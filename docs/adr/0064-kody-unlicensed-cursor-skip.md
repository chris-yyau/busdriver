# ADR 0064 — Kody's "User Not Licensed" skip on a Cursor-bot PR is waived, not acked

**Status:** Accepted (2026-11-13). Plan `docs/plans/2026-11-13-kody-unlicensed-cursor-skip.md`
passed blueprint review with FULL 3/3 coverage. Merge is held for the operator: this change
relaxes a review gate.
**Date:** 2026-11-13
**Amends:** ADR 0058 Decisions 2, 7 and 8, and its Revisit trigger ("Kody completing with
`neutral` / `skipped` on PRs other than merge-only HEADs … decide between an automatic nudge
and a new ADR making those conclusions non-gating"). This is that ADR, for one skip only.

## Context

Kody (Kodus, app `kody-ai`) is compulsory in pr-grind (ADR 0058). Tier K in
`scripts/ack-ledger.sh` reads `kody-ai` as `stale` unless the deciding `Kody Code Review`
check-run completed `success` on HEAD, so every Kody skip blocks the grind until `--max-wait`.

Kodus licenses seats per PR author. A PR opened by the Cursor cloud agent is authored by the
GitHub App bot `cursor[bot]`. That author currently has no Kodus seat, so Kody skips the
review. Upstream Kodus source suggests a seat can be assigned to a bot identity: in
`resolveIgnoreState`, a held seat overrides the automatic bot exclusion. Whether the deployed
Kodus org allows it is unverified, and this ADR does not claim seats are unavailable. Observed
on Dive-And-Dev/chrisyau.me#462 (head `3fe501d075a49d7aa6cdd463783e986024c0dcc6`):

| Field | Value |
|---|---|
| check-run id | `131335693133` |
| `app.slug` / `app.id` | `kody-ai` / `413034` |
| `name` | `Kody Code Review` |
| `status` / `conclusion` | `completed` / `skipped` |
| `output.title` | `Code Review Skipped` |
| `output.summary` | `User Not Licensed — Assign seat to user` (U+2014 em dash) |
| `head_sha` | `3fe501d075a49d7aa6cdd463783e986024c0dcc6` |
| `pull_requests` | `[{number: 462}]` |
| PR (GraphQL) | `number: 462`; author `__typename: Bot`, `login: cursor`, `databaseId: 206951365` |
| PR author (REST) | `user.login: cursor[bot]`, `user.type: Bot`, `user.id: 206951365` |

Until the author is licensed, every grind on such a PR bails naming `kody-ai`.

## Decision

1. **One waiver, one shape.** Tier K gains exactly one non-`stale` outcome besides its
   `success` ack. The waiver applies only when **all** of the following hold, each read from
   GitHub-stamped data that the PR author cannot write. Every predicate is decided inside `jq`
   on the raw JSON values, so the whitespace-split `read` of the deciding run cannot shift a
   value into place.
   - **Author and PR.** Every page of the `ALL_THREADS` GraphQL snapshot carries the same
     integer `pullRequest.number`, and a `pullRequest.author` equal to `__typename "Bot"`,
     `login "cursor"`, `databaseId 206951365`. Both come from one selection added to the
     existing threads query (`number author{__typename login ... on Bot{databaseId}}`), so they
     belong to the same snapshot that `THREADS_FETCHED_AT` stamps. `__typename` is set by
     GitHub: a user account named `cursor` reads `User`.
   - **Check identity.** The deciding run is the one Tier K already picks: the highest `id`
     among the `kody-ai` / `Kody Code Review` runs, with any run not `completed` → `stale`. For
     the waiver, two more conditions apply:
     - every candidate run has a positive integral numeric `id`, and every `check_runs`
       container is an array, so "highest" is provable;
     - the deciding run carries `app.id == 413034`.
   - **Skip reason.** `conclusion == "skipped"`, `output.title == "Code Review Skipped"` and
     `output.summary == "User Not Licensed — Assign seat to user"`, all exact string equality.
     The U+2014 is built from its code point in jq (`[8212] | implode`), so the ledger source
     stays ASCII. Every other skip — "Only Merge Commits", "Branch Mismatch", file limit,
     drafts — reads `stale`, as do `neutral`, `failure`, `cancelled` and the rest.
   - **Exact full HEAD.** `HEAD_FULL_SHA` must be exported as 40 lowercase hex characters, and
     the run's `head_sha` must equal it byte for byte. Anything else is refused: missing,
     empty, an 8-character prefix, uppercase, padded or different. The ADR 0004
     content-identity carry-forward (`acks_head`) is **not** used for the waiver. Every ledger
     consumer already exports a full `HEAD_FULL_SHA`, and the dispatcher's two explicit export
     lists now name it too; a test pins all five export statements.
   - **Bound to this PR.** Check-runs are commit-scoped, so the deciding run's `pull_requests`
     must be an array listing exactly one PR, whose number equals the snapshot's
     `pullRequest.number`. Two PRs sharing the commit, an empty list, a mismatched list or an
     object-shaped list → `stale`.
   - **Every Tier K veto still runs.**
     - No unresolved Kody thread, outdated or not.
     - `completed_at` and `started_at` are GitHub timestamps.
     - `THREADS_FETCHED_AT` is at least 60 s after completion.
     - `ALL_COMMENTS` is well formed.
     - **No** Kody "could not be posted" comment exists anywhere on the PR. The success path
       counts only comments from the deciding run's window, because a newer *review*
       supersedes an older run. A skip reviews nothing, so on the waiver path an earlier run's
       unposted findings still veto.

2. **The waiver is not an ack.** Tier K prints the bare token `skipped-unlicensed`. It is never
   a SHA and never carries a tier suffix, not even under `ACK_EMIT_TIER=1`. Each reader handles
   it as follows:
   - **Worker Step 6.5.** `_ackpart` keeps the token and `_tierpart` maps it to `none`, so
     `RESULT_REVIEWER_ACKS` carries `kody-ai=skipped-unlicensed` and `RESULT_ACK_TIERS` carries
     `kody-ai=none`. The tier set stays `{A,B,C,D,E,K,none}`. A waived Kody normally posts no
     Source 2/3/4 artifact (Kodus notifies org owners off the PR), so its ledger entry is
     usually `kody-ai=0/0:none`.
   - **Waiting and clean.** The token is not `stale`, so the worker may return `clean`
     (Invariant 2), Invariant 1 does not count it as a reason to wait, and Codex's sole-stale
     re-trigger may fire.
   - **Invariant 3.** It inspects only SHA-shaped ack values, so it does not apply. Codex,
     CodeScene, required CI and every other source the worker triages are unchanged.
   - **Dispatcher.** It passes the token through on the clean path and on the wait-round
     refresh. The ADR 0058 Decision 7 bail on `kody-ai=none` is unchanged.
   - **Completion is the authority.** It recomputes `FRESH_ACKS` from its own ledger run and
     never trusts the worker's string. Its `STALE_BOTS` filter is now an exact allow-list for
     `kody-ai`: two fields, string compares, value exactly `$HEAD_SHA` or exactly
     `skipped-unlicensed`. Anything else blocks; before this ADR, only `stale` and `none` did.
   - **Completion's audit record.** When the value is `skipped-unlicensed`, completion:
     - prints that Kody did **not** review HEAD and that the waiver was applied;
     - records a `kody-unlicensed-skip-waived` event in the **main** repo's
       `bypass-log.jsonl` (the parent of the absolute `--git-common-dir`, never the ephemeral
       worktree). The state dir is sanitized as the dispatcher does. The write goes through
       the existing hardened writer `hooks/gate-scripts/lib/audit_append.py`, imported exactly
       as `pre-merge-gate.sh` imports it, which refuses symlinks and torn lines. Nothing under
       `hooks/` is edited.

     The record carries `event`, `gate: "pr-grind-completion"`, `pr`, the full `head_sha`,
     `author`, `reason`, `adr` and `ts`. If it cannot be written, completion blocks. It
     records the waiver **decision at a completion attempt**: later steps (the checks-green
     block, Shipping routing) can still stop the run, so it is not proof of merge.

3. **Nothing else moves.** There is no skip file, environment switch, config key or repo
   opt-in. ADR 0012's advisory downgrade still refuses `kody-ai`. The following are unchanged:
   - required status checks and branch protection;
   - `hooks/gate-scripts/**` (the pre-merge gate reads only the clean marker);
   - every other Busdriver gate.

4. **Capability marker `tier-k4`.** What Tier K accepts has changed, so the ADR 0058 Decision 8
   marker moves to `# ack-ledger-capability: tier-k4`. A busdriver branch cut before this change
   does not judge `kody-ai`: the loaded ledger does. An older ledger would read the waiver as
   `stale` (fail-closed) in any case.

## Alternatives

- **Assign a Kodus seat to `cursor[bot]`.** Supported upstream, and likely the cleaner fix: Kody
  would then review Cursor PRs normally through Tier K's `success` path. **Rejected for this
  task by operator decision (2026-11-13)**, because it introduces billing and account changes
  that are outside this task's scope. The rejection is about scope, not feasibility. The waiver
  does not compete with a seat: it fires only while Kody reports "User Not Licensed", so if a
  seat is assigned later it simply stops firing.
- **Emit a HEAD-ack with a new tier letter.** Rejected. Under the default output (no
  `ACK_EMIT_TIER`) it is a bare SHA, indistinguishable from a real review in every reader and
  in the audit trail.
- **`none` for `kody-ai`.** Rejected. ADR 0058 Decision 7 makes `kody-ai=none` an unrefreshed
  default that bails, and overloading it would blur the two.
- **A per-PR or per-repo skip file / opt-out.** Rejected by the operator: it covers every
  reason Kody might be absent, not this one.
- **Match the PR author by REST `user.login == "cursor[bot]"`.** Equivalent, since the `[bot]`
  suffix is reserved for Apps, but it needs another fetch at every site. The GraphQL author
  rides on the threads query that already exists.
- **Waive any `skipped` run on a `cursor[bot]` PR.** Rejected: merge-only and branch-mismatch
  skips have recoveries (ADR 0058 Decision 6), and waiving them would let a stale Kody state
  pass silently.

## Consequences

- **What still applies.** A Cursor-authored PR merges with no Kody review. Codex (when active),
  CodeScene threads, required CI and all Litmus/pr-grind invariants remain. The waiver is
  visible in completion output and in `bypass-log.jsonl`.
- **Amend recovery.** A message-only amend creates a new HEAD, and the predecessor's skip does
  not carry over. `kody-ai` reads `stale` until Kody posts its own run on the new HEAD. Kody
  does so on every push, and it skips again for the same author. If no run appears, the
  operator comments `@kody review --force`.
- **Residual: authorship is fixed at open.** GraphQL `pullRequest.author` is the opener. A
  later push to a Cursor-authored PR by a human or another agent is still waived, because Kody
  skips it for the same licensing reason. Commit author and committer are client-stamped, so
  they are not used to narrow this. Accepted for a single-operator setup.
- **Residual: vendor text.** The waiver keys on Kodus's literal title and summary. If Kodus
  rewords them, the waiver stops applying and the grind reads `stale` again (fail-closed).
- **Residual: the waiver trusts Kodus's own word.** The `skipped` conclusion and its text are
  written by the kody-ai App (pinned by slug and id). That is the same trust Tier K already
  places in that App's `success`.

## Revisit trigger

- A Kodus seat is assigned to `cursor[bot]`, or the summary text changes: drop the waiver, or
  re-pin it.
- Anyone other than the operator gains push access to Cursor branches: bind the waiver to the
  PR's commits as well (e.g. a GitHub-verified Cursor commit signature), not only to its opener.
- A second unlicensed bot author appears: extend the pinned author set in a new amendment. Do
  not generalise to "any Bot".
