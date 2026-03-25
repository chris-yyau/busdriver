# Busdriver

Unified workflow orchestrator for Claude Code. Consolidates pipeline process (brainstorming, planning, TDD, verification), domain tools (language patterns, reviewers, build resolvers), and enforcement gates (code review, design review, secret scanning) into one installable plugin.

## Install

```bash
claude plugin install busdriver
```

## Architecture

All skills live in `skills/` (flat structure for Claude Code auto-discovery). Conceptually they span four layers:

1. **Pipeline** — Process skills: brainstorming, planning, TDD, verification, git worktrees
2. **Domain** — Language/framework patterns, specialized agents, build resolvers
3. **Gates** — Hook-enforced reviews (codex-reviewer, design-reviewer) that cannot be skipped
4. **Workflow** — Orchestrator, council, reflection, and routing tools

## License

MIT
