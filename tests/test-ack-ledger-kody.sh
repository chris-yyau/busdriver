#!/usr/bin/env bash
# tests/test-ack-ledger-kody.sh
#
# Tier K (kody-ai, ADR 0058): Kody acks HEAD only when its `Kody Code Review`
# check-run completed `success` on HEAD (or a content-identical predecessor) AND
# the thread snapshot (THREADS_FETCHED_AT) was taken >= 60 s after completion.
# Everything else is `stale` — Kody is compulsory, so Tier K never emits `none` —
# and the block always exits, so no Kody fixture reaches a login-agnostic tier.
# An unresolved Kody thread blocks even when outdated (busdriver#989 case a), and
# a zero thread count is trusted only on a well-formed ALL_THREADS. A Kody status
# comment saying its findings "could not be posted", created for the deciding run
# or later, vetoes the ack (busdriver#1059).
# Also covers Decision 8: an older checkout ledger without the Tier K capability
# marker never judges kody-ai through the self-resolve re-exec.

set -euo pipefail
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ACK_SCRIPT="$SCRIPT_DIR/scripts/ack-ledger.sh"

passed=0
failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — ack-ledger.sh tier parsing requires it"
  exit 0
fi

TMP_DIRS=()
cleanup() { local d; for d in "${TMP_DIRS[@]:-}"; do [ -n "${d:-}" ] && rm -rf "$d"; done; return 0; }
trap cleanup EXIT

repo=$(mktemp -d); TMP_DIRS+=("$repo")
git -C "$repo" init -q
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name tester
git -C "$repo" config commit.gpgsign false
( cd "$repo" && echo v1 > f.txt && git add f.txt && git commit -qm "feat: thing" )
OLD=$(git -C "$repo" rev-parse HEAD)
( cd "$repo" && git commit -q --amend -m "feat: thing (message only)" )
HEAD=$(git -C "$repo" rev-parse HEAD); HEAD8=${HEAD:0:8}
OTHER=0123456789abcdef0123456789abcdef01234567

DONE=2026-10-19T00:00:00Z

# run_ledger <login> [cwd] — fixture vars come from the environment below.
run_ledger() {
  # Scrub inherited ledger inputs so a caller's exported value cannot flip a case.
  # HEAD_FULL_SHA reaches the ledger only when a case sets CASE_FULL_SHA (set-empty
  # stays distinct from unset): `env -u X ... X=v` unsets first, then sets.
  ( cd "${2:-$repo}" && env -u HEAD_FULL_SHA -u ACK_CONTENT_IDENTITY \
      -u HEAD_PUSH_DATE -u HEAD_CHECKS_DATE \
      ${CASE_FULL_SHA+HEAD_FULL_SHA="$CASE_FULL_SHA"} \
      BUSDRIVER_DISABLE_ACK_SELF_RESOLVE="${SELF_RESOLVE_OFF:-1}" \
      ACK_EMIT_TIER=1 \
      FETCH_OK="${FETCH_OK:-1}" \
      HEAD_SHA="$HEAD8" \
      THREADS_FETCHED_AT="${THREADS_FETCHED_AT-2026-10-19T00:01:10Z}" \
      ALL_REVIEWS="${ALL_REVIEWS:-}" \
      ALL_THREADS="${ALL_THREADS:-}" \
      ALL_COMMENTS="${ALL_COMMENTS:-}" \
      ALL_CHECK_RUNS="${ALL_CHECK_RUNS:-}" \
      ALL_STATUSES="" ALL_REACTIONS="" \
      bash "$ACK_SCRIPT" "$1" 2>/dev/null || echo "ERR" )
}

NO_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
NO_COMMENTS='{"comments":[]}'

reset() {
  unset FETCH_OK ALL_REVIEWS ALL_CHECK_RUNS SELF_RESOLVE_OFF CASE_FULL_SHA 2>/dev/null || true
  ALL_THREADS="$NO_THREADS"
  ALL_COMMENTS="$NO_COMMENTS"
  THREADS_FETCHED_AT=2026-10-19T00:01:10Z
}

