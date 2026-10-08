# ADR 0053 — Withdraw the droid CLI

## Status

**Accepted (2026-10-06).** Amends [ADR 0006](./0006-pr-mode-codex-deep-review.md)
(PR mode no longer needs to disable a droid escalation — none exists) and
[ADR 0034](./0034-pi-in-tree-read-lane.md) (pi's exemption from the runtime droid
escalation is moot). Plan: `docs/plans/2026-10-06-withdraw-droid.md`.

## Context

droid (Factory) served four roles: a dispatch lane (`--cli droid`), the second entry
of every shipped route, a runtime escalation target when codex/agy failed (litmus
commit mode, council voices), and a one-voice rescue for a failed blueprint reviewer.
It is uninstalled on both operator hosts (verified 2026-10-06), so every one of those
paths was already dead in practice: routes fell through, escalations found no binary,
and a failed blueprint reviewer was already recorded `runtime-failed` with PASS
withheld (#355). References spanned 45 files outside ADRs and plans, including two
whole test files and a cross-provider containment rule (grok/pi/prose must never
escalate to droid) that existed only because the escalation did.

## Decision

Remove droid entirely. A stale `droid` value is a removed CLI, handled exactly like
`opencode` (ADR 0051): warned and skipped in routes and defaults, `unsupported:droid`
from `BUSDRIVER_REVIEW_CLI`. A route or defaults chain made up only of removed CLIs
does not degrade to the next resolver: it fails closed with `unsupported:<cli>`. A failed Codex falls straight to `BUILTIN_FALLBACK`
(exit 3) or exit 124; a failed council voice drops and is recorded `(unavailable)`;
a failed blueprint reviewer stays `runtime-failed`.

`derive_coverage` keeps reading `.metadata.runtime_escalated_from`, now as a
legacy-artifact guard: a slot carrying it is `runtime-failed`, never coverage.
Nothing current writes the field, so dropping the read would only loosen fail-closed.

## Alternatives

- **Keep droid code dormant.** Rejected: it cannot run on either host, and its
  containment rules (which CLIs may escalate where) are review surface with no
  function.
- **Replace droid with another fallback CLI.** Rejected: no request for one, and
  every fallback re-sends a prompt to a different third party than the operator
  chose — the exact hazard the escalation exemptions were written to contain.

## Consequences

- One fewer external provider in every data-boundary argument.
- After primary retries are exhausted, no other provider rescues the slot: blueprint
  withholds PASS until a re-run; council proceeds with fewer voices. This was already
  the behaviour on both hosts.
- With no fallback CLI, a missing grok resolves blueprint reviewer_3 to `none`, which
  coverage provenance labels `explicit-none`. Here that means grok is not installed
  (or failed its preflight), not an operator opt-out.
- The `codex-droid-fallback` telemetry event and the `droid-fallback` dispatch status
  are retired; historical log entries keep them.

## Revisit trigger

A fallback reviewer becomes desirable again (e.g. sustained Codex outages blocking
commits). Add it as a new, explicitly reviewed route entry — not by restoring
escalation.
