#!/usr/bin/env bash
# scripts/typesafe-ack-eval.sh — calibration harness for the TypeSafe/Jev union
# classifier in scripts/ack-ledger.sh. NOT a CI test (tests/test-ack-ledger-
# typesafe-union.sh is, and it mocks the network). This one makes real API calls
# and exists to answer ONE question before a threshold is chosen:
#
#   On the fixtures the regex classifier is already pinned against, where does a
#   Noul agree with it, and what does it do to the two documented RESIDUAL groups
#   the regex deliberately gets wrong?
#
# Method
#   1. Baseline: run the ledger end-to-end with the lane OFF (ACK_LEDGER_TYPESAFE=0)
#      -> today's terminal. This measures the COMPOSITION, not a private function.
#   2. One direct API call per fixture -> the raw noul, cached to $CACHE so a
#      re-run costs nothing.
#   3. Union outcome computed OFFLINE for several thresholds: a fixture demotes if
#      the baseline demoted OR noul >= T. That is exactly the union the script
#      implements, so a sweep costs one pass, not one pass per threshold.
#
# Fixtures are transcribed from tests/test-ack-ledger-status-description.sh and
# grouped by what that file asserts TODAY. Read the group comments before reading
# the numbers: two of the five groups are documented places where today's answer
# is knowingly wrong, and those are the interesting ones.
#
# Usage:  TYPESAFE_API_KEY=... bash scripts/typesafe-ack-eval.sh [--refresh]
set -u
# Un-export the key FIRST — before the first child of any kind. The harness forks
# jq, shasum, awk, git and the whole ledger, mostly through the inherited PATH,
# and each would otherwise carry the key in its environment; it stays in this
# shell for the two curl calls, which read it from stdin. "First" is literal:
# this line used to sit below the REPO_DIR assignment, whose `dirname` is a child
# resolved through that same PATH, so a planted dirname saw the key before the
# protection existed. Code running INSIDE this shell (an imported function,
# BASH_ENV) is the ADR 0026 session residual — see the note in ack-ledger.sh.
export -n TYPESAFE_API_KEY

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACK_SCRIPT="$REPO_DIR/scripts/ack-ledger.sh"
CACHE="${TYPESAFE_EVAL_CACHE:-$REPO_DIR/.typesafe-eval-cache.jsonl}"
# Absolute BEFORE any check. Every check below and every read and append must
# name the same file, and they did not: `git -C "$REPO_DIR" ls-files` resolved a
# relative TYPESAFE_EVAL_CACHE against the repo root while `>>` resolved it
# against the caller's cwd, so running from scripts/ with a relative name checked
# one file for tracked-ness and then served scores from another.
case "$CACHE" in /*) ;; *) CACHE="$PWD/$CACHE" ;; esac
URL='https://api.typesafe.ai/v1/systemone'

[[ -n "${TYPESAFE_API_KEY:-}" ]] || { echo "TYPESAFE_API_KEY unset" >&2; exit 2; }
[[ -f "$ACK_SCRIPT" ]] || { echo "missing $ACK_SCRIPT" >&2; exit 2; }
# The cache is APPENDED to, and `>>` follows a symlink — a checkout carrying
# .typesafe-eval-cache.jsonl as a link to something operator-writable would have
# that file grown with JSON on every cache miss. `.gitignore` is not a boundary
# (`git add -f`), and the `-f` test below follows links too, so check first and
# refuse. ponytail: a structural refuse-and-stop, not O_NOFOLLOW plumbing — the
# shape that actually occurs is a link committed into a checkout, and this closes
# it. A TOCTOU window between the test and the open remains; this is a dev
# harness on an operator's own machine, not a gate. Upgrade if that stops being
# true.
if [[ -L "$CACHE" || ( -e "$CACHE" && ! -f "$CACHE" ) ]]; then
  echo "refusing to use $CACHE: it is a symlink or not a regular file" >&2
  exit 6
fi
# A TRACKED cache is checkout-supplied input: a force-added file of fabricated
# in-range scores would be served as hits and never re-measured, and the table
# would recommend a threshold on no API evidence. Refuse it. A cache outside the
# repo (TYPESAFE_EVAL_CACHE) makes ls-files fail, which is the accept path.
if git -C "$REPO_DIR" ls-files --error-unmatch -- "$CACHE" >/dev/null 2>&1; then
  echo "refusing to use $CACHE: it is tracked by git, so the checkout supplies its scores" >&2
  exit 6
fi
if [[ "${1:-}" == "--refresh" ]] && ! rm -f "$CACHE"; then
  echo "refusing to continue: --refresh could not remove $CACHE" >&2
  exit 6
fi
# NO writability probe. The obvious one — `: > "$CACHE".tmp && rm -f "$CACHE".tmp`
# — truncates a PREDICTABLE path before deleting it, so a symlink parked at
# .typesafe-eval-cache.jsonl.tmp inside the checkout would have its target
# truncated with the operator's permissions, and a real file at that path would
# simply be destroyed. The probe bought nothing either way: the first `>> "$CACHE"`
# already fails loudly on an unwritable path.

# Transcribed VERBATIM from tests/test-ack-ledger-status-description.sh — these
# shapes are load-bearing (a missing pageInfo or the wrong comment envelope makes
# every fixture demote, which reads as a working baseline and is not one).
HEAD_SHA="abc12345"
HEAD_FULL_SHA="abc1234500000000000000000000000000000000"
EMPTY_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
EMPTY_CHECK_RUNS='{"check_runs":[]}'
EMPTY_REACTIONS='[]'
WALKTHROUGH_COMMENT='{"comments":[{"author":{"login":"coderabbitai[bot]"},"createdAt":"2026-01-01T00:00:00Z","body":"## Walkthrough\nThe post-merge hook now uses GitHub PR state to confirm merges."}]}'
PRIOR_REVIEW='[{"user":{"login":"coderabbitai[bot]"},"state":"COMMENTED","commit_id":"oldcommit","body":"Please qualify this by the API result."}]'

# ── fixtures ────────────────────────────────────────────────────────────────
# G1  today: DEMOTE. Non-performance phrasings the regex was built to catch.
# G2  today: ACK.    Foreign-subject cases ("preview failed", not the review).
# G3  today: ACK.    Ordinary completed reviews, incl. empty/whitespace.
# G4  today: ACK  — *** DOCUMENTED UNDER-BLOCK RESIDUAL ***. Semantically these
#                   ARE non-reviews; the regex misses them and the test pins the
#                   miss. A union that demotes these is the whole point.
# G5  today: DEMOTE — *** DOCUMENTED OVER-BLOCK RESIDUAL ***. Semantically these
#                   are completed reviews; the regex demotes them and every
#                   removal introduced a fail-open. The union CANNOT fix these
#                   (regex wins), so a Noul that acks them is expected and inert.
G1=(
  'Rate limit exceeded' 'Review skipped due to quota' 'Review was skipped due to quota'
  'At capacity, review not started' "Couldn't start this review" 'Could not start review'
  'Review not started' "Review can't be started" "Review couldn't be started"
  "Review won't be started" 'Review could not be started' 'Could not start this review'
  'Unable to start the review' 'Review was not completed' 'Review did not complete'
  "Review couldn't complete" 'Could not complete this review'
  'Unable to proceed, review was not started' 'Failed - review was skipped'
  'Review unavailable, rate limit exceeded' "Couldn't start" 'Unable to start'
  'Review started; failed to complete' 'Review has yet to start' 'Review has yet to be completed'
  'Review: not started' 'Review - not started' 'Review started. Failed to complete'
  'Review started! Failed to complete' 'Review was unable to start'
  'Review was unable to be started' 'Review is unable to complete' 'Review never started'
  'Review never completed' 'Review failed to be completed'
  'Review started. Failed to be completed' 'Could not start due to quota'
  'Review started; failed to complete due to timeout' 'Review failed'
  'Review failed due to timeout' 'Review -- not started' 'Review  was  not  started'
  'Review timed out' 'Review did not finish' 'Review started: failed to complete'
  'Review started - failed to complete' 'Review started,could not complete'
  'Review started:was not completed' 'Review rate:limited' 'Review rate—limited'
  'Review failed:see log' 'Review failed,retry later' 'Review failed—see log'
  'No review was completed' 'No review was started' 'No review was completed due to quota'
  'No review was completed, due to quota' 'No review was completed. Logs attached'
  'No review was completed: service unavailable'
  'No review was completed, service unavailable' 'No review was completed—due to quota'
  'No review was completed–due to quota' 'No review was started; service unavailable'
  'The review started, failed to complete' 'Code review started, failed to complete'
  'Review started successfully, failed to complete'
  'Review had successfully started, failed to complete' 'Review started,failed to complete'
  'Review did not get completed' "Review didn't get started"
  ' Review started: failed to complete' 'Review was not able to start'
  "Review wasn't able to start" 'Could not start a review' 'Unable to complete a review'
  'Failed to start this review' 'Review failed: see log' 'Review failed, retry later'
  'Review failed - contact support' 'Could not start this review: see log'
  'Could not start this review, retry later'
  'Unable to start this review: contact support' 'Failed to start this review: see log'
  'Yet to start this review: see log'
)
G2=(
  'Review completed within quota' 'Capacity analysis completed'
  'Review completed; generated files skipped' 'Review completed, no rate limit issues'
  'Review completed - 0 findings, quota healthy' 'Review started and completed'
  'Review completed; preview was skipped' 'Preview skipped' 'Preview limit reached'
  "Review completed; preview can't start" 'Review completed; generated files failed to complete'
  'Review completed - quota healthy' 'Review was not skipped'
  'Review completed: generated files failed to complete'
  'Review completed — preview failed to complete' "Review completed – preview can't start"
  'Review completed; docs yet to be written' 'Review completed: preview failed to start'
  'Review was not completely clean' 'Review completed; preview rendering: failed to complete'
  'Review completed. Preview rendering failed to complete'
  'Review completed; unable to complete the reviewer profile update'
  'Review completed; preview rendering - failed to complete'
  'Review completed; reviewer profile update: failed to complete'
  'Review completed; preview, however, failed to complete'
  'Review completed; artifacts for review: failed to complete'
  'Review failed to find any issues' 'Review completed; failed to complete the review summary'
  'Review completed; skipping reviewer profile update' 'The reviewer started, failed to complete'
  'The review summary started, failed to complete'
  "The review's author started, failed to complete" 'No review was completed without findings'
  'Review reply: failed to complete' 'Could not start this review-summary generator'
  'Review failed-safe check passed' 'Review completed; corporate: limited scope'
  'Review completed; corporate - limited scope'
  'Review completed: preview rendering - failed to complete'
)
G3=( 'Review completed' 'No issues found' '' '   ' )
G4=(
  'The scheduled nightly review started, failed to complete'
  'No review of this commit was completed'
  'Could not complete the full automated code review'
)
G5=(
  'Review completed; not rate limited'
  'Review completed; no review was skipped'
  'Review passed; failed to complete after retry but later completed'
)

# ── harness ─────────────────────────────────────────────────────────────────
baseline_terminal() {  # $1 = description -> "demote" | "ack" | "other:<raw>"
  local desc="$1" statuses raw
  statuses=$(jq -nc --arg d "$desc" \
    '[{context:"CodeRabbit",state:"success",description:$d,target_url:null,created_at:"2026-01-01T00:01:00Z",id:2}]')
  raw=$(ACK_LEDGER_TYPESAFE=0 \
    FETCH_OK=1 ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$PRIOR_REVIEW" \
    ALL_COMMENTS="$WALKTHROUGH_COMMENT" ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" \
    ALL_STATUSES="$statuses" ALL_REACTIONS="$EMPTY_REACTIONS" \
    HEAD_SHA="$HEAD_SHA" HEAD_FULL_SHA="$HEAD_FULL_SHA" \
    HEAD_COMMITTED_DATE="" HEAD_PUSH_DATE="" HEAD_CHECKS_DATE="" \
    bash "$ACK_SCRIPT" coderabbitai 2>/dev/null)
  case "$raw" in
    stale|none) echo demote ;;
    "$HEAD_SHA") echo ack ;;
    *) echo "other:$raw" ;;
  esac
}

# KEEP IN STEP with _noul_says_non_review in scripts/ack-ledger.sh — a drifted
# question makes this harness calibrate a threshold for a question the script does
# not ask. Two copies of one string, not a third file to hold it.
#
# The `false` list names the reviewer, the review summary and the author of the
# review because the regex contract already identifies those three as the
# canonical foreign-subject traps — NOT because of anything in G4. Tuning this
# question against G4 would be fitting the measurement to the answer.
# ack-ledger.sh sends a CONCRETE id (the one this harness last resolved), not the
# alias. When the alias resolves to something newer, re-run and bump that id and
# the threshold together.
# $1 = description, $2 = model id (default: the alias — for the resolve probe only).
# Every SCORING call passes the RESOLVED concrete id. Sending the alias on each
# request left the run unbound to a model: the alias could move mid-calibration
# and those later scores would still be cached under the id resolved at startup.
question_body() {
  jq -nc --arg d "$1" --arg m "${2:-jev-latest}" '{
    state: { status_description: $d },
    model: $m,
    questions: { review_did_not_run: {
      type: "noul",
      instructions: "Does this CI status description report that the code review itself did not actually run to completion?",
      criteria: {
        true: "The review was skipped, rate-limited, cancelled, timed out, or never started or finished",
        false: "The review ran to completion, or the failure named belongs to something other than the review itself — a preview build, generated files, a profile update, the review summary, the reviewer, the author of the review, a reply, or a tool whose name merely contains the word review"
      } } } }'
}

# `model: "jev-latest"` in that body is an ALIAS, so hashing the body is not
# enough on its own: when the alias moves to a new model the hash is unchanged
# and the cache keeps serving the OLD model's scores while ack-ledger.sh calls
# the new one — calibration for a classifier nobody runs. One throwaway call
# resolves the alias to a concrete id, which then goes into every key.
# Pinned for the same reason as _TYPESAFE_PATH in scripts/ack-ledger.sh: the
# harness carries the same live key, so its curl must not come from a PATH the
# checkout can set.
TOOL_PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"

resolve_model() {
  local resp
  # Status-checked and exit-checked, exactly like the scoring call and like
  # production. Piping curl straight into jq masks curl's status entirely, so a
  # failed transfer whose stdout still held a complete model object resolved
  # "successfully" — and a 3xx did too, because --fail does not cover it.
  # env -i / -q / --proto: same reason as _noul_says_non_review in
  # scripts/ack-ledger.sh — a checkout's .curlrc reached through CURL_HOME, or a
  # repo-set https_proxy plus CURL_CA_BUNDLE, adds a destination that receives
  # this Authorization header. The harness carries the same live key.
  # -H @-: the key goes to curl on stdin, never argv (ps / /proc), as in production.
  resp=$(/usr/bin/env -i PATH="$TOOL_PATH" HOME=/nonexistent \
    curl -q -sS --proto '=https' --fail --max-time 15 -X POST "$URL" \
    -H @- -H 'Content-Type: application/json' \
    -w '\n%{http_code}' \
    --data-binary "$(question_body 'Review completed')" 2>/dev/null \
    <<<"Authorization: Bearer $TYPESAFE_API_KEY") || return 1
  [[ "${resp##*$'\n'}" == "200" ]] || return 1
  printf '%s' "${resp%$'\n'*}" \
    | jq -er --slurp 'if length != 1 then empty else .[0] end
                      | .model | select(type == "string" and length > 0)' 2>/dev/null
}

noul_for() {  # $1 = description -> float, or "ERR"
  local desc="$1" key hit body resp v
  body=$(question_body "$desc" "$RESOLVED_MODEL")
  # The cache key is the WHOLE request body, not the description. Keying on the
  # description alone meant an edited instruction or criteria pair silently
  # reused scores measured against the OLD question, so a re-run would report a
  # threshold for a classifier that no longer exists. Not hypothetical: widening
  # the `false` criteria moved G2's top score 0.88 -> 0.77, and only a manual
  # --refresh caught it. The body carries the model id too, so a model change
  # invalidates the cache on the same mechanism.
  # pipefail in its own subshell, and the result is CHECKED: `| cut` masks
  # shasum's exit status, so a failed hash yielded an EMPTY key that every
  # fixture then shared — each later fixture would read the FIRST one's cached
  # score as its own, with nothing incrementing ERRS and the integrity gate
  # still allowing a recommendation. An unhashable request is an error, not a
  # measurement. The hex test also rejects a hash that parsed but is not one.
  # BOTH halves are needed: the status catches a hash that FAILED, and the hex
  # test catches one that "succeeded" into something unusable. Checking only the
  # shape was the narrower half of the same bug — a shasum that prints a digest
  # and then exits non-zero still leaves hexadecimal in $key, so the case passed
  # and the run cached under a key no successful hash produced.
  if ! key=$(set -o pipefail; printf '%s%s' "$RESOLVED_MODEL" "$body" \
               | shasum -a 256 | cut -d' ' -f1); then echo ERR; return 0; fi
  case "$key" in ''|*[!0-9a-f]*) echo ERR; return 0 ;; esac
  if [[ -f "$CACHE" ]]; then
    # A cache HIT is validated exactly like a fresh response. Returning any
    # non-empty `.n` accepted a stored -1, null, true, an object, or "0.5" as a
    # measurement — and a corrupted ack-side entry then contributed no flips and
    # incremented no error counter, so it understated a threshold's cost while
    # the integrity gate still allowed a recommendation. A record that does not
    # validate is treated as absent, so the call is simply re-made.
    hit=$(jq -r --arg k "$key" \
      'select(.k == $k) | .n | select(type == "number" and . >= 0 and . <= 1)' \
      "$CACHE" 2>/dev/null | head -1)
    if [[ -n "$hit" ]]; then echo "$hit"; return 0; fi
  fi
  # --fail and the [0,1] range check mirror _noul_says_non_review: the harness
  # must not score a run on an HTTP error body or an out-of-range probability.
  # The exit status is CHECKED, not discarded: a failed transfer can still leave
  # complete parseable JSON on stdout (a truncated-but-valid body, a proxy page
  # that happens to parse), and scoring it would cache a number the production
  # classifier would have demoted on. ERR keeps the fixture out of the table
  # rather than pricing the threshold against a transport artefact.
  resp=$(/usr/bin/env -i PATH="$TOOL_PATH" HOME=/nonexistent \
    curl -q -sS --proto '=https' --fail --max-time 15 -X POST "$URL" \
    -H @- -H 'Content-Type: application/json' \
    -w '\n%{http_code}' \
    --data-binary "$body" 2>/dev/null \
    <<<"Authorization: Bearer $TYPESAFE_API_KEY") || { echo ERR; return 0; }
  # The harness must accept exactly what production accepts, or it calibrates a
  # threshold for a classifier with different inputs: status 200 only (--fail
  # misses 3xx), and exactly one JSON document in the body.
  [[ "${resp##*$'\n'}" == "200" ]] || { echo ERR; return 0; }
  resp="${resp%$'\n'*}"
  # `select(.model == $m)` is the second half of pinning the model: the request
  # names the resolved id, and the RESPONSE has to confirm it served that id.
  # Without the confirmation the pin is a request-side hope, and a score served
  # by a different model would still be cached under the resolved one.
  v=$(printf '%s' "$resp" \
    | jq -er --slurp --arg m "$RESOLVED_MODEL" \
        'if length != 1 then empty else .[0] end
         | select(.model == $m)
         | .answers.review_did_not_run.noul
         | select(type=="number" and . >= 0 and . <= 1)' 2>/dev/null) \
    || { echo ERR; return 0; }
  jq -nc --arg k "$key" --arg d "$desc" --arg m "$RESOLVED_MODEL" --argjson n "$v" \
    '{k:$k,d:$d,m:$m,n:$n}' >> "$CACHE"
  echo "$v"
}

THRESHOLDS=(0.5 0.6 0.7 0.8 0.9)
# INDEXED arrays, not `declare -A`: CONTRIBUTING.md targets bash 3.2 (the macOS
# /bin/bash), which has no associative arrays. A (group, threshold) counter lives
# at group_index * ${#THRESHOLDS[@]} + threshold_index; the case lookup mirrors
# scripts/ci/run-shell-tests.sh.
FLIP=(); ACKED=()     # per-threshold counters
ERRS=(); BADBASE=()   # per-group integrity counters (see run_group)
ROWS=()

group_index() {  # $1 = group name -> 0..4
  case "$1" in
    G1) echo 0 ;; G2) echo 1 ;; G3) echo 2 ;; G4) echo 3 ;; G5) echo 4 ;;
    *) return 1 ;;
  esac
}

run_group() {  # $1 = group name, $2 = expected-today (demote|ack), rest = fixtures
  local name="$1" today="$2"; shift 2
  local desc base n t ti i gi
  gi=$(group_index "$name") || { echo "unknown group $name" >&2; exit 7; }
  for desc in "$@"; do
    base=$(baseline_terminal "$desc")
    # An empty/whitespace description never reaches the union (the function
    # short-circuits on it), so do not spend a call on one.
    if [[ -z "${desc// /}" ]]; then n="-"; else n=$(noul_for "$desc"); fi
    ROWS+=("$(printf '%-6s|%-7s|%-7s|%-6s|%s' "$name" "$today" "$base" "$n" "$desc")")
    # Incompleteness is COUNTED, not silently skipped. A fixture whose call
    # failed contributes to no threshold's cost, so a run where every G2/G3 call
    # errored and every G4 call succeeded would print the ideal table — three
    # residuals closed, zero cost — on no evidence at all about the fixtures
    # that must keep acking. Same for a baseline that is not the group's
    # EXPECTED terminal: a must-ack G2/G3 fixture that demotes today prices no
    # flip at any threshold, so it would drop out of the cost silently, and the
    # two startup examples only prove both outcomes are reachable — not that
    # each fixture still lands where its group says. Comparing against $today
    # covers that and a terminal outside demote/ack in one test.
    [[ "$base" == "$today" ]] \
      || BADBASE[gi]=$(( ${BADBASE[gi]:-0} + 1 ))
    [[ "$n" == "ERR" ]] && ERRS[gi]=$(( ${ERRS[gi]:-0} + 1 ))
    [[ "$n" == "-" || "$n" == "ERR" ]] && continue
    for ti in "${!THRESHOLDS[@]}"; do
      t="${THRESHOLDS[ti]}"; i=$(( gi * ${#THRESHOLDS[@]} + ti ))
      # THREE outcomes, as in production: exit 1 is "below threshold", anything
      # else is awk failing to decide -- an error, never an ack.
      awk -v n="$n" -v t="$t" 'BEGIN{exit !(n>=t)}'
      case $? in
        0) [[ "$base" == "ack" ]] && FLIP[i]=$(( ${FLIP[i]:-0} + 1 )) ;;
        1) ACKED[i]=$(( ${ACKED[i]:-0} + 1 )) ;;
        *) ERRS[gi]=$(( ${ERRS[gi]:-0} + 1 )) ;;
      esac
    done
  done
}

RESOLVED_MODEL=$(resolve_model) || RESOLVED_MODEL=""
if [[ -z "$RESOLVED_MODEL" ]]; then
  echo "could not resolve the model alias — refusing to calibrate against an unknown model" >&2
  exit 4
fi
echo "model: $RESOLVED_MODEL (alias jev-latest; cache keys are bound to it)"

# Prove the harness can produce BOTH outcomes before trusting a single number.
# A miswired env contract makes every fixture demote, which looks like a working
# baseline and is not one — that is exactly how the first run of this script lied.
_sc_ack=$(baseline_terminal 'Review completed')
_sc_dem=$(baseline_terminal 'Review rate limited')
if [[ "$_sc_ack" != "ack" || "$_sc_dem" != "demote" ]]; then
  echo "harness self-check FAILED: 'Review completed'=$_sc_ack (want ack), 'Review rate limited'=$_sc_dem (want demote)" >&2
  echo "the env contract does not match tests/test-ack-ledger-status-description.sh — fix that before reading any numbers" >&2
  exit 3
fi

run_group G1 demote "${G1[@]}"
run_group G2 ack    "${G2[@]}"
run_group G3 ack    "${G3[@]}"
run_group G4 ack    "${G4[@]}"
run_group G5 demote "${G5[@]}"

printf '\n%-6s|%-7s|%-7s|%-6s|%s\n' group today base noul description
printf -- '------|-------|-------|------|------------------------------------------\n'
printf '%s\n' "${ROWS[@]}"

printf '\n=== union flips (baseline ACK -> demote) by threshold ===\n'
printf 'group  n      '; printf '%-7s' "${THRESHOLDS[@]}"; printf '\n'
for g in G1 G2 G3 G4 G5; do
  case $g in G1) n=${#G1[@]};; G2) n=${#G2[@]};; G3) n=${#G3[@]};; G4) n=${#G4[@]};; G5) n=${#G5[@]};; esac
  printf '%-6s %-6s' "$g" "$n"
  gi=$(group_index "$g")
  for ti in "${!THRESHOLDS[@]}"; do
    printf '%-7s' "${FLIP[gi * ${#THRESHOLDS[@]} + ti]:-0}"
  done
  printf '\n'
done
# Integrity gate — the table above is only a measurement if every fixture was
# actually measured. Refuse to print a recommendation otherwise.
_incomplete=0
for g in G1 G2 G3 G4 G5; do
  gi=$(group_index "$g")
  if [[ -n "${ERRS[gi]:-}" || -n "${BADBASE[gi]:-}" ]]; then
    printf 'INCOMPLETE %s: %s API error(s), %s unexpected baseline terminal(s)\n' \
      "$g" "${ERRS[gi]:-0}" "${BADBASE[gi]:-0}" >&2
    _incomplete=1
  fi
done
if [[ "$_incomplete" -eq 1 ]]; then
  cat >&2 <<'BAD'

NO RECOMMENDATION. Unmeasured fixtures contribute to no threshold's cost, so a
run that lost the ack-side groups and kept the demote-side one would print a
perfect table on no evidence. Re-run (the cache keeps the successful calls, so a
re-run only retries what failed) and read the numbers only once this is clean.
BAD
  exit 5
fi
cat <<'NOTE'

Reading this table
  G4 flips are the WIN  — the documented under-block residual getting closed.
  G2/G3 flips are the COST — completed reviews newly demoted (a visible stall).
  G1 flips are 0 by construction (already demoted; union cannot double-demote).
  G5 cannot flip: the regex already demotes it, and the union never lifts.
Pick the lowest threshold where G4 = 3 and G2+G3 = 0, if one exists.
NOTE
