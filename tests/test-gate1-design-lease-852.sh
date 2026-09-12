#!/usr/bin/env bash
# #852 — pre-commit Gate 1 consumes the native design lease, then falls through
# to Gate 2 (Litmus). Sabotage: without the Gate 1 consumer these rows fail
# (valid lease still design-blocks; stale/unbound already did).
#
# Every token / skip file is armed inside a SCRATCH repo, never this one.
# shellcheck disable=SC2312,SC2015
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
R="$ROOT/hooks/gate-scripts/lib/resolve-repo-dir.sh"
GATE="$ROOT/hooks/gate-scripts/pre-commit-gate.sh"

PASS=0; FAIL=0
ok(){ printf "  PASS  %s\n" "$1"; PASS=$((PASS + 1)); }
no(){ printf "  FAIL  %s :: %s\n" "$1" "${2:-}"; FAIL=$((FAIL + 1)); }
eq(){ [[ "$2" = "$3" ]] && ok "$1" || no "$1" "want=$3 got=$2"; }

TMPS=()
cleanup(){ local d; for d in "${TMPS[@]:-}"; do [[ -n "$d" ]] && rm -rf "$d"; done; }
trap cleanup EXIT

NEWREPO=""
mkrepo(){
    local d
    d="$(mktemp -d)" || { printf 'FATAL: mktemp -d failed\n' >&2; exit 1; }
    [[ -n "$d" && -d "$d" ]] || { printf 'FATAL: mktemp -d gave no directory\n' >&2; exit 1; }
    TMPS+=("$d")
    git -C "$d" init -q || { printf 'FATAL: git init failed in %s\n' "$d" >&2; exit 1; }
    git -C "$d" config user.email t@t; git -C "$d" config user.name t
    git -C "$d" config core.hooksPath "$d/.git/hooks"
    git -C "$d" config core.fsmonitor false
    git -C "$d" config commit.gpgSign false
    git -C "$d" config core.pager false
    mkdir -p "$d/fakehome"
    git -C "$d" commit -q --allow-empty -m init
    NEWREPO="$d"
}
fresh(){
    mkrepo
    local r="$NEWREPO"
    mkdir -p "$r/docs/plans" "$r/src" "$r/.claude"
    printf '# plan\n'  >"$r/docs/plans/p.md"
    printf 'x\n'       >"$r/src/impl.py"
}

payload(){ jq -cn --arg c "$1" --arg cwd "$2" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}'; }

# Classify Gate 1 vs later gates. "past-gate1" means Gate 1 did not design-block
# (Gate 2 / merge / other may still emit a decision).
verdict(){
    local out
    out="$(payload "$1" "$2" | env HOME="$2/fakehome" XDG_CONFIG_HOME="$2/fakehome/.config" \
            GIT_CONFIG_SYSTEM=/dev/null bash "$GATE" 2>/dev/null)"
    case "$out" in
        *"Design review required before committing"*) printf 'design-block' ;;
        *"skip-design-review.local was created moments ago"*) printf 'too-new-block' ;;
        *"skip lease has EXPIRED"*) printf 'expired-block' ;;
        *"skip lease is EXHAUSTED"*) printf 'exhausted-block' ;;
        *'"decision"'*) printf 'past-gate1' ;;
        *) printf 'no-decision: %s' "$out" ;;
    esac
}

# The SAME canonical computation the gate uses (pre-commit-gate.sh
# _bd852_canonical_staged_hash). If these ever diverge the fixture would mint bindings
# the gate rejects, so the flags are duplicated deliberately rather than approximated.
canon_hash(){  # <repo>
    git -C "$1" --no-replace-objects -c color.ui=never -c core.quotePath=false \
        diff --cached --no-ext-diff --no-textconv --full-index --ignore-submodules=none \
        2>/dev/null | shasum -a 256 | cut -d' ' -f1
}

wt_id(){ git -C "$1" rev-parse --absolute-git-dir 2>/dev/null; }

