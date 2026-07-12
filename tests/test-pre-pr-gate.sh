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
# Determinism: the temp repo anchors origin/main at the initial commit and adds a
# second commit, so base...HEAD is a real, fixed diff. The test computes the marker
# hash the exact same way the gate does (explicit merge-base, then
# `git diff "${MERGE_BASE}...HEAD"`), guaranteeing a match without real review state.
# (The gate now fails closed on an empty/unresolved diff, so an empty-diff fixture
# would no longer be honored — see test 2c.)
#
# Usage: bash tests/test-pre-pr-gate.sh
# Exit: 0 if all pass, 1 if any fail.

set -euo pipefail
cd "$(dirname "$0")/.."

# Pin the state dir to .claude — this test seeds markers/artifacts under
# "$TMPREPO/.claude". A developer (or opencode mirror) shell may export
# BUSDRIVER_STATE_DIR=.opencode, which would otherwise make the gate look under
# .opencode and spuriously block. The gate's own value is documented to default
# to .claude for Claude Code; pin it so the test is environment-independent.
export BUSDRIVER_STATE_DIR=.claude

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
# Anchor a real base: origin/main = the initial commit, then add a second commit
# so base...HEAD has a NON-EMPTY diff. The gate now fails closed when it cannot
# resolve a real merge-base/diff (the empty-string SHA must never authorize a PR),
# so the fixture must present a genuine diff rather than the old empty-diff shortcut.
git -C "$TMPREPO" update-ref refs/remotes/origin/main HEAD
git -C "$TMPREPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
printf 'hello\nworld\n' > "$TMPREPO/file.txt"
git -C "$TMPREPO" add file.txt
git -C "$TMPREPO" commit -qm "change"

MARKER="$TMPREPO/.claude/pr-review-passed.local"
CODEX_LEAD_ART="$TMPREPO/.claude/pr-codex-lead.local.json"
BACKSTOP_ART="$TMPREPO/.claude/pr-backstop-verdict.local.json"
mkdir -p "$TMPREPO/.claude"

