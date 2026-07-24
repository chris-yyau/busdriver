#!/usr/bin/env bash
# PostToolUse hook: deterministic `@codex review` nudge at PR-CREATE time.
#
# WHY (ADR 0024 Revisit-trigger #1 — issue #473): the pre-MERGE nudge
# (codex-nudge-premerge.sh) posts `@codex review` at merge-INTENT, which is too
# late. PR #470 measured it: the nudge posted +5s before a merge that completed
# before Codex's review — carrying a P1 on the changed code — landed ~4 min later
# on the already-closed PR. ADR 0024 pre-committed the fix instead of a merge
# block (Codex is advisory / not a required check; a block on the ambiguous `none`
# would fail-open on a timer — gate-fatigue theater it unanimously rejected):
# post `@codex review` right after `gh pr create` SUCCEEDS, so Codex gets its FULL
# pre-merge window (CI + grind time) rather than a merge-time race. This hook does
# NOT gate the merge — it deletes the latency race the premerge nudge cannot close.
#
# SCOPE — pure trigger. The MECHANISM (force-on/active policy, the one-shot-per-
# (PR,HEAD) marker SHARED with the premerge + SKILL-prose paths, the actual
# `gh pr comment`, opt-out, phrase override) is codex-nudge-if-expected.sh →
# codex-retrigger.sh, delegated to unchanged. It shares codex-retrigger's
# per-`(PR,HEAD)` one-shot marker, which dedups the create + merge + SKILL paths
# that run in the SAME checkout (pr-grind creates and merges in one worktree, so
# the common case is one `@codex review` per HEAD); premerge's `none`-guard also
# skips once Codex has engaged. (codex-retrigger's marker is worktree-local, so
# create and merge run from DIFFERENT linked worktrees could each post once — a
# bounded, benign double-nudge on the same PR, not a correctness issue for a
# non-gating hook.) No `none`-guard is needed here: a just-created PR has zero
# engagement by construction, and the marker (not a live engagement check) is what
# enforces idempotency within a checkout.
#
# SUCCESS-ONLY — mirrors post-pr-consume-marker.sh: a real `gh pr create` (shared
# command-word detector, not prose that merely quotes the command) whose output
# carried a github.com PR URL, exited 0 (when the harness reports a code), and
# shows NO failure signature (`already exists`, `error:`, HTTP 4xx/5xx, ...). A
# failed create that echoes an existing PR's URL therefore never nudges.
#
# TARGET — the nudge targets the current checkout's own PR, resolved by gh DIRECTLY
# (`gh pr view`, no positional; the PR number is NOT scraped from output), which must
# be OPEN and in the cwd `origin` repo (case-insensitive, github.com only). A
# github.com URL for that PR must ALSO appear in the output (the GUARD below), which
# turns the common `gh pr create --head <other>` / trailing-`git switch` create into
# a fail-safe MISS. github.com only: the delegate's `gh pr comment` uses the default
# host.
#
# ACCEPTED LIMITS (inherent to a non-gating hook that observes shell state — the
# SAME class codex-nudge-premerge.sh documents in its ACCEPTED LIMITS #2–4. Do NOT
# try to "fix" these by parsing the command or enumerating gh error strings; a
# parser/denylist always lags, and the bound that matters already holds: bounded,
# deduped, non-gating, on the OPERATOR'S OWN machine — never a merge, never gating):
#   1. POST-command state. A PostToolUse hook runs AFTER the whole Bash call, so it
#      reads the FINAL cwd / origin / branch. To stop a compound from MOVING that
#      state around the create, precreate_parse.py's LONE-CREATE gate fires ONLY when
#      the create is the command's ONE real statement (only a plain `cd <literal>` /
#      non-sensitive assignments before it, NOTHING after, no `-R`/substitution/
#      GH_*/GIT_* in the create segment) — so `gh pr create && cd B`,
#      `git remote set-url … && gh pr create`, `-R other/repo`, and substitutions are
#      all fail-safe MISSES, not mistargets. The RESIDUAL is only what a pre-exec
#      parser inherently cannot see — a `cd`/`gh`/`git` SHELL FUNCTION or ALIAS, or an
#      inherited GH_*/GIT_* env — the identical inherent limit premerge documents
#      (ACCEPTED LIMITS #2–4), bounded to a deduped `@codex review` on the operator's
#      own machine.
#   2. The guard is a HEURISTIC, not a proof gh created THIS PR: a compound that also
#      prints the current PR's own URL (after `--head`/switch, or masking a failed
#      create — gh's error not in the signature list) nudges the current checkout's
#      own OPEN PR once, deduped. Benign (the PR is real and the operator's own).
#
# ACCEPTED LIMIT 3 (lifecycle, fail-safe MISS): this hook is registered on
# PostToolUse, which fires only when the whole Bash call SUCCEEDS (exit 0). A
# compound whose OVERALL exit is nonzero even though the create succeeded —
# `gh pr create --fill && false` — routes to PostToolUseFailure instead and is
# missed here. That is the SAME registration (PostToolUse / Bash) the sibling
# post-pr-consume-marker.sh uses, and the miss is fail-safe: the premerge nudge
# backstops it. Registering on PostToolUseFailure too would NOT help — the
# exit-code guard above (nonzero reported code → skip) would drop that very case,
# and relaxing it would reintroduce the fail-OPEN the design refuses.
#
# NON-GATING — a PostToolUse hook cannot block anyway; this emits NOTHING to
# stdout and always exits 0. FAIL-SAFE = SKIP on any parse/query error, so a bug
# here yields at most a missed (or bounded, deduped) nudge — never a spurious
# `@codex review`. Kill switch: PR_GRIND_CODEX_RETRIGGER=0 (re-imported by the
# hooks.json `env -i` line) disables the whole chain before any network work.
#
# Runs under lib/sanitized-gate.sh (ADR 0016 env containment), like the gates and
# the premerge nudge. GH_HOST is pinned / GH_REPO cleared so no repo-controlled
# value can route an outbound, credentialed `gh` call (#416).
set -u

