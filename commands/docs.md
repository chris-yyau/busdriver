---
description: Legacy slash-entry shim for the context7-cli skill. Prefer the skill directly.
---

# Docs Command (Legacy Shim)

Use this only if you still reach for `/docs`. The maintained workflow lives in `skills/context7-cli/SKILL.md`.

## Canonical Surface

- Prefer the `busdriver:context7-cli` skill directly.
- Keep this file only as a compatibility entry point.

## Arguments

`$ARGUMENTS`

## Delegation

Apply the `busdriver:context7-cli` skill.
- If the library or the question is missing, ask for the missing part.
- Use live documentation through the ctx7 CLI (Context7) instead of training data.
- Return only the current answer and the minimum code/example surface needed.
