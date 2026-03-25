#!/bin/bash
# Iteration history management for codex review convergence
# Tracks issues found across iterations so the LLM can converge

ITERATION_HISTORY_FILE="/tmp/codex-iteration-history.jsonl"

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

lines = open('$ITERATION_HISTORY_FILE').read().strip().split('\n')
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
" 2>/dev/null
}

# Clear iteration history (called on PASS or init)
clear_iteration_history() {
  rm -f "$ITERATION_HISTORY_FILE"
}
