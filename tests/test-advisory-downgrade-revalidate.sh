#!/usr/bin/env bash
# tests/test-advisory-downgrade-revalidate.sh — ADR 0012 COMPLETION-time
# re-validation (scripts/advisory-downgrade-revalidate.sh). A downgraded bot is
# suppressed (safe) ONLY if it posted no activity newer than its logged downgrade
# event; ANY newer review/thread/reaction/comment => re-engaged => not suppressed.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$DIR/scripts/advisory-downgrade-revalidate.sh"
FAIL=0
ok()  { echo "OK:   $1"; }
bad() { echo "FAIL: $1"; FAIL=1; }
eq()    { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
empty() { if [[ -z "$1" ]]; then ok "$2"; else bad "$2 (got '$1')"; fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT INT TERM
LOG="$tmp/bypass-log.jsonl"
REF="2026-07-08T10:00:00Z"          # downgrade event time
BEFORE="2026-07-08T09:00:00Z"       # activity before downgrade (the stale review)
AFTER="2026-07-08T11:00:00Z"        # activity after downgrade (re-engagement)
mk_log() {  # write a downgrade event for $1 at $REF, head=aabbccdd
  printf '{"event":"advisory_stale_timeout_downgrade","bot":"%s","head_sha":"aabbccdd","timestamp":"%s"}\n' "$1" "$REF" > "$LOG"
}
EMPTY_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
NO_RXN='[]'
NO_COMMENTS='{"comments":[]}'
NO_CHECKS='{"check_runs":[]}'
NO_STATUSES='[]'

# stderr carries the per-bot drop diagnostics (#682) and is discarded here so the
# OK/FAIL lines stay legible; test 17 asserts the diagnostic separately.
run() { # $1 downgraded $2 threads $3 reviews $4 reactions $5 comments [$6 check_runs $7 statuses] -> $R
  R=$(DOWNGRADED_BOTS="$1" FETCH_OK=1 ALL_THREADS="$2" ALL_REVIEWS="$3" ALL_REACTIONS="$4" \
    ALL_COMMENTS="$5" ALL_CHECK_RUNS="${6:-}" ALL_STATUSES="${7:-}" \
    HEAD_SHA=aabbccdd BYPASS_LOG="$LOG" bash "$SCRIPT" 2>/dev/null)
}

# 1. Silent since downgrade (only the pre-downgrade stale review) -> suppress.
mk_log cubic-dev-ai
STALE_REV=$(printf '[{"user":{"login":"cubic-dev-ai[bot]"},"state":"COMMENTED","submitted_at":"%s"}]' "$BEFORE")
run "cubic-dev-ai" "$EMPTY_THREADS" "$STALE_REV" "$NO_RXN" "$NO_COMMENTS"
eq "$R" "cubic-dev-ai" "silent since downgrade -> suppressed"

# 2. New review AFTER downgrade (e.g. COMMENTED body w/ findings, no thread) -> block.
mk_log cubic-dev-ai
NEW_REV=$(printf '[{"user":{"login":"cubic-dev-ai[bot]"},"state":"COMMENTED","submitted_at":"%s"},{"user":{"login":"cubic-dev-ai[bot]"},"state":"COMMENTED","submitted_at":"%s"}]' "$BEFORE" "$AFTER")
run "cubic-dev-ai" "$EMPTY_THREADS" "$NEW_REV" "$NO_RXN" "$NO_COMMENTS"
empty "$R" "new review after downgrade -> not suppressed (blocks)"

# 3. New unresolved thread AFTER downgrade -> block.
mk_log cubic-dev-ai
NEW_THREAD=$(printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"cubic-dev-ai[bot]"},"createdAt":"%s"}]}}]}}}}}' "$AFTER")
run "cubic-dev-ai" "$NEW_THREAD" "$STALE_REV" "$NO_RXN" "$NO_COMMENTS"
empty "$R" "new thread after downgrade -> not suppressed (blocks)"

