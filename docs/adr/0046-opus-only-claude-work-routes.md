# ADR 0046 — Opus-only Claude work routes

**Status:** Accepted · **Date:** 2026-08-24 · **Issue:** #747
**Supersedes:** the model-tier paragraph of [ADR 0009](0009-agent-effort-tiers.md) (see Decision)

## Context

Live Claude routes across `commands/`, `agents/`, and executable skills pinned or
recommended Sonnet/Haiku: 34 agent files on `sonnet`, one on `haiku`, one unvalidated
skill-embedded agent on `haiku`, plus executable defaults in `claw.js`, `llm-summary.js`,
`agent-compress.js`, the observer loop, and the skill-comply scripts — and a *tiering
thesis* in prose (`agentic-engineering`, `subagent-driven-development`,
`prompt-optimizer`, a scored `harness-audit.js` check) that named no model at all.

Nothing enforced a policy, so drift was invisible and an upstream sync could reintroduce
it silently. This is the same failure mode ADR 0009 identified for `effort:` and solved
with a test plus an `.upstream-sources.json` note.

ADR 0009 explicitly deferred this change: "Also rebalance model tiers broadly. Rejected
for now — effort is the intended dial; model changes are higher-risk and were limited to
3 opus upgrades." That deferral is what this ADR reverses.

## Decision

**Every shipped default for Claude work is `opus`.** `effort:` remains the cost dial —
ADR 0009's mechanism is unchanged and is now the *only* one.

**Explicit env/CLI overrides are outside enforcement.** `CLAW_MODEL`,
`ECC_LLM_SUMMARY_MODEL`, `ECC_OBSERVER_MODEL` and skill-comply's `--model` /
`--gen-model` still accept other values; the *default* is the policy surface. A CLI
override is operator consent. An env override is not necessarily — ADR 0016's `env -i`
sanitization is applied by the gate wrappers, and the two hooks that carry these routes
are **not** among them: `hooks/hooks.json:233` (observer) and `:247` (PreCompact) inherit
the environment, so a committed `settings.json` `env` block can select a cheaper model
there. Accepted as a **cost/quality
residual, not an authority one**: neither route carries gate authority, reviewer
selection, or merge power.

**The only non-Opus Claude-family exception is a non-implementation Fable
plan/spec/advisory role.** Three live Fable Agent dispatch sites — the blueprint-review
arbiter, the council Mythos Witness (which `commands/ultimate-council.md` merely forces,
rather than being a fourth site), and the orchestrator advisor fallback — are **named,
grandfathered exceptions that currently retain broader
tool authority than this policy allows** (`general-purpose` and a bare
`Agent(model="fable")` both inherit the full default tool set). Constraining them touches
required review gates and settled ADR 0019/0025/0028 surfaces, so it is deliberately a
follow-up, not part of this change.

**Codex routing is outside this change.** Codex review/gate routes are untouched, and the
two Codex *implementation* cells in `skills/autonomous-loops/SKILL.md:462,466` are left
verbatim because the in-flight Pi replacement
(`docs/plans/2026-08-23-pi-replacement.md:170`) reserves exactly those two rows. So this
ADR does not claim Codex is review/gate-only today — it claims Codex routing is not this
change's subject.

## Enforcement

`scripts/ci/validate-model-routes.js`, run by `npm run validate` via
`scripts/ci/validate-all.js` (CI: `tests.yml`). It owns model policy for **agent
production metadata** — `agents/*.md` and skill-embedded agent files — and
`validate-agents.js` no longer carries a model list.

It is a **closed whitelist**, not a sonnet/haiku denylist: `opus`, or `fable` for a path
in `FABLE_ALLOWED` (shipped empty and frozen) that also declares a single-line,
parseable, non-empty `tools:` drawn from a positive read-only set, plus an explicit
`effort:` of `high` or below. A missing pin, a versioned id (`claude-sonnet-5`), another
vendor, a typo, a duplicate `model` key, or an omitted/indented `tools:` on a Fable agent
all fail — an omitted `tools:` means *inherited full access*, so it is a rejection rather
than a pass. `__tests__/validate-model-routes.test.ts` exercises every branch against a
temp mini-tree with the production constants left frozen.

**Scope is metadata, stated rather than overclaimed.** The check cannot see an executable
default, an unpinned `claude -p`, or a newly added route file. What protects those is
`.upstream-sources.json` provenance: the permanently-diverged files are now `custom`, and
the `ecc` and `superpowers` notes record the divergence — so `sync-upstream` surfaces them
as CUSTOM CHANGED with a default-no prompt instead of silently overwriting them. That
prevents *automated* reversion, not a hand-written regression.

## Consequences

- **Cost and latency rise on three recurring surfaces**: pr-grind rounds (per round),
  `llm-summary` (per session compact), and the observer loop (per interval). Watchdogs
  were re-sized with the pins — observer 120s → 600s, skill-comply classifier 60s → 180s,
  generators 120s → 300s, scenario runner 300s → 900s.
- **`LLM_TIMEOUT_MS` was lowered 90 000 → 25 000**, not raised: `pre-compact.js` has no
  `module.exports`, so `run-with-flags.js` runs it under a 30 000 ms `spawnSync` bound. At
  90 000 the outer bound always won and SIGTERMed the hook before its `if (!llmSummary)`
  fallback could write anything. A vitest case pins the ordering by reading both literals
  from source.
- **Plugin-wide blast radius.** ADR 0009:16-17 notes that busdriver ships to other users,
  so consumers cannot be relied on for a global default. Every consumer now inherits
  `opus` on all 35 flipped `agents/` files (34 sonnet + 1 haiku; the skill-embedded
  observer is a 36th, not shipped as a plugin agent) with no per-agent override;
  `effort:` is the only remaining dial. The operator accepts this for downstream
  consumers.
- **`harness-audit.js`'s `cost-model-route-command` check was deleted** — it scored the
  existence of `commands/model-route.md` as Cost Efficiency for "cheap-default execution",
  the thesis this ADR retires. `context-model-route` already asserts that file's presence;
  the Cost Efficiency subtotal drops by 3 points.
- **ADR 0009 is not edited.** Its model-tier deferral is superseded here; its `effort:`
  mechanism stands.

## Revisit trigger

Reopen if a materially cheaper Claude tier becomes capable enough that a measured
comparison — not an estimate — shows equivalent output on a named class of work, or if a
follow-up constrains the grandfathered Fable dispatch sites and the policy sentence can
be tightened from "grandfathered exceptions" to an enforced invariant.
