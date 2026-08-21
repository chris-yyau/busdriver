#!/usr/bin/env bash
# PostToolUse hook: confirm or release the pre-merge bypass claim after
# `gh pr merge` has run.
#
# Lifecycle (paired with pre-merge-gate.sh "deferred consumption" path):
#   1. PreToolUse (pre-merge-gate.sh) — sees a valid skip-pr-grind.local
#      (≥30s old, <1h), records its mtime + the merge PR number into
#      $STATE_DIR/.merge-bypass-pending.local, leaves the skip file alone,
#      allows the bash command to run.
#   2. Bash executes `gh pr merge ...`.
#   3. PostToolUse (this script) — reads tool_output and the pending claim.
#      Re-validates the skip file (must still exist, mtime must match the
#      claim, age must still satisfy the 30s anti-self-bypass at the time
#      of confirmation, and the PR number parsed from the command must
#      match the claimed PR). On confirmed success → consume skip + clear
#      pending. On any other outcome → release the pending claim and
#      preserve the skip file so the operator can retry without a re-touch.
#
# Status taxonomy (all logged to bypass-log.jsonl):
#   skip-pr-grind-consumed                — the PR is confirmed merged and all
#                                           validations passed; skip file deleted.
#                                           reason names the evidence: the GitHub
#                                           API state of THIS checkout's PR
#                                           (github-api-state-merged; a merge
#                                           steered at another repo is not
#                                           queried at all), cli-pattern-merged
#                                           when gh's own output confirmed it,
#                                           cross-repo-merge-unverifiable-token-
#                                           spent for an unconfirmable cross-repo
#                                           merge, or auto-merge-accepted-token-
#                                           spent for an accepted --auto queue.
#   skip-pr-grind-released                — gh pr merge failed; skip preserved
#   skip-pr-grind-released-auto-queued    — RETIRED in #664, no longer emitted.
#                                           An accepted --auto queue now spends
#                                           the token (reason auto-merge-
#                                           accepted-token-spent) because no
#                                           later event can ever confirm it, and
#                                           preserving left it armed for a
#                                           second merge. Historical log entries
#                                           keep their old meaning.
#   skip-pr-grind-released-ambiguous      — tool_output matched neither success
#                                           nor failure patterns AND the GitHub
#                                           API did not answer MERGED; fail-safe.
#                                           reason names WHICH evidence path
#                                           failed (#672), because "preserved
#                                           because GitHub says it is still
#                                           open" and "preserved because nobody
#                                           could answer, so this token may be
#                                           spent and is still armed" need
#                                           different operator responses:
#                                           github-api-says-not-merged,
#                                           github-api-unreachable-merge-state-
#                                           unknown, github-api-answer-
#                                           unrecognized, github-api-not-queried-
#                                           pr-not-explicitly-known (neither side
#                                           names a concrete PR), or
#                                           github-api-not-queried-pr-mismatch-
#                                           claimed-<N>-parsed-<M> (both sides
#                                           name a concrete PR but they differ —
#                                           distinct from the "not explicitly
#                                           known" case so the audit trail never
#                                           tells the operator no PR was known
#                                           when two conflicting ones were).
#                                           The pre-#672 blanket reason
#                                           tool-output-matched-no-known-pattern
#                                           is retired; historical log entries
#                                           keep their old (undifferentiated)
#                                           meaning.
#   skip-pr-grind-released-tampered       — skip file disappeared, mtime
#                                           changed, or was <30s old at
#                                           confirmation time
#   skip-pr-grind-released-mismatch       — PR number parsed from the bash
#                                           command did not match the claim
#   skip-pr-grind-released-malformed      — pending file contents failed
#                                           structural validation
#   merge-bypass-stale-cleanup            — pending claim older than 5 minutes
#                                           was force-cleaned (session crash
#                                           recovery — only fires on Bash calls
#                                           that are NOT gh pr merge to avoid
#                                           swallowing real merge processing)
#
# Why deferred consumption: before this hook existed, pre-merge-gate.sh
# deleted the skip file eagerly at PreToolUse. If `gh pr merge` then failed
# at the GitHub API layer (branch not up to date, merge conflict, branch
# protection refusal), the operator had to re-touch the skip file and wait
# 30s again — wasted ceremony for a downstream failure they had nothing to
# do with. The new lifecycle moves the deletion to PostToolUse where the
# actual outcome is known.
#
# Why this scope is pre-merge-only: pre-commit-gate.sh and pre-pr-gate.sh
# do not need the same treatment because `git commit` and `gh pr create`
# fail locally before any remote side-effect — a downstream-failure window
# does not exist. `gh pr merge` is unique in that the local command can
# succeed while the GitHub API refuses to merge.

