---
name: dispatch-cli
description: >-
  Dispatch any task to Codex, Antigravity (agy), or Grok as an autonomous
  agent — analysis, audit, review, code changes, or any self-contained task.
  Triggers include send to codex/agy, dispatch to, external agent,
  second opinion. NOT for gate-specific reviews (litmus and blueprint-review
  own those).

---

# Dispatch CLI

Send any task to Codex, Antigravity (`agy`), or Grok as an autonomous agent. Unlike `litmus` and `blueprint-review` (which are gate-bound), this skill dispatches **any** work — audits, analysis, code changes, research, refactoring — without pipeline restrictions.

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
| High-stakes decisions | `both` | Codex + Agy consensus |
| Maximum coverage | `all` | All available CLIs in parallel (up to 3; `grok` is skipped in `auto` mode) |
| Quick analysis (either) | `auto` | Uses whichever is available |

### agy dispatch mechanics (plain `agy` and `agy-prose`)

> `agy-read` (ADR 0052) and `pi-read` (ADR 0060) were withdrawn; there is no read lane.
> These mechanics are the shared agy arm's and still apply to the reviewer
> slots and to `agy-prose`. `tests/test-agy-dispatch-arm.sh` pins them.

Plain `--cli agy` passes no `--model`, so the `blueprint-review.reviewer_1` and
`council.pragmatist` slots keep agy's own configured model; only `agy-prose`
reads a lane model key (`.writing_prose.model`, see `skills/writing-prose`).

**Two mechanics are load-bearing** (both measured 2026-08-17, both wired in):

