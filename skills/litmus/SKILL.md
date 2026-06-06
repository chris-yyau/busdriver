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

This skill uses the official **codex-plugin-cc** app-server protocol when installed (preferred), falling back to direct `codex exec` CLI invocation. The app-server protocol communicates via JSON-RPC. The prompt is passed via `--prompt-file <tempfile>` rather than stdin, avoiding an EAGAIN race in the companion's `fs.readFileSync(0, ...)` when fd 0 has `O_NONBLOCK` set under Claude Code's Bash tool (the retry+backoff machinery cannot clear the fd flag, so retries on this specific failure are wasted; --prompt-file reads via path and is unaffected). When codex exhausts retries on transient errors (rate-limit, network, 5xx), the review escalates to `droid exec` (default read-only mode) before falling back to the builtin Claude agent — see `LITMUS_CODEX_DROID_FALLBACK_DISABLED` below.

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
- **Max iterations (10)** → see "Auto-Escalation on Logical Failure" — dispatch `/codex:rescue` once before surfacing to user
- **Only talk to user when:** PASS, setup_error, codex quota error, infra_failure (codex→droid→builtin chain exhausted OR JSON/schema/timeout fault), or post-rescue still failing

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
- **ONLY talk to user when:** PASS, setup_error, infra_failure (when the codex→droid→builtin chain itself has exhausted or returned infra_failure for JSON-extraction/schema/timeout reasons), or post-rescue still failing (see "Auto-Escalation on Logical Failure" — stall/max-iterations auto-dispatch the `codex:rescue` skill first)

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

## Terminal status (machine-readable, additive contract)

In addition to the exit-code contract, `run-review-loop.sh` writes a
`terminal_status` field to `.claude/litmus-state.md` immediately before
failure exits (`exit 1` and `exit 124`); `exit 2` (TOO_LARGE) does not set it. Values:

| terminal_status   | Meaning                                                       |
|-------------------|---------------------------------------------------------------|
| `review_findings` | Reviewer produced actionable issues (FAIL path)               |
| `stall`           | Same blocking issues two iterations in a row                  |
| `max_iterations`  | Inner iteration cap reached                                   |
| `infra_failure`   | CLI crash, JSON validation failure, timeout, stderr error    |
| `setup_error`     | Env validation / state-file load failed before main loop     |

Automated callers SHOULD prefer this field over stdout marker-matching.
Interactive `/litmus` users see no behavior change.

## Auto-Escalation on Logical Failure (codex-rescue)

When `terminal_status` indicates Claude could not converge — **not** when codex itself crashed — auto-dispatch `/codex:rescue` for a fresh diagnostic pass BEFORE surfacing to the user. This is distinct from the runtime `codex → droid → builtin` chain (which handles *transient* codex errors); this handles *logical* failure where review succeeded but Claude can't act on the findings.

| `terminal_status` | Auto-dispatch `/codex:rescue`? | Rationale |
|---|---|---|
| `stall` | **Yes — once** | Same blocking issues two iters in a row = Claude is stuck. Highest-ROI moment for a second opinion. |
| `max_iterations` | **Yes — once** | 10 iters burned. Rescue is cheaper than dropping back to the user. |
| `infra_failure` | No — surface to user | Codex itself failed (runtime escalation handles transient cases; an `infra_failure` reaching this point means the codex→droid→builtin chain exhausted OR a JSON-extraction/schema/timeout fault occurred — not a code problem rescue could fix). |
| `setup_error` | No — surface to user | Not a code problem. |
| `review_findings` (normal FAIL) | No — let the auto-continue loop fix it | Rescuing routine FAILs burns codex tokens on lint-tier work. |

**Protocol on `stall` / `max_iterations`:**

0. **Opt-out guard:** if `LITMUS_AUTO_RESCUE_DISABLED=1` is set in the environment, skip steps 1–4 entirely and surface directly to the user with the stall/max-iter result. Do not dispatch rescue.
1. Read the failing issues from `.claude/litmus-state.md` and the iteration history (`.claude/litmus-iteration-history.local.jsonl`)
2. Dispatch the `codex:codex-rescue` subagent via the **Agent tool** (NOT the `/codex:rescue` slash command — slash commands require user input; NOT `Skill(codex:rescue)` either — that re-enters the slash command and can hang). The codex plugin exposes rescue as an agent for programmatic dispatch. Pass: the issues, the staged diff (`git diff --cached`), and prior iteration history as context in the agent prompt.
3. Apply codex's recommended fix
4. Re-run `run-review-loop.sh` **exactly once** — confirm PASS or surface to user
5. **Hard cap: one rescue dispatch per litmus session.** No rescue-then-rescue loops. If the post-rescue run still fails, surface to user with both the original findings and codex's diagnosis. This is a within-session Claude instruction — no file marker is needed; Claude tracks whether it has already dispatched rescue in the current litmus session.

**Anti-patterns:**
- Auto-rescuing on every FAIL — defeats the cost-savings goal; the auto-continue loop already handles routine fixes cheaply
- Rescue-then-rescue chains — caps the cost ceiling at one rescue, no recursion
- Dispatching rescue when codex itself was the failure (`infra_failure`) — rescue can't fix infrastructure issues, and the codex→droid→builtin chain already handled the transient case before infra_failure was emitted

