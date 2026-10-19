# ADR 0058 — Kodus replaces Cubic, CodeRabbit and Greptile in pr-grind

**Status:** Proposed
**Date:** 2026-10-19
**Amends:** ADR 0047 (its three-bot registry), ADR 0035 (keep-set), ADR 0001 (tier set gains `K`)
**Related:** ADR 0027 (stranded clean reviews), ADR 0012 (advisory downgrade), ADR 0013 (Codex nudge)

## Context

pr-grind pushes a fix, waits for every registered bot to re-review HEAD, and
repeats. All three ack-gated bots are metered against exactly that loop
(operator report, 2026-10-18):

- **CodeRabbit:** 10 reviews/hour even on the advanced plan. Each push is a
  review against that limit, so a multi-round grind hits it; `ack-ledger.sh`
  already carries Case 1b heuristics just to survive the rate-limit state.
- **Cubic:** 40,000 lines/month, ultra review counts 3×. The cap is exceeded
  every month (ADR 0047 already measured Cubic over its limit for almost all of
  Aug 2026).
- **Greptile:** billed per review, so cost scales with grind rounds.

The operator connected **Kodus** (GitHub App `kody-ai`, login `kody-ai[bot]`)
with BYOK on the OpenCode Go API (`deepseek-v4.1-flash`) for both
`Dive-And-Dev` and `chris-yyau`. The operator selected OpenCode's Global region
(required by that model) and has run reviews of private `Dive-And-Dev` code
through it, accepting that data path. The operator chose to keep an
**executable** Kody gate in this change rather than run Kody ungated.

### Measured Kodus behaviour

| Run | Findings | Findings posted | `Kody Code Review` completed |
|---|---|---|---|
| jikdak#571 (clean lockfile) | 0 | — | ~25 s after trigger |
| jikdak#573 push 1 | 3 (+ summary) | 02:44:15–02:44:33 | 02:44:34 (1 s after) |
| jikdak#573 push 2 | 1 | 02:50:36 | 02:50:40 (4 s after) |
| jikdak#573 push 3 (clean) | 0 | — | 03:24:55 (68 s after start) |
| busdriver#800 (+1620 lines, manual trigger) | 3 | 16:53:54–16:54:00 | 16:54:27 (27 s after; 26 min after start) |

The margins between the last finding and completion were 1 s, 4 s and 27 s:
ordered every time, but tight — hence the settle window in Decision 2.
`ALL_CHECK_RUNS` is fetched for HEAD and, per `fetch-pr-state.sh`, may also
carry the check-runs of a content-identical predecessor commit (an amend with
an unchanged tree); Tier K treats those as HEAD's, since the reviewed code is
the same.

Other observed behaviour:

- Automatic review on PR open and on every push (jikdak); `@kody start-review`
  on demand. Automatic review on a `chris-yyau` repo is not yet observed.
- Every finding is an inline thread inside its own `COMMENTED` review with an
  **empty body**. When a finding is critical Kody also posts a
  `CHANGES_REQUESTED` summary whose body only links those threads (jikdak#573
  review 5561157270, verbatim):

  ```
  # Found critical issues please review the requested changes

  - [Off-by-one loop bound reads records[records.length] and throws on every call](https://github.com/Dive-And-Dev/jikdak/pull/573#discussion_r4305460618)
  ```
- Kody **resolves its own threads** when it re-reviews a push that fixed them.
- A clean HEAD gets **no review object, no `APPROVED`, no dismissal**, only a
  PR-summary issue comment edited in place to "No issues were found" (marker
  `<!-- kody-codereview-completed-… -->`, **no SHA**). Kody posts that comment
  at review start on every run, so every Kody run leaves at least one Source 4
  artifact.
- The `Kody Code Review` check-run is `in_progress` while reviewing and
  `completed success` **with or without findings**.
- busdriver#800 had 30 reviews on page 1 of `/reviews`; all three Kody reviews
  were on later pages.
