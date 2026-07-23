#!/usr/bin/env bash
# PreToolUse hook: gate `gh pr merge` on pr-grind completion
#
# Blocks PR merge until pr-grind has declared the PR clean.
# This ensures reviewer feedback is addressed before merge,
# regardless of which skill the agent loaded.
#
# Fail-CLOSED: errors block merge (user preference: stuck > skipped grind)
# Skip: $STATE_DIR/skip-pr-grind.local — a gitignored, operator-created file.
#       (The env-based SKIP_PR_GRIND escape was removed in issue #325 / ADR 0016:
#       a committed settings.json could inject it, so gate env is now sanitized.)

set -euo pipefail
# ── Harness-portable state resolution ──────────────────────────────────
# BUSDRIVER_STATE_DIR: state-dir override, defaults to .claude.
# Constrain to a safe relative name (reject absolute/traversal/unsafe chars) so
# repo-root joins resolve correctly and the value is safe to embed in messages.
STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
case "$STATE_DIR" in ""|/*|*..*|*[!a-zA-Z0-9._/-]*) STATE_DIR=".claude" ;; esac
# Re-export the sanitized value so sourced helpers / subprocesses read the
# constrained STATE_DIR rather than the raw env var.
export BUSDRIVER_STATE_DIR="$STATE_DIR"
trap 'printf "{\"decision\":\"block\",\"reason\":\"Pre-merge gate error — blocking as precaution. If stuck, create %s/skip-pr-grind.local in your terminal.\"}\n" "${REPO_DIR:+$REPO_DIR/}$STATE_DIR"; exit 0' ERR

# ── Block emission helper ─────────────────────────────────────────────
block_emit() {
    if command -v jq &>/dev/null; then
        jq -n --arg r "$1" '{decision:"block", reason:$r}'
    elif command -v python3 &>/dev/null; then
        # python3 is a hard dependency of these gates; json.dumps escapes
        # backslashes, quotes, newlines and control chars that sed alone cannot.
        printf '%s' "$1" | python3 -I -c 'import json,sys; sys.stdout.write(json.dumps({"decision":"block","reason":sys.stdin.read()}))'
        printf '\n'
    else
        # Last resort (no jq, no python3 — must still emit a block or the gate
        # fails OPEN). Delete the two JSON-special bytes (" = \042, \\ = \134) and
        # every control char, so the surviving text needs no escaping at all.
        # Lossy but always valid JSON; this tier only serializes fixed gate
        # messages, which contain neither a quote nor a backslash.
        local escaped
        escaped=$(printf '%s' "$1" | tr -d '\042\134' | tr '\n\r\t' '   ' | tr -d '\000-\037')
        printf '{"decision":"block","reason":"%s"}\n' "$escaped"
    fi
}

# ── ADR 0024: non-gating missing-Codex advisory ──────────────────────
# Returns the operator-facing warning STRING on stdout when the repo is
# Codex-active-or-force-on AND Codex has not engaged on the PR; empty otherwise.
#
# NEVER propagates a failure to the gate's ERR trap (constraint 1): the entire
# detection runs in an ISOLATED subshell (ERR trap cleared, errexit/pipefail/
# nounset off) whose only stdout is the message, with a hard `|| true` backstop.
# Bounded by ONE outer `timeout` shared across BOTH network sub-checks — active
# detection and the engagement probe (constraint 2); if no bounding tool is
# present at runtime, stays silent (constraint 2 — verify, don't assume). Fails
# toward silence on every error/timeout/ambiguity (constraint 3). Read-only:
# delegates to read-only helpers, posts nothing (constraint 7).
codex_none_warning() {
    local repo_dir="$1" pr="$2" override="${3:-yes}" helper_dir
    # Kill switch: zero network, zero output (constraint 4).
    [ "${PR_GRIND_CODEX_RETRIGGER:-1}" = "0" ] && return 0
    # Repo/host override on the merge command → the origin-derived target may be
    # wrong, so stay silent rather than warn about the wrong repo (constraint 5).
    [ "$override" = "yes" ] && return 0
    case "$pr" in ''|*[!0-9]*) return 0 ;; esac
    # Resolve the TRUSTED plugin scripts dir from the gate's own location
    # ($CLAUDE_PLUGIN_ROOT/scripts), never a repo/worktree copy (constraint 10).
    helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/../../scripts" || return 0

    (
        trap - ERR
        set +eo pipefail 2>/dev/null || true
        set +u

        warn_script="$helper_dir/codex-premerge-warn.sh"
        [ -f "$warn_script" ] || exit 0

        # Resolve owner/repo from the BASE repo's origin (constraint 5). Fall to
        # silence if origin can't be confirmed a plain github.com owner/repo
        # (fork checkout, GHE host, > owner/repo) — querying the wrong repo would
        # yield a false none. Same canonicalization as codex-nudge-premerge.sh,
        # PLUS a userinfo strip (`s#^[^/@]*@##`) so credentialed HTTPS origins
        # (token-auth checkouts, e.g. `https://x-access-token:TOKEN@github.com/…`)
        # don't leave the token's `:` mistaken for the git@ scp-style separator —
        # without it, canon starts with the credential prefix instead of
        # `github.com/` and the match below silently exits, suppressing the
        # advisory on common CI/token-auth checkouts (Greptile #461).
        url=$(git -C "$repo_dir" remote get-url origin 2>/dev/null)
        canon=$(printf '%s' "$url" | sed -E 's#^git@#https://#; s#^https?://##; s#^[^/@]*@##; s#:#/#; s#\.git/?$##; s#/+$##')
        case "$canon" in github.com/*/*) : ;; *) exit 0 ;; esac
        case "$canon" in github.com/*/*/*) exit 0 ;; esac
        slug="${canon#github.com/}"
        owner="${slug%%/*}"; name="${slug#*/}"
        [ -n "$owner" ] && [ -n "$name" ] || exit 0
        printf '%s' "$owner$name" | LC_ALL=C grep -q '[^A-Za-z0-9._-]' && exit 0

        # Bounding tool — VERIFY present, do not assume (constraint 2). Homebrew
        # coreutils supplies gtimeout; GNU timeout elsewhere. Absent → silent.
        bound=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)
        [ -n "$bound" ] || exit 0

        # RESERVE the advisory budget inside the outer hook timeout (constraint 2).
        # The gate already did unbounded work before this point (notably a
        # `gh pr checks` network call on the marker path), so a fixed budget could
        # still push total wall-time past the outer cap and let the harness kill an
        # AUTHORIZED merge. Instead, cap the advisory to whatever time remains:
        #   remaining = outer_cap - elapsed(SECONDS) - margin(kill-after + emit).
        # If too little remains, skip entirely (silent) — the advisory NEVER
        # extends the gate past the cap. SECONDS is whole-second elapsed since the
        # gate started; coarse but conservative (rounds elapsed down → smaller,
        # safer budget). hooks.json passes CODEX_WARN_OUTER_BUDGET explicitly,
        # co-located with its own "timeout" value on the same command line, so
        # the two numbers can't silently drift apart (CodeRabbit PR #461); the
        # :-20 fallback only covers direct/manual invocation outside the hook.
        outer=${CODEX_WARN_OUTER_BUDGET:-20}
        budget=${CODEX_WARN_BUDGET:-8}
        remaining=$(( outer - SECONDS - 4 ))
        [ "$remaining" -lt "$budget" ] && budget="$remaining"
        [ "$budget" -lt 2 ] && exit 0    # not enough headroom → silent

        # ONE budget over the entire predicate (active detection + probe).
        # --kill-after gives a hard stop; on timeout the child exits nonzero →
        # state stays empty → silent.
        state=$("$bound" -k 2 "$budget" bash "$warn_script" "$owner/$name" "$pr" "$repo_dir" 2>/dev/null | head -n1) || state=""
        [ "$state" = "warn" ] || exit 0

        # shellcheck disable=SC2016  # backticks are LITERAL message text, not a substitution
        printf '⚠️ Codex is ACTIVE on this repo but has not engaged on PR #%s — merging without Codex engagement. To wait for one: post `@codex review` and re-run /pr-grind.' "$pr"
    ) 2>/dev/null || true
}

