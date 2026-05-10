---
name: pr-grind
description: >
  Post-PR feedback loop — reads CI failures and reviewer comments, fixes issues, pushes,
  and repeats until the PR is clean. Use after creating a PR or on any existing PR that
  needs attention.
origin: custom
---

# PR Grind — Iterative PR Feedback Resolution

## When to Use

- After `gh pr create` succeeds and you want to stay on it until merge-ready
- When CI is failing on an open PR
- When reviewer comments need addressing
- Manually: `/pr-grind` or `/pr-grind 123` or `/pr-grind https://github.com/owner/repo/pull/123`

**Announce at start:** "Grinding PR #N — will iterate until CI is green and comments are resolved, then merge." (Drop "then merge" if `--no-merge`.)

## Authority Hierarchy

**Merge gate (authoritative — all must be satisfied):**
- Required status checks: green (REQUIRED set; advisory checks like CodeScene excluded)
- Actionable findings on YOUR PR's changed lines: addressed (fix or justified reply)
- PR title/body: conventional commit + scope

**Bounded-wait advisory (best-effort, capped by `--max-wait`):**
- AI reviewer acks (Greptile, CodeRabbit, Cubic, Copilot, etc.)

**Best-effort (low priority, addressed if fix budget allows — counts against `--max-fix`, not `--max-wait`):**
- Style/nit findings: typically fixed because the effort is low

**Invariant:** required status checks are the merge authority. AI reviewer acks are bounded-wait advisory signals — apps rate-limit, freeze, or fail; `--max-wait` is the backstop. On exhaustion the loop **bails to the operator** (does NOT silently merge AND does NOT wait forever). Never wait indefinitely for any single reviewer app. The infra-error downgrade in `scripts/ack-ledger.sh` (`ever_approved=0` defense) handles the specific case of a frozen review that the bot can't self-recover from; `--max-wait` is the broader safety net for slow-bot scenarios outside that pattern.

**Why:** helmet PR #35 stuck for a full session because a frozen Copilot review couldn't be classified by the pre-v1.30.1 ack ledger (introduced v1.29.1, PR #70). v1.30.1 added the body-text infra-error downgrade with the `ever_approved=0` admin-bypass guard (PR #77, three sub-commits); v1.31 extracted the algorithm into `scripts/ack-ledger.sh` for single-source maintenance + added a fail-CLOSED `|| echo stale` guard at the new call sites (PR #79); v1.33 added the `--max-wait` budget (PR #84). Codifying the principle prevents regression — a future "tighten the gate" PR must not reintroduce unbounded waits, must not silently merge past stale acks, and must not treat reviewer acks as co-equal with required checks.

## Architecture: Dispatcher + Per-Round Worker

This skill is a **thin Opus dispatcher**. The actual round work runs in a fresh `pr-grinder` subagent on Sonnet, dispatched once per round. This:

- Cuts cost ~5× by running mechanical fix work on Sonnet
- Flattens conversation context — each round starts with O(1) tokens instead of O(N) accumulation across rounds
- Keeps Opus available for orchestration: triage of subagent results, bail handling, merge decisions, and skip-file protocol

**Override with `--opus`:** Run the loop inline in the parent Opus context (skips dispatch). Use when a PR has known nuance — multi-file architectural fixes, subtle review threads, etc.

## Anti-Patterns (DO NOT)

| Trap | Why it breaks the loop |
|------|----------------------|
| Looping rounds inside the subagent | Subagent contract is one round per dispatch. The dispatcher owns the loop. |
| Collecting feedback while checks are still pending | You'll miss reviewer findings, fix a partial set, push, and trigger a second review cycle unnecessarily |
| Declaring "Round complete" after push without waiting | The push triggers a new review cycle — you must wait for IT to finish before declaring done |
| Only waiting for CI (build/lint/test), ignoring reviewer bots | CodeRabbit, Greptile, Cubic are checks too — `gh pr checks` shows them as pending |
| Fixing pre-existing issues flagged by automated reviewers | Scope creep — only fix issues in YOUR changed code |
| Enabling GitHub auto-merge before pr-grind completes | The PR merges as soon as CI passes — before reviewer comments are addressed. pr-grind merges by default after all checks pass and comments are addressed. |
| Giving compound "grind then merge" instructions | Agent optimizes for merge as terminal goal, skipping CI wait. Just invoke `/pr-grind` — merge is the default. |
| Declaring PR clean without verifying check results | Checks completing (pass/fail/skip) ≠ checks passing — always verify status before writing the clean marker |
| Recovering inline when worker bailed because the fix would rewrite published git history | Recovery-via-inline is for *tooling friction* the worker physically can't traverse (litmus iteration without slash-command access). History-rewrite bails are *judgment friction* — the worker physically can rewrite history, but force-pushing invalidates SHAs that downstream consumers (review-thread anchors, ack ledger, claude-mem, other clones) may reference. The worker emits `RESULT_BAIL_CATEGORY: judgment` for this trigger; recovery eligibility check (d) gates on `category=tooling` precisely so this case real-bails to the operator. Do NOT widen the allowlist to include `judgment` — the carve-out boundary is the load-bearing safety rail. |

## Safety Rails

- **Max iterations:** Two independent budgets — **fix-rounds** (default 5, override with `--max-fix N`) cap how many commits the worker can push; **wait-rounds** (default 8, override with `--max-wait N`) cap how many polling rounds spent waiting for slow bots to ack HEAD. A round is classified as a *fix round* when `RESULT_COMMIT_SHA != "none"` and as a *wait round* otherwise. Bail when EITHER counter exhausts its budget. Both `--max-fix` and `--max-wait` must be `>= 1` — there is no "zero means unlimited" or "zero disables this class" form; if you want a larger budget, pass a larger number. The legacy `--max N` flag is accepted as a deprecated alias that sets both budgets to N (emits a deprecation warning). The split exists because under the old unified `--max`, every wait-round consumed a fix slot — so a PR with 3 fix iterations + 4 slow-bot polls would exhaust at MAX=5 even though only 3 fixes happened.
- **Autonomous by default:** Grinds without pausing between rounds (override with `--interactive` for human checkpoints)
- **Merges by default:** After grinding clean, pr-grind merges the PR. Pass `--no-merge` to skip the merge and just declare "Ready for merge". This is NOT GitHub auto-merge — pr-grind merges *after* all checks pass and all comments are addressed, inside its own control flow.
- **Bail triggers:** Stop immediately and clean up worktree if:
  - A comment is a design/scope question (not a code fix)
  - CI fails on an unrelated flaky test 3 times in a row
  - The fix would require architectural changes
  - The fix would require rewriting published git history (force-push, `git commit --amend` on a pushed SHA, `git filter-branch`, interactive rebase on pushed commits)
  - Max fix-rounds reached (worker pushed `MAX_FIX` commits without converging clean)
  - Max wait-rounds reached (slow bot(s) never acked HEAD within `MAX_WAIT` polling rounds)
  - **On any bail:** if Step 0 created an ephemeral worktree, `cd` back and `git worktree remove "../pr-grind-<PR_NUMBER>" --force 2>/dev/null || true` before exiting. Skip when `NO_WORKTREE=1` — i.e. either `--no-worktree` was passed OR Step 0's auto-fallback engaged because the branch was already checked out. The `|| true` keeps cleanup idempotent if the worktree was already removed.
- **Recovery-via-inline (capped at 1 per invocation):** When the worker bails for a *tooling-friction* reason (litmus blocked, pre-commit gate fired, subagent slash-command limitation) AND left inflight working-tree changes, the dispatcher takes over inline — runs the litmus iteration the subagent context can't, commits, pushes, and returns to the loop. **This is strictly for tooling friction, never for judgment friction:** design/scope questions, architectural concerns, env auth errors, history-rewriting fixes (commitlint on a pushed commit, large-diff splits — see worker Bail Triggers), and budget exhaustion all bail to the user as before. Cap is hard at 1 per pr-grind invocation — two consecutive worker bails in the same run = real bail, no matter how clean the inflight state. The cap exists so "dispatcher always rescues" can't mask a chronic worker bug over time. Override with `--no-recovery-inline` to disable entirely.
- **Out-of-scope-acknowledged discipline rails:** the worker can dismiss a finding on YOUR PR's changed lines with one of 6 enumerated reasons (`schema-refactor`, `external-research`, `follow-up-deferred`, `cross-cutting-style`, `pre-existing-on-touched-line`, `false-positive`) — see `agents/pr-grinder.md` Step 3. Three rails bound the carve-out: (a) worker per-round cap of ≤3 dismissals, self-enforced; (b) dispatcher cumulative cap of ≤5 dismissals across the whole grind (Invariant 4); (c) dispatcher cumulative cap of ≤3 follow-up issues spawned (Invariant 4). Hitting either dispatcher cap BAILs with `RESULT_BAIL_CATEGORY=judgment` regardless of round status. The default is FIX — dismissal is the carve-out. The rails exist precisely so workers can't relabel tedious-but-real findings as out-of-scope to "ship faster," leaving real bugs tracked-but-unaddressed in spawned follow-up issues.

## The Dispatcher Loop

