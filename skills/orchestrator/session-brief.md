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

The only escape hatch is the gitignored, operator-created `.local` skip file (`.claude/skip-litmus.local`, `skip-design-review.local`, `skip-pr-grind.local`). The env-based `SKIP_*` skips were **removed** (#325 / ADR 0016): a committed `settings.json` `env` block could inject them, so gate env is now sanitized.

## Routing

Any task beyond trivial Q&A: INVOKE `busdriver:orchestrator` for full routing, or Read `tasks-catalog.md` (non-pipeline) / `domain-supplements.md` (domain detection) in this skill's dir. Rows marked `(vault)` = archived: Read `skills-archive/<name>/SKILL.md` (or `agents-archive/`, `commands-archive/`) on demand and apply directly.

## Supplements

**Supplement Loading Protocol:** Before invoking a skill or dispatching an agent, check `skills/supplements/MANIFEST.md` for active supplements targeting that skill/agent. If a match exists, Read the supplement file and apply its content alongside the skill. Opt-in supplements require an explicit trigger condition (a user trigger phrase OR an auto-memory signal listed in the manifest's Trigger column). Supplements are not injected by hooks — this is prompt-level guidance.

## Design Review (CRITICAL)

<CRITICAL>
To review design/plan documents, INVOKE `blueprint-review` skill (via Skill tool). Do NOT use `code-reviewer` agent — it cannot write the `<!-- design-reviewed: PASS -->` marker.
</CRITICAL>

## Advisor Fallback

`advisor()` is fable-backed and has been erroring in-account (`fable_advisor_temporarily_disabled` / `unavailable`). Still call it normally — the outage is transient, so trying it lets it recover. **Only when a call returns an error**, fall back once for that consult: dispatch a `fable` Agent subagent, hand it the task, your current approach, and the relevant transcript context (a subagent gets none automatically, unlike advisor), and ask it to play the same skeptical stronger-reviewer role. If the fable subagent is unavailable, run `opus` and print `WARNING: FABLE ADVISOR UNAVAILABLE — ran opus` so the degradation is never silent (subagent-only fable convention, ADR 0019). This is a **failure-triggered degraded fallback for a harness tool that is itself fable-backed** — not a proactive opt-in judge surface, so it is outside the ADR 0011 two-surface scope.

## Emergency Gate Recovery

When a gate blocks and the user needs to bypass, follow the full procedure in `references/gate-recovery.md` (in this skill's directory). **Hard rules — never violate:**
- NEVER create the skip file yourself — gates reject/delete skip files <30s old (anti-self-bypass). The user must `touch <PROJECT_ROOT>/<STATE_DIR>/skip-<GATE>.local` in their own terminal (`<STATE_DIR>` = `.claude` — defaults to `.claude`; the gate names it verbatim in its block message. Resolve it, NEVER hardcode `.claude`, and give the user the absolute path).
- NEVER `sleep` directly via Bash — wait via `Monitor(command: "sleep 35 && echo READY", timeout: 45)`.
- NEVER verify the skip file (`test -f`/`ls`/`stat`/`cat`/`find`) before retrying. During the 30s anti-self-bypass window any gated tool call still destroys it; past that window `skip-design-review.local` is a lease (#519 / ADR 0031) that read-only calls no longer spend, but verifying still tells you nothing useful. Just wait and retry the blocked action directly.
- NEVER ask the user to wait — Claude waits via Monitor.
- After the user confirms "done", make NO tool calls except `Monitor` before retrying — an intervening call that reaches the gate's skip-file logic consumes the skip file. That means the design-review gate's genuinely-gated calls, and litmus's own trigger command (`git commit`, `gh pr create`), both of which delete it in PreToolUse before the command runs. **`pr-grind` is the exception:** `gh pr merge` writes a pending claim instead, and the file is consumed only once the GitHub API confirms the PR merged (#664) — so a refused or PR-mismatched attempt leaves an **unchanged** file valid for the remainder of its original 3600s window, with no fresh `touch` needed. A locally failed merge is not automatically a reprieve: if the PR merged anyway (the `--delete-branch` worktree-conflict shape) the token is spent, as it is for an accepted `--auto` queue, which GitHub lands with no further hook event. That reprieve is narrower than it sounds: it does not cover a file that is missing, whose mtime moved, or whose window has expired. `post-merge-confirm-bypass.sh` treats a missing file as tampering and can only drop the pending claim — it cannot put the file back. In all three of those cases the user must `touch` it again. If the retry still blocks, the file was consumed mid-wait; ask the user to `touch` it again and restart the wait.

All bypasses logged to `.claude/bypass-log.jsonl`. Full procedure + failure-mode taxonomy: `references/gate-recovery.md`.
