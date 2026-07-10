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

## Optional Ultra-Oracle Plan Advisory (opt-in)

Before locking in the decomposition below, an **advisory** cross-model consult can help Claude author a better plan. Claude writes the plan and can be wrong — this surfaces a second opinion on decomposition *before the draft exists*. It is deliberately distinct from blueprint-review, which *critiques the finished plan* at the gate: this **advises** (forward-looking, prevents mistakes), the gate **critiques** (backward-looking, catches them). Fires only if `ultraOracle.writingPlans.enabled` is true in the operator's **USER config** `~/.claude/busdriver.json` (a repo-controlled project config CANNOT enable it — this prevents a branch from transmitting the design to ChatGPT Pro without your local opt-in), OR the user used a trigger ("consult the oracle" / "ask the oracle"). Skipped silently otherwise.

**Mechanism — reuse brainstorming's Step 5.6 consult *plumbing*; do NOT re-implement it here.** Reuse its `scripts/ultra-oracle-consult-run.sh` wrapper, the Path A (explicit trigger) / Path B (config-gated) opt-in structure, the `oracle_status`/zsh handling, and the prompt-file cleanup trap — all defined and hardened there. **Do NOT adopt brainstorming's block-until-retry/skip/abort status branching:** this advisory is non-blocking (see "On result" below). Apply these deltas:

- **Surface / opt-in (two independent paths, mirroring brainstorming):** run when EITHER (Path B, config-driven) `ultraOracle.writingPlans.enabled: true` in your USER config `busdriver.json` (`~/.claude/busdriver.json` by default; the reader honors `$BUSDRIVER_STATE_DIR`) — a repo-controlled project config CANNOT enable it, preventing a branch from transmitting the design to ChatGPT Pro without your local opt-in — OR (Path A) the user gives an explicit "consult the oracle" trigger, which is itself the per-run opt-in and authorizes the run without the config gate. Absent both, skip silently and never transmit. On the config-driven Path B, a disabled/unresolvable/erroring config fails closed → skip (the explicit Path A trigger is unaffected by the config).
- **Timing:** run it HERE — before the File Structure / task decomposition below — on the approved design / requirements (there is no finished plan yet to critique).
- **Prompt (advisory, not a critique):** ask for forward-looking decomposition guidance — what task sequencing the dependencies imply, which single task is riskiest or hides a hard sub-problem, and what is easy to under-specify. Guidance to shape the plan, not a verdict on one.
- **Paths:** a plan-specific, session-unique prompt/out pair under `${BUSDRIVER_STATE_DIR:-.claude}/ultra-oracle/` (e.g. `plan-advisory-$$.*`) — session-unique so concurrent plan-writing runs never collide, and state-dir-aware so a custom `$BUSDRIVER_STATE_DIR` is honored (do not hardcode `.claude`).

**On result** (`$oracle_status`): `ok` → fold the guidance into the File Structure + task breakdown below (advisory — adopt what helps, note what you rejected; the oracle has no codebase tools, so its claims are UNVERIFIED until checked, and Claude still authors the plan). **Any other status** — `skipped:disabled`, `skipped:user`, `skipped:unavailable`, `error`, `timeout`, or empty — is **non-blocking**: draft the plan normally (add a one-line note if it failed rather than was skipped). This advisory NEVER pauses plan-writing; blueprint-review still critiques the finished plan at the gate. **Latency:** a ChatGPT Pro consult runs minutes — a deliberate blocking wait *when it runs* (full latency + data-boundary notes live in brainstorming Step 5.6).

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

**Global Constraints:** [Project-wide binding requirements EVERY task must honor — version floors, naming conventions, platform targets, "no new deps", API-compat/backward-compat rules. Listed ONCE here instead of repeated per task; every task and every task reviewer reads this block.]

