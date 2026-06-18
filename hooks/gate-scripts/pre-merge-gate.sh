#!/usr/bin/env bash
# PreToolUse hook: gate `gh pr merge` on pr-grind completion
#
# Blocks PR merge until pr-grind has declared the PR clean.
# This ensures reviewer feedback is addressed before merge,
# regardless of which skill the agent loaded.
#
# Fail-CLOSED: errors block merge (user preference: stuck > skipped grind)
# Skip: $STATE_DIR/skip-pr-grind.local (or SKIP_PR_GRIND=1 exported in parent
#       shell before `claude` starts — inline `SKIP_PR_GRIND=1 gh pr merge`
#       does NOT work because PreToolUse hooks fire before the command's
#       inline env is applied)

set -euo pipefail
# ── Harness-portable root/state resolution ─────────────────────────────
# BUSDRIVER_PLUGIN_ROOT: set by opencode adapter; CLAUDE_PLUGIN_ROOT by Claude Code.
# Falls back to relative path from this script's location.
# BUSDRIVER_STATE_DIR: .opencode for opencode, .claude for Claude Code (default).
PLUGIN_ROOT="${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
trap 'printf "{\"decision\":\"block\",\"reason\":\"Pre-merge gate error — blocking as precaution. If stuck, create '"$STATE_DIR"'/skip-pr-grind.local in your terminal.\"}\n"; exit 0' ERR

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

# ── Required-checks allowlist (with advisory-pattern fallback) ───────
# When <repo>/.github/required-checks.lock exists and declares
# `required[].name`, only failures of those checks block this gate.
# This is the helmet drift-detector's source-of-truth registry and
# matches what GitHub branch protection actually enforces — advisory
# failures still get surfaced through pr-grind feedback but do not
# block merge. Without this filter the gate was strictly stronger
# than branch protection itself, blocking on checks GitHub would
# happily ignore (e.g. commitlint failures on commits the squash
# would discard).
#
# Fallback (no lock file or empty `required[]`): strip names matching
# ADVISORY_PATTERN, then count FAIL/PENDING on the remainder. This
# preserves pre-fix behavior for repos that haven't adopted the lock.
ADVISORY_PATTERN="CodeScene"

_relevant_check_counts() {
    # filter logic: see scripts/relevant-check-status.sh (single source of truth
    # across this gate, skills/pr-grind/SKILL.md, and agents/pr-grinder.md —
    # issue #154). Reads `gh pr checks` text on stdin; the helper emits
    # "<failed> <pending> <mode> <kept>" on line 1 (mode ∈ required|all) and may
    # append the failing rows on lines 2..N — the gate's `read -r FAILED PENDING
    # MODE KEPT <<<"$COUNTS"` consumes only line 1, so the rows are ignored here.
    # Fail-CLOSED: the helper always exits 0 with the conservative blocking line
    # "1 0 all 0" on any internal error; this wrapper adds a second guard.
    local repo_dir="$1" _hd
    _hd=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)
    bash "$_hd/../../scripts/relevant-check-status.sh" "$repo_dir" "$ADVISORY_PATTERN" 2>/dev/null \
        || printf '1 0 all 0\n'
}

# ── python3 pre-check ─────────────────────────────────────────────────
if ! command -v python3 &>/dev/null; then
    block_emit "CRITICAL: python3 not found. Pre-merge gate requires python3 for JSON parsing. Install python3 to restore gate enforcement."
    exit 0
fi

# Consume stdin
HOOK_DATA=$(cat 2>/dev/null || true)
[ -z "$HOOK_DATA" ] && exit 0

# Fast pre-filter: skip if hook data doesn't look like it could contain gh pr merge
case "$HOOK_DATA" in
    *\"Bash\"*gh\ pr\ merge*) ;;
    *gh\ pr\ merge*\"Bash\"*) ;;
    *) exit 0 ;;
esac