# <repo> <age-seconds> [binding-line]
# With no third argument the file gets a VALID #852 binding for this repo's current
# staged diff — so callers must stage first. Pass an explicit line (or "") to arm a
# deliberately wrong or unbound authorization.
arm_skip(){
    local repo="$1" age="$2" when
    rm -rf "$repo/.claude/.skip-design-review-lease.d"
    mkdir -p "$repo/.claude"
    if [[ $# -ge 3 ]]; then
        # NEWLINE-TERMINATED. Without it the old shell read hit EOF, returned non-zero
        # and cleared the line, so every "wrong binding" row silently exercised the
        # missing-binding arm instead of the rejection it names — the rows passed for the
        # wrong reason. `arm_skip_raw` below writes the unterminated form deliberately,
        # as a control, rather than leaving it as an accident of the helper.
        printf '%s\n' "$3" >"$repo/.claude/skip-design-review.local"
    else
        printf 'PASS-DESIGN %s %s\n' "$(wt_id "$repo")" "$(canon_hash "$repo")" \
            >"$repo/.claude/skip-design-review.local"
    fi
    when="$(python3 -c 'import sys,time;print(time.time()-float(sys.argv[1]))' "$age")"
    python3 -c 'import os,sys;t=float(sys.argv[2]);os.utime(sys.argv[1],(t,t))' \
        "$repo/.claude/skip-design-review.local" "$when"
}

lease_uses(){
    find "$1/.claude/.skip-design-review-lease.d" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
        | wc -l | tr -d ' '
}

pending_tokens(){
    # Existence of any design-review-needed token under the shared marker dir.
    # Readers must not mutate; we only count files that look like armed tokens.
    local repo="$1" dir
    dir="$(bash "$R" dir "$repo" 2>/dev/null)" || dir=""
    if [[ -z "$dir" || ! -d "$dir" ]]; then
        printf '0'
        return
    fi
    find "$dir" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' '
}

echo "── #852 Gate 1 design-lease consumer ───────────────────────────────"

# (a) Valid lease + pending + impl commit → past Gate 1 (falls through to Gate 2).
# Sabotage without consumer: design-block.
fresh; a="$NEWREPO"
bash "$R" arm "$a/docs/plans/p.md" >/dev/null 2>&1 || true
git -C "$a" add src/impl.py
arm_skip "$a" 120
before_tokens="$(pending_tokens "$a")"
before_uses="$(lease_uses "$a")"
eq "valid lease + impl → past Gate 1" \
   "$(verdict "git commit -m 'fix: impl'" "$a")" "past-gate1"
after_uses="$(lease_uses "$a")"
after_tokens="$(pending_tokens "$a")"
if [[ "$((before_uses + 1))" = "$after_uses" ]]; then
    ok "valid lease spends exactly one slot"
else
    no "valid lease spends exactly one slot" "before=$before_uses after=$after_uses"
fi
if [[ "$before_tokens" = "$after_tokens" && "$before_tokens" != "0" ]]; then
    ok "lease grant does not design-clear pending tokens"
else
    no "lease grant does not design-clear pending tokens" \
       "before=$before_tokens after=$after_tokens"
fi
# Fall-through (not exit 0): a later gate still decided.
out="$(payload "git commit -m 'fix: impl'" "$a" | env HOME="$a/fakehome" \
        XDG_CONFIG_HOME="$a/fakehome/.config" GIT_CONFIG_SYSTEM=/dev/null \
        bash "$GATE" 2>/dev/null)"
case "$out" in
    *"Design review required"*) no "grant falls through to Gate 2" "still on Gate 1" ;;
    *'"decision"'*)             ok "grant falls through to Gate 2 (later gate decided)" ;;
    *)                          no "grant falls through to Gate 2" "no decision: $out" ;;
esac
err="$(payload "git commit -m 'fix: impl'" "$a" | env HOME="$a/fakehome" \
        XDG_CONFIG_HOME="$a/fakehome/.config" GIT_CONFIG_SYSTEM=/dev/null \
        bash "$GATE" 2>&1 >/dev/null)"