# 4. Codex fresh 👀 reaction AFTER downgrade -> block.
mk_log chatgpt-codex-connector
CODEX_REV=$(printf '[{"user":{"login":"chatgpt-codex-connector[bot]"},"state":"COMMENTED","submitted_at":"%s"}]' "$BEFORE")
CODEX_EYES=$(printf '[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"eyes","created_at":"%s"}]' "$AFTER")
run "chatgpt-codex-connector" "$EMPTY_THREADS" "$CODEX_REV" "$CODEX_EYES" "$NO_COMMENTS"
empty "$R" "Codex fresh eyes after downgrade -> not suppressed (blocks)"

# 5. New issue comment AFTER downgrade -> block.
mk_log cubic-dev-ai
NEW_CMT=$(printf '{"comments":[{"author":{"login":"cubic-dev-ai[bot]"},"createdAt":"%s"}]}' "$AFTER")
run "cubic-dev-ai" "$EMPTY_THREADS" "$STALE_REV" "$NO_RXN" "$NEW_CMT"
empty "$R" "new issue comment after downgrade -> not suppressed (blocks)"

# 6. No downgrade event in the log -> fail-CLOSED (block).
: > "$LOG"
run "cubic-dev-ai" "$EMPTY_THREADS" "$STALE_REV" "$NO_RXN" "$NO_COMMENTS"
empty "$R" "no logged downgrade event -> fail-closed (not suppressed)"

