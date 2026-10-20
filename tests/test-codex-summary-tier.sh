#!/usr/bin/env bash
# tests/test-codex-summary-tier.sh
#
# Verifies scripts/ack-ledger.sh's summary form of Tier G (#992): Codex's
# edited-in-place review-summary comment, whose `codex-review-state:v1` line names
# the commit it reviewed. The positive fixture is #984's real summary at 11cec108,
# which read `stale` until an `@codex review` nudge: no 👍, no receipt verdict,
# earlier Codex threads resolved and outdated.

set -euo pipefail
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ACK_SCRIPT="$SCRIPT_DIR/scripts/ack-ledger.sh"

passed=0
failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }
expect() { # expect <want> <got> <label>
  if [ "$2" = "$1" ]; then ok "$3"; else fail "$3 — expected '$1', got '$2'"; fi
}

CODEX="chatgpt-codex-connector"
FULL_HEAD="11cec1085104a5e04a1e606a2b1506b295808f7e"
HEAD_SHA="${FULL_HEAD:0:8}"
OTHER_FULL="249a0a1600000000000000000000000000000000"

PUSH_AT="2026-10-20T00:24:01Z"
SUMMARY_AT="2026-10-19T02:57:38Z"   # first post; the comment is edited in place
AFTER_PUSH="2026-10-20T00:40:00Z"

FOOTER=$'\n\n<details> <summary>ℹ️ About Codex in GitHub</summary>\n<br/>\n\n[Your team has set up Codex to review pull requests in this repo](https://chatgpt.com/codex/cloud/settings/general). Reviews are triggered when you\n- Open a pull request for review\n- Mark a draft as ready\n- Comment "@codex review" or "@codex security review".\n\nCodex reacts with 👀 while any review is running, comments if it has suggestions, and reacts with 👍 once all reviews finish with no findings.\n\n</details>'

# summary_body <state-json> — #984's summary layout around a given state line.
summary_body() {
  printf '%s' $'<!-- codex-pull-request-review-summary -->\n<!-- codex-review-state:v1 '"$1"$' -->\n\n## Codex Review Summary\n\nThis comment shows the latest Codex review activity on this pull request.\n\n| Review | Status | Commit | Review trigger |\n| --- | --- | --- | --- |\n| 📝 **Code Review** | ✅ **Completed** | `11cec10` | New commits |'"$FOOTER"
}
state() { # state <commit_sha> <status> <has_unresolved> [<security_review json>]
  printf '{"code_review":{"commit_sha":"%s","has_any_findings":true,"has_unresolved_findings":%s,"status":"%s"},"security_review":%s}' \
    "$1" "$3" "$2" "${4:-{\"commit_sha\":null,\"has_any_findings\":null,\"has_unresolved_findings\":null,\"status\":null\}}"
}
SUMMARY_984=$(summary_body "$(state "$FULL_HEAD" completed false)")

EMPTY_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
codex_thread() { # codex_thread <isResolved> <isOutdated>
  printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":%s,"isOutdated":%s,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector[bot]"},"createdAt":"2026-10-19T18:05:58Z"}]}}]}}}}}' "$1" "$2"
}
# #984's two earlier Codex findings, on b054013b and 249a0a16 — never on HEAD.
REVIEWS_984=$(jq -nc '[{user:{login:"chatgpt-codex-connector[bot]"},commit_id:"b054013b00000000000000000000000000000000",submitted_at:"2026-10-19T06:47:42Z"},
                      {user:{login:"chatgpt-codex-connector[bot]"},commit_id:"249a0a1600000000000000000000000000000000",submitted_at:"2026-10-19T18:05:58Z"}]')
review_on() { jq -nc --arg c "$1" '[{user:{login:"chatgpt-codex-connector[bot]"},commit_id:$c,submitted_at:"2026-10-20T00:35:00Z"}]'; }
EYES='[{"content":"eyes","created_at":"2026-10-20T00:30:00Z","user":{"login":"chatgpt-codex-connector[bot]"}}]'

