# Litmus Examples

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

```bash
LITMUS_SCRIPTS="${BUSDRIVER_PLUGIN_ROOT}/skills/litmus/scripts"
git reset --soft HEAD~1
bash "$LITMUS_SCRIPTS/init-review-loop.sh" --force 10
bash "$LITMUS_SCRIPTS/run-review-loop.sh"
# Fix issues, re-stage, re-run until PASS, then commit again
```

**If already pushed:**
```bash
LITMUS_SCRIPTS="${BUSDRIVER_PLUGIN_ROOT}/skills/litmus/scripts"
git reset --soft HEAD~1
bash "$LITMUS_SCRIPTS/init-review-loop.sh" --force 10
bash "$LITMUS_SCRIPTS/run-review-loop.sh"
# Fix issues, re-stage, re-run until PASS
git push --force-with-lease
```

## Automation Best Practices

### Creating a Wrapper Function

Run the review as a **blocking** call (never in background).
**Prerequisite:** `init-review-loop.sh` must have been called first to create `.opencode/litmus-state.md`.

```python
def run_litmus():
    # Requires prior: bash init-review-loop.sh --force 10
    return bash(
        command="bash ${BUSDRIVER_PLUGIN_ROOT}/skills/litmus/scripts/run-review-loop.sh",
        description="Run Codex review (blocking gate)",
        timeout=1260000  # 21 min timeout
    )
```

## Example 1: Automatic Iteration Loop

**Scenario:** Refactored authentication system, expecting multiple review cycles

```bash
LITMUS_SCRIPTS="${BUSDRIVER_PLUGIN_ROOT}/skills/litmus/scripts"

# Initialize state-based review loop (max 10 iterations)
bash "$LITMUS_SCRIPTS/init-review-loop.sh" --force 10

# Each call does ONE review pass:
#   Exit 0 = PASS → proceed to commit
#   Exit 1 = FAIL → fix issues, stage, call again
#   Exit 2 = TOO_LARGE → split into smaller commits
set -e  # Ensure failed review blocks commit
bash "$LITMUS_SCRIPTS/run-review-loop.sh"
# If we reach here, review PASSED

npm test
git commit -m "Refactor authentication system"
```

**Key points:**
- Each `run-review-loop.sh` call does one review pass and exits
- The caller (Claude or script) handles fix→re-stage→re-run
- State tracked in `.opencode/litmus-state.md` with iteration history
- Cleans up state file on PASS; preserves on max iterations for inspection

## Example 2: Reaching Max Iterations

**Scenario:** Complex changes hitting iteration limit

```bash
# ... iterations 1-9 ...

# --- ITERATION 10 ---
# run-review-loop.sh tracks iteration internally
bash "$LITMUS_SCRIPTS/run-review-loop.sh"
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
