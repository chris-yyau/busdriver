---
name: blueprint-review
description: >
  Use after writing implementation plans, architecture documents, or design specs,
  before implementation begins. Required for validating strategic and technical soundness.
  Trigger on "design review", "review plan", "review design", "blueprint review",
  "design-reviewer", or when design docs are flagged by the PostToolUse hook.
---

# Blueprint Review (Three-Tier, Claude Arbiter)

AI-powered design review using Gemini + Codex (parallel) with Claude as the arbiter.

<EXTREMELY-IMPORTANT>
YOU MUST WAIT FOR ALL THREE REVIEWERS BEFORE MARKING PASS.

This is the rule Claude violated on class-roll (2026-03-10): Claude did its own validation, decided PASS with "only low-severity items," and stamped `<!-- design-reviewed: PASS -->` while Gemini and Codex were still running in background. This is NEVER acceptable.

DO NOT rationalize skipping reviewers. These thoughts are violations:
- "Claude validation already PASSED with low-severity items"
- "Gemini and Codex are still running, I'll build consensus with what we have"
- "The Claude review is most authoritative since it has codebase context"
- "Two out of three passed, that's probably good enough"
- "I can do my own review instead of waiting for the script"

EVERY design review MUST:
1. Run `run-design-review-loop.sh` as a BLOCKING bash call
2. Wait for ALL THREE reviewer outputs (gemini.json, codex.json, claude.json)
3. Claude validates Gemini/Codex findings against the codebase
4. Mark PASS ONLY when Claude's verdict has no HIGH/MEDIUM issues (confidence >= 0.5)
</EXTREMELY-IMPORTANT>

## Overview

Three-tier model with Claude as arbiter:
1. **Gemini + Codex**: Run in parallel as independent comprehensive reviewers
2. **Claude**: Validates their findings against the codebase (arbiter)
3. **Claude's verdict**: The sole convergence signal

**Key features:**
- Parallel execution (Gemini + Codex run simultaneously)
- Run-scoped artifact isolation (stale outputs cleaned per iteration)
- Hard freshness contract (run_id + spec_hash in every output)
- Atomic writes (.pending → rename on success)
- Explicit progress model (severity breakdown, not binary FAIL/PASS)

## When to Use

**Use for:**
- Implementation plans (PLAN.md, roadmaps, feature specs)
- Architecture documents (system designs, API specs, data models)
- Major refactoring plans or structural decisions

**Don't use for:**
- Code review (use litmus instead)
- Documentation review (not technical decisions)
- Already-implemented features (too late)

## Quick Reference

| Component | Focus | Typical Time |
|-----------|-------|--------------|
| Reviewer 1 | Comprehensive (all aspects) | 1-5min |
| Reviewer 2 | Comprehensive (all aspects) | 1-5min |
| Reviewer 1 + 2 | Parallel execution | 1-5min (wall clock) |
| Claude | Arbiter + codebase validation | 2-5min |

**Completion criteria:** Claude's verdict has no HIGH or MEDIUM severity issues with confidence >= 0.5

**Escape hatch:** If the review loop does not converge, the user can create `.claude/skip-design-review.local` in their terminal to bypass the gate (single-use, 30s self-bypass detection — see orchestrator SKILL.md for protocol).

## Configuration

Reviewer CLIs are configurable via `.claude/busdriver.json` using the `routes` object:

```json
{
  "routes": {
    "blueprint-review.reviewer_1": ["gemini"],
    "blueprint-review.reviewer_2": ["codex"]
  }
}
```

| Role | Route key | Default |
|------|-----------|---------|
| Reviewer 1 | `blueprint-review.reviewer_1` | gemini |
| Reviewer 2 | `blueprint-review.reviewer_2` | codex |
| Arbiter | (hardcoded) | claude (not configurable — Claude is always the arbiter) |

If both reviewers resolve to the same CLI, the system runs single-reviewer mode (one execution, output copied to both paths, logged as degradation).

See `.claude/busdriver.json` for per-role routing configuration.

## Workflow

```dot
digraph review {
    rankdir=TB;
    node [shape=box, style=rounded];

    init [label="1. Initialize\nbash init-design-review.sh"];
    parallel [label="2. Gemini + Codex\n(parallel)"];
    claude [label="3. Claude Arbiter\n(codebase context)"];
    progress [label="4. Progress Analysis\n(severity breakdown)"];
    converged [label="No HIGH/MEDIUM?" shape=diamond];
    done [label="Design Approved" shape=doublecircle style=filled fillcolor=lightgreen];
    fix [label="5. Fix Issues"];
    iterate [label="6. Next Iteration"];

    init -> parallel;
    parallel -> claude;
    claude -> progress;
    progress -> converged;
    converged -> done [label="yes"];
    converged -> fix [label="no"];
    fix -> iterate;
    iterate -> parallel;
}
```