# ── ADR 0024: single allow epilogue ──────────────────────────────────
# The ONE terminal all three substantive allow sites route through (operator
# skip, pr-grind-clean marker + CI, bootstrap bypass). Emits the non-gating
# missing-Codex advisory as a top-level `systemMessage` — operator-visible and
# carrying NO decision/permissionDecision, so it never gates (constraint 8) —
# then runs the pre-existing approve (bare exit 0). When silent, stdout is empty:
# byte-for-byte identical to the old bare `exit 0` on every allow path. Deny
# paths never reach here, so they never emit the advisory and never run any
# Codex command.
allow_merge() {
    # $1 = reason label (readability/telemetry only; not emitted).
    local _msg=""
    _msg=$(codex_none_warning "${REPO_DIR:-}" "${MERGE_PR_NUM:-}" "${REPO_OVERRIDE:-yes}") || _msg=""
    if [ -n "$_msg" ]; then
        if command -v jq &>/dev/null; then
            jq -n --arg m "$_msg" '{systemMessage:$m}' 2>/dev/null || true
        elif command -v python3 &>/dev/null; then
            { printf '%s' "$_msg" | python3 -I -c 'import json,sys; sys.stdout.write(json.dumps({"systemMessage": sys.stdin.read()}))'; printf '\n'; } 2>/dev/null || true
        fi
        # No lossy last-resort tier: the gate already hard-requires python3, so a
        # jq-and-python3-less host is unreachable. A garbled systemMessage would
        # be worse than none for an advisory — stay silent instead.
    fi
    exit 0
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
    *\"Bash\"*gh*pr*merge*) ;;
    *gh*pr*merge*\"Bash\"*) ;;
    *) exit 0 ;;