```text
START
  ├── Resolve PR # (arg, current branch, or ask user)
  ├── Step 0: Create ephemeral worktree
  ├── Resolve budgets (with deprecation handling for legacy --max):
  │     If BOTH `--max` and either `--max-fix`/`--max-wait` were passed →
  │       BAIL with reason "conflicting flags: --max cannot be combined with --max-fix or --max-wait"
  │       (the alias contract is "set both to N"; combining with explicit budgets is ambiguous).
  │     If `--max N` was passed (and neither `--max-fix` nor `--max-wait`):
  │       MAX_FIX  = N
  │       MAX_WAIT = N
  │       emit "⚠️  --max is deprecated; use --max-fix and --max-wait. Note: legacy --max=N capped TOTAL rounds at N; the alias allows up to 2N rounds (N fix + N wait)."
  │     Otherwise:
  │       MAX_FIX  = --max-fix N value (default 5)
  │       MAX_WAIT = --max-wait N value (default 8)
  │     Validate budgets after resolution:
  │       If MAX_FIX < 1 or MAX_WAIT < 1 →
  │         BAIL with reason "invalid budget: --max-fix and --max-wait must be positive integers (>= 1)"
  │     # The lower bound is 1, not 0. A grind with budget 0 has no useful
  │     # semantics: the dispatcher would either bail before doing any work
  │     # (if zero meant "no rounds") or run forever (if zero meant "unlimited"),
  │     # neither of which a sensible operator wants. Reject at the boundary.
  └── Initialize: PRIOR_COMMIT_SHA=none, PRIOR_ATTEMPTS=[],
                   fix_round=0, wait_round=0,
                   round_number=0,
                   recovery_inline_used=0,
                   # recovery_inline_used is the cap counter for the
                   # RECOVERY_INLINE carve-out (Bug 2). Hard cap: 1 per
                   # pr-grind invocation. Reset on each invocation, never
                   # persisted across invocations — two consecutive worker
                   # bails in the same run = real bail, no second rescue.
                   # round_number is pre-incremented at the TOP of each loop
                   # iteration (before dispatch), so the first dispatch receives
                   # ROUND=1, the second ROUND=2, etc. It is the N in
                   # "ROUND=<N>" and "Round N" in PRIOR_ATTEMPTS template strings.
                   total_scope_skipped=0,
                   total_issues_spawned=0,
                   # total_scope_skipped accumulates this-round contributions
                   # parsed out of every `scope-skipped:<reason>:<count>`
                   # segment in RESULT_BOT_LEDGER (segments are `+`-joined
                   # within a disposition; outer entry split is `,`).
                   # total_issues_spawned accumulates the comma-count of
                   # RESULT_ISSUES_SPAWNED ("none" → 0). Both gate Invariant 4
                   # (discipline rails — cumulative caps of 5 dismissals and
                   # 3 spawned issues per grind). Reset on each invocation,
                   # never persisted across invocations or surfaced in
                   # PRIOR_ATTEMPTS — the worker doesn't need to see them.
                   PRIOR_REVIEWER_ACKS="greptile-apps=none,cubic-dev-ai=none,coderabbitai=none,copilot-pull-request-reviewer=none"

LOOP (terminates when fix_round >= MAX_FIX OR wait_round >= MAX_WAIT):
  │
  ├── round_number += 1   # pre-increment so ROUND=<N> is 1-indexed at dispatch time
  │
  ├── Decide model:
  │     --opus, --interactive,
  │       --ci-only, --comments-only → run inline (Steps 1–7 below)
  │     default                       → dispatch pr-grinder subagent
  │
  │   (--ci-only and --comments-only force inline because they need
  │   Step 2's per-source branching; the subagent contract collects
  │   all sources unconditionally and the round-isolated dispatch
  │   doesn't carry per-flag suppression. Until those are wired into
  │   the worker, the inline path is the honest place for them.)
  │
  ├── Dispatch (default path):
  │     Agent(subagent_type="pr-grinder", prompt=<context block>)
  │     ↳ Subagent does ONE round (Steps 1–6.5), returns RESULT_* tags
  │
  ├── Parse subagent output (extract tags only — control flow is sequential):
  │     The status arrows below describe each round's EVENTUAL routing
  │     after all the steps in this loop body have run; control does NOT
  │     transfer immediately on parse. Counter updates (next step), the
  │     recovery-via-inline check (only on bail), and Invariant checks
  │     1-4 (on needs_more AND clean) all run BEFORE the status decides
  │     where to jump. Without this ordering, Invariant 4 would never
  │     fire on `clean` rounds where the worker dismissed findings
  │     before declaring clean — exactly the failure mode the rails
  │     exist to catch.
  │
  │     RESULT_STATUS=clean       → eventually: invariants pass, go to COMPLETION
  │     RESULT_STATUS=bail        → eventually: recovery-via-inline check;
  │                                  if eligible AND not exhausted, go to RECOVERY_INLINE;
  │                                  otherwise break loop, go to BAIL
  │     RESULT_STATUS=needs_more  → eventually: invariants pass, classify, update state, continue
  │
  ├── Update discipline-rail counters (runs on EVERY status, including bail/clean):
  │     # Out-of-scope-acknowledged accumulator. The worker may have dismissed
  │     # findings even on rounds it ultimately bails or marks clean; those
  │     # dismissals count toward the cumulative cap regardless of round
  │     # status. Updating here (before the bail/recovery branch and before
  │     # invariant checks) ensures Invariant 4 sees a fresh total.
  │     scope_skipped_this_round = sum of every integer N matched by the
  │                                regex `scope-skipped:[a-z-]+:(\d+)` across
  │                                ALL bot-ledger entries this round.
  │                                Segments inside a single disposition are
  │                                `+`-joined; the entry split (which the
  │                                regex match honors implicitly) is `,`.
  │                                A disposition with no segments contributes 0.
  │     total_scope_skipped += scope_skipped_this_round
  │     issues_spawned_this_round = (RESULT_ISSUES_SPAWNED missing
  │                                   OR == "none") ? 0
  │                                  : count of comma-separated tokens.
  │     total_issues_spawned += issues_spawned_this_round
  │     # Missing-tag handling matters for the in-flight upgrade case: a
  │     # worker on the old contract never emitted RESULT_ISSUES_SPAWNED,
  │     # and the dispatcher must treat that as zero contribution rather
  │     # than bailing "subagent output unparseable". The protocol is
  │     # ADDITIVE — old workers operate under old semantics for the rest
  │     # of their grind (Invariant 4 simply doesn't enforce, bounded by
  │     # the worker's per-round cap of ≤3); new workers opt into
  │     # Invariant 4 by emitting the new tags. Same reasoning applies to
  │     # `scope-skipped:*:*` segments — old workers never produced them,
  │     # so the regex match returns 0 contributions, which is correct.
  │     # The two contributions ARE related (every spawn is also a skip
  │     # under one of the spawn-eligible reasons), but tracked separately
  │     # because skips and spawns have different caps (5 vs 3) and the
  │     # worker decides per-finding whether to spawn. The dispatcher does
  │     # not infer one from the other.
  │
  ├── Recovery-via-inline eligibility (Bug 2 — bounded takeover for tooling friction):
  │     Triggers ONLY on RESULT_STATUS=bail. Default is BAIL; recovery is the carve-out.
  │
  │     Eligible only when ALL of the following hold:
  │       a. recovery_inline_used == 0 (cap is 1 per pr-grind invocation; reset
  │          on each invocation, never persisted across invocations)
  │       b. --no-recovery-inline was NOT passed
  │       c. RESULT_INFLIGHT_CHANGES ∈ {staged, unstaged, both} — worker left
  │          working-tree changes that may be salvageable. The `both` state
  │          (worker had simultaneous staged AND unstaged changes — common
  │          mid-fix: ran `git add` on some files, kept editing others) is
  │          handled by the dedicated branch in the RECOVERY_INLINE block
  │          below; excluding it here would silently defeat the dual-state
  │          recovery the worker contract specifically builds.
  │       d. RESULT_BAIL_CATEGORY == "tooling" — explicit enum on a structured tag,
  │          NOT substring matching against free-form RESULT_BAIL_REASON. The worker
  │          contract (agents/pr-grinder.md "Output Format" + "Bail Triggers") emits
  │          RESULT_BAIL_CATEGORY ∈ {tooling, judgment, env, budget} alongside the
  │          human-readable RESULT_BAIL_REASON; this gate keys on the enum so a
  │          worker (or a quoted bot comment paraphrased into RESULT_BAIL_REASON)
  │          can't trip recovery via narrative containing the substring "litmus blocked".
  │          Currently the only worker bail trigger that emits category=tooling is
  │          "litmus blocked twice in this round"; expanding the category requires
  │          an explicit worker-contract change, never an emergent prose match.
  │
  │     If any condition fails → go to BAIL as today.
  │     If all conditions pass → set recovery_inline_used = 1 and go to RECOVERY_INLINE.
  │
  │     Hard non-eligibility (these bails MUST surface to the user, never recover):
  │       - "design question" / "design/scope" — needs human judgment
  │       - "WORKTREE_DIR missing" / "skipped pre-flight Read" — worker setup broken
  │       - "gh CLI auth" / "rate-limit" — environmental, dispatcher can't help
  │       - "history rewrite" / "force-push" / "amend on pushed commit" /
  │         "filter-branch" — worker contract category=judgment; rewriting
  │         published SHAs is operator-authorization territory, not a tooling
  │         friction the dispatcher can bridge. See worker `Bail Triggers`
  │         table → "Fix would require rewriting published git history".
  │       - "max-fix iterations" / "max-wait iterations" — already exhausted budgets
  │     The match list above is allowlist-style precisely so this carve-out
  │     can't widen by accident — adding new tooling-friction reasons is an
  │     intentional protocol change, not an emergent behavior.
  │
  ├── Invariant checks (fail-CLOSED — both must hold):
  │     1. If RESULT_STATUS=needs_more AND RESULT_COMMIT_SHA=none AND
  │        RESULT_REVIEWER_ACKS contains no `stale` entries →
  │        BAIL with reason "subagent emitted needs_more without a commit
  │        SHA and without any stale ack — neither a fix nor a wait-for-
  │        bots is justified, so the loop has no progress signal".
  │        Legitimate `needs_more` rounds always have either a new commit
  │        SHA (worker pushed a fix) OR at least one `stale` ack (worker
  │        is waiting for a bot to re-review). A round with neither is
  │        broken — re-dispatching would loop forever on no progress.
  │        Note: a bot whose review was downgraded to `none` by the
  │        infra-error path (see scripts/ack-ledger.sh) will not appear as
  │        `stale`. If that downgraded bot was the ONLY reason the worker
  │        considered the round incomplete, the worker should return
  │        `clean` (or `bail`), not `needs_more` with all-`none` acks —
  │        the invariant correctly catches that misuse.
  │     2. If RESULT_STATUS=clean AND any registered bot in
  │        RESULT_REVIEWER_ACKS has value `stale` →
  │        BAIL with reason "subagent reported clean but reviewer ack
  │        ledger has stale entries: <list>". Slow-Greptile / slow-Cubic
  │        race protection — clean cannot ship while a registered bot
  │        hasn't acked HEAD.
  │     3. Bot-ledger coverage gate (Bug 1 — prose-review enumeration):
  │        For every bot in the **intersection** of RESULT_REVIEWER_ACKS
  │        and RESULT_BOT_LEDGER whose ack value is a <short-sha>
  │        (acked HEAD) — i.e., the bot definitely reviewed something
  │        on this PR AND has an enumeration entry — that ledger entry
  │        MUST have `n_total >= 1`. A `0/0` ledger entry for a
  │        HEAD-acked bot means the worker didn't enumerate the bot's
  │        body; merging would risk a Greptile-style prose coverage gap
  │        (PR with buried actionable findings the worker silently
  │        skipped).
  │
  │        **Asymmetry: ledger and ack registry are not 1:1.** The
  │        ledger includes `codescene-delta-analysis` (it posts findings
  │        as Source 2 review threads) while the ack registry does not
  │        (codescene has no /reviews entries, so its HEAD-ack signal
  │        doesn't go through scripts/ack-ledger.sh). For ledger entries
  │        whose login is NOT in RESULT_REVIEWER_ACKS, this invariant
  │        does not apply — codescene is enumerated for content but its
  │        coverage is gated through the worked-example "always include
  │        codescene in the default ledger" rule, not through this
  │        invariant. The intersection rule keeps Invariant 3 strictly
  │        scoped to the four registered ack-bots that the worker can
  │        cross-correlate.
  │
  │        Parse RESULT_BOT_LEDGER as comma-separated entries of shape
  │        `<login>=<n_actionable>/<n_total>:<disposition>`.
  │
  │        **Defensive count check FIRST.** The known-bot set is fixed
  │        (5 bots: `greptile-apps`, `cubic-dev-ai`, `coderabbitai`,
  │        `copilot-pull-request-reviewer`, `codescene-delta-analysis`).
  │        After comma-splitting, the number of entries MUST equal 5; if
  │        it doesn't, BAIL with reason "malformed bot ledger: expected 5
  │        entries, got <N> — possible disposition comma corruption (the
  │        worker contract requires dispositions to contain no commas
  │        because they would split into phantom entries and could hide
  │        a HEAD-acked bot's `0/0` from this gate)". This count check
  │        is what makes "MUST NOT contain commas" enforceable instead
  │        of a soft hope.
  │
  │        Then for each entry where the corresponding RESULT_REVIEWER_ACKS
  │        value exists AND looks like a short SHA (regex `^[0-9a-f]{7,40}$`):
  │          - if n_total == 0 → BAIL with reason "worker did not
  │            enumerate findings for <bot> despite ack on
  │            <short-sha> — possible prose-review coverage gap;
  │            manual review required"
  │          - if n_total >= 1 → pass (worker enumerated; disposition
  │            is its decision)
  │
  │        `stale` and `none` ack values do NOT trigger this gate —
  │        `stale` means bot hasn't re-reviewed yet (Invariant 2 already
  │        gates on this for clean status); `none` means bot never posted
  │        or only posted infra-error markers (`<bot>=0/0:none` ledger
  │        entry is the matching shape and is fine). Only HEAD-acked bots
  │        prove a body exists that should have been enumerated.
  │
  │     4. Discipline rails — cumulative caps for the out-of-scope-
  │        acknowledged flow (see agents/pr-grinder.md Step 3
  │        "Out-of-Scope-Acknowledged Workflow").
  │
  │        Runs on EVERY round status, including `clean`. Accumulated
  │        breaches block ship even when this round's classification is
  │        clean — a worker that dismisses 5+ findings before declaring
  │        clean must still surface to the operator.
  │
  │        Both bails are dispatcher-emitted with category=`judgment`. This
  │        widens the dispatcher emit set from `{budget}` to
  │        `{budget, judgment}` — see agents/pr-grinder.md "Bail Triggers"
  │        category enum doc.
  │
  │        Caps are INCLUSIVE — 5 dismissals and 3 spawned issues are
  │        the maximum ALLOWED (worker can use the full budget); the
  │        6th dismissal / 4th spawn is what BAILs. The conditions below
  │        use strict-greater-than so the cap value itself remains a
  │        legal grind state. The natural-language wording ("≤5", "≤3")
  │        in Safety Rails / Anti-Patterns / Worked Example all reflect
  │        this inclusive reading; the pseudocode's `>` (not `>=`) is
  │        what makes that wording true. Earlier drafts had `>=` which
  │        BAILed the legal 5th/3rd — fixed in review.
  │
  │        - If total_scope_skipped > 5 →
  │            BAIL with reason "out-of-scope dismissal count is
  │            <total_scope_skipped> across <round_number> rounds —
  │            exceeds discipline rail of 5; operator review required",
  │            RESULT_BAIL_CATEGORY=judgment.
  │
  │        - If total_issues_spawned > 3 →
  │            BAIL with reason "follow-up-issue spawn count is
  │            <total_issues_spawned> across <round_number> rounds —
  │            exceeds discipline rail of 3; PR scope is too narrow or
  │            worker is misclassifying", RESULT_BAIL_CATEGORY=judgment.
  │
  │        The thresholds are deliberate: 5 dismissals = roughly one per
  │        round at MAX_FIX=5, well above the per-round cap of 3 the
  │        worker self-enforces (so honest workers won't trip it); 3
  │        spawned issues = the point at which "this PR has scope creep
  │        worth deferring" tips into "this PR's scope is wrong, replan."
  │        Tightening the caps without operator data risks bailing
  │        legitimate grinds; loosening them silently allows the
  │        relabel-as-out-of-scope failure mode the rails exist to catch.
  │
  ├── Classify round and increment the appropriate counter:
  │     # ONLY runs on RESULT_STATUS=needs_more — bail and clean rounds skip this
  │     # block via the earlier branch in "Parse subagent output". This is
  │     # intentional: bail terminates the loop (no future round to budget for)
  │     # and clean ships the PR (same — no future round). Only needs_more
  │     # rounds consume budget because only they cause another dispatch.
  │     If RESULT_COMMIT_SHA != "none" → fix_round  += 1   # worker pushed a fix
  │     If RESULT_COMMIT_SHA == "none" → wait_round += 1   # worker waiting for bots
  │     # Classification reads RESULT_COMMIT_SHA, not the alias RESULT_HEAD_SHA —
  │     # the dispatcher's tag-resolution step already canonicalized aliases
  │     # before this point (see "Resolution order" in Dispatch a Round below).
  │
  └── Update state:
        PRIOR_COMMIT_SHA    = RESULT_COMMIT_SHA
        PRIOR_REVIEWER_ACKS = RESULT_REVIEWER_ACKS
        PRIOR_ATTEMPTS     += "Round N (fix=<fix_round>/<MAX_FIX>, wait=<wait_round>/<MAX_WAIT>): fixes=<RESULT_FIXES>; failures=<RESULT_REMAINING>; acks=<RESULT_REVIEWER_ACKS>; scope-skipped=<scope_skipped_this_round>; spawned=<issues_spawned_this_round>"
        # failures= is required — subagent's flaky-check bail (3+ rounds)
        # reads it. Dropping it makes that bail unreachable and the loop
        # will grind to MAX rounds instead of stopping early on a flaky
        # check.
        # acks= is preserved for diagnostics / human review of the loop
        # transcript; the worker does NOT bail on stale-ack streaks (every
        # commit-round emits all-stale by design, so a streak is the
        # healthy case). Genuinely stuck bots fall out via MAX_WAIT.
        # The fix=/wait= prefix in the round summary lets the worker (which
        # gets PRIOR_ATTEMPTS in its context block) see budget pressure
        # without needing the dispatcher to pass MAX_FIX/MAX_WAIT separately.
        # scope-skipped= and spawned= record this-round contributions to
        # Invariant 4's cumulative counters — visibility for the operator
        # reading PRIOR_ATTEMPTS at bail time. Per-thread permalinks and
        # spawn-issue numbers live in the spawned issues themselves
        # (filter via `gh issue list --label scope-deferred`); duplicating
        # them in PRIOR_ATTEMPTS would balloon the worker's context block
        # for marginal clarity.

# Loop exits naturally when fix_round >= MAX_FIX OR wait_round >= MAX_WAIT
# without ever seeing RESULT_STATUS=clean → fail-CLOSED to BAIL, NOT to
# COMPLETION. The PR isn't clean; we just ran out of attempts. Writing the
# marker here would silently merge an unfinished PR.
ON_LOOP_EXHAUSTED — two flavors, branch on which counter overflowed.
                     Both flavors emit RESULT_BAIL_CATEGORY=budget — this is the
                     dispatcher-only enum value documented in agents/pr-grinder.md
                     "Bail Triggers" (workers never emit `budget`; only the dispatcher
                     knows about MAX_FIX/MAX_WAIT exhaustion).
  fix_round  >= MAX_FIX   → BAIL with reason "max-fix iterations (<MAX_FIX>) reached without clean status",
                          RESULT_BAIL_CATEGORY=budget
  wait_round >= MAX_WAIT  → derive STALE_AT_BAIL from PRIOR_REVIEWER_ACKS (the persisted last-round
                          ledger updated in the Update state block above): comma-separated list of bot logins
                          whose ack value is the literal string `stale`. Then BAIL with reason
                          "max-wait iterations (<MAX_WAIT>) reached without all bots acking HEAD;
                          latest stale: <STALE_AT_BAIL>" (or "<none>" if no bots are stale —
                          which would itself be diagnostic, since exhausting wait-rounds without
                          any stale acks suggests a bug in the round-classification logic, not
                          a slow bot), RESULT_BAIL_CATEGORY=budget.
  # If both counters happen to overflow on the same round (impossible by
  # construction — only one increments per round — but defensive), prefer
  # the fix-round message since fix-rounds represent active engineering
  # progress that the operator likely cares about more.
  # NOTE on persistence: STALE_AT_BAIL is derived from PRIOR_REVIEWER_ACKS, NOT
  # from Step 6.5's transient $STALE_BOTS bash variable — that variable lives
  # only inside the bash invocation that runs the ledger snippet and does not
  # survive into the dispatcher's bail handler. PRIOR_REVIEWER_ACKS IS persisted
  # across rounds (updated in the Update state block above on every needs_more round), so
  # parsing its `stale` entries at bail time gives a reliable answer.

COMPLETION:
  ├── Verify checks one more time (defense in depth)
  ├── Recompute ack ledger and assert all entries are <HEAD-SHA> or `none`
  │   (defense in depth — invariant check 2 already gated this, but the
  │   bot may have re-posted between subagent return and merge time)
  ├── Write .claude/pr-grind-clean.local at repo root
  ├── default → gh pr merge --squash --delete-branch
  ├── --no-merge → write marker to original-worktree repo root, report ready
  └── Cleanup ephemeral worktree (skip if NO_WORKTREE=1)

BAIL:
  └── Cleanup ephemeral worktree (skip if NO_WORKTREE=1), surface RESULT_BAIL_REASON to user

RECOVERY_INLINE (Bug 2 — bounded inline takeover):
  ├── cd "$WORKTREE_DIR" (worker's working tree carries the inflight changes)
  ├── Inspect & verify the inflight state matches what the worker reported.
  │   Path comparisons MUST use set equality on `|`-split tokens (worker emits
  │   `|`-delimited paths to survive filenames with spaces — see worker
  │   snapshot block). Stage updates MUST use `git add -- <files>` (with the
  │   `--` separator) to prevent option-injection from filenames starting
  │   with `-`. NEVER pass RESULT_STAGED_FILES / RESULT_UNSTAGED_FILES
  │   through unquoted shell expansion.
  │
  │     If RESULT_INFLIGHT_CHANGES=staged:
  │       a. Run `git diff --cached -z --name-only | tr '\0' '\n' | sort` →
  │          local snapshot. Run `printf '%s' "$RESULT_STAGED_FILES" |
  │          tr '|' '\n' | sort` → reported snapshot. Compare as sets.
  │       b. If they diverge, BAIL with reason "recovery-via-inline: staged
  │          state mismatch (worker reported <X>, working tree shows <Y>)".
  │       c. Verify staged-diff content hasn't been mutated:
  │          LOCAL_SHA=$(git diff --cached | sha256sum | cut -c1-64)
  │          If LOCAL_SHA != RESULT_STAGED_DIFF_SHA, BAIL with reason
  │          "recovery-via-inline: staged diff content changed since worker
  │          bail (sha mismatch)" — defends against concurrent worktree
  │          mutation that the path-list match cannot catch.
  │     If RESULT_INFLIGHT_CHANGES=unstaged:
  │       a. Compare `git diff -z --name-only` set against RESULT_UNSTAGED_FILES;
  │          divergence → BAIL "recovery-via-inline: unstaged state mismatch".
  │       b. Verify unstaged-diff content via SHA:
  │          LOCAL_UNSTAGED_SHA=$(git diff | sha256sum | cut -c1-64)
  │          If LOCAL_UNSTAGED_SHA != RESULT_UNSTAGED_DIFF_SHA, BAIL with reason
  │          "recovery-via-inline: unstaged diff content changed since worker
  │          bail (sha mismatch)" — concurrent worktree mutation between
  │          worker bail and dispatcher takeover would otherwise let the
  │          dispatcher commit content the worker never saw.
  │       c. Stage the verified set: read the path list with mapfile / while-read
  │          loop on the `|`-split tokens, then `git add -- "${PATHS[@]}"`.
  │     If RESULT_INFLIGHT_CHANGES=both:
  │       Worker had both staged AND unstaged changes (common mid-fix state:
  │       added some files, kept editing others). Verify staged set + diff-sha
  │       per the staged branch above, verify and stage the unstaged set per
  │       the unstaged branch above. Both must verify before commit; failure
  │       in either set BAILs without partial-state mutation.
  │
  ├── Brief inline review of the staged diff:
  │     Run `git diff --cached` and read the change. The dispatcher (Opus)
  │     can read the diff in conversation context — the worker bailed mid-fix,
  │     but the diff itself may still be sound. Sanity-check that the change
  │     addresses something in the worker's RESULT_FIXES summary; if RESULT_FIXES
  │     was empty (worker bailed before classifying anything as fixed), that's a
  │     red flag — BAIL with reason "recovery-via-inline: worker bailed without
  │     RESULT_FIXES summary; no clear intent to recover".
  │
  ├── Commit & push (the dispatcher CAN handle litmus iteration, the worker can't):
  │     # SECURITY: build the message with `printf %s` formatters that do NOT
  │     # re-interpret content, then pipe to `git commit -F -` reading from
  │     # stdin. RESULT_FIXES is worker prose that can contain attacker-
  │     # controlled content (paraphrased bot-comment text, quoted user
  │     # input, etc.); shell-string interpolation into a `COMMIT_BODY="..."`
  │     # assignment OR a `git commit -m "..."` flag would create a
  │     # command-injection sink for any backtick / $(...) / closing-quote
  │     # sequence in the summary. The `printf '%s' "$VAR"` pattern below
  │     # treats $VAR as literal data — no command substitution, no quote
  │     # parsing, no $(...) expansion of the variable's contents.
  │     printf 'fix: address PR #%s feedback — %s (recovery-via-inline)\n' \
  │       "$PR_NUMBER" "$RESULT_FIXES" \
  │       | git commit -F -
  │     # If RESULT_FIXES happens to contain a literal newline (workers
  │     # shouldn't emit one — RESULT_FIXES is "one-line summary" per the
  │     # output-format contract — but defense in depth): strip it via
  │     # `tr -d '\n'` before piping.
  │     # The pre-commit hook fires litmus. The dispatcher (Opus) can iterate
  │     # through litmus auto-corrections (up to 10 iterations per gate semantics);
  │     # the worker context can't, which is precisely the tooling friction this
  │     # carve-out exists to bridge.
  │     git push
  │
  ├── On litmus FAIL after auto-iteration:
  │     BAIL with reason "recovery-via-inline attempted but litmus rejected
  │     worker's in-flight changes: <litmus output>". This surfaces the actual
  │     code problem to the user — the worker's fix was wrong, not just blocked
  │     by tooling. Do NOT retry; the recovery cap is 1.
  │
  ├── On commit/push success:
  │     fix_round += 1                         # recovery counts as a fix-round (engineering work happened)
  │     PRIOR_COMMIT_SHA   = <new SHA>
  │     PRIOR_ATTEMPTS    += "Round N (fix=<fix_round>/<MAX_FIX>, wait=<wait_round>/<MAX_WAIT>):
  │                            fixes=<RESULT_FIXES> (recovery-via-inline);
  │                            failures=<RESULT_REMAINING>;
  │                            acks=<recompute fresh — bots haven't seen recovery commit yet, expect mostly stale>"
  │     # PRIOR_REVIEWER_ACKS is recomputed fresh via scripts/ack-ledger.sh against the new HEAD —
  │     # don't reuse the worker's pre-bail snapshot, it's now stale.
  │     If fix_round >= MAX_FIX → fall through to ON_LOOP_EXHAUSTED (no rescue from budget exhaustion)
  │     Else → return to top of LOOP (continue dispatching workers)
  │
  └── recovery_inline_used remains 1 for the rest of this invocation —
      a second worker bail will go straight to BAIL, no matter how clean
      its inflight state looks. The cap is the load-bearing safety rail
      that prevents "dispatcher always rescues" from masking a chronic
      worker bug over time.
```

