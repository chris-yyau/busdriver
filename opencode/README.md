# Busdriver — opencode port

A port of four busdriver features to the [opencode](https://opencode.ai) harness:

| Feature | Skill | What it does |
|---------|-------|--------------|
| **litmus** | `/litmus` | Code-review gate before commit / PR |
| **blueprint-review** | `/blueprint-review` | Three-tier design-doc review (Agy + Codex + Grok → arbiter) |
| **council** | `/council` | Five-voice multi-perspective analysis |
| **pr-grind** | `/pr-grind` | Iterative post-PR feedback loop (dispatches the `pr-grinder` worker per round) |

> This subtree is a **downstream mirror**. The source-of-truth skills/agents/scripts live at the busdriver repo root; the files here are the opencode-flavored copies plus the `plugin.ts` gate-bridge. See the root `.claude/CLAUDE.md` for the mirror policy.

## How it works (bridge model)

The port does **not** duplicate the helper scripts. The opencode skills and the `pr-grinder` worker call the **root** `scripts/*.sh` (`ack-ledger.sh`, `dispatcher-commit-block.sh`, `relevant-check-status.sh`, `resolve-cli.sh`, …) directly, resolved through the `BUSDRIVER_PLUGIN_ROOT` environment variable. **You therefore need a busdriver checkout on disk**, and `BUSDRIVER_PLUGIN_ROOT` must point at it.

`opencode/plugin.ts` is the adapter: it injects `BUSDRIVER_PLUGIN_ROOT` / `BUSDRIVER_STATE_DIR` into every shell call (`shell.env`) and bridges the gate-scripts at the `tool.execute.before/after` hooks (throwing to block, the opencode equivalent of Claude Code's `{"decision":"block"}`).

## Prerequisites

1. A busdriver checkout (this repo) on disk.
2. `BUSDRIVER_PLUGIN_ROOT` exported in the environment **opencode is launched from** — the plugin reads `process.env.BUSDRIVER_PLUGIN_ROOT`; if it is unset the bridge cannot find the gate-scripts.
3. `BUSDRIVER_STATE_DIR` — **do not set this yourself.** The plugin defaults it to `.opencode` and injects it into every shell/gate call automatically. Exporting it globally is harmful: the shared scripts honor it, so a global `.opencode` value would make your *Claude Code* sessions (in any repo) read/write `.opencode/` instead of `.claude/`.

### Set the env var

Only `BUSDRIVER_PLUGIN_ROOT` needs to be in the environment opencode launches from — the plugin reads `process.env.BUSDRIVER_PLUGIN_ROOT` at load time and cannot self-inject this one.

**bash / zsh** (`~/.bashrc` / `~/.zshrc`):
```bash
export BUSDRIVER_PLUGIN_ROOT=/path/to/busdriver
```

**fish** (`~/.config/fish/config.fish`, or run once with `-U` to persist):
```fish
set -Ux BUSDRIVER_PLUGIN_ROOT /path/to/busdriver
```
> fish does not read `~/.zshrc`. If you launch opencode from fish, you **must** set this in fish — otherwise `$BUSDRIVER_PLUGIN_ROOT` is empty and the bridge silently falls back to the wrong root.

## Install

opencode discovers each component from a dedicated directory. **The directory names are plural** (`agents/`, `skills/`). Installing the agent into a singular `agent/` directory leaves the `pr-grinder` worker undiscoverable — opencode silently falls back to a built-in agent and pr-grind degrades to running inline.

Project-local (under `.opencode/`), or global (under `~/.config/opencode/`) — same three components:

```bash
# 1. Adapter plugin (gate bridge)
mkdir -p ~/.config/opencode/plugins
cp "$BUSDRIVER_PLUGIN_ROOT/opencode/plugin.ts" ~/.config/opencode/plugins/busdriver.ts

# 2. Agents — PLURAL "agents/" (the pr-grinder worker, dispatched via task())
mkdir -p ~/.config/opencode/agents
cp "$BUSDRIVER_PLUGIN_ROOT"/opencode/agents/*.md ~/.config/opencode/agents/

# 3. Skills — the four features
mkdir -p ~/.config/opencode/skills
cp -R "$BUSDRIVER_PLUGIN_ROOT"/opencode/skills/* ~/.config/opencode/skills/
```

Local plugin files in `plugins/` are **auto-loaded at startup** — no `opencode.json` registration is needed (the `"plugin"` config field is for npm packages, not local file paths). Load order: global config → project config → global `plugins/` → project `plugins/`.

### Validate

opencode validates agent/config files at **startup**, so just launching it surfaces a malformed agent as `Configuration is invalid at <path> … Expected object | undefined, got [...]`. To confirm the worker loaded without opening an interactive session:
```bash
opencode agent list   # the `pr-grinder` agent should appear in the list
```
If you see the `Configuration is invalid` error on `pr-grinder.md`, you have a stale copy with the old `tools: [...]` array shape — re-copy from `opencode/agents/`. The current agents use a `permission:` map (`mode: subagent` + `permission: { edit, bash, webfetch }`), which is the shape opencode expects.

## Per-role CLI routing (optional)

Reviewer/voice CLI routing is read from `${BUSDRIVER_STATE_DIR}/busdriver.json` — i.e. **`.opencode/busdriver.json`** when `BUSDRIVER_STATE_DIR=.opencode` (and `$HOME/.opencode/busdriver.json` for user-level defaults). Absent that file, routes fall back to built-in defaults. Format matches the root README's per-role routing table.

## Smoke tests

```text
C0  bridge sanity   : in opencode bash — `. "$BUSDRIVER_PLUGIN_ROOT/scripts/fetch-pr-state.sh" <PR>`
                      then `bash "$BUSDRIVER_PLUGIN_ROOT/scripts/ack-ledger.sh" <bot>` in the SAME shell
                      → FETCH_OK=1, non-empty reviews, real none/stale/<sha> verdicts
C1  task dispatch   : dispatch subagent_type="pr-grinder" → must dispatch the CUSTOM worker (not a builtin),
                      and its bash must see BUSDRIVER_PLUGIN_ROOT / BUSDRIVER_STATE_DIR
C2  real grind      : /pr-grind <throwaway PR> → dispatches pr-grinder PER ROUND, runs the real
                      ack-ledger/dispatcher-commit-block, merges or bails with RESULT_BAIL_CATEGORY
```
