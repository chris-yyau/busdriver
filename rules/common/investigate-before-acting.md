# Investigate Before Acting

> Provenance: distilled from `~/.claude/notes/` Behavioral Rules — Investigate before reversing, Never rollback without asking, Wrong root cause attribution, Read source before analyzing, Scope full problem before solutions, Search before asserting nonexistence, Verify symlinks, Verify subagent claims, Don't modify unrelated infrastructure, Web search before asking.

## Rule

Before fixing, reverting, or asserting anything, **investigate first**. Read the actual code. Reproduce the problem. Map the full scope. The cost of pausing to understand is minutes; the cost of acting on wrong assumptions is hours of cleanup.

## The Investigation Order

1. **Read** — Read the full source files involved, not grep fragments. Understand what exists before proposing changes.
2. **Reproduce** — Confirm the problem actually exists as described. Check if you caused it yourself.
3. **Scope** — Map ALL affected components before proposing solutions. Partial understanding leads to partial fixes that create new problems.
4. **Search** — Before asserting something doesn't exist, search for it. Absence from your training data does not mean nonexistence. Search the web for unfamiliar terms before asking the user — local grep is not sufficient.
5. **Diagnose** — Identify the root cause. Check if Claude itself caused the issue before blaming external systems.
6. **Then act** — Only after steps 1-5.

## Anti-Patterns

| Trap | Fix |
|------|-----|
| Reverting code to "fix" a problem | Diagnose first, fix second, rollback only as last resort — and only with user approval |
| Guessing root cause from symptoms | Read the actual error, trace the actual code path |
| Proposing a fix for file A when the bug is in file B | Scope the full problem across all components first |
| "This doesn't exist" based on training data | Search the filesystem, web, or package registry before asserting |
| Blaming hooks/agents/CI for a recurrence | Check if your own prior action caused it |
| Trusting subagent classifications for deletion | Verify each claim independently — subagents can misclassify custom files |
| Guessing at unfamiliar terms from local files | Web search first, local grep second, ask user last |
