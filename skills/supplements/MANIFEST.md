# Supplements Manifest

> - **Supplement:** Separate file in `skills/supplements/` loaded alongside the original via orchestrator routing. Zero merge conflicts.
> - **Opt-in:** Supplement that is NOT loaded by default — only when explicitly invoked or triggered.
>
> **How supplements load:** Supplements are NOT auto-loaded by hooks. When invoking a skill or dispatching an agent listed in a supplement's `targets:` frontmatter, Claude must Read the supplement file from `skills/supplements/` and apply its content alongside the targeted skill. The orchestrator's "Supplement Loading Protocol" section provides the instruction. Opt-in supplements require an explicit trigger condition (a user trigger phrase OR an auto-memory signal listed in the manifest's Trigger column).
>
> **Upstream tracking:** Fork-edit state is tracked in `.upstream-sources.json` at the repo root, not in this file.

## Active Supplements

| File | Targets | Source | Added |
|------|---------|--------|-------|
| `anti-sycophancy.md` | `busdriver:brainstorming`, `roundtable` | gstack /office-hours | 2026-03-23 |
| `llm-security-audit.md` | `security-reviewer` agent | gstack /cso Phase 7 | 2026-03-23 |
| `skill-supply-chain.md` | `busdriver:security-scan` | gstack /cso Phase 8 | 2026-03-23 |
| `diff-aware-qa.md` | `e2e-runner` agent | gstack /qa | 2026-03-23 |
| `confidence-gated-findings.md` | `security-reviewer` agent, `security-scan` skill | gstack /cso | 2026-03-24 |
| `three-layer-knowledge.md` | `busdriver:brainstorming`, `busdriver:writing-plans` | gstack shared | 2026-03-24 |
| `spec-review-convergence.md` | `busdriver:brainstorming`, `blueprint-review` skill | gstack /office-hours | 2026-03-24 |
| `nutrient-api-terms.md` | `busdriver:nutrient-document-processing` | fork-edit migration (roundtable 2026-03-24) | 2026-03-24 |
| `context-degradation-tiers.md` | `busdriver:context-budget`, `busdriver:strategic-compact`, `busdriver:dispatching-parallel-agents`, `busdriver:subagent-driven-development` | GSD references/context-budget.md (adapted) | 2026-04-06 |
| `thinking-models-planning.md` | `busdriver:writing-plans`, `busdriver:brainstorming`, `busdriver:executing-plans` | GSD references/thinking-models-planning.md (adapted) | 2026-04-08 |
| `gates-taxonomy.md` | `busdriver:orchestrator`, `busdriver:litmus`, `busdriver:blueprint-review`, `busdriver:verification-loop`, `busdriver:finishing-a-development-branch` | GSD references/gates.md (adapted) | 2026-04-08 |
| `agent-contracts.md` | `busdriver:dispatching-parallel-agents`, `busdriver:subagent-driven-development`, `busdriver:executing-plans`, `busdriver:orchestrator` | GSD references/agent-contracts.md (adapted) | 2026-04-08 |
| `thinking-models-debug.md` | `busdriver:systematic-debugging`, `busdriver:agent-introspection-debugging` | GSD references/thinking-models-debug.md (adapted) | 2026-05-01 |
| `thinking-models-execution.md` | `busdriver:executing-plans`, `busdriver:subagent-driven-development`, `busdriver:dispatching-parallel-agents` | GSD references/thinking-models-execution.md (adapted) | 2026-05-01 |
| `thinking-models-research.md` | `busdriver:deep-research`, `busdriver:research-ops`, `busdriver:search-first`, `busdriver:codebase-onboarding` | GSD references/thinking-models-research.md (adapted) | 2026-05-01 |
| `thinking-models-verification.md` | `busdriver:verification-loop`, `busdriver:verification-before-completion`, `busdriver:blueprint-review` | GSD references/thinking-models-verification.md (adapted) | 2026-05-01 |

## Opt-In Supplements

| File | Targets | Trigger | Source | Added |
|------|---------|---------|--------|-------|
| `design-anti-slop.md` | `document-skills:frontend-design`, `busdriver:frontend-patterns`, `ui-ux-pro-max` | "avoid AI slop", "make it unique", "don't make it generic" | gstack /design-consultation | 2026-03-24 |
| `directory-freeze.md` | `busdriver:systematic-debugging` | "freeze", "lock this dir" | gstack /freeze | 2026-03-24 |
| `beginner-mode.md` | `busdriver:brainstorming`, `busdriver:grill-me` | "I'm new to this", "explain like I'm a beginner", "beginner mode", "what does X mean", "I don't understand X" + auto-memory user-knowledge-gap entries | in-house (grill-me integration) | 2026-05-05 |

## Rejected (Roundtable Decision)

| Idea | Reason | Roundtable Date |
|------|--------|-------------|
| Cognitive pattern libraries | Convergent reasoning risk in 4-voice roundtable | 2026-03-23 |
| Effort compression table | Cargo-cult machinery, fake rigor | 2026-03-24 |
| Autoplan decision principles | Centralizes taste, governance bloat | 2026-03-24 |
| Cross-project retrospective | Historical scorekeeping risk | 2026-03-24 |
| Founder signal synthesis | Too niche, no advocate | 2026-03-24 |

## Notes

Fork-edit tracking (ECC and Superpowers customizations) is maintained in `.upstream-sources.json` at the repo root.
