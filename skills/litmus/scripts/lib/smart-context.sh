#!/bin/bash
# Collect cross-file context for changed functions/methods.
# Extracts function names from diff hunks, finds callers and importers.
#
# Usage: source this file, then call collect_smart_context "$staged_diff" "$files_list"
# Output: Formatted context string on stdout for prompt injection.
#
# Environment:
#   LITMUS_SKIP_CONTEXT=1      — skip smart context collection
#   LITMUS_MAX_CONTEXT_LINES=50 — max context lines per function (default: 50)
#   LITMUS_MAX_FUNCTIONS=10     — max functions to trace (default: 10)
#   LITMUS_MAX_CONTEXT_DIFF_BYTES=262144 — skip enrichment (extraction + caller/
#                                importer grep) when the diff exceeds this many
#                                bytes (default: 256 KiB)
#   LITMUS_MAX_CONTEXT_LINE_BYTES=4000   — skip enrichment when any diff line is
#                                longer than this (default: 4000 — minified/data
#                                lines trigger pathological regex backtracking)
#   LITMUS_CONTEXT_TIMEOUT=15   — per-operation timeout (s) for extraction and
#                                caller/importer grep (default: 15)

set -euo pipefail

# Escape regex metacharacters for safe grep -E interpolation
_ctx_escape_regex() {
  printf '%s' "$1" | sed 's/[.+*?^${}()|[\]\\]/\\&/g'
}

# Portable timeout (mirrors lib/sast-runner.sh::_sast_timeout so this lib stays
# self-contained — it is sourced and run standalone). Fail-open callers wrap the
# invocation with `|| true`; a timeout exits 124.
_ctx_timeout() {
  local duration="$1"; shift
  case "$duration" in
    ''|*[!0-9]*) duration=15 ;;
  esac
  if command -v timeout &>/dev/null; then
    timeout "$duration" "$@"
  elif command -v gtimeout &>/dev/null; then
    gtimeout "$duration" "$@"
  else
    # Perl fallback for macOS — fork + alarm (exec alone loses the alarm handler)
    perl -e '
      use POSIX ":sys_wait_h";
      our $pid = fork();
      if (!defined $pid) { die "fork failed: $!"; }
      if ($pid == 0) { alarm 0; exec @ARGV[1..$#ARGV]; die "exec failed: $!"; }
      $SIG{ALRM} = sub {
        if ($pid) {
          kill "TERM", $pid;
          for (1..4) { last if waitpid($pid, WNOHANG) > 0; select(undef,undef,undef,0.5); }
          kill "KILL", $pid if waitpid($pid, WNOHANG) == 0;
        }
        exit 124;
      };
      alarm $ARGV[0];
      waitpid($pid, 0);
      alarm 0;
      if ($? & 127) { exit(128 + ($? & 127)); }
      exit($? >> 8);
    ' "$duration" "$@"
  fi
}

# Returns 0 (true) when the diff is too large / too long-lined to run regex
# extraction over safely. Both checks are linear and backtracking-free, so the
# guard itself can never become the hang it prevents.
_ctx_diff_too_large() {
  local diff="$1"
  local max_bytes="${LITMUS_MAX_CONTEXT_DIFF_BYTES:-262144}"
  local max_line="${LITMUS_MAX_CONTEXT_LINE_BYTES:-4000}"
  case "$max_bytes" in ''|*[!0-9]*) max_bytes=262144 ;; esac
  case "$max_line" in ''|*[!0-9]*) max_line=4000 ;; esac

  # Total size check first — in-process, no fork.
  if [ "${#diff}" -gt "$max_bytes" ]; then
    return 0
  fi

  # Longest-line check — awk length() is linear, immune to regex backtracking.
  local longest
  longest=$(printf '%s' "$diff" | awk '{ if (length($0) > m) m = length($0) } END { print m+0 }' 2>/dev/null || echo 0)
  case "$longest" in ''|*[!0-9]*) longest=0 ;; esac
  if [ "$longest" -gt "$max_line" ]; then
    return 0
  fi

  return 1
}

# Extract function/method names from diff hunks
# Parses both added lines AND @@ hunk headers (which contain enclosing function context)
_extract_changed_functions() {
  local diff="$1"

  # Fail-open guard: skip extraction on pathologically large / long-line diffs.
  # The decl patterns below backtrack; running re.finditer over a huge
  # single-file data diff (minified JSON, NDJSON, lockfiles) can stall for
  # minutes. Protects every caller (smart context AND docs context, which
  # reuses this extractor).
  if _ctx_diff_too_large "$diff"; then
    return
  fi

  local ctx_timeout="${LITMUS_CONTEXT_TIMEOUT:-15}"
  case "$ctx_timeout" in ''|*[!0-9]*) ctx_timeout=15 ;; esac

  # Timeout is defense-in-depth behind the size guard: no input should reach the
  # regex slow enough to need it, but if one does we fail open (|| true) rather
  # than hang the review. printf is safer than echo for diffs starting with -.
  printf '%s\n' "$diff" | _ctx_timeout "$ctx_timeout" python3 -c "