# Parse tool name and command, verify gh pr merge, extract PR number AND target dir.
# target_dir mirrors pre-pr-gate.sh: parse `cd <dir> && gh pr merge` so the gate
# reads marker files from the user's intended repo, not Claude's CWD.
MERGE_PARSE=$(printf '%s' "$HOOK_DATA" | python3 -c "
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
    pr_num = ''
    # Count every 'gh pr merge' invocation in the WHOLE command string, not
    # just per-segment. Shell-quote-unaware segment splitting misses
    # wrappers like \`bash -c \"gh pr merge X && gh pr merge Y\"\`, \`sh -c\`,
    # \`eval\`, \`\$(...)\`, and \`(...)\` subshells — all of which split into
    # at most one segment matching gh-pr-merge, defeating the multi-merge
    # guard. The substring-count approach catches every occurrence
    # regardless of how it's wrapped.
    merge_count = len(re.findall(r'\bgh\s+pr\s+merge\b', cmd))

    # Walk segments to find target_dir (for cd-prefix support) and the
    # first PR number — only meaningful when merge_count == 1.
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
        if re.match(r'gh\s+pr\s+merge\b', seg) and not pr_num:
            # Capture the FIRST top-level merge's PR number. If the actual
            # merge command is wrapped (bash -c, eval, etc.), pr_num may
            # remain empty — the multi-merge guard below blocks on count,
            # and even if count is 1 a wrapped merge will be gated on
            # \`unknown\` PR (downstream PostToolUse refuses consumption
            # on unknown-PR claims).
            args = re.split(r'\s+', seg)
            for a in args[3:]:  # skip 'gh', 'pr', 'merge'
                if a.startswith('-'):
                    break
                if re.match(r'^\d+$', a):
                    pr_num = a
                    break
    if merge_count >= 1:
        # Use newline separator: target_dir may contain '|' on weird paths
        print('yes' if merge_count == 1 else 'multi')
        print(pr_num)
        print(target_dir)
        print(merge_count)
        print(cwd)
except Exception:
    print('error')
    print('')
    print('')
    print('0')
    print('')
" 2>/dev/null || true)

IS_GH_PR_MERGE=$(echo "$MERGE_PARSE" | sed -n '1p')
MERGE_PR_NUM=$(echo "$MERGE_PARSE" | sed -n '2p')
TARGET_DIR=$(echo "$MERGE_PARSE" | sed -n '3p')
MERGE_COUNT=$(echo "$MERGE_PARSE" | sed -n '4p')
HOOK_CWD=$(echo "$MERGE_PARSE" | sed -n '5p')

[ -z "$IS_GH_PR_MERGE" ] && exit 0

# Multi-merge guard: refuse a Bash call that chains more than one
# 'gh pr merge' invocation. The gate authorizes a single merge per call;
# chained merges defeat per-PR gating, the cross-PR marker mismatch check,
# and the deferred-consumption claim flow (claim is filed for one PR but
# the second merge runs unauthorized). Block at PreToolUse and ask the
# operator to run them one-at-a-time so each goes through its own gate.
if [ "$IS_GH_PR_MERGE" = "multi" ]; then
    block_emit "Pre-merge gate: command chains ${MERGE_COUNT:-multiple} \`gh pr merge\` invocations in one Bash call. Only one merge per call is authorized — chained merges bypass per-PR gating and the deferred-consumption claim flow. Run each merge in its own Bash call so each goes through PreToolUse separately."
    exit 0
fi

# Fail-closed: parser error after fast pre-filter matched → block as precaution
if [ "$IS_GH_PR_MERGE" = "error" ]; then
    block_emit "Pre-merge gate: failed to parse tool input for command matching gh pr merge pattern. Blocking as precaution (fail-closed). If stuck, create $STATE_DIR/skip-pr-grind.local in your terminal."
    exit 0
fi

[ "$IS_GH_PR_MERGE" != "yes" ] && exit 0

# Resolve REPO_DIR (cwd-anchored; cd target only as a safe refinement).
# Fail-CLOSED on command-substitution targets the gate cannot evaluate.
# NOTE: unlike pre-commit/pre-pr there is no `outside-repo -> approve` escape:
# `gh pr merge` supports `-R owner/repo` and can operate from a non-repo cwd,
# so an unresolved anchor falls through to the existing marker-not-found block
# rather than approving.
gate_resolve_repo_dir "$TARGET_DIR" "$HOOK_CWD"
if [ "$GATE_RESOLVE_STATUS" = "block-unresolvable" ]; then
    block_emit "Pre-merge gate: the command's cd target uses command substitution the gate cannot resolve statically (e.g. cd \"\$(...)\"). Merge from the repo root, or use cd \"\$(git rev-parse --show-toplevel)\" which the gate recognizes. Blocking as precaution (fail-closed)."
    exit 0
fi
REPO_DIR="$GATE_REPO_DIR"

# ── Skip overrides ────────────────────────────────────────────────────

# Env var override
[ "${SKIP_PR_GRIND:-}" = "1" ] && exit 0

# File-based skip (anti-self-bypass pattern from pre-commit gate)
SKIP_FILE="$REPO_DIR/$STATE_DIR/skip-pr-grind.local"
if [ -f "$SKIP_FILE" ]; then
    FILE_AGE=999
    _MTIME=$(stat -f %m "$SKIP_FILE" 2>/dev/null) \
        || _MTIME=$(stat -c %Y "$SKIP_FILE" 2>/dev/null) \
        || _MTIME=""
    [ -n "$_MTIME" ] && FILE_AGE=$(( $(date +%s) - _MTIME ))

    # Reject skip files created within last 30 seconds — likely Claude self-bypass
    if [ "$FILE_AGE" -lt 30 ]; then
        rm -f "$SKIP_FILE"
        block_emit "BLOCKED: skip-pr-grind.local was created moments ago (likely self-bypass). Do NOT create $STATE_DIR/skip-pr-grind.local yourself. Run /pr-grind instead. If the user wants to skip, they should create the file manually in their terminal."
        exit 0
    fi

    if [ "$FILE_AGE" -lt 3600 ]; then
        # Deferred consumption: the skip file is NOT deleted here. We write a
        # "pending bypass" claim that the PostToolUse hook
        # (post-merge-confirm-bypass.sh) consumes only after gh pr merge
        # actually succeeds. If the merge fails downstream (e.g. GitHub
        # branch-protection refusal), the skip file remains valid so the
        # operator does not need to re-touch it. This closes the
        # consume-on-gate-pass-but-command-fail gap.
        mkdir -p "$REPO_DIR/$STATE_DIR"
        if ! printf 'skip_mtime=%s\nmerge_pr=%s\nclaimed_at=%s\n' \
            "${_MTIME:-0}" "${MERGE_PR_NUM:-unknown}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            > "$REPO_DIR/$STATE_DIR/.merge-bypass-pending.local" 2>/dev/null; then
            block_emit "Pre-merge gate: failed to write bypass-pending claim to $REPO_DIR/$STATE_DIR/.merge-bypass-pending.local. Cannot proceed safely (PostToolUse hook cannot confirm consumption). Check filesystem permissions."
            exit 0
        fi
        # Pre-claim telemetry (final consumption logged by PostToolUse hook)
        printf '{"ts":"%s","event":"skip-pr-grind-claimed","gate":"pre-merge","pr":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${MERGE_PR_NUM:-unknown}" \
            >> "$REPO_DIR/$STATE_DIR/bypass-log.jsonl" 2>/dev/null || true
        exit 0
    else
        rm -f "$SKIP_FILE"
    fi
fi

# ── Check for pr-grind-clean marker ──────────────────────────────────
# pr-grind writes $STATE_DIR/pr-grind-clean.local when it declares a PR clean.
# Marker expires after 2 hours (stale marker from a different PR session).
MARKER_FILE="$REPO_DIR/$STATE_DIR/pr-grind-clean.local"
if [ -f "$MARKER_FILE" ]; then
    MARKER_AGE=99999
    _MTIME=$(stat -f %m "$MARKER_FILE" 2>/dev/null) \
        || _MTIME=$(stat -c %Y "$MARKER_FILE" 2>/dev/null) \
        || _MTIME=""
    [ -n "$_MTIME" ] && MARKER_AGE=$(( $(date +%s) - _MTIME ))

    if [ "$MARKER_AGE" -lt 7200 ]; then
        # Marker is fresh — pr-grind completed recently.
        # But verify CI checks actually passed (don't trust marker alone).
        PR_NUM=$(tr -d '[:space:]' < "$MARKER_FILE" 2>/dev/null || true)
        case "$PR_NUM" in
            ''|*[!0-9]*)
                rm -f "$MARKER_FILE"
                block_emit "Pre-merge gate: pr-grind marker is empty or corrupt. Run \`/pr-grind\` again before merging."
                exit 0
                ;;
        esac
        # Marker is per-PR (pr-grind writes PR_NUM to the marker on clean
        # convergence). Refuse to authorize merging PR X based on a marker
        # written for PR Y — that allows a fresh-but-unrelated grind on one PR
        # to unlock the merge of any other open PR. Treat the mismatch as
        # stale-for-this-merge: delete and require a fresh grind for the
        # actual PR being merged.
        if [ -z "${MERGE_PR_NUM:-}" ]; then
            # Auto-detect merge (no explicit PR number): cannot confirm the
            # marker authorizes THIS PR. Fail-closed — require the operator
            # to supply an explicit PR number so the per-PR check can run.
            # Preserve the marker so the operator can retry with explicit PR
            # number without needing a fresh grind.
            block_emit "Pre-merge gate: pr-grind-clean marker is for PR #$PR_NUM but the merge command did not include an explicit PR number. Supply the PR number explicitly (e.g. \`gh pr merge $PR_NUM --squash\`) so the per-PR marker check can authorize this merge."
            exit 0
        fi
        if [ "$PR_NUM" != "$MERGE_PR_NUM" ]; then
            rm -f "$MARKER_FILE"
            block_emit "Pre-merge gate: pr-grind-clean marker is for PR #$PR_NUM but the merge targets PR #$MERGE_PR_NUM. Marker removed (per-PR, cannot cross-authorize). Run \`/pr-grind\` for PR #$MERGE_PR_NUM before merging."
            exit 0
        fi
        if command -v gh &>/dev/null; then
            # gh pr checks exits 1 when any check has failed — capture output
            # and exit code separately to distinguish "check failed" from "CLI error".
            GH_EXIT=0
            CHECKS_OUTPUT=$(cd "$REPO_DIR" && gh pr checks "$PR_NUM" 2>&1) || GH_EXIT=$?
            # Detect CLI errors vs check failures: valid output contains tab-separated
            # check results (pass/fail/pending). If gh errored, output is an error message
            # without these markers.
            if [ "$GH_EXIT" -ne 0 ] && ! printf '%s\n' "$CHECKS_OUTPUT" | grep -qE "pass|fail|pending"; then
                block_emit "Pre-merge gate: unable to verify CI checks for PR #$PR_NUM (\`gh pr checks\` failed with exit $GH_EXIT). Resolve GitHub CLI/auth/network issues and retry."
                exit 0
            fi
            COUNTS=$(printf '%s\n' "$CHECKS_OUTPUT" | _relevant_check_counts "$REPO_DIR")
            read -r FAILED PENDING MODE KEPT <<<"$COUNTS"
            # Fail-CLOSED: an empty/malformed helper output (python crash,
            # missing fields) would leave MODE unset and let `${FAILED:-0}`
            # default to 0 → gate passes silently. Block instead.
            if [[ -z "${MODE:-}" || -z "${FAILED:-}" || -z "${PENDING:-}" || -z "${KEPT:-}" ]]; then
                block_emit "Pre-merge gate: CI-check parser produced unexpected output (got '$COUNTS'). Blocking as precaution (fail-closed)."
                exit 0
            fi
            if [[ "$MODE" = "required" ]]; then
                CHECK_DESC="required CI checks (per .github/required-checks.lock)"
            else
                CHECK_DESC="CI checks"
            fi
            # Mirror the bootstrap-path KEPT > 0 guard for ALL modes. "0 FAILED
            # + 0 PENDING" alone is insufficient evidence — in required mode the
            # lock could list checks that never ran (cancelled/skipped), in
            # fallback mode every line could be filtered as advisory leaving no
            # real signal. Either way, "no failures because nothing relevant
            # appeared" is a fail-open we explicitly close here.
            if [[ "${KEPT:-0}" -eq 0 ]]; then
                block_emit "Pre-merge gate: pr-grind marker exists but 0 relevant $CHECK_DESC appeared in \`gh pr checks\` output — they may have been cancelled, skipped, or never triggered. Blocking as precaution (fail-closed)."
                exit 0
            fi
            if [[ "${FAILED:-0}" -gt 0 ]]; then
                block_emit "Pre-merge gate: pr-grind marker exists but $FAILED $CHECK_DESC are FAILING. Fix failures before merging. Run \`/pr-grind\` to resume."
                exit 0
            fi
            if [[ "${PENDING:-0}" -gt 0 ]]; then
                block_emit "Pre-merge gate: pr-grind marker exists but $PENDING $CHECK_DESC still PENDING. Wait for all checks to complete before merging."
                exit 0
            fi
        fi
        exit 0
    else
        # Stale marker — remove and require fresh grind
        rm -f "$MARKER_FILE"
    fi
