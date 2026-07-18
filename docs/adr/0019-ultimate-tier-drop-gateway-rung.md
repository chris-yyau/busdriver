# ADR 0019: Ultimate Tier — Drop the zenmux Gateway Rung (Fable via Subagent Only)

## Status

Accepted (2026-07-18). Amends [ADR 0011](./0011-ultimate-tier-fable-surfaces.md),
[ADR 0015](./0015-ultimate-tier-fable-subagent-first.md), and
[ADR 0008](./0008-opus-default-arbiter-drop-fable.md): both ultimate surfaces lose the zenmux
gateway rung entirely — fable is reached **only** via the in-harness Agent subagent.

- **ADR 0011** — the `ultra*` (ChatGPT Pro) vs `ultimate*` (Claude Fable) **naming split** is
  unchanged; what changes is 0011's *definition* of `ultimate*`, from "Claude Fable **via the
  zenmux gateway**" to "Claude Fable **via the in-harness Agent subagent**". The prefix and its
  model family are untouched; only the transport is.
- **ADR 0015** — flipped gateway from primary to *fallback*; this ADR removes the fallback too.
- **ADR 0008** — its **default-arbiter-is-opus** decision **stands** (unchanged). What this ADR
  reverses is 0008's separate "**Retain the gateway-fable path** … keep `dispatch-gateway-arbiter.sh`
  verbatim" decision: that path is now deleted (its founding premise — fable unreachable in-harness —
  is stale per ADR 0015). So `opus` remains the default arbiter; only the gateway *escalation
  transport* is gone.

## Date

2026-07-18

## Context

ADR 0011 introduced the zenmux gateway as the ONLY way to reach `claude-fable-5` (fable had
left the subscription plan). ADR 0015 then demoted the gateway to a **fallback** once the
harness's Agent tool could select `model="fable"` in-account, keeping the gateway only "for
harnesses whose Agent tool cannot select `model="fable"` (older/other harnesses, CI)."

That fallback is now dead weight. Fable is included in the operator's plan and is reliably
reachable in-account via the Agent subagent (ADR 0015 verified `model="fable"` self-reports
`claude-fable-5`). The operator's harness always takes the subagent primary; the gateway rung
has not been — and will not be — exercised on the common path. Meanwhile it costs:

- ~44KB of gateway/credential-scrub shell (`scripts/ultimate-dispatch.sh` +
  `skills/blueprint-review/scripts/dispatch-gateway-arbiter.sh`) plus their tests,
- an external data-boundary crossing and metered API billing on the one path that used it,
- gateway-credential configuration (`BLUEPRINT_ARBITER_GATEWAY_*`),
- a standing security surface (a `claude -p` subprocess fed operator credentials) maintained
  for a path that never runs.

Deleting a never-taken, credential-bearing fallback removes maintenance and attack surface for
zero loss of capability on this harness. This is the operator's decision (solo repo).

## Decision

Remove the gateway rung from **both** ultimate surfaces. Fable is reached via the in-harness
Agent subagent only.

1. **Ultimate arbiter** (blueprint-review). Chain collapses from
   `fable subagent → gateway fable → opus (degraded)` to **`fable subagent → opus (degraded)`**.
   `model_pin_status=ultimate_arbiter_fable` now covers only the subagent transport;
   `ultimate_arbiter_unavailable` still marks the opus degrade (with the loud caller-side
   `WARNING: ULTIMATE-ARBITER UNAVAILABLE — ran opus`). If the fable subagent fails, fall
   straight through to the `opus` Agent dispatch — no gateway step in between.