- Cost: $0.004–$0.02 per PR review (OpenCode request log); one unexplained
  53-request background burst cost $0.11.

### Why no existing tier fits Kody

- **Tier A disposed branch** (`ack-ledger.sh:1683-1688`) acks HEAD when any of
  the login's threads is resolved or outdated. Kody resolves its own threads
  and pushes outdate them, so this would ack HEAD without a review of HEAD.
- **Tier B** only binds HEAD when Kody had findings; a clean HEAD has no review
  object, so the last Kody review strands on an older commit (ADR 0027/0047).
- **Tier C** has no SHA to read.
- **Tier D** acks a `success` check-run, which Kody reports with or without
  findings — the reason `greptile-apps` is excluded there.

What *is* HEAD-bound and terminal is the `Kody Code Review` check-run itself:
it is fetched for HEAD only (`commits/<HEAD>/check-runs`), stays
`in_progress` until the review finishes, and in every observed run Kody's
findings were visible before it completed. Tier A's live-thread check, which
already runs first for every login, turns any visible finding into `stale`.

## Decision

1. **Registry becomes `REGISTERED_ACK_BOTS=(kody-ai)`.** Cubic, CodeRabbit and
   Greptile are dropped. The registry stays non-empty, so no empty-array
   handling is needed. Codex stays gated separately via `RESULT_CODEX_ACK`.
   The ADR 0035 keep-set becomes **Codex + Kody**; the Bugbot and Devin drops
   stand for their original reasons.

