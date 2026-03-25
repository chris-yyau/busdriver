# Codex Reviewer Advanced Features

This document contains optional advanced features referenced from SKILL.md.

## Changelog System (Context Continuity)

**Optional feature:** Save and load changelog entries to maintain context between review sessions.

### How It Works

- After each commit, optionally run `bash scripts/save_changelog.sh`
- Saves commit info, changed files, review iterations to `~/.claude/projects/{project}/codex-context/`
- Next review automatically loads last 3 changelog entries for context
- Helps reviewer understand recent changes and avoid redundant issues

### What Gets Saved

- Commit SHA and message
- Changed files list
- Lines added/deleted
- Review iteration count
- Timestamp

### Configuration

```bash
# Load more history (default: 3)
export CODEX_CHANGELOG_LIMIT=5
bash scripts/run-review-loop.sh
```

### Storage Location

```
~/.claude/projects/{normalized-project-path}/codex-context/
├── task-history.jsonl      # Append-only log of all tasks
└── last-task.json           # Most recent task (quick access)
```

### Error Handling

- If jq not installed → skips changelog (warns once)
- If history missing → empty changelog (no error)
- Never blocks review workflow

## Completion Promises

**Advanced feature:** Set semantic exit criteria for the review loop.

### Usage

```bash
# Initialize with completion promise
bash scripts/init-review-loop.sh 10 "REVIEW PASSED"
```

### How It Works

- Review loop checks output for `<promise>REVIEW PASSED</promise>`
- When promise detected, loop exits successfully
- Prevents false exits and ensures genuine completion
- Inspired by Ralph Loop pattern

### Example

```bash
# Set promise
bash scripts/init-review-loop.sh 10 "ALL ISSUES RESOLVED"

# When Claude outputs:
# <promise>ALL ISSUES RESOLVED</promise>
# Loop exits successfully regardless of iteration count
```

### Use Cases

- Complex reviews requiring explicit confirmation
- Multi-stage review processes
- Custom completion criteria beyond PASS/FAIL

## State-Based Approach Details

The new state-based approach uses `.claude/codex-review-state.md` with YAML frontmatter to track:

- **active**: Whether review loop is active
- **iteration**: Current iteration number
- **max_iterations**: Maximum allowed iterations
- **completion_promise**: Optional semantic exit criteria
- **review_status**: PENDING, PASS, or FAIL
- **started_at**: ISO 8601 timestamp of loop start
- **last_result**: Last review result JSON

### Automatic Cleanup

- State file removed on PASS (keeps changelog intact)
- No manual cleanup needed
- Failure at max iterations preserves state for debugging

## Integration with Ralph Loop Pattern

This skill uses the Ralph Loop pattern for automated iteration:

- **Autonomous execution** until completion criteria met
- **Clear exit conditions**: PASS status or max iterations
- **No permission needed** for fix-and-retry cycles
- **State persistence** across iterations
- **Completion promises** for semantic exits

See references/advanced-usage.md for integration patterns with CI/CD, pre-commit hooks, and task management systems.