### 1. Initialize Review

```bash
cd /path/to/project
# CLAUDE_PLUGIN_ROOT is set by the plugin loader at session start
bash "${CLAUDE_PLUGIN_ROOT}/skills/blueprint-review/scripts/init-design-review.sh" docs/plans/PLAN.md
```

**Creates state file** (`docs/reviews/<slug>/state.md`) tracking:
- Current iteration (1-5)
- Review statuses (Gemini, Codex, Claude)
- Progress model (high/medium/low issue counts)

### 2. Run Review Loop

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/blueprint-review/scripts/run-design-review-loop.sh"
```

**Automated workflow:**
1. **Clean stale artifacts** from previous iteration
2. **Run Gemini + Codex in parallel** (background processes, `wait` for both)
3. **Validate outputs** (JSON integrity + freshness contract)
4. **Claude validation** with codebase access (manual step or pre-existing output)
5. **Progress analysis** (severity breakdown from Claude's verdict)
6. **Convergence check** (no HIGH/MEDIUM with confidence >= 0.5 → PASS)

### 3. Address Issues & Iterate

Update your design document based on Claude's findings, then re-run:

```bash
# Edit design file
vim docs/plans/PLAN.md

# Run next iteration
bash "${CLAUDE_PLUGIN_ROOT}/skills/blueprint-review/scripts/run-design-review-loop.sh"
```

**Iteration continues until:**
- Claude's verdict has no HIGH/MEDIUM issues (confidence >= 0.5)
- OR max iterations reached (default: 5)

## Architecture: Claude as Arbiter

### Why Not Mechanical Consensus?

The original system used Jaccard keyword similarity to match issues across reviewers.
It achieved **0% match rate** across 5 iterations because reviewers use different naming conventions.
Claude's manual cross-referencing was doing all the real consensus work.

**New model:** Claude IS the consensus mechanism. Gemini and Codex provide independent perspectives;
Claude validates them against the codebase and renders a verdict.

### Freshness Contract

Every reviewer output includes metadata for provenance tracking:

```json
{
  "metadata": {
    "run_id": "a1b2c3d4",
    "iteration": 2,
    "spec_hash": "sha256-of-design-file",
    "review_duration_ms": 120000
  }
}
```

The script validates that all outputs share the same `run_id` before proceeding.
Stale outputs from previous runs are rejected (fail-closed).

### Progress Model

Replaces binary FAIL/PASS with explicit severity breakdown:

| Status | Meaning | Action |
|--------|---------|--------|
| `blocked_by_high_issues` | HIGH severity issues remain | Must fix before proceeding |
| `medium_issues_remaining` | MEDIUM severity issues remain | Should fix before proceeding |
| `low_issues_only` | Only LOW severity issues | PASS — proceed to implementation |
| `passed` | No issues | PASS — proceed to implementation |

Progress is visible across iterations: "iteration 1: 6 high → iteration 2: 2 high → iteration 3: 0 high, 1 medium"

## Claude Validation

**Claude's unique role as arbiter:**

- Full codebase context (can read existing code)
- Validates Gemini/Codex claims against reality
- Identifies gaps in their coverage
- Renders the final verdict

**Validation types:**
- `confirms_gemini`: Agrees with Gemini finding
- `confirms_codex`: Agrees with Codex finding
- `new_finding`: Found issue they missed
- `contradicts_gemini`: Disagrees with Gemini
- `contradicts_codex`: Disagrees with Codex

## Output Format

**Review JSON schema:**

```json
{
  "status": "PASS"|"FAIL",
  "reviewer_id": "gemini|codex|claude",
  "review_duration_ms": 0,
  "issues": [
    {
      "section": "Section name or line reference",
      "severity": "high|medium|low",
      "confidence": 0.0-1.0,
      "category": "clarity|completeness|architecture|...",
      "description": "Clear, specific description",
      "suggestion": "Actionable fix",
      "reviewer": "gemini|codex|claude"
    }
  ],
  "metadata": {
    "run_id": "a1b2c3d4",
    "iteration": 1,
    "spec_hash": "sha256...",
    "total_sections_reviewed": 0,
    "review_timestamp": "ISO-8601",
    "codebase_files_examined": []
  }
}
```

**Status rules:**
- `FAIL`: Any high/medium severity with confidence >= 0.5
- `PASS`: Only low severity OR low confidence (<0.5) issues

## Error Handling

Reviewer outputs MUST be validated before Claude arbitration. Malformed or error JSON treated as implicit PASS is a critical bypass.

**Validation rules:**
1. Each reviewer JSON MUST contain a `"status"` field with value `"PASS"` or `"FAIL"`
2. Each reviewer JSON MUST contain a `"reviewer_id"` field
3. If a reviewer JSON contains an `"error"` key, treat as `"status": "FAIL"`
4. If a reviewer JSON fails to parse, treat as `"status": "FAIL"`
5. If a reviewer file is missing after timeout, treat as `"status": "FAIL"` — never skip
6. If `run_id` doesn't match current run, treat as stale — reject (fail-closed)

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Show partial results before all reviews complete | Wait for all three outputs, then proceed |
| Skip Claude validation | Claude is the arbiter — skipping it removes the convergence signal |
| Trust external reviews blindly | Claude validates claims against the codebase |
| Ignore iteration limits | Max 5 iterations prevents infinite loops |
| Accept error JSON as valid review | Validate `status` field; `error` key → synthetic FAIL |
| Read stale outputs from previous run | Script cleans artifacts at iteration start + validates run_id |

## Troubleshooting

**Issue: Gemini or Codex CLI not found**

```bash
which gemini
which codex
```

If not installed, the workflow uses error fallback. Install CLIs for full review coverage.

**Issue: Claude validation is slow**

Claude needs codebase access for validation. In auto mode, the calling skill must complete Claude validation before the script checks for output.

**Issue: Iteration loop doesn't converge**

- Check progress in state file: `cat docs/reviews/<slug>/state.md`
- Look at severity breakdown: is it improving? (6 high → 2 high → 0 high)
- If stuck, break design into smaller pieces
- Max iterations (default: 5) prevents infinite loops

**Issue: Stale output detected**

The script validates `run_id` on every output. If you see "STALE OUTPUT DETECTED", a file from a previous run was not cleaned up. The script handles this automatically by replacing with an error JSON.

## State Files

Each design file gets its own review directory: `docs/reviews/<slug>/`

Active review tracked by pointer file: `.claude/current-design-review.local`

- `docs/reviews/<slug>/state.md` - YAML frontmatter tracking iteration + progress
- `docs/reviews/<slug>/gemini.json` - Gemini review output (with freshness metadata)
- `docs/reviews/<slug>/codex.json` - Codex review output (with freshness metadata)
- `docs/reviews/<slug>/claude.json` - Claude arbiter output (with freshness metadata)
- `docs/reviews/<slug>/claude-validation-prompt.txt` - Generated prompt for Claude

**Clean up after completion:**

```bash
rm -rf docs/reviews/<slug>/
```

## Confidence Scoring Guidelines

| Range | Meaning | Criteria |
|-------|---------|----------|
| 0.9-1.0 | Certain | Clear violation with cited evidence |
| 0.7-0.9 | Very likely | Strong evidence but some ambiguity |
| 0.5-0.7 | Probable | Moderate evidence, could be design choice |
| 0.3-0.5 | Uncertain | Weak evidence, needs clarification |
| 0.0-0.3 | Speculative | No strong evidence, just a concern |

### Display Rules

When presenting findings to the user, filter by confidence tier:

| Confidence | Display |
|------------|---------|
| 0.7 to 1.0 | Show normally in main report |
| 0.5 to <0.7 | Show with caveat: "*Medium confidence — verify this is actually an issue*" |
| 0.3 to <0.5 | Suppress from main report. Include in appendix section: "Low-confidence findings (may be false positives)" |
| 0.0 to <0.3 | Suppress entirely unless severity is `high` |

**Important:** Low-confidence findings are suppressed from the user-facing report only. They remain in the JSON artifacts (`gemini.json`, `codex.json`, `claude.json`) for auditability. Never delete findings from stored outputs.

### Calibration-to-Instinct Bridge

When the user confirms a low-confidence finding (0.3-0.5) was a real issue, this is a calibration event — the reviewer's initial confidence was too low. Log the corrected pattern so future reviews catch it with higher confidence:

Write to `~/.claude/notes/lesson-review-cal-{YYYY-MM-DD}-{slug}.md`. If the path already exists, append `-2`, `-3`, etc. to the slug before writing, and use the same suffixed filename in the NOTES.md pointer below.

```markdown
---
name: review-cal-{actual-slug}
description: Blueprint review underconfident on {pattern} — was {original_confidence}, should be {corrected_confidence}
type: feedback
last_validated: "{YYYY-MM-DD}"
---

