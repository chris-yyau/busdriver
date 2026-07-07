#!/usr/bin/env bash
# scripts/advisory-stale-downgrade.sh — ADR 0012 bounded advisory-bot stale-ack
# timeout downgrade decision (single source of truth, testable).
#
# Called by pr-grind's dispatcher ONLY at wait-round exhaustion (--max-wait), as
# the last step before BAIL. Decides which `stale` advisory bots may be
# downgraded stale->none (non-gating) so a green PR is not held hostage by a bot
# that reviewed an old SHA, found nothing, and never re-acked HEAD (#295).
#
# HARD BOUNDARY: this NEVER touches merge authority. Required status checks +
# litmus remain the gate; this only releases the *advisory* ack after those are
# already green. It is fail-CLOSED: any unmet or unprovable condition yields an
# empty downgrade set (the caller then BAILs as before).
#
# Downgrade is emitted as stale->NONE, never ->approved: the ledger records "this
# advisory signal expired cleanly," not "the bot approved HEAD."
#
# Inputs (env):
#   SOLO_OPTIN            1 iff the operator opt-in file
#                        (.claude/pr-grind-advisory-downgrade.local) is present.
#                        The caller resolves presence; absent => no downgrade.
#   CI_GREEN             1 iff required status checks are green (required-checks.lock).
#   LITMUS_GREEN         1 iff litmus PASS on the current HEAD.
#   HEAD_SHA PR REPO     forensic context for the log.
#   WAIT_ROUNDS          --max-wait value that was exhausted (forensics).
#   OPERATOR             operator identity for the log (default: git user.name).
#   CANDIDATES           comma-separated stale advisory bots to evaluate, each
#                        `login:unresolved_threads:actionable_findings:last_state:stale_sha`.
#                        unresolved_threads / actionable_findings are integers;
#                        last_state is the bot's last /reviews state (COMMENTED,
#                        APPROVED, CHANGES_REQUESTED, ...).
#   BYPASS_LOG           append target (default: .claude/bypass-log.jsonl).
#
# Output (stdout): comma-separated logins that MAY be downgraded (possibly empty).
# Side effect: one JSONL `advisory_stale_timeout_downgrade` event per downgraded
# bot appended to BYPASS_LOG. Always exits 0 (empty stdout = nothing eligible).
set -u

POLICY_VERSION="adr-0012-v1"
BYPASS_LOG="${BYPASS_LOG:-.claude/bypass-log.jsonl}"
OPERATOR="${OPERATOR:-$(git config user.name 2>/dev/null || echo unknown)}"
_now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"

# Global fail-CLOSED gates. Any not provably true => no downgrade at all.
if [[ "${SOLO_OPTIN:-0}" != 1 || "${CI_GREEN:-0}" != 1 || "${LITMUS_GREEN:-0}" != 1 ]]; then
  exit 0
fi

# Emit ONE audit event; RETURN its write status. A bot is downgraded only when
# this succeeds — no audit trail => no release (fail-CLOSED on the forensic
# requirement). Missing jq, an unwritable/full BYPASS_LOG, etc. => non-zero.
_emit_log() { # $1 login  $2 unresolved_threads  $3 actionable  $4 last_state  $5 stale_sha
  jq -cn \
    --arg event "advisory_stale_timeout_downgrade" \
    --arg repo "${REPO:-}" --arg pr "${PR:-}" --arg bot "$1" \
    --arg head_sha "${HEAD_SHA:-}" --arg stale_sha "$5" --arg last_state "$4" \
    --arg threads "$2" --arg findings "$3" \
    --arg checks "green" --arg litmus "pass" \
    --arg wait "${WAIT_ROUNDS:-}" --arg policy "$POLICY_VERSION" \
    --arg operator "$OPERATOR" --arg ts "$_now" \
    '{event:$event, repo:$repo, pr:$pr, bot:$bot, head_sha:$head_sha,
      stale_review_sha:$stale_sha, last_state:$last_state,
      unresolved_bot_findings_on_head:($findings|tonumber? // $findings),
      unresolved_bot_threads:($threads|tonumber? // $threads),
      required_checks_state:$checks, litmus_state:$litmus,
      wait_rounds:($wait|tonumber? // $wait), policy_version:$policy,
      operator:$operator, timestamp:$ts}' 2>/dev/null >> "$BYPASS_LOG"
}

eligible=""
IFS=',' read -r -a _cands <<< "${CANDIDATES:-}"
for _c in "${_cands[@]}"; do
  [[ -n "$_c" ]] || continue
  IFS=':' read -r login threads findings last_state stale_sha <<< "$_c"
  # Per-bot fail-CLOSED conditions (any unmet / unprovable => skip, never downgrade):
  #  - login present.
  #  - integer, 0 unresolved threads on HEAD (a live Tier-A finding => keep stale).
  #  - integer, 0 actionable findings in the bot's last review (old-SHA finding => keep stale).
  #  - last_state present AND not a blocking state (CHANGES_REQUESTED / DISMISSED). An
  #    EMPTY last_state cannot prove non-blocking => skip.
  #  - stale_sha present: cannot prove the stale review targeted an old SHA otherwise => skip.
  [[ -n "$login" ]] || continue
  [[ "$threads" =~ ^[0-9]+$ ]] || continue
  [[ "$findings" =~ ^[0-9]+$ ]] || continue
  [[ "$threads" -eq 0 ]] || continue
  [[ "$findings" -eq 0 ]] || continue
  [[ -n "$last_state" ]] || continue
  [[ -n "$stale_sha" ]] || continue
  case "$last_state" in
    CHANGES_REQUESTED|DISMISSED) continue ;;
  esac
  # Downgrade ONLY if the audit event was durably written.
  if _emit_log "$login" "$threads" "$findings" "$last_state" "$stale_sha"; then
    eligible="${eligible:+$eligible,}$login"
  else
    printf 'advisory-stale-downgrade: audit log write failed for %s — NOT downgrading (fail-closed)\n' "$login" >&2
  fi
done

printf '%s' "$eligible"
