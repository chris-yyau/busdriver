---
name: dispatch-cli
description: >
  Dispatch any task to Codex CLI or Antigravity (agy) CLI as an autonomous agent.
  Use when needing an external AI to perform analysis, audit, review, code changes,
  or any self-contained task. Triggers: "send to codex/agy", "dispatch to",
  "have codex/agy do", "external agent", "second opinion", general audits,
  or when a task would benefit from independent external execution.
  NOT for gate-specific reviews (use litmus or blueprint-review for those).
---

# Dispatch CLI

Send any task to Codex or Antigravity (`agy`) CLI as an autonomous agent. Unlike `litmus` and `blueprint-review` (which are gate-bound), this skill dispatches **any** work — audits, analysis, code changes, research, refactoring — without pipeline restrictions.

## When to Use

- **General audits** — audit code, configs, scripts without gate constraints
- **Second opinions** — independent analysis from another AI
- **Parallel sub-tasks** — dispatch work while continuing your own
- **Specialized analysis** — deep dive into a specific area
- **Code changes via external agent** — refactoring, fixes, generation
- **Any self-contained task** you can describe in a prompt

## When NOT to Use

- Pre-commit code review → use `litmus` (gate-enforced)
- Design/plan doc review → use `blueprint-review` (gate-enforced)
- Tasks requiring Claude Code's specific tools (MCP, web search, etc.)

## CLI Selection

| Task Type | CLI | Rationale |
|-----------|-----|-----------|
| Code audit, bug hunting | `codex` | Deep code reasoning, tool use |
| Architecture analysis | `agy` | Broad strategic thinking |
| Fast autonomous agent | `droid` | Lightweight, fast execution |
| High-stakes decisions | `both` | Codex + Agy consensus |
| Maximum coverage | `all` | Top 3 available CLIs in parallel |
| Quick analysis (either) | `auto` | Uses whichever is available |

## Execution Modes

| Mode | What happens | When to use |
|------|-------------|-------------|
| `readonly` (default) | Read-only intent* | Analysis, audit, review |
| `auto` | Full auto-approve — can make changes | Refactoring, code generation |

