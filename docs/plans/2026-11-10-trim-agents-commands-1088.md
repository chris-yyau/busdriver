# Plan — Trim unused agents and commands (#1088, ADR 0048 agents/commands round)

**Status:** Draft (rev 2 — review round 1 addressed) · **Date:** 2026-11-10 · **Issue:** #1088 · **Branch:** `chore/1088-trim-agents-commands`

## Context

ADR 0048 trimmed `skills/` to the pipeline-only set and explicitly deferred the rest:
"Whether the remaining ECC dependency (mostly `agents/` and `commands/`) is worth keeping is
deferred to the agents/commands round" (`docs/adr/0048-pipeline-only-skill-set.md:48`).
This is that round.

Evidence (local transcripts, `~/.claude/projects/**`, 2026-09-23 → 2026-11-10, deduplicated by
`tool_use` id):

- 1,418 Agent-tool dispatches. Named busdriver agents dispatched: `pr-grinder` 1,012,
  `code-reviewer` 7, `security-reviewer` 1. The other 37 agents: 0.
- `pr-security-backstop` shows 0 dispatches but runs on every PR through
  `skills/litmus/scripts/run-review-loop.sh` (not the Agent tool) — **dispatch count alone is
  not the deletion criterion.**
- 0 of 61 busdriver commands were typed. Skill-tool invocations: `save-session` 22,
  `ultimate-council` 2.

**Deletion criterion (primary):** nothing that stays — `hooks/hooks.json`, gate scripts, kept
skills and supplements, `rules/common/`, ADR-pinned tests, live hook-driven subsystems — names
the item. Usage data is supporting evidence. When in doubt, keep.

**Cost of keeping (why bother):** every session's system prompt lists all agent descriptions
(~3k tokens/turn re-read from cache), descriptions such as "MUST BE USED" / "Use PROACTIVELY"
pull the model toward agents nobody uses, and each file is maintained by the effort-tier test,
the model-route validator and the ECC upstream sync.

**Out of scope:** model routing (ADR 0046 stays — every kept agent remains `model: opus`), effort
tiers of kept agents, skills (ADR 0048 settled them), scripts not orphaned by this change
(e.g. `scripts/claw.js`, `scripts/auto-update.js`; `scripts/ecc.js` already maps a
`loop-status` subcommand to a missing `loop-status.js` — pre-existing, untouched, an accepted
sweep residual since it names an `ecc` subcommand, not the slash command), the wording of kept
agents' descriptions (`planner`/`architect` keep "Use PROACTIVELY": they are `status: sync`
and editing them only to soften routing would fork them for no functional gain), the operator's
`~/.claude/scripts/sync-upstream.sh` (it lives outside this repo), historical ADRs and plans
(left verbatim as record).

## Decision

### Agents — keep 7, delete 33

| Keep | Why |
|------|-----|
| `pr-grinder` | pr-grind; named by gate scripts and tests |
| `pr-security-backstop` | litmus PR mode (`run-review-loop.sh`) |
| `code-reviewer` | used; `/santa-loop`; council routing table |
| `security-reviewer` | used; orchestrator Phase 5 |
| `planner`, `architect` | council routing table (`skills/council/SKILL.md:497-498`); `/plan` |
| `tdd-guide` | pinned by `tests/test-adr-0038-tdd-not-default.sh` (ADR 0038) |

Delete: `a11y-architect`, `agent-evaluator`, `build-error-resolver`, `chief-of-staff`,
`code-architect`, `code-explorer`, `code-simplifier`, `comment-analyzer`,
`conversation-analyzer`, `database-reviewer`, `doc-updater`, `e2e-runner`, `fastapi-reviewer`,
`gan-evaluator`, `gan-generator`, `gan-planner`, `harness-optimizer`, `loop-operator`,
`marketing-agent`, `opensource-forker`, `opensource-packager`, `opensource-sanitizer`,
`performance-optimizer`, `plan-code-reviewer`, `pr-test-analyzer`, `python-reviewer`,
`react-build-resolver`, `react-reviewer`, `refactor-cleaner`, `seo-specialist`,
`silent-failure-hunter`, `type-design-analyzer`, `typescript-reviewer`.

### Commands — keep 22, delete 39

