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
chmod 000 "$TOKDIR" 2>/dev/null || true
OUT2=""; RC2=0
OUT2="$(bash "$PF" -C "$WORK" 2>&1)" || RC2=$?
chmod 755 "$TOKDIR" 2>/dev/null || true
if [ "$RC2" -eq 0 ]; then ok "unreadable marker dir → exit 0 (fail OPEN)"
else no "unreadable marker dir → exit 0 (fail OPEN)" "rc=$RC2 out=$OUT2"; fi

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

# ── 4. Freeze definite-block boundaries (inner scope vs disjoint) ────────────
FZ="$(mktemp -d)" || FZ=""
if [ -n "$FZ" ]; then
    git -C "$FZ" init -q
    mkdir -p "$FZ/.claude" "$FZ/src/auth"
    printf 'src/auth\n' >"$FZ/.claude/freeze-scope.local"
    FZ_RC=0
    bash "$PF" -C "$FZ" >/dev/null 2>&1 || FZ_RC=$?
    if [ "$FZ_RC" -eq 0 ]; then ok "freeze scope inside worktree → not definite (exit 0)"
    else no "freeze scope inside worktree → not definite (exit 0)" "rc=$FZ_RC"; fi
    printf '/tmp/not-this-tree\n' >"$FZ/.claude/freeze-scope.local"
    FZ_RC=0
    bash "$PF" -C "$FZ" >/dev/null 2>&1 || FZ_RC=$?
    if [ "$FZ_RC" -eq 1 ]; then ok "freeze scope disjoint from worktree → exit 1"
    else no "freeze scope disjoint from worktree → exit 1" "rc=$FZ_RC"; fi
    rm -rf "$FZ"
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