**Environment variables:**
- `LITMUS_AUTO_RESCUE_DISABLED=1` — opt out of the logical-failure escalation (e.g., when the user wants to see the stall/max-iter result directly without rescue overhead)

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

**Full PR deep-review procedure** — Fast Path, pre-commit-coverage detection (Step 0.5), codex CLI pass, scope-drift detection, the 6-agent multi-voice review, scoring + weighted quorum, gate decision, degraded states, and marker encoding: **Read `references/pr-review-mode.md`** when the pre-PR gate fires. It is not needed on the common commit path.

## Configuration (Environment Variables)

These govern both commit and PR review modes:
- `BUSDRIVER_REVIEW_CLI=auto` — choose review backend (auto/codex/agy/droid/builtin/none). Per-role routing: `.claude/busdriver.json`
- `LITMUS_MODE=pr` — switches to PR deep review mode
- `LITMUS_PR_BASE=main` — override base branch (auto-prefixed to `origin/<branch>` if no `origin/` prefix; defaults to `origin/HEAD` or `origin/main`)
- `LITMUS_PR_FAST=1` — skip multi-agent review, use fast mode only (audited in bypass-log)
- `LITMUS_CODEX_DROID_FALLBACK_DISABLED=1` — opt out of the runtime droid escalation. By default (unset or `0`), when codex exhausts retries on transient errors (rate-limit, network, 5xx), the review escalates to `droid exec` (default read-only mode — Create/Edit blocked) before falling back to the builtin Claude agent. The legacy name `LITMUS_CODEX_DROID_FALLBACK=0` is also honored. Escalations are logged to `.claude/bypass-log.jsonl` as `codex-droid-fallback` events. **Note:** this flag only governs the runtime fallback inside `_execute_codex`; install-time routes in `.claude/busdriver.json` control which CLIs are tried for a role, but do not by themselves suppress this runtime escalation once codex is running. Use `LITMUS_CODEX_DROID_FALLBACK_DISABLED=1` (or `BUSDRIVER_REVIEW_CLI=codex`) when codex-only runtime behavior is required.
- `LITMUS_CODEX_RETRIES=5` — maximum retry attempts before escalating to droid. Default: `5`. Backoff sequence at the default is 30, 60, 120, 240, 480 seconds (~15.5 min total). Raise for longer patience before escalation; lower for faster bail (e.g., `export LITMUS_CODEX_RETRIES=2`). The defaults were originally sized to absorb the EAGAIN failure mode observed under Claude Code's Bash tool; that root cause is now bypassed via `--prompt-file` (see Review Protocol above), so the budget is effectively reserved for genuine network / rate-limit / 5xx transients.
- `LITMUS_CODEX_RETRY_DELAY=30` — base retry delay in seconds; each retry doubles it (exponential backoff). Default: `30`. The resulting sequence at the default is 30, 60, 120, 240, 480 seconds. From retry 2 onward (t≥90s) the sequence clears OpenAI's per-minute window; by retry 4 (t≥450s) it clears the per-5min window. Lower for faster feedback in low-latency environments (e.g., `export LITMUS_CODEX_RETRY_DELAY=5`).
- `LITMUS_CODEX_HIGH_FROM=3` — attempt index at which codex switches from extended (`xhigh`) to high-reasoning mode. Default: `3` (zero-indexed, so attempts 0–2 use `xhigh`, attempts 3+ use `high`). Adjust to bias earlier or later toward high reasoning (e.g., `export LITMUS_CODEX_HIGH_FROM=1`).

## Builtin Fallback (Exit Code 3)

When `run-review-loop.sh` exits with code 3, external review paths were exhausted for this run — e.g., no CLI is available, codex failed (transient or non-transient), and any applicable droid escalation was disabled, unavailable, or also failed. Handle as follows:

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
- `LITMUS_MAX_CONTEXT_DIFF_BYTES=262144` — skip enrichment (extraction + caller/importer grep) when the diff exceeds this many bytes (default: 256 KiB). Guards against the regex extractor stalling on huge single-file data diffs (minified JSON, NDJSON, lockfiles)
- `LITMUS_MAX_CONTEXT_LINE_BYTES=4000` — skip enrichment when any diff line is longer than this (default: 4000; long minified/data lines trigger pathological regex backtracking)
- `LITMUS_CONTEXT_TIMEOUT=15` — per-operation timeout (s) for extraction and caller/importer grep; fails open to empty context (default: 15)

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

When the user wants to bypass litmus review (e.g., upstream-only syncs with no custom code), they create `.claude/skip-litmus.local` manually in their terminal.

**Litmus-specific behavior:**

| | Pre-commit | Pre-PR |
|---|---|---|
| Triggered by | `git commit` | `gh pr create` |
| On <30s rejection | gate **preserves** the file (still ages naturally — wait the remainder of 30s and retry) | gate **deletes** the file (user must `touch` again) |

Both gates use the same skip file (`.claude/skip-litmus.local`) and both enforce a 30-second timing heuristic against self-bypass.

**Full protocol** — verbatim message template (with `<GATE>` substitution), `Monitor`-based 35s wait pattern, and hard rules (NEVER create the skip file yourself, NEVER verify via Bash, etc.) — lives canonically in `skills/blueprint-review/SKILL.md` → "User-Created Skip File". The protocol is identical across all busdriver gates; only the per-gate variations in the table above differ.

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
