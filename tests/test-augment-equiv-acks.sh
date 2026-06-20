#!/usr/bin/env bash
# tests/test-augment-equiv-acks.sh
#
# Verifies scripts/augment-equiv-acks.sh — the sourced helper that makes Tier D
# (check-run) carry forward across a message-only `git commit --amend` force-push.
# The HEAD-scoped fetch only sees HEAD's check-runs, so a bot's check-run on the
# PRE-amend SHA is invisible; this helper derives the content-identical predecessor
# SHA, fetches ITS check-runs, and appends them so the ledger's Tier D can ack HEAD.
# (Tier E commit-statuses are deliberately NOT carried forward — see the helper.)
#
# `gh` is stubbed (a fake on PATH); `git` is real (temp repos). The end-to-end
# assertion runs the REAL scripts/ack-ledger.sh against the widened inputs, so a
# pass means the production Tier D path works, not just the helper in isolation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AUGMENT="$SCRIPT_DIR/scripts/augment-equiv-acks.sh"
ACK_SCRIPT="$SCRIPT_DIR/scripts/ack-ledger.sh"

passed=0; failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

for f in "$AUGMENT" "$ACK_SCRIPT"; do
  [ -f "$f" ] || { fail "missing $f"; echo "Results: $passed passed, $failed failed"; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP_DIRS=()
cleanup() { local d; for d in "${TMP_DIRS[@]:-}"; do [ -n "${d:-}" ] && rm -rf "$d"; done; return 0; }
trap cleanup EXIT

mk() { local d; d=$(mktemp -d); TMP_DIRS+=("$d"); printf '%s' "$d"; }

# A fake `gh`: returns the repo slug; for any commits/<sha>/check-runs call echoes
# $STUB_CHECKRUNS; for a graphql call returns a force-push timeline whose
# beforeCommit.oid is $STUB_TIMELINE_OID (or {} when unset).
make_gh_stub() {
  local bindir="$1"
  cat > "$bindir/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then echo "test-owner/test-repo"; exit 0; fi
if [ "$1" = "api" ]; then
  case "$*" in *graphql*)
    if [ -n "${STUB_TIMELINE_OID:-}" ]; then
      printf '{"data":{"repository":{"pullRequest":{"timelineItems":{"nodes":[{"beforeCommit":{"oid":"%s"}}]}}}}}' "$STUB_TIMELINE_OID"
    else echo '{}'; fi
    exit 0 ;;
  esac
  for a in "$@"; do
    case "$a" in
      */check-runs) printf '%s' "${STUB_CHECKRUNS:-}"; exit 0 ;;
    esac
  done
  exit 0
fi
exit 0
STUB
  chmod +x "$bindir/gh"
}

