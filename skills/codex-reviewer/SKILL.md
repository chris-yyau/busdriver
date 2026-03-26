---
name: codex-reviewer
description: >
  Use before git commits, deployments, or PR creation. Trigger when about to:
  commit code, push changes, deploy to production, create pull requests, or
  finalize any code changes. Required before all code deployment actions.
---

# Codex Reviewer

<EXTREMELY-IMPORTANT>
YOU MUST RUN THE CODEX REVIEW LOOP BEFORE EVERY COMMIT. NO EXCEPTIONS.

This is a BLOCKING, MANDATORY gate. Code CANNOT be committed without a PASS from the review loop.

DO NOT rationalize skipping review. These thoughts are violations:
- "This change is too simple to review"
- "I already manually reviewed the code"
- "The user said it's urgent, I'll review later"
- "It's just a config/typo/docs change"
- "I'll fix it in the next commit"
- "The tests pass, so it must be fine"
- "I already ran the review on a similar change"
- "The diff is too small to matter"

EVERY commit MUST:
1. Run `run-review-loop.sh` as a BLOCKING bash call (timeout=1860000)
2. Wait for the result — NEVER run in background
3. If FAIL: fix issues silently, re-run — do NOT ask user between iterations
4. If PASS: proceed to tests and commit
5. NEVER use `--no-verify` or skip hooks to bypass review
</EXTREMELY-IMPORTANT>

## Purpose

Enforce automated code quality gates before committing or deploying code. Review code for bugs, security issues, performance problems, and maintainability using OpenAI Codex CLI.

## When to Use

**BLOCKING REQUIREMENT:** Invoke this skill BEFORE:
- `git commit`
- `git push`
- Deployment commands
- PR creation
- Any action finalizing code changes

**Trigger when thinking:**
- "Time to commit this code"
- "Let me write a commit message"
- "Ready to deploy/push/create PR"

## Red Flags - STOP and Run Review

These thoughts mean you're about to violate the requirement:

| Excuse | Reality |
|--------|---------|
| "This change is too simple to review" | Simple bugs exist. Review takes 30 seconds. |
| "I'll review after commit" | Defeats purpose. Review prevents bad commits. |
| "Already manually tested" | Manual ≠ automated review. Different issues found. |
| "User said it's urgent" | Bad code is slower than review. Quality > speed. |
| "Review takes too long" | Wasted debugging time > review time. |
| "Code is obviously correct" | Obvious bugs are the most common. |
| "This is just a typo fix" | Typos can break functionality. Review everything. |
| "I'll fix it in the next commit" | Then review the next commit. No exceptions. |

**All of these mean: STOP. Run codex review. No exceptions.**

## Core Workflow

### Recommended: Use Pre-Commit Hooks (Automatic)

**Best approach:** Projects with pre-commit hooks handle review automatically.

1. **Check for hooks:** `ls -la .git/hooks/pre-commit`
2. **If hooks exist:** Just commit normally - review runs automatically
   ```bash
   git add -A
   git commit -m "Your message"
   # Hook automatically runs review before committing
   ```
3. **If hooks don't exist:** See "Manual Workflow" below

### Manual Workflow (5 Steps)

Use this only if pre-commit hooks aren't available:

**1. Set script path:**
```bash
CODEX_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/skills/codex-reviewer/scripts"
```

**2. Initialize:** `bash $CODEX_SCRIPTS/init-review-loop.sh`
   (Defaults to 10 max iterations)

**3. Run Review (BLOCKING - wait for result):**
```bash
# Run as BLOCKING call - just wait for the result
Bash(
    command='bash "${CLAUDE_PLUGIN_ROOT}/skills/codex-reviewer/scripts/run-review-loop.sh"',
    timeout=1860000  # 31 min timeout (inner codex review timeout is 30 min)
)
```

**4. Auto-Continue Loop (fully silent):**
- **PASS (exit 0)** → Proceed to step 5 (tests & commit)
- **FAIL (exit 1)** → **Silently** fix all issues, stage, re-run step 3
  - Do NOT show user each iteration
  - Do NOT ask for permission between iterations
  - Do NOT use background tasks or polling
  - Just fix → stage → re-run in a tight loop
- **TOO LARGE (exit 2)** → Auto-split into smaller commits (see below)
- **TIMEOUT (exit 124)** → Split into smaller commits and retry each group
- **Max iterations (10)** → Stop, show summary, ask user
- **Only talk to user when:** PASS, max iterations, or codex quota error

