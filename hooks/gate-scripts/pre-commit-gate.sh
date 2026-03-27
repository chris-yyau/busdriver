#!/usr/bin/env bash
# PreToolUse hook: gate git commit on review requirements
#
# Two mandatory gates before any git commit:
#   Gate 1: Design review — blocks if design docs written but not reviewed
#   Gate 2: Codex review  — blocks if no review-passed marker for current staged changes
#
# Fail-CLOSED: errors block commits (user preference: stuck > skipped review)
# Skip: .claude/skip-codex-review.local or SKIP_CODEX_REVIEW=1

set -euo pipefail
# Fail-CLOSED: errors block commits rather than silently approving.
# User preference: "a stuck session is better than a skipped review."
# Escape hatch: .claude/skip-codex-review.local or SKIP_CODEX_REVIEW=1
trap 'printf "{\"decision\":\"block\",\"reason\":\"Pre-commit gate error — blocking as precaution. If stuck, create .claude/skip-codex-review.local in your terminal.\"}\n"; exit 0' ERR

# ── Block emission helper (F6 fix) ────────────────────────────────────
# Uses jq when available, falls back to printf when jq is missing.
# Ensures block decisions are always emitted regardless of jq availability.
block_emit() {
    if command -v jq &>/dev/null; then
        jq -n --arg r "$1" '{decision:"block", reason:$r}'
    else
        local escaped
        escaped=$(printf '%s' "$1" | sed 's/"/\\"/g' | head -c 2000)
        printf '{"decision":"block","reason":"%s"}\n' "$escaped"
    fi
}

# ── python3 pre-check (F5 fix) ────────────────────────────────────────
# python3 is REQUIRED for git commit detection and all gate logic.
# If missing, block — fail-closed principle. The || true on the python3
# call below would otherwise silently allow ALL commits.
if ! command -v python3 &>/dev/null; then
    block_emit "CRITICAL: python3 not found. All review gates require python3 for JSON parsing and command detection. Install python3 to restore gate enforcement. Escape hatch: .claude/skip-codex-review.local"
    exit 0
fi

# Consume stdin
HOOK_DATA=$(cat 2>/dev/null || true)
[ -z "$HOOK_DATA" ] && exit 0

# Fast pre-filter: skip if hook data doesn't look like it could contain a git commit.
# NOTE: We require "Bash" tool_name to avoid false positives when prompt text piped
# to other tools (gemini, codex) contains "git commit" as prose.
# Uses *git*commit* (not *git commit*) to also match `git -C <dir> commit`.
# The Python parser handles precision — this pre-filter just rejects obvious non-matches.
case "$HOOK_DATA" in
    *\"Bash\"*git*commit*) ;;
    *git*commit*\"Bash\"*) ;;
    *) exit 0 ;;
esac

# Parse tool name and command, verify git commit, and extract target directory
# from `cd <dir> &&` prefix or `git -C <dir>` flag.
# Fix: marker written by codex-reviewer in target repo was invisible to gate
# when committing to repos outside the session CWD (worktrees, temp clones).
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
        # Track cd commands to determine target repo directory
        cd_m = re.match(r'cd\s+(.*)', seg)
        if cd_m:
            target_dir = cd_m.group(1).strip().strip('\042\047')
            continue
        # Strip leading env var assignments (e.g. SKIP=1 git commit)
        while re.match(r'^\w+=\S*\s', seg):
            seg = re.sub(r'^\w+=\S*\s+', '', seg, count=1)
        if re.match(r'git\b', seg):
            # Find subcommand by skipping flags (-C val, --no-pager, etc.)
            words = seg.split()
            skip_next = False
            found = False
            for w in words[1:]:
                if skip_next:
                    skip_next = False
                    continue
                if w in ('-C', '-c'):
                    skip_next = True
                    continue
                if w.startswith('-'):
                    continue
                found = (w == 'commit')
                break
            if found:
                c_m = re.search(r'-C\s+(\S+)', seg)
                if c_m:
                    target_dir = c_m.group(1).strip('\042\047')
                print('yes')
                print(target_dir)
                break