esac

# Parse tool name and command, verify gh pr merge, extract PR number AND target dir.
# target_dir mirrors pre-pr-gate.sh: parse `cd <dir> && gh pr merge` so the gate
# reads marker files from the user's intended repo, not Claude's CWD.
_GATE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
MERGE_PARSE=$(printf '%s' "$HOOK_DATA" | PYTHONPATH="$_GATE_LIB" python3 -S -c "
import sys
# Drop CWD from sys.path (python3 -c prepends it ahead of PYTHONPATH) + -S skips
# site so a repo-planted sitecustomize.py, a shadowed gitcmd_detect.py, or a
# shadowed stdlib (json.py) cannot run in the gate. Scrub BEFORE any import.
# Also move the PYTHONPATH-injected gate lib to the END so a file named json.py
# beside the detector cannot shadow the stdlib json (sys.path order is otherwise
# interpreter-dependent). The detector is still importable from the tail entry.
_gatelib = [p for p in sys.path if p.endswith('gate-scripts/lib')]
sys.path[:] = [p for p in sys.path
               if p not in ('', '.') and p not in _gatelib] + _gatelib
try:
    # Imports inside the try: a missing/broken gitcmd_detect must land in the
    # 'error' branch (which BLOCKS) rather than crash to empty output, which the
    # caller's \`[ -z ... ] && exit 0\` would read as 'not a merge' — fail-OPEN.
    import json
    from gitcmd_detect import gh_pr, gh_pr_count
    d = json.load(sys.stdin)
    tool = d.get('tool_name', d.get('toolName', ''))
    if tool != 'Bash':
        sys.exit(0)
    cwd = d.get('cwd') or ''
    inp = d.get('tool_input', d.get('toolInput', {}))
    if isinstance(inp, str):
        inp = json.loads(inp)
    cmd = inp.get('command', '')
    # Count merges by COMMAND WORD via the shared detector — the same parser the
    # sibling gates and post-merge-confirm-bypass.sh use, so 'what is a merge'
    # cannot drift between the claim and its confirmation. It still sees inside
    # \`bash -c\`, \`sh -c\`, \`eval\`, \`\$(...)\`, backticks and subshells (each is a
    # scanned chunk), so the multi-merge guard keeps its coverage — but prose
    # that merely QUOTES the merge command (an issue comment, a --body, a test
    # fixture's input string) no longer counts as a merge (issue #426).
    merge_count = gh_pr_count(cmd, 'merge')
    _present, target_dir, pr_num = gh_pr(cmd, 'merge')
    # ADR 0024 constraint 5: a per-command repo/host override means the merge may
    # target a DIFFERENT repo than the checkout's origin, so the origin-derived
    # missing-Codex advisory would name the wrong repo. Surface its presence so
    # the allow epilogue falls to SILENT (never a wrong-repo warning). Advisory-
    # only — it does NOT gate. gitcmd_detect.gh_pr value-skips -R/--repo, so it is
    # detected here from the raw command (same override set the nudge rejects).
    # Coarse, fail-safe-SILENT override detection (constraint 5). Err toward
    # silence: any repo/host selector suppresses the advisory. First strip the
    # three shell quote/escape chars (chr(34)=doublequote, chr(39)=singlequote,
    # chr(92)=backslash -- referenced by code point so no literal quote/backslash
    # lands in this bash-wrapped python) so quote/backslash-split forms collapse
    # back to a plain -R substring before the test. Then a substring test covers
    # detached (-R other), attached (-Rother), quoted, and long (--repo) forms,
    # AND inline GH_REPO=/GH_HOST= assignments -- all four checked against the
    # NORMALIZED command so a split GH_\REPO= evades none. Over-broad
    # ONLY toward silence (a legit advisory skipped), never toward a wrong-repo
    # warning. Real gh pr merge flags (--squash/--rebase/--admin/
    # --match-head-commit) contain no -R substring. Truly exotic obfuscation
    # (ANSI-C quoting, variable indirection) stays out of scope per ADR 0024 --
    # the advisory is non-gating, so the residual is at worst a misleading warning.
    _cmd_norm = cmd.replace(chr(34), '').replace(chr(39), '').replace(chr(92), '')
    repo_override = 'yes' if ('-R' in _cmd_norm or '--repo' in _cmd_norm
                              or 'GH_REPO=' in _cmd_norm or 'GH_HOST=' in _cmd_norm) else 'no'
    if merge_count >= 1:
        # Use newline separator: target_dir may contain '|' on weird paths
        print('yes' if merge_count == 1 else 'multi')
        print(pr_num)
        print(target_dir)
        print(merge_count)
        print(cwd)
        print(repo_override)
except Exception:
    print('error')
    print('')
    print('')
    print('0')
    print('')
    print('yes')
" 2>/dev/null || true)

IS_GH_PR_MERGE=$(echo "$MERGE_PARSE" | sed -n '1p')
MERGE_PR_NUM=$(echo "$MERGE_PARSE" | sed -n '2p')
TARGET_DIR=$(echo "$MERGE_PARSE" | sed -n '3p')
MERGE_COUNT=$(echo "$MERGE_PARSE" | sed -n '4p')
HOOK_CWD=$(echo "$MERGE_PARSE" | sed -n '5p')
# ADR 0024: 'yes' → suppress the missing-Codex advisory (constraint 5). Defaults
# to 'yes' (silent) on any parse anomaly — fail toward silence.
REPO_OVERRIDE=$(echo "$MERGE_PARSE" | sed -n '6p')
case "$REPO_OVERRIDE" in yes|no) ;; *) REPO_OVERRIDE=yes ;; esac

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
    block_emit "Pre-merge gate: failed to parse tool input for command matching gh pr merge pattern. Blocking as precaution (fail-closed). If stuck, create ${REPO_DIR:+$REPO_DIR/}$STATE_DIR/skip-pr-grind.local in your terminal."
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
# (env-based SKIP_PR_GRIND removed — issue #325; use the .local skip file. ADR 0016.)