## Step Details

### Step 0: Create Ephemeral Worktree

Create an isolated worktree so the user's main workspace stays free for their next task.

```bash
PR_BRANCH=$(gh pr view <PR_NUMBER> --json headRefName -q .headRefName)
# Resolve to an absolute path so WORKTREE_DIR can be passed to the subagent
# unambiguously — a relative path would re-anchor against whatever CWD the
# subagent SDK happens to start in, not the dispatcher's post-`cd` CWD.
# Use parent-pwd composition so this works even before the worktree exists
# (BSD realpath on macOS rejects non-existent paths).
WORKTREE_DIR="$(cd .. && pwd -P)/pr-grind-${PR_NUMBER}"

# Attempt to create the ephemeral worktree. If the branch is already
# checked out elsewhere (another worktree, or the dispatcher's own CWD —
# the common case when running pr-grind on the branch you just pushed),
# fall back to in-place mode automatically — equivalent to passing
# `--no-worktree`. This avoids a hard failure on a workflow we expect.
WT_OUT=$(LANG=C LC_ALL=C git worktree add "$WORKTREE_DIR" "$PR_BRANCH" 2>&1)
WT_EXIT=$?

# `tr -cd '[:print:]\n\t'` strips every non-printable byte — kills CSI, OSC,
# and any other terminal-control sequence in one pass. Used here instead of
# sed because BSD sed (macOS default) does not support the `\x1B` hex escape;
# `tr -cd '[:print:]\n\t'` is portable across BSD and GNU. Applied to any
# output that came from git or from the GitHub-API-supplied branch name.
SAFE_BRANCH=$(printf '%s' "$PR_BRANCH" | tr -cd '[:print:]\n\t')

if [ "$WT_EXIT" -ne 0 ]; then
  if printf '%s' "$WT_OUT" | grep -q 'already used by worktree at'; then
    echo "ℹ️  Branch $SAFE_BRANCH is already checked out — falling back to in-place mode (--no-worktree)."
    # Marker line — the dispatcher scans stdout for this exact string and
    # MUST propagate NO_WORKTREE=1 to subsequent bash blocks (shell vars
    # don't survive across Claude tool calls; the printed marker is the
    # cross-block source of truth).
    echo "pr-grind-mode: no-worktree"
    # Hard-fail if we can't resolve the repo root — without `set -e`, an
    # empty WORKTREE_DIR would let `cd ""` silently fall through to $HOME.
    if ! WORKTREE_DIR=$(git rev-parse --show-toplevel); then
      echo "❌ git rev-parse --show-toplevel failed — cannot determine repo root for in-place fallback."
      exit 1
    fi
    NO_WORKTREE=1
    cd "$WORKTREE_DIR" || { echo "❌ cd to repo root '$WORKTREE_DIR' failed — cannot proceed with in-place fallback."; exit 1; }
    # Echo the resolved path so the dispatcher can capture it deterministically
    echo "WORKTREE_DIR=$WORKTREE_DIR"
  else
    SAFE_WT_OUT=$(printf '%s' "$WT_OUT" | tr -cd '[:print:]\n\t')
    echo "❌ git worktree add failed: $SAFE_WT_OUT"
    exit 1
  fi
else
  cd "$WORKTREE_DIR" || { echo "❌ cd to worktree '$WORKTREE_DIR' failed — cannot proceed."; exit 1; }
  echo "WORKTREE_DIR=$WORKTREE_DIR"
fi
```

