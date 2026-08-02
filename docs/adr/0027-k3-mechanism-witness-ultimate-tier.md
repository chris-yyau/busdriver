# ADR 0027 — kimi-k3 auditor becomes the "Mechanism Witness"; council-side moves to the ultimate tier

## Status

**Accepted (2026-07-25).** Refines the advisory-Auditor decisions of #435 (the k3
claim-vs-mechanism voice, added 2026-07-20) and #453 (its own reap budget, see
[the grace-budget test](../../tests/test-auditor-grace-budget.sh)). Builds on the
`ultimate` tier of [ADR 0011](./0011-ultimate-tier-fable-surfaces.md) /
[ADR 0015](./0015-ultimate-tier-fable-subagent-first.md) /
[ADR 0019](./0019-ultimate-tier-drop-gateway-rung.md) — the k3 council voice now
shares that tier's `MYTHOS_ATTEMPT` gate with the fable Mythos Witness. The
five-voice council composition (ADRs 0006/0011/0012/0013/0019) is **unchanged** —
k3 was never a voice and still is not.

## Date

2026-07-25

## Context

The `opencode-go/kimi-k3` reviewer was added (#435) as an always-on **advisory
Auditor** with a single *claim-vs-mechanism* lens — "does the artifact actually do
what it says it does." It ran, as a background dispatch, in **every** council and
**every** blueprint-review, rendered as its own section, never a voice, never a
vote.

Three problems surfaced in operation:

1. **It silently vanished.** kimi-k3 is a slow reasoning model. The council budget
   was **120s** (clamped max 600s); on a real, context-heavy council prompt k3
   routinely exceeded that. With **no droid fallback** (deliberate — a droid
   Auditor is false corroboration), a timeout meant the witness simply disappeared
   from the report with no trace. The operator observed the council/blueprint
   *saying* "k3 dispatched" while the finished report never contained a k3 section
   — the dispatch was real, the timeout silent. A smoke test of the dispatch path
   confirmed k3 works and answers a trivial prompt in ~29s; the disappearances
   were budget exhaustion on heavy prompts, not a broken wiring.

2. **A long budget in every council is the wrong tradeoff.** Fixing (1) by simply
   raising the budget would make *every plain council* potentially wait minutes on
   a slow auxiliary — regressing the fast path that is the whole point of a plain
   council (seconds, five voices).

3. **Name collision.** Claude Code shipped a first-party "Advisor". "advisory
   Auditor" now reads ambiguously against a product surface with the same word.

## Decision

Three coupled changes.

1. **Rename the surface to the "Mechanism Witness".** The k3 voice is reframed as
   an **Expert Witness** — its own rendered section, never a vote — exactly like
   the UltraOracle and the Mythos Witness it now sits beside. The word "advisory"
   is scrubbed from everything that describes k3. **Internal identifiers are
   unchanged** — the config route keys `council.auditor` / `blueprint-review.auditor`,
   the `auditor.json` artifact, the `AUDITOR_*` / `_AUD_*` variables, and the
   opencode `busdriver-review` agent all keep the `auditor` name. Renaming them
   would break the operator's live `.claude/busdriver.json` routes and churn the
   blueprint arbiter-prompt wiring for zero user-visible gain; they never collide
   with "Advisor" (not user-facing).

2. **Council: move k3 from always-on → ultimate-council ONLY.** The Mechanism
   Witness is now gated on the **same `MYTHOS_ATTEMPT` signal** as the fable Mythos
   Witness (Step 4.6/4.7 of `council/SKILL.md`). A plain or ultra-council does NOT
   dispatch it; an ultimate-council runs all three witnesses (UltraOracle + Mythos
   + Mechanism). Authorization is a **literal `MECHANISM_WITNESS=0`** in the Step 4b
   preamble (Claude flips it to `1` only for an authorized ultimate-council), which
   **shadows any repo-injected ambient `MECHANISM_WITNESS`** — a committed
   `.claude/settings.json` `env` block can set env vars (#325 / ADR 0016 class), so the
   guard must not trust an inherited value or a plain council could be forced to
   transmit its prompt to kimi-k3. Same injection-proofing as the Step 4.6 `_forced=0`
   literal; fail-safe default `0`.

3. **Budget raised, per-surface — both hard-clamped (the env vars are repo-injectable,
   #325).** `COUNCIL_AUDITOR_TIMEOUT` default 120→**900**, clamp→**900**. This is
   TRUE UltraOracle-parity: the oracle's own cap `ultra_oracle_timeout_cap`
   **defaults to 900s** (user-configurable up to a 3600s ceiling), so k3 at 900s
   rides that same window and fits the block's `≥ oracle budget + 90s` Bash-tool
   timeout — a 3600s k3 against a default-900s oracle would extend an ultimate-council
   ~45 min past that timeout. `BLUEPRINT_AUDITOR_TIMEOUT` default 300→**600**,
   clamp→**600**: in blueprint the auditor reap sits ON THE CRITICAL PATH before the
   arbiter (Phase 3), so a longer budget could starve arbitration under the Bash-tool
   cap the loop runs beneath. **⚠ SUPERSEDED IN PART by [ADR 0030](./0030-blueprint-blocking-window.md)
   (2026-07-27): the "starve it under the Bash-tool cap" half of this rationale is
   retired — that cap is a foreground-wait boundary, not a kill boundary (an
   over-long call is backgrounded and runs to completion), and the binding term on
   the blueprint critical path was measured to be the UltraOracle poll, not the k3
   reap. The 600s clamp itself STANDS, unchanged, on the repo-injection ground
   stated in the next sentence — which is independent and sufficient.** Both clamps
   are HARD (not the oracle's 3600s ceiling)
   because a fork's committed `settings.json` `env` block can inject these vars — an
   unbounded ceiling would let a hostile branch delay arbitration by up to an hour.
   Blueprint **keeps** k3 always-on (it is already a multi-minute review) — only its
   budget changes.

### Council budget vs. the Step 4 Bash-tool timeout

In an ultimate-council the Mechanism Witness is backgrounded in the SAME Step 4
Bash block as the UltraOracle; its bounded reap can block the closing `wait` for up
to `_AUD_TO + 10` ≤ **910s**. Two facts keep this from surprising the operator:

- **k3's clamp is pinned to 900s — the oracle's *default* cap** (`ultra_oracle_timeout_cap`),
  NOT the oracle's 3600s ceiling. When both witnesses run at defaults, the block's
  wall time is `max(oracle 900, k3 910)` ≈ the oracle's own `#477` requirement
  (`oracle budget + 90`), so k3 adds no *extra* bump over what an ultra-council
  already needs. A 3600s k3 against a default-900s oracle would instead run ~45 min
  past that timeout — which is why the clamp is hard 900.
- **k3 is NOT always hidden behind an oracle window.** `MYTHOS_ATTEMPT=1` can come
  from `ultimate.surfaces.council` with the oracle disabled, or the oracle cap can be
  set below 900. So the Step 4 Bash-tool `timeout` must cover `max(oracle budget + 90,
  910)` whenever `MECHANISM_WITNESS=1` — documented in the Step 4.7 timeout note, not
  assumed. The bound is finite and small (≤910s) precisely because of the hard clamp.

## Alternatives considered

- **Just raise the budget, keep k3 always-on (both surfaces).** Rejected for the
  council: regresses the plain-council fast path (problem 2). Kept for blueprint,
  which has no fast path to protect.
- **Remove k3 from blueprint too (strict council-ultimate-only).** Rejected by the
  operator — blueprint is already slow and the claim-vs-mechanism lens is useful
  there on every design doc; there is no tier to gate it behind.
- **Rename internal identifiers as well (`council.mechanism`, `mechanism.json`).**
  Rejected — breaks the live config route and the arbiter-prompt/resume wiring for
  no user-visible benefit; `auditor` does not collide with "Advisor".
- **Keep the name "Auditor", drop only "advisory".** Viable, but "Mechanism
  Witness" names the actual lens (claim-vs-mechanism) and slots cleanly beside the
  Mythos Witness in the ultimate tier. Operator chose it.

## Consequences

- A **plain or ultra-council no longer runs k3** — one fewer background dispatch,
  strictly faster, and no more silent-timeout confusion. The claim-vs-mechanism
  lens is now an ultimate-council feature.
- **Ultimate-council runs three witnesses**, all rendered separately, none in the
  vote tally. Its latency profile is unchanged (bounded by the oracle window).
- **Blueprint-review is behaviorally the same** except k3 now gets a real budget
  and will actually produce `auditor.json` on heavy prompts instead of silently
  timing out. It also now emits a **one-line Mechanism Witness status** (ran +
  finding count / absent / failed) beside the reviewer statuses — previously k3's
  output only ever reached the arbiter's context with no report line, so a run was
  invisible; this makes "did k3 fire?" answerable at a glance without gating.
- Internal route keys / artifacts / env vars are stable — no operator config
  migration, and `tests/test-opencode-review-arm.sh` (which asserts the
  Auditor-only routing security via the `*.auditor` keys) needs no change.
- `tests/test-auditor-grace-budget.sh` is updated for the new hard clamps (council 900s, blueprint 600s), executing the real normalization at each boundary.

## Revisit trigger

- If kimi-k3 becomes fast/reliable enough that a 120s pass consistently completes,
  reconsider putting the Mechanism Witness back in the plain-council roster.
- If a future Claude Code feature collides with "Witness" the way "Advisor" did,
  revisit the surface name (internal `auditor` keys are unaffected either way).
- If the ultimate-council latency ceiling is ever tightened below the oracle
  window, re-check the "no serial addition" argument above.

---

## Revision 2026-08-03 — blueprint clamp raised 600s → 1800s

**Status:** Accepted (amends the "blueprint 600s" decision above; council 900s unchanged)

### Context

The 600s blueprint clamp set by this ADR was chosen as a DoS bound, not a
capacity estimate. In practice k3 was observed timing out at 600s on real design
documents, so the reap killed it mid-flight and the round proceeded without the
Mechanism Witness — reintroducing exactly the "silently timing out" failure this
ADR raised 300s → 600s to fix, one size class up.

The operator also runs `ultraOracle.timeoutCapSeconds: 1800`, so the two
auxiliary voices had asymmetric allowances: 30 minutes for the oracle, 10 for k3.

### Decision

Blueprint `BLUEPRINT_AUDITOR_TIMEOUT` default and hard clamp both move to
**1800s**, matching the operator's configured oracle cap. Council stays at 900s.

### Alternatives considered

- **Leave at 600.** Rejected: it is the status quo that loses the witness on
  every heavy document, which is the problem this ADR exists to prevent.
- **Split the ceiling by source** — compiled default 1800, env-supplied override
  clamped to 600, on the theory that `BLUEPRINT_AUDITOR_TIMEOUT` is
  repo-injectable (#325 / ADR 0016) and therefore untrusted. **Implemented, then
  reverted.** It defends the wrong door: a hostile branch does not need the env
  var, it only needs k3 to be slow, which an adversarial or merely enormous
  design document achieves on its own. Omitting the variable already reaches the
  default, so the split could not reduce the worst case — it only added ~15 lines
  of ceiling-tracking state. Recorded here because the reasoning is not obvious
  and the idea will otherwise be reinvented.
- **900s middle ground.** Viable, and preferable on a multi-contributor repo.
  Not chosen here because there is no evidence k3 reliably fits 900, and a second
  round of "still timing out" costs more than the extra 15 minutes of ceiling.

### Consequences

- **The DoS bound is genuinely widened, 10 minutes → 30 minutes per round.** Any
  branch under review can hold the arbitration critical path (Phase 3) for up to
  1800s by making k3 slow. This is accepted, not mitigated. It is tolerable only
  because this repo is single-operator: the maintainer alone chooses when the
  gate runs and on which branch, so the stall is a scheduling cost to the person
  who opted into it, not a denial of service against other contributors.
  **On a multi-contributor repo this belongs back at 600.**
- **Requires operator harness budget.** `BASH_MAX_TIMEOUT_MS` must exceed the
  serial worst case, which is a formula rather than a constant:
  `max(reviewers(≤1200) + this reap's marginal add + droid rescue(≤1200),
  ultraOracle.timeoutCapSeconds + 90)`. At the shipped oracle cap the left term
  binds (~3010s); at the documented 3600 ceiling the right term binds (3690s).
  Set to 3600000 for this operator's `timeoutCapSeconds: 1800`.
- The reap does **not** add a full 1800s to a round: `AUDITOR_DEADLINE` is
  anchored at dispatch (#506), T0 alongside the reviewers, so it adds only ~610s
  past a worst-case reviewer wait. Deriving the budget as
  `reviewers + 1800 + rescue` over-provisions by ~20 minutes.
- `tests/test-auditor-grace-budget.sh` moves with it. Its Layer-2 extractor is
  anchored on the clamp line, so leaving the test untouched would have made it
  silently extract nothing rather than fail — boundaries are now 1800/1801, 600
  is retained as an in-range case, and the overflow assertion checks an exact
  ceiling instead of a `1..max` range that would have accepted any in-range
  garbage.

### Revisit trigger

- **A second approval-capable contributor is added to this repo** — the
  single-operator premise is the whole justification; lower to 600 or 900.
- k3 becomes fast enough that 900s consistently completes, or slow enough that
  1800s also times out (in which case the answer is checkpointing per #547, not
  a larger number).
