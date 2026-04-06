---
name: context-degradation-tiers
description: Graduated behavioral rules for context pressure — tier-based throttling (PEAK/GOOD/DEGRADING/POOR) with early warning signals for quality degradation
targets:
  - busdriver:context-budget
  - busdriver:strategic-compact
  - busdriver:dispatching-parallel-agents
  - busdriver:subagent-driven-development
source: gsd-build/get-shit-done references/context-budget.md (adapted)
---

# Context Degradation Tiers

Runtime behavioral rules for managing context pressure. Apply these whenever orchestrating multi-step work, spawning agents, or reading large files.

## Tier Definitions

| Tier | Usage | Behavior |
|------|-------|----------|
| **PEAK** | 0–30% | Full operations. Read file bodies, spawn multiple parallel agents, inline subagent results. |
| **GOOD** | 30–50% | Normal operations. Prefer summaries over full reads. Delegate aggressively to subagents rather than doing work inline. |
| **DEGRADING** | 50–70% | Economize. Read frontmatter/headers only. Minimal result inlining. Warn user: "Context is getting heavy — consider compacting or checkpointing." |
| **POOR** | 70%+ | Emergency mode. Checkpoint progress immediately. No new file reads unless critical to current task. Suggest `/compact` or session handoff. |

## Read Depth by Model

| Context Window | Subagent Results | Large Files | Multi-file Reads |
|---------------|-----------------|-------------|-----------------|
| < 500k (200k model) | Summaries only | Headers/frontmatter only | Current task scope only |
| ≥ 500k (1M model) | Full body permitted when needed for decisions | Full body permitted | Still limit to current task scope |

## Early Warning Signals

Quality degrades *gradually* before hard limits hit. Watch for these signals in your own output and in subagent results:

### Silent Partial Completion
Agent claims task is done but implementation is incomplete. Self-check confirms files exist but misses semantic gaps. **Mitigation:** Verify against plan's must-haves, not just file existence.

### Increasing Vagueness
Output shifts from specific code to phrases like "appropriate handling", "standard patterns", or "follow best practices." This indicates context pressure even before budget warnings fire. **Mitigation:** If you catch yourself being vague, stop and compact.

### Skipped Steps
Agent omits protocol steps it would normally follow. If success criteria has 8 items but only 5 are reported, suspect context pressure. **Mitigation:** Count checklist items explicitly.

## Orchestrator Rules

When spawning or managing subagents:

1. **Never** inline large files into subagent prompts — tell agents to read from disk
2. **Never** read agent definition files (`agents/*.md`) — `subagent_type` auto-loads them
3. **Delegate** heavy work to subagents — the orchestrator routes, it doesn't execute
4. Orchestrators cannot verify *semantic* correctness of agent output — only structural completeness. This is a fundamental limitation. Mitigate with explicit must-haves and spot-check verification.
