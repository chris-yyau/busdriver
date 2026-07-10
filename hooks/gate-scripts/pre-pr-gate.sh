#!/usr/bin/env bash
# PreToolUse hook: gate `gh pr create` on codex review of full base..HEAD diff
#
# Blocks PR creation until litmus passes on the aggregate branch diff.
# This catches code that escaped per-commit review (worktree commits, existing
# branches, pre-existing commits from other sessions).
#
# Fail-CLOSED: errors block PR creation (user preference: stuck > skipped review)
# Skip: $STATE_DIR/skip-litmus.local — git-resolved, operator-placed, single-use,
#       audited. No env-var hatch: a committed .claude/settings.json env block is
#       injectable by the PR under review (issue #325 / ADR 0016).
#
# Council decision (2026-03-21): Gate `gh pr create` only, NOT `git push`.
# Gating push kills WIP pushes and destroys credibility of the gate system.

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
trap 'printf "{\"decision\":\"block\",\"reason\":\"Pre-PR gate error — blocking as precaution. If stuck, create %s/skip-litmus.local in your terminal.\"}\n" "$STATE_DIR"; exit 0' ERR

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

# ── python3 pre-check ─────────────────────────────────────────────────
if ! command -v python3 &>/dev/null; then
    block_emit "CRITICAL: python3 not found. PR gate requires python3 for JSON parsing. Install python3 to restore gate enforcement."
    exit 0
fi

# Consume stdin
HOOK_DATA=$(cat 2>/dev/null || true)
[ -z "$HOOK_DATA" ] && exit 0

# Fast pre-filter: skip if hook data doesn't look like it could contain gh pr create
case "$HOOK_DATA" in
    *\"Bash\"*gh\ pr\ create*) ;;
    *gh\ pr\ create*\"Bash\"*) ;;
    *) exit 0 ;;
esac

# Parse tool name and command, verify gh pr create, and extract target directory
PARSE_RESULT=$(printf '%s' "$HOOK_DATA" | python3 -c "
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
        if re.match(r'gh\s+pr\s+create\b', seg):
            print('yes')
            print(target_dir)
            print(cwd)
            break
except Exception:
    # Fail-CLOSED: fast pre-filter matched gh pr create but parser failed.
    print('error')
    print('')
    print('')
" 2>/dev/null || true)

IS_GH_PR_CREATE=$(echo "$PARSE_RESULT" | head -1)
TARGET_DIR=$(echo "$PARSE_RESULT" | sed -n '2p')
HOOK_CWD=$(echo "$PARSE_RESULT" | sed -n '3p')

# Fail-closed: parser error after fast pre-filter matched → block as precaution
if [ "$IS_GH_PR_CREATE" = "error" ]; then
    block_emit "Pre-PR gate: failed to parse tool input for command matching gh pr create pattern. Blocking as precaution (fail-closed). If stuck, create $STATE_DIR/skip-litmus.local in your terminal."
    exit 0
fi

[ "$IS_GH_PR_CREATE" != "yes" ] && exit 0

# Resolve REPO_DIR (cwd-anchored; cd target only as a safe refinement).
# Fail-CLOSED on command-substitution targets the gate cannot evaluate.
gate_resolve_repo_dir "$TARGET_DIR" "$HOOK_CWD"
if [ "$GATE_RESOLVE_STATUS" = "block-unresolvable" ]; then
    block_emit "Pre-PR gate: the command's cd target uses command substitution the gate cannot resolve statically (e.g. cd \"\$(...)\"). Run gh pr create from the repo root, or use cd \"\$(git rev-parse --show-toplevel)\" which the gate recognizes. Blocking as precaution (fail-closed)."
    exit 0
fi
# Genuinely not in a git repo → approve (gh pr create fails on its own).
[ "$GATE_RESOLVE_STATUS" = "outside-repo" ] && exit 0
REPO_DIR="$GATE_REPO_DIR"

# ── Skip overrides (shared with commit gate) ──────────────────────────
SKIP_FILE="$REPO_DIR/$STATE_DIR/skip-litmus.local"
if [ -f "$SKIP_FILE" ]; then
    FILE_AGE=999
    _MTIME=$(stat -f %m "$SKIP_FILE" 2>/dev/null) \
        || _MTIME=$(stat -c %Y "$SKIP_FILE" 2>/dev/null) \
        || _MTIME=""
    [ -n "$_MTIME" ] && FILE_AGE=$(( $(date +%s) - _MTIME ))
    if [ "$FILE_AGE" -lt 30 ]; then
        rm -f "$SKIP_FILE"
        block_emit "BLOCKED: skip-litmus.local was created moments ago (likely self-bypass). Run /litmus instead."
        exit 0
    fi
    rm -f "$SKIP_FILE"
    mkdir -p "$REPO_DIR/$STATE_DIR"
    printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-pr"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$REPO_DIR/$STATE_DIR/bypass-log.jsonl" 2>/dev/null || true
    exit 0
fi
# No SKIP_LITMUS env-var hatch — injectable via committed settings.json
# (issue #325 / ADR 0016); use the skip file above.

# ── ~/.claude repo: auto-generated file bypass ────────────────────────
# If all changes on this branch vs main are auto-generated files, skip review.
REPO_ROOT=$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")
if [ "$REPO_ROOT" = "$HOME/.claude" ]; then
    BASE_BRANCH=$(git -C "$REPO_DIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main")
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
    while IFS= read -r changed_file; do
        [ -z "$changed_file" ] && continue
        HAS_FILES=true
        is_auto=false
        for pattern in "${AUTO_GEN_PATHS[@]}"; do
            case "$pattern" in
                */) case "$changed_file" in ${pattern}*) is_auto=true; break ;; esac ;;
                *)  [ "$changed_file" = "$pattern" ] && is_auto=true && break ;;
            esac
        done
        if [ "$is_auto" = false ]; then
            ALL_AUTO=false
            break
        fi
    done < <(git -C "$REPO_DIR" diff --name-only "${BASE_BRANCH}...HEAD" 2>/dev/null)
    if [ "$HAS_FILES" = true ] && [ "$ALL_AUTO" = true ]; then
        exit 0
    fi
