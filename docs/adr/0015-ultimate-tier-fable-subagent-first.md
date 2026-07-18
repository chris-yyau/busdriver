# ADR 0015: Ultimate Tier — Fable via In-Harness Subagent (Gateway Demoted to Fallback)

> **Amended by [ADR 0019](./0019-ultimate-tier-drop-gateway-rung.md) (2026-07-18, gateway transport deleted).** This ADR demoted the gateway from primary to *fallback*; ADR 0019 removes the fallback entirely. The arbiter chain is now **fable subagent → opus (degraded)** and the Mythos Witness is subagent-only. The "Alternatives considered → Drop the gateway entirely (Rejected)" entry below is thereby **superseded**: with fable reliably in-plan and in-account, the never-exercised fallback was net cost. Body below left as historical record.

## Status

Accepted (2026-07-10). Amends [ADR 0011](./0011-ultimate-tier-fable-surfaces.md)
(both ultimate surfaces flip from gateway-primary to subagent-first) and updates the
premise of [ADR 0008](./0008-opus-default-arbiter-drop-fable.md) (fable is again
reachable in-harness, now as a selectable Agent-tool model rather than a subscription plan).
The `ultra*` / `ultimate*` naming convention from ADR 0011 is UNCHANGED.

## Date

2026-07-10

## Context

ADR 0011 routed **Claude Fable** (`claude-fable-5`) through the zenmux gateway because its
founding premise — stated verbatim in `skills/blueprint-review/SKILL.md` — was that
"Agent-tool subagents always inherit the parent session's auth, endpoint, and credentials —
there is **no supported way** to point a single Agent-tool subagent at a different endpoint,"
and `fable` had been dropped from the subscription plan (ADR 0008). The gateway `claude -p`
subprocess was the only way to reach fable.

That premise is now **stale**. This harness's Agent tool exposes `model="fable"` directly; a
probe subagent dispatched with `model="fable"` self-reports `claude-fable-5` (verified this
session). So fable is reachable **in-account**, with no gateway, no metered billing, and no
external transmission.

The trigger was a concrete failure: in an SDK/child session (`CLAUDE_CODE_ENTRYPOINT=sdk-ts`,
`CLAUDE_CODE_CHILD_SESSION=1`) `CLAUDE_PLUGIN_ROOT` is empty in the Bash tool env, so the
council's `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ultimate-dispatch.sh"` collapsed to `/scripts/…`
and every voice + witness failed to launch. Investigating the fable failure surfaced the deeper
point: the gateway is no longer the only — or the best — way to reach fable.

The gateway also carries real costs the subagent avoids: metered API billing, an external
data-boundary crossing, gateway-credential configuration, and (for the arbiter) a `--bare`
`--tools "Read,Edit"` posture with **no** free-form codebase search (`Grep`/`Glob` unselectable
under `--bare`).

## Decision

Both ultimate surfaces flip to **subagent-first, gateway-fallback**. The hardened gateway
scripts (`scripts/ultimate-dispatch.sh`, `skills/blueprint-review/scripts/dispatch-gateway-arbiter.sh`)
are **unchanged** and remain the fallback; their credential-containment / provider scrub is
untouched. All opt-in gates are **unchanged**: USER-config-only (`~/.claude/busdriver.json`
`.ultimate.surfaces.*`), a repo config can never opt in, and `BUSDRIVER_ULTIMATE=0` is a global
force-OFF that outranks the per-run trigger.

1. **Council Mythos Witness** — primary is a fresh `Agent(model="fable")` dispatched in the same
   Step 4 message as the other voices (in-account, no external transmission). Fall back to the
   gateway (`ultimate-dispatch.sh mythos-witness`) only if the subagent errors, reports
   `model="fable"` unavailable, or returns empty.

2. **Ultimate arbiter** (blueprint-review) — primary is the SAME fresh arbiter subagent as the
   default `opus` dispatch but with `model: fable` (identical `general-purpose` posture, fixed
   prompt template, and `claude.json` verdict contract). Chain: **fable subagent → gateway fable
   → opus (degraded)**. `model_pin_status=ultimate_arbiter_fable` covers both fable transports;
   `ultimate_arbiter_unavailable` still marks the opus degrade.

## Consequences

**Positive.**
- Works in SDK/child and gateway-less sessions — the failure that triggered this ADR.
- Cheaper (no metered gateway call on the common path) and simpler (no gateway creds needed).
- Better data boundary: the primary stays in-account; the zenmux external-transmission warning
  now applies only to the rare gateway fallback.
- The arbiter's fable subagent gets codebase tools (Read/Grep/Glob) the gateway `--bare` arbiter
  lacked — a review-quality gain, matching the default opus arbiter's posture.

**Negative / accepted.**
- The fable subagent carries the `general-purpose` tool posture. Accepted because: (a) for the
  arbiter, the **default** path (opus subagent) already has exactly this posture, so fable is a
  drop-in with no new boundary; (b) the council witness mirrors the existing Fresh-Claude Skeptic
  subagent; (c) for solo use the hostile-arbiter / hostile-content threat model is already
  discounted (`.claude/CLAUDE.md`). The gateway fallbacks keep their existing isolation when they
  fire, which **differs by surface**: the Mythos text witness runs `--tools ""` (no tools at all),
  while the arbiter gateway runs `--tools "Read,Edit"` (output-scoped `Edit`, sensitive-path `Read`
  denies, but ordinary workspace reads allowed) — matching, not exceeding, the tool-bearing
  subagent it backs (consistent with the Context note above). Neither is a blanket `--tools ""`.
- Subagent overhead is real (a probe cost ~42k tokens) but far below a gateway round-trip's
  latency and billing.
- The gateway remains as a fallback for harnesses whose Agent tool cannot select `model="fable"`.

## Alternatives considered

- **Keep gateway-primary (ADR 0011 as-is).** Rejected: the founding premise is stale, it fails
  in SDK/child sessions, and it is metered + external for a capability now available in-account.
- **Drop the gateway entirely.** Rejected: still needed as a fallback where the Agent tool cannot
  select `model="fable"` (older/other harnesses, CI).
- **Constrain the fable subagent to a no-tools posture (mirror `--tools ""`).** Rejected: the
  Agent tool has no per-call tool-restriction and no zero-tool subagent type; and for the arbiter
  the tool-bearing posture is the *existing* accepted default (opus subagent) and a quality gain.

## Revisit trigger

Revisit if the harness stops exposing `model="fable"` (gateway returns to primary), or if a real
second user / hostile-content threat emerges that makes the arbiter's tool-bearing subagent
posture unacceptable (reintroduce the gateway's `--tools ""` isolation as the arbiter primary).
