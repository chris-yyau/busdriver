#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO_ROOT/scripts/fetch-pr-state.sh"

# t1: no shebang (must be source-only)
# shellcheck disable=SC2312  # head pipeline; head succeeds on any non-empty file
first=$(head -1 "$HELPER")
[[ "$first" =~ ^#!.+ ]] && { echo "FAIL: has shebang ($first); must be source-only"; exit 1; }
grep -q -i "sourced" <(head -3 "$HELPER") || { echo "FAIL: doc comment missing 'sourced'"; exit 1; }

# t2: sourcing under set -euo pipefail does not abort (HIGH #2 — no top-level `local`)
export PATH="$REPO_ROOT/tests/fixtures/gh-mock:$PATH"
unset FETCH_OK ALL_THREADS ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS HEAD_SHA 2>/dev/null || true
bash -c "set -euo pipefail; source '$HELPER' 123; echo OK" | grep -q OK \
    || { echo "FAIL: source aborted under set -euo pipefail"; exit 1; }

# t3: all 6 env vars set
unset FETCH_OK ALL_THREADS ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS HEAD_SHA 2>/dev/null || true
# shellcheck source=/dev/null  # $HELPER is dynamic at test time
. "$HELPER" 123
[[ "$FETCH_OK" = "1" ]] || { echo "FAIL t3: FETCH_OK='$FETCH_OK'"; exit 1; }
[[ -n "$ALL_THREADS" ]] && [[ -n "$ALL_REVIEWS" ]] && [[ -n "$ALL_COMMENTS" ]] \
    && [[ -n "$ALL_CHECK_RUNS" ]] && [[ -n "$HEAD_SHA" ]] || { echo "FAIL t3: empty env var"; exit 1; }

# t4: shapes match ack-ledger.sh's parsers (HIGH #3)
# ALL_REVIEWS must be parseable by jq -s '[.[] | .[] | select(.user.login == X)]'
echo "$ALL_REVIEWS" | jq -e 'type == "array" or type == "object"' >/dev/null \
    || { echo "FAIL t4a: ALL_REVIEWS not parseable"; exit 1; }
# ALL_COMMENTS must have .comments[] with .author.login
echo "$ALL_COMMENTS" | jq -e '.comments | type == "array"' >/dev/null \
    || { echo "FAIL t4b: ALL_COMMENTS shape wrong"; exit 1; }

# t5: gh failure → FETCH_OK=0
export PATH="$REPO_ROOT/tests/fixtures/gh-mock-fail:$PATH"
unset FETCH_OK 2>/dev/null || true
# shellcheck source=/dev/null  # $HELPER is dynamic at test time
. "$HELPER" 123
[[ "$FETCH_OK" = "0" ]] || { echo "FAIL t5: FETCH_OK not 0 on gh fail"; exit 1; }

echo "All fetch-pr-state shape tests passed"