# Compute the diff hash the exact way the gate does: explicit merge-base, then
# `git diff "${MERGE_BASE}...HEAD"` (byte-identical to compute_pr_diff_hash).
MERGE_BASE=$(git -C "$TMPREPO" merge-base origin/main HEAD)
REAL_DIFF=$(git -C "$TMPREPO" diff "${MERGE_BASE}...HEAD" 2>/dev/null || true)
VALID_HASH=$(printf '%s' "$REAL_DIFF" | (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1)
STALE_HASH=$(printf '%s' "stale-marker-content" | (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1)

# Dual-voice PR gate (ADR 0006): a non-fast PR marker is honored only when BOTH
# diff-bound PASS artifacts (Codex lead + Opus backstop) are fresh for the same
# hash. Seed both bound to $1, with ts=now (within the default 3600s window).
seed_artifacts() {
    local h="$1" now
    now=$(date +%s)
    printf '{"status":"PASS","model":"codex","diff_hash":"%s","ts":%s}\n' "$h" "$now" > "$CODEX_LEAD_ART"
    printf '{"status":"PASS","model":"opus","diff_hash":"%s","ts":%s,"issues":[]}\n' "$h" "$now" > "$BACKSTOP_ART"
}
clear_artifacts() { rm -f "$CODEX_LEAD_ART" "$BACKSTOP_ART"; }

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

# Compose a POST-hook input (command + tool_output + cwd) for consume tests.
make_posthook_cwd() {
    # $1=command $2=output $3=cwd
    python3 -c "
import json, sys
print(json.dumps({'tool_name':'Bash','tool_input':{'command':sys.argv[1]},'tool_output':{'output':sys.argv[2],'exit_code':0},'cwd':sys.argv[3]}))
" "$1" "$2" "$3"
}

# ── 1. Gate allows on valid hash marker + both artifacts, and does not consume ──
printf '%s' "$VALID_HASH" > "$MARKER"
seed_artifacts "$VALID_HASH"
GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$PR_CREATE_CMD")
got=$(run_gate "$GATE_INPUT")
check "gate allows on valid hash marker + dual-voice artifacts" "allow" "$got"
got=$(marker_state)
check "gate does NOT consume marker on allow (deferred to post-hook)" "present" "$got"

# ── 1b. Gate blocks when the backstop artifact is missing (lead alone) ─────────
rm -f "$BACKSTOP_ART"
got=$(run_gate "$GATE_INPUT")
check "gate blocks when backstop artifact missing (lead PASS alone)" "block" "$got"
# restore both for subsequent cases that expect a clean marker write
seed_artifacts "$VALID_HASH"
printf '%s' "$VALID_HASH" > "$MARKER"

# ── 2. Gate blocks + cleans up stale (mismatched) marker ──────────────
printf '%s' "$STALE_HASH" > "$MARKER"
got=$(run_gate "$GATE_INPUT")
check "gate blocks on stale hash marker" "block" "$got"
got=$(marker_state)
check "gate removes stale marker" "absent" "$got"

# ── 2c. Gate fails closed when merge-base can't be resolved (no real diff) ──
# Remove origin/main so the gate cannot compute a base...HEAD diff. Even a marker
# + artifacts carrying the empty-string SHA must NOT authorize a PR (the hardening
# codex flagged while dogfooding this very change).
ROOT_COMMIT=$(git -C "$TMPREPO" rev-list --max-parents=0 HEAD | head -1)
git -C "$TMPREPO" symbolic-ref -d refs/remotes/origin/HEAD 2>/dev/null || true
git -C "$TMPREPO" update-ref -d refs/remotes/origin/main
EMPTY_SHA=$(printf '%s' "" | (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1)
printf '%s' "$EMPTY_SHA" > "$MARKER"
seed_artifacts "$EMPTY_SHA"
got=$(run_gate "$GATE_INPUT")
check "gate fails closed when merge-base unresolved (empty-diff SHA rejected)" "block" "$got"
# Restore the base for the remaining tests.
git -C "$TMPREPO" update-ref refs/remotes/origin/main "$ROOT_COMMIT"
git -C "$TMPREPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
rm -f "$MARKER"; clear_artifacts

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

# Cross-gate parity: every other shell-active cd target the shared resolver
# fail-closes (cd -, glob, brace, cd -- options) must also block at the pre-PR
# gate, locking in the same contract the pre-commit suite asserts.
got=$(run_gate "$(make_input_cwd 'cd - && gh pr create --fill' "$TMPREPO")")
check "gate blocks cd - (OLDPWD) create" "block" "$got"
got=$(run_gate "$(make_input_cwd 'cd * && gh pr create --fill' "$TMPREPO")")
check "gate blocks glob cd (*) create" "block" "$got"
got=$(run_gate "$(make_input_cwd 'cd {a,b} && gh pr create --fill' "$TMPREPO")")
check "gate blocks brace-expansion cd ({a,b}) create" "block" "$got"
got=$(run_gate "$(make_input_cwd 'cd -- /tmp && gh pr create --fill' "$TMPREPO")")
check "gate blocks cd -- <path> create (end-of-options form)" "block" "$got"

# cwd is consulted: no cd prefix + valid marker + both artifacts in the cwd repo
# → allow (before the fix this resolved to the test runner's CWD and blocked).
printf '%s' "$VALID_HASH" > "$MARKER"
seed_artifacts "$VALID_HASH"
got=$(run_gate "$(make_input_cwd 'gh pr create --fill' "$TMPREPO")")
check "gate allows when cwd anchors to repo with valid marker (cwd consulted)" "allow" "$got"
rm -f "$MARKER"
clear_artifacts

# ── 9. Post-hook consumes marker for the toplevel cd form (cwd-anchored) ──
# Regression (PR #200 review): before the post-hook was cwd-anchored, a
# `cd "$(git rev-parse --show-toplevel)"` prefix resolved TARGET_DIR to the
# literal junk path, so the marker was looked up under the junk path and never
# consumed — left stale, able to re-authorize a later diff. Now the post-hook
# resolves via the cwd field and consumes the marker in the real repo.
printf '%s' "$VALID_HASH" > "$MARKER"
run_post_hook "$(make_posthook_cwd 'cd "$(git rev-parse --show-toplevel)" && gh pr create --fill' 'https://github.com/owner/repo/pull/42' "$TMPREPO")"
got=$(marker_state)
check "post-hook consumes marker for toplevel cd form (cwd-anchored)" "absent" "$got"

# ── Matcher hardening: wrapper/prefix bypass regression (Task 1) ──────
echo ""
echo "── pre-pr-gate wrapper/prefix bypass ───────────────────────"
clear_artifacts; rm -f "$MARKER"

# Compose input for CMD and run the gate. The got=$(...) assignment form below
# avoids masked command-substitution returns (SC2312) that a nested $() causes.
gate_of() { local _in; _in=$(make_input_cwd "$1" "$TMPREPO"); run_gate "$_in"; }

# Start-anchored matcher + literal-space pre-filter (command/double-space/abs
# path) AND the wrapper-word-only strip (option-bearing wrappers) all let real,
# unreviewed PR creations through. Every form below MUST now block.
got=$(gate_of 'command gh pr create --fill');        check "blocks: command gh pr create" "block" "$got"
got=$(gate_of 'gh  pr create --fill');               check "blocks: gh  pr create (double space)" "block" "$got"
got=$(gate_of '/usr/bin/gh pr create --fill');       check "blocks: /usr/bin/gh pr create" "block" "$got"
got=$(gate_of 'env -i FOO=1 gh pr create --fill');   check "blocks: env -i FOO=1 gh pr create" "block" "$got"
got=$(gate_of 'sudo -u nobody gh pr create --fill'); check "blocks: sudo -u nobody gh pr create" "block" "$got"
got=$(gate_of 'sudo -n gh pr create --fill');        check "blocks: sudo -n gh pr create (no-arg option)" "block" "$got"
got=$(gate_of 'command -- gh pr create --fill');     check "blocks: command -- gh pr create" "block" "$got"
# Negative: gh named only in prose is NOT a create → allow (both revisions).
got=$(gate_of 'echo run gh pr create when ready');   check "allows: prose mentioning gh pr create" "allow" "$got"

# Consume-marker parity: the post-hook carried the SAME matcher, so a wrapper-
# prefixed create would leave the marker stale (re-authorizing a later diff).
# It must recognize the prefix and consume; prose must NOT consume.
in1=$(make_posthook_cwd 'command gh pr create --fill' 'https://github.com/owner/repo/pull/43' "$TMPREPO")
printf '%s' "$VALID_HASH" > "$MARKER"; run_post_hook "$in1"
got=$(marker_state); check "post-hook consumes marker for command-prefixed create" "absent" "$got"
in2=$(make_posthook_cwd 'echo run gh pr create later' 'no-url' "$TMPREPO")
printf '%s' "$VALID_HASH" > "$MARKER"; run_post_hook "$in2"
got=$(marker_state); check "post-hook leaves marker for prose (not a real create)" "present" "$got"
rm -f "$MARKER"

# ── Summary ───────────────────────────────────────────────────────────
echo ""
echo "  ── $PASS/$TOTAL passed ──"
[[ "$FAIL" -eq 0 ]] || { echo "  $FAIL test(s) failed"; exit 1; }
exit 0
