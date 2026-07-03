# ADR 0011: Ultimate Tier — Claude Fable Surfaces via the zenmux Gateway

## Status

Accepted (2026-07-03). Settled by an ultra-council review this session. Amends
[ADR 0008](./0008-opus-default-arbiter-drop-fable.md) (rename: "ultra arbiter" →
"ultimate arbiter") and extends [ADR 0007](./0007-ultraoracle-expert-witness-and-ultra-council.md)
(council expert-witness pattern) with a second witness.

## Date

2026-07-03

## Context

`fable` has been dropped from the subscription plan (ADR 0008), but the operator has a
~$1000/mo budget on a zenmux gateway that can serve **Claude Fable** (`claude-fable-5`) over
an Anthropic-API-compatible endpoint. Fable is a distinct-personality, strong model whose
value here is as a **judge / expert witness**, not a generator — a second lens on decisions
and design verdicts, complementary to the opus arbiter and the GPT-5.5 Pro UltraOracle.

Naming was a persistent source of confusion, so it is fixed as a convention:

- **`ultra*`** = ChatGPT Pro / GPT-5.5 Pro surfaces — `ultraoracle`, `ultra-council` (UNCHANGED).
- **`ultimate*`** = Claude Fable via the zenmux gateway (this ADR).

The ultra-council review reached a clear verdict: ship Fable as a **judge, not a generator**;
launch **two surfaces first** (not five); add **no budget guard** (the operator self-monitors
the gateway spend); and add **no proactive auto-proposals** until there is evidence Fable's
verdicts actually differ from opus's — roughly **~10 arbiter runs** showing verdict deltas
vs. opus before expanding.

## Decision

Ship exactly **two** ultimate surfaces now, both opt-in, both routed through one shared
helper `scripts/ultimate-dispatch.sh` (role slug + prompt file + output path; pins
`claude-fable-5`; fail-closed — loud warning + non-zero exit when gateway creds are missing or
the dispatch fails twice):

1. **Ultimate arbiter** (blueprint-review) — the existing gateway-fable escalation above the
   default opus arbiter, renamed from "ultra arbiter". USER opt-in is a top-level
   `.ultimate.surfaces.arbiter` in `~/.claude/busdriver.json`; env force `BUSDRIVER_ULTIMATE=1`
   (replacing `.ultraArbiter.enabled` / `BLUEPRINT_ARBITER_ULTRA=1`, dropped with no compat
   shim — solo operator). The trigger phrase "ultimate arbiter" authorizes one run with no
   config (gateway creds only). `model_pin_status` tokens renamed `ultra_arbiter_*` →
   `ultimate_arbiter_*`. The `arbiter` role of `ultimate-dispatch.sh` delegates to the
   unchanged, hardened `dispatch-gateway-arbiter.sh`; its credential-containment / provider
   scrub is untouched.

2. **Mythos Witness** (council) — a new second expert witness for the council, Claude Fable
   via the gateway, rendered as its own `## Mythos Witness — Expert Witness` section AFTER the
   UltraOracle section and BEFORE the Verdict. It is **never a vote**, EXCLUDED from
   consensus/dissent, and its claims are unverified-until-checked (like the Researcher's). A
   new trigger **"ultimate council"** runs the normal 5-voice council PLUS BOTH witnesses
   (UltraOracle AND Mythos); config gate `.ultimate.surfaces.council`; per-run force
   `ULTIMATE_COUNCIL_FORCE=1` (plain, non-exported, unset at end — mirroring
   `ULTRA_ORACLE_COUNCIL_FORCE`). A loud `MYTHOS_FAILED [status]` banner on failure, never a
   silent omission. "ultra council" is UNCHANGED (UltraOracle only).

Config shape (USER-only, security-sensitive — a repo config can never opt a reviewer in):

```json
{ "ultimate": { "surfaces": { "arbiter": true, "council": true } } }
```

Env force `BUSDRIVER_ULTIMATE=1` (or `0`) is a global tier override. Old keys are DROPPED with
no compatibility shim (single operator; migration is a one-line config edit).

## Alternatives Considered

- **5-surface launch (arbiter, council, litmus, brainstorming, plan-writing) — REJECTED** as
  scope creep. Litmus/brainstorming/plan-writing surfaces and ALL proactive auto-proposals are
  explicitly deferred until the two judge surfaces prove their value.
- **A budget guard / spend cap in code — REJECTED by the operator.** They monitor the gateway
  spend directly; a code-side cap adds machinery for a risk the operator already owns.
- **Keep the "ultra arbiter" name — REJECTED.** `ultra` already means the GPT-5.5 Pro surfaces;
  overloading it for a Claude-family model was the exact confusion this ADR removes.
- **A compat shim for the old `.ultraArbiter.enabled` key — REJECTED (YAGNI).** Solo operator;
  no external consumers to break.

## Consequences

- One shared dispatch path (`ultimate-dispatch.sh`) for both surfaces — future ultimate
  surfaces extend it rather than re-implementing gateway plumbing.
- Fable verdicts are metered API billing on the gateway, not flat subscription; the operator
  self-monitors. An ultimate-council runs two slow gateway/Pro consults, so it is minutes, not
  seconds — off by default, opt-in only.
- The `ultra*` / `ultimate*` split is now a hard naming convention; mixing them is a bug.

## Revisit Trigger

Expand beyond the two surfaces (litmus/brainstorming/plan-writing, or any proactive
auto-proposal) **only if Fable verdicts actually differ from opus's** — measured over ~10
ultimate-arbiter runs showing real verdict deltas vs. opus. If Fable merely echoes opus, the
extra surfaces and their billing are not worth it and this stays at two surfaces.

<!-- design-reviewed: PASS -->