except Exception:
    # Fail-CLOSED: fast pre-filter matched git commit pattern but parser
    # failed. Print sentinel so bash can block rather than silently approve.
    print('error')
    print('')
" 2>/dev/null || true)

IS_GIT_COMMIT=$(echo "$PARSE_RESULT" | head -1)
TARGET_DIR=$(echo "$PARSE_RESULT" | sed -n '2p')

# Fail-closed: parser error after fast pre-filter matched → block as precaution
if [ "$IS_GIT_COMMIT" = "error" ]; then
    block_emit "Pre-commit gate: failed to parse tool input for command matching git commit pattern. Blocking as precaution (fail-closed). If stuck, create .claude/skip-codex-review.local in your terminal."
    exit 0
fi

[ "$IS_GIT_COMMIT" != "yes" ] && exit 0

# Resolve to git repo root (TARGET_DIR may be a subdirectory, not the root)
REPO_DIR=$(git -C "${TARGET_DIR:-.}" rev-parse --show-toplevel 2>/dev/null || echo "${TARGET_DIR:-.}")

# Not in a git repo → approve
git -C "$REPO_DIR" rev-parse --is-inside-work-tree &>/dev/null || exit 0

# ── ~/.claude repo: scoped auto-generated file bypass ──────────────────────
# Skip review gates ONLY when ALL staged files are auto-generated artifacts.
# Hooks and skills that affect all projects still require review.
REPO_ROOT=$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")
if [ "$REPO_ROOT" = "$HOME/.claude" ]; then
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
    while IFS= read -r staged_file; do
        [ -z "$staged_file" ] && continue
        HAS_FILES=true
        is_auto=false
        for pattern in "${AUTO_GEN_PATHS[@]}"; do
            case "$pattern" in
                */) case "$staged_file" in ${pattern}*) is_auto=true; break ;; esac ;;
                *)  [ "$staged_file" = "$pattern" ] && is_auto=true && break ;;
            esac
        done
        if [ "$is_auto" = false ]; then
            ALL_AUTO=false
            break
        fi
    done < <(git -C "$REPO_DIR" diff --cached --name-only 2>/dev/null)
    if [ "$HAS_FILES" = true ] && [ "$ALL_AUTO" = true ]; then
        exit 0  # All staged files are auto-generated → skip review
    fi
    # Otherwise fall through to normal review gates
fi

# ── ACCEPTED RISK: TOCTOU gap for chained `git add && git commit` ─────
# When Claude chains `git add && git commit` in one Bash call, PreToolUse
# runs BEFORE `git add` executes, so `git diff --cached` is empty.
#
# Impact: We cannot verify that the reviewed changes match the staged changes.
# Hash verification was removed because of this — marker existence is the sole check.
#
# Mitigations:
#   1. Marker consumed after successful commit via PostToolUse hook, preventing reuse
#   2. Pre-implementation gate blocks file writes during design review
#   3. DEGRADED markers are rejected (fail-closed when codex CLI missing)
#   4. CI/branch protection provides secondary enforcement
#
# Residual risk: MODERATE — if review passes on clean code, then malicious code
# is added in the same chained command, the gate accepts it. Mitigated by (1).
#
# Recommendation to Claude: Prefer separate `git add` and `git commit` calls
# over chaining them. This allows the hook to see actual staged changes.
#
# Audit trail: H4 finding, Sprint 1 (2026-03-19). Council rated HIGH (accepted).
# ─────────────────────────────────────────────────────────────────────────

# Skip overrides
if [ -f ".claude/skip-codex-review.local" ]; then
    # Reject skip files created within the last 30 seconds — likely Claude self-bypass.
    # A human-created skip file (via terminal) will typically be older.
    FILE_AGE=999
    if stat -f %m ".claude/skip-codex-review.local" &>/dev/null; then
        FILE_AGE=$(( $(date +%s) - $(stat -f %m ".claude/skip-codex-review.local") ))
    elif stat -c %Y ".claude/skip-codex-review.local" &>/dev/null; then
        FILE_AGE=$(( $(date +%s) - $(stat -c %Y ".claude/skip-codex-review.local") ))
    fi
    if [ "$FILE_AGE" -lt 30 ]; then
        # Likely self-bypass — reject and warn
        rm -f ".claude/skip-codex-review.local"
        REASON="BLOCKED: skip-codex-review.local was created moments ago (likely self-bypass).

