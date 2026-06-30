#!/usr/bin/env bash
# tests/test-ultraoracle-retrieval-review.sh
# ADR 0007 Phase 5 — validate-retrieval-review.sh must fail CLOSED on empty/uncited
# Round-2 verdicts (the ADR Phase 5 acceptance criterion) and on shape violations.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/ultraoracle/scripts/validate-retrieval-review.sh"

passed=0; failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }
[[ -f "$SCRIPT" ]] || { fail "validate-retrieval-review.sh missing"; echo "Results: 0 passed, 1 failed"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
v() { bash "$SCRIPT" --review-file "$1"; }

# valid, cited review => pass (exit 0)
cat > "$TMP/good.json" <<JSON
{ "review_type": "ORACLE_RETRIEVAL_REVIEW", "claims": [ {"claim": "x", "evidence": ["app.sh:1"]} ], "verdict": "PASS" }
JSON
v "$TMP/good.json" >/dev/null 2>&1 && ok "valid cited review passes" || fail "valid review rejected"

# UNCERTAIN with a cited claim is still structurally valid => pass
cat > "$TMP/uncertain.json" <<JSON
{ "review_type": "ORACLE_RETRIEVAL_REVIEW", "claims": [ {"claim": "x", "evidence": ["a.sh:2"]} ], "verdict": "UNCERTAIN" }
JSON
v "$TMP/uncertain.json" >/dev/null 2>&1 && ok "UNCERTAIN cited passes" || fail "UNCERTAIN cited rejected"

# empty claims => fail closed (exit 6)
cat > "$TMP/empty.json" <<JSON
{ "review_type": "ORACLE_RETRIEVAL_REVIEW", "claims": [], "verdict": "PASS" }
JSON
v "$TMP/empty.json" >/dev/null 2>&1 && fail "empty claims accepted" || ok "empty claims rejected"

# uncited claim (empty evidence) => fail closed (exit 7)
cat > "$TMP/uncited.json" <<JSON
{ "review_type": "ORACLE_RETRIEVAL_REVIEW", "claims": [ {"claim": "x", "evidence": []} ], "verdict": "PASS" }
JSON
v "$TMP/uncited.json" >/dev/null 2>&1 && fail "uncited claim accepted" || ok "uncited claim rejected"

# wrong review_type => fail closed (exit 4)
cat > "$TMP/wrongtype.json" <<JSON
{ "review_type": "SOMETHING_ELSE", "claims": [ {"claim": "x", "evidence": ["a:1"]} ], "verdict": "PASS" }
JSON
v "$TMP/wrongtype.json" >/dev/null 2>&1 && fail "wrong review_type accepted" || ok "wrong review_type rejected"

# bad verdict => fail closed (exit 5)
cat > "$TMP/badverdict.json" <<JSON
{ "review_type": "ORACLE_RETRIEVAL_REVIEW", "claims": [ {"claim": "x", "evidence": ["a:1"]} ], "verdict": "LGTM" }
JSON
v "$TMP/badverdict.json" >/dev/null 2>&1 && fail "bad verdict accepted" || ok "bad verdict rejected"

# claims as a STRING (not array) => fail closed (jq length would return char count)
cat > "$TMP/claimstr.json" <<JSON
{ "review_type": "ORACLE_RETRIEVAL_REVIEW", "claims": "hello", "verdict": "PASS" }
JSON
v "$TMP/claimstr.json" >/dev/null 2>&1 && fail "string claims accepted" || ok "string claims rejected"

# evidence as a STRING (not array) => uncited, fail closed
cat > "$TMP/evstr.json" <<JSON
{ "review_type": "ORACLE_RETRIEVAL_REVIEW", "claims": [ {"claim": "x", "evidence": "a:1"} ], "verdict": "PASS" }
JSON
v "$TMP/evstr.json" >/dev/null 2>&1 && fail "string evidence accepted" || ok "string evidence rejected"

# Boundary: a fabricated-but-structurally-cited citation PASSES — existence verification
# is the downstream arbiter's responsibility, not this structural validator's (ADR P4).
cat > "$TMP/fab.json" <<JSON
{ "review_type": "ORACLE_RETRIEVAL_REVIEW", "claims": [ {"claim": "x", "evidence": ["nonexistent.sh:999"]} ], "verdict": "PASS" }
JSON
v "$TMP/fab.json" >/dev/null 2>&1 && ok "structurally-cited (fabricated) passes — arbiter checks existence" || fail "fabricated citation rejected (should defer to arbiter)"

# null claim text + object (non-string) evidence element => fail closed
cat > "$TMP/nullclaim.json" <<JSON
{ "review_type": "ORACLE_RETRIEVAL_REVIEW", "claims": [ {"claim": null, "evidence": [{}]} ], "verdict": "PASS" }
JSON
v "$TMP/nullclaim.json" >/dev/null 2>&1 && fail "null-claim/object-evidence accepted" || ok "null-claim/object-evidence rejected"

# bare-string claim element (claims:["x"]) => typed fail closed, not a jq crash
cat > "$TMP/strclaim.json" <<JSON
{ "review_type": "ORACLE_RETRIEVAL_REVIEW", "claims": [ "iamastring" ], "verdict": "PASS" }
JSON
if v "$TMP/strclaim.json" >/dev/null 2>&1; then fail "string claim element accepted"; else
  rc=$?; [ "$rc" -eq 7 ] && ok "string claim element -> typed exit 7" || fail "string claim element exit $rc (want 7)"; fi

# malformed JSON => fail closed (exit 3)
printf '{ not json' > "$TMP/bad.json"
v "$TMP/bad.json" >/dev/null 2>&1 && fail "malformed JSON accepted" || ok "malformed JSON rejected"

# evidence with a colon but NO line number ("file:") is NOT a path:line citation => fail
# closed (exit 7). Pins test(":[0-9]"): a bare colon or "trust:me" must not pass. Existence
# is still the arbiter's job; this only enforces the structural path:line citation shape.
cat > "$TMP/noncite.json" <<JSON
{ "review_type": "ORACLE_RETRIEVAL_REVIEW", "claims": [ {"claim": "x", "evidence": ["file:"]} ], "verdict": "PASS" }
JSON
v "$TMP/noncite.json" >/dev/null 2>&1 && fail "colon-without-line evidence accepted" || ok "colon-without-line evidence rejected"

echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
