#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2310,SC2312,SC2329  # eval/awk extraction + subshell fixtures used for reach/propagation checks
# tests/test-reviewer-timeout.sh — guard for the per-reviewer blueprint budget.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOOP="$SCRIPT_DIR/skills/blueprint-review/scripts/run-design-review-loop.sh"

passed=0; failed=0
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
eq() {  # <got> <want> <label>
  if [[ "$1" == "$2" ]]; then ok "$3 → $1"; else fail "$3 → got '$1', want '$2'"; fi
}

if [[ ! -f "$LOOP" ]]; then
  fail "missing $LOOP"
  echo "Results: $passed passed, $failed failed"
  exit 1
fi

rv_code() {
  awk '/_REV_TIMEOUT="\$\{BLUEPRINT_REVIEWER_TIMEOUT/{p=1} p{print} p&&/_REV_TIMEOUT" -gt 1800/{exit}' "$LOOP"
}

rv_norm() {  # <BLUEPRINT_REVIEWER_TIMEOUT value> -> normalized _REV_TIMEOUT
  # shellcheck disable=SC2034  # BLUEPRINT_REVIEWER_TIMEOUT is read by eval below
  local BLUEPRINT_REVIEWER_TIMEOUT="$1" _REV_TIMEOUT code
  code="$(awk '/_REV_TIMEOUT="\$\{BLUEPRINT_REVIEWER_TIMEOUT/{p=1} p{print} p&&/_REV_TIMEOUT" -gt 1800/{exit}' "$LOOP")"
  eval "$code"$'\ntrue'
  echo "$_REV_TIMEOUT"
}

rv_norm_unset() {  # normalized _REV_TIMEOUT with BLUEPRINT_REVIEWER_TIMEOUT unset
  local _REV_TIMEOUT code
  code="$(awk '/_REV_TIMEOUT="\$\{BLUEPRINT_REVIEWER_TIMEOUT/{p=1} p{print} p&&/_REV_TIMEOUT" -gt 1800/{exit}' "$LOOP")"
  (
    unset BLUEPRINT_REVIEWER_TIMEOUT
    eval "$code"$'\ntrue'
    echo "$_REV_TIMEOUT"
  )
}

if [[ -z "$(rv_code)" ]]; then
  fail "could not extract reviewer normalization block"
else
  ok "reviewer normalization block extracted"
fi

eq "$(rv_norm_unset)" 1200 "reviewer unset (default)"
eq "$(rv_norm '')" 1200 "reviewer empty (default)"
eq "$(rv_norm abc)" 1200 "reviewer abc (non-numeric → default)"
eq "$(rv_norm 0)" 1200 "reviewer 0 (→ default)"
eq "$(rv_norm 000)" 1200 "reviewer 000 (→ default)"
eq "$(rv_norm 0001500)" 1500 "reviewer 0001500 (leading zeros stripped)"
eq "$(rv_norm -5)" 1200 "reviewer -5 (non-numeric → default)"
eq "$(rv_norm 300)" 300 "reviewer 300 (in-range)"
eq "$(rv_norm 1800)" 1800 "reviewer 1800 (at ceiling)"
eq "$(rv_norm 1801)" 1800 "reviewer 1801 (upper clamp)"
eq "$(rv_norm 3600)" 1800 "reviewer 3600 (upper clamp)"
eq "$(rv_norm 12345678)" 1800 "reviewer 12345678 (length clamp)"
eq "$(rv_norm 999999999999999999999)" 1800 "reviewer overflow-sized input (ceiling)"

reviewer_calls="$(grep -E '^[[:space:]]*execute_review "\$REVIEWER_[123]_CLI"' "$LOOP" || true)"
reviewer_count="$(printf '%s\n' "$reviewer_calls" | sed '/^$/d' | wc -l | awk '{print $1}')"
eq "$reviewer_count" 3 "reviewer execute_review reach control"
missing_timeout=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  if ! grep -Fq '"$_REV_TIMEOUT"' <<< "$line"; then
    missing_timeout=1
  fi
done <<< "$reviewer_calls"
if [[ "$missing_timeout" -eq 0 ]]; then
  ok 'all reviewer calls pass "$_REV_TIMEOUT"'
else
  fail 'a reviewer call does not pass "$_REV_TIMEOUT"'
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
reviewer_lines="$reviewer_calls"
code="$(rv_code)"
(
  execute_review() { printf '%s\n' "${3:-UNSET}" >> "$TMP/args"; }
  REVIEWER_1_CLI=x REVIEWER_2_CLI=x REVIEWER_3_CLI=x
  FULL_PROMPT=p
  AGY_RAW_FILE="$TMP/agy.txt" CODEX_RAW_FILE="$TMP/codex.txt" GROK_RAW_FILE="$TMP/grok.txt"
  BLUEPRINT_REVIEWER_TIMEOUT=1234
  _REV_TIMEOUT=
  REVIEWER_EXIT=0
  eval "$code"$'\ntrue'
  eval "$reviewer_lines"
)
eq "$(cat "$TMP/args")" $'1234\n1234\n1234' "reviewer calls propagate 1234"

: > "$TMP/args"
(
  unset BLUEPRINT_REVIEWER_TIMEOUT
  execute_review() { printf '%s\n' "${3:-UNSET}" >> "$TMP/args"; }
  REVIEWER_1_CLI=x REVIEWER_2_CLI=x REVIEWER_3_CLI=x
  FULL_PROMPT=p
  AGY_RAW_FILE="$TMP/agy-unset.txt" CODEX_RAW_FILE="$TMP/codex-unset.txt" GROK_RAW_FILE="$TMP/grok-unset.txt"
  _REV_TIMEOUT=
  REVIEWER_EXIT=0
  eval "$code"$'\ntrue'
  eval "$reviewer_lines"
)
eq "$(cat "$TMP/args")" $'1200\n1200\n1200' "reviewer calls propagate unset default"

mutated_code="$(rv_code | sed '/_REV_TIMEOUT" -gt 1800/d')"
rv_eval() {
  local BLUEPRINT_REVIEWER_TIMEOUT="$1" _REV_TIMEOUT
  eval "$2"$'\ntrue'
  echo "$_REV_TIMEOUT"
}
eq "$(rv_eval 3600 "$mutated_code")" 3600 "mutation control removes upper clamp"
eq "$(rv_eval 3600 "$code")" 1800 "unmutated block keeps upper clamp"

auditor_count="$(grep -c '_AUD_TIMEOUT"' "$LOOP")"
if [[ "$auditor_count" -gt 0 ]] && grep -Fq 'execute_review "$AUDITOR_CLI" "$FULL_PROMPT" "$_AUD_TIMEOUT"' "$LOOP"; then
  ok "auditor timeout pass-through remains"
else
  fail "auditor timeout pass-through changed"
fi

echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
