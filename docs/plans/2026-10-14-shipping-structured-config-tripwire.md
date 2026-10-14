# Structured Agent Config Tripwire (#950) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use busdriver:subagent-driven-development (recommended) or busdriver:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `scripts/needs-shipping.py`'s import walk incomplete when agent config can make an agent run a repo file, so such repos hand-land every PR instead of letting Shipping auto-land an edit to that file.

**Architecture:** Three predicates, `structured_config(path)`, `frontmatter_trips(text)` and `injects_shell(text)`, plus the `shell_scope(path)` and `shell_path(path)` path rules, are wired into `walk()`. The structured-config and skill-path checks run on tree paths in the first loop, so it needs no blob fetch. The Markdown checks run once per depth-0 `(rev, path)` on text the walk already fetched. Every trip raises the existing `Incomplete`, and #936's `INCOMPLETE` routing does the rest.

**Tech Stack:** Python 3.9 stdlib (`/usr/bin/python3 -I`), bash test harness `tests/test-needs-shipping.sh` with its stub `gh`.

**Global Constraints:**
- Python 3.9-compatible and stdlib only. No YAML, TOML or JSON parsing for this feature.
- Every new check fails closed: doubt raises `Incomplete`, never returns "no trip".
- Spec: `docs/specs/2026-10-13-shipping-hook-mcp-command-tripwire-design.md` (commit `799a1a5e`). Two deviations, both from the review's deferred mediums (`docs/reviews/shipping-hook-mcp-command-tripwire-design/follow-up-issues.md`). Both must be named in the PR body.
  1. The inline `` !` `` trips when it starts a whitespace-separated word, as the Claude Code skills docs document and the 2.1.296 binary implements (`/(?<=^|\s)!`([^`]+)`/gm`), and the check runs on a copy in which every `$` run (`\$[^\s\ufeff`!]*`) is replaced by a NUL sentinel that may stand for nothing or for whitespace. Claude Code substitutes `$` placeholders (`$name`, `$0`, `$ARGUMENTS`, `${CLAUDE_SESSION_ID}`, ...) before the `!` scan; a missing named argument becomes empty and a quoted argument can be whitespace (skills docs). So in the copy, `!` trips after start, whitespace, U+FEFF or a sentinel, followed by any number of sentinels and then a backtick; and a fence trips when ```` ```! ```` appears with the sentinels deleted. A `$` run never contains whitespace, U+FEFF, a backtick or `!`, so every marker an empty or whitespace substitution can form, the copy also forms. Treating a sentinel as both nothing and whitespace can only add trips. A placeholder can also expand to repo-controlled text: `${CLAUDE_SKILL_DIR}` and `${CLAUDE_PLUGIN_ROOT}` expand to a directory in the tree, and Claude Code prefixes a skill with `Base directory for this skill: <dir>`, so the path also reaches the `!` scan. Every marker needs a `!` or a backtick, and a value without either can only add nothing, whitespace or characters that break a marker, so `shell_path` trips on any agent-config path with a `skills` or `commands` component that contains `!` or a backtick, in the first loop with no fetch, and the sentinel covers the rest. Residuals: an argument value that itself supplies `!` or a backtick (the value comes from the invocation, not the repo), the part of an absolute directory outside the checkout (set by the operator or the cloud VM), and a substitution syntax that does not start with `$`. Words split on Python's `\s` plus U+FEFF, which contains JavaScript's `\s` (Python's also has U+001C-U+001F and U+0085, which only adds trips). A ```` ```! ```` anywhere trips because the binary's fence regex (`/```!\s*\n?([\s\S]*?)\n?```/g`) is not anchored to a line start; an unclosed one trips too, as a fail-closed choice, since text added later (a substitution or the base-directory prefix) can close it. The check is a linear scan, with no backtracking regex over blob text.
  2. The Markdown checks run for every depth-0 `(rev, path)`, outside the sha-keyed `parsed` guard.
- Keep existing pinned doc phrases intact: `files an agent-config file imports with `@path`` in `skills/pr-grind/SKILL.md`, and `import with `@path` (#936)` in `skills/pr-grind/references/completion.md`.
- Conventional Commits. Each commit ends with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

---

## File Structure

- Modify `scripts/needs-shipping.py`: new predicates next to `instruction_file()` (around line 243); wiring in `walk()` (lines 488-540); selftest asserts in `selftest()` (before `print("needs_shipping_selftest_ok")`); one docstring sentence.
- Modify `tests/test-needs-shipping.sh`: a new `── tripwire (#950)` section after the import-walk section, plus two doc pins near the end.
- Modify `docs/adr/0055-pr-grind-shipping-kick.md`: amendment paragraph after line 22, consequence bullet after the #936 bullet (around line 156).
- Modify `skills/pr-grind/SKILL.md:83` and `skills/pr-grind/references/completion.md:571`: one clause each.

---

### Task 1: Predicates and selftest

**Files:**
- Modify: `scripts/needs-shipping.py`, after `def instruction_file` (line 243-245) and inside `selftest()`

**Interfaces:**
- Produces: `structured_config(path: str) -> bool`, `frontmatter_trips(text: str) -> Optional[str]` (a reason, or None), `injects_shell(text: str) -> bool`, `shell_scope(path: str) -> bool`, `shell_path(path: str) -> bool`, `markdown_trips(path: str, text: str) -> None` (raises `Incomplete`)

- [ ] **Add the predicates** directly after `instruction_file()`:

```python
STRUCTURED_EXTS = (".json", ".jsonc", ".toml", ".yaml", ".yml")
FM_KEY_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_-]*)[ \t]*:")
FM_RUN_KEYS = ("hooks", "mcpServers", "lspServers", "monitors", "settings")  # keys Claude Code 2.1.296 knows that can start a process
DOLLAR_RUN_RE = re.compile(r"\$[^\s\ufeff`!]*")  # wider than any $-placeholder; keeps every boundary, backtick and !
INLINE_SHELL_RE = re.compile(r"(?:^|(?<=[\s\ufeff\x00]))!\x00*`", re.M)  # \x00: a placeholder, empty or whitespace


