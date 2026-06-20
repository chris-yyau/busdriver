# ADR 0004 — Carry reviewer-bot acks forward across content-identical force-pushes

## Status

Accepted (2026-06-20)

## Context

`scripts/ack-ledger.sh` keys every reviewer-bot HEAD-ack to a commit SHA. That is
deliberate and security-motivated: the timestamp tiers (Codex `+1` Tier F,
resolved-thread Tier A.2) distrust committer/push dates because they are
attacker-backdatable, and were hardened in #186/#189 to anchor solely on the
server-stamped `HEAD_PUSH_DATE` and fail CLOSED otherwise.

But SHA-keying conflates **"a bot acked this SHA"** with **"a bot reviewed this
code."** For a **message-only `git commit --amend` + force-push** they diverge:
the new commit has an **identical tree and identical parents** (identical
patch-id) but a **fresh SHA**, so every SHA-anchored tier misses. The bots won't
re-post acks (no code to re-review), so bots with review history fall through to
`echo "stale"` and block the merge gate until `--max-wait` bails (~8 min) — on
**every** message-only force-push: commitlint header fixes (the triggering case —
jikdak PR, commits `9d37b98`/`3761cf8`, identical trees + identical patch-id), DCO
sign-offs, GPG re-signing, commit-message typos. A predictable, guaranteed dead-end.

The tiers split by where their signal is fetched:

- **Tier B (`/reviews` `commit_id`) and Tier C (comment body-SHA)** come from
  **PR-wide** endpoints that still carry the pre-amend SHA.
