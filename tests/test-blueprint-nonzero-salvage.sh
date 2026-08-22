#!/usr/bin/env bash
# Issue #714: a normal reviewer slot must not discard a complete, schema-valid
# verdict just because the CLI process exited non-zero.
#
# Behavioural, not a source grep: the reviewer-1 subshell is extracted from
# run-design-review-loop.sh and run with `execute_review` stubbed as a fake
# reviewer that prints a complete fenced verdict and then exits non-zero. The
# real extract_review_json.py and the real create_error_json do the work, so a
# regression in either shows up here.
#
# Two cases only, deliberately: the valid-non-zero salvage and one truncated
# fail-closed control. The three reviewer blocks share ONE helper, so per-slot
# variants would test the same code path three times — the wiring assertion at
# the end is what pins that all three route through it.
#
# Usage: bash tests/test-blueprint-nonzero-salvage.sh
# Exit: 0 if all pass, 1 if any fail.

# SC2015: `cmd && ok || bad` is intentional — ok()/bad() always return 0.
# SC2034/SC2329: every assignment and stub inside run_block() is an input to the
#         eval'd reviewer block, which the linter cannot follow.
# SC2312: the jq reader j() is used inside [[ ]] tests on purpose — a missing
#         field must read as empty, not abort the assertion.
# shellcheck disable=SC2015,SC2034,SC2312,SC2329
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0; TOTAL=0
ok()  { printf "  PASS  %s\n" "$1"; PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); }
bad() { printf "  FAIL  %s\n" "$1"; FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); }

BPLOOP="skills/blueprint-review/scripts/run-design-review-loop.sh"