**5. Run Tests & Commit:** Only after review passes, tests pass
```bash
npm test                    # Run test suite
git commit -m "Message"
```

## Auto-Continue Loop (Default Behavior)

**This is the default workflow** - fully automated, silent iteration:

1. Run review (BLOCKING, 31 min timeout) → get result
2. If PASS → done, proceed to tests & commit
3. If FAIL → **silently** fix issues, stage, re-run step 1
4. If TOO LARGE (exit 2) or TIMEOUT (exit 124) → auto-split (see below)
5. Repeat until PASS or max iterations (10)

**CRITICAL RULES:**
- **NO background tasks** - run blocking, wait for result
- **NO polling/sleep loops** - just use timeout=1860000
- **NO user interaction** between iterations - fix silently
- **NO verbose progress** - don't narrate each step
- **ONLY talk to user when:** PASS, max iterations, or error

## Auto-Split on Large Diffs

When the review script exits with code **2** (TOO LARGE) or **124** (TIMEOUT), the staged diff is too large for a single review. The script outputs a suggested split plan grouping files by directory.

**What to do on exit code 2 or 124:**

1. Read the script output — it lists staged files with line counts and suggested groups
2. `git reset HEAD` — unstage all files
3. Group files into logical commits (same module/feature together, using the suggestions as a starting point)
4. For each group:
   a. `git add <files in group>`
   b. `bash $CODEX_SCRIPTS/init-review-loop.sh`
   c. `bash $CODEX_SCRIPTS/run-review-loop.sh` (review loop for this group)
   d. Fix issues if FAIL, re-run until PASS
   e. `git commit -m '<descriptive message for this group>'`
5. Repeat until all files are committed

**Why auto-split:**
- Each commit is logically coherent (not "batch 1 of 3")
- Smaller diffs = faster reviews that complete within timeout
- Better git history with meaningful commit messages
- Prevents crashes from oversized prompts

**Thresholds (commit mode only — PR mode skips size check):** Weighted lines use additions at 1x + deletions at 0.25x (deleted code needs minimal review). Triggers: >800 weighted lines (>2000 for single-file) OR >2000 total raw lines OR >8 staged files. Override with `CODEX_MAX_WEIGHTED_LINES` and `CODEX_MAX_STAGED_FILES` env vars.

**Example:**
```
Claude: "Review detected large diff (847 lines, 12 files). Auto-splitting..."
Claude: "Group 1: src/security/ (3 files, 230 lines)"
  → init → review → PASS → commit "feat: add path guard security module"
Claude: "Group 2: src/workers/ (2 files, 180 lines)"
  → init → review → PASS → commit "feat: add claude code worker"
Claude: "Group 3: src/utils/ (4 files, 290 lines)"
  → init → review → PASS → commit "feat: add utility modules"
Claude: "All groups committed successfully."
```

**State persists in:** `.claude/codex-review-state.md`

## Example: Silent Auto-Continue

```
Claude: "Running codex review for commit 1 (database schema)..."
[Runs 3 iterations silently - user sees nothing]
Claude: "✅ Codex review PASSED after 3 iterations. Committing..."
git commit -m "feat: Add notification database schema"
```

**Anti-pattern (DO NOT DO THIS):**
```
Claude: "Running review in background..."
Claude: "Still running... 20s"
Claude: "Still running... 40s"
Claude: "Review found 2 issues. Let me fix them..."
Claude: "Fixed! Re-running..."
Claude: "Still running... 20s"
[User falls asleep]
```

<CRITICAL>
<!-- advisory: the real gate is the PreToolUse hook in pre-commit-gate.sh -->
EXECUTION MUST BE BLOCKING. NEVER run review in background.

If you are about to set `run_in_background=True` for the review loop, STOP. This defeats the entire gate — you'll proceed to commit while review is still running.
</CRITICAL>

## Execution Pattern

```bash
# ✅ CORRECT - blocking, silent
Bash(
    command='bash "${CLAUDE_PLUGIN_ROOT}/skills/codex-reviewer/scripts/run-review-loop.sh"',
    timeout=1860000  # 11 min (inner timeout is 10 min)
)
# Parse exit code: 0=PASS, 1=FAIL (fix and re-run), 2=TOO_LARGE (split), 124=TIMEOUT (split)

# ❌ WRONG - background + polling
Bash(
    command="...",
    run_in_background=True  # NEVER use this for codex review
)
```

**Note:** If project has pre-commit hooks, just use `git commit` normally.

## Review Output

JSON format: `{"status": "PASS"|"FAIL", "issues": [{file, line, severity, category, description, suggestion}, ...]}`