**Why a worktree:** pr-grind is a different operational mode from the pipeline. Pre-PR phases optimize for local delivery; post-PR grind optimizes for async iteration. An ephemeral worktree gives pr-grind its own branch ownership without hijacking the main workspace.

**Skip with `--no-worktree`:** Optional explicit opt-in to in-place mode. The auto-fallback below now handles the common case (branch already checked out), so passing this flag is rarely required — use it when you want to suppress the info-level fallback message or skip the worktree-add attempt entirely.

**Auto-fallback to in-place mode:** If `git worktree add` fails with `already used by worktree at`, Step 0 automatically falls back and prints three lines: an `ℹ️` info line naming the branch, `pr-grind-mode: no-worktree`, and `WORKTREE_DIR=<repo-root>`. **When the `pr-grind-mode: no-worktree` line appears, the dispatcher MUST treat the rest of the run as if `--no-worktree` was passed** — set `NO_WORKTREE=1` in every subsequent bash block, skip the worktree cleanup at COMPLETION and BAIL, and write `pr-grind-clean.local` to the current repo root rather than copying it across worktrees. This state has to be carried by Claude across bash invocations because shell variables don't persist; treat the printed marker as the source of truth and propagate it explicitly. The `WORKTREE_DIR=<repo-root>` line is the resolved path the dispatcher should pass to the subagent context block.

