#!/bin/bash
STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
# Iteration history management for litmus review convergence
# Tracks issues found across iterations so the LLM can converge

# Store iteration history alongside review state in .claude/ (safe from /tmp symlink attacks)
ITERATION_HISTORY_FILE="$STATE_DIR/litmus-iteration-history.local.jsonl"

# Append current iteration's issues to history
# Usage: append_iteration_history <iteration_number> <json_output>
append_iteration_history() {
  local iteration="$1"
  local json_output="$2"

  # Extract issues array and add iteration metadata
  local entry
  entry=$(echo "$json_output" | python3 -c "
import sys, json
data = json.load(sys.stdin)
entry = {
    'iteration': int(sys.argv[1]),
    'status': data.get('status', 'UNKNOWN'),
    'issues': data.get('issues', [])
}
print(json.dumps(entry))
" "$iteration" 2>/dev/null) || return 1

  echo "$entry" >> "$ITERATION_HISTORY_FILE"
}

# Load iteration history formatted for prompt injection
# Returns empty string if no history exists
load_iteration_history() {
  if [ ! -f "$ITERATION_HISTORY_FILE" ] || [ ! -s "$ITERATION_HISTORY_FILE" ]; then
    echo ""
    return 0
  fi

  python3 -c "
import sys, json

lines = open(sys.argv[1]).read().strip().split('\n')
if not lines or lines == ['']:
    sys.exit(0)

print('PREVIOUS ITERATION HISTORY:')
print('The following issues were found in previous review iterations.')
print('Issues that have been fixed should NOT be re-reported.')
print('')

for line in lines:
    try:
        entry = json.loads(line)
        iteration = entry['iteration']
        status = entry['status']
        issues = entry['issues']
        print(f'--- Iteration {iteration} (status: {status}) ---')
        if issues:
            for issue in issues:
                sev = issue.get('severity', '?')
                f = issue.get('file', '?')
                ln = issue.get('line', '?')
                desc = issue.get('description', '?')
                print(f'  [{sev}] {f}:{ln} - {desc}')
        else:
            print('  No issues found.')
        print('')
    except:
        continue
" "$ITERATION_HISTORY_FILE" 2>/dev/null
}

# Shared Python snippet for fingerprinting blocking issues.
# Used by both compute_issue_fingerprint and is_stalled.
#
# IMPORTANT: this heredoc is single-quoted in bash, so the body is passed to
# python3 verbatim — no shell escape processing. That means we CANNOT use the
# `f"{i[\"file\"]}..."` style (the `\"` inside a single-quoted bash heredoc
# survives as a literal backslash + quote, which Python rejects as a syntax
# error inside an f-string expression). String concatenation lets Python use
# its own double-quote literals without any escape gymnastics. This bug
# previously left both compute_issue_fingerprint and is_stalled silently
# returning "unknown" / empty, so stall detection never fired — issue #105's
# mock-CLI harness exposed it.
_FINGERPRINT_PY='
import sys, json, hashlib
issues = json.load(sys.stdin)
if isinstance(issues, dict):
    issues = issues.get("issues", [])
blocking = sorted(
    str(i.get("file", "")) + ":" + str(i.get("severity", "")) + ":" + str(i.get("description", "") or "")[:50]
    for i in issues
    if i.get("severity") in ("high", "medium")
)
print(hashlib.md5("|".join(blocking).encode()).hexdigest() if blocking else "empty")
'

# Compute a fingerprint of the current blocking issue set
# Used for stall detection: if fingerprint matches previous iteration, loop is stuck
compute_issue_fingerprint() {
  local json_output="$1"
  echo "$json_output" | python3 -c "$_FINGERPRINT_PY" 2>/dev/null || echo "unknown"
}

# Check if current issue set matches the previous iteration (stall detection)
# Returns 0 (true) if stalled, 1 (false) if progressing
is_stalled() {
  local current_fingerprint="$1"
  [ ! -f "$ITERATION_HISTORY_FILE" ] && return 1
  local prev_fingerprint
  # Extract issues array from the last JSONL entry, then fingerprint
  prev_fingerprint=$(tail -1 "$ITERATION_HISTORY_FILE" 2>/dev/null | python3 -c "$_FINGERPRINT_PY" 2>/dev/null) || return 1
  [ "$current_fingerprint" = "$prev_fingerprint" ]
}

# Clear iteration history (called on PASS or init)
clear_iteration_history() {
  rm -f "$ITERATION_HISTORY_FILE"
}