case "$err" in
    *"#852"*) ok "lease grant is announced on stderr" ;;
    *)        no "lease grant is announced on stderr" "got: $err" ;;
esac
# Must not reset the Gate 2 circuit breaker.
: >"$a/.claude/.gate-block-count.local"
printf '7\n' >"$a/.claude/.gate-block-count.local"
arm_skip "$a" 120
verdict "git commit -m 'fix: impl'" "$a" >/dev/null
cnt="$(tr -d ' \n' <"$a/.claude/.gate-block-count.local" 2>/dev/null || true)"
# Gate 2 still runs and may increment (7→8). A skip-litmus-style reset would
# wipe the file so the next block writes 1. Seeing 8 proves no wipe.
if [[ "$cnt" = "8" ]]; then
    ok "lease grant does not reset .gate-block-count.local"
else
    no "lease grant does not reset .gate-block-count.local" "got=$cnt (want 8 = Gate2 increment of 7)"
fi

# (b) Too-new (<30s) → still blocks; not an allow; not skip-litmus.
fresh; b="$NEWREPO"
bash "$R" arm "$b/docs/plans/p.md" >/dev/null 2>&1 || true
git -C "$b" add src/impl.py
arm_skip "$b" 5
eq "too-new lease → too-new-block" \
   "$(verdict "git commit -m 'fix: impl'" "$b")" "too-new-block"
if [[ -f "$b/.claude/skip-litmus.local" ]]; then
    no "too-new does not invent skip-litmus.local" "file present"
else
    ok "too-new does not invent skip-litmus.local"
fi

# (c) Expired (>3600s) → still blocks.
fresh; c="$NEWREPO"
bash "$R" arm "$c/docs/plans/p.md" >/dev/null 2>&1 || true
git -C "$c" add src/impl.py
arm_skip "$c" 4000
eq "expired lease → expired-block" \
   "$(verdict "git commit -m 'fix: impl'" "$c")" "expired-block"

# (d) Exhausted (20 uses) → still blocks.
fresh; d="$NEWREPO"
bash "$R" arm "$d/docs/plans/p.md" >/dev/null 2>&1 || true
git -C "$d" add src/impl.py
arm_skip "$d" 120
i=0
while [[ "$i" -lt 20 ]]; do
    verdict "git commit -m 'fix: impl'" "$d" >/dev/null
    i=$((i + 1))
done
eq "use 21 → exhausted-block" \
   "$(verdict "git commit -m 'fix: impl'" "$d")" "exhausted-block"

# (e) Missing skip file → unbound Gate 1 block.
fresh; e="$NEWREPO"
bash "$R" arm "$e/docs/plans/p.md" >/dev/null 2>&1 || true
git -C "$e" add src/impl.py
rm -f "$e/.claude/skip-design-review.local"
eq "no skip file → design-block" \
   "$(verdict "git commit -m 'fix: impl'" "$e")" "design-block"

# (f) #325 repo-controlled skip file → unbound Gate 1 block (not an allow).
fresh; f="$NEWREPO"
bash "$R" arm "$f/docs/plans/p.md" >/dev/null 2>&1 || true
git -C "$f" add src/impl.py
arm_skip "$f" 120
git -C "$f" add -f .claude/skip-design-review.local >/dev/null 2>&1
out="$(verdict "git commit -m 'fix: impl'" "$f")"
case "$out" in
    past-gate1) no "repo-controlled skip → still blocks" "past-gate1 (allow)" ;;
    design-block|too-new-block|expired-block|exhausted-block)
        ok "repo-controlled skip → still blocks ($out)" ;;
    *)
        # May surface as design-block with refusal lead; accept any non-allow.
        if [[ "$out" == past-gate1* ]]; then
            no "repo-controlled skip → still blocks" "$out"
        else
            # design-block is the expected unbound path
            eq "repo-controlled skip → design-block" "$out" "design-block"
        fi
        ;;
