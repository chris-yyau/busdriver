#!/usr/bin/env bash
# scripts/codex-nudge-if-expected.sh — POLICY wrapper around codex-retrigger.sh
# for the `none` (Codex NEVER auto-triggered) case. ADR 0013 (as revised, #320).
#
# WHY: ADR 0005's codex-retrigger fires only when Codex is `stale`. It does NOT
# fire when Codex is `none` — Codex never engaged on the PR — because `none` is
# legitimately non-gating and indistinguishable (from the GitHub API) between
# not-installed, quota-exhausted, and a dropped auto-review webhook. Blanket-
# nudging every `none` would force `@codex review` onto every PR on every repo.
#
# TRIGGER (ADR 0013 revision): a `none` Codex is nudged when EITHER
#   (a) FORCE-ON — the per-repo opt-in file
#       <main-root>/.claude/pr-grind-codex-expected.local exists (a cold-start
#       override: a new repo where Codex IS expected but has no history yet), OR
#   (b) AUTO-DETECT — the repo is proven Codex-active (recent reviews/reactions),
#       signalled by the 4th POSITIONAL arg `active-bit` (1/0) supplied by the
#       caller, or self-detected here via codex-active-repo.sh when it is absent.
#   Absent both → no-op (today's behavior: a `none` Codex is never nudged).
#
# The active bit is a POSITIONAL ARG, never an env var: an env signal would be
# injectable by a committed .claude/settings.json env block (the #325 / ADR 0016
# gate-env threat), and this is a force-nudge signal, so it stays caller-supplied.
#
# SCOPE — pure POLICY. The MECHANISM (one-shot-per-(PR,HEAD) post, marker, fail-
# safe, opt-out, phrase override) lives in codex-retrigger.sh, delegated to
# unchanged. Both paths share codex-retrigger's per-(PR,HEAD) marker, so at most
# ONE `@codex review` is posted per HEAD across the stale AND none paths.
#
# CONTRACT — fail-SAFE: exit 0 on every operational path (not triggered, bad
# args, delegate skip/fail). Exit 2 ONLY on missing required args (a wiring bug).
#   Usage:  codex-nudge-if-expected.sh <pr-number> <head-sha> [owner/repo] [active-bit]
#
# CWD CONTRACT — the caller invokes this from inside the target repo's worktree
# (or passes BUSDRIVER_MAIN_ROOT), so the opt-in root is the PR's own repo.
# Test seam: BUSDRIVER_MAIN_ROOT overrides the git-derived main-repo root.
set -u

PR="${1:-}"
HEAD_SHA="${2:-}"
REPO="${3:-}"
ACTIVE_BIT="${4:-}"

if [ -z "$PR" ] || [ -z "$HEAD_SHA" ]; then
    echo "usage: codex-nudge-if-expected.sh <pr-number> <head-sha> [owner/repo] [active-bit]" >&2
    exit 2
fi

DIR="$(cd "$(dirname "$0")" && pwd)"

# Delegate to the ADR 0005 mechanism (one-shot marker, fail-safe, opt-out, phrase).
# exec so codex-retrigger's own log lines and exit status surface directly.
delegate() { exec bash "${DIR}/codex-retrigger.sh" "$PR" "$HEAD_SHA" "$REPO"; }

# (a) FORCE-ON: opt-in file at the MAIN repo root. Resolve the root ONLY for this
# file check — auto-detect below does NOT need it, so an UNRESOLVABLE root must
# fall through to auto-detect (not abort), else the new default path silently
# no-ops (issue #320 regression). --git-common-dir's parent is the main-repo root
# in both worktree and plain-clone modes.
MAIN_ROOT="${BUSDRIVER_MAIN_ROOT:-}"
if [ -z "$MAIN_ROOT" ]; then
    GCD=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
    case "$GCD" in /*) MAIN_ROOT="$(dirname "$GCD")" ;; esac
fi
if [ -n "$MAIN_ROOT" ] && [ -f "${MAIN_ROOT}/.claude/pr-grind-codex-expected.local" ]; then
    echo "ℹ️  codex-nudge: force-on opt-in present; delegating one-shot nudge for PR #$PR." >&2
    delegate
fi

# (b) AUTO-DETECT: honor the caller's active bit (POSITIONAL, not env); only 0/1
# accepted — any other/empty value → self-detect via codex-active-repo.sh (its
# stderr diagnostic flows; stdout discarded).
ACTIVE=""
case "$ACTIVE_BIT" in 0 | 1) ACTIVE="$ACTIVE_BIT" ;; esac
if [ -z "$ACTIVE" ]; then
    if bash "${DIR}/codex-active-repo.sh" "$REPO" >/dev/null; then ACTIVE=1; else ACTIVE=0; fi
fi

if [ "$ACTIVE" = 1 ]; then
    echo "ℹ️  codex-nudge: repo is Codex-active; delegating one-shot nudge for PR #$PR." >&2
    delegate
fi

echo "ℹ️  codex-nudge: no force-on opt-in and repo not Codex-active; leaving \`none\` Codex non-gating." >&2
exit 0