**Pattern:** {what the finding was about}
**Original confidence:** {0.X} | **Correct confidence:** {0.X+0.2 or higher}
**Why underconfident:** {why the reviewer didn't see stronger evidence}
**How to apply:** When reviewing {similar patterns}, start at confidence {corrected} instead of {original}
```

After writing the file, add a one-line pointer to `~/.claude/notes/NOTES.md` using the actual filename written (including any `-2`, `-3` suffix):
```
- [Review calibration: {slug}](./lesson-review-cal-{YYYY-MM-DD}-{actual-slug}.md) — {pattern} confidence corrected {old} → {new}
```

**Solicitation:** When the design review report includes an appendix of low-confidence findings, end the report with: "**Calibration check:** Were any of the appendix findings above actually real issues? If so, I'll log the corrected confidence for future reviews."

This bridges design review findings into the instinct/lesson system, compounding review quality over time.

## User-Created Skip File

When the user wants to bypass design review (e.g., plan already validated out-of-band, or the review is blocking legitimate exploration), they create `.claude/skip-design-review.local` manually in their terminal. The skip file is consumed by the **pre-implementation gate only** (it does not bypass the pre-commit or pre-PR gates). The gate has a **30-second timing heuristic** that rejects and deletes skip files created "moments ago" to prevent Claude from self-bypassing.

**How the skip-file check behaves on every tool call the gate sees while design review is pending:**
1. If `.claude/skip-design-review.local` exists and is **<30s old** → gate deletes it and blocks (treated as self-bypass).
2. If the file exists and is **≥30s old** → gate deletes it (single-use) and allows the blocked action through.
3. If no file → gate falls through to its normal allow/block rules (Write/Edit of implementation code → block; file-modifying Bash → block; SAFE tool uses → allow).

Critically, the skip-file check in steps 1–2 runs **before** tool-type discrimination — so any tool call that reaches the gate while a skip file exists will consume it, even ostensibly "harmless" Bash like `test -f`, `ls`, or `stat` on the skip file itself. Verification counts. Polling counts. If Claude fires any tool call during the <30s window, the file is destroyed and must be re-created.

### Verbatim message template (required)

When Claude needs a skip file, it must emit this exact message, with `<PROJECT_ROOT>` replaced by the absolute path of the current git repo root (from `git rev-parse --show-toplevel` — not the CWD of the Claude session, which may be a subdirectory):

> I need a skip file to bypass the design-review gate. Please run this in **your terminal** (not in this session):
>
> ```
> touch <PROJECT_ROOT>/.claude/skip-design-review.local
> ```
>
> After you run it, I will wait ~35 seconds before retrying the blocked action. Please reply "done" once you've run the command. Do not expect an immediate response from me — the wait is required by the gate and is not a stall.

Do not give the relative path (`.claude/skip-design-review.local`) — the gate checks `.claude/` relative to the **blocked command's CWD**, which may differ from the user's terminal CWD, and users routinely run `touch` from a different pane.

### After the user confirms ("done")

Wait ~35 seconds without executing any tool that touches the filesystem, then retry the originally blocked action directly.

```
Monitor(command: "sleep 35 && echo READY", timeout: 45)
# When Monitor emits READY (or completes), retry the blocked Edit/Write/Bash.
# Do NOT verify the skip file first — the verification itself consumes it.
```

`Monitor`'s subprocess sleeps atomically and does not re-enter the PreToolUse hook, so the skip file survives the wait. A direct `sleep 35` via Bash is blocked by the harness (long foreground sleeps are rejected), and polling loops that call `stat`/`test`/`ls` will destroy the file.

### Hard rules

- **NEVER create the skip file yourself** — the gate will detect self-bypass, delete the file, and log an audit event.
- **NEVER verify the skip file via Bash** (`test -f`, `ls`, `stat`, `cat`, `find`). Any tool call during the <30s window consumes the file. Trust the user's "done" confirmation.
- **NEVER ask the user to wait** — Claude does the wait via `Monitor`.
- **Use `Monitor(command: "sleep 35 && echo READY")`**, not `sleep 32` directly.
- **Single-use** — the skip file is consumed after one bypass. If more writes are needed, the user must `touch` it again and Claude must wait another 35s.
- **Audit trail** — every consumption is logged to `.claude/bypass-log.jsonl`.
- **If the file gets rejected-and-deleted** (e.g., Claude fat-fingered a tool call during the window), ask the user to `touch` it again and start the wait over.

## Version History

**v3 (current, 2026-03-27):** Claude-as-arbiter model. Parallel Gemini+Codex. Run-scoped isolation. Freshness contracts. Atomic writes. Explicit progress model. Deleted broken Jaccard consensus, auto-fix engine, and report generator.

**v2:** Three-tier with Jaccard consensus + auto-fix. Achieved 0% consensus match rate. Claude's manual cross-referencing did all real work.

**v1:** Gemini (strategic) + Codex (technical) with manual triage.
