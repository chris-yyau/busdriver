#!/usr/bin/env bash
# scripts/codex-engagement-probe.sh — read-only, PR-scoped Codex engagement probe.
#
# ADR 0024 (constraints 6 & 7). Answers ONE question about a single PR: has Codex
# (chatgpt-codex-connector) engaged AT ALL on it — any review OR any PR-level
# reaction? Prints EXACTLY ONE token on stdout and nothing else:
#
#     engaged   Codex login found in the PR's reviews or issue reactions.
#     none      every page of every source fetched cleanly AND no Codex login.
#     unknown   any fetch/parse failure, missing tool, or bad input.
#
# CONTRACT
#   - READ-ONLY. Never posts, never writes a marker/comment (constraint 7). It is
#     the inverse of codex-nudge-premerge.sh, which posts; this only observes.
#   - PR-SCOPED, NOT HEAD-scoped (constraint 6). PR-level reactions carry no commit
#     SHA and the review scan does not filter commit_id, matching the nudge's and
#     pr-grind's none-vs-stale split. HEAD is the caller's concern (label-only).
#   - FAIL TO `unknown` — never to `none`. A partial/errored fetch must be
#     distinguishable from a genuinely-idle PR so the caller stays silent rather
#     than warning on a false `none` (constraint 3).
#   - SINGLE-TOKEN stdout. All diagnostics go to stderr. The caller treats any
#     stdout that is not exactly `engaged`/`none`/`unknown` as `unknown`.
#   - This script does NOT check the kill switch or active-repo status — that is
#     the adapter's job (codex-premerge-warn.sh). This is pure engagement.
#
#   Usage:  codex-engagement-probe.sh <owner/repo> <pr>
#   Always exits 0 (the token is the result; a nonzero exit is not part of the
#   contract and callers must not depend on it).
set -u

REPO="${1:-}"
PR="${2:-}"

emit() { printf '%s\n' "$1"; exit 0; }

# ── Validate owner/repo (same conservative charset as codex-active-repo.sh) ──
case "$REPO" in
    */*/* | /* | */ ) REPO="" ;;
esac
OWNER="${REPO%%/*}"
NAME="${REPO#*/}"
if [ -z "$OWNER" ] || [ -z "$NAME" ] || [ "$OWNER" = "$REPO" ] \
   || printf '%s' "$OWNER$NAME" | LC_ALL=C grep -q '[^A-Za-z0-9._-]'; then
    echo "ℹ️  codex-engagement-probe: bad owner/repo '$REPO' → unknown." >&2
    emit unknown
fi

# ── Validate PR (numeric) ────────────────────────────────────────────────
case "$PR" in
    '' | *[!0-9]*)
        echo "ℹ️  codex-engagement-probe: bad PR '$PR' → unknown." >&2
        emit unknown ;;
esac

command -v gh >/dev/null 2>&1 || { echo "ℹ️  codex-engagement-probe: gh not found → unknown." >&2; emit unknown; }
# NOTE: no standalone-jq requirement. The reads below use `gh api --jq`, which is
# implemented BY gh itself — a separate jq binary is never invoked here. Requiring
# one would falsely return `unknown` (suppressing the advisory) on a host that has
# gh + python but no standalone jq.

# ── Paginated presence read (mirrors codex-nudge-premerge.sh gh_api_logins) ──
# Fully paginated so engagement past the first page is never missed (a false
# `none` would suppress a real warning). Defensive jq (`.[]?.user?.login? //
# empty`): a ghost/deleted reviewer or malformed element yields empty, not a jq
# error. Bounded 2-attempt retry absorbs a transient read; only a total failure
# returns non-zero → the caller maps that to `unknown`.
gh_api_logins() {
    local _out _rc _attempt
    for _attempt in 1 2; do
        _out=$(gh api --paginate "$1" --jq '.[]?.user?.login? // empty' 2>/dev/null); _rc=$?
        [ "$_rc" -eq 0 ] && { printf '%s' "$_out"; return 0; }
        [ "$_attempt" -lt 2 ] && sleep 1
    done
    return 1
}

# Fetched in parallel — the caller wraps this whole script (plus
# codex-active-repo.sh) in a single shrinking outer budget (as low as 2s,
# default 8s), so sequential retries here would consume a disproportionate
# share of an already-tight window.
TMP_REV=$(mktemp) TMP_REACT=$(mktemp)
trap 'rm -f "$TMP_REV" "$TMP_REACT"' EXIT
gh_api_logins "repos/$OWNER/$NAME/pulls/$PR/reviews" >"$TMP_REV" & pid_rev=$!
gh_api_logins "repos/$OWNER/$NAME/issues/$PR/reactions" >"$TMP_REACT" & pid_react=$!
wait "$pid_rev";   rc_rev=$?
wait "$pid_react"; rc_react=$?
REVIEW_LOGINS=$(cat "$TMP_REV"); REACTION_LOGINS=$(cat "$TMP_REACT")
[ "$rc_rev" -eq 0 ]   || { echo "ℹ️  codex-engagement-probe: reviews fetch failed → unknown." >&2; emit unknown; }
[ "$rc_react" -eq 0 ] || { echo "ℹ️  codex-engagement-probe: reactions fetch failed → unknown." >&2; emit unknown; }

# Bare OR [bot]-suffixed login (ADR 0002 / ack-ledger.sh) — GitHub returns either.
if printf '%s\n%s\n' "$REVIEW_LOGINS" "$REACTION_LOGINS" \
   | grep -qxE 'chatgpt-codex-connector(\[bot\])?'; then
    emit engaged
fi

# Both sources fetched cleanly, no Codex login anywhere → genuine none.
emit none
