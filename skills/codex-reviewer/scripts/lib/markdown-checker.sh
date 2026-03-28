#!/bin/bash
# Validate changed markdown files: broken URLs and lint violations.
#
# Usage: source this file, then call run_markdown_checks "$files_list"
# Output: JSON array of findings on stdout.
#
# Environment:
#   CODEX_SKIP_MARKDOWN=1       — skip all markdown checks
#   CODEX_CHECK_URLS=1          — enable URL validation (disabled by default — slow)
#   CODEX_MARKDOWN_TIMEOUT=5    — per-URL timeout in seconds (default: 5)

set -euo pipefail

_md_has_markdownlint() { command -v markdownlint-cli2 &>/dev/null || command -v markdownlint &>/dev/null; }

# Run markdownlint on changed .md files
_md_run_lint() {
  local files_list="$1"

  local md_files
  md_files=$(echo "$files_list" | grep -E '\.md$' || true)
  [ -z "$md_files" ] && { echo "[]"; return; }

  local lint_cmd
  if command -v markdownlint-cli2 &>/dev/null; then
    lint_cmd="markdownlint-cli2"
  elif command -v markdownlint &>/dev/null; then
    lint_cmd="markdownlint"
  else
    echo "[]"
    return
  fi

  local raw_output=""
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    local file_output
    file_output=$($lint_cmd "$f" 2>&1) || true
    [ -n "$file_output" ] && raw_output+="$file_output"$'\n'
  done <<< "$md_files"

  [ -z "$raw_output" ] && { echo "[]"; return; }

  echo "$raw_output" | python3 -c "
import sys, json, re
findings = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    m = re.match(r'^(.+?):(\d+)(?::\d+)?\s+(MD\d+/\S+)\s+(.*)', line)
    if m:
        findings.append({
            'file': m.group(1),
            'line': int(m.group(2)),
            'severity': 'low',
            'category': 'maintainability',
            'description': '[markdownlint:' + m.group(3) + '] ' + m.group(4),
            'suggestion': 'Fix the markdown lint violation',
            'source': 'lint:markdownlint'
        })
print(json.dumps(findings))
" 2>/dev/null || echo "[]"
}

# Validate URLs in changed markdown files (opt-in, slow)
_md_check_urls() {
  local files_list="$1"
  local timeout_sec="${CODEX_MARKDOWN_TIMEOUT:-5}"

  # Validate timeout_sec is numeric to prevent injection
  case "$timeout_sec" in
    ''|*[!0-9]*) timeout_sec=5 ;;
  esac

  local md_files
  md_files=$(echo "$files_list" | grep -E '\.md$' || true)
  [ -z "$md_files" ] && { echo "[]"; return; }

  # Extract URLs with file path and line numbers
  local all_urls=""
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    # Use grep -n for line numbers, then extract URLs with python for robustness
    local file_urls
    file_urls=$(grep -nE '\]\(https?://' "$f" 2>/dev/null || true)
    if [ -n "$file_urls" ]; then
      echo "$file_urls" | while IFS= read -r match_line; do
        local line_num="${match_line%%:*}"
        local line_content="${match_line#*:}"
        # Extract URLs from this line using python for balanced parens
        echo "$line_content" | python3 -c "
import sys, re
for line in sys.stdin:
    for m in re.finditer(r'\]\((https?://[^\s)]+(?:\([^\s)]*\))*[^\s)]*)\)', line):
        print('$f|$line_num|' + m.group(1))
" 2>/dev/null || true
      done
    fi
  done <<< "$md_files"

  # Collect into variable (subshell workaround)
  all_urls=$(
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      grep -nE '\]\(https?://' "$f" 2>/dev/null | while IFS=: read -r line_num line_content; do
        echo "$line_content" | python3 -c "
import sys, re
for line in sys.stdin:
    for m in re.finditer(r'\]\((https?://[^\s)]+(?:\([^\s)]*\))*[^\s)]*)\)', line):
        print('$f|$line_num|' + m.group(1))
" 2>/dev/null || true
      done
    done <<< "$md_files"
  )

  [ -z "$all_urls" ] && { echo "[]"; return; }

  echo "$all_urls" | head -20 | python3 -c "
import sys, json, urllib.request, urllib.error, ssl
timeout_sec = int(sys.argv[1]) if len(sys.argv) > 1 else 5
ctx = ssl.create_default_context()
findings = []
for line in sys.stdin:
    line = line.strip()
    if not line or '|' not in line:
        continue
    parts = line.split('|', 2)
    if len(parts) < 3:
        continue
    file_path, line_num, url = parts[0], parts[1], parts[2]
    try:
        line_num = int(line_num)
    except ValueError:
        line_num = 0
    try:
        req = urllib.request.Request(url, method='HEAD', headers={'User-Agent': 'Mozilla/5.0 link-checker'})
        urllib.request.urlopen(req, timeout=timeout_sec, context=ctx)
    except urllib.error.HTTPError as e:
        if e.code >= 400:
            findings.append({
                'file': file_path,
                'line': line_num,
                'severity': 'low',
                'category': 'maintainability',
                'description': f'[url-check] Broken link ({e.code}): {url}',
                'suggestion': 'Update or remove the broken URL',
                'source': 'lint:url-check'
            })
    except (urllib.error.URLError, OSError, ValueError) as e:
        findings.append({
            'file': file_path,
            'line': line_num,
            'severity': 'low',
            'category': 'maintainability',
            'description': f'[url-check] Unreachable link: {url} ({type(e).__name__})',
            'suggestion': 'Verify the URL is correct and accessible',
            'source': 'lint:url-check'
        })
print(json.dumps(findings))
" "$timeout_sec" 2>/dev/null || echo "[]"
}

# Main entry point
run_markdown_checks() {
  local files_list="$1"

  if [ "${CODEX_SKIP_MARKDOWN:-0}" = "1" ]; then
    echo "[]"
    return
  fi

  local md_files
  md_files=$(echo "$files_list" | grep -E '\.md$' || true)
  if [ -z "$md_files" ]; then
    echo "[]"
    return
  fi

  local all_findings="[]"

  if _md_has_markdownlint; then
    echo "   Markdown: running markdownlint..." >&2
    local lint_findings
    lint_findings=$(_md_run_lint "$files_list")
    all_findings=$(printf '%s\n%s' "$all_findings" "$lint_findings" | python3 -c "
import sys, json
arrays = []
for line in sys.stdin:
    line = line.strip()
    if line:
        try: arrays.extend(json.loads(line))
        except (json.JSONDecodeError, ValueError): pass
print(json.dumps(arrays))
")
  fi

  if [ "${CODEX_CHECK_URLS:-0}" = "1" ]; then
    echo "   Markdown: validating URLs..." >&2
    local url_findings
    url_findings=$(_md_check_urls "$files_list")
    all_findings=$(printf '%s\n%s' "$all_findings" "$url_findings" | python3 -c "
import sys, json
arrays = []
for line in sys.stdin:
    line = line.strip()
    if line:
        try: arrays.extend(json.loads(line))
        except (json.JSONDecodeError, ValueError): pass
print(json.dumps(arrays))
")
  fi

  local count
  count=$(echo "$all_findings" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
  [ "$count" -gt 0 ] && echo "   Markdown: $count finding(s)" >&2

  echo "$all_findings"
}

# If run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if ! git rev-parse --git-dir &>/dev/null; then
    echo "[]"
    exit 0
  fi
  STAGED_FILES=$(git diff --cached --name-only 2>/dev/null || echo "")
  run_markdown_checks "$STAGED_FILES"
fi
