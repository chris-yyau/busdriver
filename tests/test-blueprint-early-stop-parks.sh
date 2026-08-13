#!/usr/bin/env bash
# #656: the trajectory auto-stop must PARK, never approve.
#
# The defect: both early-stop branches set PROGRESS_STATUS="low_issues_only", which
# Phase 5 treats as APPROVED — so a no-progress PROCESS signal was laundered into a
# quality verdict and stamped `design-reviewed: PASS` onto documents whose arbiter
# verdict was FAIL with plan-blocking HIGH still open. Six such markers were found on
# this repo, one of them on the ADR that introduced the fresh-subagent arbiter.
#
# SCOPE — read this before trusting a green run. This is a CONTRACT test over the
# script text, NOT an end-to-end behavioural test. It proves the parked branch exists,
# is reachable before the approval branch, and has the right posture. It does NOT
# execute the branch: driving Phase 5 for real needs a full review round with three
# reviewer CLIs and an arbiter verdict. The behavioural proof is still owed — see #656.
# A contract test is not nothing (it is what stops the next upstream sync silently
# reinstating `low_issues_only`), but do not read it as "observed failing and passing".
#
# Usage: bash tests/test-blueprint-early-stop-parks.sh   (exit 0 = all pass)
# shellcheck disable=SC2312,SC2015
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# Optional arg 1 = an alternate loop script to check. Used to prove this test can FAIL:
# point it at a copy with the #656 fix reverted and it must go red. A guard whose
# failure branch has never been observed is not a guard.
LOOP="${1:-skills/blueprint-review/scripts/run-design-review-loop.sh}"
PASS=0; FAIL=0
ok(){ printf "  PASS  %s\n" "$1"; PASS=$((PASS + 1)); }
no(){ printf "  FAIL  %s :: %s\n" "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

[[ -f "$LOOP" ]] || { echo "missing $LOOP"; exit 1; }

# (0) the script must still parse — a contract test over a file that does not run is
# worthless, and this is the cheapest way to catch a bad edit to the branch.
bash -n "$LOOP" 2>/dev/null && ok "loop script parses" || no "loop script parses"

# (1) Neither trajectory early-stop may resolve to a PASS state. Both branches are
# identified by their log line, then the following 4 lines are checked for the
# assignment — narrow enough that an unrelated low_issues_only elsewhere cannot mask a
# regression here.
for sev in HIGH MEDIUM; do
  blk=$(grep -A4 "plan-blocking ${sev} did not decrease" "$LOOP" 2>/dev/null || true)
  if [[ -z "$blk" ]]; then
    no "${sev} early-stop branch found" "log line missing — branch renamed or removed?"
  elif grep -q 'PROGRESS_STATUS="low_issues_only"' <<<"$blk"; then
    no "${sev} early-stop does not approve" "still assigns low_issues_only (#656 regression)"
  elif grep -q 'PROGRESS_STATUS="parked_no_progress"' <<<"$blk"; then
    ok "${sev} early-stop parks instead of approving"
  else
    no "${sev} early-stop parks instead of approving" "assigns neither known state"
  fi
done

# (2) The parked state must have a terminal branch that is NOT the approval branch.
grep -q 'if \[\[ "$PROGRESS_STATUS" == "parked_no_progress" \]\]' "$LOOP" \
  && ok "parked_no_progress has its own branch" \
  || no "parked_no_progress has its own branch"

# (3) The parked branch must be reachable — i.e. appear BEFORE the approval branch,
# which would otherwise be evaluated first. (It cannot match "parked_no_progress", but
# ordering is asserted so a future edit cannot bury the parked branch after an exit.)
parked_ln=$(grep -n 'PROGRESS_STATUS" == "parked_no_progress"' "$LOOP" | head -1 | cut -d: -f1)
appr_ln=$(grep -n 'PROGRESS_STATUS" == "passed"' "$LOOP" | head -1 | cut -d: -f1)
if [[ -n "$parked_ln" && -n "$appr_ln" && "$parked_ln" -lt "$appr_ln" ]]; then
  ok "parked branch precedes the approval branch ($parked_ln < $appr_ln)"
else
  no "parked branch precedes the approval branch" "parked=$parked_ln approval=$appr_ln"
fi

# (4) Posture: the parked branch must terminate the review (so the caller stops
# re-invoking) and exit non-zero (so no caller reads it as success). Checked within the
# branch body — from its `if` to the next line that closes it at that indent.
body=$(sed -n "${parked_ln},\$p" "$LOOP" | sed -n '1,/^  fi$/p')
grep -q 'mark_review_complete "parked_no_progress"' <<<"$body" \
  && ok "parked branch marks the review complete" \
  || no "parked branch marks the review complete" "caller would re-invoke forever"
grep -q '^[[:space:]]*exit 1' <<<"$body" \
  && ok "parked branch exits non-zero" \
  || no "parked branch exits non-zero"

# (5) The parked branch must NOT write a PASS marker. This is the invariant the whole
# issue is about, so it is asserted directly rather than inferred from (1).
if grep -q 'design-reviewed: PASS -->' <<<"$body" \
   && ! grep -q 's|$_RE_PASS|<!-- design-reviewed: PENDING -->|' <<<"$body"; then
  no "parked branch writes no PASS" "a PASS write appears in the parked body"
else
  ok "parked branch writes no PASS"
fi

# (6) It must downgrade a stale PASS from a prior converged run — otherwise the doc
# contradicts the withheld verdict (same reason #355 does it on the degraded path).
grep -q '<!-- design-reviewed: PENDING -->' <<<"$body" \
  && ok "parked branch downgrades a stale PASS" \
  || no "parked branch downgrades a stale PASS"

# (7) The tokens must stay armed: the parked branch must not prune the marker snapshot.
# Tokens are what the pre-implementation gate actually keys on, so pruning here would
# unblock implementation on a parked review even with the PASS withheld.
grep -q '_MARKER_SNAP' <<<"$body" \
  && no "parked branch leaves tokens armed" "touches _MARKER_SNAP — tokens may be pruned" \
  || ok "parked branch leaves tokens armed"

# (8) The atomic-sed helper and marker regexes were hoisted out of the approval branch
# so both terminal paths share one copy. Assert exactly one definition of each — a
# second copy is the "third copy drifting" defect this repo already tracks.
[[ "$(grep -c '_dr_atomic_sed() {' "$LOOP")" == 1 ]] \
  && ok "_dr_atomic_sed defined exactly once" \
  || no "_dr_atomic_sed defined exactly once" "$(grep -c '_dr_atomic_sed() {' "$LOOP") definitions"
[[ "$(grep -c "_RE_PASS=" "$LOOP")" == 1 ]] \
  && ok "_RE_PASS defined exactly once" \
  || no "_RE_PASS defined exactly once" "$(grep -c '_RE_PASS=' "$LOOP") definitions"

printf "\n  %d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
