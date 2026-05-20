#!/usr/bin/env bash
# tests/test-merge-findings.sh — regression tests for merge-findings.py.
#
# Background: the JSON extractor at
# skills/blueprint-review/scripts/lib/extract_review_json.py always emits
# pretty-printed (multi-line) JSON via `json.dumps(result, indent=2)`. The
# previous merger implementation read stdin line-by-line and tried to parse
# each line as a complete JSON value, which meant the LLM verdict was
# silently dropped from production litmus runs (only SAST findings reached
# the merge). This bug was uncovered while implementing issue #105's
# stall/review_findings test fixture and is fixed here.
#
# These tests pin the new behavior: the merger accepts concatenated /
# multi-line JSON inputs and preserves blocking findings regardless of
# pretty-print formatting.

set -euo pipefail
cd "$(dirname "$0")/.."

MERGER="skills/litmus/scripts/lib/merge-findings.py"

PASS=0
FAIL=0
TOTAL=0

# Assert: piped input through the merger produces a result whose status
# matches the expected value. Args: <name> <expected_status> <input>.
assert_merge_status() {
    local name="$1" expected_status="$2" input="$3"
    TOTAL=$((TOTAL + 1))
    local result actual_status
    result=$(printf '%s' "$input" | python3 "$MERGER")
    actual_status=$(printf '%s' "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','MISSING'))")
    if [ "$actual_status" = "$expected_status" ]; then
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s (expected status=%s got=%s)\n    result=%s\n" \
            "$name" "$expected_status" "$actual_status" "$result"
        FAIL=$((FAIL + 1))
    fi
}

assert_merge_issue_count() {
    local name="$1" expected_count="$2" input="$3"
    TOTAL=$((TOTAL + 1))
    local result actual_count
    result=$(printf '%s' "$input" | python3 "$MERGER")
    actual_count=$(printf '%s' "$result" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('issues',[])))")
    if [ "$actual_count" = "$expected_count" ]; then
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s (expected %s issues got %s)\n    result=%s\n" \
            "$name" "$expected_count" "$actual_count" "$result"
        FAIL=$((FAIL + 1))
    fi
}

echo "── merge-findings ─────────────────────────────────────────"

# 1. Empty inputs → PASS, 0 issues. Baseline.
assert_merge_status "empty stdin → PASS" "PASS" ""
assert_merge_status "three empty lists → PASS" "PASS" '[]
[]
[]'

# 2. Single-line LLM FAIL (legacy contract) → preserved.
COMPACT_FAIL='{"status":"FAIL","issues":[{"file":"x.txt","line":1,"severity":"high","category":"bug","description":"compact fail","confidence":90}]}'
assert_merge_status "single-line LLM FAIL → FAIL" "FAIL" \
    "$(printf '[]\n[]\n%s\n' "$COMPACT_FAIL")"
assert_merge_issue_count "single-line LLM FAIL → 1 issue preserved" "1" \
    "$(printf '[]\n[]\n%s\n' "$COMPACT_FAIL")"

# 3. Multi-line PRETTY-PRINTED LLM FAIL (extractor output) — the real
#    production contract — must now be preserved. This is the regression
#    that motivated this test file. Before the fix the merger returned
#    PASS / 0 issues because each line was attempted as separate JSON.
PRETTY_FAIL='{
  "status": "FAIL",
  "issues": [
    {
      "file": "x.txt",
      "line": 1,
      "severity": "high",
      "category": "bug",
      "description": "pretty-printed fail",
      "confidence": 90
    }
  ]
}'
assert_merge_status "pretty-printed LLM FAIL → FAIL" "FAIL" \
    "$(printf '[]\n[]\n%s\n' "$PRETTY_FAIL")"
assert_merge_issue_count "pretty-printed LLM FAIL → 1 issue preserved" "1" \
    "$(printf '[]\n[]\n%s\n' "$PRETTY_FAIL")"

# 4. Pretty-printed SAST list (single-line) + pretty-printed LLM dict
#    + empty markdown — all preserved together.
SAST_LIST='[{"file":"y.sh","line":2,"severity":"medium","category":"bug","description":"sast finding","source":"sast:shellcheck"}]'
assert_merge_issue_count "pretty LLM + single-line SAST → 2 issues" "2" \
    "$(printf '%s\n[]\n%s\n' "$SAST_LIST" "$PRETTY_FAIL")"

# 5. Low-severity-only findings → still PASS (the merger only blocks on
#    high/medium with confidence >= 70%). Pin the threshold behavior.
LOW_ONLY='{"status":"FAIL","issues":[{"file":"x","line":1,"severity":"low","category":"maintainability","description":"low","confidence":99}]}'
assert_merge_status "low-only LLM verdict → PASS (below blocking threshold)" "PASS" \
    "$(printf '[]\n[]\n%s\n' "$LOW_ONLY")"

# 6. SAST/lint findings always block (deterministic source rule). Pin it.
SAST_BLOCKER='[{"file":"x","line":1,"severity":"medium","category":"bug","description":"d","source":"sast:semgrep"}]'
assert_merge_status "deterministic SAST blocker → FAIL" "FAIL" \
    "$(printf '%s\n[]\n[]\n' "$SAST_BLOCKER")"

# 7. All-garbage input → fail-closed (security: do not silently PASS when
#    every input is unparseable — that would hide upstream tool crashes).
assert_merge_status "all-garbage stdin → fail-closed FAIL" "FAIL" \
    "$(printf 'not json\nstill not json\n')"

echo ""
echo "── Results: $PASS/$TOTAL passed ────────────────────────────"
if [ "$FAIL" -gt 0 ]; then
    echo "   $FAIL FAILED"
    exit 1
fi
echo "   All passed."
exit 0
