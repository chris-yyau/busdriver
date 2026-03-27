# Contributing to Busdriver

Thanks for your interest in contributing to Busdriver! This guide covers how to set up a development environment, understand the project structure, and submit changes.

## Development Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/chris-yyau/busdriver.git
   cd busdriver
   ```

2. Install development dependencies:
   ```bash
   # Commitlint for commit message validation (required for CI)
   npm install

   # ShellCheck for linting gate scripts (required for CI)
   brew install shellcheck    # macOS
   # apt-get install shellcheck  # Linux
   ```

## Project Structure

```text
busdriver/
├── skills/                    # 146 skill definitions (flat, auto-discovered)
│   ├── orchestrator/          # Master routing skill
│   ├── brainstorming/         # Phase 1: discovery
│   ├── writing-plans/         # Phase 2: planning
│   ├── using-git-worktrees/   # Phase 3: isolation
│   ├── executing-plans/       # Phase 4: execution
│   ├── verification-loop/     # Phase 5: verification
│   ├── finishing-a-dev-branch/# Phase 6: finishing
│   ├── codex-reviewer/        # Pre-commit/PR code review
│   ├── design-reviewer/       # Plan/design doc review
│   ├── golang-patterns/       # Language: Go patterns
│   ├── python-patterns/       # Language: Python patterns
│   └── ...                    # 134 more skills
├── agents/                    # 29 specialized agent definitions
│   ├── architect.md
│   ├── planner.md
│   ├── tdd-guide.md
│   ├── code-reviewer.md
│   ├── security-reviewer.md
│   ├── go-reviewer.md         # Language-specific reviewers (8)
│   ├── go-build-resolver.md   # Language-specific build resolvers (7)
│   └── ...
├── hooks/                     # Hook registration and gate scripts
│   ├── hooks.json             # Hook definitions (PreToolUse, PostToolUse)
│   └── gate-scripts/          # Shell scripts for enforcement gates
│       ├── pre-commit-gate.sh
│       ├── pre-pr-gate.sh
│       ├── pre-implementation-gate.sh
│       ├── freeze-guard.sh
│       ├── check-design-document.sh
│       ├── go-post-edit.sh
│       └── ...
├── commands/                  # 65 slash commands (/tdd, /verify, /plan, etc.)
├── scripts/                   # Build, CI, and utility scripts
│   ├── lib/                   # Shared shell libraries
│   ├── ci/                    # CI-specific scripts
│   └── hooks/                 # Hook helper scripts
├── docs/                      # Documentation and plans
├── .github/workflows/         # CI: tests, security, release, pinact, scorecard
└── .claude-plugin/
    └── plugin.json            # Plugin manifest
```

### Conceptual Layers

Skills span four layers, all living flat under `skills/`:

1. **Pipeline** — Process skills (brainstorming, planning, TDD, verification, worktrees)
2. **Domain** — Language/framework patterns, specialized agents, build resolvers
3. **Gates** — Hook-enforced reviews (codex-reviewer, design-reviewer, pre-implementation)
4. **Workflow** — Orchestrator, council, reflection, and routing tools

## Commit Messages

This project uses [Conventional Commits](https://www.conventionalcommits.org/). PRs are validated by commitlint in CI.

```text
feat: add kotlin coroutines skill
fix: codex reviewer marker not consumed after commit
refactor: extract shared gate logic into lib
test: add shellcheck validation for gate scripts
docs: update language support table
chore: bump CI action versions
ci: harden security workflow permissions
```

## Pull Request Process

1. Create a feature branch from `main`
2. Make your changes
3. Ensure CI checks pass locally:
   ```bash
   # Lint gate scripts
   shellcheck hooks/gate-scripts/*.sh

   # Validate commit messages
   npx commitlint --from HEAD~1
   ```
4. Open a PR against `main`
5. CI runs: shellcheck, commitlint, security scanners (trivy, semgrep, checkov, zizmor), and OpenSSF scorecard

## Adding a New Skill

1. Create `skills/<skill-name>/SKILL.md` with frontmatter:
   ```markdown
   ---
   name: my-new-skill
   description: One-line description used for skill discovery and routing
   ---

   # Skill Content

   Detailed instructions, patterns, and examples.
   ```

2. If the skill is language/framework-specific, add a detection entry to `skills/orchestrator/domain-supplements.md`

3. If the skill needs a slash command, create `commands/<name>.md`

4. Update the orchestrator's Non-Pipeline Tasks table if the skill runs outside the standard pipeline

## Adding a New Agent

1. Create `agents/<name>.md` with frontmatter:
   ```markdown
   ---
   name: my-agent
   description: When to use this agent and what it does
   tools: [Read, Grep, Glob, Bash]
   ---

   # Agent instructions
   ```

2. Follow the naming convention: `{lang}-reviewer` for language reviewers, `{lang}-build-resolver` for build resolvers

3. Register the agent in the orchestrator's Phase 4 DISPATCH rules if it should be auto-invoked

## Adding a New Gate Script

1. Create `hooks/gate-scripts/<name>.sh` following existing patterns:
   - Parse hook input JSON from stdin
   - Exit 0 with no output to allow the action
   - Output `{"decision":"block","reason":"..."}` to block
   - Handle edge cases gracefully (missing files, empty state)

2. Register the hook in `hooks/hooks.json`

3. Document the gate in the orchestrator's Gates section

## Code Style

- Shell scripts target **bash 3.2+** (macOS default)
- All gate scripts pass **ShellCheck** with zero warnings
- Quote all variables: `"$var"` not `$var`
- Use `[[ ]]` for conditionals
- Skill files use Markdown with YAML frontmatter
- Agent files use Markdown with YAML frontmatter

## Security

If you discover a security vulnerability, please see [SECURITY.md](SECURITY.md) for responsible disclosure instructions.