TMP=$(mktemp -d) || { echo "mktemp -d failed"; exit 1; }
[[ -n "$TMP" && -d "$TMP" ]] || { echo "mktemp -d produced no directory"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# The helper and the reviewer-1 block are extracted by anchor. If either anchor
# drifts the extraction comes back empty — fail loudly rather than pass on a
# fragment that exercises nothing (the #704 lesson).
_bp_helper=$(sed -n '/^_bp_salvage_nonzero_verdict()/,/^}/p' "$BPLOOP")
_bp_block=$(sed -n '/^  # Run Agy (reviewer 1) in background$/,/^  AGY_PID=\$!$/p' "$BPLOOP")

[[ -n "$_bp_helper" ]] || bad "could not extract _bp_salvage_nonzero_verdict from $BPLOOP (missing or renamed — salvage unverified)"
[[ -n "$_bp_block"  ]] || bad "could not extract the reviewer-1 block from $BPLOOP (reshaped? salvage unverified)"

# One fenced verdict, self-labelled `codex` while the resolved CLI is droid —
# the exact mis-attribution observed in #714 — carrying a stale run_id the
# salvage must overwrite, and two issues that must survive and be retagged.
cat > "$TMP/valid-raw.txt" <<'RAW'
[droid] session started, loading config...
Reviewing the design document now.

```json
{
  "status": "FAIL",
  "reviewer_id": "codex",
  "issues": [
    {"section": "Architecture", "severity": "HIGH", "confidence": 0.9,
     "category": "correctness", "description": "unbounded retry", "suggestion": "cap it",
     "reviewer": "codex"},
    {"section": "Rollout", "severity": "MEDIUM", "confidence": 0.7,
     "category": "operability", "description": "no rollback", "suggestion": "add one",
     "reviewer": "codex"}
  ],
  "error": "model-authored error field",
  "metadata": {"run_id": "stale-run", "iteration": 99, "spec_hash": "h-old",
               "runtime_escalated_from": "codex"}
}
```

Tokens used: 41200
RAW

# A complete PASS. A failed transcript cannot authenticate one — the extractor
# promotes a verdict-shaped object quoted inside an unpinned command echo, and a
# reviewed design document that embeds an example verdict can put one there. It
# must never become a passing voice, however complete and schema-valid it is.
sed 's/"FAIL"/"PASS"/' "$TMP/valid-raw.txt" > "$TMP/pass-raw.txt"

# Same payload, truncated mid-object — the fail-closed control.
head -c 260 "$TMP/valid-raw.txt" > "$TMP/broken-raw.txt"

# Run the extracted reviewer-1 block against one raw fixture. $1=fixture,
# $2=exit code the fake reviewer returns, $3=the RESOLVED reviewer CLI for the
# slot (default droid). Leaves the slot artifact at $TMP/agy.json.
run_block() {
  local fixture="$1" rc="$2" cli="${3:-droid}"
  rm -f "$TMP/agy.json" "$TMP/agy-raw.txt" "$TMP/clock"
  (
    set +u
    # shellcheck disable=SC1091
    source skills/blueprint-review/scripts/lib/validation.sh   # real create_error_json
    set +e
    log_info() { :; }; log_warning() { :; }; log_error() { :; }
    get_review_file() { echo "$TMP/$1"; }
    # Monotonic stub clock: two calls 511ms apart, so an injected
    # review_duration_ms of 511 proves exit-0 parity rather than a zero default.
    millis() { local n; n=$(cat "$TMP/clock" 2>/dev/null || echo 1000); echo "$n"; echo $((n+511)) > "$TMP/clock"; }
    # The disposable fake reviewer: complete output, non-zero exit.
    execute_review() { cat "$fixture"; return "$rc"; }
    AGY_AVAILABLE=true
    AGY_OUTPUT_FILE="$TMP/agy.json"
    REVIEWER_1_CLI="$cli"
    FULL_PROMPT="design spec"
    RUN_ID=r-cur; CURRENT_ITERATION=3; SPEC_HASH=h-cur
    SCRIPT_DIR="$PWD/skills/blueprint-review/scripts"
    [[ -n "$_bp_helper" ]] && eval "$_bp_helper"
    eval "$_bp_block"
    wait "$AGY_PID" 2>/dev/null
  ) >/dev/null 2>&1
}

j() { jq -r "$1" "$TMP/agy.json" 2>/dev/null; }

echo "── valid verdict + non-zero exit → findings salvaged ───────"
run_block "$TMP/valid-raw.txt" 7
[[ "$(j '.issues | length')" == "2" && "$(j '.metadata.salvaged_status')" == "FAIL" ]] \
  && ok  "the reviewer's findings survive a non-zero exit instead of being deleted" \
  || bad "the reviewer's findings survive a non-zero exit (n=$(j '.issues | length') salvaged_status=$(j '.metadata.salvaged_status'))"
# The load-bearing safety property: salvage recovers CONTENT, never COVERAGE.
# A salvaged slot must stay ERROR so derive_coverage still calls it
# runtime-failed and the droid rescue (which skips PASS/FAIL slots) still
# treats it as rescuable. Otherwise a verdict-shaped object echoed out of the
# reviewed document could fulfil a lens and help grant the PASS marker.
[[ "$(j '.status')" == "ERROR" && "$(j '.error')" == *"NOT counted as coverage"* ]] \
  && ok  "a salvaged slot still reports as failed coverage and stays droid-rescue eligible" \
  || bad "a salvaged slot still reports as failed coverage — got status '$(j '.status')' error '$(j '.error')'"
[[ "$(j '.reviewer_id')" == "droid" ]] \
  && ok  "attribution overwritten from the resolved reviewer (droid, not the model's 'codex')" \
  || bad "attribution overwritten from the resolved reviewer — got '$(j '.reviewer_id')'"
[[ "$(j '.issues[0].reviewer')" == "droid" && "$(j '.issues[1].reviewer')" == "droid" ]] \
  && ok  "every issue is retagged to the resolved reviewer" \
  || bad "every issue is retagged to the resolved reviewer — got '$(j '.issues[0].reviewer')'"
[[ "$(j '.metadata.run_id')" == "r-cur" && "$(j '.metadata.iteration')" == "3" && "$(j '.metadata.spec_hash')" == "h-cur" ]] \
  && ok  "current run_id/iteration/spec_hash injected over the model's stale copy" \
  || bad "current run_id/iteration/spec_hash injected (run_id=$(j '.metadata.run_id') iter=$(j '.metadata.iteration') hash=$(j '.metadata.spec_hash'))"
[[ "$(j '.metadata.review_duration_ms')" == "511" ]] \
  && ok  "review_duration_ms injected exactly as the exit-0 path does" \
  || bad "review_duration_ms injected exactly as the exit-0 path does — got '$(j '.metadata.review_duration_ms')'"
[[ "$(j '.metadata.salvaged_exit_code')" == "7" ]] \
  && ok  "the non-zero exit is retained as diagnostic metadata" \
  || bad "the non-zero exit is retained as diagnostic metadata — got '$(j '.metadata.salvaged_exit_code')'"
# The fixture authors runtime_escalated_from, which derive_coverage reads as
# "a droid rescue ran" for this slot. Nothing was dispatched here, so the retag
# must DELETE it rather than carry the payload's claim into coverage.
[[ "$(j '.metadata.runtime_escalated_from // "unset"')" == "unset" ]] \
  && ok  "a payload-authored runtime_escalated_from is stripped, not carried into coverage" \
  || bad "a payload-authored runtime_escalated_from is stripped — got '$(j '.metadata.runtime_escalated_from')'"

echo ""
echo "── truncated verdict + non-zero exit → fails closed ────────"
run_block "$TMP/broken-raw.txt" 7
[[ "$(j '.status')" == "ERROR" ]] \
  && ok  "unparseable payload keeps the ERROR artifact" \
  || bad "unparseable payload keeps the ERROR artifact — got '$(j '.status')'"
[[ "$(j '.error')" == *"CLI execution failed (exit 7)"* ]] \
  && ok  "the original failure reason is preserved, not replaced by a parse message" \
  || bad "the original failure reason is preserved — got '$(j '.error')'"

# exit 3 is BUILTIN_FALLBACK, and it is the shape the CODEX reviewer actually
# fails in: `_execute_codex` re-emits the captured CLI output on stderr and THEN
# returns 3, so a codex verdict lost this way never reaches the ordinary
# non-zero branch. Same mechanism, no second code path.
echo ""
echo "── complete PASS + non-zero exit → still not a voice ───────"
run_block "$TMP/pass-raw.txt" 7
[[ "$(j '.status')" == "ERROR" && "$(j '.metadata.salvaged_status')" == "PASS" ]] \
  && ok  "a PASS payload cannot produce a passing voice from a failed transcript" \
  || bad "a PASS payload cannot produce a passing voice — got status '$(j '.status')'"

echo ""
echo "── valid verdict + exit 3 (builtin fallback) → salvaged ────"
run_block "$TMP/valid-raw.txt" 3
[[ "$(j '.issues | length')" == "2" && "$(j '.metadata.salvaged_exit_code')" == "3" ]] \
  && ok  "a BUILTIN_FALLBACK exit does not discard the findings either" \
  || bad "a BUILTIN_FALLBACK exit does not discard the findings — got n=$(j '.issues | length')"
run_block "$TMP/broken-raw.txt" 3
[[ "$(j '.error')" == *"builtin fallback"* ]] \
  && ok  "an unsalvageable exit 3 still reports builtin fallback, not a generic failure" \
  || bad "an unsalvageable exit 3 still reports builtin fallback — got '$(j '.error')'"

# A salvaged slot is still ERROR, so the post-run droid rescue may pick it. The
# rescue writes its OWN artifact over the slot, which would delete the salvaged
# findings a few lines before the arbiter reads them — so it must carry them
# over, keeping each issue's own `.reviewer` tag.
echo ""
echo "── droid rescue over a salvaged slot keeps the findings ────"
_bp_rescue=$(sed -n '/^_bp_droid_rescue()/,/^}/p' "$BPLOOP")
if [[ -z "$_bp_rescue" ]]; then
  bad "could not extract _bp_droid_rescue from $BPLOOP (renamed? carry-over unverified)"
else
  # Resolved CLI is codex here, NOT droid, so the two voices are separable:
  # a regression that retagged carried issues to droid would be invisible if
  # they had already been droid-tagged by the salvage.
  run_block "$TMP/valid-raw.txt" 7 codex
  _rescue_agy() { (
    set +u
    log_info() { :; }; log_warning() { :; }
    get_review_file() { echo "$TMP/$1"; }
    execute_review() { printf '{"status":"FAIL","reviewer_id":"droid","issues":[{"section":"S","description":"droid finding"}]}\n'; }
    FULL_PROMPT="design spec"; RUN_ID=r-cur; CURRENT_ITERATION=3; SPEC_HASH=h-cur
    SCRIPT_DIR="$PWD/skills/blueprint-review/scripts"
    eval "$_bp_rescue"
    _bp_droid_rescue agy "$TMP/agy.json" codex
  ) >/dev/null 2>&1; }
  _rescue_agy
  [[ "$(j '.metadata.carried_salvaged_issues')" == "2" ]] \
    && [[ "$(j '.issues | length')" == "3" ]] \
    && [[ "$(j '[.issues[] | select(.reviewer=="codex")] | length')" == "2" ]] \
    && [[ "$(j '[.issues[] | select(.reviewer=="droid")] | length')" == "1" ]] \
    && ok  "the rescue's verdict is added to the salvaged findings, each keeping its own reviewer tag" \
    || bad "the rescue's verdict is added to the salvaged findings (carried=$(j '.metadata.carried_salvaged_issues') codex=$(j '[.issues[]|select(.reviewer=="codex")]|length') droid=$(j '[.issues[]|select(.reviewer=="droid")]|length'))"

  # Carry-over provenance is out-of-band. A reviewer that exits 0 with a
  # parseable NON-verdict has that object written through verbatim by the
  # exit-0 branch, so it can author BOTH `.issues[].reviewer` AND a
  # `metadata.salvaged_status` of its own — neither may authorize a carry-over,
  # because neither passed the completeness check. (Codex + litmus, PR #738.)
  rm -f "$TMP/agy.json.salvaged"
  printf '{"status":"ERROR","issues":[{"section":"S","description":"unvalidated","reviewer":"codex"}],"metadata":{"salvaged_status":"FAIL"}}\n' > "$TMP/agy.json"
  _rescue_agy
  [[ "$(j '.metadata.carried_salvaged_issues')" == "0" && "$(j '.issues | length')" == "1" ]] \
    && ok  "a payload-authored salvage marker cannot carry unvalidated issues into the rescue" \
    || bad "a payload-authored salvage marker cannot carry unvalidated issues (carried=$(j '.metadata.carried_salvaged_issues') total=$(j '.issues | length'))"

  # A sidecar left behind by an earlier round is not authorization either.
  run_block "$TMP/valid-raw.txt" 7 codex
  jq '.iteration = 1' "$TMP/agy.json.salvaged" > "$TMP/stale.salvaged" && mv "$TMP/stale.salvaged" "$TMP/agy.json.salvaged"
  _rescue_agy
  [[ "$(j '.metadata.carried_salvaged_issues')" == "0" ]] \
    && ok  "a sidecar from a different round is rejected, not replayed" \
    || bad "a sidecar from a different round is rejected (carried=$(j '.metadata.carried_salvaged_issues'))"
fi

echo ""
echo "── all three reviewer slots share the one mechanism ────────"
_wired=$(grep -c 'elif _bp_salvage_nonzero_verdict ' "$BPLOOP")
[[ "$_wired" -eq 3 ]] \
  && ok  "reviewer 1/2/3 all route their non-zero branch through the shared helper" \
  || bad "reviewer 1/2/3 all route through the shared helper — found $_wired call sites, expected 3"

echo ""
echo "── Results: $PASS/$TOTAL passed ────────────────────────────"
[[ "$FAIL" -gt 0 ]] && { echo "   $FAIL FAILED"; exit 1; }
echo "   All passed."
exit 0
