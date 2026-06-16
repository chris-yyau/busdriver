#!/usr/bin/env bash
# Tests for the pre-PR gate and the post-PR marker consumer.
#
# Validates the deferred-consumption fix: the PreToolUse gate (pre-pr-gate.sh)
# must VALIDATE the PR review marker without consuming it, and the PostToolUse
# hook (post-pr-consume-marker.sh) must consume it only after `gh pr create`
# actually succeeds. This prevents a gh failure (missing --body-file, network,
# bad --base) from burning a valid 6-agent review of unchanged code.
#
# Cases:
#   1. Gate allows on a valid hash marker AND does NOT consume it (the fix)
#   2. Gate blocks + cleans up a stale (mismatched) hash marker
#   3. Post-hook consumes the marker when output has a PR URL + exit 0 (success)
#   4. Post-hook preserves the marker when output has no PR URL (gh failed)
#   5. Post-hook preserves the marker on a nonzero exit even if a URL is printed
#      (e.g. "a pull request already exists: <url>")
#   6. Post-hook ignores non-PR commands (marker untouched)
#   7. Post-hook is a no-op (no crash) when no marker exists
#
# Determinism: a fresh temp repo has no origin/main, so the gate's
# `git diff origin/main...HEAD` yields an empty diff. The test computes the
# marker the exact same way, guaranteeing a hash match without real review
# state.
#
# Usage: bash tests/test-pre-pr-gate.sh
# Exit: 0 if all pass, 1 if any fail.

set -euo pipefail
cd "$(dirname "$0")/.."

GATE_SCRIPT="$(pwd)/hooks/gate-scripts/pre-pr-gate.sh"
POST_HOOK="$(pwd)/hooks/gate-scripts/post-pr-consume-marker.sh"

PASS=0
FAIL=0
TOTAL=0

# ── Temp repo ─────────────────────────────────────────────────────────
TMPREPO=$(mktemp -d 2>/dev/null || mktemp -d -t prgate)
# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$TMPREPO" 2>/dev/null || true; }
trap cleanup EXIT

git -C "$TMPREPO" init -q
git -C "$TMPREPO" config user.email "test@example.com"
git -C "$TMPREPO" config user.name "Test"
echo "hello" > "$TMPREPO/file.txt"
git -C "$TMPREPO" add file.txt
git -C "$TMPREPO" commit -qm "initial"

MARKER="$TMPREPO/.claude/pr-review-passed.local"
mkdir -p "$TMPREPO/.claude"

