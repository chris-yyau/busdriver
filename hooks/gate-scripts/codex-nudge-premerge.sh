#!/usr/bin/env bash
# PreToolUse hook: deterministic `@codex review` nudge on `gh pr merge`.
#
# WHY: the ADR 0013 `none`-nudge (post `@codex review` when Codex never engaged
# on a PR that a Codex-active repo expects it to) was PROSE — a bash block buried
# in skills/pr-grind/SKILL.md's COMPLETION section that only fires if the grinding
# agent executes it verbatim. It therefore SILENTLY no-ops on every merge path
# that reaches "clean" without running that block: the pre-merge gate's
# bootstrap-merge bypass (gate-modifying PRs), skip-pr-grind bypasses, worktree
# `--admin` squashes, and any run where the agent shortcut to the marker. The
# ONLY deterministic enforcement (pre-merge-gate.sh) checks a pr-grind-clean
# marker + green CI and never verifies the nudge ran. This hook makes the nudge
# fire on the merge-INTENT event instead of agent prose — the one deterministic
# point that is post-CI-settle AND pre-merge — so it catches exactly the cases
# the SKILL prose misses.
#
# SCOPE — pure trigger. The MECHANISM (force-on/active policy, one-shot-per-
# (PR,HEAD) marker, the actual `gh pr comment`, opt-out, phrase override) is the
# existing scripts/codex-nudge-if-expected.sh → codex-retrigger.sh chain,
# delegated to unchanged. This hook adds two things they lack at merge time:
#   1. the deterministic firing point (a PreToolUse hook on `gh pr merge`), and
#   2. the `none` GUARD — the wrapper nudges whenever the repo is active, so
#      without this check it would post a redundant `@codex review` on EVERY
#      merge of a PR Codex already reviewed. We nudge ONLY when Codex has zero
#      engagement (no review, no reaction) on the PR — matching the SKILL's
#      `CODEX_DONE == "none"` policy. `stale` Codex is handled elsewhere (the
#      in-loop retrigger, ADR 0005); we must not double-fire on it here.
#
# TARGET SAFETY (the load-bearing invariant) — we do NOT try to reconstruct gh's
# full repo/PR/host resolution from the command string; that surface (global vs
# subcommand `-R`, GH_REPO/GH_HOST, PR URLs, branch names, GHE hosts) is too large
# to replicate without eventually nudging the WRONG PR. Instead we FIRE ONLY WHEN
# the merge provably targets THIS repo — the one the command runs in:
#   (a) parse rejects (→ skip) any per-command override we can't neutralize: a
#       `-R`/`--repo` flag anywhere in the invocation, an inline `GH_REPO=`/
#       `GH_HOST=` assignment, or a non-numeric positional (branch / PR URL);
#   (b) we DELEGATE resolution to gh (`gh pr view [<num>] --json number,headRefOid,
#       url`) in the merge's own cwd + env, then REQUIRE the resolved
#       host/owner/repo to EQUAL the cwd repo's `origin` (github.com only). Any
#       divergence — a cross-repo/cross-host URL — fails the equality check and skips.
#   Our own gh calls can no longer be re-routed at all: GH_HOST is pinned and
#   GH_REPO cleared at the top of this script (#416), so resolution is always
#   "the repo this cwd's origin points at, on github.com".
# Because the fire path is gated on target == cwd repo, the force-on marker and the
# delegate's one-shot dedup marker (both anchored on the cwd repo) are ALWAYS the
# target repo's own — never repo A's consent triggering a nudge on repo B. Anything
# not covered here is still covered by the SKILL-prose nudge.
#
# NON-GATING — this hook NEVER blocks a merge. It emits NOTHING to stdout and
# always exits 0 (approve). A bug here cannot break merges; the worst failure is
# a missed or (bounded, deduped) redundant nudge. FAIL-SAFE = SKIP: on any parse/
# query error we exit 0 WITHOUT posting, so we never emit a spurious `@codex
# review` (the inverse of the security gates, which fail-CLOSED to a block — a
# nudge that fails closed would spam comments).
#
# ACCEPTED LIMITS (independently reviewed 2026-07-15 — inherent, NOT bugs; do not
# "fix" without re-reading this):
#   1. Fires on merge-INTENT, decoupled from the pre-merge GATE's verdict. The
#      one-shot dedup is per-(PR,HEAD) (codex-retrigger.sh), so firing on an
#      attempt the gate later blocks still did its job — Codex was asked about
#      THIS code state; a same-HEAD retry needs no re-nudge, new commits earn a
#      fresh one. Gating on the pr-grind-clean marker instead would duplicate the
#      gate's admission logic AND re-exclude the bootstrap-bypass PRs this hook
#      exists to cover — a strictly worse trade.
#   2. A PreToolUse hook is a separate pre-exec process reading only the payload;
#      it cannot observe the executing shell's aliases / gh() functions / PATH.
#      sanitized-gate fixes PATH for OUR gh/git calls only. The literal-'gh'-token
#      guard below already skips wrapper/decoy forms; the residual (a real `gh`
#      alias that keeps the literal `gh pr merge N` shape) is bounded to a deduped,
#      possibly-early nudge — never a blocked merge (non-gating), never a flood.
#   3. Same root cause as #2 for `cd` (ADR 0018): a `cd` shell FUNCTION/alias can
#      send the merge to a THIRD dir the hook cannot see, so the standalone-cd
#      cross-cwd origin guard (payload==target origin) cannot fully prove the merge's
#      runtime repo. Like #2 this is inherent to a pre-exec hook and applies equally to
#      the pre-existing &&-captured-cd path; bounded to a deduped, possibly-mistargeted
#      nudge on the operator's OWN machine — never a blocked or mis-routed merge.
#   4. Same family, introduced by #416: the merge shell may carry an inherited
#      GH_REPO/GH_HOST this hook no longer imports and therefore cannot see, so a
#      merge that lands on repo B can still earn a nudge on the cwd repo's own PR.
#      That is the deliberate trade — a possibly-wrong-PR nudge INSIDE the repo we
#      already trust, in exchange for the guarantee that no repo-controlled value
#      ever routes an outbound, credentialed `gh` call. Bounded by the per-(PR,HEAD)
#      dedup marker and by the hook being non-gating.
#
# Runs under lib/sanitized-gate.sh (ADR 0016 env containment), like the gates.
# The hooks.json `env -i` line re-imports exactly ONE var beyond the standard
# PATH/HOME/CLAUDE_PLUGIN_ROOT: PR_GRIND_CODEX_RETRIGGER, the documented kill
# switch, which can only ever DISABLE the nudge. GH_REPO / GH_HOST /
# BUSDRIVER_STATE_DIR were dropped (#416): a committed `.claude/settings.json`
# `env` block is repo-controlled, and those three steer an OUTBOUND write —
# GH_HOST sends credentialed `gh` requests to an arbitrary host, GH_REPO
# re-points the comment target, BUSDRIVER_STATE_DIR misdirects the one-shot
# dedup marker. Repo targeting is now derived from `origin` (below) and the
# host is PINNED, so no repo-controlled value reaches any `gh` invocation.
set -u