# kody_run <id> <status> <conclusion|null> <head_sha> <completed_at|null> [slug] [name] [started_at|null]
# started_at defaults to START when the run has completed, else null.
START=2026-10-18T23:40:00Z
kody_run() {
  local concl=null done=null start=null
  [ "$3" = null ] || concl="\"$3\""
  [ "$5" = null ] || { done="\"$5\""; start="\"$START\""; }
  case "${8-}" in '') ;; null) start=null ;; *) start="\"$8\"" ;; esac
  printf '{"id":%s,"app":{"slug":"%s"},"name":"%s","status":"%s","conclusion":%s,"head_sha":"%s","started_at":%s,"completed_at":%s}' \
    "$1" "${6:-kody-ai}" "${7:-Kody Code Review}" "$2" "$concl" "$4" "$start" "$done"
}
# comments <login> <createdAt> <first line> — one issue comment in `gh pr view --json comments` shape.
comments() {
  jq -cn --arg l "$1" --arg c "$2" --arg b "$3" \
    '{comments:[{author:{login:$l},createdAt:$c,body:($b + "\n\nThe review produced 2 comment(s).")}]}'
}
UNPOSTED='## Code Review Completed, but its comments could not be posted ⚠️'
page() { local IFS=,; printf '{"check_runs":[%s]}' "$*"; }
thread() { # <isResolved> <isOutdated> [first-comment author JSON]
  local author='{"login":"kody-ai"}'
  [ $# -lt 3 ] || author=$3
  printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":%s,"isOutdated":%s,"comments":{"nodes":[{"author":%s}]}}]}}}}}' "$1" "$2" "$author"
}

expect() { # <label> <expected> <actual>
  if [ "$3" = "$2" ]; then ok "$1 ($3)"; else fail "$1: expected '$2', got '$3'"; fi
}

SUCCESS=$(page "$(kody_run 10 completed success "$HEAD" "$DONE")")

reset; ALL_CHECK_RUNS="$SUCCESS"
expect "success settled 70 s before snapshot acks at K" "$HEAD8:K" "$(run_ledger kody-ai)"

reset; ALL_CHECK_RUNS="$SUCCESS"; THREADS_FETCHED_AT=2026-10-19T00:01:00Z
expect "exactly 60 s acks" "$HEAD8:K" "$(run_ledger kody-ai)"

reset; ALL_CHECK_RUNS="$SUCCESS"; THREADS_FETCHED_AT=2026-10-19T00:00:59Z
expect "59 s is inside the settle window" stale "$(run_ledger kody-ai)"

reset; ALL_CHECK_RUNS="$SUCCESS"; THREADS_FETCHED_AT=2026-10-18T23:59:00Z
expect "snapshot older than completion" stale "$(run_ledger kody-ai)"

reset; ALL_CHECK_RUNS="$SUCCESS"; THREADS_FETCHED_AT=""
expect "THREADS_FETCHED_AT empty" stale "$(run_ledger kody-ai)"

reset; ALL_CHECK_RUNS="$SUCCESS"; THREADS_FETCHED_AT="2026-10-19 00:01:10"
expect "THREADS_FETCHED_AT malformed" stale "$(run_ledger kody-ai)"

reset; ALL_CHECK_RUNS=$(page "$(kody_run 10 completed success "$HEAD" null)")
expect "completed_at null" stale "$(run_ledger kody-ai)"

reset; ALL_CHECK_RUNS=$(page "$(kody_run 10 completed success "$HEAD" 2026-10-19T00:00:00.500Z)")
expect "completed_at fractional" stale "$(run_ledger kody-ai)"

reset; ALL_CHECK_RUNS=$(page "$(kody_run 10 in_progress null "$HEAD" null)")
expect "in_progress" stale "$(run_ledger kody-ai)"

reset; ALL_CHECK_RUNS=$(page "$(kody_run 10 queued null "$HEAD" null)")
expect "queued with started_at null" stale "$(run_ledger kody-ai)"

for c in failure cancelled timed_out neutral skipped action_required stale; do
  reset; ALL_CHECK_RUNS=$(page "$(kody_run 10 completed "$c" "$HEAD" "$DONE")")
  expect "conclusion $c" stale "$(run_ledger kody-ai)"
done

reset; ALL_CHECK_RUNS=$(page "$(kody_run 9 in_progress null "$HEAD" null)" "$(kody_run 10 completed success "$HEAD" "$DONE")")
expect "older run still in_progress beside newer success" stale "$(run_ledger kody-ai)"

reset; ALL_CHECK_RUNS=$(page "$(kody_run 10 completed success "$HEAD" "$DONE")" "$(kody_run 11 queued null "$HEAD" null)")
expect "newer queued run beside older success" stale "$(run_ledger kody-ai)"

reset; ALL_CHECK_RUNS="$SUCCESS"; ALL_THREADS=$(thread false false)
expect "open non-outdated Kody thread blocks first (Tier A)" stale "$(run_ledger kody-ai)"

reset; ALL_CHECK_RUNS="$SUCCESS"; ALL_THREADS=$(thread true true)
expect "disposed Kody threads do not block a settled success" "$HEAD8:K" "$(run_ledger kody-ai)"

# busdriver#989 case (a): a push changed the finding's lines without fixing it;
# Kody's run on it completed success and raised nothing new, the old thread went
# outdated and stayed open.
reset; ALL_CHECK_RUNS="$SUCCESS"; ALL_THREADS=$(thread false true)
expect "case (a): unresolved OUTDATED Kody thread + settled success" stale "$(run_ledger kody-ai)"
reset; ALL_CHECK_RUNS="$SUCCESS"; ALL_THREADS=$(thread false true '{"login":"kody-ai[bot]"}')
expect "case (a) with the [bot] login form" stale "$(run_ledger kody-ai)"
reset; ALL_CHECK_RUNS="$SUCCESS"; ALL_THREADS=$(thread true false)
expect "the same thread resolved" "$HEAD8:K" "$(run_ledger kody-ai)"
reset; ALL_CHECK_RUNS="$SUCCESS"; ALL_THREADS=$(thread false true '{"login":"someone-else"}')
expect "an outdated thread by another login does not block Kody" "$HEAD8:K" "$(run_ledger kody-ai)"

# A zero count is trusted only on a well-formed ALL_THREADS (Tier G's predicate).
reset; ALL_CHECK_RUNS="$SUCCESS"
expect "well-formed page with zero threads" "$HEAD8:K" "$(run_ledger kody-ai)"
reset; ALL_CHECK_RUNS="$SUCCESS"; ALL_THREADS=""
expect "ALL_THREADS empty" stale "$(run_ledger kody-ai)"
reset; ALL_CHECK_RUNS="$SUCCESS"; ALL_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isOutdated":true,"comments":{"nodes":[{"author":{"login":"kody-ai"}}]}}]}}}}}'
expect "node missing isResolved" stale "$(run_ledger kody-ai)"
reset; ALL_CHECK_RUNS="$SUCCESS"; ALL_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":"yes","comments":{"nodes":[{"author":{"login":"kody-ai"}}]}}]}}}}}'
expect "non-boolean isOutdated" stale "$(run_ledger kody-ai)"
reset; ALL_CHECK_RUNS="$SUCCESS"; ALL_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":true,"comments":{"nodes":[]}}]}}}}}'
expect "empty comments.nodes" stale "$(run_ledger kody-ai)"
reset; ALL_CHECK_RUNS="$SUCCESS"; ALL_THREADS=$(thread false true '{}')
expect "first comment author {}" stale "$(run_ledger kody-ai)"
reset; ALL_CHECK_RUNS="$SUCCESS"; ALL_THREADS=$(thread false true '{"login":null}')
expect "first comment author login null" stale "$(run_ledger kody-ai)"
reset; ALL_CHECK_RUNS="$SUCCESS"; ALL_THREADS=$(thread true true null)
expect "deleted-account (null) author is well-formed" "$HEAD8:K" "$(run_ledger kody-ai)"

reset; ALL_THREADS=$(thread true true)
ALL_COMMENTS='{"comments":[{"author":{"login":"kody-ai[bot]"},"body":"# Kody Review Complete"}]}'
expect "disposed threads + comment, no check-run: never a disposed-thread A" stale "$(run_ledger kody-ai)"

reset
expect "no check-run and no Kody artifact (compulsory, never none)" stale "$(run_ledger kody-ai)"

reset; ALL_CHECK_RUNS=$(page "$(kody_run 10 completed success "$OTHER" "$DONE")")
expect "deciding run's head_sha fails acks_head" stale "$(run_ledger kody-ai)"

reset; ALL_CHECK_RUNS=$(page "$(kody_run 10 completed success "$OLD" "$DONE")")
expect "content-identical predecessor's success acks" "$HEAD8:K" "$(run_ledger kody-ai)"

reset; ALL_CHECK_RUNS=$(page "$(kody_run 10 completed success "$HEAD" "$DONE" impostor-app)")
expect "another app's 'Kody Code Review' run is ignored" stale "$(run_ledger kody-ai)"

reset; ALL_CHECK_RUNS="$(page "$(kody_run 3 completed success "$HEAD" "$DONE" other-app 'CI')")$(page "$(kody_run 10 completed success "$HEAD" "$DONE")")"
expect "Kody run on page 2 of a paginated stream" "$HEAD8:K" "$(run_ledger kody-ai)"

# busdriver#1059: Kody's status comment, created when the run starts (START), says
# the findings could not be posted, while the run itself completed success.
reset; ALL_CHECK_RUNS="$SUCCESS"; ALL_COMMENTS=$(comments kody-ai 2026-10-18T23:40:04Z "$UNPOSTED")
expect "#1059: unposted-findings comment for the deciding run" stale "$(run_ledger kody-ai)"
reset; ALL_CHECK_RUNS="$SUCCESS"; ALL_COMMENTS=$(comments 'kody-ai[bot]' 2026-10-18T23:40:04Z "$UNPOSTED")
expect "#1059: the same with the [bot] login form" stale "$(run_ledger kody-ai)"
reset; ALL_CHECK_RUNS="$SUCCESS"; ALL_COMMENTS=$(comments kody-ai 2026-10-18T23:39:30Z "$UNPOSTED")
expect "#1059: created up to 60 s before started_at still vetoes" stale "$(run_ledger kody-ai)"
reset; ALL_CHECK_RUNS="$SUCCESS"; ALL_COMMENTS=$(comments kody-ai 2026-10-18T23:20:00Z "$UNPOSTED")
expect "#1059: an earlier run's comment is cleared by a newer success" "$HEAD8:K" "$(run_ledger kody-ai)"
reset; ALL_CHECK_RUNS="$SUCCESS"; ALL_COMMENTS=$(comments someone-else 2026-10-18T23:40:04Z "$UNPOSTED")
expect "#1059: the text from another login does not veto" "$HEAD8:K" "$(run_ledger kody-ai)"
reset; ALL_CHECK_RUNS="$SUCCESS"; ALL_COMMENTS=$(comments kody-ai 2026-10-18T23:40:04Z '## Code Review Completed! 🔥')
expect "#1059: a clean completion comment does not veto" "$HEAD8:K" "$(run_ledger kody-ai)"
reset; ALL_CHECK_RUNS="$SUCCESS"; ALL_COMMENTS=""
expect "#1059: ALL_COMMENTS empty" stale "$(run_ledger kody-ai)"
reset; ALL_CHECK_RUNS="$SUCCESS"; ALL_COMMENTS='{"comments":[{"author":{"login":"kody-ai"},"body":"x"}]}'
expect "#1059: comment missing createdAt" stale "$(run_ledger kody-ai)"
reset; ALL_CHECK_RUNS="$SUCCESS"; ALL_COMMENTS='{"nodes":[]}'
expect "#1059: drifted ALL_COMMENTS shape" stale "$(run_ledger kody-ai)"
reset; ALL_CHECK_RUNS=$(page "$(kody_run 10 completed success "$HEAD" "$DONE" kody-ai 'Kody Code Review' null)")
expect "#1059: started_at null" stale "$(run_ledger kody-ai)"

reset; ALL_CHECK_RUNS='oops'
expect "malformed ALL_CHECK_RUNS" stale "$(run_ledger kody-ai)"

reset; ALL_CHECK_RUNS="$SUCCESS"; FETCH_OK=0
expect "FETCH_OK=0" stale "$(run_ledger kody-ai)"

# Shapes of the login-agnostic terminals below Tier K (a skipped check-run, the
# empty-review `none` return, Tier B/D): Tier K must answer first.
EMPTY_REVIEW="[{\"user\":{\"login\":\"kody-ai[bot]\"},\"commit_id\":\"$HEAD\",\"state\":\"COMMENTED\",\"body\":\"\"}]"
reset; ALL_CHECK_RUNS=$(page "$(kody_run 10 completed skipped "$HEAD" "$DONE")"); ALL_REVIEWS="$EMPTY_REVIEW"
expect "skipped run + empty-body COMMENTED Kody review" stale "$(run_ledger kody-ai)"
reset; ALL_CHECK_RUNS=$(page "$(kody_run 10 completed skipped "$HEAD" "$DONE")")
expect "skipped run, no review" stale "$(run_ledger kody-ai)"
reset; ALL_CHECK_RUNS="$SUCCESS"; THREADS_FETCHED_AT=2026-10-19T00:00:30Z; ALL_REVIEWS="$EMPTY_REVIEW"
expect "success inside the window + HEAD review (no Tier B/D ack)" stale "$(run_ledger kody-ai)"

# --- ADR 0064: the unlicensed-Cursor skip is waived (`skipped-unlicensed`), never acked ---
# Positive inputs are the real bytes of Dive-And-Dev/chrisyau.me#462 (check-run
# 131335693133 and the PR's GraphQL number+author); only head_sha is rewritten
# to this test repo's HEAD. Every negative changes exactly one thing.
FIX_RUNS="$SCRIPT_DIR/tests/fixtures/kody/unlicensed-cursor-462.json"
FIX_PR="$SCRIPT_DIR/tests/fixtures/kody/unlicensed-cursor-462-pr.json"
W_FETCHED=2026-11-12T16:46:19Z   # fixture completed_at + 70 s
# fixture_runs [jq-filter] — the real run on HEAD, then an optional mutation of the page.
fixture_runs() { jq -c --arg h "$HEAD" "(.check_runs[0].head_sha = \$h) | ${1:-.}" "$FIX_RUNS"; }
# pr_page [jq-filter] — NO_THREADS with the real pullRequest number+author, then a mutation.
pr_page() { jq -c --slurpfile p "$FIX_PR" ".data.repository.pullRequest += \$p[0] | ${1:-.}" <<<"$NO_THREADS"; }
waive_reset() {
  reset
  CASE_FULL_SHA=$HEAD
  THREADS_FETCHED_AT=$W_FETCHED
  ALL_THREADS=$(pr_page)
  ALL_CHECK_RUNS=$(fixture_runs)
}
W=skipped-unlicensed
SUCC_FROM_FIX='.check_runs[0] + {conclusion:"success", output:{title:"Code Review Completed",summary:""}}'

waive_reset
expect "P1 real PR-462 fixture: waived with the bare token" "$W" "$(run_ledger kody-ai)"
if [ "$(jq -r '.check_runs[0].output.summary' "$FIX_RUNS" | od -An -tx1 | tr -d ' \n' | grep -c 'e28094')" = 1 ]; then
  ok "fixture summary carries the real U+2014 bytes"; else fail "fixture summary lost its em dash"; fi

waive_reset; unset CASE_FULL_SHA
expect "P2a HEAD_FULL_SHA unset" stale "$(run_ledger kody-ai)"
waive_reset; CASE_FULL_SHA=""
expect "P2b HEAD_FULL_SHA empty" stale "$(run_ledger kody-ai)"
waive_reset; CASE_FULL_SHA=$HEAD8
expect "P2c HEAD_FULL_SHA is the 8-char prefix" stale "$(run_ledger kody-ai)"
waive_reset; CASE_FULL_SHA=$(printf '%s' "$HEAD" | tr 'a-f' 'A-F')
expect "P2d HEAD_FULL_SHA uppercase" stale "$(run_ledger kody-ai)"
waive_reset; CASE_FULL_SHA=$OTHER
expect "P2e HEAD_FULL_SHA a different full SHA" stale "$(run_ledger kody-ai)"
waive_reset; CASE_FULL_SHA=$HEAD8; ALL_CHECK_RUNS=$(fixture_runs ".check_runs[0].head_sha = \"$HEAD8\"")
expect "P3a head_sha and HEAD_FULL_SHA both the 8-char prefix (only the regex refuses)" stale "$(run_ledger kody-ai)"
UP=$(printf '%s' "$HEAD" | tr 'a-f' 'A-F')
waive_reset; CASE_FULL_SHA=$UP; ALL_CHECK_RUNS=$(fixture_runs ".check_runs[0].head_sha = \"$UP\"")
expect "P3b head_sha and HEAD_FULL_SHA both uppercase (only the regex refuses)" stale "$(run_ledger kody-ai)"

waive_reset; ALL_THREADS=$(pr_page '.data.repository.pullRequest.author.__typename = "User"')
expect "N1 author is a User named cursor" stale "$(run_ledger kody-ai)"
waive_reset; ALL_THREADS=$(pr_page '.data.repository.pullRequest.author.databaseId = 1')
expect "N2 Bot/cursor with another databaseId" stale "$(run_ledger kody-ai)"
waive_reset; ALL_THREADS=$(pr_page '.data.repository.pullRequest.author.login = "cursor-agent"')
expect "N3 another bot login" stale "$(run_ledger kody-ai)"
waive_reset; ALL_THREADS=$(pr_page 'del(.data.repository.pullRequest.author)')
expect "N4a author key missing" stale "$(run_ledger kody-ai)"
waive_reset; ALL_THREADS=$(pr_page '.data.repository.pullRequest.author = null')
expect "N4b author null" stale "$(run_ledger kody-ai)"
waive_reset; ALL_THREADS="$(pr_page)
$(pr_page '.data.repository.pullRequest.author.__typename = "User"')"
expect "N5 second page carries a different author" stale "$(run_ledger kody-ai)"
waive_reset; ALL_THREADS=""
expect "N6 ALL_THREADS empty" stale "$(run_ledger kody-ai)"
waive_reset; ALL_CHECK_RUNS=$(fixture_runs '.check_runs[0].app.id = 1')
expect "N7 right slug, wrong app id" stale "$(run_ledger kody-ai)"
waive_reset; ALL_CHECK_RUNS=$(fixture_runs '.check_runs[0].app.slug = "kody-ai-evil"')
expect "N8 another app's run with the same name and text" stale "$(run_ledger kody-ai)"
waive_reset; ALL_CHECK_RUNS=$(fixture_runs '.check_runs[0].output.summary |= sub("—"; "-")')
expect "N9 hyphen instead of the em dash" stale "$(run_ledger kody-ai)"
waive_reset; ALL_CHECK_RUNS=$(fixture_runs '.check_runs[0].output.summary += " (x)"')
expect "N10a summary with trailing text" stale "$(run_ledger kody-ai)"
waive_reset; ALL_CHECK_RUNS=$(fixture_runs '.check_runs[0].output.title = "Code Review skipped"')
expect "N10b title case differs" stale "$(run_ledger kody-ai)"
waive_reset; ALL_CHECK_RUNS=$(fixture_runs '.check_runs[0].conclusion = "neutral"')
expect "N11 neutral with the same text" stale "$(run_ledger kody-ai)"
waive_reset; ALL_CHECK_RUNS=$(fixture_runs '.check_runs[0].output.summary = "Only Merge Commits"')
expect "N12a merge-only skip" stale "$(run_ledger kody-ai)"
waive_reset; ALL_CHECK_RUNS=$(fixture_runs '.check_runs[0].output.summary = "Branch Mismatch"')
expect "N12b branch-mismatch skip" stale "$(run_ledger kody-ai)"
waive_reset; ALL_CHECK_RUNS=$(fixture_runs '.check_runs += [.check_runs[0] + {id: (.check_runs[0].id + 1), status: "in_progress", conclusion: null}]')
expect "N13 a newer Kody run still in progress" stale "$(run_ledger kody-ai)"
waive_reset; ALL_CHECK_RUNS=$(fixture_runs ".check_runs += [($SUCC_FROM_FIX) + {id: (.check_runs[0].id + 1)}]")
expect "N14 a newer settled success decides (a real ack)" "$HEAD8:K" "$(run_ledger kody-ai)"
waive_reset; ALL_CHECK_RUNS=$(fixture_runs ".check_runs += [($SUCC_FROM_FIX) + {id: (.check_runs[0].id - 1)}]")
expect "N15 the newer skip decides over an older success" "$W" "$(run_ledger kody-ai)"
waive_reset; ALL_CHECK_RUNS=$(fixture_runs ".check_runs[0].head_sha = \"$OLD\"")
expect "N16 content-identical predecessor's skip (no carry-forward)" stale "$(run_ledger kody-ai)"
waive_reset; ALL_CHECK_RUNS=$(fixture_runs ".check_runs[0].head_sha = \"${HEAD8}ffffffffffffffffffffffffffffffff\"")
expect "N17a another SHA sharing HEAD's 8-char prefix" stale "$(run_ledger kody-ai)"
waive_reset; ALL_CHECK_RUNS=$(fixture_runs ".check_runs[0].head_sha = \"$OTHER\"")
expect "N17b another SHA" stale "$(run_ledger kody-ai)"
waive_reset; ALL_THREADS=$(thread false true | jq -c --slurpfile p "$FIX_PR" '.data.repository.pullRequest += $p[0]')
expect "N18 unresolved outdated Kody thread" stale "$(run_ledger kody-ai)"
waive_reset; THREADS_FETCHED_AT=2026-11-12T16:46:08Z
expect "N19a snapshot 59 s after completion" stale "$(run_ledger kody-ai)"
waive_reset; THREADS_FETCHED_AT=""
expect "N19b THREADS_FETCHED_AT empty" stale "$(run_ledger kody-ai)"
waive_reset; ALL_CHECK_RUNS=$(fixture_runs '.check_runs[0].started_at = null')
expect "N20 started_at null" stale "$(run_ledger kody-ai)"
waive_reset; ALL_COMMENTS='{}'
expect "N21a malformed ALL_COMMENTS" stale "$(run_ledger kody-ai)"
waive_reset; ALL_COMMENTS=$(comments kody-ai 2026-11-12T16:45:08Z "$UNPOSTED")
expect "N21b unposted-findings comment for this run" stale "$(run_ledger kody-ai)"
waive_reset; ALL_COMMENTS=$(comments kody-ai 2026-11-12T15:45:00Z "$UNPOSTED")
expect "N21c an earlier run's unposted findings still veto a skip" stale "$(run_ledger kody-ai)"
waive_reset; ALL_COMMENTS=$(comments kody-ai 2026-11-12T15:45:00Z "$UNPOSTED"); ALL_CHECK_RUNS=$(fixture_runs ".check_runs = [($SUCC_FROM_FIX)]")
expect "N21d success path keeps its started_at window (control)" "$HEAD8:K" "$(run_ledger kody-ai)"
waive_reset; FETCH_OK=0
expect "N22 FETCH_OK=0" stale "$(run_ledger kody-ai)"
waive_reset; ALL_CHECK_RUNS=$(fixture_runs '.check_runs[0] |= (.conclusion = "skipped-unlicensed" | .app.id = 1 | del(.output))')
expect "N23 a raw conclusion spelled like the token" stale "$(run_ledger kody-ai)"
waive_reset
case "$(run_ledger chatgpt-codex-connector)" in "$W") fail "N24 the waiver leaked to another login" ;; *) ok "N24 the waiver is kody-ai only" ;; esac
for idf in '"invalid"' null 0 1.5; do
  waive_reset; ALL_CHECK_RUNS=$(fixture_runs ".check_runs[0].id = $idf")
  expect "N25 skip run id $idf" stale "$(run_ledger kody-ai)"
