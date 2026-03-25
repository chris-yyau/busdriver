# Codex Reviewer Advanced Usage

Optional features and advanced integration patterns.

## Changelog System (Optional)

The changelog system provides continuity across review sessions by tracking completed tasks and their changes.

### How It Works

After successful commits, the skill can save changelog information:

**Storage location:**
- Location: `~/.claude/projects/-{project-path}/codex-context/`
- Files created:
  - `task-history.jsonl` - Append-only log of all completed tasks
  - `last-task.json` - Most recent task (for quick access)

**What gets saved:**
- Task ID (if exists)
- Commit SHA and message
- Changed files list
- Diff summary
- Lines added/deleted
- Number of review iterations

**Loading previous changelog:**

The `execute_review.sh` script automatically loads changelog from the previous task (if available) and injects it into the review prompt. This provides context about recent changes.

**Error handling:**
- If directory creation fails → warning shown, workflow continues
- If not in git repo → skips changelog save silently
- Changelog persistence is optional, failures don't block workflow

### Using the Changelog Scripts

**Save changelog after commit:**
```bash
# Simple usage (task ID from environment if available)
bash scripts/save_changelog.sh

# Or with explicit paths
bash ${CLAUDE_PLUGIN_ROOT}/skills/codex-reviewer/scripts/save_changelog.sh
```

**Load previous changelog:**
```bash
# Load last 3 entries (default)
PREV_CHANGELOG=$(bash scripts/load_changelog.sh 2>/dev/null || echo "")

# Load more entries
CODEX_CHANGELOG_LIMIT=5 bash scripts/load_changelog.sh
```

### When to Use Changelog

**Useful for:**
- Long-running feature development across multiple sessions
- Team projects where context needs to persist
- Complex refactorings spanning multiple commits

**Not needed for:**
- Simple bug fixes
- Single-commit features
- Projects with good commit history

## Task Auto-Continuation (Deprecated)

**Note:** This feature is deprecated and removed from the core workflow. It's documented here for reference.

### Previous Behavior

After completing a task and committing, the skill would:
1. Mark current task as completed
2. Query for next available pending task
3. Automatically load and start the next task
4. Continue the review loop workflow

### Why It Was Removed

1. **Separate concern** - Task management is independent of code review
2. **Over-complicated** - Added complexity to core review loop
3. **Not universal** - Not all users use task management systems
4. **Better alternatives** - Task systems handle this natively

### Manual Task Continuation

If you want to continue to the next task after review:

```python
# After commit completes
current_task_id = os.environ.get('CURRENT_TASK_ID')
if current_task_id:
    TaskUpdate(taskId=current_task_id, status="completed")

# Query for next task
tasks = TaskList()
next_task = next((t for t in tasks if t['status'] == 'pending' and not t.get('blockedBy')), None)

if next_task:
    TaskUpdate(taskId=next_task['id'], status="in_progress")
    # Continue with next task
```

## Custom Review Prompts

You can customize the review prompt by modifying `prompt_template.txt`:

**Default prompt focuses on:**
- Bugs
- Security issues
- Performance problems
- Maintainability

**Customization examples:**

### Focus on security only
```
Review the uncommitted changes for security vulnerabilities only.

Look for:
- SQL injection
- XSS vulnerabilities
- Authentication bypasses
- Insecure data handling
- Missing input validation

CRITICAL OUTPUT REQUIREMENT: Output ONLY valid JSON.
{
  "status": "PASS" or "FAIL",
  "issues": [...]
}
```

### Focus on performance
```
Review the uncommitted changes for performance issues only.

Look for:
- N+1 queries
- Inefficient algorithms
- Missing database indexes
- Unnecessary re-renders
- Memory leaks

CRITICAL OUTPUT REQUIREMENT: Output ONLY valid JSON.
{
  "status": "PASS" or "FAIL",
  "issues": [...]
}
```

### Include changelog context

The template supports `{{PREV_CHANGELOG}}` variable:

```
Review the uncommitted changes for bugs and security issues.

CHANGELOG FROM PREVIOUS TASK:
{{PREV_CHANGELOG}}

Use this changelog to ensure consistency with recent changes and patterns.

CRITICAL OUTPUT REQUIREMENT: Output ONLY valid JSON.
{
  "status": "PASS" or "FAIL",
  "issues": [...]
}
```

## Integration Patterns

### Integration with CI/CD

Run codex review in CI pipeline before deployment:

```yaml
# .github/workflows/review.yml
name: Code Review
on: [pull_request]
jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - name: Install Codex
        run: |  # Install codex CLI
      - name: Run Review
        run: |
          git diff origin/main...HEAD > /tmp/changes.diff
          codex review "Review changes for security and bugs..."
```

### Integration with Pre-commit Hooks

Add review to git pre-commit hook:

```bash
# .git/hooks/pre-commit
#!/bin/bash
set -e

echo "Running codex review..."

# Initialize iteration counter
echo "1" > /tmp/codex-iteration.txt

# Run review loop
MAX_ITER=3
for i in $(seq 1 $MAX_ITER); do
    RESULT=$(bash ${CLAUDE_PLUGIN_ROOT}/skills/codex-reviewer/scripts/execute_review.sh)
    STATUS=$(echo "$RESULT" | jq -r '.status')

    if [ "$STATUS" = "PASS" ]; then
        rm /tmp/codex-iteration.txt
        exit 0
    fi

    # Show issues
    echo "$RESULT" | jq -r '.issues[] | "[\(.severity)] \(.file):\(.line) - \(.description)"'

    # In pre-commit hook, we can't auto-fix, so fail
    if [ $i -eq $MAX_ITER ]; then
        echo "Review failed after $MAX_ITER iterations"
        rm /tmp/codex-iteration.txt
        exit 1
    fi
done
```

