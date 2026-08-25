# ADR 0041 — Re-add Bugbot (cursor) to the pr-grind ack registry

**Status:** Superseded (2026-08-25, ADR 0047 — Bugbot dashboard-disabled; cursor dropped from registry again)
**Date:** 2026-08-17
**Amends:** ADR 0035 (cursor half only; the devin half stands; cursor half restored by ADR 0047)

## Context

ADR 0035 dropped `cursor` (Cursor Bugbot) and `devin-ai-integration` from
`REGISTERED_ACK_BOTS`. The evidence for dropping Bugbot was footprint, and the
footprint had one cause named in that ADR:

> The operator is on a $20/month plan that is insufficient for Bugbot and Devin
> to re-review every commit, so those two bots run only at PR-create time.

That constraint produced both symptoms the ADR measured: 13 PRs reviewed in 60
days, and the structural one — a review-once-at-create bot's clean review
strands stale on the pre-fix SHA after every fix round, which is why the ~130-line
Case-4 whitelist (ADR 0027) existed at all. Bugbot's *precision* was never the
problem: 90% of its findings were fixed, its exclusive finding was fixed 100% of
the time, and its catches were verified real (`dispatch.sh` `pi` omission,
commit-block active-flag parsing, redirect-hiding in the impl gate).

The operator is now on **Cursor Ultra**, which lifts the per-commit review
budget. With run-on-every-push enabled, Bugbot re-reviews each fix-round push
like `cubic-dev-ai`, `coderabbitai`, and `greptile-apps` — so the premise the
drop rested on no longer holds.

## Decision

Re-add **`cursor`** to the pr-grind ack registry. **`devin-ai-integration` stays
dropped** — its drop rationale was a 34% fix rate on its exclusive findings, a
value judgement no plan upgrade changes, and the Case-4 whitelist it needed
stays deleted.

Registry after the change: `cursor`, `cubic-dev-ai`, `coderabbitai`,
`greptile-apps` (ack-gated) + `codescene-delta-analysis`,
`chatgpt-codex-connector` (ledger). `REGISTERED_ACK_BOTS` grows 3 → 4; the
bot-ledger known-set invariant grows 5 → 6.

Mechanical changes:

- `scripts/dispatcher-commit-block.sh`: `REGISTERED_ACK_BOTS=(cursor cubic-dev-ai
  coderabbitai greptile-apps)`; the clean-path `RESULT_ACK_TIERS` fallback default
  regains its `cursor=none` entry.
- `scripts/ack-ledger.sh`: **unchanged.** Its tiers are login-agnostic except the
  Codex and `greptile-apps` guards, neither of which touches cursor — Bugbot's
  `Cursor Bugbot` check-run is clean-only, so it stays Tier-D eligible, exactly as
  before ADR 0035. Case 4 stays removed (it was devin-only).
- `skills/pr-grind/SKILL.md`, `skills/pr-grind/references/completion.md`,
  `agents/pr-grinder.md`: registry table row, ack/tier/ledger example strings,
  `FRESH_ACKS` scans, three-bot → four-bot phrasing, ledger count invariant 5 → 6.
- `scripts/augment-equiv-acks.sh`: Tier-D scope comment lists cursor again.
- `tests/test-dispatcher-commit-block.sh` (`test_m`) and
  `tests/test-pr-grind-codex-wiring.sh` (`POSTWAIT_LEDGER` + the two FRESH_ACKS
  anchors): exact-match ledger strings carry `cursor=` first.

Registry ORDER is `cursor` first — the pre-ADR-0035 order. The order is
load-bearing: `RESULT_REVIEWER_ACKS` is built by iterating the array, and two
tests assert the resulting string with `==`.

## Alternatives

- **Leave it dropped; rely on the GitHub-side review.** Rejected: Bugbot reviews
  the PR either way, but an ungated bot's findings are neither waited on nor
  enumerated, so a fix round can merge past a finding Bugbot posted seconds later.
  Gating is the whole point of the ledger.
- **Re-add Devin too.** Rejected: no new evidence. Its drop was about the value of
  its exclusive findings, not about its plan.
- **Gate cursor but keep it off Tier D** (mirroring the `greptile-apps` carve-out).
  Rejected: the greptile exclusion exists because its check goes green *with* open
  findings; Bugbot's check is clean-only (the property ADR 0035 itself cites when
  contrasting greptile with "cursor/coderabbit's clean-only Tier-D check"). Adding
  a carve-out cursor doesn't need would strand its clean runs at `none`.

## Consequences

- One more bot to converge per round. If Bugbot is genuinely absent from a repo it
  reads `none` (non-gating), so repos it isn't installed on are unaffected.
- The bot-ledger count invariant is 6. Any future registry change must move the
  count check, the ledger templates, and the two exact-match tests together.
- **The premise is dashboard-side and NOT repo-verifiable.** Nothing in this
  repository can assert that Bugbot's run-on-every-push setting is on for
  `chris-yyau/busdriver` — the Ultra plan makes it *possible*, the per-repo setting
  makes it *true*. Confirm it in the Cursor dashboard.

## Revisit trigger

If `cursor` strands `stale` through a fix push on the first multi-round PR after
this lands — i.e. it acked the pre-fix SHA and never re-acked the new HEAD — the
every-push setting is not actually on, and this ADR's premise is false. Either
enable the setting or revert to the ADR 0035 registry; do not paper over it with a
whitelist or a Tier carve-out. ADR 0035's own revisit trigger (a review-once bot
with a high exclusive-fix-rate) remains the bar for Devin.