- **PASS:** No issues or only low-severity
- **FAIL:** One or more high/medium severity issues

## Violation Recovery

**If already committed without review:**

```bash
# Uncommit (keep changes)
git reset --soft HEAD~1

# If using pre-commit hooks:
git commit -m "Your message"  # Hooks will enforce review

# If using manual approach:
CODEX_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/skills/codex-reviewer/scripts"
bash $CODEX_SCRIPTS/init-review-loop.sh 10
bash $CODEX_SCRIPTS/run-review-loop.sh
# Fix issues, iterate until PASS, then commit again
```

**If already pushed:**

```bash
git reset --soft HEAD~1
# Review, fix, iterate until PASS
git push --force-with-lease  # Use with caution
```

## Quick Reference

**With pre-commit hooks (recommended):**
```bash
git add -A              # Stage changes
git commit -m "Message" # Hooks automatically run review
git push                # Push after review passes
```

**Manual approach (if no hooks):**
```bash
git add -A                                                          # Stage changes
CODEX="${CLAUDE_PLUGIN_ROOT}/skills/codex-reviewer/scripts"
bash $CODEX/init-review-loop.sh 10                                  # Initialize
bash $CODEX/run-review-loop.sh                                      # Review (auto-loops)
# Fix if FAIL, run again until PASS
npm test                                                            # Tests
git commit -m "Message"                                             # Commit
```

## PR Review Mode (Deep — Multi-Voice)

When the pre-PR gate blocks `gh pr create`, run the deep review. This combines the codex CLI pass with a 5-agent multi-voice review for cross-commit depth.

### Step 1: Codex CLI Pass (fast)

```bash
# Initialize and run in PR mode (same as before)
CODEX_REVIEW_MODE=pr bash "${CLAUDE_PLUGIN_ROOT}/skills/codex-reviewer/scripts/init-review-loop.sh"
CODEX_REVIEW_MODE=pr bash "${CLAUDE_PLUGIN_ROOT}/skills/codex-reviewer/scripts/run-review-loop.sh"
```

If FAIL → fix and re-run (same auto-continue loop as commit mode).

### Step 2: Multi-Agent Deep Review

<EXTREMELY-IMPORTANT>
YOU MUST WAIT FOR ALL 5 AGENTS TO RETURN BEFORE PROCEEDING TO STEP 3.

DO NOT:
- Write the PR marker after only some agents complete
- Rationalize "I have enough results" with partial returns
- Create the PR while agents are still running
- Use early agent results to decide "no blocking issues" before all return

If an agent is slow, WAIT. If it times out after 10 minutes, mark it as timed-out and proceed with the remaining results. But never proceed while agents are still "running" or "in progress".
</EXTREMELY-IMPORTANT>

After codex CLI passes, dispatch **5 parallel review agents** using the Agent tool. Each reviews the full `base..HEAD` diff from a different lens. Launch all 5 in a **single message** for concurrency.

| Agent | Lens | Focus |
|-------|------|-------|
| 1 | **Guidelines** | CLAUDE.md compliance, project conventions, naming consistency |
| 2 | **Bugs** | Logic errors, off-by-one, null/undefined, race conditions (changes only, not full codebase) |
| 3 | **History** | Run `git log --oneline base..HEAD` and `git blame` on changed files. Flag: reverted changes, contradictory commits, partial refactors |
| 4 | **Cross-commit** | Inconsistent naming across commits, partial migrations, orphaned imports, incomplete renames |
| 5 | **Security** | Hardcoded secrets, injection, auth bypass, error messages leaking internals, unsafe dependencies |

**Agent prompt template** (adapt per lens):
```
Review this PR diff for [LENS]. The diff is from base..HEAD.

## Diff
[paste git diff base..HEAD output, max ~4000 tokens]

## Project Guidelines
[paste relevant CLAUDE.md sections if they exist]

For each issue found, output JSON:
{"file": "path", "line": N, "severity": "CRITICAL|HIGH|MEDIUM|LOW", "confidence": 0-100, "description": "...", "suggestion": "..."}

Rules:
- Only report issues in CHANGED code, not pre-existing
- Confidence 0-100: 0=guess, 50=plausible, 80=likely real, 100=certain
- Do NOT report issues already caught by linters/type checkers
- Maximum 5 issues per agent
```

### Step 3: Score and Filter

After all 5 agents return:

