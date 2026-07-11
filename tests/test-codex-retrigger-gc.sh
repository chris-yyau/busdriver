#!/usr/bin/env bash
# tests/test-codex-retrigger-gc.sh — verifies scripts/codex-retrigger-gc.sh, the
# merge-path prune of a PR's codex-retrigger idempotency markers (issue #327).
#
# The GC resolves STATE_DIR the SAME way codex-retrigger.sh:69 writes it —
# `${BUSDRIVER_STATE_DIR:-.claude}` relative to the invocation CWD — so we exercise
# in-place (default .claude), relative-override, and absolute-override forms, plus
# the pr1-vs-pr10 boundary and the bad/empty-PR no-ops.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GC="$SCRIPT_DIR/scripts/codex-retrigger-gc.sh"
BASH_BIN="$(command -v bash)"

passed=0; failed=0
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }

[ -f "$GC" ] || { fail "missing $GC"; echo "Results: $passed passed, $failed failed"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mk() { mkdir -p "$(dirname "$1")"; : > "$1"; }
marker() { printf '%s/.pr-grind-codex-retriggered-pr%s-%s.local' "$1" "$2" "$3"; }

# 1. in-place default (.claude relative to CWD): prune pr123, keep pr456
D="$TMP/inplace"; mkdir -p "$D/.claude"
mk "$(marker "$D/.claude" 123 aaaaaaaa)"
mk "$(marker "$D/.claude" 123 bbbbbbbb)"
mk "$(marker "$D/.claude" 456 cccccccc)"
RC=0; ( cd "$D" && "$BASH_BIN" "$GC" 123 ) || RC=$?
if [ "$RC" = 0 ] \
   && [ ! -e "$(marker "$D/.claude" 123 aaaaaaaa)" ] \
   && [ ! -e "$(marker "$D/.claude" 123 bbbbbbbb)" ] \
   && [ -e "$(marker "$D/.claude" 456 cccccccc)" ]; then
  ok "in-place: pruned both pr123 markers, kept pr456 (exit 0)"
else
  fail "in-place: RC=$RC $(ls "$D/.claude")"
fi

# 2. relative BUSDRIVER_STATE_DIR override (worktree-style)
D="$TMP/relover"; mkdir -p "$D/state"
mk "$(marker "$D/state" 77 deadbeef)"
RC=0; ( cd "$D" && BUSDRIVER_STATE_DIR="state" "$BASH_BIN" "$GC" 77 ) || RC=$?
[ "$RC" = 0 ] && [ ! -e "$(marker "$D/state" 77 deadbeef)" ] \
  && ok "relative BUSDRIVER_STATE_DIR: pruned (exit 0)" \
  || fail "relative override: RC=$RC $(ls "$D/state")"

# 3. absolute BUSDRIVER_STATE_DIR UNDER the worktree → pruned
D="$TMP/absunder"; A="$D/state"; mkdir -p "$A"
mk "$(marker "$A" 88 cafebabe)"
RC=0; ( cd "$D" && BUSDRIVER_STATE_DIR="$A" "$BASH_BIN" "$GC" 88 ) || RC=$?
[ "$RC" = 0 ] && [ ! -e "$(marker "$A" 88 cafebabe)" ] \
  && ok "absolute BUSDRIVER_STATE_DIR under worktree → pruned (exit 0)" \
  || fail "absolute under: RC=$RC $(ls "$A")"

# 3b. absolute BUSDRIVER_STATE_DIR OUTSIDE the worktree → refused, marker KEPT (#325
#     containment: a redirected state dir must not let the GC delete another repo's markers)
OUT="$TMP/outside"; WT="$TMP/wt"; mkdir -p "$OUT" "$WT"
mk "$(marker "$OUT" 88 cafebabe)"
RC=0; ( cd "$WT" && BUSDRIVER_STATE_DIR="$OUT" "$BASH_BIN" "$GC" 88 ) || RC=$?
[ "$RC" = 0 ] && [ -e "$(marker "$OUT" 88 cafebabe)" ] \
  && ok "absolute state dir OUTSIDE worktree → refused, marker kept (exit 0)" \
  || fail "outside refuse: RC=$RC kept=$([ -e "$(marker "$OUT" 88 cafebabe)" ] && echo yes || echo no)"

# 4. pr1 must NOT match pr10 (the trailing '-' guard)
D="$TMP/boundary"; mkdir -p "$D/.claude"
mk "$(marker "$D/.claude" 1  11111111)"
mk "$(marker "$D/.claude" 10 22222222)"
RC=0; ( cd "$D" && "$BASH_BIN" "$GC" 1 ) || RC=$?
if [ "$RC" = 0 ] \
   && [ ! -e "$(marker "$D/.claude" 1 11111111)" ] \
   && [ -e "$(marker "$D/.claude" 10 22222222)" ]; then
  ok "boundary: gc 1 pruned pr1 but kept pr10"
else
  fail "boundary: RC=$RC $(ls "$D/.claude")"
fi

# 5. non-numeric PR → no-op, markers untouched, exit 0
D="$TMP/badpr"; mkdir -p "$D/.claude"
mk "$(marker "$D/.claude" 5 99999999)"
RC=0; ( cd "$D" && "$BASH_BIN" "$GC" "abc" ) || RC=$?
[ "$RC" = 0 ] && [ -e "$(marker "$D/.claude" 5 99999999)" ] \
  && ok "non-numeric PR → no-op (exit 0, markers untouched)" \
  || fail "bad PR: RC=$RC"

# 6. empty PR arg → no-op, exit 0
RC=0; ( cd "$TMP" && "$BASH_BIN" "$GC" ) || RC=$?
[ "$RC" = 0 ] && ok "empty PR arg → no-op (exit 0)" || fail "empty PR: RC=$RC"

# 7. no markers present → clean no-op, exit 0
D="$TMP/nomarkers"; mkdir -p "$D/.claude"
RC=0; ( cd "$D" && "$BASH_BIN" "$GC" 123 ) || RC=$?
[ "$RC" = 0 ] && ok "no matching markers → clean no-op (exit 0)" || fail "no markers: RC=$RC"

echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
