#!/usr/bin/env bash
# tests/test-advisory-stale-downgrade.sh — ADR 0012 bounded advisory-bot
# stale-ack timeout downgrade decision (scripts/advisory-stale-downgrade.sh).
# Verifies the fail-CLOSED gates and per-bot conditions, and the bypass-log shape.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$DIR/scripts/advisory-stale-downgrade.sh"
FAIL=0
ok()  { echo "OK:   $1"; }
bad() { echo "FAIL: $1"; FAIL=1; }
eq()     { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
empty()  { if [[ -z "$1" ]]; then ok "$2"; else bad "$2 (got '$1')"; fi; }
logn()   { local n; n="$(wc -l < "$1")"; n="${n//[^0-9]/}"; if [[ "$n" == "$2" ]]; then ok "$3"; else bad "$3 (got $n)"; fi; }
has()    { if grep -q "$1" "$2"; then ok "$3"; else bad "$3"; fi; }
nothas() { if grep -q "$1" "$2"; then bad "$3"; else ok "$3"; fi; }
nofile() { if [[ ! -s "$1" ]]; then ok "$2"; else bad "$2"; fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT INT TERM

# Fixed GitHub-server anchor (issue #302). run() passes it as SERVER_NOW; a test
# can override by appending SERVER_NOW=... (overrides land after the defaults).
# A clearly-PAST real instant: distinct from "now" (so the logged timestamp proves
# it came from SERVER_NOW, not a local-clock stamp) and always within the script's
# future-plausibility bound on any machine whose clock is >= 2020.
SRV="2020-01-01T00:00:00Z"

# run CANDIDATES [KEY=VAL ...] — global gates default to green/opt-in; overrides last.
run() {
  local cands="$1"; shift
  LAST_LOG="$tmp/log.jsonl"; : > "$LAST_LOG"
  LAST_OUT="$(env SOLO_OPTIN=1 CI_GREEN=1 LITMUS_GREEN=1 SERVER_NOW="$SRV" HEAD_SHA=head1 PR=1 \
    REPO=o/r WAIT_ROUNDS=8 OPERATOR=t BYPASS_LOG="$LAST_LOG" CANDIDATES="$cands" "$@" \
    bash "$SCRIPT")"
}

# CANDIDATES field order:
# login:unresolved_threads:actionable_findings:last_state:stale_sha:ever_changes_requested:engaged_signal

# 1. All conditions met -> bot eligible, one well-formed log event.
run "devin-ai-integration:0:0:COMMENTED:old1:0:0"
eq   "$LAST_OUT" "devin-ai-integration" "clean stale bot -> eligible"
logn "$LAST_LOG" 1 "one bypass-log event written"
has  '"event":"advisory_stale_timeout_downgrade"' "$LAST_LOG" "log carries the distinct event name"
has  '"stale_review_sha":"old1"' "$LAST_LOG" "log carries stale_review_sha"
# issue #302 skew regression: the event timestamp is the GitHub-server anchor
# (SERVER_NOW), NOT the local clock — this is what makes the ref comparable to
# GitHub `created_at` in advisory-downgrade-revalidate.sh regardless of operator skew.
has  "\"timestamp\":\"$SRV\"" "$LAST_LOG" "log timestamp is the GitHub-server anchor (not local clock)"
# Forensic completeness: the two load-bearing eligibility signals are recorded
# (both are always 0 for a downgraded bot — the gate requires ever_cr==0 && engaged==0).
has  '"ever_changes_requested":0' "$LAST_LOG" "log carries ever_changes_requested"
has  '"engaged_signal":0' "$LAST_LOG" "log carries engaged_signal"

# 1b. APPROVED terminal state is also allowlisted -> eligible.
run "devin-ai-integration:0:0:APPROVED:old1:0:0"
eq   "$LAST_OUT" "devin-ai-integration" "APPROVED terminal state -> eligible"

# 2. Solo opt-in absent -> nothing downgraded (fail-closed), no log.
run "devin-ai-integration:0:0:COMMENTED:old1:0:0" SOLO_OPTIN=0
empty  "$LAST_OUT" "no opt-in -> empty"
nofile "$LAST_LOG" "no opt-in -> no log event"

# 3-4. Global gates fail-closed.
run "devin-ai-integration:0:0:COMMENTED:old1:0:0" CI_GREEN=0
empty "$LAST_OUT" "CI not green -> empty"
run "devin-ai-integration:0:0:COMMENTED:old1:0:0" LITMUS_GREEN=0
empty "$LAST_OUT" "litmus not green -> empty"

# 4b-4c. Server-time anchor fail-CLOSED (issue #302): without a valid
# GitHub-server timestamp the downgrade refuses to run — it never falls back to a
# skew-prone local clock. Covers absent and malformed SERVER_NOW.
run "devin-ai-integration:0:0:COMMENTED:old1:0:0" SERVER_NOW=
empty  "$LAST_OUT" "absent SERVER_NOW -> empty (fail-closed)"
nofile "$LAST_LOG" "absent SERVER_NOW -> no log event"
run "devin-ai-integration:0:0:COMMENTED:old1:0:0" SERVER_NOW=not-a-timestamp
empty  "$LAST_OUT" "malformed SERVER_NOW -> empty (fail-closed)"
nofile "$LAST_LOG" "malformed SERVER_NOW -> no log event"
# 4d. Valid-format but far-FUTURE SERVER_NOW (poisoned/stale caller): the ref is
# CLAMPED to the local clock (min), so the downgrade still proceeds but the logged
# ref is local-now, never the inflated future value — closing the suppression
# window at any magnitude without a tolerance knob.
run "devin-ai-integration:0:0:COMMENTED:old1:0:0" SERVER_NOW=2099-01-01T00:00:00Z
eq     "$LAST_OUT" "devin-ai-integration" "far-future SERVER_NOW -> clamped, still eligible"
nothas '2099'      "$LAST_LOG" "far-future SERVER_NOW -> ref clamped to local (no 2099 in log)"

# 5-7. Per-bot conditions keep a bot stale.
run "coderabbitai:2:0:COMMENTED:old1:0:0"
empty "$LAST_OUT" "unresolved threads (live finding) -> kept stale"
run "cursor:0:3:COMMENTED:old1:0:0"
empty "$LAST_OUT" "actionable findings -> kept stale"
run "cursor:0:0:CHANGES_REQUESTED:old1:0:0"
empty "$LAST_OUT" "CHANGES_REQUESTED (latest state) -> kept stale"

# 7b. Allowlist (not denylist): PENDING / unknown future states are NOT
# treated as safe just because they're not CHANGES_REQUESTED/DISMISSED.
run "cursor:0:0:PENDING:old1:0:0"
empty "$LAST_OUT" "PENDING last_state -> kept stale (not on allowlist)"
run "cursor:0:0:SOME_FUTURE_STATE:old1:0:0"
empty "$LAST_OUT" "unknown/future last_state -> kept stale (not on allowlist)"

# 7c. ever_changes_requested=1 keeps a bot stale even when its LATEST state is
# COMMENTED/APPROVED — a later non-blocking review does not erase an earlier
# raised concern (mirrors ack-ledger.sh's [CHANGES_REQUESTED, COMMENTED] guard).
run "cursor:0:0:COMMENTED:old1:1:0"
empty "$LAST_OUT" "history ever had CHANGES_REQUESTED -> kept stale"
run "cursor:0:0:APPROVED:old1:1:0"
empty "$LAST_OUT" "history ever had CHANGES_REQUESTED, now APPROVED -> kept stale"

# 7d. engaged_signal=1 keeps a bot stale even with 0 threads/findings and a
# clean last_state — models Codex's hoisted 👀-reaction override in
# ack-ledger.sh (actively re-reviewing HEAD right now => not the "reviewed an
# old SHA, found nothing, never re-acked" case ADR 0012 targets).
run "chatgpt-codex-connector:0:0:COMMENTED:old1:0:1"
empty "$LAST_OUT" "active engagement signal (Codex 👀) -> kept stale"

# 8. Malformed candidate (non-integer field) -> skipped (fail-closed).
run "cursor:x:0:COMMENTED:old1:0:0"
empty "$LAST_OUT" "malformed field -> skipped"

# 8b. Empty last_state (cannot prove non-blocking) -> skipped.
run "cursor:0:0::old1:0:0"
empty "$LAST_OUT" "empty last_state -> skipped (fail-closed)"

# 8c. Empty stale_sha (cannot prove old-SHA tie) -> skipped.
run "cursor:0:0:COMMENTED::0:0"
empty "$LAST_OUT" "empty stale_sha -> skipped (fail-closed)"

# 8d. Missing/empty ever_changes_requested field (cannot prove clean history) -> skipped.
run "cursor:0:0:COMMENTED:old1::0"
empty "$LAST_OUT" "empty ever_changes_requested -> skipped (fail-closed)"

# 8e. Missing/empty engaged_signal field (cannot prove no live engagement) -> skipped.
run "cursor:0:0:COMMENTED:old1:0:"
empty "$LAST_OUT" "empty engaged_signal -> skipped (fail-closed)"

# 8f. Audit-log write failure -> NOT downgraded (no audit => no release). Point
# BYPASS_LOG at a path whose parent dir does not exist so the append fails.
LAST_OUT="$(env SOLO_OPTIN=1 CI_GREEN=1 LITMUS_GREEN=1 SERVER_NOW="$SRV" HEAD_SHA=head1 PR=1 REPO=o/r \
  WAIT_ROUNDS=8 OPERATOR=t BYPASS_LOG="$tmp/nope/dir/log.jsonl" \
  CANDIDATES="devin-ai-integration:0:0:COMMENTED:old1:0:0" bash "$SCRIPT" 2>/dev/null)"
empty "$LAST_OUT" "audit-log write failure -> not downgraded (fail-closed)"

# 8g. Empty CANDIDATES entirely (e.g. no stale bots survived assembly) -> must
# still exit 0 with empty stdout, not crash, on bash 3.2 (empty-array guard).
LAST_OUT="$(env SOLO_OPTIN=1 CI_GREEN=1 LITMUS_GREEN=1 SERVER_NOW="$SRV" HEAD_SHA=head1 PR=1 REPO=o/r \
  WAIT_ROUNDS=8 OPERATOR=t BYPASS_LOG="$tmp/empty-cands.jsonl" \
  CANDIDATES="" bash "$SCRIPT" 2>&1)"
EMPTY_CANDS_EXIT=$?
eq "$EMPTY_CANDS_EXIT" "0" "empty CANDIDATES -> exits 0 (no crash)"
empty "$LAST_OUT" "empty CANDIDATES -> empty stdout"

# 9. Mixed set: only the fully-clean bot is downgraded.
run "devin-ai-integration:0:0:COMMENTED:old1:0:0,coderabbitai:1:0:COMMENTED:old2:0:0,cursor:0:2:COMMENTED:old3:0:0"
eq   "$LAST_OUT" "devin-ai-integration" "mixed set -> only clean bot eligible"
logn "$LAST_LOG" 1 "mixed set -> exactly one log event"

# 10. Two clean bots -> both eligible, two log events.
run "devin-ai-integration:0:0:COMMENTED:old1:0:0,cubic-dev-ai:0:0:COMMENTED:old2:0:0"
eq   "$LAST_OUT" "devin-ai-integration,cubic-dev-ai" "two clean bots -> both eligible"
logn "$LAST_LOG" 2 "two clean bots -> two log events"

[[ "$FAIL" == 0 ]] && echo "PASS test-advisory-stale-downgrade" || exit 1