fi

# ── Dual-voice PR review enforcement ──────────────────────────────────
# PR mode (litmus deep review) runs a Codex (xhigh reasoning) LEAD reviewer + ONE
# read-only Opus Security/Bugs BACKSTOP. The gate honors a PR only when:
#   • $STATE_DIR/pr-review-passed.local = the current base...HEAD diff hash, AND
#   • BOTH diff-bound artifacts are fresh status:PASS for that same hash:
#       pr-codex-lead.local.json   (the lead voice)
#       pr-backstop-verdict.local.json (the backstop voice)
# The gate re-verifies the artifacts INDEPENDENTLY of the marker, so a bare
# marker hash alone, a missing/stale artifact, or a backstop PASS without the
# lead never authorizes a PR. The commit marker ($STATE_DIR/litmus-passed.local)
# is NOT accepted here — per-commit review does not prove the PR-level dual-voice
# deep review ran (closes the prior commit-marker PR bypass). See ADR 0006.
#
# The PR gate does NOT consume the marker on success — post-pr-consume-marker.sh
# consumes it (and the artifacts) only after `gh pr create` actually succeeds,
# so a gh failure (bad --base, auth, network) doesn't burn the review.
PR_MARKER="$REPO_DIR/$STATE_DIR/pr-review-passed.local"
CODEX_LEAD_ART="$REPO_DIR/$STATE_DIR/pr-codex-lead.local.json"
BACKSTOP_ART="$REPO_DIR/$STATE_DIR/pr-backstop-verdict.local.json"

# Freshness window (shared with the writer). Integer seconds; default 3600.
MAX_AGE="${LITMUS_PR_BACKSTOP_MAX_AGE:-3600}"
case "$MAX_AGE" in ''|*[!0-9]*) MAX_AGE=3600 ;; esac

# verify_pr_artifact_gate <file> <expected_hash> <max_age> → 0 iff the artifact
# exists, parses, status==PASS, diff_hash==expected, and 0<=now-ts<=max_age.
verify_pr_artifact_gate() {
    local f="$1" expected="$2" max_age="$3"
    [ -f "$f" ] || return 1
    python3 - "$f" "$expected" "$max_age" <<'PYV' 2>/dev/null
import json, sys, time
f, expected, max_age = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    d = json.load(open(f))
except Exception:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
if d.get("status") != "PASS":
    sys.exit(1)
if d.get("diff_hash") != expected:
    sys.exit(1)
ts = d.get("ts")
if not isinstance(ts, int) or isinstance(ts, bool):
    sys.exit(1)
age = int(time.time()) - ts
if age < 0 or age > max_age:
    sys.exit(1)
sys.exit(0)
PYV
}

