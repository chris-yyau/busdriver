# 0009 — Per-agent reasoning `effort` tiers

**Status:** Accepted (2026-07-02)

## Context

Claude Code honors an `effort:` field in agent frontmatter (`low|medium|high|xhigh|max`;
sonnet caps at ~`high`, `xhigh`/`max` require an opus model). Verified honored on the
installed build (2.1.198) by binary inspection of the effort-branching logic.

Until now **no** agent in `agents/*.md` set `effort`, so every one of the 68 subagents
inherited the session/global default. In this operator's setup that default is `xhigh`
— so cheap, high-frequency mechanical agents (build resolvers, explorers) were reasoning
at near-max effort. A cost leak with no quality upside.

Because busdriver is a **plugin shipped to other users**, we cannot rely on each
consumer's global default. The effort tier must travel *in the agent file*.

## Decision

Tier every agent by **blast radius**, not role prestige:

| Tier | Applies to |
|------|-----------|
| `low` | read-only analysis/exploration only (no Write/Edit tool) |
| `medium` | ordinary reviewers **and anything that mutates the working tree** |
| `high` | hard-gate reviewers + irreversible/secret-handling actions |
| `xhigh` | opus-only deep reasoning: architecture, security, planning, db, performance |

Enforced by `tests/test-agent-effort-tiers.sh`, which asserts:
1. every agent has exactly one valid effort value (no missing/duplicate/malformed);
2. any agent with a `Write`/`Edit` tool is `>= medium` (never `low`);
3. gate-critical agents (`code-reviewer`, `security-reviewer`, `pr-security-backstop`,
   `opensource-sanitizer`, `opensource-forker`) are `>= high`;
4. `xhigh`/`max` agents declare `model: opus` (sonnet silently caps otherwise).

## Alternatives considered

- **Lower the global default to `medium` instead of per-agent lines.** Rejected: the
  global default lives in each consumer's own config; a shipped plugin can't set it. The
  per-agent line is the only portable mechanism.
- **Prose-only policy (this ADR, no test).** Rejected: a periodic upstream sync can clobber
  an effort line, silently reverting that agent to the `xhigh` default — an invisible cost
  regression. Prose can't catch that; the test can. This ADR documents intent; the test enforces it.
- **Also rebalance model tiers broadly.** Rejected for now — effort is the intended dial;
  model changes are higher-risk and were limited to 3 opus upgrades (code-architect,
  database-reviewer, performance-optimizer) done earlier.

## Consequences

- 20 mechanical agents drop off the inherited `xhigh`; the deep reasoners keep it.
- The test fails **red** on any sync that drops/clobbers a tier — a fail-closed signal, by design.
- Known limitation: the test *detects* drift, it does not auto-remediate. A red run means
  re-apply the tier by hand.
- Bash frontmatter parsing is tolerant (`^effort:`/`^model:`/`^tools:`); a radical reformat
  upstream could need the matcher updated.

## Revisit trigger

- Effort savings turn out negligible when measured (no token-delta was captured — direction,
  not magnitude, drove this), OR
- Claude Code changes the effort enum / model-cap semantics, OR
- a new gate-critical agent is added (extend invariant 3's list).