2. **New Tier K in `scripts/ack-ledger.sh`, for `kody-ai` only.** It runs
   immediately after Tier A's live-thread check (`ack-ledger.sh:1193`, so an
   unresolved, non-outdated Kody thread is already `stale`) and before the
   non-Codex disposed-thread `else` (`:1683-1688`); Tier G sits inside the
   `chatgpt-codex-connector` block and is never reached by `kody-ai`. Tier K
   always exits:
   - Read `ALL_CHECK_RUNS` with `jq -rs` across all pages (as Tier D does)
     and keep check-runs with `app.slug == "kody-ai"` and
     `name == "Kody Code Review"`. Every fetch uses GitHub's default
     `filter=latest`, which returns only the most recent run per name, and
     `augment-equiv-acks.sh` adds a content-identical predecessor's run only
     when HEAD has none from that app — so normally one run decides. As a
     guard, if more than one survives, any non-`completed` one → `stale`,
     else the highest `id` decides.
   - The deciding run's `head_sha` must pass `acks_head` (as Tier D's does at
     `ack-ledger.sh:1738`), so a predecessor run counts only where the
     ledger's own HEAD-equivalence proof accepts it; otherwise `stale`.
   - Not `completed` (`queued`, `in_progress`, …) → `stale`. This does not
     depend on `started_at`, which is null while queued.
   - `completed` with conclusion `success` → continue to the settle check.
     Every other conclusion → `stale`, including `neutral` and `skipped`: a run
     that did not review HEAD is not a review of it, and Kody is compulsory.
     Kodus documents several skips (Code Review Flow, "When Kody Skips"): no new
     commits since the last run, "only merge commits with no effective
     changes" (exactly what `gh pr update-branch` produces), all changed files
     ignored, the file limit exceeded, invalid configuration, an unconfigured
     branch, and drafts when configured. The merge-only skip is the one
     pr-grind itself causes; its recovery is a forced Kody review of that HEAD
     (Decision 6), not accepting the skip. The others are repository or PR
     configuration problems, and a compulsory gate correctly stays `stale`
     until the operator fixes them.
   - `completed_at` and `THREADS_FETCHED_AT` are validated with the ledger's
     existing `ts_ok` before comparison.
   - **Settle window bound to the thread snapshot.** Every place that fills
     `ALL_THREADS` also records `THREADS_FETCHED_AT`, GitHub's own clock from
     `scripts/github-server-now.sh`, read immediately **before** the threads
     query. Tier K acks only if `THREADS_FETCHED_AT` is present and that run's
     `completed_at` is at least 60 s earlier, compared in `jq` with
     `--arg fetched "$THREADS_FETCHED_AT"` as
     `($fetched | fromdateiso8601) - (.completed_at | fromdateiso8601) >= 60`.
     Both values are whole-second `…Z` strings (`github-server-now.sh` prints
     that shape; GitHub's REST check-run times have no fractions), which is the
     form `fromdateiso8601` accepts; any other shape (including a null or
     fractional `completed_at`) fails `ts_ok` first. So the thread snapshot
     Tier A just checked was taken at least 60 s
     after Kody reported finishing, and every observed Kody finding was posted
     before that. Missing or unparsable timestamps → `stale`.
   - **`completed_at` is app-settable**: the Checks API lets the app that owns
     a check-run write its timestamps. It is written by Kodus, the
     reviewer, not by the gated PR author, and the measured runs show Kodus
     stamping the real completion time. Residual: a Kodus that reports
     `completed_at` earlier than its last finding could ack HEAD before that
     finding is visible. Accepted; see Revisit trigger.
   - All conditions hold → `emit_head_ack "$HEAD_SHA" K`.
   - No Kody check-run on HEAD → `stale`, whether or not Kody has other
     artifacts on the PR: **Kody is compulsory** (operator decision,
     2026-10-19). There is no opt-out marker, no config switch and no
     time-based grace; Tier K never returns `none`, and it reads no other Kody
     artifact.

     So a fresh PR waits for Kody however long after the push it was opened,
     a second clone behaves the same as the first, and a silent Kodus outage
     (no check-run, no comment) reads `stale` until `--max-wait` rather than
     passing. This differs on purpose from the removed bots, whose absence
     read `none`: with one registered bot, its absence must not open the
     gate.
   - A `jq` failure on any of these reads fails closed to `stale`
     (`num_or`-style defaults).
   - Kody never reaches Tiers B–E, G, the disposed-thread branch, Case 3 or
     the empty-review `none` return (`ack-ledger.sh:1913`): the Tier K block
     ends with an unconditional `stale` and `exit 0` after its own branches,
     so no Kody path falls through to a login-agnostic terminal. A test feeds
     Kody fixtures shaped like those terminals' inputs (a `skipped` Kody
     check-run with an empty-body `COMMENTED` Kody review; a `skipped` run with
     no review; a `success` run inside the settle window) and expects
     `stale`.

   Tier K is a HEAD-bound structured ack but is **not** bodyless: a Kody run
   with Kodus's default start/end messages leaves its Source 4 comment (the
   messages can be switched off in Kodus; that configuration is unsupported
   and fails closed at Invariant 3), so Invariant 3's `n_total >= 1` requirement
   applies unchanged and the D/E bodyless exemption is not extended to `K`.
   The documented tier set becomes `{A,B,C,D,E,K,none}` (SKILL.md Invariant 3
   and tag reference, `agents/pr-grinder.md` tag reference).

