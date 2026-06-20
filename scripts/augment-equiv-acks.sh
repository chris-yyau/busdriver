# shellcheck shell=bash
# shellcheck disable=SC2034  # ALL_CHECK_RUNS/HEAD_FULL_SHA re-exported to parent via `source`
# scripts/augment-equiv-acks.sh — sourced helper; widens the HEAD-scoped check-run
# input so a bot's check-run on a CONTENT-IDENTICAL predecessor commit reaches the
# ledger (Tier D carry-forward across message-only force-pushes).
#
# CRITICAL: source this file (`. augment-equiv-acks.sh`); do NOT execute it — a
# child bash cannot export the widened var back to the parent. Source it AFTER the
# HEAD-scoped fetch (so ALL_REVIEWS/ALL_COMMENTS/ALL_CHECK_RUNS and
# HEAD_SHA/HEAD_FULL_SHA are populated) and BEFORE the per-bot ack-ledger.sh calls.
#
# WHY: check-runs are fetched per-commit at `commits/$HEAD_SHA/check-runs`, so they
# only ever describe HEAD. After a message-only `git commit --amend` + force-push
# (commitlint fix, DCO sign-off, GPG re-sign, typo) the bots do NOT re-run — their
# check-run sits on the PRE-amend SHA, which the HEAD-scoped fetch never returns.
# ack-ledger.sh Tier D (check-run) therefore misses, the bot falls through to
# `stale`, and the gate polls then bails at --max-wait on every such force-push.
# (Tier B `/reviews` and Tier C body-SHA already survive: those endpoints are
# PR-wide and still carry the pre-amend SHA, so ack-ledger.sh's acks_head() carries
# them forward on its own.)
#
# SCOPE — check-runs ONLY. We deliberately do NOT widen commit-STATUSES (Tier E):
# a status object carries no SHA the ledger can re-prove, so an appended predecessor
# status would be trusted on this helper's proof alone AND could override a HEAD
# pending/failure status. Tier E stays correct on its own HEAD-scoped fetch (a bot
# that re-reviews HEAD posts a fresh status; one that doesn't yields `none`, which is
# non-blocking). A check-run, by contrast, carries `head_sha`, so Tier D RE-PROVES
# identity via acks_head(head_sha) after the append — defense in depth.
#
# WHAT: derive predecessor SHAs that are git-PROVABLY content-identical to HEAD
# (same tree AND same parents — an amend-without-rebase), then fetch THEIR check-runs
# and APPEND them to ALL_CHECK_RUNS.
#
# SAFETY: strictly ADDITIVE and best-effort. It only ever APPENDS already-acked
# check-runs for commits proven byte-identical to HEAD; it never removes data and
# never sets FETCH_OK=0 (a carry-forward fetch failure must not stale the gate).
# It also never OVERRIDES a HEAD signal: a predecessor check-run is appended only
# for an app that has NO check-run on HEAD, so a HEAD pending/failure/in-progress
# (the bot IS re-running on HEAD) is never masked by an old predecessor success.
# Timestamp-FREE (git object hashes, not backdatable dates), so it does not relax
# the #186/#189 anti-backdating posture. Disable entirely with ACK_CONTENT_IDENTITY=0.
#
# SCOPE BOUNDARY: this widens ONLY the AI-reviewer ack ledger (Tier D — cursor/cubic/
# coderabbit, code reviewers that approve the tree). The required status checks that
# are the merge authority (commitlint, DCO, signature, CI) are enforced by GitHub
# branch protection on the real HEAD and re-run independently — they are NEVER carried
# forward here, so a metadata-only amend with a bad commit message cannot bypass them.
#
# Candidate predecessor SHAs (priority order; deduped; HEAD excluded; capped):
#   1. force-push `beforeCommit` OIDs from the PR timeline — the authoritative
#      "what was HEAD before this push" source (covers a check-run-only repo where
#      no SHA-carrying review/comment survives). Best-effort; needs PR_NUMBER.
#   2. non-HEAD `commit_id`s already in ALL_REVIEWS + body-SHA links in ALL_COMMENTS
#      (no extra fetch; covers the common multi-bot PR, e.g. cubic-dev-ai's /reviews).
# Each candidate is sanitized, best-effort-fetched (fresh clones may lack the old
# object), then git-proven content-identical before any predecessor check-run fetch.
# At most 4 proven predecessors are fetched (content-identical predecessors are
# interchangeable, so one passing signal suffices; the cap bounds API budget).