# Current base...HEAD diff hash (byte-identical to the writer: $()-captured diff
# fed via printf '%s', no trailing newline). Respect LITMUS_PR_BASE.
PR_BASE="${LITMUS_PR_BASE:-$(git -C "$REPO_DIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/||' || echo "origin/main")}"
[[ -n "${LITMUS_PR_BASE:-}" && "$PR_BASE" != origin/* ]] && PR_BASE="origin/${PR_BASE}"
# Compute the merge-base explicitly and diff from it, using the SAME expression
# as the writer's compute_pr_diff_hash (run-review-loop.sh): `git diff "${MB}...HEAD"`.
# `git diff A...HEAD` already means `git diff $(git merge-base A HEAD) HEAD`, so this
# is behaviorally identical to the old `${PR_BASE}...HEAD` form — but pinning the
# gate and the writer to the SAME formula keeps a single source of truth and removes
# any chance the two drift if one side is later edited.
MERGE_BASE=$(git -C "$REPO_DIR" merge-base "${PR_BASE}" HEAD 2>/dev/null || true)
DIFF_OUTPUT=$(git -C "$REPO_DIR" diff "${MERGE_BASE}...HEAD" 2>/dev/null || true)
CURRENT_HASH=$(printf '%s' "$DIFF_OUTPUT" | (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1)

# Fail-closed cleanup: if a marker exists but we could NOT compute a verifiable
# base...HEAD diff (empty merge-base, or an empty diff — e.g. a transient git
# failure, or a base ref that briefly disappeared), clear the marker AND both
# artifacts. Leaving them lets a later base restoration silently reuse stale
# review state instead of requiring a fresh review for the resolved diff.
if [ -f "$PR_MARKER" ] && { [ -z "$MERGE_BASE" ] || [ -z "$DIFF_OUTPUT" ]; }; then
    echo "[pre-pr-gate] Cannot compute a verifiable base...HEAD diff; clearing stale PR marker + artifacts (fail-closed)." >&2
    rm -f "$PR_MARKER" "$CODEX_LEAD_ART" "$BACKSTOP_ART"
fi

# Only honor a marker when we resolved a REAL base...HEAD diff. A failed/empty
# merge-base (missing or unrelated base ref) and an empty diff BOTH collapse to
# the empty-string SHA (e3b0c442...); honoring a marker that carries that hash
# would authorize a PR with no verified diff. Fail closed: skip all marker
# acceptance and fall through to the block below when there is nothing to gate.
if [ -n "$MERGE_BASE" ] && [ -n "$DIFF_OUTPUT" ] && [ -f "$PR_MARKER" ]; then
    PR_MARKER_CONTENT=$(cat "$PR_MARKER" 2>/dev/null || echo "")
    if echo "$PR_MARKER_CONTENT" | grep -qE '^(DEGRADED|SKIPPED-NONE|BUILTIN-)'; then
        rm -f "$PR_MARKER"
    elif echo "$PR_MARKER_CONTENT" | grep -qE '^[a-f0-9]{64}$'; then
        # Dual-voice deep-review marker: require hash match AND both fresh PASS artifacts.
        if [ "$PR_MARKER_CONTENT" = "$CURRENT_HASH" ] \
            && verify_pr_artifact_gate "$CODEX_LEAD_ART" "$CURRENT_HASH" "$MAX_AGE" \
            && verify_pr_artifact_gate "$BACKSTOP_ART" "$CURRENT_HASH" "$MAX_AGE"; then
            exit 0  # defer consumption to post-pr-consume-marker.sh
        else
            echo "[pre-pr-gate] PR marker present but dual-voice artifacts missing/stale/mismatched — re-run litmus PR review." >&2
            rm -f "$PR_MARKER"
        fi
    elif echo "$PR_MARKER_CONTENT" | grep -qE '^PASS-(FAST|EXCLUDED)-[a-f0-9]{64}-[0-9]+$'; then
        # Diff-bound bypass markers, both honored ONLY here (never the dual-artifact
        # path):
        #   PASS-FAST     — audited LITMUS_PR_FAST bypass: Codex lead ran, backstop skipped.
        #   PASS-EXCLUDED — the entire diff was excluded from review (lockfile/rules/
        #                   manifest-only PR): NO reviewer ran, nothing to review.
        # Accept ONLY if the embedded diff_hash matches the current diff AND it is
        # within max-age. A preserved marker (failed gh keeps markers) cannot
        # authorize a CHANGED diff. The (FAST|EXCLUDED) alternation is group 1, so
        # the hash/epoch captures shift to \2.
        FAST_HASH=$(printf '%s' "$PR_MARKER_CONTENT" | sed -E 's/^PASS-(FAST|EXCLUDED)-([a-f0-9]{64})-[0-9]+$/\2/')
        FAST_EPOCH=$(printf '%s' "$PR_MARKER_CONTENT" | sed -E 's/^PASS-(FAST|EXCLUDED)-[a-f0-9]{64}-([0-9]+)$/\2/')
        FAST_AGE=$(( $(date +%s) - FAST_EPOCH ))
        if [ "$FAST_HASH" = "$CURRENT_HASH" ] && [ "$FAST_AGE" -ge 0 ] && [ "$FAST_AGE" -le "$MAX_AGE" ]; then
            exit 0  # defer consumption to post-pr-consume-marker.sh
        else
            echo "[pre-pr-gate] Bypass marker stale or for a different diff — re-run litmus PR review." >&2
            rm -f "$PR_MARKER"
        fi
    else
        # Unrecognized PR marker format — reject (no blanket allow).
        echo "[pre-pr-gate] PR marker content not recognized — rejecting: ${PR_MARKER_CONTENT:0:30}..." >&2
        rm -f "$PR_MARKER"
    fi
fi

# NOTE: $STATE_DIR/litmus-passed.local (the commit marker) is intentionally NOT
# accepted for PR creation. Closing that path is the core fix in ADR 0006.

# No valid dual-voice review → block PR creation.
# The Codex lead runs on EVERY PR (no agents-only skip) — the lead must resolve
# to codex or the run is inconclusive/fail-closed (see run-review-loop.sh).
REASON="Code review required before creating a PR (litmus PR mode — deep review).

PR mode runs a Codex (xhigh reasoning) LEAD reviewer + ONE read-only Opus
Security/Bugs BACKSTOP. BOTH must PASS on the current base...HEAD diff, and the
gate verifies both diff-bound artifacts before honoring the marker.

  1. Run the Codex lead pass:
       LITMUS_MODE=pr bash \"\${BUSDRIVER_PLUGIN_ROOT:-\${CLAUDE_PLUGIN_ROOT}}/skills/litmus/scripts/init-review-loop.sh\" \\
         && LITMUS_MODE=pr bash \"\${BUSDRIVER_PLUGIN_ROOT:-\${CLAUDE_PLUGIN_ROOT}}/skills/litmus/scripts/run-review-loop.sh\"
  2. On Codex PASS, dispatch the read-only pr-security-backstop agent over the
     SAME base...HEAD diff (see skills/litmus/references/pr-review-mode.md).
  3. Persist its verdict (re-derives diff_hash/ts, fails closed on stale/bad input):
       <agent-json> | bash \"\${BUSDRIVER_PLUGIN_ROOT:-\${CLAUDE_PLUGIN_ROOT}}/skills/litmus/scripts/run-review-loop.sh\" --write-backstop-verdict
  4. Write the gate marker (requires BOTH voices PASS):
       bash \"\${BUSDRIVER_PLUGIN_ROOT:-\${CLAUDE_PLUGIN_ROOT}}/skills/litmus/scripts/run-review-loop.sh\" --write-pr-marker
  5. Retry gh pr create

IMPORTANT: Do NOT create the skip file yourself. That is a user-only escape hatch. You MUST run the reviewer instead.
If the user wants to skip: touch $REPO_DIR/$STATE_DIR/skip-litmus.local"
block_emit "$REASON"
