# Busdriver

The adult supervision your AI coding agent didn't ask for but desperately needs.

Busdriver is a unified workflow orchestrator for Claude Code that makes sure your AI actually follows a process instead of yolo-committing spaghetti at 3am. It consolidates pipeline process (brainstorming, planning, TDD, verification), domain tools (language patterns, reviewers, build resolvers), and enforcement gates (code review, design review) into one plugin that Claude literally cannot talk its way out of.

Think of it as the designated driver for your codebase — it won't let Claude leave the bar until the code review passes.

## Install

```bash
claude plugin marketplace add github:chris-yyau/busdriver
claude plugin install busdriver@busdriver
```

## What It Does

- **Forces a process** — 6-phase pipeline from brainstorming to merge. Small, specific tasks (bug fix, typo, config tweak) can skip straight to execution, but everything else goes through the full pipeline.
- **Reviews everything** — Codex reviewer gates every commit. Design reviewer gates every plan. Pre-implementation gate blocks code while plans are unreviewed. Claude will try to rationalize its way past these. It will fail.
- **Speaks 15 languages and frameworks** — Go, Python, Rust, TypeScript, Swift, Kotlin, C++, Java, Perl, Flutter/Dart, Django, Spring Boot, Laravel, Nuxt, and more. Each with dedicated patterns, testing skills, and reviewer agents.
- **29 specialized agents** — Architect, planner, TDD guide, security reviewer, 8 language-specific reviewers, 7 build resolvers, and more. They argue with each other so you don't have to.
- **Learns from mistakes** — Instinct system observes patterns, council provides multi-perspective analysis, lessons get captured when reviews find issues the plan missed.

## Architecture

All skills live in `skills/` (flat structure for Claude Code auto-discovery). Conceptually they span four layers:

1. **Pipeline** — Process skills: brainstorming, planning, TDD, verification, git worktrees
2. **Domain** — Language/framework patterns, specialized agents, build resolvers
3. **Gates** — Hook-enforced reviews (codex-reviewer, design-reviewer, pre-implementation) that cannot be skipped
4. **Workflow** — Orchestrator, council, reflection, and routing tools

## Credits

Built on the shoulders of:
- **[Superpowers](https://github.com/obra/superpowers)** by Jesse Vincent — the pipeline backbone
- **[Everything Claude Code](https://github.com/affaan-m/everything-claude-code)** by Affaan Mustafa — domain tools, hooks, and agents

## License

MIT
