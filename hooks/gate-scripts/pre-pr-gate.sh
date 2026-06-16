#!/usr/bin/env bash
# PreToolUse hook: gate `gh pr create` on codex review of full base..HEAD diff
#
# Blocks PR creation until litmus passes on the aggregate branch diff.
# This catches code that escaped per-commit review (worktree commits, existing
# branches, pre-existing commits from other sessions).
#
# Fail-CLOSED: errors block PR creation (user preference: stuck > skipped review)
# Skip: .claude/skip-litmus.local (or SKIP_LITMUS=1 exported in parent shell
#       before `claude` starts — inline `SKIP_LITMUS=1 gh pr create` does NOT
#       work because PreToolUse hooks fire before the command's inline env
#       is applied; same caveat as pre-commit gate)
#
# Council decision (2026-03-21): Gate `gh pr create` only, NOT `git push`.
# Gating push kills WIP pushes and destroys credibility of the gate system.

set -euo pipefail
trap 'printf "{\"decision\":\"block\",\"reason\":\"Pre-PR gate error — blocking as precaution. If stuck, create .claude/skip-litmus.local in your terminal.\"}\n"; exit 0' ERR

# ── Block emission helper ─────────────────────────────────────────────
block_emit() {
    if command -v jq &>/dev/null; then
        jq -n --arg r "$1" '{decision:"block", reason:$r}'
    else
        local escaped
        escaped=$(printf '%s' "$1" | sed 's/"/\\"/g' | head -c 2000)
        printf '{"decision":"block","reason":"%s"}\n' "$escaped"
    fi
}

# ── Shared repo-dir resolver ──────────────────────────────────────────
# shellcheck source=lib/resolve-repo-dir.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/resolve-repo-dir.sh"

# ── python3 pre-check ─────────────────────────────────────────────────
if ! command -v python3 &>/dev/null; then
    block_emit "CRITICAL: python3 not found. PR gate requires python3 for JSON parsing. Install python3 to restore gate enforcement."
    exit 0
fi

# Consume stdin
HOOK_DATA=$(cat 2>/dev/null || true)
[ -z "$HOOK_DATA" ] && exit 0

# Fast pre-filter: skip if hook data doesn't look like it could contain gh pr create
case "$HOOK_DATA" in
    *\"Bash\"*gh\ pr\ create*) ;;
    *gh\ pr\ create*\"Bash\"*) ;;
    *) exit 0 ;;
esac

