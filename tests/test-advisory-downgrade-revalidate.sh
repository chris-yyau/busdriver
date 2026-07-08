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
mk_log() {  # write a downgrade event for $1 at $REF, head=head1
  printf '{"event":"advisory_stale_timeout_downgrade","bot":"%s","head_sha":"head1","timestamp":"%s"}\n' "$1" "$REF" > "$LOG"
}
EMPTY_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
NO_RXN='[]'
NO_COMMENTS='{"comments":[]}'
NO_CHECKS='{"check_runs":[]}'
NO_STATUSES='[]'

run() { # $1 downgraded $2 threads $3 reviews $4 reactions $5 comments [$6 check_runs $7 statuses] -> $R
  R=$(DOWNGRADED_BOTS="$1" FETCH_OK=1 ALL_THREADS="$2" ALL_REVIEWS="$3" ALL_REACTIONS="$4" \
    ALL_COMMENTS="$5" ALL_CHECK_RUNS="${6:-}" ALL_STATUSES="${7:-}" \
    HEAD_SHA=head1 BYPASS_LOG="$LOG" bash "$SCRIPT")
}

# 1. Silent since downgrade (only the pre-downgrade stale review) -> suppress.
mk_log devin-ai-integration
STALE_REV=$(printf '[{"user":{"login":"devin-ai-integration[bot]"},"state":"COMMENTED","submitted_at":"%s"}]' "$BEFORE")
run "devin-ai-integration" "$EMPTY_THREADS" "$STALE_REV" "$NO_RXN" "$NO_COMMENTS"
eq "$R" "devin-ai-integration" "silent since downgrade -> suppressed"

# 2. New review AFTER downgrade (e.g. COMMENTED body w/ findings, no thread) -> block.
mk_log devin-ai-integration
NEW_REV=$(printf '[{"user":{"login":"devin-ai-integration[bot]"},"state":"COMMENTED","submitted_at":"%s"},{"user":{"login":"devin-ai-integration[bot]"},"state":"COMMENTED","submitted_at":"%s"}]' "$BEFORE" "$AFTER")
run "devin-ai-integration" "$EMPTY_THREADS" "$NEW_REV" "$NO_RXN" "$NO_COMMENTS"
empty "$R" "new review after downgrade -> not suppressed (blocks)"

# 3. New unresolved thread AFTER downgrade -> block.
mk_log devin-ai-integration
NEW_THREAD=$(printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"devin-ai-integration[bot]"},"createdAt":"%s"}]}}]}}}}}' "$AFTER")
run "devin-ai-integration" "$NEW_THREAD" "$STALE_REV" "$NO_RXN" "$NO_COMMENTS"
empty "$R" "new thread after downgrade -> not suppressed (blocks)"

# 4. Codex fresh 👀 reaction AFTER downgrade -> block.
mk_log chatgpt-codex-connector
CODEX_REV=$(printf '[{"user":{"login":"chatgpt-codex-connector[bot]"},"state":"COMMENTED","submitted_at":"%s"}]' "$BEFORE")
CODEX_EYES=$(printf '[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"eyes","created_at":"%s"}]' "$AFTER")
run "chatgpt-codex-connector" "$EMPTY_THREADS" "$CODEX_REV" "$CODEX_EYES" "$NO_COMMENTS"
empty "$R" "Codex fresh eyes after downgrade -> not suppressed (blocks)"

# 5. New issue comment AFTER downgrade -> block.
mk_log devin-ai-integration
NEW_CMT=$(printf '{"comments":[{"author":{"login":"devin-ai-integration[bot]"},"createdAt":"%s"}]}' "$AFTER")
run "devin-ai-integration" "$EMPTY_THREADS" "$STALE_REV" "$NO_RXN" "$NEW_CMT"
empty "$R" "new issue comment after downgrade -> not suppressed (blocks)"

# 6. No downgrade event in the log -> fail-CLOSED (block).
: > "$LOG"
run "devin-ai-integration" "$EMPTY_THREADS" "$STALE_REV" "$NO_RXN" "$NO_COMMENTS"
empty "$R" "no logged downgrade event -> fail-closed (not suppressed)"