Do NOT create .claude/skip-codex-review.local yourself. Run /codex-reviewer instead.
If the user wants to skip, they should create the file manually in their terminal."
        block_emit "$REASON"
        exit 0
    fi
    # Single-use: consume the skip file after allowing one commit.
    # This prevents stale skip files from permanently disabling review gates.
    rm -f ".claude/skip-codex-review.local"
    rm -f ".claude/.gate-block-count.local" 2>/dev/null || true  # Reset circuit breaker
    # ── Bypass telemetry ──────────────────────────────────────────────
    # Log skip-file consumption so there's an auditable record of bypasses.
    mkdir -p .claude
    printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-commit"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> ".claude/bypass-log.jsonl" 2>/dev/null || true
    exit 0
fi
[ "${SKIP_CODEX_REVIEW:-0}" = "1" ] && exit 0

# ── Gate 1: Design review ────────────────────────────────────────────────
DESIGN_STATE=".claude/design-review-needed.local.md"
if [ -f "$DESIGN_STATE" ]; then
    UNREVIEWED=""
    DESIGN_LINES=$(grep '^\- ' "$DESIGN_STATE" 2>/dev/null || true)
    while IFS= read -r line; do
        file="${line#- }"
        [ -z "$file" ] && continue
        if [ -f "$file" ] && ! grep -q "<!-- design-reviewed: PASS -->" "$file" 2>/dev/null; then
            UNREVIEWED="${UNREVIEWED}  - ${file}\n"
        fi
    done <<< "$DESIGN_LINES"

    if [ -n "$UNREVIEWED" ]; then
        REASON=$(printf "Design review required before committing.\n\nUnreviewed documents:\n%b\nRun /design-reviewer to review these documents, then try committing again.\n\nIMPORTANT: Do NOT create .claude/skip-design-review.local yourself. That is a user-only escape hatch. You MUST run the design reviewer instead." "$UNREVIEWED")
        block_emit "$REASON"
        exit 0
    else
        # All files have the review marker → clean up state
        rm -f "$DESIGN_STATE"
    fi
fi

# ── Merge commit auto-pass ─────────────────────────────────────────────
# During a merge resolution, all files are already staged as part of the
# merge state. If the merge introduces no changes relative to HEAD (e.g.,
# conflicts resolved by keeping our already-reviewed code), there's nothing
# new to review. Skip the codex review gate — the code was already reviewed
# when committed to our branch.
# If the merge DOES introduce changes (auto-merged from the other branch),
# fall through to require normal review.
if git -C "$REPO_DIR" rev-parse MERGE_HEAD &>/dev/null; then
    if git -C "$REPO_DIR" diff --cached --quiet HEAD 2>/dev/null; then
        exit 0  # Merge with no net changes vs HEAD → nothing to review
    fi
    # Merge with changes → fall through to require review
fi

# ── Design-reviewed bypass: skip codex gate for spec-only commits ────────
# When ALL staged files are design-reviewed specs (plans/specs .md with PASS
# marker), codex review is redundant — the 3-tier design reviewer (Gemini +
# Codex + Claude) already covered them. Skip Gate 2 to avoid wrong ordering
# where codex-reviewer runs on specs before design-reviewer.
ALL_DESIGN_REVIEWED=true
HAS_STAGED=false
while IFS= read -r staged_file; do
    [ -z "$staged_file" ] && continue
    HAS_STAGED=true
    FULL_PATH="$REPO_DIR/$staged_file"
    # Check if file is a design/spec doc with PASS marker
    IS_REVIEWED_SPEC=false
    if echo "$staged_file" | grep -qE '\.md$'; then
        # Match design doc patterns: basename starts with PLAN/DESIGN/ARCHITECTURE,
        # or file is in a plans/ or specs/ directory under .claude/ or docs/
        if echo "$staged_file" | grep -qiE '(^|/)(PLAN|DESIGN|ARCHITECTURE)[^/]*\.md$' || \
           echo "$staged_file" | grep -qE '(\.claude|docs)/([^/]+/)*(plans|specs)/.*\.md$'; then
            if [ -f "$FULL_PATH" ] && grep -q "<!-- design-reviewed: PASS -->" "$FULL_PATH" 2>/dev/null; then
                IS_REVIEWED_SPEC=true
            fi
        fi
    fi
    if [ "$IS_REVIEWED_SPEC" = false ]; then
        ALL_DESIGN_REVIEWED=false
        break
    fi