### Dispatch a Round (default path)

Build the context block and dispatch the subagent. The block must include everything the subagent needs — it has no memory of prior rounds.

**Generate a unique `RESULT_FILE` path BEFORE dispatch** so the worker's belt-and-suspenders RESULT-block backup (per `agents/pr-grinder.md` "Output Format") is uniquely scoped to this dispatch attempt. Use `mktemp -t pr-grinder-result.XXXXXXXX` (preferred) or compose `/tmp/pr-grinder-result-${PR_NUMBER}-${ROUND}-$$-$(date +%s%N).txt`; either form prevents a stale leftover from a prior round / session / concurrent grind from being mis-parsed as the current round's output.

```text
Agent invocation:
  subagent_type: pr-grinder
  description: pr-grind round N
  prompt: |
    PR_NUMBER=<N>
    OWNER=<owner>
    REPO=<repo>
    WORKTREE_DIR=<absolute path>
    ROUND=<N> (fix=<fix_round>/<MAX_FIX>, wait=<wait_round>/<MAX_WAIT>)
    RESULT_FILE=<unique tmp path generated above>
    PRIOR_COMMIT_SHA=<sha or "none">
    PRIOR_REVIEWER_ACKS=<login=value,login=value,...> (round 1: every registered bot = none)
    PRIOR_ATTEMPTS:
      - Round 1 (fix=<fix_round>/<MAX_FIX>, wait=<wait_round>/<MAX_WAIT>): fixes=<summary>; failures=<failed-check-names or "none">; acks=<login=value,...>
      - Round 2 (fix=<fix_round>/<MAX_FIX>, wait=<wait_round>/<MAX_WAIT>): fixes=<summary>; failures=<failed-check-names or "none">; acks=<login=value,...>
      ...

    Execute one round per agents/pr-grinder.md. Return RESULT_* tags.
```

After the subagent returns, **scan the response for lines matching `^RESULT_<NAME>: ` and extract each tag's value**. Don't rely on a fixed line count — `RESULT_BAIL_REASON` is only present on bail. Parsing by tag prefix is robust to additions/omissions. If the same tag appears multiple times (e.g., the subagent quotes a review comment that happens to contain `RESULT_STATUS:`), use the **last** occurrence — the canonical block is at the end of the response.

**Legacy tag aliases (deprecated, accepted with warning):** Older worker contracts and third-party adapters use different names for three of the canonical fields. When the canonical tag is missing but its alias is present, treat the alias as a synonym AND emit a one-line `⚠️  deprecated tag <alias>; use <canonical>` notice so the operator can prompt the worker to update.

| Canonical | Legacy alias |
|---|---|
| `RESULT_STATUS` | `RESULT_VERDICT` |
| `RESULT_COMMIT_SHA` | `RESULT_HEAD_SHA` |
| `RESULT_REVIEWER_ACKS` | `RESULT_ROUND_ACKS` |

**Resolution order (matters):** apply alias resolution **first**, then last-occurrence-within-a-name, then validate required tags are present. If you check the bail rule below ("`RESULT_STATUS` missing → bail unparseable") before resolving aliases, a worker that emitted only `RESULT_VERDICT` would be falsely bailed and the alias rule never fires.

**On dual emission:** if BOTH the canonical name and its alias appear in the same response, prefer the canonical and emit `⚠️  worker emitted both <canonical> and <alias>; using canonical — file a worker-contract bug` so the inconsistency surfaces. (Last-occurrence-wins still applies *within* a single name; canonical-vs-alias preference overrides it *across* the pair.)

The full tag set:

```
RESULT_STATUS: clean | needs_more | bail              (always present)
RESULT_COMMIT_SHA: <sha or "none">                    (always present)
RESULT_FIXES: <one-line summary>                      (always present)
RESULT_REMAINING: <one-line or "none">                (always present)
RESULT_REVIEWER_ACKS: <login=value,login=value,...>   (always present; values: <short-sha> | none | stale; early-bail paths emit the all-`none` default initialized before Step 0)
RESULT_BOT_LEDGER: <login=n_act/n_total:disp,...>     (always present; entries shape: `<login>=<n_actionable>/<n_total>:<disposition>`; early-bail paths emit the all-`0/0:none` default; gates Invariant 3 — see Dispatcher Loop. Disposition prose MUST NOT contain commas; entries are split on `,` and a comma inside a disposition would corrupt the parse. Disposition MAY carry `+`-joined `scope-skipped:<reason>:<count>` segments — Invariant 4 sums those counts across all bots/rounds against the ≤5 cumulative cap)
RESULT_ISSUES_SPAWNED: <issue,issue,... or "none">    (always present in the new contract; comma-separated GitHub issue numbers spawned this round via the out-of-scope-acknowledged workflow; gates Invariant 4 — cumulative count across rounds caps at 3. **Backward compatibility:** missing tag entirely → treat as "none" / zero contribution. Old-contract workers (pre-out-of-scope-flow) never emitted this tag and operate under pre-Invariant-4 semantics for the rest of their grind; new-contract workers always emit it. Do NOT bail "subagent output unparseable" on a missing RESULT_ISSUES_SPAWNED — the protocol is additive, not version-pinned.)
RESULT_INFLIGHT_CHANGES: none | staged | unstaged | both  (always present; non-bail rounds emit `none`; bail rounds emit the worker's snapshotted working-tree state — gates RECOVERY_INLINE eligibility)
RESULT_STAGED_FILES: <`|`-separated paths or "none">  (always present; pipe-delimited — split on `|` and use `git add --` to prevent option-injection; `|` is used because NUL bytes cannot survive in plain-text tag files)
RESULT_UNSTAGED_FILES: <`|`-separated paths or "none"> (always present; pipe-delimited)
RESULT_STAGED_DIFF_SHA: <64-hex sha256 or "none">     (always present; verifies staged content hasn't been mutated between worker bail and dispatcher takeover)
RESULT_UNSTAGED_DIFF_SHA: <64-hex sha256 or "none">   (always present; verifies unstaged content hasn't been mutated — applies in unstaged and both modes)
RESULT_BAIL_REASON: <one-line free-form prose>        (present only when status=bail; for human consumption — NEVER substring-matched for control flow)
RESULT_BAIL_CATEGORY: tooling | judgment | env | budget  (present only when status=bail; structured enum that gates recovery-via-inline eligibility)
```

**Stdout-parse fallback to the dispatcher-allocated `RESULT_FILE`:** if scanning the worker's stdout for `^RESULT_<NAME>: ` produces no `RESULT_STATUS` after alias resolution **OR** produces a `RESULT_STATUS` whose value isn't one of `clean`, `needs_more`, `bail`, DO NOT immediately bail. First try reading `$RESULT_FILE` (the unique path you allocated in the context block above); if it exists and yields a `RESULT_STATUS` whose value IS one of the three canonical values (after the same alias resolution and last-occurrence rules), use those tags. The worker writes this file immediately before stdout emission per the contract in `agents/pr-grinder.md`, so it should be present on the filesystem even when stdout was truncated, reformatted by the SDK, polluted by mid-prompt output, OR contained a malformed `RESULT_STATUS` value. Only bail "subagent output unparseable" if BOTH stdout and the file fail to yield a `RESULT_STATUS` with a canonical value.

The fallback fires on EITHER missing OR invalid `RESULT_STATUS`. A worker that emitted `RESULT_STATUS: garbage` on stdout and `RESULT_STATUS: clean` to the file should be treated as `clean`, not bailed — stdout pollution should not override a well-formed file backup.

If after both probes `RESULT_STATUS` is still missing or its value still isn't one of the three valid options, then bail "subagent output unparseable" — do not guess.

### Inline Execution (`--opus`, `--interactive`, `--ci-only`, or `--comments-only`)

When inline, the dispatcher executes the round body itself. This is the legacy behavior — Steps 1–7 below — running in the parent Opus context.

<EXTREMELY-IMPORTANT>
YOU MUST COMPLETE STEP 1 BEFORE PROCEEDING. Do NOT skip, abbreviate, or defer CI waiting.
The entire pr-grind workflow depends on checks being complete. If you proceed without waiting,
you will be blocked by the pre-merge gate and waste the user's time.
</EXTREMELY-IMPORTANT>

#### Step 1: Wait for ALL Checks + Reviewers

**DO NOT skip this step. DO NOT proceed while checks are still pending.**

Automated reviewers (CodeRabbit, Greptile, Cubic, CodeScene, GitGuardian) register as GitHub checks. `gh pr checks --watch` blocks until ALL of them complete — not just CI build/lint/test.

**Advisory checks (CodeScene):** CodeScene is non-blocking — its feedback is still collected and you MUST attempt to fix its issues, but its pass/fail status does not block the clean marker or merge gate. If a CodeScene finding requires architectural changes beyond PR scope, note it and proceed.

```bash
# Phase 1: Wait for all GitHub-registered checks (CI + automated reviewers)
timeout 900 gh pr checks <PR_NUMBER> --watch 2>&1 || true

# Phase 2: Verify no checks are still pending (defensive — catches race conditions)
for i in 1 2 3 4 5; do
  PENDING=$(gh pr checks <PR_NUMBER> 2>&1 | grep -c "pending" || true)
  [ "$PENDING" -eq 0 ] && break
  echo "⏳ $PENDING checks still pending — waiting 60s (attempt $i/5)..."
  sleep 60
done
if [ "$PENDING" -gt 0 ]; then
  echo "❌ $PENDING checks still pending after 5 retries. Cannot proceed."
  echo "Remaining: $(gh pr checks <PR_NUMBER> 2>&1 | grep pending)"
  exit 1
fi

# Phase 2.5: Verify all checks PASSED (not just completed)
GH_EXIT=0
CHECKS_RAW=$(gh pr checks <PR_NUMBER> 2>&1) || GH_EXIT=$?
if [ "$GH_EXIT" -ne 0 ] && ! printf '%s\n' "$CHECKS_RAW" | grep -qE "pass|fail|pending"; then
  echo "❌ gh pr checks failed (exit $GH_EXIT). Resolve CLI/auth issues."
  exit 1
fi
ADVISORY_PATTERN="CodeScene"
REQUIRED=$(echo "$CHECKS_RAW" | grep -ivE "$ADVISORY_PATTERN" || true)
ADVISORY_FAILED=$(echo "$CHECKS_RAW" | grep -iE "$ADVISORY_PATTERN" | grep -cE "fail" || true)
FAILED=$(echo "$REQUIRED" | grep -cE "fail" || true)
if [ "$ADVISORY_FAILED" -gt 0 ]; then
  echo "⚠️  $ADVISORY_FAILED advisory checks failing (non-blocking)."
fi
if [ "$FAILED" -gt 0 ]; then
  echo "❌ $FAILED required checks FAILED. Continuing to Step 2 to collect details."
  echo "$REQUIRED" | grep -E "fail"
fi

# Phase 3: Grace period for late-arriving comments
sleep 30
```