- **Tier D (check-runs) and Tier E (commit-statuses)** are fetched per-commit at
  `commits/$HEAD_SHA/...` — **HEAD-scoped** — so the bot's signal on the pre-amend
  SHA is never returned. (A first draft fixed only B/C in the ledger; blueprint
  review (Codex, HIGH) caught that cursor — a verified blocker, Tier D — was still
  broken because the caller never fetches the predecessor's check-runs.)

## Decision

Two cooperating parts, both timestamp-FREE and fail-CLOSED.

### Part 1 — `acks_head()` in the ledger (Tiers B, C, D)

HEAD-ack a candidate SHA when it covers HEAD via **either** a direct 8-char-prefix
match (pre-fix behavior; short-circuits before any git call — common path
unchanged and git-free) **or** git-proven **content identity**: same tree AND same
parents as the HEAD OID. Proven from git object hashes (the tree SHA is a Merkle
hash of the snapshot; parents are pinned), so it cannot be forged without a SHA
collision and does not depend on any timestamp. The candidate is **sanitized**
(hex, 7–64 chars — SHA-1 or SHA-256) before reaching git — it is bot-controlled, so a value like
`-O…`/`--upload-pack=…` would otherwise be an argument-injection vector. The
reference is the **full** `$HEAD_FULL_SHA` when present (not the 8-char prefix), so
the proof never hinges on abbreviation uniqueness. Tiers B/C/D emit `$HEAD_SHA` on
a carry-forward (output contract unchanged in the direct-match case).

### Part 2 — `scripts/augment-equiv-acks.sh` (sourced) for Tier D (check-runs)

Because check-runs are HEAD-scoped, Part 1 alone can't see the predecessor's
check-run. This sourced helper runs after the HEAD-scoped fetch and before the
ledger: it derives candidate predecessor SHAs — **priority order**: the force-push
timeline (`HeadRefForcePushedEvent.beforeCommit`, the authoritative prior-HEAD
source; needs `PR_NUMBER`), then non-HEAD `/reviews` `commit_id`s + comment
body-SHAs already in hand (deduped, HEAD excluded, capped); sanitizes each (hex,
7–64 chars — SHA-1 or SHA-256), **best-effort `git fetch origin <sha>`** (a fresh
clone / `pull/ID/head` checkout may lack the pre-force-push object; GitHub serves
any pushed SHA by id), and git-proves content identity (same predicate as
`acks_head`); then fetches **only** the proven predecessors' **check-runs** and
**appends** them to `ALL_CHECK_RUNS` (at most 4 predecessors — content-identical
ones are interchangeable, bounding API budget). Tier D then **re-proves** identity
via `acks_head(check_run.head_sha)` — defense in depth. A predecessor check-run is
appended **only for an app HEAD reports nothing from**, so a HEAD pending/failure/
in-progress is never masked by an old predecessor success (the same `last`-wins
precedence concern that excludes Tier E). Strictly **additive** and best-effort:
only appends already-acked check-runs for byte-identical commits, never removes
data, and **never sets `FETCH_OK=0`**. Wired as a one-line `source`
into all four fetch sites — `scripts/fetch-pr-state.sh` (dispatcher / merge-gate
path), `agents/pr-grinder.md` Step 6.5 (worker), and the two
`skills/pr-grind/SKILL.md` mirrors — kept in sync.

**Tier E (commit-statuses) is deliberately NOT carried forward.** A status object
carries no SHA the ledger can re-prove, so an appended predecessor status would
rest on this helper's proof alone *and* `last`-wins precedence could let a
predecessor success override a HEAD `pending`/`failure`. Tier E stays correct on
its own HEAD-scoped fetch (a re-reviewing bot posts a fresh HEAD status; one that
doesn't → `none`, non-blocking).

`ACK_CONTENT_IDENTITY=0` disables both parts.

## Alternatives

- **`git patch-id` over the cumulative diff.** Rejected: default whitespace
  stripping is undesirable for a security gate, and it must recompute the base.
  Tree-SHA identity is stronger and git-native; parent-pinning supplies the base.
- **Tree identity only (no parent pin).** Rejected: a changed base with a
  coincidentally-identical final tree would carry forward a different reviewed
  diff. Parent-pinning keeps the proof tight and matches the amend-without-rebase
  class the verdict describes.
- **Ledger-only fix (Tiers B/C), defer D/E.** Rejected after review: it leaves
  cursor (Tier D), a verified jikdak blocker, broken — the dead-end would persist.
- **Fetch the predecessor inside the ledger.** Rejected: the ledger is a pure
  classifier with no network I/O; the predecessor fetch belongs in the caller
  layer (the additive `augment-equiv-acks.sh`), and the ledger still re-proves.

## Consequences

- Message-only force-pushes (commitlint/DCO/GPG/typo) no longer dead-end: Tier B/C
  carry forward in the ledger, Tier D via the predecessor check-run fetch; Tier E
  stays correct on its own HEAD-scoped fetch.
- The gate is **not** loosened: a real code change (different tree) or a rebase
  (different parent) still falls through to `stale`. Covered by
  `tests/test-ack-ledger-content-identity.sh` (10 cases incl. arg-injection +
  `HEAD_FULL_SHA`) and `tests/test-augment-equiv-acks.sh` (4 cases, `gh` stubbed +
  real git, end-to-end Tier-D ack proven).
- The Codex timestamp tiers (F / A.2) are untouched.
- **Required status checks are NOT carried forward — only the AI-reviewer ack ledger
  is.** Tier D acks the *code reviewers* (cursor/cubic/coderabbit), which approve the
  tree. The required status checks that are the actual merge authority (commitlint,
  DCO, signature, CI) are enforced by GitHub branch protection on the real HEAD and
  re-run independently of this ledger. So a metadata-only amend with, e.g., a bad
  commit message cannot merge via carry-forward — commitlint still fails on HEAD.
  This matches pr-grind's standing invariant ("required status checks are the merge
  authority; AI reviewer acks are bounded-wait advisory signals"). It is also why
  carrying a code-reviewer ack across a message/DCO/signature change is sound: the
  reviewer approved the tree, and the metadata is validated elsewhere.

## Known limitations

- **Tier E (commit-status) is not carried forward** — see Part 2. Not a dead-end:
  a re-reviewing bot posts a fresh HEAD status; one that doesn't yields `none`
  (non-blocking).
- **Codex tiers (F / A.2) do not carry forward** — reaction/timestamp-anchored, no
  SHA; left untouched to preserve the #186/#189 hardening. In practice Codex
  re-reviews on *every* push, so it refreshes its own 👍 on a message-only amend
  rather than persistently blocking; the fix targets the SHA-keyed reviewer bots
  (B/C/D) that skip re-running on identical content.
- **Predecessor SHA undiscoverable / unfetchable** — if no timeline/`reviews`/comment
  signal names the pre-amend commit, or the best-effort `git fetch` can't retrieve
  it, the carry-forward simply doesn't fire and the bot keeps its **pre-fix
  classification** — `none` (non-blocking) for a check-run-only bot with no other
  signal, `stale` for a bot with review history — **never a false HEAD-ack**.
  Narrower than the original dead-end; the common multi-bot PR is covered (a
  `/reviews` bot such as cubic-dev-ai, or the force-push timeline, supplies the
  predecessor SHA).
- **Whole-branch reword (rebase), not a tip `--amend`.** Parent changes ⇒ no
  carry-forward ⇒ `stale`. Accepted: the triggering cases are tip amends.

## Revisit trigger

- A check-run-only repo with no SHA-carrying bot signal is observed to stall on
  message-only force-pushes despite the timeline source → strengthen predecessor
  discovery (e.g. local reflog candidates for the worker path).
- A requirement to carry acks across rebases (changed base) → revisit the
  parent-pin; would need diff-against-base equivalence, not tree+parent identity.
- git SHA-1 → SHA-256 migration edge → re-confirm the Merkle-hash soundness argument.
