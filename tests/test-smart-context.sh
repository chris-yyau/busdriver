#!/bin/bash
# Regression tests for smart-context.sh — guard against the large / long-line
# diff hang.
#
# Root cause (fixed): _extract_changed_functions ran backtracking-prone Python
# regex (re.finditer) over the FULL raw diff with no size cap and no timeout.
# A 770 KB single-file data diff (minified JSON, NDJSON, lockfiles, base64)
# stalled the whole review pipeline before the reviewer ever ran, and the
# documented LITMUS_SKIP_CONTEXT flag never reached the hook-spawned script.
#
# Fix: byte + max-line-length guard plus a fail-open timeout. Smart context is
# enrichment, not a correctness gate — skipping it on a pathological diff loses
# nothing the reviewer depends on.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=../skills/litmus/scripts/lib/smart-context.sh
source "$SCRIPT_DIR/skills/litmus/scripts/lib/smart-context.sh"
# Sourcing turns on `set -e`; disable so assertions can inspect exit codes.
set +e

passed=0
failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

# Hermetic temp repo (caller-grep helpers resolve git toplevel).
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT
cd "$TMPDIR_TEST" || exit 1
git init -q

# ── Case 1: a single very long line trips the line-length guard ───────────
# 5000-char added line that ALSO contains an extractable declaration.
# Pre-fix: extractor returns "bigDataFn". Post-fix: guard skips → empty.
LONG_LINE=$(printf 'x%.0s' $(seq 1 5000))
LONG_DIFF=$(printf '%s\n' \
  '@@ -1,1 +1,2 @@' \
  "+function bigDataFn(){ var d=\"$LONG_LINE\"; }")
start=$SECONDS
OUT=$(_extract_changed_functions "$LONG_DIFF")
elapsed=$((SECONDS - start))
if [ -z "$OUT" ]; then
  ok "Long-line diff skips function extraction (fail-open, empty)"
else
  fail "Long-line diff still extracted functions: $OUT"
fi
if [ "$elapsed" -lt 20 ]; then
  ok "Long-line extraction returns promptly (${elapsed}s)"
else
  fail "Long-line extraction took too long (${elapsed}s)"
fi

# ── Case 2: an oversized diff trips the byte-size guard ───────────────────
# >256 KiB built from many SHORT lines (so only the byte cap can trip, not the
# line cap). Each line carries a declaration. Pre-fix: extracts names.
BIG_DIFF=$( { echo '@@ -1,1 +1,20000 @@'; \
  seq 1 18000 | awk '{print "+function genFn" $1 "(){ return " $1 "; }"}'; } )
start=$SECONDS
OUT2=$(_extract_changed_functions "$BIG_DIFF")
elapsed=$((SECONDS - start))
if [ -z "$OUT2" ]; then
  ok "Oversized diff (>256 KiB) skips extraction (fail-open, empty)"
else
  fail "Oversized diff still extracted functions (first: $(echo "$OUT2" | head -1))"
fi
if [ "$elapsed" -lt 20 ]; then
  ok "Oversized-diff extraction returns promptly (${elapsed}s)"
else
  fail "Oversized-diff extraction took too long (${elapsed}s)"
fi

# ── Case 3: a normal diff still extracts (happy path preserved) ───────────
NORMAL_DIFF=$(printf '%s\n' \
  '@@ -1,3 +1,4 @@' \
  '+function calcTotal(items) {' \
  '+  return items.length;' \
  '+}')
OUT3=$(_extract_changed_functions "$NORMAL_DIFF")
if echo "$OUT3" | grep -q "calcTotal"; then
  ok "Normal diff still extracts function names"
else
  fail "Normal diff extraction broke — expected calcTotal, got: $OUT3"
fi

# ── Case 4: collect_smart_context fails open (clean exit, no hang) ─────────
start=$SECONDS
collect_smart_context "$LONG_DIFF" "data/big.json" >/dev/null 2>&1
rc=$?
elapsed=$((SECONDS - start))
if [ "$rc" -eq 0 ] && [ "$elapsed" -lt 20 ]; then
  ok "collect_smart_context returns cleanly on pathological diff (${elapsed}s, rc=$rc)"
else
  fail "collect_smart_context misbehaved (rc=$rc, ${elapsed}s)"
fi

# ── Case 5: LITMUS_SKIP_CONTEXT=1 still short-circuits ────────────────────
SKIP_OUT=$(LITMUS_SKIP_CONTEXT=1 collect_smart_context "$NORMAL_DIFF" "src/x.js")
if [ -z "$SKIP_OUT" ]; then
  ok "LITMUS_SKIP_CONTEXT=1 short-circuits collection"
else
  fail "LITMUS_SKIP_CONTEXT=1 did not skip"
fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] && exit 0 || exit 1