| Flag | Why it cannot be dropped |
|------|--------------------------|
| `--add-dir "$PWD"` | Without it agy resolves its own remembered workspace. A dispatch from this repo answered out of a stale `~/src/busdriver` checkout with confident, correctly-formatted citations for the **wrong tree** — it does not error, it lies with citations. **On every agy dispatch since #686, with the one exception below** — plain `--cli agy` (`blueprint-review.reviewer_1`, `council.pragmatist`) gets the same flag so a reviewer of record cannot cite a remembered foreign tree. Every readonly agy dispatch also runs from a guard workspace (below), with `--add-dir` still naming the checkout; that is strictly narrower than running from the checkout itself, which is what these slots did before. (A 2026-10-10 probe on agy 1.3.2 found a hooks file in an `--add-dir` tree did not run; the 1.2.2 reproduction below found it did — do not rely on either.) **Exception — the agy >=1.2 stream-json review rung (#840):** there agy runs from a fresh `/tmp/agy-review-guard.*` git workspace holding a plugin-owned PreToolUse guard, and `--add-dir` names that workspace, never the checkout. A directory handed to agy as a workspace runs its repo-controlled `.agents/hooks.json` as host commands (reproduced on 1.2.2 with a hostile `--add-dir` tree), so adding the reviewed checkout is deliberately refused; files outside the workspace are still readable by absolute path, which is not confinement. |
| guard workspace (every readonly agy dispatch) | **`--sandbox` does NOT block writes.** A `--sandbox` probe asked to write created both `./scratch-probe.txt` and `/tmp/agy-write-probe.txt`. `--sandbox` is terminal restrictions, not a filesystem boundary. `--mode plan` blocked that probe on 2026-08-17 but **wrote into the checkout on 2026-10-10** (agy 1.3.2, `toolPermission: always-proceed`), and plain `--sandbox` (the council and reviewer slots' only flag) wrote into it too, so neither is a boundary. Every readonly agy dispatch — the prose lane, `council.pragmatist`, `blueprint-review.reviewer_1` — now runs from a fresh `/tmp/agy-review-guard.*` workspace holding the deny-by-default `agy-review-guard` PreToolUse hook, which denied both `write_to_file` and `call_mcp_tool` in the same session; `--add-dir "$PWD"` still names the checkout. The >=1.2 stream-json review rung keeps `--mode plan` alongside the same guard, unchanged: its result contract rejects any `denied_actions`, so dropping plan mode there could turn a reviewer's attempted write into a rejected review — untested, and left for a separate change. |

**Calibrate the write claim.** The guard is a hook agy runs, not a kernel
sandbox. Read it as best-effort defense in depth, not write-**proof**. agy also persists each conversation under
`~/.gemini/antigravity-cli/`, so the prompt and any repo content it quoted stay
on disk outside the repo.

**Hindsight memory is read-only for readonly dispatches.** Every `--mode readonly`
dispatch (council voices, reviewers, the prose lane) exports
`HINDSIGHT_RETAIN_SESSIONS=false` and `HINDSIGHT_AUTO_INJECT=pages`: a codex or agy
voice reads the project's knowledge pages but its transcript is never retained;
an inherited `HINDSIGHT_BANK_ID` is cleared first, and an operator's
`HINDSIGHT_DISABLED` is left alone. The
review launcher (`_portable_timeout --review`) applies the same pair to codex and to
agy, except on agy's stream rung: there it also pins the checkout's bank
(`HINDSIGHT_BANK_ID`), and when that bank cannot be derived it sends
`HINDSIGHT_DISABLED=1` instead, so Hindsight is off and no pages are read.
grok launches under `env -i` and does not receive the pair. It runs with
`HINDSIGHT_DISABLED=1`, so it neither reads Hindsight's hook context nor retains a
transcript: grok never shows SessionStart or UserPromptSubmit hook context to the
model (vectorize-io/hindsight#5467), so those hooks could only write. Instead,
busdriver fetches the prompt-matched pages outside grok's sandbox (read-only: no
seeding, retain or self-update) and passes them as `BUSDRIVER_GROK_HINDSIGHT`.

**grok memory hook (optional, operator-installed).** grok shows the model context
only from tool hooks, so `grok-hooks/busdriver-memory.py` runs on `PostToolUse` and,
once per session, hands grok its Claude Mem timeline (a GET to the local worker,
without the work-state block) and the prefetched Hindsight pages, each under grok's
10,000-character per-hook limit. It writes to neither. Install it as global hooks,
copied rather than symlinked:

```bash
mkdir -p ~/.grok/hooks
cp "${CLAUDE_PLUGIN_ROOT}"/skills/dispatch-cli/grok-hooks/busdriver-memory.{py,json} ~/.grok/hooks/
```

Global hooks run outside grok's permission rules, so installing one is the same
class of decision as adding a git hook. Without it, dispatched grok gets no memory.

**Claude Mem keeps its reads and drops its writes.** The same readonly
dispatches, both review launchers and the litmus Opus backstop set
`CLAUDE_MEM_DISABLE_OBSERVATION=1` and `CLAUDE_MEM_DISABLE_SUMMARY=1` (Claude Mem
13.38+). The session-start context still loads, but no observer LLM call runs per
tool use and the session ends without a summary. `--mode auto` dispatches are untouched.

**⚠️ Reads are not confined.** Assume agy can read any file your user account
can, including gitignored ones by absolute path (it demonstrably reaches outside
the tree — it wrote to `/tmp` when it could write). Everything it reads is
transmitted to Google. Gate on **who wrote the content**, not on where it sits.

## Execution Modes

| Mode | What happens | When to use |
|------|-------------|-------------|
| `readonly` (default) | Read-only intent* | Analysis, audit, review |
| `auto` | Full auto-approve — can make changes | Refactoring, code generation |

\* Strength varies by CLI — see [Per-CLI sandboxing strength](#per-cli-sandboxing-strength) below.

**Safety**: ALWAYS default to `readonly`. Only use `auto` when the user explicitly requests file changes.

### Per-CLI sandboxing strength

| CLI | Readonly mechanism | Strict sandbox? |
|-----|-------------------|-----------------|
| codex | `-s read-only` | ⚠️  **unverified** — measured writing files anyway on codex-cli 0.147.0. See below |
| agy | `--sandbox` (omit `--dangerously-skip-permissions`) | ✅ yes (terminal-restricted sandbox) |
| grok | `--sandbox busdriver-review` (custom kernel profile) + `--deny Bash(*)/Edit/MCPTool(*)` + vendor hook switches | ✅ yes — reads kernel-confined to CWD; **requires one-time operator setup, see below** |

**grok requires `~/.grok/sandbox.toml` — the lane refuses to dispatch without it.**
Copy `docs/examples/grok-sandbox.toml` to `~/.grok/sandbox.toml` (edit the absolute
home paths in its `deny` list) before using `--cli grok`, or the dispatcher exits with
`grok dispatch refused — the operator sandbox profile is missing or does not meet the
contract` (`grok_preflight_hint`'s `WHY=profile` branch, `scripts/lib/resolve-cli.sh`).

That extra step buys the only fail-CLOSED posture grok offers. Measured 2026-08-19:

| Property | Built-in profile | `busdriver-review` (custom) |
|---|---|---|
| Kernel policy cannot be applied | **warns and runs unconfined** | **refuses to start** |
| Definition can come from the reviewed repo | n/a | no — grok's sandbox docs give the user file precedence over a project `.grok/sandbox.toml` of the same name, and busdriver's preflight independently requires the user file to exist and meet the contract, so the repo copy is never what is trusted |
| `~/.ssh` readable | yes under `readonly` (returned a full key listing) | no — `Permission denied` |
| In-tree hook sources readable | yes | no — kernel-denied, so a branch-planted hook cannot load |
| Shell / writes / MCP | policy-dependent | denied by the three `--deny` rules |

Residual, unchanged: network egress is not blocked on macOS and grok's own web tools
stay open, so CWD-readable content can still leave. With the memory hook installed
(below), so can the injected Claude Mem timeline and Hindsight pages; codex and agy
readonly dispatches already carry the same memory context. Gate the lane on **who wrote
the content**, exactly as for agy.

**Codex caveat — `-s read-only` was observed NOT confining.** Measured 2026-08-09 on
**codex-cli 0.147.0**, workdir a fresh `mktemp -d` outside any git checkout (so this is
not an enclosing-repo effect), via `codex exec -s <mode> -C <workdir> --skip-git-repo-check`:

| Probe | Result |
|-------|--------|
| `-s read-only`, asked to write a file **inside** its own workdir | **wrote it** — replied `DONE` |
| `-s read-only`, asked to write **outside** the workdir | **wrote it** |
| `-s workspace-write`, asked to write **outside** the workdir | **wrote it** |

Codex's own run summary still reported the workspace that was asked for, so its
self-report does not surface this — the write has to be checked for on disk.

**The cause is NOT established, so do not treat any config edit as the fix.** Deleting
the `[projects."/"] trust_level = "trusted"` entry from `$CODEX_HOME/config.toml` was
tried and did **not** restore confinement: with it gone, both the workspace-write
outside-write and the read-only inside-write still succeeded. Note also that codex
**adds a `[projects."<dir>"]` trust entry for a directory it is run in**, so the absence
of an entry beforehand does not mean the path stays untrusted for the run.

What follows from this, and only this:

- **Verify, do not assume.** Before relying on the `readonly` row above as a security
  boundary, run the probe on your own machine and check the filesystem — not the reply.
- **This affects who can review what.** litmus pins codex as its PR-mode lead reviewer
  partly on the assumption that `-s read-only` confines it. On the configuration
  measured above it does not.
- `busdriver:imagegen` already assumes the worst here: its codex route is gated behind
  `CODEX_UNCONFINED_OK=1`, and its block defaults to `agy` — whose `--sandbox` at least
  confines WRITES as documented, which is not the same as isolation (no provider there
  confines reads). Note what that
  flag does and does not say — it is the operator ACCEPTING an unconfined agent, not
  certifying confinement, because no `-s` value was found that reliably confines codex.

For strict read-only guarantees, dispatch to `agy` — **not** `codex`, whose `-s read-only`
was measured writing files anyway (see the Codex caveat above; this line used to name both).

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
| `--cli` | `codex`, `agy`, `agy-prose`, `grok`, `both`, `all`, `auto` | `auto` |
| `--mode` | `readonly`, `auto` | `readonly` |
| `--timeout` | seconds | `600` |
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
A run that ends in `error` or `timeout` also has its output archived to
`~/.claude/homunculus/failures/` (mode 600, in a mode-700 directory), and the log
entry's `output_file` points there rather than at the `$TMPDIR` original — which
the OS reaps and a reboot wipes, so a failure's only diagnostic used to disappear
before anyone read it. The archive keeps the **last** 64KB: a CLI appends its
fatal error after its normal output, so capping from the front would preserve
everything except the failure cause.

## Reading code is not a dispatch

No CLI here is a read lane (`agy-read` withdrawn in ADR 0052, `pi-read` in ADR 0060).
To keep large reads out of context, use `codegraph_explore` first and an Explore
subagent for a broad sweep — see the reading rule in `.claude/CLAUDE.md`.
Everything any lane here reads is sent to that lane's provider, so the
provenance and confidentiality questions still apply to every dispatch: does
everything the prompt can reach trace back to an author you trust, and are you
willing to send it — untracked files included — to that third party?

## Error Handling

| Situation | What happens |
|-----------|-------------|
| CLI not found | Script falls back to other CLI (auto mode) or errors clearly |
| Timeout (default 10min) | Script returns timeout status, partial output if any |
| CLI error | Script captures stderr, returns error status |
| Empty output | Script notes "(no output)" — may need a better prompt |
| Setup precondition unmet | Script returns **`skipped`** status — see below |

### `skipped` vs `error` (#594)

A voice that refuses to run on a **deterministic precondition** — grok with no usable sandbox profile, or a `--model` grok cannot accept — reports `skipped`, not `error`. It never ran, so
it is not a failed attempt, and the two carry different consequences:

| Invocation | A skipped voice means |
|------------|----------------------|
| `--cli grok` (explicit) | **Failure**, exit non-zero — the voice you asked for is the whole request |
| `--cli all` (batch) | **Not a failure** — the voice drops out, the batch succeeds on the others |
| `--cli all`, every voice skipped | **Failure**, exit non-zero — nothing ran, and nothing must never read as success |

A voice that genuinely ran and failed still fails the batch, exactly as before.
`skipped` is recorded verbatim in the dispatch log, so an audit distinguishes
"never attempted" from "attempted and failed".

Only the grok arm currently produces a `skipped`; the status itself is shared by every CLI.

If a dispatch fails, check:
1. Is the CLI installed? (`which codex`, `which agy`)
2. Is the prompt clear enough?
3. Does the timeout need extending for complex tasks?
4. Try the other CLI as fallback
