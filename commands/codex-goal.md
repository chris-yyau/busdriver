---
description: Verifier-led iterative Codex handover — delegate a goal-shaped task to Codex with declarative pass/fail verifiers, returning the result to Claude Code for review. Foreground only; for fire-and-forget use TUI /goal.
argument-hint: "[--max-iters N] [--model M] [--effort E] <spec-file-or-inline-objective>"
allowed-tools: Read, Bash, Write
---

# /busdriver:codex-goal

Apply the `codex-goal-handover` skill.

User request:
$ARGUMENTS

## Routing

1. **If `$ARGUMENTS` references a spec file** (`.yaml`/`.yml`/`.md`) → invoke the skill directly with that path.
2. **If `$ARGUMENTS` is an inline task description** → before dispatching, help the user shape it into a spec with `objective`, `scope`, and `verifiable_end_state.verifiers` (declarative shell commands). Confirm the spec with the user (one round) before invoking the skill.
3. **If the task has no clean verifier commands** (open-ended investigation, judgment-heavy refactor) → suggest `/codex:rescue` instead. That is the one-shot path with no verifier requirement.
4. **If the task is hours-long and the user wants fire-and-forget** (manual pause/resume, no round-trip needed) → suggest opening a separate terminal, running `codex`, and using `/goal <spec>` directly. Zero CC quota cost; native budget guard. This slash command does not cover that case.

## Apply the skill

Invoke `codex-goal-handover` via the Skill tool with the validated spec. Follow the SKILL.md playbook strictly:

- Verifiers (not Claude, not Codex's self-report) decide completion.
- Per-iter commit checkpoint mandatory.
- Claude judges and steers only — never writes code in the loop.
- Default `max_iters=5`; hard cap 8. Forward `--max-iters`, `--model`, `--effort` to the helper as provided.

## When NOT to run this command

- Task can be done inline in ≤3 CC turns → just do it
- No clean pass/fail verifiers → `/codex:rescue`
- Multi-hour autonomous run preferred over round-trip → TUI `codex` + `/goal`
