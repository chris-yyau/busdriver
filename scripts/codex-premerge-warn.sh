#!/usr/bin/env bash
# scripts/codex-premerge-warn.sh — ADR 0024 fail-open predicate for the
# pre-merge missing-Codex advisory. Decides whether pre-merge-gate.sh should
# surface its one-line warning on an allow path.
#
# Prints EXACTLY ONE token on stdout:
#     warn      repo is Codex-active-or-force-on AND Codex has NOT engaged (none).
#     silent    everything else — kill switch, idle repo, Codex engaged, OR any
#               ambiguity (unknown engagement, bad input, tool/fetch failure).
#
# This is the "entire predicate" the ADR requires behind ONE shared latency
# budget: the caller (pre-merge-gate.sh) runs this whole script under a single
# outer `timeout`, so BOTH network sub-checks (active-repo detection + the
# engagement probe) are bounded together (constraint 2). If that outer timeout
# kills this script, the caller maps the result to `silent` (constraint 1/3).
#
# ORDER (matches #450 spec step 3): kill-switch → force-on marker → active-repo
# → engagement. Force-on is checked BEFORE the activation lookup so a force-on
# repo pays no active-detection round-trip.
#
# FAIL TOWARD SILENCE (constraint 3): only a POSITIVE active-or-force-on AND a
# POSITIVE `none` yields `warn`. Every error, timeout, or ambiguity → `silent`.
# READ-ONLY (constraint 7): delegates only to read-only helpers; posts nothing.
#
#   Usage:  codex-premerge-warn.sh <owner/repo> <pr> <repo_dir>
#   Always prints one token and exits 0.
set -u

REPO="${1:-}"
PR="${2:-}"
REPO_DIR="${3:-}"

emit() { printf '%s\n' "$1"; exit 0; }

# ── Kill switch FIRST — before any network or filesystem work (constraint 4) ──
# PR_GRIND_CODEX_RETRIGGER=0 suppresses the advisory entirely. Kill-only: its
# sole effect is to short-circuit to silence, so a repo-injected value can only
# turn the repo's OWN advisory off (fail-toward-silence, grants no bypass).
[ "${PR_GRIND_CODEX_RETRIGGER:-1}" = "0" ] && emit silent

# ── Resolve this script's dir so it works from CLAUDE_PLUGIN_ROOT ─────────
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTIVE_REPO="$DIR/codex-active-repo.sh"
PROBE="$DIR/codex-engagement-probe.sh"
if [ ! -f "$ACTIVE_REPO" ] || [ ! -f "$PROBE" ]; then emit silent; fi

# ── Force-on marker (checked before the active-repo lookup) ──────────────
# Resolved EXACTLY where codex-nudge-premerge.sh resolves it: the MAIN repo root
# (git-common-dir's parent, so it holds from a linked worktree) under a hardcoded
# `.claude` — so this and the nudge agree on force-on. STATE_DIR is intentionally
# not used here.
FORCEON=0
if [ -n "$REPO_DIR" ]; then
    _GCD=$(git -C "$REPO_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
    case "$_GCD" in
        /*) [ -f "$(dirname "$_GCD")/.claude/pr-grind-codex-expected.local" ] && FORCEON=1 ;;
    esac
fi

# ── Active-repo detection (skipped when force-on) ────────────────────────
ACTIVE=0
if [ "$FORCEON" != "1" ]; then
    if bash "$ACTIVE_REPO" "$REPO" >/dev/null 2>&1; then ACTIVE=1; fi
fi

# Neither active nor force-on → nothing to warn about.
[ "$FORCEON" = "1" ] || [ "$ACTIVE" = "1" ] || emit silent

# ── Engagement probe (only reached on an active-or-force-on repo) ────────
STATE=$(bash "$PROBE" "$REPO" "$PR" 2>/dev/null | head -n1)
case "$STATE" in
    none)    emit warn ;;   # active/force-on + zero Codex engagement → the #444 gap
    *)       emit silent ;; # engaged, unknown, or any malformed token → silent
esac
