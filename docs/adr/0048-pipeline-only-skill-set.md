# ADR 0048: Pipeline-Only Skill Set — Delete the Long Tail, Retire the Vault

## Status

Accepted (2026-08-26). Supersedes [ADR 0010](0010-skill-vault-lazy-tier-archive.md).

## Context

An audit on 2026-08-26 measured the plugin's skill surface against every retained Claude Code transcript (103 project directories), OMP session logs, and Cursor state:

- **189 live skills** (plus the `supplements/` support directory; ~14.1k frontmatter tokens re-read every turn) plus **201 vaulted** under `skills-archive/`.
- Only **14** skills had ever been invoked through the Skill tool; **27** had ever been Read. `pr-grind` (125), `litmus` (72), `save-session` (39), `blueprint-review` (28), `council` (12) account for almost all of it.
- The operator's edited-file mix is shell / Python / TypeScript. Zero Go, Rust, Kotlin, Dart, Swift files were ever touched, so the language packs and their paired reviewer / build-resolver agents never fired.
- The ADR 0010 vault produced **zero promotions** in eight weeks, while 286 `(vault)` marker lines, a contract test, a promote script, and ~475 archived manifest entries had to be maintained, and upstream sync spent seven commits refreshing files nobody read.
- The third-party toolbox skills vendored by PR #228 (`agent-browser`, `firecrawl`, `tavily-cli`, `context7-cli`, `deep-research`, `humanizer`, the taste-skill design cluster, Vercel/Expo/Supabase guides) were never loaded through busdriver by any consumer. The agents that do use them (Hermes, Codex, Cursor) read `~/.agents/skills` directly. Frontend design work in practice runs through OMP's `designer` model role, not a Claude-side taste skill.
- OMP and Cursor Agent both resolve busdriver through Claude's `installed_plugins.json` and scan the same `skills/` directory, so any change here reaches all three consumers identically.

The conclusion the operator reached: busdriver's value is the **pipeline** — hook-enforced gates, cross-session state, external review and dispatch orchestration — and everything else is either frontier-model knowledge or another tool's job.

## Decision

1. **Keep 37 skills (plus the `supplements/` support directory).** The test for survival is "does this do something the model cannot do for itself, or does the orchestrator invoke it as pipeline discipline?" Kept: `litmus`, `pr-grind`, `blueprint-review`, `orchestrator`, `gateguard`, `dispatch-cli`, `ultraoracle`, `zenmux`, `codex-goal-handover`, `council`, `imagegen`, `supplements`, `continuous-learning-v2`, `reflect`, `strategic-compact`, the fourteen superpowers workflow skills, `writing-prose`, `grill-me`, `tdd-workflow`, `verification-loop`, `skill-comply` and `agent-self-evaluation` (CI runs their pytest), and `eval-harness` / `security-review` / `cost-aware-llm-pipeline` (checked for by `scripts/harness-audit.js`).
2. **Delete, do not vault.** 152 live skills, the entire `skills-archive/`, `agents-archive/`, `commands-archive/`, the 17 command shims and 6 agents (`go-*`, `rust-*`, `pytorch-build-resolver`, `mle-reviewer`) that existed only for deleted skills, `scripts/vault-promote.sh`, `tests/test-vault-references.sh`, and every `(vault)` marker. The recovery anchor is git: branch `pre-trim-2026-08-26` at `0226ff45` (also `origin/main` at the time). `git checkout pre-trim-2026-08-26 -- skills/<name>` restores anything.
3. **Three skill sources on an operator machine, none overlapping:**
   - **busdriver** (this repo → Claude plugin registry → Claude Code, OMP, Cursor Agent): pipeline mechanics only.
   - **`~/.agents/skills`** (`npx skills add`, tracked by its lock file): third-party toolbox skills. Cursor and Codex read it natively; Hermes and Claude reach it through symlinks (`~/.claude/skills/<name> -> ../../.agents/skills/<name>`).
   - **`~/.local/share/agent-skills`**: skills the operator writes for more than one agent, mounted into each consumer as a `SKILL.md` symlink (the existing `agent-disk-hygiene` / `busdriver-consumer-update` / `um-executor` shape). `deep-research` (busdriver's own rewrite from PR #228) moves here.
4. **Routing to non-busdriver skills is best-effort.** Catalog rows marked *(personal)* name a skill that may be installed under `~/.claude/skills`; if it is absent the model falls back to built-in tools. Busdriver never routes to an absolute personal path (`scripts/ci/validate-no-personal-paths.js`).
5. **`humanizer` leaves busdriver too.** The vendored copy was an unmodified June snapshot (`status: sync`) already behind upstream; it is refreshed into `~/.agents/skills` from `blader/humanizer` and reaches Claude by symlink.
6. **`sync-upstream` stays** as maintainer tooling; its manifest shrinks from 1343 tracked files to 417 as a side effect. Whether the remaining ECC dependency (mostly `agents/` and `commands/`) is worth keeping is deferred to the agents/commands round.

## Alternatives Considered

- **Vault wave 2 (ADR 0010 mechanism).** Rejected: the mechanism's stated benefits (on-demand Read, upstream freshness, one-command promote) were never exercised, and its costs (marker hygiene, contract test, manifest rewrites) recur on every catalog edit.
- **Keep the pattern libraries for the operator's own stacks (Python/TS).** Rejected: zero reads in eight weeks; frontier models cover the content.
- **Keep the design cluster because CLAUDE.md marked it SETTLED.** Reopened deliberately: the settled routing protected a path with zero traffic; the operator's actual design engine is OMP's `designer` role, and `impeccable` covers the Claude side alone.

## Consequences

- Registry cost per turn drops by ~10k tokens (≈70% of the skill frontmatter) for Claude, OMP, and Cursor alike.
- `tasks-catalog.md` and `domain-supplements.md` shrink to what exists; there is no longer a reference-hygiene test, so the pre-PR sweep (`grep` for every deleted name across active surfaces) is the guard.
- Consumers snapshot skills at session start: after the marketplace clone fast-forwards (`busdriver-consumer-update`), OMP and Cursor need fresh sessions.
- Historical ADRs and `docs/plans/*` still mention deleted skills; they are records, not routes, and are left untouched.

## Revisit Trigger

A kept skill goes unused for 90 days (delete it), or a deleted skill is restored from the anchor twice (it belongs in a source — decide which of the three).
