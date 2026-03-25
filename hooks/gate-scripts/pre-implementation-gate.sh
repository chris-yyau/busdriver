#!/usr/bin/env bash
# PreToolUse hook: block implementation code when design docs are unreviewed
#
# When a design/plan doc is written, check-design-document.sh flags it in
# .claude/design-review-needed.local.md. This hook blocks Write/Edit of
# implementation files AND file-modifying Bash commands until design review
# completes.
#
# Without this hook, Claude writes the plan, ignores the "run /design-reviewer"
# warning, and starts writing implementation code — the design review gate only
# fires at commit time, which is too late.
#
# Fail-CLOSED: errors block writes (user preference: stuck > skipped review)
# Skip: .claude/skip-design-review.local

set -euo pipefail
# Fail-CLOSED: errors block implementation writes rather than silently approving.
# User preference: "a stuck session is better than a skipped review."
# Escape hatch: .claude/skip-design-review.local
trap 'printf "{\"decision\":\"block\",\"reason\":\"Pre-implementation gate error — blocking as precaution. If stuck, create .claude/skip-design-review.local in your terminal.\"}\n"; exit 0' ERR

# ── Block emission helper (F6 fix) ────────────────────────────────────
# Uses jq when available, falls back to printf when jq is missing.
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
# python3 is REQUIRED for tool type parsing and command detection.
# If missing, block — fail-closed principle. Without python3, the PARSED
# variable defaults to "SAFE|" which silently allows ALL writes.
if ! command -v python3 &>/dev/null; then
    # Only block if there are pending design reviews (avoid false blocks when no reviews needed)
    if [ -f ".claude/design-review-needed.local.md" ]; then
        block_emit "CRITICAL: python3 not found. Pre-implementation gate cannot parse tool inputs. Install python3 to restore enforcement. Escape hatch: .claude/skip-design-review.local"
        exit 0
    fi
fi

# No pending design reviews → approve immediately
DESIGN_STATE=".claude/design-review-needed.local.md"
[ ! -f "$DESIGN_STATE" ] && exit 0

# ── F10 staleness auto-expiry REMOVED (F11) ───────────────────────────
# Design review state now persists across sessions unconditionally.
# Previously, state older than DESIGN_REVIEW_STALE_HOURS was auto-expired
# here, creating a session-boundary gap where reviews silently disappeared.
# SessionStart (load-orchestrator.sh) still warns about stale state for UX.
# Escape hatch: .claude/skip-design-review.local (user-created only).

# Skip overrides — unified with pre-commit-gate.sh behavior
# Both gates use the same pattern: single-use consumption + self-bypass detection
if [ -f ".claude/skip-design-review.local" ]; then
    # Reject skip files created within the last 30 seconds — likely Claude self-bypass.
    # A human-created skip file (via terminal) will typically be older.
    FILE_AGE=999
    if stat -f %m ".claude/skip-design-review.local" &>/dev/null; then
        FILE_AGE=$(( $(date +%s) - $(stat -f %m ".claude/skip-design-review.local") ))
    elif stat -c %Y ".claude/skip-design-review.local" &>/dev/null; then
        FILE_AGE=$(( $(date +%s) - $(stat -c %Y ".claude/skip-design-review.local") ))
    fi
    if [ "$FILE_AGE" -lt 30 ]; then
        # Likely self-bypass — reject and warn
        rm -f ".claude/skip-design-review.local"
        REASON="BLOCKED: skip-design-review.local was created moments ago (likely self-bypass).

Do NOT create .claude/skip-design-review.local yourself. Run /design-reviewer instead.
If the user wants to skip, they should create the file manually in their terminal."
        block_emit "$REASON"
        exit 0
    fi
    # Single-use: consume the skip file after allowing one bypass.
    # This prevents stale skip files from permanently disabling review gates.
    rm -f ".claude/skip-design-review.local"
    rm -f ".claude/.impl-gate-block-count.local" 2>/dev/null || true
    # ── Bypass telemetry ──────────────────────────────────────────────
    mkdir -p .claude
    printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-implementation"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> ".claude/bypass-log.jsonl" 2>/dev/null || true
    exit 0
fi
[ "${SKIP_DESIGN_REVIEW:-0}" = "1" ] && exit 0

# Consume stdin
INPUT=$(cat 2>/dev/null || true)
[ -z "$INPUT" ] && exit 0