3. **Waiting and blocking reuse the existing machinery.** Because `kody-ai` is
   registered:
   - A Kody review in progress, or an open Kody thread, is `stale`, so a
     no-commit wait-round is legal under Invariant 1 and counts against
     `--max-wait` (default 8 rounds, each up to the Phase 1 900 s watch plus
     30 s grace — enough for the 26-minute busdriver#800 review). The round
     whose watch sees Kody complete usually ends inside the 60 s settle window,
     so the worker reports `kody-ai=stale` and the dispatcher's wait-round
     refresh, taken later with a new `THREADS_FETCHED_AT`, may already ack.
   - **Invariant 1 is amended for that crossing.** Today the wait-round refresh
     overwrites `RESULT_REVIEWER_ACKS` / `RESULT_CODEX_ACK` before Invariant 1,
     so a refresh with no `stale` left reads as "no progress" and bails. The
     dispatcher now keeps the worker's own values as `WORKER_REVIEWER_ACKS` /
     `WORKER_CODEX_ACK` and evaluates Invariant 1 against those: the
     invariant exists to catch a worker that emits `needs_more` with no reason
     to wait, and the worker's values are what show that. A wait-round whose
     refresh has no `stale` left is dispatched again as a normal round; the
     next worker's own Step 6.5 pass sees the acks and returns `clean`, and
     Invariants 2 and 3 apply to that envelope as usual. This is not specific
     to Kody: any bot that finishes between the worker's snapshot and the
     refresh hit the same bail before.
   - Invariant 2 refuses `clean` while Kody is `stale`.
   - Completion's `FRESH_ACKS` re-runs `ack-ledger.sh kody-ai` on the final
     fetch (and after the Codex grace), so `STALE_BOTS` blocks the clean
     marker on a Kody finding that appeared late. No new completion helper.
   - ADR 0012's advisory downgrade does **not** apply to `kody-ai`.
     `advisory-stale-downgrade.sh` only treats Codex as having a non-thread
     engagement signal, so it could release Kody while its review is still
     running. It refuses `kody-ai` by login, so an exhausted Kody wait bails
     instead of downgrading (busdriver is opted in to downgrades, so this
     matters here).

4. **Worker contract for Kody** (`agents/pr-grinder.md`):
   - Kody findings are triaged through **Source 2 threads**. Kody review bodies
     are informational: per-finding reviews are empty and the summary only
     links threads. Residual: a finding Kody put only in a review body would be
     missed; none was observed. The worker's Source 3 rule that a
     `CHANGES_REQUESTED` stays live until `APPROVED` does not apply to
     `kody-ai`.
   - Fixed threads are resolved by Kody on its re-review; the worker does not
     resolve them. Dismissed findings use the existing out-of-scope flow, which
     already replies and calls `resolveReviewThread`, inside Invariant 4's caps.
     As for every other bot, Tier A counts only unresolved **non-outdated**
     threads: a thread whose lines the fix changed is outdated and no longer
     blocks, whether or not Kody resolves it; this relies on Kody's review of
     the new HEAD raising a new thread if the fix was wrong (measured once:
     jikdak#573 push 2 raised a new finding on the fixed function; whether
     Kodus de-duplicates across runs is not documented, so the rollout probe
     checks it). An unresolved thread on lines
     the push did not touch keeps the ack `stale` until Kody resolves it or the
     worker dismisses it.
   - Source 3 `/reviews` fetch gains `--paginate` (busdriver#800 shows why).
   - Ledger: `kody-ai` replaces the three removed bots; the known-set becomes
     `kody-ai`, `codescene-delta-analysis`, `chatgpt-codex-connector` (5 → 3).
     Kody's entry uses the existing units and counts its Source 4 comment, so
     a clean Kody run is `kody-ai=0/1:<disposition>`.

5. **The three bots are removed completely from pr-grind's contract** — the
   registry, ledger, defaults, worked examples, and every mention that
   describes current behaviour in `skills/`, `agents/` and `docs/` (including
   both `[update-merge]` copies), plus the status text of the ADRs listed
   below (operator decision, 2026-10-19). Earlier ADR bodies keep their
   history. The small login-keyed `greptile-apps` Tier-D exclusion is
   deleted with its test. The **CodeRabbit-specific engine** in `scripts/` —
   Tier E's status-context mapping (`ack-ledger.sh`,
   `advisory-downgrade-revalidate.sh`, `augment-equiv-acks.sh`), the Case 1b
   rate-limit-notice detection, the TypeSafe union classifier and
   `typesafe-ack-eval.sh`, and the cubic merge-commit `skipped` handling in
   Case 3 — is no longer reached by any registered login (Tier K exits
   before it for `kody-ai`; Codex has its own tiers) and is removed in a
   **separate follow-up PR** (a GitHub issue is filed with this one), because
   it is several hundred lines with its own tests. Historical comments inside the
   gate-integrity-locked `hooks/gate-scripts/**` that cite these bots as
   incident examples are left as history. Tiers A–G for other logins (Codex)
   are unchanged.

6. **Merge-only HEADs get an explicit Kody review request.** Because Kody
   skips a merge commit with no effective changes and Tier K refuses a skip:
   - Both copies of `references/completion.md`'s `[update-merge]` option drop
     the cubic Case 3 note **and** the sentence that makes a stranded
     registered bot eligible for an ADR 0012 stale→none downgrade (that
     release is refused for `kody-ai`, Decision 3). They say instead: after
     `gh pr update-branch`, post
     `@kody review --force` on the PR so Kody reviews the merge HEAD. Kodus
     documents `--force` as the skip override and warns that a plain
     `@kody start-review` "will skip again if there are no new commits";
     without it `kody-ai` stays `stale` on the merge HEAD and the grind bails
     at `--max-wait`.
   - The `--max-wait` BAIL in `skills/pr-grind/SKILL.md` (the
     `"max-wait iterations … latest stale: <STALE_AT_BAIL>"` reason) gains a
     clause: when `kody-ai` is in `STALE_AT_BAIL`, the reason also prints
     "kody-ai stale: if HEAD is a merge-only commit, comment
     `@kody review --force`; otherwise check the Kody check-run and the Kodus
     dashboard (app installed, branch configured, file limit)".
   - The comment is an operator action, like choosing `[update-merge]` itself;
     pr-grind does not post it automatically.
   - The rollout probe covers it (see below).

7. **Dispatcher defence in depth.** Tier K never emits `none`, so a `clean`
   worker envelope whose `RESULT_REVIEWER_ACKS` carries `kody-ai=none` can only
   be an unrefreshed default. The dispatcher's clean path bails on that
   `RESULT_REVIEWER_ACKS` value, and completion's `STALE_BOTS` filter
   (`completion.md:519-522`) treats `kody-ai=none` in `FRESH_ACKS` as
   blocking, the same as `stale`. `RESULT_ACK_TIERS` is only an informational
   tag (SKILL.md tag reference) and is not checked.

8. **An older ledger never judges `kody-ai`.** `ack-ledger.sh:183-194`
   re-executes the PR checkout's own `scripts/ack-ledger.sh` on any
   `chris-yyau/busdriver` checkout. After this change merges, a busdriver PR
   branched earlier would run a ledger without Tier K, where `kody-ai` falls
   through to the disposed-thread `A` ack — the fail-open "Why no existing tier
   fits" rules out. The self-resolve condition therefore gains one clause:
   when `$1` is `kody-ai`, it re-executes the checkout copy only if that copy
   contains the capability comment `# ack-ledger-capability: tier-k`, a
   whole line added beside Tier K for this purpose (a fixed comment, so a
   reformatted `emit_head_ack` call cannot break detection);
   otherwise the loaded ledger, which has Tier K, decides. Only the loaded
   ledger's code runs this check, so it covers every older branch from the
   day this merges.

Mechanical changes (must move together):

- `scripts/ack-ledger.sh`: Tier K branch; header caller contract names
  `THREADS_FETCHED_AT`; the Decision 8 self-resolve clause.
- Every `ALL_THREADS` fetch site — `scripts/fetch-pr-state.sh` (the `_tmp`
  GraphQL call), the worker's Step 6.5 fetch (`agents/pr-grinder.md:635`, plus
  its export list), and `skills/pr-grind/references/completion.md` (initial
  fetch and post-Codex-grace refresh): set `THREADS_FETCHED_AT` (via
  `github-server-now.sh`, empty on failure) on the line immediately before the
  GraphQL call starts, and export it with the other state, including both
  dispatcher export lists (`dispatcher-commit-block.sh:336` and `:1438`). Every save and
  restore of completion's Codex-grace snapshot (`CODEX_LG_*`, including the
  initial save, the per-poll save and the restore) carries
  `THREADS_FETCHED_AT` together with `CODEX_LG_THREADS`.