done
waive_reset; ALL_CHECK_RUNS=$(fixture_runs 'del(.check_runs[0].id)')
expect "N25 skip run id missing" stale "$(run_ledger kody-ai)"
waive_reset; ALL_CHECK_RUNS=$(fixture_runs '.check_runs += [.check_runs[0] + {id: "zzz", conclusion: "failure"}]')
expect "N25 a string-id run beside the skip (order unprovable)" stale "$(run_ledger kody-ai)"
for prs in '[]' '[{"number":999}]' '[{"number":462},{"number":999}]' '{"bogus":{"number":462}}'; do
  waive_reset; ALL_CHECK_RUNS=$(fixture_runs ".check_runs[0].pull_requests = $prs")
  expect "N26 pull_requests $prs" stale "$(run_ledger kody-ai)"
done
waive_reset; ALL_CHECK_RUNS=$(fixture_runs 'del(.check_runs[0].pull_requests)')
expect "N26 pull_requests missing" stale "$(run_ledger kody-ai)"
waive_reset; ALL_THREADS=$(pr_page 'del(.data.repository.pullRequest.number)')
expect "N27a pullRequest.number missing" stale "$(run_ledger kody-ai)"
waive_reset; ALL_THREADS="$(pr_page)
$(pr_page '.data.repository.pullRequest.number = 463')"
expect "N27b pages disagree on the PR number" stale "$(run_ledger kody-ai)"
waive_reset; ALL_CHECK_RUNS=$(fixture_runs ".check_runs[0].head_sha = \"$HEAD \"")
expect "N28 head_sha padded with a space" stale "$(run_ledger kody-ai)"
waive_reset; ALL_CHECK_RUNS=$(fixture_runs '.check_runs[0].completed_at = null | .check_runs[0].started_at = "2026-11-12T16:45:07Z 2026-11-12T16:45:09Z"')
expect "N29 null completed_at cannot shift a smuggled timestamp into place" stale "$(run_ledger kody-ai)"
waive_reset; ALL_CHECK_RUNS=$(fixture_runs '.check_runs = {"x": .check_runs[0]}')
expect "N30 object-shaped check_runs" stale "$(run_ledger kody-ai)"