# Parse tool name and command, verify gh pr create, and extract target directory
PARSE_RESULT=$(printf '%s' "$HOOK_DATA" | python3 -c "
import sys, json, re, os
try:
    d = json.load(sys.stdin)
    tool = d.get('tool_name', d.get('toolName', ''))
    if tool != 'Bash':
        sys.exit(0)
    cwd = d.get('cwd') or ''
    inp = d.get('tool_input', d.get('toolInput', {}))
    if isinstance(inp, str):
        inp = json.loads(inp)
    cmd = inp.get('command', '')
    segments = re.split(r'&&|\|\||[;\n|]', cmd)
    target_dir = ''
    for seg in segments:
        seg = seg.strip()
        cd_m = re.match(r'cd\s+(.*)', seg)
        if cd_m:
            # Strip outer quotes, then expand ~ (shell would expand it before
            # cd runs; the gate sees the literal command string, so we have
            # to mimic that expansion or git -C will fail on '~/repo' literal).
            raw = cd_m.group(1).strip().strip('\042\047')
            target_dir = os.path.expanduser(raw)
            continue
        while re.match(r'^\w+=\S*\s', seg):
            seg = re.sub(r'^\w+=\S*\s+', '', seg, count=1)
        if re.match(r'gh\s+pr\s+create\b', seg):
            print('yes')
            print(target_dir)
            print(cwd)
            break
except Exception:
    # Fail-CLOSED: fast pre-filter matched gh pr create but parser failed.
    print('error')
    print('')
    print('')
" 2>/dev/null || true)

IS_GH_PR_CREATE=$(echo "$PARSE_RESULT" | head -1)
TARGET_DIR=$(echo "$PARSE_RESULT" | sed -n '2p')
HOOK_CWD=$(echo "$PARSE_RESULT" | sed -n '3p')

# Fail-closed: parser error after fast pre-filter matched → block as precaution
if [ "$IS_GH_PR_CREATE" = "error" ]; then
    block_emit "Pre-PR gate: failed to parse tool input for command matching gh pr create pattern. Blocking as precaution (fail-closed). If stuck, create .claude/skip-litmus.local in your terminal."
    exit 0
fi

[ "$IS_GH_PR_CREATE" != "yes" ] && exit 0

# Resolve REPO_DIR (cwd-anchored; cd target only as a safe refinement).
# Fail-CLOSED on command-substitution targets the gate cannot evaluate.
gate_resolve_repo_dir "$TARGET_DIR" "$HOOK_CWD"
if [ "$GATE_RESOLVE_STATUS" = "block-unresolvable" ]; then
    block_emit "Pre-PR gate: the command's cd target uses command substitution the gate cannot resolve statically (e.g. cd \"\$(...)\"). Run gh pr create from the repo root, or use cd \"\$(git rev-parse --show-toplevel)\" which the gate recognizes. Blocking as precaution (fail-closed)."
    exit 0
fi
# Genuinely not in a git repo → approve (gh pr create fails on its own).
[ "$GATE_RESOLVE_STATUS" = "outside-repo" ] && exit 0
REPO_DIR="$GATE_REPO_DIR"

# ── Skip overrides (shared with commit gate) ──────────────────────────
SKIP_FILE="$REPO_DIR/.claude/skip-litmus.local"
if [ -f "$SKIP_FILE" ]; then
    FILE_AGE=999
    _MTIME=$(stat -f %m "$SKIP_FILE" 2>/dev/null) \
        || _MTIME=$(stat -c %Y "$SKIP_FILE" 2>/dev/null) \
        || _MTIME=""
    [ -n "$_MTIME" ] && FILE_AGE=$(( $(date +%s) - _MTIME ))
    if [ "$FILE_AGE" -lt 30 ]; then
        rm -f "$SKIP_FILE"
        block_emit "BLOCKED: skip-litmus.local was created moments ago (likely self-bypass). Run /litmus instead."
        exit 0
    fi
    rm -f "$SKIP_FILE"
    mkdir -p "$REPO_DIR/.claude"
    printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-pr"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$REPO_DIR/.claude/bypass-log.jsonl" 2>/dev/null || true
    exit 0
fi
[ "${SKIP_LITMUS:-0}" = "1" ] && exit 0

# ── ~/.claude repo: auto-generated file bypass ────────────────────────
# If all changes on this branch vs main are auto-generated files, skip review.
REPO_ROOT=$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")
if [ "$REPO_ROOT" = "$HOME/.claude" ]; then
    BASE_BRANCH=$(git -C "$REPO_DIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main")
    AUTO_GEN_PATHS=(
        "homunculus/"
        "memory/"
        "metrics/"
        "plugins/blocklist.json"
        "plugins/config.json"
        "plugins/install-counts-cache.json"
        "plugins/installed_plugins.json"
        "plugins/known_marketplaces.json"
        "scripts/auto-backup.log"
        "session-aliases.json"
        ".claude/bypass-log.jsonl"
        "bypass-log.jsonl"
    )
    ALL_AUTO=true
    HAS_FILES=false
    while IFS= read -r changed_file; do
        [ -z "$changed_file" ] && continue
        HAS_FILES=true
        is_auto=false
        for pattern in "${AUTO_GEN_PATHS[@]}"; do
            case "$pattern" in
                */) case "$changed_file" in ${pattern}*) is_auto=true; break ;; esac ;;
                *)  [ "$changed_file" = "$pattern" ] && is_auto=true && break ;;
            esac
        done
        if [ "$is_auto" = false ]; then
            ALL_AUTO=false
            break
        fi
    done < <(git -C "$REPO_DIR" diff --name-only "${BASE_BRANCH}...HEAD" 2>/dev/null)
    if [ "$HAS_FILES" = true ] && [ "$ALL_AUTO" = true ]; then
        exit 0
    fi
fi