fi

# ── Bootstrap detection: PR modifies gate infrastructure ─────────────
# When a PR modifies gate scripts or hook configs, the locally cached (old)
# gate code runs and blocks the merge of its own fix — a deadlock. CI checks
# run the NEW code from the PR branch, so they are the right authority for
# gate-modifying PRs. If CI all passes, allow the merge with telemetry.
if [ -n "$MERGE_PR_NUM" ] && command -v gh &>/dev/null; then
    # Subshell groups the cd+gh chain so SC2015's A && B || C pattern doesn't
    # apply: the `|| true` catches grep -c exiting 1 (no matches), not the
    # cd or gh failure modes (those are intended to suppress to empty output
    # via the inner `2>/dev/null` and absent stdout, then grep -c yields 0).
    GATE_FILES_CHANGED=$( (cd "$REPO_DIR" && gh pr diff "$MERGE_PR_NUM" --name-only 2>/dev/null) \
        | grep -cE "^hooks/(gate-scripts/|hooks\.json)" || true)
    if [ "$GATE_FILES_CHANGED" -gt 0 ]; then
        GH_EXIT=0
        CHECKS_OUTPUT=$(cd "$REPO_DIR" && gh pr checks "$MERGE_PR_NUM" 2>&1) || GH_EXIT=$?
        if [ "$GH_EXIT" -ne 0 ] && ! printf '%s\n' "$CHECKS_OUTPUT" | grep -qE "pass|fail|pending"; then
            : # CLI error — fall through to normal block
        else
            COUNTS=$(printf '%s\n' "$CHECKS_OUTPUT" | _relevant_check_counts "$REPO_DIR")
            read -r FAILED PENDING MODE KEPT <<<"$COUNTS"
            # Fail-CLOSED on empty/malformed helper output (see comment at
            # the marker-path site). Bootstrap path additionally requires
            # KEPT > 0 — "no failures, no pendings" is necessary but not
            # sufficient. Without positive evidence that any relevant check
            # actually ran, a PR with zero CI could silently bootstrap-merge
            # gate-script changes through this branch.
            if [ -z "${MODE:-}" ] || [ -z "${FAILED:-}" ] || [ -z "${PENDING:-}" ] || [ -z "${KEPT:-}" ]; then
                : # fall through to the BLOCK below
            elif [[ "${FAILED:-0}" -eq 0 && "${PENDING:-0}" -eq 0 && "${KEPT:-0}" -gt 0 ]]; then
                mkdir -p "$REPO_DIR/$STATE_DIR"
                printf '{"ts":"%s","event":"bootstrap-merge","gate":"pre-merge","pr":%s,"gate_files":%s}\n' \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MERGE_PR_NUM" "$GATE_FILES_CHANGED" \
                    >> "$REPO_DIR/$STATE_DIR/bypass-log.jsonl" 2>/dev/null || true
                exit 0
            fi
        fi
    fi
fi

# ── BLOCK: no pr-grind-clean marker found ────────────────────────────
block_emit "Pre-merge gate: pr-grind has not declared this PR clean. FIRST wait for all CI checks to complete (\`gh pr checks ${MERGE_PR_NUM:-<PR_NUMBER>} --watch\`), THEN run \`/pr-grind\` to address reviewer feedback before merging. Do NOT skip the CI wait. If you just wrote $STATE_DIR/pr-grind-clean.local: ensure it was a SEPARATE Bash tool call from \`gh pr merge\` — this hook fires BEFORE bash runs, so a combined write+merge call cannot see its own marker (TOCTOU). See skills/pr-grind/SKILL.md COMPLETION section. Escape hatch: create $STATE_DIR/skip-pr-grind.local in your terminal."
exit 0
