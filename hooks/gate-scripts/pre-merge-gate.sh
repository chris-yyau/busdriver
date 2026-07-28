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
    from gitcmd_detect import gh_pr, gh_pr_count, gh_pr_repo_override, gh_pr_auto_merge
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
    _present, target_dir, pr_num, untrusted_cd = gh_pr(cmd, 'merge', with_untrusted_cd=True)
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
    # #505: the same question, but scoped to the MERGE invocation's own argv. The
    # whole-command value above stays as-is for ADR 0024's non-gating advisory; only
    # this narrower one gates, because the coarse test also matches a sibling
    # \`gh -R ... pr view\` in the same call and would block pr-grind's auto-admin
    # merge. (Backticks MUST stay escaped: this block is a double-quoted shell string,
    # so a bare backtick pair is command substitution — an unescaped one here really
    # did run a stray \`gh\` on every merge-gate invocation.)
    merge_repo_override = 'yes' if gh_pr_repo_override(cmd, 'merge') else 'no'
    # Codex (#511): \`--auto\` queues the merge for whenever GitHub's required
    # checks/protections clear instead of merging immediately, so the head-SHA
    # / CI verification this gate performs at hook time can be stale by minutes
    # or hours when GitHub actually merges -- far past the few-second window
    # ADR 0030 Residual risk item 2 accepts. Scoped to the merge invocation's
    # own argv, same reasoning as merge_repo_override above.
    # (Backticks MUST stay escaped here too -- see the note above this block.)
    merge_auto = 'yes' if gh_pr_auto_merge(cmd, 'merge') else 'no'
    # cubic review (#511): the fields below are emitted one per line and read back
    # by the caller via \`sed -n 'Np'\` — a positional line protocol. pr_num,
    # target_dir, cwd, and untrusted_cd are the only fields whose content is not a
    # fixed literal ('yes'/'no'/an int), so they are the only ones that could
    # smuggle an embedded CR/LF (a CR/LF-bearing target_dir from a crafted \`cd\`
    # argument, an unusual hook-supplied cwd, or a CR/LF-bearing untrusted-cd
    # operand recorded by the loose-cd tracker -- #509) and shift every later
    # line — including merge_repo_override on line 7 and untrusted_cd on line 8,
    # the guards this PR and #509 each added. Reject any embedded CR/LF in those
    # fields by routing into the SAME except-Exception fail-closed branch as a
    # genuine parse error, rather than printing a field that could desynchronize
    # the line protocol. untrusted_cd is validated separately below, in the
    # merge_count>=1 branch, since it is only ever printed there.
    for _f in (pr_num, target_dir, cwd):
        if '\n' in _f or '\r' in _f:
            raise ValueError('embedded CR/LF in emitted hook field')
    # NOTE (#505): an earlier revision also tried to REQUIRE a head-pin flag here,
    # to close the preflight-to-merge window for a hand-typed merge. It was removed.
    # Deciding whether a flag is really on the merge argv means parsing a command
    # this hook never executes, and review found a fresh evasion every round: prose,
    # comments, redirect targets, heredoc delimiters, fd-name redirections, and a SHA
    # supplied by an unrelated assignment while the real operand was a command
    # substitution. That is the documented anti-pattern -- a regex over an un-run
    # command is not a security boundary -- and each patch added complexity to
    # something that could never become one. The window is handled where it can be:
    # pr-grind own merges pass the pin from a template-substituted REVIEWED_HEAD
    # (#427, no parsing), and the marker-vs-live-HEAD check below reads authoritative
    # GitHub state rather than the command string. See ADR 0030 Residual risk.
    if merge_count >= 1:
        # This hook frames its fields as LINES, so a NEWLINE in ANY emitted value
        # shifts every field after it. Directory names may legally contain one on
        # POSIX, so guarding only the cd operand was not enough: 'git -C' on a
        # crafted path forges the WHOLE frame -- a decoy target_dir, an attacker-
        # chosen HOOK_CWD anchor, and a BLANK untrusted_cd that erases this very
        # defense. No emitted field can legitimately contain a CR or LF, so treat
        # one as unparseable and fail CLOSED rather than trying to re-frame.
        # untrusted_cd is populated unconditionally by gh_pr() above but only ever
        # printed here, so it is validated here rather than in the earlier loop
        # (which runs even when merge_count == 0 and nothing is printed).
        if not isinstance(untrusted_cd, str) or '\n' in untrusted_cd or '\r' in untrusted_cd:
            raise ValueError('non-string or embedded CR/LF in untrusted_cd')
        # Use newline separator: target_dir may contain '|' on weird paths
        print('yes' if merge_count == 1 else 'multi')
        print(pr_num)
        print(target_dir)
        print(merge_count)
        print(cwd)
        print(repo_override)
        print(merge_repo_override)
        print(untrusted_cd)
        print(merge_auto)
