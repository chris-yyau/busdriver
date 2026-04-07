---
name: pr-grind
description: >
  Post-PR feedback loop — reads CI failures and reviewer comments, fixes issues, pushes,
  and repeats until the PR is clean. Use after creating a PR or on any existing PR that
  needs attention.
origin: custom
---

# PR Grind — Iterative PR Feedback Resolution

## When to Use

- After `gh pr create` succeeds and you want to stay on it until merge-ready
- When CI is failing on an open PR
- When reviewer comments need addressing
- Manually: `/pr-grind` or `/pr-grind 123` or `/pr-grind https://github.com/owner/repo/pull/123`

**Announce at start:** "Grinding PR #N — will iterate until CI is green and comments are resolved."

## Safety Rails

- **Max iterations:** 5 rounds (override with `--max N`)
- **Autonomous by default:** Grinds without pausing between rounds (override with `--interactive` for human checkpoints)
- **Bail triggers:** Stop immediately if:
  - A comment is a design/scope question (not a code fix)
  - CI fails on an unrelated flaky test 3 times in a row
  - The fix would require architectural changes
  - Max iterations reached

## The Loop

```
┌─────────────────────────────────────────────┐
│  START: Resolve PR number                   │
│  (from arg, current branch, or ask user)    │
└──────────────────┬──────────────────────────┘
                   │
          ┌────────▼────────┐
          │  ROUND N of MAX │
          └────────┬────────┘
                   │
     ┌─────────────▼─────────────┐
     │  Step 1: Wait for CI      │
     │  gh pr checks --watch     │
     └─────────────┬─────────────┘
                   │
     ┌─────────────▼─────────────┐
     │  Step 2: Collect feedback │
     │  - CI failures            │
     │  - Reviewer comments      │
     │  - Review requests        │
     └─────────────┬─────────────┘
                   │
            ┌──────▼──────┐
            │ All clean?  │──YES──▶ DONE
            └──────┬──────┘
                   │ NO
     ┌─────────────▼─────────────┐
     │  Step 3: Triage           │
     │  - Code fixes → fix them  │
     │  - Design questions → bail│
     │  - Flaky tests → note     │
     └─────────────┬─────────────┘
                   │
     ┌─────────────▼─────────────┐
     │  Step 4: Fix              │
     │  Read failing code, apply │
     │  targeted fixes           │
     └─────────────┬─────────────┘
                   │
     ┌─────────────▼─────────────┐
     │  Step 5: Verify locally   │
     │  Run relevant tests       │
     └─────────────┬─────────────┘
                   │
     ┌─────────────▼─────────────┐
     │  Step 6: Commit & push    │
     │  (litmus gate fires here) │
     └─────────────┬─────────────┘
                   │
     ┌─────────────▼─────────────┐
     │  Step 7: Checkpoint       │
     │  Show summary to user     │
     │  (skip if --auto)         │
     └─────────────┬─────────────┘
                   │
                   └──────▶ ROUND N+1
```

## Step Details

### Step 1: Wait for CI

```bash
# Wait for all checks to complete (timeout 10 minutes)
gh pr checks <PR_NUMBER> --watch --fail-on-error 2>&1 || true
```

If checks are still pending after timeout, report status and ask user whether to wait longer or proceed with what's available.

### Step 2: Collect Feedback

Gather ALL pending issues in one pass:

```bash
# CI check results
gh pr checks <PR_NUMBER>

# Reviewer comments (unresolved)
gh api repos/{owner}/{repo}/pulls/<PR_NUMBER>/comments \
  --jq '.[] | select(.position != null) | {path: .path, line: .line, body: .body, user: .user.login}'

# Review-level comments (approve/request changes/comment)
gh api repos/{owner}/{repo}/pulls/<PR_NUMBER>/reviews \
  --jq '.[] | select(.state == "CHANGES_REQUESTED" or .state == "COMMENTED") | {user: .user.login, state: .state, body: .body}'

# Issue comments (general PR discussion)
gh pr view <PR_NUMBER> --comments --json comments \
  --jq '.comments[] | {author: .author.login, body: .body}'
```

### Step 3: Triage

Classify each piece of feedback:

| Category | Action |
|----------|--------|
| **CI failure — test/lint/build** | Fix it |
| **CI failure — flaky/infra** | Note it, skip after 2 consecutive identical failures |
| **Code review — specific fix request** | Fix it |
| **Code review — question/clarification** | Reply with explanation, don't change code |
| **Code review — design/scope concern** | **BAIL** — surface to user, this needs human judgment |
| **Code review — nit/style** | Fix it (low effort, high goodwill) |

### Step 4: Fix

For each actionable item:

1. Read the relevant file(s) at the referenced lines
2. Understand the surrounding context
3. Apply the minimal fix that addresses the feedback
4. Do NOT refactor, improve, or "while I'm here" adjacent code

### Step 5: Verify Locally

Run the narrowest test that covers the fix:

```bash
# Detect test runner and run relevant subset
# npm test / pytest / go test / cargo test — scoped to changed files when possible
```

If local tests fail, fix before pushing. Do not push known-failing code.

### Step 6: Commit & Push

```bash
# Stage only the files you changed
git add <specific-files>

# Commit with descriptive message referencing the PR
git commit -m "fix: address PR #<N> feedback — <brief description>"

# Push to the PR branch
git push
```

The litmus pre-commit gate fires automatically here. If litmus finds issues, fix them before retrying the commit.

### Step 7: Checkpoint (only with --interactive)

In autonomous mode (default), log a brief summary and continue immediately to the next round.

In interactive mode (`--interactive`), present to user and wait:

```
## PR Grind — Round N/MAX complete

**Fixed:**
- [ ] CI: <what failed and how you fixed it>
- [ ] Review: <comment summary and what you changed>

**Skipped:**
- <design questions, flaky tests, etc.>

**Status:** Pushed. CI will re-run.

Continue grinding?
```

## Completion

When all CI checks pass and no unresolved actionable comments remain:

```
## PR Grind Complete

PR #<N> is clean after <rounds> round(s).
- CI: all checks passing
- Comments: all addressed
- Ready for merge.
```

## Arguments

| Argument | Description | Default |
|----------|-------------|---------|
| `<PR>` | PR number or URL | Auto-detect from current branch |
| `--max N` | Maximum iterations | 5 |
| `--interactive` | Pause for human confirmation each round | Off (autonomous) |
| `--ci-only` | Only fix CI failures, ignore comments | Off |
| `--comments-only` | Only address comments, ignore CI | Off |

## Integration

- **Pairs with:** `finishing-a-development-branch` (Phase 6 creates the PR, then `/pr-grind` handles the feedback loop)
- **Gate:** Litmus pre-commit hook fires on each `git commit` within the loop
- **Agents:** May dispatch `code-reviewer`, `build-error-resolver`, or language-specific reviewers for complex fixes
