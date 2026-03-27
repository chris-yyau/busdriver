# Busdriver

[![CI](https://github.com/chris-yyau/busdriver/actions/workflows/tests.yml/badge.svg)](https://github.com/chris-yyau/busdriver/actions/workflows/tests.yml)
[![Security](https://github.com/chris-yyau/busdriver/actions/workflows/security.yml/badge.svg)](https://github.com/chris-yyau/busdriver/actions/workflows/security.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/chris-yyau/busdriver/badge)](https://scorecard.dev/viewer/?uri=github.com/chris-yyau/busdriver)

The adult supervision your AI coding agent didn't ask for but desperately needs.

Busdriver is a [Claude Code plugin](https://docs.anthropic.com/en/docs/claude-code/plugins) that consolidates pipeline process (brainstorming, planning, TDD, verification), domain tools (language patterns, reviewers, build resolvers), and enforcement gates (code review, design review) into one unified workflow orchestrator. Claude literally cannot talk its way out of it.

Think of it as the designated driver for your codebase — it won't let Claude leave the bar until the code review passes.

## What it does

Busdriver enforces a 6-phase development pipeline and gates every commit and PR with automated review:

| Phase | What happens |
|-------|-------------|
| **1. Brainstorming** | Explore intent, requirements, and design before writing code |
| **2. Planning** | Produce TDD task lists with file paths, commands, expected output |
| **3. Worktree** | Create isolated git worktree, verify baseline tests pass |
| **4. Execution** | TDD (red/green/refactor), code review, language-specific patterns |
| **5. Verification** | Build + lint + tests, security scan, specialist review agents |
| **6. Finishing** | Commit (codex-reviewed), PR or merge, worktree cleanup |

Small, specific tasks (bug fix, typo, config tweak) skip straight to Phase 4. Everything else goes through the full pipeline.

### Gates (hook-enforced, cannot bypass)

| Gate | Trigger | What it blocks |
|------|---------|---------------|
| **Codex Reviewer** | `git commit` | Blocks commit until code review passes |
| **Codex Reviewer (deep)** | `gh pr create` | Blocks PR until 5 parallel review agents pass (3-of-5 quorum) |
| **Design Reviewer** | Plan/design doc written | Blocks implementation code while plans are unreviewed |
| **Pre-implementation** | `Write`/`Edit` of code files | Blocks file writes while design docs lack `<!-- design-reviewed: PASS -->` |
| **Freeze/Guard** | Debugging session active | Restricts edits to investigation scope only |

Gates emit `{"decision":"block"}` via PreToolUse hooks. The harness rejects the tool call — Claude cannot rationalize its way past these.

### 15 languages and frameworks

| Language | Patterns | Testing | Reviewer | Build Resolver |
|----------|----------|---------|----------|---------------|
| Go | `golang-patterns` | `golang-testing` | `go-reviewer` | `go-build-resolver` |
| Python | `python-patterns` | `python-testing` | `python-reviewer` | -- |
| Rust | `rust-patterns` | `rust-testing` | `rust-reviewer` | `rust-build-resolver` |
| TypeScript/JS | `coding-standards` | `tdd-guide` | `typescript-reviewer` | `build-error-resolver` |
| Swift | `swiftui-patterns` | -- | -- | -- |
| Kotlin | `kotlin-patterns` | `kotlin-testing` | `kotlin-reviewer` | `kotlin-build-resolver` |
| C++ | `cpp-coding-standards` | `cpp-testing` | `cpp-reviewer` | `cpp-build-resolver` |
| Java | `java-coding-standards` | `springboot-tdd` | `java-reviewer` | `java-build-resolver` |
| Perl | `perl-patterns` | `perl-testing` | -- | -- |
| Flutter/Dart | `flutter-dart-code-review` | -- | `flutter-reviewer` | -- |
| Django | `django-patterns` | `django-tdd` | -- | -- |
| Spring Boot | `springboot-patterns` | `springboot-tdd` | -- | -- |
| Laravel | `laravel-patterns` | `laravel-tdd` | -- | -- |
| Nuxt | `nuxt4-patterns` | -- | -- | -- |
| PyTorch | `pytorch-patterns` | -- | -- | `pytorch-build-resolver` |

### 29 specialized agents

Architect, planner, TDD guide, security reviewer, 8 language-specific reviewers, 7 build resolvers, council (4-voice multi-perspective analysis), and more. They argue with each other so you don't have to.

### 146 skills

From brainstorming and planning to domain patterns, deployment workflows, supply chain management, and AI/LLM pipeline optimization. See `skills/` for the full inventory.

## Requirements

- **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)** — the host harness (required)

### Review CLI (configurable)

Set `BUSDRIVER_REVIEW_CLI` to choose your review backend:

| Value | Behavior |
|-------|----------|
| `auto` (default) | Detects: codex > gemini > built-in agent fallback |
| `codex` | OpenAI Codex CLI (`npm install -g @openai/codex`) |
| `gemini` | Google Gemini CLI |
| `claude` | Claude CLI (experimental) |
| `aider` | Aider CLI (experimental) |
| `builtin` | Built-in code-reviewer agent (always available, less independent) |
| `none` | Disable review gate (logs warning on every commit) |

**Without any external CLI:** Auto-detection falls back to the built-in code-reviewer agent. All commits are still reviewed, but by the same model that wrote the code (less independent). Run `node scripts/doctor.js` to see your effective reviewer.

### Optional CLIs for multi-model features

| CLI | Used by | Install |
|-----|---------|---------|
| **[Codex CLI](https://github.com/openai/codex)** | Code review gate (default), design reviewer, council | `npm install -g @openai/codex` |
| **[Gemini CLI](https://github.com/google-gemini/gemini-cli)** | Design reviewer, council, code review (if configured) | `npm install -g @google/gemini-cli` or see repo |

**Without Gemini CLI:** The design reviewer runs with Codex + Claude only (1 external voice instead of 2). The council degrades to 3-voice. Core pipeline works normally.

## Install

```bash
claude plugin marketplace add github:chris-yyau/busdriver
claude plugin install busdriver@busdriver
```

## How it works

Busdriver registers [PreToolUse and PostToolUse hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) that intercept tool calls at the harness level. The orchestrator skill routes every task to the correct pipeline phase and domain tools.

### Architecture

```
Claude Code                        Busdriver Plugin
───────────                        ────────────────

  User task ──► Orchestrator routes to pipeline phase
                    │
                    ├─► Phase 1-2: brainstorming / writing-plans
                    │     └─► Design Reviewer gates plan docs
                    │
                    ├─► Phase 3: git worktree isolation
                    │
                    ├─► Phase 4: TDD + domain skills + code review
                    │     ├─► Language patterns loaded by detection
                    │     ├─► tdd-guide agent enforces red/green/refactor
                    │     └─► {lang}-reviewer agent reviews every task
                    │
                    ├─► Phase 5: verification loop
                    │     ├─► build + lint + tests
                    │     └─► security-reviewer if auth/input/API touched
                    │
                    └─► Phase 6: finishing
                          ├─► git commit ──► Codex Reviewer (fast)
                          └─► gh pr create ──► Codex Reviewer (deep, 5 agents)

  Gate hooks (PreToolUse):
    ├── pre-commit gate ──► blocks until codex review passes
    ├── pre-PR gate ──► blocks until deep review passes
    ├── pre-implementation gate ──► blocks code while plans unreviewed
    └── freeze/guard ──► restricts edits during debugging

  PostToolUse hooks:
    ├── design doc detector ──► flags docs for review
    ├── go post-edit ──► gofmt/goimports/go vet
    └── post-commit cleanup ──► consumes review markers
```

### Skip / bypass

Gates have escape hatches for when you need them:

```bash
# Skip codex review (single-use, 30s self-bypass detection)
touch .claude/skip-codex-review.local

# Skip design review (single-use, 30s self-bypass detection)
touch .claude/skip-design-review.local

# Environment variable bypass
export SKIP_CODEX_REVIEW=1
export SKIP_DESIGN_REVIEW=1
```

Skip files are single-use (consumed after one bypass) and logged to `.claude/bypass-log.jsonl`. Files created within 30 seconds are rejected — this prevents Claude from creating skip files itself to bypass gates.

## Learning system

Busdriver learns from its mistakes:

- **Instincts** — Observed patterns from sessions, promoted after human review
- **Council** — 4-voice multi-perspective analysis (Architect + Skeptic + Pragmatist + Critic)
- **Lesson capture** — When review finds HIGH+ issues the plan missed, lessons are saved automatically
- **Reflection** — Manual `/reflect` skill for capturing corrections and feedback

## Credits

Built on the shoulders of:
- **[Superpowers](https://github.com/obra/superpowers)** by Jesse Vincent — the pipeline backbone
- **[Everything Claude Code](https://github.com/affaan-m/everything-claude-code)** by Affaan Mustafa — domain tools, hooks, and agents
- **[gstack](https://github.com/garrytan/gstack)** by Garry Tan — supplement patterns for security audit, QA, anti-sycophancy, and design quality
- **[Ralphinho RFC Pipeline](https://github.com/humanplane)** — multi-agent DAG execution and multi-model gate review patterns

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and guidelines.

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting.

## License

MIT
