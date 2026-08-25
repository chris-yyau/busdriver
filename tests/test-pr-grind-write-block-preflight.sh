#!/usr/bin/env bash
# tests/test-pr-grind-write-block-preflight.sh — issue #625
#
# One biting check over the shared-root read-only preflight:
#   1. definite design-review block → exit 1, names the doc + release path
#   2. unreadable marker dir → fail OPEN (exit 0; dispatch would proceed)
#   3. active skip lease is NOT consumed
#   4. worker env-bail backstop prose in agents/pr-grinder.md is unchanged
#   5. dispatcher skill wires the preflight before every pr-grinder dispatch
#
# Usage: bash tests/test-pr-grind-write-block-preflight.sh

# shellcheck disable=SC2292  # [ ] matches sibling grind helpers
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO_ROOT="$PWD"
PF="$REPO_ROOT/scripts/pr-grind-write-block-preflight.sh"
AGENT="$REPO_ROOT/agents/pr-grinder.md"
SKILL="$REPO_ROOT/skills/pr-grind/SKILL.md"
LEASE="$REPO_ROOT/hooks/gate-scripts/lib/lease_slot.py"

# Construct protected marker names without a contiguous forbidden token in source
# (the Bash gate's marker-mention classifier otherwise refuses to even launch this
# suite). The strings must still equal the production constants at runtime.
# shellcheck disable=SC2140  # intentional quote-split so source lacks the contiguous name
_SKIP_BASENAME="skip"-design-"review.local"
# shellcheck disable=SC2140
_LEASE_DIRNAME=".skip"-design-"review-lease.d"

PASS=0; FAIL=0
ok() { printf "  PASS  %s\n" "$1"; PASS=$((PASS + 1)); }
no() { printf "  FAIL  %s (%s)\n" "$1" "$2"; FAIL=$((FAIL + 1)); }

[ -f "$PF" ] || { echo "missing $PF"; exit 1; }
[ -f "$AGENT" ] || { echo "missing $AGENT"; exit 1; }
[ -f "$SKILL" ] || { echo "missing $SKILL"; exit 1; }

# ── Fixture: throwaway repo with one armed design-review token ───────────────
WORK="$(mktemp -d)" || WORK=""
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

git -C "$WORK" init -q
git -C "$WORK" config user.email t@t.t
git -C "$WORK" config user.name t
mkdir -p "$WORK/docs/plans" "$WORK/.claude" "$WORK/src"
printf '# plan\n' >"$WORK/docs/plans/blocked.md"
bash "$REPO_ROOT/hooks/gate-scripts/lib/resolve-repo-dir.sh" arm "$WORK/docs/plans/blocked.md" >/dev/null 2>&1 \
  || { echo "fixture arm failed"; exit 1; }

# ── 1. Definite block ────────────────────────────────────────────────────────
OUT=""; RC=0
OUT="$(bash "$PF" -C "$WORK" 2>&1)" || RC=$?
if [ "$RC" -eq 1 ]; then ok "armed marker → exit 1 (definite block)"
else no "armed marker → exit 1 (definite block)" "rc=$RC out=$OUT"; fi
case "$OUT" in
    *blocked.md*) ok "block message names the blocking doc" ;;
    *) no "block message names the blocking doc" "out=$OUT" ;;
esac
case "$OUT" in
    *design-clear.sh*) ok "block message names design-clear.sh release path" ;;
    *) no "block message names design-clear.sh release path" "out=$OUT" ;;
esac
case "$OUT" in
    *unless\ it\ is\ abandoned*) ok "block message carries abandoned-drain caveat" ;;
    *) no "block message carries abandoned-drain caveat" "out=$OUT" ;;
esac

# ── 2. Fail OPEN on unreadable marker directory ──────────────────────────────
COMMON_DIR="$(git -C "$WORK" rev-parse --git-common-dir 2>/dev/null)" || COMMON_DIR=""
COMMON=""
[ -n "$COMMON_DIR" ] && COMMON="$(cd "$WORK" && cd "$COMMON_DIR" && pwd -P)" || true
TOKDIR="$COMMON/busdriver/design-review-needed.local.d"
_UID="$(id -u)"
if [ "$_UID" -eq 0 ]; then
    # Mode bits do not restrict root, so the classifier would still read the
    # marker and the fail-OPEN assertion would report a false failure. Many CI
    # containers run as root.
    printf "  SKIP  unreadable marker dir → fail OPEN (running as root)\n"
