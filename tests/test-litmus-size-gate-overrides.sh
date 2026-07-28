#!/usr/bin/env bash
# shellcheck disable=SC2016  # awk/grep patterns intentionally contain literal $ { }
# shellcheck disable=SC2310,SC2312  # test helpers use command substitution in assertions; masking return values is by design
# tests/test-litmus-size-gate-overrides.sh — guard for the litmus commit-mode
# size gate's three independent triggers (#514).
#
# #514: MAX_TOTAL_LINES_CEILING was a hardcoded literal while its two siblings
# had LITMUS_MAX_* overrides. A merge commit's diff-vs-HEAD is by definition
# everything the merge brings in, so it cannot be subdivided and neither sibling
# override reaches the raw-lines trigger — the only exit was skip-litmus.local,
# which skips the conflict resolutions too (the one genuinely new part of a merge).
#
# Second property pinned here: every threshold must be numeric-validated. A
# non-numeric value makes `[ N -gt "$MAX" ]` error INSIDE its `if` condition,
# which evaluates false — and `set -e` does not fire in a condition context — so
# the threshold silently fails OPEN. LITMUS_MAX_STAGED_FILES shipped unvalidated.
#
# Two layers: (1) golden-grep anchored to the real assignment lines proves the
# wiring is present; (2) an EXECUTABLE pass extracts the real assignment+
# validation block from source, evals it with seeded env values, and then runs
# the REAL comparison — so a reverted literal or a dropped `case` actually fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOOP="$SCRIPT_DIR/skills/litmus/scripts/run-review-loop.sh"

passed=0; failed=0
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }

assert_present() {  # <file> <ere> <ok-msg> <fail-msg>
  if grep -qE "$2" "$1"; then ok "$3"; else fail "$4"; fi
}
assert_absent() {   # <file> <ere> <ok-msg> <fail-msg>
  if grep -qE "$2" "$1"; then fail "$4"; else ok "$3"; fi
}
eq() {  # <got> <want> <label>
  if [[ "$1" == "$2" ]]; then ok "$3 → $1"; else fail "$3 → got '$1', want '$2'"; fi
}

if [[ ! -f "$LOOP" ]]; then
  fail "missing $LOOP"; echo "Results: $passed passed, $failed failed"; exit 1
fi

# ── Layer 1: anchored wiring ──────────────────────────────────────────
assert_absent  "$LOOP" '^\s*MAX_TOTAL_LINES_CEILING=2000\s*$' \
  "raw-lines ceiling is no longer a bare literal" \
  "MAX_TOTAL_LINES_CEILING reverted to a hardcoded literal (regressed #514)"
assert_present "$LOOP" 'MAX_TOTAL_LINES_CEILING="\$\{LITMUS_MAX_TOTAL_LINES:-2000\}"' \
  "raw-lines ceiling reads LITMUS_MAX_TOTAL_LINES" \
  "raw-lines ceiling has no LITMUS_MAX_TOTAL_LINES override (#514)"
for v in LITMUS_MAX_WEIGHTED_LINES LITMUS_MAX_TOTAL_LINES LITMUS_MAX_STAGED_FILES; do
  assert_present "$LOOP" "$v='\\\$" \
    "$v is numeric-validated" \
    "$v has no numeric validation — non-numeric fails the size gate OPEN"
done
assert_present "$LOOP" 'LITMUS_MAX_TOTAL_LINES=\$\(\(ADDITION_LINES \+ DELETION_LINES \+ 100\)\)' \
  "TOO_LARGE message advertises the total-lines override" \
  "TOO_LARGE message does not tell the operator about LITMUS_MAX_TOTAL_LINES"

# ── Layer 2: execute the REAL assignment + validation block ───────────
# Extract from the first threshold assignment through the third `esac`.
thresholds() {  # <weighted> <total> <staged> -> "<weighted> <total> <staged>"
  local LITMUS_MAX_WEIGHTED_LINES="$1" LITMUS_MAX_TOTAL_LINES="$2" LITMUS_MAX_STAGED_FILES="$3"
  local MAX_WEIGHTED_LINES MAX_TOTAL_LINES_CEILING MAX_STAGED_FILES code
  export LITMUS_MAX_WEIGHTED_LINES LITMUS_MAX_TOTAL_LINES LITMUS_MAX_STAGED_FILES
  # Bounded on both ends: EFFECTIVE_MAX is the first line after the threshold
  # block, so a source that lost an `esac` extracts nothing instead of eval'ing
  # unrelated gate code with unbound variables.
  code="$(awk '/MAX_WEIGHTED_LINES="\$\{LITMUS_MAX_WEIGHTED_LINES:-800\}"/{p=1} p&&/^  EFFECTIVE_MAX=/{exit} p{print} p&&/^  esac$/{n++; if(n==3) exit}' "$LOOP")"
  [[ -z "$code" ]] && { echo "EXTRACT-FAILED"; return 0; }
  eval "$code" >/dev/null
  echo "$MAX_WEIGHTED_LINES $MAX_TOTAL_LINES_CEILING $MAX_STAGED_FILES"
}

eq "$(thresholds 800 2000 8)"    "800 2000 8"    "defaults pass through"
eq "$(thresholds 4000 6000 40)"  "4000 6000 40"  "all three overrides honoured"
eq "$(thresholds abc abc abc)"   "800 2000 8"    "non-numeric falls back to defaults"
eq "$(thresholds 800 -5 8)"      "800 2000 8"    "negative is non-numeric → default"
eq "$(thresholds 800 3.5 8)"     "800 2000 8"    "decimal is non-numeric → default"

# ── Layer 2b: the fail-open the validation exists to prevent ──────────
# Run the REAL comparison shape against a garbage override. Without the `case`
# guard, `[ -gt ]` errors, the `if` evaluates false, and the gate never fires.
gate_fires() {  # <observed> <threshold> -> fired|SILENTLY-SKIPPED
  local observed="$1" threshold="$2"
  if [ "$observed" -gt "$threshold" ] 2>/dev/null; then echo "fired"; else echo "SILENTLY-SKIPPED"; fi
}
read -r _w t s <<<"$(thresholds 800 abc abc)"
eq "$(gate_fires 5000 "$t")" "fired" "garbage LITMUS_MAX_TOTAL_LINES still trips the ceiling"
eq "$(gate_fires 40 "$s")"   "fired" "garbage LITMUS_MAX_STAGED_FILES still trips the file count"

# Sanity: the unguarded shape really does fail open (proves the guard above is
# testing something real, not a tautology).
eq "$(gate_fires 5000 abc)" "SILENTLY-SKIPPED" "unvalidated threshold fails OPEN (the bug being guarded)"

echo ""
echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
