#!/bin/bash
# Run available SAST tools on staged/changed files and output normalized JSON findings.
# Gracefully skips tools that aren't installed. Never fails the review due to missing tools.
#
# Usage: source this file, then call run_sast_scan "$staged_files"
# Output: JSON array on stdout — [{file, line, severity, category, description, suggestion, source}]
#
# Environment:
#   CODEX_SKIP_SAST=1     — skip all SAST scanning
#   CODEX_SAST_TIMEOUT=30 — per-tool timeout in seconds (default: 30)

set -euo pipefail

_SAST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect available SAST tools
_sast_has_semgrep() { command -v semgrep &>/dev/null; }
_sast_has_shellcheck() { command -v shellcheck &>/dev/null; }
_sast_has_trufflehog() { command -v trufflehog &>/dev/null; }

# Portable timeout (reuse from resolve-cli.sh if available)
_sast_timeout() {
  local duration="$1"; shift
  # Validate duration is numeric to prevent injection
  case "$duration" in
    ''|*[!0-9]*) duration=30 ;;
  esac
  if command -v timeout &>/dev/null; then
    timeout "$duration" "$@"
  elif command -v gtimeout &>/dev/null; then
    gtimeout "$duration" "$@"
  else
    # Perl fallback for macOS — pass duration safely as argument
    perl -e 'alarm shift @ARGV; exec @ARGV' "$duration" "$@"
  fi
}

# Merge two JSON arrays — shared helper to avoid copy-paste
_sast_merge_json() {
  printf '%s\n%s' "$1" "$2" | python3 -c "
import sys, json
arrays = []
for line in sys.stdin:
    line = line.strip()
    if line:
        try: arrays.extend(json.loads(line))
        except (json.JSONDecodeError, ValueError):
            print('WARNING: Failed to parse SAST output line (malformed JSON)', file=sys.stderr)
print(json.dumps(arrays))
"
}

# Run Semgrep on changed files
_sast_run_semgrep() {
  local files_list="$1"
  local timeout_sec="${CODEX_SAST_TIMEOUT:-30}"

  # Filter to file types Semgrep supports
  local semgrep_files
  semgrep_files=$(echo "$files_list" | grep -E '\.(js|jsx|ts|tsx|py|go|rb|java|php|rs|c|cpp|swift|kt)$' || true)
  [ -z "$semgrep_files" ] && { echo "[]"; return; }

  # Pass files as positional arguments (semgrep scan does NOT support --target-list)
  local raw_output
  # shellcheck disable=SC2086
  raw_output=$(_sast_timeout "$timeout_sec" semgrep scan \
    --config auto \
    --json \
    --quiet \
    $semgrep_files 2>/dev/null) || { echo "[]"; return; }

  # Normalize to our format
  echo "$raw_output" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    print('[]'); sys.exit(0)
findings = []
sev_map = {'ERROR': 'high', 'WARNING': 'medium', 'INFO': 'low'}
for r in data.get('results', []):
    findings.append({
        'file': r.get('path', ''),
        'line': r.get('start', {}).get('line', 0),
        'severity': sev_map.get(r.get('extra', {}).get('severity', ''), 'medium'),
        'category': 'security',
        'description': '[semgrep:' + r.get('check_id', 'unknown') + '] ' + r.get('extra', {}).get('message', ''),
        'suggestion': 'Fix the issue identified by Semgrep rule ' + r.get('check_id', 'unknown'),
        'source': 'sast:semgrep'
    })
print(json.dumps(findings))
" 2>/dev/null || echo "[]"
}

# Run ShellCheck on changed shell scripts
_sast_run_shellcheck() {
  local files_list="$1"
  local timeout_sec="${CODEX_SAST_TIMEOUT:-30}"

  # Filter to shell scripts
  local sh_files
  sh_files=$(echo "$files_list" | grep -E '\.(sh|bash)$' || true)
  [ -z "$sh_files" ] && { echo "[]"; return; }

  # Configurable extra ShellCheck checks (env var override)
  # Curated list targeting audit gap categories: portability, set-e interaction, quoting
  local enable_rules="${CODEX_SHELLCHECK_ENABLE:-check-extra-masked-returns,check-set-e-suppressed,quote-safe-variables,require-double-brackets}"
  # Validate: only allow alphanumeric, comma, hyphen, underscore (prevent injection)
  case "$enable_rules" in
    ''|,*|*,,*|*,)
      echo "⚠️  CODEX_SHELLCHECK_ENABLE is empty or malformed, using default" >&2
      enable_rules="check-extra-masked-returns,check-set-e-suppressed,quote-safe-variables,require-double-brackets" ;;
    *[!a-zA-Z0-9,_-]*)
      echo "⚠️  CODEX_SHELLCHECK_ENABLE contains invalid characters, using default" >&2
      enable_rules="check-extra-masked-returns,check-set-e-suppressed,quote-safe-variables,require-double-brackets" ;;
  esac

  # Run ShellCheck with JSON output on each file
  local all_findings="["
  local first=true
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    local file_output
    file_output=$(_sast_timeout "$timeout_sec" shellcheck \
      --enable="$enable_rules" \
      -f json "$f" 2>/dev/null) || true
    if [ -n "$file_output" ] && [ "$file_output" != "[]" ]; then
      if [ "$first" = true ]; then
        first=false
      else
        all_findings+=","
      fi
      # Strip outer brackets and append
      all_findings+=$(echo "$file_output" | sed 's/^\[//;s/\]$//')
    fi
  done <<< "$sh_files"
  all_findings+="]"

  # Normalize
  echo "$all_findings" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    print('[]'); sys.exit(0)
