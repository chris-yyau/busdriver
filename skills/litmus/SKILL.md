---
name: litmus
description: >
  Use before git commits, deployments, or PR creation. Trigger when about to:
  commit code, push changes, deploy to production, create pull requests, or
  finalize any code changes. Required before all code deployment actions.
---

# Litmus

<EXTREMELY-IMPORTANT>
YOU MUST RUN THE LITMUS REVIEW LOOP BEFORE EVERY COMMIT. NO EXCEPTIONS.

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
1. Run `run-review-loop.sh` as a BLOCKING bash call (timeout=1260000)
2. Wait for the result — NEVER run in background
3. If FAIL: fix issues silently, re-run — do NOT ask user between iterations
4. If PASS: proceed to tests and commit
5. NEVER use `--no-verify` or skip hooks to bypass review
</EXTREMELY-IMPORTANT>

## Purpose

Enforce automated code quality gates before committing or deploying code. Review code for bugs, security issues, performance problems, and maintainability using OpenAI Codex CLI.

## Review Protocol

This skill uses the official **codex-plugin-cc** app-server protocol when installed (preferred), falling back to direct `codex exec` CLI invocation. The app-server protocol communicates via JSON-RPC, avoiding the stdin piping issues that cause CLI hangs.

**Complementary commands** (from the official codex plugin — use directly, not through this skill):
- `/codex:adversarial-review` — Steerable challenge review targeting design choices and risk areas
- `/codex:rescue` — Delegate investigation/fix tasks to Codex in background
- `/codex:review` — On-demand read-only Codex review (outside the gate pipeline)
- `/codex:status`, `/codex:result`, `/codex:cancel` — Manage background Codex jobs

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

