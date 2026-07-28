#!/bin/bash
# shellcheck disable=SC2016  # grep/awk patterns intentionally contain literal $ ( )
# tests/test-blueprint-auditor-deadline.sh — guard for the Mechanism Witness (k3)
# reap in blueprint-review (#506 / ADR 0030 residual 4).
#
# k3 is dispatched CONCURRENTLY with the three reviewers, but `_aud_grace` was
# initialised only AFTER the reviewer `wait`s — so the reap could poll a fresh
# `_AUD_TIMEOUT + 10` measured from the moment the reviewers finished, i.e. up to
# R + T + 10 on the critical path ahead of the arbiter. The fix anchors an absolute
# deadline at DISPATCH and keeps the counter as a clock-independent backstop.
#
# Both bounds are load-bearing:
#   - deadline only  -> a backward wall-clock step (NTP) stalls the reap
#   - counter only   -> concurrent reviewer time is never credited (the defect)
#
# Structure mirrors tests/test-blueprint-oracle-deadline.sh: golden-grep anchored to
# the real lines, plus an EXECUTABLE pass that extracts the real reap from source and
# runs it at boundaries — so a reorder or a dropped condition actually fails.

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

assert_present "$LOOP" '^  AUDITOR_DEADLINE=0' \
  "deadline pre-initialised per iteration (set -u safe, no stale carry-over)" \
  "AUDITOR_DEADLINE not reset beside AUDITOR_PID — a prior iteration's deadline could leak"

assert_present "$LOOP" 'AUDITOR_DEADLINE=\$\(\( \$\(date \+%s\) \+ _AUD_TIMEOUT \+ 10 \)\)' \
  "deadline anchored at dispatch (budget + 10)" \
  "deadline no longer captured at dispatch — the reap would re-charge a fresh budget"

# The anchor must sit with the dispatch, BEFORE the reviewer waits — that is the
# whole point of the fix. Line order is the invariant, so assert it directly.
# `|| true` on both: a missing anchor must report as a FAIL here and let the
# executable layer below run, not abort the suite via set -e/pipefail.
_l_anchor="$(grep -n 'AUDITOR_DEADLINE=\$(( \$(date +%s)' "$LOOP" | head -1 | cut -d: -f1 || true)"
_l_wait="$(grep -n '^  wait "\$AGY_PID"' "$LOOP" | head -1 | cut -d: -f1 || true)"
if [[ -n "$_l_anchor" && -n "$_l_wait" && "$_l_anchor" -lt "$_l_wait" ]]; then
  ok "deadline captured before the reviewer waits (line $_l_anchor < $_l_wait)"
else
  fail "deadline not captured before the reviewer waits (anchor='$_l_anchor' wait='$_l_wait')"
fi

assert_present "$LOOP" '\[\[ "\$\(date \+%s\)" -ge "\$AUDITOR_DEADLINE" \]\]' \
  "reap honours the absolute deadline" \
  "reap no longer checks the deadline"

assert_present "$LOOP" '\[\[ "\$_aud_grace" -ge "\$_aud_grace_cap" \]\]' \
  "reap retains the counter backstop (clock-step safe)" \
  "counter backstop removed — a backward NTP step would stall the reap"

# #325: BLUEPRINT_AUDITOR_GRACE is repo-injectable and may only SHORTEN. The
# deadline must not have become a way to re-lengthen it.
assert_present "$LOOP" '\[\[ "\$_aud_grace_cap" -gt \$\(\( _AUD_TIMEOUT \+ 10 \)\) \]\]' \
  "grace override still may only shorten (#325 preserved)" \
  "grace override upper clamp lost — a repo-injected value could lengthen the stall"

# ── Layer 2: execute the REAL reap loop against a stubbed clock ───────────────
# Extracted verbatim so a reordered/removed condition fails here, not silently.
reap_body() { awk '/^    _aud_grace=0$/{p=1} p{print} p&&/^    done$/{exit}' "$LOOP"; }

[[ -n "$(reap_body)" ]] || { fail "could not extract the reap loop from source"; }

run_reap() {  # <deadline-epoch> <grace-cap> -> "elapsed_iterations"
  # shellcheck disable=SC2034  # both are read by the reap body eval'd from source below
  local AUDITOR_DEADLINE="$1" _aud_grace_cap="$2" _aud_grace
  local AUDITOR_PID
  # A real sleeping child so `kill -0` succeeds until the reap kills it.
  sleep 30 & AUDITOR_PID=$!
  eval "$(reap_body)"
  kill "$AUDITOR_PID" 2>/dev/null || true
  wait "$AUDITOR_PID" 2>/dev/null || true
  printf '%s' "$_aud_grace"
}
# Silence the loop's log_warning without importing the whole script.
log_warning() { :; }

now="$(date +%s)"

# Deadline already passed → reap exits on the first poll, before burning the counter.
# This is the assertion that FAILS against the counter-only shape: a fresh cap would
# poll for the full budget regardless of how long the reviewers already ran.
eq "$(run_reap "$(( now - 100 ))" 5)" 0 "expired deadline reaps immediately (concurrent time credited)"

# Deadline far in the future → the counter bounds it (clock-step backstop).
_c="$(run_reap "$(( now + 3600 ))" 3)"
if [[ "$_c" -ge 3 && "$_c" -le 5 ]]; then
  ok "counter backstop bounds the reap when the deadline is unreachable → ${_c}s"
else
  fail "counter backstop did not bound the reap → ${_c}s (want 3..5)"
fi

# Deadline of 0 (nothing dispatched) must not short-circuit into an instant reap
# NOR an unbounded one — the `-gt 0` guard makes the counter authoritative.
_z="$(run_reap 0 3)"
if [[ "$_z" -ge 3 && "$_z" -le 5 ]]; then
  ok "zero deadline falls back to the counter → ${_z}s"
else
  fail "zero deadline mishandled → ${_z}s (want 3..5)"
fi

# Deadline expiring mid-poll → reap stops at the deadline, not at the larger cap.
_m="$(run_reap "$(( $(date +%s) + 2 ))" 20)"   # fresh clock: earlier cases have burned seconds
if [[ "$_m" -ge 1 && "$_m" -le 4 ]]; then
  ok "deadline fires mid-poll ahead of the looser counter cap → ${_m}s"
else
  fail "deadline did not pre-empt the counter cap → ${_m}s (want 1..4)"
fi

echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