- `scripts/ack-ledger.sh`: delete the `greptile-apps` Tier-D exclusion and
  its comment; `tests/test-ack-ledger-content-identity.sh` case 11 and its
  control go with it.
- `scripts/advisory-stale-downgrade.sh`: refuse `kody-ai`.
- `scripts/dispatcher-commit-block.sh`: registry and comment; clean-path
  `RESULT_ACK_TIERS` fallback tag `kody-ai=none`; clean-path bail when
  `RESULT_REVIEWER_ACKS` contains `kody-ai=none` (Decision 7).
- `agents/pr-grinder.md`: default `ACKS` / `ACK_TIERS` = `kody-ai=none`;
  default `BOT_LEDGER`; Step 2.5 registry table and the Codex note beside it
  (`:266`); Source 3 `--paginate`; Step 2.6 and triage rows for Kody
  (Decision 4), citing ADR 0058; tier reference gains `K`; `_cub/_cod/_grp`
  and worked examples.
- `skills/pr-grind/references/completion.md`: `FRESH_ACKS` (three call sites)
  = `kody-ai` + `chatgpt-codex-connector`; `STALE_BOTS` also blocks on
  `kody-ai=none` (Decision 7); checklist items 3 and 7; both
  `[update-merge]` copies (`:738` and `:803`, under each
  `AUDIT_WORKFLOW_PRESENT` value) and the re-invoke note at `:852`
  (Decision 6).
