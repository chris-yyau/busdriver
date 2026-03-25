---
name: directory-freeze
description: "Directory-scoped edit lock during debugging — opt-in supplement to prevent scope creep when fixing bugs"
targets: busdriver:systematic-debugging
type: supplement
opt_in: true
source: gstack /freeze
added: 2026-03-24
---

# Directory-Scoped Freeze

> **Opt-in supplement.** Load alongside `busdriver:systematic-debugging` when debugging complex issues. Not loaded by default — invoke when the user says "freeze", "lock this dir", "don't touch anything outside", or when debugging scope is creeping.

## Purpose

During debugging, it's easy to start "fixing" things in unrelated areas. The freeze pattern locks edits to a specific directory scope, preventing scope creep.

## How It Works

1. **User specifies scope:** "Only edit files in `src/auth/`"
2. **Freeze rule:** Before any Edit/Write operation, check if the target file is within the frozen scope
3. **If outside scope:** Stop and ask the user: "This file is outside the freeze scope (`src/auth/`). Edit anyway?"
4. **If inside scope:** Proceed normally

## When to Suggest Freezing

- After forming a debugging hypothesis that points to a specific module
- When the user says "I think the bug is in X" — suggest freezing to X
- After 3+ edits that span unrelated directories — scope may be creeping
- During the "Implement" phase of systematic debugging (hypothesis is locked)

## Scope Rules

- **Read is always allowed** — freeze only blocks Edit/Write, not Read/Grep/Glob
- **Bash commands are allowed** — running tests, build commands, etc. are fine
- **The freeze is session-scoped** — it ends when the debugging task ends
- **User can unfreeze anytime** — "unfreeze" or "expand scope to include X"

## Limitations

This is prompt-based guidance, not a mechanical hook. It relies on following the discipline. For mechanical enforcement, this would need a PreToolUse hook (future work).
