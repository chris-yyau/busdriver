#!/usr/bin/env bash
# #1147: busdriver state under <repo>/<STATE_DIR>/ must not be staged by `git add -A`
# in a repo whose .gitignore does not list it, while committable .claude/ files
# (settings.json, CLAUDE.md, review-exclude, plans) stay stageable.
set -euo pipefail
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
cd "$(dirname "$0")/.."
ROOT=$PWD
unset BUSDRIVER_STATE_DIR   # the SessionStart rows assume the default state dir
LIB="$ROOT/hooks/gate-scripts/lib/exclude-state.sh"
GATE="$ROOT/hooks/gate-scripts/pre-commit-gate.sh"
SESSION="$ROOT/hooks/gate-scripts/load-orchestrator.sh"
# shellcheck source=../hooks/gate-scripts/lib/exclude-state.sh
. "$LIB"

PASS=0; FAIL=0; TOTAL=0
assert() {
    local name="$1" expected="$2" got="$3"
    TOTAL=$((TOTAL + 1))
    if [[ "$got" == "$expected" ]]; then
        printf "  PASS  %s\n" "$name"; PASS=$((PASS + 1))
    else
        printf "  FAIL  %s (expected=%s got=%s)\n" "$name" "$expected" "$got"; FAIL=$((FAIL + 1))
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# SessionStart writes the global excludes file (#1158): never the real one. (The
# isolation preamble above already exports GIT_CONFIG_GLOBAL=/dev/null.)
export HOME="$TMP/home"; unset XDG_CONFIG_HOME
newrepo() {  # $1 = dir; a repo with one commit and no ignore rules
    git init -q "$1"
    git -C "$1" config user.email t@t.dev
    git -C "$1" config user.name tester
    echo a > "$1/a"; git -C "$1" add a; git -C "$1" commit -q -m init
}
seed_state() {  # $1 = repo, $2 = state dir
    local d="$1/$2"
    mkdir -p "$d/_backstop" "$d/ultra-oracle" "$d/oracle-max"
    for f in skip-litmus.local commit-base-claim-0.local pr-codex-lead.local.json \
        litmus-state.md litmus-review.lock litmus-review.lock.probe.x bypass-log.jsonl \
        review-metrics.jsonl toctou-parse.log _backstop/v ultra-oracle/v oracle-max/v; do
        echo s > "$d/$f"
    done
    mkdir -p "$d/plans"
    for f in settings.json CLAUDE.md review-exclude plans/p.md; do echo k > "$d/$f"; done
}
staged() {  # $1 = repo; staged paths under any dot dir, one line (info/exclude only)
    git -C "$1" -c core.excludesFile=/dev/null add -A
    git -C "$1" diff --cached --name-only | grep '^\.' | sort | tr '\n' ' '
}
KEEP=".claude/CLAUDE.md .claude/plans/p.md .claude/review-exclude .claude/settings.json "

echo "── without the helper, git add -A stages gate state ──"
newrepo "$TMP/r0"; seed_state "$TMP/r0" .claude
assert "control: state files are stageable" "yes" \
    "$(staged "$TMP/r0" | grep -q 'skip-litmus.local' && echo yes || echo no)"

echo "── the helper hides state and keeps committable files ──"
newrepo "$TMP/r1"; seed_state "$TMP/r1" .claude
gate_exclude_state "$TMP/r1" .claude
assert "only committable .claude files are staged" "$KEEP" "$(staged "$TMP/r1")"
gate_exclude_state "$TMP/r1" .claude
assert "a second run adds nothing" "1" \
    "$(grep -c '^# busdriver gate state: /.claude/' "$TMP/r1/.git/info/exclude")"

echo "── a tracked state file stays tracked ──"
newrepo "$TMP/r2"; mkdir -p "$TMP/r2/.claude"; echo t > "$TMP/r2/.claude/skip-litmus.local"
git -C "$TMP/r2" add -f .claude/skip-litmus.local; git -C "$TMP/r2" commit -q -m t
gate_exclude_state "$TMP/r2" .claude
assert "ls-files still lists it" ".claude/skip-litmus.local" \
    "$(git -C "$TMP/r2" ls-files .claude)"

echo "── an exclude file without a final newline keeps its last rule ──"
newrepo "$TMP/r3"; printf 'mine' > "$TMP/r3/.git/info/exclude"; echo x > "$TMP/r3/mine"
gate_exclude_state "$TMP/r3" .claude
assert "the old last rule still applies" "mine" \
    "$(git -C "$TMP/r3" check-ignore mine || echo none)"
assert "the block header is its own line" "1" \
    "$(grep -cx '# busdriver gate state: /.claude/ (#1147, added automatically)' "$TMP/r3/.git/info/exclude")"

echo "── a linked worktree uses the shared exclude ──"
newrepo "$TMP/r4"; git -C "$TMP/r4" worktree add -q "$TMP/w4" -b w4
seed_state "$TMP/w4" .claude
gate_exclude_state "$TMP/w4" .claude
assert "written to the common exclude" "1" \
    "$(grep -c '^# busdriver gate state' "$TMP/r4/.git/info/exclude")"
assert "worktree add -A skips state" "$KEEP" "$(staged "$TMP/w4")"

echo "── a custom state dir is anchored on itself ──"
newrepo "$TMP/r5"; seed_state "$TMP/r5" .bd
gate_exclude_state "$TMP/r5" .bd/
assert "custom dir state hidden" ".bd/CLAUDE.md .bd/plans/p.md .bd/review-exclude .bd/settings.json " \
    "$(staged "$TMP/r5")"
assert "an unsafe state dir falls back to .claude" "1" \
    "$(gate_exclude_state "$TMP/r5" '../x'; grep -c '^# busdriver gate state: /.claude/' "$TMP/r5/.git/info/exclude")"

newrepo "$TMP/r12"; before=$(cat "$TMP/r12/.git/info/exclude")
gate_exclude_state "$TMP/r12" .
assert "a repo-root state dir adds nothing" "$before" "$(cat "$TMP/r12/.git/info/exclude")"

newrepo "$TMP/r14"; gate_exclude_state "$TMP/r14" /
assert "an absolute state dir falls back to .claude, as the gates do" "1" \
    "$(grep -c '^# busdriver gate state: /.claude/' "$TMP/r14/.git/info/exclude")"

newrepo "$TMP/r15"; chmod 000 "$TMP/r15/.git/info/exclude"
if [[ -r "$TMP/r15/.git/info/exclude" ]]; then
    assert "an unreadable exclude is reported (skipped: running as root)" "skip" "skip"
else
    err=$(gate_exclude_state "$TMP/r15" .claude 2>&1)
    assert "an unreadable exclude is reported" "yes" "$([[ "$err" == *"could not read"* ]] && echo yes || echo no)"
fi
chmod 644 "$TMP/r15/.git/info/exclude"

for sd in ./.bd .bd// ./.bd/./ .bd/. .//.bd; do
    newrepo "$TMP/n"; seed_state "$TMP/n" .bd
    gate_exclude_state "$TMP/n" "$sd"
    assert "state dir spelled $sd is normalized" ".bd/CLAUDE.md .bd/plans/p.md .bd/review-exclude .bd/settings.json " \
        "$(staged "$TMP/n")"
    rm -rf "$TMP/n"
done

echo "── a partial or older block is completed ──"
newrepo "$TMP/r9"; seed_state "$TMP/r9" .claude
gate_exclude_state_block .claude > "$TMP/block"
head -n 3 "$TMP/block" > "$TMP/r9/.git/info/exclude"
gate_exclude_state "$TMP/r9" .claude
assert "missing rules are added" "$KEEP" "$(staged "$TMP/r9")"
rc=0; gone=$(grep -vxF -f "$TMP/r9/.git/info/exclude" "$TMP/block") || rc=$?
# grep -v exits 1 only when every block line was found; 2 is an unreadable file.
assert "every block line is now present" "1:" "$rc:$gone"
assert "and none is repeated" "$(wc -l < "$TMP/block")" "$(wc -l < "$TMP/r9/.git/info/exclude")"
before=$(wc -l < "$TMP/r9/.git/info/exclude")
gate_exclude_state "$TMP/r9" .claude
assert "a complete block is left alone" "$before" "$(wc -l < "$TMP/r9/.git/info/exclude")"

echo "── only a regular exclude file is written ──"
newrepo "$TMP/r10"; echo shared > "$TMP/shared-ignore"
rm -f "$TMP/r10/.git/info/exclude"; ln -s "$TMP/shared-ignore" "$TMP/r10/.git/info/exclude"
err=$(gate_exclude_state "$TMP/r10" .claude 2>&1)
assert "a symlinked exclude is left alone" "shared:link" \
    "$(cat "$TMP/shared-ignore"):$([[ -L "$TMP/r10/.git/info/exclude" ]] && echo link || echo replaced)"
assert "and the skip is reported" "yes" "$([[ "$err" == *"not a regular file"* ]] && echo yes || echo no)"
newrepo "$TMP/r13"; echo other > "$TMP/other-exclude"
rm -f "$TMP/r13/.git/info/exclude"; ln "$TMP/other-exclude" "$TMP/r13/.git/info/exclude"
gate_exclude_state "$TMP/r13" .claude 2>/dev/null
assert "a hard-linked exclude is left alone" "other:linked" \
    "$(cat "$TMP/other-exclude"):$([[ "$TMP/r13/.git/info/exclude" -ef "$TMP/other-exclude" ]] && echo linked || echo replaced)"
newrepo "$TMP/r11"; FIFO="$TMP/r11/.git/info/exclude"; rm -f "$FIFO"; mkfifo "$FIFO"
( gate_exclude_state "$TMP/r11" .claude ) >/dev/null 2>&1 & fpid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$fpid" 2>/dev/null || break; sleep 0.5; done
fifo=returned
if kill -0 "$fpid" 2>/dev/null; then
    fifo=hung
    # A read-write open never blocks and releases whichever side is stuck.
    for _ in 1 2 3; do exec 3<>"$FIFO"; exec 3>&-; done
    # Bounded: whatever is still blocked after that is killed, never waited on.
    sleep 0.5; kill -9 "$fpid" 2>/dev/null || true
fi
kill -0 "$fpid" 2>/dev/null || wait "$fpid" 2>/dev/null || true
assert "a FIFO exclude does not hang the hook and is left alone" "returned:fifo" \
    "$fifo:$([[ -p "$FIFO" ]] && echo fifo || echo replaced)"

echo "── an inherited GIT_DIR does not redirect it ──"
newrepo "$TMP/ga"; newrepo "$TMP/gb"
(export GIT_DIR="$TMP/ga/.git"; gate_exclude_state "$TMP/gb" .claude)
assert "the repo the dir is in gets the rules, not GIT_DIR's" "1:0" \
    "$(grep -c '^# busdriver gate state' "$TMP/gb/.git/info/exclude" || true):$(grep -c '^# busdriver' "$TMP/ga/.git/info/exclude" || true)"

echo "── outside a repo it is a quiet no-op ──"
mkdir -p "$TMP/plain"
assert "returns 0 with no output" "0:" "$(gate_exclude_state "$TMP/plain" .claude 2>&1; echo "$?:")"

echo "── the helper and busdriver's .gitignore state rules agree ──"
newrepo "$TMP/r6"; gate_exclude_state "$TMP/r6" .claude
# Claude Code's own dir, not busdriver state.
gi_rules=$(grep -E '^/?\.claude/' "$ROOT/.gitignore" | sed 's#^/##' | grep -vx '\.claude/worktrees/' || true)
assert "the .gitignore state rules were read" "yes" "$([[ -n "$gi_rules" ]] && echo yes || echo no)"
missing=""
while IFS= read -r rule; do
    [[ -n "$rule" ]] || continue
    p=${rule//\*/x}; case "$p" in */) p="${p}f" ;; esac
    mkdir -p "$TMP/r6/$(dirname "$p")"; : > "$TMP/r6/$p"
    git -C "$TMP/r6" check-ignore -q "$p" || missing="$missing $rule"
done <<< "$gi_rules"
assert "every .gitignore state rule is covered by the helper" "" "$missing"
gate_exclude_state_block .claude > "$TMP/block6"
extra=""
while IFS= read -r rule; do
    case "$rule" in "#"*) continue ;; esac
    grep -qxF -- "${rule#/}" <<< "$gi_rules" || extra="$extra $rule"
done < "$TMP/block6"
assert "every helper rule is also a .gitignore state rule" "" "$extra"

echo "── the exclude file's mode is kept ──"
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
newrepo "$TMP/r17"; chmod 640 "$TMP/r17/.git/info/exclude"
gate_exclude_state "$TMP/r17" .claude
assert "an existing exclude keeps its mode" "640" "$(mode_of "$TMP/r17/.git/info/exclude")"
newrepo "$TMP/r18"; rm -f "$TMP/r18/.git/info/exclude"
(umask 077; gate_exclude_state "$TMP/r18" .claude)
assert "a new exclude follows the umask" "600" "$(mode_of "$TMP/r18/.git/info/exclude")"
newrepo "$TMP/r19"; rm -f "$TMP/r19/.git/info/exclude"
(umask 022; gate_exclude_state "$TMP/r19" .claude)
assert "and is readable under a 022 umask" "644" "$(mode_of "$TMP/r19/.git/info/exclude")"

newrepo "$TMP/r21"; rm -f "$TMP/r21/.git/info/exclude"
(umask 0222; gate_exclude_state "$TMP/r21" .claude)
assert "a read-only umask still gets the rules" "1" \
    "$(grep -c '^# busdriver gate state: /.claude/' "$TMP/r21/.git/info/exclude" 2>/dev/null || true)"

echo "── concurrent hooks lose nothing ──"
newrepo "$TMP/r24"; seed_state "$TMP/r24" .claude; seed_state "$TMP/r24" .st2
for _ in 1 2 3 4 5 6; do gate_exclude_state "$TMP/r24" .claude & gate_exclude_state "$TMP/r24" .st2 & done; wait
# A repeated line is harmless; a missing one is not.
assert "parallel runs for two state dirs keep both sets of rules" ".claude/CLAUDE.md .claude/plans/p.md .claude/review-exclude .claude/settings.json .st2/CLAUDE.md .st2/plans/p.md .st2/review-exclude .st2/settings.json " \
    "$(staged "$TMP/r24")"

echo "── a UTF-8 BOM stays at the start ──"
newrepo "$TMP/r20"; printf '\357\273\277/private.env\n' > "$TMP/r20/.git/info/exclude"; echo p > "$TMP/r20/private.env"
gate_exclude_state "$TMP/r20" .claude
assert "the user's first rule still matches" "private.env" "$(git -C "$TMP/r20" check-ignore private.env || echo none)"
assert "the file still starts with the BOM" "efbbbf" \
    "$(head -c 3 "$TMP/r20/.git/info/exclude" | od -An -tx1 | tr -d ' \n')"

echo "── a .gitignore exception still wins ──"
newrepo "$TMP/r16"; mkdir -p "$TMP/r16/.claude"; echo k > "$TMP/r16/.claude/keep.local"
printf '!/.claude/keep.local\n' > "$TMP/r16/.gitignore"
gate_exclude_state "$TMP/r16" .claude
assert "the excepted file is still stageable" ".claude/keep.local .gitignore " "$(staged "$TMP/r16")"

echo "── wiring: the pre-commit gate and SessionStart both call it ──"
newrepo "$TMP/r7"
printf '{"tool_name":"Bash","tool_use_id":"t1","cwd":"%s","tool_input":{"command":"git add -A && git commit -m x"}}' \
    "$TMP/r7" | bash "$GATE" >/dev/null 2>&1 || true
assert "pre-commit gate wrote the block" "1" \
    "$(grep -c '^# busdriver gate state: /.claude/' "$TMP/r7/.git/info/exclude" || true)"
newrepo "$TMP/r8"
(cd "$TMP/r8" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$SESSION" </dev/null >/dev/null 2>&1) || true
assert "SessionStart wrote the block" "1" \
    "$(grep -c '^# busdriver gate state: /.claude/' "$TMP/r8/.git/info/exclude" || true)"
# #1158: a standalone `git -C <other> add -A` reaches no gate or SessionStart in that
# repo, so the rules also go in the global excludes file git reads for every repo.
# The helper writes only for the account's own HOME, so each row passes its fake
# home as that account home and clears the preamble's GIT_CONFIG_GLOBAL/NOSYSTEM,
# which lets the system config in; a machine whose system config sets
# core.excludesFile would make every row report instead, so they are skipped there.
gx() {  # $1 = home; the rest = extra VAR=value exports; prints the helper's stderr
    local h="$1"; shift
    # shellcheck disable=SC2163  # the arguments are VAR=value words to export
    (export HOME="$h" "$@"; unset GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM; gate_exclude_state_global "$h") 2>&1
}
if env -u GIT_CONFIG_NOSYSTEM git -C / config --system --includes --get core.excludesFile >/dev/null 2>&1; then
    echo "  SKIP  global excludes rows: this machine's system git config sets core.excludesFile"
else
mkdir -p "$TMP/h1"; chmod 755 "$TMP/h1"
newrepo "$TMP/g1other"; seed_state "$TMP/g1other" .claude
gx "$TMP/h1" >/dev/null
assert "the global excludes file gets the block" "1" \
    "$(grep -c '^# busdriver gate state: /.claude/' "$TMP/h1/.config/git/ignore" || true)"
assert "a repo no hook has seen: git add -A skips its state" "$KEEP" \
    "$(HOME="$TMP/h1" env -u GIT_CONFIG_COUNT git -C "$TMP/g1other" add -A && git -C "$TMP/g1other" diff --cached --name-only | grep '^\.' | sort | tr '\n' ' ')"
assert "that repo's info/exclude was not needed" "0" \
    "$(grep -c 'busdriver gate state' "$TMP/g1other/.git/info/exclude" || true)"
n1=$(wc -l < "$TMP/h1/.config/git/ignore"); gx "$TMP/h1" >/dev/null
assert "a second run adds nothing" "$n1" "$(wc -l < "$TMP/h1/.config/git/ignore")"
mkdir -p "$TMP/h2/.config/git"; printf 'AGENTS.md' > "$TMP/h2/.config/git/ignore"; gx "$TMP/h2" >/dev/null
assert "the user's own rules are kept, and an unterminated last line is not joined" "AGENTS.md|1" \
    "$(head -1 "$TMP/h2/.config/git/ignore")|$(grep -c '^# busdriver gate state: /.claude/' "$TMP/h2/.config/git/ignore")"
mkdir -p "$TMP/h3"; gx "$TMP/h3" XDG_CONFIG_HOME="$TMP/h3/.config" >/dev/null
assert "XDG_CONFIG_HOME at its default is accepted" "1" \
    "$(grep -c '^# busdriver gate state' "$TMP/h3/.config/git/ignore" || true)"
mkdir -p "$TMP/h15"; printf '[core]\n\texcludesFile = ~/.config/git/ignore\n' > "$TMP/h15/.gitconfig"; gx "$TMP/h15" >/dev/null
assert "a core.excludesFile naming that same file is accepted" "1" \
    "$(grep -c '^# busdriver gate state' "$TMP/h15/.config/git/ignore" || true)"
mkdir -p "$TMP/h4"; echo keep > "$TMP/h4/my-ignore"
printf '[core]\n\texcludesFile = %s\n' "$TMP/h4/my-ignore" > "$TMP/h4/.gitconfig"; err=$(gx "$TMP/h4")
assert "a core.excludesFile naming another file is reported and nothing is written" "keep|1|no" \
    "$(cat "$TMP/h4/my-ignore")|$(grep -c 'names another file' <<<"$err" || true)|$([[ -e "$TMP/h4/.config/git/ignore" ]] && echo yes || echo no)"
mkdir -p "$TMP/h6"; printf '[core]\n\texcludesFile = %s\n' "$TMP/h6/inc-ignore" > "$TMP/g6.inc"
printf '[include]\n\tpath = %s\n' "$TMP/g6.inc" > "$TMP/h6/.gitconfig"; err=$(gx "$TMP/h6")
assert "one set through include.path is found too (git add finds it)" "1|no" \
    "$(grep -c 'names another file' <<<"$err" || true)|$([[ -e "$TMP/h6/.config/git/ignore" ]] && echo yes || echo no)"
mkdir -p "$TMP/h7"; printf '[core]\n\texcludesFile = "%s\\n"\n' "$TMP/h7/.config/git/ignore" > "$TMP/h7/.gitconfig"; err=$(gx "$TMP/h7")
assert "a name that differs only by a trailing newline is another file" "1|no" \
    "$(grep -c 'names another file' <<<"$err" || true)|$([[ -e "$TMP/h7/.config/git/ignore" ]] && echo yes || echo no)"
mkdir -p "$TMP/h8"; printf '[core]\n\texcludesFile =\n' > "$TMP/h8/.gitconfig"; err=$(gx "$TMP/h8")
assert "an explicitly empty core.excludesFile is reported and writes nothing" "1|no" \
    "$(grep -c 'core.excludesFile is empty' <<<"$err" || true)|$([[ -e "$TMP/h8/.config/git/ignore" ]] && echo yes || echo no)"
mkdir -p "$TMP/h9"; echo keep > "$TMP/victim9"; printf '[core]\n\texcludesFile = %s\n' "$TMP/victim9" > "$TMP/g9.cfg"
gx "$TMP/h9" GIT_CONFIG="$TMP/g9.cfg" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.excludesFile GIT_CONFIG_VALUE_0="$TMP/victim9" >/dev/null
assert "a process-scoped config override does not choose the file" "keep|1" \
    "$(cat "$TMP/victim9")|$(grep -c '^# busdriver gate state' "$TMP/h9/.config/git/ignore" || true)"
for v in GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM XDG_CONFIG_HOME; do
    mkdir -p "$TMP/h13$v"
    err=$(export HOME="$TMP/h13$v"; unset GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM; export "$v=$TMP/g9.cfg"; gate_exclude_state_global "$HOME" 2>&1)
    assert "a redirected $v is reported and writes nothing" "keep|1|no" \
        "$(cat "$TMP/victim9")|$(grep -c 'global config is redirected' <<<"$err" || true)|$([[ -e "$TMP/h13$v/.config/git/ignore" ]] && echo yes || echo no)"
done
mkdir -p "$TMP/h10"; printf '[core\n' > "$TMP/h10/.gitconfig"; err=$(gx "$TMP/h10")
assert "an unreadable config is reported and writes nothing" "1:no" \
    "$(grep -c 'could not read core.excludesFile' <<<"$err" || true):$([[ -e "$TMP/h10/.config/git/ignore" ]] && echo yes || echo no)"
mkdir -p "$TMP/h16" "$TMP/elsewhere16"; ln -s "$TMP/elsewhere16" "$TMP/h16/.config"; err=$(gx "$TMP/h16")
assert "a symlinked ~/.config is reported, and nothing is created through it" "1|no" \
    "$(grep -c 'not a regular file of this account' <<<"$err" || true)|$([[ -e "$TMP/elsewhere16/git" ]] && echo yes || echo no)"
mkdir -p "$TMP/h20/.config" "$TMP/elsewhere20"; echo keep > "$TMP/elsewhere20/ignore"; ln -s "$TMP/elsewhere20" "$TMP/h20/.config/git"
err=$(gx "$TMP/h20")
assert "a symlinked ~/.config/git cannot lead to another file named ignore" "keep|1" \
    "$(cat "$TMP/elsewhere20/ignore")|$(grep -c 'not a regular file of this account' <<<"$err" || true)"
mkdir -p "$TMP/h18/.config/git"; echo keep > "$TMP/h18/other"; ln "$TMP/h18/other" "$TMP/h18/.config/git/ignore"
err=$(gx "$TMP/h18")
assert "a hard-linked global file is refused, reported, and left alone" "keep|1" \
    "$(cat "$TMP/h18/other")|$(grep -c 'not a regular file of this account' <<<"$err" || true)"
mkdir -p "$TMP/h19/.config/git/ignore"; err=$(gx "$TMP/h19")
assert "a directory in its place is refused and reported" "1" \
    "$(grep -c 'not a regular file of this account' <<<"$err" || true)"
mkdir -p "$TMP/h21/.config/git"; echo keep > "$TMP/h21/.config/git/ignore"; chmod 111 "$TMP/h21/.config"
gx "$TMP/h21" >/dev/null; chmod 755 "$TMP/h21/.config"
assert "a searchable but unreadable ~/.config still gets the block (git can read the file)" "1" \
    "$(grep -c '^# busdriver gate state' "$TMP/h21/.config/git/ignore" || true)"
mkdir -p "$TMP/h22"; for i in 1 2 3 4 5 6; do gx "$TMP/h22" > "$TMP/h22.err$i" & done; wait
assert "sessions starting at once write the block once, with no failure report" "1|" \
    "$(grep -c '^# busdriver gate state' "$TMP/h22/.config/git/ignore" || true)|$(cat "$TMP"/h22.err*)"
mkdir -p "$TMP/h23/.config/git"; gate_exclude_state_block .claude > "$TMP/h23/.config/git/ignore"
head -c 2100000 /dev/zero | tr '\0' '#' >> "$TMP/h23/.config/git/ignore"; n23=$(wc -c < "$TMP/h23/.config/git/ignore")
err=$(gx "$TMP/h23")
assert "a large file holding the block (and a 2 MB line) is read, not rewritten or reported" "|$n23" \
    "$err|$(wc -c < "$TMP/h23/.config/git/ignore")"
mkdir -p "$TMP/h24/.config/git"; { head -c 70000 /dev/zero | tr '\0' 'x'; gate_exclude_state_block .claude | head -2 | tail -1; } > "$TMP/h24/.config/git/ignore"
gx "$TMP/h24" >/dev/null
assert "a rule glued to the end of an overlong line does not count as present" "1" \
    "$(grep -cxF '/.claude/*.local' "$TMP/h24/.config/git/ignore" || true)"
mkdir -p "$TMP/h25/.config/git"; gate_exclude_state_block .claude | sed 's/$/'$'\r''/' > "$TMP/h25/.config/git/ignore"
n25=$(wc -c < "$TMP/h25/.config/git/ignore"); gx "$TMP/h25" >/dev/null
assert "a CRLF copy of the block counts as present (git drops the CR)" "$n25" "$(wc -c < "$TMP/h25/.config/git/ignore")"
mkdir -p "$TMP/h26/.config/git"; { head -c 65435 /dev/zero | tr '\0' '#'; echo
    gate_exclude_state_block .claude | sed 's/$/                                        /'; } > "$TMP/h26/.config/git/ignore"
n26=$(wc -c < "$TMP/h26/.config/git/ignore"); gx "$TMP/h26" >/dev/null
assert "rules with trailing spaces across a read boundary count as present" "$n26" "$(wc -c < "$TMP/h26/.config/git/ignore")"
mkdir -p "$TMP/h27/.config/git"
{ printf '\357\273\277'; gate_exclude_state_block .claude | sed -n 2p; echo '!/.claude/keep.local'; } > "$TMP/h27/.config/git/ignore"
gx "$TMP/h27" >/dev/null
assert "a rule after a leading UTF-8 BOM counts as present, so a later ! exception keeps winning" "0|1" \
    "$(grep -cxF '/.claude/*.local' "$TMP/h27/.config/git/ignore" || true)|$(grep -c '^/.claude/\*\.local\.\*$' "$TMP/h27/.config/git/ignore" || true)"
mkdir -p "$TMP/h5/.config/git"; echo keep > "$TMP/h5/real"; ln -s "$TMP/h5/real" "$TMP/h5/.config/git/ignore"
err=$(gx "$TMP/h5")
assert "a symlinked global file is refused, reported, and left alone" "keep|1" \
    "$(cat "$TMP/h5/real")|$(grep -c 'not a regular file of this account' <<<"$err" || true)"
fi
newrepo "$TMP/g12"
# Only HOME differs here: the preamble's GIT_CONFIG_* would trigger the same report.
err=$(cd "$TMP/g12" && env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_NOSYSTEM HOME="$TMP/h12" CLAUDE_PLUGIN_ROOT="$ROOT" \
    bash "$SESSION" </dev/null 2>&1 >/dev/null) || true
assert "SessionStart calls it, and a HOME other than the account's is reported, not written" "1:no" \
    "$(grep -c "global config is redirected" <<<"$err" || true):$([[ -e "$TMP/h12/.config/git/ignore" ]] && echo yes || echo no)"
out=$(cd "$TMP/g12" && env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_NOSYSTEM HOME="$TMP/h12" CLAUDE_PLUGIN_ROOT="$ROOT" \
    bash "$SESSION" </dev/null 2>/dev/null) || true
assert "and the report reaches Claude in additionalContext" "1" \
    "$(python3 -c 'import json,sys; print(int("global config is redirected" in json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]))' <<<"$out" || echo error)"
newrepo "$TMP/r25"
(cd "$TMP/r25" && BUSDRIVER_STATE_DIR=.bd CLAUDE_PLUGIN_ROOT="$ROOT" bash "$SESSION" </dev/null >/dev/null 2>&1) || true
assert "SessionStart with an override still protects the contained gates' .claude" "1 1" \
    "$(grep -c '^# busdriver gate state: /.claude/' "$TMP/r25/.git/info/exclude" || true) $(grep -c '^# busdriver gate state: /.bd/' "$TMP/r25/.git/info/exclude" || true)"
newrepo "$TMP/r30"
(cd "$TMP/r30" && BUSDRIVER_STATE_DIR=src CLAUDE_PLUGIN_ROOT="$ROOT" bash "$SESSION" </dev/null >/dev/null 2>&1) || true
assert "SessionStart ignores a non-dot override (repo-settable via settings.json env)" "1 0" \
    "$(grep -c '^# busdriver gate state: /.claude/' "$TMP/r30/.git/info/exclude" || true) $(grep -c '^/src/' "$TMP/r30/.git/info/exclude" || true)"
newrepo "$TMP/r33"
(cd "$TMP/r33" && BUSDRIVER_STATE_DIR=./.bd CLAUDE_PLUGIN_ROOT="$ROOT" bash "$SESSION" </dev/null >/dev/null 2>&1) || true
assert "SessionStart accepts a ./-spelled dot override" "1" \
    "$(grep -c '^# busdriver gate state: /.bd/' "$TMP/r33/.git/info/exclude" || true)"
# The pre-commit gate hands its STATE_DIR straight to the helper, so the helper filters.
newrepo "$TMP/r32"; before=$(cat "$TMP/r32/.git/info/exclude")
for sd in src x/.bd .config/src ./.bd/state; do gate_exclude_state "$TMP/r32" "$sd"; done
assert "the helper adds nothing for a non-dot state dir" "$before" "$(cat "$TMP/r32/.git/info/exclude")"
# A copy of the gate whose lib dir lacks exclude-state.sh must still reach its own
# decision (an unguarded source exits 1 with no output, and the commit goes through).
cp -R "$ROOT/hooks/gate-scripts" "$TMP/nolibgate"; rm "$TMP/nolibgate/lib/exclude-state.sh"
newrepo "$TMP/r31"
rc=0; out=$(printf '{"tool_name":"Bash","tool_use_id":"t1","cwd":"%s","tool_input":{"command":"git add -A && git commit -m x"}}' \
    "$TMP/r31" | bash "$TMP/nolibgate/pre-commit-gate.sh" 2>"$TMP/r31.err") || rc=$?
decision=$(printf '%s' "$out" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d["decision"], "review" in d["reason"].lower())' 2>/dev/null) || decision=unparseable
assert "pre-commit gate without the lib warns and still blocks for review" "0:block True:1" \
    "$rc:$decision:$(grep -c 'exclude-state.sh unavailable' "$TMP/r31.err" || true)"
newrepo "$TMP/r26"; mkdir -p "$TMP/r26/sub"
(cd "$TMP/r26/sub" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$SESSION" </dev/null >/dev/null 2>&1) || true
assert "SessionStart in a subdirectory protects that subdirectory's .claude too" "1 1" \
    "$(grep -c '^# busdriver gate state: /.claude/' "$TMP/r26/.git/info/exclude" || true) $(grep -c '^# busdriver gate state: /sub/.claude/' "$TMP/r26/.git/info/exclude" || true)"
# A copy of the hook whose lib dir lacks exclude-state.sh must still emit its output.
mkdir -p "$TMP/nolib/lib"; cp "$SESSION" "$TMP/nolib/load-orchestrator.sh"
newrepo "$TMP/r27"
rc=0; out=$(cd "$TMP/r27" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$TMP/nolib/load-orchestrator.sh" </dev/null 2>"$TMP/r27.err") || rc=$?
assert "SessionStart without the lib still emits additionalContext and exits 0" "yes:0" \
    "$(case "$out" in *additionalContext*) echo yes ;; *) echo no ;; esac):$rc"
assert "SessionStart without the lib warns that state stays stageable" "1" \
    "$(grep -c 'exclude-state.sh unavailable' "$TMP/r27.err" || true)"
newrepo "$TMP/r28"; mkdir -p "$TMP/r28/client work [x]/.claude"
echo s > "$TMP/r28/client work [x]/.claude/skip-litmus.local"; echo k > "$TMP/r28/client work [x]/.claude/settings.json"
(cd "$TMP/r28/client work [x]" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$SESSION" </dev/null >/dev/null 2>&1) || true
assert "a subdirectory with spaces and glob characters gets literal rules" "client work [x]/.claude/settings.json " \
    "$(git -C "$TMP/r28" add -A && git -C "$TMP/r28" diff --cached --name-only | grep '/\.claude/' | tr '\n' ' ')"
newrepo "$TMP/r29"
(cd "$TMP/r29" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$SESSION" </dev/null >/dev/null 2>&1) || true
assert "a default session writes one block, not two" "1" \
    "$(grep -c '^# busdriver gate state' "$TMP/r29/.git/info/exclude" || true)"
before=$(cat "$TMP/r29/.git/info/exclude")
gate_exclude_state "$TMP/r29" '../x/.claude' literal
assert "a literal ../ component is refused, adding nothing" "$before" "$(cat "$TMP/r29/.git/info/exclude")"

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
