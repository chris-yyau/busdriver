# Supplements Manifest

> - **Supplement:** Separate file in `skills/supplements/` loaded alongside the original via orchestrator routing. Zero merge conflicts.
> - **Opt-in:** Supplement that is NOT loaded by default — only when explicitly invoked or triggered.
>
> **How supplements load:** Supplements are NOT auto-loaded by hooks. When invoking a skill or dispatching an agent listed in a supplement's `targets:` frontmatter, Claude must Read the supplement file from `skills/supplements/` and apply its content alongside the targeted skill. The orchestrator's "Supplement Loading Protocol" section provides the instruction. Opt-in supplements require an explicit user trigger phrase.
>
> **Upstream tracking:** Fork-edit state is tracked in `.upstream-sources.json` at the repo root, not in this file.

## Active Supplements

| File | Targets | Source | Added |
|------|---------|--------|-------|
| `anti-sycophancy.md` | `busdriver:brainstorming` | gstack /office-hours | 2026-03-23 |
| `llm-security-audit.md` | `security-reviewer` agent | gstack /cso Phase 7 | 2026-03-23 |
| `skill-supply-chain.md` | `busdriver:security-scan` | gstack /cso Phase 8 | 2026-03-23 |
| `diff-aware-qa.md` | `e2e-runner` agent | gstack /qa | 2026-03-23 |
| `confidence-gated-findings.md` | `security-reviewer` agent, `security-scan` skill | gstack /cso | 2026-03-24 |
| `three-layer-knowledge.md` | `busdriver:brainstorming`, `busdriver:writing-plans` | gstack shared | 2026-03-24 |
| `spec-review-convergence.md` | `busdriver:brainstorming`, `design-reviewer` skill | gstack /office-hours | 2026-03-24 |
| `nutrient-api-terms.md` | `busdriver:nutrient-document-processing` | fork-edit migration (council 2026-03-24) | 2026-03-24 |

## Opt-In Supplements

| File | Targets | Trigger | Source | Added |
|------|---------|---------|--------|-------|
| `design-anti-slop.md` | `document-skills:frontend-design`, `busdriver:frontend-patterns` | "avoid AI slop", "make it unique" | gstack /design-consultation | 2026-03-24 |
| `directory-freeze.md` | `busdriver:systematic-debugging` | "freeze", "lock this dir" | gstack /freeze | 2026-03-24 |

## Rejected (Council Decision)

| Idea | Reason | Council Date |
|------|--------|-------------|
| Cognitive pattern libraries | Convergent reasoning risk in 4-voice council | 2026-03-23 |
| Effort compression table | Cargo-cult machinery, fake rigor | 2026-03-24 |
| Autoplan decision principles | Centralizes taste, governance bloat | 2026-03-24 |
| Cross-project retrospective | Historical scorekeeping risk | 2026-03-24 |
| Founder signal synthesis | Too niche, no advocate | 2026-03-24 |

## Notes

Fork-edit tracking (ECC and Superpowers customizations) is maintained in `.upstream-sources.json` at the repo root.
