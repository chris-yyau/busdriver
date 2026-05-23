---
name: writing-plans
description: Use when you have a spec or requirements for a multi-step task, before touching code
---

# Writing Plans

## Overview

Write comprehensive implementation plans assuming the engineer has zero context for our codebase and questionable taste. Document everything they need to know: which files to touch for each task, code, testing, docs they might need to check, how to test it. Give them the whole plan as bite-sized tasks. DRY. YAGNI. TDD. Frequent commits.

Assume they are a skilled developer, but know almost nothing about our toolset or problem domain. Assume they don't know good test design very well.

**Announce at start:** "I'm using the writing-plans skill to create the implementation plan."

**Context:** This should be run in a dedicated worktree (created by brainstorming skill).

**Save plans to:** `docs/plans/YYYY-MM-DD-<feature-name>.md`
- (User preferences for plan location override this default)

## Scope Check

If the spec covers multiple independent subsystems, it should have been broken into sub-project specs during brainstorming. If it wasn't, suggest breaking this into separate plans — one per subsystem. Each plan should produce working, testable software on its own.

## File Structure

Before defining tasks, map out which files will be created or modified and what each one is responsible for. This is where decomposition decisions get locked in.

- Design units with clear boundaries and well-defined interfaces. Each file should have one clear responsibility.
- You reason best about code you can hold in context at once, and your edits are more reliable when files are focused. Prefer smaller, focused files over large ones that do too much.
- Files that change together should live together. Split by responsibility, not by technical layer.
- In existing codebases, follow established patterns. If the codebase uses large files, don't unilaterally restructure - but if a file you're modifying has grown unwieldy, including a split in the plan is reasonable.

This structure informs the task decomposition. Each task should produce self-contained changes that make sense independently.

## Bite-Sized Task Granularity

**Each step is one action (2-5 minutes):**
- "Write the failing test" - step
- "Run it to make sure it fails" - step
- "Implement the minimal code to make the test pass" - step
- "Run the tests and make sure they pass" - step
- "Commit" - step

## Plan Document Header

**Every plan MUST start with this header:**

```markdown
# [Feature Name] Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use busdriver:subagent-driven-development (recommended) or busdriver:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** [One sentence describing what this builds]

**Architecture:** [2-3 sentences about approach]

**Tech Stack:** [Key technologies/libraries]

---
```

## Task Structure

````markdown
### Task N: [Component Name]

**Files:**
- Create: `exact/path/to/file.py`
- Modify: `exact/path/to/existing.py:123-145`
- Test: `tests/exact/path/to/test.py`

- [ ] **Step 1: Write the failing test**

```python
def test_specific_behavior():
    result = function(input)
    assert result == expected
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/path/test.py::test_name -v`
Expected: FAIL with "function not defined"

- [ ] **Step 3: Write minimal implementation**

```python
def function(input):
    return expected
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/path/test.py::test_name -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add tests/path/test.py src/path/file.py
git commit -m "feat: add specific feature"
```
````

## No Placeholders

Every step must contain the actual content an engineer needs. These are **plan failures** — never write them:
- "TBD", "TODO", "implement later", "fill in details"
- "Add appropriate error handling" / "add validation" / "handle edge cases"
- "Write tests for the above" (without actual test code)
- "Similar to Task N" (repeat the code — the engineer may be reading tasks out of order)
- Steps that describe what to do without showing how (code blocks required for code steps)
- References to types, functions, or methods not defined in any task

## Remember
- Exact file paths always
- Complete code in every step — if a step changes code, show the code
- Exact commands with expected output
- DRY, YAGNI, TDD, frequent commits

## Plan Sanity Check

After writing the complete plan, look at the spec with fresh eyes and check the plan against it. This is a quick inline checklist you run yourself — not a subagent dispatch, and NOT a substitute for blueprint-review.

**1. Spec coverage:** Skim each section/requirement in the spec. Can you point to a task that implements it? List any gaps.