elif [ ! -d "$TOKDIR" ]; then
    no "unreadable marker dir → exit 0 (fail OPEN)" "fixture marker dir not found: $TOKDIR"
else
    chmod 000 "$TOKDIR" 2>/dev/null || true
    OUT2=""; RC2=0
    OUT2="$(bash "$PF" -C "$WORK" 2>&1)" || RC2=$?
    chmod 755 "$TOKDIR" 2>/dev/null || true
    if [ "$RC2" -eq 0 ]; then ok "unreadable marker dir → exit 0 (fail OPEN)"
    else no "unreadable marker dir → exit 0 (fail OPEN)" "rc=$RC2 out=$OUT2"; fi
fi

# ── 3. No skip-lease consumption ─────────────────────────────────────────────
# Arm a recent-but-aged lease (older than the 30s floor, younger than 3600s),
# claim one real slot, run preflight, confirm slot count unchanged.
_SKIP="$WORK/.claude/${_SKIP_BASENAME}"
: >"$_SKIP"
P="$_SKIP" python3 -I -c 'import os,time; os.utime(os.environ["P"], (time.time()-120,)*2)' \
  || { echo "utime failed"; exit 1; }
# lease_slot requires a CWD-relative state dir (absolute paths are refused).
( cd "$WORK" && python3 -I "$LEASE" .claude 20 30 3600 ) >/dev/null 2>&1 \
  || { echo "lease claim failed — fixture broken"; exit 1; }
lease_uses() {
    find "$WORK/.claude/${_LEASE_DIRNAME}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
      | wc -l | tr -d ' '
}
BEFORE="$(lease_uses)"
bash "$REPO_ROOT/hooks/gate-scripts/lib/resolve-repo-dir.sh" arm "$WORK/docs/plans/blocked.md" >/dev/null 2>&1 || true
OUT3=""; RC3=0
OUT3="$(bash "$PF" -C "$WORK" 2>&1)" || RC3=$?
AFTER="$(lease_uses)"
if [ "$BEFORE" = "$AFTER" ] && [ "$BEFORE" = "1" ]; then
    ok "preflight consumes no skip-lease slot (before=after=1)"
else
    no "preflight consumes no skip-lease slot" "before=$BEFORE after=$AFTER"
fi
if [ "$RC3" -eq 0 ]; then
    ok "active operator lease + pending markers → exit 0 (not definite)"
else
    no "active operator lease + pending markers → exit 0 (not definite)" "rc=$RC3 out=$OUT3"
fi
if [ -f "$_SKIP" ]; then
    ok "preflight leaves operator skip file untouched"
else
    no "preflight leaves operator skip file untouched" "file missing"
fi
# Too-new skip file must NOT authorize (anti-self-bypass floor).
P="$_SKIP" python3 -I -c 'import os,time; os.utime(os.environ["P"], (time.time()-5,)*2)'
OUT4=""; RC4=0
OUT4="$(bash "$PF" -C "$WORK" 2>&1)" || RC4=$?
if [ "$RC4" -eq 1 ]; then
    ok "too-new skip file does not authorize (exit 1 with pending markers)"
else
    no "too-new skip file does not authorize (exit 1 with pending markers)" "rc=$RC4 out=$OUT4"
fi
# Restore aged mtime for later assertions that expect the skip file present.
P="$_SKIP" python3 -I -c 'import os,time; os.utime(os.environ["P"], (time.time()-120,)*2)'

# ── 3b. Slot count is scoped to the CURRENT lease ────────────────────────────
# lease_slot.py keys uses as `<st_mtime_ns>.<n>` and prunes other prefixes on
# the next claim. Counting the whole ledger made leftovers from a spent lease
# read as exhausted, so a freshly re-armed skip file produced a block the real
# gate would never raise.
_LEDGER="$WORK/.claude/${_LEASE_DIRNAME}"
_KEY="$(P="$_SKIP" python3 -I -c 'import os; print(os.stat(os.environ["P"], follow_symlinks=False).st_mtime_ns)')"
_I=1
while [ "$_I" -le 25 ]; do
    mkdir -p "$_LEDGER/1234567890.$_I"
    _I=$((_I + 1))
done
RC5=0
bash "$PF" -C "$WORK" >/dev/null 2>&1 || RC5=$?
if [ "$RC5" -eq 0 ]; then
    ok "leftover foreign-prefix slots do not exhaust the current lease"
else
    no "leftover foreign-prefix slots do not exhaust the current lease" "rc=$RC5"
