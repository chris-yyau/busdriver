# Litmus Scripts Reference

Detailed documentation for all scripts in the litmus skill.

## Core Scripts

### init-review-loop.sh

**Purpose:** Initialize state file for review loop.

**Usage:**
```bash
/bin/bash -p scripts/init-review-loop.sh [max_iterations] [completion_promise]
```

**Arguments:**
- `max_iterations` (optional, default: 10) - Maximum review iterations
- `completion_promise` (optional, default: null) - Semantic exit criteria

**Examples:**
```bash
# Basic initialization
/bin/bash -p scripts/init-review-loop.sh

# Custom max iterations
/bin/bash -p scripts/init-review-loop.sh 15

# With completion promise
/bin/bash -p scripts/init-review-loop.sh 10 "REVIEW PASSED"
```

**Output:**
- Creates `.claude/litmus-state.md` with YAML frontmatter
- Displays initialization summary
- Shows next steps

**Exit codes:**
- 0: Success
- 1: Invalid arguments or not in git repository

### run-review-loop.sh

**Purpose:** Main review loop with state management and automatic iteration.

**Usage:**
```bash
/bin/bash -p scripts/run-review-loop.sh
```

**Requirements:**
- `.claude/litmus-state.md` must exist (run `init-review-loop.sh` first)
- Staged git changes (run `git add -A`)

**Behavior:**
1. Reads current state from `.claude/litmus-state.md`
2. Runs SAST tools (semgrep, shellcheck, trufflehog) if available
3. Collects smart context (callers, importers, docs references)
4. Runs codex review with enriched prompt
5. Parses result and updates state file
6. Outputs human-readable progress logs to stdout

**Output:**
- Human-readable progress and review results to stdout
- Updates `.claude/litmus-state.md` with iteration results
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
- Appends one JSON line to `.claude/review-metrics.jsonl`
- Captures: status, issues, severity breakdown, commit SHA, branch, diff size
- Called automatically by `run-review-loop.sh` after merge-findings

**Configuration:**
- `LITMUS_METRICS_FILE` — override output path (default: `.claude/review-metrics.jsonl`)

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
    command="/bin/bash -p scripts/init-review-loop.sh 10",
    description="Initialize codex review loop",
    timeout=5000
)

# Run review — BLOCKING, never backgrounded. SKILL.md's CRITICAL RULES are
# explicit ("Do NOT use background tasks or polling"), and the reason is not
# style: while the call blocks, the session cannot advance and therefore cannot
# read half-written review artifacts or build a verdict from partial state. A
# backgrounded gate is an incomplete gate that orchestration can walk past.
output = Bash(
    command="/bin/bash -p scripts/run-review-loop.sh",
    description=f"Run Codex review iteration {iteration}",
    timeout=600000  # 10 min — the harness CAPS this; larger values are clamped
)

# Parse result
result = json.loads(output['output'])
```

### Using in Pre-commit Hooks

```bash
#!/bin/bash
# .git/hooks/pre-commit

set -e

# CLAUDE_PLUGIN_ROOT is set only inside Claude's skill renderer. A git hook runs
# outside it, so resolve an explicit root and fail loudly rather than expanding to
# `/skills/...` and dying with exit 127. Quoted throughout: the path may contain
# whitespace.
#
# EXPORT it as BUSDRIVER_PLUGIN_ROOT, not a name of your own: run-review-loop.sh
# locates its shared JSON extractor via `${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}`,
# so a root under any other variable leaves that lookup empty and silently demotes
# the run to the narrative parser, which can reject valid review output.
#
# Write the path LITERALLY. Do not fall back to an inherited BUSDRIVER_PLUGIN_ROOT or
# CLAUDE_PLUGIN_ROOT: environment is repo-injectable (a committed `.claude/settings.json`
# `env` block sets variables — #325 / ADR 0016), and this hook runs BEFORE any review, so
# accepting either would let the checkout name the review loop that is about to judge it.
# There is no skill renderer in a git hook, so CLAUDE_PLUGIN_ROOT is not authoritative
# here either. $HOME remains an ambient input this example cannot close; the sanitized
# route is the PreToolUse `pre-commit-gate.sh`, not a hand-written hook.
export BUSDRIVER_PLUGIN_ROOT="$HOME/.claude/plugins/marketplaces/busdriver"
[ -d "$BUSDRIVER_PLUGIN_ROOT" ] || { echo "busdriver plugin root not found: $BUSDRIVER_PLUGIN_ROOT" >&2; exit 1; }

# Initialize
/bin/bash -p "$BUSDRIVER_PLUGIN_ROOT/skills/litmus/scripts/init-review-loop.sh" 3

# Run review
RESULT=$(/bin/bash -p "$BUSDRIVER_PLUGIN_ROOT/skills/litmus/scripts/run-review-loop.sh")
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
# Check the reviewer out from ITS OWN repository. `actions/checkout` requires a
# path under $GITHUB_WORKSPACE, so this directory sits inside the workspace — but
# the action OVERWRITES it with the busdriver ref's content, so what executes comes
# from busdriver even if the reviewed repo ships a `.busdriver-plugin/` of its own.
# Location is not the control here; provenance of the content is.
#
# Both pins are load-bearing and for the same reason. `uses:` is a COMMIT SHA, not
# a mutable tag: a moved tag runs unreviewed action code with workflow credentials
# before the reviewer starts, which is the checkout step compromising the review it
# is meant to set up. `ref:` pins the reviewer itself to a COMMIT SHA for the same
# reason -- a tag is mutable, so `ref: v2.1.9` would leave whoever can retarget that
# tag able to swap the reviewer, which is the property this pin exists to remove.
# The trailing comment records which release the SHA is, the way `uses:` does.
# Bump both deliberately.
- name: Check out busdriver
  uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
  with:
    repository: chris-yyau/busdriver
    ref: 34b9035af5b2400fdd61f94e088d82000a1c7261  # v2.1.9
    path: .busdriver-plugin

- name: Review Code
  env:
    # Same reason as the pre-commit hook above: no skill renderer in CI. Set the
    # variable run-review-loop.sh actually reads, HERE in `env:` rather than from
    # whatever the job inherited — a workflow-level value is what the operator
    # controls, and `${{ github.workspace }}` is absolute, so the `cd` below cannot
    # change what it points at.
    BUSDRIVER_PLUGIN_ROOT: ${{ github.workspace }}/.busdriver-plugin
  run: |
    cd "$GITHUB_WORKSPACE"
    # Fail loudly rather than expanding to `/skills/...` and dying with exit 127.
    [ -d "$BUSDRIVER_PLUGIN_ROOT" ] || { echo "busdriver plugin root not found: $BUSDRIVER_PLUGIN_ROOT" >&2; exit 1; }
    /bin/bash -p "$BUSDRIVER_PLUGIN_ROOT/skills/litmus/scripts/init-review-loop.sh" 5
    /bin/bash -p "$BUSDRIVER_PLUGIN_ROOT/skills/litmus/scripts/run-review-loop.sh"
```

## Environment Variables

- `LITMUS_CHANGELOG_LIMIT` - Number of changelog entries to load (default: 3)
- `CURRENT_TASK_ID` - Task ID for changelog tracking (optional)

## File Locations

- **State file:** `.claude/litmus-state.md` (in project root)
- **Changelog:** `~/.claude/projects/{project}/litmus-context/`
- **Legacy counter:** `/tmp/litmus-iteration.txt` (deprecated)
- **Prompt template:** `${CLAUDE_PLUGIN_ROOT}/skills/litmus/prompt_template.txt`
