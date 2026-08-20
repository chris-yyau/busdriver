#!/usr/bin/env bash
# Tests for pre-merge gate and post-PR-created hook.
#
# Validates:
#   1. Pre-merge gate blocks gh pr merge without pr-grind-clean marker
#   2. Pre-merge gate allows with fresh marker
#   3. Pre-merge gate allows with skip file
#   4. Pre-merge gate ignores non-merge commands
#   5. Pre-merge gate rejects stale markers (>2h)
#   6. Post-PR-created hook appends pr-grind instruction
#   7. Post-PR-created hook passes through non-PR commands
#   8. Gate is wired to scripts/relevant-check-status.sh (issue #154) and the
#      lock-aware allowlist + ADVISORY_PATTERN fallback behaves correctly when
#      driven through the gate-relative helper path (R1-R8 integration). Filter
#      edge-case units live in tests/test-relevant-check-status.sh.
#
# Usage: bash tests/test-pre-merge-gate.sh
# Exit: 0 if all pass, 1 if any fail.

set -euo pipefail
cd "$(dirname "$0")/.."

PASS=0
FAIL=0
TOTAL=0

GATE_SCRIPT="hooks/gate-scripts/pre-merge-gate.sh"
POST_HOOK_SCRIPT="hooks/gate-scripts/post-merge-confirm-bypass.sh"
HOOK_SCRIPT="scripts/hooks/post-bash-pr-created.js"
MARKER_DIR=".claude"
CLEAN_MARKER="$MARKER_DIR/pr-grind-clean.local"
SKIP_FILE="$MARKER_DIR/skip-pr-grind.local"
PENDING_MARKER="$MARKER_DIR/pr-pending-grind.local"
BYPASS_PENDING="$MARKER_DIR/.merge-bypass-pending.local"

# ── Hermetic gh stub ──────────────────────────────────────────────────
# The pre-merge gate independently verifies CI via `gh pr checks <PR>`
# (pre-merge-gate.sh). A real gh call needs network + auth, which CI runners
# lack; the gate then fail-closes and the "allow with fresh marker" cases
# wrongly block. Shim gh so `gh pr checks` reports every required check (read
# from the lock in the gate's cwd, so it can't drift) as passing — making these
# tests hermetic (no network/auth dependency). Only `gh pr checks` is exercised
# by the gate; any other subcommand exits 0.
#
# The gate ALSO resolves the PR's live head OID (`gh pr view --json headRefOid`)
# to check it against the marker's SHA field (#505). The stub answers from
# GH_STUB_HEAD_OID so a test can simulate "HEAD moved" by changing that env var
# rather than by needing a real remote. Leaving it EMPTY simulates an
# unresolvable head, which the gate must fail-closed on.
# Contains hex letters (a-f) deliberately — test 2e1 below exercises the
# case-insensitive compare via `tr 'a-f' 'A-F'`, which is a no-op on an
# all-digit SHA and would silently skip testing the uppercase path (cubic
# review, PR #511).
GH_STUB_HEAD_OID_DEFAULT="deadbeef00112233445566778899aabbccddeeff"
export GH_STUB_HEAD_OID="$GH_STUB_HEAD_OID_DEFAULT"
GH_STUBDIR=$(mktemp -d)
cat > "$GH_STUBDIR/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "checks" ]; then
  python3 - <<'PY' 2>/dev/null || printf 'shellcheck\tpass\t1s\thttps://x\n'
import json
try:
    names = [c["name"] for c in json.load(open(".github/required-checks.lock")).get("required", [])]
except Exception:
    names = []
for n in (names or ["shellcheck"]):
    print(f"{n}\tpass\t1s\thttps://x")
PY
  exit 0
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  # Only two projections are exercised: headRefOid by the pre-merge gate, and
  # `--json state` by post-merge-confirm-bypass.sh's authoritative merge-state
  # check (#664). Both answer from an env var so a test can simulate any remote
  # state without a network. GH_STUB_PR_STATE defaults to EMPTY = "GitHub did
  # not answer", which is what every fixture written before #664 assumes.
  case "$*" in
    *headRefOid*) printf '%s\n' "${GH_STUB_HEAD_OID:-}" ;;
    *"--json state"*)
      # -R <repo> present → answer from GH_STUB_PR_STATE_NAMED, so a test can
      # prove WHICH repo the hook asked about, not merely that it asked.
      case "$*" in
        *" -R "*) [ -n "${GH_STUB_PR_STATE_NAMED:-}" ] && printf '%s\n' "$GH_STUB_PR_STATE_NAMED" ;;
        *) [ -n "${GH_STUB_PR_STATE:-}" ] && printf '%s\n' "$GH_STUB_PR_STATE" ;;
      esac ;;
  esac
  exit 0
fi
exit 0
STUB
chmod +x "$GH_STUBDIR/gh"
export PATH="$GH_STUBDIR:$PATH"

# Write a marker in the current `<PR_NUMBER> <HEAD_SHA>` contract (#505).
# Second arg overrides the SHA (to simulate a marker written for another commit).
write_marker() {
    printf '%s %s\n' "$1" "${2:-$GH_STUB_HEAD_OID_DEFAULT}" > "$CLEAN_MARKER"
}

# ── Helpers ───────────────────────────────────────────────────────────

run_gate_test() {
    local name="$1" expected="$2" input="$3"
    TOTAL=$((TOTAL + 1))
    local output exit_code
    output=$(printf '%s' "$input" | bash "$GATE_SCRIPT" 2>/dev/null) && exit_code=0 || exit_code=$?

    local got="allow"
    if [[ "$exit_code" -ne 0 ]] && [[ -z "$output" ]]; then
        got="crash"
    elif echo "$output" | grep -q '"block"' 2>/dev/null; then
        got="block"
    fi

    if [[ "$got" == "$expected" ]]; then
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s (expected=%s got=%s)\n" "$name" "$expected" "$got"
        FAIL=$((FAIL + 1))
    fi
}