- `skills/pr-grind/SKILL.md`: registry lists and examples; Invariant 3 known
  set 5 → 3 and tier set; Invariant 1 evaluated on `WORKER_REVIEWER_ACKS` /
  `WORKER_CODEX_ACK` (Decision 3); the `--max-wait` BAIL reason's `kody-ai` hint
  (Decision 6); the ADR 0012 `CANDIDATES` assembly excludes
  `kody-ai`; Kody described as registered.
- Tests:
  - `tests/test-ack-ledger-kody.sh` (new): fixtures shaped like real
    `gh api --paginate` output for each Tier K row, with `THREADS_FETCHED_AT`
    injected — success completed ≥ 60 s before the snapshot → `<sha>:K`;
    completed < 60 s before the
    snapshot → `stale`; exactly 60 s → `<sha>:K` and 59 s → `stale`;
    `completed_at` null or fractional → `stale`; a content-identical
    predecessor's success run that passes `acks_head` → `<sha>:K`;
    `THREADS_FETCHED_AT` empty or malformed → `stale`;
    `in_progress`, `queued` (with `started_at: null`) → `stale`; `failure` /
    `cancelled` / `timed_out` → `stale`; an older run still `in_progress`
    beside a newer success → `stale`; a newer queued run beside an older
    success → `stale`; open non-outdated Kody thread
    with a completed check-run → `stale` (Tier A first); resolved/outdated
    Kody threads only, no check-run, Kody issue comment present → `stale`
    (never a disposed-thread `A`); a deciding run whose `head_sha` fails
    `acks_head` → `stale`;
    a check-run from another app named `Kody Code Review` → ignored;
    malformed `ALL_CHECK_RUNS` → `stale`; `FETCH_OK=0` → `stale`.
  - `tests/test-advisory-stale-downgrade.sh`: `kody-ai` is never downgraded.
  - Decision 8 self-resolve: with a fake busdriver checkout whose
    `scripts/ack-ledger.sh` lacks the capability comment, `ack-ledger.sh kody-ai`
    runs the loaded ledger (Tier K result); with the marker present it
    re-executes the checkout copy; `chatgpt-codex-connector` self-resolves as
    before.
  - `tests/test-dispatcher-commit-block.sh`: a `clean` envelope with
    `kody-ai=none` bails.
  - `tests/test-pr-grind-codex-wiring.sh`: anchors that the SKILL.md max-wait
    BAIL reason and both `completion.md` `[update-merge]` copies carry
    `@kody review --force` and that neither copy still offers the ADR 0012
    downgrade for a stranded bot; that Invariant 1 names
    `WORKER_REVIEWER_ACKS` and `WORKER_CODEX_ACK`; and that the `STALE_BOTS`
    awk blocks `kody-ai=none` (run against sample `FRESH_ACKS`).
  - A stubbed check runs `scripts/fetch-pr-state.sh` with `gh` stubbed and
    asserts `THREADS_FETCHED_AT` is exported to the ledger subprocess.
  - An anchor test that enumerates every `gh api graphql` reviewThreads fetch
    feeding `ALL_THREADS` in `scripts/`, `agents/` and `skills/` and asserts a
    `THREADS_FETCHED_AT=` assignment on the line before the call starts (not
    before the later `ALL_THREADS="$_tmp"` copy), and that every line
    assigning `CODEX_LG_THREADS` or restoring `ALL_THREADS` from it also
    assigns the matching timestamp. A new thread fetch or snapshot site
    without the stamp fails this test.
  - Tier K cases also cover: a two-page `ALL_CHECK_RUNS` with the Kody run on
    page 2; `neutral` / `skipped` / `timed_out` / `action_required` /
    `stale` conclusions → `stale`; no check-run and no Kody artifact → `stale` (Tier K never emits
    `none`).
  - The Source 3 pagination anchor targets the worker's **Step 2** Source 3
    fetch (`pr-grinder.md:224`) by its surrounding comment, not any
    `/reviews` call in the file (the Step 6.5 one already paginates).
  - `tests/test-dispatcher-commit-block.sh` and
    `tests/test-pr-grind-codex-wiring.sh`: fixtures, exact-match anchors,
    `FRESH_ACKS` / `POSTWAIT_LEDGER` follow the new registry and ledger;
    anchor that Source 3 uses `--paginate`.
