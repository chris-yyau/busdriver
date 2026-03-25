# Orchestrator: Master Skill Router for Claude Code

A unified routing system that intelligently directs tasks to the appropriate skills across 4 distinct skill systems.

## What It Does

The orchestrator replaces `using-superpowers` as your primary skill router, providing:

- **Unified routing** across 4 distinct skill systems
- **Mandatory review gates** that ensure quality (codex-reviewer, design-reviewer)
- **Smart deduplication** when skills overlap between systems
- **Cascade matching** with language/framework detection
- **1% threshold routing** - if there's even a 1% chance a skill applies, it gets invoked

## Quick Start

1. **Install the skill:**
   ```bash
   # Skill files already created at:
   # ${CLAUDE_PLUGIN_ROOT}/skills/orchestrator/SKILL.md
   # ${CLAUDE_PLUGIN_ROOT}/skills/orchestrator/INSTALL.md
   # ${CLAUDE_PLUGIN_ROOT}/skills/orchestrator/README.md
   ```

2. **Configure as SessionStart hook:**
   ```bash
   # Add to ~/.claude/settings.json
   {
     "hooks": {
       "SessionStart": [{
         "command": "Skill",
         "arguments": {"skill": "orchestrator"},
         "description": "Load master orchestrator"
       }]
     }
   }
   ```

3. **Remove using-superpowers hook** if present (orchestrator replaces it)

## How It Routes

### 1. Mandatory Gates (Blocking)
- **Pre-commit**: Invokes `codex-reviewer` before any git commit/push/deploy
- **Post-planning**: Invokes `design-reviewer` after writing plans/designs

### 2. Process Skills (Lifecycle)
- **Ideation**: Routes to `busdriver:brainstorming`
- **Planning**: Routes to `busdriver:writing-plans`
- **Execution**: Routes to `executing-plans` or `subagent-driven-development`
- **Verification**: Routes to `verification-before-completion`
- **Integration**: Routes to `finishing-a-development-branch`

### 3. Task-Specific Routing
- **Debugging**: → `systematic-debugging`
- **Testing/TDD**: → `test-driven-development` + language-specific
- **Refactoring**: → `refactor-cleaner`
- **Security**: → `security-reviewer` + framework-specific

### 4. Language Detection
- **Go**: golang-patterns, golang-testing, go-reviewer
- **Python**: python-patterns, python-testing, python-reviewer
- **Swift**: rules/swift/*, swiftui-patterns, swift-concurrency-6-2, swift-protocol-di-testing
- **Django**: django-patterns, django-security, django-tdd
- **Spring Boot**: springboot-patterns, springboot-security, springboot-tdd
- **Frontend**: frontend-patterns, coding-standards, next-best-practices
- **C++**: cpp-coding-standards, cpp-testing
- **Database**: postgres-patterns, clickhouse-io, database-migrations

## Example Routing

```
User: "Let's build a user authentication system"
→ Orchestrator detects: New feature (ideation phase)
→ Routes to: busdriver:brainstorming
→ Then automatically: busdriver:writing-plans
→ After plan written: design-reviewer (mandatory gate)
→ During implementation: test-driven-development
→ Before commit: codex-reviewer (mandatory gate)
```

## Key Features

### Intelligent Deduplication

When skills overlap, orchestrator picks the best:
- TDD: Uses superpowers version (more comprehensive)
- Code review: Uses codex-reviewer (mandatory) + language-specific
- Planning: Uses superpowers flow (brainstorming → writing-plans)

### Cascade Matching

Checks in order:
1. Mandatory gates (always)
2. Lifecycle phase
3. Task type
4. Language/framework
5. Utilities

### Precedence Rules

1. **Mandatory gates** (highest priority)
2. **Superpowers process skills**
3. **ECC specialized agents**
4. **ECC command shortcuts**
5. **Domain-specific skills**
6. **General utilities**

## The 4 Skill Systems

### System 1: Superpowers (14 skills)
- Process workflow skills (brainstorming, planning, execution)
- Development lifecycle management (debugging, TDD, verification)
- Git and agent orchestration

### System 2: Everything Claude Code (50 skills + 33 commands + 13 agents)
- Language-specific patterns and testing (Go, Python, Swift, Django, Spring Boot, C++)
- Specialized agents (build-error-resolver, refactor-cleaner, security-reviewer, database-reviewer)
- Command shortcuts (/tdd, /e2e, /orchestrate, /verify)

### System 3: Codex Reviewer (standalone skill)
- Mandatory pre-commit/pre-deploy gate
- Reviewer: Codex CLI (technical code review)
- Auto-iterates up to 10 cycles until PASS

### System 4: Design Reviewer (standalone skill)
- Mandatory post-planning gate
- Reviewers: Gemini + Codex + Claude — three-tier consensus
- All three must return PASS before implementation proceeds

## Customization

### Add Custom Routes

Edit `${CLAUDE_PLUGIN_ROOT}/skills/orchestrator/SKILL.md` and add entries to the appropriate section (Non-Pipeline Tasks, Domain Supplements, or Cross-Cutting Utilities) using the same markdown format as existing entries.

### Disable Specific Routes

Comment out or remove entries in the routing tables within SKILL.md.

## Troubleshooting

**Orchestrator not loading?**
- Check SessionStart hook in settings.json
- Verify skill file exists
- Ensure using-superpowers hook is removed

**Skills routing twice?**
- Check for duplicate hooks
- Verify deduplication rules
- Remove redundant skill invocations

**Missing a route?**
- Check skill is installed
- Verify skill name matches exactly
- Add explicit routing rule if needed

## Architecture

```
┌─────────────────────┐
│   User Request      │
└──────────┬──────────┘
           ▼
┌─────────────────────┐
│   Orchestrator      │
│  (Cascade Matcher)  │
└──────────┬──────────┘
           ▼
    ┌──────────────┐
    │ Check Gates  │──► Blocking?──► Run Gate
    └──────┬───────┘
           ▼
    ┌──────────────┐
    │ Match Phase  │──► Found?──► Route to Process Skill
    └──────┬───────┘
           ▼
    ┌──────────────┐
    │ Match Task   │──► Found?──► Route to Task Skill
    └──────┬───────┘
           ▼
    ┌──────────────┐
    │Match Language│──► Found?──► Route to Domain Skill
    └──────┬───────┘
           ▼
    ┌──────────────┐
    │   Utilities  │──► Found?──► Route to Utility
    └──────┬───────┘
           ▼
    ┌──────────────┐
    │ Execute Task │
    └──────────────┘
```

## Philosophy

The orchestrator embodies three principles:

1. **1% Threshold**: If there's even a 1% chance a skill applies, route to it
2. **Gates Before Code**: Mandatory reviews prevent bad code from entering the system
3. **Process Over Improvisation**: Structured workflows (brainstorming→planning→execution) produce better results

## Credits

Built to unify:
- **Superpowers** by [affaanmustafa](https://x.com/affaanmustafa)
- **Everything Claude Code** by [affaanmustafa](https://x.com/affaanmustafa)
- **Codex & Design Reviewers** (standalone skills)

## License

Same as your Claude Code configuration.