run_hook_test() {
    local name="$1" expected_pattern="$2" input="$3"
    TOTAL=$((TOTAL + 1))
    local output
    output=$(CLAUDE_PLUGIN_ROOT="$(pwd)" node -e "
        const m = require('./$HOOK_SCRIPT');
        const r = m.run(process.argv[1]);
        if (typeof r === 'string') process.stdout.write(r);
        else if (r && r.stdout) process.stdout.write(r.stdout);
    " "$input" 2>/dev/null) || true

    if echo "$output" | grep -q "$expected_pattern" 2>/dev/null; then
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s (pattern '%s' not found)\n" "$name" "$expected_pattern"
        FAIL=$((FAIL + 1))
    fi
}

# ── Setup ─────────────────────────────────────────────────────────────
mkdir -p "$MARKER_DIR"

# Save and restore any existing markers (track existence, not just content)
HAD_CLEAN=false ; HAD_SKIP=false ; HAD_PENDING=false ; HAD_BYPASS=false
PREV_CLEAN="" ; PREV_SKIP="" ; PREV_PENDING="" ; PREV_BYPASS=""
[ -f "$CLEAN_MARKER" ]    && HAD_CLEAN=true    && PREV_CLEAN=$(cat "$CLEAN_MARKER")
[ -f "$SKIP_FILE" ]       && HAD_SKIP=true     && PREV_SKIP=$(cat "$SKIP_FILE")
[ -f "$PENDING_MARKER" ]  && HAD_PENDING=true  && PREV_PENDING=$(cat "$PENDING_MARKER")
[ -f "$BYPASS_PENDING" ]  && HAD_BYPASS=true   && PREV_BYPASS=$(cat "$BYPASS_PENDING")

cleanup() {
    rm -rf "$GH_STUBDIR" 2>/dev/null || true
    rm -f "$CLEAN_MARKER" "$SKIP_FILE" "$PENDING_MARKER" "$BYPASS_PENDING"
    [ "$HAD_CLEAN" = true ]   && printf '%s' "$PREV_CLEAN"   > "$CLEAN_MARKER"   || true
    [ "$HAD_SKIP" = true ]    && printf '%s' "$PREV_SKIP"    > "$SKIP_FILE"      || true
    [ "$HAD_PENDING" = true ] && printf '%s' "$PREV_PENDING" > "$PENDING_MARKER" || true
    [ "$HAD_BYPASS" = true ]  && printf '%s' "$PREV_BYPASS"  > "$BYPASS_PENDING" || true
}
trap cleanup EXIT

# Start clean
rm -f "$CLEAN_MARKER" "$SKIP_FILE" "$PENDING_MARKER" "$BYPASS_PENDING"

# ═══════════════════════════════════════════════════════════════════════
# PRE-MERGE GATE TESTS
# ═══════════════════════════════════════════════════════════════════════
MERGE_INPUT='{"tool_name":"Bash","toolName":"Bash","tool_input":{"command":"gh pr merge 31 --squash"}}'
NON_MERGE_INPUT='{"tool_name":"Bash","toolName":"Bash","tool_input":{"command":"npm install"}}'
MERGE_WITH_CD='{"tool_name":"Bash","toolName":"Bash","tool_input":{"command":"cd /tmp/repo && gh pr merge 42 --squash --delete-branch"}}'
MULTI_MERGE_INPUT='{"tool_name":"Bash","toolName":"Bash","tool_input":{"command":"gh pr merge 42 --squash && gh pr merge 99 --squash"}}'
WRAPPED_BASH_C='{"tool_name":"Bash","toolName":"Bash","tool_input":{"command":"bash -c \"gh pr merge 42 --squash && gh pr merge 99 --squash\""}}'
WRAPPED_SUBSHELL='{"tool_name":"Bash","toolName":"Bash","tool_input":{"command":"(gh pr merge 42 --squash; gh pr merge 99 --squash)"}}'

echo "── pre-merge-gate ──────────────────────────────────────────"

# 1. Block without marker
run_gate_test "blocks gh pr merge without marker" "block" "$MERGE_INPUT"

# 2. Allow with fresh marker
write_marker 31
run_gate_test "allows gh pr merge with fresh marker" "allow" "$MERGE_INPUT"
rm -f "$CLEAN_MARKER"

# ── 2b-2e. Marker must authorize the COMMIT, not just the PR (#505) ──────
# Regression: a marker written when the grind converged stayed valid for 2h, so a
# push landing after convergence let `gh pr merge <same PR>` merge a commit no
# reviewer ack had covered (chrisyau.me#181 merged 5 unresolved bot threads that
# were posted on a HEAD pushed 6 min AFTER the grind's last validated commit).
# All four arms below must BLOCK; test 2 above is the matching-SHA allow arm, so
# the guard is pinned in both directions.

# 2b. Marker SHA is for a different commit than the PR's current HEAD.
write_marker 31 "9999999999888888888877777777776666666666"
run_gate_test "blocks when PR HEAD moved since grind (marker SHA != live HEAD)" "block" "$MERGE_INPUT"
# ...and the now-worthless marker must be removed, not left to authorize a retry.
TOTAL=$((TOTAL + 1))
if [ ! -f "$CLEAN_MARKER" ]; then
    PASS=$((PASS + 1)); printf "  PASS  removes marker whose SHA no longer matches HEAD\n"
else
    FAIL=$((FAIL + 1)); printf "  FAIL  removes marker whose SHA no longer matches HEAD\n"
fi
rm -f "$CLEAN_MARKER"

# 2c. Pre-#505 marker (bare PR number, no SHA) cannot prove which commit was
#     reviewed → fail-closed rather than grandfathered in.
echo "31" > "$CLEAN_MARKER"
run_gate_test "blocks legacy bare-PR-number marker (no head SHA)" "block" "$MERGE_INPUT"
rm -f "$CLEAN_MARKER"

# 2d. Truncated/short SHA is not accepted as a commit identity.
write_marker 31 "10090de5"
run_gate_test "blocks marker with abbreviated (non-40-char) head SHA" "block" "$MERGE_INPUT"
rm -f "$CLEAN_MARKER"

# 2e1. Hex is accepted case-insensitively, so it must COMPARE case-insensitively —
#      an uppercase marker must not read as "HEAD moved" and delete a valid marker.
printf '31 %s\n' "$(printf '%s' "$GH_STUB_HEAD_OID_DEFAULT" | tr 'a-f' 'A-F')" > "$CLEAN_MARKER"
run_gate_test "allows an uppercase-hex marker matching the same head" "allow" "$MERGE_INPUT"
rm -f "$CLEAN_MARKER"

# 2e2. A truncated-but-hex live OID is a VERIFICATION failure, not a staleness
#      verdict. It must not reach the authoritative comparison, which would delete
#      a perfectly valid marker on a bogus "HEAD moved".
GH_STUB_HEAD_OID="1111111" write_marker 31
GH_STUB_HEAD_OID="1111111" run_gate_test "blocks on a truncated (non-40-char) live head OID" "block" "$MERGE_INPUT"
TOTAL=$((TOTAL + 1))
if [ -f "$CLEAN_MARKER" ]; then
    PASS=$((PASS + 1)); printf "  PASS  preserves marker when live OID is truncated (verification failure)\n"
else
    FAIL=$((FAIL + 1)); printf "  FAIL  preserves marker when live OID is truncated\n"
fi
rm -f "$CLEAN_MARKER"

# 2e. Head OID unresolvable (auth/network failure) → block, and PRESERVE the
#     marker: the grind was valid, only the verification call failed.
GH_STUB_HEAD_OID="" write_marker 31
GH_STUB_HEAD_OID="" run_gate_test "blocks when PR head SHA cannot be resolved" "block" "$MERGE_INPUT"
TOTAL=$((TOTAL + 1))
if [ -f "$CLEAN_MARKER" ]; then
    PASS=$((PASS + 1)); printf "  PASS  preserves marker when head-SHA lookup fails (verification error, not staleness)\n"
else
    FAIL=$((FAIL + 1)); printf "  FAIL  preserves marker when head-SHA lookup fails\n"
fi
rm -f "$CLEAN_MARKER"

# ── 2f. Cross-repo guard is MERGE-SCOPED (#505) ──────────────────────────
# A repo/host selector on the merge itself means "PR #31" may be a different
# repo's PR, which none of this checkout's evidence (marker SHA, `gh pr checks`,
# `gh pr diff`) covers. One shape per branch of gh_pr_repo_override(): separate
# and attached -R, separate and = forms of --repo, a gh GLOBAL flag placed before
# `pr` (which really does retarget), and an env-assignment prefix.
# The marker is PRESERVED — this is a targeting refusal, not marker staleness.
for xrepo_shape in \
    'gh pr merge 31 --squash -R other/repo' \
    'gh pr merge 31 --squash -Rother/repo' \
    'gh pr merge 31 --squash --repo other/repo' \
    'gh pr merge 31 --squash --repo=other/repo' \
    'gh -R other/repo pr merge 31 --squash' \
    'GH_REPO=other/repo gh pr merge 31 --squash'
do
    write_marker 31
    run_gate_test "blocks cross-repo merge: $xrepo_shape" "block" \
        "{\"tool_name\":\"Bash\",\"toolName\":\"Bash\",\"tool_input\":{\"command\":\"$xrepo_shape\"}}"
    TOTAL=$((TOTAL + 1))
    if [ -f "$CLEAN_MARKER" ]; then
        PASS=$((PASS + 1))
        printf "  PASS  preserves marker on cross-repo refusal (%s)\n" "$xrepo_shape"
    else
        FAIL=$((FAIL + 1))
        printf "  FAIL  preserves marker on cross-repo refusal (%s)\n" "$xrepo_shape"
    fi
    rm -f "$CLEAN_MARKER"
done

# 2f2. ...and the guard must stay scoped to the MERGE's own argv. pr-grind's
#      auto-admin block runs `gh -R "$OWNER/$REPO" pr view` and `gh pr merge`
#      inside ONE fenced Bash call (skills/pr-grind/SKILL.md). ADR 0024's
#      whole-command substring test matched that sibling `-R` and rejected the
#      entire call, so pr-grind could never merge — the regression this case pins.
AUTO_ADMIN_SHAPE='{"tool_name":"Bash","toolName":"Bash","tool_input":{"command":"gh -R \"$OWNER/$REPO\" pr view 31 --json mergeStateStatus -q .mergeStateStatus && gh pr merge 31 --squash --delete-branch --admin"}}'
write_marker 31
run_gate_test "allows pr-grind auto-admin shape (sibling gh -R pr view, unselected merge)" "allow" \
    "$AUTO_ADMIN_SHAPE"
rm -f "$CLEAN_MARKER"
# ...and that allow must be an authorization, not a failure to SEE the merge: the
# gate exits 0 when it recognizes no merge at all, so without the marker the very
# same command must block. Otherwise the case above passes for the wrong reason.
run_gate_test "recognizes the merge inside the auto-admin shape (blocks with no marker)" "block" \
    "$AUTO_ADMIN_SHAPE"

# 2g. The MERGE_PARSE block is a double-quoted shell string, so an unescaped
#     backtick pair inside it is COMMAND SUBSTITUTION, not prose. A comment
#     mentioning `gh -R ... pr view` really did run a stray credentialed gh on every
#     merge-gate invocation. Assert the gate never calls gh with that literal.
TOTAL=$((TOTAL + 1))
_SPYDIR=$(mktemp -d)
printf '#!/bin/sh\necho "$*" >> %s/hits\nexit 0\n' "$_SPYDIR" > "$_SPYDIR/gh"
chmod +x "$_SPYDIR/gh"
write_marker 31
printf '%s' "$MERGE_INPUT" | PATH="$_SPYDIR:$PATH" bash "$GATE_SCRIPT" >/dev/null 2>&1 || true
if grep -q -- '-R \.\.\.' "$_SPYDIR/hits" 2>/dev/null; then
    FAIL=$((FAIL + 1))
    printf "  FAIL  no stray gh call from an unescaped backtick in MERGE_PARSE\n"
else
    PASS=$((PASS + 1))
    printf "  PASS  no stray gh call from an unescaped backtick in MERGE_PARSE\n"
fi
rm -rf "$_SPYDIR"
rm -f "$CLEAN_MARKER"

# ── 2h. Auto-merge queuing guard is MERGE-SCOPED (Codex #511) ────────────
# `--auto` queues the merge for whenever GitHub's required checks/protections
# clear rather than merging immediately, so the marker's head-SHA check can be
# minutes/hours stale by the time GitHub actually merges. Block on presence,
# regardless of a valid marker. The marker is PRESERVED — this is a queuing
# refusal, not marker staleness.
for auto_shape in \
    'gh pr merge 31 --squash --auto' \
    'gh pr merge 31 --auto --delete-branch' \
    'gh pr merge 31 --admin --auto'
do
    write_marker 31
    run_gate_test "blocks auto-merge queuing: $auto_shape" "block" \
        "{\"tool_name\":\"Bash\",\"toolName\":\"Bash\",\"tool_input\":{\"command\":\"$auto_shape\"}}"
    TOTAL=$((TOTAL + 1))
    if [ -f "$CLEAN_MARKER" ]; then
        PASS=$((PASS + 1))
        printf "  PASS  preserves marker on auto-merge refusal (%s)\n" "$auto_shape"
    else
        FAIL=$((FAIL + 1))
        printf "  FAIL  preserves marker on auto-merge refusal (%s)\n" "$auto_shape"
    fi
    rm -f "$CLEAN_MARKER"
done

# 2h2. `--disable-auto` is a DIFFERENT pflag flag name (cancels a previously
#      queued auto-merge), not a prefix/substring of `--auto` — it must NOT
#      trip the guard. A matching marker should allow normally.
write_marker 31
run_gate_test "does not block --disable-auto (distinct flag, not --auto)" "allow" \
    "{\"tool_name\":\"Bash\",\"toolName\":\"Bash\",\"tool_input\":{\"command\":\"gh pr merge 31 --squash --disable-auto\"}}"
rm -f "$CLEAN_MARKER"

# 2h3. `--auto` on a SIBLING command (not the merge itself) must not false-block —
#      same scoping requirement as the 2f2 auto-admin case above.
AUTO_SIBLING_SHAPE='{"tool_name":"Bash","toolName":"Bash","tool_input":{"command":"gh pr view 31 --json title -q .title --auto && gh pr merge 31 --squash"}}'
write_marker 31
run_gate_test "allows merge when --auto sits on a sibling gh command, not the merge" "allow" \
    "$AUTO_SIBLING_SHAPE"
rm -f "$CLEAN_MARKER"

# 2h4. Same backtick-safety regression as 2g, for the new auto-merge comment
#      block: assert no stray gh call fires from an unescaped backtick.
TOTAL=$((TOTAL + 1))
_SPYDIR=$(mktemp -d)
printf '#!/bin/sh\necho "$*" >> %s/hits\nexit 0\n' "$_SPYDIR" > "$_SPYDIR/gh"
chmod +x "$_SPYDIR/gh"
write_marker 31
printf '%s' "$MERGE_INPUT" | PATH="$_SPYDIR:$PATH" bash "$GATE_SCRIPT" >/dev/null 2>&1 || true
if grep -q -- '--auto' "$_SPYDIR/hits" 2>/dev/null; then
    FAIL=$((FAIL + 1))
    printf "  FAIL  no stray gh call from an unescaped backtick in the auto-merge comment\n"
else
    PASS=$((PASS + 1))
    printf "  PASS  no stray gh call from an unescaped backtick in the auto-merge comment\n"
fi
rm -rf "$_SPYDIR"
rm -f "$CLEAN_MARKER"

# 3. Allow with skip file (must be > 30s old to pass anti-self-bypass).
#    Bug B deferred-consumption: gate should ALSO leave skip file in place
#    and write .merge-bypass-pending.local so PostToolUse can consume only on
#    confirmed merge-success.
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null \
    || true
rm -f "$BYPASS_PENDING"
run_gate_test "allows gh pr merge with skip file" "allow" "$MERGE_INPUT"

# 3a. Deferred-consumption: skip file MUST still exist after gate-pass
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ]; then
    printf "  PASS  defers skip-pr-grind.local consumption (still exists post-gate)\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  defers skip-pr-grind.local consumption (skip file was deleted)\n"
    FAIL=$((FAIL + 1))