# 7. Missing bypass-log file -> fail-CLOSED.
R=$(DOWNGRADED_BOTS="devin-ai-integration" FETCH_OK=1 ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$STALE_REV" \
    ALL_REACTIONS="$NO_RXN" ALL_COMMENTS="$NO_COMMENTS" HEAD_SHA=head1 \
    BYPASS_LOG="$tmp/does-not-exist.jsonl" bash "$SCRIPT")
empty "$R" "missing bypass-log -> fail-closed"

# 8. Empty DOWNGRADED_BOTS -> empty (no-op).
mk_log devin-ai-integration
run "" "$EMPTY_THREADS" "$STALE_REV" "$NO_RXN" "$NO_COMMENTS"
empty "$R" "empty DOWNGRADED_BOTS -> empty"

# 9. Mixed: one silent (suppress) + one re-engaged (block).
printf '{"event":"advisory_stale_timeout_downgrade","bot":"devin-ai-integration","head_sha":"head1","timestamp":"%s"}\n{"event":"advisory_stale_timeout_downgrade","bot":"cursor","head_sha":"head1","timestamp":"%s"}\n' "$REF" "$REF" > "$LOG"
MIX_REV=$(printf '[{"user":{"login":"devin-ai-integration[bot]"},"state":"COMMENTED","submitted_at":"%s"},{"user":{"login":"cursor[bot]"},"state":"COMMENTED","submitted_at":"%s"}]' "$BEFORE" "$AFTER")
run "devin-ai-integration,cursor" "$EMPTY_THREADS" "$MIX_REV" "$NO_RXN" "$NO_COMMENTS"
eq "$R" "devin-ai-integration" "mixed: silent devin suppressed, re-engaged cursor blocked"

# 10. A source fetch failed (FETCH_OK != 1) -> suppress nothing even if silent.
#     An empty/failed source reads as "no activity" to jq; without this guard a
#     re-engaged bot whose review failed to fetch would be wrongly suppressed.
mk_log devin-ai-integration
R=$(DOWNGRADED_BOTS="devin-ai-integration" FETCH_OK=0 ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$STALE_REV" \
    ALL_REACTIONS="$NO_RXN" ALL_COMMENTS="$NO_COMMENTS" HEAD_SHA=head1 BYPASS_LOG="$LOG" bash "$SCRIPT")
empty "$R" "FETCH_OK=0 (a source failed) -> fail-closed (suppress nothing)"

# 10b. FETCH_OK unset entirely -> same fail-CLOSED default.
R=$(DOWNGRADED_BOTS="devin-ai-integration" ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$STALE_REV" \
    ALL_REACTIONS="$NO_RXN" ALL_COMMENTS="$NO_COMMENTS" HEAD_SHA=head1 BYPASS_LOG="$LOG" bash "$SCRIPT")
empty "$R" "FETCH_OK unset -> fail-closed (suppress nothing)"

# 11. Corrupt/forged reference timestamp in the log -> block (even when silent).
#     "zzzz" sorts AFTER real activity; without ISO-8601 validation the bot would
#     be treated as silent and wrongly suppressed. The bot IS silent here (only the
#     pre-downgrade stale review), so a pass proves the format guard — not activity.
printf '{"event":"advisory_stale_timeout_downgrade","bot":"devin-ai-integration","head_sha":"head1","timestamp":"zzzz"}\n' > "$LOG"
run "devin-ai-integration" "$EMPTY_THREADS" "$STALE_REV" "$NO_RXN" "$NO_COMMENTS"
empty "$R" "non-ISO-8601 reference timestamp -> fail-closed (not suppressed)"

# 11b. Well-formed-but-not-UTC ref (no trailing Z) -> also rejected.
printf '{"event":"advisory_stale_timeout_downgrade","bot":"devin-ai-integration","head_sha":"head1","timestamp":"2026-07-08T10:00:00"}\n' > "$LOG"
run "devin-ai-integration" "$EMPTY_THREADS" "$STALE_REV" "$NO_RXN" "$NO_COMMENTS"
empty "$R" "reference timestamp without trailing Z -> fail-closed (not suppressed)"

# 12. Fresh check-run on HEAD AFTER downgrade (ack-ledger Tier D surface) -> block.
#     Matched by .app.slug; an in-progress re-run (started, not completed) also counts.
mk_log devin-ai-integration
NEW_CHECK=$(printf '{"check_runs":[{"app":{"slug":"devin-ai-integration"},"started_at":"%s","completed_at":null}]}' "$AFTER")
run "devin-ai-integration" "$EMPTY_THREADS" "$STALE_REV" "$NO_RXN" "$NO_COMMENTS" "$NEW_CHECK" "$NO_STATUSES"
empty "$R" "fresh check-run after downgrade -> not suppressed (blocks)"

# 12b. Only a pre-downgrade check-run -> still silent -> suppress.
mk_log devin-ai-integration
OLD_CHECK=$(printf '{"check_runs":[{"app":{"slug":"devin-ai-integration"},"started_at":"%s","completed_at":"%s"}]}' "$BEFORE" "$BEFORE")
run "devin-ai-integration" "$EMPTY_THREADS" "$STALE_REV" "$NO_RXN" "$NO_COMMENTS" "$OLD_CHECK" "$NO_STATUSES"
eq "$R" "devin-ai-integration" "only pre-downgrade check-run -> suppressed"

# 13. Fresh commit-status AFTER downgrade (ack-ledger Tier E surface) -> block.
#     Matched by status CREATOR login; a pending/failure re-review status re-engages.
mk_log devin-ai-integration
NEW_STATUS=$(printf '[{"creator":{"login":"devin-ai-integration[bot]"},"context":"devin","state":"pending","created_at":"%s","updated_at":"%s"}]' "$AFTER" "$AFTER")
run "devin-ai-integration" "$EMPTY_THREADS" "$STALE_REV" "$NO_RXN" "$NO_COMMENTS" "$NO_CHECKS" "$NEW_STATUS"
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
mk_log devin-ai-integration
PENDING_REV=$(printf '[{"user":{"login":"devin-ai-integration[bot]"},"state":"COMMENTED","submitted_at":"%s"},{"user":{"login":"devin-ai-integration[bot]"},"state":"PENDING","submitted_at":null}]' "$BEFORE")
run "devin-ai-integration" "$EMPTY_THREADS" "$PENDING_REV" "$NO_RXN" "$NO_COMMENTS"
empty "$R" "PENDING in-progress review -> not suppressed (blocks)"

# 14. Activity in the SAME SECOND as the downgrade event -> block (>=, not strict >).
#     A re-comment stamped exactly at REF must not be waved through by a strict > compare.
mk_log devin-ai-integration
SAME_SEC_CMT=$(printf '{"comments":[{"author":{"login":"devin-ai-integration[bot]"},"createdAt":"%s"}]}' "$REF")
run "devin-ai-integration" "$EMPTY_THREADS" "$STALE_REV" "$NO_RXN" "$SAME_SEC_CMT"
empty "$R" "activity in same second as downgrade -> not suppressed (blocks)"

# 15. Thread currently UNRESOLVED but the bot's comment PREDATES the downgrade -> block.
#     A resolved→reopened flip carries no new timestamp, so only the current thread
#     STATE gates here (mirrors ack-ledger's unresolved query). Genuinely RED without
#     the state check: the sole timestamp (BEFORE) is < ref, so it would look silent.
mk_log devin-ai-integration
REOPENED=$(printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"devin-ai-integration[bot]"},"createdAt":"%s"}]}}]}}}}}' "$BEFORE")
run "devin-ai-integration" "$REOPENED" "$STALE_REV" "$NO_RXN" "$NO_COMMENTS"
empty "$R" "currently-unresolved thread with pre-downgrade comment -> not suppressed (blocks)"

# 15b. RESOLVED pre-downgrade thread is disposed (acked) -> still suppressible (no over-block).
mk_log devin-ai-integration
RESOLVED_THREAD=$(printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":true,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"devin-ai-integration[bot]"},"createdAt":"%s"}]}}]}}}}}' "$BEFORE")
run "devin-ai-integration" "$RESOLVED_THREAD" "$STALE_REV" "$NO_RXN" "$NO_COMMENTS"
eq "$R" "devin-ai-integration" "resolved pre-downgrade thread -> suppressed (disposed, not live)"

# 15c. Unresolved thread opened by ANOTHER bot -> does not block THIS bot's suppression.
mk_log devin-ai-integration
OTHER_THREAD=$(printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"cursor[bot]"},"createdAt":"%s"}]}}]}}}}}' "$AFTER")
run "devin-ai-integration" "$OTHER_THREAD" "$STALE_REV" "$NO_RXN" "$NO_COMMENTS"
eq "$R" "devin-ai-integration" "another bot's unresolved thread -> this bot still suppressed"

[[ "$FAIL" == 0 ]] && echo "PASS test-advisory-downgrade-revalidate" || exit 1