# Pin gh's routing. `env -i` already omits these, so this is belt-and-braces
# against a future caller that does not go through hooks.json — and it is the
# invariant the #416 regression test anchors on. Exported so the delegate's
# `gh pr comment` inherits the same pin.
export GH_HOST=github.com
unset GH_REPO

# ── Read the PreToolUse payload once ───────────────────────────────────
HOOK_DATA=$(cat 2>/dev/null || true)
[[ -z "$HOOK_DATA" ]] && exit 0

# Fast pre-filter: bail on anything that can't be a `gh pr merge` before paying
# for python/gh. Match `pr`…`merge` WITHOUT requiring a literal adjacent `gh`, so
# quoted/escaped executable forms (g"h" pr merge, g\h pr merge) still reach the
# quote-aware detector; the `pr`+`merge` subcommand tokens are what the caller
# always writes unquoted. Still a near-no-op for the vast majority of Bash calls.
case "$HOOK_DATA" in
    *pr*merge*) ;;
    *) exit 0 ;;
esac

# Kill switch — PR_GRIND_CODEX_RETRIGGER=0 disables the whole nudge chain (the
# delegate honors it too, but short-circuit here to skip all network work).
[[ "${PR_GRIND_CODEX_RETRIGGER:-1}" == "0" ]] && exit 0