def structured_config(path):
    """#950: a JSON/TOML/YAML file in an agent directory, or any `.mcp.json`, can declare a hook,
    MCP server, helper or plugin that runs a repo file, so its presence makes the walk incomplete.
    `.cursor/environment.json` is exempt: it configures the cloud VM, which runs repo code anyway."""
    # keep-simple(UPGRADE: parse declared commands and add the scripts they name to the imported set once an opted-in repo needs structured agent config)
    parts = path.lower().split("/")
    if parts[-2:] == [".cursor", "environment.json"]:
        return False
    return parts[-1] == ".mcp.json" or (any(p in AGENT_DIRS for p in parts) and parts[-1].endswith(STRUCTURED_EXTS))


def md_lines(text):
    return text.replace("\r\n", "\n").replace("\r", "\n").split("\n")


def frontmatter_trips(text):
    """#950 §2.1: a reason when YAML frontmatter may declare `hooks` or `mcpServers`, else None.
    Only plain column-0 keys are read; any other spelling YAML allows trips as unreadable."""
    lines = md_lines(text[1:] if text.startswith("\ufeff") else text)
    start = next((k for k, ln in enumerate(lines) if ln.strip()), None)
    if start is None or lines[start].strip() != "---":  # an indented opener is read too: only adds trips
        return None
    first = True
    for ln in lines[start + 1:]:
        if ln.rstrip(" \t") == "---":  # close only on what a YAML reader closes on; `...` never closes
            break
        if not ln.strip() or ln.startswith("#"):
            continue
        if ln[0] in " \t":
            if first:  # an indented top level is legal YAML the column-0 rule would never read
                return "unreadable frontmatter"
            continue
        first = False
        m = FM_KEY_RE.match(ln)
        if not m:
            return "unreadable frontmatter"
        if m.group(1) in FM_RUN_KEYS:
            return "hook or MCP server in frontmatter"
    return None


