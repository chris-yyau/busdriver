---
name: finishing-a-development-branch
description: Use when implementation is complete, all tests pass, and you need to decide how to integrate the work - guides completion of development work by presenting structured options for merge, PR, or cleanup
---

# Finishing a Development Branch

## Overview

Guide completion of development work by presenting clear options and handling chosen workflow.

**Core principle:** Verify → Dashboard → Present options → Execute → Doc sync → Clean up.

**Announce at start:** "I'm using the finishing-a-development-branch skill to complete this work."

## The Process

### Step 1: Verify Tests

**Before presenting options, verify tests pass:**

```bash
# Run project's test suite
npm test / cargo test / pytest / go test ./...
```

**If tests fail:**
```
Tests failing (<N> failures). Must fix before completing:

[Show failures]

Cannot proceed with merge/PR until tests pass.
```

Stop. Don't proceed to Step 2.

**If tests pass:** Continue to Step 2.

### Step 2: Determine Base Branch

```bash
# Try common base branches
git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null
```

Or ask: "This branch split from main - is that correct?"

### Step 3: Readiness Dashboard

Before presenting options, show a readiness summary so the user can make an informed decision:

```bash
# Gather dashboard data
BASE_BRANCH="main"  # or detected base
COMMITS=$(git log --oneline $BASE_BRANCH..HEAD | wc -l | tr -d ' ')
FILES_CHANGED=$(git diff --name-only $BASE_BRANCH..HEAD | wc -l | tr -d ' ')
LINES_ADDED=$(git diff --stat $BASE_BRANCH..HEAD | tail -1)
UNSTAGED=$(git status --porcelain | grep -v '^?' | wc -l | tr -d ' ')
```

Present the dashboard:

```
## Readiness Dashboard

| Check | Status |
|-------|--------|
| Tests | ✓ All passing |
| Commits | <N> commits on branch |
| Files changed | <N> files (<lines summary>) |
| Unstaged changes | ✓ None / ⚠ <N> files with uncommitted changes |
| Code review | ✓ Reviewed / ⚠ Not reviewed |

<If unstaged changes exist>
⚠ You have uncommitted changes. Consider committing or stashing before proceeding.
```

**Code review status:** Check if the code-reviewer agent was dispatched during this session. If not, note it as a warning but don't block — the codex-reviewer gate will enforce at commit/PR time.

### Step 4: Present Options

Present exactly these 4 options:

```
Implementation complete. What would you like to do?

1. Merge back to <base-branch> locally
2. Push and create a Pull Request
3. Keep the branch as-is (I'll handle it later)
4. Discard this work

Which option?
```

**Don't add explanation** - keep options concise.

### Step 5: Execute Choice

#### Option 1: Merge Locally

```bash
# Switch to base branch
git checkout <base-branch>

# Pull latest
git pull

# Merge feature branch
git merge <feature-branch>

# Verify tests on merged result
<test command>

# If tests pass
git branch -d <feature-branch>
```

Then: Doc sync (Step 6) → Cleanup worktree (Step 7)

#### Option 2: Push and Create PR

```bash
# Push branch
git push -u origin <feature-branch>

# Create PR
gh pr create --title "<title>" --body "$(cat <<'EOF'
## Summary
<2-3 bullets of what changed>

## Test Plan
- [ ] <verification steps>
EOF
)"
```

Then: Doc sync (Step 6) → Cleanup worktree (Step 7)

#### Option 3: Keep As-Is

Report: "Keeping branch <name>. Worktree preserved at <path>."

**Don't cleanup worktree. Skip doc sync.**

#### Option 4: Discard

**Confirm first:**
```
This will permanently delete:
- Branch <name>
- All commits: <commit-list>
- Worktree at <path>

Type 'discard' to confirm.
```

Wait for exact confirmation.

If confirmed:
```bash
git checkout <base-branch>
git branch -D <feature-branch>
```

Then: Cleanup worktree (Step 7). Skip doc sync.