- `docs/degraded-modes.md`: Cubic/CodeRabbit/Greptile rows marked removed, and
  the Bugbot row's reference to them as gated peers updated;
  Kodus row (Tier K; slow large-PR reviews consume wait-rounds; Kodus outage
  → `stale` until `--max-wait`).
- Status text of ADR 0047, ADR 0035, ADR 0027, ADR 0012 and ADR 0001 points here.

**Rollout check (before merge):** one seeded probe PR on
`chris-yyau/busdriver`, **based on this branch** (so the self-resolved ledger
in its checkout has Tier K) and opened without `@kody`, is ground end to end
with the plugin loaded from this branch's worktree (the worker loads the
ledger from the plugin root, `pr-grinder.md:747`, as do completion and the
dispatcher), not from the installed release. Kody must
review it automatically; with an open Kody finding the grind must wait or
block; after the fix push and Kody's automatic re-review it must reach `clean`
with `kody-ai=<sha>` at tier `K`. The probe also: (a) pushes a change to a
finding's lines that does not fix it, and Kody must raise it again; (b) runs
`gh pr update-branch`, waits until the unforced merge-only Kody check-run has
been `completed` for at least 60 s (or until no run appears for 10 minutes),
then records its status and conclusion and that the ledger reads `stale` (the
payload is saved as a test fixture) — only after that does it post
`@kody review --force` and check that it gets the merge HEAD to
`kody-ai=<sha>` at `K`. If the settled unforced read is a Tier K ack, a skip
reports `success`, Tier K's premise is broken, and this change does not merge
until it is amended and re-reviewed. Merge is not allowed until this case has
produced a Tier K ack on a merge HEAD.

## Alternatives

- **Kody ungated (ledger-only), executable gate later.** Offered; the operator
  chose to gate now. It would leave Kody's findings protected by the worker's
  prose clean rule only.
