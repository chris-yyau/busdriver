# ADR 0002 — Gate Codex via reaction-aware Tier F, tracked in a separate field

## Status

Accepted (2026-06-07)

## Context

`chatgpt-codex-connector` (Codex) reviews every pr-grind PR but was **explicitly
excluded** from the ack registry (`agents/pr-grinder.md` Step 2.5): when it
finishes a review with no findings, its only signal is a 👍 (`+1`) **reaction**
on the PR body — it removes its 👀 (`eyes`) reaction and adds 👍. There is no
`/reviews` APPROVED entry, no check-run, no commit-status. Tiers A–E of
`ack-ledger.sh` are all SHA-keyed, so none can ack a bare reaction; the prior
registry note warned that registering Codex naively would **deadlock every clean
terminal push** (the ledger reads 👍 as `none`/`stale`, never a SHA) and
prescribed the fix: *"give `ack-ledger.sh` a reaction-aware tier."*

Empirical signal shape (verified on `Dive-And-Dev/chrisyau.me`):
- **Clean** (PR #142): `eyes` removed, `+1` added at the issue level; no
  `/reviews`, no comment. The `+1.created_at` (16:24:36Z) postdates HEAD's
  commit time (16:12:23Z) by ~12 min.
- **Findings** (PR #140): a `/reviews` COMMENTED entry with `commit_id` + inline
  threads carrying P1/P2/P3 badges. A 👍 lands later, once the findings are
  resolved. (These must BLOCK until triaged — see Decision 2; a Codex review is
  always a findings post, never a clean ack.)

So only the *clean* path needs a new positive-ack signal (the 👍 reaction); the
findings path must resolve to `stale`. The only available clean anchor is the
reaction timestamp vs the push event time (`HEAD_PUSH_DATE`).

## Decision

1. **Hoisted eyes-override (timestamp-independent), above every tier:** for
   `login == chatgpt-codex-connector`, a current 👀 reaction → `stale`. Codex
   re-adds 👀 whenever HEAD advances, so this is the robust guard for the
   re-review race and the backdated-commit residual. It runs BEFORE Tier A so a
   resolved-current-head thread (see Decision 2) cannot ack while Codex is still
   mid-review of a newer push.
2. **Tier F in `ack-ledger.sh`** (the prescribed single source), reached only
   when Codex is not mid-review:
   - a `+1` whose `created_at > HEAD_PUSH_DATE` → HEAD-ack (`:F`); absent a push anchor the `+1` path fails CLOSED to `stale` (#189) — see Amendment below,
     selected with `sort_by(.created_at) | last` (the reactions API does not
     guarantee result ordering);
   - an engaged-but-not-fresh Codex (a 👍 from before the last push) → `stale`;
   - no reaction at all → falls through to the existing `none`.
   Codex-only and guarded on non-empty `ALL_REACTIONS`, so it is a strict no-op
   for every other login and for callers that don't fetch reactions (additive,
   like Tier E). Reaction JSON is slurped with `jq -rs` so it tolerates the
   multi-page stream `gh api --paginate` emits (Codex's 👍 can sit behind >30
   human PR-body reactions).
   **`HEAD_COMMITTED_DATE` (committer date) is NO LONGER the Tier-F anchor as of #189:**
   it was originally the freshness anchor, but the committer date is client-stamped and
   backdatable (`git commit --date` / `GIT_COMMITTER_DATE`), so a leftover 👍 could
   falsely ack a deliberately-backdated HEAD. The `+1` path now anchors on
   `HEAD_PUSH_DATE` (server-stamped) ALONE and fails CLOSED when absent — see the
   Amendment under "Deliberately backdated HEAD" below.
3. **Codex thread handling — clear resolved-current-head, block everything else.**
   A Codex review is normally a findings post (it 👍s when clean), so it is
   excluded from Tier B's `/reviews` clean-ack and from non-Codex Tier A's
   any-disposed ack. But a **resolved + non-outdated** thread (a finding the
   worker addressed/dismissed on the *current* head via the out-of-scope-
   acknowledged workflow — no code push, so no new commit to trigger a fresh 👍)
   **does** ack via Tier A, or Codex would stay `stale` until `--max-wait` bails
   (the deadlock Codex's own review of this PR flagged). Live (`unresolved`)
   threads still block via Tier A.1 (login-agnostic); **outdated** threads block
   as `stale` (Codex must re-review superseded code), never ack; a COMMENTED
   `/reviews` findings entry blocks via the downgrade fall-through. The hoisted
   eyes-override guarantees none of these ack while Codex is mid-review.
4. **Track Codex in a dedicated `RESULT_CODEX_ACK` field, NOT in the three-bot
   `RESULT_REVIEWER_ACKS` string.** A `stale` value blocks `clean` exactly like a
   stale registered bot (worker returns `needs_more`; the dispatcher COMPLETION
   `FRESH_ACKS` re-query blocks the merge). It is also checked by Invariant 2
   (clean + stale → bail). The field is additive/backward-compatible; the
   COMPLETION re-query is authoritative regardless.
5. The two new inputs (`ALL_REACTIONS`, `HEAD_COMMITTED_DATE`) are fetched and
   exported at all three ack-ledger call sites; reactions are fetched **with**
   `--paginate` (Tier F slurps the page stream).
6. **No-progress invariant is Codex-aware.** The dispatcher's wait-round
   legitimacy check (`needs_more` + no commit must coincide with some `stale`
   ack) now also accepts `RESULT_CODEX_ACK=stale`, so a Codex-only wait-round
   (all registered bots acked, Codex still reviewing) is not misread as
   no-progress and bailed. Empty/missing tag `!= stale` → prior behavior.
7. **First-engagement grace** at the COMPLETION gate: when Codex resolves to
   `none` (zero engagement), a bounded re-poll (`PR_GRIND_CODEX_GRACE_SECS`,
   `0` disables) catches a Codex that hadn't yet posted its initial
   👀 on a just-pushed HEAD. Rarely fires — COMPLETION is reached only after the
   loop converges, by which point an active Codex has engaged.
   *(Revised 2026-07-19, #420: the single blind 20s sleep is now a poll — a 480s
   deadline polled every `PR_GRIND_CODEX_POLL_SECS` (30s), breaking the instant
   Codex engages. The full deadline applies only where Codex is proven-active or
   force-on; repos with no Codex keep the 20s courtesy wait. See the revisit
   trigger below and the ADR 0013 revision.)*

## Alternatives

- **Register Codex as a 4th `REGISTERED_ACK_BOTS` entry** (fold into
  `RESULT_REVIEWER_ACKS`). Rejected: Codex's clean signal is timestamp-keyed, not
  one of the A–E SHA-keyed structured acks. Folding it in would pull it into
  Invariant 3's intersection and force the "three registered ack-bots" contract,
  Invariant-3 exemption set, and worker/dispatcher prose to all move — large
  blast radius on the merge gate for no behavioral gain over the separate field.
- **Bolt-on reaction-wait at COMPLETION only** (no Tier F). Rejected: duplicates
  ack logic outside `ack-ledger.sh` (the exact smell PR #79 consolidated) and
  would need mirroring in the worker too.

## Consequences

- Codex is now waited on: a clean merge can no longer race ahead of an in-flight
  Codex review. Bounded by the loop's `--max-wait`; on exhaustion the loop bails
  to the operator (never silent-merge, never wait forever).
- Invariant 3 and the three-bot `RESULT_REVIEWER_ACKS` contract are **untouched**
  — the dedicated field keeps the SHA-keyed intersection scoped to the three.
- Fail-CLOSED preserved: a reactions/commit-date fetch failure sets
  `FETCH_OK=0` → `ack-ledger.sh` returns `stale` for every bot.

## Known limitations

**First-engagement race (now bounded, not eliminated).** In the brief window
after a fresh push but before Codex posts its first 👀, `ALL_REACTIONS` has no
Codex entry → Tier F returns `none` (non-gating). Closed at the loop level by
the COMPLETION first-engagement grace (Decision 6) plus the worker's Step 1
check-wait + 30s grace, and — on repos with registered bots — by those bots'
own post-push staleness forcing more rounds. The residual is a Codex-only repo
where the grace re-poll still isn't enough for Codex to start; a larger
`PR_GRIND_CODEX_GRACE_SECS` covers slower starts. `ack-ledger.sh` stays a
pure classifier — the timing fix lives in the loop, not the tier.
*(#420: this residual was measured, not theoretical — the old 20s default was
~15x under Codex's real 3–7min latency, so the re-poll always fell through. The
default is now a 480s polled deadline; see the revisit trigger below.)*

**Deliberately backdated HEAD.** *(For the `+1` path this residual is now CLOSED —
see the #189 Amendment below. The paragraph here describes the pre-#189 design, in
which the committer date was the clean-path anchor; it is retained for historical
context.)* The clean-path freshness anchor is a timestamp
(Codex emits no SHA for a findings-free review). The committer-date choice
handles rebase/cherry-pick/amend (git resets committer.date to operation time),
so the only residual is a commit whose committer.date is *deliberately* set to
the past (`git commit --date` / `GIT_COMMITTER_DATE`) reused under a pre-existing
👍. The eyes-override (Codex re-adds 👀 on every HEAD advance → `stale`) and the
registered bots' own post-push staleness close this in practice; pr-grind's own
fix commits are never backdated.

**Amendment (2026-06-18, #189):** This residual is now CLOSED for the `+1` path. The
Tier-F `+1` freshness anchor is `HEAD_PUSH_DATE` (server-stamped push event time) ALONE —
the backdatable committer date no longer participates — and the path fails CLOSED to
`stale` when no push anchor is available (fork head, events API aged-out/capped), matching
the resolved-thread path (#186). The eyes-override remains as defense-in-depth. The
operability cost (a no-push-date PR with a prior Codex finding can stall to `--max-wait`)
is accepted; a server-stamped fallback marker is a deferred follow-up.

## Revisit trigger

- Codex changes its completion signal (e.g., starts posting an APPROVED
  `/reviews` entry, or stops using reactions) → Tier F's anchor must change.
- The first-engagement race is observed to actually skip a Codex review despite
  the COMPLETION grace (Decision 6) → raise the default `PR_GRIND_CODEX_GRACE_SECS`
  or add a worker-side first-engagement wait.
  **FIRED 2026-07-19 (#420).** The race was observed skipping the review on PRs
  #412/#419/#409/#390: measured Codex latency is 3m37s–7m27s against a 20s grace
  (#413 is the related case where no review ever arrived). Actioned
  as prescribed — the blind sleep became a bounded poll (480s deadline, 30s interval,
  early-exit on engagement). See the ADR 0013 revision for the data and rationale.
- A second reaction-only reviewer appears → generalize Tier F beyond the Codex
  login guard.