# Pin gh's routing (belt-and-braces against a future non-hooks.json caller; the
# #416 invariant). Exported so the delegate's `gh pr comment` inherits the pin.
export GH_HOST=github.com
unset GH_REPO

# ── Read the PostToolUse payload once ──────────────────────────────────
HOOK_DATA=$(cat 2>/dev/null || true)
[[ -z "$HOOK_DATA" ]] && exit 0

# Fast pre-filter: bail on anything that can't be a `gh pr create` before paying
# for python/gh. `pr`+`create` are the subcommand tokens the caller always writes
# unquoted; a near-no-op for the vast majority of Bash calls.
case "$HOOK_DATA" in
    *pr*create*) ;;
    *) exit 0 ;;
esac

# Kill switch — short-circuit before any network/tool work.
[[ "${PR_GRIND_CODEX_RETRIGGER:-1}" == "0" ]] && exit 0

command -v python3 >/dev/null 2>&1 || exit 0
command -v gh >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$DIR/../../scripts"
# shellcheck source=lib/resolve-repo-dir.sh disable=SC1091
source "$DIR/lib/resolve-repo-dir.sh" || exit 0

# ── Parse (delegated to lib/precreate_parse.py, a FILE not an inline `python3 -c`
#    like sibling nudge_parse.py: the LONE-CREATE integrity check needs `$(`,
#    backticks and `\${` as literals, which a bash double-quoted -c string mangles).
#    Emits `yes` + json-encoded target_dir + json-encoded cwd + one lowercased
#    owner/repo/number key per github.com PR URL gh printed — ONLY for a successful,
#    LONE `gh pr create` (see the file header). Any other shape → empty → skip.
_GATE_LIB="$DIR/lib"
PARSE=$(printf '%s' "$HOOK_DATA" | PYTHONPATH="$_GATE_LIB" python3 -S "$_GATE_LIB/precreate_parse.py" 2>/dev/null || true)

