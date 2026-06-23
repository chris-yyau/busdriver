---
name: finishing-a-development-branch
description: Use when implementation is complete, all tests pass, and you need to decide how to integrate the work - guides completion of development work by presenting structured options for merge, PR, or cleanup
---

# Finishing a Development Branch

## Overview

Guide completion of development work by presenting clear options and handling chosen workflow.

**Core principle:** Verify tests → Detect environment → Present options → Execute choice → Clean up.

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

**If tests pass:** Continue to Step 1.5.

### Step 1.5: Detect Environment

The workspace shape changes which options are valid — detect it before presenting them:

```bash
branch=$(git symbolic-ref --quiet --short HEAD || echo "")   # empty => detached HEAD
case "$(git rev-parse --git-dir)" in */worktrees/*) worktree=yes ;; *) worktree=no ;; esac
```

- **Normal repo on a named branch** — all 4 options apply.
- **Linked worktree** (`worktree=yes`) — Option 1 (local merge) would switch the primary checkout's branch; prefer Option 2 (PR), or merge from the primary worktree. Cleanup (Step 5) removes *this* worktree.
- **Detached HEAD** (`branch` empty) — nothing to merge or keep by name. Offer to create a branch first (`git switch -c <name>`), then present the 4 options.

### Step 2: Determine Base Branch

```bash
# Try common base branches
git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null
```

Or ask: "This branch split from main - is that correct?"

### Step 3: Present Options

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

### Step 4: Execute Choice

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

Then: Cleanup worktree (Step 5)

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

<EXTREMELY-IMPORTANT>
After PR is created (BEFORE worktree cleanup):
1. **DO NOT enable GitHub auto-merge.** It races against pr-grind — the PR merges before reviewer comments are addressed.
2. **INVOKE `busdriver:pr-grind --no-worktree`** (you're still on the PR branch) for the default flow, or **`busdriver:pr-grind --no-worktree --no-merge`** to opt out of auto-merge. Do NOT give separate "grind then merge" instructions — that causes agents to skip CI waiting.
3. In the default flow, do NOT attempt `gh pr merge` separately — pr-grind handles it after all checks pass and comments are addressed. Manual `gh pr merge` is only appropriate in the `--no-merge` opt-out path, after pr-grind writes the clean marker.
</EXTREMELY-IMPORTANT>

Then: Cleanup worktree (Step 5)

#### Option 3: Keep As-Is

Report: "Keeping branch <name>. Worktree preserved at <path>."

**Don't cleanup worktree.**

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

Then: Cleanup worktree (Step 5)

### Step 5: Cleanup Worktree

**For Options 1, 2, 4:**

Only clean up a worktree you created, and confirm the exact path first — path naming is not proof of ownership:
```bash
wt=$(git rev-parse --show-toplevel)
case "$(git rev-parse --git-dir)" in */worktrees/*) is_wt=yes ;; *) is_wt=no ;; esac
```

- `is_wt=no` → normal checkout; nothing to clean up.
- `is_wt=yes` → report `$wt` and **ask before** `git worktree remove "$wt"`. Never auto-remove. Skip entirely if it is harness-managed (a `worktrees/` directory under the harness state dir — `.claude/worktrees/*`, or `${BUSDRIVER_STATE_DIR:-.claude}/worktrees/*` such as `.opencode/worktrees/*` — created by the EnterWorktree tool, which has its own cleanup) or an operator worktree you did not create.

**For Option 3:** Keep worktree.

## Quick Reference

| Option | Merge | Push | Keep Worktree | Cleanup Branch |
|--------|-------|------|---------------|----------------|
| 1. Merge locally | ✓ | - | ask† | ✓ |
| 2. Create PR | - | ✓ | ask† | - |
| 3. Keep as-is | - | - | ✓ | - |
| 4. Discard | - | - | - | ✓ (force) |

† Options 1, 2, and 4 **offer** worktree cleanup but **ask before removing** (never automatic), and only for a worktree you created (skip harness-managed ones). Option 3 keeps the worktree. This matches Step 5.

## Common Mistakes

**Skipping test verification**
- **Problem:** Merge broken code, create failing PR
- **Fix:** Always verify tests before offering options

**Open-ended questions**
- **Problem:** "What should I do next?" → ambiguous
- **Fix:** Present exactly 4 structured options

**Automatic worktree cleanup**
- **Problem:** Removing a worktree the user still needs (Option 3), or one you did not create (harness-managed)
- **Fix:** Offer cleanup for Options 1, 2, and 4 but **ask first** (never automatic); keep for Option 3; skip harness-managed worktrees

**No confirmation for discard**
- **Problem:** Accidentally delete work
- **Fix:** Require typed "discard" confirmation

## Red Flags

**Never:**
- Proceed with failing tests
- Merge without verifying tests on result
- Delete work without confirmation
- Force-push without explicit request
- Enable GitHub auto-merge (pr-grind merges by default after grinding clean)
- Give compound "grind then merge" instructions (just invoke pr-grind — merge is default)

**Always:**
- Verify tests before offering options
- Present exactly 4 options
- Get typed confirmation for Option 4
- Clean up worktree for Options 1 & 4 only

## Integration

**Called by:**
- **subagent-driven-development** (Step 7) - After all tasks complete
- **executing-plans** (Step 5) - After all batches complete

**Pairs with:**
- **using-git-worktrees** - Cleans up worktree created by that skill
