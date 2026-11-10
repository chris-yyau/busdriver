# ADR 0062 — Trim agents and commands to what the pipeline uses

## Status

**Accepted (2026-11-10).** Settles the agents/commands round that
[ADR 0048](./0048-pipeline-only-skill-set.md) decision 6 deferred. Supersedes the membership of
[ADR 0009](./0009-agent-effort-tiers.md) decision 3 (the gate-critical list). Issue #1088. Plan:
`docs/plans/2026-11-10-trim-agents-commands-1088.md`. Recovery anchor: branch
`pre-trim-agents-2026-11-10` (= `a0745900`).

## Context

ADR 0048 cut `skills/` to pipeline mechanics and left `agents/` (40 files) and `commands/`
(61 files), most of them ECC imports, for a later round. Local transcripts from 2026-09-23 to
2026-11-10, deduplicated by `tool_use` id, show 1,418 Agent-tool dispatches: `pr-grinder` 1,012,
`code-reviewer` 7, `security-reviewer` 1, every other busdriver agent 0. None of the 61 commands
was typed; the Skill tool invoked `save-session` 22 times and `ultimate-council` twice.

Keeping them was not free. Every session's system prompt lists every agent description (about
3k tokens re-read from cache per turn), descriptions such as "MUST BE USED" and "Use PROACTIVELY"
pull the model toward agents nobody runs, and each file is carried by the effort-tier test, the
model-route validator and the upstream sync.

## Decision

1. **Deletion criterion:** an agent or command goes when nothing that stays names it — hooks,
   gate scripts, kept skills and supplements, `rules/common/`, ADR-pinned tests, live hook-driven
   subsystems. Usage is supporting evidence; when in doubt, keep.
2. **Keep 7 agents:** `pr-grinder`, `pr-security-backstop`, `code-reviewer`, `security-reviewer`,
   `planner`, `architect`, `tdd-guide`. Delete the other 33.
3. **Keep 22 commands:** the session family (`save-session`, `resume-session`, `sessions`), the
   council family (`ultra-council`, `ultimate-council`, `ultraoracle`), `tdd`, `verify`, `eval`,
   `plan`, `santa-loop`, `cost-report`, `refine-notes`, and the continuous-learning surfaces
   (`instinct-status`, `instinct-import`, `instinct-export`, `promote`, `projects`, `evolve`,
   `prune`, `learn`, `learn-eval`). Delete the other 39.
4. **One review route.** There are no per-language reviewers or build resolvers. Every diff goes
   to `code-reviewer`, security-sensitive diffs also to `security-reviewer`, and build failures to
   `busdriver:systematic-debugging`. The Phase 5 specialists (`silent-failure-hunter`,
   `type-design-analyzer`, `pr-test-analyzer`) are gone: `code-reviewer` already checks swallowed
   errors and missing tests; dedicated type-design review has no replacement.
5. **Scripts orphaned by the deletions go too:** `scripts/gan-harness.sh`,
   `scripts/harness-audit.js`, `scripts/skill-create-output.js`, `scripts/skills-health.js`,
   `scripts/lib/skill-evolution/`, `scripts/lib/suggest-compact-registration.js` (and its test),
   and the `diff-aware-qa.md` supplement whose only target was `e2e-runner`.
6. **Manifest:** every deleted path leaves `.upstream-sources.json` `files[]`; each
   upstream-sourced one gets an exact-path `rejected[]` record so a maintainer reviewing a sync's
   NEW-candidate list sees the decision. Kept `status: sync` files edited to drop deleted names
   (`commands/plan.md`, `commands/instinct-status.md`, `scripts/setup-package-manager.js`) flip to
   `custom`.
7. **Gate-critical list (ADR 0009 decision 3)** is now `code-reviewer`, `security-reviewer`,
   `pr-security-backstop`; `tests/test-agent-effort-tiers.sh` also fails when a listed name has no
   file under `agents/`.

The three skills ADR 0048 decision 1 kept as "checked for by `scripts/harness-audit.js`"
(`eval-harness`, `security-review`, `cost-aware-llm-pipeline`) are no longer anchored by that
script. They stay; whether they earn their place is a question for the next skills round.

## Alternatives considered

- **Keep everything, soften descriptions.** Cuts the routing pull but not the prompt cost or the
  maintenance, and forks `status: sync` files for wording alone.
- **Vault instead of delete.** ADR 0048 rejected vaults; git is the archive.
- **Delete by usage alone.** Would have removed `pr-security-backstop`, which runs on every PR
  through the litmus script rather than the Agent tool.

## Consequences

- Breaking change for anyone invoking a deleted agent or command; released as a major.
- The upstream sync reports each deleted ECC path as a NEW candidate on every run; the
  `rejected[]` record is the answer.
- `scripts/ecc.js` still maps a `loop-status` subcommand to a missing script — pre-existing and
  untouched. Two comments that use deleted names as examples stay
  (`scripts/ci/validate-commands.js`, `hooks/gate-scripts/check-design-document.sh`).

## Revisit trigger

A deleted agent or command is wanted twice within a quarter: restore it with
`git checkout pre-trim-agents-2026-11-10 -- <path>` and record the use case here.
