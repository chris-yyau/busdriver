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
reaction timestamp vs HEAD's commit time.

## Decision
1. **Tier F in `ack-ledger.sh`** (the prescribed single source): for
   `login == chatgpt-codex-connector` with non-empty `ALL_REACTIONS`:
   - **eyes-override (timestamp-independent):** a current 👀 reaction → `stale`.
     Codex re-adds 👀 whenever HEAD advances, so this is the robust guard for the
     re-review race and the backdated-commit residual.
   - a `+1` whose `created_at > HEAD_COMMITTED_DATE` → HEAD-ack (`:F`);
   - an engaged-but-not-fresh Codex (a 👍 from before the last push) → `stale`;
   - no reaction at all → falls through to the existing `none`.
   Codex-only and guarded on non-empty `ALL_REACTIONS`, so it is a strict no-op
   for every other login and for callers that don't fetch reactions (additive,
   like Tier E). Reaction JSON is slurped with `jq -rs` so it tolerates the
   multi-page stream `gh api --paginate` emits (Codex's 👍 can sit behind >30
   human PR-body reactions).
   **`HEAD_COMMITTED_DATE` is the *committer* date, not author date:** git resets
   committer.date to operation time on commit/amend/rebase/cherry-pick, so a
   rebased or cherry-picked HEAD reads as fresh and a pre-existing 👍 reads as
   stale — the realistic "old commit becomes HEAD" cases are handled.
2. **Codex is excluded from both "clean-ack" tiers — Tier A's disposed-thread
   branch and Tier B's `/reviews` branch.** A Codex review is *always* a findings
   post (it 👍s when clean), so neither a resolved/outdated thread from an older
   commit nor a COMMENTED `/reviews` entry may ack it — both would let a clean
   merge race ahead of, or merge past, Codex findings. Codex falls through to
   `stale` and its only positive ack is Tier F's fresh 👍. Its *unresolved*
   threads still block via Tier A.1 (login-agnostic), so live findings are never
   masked, and a findings `/reviews` entry blocks via the downgrade fall-through.
3. **Track Codex in a dedicated `RESULT_CODEX_ACK` field, NOT in the three-bot
   `RESULT_REVIEWER_ACKS` string.** A `stale` value blocks `clean` exactly like a
   stale registered bot (worker returns `needs_more`; the dispatcher COMPLETION
   `FRESH_ACKS` re-query blocks the merge). The field is additive/backward-
   compatible; the COMPLETION re-query is authoritative regardless.
4. The two new inputs (`ALL_REACTIONS`, `HEAD_COMMITTED_DATE`) are fetched and
   exported at all three ack-ledger call sites; reactions are fetched **with**
   `--paginate` (Tier F slurps the page stream).
5. **No-progress invariant is Codex-aware.** The dispatcher's wait-round
   legitimacy check (`needs_more` + no commit must coincide with some `stale`
   ack) now also accepts `RESULT_CODEX_ACK=stale`, so a Codex-only wait-round
   (all registered bots acked, Codex still reviewing) is not misread as
   no-progress and bailed. Empty/missing tag `!= stale` → prior behavior.
6. **First-engagement grace** at the COMPLETION gate: when Codex resolves to
   `none` (zero engagement), one bounded re-poll (`PR_GRIND_CODEX_GRACE_SECS`,
   default 20s, `0` disables) catches a Codex that hadn't yet posted its initial
   👀 on a just-pushed HEAD. Rarely fires — COMPLETION is reached only after the
   loop converges, by which point an active Codex has engaged.

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
where the grace re-poll (default 20s) still isn't enough for Codex to start; a
larger `PR_GRIND_CODEX_GRACE_SECS` covers slower starts. `ack-ledger.sh` stays a
pure classifier — the timing fix lives in the loop, not the tier.

**Deliberately backdated HEAD.** The clean-path freshness anchor is a timestamp
(Codex emits no SHA for a findings-free review). The committer-date choice
handles rebase/cherry-pick/amend (git resets committer.date to operation time),
so the only residual is a commit whose committer.date is *deliberately* set to
the past (`git commit --date` / `GIT_COMMITTER_DATE`) reused under a pre-existing
👍. The eyes-override (Codex re-adds 👀 on every HEAD advance → `stale`) and the
registered bots' own post-push staleness close this in practice; pr-grind's own
fix commits are never backdated.

## Revisit trigger
- Codex changes its completion signal (e.g., starts posting an APPROVED
  `/reviews` entry, or stops using reactions) → Tier F's anchor must change.
- The first-engagement race is observed to actually skip a Codex review in
  practice → implement the loop-level grace window.
- A second reaction-only reviewer appears → generalize Tier F beyond the Codex
  login guard.