findings = []
sev_map = {'error': 'high', 'warning': 'medium', 'info': 'low', 'style': 'low'}
for r in data:
    findings.append({
        'file': r.get('file', ''),
        'line': r.get('line', 0),
        'severity': sev_map.get(r.get('level', ''), 'medium'),
        'category': 'bug',
        'description': '[shellcheck:SC' + str(r.get('code', 0)) + '] ' + r.get('message', ''),
        'suggestion': 'See https://www.shellcheck.net/wiki/SC' + str(r.get('code', 0)),
        'source': 'sast:shellcheck'
    })
print(json.dumps(findings))
" 2>/dev/null || echo "[]"
}

# Run TruffleHog on staged files for secrets
_sast_run_trufflehog() {
  local files_list="$1"
  local timeout_sec="${CODEX_SAST_TIMEOUT:-30}"

  [ -z "$files_list" ] && { echo "[]"; return; }

  # Create temp dir with symlinks to staged files (preserves real paths in output)
  local tmpdir
  tmpdir=$(mktemp -d)
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")

  while IFS= read -r f; do
    { [ -z "$f" ] || [ ! -f "$repo_root/$f" ]; } && continue
    local dir
    dir=$(dirname "$f")
    mkdir -p "$tmpdir/$dir"
    ln -s "$repo_root/$f" "$tmpdir/$f" 2>/dev/null || true
  done <<< "$files_list"

  local raw_output
  raw_output=$(_sast_timeout "$timeout_sec" trufflehog filesystem --json --no-update "$tmpdir" 2>/dev/null) || { rm -rf "$tmpdir"; echo "[]"; return; }

  local saved_tmpdir="$tmpdir"
  rm -rf "$tmpdir"

  [ -z "$raw_output" ] && { echo "[]"; return; }

  # TruffleHog outputs one JSON object per line (JSONL)
  echo "$raw_output" | python3 -c "
import sys, json
findings = []
tmpdir_prefix = sys.argv[1] if len(sys.argv) > 1 else ''
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        r = json.loads(line)
    except (json.JSONDecodeError, ValueError):
        continue
    raw_path = r.get('SourceMetadata', {}).get('Data', {}).get('Filesystem', {}).get('file', 'unknown')
    if tmpdir_prefix and raw_path.startswith(tmpdir_prefix):
        raw_path = raw_path[len(tmpdir_prefix):].lstrip('/')
    findings.append({
        'file': raw_path,
        'line': 0,
        'severity': 'high',
        'category': 'security',
        'description': '[trufflehog:' + r.get('DetectorName', 'secret') + '] Potential secret or credential detected',
        'suggestion': 'Remove the secret and rotate it immediately. Use environment variables or a secret manager.',
        'source': 'sast:trufflehog'
    })
print(json.dumps(findings))
" "$saved_tmpdir" 2>/dev/null || echo "[]"
}

# Main entry point: run all available SAST tools
# Args: $1 = newline-separated list of changed file paths
# Output: JSON array of all findings on stdout
run_sast_scan() {
  local files_list="$1"

  # Skip if disabled
  if [ "${CODEX_SKIP_SAST:-0}" = "1" ]; then
    echo "[]"
    return
  fi

  local all_findings="[]"
  local tool_count=0

  # Run each available tool
  if _sast_has_semgrep; then
    echo "   SAST: running semgrep..." >&2
    local semgrep_findings
    semgrep_findings=$(_sast_run_semgrep "$files_list")
    all_findings=$(_sast_merge_json "$all_findings" "$semgrep_findings")
    tool_count=$((tool_count + 1))
  fi

  if _sast_has_shellcheck; then
    echo "   SAST: running shellcheck..." >&2
    local sc_findings
    sc_findings=$(_sast_run_shellcheck "$files_list")
    all_findings=$(_sast_merge_json "$all_findings" "$sc_findings")
    tool_count=$((tool_count + 1))
  fi

  if _sast_has_trufflehog && [ -n "$files_list" ]; then
    echo "   SAST: running trufflehog..." >&2
    local th_findings
    th_findings=$(_sast_run_trufflehog "$files_list")
    all_findings=$(_sast_merge_json "$all_findings" "$th_findings")
    tool_count=$((tool_count + 1))
  fi

  if [ "$tool_count" -eq 0 ]; then
    echo "   SAST: no tools installed (semgrep, shellcheck, trufflehog) — skipping" >&2
  else
    local finding_count
    finding_count=$(echo "$all_findings" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    echo "   SAST: $tool_count tool(s) ran, $finding_count finding(s)" >&2
  fi

  echo "$all_findings"
}

# If run directly (not sourced), execute on staged files
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if ! git rev-parse --git-dir &>/dev/null; then
    echo "[]"
    exit 0
  fi
  STAGED_FILES=$(git diff --cached --name-only 2>/dev/null || echo "")
  run_sast_scan "$STAGED_FILES"
fi