done < <(git -C "$REPO_DIR" diff --cached --name-only 2>/dev/null)

if [ "$HAS_STAGED" = true ] && [ "$ALL_DESIGN_REVIEWED" = true ]; then
    exit 0  # All staged files are design-reviewed specs → codex review redundant
fi

# ── Gate 2: Codex review ─────────────────────────────────────────────────
MARKER="$REPO_DIR/.claude/codex-review-passed.local"
if [ -f "$MARKER" ]; then
    # Marker exists — verify it represents an actual review, not degraded mode.
    # DEGRADED markers (written when codex CLI is missing) must NOT pass the gate.
    # This prevents silent bypass of code review when codex is unavailable.
    MARKER_CONTENT=$(cat "$MARKER" 2>/dev/null || echo "")
    if echo "$MARKER_CONTENT" | grep -q "^DEGRADED"; then
        rm -f "$MARKER"
        echo '{"decision":"block","reason":"Code review ran in DEGRADED mode (no review CLI installed). No actual code review was performed. Install a review CLI or create .claude/skip-codex-review.local to bypass."}' >&2
        # Do NOT exit 0 — fall through to blocking logic below
    elif echo "$MARKER_CONTENT" | grep -q "^SKIPPED-NONE"; then
        # BUSDRIVER_REVIEW_CLI=none — user explicitly opted out of review.
        # Accept unconditionally. See design spec §4 for risk analysis.
        exit 0
    elif echo "$MARKER_CONTENT" | grep -q "^BUILTIN-"; then
        # Built-in agent review — accept for commit gate.
        # Post-commit hook excludes from reviewed-commits.local (requires PR deep review).
        exit 0
    else
        # Genuine external review pass — approve but DO NOT consume the marker.
        # Consumption is deferred to PostToolUse (post-commit-consume-marker.sh)
        # which verifies the commit actually succeeded before deleting.
        #
        # Why: PreToolUse runs BEFORE git commit executes. If consumed here
        # and the commit subsequently fails (git hooks, conflicts, errors),
        # the marker is lost — forcing a full re-review for unchanged code.
        exit 0
    fi
fi

# Circuit breaker: detect repeated blocking that may indicate a stuck gate.
# If blocked >10 times in this session, warn user about manual escape hatch.
BLOCK_COUNTER=".claude/.gate-block-count.local"
BLOCK_COUNT=0
if [ -f "$BLOCK_COUNTER" ]; then
    BLOCK_COUNT=$(cat "$BLOCK_COUNTER" 2>/dev/null || echo "0")
fi
BLOCK_COUNT=$((BLOCK_COUNT + 1))
echo "$BLOCK_COUNT" > "$BLOCK_COUNTER" 2>/dev/null || true

ESCAPE_HINT=""
if [ "$BLOCK_COUNT" -ge 10 ]; then
    ESCAPE_HINT="

WARNING: This gate has blocked $BLOCK_COUNT consecutive commits this session.
If you believe the gate is stuck, the user can create .claude/skip-codex-review.local in their terminal to bypass."
fi

# No valid review marker → block commit
REASON="Code review required before committing.

Run /codex-reviewer to review your staged changes. The review must pass before git commit is allowed.

IMPORTANT: Do NOT create .claude/skip-codex-review.local yourself. That is a user-only escape hatch. You MUST run the codex reviewer instead.${ESCAPE_HINT}"
block_emit "$REASON"
