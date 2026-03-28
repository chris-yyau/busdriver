#!/bin/bash
# Validate changed markdown files: broken URLs and lint violations.
#
# Usage: source this file, then call run_markdown_checks "$files_list"
# Output: JSON array of findings on stdout.
#
# Environment:
#   CODEX_SKIP_MARKDOWN=1       — skip all markdown checks
#   CODEX_CHECK_URLS=1          — enable URL validation (disabled by default — slow)
#   CODEX_MARKDOWN_TIMEOUT=10   — per-URL timeout in seconds (default: 5)

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

  local md_files
  md_files=$(echo "$files_list" | grep -E '\.md$' || true)
  [ -z "$md_files" ] && { echo "[]"; return; }

  local all_urls=""
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    local urls
    urls=$(grep -oE '\]\(https?://[^[:space:]]*\)' "$f" 2>/dev/null | sed 's/^](//;s/)$//' || true)
    if [ -n "$urls" ]; then
      while IFS= read -r url; do
        all_urls+="$f|$url"$'\n'
      done <<< "$urls"
    fi
  done <<< "$md_files"

  [ -z "$all_urls" ] && { echo "[]"; return; }

  echo "$all_urls" | head -20 | python3 -c "
import sys, json, urllib.request, urllib.error, ssl
ctx = ssl.create_default_context()
findings = []
for line in sys.stdin:
    line = line.strip()
    if not line or '|' not in line:
        continue
    file_path, url = line.split('|', 1)
    try:
        req = urllib.request.Request(url, method='HEAD', headers={'User-Agent': 'Mozilla/5.0 link-checker'})
        urllib.request.urlopen(req, timeout=$timeout_sec, context=ctx)
    except urllib.error.HTTPError as e:
        if e.code >= 400:
            findings.append({
                'file': file_path,
                'line': 0,
                'severity': 'low',
                'category': 'maintainability',
                'description': f'[url-check] Broken link ({e.code}): {url}',
                'suggestion': 'Update or remove the broken URL',
                'source': 'lint:url-check'
            })
    except Exception:
        pass
print(json.dumps(findings))
" 2>/dev/null || echo "[]"
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
        except: pass
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
        except: pass
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
