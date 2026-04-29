---
description: Grilling session that stress-tests a plan against the project's domain glossary (CONTEXT.md) and recorded decisions (docs/adr/), updating both inline.
argument-hint: [the plan or design to be grilled]
---

# /grill-with-docs

Slash entry point for the `grill-with-docs` skill. The skill has `disable-model-invocation: true` because of its heavyweight side effects (writes `CONTEXT.md` and `docs/adr/*`), so this command is the primary user-facing invocation path.

## Arguments

`$ARGUMENTS`

## Delegation

Apply the `grill-with-docs` skill (`skills/grill-with-docs/SKILL.md`). Walk the design tree one question at a time, persisting decisions into `CONTEXT.md` (vocabulary) and `docs/adr/*.md` (architecture decisions) inline as they crystallise.