| Keep | Why |
|------|-----|
| `save-session`, `resume-session`, `sessions` | used; `scripts/hooks/session-start.js:698` names `/sessions` |
| `ultimate-council`, `ultra-council`, `ultraoracle` | used; council family, `tests/test-ultra-council.sh` |
| `tdd` | ADR 0038 test; `rules/common/validate-before-building.md` |
| `verify`, `eval` | named by kept skills `verification-loop`, `eval-harness` |
| `plan`, `santa-loop` | surfaces of kept agents; council routing table |
| `cost-report` | only user surface of the live `cost-tracker.js` hook |
| `refine-notes` | named by a live `tasks-catalog.md` route; when in doubt, keep |
| `instinct-status`, `instinct-import`, `instinct-export`, `promote`, `projects`, `evolve`, `prune`, `learn`, `learn-eval` | continuous-learning-v2 surfaces: the observer is live in `hooks.json` and `load_instincts.py:226` names `/instinct-status` and `/promote`; the others are kept as the same subsystem's manual surface (when in doubt, keep). `observer-loop.sh` calls the `prune` CLI subcommand, not the slash command |

Delete: `aside`, `auto-update`, `build-fix`, `checkpoint`, `code-review`, `codex-goal`,
`fastapi-review`, `feature-dev`, `gan-build`, `gan-design`, `harness-audit`, `hookify`,
`hookify-configure`, `hookify-help`, `hookify-list`, `loop-start`, `loop-status`,
`model-route`, `multi-backend`, `multi-execute`, `multi-frontend`, `multi-plan`,
`multi-workflow`, `pm2`, `project-init`, `prp-commit`, `prp-implement`, `prp-plan`,
`prp-pr`, `prp-prd`, `quality-gate`, `refactor-clean`, `review-pr`, `setup-pm`,
`skill-create`, `skill-health`, `test-coverage`, `update-codemaps`, `update-docs`.

Notes: the hookify commands have no engine in this repo (no script or hook names hookify).
`codex-goal`'s backing skill `codex-goal-handover` stays invocable. `quality-gate.js` keeps
running as a hook; only its manual command goes. `scripts/auto-update.js` is not touched.

### Scripts orphaned by the deletions — delete 5 files, one directory, one test

`scripts/gan-harness.sh`, `scripts/harness-audit.js`, `scripts/skill-create-output.js`,
`scripts/skills-health.js`, `scripts/lib/skill-evolution/` (6 files, imported only by
`skills-health.js`), and `scripts/lib/suggest-compact-registration.js` with its test
`__tests__/suggest-compact-registration.test.ts` (its only non-test caller is
`harness-audit.js`). After the deletions each has **zero in-repo callers** (verified by grep
over tracked `*.js|*.ts|*.sh|*.md|*.json|*.yml`, excluding `docs/adr|plans|reviews`).
`scripts/setup-package-manager.js` **stays** — `skills/tdd-workflow/SKILL.md:95` calls it.

### Manifest and upstream sync

`~/.claude/scripts/sync-upstream.sh` never copies new upstream files and never reads
`rejected[]`; `detect_new_files()` compares upstream against `files[].upstream_path` and reports
anything unmatched as a NEW candidate for manual adoption. So removing the `files[]` entries does
**not** risk silent re-import — it makes every deleted path reappear as NEW-candidate noise on
each sync run, which could tempt re-adoption. `rejected[]` is therefore an **advisory record** a
maintainer reads before adopting, matching how the existing entries are used. Making the sync
script honour `rejected[]` is out of scope (the script is outside this repo).

**General rule:** every `status: sync` file this change edits flips to `status: custom` with a
`custom_reason` citing ADR 0062, in the same commit — otherwise the next sync reverts the edit.

## Tasks

The repository squash-merges, so main sees one commit; the branch still keeps each commit green
where a test enforces "same commit".

1. **Recovery anchor.** Push branch `pre-trim-agents-2026-11-10` at the merge base
   (`origin/main`). → verify: `git ls-remote origin pre-trim-agents-2026-11-10` returns the oid.