except Exception:
    print('error')
    print('')
    print('')
    print('0')
    print('')
    print('yes')
    print('yes')
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
# #505 merge-scoped override (gates); fail-safe 'yes' on any parse anomaly.
MERGE_REPO_OVERRIDE=$(echo "$MERGE_PARSE" | sed -n '7p')
case "$MERGE_REPO_OVERRIDE" in yes|no) ;; *) MERGE_REPO_OVERRIDE=yes ;; esac
case "$REPO_OVERRIDE" in yes|no) ;; *) REPO_OVERRIDE=yes ;; esac
# The cd operand that did NOT '&&'-gate the merge (see gitcmd_detect._untrusted_cd).
UNTRUSTED_CD=$(echo "$MERGE_PARSE" | sed -n '8p')
# Codex (#511): 'yes' -> the merge invocation carries --auto. Fail-safe 'yes'
# (blocks) on any parse anomaly, same posture as MERGE_REPO_OVERRIDE.
MERGE_AUTO_FLAG=$(echo "$MERGE_PARSE" | sed -n '9p')
case "$MERGE_AUTO_FLAG" in yes|no) ;; *) MERGE_AUTO_FLAG=yes ;; esac

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
gate_resolve_repo_dir "$TARGET_DIR" "$HOOK_CWD" "$UNTRUSTED_CD"
if [ "$GATE_RESOLVE_STATUS" = "block-unresolvable" ]; then
    block_emit "Pre-merge gate: the command's cd target cannot be resolved statically. Either it uses a substitution or variable (cd \"\$(...)\", cd \$DIR, cd -, a glob), or it is a plain 'cd <dir>' that is NOT '&&'-joined to the gh pr merge and resolves to a DIFFERENT repo than the session cwd -- so the gate cannot tell which repo receives it, and checking the wrong one would let an unreviewed change through. Merge from the repo root, join the cd with '&&' (cd /repo && gh pr merge), or use cd \"\$(git rev-parse --show-toplevel)\" which the gate recognizes. Blocking as precaution (fail-closed)."
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

# ── Cross-repo guard (covers BOTH evidence-based allow paths) ────────
# Every check the allow paths below perform — the marker's head SHA, `gh pr checks`,
# and the bootstrap path's `gh pr diff` — resolves against REPO_DIR's origin. A
# repo/host selector on the MERGE makes it target a different repo, where "PR #N" is
# an unrelated pull request none of that evidence covers.
#
# Gates on gitcmd_detect.gh_pr_repo_override, not ADR 0024's whole-command substring.
# That function scopes the FLAG form (-R/--repo) to the merge's own argv and the ENV
# form (GH_REPO=/GH_HOST=) to the whole command — a flag cannot reach a sibling, an
# assignment can (it survives quoting, grouping and `bash -c` wrapping). ADR 0024's
# coarse form matches a sibling `gh -R ... pr view` in the same Bash call, which
# blocked pr-grind's OWN auto-admin merge (that block runs the view and the merge in
# one fenced call) — verified in-tree before this was scoped.
#
# Placed ABOVE both branches deliberately: guarding only the marker path would leave
# the bootstrap path able to authorize `gh pr merge N -R other/repo` off this
# checkout's diff and CI. Sibling gates get unified, never special-cased. The operator
# skip path is intentionally NOT covered — it exits earlier and is an explicit human
# bypass, not an evidence-based authorization.
#
# Defense-in-depth, NOT a boundary: a selector built by shell expansion, or an
# exported GH_REPO, is invisible to a hook that never runs the command. Safe here
# because a miss just returns to the PRE-EXISTING behaviour (before #505 this path
# already validated `gh pr checks` against REPO_DIR with no repo guard at all), while
# a hit blocks. See ADR 0030 Residual risk.
if [ "$MERGE_REPO_OVERRIDE" = "yes" ]; then
    block_emit "Pre-merge gate: the merge command carries a repo/host override (-R/--repo/GH_REPO=/GH_HOST=), so PR #${MERGE_PR_NUM:-?} may not be the PR verified in this checkout — the marker, CI results and diff all come from ${REPO_DIR:-this repo}'s origin. Run \`/pr-grind\` in a checkout of the target repo and merge from there, or drop the override. Marker (if any) preserved."
    exit 0
