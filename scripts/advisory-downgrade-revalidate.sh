#!/usr/bin/env bash
# scripts/advisory-downgrade-revalidate.sh — ADR 0012 COMPLETION-time re-validation
# of an ON_LOOP_EXHAUSTED stale-ack downgrade against FRESH GitHub state.
#
# WHY: the wait-round downgrade (advisory-stale-downgrade.sh) runs at --max-wait
# exhaustion and writes an `advisory_stale_timeout_downgrade` event (with a
# timestamp) to bypass-log.jsonl per released bot. COMPLETION happens LATER and
# re-queries the ack ledger for defense-in-depth. A bot can RE-ENGAGE in that
# window — a new unresolved thread, a new review (even a COMMENTED body that
# carries actionable findings), or (Codex) a current 👀 reaction. FRESH_ACKS
# would then correctly read `stale`; blindly suppressing every DOWNGRADED_BOTS
# login would defeat this re-query and merge past a live review (litmus HIGH).
#
# APPROACH — re-engagement by TIMESTAMP, not by re-deriving findings. COMPLETION
# cannot cheaply enumerate a COMMENTED review body for actionable findings the
# way the worker's RESULT_BOT_LEDGER does, so any attempt to re-derive
# `actionable_findings` here is unsound (a COMMENTED body with findings and no
# thread would slip through). Instead a bot is safe to suppress ONLY if BOTH:
#   (1) it has posted NOTHING new since its downgrade event across the SAME activity
#       surfaces ack-ledger reads — review, thread comment, reaction, issue comment,
#       check-run (Tier D), commit-status (Tier E) — with a timestamp AFTER it; AND
#   (2) it has NO currently-live unresolved+non-outdated thread on HEAD — a STATE
#       signal with no timestamp (a resolved→reopened flip carries no new comment),
#       so (1) alone can't see it, yet ack-ledger reads it as `stale`.
# ANY newer activity OR any live thread => treat as re-engaged => drop it (caller
# leaves it in STALE_BOTS => blocks). This is deliberately conservative (a benign
# re-comment also blocks); over-blocking is the safe direction for a merge gate.
#
# Fail-CLOSED everywhere: missing downgrade event, unparseable timestamp, jq
# error, or any newer activity => the login is NOT echoed (not suppressed).
#
# Inputs (env):
#   DOWNGRADED_BOTS   comma-separated logins released on the exhaustion path.
#   FETCH_OK          "1" iff EVERY fresh source below was fetched successfully.
#                     Anything else => a source failed => we cannot prove any bot
#                     was silent => suppress nothing (fail-CLOSED).
#   ALL_THREADS       fresh reviewThreads GraphQL pages (COMPLETION fetch).
#   ALL_REVIEWS       fresh /pulls/N/reviews pages.
#   ALL_REACTIONS     fresh /issues/N/reactions pages.
#   ALL_COMMENTS      fresh `gh pr view --json comments` output.
#   ALL_CHECK_RUNS    fresh /commits/HEAD/check-runs pages (ack-ledger Tier D surface).
#   ALL_STATUSES      fresh /commits/HEAD/statuses pages (ack-ledger Tier E surface).
#   HEAD_SHA          8-char HEAD sha (matched against the logged event's head_sha).
#   BYPASS_LOG        the audit log to read downgrade timestamps from
#                     (default: .claude/bypass-log.jsonl).
# Output (stdout): comma-separated logins with NO activity since their downgrade
# (subset of DOWNGRADED_BOTS). Empty when none qualify. Always exit 0.
set -u

