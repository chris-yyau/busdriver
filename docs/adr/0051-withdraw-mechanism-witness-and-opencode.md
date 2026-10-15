# ADR 0051 — Withdraw the Mechanism Witness (auditor) and the opencode CLI

## Status

**Accepted (2026-10-05).** Supersedes [ADR 0027](./0027-k3-mechanism-witness-ultimate-tier.md).
Amends [ADR 0030](./0030-blueprint-blocking-window.md) (the witness reap leaves the
blocking-window budget), [ADR 0005](./0005-codex-auto-retrigger.md) and
[ADR 0006](./0006-pr-mode-codex-deep-review.md) (opencode is no longer a review CLI of
any kind). Withdraws the `pi-auditor` role proposed in
`docs/plans/2026-08-23-pi-replacement.md` §0.2.

**Implementation:** lands in the same PR as this record, in the commits that follow
it (plan: `docs/plans/2026-10-05-withdraw-auditor-opencode.md`). Until that PR
merges, the Decision below describes the target state, not `main`.

## Context

The auditor ("Mechanism Witness", claim-vs-mechanism lens) ran in two places:
- as an auxiliary, non-gating 4th voice in blueprint-review;
- as the third expert witness in ultimate-council.

Both ran the `opencode` CLI under a plugin-owned read-only sandbox config, with the
model taken from the operator key `.auditor.model`.

- **Measured value is mixed.** Against three already-passed PRs (2026-07-20) it
  produced one true positive that Codex and the Opus backstop both missed, one
  confident false positive, and one correct nothing-found, with inverted confidence.
- **Reliability is poor.** Since 2026-10-03 every dispatch has failed: the configured
  model routes through an OpenCode Go balancer whose subscriptions return 403. Two
  days of blueprint and council runs proceeded without anyone noticing. #662: it
  returns unparseable output on code-heavy design docs. #547: auxiliary voices, this
  one included, can consume a whole review round.
- **Maintenance cost is high.** Keeping it means keeping the opencode CLI and the
  harness that contains it: sandbox HOME, home-config validation, auth staging,
  banner detection and a clean-child re-exec. Most of `resolve-cli.sh`'s opencode
  surface exists only for this voice.

## Decision

Delete the voice and the opencode CLI dependency.
- **blueprint-review:** three reviewers (agy, codex, grok) plus the Claude arbiter,
  with the UltraOracle where enabled.
- **council:** five voices. ultimate-council adds **two** expert witnesses (the
  UltraOracle and the Mythos Witness), each still rendered separately and never a vote.
- **Config:**
  - `opencode` joins the removed-CLI set (`amp|claude|aider`). A stale `opencode`
    route entry or `BUSDRIVER_REVIEW_CLI=opencode` is warned about and skipped exactly
    as `amp` is.
  - The `.auditor.model` key and the `blueprint-review.auditor` / `council.auditor`
    routes are retired. A leftover `.auditor.model` is ignored.
- **pi program:** the `pi-auditor` role is not built. The pi read lane and the
  `opencode-go` *provider* used by pi are outside this ADR.

## Alternatives

- **Migrate to a `pi-auditor` role** (the 2026-08-23 plan). Rejected: it builds a new
  lane (config key, prompt, parsing, deadlines, version certification) for a voice
  whose net value is uncertain.
- **Fold the lens into an existing reviewer prompt.** Not done now. It is cheap and
  reversible if the lens is wanted later (see Revisit trigger).
- **Keep it and fix the provider.** Rejected: it keeps the opencode dependency and
  the #662 / #547 failure modes.

## Consequences

- Blueprint review and council get shorter: no witness reap. One fewer third party
  receives repo content.
- The dedicated claim-vs-mechanism lens is gone, including the kind of unique catch
  it made once. The remaining reviewers and the arbiter still check claims, without
  a dedicated lens.
- #662 and #817 become obsolete. #547 and #570 shrink to their non-witness halves.

## Revisit trigger

A review that later proves a stated mechanism false, where the miss would plausibly
have been caught by a claim-vs-mechanism pass. Then add one line to an existing
reviewer prompt before considering a new voice.