command -v python3 >/dev/null 2>&1 || exit 0
command -v gh >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$DIR/../../scripts"
# shellcheck source=lib/resolve-repo-dir.sh disable=SC1091
source "$DIR/lib/resolve-repo-dir.sh" || exit 0

# ── Parse via the standalone lib/nudge_parse.py (a FILE, not an inline python -c,
#    so no bash double-quote layer can corrupt backslashes/backticks) ───────
# The OLD parser required a single canonical `gh pr merge <literal>` command and so
# ALWAYS skipped pr-grind's real MULTI-LINE merge (`gh pr merge … || true` + a `for`
# retry loop, `$(gh pr view …)`, `if`, `cd`, `git worktree remove`; both paths embed
# `gh pr merge` in comments). ADR 0013 rev 2026-07-17 replaced it with a MERGE-FIRST
# rule that fires on the real shape while staying adversarially closed. nudge_parse.py:
#   1. Strips shell comments (Bash-faithful) first, then counts merges by COMMAND-WORD
#      (not substring — the block's commented `gh pr merge` decoys must not inflate the
#      count); requires EXACTLY ONE clean merge segment (no `-R`, no `$`/backtick, one
#      NUMERIC PR or none = current branch).
#   2. MERGE-FIRST: nothing may execute before the merge except pure non-sensitive
#      assignments and a single captured `cd &&` prefix; ANY real command before it →
#      skip. Complete by construction — no denylist of re-targeting commands to keep
#      exhaustive (`printf > .git/config`, cp, sed -i, pushd, $(git …), then GH_REPO=…
#      all re-point origin; requiring merge-first sidesteps enumerating them).
# The pr-grind DEFAULT block and skip/bootstrap bypass merges ARE merge-first (a leading
# standalone `cd "$WORKTREE_DIR"` per the CWD-reset rule and `NO_WORKTREE=<0|1>` precede
# the merge — both permitted; the literal cd is captured as target_dir and re-validated
# by the target==cwd equality below, ADR 0018) → nudged. The admin approver-gap block
# writes bypass-log jq before the merge → not merge-first → skipped here, covered by the
# SKILL-prose nudge.
# The residual (a `gh` alias / shell function / PATH this separate hook process can't see)
# is bounded to a deduped, possibly-spurious nudge on the CWD repo's OWN PR — never a
# cross-repo post (inherited-env skip + merge-segment checks + gh-pr-view==cwd-origin
# equality) and never a blocked merge. On ANY parse error we emit nothing → skip.
PARSE=$(printf '%s' "$HOOK_DATA" | PYTHONPATH="$DIR/lib" python3 -S "$DIR/lib/nudge_parse.py" 2>/dev/null || true)

IS_MERGE=$(printf '%s' "$PARSE" | sed -n '1p')
TARGET_DIR=$(printf '%s' "$PARSE" | sed -n '2p')
POSITIONAL=$(printf '%s' "$PARSE" | sed -n '3p')
UNSAFE=$(printf '%s' "$PARSE" | sed -n '4p')
HOOK_CWD=$(printf '%s' "$PARSE" | sed -n '5p')

[[ "$IS_MERGE" == "yes" ]] || exit 0
[[ -n "$UNSAFE" ]] && exit 0      # per-command override we can't neutralize → skip

# ── Resolve the repo dir the merge runs in ─────────────────────────────
gate_resolve_repo_dir "$TARGET_DIR" "$HOOK_CWD"
[[ "$GATE_RESOLVE_STATUS" == "proceed" ]] || exit 0
REPO_DIR="$GATE_REPO_DIR"

# cwd repo canonical host/owner/repo from origin (offline). github.com only —
# a non-github origin (GHE) is skipped: the delegate's `gh pr comment` uses the
# default host, so we only act where that host is correct.
CWD_URL=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)
CWD_CANON=$(printf '%s' "$CWD_URL" | sed -E 's#^git@#https://#; s#^https?://##; s#:#/#; s#\.git/?$##; s#/+$##')
case "$CWD_CANON" in github.com/*/*) : ;; *) exit 0 ;; esac
case "$CWD_CANON" in github.com/*/*/*) exit 0 ;; esac   # more than owner/repo → reject
SLUG="${CWD_CANON#github.com/}"
OWNER="${SLUG%%/*}"; NAME="${SLUG#*/}"
[[ -n "$OWNER" && -n "$NAME" ]] || exit 0
printf '%s' "$OWNER$NAME" | LC_ALL=C grep -q '[^A-Za-z0-9._-]' && exit 0