**All of these mean: STOP. Run litmus review. No exceptions.**

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
LITMUS_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts"
```

**2. Initialize:** `bash $LITMUS_SCRIPTS/init-review-loop.sh`
   (Defaults to 10 max iterations)

**3. Run Review (BLOCKING - wait for result):**
```bash
# Run as BLOCKING call - just wait for the result
Bash(
    command='bash "${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts/run-review-loop.sh"',
    timeout=1260000  # 21 min timeout (inner codex review timeout is 20 min)
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

1. Run review (BLOCKING, 21 min timeout) → get result
2. If PASS → done, proceed to tests & commit
3. If FAIL → **silently** fix issues, stage, re-run step 1
4. If TOO LARGE (exit 2) or TIMEOUT (exit 124) → auto-split (see below)
5. Repeat until PASS or max iterations (10)

**CRITICAL RULES:**
- **NO background tasks** - run blocking, wait for result
- **NO polling/sleep loops** - just use timeout=1260000
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
   b. `bash $LITMUS_SCRIPTS/init-review-loop.sh`
   c. `bash $LITMUS_SCRIPTS/run-review-loop.sh` (review loop for this group)
   d. Fix issues if FAIL, re-run until PASS
   e. `git commit -m '<descriptive message for this group>'`
5. Repeat until all files are committed

**Why auto-split:**
- Each commit is logically coherent (not "batch 1 of 3")
- Smaller diffs = faster reviews that complete within timeout
- Better git history with meaningful commit messages
- Prevents crashes from oversized prompts

**Thresholds (commit mode only — PR mode skips size check):** Weighted lines use additions at 1x + deletions at 0.25x (deleted code needs minimal review). Triggers: >800 weighted lines (>2000 for single-file) OR >2000 total raw lines OR >8 staged files. Override with `LITMUS_MAX_WEIGHTED_LINES` and `LITMUS_MAX_STAGED_FILES` env vars.

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

**State persists in:** `.claude/litmus-state.md`

## Example: Silent Auto-Continue

```
Claude: "Running litmus review for commit 1 (database schema)..."
[Runs 3 iterations silently - user sees nothing]
Claude: "✅ Litmus review PASSED after 3 iterations. Committing..."
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
    command='bash "${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts/run-review-loop.sh"',
    timeout=1260000  # 21 min timeout (inner codex review timeout is 20 min)
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
LITMUS_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts"
bash $LITMUS_SCRIPTS/init-review-loop.sh 10
bash $LITMUS_SCRIPTS/run-review-loop.sh
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
LITMUS="${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts"
bash $CODEX/init-review-loop.sh 10                                  # Initialize
bash $CODEX/run-review-loop.sh                                      # Review (auto-loops)
# Fix if FAIL, run again until PASS
npm test                                                            # Tests
git commit -m "Message"                                             # Commit
```

## PR Review Mode (Deep — Multi-Voice)

When the pre-PR gate blocks `gh pr create`, run the full deep review. This combines the codex CLI pass with a 6-agent multi-voice review for cross-commit depth.

### Fast Path (CLI-only, no agents)

Only when the user explicitly asks to skip the deep review:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts/run-review-loop.sh" --auto-pr-review
```
This runs CLI review only and writes the marker on PASS. **Does NOT dispatch the 6-agent review.**

### Step 0.5: Smart Detection — Check Pre-Commit Coverage

Before running the codex CLI pass, check if all commits were already pre-commit reviewed:

```bash
# Check for agents-only signal (written by pre-pr-gate when all commits were pre-reviewed)
# Signal is branch-scoped ("agents-only:<branch>") to prevent cross-branch contamination
CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
if [ -f ".claude/pr-commits-prereviewed.local" ] && \
   grep -qxF "agents-only:${CURRENT_BRANCH}" ".claude/pr-commits-prereviewed.local" 2>/dev/null; then
  echo "✅ All commits pre-commit reviewed — skipping codex CLI pass, agents-only mode."
  rm -f ".claude/pr-commits-prereviewed.local"
  # SKIP Step 1 entirely → go straight to Step 1.5 (scope drift) and Step 2 (agents)
fi
```

**Why skip codex CLI but keep agents:** Codex CLI reviews individual diffs — the same thing it already did per-commit. The 6 agents review the *full PR diff* for cross-commit issues (inconsistent naming, partial migrations, orphaned imports, security across files, docs drift). These are different types of review with unique value.

| Already done per-commit | Unique to PR agents |
|---|---|
| Single-diff bug detection | Cross-commit consistency |
| Per-file code quality | Naming/migration completeness |
| Syntax/style issues | Security across file boundaries |
| | Docs vs code drift |

### Step 1: Codex CLI Pass (fast)

**Skip this step if Step 0.5 detected agents-only mode.**

```bash
# Initialize and run in PR mode
LITMUS_MODE=pr bash "${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts/init-review-loop.sh"
LITMUS_MODE=pr bash "${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts/run-review-loop.sh"
```

If FAIL → fix and re-run (same auto-continue loop as commit mode).

### Step 1.5: Scope Drift Detection (Advisory)

Before launching the expensive multi-agent review, check whether the branch stayed aligned with its stated intent. This is **advisory only** — it flags deviations but never blocks.

**Step 1.5a: Find the plan.** Use Glob to search for intent documents: `docs/superpowers/plans/*.md`, `docs/superpowers/specs/*.md`, `docs/plans/*.md`, and top-level `PLAN.md`/`DESIGN.md`/`ARCHITECTURE.md`. Skim each candidate to find the one most relevant to this branch (matching branch name, feature description, or commit subject). If no intent document exists or none is clearly relevant, skip scope drift detection silently.

**Step 1.5b: Gather intent and changes.** Read the matched plan file. Also read `TODOS.md` (if it exists), commit messages, and PR description. Gather the actual diff by computing the merge-base explicitly:
```bash
PR_BASE=${LITMUS_PR_BASE:-}
[ -z "$PR_BASE" ] && PR_BASE=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/||')
[ -z "$PR_BASE" ] && PR_BASE=origin/main
# Auto-prefix origin/ if bare branch name provided
[[ -n "${LITMUS_PR_BASE:-}" && "$PR_BASE" != origin/* ]] && PR_BASE="origin/${PR_BASE}"
MERGE_BASE=$(git merge-base "${PR_BASE}" HEAD)
git log --oneline "${MERGE_BASE}..HEAD"
git diff "${MERGE_BASE}..HEAD" --stat
gh pr view --json body -q .body 2>/dev/null || true
```

**Step 1.5c: Compare and flag two categories:**

**1. Scope creep** — files changed that are unrelated to the plan:
- For each changed file, check if it (or its parent directory) is mentioned anywhere in the plan
- Exempt: `.claude/`, `CLAUDE.md`, `docs/`, config files, and test files accompanying planned changes
- Frame as: "These files were changed but aren't mentioned in the plan: [list]. Intentional?"

**2. Missing requirements** — plan items with no corresponding changes:
- Read the intent document and extract all file paths mentioned (in task sections, file listings, code blocks, or inline references)
- Check which of those file paths appear in the diff
- Frame as: "These planned files have no matching changes in the diff: [list]. Deferred or forgotten?"

**Output format:**
```
## Scope Drift Check (advisory)

### Unplanned changes
- `path/to/file.ts` — not referenced in plan (explain or trim)

### Missing from plan
- Task 3 (auth middleware) — `src/middleware/auth.ts` not in diff

### Verdict: [CLEAN | DRIFT DETECTED]
```

**Important:** This is "explain or trim" framing, not "you violated scope." Legitimate opportunistic fixes are fine. The value is surfacing the gap so the developer can consciously decide, not punishing agility.

### Step 2: Multi-Agent Deep Review

<EXTREMELY-IMPORTANT>
YOU MUST WAIT FOR ALL 6 AGENTS TO RETURN BEFORE PROCEEDING TO STEP 3.

DO NOT:
- Write the PR marker after only some agents complete
- Rationalize "I have enough results" with partial returns
- Create the PR while agents are still running
- Use early agent results to decide "no blocking issues" before all return

If an agent is slow, WAIT. If it times out after 10 minutes, mark it as timed-out and proceed with the remaining results. But never proceed while agents are still "running" or "in progress".
</EXTREMELY-IMPORTANT>

After codex CLI passes, dispatch **6 parallel review agents** using the Agent tool. Each reviews the full `base..HEAD` diff from a different lens. Launch all 6 in a **single message** for concurrency.

| Agent | Lens | Focus |
|-------|------|-------|
| 1 | **Guidelines** | CLAUDE.md compliance, project conventions, naming consistency |
| 2 | **Bugs** | Logic errors, off-by-one, null/undefined, race conditions (changes only, not full codebase) |
| 3 | **History** | Run `git log --oneline base..HEAD` and `git blame` on changed files. Flag: reverted changes, contradictory commits, partial refactors |
| 4 | **Cross-commit** | Inconsistent naming across commits, partial migrations, orphaned imports, incomplete renames |
| 5 | **Security** | Hardcoded secrets, injection, auth bypass, error messages leaking internals, unsafe dependencies |
| 6 | **Docs-consistency** | README, SKILL.md, docs/ accuracy vs changed code. Flag: stale examples, wrong function signatures, missing new features |

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

**Agent 6 (Docs-consistency) additional instructions:**
```text
Also review documentation files (.md) in the diff. For each changed code file:
1. Search for README.md, docs/, and SKILL.md files that reference the changed code
2. Flag mismatches: wrong function names, stale examples, missing documentation for new features
3. Check if removed functions are still documented
4. Verify code examples in docs match the actual implementation
```

### Step 3: Score and Filter

After all 6 agents return:

1. **Collect** all findings into one list
2. **Deduplicate** — same file + same line + similar description = keep highest confidence
3. **Filter** — only surface findings with confidence ≥ 80
4. **Classify**:
   - CRITICAL/HIGH at 80+ confidence → **FAIL** (do not write marker)
   - MEDIUM/LOW at 80+ confidence → **advisory** (show but don't block)
   - Below 80 confidence → **suppress** (don't show)

### Step 3.5: Weighted Quorum (Agent Availability)

Not all agents are equally load-bearing. The pass/fail decision uses weighted scoring rather than a flat 4-of-6 count, so that availability hiccups in low-weight agents (Docs, History) don't block merge when the high-weight agents (Bugs, Security) returned clean.

**Agent weights (total 12 points):**

| Agent | Weight | Rationale |
|-------|--------|-----------|
| Agent 2 — **Bugs** | 3 | Direct correctness risk |
| Agent 5 — **Security** | 3 | Direct exploit/exposure risk |
| Agent 1 — Guidelines | 2 | Convention/consistency |
| Agent 4 — Cross-commit | 2 | Partial-migration risk |
| Agent 3 — History | 1 | Mostly retrospective signal |
| Agent 6 — Docs | 1 | Docs drift, rarely blocking |

**Pass rules (BOTH must hold):**

1. **Score threshold:** returned-agent weight sum ≥ **7** (of 12). Timed-out or errored agents contribute 0.
2. **Hard requirement:** neither Agent 2 (Bugs) nor Agent 5 (Security) is timed-out or errored. If either is missing, the review is inconclusive regardless of total score.

**Why score + hard requirement:** The weight lets Docs+History timeouts (2 pts missing) still pass if all 4 higher-weight agents returned. The hard requirement prevents "10 out of 12 points with Security down" from being treated as a pass — Security gaps are categorically different from Docs gaps.

**Calibration note:** If you observe weight drift (e.g., Docs catching real bugs consistently, or Bugs producing noise), adjust weights based on observed signal quality. Default weights reflect general-purpose code; healthcare/finance workloads should lift Security to 4 and lower Guidelines.

### Step 4: Gate Decision

| Result | Action |
|--------|--------|
| Codex CLI PASS + no CRITICAL/HIGH at 80+ | Write marker (see below) → gate passes |
| Codex CLI PASS + CRITICAL/HIGH at 80+ | Report findings. Fix, then re-run Step 2 only |
| Codex CLI FAIL | Fix, re-run from Step 1 |

**Write the marker** (the script does NOT write it in PR mode — you must call the trusted marker writer):
```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts/run-review-loop.sh" --write-pr-marker
```
This computes the diff hash and writes `.claude/pr-review-passed.local`. Direct writes to marker files are blocked by the PreToolUse hook — only `run-review-loop.sh` can write them.

The marker must be a SHA-256 hash (64 hex chars) or a timestamped pass (`PASS-<epoch>`). The gate rejects `DEGRADED`, `SKIPPED-NONE`, and `BUILTIN-` prefixed markers for PR review.

### Degraded States

Wait for all agents. Only evaluate quorum AFTER agents have timed out (10 min), never while they're still running.

| Failure | Handling |
|---------|----------|
| Agent times out (>10 min) | Mark as timed-out (weight contribution = 0). Proceed with returned results only after ALL agents are either returned or timed-out |
| Weighted score ≥ 7 AND Bugs + Security both returned | **Valid review.** Evaluate findings from returned agents (apply Step 3 classification) |
| Weighted score < 7 | `inconclusive` — fail-closed, do not write marker |
| Bugs or Security agent timed-out/errored | `inconclusive` — fail-closed regardless of score (hard requirement) |
| All agents timeout | Fail-closed. Fall back to codex CLI result only (degrade to fast mode) |
| Codex CLI unavailable | Multi-agent review only (skip Step 1). Marker still written if deep review passes weighted quorum |

### Marker Encoding

PR markers contain a SHA-256 hash of the `base...HEAD` diff for staleness detection:
```
<64-hex-char-sha256-hash>
```
The pre-PR gate accepts markers that are 64-hex SHA-256 hashes or `PASS-<epoch>` timestamps. It rejects `DEGRADED`, `SKIPPED-NONE`, and `BUILTIN-` prefixed markers.

**Environment variables:**
- `BUSDRIVER_REVIEW_CLI=auto` — choose review backend (auto/codex/gemini/droid/amp/opencode/claude/aider/builtin/none). Per-role routing: `.claude/busdriver.json`
- `LITMUS_MODE=pr` — switches to PR deep review mode
- `LITMUS_PR_BASE=main` — override base branch (auto-prefixed to `origin/<branch>` if no `origin/` prefix; defaults to `origin/HEAD` or `origin/main`)
- `LITMUS_PR_FAST=1` — skip multi-agent review, use fast mode only (audited in bypass-log)

## Builtin Fallback (Exit Code 3)

When `run-review-loop.sh` exits with code 3, no external review CLI is available and the builtin fallback was triggered. Handle as follows:

1. Read the prompt path from `.claude/builtin-review-prompt-path.local`
2. Read the review prompt from that path
3. Dispatch the `code-reviewer` agent via the Agent tool with the prompt as context. **The agent prompt MUST include:**
   - **Read-only mode:** "Do NOT modify any files. Report only. Do not use the Fix-First pass. Do not use Write or Edit tools."
   - **JSON output format:** "Output your review as a JSON array of issues: `[{\"severity\": \"CRITICAL|HIGH|MEDIUM|LOW\", \"file\": \"path\", \"line\": 0, \"description\": \"...\"}]`. If no issues found, output: `[]`"
4. Parse the agent's JSON output for CRITICAL/HIGH/MEDIUM issues
5. If no blocking issues: write the marker via `bash "${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts/write-review-marker.sh"` (NOT via Write tool — the pre-implementation gate blocks Write to marker files)
6. If CRITICAL/HIGH/MEDIUM issues: report FAIL with issues, fix and re-run
7. Clean up: remove the temp prompt file and the handoff path file

## Enhanced Review Features

### Short-Circuit Gate (Commit Mode Only)

Small, low-risk commits can skip the Codex CLI review when ALL conditions hold:

- Weighted diff lines < `LITMUS_SHORTCIRCUIT_MAX_LINES` (default **10**)
- SAST findings = 0 (gitleaks, semgrep, shellcheck, trufflehog all clean)
- Markdown findings = 0
- No changed files match the sensitive-path pattern (workflows, secrets, crypto material, lockfiles, env files, IaC)

When all conditions pass, litmus emits `⚡ Short-circuit PASS`, logs the event to `.claude/review-metrics.jsonl` + `.claude/bypass-log.jsonl` (as a distinct `short-circuit-pass` event, NOT a bypass), writes the commit marker, and exits 0 without dispatching Codex.

**Fail-closed:** Any condition failing falls through to normal review.

**Sensitive-path pattern** (hardcoded baseline, extensible):
- `.github/`, `.env*`, `Dockerfile*`, `docker-compose*`
- `*.key`, `*.pem`, `*.p12`
- Lockfiles: `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `Cargo.lock`, `go.sum`, `uv.lock`, `Pipfile.lock`, `Gemfile.lock`, `composer.lock`
- `*.tf`, `migrations/`, `secrets/`

**Environment variables:**
- `LITMUS_SHORTCIRCUIT_DISABLED=1` — disable short-circuit entirely, always run Codex
- `LITMUS_SHORTCIRCUIT_MAX_LINES=10` — weighted-lines threshold (override for tighter/looser gate)
- `LITMUS_SHORTCIRCUIT_EXTRA_SENSITIVE=<regex>` — append project-specific sensitive paths (e.g., `auth/|db/|billing/`)

**When to tighten:** If you see false short-circuits on important small changes, lower the threshold to 5 or add paths to the sensitive pattern. **When to disable:** Compliance environments where every commit must have LLM review regardless of size.

### SAST Integration (Deterministic)

The review loop automatically runs available static analysis tools before the LLM review:

| Tool | What it catches | Install |
|------|----------------|---------|
| **Semgrep** | Security vulnerabilities, code patterns | `pip install semgrep` |
| **ShellCheck** | Shell script bugs, quoting issues | `brew install shellcheck` |
| **TruffleHog** | Leaked secrets and credentials | `brew install trufflehog` |

SAST findings are deterministic (not LLM-generated) and merge with LLM findings in the final output. Missing tools are skipped gracefully.

**Environment variables:**
- `LITMUS_SKIP_SAST=1` — skip all SAST scanning
- `LITMUS_SAST_TIMEOUT=30` — per-tool timeout in seconds (default: 30)
- `LITMUS_SHELLCHECK_ENABLE=check-extra-masked-returns,check-set-e-suppressed,quote-safe-variables,require-double-brackets` — ShellCheck optional checks to enable (default: curated list targeting audit gaps). Set to `all` to enable everything, or narrow to specific checks

### Smart Context (Cross-File)

The review loop automatically collects cross-file context:
- Extracts function names from changed hunks
- Finds callers of changed functions across the repo
- Traces importers of changed files
- Injects this context into the review prompt

This enables the LLM to catch broken contracts, renamed parameters, and cross-file bugs.

**Environment variables:**
- `LITMUS_SKIP_CONTEXT=1` — skip smart context collection
- `LITMUS_MAX_CONTEXT_LINES=50` — max context lines per function (validated numeric)
- `LITMUS_MAX_FUNCTIONS=10` — max functions to trace (validated numeric)

### Docs Consistency

The review loop checks for doc/code mismatches:
- Finds README/docs files that reference changed code
- Injects relevant doc snippets into the review prompt
- LLM flags stale docs, wrong examples, missing documentation
- PR deep review includes a dedicated docs-consistency agent (6th agent)

**Environment variables:**
- `LITMUS_DOCS_CONTEXT=1` — enable docs context collection (default: off)
- `LITMUS_MAX_DOC_SNIPPETS=5` — max doc file snippets to include (validated numeric)
- `LITMUS_MAX_ENRICHMENT_LINES=100` — max lines of smart-context and docs-context injected into prompt (validated numeric)

### Metrics Persistence

Every litmus review automatically logs its outcome to `.claude/review-metrics.jsonl`:

- Status (PASS/FAIL), issue count, severity breakdown (`high`/`medium`/`low`)
- Iteration number, review CLI used, review mode (commit/pr)
- Commit SHA, branch name, diff size

**Report dashboard:** `bash scripts/litmus-metrics-report.sh`

```bash
# View recent reviews
bash scripts/litmus-metrics-report.sh --recent 10

# Full dashboard (pass rate, severity distribution, avg iterations)
bash scripts/litmus-metrics-report.sh

# Raw JSONL data
bash scripts/litmus-metrics-report.sh --raw
```

**Environment variables:**
- `LITMUS_METRICS_FILE=path` — override metrics file location (default: `.claude/review-metrics.jsonl`)

### Markdown Validation

When `.md` files are staged, the review loop runs:
- **markdownlint** (if installed) — lint violations
- **URL validation** (opt-in) — broken links

**Environment variables:**
- `LITMUS_SKIP_MARKDOWN=1` — skip markdown checks
- `LITMUS_CHECK_URLS=1` — enable URL validation (disabled by default — slow)

## User-Created Skip File

When the user wants to bypass litmus review (e.g., upstream-only syncs with no custom code), they create `.claude/skip-litmus.local` manually in their terminal. The pre-commit and pre-PR gates both honor this skip file and enforce a **30-second timing heuristic** that rejects skip files created "moments ago" to prevent Claude from self-bypassing. Gate-specific behavior on rejection: `pre-commit-gate.sh` preserves the file and tells the user to wait the remaining seconds; `pre-pr-gate.sh` deletes the file on rejection (requiring re-touch).

**How the gates behave on every commit / PR-create attempt while litmus is unpassed:**
1. If `.claude/skip-litmus.local` exists and is **<30s old** → gate blocks as likely self-bypass. `pre-commit-gate.sh` preserves the file; `pre-pr-gate.sh` deletes it.
2. If the file exists and is **≥30s old** → gate consumes the file (single-use) and allows the action through.
3. If no file → gate blocks with the normal "litmus must pass" message.

### Verbatim message template (required)

When Claude needs a skip file, it must emit this exact message, with `<PROJECT_ROOT>` replaced by the absolute path of the current git repo root (from `git rev-parse --show-toplevel` — not the CWD of the Claude session, which may be a subdirectory):

> I need a skip file to bypass the litmus gate. Please run this in **your terminal** (not in this session):
>
> ```
> touch <PROJECT_ROOT>/.claude/skip-litmus.local
> ```
>
> After you run it, I will wait ~35 seconds before retrying the blocked commit / PR creation. Please reply "done" once you've run the command. Do not expect an immediate response from me — the wait is required by the gate and is not a stall.

Do not give the relative path (`.claude/skip-litmus.local`) — the gate checks `.claude/` relative to the **blocked command's CWD**, which may differ from the user's terminal CWD, and users routinely run `touch` from a different pane.

### After the user confirms ("done")

Wait ~35 seconds, then retry the originally blocked action (git commit or gh pr create) directly. Do not verify the skip file with `test -f` / `ls` / `stat` first — trust the user's "done" confirmation and let the retry run the gate.

```
Monitor(command: "sleep 35 && echo READY", timeout: 45)
# When Monitor emits READY (or completes), retry:
#   git commit -m "..."         # for pre-commit gate
#   gh pr create --title "..."  # for pre-PR gate
```

`Monitor`'s subprocess sleeps atomically and does not re-enter the PreToolUse hook. A direct `sleep 32` via Bash is blocked by the harness (long foreground sleeps are rejected by the shell-command gate).

### Hard rules

- **NEVER create the skip file yourself** — the gate will detect self-bypass and log an audit event.
- **NEVER verify the skip file via Bash** (`test -f`, `ls`, `stat`, `cat`, `find`). Any tool call that reaches the gate while the file is <30s old consumes it. Trust the user's "done" confirmation.
- **NEVER ask the user to wait** — Claude does the wait via `Monitor`.
- **Use `Monitor(command: "sleep 35 && echo READY")`**, not `sleep 32` directly.
- **Single-use** — the skip file is consumed after one successful bypass. Subsequent commits/PRs need a new `touch`.
- **Audit trail** — every consumption is logged to `.claude/bypass-log.jsonl`.
- **On rejection (<30s):** `pre-commit-gate.sh` preserves the file — wait the remainder of the 30s and retry. `pre-pr-gate.sh` deletes the file — ask the user to `touch` again and wait another 35s.

## Key Principles

1. **Review before commit** - No exceptions
2. **Silent auto-continue** - Fix and re-review without talking to user
3. **Max iterations safety** - Stop at 10, ask user
4. **Blocking execution** - Run with timeout=1260000, NEVER use background
5. **Structured output** - Parse JSON for status and issues
6. **Test after pass** - Run test suite before committing
7. **Split large commits** - If >800 weighted lines (override: `LITMUS_MAX_WEIGHTED_LINES`), split into logical commits FIRST. PR mode skips size check.
8. **Staged-only scope** - Reviews only `git diff --cached`, not unstaged/untracked files
9. **Iteration memory** - Previous findings are injected into the next pass to prevent re-reporting
10. **Convergence cap** - Max 3 new issues per iteration to ensure the loop converges
11. **Shell-aware review** - Prompt includes targeted checklists for shell scripting (portability, CWD safety, cleanup ordering, timeout fail-open, boolean normalization) and documentation accuracy (factual claims cross-referenced against code), added based on empirical coverage audit (19% baseline vs paid tools)

## Convergence System

The review loop uses three mechanisms to ensure convergence:

**Scope control:** The prompt includes the staged diff (`git diff --cached`) explicitly, so the LLM reviews exactly what will be committed — not unstaged work or untracked files.

**Iteration history:** After each FAIL, the issues found are saved to `/tmp/litmus-iteration-history.jsonl`. On the next iteration, this history is injected into the prompt so the LLM knows what was already reported and can focus on verifying fixes.

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
- **`references/legacy-approach.md`** - Legacy counter method (deprecated — use state-based approach)
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