# 7. Missing bypass-log file -> fail-CLOSED.
R=$(DOWNGRADED_BOTS="cubic-dev-ai" FETCH_OK=1 ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$STALE_REV" \
    ALL_REACTIONS="$NO_RXN" ALL_COMMENTS="$NO_COMMENTS" HEAD_SHA=aabbccdd \
    BYPASS_LOG="$tmp/does-not-exist.jsonl" bash "$SCRIPT" 2>/dev/null)
empty "$R" "missing bypass-log -> fail-closed"

# 8. Empty DOWNGRADED_BOTS -> empty (no-op).
mk_log cubic-dev-ai
run "" "$EMPTY_THREADS" "$STALE_REV" "$NO_RXN" "$NO_COMMENTS"
empty "$R" "empty DOWNGRADED_BOTS -> empty"

# 9. Mixed: one silent (suppress) + one re-engaged (block).
printf '{"event":"advisory_stale_timeout_downgrade","bot":"cubic-dev-ai","head_sha":"aabbccdd","timestamp":"%s"}\n{"event":"advisory_stale_timeout_downgrade","bot":"greptile-apps","head_sha":"aabbccdd","timestamp":"%s"}\n' "$REF" "$REF" > "$LOG"
MIX_REV=$(printf '[{"user":{"login":"cubic-dev-ai[bot]"},"state":"COMMENTED","submitted_at":"%s"},{"user":{"login":"greptile-apps[bot]"},"state":"COMMENTED","submitted_at":"%s"}]' "$BEFORE" "$AFTER")
run "cubic-dev-ai,greptile-apps" "$EMPTY_THREADS" "$MIX_REV" "$NO_RXN" "$NO_COMMENTS"
eq "$R" "cubic-dev-ai" "mixed: silent cubic suppressed, re-engaged greptile blocked"

# 10. A source fetch failed (FETCH_OK != 1) -> suppress nothing even if silent.
#     An empty/failed source reads as "no activity" to jq; without this guard a
#     re-engaged bot whose review failed to fetch would be wrongly suppressed.
mk_log cubic-dev-ai
R=$(DOWNGRADED_BOTS="cubic-dev-ai" FETCH_OK=0 ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$STALE_REV" \
    ALL_REACTIONS="$NO_RXN" ALL_COMMENTS="$NO_COMMENTS" HEAD_SHA=aabbccdd BYPASS_LOG="$LOG" bash "$SCRIPT" 2>/dev/null)
empty "$R" "FETCH_OK=0 (a source failed) -> fail-closed (suppress nothing)"

# 10b. FETCH_OK unset entirely -> same fail-CLOSED default.
R=$(DOWNGRADED_BOTS="cubic-dev-ai" ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$STALE_REV" \
    ALL_REACTIONS="$NO_RXN" ALL_COMMENTS="$NO_COMMENTS" HEAD_SHA=aabbccdd BYPASS_LOG="$LOG" bash "$SCRIPT" 2>/dev/null)
empty "$R" "FETCH_OK unset -> fail-closed (suppress nothing)"

# 11. Corrupt/forged reference timestamp in the log -> block (even when silent).
#     "zzzz" sorts AFTER real activity; without ISO-8601 validation the bot would
#     be treated as silent and wrongly suppressed. The bot IS silent here (only the
#     pre-downgrade stale review), so a pass proves the format guard — not activity.
printf '{"event":"advisory_stale_timeout_downgrade","bot":"cubic-dev-ai","head_sha":"aabbccdd","timestamp":"zzzz"}\n' > "$LOG"
run "cubic-dev-ai" "$EMPTY_THREADS" "$STALE_REV" "$NO_RXN" "$NO_COMMENTS"
empty "$R" "non-ISO-8601 reference timestamp -> fail-closed (not suppressed)"

# 11b. Well-formed-but-not-UTC ref (no trailing Z) -> also rejected.
printf '{"event":"advisory_stale_timeout_downgrade","bot":"cubic-dev-ai","head_sha":"aabbccdd","timestamp":"2026-07-08T10:00:00"}\n' > "$LOG"
run "cubic-dev-ai" "$EMPTY_THREADS" "$STALE_REV" "$NO_RXN" "$NO_COMMENTS"
empty "$R" "reference timestamp without trailing Z -> fail-closed (not suppressed)"

# 12. Fresh check-run on HEAD AFTER downgrade (ack-ledger Tier D surface) -> block.
#     Matched by .app.slug; an in-progress re-run (started, not completed) also counts.
mk_log cubic-dev-ai
NEW_CHECK=$(printf '{"check_runs":[{"app":{"slug":"cubic-dev-ai"},"started_at":"%s","completed_at":null}]}' "$AFTER")
run "cubic-dev-ai" "$EMPTY_THREADS" "$STALE_REV" "$NO_RXN" "$NO_COMMENTS" "$NEW_CHECK" "$NO_STATUSES"
empty "$R" "fresh check-run after downgrade -> not suppressed (blocks)"

# 12b. Only a pre-downgrade check-run -> still silent -> suppress.
mk_log cubic-dev-ai
OLD_CHECK=$(printf '{"check_runs":[{"app":{"slug":"cubic-dev-ai"},"started_at":"%s","completed_at":"%s"}]}' "$BEFORE" "$BEFORE")
run "cubic-dev-ai" "$EMPTY_THREADS" "$STALE_REV" "$NO_RXN" "$NO_COMMENTS" "$OLD_CHECK" "$NO_STATUSES"
eq "$R" "cubic-dev-ai" "only pre-downgrade check-run -> suppressed"

# 13. Fresh commit-status AFTER downgrade (ack-ledger Tier E surface) -> block.
#     Matched by status CREATOR login; a pending/failure re-review status re-engages.
mk_log cubic-dev-ai
NEW_STATUS=$(printf '[{"creator":{"login":"cubic-dev-ai[bot]"},"context":"review","state":"pending","created_at":"%s","updated_at":"%s"}]' "$AFTER" "$AFTER")
run "cubic-dev-ai" "$EMPTY_THREADS" "$STALE_REV" "$NO_RXN" "$NO_COMMENTS" "$NO_CHECKS" "$NEW_STATUS"
empty "$R" "fresh commit-status after downgrade -> not suppressed (blocks)"

# 13b. CodeRabbit LEGACY commit-status matched by CONTEXT (not creator) AFTER downgrade -> block.
#      ack-ledger Tier E classifies CodeRabbit's status by context "CodeRabbit"; the status
#      creator login can differ (legacy free-tier), so a creator-only match would miss it.
mk_log coderabbitai
CR_REV=$(printf '[{"user":{"login":"coderabbitai[bot]"},"state":"COMMENTED","submitted_at":"%s"}]' "$BEFORE")
CR_STATUS=$(printf '[{"creator":{"login":"github-actions[bot]"},"context":"CodeRabbit","state":"pending","created_at":"%s","updated_at":"%s"}]' "$AFTER" "$AFTER")
run "coderabbitai" "$EMPTY_THREADS" "$CR_REV" "$NO_RXN" "$NO_COMMENTS" "$NO_CHECKS" "$CR_STATUS"
empty "$R" "CodeRabbit legacy status by context after downgrade -> not suppressed (blocks)"

# 13c. A PENDING (in-progress) review has no submitted_at -> block, not read as silent.
#      Without the sentinel, the only timestamp is the pre-downgrade review (BEFORE < ref)
#      and the bot would be wrongly suppressed while it is actively re-reviewing.
mk_log cubic-dev-ai
PENDING_REV=$(printf '[{"user":{"login":"cubic-dev-ai[bot]"},"state":"COMMENTED","submitted_at":"%s"},{"user":{"login":"cubic-dev-ai[bot]"},"state":"PENDING","submitted_at":null}]' "$BEFORE")
run "cubic-dev-ai" "$EMPTY_THREADS" "$PENDING_REV" "$NO_RXN" "$NO_COMMENTS"
empty "$R" "PENDING in-progress review -> not suppressed (blocks)"

# 14. Activity in the SAME SECOND as the downgrade event -> block (>=, not strict >).
#     A re-comment stamped exactly at REF must not be waved through by a strict > compare.
mk_log cubic-dev-ai
SAME_SEC_CMT=$(printf '{"comments":[{"author":{"login":"cubic-dev-ai[bot]"},"createdAt":"%s"}]}' "$REF")
run "cubic-dev-ai" "$EMPTY_THREADS" "$STALE_REV" "$NO_RXN" "$SAME_SEC_CMT"
empty "$R" "activity in same second as downgrade -> not suppressed (blocks)"

# 15. Thread currently UNRESOLVED but the bot's comment PREDATES the downgrade -> block.
#     A resolved→reopened flip carries no new timestamp, so only the current thread
#     STATE gates here (mirrors ack-ledger's unresolved query). Genuinely RED without
#     the state check: the sole timestamp (BEFORE) is < ref, so it would look silent.
mk_log cubic-dev-ai
REOPENED=$(printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"cubic-dev-ai[bot]"},"createdAt":"%s"}]}}]}}}}}' "$BEFORE")
run "cubic-dev-ai" "$REOPENED" "$STALE_REV" "$NO_RXN" "$NO_COMMENTS"
empty "$R" "currently-unresolved thread with pre-downgrade comment -> not suppressed (blocks)"