[[ -n "${DOWNGRADED_BOTS:-}" ]] || { printf ''; exit 0; }
# A failed fresh fetch leaves a source EMPTY, which jq reads as "no activity" —
# fail-OPEN (a re-engaged bot with an unfetched review would be suppressed). The
# caller sets FETCH_OK=1 only when EVERY source fetch succeeded; anything else
# means we cannot trust the fresh state → suppress nothing (fail-CLOSED).
[[ "${FETCH_OK:-0}" == 1 ]] || { printf ''; exit 0; }
command -v jq >/dev/null 2>&1 || { printf ''; exit 0; }   # no jq → can't prove freshness → suppress nothing
# HEAD_SHA is REQUIRED: the per-bot reference event is matched by (bot, head_sha).
# Without it we cannot confirm the logged downgrade is for THIS HEAD, so a stale
# ack on a different HEAD could be suppressed — fail-CLOSED and suppress nothing.
[[ -n "${HEAD_SHA:-}" ]] || { printf ''; exit 0; }
BYPASS_LOG="${BYPASS_LOG:-.claude/bypass-log.jsonl}"
[[ -f "$BYPASS_LOG" ]] || { printf ''; exit 0; }          # no audit log → no reference ts → fail-CLOSED

# A far-future sentinel emitted on ANY jq parse error so a malformed/truncated
# source is treated as "activity newer than the downgrade" (re-engaged → block),
# NOT as "no activity" (which would fail OPEN). Sorts last, so it wins tail -1.
_FUTURE="9999-12-31T23:59:59Z"

# Latest downgrade-event timestamp for this bot on THIS HEAD (empty if none →
# caller fail-CLOSES that login). head_sha match is mandatory (no empty escape).
_ref_ts() { # $1 login
  jq -rs --arg bot "$1" --arg head "$HEAD_SHA" \
    '[ .[] | select(.event == "advisory_stale_timeout_downgrade" and .bot == $bot and .head_sha == $head) ]
     | sort_by(.timestamp) | last | .timestamp // empty' "$BYPASS_LOG" 2>/dev/null || printf ''
}

# Newest activity timestamp for this bot across all fresh sources (empty if none).
# Each source falls back to the far-future sentinel on jq failure (fail-CLOSED).
_newest_activity() { # $1 login
  # Mirror ack-ledger Tier E's login→status-context map (its ONLY entry today) so a
  # legacy CodeRabbit commit-status — classified by context "CodeRabbit", NOT by
  # creator login — is not missed. Kept in sync with ack-ledger.sh's `case $login`.
  local _sctx=""
  case "$1" in coderabbitai) _sctx="CodeRabbit" ;; esac
  # shellcheck disable=SC2312  # each jq's failure is handled explicitly by
  # `|| echo "$_FUTURE"` (fail-CLOSED: a parse error forces re-engaged), so the
  # masked pipe exit inside this group is intentional, not a swallowed error.
  {
    printf '%s' "${ALL_REVIEWS:-}" | jq -rs --arg l "$1" --arg lb "${1}[bot]" \
      '.[][]? | select(.user.login==$l or .user.login==$lb) | .submitted_at // empty' 2>/dev/null || echo "$_FUTURE"
    # Threads: match the bot on the FIRST comment (thread opener) OR any of the
    # last-10 resolution/reply comments, and emit every matching createdAt — so a
    # reply or resolution comment posted after the downgrade also counts.
    printf '%s' "${ALL_THREADS:-}" | jq -rs --arg l "$1" --arg lb "${1}[bot]" \
      '.[].data.repository.pullRequest.reviewThreads.nodes[]?
       | (.comments.nodes[]?, .resolutionComments.nodes[]?)
       | select(.author.login==$l or .author.login==$lb) | .createdAt // empty' 2>/dev/null || echo "$_FUTURE"
    printf '%s' "${ALL_REACTIONS:-}" | jq -rs --arg l "$1" --arg lb "${1}[bot]" \
      '.[][]? | select(.user.login==$l or .user.login==$lb) | .created_at // empty' 2>/dev/null || echo "$_FUTURE"
    printf '%s' "${ALL_COMMENTS:-}" | jq -r --arg l "$1" --arg lb "${1}[bot]" \
      '.comments[]? | select(.author.login==$l or .author.login==$lb) | .createdAt // empty' 2>/dev/null || echo "$_FUTURE"
    # Check-runs (ack-ledger Tier D surface): a bot (re-)running its check on HEAD is
    # re-engagement. Matched by .app.slug exactly as Tier D; both started_at and
    # completed_at count so an in-progress (not-yet-completed) re-run also blocks.
    printf '%s' "${ALL_CHECK_RUNS:-}" | jq -rs --arg l "$1" \
      '.[].check_runs[]? | select(.app.slug==$l) | (.started_at // empty), (.completed_at // empty)' 2>/dev/null || echo "$_FUTURE"
    # Commit-statuses (ack-ledger Tier E surface): a fresh status (e.g. a pending or
    # failure re-review) is re-engagement. Match by the status CREATOR login (any
    # status the bot posted) OR the Tier-E mapped context (e.g. CodeRabbit's legacy
    # status, whose creator login differs) — the union is a superset of Tier E, so
    # it can only over-block (the safe direction), never miss a live status.
    printf '%s' "${ALL_STATUSES:-}" | jq -rs --arg l "$1" --arg lb "${1}[bot]" --arg ctx "$_sctx" \
      '.[]? | .[]? | select(.creator.login==$l or .creator.login==$lb or ($ctx != "" and .context==$ctx)) | (.created_at // empty), (.updated_at // empty)' 2>/dev/null || echo "$_FUTURE"
  } | LC_ALL=C sort | tail -1
}