_augment_equiv_acks() {
    # Kill switch: same flag the ledger honors. Off => leave inputs untouched.
    [ "${ACK_CONTENT_IDENTITY:-1}" = "1" ] || return 0
    command -v git >/dev/null 2>&1 || return 0
    command -v gh >/dev/null 2>&1 || return 0
    [ -n "${HEAD_SHA:-}" ] || return 0

    local ref
    ref="${HEAD_FULL_SHA:-$HEAD_SHA}"

    local nwo owner name
    nwo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null) || return 0
    [ -n "$nwo" ] || return 0
    owner="${nwo%/*}"
    name="${nwo#*/}"

    # --- Gather candidate predecessor SHAs (priority: timeline, then reviews/comments) ---
    # Each producer is `|| true`-guarded: a no-match grep (exit 1) or jq parse miss
    # must not abort the parent when sourced under `set -e`/`pipefail`. Worst case is
    # zero candidates. `awk 'NF'` drops blanks; we keep first occurrence per SHA.
    local candidates
    candidates=$(
        {
            # (1) force-push beforeCommit OIDs from the PR timeline (best-effort, first)
            if [ -n "${PR_NUMBER:-}" ]; then
                # shellcheck disable=SC2016  # GraphQL needs literal $var refs
                { gh api graphql -F number="$PR_NUMBER" -F owner="$owner" -F name="$name" \
                    -f query='query($number:Int!,$owner:String!,$name:String!){
                        repository(owner:$owner,name:$name){
                          pullRequest(number:$number){
                            timelineItems(last:50, itemTypes:[HEAD_REF_FORCE_PUSHED_EVENT]){
                              nodes{ ... on HeadRefForcePushedEvent { beforeCommit{oid} } }
                            }
                          }
                        }
                      }' 2>/dev/null \
                    | jq -r '.data.repository.pullRequest.timelineItems.nodes[]?.beforeCommit.oid // empty' 2>/dev/null; } || true
            fi
            # (2a) non-HEAD /reviews commit_ids (ALL_REVIEWS = paginated stream of arrays)
            printf '%s' "${ALL_REVIEWS:-}" \
                | jq -rs '[.[]?|.[]?|.commit_id // empty]|.[]' 2>/dev/null || true
            # (2b) body-SHA links in issue/review comments (ALL_COMMENTS = {comments:[...]})
            { printf '%s' "${ALL_COMMENTS:-}" \
                | jq -r '.comments[]?.body // empty' 2>/dev/null \
                | grep -oE 'commit/[0-9a-fA-F]{7,64}' 2>/dev/null \
                | sed 's|commit/||'; } || true
        } | awk 'NF && !seen[$0]++' | head -32
    ) || true
    [ -n "$candidates" ] || return 0

    # Fail-safe on malformed HEAD check-run input: if ALL_CHECK_RUNS is non-empty but
    # does NOT parse cleanly (e.g. a partial gh response that did not trip FETCH_OK),
    # bail rather than fall through with an empty _head_apps below — an empty app set
    # would disable HEAD-precedence suppression and could let a predecessor success
    # mask a live HEAD non-success. No widening at all is the safe outcome here.
    if [ -n "${ALL_CHECK_RUNS:-}" ]; then
        printf '%s' "$ALL_CHECK_RUNS" | jq empty 2>/dev/null || return 0
    fi

    # Apps HEAD already reports a check-run for: NEVER override their HEAD signal. If
    # HEAD has a check-run from this app we leave HEAD to win — a success acks via HEAD
    # anyway, and a pending/failure/null HEAD check-run (the bot IS re-running on HEAD)
    # must not be masked by an appended predecessor success. Keyed on app.slug to MATCH
    # the ledger's Tier D ack granularity: Tier D acks on ANY successful check-run for
    # the bot's slug (`select(.app.slug==$login)|select(.conclusion=="success")`,
    # regardless of check-run name), so the suppression must be per-slug too —
    # otherwise a HEAD pending under one name + a predecessor success under another
    # name (same slug) would slip through and falsely ack. Computed once, from HEAD.
    local _head_apps
    _head_apps=$(printf '%s' "${ALL_CHECK_RUNS:-}" | jq -rsc '[.[]?|.check_runs[]?|.app.slug // empty]|unique' 2>/dev/null) || _head_apps='[]'
    [ -n "$_head_apps" ] || _head_apps='[]'

    # --- Prove identity, then fetch each proven predecessor's CHECK-RUNS ------
    local cand _n=0
    for cand in $candidates; do
        # Sanitize before any git/gh call (injected-candidate guard; hex, 7–64).
        case "$cand" in *[!0-9A-Fa-f]*) continue ;; esac
        { [ "${#cand}" -ge 7 ] && [ "${#cand}" -le 64 ]; } || continue
        # Best-effort: a fresh-clone / `pull/ID/head` checkout may not have the
        # pre-force-push object. GitHub serves any pushed SHA by id; failure is
        # non-fatal (the proof then fails closed). Quiet, no tags, writes no ref;
        # low-speed-abort so an uncooperative remote can't hang the gate (~15s).
        git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 \
            fetch --quiet --no-tags origin "$cand" 2>/dev/null || true
        _equiv_to_head "$cand" "$ref" || continue
        local _cr
        _cr=$(gh api --paginate "repos/$owner/$name/commits/$cand/check-runs" 2>/dev/null) || _cr=""
        # Drop predecessor check-runs for any app.slug HEAD already reports — matching
        # the ledger's per-slug Tier D ack granularity (see above), so a live HEAD
        # non-success signal is never masked by an old predecessor success.
        if [ -n "$_cr" ]; then
            _cr=$(printf '%s' "$_cr" | jq -c --argjson head "$_head_apps" \
                'if type=="object" and (.check_runs|type=="array")
                 then .check_runs |= map(select((.app.slug // "") as $s | ($head|index($s))|not))
                 else . end' 2>/dev/null) || _cr=""
        fi
        if [ -n "$_cr" ]; then ALL_CHECK_RUNS=$(printf '%s\n%s' "${ALL_CHECK_RUNS:-}" "$_cr"); fi
        _n=$((_n + 1)); [ "$_n" -ge 4 ] && break   # cap predecessor fetches (API budget)
    done

    export ALL_CHECK_RUNS HEAD_FULL_SHA
    return 0
}

# _equiv_to_head <candidate_sha> <head_ref> — true (0) iff <candidate_sha> is a
# git-provable content-identical PREDECESSOR of <head_ref>: same tree AND same
# parents, and NOT head itself. Mirrors scripts/ack-ledger.sh acks_head()'s
# content-identity branch (kept in sync) — both sanitize the bot-supplied SHA
# (hex, 7–64 chars; SHA-1 or SHA-256) before it reaches git (argument-injection
# guard) and fail CLOSED on any missing object / mismatch.
_equiv_to_head() {
    local c="$1" r="$2" _ct _ht _cp _hp
    [ -n "$c" ] || return 1
    case "$c" in *[!0-9A-Fa-f]*) return 1 ;; esac
    { [ "${#c}" -ge 7 ] && [ "${#c}" -le 64 ]; } || return 1
    [ "${c:0:8}" = "$HEAD_SHA" ] && return 1   # head itself: already fetched, not a predecessor
    _ct=$(git rev-parse --verify --quiet "${c}^{tree}" 2>/dev/null) || return 1
    _ht=$(git rev-parse --verify --quiet "${r}^{tree}" 2>/dev/null) || return 1
    [ -n "$_ct" ] && [ "$_ct" = "$_ht" ] || return 1
    _cp=$(git show -s --format=%P "$c" 2>/dev/null) || return 1
    _hp=$(git show -s --format=%P "$r" 2>/dev/null) || return 1
    [ "$_cp" = "$_hp" ]
}

_augment_equiv_acks