# --- Decision 8: self-resolve never hands kody-ai to a ledger without Tier K ---
fake=$(mktemp -d); TMP_DIRS+=("$fake")
git -C "$fake" init -q
git -C "$fake" remote add origin https://github.com/chris-yyau/busdriver.git
mkdir -p "$fake/scripts"
printf '#!/usr/bin/env bash\necho CHECKOUT\n' > "$fake/scripts/ack-ledger.sh"

reset; SELF_RESOLVE_OFF=0; ALL_CHECK_RUNS="$SUCCESS"
expect "older checkout ledger (no marker) does not judge kody-ai; the loaded one does" "$HEAD8:K" "$(run_ledger kody-ai "$fake")"
reset; SELF_RESOLVE_OFF=0
expect "other logins still self-resolve into the checkout" CHECKOUT "$(run_ledger chatgpt-codex-connector "$fake")"
printf '#!/usr/bin/env bash\n# ack-ledger-capability: tier-k\necho CHECKOUT\n' > "$fake/scripts/ack-ledger.sh"
reset; SELF_RESOLVE_OFF=0; ALL_CHECK_RUNS="$SUCCESS"
expect "checkout carrying only the older tier-k marker is not trusted" "$HEAD8:K" "$(run_ledger kody-ai "$fake")"
printf '#!/usr/bin/env bash\n# ack-ledger-capability: tier-k2\necho CHECKOUT\n' > "$fake/scripts/ack-ledger.sh"
reset; SELF_RESOLVE_OFF=0; ALL_CHECK_RUNS="$SUCCESS"
expect "checkout carrying only the tier-k2 marker (no #1059 veto) is not trusted" "$HEAD8:K" "$(run_ledger kody-ai "$fake")"
printf '#!/usr/bin/env bash\n# ack-ledger-capability: tier-k3\necho CHECKOUT\n' > "$fake/scripts/ack-ledger.sh"
reset; SELF_RESOLVE_OFF=0; ALL_CHECK_RUNS="$SUCCESS"
expect "checkout carrying only the tier-k3 marker (no ADR 0064 waiver) is not trusted" "$HEAD8:K" "$(run_ledger kody-ai "$fake")"
printf '#!/usr/bin/env bash\n# ack-ledger-capability: tier-k4\necho CHECKOUT\n' > "$fake/scripts/ack-ledger.sh"
reset; SELF_RESOLVE_OFF=0
expect "checkout ledger with the marker self-resolves for kody-ai" CHECKOUT "$(run_ledger kody-ai "$fake")"

# The marker the self-resolve looks for must exist, whole-line, in this ledger.
if grep -qx '# ack-ledger-capability: tier-k4' "$ACK_SCRIPT"; then ok "this ledger carries the Tier K capability marker"
else fail "capability marker line missing from scripts/ack-ledger.sh"; fi

echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