# shellcheck disable=SC2312  # sed over $PARSE cannot fail meaningfully; masked status is fine
[[ "$(printf '%s' "$PARSE" | sed -n '1p')" == "yes" ]] || exit 0
# target_dir/cwd are JSON-encoded (single line each); decode with jq so an embedded
# newline in a path can never shift these fields. jq appends a \x01 (SOH) sentinel
# with `-j` (raw, no jq newline) so that $(...) — which strips ALL trailing newlines
# — cannot eat a path's OWN trailing newline(s); we then strip exactly the sentinel.
# SOH is invalid in a filesystem path, so it never occurs in the real value.
# Malformed JSON → empty → the resolver below fails closed (skip).
# shellcheck disable=SC2312  # sed|jq pipeline; a decode failure yields empty → resolver skips
TARGET_DIR=$(printf '%s' "$PARSE" | sed -n '2p' | jq -j '. + "\u0001"' 2>/dev/null); TARGET_DIR=${TARGET_DIR%$'\001'}
# shellcheck disable=SC2312
HOOK_CWD=$(printf '%s' "$PARSE" | sed -n '3p' | jq -j '. + "\u0001"' 2>/dev/null); HOOK_CWD=${HOOK_CWD%$'\001'}
OUT_KEYS=$(printf '%s' "$PARSE" | sed -n '4,$p')   # lowercased owner/repo/number keys gh printed
# A cd target / cwd containing a newline is inherently ambiguous (never a real
# checkout path); reject rather than resolve a normalized-but-different repo.
# Embedded newlines are already framing-safe (json+jq above) — this is a
# belt-and-braces fail-safe, not the framing's correctness guard.
case "$TARGET_DIR" in *$'\n'*) exit 0 ;; esac
case "$HOOK_CWD" in *$'\n'*) exit 0 ;; esac

# ── Resolve the repo the create ran in ──
gate_resolve_repo_dir "$TARGET_DIR" "$HOOK_CWD"
[[ "$GATE_RESOLVE_STATUS" == "proceed" ]] || exit 0
REPO_DIR="$GATE_REPO_DIR"

# cwd repo canonical owner/repo from origin (offline). Same canonicalization as
# codex-nudge-premerge.sh, incl. the userinfo strip for credentialed HTTPS origins.
CWD_URL=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)
# Lowercase the canonical origin (host + owner/repo are case-insensitive on
# GitHub) so `https://GitHub.com/Owner/Repo.git` is accepted, not rejected before
# the later case-insensitive comparisons.
# shellcheck disable=SC2312  # sed/tr canon pipeline cannot fail meaningfully
# Reject a stacked-scheme origin (two `://`, e.g. `ssh://https://github.com/…`) —
# the sequential scheme strips below could otherwise collapse it into a FALSE
# github.com authority that passes the owner/repo checks.
case "$CWD_URL" in *://*://*) exit 0 ;; esac
# Strip a leading `ssh://` scheme FIRST so the standard `ssh://git@github.com/owner/
# repo.git` form canonicalizes correctly (without this the later `:`→`/` mangles the
# scheme's own colon). Handles https, scp-style git@host:owner, ssh://, and
# credentialed https (userinfo strip). A port in an ssh URL (…github.com:22/…)
# yields an extra path segment and is safely rejected by the owner/repo checks below.
# shellcheck disable=SC2312  # sed/tr canon pipeline cannot fail meaningfully
CWD_CANON=$(printf '%s' "$CWD_URL" | sed -E 's#^ssh://##; s#^git@#https://#; s#^https?://##; s#^[^/@]*@##; s#:#/#; s#\.git/?$##; s#/+$##' | tr '[:upper:]' '[:lower:]')
case "$CWD_CANON" in github.com/*/*) : ;; *) exit 0 ;; esac
case "$CWD_CANON" in github.com/*/*/*) exit 0 ;; esac   # more than owner/repo → reject
SLUG="${CWD_CANON#github.com/}"
OWNER="${SLUG%%/*}"; NAME="${SLUG#*/}"
[[ -n "$OWNER" && -n "$NAME" ]] || exit 0
printf '%s' "$OWNER$NAME" | LC_ALL=C grep -q '[^a-z0-9._-]' && exit 0

