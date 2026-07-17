#!/usr/bin/env bash
# tests/test-ack-ledger-content-identity.sh
#
# Verifies scripts/ack-ledger.sh content-identity carry-forward (acks_head): a
# reviewer-bot ack recorded against SHA_old still HEAD-acks the current HEAD when
# HEAD is git-PROVABLY content-identical to SHA_old (same tree AND same parents) —
# i.e. a message-only `git commit --amend` + force-push (commitlint header fix,
# DCO sign-off, GPG re-sign, commit-message typo). This eliminates the guaranteed
# poll-then-bail-at-`--max-wait` dead-end the ledger hit on every such force-push
# (bots won't re-post acks when there is no code to re-review).
#
# Unlike the other tier tests (pure env fixtures), carry-forward needs REAL git
# objects — the helper proves identity from tree + parent hashes — so each case
# builds a throwaway git repo and runs the ledger with CWD inside it.
#
# Security invariant under test: identity is proven from git object hashes, NOT
# from backdatable timestamps, so the carry-forward must NEVER fire when the tree
# OR the parents differ (real code change, or a rebase onto a different base).
# Those cases must keep their pre-fix classification (no false HEAD-ack).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ACK_SCRIPT="$SCRIPT_DIR/scripts/ack-ledger.sh"

passed=0
failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

if [ ! -f "$ACK_SCRIPT" ]; then
  fail "ack-ledger.sh missing at $ACK_SCRIPT"
  echo "Results: $passed passed, $failed failed"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — ack-ledger.sh tier parsing requires it"
  exit 0
fi

# Cleaned up on exit — collect every temp repo we create.
TMP_REPOS=()
cleanup() { local d; for d in "${TMP_REPOS[@]:-}"; do [ -n "${d:-}" ] && rm -rf "$d"; done; return 0; }
trap cleanup EXIT

# make_repo — fresh git repo with deterministic identity and signing disabled.
# Echoes the path only; registration happens in new_repo. Appending to TMP_REPOS
# HERE would be lost — make_repo runs inside a $() subshell, so a mutation never
# reaches the parent shell (which would leak repos AND poison the cleanup loop).
make_repo() {
  local d
  d=$(mktemp -d)
  git -C "$d" init -q
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name  tester
  git -C "$d" config commit.gpgsign false
  printf '%s' "$d"
}

# new_repo — create a repo, register it for cleanup, expose it as global $repo.
new_repo() { repo=$(make_repo); TMP_REPOS+=("$repo"); }

# run_ledger <repo> <login> — invoke the ledger with CWD inside <repo>. Fixture
# inputs come from the exported ALL_*/HEAD_* vars the caller sets. The self-
# resolver is force-disabled so we always exercise THIS working-tree script.
run_ledger() {
  local repo="$1" login="$2"
  ( cd "$repo" && env \
      BUSDRIVER_DISABLE_ACK_SELF_RESOLVE=1 \
      FETCH_OK="${FETCH_OK:-1}" \
      HEAD_SHA="${HEAD_SHA:-}" \
      HEAD_FULL_SHA="${HEAD_FULL_SHA:-}" \
      HEAD_PUSH_DATE="${HEAD_PUSH_DATE:-}" \
      ALL_REVIEWS="${ALL_REVIEWS:-}" \
      ALL_THREADS="${ALL_THREADS:-}" \
      ALL_COMMENTS="${ALL_COMMENTS:-}" \
      ALL_CHECK_RUNS="${ALL_CHECK_RUNS:-}" \
      ALL_STATUSES="${ALL_STATUSES:-}" \
      ALL_REACTIONS="${ALL_REACTIONS:-}" \
      ACK_CONTENT_IDENTITY="${ACK_CONTENT_IDENTITY:-1}" \
      bash "$ACK_SCRIPT" "$login" 2>/dev/null )
}

# Reset all fixture vars between cases so leakage can't mask a bug.
reset_fixture() {
  unset HEAD_SHA HEAD_FULL_SHA HEAD_PUSH_DATE ALL_REVIEWS ALL_THREADS ALL_COMMENTS \
        ALL_CHECK_RUNS ALL_STATUSES ALL_REACTIONS ACK_CONTENT_IDENTITY FETCH_OK 2>/dev/null || true
}

