---
name: dispatch-cli
description: >
  Dispatch any task to Codex CLI or Gemini CLI as an autonomous agent.
  Use when needing an external AI to perform analysis, audit, review, code changes,
  or any self-contained task. Triggers: "send to codex/gemini", "dispatch to",
  "have codex/gemini do", "external agent", "second opinion", general audits,
  or when a task would benefit from independent external execution.
  NOT for gate-specific reviews (use codex-reviewer or design-reviewer for those).
---

# Dispatch CLI

Send any task to Codex or Gemini CLI as an autonomous agent. Unlike `codex-reviewer` and `design-reviewer` (which are gate-bound), this skill dispatches **any** work — audits, analysis, code changes, research, refactoring — without pipeline restrictions.

## When to Use

- **General audits** — audit code, configs, scripts without gate constraints
- **Second opinions** — independent analysis from another AI
- **Parallel sub-tasks** — dispatch work while continuing your own
- **Specialized analysis** — deep dive into a specific area
- **Code changes via external agent** — refactoring, fixes, generation
- **Any self-contained task** you can describe in a prompt

## When NOT to Use

- Pre-commit code review → use `codex-reviewer` (gate-enforced)
- Design/plan doc review → use `design-reviewer` (gate-enforced)
- Tasks requiring Claude Code's specific tools (MCP, web search, etc.)

## CLI Selection

| Task Type | CLI | Rationale |
|-----------|-----|-----------|
| Code audit, bug hunting | `codex` | Deep code reasoning, tool use |
| Architecture analysis | `gemini` | Broad strategic thinking |
| High-stakes decisions | `both` | Consensus from two perspectives |
| Code changes, refactoring | `codex` | Better at precise edits |
| Research, synthesis | `gemini` | Good at connecting patterns |
| Quick analysis (either) | `auto` | Uses whichever is available |

## Execution Modes

| Mode | What happens | When to use |
|------|-------------|-------------|
| `readonly` (default) | Sandbox — cannot modify files | Analysis, audit, review |
| `auto` | Full auto-approve — can make changes | Refactoring, code generation |

**Safety**: ALWAYS default to `readonly`. Only use `auto` when the user explicitly requests file changes.

## How to Dispatch

### Step 1: Construct the Prompt

This is where the value is. A well-constructed prompt is the difference between useful output and noise.

**Structure every prompt like this:**

```
## Task
[One clear sentence: what to do]

## Scope
[Specific files, directories, or areas to focus on]

## Focus Areas
[What specifically to look for or produce]

## Output Format
[How to structure the response — report, JSON, list, etc.]

## Constraints
[What NOT to do, boundaries]
```

**Example — Audit prompt:**
```
## Task
Audit the shell scripts under ${CLAUDE_PLUGIN_ROOT}/hooks/gate-scripts/ for correctness, edge cases, and bugs.

## Scope
All .sh files in ${CLAUDE_PLUGIN_ROOT}/hooks/gate-scripts/ and ~/.claude/skills/*/scripts/

## Focus Areas
- Race conditions in concurrent operations
- Unhandled edge cases (empty inputs, missing files)
- Shell quoting issues
- Error handling gaps

## Output Format
Severity-ranked report: CRITICAL > HIGH > MEDIUM > LOW
Each finding: file, line, severity, description, suggested fix.

## Constraints
Read-only analysis. Do not modify any files.
```

**Example — Code change prompt:**
```
## Task
Refactor the pre-commit gate to extract shared JSON-emitting logic into a helper function.

## Scope
${CLAUDE_PLUGIN_ROOT}/hooks/gate-scripts/pre-commit-gate.sh

## Focus Areas
- Extract shared logic into helper functions
- Maintain identical behavior (no functional changes)
- Keep the fail-closed guarantee

## Output Format
Make the changes directly. Show a summary of what changed.

## Constraints
Do not change any external interfaces. Gate behavior must remain identical.
```

### Step 2: Invoke the Script

```bash
# Single CLI, read-only (default and safest)
~/.claude/skills/dispatch-cli/scripts/dispatch.sh \
  --cli codex \
  --prompt "Your task description here"

# Both CLIs for consensus (parallel execution)
~/.claude/skills/dispatch-cli/scripts/dispatch.sh \
  --cli both \
  --prompt "Your task description here"

# Write mode (user explicitly requested changes)
~/.claude/skills/dispatch-cli/scripts/dispatch.sh \
  --cli codex \
  --mode auto \
  --prompt "Your task description here"

# With model override and custom timeout
~/.claude/skills/dispatch-cli/scripts/dispatch.sh \
  --cli gemini \
  --model gemini-2.5-pro \
  --timeout 600 \
  --prompt "Your task description here"
```

**Script flags:**
| Flag | Values | Default |
|------|--------|---------|
| `--cli` | `codex`, `gemini`, `both`, `auto` | `auto` |
| `--mode` | `readonly`, `auto` | `readonly` |
| `--timeout` | seconds | `300` |
| `--model` | model name | CLI default |
| `--prompt` | task description | (or pipe stdin) |

### Step 3: Process the Output

- **Single CLI**: Output prints to stdout. Read it and summarize key findings.
- **Both CLIs**: Output shows labeled sections for each. Synthesize a consensus view — where they agree is high confidence, where they disagree warrants investigation.
- **Raw output saved** to `/tmp/dispatch-{cli}-{timestamp}.txt` for reference.

After dispatch:
1. Read the output carefully
2. Summarize key findings for the user
3. If actionable items exist, propose next steps
4. If "both" mode, highlight agreements and disagreements

## Dispatch Patterns

### Pattern: Quick Analysis
One CLI, readonly, focused question.
```bash
dispatch.sh --cli codex --prompt "What does the observe-session.sh hook do? Explain its data flow."
```

### Pattern: Consensus Audit
Both CLIs, readonly, comprehensive review.
```bash
dispatch.sh --cli both --prompt "Audit the pre-commit gate for security issues and bypass vectors."
```

### Pattern: Delegated Code Change
One CLI, auto mode, well-scoped change.
```bash
dispatch.sh --cli codex --mode auto --prompt "Add input validation to dispatch.sh for the --timeout flag (must be positive integer)."
```

### Pattern: Research
One CLI, readonly, open-ended exploration.
```bash
dispatch.sh --cli gemini --prompt "Analyze the instinct learning system and suggest improvements to the confidence scoring algorithm."
```

## Integration

This skill is **not pipeline-bound**. Use it from anywhere:
- During Phase 1 (brainstorming) — get external perspective
- During Phase 4 (execution) — dispatch sub-tasks
- Outside the pipeline — general analysis, audits
- Within other skills — as a building block

Dispatch events log to `~/.claude/homunculus/dispatch-log.jsonl` for auditing.

## Error Handling

| Situation | What happens |
|-----------|-------------|
| CLI not found | Script falls back to other CLI (auto mode) or errors clearly |
| Timeout (default 5min) | Script returns timeout status, partial output if any |
| CLI error | Script captures stderr, returns error status |
| Empty output | Script notes "(no output)" — may need a better prompt |

If a dispatch fails, check:
1. Is the CLI installed? (`which codex`, `which gemini`)
2. Is the prompt clear enough?
3. Does the timeout need extending for complex tasks?
4. Try the other CLI as fallback
