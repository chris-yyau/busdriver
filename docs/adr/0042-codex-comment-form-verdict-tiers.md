# ADR 0042 — Read Codex's comment-form verdicts: Tier G ack, comment-as-engagement

**Status:** Accepted
**Date:** 2026-08-18

## Context

`scripts/ack-ledger.sh` classifies each review bot's signal on the PR head as
`<sha>` (acked), `stale` (engaged, not acked), or `none` (non-gating). For
`chatgpt-codex-connector` the design rested on a premise stated verbatim in the
Tier B exclusion comment and in OpenAI's own integration footer:

> If Codex has suggestions, it will comment; otherwise it will react with 👍.

Read as: findings arrive as **review threads / `/reviews` entries**, and the only
clean signal is a **👍 reaction** (Tier F). Every Codex path in the ledger was
built on that split.

On 2026-08-17 both halves failed on two PRs inside one hour:

| PR | head | what Codex actually did | ledger said |
|---|---|---|---|
| #687 | `f4f05d37` | clean verdict as an **issue comment**, no 👍, 👀 left in place | `stale` forever |
| #688 | `bd532d84` | clean verdict as an **issue comment**, zero reactions at all | `stale` forever |
| #688 | `2ff0484b` | a real **P2 finding** as an **issue comment**, no thread | (masked by outdated threads) |

The comment-form clean verdict acked through no tier: not a review (B), no thread
(A), no check-run/status (D/E), no reaction (F). Both PRs exhausted their
`@codex review` nudge budget — the nudges **landed**, and Codex answered in
comment form each time, so #673's bounded-N retry could not help. Both merged
only under an operator `.claude/skip-pr-grind.local`. The gate did not merely
stall: it reported "Codex has not acked" about a commit Codex had explicitly
approved by SHA. Filed as #690 (from #687) with corroborating #688 evidence.

The delivery change was not clean-vs-findings and not a one-off. On #688 the
mechanism switched **part-way through the same PR** — reviews at 13:29/14:04/15:30,
then comments at 17:36 (with a finding) and 18:11 (clean) — and persisted.

## Decision

Read Codex's comments. Three changes in `scripts/ack-ledger.sh`, all scoped to
`chatgpt-codex-connector` — plus one deliberately GLOBAL hardening, called out at
the end of this section because it changes every bot's behaviour on a broken
snapshot.

**1. Tier G — the clean-verdict comment acks HEAD.** The last Codex-authored
issue comment acks when its body **starts with** `Codex Review: Didn't find any
major issues.` and its `**Reviewed commit:** <sha>` line names HEAD. Freshness is
the **SHA itself** — no push/check-suite anchor is consulted, the same proof
shape as Tiers B and C (including their ADR 0004 content-identity allowance) and
stronger than the timestamp anchors F and A.2 need.

Placement is load-bearing in both directions: **below** Tier A.1, so a live
unresolved thread always outranks a clean comment; **above** the eyes-override,
because comment-form completion leaves the 👀 in place (#687: eyes at 17:39:45Z
outlived verdicts at 17:43:20Z and 17:50:56Z) and an eyes-first order would
swallow the ack in exactly the case it exists to fix. Ordering around the
eyes-override would have merely traded one blind spot for another, so Tier G
keeps the property that override was approximating, and keeps it precisely: it
**declines on any Codex activity at or after the verdict** — a 👀 (a re-review in
flight on this same HEAD) or a `/reviews` entry (always a findings post, and a
body-only one opens no inline thread for A.1 to catch) — while a 👀 that predates
the verdict is residue of the review that produced it. The comparison is `>=`:
GitHub timestamps are second-resolution, so a re-review kicked off inside the
verdict's own second would compare equal, and a tie is exactly the ambiguous
case.

**2. A Codex comment that Tier G declined blocks every tier below it**, when it
postdates the freshness anchor. Reaction and comment are separate objects, so
publishing a finding does not retract an earlier 👍; without this, a leftover
Tier F reaction acks HEAD while a comment-form finding sits unaddressed. Scoped
to post-anchor comments so a superseded finding — the comment-form twin of an
outdated thread — cannot veto the 👍 that answered it.

**2a. The block's own threshold tracks a LATER 👍, not just the push (#693 round
4, Codex P2).** A finding comment can itself be superseded by a still-later
clean reaction that carries no new comment — Codex re-reviewing the unchanged
HEAD and expressing satisfaction only via 👍. If the block compared every
post-push comment against `anchor_date` alone, that later reaction could never
clear the gate (another push or comment-form verdict would be required even
though Codex had already said, via the reaction, that it was done). The veto
threshold is `anchor_date`, EXCEPT when a fresher 👍 exists — then it is that
👍's own timestamp, so a finding strictly OLDER than the reaction is treated as
superseded (no veto) while a finding NEWER than the reaction (a re-review that
found something after all) still blocks.

**3. A pre-anchor Codex comment is engagement, not absence:** it yields `stale`
rather than falling through to `none`.

Every count these paths read is coerced through a new `num_or` helper that
substitutes the **blocking** value when jq errors or returns a non-integer.

**The one global change:** the Tier A.1 live-thread query now defaults to `1`
rather than `0` on failure, so an unreadable `ALL_THREADS` stales **every** bot
where it previously fell through to Tier B. Tier G's whole precedence claim rests
on A.1 having proven there is no live finding, and a proof that silently returns
"no findings" when it could not read the threads is not a proof. Fail-closed on a
snapshot the caller asserted was complete (`FETCH_OK=1`) is the file's stated
posture; scoping the default to Codex would have left the same hole for the three
registered bots for no reason. A missing timestamp sorts as `9999`, i.e. newer than
everything, so an unreadable record blocks rather than acks.

