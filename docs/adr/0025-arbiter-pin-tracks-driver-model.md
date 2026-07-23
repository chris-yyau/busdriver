# ADR 0025 — Blueprint-review arbiter pin tracks the calling session's model (opus floor)

## Status

**Accepted (2026-07-23).** Amends [ADR 0008](./0008-opus-default-arbiter-drop-fable.md)
(opus-*default* arbiter) and builds on [ADR 0019](./0019-ultimate-tier-drop-gateway-rung.md)
(gateway transport deleted; fable is an in-account Agent subagent). The
fresh-subagent / author≠judge / context-firewall decisions of
[ADR 0003](./0003-fresh-subagent-arbiter-for-blueprint-review.md) and the
`ultimate` opt-in surface of [ADR 0011](./0011-ultimate-tier-fable-surfaces.md) /
[ADR 0015](./0015-ultimate-tier-fable-subagent-first.md) are unchanged. Prose-only
change — the surviving fable path was already prose-gated (ADR 0019).

## Date

2026-07-23

## Context

The blueprint-review arbiter is a fresh Claude subagent that validates the
Agy/Codex/Grok reviewers' findings against the codebase and renders the sole
convergence verdict. Since ADR 0008 its model was a flat pin: **`opus` for
everyone**, with `fable` reachable only through the USER-level "ultimate arbiter"
opt-in (`.ultimate.surfaces.arbiter` / `BUSDRIVER_ULTIMATE=1` / the "ultimate
arbiter" trigger phrase).

Two things that justified gating `fable` behind an opt-in no longer hold:

1. **Cost / data boundary is gone.** ADR 0008's Decision 3 gated fable because
   reaching it meant "routing to a metered third-party gateway" — a deliberate,
   operator-controlled escalation with an external data boundary. **ADR 0019
   deleted the zenmux gateway.** Fable is now an in-harness Agent-tool subagent
   (`claude-fable-5`) with no external transmission and no metered billing. The
   cost/data-boundary rationale for the opt-in is vestigial.

2. **Reproducibility-across-operators is moot here.** The repo is single-operator
   (see root `CLAUDE.md`). "Two reviewers of the same PR would get different
   arbiters" is not a live concern with one operator.

What remains is only "is fable a good arbiter for codebase validation" — and fable
is already the repo's designated `ultimate`/Mythos escalation tier, so a `fable`
arbiter when the operator is *already* driving `fable` is not a downgrade.

Historical note: an `inherit`-the-driver-model rung existed in ADR 0003's fallback
chain (`fable → gateway fable → opus → inherit`) and was **deliberately deleted**
by ADR 0008 as "buys no resilience." This ADR does **not** revive that rung — it
is a new, bounded policy (`{opus, fable}` only, clamped upward), not a same-session
resilience fallback.

## Decision

**The arbiter pin tracks the calling session's model, clamped to an `opus` floor:**

1. Calling session runs **`opus`** — or any model that is neither `fable` nor
   stronger — → pin **`opus`**. `model_pin_status=pinned`. Unchanged default.
   A non-fable, non-opus driver (sonnet/haiku) still pins `opus`: the arbiter
   never inherits *down* to a weaker model.
2. Calling session runs **`fable`** → pin **`fable`** automatically, via the
   existing fable-subagent → opus-degraded chain. New dispatch-time status
   `model_pin_status=driver_fable`.
3. **Ultimate-arbiter opt-in is retained, re-scoped to "force fable when driving
   `opus`."** The USER-level opt-in (and the "ultimate arbiter" trigger phrase)
   force-pin `fable` when the driver is not already `fable`, recording
   `model_pin_status=ultimate_arbiter_fable`. When the driver IS `fable`, the
   automatic driver-fable trigger (step 2) already pins `fable`, and the status
   stays `model_pin_status=driver_fable` — the opt-in has nothing left to force.
4. **Degrade-to-opus is fail-closed and loud on both fable triggers.** If the
   fable subagent fails, fall back to `opus`, record the matching degraded status
   (`driver_fable_unavailable` or `ultimate_arbiter_unavailable`, + `run_degraded=true`),
   and emit `WARNING: FABLE ARBITER UNAVAILABLE — ran opus` — never silently. The
   step-3 self-report post-check and step-4 failure handling treat the `driver_*`
   pair identically to their `ultimate_arbiter_*` counterparts.

The pin is caller-chosen; the calling session knows its own model. Nothing about
driver identity flows *into* the arbiter beyond the pin — the fixed prompt template
and context firewall are unchanged, and the arbiter's model self-report is still
compared against the expected pin, so author≠judge and pin-observability both hold.

## Alternatives considered

- **Keep the flat `opus` default, fable opt-in only (status quo).** Rejected: the
  opt-in's two justifications (cost/data-boundary, cross-operator reproducibility)
  are both dead post-ADR-0019 for a solo repo, so it now costs the operator an
  explicit escalation for no boundary benefit when they are already on `fable`.
- **Full inherit — arbiter = driver model, unclamped.** Rejected: a `sonnet`/`haiku`
  driver would inherit a weaker arbiter, degrading the review gate exactly when the
  driver is already a cheaper model. The `opus` floor is the point.
- **Add a distinct new-value pair vs. reuse `ultimate_arbiter_*`.** Chose distinct
  (`driver_fable` / `driver_fable_unavailable`) so the audit trail records *why*
  a non-default arbiter ran (auto-matched driver vs. conscious operator escalation).
  `model_pin_status` has no code consumers today (caller-side observability only),
  so the extra values cost only prose.

## Consequences

- A `fable`-driven session gets a `fable` arbiter with no opt-in ceremony; an
  `opus`-driven session is unchanged (`opus` arbiter).
- The `ultimate arbiter` opt-in / trigger phrase is now only meaningful when driving
  `opus` (a `fable` driver already pins `fable`).
- Two new `model_pin_status` values (`driver_fable`, `driver_fable_unavailable`);
  the fallback WARNING banner is generalized from `ULTIMATE-ARBITER` to
  `FABLE ARBITER`. No code consumers of the field, so no downstream migration.
- Council's Mythos Witness is untouched — it is a fixed-fable expert witness, not
  driver-tracking.

## Revisit trigger

- Fable leaves the operator's in-account plan, or regains a metered/external transport
  (would restore the cost/data-boundary reason to gate it behind an opt-in).
- The repo gains a second approval-capable operator (reproducibility-across-operators
  becomes live; reconsider whether a launch-model-dependent arbiter is acceptable).
- A `model_pin_status` code consumer appears (the two new values would then need a
  migration story rather than tolerated-unknown handling).