fi

# 3b. Deferred-consumption: pending claim MUST be written
TOTAL=$((TOTAL + 1))
if [ -f "$BYPASS_PENDING" ]; then
    printf "  PASS  writes .merge-bypass-pending.local on gate-pass\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  writes .merge-bypass-pending.local on gate-pass\n"
    FAIL=$((FAIL + 1))
fi

# 3c. Pending claim records the merge PR number for audit
TOTAL=$((TOTAL + 1))
if [ -f "$BYPASS_PENDING" ] && grep -q '^merge_pr=31$' "$BYPASS_PENDING" 2>/dev/null; then
    printf "  PASS  pending claim records merge_pr=31\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  pending claim records merge_pr=31 (content: %s)\n" \
        "$(cat "$BYPASS_PENDING" 2>/dev/null || echo MISSING)"
    FAIL=$((FAIL + 1))
fi

rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# 4. Ignore non-merge commands
run_gate_test "ignores non-merge commands" "allow" "$NON_MERGE_INPUT"

# 5. Block with merge + cd prefix (no marker)
run_gate_test "blocks cd + gh pr merge without marker" "block" "$MERGE_WITH_CD"

# 5b. A LEADING LF embedded in an UNTRUSTED (loose-parsed) cd operand must fail
# closed even with a fresh, valid marker present. `pushd` (unlike `cd`) is only
# ever seen by the LOOSE cd parser (_cd_target_loose) feeding the untrusted_cd
# channel -- _cd_target's strict _reject_crlf guard never runs on it.
# untrusted_cd is the LAST field this hook prints, so an embedded LF cannot
# shift a LATER field, but it still SPLITS the field's own `print()` into two
# lines: `sed -n '8p'` then captures only the text BEFORE the first LF. A LF
# at the very START of the operand truncates UNTRUSTED_CD to the EMPTY STRING
# -- and gate_resolve_repo_dir treats an empty untrusted_cd exactly like "no
# untrusted cd happened at all" ([ -n "$untrusted_cd" ] guards every check),
# so the untrusted-cd defense is SILENTLY SKIPPED while bash really did `pushd`
# into an attacker-chosen directory. Verified this is a real bypass, not just
# defense-in-depth: with the untrusted_cd LF/CR guard reverted, this exact
# input flips from block to ALLOW with a fresh marker present. Zero test
# coverage for this existed prior to #511's merge with #509 (which introduced
# the untrusted_cd field and its LF-only `chr(10)` emission guard).
MERGE_WITH_LEADING_LF=$(printf '%s' '{"tool_name":"Bash","toolName":"Bash","tool_input":{"command":"pushd \"' && printf '\\n' && printf '%s' 'Q\"; gh pr merge 42 --squash --delete-branch"}}')
write_marker 42
run_gate_test "blocks leading-LF untrusted (pushd) cd operand even with fresh marker" "block" "$MERGE_WITH_LEADING_LF"
rm -f "$CLEAN_MARKER"

# 6. Non-Bash tool name → allow (not our concern)
run_gate_test "ignores non-Bash tool" "allow" \
    '{"tool_name":"Write","tool_input":{"file_path":"test.js"}}'

# 7. Stale marker (simulate by touching with old timestamp)
write_marker 31
# Touch with timestamp 3 hours ago (macOS or GNU)
TOUCH_OK=false
touch -t "$(date -v-3H '+%Y%m%d%H%M.%S')" "$CLEAN_MARKER" 2>/dev/null && TOUCH_OK=true
[ "$TOUCH_OK" = false ] && touch -d "3 hours ago" "$CLEAN_MARKER" 2>/dev/null && TOUCH_OK=true
if [ "$TOUCH_OK" = true ]; then
    run_gate_test "blocks with stale marker (>2h old)" "block" "$MERGE_INPUT"
else
    TOTAL=$((TOTAL + 1))
    printf "  SKIP  blocks with stale marker (>2h old) — touch timestamp not supported\n"
    PASS=$((PASS + 1))  # Don't fail the suite on platform limitation
fi
rm -f "$CLEAN_MARKER"

# 7c. Multi-merge guard: refuse Bash commands chaining more than one
#     gh pr merge invocation, regardless of marker/skip state.
write_marker 42  # marker WOULD authorize PR 42, but multi-merge blocks anyway
run_gate_test "blocks chained gh pr merge (multi-merge guard)" "block" "$MULTI_MERGE_INPUT"
rm -f "$CLEAN_MARKER"

# 7d. Multi-merge guard MUST also catch wrapper bypasses (bash -c, sh -c,
#     eval, subshell). Substring-count over the whole cmd, not per-segment.
write_marker 42
run_gate_test "blocks bash -c wrapped chained merges" "block" "$WRAPPED_BASH_C"
rm -f "$CLEAN_MARKER"

# 7e. Subshell-wrapped chained merges.
write_marker 42
run_gate_test "blocks (...)-subshell chained merges" "block" "$WRAPPED_SUBSHELL"
rm -f "$CLEAN_MARKER"

# 7e2. Issue #426 — writing ABOUT the gate must not trip it. The merge command
#      quoted as PROSE (an issue comment, a --body, a quoted heredoc table, a
#      test fixture's input string) is DATA the shell never executes, so the
#      gate must stay silent. Verified against real bash before pinning: a
#      SINGLE-quoted / quoted-heredoc body expands nothing (0 commands run),
#      while a double-quoted backtick genuinely does run the merge — so only
#      the inert forms belong here. No marker present, so any block these
#      produce is unambiguously the false positive, not a missing marker.
rm -f "$CLEAN_MARKER"

# Build a Bash-tool payload from a raw command string. Assigning the
# substitution to a variable first (rather than inlining it into the
# run_gate_test call) keeps its exit status visible — shellcheck SC2312.
bash_payload() {
    local _json
    _json=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1") || return 1
    printf '%s' "$_json"
}

PROSE_CASES=(
    "gh issue close 426 --comment 'registered as a PreToolUse hook on \`gh pr merge\`'"
    "gh pr comment 5 --body 'run gh pr merge then gh pr merge again'"
    "gh pr view 5 --json title"
)
for _p in "${PROSE_CASES[@]}"; do
    PAYLOAD=$(bash_payload "$_p")
    run_gate_test "ignores merge quoted as prose: ${_p:0:44}..." "allow" "$PAYLOAD"
done

