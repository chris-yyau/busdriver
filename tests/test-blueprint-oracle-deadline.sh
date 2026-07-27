#!/bin/bash
# shellcheck disable=SC2016  # grep/awk patterns intentionally contain literal $ ( )
# tests/test-blueprint-oracle-deadline.sh — guard for the UltraOracle .rc poll
# in blueprint-review (#501 / ADR 0030).
#
# Once `--mode background` genuinely returns early, the consult runs concurrently
# with the reviewers. The poll used to start a FRESH `cap + 90` AFTER the reviewer
# waits, which would then ADD to the reviewer window (worst case reviewers + cap +
# 90 — worse than the blocking behaviour it replaced). The fix anchors an absolute
# deadline at DISPATCH, and keeps the pre-existing iteration counter as a
# clock-independent backstop.
#
# Both bounds are load-bearing:
#   - deadline only  -> a backward wall-clock step (NTP) stalls the poll
#   - counter only   -> concurrent reviewer time is never credited
#
# Structure mirrors tests/test-auditor-grace-budget.sh: golden-grep anchored to the
# real assignment lines, plus an EXECUTABLE pass that extracts the real code from
# source and runs it at boundaries — so a broken reorder actually fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOOP="$SCRIPT_DIR/skills/blueprint-review/scripts/run-design-review-loop.sh"

passed=0; failed=0
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
eq() { if [[ "$1" == "$2" ]]; then ok "$3 → $1"; else fail "$3 → got '$1', want '$2'"; fi; }

[[ -f "$LOOP" ]] || { fail "missing $LOOP"; echo "Results: $passed passed, $failed failed"; exit 1; }

# ── Layer 1: wiring ──────────────────────────────────────────────────────────
assert_present() { if grep -qE "$2" "$1"; then ok "$3"; else fail "$4"; fi; }
assert_absent()  { if grep -qE "$2" "$1"; then fail "$4"; else ok "$3"; fi; }

assert_present "$LOOP" '^ULTRA_ORACLE_DEADLINE=0' \
  "deadline pre-initialised at top level (set -u safe)" \
  "ULTRA_ORACLE_DEADLINE not pre-initialised — set -u abort reachable"

assert_present "$LOOP" 'ULTRA_ORACLE_DEADLINE=\$\(\( \$\(date \+%s\) \+ \$\(ultra_oracle_timeout_cap\) \+ \$\(_uora_rc_grace\) \)\)' \
  "deadline anchored at dispatch (cap + grace)" \
  "deadline no longer captured at dispatch — the poll would re-charge a fresh budget"

assert_present "$LOOP" '\[ "\$\(date \+%s\)" -lt "\$ULTRA_ORACLE_DEADLINE" \]' \
  "poll honours the absolute deadline" \
  "poll no longer checks the deadline"

assert_present "$LOOP" '\[ "\$_uora_wait" -lt "\$_uora_cap" \]' \
  "poll retains the counter backstop (clock-step safe)" \
  "counter backstop removed — a backward NTP step would stall the poll"

# The stale-browser-lock recovery pointer travels on the child's stderr; the
# dispatch must not discard it (ADR 0030 Decision 2).
assert_absent "$LOOP" 'Be concise\." 2>/dev/null \|\| true\)"' \
  "dispatch no longer discards the child's stderr" \
  "dispatch still has 2>/dev/null — the stale-lock 'rm -f' pointer is unreachable"

# ── Layer 2: execute the REAL grace normalization at boundaries ───────────────
# ULTRA_ORACLE_RC_GRACE is repo-injectable (#325 / ADR 0016) and bounds a wait, so
# it must sanitize like the sibling BLUEPRINT_AUDITOR_GRACE and may only SHORTEN.
grace() {
  # shellcheck disable=SC2034  # read by the _uora_rc_grace body eval'd from source below
  local ULTRA_ORACLE_RC_GRACE="$1" _UORA_RC_GRACE_DEFAULT code
  code="$(awk '/^_UORA_RC_GRACE_DEFAULT=/{p=1} p{print} p&&/^}$/{exit}' "$LOOP")"
  eval "$code"
  _uora_rc_grace
}

[[ -n "$(grace 30)" ]] || fail "could not extract _uora_rc_grace from source"

eq "$(grace 30)"        30 "grace 30 (in range, shortens)"
eq "$(grace 90)"        90 "grace 90 (at default)"
eq "$(grace 91)"        90 "grace 91 (upper clamp — may only shorten)"
eq "$(grace 3600)"      90 "grace 3600 (repo-injected → clamped)"
eq "$(grace 0)"         90 "grace 0 (→ default)"
eq "$(grace 0000030)"   30 "grace 0000030 (zero-padded → not octal)"
eq "$(grace abc)"       90 "grace abc (non-numeric → default)"
eq "$(grace 12345678)"  90 "grace 12345678 (>7 digits → length guard)"
eq "$(grace '')"        90 "grace empty (→ default)"
_ov="$(grace 999999999999999999999)"
if [[ "$_ov" -ge 1 && "$_ov" -le 90 ]]; then ok "grace overflow-sized input bounded → $_ov"
else fail "grace overflow-sized input escaped 1..90 → $_ov"; fi

# ── Layer 3: execute the REAL poll loop against a stubbed clock ───────────────
# Extracted verbatim so a reordered/removed condition fails here, not silently.
poll_body() { awk '/_uora_wait=0; _uora_cap=/{p=1} p{print} p&&/^      done$/{exit}' "$LOOP"; }

run_poll() {  # <deadline-epoch> <rc-exists:0|1> -> "elapsed_iterations"
  # shellcheck disable=SC2034  # read by the poll body eval'd from source below
  local ULTRA_ORACLE_DEADLINE="$1" rc_exists="$2"
  local ULTRA_ORACLE_ADVISORY_FILE _uora_wait _uora_cap
  local t; t="$(mktemp -d)"
  ULTRA_ORACLE_ADVISORY_FILE="$t/adv.md"
  [[ "$rc_exists" == "1" ]] && : > "$ULTRA_ORACLE_ADVISORY_FILE.rc"
  # tiny budgets so the loop cannot burn CI time
  ultra_oracle_timeout_cap() { printf '4'; }
  _uora_rc_grace() { printf '2'; }
  eval "$(poll_body)"
  rm -rf "$t"
  printf '%s' "$_uora_wait"
}

now="$(date +%s)"

# .rc already present -> zero iterations regardless of deadline
eq "$(run_poll "$(( now + 3600 ))" 1)" 0 "poll exits immediately when .rc exists"

# deadline already passed, no .rc -> deadline short-circuits before the counter
eq "$(run_poll "$(( now - 100 ))" 0)" 0 "expired deadline exits without waiting"

# deadline far in the future, no .rc -> counter backstop bounds it at cap(4)+grace(2)
_c="$(run_poll "$(( now + 3600 ))" 0)"
if [[ "$_c" -ge 6 && "$_c" -le 8 ]]; then
  ok "counter backstop bounds the poll when the clock never advances past the deadline → ${_c}s"
else
  fail "counter backstop did not bound the poll → ${_c}s (want 6..8)"
fi

# A deadline of 0 (nothing dispatched) must not short-circuit into an infinite
# wait — the `-le 0` guard makes the counter authoritative.
_z="$(run_poll 0 0)"
if [[ "$_z" -ge 6 && "$_z" -le 8 ]]; then
  ok "zero deadline falls back to the counter → ${_z}s"
else
  fail "zero deadline mishandled → ${_z}s (want 6..8)"
fi

echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