def injects_shell(text):
    """#950 §2.2: a `!` command Claude Code may run before a skill or command reaches the model:
    inline `!`cmd` at a word start, or a ```! fence wherever it opens (Claude Code 2.1.296).
    `$` placeholders are substituted first and may become empty or whitespace, so each `$` run
    becomes a sentinel that counts as either."""
    t = DOLLAR_RUN_RE.sub("\x00", text)
    return "```!" in t.replace("\x00", "") or bool(INLINE_SHELL_RE.search(t))


def shell_scope(path):
    return any(p in ("skills", "commands") for p in path.lower().split("/"))


def shell_path(path):
    """#950: `${CLAUDE_SKILL_DIR}`, `${CLAUDE_PLUGIN_ROOT}` and the skill's base-directory prefix put
    the path in the text Claude Code scans for `!`, and every marker needs a `!` or a backtick."""
    return shell_scope(path) and ("!" in path or "`" in path)


def markdown_trips(path, text):
    """Raise Incomplete when depth-0 agent Markdown can run a repo file (#950)."""
    reason = frontmatter_trips(text)
    if reason:
        raise Incomplete(reason)
    if shell_scope(path) and injects_shell(text):
        raise Incomplete("skill shell injection")
```

- [ ] **Add selftest asserts** in `selftest()`, directly before `print("needs_shipping_selftest_ok")`:

```python
    for p in (".claude/settings.json", "A/.CLAUDE/Settings.Local.JSON", ".cursor/mcp.json", "x/.mcp.json",
              ".codex/config.toml", ".agents/a.yml", ".claude/x/y.yaml", ".cursor/a.jsonc"):
        assert structured_config(p), p
    for p in ("settings.json", ".cursor/environment.json", "X/.Cursor/Environment.json", ".claude/x.md",
              ".claude/hook.sh", "docs/a.json"):
        assert not structured_config(p), p
    fm = "---\n%s\n---\nbody"
    for t in ("no frontmatter\nhooks: x", fm % "name: s\ndescription: d", fm % "# c\nname: s",
              fm % "metadata:\n  hooks: x", "body\n---\nhooks: x\n---"):
        assert not frontmatter_trips(t), t
    for t in (fm % "hooks: x", fm % "mcpServers: {}", "\ufeff" + fm % "hooks: x", "---  \nhooks: x\n---",
              "---\r\nhooks: x\r\n---\r\n", "---\rhooks: x\r---", "---\nname: s\nhooks: x",
              "---\nname: s\n...\nhooks: x\n---", fm % '"hooks": x', fm % "!!str hooks: x",
              fm % "{hooks: x}", fm % "<<: *a", fm % "- x", fm % "  hooks: x", "  ---\nhooks: x\n---"):
        assert frontmatter_trips(t), t
    assert frontmatter_trips(fm % "hooks: x") == "hook or MCP server in frontmatter"
    for k in ("lspServers", "monitors", "settings"):
        assert frontmatter_trips(fm % (k + ": x")) == "hook or MCP server in frontmatter", k
    assert frontmatter_trips(fm % "- x") == "unreadable frontmatter"
    for t in ("!`x`", "Diff: !`git diff`", "- PR diff: !`gh pr diff`", "a\r!`x`", "\t!`x`", "\ufeff!`x`",
              "```!\nx\n```", "  ````!\nx", "- ```!\nx\n```", "> ```!\nx", "see ```! x```", "$unused!`x`",
              "${CLAUDE_SKILL_DIR}!`x`", "a $ARGUMENTS[0]!`x`", "$1!`x`", "!`a`b!`c`", "\u3000!`x`",
              "!$unused`./x.sh`", "!$ARGUMENTS`x`", "``$unused`!\nx", "x$a!`y`", "prefix$0!`./x.sh`",
              "x$a!$b`./x.sh`", "x$a\ufeff!$b`cmd`"):
        assert injects_shell(t), t
    for t in ("plain ! text", "```bash\nx\n```", "use `println!` here", "KEY=!`cmd`", "$x then `println!` here", "price $5!", "c!$d`x`", "$a `b` !c"):
        assert not injects_shell(t), t
    assert shell_scope(".claude/skills/s/SKILL.md") and shell_scope(".claude/Commands/c.md")
    assert not shell_scope("CLAUDE.md") and not shell_scope(".claude/agents/x.md")
    for p in (".claude/skills/ !`bash x.sh`/SKILL.md", ".claude/skills/foo !/SKILL.md", ".claude/skills/x```/SKILL.md",
              ".cursor/commands/a!b.md"):
        assert shell_path(p), p
    for p in (".claude/skills/s/SKILL.md", ".claude/notes/a!.md"):
        assert not shell_path(p), p
