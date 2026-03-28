#!/usr/bin/env bash
# PreToolUse hook: gate `gh pr create` on codex review of full base..HEAD diff
#
# Blocks PR creation until codex reviewer passes on the aggregate branch diff.
# This catches code that escaped per-commit review (worktree commits, existing
# branches, pre-existing commits from other sessions).
#
# Fail-CLOSED: errors block PR creation (user preference: stuck > skipped review)
# Skip: .claude/skip-codex-review.local or SKIP_CODEX_REVIEW=1 (same as commit gate)
#
# Council decision (2026-03-21): Gate `gh pr create` only, NOT `git push`.
# Gating push kills WIP pushes and destroys credibility of the gate system.

set -euo pipefail
trap 'printf "{\"decision\":\"block\",\"reason\":\"Pre-PR gate error — blocking as precaution. If stuck, create .claude/skip-codex-review.local in your terminal.\"}\n"; exit 0' ERR

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
import sys, json, re
try:
    d = json.load(sys.stdin)
    tool = d.get('tool_name', d.get('toolName', ''))
    if tool != 'Bash':
        sys.exit(0)
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
            target_dir = cd_m.group(1).strip().strip('\042\047')
            continue
        while re.match(r'^\w+=\S*\s', seg):
            seg = re.sub(r'^\w+=\S*\s+', '', seg, count=1)
        if re.match(r'gh\s+pr\s+create\b', seg):
            print('yes')
            print(target_dir)
            break
except Exception:
    # Fail-CLOSED: fast pre-filter matched gh pr create but parser failed.
    print('error')
    print('')
" 2>/dev/null || true)

IS_GH_PR_CREATE=$(echo "$PARSE_RESULT" | head -1)
TARGET_DIR=$(echo "$PARSE_RESULT" | sed -n '2p')

# Fail-closed: parser error after fast pre-filter matched → block as precaution
if [ "$IS_GH_PR_CREATE" = "error" ]; then
    block_emit "Pre-PR gate: failed to parse tool input for command matching gh pr create pattern. Blocking as precaution (fail-closed). If stuck, create .claude/skip-codex-review.local in your terminal."
    exit 0
fi

[ "$IS_GH_PR_CREATE" != "yes" ] && exit 0

# Resolve to git repo root (TARGET_DIR may be a subdirectory, not the root)
REPO_DIR=$(git -C "${TARGET_DIR:-.}" rev-parse --show-toplevel 2>/dev/null || echo "${TARGET_DIR:-.}")

# Not in a git repo → approve
git -C "$REPO_DIR" rev-parse --is-inside-work-tree &>/dev/null || exit 0

# ── Skip overrides (shared with commit gate) ──────────────────────────
if [ -f ".claude/skip-codex-review.local" ]; then
    FILE_AGE=999
    if stat -f %m ".claude/skip-codex-review.local" &>/dev/null; then
        FILE_AGE=$(( $(date +%s) - $(stat -f %m ".claude/skip-codex-review.local") ))
    elif stat -c %Y ".claude/skip-codex-review.local" &>/dev/null; then
        FILE_AGE=$(( $(date +%s) - $(stat -c %Y ".claude/skip-codex-review.local") ))
    fi
    if [ "$FILE_AGE" -lt 30 ]; then
        rm -f ".claude/skip-codex-review.local"
        block_emit "BLOCKED: skip-codex-review.local was created moments ago (likely self-bypass). Run /codex-reviewer instead."
        exit 0
    fi
    rm -f ".claude/skip-codex-review.local"
    mkdir -p .claude
    printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-pr"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> ".claude/bypass-log.jsonl" 2>/dev/null || true
    exit 0
fi
[ "${SKIP_CODEX_REVIEW:-0}" = "1" ] && exit 0

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
# Uses the SAME marker as the commit gate (.claude/codex-review-passed.local).
# The PR gate does NOT consume the marker — the commit gate handles that.
# This allows: review → commit (consumes marker) → push → PR create.
#
# For the PR gate to pass, one of these must be true:
#   1. A review marker exists (review done but not yet committed — unusual but valid)
#   2. A PR-review marker exists (.claude/pr-review-passed.local) — set by running
#      codex-reviewer specifically for the PR diff
MARKER="$REPO_DIR/.claude/codex-review-passed.local"
PR_MARKER="$REPO_DIR/.claude/pr-review-passed.local"

if [ -f "$PR_MARKER" ]; then
    PR_MARKER_CONTENT=$(cat "$PR_MARKER" 2>/dev/null || echo "")
    if echo "$PR_MARKER_CONTENT" | grep -qE '^(DEGRADED|SKIPPED-NONE|BUILTIN-)'; then
        rm -f "$PR_MARKER"
    else
        # Genuine PR review pass — consume and allow
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
REVIEWED_FILE="$REPO_DIR/.claude/reviewed-commits.local"
if [ -f "$REVIEWED_FILE" ]; then
    BASE_BRANCH=$(git -C "$REPO_DIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main")
    ALL_REVIEWED=true
    while IFS= read -r commit_sha; do
        [ -z "$commit_sha" ] && continue
        if ! grep -qF "$commit_sha" "$REVIEWED_FILE" 2>/dev/null; then
            ALL_REVIEWED=false
            break
        fi
    done < <(git -C "$REPO_DIR" log --format='%H' "${BASE_BRANCH}..HEAD" 2>/dev/null)
    if [ "$ALL_REVIEWED" = true ]; then
        # All commits were per-commit reviewed — allow PR without re-review
        # Clean up the tracking file since PR is being created
        rm -f "$REVIEWED_FILE"
        exit 0
    fi
fi

# No valid review marker → block PR creation
REASON="Code review required before creating a PR.

Run /codex-reviewer to review the full branch diff (base..HEAD). The review must pass before \`gh pr create\` is allowed.

This gate ensures aggregate changes are reviewed before PR creation — individual commit reviews may have missed cross-commit issues, and worktree/external commits may have bypassed the per-commit gate entirely.

IMPORTANT: Do NOT create .claude/skip-codex-review.local yourself. That is a user-only escape hatch. You MUST run the codex reviewer instead."
block_emit "$REASON"
