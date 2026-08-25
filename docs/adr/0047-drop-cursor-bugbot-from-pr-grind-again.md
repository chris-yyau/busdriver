# ADR 0047 — Drop Bugbot (cursor) from the pr-grind ack registry again

**Status:** Accepted
**Date:** 2026-08-25
**Amends:** ADR 0041 (supersedes its re-add); restores the cursor half of ADR 0035
**Related:** ADR 0027 (stranded clean reviews — Case 4 stays deleted)

## Context

ADR 0041 re-added `cursor` (Cursor Bugbot) to `REGISTERED_ACK_BOTS` because the
operator moved to Cursor Ultra with run-on-every-push enabled. That premise was
dashboard-side and not repo-verifiable; ADR 0041's own revisit trigger said:

> If `cursor` strands `stale` through a fix push … the every-push setting is not
> actually on … Either enable the setting or revert to the ADR 0035 registry.

On 2026-08-25 the operator **disabled Bugbot** in the Cursor dashboard so Cursor
Auto can keep included Ultra usage. With Bugbot off, every-push re-review is
gone again — the ADR 0041 premise is withdrawn. (Exact pool accounting between
Bugbot and Auto is product-side and can move with billing migrations; the
operator decision is the binding input here, not a claim that every Auto
request and every Bugbot run always share one named pool.)

Measured on `chris-yyau/busdriver` (Aug 1–25 2026, 23 PRs with Bugbot activity,
52 finding threads). **Same-file with Codex is a cheap overlap proxy, not the
ADR 0035 exclusivity bar** (which required PRs/findings no keep-bot flagged,
plus exclusive-fix rate). Cubic was over its monthly LOC limit for almost the
entire window, so the live keep-set was already missing ADR 0035's
highest-precision keep-bot:

| Wave | Findings / runs | Same-file Codex (Codex-present subset) | Different-file while Codex posted | Codex absent |
|---|---:|---:|---:|---:|
| Create / first run | 27 / 23 (~1.17/run) | 20/25 (80%) | 5/25 | 2 |
| Later / every push | 25 / 23 (~1.09/run) | 17/21 (81%) | 4/21 | 4 |

Findings-per-run barely moved (~7% worse on later runs). On the Codex-present
subset, ~4 in 5 later findings shared a file Codex already touched; counting
Codex-absent later findings as potentially unique raises later uniqueness from
4/21 (19%) to 8/25 (32%). Neither figure is an ADR 0035-grade exclusivity
audit against Cubic+CodeRabbit+Greptile+Codex.

## Decision

Drop **`cursor`** from the pr-grind ack registry again. Restore the ADR 0035
three-bot registry:

`cubic-dev-ai`, `coderabbitai`, `greptile-apps` (ack-gated) +
`codescene-delta-analysis`, `chatgpt-codex-connector` (ledger).

`REGISTERED_ACK_BOTS` shrinks 4 → 3; the bot-ledger known-set invariant shrinks
6 → 5. **`devin-ai-integration` stays dropped.** Case 4 stays deleted — do not
reintroduce a stranded-clean whitelist for an ungated bot.

Mechanical changes (must move together):

- `scripts/dispatcher-commit-block.sh`: `REGISTERED_ACK_BOTS=(cubic-dev-ai
  coderabbitai greptile-apps)`; clean-path `RESULT_ACK_TIERS` fallback drops
  `cursor=none`.
- `scripts/ack-ledger.sh`: unchanged (login-agnostic tiers; Case 4 already gone).
- `skills/pr-grind/SKILL.md`, `skills/pr-grind/references/completion.md`,
  `agents/pr-grinder.md`: registry row removed; ack/tier/ledger examples;
  `FRESH_ACKS` scans; four-bot → three-bot phrasing; ledger count 6 → 5;
  operator-facing registered-bot lists (completion criteria, anti-pattern
  tables, worked examples) drop Cursor as a gated peer.
- `scripts/augment-equiv-acks.sh`: Tier-D scope comment drops cursor.
- `tests/test-dispatcher-commit-block.sh`: `test_m` exact-match refreshed acks
  drop `cursor=`; `test_n` / `test_o` clean-path fixtures use
  `cubic-dev-ai=<sha>` / `cubic-dev-ai=D` (Tier-D pass-through regression kept,
  fixture retargeted — do not delete the D-tier assertion).
- `tests/test-pr-grind-codex-wiring.sh`: `POSTWAIT_LEDGER` + FRESH_ACKS anchors
  no longer carry `cursor=` first; bot-count comments 4→3 / 5→4 as appropriate.
- `docs/degraded-modes.md`: Bugbot row notes ungated; Greptile/CodeRabbit
  fallbacks no longer name cursor as a gated peer.
- Related ADR status text (must not stay contradictory): ADR 0041 → Superseded
  by this ADR; ADR 0035 cursor-half note restored; ADR 0012 registered-bot list;
  ADR 0027 supersession note (Case 4 stays deleted).

## Alternatives

- **Keep cursor registered while dashboard-disabled.** Rejected: acks read
  `none` (non-gating) when absent, but the ledger still pretends Bugbot is a
  live reviewer and the next operator who re-enables create-only Bugbot would
  reintroduce stranded `stale` without noticing.
- **Create-only Bugbot, stay gated.** Rejected: same stranded-clean failure mode
  ADR 0035/0027 already priced; measured uniqueness vs Codex is thin and not
  ADR 0035-grade against the full keep-set.
- **Re-add Devin too.** Rejected: unchanged 34% exclusive-fix evidence.

## Consequences

- One fewer bot to converge per round; Codex + Cubic + CodeRabbit + Greptile
  remain the gated / ledger load.
- Bot-ledger count invariant is 5 again. Future registry changes must move the
  count check, ledger templates, and exact-match tests together.
- **Dashboard/registry drift is fail-open for findings, fail-closed for
  stranded acks:** if Bugbot is re-enabled without a matching registry re-add,
  its findings are neither waited on nor enumerated (merge can pass an observed
  Bugbot comment). That is accepted only while Bugbot stays dashboard-off; a
  re-enable without a new ADR is an operator error, not a silent feature. The
  opposite drift (registry on, dashboard off) is what ADR 0041's revisit trigger
  already forbade via stranded `stale`.

## Revisit trigger

Re-open only if **both**:

1. Bugbot is re-enabled with verified every-push re-review on this repo (no
   stranded `stale` through a multi-round fix push), **and**
2. A fresh audit matching ADR 0035's bar shows a high exclusive-fix rate
   (example bar from ADR 0035: ~80%+ fix rate on PRs no other gated bot flags —
   Cubic, CodeRabbit, Greptile, and Codex when present), over a window of at
   least 30 days / ≥10 Bugbot-reviewed PRs.

Quota relief for Cursor Auto is not by itself a reason to re-gate. Same-file
overlap with a single bot is not sufficient revisit evidence.

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