# Compute the diff hash the exact way the gate does (empty diff → empty hash).
EMPTY_DIFF=$(git -C "$TMPREPO" diff "origin/main...HEAD" 2>/dev/null || true)
VALID_HASH=$(printf '%s' "$EMPTY_DIFF" | (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1)
STALE_HASH=$(printf '%s' "stale-marker-content" | (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1)

PR_CREATE_CMD="cd $TMPREPO && gh pr create --fill"

# ── Helpers ───────────────────────────────────────────────────────────

# Run the gate and report block|crash|allow. A crash (gate failed to execute:
# missing script, interpreter error before the ERR trap) exits non-zero with
# no output — do NOT mask it as "allow", which would hide a broken gate.
run_gate() {
    local input="$1" output exit_code
    output=$(printf '%s' "$input" | env -u SKIP_LITMUS -u LITMUS_PR_BASE bash "$GATE_SCRIPT" 2>/dev/null) && exit_code=0 || exit_code=$?
    if printf '%s' "$output" | grep -q '"block"'; then
        echo "block"
    elif [ "$exit_code" -ne 0 ] && [ -z "$output" ]; then
        echo "crash"
    else
        echo "allow"
    fi
}

run_post_hook() {
    printf '%s' "$1" | bash "$POST_HOOK" >/dev/null 2>&1 || true
}

check() {
    local name="$1" expected="$2" got="$3"
    TOTAL=$((TOTAL + 1))
    if [[ "$got" == "$expected" ]]; then
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s (expected=%s got=%s)\n" "$name" "$expected" "$got"
        FAIL=$((FAIL + 1))
    fi
}

marker_state() { [[ -f "$MARKER" ]] && echo "present" || echo "absent"; }

# Compose a gate input that includes the PreToolUse `cwd` field (python handles
# JSON escaping of embedded quotes / command substitution safely).
make_input_cwd() {
    python3 -c "
import json, sys
print(json.dumps({'tool_name':'Bash','tool_input':{'command':sys.argv[1]},'cwd':sys.argv[2]}))
" "$1" "$2"
}

# ── 1. Gate allows on valid hash marker AND does not consume ──────────
printf '%s' "$VALID_HASH" > "$MARKER"
GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$PR_CREATE_CMD")
got=$(run_gate "$GATE_INPUT")
check "gate allows on valid hash marker" "allow" "$got"
got=$(marker_state)
check "gate does NOT consume marker on allow (deferred to post-hook)" "present" "$got"

# ── 2. Gate blocks + cleans up stale (mismatched) marker ──────────────
printf '%s' "$STALE_HASH" > "$MARKER"
got=$(run_gate "$GATE_INPUT")
check "gate blocks on stale hash marker" "block" "$got"
got=$(marker_state)
check "gate removes stale marker" "absent" "$got"

# ── 3. Post-hook consumes marker on success (PR URL + exit 0) ─────────
printf '%s' "$VALID_HASH" > "$MARKER"
SUCCESS_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_output":{"output":"https://github.com/owner/repo/pull/42","exit_code":0}}' "$PR_CREATE_CMD")
run_post_hook "$SUCCESS_INPUT"
got=$(marker_state)
check "post-hook consumes marker after successful gh pr create" "absent" "$got"

# ── 3b. Post-hook consumes on clean URL when no exit_code is reported ──
printf '%s' "$VALID_HASH" > "$MARKER"
NOCODE_OK_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_output":{"output":"https://github.com/owner/repo/pull/42"}}' "$PR_CREATE_CMD")
run_post_hook "$NOCODE_OK_INPUT"
got=$(marker_state)
check "post-hook consumes on clean URL with no exit_code (fallback success)" "absent" "$got"

# ── 4. Post-hook preserves marker on failure (no PR URL) ──────────────
printf '%s' "$VALID_HASH" > "$MARKER"
FAIL_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_output":{"output":"could not open body file: no such file or directory","exit_code":1}}' "$PR_CREATE_CMD")
run_post_hook "$FAIL_INPUT"
got=$(marker_state)
check "post-hook preserves marker when gh pr create fails" "present" "$got"

# ── 4b. Post-hook preserves on 'already exists' diagnostic w/o exit_code ─
printf '%s' "$VALID_HASH" > "$MARKER"
EXISTS_NOCODE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_output":{"output":"a pull request for branch already exists:\\nhttps://github.com/owner/repo/pull/7"}}' "$PR_CREATE_CMD")
run_post_hook "$EXISTS_NOCODE_INPUT"
got=$(marker_state)
check "post-hook preserves on 'already exists' URL with no exit_code" "present" "$got"

# ── 4c. Post-hook preserves on masked exit code (gh ... || true) ──────
# A compound command exits 0 even when gh failed; the 'already exists'
# failure signature must still block consumption despite exit_code == 0.
printf '%s' "$VALID_HASH" > "$MARKER"
MASKED_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s || true"},"tool_output":{"output":"a pull request for branch already exists:\\nhttps://github.com/owner/repo/pull/7","exit_code":0}}' "$PR_CREATE_CMD")
run_post_hook "$MASKED_INPUT"
got=$(marker_state)
check "post-hook preserves on masked exit code (failure sig wins over exit 0)" "present" "$got"

# ── 4d. Post-hook consumes on GHES / custom-host success URL ──────────
printf '%s' "$VALID_HASH" > "$MARKER"
GHES_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_output":{"output":"https://github.example.com/owner/repo/pull/42","exit_code":0}}' "$PR_CREATE_CMD")
run_post_hook "$GHES_INPUT"
got=$(marker_state)
check "post-hook consumes on GHES/custom-host PR URL" "absent" "$got"

# ── 5. Post-hook preserves marker on nonzero exit despite a printed URL ─
printf '%s' "$VALID_HASH" > "$MARKER"
EXISTING_PR_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_output":{"output":"a pull request for branch already exists: https://github.com/owner/repo/pull/7","exit_code":1}}' "$PR_CREATE_CMD")
run_post_hook "$EXISTING_PR_INPUT"
got=$(marker_state)
check "post-hook preserves marker on nonzero exit even with a URL" "present" "$got"

# ── 6. Post-hook ignores non-PR commands ──────────────────────────────
printf '%s' "$VALID_HASH" > "$MARKER"
NONPR_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"cd %s && git status"},"tool_output":{"output":"https://github.com/owner/repo/pull/42","exit_code":0}}' "$TMPREPO")
run_post_hook "$NONPR_INPUT"
got=$(marker_state)
check "post-hook ignores non-PR command" "present" "$got"

# ── 7. Post-hook is a no-op when no marker exists ─────────────────────
rm -f "$MARKER"
run_post_hook "$SUCCESS_INPUT"
got=$(marker_state)
check "post-hook no-op when marker absent (no crash, none created)" "absent" "$got"

# ── 8. cwd-anchored resolution + substitution handling ───────────────
# Regression: a `cd "$(...)"` prefix used to produce a junk REPO_DIR that
# tripped `... || exit 0`, silently ALLOWING gh pr create with no review.
rm -f "$MARKER"
got=$(run_gate "$(make_input_cwd 'cd "$(git rev-parse --show-toplevel)" && gh pr create --fill' "$TMPREPO")")
check "gate blocks substitution-cd create with absent marker (was fail-open)" "block" "$got"

# Unresolvable command substitution target → fail-CLOSED block.
got=$(run_gate "$(make_input_cwd 'cd "$(echo /tmp)" && gh pr create --fill' "$TMPREPO")")
check "gate blocks unresolvable cd substitution target" "block" "$got"

# Bare $VAR expansion is unresolvable too — cd $PWD is a no-op landing in the
# live repo, so it must not slip through as "literal" and approve unreviewed.
got=$(run_gate "$(make_input_cwd 'cd $PWD && gh pr create --fill' "$TMPREPO")")
check "gate blocks bare-var cd (\$PWD) create, no marker (was fail-open)" "block" "$got"

# cwd is consulted: no cd prefix + valid marker in the cwd repo → allow
# (before the fix this resolved to the test runner's CWD and blocked).
printf '%s' "$VALID_HASH" > "$MARKER"
got=$(run_gate "$(make_input_cwd 'gh pr create --fill' "$TMPREPO")")
check "gate allows when cwd anchors to repo with valid marker (cwd consulted)" "allow" "$got"
rm -f "$MARKER"

# ── Summary ───────────────────────────────────────────────────────────
echo ""
echo "  ── $PASS/$TOTAL passed ──"
[[ "$FAIL" -eq 0 ]] || { echo "  $FAIL test(s) failed"; exit 1; }
exit 0