esac
git -C "$f" rm --cached -q .claude/skip-design-review.local >/dev/null 2>&1 || true

# (g) Unrecordable lease dir (plain file) → unbound Gate 1 block.
fresh; g="$NEWREPO"
bash "$R" arm "$g/docs/plans/p.md" >/dev/null 2>&1 || true
git -C "$g" add src/impl.py
arm_skip "$g" 120
rm -rf "$g/.claude/.skip-design-review-lease.d"
: >"$g/.claude/.skip-design-review-lease.d"
eq "unrecordable ledger → design-block" \
   "$(verdict "git commit -m 'fix: impl'" "$g")" "design-block"
rm -f "$g/.claude/.skip-design-review-lease.d"

# (h) #685 docs-only carve-out unchanged (no lease needed / not spent).
fresh; h="$NEWREPO"
bash "$R" arm "$h/docs/plans/p.md" >/dev/null 2>&1 || true
git -C "$h" add docs/plans/p.md
arm_skip "$h" 120
before="$(lease_uses "$h")"
eq "docs-only still past Gate 1 (#685)" \
   "$(verdict "git commit -m 'docs: fix'" "$h")" "past-gate1"
after="$(lease_uses "$h")"
if [[ "$before" = "$after" ]]; then
    ok "docs-only does not spend a lease use"
else
    no "docs-only does not spend a lease use" "$before -> $after"
fi

# (i) Valid lease must not whole-hook exit 0 (skip-litmus shape).
# Gate 2 still emits a decision → covered by (a) fall-through. Pin: no
# skip-litmus consumption / no empty stdout allow.
fresh; i="$NEWREPO"
bash "$R" arm "$i/docs/plans/p.md" >/dev/null 2>&1 || true
git -C "$i" add src/impl.py
arm_skip "$i" 120
: >"$i/.claude/skip-litmus.local"
# Age the litmus skip past 30s so IF Gate 1 wrongly routed through it, it would
# consume. We assert the design lease path did not remove it when Gate 1 granted
# via design lease first... Actually skip-litmus is checked BEFORE Gate 1 and
# would exit 0. Remove it — this case asserts design lease alone is not exit 0.
rm -f "$i/.claude/skip-litmus.local"
raw="$(payload "git commit -m 'fix: impl'" "$i" | env HOME="$i/fakehome" \
        XDG_CONFIG_HOME="$i/fakehome/.config" GIT_CONFIG_SYSTEM=/dev/null \
        bash "$GATE" 2>/dev/null)"
case "$raw" in
    "") no "design lease is not unconditional exit 0" "empty stdout" ;;
    *'"decision"'*) ok "design lease is not unconditional exit 0" ;;
    *) no "design lease is not unconditional exit 0" "got: ${raw:0:120}" ;;
esac

echo
echo "── #852 pin: worktree + staged-digest binding ──────────────────────"

# Every negative row asserts BOTH the block AND that no lease use was spent. The
# no-spend half is the point: a binding that never qualified must not consume the
# operator's authorization, or a typo would silently burn one of the 20 uses.
# Raw writer: EXACT bytes, no trailing newline. Used for the EOF control below.
arm_skip_raw(){  # <repo> <age-seconds> <exact-bytes>
    local repo="$1" age="$2" when
    rm -rf "$repo/.claude/.skip-design-review-lease.d"
    mkdir -p "$repo/.claude"
    printf '%s' "$3" >"$repo/.claude/skip-design-review.local"
    when="$(python3 -c 'import sys,time;print(time.time()-float(sys.argv[1]))' "$age")"
    python3 -c 'import os,sys;t=float(sys.argv[2]);os.utime(sys.argv[1],(t,t))' \
        "$repo/.claude/skip-design-review.local" "$when"
}

