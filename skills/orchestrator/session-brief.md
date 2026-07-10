# Orchestrator Session Brief

<!-- Condensed SessionStart injection. Full routing/phases/catalog live in
     skills/orchestrator/SKILL.md — INVOKE busdriver:orchestrator when routing. -->

<EXTREMELY-IMPORTANT>
Follow the pipeline. Feature work goes through phases 1–6. Do NOT use EnterPlanMode for feature work — INVOKE `busdriver:brainstorming` (Phase 1) or `busdriver:writing-plans` (Phase 2) instead. EnterPlanMode is only acceptable for non-pipeline tasks.
</EXTREMELY-IMPORTANT>

## Gates (Hook-Enforced)

All gates emit `{"decision":"block"}` via PreToolUse hooks. The harness rejects the tool call — Claude cannot bypass.

| Gate | Trigger | Skip / deactivate | Detail |
|------|---------|-------------------|--------|
| **Litmus (pre-commit)** | `git commit` | `.claude/skip-litmus.local` | `litmus/SKILL.md` |
| **Litmus (pre-PR)** | `gh pr create` (multi-voice deep review; PostToolUse appends an instruction to invoke `pr-grind` after PR creation) | `.claude/skip-litmus.local` | `litmus/SKILL.md` |
| **Blueprint Review** | Write/Edit of PLAN/DESIGN/ARCHITECTURE docs | `.claude/skip-design-review.local` | `blueprint-review/SKILL.md` |
| **Pre-implementation** | Write/Edit/MultiEdit/Bash while design unreviewed | `.claude/skip-design-review.local` | `blueprint-review/SKILL.md` |
| **Freeze/Guard** | Write/Edit/MultiEdit while `.claude/freeze-scope.local` exists | `rm .claude/freeze-scope.local` (deactivates the freeze; activate with `echo "path/to/scope" > .claude/freeze-scope.local`) | `hooks/gate-scripts/freeze-guard.sh` |
| **Pre-merge (pr-grind)** | `gh pr merge` | `.claude/skip-pr-grind.local` (must be ≥30s and ≤3600s old) | `pr-grind/SKILL.md` |

Gate skips are **file-only** (`touch <STATE_DIR>/skip-litmus.local`, `skip-design-review.local`, `skip-pr-grind.local`). The `SKIP_LITMUS` / `SKIP_DESIGN_REVIEW` / `SKIP_PR_GRIND` env-var hatches were removed — a committed `.claude/settings.json` env block is PR-injectable (issue #325 / ADR 0016).

## Routing

Any task beyond trivial Q&A: INVOKE `busdriver:orchestrator` for full routing, or Read `tasks-catalog.md` (non-pipeline) / `domain-supplements.md` (domain detection) in this skill's dir. Rows marked `(vault)` = archived: Read `skills-archive/<name>/SKILL.md` (or `agents-archive/`, `commands-archive/`) on demand and apply directly.

## Supplements

**Supplement Loading Protocol:** Before invoking a skill or dispatching an agent, check `skills/supplements/MANIFEST.md` for active supplements targeting that skill/agent. If a match exists, Read the supplement file and apply its content alongside the skill. Opt-in supplements require an explicit trigger condition (a user trigger phrase OR an auto-memory signal listed in the manifest's Trigger column). Supplements are not injected by hooks — this is prompt-level guidance.

## Design Review (CRITICAL)

<CRITICAL>
To review design/plan documents, INVOKE `blueprint-review` skill (via Skill tool). Do NOT use `code-reviewer` agent — it cannot write the `<!-- design-reviewed: PASS -->` marker.
</CRITICAL>

## Emergency Gate Recovery

When a gate blocks and the user needs to bypass, follow the full procedure in `references/gate-recovery.md` (in this skill's directory). **Hard rules — never violate:**
- NEVER create the skip file yourself — gates reject/delete skip files <30s old (anti-self-bypass). The user must `touch <PROJECT_ROOT>/<STATE_DIR>/skip-<GATE>.local` in their own terminal (`<STATE_DIR>` = `${BUSDRIVER_STATE_DIR:-.claude}` — defaults to `.claude`; the gate names it verbatim in its block message. Resolve it, NEVER hardcode `.claude`, and give the user the absolute path).
- NEVER `sleep` directly via Bash — wait via `Monitor(command: "sleep 35 && echo READY", timeout: 45)`.
- NEVER verify the skip file (`test -f`/`ls`/`stat`/`cat`/`find`) before retrying — it gets consumed on any intervening tool call. Just wait and retry the blocked action directly.
- NEVER ask the user to wait — Claude waits via Monitor.
- After the user confirms "done", make NO tool calls except `Monitor` before retrying — any intervening call consumes the skip file. If the retry still blocks, the file was consumed mid-wait; ask the user to `touch` it again and restart the wait.

All bypasses logged to `.claude/bypass-log.jsonl`. Full procedure + failure-mode taxonomy: `references/gate-recovery.md`.
