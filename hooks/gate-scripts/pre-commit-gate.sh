#!/usr/bin/env bash
# PreToolUse hook: gate git commit on review requirements
#
# Two mandatory gates before any git commit:
#   Gate 1: Design review — blocks if design docs written but not reviewed
#   Gate 2: Codex review  — blocks if no review-passed marker for current staged changes
#
# Fail-CLOSED: errors block commits (user preference: stuck > skipped review)
# Skip: $STATE_DIR/skip-litmus.local — a gitignored, operator-created file.
#       (The env-based SKIP_LITMUS escape was removed in issue #325 / ADR 0016:
#       a committed settings.json could inject it, so gate env is now sanitized.)

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
# Fail-CLOSED: errors block commits rather than silently approving.
# User preference: "a stuck session is better than a skipped review."
# Escape hatch: $STATE_DIR/skip-litmus.local (env-based skip removed — #325).
trap 'printf "{\"decision\":\"block\",\"reason\":\"Pre-commit gate error — blocking as precaution. If stuck, create '"$STATE_DIR"'/skip-litmus.local in your terminal.\"}\n"; exit 0' ERR

# ── Block emission helper (F6 fix) ────────────────────────────────────
# jq → python3 (json.dumps) → pure-shell escape. jq is NOT guaranteed on the
# sanitized PATH, so the python3 tier does the real escaping (backslash, newline,
# control chars) that sed alone cannot. Block decisions always emit as valid JSON.
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