---
```

## Task Structure

````markdown
### Task N: [Component Name]

**Files:**
- Create: `exact/path/to/file.py`
- Modify: `exact/path/to/existing.py:123-145`
- Test: `tests/exact/path/to/test.py`

**Interfaces:**
- Consumes: `[signatures/types this task depends on from earlier tasks — e.g. parseConfig(path: str) -> Config]`
- Produces: `[signatures/types this task exposes for later tasks — e.g. Config dataclass; loadUser(id: int) -> User]`

(Interfaces make cross-task dependencies explicit so a worker implementing Task N — possibly in a fresh subagent with no memory of Task 1 — knows the exact signatures it can rely on and must expose. Omit only for a single-task plan.)

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

After sanity check passes, evaluate whether this plan should hand off to codex instead of running implementation in this CC session. The goal is token savings — codex does the implementation work, Claude does only spec-emit + final review.

**Mandatory pre-flight (run FIRST, before deciding outcome):** delete `.claude/codex-goal-*.json.local` files older than 2 hours.

```bash
# Pre-flight: remove orphaned specs ONLY (mtime > 2h ago). macOS/BSD find compatible.
# Guard against .claude not existing yet (fresh worktree / new repo) — find would otherwise exit non-zero.
[ -d .claude ] && find .claude -maxdepth 1 -name 'codex-goal-*.json.local' -type f -mmin +120 -delete 2>/dev/null || true
```

This is a **best-effort** mitigation for orphaned specs from prior interrupted Step 3 executions. **Known limitations of the time-based filter (intentional tradeoff):**

- **Plans started within 2 hours of an interrupted Step 3** — the stale spec persists and can mis-route orchestrator Phase 4. User can manually clean with `rm -f .claude/codex-goal-*.json.local` between plans.
- **Handovers running longer than 2 hours** — the live spec could be deleted by another session's pre-flight mid-handover. In practice an 8-iter handover finishes in well under 2 hours; if you have a known long-running case, disable the pre-flight for that session.

Stronger guarantees (lockfile-based ownership, session-ID sentinels in the JSON, orchestrator-side content validation) are deferred — the residual window is narrow enough for solo-dev use and the additional complexity has its own failure modes. Document and accept; revisit if real stale-routing incidents occur.

Three outcomes for the eligibility decision:

| Plan shape | Outcome | Emits |
|---|---|---|
| Small + verifier-shaped + bounded (≤8 iters' worth of work) AND result must return to CC | **In-CC handover** via `busdriver:codex-goal-handover` | `.claude/codex-goal-<slug>.json.local` |
| Verifier-shaped but too large (>8 iters, hours-long, or plan markdown >~3KB) OR result need not return to CC | **TUI handoff** — user pastes `/goal` invocation into codex TUI | `.claude/codex-goal-<slug>.md.local` + chat instructions |
| Not verifier-shaped (judgment-heavy, ambiguous verifiers, needs Claude's eyes per step) | **No action** — continue to default executor | Nothing |

**Eligibility criteria — criteria 1–4 must ALL hold for any codex handoff; criterion 5 distinguishes Outcome 1 from Outcome 2:**
1. **Substantive task** — not a one-line edit; meaningful scope to delegate
2. **Clean verifier commands** — pass/fail expressible as shell commands (tests, lint, typecheck) at plan level
3. **Claude doesn't need to read code between steps** — the loop is verifier-led, not Claude-judged
4. **Scope is bounded** — does not require Claude's intermediate judgment
5. **Result returns to CC for follow-up** — if yes → Outcome 1 (in-CC, codex finishes and Claude reviews); if no (fire-and-forget overnight) → Outcome 2 (TUI handoff, user takes over entirely), regardless of size.

If ANY of criteria 1–4 fails → Outcome 3 (default executor). **When criteria 1–4 ALL hold, criterion 5 resolves to Outcome 1 (result returns to CC), the plan is within the size caps below, AND every verifier is a deterministic runnable command (tests/lint/typecheck — not prose acceptance criteria) AND the tasks are mechanical (1–2 file changes each, no cross-cutting design decisions), prefer Outcome 1** — that shape is exactly what codex-goal's verifier-led loop handles well within its 8-iter cap, and the cost savings are real. This preference does NOT override criterion 5 or the size decision below: a fire-and-forget plan (criterion 5 → Outcome 2) or a plan exceeding the size caps still routes to Outcome 2 regardless of how deterministic or mechanical its verifiers are. For everything else — genuine doubt, marginal fit, non-deterministic verifiers, or design-flavored tasks — prefer Outcome 3, since a marginal-fit plan wastes the cost savings against that 8-iter cap. Expansion trigger: relax the size caps below only once >80% of handoffs land green within 4 of the 8 iterations (operator tracks this informally).

**Size decision (handover vs TUI):** Estimate iter count as ≈ one logical commit per task. Rough rubric:
- ≤8 tasks of 1–2 file changes each → Outcome 1 (in-CC handover)
- >8 tasks, OR any task clearly multi-hour, OR plan markdown >~3KB → Outcome 2 (TUI handoff)

This is judgment, not pattern matching — give it 30 seconds of thought, don't algorithmify it.

### Outcome 1: Defer spec emission to Step 3 (in-CC handover)

When this outcome is selected, **note the decision in conversation context for use in Step 3 below** — do NOT emit the spec file here, and do NOT create any on-disk artifact. Spec emission happens in Step 3 of Auto-Execution — *after* Design Review and Worktree Setup. This ordering matters: if either earlier phase halts (Design Review rejects, baseline tests fail), no stale `.claude/codex-goal-<slug>.json.local` is left behind to mis-route orchestrator Phase 4 on a subsequent plan run.

In Step 3, when invoking `busdriver:codex-goal-handover`, write `.claude/codex-goal-<plan-slug>.json.local` (the `.local` suffix is mandatory — it matches the `.claude/*.local` gitignore rule and prevents the spec from being committed by accident) matching the shape in `busdriver:codex-goal-handover` → "Inputs: the spec":

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

**`max_iters` derivation (the `5` above is a placeholder — compute the actual value):** estimate one iter per task in the plan, add 1 buffer, clamp to `[5, 8]` — i.e. `max(5, tasks + 1)` capped at 8. A 1-task plan still emits `max_iters: 5` (codex-goal-handover's documented default); a 7-task plan emits `max_iters: 8`. Never undershoot the documented default — small plans can have unexpected iter spread, and the floor of 5 matches codex-goal-handover Hard rule 4. JSON does not support comments, so the emitter must substitute a real integer in `[5, 8]` before writing the file (codex-goal-handover validates with `jq -e`).

**Slug derivation:** compute the spec path ONCE as a **literal string**, and use that literal at the emit, invocation, and cleanup sites. Do NOT rely on shell variable persistence — Claude Code's Bash tool spawns a fresh shell per invocation, so a `SPEC_PATH=...` set in one Bash call does not survive to the next. Either chain emit + invoke-prep + cleanup in conversation memory (record the literal path string), or substitute the resolved literal into every command directly.

Sanitize the plan title to `[A-Za-z0-9_-]` (note: `.` is excluded — the codex-goal-handover Step 6 `v_safe` pattern allows `.` because verifier names benefit from dotted forms, but slugs do NOT, and allowing `.` lets `..` traversal sequences survive sanitization). Reject empty slugs after stripping.

Example one-shot derivation (run in a single Bash call to compute the literal path; record the *result* — not the variable — for use in subsequent Bash calls):
```bash
SLUG=$(printf '%s' "$PLAN_TITLE" | tr -cd 'A-Za-z0-9_-')
[ -n "$SLUG" ] || { echo "empty slug after sanitization — abort"; exit 1; }
printf 'SPEC_PATH=%s\n' ".claude/codex-goal-${SLUG}.json.local"
# Capture the printed literal — e.g., `.claude/codex-goal-refactor-auth.json.local`.
# Use the literal in every subsequent command, NOT a $SPEC_PATH reference across Bash calls.
```

The strict whitelist alone is sufficient — no runtime `realpath` validation needed (which would fail on macOS/BSD for not-yet-existing paths anyway).

Then in Auto-Execution below, **skip the default Execute step** — orchestrator Phase 4 routes to `busdriver:codex-goal-handover` based on the spec file's presence. **Cleanup is the caller's responsibility** (writing-plans Step 3 does the `rm -f`); the dispatcher does not currently auto-clean. The pre-flight at the top of this section handles the residual window where an interruption between emit and cleanup leaves a stale spec.

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
- Blueprint-review = 3 independent external reviewers (Agy + Codex + Grok) plus a fresh Claude subagent arbiter validating the design (minutes)
</EXTREMELY-IMPORTANT>

After saving the plan and sanity check passes, proceed automatically through the remaining pipeline phases. Do NOT pause to ask the user which execution mode to use — execute immediately.

**Announce:** "Plan complete and saved to `<path>`. Auto-executing: design review → worktree → implementation."

**Sequence:**

1. **Design Review** — INVOKE `busdriver:blueprint-review` to review and approve the plan document. The design review gate (hook-enforced) blocks all implementation code until this passes. If design review rejects, fix issues and re-submit — do not proceed until it passes.
2. **Worktree Setup** — INVOKE `busdriver:using-git-worktrees` to create an isolated workspace. If worktree creation fails or baseline tests fail, stop and report.
3. **Execute** — If Codex Handoff Eligibility selected Outcome 1: derive the literal spec path per the Slug derivation rule (record it in conversation context — e.g., `.claude/codex-goal-refactor-auth.json.local`), **emit the spec file at that literal path now** (deferred from the Eligibility step — see Outcome 1 for the JSON template), then INVOKE `busdriver:codex-goal-handover` with that literal path. **Cleanup on every exit path:** after handover returns (green, bailed, or max-iters) AND on any error path before reaching that point (handover throws, session interrupted), delete the spec by passing the literal path to `rm -f` (e.g., `rm -f .claude/codex-goal-refactor-auth.json.local`). Treat this as an always-runs finalizer — if you bail out of Step 3 for any reason, do the rm before reporting to the user. Do NOT rely on a `$SPEC_PATH` shell variable across Bash tool calls (each call spawns a fresh shell; the variable will be empty). Otherwise INVOKE `busdriver:subagent-driven-development` for independent tasks, or `busdriver:executing-plans` for dependent tasks requiring sequential execution with review checkpoints. (Outcome 2 already halted auto-execution before reaching this step.)
4. **Verify** — INVOKE `busdriver:verification-loop` (build + lint + tests), then `busdriver:verification-before-completion` to confirm no claims without evidence.
5. **Finish** — `busdriver:finishing-a-development-branch` presents integration options (merge/PR/keep/discard).

**Stop conditions — halt auto-execution and report to user when:**
- Design review rejects the plan after 3 fix attempts
- Worktree baseline tests fail
- A task blocker requires human input (missing dependency, unclear requirement)
- Verification fails after implementation
- **Codex Handoff Outcome 2 (TUI handoff)** — by design; user takes over in codex TUI

**Override:** If the user explicitly asks to choose execution mode or pause between phases, respect that. Auto-execution is the default, not a mandate.