**Polling/proceed gate is `0 pending` — NOT a specific check count.** Once nothing is pending, continue so Step 2 can collect any failures or review feedback. **Clean/merge-ready state is `0 pending AND 0 failed`.** After rebases, some services (CodeRabbit, cubic) may not re-register their check. Do NOT poll for "expected N checks" — only use pending vs failed state.

#### Step 2: Collect Feedback

Gather ALL pending issues in one pass:

```bash
# CI check results
gh pr checks <PR_NUMBER>

# Inline review threads (GraphQL — skips resolved and outdated threads)
gh api graphql --paginate -f query='
  query($owner: String!, $repo: String!, $pr: Int!, $endCursor: String) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        reviewThreads(first: 100, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            isResolved
            isOutdated
            path
            line
            comments(first: 100) {
              nodes { body author { login } createdAt }
            }
          }
        }
      }
    }
  }
' -f owner={owner} -f repo={repo} -F pr=<PR_NUMBER> \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[]
    | select(.isResolved == false and .isOutdated == false)
    | {path, line, comments: [.comments.nodes[] | {body, user: .author.login, createdAt}]}'

# Review-level comments (approve/request changes/comment)
gh api repos/{owner}/{repo}/pulls/<PR_NUMBER>/reviews \
  --jq '.[] | select(.state == "CHANGES_REQUESTED" or .state == "COMMENTED") | {user: .user.login, state: .state, body: .body}'

# Issue comments
gh pr view <PR_NUMBER> --comments --json comments \
  --jq '.comments[] | {author: .author.login, body: .body}'
```

