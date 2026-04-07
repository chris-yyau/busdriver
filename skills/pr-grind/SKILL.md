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

## Anti-Patterns (DO NOT)

| Trap | Why it breaks the loop |
|------|----------------------|
| Collecting feedback while checks are still pending | You'll miss reviewer findings, fix a partial set, push, and trigger a second review cycle unnecessarily |
| Declaring "Round complete" after push without waiting | The push triggers a new review cycle — you must wait for IT to finish before declaring done |
| Only waiting for CI (build/lint/test), ignoring reviewer bots | CodeRabbit, Greptile, Cubic are checks too — `gh pr checks` shows them as pending |
| Fixing pre-existing issues flagged by automated reviewers | Scope creep — only fix issues in YOUR changed code |

## Safety Rails

- **Max iterations:** 5 rounds (override with `--max N`)
- **Autonomous by default:** Grinds without pausing between rounds (override with `--interactive` for human checkpoints)
- **Bail triggers:** Stop immediately if:
  - A comment is a design/scope question (not a code fix)
  - CI fails on an unrelated flaky test 3 times in a row
  - The fix would require architectural changes
  - Max iterations reached

## The Loop

```text
┌─────────────────────────────────────────────┐
│  START: Resolve PR number                   │
│  (from arg, current branch, or ask user)    │
└──────────────────┬──────────────────────────┘
                   │
          ┌────────▼────────┐
          │  ROUND N of MAX │
          └────────┬────────┘
                   │
     ┌─────────────▼──────────────────┐
     │  Step 1: Wait for ALL checks  │
     │  CI + automated reviewers     │
     │  (CodeRabbit, Greptile, etc.) │
     └─────────────┬────────────────┘
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

### Step 1: Wait for ALL Checks + Reviewers

**DO NOT skip this step. DO NOT proceed while checks are still pending.**

Automated reviewers (CodeRabbit, Greptile, Cubic, CodeScene, GitGuardian) register as GitHub checks. `gh pr checks --watch` blocks until ALL of them complete — not just CI build/lint/test.

```bash
# Phase 1: Wait for all GitHub-registered checks (CI + automated reviewers)
# --watch blocks until every check is pass/fail/skipped — including reviewer bots
timeout 900 gh pr checks <PR_NUMBER> --watch 2>&1 || true

# Phase 2: Verify no checks are still pending (defensive — catches race conditions)
PENDING=$(gh pr checks <PR_NUMBER> 2>&1 | grep -c "pending" || true)
if [ "$PENDING" -gt 0 ]; then
  echo "⏳ $PENDING checks still pending — waiting 60s..."
  sleep 60
fi

# Phase 3: Poll for reviewer comments that may arrive after check status flips
# Some reviewers mark their check as "pass" then post comments async
sleep 30  # Grace period for late-arriving comments
```

**Why 3 phases:** `--watch` handles most cases, but some reviewers (e.g., CodeRabbit) mark their check as "pass" and then post inline comments asynchronously. The grace period catches these late arrivals. Without it, you'll collect feedback, fix it, push — and then the reviewer's *real* feedback arrives on the old commit.

If the timeout fires before checks complete, report which checks are still pending and ask user whether to wait or proceed.

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
| **CI failure — flaky/infra** | Note it, skip after 3 consecutive identical failures |
| **Automated reviewer — specific fix** (CodeRabbit, Greptile, Cubic) | Fix it — treat like human review |
| **Automated reviewer — stale/pre-existing issue** | Skip — only fix issues in YOUR changed code |
| **Human review — specific fix request** | Fix it |
| **Human review — question/clarification** | Reply with explanation, don't change code |
| **Human review — design/scope concern** | **BAIL** — surface to user, this needs human judgment |
| **Code review — nit/style** | Fix it (low effort, high goodwill) |

**Important:** Automated reviewers often post on code that was already in the repo before your PR. Only fix issues in files/lines that YOUR PR changed. If a reviewer flags pre-existing code, note it but don't fix it in this PR.

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

**BLOCKING GATE:** The `git commit` command will block until the litmus pre-commit review passes. Litmus may auto-iterate up to 10 times to fix issues silently. Do NOT use `--no-verify` to bypass this gate. If litmus repeatedly blocks, split the changes into smaller commits.

### Step 7: Checkpoint (only with --interactive)

In autonomous mode (default), log a brief summary and continue immediately to the next round.

In interactive mode (`--interactive`), present to user and wait:

```text
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

**All of these must be true before declaring done:**
1. All CI checks passing (build, lint, test)
2. All automated reviewers completed (CodeRabbit, Greptile, Cubic, etc.)
3. No unresolved actionable comments from any source
4. No new comments arrived after your last push (wait for the full cycle)

```text
## PR Grind Complete

PR #<N> is clean after <rounds> round(s).
- CI: all checks passing
- Automated reviewers: all completed, no actionable findings
- Human comments: all addressed
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
