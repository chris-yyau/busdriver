# Legacy Counter Approach

This document describes the legacy manual counter approach for backward compatibility.

**Recommended:** Use the state-based approach instead (see SKILL.md).

## Legacy Manual Counter Method

### Setup

```bash
# Initialize counter
echo "1" > /tmp/codex-iteration.txt

# Check current iteration
ITERATION=$(cat /tmp/codex-iteration.txt)
echo "Current iteration: $ITERATION"
```

### Running Review

```python
# Get current iteration
ITERATION = int(open('/tmp/codex-iteration.txt').read().strip())

# Run review
result = Bash(
    command="bash ${CLAUDE_PLUGIN_ROOT}/skills/codex-reviewer/scripts/execute_review.sh",
    description=f"Run Codex review iteration {ITERATION}",
    run_in_background=True,  # MANDATORY
    timeout=600000
)
```

### Incrementing Counter

```bash
# After FAIL, increment counter
ITERATION=$(cat /tmp/codex-iteration.txt)
echo "$((ITERATION + 1))" > /tmp/codex-iteration.txt
```

### Cleanup

```bash
# After PASS or max iterations
rm /tmp/codex-iteration.txt
```

## Why State-Based is Better

1. **Automatic increment** - No manual counter management
2. **State persistence** - Survives crashes and restarts
3. **Rich metadata** - Tracks timestamps, status, last result
4. **YAML frontmatter** - Easy to parse and inspect
5. **Automatic cleanup** - Removed on PASS, no manual rm needed
6. **Completion promises** - Semantic exit criteria support
7. **Better debugging** - State file shows full loop history

## Migration Guide

### From Legacy to State-Based

**Before (legacy):**
```bash
echo "1" > /tmp/codex-iteration.txt
bash scripts/execute_review.sh
# Manual increment and iteration
rm /tmp/codex-iteration.txt
```

**After (state-based):**
```bash
bash scripts/init-review-loop.sh 10
bash scripts/run-review-loop.sh
# Automatic iteration, no manual counter
# Automatic cleanup on PASS
```

### Backward Compatibility

The `execute_review.sh` script still works with the legacy approach for backward compatibility. However, new code should use the state-based approach.

## Legacy Quick Start

```bash
# 1. Make code changes
# 2. Stage changes
git add -A

# 3. Initialize counter
echo "1" > /tmp/codex-iteration.txt

# 4. Run review via Claude
# Claude will use execute_review.sh with run_in_background=true

# 5. Fix issues, stage, iterate automatically

# 6. Once PASS: run tests and commit
npm test
git commit -m "Your message"

# 7. Clean up
rm /tmp/codex-iteration.txt

# 8. (Optional) Save changelog
bash scripts/save_changelog.sh
```
