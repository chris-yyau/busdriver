# ADR 0008: Opus-Default Blueprint-Review Arbiter (Drop Fable)

> **Amended by [ADR 0011](./0011-ultimate-tier-fable-surfaces.md) (2026-07-03, rename: ultra arbiter → ultimate arbiter).** The opt-in gateway-fable escalation this ADR calls the "ultra arbiter" is renamed the **"ultimate arbiter"** (the `ultimate` tier = Claude Fable via the zenmux gateway; `ultra*` stays reserved for the GPT-5.5 Pro / UltraOracle surfaces). The USER opt-in moved from `.ultraArbiter.enabled` to `.ultimate.surfaces.arbiter`, the env force `BLUEPRINT_ARBITER_ULTRA=1` → `BUSDRIVER_ULTIMATE=1`, and `model_pin_status` `ultra_arbiter_*` → `ultimate_arbiter_*`. Only labels/keys changed — the opus-default decision and containment posture of this ADR are unchanged. Body below left as historical record.

## Status

Accepted (2026-07-01). Supersedes the arbiter-*model* decisions of
[ADR 0003](./0003-fresh-subagent-arbiter-for-blueprint-review.md) (the `model: fable`
pin + fallback chain) and the "Fable arbiter" label throughout
[ADR 0007](./0007-ultraoracle-expert-witness-and-ultra-council.md). The fresh-subagent /
author≠judge / context-firewall decisions of ADR 0003 and the arbiter *contract* of
ADR 0007 remain in force — only the pinned model changes.

## Date

2026-07-01

## Context

The blueprint-review arbiter was pinned to `model: fable` (ADR 0003), with an
unsupported-`fable` fallback chain `fable → gateway fable → opus → inherit`. `fable` is
being removed from the subscription plan. Once it is gone, every arbiter dispatch would
begin by attempting `fable`, take a recognized-unsupported-model error, and walk the
chain — a guaranteed wasted dispatch on every review. Two tail rungs were also dead
weight: the **inherit** rung and the **inline (user-authorized) degraded** allowance both
assume same-session availability, so they add no resilience over a fresh-`opus` dispatch
(same auth, same plan), and inline arbitration reintroduces the author-as-judge bias that
ADR 0003 exists to eliminate.

## Decision

1. **Pin the arbiter to `opus` by default** — the strongest available *subscription*
   model, and a verified Agent-tool value (this migration's own design-review arbiter
   ran on `opus`). On success, `model_pin_status=pinned`.
2. **Drop the fable primary pin, the inherit rung, and the inline-degraded allowance.**
   A persistent `opus` dispatch failure is a fail-closed **STOP** (report to the user),
   not a silent degradation — one retry covers transient rate-limit / 529s.
3. **Retain the gateway-fable path, re-cast as an opt-in "ultra arbiter" escalation**
   *above* the default `opus` (not an automatic fallback). It is gated by an operator
   **USER-level** opt-in — a top-level `.ultraArbiter.enabled` in USER
   `~/.claude/busdriver.json` and/or `BLUEPRINT_ARBITER_ULTRA=1` — mirroring the
   `ultraOracle` USER-config boundary so a repo-controlled config or any reviewed content
   (design doc, prompt, review artifacts) can never trigger it. New `model_pin_status`
   values: `ultra_arbiter_fable` (escalation ran) and `ultra_arbiter_unavailable`
   (opt-in set but gateway unconfigured or failed twice → ran `opus`, degraded, with a
   loud caller-side `WARNING`). The retired values `gateway_fable_fallback`,
   `opus_fallback`, and `inherited_fallback` are dropped from the live contract (they
   remain in historical artifacts; readers tolerate unknown legacy values).
4. **The gateway helper's credential-containment and AWS/provider `env -u` scrub are
   unchanged** — the escalation reuses the existing hardened `dispatch-gateway-arbiter.sh`
   machinery verbatim.

## Alternatives considered

- **Keep `fable` as primary, rely on the fallback chain.** Rejected: guarantees a wasted
  dispatch per review once `fable` leaves the plan.
- **Keep the inherit / inline rungs as a safety net.** Rejected: they buy no real
  resilience (same-session auth) and inline reintroduces author-as-judge bias.
- **Make the gateway path an automatic fallback (as before).** Rejected: with `opus` as a
  strong default, routing to a metered third-party gateway should be a deliberate,
  operator-controlled escalation, not silent behaviour — matching the cost-awareness and
  data-boundary posture of `ultraOracle`.

## Consequences

- Arbiter runs at `opus` with no fallback walk; simpler and no wasted dispatches.
- Fable-quality arbitration is still reachable on explicit USER opt-in, at metered gateway
  cost, via the unchanged hardened helper.
- Retired `*_fallback` status values persist in historical `docs/reviews/*/*.json`,
  `state.md`, and coverage JSONL — these are frozen records; consumers tolerate unknown
  `model_pin_status` values (the field has no code consumers today — caller-side only).
- **Deferred (tracked in [#265](https://github.com/chris-yyau/busdriver/issues/265)):**
  code-level enforcement of the opt-in — a guard in `dispatch-gateway-arbiter.sh`, a
  dedicated `scripts/lib/ultra-arbiter-config.sh`, a static contract test, and CI
  enforcement. Until then the gateway path is creds-gated exactly as before — no
  behavioural regression.

## Revisit trigger

Revisit if `opus` is renamed/retired or ceases to be a valid Agent-tool pin, if `fable`
returns to the subscription plan, or if a non-solo operator/threat model makes the
prose-level opt-in insufficient before #265 lands.
