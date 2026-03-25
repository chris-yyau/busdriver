# Codex Reviewer Workflow Details

Detailed iteration examples and workflow patterns referenced from SKILL.md.

## Automatic Iteration Requirements

**CRITICAL:** The review loop must iterate automatically without asking permission.

### Automation Rules

1. **Initialize counter ONCE** at start of review loop
2. **Run review** with `run_in_background=true`
3. **If FAIL:** Fix issues, stage changes, increment counter, **IMMEDIATELY return to step 2**
4. **No permission needed** to continue iterating
5. **Only stop** when PASS or max iterations reached

### Why This Matters

- Asking permission breaks the automatic loop
- Manual intervention slows down the workflow
- The skill enforces discipline, not bureaucracy
- Max iterations (10) provides safety net

## Detailed Iteration Examples

### Example 1: Single Issue (2 iterations)

```bash
# Initialize
echo "1" > /tmp/codex-iteration.txt
git add -A

# Iteration 1
codex review "Review uncommitted changes..."
# Result: FAIL - 1 issue (SQL injection in auth.ts:45)

# Fix issue
[Fix SQL injection by using parameterized query]
git add -A
echo "2" > /tmp/codex-iteration.txt

# Iteration 2 - AUTOMATIC, NO PERMISSION
codex review "Review uncommitted changes..."
# Result: PASS

# Proceed to tests and commit
npm test
git commit -m "Fix authentication"
rm /tmp/codex-iteration.txt
```

**Key point:** Loop continued automatically from iteration 1 to 2 without asking permission.

### Example 2: Multiple Issues (4 iterations)

```bash
# Initialize
echo "1" > /tmp/codex-iteration.txt
git add -A

# --- ITERATION 1 ---
codex review "Review uncommitted changes..."
# Result: FAIL - 8 issues (4 high, 4 medium)

# Fix high severity issues
[Fix XSS, SQL injection, auth bypass, missing validation]
git add -A
echo "2" > /tmp/codex-iteration.txt

# --- ITERATION 2 - AUTOMATIC ---
codex review "Review uncommitted changes..."
# Result: FAIL - 5 issues (1 high, 4 medium)

# Fix remaining high and some medium issues
[Fix race condition, add error handling, improve logging]
git add -A
echo "3" > /tmp/codex-iteration.txt

# --- ITERATION 3 - AUTOMATIC ---
codex review "Review uncommitted changes..."
# Result: FAIL - 2 issues (2 medium)

# Fix last medium issues
[Add input sanitization, improve error messages]
git add -A
echo "4" > /tmp/codex-iteration.txt

# --- ITERATION 4 - AUTOMATIC ---
codex review "Review uncommitted changes..."
# Result: PASS

# Proceed to tests and commit
npm test
git commit -m "Refactor authentication system"
rm /tmp/codex-iteration.txt
```

**Key points:**
- Loop ran through 4 iterations automatically
- No permission asked between cycles
- Iteration counter tracked progress
- Only stopped at PASS

### Example 3: Max Iterations Reached

```bash
# ... iterations 1-9 ...

# --- ITERATION 10 ---
ITERATION=$(cat /tmp/codex-iteration.txt)  # 10
codex review "Review uncommitted changes..."
# Result: FAIL - 3 issues (1 high, 2 medium)

# Max iterations reached - STOP AND ASK USER
echo "🛑 Max iterations (10) reached without PASS"
echo ""
echo "Current status:"
echo "  Review: FAIL"
echo "  Remaining issues: 3 (1 high, 2 medium)"
echo ""
echo "Issues summary:"
echo "  1. [HIGH] Missing error handling in transaction rollback (auth.ts:245)"
echo "  2. [MED] Inefficient query in getUserRoles (auth.ts:312)"
echo "  3. [MED] Hardcoded timeout value (auth.ts:198)"
echo ""
echo "What would you like to do?"
echo "  1. Continue loop (reset counter, keep iterating)"
echo "  2. Break into smaller changes (commit working parts, iterate on problems)"
echo "  3. Manual review (interactive discussion of issues)"
echo "  4. Commit with issues (acknowledge technical debt, file follow-up tasks)"

# WAIT FOR USER DECISION
# Do NOT continue automatically
# Do NOT make assumptions about what user wants
```

**Key points:**
- Max iterations provides safety limit
- Claude presents clear options
- Does not proceed automatically at limit
- User decides how to handle remaining issues

## Common Patterns

### Pattern 1: Simple Fix
```
Review → FAIL (3 issues) → Fix → Review → PASS → Test → Commit
```

### Pattern 2: Multi-Iteration
```
Review → FAIL (12 issues) → Fix → Review → FAIL (5 issues) → Fix → Review → PASS → Test → Commit
```

### Pattern 3: Max Iterations
```
Review → FAIL → Fix → ... (10 iterations) → Max reached → Ask user
```

## Automation Best Practices

### Creating a Wrapper Function

```python
def run_codex_review(iteration_num):
    return Bash(
        command="bash ${CLAUDE_PLUGIN_ROOT}/skills/codex-reviewer/scripts/run-review-loop.sh",
        description=f"Run Codex review iteration {iteration_num}",
        run_in_background=True,  # Always included
        timeout=600000
    )
```

### Consistent Automation

```python
# CORRECT - automated every iteration
for iteration in range(1, 11):
    result = Bash(
        command="bash scripts/run-review-loop.sh",
        run_in_background=True,  # EVERY iteration
        timeout=600000
    )
    if result['status'] == 'PASS':
        break

# WRONG - inconsistent automation
Bash(command="...", run_in_background=True)  # First iteration
Bash(command="...")  # Second iteration - MISSING FLAG!
```

## Using State-Based Approach

### Quick Start

```bash
# 1. Make code changes
# 2. Stage changes
git add -A

# 3. Initialize review loop
bash scripts/init-review-loop.sh 10

# 4. Run review (loops automatically)
bash scripts/run-review-loop.sh

# 5. If FAIL: fix issues, stage, run again
# Loop continues until PASS

# 6. Once PASS: run tests
npm test

# 7. Commit
git commit -m "Your message"

# 8. (Optional) Save changelog for context continuity
bash scripts/save_changelog.sh
```

### State File Format

`.claude/codex-review-state.md` contains:

```markdown
---
active: true
iteration: 3
max_iterations: 10
completion_promise: null
review_status: "FAIL"
started_at: "2024-01-30T15:30:00Z"
last_result: {"status": "FAIL", "issues": [...]}
---

[Review prompt with changelog context]
```