# ── Parse tool type and relevant input ─────────────────────────────────
# Returns: WRITE_EDIT|<file_path>  or  BASH_MOD|<command>  or  SAFE|
# NOTE: Python block uses single-quoted shell string to avoid bash 3.2
# quote-matching issues with $(...)  — all Python strings use double quotes.
# F7 fix: Strip fd-to-fd redirects (2>&1, >&2) before file-redirect detection.
# F8 fix: Allow review infrastructure scripts (design-reviewer, codex-reviewer)
# to run even when design docs are unreviewed — prevents circular dependency.
PARSED=$(printf '%s' "$INPUT" | python3 -c '
import sys, json, re
try:
    d = json.load(sys.stdin)
    tool = d.get("tool_name", d.get("toolName", ""))
    inp = d.get("tool_input", d.get("toolInput", {}))
    if isinstance(inp, str):
        inp = json.loads(inp)
    if tool in ("Write", "Edit"):
        print("WRITE_EDIT|" + inp.get("file_path", inp.get("filePath", "")))
    elif tool == "Bash":
        cmd = inp.get("command", "")
        FILE_MOD_PATTERNS = [
            r"\bsed\s+-i",
            r"\btee\s",
            r"\bpatch\s",
            r"\bcp\s",
            r"\bmv\s",
            r"\brm\s",
            r"\bln\s",
            r"\binstall\s",
        ]
        has_explicit_mod = any(re.search(p, cmd) for p in FILE_MOD_PATTERNS)
        is_mod = has_explicit_mod
        # Check for shell redirects (>, >>) not targeting /dev/null.
        # Strip single-quoted strings first (literal text like jq .x > 0).
        if not is_mod:
            no_single = re.sub(r"'\''[^'\'']*'\''", "", cmd)
            safe = re.sub(r"[12]>\s*/dev/null", "", no_single)
            safe = re.sub(r"&>\s*/dev/null", "", safe)
            safe = re.sub(r">\s*/dev/null", "", safe)
            # Strip fd-to-fd redirects: 2>&1, >&2, 1>&2 (not file writes)
            safe = re.sub(r"[012]?>&[012]", "", safe)
            if re.search(r">{1,2}\s*\S", safe):
                is_mod = True
        # Allow review infrastructure scripts when flagged only by redirects
        # (not explicit file-mod patterns like rm/cp/mv). This prevents
        # compound command bypass: "bash reviewer.sh && rm -rf src" still
        # blocked because rm triggers has_explicit_mod.
        if is_mod and not has_explicit_mod and re.search(r"(?:^|[\s;|&])(?:ba)?sh\s+\S*(?:design-reviewer|codex-reviewer)/(?:scripts|config)/", cmd):
            print("SAFE|")
        elif is_mod:
            # F9 fix: Allow rm/mkdir targeting only .claude/ infrastructure.
            # Prevents circular dependency where gate blocks cleanup of its
            # own state files. Conservative: no command chaining allowed,
            # only .claude/ relative paths, only rm and mkdir.
            clean = re.sub(r"\s*(?:2>/dev/null\s*)?(?:\|\|\s*(?:true|:)\s*)?$", "", cmd)
            if re.match(r"^\s*(?:rm|mkdir)\s+(?:-[a-zA-Z]+\s+)*(?:\.claude/\S+\s*)+$", clean):
                print("SAFE|")
            else:
                print("BASH_MOD|" + cmd[:500])
        else:
            print("SAFE|")
    else:
        print("SAFE|")
except Exception:
    print("SAFE|")
' 2>/dev/null || echo "SAFE|")

TOOL_TYPE="${PARSED%%|*}"
TOOL_VALUE="${PARSED#*|}"

# Non-Write/Edit or safe Bash → approve
[ "$TOOL_TYPE" = "SAFE" ] && exit 0

# ── For Write/Edit: apply file-path allowlists ─────────────────────────
if [ "$TOOL_TYPE" = "WRITE_EDIT" ]; then
    FILE_PATH="$TOOL_VALUE"

    # No file path → approve
    [ -z "$FILE_PATH" ] && exit 0

    # Allow writing to these paths (review infrastructure, not implementation):
    #   - Design/plan docs themselves (writing/editing the plan is fine)
    #   - Review output files (design-reviewer generates these)
    #   - .claude/ config files
    #   - docs/reviews/ (review artifacts)
    #   - CLAUDE.md, NOTES.md, *.local* files
    case "$FILE_PATH" in
        *PLAN*.md|*DESIGN*.md|*ARCHITECTURE*.md) exit 0 ;;
        *docs/plans/*) exit 0 ;;
        *docs/reviews/*) exit 0 ;;
        *docs/superpowers/*) exit 0 ;;
        *CLAUDE.md|*NOTES.md) exit 0 ;;
    esac

    # Allow .claude/ config writes EXCEPT security-sensitive gate markers
    # These files control review gate bypass — writing them forges compliance
    case "$FILE_PATH" in
        *.claude/codex-review-passed.local*)
            # BLOCK: writing this file forges a codex review pass
            REASON="BLOCKED: Cannot write .claude/codex-review-passed.local directly.
This file is a gate marker written by the codex-reviewer after a passing review.
Writing it manually forges compliance. Run /codex-reviewer instead."
            block_emit "$REASON"
            exit 0
            ;;
        *.claude/skip-design-review.local*)
            # BLOCK: writing this file bypasses design review gates
            REASON="BLOCKED: Cannot write .claude/skip-design-review.local directly.
This is a user-only escape hatch. Only the human user may create this file in their terminal."
            block_emit "$REASON"
            exit 0
            ;;
        *.claude/skip-codex-review.local*)
            # BLOCK: writing this file bypasses codex review gates
            REASON="BLOCKED: Cannot write .claude/skip-codex-review.local directly.
This is a user-only escape hatch. Only the human user may create this file in their terminal."
            block_emit "$REASON"
            exit 0
            ;;
        *.claude/pr-review-passed.local*)
            # BLOCK: writing this file forges a PR-level codex review pass
            REASON="BLOCKED: Cannot write .claude/pr-review-passed.local directly.
This file is a gate marker written by the codex-reviewer after a passing PR diff review.
Writing it manually forges compliance. Run /codex-reviewer on the PR diff instead."
            block_emit "$REASON"
            exit 0
            ;;
        *.claude/reviewed-commits.local*)
            # BLOCK: writing this file forges per-commit review tracking
            REASON="BLOCKED: Cannot write .claude/reviewed-commits.local directly.
This file tracks which commits passed per-commit codex review. It is written by the
post-commit hook after successful reviewed commits. Writing it manually forges compliance."
            block_emit "$REASON"
            exit 0
            ;;
        *.claude/design-review-needed.local*)
            # BLOCK: writing this file manipulates design review gate state.
            # Only the PostToolUse hook (check-design-document.sh) should modify it.
            REASON="BLOCKED: Cannot write .claude/design-review-needed.local.md directly.
This file tracks which design docs need review. Editing it bypasses the design review gate.
Run /design-reviewer to complete design review instead."
            block_emit "$REASON"
            exit 0
            ;;
        *.claude/*) exit 0 ;;                   # Allow: other .claude config
    esac

    # Allow files with .local suffix ONLY if they match known config patterns
    # (not broad *.local* which catches localStorage-handler.ts etc.)
    case "$FILE_PATH" in
        *.local.md|*.local.json|*.local.yaml|*.local.yml) exit 0 ;;
    esac
fi

# For BASH_MOD: the command was already identified as file-modifying.
# No file-path allowlist needed — Bash command parsing is unreliable for
# extracting target paths, and the patterns (sed -i, tee, patch) are
# unambiguous file-modification operations.

# ── Check if ANY flagged design docs are still unreviewed ──────────────
UNREVIEWED=""
DESIGN_LINES=$(grep '^\- ' "$DESIGN_STATE" 2>/dev/null || true)
while IFS= read -r line; do
    file="${line#- }"
    [ -z "$file" ] && continue
    if [ -f "$file" ] && ! grep -q "<!-- design-reviewed: PASS -->" "$file" 2>/dev/null; then
        UNREVIEWED="${UNREVIEWED}  - ${file}\n"
    fi
done <<< "$DESIGN_LINES"

# All reviewed → clean up and approve
if [ -z "$UNREVIEWED" ]; then
    rm -f "$DESIGN_STATE"
    rm -f ".claude/.impl-gate-block-count.local" 2>/dev/null || true
    exit 0
fi

# ── Circuit breaker: detect repeated blocking ──────────────────────────
# Mirrors pre-commit-gate.sh: warns after 10 blocks so user knows to
# either run /design-reviewer or create skip-design-review.local manually.
BLOCK_COUNTER=".claude/.impl-gate-block-count.local"
BLOCK_COUNT=0
if [ -f "$BLOCK_COUNTER" ]; then
    BLOCK_COUNT=$(cat "$BLOCK_COUNTER" 2>/dev/null || echo "0")
fi
BLOCK_COUNT=$((BLOCK_COUNT + 1))
echo "$BLOCK_COUNT" > "$BLOCK_COUNTER" 2>/dev/null || true

ESCAPE_HINT=""
if [ "$BLOCK_COUNT" -ge 10 ]; then
    ESCAPE_HINT="

WARNING: This gate has blocked $BLOCK_COUNT consecutive implementation attempts this session.
If you believe the gate is stuck, the user can create .claude/skip-design-review.local in their terminal to bypass."
fi

# ── Block: unreviewed design docs exist ────────────────────────────────
if [ "$TOOL_TYPE" = "BASH_MOD" ]; then
    REASON=$(printf "Design review must complete before modifying files via Bash.\n\nDetected file-modifying Bash command while design docs are unreviewed:\n%b\nRun /design-reviewer to review these documents first.\n\nIMPORTANT: Do NOT create .claude/skip-design-review.local yourself. That is a user-only escape hatch. You MUST run the design reviewer instead.%s" "$UNREVIEWED" "$ESCAPE_HINT")
else
    REASON=$(printf "Design review must complete before writing implementation code.\n\nUnreviewed design documents:\n%b\nRun /design-reviewer to review these documents first.\n\nIMPORTANT: Do NOT create .claude/skip-design-review.local yourself. That is a user-only escape hatch. You MUST run the design reviewer instead.%s" "$UNREVIEWED" "$ESCAPE_HINT")
fi
block_emit "$REASON"
