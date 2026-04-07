---
name: thinking-models-planning
description: 6 structured reasoning models for planning decisions — Pre-Mortem, MECE, Constraint Analysis, Reversibility Test, Curse of Knowledge Counter, Base Rate Neglect Counter
targets:
  - busdriver:writing-plans
  - busdriver:brainstorming
  - busdriver:executing-plans
source: gsd-build/get-shit-done references/thinking-models-planning.md (adapted)
added: 2026-04-08
---

# Thinking Models for Planning

Structured reasoning models for planning and architecture decisions. Apply these at decision points, not continuously. Each model counters a specific failure mode.

> Load alongside `busdriver:writing-plans` and `busdriver:brainstorming` when making planning decisions.

## Conflict Resolution

Pre-Mortem and Constraint Analysis both analyze risk at different granularities. Run **Constraint Analysis FIRST** (identify the hardest constraint), then **Pre-Mortem** (enumerate failure modes around that constraint and the rest of the plan).

---

## 1. Pre-Mortem Analysis

**Counters:** Optimistic plan decomposition that ignores failure modes.

Before finalizing a plan, assume it has already failed. List the 3 most likely reasons for failure — missing dependency, wrong decomposition, underestimated complexity — and add mitigation steps or acceptance criteria that would catch each failure early.

## 2. MECE Decomposition

**Counters:** Overlapping tasks (merge conflicts) or gapped tasks (missing requirements).

Verify the task breakdown is MECE at the REQUIREMENT level:
1. List every requirement from the phase/feature goal
2. Confirm each maps to exactly one task's done criteria
3. If two tasks modify the same file, confirm they modify DIFFERENT sections or serve DIFFERENT requirements
4. Flag any requirement not covered by any task

## 3. Constraint Analysis

**Counters:** Deferring the hardest constraint to the last task, causing late-stage failures.

Identify the single hardest constraint — the one thing that, if it doesn't work, makes everything else irrelevant. Schedule that constraint as Task 1 or 2, not last. If the constraint involves an external API or unfamiliar library, add a spike/proof-of-concept task before the main implementation.

## 4. Reversibility Test

**Counters:** Over-analyzing cheap decisions, under-analyzing costly ones.

For each significant decision, classify as:
- **REVERSIBLE** — can change later with low cost
- **IRREVERSIBLE** — changing later requires migration, breaking changes, or significant rework

Spend analysis time proportional to irreversibility. For irreversible decisions, document the rationale in the plan.

## 5. Curse of Knowledge Counter

**Counters:** Plan-to-executor ambiguity from compressed instructions.

For each action step, re-read it as if you have NEVER seen this codebase. Is every noun unambiguous (which file? which function? which endpoint?)? Is every verb specific (add WHERE? modify HOW?)? If a step could be interpreted two ways, rewrite it. Include file paths, function names, and expected behavior.

## 6. Base Rate Neglect Counter

**Counters:** Planners ignoring low-confidence research caveats.

Before finalizing the plan, read ALL needs-decision items and low-confidence recommendations from research. For each: either (a) create a decision checkpoint task to resolve it, or (b) document why the risk is acceptable. Low-confidence items that are silently accepted become undocumented technical debt.

---

## Gap Closure Mode

When replanning after verification finds gaps, apply a root-cause check before writing the fix plan:

**Why did this gap occur?**
- **Plan deficiency** — wrong or missing task
- **Execution miss** — correct task, wrong implementation
- **Changed assumption** — environment or dependency shifted

The fix plan must target the root cause category, not just the symptom.

---

## When NOT to Think

Skip structured reasoning models when the situation does not benefit:

- **Single-task changes** — one clear requirement, one obvious task. Write it directly.
- **Well-researched features** — research has high-confidence recommendations for every decision. Skip Base Rate Neglect Counter.
- **Revision iterations** — when revising based on reviewer feedback, apply only the model relevant to the specific issue (e.g., MECE if coverage gap found).
- **Boilerplate** — config changes, version bumps, docs updates. No failure modes worth pre-mortem analysis.