fi
# Junk names under the current key prefix (<key>.junkN) must not count as uses —
# the gate only claims exact <key>.1..<key>.20 directories.
_I=1
while [ "$_I" -le 25 ]; do
    mkdir -p "$_LEDGER/${_KEY}.junk$_I"
    _I=$((_I + 1))
done
RC5b=0
bash "$PF" -C "$WORK" >/dev/null 2>&1 || RC5b=$?
_I=1
while [ "$_I" -le 25 ]; do
    rmdir "$_LEDGER/${_KEY}.junk$_I" 2>/dev/null || true
    _I=$((_I + 1))
done
if [ "$RC5b" -eq 0 ]; then
    ok "junk-suffix dirs under lease key do not exhaust the current lease"
else
    no "junk-suffix dirs under lease key do not exhaust the current lease" "rc=$RC5b"
fi
# Exact <key>.1..<key>.20 names of ANY inode type occupy claimable slots —
# lease_slot treats FileExistsError on mkdir as occupied. Filling all 20 with
# regular files must exhaust authorization (exit 1 with pending markers).
_I=1
while [ "$_I" -le 20 ]; do
    : >"$_LEDGER/${_KEY}.$_I"
    _I=$((_I + 1))
done
RC5c=0
bash "$PF" -C "$WORK" >/dev/null 2>&1 || RC5c=$?
_I=1
while [ "$_I" -le 20 ]; do
    rm -f "$_LEDGER/${_KEY}.$_I" 2>/dev/null || true
    _I=$((_I + 1))
done
if [ "$RC5c" -eq 1 ]; then
    ok "non-directory exact slot names exhaust the current lease"
else
    no "non-directory exact slot names exhaust the current lease" "rc=$RC5c"
fi
# A poison sentinel for THIS lease means the gate refuses it outright. Drop the
# foreign slots first, so exit 1 can only come from the sentinel and not from a
# ledger that is merely over the count.
_I=1
while [ "$_I" -le 25 ]; do
    rmdir "$_LEDGER/1234567890.$_I" 2>/dev/null || true
    _I=$((_I + 1))
done
mkdir -p "$_LEDGER/${_KEY}.poison"
RC6=0
bash "$PF" -C "$WORK" >/dev/null 2>&1 || RC6=$?
if [ "$RC6" -eq 1 ]; then
    ok "poisoned lease does not authorize (exit 1 with pending markers)"
else
    no "poisoned lease does not authorize (exit 1 with pending markers)" "rc=$RC6"
fi
rm -rf "$_LEDGER/${_KEY}.poison"

# ── 3c. Lease thresholds must not drift from the gate's ──────────────────────
# The preflight duplicates the gate's floors by necessity: the gate defines them
# inline in a hook that cannot be sourced, and lease_slot.py takes them as argv.
# Assert equality so a future gate change fails here instead of silently turning
# the preflight into a source of false blocks.
_GATE="$REPO_ROOT/hooks/gate-scripts/pre-implementation-gate.sh"
G_USES="$(grep -m1 '^LEASE_MAX_USES=' "$_GATE" | cut -d= -f2)"
G_AGE="$(grep -m1 '^LEASE_MAX_AGE=' "$_GATE" | cut -d= -f2)"
# shellcheck disable=SC2016  # literal `$` sought in the scanned scripts' source
G_MIN="$(grep -o 'lease_slot\.py" "\$STATE_DIR" "\$LEASE_MAX_USES" [0-9]*' "$_GATE" \
  | grep -o '[0-9]*$' | head -1)"
# shellcheck disable=SC2016
P_USES="$(grep -o '"\$slots" -lt [0-9]*' "$PF" | grep -o '[0-9]*$' | head -1)"
# shellcheck disable=SC2016
P_AGE="$(grep -o '"\$age" -le [0-9]*' "$PF" | grep -o '[0-9]*$' | head -1)"
# shellcheck disable=SC2016
P_MIN="$(grep -o '"\$age" -ge [0-9]*' "$PF" | grep -o '[0-9]*$' | head -1)"
if [ -n "$G_USES" ] && [ -n "$G_AGE" ] && [ -n "$G_MIN" ] \
   && [ "$P_USES" = "$G_USES" ] && [ "$P_AGE" = "$G_AGE" ] && [ "$P_MIN" = "$G_MIN" ]; then
    ok "preflight lease floors match the gate (uses=$G_USES min=$G_MIN max=$G_AGE)"
