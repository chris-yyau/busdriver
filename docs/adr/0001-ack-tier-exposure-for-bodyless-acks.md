# ADR 0001 — Expose ack tier so Invariant 3 can permit bodyless clean acks

## Status
Accepted (2026-06-05)

## Context
PR #179 swaps `greptile` → `cursor` in the pr-grind ack registry. Cursor
("Bugbot") signals a clean review as a **check-run only** (ack-ledger Tier D),
with no inline thread, review, or comment body. CodeRabbit on private repos
does the same via a **commit-status** (Tier E).

The dispatcher's Invariant 3 ("bot-ledger coverage gate") bails when a
HEAD-acked bot has `n_total == 0`, to catch a worker that silently skipped a
bot's prose findings. But a genuinely-clean check-run/status-only bot
legitimately has `n_total == 0` — its only artifact is the structured ack,
which carries no enumerable body. Invariant 3 therefore deadlocks the merge on
every clean Cursor/CodeRabbit run.

A first attempt put a worker-side reconciliation (Guard A: a check-run/status
exists; Guard B: independently re-count Source 2/3/4 artifacts from the raw
fetches) that rewrote `0/0:none` → `0/1:no-findings`. Litmus review surfaced a
cascade of edge cases in Guard B's hand-rolled re-derivation (post-triage
thread mutation, comment pagination, reply-vs-thread-starter, Tier-E omission).
The pattern — each fix exposing a deeper hole — signalled a wrong-layer fix:
Guard B duplicates the enumeration the worker already did.

## Decision
Move the decision to the authoritative source. `scripts/ack-ledger.sh` already
knows which tier produced a HEAD-ack; expose it.

1. `ack-ledger.sh` gains an opt-in `ACK_EMIT_TIER=1` mode: a HEAD-ack SHA is
   suffixed `:<tier>` (A–E). Default output is byte-identical, so every
   existing caller is unaffected. `none`/`stale` are never suffixed.
2. The worker (`agents/pr-grinder.md` Step 6.5) computes the tier alongside the
   ack and emits a new additive `RESULT_ACK_TIERS` tag. `RESULT_REVIEWER_ACKS`
   stays bare SHAs (unchanged contract).
3. Dispatcher Invariant 3 (`skills/pr-grind/SKILL.md`) exempts a HEAD-acked bot
   with `n_total == 0` **iff** its ack tier ∈ {D, E}. Missing tag / missing /
   unknown tier → current strict bail (fail-CLOSED, backward-compatible).
4. The worker-side Guard A/B reconciliation is deleted.

## Why the exemption is sound
`ack-ledger.sh` resolves tiers in order A→B→C→D→E and returns at the first
HEAD-ack. Tier A returns `stale` on any unresolved/non-outdated Source-2 thread
and a Tier-A HEAD-ack on disposed threads — so **reaching Tier D/E proves the
bot has zero live Source-2 inline threads** (the dominant bot-finding channel).
For Source 3 (`/reviews`) and Source 4 (issue comments), the worker enumerates
them into `n_total` regardless of commit; `n_total == 0` means the worker found
none. The residual risk — the worker *missed* an existing Source 3/4 artifact
AND the bot acks via D/E — requires a worker enumeration bug, the same class of
bug Invariant 3 is a heuristic backstop for. We accept that residual in
exchange for deleting the fragile Guard B re-derivation.

## Alternatives
- **Keep Guard B (re-count artifacts in the worker).** Rejected: litmus showed
  it keeps sprouting edge cases; it duplicates the worker's own enumeration.
- **Encode the tier inside `RESULT_REVIEWER_ACKS` (`sha:tier`).** Rejected:
  breaks every existing SHA-equality / `^[0-9a-f]{7,40}$` consumer. A separate
  additive tag has zero blast radius on the ack-value contract.

## Consequences
- New opt-in env var on `ack-ledger.sh`; new `RESULT_ACK_TIERS` worker tag.
- Invariant 3 becomes tier-aware; backward-compatible (missing tier → bail).
- Inline execution path computes tiers the same way as the subagent path.
- **Fix-round consistency (fail-CLOSED):** on a fix round the dispatcher
  overwrites `RESULT_REVIEWER_ACKS` with the commit-block's post-push synthesis,
  which does NOT compute tiers. To avoid pairing a fresh post-push ack with the
  worker's stale pre-commit tier snapshot, the dispatcher resets
  `RESULT_ACK_TIERS` to all-`none` on the success branch of the commit-block
  envelope parse. Invariant 3 then grants no bodyless-ack exemption on fix rounds
  (strict pre-ADR-0001 behavior). The exemption fires only on clean/wait rounds,
  where acks and tiers both come from the same worker Step 6.5 pass. This keeps
  the commit-block contract unchanged (no tier synthesis there) at the cost of a
  rare, benign fail-closed bail if a bot bodyless-acks the new HEAD before the
  next round — strictly safer than applying a stale tier.

## Revisit trigger
If a bot emerges that posts actionable findings ONLY via a check-run/status
body (no Source 2/3/4 artifact), the D/E exemption would mask it — at that point
hoist that bot's check-run `output.text` into the worker's Step 2 enumeration
(the same escape hatch already noted in Step 2.6).