# Count of CURRENT unresolved+non-outdated threads opened by the bot on HEAD. This
# is a STATE signal with no timestamp: a thread resolved at downgrade time and
# reopened before merge flips isResolved true→false WITHOUT a new comment, so
# _newest_activity can't see it — yet ack-ledger reads it as `stale` (ack-ledger.sh
# line 316). Mirror that exact query so a reopened finding blocks the suppression.
# Fail-CLOSED: any jq failure → 999 (>0 → treated as a live thread → block).
_live_unresolved() { # $1 login
  printf '%s' "${ALL_THREADS:-}" | jq -rs --arg l "$1" --arg lb "${1}[bot]" \
    '[.[].data.repository.pullRequest.reviewThreads.nodes[]?
      | select(.comments.nodes[0].author.login == $l or .comments.nodes[0].author.login == $lb)
      | select(.isResolved == false and .isOutdated == false)] | length' 2>/dev/null || echo 999
}

eligible=""
_oldIFS="$IFS"; IFS=','
for L in $DOWNGRADED_BOTS; do
  IFS="$_oldIFS"
  [[ -n "$L" ]] || { IFS=','; continue; }
  ref="$(_ref_ts "$L")"
  # No logged downgrade for this bot+HEAD → cannot establish a reference → block.
  [[ -n "$ref" ]] || { IFS=','; continue; }
  # The reference is compared LEXICALLY against activity timestamps, so it MUST be
  # a real ISO-8601 UTC instant. A corrupt/forged event like {"timestamp":"zzzz"}
  # would sort AFTER every real activity ("z" > "9") and silently suppress a
  # re-engaged bot. Reject any ref that isn't strict YYYY-MM-DDThh:mm:ssZ → block.
  [[ "$ref" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || { IFS=','; continue; }
  newest="$(_newest_activity "$L")"
  # ISO-8601 UTC strings sort lexically. Both the downgrade event and GitHub
  # activity are second-resolution, so re-engagement in the SAME second as the
  # downgrade must count — compare `newest >= ref`, NOT strict `>` (which would
  # wave through a same-second re-comment). Bash [[ ]] has no >= for strings, so
  # `! (newest < ref)`. Suppress ONLY when the bot has been silent since (no
  # activity, or newest strictly < ref); activity at-or-after the downgrade blocks.
  _reengaged=0
  if [[ -n "$newest" ]] && ! [[ "$newest" < "$ref" ]]; then _reengaged=1; fi
  # Timestamp-independent state gate: a currently-live unresolved thread the bot
  # opened is a fresh finding regardless of when it was posted (a resolved→reopened
  # flip carries no new timestamp). ack-ledger would return `stale`; suppress NOTHING.
  if [[ "$(_live_unresolved "$L")" -gt 0 ]]; then _reengaged=1; fi
  if [[ "$_reengaged" -eq 0 ]]; then
    eligible="${eligible:+$eligible,}$L"
  fi
  IFS=','
done
IFS="$_oldIFS"

printf '%s' "$eligible"