# ── TARGET: the current branch's own PR ──
# Resolved by gh DIRECTLY (gh pr view, no positional) — the PR NUMBER is NOT
# scraped from output. gh runs with GH_HOST pinned / GH_REPO cleared → resolves the
# cwd repo's current-branch PR — the operator's OWN PR in the common case (worst
# case: a mistargeted-but-deduped nudge if a compound moved the cwd/origin
# post-command, or a benign self-nudge — see ACCEPTED LIMITS in the header — or a
# miss; all non-gating).
PRJSON=$( (cd "$REPO_DIR" 2>/dev/null && gh pr view --json number,headRefOid,url,state 2>/dev/null) || true)
[[ -n "$PRJSON" ]] || exit 0
PR=$(printf '%s' "$PRJSON" | jq -r '.number // empty' 2>/dev/null) || exit 0
HEAD_SHA=$(printf '%s' "$PRJSON" | jq -r '.headRefOid // empty' 2>/dev/null) || exit 0
VURL=$(printf '%s' "$PRJSON" | jq -r '.url // empty' 2>/dev/null) || exit 0
STATE=$(printf '%s' "$PRJSON" | jq -r '.state // empty' 2>/dev/null) || exit 0
case "$PR" in ''|*[!0-9]*) exit 0 ;; esac
case "$HEAD_SHA" in ''|*[!0-9A-Fa-f]*) exit 0 ;; esac
[[ "$STATE" == "OPEN" ]] || exit 0                       # a successful create yields an OPEN PR

# Resolved PR's repo (strip scheme + /pull/N) must equal the cwd origin repo.
# shellcheck disable=SC2312  # sed/tr canon pipeline cannot fail meaningfully
VIEW_LC=$(printf '%s' "$VURL" | sed -E 's#^https?://##; s#/pull/[0-9]+/?$##; s#/+$##' | tr '[:upper:]' '[:lower:]')
[[ "$VIEW_LC" == "$CWD_CANON" ]] || exit 0               # CWD_CANON already lowercased

# GUARD — gh must have PRINTED this branch's PR URL in the create output. This ties
# the nudge to output that named THIS branch's PR (not an unrelated command that
# merely ran gh pr create), and turns the common `gh pr create --head <other>` /
# trailing-`git switch` cases into fail-safe SKIPS (the premerge nudge backstops
# them). It is a HEURISTIC, not a proof the create made THIS PR: a compound that
# ALSO prints the current PR's own URL passes it (ACCEPTED LIMITS in the header).
# OUT_KEYS is lowercased owner/repo/number.
WANT_KEY=$(printf '%s/%s/%s' "$OWNER" "$NAME" "$PR" | tr '[:upper:]' '[:lower:]')
# shellcheck disable=SC2312  # grep over a known-small list; masked status is fine
printf '%s\n' "$OUT_KEYS" | grep -qxF "$WANT_KEY" || exit 0

# ── Delegate the one-shot nudge (force-on/active policy + dedup marker + the post
# all live in the delegate). cd into REPO_DIR (== the created PR's repo, verified
# above) so the force-on root and per-(PR,HEAD) marker anchor on the PR's own repo,
# shared with the premerge + SKILL paths. Output → stderr so this hook's stdout
# stays empty; `|| true` so a failed nudge can never affect anything. ───────────
( cd "$REPO_DIR" 2>/dev/null || exit 0
  bash "$SCRIPTS/codex-nudge-if-expected.sh" "$PR" "$HEAD_SHA" "$OWNER/$NAME" ) 1>&2 || true
exit 0