# mk_comments <login> <createdAt> <body> [<createdAt> <body> ...]
mk_comments() {
  local login="$1"; shift
  jq -nc --arg login "$login" \
    '($ARGS.positional) as $a
     | {comments: [range(0; ($a | length); 2)
        | {author: {login: $login}, createdAt: $a[.], body: $a[. + 1]}]}' \
    --args "$@"
}

# run_ledger <comments> [threads] [reviews] [reactions] [login] [emit_tier] [push_date]
run_ledger() {
  FETCH_OK=1 ACK_EMIT_TIER="${6:-0}" ACK_CONTENT_IDENTITY=0 \
  ALL_THREADS="${2:-$EMPTY_THREADS}" ALL_REVIEWS="${3:-[]}" ALL_COMMENTS="$1" \
  ALL_CHECK_RUNS='{"check_runs":[]}' ALL_STATUSES='[]' \
  ALL_REACTIONS="${4-[]}" HEAD_SHA="$HEAD_SHA" HEAD_PUSH_DATE="${7-$PUSH_AT}" HEAD_CHECKS_DATE="" \
  bash "$ACK_SCRIPT" "${5:-$CODEX}" 2>/dev/null
}
C984=$(mk_comments "$CODEX" "$SUMMARY_AT" "$SUMMARY_984")

# --- positive: the #984 snapshot ------------------------------------------
expect "$HEAD_SHA" "$(run_ledger "$C984" "$(codex_thread true true)" "$REVIEWS_984")" \
  "#984 summary (completed, unresolved=false, HEAD) + resolved outdated threads + older reviews → HEAD"
expect "${HEAD_SHA}:G" "$(run_ledger "$C984" "" "" "[]" "" 1)" "summary ack is reported as Tier G"
expect "$HEAD_SHA" "$(run_ledger "$C984" "" "" "[]" "" "" "")" "empty push anchor: the SHA alone is the proof → HEAD"
SEC_CLEAN='{"commit_sha":"'"$FULL_HEAD"'","has_any_findings":false,"has_unresolved_findings":false,"status":"completed"}'
expect "$HEAD_SHA" "$(run_ledger "$(mk_comments "$CODEX" "$SUMMARY_AT" "$(summary_body "$(state "$FULL_HEAD" completed false "$SEC_CLEAN")")")")" \
  "security review completed clean → HEAD"

# --- negatives: the state line ---------------------------------------------
expect stale "$(run_ledger "$(mk_comments "$CODEX" "$SUMMARY_AT" "$(summary_body "$(state "$FULL_HEAD" in_progress false)")")")" \
  "code review in_progress → stale"
expect stale "$(run_ledger "$(mk_comments "$CODEX" "$SUMMARY_AT" "$(summary_body "$(state "$FULL_HEAD" completed true)")")")" \
  "has_unresolved_findings=true → stale"
expect stale "$(run_ledger "$(mk_comments "$CODEX" "$SUMMARY_AT" "$(summary_body "$(state "$FULL_HEAD" completed '"false"')")")")" \
  "has_unresolved_findings as a string → stale"
expect stale "$(run_ledger "$(mk_comments "$CODEX" "$SUMMARY_AT" "$(summary_body "$(state "$OTHER_FULL" completed false)")")")" \
  "summary naming another commit → stale"
expect stale "$(run_ledger "$(mk_comments "$CODEX" "$SUMMARY_AT" "$(summary_body "$(state "$HEAD_SHA" completed false)")")")" \
  "short commit_sha → stale (only the full SHA is read)"
SEC_OTHER='{"commit_sha":"'"$OTHER_FULL"'","has_any_findings":false,"has_unresolved_findings":false,"status":"completed"}'
expect stale "$(run_ledger "$(mk_comments "$CODEX" "$SUMMARY_AT" "$(summary_body "$(state "$FULL_HEAD" completed false "$SEC_OTHER")")")")" \
  "security review completed clean on an EARLIER commit → stale (SR must name HEAD too)"