- **Kody ungated plus a separate completion-only thread check.** Rejected after
  four review rounds: without a registered ack, "Kody still reviewing" has no
  legal wait state (Invariant 1) and the worker cannot cite fix commits it does
  not make. Registering Kody with its own tier reuses the waiting, blocking and
  re-check machinery instead.
- **Reuse Tier D for Kody.** Rejected: a bodyless D ack would claim the D/E
  exemption and the check-run is `success` with findings.
- **Keep the three bots on `chris-yyau`.** Rejected by the operator: the
  metering problem is the same on both accounts.

## Consequences

- **Publication-race residual.** Tier K trusts that every Kody finding is
  posted before its check-run completes, and so is in a thread snapshot taken
  60 s later. Observed in every run; not a vendor guarantee. A finding posted
  after completion is caught only if it lands before completion's final
  thread snapshot; otherwise it is merged past. This is the risk `ack-ledger.sh` declines for
  Greptile's check-run; it is accepted here because Kody's check-run, unlike
  Greptile's, was observed to stay `in_progress` until its findings were
  posted.
- **Slow reviews cost wait-rounds.** busdriver#800 took 26 minutes. Large PRs
  may exhaust `--max-wait`; the bail is visible and re-runnable.
- **Kodus outage or failed review** → `stale` until `--max-wait`, then bail.
  No downgrade (Decision 3). Fail-closed.
- **Every repo must have Kodus.** A repo without it stalls each grind until
  `--max-wait` and bails naming `kody-ai`; the fix is installing Kodus there.
  Both operator accounts have Kodus connected, and busdriver is
  single-operator, so no third-party grind is affected.
- **Merge precondition:** the rollout probe PR is
  opened on `chris-yyau/busdriver` itself (the account where only a manual
  trigger has been observed) and must show Kody reviewing automatically on
  open and on a fix push. If it does not, auto-review is fixed in the Kodus
  dashboard before this change merges.
- If Kody was triggered once manually but does not auto-review later pushes,
  each later HEAD reads `stale` (Kody has artifacts on the PR) until
  `--max-wait`; the bail names `kody-ai`, so the cause is visible.
- **Uninstall first.** The operator uninstalls Cubic, CodeRabbit and Greptile on
  both accounts before this merges. Like Bugbot under ADR 0047, they then join
  the dropped bots whose findings "are not enumerated"
  (`agents/pr-grinder.md` triage row): an unresolved finding they left on a PR
  already open at that point can be merged past. Uninstalling does not close
  those threads; the operator reviews open PRs they touched before grinding
  them.
- Kody's leftover `CHANGES_REQUESTED` would block a repo with a required-review
  rule; busdriver and jikdak have none.
- **Kodus configuration is part of the gate.** Disabling Kody's start/end
  messages, enabling auto-pause, or excluding a branch makes grinds bail
  (`stale` or Invariant 3) rather than pass. The bail names `kody-ai`.
- Data path: review context for private repos goes to OpenCode (Global region)
  under the operator's acceptance above.

## Revisit trigger

- Any observed Kody finding that became visible **after** its check-run had been
  `completed` for 60 s: widen the settle window or demote Kody to ungated.
- Kody completing with `neutral` / `skipped` on PRs other than merge-only
  HEADs, or `@kody review --force` not overriding the merge skip: decide
  between an automatic nudge and a new ADR making those conclusions
  non-gating (which must also revisit Decision 7).
- Any Kody run whose `completed_at` precedes the `created_at` of one of its own
  findings: the settle window's premise is broken; demote Kody to ungated
  until it is redesigned.
- Kody not re-raising an unfixed finding after its lines changed: add a
  check that blocks on outdated Kody threads.
- Kody posting a finding only in a review body: route Kody Source 3 bodies back
  into triage.
- Kody failing to resolve fixed threads often enough to exhaust `--max-wait`:
  add a worker resolution step tied to the dispatcher's pushed SHA.
- Re-add any removed bot only if its plan stops metering per review / per line /
  per hour in a way a grind loop exhausts.

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