# --- Fixture builders (JSON shapes match the real gh-api stream the ledger slurps) ---
reviews_json()    { printf '[{"user":{"login":"%s[bot]"},"commit_id":"%s","state":"%s"}]' "$1" "$2" "$3"; }
checkruns_json()  { printf '{"check_runs":[{"app":{"slug":"%s"},"conclusion":"success","head_sha":"%s"}]}' "$1" "$2"; }
comments_json()   { printf '{"comments":[{"author":{"login":"%s[bot]"},"body":"Last reviewed commit: [x](https://github.com/o/r/commit/%s)"}]}' "$1" "$2"; }

# =====================================================================
# 1. Tier B carry-forward — message-only amend, /reviews APPROVED on SHA_old
# =====================================================================
reset_fixture
new_repo
( cd "$repo" && echo v1 > f.txt && git add f.txt && git commit -qm "feat: thing" )
OLD=$( git -C "$repo" rev-parse HEAD )
( cd "$repo" && git commit -q --amend -m "feat: thing (shorter subject)" )   # message-only: same tree+parent
NEW=$( git -C "$repo" rev-parse HEAD )
NEW8=${NEW:0:8}
HEAD_SHA="$NEW8"; ALL_REVIEWS=$(reviews_json cubic-dev-ai "$OLD" APPROVED)
out=$(run_ledger "$repo" cubic-dev-ai)
if [ "$out" = "$NEW8" ]; then ok "Tier B: message-only amend carries the /reviews ack forward to HEAD ($out)"
else fail "Tier B: expected HEAD-ack $NEW8, got '$out'"; fi

# =====================================================================
# 2. Tier D carry-forward — message-only amend, check-run success on SHA_old
# =====================================================================
reset_fixture
new_repo
( cd "$repo" && echo v1 > f.txt && git add f.txt && git commit -qm "feat: thing" )
OLD=$( git -C "$repo" rev-parse HEAD )
( cd "$repo" && git commit -q --amend -m "feat: thing typo-fixed" )
NEW=$( git -C "$repo" rev-parse HEAD ); NEW8=${NEW:0:8}
HEAD_SHA="$NEW8"; ALL_CHECK_RUNS=$(checkruns_json cursor "$OLD")
out=$(run_ledger "$repo" cursor)
if [ "$out" = "$NEW8" ]; then ok "Tier D: message-only amend carries the check-run ack forward to HEAD ($out)"
else fail "Tier D: expected HEAD-ack $NEW8, got '$out'"; fi

# =====================================================================
# 3. Tier C carry-forward — message-only amend, body-SHA comment on SHA_old
# =====================================================================
reset_fixture
new_repo
( cd "$repo" && echo v1 > f.txt && git add f.txt && git commit -qm "feat: thing" )
OLD=$( git -C "$repo" rev-parse HEAD )
( cd "$repo" && git commit -q --amend -m "feat: thing reworded" )
NEW=$( git -C "$repo" rev-parse HEAD ); NEW8=${NEW:0:8}
HEAD_SHA="$NEW8"; ALL_COMMENTS=$(comments_json greptile "$OLD")
out=$(run_ledger "$repo" greptile)
if [ "$out" = "$NEW8" ]; then ok "Tier C: message-only amend carries the body-SHA ack forward to HEAD ($out)"
else fail "Tier C: expected HEAD-ack $NEW8, got '$out'"; fi

# =====================================================================
# 4. NEGATIVE — real code change → tree differs → NO carry-forward → stale
#    (proves we did not loosen the gate)
# =====================================================================
reset_fixture
new_repo
( cd "$repo" && echo v1 > f.txt && git add f.txt && git commit -qm "feat: thing" )
OLD=$( git -C "$repo" rev-parse HEAD )
( cd "$repo" && echo v2 > f.txt && git add f.txt && git commit -q --amend --no-edit )  # different tree
NEW=$( git -C "$repo" rev-parse HEAD ); NEW8=${NEW:0:8}
HEAD_SHA="$NEW8"; ALL_REVIEWS=$(reviews_json cursor "$OLD" APPROVED)   # APPROVED ⇒ ever_approved>0 ⇒ final stale
out=$(run_ledger "$repo" cursor)
if [ "$out" = "stale" ]; then ok "Negative (real code change): correctly stale, no false HEAD-ack"
elif [ "$out" = "$NEW8" ]; then fail "Negative (real code change): FALSE HEAD-ack $out — carry-forward fired on a different tree!"
else fail "Negative (real code change): expected stale, got '$out'"; fi