# Raw gate stdout, so a row can assert WHICH refusal fired rather than only that
# something blocked. Both the lease refusal and the Gate 1 text appear together (the
# refusal is prepended as the lead), so matching "design-block" alone cannot tell the
# binding rejection apart from "there was never a skip file".
raw_out(){
    payload "$1" "$2" | env HOME="$2/fakehome" \
        XDG_CONFIG_HOME="$2/fakehome/.config" GIT_CONFIG_SYSTEM=/dev/null \
        bash "$GATE" 2>/dev/null
}

BIND_LEAD='skip lease: REFUSED — the skip file does not authorize this commit'

# Every negative row asserts three things: it blocks at Gate 1, it does so FOR THE
# BINDING REASON, and it spends no lease use.
pin_refuses(){  # <name> <binding-line> [raw]
    local name="$1" binding="$2" mode="${3:-line}" repo before after out
    fresh; repo="$NEWREPO"
    bash "$R" arm "$repo/docs/plans/p.md" >/dev/null 2>&1 || true
    git -C "$repo" add src/impl.py
    if [[ "$mode" = "raw" ]]; then
        arm_skip_raw "$repo" 120 "$binding"
    else
        arm_skip "$repo" 120 "$binding"
    fi
    before="$(lease_uses "$repo")"
    out="$(raw_out "git commit -m 'fix: impl'" "$repo")"
    after="$(lease_uses "$repo")"
    case "$out" in
        *"$BIND_LEAD"*) ok "$name — refused for the binding reason" ;;
        *"Design review required before committing"*)
            no "$name — refused for the binding reason" "blocked, but NOT on the binding" ;;
        *) no "$name — refused for the binding reason" "got: ${out:0:120}" ;;
    esac
    if [[ "$before" = "$after" ]]; then
        ok "$name — spends no lease use"
    else
        no "$name — spends no lease use" "before=$before after=$after"
    fi
}

# A binding naming a DIFFERENT worktree. Identity is computed by the gate from the
# repo it is about to let commit, so a foreign --absolute-git-dir cannot match.
pin_refuses "other-worktree binding" \
    "PASS-DESIGN /somewhere/else/.git/worktrees/other $(printf 'a%.0s' {1..64})"

# Content-free lease: still valid for the pre-implementation gate, never for commit.
pin_refuses "unbound (empty) skip file" ""

# Malformed shapes: wrong verb, short digest, missing field.
pin_refuses "malformed binding — wrong verb"  "PASS-FF refs/heads/main deadbeef"
pin_refuses "malformed binding — short digest" "PASS-DESIGN /x/.git abc123"
pin_refuses "malformed binding — missing digest" "PASS-DESIGN /x/.git"

# EOF control. The authorization is correct but the file has NO trailing newline. This
# must be ACCEPTED: the claim compares the first line, and whether the operator's editor
# added a final newline is not an authorization question. It is also the exact shape that
# used to make every negative row above pass for the wrong reason.
fresh; eofr="$NEWREPO"
bash "$R" arm "$eofr/docs/plans/p.md" >/dev/null 2>&1 || true
git -C "$eofr" add src/impl.py
arm_skip_raw "$eofr" 120 "PASS-DESIGN $(wt_id "$eofr") $(canon_hash "$eofr")"
eof_before="$(lease_uses "$eofr")"
eq "valid binding without trailing newline → accepted" \
   "$(verdict "git commit -m 'fix: impl'" "$eofr")" "past-gate1"
if [[ "$((eof_before + 1))" = "$(lease_uses "$eofr")" ]]; then
    ok "unterminated valid binding spends exactly one slot"
else
    no "unterminated valid binding spends exactly one slot" "$eof_before -> $(lease_uses "$eofr")"
fi

# LENGTH control: one newline-free 200 KiB line. Must refuse on the binding, spend
# nothing, and return promptly — the read is capped on the Python side, and the shell no
# longer reads the file at all, which is what removed the unbounded-allocation path.
pin_refuses "overlong newline-free payload" "$(python3 -c 'print("x"*204800, end="")')" raw

