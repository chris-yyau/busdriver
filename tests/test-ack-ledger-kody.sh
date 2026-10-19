#!/usr/bin/env bash
# tests/test-ack-ledger-kody.sh
#
# Tier K (kody-ai, ADR 0058): Kody acks HEAD only when its `Kody Code Review`
# check-run completed `success` on HEAD (or a content-identical predecessor) AND
# the thread snapshot (THREADS_FETCHED_AT) was taken >= 60 s after completion.
# Everything else is `stale` — Kody is compulsory, so Tier K never emits `none` —
# and the block always exits, so no Kody fixture reaches a login-agnostic tier.
# An unresolved Kody thread blocks even when outdated (busdriver#989 case a), and
# a zero thread count is trusted only on a well-formed ALL_THREADS.
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
  ( cd "${2:-$repo}" && env -u HEAD_FULL_SHA -u ACK_CONTENT_IDENTITY \
      -u HEAD_PUSH_DATE -u HEAD_CHECKS_DATE -u ACK_LEDGER_TYPESAFE \
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

reset() {
  unset FETCH_OK ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS SELF_RESOLVE_OFF 2>/dev/null || true
  ALL_THREADS="$NO_THREADS"
  THREADS_FETCHED_AT=2026-10-19T00:01:10Z
}

# kody_run <id> <status> <conclusion|null> <head_sha> <completed_at|null> [slug] [name]
kody_run() {
  local concl=null done=null
  [ "$3" = null ] || concl="\"$3\""
  [ "$5" = null ] || done="\"$5\""
  printf '{"id":%s,"app":{"slug":"%s"},"name":"%s","status":"%s","conclusion":%s,"head_sha":"%s","started_at":null,"completed_at":%s}' \
    "$1" "${6:-kody-ai}" "${7:-Kody Code Review}" "$2" "$concl" "$4" "$done"
}
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

reset; ALL_CHECK_RUNS='oops'
expect "malformed ALL_CHECK_RUNS" stale "$(run_ledger kody-ai)"

reset; ALL_CHECK_RUNS="$SUCCESS"; FETCH_OK=0
expect "FETCH_OK=0" stale "$(run_ledger kody-ai)"

# Shapes of the login-agnostic terminals below Tier K (Case 3, the empty-review
# `none` return, Tier B/D): Tier K must answer first.
EMPTY_REVIEW="[{\"user\":{\"login\":\"kody-ai[bot]\"},\"commit_id\":\"$HEAD\",\"state\":\"COMMENTED\",\"body\":\"\"}]"
reset; ALL_CHECK_RUNS=$(page "$(kody_run 10 completed skipped "$HEAD" "$DONE")"); ALL_REVIEWS="$EMPTY_REVIEW"
expect "skipped run + empty-body COMMENTED Kody review" stale "$(run_ledger kody-ai)"
reset; ALL_CHECK_RUNS=$(page "$(kody_run 10 completed skipped "$HEAD" "$DONE")")
expect "skipped run, no review" stale "$(run_ledger kody-ai)"
reset; ALL_CHECK_RUNS="$SUCCESS"; THREADS_FETCHED_AT=2026-10-19T00:00:30Z; ALL_REVIEWS="$EMPTY_REVIEW"
expect "success inside the window + HEAD review (no Tier B/D ack)" stale "$(run_ledger kody-ai)"

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
reset; SELF_RESOLVE_OFF=0
expect "checkout ledger with the marker self-resolves for kody-ai" CHECKOUT "$(run_ledger kody-ai "$fake")"

# The marker the self-resolve looks for must exist, whole-line, in this ledger.
if grep -qx '# ack-ledger-capability: tier-k2' "$ACK_SCRIPT"; then ok "this ledger carries the Tier K capability marker"
else fail "capability marker line missing from scripts/ack-ledger.sh"; fi

echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
