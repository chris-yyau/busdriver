# Litmus Scripts Reference

Detailed documentation for all scripts in the litmus skill.

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
- Creates `.opencode/litmus-state.md` with YAML frontmatter
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
- `.opencode/litmus-state.md` must exist (run `init-review-loop.sh` first)
- Staged git changes (run `git add -A`)

**Behavior:**
1. Reads current state from `.opencode/litmus-state.md`
2. Runs SAST tools (semgrep, shellcheck, trufflehog) if available
3. Collects smart context (callers, importers, docs references)
4. Runs codex review with enriched prompt
5. Parses result and updates state file
6. Outputs human-readable progress logs to stdout

**Output:**
- Human-readable progress and review results to stdout
- Updates `.opencode/litmus-state.md` with iteration results
- Removes state file on PASS; preserves on failure for inspection

**Exit codes:**
- 0: Review passed
- 1: Review failed, state missing, or max iterations reached
- 2: Diff too large — split into smaller commits
- 3: Builtin fallback triggered (no external CLI available)
- 124: Codex review timed out

### execute_review.sh (Removed)

This legacy script has been removed. Use `run-review-loop.sh` for all review workflows.

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
3. Saves to `~/.claude/projects/{project}/litmus-context/task-history.jsonl`
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
LITMUS_CHANGELOG_LIMIT=5 bash scripts/load_changelog.sh
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

### lib/log-metrics.sh

**Purpose:** Persistent review metrics logging.

**Functions:**

**`log_review_metrics(status, issue_count, iteration, mode, cli, json_output)`**
- Appends one JSON line to `.opencode/review-metrics.jsonl`
- Captures: status, issues, severity breakdown, commit SHA, branch, diff size
- Called automatically by `run-review-loop.sh` after merge-findings

**Configuration:**
- `LITMUS_METRICS_FILE` — override output path (default: `.opencode/review-metrics.jsonl`)

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
bash(
    command="bash scripts/init-review-loop.sh 10",
    description="Initialize codex review loop",
    timeout=5000
)

# Run review (with background execution)
task = bash(
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
bash ${BUSDRIVER_PLUGIN_ROOT}/skills/litmus/scripts/init-review-loop.sh 3

# Run review
RESULT=$(bash ${BUSDRIVER_PLUGIN_ROOT}/skills/litmus/scripts/run-review-loop.sh)
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
    bash ${BUSDRIVER_PLUGIN_ROOT}/skills/litmus/scripts/init-review-loop.sh 5
    bash ${BUSDRIVER_PLUGIN_ROOT}/skills/litmus/scripts/run-review-loop.sh
```

## Environment Variables

- `LITMUS_CHANGELOG_LIMIT` - Number of changelog entries to load (default: 3)
- `CURRENT_TASK_ID` - Task ID for changelog tracking (optional)

## File Locations

- **State file:** `.opencode/litmus-state.md` (in project root)
- **Changelog:** `~/.claude/projects/{project}/litmus-context/`
- **Legacy counter:** `/tmp/litmus-iteration.txt` (deprecated)
- **Prompt template:** `${BUSDRIVER_PLUGIN_ROOT}/skills/litmus/prompt_template.txt`