1. **Collect** all findings into one list
2. **Deduplicate** — same file + same line + similar description = keep highest confidence
3. **Filter** — only surface findings with confidence ≥ 80
4. **Classify**:
   - CRITICAL/HIGH at 80+ confidence → **FAIL** (do not write marker)
   - MEDIUM/LOW at 80+ confidence → **advisory** (show but don't block)
   - Below 80 confidence → **suppress** (don't show)

### Step 4: Gate Decision

| Result | Action |
|--------|--------|
| Codex CLI PASS + no CRITICAL/HIGH at 80+ | Write marker (see below) → gate passes |
| Codex CLI PASS + CRITICAL/HIGH at 80+ | Report findings. Fix, then re-run Step 2 only |
| Codex CLI FAIL | Fix, re-run from Step 1 |

**Write the marker** (the script does NOT write it in PR mode — you must):
```bash
mkdir -p .claude && echo "PASS pr-review $(git rev-parse --short HEAD) $(date +%s)" > .claude/pr-review-passed.local
```

### Degraded States

Wait for all agents. Only apply quorum AFTER agents have timed out (10 min), never while they're still running.

| Failure | Handling |
|---------|----------|
| Agent times out (>10 min) | Mark as timed-out. Proceed with returned results only after ALL agents are either returned or timed-out |
| ≥3 agents returned | **3-of-5 quorum** — valid review. Evaluate findings from returned agents |
| <3 agents returned | `inconclusive` — fail-closed, do not write marker |
| All agents timeout | Fail-closed. Fall back to codex CLI result only (degrade to fast mode) |
| Codex CLI unavailable | Multi-agent review only (skip Step 1). Marker still written if deep review passes |

### Marker Encoding

PR markers include diff hash for staleness detection:
```
PASS pr-review <short-sha-of-HEAD> <timestamp>
```
The pre-PR gate verifies the marker's SHA matches current HEAD. Stale markers from prior reviews are rejected.

**Environment variables:**
- `CODEX_REVIEW_MODE=pr` — switches to PR deep review mode
- `CODEX_PR_BASE=main` — override base branch (defaults to `origin/HEAD` or `main`)
- `CODEX_PR_FAST=1` — skip multi-agent review, use fast mode only (audited in bypass-log)

## Key Principles

1. **Review before commit** - No exceptions
2. **Silent auto-continue** - Fix and re-review without talking to user
3. **Max iterations safety** - Stop at 10, ask user
4. **Blocking execution** - Run with timeout=1860000, NEVER use background
5. **Structured output** - Parse JSON for status and issues
6. **Test after pass** - Run test suite before committing
7. **Split large commits** - If >800 weighted lines (override: `CODEX_MAX_WEIGHTED_LINES`), split into logical commits FIRST. PR mode skips size check.
8. **Staged-only scope** - Reviews only `git diff --cached`, not unstaged/untracked files
9. **Iteration memory** - Previous findings are injected into the next pass to prevent re-reporting
10. **Convergence cap** - Max 3 new issues per iteration to ensure the loop converges

## Convergence System

The review loop uses three mechanisms to ensure convergence:

**Scope control:** The prompt includes the staged diff (`git diff --cached`) explicitly, so the LLM reviews exactly what will be committed — not unstaged work or untracked files.

**Iteration history:** After each FAIL, the issues found are saved to `/tmp/codex-iteration-history.jsonl`. On the next iteration, this history is injected into the prompt so the LLM knows what was already reported and can focus on verifying fixes.

**Convergence rules in prompt:**
- Do NOT re-report fixed issues from previous iterations
- Only report NEW issues not seen in any previous iteration
- Maximum 3 new issues per iteration
- If all previous issues are fixed and no new issues found, return PASS

History is cleared on PASS or on `init-review-loop.sh` (fresh start).

## Additional Resources

Load these references as needed:

- **`references/workflow-details.md`** - Detailed iteration examples, automation patterns
- **`references/advanced-features.md`** - Changelog system, completion promises, Ralph Loop details
- **`references/script-reference.md`** - Complete script documentation and integration patterns
- **`references/legacy-approach.md`** - Manual counter method (backward compatibility)
- **`references/troubleshooting.md`** - Common issues and solutions
- **`references/examples.md`** - Violation examples and best practices
- **`references/advanced-usage.md`** - CI/CD integration, custom prompts, multi-repo workflows

**When to load:**
- **workflow-details.md:** Need to understand iteration flow
- **advanced-features.md:** Using changelog or completion promises
- **script-reference.md:** Custom integrations or automation
- **troubleshooting.md:** Encountering errors or unexpected behavior

---

**Remember:** This is a BLOCKING requirement. Code cannot be committed, pushed, or deployed without passing review.
