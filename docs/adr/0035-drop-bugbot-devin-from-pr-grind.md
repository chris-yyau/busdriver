# ADR 0035 — Drop Bugbot (cursor) and Devin from the pr-grind ack registry

**Status:** Accepted (cursor half amended by ADR 0041 — Bugbot is registered again; the devin drop stands)
**Date:** 2026-08-09

## Context

pr-grind gates merge on a fixed ack registry of advisory reviewer bots
(`REGISTERED_ACK_BOTS` in `scripts/dispatcher-commit-block.sh`, the Step 2.5
registry in `agents/pr-grinder.md`, and the 7-entry bot ledger in
`skills/pr-grind/SKILL.md`). As of the decision date the registry contained
`cursor` (Cursor Bugbot), `cubic-dev-ai`, `coderabbitai`,
`devin-ai-integration`, and `greptile-apps`, with `codescene-delta-analysis`
and `chatgpt-codex-connector` (Codex) tracked in the ledger.

The operator is on a $20/month plan that is insufficient for Bugbot and Devin
to re-review every commit, so those two bots run only at PR-create time. The
question: are they worth keeping in the gate at all, given the other bots
(Codex pr-grind, Cubic, CodeRabbit, Greptile) keep reviewing every commit?

**Evidence (60-day window 2026-06-10..08-09, 14 repos, 682 PRs; findings
verified against actual code in local checkouts):**

| Bot | PRs reviewed | Findings (threads) | Fixed % | PRs exclusively flagged | Exclusive-finding fix % |
|---|---|---|---|---|---|
| Bugbot (cursor) | 13 | 41 | 90% | 1 | 100% |
| Devin | 382 | 358 | 72% | 60 | **34%** |
| Codex pr-grind | 175 | 594 | 63% | 26 | 52% |
| Cubic | 352 | 564 | 92% | 8 | 100% |
| CodeRabbit | 186 | 554 | 90% | 30 | 84% |
| Greptile | 35 | 46 | 93% | 9 | 100% |

Key findings:

- **Bugbot reviewed only 13 PRs in 60 days across 4 repos** (24 review events).
  Its findings were real (verified: dispatch.sh `pi` omission, commit-block
  active-flag parsing, redirect-hiding in the impl gate) and 90% fixed — but
  **92% of its flagged PRs were also flagged by a keep-bot**; only 1 PR was
  exclusively its catch. Its footprint is too small to justify gate cost.
- **Devin had the widest footprint** (382 PRs / 10 repos) but its **60 exclusive
  PRs carry only a 34% fix rate** — its unique findings were mostly
  dependency/version nags (jsdom Node floor, workflow version-comment
  staleness, stale frontmatter) the author ignored. A couple were real
  (commitlint Node floor #244, CVE-report path #82) but went unfixed too.
- **Both Bugbot and Devin are review-once-at-create bots** (ADR 0027): they
  review only the PR-create commit and structurally never re-review fix-round
  pushes. That is exactly the $20-plan constraint, and it means their clean
  reviews strand stale on the pre-fix SHA after every fix round — the reason
  the ~130-line Case-4 fail-CLOSED whitelist (ADR 0027) existed at all.
- **Keep-bots carry the load with better precision**: Cubic 92% fixed, CodeRabbit
  90%, Greptile 93% — and Codex pr-grind is the loop's actual re-review engine
  (594 findings on 175 PRs).

## Decision

Drop **`cursor` (Bugbot)** and **`devin-ai-integration` (Devin)** from the
pr-grind ack registry. They remain installed on the GitHub side (they still
review at PR-create where the plan allows); pr-grind no longer gates on their
acks or enumerates their findings.

Registry after the change: `cubic-dev-ai`, `coderabbitai`, `greptile-apps`
(ack-gated) + `codescene-delta-analysis`, `chatgpt-codex-connector` (ledger).
The bot-ledger known-set shrinks 7 → 5; `REGISTERED_ACK_BOTS` shrinks 5 → 3.

Mechanical changes:

- `scripts/dispatcher-commit-block.sh`: `REGISTERED_ACK_BOTS` and the clean-path
  tier default drop cursor/devin.
- `scripts/ack-ledger.sh`: **Case 4 removed** (~130 lines, the Devin clean-body
  whitelist). Tier D's greptile login guard, Codex Tier F, and Case 3 (cubic
  merge-commit skipping) are untouched.
- `skills/pr-grind/SKILL.md` + `agents/pr-grinder.md`: registry tables, ack
  templates, FRESH_ACKS, worked examples, and the known-bot count invariant
  (7 → 5) updated.
- `tests/test-ack-ledger-devin.sh` deleted (pinned the removed Case 4); advisory
  and resolved ack-ledger test fixtures re-pointed at still-registered bots
  (greptile-apps / cubic-dev-ai), keeping the Tier-D tests on Tier-D-eligible
  logins.
- `docs/adr/0012` registered-bot list updated; `docs/adr/0027` marked
  superseded.

## Alternatives

- **Keep Devin, drop only Bugbot.** Rejected: Devin's exclusive-PR fix rate
  (34%) shows its unique value is mostly ignored nags, and keeping it forces
  the Case-4 whitelist to stay alive for a bot that can't re-review. The 61%
  overlap with keep-bots means the real catches are caught twice anyway.
- **Keep both but stop gating, keep enumerating.** Rejected: enumeration
  without gating keeps the ledger count at 7 for zero gate value — the worker
  would still triage their findings, and the registry invariant stays complex
  for bots that contribute ~0 unique actionables.
- **Move them to Tier-C-only (issue-comment SHA).** Rejected: their review
  mechanism (threads + `/reviews`) is already fully covered by the generic
  tiers; the problem was never the tier, it was review-once + redundancy.

## Consequences

- Fewer bots to wait on per round: fix-round convergence no longer depends on
  two bots that never re-review, so `--max-wait` bails on stranded acks should
  drop (the primary ADR 0027 failure mode is gone).
- The bot-ledger count invariant is 5, so any future re-registration must
  update the count check and the ledger templates together.
- Coverage on repos where Devin was the *only* reviewer (e.g.
  Dive-And-Dev/class-roll) drops to zero **pr-grind-gated** AI review — the
  GitHub-side Devin review at PR-create is unchanged (Devin stays installed;
  only gating and enumeration are removed). Accepted: those repos' pr-grind
  gate never depended on Devin meaningfully (its exclusive findings were
  mostly ignored). The registry is a fixed array (no per-repo override), so
  re-adding Devin is a code change, not a per-repo flag.
- Cost: the $20 plan pressure is relieved for the two most redundant bots.

## Revisit trigger

If a review-once bot with a *high* exclusive-fix-rate (e.g. a Bugbot-tier
reviewer with 80%+ fix rate on PRs no other bot flags) is proposed, re-open
this ADR before re-adding it to the registry — the drop was data-driven, not a
statement that all review-once bots are worthless.
