# PR Review Mode (Deep — Multi-Voice)

> Loaded on demand by `litmus/SKILL.md` when the pre-PR gate blocks `gh pr create`. Not needed on the common commit path. The shared env-var configuration stays in `SKILL.md`.

When the pre-PR gate blocks `gh pr create`, run the full deep review. This combines the codex CLI pass with a 6-agent multi-voice review for cross-commit depth.

## Fast Path (CLI-only, no agents)

Only when the user explicitly asks to skip the deep review:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts/run-review-loop.sh" --auto-pr-review
```
This runs CLI review only and writes the marker on PASS. **Does NOT dispatch the 6-agent review.**

## Step 0.5: Smart Detection — Check Pre-Commit Coverage

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

## Step 1: Codex CLI Pass (fast)

**Skip this step if Step 0.5 detected agents-only mode.**

```bash
# Initialize and run in PR mode
LITMUS_MODE=pr bash "${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts/init-review-loop.sh"
LITMUS_MODE=pr bash "${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts/run-review-loop.sh"
```

If FAIL → fix and re-run (same auto-continue loop as commit mode).

## Step 1.5: Scope Drift Detection (Advisory)

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
```text
## Scope Drift Check (advisory)

### Unplanned changes
- `path/to/file.ts` — not referenced in plan (explain or trim)

### Missing from plan
- Task 3 (auth middleware) — `src/middleware/auth.ts` not in diff

### Verdict: [CLEAN | DRIFT DETECTED]
```

**Important:** This is "explain or trim" framing, not "you violated scope." Legitimate opportunistic fixes are fine. The value is surfacing the gap so the developer can consciously decide, not punishing agility.

## Step 2: Multi-Agent Deep Review

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

**Pass the listed `model` parameter to each Agent dispatch.** High-weight agents (Bugs, Security, Cross-commit) need Opus reasoning for kill-switch reliability; lower-weight agents (Guidelines, History, Docs) are pattern-matching tasks where Sonnet is the cost/quality sweet spot. Without explicit `model:` on the Agent call, dispatches inherit the parent's model (typically Opus) and inflate cost ~3×.

| Agent | Lens | Model | Focus |
|-------|------|-------|-------|
| 1 | **Guidelines** | sonnet | CLAUDE.md compliance, project conventions, naming consistency |
| 2 | **Bugs** | opus | Logic errors, off-by-one, null/undefined, race conditions (changes only, not full codebase) |
| 3 | **History** | sonnet | Run `git log --oneline base..HEAD` and `git blame` on changed files. Flag: reverted changes, contradictory commits, partial refactors |
| 4 | **Cross-commit** | opus | Inconsistent naming across commits, partial migrations, orphaned imports, incomplete renames |
| 5 | **Security** | opus | Hardcoded secrets, injection, auth bypass, error messages leaking internals, unsafe dependencies |
| 6 | **Docs-consistency** | sonnet | README, SKILL.md, docs/ accuracy vs changed code. Flag: stale examples, wrong function signatures, missing new features |

**Agent prompt template** (adapt per lens, set `model:` per the table above):
```text
model: [MODEL]  # e.g. opus / sonnet — per the dispatch table above
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

## Step 3: Score and Filter

After all 6 agents return:

1. **Collect** all findings into one list
2. **Deduplicate** — same file + same line + similar description = keep highest confidence
3. **Filter** — only surface findings with confidence ≥ 80
4. **Classify**:
   - CRITICAL/HIGH at 80+ confidence → **FAIL** (do not write marker)
   - MEDIUM/LOW at 80+ confidence → **advisory** (show but don't block)
   - Below 80 confidence → **suppress** (don't show)

## Step 3.5: Weighted Quorum (Agent Availability)

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

## Step 4: Gate Decision

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

## Degraded States

Wait for all agents. Only evaluate quorum AFTER agents have timed out (10 min), never while they're still running.

| Failure | Handling |
|---------|----------|
| Agent times out (>10 min) | Mark as timed-out (weight contribution = 0). Proceed with returned results only after ALL agents are either returned or timed-out |
| Weighted score ≥ 7 AND Bugs + Security both returned | **Valid review.** Evaluate findings from returned agents (apply Step 3 classification) |
| Weighted score < 7 | `inconclusive` — fail-closed, do not write marker |
| Bugs or Security agent timed-out/errored | `inconclusive` — fail-closed regardless of score (hard requirement) |
| All agents timeout | Fail-closed. Fall back to codex CLI result only (degrade to fast mode) |
| Codex CLI unavailable | Multi-agent review only (skip Step 1). Marker still written if deep review passes weighted quorum |

## Marker Encoding

PR markers contain a SHA-256 hash of the `base...HEAD` diff for staleness detection:
```text
<64-hex-char-sha256-hash>
```
The pre-PR gate accepts markers that are 64-hex SHA-256 hashes or `PASS-<epoch>` timestamps. It rejects `DEGRADED`, `SKIPPED-NONE`, and `BUILTIN-` prefixed markers.
