# Codex Reviewer Scripts Reference

Detailed documentation for all scripts in the codex-reviewer skill.

## Core Scripts

### init-review-loop.sh

**Purpose:** Initialize state file for review loop.

**Usage:**
```bash
bash scripts/init-review-loop.sh [max_iterations] [completion_promise]
```

**Arguments:**
- `max_iterations` (optional, default: 10) - Maximum review iterations
- `completion_promise` (optional, default: null) - Semantic exit criteria

**Examples:**
```bash
# Basic initialization
bash scripts/init-review-loop.sh

# Custom max iterations
bash scripts/init-review-loop.sh 15

# With completion promise
bash scripts/init-review-loop.sh 10 "REVIEW PASSED"
```

**Output:**
- Creates `.claude/codex-review-state.md` with YAML frontmatter
- Displays initialization summary
- Shows next steps

**Exit codes:**
- 0: Success
- 1: Invalid arguments or not in git repository

### run-review-loop.sh

**Purpose:** Main review loop with state management and automatic iteration.

**Usage:**
```bash
bash scripts/run-review-loop.sh
```

**Requirements:**
- `.claude/codex-review-state.md` must exist (run `init-review-loop.sh` first)
- Staged git changes (run `git add -A`)

**Behavior:**
1. Reads current state from `.claude/codex-review-state.md`
2. Loads previous changelog (if available)
3. Runs codex review with full prompt
4. Parses JSON result
5. Updates state file
6. Returns JSON result

**Output:**
- JSON with `status` ("PASS" or "FAIL") and `issues` array
- Updates `.claude/codex-review-state.md` with results
- Removes state file on PASS (keeps changelog intact)

**Exit codes:**
- 0: Review passed or completed iteration
- 1: State file missing or codex command failed
- 2: Max iterations reached

### execute_review.sh (Legacy)

**Purpose:** Legacy review execution for backward compatibility.

**Usage:**
```bash
bash scripts/execute_review.sh
```

**Requirements:**
- `/tmp/codex-iteration.txt` with current iteration number
- Staged git changes

**Behavior:**
1. Reads iteration from `/tmp/codex-iteration.txt`
2. Loads previous changelog (if available)
3. Runs codex review
4. Returns JSON result

**Note:** This script doesn't auto-increment or manage state. Use `run-review-loop.sh` for modern approach.

## Helper Scripts

### save_changelog.sh

**Purpose:** Save commit information to changelog for context continuity.

**Usage:**
```bash
bash scripts/save_changelog.sh
```

**Requirements:**
- Must be in git repository
- Ideally run after successful commit

**Behavior:**
1. Collects commit info (SHA, message, changed files)
2. Gets iteration count from state file or counter
3. Saves to `~/.claude/projects/{project}/codex-context/task-history.jsonl`
4. Updates `last-task.json` for quick access

**Output:**
- Appends entry to task-history.jsonl
- Overwrites last-task.json
- Silent on success, warnings on errors

**Error handling:**
- Missing jq → warning, skips changelog
- Not in git repo → silent skip
- Directory creation failure → warning, continues

### load_changelog.sh

**Purpose:** Load previous changelog entries for review context.

**Usage:**
```bash
bash scripts/load_changelog.sh [limit]

# Or with environment variable
CODEX_CHANGELOG_LIMIT=5 bash scripts/load_changelog.sh
```

**Arguments:**
- `limit` (optional, default: 3) - Number of recent entries to load

**Output:**
- Formatted changelog text for inclusion in review prompt
- Empty string if no changelog or errors

**Error handling:**
- Missing directory → empty output
- Missing jq → empty output
- Silent errors (doesn't block review workflow)

## Utility Scripts

### lib/validation.sh

**Purpose:** Shared validation utilities for scripts.

**Functions:**

**`validate_max_iterations(value)`**
- Validates max iterations is positive integer
- Returns 0 if valid, 1 if invalid

**`validate_git_repo()`**
- Checks if current directory is git repository
- Returns 0 if yes, 1 if no

**`normalize_project_path(path)`**
- Converts file path to normalized format for storage
- Example: `/foo/bar` → `-foo-bar`

## Script Integration Patterns

### Using in Claude Code

```python
# Initialize review loop
Bash(
    command="bash scripts/init-review-loop.sh 10",
    description="Initialize codex review loop",
    timeout=5000
)

# Run review (with background execution)
task = Bash(
    command="bash scripts/run-review-loop.sh",
    description=f"Run Codex review iteration {iteration}",
    run_in_background=True,  # CRITICAL for automation
    timeout=600000
)

# Poll for completion
task_id = task['task_id']
while True:
    output = TaskOutput(task_id=task_id, block=True, timeout=30000)
    if output['status'] == 'completed':
        break

# Parse result
result = json.loads(output['output'])
```

### Using in Pre-commit Hooks

```bash
#!/bin/bash
# .git/hooks/pre-commit

set -e

# Initialize
bash ${CLAUDE_PLUGIN_ROOT}/skills/codex-reviewer/scripts/init-review-loop.sh 3

# Run review
RESULT=$(bash ${CLAUDE_PLUGIN_ROOT}/skills/codex-reviewer/scripts/run-review-loop.sh)
STATUS=$(echo "$RESULT" | jq -r '.status')

if [ "$STATUS" != "PASS" ]; then
    echo "❌ Codex review failed. Fix issues before committing."
    exit 1
fi

echo "✅ Codex review passed"
```

### Using in CI/CD

```yaml
# .github/workflows/review.yml
- name: Review Code
  run: |
    cd $GITHUB_WORKSPACE
    bash ${CLAUDE_PLUGIN_ROOT}/skills/codex-reviewer/scripts/init-review-loop.sh 5
    bash ${CLAUDE_PLUGIN_ROOT}/skills/codex-reviewer/scripts/run-review-loop.sh
```

## Environment Variables

- `CODEX_CHANGELOG_LIMIT` - Number of changelog entries to load (default: 3)
- `CURRENT_TASK_ID` - Task ID for changelog tracking (optional)

## File Locations

- **State file:** `.claude/codex-review-state.md` (in project root)
- **Changelog:** `~/.claude/projects/{project}/codex-context/`
- **Legacy counter:** `/tmp/codex-iteration.txt` (deprecated)
- **Prompt template:** `${CLAUDE_PLUGIN_ROOT}/skills/codex-reviewer/prompt_template.txt`
