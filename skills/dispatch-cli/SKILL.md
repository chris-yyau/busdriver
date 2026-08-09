---
name: dispatch-cli
description: >-
  Dispatch any task to Codex, Antigravity (agy), or Droid CLI as an autonomous
  agent — analysis, audit, review, code changes, or any self-contained task.
  Triggers include send to codex/agy/droid, dispatch to, external agent,
  second opinion. NOT for gate-specific reviews (litmus and blueprint-review
  own those).

---

# Dispatch CLI

Send any task to Codex, Antigravity (`agy`), or Droid CLI as an autonomous agent. Unlike `litmus` and `blueprint-review` (which are gate-bound), this skill dispatches **any** work — audits, analysis, code changes, research, refactoring — without pipeline restrictions.

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
| **Repo tracing / "how does X work"** | **`pi`** | **Reads the working tree and returns a cited summary — see below** |
| High-stakes decisions | `both` | Codex + Agy consensus |
| Maximum coverage | `all` | All available CLIs in parallel (up to 6; `grok`, `opencode` and `pi` are skipped in `auto` mode) |
| Quick analysis (either) | `auto` | Uses whichever is available |

### `pi` — the in-tree read lane

Every other read-only lane is confined to an empty directory so the checkout
cannot redefine the reviewer. `pi` is the exception: it runs **in the working
tree**, because tracing real code is the point. Use it to answer "how does X
work", map a subsystem, or triage a diff — then verify the `file:line` citations
it returns rather than reading the files yourself. That is the whole saving:
reading is ~86% of a Claude session's token consumption.

Containment moves to the toolset instead of the directory: a positive allowlist
(`--tools read`) plus six project-config kill switches. It is read-only by
construction — `--mode` is ignored and `pi` is skipped in `--cli all --mode auto`.

```bash
skills/dispatch-cli/scripts/dispatch.sh --cli pi \
  --prompt "trace how the pr-grind dispatcher decides fix vs wait round"
```

**Model** — set once in `~/.claude/busdriver.json`:

```json
{ "pi": { "model": "<provider>/<model-id>" } }
```

Same trust rules as `.auditor.model` (USER config only, no env override): the
value names the third party your repo's source is shipped to. `pi --list-models`
enumerates ids; `pi auth check --provider <name>` confirms one is reachable. If a
run returns an empty answer, read the transcript — provider errors (e.g. a
region-gated model returning HTTP 403) are surfaced there, not swallowed.

**⚠️ Read confinement — know this before use.** `--tools read` blocks writes
(verified in both directions). It does **not** confine reads: pi's read tool
accepts absolute paths. The arm therefore runs pi under a projected private
`$HOME` containing only the selected provider's credential, so `~/.ssh`,
`~/.aws`, `~/.claude` and your other provider keys are not reachable via `~`.
That shrinks blast radius — it does not close the hole. **Assume an injection in
repo content can reach any file your user account can read**: absolute paths are
served, and `/etc/passwd` discloses your real home, making `~/.ssh/id_rsa` and
`~/.aws/credentials` predictable from inside the jail. **Do not point this lane
at a checkout you would not run.**

A failed pi never escalates to droid (unlike other voices): you chose the
provider at `.pi.model`, so a silent re-send elsewhere would defeat that choice.

Rationale, the residual, and the removed-as-vacuous injection test:
`docs/adr/0034-pi-in-tree-read-lane.md`.

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
| pi | `--tools read` (positive allowlist) + 6 project-config kill switches + projected private `$HOME` | ⚠️  **no** — writes are blocked, **reads are not confined**. See below |

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

For strict read-only guarantees, dispatch to `codex` or `agy` instead. (Litmus/santa/blueprint-review backends use bare `droid exec` — default read-only mode with Create/Edit blocked — via `scripts/lib/resolve-cli.sh::execute_review`. Empirically verified on droid v0.131.0+; earlier versions per PR #97 required `--auto low` because bare `droid exec` bailed on stdin pipe. `DROID_AUTO_LEVEL` does NOT apply to that path.)

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
| Setup precondition unmet | Script returns **`skipped`** status — see below |

### `skipped` vs `error` (#594)

A voice that refuses to run on a **deterministic precondition** — an unprobed pi
version, a model reference with no `provider/` prefix, a provider whose
credential cannot be projected — reports `skipped`, not `error`. It never ran, so
it is not a failed attempt, and the two carry different consequences:

| Invocation | A skipped voice means |
|------------|----------------------|
| `--cli pi` (explicit) | **Failure**, exit non-zero — the voice you asked for is the whole request |
| `--cli all` (batch) | **Not a failure** — the voice drops out, the batch succeeds on the others |
| `--cli all`, every voice skipped | **Failure**, exit non-zero — nothing ran, and nothing must never read as success |

A voice that genuinely ran and failed still fails the batch, exactly as before.
`skipped` is recorded verbatim in the dispatch log, so an audit distinguishes
"never attempted" from "attempted and failed".

Only the pi arm can currently produce a `skipped`; the status itself is shared by
every CLI.

If a dispatch fails, check:
1. Is the CLI installed? (`which codex`, `which agy`)
2. Is the prompt clear enough?
3. Does the timeout need extending for complex tasks?
4. Try the other CLI as fallback
