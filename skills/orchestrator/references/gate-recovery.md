# Emergency Gate Recovery

> Full procedure for bypassing a hook-enforced gate. Read this when a gate blocks and the user needs to bypass. The condensed hard-rules summary lives inline in `orchestrator/SKILL.md`.

When a gate blocks and the user needs to bypass:

1. **Get absolute project path and state dir:** `git rev-parse --show-toplevel` for `<PROJECT_ROOT>`, and resolve `<STATE_DIR>` = `.claude` (default `.claude` — the gate also names it verbatim in its block message). Skip files use absolute paths because the gate checks `<STATE_DIR>/` relative to the **blocked command's CWD**.
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
- NEVER verify the skip file via Bash (`test -f`, `ls`, `stat`, `cat`, `find`) before retrying. During the design-review gate's <30s self-bypass window, any gated call (Write/Edit/MultiEdit/Bash) still destroys that skip file; past that window it is a lease evaluated AFTER tool-type discrimination, so a read-only call no longer spends a use (#519 / ADR 0031) — but verifying still tells you nothing useful. `litmus`/`pr-grind`'s gates only inspect their skip file when the Bash command itself matches the gate's trigger pattern (`git commit` / `gh pr create` / `gh pr merge`), so a bare verification command never reaches their skip-file logic at all — but it still burns a turn for no information. In all cases: don't verify — just wait and retry.
- NEVER ask the user to wait — Claude waits via Monitor.
- After user touches the file, make NO tool calls except Monitor before retrying.
- If the retry still blocks, the file was consumed mid-wait — ask the user to `touch` again and restart the 35s wait.

`skip-litmus.local` is single-use. `skip-design-review.local` is a **lease** — 20 gated writes within 3600s per `touch`, spent only by genuinely gated operations, every use logged (an unloggable use is refused) (#519 / ADR 0031). `skip-pr-grind.local` uses deferred consumption (preserved on merge failure / `--auto` queue / ambiguous output; consumed only on confirmed `gh pr merge` success). All bypasses logged to `.claude/bypass-log.jsonl`. Full failure-mode taxonomy: `skills/blueprint-review/SKILL.md` ("User-Created Skip File").
