# Orchestrator: Master Skill Router

Routes tasks to the appropriate busdriver skill, agent, or command.

## What It Does

- **Pipeline enforcement** — phases 1–6 (brainstorming → finishing)
- **Domain detection** — loads language/framework patterns automatically
- **Gate enforcement** — six hook-enforced gates (litmus pre-commit/pre-PR, blueprint-review, pre-implementation, freeze/guard, pre-merge/pr-grind)
- **Agent dispatch** — specialized agents in `agents/` (reviewers, build resolvers, gan/opensource pipelines, etc.)

## How It Routes

### 1. Mandatory Gates (Hook-Enforced)
- **Litmus (pre-commit)** — code review before `git commit`
- **Litmus (pre-PR)** — multi-voice deep review before `gh pr create`
- **Blueprint Review** — plan/design review (writes `<!-- design-reviewed: PASS -->`)
- **Pre-implementation** — blocks impl while design docs unreviewed
- **Freeze/Guard** — restricts edits to investigation scope during debugging
- **Pre-merge (pr-grind)** — blocks `gh pr merge` until pr-grind clean

### 2. Pipeline Phases
- **Phase 1** → `busdriver:brainstorming`
- **Phase 2** → `busdriver:writing-plans`
- **Phase 3** → `busdriver:using-git-worktrees`
- **Phase 4** → execution mode + TDD + code review
- **Phase 5** → `busdriver:verification-loop` then `busdriver:verification-before-completion`
- **Phase 6** → `busdriver:finishing-a-development-branch`

### 3. Domain Detection
Detects language/framework from file extensions and loads matching patterns:
- Go, Python, Django, Spring Boot, Frontend (React/Next.js), C++, Swift, Kotlin, Rust, Flutter, Perl, PHP/Laravel, Nuxt, Database, DevOps, AI/LLM, Video

### 4. Non-Pipeline Tasks
Direct routes for tasks outside the pipeline: refactoring, research, roundtable, multi-agent, content, media, etc.

## Scope

The orchestrator only routes to **busdriver-owned** skills, agents, and commands. External plugins and local skills resolve through their own descriptions in the skill registry.

## Credits

Built on:
- **Superpowers** by [affaanmustafa](https://x.com/affaanmustafa)
- **Everything Claude Code** by [affaanmustafa](https://x.com/affaanmustafa)