2. **Deletion + manifest commit** (`refactor(agents)!:` with `BREAKING CHANGE:` footer — removals
   ship as a major, as #773 did):
   - `git rm` the 33 agents, 39 commands, 4 scripts, `scripts/lib/skill-evolution/`, and
     `skills/supplements/diff-aware-qa.md` (its only target, `e2e-runner`, is deleted).
   - `git rm` `scripts/lib/suggest-compact-registration.js` and
     `__tests__/suggest-compact-registration.test.ts` in the same commit.
   - In the same commit, drop every `files[]` entry from `.upstream-sources.json` whose path is
     in the deletion set, derived by script from the `git rm` list (not hand-counted; round-1
     inventory: 74 command/agent/script entries — `commands/codex-goal.md` was never
     registered — plus `diff-aware-qa.md`, `skills-health.js` and the `skill-evolution/*`
     entries).
   - Add one **exact-path** `rejected[]` object per removed upstream-sourced entry, generated
     from that entry's own `source` and `upstream_path` — never a directory glob, because
     `agents/` and `commands/` keep upstream files (e.g. ECC `agents/code-reviewer.md`). Shape
     `{source, upstream_path, reason: "unused; deleted by ADR 0062 (#1088)", date: "2026-11-10"}`.
     Local-only entries get no `rejected[]` record.
   - → verify: `bash tests/test-upstream-manifest.sh` passes on this commit.
3. **Rewire commit** — remove or retarget every live reference:
   - **Orchestrator** (`skills/orchestrator/SKILL.md`, `tasks-catalog.md`,
     `domain-supplements.md`, `session-brief.md`), with these replacements:
     - **One substitution rule everywhere** (orchestrator files, `README.md`, `CONTRIBUTING.md`):
       a route to a deleted language/domain **reviewer** (`typescript-`, `python-`, `react-`,
       `fastapi-`, `database-reviewer`) → `code-reviewer`, plus `security-reviewer` for
       security-sensitive diffs; a route to a deleted **build resolver**
       (`build-error-resolver`, `react-build-resolver`) → `busdriver:systematic-debugging`
       (already the stated fallback). Known sites: `SKILL.md:108` (reviewer dispatch),
       `SKILL.md:112` (build-resolver dispatch), `SKILL.md:162`, `domain-supplements.md:5`,
       `:9-12`, `:16-20`, `:25`, `:29` (drop "NOT optional"), `README.md:66`. The task-4 sweep,
       not this list, is the completeness check.
     - Phase 5 specialists `silent-failure-hunter` / `type-design-analyzer` /
       `pr-test-analyzer` (`SKILL.md:122-125`) → removed, with one line noting that
       `code-reviewer` covers swallowed errors and missing tests (`agents/code-reviewer.md:151`,
       `:154`) and that dedicated type-design review has no replacement (accepted loss).
     - Contributor prose using the `{lang}-reviewer` template (`skills/orchestrator/INSTALL.md:32`,
       `skills/orchestrator/README.md`, `CONTRIBUTING.md:47-48`, `:142`) → reworded to the
       substitution rule above.
     - `tasks-catalog.md:33` Codex Goal row → retarget to the skill `busdriver:codex-goal-handover`
       (keeps the only keyword route to it).
     - **Catalog rows are edited at cell level, not dropped wholesale.** A row whose routes are all
       deleted is removed; a row mixing kept and deleted routes keeps the row and drops only the
       deleted route. Known mixed rows: Multi-Service (`dispatching-parallel-agents` stays,
       `/pm2` goes), Agent Self-Evaluation (`agent-self-evaluation` stays, `agent-evaluator`
       goes), Context/Session (`/save-session`, `/resume-session`, `/sessions`,
       `strategic-compact` stay, `/aside` goes). Plan Review (`plan-code-reviewer`) → removed.
   - **Kept command bodies:** `commands/plan.md:184-191` → `/build-fix` to
     `busdriver:systematic-debugging`; `/code-review` to the `code-reviewer` agent (or
     `/santa-loop`); `/prp-pr` to `busdriver:finishing-a-development-branch` (its PR option opens
     the PR and hands off to `pr-grind` — `pr-grind` alone needs an existing PR); `/prp-plan`,
     `/prp-prd`, `/prp-implement` to `busdriver:writing-plans` / `busdriver:executing-plans`.
     `commands/instinct-status.md:14` → drop `/skill-health`.
     Every other kept command body is swept the same way. Both files are `status: sync` → flip
     to `custom` (general rule).
   - **Kept script comment:** `scripts/setup-package-manager.js:6` names `/setup-pm` → reword;
     flip to `custom` if it is `status: sync`.
   - **Supplements:** `MANIFEST.md` row for `diff-aware-qa.md` → removed;
     `worktree-git-stash.md:35` example `/checkpoint` → reworded without it.
   - **All 7 kept agents** (`pr-grinder`, `pr-security-backstop`, `planner`, `architect`,
     `code-reviewer`, `security-reviewer`, `tdd-guide`): bodies swept for deleted names; any
     edited `status: sync` agent flips to `custom` (general rule).
   - `scripts/ci/validate-commands.js:131` comment uses `/build-fix` as an example → **leave it**
     (the file is ECC `status: sync`; forking it for a comment is the same trade the plan
     refuses for `planner`/`architect`) and list it as an accepted sweep residual.
   - **Tests:** `tests/test-agent-effort-tiers.sh` `GATE_CRITICAL` (line 47) drops
     `opensource-sanitizer` and `opensource-forker`, and gains an assertion that every
     `GATE_CRITICAL` name exists under `agents/` (a stale name is otherwise silent — line 111
     only matches agents present on disk). `__tests__/validate-model-routes.test.ts` and
     `scripts/ci/validate-agents.js` are swept for deleted names. `scripts/ci/validate-commands.js`
     needs no logic change — it builds its valid sets from disk and names `/build-fix` and
     `agents/planner.md` only in comments; it is the check that fails the command bodies above.
   - **Docs:** `README.md`, `CONTRIBUTING.md`, project `.claude/CLAUDE.md`, plugin manifests if
     they enumerate agents/commands or counts.
   - `hooks/gate-scripts/check-design-document.sh:190` names `agents/plan-code-reviewer.md` only
     as a false-positive example in a comment — **leave it** (no gate-script diff, no
     `.gate-integrity.lock` churn).
   - **ADRs:** new `docs/adr/0062-trim-agents-commands.md` (Context / Decision / Alternatives /
     Consequences / Revisit trigger). It records that it supersedes the membership of ADR 0009
     decision 3 (the gate-critical list loses the two opensource agents), and that the skills
     ADR 0048:40 justified as "checked for by `scripts/harness-audit.js`" (`eval-harness`,
     `security-review`, `cost-aware-llm-pipeline`) are no longer anchored by that script.
     Amend ADR 0048 line 48 and ADR 0009's decision-3 list with a one-line pointer to 0062.
4. **Dangling-reference sweep** (the acceptance check), as a script over tracked files outside
   `docs/adr/`, `docs/plans/`, `docs/specs/`, `docs/reviews/`, `CHANGELOG.md`. For each deleted
   name it matches `busdriver:<name>`, `agents/<name>.md`, `commands/<name>.md`, a slash command
   `/<name>` (the `/` must start the line or follow whitespace, a backtick, `(` or `|` — so a path
   segment such as `scripts/auto-update` is not a command), `` `<name>` ``, and for agents only
   the bare word and the bare `<name>.md` filename. Boundaries: the preceding character is not in
   `[A-Za-z0-9_.-]`; the following text is not `[A-Za-z0-9_-]` and not `.` followed by a
   letter/digit (except the agent `.md` form) — so path continuations (`<name>.js`, `<name>-…`)
   and URLs do not match while a name ending a sentence (`<name>.` / `<name>.md.`) still does.
   Command names are matched only in their command forms (never as a bare word), so ordinary
   words such as "checkpoint", "aside" or a `repair`/`uninstall`/`auto-update` list in prose do
   not hit. The script asserts required hits and non-hits on fixture strings so a wrong pattern
   fails loudly — hits: `see python-reviewer.md.`, `` run `/aside` ``; non-hits:
   `codex-goal-handover`, `code-reviewer`, `scripts/hooks/quality-gate.js`,
   `scripts/auto-update.js`, "take a checkpoint, then an aside". Accepted residuals: the
   `scripts/ecc.js` `loop-status` subcommand (see Out of scope), the
   `scripts/ci/validate-commands.js:131` and `hooks/gate-scripts/check-design-document.sh:190`
   comments (both deliberately left, see task 3).
   → verify: zero hits, or each remaining hit listed in the PR body with why it stays.

## Verification

- `npm run validate` (includes `validate-model-routes.js`, `validate-commands.js`,
  `validate-agents.js`).
- `npm test` (vitest), `scripts/test-python.sh`, and the shell suites
  `tests/test-upstream-manifest.sh`, `tests/test-agent-effort-tiers.sh`,
  `tests/test-adr-0038-tdd-not-default.sh`, `tests/test-ultra-council.sh`,
  `tests/test-litmus-shortcircuit-passive.sh`, `tests/test-gate-integrity.sh`.
- `./scripts/gate-integrity.sh --check` passes with no lock change (no locked dir touched).
- The sweep in task 4.
- Tree check (pre-merge): `ls agents/*.md | wc -l` = 7 and `ls commands/*.md | wc -l` = 22.
- Smoke (post-release only — sessions load busdriver from the installed plugin cache, not the
  worktree): after the release reaches the cache, a fresh session lists exactly the 7 kept
  `busdriver:` agents.

## Risks

- **A deleted item is used in a way the transcripts and grep miss** (an external script, another
  machine). Mitigation: recovery anchor branch; `git checkout pre-trim-agents-2026-11-10 --
  agents/<name>.md` restores any file. Transcript window is ~7 weeks.
- **NEW-candidate noise on every upstream sync** tempts re-adoption of a deleted file.
  Mitigation: the exact-path `rejected[]` records the decision and its ADR where a maintainer
  checks before adopting.
- **Upstream sync reverts a rewire.** Mitigation: the sync→custom general rule.
- **Major release.** Accepted — #773 set the precedent; busdriver is single-operator.

## Revisit trigger

A deleted agent or command is wanted twice within a quarter → restore it from the anchor and
record the use case in ADR 0062.

<!-- design-review-coverage: DEGRADED 2/3 reviewer_1=runtime-failed -->