# 7e3. Issue #426 — a QUOTED heredoc body (the four-row evidence table that hit
#      this three times in one session) is inert data; the gate must ignore it.
PAYLOAD=$(bash_payload "gh issue comment 426 --body-file - <<'EOF'
| gh pr merge | env gh pr merge |
| /usr/bin/gh pr merge | gh  pr  merge |
EOF")
run_gate_test "ignores merge rows in a quoted heredoc body" "allow" "$PAYLOAD"

# 7e4. The exemption must NOT become a bypass: a heredoc fed to an interpreter
#      really executes its body (verified against real bash), so it must still
#      block — including behind a leading command, which reads the consumer from
#      the owning segment rather than the whole physical line.
write_marker 42
PAYLOAD=$(bash_payload "bash <<'EOF'
gh pr merge 1
gh pr merge 2
EOF")
run_gate_test "still blocks merges inside an interpreter heredoc" "block" "$PAYLOAD"
PAYLOAD=$(bash_payload "true; bash <<'EOF'
gh pr merge 1
EOF")
run_gate_test "still blocks interpreter heredoc behind a leading command" "block" "$PAYLOAD"

# 7e5. Compound-command keywords must not hide a merge (fail-OPEN regression
#      caught in review — all of these really run the merge).
# shellcheck disable=SC2016  # $x must stay literal — it is the command under test
for _c in 'if true; then gh pr merge 1; fi' 'for x in 1; do gh pr merge "$x"; done'; do
    PAYLOAD=$(bash_payload "$_c")
    run_gate_test "still blocks merge behind a shell keyword: ${_c:0:30}..." "block" "$PAYLOAD"
done
rm -f "$CLEAN_MARKER"

# 7a. Bug A: marker for PR X must NOT authorize merging PR Y. Marker holds
#     a different PR number than the one being merged → gate blocks.
write_marker 99
run_gate_test "blocks when marker PR != merge PR (cross-PR mismatch)" "block" "$MERGE_INPUT"
rm -f "$CLEAN_MARKER"

# 7b. Bug A: when the mismatch fires, the stale marker is removed so the
#     next attempt does not silently re-authorize.
write_marker 99
printf '%s' "$MERGE_INPUT" | bash "$GATE_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ ! -f "$CLEAN_MARKER" ]; then
    printf "  PASS  removes mismatched pr-grind-clean marker (no silent re-auth)\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  removes mismatched pr-grind-clean marker\n"
    FAIL=$((FAIL + 1))
fi
rm -f "$CLEAN_MARKER"

# 7f. cwd-anchored resolution: the recognized $(git rev-parse --show-toplevel)
#     idiom resolves via cwd instead of a junk path, so a fresh marker
#     authorizes the merge (previously this spurious-blocked). Shares the
#     gh-availability precondition with case 2 above.
SUBST_MERGE='{"tool_name":"Bash","toolName":"Bash","tool_input":{"command":"cd \"$(git rev-parse --show-toplevel)\" && gh pr merge 31 --squash"}}'
write_marker 31
run_gate_test "allows toplevel-idiom cd prefix with fresh marker" "allow" "$SUBST_MERGE"
rm -f "$CLEAN_MARKER"

# 7g. Unresolvable command substitution in the cd target → fail-CLOSED block,
#     even with a marker that would otherwise authorize the merge (the block
#     fires during resolution, before the marker check).
UNRESOLV_MERGE='{"tool_name":"Bash","toolName":"Bash","tool_input":{"command":"cd \"$(echo /x)\" && gh pr merge 31 --squash"}}'
write_marker 31
run_gate_test "blocks unresolvable cd substitution target" "block" "$UNRESOLV_MERGE"
rm -f "$CLEAN_MARKER"

# ═══════════════════════════════════════════════════════════════════════
# POST-MERGE BYPASS CONFIRMATION HOOK TESTS (Bug B)
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "── post-merge-confirm-bypass ──────────────────────────────"

# B1. Success path: merge succeeded → consume skip file + clear pending.
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf 'skip_mtime=%s\nmerge_pr=42\nclaimed_at=%s\n' \
    "$(stat -c %Y "$SKIP_FILE" 2>/dev/null || stat -f %m "$SKIP_FILE" 2>/dev/null)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$BYPASS_PENDING"
SUCCESS_INPUT='{"tool_name":"Bash","tool_input":{"command":"gh pr merge 42 --squash --delete-branch"},"tool_output":{"output":"✓ Squashed and merged pull request #42","exit_code":0}}'
printf '%s' "$SUCCESS_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ ! -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  success → skip + pending consumed\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  success path: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B2. Failure path: merge failed → leave skip file, clear pending.
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf 'skip_mtime=%s\nmerge_pr=42\nclaimed_at=%s\n' \
    "$(stat -c %Y "$SKIP_FILE" 2>/dev/null || stat -f %m "$SKIP_FILE" 2>/dev/null)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$BYPASS_PENDING"
FAIL_INPUT='{"tool_name":"Bash","tool_input":{"command":"gh pr merge 42 --squash --delete-branch"},"tool_output":{"output":"X Pull request is not mergeable: the head branch is not up to date with the base branch.","exit_code":1}}'
printf '%s' "$FAIL_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  failure → skip preserved, pending released\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  failure path: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B3. No pending claim → hook is a no-op (does not touch skip file).
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf '%s' "$SUCCESS_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ]; then
    printf "  PASS  no pending claim → skip file untouched\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  no pending claim → skip file was incorrectly deleted\n"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B4. Non-merge bash call does not touch pending claim.
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf 'skip_mtime=0\nmerge_pr=42\nclaimed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$BYPASS_PENDING"
NON_MERGE_BASH='{"tool_name":"Bash","tool_input":{"command":"gh pr view 42"},"tool_output":{"output":"PR title\n","exit_code":0}}'
printf '%s' "$NON_MERGE_BASH" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ] && [ -f "$BYPASS_PENDING" ]; then
    printf "  PASS  non-merge bash leaves pending claim intact\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  non-merge bash touched pending claim or skip file\n"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B5. Ambiguous output (no clear success/failure signal) → fail-safe: leave skip.
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf 'skip_mtime=%s\nmerge_pr=42\nclaimed_at=%s\n' \
    "$(stat -c %Y "$SKIP_FILE" 2>/dev/null || stat -f %m "$SKIP_FILE" 2>/dev/null)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$BYPASS_PENDING"
AMBIG_INPUT='{"tool_name":"Bash","tool_input":{"command":"gh pr merge 42 --squash"},"tool_output":{"output":"some unfamiliar output that matches neither pattern"}}'
printf '%s' "$AMBIG_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  ambiguous → fail-safe (skip preserved, pending released)\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  ambiguous: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B6. Tamper detection: skip file mtime changed between claim and confirm.
#     Pending file records the OLD mtime; current file has a NEWER mtime.
#     Should refuse to consume + preserve skip (release-tampered).
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
ORIGINAL_MTIME=$(stat -c %Y "$SKIP_FILE" 2>/dev/null || stat -f %m "$SKIP_FILE" 2>/dev/null)
printf 'skip_mtime=%s\nmerge_pr=42\nclaimed_at=%s\n' \
    "$ORIGINAL_MTIME" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$BYPASS_PENDING"
# Simulate tamper: re-touch skip file to update its mtime (claim's mtime now stale)
touch "$SKIP_FILE"
printf '%s' "$SUCCESS_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  tamper detected (skip mtime changed) → released, skip preserved\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  tamper detection: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B7. Tamper detection: skip file deleted between claim and confirm.
#     Pending file claims an mtime but the skip file is gone. Should release
#     pending (nothing left to consume).
printf 'skip_mtime=12345\nmerge_pr=42\nclaimed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$BYPASS_PENDING"
# No skip file — pre-existing or post-gate deletion
printf '%s' "$SUCCESS_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ ! -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  skip file missing → released-tampered (nothing to consume)\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  missing-skip case: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B8. Tamper detection: skip file is too young (<30s) at confirm time.
#     Re-applies the anti-self-bypass check at consumption — defense
#     against a Claude self-touch between claim and confirm.
touch "$SKIP_FILE"  # fresh mtime → age = 0s
printf 'skip_mtime=%s\nmerge_pr=42\nclaimed_at=%s\n' \
    "$(stat -c %Y "$SKIP_FILE" 2>/dev/null || stat -f %m "$SKIP_FILE" 2>/dev/null)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$BYPASS_PENDING"
printf '%s' "$SUCCESS_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  skip <30s at confirm → released-tampered, skip preserved\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  young-skip case: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B9. Cross-PR mismatch: claim is for PR 42 but bash cmd is gh pr merge 99.
#     Should release pending without consuming skip (released-mismatch).
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf 'skip_mtime=%s\nmerge_pr=42\nclaimed_at=%s\n' \
    "$(stat -c %Y "$SKIP_FILE" 2>/dev/null || stat -f %m "$SKIP_FILE" 2>/dev/null)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$BYPASS_PENDING"
MISMATCH_INPUT='{"tool_name":"Bash","tool_input":{"command":"gh pr merge 99 --squash"},"tool_output":{"output":"✓ Squashed and merged pull request #99","exit_code":0}}'
printf '%s' "$MISMATCH_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  claim/cmd PR mismatch → released-mismatch, skip preserved\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  PR mismatch: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B10. Auto-merge enabled (gh pr merge --auto) → PR not actually merged yet.
#      Should release pending and preserve skip so retry doesn't need a
#      re-touch when the real merge eventually fires (or fails).
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf 'skip_mtime=%s\nmerge_pr=42\nclaimed_at=%s\n' \
    "$(stat -c %Y "$SKIP_FILE" 2>/dev/null || stat -f %m "$SKIP_FILE" 2>/dev/null)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$BYPASS_PENDING"
AUTO_INPUT='{"tool_name":"Bash","tool_input":{"command":"gh pr merge 42 --squash --auto"},"tool_output":{"output":"✓ Pull request #42 will be automatically merged via squash when all requirements are met","exit_code":0}}'
printf '%s' "$AUTO_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
# #664: GitHub ACCEPTED the merge and will land it with no further hook event,
# so the token is spent here — preserving it left a spent bypass armed for a
# second merge. (Was: released-auto-queued, skip preserved.)
if [ ! -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  --auto accepted → token spent, not left armed\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  --auto case: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B11. Malformed pending file (non-numeric mtime / corrupt content) →
#      released-malformed without consuming the skip file.
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf 'skip_mtime=not-a-number\nmerge_pr=DROP TABLE users;\nclaimed_at=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$BYPASS_PENDING"
printf '%s' "$SUCCESS_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  malformed pending → released-malformed, skip preserved\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  malformed case: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B12. Stale-cleanup ordering: a >5min-old pending claim must NOT be
#      cleaned up when the current Bash call IS gh pr merge — the merge
#      processing must take priority. (Cleanup is for crash-recovery on
#      unrelated bash calls only.)
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf 'skip_mtime=%s\nmerge_pr=42\nclaimed_at=%s\n' \
    "$(stat -c %Y "$SKIP_FILE" 2>/dev/null || stat -f %m "$SKIP_FILE" 2>/dev/null)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$BYPASS_PENDING"
# Make pending file >5min old (10 min)
touch -t "$(date -v-10M '+%Y%m%d%H%M.%S')" "$BYPASS_PENDING" 2>/dev/null \
    || touch -d "10 minutes ago" "$BYPASS_PENDING" 2>/dev/null || true
# Run hook with gh pr merge → cleanup must NOT fire here; the success path
# must process the merge normally (skip + pending consumed).
printf '%s' "$SUCCESS_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ ! -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  stale pending on gh-pr-merge call → merge processed (not cleaned)\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  stale ordering: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B14. Stricter PR equality: claim with merge_pr=unknown must NOT
#      authorize consumption even on a success-pattern merge. The
#      auto-detect path is rejected to prevent cross-PR token reuse via
#      branch-switching between claim and confirm.
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf 'skip_mtime=%s\nmerge_pr=unknown\nclaimed_at=%s\n' \
    "$(stat -c %Y "$SKIP_FILE" 2>/dev/null || stat -f %m "$SKIP_FILE" 2>/dev/null)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$BYPASS_PENDING"
printf '%s' "$SUCCESS_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  unknown-PR claim + success → released-mismatch, skip preserved\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  unknown-PR case: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B15a. Log-injection defense via merge_pr (round-3 fix): if a forged
#       pending file contains a malformed merge_pr (non-numeric/non-unknown)
#       with embedded JSON-fragment text, the malformed branch must also
#       suppress merge_pr in the log (mirroring the claimed_at fix).
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf 'skip_mtime=%s\nmerge_pr=42","event":"INJECTED-VIA-PR\nclaimed_at=%s\n' \
    "$(stat -c %Y "$SKIP_FILE" 2>/dev/null || stat -f %m "$SKIP_FILE" 2>/dev/null)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$BYPASS_PENDING"
LOG_LINES_BEFORE_B15A=$(wc -l < .claude/bypass-log.jsonl 2>/dev/null || echo 0)
printf '%s' "$SUCCESS_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  log-injection in merge_pr → released-malformed, skip preserved\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  merge_pr injection: skip=%s pending=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
LOG_LINES_AFTER_B15A=$(wc -l < .claude/bypass-log.jsonl 2>/dev/null || echo 0)
LAST_LOG=$(tail -1 .claude/bypass-log.jsonl 2>/dev/null || true)
TOTAL=$((TOTAL + 1))
if [ "$LOG_LINES_AFTER_B15A" -gt "$LOG_LINES_BEFORE_B15A" ] \
    && printf '%s' "$LAST_LOG" | grep -q 'released-malformed' \
    && ! printf '%s' "$LAST_LOG" | grep -q '"event":"INJECTED-VIA-PR"'; then
    printf "  PASS  log line preserves framing on merge_pr injection\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  merge_pr injection escaped into log (lines before=%s after=%s): %s\n" \
        "$LOG_LINES_BEFORE_B15A" "$LOG_LINES_AFTER_B15A" "$LAST_LOG"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B15. Log-injection defense: claimed_at containing JSON-fragment text
#      must be rejected as malformed (preserves bypass-log.jsonl integrity).
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf 'skip_mtime=%s\nmerge_pr=42\nclaimed_at=2026-05-20T02:00:00Z","event":"INJECTED\n' \
    "$(stat -c %Y "$SKIP_FILE" 2>/dev/null || stat -f %m "$SKIP_FILE" 2>/dev/null)" \
    > "$BYPASS_PENDING"
LOG_LINES_BEFORE_B15=$(wc -l < .claude/bypass-log.jsonl 2>/dev/null || echo 0)
printf '%s' "$SUCCESS_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  log-injection in claimed_at → released-malformed, skip preserved\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  log-injection case: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
# Verify the bypass-log line for this injection attempt does NOT contain
# the injected fragment in a JSON-key position. Assert a new line was
# appended first, then validate the last line content.
LOG_LINES_AFTER_B15=$(wc -l < .claude/bypass-log.jsonl 2>/dev/null || echo 0)
LAST_LOG=$(tail -1 .claude/bypass-log.jsonl 2>/dev/null || true)
TOTAL=$((TOTAL + 1))
if [ "$LOG_LINES_AFTER_B15" -gt "$LOG_LINES_BEFORE_B15" ] \
    && printf '%s' "$LAST_LOG" | grep -q 'released-malformed' \
    && ! printf '%s' "$LAST_LOG" | grep -q '"event":"INJECTED"'; then
    printf "  PASS  log line preserves JSONL framing (no injected event key)\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  log injection detected (lines before=%s after=%s): %s\n" \
        "$LOG_LINES_BEFORE_B15" "$LOG_LINES_AFTER_B15" "$LAST_LOG"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B13. Stale-cleanup correctness: a >5min-old pending claim IS cleaned up
#      when the current Bash call is unrelated (not gh pr merge). Skip
#      file is preserved (cleanup only releases the claim, not the skip).
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf 'skip_mtime=%s\nmerge_pr=42\nclaimed_at=%s\n' \
    "$(stat -c %Y "$SKIP_FILE" 2>/dev/null || stat -f %m "$SKIP_FILE" 2>/dev/null)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$BYPASS_PENDING"
touch -t "$(date -v-10M '+%Y%m%d%H%M.%S')" "$BYPASS_PENDING" 2>/dev/null \
    || touch -d "10 minutes ago" "$BYPASS_PENDING" 2>/dev/null || true
UNRELATED_BASH='{"tool_name":"Bash","tool_input":{"command":"ls -la"},"tool_output":{"output":"total 8\n","exit_code":0}}'
printf '%s' "$UNRELATED_BASH" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  stale pending on unrelated bash → force-cleaned, skip preserved\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  stale cleanup: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# ── #664: consume on an API-confirmed merge, not on CLI chatter ────────
# `gh pr merge` prints "✓ Squashed and merged pull request #N" only on a TTY,
# and under the Claude Code Bash tool stdout never is — so a SUCCESSFUL
# agent-driven merge produced no output at all and classified as `ambiguous`,
# leaving the spent skip file armed for the rest of its 3600s window. These
# fixtures drive the exact shape the harness produces (exit 0, empty output).
arm_skip_and_claim() {
    # Args: claimed_pr. Arms a 2-minute-old skip file + a matching claim.
    touch "$SKIP_FILE"
    touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
        || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
    printf 'skip_mtime=%s\nmerge_pr=%s\nclaimed_at=%s\n' \
        "$(stat -c %Y "$SKIP_FILE" 2>/dev/null || stat -f %m "$SKIP_FILE" 2>/dev/null)" \
        "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$BYPASS_PENDING"
}

# Exit 0, ZERO output — the real non-TTY success shape from issue #664.
SILENT_SUCCESS_INPUT='{"tool_name":"Bash","tool_input":{"command":"gh pr merge 42 --squash --delete-branch"},"tool_output":{"output":"","exit_code":0}}'
# Exit 1, unmatched output — `--delete-branch` hit a post-merge worktree
# checkout conflict AFTER the remote already merged (empirical, PR #98).
DELETE_BRANCH_CONFLICT_INPUT='{"tool_name":"Bash","tool_input":{"command":"gh pr merge 42 --squash --delete-branch"},"tool_output":{"output":"failed to delete local branch fix/x: worktree is checked out","exit_code":1}}'

# B16. THE REGRESSION: silent success + GitHub says MERGED → must consume.
#      Fails if a successful merge leaves the skip file armed.
arm_skip_and_claim 42
GH_STUB_PR_STATE=MERGED
export GH_STUB_PR_STATE
printf '%s' "$SILENT_SUCCESS_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
unset GH_STUB_PR_STATE
TOTAL=$((TOTAL + 1))
LAST_LOG=$(tail -1 "$MARKER_DIR/bypass-log.jsonl" 2>/dev/null || true)
if [ ! -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ] \
    && printf '%s' "$LAST_LOG" | grep -q 'skip-pr-grind-consumed' \
    && printf '%s' "$LAST_LOG" | grep -q 'github-api-state-merged'; then
    printf "  PASS  #664 silent success + API MERGED → skip consumed\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  #664 silent success left skip armed: skip exists=%s pending exists=%s log=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)" "$LAST_LOG"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B17. Boundary: same silent output, but the PR is NOT merged (still OPEN)
#      → the API must NOT promote it. Skip preserved, fail-safe intact.
arm_skip_and_claim 42
GH_STUB_PR_STATE=OPEN
export GH_STUB_PR_STATE
printf '%s' "$SILENT_SUCCESS_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
unset GH_STUB_PR_STATE
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  #664 silent output + API OPEN → skip preserved (fail-safe)\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  #664 OPEN case wrongly consumed: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B18. Sibling path: gh exited NON-ZERO (--delete-branch worktree conflict)
#      but the remote merged → the exit code must not keep the token armed.
arm_skip_and_claim 42
GH_STUB_PR_STATE=MERGED
export GH_STUB_PR_STATE
printf '%s' "$DELETE_BRANCH_CONFLICT_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
unset GH_STUB_PR_STATE
TOTAL=$((TOTAL + 1))
if [ ! -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  #664 non-zero exit + API MERGED → skip consumed\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  #664 delete-branch-conflict left skip armed: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B19. Cross-PR reuse stays refused: the API answer for the CLAIMED PR must
#      never rescue a command that merged a DIFFERENT PR.
arm_skip_and_claim 42
GH_STUB_PR_STATE=MERGED
export GH_STUB_PR_STATE
OTHER_PR_SILENT='{"tool_name":"Bash","tool_input":{"command":"gh pr merge 99 --squash"},"tool_output":{"output":"","exit_code":0}}'
printf '%s' "$OTHER_PR_SILENT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
unset GH_STUB_PR_STATE
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  #664 API check refuses cross-PR promotion\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  #664 cross-PR: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B20. --auto with the PR still OPEN — the queue has NOT landed yet and nothing
#      later will report it (no second PostToolUse event fires when GitHub
#      merges). The token must be spent now rather than left armed, and the
#      reason must say it was the queue, never a confirmed merge.
arm_skip_and_claim 42
GH_STUB_PR_STATE=OPEN
export GH_STUB_PR_STATE
printf '%s' "$AUTO_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
unset GH_STUB_PR_STATE
TOTAL=$((TOTAL + 1))
LAST_LOG=$(tail -1 "$MARKER_DIR/bypass-log.jsonl" 2>/dev/null || true)
if [ ! -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ] \
    && printf '%s' "$LAST_LOG" | grep -q 'auto-merge-accepted-token-spent'; then
    printf "  PASS  #664 --auto accepted while PR still OPEN → token spent\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  #664 auto-queued left skip armed: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B21. Cross-repo merge (literal selector): the operator skip path is
#      deliberately NOT covered by the gate's cross-repo guard, so a claimed
#      merge can target another repo — where PR 42 is a different pull request.
#      This checkout's PR 42 must not decide the outcome in EITHER direction —
#      local state says MERGED here and must be ignored. The authorization was
#      spent somewhere this hook cannot see, so the token is SPENT rather than
#      left armed for the rest of the hour, and the reason must say so instead
#      of claiming a confirmed merge.
for _xrepo in \
    "gh pr merge 42 --squash -R other/repo" \
    "gh pr merge 42 --squash --repo=other/repo" \
    "GH_REPO=other/repo gh pr merge 42 --squash"; do
arm_skip_and_claim 42
GH_STUB_PR_STATE=MERGED
export GH_STUB_PR_STATE
_INPUT=$(python3 -c "import json,sys; print(json.dumps({'tool_name':'Bash','tool_input':{'command':sys.argv[1]},'tool_output':{'output':'','exit_code':0}}))" "$_xrepo")
printf '%s' "$_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
unset GH_STUB_PR_STATE
TOTAL=$((TOTAL + 1))
LAST_LOG=$(tail -1 "$MARKER_DIR/bypass-log.jsonl" 2>/dev/null || true)
if [ ! -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ] \
    && printf '%s' "$LAST_LOG" | grep -q 'cross-repo-merge-unverifiable-token-spent'; then
    printf "  PASS  #664 cross-repo merge → token spent, not left armed: %s\n" "$_xrepo"
    PASS=$((PASS + 1))
else
    printf "  FAIL  #664 cross-repo merge ('%s'): skip exists=%s log=%s\n" \
        "$_xrepo" "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" "$LAST_LOG"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"
done

# B23. The override precondition must not swallow ordinary same-repo commands.
#      Slash-bearing text is everywhere — a cd prefix, a redirect target, a
#      sibling command — and a coarse owner/repo-SHAPE test (tried, reverted)
#      spent the token on genuinely FAILED merges because of it. These shapes
#      must still reach the authoritative query (API says OPEN → skip preserved,
#      the retry reprieve deferred consumption exists for).
for _cmd in \
    "gh pr merge 42 --squash --delete-branch" \
    "cd owner/repo && gh pr merge 42 --squash" \
    "gh pr merge 42 --squash 2>logs/merge.err" \
    "gh pr merge 42 --squash || echo owner/repo"; do
arm_skip_and_claim 42
GH_STUB_PR_STATE=OPEN
export GH_STUB_PR_STATE
_INPUT=$(python3 -c "import json,sys; print(json.dumps({'tool_name':'Bash','tool_input':{'command':sys.argv[1]},'tool_output':{'output':'','exit_code':0}}))" "$_cmd")
printf '%s' "$_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
unset GH_STUB_PR_STATE
TOTAL=$((TOTAL + 1))
LAST_LOG=$(tail -1 "$MARKER_DIR/bypass-log.jsonl" 2>/dev/null || true)
# Assert only what this case is about — the skip file survives and no override
# path fired. Pending-claim placement varies with cd-prefix repo resolution,
# which tests/test-pre-merge-gate.sh covers separately.
if [ -f "$SKIP_FILE" ] \
    && ! printf '%s' "$LAST_LOG" | grep -q 'cross-repo-merge-unverifiable-token-spent'; then
    printf "  PASS  #664 ordinary shape keeps the retry reprieve: %s\n" "$_cmd"
    PASS=$((PASS + 1))
else
    printf "  FAIL  #664 override supplement over-triggered on '%s': skip exists=%s log=%s\n" \
        "$_cmd" "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" "$LAST_LOG"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"
done

# ── #672: the ambiguous fail-safe must say WHICH evidence path failed ──
# The reported occurrences (PR #670, and chrisyau.me #272 below) were real
# successful merges whose "Squashed and merged" confirmation gh prints only to a
# TTY: stdout carried nothing but the --delete-branch local fast-forward
# housekeeping. #664/#709 made those consume via the API. What stayed broken is
# the audit trail: every ambiguous release logged one string, so "GitHub says it
# did not merge" (nothing to do) and "nobody could answer, so a possibly-spent
# token is still armed on disk" (delete it by hand) were indistinguishable.
#
# Verbatim stdout from the second occurrence in the issue.
FF_ONLY_TEXT=$(cat <<'FFEOF'
From https://github.com/Dive-And-Dev/chrisyau.me
 * branch            main       -> FETCH_HEAD
   60ddcb2..53968e7  main       -> origin/main
Updating 60ddcb2..53968e7
Fast-forward
 .github/lighthouse.baseline.json | 14 +++++++-------
 1 file changed, 7 insertions(+), 7 deletions(-)
FFEOF
)
FF_ONLY_INPUT=$(printf '%s' "$FF_ONLY_TEXT" | python3 -c "
import json, sys
print(json.dumps({
    'tool_name': 'Bash',
    'tool_input': {'command': 'gh pr merge 42 --squash --delete-branch --match-head-commit ed5be327ffe2fc4c49b570a9835b853c03ae73b7'},
    'tool_output': {'output': sys.stdin.read(), 'exit_code': 0},
}))")

# B24. The exact shape from the issue, merge confirmed by the API → consumed.
arm_skip_and_claim 42
GH_STUB_PR_STATE=MERGED
export GH_STUB_PR_STATE
printf '%s' "$FF_ONLY_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
unset GH_STUB_PR_STATE
TOTAL=$((TOTAL + 1))
if [ ! -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  #672 fast-forward-only output + API MERGED → skip consumed\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  #672 fast-forward-only output left skip armed: skip exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B25-B27. Same shape, no confirmation available → skip preserved (the fail-safe
# is unchanged), but the reason must name the evidence path that failed.
for _case in \
    ":github-api-unreachable-merge-state-unknown" \
    "OPEN:github-api-says-not-merged" \
    "WEIRD:github-api-answer-unrecognized"; do
_state="${_case%%:*}"
_want="${_case#*:}"
arm_skip_and_claim 42
GH_STUB_PR_STATE="$_state"
export GH_STUB_PR_STATE
printf '%s' "$FF_ONLY_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
unset GH_STUB_PR_STATE
TOTAL=$((TOTAL + 1))
LAST_LOG=$(tail -1 "$MARKER_DIR/bypass-log.jsonl" 2>/dev/null || true)
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ] \
    && printf '%s' "$LAST_LOG" | grep -q 'skip-pr-grind-released-ambiguous' \
    && printf '%s' "$LAST_LOG" | grep -q "\"reason\":\"$_want\""; then
    printf "  PASS  #672 ambiguous release names its cause: %s\n" "$_want"
    PASS=$((PASS + 1))
else
    printf "  FAIL  #672 expected reason %s, got: %s\n" "$_want" "$LAST_LOG"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"
done

# B28. No explicit PR on the command → the query never runs, and the reason must
#      say so rather than blame the output patterns.
arm_skip_and_claim unknown
GH_STUB_PR_STATE=MERGED
export GH_STUB_PR_STATE
NO_PR_INPUT='{"tool_name":"Bash","tool_input":{"command":"gh pr merge --squash --delete-branch"},"tool_output":{"output":"","exit_code":0}}'
printf '%s' "$NO_PR_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
unset GH_STUB_PR_STATE
TOTAL=$((TOTAL + 1))
LAST_LOG=$(tail -1 "$MARKER_DIR/bypass-log.jsonl" 2>/dev/null || true)
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ] \
    && printf '%s' "$LAST_LOG" | grep -q 'github-api-not-queried-pr-not-explicitly-known'; then
    printf "  PASS  #672 unqueryable claim names the missing precondition\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  #672 unqueryable claim: skip exists=%s pending exists=%s log=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)" "$LAST_LOG"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B29. Both sides name a concrete PR but they DIFFER, with no evidence path
#      reached (no explicit -R/--repo override, PR mismatch caught before the
#      query runs) → must be distinguished from B28's "neither side known"
#      case, not folded into the same reason string (#672 follow-up, Codex +
#      Cursor Bugbot review on PR #717).
arm_skip_and_claim 42
GH_STUB_PR_STATE=MERGED
export GH_STUB_PR_STATE
MISMATCH_INPUT='{"tool_name":"Bash","tool_input":{"command":"gh pr merge 99 --squash --delete-branch"},"tool_output":{"output":"random unmatched text","exit_code":0}}'
printf '%s' "$MISMATCH_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
unset GH_STUB_PR_STATE
TOTAL=$((TOTAL + 1))
LAST_LOG=$(tail -1 "$MARKER_DIR/bypass-log.jsonl" 2>/dev/null || true)
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ] \
    && printf '%s' "$LAST_LOG" | grep -q 'github-api-not-queried-pr-mismatch-claimed-42-parsed-99'; then
    printf "  PASS  #672 claimed-vs-parsed PR mismatch names both PRs, not a missing-PR reason\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  #672 mismatch reason: skip exists=%s pending exists=%s log=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)" "$LAST_LOG"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# ═══════════════════════════════════════════════════════════════════════
# POST-PR-CREATED HOOK TESTS
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "── post-bash-pr-created ────────────────────────────────────"

# 8. Appends instruction on PR creation
run_hook_test "appends pr-grind instruction on PR creation" "PR Grind Required" \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr create --title test"},"tool_output":{"output":"https://github.com/owner/repo/pull/42\n"}}'

# 9. Passes through non-PR commands
run_hook_test "passes through non-PR commands" "npm install" \
    '{"tool_name":"Bash","tool_input":{"command":"npm install"},"tool_output":{"output":"added 5 packages\n"}}'

# 10. Passes through failed PR creation (no URL in output)
run_hook_test "passes through failed PR creation" "error creating" \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr create --title test"},"tool_output":{"output":"error creating pull request\n"}}'

# 11. Writes pending marker
rm -f "$PENDING_MARKER"
CLAUDE_PLUGIN_ROOT="$(pwd)" node -e "
    const m = require('./$HOOK_SCRIPT');
    m.run(JSON.stringify({tool_name:'Bash',tool_input:{command:'gh pr create --title test'},tool_output:{output:'https://github.com/owner/repo/pull/99\n'}}));
" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$PENDING_MARKER" ]; then
    printf "  PASS  writes pr-pending-grind.local on PR creation\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  writes pr-pending-grind.local on PR creation\n"
    FAIL=$((FAIL + 1))
fi
rm -f "$PENDING_MARKER"

# 12. Invalidates stale clean marker on new PR creation
echo "old-pr" > "$CLEAN_MARKER"
CLAUDE_PLUGIN_ROOT="$(pwd)" node -e "
    const m = require('./$HOOK_SCRIPT');
    m.run(JSON.stringify({tool_name:'Bash',tool_input:{command:'gh pr create --title test'},tool_output:{output:'https://github.com/owner/repo/pull/99\n'}}));
" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ ! -f "$CLEAN_MARKER" ]; then
    printf "  PASS  invalidates stale pr-grind-clean.local on new PR\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  invalidates stale pr-grind-clean.local on new PR\n"
    FAIL=$((FAIL + 1))
fi
rm -f "$CLEAN_MARKER" "$PENDING_MARKER"

# ═══════════════════════════════════════════════════════════════════════
# REQUIRED-CHECKS ALLOWLIST TESTS
# ═══════════════════════════════════════════════════════════════════════
# Exercises _relevant_check_counts directly with synthetic gh pr checks
# text + synthetic .github/required-checks.lock files in tmpdirs. The
# helper drives both fail-counting sites in the gate, so unit-testing it
# covers the marker-path and bootstrap paths equivalently.
echo ""
echo "── required-checks allowlist ───────────────────────────────"

# The filter logic now lives in scripts/relevant-check-status.sh (issue #154);
# its full edge-case unit coverage is in tests/test-relevant-check-status.sh.
# Here we drive it through the SAME gate-relative path the gate's wrapper uses,
# so R1-R8 double as gate↔helper integration tests (path resolution + argument
# passing + line-1 parse). No more sed/eval of the gate's function body — that
# body is now a thin wrapper, and eval'ing it here would mis-resolve
# ${BASH_SOURCE[0]} to this test file instead of the gate.
export BUSDRIVER_DISABLE_RELEVANT_CHECK_SELF_RESOLVE=1  # test the working copy deterministically
HELPER="$(cd "$(dirname "$GATE_SCRIPT")" && pwd -P)/../../scripts/relevant-check-status.sh"
TOTAL=$((TOTAL + 1))
# Read non-comment lines into a var first, then match via a here-string. Piping
# `grep -vE … | grep -q …` is fragile under `set -o pipefail`: `grep -q`
# short-circuits on the first match and SIGPIPEs the upstream grep (exit 141),
# which pipefail surfaces as a whole-pipeline failure (seen only on GNU grep,
# where the short-circuit wins the race). A here-string has no upstream to break.
GATE_BODY=$(grep -vE '^\s*#' "$GATE_SCRIPT" || true)
if [ -f "$HELPER" ] \
    && grep -q 'relevant-check-status\.sh' <<< "$GATE_BODY" \
    && ! grep -q 'import sys, os, json, re' "$GATE_SCRIPT"; then
    printf "  PASS  gate wired to relevant-check-status.sh (inline python removed)\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  gate not wired to helper, or inline python still present\n"
    FAIL=$((FAIL + 1))
fi
# Local wrapper mirrors the gate's _relevant_check_counts() invocation: it calls
# $HELPER (the same script the gate delegates to) with the same args the gate
# passes. `head -n1` keeps only the count line (the helper appends failing rows
# on lines 2..N, which the gate's `read <<<` ignores).
# Note: sourcing the full gate script to call its wrapper is not feasible here
# because the gate's main body runs at source time. Since _relevant_check_counts
# in the gate is a thin wrapper that just calls $HELPER, calling $HELPER directly
# is equivalent and avoids side-effects.
_relevant_check_counts() { bash "$HELPER" "$1" "CodeScene" 2>/dev/null | head -n1; }

# Synthetic CI output mirrors gh pr checks text: tab-separated columns,
# first column = check name. Same shape regardless of pass/fail mix.
SYNTH_CHECKS=$(printf 'shellcheck\tpass\t5s\thttps://x\ncommitlint\tfail\t3s\thttps://x\nCodeScene\tfail\t10s\thttps://x\nbuild\tpending\t1m\thttps://x\n')

# R1. Lock present + required[] includes only "shellcheck" → commitlint fail
#     is NOT counted (not in required), build pending NOT counted, CodeScene
#     fail NOT counted. Expected: 0 fail, 0 pending, mode=required.
REPO_R1=$(mktemp -d)
mkdir -p "$REPO_R1/.github"
printf '%s' '{"required":[{"name":"shellcheck"}]}' > "$REPO_R1/.github/required-checks.lock"
OUT=$(printf '%s' "$SYNTH_CHECKS" | _relevant_check_counts "$REPO_R1")
TOTAL=$((TOTAL + 1))
if [[ "$OUT" = "0 0 required 1" ]]; then
    printf "  PASS  allowlist filters out non-required failures\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  allowlist non-required filter (got '%s', want '0 0 required 1')\n" "$OUT"
    FAIL=$((FAIL + 1))
fi
rm -rf "$REPO_R1"

# R2. Lock present + required[] includes "commitlint" → commitlint fail
#     IS counted. Expected: 1 fail, 0 pending, mode=required.
REPO_R2=$(mktemp -d)
mkdir -p "$REPO_R2/.github"
printf '%s' '{"required":[{"name":"commitlint"}]}' > "$REPO_R2/.github/required-checks.lock"
OUT=$(printf '%s' "$SYNTH_CHECKS" | _relevant_check_counts "$REPO_R2")
TOTAL=$((TOTAL + 1))
if [[ "$OUT" = "1 0 required 1" ]]; then
    printf "  PASS  allowlist counts required failures\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  allowlist counts required failures (got '%s', want '1 0 required 1')\n" "$OUT"
    FAIL=$((FAIL + 1))
fi
rm -rf "$REPO_R2"

# R3. Lock present + required[] includes "build" (pending) → 0 fail, 1 pending.
REPO_R3=$(mktemp -d)
mkdir -p "$REPO_R3/.github"
printf '%s' '{"required":[{"name":"build"}]}' > "$REPO_R3/.github/required-checks.lock"
OUT=$(printf '%s' "$SYNTH_CHECKS" | _relevant_check_counts "$REPO_R3")
TOTAL=$((TOTAL + 1))
if [[ "$OUT" = "0 1 required 1" ]]; then
    printf "  PASS  allowlist counts required pending checks\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  allowlist required pending (got '%s', want '0 1 required 1')\n" "$OUT"
    FAIL=$((FAIL + 1))
fi
rm -rf "$REPO_R3"

# R4. Lock missing → fallback to ADVISORY_PATTERN filter. CodeScene fail
#     is dropped, commitlint fail counted, build pending counted.
#     Expected: 1 fail, 1 pending, mode=all.
REPO_R4=$(mktemp -d)
OUT=$(printf '%s' "$SYNTH_CHECKS" | _relevant_check_counts "$REPO_R4")
TOTAL=$((TOTAL + 1))
if [[ "$OUT" = "1 1 all 3" ]]; then
    printf "  PASS  no lock file → ADVISORY_PATTERN fallback\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  no-lock fallback (got '%s', want '1 1 all 3')\n" "$OUT"
    FAIL=$((FAIL + 1))
fi
rm -rf "$REPO_R4"

# R5. Malformed lock (invalid JSON) → fallback to ADVISORY_PATTERN.
REPO_R5=$(mktemp -d)
mkdir -p "$REPO_R5/.github"
printf '%s' 'not valid json{' > "$REPO_R5/.github/required-checks.lock"
OUT=$(printf '%s' "$SYNTH_CHECKS" | _relevant_check_counts "$REPO_R5")
TOTAL=$((TOTAL + 1))
if [[ "$OUT" = "1 1 all 3" ]]; then
    printf "  PASS  malformed lock → ADVISORY_PATTERN fallback\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  malformed-lock fallback (got '%s', want '1 1 all 3')\n" "$OUT"
    FAIL=$((FAIL + 1))
fi
rm -rf "$REPO_R5"

# R6. Empty required[] → fallback (no allowlist means "no opinion", not
#     "allow everything"). Same as R4 expectation.
REPO_R6=$(mktemp -d)
mkdir -p "$REPO_R6/.github"
printf '%s' '{"required":[]}' > "$REPO_R6/.github/required-checks.lock"
OUT=$(printf '%s' "$SYNTH_CHECKS" | _relevant_check_counts "$REPO_R6")
TOTAL=$((TOTAL + 1))
if [[ "$OUT" = "1 1 all 3" ]]; then
    printf "  PASS  empty required[] → ADVISORY_PATTERN fallback\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  empty-required fallback (got '%s', want '1 1 all 3')\n" "$OUT"
    FAIL=$((FAIL + 1))
fi
rm -rf "$REPO_R6"

# R7a. Whitespace-padded names in required[] still match. Lock files
#      written by hand or pasted from CI logs can carry stray spaces;
#      without normalization the allowlist silently misses the real
#      failure → fail-open. (Regression test for the .strip() inside
#      the python helper.)
REPO_R7A=$(mktemp -d)
mkdir -p "$REPO_R7A/.github"
printf '%s' '{"required":[{"name":"  shellcheck  "}]}' > "$REPO_R7A/.github/required-checks.lock"
OUT=$(printf 'shellcheck\tfail\t5s\thttps://x\n' | _relevant_check_counts "$REPO_R7A")
TOTAL=$((TOTAL + 1))
if [[ "$OUT" = "1 0 required 1" ]]; then
    printf "  PASS  required[] names with padding strip-match\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  whitespace-padded name match (got '%s', want '1 0 required 1')\n" "$OUT"
    FAIL=$((FAIL + 1))
fi
rm -rf "$REPO_R7A"

# R7b. Status column parsing — a passing check whose URL contains "fail"
#      (e.g. /actions/runs/.../fail-handler) must NOT be miscounted as
#      failed. Pre-fix the helper substring-scanned the whole line.
REPO_R7B=$(mktemp -d)
mkdir -p "$REPO_R7B/.github"
printf '%s' '{"required":[{"name":"shellcheck"}]}' > "$REPO_R7B/.github/required-checks.lock"
URL_TRAP=$(printf 'shellcheck\tpass\t5s\thttps://github.com/owner/repo/actions/runs/12345/job/fail-handler\n')
OUT=$(printf '%s' "$URL_TRAP" | _relevant_check_counts "$REPO_R7B")
TOTAL=$((TOTAL + 1))
if [[ "$OUT" = "0 0 required 1" ]]; then
    printf "  PASS  status column parsing ignores 'fail' in URL column\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  URL substring false-positive (got '%s', want '0 0 required 1')\n" "$OUT"
    FAIL=$((FAIL + 1))
fi
rm -rf "$REPO_R7B"

# R7c. Lock has multi-word check name ("Actions security") → exact-match
#      against first tab-separated column handles spaces correctly.
REPO_R7C=$(mktemp -d)
mkdir -p "$REPO_R7C/.github"
printf '%s' '{"required":[{"name":"Actions security"}]}' > "$REPO_R7C/.github/required-checks.lock"
MULTI_CHECKS=$(printf 'Actions security\tfail\t8s\thttps://x\nshellcheck\tpass\t5s\thttps://x\n')
OUT=$(printf '%s' "$MULTI_CHECKS" | _relevant_check_counts "$REPO_R7C")
TOTAL=$((TOTAL + 1))
if [[ "$OUT" = "1 0 required 1" ]]; then
    printf "  PASS  allowlist matches multi-word check names\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  multi-word match (got '%s', want '1 0 required 1')\n" "$OUT"
    FAIL=$((FAIL + 1))
fi
rm -rf "$REPO_R7C"

# R8. Empty stdin → kept count is 0. Bootstrap path uses this to refuse a
#     bootstrap-merge when no relevant checks ran at all (defends against
#     a gate-modifying PR that also disables CI).
#     pending=1 (not 0) since #515: the lock's one required check reported no
#     row, and a non-reporting required check is unarrived evidence. kept=0 —
#     the signal this case actually asserts — is unchanged.
REPO_R8=$(mktemp -d)
mkdir -p "$REPO_R8/.github"
printf '%s' '{"required":[{"name":"shellcheck"}]}' > "$REPO_R8/.github/required-checks.lock"
OUT=$(printf '' | _relevant_check_counts "$REPO_R8")
TOTAL=$((TOTAL + 1))
if [[ "$OUT" = "0 1 required 0" ]]; then
    printf "  PASS  empty stdin → kept=0 (bootstrap fail-safe signal)\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  empty-stdin kept count (got '%s', want '0 1 required 0')\n" "$OUT"
    FAIL=$((FAIL + 1))
fi
rm -rf "$REPO_R8"

# ═══════════════════════════════════════════════════════════════════════
# MATCHER HARDENING: whitespace/prefix bypass regression (Task 1)
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "── pre-merge-gate whitespace/prefix bypass ─────────────────"
rm -f "$CLEAN_MARKER" "$SKIP_FILE" "$PENDING_MARKER" "$BYPASS_PENDING"

# Double space defeated the literal-single-space pre-filter (*gh\ pr\ merge*),
# skipping the parser entirely → early exit 0 (allow). Now *gh*pr*merge*.
run_gate_test "blocks 'gh  pr  merge' (double-space pre-filter bypass)" "block" \
    '{"tool_name":"Bash","tool_input":{"command":"gh  pr  merge 31 --squash"}}'
# Wrapper prefix: the parser already used whole-command re.findall, so this was
# blocked pre-fix too — asserted here to lock in cross-gate detection parity.
run_gate_test "blocks 'command gh pr merge' (wrapper prefix)" "block" \
    '{"tool_name":"Bash","tool_input":{"command":"command gh pr merge 31 --squash"}}'

# ═══════════════════════════════════════════════════════════════════════
# POST-MERGE-CONFIRM detection: prose must NOT be treated as a merge (Task 1)
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "── post-merge-confirm-bypass prose vs command ──────────────"
PMCB="hooks/gate-scripts/post-merge-confirm-bypass.sh"
# Setup a scratch repo with a STALE pending file, run the post-merge hook on it,
# and report whether stale-cleanup fired. Stale-cleanup only runs when detection
# says NOT-a-merge, so it is a clean proxy for the is_merge decision against the
# real script: prose → cleanup fires; real command-word merge → cleanup skipped.
pmcb_stale_cleanup_fired() {
    local cmd="$1" tmp input
    tmp=$(mktemp -d)
    git -C "$tmp" init -q
    mkdir -p "$tmp/.claude"
    echo "merge_pr=5" > "$tmp/.claude/.merge-bypass-pending.local"
    touch -t "$(date -v-10M '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '10 minutes ago' '+%Y%m%d%H%M.%S')" \
        "$tmp/.claude/.merge-bypass-pending.local" 2>/dev/null || true
    input=$(python3 -c "import json,sys; print(json.dumps({'tool_name':'Bash','tool_input':{'command':sys.argv[1]},'cwd':sys.argv[2]}))" "$cmd" "$tmp")
    printf '%s' "$input" | bash "$PMCB" >/dev/null 2>&1 || true
    if grep -q 'merge-bypass-stale-cleanup' "$tmp/.claude/bypass-log.jsonl" 2>/dev/null; then echo yes; else echo no; fi
    rm -rf "$tmp"
}
_pmcb_prose=$(pmcb_stale_cleanup_fired 'echo gh pr merge 5')
TOTAL=$((TOTAL + 1))
if [[ "$_pmcb_prose" == "yes" ]]; then
    printf "  PASS  prose 'echo gh pr merge 5' not treated as merge\n"; PASS=$((PASS + 1))
else
    printf "  FAIL  prose treated as merge (stale-cleanup did not fire, got=%s)\n" "$_pmcb_prose"; FAIL=$((FAIL + 1))
fi
_pmcb_real=$(pmcb_stale_cleanup_fired 'command gh pr merge 5')
TOTAL=$((TOTAL + 1))
if [[ "$_pmcb_real" == "no" ]]; then
    printf "  PASS  'command gh pr merge 5' recognized as merge\n"; PASS=$((PASS + 1))
else
    printf "  FAIL  command-prefixed merge not recognized (got=%s)\n" "$_pmcb_real"; FAIL=$((FAIL + 1))
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