# ── Circuit-breaker-aware block helper (Gate 2 marker rejections) ───────
# Every marker-specific rejection in Gate 2 (DEGRADED, stale PASS-MERGE,
# stale PASS-EXCLUDED, mismatched BUILTIN/bare-hash, unrecognized content)
# used to block via a bare `block_emit "$REASON"; exit 0`, bypassing the
# stuck-gate circuit breaker entirely. A workflow that regenerates a stale
# or invalid marker on every retry would then never receive the documented
# "gate has blocked N times" warning (cubic P2, PR #577). Centralizing the
# counter here keeps every marker-rejection call site consistent. Requires
# REPO_DIR/STATE_DIR to already be resolved — only called from Gate 2
# onward, well after gate_resolve_repo_dir has run.
gate_record_block_and_emit() {
    local reason="$1"
    mkdir -p "$REPO_DIR/$STATE_DIR" 2>/dev/null || true
    local counter="$REPO_DIR/$STATE_DIR/.gate-block-count.local"
    local count=0
    if [[ -f "$counter" ]]; then
        count=$(cat "$counter" 2>/dev/null || echo "0")
    fi
    # Normalize BEFORE any arithmetic. The counter file is ordinary on-disk
    # state, so its contents are not guaranteed to be a number — a truncated
    # write, a stray edit, or a leftover from another tool can leave `bad` or
    # an empty string there. Bash does NOT run the ERR trap for an
    # arithmetic-expansion error, so a bare `$((count + 1))` on garbage would
    # abort this function BEFORE `block_emit` ever ran: the hook would exit
    # without emitting a decision, which the harness reads as "no objection".
    # That turns the circuit breaker — a control meant only to WARN — into a
    # way to silently defeat the gate it reports on. Anything that is not a
    # plain 1-9 digit run resets to 0, and `10#` forces decimal so a
    # zero-padded value like `09` can never be read as a bad octal literal.
    [[ "$count" =~ ^[0-9]{1,9}$ ]] || count=0
    count=$((10#$count + 1))
    echo "$count" > "$counter" 2>/dev/null || true
    if [[ "$count" -ge 10 ]]; then
        reason="$reason

WARNING: This gate has blocked $count consecutive commits this session.
If you believe the gate is stuck, the user can run: touch $REPO_DIR/$STATE_DIR/skip-litmus.local"
    fi
    block_emit "$reason"
}

# ── Shared repo-dir resolver ──────────────────────────────────────────
# shellcheck source=lib/resolve-repo-dir.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/resolve-repo-dir.sh"

# ── python3 pre-check (F5 fix) ────────────────────────────────────────
# python3 is REQUIRED for git commit detection and all gate logic.
# If missing, block — fail-closed principle. The || true on the python3
# call below would otherwise silently allow ALL commits.
if ! command -v python3 &>/dev/null; then
    block_emit "CRITICAL: python3 not found. All review gates require python3 for JSON parsing and command detection. Install python3 to restore gate enforcement. Escape hatch: $STATE_DIR/skip-litmus.local"
    exit 0
fi

# Consume stdin
HOOK_DATA=$(cat 2>/dev/null || true)
[ -z "$HOOK_DATA" ] && exit 0

# Fast pre-filter: skip if hook data doesn't look like it could contain a git commit.
# NOTE: We require "Bash" tool_name to avoid false positives when prompt text piped
# to other tools (agy, codex) contains "git commit" as prose.
# Uses *git*commit* (not *git commit*) to also match `git -C <dir> commit`.
# The Python parser handles precision — this pre-filter just rejects obvious non-matches.
case "$HOOK_DATA" in
    *\"Bash\"*git*commit*) ;;
    *git*commit*\"Bash\"*) ;;
    *) exit 0 ;;
esac

# Parse tool name and command, verify git commit, and extract target directory
# from `cd <dir> &&` prefix or `git -C <dir>` flag.
# Fix: marker written by litmus in target repo was invisible to gate
# when committing to repos outside the session CWD (worktrees, temp clones).
_GATE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
PARSE_RESULT=$(printf '%s' "$HOOK_DATA" | PYTHONPATH="$_GATE_LIB" python3 -S -c "
import sys
# Drop CWD from sys.path (python3 -c prepends it ahead of PYTHONPATH) so a repo-
# controlled gitcmd_detect.py or shadowed stdlib (json.py) cannot run in the gate.
sys.path[:] = [p for p in sys.path if p not in ('', '.')]
try:
    import json
    from gitcmd_detect import git_commit
    d = json.load(sys.stdin)
    tool = d.get('tool_name', d.get('toolName', ''))
    if tool != 'Bash':
        sys.exit(0)
    cwd = d.get('cwd') or ''
    inp = d.get('tool_input', d.get('toolInput', {}))
    if isinstance(inp, str):
        inp = json.loads(inp)
    cmd = inp.get('command', '')
    is_commit, target_dir, is_amend, untrusted_cd = git_commit(cmd, with_untrusted_cd=True)
    if is_commit:
        # This hook frames its fields as LINES, so a NEWLINE in ANY emitted value
        # shifts every field after it. Directory names may legally contain one on
        # POSIX, so guarding only the cd operand was not enough: 'git -C' on a
        # crafted path forges the WHOLE frame -- a decoy target_dir, an attacker-
        # chosen HOOK_CWD anchor, and a BLANK untrusted_cd that erases this very
        # defense. No emitted field can legitimately contain a newline, so treat
        # it as unparseable and fail CLOSED rather than trying to re-frame.
        if any(not isinstance(v, str) or chr(10) in v or chr(13) in v for v in (target_dir, cwd, untrusted_cd)):
            raise ValueError('non-string or newline in an emitted field')
        print('yes')
        print(target_dir)
        print('1' if is_amend else '0')
        print(cwd)
        print(untrusted_cd)
except Exception:
    # Fail-CLOSED: fast pre-filter matched git commit pattern but parser
    # failed. Print sentinel so bash can block rather than silently approve.
    print('error')
    print('')
    print('')
    print('')
    print('')
" 2>/dev/null || true)

IS_GIT_COMMIT=$(echo "$PARSE_RESULT" | sed -n '1p')
TARGET_DIR=$(echo "$PARSE_RESULT" | sed -n '2p')
IS_AMEND=$(echo "$PARSE_RESULT" | sed -n '3p')
HOOK_CWD=$(echo "$PARSE_RESULT" | sed -n '4p')
# The cd operand that did NOT '&&'-gate the commit (see gitcmd_detect._untrusted_cd).
UNTRUSTED_CD=$(echo "$PARSE_RESULT" | sed -n '5p')

# Fail-closed: parser error after fast pre-filter matched → block as precaution
if [ "$IS_GIT_COMMIT" = "error" ]; then
    block_emit "Pre-commit gate: failed to parse tool input for command matching git commit pattern. Blocking as precaution (fail-closed). If stuck, create $STATE_DIR/skip-litmus.local in your terminal."
    exit 0
fi

[ "$IS_GIT_COMMIT" != "yes" ] && exit 0

# Resolve REPO_DIR (cwd-anchored; cd/-C target only as a safe refinement).
# Fail-CLOSED on command-substitution targets the gate cannot evaluate.
gate_resolve_repo_dir "$TARGET_DIR" "$HOOK_CWD" "$UNTRUSTED_CD"
if [ "$GATE_RESOLVE_STATUS" = "block-unresolvable" ]; then
    block_emit "Pre-commit gate: the command's cd target cannot be resolved statically. Either it uses a substitution or variable (cd \"\$(...)\", cd \$DIR, cd -, a glob), or it is a plain 'cd <dir>' that is NOT '&&'-joined to the git commit and resolves to a DIFFERENT repo than the session cwd -- so the gate cannot tell which repo receives it, and checking the wrong one would let an unreviewed change through. Commit from the repo root, join the cd with '&&' (cd /repo && git commit), use git -C /repo, or use cd \"\$(git rev-parse --show-toplevel)\" which the gate recognizes. Blocking as precaution (fail-closed)."
    exit 0
fi
# Genuinely not in a git repo → nothing to review (git commit fails on its own).
[ "$GATE_RESOLVE_STATUS" = "outside-repo" ] && exit 0
REPO_DIR="$GATE_REPO_DIR"

# ── --amend with no staged changes auto-pass ──────────────────────────
# A `git commit --amend` with no staged changes is a commit-message-only
# rewrite — the resulting commit has the same tree as HEAD, which already
# passed review to land. There's nothing new to review; allow.
#
# Empirical motivation: PR #96 grind hit commitlint footer-max-line-length
# on a pushed commit body. The fix required force-push amend. Litmus
# refused to run on empty staged diff ("No uncommitted changes detected"),
# but this gate still required litmus pass — deadlock. The user had to
# create \`$STATE_DIR/skip-litmus.local\` manually. This auto-pass eliminates
# the skip-file dance for commit-message-only amends.
#
# Safety: same invariant as the merge-commit auto-pass below — empty
# `git diff --cached` against HEAD means the commit introduces no new
# content vs. an already-reviewed HEAD, so no new review is needed.
# Amends WITH staged changes still go through the normal review gates
# (staged content IS new and must be reviewed). The narrow precondition
# `IS_AMEND=1 AND git diff --cached --quiet` is what keeps this bypass
# tight.
#
# Soft-spot: `git commit --amend <file>` (path-arg form) stages the
# file internally AFTER this hook fires, so `git diff --cached --quiet`
# returns true and we auto-pass without reviewing the staged change.
# This is the same soft-spot as `git commit -a` and chained
# `git add && git commit` (see "ACCEPTED RISK" block below). Not a new
# class of risk — the existing risk model accepts it.
if [ "$IS_AMEND" = "1" ]; then
    if git -C "$REPO_DIR" diff --cached --quiet 2>/dev/null; then
        # --amend with empty staged diff → commit-message-only rewrite
        # No new content to review; allow.
        exit 0
    fi
fi

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
#
# Related soft-spot: `git commit --amend <file>` (path-arg form) — the
# file is staged internally AFTER this hook fires, so `git diff --cached
# --quiet` returns true and the amend bypass allows the commit without
# reviewing the new content. Same class of risk as chained `git add &&
# git commit`. Not a new risk category — explicitly noted here so future
# maintainers recognize it as an examined gap, not an oversight.
# ─────────────────────────────────────────────────────────────────────────

# Skip overrides
# All marker/state files are scoped to $REPO_DIR (the cwd-anchored target repo),
# consistent with the litmus marker below and the sibling pre-pr/pre-merge gates,
# so a commit targeting a repo other than the hook process CWD reads the right
# $STATE_DIR/ directory.
if [ -f "$REPO_DIR/$STATE_DIR/skip-litmus.local" ] \
   && ! gate_skip_file_repo_controlled "$REPO_DIR" "$STATE_DIR/skip-litmus.local"; then
    # Reject skip files created within the last 30 seconds — likely Claude self-bypass.
    # A human-created skip file (via terminal) will typically be older.
    FILE_AGE=999
    _MTIME=$(stat -f %m "$REPO_DIR/$STATE_DIR/skip-litmus.local" 2>/dev/null) \
        || _MTIME=$(stat -c %Y "$REPO_DIR/$STATE_DIR/skip-litmus.local" 2>/dev/null) \
        || _MTIME=""
    [ -n "$_MTIME" ] && FILE_AGE=$(( $(date +%s) - _MTIME ))
    if [ "$FILE_AGE" -lt 30 ]; then
        WAIT_SECS=$(( 30 - FILE_AGE ))
        REASON="BLOCKED: skip-litmus.local is only ${FILE_AGE}s old (must be ≥30s to prevent self-bypass).

If the USER just created this file: wait ${WAIT_SECS} more seconds, then retry the commit.
If YOU created this file: STOP. Do NOT create skip files yourself. Run /litmus instead."
        block_emit "$REASON"
        exit 0
    fi
    # Single-use: consume the skip file after allowing one commit.
    # This prevents stale skip files from permanently disabling review gates.
    rm -f "$REPO_DIR/$STATE_DIR/skip-litmus.local"
    rm -f "$REPO_DIR/$STATE_DIR/.gate-block-count.local" 2>/dev/null || true  # Reset circuit breaker
    # ── Bypass telemetry ──────────────────────────────────────────────
    # Log skip-file consumption so there's an auditable record of bypasses.
    mkdir -p "$REPO_DIR/$STATE_DIR"
    printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-commit"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$REPO_DIR/$STATE_DIR/bypass-log.jsonl" 2>/dev/null || true
    exit 0
fi
# (env-based SKIP_LITMUS removed — issue #325; use the .local skip file. ADR 0016.)

# ── Gate 1: Design review (ADR-A/C — existence-keyed tokens) ──────────────
# Anchor on the cwd-resolved target repo; all linked worktrees share one marker
# dir. Pure-shell fast reject first, then the authoritative classifier only for
# the maybe-pending case. Readers NEVER mutate (ADR-C removes the whole-file rm).
if ! gate_marker_pending_pureshell "$REPO_DIR"; then
    _MK_RECS="$(mktemp 2>/dev/null)" || _MK_RECS=""
    _MK_CODE=0
    if [ -n "$_MK_RECS" ]; then
        gate_marker_pending "$REPO_DIR" >"$_MK_RECS" 2>/dev/null || _MK_CODE=$?
    else
        # mktemp failed — never redirect to a predictable path (symlink-clobber
        # risk). Take the decision without records.
        gate_marker_pending "$REPO_DIR" >/dev/null 2>&1 || _MK_CODE=$?
    fi
    if [ "$_MK_CODE" != "0" ]; then
        UNREVIEWED=""
        if [ "$_MK_CODE" = "2" ] || [ -z "$_MK_RECS" ]; then
            UNREVIEWED="  - (design review pending — run /blueprint-review to see the specific documents)\n"
        else
            # Shared renderer (resolve-repo-dir.sh) — annotates each doc with the
            # worktree that armed it when it isn't THIS commit's worktree (#356
            # cross-worktree visibility). REPO_DIR is the committing worktree.
            UNREVIEWED="$(gate_render_pending_records "$_MK_RECS" "$REPO_DIR")"
        fi
        rm -f "$_MK_RECS"
        # §6: a COMMIT is bypassed with skip-litmus.local (pre-commit consumes only
        # that, above, before this gate — NOT skip-design-review.local).
        REASON=$(printf "Design review required before committing.\n\nUnreviewed documents:\n%b\nRun /blueprint-review to review these documents, then try committing again.\n\nIf the user wants to bypass the commit: touch %s/%s/skip-litmus.local (pre-commit consumes skip-litmus.local, not skip-design-review.local). Do NOT create it yourself." "$UNREVIEWED" "$REPO_DIR" "$STATE_DIR")
        block_emit "$REASON"
        exit 0
    fi
    rm -f "$_MK_RECS"
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
# marker), codex review is redundant — the 3-tier blueprint review (Agy +
# Codex + Claude) already covered them. Skip Gate 2 to avoid wrong ordering
# where litmus runs on specs before blueprint-review.
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
        # or file is in a plans/ or specs/ directory under $STATE_DIR/ or docs/
        if echo "$staged_file" | grep -qiE '(^|/)(PLAN|DESIGN|ARCHITECTURE)[^/]*\.md$' || \
           echo "$staged_file" | grep -qE "(\\.${STATE_DIR#.}|docs)/([^/]+/)*(plans|specs)/.*\\.md\$"; then
            if gate_design_pass_honored "$FULL_PATH"; then
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

# ── TOCTOU fallback for design-reviewed bypass ───────────────────────────
# When `git add && git commit` is chained, PreToolUse fires before `git add`
# executes, so `git diff --cached` is empty (HAS_STAGED=false). Extract
# explicit file paths from the `git add` portion of the command and check
# those files for design-reviewed markers.
# Fail-closed: reject flags (-A, -u, -p), globs (*?[{), or any parse failure.
if [ "$HAS_STAGED" = false ]; then
    mkdir -p "$REPO_DIR/$STATE_DIR" 2>/dev/null || true
    TOCTOU_FILES=$(printf '%s' "$HOOK_DATA" | python3 -c "
import sys, json, re
try:
    d = json.load(sys.stdin)
    inp = d.get('tool_input', d.get('toolInput', {}))
    if isinstance(inp, str):
        inp = json.loads(inp)
    cmd = inp.get('command', '')
    segments = re.split(r'&&|\|\||[;\n]', cmd)
    files = []
    for seg in segments:
        seg = seg.strip()
        if not re.match(r'git\s+add\b', seg):
            continue
        words = seg.split()
        reject = False
        args = []
        past_sep = False
        for w in words[2:]:
            if w == '--':
                past_sep = True
                continue
            if not past_sep and w.startswith('-'):
                reject = True
                break
            if w == '.' or w.startswith('/') or '..' in w.split('/') or any(c in w for c in '*?[{'):
                reject = True
                break
            args.append(w)
        if reject or not args:
            files = []
            break
        files.extend(args)
    for f in files:
        print(f)
except Exception as e:
    import sys
    sys.stderr.write('toctou-parse-error: ' + repr(e) + '\n')
" 2>>"${REPO_DIR}/${STATE_DIR}/toctou-parse.log" || true)

    if [ -n "$TOCTOU_FILES" ]; then
        TOCTOU_ALL_SPECS=true
        TOCTOU_COUNT=0
        while IFS= read -r toctou_file; do
            [ -z "$toctou_file" ] && continue
            TOCTOU_COUNT=$((TOCTOU_COUNT + 1))
            FULL_PATH="$REPO_DIR/$toctou_file"
            IS_SPEC=false
            if echo "$toctou_file" | grep -qE '\.md$'; then
                if echo "$toctou_file" | grep -qiE '(^|/)(PLAN|DESIGN|ARCHITECTURE)[^/]*\.md$' || \
                   echo "$toctou_file" | grep -qiE "(\\.${STATE_DIR#.}|docs)/([^/]+/)*(plans|specs)/.*\\.md\$"; then
                    if [[ ! -L "$FULL_PATH" ]] && gate_design_pass_honored "$FULL_PATH"; then
                        IS_SPEC=true
                    fi
                fi
            fi
            if [ "$IS_SPEC" = false ]; then
                TOCTOU_ALL_SPECS=false
                break
            fi
        done <<< "$TOCTOU_FILES"

        if [ "$TOCTOU_ALL_SPECS" = true ] && [ "$TOCTOU_COUNT" -gt 0 ]; then
            exit 0  # TOCTOU bypass: all git-add files are design-reviewed specs
        fi
    fi
fi

# ── Gate 2: Codex review ─────────────────────────────────────────────────
MARKER="$REPO_DIR/$STATE_DIR/litmus-passed.local"
if [ -f "$MARKER" ]; then
    # Marker exists — verify it represents an actual review, not degraded mode.
    # DEGRADED markers (written when codex CLI is missing) must NOT pass the gate.
    # This prevents silent bypass of code review when codex is unavailable.
    MARKER_CONTENT=$(cat "$MARKER" 2>/dev/null || echo "")

    # The staged diff this commit would actually create. Every hash-bearing
    # marker format is bound to it below (#545): the marker is written on review
    # PASS and consumed only POST-commit, so between those two points an
    # unbound marker is a bearer token for whatever happens to be staged. A
    # marker minted for diff A must not authorize committing diff B — observed
    # live on 2026-08-01, where a marker hours old would have authorized a diff
    # whose own review had returned structured FAIL.
    #
    # Deliberately the BARE `git diff --cached`, byte-identical to every writer
    # (run-review-loop.sh, litmus/scripts/write-review-marker.sh) AND to
    # dispatcher-commit-block.sh, whose own comment already pins this coupling:
    # "Match the marker writer's hash form exactly: bare `git diff --cached`".
    # Four sites must agree; any one of them adding a flag makes the marker stop
    # matching and blocks every commit.
    #
    # SCOPE — be precise about what "bound to the diff" means here. This runs in
    # PreToolUse, BEFORE the command executes, so it binds the marker to the
    # index as it stands at DISPATCH time, not to what the command ultimately
    # commits. Two shapes still slip past and are NOT closed by this change:
    #   git add B && git commit …   the marker for A matches at hook time; B is
    #                               staged afterwards and committed unreviewed.
    #   git commit -a               stages tracked modifications at commit time,
    #                               likewise after this check has passed.
    # Both were equally unreviewed before (the gate accepted ANY marker), so this
    # is pre-existing exposure rather than a regression — but the binding must
    # not be read as more than it is. Closing them needs the command's own shape
    # to gate acceptance (refuse `-a`, refuse a compound that stages first);
    # tracked in #576.
    #
    # Known residual, NOT fixed here: porcelain `git diff` honors
    # GIT_EXTERNAL_DIFF and per-path textconv drivers, both reachable from
    # repo-controlled config, so a driver emitting constant output could collapse
    # two different diffs to one hash. PR mode already pins --no-ext-diff
    # --no-textconv (run-review-loop.sh:942); commit mode cannot adopt them
    # unilaterally — it is a coordinated change across all four sites and is
    # tracked separately. This is pre-existing exposure that the binding above
    # does not worsen.
    #
    # NOT computed here (Codex P2, PR #577): the two unconditional opt-outs
    # below (DEGRADED, SKIPPED-NONE) must always succeed even when `git diff
    # --cached` itself cannot run cleanly (a broken GIT_EXTERNAL_DIFF/textconv
    # driver, or neither sha256sum nor shasum present) — under `set -euo
    # pipefail` a failing pipeline here fires the script's ERR trap and blocks
    # BEFORE either opt-out is honored, defeating the documented
    # BUSDRIVER_REVIEW_CLI=none escape hatch. STAGED_HASH is computed lazily,
    # right after those two opt-outs, only for the branches that actually
    # bind to it.
    if echo "$MARKER_CONTENT" | grep -q "^DEGRADED"; then
        rm -f "$MARKER"
        REASON="Code review ran in DEGRADED mode (no review CLI installed). No actual code review was performed. Install a review CLI or create $STATE_DIR/skip-litmus.local to bypass."
        gate_record_block_and_emit "$REASON"
        exit 0
    elif [[ "$MARKER_CONTENT" =~ ^SKIPPED-NONE-[0-9]+$ ]]; then
        # BUSDRIVER_REVIEW_CLI=none — user explicitly opted out of review.
        # Accept unconditionally. See design spec §4 for risk analysis.
        # Carries no hash by construction: no review ran, so there is nothing
        # to bind it to. The opt-out is the operator's, and it is logged.
        #
        # `[[ =~ ]]` (not `grep -qE`) deliberately: bash's `=~` anchors `^`/`$`
        # against the WHOLE subject string, so a multi-line MARKER_CONTENT
        # whose first line merely starts with SKIPPED-NONE, or trailing
        # garbage after the epoch, fails the match. `grep` anchors per LINE,
        # so `grep -qE '^SKIPPED-NONE-[0-9]+$'` would still honor a marker
        # like "SKIPPED-NONE-123\nrm -rf /" because line 1 alone satisfies
        # the pattern. The hash arms below are safe from this because they
        # follow up with an exact `[ "$MARKER_CONTENT" = "$HASH" ]` compare;
        # this arm has no such follow-up (it's an unconditional exit), so the
        # anchor itself must be airtight.
        exit 0
    fi

    # Reached only for marker shapes that bind to the staged diff (PASS-MERGE
    # binds to emptiness instead, but is included here since it is not one of
    # the two unconditional opt-outs above).
    #
    # Fail-CLOSED, but through the circuit-breaker helper (cubic P1, PR #577):
    # under `set -euo pipefail`, letting this assignment fail bare would fire
    # the script's ERR trap (line 28) instead of `gate_record_block_and_emit`,
    # so a broken external diff driver (or a host with neither sha256sum nor
    # shasum) would block every commit WITHOUT ever incrementing the stuck-gate
    # counter or emitting its escape-hatch warning. Disabling `set -e` for the
    # single assignment (via `if ! STAGED_HASH=$(...); then`) lets a failure
    # reach the helper explicitly while still blocking — same fail-closed
    # outcome, but through the counted path.
    #
    # The marker is deliberately NOT deleted here. A broken diff driver or a
    # host missing both hashing tools says nothing about whether the marker is
    # valid — it only means we cannot check it right now. Deleting it would
    # turn a transient environment fault into a destroyed review: once the
    # driver is repaired the still-good marker is gone and the whole review has
    # to be re-run. Every OTHER rejection arm below deletes the marker because
    # it has PROVEN the marker wrong (mismatched hash, expired epoch,
    # unrecognized shape); this arm has proven nothing. Blocking without
    # deleting is the fail-closed outcome either way.
    if ! STAGED_HASH=$(git -C "$REPO_DIR" diff --cached 2>/dev/null | (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1); then
        REASON="Could not compute the staged-diff hash (external diff driver or hashing tool failed). Blocking rather than assuming a pass; the review marker is preserved so a retry can validate it once the environment is repaired. Run /litmus, or create $STATE_DIR/skip-litmus.local to bypass."
        gate_record_block_and_emit "$REASON"
        exit 0
    fi

    if echo "$MARKER_CONTENT" | grep -qE '^PASS-MERGE-[0-9]+$'; then
        # Merge commit whose resolution kept already-reviewed code unchanged
        # (run-review-loop.sh:846). Its precondition IS `git diff --cached
        # --quiet`, so bind it to that rather than to a hash: an empty staged
        # diff is the only state this marker was ever minted for. A merge that
        # resolved conflicts has a NON-empty diff, falls through to a real
        # review, and gets a bare-hash marker instead — so a PASS-MERGE marker
        # sitting in front of a non-empty diff is stale or forged, never valid.
        if git -C "$REPO_DIR" diff --cached --quiet 2>/dev/null; then
            exit 0
        fi
        rm -f "$MARKER"
        REASON="PASS-MERGE review marker present but the staged diff is not empty. That marker is only minted for a merge whose resolution changed nothing; a merge with real resolutions must be reviewed. Run /litmus."
        gate_record_block_and_emit "$REASON"
        exit 0
    elif echo "$MARKER_CONTENT" | grep -qE '^PASS-EXCLUDED-[a-f0-9]{64}-[0-9]{1,15}$'; then
        # Whole staged diff was excluded from review (lockfiles, minified
        # bundles, sourcemaps): no reviewer ran because there was nothing
        # reviewable. Diff-bound AND age-bound, the same shape pre-pr-gate.sh
        # already honors for PR mode.
        #
        # Commit mode used to write this epoch-only, on the grounds that the
        # pre-commit gate "accepts marker existence without hash verification".
        # That is no longer true, so run-review-loop.sh now emits the hash here
        # too and the epoch-only form is retired — it falls to the unrecognized
        # arm below rather than being honored, because it is precisely the
        # bearer token the rest of this change removes.
        #
        # Binding on the hash also avoids re-deriving the exclusion pathspec in
        # the gate. That was the tempting check — "is the staged diff still
        # all-excluded?" — and it is the wrong one: exclude-generated.sh merges
        # $STATE_DIR/review-exclude, which the working tree controls, so an
        # UNSTAGED widening of that file (adding `*`) neutralizes the check
        # while the marker stays valid. A hash over the staged diff cannot be
        # widened by editing a policy file.
        EXCLUDED_HASH=$(printf '%s' "$MARKER_CONTENT" | sed -E 's/^PASS-EXCLUDED-([a-f0-9]{64})-[0-9]{1,15}$/\1/')
        EXCLUDED_EPOCH=$(printf '%s' "$MARKER_CONTENT" | sed -E 's/^PASS-EXCLUDED-[a-f0-9]{64}-([0-9]{1,15})$/\1/')
        # `10#` forces base 10. A zero-padded epoch is all digits, so it passes
        # the pattern above, but bash reads a leading zero as OCTAL and aborts
        # on the digits 8 and 9 with "value too great for base". Measured, that
        # still BLOCKS today — the ERR trap catches it — so this is not a live
        # fail-open. Canonicalized anyway so the safety rests on an explicit
        # conversion rather than on a trap firing: move this line inside any
        # conditional (where `set -e` is suspended) and the accidental
        # protection silently disappears.
        #
        # The `{1,10}` bound above (cubic P1 finding) closes a SEPARATE overflow
        # path: bash's `$(( ))` does NOT error on 64-bit signed overflow for a
        # plain decimal/`10#` literal, it silently WRAPS (measured:
        # `$((10#18446744073709551616))` → 0). An unbounded `[0-9]+` epoch
        # therefore let an attacker who can write the marker file choose an
        # epoch of the form `real_target + k*2^64` that wraps to land inside
        # the current 1h freshness window, forging a "fresh" marker regardless
        # of its literal digit value. Ten digits caps the epoch at
        # 9999999999 (year 2286), 16 orders of magnitude below the 2^63
        # wraparound boundary, so the value reaching the arithmetic below is
        # never large enough to overflow.
        EXCLUDED_EPOCH=$((10#$EXCLUDED_EPOCH))
        EXCLUDED_AGE=$(( $(date +%s) - EXCLUDED_EPOCH ))
        if [ -n "$STAGED_HASH" ] && [ "$EXCLUDED_HASH" = "$STAGED_HASH" ] \
            && [ "$EXCLUDED_AGE" -ge 0 ] && [ "$EXCLUDED_AGE" -le 3600 ]; then
            exit 0
        fi
        rm -f "$MARKER"
        REASON="Excluded-only review marker is stale (over 1h old) or names a different diff than the one staged. That marker only certifies a diff with nothing reviewable in it. Run /litmus."
        gate_record_block_and_emit "$REASON"
        exit 0
    elif echo "$MARKER_CONTENT" | grep -qE '^BUILTIN-[a-f0-9]{64}$'; then
        # Built-in agent review — accept for the commit gate, but only for the
        # diff it reviewed. Post-commit hook excludes it from
        # reviewed-commits.local (a PR still requires the deep review).
        BUILTIN_HASH=${MARKER_CONTENT#BUILTIN-}
        if [ -n "$STAGED_HASH" ] && [ "$BUILTIN_HASH" = "$STAGED_HASH" ]; then
            exit 0
        fi
        rm -f "$MARKER"
        REASON="Builtin review marker is for a different diff than the one staged. Re-run /litmus so the review covers what you are committing."
        gate_record_block_and_emit "$REASON"
        exit 0
    elif echo "$MARKER_CONTENT" | grep -qE '^[a-f0-9]{64}$'; then
        # Genuine external review pass. Approve only when the marker names the
        # staged diff, and do NOT consume the marker — consumption is deferred
        # to PostToolUse (post-commit-consume-marker.sh), which verifies the
        # commit actually succeeded before deleting.
        #
        # Why defer: PreToolUse runs BEFORE git commit executes. If consumed
        # here and the commit then fails (git hooks, conflicts, errors), the
        # marker is lost — forcing a full re-review of unchanged code.
        if [ -n "$STAGED_HASH" ] && [ "$MARKER_CONTENT" = "$STAGED_HASH" ]; then
            exit 0
        fi
        rm -f "$MARKER"
        REASON="Review marker is for a different diff than the one staged (marker ${MARKER_CONTENT:0:12}..., staged ${STAGED_HASH:0:12}...). A review of one diff cannot authorize committing another. Run /litmus."
        gate_record_block_and_emit "$REASON"
        exit 0
    else
        # Unrecognized marker content — reject, matching pre-pr-gate.sh:321.
        # A gate that cannot prove the safe condition must block; "I do not
        # recognize this" is the failure case, not the happy path. This arm is
        # what closes the fail-open: every format the writers actually emit is
        # enumerated above, so anything reaching here is stale, hand-written,
        # or forged.
        rm -f "$MARKER"
        REASON="Review marker content not recognized: ${MARKER_CONTENT:0:30}... Rejecting rather than assuming a pass. Run /litmus."
        gate_record_block_and_emit "$REASON"
        exit 0
    fi
fi

# No valid review marker → block commit. Routed through the same
# gate_record_block_and_emit helper as every Gate 2 marker rejection above
# (single source of truth for the stuck-gate circuit breaker + escape hint —
# cubic P2, PR #577).
REASON="Code review required before committing.

Run /litmus to review your staged changes. The review must pass before git commit is allowed.

IMPORTANT: Do NOT create the skip file yourself. That is a user-only escape hatch. You MUST run litmus instead.
If the user wants to skip: touch $REPO_DIR/$STATE_DIR/skip-litmus.local
After the user creates the skip file, WAIT 30 SECONDS before retrying the commit (the gate rejects files newer than 30s to prevent self-bypass)."
gate_record_block_and_emit "$REASON"