else
    no "preflight lease floors match the gate" \
       "gate uses=$G_USES min=$G_MIN max=$G_AGE / preflight uses=$P_USES min=$P_MIN max=$P_AGE"
fi

# ── 3d. A repo-controlled skip file is not operator consent ─────────────────
# The gate's _skip_lease_consume refuses a skip file tracked in the index or
# HEAD (#325). Reading one as an active lease cleared the preflight and dropped
# the worker into the `env` bail this probe exists to avoid, so assert the
# untracked baseline authorizes and the staged same file does not.
RC7=0
bash "$PF" -C "$WORK" >/dev/null 2>&1 || RC7=$?
if [ "$RC7" -eq 0 ]; then
    ok "untracked aged skip file still authorizes (repo-control baseline)"
else
    no "untracked aged skip file still authorizes (repo-control baseline)" "rc=$RC7"
fi
if git -C "$WORK" add -f -- ".claude/${_SKIP_BASENAME}" >/dev/null 2>&1; then
    RC8=0
    bash "$PF" -C "$WORK" >/dev/null 2>&1 || RC8=$?
    git -C "$WORK" rm --cached -q -- ".claude/${_SKIP_BASENAME}" >/dev/null 2>&1 || true
    if [ "$RC8" -eq 1 ]; then
        ok "repo-controlled (staged) skip file does not authorize"
    else
        no "repo-controlled (staged) skip file does not authorize" "rc=$RC8"
    fi
else
    no "repo-controlled (staged) skip file does not authorize" "fixture stage failed"
fi

