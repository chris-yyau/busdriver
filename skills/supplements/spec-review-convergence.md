---
name: spec-review-convergence
description: Independent subagent spec review with bounded iterations and convergence guard — prevents infinite planning loops
targets: busdriver:brainstorming, design-reviewer skill
type: supplement
source: gstack /office-hours
added: 2026-03-24
---

# Spec Review Loop with Convergence

> Load alongside `busdriver:brainstorming` (Step 7) and `design-reviewer` skill.

## Process

After writing a design doc or spec, dispatch an independent subagent reviewer before proceeding to implementation.

### 1. Dispatch Reviewer

Launch a fresh subagent (clean context) with:
- The spec document content
- Review dimensions: completeness, consistency, clarity, scope, feasibility
- NO conversation history — the reviewer sees only the spec

### 2. Review Dimensions

The reviewer evaluates on 5 dimensions:

| Dimension | Question |
|-----------|----------|
| **Completeness** | Are all requirements addressed? Any gaps? |
| **Consistency** | Do sections contradict each other? |
| **Clarity** | Could an implementer build this without asking questions? |
| **Scope** | Is the scope appropriate? Too broad? Too narrow? |
| **Feasibility** | Can this be built with the stated approach and constraints? |

Each dimension: PASS, CONCERN (minor issue), or FAIL (blocks implementation).

### 3. Convergence Guard

- **Max 3 iterations.** Fix issues and re-dispatch up to 3 times.
- **After 3 iterations:** If issues persist, surface them as "Reviewer Concerns" in the spec — don't loop forever. These become known risks for the implementer.
- **Convergence signal:** All 5 dimensions PASS, or remaining concerns are documented and accepted.

### 4. What the Reviewer Should NOT Do

- Rewrite the spec (reviewer reports issues, author fixes them)
- Add new requirements (scope is set by the user, not the reviewer)
- Block on style/formatting (substance over form)
- Require unanimous agreement on every point (documented concerns are acceptable)

## When to Skip

- Trivial specs (< 100 words, single-function changes)
- User explicitly says "skip review"
- Time-critical fixes where review delay exceeds the risk
