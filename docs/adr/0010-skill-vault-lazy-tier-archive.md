# ADR 0010: Skill Vault — Lazy-Tier Archive for Long-Tail Skills

## Status

Accepted (2026-07-03).

## Context

The plugin had grown to 336 skills, 68 agents, and 89 commands. Every skill/agent
description is injected into the system-prompt registry of every session —
measured at ~27k tokens of frontmatter (~109KB skills + ~22KB agents) re-read on
every turn. Most of that surface is long-tail: niche domains (logistics,
healthcare, homelab, scientific, trading), language packs for stacks the operator
does not write (Java, Kotlin, Swift, Laravel, Django, C++/C#/F#/Perl), video/media
tooling, and speculative business one-offs.

An ultra-council review (2026-07-03) settled the design:

- The dollar cost of the registry is modest (sessions are cache-read dominated;
  the prefix bills at ~10% input rates). The real wins are **subscription
  rate-limit headroom and latency** — still worth the archive, with honest framing.
- A proposed usage-telemetry loop (PostToolUse hook on the Skill tool +
  `vault-gc` auto-promote/demote) was **rejected**: the signal is structurally
  blind to Read-loaded skills (domain supplements load via Read, not the Skill
  tool), and automation built on a known-blind metric is over-engineering.
- `sync-upstream` tracks files by live path in `.upstream-sources.json`; without
  a manifest rewrite the next sync would silently re-copy archived files back
  into `skills/` ("resurrection").

## Decision

1. **Archive dirs outside auto-discovery.** ~130 skills, 22 agents, and 12
   command shims move to `skills-archive/`, `agents-archive/`,
   `commands-archive/` at the plugin root. Zero registry cost; content preserved
   verbatim and still update-able from upstream.
2. **No new index skill.** `tasks-catalog.md` and `domain-supplements.md` are
   already lazy-loaded routing layers. Rows referencing archived items carry a
   literal `(vault)` marker; the orchestrator's "Vault (Archived Skills)"
   section defines the single loading convention (Read the archived file on
   demand and apply it).
3. **No usage telemetry, no vault-gc.** Promotion is manual-on-friction
   (`git mv` back when a skill keeps being loaded). Upgrade trigger recorded in
   the orchestrator: build tracking only if >3 manual promotions in 60 days.
4. **Contract test** (`tests/test-vault-references.sh`) enforces: (a) no name
   lives in both live and archive dirs (resurrection guard); (b) every active-
   surface reference to an archived name carries `(vault)` on the same line;
   (c) `.upstream-sources.json` never tracks an archived name at a live path.
5. **Manifest rewrite.** 260 `.upstream-sources.json` paths rewritten to their
   archive locations, so upstream sync updates land in the vault instead of
   resurrecting live skills.

## Alternatives Considered

- **New `skill-vault` index skill** — rejected: duplicates the existing lazy
  routing files and re-adds a description tax.
- **PostToolUse usage hook + automated GC** — rejected by council (blind signal,
  cache-churn concern, solo operator does not need a promotion economy).
- **Deleting the long tail** — rejected: capability is cheap to keep on disk and
  upstream sync keeps it fresh; only registry presence is expensive.

## Consequences

- Live registry drops from 336 to ~206 skills (~9-10k tokens off every turn),
  68→46 agents, 89→77 commands.
- Archived capability remains one Read away via `(vault)` routes; language packs
  promote back trivially if the operator's stack changes.
- `sync-upstream` policy (documented in the maintainer skill): new upstream
  files default to the archive unless they match the live stack.

## Revisit Trigger

>3 manual promotions in 60 days (build usage tracking), or the operator's
primary stack changes (bulk-promote the relevant language pack).
