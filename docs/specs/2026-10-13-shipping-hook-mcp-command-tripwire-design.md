# Structured agent config makes the import walk incomplete (#950)

## Context
`scripts/needs-shipping.py` treats an edit to agent config as a reason to hand-land a PR in a repo opted in to Cursor Cloud Shipping (ADR 0054, ADR 0055). Agent config is any path with a `.cursor`, `.claude`, `.codex` or `.agents` component, a basename in `AGENT_FILES`, or (since #936) a file reached through `@path` imports from those files at the PR head or `base_tip`.

Agent config can also make an agent **run** a repo file: hooks, MCP servers, status lines, credential helpers, `env` blocks and plugin manifests in `.claude/settings.json`, `.mcp.json`, `.cursor/hooks.json`, `.cursor/mcp.json`, `.codex/config.toml`, `.codex/hooks.json` and `.claude/skills/<p>/.claude-plugin/plugin.json`; subagent, skill and command frontmatter (`hooks`, `mcpServers`); and skill and command bodies, whose `` !`command` `` lines and ```` ```! ```` blocks run before the skill reaches the model (Claude Code skills docs, "Inject dynamic context").

The declaring file is agent config, but a script it names (`scripts/hook.sh`, `tools/server.js`) is ordinary code. A PR that edits only that script can be auto-landed by Shipping, and the next local agent session runs the changed script on the operator's machine.

On 2026-10-13 none of the three opted-in repos (jikdak, diveand.dev, chrisyau.me) had `.claude/settings.json`, `.cursor/hooks.json`, `.mcp.json` or `.cursor/mcp.json` on its default branch. On 2026-10-14 a read-only scan of their default branches (jikdak `665a4a72`, diveand.dev `9c742830`, chrisyau.me `7b042e05`) found no path or agent Markdown that §1 or §2 matches; see Rollout.

## Decisions
- **Tripwire, not parsing** (the operator's choice). Deciding whether a command string runs repo code is fail-open-prone: `"$CLAUDE_PROJECT_DIR"/scripts/x.sh`, `npm run lint`, `python -m tools.server` and `bash -c "…"` all run repo code without naming a plain path. So a tripped repo hand-lands every PR. The code is marked `keep-simple(UPGRADE: parse declared commands and add the scripts they name to the imported set once an opted-in repo needs structured agent config)`.
- **Presence, not content** (the operator's choice, 2026-10-13). Three review rounds of a key-by-key design each found another execution point (`headersHelper`, `env`, `extraKnownMarketplaces`, skills-directory plugins, Codex hooks). Every Claude Code, Cursor or Codex release can add one. So any structured file in an agent directory trips, whatever it holds. A new key or a new file name in an existing format then trips with no change here, and there is no JSON or TOML parsing, so no parser error path. The operator accepted the cost: a permissions-only `.claude/settings.json` or a url-only `.mcp.json` now trips too.
- **Structured means the extension** `.json`, `.jsonc`, `.toml`, `.yaml` or `.yml`. These are the formats the three tools read config from today. A config file in another format is a residual.
- **`.cursor/environment.json` is exempt** (the operator's choice). It configures the Cursor cloud VM, where the agent already runs repo code by design (dependency install, tests). A script it names adds no new execution surface, and #950's threat is code auto-running in the operator's local session.
- **Markdown frontmatter: allow simple top-level keys only.** The stdlib has no YAML parser, and YAML can spell a key through quotes, escapes, tags, merge keys or flow mappings. So the check reads only column-0 lines, and any column-0 line that is not a plain key makes the walk incomplete (§2.1). Top-level `hooks`, `mcpServers`, `lspServers`, `monitors` and `settings` trip by name.
- **Shell injection is checked only under `skills` and `commands`** (the operator's choice). Only skill and command bodies run `!` lines. Checking every instruction file would trip on ordinary Markdown such as `` `println!` `` in a `CLAUDE.md`.

## Design

### 1. Structured config
`structured_config(path)` is true, case-insensitively, when `agent_config(path)` is true and either:
- the path has an `AGENT_DIRS` component and its basename ends with `.json`, `.jsonc`, `.toml`, `.yaml` or `.yml`; or
- the basename is `.mcp.json`.

It is false for a path whose last two components are `.cursor/environment.json`.

### 2. Markdown triggers
Both run on every instruction file (`instruction_file()`: `.md`, `.mdc`, `.cursorrules`) that the walk collects at depth 0, not on files reached through imports. Each raises `Incomplete`.

#### 2.1 Frontmatter
`frontmatter_trips(text)` returns true when the frontmatter may declare a hook or MCP server. Reason: `hook or MCP server in frontmatter`.
- Strip a leading BOM. Split lines at LF, CR or CRLF, as `parse()` does.
- If the first non-blank line, with surrounding whitespace stripped, is not `---`, there is no frontmatter: return false.
- The frontmatter runs to the next line that is `---` after trailing whitespace is stripped, or to end of file when there is none. A YAML `...` end marker does not close it: if a reader kept reading past `...`, closing there would hide its keys, while not closing can only over-trip.
- Blank lines and lines starting with `#` are skipped. If the first remaining line starts with whitespace, return true: YAML allows an indented top level, which the column-0 rule would otherwise never read. After that, lines starting with whitespace are skipped.
- Every other line must match `^([A-Za-z_][A-Za-z0-9_-]*)[ \t]*:`. A line that does not match returns true. That includes a quoted key, a tag, a flow mapping, a merge key `<<:` and a column-0 list item `- x`.
- A captured key equal to `hooks`, `mcpServers`, `lspServers`, `monitors` or `settings` returns true.

#### 2.2 Shell injection
Only for a path with a `skills` or `commands` component (case-insensitive). `injects_shell(text)` returns true when the text contains `` !` `` at a word start (line start, or after whitespace or a BOM), or ```` ```! ```` anywhere, an unclosed fence included. Claude Code substitutes `$` placeholders before it scans, and one can become empty or whitespace, so each `$` run is first replaced by a sentinel that counts as either. Reason: `skill shell injection`.

`shell_path(path)` is true for a `skills` or `commands` path that itself contains `!` or a backtick: `${CLAUDE_SKILL_DIR}`, `${CLAUDE_PLUGIN_ROOT}` and the skill's base-directory prefix put the path into the scanned text. Reason: `` `!` or backtick in a skill path ``.

### 3. Placement
In `walk()`'s first loop over each rev's agent-config entries, after the existing symlink and gitlink checks: an entry with `structured_config(path)` raises `Incomplete("structured agent config")`, and one with `shell_path(path)` raises its §2.2 reason. This needs the tree only, no blob fetch.

In the import loop at depth 0, each fetched text is checked with §2.1, and with §2.2 when the path qualifies, before `parse()`. Those blobs are already fetched for the import walk, so fetching adds nothing.

Both revs are checked, as for imports. `base_tip` is the base branch's live tip, not the merge base, so a file present only at `base_tip` still trips.

### 4. Effect
Unchanged from #936 §6: `imported_config()` returns `INCOMPLETE`, every changed path is agent config, the PR routes with `agent_config_edited=1`, and lands through the ADR 0054 D4 escape.

### 5. Docs
- `scripts/needs-shipping.py` module docstring: one clause naming the tripwire.
- ADR 0055: one amendment paragraph (#950) and one consequence bullet, next to the #936 ones.
- `skills/pr-grind/SKILL.md:83` and `skills/pr-grind/references/completion.md:571`: extend the #936 clause ("files an agent-config file imports with `@path`") to say that a JSON, TOML or YAML file in an agent directory, or a hook, MCP server or shell command in agent Markdown, makes every path agent config.

## Testing
`tests/test-needs-shipping.sh`, using the #936 stub-`gh` tree and blob fixtures, in an opted-in repo with a PR that changes one ordinary code path. Expected `agent_config_edited`:

| # | Fixture | Expected |
|---|---------|----------|
| 1 | `.claude/settings.json` with only `permissions`, at head | 1 |
| 2 | `.mcp.json` with a url-only server | 1 |
| 3 | `.cursor/hooks.json` at `base_tip` only | 1 |
| 4 | `sub/.claude/settings.local.json` | 1 |
| 5 | `.codex/config.toml` | 1 |
| 6 | `.codex/hooks.json` | 1 |
| 7 | `.claude/skills/p/.claude-plugin/plugin.json` | 1 |
| 8 | `.cursor/skills/verify-x/config.yaml` | 1 |
| 9 | `.cursor/environment.json` only | 0 |
| 10 | `.claude/agents/x.md` with frontmatter `hooks:` | 1 |
| 11 | `.claude/agents/x.md` with frontmatter `mcpServers:` | 1 |
| 12 | `.claude/agents/x.md` saved with CRLF, frontmatter `hooks:` | 1 |
| 13 | `.claude/skills/s/SKILL.md` with frontmatter `name`, `description` only | 0 |
| 14 | `.claude/skills/s/SKILL.md` with a quoted key `"hooks":` | 1 |
| 15 | `.claude/skills/s/SKILL.md` body with `` !`./scripts/x.sh` `` | 1 |
| 16 | `.claude/commands/c.md` body with a ```` ```! ```` fence | 1 |
| 17 | `CLAUDE.md` with `` `println!` `` in a code span | 0 |

`--selftest` gains asserts, each with its expected result:
- `structured_config`: true for `.claude/settings.json`, `A/.CLAUDE/Settings.Local.JSON`, `.cursor/mcp.json`, `x/.mcp.json`, `.codex/config.toml`, `.agents/a.yml`, `.claude/x/y.yaml`, `.cursor/a.jsonc`; false for `settings.json`, `.cursor/environment.json`, `X/.Cursor/Environment.json`, `.claude/x.md`, `.claude/hook.sh`, `docs/a.json`.
- `frontmatter_trips`: false for no frontmatter, for `name`/`description` only, for a `# comment` line, and for an indented line under `metadata:`; true for `hooks:`, `mcpServers:`, a BOM before `---` with `hooks:`, `---  ` (trailing spaces) with `hooks:`, CRLF with `hooks:`, no closing `---` with `hooks:` in the body, `"hooks":`, `!!str hooks:`, `{hooks: x}`, `<<: *a`, `- x`, and an indented first key.
- `injects_shell`: true for `` !`x` `` and for ```` ```! ````; false for plain text with a lone `!` and for ```` ```bash ````.
- The path rule for §2.2: true for `.claude/skills/s/SKILL.md` and `.claude/Commands/c.md`; false for `CLAUDE.md` and `.claude/agents/x.md`.

## Rollout
Before the PR is opened, list the three opted-in repos' default-branch files that §1 would match, and scan their agent-config Markdown for §2.1 and §2.2 hits. A hit means that repo hand-lands every PR once this ships; the operator decides whether to ship anyway.

## Residuals
- `.cursor/environment.json` `install`/`start`/`terminals`/`build` can name repo files; exempt by decision above.
- A config file in an agent directory in another format (`.ini`, `.json5`, no extension) is not checked. A tool that adds such a format needs its extension added here.
- A `!` line in agent Markdown outside `skills` and `commands` is not checked; no tool runs one there today.
- Settings outside the tree are invisible: a gitignored `.claude/settings.local.json`, the operator's `~/.claude/settings.json`, and a plugin loaded with `--plugin-dir`. If any names a repo script, a PR can still change that script and auto-land. Only what is committed is checked. Inside the tree, Claude Code loads a repository plugin only through `.claude/settings.json` or `.claude/skills/` (Claude Code plugins docs, "Plugins shared through a repository"), and both trip.
- A repo with any structured agent config, or with a hook, MCP server or shell command in agent Markdown, hand-lands every PR until command parsing exists.

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