### Integration with Task Management

Link review results to task tracking:

```python
def run_review_for_task(task_id):
    # Mark task in progress
    TaskUpdate(taskId=task_id, status="in_progress")

    # Get task details
    task = TaskGet(taskId=task_id)

    # Set environment for changelog
    os.environ['CURRENT_TASK_ID'] = task_id

    # Run review loop
    iteration = 1
    while iteration <= 10:
        result = run_codex_review(iteration)

        if result['status'] == 'PASS':
            # Task complete
            TaskUpdate(taskId=task_id, status="completed")
            return True

        # Fix issues and continue
        fix_issues(result['issues'])
        iteration += 1

    # Max iterations reached
    return False
```

## Advanced Iteration Control

### Custom Max Iterations

Modify the max iteration limit for specific scenarios:

```python
# For simple changes - fail fast
MAX_ITERATIONS = 3

# For complex refactorings - allow more iterations
MAX_ITERATIONS = 15

# Check iteration
iteration = int(open('/tmp/codex-iteration.txt').read().strip())
if iteration > MAX_ITERATIONS:
    # Handle max iterations
    pass
```

### Iteration Metrics

Track review metrics across iterations:

```python
import json
from datetime import datetime

metrics = {
    'iterations': [],
    'total_issues': 0,
    'time_started': datetime.now().isoformat()
}

for iteration in range(1, 11):
    result = run_codex_review(iteration)

    metrics['iterations'].append({
        'iteration': iteration,
        'status': result['status'],
        'issue_count': len(result['issues']),
        'timestamp': datetime.now().isoformat()
    })

    if result['status'] == 'PASS':
        break

# Save metrics
with open('.codex-metrics.json', 'w') as f:
    json.dump(metrics, f, indent=2)
```

## Multi-Repository Workflows

### Reviewing Changes Across Repos

For monorepo or multi-repo projects:

```bash
# Review all repos in a workspace
for repo in repo1 repo2 repo3; do
    cd $repo
    echo "Reviewing $repo..."

    echo "1" > /tmp/codex-iteration.txt
    bash ${CLAUDE_PLUGIN_ROOT}/skills/codex-reviewer/scripts/execute_review.sh

    if [ $? -eq 0 ]; then
        echo "✅ $repo passed review"
    else
        echo "❌ $repo failed review"
        exit 1
    fi
done
```

### Coordinated Reviews

Review changes that span multiple repos:

```bash
# Collect all diffs
cat > /tmp/multi-repo-diff.txt <<EOF
REPOSITORY: api
$(cd api && git diff HEAD)

REPOSITORY: web
$(cd web && git diff HEAD)

REPOSITORY: mobile
$(cd mobile && git diff HEAD)
EOF

# Review all changes together
codex review "Review the following changes across multiple repositories..."
```

## Performance Optimization

### Parallel Review

Review multiple files in parallel:

```bash
# Get list of changed files
FILES=$(git diff --name-only HEAD)

# Review each file in parallel
for file in $FILES; do
    (
        git diff HEAD -- "$file" > "/tmp/review-$file.diff"
        codex review "Review changes in $file..." &
    )
done

# Wait for all reviews
wait

# Collect results
# ... aggregate JSON results from each review
```

### Incremental Review

Review only new changes since last review:

```bash
# Save last reviewed commit
git rev-parse HEAD > .last-review-commit

# Later, review only new changes
LAST_COMMIT=$(cat .last-review-commit)
git diff $LAST_COMMIT..HEAD > /tmp/new-changes.diff
codex review "Review only the new changes..."

# Update last reviewed commit
git rev-parse HEAD > .last-review-commit
```

## Debugging and Diagnostics

### Enable Verbose Logging

Add debugging to review scripts:

```bash
# In execute_review.sh
set -x  # Enable debug mode

# Log all variables
echo "DEBUG: SCRIPT_DIR=$SCRIPT_DIR" >&2
echo "DEBUG: FINAL_PROMPT=$FINAL_PROMPT" >&2

# Log codex output before parsing
echo "DEBUG: Codex output:" >&2
codex review "$FINAL_PROMPT" | tee /tmp/codex-debug.log
```

### Save Review History

Keep history of all review iterations:

```bash
# Create review log directory
mkdir -p .codex-review-logs

# Save each iteration
ITERATION=$(cat /tmp/codex-iteration.txt)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE=".codex-review-logs/iteration-${ITERATION}-${TIMESTAMP}.json"

# Run review and save
codex review "$PROMPT" | tee "$LOG_FILE"
```

### Analyze Review Patterns

Identify common review issues:

```bash
# Extract all issues from review logs
jq -r '.issues[] | "\(.severity) | \(.category) | \(.description)"' \
    .codex-review-logs/*.json | \
    sort | uniq -c | sort -rn

# Output:
#   15 high | security | Missing input validation
#    8 medium | performance | N+1 query detected
#    5 high | security | SQL injection vulnerability
```
