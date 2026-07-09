#!/usr/bin/env bash
# scripts/codex-nudge-if-expected.sh — opt-in policy wrapper around
# codex-retrigger.sh for the `none` (Codex NEVER auto-triggered) case. ADR 0013.
#
# WHY: ADR 0005's codex-retrigger fires only when Codex is `stale` (engaged on an
# older SHA, didn't re-ack HEAD). It does NOT fire when Codex is `none` — Codex
# never engaged on the PR at all — because `none` is legitimately non-gating and
# indistinguishable (from the GitHub API) between not-installed, quota-exhausted,
# and a dropped auto-review webhook. Blanket-nudging every `none` would force
# `@codex review` onto every PR on every repo (issue #298). This wrapper adds the
# nudge ONLY on a per-repo opt-in ("Codex is expected to auto-review here").
#
# SCOPE — pure POLICY (the opt-in check). The MECHANISM (one-shot-per-(PR,HEAD)
# post, marker, fail-safe, opt-out, phrase override) lives in codex-retrigger.sh,
# which this script delegates to unchanged — preserving ADR 0005's helper-is-
# mechanism / caller-is-policy split. Because both paths share codex-retrigger's
# per-(PR,HEAD) marker, at most ONE `@codex review` is ever posted per HEAD across
# the stale AND none paths combined.
#
# Opt-in:  <main-repo-root>/.claude/pr-grind-codex-expected.local  (gitignored,
#          same pattern as pr-grind-auto-admin-solo.local). ABSENT => no-op
#          (today's behavior: a `none` Codex is never nudged). The file lives at
#          the MAIN repo root, not the ephemeral worktree — worktree `.local`
#          files are not copied into worktrees.
#
# CONTRACT — fail-SAFE: exit 0 on every operational path (not opted in, bad args,
#   delegate skip/fail). Exit 2 ONLY on missing required args (wiring bug). A
#   failed nudge must NEVER stale the merge gate; call sites also append `|| true`.
#   The CALLER (pr-grind COMPLETION first-engagement grace) invokes this ONCE,
#   before its existing bounded re-poll, so an opted-in repo whose Codex never
#   auto-triggered gets one nudge; if Codex still does not engage within the grace
#   it falls through to non-gating `none` (bounded — NEVER a hang).
#
#   Usage:  codex-nudge-if-expected.sh <pr-number> <head-sha> [owner/repo]
#
# Test seam: BUSDRIVER_MAIN_ROOT overrides the git-derived main-repo root so the
# opt-in lookup needs no real git checkout.
set -u

PR="${1:-}"
HEAD_SHA="${2:-}"
REPO="${3:-}"

if [ -z "$PR" ] || [ -z "$HEAD_SHA" ]; then
    echo "usage: codex-nudge-if-expected.sh <pr-number> <head-sha> [owner/repo]" >&2
    exit 2
fi

DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve the MAIN repo root. --git-common-dir's parent is the main-repo root in
# BOTH worktree and plain-clone modes (the same resolver pr-grind uses for its
# other opt-ins). BUSDRIVER_MAIN_ROOT short-circuits it for tests.
MAIN_ROOT="${BUSDRIVER_MAIN_ROOT:-}"
if [ -z "$MAIN_ROOT" ]; then
    GCD=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
    case "$GCD" in /*) MAIN_ROOT="$(dirname "$GCD")" ;; esac
fi
# Fail-SAFE: if the main-repo root can't be resolved we cannot confirm THIS repo
# opted in. Do NOT fall back to a bare "." — a CWD-relative lookup could read an
# UNRELATED directory's pr-grind-codex-expected.local and nudge a repo that never
# consented. Unresolvable root => skip (exit 0), exactly like "not opted in".
if [ -z "$MAIN_ROOT" ]; then
    echo "ℹ️  codex-nudge: could not resolve main-repo root; skipping (no nudge)." >&2
    exit 0
fi

OPTIN="${MAIN_ROOT}/.claude/pr-grind-codex-expected.local"
if [ ! -f "$OPTIN" ]; then
    # Not opted in → preserve today's behavior: never nudge a `none` Codex.
    echo "ℹ️  codex-nudge: no pr-grind-codex-expected.local opt-in; leaving \`none\` Codex non-gating." >&2
    exit 0
fi

echo "ℹ️  codex-nudge: opt-in present; delegating one-shot nudge to codex-retrigger for PR #$PR." >&2
# Delegate to the ADR 0005 mechanism (one-shot marker, fail-safe, opt-out, phrase).
# exec so codex-retrigger's own log lines and exit status surface directly.
exec bash "${DIR}/codex-retrigger.sh" "$PR" "$HEAD_SHA" "$REPO"
