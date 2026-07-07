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
nofile() { if [[ ! -s "$1" ]]; then ok "$2"; else bad "$2"; fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT INT TERM

# run CANDIDATES [KEY=VAL ...] — global gates default to green/opt-in; overrides last.
run() {
  local cands="$1"; shift
  LAST_LOG="$tmp/log.jsonl"; : > "$LAST_LOG"
  LAST_OUT="$(env SOLO_OPTIN=1 CI_GREEN=1 LITMUS_GREEN=1 HEAD_SHA=head1 PR=1 \
    REPO=o/r WAIT_ROUNDS=8 OPERATOR=t BYPASS_LOG="$LAST_LOG" CANDIDATES="$cands" "$@" \
    bash "$SCRIPT")"
}

# 1. All conditions met -> bot eligible, one well-formed log event.
run "devin-ai-integration:0:0:COMMENTED:old1"
eq   "$LAST_OUT" "devin-ai-integration" "clean stale bot -> eligible"
logn "$LAST_LOG" 1 "one bypass-log event written"
has  '"event":"advisory_stale_timeout_downgrade"' "$LAST_LOG" "log carries the distinct event name"
has  '"stale_review_sha":"old1"' "$LAST_LOG" "log carries stale_review_sha"

# 2. Solo opt-in absent -> nothing downgraded (fail-closed), no log.
run "devin-ai-integration:0:0:COMMENTED:old1" SOLO_OPTIN=0
empty  "$LAST_OUT" "no opt-in -> empty"
nofile "$LAST_LOG" "no opt-in -> no log event"

# 3-4. Global gates fail-closed.
run "devin-ai-integration:0:0:COMMENTED:old1" CI_GREEN=0
empty "$LAST_OUT" "CI not green -> empty"
run "devin-ai-integration:0:0:COMMENTED:old1" LITMUS_GREEN=0
empty "$LAST_OUT" "litmus not green -> empty"

# 5-7. Per-bot conditions keep a bot stale.
run "coderabbitai:2:0:COMMENTED:old1"
empty "$LAST_OUT" "unresolved threads (live finding) -> kept stale"
run "cursor:0:3:COMMENTED:old1"
empty "$LAST_OUT" "actionable findings -> kept stale"
run "cursor:0:0:CHANGES_REQUESTED:old1"
empty "$LAST_OUT" "CHANGES_REQUESTED -> kept stale"

# 8. Malformed candidate (non-integer field) -> skipped (fail-closed).
run "cursor:x:0:COMMENTED:old1"
empty "$LAST_OUT" "malformed field -> skipped"

# 8b. Empty last_state (cannot prove non-blocking) -> skipped.
run "cursor:0:0::old1"
empty "$LAST_OUT" "empty last_state -> skipped (fail-closed)"

# 8c. Empty stale_sha (cannot prove old-SHA tie) -> skipped.
run "cursor:0:0:COMMENTED:"
empty "$LAST_OUT" "empty stale_sha -> skipped (fail-closed)"

# 8d. Audit-log write failure -> NOT downgraded (no audit => no release). Point
# BYPASS_LOG at a path whose parent dir does not exist so the append fails.
LAST_OUT="$(env SOLO_OPTIN=1 CI_GREEN=1 LITMUS_GREEN=1 HEAD_SHA=head1 PR=1 REPO=o/r \
  WAIT_ROUNDS=8 OPERATOR=t BYPASS_LOG="$tmp/nope/dir/log.jsonl" \
  CANDIDATES="devin-ai-integration:0:0:COMMENTED:old1" bash "$SCRIPT" 2>/dev/null)"
empty "$LAST_OUT" "audit-log write failure -> not downgraded (fail-closed)"

# 9. Mixed set: only the fully-clean bot is downgraded.
run "devin-ai-integration:0:0:COMMENTED:old1,coderabbitai:1:0:COMMENTED:old2,cursor:0:2:COMMENTED:old3"
eq   "$LAST_OUT" "devin-ai-integration" "mixed set -> only clean bot eligible"
logn "$LAST_LOG" 1 "mixed set -> exactly one log event"

# 10. Two clean bots -> both eligible, two log events.
run "devin-ai-integration:0:0:COMMENTED:old1,cubic-dev-ai:0:0:COMMENTED:old2"
eq   "$LAST_OUT" "devin-ai-integration,cubic-dev-ai" "two clean bots -> both eligible"
logn "$LAST_LOG" 2 "two clean bots -> two log events"

[[ "$FAIL" == 0 ]] && echo "PASS test-advisory-stale-downgrade" || exit 1
