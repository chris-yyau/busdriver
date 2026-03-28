#!/bin/bash
# Collect cross-file context for changed functions/methods.
# Extracts function names from diff hunks, finds callers and importers.
#
# Usage: source this file, then call collect_smart_context "$staged_diff" "$files_list"
# Output: Formatted context string on stdout for prompt injection.
#
# Environment:
#   CODEX_SKIP_CONTEXT=1      — skip smart context collection
#   CODEX_MAX_CONTEXT_LINES=50 — max context lines per function (default: 50)
#   CODEX_MAX_FUNCTIONS=10     — max functions to trace (default: 10)

set -euo pipefail

# Extract function/method names from diff hunks
# Parses both added lines AND @@ hunk headers (which contain enclosing function context)
_extract_changed_functions() {
  local diff="$1"
  echo "$diff" | python3 -c "
import sys, re

# Patterns for function/method declarations
decl_patterns = [
    # JavaScript/TypeScript
    r'(?:export\s+)?(?:async\s+)?function\s+(\w+)',
    r'(?:export\s+)?(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s+)?\(',
    r'(\w+)\s*\(.*\)\s*\{',
    # Python
    r'def\s+(\w+)\s*\(',
    r'class\s+(\w+)',
    # Go
    r'func\s+(?:\([^)]+\)\s+)?(\w+)\s*\(',
    # Rust
    r'(?:pub\s+)?fn\s+(\w+)',
    # Shell
    r'^(\w+)\s*\(\)\s*\{',
]
# Hunk header pattern: @@ -a,b +c,d @@ optional function context
hunk_pattern = r'^@@ .+ @@\s*(.*)'
skip = {'if', 'for', 'while', 'switch', 'case', 'return', 'else', 'elif',
        'var', 'let', 'const', 'def', 'func', 'fn', 'pub', 'export',
        'true', 'false', 'null', 'undefined', 'new', 'this', 'self'}
names = set()
for line in sys.stdin:
    # Parse @@ hunk headers for enclosing function context
    hm = re.match(hunk_pattern, line)
    if hm:
        context = hm.group(1).strip()
        if context:
            for p in decl_patterns:
                for m in re.finditer(p, context):
                    name = m.group(1)
                    if len(name) > 2 and name.lower() not in skip:
                        names.add(name)
        continue
    # Parse added lines for new declarations
    if not line.startswith('+'):
        continue
    line = line[1:]  # strip leading +
    for p in decl_patterns:
        for m in re.finditer(p, line):
            name = m.group(1)
            if len(name) > 2 and name.lower() not in skip and not name.startswith('_'):
                names.add(name)
for n in sorted(names):
    print(n)
" 2>/dev/null || true
}

# Find callers of a function across the repo
_find_callers() {
  local func_name="$1"
  local max_lines="${CODEX_MAX_CONTEXT_LINES:-50}"
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")

  # Use grep to find call sites (exclude test/spec files and common vendor dirs)
  grep -rn --include='*.js' --include='*.ts' --include='*.tsx' --include='*.jsx' \
    --include='*.py' --include='*.go' --include='*.rs' --include='*.sh' \
    --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=vendor \
    --exclude-dir='__pycache__' --exclude-dir='.claude' \
    -E "\b${func_name}\b" "$repo_root" 2>/dev/null | \
    grep -vE '(/|^)(test_|_test\.|\.test\.|\.spec\.|tests/|spec/)' | \
    head -n "$max_lines" || true
}

# Find files that import/require changed files
_find_importers() {
  local changed_file="$1"
  local max_lines="${CODEX_MAX_CONTEXT_LINES:-50}"
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")

  # Extract module name from file path (strip extension and leading path)
  local module_name
  module_name=$(basename "$changed_file" | sed 's/\.[^.]*$//')

  # Search for import/require statements referencing this module
  grep -rn --include='*.js' --include='*.ts' --include='*.tsx' --include='*.jsx' \
    --include='*.py' --include='*.go' --include='*.rs' \
    --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=vendor \
    --exclude-dir='__pycache__' --exclude-dir='.claude' \
    -E "(import.*['\"].*${module_name}['\"]|require\(['\"].*${module_name}['\"]|from\s+.*${module_name}\s+import)" "$repo_root" 2>/dev/null | \
    head -n "$max_lines" || true
}

# Main entry point
# Args: $1 = staged diff content, $2 = newline-separated changed file paths
# Output: Formatted context string on stdout
collect_smart_context() {
  local diff="$1"
  local files_list="$2"
  local max_functions="${CODEX_MAX_FUNCTIONS:-10}"

  if [ "${CODEX_SKIP_CONTEXT:-0}" = "1" ]; then
    return
  fi

  [ -z "$diff" ] && return

  # Extract changed function names
  local functions
  functions=$(_extract_changed_functions "$diff")
  [ -z "$functions" ] && return

  local func_count
  func_count=$(echo "$functions" | wc -l | tr -d ' ')
  echo "   Context: found $func_count changed function(s), tracing callers..." >&2

  # Limit to top N functions
  functions=$(echo "$functions" | head -n "$max_functions")

  local context=""
  local traced=0

  # For each function, find callers
  while IFS= read -r func_name; do
    [ -z "$func_name" ] && continue
    local callers
    callers=$(_find_callers "$func_name")
    if [ -n "$callers" ]; then
      local caller_count
      caller_count=$(echo "$callers" | wc -l | tr -d ' ')
      context+="### Callers of \`${func_name}\` ($caller_count call sites)
\`\`\`
$callers
\`\`\`

"
      traced=$((traced + 1))
    fi
  done <<< "$functions"

  # For each changed file, find importers
  local import_context=""
  while IFS= read -r changed_file; do
    [ -z "$changed_file" ] && continue
    local importers
    importers=$(_find_importers "$changed_file")
    if [ -n "$importers" ]; then
      local importer_count
      importer_count=$(echo "$importers" | wc -l | tr -d ' ')
      import_context+="### Files importing \`${changed_file}\` ($importer_count importers)
\`\`\`
$importers
\`\`\`

"
    fi
  done <<< "$(echo "$files_list" | head -n 5)"

  if [ -n "$context" ] || [ -n "$import_context" ]; then
    echo "   Context: traced $traced function(s) with callers" >&2
    echo "## Cross-File Context (auto-collected)"
    echo ""
    echo "The following call sites and importers may be affected by the changes under review."
    echo "Check for broken contracts, renamed parameters, or changed return types."
    echo ""
    [ -n "$context" ] && echo "$context"
    [ -n "$import_context" ] && echo "$import_context"
  fi
}

# If run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if ! git rev-parse --git-dir &>/dev/null; then
    exit 0
  fi
  STAGED_DIFF=$(git diff --cached --no-color 2>/dev/null || echo "")
  STAGED_FILES=$(git diff --cached --name-only 2>/dev/null || echo "")
  collect_smart_context "$STAGED_DIFF" "$STAGED_FILES"
fi