# =====================================================================
# 5. NEGATIVE — same tree, DIFFERENT parent (rebase) → NO carry-forward → stale
#    Built with plumbing: NEW has OLD's tree but a fresh, different parent.
# =====================================================================
reset_fixture
new_repo
( cd "$repo" && echo a > a.txt && git add a.txt && git commit -qm base )
B0=$( git -C "$repo" rev-parse HEAD )
( cd "$repo" && echo x > x.txt && git add x.txt && git commit -qm feat )
OLD=$( git -C "$repo" rev-parse HEAD )
TREE_OLD=$( git -C "$repo" rev-parse "HEAD^{tree}" )
B0_TREE=$( git -C "$repo" rev-parse "${B0}^{tree}" )
# Alternate parent: same tree as B0 but a different SHA (no parent → distinct).
ALTPARENT=$( git -C "$repo" commit-tree "$B0_TREE" -m "base v2" )
# NEW: identical tree to OLD, but parent = ALTPARENT (≠ B0 = OLD's parent).
NEW=$( git -C "$repo" commit-tree "$TREE_OLD" -p "$ALTPARENT" -m feat )
git -C "$repo" reset -q --hard "$NEW"
NEW8=${NEW:0:8}
# Sanity: trees equal, parents differ (so the test exercises the parent pin).
[ "$( git -C "$repo" rev-parse "${NEW}^{tree}" )" = "$TREE_OLD" ] || fail "setup#5: NEW tree != OLD tree"
OLD_PARENT=$(git -C "$repo" show -s --format=%P "$OLD")
NEW_PARENT=$(git -C "$repo" show -s --format=%P "$NEW")
[ "$OLD_PARENT" != "$NEW_PARENT" ] || fail "setup#5: NEW parent unexpectedly equals OLD parent"
HEAD_SHA="$NEW8"; ALL_REVIEWS=$(reviews_json cursor "$OLD" APPROVED)
out=$(run_ledger "$repo" cursor)
if [ "$out" = "stale" ]; then ok "Negative (parent change / rebase): parent-pin rejects it, stays stale"
elif [ "$out" = "$NEW8" ]; then fail "Negative (parent change): FALSE HEAD-ack $out — parent pin failed!"
else fail "Negative (parent change): expected stale, got '$out'"; fi

# =====================================================================
# 6. FAIL-CLOSED — acked SHA absent from the local repo → stale
# =====================================================================
reset_fixture
new_repo
( cd "$repo" && echo v1 > f.txt && git add f.txt && git commit -qm "feat: thing" )
( cd "$repo" && git commit -q --amend -m "feat: thing reworded" )
NEW=$( git -C "$repo" rev-parse HEAD ); NEW8=${NEW:0:8}
ABSENT="0123456789abcdef0123456789abcdef01234567"   # not an object in this repo
HEAD_SHA="$NEW8"; ALL_REVIEWS=$(reviews_json cursor "$ABSENT" APPROVED)
out=$(run_ledger "$repo" cursor)
if [ "$out" = "stale" ]; then ok "Fail-closed (acked SHA not local): stays stale, no carry-forward"
else fail "Fail-closed (absent object): expected stale, got '$out'"; fi

# =====================================================================
# 7. OPT-OUT — ACK_CONTENT_IDENTITY=0 disables carry-forward (message-only amend → stale)
# =====================================================================
reset_fixture
new_repo
( cd "$repo" && echo v1 > f.txt && git add f.txt && git commit -qm "feat: thing" )
OLD=$( git -C "$repo" rev-parse HEAD )
( cd "$repo" && git commit -q --amend -m "feat: thing reworded" )
NEW=$( git -C "$repo" rev-parse HEAD ); NEW8=${NEW:0:8}
HEAD_SHA="$NEW8"; ALL_REVIEWS=$(reviews_json cursor "$OLD" APPROVED); ACK_CONTENT_IDENTITY=0
out=$(run_ledger "$repo" cursor)
if [ "$out" = "stale" ]; then ok "Opt-out (ACK_CONTENT_IDENTITY=0): kill switch restores pre-fix stale"
else fail "Opt-out: expected stale, got '$out'"; fi

# =====================================================================
# 8. NO-REGRESSION — direct SHA match still HEAD-acks (byte-identical old path)
# =====================================================================
reset_fixture
new_repo
( cd "$repo" && echo v1 > f.txt && git add f.txt && git commit -qm "feat: thing" )
HEAD=$( git -C "$repo" rev-parse HEAD ); HEAD8=${HEAD:0:8}
HEAD_SHA="$HEAD8"; ALL_REVIEWS=$(reviews_json cubic-dev-ai "$HEAD" APPROVED)
out=$(run_ledger "$repo" cubic-dev-ai)
if [ "$out" = "$HEAD8" ]; then ok "No-regression: direct commit_id==HEAD_SHA still HEAD-acks ($out)"
else fail "No-regression: expected HEAD-ack $HEAD8, got '$out'"; fi