2. **Council Mythos Witness**. Primary is unchanged: a fresh `Agent(model="fable")` dispatch (an
   Agent tool call returning **text**, not a Bash pipeline). The entire gateway fallback **Bash block**
   in `skills/council/SKILL.md` Step 4.6 (the `PLUGIN_ROOT` resolution, the `ultimate-dispatch.sh
   mythos-witness` call, and its `_mythos_rc`-graded `MYTHOS_FAILED` arms) is **deleted** — that block
   is today the only *structured* `MYTHOS_FAILED` emitter, but it only ever ran on the gateway path.
   The never-silent contract is upheld by the **Step 5 render logic**, which is already where the
   primary path is handled (the executor reads the subagent's returned text): the render bullets are
   rewritten so the executor, seeing the subagent **error or return empty**, renders the loud
   `MYTHOS_FAILED [subagent-failed | empty verdict]` banner directly — no gateway, no bash rc pipeline.
   The "Subagent failed → gateway fallback ran" render bullet is removed. Preserved: an attempted
   witness that produces no verdict is **never silently omitted** (a loud banner instead); the
   un-attempted case (`MYTHOS_ATTEMPT=0`, operator not opted in) still omits the section. The witness
   is auxiliary ("never a vote"), so deleting the gateway needs no replacement transport — the render
   banner covers failure and the council converges on its five voices. Note: deleting
   `ultimate-dispatch.sh` also removes its helper-side defense-in-depth re-check of the council
   surface opt-in, so the witness (like the arbiter — §5) is authorized by the SKILL.md gate
   (`MYTHOS_ATTEMPT`, from `ultimate_surface_enabled council` or the trigger force) alone. Accepted:
   the witness is advisory and the prose gate is the same one already governing the subagent primary.
   `ULTIMATE_COUNCIL_FORCE` — which existed only to authorize the deleted gateway helper — is removed
   entirely. **`_forced` stays** in the Step 4.6 gate block: it is the trigger flag that sets
   `MYTHOS_ATTEMPT=1` for a trigger-only ("ultimate council") run with no USER config, so deleting it
   would break exactly the path that needs no config. What goes is the *gateway block's duplicate*
   `_forced` declaration (that block re-declared it independently because shell state does not carry
   across Bash calls), so `_forced=0` now appears exactly once; `tests/test-ultimate-tier.sh`'s
   dual-block assertion is updated to that single-block contract.

3. **Delete** the now-unreachable gateway code and its tests:
   `scripts/ultimate-dispatch.sh`, `skills/blueprint-review/scripts/dispatch-gateway-arbiter.sh`,
   `tests/test-gateway-arbiter-dispatch.sh`, `tests/test-gateway-arbiter-claude-json-residual.sh`.
   `tests/test-ultimate-tier.sh` is **structurally** gateway-coupled (its `LIVE_FILES` list, the
   section-(b) gateway-helper cases, and dual force paths) — it is restructured to the
   subagent-only contract, not surgically trimmed. `tests/test-cli-retry.sh` has **no** gateway
   cases and is out of scope. The consuming references updated in the same change (or CI /
   instructions break):
   - **CI shellcheck** — `.github/workflows/tests.yml` explicitly names three of the deleted files
     in its shellcheck list (`scripts/ultimate-dispatch.sh`,
     `skills/blueprint-review/scripts/dispatch-gateway-arbiter.sh`,
     `tests/test-gateway-arbiter-dispatch.sh`); those lines are removed, and the kept ultimate
     files in the same list (`scripts/lib/ultimate-config.sh`, `tests/test-ultimate-config.sh`,
     `tests/test-ultimate-tier.sh`, `tests/test-blueprint-arbiter-default-pin.sh`) stay.
   - **Gate-test runner + inventory** — `scripts/ci/run-shell-tests.sh` (drops the
     `test-gateway-arbiter-claude-json-residual` self-skip entry) and `docs/ci/shell-test-inventory.md`.
   - **Skill/command instructions** — `skills/blueprint-review/SKILL.md`: the gateway rung is woven
     through the Arbiter Dispatch Protocol (steps 1–4) **and** its own "Ultimate-Arbiter Escalation
     (headless `claude -p`)" section — both are removed so the chain reads `fable subagent → opus
     (degraded)` with no dangling fallthrough. The gateway-coupled sub-parts to reconcile to the
     subagent-only path: the pin-mismatch → gateway fallthrough branch (step 3, rewritten so a fable
     pin mismatch falls straight to `opus`), the config-table arbiter row, and the `--bare` tooling
     note. **Keep** the `fable ≡ claude-fable-5` model-identity equivalence — it is required by the
     surviving subagent path (the fable subagent self-reports `claude-fable-5`); drop **only** the
     gateway-namespaced `anthropic/claude-fable-5` form. Add a v3.8 Version History entry.
     `skills/council/SKILL.md` (per §2, including the Step 6 report-template block that also describes
     the gateway). `commands/ultimate-council.md` (scrub gateway wording; reconcile its dual-block
     force contract — see §2/§4).
   - **Repo docs** — `.claude/CLAUDE.md`: the SETTLED chain note is updated to
     `fable subagent → opus (degraded)`, **and** the "gateway/provider-scrub hardening is considered
     done — treat that surface as frozen" bullet is rewritten (that 44KB surface is being deleted, not
     frozen). `scripts/lib/ultimate-config.sh` **and** `tests/test-ultimate-config.sh` both carry the
     same stale "transmits to an external gateway" comment wording — both are corrected (per §5).
     Historical `docs/plans/2026-07-*.md` are dated records, left unchanged (a prior plan reflecting the
     then-current gateway design is not a live instruction).
   - **Amendment banners** — per the ADR 0008 convention, add a Status-line banner to
     `docs/adr/0008-*.md`, `docs/adr/0011-*.md`, and `docs/adr/0015-*.md` noting they are amended by
     this ADR (gateway transport removed; 0008's opus-default decision preserved). While there, also
     correct 0008's own line-3 banner text, which still *defines* the ultimate tier as "Claude Fable
     via the zenmux gateway" — else 0008 is left internally contradictory.
   - **Retired enforcement (#265 — already shipped and closed)** — the code-level opt-in guard is not
     pending work: it landed in `fb86e2f0` (*feat(blueprint-review): enforce ultra-arbiter opt-in +
     CI/test hardening*, **#265**, now CLOSED) as the `ultimate_surface_enabled arbiter || skip` check
     at the top of `dispatch-gateway-arbiter.sh`. Deleting that helper therefore **retires a shipped
     guard**, leaving the surviving fable-subagent path gated in prose only (§5) — an accepted
     consequence of removing the transport it protected, not a regression against an open issue.
     #265 is closed and stays closed; drop the now-stale "deferred / tracked in #265" notes in
     `docs/adr/0008-*.md` and `skills/blueprint-review/SKILL.md`, which still describe it as pending.

4. **Replacement test coverage.** The deleted tests only exercised the *gateway transport*, which
   no longer exists — so there is nothing to re-cover, not a coverage gap. The surviving fable path
   stays covered by the existing non-gateway tests: `tests/test-blueprint-arbiter-default-pin.sh`
   (arbiter pin/degrade), the restructured `tests/test-ultimate-tier.sh`, and
   `tests/test-ultimate-config.sh` (the opt-in gate). Add a case **in `tests/test-ultimate-tier.sh`**
   asserting the ultimate-arbiter chain is exactly `fable subagent → opus` (no gateway rung) so a
   future gateway re-introduction is a deliberate, test-visible change.

5. **Keep** the opt-in gate (`scripts/lib/ultimate-config.sh`, `ultimate_surface_enabled`)
   functionally unchanged — only its stale gateway comments are corrected (the header and the
   `ultimate_surface_enabled` comment still describe "transmits content to an external gateway",
   which no longer holds for the in-account subagent; `tests/test-ultimate-config.sh` carries the
   same stale wording and is corrected alongside it). Precisely, the surface is enabled by the
   per-surface USER-config flag
   `.ultimate.surfaces.<arbiter|council>` **or** the global `BUSDRIVER_ULTIMATE=1` operator force
   (and `BUSDRIVER_ULTIMATE=0` force-OFF outranks config) — it is not USER-config-*only*, and this
   ADR does not change that resolution. Its rationale weakens now that the primary stays in-account,
   but it remains a deliberate "use the heavier fable lens only when asked" toggle; loosening consent
   is out of scope for a cleanup. Residual: operators may still have unused `BLUEPRINT_ARBITER_GATEWAY_*`
   env vars in their own settings — now dead, safe to remove, but this repo cannot and does not touch them.

6. **Default arbiter stays `opus`** (ADR 0008 unchanged). Fable remains the divergent/witness
   lens (Mythos Witness) and the opt-in ultimate-arbiter escalation — it does not become the
   everyday rigorous-validation arbiter.

**Implementation altitude & verification.** This ADR fixes the *decision* and a complete inventory of
the *consuming surfaces* (§3). It deliberately does **not** transcribe the line-level edit contracts —
the exact rewrite of the arbiter pin-mismatch/failure predicate in `SKILL.md` steps 3–4, the precise
`test-ultimate-tier.sh` restructure, and the trigger-force control flow after `ULTIMATE_COUNCIL_FORCE`
is removed (`_forced` itself stays — see §2) —
because those are executed and verified in the **implementation PR**, where the enforcing gate is the
litmus review plus the shell test suite (`tests/test-ultimate-*.sh`, `test-blueprint-arbiter-default-pin.sh`,
run via `scripts/ci/run-shell-tests.sh`) running green against the actual code. The never-silent Mythos
contract and the `fable subagent → opus (degraded)` arbiter chain are the two behaviors those tests must
assert. Enumerating patch-level contracts in the ADR itself would rot against the code and is the wrong
altitude for this record.

## Consequences

**Positive.**
- Simpler: one fable transport, no gateway creds. The **fable** external data boundary is removed —
  the fable subagent is in-account, and the only crossing that used it (the gateway) is deleted.
  (Scope note: this removes the *fable* external path only. An **ultimate-council** run
  still includes the UltraOracle — ChatGPT Pro, an `ultra*` surface — which transmits externally;
  that boundary is unaffected by and out of scope for this ADR.)
- Less code and less security surface: ~44KB of credential-handling shell + two test files gone.
- The ultimate arbiter's fable→fallback chain is now a single rung (`opus`), not a two-step chain.

**Negative / accepted.**
- No gateway escape for a harness whose Agent tool cannot select `model="fable"` (older/other
  harnesses, CI). Accepted: the operator's harness selects fable in-account; the revisit trigger
  below covers regression.
- The Mythos Witness has no transport fallback. Accepted: it is auxiliary and never a vote; a failed
  subagent renders the loud `MYTHOS_FAILED` banner (its existing contract), so its absence is never
  silent, and the council still converges on its five voices.
- The Mythos Witness's primary fable subagent has no per-run model-identity self-report check (unlike
  the arbiter's `executed_model` comparison). Accepted as-is: the witness is advisory and excluded
  from the vote, so a silently-substituted model is far lower-stakes than for the arbiter; adding
  witness pin-parity is a possible follow-up, not a blocker for this cleanup.

## Alternatives considered

- **Keep the gateway as a dormant fallback (ADR 0015 as-is).** Rejected: it is never exercised
  in-account, yet carries live credential-handling code and its own attack/maintenance surface.
  A fallback that never fires is cost without benefit.
- **Make fable the default arbiter (drop opus entirely).** Rejected: opus is the deliberate
  rigorous-validation default (ADR 0008); fable is the divergent/witness lens. Swapping it in as
  the everyday convergent arbiter is a quality change, not a cleanup, and was not the decision.
- **Drop the opus degraded fallback too (fable subagent with no fallback).** Rejected: the review
  gate is fail-CLOSED; a last-resort `opus` degrade (one dispatch) keeps arbitration available if
  the fable subagent is momentarily unavailable, without reintroducing any external path.

## Revisit trigger

Revisit if the harness stops exposing `model="fable"` to the Agent tool (fable becomes
unreachable in-account) — at which point a fable transport (gateway or successor) would need to
be reintroduced, or the ultimate arbiter would collapse to `opus`.