```

- [ ] **Run the selftest**

Run: `/usr/bin/python3 -I scripts/needs-shipping.py --selftest`
Expected: `needs_shipping_selftest_ok`

- [ ] **Prove one assert can fail:** temporarily change `FM_RUN_KEYS = ("hooks", "mcpServers",` to `FM_RUN_KEYS = ("mcpServers",` and re-run the selftest. Expected: `AssertionError` naming `---\nhooks: x...`. Revert the change.

- [ ] **Commit** (litmus commit review first: `init-review-loop.sh`, then `run-review-loop.sh` from the 2.8.0 plugin)

```bash
git add scripts/needs-shipping.py
git commit -m "feat(needs-shipping): add #950 tripwire predicates" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

### Task 2: Wire into walk() with integration tests

**Files:**
- Modify: `scripts/needs-shipping.py` `walk()` (lines 497-520)
- Test: `tests/test-needs-shipping.sh`, a new section after the last import-walk case (before `--selftest under $PY`, around line 585)

**Interfaces:**
- Consumes: `structured_config`, `shell_path`, `markdown_trips` from Task 1

- [ ] **Wire the first loop.** In `walk()`, after the gitlink check (`raise Incomplete("gitlink at an agent-config path")`) and before `if kind == "blob" and instruction_file(path):`, add:

```python
            if kind == "blob" and structured_config(path):  # tree-only: no blob is fetched for it (#950 §3)
                raise Incomplete("structured agent config")
            if shell_path(path):  # the path itself reaches the `!` scan (#950)
                raise Incomplete("`!` or backtick in a skill path")
```

- [ ] **Wire the import loop.** In the `for rev, path, rd in level:` loop, between `sha = tmaps[rev][path][2]` and `if sha not in parsed:`, add:

```python
            if depth == 0:  # per path, not per sha: shell_scope depends on where the text sits (#950)
                markdown_trips(path, texts[sha])
```

- [ ] **Add the integration section** to `tests/test-needs-shipping.sh`, directly before the `--selftest` block (`out=$("$PY" -I "$SCRIPT" --selftest 2>&1); rc=$?`). Every case changes only `src/x.ts`, so `$AC` (agent_config_edited=1) means the walk tripped and `$(ship)` means it did not.

```bash
echo "── tripwire (#950) ──────────────────────────────────────────"
walk_case '.claude/settings.json={"permissions": {}}' '.claude/CLAUDE.md=x'; only src/x.ts
run_case "permissions-only .claude/settings.json → incomplete" 10 "$AC"
if [ "$(gql_count)" = 0 ]; then pass "structured config trips from the tree alone (no blob fetch)"; else fail "structured config fetched blobs ($(gql_count))"; fi
walk_case '.mcp.json={"mcpServers": {"s": {"url": "https://x"}}}'; only src/x.ts
run_case "url-only .mcp.json → incomplete" 10 "$AC"
new_case; opt_in; at "$HEAD"; at "$BASE" '.cursor/hooks.json={}'; only src/x.ts
run_case ".cursor/hooks.json at base_tip only → incomplete" 10 "$AC"
for p in sub/.claude/settings.local.json .codex/config.toml .codex/hooks.json \
         .claude/skills/p/.claude-plugin/plugin.json .cursor/skills/verify-x/config.yaml; do
  walk_case "$p=x"; only src/x.ts
  run_case "$p → incomplete" 10 "$AC"
done
walk_case '.cursor/environment.json={"install": "npm ci"}'; only src/x.ts
run_case ".cursor/environment.json alone → no trip" 10 "$(ship)"
walk_case '.cursor/environment.json={"install": "npm ci"}'; only .cursor/environment.json
run_case "a PR editing .cursor/environment.json is still agent config" 10 "$AC"
walk_case '.claude/archive.json@dir'; only src/x.ts
run_case "a directory named like config → no trip (blobs only)" 10 "$(ship)"
walk_case $'.claude/agents/x.md=---\nhooks:\n  - x\n---\nbody'; only src/x.ts
run_case "agent frontmatter hooks → incomplete" 10 "$AC"
walk_case $'.claude/agents/x.md=---\nmcpServers: {}\n---\nbody'; only src/x.ts
run_case "agent frontmatter mcpServers → incomplete" 10 "$AC"
walk_case $'.claude/agents/x.md=---\r\nhooks: x\r\n---\r\nbody'; only src/x.ts
run_case "CRLF agent frontmatter hooks → incomplete" 10 "$AC"
walk_case $'.claude/skills/s/SKILL.md=---\nname: s\ndescription: d\n---\nbody'; only src/x.ts
run_case "skill with name/description only → no trip" 10 "$(ship)"
walk_case $'.claude/skills/s/SKILL.md=---\nname: s\n"hooks": x\n---\nbody'; only src/x.ts
run_case "quoted frontmatter key → incomplete" 10 "$AC"
# shellcheck disable=SC2016  # literal backticks in fixture text
walk_case '.claude/skills/s/SKILL.md=Diff: !`./scripts/x.sh`'; only src/x.ts
run_case "skill !\`cmd\` → incomplete" 10 "$AC"
walk_case $'.claude/commands/c.md=```!\n./scripts/x.sh\n```'; only src/x.ts
run_case "command \`\`\`! fence → incomplete" 10 "$AC"
# shellcheck disable=SC2016  # literal backticks in fixture text
walk_case '.claude/skills/s/SKILL.md=Use `println!` here'; only src/x.ts
run_case "skill code span println! → no trip" 10 "$(ship)"
# shellcheck disable=SC2016  # literal backticks in fixture text
walk_case 'CLAUDE.md=Use `println!` and !`x` here'; only src/x.ts
run_case "CLAUDE.md is outside the shell-injection scope → no trip" 10 "$(ship)"
# shellcheck disable=SC2016  # literal backticks in fixture text
walk_case '.claude/agents/x.md=!`./scripts/x.sh`' '.claude/skills/s/SKILL.md=!`./scripts/x.sh`'; only src/x.ts
run_case "same blob at an agent and a skill path → incomplete (checked per path)" 10 "$AC"
# shellcheck disable=SC2016  # literal backticks and $ in fixture text
walk_case $'.claude/skills/s/SKILL.md=---\narguments: [unused]\n---\n$unused!`./scripts/x.sh`'; only src/x.ts
run_case "skill \$placeholder!\`cmd\` → incomplete" 10 "$AC"
# shellcheck disable=SC2016  # literal backticks in fixture text
new_case; opt_in; at "$HEAD"; at "$BASE" '.claude/skills/s/SKILL.md=!`./scripts/x.sh`'; only src/x.ts
run_case "skill !\`cmd\` at base_tip only → incomplete" 10 "$AC"
# shellcheck disable=SC2016  # literal backticks in fixture text
new_case; opt_in; at "$HEAD" '.claude/skills/s/SKILL.md=!$unused`./scripts/x.sh`'; at "$BASE"; only src/x.ts
run_case "skill !\$placeholder\`cmd\` at head only → incomplete" 10 "$AC"
# shellcheck disable=SC2016  # literal backticks in fixture text
walk_case '.claude/CLAUDE.md=@../docs/skills/x.md' $'docs/skills/x.md=---\nhooks: x\n---\n!`./scripts/x.sh`'; only src/x.ts
run_case "triggers in an imported (depth 1) file are not run → no trip" 10 "$(ship)"
walk_case '.claude/skills/a!b/SKILL.md=body'; only src/x.ts
run_case "skill directory with ! → incomplete" 10 "$AC"
# shellcheck disable=SC2016  # literal backtick in fixture path
walk_case '.claude/skills/a`b/SKILL.md=body'; only src/x.ts
run_case "skill directory with a backtick → incomplete" 10 "$AC"
```

- [ ] **Run the suite**

Run: `bash -c 'bash tests/test-needs-shipping.sh 2>&1 | tail -5; exit "${PIPESTATUS[0]}"'; echo "rc=$?"` (the tool shell is zsh, so `PIPESTATUS` is read inside `bash -c`)
Expected: last lines `needs-shipping: N passed, 0 failed` and `rc=0`. No pre-existing case changes result. If one does, its fixture holds a structured file or a `!` line in an agent dir; read it before changing anything.

- [ ] **Prove the wiring fires** (restore the code after each step):
  1. Delete the `if depth == 0:` line and the `markdown_trips(path, texts[sha])` line under it, and re-run. Expected: exactly the frontmatter rows (hooks, mcpServers, CRLF, quoted key) and the `!` rows (skill `!`cmd``, command fence, same-blob, `$placeholder`, base_tip-only, head-only) fail; the depth-1 row and the two skill-directory rows still pass.
  2. Move those two lines inside the `if sha not in parsed:` block, and re-run. Expected: only the same-blob row fails.
  3. Change `if depth == 0:` to `if True:`, and re-run. Expected: only the depth-1 row fails.
  4. Delete the `structured_config` raise (both lines), and re-run. Expected: the structured rows fail, and so does the no-blob-fetch check, because `.claude/CLAUDE.md` is then fetched.
  5. Delete the `shell_path` raise (both lines), and re-run. Expected: exactly the two skill-directory rows fail.

- [ ] **Shellcheck the test file**

Run: `shellcheck --severity=warning tests/test-needs-shipping.sh`
Expected: no output.

- [ ] **Commit** (litmus first)

```bash
git add scripts/needs-shipping.py tests/test-needs-shipping.sh
git commit -m "fix(needs-shipping): structured agent config makes the import walk incomplete (#950)" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

### Task 3: Docs

**Files:**
- Modify: `scripts/needs-shipping.py` module docstring (line 10-11)
- Modify: `docs/adr/0055-pr-grind-shipping-kick.md` (after line 22; after the #936 consequence bullet)
- Modify: `skills/pr-grind/SKILL.md:83`, `skills/pr-grind/references/completion.md:571`
- Test: `tests/test-needs-shipping.sh` doc pins

- [ ] **Docstring.** Replace `A walk that cannot finish makes every changed path agent config (#936).` with:

```text
A walk that cannot finish makes every changed path agent config (#936), and so does a JSON,
TOML or YAML file in an agent directory or any `.mcp.json` (`.cursor/environment.json` exempt),
or a hook, MCP server or unreadable frontmatter in agent Markdown, or a `!` command in a skill
or command or its path, any of which can run a repo file (#950).
```

- [ ] **ADR 0055 amendment.** Insert after the paragraph ending `` `CLASSIFIER_TIMEOUT` rises to `` / `1700s.` (it wraps across lines 21-22, so match the `1700s.` line), separated by a blank line:

```markdown
Amended (2026-10-13, #950): agent config can make an agent run a repo file (a hook, an MCP
server, a credential helper, a plugin, a skill's `!` command), and that file is ordinary code.
So the walk is also incomplete when either rev has a `.json`, `.jsonc`, `.toml`, `.yaml` or
`.yml` file in an agent directory, or any `.mcp.json` (`.cursor/environment.json` exempt); when
agent Markdown frontmatter has a `hooks`, `mcpServers`, `lspServers`, `monitors` or `settings`
key, or a line the plain-key reader cannot read; or when a body under `skills/` or `commands/` has a `!` command, or such a path
has a `!` or backtick (`${CLAUDE_SKILL_DIR}` and the skill's base-directory prefix put the path
in the text that is scanned). Presence trips,
not content: three review rounds of a key-by-key design each found another execution point
(spec `docs/specs/2026-10-13-shipping-hook-mcp-command-tripwire-design.md`).
```

- [ ] **ADR 0055 consequence.** Insert directly after the #936 bullet (the one ending `on 2026-10-12 none of the three opted-in repos had one.`):

```markdown
- (#950) A repo with any JSON, TOML or YAML file in an agent directory (a permissions-only
  `.claude/settings.json` included) or any `.mcp.json`, `.cursor/environment.json` exempt, or
  with a hook, MCP server or unreadable frontmatter in agent Markdown, or a `!` command in a
  skill or command or its path, hand-lands every PR until command parsing exists.
```

- [ ] **SKILL.md:83.** Replace `` `@path`, are never skipped) stops at`` with:

```text
`@path`, are never skipped; a JSON, TOML or YAML file in an agent directory or any `.mcp.json` (`.cursor/environment.json` exempt), or a hook, MCP server or unreadable frontmatter in agent Markdown, or a `!` command in a skill or command or its path, makes every path agent config (#950)) stops at
```

- [ ] **completion.md:571.** Replace `` import with `@path` (#936)) is landed`` with:

```text
import with `@path` (#936); a JSON, TOML or YAML file in an agent directory or any `.mcp.json` (`.cursor/environment.json` exempt), or a hook, MCP server or unreadable frontmatter in agent Markdown, or a `!` command in a skill or command or its path, makes every path agent config (#950)) is landed
```

- [ ] **Doc pins.** In `tests/test-needs-shipping.sh`, after the `t "SKILL.md names imported files" ...` line, add:

```bash
t "SKILL.md names the #950 tripwire" grep -qF 'makes every path agent config (#950)' "$SKILL"
t "routing names the #950 tripwire" has "$ROUTE_TEXT" 'makes every path agent config (#950)'
```

- [ ] **Run the suite and the other suites that read these files**

Run: `for f in $(grep -l "completion.md\|pr-grind/SKILL.md\|needs-shipping" tests/*.sh); do bash "$f" > /dev/null 2>&1; echo "$f rc=$?"; done`
Expected: every line ends `rc=0`. For a non-zero line, re-run that file alone and read its output.

- [ ] **Commit** (litmus first)

```bash
git add scripts/needs-shipping.py docs/adr/0055-pr-grind-shipping-kick.md skills/pr-grind/SKILL.md skills/pr-grind/references/completion.md tests/test-needs-shipping.sh
git commit -m "docs(shipping): record the #950 structured-config tripwire" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

### Task 4: Rollout measurement (before the PR; needs the operator's permission)

The operator must approve this read of the three external repos first. It is not yet approved.

- [ ] For each of `Dive-And-Dev/jikdak`, `Dive-And-Dev/diveand.dev`, `Dive-And-Dev/chrisyau.me`: read the default branch's commit SHA, then fetch that commit's recursive tree. A truncated tree reports the repo as "unknown (tree truncated)". As `walk()`'s first loop does, run `shell_path` over every agent-config entry and `structured_config` over every agent-config `blob` entry, and print only the matching paths. For each agent-config instruction blob, fetch its text and call `markdown_trips` inside `try/except Incomplete`, printing only the path and the reason. A blob that fails to fetch, is binary or is truncated reports the repo as "unknown (blob unreadable)", as production makes such a walk incomplete. An "unreadable frontmatter" trip on a file outside `skills/` or `commands/` (a `CLAUDE.md` or `AGENTS.md` opening with a `---` rule) is listed separately, so the operator can tell a style false positive from a real key. No file contents are printed or saved. This is a local measurement script in the scratchpad, never committed.
- [ ] Report per repo, with the measured commit SHA: "would hand-land every PR" (with the matching paths and reasons), "unaffected", or "unknown". The operator decides whether to ship.
- [ ] When the PR is opened, its body names both Global Constraints deviations (the inline `!` rule with the `$`-placeholder sentinel, the `shell_path` rule for `!` or a backtick in a skill or command path, and the unanchored fence, and the per-path placement), plus its three residuals (argument values that supply `!` or a backtick, the part of a skill's absolute directory outside the checkout, and substitution syntax not starting with `$`) and the Task 4 result per repo.

---

## Codex Handoff Eligibility

Outcome 3 (in-session). Criterion 3 fails: each fixture's result depends on tree ordering and on the existing `$AC`/`$(ship)` helpers, and each "prove it fires" step needs a reading of which rows flipped.

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