# =====================================================================
# 9. ARG-INJECTION GUARD — a non-hex candidate (e.g. a leading-dash option) is
#    rejected before reaching git; no carry-forward → stale (no false HEAD-ack).
# =====================================================================
reset_fixture
new_repo
( cd "$repo" && echo v1 > f.txt && git add f.txt && git commit -qm "feat: thing" )
( cd "$repo" && git commit -q --amend -m "feat: thing reworded" )
NEW=$( git -C "$repo" rev-parse HEAD ); NEW8=${NEW:0:8}
# commit_id is an injection-shaped string, not a SHA. APPROVED ⇒ stale on no ack.
HEAD_SHA="$NEW8"; ALL_REVIEWS='[{"user":{"login":"cursor[bot]"},"commit_id":"--output=/tmp/x","state":"APPROVED"}]'
out=$(run_ledger "$repo" cursor)
if [ "$out" = "stale" ]; then ok "arg-injection guard: non-hex candidate rejected, stays stale"
elif [ "$out" = "$NEW8" ]; then fail "arg-injection guard: FALSE HEAD-ack from a non-hex candidate!"
else fail "arg-injection guard: expected stale, got '$out'"; fi

# =====================================================================
# 10. HEAD_FULL_SHA path — when the full OID is provided, the proof anchors on it
#     (not the 8-char prefix) and still carries a message-only amend forward.
# =====================================================================
reset_fixture
new_repo
( cd "$repo" && echo v1 > f.txt && git add f.txt && git commit -qm "feat: thing" )
OLD=$( git -C "$repo" rev-parse HEAD )
( cd "$repo" && git commit -q --amend -m "feat: thing (full-oid path)" )
NEW=$( git -C "$repo" rev-parse HEAD ); NEW8=${NEW:0:8}
HEAD_SHA="$NEW8"; HEAD_FULL_SHA="$NEW"; ALL_REVIEWS=$(reviews_json cubic-dev-ai "$OLD" APPROVED)
out=$(run_ledger "$repo" cubic-dev-ai)
if [ "$out" = "$NEW8" ]; then ok "HEAD_FULL_SHA path: full-OID anchor still carries the amend forward ($out)"
else fail "HEAD_FULL_SHA path: expected HEAD-ack $NEW8, got '$out'"; fi

# =====================================================================
# 11. greptile-apps Tier-D guard — a success check-run on HEAD with NO review
#     object must NOT bodyless-ack (its check goes success even WITH findings, so
#     a green check can't prove clean; a Tier-D `0/0` ack would trip Invariant 3's
#     ADR-0001 exemption → merge-past-findings fail-open). Fail-CLOSED: greptile
#     falls through to `none` (non-gating), never a fabricated clean HEAD-ack.
# =====================================================================
reset_fixture
new_repo
( cd "$repo" && echo v1 > f.txt && git add f.txt && git commit -qm "feat: thing" )
HEAD=$( git -C "$repo" rev-parse HEAD ); HEAD8=${HEAD:0:8}
HEAD_SHA="$HEAD8"; ALL_CHECK_RUNS=$(checkruns_json greptile-apps "$HEAD")
out=$(run_ledger "$repo" greptile-apps)
if [ "$out" = "none" ]; then ok "greptile Tier-D guard: check-run-only success does NOT bodyless-ack ($out)"
elif [ "$out" = "$HEAD8" ]; then fail "greptile Tier-D guard: FAIL-OPEN — check-run alone fabricated a clean HEAD-ack!"
else fail "greptile Tier-D guard: expected none, got '$out'"; fi

# Control: the SAME fixture for a clean-only-check bot (cursor) MUST still ack via
# Tier D — proves the guard is greptile-specific, not a blanket Tier-D break.
reset_fixture
HEAD_SHA="$HEAD8"; ALL_CHECK_RUNS=$(checkruns_json cursor "$HEAD")
out=$(run_ledger "$repo" cursor)
if [ "$out" = "$HEAD8" ]; then ok "control: cursor still Tier-D acks the same check-run fixture ($out)"
else fail "control: cursor Tier-D ack broke — guard is not greptile-specific; got '$out'"; fi

echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
