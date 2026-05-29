# Automatic Behaviors (Hooks)

> Reference table of hook-driven behaviors. Read when you need to know which hook does what. The orchestrator's inline section in `orchestrator/SKILL.md` carries only a pointer here.

| Phase | Hook | Enforcement | What It Does |
|-------|------|-------------|-------------|
| **SessionStart** | Plugin update checker | context | Emits `<update-alert>` after task completes |
| **SessionStart** | Orchestrator loader | context | Loads this skill + staleness + instincts |
| **PreToolUse** (Bash) | Pre-commit gate | **GATE** | Blocks `git commit` until litmus + design review pass |
| **PreToolUse** (Bash) | Pre-PR gate | **GATE** | Blocks `gh pr create` until litmus passes |
| **PreToolUse** (Write\|Edit\|MultiEdit\|Bash) | Pre-implementation gate (Blueprint Review) | **GATE** | Blocks impl while design/plan docs are unreviewed — enforces the Blueprint Review gate |
| **PreToolUse** (Bash) | Pre-merge gate | **GATE** | Blocks `gh pr merge` until pr-grind clean |
| **PreToolUse** (Write\|Edit\|MultiEdit) | Freeze/Guard | **GATE** | Restricts edits to investigation scope |
| **PostToolUse** (Write\|Edit\|Bash) | Design doc detector | state | Flags design/plan docs that trigger the Blueprint Review gate above (review via `blueprint-review`) |
| **PostToolUse** (Edit) | Go post-edit | formatting | gofmt/goimports/go vet |
| **PostToolUse** (Bash) | Post-commit marker | cleanup | Consumes litmus marker after commit |
| **SessionEnd** | Auto-push config | persistence | Commits pipeline state to remote |

Inherited hooks (ECC upstream): quality-gate, cost-tracker, session persistence, post-edit format (JS/TS), suggest-compact, block-no-verify, auto-tmux-dev, config-protection, mcp-health-check, observe.sh.
