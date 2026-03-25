---
name: refine-notes
description: Analyze notes health and upgrade thematic groups — distill to rules or skills, archive the rest
---

# Refine Notes

Analyze `~/.claude/notes/` health, then upgrade lessons: actionable principles become rules, reusable patterns become skills, and stale/consumed notes get archived.

## Phase 1: Health Analysis

Run the health analysis script:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/prune-notes.py"
```

Present the report summarizing:
- **Orphaned files**: Notes not in NOTES.md (add to index or archive)
- **Dead links**: Index references to missing files (remove from index)
- **Stale notes**: Past type-specific TTLs (re-validate or archive)
- **Missing metadata**: Notes without frontmatter or last_validated dates

If issues found, propose fixes and wait for user approval before proceeding.

## Phase 2: Thematic Analysis

Read `~/.claude/notes/NOTES.md` and identify thematic groups under `## Council Lessons`.

For each thematic group:
1. Count the lessons in the group
2. Check if a corresponding distilled rule file already exists in `~/.claude/rules/common/`
3. Read 2-3 representative lessons to assess whether the group's summary accurately captures the principles
4. Groups marked "distributed across rule files above" (e.g., Engineering Principles) are already handled — skip distillation proposals for these

**Existing distilled rule files:**
- `gates-and-auditing.md` — Gate & Enforcement Design + Audit Methodology
- `routing-and-architecture.md` — Routing & Architecture + architectural Engineering Principles
- `upstream-and-trust.md` — Fork/Patch/Upstream + Trust/Instinct Boundaries
- `review-tooling.md` — Review & Tool Selection + review-relevant Engineering Principles

## Phase 3: Upgrade Proposals

For any thematic group WITHOUT a corresponding rule file, or with new lessons not reflected in the existing rule file:

1. **Broadly actionable principle** → Propose addition to existing rule file or new rule file
2. **Reusable pattern with implementation detail** → Propose extracting as a skill
3. **Consumed into rules/skills** → Propose archiving the source note (move to `notes/archive/`)
4. **Still relevant but not upgradeable** → Leave as-is (technique-specific, decision context)

Present proposals and wait for user approval.

## Phase 4: Execute Approved Changes

For approved proposals:
1. Create or update rule files in `~/.claude/rules/common/`
2. Create skills if approved (via `busdriver:writing-skills`)
3. Archive consumed notes: `mkdir -p ~/.claude/notes/archive/ && mv ~/.claude/notes/<file> ~/.claude/notes/archive/`
4. Update NOTES.md to remove archived entries and add any new references
5. Each rule file includes a provenance header linking back to NOTES.md sections

## Principles

- **Notes = historical record** — specific failure scenarios, who said what, decision context
- **Rules = actionable principles** — always-loaded, concise, applies broadly
- **Skills = reusable patterns** — detailed implementation guidance, loaded on demand
- **Archive = consumed or stale** — notes whose value has been fully captured in rules/skills
- **Always-loaded rules gain constitutional weight** — only promote genuinely actionable behavioral rules, not definitions or vocabulary
