#!/usr/bin/env bash
# PreToolUse hook: run zizmor + checkov + trivy on staged files before git commit
#
# Scans staged files for security issues:
#   zizmor  — GitHub Actions workflow security          → WARN (informational)
#   checkov — IaC misconfigurations (Dockerfile, etc.)  → BLOCK (IaC vuln on prod = high cost)
#   trivy   — dependency vulnerabilities in lock files  → WARN (slow; CI trivy is the real gate)
#
# Skip: SKIP_IAC_SCAN=1

set -euo pipefail
trap 'exit 0' ERR  # Fail-open — IaC scanning is supplementary

# ── Skip override ────────────────────────────────────────────────────
[ "${SKIP_IAC_SCAN:-0}" = "1" ] && exit 0

# Consume stdin
HOOK_DATA=$(cat 2>/dev/null || true)
[ -z "$HOOK_DATA" ] && exit 0

# Fast pre-filter: only fire on git commit
# Uses *git*commit* (not *git commit*) to also match `git -C <dir> commit`
# (worktree commits). Council audit (2026-03-24): literal space pattern missed
# worktree commits, creating a bypass for IaC scanning.
case "$HOOK_DATA" in
    *\"Bash\"*git*commit*) ;;
    *git*commit*\"Bash\"*) ;;
    *) exit 0 ;;
esac

# python3 required for JSON parsing
command -v python3 &>/dev/null || exit 0

# Parse tool name and command, verify git commit is actual command.
# Walks words and skips flags (-C val, etc.) to find the actual git subcommand.
# Matches pre-commit-gitleaks.sh pattern for worktree-aware detection.
IS_GIT_COMMIT=$(printf '%s' "$HOOK_DATA" | python3 -c "
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
    for seg in re.split(r'&&|\|\||[;\n|]', cmd):
        seg = seg.strip()
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
                print('yes')
                break
except Exception:
    pass
" 2>/dev/null || true)

[ "$IS_GIT_COMMIT" != "yes" ] && exit 0

# Not in a git repo → skip
git rev-parse --is-inside-work-tree &>/dev/null || exit 0

# ── Collect staged files ───────────────────────────────────────────────
STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)
[ -z "$STAGED_FILES" ] && exit 0

FINDINGS=""
CHECKOV_BLOCKED=0

# ── zizmor: GitHub Actions workflow files (WARN) ──────────────────────
if command -v zizmor &>/dev/null; then
    WORKFLOW_FILES=$(echo "$STAGED_FILES" | grep -E '\.github/workflows/.*\.(yml|yaml)$' || true)
    if [ -n "$WORKFLOW_FILES" ]; then
        while IFS= read -r wf; do
            [ -f "$wf" ] || continue
            OUTPUT=$(zizmor --no-progress "$wf" 2>&1) || true
            if echo "$OUTPUT" | grep -qE '(warning|error)\['; then
                HITS=$(echo "$OUTPUT" | grep -cE '(warning|error)\[' 2>/dev/null || echo "0")
                FINDINGS="${FINDINGS}⚡ zizmor: ${HITS} finding(s) in $(basename "$wf")\n"
                FINDINGS="${FINDINGS}$(echo "$OUTPUT" | grep -E '(warning|error)\[' | head -3)\n"
            fi
        done <<< "$WORKFLOW_FILES"
    fi
fi

# ── checkov: IaC files (BLOCK) ────────────────────────────────────────
CHECKOV_CMD=""
if command -v checkov &>/dev/null; then
    CHECKOV_CMD="checkov"
elif python3 -c "import checkov" &>/dev/null 2>&1; then
    CHECKOV_CMD="python3 -m checkov.main"
fi

