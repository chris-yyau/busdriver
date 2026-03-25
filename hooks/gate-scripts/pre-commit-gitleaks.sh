#!/usr/bin/env bash
# PreToolUse hook: scan staged changes for secrets before git commit
#
# Runs gitleaks on staged changes to catch hardcoded secrets, API keys,
# tokens, and credentials before they enter git history.
#
# Deterministic gate — not AI review. High signal, low noise.
# Council decision (2026-03-21): Tier 1 priority, non-negotiable.
#
# Fail-CLOSED: errors block commits (secrets in history are catastrophic)
# Skip: SKIP_GITLEAKS=1 (env var only — no file-based bypass)

set -euo pipefail
trap 'printf "{\"decision\":\"block\",\"reason\":\"Gitleaks hook error — blocking as precaution. Set SKIP_GITLEAKS=1 to bypass.\"}\n"; exit 0' ERR

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

# ── Skip override ────────────────────────────────────────────────────
[ "${SKIP_GITLEAKS:-0}" = "1" ] && exit 0

# ── gitleaks availability check ──────────────────────────────────────
if ! command -v gitleaks &>/dev/null; then
    # Degrade gracefully — warn but don't block if gitleaks not installed.
    # Unlike codex review, secret scanning is supplementary to other gates.
    exit 0
fi

# Consume stdin
HOOK_DATA=$(cat 2>/dev/null || true)
[ -z "$HOOK_DATA" ] && exit 0

# Fast pre-filter: only fire on git commit
# Uses *git*commit* (not *git commit*) to also match `git -C <dir> commit`.
# Council audit (2026-03-24): literal space pattern missed worktree commits.
case "$HOOK_DATA" in
    *\"Bash\"*git*commit*) ;;
    *git*commit*\"Bash\"*) ;;
    *) exit 0 ;;
esac

# ── python3 check for command parsing ────────────────────────────────
if ! command -v python3 &>/dev/null; then
    # Can't parse — skip rather than block (gitleaks is supplementary)
    exit 0
fi

# Parse tool name and command, verify git commit, extract target directory.
# Matches pre-commit-gate.sh pattern: walks words, skips flags (-C val, etc.)
# to find the actual git subcommand. Extracts target dir from `cd <dir> &&`
# prefix or `git -C <dir>` flag for worktree-aware scanning.
PARSE_RESULT=$(printf '%s' "$HOOK_DATA" | python3 -c "
import sys, json, re
try:
    d = json.load(sys.stdin)
    tool = d.get('tool_name', d.get('toolName', ''))
    if tool != 'Bash':
        sys.exit(0)
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
            target_dir = cd_m.group(1).strip().strip('\042\047')
            continue
        while re.match(r'^\w+=\S*\s', seg):
            seg = re.sub(r'^\w+=\S*\s+', '', seg, count=1)
        if re.match(r'git\b', seg):
            words = seg.split()
            skip_next = False
            found = False
            for w in words[1:]:
                if skip_next:
                    skip_next = False
                    continue
                if w in ('-C', '-c'):
                    skip_next = True
                    continue
                if w.startswith('-'):
                    continue
                found = (w == 'commit')
                break
            if found:
                c_m = re.search(r'-C\s+(\S+)', seg)
                if c_m:
                    target_dir = c_m.group(1).strip('\042\047')
                print('yes')
                print(target_dir)
                break
except Exception:
    pass
" 2>/dev/null || true)

IS_GIT_COMMIT=$(echo "$PARSE_RESULT" | head -1)
TARGET_DIR=$(echo "$PARSE_RESULT" | sed -n '2p')

[ "$IS_GIT_COMMIT" != "yes" ] && exit 0

# Resolve to git repo root (TARGET_DIR may be a subdirectory, not the root)
REPO_DIR=$(git -C "${TARGET_DIR:-.}" rev-parse --show-toplevel 2>/dev/null || echo "${TARGET_DIR:-.}")

# Not in a git repo → approve
git -C "$REPO_DIR" rev-parse --is-inside-work-tree &>/dev/null || exit 0

# ── Run gitleaks on staged changes ───────────────────────────────────
# --staged: only scan staged changes (what's about to be committed)
# --no-banner: suppress version banner
# --exit-code: non-zero on findings
# Run in target repo directory for worktree-aware scanning.
GITLEAKS_OUTPUT=$(cd "$REPO_DIR" && gitleaks protect --staged --no-banner 2>&1) || true
GITLEAKS_EXIT=$?

# Exit code 0 = no leaks found
if [ "$GITLEAKS_EXIT" -eq 0 ]; then
    exit 0
fi

# Exit code 1 = leaks found — BLOCK
if [ "$GITLEAKS_EXIT" -eq 1 ]; then
    # Truncate output for block message
    TRUNCATED=$(echo "$GITLEAKS_OUTPUT" | head -20)
    REASON="SECRET DETECTED in staged changes — commit blocked.

Gitleaks found potential secrets/credentials:

${TRUNCATED}

Fix: Remove the secret from staged files and use environment variables or a secret manager instead.

If this is a false positive (e.g., test fixture), add it to .gitleaksignore.
To bypass: set SKIP_GITLEAKS=1 (use with extreme caution)."
    block_emit "$REASON"
    exit 0
fi

# Other exit codes (errors) — let through (fail-open for tool errors,
# fail-closed only for actual secret findings)
exit 0