SEC_NOSHA='{"commit_sha":null,"has_any_findings":false,"has_unresolved_findings":false,"status":"completed"}'
expect stale "$(run_ledger "$(mk_comments "$CODEX" "$SUMMARY_AT" "$(summary_body "$(state "$FULL_HEAD" completed false "$SEC_NOSHA")")")")" \
  "security review completed without a commit_sha → stale"
# An all-null security_review is also what an SR not yet started looks like, so it
# reads "never ran" only on a PR that carries no Codex Security Review comment.
SR_FOOTER=$'<details> <summary>ℹ️ About Codex security reviews in GitHub</summary>\n<br/>\n\nThis is an experimental Codex feature. Security reviews are triggered when:\n- You comment "@codex security review"\n- A regular code review gets triggered (for example, "@codex review" or when a PR is opened), and you’re opted in so security review runs alongside code review\n\nOnce complete, Codex will leave suggestions, or a comment if no findings are found.\n\n\n</details>'
SR_CLEAN_HEAD=$'### 🛡️ Codex Security Review · _Automatically triggered_\n\nSecurity review completed. No security issues were found in this pull request.\n\n'"**Reviewed commit:** \`${FULL_HEAD:0:10}\`"$'\n\n'"$SR_FOOTER"
expect stale "$(run_ledger "$(mk_comments "$CODEX" "$SUMMARY_AT" "$SUMMARY_984" "$SUMMARY_AT" "$SR_CLEAN_HEAD")")" \
  "all-null security_review on a PR with Codex Security Review activity → stale"
expect "$HEAD_SHA" "$(run_ledger "$(mk_comments "$CODEX" "$SUMMARY_AT" "$(summary_body "$(state "$FULL_HEAD" completed false "$SEC_CLEAN")")" "$SUMMARY_AT" "$SR_CLEAN_HEAD")")" \
  "security review completed clean on HEAD + its clean SR comment → HEAD"
SEC_BAD='{"commit_sha":"'"$FULL_HEAD"'","has_any_findings":true,"has_unresolved_findings":true,"status":"completed"}'
expect stale "$(run_ledger "$(mk_comments "$CODEX" "$SUMMARY_AT" "$(summary_body "$(state "$FULL_HEAD" completed false "$SEC_BAD")")")")" \
  "security review with unresolved findings → stale"
SEC_RUN='{"commit_sha":"'"$FULL_HEAD"'","has_any_findings":null,"has_unresolved_findings":null,"status":"in_progress"}'
expect stale "$(run_ledger "$(mk_comments "$CODEX" "$SUMMARY_AT" "$(summary_body "$(state "$FULL_HEAD" completed false "$SEC_RUN")")")")" \
  "security review in progress → stale"
expect stale "$(run_ledger "$(mk_comments "$CODEX" "$SUMMARY_AT" "$(summary_body '{"code_review":{"commit_sha":"'"$FULL_HEAD"'","has_unresolved_findings":false,"status":"completed"}')")")" \
  "security_review missing → stale"
for sec in '{}' '{"has_unresolved_findings":true}' '{"status":null,"has_unresolved_findings":true}' \
  '{"commit_sha":"'"$FULL_HEAD"'","has_any_findings":null,"has_unresolved_findings":null,"status":null}' \
  '{"commit_sha":null,"has_any_findings":true,"has_unresolved_findings":null,"status":null}' \
  '{"has_unresolved_findings":null,"status":null}'; do
  expect stale "$(run_ledger "$(mk_comments "$CODEX" "$SUMMARY_AT" "$(summary_body "$(state "$FULL_HEAD" completed false "$sec")")")")" \
    "security_review $sec → stale"
done
expect stale "$(run_ledger "$(mk_comments "$CODEX" "$SUMMARY_AT" "$(summary_body '{"code_review":{"commit_sha":"'"$FULL_HEAD"'",')")")" \
  "malformed state JSON → stale"
