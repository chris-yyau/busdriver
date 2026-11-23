#!/usr/bin/env bash
# #1147: busdriver state under <repo>/<STATE_DIR>/ must not be staged by `git add -A`
# in a repo whose .gitignore does not list it, while committable .claude/ files
# (settings.json, CLAUDE.md, review-exclude, plans) stay stageable.
set -euo pipefail
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
cd "$(dirname "$0")/.."
ROOT=$PWD
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
staged() {  # $1 = repo; staged paths under any dot dir, one line
    git -C "$1" add -A
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
newrepo "$TMP/r5"; seed_state "$TMP/r5" .bd/state
gate_exclude_state "$TMP/r5" .bd/state/
assert "custom dir state hidden" ".bd/state/CLAUDE.md .bd/state/plans/p.md .bd/state/review-exclude .bd/state/settings.json " \
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

for sd in ./.bd/state .bd//state ./.bd/./state// .bd/state/. .//.bd/state; do
    newrepo "$TMP/n"; seed_state "$TMP/n" .bd/state
    gate_exclude_state "$TMP/n" "$sd"
    assert "state dir spelled $sd is normalized" ".bd/state/CLAUDE.md .bd/state/plans/p.md .bd/state/review-exclude .bd/state/settings.json " \
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

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