# 15b. RESOLVED pre-downgrade thread is disposed (acked) -> still suppressible (no over-block).
mk_log cubic-dev-ai
RESOLVED_THREAD=$(printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":true,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"cubic-dev-ai[bot]"},"createdAt":"%s"}]}}]}}}}}' "$BEFORE")
run "cubic-dev-ai" "$RESOLVED_THREAD" "$STALE_REV" "$NO_RXN" "$NO_COMMENTS"
eq "$R" "cubic-dev-ai" "resolved pre-downgrade thread -> suppressed (disposed, not live)"

# 15c. Unresolved thread opened by ANOTHER bot -> does not block THIS bot's suppression.
mk_log cubic-dev-ai
OTHER_THREAD=$(printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"greptile-apps[bot]"},"createdAt":"%s"}]}}]}}}}}' "$AFTER")
run "cubic-dev-ai" "$OTHER_THREAD" "$STALE_REV" "$NO_RXN" "$NO_COMMENTS"
eq "$R" "cubic-dev-ai" "another bot's unresolved thread -> this bot still suppressed"

# --- #682: head_sha is a JOIN KEY and must match across SHA forms ------------
# advisory-stale-downgrade.sh writes HEAD_SHA verbatim and its caller may pass the
# full 40-char OID or the 8-char short form; COMPLETION passes
# `git rev-parse HEAD | cut -c1-8`. Under the old strict-equality join those never
# matched, so a full-SHA release was logged and then silently refused at merge —
# the entire ADR 0012 path was unreachable and fail-CLOSED made it look correct
# (hit live on PR #680). The join now compares over the shorter of the two SHA
# lengths — a mixed full/short pair matches on their shared short prefix, while
# two full 40-char SHAs are still compared at full length (see 16c2 below).
#
# 16c/16d are the load-bearing half: normalizing a join key is exactly the change
# that can destroy its discriminating power (a botched slice comparing "" to ""
# matches every event), and until now NO test exercised this join with differing
# values at all. A different HEAD must still fail to match.
FULL_SHA="2f9058d07a203823ccb3ca7f842a9451c361e7ba"
SHORT_SHA="2f9058d0"
OTHER_FULL="9c11881eb0f4a7c2d3e5f6a7b8c9d0e1f2a3b4c5"   # differs within the first 8
OTHER_SHORT="9c11881e"