# run_augment <repo> — source the helper with CWD inside <repo>, env preset by caller.
run_augment() {
  local repo="$1" bindir="$2"
  ( cd "$repo" && PATH="$bindir:$PATH" bash -c '
      set -euo pipefail
      ALL_CHECK_RUNS="${ALL_CHECK_RUNS:-}"; ALL_STATUSES="${ALL_STATUSES:-}"
      . "'"$AUGMENT"'"
      printf "%s" "$ALL_CHECK_RUNS"
    ' )
}

reviews_json() { printf '[{"user":{"login":"%s[bot]"},"commit_id":"%s","state":"%s"}]' "$1" "$2" "$3"; }
checkruns_json() { printf '{"check_runs":[{"app":{"slug":"%s"},"conclusion":"success","head_sha":"%s"}]}' "$1" "$2"; }

# ============================================================
# 1. POSITIVE — message-only amend: predecessor's cursor check-run is fetched,
#    and the real ledger then HEAD-acks cursor via Tier D.
# ============================================================
repo=$(mk); bin=$(mk); make_gh_stub "$bin"
( cd "$repo" && git init -q && git config user.email t@e && git config user.name t && git config commit.gpgsign false \
   && echo v1 > f.txt && git add f.txt && git commit -qm "feat: thing" )
OLD=$(git -C "$repo" rev-parse HEAD)
( cd "$repo" && git commit -q --amend -m "feat: thing (commitlint-shortened)" )
NEW=$(git -C "$repo" rev-parse HEAD); NEW8=${NEW:0:8}

export HEAD_SHA="$NEW8" HEAD_FULL_SHA="$NEW"
ALL_REVIEWS="$(reviews_json cubic-dev-ai "$OLD" COMMENTED)"; export ALL_REVIEWS  # cubic kept its pre-amend /reviews entry → predecessor SHA
export ALL_COMMENTS='' ALL_CHECK_RUNS='' ALL_STATUSES=''
STUB_CHECKRUNS="$(checkruns_json cursor "$OLD")"; export STUB_CHECKRUNS          # cursor's check-run lives on the OLD sha
export STUB_STATUSES=''
widened=$(run_augment "$repo" "$bin")
if printf '%s' "$widened" | jq -es '[.[]?|.check_runs[]?|select(.app.slug=="cursor")]|length>0' >/dev/null 2>&1; then
  ok "augment fetched the predecessor's cursor check-run into ALL_CHECK_RUNS"
else
  fail "augment did NOT widen ALL_CHECK_RUNS with the predecessor check-run (got: $(printf '%s' "$widened" | head -c 200))"
fi
# End-to-end: real ledger on the widened inputs → cursor HEAD-acks via Tier D.
out=$( cd "$repo" && env BUSDRIVER_DISABLE_ACK_SELF_RESOLVE=1 FETCH_OK=1 \
        HEAD_SHA="$NEW8" HEAD_FULL_SHA="$NEW" ALL_REVIEWS="" ALL_THREADS="" ALL_COMMENTS="" \
        ALL_CHECK_RUNS="$widened" ALL_STATUSES="" ALL_REACTIONS="" \
        bash "$ACK_SCRIPT" cursor 2>/dev/null )
if [ "$out" = "$NEW8" ]; then ok "end-to-end: ledger Tier D HEAD-acks cursor after augment ($out)"
else fail "end-to-end: expected HEAD-ack $NEW8 for cursor, got '$out'"; fi
unset HEAD_SHA HEAD_FULL_SHA ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS ALL_STATUSES STUB_CHECKRUNS STUB_STATUSES

# ============================================================
# 2. NEGATIVE — real code change: predecessor is NOT content-identical, so the
#    helper must NOT fetch/append its check-run (no false carry-forward).
# ============================================================
repo=$(mk); bin=$(mk); make_gh_stub "$bin"
( cd "$repo" && git init -q && git config user.email t@e && git config user.name t && git config commit.gpgsign false \
   && echo v1 > f.txt && git add f.txt && git commit -qm "feat: thing" )
OLD=$(git -C "$repo" rev-parse HEAD)
( cd "$repo" && echo v2 > f.txt && git add f.txt && git commit -q --amend --no-edit )   # different tree
NEW=$(git -C "$repo" rev-parse HEAD); NEW8=${NEW:0:8}
export HEAD_SHA="$NEW8" HEAD_FULL_SHA="$NEW"
ALL_REVIEWS="$(reviews_json cubic-dev-ai "$OLD" COMMENTED)"; export ALL_REVIEWS
export ALL_COMMENTS='' ALL_CHECK_RUNS='' ALL_STATUSES=''
STUB_CHECKRUNS="$(checkruns_json cursor "$OLD")"; export STUB_CHECKRUNS STUB_STATUSES=''
widened=$(run_augment "$repo" "$bin")
if printf '%s' "$widened" | jq -es '[.[]?|.check_runs[]?|select(.app.slug=="cursor")]|length>0' >/dev/null 2>&1; then
  fail "NEGATIVE: augment fetched a non-identical predecessor's check-run (false carry-forward!)"
else
  ok "negative (real code change): predecessor rejected, ALL_CHECK_RUNS not widened"
fi
unset HEAD_SHA HEAD_FULL_SHA ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS ALL_STATUSES STUB_CHECKRUNS STUB_STATUSES

# ============================================================
# 3. KILL SWITCH — ACK_CONTENT_IDENTITY=0 → helper is a no-op.
# ============================================================
repo=$(mk); bin=$(mk); make_gh_stub "$bin"
( cd "$repo" && git init -q && git config user.email t@e && git config user.name t && git config commit.gpgsign false \
   && echo v1 > f.txt && git add f.txt && git commit -qm "feat: thing" )
OLD=$(git -C "$repo" rev-parse HEAD)
( cd "$repo" && git commit -q --amend -m "feat: thing reworded" )
NEW=$(git -C "$repo" rev-parse HEAD); NEW8=${NEW:0:8}
export ACK_CONTENT_IDENTITY=0 HEAD_SHA="$NEW8" HEAD_FULL_SHA="$NEW"
ALL_REVIEWS="$(reviews_json cubic-dev-ai "$OLD" COMMENTED)"; export ALL_REVIEWS
export ALL_COMMENTS='' ALL_CHECK_RUNS='' ALL_STATUSES=''
STUB_CHECKRUNS="$(checkruns_json cursor "$OLD")"; export STUB_CHECKRUNS STUB_STATUSES=''
widened=$(run_augment "$repo" "$bin")
if [ -z "$(printf '%s' "$widened" | tr -d '[:space:]')" ]; then ok "kill switch (ACK_CONTENT_IDENTITY=0): no-op, inputs untouched"
else fail "kill switch: expected empty ALL_CHECK_RUNS, got non-empty"; fi
unset ACK_CONTENT_IDENTITY HEAD_SHA HEAD_FULL_SHA ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS ALL_STATUSES STUB_CHECKRUNS STUB_STATUSES

# ============================================================
# 4. TIMELINE-ONLY discovery — no /reviews or comment SHA survives; the predecessor
#    is found only via the force-push timeline (beforeCommit). Covers check-run-only
#    repos. End-to-end: ledger Tier D HEAD-acks cursor.
# ============================================================
repo=$(mk); bin=$(mk); make_gh_stub "$bin"
( cd "$repo" && git init -q && git config user.email t@e && git config user.name t && git config commit.gpgsign false \
   && echo v1 > f.txt && git add f.txt && git commit -qm "feat: thing" )
OLD=$(git -C "$repo" rev-parse HEAD)
( cd "$repo" && git commit -q --amend -m "feat: thing (commitlint)" )
NEW=$(git -C "$repo" rev-parse HEAD); NEW8=${NEW:0:8}
export HEAD_SHA="$NEW8" HEAD_FULL_SHA="$NEW"
export ALL_REVIEWS='' ALL_COMMENTS='' ALL_CHECK_RUNS='' ALL_STATUSES=''
export PR_NUMBER=123 STUB_TIMELINE_OID="$OLD"          # predecessor discoverable ONLY via timeline
STUB_CHECKRUNS="$(checkruns_json cursor "$OLD")"; export STUB_CHECKRUNS
widened=$(run_augment "$repo" "$bin")
if printf '%s' "$widened" | jq -es '[.[]?|.check_runs[]?|select(.app.slug=="cursor")]|length>0' >/dev/null 2>&1; then
  ok "timeline-only: predecessor found via force-push timeline, check-run fetched"
else
  fail "timeline-only: augment did not discover predecessor via timeline (got: $(printf '%s' "$widened" | head -c 160))"
fi
out=$( cd "$repo" && env BUSDRIVER_DISABLE_ACK_SELF_RESOLVE=1 FETCH_OK=1 \
        HEAD_SHA="$NEW8" HEAD_FULL_SHA="$NEW" ALL_REVIEWS="" ALL_THREADS="" ALL_COMMENTS="" \
        ALL_CHECK_RUNS="$widened" ALL_STATUSES="" ALL_REACTIONS="" \
        bash "$ACK_SCRIPT" cursor 2>/dev/null )
if [ "$out" = "$NEW8" ]; then ok "end-to-end (timeline-only): ledger Tier D HEAD-acks cursor ($out)"
else fail "end-to-end (timeline-only): expected HEAD-ack $NEW8, got '$out'"; fi
unset HEAD_SHA HEAD_FULL_SHA ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS ALL_STATUSES PR_NUMBER STUB_TIMELINE_OID STUB_CHECKRUNS

# ============================================================
# 5. PRECEDENCE — HEAD already reports a cursor check-run (here: failure). A
#    predecessor success must NOT be appended (HEAD's own signal wins; a
#    pending/failing HEAD must not be masked by an old success).
# ============================================================
repo=$(mk); bin=$(mk); make_gh_stub "$bin"
( cd "$repo" && git init -q && git config user.email t@e && git config user.name t && git config commit.gpgsign false \
   && echo v1 > f.txt && git add f.txt && git commit -qm "feat: thing" )
OLD=$(git -C "$repo" rev-parse HEAD)
( cd "$repo" && git commit -q --amend -m "feat: thing reworded" )
NEW=$(git -C "$repo" rev-parse HEAD); NEW8=${NEW:0:8}
export HEAD_SHA="$NEW8" HEAD_FULL_SHA="$NEW"
ALL_REVIEWS="$(reviews_json cubic-dev-ai "$OLD" COMMENTED)"; export ALL_REVIEWS
# HEAD already has a cursor check-run that is NOT success → carry-forward must skip cursor.
ALL_CHECK_RUNS="$(printf '{"check_runs":[{"app":{"slug":"cursor"},"conclusion":"failure","head_sha":"%s"}]}' "$NEW")"; export ALL_CHECK_RUNS
export ALL_COMMENTS=''
STUB_CHECKRUNS="$(checkruns_json cursor "$OLD")"; export STUB_CHECKRUNS   # predecessor cursor success
widened=$(run_augment "$repo" "$bin")
# Two assertions: (1) no predecessor success leaked, AND (2) HEAD failure entry is still present.
if printf '%s' "$widened" | jq -es '[.[]?|.check_runs[]?|select(.app.slug=="cursor" and .conclusion=="success")]|length==0' >/dev/null 2>&1; then
  ok "precedence: predecessor cursor success did not leak"
else
  fail "precedence: predecessor cursor success leaked despite a HEAD cursor check-run"
fi
if printf '%s' "$widened" | jq -es --arg sha "$NEW" '[.[]?|.check_runs[]?|select(.app.slug=="cursor" and .conclusion=="failure" and .head_sha==$sha)]|length==1' >/dev/null 2>&1; then
  ok "precedence: HEAD cursor failure entry preserved after widening"
else
  fail "precedence: HEAD cursor failure entry missing or duplicated after widening"
fi
unset HEAD_SHA HEAD_FULL_SHA ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS STUB_CHECKRUNS

# ============================================================
# 6. FAIL-CLOSED (fresh clone) — the predecessor object is NOT local and there is no
#    origin to fetch it from, so the proof can't run → no widening (no false ack).
#    Exercises the best-effort `git fetch origin <sha>` → fail path.
# ============================================================
repo=$(mk); bin=$(mk); make_gh_stub "$bin"
( cd "$repo" && git init -q && git config user.email t@e && git config user.name t && git config commit.gpgsign false \
   && echo v1 > f.txt && git add f.txt && git commit -qm "feat: thing" )
( cd "$repo" && git commit -q --amend -m "feat: thing reworded" )   # no origin remote exists
NEW=$(git -C "$repo" rev-parse HEAD); NEW8=${NEW:0:8}
ABSENT="0123456789abcdef0123456789abcdef01234567"   # well-formed but not an object here
export HEAD_SHA="$NEW8" HEAD_FULL_SHA="$NEW"
ALL_REVIEWS="$(reviews_json cubic-dev-ai "$ABSENT" COMMENTED)"; export ALL_REVIEWS
export ALL_COMMENTS='' ALL_CHECK_RUNS=''
STUB_CHECKRUNS="$(checkruns_json cursor "$ABSENT")"; export STUB_CHECKRUNS
widened=$(run_augment "$repo" "$bin")
if [ -z "$(printf '%s' "$widened" | tr -d '[:space:]')" ]; then
  ok "fail-closed (fresh clone): absent+unfetchable predecessor → no widening"
else
  fail "fail-closed: widened ALL_CHECK_RUNS despite an absent, unfetchable predecessor"
fi
unset HEAD_SHA HEAD_FULL_SHA ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS STUB_CHECKRUNS

# ============================================================
# 7. MALFORMED ALL_CHECK_RUNS — defensive bail-out: malformed non-empty
#    ALL_CHECK_RUNS must result in a no-op (no widening, no mutation).
# ============================================================
repo=$(mk); bin=$(mk); make_gh_stub "$bin"
( cd "$repo" && git init -q && git config user.email t@e && git config user.name t && git config commit.gpgsign false \
   && echo v1 > f.txt && git add f.txt && git commit -qm "feat: thing" )
OLD=$(git -C "$repo" rev-parse HEAD)
( cd "$repo" && git commit -q --amend -m "feat: thing reworded" )
NEW=$(git -C "$repo" rev-parse HEAD); NEW8=${NEW:0:8}
export HEAD_SHA="$NEW8" HEAD_FULL_SHA="$NEW"
ALL_REVIEWS="$(reviews_json cubic-dev-ai "$OLD" COMMENTED)"; export ALL_REVIEWS
export ALL_COMMENTS=''
ALL_CHECK_RUNS='not-valid-json{{{'; export ALL_CHECK_RUNS   # malformed non-empty payload
export STUB_CHECKRUNS=''
widened=$(run_augment "$repo" "$bin")
# The bail-out (jq empty fails → return 0) leaves ALL_CHECK_RUNS unchanged (no widening).
# Verify the output equals the original malformed input — no predecessor check-runs appended.
if [ "$widened" = 'not-valid-json{{{' ]; then
  ok "malformed ALL_CHECK_RUNS: defensive bail-out — input unchanged, no widening"
else
  fail "malformed ALL_CHECK_RUNS: expected unchanged input, got: '$widened'"
fi
unset HEAD_SHA HEAD_FULL_SHA ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS STUB_CHECKRUNS

echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