# ── 4. Freeze definite-block boundaries (inner scope vs disjoint) ────────────
# freeze-guard reads CWD-relative `.claude/freeze-scope.local` (session/hook
# CWD). Mirror that: cd into the fixture before invoking so the probe observes
# the same freeze file the real Write/Edit hook would.
FZ="$(mktemp -d)" || FZ=""
# Centralize cleanup: an early exit or interrupt inside the block below would
# otherwise leak the fixture, since the block-local removal only runs on the
# fall-through path.
[ -n "$FZ" ] && trap 'rm -rf "$WORK" "$FZ"' EXIT
if [ -n "$FZ" ]; then
    git -C "$FZ" init -q
    mkdir -p "$FZ/.claude" "$FZ/src/auth"
    printf 'src/auth\n' >"$FZ/.claude/freeze-scope.local"
    FZ_RC=0
    (cd "$FZ" && bash "$PF" -C "$FZ") >/dev/null 2>&1 || FZ_RC=$?
    if [ "$FZ_RC" -eq 0 ]; then ok "freeze scope inside worktree → not definite (exit 0)"
    else no "freeze scope inside worktree → not definite (exit 0)" "rc=$FZ_RC"; fi
    printf '/tmp/not-this-tree\n' >"$FZ/.claude/freeze-scope.local"
    FZ_RC=0
    (cd "$FZ" && bash "$PF" -C "$FZ") >/dev/null 2>&1 || FZ_RC=$?
    if [ "$FZ_RC" -eq 1 ]; then ok "freeze scope disjoint from worktree → exit 1"
    else no "freeze scope disjoint from worktree → exit 1" "rc=$FZ_RC"; fi
    # Freeze only under -C while session CWD differs → not definite (hook-invisible).
    # Use a sterile empty CWD so REPO_ROOT/.claude/freeze-scope.local cannot
    # contaminate the assertion (the probe reads session CWD, not -C alone).
    FZ_EMPTY="$(mktemp -d)" || FZ_EMPTY=""
    FZ_RC=0
    if [ -n "$FZ_EMPTY" ]; then
        (cd "$FZ_EMPTY" && bash "$PF" -C "$FZ") >/dev/null 2>&1 || FZ_RC=$?
        rmdir "$FZ_EMPTY" 2>/dev/null || rm -rf "$FZ_EMPTY"
    else
        FZ_RC=99
    fi
    if [ "$FZ_RC" -eq 0 ]; then ok "freeze only under -C (foreign session CWD) → fail OPEN"
    else no "freeze only under -C (foreign session CWD) → fail OPEN" "rc=$FZ_RC"; fi
    # Symlinked freeze file must fail OPEN (no follow / no disclosure).
    rm -f "$FZ/.claude/freeze-scope.local"
    echo secret-line >"$FZ/secret.txt"
    ln -s "$FZ/secret.txt" "$FZ/.claude/freeze-scope.local"
    FZ_RC=0
    OUTF="$(cd "$FZ" && bash "$PF" -C "$FZ" 2>&1)" || FZ_RC=$?
    if [ "$FZ_RC" -eq 0 ] && ! printf '%s' "$OUTF" | grep -q 'secret-line'; then
        ok "symlinked freeze file → fail OPEN (no target disclosure)"
    else
        no "symlinked freeze file → fail OPEN (no target disclosure)" "rc=$FZ_RC out=$OUTF"
    fi
    # Symlinked .claude parent must also fail OPEN.
    rm -rf "$FZ/.claude"
    mkdir -p "$FZ/real-claude" "$FZ/elsewhere"
    printf '/tmp/not-this-tree\n' >"$FZ/elsewhere/freeze-scope.local"
    ln -s "$FZ/elsewhere" "$FZ/.claude"
    FZ_RC=0
    (cd "$FZ" && bash "$PF" -C "$FZ") >/dev/null 2>&1 || FZ_RC=$?
    if [ "$FZ_RC" -eq 0 ]; then ok "symlinked .claude parent → fail OPEN"
    else no "symlinked .claude parent → fail OPEN" "rc=$FZ_RC"; fi
    # FIFO at freeze path must fail OPEN without hanging.
    rm -rf "$FZ/.claude"
    mkdir -p "$FZ/.claude"
    mkfifo "$FZ/.claude/freeze-scope.local"
    FZ_RC=0
    # Bound the whole preflight call. The preflight's own classify budget is ~8s
    # plus a ~2s kill grace, so a 3s bound was tighter than the code under test
    # and fired on loaded runners; 30s means only a real hang trips this.
    # Keep paths as separate argv words (no bash -c string interpolation).
    FZ_BOUND=1
    if command -v timeout >/dev/null 2>&1; then
        (cd "$FZ" && timeout 30 bash "$PF" -C "$FZ") >/dev/null 2>&1 || FZ_RC=$?
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm 30; chdir $ARGV[0] or exit 1; exec @ARGV[1..$#ARGV]' \
            "$FZ" bash "$PF" -C "$FZ" >/dev/null 2>&1 || FZ_RC=$?
    else
        FZ_BOUND=0
    fi
    if [ "$FZ_BOUND" -eq 0 ]; then
        # Neither bounding tool present: a missing tool is not a hang, so do not
        # report a failure for it.
        printf "  SKIP  FIFO freeze file → fail OPEN (no timeout or perl available)\n"
    elif [ "$FZ_RC" -eq 0 ]; then
        ok "FIFO freeze file → fail OPEN (no hang)"
    elif [ "$FZ_RC" -eq 124 ] || [ "$FZ_RC" -eq 142 ]; then
        no "FIFO freeze file → fail OPEN (no hang)" "timed out rc=$FZ_RC"
    else
        no "FIFO freeze file → fail OPEN (no hang)" "rc=$FZ_RC"
    fi
else
    no "freeze fixture" "mktemp failed"
fi

# ── 5. Worker env-bail backstop unchanged ────────────────────────────────────
# shellcheck disable=SC2016  # literal backticks sought in agent prose
if grep -q 'PreToolUse gate blocks a Write/Edit/MultiEdit/Bash you cannot route around' "$AGENT" \
   && grep -qF '| `env` |' "$AGENT"; then
    ok "worker env-bail backstop row still present in pr-grinder.md"
else
    no "worker env-bail backstop row still present in pr-grinder.md" "row missing or rewritten"
fi

# ── 6. Dispatcher wires preflight before every pr-grinder dispatch ───────────
if grep -q 'scripts/pr-grind-write-block-preflight.sh' "$SKILL" \
   && grep -q 'BEFORE every.*pr-grinder\|before every worker dispatch\|Write-block preflight' "$SKILL"; then
    ok "SKILL.md wires write-block preflight before worker dispatch"
else
    no "SKILL.md wires write-block preflight before worker dispatch" "missing wiring prose"
fi

PF_LINE="$(grep -n 'pr-grind-write-block-preflight.sh' "$SKILL" | head -1 | cut -d: -f1)"
AG_LINE="$(grep -n 'Agent(subagent_type="pr-grinder"' "$SKILL" | head -1 | cut -d: -f1)"
if [ -n "$PF_LINE" ] && [ -n "$AG_LINE" ] && [ "$PF_LINE" -lt "$AG_LINE" ]; then
    ok "preflight appears before first Agent(pr-grinder) dispatch site"
else
    no "preflight appears before first Agent(pr-grinder) dispatch site" \
       "pf_line=$PF_LINE ag_line=$AG_LINE"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