mk_log_head() {  # $1 bot, $2 head_sha value written verbatim into the event
  printf '{"event":"advisory_stale_timeout_downgrade","bot":"%s","head_sha":"%s","timestamp":"%s"}\n' "$1" "$2" "$REF" > "$LOG"
}
run_head() {  # $1 downgraded, $2 HEAD_SHA the caller passes -> $R. Bot is silent throughout.
  R=$(DOWNGRADED_BOTS="$1" FETCH_OK=1 ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$STALE_REV" \
    ALL_REACTIONS="$NO_RXN" ALL_COMMENTS="$NO_COMMENTS" ALL_CHECK_RUNS="$NO_CHECKS" \
    ALL_STATUSES="$NO_STATUSES" HEAD_SHA="$2" BYPASS_LOG="$LOG" bash "$SCRIPT" 2>/dev/null)
}

# 16a. Event logged with the FULL sha, caller passes the SHORT form -> match.
#      This is #680's exact shape and is RED before the fix.
mk_log_head cubic-dev-ai "$FULL_SHA"
run_head "cubic-dev-ai" "$SHORT_SHA"
eq "$R" "cubic-dev-ai" "#682: full-sha event + short-sha caller -> joins (suppressed)"

# 16b. Mirror: event logged SHORT, caller passes FULL -> match.
mk_log_head cubic-dev-ai "$SHORT_SHA"
run_head "cubic-dev-ai" "$FULL_SHA"
eq "$R" "cubic-dev-ai" "#682: short-sha event + full-sha caller -> joins (suppressed)"

# 16b2. Both full (a caller consistent on the long form) -> match.
mk_log_head cubic-dev-ai "$FULL_SHA"
run_head "cubic-dev-ai" "$FULL_SHA"
eq "$R" "cubic-dev-ai" "#682: full-sha event + full-sha caller -> joins (suppressed)"

# 16c. Event belongs to a DIFFERENT head (full form) -> no join -> fail-CLOSED.
#      Proves the normalization did not turn the join into a wildcard.
mk_log_head cubic-dev-ai "$OTHER_FULL"
run_head "cubic-dev-ai" "$FULL_SHA"
empty "$R" "#682: event for a different head (full) -> no join -> fail-closed"

# 16d. Same, short form on both sides -> still discriminates.
mk_log_head cubic-dev-ai "$OTHER_SHORT"
run_head "cubic-dev-ai" "$SHORT_SHA"
empty "$R" "#682: event for a different head (short) -> no join -> fail-closed"

# 16c2. Two DIFFERENT full shas that SHARE the first 8 chars -> no join.
#       Codex's litmus finding on this change: 16c/16d only use shas that differ
#       WITHIN the first 8, so a blanket `[0:8]` truncation on both sides passes
#       them while still confusing two real commits. Comparing over min(len)
#       instead means two full shas are compared over all 40 chars, so this is
#       RED under truncation and GREEN under the shipped join.
mk_log_head cubic-dev-ai "2f9058d0ffffffffffffffffffffffffffffffff"
run_head "cubic-dev-ai" "$FULL_SHA"
empty "$R" "#682: different full shas sharing an 8-char prefix -> no join -> fail-closed"

# 16c3. The residual on the COMPATIBILITY path, asserted so it is a KNOWN property
#       and not an accident: when one side supplied only the short form there is
#       nothing left to disambiguate with, so an 8-char prefix match IS the join.
#       This is NOT the production path — COMPLETION passes HEAD_FULL_SHA and
#       SKILL.md step 4 logs the full sha, so the real comparison is 40-char exact
#       (16b2). It is reachable only for a legacy short-form event or a caller that
#       ignores that guidance, and it is the pre-existing property of `cut -c1-8`.
mk_log_head cubic-dev-ai "2f9058d0ffffffffffffffffffffffffffffffff"
run_head "cubic-dev-ai" "$SHORT_SHA"
eq "$R" "cubic-dev-ai" "#682: short caller cannot disambiguate a shared prefix (accepted residual)"

# 16c4/16c5. A sha shorter than 8 chars on EITHER side joins nothing -> fail-CLOSED.
#            These two hold under a blanket truncation as well (a 3-char value
#            truncates to itself and cannot equal an 8-char one) — they pin the
#            contract, they do not distinguish the implementations. 16c6 is the
#            case that does.
mk_log_head cubic-dev-ai "$FULL_SHA"
run_head "cubic-dev-ai" "2f9"
empty "$R" "#682: caller sha under 8 chars -> no join -> fail-closed"

mk_log_head cubic-dev-ai "2f9"
run_head "cubic-dev-ai" "$FULL_SHA"
empty "$R" "#682: event head_sha under 8 chars -> no join -> fail-closed"

# 16c6. BOTH sides carry the SAME under-8 value (a truncated or garbage sha written
#       by one caller and echoed by the other). A blanket `[0:8]` truncation reads
#       that as a match and releases the bot on 3 chars of "identity"; the floor
#       refuses it. RED under truncation — this is what the `>= 8` buys.
mk_log_head cubic-dev-ai "2f9"
run_head "cubic-dev-ai" "2f9"
empty "$R" "#682: same under-8 value on both sides -> still no join (8-char floor)"

# 16e. Event carries no head_sha at all -> no join (the `// ""` fallback must not
#      match a real caller sha).
printf '{"event":"advisory_stale_timeout_downgrade","bot":"cubic-dev-ai","timestamp":"%s"}\n' "$REF" > "$LOG"
run_head "cubic-dev-ai" "$FULL_SHA"
empty "$R" "#682: event missing head_sha -> no join -> fail-closed"

# 17. The refusal is DIAGNOSABLE, not silent (#682's other half). An empty stdout
#     reads identically whether the bot re-engaged or the join failed; without a
#     stderr reason that ambiguity cost a live diagnosis. Assert the no-reference
#     branch names the bot and the head it searched for.
mk_log_head cubic-dev-ai "$OTHER_FULL"
ERR=$(DOWNGRADED_BOTS="cubic-dev-ai" FETCH_OK=1 ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$STALE_REV" \
  ALL_REACTIONS="$NO_RXN" ALL_COMMENTS="$NO_COMMENTS" ALL_CHECK_RUNS="$NO_CHECKS" \
  ALL_STATUSES="$NO_STATUSES" HEAD_SHA="$FULL_SHA" BYPASS_LOG="$LOG" bash "$SCRIPT" 2>&1 >/dev/null)
case "$ERR" in
  *cubic-dev-ai*"$SHORT_SHA"*) ok "#682: unmatched join explains itself on stderr (names bot + head)" ;;
  *) bad "#682: unmatched join explains itself on stderr (names bot + head) (got '$ERR')" ;;
esac

# 17b. Diagnostics must never contaminate stdout — it is parsed as a login list.
#      (17's own stdout was discarded; re-run capturing stdout alone.)
run_head "cubic-dev-ai" "$FULL_SHA"
empty "$R" "#682: diagnostics go to stderr only, stdout stays empty"

[[ "$FAIL" == 0 ]] && echo "PASS test-advisory-downgrade-revalidate" || exit 1