fi

# ── Auto-merge queuing guard (Codex #511) ─────────────────────────────
# `gh pr merge --auto` does not merge immediately — GitHub QUEUES it and
# merges automatically once required checks/protections clear, which can be
# minutes to hours later, not the few-second window ADR 0030 Residual risk
# item 2 accepts ("A push landing between the head-SHA check and GitHub
# processing a hand-typed `gh pr merge`... Scale: the window is the seconds
# between hook and API call"). Both evidence-based allow paths below (marker
# and bootstrap) verify the CURRENT head SHA / CI state at HOOK time; a
# `--auto` queue defers the actual merge past that verification with no
# re-check, so a push landing in the (now unbounded) gap is queued through
# unreviewed. Placed above both branches, same as MERGE_REPO_OVERRIDE above —
# unify sibling gates, don't special-case one allow path.
#
# This is NOT the reverted "require --match-head-commit on the merge argv"
# fight: that required PROVING a flag's presence, so a parser miss failed
# OPEN (an unpinned merge looked identical to a compliant one). This detects
# --auto's PRESENCE and blocks, so a parser miss fails safe — the merge just
# proceeds exactly as it would have before this guard existed, never worse.
# The operator re-runs a normal (non-queued) `gh pr merge` once checks are
# green, which they already must be for either allow path to authorize.
if [ "$MERGE_AUTO_FLAG" = "yes" ]; then
    block_emit "Pre-merge gate: \`gh pr merge --auto\` queues the merge for whenever GitHub's required checks/protections clear rather than merging immediately, so the head-SHA / CI verification this gate performs right now can be minutes or hours stale by the time GitHub actually merges — a push landing in that window would be queued through unreviewed. Re-run \`gh pr merge ${MERGE_PR_NUM:-<PR_NUMBER>}\` (with --squash/--rebase/--admin as appropriate) WITHOUT --auto once checks are green. Marker (if any) preserved."
    exit 0
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
        #
        # Marker contract: `<PR_NUMBER> <HEAD_FULL_SHA>` on line 1. The SHA field
        # is what makes the marker an assertion about a SPECIFIC COMMIT rather
        # than about a PR number for the next 2 hours. Do NOT collapse this back
        # to `tr -d '[:space:]'` over the whole file: that concatenated the two
        # fields into one non-digit blob.
        MARKER_RAW=$(tr -d '\r' < "$MARKER_FILE" 2>/dev/null || true)
        PR_NUM=$(printf '%s\n' "$MARKER_RAW" | awk 'NR==1{print $1}')
        MARKER_SHA=$(printf '%s\n' "$MARKER_RAW" | awk 'NR==1{print $2}')
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
        # ── Marker must authorize the COMMIT being merged, not just the PR ──
        # The marker is per-PR AND fresh-for-2-hours, but until #505 it carried no
        # commit identity. A push landing AFTER pr-grind converged left the marker
        # valid, so `gh pr merge <same-PR>` merged a HEAD no reviewer had cleared.
        # Observed (chrisyau.me#181): grind converged on 866eb7d4 → operator pushed
        # 10090de5 at 09:11:56Z → Codex posted 3 P2s at 09:17:21Z and Greptile 2 P1s
        # at 09:21:10Z on that new HEAD → merged 09:56:27Z with all five unresolved.
        # The wrap-up's "all threads on the prior HEAD resolved" was true of the SHA
        # the grind actually validated, which is precisely the bug: the ack ledger
        # (scripts/ack-ledger.sh Tier A returns `stale` on unresolved non-outdated
        # threads) had never seen the merged commit at all.
        #
        # Fail-CLOSED throughout: a marker with no/!40-hex SHA (pre-#505 writer), a
        # missing `gh`, or an unresolvable head OID all BLOCK. Unresolvable commit
        # identity is the failure case, not the happy path.
        case "$MARKER_SHA" in
            *[!0-9a-fA-F]*|'')
                rm -f "$MARKER_FILE"
                block_emit "Pre-merge gate: pr-grind-clean marker carries no valid head SHA (it must be \`<PR_NUMBER> <HEAD_SHA>\`). Marker removed — it cannot prove which commit was reviewed. Run \`/pr-grind $MERGE_PR_NUM\` before merging."
                exit 0
                ;;
        esac
        if [ "${#MARKER_SHA}" -ne 40 ]; then
            rm -f "$MARKER_FILE"
            block_emit "Pre-merge gate: pr-grind-clean marker head SHA is not a full 40-char OID (got '${MARKER_SHA}'). Marker removed. Run \`/pr-grind $MERGE_PR_NUM\` before merging."
            exit 0
        fi
        if ! command -v gh &>/dev/null; then
            block_emit "Pre-merge gate: \`gh\` is unavailable, so the pr-grind marker's head SHA cannot be checked against PR #$PR_NUM's current HEAD. Blocking as precaution (fail-closed)."
            exit 0
        fi
        # `|| LIVE_HEAD_OID=""` is load-bearing under `set -euo pipefail`: without it a
        # failing gh (auth/network/unknown PR) makes the assignment non-zero and fires
        # the ERR trap, emitting the GENERIC gate-error block instead of the tailored
        # "unable to resolve ... Marker preserved" message below — i.e. the branch this
        # diff adds would be unreachable for the most common real failure. Same shape as
        # the `gh pr checks` call further down.
        LIVE_HEAD_OID=$(cd "$REPO_DIR" && gh pr view "$PR_NUM" --json headRefOid -q .headRefOid 2>/dev/null | tr -d '[:space:]') || LIVE_HEAD_OID=""
        # Require a FULL 40-char hex OID, not merely "hex or empty". A truncated but
        # all-hex value (partial read, an abbreviated id) would otherwise pass this
        # check and then be compared as authoritative below, deleting a perfectly
        # valid marker on a bogus "HEAD moved". Anything short of a full OID is a
        # VERIFICATION failure — which preserves the marker — not a staleness verdict.
        LIVE_OID_OK=1
        [ "${#LIVE_HEAD_OID}" -eq 40 ] || LIVE_OID_OK=0
        case "$LIVE_HEAD_OID" in *[!0-9a-fA-F]*|'') LIVE_OID_OK=0 ;; esac
        if [ "$LIVE_OID_OK" -eq 0 ]; then
            block_emit "Pre-merge gate: unable to resolve PR #$PR_NUM's current head SHA as a full 40-char OID (\`gh pr view --json headRefOid\` returned '${LIVE_HEAD_OID:-<empty>}'). Resolve GitHub CLI/auth/network issues and retry. Marker preserved."
            exit 0
        fi
        # Both sides are validated as case-INsensitive hex, so compare case-insensitively
        # too: an uppercase marker would otherwise read as "HEAD moved" and delete a
        # valid marker for a commit that never changed.
        MARKER_SHA=$(printf '%s' "$MARKER_SHA" | tr 'A-F' 'a-f')
        LIVE_HEAD_OID=$(printf '%s' "$LIVE_HEAD_OID" | tr 'A-F' 'a-f')
        # SCOPE (ADR 0030, Residual risk item 2 — accepted, do not "fix" here): this
        # is a PreToolUse hook, so the comparison is a PREFLIGHT. It cannot pin a
        # hand-typed merge, and a push landing between here and GitHub processing the
        # merge is still possible. pr-grind's OWN merges are unaffected — they carry
        # --match-head-commit "$REVIEWED_HEAD" (#427) by template substitution, so
        # GitHub itself refuses a moved head. REQUIRING that flag on arbitrary
        # operator commands was implemented and REVERTED: it means parsing a command
        # this hook never executes, and review defeated every version of that parse.
        # Closing this window belongs SERVER-side (branch protection), not here.
        # Scale: seconds, against the ~45 min the unpinned 2-hour marker allowed.
        if [ "$LIVE_HEAD_OID" != "$MARKER_SHA" ]; then
            rm -f "$MARKER_FILE"
            block_emit "Pre-merge gate: PR #$PR_NUM HEAD moved since pr-grind declared it clean — marker cleared ${MARKER_SHA:0:9}, current HEAD is ${LIVE_HEAD_OID:0:9}. The new commit has not been through the reviewer-ack ledger, and bots may have posted findings on it that no round ever triaged. Marker removed. Run \`/pr-grind $MERGE_PR_NUM\` on the current HEAD before merging."
            exit 0
        fi
        # The comparison above is a PREFLIGHT: this hook fires before the command
        # runs, so a push landing between here and GitHub processing the merge is
        # still possible. Requiring the merge itself to carry --match-head-commit was
        # tried and REVERTED (see the NOTE in the parse block above and ADR 0030):
        # proving a flag is on the merge argv means parsing a command this hook never
        # executes. pr-grind's own merges pin via a template-substituted REVIEWED_HEAD
        # (#427), and closing the window for hand-typed merges belongs server-side.
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
