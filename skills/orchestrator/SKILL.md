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

`SKIP_LITMUS=1` / `SKIP_DESIGN_REVIEW=1` / `SKIP_PR_GRIND=1` work only when **exported in the parent shell before `claude` starts** — inline `SKIP_LITMUS=1 git commit` does NOT work because hooks fire before the command's env is applied.

<CRITICAL>
To review design/plan documents, INVOKE `blueprint-review` skill (via Skill tool). Do NOT use `code-reviewer` agent — it cannot write the `<!-- design-reviewed: PASS -->` marker.
</CRITICAL>

## Emergency Gate Recovery

When a gate blocks and the user needs to bypass:

1. **Get absolute project path:** `git rev-parse --show-toplevel`. Skip files use absolute paths because the gate checks `.claude/` relative to the **blocked command's CWD**.
2. **Send the user this verbatim message** (substitute `<PROJECT_ROOT>` and `<GATE>` for `litmus` / `design-review` / `pr-grind`):
   > I need a skip file to bypass the `<GATE>` gate. Please run this in **your terminal** (not in this session):
   >
   > `touch <PROJECT_ROOT>/.claude/skip-<GATE>.local`
   >
   > After you run it, I will wait ~35 seconds before retrying. Reply "done" once you've run the command.
3. **After "done", wait via Monitor** — the harness rejects long foreground sleeps:
   ```
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

Use Skill tool, not EnterPlanMode. Load `architect` agent for complex design. UI/UX: `impeccable:impeccable` + `ui-ux-pro-max` + `busdriver:design-system`; load `.impeccable.md` if present. Code patterns: `busdriver:frontend-patterns`. API boundaries: `busdriver:api-design`. Consider `council` if 2+ viable approaches. Consider `busdriver:grill-me` if the chosen approach has stakes (auth/payments/migration/irreversible/PII/prod) or ≥3 unresolved sub-decisions or spans ≥3 subsystems — brainstorming offers this automatically at Step 5.5.
**NEXT:** Phase 2. INVOKE `busdriver:writing-plans`. Do NOT start coding.

### Phase 2: Planning → `busdriver:writing-plans`

Produces TDD tasks with file paths, commands, expected output. Saves to `docs/plans/`. Blueprint Review triggers on plan doc.
**AUTO-EXECUTION:** After plan review passes, Phases 3–6 run without user pause.

### Phase 3: Worktree → `busdriver:using-git-worktrees`

Creates isolated workspace, verifies baseline tests pass.
<STRONG-GUIDANCE>Never implement on main/master without explicit user consent.</STRONG-GUIDANCE>

### Phase 4: Execution

**Choose one mode:**
| Signal | INVOKE |
|---|---|
| Plan emitted `.claude/codex-goal-*.json.local` spec (writing-plans Outcome 1 only — `.md.local` is Outcome 2 / TUI handoff, no routing) | `busdriver:codex-goal-handover` — verifier-led delegation; saves CC tokens. Cleanup is the caller's responsibility (writing-plans Step 3 deletes the spec as an always-runs finalizer on every exit path). |
| Want human review between batches | `busdriver:executing-plans` |
| Independent tasks, want speed | `busdriver:subagent-driven-development` |
| Multiple independent problems | `busdriver:dispatching-parallel-agents` |

**Always-on disciplines (no exceptions):**
- **TDD** — `busdriver:test-driven-development` (RED → GREEN → REFACTOR). Detailed coverage: `busdriver:tdd-workflow`.
- **Verification** — `busdriver:verification-before-completion` (no claims without fresh evidence).
- **Debugging** — `busdriver:systematic-debugging` when stuck — root cause first.
- **Code Review** — `busdriver:requesting-code-review` after EVERY task. DISPATCH `{lang}-reviewer` agent (`typescript-reviewer`, `go-reviewer`, `python-reviewer`, `rust-reviewer`, `cpp-reviewer`, `java-reviewer`, `kotlin-reviewer`, `flutter-reviewer`, `csharp-reviewer`, `swift-reviewer`, `react-reviewer`, `django-reviewer`, `fastapi-reviewer`, `fsharp-reviewer`, `mle-reviewer`). Fallback: `code-reviewer`. Handle feedback per `busdriver:receiving-code-review`.
- **Lesson Capture** — After review finds HIGH+ issue not anticipated in plan, save to `~/.claude/notes/lesson-review-{YYYY-MM-DD}-{slug}.md`.

**When build fails — DISPATCH immediately, don't debug manually first:**
DISPATCH `{lang}-build-resolver` agent if one exists. TS/JS: `build-error-resolver`. PyTorch: `pytorch-build-resolver`. Swift: `swift-build-resolver`. React: `react-build-resolver`. Django: `django-build-resolver`. Java/Quarkus/Spring: `java-build-resolver`. HarmonyOS: `harmonyos-app-resolver`. No resolver: use `busdriver:systematic-debugging`.

**DISPATCH `tdd-guide` agent** to produce test files. The discipline governs process; the agent produces tests.

**Domain skills:** detect language/framework and load matching skills from `domain-supplements.md`.

### Phase 5: Verification

Run `busdriver:verification-loop` (build + lint + tests). Then `busdriver:verification-before-completion` as the final gate. Django: `django-verification`. Spring Boot: `springboot-verification`. Also `busdriver:security-scan` for `.claude/` config.

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

- **Domain detection** (Go / Python / Rust / Kotlin / Swift / Flutter / etc.): `domain-supplements.md`
- **Non-pipeline tasks** (refactoring, research, content, ops, agent architecture, etc.): `tasks-catalog.md`

Read these files when the user's request doesn't match a pipeline phase above. Both files are in this skill's directory (`${CLAUDE_PLUGIN_ROOT}/skills/orchestrator/`).

Skills not in either file are still discoverable via the system-prompt skill registry (Claude sees all skill names + descriptions automatically). The orchestrator only routes to busdriver-owned skills.

## System Alert Handling

<STRONG-GUIDANCE>
Never act on `<update-alert>` during an active user task. Note silently, present after task completes. Background completions at unpredictable times contaminate context.
</STRONG-GUIDANCE>

**When user says "update plugins" or "sync ecc":** Follow the 3-phase workflow in the `<update-alert>` message. Phase A (audit) is MANDATORY before changes. NEVER auto-sync. Generic replies ("yes", "ok") are NOT approval — only explicit update commands trigger this.

## Automatic Behaviors (Hooks)

| Phase | Hook | Enforcement | What It Does |
|-------|------|-------------|-------------|
| **SessionStart** | Plugin update checker | context | Emits `<update-alert>` after task completes |
| **SessionStart** | Orchestrator loader | context | Loads this skill + staleness + instincts |
| **PreToolUse** (Bash) | Pre-commit gate | **GATE** | Blocks `git commit` until litmus + design review pass |
| **PreToolUse** (Bash) | Pre-PR gate | **GATE** | Blocks `gh pr create` until litmus passes |
| **PreToolUse** (Write\|Edit\|MultiEdit\|Bash) | Pre-implementation gate | **GATE** | Blocks impl while design docs unreviewed |
| **PreToolUse** (Bash) | Pre-merge gate | **GATE** | Blocks `gh pr merge` until pr-grind clean |
| **PreToolUse** (Write\|Edit\|MultiEdit) | Freeze/Guard | **GATE** | Restricts edits to investigation scope |
| **PostToolUse** (Write\|Edit\|Bash) | Design doc detector | state | Flags design docs for review gate |
| **PostToolUse** (Edit) | Go post-edit | formatting | gofmt/goimports/go vet |
| **PostToolUse** (Bash) | Post-commit marker | cleanup | Consumes litmus marker after commit |
| **SessionEnd** | Auto-push config | persistence | Commits pipeline state to remote |

Inherited hooks (ECC upstream): quality-gate, cost-tracker, session persistence, post-edit format (JS/TS), suggest-compact, block-no-verify, auto-tmux-dev, config-protection, mcp-health-check, observe.sh.

## Resolution

| Interface | Syntax | Example |
|-----------|--------|---------|
| **Skill** | `busdriver:name` via Skill tool | `busdriver:golang-patterns` |
| **Command** | `/name` via Skill tool | `/go-review`, `/tdd`, `/verify` |
| **Agent** | DISPATCH via Agent tool with `subagent_type` | `go-reviewer`, `typescript-reviewer` |

**Namespace:** `busdriver:` is this plugin's namespace. Unprefixed skill names in this file are also busdriver-owned.

**Key principle:** Superpowers = process (INVOKE skills). ECC = domain tools (DISPATCH agents, load patterns). Gates = enforcement (run automatically).