### Step 6: Doc Sync (Options 1 & 2 only)

Before finalizing, cross-reference documentation against the diff to catch stale references:

```bash
# Get list of changed/deleted/renamed files
CHANGED_FILES=$(git diff --name-only --diff-filter=AMRD $BASE_BRANCH..HEAD)
DELETED_FILES=$(git diff --name-only --diff-filter=D $BASE_BRANCH..HEAD)
RENAMED_FILES=$(git diff --name-status --diff-filter=R $BASE_BRANCH..HEAD)
```

**Check for each documentation file** (README.md, CLAUDE.md, docs/**/*.md):

1. **Stale file references** — Does any doc reference a file that was deleted or renamed in this branch?
2. **Stale command references** — If CLI commands, scripts, or entry points were changed, do docs still reference old names/paths?
3. **Outdated structure trees** — If the file tree section exists, does it reflect added/removed files?
4. **Completed TODOs** — Scan docs for TODO items that reference work completed in this branch

```bash
# Quick scan: find docs referencing deleted files
for f in $(git diff --name-only --diff-filter=D $BASE_BRANCH..HEAD); do
  grep -rl "$f" docs/ README.md CLAUDE.md 2>/dev/null
done
```

**If stale references found:**
- Fix them directly (update paths, remove references to deleted files)
- Stage and commit as `docs: sync references with implementation changes`
- This commit goes through the normal codex review gate

**If no stale references:** Note "Doc sync: no stale references found" and continue.

### Step 7: Cleanup Worktree

**For Options 1, 2, 4:**

Check if in worktree:
```bash
git worktree list | grep $(git branch --show-current)
```

If yes:
```bash
git worktree remove <worktree-path>
```

**For Option 3:** Keep worktree.

## Quick Reference

| Step | What | When |
|------|------|------|
| 1. Verify tests | Run test suite | Always |
| 2. Base branch | Detect merge target | Always |
| 3. Dashboard | Show readiness summary | Always |
| 4. Options | Present 4 choices | Always |
| 5. Execute | Run chosen option | Always |
| 6. Doc sync | Cross-reference docs vs diff | Options 1 & 2 |
| 7. Worktree cleanup | Remove worktree | Options 1, 2, 4 |

| Option | Merge | Push | Doc Sync | Cleanup |
|--------|-------|------|----------|---------|
| 1. Merge locally | ✓ | - | ✓ | ✓ |
| 2. Create PR | - | ✓ | ✓ | ✓ |
| 3. Keep as-is | - | - | - | - |
| 4. Discard | - | - | - | ✓ (force) |

## Common Mistakes

**Skipping test verification**
- **Problem:** Merge broken code, create failing PR
- **Fix:** Always verify tests before offering options

**Open-ended questions**
- **Problem:** "What should I do next?" → ambiguous
- **Fix:** Present exactly 4 structured options

**Automatic worktree cleanup**
- **Problem:** Remove worktree when might need it (Option 2, 3)
- **Fix:** Only cleanup for Options 1 and 4

**No confirmation for discard**
- **Problem:** Accidentally delete work
- **Fix:** Require typed "discard" confirmation

**Skipping doc sync**
- **Problem:** Stale file paths, outdated commands in docs after rename/delete
- **Fix:** Always run doc sync for Options 1 & 2 before finalizing

## Red Flags

**Never:**
- Proceed with failing tests
- Merge without verifying tests on result
- Delete work without confirmation
- Force-push without explicit request
- Skip doc sync when files were renamed or deleted

**Always:**
- Verify tests before offering options
- Show readiness dashboard before presenting options
- Present exactly 4 options
- Run doc sync for Options 1 & 2
- Get typed confirmation for Option 4
- Clean up worktree for Options 1, 2 & 4

## Integration

**Called by:**
- **subagent-driven-development** (Step 7) - After all tasks complete
- **executing-plans** (Step 5) - After all batches complete

**Pairs with:**
- **using-git-worktrees** - Cleans up worktree created by that skill