# File-based skip (anti-self-bypass pattern from pre-commit gate)
SKIP_FILE="$REPO_DIR/$STATE_DIR/skip-pr-grind.local"
if [ -f "$SKIP_FILE" ] \
   && ! gate_skip_file_repo_controlled "$REPO_DIR" "$STATE_DIR/skip-pr-grind.local"; then
    FILE_AGE=999
    _MTIME=$(stat -f %m "$SKIP_FILE" 2>/dev/null) \
        || _MTIME=$(stat -c %Y "$SKIP_FILE" 2>/dev/null) \
        || _MTIME=""
    [ -n "$_MTIME" ] && FILE_AGE=$(( $(date +%s) - _MTIME ))

    # Reject skip files created within last 30 seconds — likely Claude self-bypass
    if [ "$FILE_AGE" -lt 30 ]; then
        rm -f "$SKIP_FILE"
        block_emit "BLOCKED: skip-pr-grind.local was created moments ago (likely self-bypass). Do NOT create ${REPO_DIR:+$REPO_DIR/}$STATE_DIR/skip-pr-grind.local yourself. Run /pr-grind instead. If the user wants to skip, they should create the file manually in their terminal."
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
        allow_merge "skip-pr-grind"
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
        allow_merge "pr-grind-clean+ci"
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
    # Scope the bootstrap bypass to the busdriver plugin repo itself. A gate-
    # modifying PR is only meaningful here; any OTHER repo that happens to have
    # hooks/gate-scripts/ or hooks/hooks.json paths must NOT inherit this
    # pr-grind bypass. Fail CLOSED — if the busdriver plugin manifest can't be
    # confirmed at $REPO_DIR, fall through to the normal block below.
    IS_BUSDRIVER_REPO=false
    if [[ -f "$REPO_DIR/.claude-plugin/plugin.json" ]] && \
       grep -q '"name"[[:space:]]*:[[:space:]]*"busdriver"' "$REPO_DIR/.claude-plugin/plugin.json" 2>/dev/null; then
        IS_BUSDRIVER_REPO=true
    fi
    if [[ "$GATE_FILES_CHANGED" -gt 0 ]] && [[ "$IS_BUSDRIVER_REPO" == true ]]; then
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
                allow_merge "bootstrap-merge"
            fi
        fi
    fi
fi

# ── BLOCK: no pr-grind-clean marker found ────────────────────────────
block_emit "Pre-merge gate: pr-grind has not declared this PR clean. FIRST wait for all CI checks to complete (\`gh pr checks ${MERGE_PR_NUM:-<PR_NUMBER>} --watch\`), THEN run \`/pr-grind\` to address reviewer feedback before merging. Do NOT skip the CI wait. If you just wrote ${REPO_DIR:+$REPO_DIR/}$STATE_DIR/pr-grind-clean.local: ensure it was a SEPARATE Bash tool call from \`gh pr merge\` — this hook fires BEFORE bash runs, so a combined write+merge call cannot see its own marker (TOCTOU). See skills/pr-grind/SKILL.md COMPLETION section. Escape hatch: create ${REPO_DIR:+$REPO_DIR/}$STATE_DIR/skip-pr-grind.local in your terminal."
exit 0