**On filtering:** Don't filter by "latest comment newer than `PRIOR_COMMIT_SHA`" — that drops unresolved threads whose latest reply happens to be old, even though they're still actionable (a reviewer can post a comment, you push a commit that *doesn't* address it, and the thread stays unresolved with an "old" timestamp). Use **per-source** staleness signals, not one filter that covers all:
- **Source 2 (inline review threads):** `isResolved == false AND isOutdated == false`
- **Source 3 (review-level comments):** `state == CHANGES_REQUESTED` or `COMMENTED`; an explicit `APPROVED` from the same reviewer clears prior CHANGES_REQUESTED
- **Source 4 (issue comments):** no GitHub-side flag exists. Each bot's latest comment body is canonical; older comments from same bot are superseded. **Greptile and CodeRabbit-Pro post their findings only here** — running Source 2 alone misses them. See `agents/pr-grinder.md` Step 2 for concrete bot-by-bot parsing rules.

Re-fetching all four sources each round is cheap; the cost we cared about was conversation-context accumulation, not API traffic, and per-round subagent dispatch already solves that.

#### Step 3: Triage

Classify each piece of feedback:

| Category | Action |
|----------|--------|
| **CI failure — test/lint/build** | Fix it |
| **CI failure — flaky/infra** | Note it, skip after 3 consecutive identical failures |
| **Automated reviewer — specific fix** (CodeRabbit, Greptile, Cubic) | Fix it — treat like human review |
| **Automated reviewer — out-of-scope-acknowledged on YOUR changed code** | Apply the workflow at `agents/pr-grinder.md` Step 3 (Out-of-Scope-Acknowledged Workflow): classify with one of 6 enumerated reasons, spawn follow-up issue (3 spawn reasons) or post audit-only reply (3 audit reasons), then resolve the thread. **DEFAULT IS FIX** — only dismiss with ≥80% confidence the fix would expand scope or require off-codebase work. Per-round cap ≤3 dismissals; cumulative caps ≤5 dismissals + ≤3 spawned issues across the grind (Invariant 4 BAILs past either) |
| **Automated reviewer — stale/pre-existing issue in untouched code** | Skip — only fix issues in YOUR PR's changed lines (this is distinct from out-of-scope-acknowledged: this row is for findings on lines your PR did NOT touch; the row above is for findings on touched lines where the fix is out of scope) |
| **Resolved or outdated thread** | Skip — already filtered out by GraphQL (`isResolved`, `isOutdated`); note that pr-grind's own out-of-scope flow resolves threads after dismissal, so resolved-by-operator threads also fall in this row on subsequent rounds |
| **Human review — specific fix request** | Fix it |
| **Human review — question/clarification** | Reply with explanation, don't change code |
| **Human review — design/scope concern** | **BAIL** — surface to user, this needs human judgment |
| **Code review — nit/style** | Fix it (low effort, high goodwill) |

**Important:** Automated reviewers often post on code that was already in the repo before your PR. Only fix issues in files/lines that YOUR PR changed.

**Inline-mode self-tracking note:** When running inline (`--opus`, `--interactive`, `--ci-only`, `--comments-only`), the dispatcher IS the worker — there is no subagent boundary to emit `RESULT_BOT_LEDGER` / `RESULT_ISSUES_SPAWNED` across. Self-track `total_scope_skipped` and `total_issues_spawned` in your conversation context across rounds, and apply the same Invariant 4 cumulative caps with strict-greater-than thresholds (`>5` dismissals OR `>3` spawned issues → BAIL with `RESULT_BAIL_CATEGORY=judgment`). Caps are INCLUSIVE — 5 dismissals and 3 spawns are the maximum allowed; the 6th dismissal / 4th spawn is what BAILs. This matches the canonical pseudocode at "Invariant checks → 4. Discipline rails" in the Dispatcher Loop above. The discipline rails are protocol invariants, not subagent-only checks; both the inline and subagent surfaces enforce identical thresholds.

#### Step 4: Fix

For each actionable item:

1. Read the relevant file(s) at the referenced lines
2. Understand the surrounding context
3. Apply the minimal fix that addresses the feedback
4. Do NOT refactor, improve, or "while I'm here" adjacent code

#### Step 5: Verify Locally

Run the narrowest test that covers the fix. If local tests fail, fix before pushing.

#### Step 6: Commit & Push

```bash
git add <specific-files>
git commit -m "fix: address PR #<N> feedback — <brief description>"
git push
```

**BLOCKING GATE:** The `git commit` command will block until the litmus pre-commit review passes. Litmus may auto-iterate up to 10 times to fix issues silently. Do NOT use `--no-verify` to bypass this gate. If litmus repeatedly blocks, split the changes into smaller commits or bail.

If you didn't change any files this round (no actionable findings — only waiting for bots to re-review), skip the commit/push and proceed to Step 6.5; HEAD is unchanged and the ledger will reflect bot acks against the existing HEAD.

#### Step 6.5: Compute reviewer ack ledger (post-push)

After any commit/push has settled, compute the per-bot ack ledger. This closes the slow-bot race: a bot's GitHub check can flip green seconds before the bot actually posts its review. Without this gate, Step 7 would declare the round complete and the loop would exit before the bot's findings landed.

The per-bot algorithm itself is single-sourced at `scripts/ack-ledger.sh` and invoked identically here, in `agents/pr-grinder.md` Step 6.5 (the Sonnet worker copy), and in COMPLETION below — algorithm edits touch one file. The fetch block (`ALL_THREADS`/`ALL_REVIEWS`/`ALL_COMMENTS` and the `FETCH_OK` flag) still lives at each call site because PR/owner/repo come from caller-local context. The result-var name (`ROUND_ACKS`) differs from the worker (`ACKS`) and dispatcher (`FRESH_ACKS`) so multiple snippets can coexist in a single Bash invocation without namespace collision.

The `<PR_NUMBER>`, `<owner>`, `<repo>` placeholders below follow the same template-substitution convention used by COMPLETION — Claude substitutes the literal owner / repo / PR-number values at run time before executing the bash.

```bash
PR=<PR_NUMBER>
OWNER=<owner>
REPO=<repo>
HEAD_SHA=$(git rev-parse HEAD | cut -c1-8)

# One-shot fetches. FETCH_OK tracks any source failure; if any source failed,
# scripts/ack-ledger.sh fails-CLOSED to `stale` for every bot (fail-OPEN
# regression guard — empty-default fallbacks would silently produce `none`
# and let `clean` slip through).
FETCH_OK=1
# Source 2: --paginate + cursor — large PRs can exceed reviewThreads(first:100)
ALL_THREADS=$(gh api graphql --paginate -f query='
  query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String) {
    repository(owner:$owner,name:$repo) {
      pullRequest(number:$pr) {
        reviewThreads(first:100, after:$endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            isResolved isOutdated
            comments(first:1) { nodes { author { login } } }
          }
        }
      }
    }
  }
' -f owner="$OWNER" -f repo="$REPO" -F pr="$PR" 2>/dev/null) || FETCH_OK=0
ALL_REVIEWS=$(gh api --paginate "repos/$OWNER/$REPO/pulls/$PR/reviews" 2>/dev/null) || FETCH_OK=0
ALL_COMMENTS=$(gh pr view "$PR" --comments --json comments 2>/dev/null) || FETCH_OK=0
# Source 5: check-runs on HEAD — bots like CodeRabbit (free plan) emit a
# check-run instead of a /reviews entry; tier D in scripts/ack-ledger.sh
# treats a passing check_run whose head_sha == HEAD as a HEAD-ack.
ALL_CHECK_RUNS=$(gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_SHA/check-runs" 2>/dev/null) || FETCH_OK=0

# Per-bot ack — algorithm lives in scripts/ack-ledger.sh (single source of
# truth for this site, the worker's Step 6.5 in agents/pr-grinder.md, and the
# dispatcher's Completion site below). The script reads FETCH_OK / ALL_THREADS /
# ALL_REVIEWS / ALL_COMMENTS / ALL_CHECK_RUNS / HEAD_SHA from env and the bot
# login from $1.
export FETCH_OK ALL_THREADS ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS HEAD_SHA
ACK_SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/ack-ledger.sh"
ROUND_ACKS="greptile-apps=$(bash "$ACK_SCRIPT" greptile-apps 2>/dev/null || echo stale),cubic-dev-ai=$(bash "$ACK_SCRIPT" cubic-dev-ai 2>/dev/null || echo stale),coderabbitai=$(bash "$ACK_SCRIPT" coderabbitai 2>/dev/null || echo stale),copilot-pull-request-reviewer=$(bash "$ACK_SCRIPT" copilot-pull-request-reviewer 2>/dev/null || echo stale)"
echo "Ack ledger: $ROUND_ACKS"

STALE_BOTS=$(echo "$ROUND_ACKS" | tr ',' '\n' | awk -F= '$2=="stale"{print $1}')
echo "STALE_BOTS: $STALE_BOTS"
```

**Acting on the result (instruction to Claude, not shell control flow):** the `STALE_BOTS` variable lives only inside the Bash invocation that runs the snippet above — it does NOT persist into a subsequent inline-loop iteration. After the snippet runs, **Claude reads the printed `Ack ledger:` and `STALE_BOTS:` lines from stdout** and decides:

- **STALE_BOTS empty** → round genuinely complete; proceed to Step 7 (autonomous summary or interactive checkpoint), which will either continue to the next round or dispatch Completion depending on whether checks are green and all findings are resolved.
- **STALE_BOTS non-empty** → round is in waiting-for-bots state; **skip Step 7 entirely** and re-dispatch Step 1 directly (analogous to the Sonnet subagent's `needs_more + RESULT_COMMIT_SHA=none + stale-acks` flow that the dispatcher's relaxed Invariant 1 permits). Increment the round counter as normal.

**Interaction with `--max-fix` / `--max-wait`:** wait-rounds count against `--max-wait` (default 8), NOT against `--max-fix` (default 5). The split fixed a real failure mode in the previous unified `--max` budget: every wait-round consumed a fix slot, so a PR with 3 fix iterations + 4 slow-bot polls would exhaust at `--max=5` even though only 3 fixes happened. With the dual budget, fix-budget reflects *engineering effort* and wait-budget reflects *bot latency tolerance* — orthogonal concerns. Either exhausted budget bails with a specific reason: `max-fix iterations (<MAX_FIX>) reached without clean status` (raise `--max-fix` if grinding a PR with many feedback rounds) or `max-wait iterations (<MAX_WAIT>) reached without all bots acking HEAD; latest stale: <STALE_AT_BAIL>` (raise `--max-wait` if grinding a PR with known-slow reviewer bots; `STALE_AT_BAIL` is the dispatcher-side derivation from `PRIOR_REVIEWER_ACKS` — see `ON_LOOP_EXHAUSTED` in the Dispatcher Loop above. Note: this is distinct from Step 6.5's transient `$STALE_BOTS` bash variable, which lives only inside the ledger snippet and does not survive into the bail handler). The legacy `--max N` flag is a deprecated alias that sets both budgets to N (emits a `⚠️  --max is deprecated; use --max-fix and --max-wait` warning at dispatch start) and CANNOT be combined with `--max-fix` or `--max-wait` — combining them bails with reason `conflicting flags: --max cannot be combined with --max-fix or --max-wait`.

#### Step 7: Round summary / checkpoint

**Gate:** Step 7 only runs when Step 6.5's `STALE_BOTS` was empty (every registered bot is `<HEAD-SHA>` or `none`). When `STALE_BOTS` is non-empty, the round is in waiting-for-bots state — skip Step 7 entirely and re-dispatch Step 1 directly (mirrors the dispatcher's relaxed Invariant 1 handling for stale-ack rounds).

In autonomous mode (default), log a brief summary and continue immediately to the next round (or to Completion if every check is green and no findings remain). In interactive mode (`--interactive`), present to user and wait:

```text
## PR Grind — Round N (fix=<fix_round>/<MAX_FIX>, wait=<wait_round>/<MAX_WAIT>) complete

**Fixed:**
- [ ] CI: <what failed and how you fixed it>
- [ ] Review: <comment summary and what you changed>

**Skipped:**
- <design questions, flaky tests, etc.>

**Status:** Pushed. CI will re-run.

Continue grinding?
```

## Worked Example: Out-of-Scope-Acknowledged Flow

Concrete walk-through of the carve-out — what the worker does, what the dispatcher sees, and how Invariant 4 interacts with it. Drawn from the failure mode that motivated this flow (jikdak PR #129, where the dispatcher had no clean way to dispose of architectural findings on touched lines and the merge stayed blocked across 7+ rounds).

**Setup.** A content PR changes `client/src/lib/blog-data.ts` (one of many edits). CodeRabbit posts two findings on lines this PR touched:

1. `client/src/lib/latest-data.ts:1963` — "Model `eventDate` as a date range (start + end)" → would change the shared `LatestItem` schema/interface contract.
2. `client/src/lib/blog-data.ts:11427` — "Use report-level source links instead of homepage links" → requires off-codebase research to find each report's permalink.

Both are real findings on changed code. Neither fits the existing pre-existing-issue carve-out (the lines were touched). Without out-of-scope-acknowledged, the worker would either fix them (3+ scope-creep rounds, bot finds new things on the new HEAD, grind never converges) or leave the threads unresolved (ack ledger stays `stale` forever, merge gate blocks indefinitely).

**Round 3 (worker, inline).**

```
Round 3 triage (BOT_REVIEWS["coderabbitai"]):

1. eventDate range modeling (latest-data.ts:1963)
   → Classification: out-of-scope-acknowledged
   → Reason: schema-refactor (changes shared LatestItem contract)
   → Spawn: yes
   → gh issue create → spawned issue #847
   → addPullRequestReviewThreadReply: "pr-grind: out-of-scope (schema-refactor) — tracked as #847"
   → resolveReviewThread: thread closed

2. Source link homepage→report (blog-data.ts:11427)
   → Classification: out-of-scope-acknowledged
   → Reason: external-research (requires off-codebase web lookup per report)
   → Spawn: yes
   → gh issue create → spawned issue #848
   → addPullRequestReviewThreadReply: "pr-grind: out-of-scope (external-research) — tracked as #848"
   → resolveReviewThread: thread closed

3. /blog/* paths in relatedTools (blog-data.ts: multiple lines)
   → Classification: fix it (specific fix in changed code; mechanical)
   → Apply edit; commit; push.

Round 3 dismissal count: 2 (under per-round cap of 3) ✓
```

**Worker emits:**

```
RESULT_STATUS: needs_more
RESULT_COMMIT_SHA: 4361cc54
RESULT_FIXES: remove /blog/* paths from 4 relatedTools blocks
RESULT_REMAINING: none
RESULT_REVIEWER_ACKS: greptile-apps=stale,cubic-dev-ai=stale,coderabbitai=stale,copilot-pull-request-reviewer=stale
RESULT_BOT_LEDGER: greptile-apps=0/0:none,cubic-dev-ai=0/0:none,coderabbitai=3/3:fixed relatedTools paths+scope-skipped:schema-refactor:1+scope-skipped:external-research:1,copilot-pull-request-reviewer=0/1:no-findings,codescene-delta-analysis=0/0:none
RESULT_ISSUES_SPAWNED: 847,848
RESULT_INFLIGHT_CHANGES: none
RESULT_STAGED_FILES: none
RESULT_UNSTAGED_FILES: none
RESULT_STAGED_DIFF_SHA: none
RESULT_UNSTAGED_DIFF_SHA: none
```

**Dispatcher state after Round 3:**

```
total_scope_skipped: 0 + 2 = 2  (well under cap of 5)
total_issues_spawned: 0 + 2 = 2  (well under cap of 3)
Invariant 4: pass (both under cap)
PRIOR_ATTEMPTS:
  - Round 3 (fix=2/5, wait=0/8): fixes=remove /blog/* paths from 4 relatedTools blocks; failures=none; acks=greptile-apps=stale,...; scope-skipped=2; spawned=2
```

**Round 4 (next worker dispatch).** Bots re-review `4361cc54`. CodeRabbit's prior threads are now resolved (worker closed them in Round 3); `scripts/ack-ledger.sh` tier A counts the resolved threads against HEAD-ack rather than `stale` (the change in this PR). All four bots clear, grind converges to `clean`, dispatcher hits COMPLETION.

**Total grind:** 4 rounds (was 7+ rounds + manual intervention before this carve-out existed). 2 dismissals consumed (under cap), 2 follow-up issues spawned (under cap). The two architectural findings live as `#847` and `#848` for separate PRs to address with proper scope.

**What would BAIL.** If the worker dismisses a 6th finding across the grind (cumulative cap ≤5 inclusive — 5 allowed, 6th BAILs), Invariant 4 fires at the start of the next round with `RESULT_BAIL_CATEGORY=judgment` and reason `out-of-scope dismissal count is 6 across N rounds — exceeds discipline rail of 5; operator review required`. Operator decides whether the PR's scope is wrong (split it) or the worker is misclassifying (interactive review of the dismissals). Same shape applies to the spawn cap: 3 spawns allowed, the 4th BAILs.

## Completion (post-loop, dispatcher only)

**All of these must be true before declaring done:**
1. Subagent returned `RESULT_STATUS=clean` (or inline mode reached the same state)
2. All required CI checks passing (build, lint, test)
3. All automated reviewers completed (CodeRabbit, Greptile, Cubic, etc.)
4. No unresolved actionable comments from any source
5. No new comments arrived after your last push (wait for the full cycle)
6. Advisory check issues either fixed or noted as beyond PR scope
7. **Reviewer ack ledger**: every registered bot (Greptile, Cubic, CodeRabbit, Copilot) is either `<HEAD-short-SHA>` or `none` in `RESULT_REVIEWER_ACKS`. Any `stale` entry blocks completion — the bot finished its check but hasn't re-reviewed HEAD yet, and merging now would race ahead of its findings. (`none` here can mean either "bot doesn't operate on this repo" OR "bot's only reviews are infra-error/rate-limit markers that cannot self-recover" — both are non-gating; see `scripts/ack-ledger.sh`'s infra-error downgrade.)

**Re-query the ack ledger fresh (REQUIRED — defense in depth against late posts between subagent return and merge time):**

The dispatcher must re-run the same `scripts/ack-ledger.sh` lookup the worker used in Step 6.5, against the live `/reviews` endpoint, with HEAD recomputed against the current branch state. Just re-parsing `$RESULT_REVIEWER_ACKS` would only validate the worker's snapshot — it can't catch a bot that finished re-reviewing in the seconds between subagent return and merge.

The `<PR_NUMBER>`, `<owner>`, `<repo>` placeholders below follow the same template-substitution convention as `<PR_NUMBER>` elsewhere in this Completion section — Claude substitutes the literal owner / repo / PR-number values at run time before executing the bash.

```bash
PR=<PR_NUMBER>
OWNER=<owner>
REPO=<repo>
HEAD_SHA=$(git rev-parse HEAD | cut -c1-8)

# One-shot fetches — same four sources as worker's Step 6.5.
# FETCH_OK tracks failure; fail-CLOSED to `stale` on any source failure.
FETCH_OK=1
ALL_THREADS=$(gh api graphql --paginate -f query='
  query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String) {
    repository(owner:$owner,name:$repo) {
      pullRequest(number:$pr) {
        reviewThreads(first:100, after:$endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            isResolved isOutdated
            comments(first:1) { nodes { author { login } } }
          }
        }
      }
    }
  }
' -f owner="$OWNER" -f repo="$REPO" -F pr="$PR" 2>/dev/null) || FETCH_OK=0
ALL_REVIEWS=$(gh api --paginate "repos/$OWNER/$REPO/pulls/$PR/reviews" 2>/dev/null) || FETCH_OK=0
ALL_COMMENTS=$(gh pr view "$PR" --comments --json comments 2>/dev/null) || FETCH_OK=0
# Source 5: check-runs on HEAD — same as worker/Step 6.5 fetch above.
ALL_CHECK_RUNS=$(gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_SHA/check-runs" 2>/dev/null) || FETCH_OK=0

# Per-bot ack — same single-sourced algorithm as the worker's Step 6.5 and
# the inline ledger block in Step 6.5 above. All three sites invoke
# scripts/ack-ledger.sh; algorithm edits live in that one file.
export FETCH_OK ALL_THREADS ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS HEAD_SHA
ACK_SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/ack-ledger.sh"
FRESH_ACKS="greptile-apps=$(bash "$ACK_SCRIPT" greptile-apps 2>/dev/null || echo stale),cubic-dev-ai=$(bash "$ACK_SCRIPT" cubic-dev-ai 2>/dev/null || echo stale),coderabbitai=$(bash "$ACK_SCRIPT" coderabbitai 2>/dev/null || echo stale),copilot-pull-request-reviewer=$(bash "$ACK_SCRIPT" copilot-pull-request-reviewer 2>/dev/null || echo stale)"
STALE_BOTS=$(echo "$FRESH_ACKS" | tr ',' '\n' | awk -F= '$2=="stale"{print $1}')
if [ -n "$STALE_BOTS" ]; then
  echo "❌ BLOCKED: registered reviewer(s) with stale ack at merge time: $STALE_BOTS"
  echo "   Re-run the loop or wait for the bot(s) to ack HEAD ($HEAD_SHA)."
  exit 1
fi
```

**Verify checks are green (REQUIRED — do NOT skip, even if subagent said clean):**
```bash
GH_EXIT=0
CHECKS_RAW=$(gh pr checks <PR_NUMBER> 2>&1) || GH_EXIT=$?
if [ "$GH_EXIT" -ne 0 ] && ! printf '%s\n' "$CHECKS_RAW" | grep -qE "pass|fail|pending"; then
  echo "❌ gh pr checks failed (exit $GH_EXIT). Resolve CLI/auth issues."
  exit 1
fi
ADVISORY_PATTERN="CodeScene"
REQUIRED=$(echo "$CHECKS_RAW" | grep -ivE "$ADVISORY_PATTERN" || true)
FAILED=$(echo "$REQUIRED" | grep -cE "fail" || true)
if [ "$FAILED" -gt 0 ]; then
  echo "❌ BLOCKED: $FAILED required checks still failing. Cannot declare PR clean."
  echo "$REQUIRED" | grep -E "fail"
  exit 1
fi
```

**Write the pr-grind-clean marker (REQUIRED — pre-merge gate checks `.claude/` at the REPO ROOT of the worktree the merge runs in):**
```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
mkdir -p "$REPO_ROOT/.claude"
echo "<PR_NUMBER>" > "$REPO_ROOT/.claude/pr-grind-clean.local"
rm -f "$REPO_ROOT/.claude/pr-pending-grind.local"
```

**Default: merge, then clean up the worktree (skip cleanup with `--no-worktree`):**
```bash
gh pr merge <PR_NUMBER> --squash --delete-branch

# Only return to a separate worktree and remove the ephemeral one if Step 0
# actually created it. With --no-worktree we ran in-place — there is no
# separate worktree to leave or remove.
if [ "${NO_WORKTREE:-0}" != "1" ]; then
  cd <original-worktree-path>
  git worktree remove "../pr-grind-<PR_NUMBER>" --force 2>/dev/null || true
fi
```

**If `--no-merge`: write marker to the repo root of the worktree the user will merge from, clean up, report ready (also `--no-worktree`-aware):**
```bash
# When --no-worktree, the dispatcher already runs in the user's worktree, so
# the marker target is the same repo root we're in — no cross-worktree copy.
if [ "${NO_WORKTREE:-0}" = "1" ]; then
  REPO_ROOT=$(git rev-parse --show-toplevel)
  mkdir -p "$REPO_ROOT/.claude"
  echo "<PR_NUMBER>" > "$REPO_ROOT/.claude/pr-grind-clean.local"
  rm -f "$REPO_ROOT/.claude/pr-pending-grind.local"
else
  ORIGINAL_REPO_ROOT=$(git -C <original-worktree-path> rev-parse --show-toplevel)
  mkdir -p "$ORIGINAL_REPO_ROOT/.claude"
  cp .claude/pr-grind-clean.local "$ORIGINAL_REPO_ROOT/.claude/pr-grind-clean.local"
  rm -f "$ORIGINAL_REPO_ROOT/.claude/pr-pending-grind.local"
  cd <original-worktree-path>
  git worktree remove "../pr-grind-<PR_NUMBER>" --force 2>/dev/null || true
fi
```

**Output (both modes):**
```text
## PR Grind Complete

PR #<N> is clean after <rounds> round(s).
- Model: <Sonnet (default) | Opus (--opus)>
- CI: all required checks passing
- Automated reviewers: all completed, no actionable findings
- Advisory checks: [fixed | N failing — noted as beyond PR scope]
- Human comments: all addressed
- Worktree cleaned up.
```

**Default:** append `- Merged.`

**With `--no-merge`:** append `- Ready for merge.`

## Arguments

| Argument | Description | Default |
|----------|-------------|---------|
| `<PR>` | PR number or URL | Auto-detect from current branch |
| `--max-fix N` | Maximum **fix-rounds** (worker pushed a commit; `RESULT_COMMIT_SHA != "none"`) before bail. Reflects engineering iteration budget. | 5 |
| `--max-wait N` | Maximum **wait-rounds** (worker did not push; `RESULT_COMMIT_SHA == "none"` — polling for slow bots to ack HEAD) before bail. Reflects bot-latency tolerance. | 8 |
| `--max N` | **Deprecated alias** that sets both `--max-fix` and `--max-wait` to N. Emits a `⚠️  --max is deprecated; use --max-fix and --max-wait` warning. Cannot be combined with `--max-fix` or `--max-wait` — combining bails with `conflicting flags`. | unset |
| `--opus` | Run rounds inline in parent Opus context (no Sonnet dispatch) | Off (dispatches Sonnet subagent) |
| `--interactive` | Pause for human confirmation each round (forces inline; subagent can't pause) | Off (autonomous) |
| `--no-worktree` | Skip worktree creation, work in current directory. Same behavior auto-engages without the flag if `git worktree add` reports the branch is already checked out elsewhere — see Step 0 fallback. | Off (creates worktree) |
| `--ci-only` | Only fix CI failures, ignore comments. Forces inline mode (Step 2 branching not yet wired into the subagent). | Off |
| `--no-merge` | Skip merge after grinding clean — just declare "Ready for merge" | Off (merges by default) |
| `--comments-only` | Only address comments, ignore CI. Forces inline mode (same reason as `--ci-only`). | Off |
| `--no-recovery-inline` | Disable the bounded RECOVERY_INLINE carve-out (Bug 2). When passed, any worker bail goes straight to BAIL regardless of inflight state or bail reason — useful when you want the worker's bail to surface immediately for human review and don't trust the dispatcher to commit-and-push on the worker's behalf. | Off (recovery enabled, capped at 1 per invocation) |

## User-Created Skip File

When the user wants to bypass the pre-merge gate (e.g., pr-grind stuck in a loop, or PR ready-enough and the user accepts the risk), they create `.claude/skip-pr-grind.local` manually in their terminal.

**Pre-merge specifics (different from other busdriver gates):**

- Skip file: `.claude/skip-pr-grind.local`
- Trigger: `gh pr merge`
- On <30s rejection: gate **deletes** the file (user must `touch` again).
- **Freshness window: 30s..3600s.** The gate silently deletes files ≥1h old without bypassing — the user has up to 1 hour between `touch` and the merge retry.

When emitting the verbatim message template (from the canonical protocol — see below), tell the user "the file must be touched within the last hour — the gate rejects ages of 3600s or more" so they don't sit on it indefinitely. Otherwise the protocol is identical to other gates: 35s `Monitor` wait, no Bash verification, NEVER create the skip file yourself, etc.

**Stale-file recovery (pr-grind only):** If `gh pr merge` blocks after the user has already run `touch` and Claude has waited the 35s, the skip file may have expired (≥3600s since `touch`). The gate silently deletes stale files without bypassing — there's no "stale" message. Ask the user to `touch` again and restart the 35s wait.

**Full protocol** — verbatim message template (with `<GATE>` substitution), `Monitor`-based 35s wait pattern, and hard rules — lives canonically in `skills/blueprint-review/SKILL.md` → "User-Created Skip File". The protocol is identical across all busdriver gates; only the pre-merge specifics in the bullets above differ.

## Integration

- **Pairs with:** `finishing-a-development-branch` (Phase 6 creates the PR and cleans up its worktree, then `/pr-grind` creates its own ephemeral worktree for the feedback loop)
- **Worktree lifecycle:** pr-grind owns its worktree from creation to cleanup — independent of the pipeline's Phase 3 worktree.
- **Gate:** Litmus pre-commit hook fires on each `git commit` within the loop (inside the subagent or inline); pre-merge gate fires on `gh pr merge` (skip: `.claude/skip-pr-grind.local`)
- **Subagent:** `pr-grinder` (Sonnet) — receives one-round dispatch, returns RESULT_* tags. See `agents/pr-grinder.md`.
