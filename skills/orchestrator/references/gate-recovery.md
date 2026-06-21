# Emergency Gate Recovery

> Full procedure for bypassing a hook-enforced gate. Read this when a gate blocks and the user needs to bypass. The condensed hard-rules summary lives inline in `orchestrator/SKILL.md`.

When a gate blocks and the user needs to bypass:

1. **Get absolute project path and state dir:** `git rev-parse --show-toplevel` for `<PROJECT_ROOT>`, and resolve `<STATE_DIR>` = `${BUSDRIVER_STATE_DIR:-.claude}` (default `.claude`; `.opencode` under the opencode harness — the gate also names it verbatim in its block message). Skip files use absolute paths because the gate checks `<STATE_DIR>/` relative to the **blocked command's CWD**.
2. **Send the user this verbatim message** (substitute `<PROJECT_ROOT>`, `<STATE_DIR>` resolved above — **NEVER hardcode `.claude`** — and `<GATE>` for `litmus` / `design-review` / `pr-grind`):
   > I need a skip file to bypass the `<GATE>` gate. Please run this in **your terminal** (not in this session):
   >
   > `touch <PROJECT_ROOT>/<STATE_DIR>/skip-<GATE>.local`
   >
   > After you run it, I will wait ~35 seconds before retrying. Reply "done" once you've run the command.
3. **After "done", wait via Monitor** — the harness rejects long foreground sleeps:
   ```text
   Monitor(command: "sleep 35 && echo READY", timeout: 45)
   ```
4. **When READY, retry the originally blocked action directly.** Do NOT verify the skip file first.

**Hard rules:**
- NEVER create the skip file yourself — gates reject and delete skip files less than 30s old (anti-self-bypass).
- NEVER use `sleep 32` / `sleep 35` directly via Bash — the harness rejects long foreground sleeps.
- NEVER verify the skip file via Bash (`test -f`, `ls`, `stat`, `cat`, `find`) before retrying. The design-review gate consumes the file on any intervening tool call (it fires before tool-type discrimination). For litmus/pr-grind, Bash verification trips the <30s self-bypass detector. In all cases: don't verify — just wait and retry.
- NEVER ask the user to wait — Claude waits via Monitor.
- After user touches the file, make NO tool calls except Monitor before retrying.
- If the retry still blocks, the file was consumed mid-wait — ask the user to `touch` again and restart the 35s wait.

Skip files for litmus and design-review are single-use. `skip-pr-grind.local` uses deferred consumption (preserved on merge failure / `--auto` queue / ambiguous output; consumed only on confirmed `gh pr merge` success). All bypasses logged to `.claude/bypass-log.jsonl`. Full failure-mode taxonomy: `skills/blueprint-review/SKILL.md` ("User-Created Skip File").