# ── Check for codex review marker ─────────────────────────────────────
# Uses the SAME marker as the commit gate (.claude/litmus-passed.local).
# The PR gate does NOT consume the marker — the commit gate handles that.
# This allows: review → commit (consumes marker) → push → PR create.
#
# For the PR gate to pass, one of these must be true:
#   1. A review marker exists (review done but not yet committed — unusual but valid)
#   2. A PR-review marker exists (.claude/pr-review-passed.local) — set by running
#      litmus specifically for the PR diff
MARKER="$REPO_DIR/.claude/litmus-passed.local"
PR_MARKER="$REPO_DIR/.claude/pr-review-passed.local"

if [ -f "$PR_MARKER" ]; then
    PR_MARKER_CONTENT=$(cat "$PR_MARKER" 2>/dev/null || echo "")
    if echo "$PR_MARKER_CONTENT" | grep -qE '^(DEGRADED|SKIPPED-NONE|BUILTIN-)'; then
        rm -f "$PR_MARKER"
    elif echo "$PR_MARKER_CONTENT" | grep -qE '^[a-f0-9]{64}$'; then
        # SHA-256 hash — verify it matches current base..HEAD diff to prevent stale markers
        # Must match the writer's hashing: printf '%s' "$DIFF" | sha256sum (no trailing newline)
        # Respect LITMUS_PR_BASE to match the marker writer's base branch
        PR_BASE="${LITMUS_PR_BASE:-$(git -C "$REPO_DIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/||' || echo "origin/main")}"
        [[ -n "${LITMUS_PR_BASE:-}" && "$PR_BASE" != origin/* ]] && PR_BASE="origin/${PR_BASE}"
        DIFF_OUTPUT=$(git -C "$REPO_DIR" diff "${PR_BASE}...HEAD" 2>/dev/null || true)
        CURRENT_HASH=$(printf '%s' "$DIFF_OUTPUT" | (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1)
        if [ "$PR_MARKER_CONTENT" = "$CURRENT_HASH" ]; then
            # Hash matches current diff — defer consumption and allow.
            # Do NOT consume here. The marker is consumed by the PostToolUse
            # hook (post-pr-consume-marker.sh) only after `gh pr create`
            # actually succeeds. Consuming in PreToolUse burns the review when
            # gh then fails (missing --body-file, network, bad --base, auth
            # expiry), forcing a redundant 6-agent re-review of unchanged code.
            # This mirrors the deferred-consumption pattern the commit gate
            # already uses (pre-commit-gate.sh validates,
            # post-commit-consume-marker.sh consumes).
            # Safe to defer: the marker is the SHA-256 of this exact diff, so a
            # marker that survives a gh failure only ever re-authorizes the
            # identical reviewed diff — any new commit changes the hash and the
            # marker is rejected as stale on the next gate check.
            exit 0
        else
            # Stale marker from a different branch or older diff — reject
            echo "[pre-pr-gate] PR review marker hash mismatch (stale marker from different branch/diff). Re-run litmus PR review." >&2
            rm -f "$PR_MARKER"
        fi
    else
        # Genuine PR review pass (non-hash format) — consume and allow
        rm -f "$PR_MARKER"
        exit 0
    fi
fi

if [ -f "$MARKER" ]; then
    MARKER_CONTENT=$(cat "$MARKER" 2>/dev/null || echo "")
    # Reject DEGRADED, SKIPPED-NONE, BUILTIN- markers — PR requires external CLI review
    if echo "$MARKER_CONTENT" | grep -qE '^(DEGRADED|SKIPPED-NONE|BUILTIN-)'; then
        : # Fall through to blocking logic — these markers don't satisfy PR gate
    elif echo "$MARKER_CONTENT" | grep -qE '^[a-f0-9]{64}$'; then
        # Valid SHA-256 hash from external CLI review — allow PR creation
        # Do NOT consume — the commit gate needs it
        exit 0
    elif echo "$MARKER_CONTENT" | grep -qE '^PASS(-MERGE)?-[0-9]+$'; then
        # Valid timestamped pass marker (auto-generated files, merge commits)
        # Do NOT consume — the commit gate needs it
        exit 0
    else
        # Unrecognized marker format — reject as invalid
        echo "[pre-pr-gate] Marker content not recognized (expected SHA-256 hash or PASS-*): ${MARKER_CONTENT:0:30}..." >&2
    fi
fi

# ── Smart PR gate: check if all commits were per-commit reviewed ──────
# If every commit in base..HEAD was individually reviewed (tracked in
# reviewed-commits.local by post-commit-consume-marker.sh), skip the
# redundant full-branch re-review. Only require PR-level review when
# unreviewed commits exist (worktree, external tools, other sessions).
#
# Entries are branch-scoped ("branch:sha") to prevent cross-branch carry-over.
# Also accepts legacy bare SHA format for backwards compatibility.
REVIEWED_FILE="$REPO_DIR/.claude/reviewed-commits.local"
if [ -f "$REVIEWED_FILE" ]; then
    BASE_BRANCH=$(git -C "$REPO_DIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main")
    CURRENT_BRANCH=$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "")
    ALL_REVIEWED=true
    while IFS= read -r commit_sha; do
        [ -z "$commit_sha" ] && continue
        # Check branch-scoped entry ("branch:sha") first, then bare SHA for compat
        # Use -x (exact line match) to prevent substring matches across branches
        if grep -qxF "${CURRENT_BRANCH}:${commit_sha}" "$REVIEWED_FILE" 2>/dev/null; then
            continue  # Reviewed on this branch
        elif grep -qxF "$commit_sha" "$REVIEWED_FILE" 2>/dev/null; then
            continue  # Legacy bare SHA format (backwards compat)
        else
            ALL_REVIEWED=false
            break
        fi
    done < <(git -C "$REPO_DIR" log --format='%H' "${BASE_BRANCH}..HEAD" 2>/dev/null)
    if [ "$ALL_REVIEWED" = true ]; then
        # All commits were per-commit reviewed — codex CLI is redundant.
        # But multi-agent deep review (cross-commit analysis) is still valuable.
        # Signal agents-only mode instead of bypassing entirely.
        mkdir -p "$REPO_DIR/.claude"
        echo "agents-only:${CURRENT_BRANCH}" > "$REPO_DIR/.claude/pr-commits-prereviewed.local"
        # Keep REVIEWED_FILE so retries can re-derive agents-only if signal is consumed
        # Fall through to block — require agents-only PR review
    fi
fi

# No valid review marker → block PR creation
# Check if agents-only mode was signaled (all commits pre-reviewed)
AGENTS_ONLY_SIGNAL="$REPO_DIR/.claude/pr-commits-prereviewed.local"
SIGNAL_BRANCH=$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "")
if [ -f "$AGENTS_ONLY_SIGNAL" ] && grep -qxF "agents-only:${SIGNAL_BRANCH}" "$AGENTS_ONLY_SIGNAL" 2>/dev/null; then
REASON="All commits were pre-commit reviewed — codex CLI pass is redundant.
Run agents-only PR review (skip Step 1; continue with Step 1.5 + Step 2):

  1. SKIP the codex CLI pass (Step 1) — already reviewed per-commit
  1.5. Run scope drift detection (Step 1.5, advisory)
  2. Dispatch 6 parallel review agents (Step 2: Guidelines, Bugs, History, Cross-commit, Security, Docs-consistency)
  3. Score and filter findings (confidence >= 80)
  4. If no CRITICAL/HIGH: bash \"\${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts/run-review-loop.sh\" --write-pr-marker
  5. Retry gh pr create

IMPORTANT: Do NOT create the skip file yourself. That is a user-only escape hatch. You MUST run the reviewer instead.
If the user wants to skip: touch $REPO_DIR/.claude/skip-litmus.local"
else
REASON="Code review required before creating a PR.

Follow the PR Review Mode in the litmus SKILL.md:
  1. Run the CLI pass: LITMUS_MODE=pr bash \"\${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts/init-review-loop.sh\" && LITMUS_MODE=pr bash \"\${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts/run-review-loop.sh\"
  2. Dispatch 6 parallel review agents (Guidelines, Bugs, History, Cross-commit, Security, Docs-consistency)
  3. Score and filter findings (confidence >= 80)
  4. If no CRITICAL/HIGH: bash \"\${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts/run-review-loop.sh\" --write-pr-marker
  5. Retry gh pr create

For CLI-only fast review (skips 6-agent deep review):
  bash \"\${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts/run-review-loop.sh\" --auto-pr-review

IMPORTANT: Do NOT create the skip file yourself. That is a user-only escape hatch. You MUST run the reviewer instead.
If the user wants to skip: touch $REPO_DIR/.claude/skip-litmus.local"
fi
block_emit "$REASON"
