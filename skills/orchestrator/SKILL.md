---
name: orchestrator
description: >
  Use when starting any task, routing to skills, about to commit or deploy, writing new features or fixing bugs, after writing plans or design docs, debugging, doing code review, or uncertain which skill applies. Use when there is even a 1% chance a skill might apply — this is the single routing authority for superpowers, everything-claude-code, litmus, and blueprint-review.
---

# Master Orchestrator

<!-- This file is for ROUTING DECISIONS only. Implementation details live in each skill's own SKILL.md.
     Non-pipeline tasks: see `tasks-catalog.md`.
     Domain detection: see `domain-supplements.md`. -->

<EXTREMELY-IMPORTANT>
Follow the pipeline. Feature work goes through phases 1–6. Do NOT use EnterPlanMode for feature work — INVOKE `busdriver:brainstorming` (Phase 1) or `busdriver:writing-plans` (Phase 2) instead. EnterPlanMode is only acceptable for non-pipeline tasks.
</EXTREMELY-IMPORTANT>

## Architecture

Three layers, one pipeline:

1. **Superpowers Pipeline** (backbone) — Defines the process and order
2. **ECC + third-party skills** (tools) — Domain patterns + DISPATCHed agents
3. **Gates** (enforcement) — Hook-enforced reviews that cannot be bypassed