# ── ADR 0018 cross-cwd origin guard (the standalone-cd safety backstop) ──
# A pre-exec hook CANNOT prove a parsed `cd` actually executed and changed the cwd:
# a shell FUNCTION or alias named `cd`, a conditional that skipped it, a failed cd, or
# a symlink+`..` that resolves differently under bash-logical vs git-physical rules can
# all leave the merge running in the PAYLOAD cwd rather than TARGET_DIR. So when the
# command changed directory (TARGET_DIR set), the merge's REAL cwd is EITHER the
# resolved target OR the payload cwd — and we require BOTH to resolve to the SAME
# github origin. Then whichever one the merge used, the nudge targets the correct repo;
# a divergence is skipped (fail-safe). A git worktree shares its main checkout's origin,
# so the real pr-grind case (payload cwd + WORKTREE_DIR of the same repo) passes. Only
# enforced when TARGET_DIR is set — a no-cd merge already runs in the payload cwd, so
# CWD_CANON (from REPO_DIR) is that repo and there is no divergence to guard.
# NOT closed by this guard: a `cd` shell FUNCTION/alias can send the merge to a THIRD
# dir neither HOOK_CWD nor TARGET_DIR — see ACCEPTED LIMITS #3 below; that residual is
# inherent to a pre-exec hook and identical to the gh-alias one (#2).
if [[ -n "$TARGET_DIR" && -n "$HOOK_CWD" ]]; then
    # shellcheck disable=SC2312  # canon pipeline: sed/tr cannot fail meaningfully here
    PAYLOAD_URL=$(git -C "$HOOK_CWD" remote get-url origin 2>/dev/null || true)
    PAYLOAD_CANON=$(printf '%s' "$PAYLOAD_URL" | sed -E 's#^git@#https://#; s#^https?://##; s#:#/#; s#\.git/?$##; s#/+$##' | tr '[:upper:]' '[:lower:]')
    CWD_CANON_LC=$(printf '%s' "$CWD_CANON" | tr '[:upper:]' '[:lower:]')
    [[ -n "$PAYLOAD_CANON" && "$PAYLOAD_CANON" == "$CWD_CANON_LC" ]] || exit 0
elif [[ -n "$TARGET_DIR" ]]; then
    exit 0                      # cd present but no payload cwd to cross-check → fail-safe
fi

# ── Delegate resolution to gh, then REQUIRE resolved target == cwd repo ──
# `gh pr view` runs with GH_HOST pinned and GH_REPO cleared, so it resolves against
# the cwd repo's own remote. We still compare its canonical url to the cwd origin:
# any divergence (a cross-repo/cross-host URL) → skip.
if [[ -n "$POSITIONAL" ]]; then
    PRJSON=$( (cd "$REPO_DIR" 2>/dev/null && gh pr view "$POSITIONAL" --json number,headRefOid,url 2>/dev/null) || true)
else
    PRJSON=$( (cd "$REPO_DIR" 2>/dev/null && gh pr view --json number,headRefOid,url 2>/dev/null) || true)
fi
[[ -n "$PRJSON" ]] || exit 0
PR=$(printf '%s' "$PRJSON" | jq -r '.number // empty' 2>/dev/null) || exit 0
HEAD_SHA=$(printf '%s' "$PRJSON" | jq -r '.headRefOid // empty' 2>/dev/null) || exit 0
URL=$(printf '%s' "$PRJSON" | jq -r '.url // empty' 2>/dev/null) || exit 0
case "$PR" in ''|*[!0-9]*) exit 0 ;; esac
case "$HEAD_SHA" in ''|*[!0-9A-Fa-f]*) exit 0 ;; esac

# Canonical host/owner/repo of the resolved PR (strip scheme + `/pull/N`). Compare
# case-INSENSITIVELY: GitHub owner/repo are case-insensitive, and the origin may
# carry user-entered casing that differs from gh's canonical form.
VIEW_CANON=$(printf '%s' "$URL" | sed -E 's#^https?://##; s#/pull/[0-9]+/?$##; s#/+$##')
CWD_LC=$(printf '%s' "$CWD_CANON" | tr '[:upper:]' '[:lower:]')
VIEW_LC=$(printf '%s' "$VIEW_CANON" | tr '[:upper:]' '[:lower:]')
[[ "$VIEW_LC" == "$CWD_LC" ]] || exit 0           # target != cwd repo → skip (fail-safe)

