---
name: agent-contracts
description: Formal completion markers and handoff schemas for multi-agent workflows — standardized signals for agent completion, blocking, and partial results
targets:
  - busdriver:dispatching-parallel-agents
  - busdriver:subagent-driven-development
  - busdriver:executing-plans
  - busdriver:orchestrator
source: gsd-build/get-shit-done references/agent-contracts.md (adapted)
added: 2026-04-08
---

# Agent Contracts

Completion markers and handoff conventions for busdriver's multi-agent workflows. When spawning agents via the Agent tool, use these markers to detect agent state and route accordingly.

> Load alongside `busdriver:dispatching-parallel-agents` and `busdriver:executing-plans` when orchestrating multi-agent work.

---

## Standard Completion Markers

Agents should end their output with one of these H2 markers so the orchestrator can detect completion state:

| Marker | Meaning | Orchestrator Action |
|--------|---------|---------------------|
| `## TASK COMPLETE` | Agent finished successfully | Proceed to next step |
| `## TASK BLOCKED` | Agent cannot proceed — missing input or unresolvable issue | Escalate to user |
| `## CHECKPOINT REACHED` | Agent paused at a decision point — needs input to continue | Present options to user |
| `## PARTIAL RESULTS` | Agent produced some output but couldn't finish everything | Review partial output, decide whether to retry or accept |

### Specialized Markers

| Context | Success Marker | Failure Marker |
|---------|---------------|----------------|
| Planning | `## PLAN COMPLETE` | `## PLANNING BLOCKED` |
| Research | `## RESEARCH COMPLETE` | `## RESEARCH BLOCKED` |
| Review | `## REVIEW COMPLETE` | `## ISSUES FOUND` |
| Verification | `## VERIFICATION PASSED` | `## VERIFICATION FAILED` |
| Build/Fix | `## BUILD PASSING` | `## BUILD FAILING` |

---

## Marker Rules

1. Markers are **H2 headings** (`## `) at the start of a line in the agent's final output
2. Use **ALL-CAPS** for standard markers
3. Agents without explicit markers (e.g., code-reviewer) write artifacts directly — the orchestrator checks artifact existence instead
4. When an agent produces partial results, the `## PARTIAL RESULTS` marker should be followed by a summary of what was completed and what remains

---

## Handoff Schemas

When agents produce artifacts that downstream agents consume, use consistent structure:

### Plan Handoff (Planner -> Executor)

The plan artifact should contain:
- **Objective** — what the plan achieves
- **Tasks** — ordered list with files, actions, verification steps, acceptance criteria
- **Success criteria** — measurable completion conditions
- **Dependencies** — what must exist before execution starts

### Execution Handoff (Executor -> Reviewer)

The execution summary should contain:
- **What changed** — files modified with purpose
- **Deviations** — any departures from the plan and why
- **Self-check** — PASSED or FAILED with details
- **Remaining work** — anything deferred or incomplete

### Review Handoff (Reviewer -> Developer)

Review output should contain:
- **Severity-classified findings** — CRITICAL, HIGH, MEDIUM, LOW
- **Actionable fixes** — specific file:line references
- **Approval status** — APPROVE, WARN, or BLOCK

---

## Orchestrator Detection

When processing agent results, orchestrators should:

1. **Check for completion markers first** — regex match `^## (TASK COMPLETE|TASK BLOCKED|CHECKPOINT|PARTIAL)` in agent output
2. **Fall back to artifact existence** — if no marker, check whether expected output files were created
3. **Never assume success from absence** — if neither marker nor artifact is found, treat as blocked
4. **Route based on marker type:**
   - COMPLETE/PASSED → advance to next step
   - BLOCKED/FAILED → escalate to user
   - CHECKPOINT → present decision options
   - PARTIAL/ISSUES FOUND → evaluate whether to retry, fix, or accept

---

## Agent Prompt Convention

When spawning agents that should use contracts, include this in the prompt:

> When you finish, end your output with the appropriate completion marker:
> - `## TASK COMPLETE` if successful
> - `## TASK BLOCKED` if you cannot proceed (explain why)
> - `## CHECKPOINT REACHED` if you need a decision before continuing

This is a convention, not enforcement. Agents from the busdriver registry (via `subagent_type`) may have their own output patterns. Apply contracts primarily to custom agent spawns in multi-step workflows.