TWO_STATES=$'<!-- codex-pull-request-review-summary -->\n<!-- codex-review-state:v1 '"$(state "$FULL_HEAD" completed false)"$' -->\n<!-- codex-review-state:v1 '"$(state "$FULL_HEAD" completed true)"' -->'
expect stale "$(run_ledger "$(mk_comments "$CODEX" "$SUMMARY_AT" "$TWO_STATES")")" "two state lines in one summary → stale"
expect stale "$(run_ledger "$(mk_comments "$CODEX" "$SUMMARY_AT" "$SUMMARY_984" "$SUMMARY_AT" "$SUMMARY_984")")" \
  "two summary comments → stale"
expect stale "$(run_ledger "$(mk_comments "$CODEX" "$SUMMARY_AT" $'Quoted:\n'"$SUMMARY_984")")" \
  "marker not on the first line (quoted) → stale"

# --- negatives: the cross-checks -------------------------------------------
expect stale "$(run_ledger "$C984" "$(codex_thread false true)")" "unresolved OUTDATED Codex thread despite the flag → stale"
expect stale "$(run_ledger "$C984" "$(codex_thread false false)")" "unresolved live Codex thread → stale"
expect stale "$(run_ledger "$C984" "" "$(review_on "$FULL_HEAD")")" "a Codex /reviews entry on HEAD → stale"
expect stale "$(run_ledger "$C984" "" '[{"user":{"login":"chatgpt-codex-connector[bot]"},"commit_id":null,"submitted_at":"2026-10-20T00:35:00Z"}]')" \
  "a Codex review without a commit_id → stale"
expect stale "$(run_ledger "$C984" "" '[{"user":{"login":"chatgpt-codex-connector[bot]"},"submitted_at":"2026-10-20T00:35:00Z"}]')" \
  "a review record missing commit_id (shape drift) → stale"
for cid in '""' '"not-a-sha"'; do
  expect stale "$(run_ledger "$C984" "" '[{"user":{"login":"chatgpt-codex-connector[bot]"},"commit_id":'"$cid"',"submitted_at":"2026-10-20T00:35:00Z"}]')" \
    "a Codex review with commit_id $cid → stale"
done
expect stale "$(run_ledger "$C984" "" "" '[{"content":"eyes","created_at":"2026-10-20T00:30:00Z","user":{}}]')" \
  "a reaction without user.login (shape drift) → stale"
expect stale "$(run_ledger "$C984" "" "" '[{"created_at":"2026-10-20T00:30:00Z","user":{"login":"chatgpt-codex-connector[bot]"}}]')" \
  "a reaction without content (shape drift) → stale"
expect stale "$(run_ledger "$C984" "" "" "$EYES")" "👀 (review in flight) → stale"
expect stale "$(run_ledger "$C984" "" "" "")" "reactions not fetched → stale"
expect stale "$(run_ledger "$C984" '{"data":{}}')" "malformed ALL_THREADS → stale"
FINDINGS=$'\n### 💡 Codex Review\n\nP2: something on HEAD.'"$FOOTER"
expect stale "$(run_ledger "$(mk_comments "$CODEX" "$SUMMARY_AT" "$SUMMARY_984" "$AFTER_PUSH" "$FINDINGS")")" \
  "post-anchor comment-form finding beside a clean summary → stale"
expect stale "$(run_ledger "$(mk_comments "$CODEX" "$SUMMARY_AT" "$SUMMARY_984" "$AFTER_PUSH" "$FINDINGS")" "" "" "[]" "" "" "")" \
  "empty anchor counts every other comment → stale"
expect stale "$(run_ledger "$(mk_comments "$CODEX" "$SUMMARY_AT" "$SUMMARY_984" "$AFTER_PUSH" "$FINDINGS")" "" "" "[]" "" "" "zzzz")" \
  "malformed anchor counts every other comment → stale"
expect none "$(run_ledger "$(mk_comments "some-bot" "$SUMMARY_AT" "$SUMMARY_984")" "" "" "[]" "some-bot")" \
  "the same comment from another login → none (Codex-only)"

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] && exit 0 || exit 1