set -euo pipefail
# ── Harness-portable root/state resolution ─────────────────────────────
# BUSDRIVER_PLUGIN_ROOT: plugin-root override; falls back to CLAUDE_PLUGIN_ROOT.
# Falls back to relative path from this script's location.
# BUSDRIVER_STATE_DIR: state-dir override, defaults to .claude.
# shellcheck disable=SC2034  # PLUGIN_ROOT used in env-var fallback chains
PLUGIN_ROOT="${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
# Constrain to a safe relative name (reject absolute/traversal/unsafe chars) and
# re-export so every gate writes/consumes markers from the same state dir.
case "$STATE_DIR" in ""|/*|*..*|*[!a-zA-Z0-9._/-]*) STATE_DIR=".claude" ;; esac
export BUSDRIVER_STATE_DIR="$STATE_DIR"
trap 'exit 0' ERR

HOOK_DATA=$(cat 2>/dev/null || true)
[ -z "$HOOK_DATA" ] && exit 0

# Fast pre-filter: only process Bash tool calls
case "$HOOK_DATA" in
    *\"Bash\"*) ;;
    *) exit 0 ;;
esac

# Shared repo-dir resolver — keep PENDING_FILE/SKIP_FILE lookup cwd-anchored,
# consistent with the pre-merge gate, so the toplevel form
# cd "$(git rev-parse --show-toplevel)" resolves the bypass files in the real
# repo instead of a junk literal path.
# shellcheck source=lib/resolve-repo-dir.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/resolve-repo-dir.sh"

# Determine whether this Bash call is the gh pr merge we may have claimed
# against, and extract the target directory (mirrors pre-merge-gate.sh's
# cd-prefix resolution so REPO_DIR is anchored to the operator's intended
# repo, not the hook process CWD — which diverges when the command is
# `cd <dir> && gh pr merge ...`). The narrower test must run before
# stale-cleanup so that a slow operator (>5 min between claim and merge)
# doesn't lose merge processing to opportunistic cleanup.
_GATE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
_PRE_PARSE=$(printf '%s' "$HOOK_DATA" | PYTHONPATH="$_GATE_LIB" python3 -S -c "
import sys
# Drop CWD from sys.path (python3 -c prepends it ahead of PYTHONPATH) so a repo-
# controlled gitcmd_detect.py or shadowed stdlib (json.py) cannot run in the gate.
sys.path[:] = [p for p in sys.path if p not in ('', '.')]
try:
    import json
    from gitcmd_detect import gh_pr
    d = json.load(sys.stdin)
    tool = d.get('tool_name', d.get('toolName', ''))
    if tool != 'Bash':
        print('false'); print(''); print(''); sys.exit(0)
    cwd = d.get('cwd') or ''
    inp = d.get('tool_input', d.get('toolInput', {}))
    if isinstance(inp, str):
        inp = json.loads(inp)
    cmd = inp.get('command', '')
    # Fail-CLOSED command-word detection via the shared detector: prose/args
    # like 'echo gh pr merge 31' must NOT count as a completed merge (a bare
    # re.search did, letting crafted text drive confirmation/consumption of
    # bypass state). target_dir is the cd/gh -C repo scope.
    is_merge, target_dir, _pr = gh_pr(cmd, 'merge')
    print('true' if is_merge else 'false')
    print(target_dir)
    print(cwd)
except Exception:
    print('false'); print(''); print('')
" 2>/dev/null || true)
is_gh_pr_merge=$(printf '%s' "$_PRE_PARSE" | sed -n '1p')
_TARGET_DIR=$(printf '%s' "$_PRE_PARSE" | sed -n '2p')
_HOOK_CWD=$(printf '%s' "$_PRE_PARSE" | sed -n '3p')
[ -z "$is_gh_pr_merge" ] && is_gh_pr_merge=false

# Resolve repo root: cwd-anchored (mirrors pre-merge-gate.sh) so the toplevel
# cd "$(git rev-parse --show-toplevel)" form resolves the bypass files in the
# real repo; the lenient resolver falls back to the cwd/process git root.
REPO_DIR=$(gate_repo_dir_lenient "$_TARGET_DIR" "$_HOOK_CWD")
PENDING_FILE="$REPO_DIR/$STATE_DIR/.merge-bypass-pending.local"
SKIP_FILE="$REPO_DIR/$STATE_DIR/skip-pr-grind.local"
LOG_FILE="$REPO_DIR/$STATE_DIR/bypass-log.jsonl"

mkdir -p "$REPO_DIR/$STATE_DIR" 2>/dev/null || true

log_event() {
    # Args: event_name [reason]. Other fields read from CLAIMED_* globals.
    local event="$1" reason="${2:-}"
    if [ -n "$reason" ]; then
        printf '{"ts":"%s","event":"%s","gate":"post-merge","pr":"%s","claimed_at":"%s","reason":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" \
            "${CLAIMED_MERGE_PR:-unknown}" "${CLAIMED_AT:-unknown}" "$reason" \
            >> "$LOG_FILE" 2>/dev/null || true
    else
        printf '{"ts":"%s","event":"%s","gate":"post-merge","pr":"%s","claimed_at":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" \
            "${CLAIMED_MERGE_PR:-unknown}" "${CLAIMED_AT:-unknown}" \
            >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# Initialize claimed_* in this scope so log_event can be called pre-load.
CLAIMED_AT=""
CLAIMED_MERGE_PR=""
CLAIMED_SKIP_MTIME=""

# ── Stale-pending cleanup ────────────────────────────────────────────
# Only fires when the current Bash call is NOT gh pr merge — otherwise we
# would clean up a pending claim that the current call is about to
# confirm/release, leaving the skip file silently valid as an undetected
# bypass for up to ~58 more minutes (the pre-gate's 1-hour FILE_AGE expiry).
if [ "$is_gh_pr_merge" = "false" ] && [ -f "$PENDING_FILE" ]; then
    _PMTIME=$(stat -f %m "$PENDING_FILE" 2>/dev/null) \
        || _PMTIME=$(stat -c %Y "$PENDING_FILE" 2>/dev/null) \
        || _PMTIME=""
    if [ -n "$_PMTIME" ]; then
        _PENDING_AGE=$(( $(date +%s) - _PMTIME ))
        if [ "$_PENDING_AGE" -gt 300 ]; then
            rm -f "$PENDING_FILE"
            printf '{"ts":"%s","event":"merge-bypass-stale-cleanup","gate":"post-merge","age_sec":%s}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_PENDING_AGE" \
                >> "$LOG_FILE" 2>/dev/null || true
        fi
    fi
fi

# If this Bash call is not gh pr merge, we are done — stale-cleanup above
# was the only legitimate action.
[ "$is_gh_pr_merge" = "false" ] && exit 0

# No pending claim → nothing for us to confirm/release. Exit silently.
[ ! -f "$PENDING_FILE" ] && exit 0

# Load claim context.
CLAIMED_AT=$(grep -E '^claimed_at=' "$PENDING_FILE" 2>/dev/null | head -1 | cut -d= -f2- || echo "")
CLAIMED_MERGE_PR=$(grep -E '^merge_pr=' "$PENDING_FILE" 2>/dev/null | head -1 | cut -d= -f2- || echo "")
CLAIMED_SKIP_MTIME=$(grep -E '^skip_mtime=' "$PENDING_FILE" 2>/dev/null | head -1 | cut -d= -f2- || echo "")

# Validate claim structure before trusting any of it. The bypass log is the
# user's only audit trail; if we let unvalidated fields flow into JSONL we
# enable log-injection attacks via a forged pending file. Validate every
# field that gets logged.
_CLAIM_MALFORMED=false

# skip_mtime: required, numeric only.
case "$CLAIMED_SKIP_MTIME" in
    ''|*[!0-9]*) _CLAIM_MALFORMED=true ;;
esac

# merge_pr: numeric, or the literal "unknown" sentinel (auto-detect path).
case "$CLAIMED_MERGE_PR" in
    ''|unknown) : ;;
    *[!0-9]*) _CLAIM_MALFORMED=true ;;
esac

# claimed_at: strict ISO-8601 UTC, exactly as pre-merge-gate.sh produces via
# `date -u +%Y-%m-%dT%H:%M:%SZ`. Anything else (control chars, JSON
# fragments, attempted log-injection payloads) is rejected. Note: we
# deliberately DO NOT log the claimed_at value when releasing-malformed,
# because the malformed value is exactly what an attacker would inject.
case "$CLAIMED_AT" in
    [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z) : ;;
    *) _CLAIM_MALFORMED=true ;;
esac

if [ "$_CLAIM_MALFORMED" = "true" ]; then
    rm -f "$PENDING_FILE"
    # Suppress every unvalidated field that would flow into the JSONL log.
    # Either field can carry an attacker payload; resetting both to
    # 'unknown' guarantees the malformed-event log line cannot be used to
    # inject JSON keys or break the framing of the bypass-log.jsonl.
    CLAIMED_AT="unknown"
    CLAIMED_MERGE_PR="unknown"
    log_event "skip-pr-grind-released-malformed" "pending-file-failed-structural-validation"
    exit 0
fi

# Parse the bash command + tool_output. Output two newline-separated values:
#   line 1: status   (success | auto_queued | failure | ambiguous)
#   line 2: extracted PR number (empty if not present in the command)
PARSE=$(printf '%s' "$HOOK_DATA" | PYTHONPATH="$_GATE_LIB" python3 -S -c "
import sys
# Drop CWD from sys.path (python3 -c prepends it ahead of PYTHONPATH) so a repo-
# controlled gitcmd_detect.py or shadowed stdlib (json.py) cannot run in the gate.
sys.path[:] = [p for p in sys.path if p not in ('', '.')]
try:
    import json, re
    from gitcmd_detect import gh_pr, gh_pr_repo_override
    d = json.load(sys.stdin)
    tool = d.get('tool_name', d.get('toolName', ''))
    if tool != 'Bash':
        sys.exit(0)
    inp = d.get('tool_input', d.get('toolInput', {}))
    if isinstance(inp, str):
        inp = json.loads(inp)
    cmd = inp.get('command', '')
    # Fail-CLOSED command-word detection via the shared detector: only a real
    # gh-pr-merge invocation counts, not prose like 'echo gh pr merge 31'.
    is_merge, _td, pr_num = gh_pr(cmd, 'merge')
    if not is_merge:
        sys.exit(0)

    out = d.get('tool_output', d.get('toolOutput', {}))
    if isinstance(out, dict):
        output_text = out.get('output', '')
        ec = out.get('exit_code', out.get('exitCode'))
    elif isinstance(out, str):
        output_text = out
        ec = None
    else:
        output_text = ''
        ec = None

    # AUTO-QUEUED: --auto enabled auto-merge but the PR is not yet merged.
    # The skip file must NOT be consumed (the merge has not happened).
    auto_queued_patterns = [
        r'set to auto-merge when',
        r'will be automatically merged',
        r'enabled auto-merge',
        r'Pull request .* will be merged when',
    ]
    has_auto_queued = any(re.search(p, output_text, re.MULTILINE) for p in auto_queued_patterns)

    # CONFIRMED SUCCESS: the PR is actually merged.
    success_patterns = [
        r'Squashed and merged pull request',
        r'Merged pull request',
        r'Rebased and merged pull request',
        r'\bmerged pull request #\d+',
    ]
    has_success = any(re.search(p, output_text, re.MULTILINE | re.IGNORECASE) for p in success_patterns)

    # FAILURE: explicit refusal or error.
    failure_patterns = [
        r'not mergeable',
        r'^error:',
        r'^fatal:',
        r'GraphQL:',
        r'X Pull request',
        r'failed to merge',
        r'merge conflict',
        r'required status check',
        r'CHECKS_FAILED',
        r'cannot be merged',
    ]
    has_failure = any(re.search(p, output_text, re.MULTILINE) for p in failure_patterns)

    # Decision order:
    #   1. Explicit failure pattern wins (even if exit-code says 0; gh can
    #      print warnings on a non-fatal stderr path).
    #   2. Auto-queued without confirmed-merge → release, preserve skip.
    #      (auto-queued AND confirmed-merge is impossible in practice — gh
    #      either queues OR merges, not both — but if it ever happens,
    #      success wins.)
    #   3. Confirmed-merge pattern → success.
    #   4. Fall back to exit code: 0 with no patterns → ambiguous (fail-safe).
    #      Non-zero → failure.
    # Both 'ambiguous' and 'failure' are re-checked against the GitHub API
    # by the caller (#664) — gh's stdout and its exit code are BOTH unreliable
    # signals for whether the remote actually merged.
    if has_failure:
        status = 'failure'
    elif has_auto_queued and not has_success:
        status = 'auto_queued'
    elif has_success:
        status = 'success'
    else:
        if ec is not None:
            try:
                status = 'ambiguous' if int(ec) == 0 else 'failure'
            except (ValueError, TypeError):
                status = 'ambiguous'
        else:
            status = 'ambiguous'

    print(status)
    print(pr_num)
    # Line 3: does the merge carry a repo/host selector? The pre-merge gate's
    # cross-repo guard sits BELOW its skip branch on purpose (an operator skip
    # is an explicit human bypass, not evidence-based authorization), so a
    # claimed merge CAN steer at another repo — and then PR #N in THIS checkout
    # is a different pull request, which the query below must not judge it by.
    # A detected selector makes the caller SPEND the token (see below) rather
    # than query. Reading the selector's VALUE and querying the named repo was
    # tried and reverted: a whole-command regex picks up a sibling command's
    # selector (gh pr view 7 -R wrong/repo; gh pr merge 42 -R right/repo) and
    # misses clustered/spaced/URL spellings — scoping a value to the right
    # invocation belongs in gitcmd_detect beside _gh_pr_argv, not in a
    # hook-local regex.
    #
    # RESIDUAL, stated rather than papered over: a selector the SHELL assembles
    # leaves no literal to detect, and no static reader can resolve it —
    # resolving it means running the command, which a hook must never do. There
    # the query answers for this checkout's unrelated PR and a non-MERGED answer
    # preserves a token that was in fact spent: pre-#664 behaviour for that one
    # shape, never worse than today, bounded by the operator's own 3600s window,
    # and reachable only while their skip token is live. It is the same residual
    # this detector already carries for the GATE, and accepted for the same
    # reason (see gh_pr_repo_override's docstring): defense-in-depth against the
    # literal forms, never a boundary.
    print('yes' if gh_pr_repo_override(cmd, 'merge') else 'no')
    # Line 4: explicit completion marker. Printed only once every prior print
    # succeeded — an exception anywhere above (including inside
    # gh_pr_repo_override itself) truncates the output before this line ever
    # runs. Without it, a truncated line 3 was indistinguishable from a real
    # 'yes': both look non-'no' to the bash side below.
    print('parse-complete')
except Exception:
    pass
" 2>/dev/null || true)

PARSE_STATUS=$(echo "$PARSE" | sed -n '1p')
PARSE_PR=$(echo "$PARSE" | sed -n '2p')
PARSE_REPO_OVERRIDE=$(echo "$PARSE" | sed -n '3p')
PARSE_COMPLETE=$(echo "$PARSE" | sed -n '4p')
# Trust an explicit "yes" ONLY when the parse fully completed (line 4 present
# — proves no exception truncated the output before or during line 3). A
# truncated/garbled/missing line 3 must default to "no", not "yes": "yes"
# immediately forces PARSE_STATUS to "success" and spends the token below
# (cross-repo-merge-unverifiable-token-spent) even when PARSE_STATUS was
# genuinely 'failure' — burning the token on a same-repo failure the parser
# never actually confirmed was cross-repo. "no" instead falls through to the
# normal query/preserve path, which can only ever preserve the skip file on
# an anomaly, never force-spend it.
if [ "$PARSE_COMPLETE" = "parse-complete" ] && [ "$PARSE_REPO_OVERRIDE" = "yes" ]; then
    PARSE_REPO_OVERRIDE=yes
else
    PARSE_REPO_OVERRIDE=no
fi
_SUCCESS_SOURCE=""
# Why the ambiguous fail-safe fired, in a FIXED vocabulary (#672). Before this,
# every ambiguous release logged "tool-output-matched-no-known-pattern", which
# since #664/#709 is both wrong (the API *is* consulted) and undiagnosable: it
# covered "GitHub says the merge did not happen" (correct preserve, nothing to
# do) and "nobody could answer, so a possibly-spent token is still armed on
# disk" (operator must check by hand) with the same string. Fixed strings only —
# never gh's own text — so the one audit trail cannot be injected or leaked into.
_AMBIGUOUS_REASON="merge-state-unclassified"

# ── Authoritative merge-state confirmation (issue #664) ────────────────
# Neither of gh's local signals proves what the remote did:
#   - stdout: `gh pr merge` prints "✓ Squashed and merged pull request #N"
#     only when stdout is a TTY. Under the Claude Code Bash tool it never
#     is, so a SUCCESSFUL agent-driven merge emits nothing at all → exit 0
#     with zero pattern matches → 'ambiguous', leaving a spent bypass token
#     armed for the rest of its 3600s window. Deterministic, not a race.
#   - exit code: with --delete-branch a post-merge worktree-checkout
#     conflict makes gh exit non-zero on a merge the remote already
#     accepted (empirical, PR #98) → 'failure', same armed-token outcome.
#   - --auto: gh reports the merge QUEUED, but GitHub merges immediately when
#     the required checks are already green, so the PR can be MERGED by the
#     time this hook runs — 'auto_queued' then armed the token too. (The
#     gate's --auto guard, like its cross-repo guard, sits BELOW the skip
#     branch, so a claimed merge can carry --auto.)
# So ask GitHub, the authority pr-grind already treats as definitive
# (skills/pr-grind/SKILL.md), for EVERY non-success classification, and
# promote only on MERGED. The CLI patterns stay as the offline path; an
# unreachable, unauthenticated or non-MERGED answer leaves the fail-safe
# classification untouched.
# An ACCEPTED --auto queue spends the token even though the PR has not merged
# yet. The gate authorized one merge; GitHub took it and will land it with no
# further PostToolUse event, so nothing will ever confirm it — preserving here
# left the spent token armed for a second merge (the #664 hole through the
# --auto door; the gate's own --auto guard, like its cross-repo guard, sits
# BELOW the skip branch, so a claimed merge can carry it). The retry reprieve
# deferred consumption exists for covers merges that FAILED, not merges that
# were accepted; if the queue later fails its checks the operator re-touches.
# Promoted before the query so it still passes every tamper/age/PR validation.
case "$PARSE_STATUS" in
    success)
        # The CLI patterns already confirmed it (a TTY ran the merge, or gh
        # printed on stderr). Name that evidence rather than logging an empty
        # reason — including for a cross-repo merge, where the pattern is the
        # only thing that can speak to another repo's PR and the query below
        # would never run.
        _SUCCESS_SOURCE="cli-pattern-merged"
        ;;
    auto_queued)
        PARSE_STATUS="success"
        _SUCCESS_SOURCE="auto-merge-accepted-token-spent"
        ;;
esac

case "$PARSE_STATUS" in
    success) ;;
    *)
        # Fail-closed precondition for the query: a concretely-known PR on
        # BOTH sides. The query needs an unambiguous target, and judging by
        # some other PR's state is the cross-PR token reuse the success path
        # refuses below.
        if [ "$PARSE_REPO_OVERRIDE" = "yes" ]; then
            # A merge steered at another repo/host. No query here can speak to
            # it — this checkout's PR #N is a different pull request — so the
            # token cannot be CONFIRMED. Spend it rather than leave it armed:
            # the gate authorized one merge, that merge was attempted somewhere
            # this hook cannot see, and a live token nobody knows about for the
            # rest of the hour is the #664 defect itself. Consumption is the
            # fail-CLOSED direction (it removes a bypass, never grants one);
            # the cost is a re-touch if that cross-repo merge failed. The
            # detector is the same one the GATE trusts to BLOCK a merge, so
            # trusting it here is strictly less consequential than its existing
            # use. Logged with its own reason, so the audit trail never claims
            # a merge was confirmed.
            PARSE_STATUS="success"
            _SUCCESS_SOURCE="cross-repo-merge-unverifiable-token-spent"
        elif [ -n "$PARSE_PR" ] && [ "$PARSE_PR" = "$CLAIMED_MERGE_PR" ]; then
            # Bound the network call well inside the hook timeout; absent a
            # timeout binary, run unbounded (the harness timeout still caps
            # it, and a killed hook consumes nothing — fail-safe).
        _BOUND=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)
        if [ -n "$_BOUND" ]; then
            _PR_STATE=$(cd "$REPO_DIR" && "$_BOUND" 6 gh pr view "$PARSE_PR" --json state -q .state 2>/dev/null) || _PR_STATE=""
        else
            _PR_STATE=$(cd "$REPO_DIR" && gh pr view "$PARSE_PR" --json state -q .state 2>/dev/null) || _PR_STATE=""
        fi
        case "$_PR_STATE" in
            MERGED)
                PARSE_STATUS="success"
                _SUCCESS_SOURCE="github-api-state-merged"
                ;;
            OPEN|CLOSED)
                _AMBIGUOUS_REASON="github-api-says-not-merged"
                ;;
            "")
                # Unreachable, unauthenticated, or timed out. THIS is the #672
                # hazard: the merge may well have succeeded, so the preserved
                # token may already be spent and stays armed for the rest of
                # its window. Preserving is still the fail-safe direction; the
                # operator just has to be able to tell this case from the one
                # above and delete the file by hand.
                _AMBIGUOUS_REASON="github-api-unreachable-merge-state-unknown"
                ;;
            *)
                _AMBIGUOUS_REASON="github-api-answer-unrecognized"
                ;;
        esac
        elif [ -n "$PARSE_PR" ] && [ -n "$CLAIMED_MERGE_PR" ] \
            && [ "$CLAIMED_MERGE_PR" != "unknown" ]; then
            # Both sides name a concrete PR but they differ — a cross-PR
            # mismatch, not a missing PR. Distinct reason so the operator is
            # never told "no PR was known" when two conflicting ones were.
            _AMBIGUOUS_REASON="github-api-not-queried-pr-mismatch-claimed-${CLAIMED_MERGE_PR}-parsed-${PARSE_PR}"
        else
            _AMBIGUOUS_REASON="github-api-not-queried-pr-not-explicitly-known"
        fi
        ;;
esac

# Helpers — kept in this scope so they can access CLAIMED_* and log_event.
release_claim_preserving_skip() {
    # Args: event_name reason
    rm -f "$PENDING_FILE"
    log_event "$1" "$2"
}

consume_bypass() {
    rm -f "$SKIP_FILE" "$PENDING_FILE"
    log_event "skip-pr-grind-consumed" "${_SUCCESS_SOURCE:-}"
}

case "$PARSE_STATUS" in
    success)
        # Pre-consumption validations (defense-in-depth against forgery,
        # tampering, and cross-PR token reuse). Any failure → release the
        # claim without consuming the skip file.
        #
        # Validation order matters: cheap checks first (existence), then
        # mtime tamper, then age re-check (re-applies the 30s anti-self-
        # bypass at the moment of consumption — not just at gate entry),
        # then PR equality.

        if [ ! -f "$SKIP_FILE" ]; then
            release_claim_preserving_skip "skip-pr-grind-released-tampered" \
                "skip-file-missing-at-confirm"
            exit 0
        fi

        # GNU-first: on Linux `stat -f` is --file-system and prints block info
        # to stdout (corrupting the value); `stat -c` is GNU's format flag. BSD
        # lacks -c and falls through to -f. (BSD-first here would return
        # "<fs-info>\n<mtime>" on Linux and read as an mtime tamper.)
        _CURRENT_SKIP_MTIME=$(stat -c %Y "$SKIP_FILE" 2>/dev/null \
            || stat -f %m "$SKIP_FILE" 2>/dev/null \
            || echo "")
        if [ -z "$_CURRENT_SKIP_MTIME" ] \
            || [ "$_CURRENT_SKIP_MTIME" != "$CLAIMED_SKIP_MTIME" ]; then
            release_claim_preserving_skip "skip-pr-grind-released-tampered" \
                "skip-mtime-changed-between-claim-and-confirm"
            exit 0
        fi

        _SKIP_AGE=$(( $(date +%s) - _CURRENT_SKIP_MTIME ))
        if [ "$_SKIP_AGE" -lt 30 ]; then
            release_claim_preserving_skip "skip-pr-grind-released-tampered" \
                "skip-file-younger-than-30s-at-confirm"
            exit 0
        fi

        # PR equality: require BOTH sides to be concretely known and equal.
        # If either side is missing or unknown, we cannot prove the consumed
        # bypass authorizes the merged PR — preserve the skip file rather
        # than risk a cross-PR token reuse via the auto-detect path
        # (`gh pr merge` with no explicit number relies on the current
        # branch to pick a PR, and that branch can change between gate and
        # confirm without the gate noticing).
        if [ -z "$PARSE_PR" ] \
            || [ -z "$CLAIMED_MERGE_PR" ] \
            || [ "$CLAIMED_MERGE_PR" = "unknown" ]; then
            release_claim_preserving_skip "skip-pr-grind-released-mismatch" \
                "pr-not-explicitly-known-on-claim-or-cmd-side"
            exit 0
        fi
        if [ "$PARSE_PR" != "$CLAIMED_MERGE_PR" ]; then
            release_claim_preserving_skip "skip-pr-grind-released-mismatch" \
                "claimed-pr-${CLAIMED_MERGE_PR}-but-cmd-merged-pr-${PARSE_PR}"
            exit 0
        fi

        consume_bypass
        ;;
    failure)
        release_claim_preserving_skip "skip-pr-grind-released" "merge-failed"
        ;;
    *)
        # Ambiguous output: fail-safe — release pending, preserve skip so
        # the operator can retry without a re-touch. Distinguished from the
        # plain failure path so the bypass log surfaces output-parsing gaps
        # for future tuning.
        release_claim_preserving_skip "skip-pr-grind-released-ambiguous" \
            "$_AMBIGUOUS_REASON"
        ;;
esac

exit 0