import sys, re

# Patterns for function/method declarations (anchored to avoid false positives)
decl_patterns = [
    # JavaScript/TypeScript: named function declarations
    r'(?:export\s+)?(?:async\s+)?function\s+(\w+)',
    # JavaScript/TypeScript: const/let/var arrow or function expressions
    r'(?:export\s+)?(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s+)?\(',
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
        'true', 'false', 'null', 'undefined', 'new', 'this', 'self',
        'forEach', 'catch', 'then', 'map', 'filter', 'reduce', 'try',
        'finally', 'with', 'except', 'async', 'await', 'yield'}
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
  local max_lines="${LITMUS_MAX_CONTEXT_LINES:-50}"
  case "$max_lines" in
    ''|*[!0-9]*) max_lines=50 ;;
  esac
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
  local ctx_timeout="${LITMUS_CONTEXT_TIMEOUT:-15}"
  case "$ctx_timeout" in ''|*[!0-9]*) ctx_timeout=15 ;; esac

  # Use grep -w for portable word boundary matching (no regex escaping needed).
  # Timeout-wrapped so a huge tracked file can't make the repo scan hang.
  _ctx_timeout "$ctx_timeout" grep -rwn --include='*.js' --include='*.ts' --include='*.tsx' --include='*.jsx' \
    --include='*.py' --include='*.go' --include='*.rs' --include='*.sh' \
    --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=vendor \
    --exclude-dir='__pycache__' --exclude-dir='.claude' \
    --exclude-dir='.next' --exclude-dir=dist --exclude-dir=build --exclude-dir=out \
    "$func_name" "$repo_root" 2>/dev/null | \
    grep -vE '(/|^)(test_|_test\.|\.test\.|\.spec\.|tests/|spec/)' | \
    head -n "$max_lines" || true
}

# Find files that import/require changed files
_find_importers() {
  local changed_file="$1"
  local max_lines="${LITMUS_MAX_CONTEXT_LINES:-50}"
  case "$max_lines" in
    ''|*[!0-9]*) max_lines=50 ;;
  esac
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")

  # Extract module name from file path (strip extension and leading path)
  local module_name
  module_name=$(basename "$changed_file" | sed 's/\.[^.]*$//')

  local escaped_module
  escaped_module=$(_ctx_escape_regex "$module_name")

  local ctx_timeout="${LITMUS_CONTEXT_TIMEOUT:-15}"
  case "$ctx_timeout" in ''|*[!0-9]*) ctx_timeout=15 ;; esac

  # Search for import/require statements referencing this module.
  # Timeout-wrapped so a huge tracked file can't make the repo scan hang.
  _ctx_timeout "$ctx_timeout" grep -rn --include='*.js' --include='*.ts' --include='*.tsx' --include='*.jsx' \
    --include='*.py' --include='*.go' --include='*.rs' \
    --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=vendor \
    --exclude-dir='__pycache__' --exclude-dir='.claude' \
    --exclude-dir='.next' --exclude-dir=dist --exclude-dir=build --exclude-dir=out \
    -E "(import.*['\"].*${escaped_module}['\"]|require\(['\"].*${escaped_module}['\"]|from\s+.*${escaped_module}\s+import)" "$repo_root" 2>/dev/null | \
    head -n "$max_lines" || true
}

# Main entry point
# Args: $1 = staged diff content, $2 = newline-separated changed file paths
# Output: Formatted context string on stdout
collect_smart_context() {
  local diff="$1"
  local files_list="$2"
  local max_functions="${LITMUS_MAX_FUNCTIONS:-10}"
  case "$max_functions" in
    ''|*[!0-9]*) max_functions=10 ;;
  esac

  if [ "${LITMUS_SKIP_CONTEXT:-0}" = "1" ]; then
    return
  fi

  [ -z "$diff" ] && return

  # Fail-open: skip the entire enrichment (extraction + caller/importer grep)
  # when the diff is too large or long-lined to process safely. Enrichment is
  # optional — the reviewer still receives the full diff. This is the guard that
  # the documented LITMUS_SKIP_CONTEXT flag could not provide, because inline env
  # vars never reach the hook-spawned gate script.
  if _ctx_diff_too_large "$diff"; then
    echo "   Context: diff too large for caller tracing — skipping enrichment" >&2
    return
  fi

  # Extract changed function names
  local functions
  functions=$(_extract_changed_functions "$diff")

  # Even without function names, still trace importers of changed files
  local func_count=0
  if [ -n "$functions" ]; then
    func_count=$(echo "$functions" | wc -l | tr -d ' ')
    echo "   Context: found $func_count changed function(s), tracing callers..." >&2
    # Limit to top N functions
    functions=$(echo "$functions" | head -n "$max_functions")
  fi

  local context=""
  local traced=0

  # For each function, find callers
  if [ -n "$functions" ]; then
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
  fi

  # For each changed file, find importers (runs even without function names)
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
  return 0
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