**Every source Tier G reasons about is validated by shape before its count is
believed.** This is the part that took the most review rounds, and the reason is
structural: each guard concludes from a count of ZERO — no live thread, no newer
👀, no newer review — and `jq` reports zero just as readily for a source that is
missing, null, or drifted as for one that is genuinely quiet, with exit status 0
throughout. Neither `|| echo 1` nor `num_or` ever fires on that path, so an
UNREAD source is indistinguishable from a quiet one and Tier G becomes the only
tier whose guards a broken caller can silently switch off. The predicates
therefore reach the **fields the counts index**, not just the outer container:
`[{}]`, `user:{}`, `author:{"login":null}` and `content:{}` all parse cleanly and
all drop out of a login-filtered count.

Two lines are drawn deliberately. **Presence, not value, on identity** — but
`user: null` / `author: null` is the shape GitHub emits for a **deleted account**
and must parse, or the tier fails closed forever on any PR one of them touched;
`{}` or a non-string login is drift and blocks. **Timestamps get a format check,
not just a type check** — the comparisons are lexicographic, so the string `"0"`
is a well-typed value that sorts before every real date; only the UTC `Z`
ISO-8601 form GitHub emits is accepted.

## Alternatives considered

- **Whitelist the full clean line.** Rejected on evidence: the two observed
  verdicts differ in their tail (`:rocket:` on #687, `Swish!` on #688), so any
  full-line whitelist matches one PR and misses the other. Only the stable prefix
  is matched; the tail is free text.
- **Scan the body for any commit SHA (reuse Tier C's shape).** Rejected as a
  fail-open, demonstrated by our own data: #688's *findings* comment embeds
  HEAD's 40-char SHA in a blob permalink, so a body-wide hex scan would have
  acked a comment carrying an unaddressed P2. The SHA is read only from the
  `**Reviewed commit:**` line. Tier C's existing `commit/<sha>` **link** grep was
  a near-miss for the clean body, not a usable gap — Codex writes a bare code
  span, never a URL.
- **Treat "comment ⇒ clean".** Rejected: #688's 17:36 comment carried a real P2.
- **Fix it in the nudge instead.** Rejected: three nudges landed on #688 and all
  three were answered in comment form. The nudge is still required (nothing else
  makes Codex re-review an unchanged HEAD), but it was never the missing piece.
- **Leave the `none` fall-through alone** (scope the change to the clean verdict
  only). Rejected once the tests made it visible: a PR whose Codex findings
  arrive only as comments — now the normal shape — classified `none`, i.e.
  **non-gating**, and would merge past an untriaged finding. Same premise, worse
  direction.
- **Block on ANY Codex comment, unanchored.** Rejected: a findings comment from
  before the last push would then veto the fresh 👍 that answered it, and every
  PR Codex ever commented on would deadlock. Anchoring the block to
  post-`anchor_date` comments is what makes the tightening convergent.

## Consequences

- Codex converges on a comment-form clean verdict instead of dead-ending at
  `--max-wait`; the ~1h/3-nudge cost seen on #687 and #688 does not recur.
- The `none` → `stale` change is **strictly more blocking**. An off-topic Codex
  comment (e.g. a reply to `@codex address that feedback`) now holds the gate
  until Codex re-reviews clean. That is the correct direction to be wrong in on a
  merge gate, and `--max-wait` remains the operator-visible backstop.
- Tier letter `G` is inert downstream: `pr-grinder.md`'s `_ackpart` strips the
  suffix for `CODEX_ACK`, and Invariant 3's bodyless-ack exemption special-cases
  only D/E.
- The premise "Codex's only positive ack is the Tier F 👍" is now false and was
  corrected wherever it was asserted: `ack-ledger.sh` (header, Tier B exclusion,
  outdated-thread branch), `codex-retrigger.sh`, `agents/pr-grinder.md`,
  `skills/pr-grind/SKILL.md`, `skills/pr-grind/references/completion.md`.

## Verification

Replaying PR #688's real GitHub state (7 sources, `HEAD_SHA=bd532d84`) through
both ledgers: the pre-fix one returns `stale` — the verdict that forced the
operator override — and this one returns `bd532d84:G`. PR #687, the sibling case
that filed #690, likewise goes `stale` → `c78c25e0:G`. 50 unit tests cover the
tier, every body a verbatim capture from those two PRs.

Known workflow gap, not addressed here: a comment-form **finding** now blocks
correctly, but has no dismissal path — there is no thread to resolve, so the only
exits are a fix-push or a clean re-verdict from Codex, with `--max-wait` as the
backstop. That case was fail-OPEN before this change, so it is strictly better;
the missing out-of-scope-acknowledged path is tracked on #690.

## Revisit trigger

Codex resumes reacting 👍 on clean reviews (Tier G stops firing — harmless, but
the `none`→`stale` tightening should then be re-justified on its own), **or** the
clean template's prefix changes (Tier G silently stops acking and Codex reads
`stale` again — the fail-closed direction, but it looks exactly like #690). A
template change is the one to watch: pin it by re-running
`tests/test-codex-clean-comment-tier.sh`, whose fixtures are verbatim captures.
