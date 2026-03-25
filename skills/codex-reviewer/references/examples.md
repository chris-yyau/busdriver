# Codex Reviewer Examples

This document contains detailed workflow examples referenced from SKILL.md.

## Common Violations

### ❌ WRONG - Commit before review
```bash
git add src/index.css
git commit -m "Fix bottom nav"  # ❌ NO REVIEW!
git push
# Later: "Oh, I should review this"
```

### ✅ CORRECT - Review before commit
```bash
# Make changes
git add -A
# Review automatically detects uncommitted changes
codex review "Review the uncommitted changes..."
# Wait for PASS
# Fix any issues
# Re-review until PASS
git commit -m "Fix bottom nav"
git push
```

### ❌ WRONG - Retroactive review
```bash
git commit -m "Add feature"
git push
codex review  # ❌ Too late!
```

### ✅ CORRECT - Review then commit
```bash
# Make changes
git add -A
codex review  # Review FIRST
# Fix issues, re-review until PASS
git commit -m "Add feature"
git push
```

### ❌ WRONG - Deploy before review
```bash
supabase functions deploy push-notification-scheduler  # ❌ NO REVIEW!
# Later: "Oh, I should have reviewed this first"
# Now it's in production with bugs
```

### ✅ CORRECT - Review before deploy
```bash
# Make changes to edge function
git add -A
codex review "Review the uncommitted changes..."
# Wait for PASS
# Fix any issues
# Re-review until PASS
supabase functions deploy push-notification-scheduler
git commit -m "Deploy edge function"
```

### ❌ WRONG - Deploy to test, review later
```bash
# Write edge function code
supabase functions deploy my-function  # ❌ Deploying untested code!
curl https://project.supabase.co/functions/v1/my-function  # Test in production
# Discover bugs, fix them, deploy again
```

### ✅ CORRECT - Review, then deploy
```bash
# Write edge function code
git add -A
codex review "Review the uncommitted changes..."
# Fix issues found by review
# Re-review until PASS
# Test locally if possible
supabase functions deploy my-function
```

## If You Already Committed Without Review

**You violated the workflow. Fix it:**

1. `git reset --soft HEAD~1` (uncommit, keep changes)
2. **Initialize counter:** `echo "1" > /tmp/codex-iteration.txt`
3. Run Codex review loop
4. Fix issues and iterate until PASS
5. Clean up counter: `rm /tmp/codex-iteration.txt`
6. Commit again

**If already pushed:**
1. Locally: `git reset --soft HEAD~1`
2. Initialize counter: `echo "1" > /tmp/codex-iteration.txt`
3. Run review loop, fix issues
4. Clean up counter: `rm /tmp/codex-iteration.txt`
5. Force push: `git push --force-with-lease`

## Automation Best Practices

### Creating a Wrapper Function

Create a wrapper function that ensures consistent automation parameters:

```python
def run_codex_review(iteration_num):
    return Bash(
        command="bash ${CLAUDE_PLUGIN_ROOT}/skills/codex-reviewer/scripts/execute_review.sh",
        description=f"Run Codex review iteration {iteration_num}",
        run_in_background=True,  # Always included
        timeout=600000
    )
```

## Example 1: Automatic Iteration Loop

**Scenario:** Refactored authentication system, expecting multiple review cycles

```bash
# Initialize counter
echo "1" > /tmp/codex-iteration.txt

# --- ITERATION 1 ---
ITERATION=$(cat /tmp/codex-iteration.txt)  # 1
codex review "Review the uncommitted changes..."
# Result: FAIL - 12 issues (6 high, 6 medium)

# Fix issues
[Fix SQL injection, add input validation, fix error handling]
git add -A
echo "$((ITERATION + 1))" > /tmp/codex-iteration.txt  # 2

# --- DO NOT STOP HERE ---
# --- DO NOT ASK PERMISSION ---
# --- AUTOMATICALLY CONTINUE ---

# --- ITERATION 2 ---
ITERATION=$(cat /tmp/codex-iteration.txt)  # 2
codex review "Review the uncommitted changes..."
# Result: FAIL - 5 issues (2 high, 3 medium)

# Fix remaining issues
[Fix authentication bypass, add rate limiting, improve logging]
git add -A
echo "$((ITERATION + 1))" > /tmp/codex-iteration.txt  # 3

# --- CONTINUE AGAIN ---

# --- ITERATION 3 ---
ITERATION=$(cat /tmp/codex-iteration.txt)  # 3
codex review "Review the uncommitted changes..."
# Result: PASS

# NOW proceed to tests
npm test
# Result: PASS

# Clean up counter
rm /tmp/codex-iteration.txt

# NOW can commit
git commit -m "Refactor authentication system

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

**Key points:**
- Loop continued automatically through 3 iterations
- No permission asked between cycles
- Iteration counter tracked progress
- Only stopped at PASS

## Example 2: Reaching Max Iterations

**Scenario:** Complex changes hitting iteration limit

```bash
# ... iterations 1-9 ...

# --- ITERATION 10 ---
ITERATION=$(cat /tmp/codex-iteration.txt)  # 10
codex review "Review the uncommitted changes..."
# Result: FAIL - 3 issues (1 high, 2 medium)

# Max iterations reached - ASK USER
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
echo "  2. Commit as-is (acknowledge issues remain, file follow-up tasks)"
echo "  3. Break into smaller changes (commit what's working, iterate on problematic parts)"
echo "  4. Manually review together (interactive discussion of remaining issues)"

# WAIT FOR USER DECISION
# Do NOT continue automatically
# Do NOT make assumptions about what user wants
```

**Key points:**
- Max iterations provides safety limit
- Claude presents clear options to user
- Does not proceed automatically at limit
- User decides how to handle remaining issues