**Supplement Loading Protocol:** Before invoking a skill or dispatching an agent, check `skills/supplements/MANIFEST.md` for active supplements targeting that skill/agent. If a match exists, Read the supplement file and apply its content alongside the skill. Opt-in supplements require an explicit trigger condition (a user trigger phrase OR an auto-memory signal listed in the manifest's Trigger column). Supplements are not injected by hooks — this is prompt-level guidance.

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
| **Ref fast-forward** | `git merge` / `git pull` that would fast-forward a protected branch (#779). `git pull` there is refused outright; a merge must be the only command in its Bash call | `.claude/skip-litmus.local`, or a single-use operator-written `.claude/ref-ff-authorized.local` holding exactly `PASS-FF refs/heads/<branch> <oid>`, spent by `git merge --ff-only <oid>` naming that oid | `hooks/gate-scripts/ref-ff-gate.sh` |

The only escape hatch is the gitignored, operator-created `.local` skip file (`.claude/skip-litmus.local`, `skip-design-review.local`, `skip-pr-grind.local`). The env-based `SKIP_LITMUS` / `SKIP_DESIGN_REVIEW` / `SKIP_PR_GRIND` skips were **removed** (#325 / ADR 0016): a committed `settings.json` `env` block could inject them, so gate env is now sanitized (`env -i` + allowlist at the hook entry).

<CRITICAL>
To review design/plan documents, INVOKE `blueprint-review` skill (via Skill tool). Do NOT use `code-reviewer` agent — it cannot write the `<!-- design-reviewed: PASS -->` marker.
</CRITICAL>

## Emergency Gate Recovery

When a gate blocks and the user needs to bypass, follow the full procedure in `references/gate-recovery.md` (in this skill's directory). **Hard rules — never violate:**
- NEVER create the skip file yourself — gates reject/delete skip files <30s old (anti-self-bypass). The user must `touch <PROJECT_ROOT>/<STATE_DIR>/skip-<GATE>.local` in their own terminal (`<STATE_DIR>` is always `.claude` here — `hooks.json` launches the gate through `env -i`, which strips any `BUSDRIVER_STATE_DIR` an operator terminal exported, so the gate itself always resolves `.claude`; give the user the absolute path).
- NEVER `sleep` directly via Bash — wait via `Monitor(command: "sleep 35 && echo READY", timeout: 45)`.
- NEVER verify the skip file (`test -f`/`ls`/`stat`/`cat`/`find`) before retrying. During the 30s anti-self-bypass window any gated tool call still destroys it; past that window `skip-design-review.local` is a lease (#519 / ADR 0031) that read-only calls no longer spend, but verifying still tells you nothing useful. Just wait and retry the blocked action directly.
- NEVER ask the user to wait — Claude waits via Monitor.
- After the user confirms "done", make NO tool calls except `Monitor` before retrying — an intervening call that reaches the gate's skip-file logic consumes the skip file. That means the design-review gate's genuinely-gated calls, and litmus's own trigger command (`git commit`, `gh pr create`), both of which delete it in PreToolUse before the command runs. **`pr-grind` is the exception:** `gh pr merge` writes a pending claim instead, and the file is consumed only once the GitHub API confirms the PR merged (#664) — so a refused or PR-mismatched attempt leaves an **unchanged** file valid for the remainder of its original 3600s window, with no fresh `touch` needed. A locally failed merge is not automatically a reprieve: if the PR merged anyway (the `--delete-branch` worktree-conflict shape) the token is spent, as it is for an accepted `--auto` queue, which GitHub lands with no further hook event, and as it is for a merge steered at another repo/host (`-R`, `--repo`, or `GH_REPO`) — this checkout's same-numbered PR is a different pull request, so nothing here can query it, and the token is spent rather than left armed and unqueryable for the rest of its window. That reprieve is narrower than it sounds: it does not cover a file that is missing, whose mtime moved, or whose window has expired. `post-merge-confirm-bypass.sh` treats a missing file as tampering and can only drop the pending claim — it cannot put the file back. In all three of those cases the user must `touch` it again. If the retry still blocks, the file was consumed mid-wait; ask the user to `touch` it again and restart the wait.

All bypasses logged to `.claude/bypass-log.jsonl`. Full procedure + failure-mode taxonomy: `references/gate-recovery.md`.

## The Pipeline

### Entry Routing

| User's state | Entry | INVOKE | Then |
|---|---|---|---|
| Vague idea, exploring | Phase 1 | `busdriver:brainstorming` | → 2 → 3–6 (auto) |
| Clear requirements | Phase 2 | `busdriver:writing-plans` | → 3–6 (auto) |
| Has a plan file | Phase 3 | `busdriver:using-git-worktrees` | → 4 → 5 → 6 |
| Small specific task | Phase 4 | Execute directly | → 5 → 6 |
| Bug, test failure | Phase 4 | `busdriver:systematic-debugging` | Debug → fix → 5 → 6 |
| Write tests | Phase 4 | `/tdd` (tdd-guide agent) | Test task only |
| Not sure? | **Ask the user** | — | — |

**Auto-execution (Phases 3–6):** After plan review passes in Phase 2, the pipeline auto-continues without user pause: design-review → worktree → subagent-driven-development → verification → finishing. Halts on: design rejection (3 attempts), baseline test failure, or task blocker.

<STRONG-GUIDANCE>
DO NOT skip phases after your entry point. Only exception: small specific tasks entering at Phase 4.
</STRONG-GUIDANCE>

### Phase 1: Discovery → `busdriver:brainstorming`

Use Skill tool, not EnterPlanMode. Load `architect` agent for complex design. UI/UX: `impeccable:impeccable` (separately installed plugin) owns design end-to-end; load `.impeccable.md` if present. Consider `council` if 2+ viable approaches. Consider `busdriver:grill-me` if the chosen approach has stakes (auth/payments/migration/irreversible/PII/prod) or ≥3 unresolved sub-decisions or spans ≥3 subsystems — brainstorming offers this automatically at Step 5.5.
**NEXT:** Phase 2. INVOKE `busdriver:writing-plans`. Do NOT start coding.

### Phase 2: Planning → `busdriver:writing-plans`

Produces TDD tasks with file paths, commands, expected output. Saves to `docs/plans/`. Blueprint Review triggers on plan doc.
**Optional ultra-oracle advisory** (opt-in, USER config `ultraOracle.writingPlans.enabled`): before decomposition is locked in, a ChatGPT Pro consult *advises* on task sequencing/risk — distinct from Blueprint Review, which *critiques* the finished plan at the gate (advise → draft → critique). See writing-plans "Optional Ultra-Oracle Plan Advisory".
**AUTO-EXECUTION:** After plan review passes, Phases 3–6 run without user pause.

### Phase 3: Worktree → `busdriver:using-git-worktrees`

Creates isolated workspace, verifies baseline tests pass.
<STRONG-GUIDANCE>Never implement on main/master without explicit user consent.</STRONG-GUIDANCE>

### Phase 4: Execution

**Choose one mode:**
| Signal | INVOKE |
|---|---|
| Plan emitted `.claude/codex-goal-*.json.local` spec (writing-plans Outcome 1 only — `.md.local` is Outcome 2 / TUI handoff, no routing) | `busdriver:codex-goal-handover` — verifier-led delegation; saves CC tokens. Cleanup is the caller's responsibility (writing-plans Step 3 deletes the spec on graceful exits — green, bailed, or max-iters; session interruptions rely on the 2-hour orphan pre-flight instead). |
| Want human review between batches | `busdriver:executing-plans` |
| Independent tasks, want speed | `busdriver:subagent-driven-development` |
| Multiple independent problems | `busdriver:dispatching-parallel-agents` |

**Always-on disciplines (no exceptions):**
- **Tests** — behavioral changes ship with tests. **Ordering is not mandated** — RED → GREEN → REFACTOR is available on demand via `/tdd` (`busdriver:test-driven-development`, detail `busdriver:tdd-workflow`), not a Phase 4 default. Advisory, not gate-enforced: no hook checks test ordering or existence (ADR 0038).
- **Verification** — `busdriver:verification-before-completion` (no claims without fresh evidence).
- **Debugging** — `busdriver:systematic-debugging` when stuck — root cause first.
- **Code Review** — `busdriver:requesting-code-review` after EVERY task. DISPATCH `{lang}-reviewer` agent (`typescript-reviewer`, `python-reviewer`, `react-reviewer`, `fastapi-reviewer`). Fallback: `code-reviewer`. Handle feedback per `busdriver:receiving-code-review`.
- **Lesson Capture** — After review finds HIGH+ issue not anticipated in plan, save to `~/.claude/notes/lesson-review-{YYYY-MM-DD}-{slug}.md`.

**When build fails — DISPATCH immediately, don't debug manually first:**
DISPATCH `{lang}-build-resolver` agent if one exists. TS/JS: `build-error-resolver`. React: `react-build-resolver`. No resolver: use `busdriver:systematic-debugging`.

**Domain skills:** detect language/framework and load matching skills from `domain-supplements.md`. A language's `Testing:` entry is reference material, not an ordering mandate — RED-GREEN-REFACTOR stays opt-in per the Tests discipline above, even when the domain guide walks through it (ADR 0038).

### Phase 5: Verification

Run `busdriver:verification-loop` (build + lint + tests). Then `busdriver:verification-before-completion` as the final gate. If the change touches `.claude/` config, `hooks/`, agents, MCP servers, or settings, also run `busdriver:security-review` with the `skill-supply-chain.md` supplement (the former `security-scan` pass — supply-chain audit of hook/agent/skill/MCP wiring).

**DISPATCH `security-reviewer` agent** if auth, user input, API endpoints, payments, or secrets touched.

**DISPATCH selective specialists:**
- Error handling code → `silent-failure-hunter` agent
- Type definitions/interfaces → `type-design-analyzer` agent
- Tests added/modified → `pr-test-analyzer` agent

Consider `council` if architecturally significant or results seem "too clean."

### Phase 6: Finishing → `busdriver:finishing-a-development-branch`

Verify tests → present 4 options (merge/PR/keep/discard) → execute → clean up worktree.
**Gate:** Litmus fires automatically — fast at `git commit`, deep (multi-voice) at `gh pr create`.
**Post-PR:** If Option 2 (Create PR), `busdriver:pr-grind` is invoked automatically to address CI failures and reviewer comments, then merge. Do NOT enable GitHub auto-merge (races against pr-grind). Do NOT give compound "grind then merge" instructions.

## Routing Catalog

- **Domain detection** (Python / TypeScript / React / database / AI-LLM): `domain-supplements.md`
- **Non-pipeline tasks** (refactoring, research, content, ops, agent architecture, etc.): `tasks-catalog.md`

Read these files when the user's request doesn't match a pipeline phase above. Both files are in this skill's directory (`${CLAUDE_PLUGIN_ROOT}/skills/orchestrator/`).

Skills not in either file are still discoverable via the system-prompt skill registry (Claude sees all skill names + descriptions automatically). The orchestrator routes to busdriver-owned skills plus a few *(personal)* toolbox skills that are installed per machine (ADR 0048) — those are best-effort routes, not dependencies.


## System Alert Handling

<STRONG-GUIDANCE>
Never act on `<update-alert>` during an active user task. Note silently, present after task completes. Background completions at unpredictable times contaminate context.
</STRONG-GUIDANCE>

**When user says "update plugins" or "sync ecc":** Follow the 3-phase workflow in the `<update-alert>` message. Phase A (audit) is MANDATORY before changes. NEVER auto-sync. Generic replies ("yes", "ok") are NOT approval — only explicit update commands trigger this.

## Automatic Behaviors (Hooks)

Gates (pre-commit, pre-PR, pre-implementation, pre-merge, freeze) + formatting + state-tracking + persistence run automatically via PreToolUse/PostToolUse/SessionStart/SessionEnd hooks. Full table of every hook and what it does: `references/hooks-reference.md` (in this skill's directory).

## Resolution

| Interface | Syntax | Example |
|-----------|--------|---------|
| **Skill** | `busdriver:name` via Skill tool | `busdriver:litmus` |
| **Command** | `/name` via Skill tool | `/fastapi-review`, `/tdd`, `/verify` |
| **Agent** | DISPATCH via Agent tool with `subagent_type` | `python-reviewer`, `typescript-reviewer` |

**Namespace:** `busdriver:` is this plugin's namespace. Unprefixed skill names in this file are also busdriver-owned.

**Key principle:** Superpowers = process (INVOKE skills). ECC = domain tools (DISPATCH agents, load patterns). Gates = enforcement (run automatically).
