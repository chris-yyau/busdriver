# Tool Discipline

> Provenance: distilled from `~/.claude/notes/` Behavioral Rules — use-skill-tool-not-manual-reimplementation, agent-overhead-single-task, ultrathink-means-analyze-not-implement, questions-are-not-instructions.

## Use the Right Tool

- **Skill tool over manual reconstruction.** When a skill exists (busdriver, ECC, plugin), invoke it via the `Skill` tool — don't reimplement its protocol from memory. Search the available-skills list before assuming a capability is missing. Manual reconstructions get details wrong, waste turns, and frustrate users who already know the skill exists.
- **Inline work over Agent dispatch.** Don't launch background Agents for single sequential tasks. Agents inherit the full hook pipeline (review gates, codex loops, worktree setup), turning 2-minute work into 10+ minute waits. Reserve Agent for genuine parallelism (2+ independent tasks) or context-overflow risk.

## Distinguish Question from Instruction

- **Questions get answers, not implementations.** "Can we X?", "Should we Y?", "What if Z?", "Is it possible to ...?" are questions. Answer them. Don't proceed to implement until the user explicitly says do it / build it / fix it / go ahead.
- **Plan approval ≠ implementation approval.** "Ultrathink," "redesign," "review this," "think about" all mean *present findings and wait*. After a plan is approved, explicitly ask "ready to implement?" before touching files. Plan refinement permission is not write permission.

## Anti-Patterns

| Trap | Fix |
|------|-----|
| "I'll write the council prompt from memory" | Invoke the existing skill via the `Skill` tool |
| Launching an Agent for a single 2-minute task | Do it inline — Agent overhead exceeds the work |
| Treating "can we X?" as "do X" | Ask the question back if action is implied; otherwise just answer |
| Implementing immediately after plan approval | Ask "ready to implement?" — plan approval is a checkpoint, not a green light |