# ── Active-or-force-on gate (skips the none-check on idle repos) ────────
# Resolve the force-on marker EXACTLY where the delegate (codex-nudge-if-expected.sh)
# does — the MAIN repo root (git-common-dir's parent, so it holds from a linked
# worktree) under a hardcoded `.claude` — so this pre-filter and the delegate agree
# on whether force-on is active. (STATE_DIR is intentionally NOT used here.)
FORCEON=0
_GCD=$(git -C "$REPO_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
case "$_GCD" in
    /*) [[ -f "$(dirname "$_GCD")/.claude/pr-grind-codex-expected.local" ]] && FORCEON=1 ;;
esac
ACTIVE=0
if bash "$SCRIPTS/codex-active-repo.sh" "$OWNER/$NAME" >/dev/null 2>&1; then ACTIVE=1; fi
[[ "$FORCEON" == "1" || "$ACTIVE" == "1" ]] || exit 0

# ── `none`-guard: nudge ONLY when Codex has ZERO engagement on this PR ──
# Paginate FULLY (--paginate), never a single 100-item page, so engagement beyond
# the first page is never missed — a false `none` would post a redundant nudge.
# ANY fetch error → exit 0, no post. Bare + [bot]-suffixed login (per ADR 0002).
# jq is fully defensive — `.[]?.user?.login? // empty`: a ghost/deleted reviewer or
# any malformed non-object element yields empty, NOT a jq error. Without the `?`s a
# single such element makes jq exit non-zero → `gh` non-zero → `|| exit 0` → a missed
# nudge (false-negative). A plain null `user` was already harmless (emits a stray
# `null` line the grep ignores); this also drops that noise.
# Bounded retry (2 attempts, brief backoff) around each transient gh api read before
# the fail-safe skip: on an inline/admin merge this hook is the SOLE nudge path (no
# pr-grind COMPLETION re-poll behind it), so a single flaky `none`-guard fetch would
# `|| exit 0` and silently drop the nudge with no retry (issue #398). Echoes stdout on
# success (rc 0 — including a legitimately EMPTY "no engagement" body); returns
# non-zero only after every attempt fails, preserving the fail-safe `|| exit 0`. The
# `--jq` filter stays a single-quoted literal here (identical for both reads) so the
# jq-defensiveness regression test still anchors on the runtime line.
gh_api_logins() {
    local _out _rc _attempt
    for _attempt in 1 2; do
        _out=$(gh api --paginate "$1" --jq '.[]?.user?.login? // empty' 2>/dev/null); _rc=$?
        [ "$_rc" -eq 0 ] && { printf '%s' "$_out"; return 0; }
        [ "$_attempt" -lt 2 ] && sleep 1
    done
    return 1
}
REVIEW_LOGINS=$(gh_api_logins "repos/$OWNER/$NAME/pulls/$PR/reviews") || exit 0
REACTION_LOGINS=$(gh_api_logins "repos/$OWNER/$NAME/issues/$PR/reactions") || exit 0
if printf '%s\n%s\n' "$REVIEW_LOGINS" "$REACTION_LOGINS" \
   | grep -qxE 'chatgpt-codex-connector(\[bot\])?'; then
    exit 0                            # Codex already engaged → not `none` → no nudge
fi

# ── Delegate the one-shot post ─────────────────────────────────────────
# cd into the repo dir (== the resolved target repo, verified above) so the
# wrapper's force-on root and codex-retrigger's per-(PR,HEAD) marker are anchored
# on the PR's own repo (shared with the SKILL path's marker → at most one `@codex
# review` per HEAD across both). Route all delegate output to stderr so this hook's
# stdout stays empty (approve). `|| true` so a failed nudge can never affect merge.
( cd "$REPO_DIR" 2>/dev/null || exit 0
  bash "$SCRIPTS/codex-nudge-if-expected.sh" "$PR" "$HEAD_SHA" "$OWNER/$NAME" "$ACTIVE" ) 1>&2 || true
exit 0