**2. Placeholder scan:** Search your plan for red flags — any of the patterns from the "No Placeholders" section above. Fix them.

**3. Type consistency:** Do the types, method signatures, and property names you used in later tasks match what you defined in earlier tasks? A function called `clearLayers()` in Task 3 but `clearFullLayers()` in Task 7 is a bug.

If you find issues, fix them inline. No need to re-review — just fix and move on. If you find a spec requirement with no task, add the task.

## Codex Handoff Eligibility

After sanity check passes, evaluate whether this plan should hand off to codex instead of running implementation in this CC session. The goal is token savings — codex does the implementation work, Claude does only spec-emit + final review. Three outcomes:

| Plan shape | Outcome | Emits |
|---|---|---|
| Small + verifier-shaped + bounded (≤8 iters' worth of work) AND result must return to CC | **In-CC handover** via `busdriver:codex-goal-handover` | `.claude/codex-goal-<slug>.json.local` |
| Verifier-shaped but too large (>8 iters, hours-long, or plan markdown >~3KB) OR result need not return to CC | **TUI handoff** — user pastes `/goal` invocation into codex TUI | `.claude/codex-goal-<slug>.md.local` + chat instructions |
| Not verifier-shaped (judgment-heavy, ambiguous verifiers, needs Claude's eyes per step) | **No action** — continue to default executor | Nothing |

**Eligibility criteria — ALL must hold for either handoff:**
1. **Substantive task** — not a one-line edit; meaningful scope to delegate
2. **Clean verifier commands** — pass/fail expressible as shell commands (tests, lint, typecheck) at plan level
3. **Claude doesn't need to read code between steps** — the loop is verifier-led, not Claude-judged
4. **Scope is bounded** — does not require Claude's intermediate judgment
5. **Result returns to CC for follow-up** — distinguishes Outcome 1 (in-CC, codex finishes and Claude reviews) from Outcome 2 (TUI handoff, user takes over entirely). If the work is fire-and-forget overnight, route to Outcome 2 regardless of size.

If ANY of criteria 1–4 fails → Outcome 3 (default executor). When in doubt, prefer Outcome 3 — codex-goal's hard cap is 8 iters, and a marginal-fit plan wastes the cost savings.

**Size decision (handover vs TUI):** Estimate iter count as ≈ one logical commit per task. Rough rubric:
- ≤8 tasks of 1–2 file changes each → Outcome 1 (in-CC handover)
- >8 tasks, OR any task clearly multi-hour, OR plan markdown >~3KB → Outcome 2 (TUI handoff)

This is judgment, not pattern matching — give it 30 seconds of thought, don't algorithmify it.

### Outcome 1: Emit in-CC handover spec

Write `.claude/codex-goal-<plan-slug>.json.local` (the `.local` suffix is mandatory — it matches the `.claude/*.local` gitignore rule and prevents the spec from being committed by accident) matching the shape in `busdriver:codex-goal-handover` → "Inputs: the spec":

```json
{
  "objective": "<one sentence from plan Goal>",
  "scope": {
    "include": ["<globs derived from Files: sections>"],
    "exclude": []
  },
  "constraints": [
    "<plan-level constraints — TDD, no new deps, preserve API, etc.>"
  ],
  "verifiable_end_state": {
    "description": "<plan's done-when condition>",
    "verifiers": [
      { "name": "tests", "cmd": "<project test command>" },
      { "name": "lint",  "cmd": "<project lint command>" },
      { "name": "typecheck", "cmd": "<typecheck if applicable>" }
    ]
  },
  "max_iters": 5
}
```

**`max_iters` derivation (the `5` above is a placeholder — compute the actual value):** estimate one iter per task in the plan, add 1 buffer, clamp to 8. A 3-task plan emits `max_iters: 4`; a 7-task plan emits `max_iters: 8`. The default of 5 (in codex-goal-handover/SKILL.md) is appropriate only for plans of ~4 tasks — hardcoding it for any plan size starves larger plans. JSON does not support comments, so the emitter must substitute a real integer in `[1, 8]` before writing the file (codex-goal-handover validates with `jq -e`).

**Slug derivation:** strip plan name to `[A-Za-z0-9._-]` before substitution (matches the `v_safe` pattern in codex-goal-handover Step 6) — guards against path-traversal slugs like `../../etc/passwd` if plan titles ever come from less-trusted sources.

Then in Auto-Execution below, **skip the default Execute step** — orchestrator Phase 4 routes to `busdriver:codex-goal-handover` based on the spec file's presence. Cleanup: codex-goal-handover should delete the spec file at end of execution to prevent stale-spec mis-routing on the next plan.

### Outcome 2: Emit TUI handoff materials and halt

Write `.claude/codex-goal-<plan-slug>.md.local` containing the full plan spec rewritten in codex-goal terms (objective, scope, verifiers, constraints, max_iters — same JSON shape, embedded in markdown for human readability). Then **halt auto-execution** and print to chat:

```
Plan exceeds codex-goal-handover bounds (>8 iters / hours-long).
Open a separate terminal, run `codex`, then paste:

  Follow the instructions in .claude/codex-goal-<slug>.md.local.

  Hard scope: edit only paths in scope.include. Stop after all verifiers green.
  Report total commits, tests passing, and any blockers.

This stays under the 4000-character `/goal` input limit and runs entirely outside Claude Code (zero CC tokens). Resume this session when codex finishes or hits a blocker.
```

The halt is intentional — it overrides the default "auto-run Phases 3–6" because TUI handoff means the user is taking over execution outside CC.

## Auto-Execution

<EXTREMELY-IMPORTANT>
The sanity check above is NOT the design review. You MUST still invoke `busdriver:blueprint-review` below.
Do NOT skip blueprint-review because the sanity check found no issues — they serve completely different purposes:
- Sanity check = you checking your own work for obvious errors (30 seconds)
- Blueprint-review = 3 independent external reviewers (Agy + Codex + Claude arbiter) validating the design (minutes)
</EXTREMELY-IMPORTANT>

After saving the plan and sanity check passes, proceed automatically through the remaining pipeline phases. Do NOT pause to ask the user which execution mode to use — execute immediately.

**Announce:** "Plan complete and saved to `<path>`. Auto-executing: design review → worktree → implementation."

**Sequence:**

1. **Design Review** — INVOKE `busdriver:blueprint-review` to review and approve the plan document. The design review gate (hook-enforced) blocks all implementation code until this passes. If design review rejects, fix issues and re-submit — do not proceed until it passes.
2. **Worktree Setup** — INVOKE `busdriver:using-git-worktrees` to create an isolated workspace. If worktree creation fails or baseline tests fail, stop and report.
3. **Execute** — If Codex Handoff Eligibility emitted `.claude/codex-goal-<slug>.json.local` (Outcome 1), INVOKE `busdriver:codex-goal-handover` with that spec instead. Otherwise INVOKE `busdriver:subagent-driven-development` for independent tasks, or `busdriver:executing-plans` for dependent tasks requiring sequential execution with review checkpoints. (Outcome 2 already halted auto-execution before reaching this step.)
4. **Verify** — INVOKE `busdriver:verification-loop` (build + lint + tests), then `busdriver:verification-before-completion` to confirm no claims without evidence.
5. **Finish** — `busdriver:finishing-a-development-branch` presents integration options (merge/PR/keep/discard).

**Stop conditions — halt auto-execution and report to user when:**
- Design review rejects the plan after 3 fix attempts
- Worktree baseline tests fail
- A task blocker requires human input (missing dependency, unclear requirement)
- Verification fails after implementation
- **Codex Handoff Outcome 2 (TUI handoff)** — by design; user takes over in codex TUI

**Override:** If the user explicitly asks to choose execution mode or pause between phases, respect that. Auto-execution is the default, not a mandate.
