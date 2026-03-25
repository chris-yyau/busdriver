# Supplements Manifest

> **Architecture:** Fork is the live loaded plugin. Registered via plugin configuration to load from `plugins/forked/` instead of cache.
>
> - **Supplement:** Separate file in `skills/supplements/` loaded alongside the original via orchestrator routing. Zero merge conflicts.
> - **Fork-edit:** Direct modification in `plugins/forked/`. Must be synced manually when upstream updates.
> - **Opt-in:** Supplement that is NOT loaded by default — only when explicitly invoked or triggered.
>
> **How supplements load:** Supplements are NOT auto-loaded by hooks. When invoking a skill or dispatching an agent listed in a supplement's `targets:` frontmatter, Claude must Read the supplement file from `skills/supplements/` and apply its content alongside the targeted skill. The orchestrator's "Supplement Loading Protocol" section provides the instruction. Opt-in supplements require an explicit user trigger phrase.
>
> **Fork sync (ECC):** Auto-synced from `plugins/marketplaces/` by `patch-plugin-overrides.sh` on version change. Superpowers fork syncs from `obra/superpowers` git origin (different mechanism). Last manual sync: 2026-03-24 (ECC v1.9.0).

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
| `design-anti-slop.md` | `frontend-design` skill | "avoid AI slop", "make it unique" | gstack /design-consultation | 2026-03-24 |
| `directory-freeze.md` | `busdriver:systematic-debugging` | "freeze", "lock this dir" | gstack /freeze | 2026-03-24 |

## Rejected (Council Decision)

| Idea | Reason | Council Date |
|------|--------|-------------|
| Cognitive pattern libraries | Convergent reasoning risk in 4-voice council | 2026-03-23 |
| Effort compression table | Cargo-cult machinery, fake rigor | 2026-03-24 |
| Autoplan decision principles | Centralizes taste, governance bloat | 2026-03-24 |
| Cross-project retrospective | Historical scorekeeping risk | 2026-03-24 |
| Founder signal synthesis | Too niche, no advocate | 2026-03-24 |

## Active Fork-Edits (ECC)

> Fork at `plugins/forked/everything-claude-code/`. Synced to v1.9.0 on 2026-03-24.
> Files below have intentional custom changes. Fork-only files (`.fork-custom-files`, `marketplace.json`) are not listed — they exist only in the fork and have no upstream equivalent. Verify alignment: `python3 -c "..." fork upstream` (see patcher sync logic).

| File | Why | Type |
|------|-----|------|
| `hooks/hooks.json` | Added governance-capture, suggest-compact hooks | Structural |
| `commands/build-fix.md` | Fixed Python compile command | Behavior change |
| `commands/sessions.md` | SDK entrypoint path resolution fix | Behavior change |
| `commands/skill-health.md` | SDK entrypoint path resolution fix | Behavior change |
| `scripts/sync-ecc-to-codex.sh` | Custom Codex sync script | Custom tooling |
| `skills/agent-eval/SKILL.md` | Pinned to secure commit hash | Security hardening |
| `skills/autonomous-loops/SKILL.md` | Changed install to review-first | Security hardening |
| `skills/dmux-workflows/SKILL.md` | Changed install to review-first | Security hardening |
| ~~`skills/nutrient-document-processing/SKILL.md`~~ | ~~Added API terms warning~~ | Migrated to supplement `nutrient-api-terms.md` (2026-03-24) |
| `skills/plankton-code-quality/SKILL.md` | Changed clone instructions | Security hardening |
| `skills/videodb/SKILL.md` | Removed external maintainer link | Security hardening |
| `skills/continuous-learning-v2/config.json` | observer.enabled=true (re-enabled) | Config change |
| `skills/continuous-learning-v2/SKILL.md` | Changed link to Skill Creator app | Link update |
| `skills/continuous-learning-v2/agents/observer-loop.sh` | Analysis file cleanup fix | Bug fix |
| ~~`skills/continuous-learning-v2/scripts/instinct-cli.py`~~ | ~~Instinct CLI path resolution fix~~ | Merged upstream (2026-03-25) |

## Active Fork-Edits (Superpowers)

> Fork at `plugins/forked/superpowers/`. Synced from `obra/superpowers` origin.

| File | Why | Type |
|------|-----|------|
| `hooks/hooks.json` | Removed SessionStart hook (orchestrator conflict) | Structural |

## New Local Skills

| Skill | Path | Source | Added |
|-------|------|--------|-------|
| `canary` | `~/.claude/skills/canary/SKILL.md` | gstack /canary | 2026-03-23 |