\* Strength varies by CLI — see [Per-CLI sandboxing strength](#per-cli-sandboxing-strength) below. Droid in particular lacks a strict sandbox.

**Safety**: ALWAYS default to `readonly`. Only use `auto` when the user explicitly requests file changes.

### Per-CLI sandboxing strength

| CLI | Readonly mechanism | Strict sandbox? |
|-----|-------------------|-----------------|
| codex | `-s read-only` | ✅ yes (kernel-enforced sandbox) |
| agy | `--sandbox` (omit `--dangerously-skip-permissions`) | ✅ yes (terminal-restricted sandbox) |
| droid | `--auto high` (permission tier) | ⚠️  **no** — see below |

**Droid caveat:** droid has no strict readonly mode. Its `--auto low|medium|high` are permission tiers that control whether it prompts on permission checks (without any flag, droid bails on first read under stdin redirection). Tier semantics from `droid exec --help`:

| Tier | Capabilities |
|------|--------------|
| `low` | File writes in non-system dirs only (no installs, no git, no network) |
| `medium` | + package installs, trusted-host curl/wget, local git (commit/checkout/pull) |
| `high` | + git push --force, curl/wget to arbitrary hosts, secrets, prod deploys |

**Dispatch tier mapping** (override per-call with the `DROID_AUTO_LEVEL` env var):

| Dispatch mode | Droid tier | Rationale |
|---------------|-----------|-----------|
| `readonly` | `--auto high` | Council Researcher reliably needs `high` for web fetches; `medium` bails. Tighten via `DROID_AUTO_LEVEL=low\|medium` if your dispatch doesn't need web access |
| `auto` | `--auto high` | User opted into changes; covers codegen/research/network ops |

**Empirical note:** council Researcher prompts (web fetches, API lookups) reliably require `--auto high`; `medium` bails with "Re-run with --auto high." Defaulting both dispatch modes to `high` removes the need to set `DROID_AUTO_LEVEL=high` per-call for council runs.

> **Security Warning:** `DROID_AUTO_LEVEL` overrides the dispatch default and applies to ALL `dispatch.sh` invocations in the current shell environment. A globally-exported `DROID_AUTO_LEVEL=high` (now the default if unset) keeps dispatches at the relaxed tier. `--auto high` enables potentially destructive operations (git push --force, curl|bash, secrets access). For stricter isolation, set `DROID_AUTO_LEVEL=low` or `medium` per-command and unset immediately after use. The dispatch script validates that only `low`, `medium`, or `high` are accepted values.

For strict read-only guarantees, dispatch to `codex` or `agy` instead. (Litmus/santa/blueprint-review backends use the tighter `--auto low` via `scripts/lib/resolve-cli.sh::execute_review` — review prompts emit JSON verdicts and never need writes/installs/network. `DROID_AUTO_LEVEL` does NOT apply to that path.)

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

**Use heredocs for multi-line prompts** (safe with quotes, backticks, `$`, newlines):
```bash
# Single CLI, read-only (default and safest)
~/.claude/skills/dispatch-cli/scripts/dispatch.sh \
  --cli codex \
  --timeout 300 <<'PROMPT'
Your task description here.
Can contain "quotes", `backticks`, $variables safely.
PROMPT

# Both CLIs for consensus (parallel execution)
~/.claude/skills/dispatch-cli/scripts/dispatch.sh \
  --cli both <<'PROMPT'
Your task description here
PROMPT

# Write mode (user explicitly requested changes)
~/.claude/skills/dispatch-cli/scripts/dispatch.sh \
  --cli codex \
  --mode auto <<'PROMPT'
Your task description here
PROMPT

# With custom timeout (agy v1.0.0 does not support --model)
~/.claude/skills/dispatch-cli/scripts/dispatch.sh \
  --cli agy \
  --timeout 600 <<'PROMPT'
Your task description here
PROMPT
```

> **Shell escaping warning:** `--prompt "..."` is only safe for simple single-line text without quotes, backticks, or `$`. For real prompts (which almost always contain these), use heredocs (`<<'DELIM'`) or pipe via stdin. The single-quoted delimiter prevents all shell expansion.

**Script flags:**
| Flag | Values | Default |
|------|--------|---------|
| `--cli` | `codex`, `agy`, `droid`, `both`, `all`, `auto` | `auto` |
| `--mode` | `readonly`, `auto` | `readonly` |
| `--timeout` | seconds | `300` |
| `--model` | model name | CLI default |
| `--prompt` | task description | (or pipe stdin) |

### Step 3: Process the Output

- **Single CLI**: Output prints to stdout. Read it and summarize key findings.
- **Both CLIs**: Output shows labeled sections for each (Codex + Agy). Synthesize a consensus view — where they agree is high confidence, where they disagree warrants investigation.
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
dispatch.sh --cli codex <<'PROMPT'
What does the observe-session.sh hook do? Explain its data flow.
PROMPT
```

### Pattern: Consensus Audit
Both CLIs, readonly, comprehensive review.
```bash
dispatch.sh --cli both <<'PROMPT'
Audit the pre-commit gate for security issues and bypass vectors.
PROMPT
```

### Pattern: Delegated Code Change
One CLI, auto mode, well-scoped change.
```bash
dispatch.sh --cli codex --mode auto <<'PROMPT'
Add input validation to dispatch.sh for the --timeout flag (must be positive integer).
PROMPT
```

### Pattern: Research
One CLI, readonly, open-ended exploration.
```bash
dispatch.sh --cli agy <<'PROMPT'
Analyze the instinct learning system and suggest improvements to the confidence scoring algorithm.
PROMPT
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
1. Is the CLI installed? (`which codex`, `which agy`)
2. Is the prompt clear enough?
3. Does the timeout need extending for complex tasks?
4. Try the other CLI as fallback