if [ -n "$CHECKOV_CMD" ]; then
    while IFS= read -r staged_file; do
        [ -z "$staged_file" ] && continue
        [ -f "$staged_file" ] || continue

        FRAMEWORK=""
        case "$staged_file" in
            *Dockerfile*|*dockerfile*)           FRAMEWORK="dockerfile" ;;
            *.tf|*.tf.json)                      FRAMEWORK="terraform" ;;
            *docker-compose*.yml|*docker-compose*.yaml) FRAMEWORK="docker_compose" ;;
            .github/workflows/*.yml|.github/workflows/*.yaml) FRAMEWORK="github_actions" ;;
            *k8s*/*.yml|*k8s*/*.yaml|*kubernetes*/*.yml|*kubernetes*/*.yaml) FRAMEWORK="kubernetes" ;;
            *helm*/*.yml|*helm*/*.yaml)          FRAMEWORK="helm" ;;
            *)                                   continue ;;
        esac

        OUTPUT=$($CHECKOV_CMD --file "$staged_file" --framework "$FRAMEWORK" --compact --quiet 2>&1) || true
        FAILED=$(echo "$OUTPUT" | grep -c "FAILED" 2>/dev/null || echo "0")
        PARSE_ERRORS=$(echo "$OUTPUT" | grep -cE "Parsing errors:" 2>/dev/null || echo "0")
        if [ "$FAILED" -gt 0 ]; then
            CHECKOV_BLOCKED=1
            FINDINGS="${FINDINGS}🛡 checkov BLOCKED: ${FAILED} failed check(s) in $(basename "$staged_file")\n"
            FINDINGS="${FINDINGS}$(echo "$OUTPUT" | grep "FAILED" | head -3)\n"
        elif [ "$PARSE_ERRORS" -gt 0 ]; then
            CHECKOV_BLOCKED=1
            FINDINGS="${FINDINGS}🛡 checkov BLOCKED: parse error in $(basename "$staged_file") — file could not be scanned\n"
        fi
    done <<< "$STAGED_FILES"
fi

# ── trivy: dependency vulnerabilities in lock files (WARN) ────────────
if command -v trivy &>/dev/null; then
    LOCKFILES=$(echo "$STAGED_FILES" | grep -E '(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|Cargo\.lock|requirements\.txt|poetry\.lock|uv\.lock|Pipfile\.lock|go\.sum|Gemfile\.lock|composer\.lock)$' || true)
    if [ -n "$LOCKFILES" ]; then
        # Resolve trivy cache dir (respects TRIVY_CACHE_DIR, macOS vs Linux defaults)
        TRIVY_CACHE="${TRIVY_CACHE_DIR:-}"
        if [ -z "$TRIVY_CACHE" ]; then
            if [ "$(uname)" = "Darwin" ]; then
                TRIVY_CACHE="${HOME}/Library/Caches/trivy/db"
            else
                TRIVY_CACHE="${HOME}/.cache/trivy/db"
            fi
        else
            TRIVY_CACHE="${TRIVY_CACHE}/db"
        fi
        # If no DB cached, skip trivy entirely (don't block commit on DB download)
        if [ ! -d "$TRIVY_CACHE" ] || [ -z "$(ls -A "$TRIVY_CACHE" 2>/dev/null)" ]; then
            echo "🔍 trivy: no vulnerability DB cached — run 'trivy image --download-db-only' to enable dep scanning"
        else
            # Scan only the staged lock files, not the entire repo
            # --scanners vuln: only vulnerabilities (skip secrets/misconfig — other tools handle those)
            # --severity HIGH,CRITICAL: skip low/medium noise
            # --skip-db-update: never block commit on network I/O
            while IFS= read -r lf; do
                [ -f "$lf" ] || continue
                # Portable timeout: prefer GNU timeout, fall back to no timeout
                TIMEOUT_CMD=""
                if command -v timeout &>/dev/null; then
                    TIMEOUT_CMD="timeout 30"
                elif command -v gtimeout &>/dev/null; then
                    TIMEOUT_CMD="gtimeout 30"
                fi
                OUTPUT=$($TIMEOUT_CMD trivy fs --scanners vuln --severity HIGH,CRITICAL --skip-db-update --no-progress "$lf" 2>/dev/null) || true
            # Check for actual vulnerability counts (not just "Total: 0")
            HAS_VULNS=$(echo "$OUTPUT" | grep -E "Total: [1-9]" 2>/dev/null || true)
            if [ -n "$HAS_VULNS" ]; then
                FINDINGS="${FINDINGS}🔍 trivy: vulnerabilities in $(basename "$lf")\n"
                FINDINGS="${FINDINGS}$(echo "$OUTPUT" | grep -E "(HIGH|CRITICAL)" | head -5)\n"
            fi
            done <<< "$LOCKFILES"
        fi
    fi
fi

# ── Output findings ───────────────────────────────────────────────────
if [ -n "$FINDINGS" ]; then
    # Informational findings (zizmor, trivy) go to stderr as context
    printf '%b' "$FINDINGS" >&2
fi

# checkov failures block the commit; zizmor and trivy are informational
if [ "$CHECKOV_BLOCKED" = "1" ]; then
    printf '{"decision":"block","reason":"checkov found IaC misconfigurations in staged files. Fix before committing. Skip: SKIP_IAC_SCAN=1"}\n'
    exit 0
fi

exit 0
