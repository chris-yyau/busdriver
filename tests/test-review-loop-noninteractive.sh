#!/usr/bin/env bash
# Tests for design review loop non-interactive stdin detection.
#
# Validates that the non-interactive detection code is present and
# structurally correct in run-design-review-loop.sh. These are static
# checks — they verify the code exists, not that it runs end-to-end
# (the full loop requires Agy/Codex CLIs and state files).
#
# Usage: bash tests/test-review-loop-noninteractive.sh
# Exit: 0 if all pass, 1 if any fail.

set -euo pipefail
cd "$(dirname "$0")/.."

PASS=0
FAIL=0
TOTAL=0

REVIEW_SCRIPT="skills/blueprint-review/scripts/run-design-review-loop.sh"

# ── Helpers ───────────────────────────────────────────────────────────

# We can't easily run the full review loop (needs Agy/Codex CLIs, etc.)
# Instead, test the non-interactive detection logic in isolation.

echo "── review-loop non-interactive detection ────────────────────"

# Test 1: Piped stdin is correctly detected as non-interactive
TOTAL=$((TOTAL + 1))
RESULT=$(echo "" | bash -c '[[ ! -t 0 ]] && echo "non-interactive" || echo "interactive"')
if [[ "$RESULT" == "non-interactive" ]]; then
    printf "  PASS  piped stdin detected as non-interactive\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  piped stdin not detected (got: %s)\n" "$RESULT"
    FAIL=$((FAIL + 1))
fi

# Test 2: Terminal stdin is correctly detected as interactive.
# `script` allocates a PTY, but its CLI differs by platform: BSD/macOS is
# `script -q <file> <cmd> <args>`, while util-linux (Linux/CI) is
# `script -q -c "<cmd>" <file>`. Using the BSD form on util-linux makes it read
# `bash` as the typescript FILE, so no PTY is created and detection returns empty
# (a CI-only FAIL). Detect the variant and use the matching syntax. The probe is
# POSIX (`test -t 0`) so it runs under either script's default shell.
TOTAL=$((TOTAL + 1))
_pty_probe='test -t 0 && echo interactive || echo non-interactive'
if script --version 2>/dev/null | grep -qi util-linux; then
    RESULT=$(script -q -c "$_pty_probe" /dev/null </dev/null 2>/dev/null | tr -d '\r' | grep -o 'interactive\|non-interactive' | head -1)
else
    RESULT=$(script -q /dev/null sh -c "$_pty_probe" </dev/null 2>/dev/null | tr -d '\r' | grep -o 'interactive\|non-interactive' | head -1)
fi
if [[ "$RESULT" == "interactive" ]]; then
    printf "  PASS  terminal stdin detected as interactive\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  terminal stdin detection (got: '%s')\n" "$RESULT"
    FAIL=$((FAIL + 1))
fi

# Test 3: The actual non-interactive code block exists in the script
TOTAL=$((TOTAL + 1))
if grep -q '! -t 0' "$REVIEW_SCRIPT"; then
    printf "  PASS  non-interactive detection present in review loop\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  non-interactive detection missing from review loop\n"
    FAIL=$((FAIL + 1))
fi

# Test 4: Exit code 2 is used for agent-recoverable exit
TOTAL=$((TOTAL + 1))
if grep -q 'exit 2' "$REVIEW_SCRIPT"; then
    printf "  PASS  exit code 2 used for agent-recoverable state\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  exit code 2 not found in review loop\n"
    FAIL=$((FAIL + 1))
fi

# Test 5: --claude-only instruction is given on non-interactive exit
TOTAL=$((TOTAL + 1))
if grep -A2 'exit 2' "$REVIEW_SCRIPT" | grep -q 'claude-only'; then
    printf "  PASS  --claude-only recovery instruction present\n"
    PASS=$((PASS + 1))
else
    # Check within the broader non-interactive block
    if grep -B5 'exit 2' "$REVIEW_SCRIPT" | grep -q 'claude-only'; then
        printf "  PASS  --claude-only recovery instruction present\n"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  --claude-only recovery instruction missing near exit 2\n"
        FAIL=$((FAIL + 1))
    fi
fi

# Test 6: Non-interactive path accepts existing claude.json
TOTAL=$((TOTAL + 1))
if grep -A3 '! -t 0' "$REVIEW_SCRIPT" | grep -q 'CLAUDE_OUTPUT_FILE\|claude.json\|existing Claude'; then
    printf "  PASS  non-interactive path checks for existing claude.json\n"
    PASS=$((PASS + 1))
else
    # Broader search in the non-interactive block
    NON_INT_BLOCK=$(sed -n '/! -t 0/,/^  fi/p' "$REVIEW_SCRIPT")
    if echo "$NON_INT_BLOCK" | grep -q 'CLAUDE_OUTPUT_FILE'; then
        printf "  PASS  non-interactive path checks for existing claude.json\n"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  non-interactive path doesn't check for existing claude.json\n"
        FAIL=$((FAIL + 1))
    fi
fi

# ═══════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "── Results: $PASS/$TOTAL passed ────────────────────────────"
if [[ "$FAIL" -gt 0 ]]; then
    echo "   $FAIL FAILED"
    exit 1
fi
echo "   All passed."
exit 0