# FIFO control. Opening a FIFO O_RDONLY blocks until a writer appears, and the claim
# opens it while holding the ledger lock — so without O_NONBLOCK this row HANGS the whole
# suite rather than failing it. The timeout is the assertion: a hang is the regression.
fresh; fifo="$NEWREPO"
bash "$R" arm "$fifo/docs/plans/p.md" >/dev/null 2>&1 || true
git -C "$fifo" add src/impl.py
rm -f "$fifo/.claude/skip-design-review.local"
if mkfifo "$fifo/.claude/skip-design-review.local" 2>/dev/null; then
    fifo_before="$(lease_uses "$fifo")"
    fifo_rc=0
    ( raw_out "git commit -m 'fix: impl'" "$fifo" >"$fifo/out.txt" ) &
    fifo_pid=$!
    ( sleep 20; kill -9 "$fifo_pid" 2>/dev/null ) & fifo_killer=$!
    wait "$fifo_pid" 2>/dev/null || fifo_rc=$?
    kill "$fifo_killer" 2>/dev/null || true
    if [[ "$fifo_rc" -eq 137 ]]; then
        no "FIFO at the skip path does not hang the gate" "killed after 20s — it hung"
    else
        ok "FIFO at the skip path does not hang the gate"
    fi
    case "$(cat "$fifo/out.txt" 2>/dev/null)" in
        *'"decision"'*) ok "FIFO at the skip path still reaches a decision" ;;
        *) no "FIFO at the skip path still reaches a decision" "no decision emitted" ;;
    esac
    if [[ "$fifo_before" = "$(lease_uses "$fifo")" ]]; then
        ok "FIFO at the skip path spends no lease use"
    else
        no "FIFO at the skip path spends no lease use" "$fifo_before -> $(lease_uses "$fifo")"
    fi
else
    printf "  SKIP  FIFO control (mkfifo unavailable)\n"
fi

# Changed candidate: bind to the digest, then stage one more file. The authorization
# is for the diff that was reviewed, so the later diff must not inherit it.
fresh; pc="$NEWREPO"
bash "$R" arm "$pc/docs/plans/p.md" >/dev/null 2>&1 || true
git -C "$pc" add src/impl.py
arm_skip "$pc" 120
printf 'y\n' >"$pc/src/more.py"
git -C "$pc" add src/more.py
pc_before="$(lease_uses "$pc")"
eq "changed staged digest → refused" \
   "$(verdict "git commit -m 'fix: impl'" "$pc")" "design-block"
pc_after="$(lease_uses "$pc")"
if [[ "$pc_before" = "$pc_after" ]]; then
    ok "changed staged digest — spends no lease use"
else
    no "changed staged digest — spends no lease use" "before=$pc_before after=$pc_after"
fi

# Gate 2 is NOT weakened by a valid pin: a granted Gate 1 still hits the marker check,
# and a marker bound to another diff is still rejected and removed.
fresh; g2="$NEWREPO"
bash "$R" arm "$g2/docs/plans/p.md" >/dev/null 2>&1 || true
git -C "$g2" add src/impl.py
arm_skip "$g2" 120
printf '%s' "$(printf '0%.0s' {1..64})" >"$g2/.claude/litmus-passed.local"
g2_out="$(payload "git commit -m 'fix: impl'" "$g2" | env HOME="$g2/fakehome" \
        XDG_CONFIG_HOME="$g2/fakehome/.config" GIT_CONFIG_SYSTEM=/dev/null \
        bash "$GATE" 2>/dev/null)"
case "$g2_out" in
    *"different diff than the one staged"*)
        ok "valid pin still hits Gate 2 — bad marker rejected" ;;
    *"Design review required before committing"*)
        no "valid pin still hits Gate 2 — bad marker rejected" "stopped at Gate 1" ;;
    *) no "valid pin still hits Gate 2 — bad marker rejected" "got: ${g2_out:0:140}" ;;
esac

echo
printf "PASS: %d  FAIL: %d\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
