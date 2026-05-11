---
name: gates-taxonomy
description: 4 canonical gate types for workflow validation — Pre-flight, Revision, Escalation, Abort — with selection heuristic and gate matrix
targets:
  - busdriver:orchestrator
  - busdriver:litmus
  - busdriver:blueprint-review
  - busdriver:verification-loop
  - busdriver:finishing-a-development-branch
source: gsd-build/get-shit-done references/gates.md (adapted)
added: 2026-04-08
---

# Gates Taxonomy

Canonical gate types for workflow validation. Every validation checkpoint in busdriver maps to one of these four types.

> Load alongside `busdriver:orchestrator` when routing through pipeline gates. Reference when designing or auditing validation points.

---

## Gate Types

### Pre-flight Gate
**Purpose:** Validates preconditions before starting an operation.
**Behavior:** Blocks entry if conditions unmet. No partial work created.
**Recovery:** Fix the missing precondition, then retry.
**Examples in busdriver:**
- litmus checks for staged changes before review
- blueprint-review checks for plan/design doc existence
- writing-plans checks for requirements/spec input

### Revision Gate
**Purpose:** Evaluates output quality and routes to revision if insufficient.
**Behavior:** Loops back to producer with specific feedback. Bounded by iteration cap. Escalates early if issue count does not decrease between consecutive iterations (stall detection).
**Recovery:** Producer addresses feedback; checker re-evaluates. After max iterations, escalates unconditionally.
**Examples in busdriver:**
- litmus review loop (multi-agent review with convergence)
- santa-loop adversarial convergence between two independent reviewers
- blueprint-review dimensional scoring with PASS/NEEDS WORK threshold

### Escalation Gate
**Purpose:** Surfaces unresolvable issues to the developer for a decision.
**Behavior:** Pauses workflow, presents options, waits for human input.
**Recovery:** Developer chooses action; workflow resumes on selected path.
**Examples in busdriver:**
- litmus review finding CRITICAL issues that require human judgment
- council voices unable to reach consensus
- merge conflicts during worktree cleanup

### Abort Gate
**Purpose:** Terminates the operation to prevent damage or waste.
**Behavior:** Stops immediately, preserves state, reports reason.
**Recovery:** Developer investigates root cause, fixes, restarts from checkpoint.
**Examples in busdriver:**
- careful-guard.sh blocking destructive bash commands
- context budget hitting POOR tier (70%+)
- design-review blocking implementation code before review completes

---

## Gate Matrix (Busdriver Pipeline)

| Workflow | Phase | Gate Type | What's Checked | Failure Behavior |
|----------|-------|-----------|----------------|------------------|
| orchestrator | Entry | Pre-flight | Skill/agent availability | Route to fallback or error |
| writing-plans | Entry | Pre-flight | Requirements/spec exist | Block with guidance |
| writing-plans | Quality | Revision | Plan completeness, MECE | Loop to planner (bounded) |
| blueprint-review | Entry | Pre-flight | Design doc exists | Block |
| blueprint-review | Scoring | Revision | Dimensional score threshold | NEEDS WORK with feedback |
| litmus (commit) | Entry | Pre-flight | Staged changes exist | Skip review |
| litmus (commit) | Review | Revision | Code quality findings | Fix-first, then re-review |
| litmus (PR) | Review | Revision | Full diff review | Multi-agent convergence |
| litmus | Critical | Escalation | CRITICAL findings | Surface to developer |
| careful-guard | Command | Abort | Destructive pattern match | Block with explanation |
| finishing-branch | Readiness | Pre-flight | Tests pass, no uncommitted | Block with dashboard |
| council | Consensus | Escalation | Voices disagree | Present all perspectives |

---

## Selection Heuristic

When designing or auditing a validation point:

1. **Start with Pre-flight.** If the check happens before work begins and can be verified with file existence or config reads, it's a pre-flight gate.
2. **If the check happens after work is produced**, it's a **Revision** gate. Always pair with an iteration cap. Expensive operations get fewer retries.
3. **If the revision loop cannot resolve the issue**, add an **Escalation** gate. Present clear options with enough context to decide.
4. **If continuing is dangerous** (data loss, wasted resources, meaningless output), use an **Abort** gate. Preserve state so work can resume after root cause is fixed.

---

## Applying to New Skills

When creating new skills or workflows that need validation:

1. Identify all decision/validation points in the workflow
2. Classify each as one of the 4 gate types
3. Implement the corresponding behavior (block, loop, pause, or stop)
4. Document the gate in the skill's SKILL.md
5. For revision gates: define max iterations and stall detection
6. For escalation gates: define the options presented to the user
