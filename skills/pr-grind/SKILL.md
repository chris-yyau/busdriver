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
- Required status checks: green — per `.github/required-checks.lock` `required[]` when present (allowlist mode: only those names block); otherwise all checks except `ADVISORY_PATTERN`/CodeScene (advisory-fallback mode). The lock is the single source of truth for both the pre-merge gate and pr-grind, computed by `scripts/relevant-check-status.sh`. **In allowlist mode, "green" means every lock-required check REPORTED green** — a required check with no run on this HEAD counts as pending, not as absent (#515). Non-reporting is the normal state of a `CONFLICTING` PR (GitHub stops firing `pull_request` workflows), and counting only the checks that did report let one still-posting app check certify a PR whose CI had never run. Consequence to know about: a required check that is legitimately never posted (a `paths`-filtered workflow with no dummy job) now blocks pr-grind rather than being ignored — which is what branch protection does anyway.
- Actionable findings on YOUR PR's changed lines: addressed (fix or justified reply)
- PR title/body: conventional commit + scope

**Bounded-wait advisory (best-effort, capped by `--max-wait`):**
- AI reviewer acks (CodeRabbit, Cubic, Greptile, etc.)

**External policy gates (NOT something pr-grind can resolve — surfaces to the operator):**

GitHub branch-protection settings encode org policy that pr-grind has no automated recourse for. Required `required_approving_review_count` is the canonical axis: the rules API can demand `N >= 1` human APPROVED reviews on the PR before merge, and a solo author cannot self-approve their own PR. The fix-rounds budget (`--max-fix`) and wait-rounds budget (`--max-wait`) are both irrelevant — there is nothing to fix and nothing to wait for; the gap is structural. When this is the sole remaining blocker (CI green, bots ack HEAD, threads resolved), the dispatcher BAILs with `RESULT_BAIL_CATEGORY=policy` and surfaces operator-decision options (see "Approver-Gap Detection" later in this file). pr-grind NEVER auto-bypasses org policy; the `--admin-on-approver-gap` flag is the explicit opt-in for the narrow case where the operator has admin/maintain permission AND the repo carries an audit workflow.

**Best-effort (low priority, addressed if fix budget allows — counts against `--max-fix`, not `--max-wait`):**
- Style/nit findings: typically fixed because the effort is low

**Invariant:** required status checks are the merge authority. AI reviewer acks are bounded-wait advisory signals — apps rate-limit, freeze, or fail; `--max-wait` is the backstop. On exhaustion the loop **bails to the operator** (does NOT silently merge AND does NOT wait forever). Never wait indefinitely for any single reviewer app. The infra-error downgrade in `scripts/ack-ledger.sh` (`ever_approved=0` defense) handles the specific case of a frozen review that the bot can't self-recover from; `--max-wait` is the broader safety net for slow-bot scenarios outside that pattern.

**Why:** helmet PR #35 stuck for a full session because a frozen Copilot review couldn't be classified by the pre-v1.30.1 ack ledger (introduced v1.29.1, PR #70). v1.30.1 added the body-text infra-error downgrade with the `ever_approved=0` admin-bypass guard (PR #77, three sub-commits); v1.31 extracted the algorithm into `scripts/ack-ledger.sh` for single-source maintenance + added a fail-CLOSED `|| echo stale` guard at the new call sites (PR #79); v1.33 added the `--max-wait` budget (PR #84). Codifying the principle prevents regression — a future "tighten the gate" PR must not reintroduce unbounded waits, must not silently merge past stale acks, and must not treat reviewer acks as co-equal with required checks.

## Architecture: Dispatcher + Per-Round Worker

This skill is a **thin Opus dispatcher**. The actual round work runs in a fresh `pr-grinder` subagent on Sonnet, dispatched once per round. This:

- Cuts cost ~5× by running mechanical fix work on Sonnet
- Flattens conversation context — each round starts with O(1) tokens instead of O(N) accumulation across rounds
- Keeps Opus available for orchestration: triage of subagent results, bail handling, merge decisions, and skip-file protocol

**This skill is two files.** The merge path — everything from `RESULT_STATUS=clean`
through the `pr-grind-clean.local` marker and `gh pr merge` — lives in
`references/completion.md`, and is **mandatory reading before any merge-path
action**. It is split out because it is ~48% of the document and is consulted
exactly once per grind, at the end; keeping it inline made every fix and wait
round re-read ~23k tokens of merge machinery it never uses. Read it when the
loop exits clean — not before, and never skip it.

## Anti-Patterns (DO NOT)

| Trap | Why it breaks the loop |
|------|----------------------|
| Looping rounds inside the subagent | Subagent contract is one round per dispatch. The dispatcher owns the loop. |
| Collecting feedback while checks are still pending | You'll miss reviewer findings, fix a partial set, push, and trigger a second review cycle unnecessarily |
| Declaring "Round complete" after push without waiting | The push triggers a new review cycle — you must wait for IT to finish before declaring done |
| Only waiting for CI (build/lint/test), ignoring reviewer bots | CodeRabbit, Cubic, Greptile are checks too — `gh pr checks` shows them as pending |
| Fixing pre-existing issues flagged by automated reviewers | Scope creep — only fix issues in YOUR changed code |
| Enabling GitHub auto-merge before pr-grind completes | The PR merges as soon as CI passes — before reviewer comments are addressed. pr-grind merges by default after all checks pass and comments are addressed. |
| Giving compound "grind then merge" instructions | Agent optimizes for merge as terminal goal, skipping CI wait. Just invoke `/pr-grind` — merge is the default. |
| Declaring PR clean without verifying check results | Checks completing (pass/fail/skip) ≠ checks passing — always verify status before writing the clean marker |

## Safety Rails

- **Max iterations:** Two independent budgets — **fix-rounds** (default 5, override with `--max-fix N`) cap how many dispatcher-owned fix commits can be pushed; **wait-rounds** (default 8, override with `--max-wait N`) cap how many polling rounds spent waiting for slow bots to ack HEAD. A round is classified as a *fix round* when `RESULT_COMMIT_SHA != "none"` and as a *wait round* otherwise. Bail when EITHER counter exhausts its budget. Both `--max-fix` and `--max-wait` must be `>= 1` — there is no "zero means unlimited" or "zero disables this class" form; if you want a larger budget, pass a larger number. The legacy `--max N` flag is accepted as a deprecated alias that sets both budgets to N (emits a deprecation warning). The split exists because under the old unified `--max`, every wait-round consumed a fix slot — so a PR with 3 fix iterations + 4 slow-bot polls would exhaust at MAX=5 even though only 3 fixes happened.
- **Autonomous by default:** Grinds without pausing between rounds
- **Merges by default:** After grinding clean, pr-grind merges the PR. Pass `--no-merge` to skip the merge and just declare "Ready for merge". This is NOT GitHub auto-merge — pr-grind merges *after* all checks pass and all comments are addressed, inside its own control flow.
- **Bail triggers:** Stop immediately and clean up worktree if:
  - A comment is a design/scope question (not a code fix)
  - CI fails on an unrelated flaky test 3 times in a row
  - The fix would require architectural changes
  - The fix would require rewriting published git history (force-push, `git commit --amend` on a pushed SHA, `git filter-branch`, interactive rebase on pushed commits)
  - Max fix-rounds reached (dispatcher pushed `MAX_FIX` fix commits without converging clean)
  - Max wait-rounds reached (slow bot(s) never acked HEAD within `MAX_WAIT` polling rounds)
  - External policy gap (branch protection requires `N >= 1` human APPROVED reviews the author cannot self-provide, org-level rule blocks merge, or similar non-resolvable structural blocker). Excluded from `MAX_FIX`/`MAX_WAIT` accounting — there is nothing to fix and nothing to wait for. Dispatcher emits `RESULT_BAIL_CATEGORY=policy`; the operator decides via the surfaced decision message (see "Approver-Gap Detection").
  - **On any bail:** if Step 0 created an ephemeral worktree, `cd` back and `git worktree remove "../pr-grind-<PR_NUMBER>" --force 2>/dev/null || true` before exiting. Skip when `NO_WORKTREE=1` — i.e. either `--no-worktree` was passed OR Step 0's auto-fallback engaged because the branch was already checked out. The `|| true` keeps cleanup idempotent if the worktree was already removed.
- **Out-of-scope-acknowledged discipline rails:** the worker can dismiss a finding on YOUR PR's changed lines with one of 6 enumerated reasons (`schema-refactor`, `external-research`, `follow-up-deferred`, `cross-cutting-style`, `pre-existing-on-touched-line`, `false-positive`) — see `agents/pr-grinder.md` Step 3. Three rails bound the carve-out: (a) worker per-round cap of ≤3 dismissals, self-enforced; (b) dispatcher cumulative cap of ≤5 dismissals across the whole grind (Invariant 4); (c) dispatcher cumulative cap of ≤3 follow-up issues spawned (Invariant 4). Hitting either dispatcher cap BAILs with `RESULT_BAIL_CATEGORY=judgment` regardless of round status. The default is FIX — dismissal is the carve-out. The rails exist precisely so workers can't relabel tedious-but-real findings as out-of-scope to "ship faster," leaving real bugs tracked-but-unaddressed in spawned follow-up issues.

## CWD Reset Across Bash Calls

**The Claude Code Bash tool does not reliably preserve CWD across tool calls.** Every NEW bash block added to this SKILL.md that touches the worktree MUST start with `cd "$WORKTREE_DIR"` (template-substituted to the literal absolute path resolved in Step 0). CWD inheritance can break on intervening Edit/Write/Read calls (verified empirically — interleaving non-Bash tool calls between Bash blocks can reset CWD to the session launch directory), subagent dispatches (each starts in whatever CWD the SDK chose, NOT necessarily the worktree), session boundaries (`/save-session` + `/resume-session` does not preserve CWD), and dispatcher↔worker handoffs (the dispatcher-owned commit block runs as its own fresh Bash process). Even when CWD happens to carry over between two back-to-back Bash calls, relying on it is fragile because the next intervening tool call breaks the chain silently. The failure mode is silent state corruption — commits land in the wrong repo, `gh` queries the wrong PR, file-writes land in the wrong location — not a loud error, which is the most expensive class of bug.

**Shell state — environment variables, aliases, functions, shell options — does NOT persist across Bash tool calls.** `export FOO=1` in one block does NOT survive into the next, even back-to-back. See "Resolve flag-to-state translations" in START for the template-substitution convention this SKILL.md uses for boolean flags (`ADMIN_FLAG_PASSED`, `NO_WORKTREE`) — Claude template-substitutes the literal 0/1 into each block before the bash executes.

**The rule (forward-looking):** every NEW bash tool call added to this SKILL.md that calls `git`, `gh`, or touches a worktree-relative path opens with `cd "$WORKTREE_DIR"`. The rule applies at Bash-tool-call boundaries, not to every embedded code-fence within a larger template. Pre-existing bash blocks in this SKILL.md predate this rule and rely on context-level CWD established by their parent dispatcher flow; they are not retroactively required to update.

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
  ├── Resolve flag-to-state translations (consumed by downstream bash blocks):
  │     ADMIN_FLAG_PASSED       = 1 if `--admin-on-approver-gap` was passed, else 0
  │     NO_WORKTREE             = 1 if `--no-worktree`             was passed, else 0
  │     REVIEWED_HEAD           = the full 40-char HEAD_FULL_SHA captured in the
  │                               classification block, carried forward to BOTH
  │                               Completion merge blocks as `--match-head-commit`
  │                               (#427) AND written as the second field of the
  │                               pr-grind-clean marker (#505). Remember the SHA the
  │                               acks were classified against — do NOT re-derive it
  │                               at merge time or at marker-write time; re-deriving
  │                               stamps a post-classification push as reviewed.
  │     # These are NOT exported as shell env vars — bash exports do NOT survive
  │     # across Claude Bash tool calls (each tool call gets a fresh shell). The
  │     # dispatcher (Claude) MUST remember each flag's resolved value in
  │     # conversation context and template-substitute the literal 0/1 into every
  │     # downstream Bash block that needs it. Concretely:
  │     #   - Completion's approver-gap caller block emits
  │     #     `ADMIN_FLAG_PASSED=<0|1 from above>` (literal value, NOT
  │     #     `${ADMIN_FLAG_PASSED:-0}` which always resolves to 0 in a fresh shell).
  │     #   - Step 0's auto-fallback and BAIL/COMPLETION cleanup branches read
  │     #     NO_WORKTREE from this state, NOT from `${NO_WORKTREE:-0}` env-fallback.
  │     # Same substitution convention as `<PR_NUMBER>` / `<owner>` / `<repo>`
  │     # template values used throughout this SKILL.md — Claude substitutes the
  │     # literal value at run time before executing the bash.
  └── Initialize: PRIOR_COMMIT_SHA=none, PRIOR_ATTEMPTS=[],
                   fix_round=0, wait_round=0,
                   round_number=0,
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
                   PRIOR_REVIEWER_ACKS="cubic-dev-ai=none,coderabbitai=none,greptile-apps=none",
                   PRIOR_CODEX_ACK="none"
                   # PRIOR_CODEX_ACK persists Codex's RESULT_CODEX_ACK across
                   # rounds (parallel to PRIOR_REVIEWER_ACKS), so the max-wait
                   # bail's STALE_AT_BAIL can name Codex when a Codex-only wait
                   # exhausts the budget. Reset per invocation.

LOOP (terminates when fix_round >= MAX_FIX OR wait_round >= MAX_WAIT):
  │
  ├── round_number += 1                  # pre-increment so ROUND=<N> is 1-indexed at dispatch time
  │
  ├── Dispatch a round:
  │     Agent(subagent_type="pr-grinder", prompt=<context block>)
  │     ↳ Subagent does ONE round (Steps 1–6.5), returns RESULT_* tags
  │
  ├── Parse subagent output (extract tags only — control flow is sequential):
  │     The worker owns triage and staging only. The dispatcher owns commit
  │     composition, litmus, commitlint, push, and
  │     post-push ack synthesis through `scripts/dispatcher-commit-block.sh`.
  │     Invariants still run before any terminal clean/continue decision.
  │
  │     RESULT_STATUS=clean       → eventually: invariants pass, go to COMPLETION
  │     RESULT_STATUS=bail        → break loop, go to BAIL
  │     RESULT_STATUS=needs_more  → route as fix-round or wait-round below
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
  ├── Dispatcher commit/state-synthesis block (post-inversion):
  │     Evaluate guards first:
  │       1. RESULT_STATUS=needs_more AND staged changes AND RESULT_FIXES empty
  │          → BAIL judgment ("inconsistent worker state").
  │       2. RESULT_STATUS=clean AND staged changes
  │          → BAIL judgment ("orphaned staged changes on clean round").
  │
  │     Routing:
  │       - RESULT_STATUS=needs_more + staged changes + RESULT_FIXES populated
  │         → Fix-round: invoke `scripts/dispatcher-commit-block.sh`.
  │       - RESULT_STATUS=needs_more + no staged changes
  │         → Wait-round: skip commit-block, refresh ack ledger only.
  │       - RESULT_STATUS=clean + no staged changes
  │         → Merge path; worker-emitted acks are authoritative for clean path.
  │       - RESULT_STATUS=bail
  │         → BAIL.
  │       - Any other RESULT_STATUS
  │         → BAIL judgment with reason `unrecognized RESULT_STATUS=<value>`.
  │
  │     Fix-round delegation:
  │       WORKTREE_DIR="$WORKTREE_DIR" \
  │       CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
  │       PR_NUMBER="$PR_NUMBER" \
  │       RESULT_STATUS="$RESULT_STATUS" \
  │       RESULT_FIXES="$RESULT_FIXES" \
  │       RESULT_REVIEWER_ACKS="${RESULT_REVIEWER_ACKS:-}" \
  │       RESULT_ACK_TIERS="${RESULT_ACK_TIERS:-}" \
  │       NO_WORKTREE="${NO_WORKTREE:-0}" \
  │       PRE_DISPATCH_BASELINE="${PRE_DISPATCH_BASELINE:-[]}" \
  │       BUSDRIVER_ALLOW_NO_COMMITLINT="${BUSDRIVER_ALLOW_NO_COMMITLINT:-0}" \
  │       bash "$CLAUDE_PLUGIN_ROOT/scripts/dispatcher-commit-block.sh"
  │
  │     Parse the last stdout line as exactly one JSON envelope:
  │       - Success: set RESULT_COMMIT_SHA, RESULT_REVIEWER_ACKS,
  │         RESULT_ACK_TIERS, AND RESULT_CODEX_ACK from
  │         `result_commit_sha` / `result_reviewer_acks` / `result_ack_tiers` /
  │         `result_codex_ack`. Every success envelope carries all four, and
  │         result_ack_tiers is ALWAYS computed from the SAME ack-ledger pass as
  │         result_reviewer_acks (ADR 0001 core invariant): fix-rounds and
  │         wait-rounds compute both freshly from the post-push / refresh
  │         ACK_EMIT_TIER=1 pass; the clean pass-through carries the worker's
  │         acks and tiers verbatim (one worker Step 6.5 pass). Because the two
  │         are same-pass, the dispatcher uses RESULT_ACK_TIERS directly — no
  │         reset, no fail-closed crutch. Invariant 3's bodyless-ack exemption
  │         then fires iff a registered bot acked the CURRENT HEAD via tier D
  │         (check-run) or E (commit-status) with n_total==0 — including on a
  │         fix/wait round where, e.g., cubic's check-run registers before
  │         slower bots (cubic=<sha> tier=D exempts; the others stay stale).
  │         Backward-compat: if `result_ack_tiers` is absent (legacy
  │         commit-block), reset RESULT_ACK_TIERS to the all-`none` default
  │         (fail-CLOSED — strict pre-ADR-0001 behavior).
  │         result_codex_ack is ALWAYS recomputed from the same post-push /
  │         refresh fetch pass as the registered bots (fix-rounds and
  │         wait-rounds) or passed through from the worker (clean path). This
  │         closes the fix-round staleness gap: without recomputing here, the
  │         dispatcher's PRIOR_CODEX_ACK would be the worker's pre-commit
  │         value, which predates the push. Backward-compat: if the
  │         `result_codex_ack` key is absent from the JSON envelope (legacy
  │         commit-block that predates Codex gating), the DISPATCHER preserves
  │         its stored RESULT_CODEX_ACK from the worker unchanged — old workers'
  │         Codex acks remain stale-until-next-round (same pre-fix behavior),
  │         not silently promoted to "none". Distinct from the commit-block
  │         input fallback in the "Outputs" section below, which describes what
  │         the script itself emits when the caller omits the RESULT_CODEX_ACK
  │         env var (a different layer: script output vs. dispatcher state).
  │       - Bail: set RESULT_BAIL_CATEGORY / RESULT_BAIL_REASON from
  │         `bail_category` / `bail_reason`, then go to BAIL.
  │
  ├── Invariant checks (fail-CLOSED — both must hold):
  │     1. If RESULT_STATUS=needs_more AND RESULT_COMMIT_SHA=none AND
  │        RESULT_REVIEWER_ACKS contains no `stale` entries AND
  │        RESULT_CODEX_ACK is not `stale` →
  │        BAIL with reason "subagent emitted needs_more without a commit
  │        SHA and without any stale ack — neither a fix nor a wait-for-
  │        bots is justified, so the loop has no progress signal".
  │        Legitimate `needs_more` rounds always have either a new commit
  │        SHA (dispatcher pushed a fix) OR at least one `stale` ack — a
  │        registered bot in RESULT_REVIEWER_ACKS, OR Codex via
  │        RESULT_CODEX_ACK=stale (Codex is gated but tracked outside
  │        RESULT_REVIEWER_ACKS, so a Codex-only wait-round — all three
  │        registered bots acked HEAD but Codex is still reviewing — is
  │        legitimate and must NOT be misread as no-progress). A round with
  │        none of these is broken — re-dispatching would loop forever on no
  │        progress. (Backward-compat: a worker that omits RESULT_CODEX_ACK
  │        leaves it empty, which is `!= stale`, so the check reduces to its
  │        prior registered-bot-only behavior.)
  │        Note: a bot whose review was downgraded to `none` by the
  │        infra-error path (see scripts/ack-ledger.sh) will not appear as
  │        `stale`. If that downgraded bot was the ONLY reason the worker
  │        considered the round incomplete, the worker should return
  │        `clean` (or `bail`), not `needs_more` with all-`none` acks —
  │        the invariant correctly catches that misuse.
  │     2. If RESULT_STATUS=clean AND (any registered bot in
  │        RESULT_REVIEWER_ACKS has value `stale` OR RESULT_CODEX_ACK
  │        is `stale`) →
  │        BAIL with reason "subagent reported clean but reviewer ack
  │        ledger has stale entries: <list>" (include `chatgpt-codex-connector`
  │        in <list> when RESULT_CODEX_ACK=stale). Slow-Cubic / slow-CodeRabbit
  │        race protection — clean cannot ship while a registered bot OR
  │        Codex hasn't acked HEAD. Codex is checked here even though it lives
  │        outside RESULT_REVIEWER_ACKS (its clean signal is a Tier-F reaction,
  │        not a SHA-keyed structured ack — see RESULT_CODEX_ACK in the tag set).
  │        Backward-compat: a worker that omits RESULT_CODEX_ACK leaves it empty
  │        (`!= stale`), reducing this to its prior registered-bot-only behavior.
  │     3. Bot-ledger coverage gate (Bug 1 — prose-review enumeration):
  │        For every bot in the **intersection** of RESULT_REVIEWER_ACKS
  │        and RESULT_BOT_LEDGER whose ack value is a <short-sha>
  │        (acked HEAD) — i.e., the bot definitely reviewed something
  │        on this PR AND has an enumeration entry — that ledger entry
  │        MUST have `n_total >= 1`. A `0/0` ledger entry for a
  │        HEAD-acked bot means the worker didn't enumerate the bot's
  │        body; merging would risk a Codex-style prose coverage gap
  │        (PR with buried actionable findings the worker silently
  │        skipped).
  │
  │        **Asymmetry: ledger and ack registry are not 1:1.** The
  │        ledger includes `codescene-delta-analysis` (it posts findings
  │        as Source 2 review threads) while the ack registry does not
  │        (codescene has no /reviews entries, so its HEAD-ack signal
  │        doesn't go through scripts/ack-ledger.sh). For ledger entries
  │        whose login is NOT in RESULT_REVIEWER_ACKS, this invariant
  │        does not apply — codescene and chatgpt-codex-connector are
  │        enumerated for content but their coverage is gated through the
  │        worked-example "always include codescene and
  │        chatgpt-codex-connector in the default ledger" rule, not through this
  │        invariant. The intersection rule keeps Invariant 3 strictly
  │        scoped to the three registered ack-bots that the worker can
  │        cross-correlate.
  │
  │        Parse RESULT_BOT_LEDGER as comma-separated entries of shape
  │        `<login>=<n_actionable>/<n_total>:<disposition>`.
  │
  │        **Defensive count check FIRST.** The known-bot set is fixed
  │        (5 bots: `cubic-dev-ai`, `coderabbitai`, `greptile-apps`,
  │        `codescene-delta-analysis`, `chatgpt-codex-connector`).
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
  │          - if n_total == 0:
  │              **Bodyless-ack exemption (ADR 0001).** Look up the bot's
  │              tier in RESULT_ACK_TIERS (worker tag; parse as
  │              comma-separated `<login>=<tier>`, tier ∈ {A,B,C,D,E,none}).
  │                - if tier is `D` or `E` → PASS. The HEAD-ack came from a
  │                  bodyless structured signal (D=check-run, E=commit-status)
  │                  with no enumerable Source 2/3/4 body — e.g., a
  │                  clean-only check-run bot. By ack-ledger's tier order (A→E,
  │                  first hit wins), reaching D/E proves the bot has zero
  │                  live Source-2 inline threads, so this exemption cannot
  │                  mask an inline finding. See agents/pr-grinder.md Step 2.6
  │                  "Bodyless check-run/status acks".
  │                - otherwise (tier A/B/C, tier `none`, RESULT_ACK_TIERS
  │                  missing, OR the bot's tier missing/unknown —
  │                  **fail-CLOSED**) → BAIL with reason "worker did not
  │                  enumerate findings for <bot> despite ack on <short-sha>
  │                  (tier <tier-or-?>) — possible prose-review coverage gap;
  │                  manual review required".
  │                  A body-bearing tier (A/B/C) with n_total==0 is a genuine
  │                  enumeration gap. Tier `none` (or a missing tier map) on a
  │                  HEAD-acked bot should NOT happen under same-pass computation
  │                  — acks and tiers always come from one ack-ledger pass, so a
  │                  HEAD-sha ack is always paired with a D/E (or A/B/C) tier. It
  │                  can only arise from a legacy commit-block that emits no
  │                  `result_ack_tiers` (dispatcher defaults to all-`none`) or a
  │                  degraded post-push fetch (all-`stale` acks + all-`none`
  │                  tiers — but then the ack is `stale`, not a HEAD-sha, so this
  │                  branch isn't reached). In every one of these cases the
  │                  strict pre-ADR-0001 behavior (always bail) is the safe
  │                  default.
  │          - if n_total >= 1 → pass (worker enumerated; disposition
  │            is its decision)
  │
  │        `stale` and `none` ack values do NOT trigger this gate —
  │        `stale` means bot hasn't re-reviewed yet (Invariant 2 already
  │        gates on this for clean status); `none` means bot never posted,
  │        or only posted infra-error markers, or acknowledged HEAD via a
  │        check-run with conclusion=skipped and non-actionable body. The
  │        matching ledger shapes are `<bot>=0/0:none` for bots that posted
  │        nothing, OR `<bot>=0/N:no-findings` for bots whose N>=1 artifacts
  │        were Case-1/2/3 downgraded with zero actionable findings (per
  │        the n_actionable/n_total contract at pr-grinder.md:200). Only
  │        HEAD-acked bots
  │        prove a body exists that should have been enumerated.
  │
  │     4. Discipline rails — cumulative caps for the out-of-scope-
  │        acknowledged flow (see agents/pr-grinder.md Step 3
  │        "Out-of-Scope-Acknowledged Workflow").
  │
  │        Runs on EVERY round status, including `clean` AND `bail`
  │        (Invariants 1-3 run on `needs_more`/`clean` only — see the
  │        "Parse subagent output" comment above; Invariant 4 is the
  │        explicit exception). Accumulated breaches block ship even
  │        when this round's classification is clean, AND surface
  │        operator-visible context when the worker over-dismisses
  │        findings and then bails — a worker that dismisses 5+
  │        findings must still surface to the operator regardless of
  │        whether it ultimately declared clean or bailed.
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
  ├── Codex first-engagement nudge on the CLEAN path (one-shot per HEAD) — issue #467.
  │     # Fire the `none`-case nudge the INSTANT a round converges to clean, decoupled
  │     # from the COMPLETION merge machinery. Be precise about the gap this closes:
  │     # within a faithful top-to-bottom COMPLETION run the nudge ALREADY precedes the
  │     # Branch-Currency (BEHIND) and Approver-Gap bails (in references/completion.md,
  │     # document order: nudge < BEHIND < approver-gap), so ordering-within-COMPLETION is not the
  │     # bug. The bug is that COMPLETION can be SKIPPED WHOLESALE: a dispatcher that
  │     # front-runs a cheap read-only merge-state probe (`gh pr view --json
  │     # mergeStateStatus` + relevant-check-status.sh) to pick the merge path, sees a
  │     # terminal BEHIND / approver-gap, and surfaces that decision WITHOUT ever entering
  │     # COMPLETION — so COMPLETION's nudge never runs and a never-engaged Codex is
  │     # silently skipped on exactly the PRs that end in an operator bail. Firing here,
  │     # before any merge-path branching, makes the nudge independent of that shortcut;
  │     # the bounded grace POLL stays in COMPLETION (it only matters right before merge).
  │     # Safe against the COMPLETION re-nudge: codex-retrigger.sh's one-shot per-(PR,HEAD)
  │     # marker dedupes the POST, so at most one `@codex review` is ever posted per HEAD.
  │     # COST (stated honestly, per the #467 review): on a clean `none` round this block runs
  │     # the wrapper's detection (`gh repo view` + the Codex-active GraphQL probe) ONCE, and
  │     # COMPLETION later re-derives active-ness independently — so a Codex-active / force-on
  │     # repo pays ONE extra codex-active probe per clean-none merge vs. pre-#467. This is a
  │     # deliberate, bounded tradeoff: the marker dedupes the POST (never a double `@codex
  │     # review`), but NOT the detection, because COMPLETION needs genuine active-ness for its
  │     # "engaged on recent PRs" warning + full-grace wait and a nudge-marker cannot supply
  │     # that (it conflates force-on/kill-switched with historical activity). A detection-result
  │     # breadcrumb WOULD remove the extra probe but is not worth another per-HEAD state
  │     # artifact + arg plumbing on an already network-heavy merge path (codex-rescue concurred).
  │     # The kill-switch gate below zeros BOTH probes for a Codex-less repo that sets
  │     # PR_GRIND_CODEX_RETRIGGER=0 (Codex integration off) — the same switch gates COMPLETION's
  │     # detection. Force-on repos under the kill switch are still covered by COMPLETION's
  │     # force-on path when it is reached.
  │     # Guard uses the worker-emitted RESULT_CODEX_ACK: on the clean path Invariant 2
  │     # already proved it is not `stale`, so it is a <short-sha> (Codex engaged — no
  │     # nudge) or `none` (never engaged — nudge). Empty (legacy worker) is `!= none`,
  │     # so old-contract workers no-op exactly as before.
  │     If RESULT_STATUS == clean AND RESULT_CODEX_ACK == "none" AND the Codex kill switch
  │        is off (`${PR_GRIND_CODEX_RETRIGGER:-1}` != "0"), run this block BEFORE
  │        proceeding to COMPLETION. Per the "CWD Reset Across Bash Calls" contract it
  │        MUST open with `cd "$WORKTREE_DIR"` (template-substituted Step 0 path; the repo
  │        root under --no-worktree) so the wrapper's CWD-derived force-on root and the
  │        delegated CWD-relative marker resolve against the PR's own repo. `$PR_NUMBER`
  │        is the Step 0 literal; HEAD is read inside the correct worktree after the cd.
  │        CONTAIN gh routing FIRST (issue #470 P1 / #416): a committed .claude/settings.json
  │        `env` block is repo-controlled, and GH_HOST / GH_REPO steer OUTBOUND credentialed
  │        `gh` calls — GH_HOST sends them to an arbitrary host, GH_REPO re-points the target
  │        repo. So the subshell PINS the host and CLEARS the repo override before any `gh`
  │        runs (covering the wrapper's delegated codex-active-repo.sh / codex-retrigger `gh`
  │        calls too), exactly as codex-nudge-premerge.sh:85-102 does. This routing pin is
  │        deliberately scoped to the nudge, NOT extended dispatcher-wide: the dispatcher runs
  │        in the operator session's ambient env, which a poisoned settings.json compromises
  │        wholesale (PATH/BASH_ENV, every Bash call), so a broad env wrapper would be false
  │        assurance — accepted residual, ADR 0026 (#475). Do NOT derive the repo
  │        from an ambient `gh repo view` — that call is itself routable by GH_REPO/GH_HOST;
  │        pass the dispatcher-resolved `<owner>/<repo>` PR metadata (same template values the
  │        context block and COMPLETION use). owner/repo is passed so codex-active-repo.sh can
  │        auto-detect — an empty repo arg is treated as inactive, silently dropping auto-detect
  │        to force-on-only. The subshell ABORTS on a bad worktree (`|| exit 0`); the outer
  │        `|| true` keeps a failed nudge from ever blocking the clean path:
  │          ( cd "$WORKTREE_DIR" || exit 0
  │            export GH_HOST=github.com; unset GH_REPO
  │            bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-nudge-if-expected.sh" "$PR_NUMBER" \
  │              "$(git rev-parse HEAD)" "<owner>/<repo>" || true )
  │
  ├── Classify round and increment the appropriate counter:
  │     # ONLY runs on RESULT_STATUS=needs_more — bail and clean rounds skip this
  │     # block via the earlier branch in "Parse subagent output". This is
  │     # intentional: bail terminates the loop (no future round to budget for)
  │     # and clean ships the PR (same — no future round). Only needs_more
  │     # rounds consume budget because only they cause another dispatch.
  │     If RESULT_COMMIT_SHA != "none" → fix_round  += 1   # dispatcher pushed a fix
  │     If RESULT_COMMIT_SHA == "none" → wait_round += 1   # worker waiting for bots
  │     # Classification reads RESULT_COMMIT_SHA, not the alias RESULT_HEAD_SHA —
  │     # the dispatcher's tag-resolution step already canonicalized aliases
  │     # before this point (see "Resolution order" in Dispatch a Round below).
  │
  │     # Codex sole-stale-blocker auto-re-trigger (one-shot per HEAD) — ADR 0005.
  │     # On this WAIT-round (RESULT_COMMIT_SHA == "none", so HEAD is unchanged)
  │     # where Codex is the SOLE stale ack — RESULT_CODEX_ACK == "stale" AND no
  │     # registered bot in RESULT_REVIEWER_ACKS is "stale" (they all acked HEAD) —
  │     # Codex will never self-ack the unchanged HEAD (it posts COMMENTED reviews /
  │     # 0 reactions; its thread resolutions predate the push, Tier-A.2 fail-closed),
  │     # so the next wait-rounds would just burn --max-wait and BAIL. Post `@codex
  │     # review` ONCE so Codex re-reviews HEAD before the next round (→ fresh
  │     # 👍/Tier-F ack → converge, or new findings → worker triages). The helper is
  │     # idempotent (one-shot marker per (PR,HEAD)) so this is safe even though the
  │     # worker's Step 6.5 mirrors the same call. Opt out: PR_GRIND_CODEX_RETRIGGER=0;
  │     # phrase override (forks): PR_GRIND_CODEX_RETRIGGER_PHRASE. `|| true` keeps a
  │     # failed post from ever staling the gate. Distinct from the COMPLETION
  │     # first-engagement grace, which only RE-POLLS a `none` Codex (never a `stale`).
  │     If RESULT_COMMIT_SHA == "none" AND RESULT_CODEX_ACK == "stale"
  │        AND RESULT_REVIEWER_ACKS has no `stale` entry, run this block. Per the
  │        "CWD Reset Across Bash Calls" contract it MUST open with `cd "$WORKTREE_DIR"`
  │        (template-substituted to the literal Step 0 path — do NOT rely on shell-var
  │        persistence or on the inherited CWD; `$PR_NUMBER` is likewise the Step 0
  │        literal, and HEAD is read inside the correct worktree after the cd). The
  │        cd runs in a subshell and ABORTS on failure (`|| exit 0`) so a bad
  │        WORKTREE_DIR never lets git/gh run in the wrong repo:
  │          ( cd "$WORKTREE_DIR" || exit 0
  │            bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-retrigger.sh" "$PR_NUMBER" "$(git rev-parse HEAD)" || true )
  │
  └── Update state:
        PRIOR_COMMIT_SHA    = RESULT_COMMIT_SHA
        PRIOR_REVIEWER_ACKS = RESULT_REVIEWER_ACKS
        PRIOR_CODEX_ACK     = RESULT_CODEX_ACK   # on fix/wait-rounds: overwrite with result_codex_ack from commit-block envelope (post-push); on clean path: use worker-emitted value. Backward-compat: if result_codex_ack absent from envelope (legacy commit-block), retain worker RESULT_CODEX_ACK unchanged — do NOT default to "none" (that would lose a stale signal from the worker).
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
# marker here would silently merge an unfinished PR. EXCEPTION: the
# wait_round >= MAX_WAIT branch below may still route to COMPLETION, but only
# via the explicit, condition-gated, logged ADR 0012 downgrade path (step 5) —
# never as a bare "ran out of attempts" fallthrough. Absent that opt-in/gate
# chain, exhaustion still fails closed to BAIL exactly as this paragraph says.
ON_LOOP_EXHAUSTED — two flavors, branch on which counter overflowed.
                     Both flavors emit RESULT_BAIL_CATEGORY=budget — this is the
                     dispatcher-only enum value documented in agents/pr-grinder.md
                     "Bail Triggers" (workers never emit `budget`; only the dispatcher
                     knows about MAX_FIX/MAX_WAIT exhaustion).
  fix_round  >= MAX_FIX   → BAIL with reason "max-fix iterations (<MAX_FIX>) reached without clean status",
                          RESULT_BAIL_CATEGORY=budget
  wait_round >= MAX_WAIT  → derive STALE_AT_BAIL from PRIOR_REVIEWER_ACKS AND PRIOR_CODEX_ACK
                          (both persisted in the Update state block above): the comma-separated list of
                          registered bot logins whose ack value is the literal string `stale`, PLUS
                          `chatgpt-codex-connector` when PRIOR_CODEX_ACK is `stale` (Codex lives outside
                          PRIOR_REVIEWER_ACKS, so a Codex-only wait would otherwise produce an empty list
                          and read as a classification bug).

                          ── ADR 0012: bounded advisory-bot stale-ack timeout downgrade (issue #295) ──
                          BEFORE bailing, attempt a bounded, logged, fail-CLOSED downgrade of the
                          stale advisory acks. This releases a green PR that is held hostage only
                          because a bot reviewed an old SHA, found nothing, and never re-acked HEAD
                          (e.g. Codex/Devin after a rebase). It NEVER touches merge authority — required
                          checks + litmus still gate; this only releases the *advisory* ack after those
                          are already green. Treats ALL registered advisory bots uniformly (no per-bot
                          special-casing — Codex and Cubic/Coderabbit/Greptile are aligned).

                          1. Opt-in gate: run the resolver and proceed ONLY if it prints `1`:
                             `OPTIN=$(bash "<PLUGIN_ROOT>/scripts/advisory-downgrade-optin.sh")`.
                             It returns `1` iff the per-repo file
                             `<STATE_DIR>/pr-grind-advisory-downgrade.local` (`<STATE_DIR>` =
                             `${BUSDRIVER_STATE_DIR:-.claude}`) is present at the main-repo root AND
                             accepted as operator consent — a non-repo-controlled (not in index/HEAD,
                             not gitlinked), non-symlink regular file (ADR 0012 boundary). There is NO
                             global env-var / global-file switch by design (both are repo-injectable —
                             see ADR 0012); to opt in many repos the operator drops the per-repo file
                             into each with a trusted loop, or runs `scripts/enable-advisory-downgrade.py`
                             (the hardened bulk enroller from #326 — openat+O_NOFOLLOW writes, acceptance
                             delegated back to this resolver).
                             Fail-CLOSED: `0` — not opted
                             in, or the resolver could not confirm/query the repo root — → skip to BAIL
                             below (unchanged). Run it from inside the PR's worktree so the per-repo
                             lookup's main-repo root is the PR's own repo (same CWD contract as the
                             sibling opt-ins).
                          2. Global green gates (fail-CLOSED — any not provably true → skip to BAIL):
                             - CI_GREEN: required status checks green per `scripts/relevant-check-status.sh`.
                             - LITMUS_GREEN: a fresh litmus PASS bound to the current HEAD `base...HEAD`
                               diff_hash (the pre-PR PASS artifact; a stale/missing artifact fails closed).
                          3. Assemble CANDIDATES — for each STALE_AT_BAIL bot (registered bots AND
                             `chatgpt-codex-connector` when Codex is the stale one), gather:
                               `login:unresolved_threads:actionable_findings:last_state:stale_sha:ever_changes_requested:engaged_signal`
                             where `actionable_findings` = that login's `n_actionable` from
                             RESULT_BOT_LEDGER, `unresolved_threads` = a fresh Source-2
                             unresolved+non-outdated thread count for that bot on HEAD (the same query
                             ack-ledger Tier A.1 uses), `last_state` = the bot's last /reviews state,
                             `stale_sha` = the SHA its stale review targets, `ever_changes_requested` = 1
                             iff ANY review in the bot's FULL `/reviews` history (not just the latest) was
                             CHANGES_REQUESTED or DISMISSED — mirrors `ack-ledger.sh`'s own
                             `[CHANGES_REQUESTED, COMMENTED]` guard (a later non-blocking review does not
                             erase an earlier raised concern) and satisfies ADR 0012 precondition 8.
                             `engaged_signal` = 1 iff the bot has a live non-thread engagement marker that
                             `ack-ledger.sh` gates on ahead of every tier — concretely,
                             `chatgpt-codex-connector`'s hoisted 👀-reaction override (a current 👀 means
                             Codex is actively re-reviewing HEAD *right now*, forced `stale` regardless of
                             thread/review state). 0 for every bot without such a signal (always 0 for
                             non-Codex logins today; re-use `ALL_REACTIONS` already fetched for Codex's Tier
                             F check rather than an extra API call). A live `engaged_signal` means this
                             bot's `stale` classification is not the "reviewed an old SHA, found nothing,
                             never re-acked" case ADR 0012 targets — releasing it now would race a review in
                             progress, so `advisory-stale-downgrade.sh` keeps it stale when `engaged_signal=1`.
                             **`actionable_findings=0` evidence requirement (fail-CLOSED):** only assemble
                             a bot into CANDIDATES with `actionable_findings=0` when its RESULT_BOT_LEDGER
                             entry is `0/N:no-findings` with `N >= 1` (a genuinely enumerated body with no
                             findings) — NOT `0/0:none`. A `0/0:none` entry means the bot's body was never
                             enumerated (default ledger value, early-bail output, or a parser miss), which
                             is not proof the bot reviewed and found nothing; Invariant 3 only requires
                             `n_total >= 1` for HEAD-acked bots, so a stale bot's `0/0:none` is otherwise
                             unprotected. Skip (do not assemble) any bot whose ledger entry doesn't meet
                             this bar — it stays in STALE_AT_BAIL and falls through to BAIL below.
                          4. Call the single source of truth (pass BYPASS_LOG EXPLICITLY as a
                             main-repo-root-anchored absolute path — the script's default is
                             CWD-relative `.claude/bypass-log.jsonl`, which lands in the wrong place
                             when BUSDRIVER_STATE_DIR is set or the CWD is a worktree/subdir).
                             First anchor the event clock to GitHub's, NOT the operator's — the logged
                             `timestamp` is later compared against GitHub activity timestamps by the
                             revalidator, so a skewed local clock would fail OPEN (issue #302):
                             `SERVER_NOW=$(bash "<PLUGIN_ROOT>/scripts/github-server-now.sh")`
                             (empty on any gh/parse failure → the call below fails CLOSED and downgrades
                             nothing — the safe direction). Then:
                             `DOWNGRADED=$(SOLO_OPTIN=1 CI_GREEN=<0|1> LITMUS_GREEN=<0|1> HEAD_SHA=<sha> \
                               SERVER_NOW="$SERVER_NOW" \
                               PR=<PR_NUMBER> REPO=<owner/repo> WAIT_ROUNDS=<MAX_WAIT> \
                               BYPASS_LOG="<MAIN_REPO_ROOT>/<STATE_DIR>/bypass-log.jsonl" \
                               CANDIDATES=<assembled> bash "<PLUGIN_ROOT>/scripts/advisory-stale-downgrade.sh")`
                             It re-checks every condition, emits one `advisory_stale_timeout_downgrade`
                             JSONL event per released bot to `<STATE_DIR>/bypass-log.jsonl`, and prints the
                             comma-separated logins it released (empty = nothing eligible). It downgrades
                             `stale → none` (NEVER `→ approved`): the ledger records the signal expired
                             cleanly, not that the bot approved HEAD.
                          5. If DOWNGRADED covers EVERY stale blocker in STALE_AT_BAIL (i.e. no stale
                             advisory bot remains and Codex is either acked or in DOWNGRADED) → treat those
                             acks as `none` and go to COMPLETION with DOWNGRADED_BOTS=<DOWNGRADED> so
                             COMPLETION's ack-recompute honors the release instead of re-deriving `stale`
                             (see COMPLETION) and so the released list is surfaced in the operator-facing
                             completion message and audit trail. ⚠ The `pr-grind-clean.local` marker itself
                             MUST stay exactly `<PR_NUMBER> <HEAD_SHA>` regardless — it does NOT carry
                             DOWNGRADED_BOTS or any other content (see COMPLETION's marker note; the durable
                             record of the release lives in `bypass-log.jsonl`, not the marker). Otherwise fall
                             through to BAIL — a bot with live findings, a failed green gate, or the missing
                             opt-in all keep the PR blocked exactly as before.

                          Then BAIL with reason
                          "max-wait iterations (<MAX_WAIT>) reached without all bots acking HEAD;
                          latest stale: <STALE_AT_BAIL>" (or "<none>" if neither any registered bot nor
                          Codex is stale — which would itself be diagnostic, since exhausting wait-rounds
                          without any stale acks suggests a bug in the round-classification logic, not
                          a slow bot), RESULT_BAIL_CATEGORY=budget.
  # If both counters happen to overflow on the same round (impossible by
  # construction — only one increments per round — but defensive), prefer
  # the fix-round message since fix-rounds represent active engineering
  # progress that the operator likely cares about more.
  # NOTE on persistence: STALE_AT_BAIL is derived from PRIOR_REVIEWER_ACKS and
  # PRIOR_CODEX_ACK, NOT from Step 6.5's transient $STALE_BOTS bash variable —
  # that variable lives only inside the bash invocation that runs the ledger
  # snippet and does not survive into the dispatcher's bail handler. Both
  # PRIOR_REVIEWER_ACKS and PRIOR_CODEX_ACK ARE persisted across rounds (updated
  # in the Update state block above on every needs_more round), so parsing their
  # `stale` entries at bail time gives a reliable answer.

COMPLETION:
  ├── Verify checks one more time (defense in depth)
  ├── Recompute ack ledger and assert all entries are <HEAD-SHA> or `none`
  │   (defense in depth — invariant check 2 already gated this, but the
  │   bot may have re-posted between subagent return and merge time).
  │   ADR 0012: when reached via the bounded stale-ack downgrade path, treat
  │   every login in DOWNGRADED_BOTS as `none` for this assertion — the release
  │   was already condition-checked and logged by advisory-stale-downgrade.sh; a
  │   naive recompute would re-derive `stale` (the bot's posted state is
  │   unchanged) and falsely re-block. A bot NOT in DOWNGRADED_BOTS that is now
  │   `stale` still blocks (it re-posted or was never released) → back to BAIL.
  ├── Write .claude/pr-grind-clean.local at repo root. ⚠ The marker MUST stay exactly
  │   TWO whitespace-separated fields — `<PR_NUMBER> <HEAD_SHA>` (#505). `pre-merge-gate.sh`
  │   reads field 1 as the PR (any non-digit ⇒ corrupt: marker deleted, merge blocked) and
  │   field 2 as the 40-hex commit the grind actually validated, which it compares against
  │   the PR's live `headRefOid` (mismatch or missing ⇒ blocked). Adding a third field is
  │   harmless to the parser but the SHA must never move off field 2.
  │   So NEVER write the released-bot list into the marker. ADR 0012 anti-laundering
  │   instead lives in the audit trail: advisory-stale-downgrade.sh has already
  │   written one `advisory_stale_timeout_downgrade` event per released bot to
  │   <STATE_DIR>/bypass-log.jsonl (the durable record that `clean` was reached via
  │   a bounded release, not "all advisors approved HEAD"). Additionally surface the
  │   released list (DOWNGRADED_BOTS) to the operator in the completion message so
  │   the release is visible, never silent.
  ├── default → gh pr merge --squash --delete-branch
  ├── --no-merge → write marker to original-worktree repo root, report ready
  └── Cleanup ephemeral worktree (skip if NO_WORKTREE=1)

BAIL:
  └── Cleanup ephemeral worktree (skip if NO_WORKTREE=1), surface RESULT_BAIL_REASON to user
```

## Step Details

### Step 0: Create Ephemeral Worktree

Create an isolated worktree so the user's main workspace stays free for their next task.

```bash
# Capture pr-grind invocation start time BEFORE any other operation. The
# solo-admin opt-in freshness check (snapshot writer near the end of this
# block) anchors against this timestamp, not NOW_EPOCH at snapshot time —
# otherwise a slow `gh pr view` / `git worktree add` could push elapsed
# time past 30s and let an opt-in file created mid-invocation satisfy the
# anti-self-bypass gate it's supposed to defeat.
INVOCATION_START_EPOCH=$(date +%s)

# Base-branch guard — refuse to grind a PR whose base is not one of the
# canonical trunks unless the operator explicitly opted in (stacked-PR
# workflows, long-lived feature integration branches). A non-trunk base
# can cause pr-grind to merge "successfully" into a closed-PR branch
# while leaving main untouched — a silent failure (state=MERGED still
# returned by the GitHub API) that costs a recovery cycle to detect.
#
# Two escape hatches (matching the busdriver gate convention):
#   1. File:    .claude/skip-baseref-check.local (touched in the user's terminal)
#   2. Env var: PR_GRIND_ALLOW_NON_MAIN_BASE=1 (exported in the PARENT shell
#              BEFORE launching claude — inline `PR_GRIND_ALLOW_NON_MAIN_BASE=1
#              claude` does NOT work because hooks fire before inline env applies,
#              same caveat as SKIP_LITMUS).
#
# Capture stderr so auth/network errors are surfaced in the bail message
# instead of being swallowed by `2>/dev/null`.
BASE_BRANCH_ERR=$(mktemp)
BASE_BRANCH=$(gh pr view <PR_NUMBER> --json baseRefName -q '.baseRefName // empty' 2>"$BASE_BRANCH_ERR" || true)
# Normalize: strip CR/whitespace/control chars defensively. Use sed first
# to remove full ANSI escape sequences (ESC + printable tail like `[0m`)
# before tr strips any remaining control bytes; tr alone only removes the
# ESC byte (0x1B) and leaves the printable remnants attached to the value.
BASE_BRANCH=$(printf '%s' "$BASE_BRANCH" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g' | tr -d '[:space:][:cntrl:]')

if [ -f ".claude/skip-baseref-check.local" ] || [ "${PR_GRIND_ALLOW_NON_MAIN_BASE:-0}" = "1" ]; then
  BASEREF_BYPASS=1
else
  BASEREF_BYPASS=0
fi

# CRITICAL: if the case block below exits non-zero, the dispatcher MUST treat
# this as a hard BAIL — surface the error to the user and HALT pr-grind. Do
# NOT proceed to the worktree creation below or any subsequent step. This is
# the same exit-1 contract used by the worktree-add failure path further down.
case "$BASE_BRANCH" in
  main|master|develop) ;;  # canonical trunks — proceed
  "")
    echo "❌ Could not resolve baseRefName for PR <PR_NUMBER>."
    if [ -s "$BASE_BRANCH_ERR" ]; then
      echo "   gh stderr: $(tr -d '\r' < "$BASE_BRANCH_ERR" | head -c 400)"
    fi
    echo "   Check 'gh pr view <PR_NUMBER>' and network/auth."
    rm -f "$BASE_BRANCH_ERR"
    exit 1
    ;;
  *)
    if [ "$BASEREF_BYPASS" != "1" ]; then
      echo "❌ PR <PR_NUMBER> targets '$BASE_BRANCH', not a canonical trunk (main/master/develop)."
      echo "   Merging into a non-trunk branch can land the PR on a closed or stale base"
      echo "   while still returning state=MERGED — a silent failure mode (precedent: PR #122)."
      echo "   If this is intentional (stacked PR, long-lived feature branch), either:"
      echo "     - In your terminal: touch .claude/skip-baseref-check.local"
      echo "     - Or in the PARENT shell BEFORE launching claude: export PR_GRIND_ALLOW_NON_MAIN_BASE=1"
      echo "       (inline 'PR_GRIND_ALLOW_NON_MAIN_BASE=1 claude' does NOT work — same rule as SKIP_LITMUS)"
      rm -f "$BASE_BRANCH_ERR"
      exit 1
    fi
    echo "⚠️  PR <PR_NUMBER> targets '$BASE_BRANCH' (non-canonical) — proceeding via baseref bypass."
    ;;
esac
rm -f "$BASE_BRANCH_ERR"

PR_META=$(gh pr view <PR_NUMBER> --json headRefName,headRefOid,isCrossRepository)
PR_BRANCH=$(printf '%s' "$PR_META" | jq -r '.headRefName // empty')
PR_HEAD_SHA=$(printf '%s' "$PR_META" | jq -r '.headRefOid // empty')
# NOT `// empty` here: jq's `//` treats `false` as absent just like `null`, so
# the alternative would fire on every SAME-REPO PR (isCrossRepository=false) and
# hard-exit the common path. Read the field raw and validate it as a boolean.
PR_IS_FORK=$(printf '%s' "$PR_META" | jq -r '.isCrossRepository')
if [ -z "$PR_BRANCH" ] || [ -z "$PR_HEAD_SHA" ]; then
  echo "❌ could not resolve PR head ref/oid for <PR_NUMBER> — not proceeding."
  exit 1
fi
case "$PR_IS_FORK" in
  true|false) ;;
  *) echo "❌ isCrossRepository for <PR_NUMBER> was '$PR_IS_FORK', not a boolean — not proceeding."; exit 1 ;;
esac

# FORK PRs ARE NOT SUPPORTED — refuse before touching anything. This is a hard
# stop, not a limitation to route around.
#
# `headRefName` is chosen by the PR's source repository and is NOT
# repository-qualified: a fork can name its branch `main`. Any path that maps
# that name onto a LOCAL ref is the wrong-branch class #421 exists to prevent.
# Skipping the fetch is NOT sufficient — a fork branch named `main` whose head
# merely happens to equal the local `main` SHA would satisfy the resolver's
# assertion, take in-place mode, and let grind commits push to the UPSTREAM
# branch instead of the fork.
#
# Nor is this a real capability loss: a grind must push its fix commits to the
# PR head, which requires write access to the fork — access this flow never had.
# "Supporting" fork PRs here could only ever mean pushing somewhere wrong.
if [ "$PR_IS_FORK" = "true" ]; then
  echo "❌ PR <PR_NUMBER> is from a fork. pr-grind cannot grind fork PRs: it would"
  echo "   need push access to the fork's head branch, and a fork-chosen branch"
  echo "   name must never be resolved against a local ref (#421)."
  echo "   Review the PR manually, or ask the author to push to a branch in this repo."
  exit 1
fi

# Same-repo from here. Reconcile the local branch with the PR head BEFORE
# resolving, so the ordinary "someone pushed to the PR" case proceeds instead of
# bailing. Belt-and-braces: never fetch into the base branch, so a malformed
# same-repo case cannot reach the fetch either.
if [ "$PR_BRANCH" != "$BASE_BRANCH" ]; then
  # Fast-forward only — note the absence of a leading `+`. A divergent local
  # branch must NOT be silently rewritten; the fetch fails, the SHA assertion
  # bails, and the operator decides. Same outcome when the branch is currently
  # checked out, which git refuses to update via fetch. The branch name is one
  # argv element to git, never shell-evaluated, so a hostile name containing
  # `$(...)`, backticks, `;` or `|` cannot execute anything.
  git fetch -q origin "refs/heads/${PR_BRANCH}:refs/heads/${PR_BRANCH}" 2>/dev/null || true
fi

# Resolve the grind's working directory. The resolver (#421) owns the three-way
# split — branch free / checked out HERE / held by ANOTHER worktree — and BAILs
# fail-CLOSED on the third rather than silently pointing the grind at the repo
# root's branch. It also asserts unconditionally, in BOTH modes, that the
# resolved dir is on `$PR_BRANCH` AND at `$PR_HEAD_SHA` — name alone would let a
# stale or unrelated same-named local branch through (fork PRs especially).
#
# Its stdout is the cross-block source of truth (shell vars don't survive across
# Claude tool calls): `pr-grind-mode: no-worktree` when it fell back in-place,
# and always a final `WORKTREE_DIR=<abs path>`.
RESOLVE_OUT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-pr-worktree.sh" "<PR_NUMBER>" "$PR_BRANCH" "$PR_HEAD_SHA" 2>&1)
RESOLVE_EXIT=$?
printf '%s\n' "$RESOLVE_OUT"
if [ "$RESOLVE_EXIT" -ne 0 ]; then
  echo "❌ Step 0 worktree resolution failed — see above. Not proceeding."
  exit 1
fi

if printf '%s' "$RESOLVE_OUT" | grep -q '^pr-grind-mode: no-worktree$'; then
  NO_WORKTREE=1
fi
WORKTREE_DIR=$(printf '%s' "$RESOLVE_OUT" | grep '^WORKTREE_DIR=' | tail -1 | sed 's/^WORKTREE_DIR=//')
if [ -z "$WORKTREE_DIR" ]; then
  echo "❌ resolver exited 0 but emitted no WORKTREE_DIR — refusing to guess."
  exit 1
fi
cd "$WORKTREE_DIR" || { echo "❌ cd to '$WORKTREE_DIR' failed — cannot proceed."; exit 1; }

# Snapshot the solo-admin opt-in file at pr-grind INVOCATION TIME, so the
# anti-self-bypass freshness check anchors to "≥30s old at invocation start"
# rather than "at Completion time". A pr-grind run can last minutes; without
# this snapshot, an autonomous agent could `touch` the file at the start of
# a slow run and have it satisfy the 30s threshold by the time the Completion
# merge block runs. The snapshot lives in the MAIN repo's .claude/ (not the
# worktree's), because the operator's opt-in file is in the main repo and
# .claude/*.local is gitignored / not copied into ephemeral worktrees.
# `git rev-parse --git-common-dir` returns the SHARED .git/ across worktrees,
# whose parent is the main repo root.
#
# Per-PR snapshot path: includes ${PR_NUMBER} so two concurrent pr-grind
# runs on DIFFERENT PRs cannot race on a single shared snapshot file. A
# same-PR concurrent run is a degenerate case (operator running pr-grind
# twice on the same PR simultaneously) and accepts last-writer-wins.
# Snapshot is written 0600 to prevent other local users from reading the
# mtime token (defense in depth — the threat model already assumes
# attacker has same-user write access, in which case this is marginal).
# Step 0 has already `cd`-ed into the worktree at this point (or, in
# --no-worktree mode, into the repo root). A bare `git rev-parse` here
# would work but is CWD-sensitive; `git -C "$WORKTREE_DIR"` is explicit
# and matches the symmetric Completion-side resolver. Two-step resolve +
# absolute-path check defends against `dirname ""` returning "." on a
# failed rev-parse, which would otherwise leak the CWD path through.
MAIN_REPO_ROOT_FOR_OPTIN=""
GIT_COMMON_DIR=$(git -C "$WORKTREE_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
if [ -n "$GIT_COMMON_DIR" ]; then
  CANDIDATE=$(dirname "$GIT_COMMON_DIR")
  case "$CANDIDATE" in
    /*) MAIN_REPO_ROOT_FOR_OPTIN="$CANDIDATE" ;;
    *)  : ;;
  esac
fi
if [ -n "$MAIN_REPO_ROOT_FOR_OPTIN" ] && [ -d "$MAIN_REPO_ROOT_FOR_OPTIN/.claude" ]; then
  SOLO_OPTIN_FILE="$MAIN_REPO_ROOT_FOR_OPTIN/.claude/pr-grind-auto-admin-solo.local"
  SOLO_OPTIN_SNAPSHOT="$MAIN_REPO_ROOT_FOR_OPTIN/.claude/.pr-grind-solo-opt-in-snapshot-${PR_NUMBER}.local"
  # Always clear any prior per-PR snapshot — fresh run, fresh truth.
  rm -f "$SOLO_OPTIN_SNAPSHOT"
  if [ -f "$SOLO_OPTIN_FILE" ]; then
    OPTIN_MTIME=$(stat -c %Y "$SOLO_OPTIN_FILE" 2>/dev/null || stat -f %m "$SOLO_OPTIN_FILE" 2>/dev/null || echo 0)
    case "$OPTIN_MTIME" in ''|*[!0-9]*) OPTIN_MTIME=0 ;; esac
    if [ "$OPTIN_MTIME" -eq 0 ]; then
      echo "⚠️  stat failed on $SOLO_OPTIN_FILE — cannot verify age, solo-admin auto-detect will NOT fire this run." >&2
    else
      # Anchor freshness check against INVOCATION_START_EPOCH (captured at
      # the very top of Step 0), NOT a fresh `date +%s` here. Otherwise
      # earlier Step 0 work (gh pr view, git worktree add) that takes ≥30s
      # would let an opt-in file created mid-invocation pass the gate.
      OPTIN_AGE_AT_START=$((INVOCATION_START_EPOCH - OPTIN_MTIME))
      if [ "$OPTIN_AGE_AT_START" -ge 30 ]; then
        if printf '%s\n' "$OPTIN_MTIME" > "$SOLO_OPTIN_SNAPSHOT"; then
          chmod 600 "$SOLO_OPTIN_SNAPSHOT" 2>/dev/null
          echo "ℹ️  pr-grind-auto-admin-solo.local snapshotted (age-at-invocation=${OPTIN_AGE_AT_START}s, PR #${PR_NUMBER}) — solo-admin auto-detect armed for this run."
        else
          echo "⚠️  snapshot write failed for $SOLO_OPTIN_SNAPSHOT (disk full or permission denied?) — solo-admin auto-detect will NOT fire this run." >&2
          rm -f "$SOLO_OPTIN_SNAPSHOT"
        fi
      else
        echo "⚠️  pr-grind-auto-admin-solo.local exists but was too fresh at pr-grind invocation start (age=${OPTIN_AGE_AT_START}s, required ≥30s) — solo-admin auto-detect will NOT fire this run. If you just touched the file, wait 30s and rerun pr-grind." >&2
      fi
    fi
  fi
fi
```

**Why a worktree:** pr-grind is a different operational mode from the pipeline. Pre-PR phases optimize for local delivery; post-PR grind optimizes for async iteration. An ephemeral worktree gives pr-grind its own branch ownership without hijacking the main workspace.

**Skip with `--no-worktree`:** Optional explicit opt-in to in-place mode. The auto-fallback below handles the common case (branch already checked out *here*), so passing this flag is rarely required — use it when you want to suppress the info-level fallback message or skip the worktree-add attempt entirely.

**Auto-fallback to in-place mode:** `scripts/resolve-pr-worktree.sh` splits `git worktree add`'s `already used by worktree at` failure three ways (#421):

| Branch is… | Resolver does | Emits |
|---|---|---|
| free | creates `pr-grind-<PR_NUMBER>` beside the repo root | `WORKTREE_DIR=<new worktree>` |
| checked out in **this** repo | falls back in-place | `ℹ️` info line, `pr-grind-mode: no-worktree`, `WORKTREE_DIR=<repo-root>` |
| checked out in **another** worktree | **BAILs**, naming the holder | nothing on stdout; exit 1 |

The third row is the fail-CLOSED fix. Previously *any* `already used by worktree at` fell back to the repo root, so a branch held by another worktree pointed the whole grind at whatever the repo root was on — usually `main` — which read the wrong HEAD for the ack ledger and pushed fix commits straight onto `main`, bypassing the PR. An unusable worktree is the failure case, not the happy path.

Whichever row is taken, the resolver **asserts unconditionally**, before it exits 0, that the resolved directory is on `$PR_BRANCH` **AND** at `$PR_HEAD_SHA`. That assertion, not the split, is the load-bearing guard: it catches this bug class even if a fourth case ever appears.

**Both halves are required — do not document or implement only the name check.** Branch-name equality alone is insufficient: `headRefName` is not globally unique, so a stale or wholly unrelated local branch that merely shares the PR head's name satisfies it. That is routine for fork PRs and for a local branch that never fetched the PR's latest push. The SHA equality is what makes "this is the revision the PR is actually at" true rather than merely plausible.

**When the `pr-grind-mode: no-worktree` line appears, the dispatcher MUST treat the rest of the run as if `--no-worktree` was passed** — set `NO_WORKTREE=1` in every subsequent bash block, skip the worktree cleanup at COMPLETION and BAIL, and write `pr-grind-clean.local` to the current repo root rather than copying it across worktrees. This state has to be carried by Claude across bash invocations because shell variables don't persist; treat the printed marker as the source of truth and propagate it explicitly. The final `WORKTREE_DIR=` line is the resolved path the dispatcher should pass to the subagent context block. **Marker-anchor caveat:** whenever `WORKTREE_DIR` (Step 0's resolved dir) is not the Claude session's cwd — e.g. the resolver ran from, or fell back in-place to, a linked worktree while `/pr-grind` was invoked from a different checkout — the pre-merge gate still anchors on the **session cwd**, not on `WORKTREE_DIR`. The COMPLETION marker-write block must therefore run at the ambient session cwd and must NOT `cd "$WORKTREE_DIR"` first, so `git rev-parse --show-toplevel` resolves to the gate's actual anchor (see "Write the pr-grind-clean marker").

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
RESULT_COMMIT_SHA: <sha or "none">                    (always present; dispatcher-synthesized on fix-round and wait-round paths; worker-advisory on clean path)
RESULT_FIXES: <one-line summary>                      (always present)
RESULT_REMAINING: <one-line or "none">                (always present)
RESULT_REVIEWER_ACKS: <login=value,login=value,...>   (always present; dispatcher-synthesized on fix-round and wait-round paths; worker-advisory on clean path; values: <short-sha> | none | stale; early-bail paths emit the all-`none` default initialized before Step 0)
RESULT_ACK_TIERS: <login=tier,login=tier,...>         (worker tag, additive/backward-compatible; tier ∈ {A,B,C,D,E,none} = the ack-ledger tier that produced each bot's HEAD-ack, or `none` when the bot is not HEAD-acked. Invariant 3 reads it ONLY to exempt a HEAD-acked bot with n_total==0 when its tier is D (check-run) or E (commit-status) — bodyless structured acks, see ADR 0001. MISSING TAG (old-contract worker) → Invariant 3 falls back to its strict pre-ADR-0001 behavior (n_total==0 on a HEAD-ack always bails); do NOT bail "subagent output unparseable" on a missing RESULT_ACK_TIERS — additive, not version-pinned.)
RESULT_CODEX_ACK: <short-sha | stale | none>          (Codex's reaction-based ack; gated like a registered bot but tracked SEPARATELY from RESULT_REVIEWER_ACKS because its clean signal is a timestamp-keyed 👍 (Tier F), not a SHA-keyed structured ack. `stale` blocks `clean` AND counts as a legitimate wait-round in the no-progress invariant (Invariant 1 — a Codex-only wait-round must not be misread as no-progress); `<short-sha>` = acked HEAD via a fresh 👍 (Tier F) OR a resolved current-head thread (Tier A) — Codex findings (unresolved/outdated threads, COMMENTED /reviews) resolve to `stale`, never a SHA; `none` = not on this PR, non-gating. Additive/backward-compatible: MISSING TAG (old-contract worker) → treat as empty (`!= stale`), so Invariant 1 falls back to its registered-bot-only behavior. Do NOT bail "subagent output unparseable" on a missing RESULT_CODEX_ACK — additive, not version-pinned.)
RESULT_BOT_LEDGER: <login=n_act/n_total:disp,...>     (always present; entries shape: `<login>=<n_actionable>/<n_total>:<disposition>`; early-bail paths emit the all-`0/0:none` default; gates Invariant 3 — see Dispatcher Loop. n_actionable and n_total are different units — findings (decided per-finding) vs artifacts (review/comment entries examined); a single artifact can contain multiple findings, so n_actionable > n_total (e.g., `<bot>=2/1:fixed both`) is legitimate, not a typo. Invariant 3 only requires n_total >= 1 for HEAD-acked bots; it does NOT enforce n_actionable <= n_total. See `agents/pr-grinder.md` Step 3 worked examples. Disposition prose MUST NOT contain commas; entries are split on `,` and a comma inside a disposition would corrupt the parse. Disposition MAY carry `+`-joined `scope-skipped:<reason>:<count>` segments — Invariant 4 sums those counts across all bots/rounds against the ≤5 cumulative cap)
RESULT_ISSUES_SPAWNED: <issue,issue,... or "none">    (always present in the new contract; comma-separated GitHub issue numbers spawned this round via the out-of-scope-acknowledged workflow; gates Invariant 4 — cumulative count across rounds caps at 3. Backward compatibility: missing tag entirely → treat as "none" / zero contribution. Old-contract workers (pre-out-of-scope-flow) never emitted this tag and operate under pre-Invariant-4 semantics for the rest of their grind; new-contract workers always emit it. Do NOT bail "subagent output unparseable" on a missing RESULT_ISSUES_SPAWNED — the protocol is additive, not version-pinned.)
RESULT_BAIL_REASON: <one-line free-form prose>        (present only when status=bail; for human consumption — NEVER substring-matched for control flow)
RESULT_BAIL_CATEGORY: judgment | env | budget | policy  (present only when status=bail; `budget` and `policy` are dispatcher-only — emitted when the loop exhausts or when an external org-policy gate blocks merge that pr-grind cannot resolve via fix-rounds or wait-rounds, e.g. required-approver gap)
```

### Dispatcher commit-block contract (`scripts/dispatcher-commit-block.sh`)

Inputs (env vars, required):
- `WORKTREE_DIR`, `CLAUDE_PLUGIN_ROOT`, `PR_NUMBER`, `RESULT_STATUS`, `RESULT_FIXES`.

Inputs (env vars, optional; default 0/empty):
- `NO_WORKTREE` - `1` enables the pre-dispatch baseline check for no-worktree mode (worker runs in the repo root and shares the parent index).
- `PRE_DISPATCH_BASELINE` - JSON array of paths staged before worker dispatch; required when `NO_WORKTREE=1`.
- `BUSDRIVER_ALLOW_NO_COMMITLINT` - `1` allows a missing local commitlint binary.

Outputs (stdout, exactly one JSON object on the last line):
Every success envelope carries `result_ack_tiers` AND `result_codex_ack`, ALWAYS computed from the same ack-ledger pass as `result_reviewer_acks` (ADR 0001 core invariant — they are never desynced):
- Success (fix-round): `{"status":"success","result_commit_sha":"<sha>","result_reviewer_acks":"login=value,...","result_ack_tiers":"login=tier,...","result_codex_ack":"<sha|stale|none>"}` — post-push synthesis computes acks, tiers, AND codex_ack from one ack-ledger pass over the new HEAD. Degrades to all-`stale` acks + all-`none` tiers + `"stale"` codex_ack if the post-push GitHub-state fetch fails (stale-codex on degraded fetch prevents Invariant 1 from misclassifying as no-progress).
- Success (wait-round): `{"status":"success","result_commit_sha":"none","result_reviewer_acks":"login=value,...","result_ack_tiers":"login=tier,...","result_codex_ack":"<sha|stale|none>"}` — refreshes acks, tiers, AND codex_ack from one ack-ledger pass, so a bot that bodyless-acks HEAD (e.g. cubic=<sha> tier=D) is exemptible even while slower bots stay stale. Codex ack reflects the current reaction state.
- Success (clean pass-through): `{"status":"success","result_commit_sha":"none","result_reviewer_acks":"login=value,...","result_ack_tiers":"<worker RESULT_ACK_TIERS verbatim>","result_codex_ack":"<worker RESULT_CODEX_ACK verbatim>"}` — passes the worker's acks, tiers, AND codex_ack through unchanged (one worker Step 6.5 pass). Falls back to all-`none` tiers / `"none"` codex_ack only if the caller omitted the respective tags (fail-CLOSED for tiers; `"none"` default for codex is safe on clean path since a stale Codex would block clean).
- Bail: `{"bail_category":"judgment|env|budget|policy","bail_reason":"<string>"}`

Exit code:
- `0` on success envelope.
- `1` on bail envelope.
- `2` on internal-error precondition failures.

**Stdout-parse fallback to the dispatcher-allocated `RESULT_FILE`:** if scanning the worker's stdout for `^RESULT_<NAME>: ` produces no `RESULT_STATUS` after alias resolution **OR** produces a `RESULT_STATUS` whose value isn't one of `clean`, `needs_more`, `bail`, DO NOT immediately bail. First try reading `$RESULT_FILE` (the unique path you allocated in the context block above); if it exists and yields a `RESULT_STATUS` whose value IS one of the three canonical values (after the same alias resolution and last-occurrence rules), use those tags. The worker writes this file immediately before stdout emission per the contract in `agents/pr-grinder.md`, so it should be present on the filesystem even when stdout was truncated, reformatted by the SDK, polluted by mid-prompt output, OR contained a malformed `RESULT_STATUS` value. Only bail "subagent output unparseable" if BOTH stdout and the file fail to yield a `RESULT_STATUS` with a canonical value.

The fallback fires on EITHER missing OR invalid `RESULT_STATUS`. A worker that emitted `RESULT_STATUS: garbage` on stdout and `RESULT_STATUS: clean` to the file should be treated as `clean`, not bailed — stdout pollution should not override a well-formed file backup.

If after both probes `RESULT_STATUS` is still missing or its value still isn't one of the three valid options, then bail "subagent output unparseable" — do not guess.

## Worked Example: Out-of-Scope-Acknowledged Flow

Concrete walk-through of the carve-out — what the worker does, what the dispatcher sees, and how Invariant 4 interacts with it. Drawn from the failure mode that motivated this flow (jikdak PR #129, where the dispatcher had no clean way to dispose of architectural findings on touched lines and the merge stayed blocked across 7+ rounds).

**Setup.** A content PR changes `client/src/lib/blog-data.ts` (one of many edits). CodeRabbit posts two findings on lines this PR touched:

1. `client/src/lib/latest-data.ts:1963` — "Model `eventDate` as a date range (start + end)" → would change the shared `LatestItem` schema/interface contract.
2. `client/src/lib/blog-data.ts:11427` — "Use report-level source links instead of homepage links" → requires off-codebase research to find each report's permalink.

Both are real findings on changed code. Neither fits the existing pre-existing-issue carve-out (the lines were touched). Without out-of-scope-acknowledged, the worker would either fix them (3+ scope-creep rounds, bot finds new things on the new HEAD, grind never converges) or leave the threads unresolved (ack ledger stays `stale` forever, merge gate blocks indefinitely).

**Round 3 (worker).**

```text
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

```text
RESULT_STATUS: needs_more
RESULT_COMMIT_SHA: 4361cc54
RESULT_FIXES: remove /blog/* paths from 4 relatedTools blocks
RESULT_REMAINING: none
RESULT_REVIEWER_ACKS: cubic-dev-ai=stale,coderabbitai=stale,greptile-apps=stale
RESULT_ACK_TIERS: cubic-dev-ai=none,coderabbitai=none,greptile-apps=none
RESULT_CODEX_ACK: stale
RESULT_BOT_LEDGER: cubic-dev-ai=0/0:none,coderabbitai=3/3:fixed relatedTools paths+scope-skipped:schema-refactor:1+scope-skipped:external-research:1,greptile-apps=0/0:none,codescene-delta-analysis=0/0:none,chatgpt-codex-connector=0/0:none
RESULT_ISSUES_SPAWNED: 847,848
```

**Dispatcher state after Round 3:**

```text
total_scope_skipped: 0 + 2 = 2  (well under cap of 5)
total_issues_spawned: 0 + 2 = 2  (well under cap of 3)
Invariant 4: pass (both under cap)
PRIOR_ATTEMPTS:
  - Round 3 (fix=2/5, wait=0/8): fixes=remove /blog/* paths from 4 relatedTools blocks; failures=none; acks=cubic-dev-ai=stale,...; scope-skipped=2; spawned=2
```

**Round 4 (next worker dispatch).** Bots re-review `4361cc54`. CodeRabbit's prior threads are now resolved (worker closed them in Round 3); `scripts/ack-ledger.sh` tier A counts the resolved threads against HEAD-ack rather than `stale` (the change in this PR). All three registered bots clear, grind converges to `clean`, dispatcher hits COMPLETION.

**Total grind:** 4 rounds (was 7+ rounds + manual intervention before this carve-out existed). 2 dismissals consumed (under cap), 2 follow-up issues spawned (under cap). The two architectural findings live as `#847` and `#848` for separate PRs to address with proper scope.

**What would BAIL.** If the worker dismisses a 6th finding across the grind (cumulative cap ≤5 inclusive — 5 allowed, 6th BAILs), Invariant 4 fires at the start of the next round with `RESULT_BAIL_CATEGORY=judgment` and reason `out-of-scope dismissal count is 6 across N rounds — exceeds discipline rail of 5; operator review required`. Operator decides whether the PR's scope is wrong (split it) or the worker is misclassifying (interactive review of the dismissals). Same shape applies to the spawn cap: 3 spawns allowed, the 4th BAILs.

## Completion (post-loop, dispatcher only)

<CRITICAL>
STOP. The entire Completion path — the done-criteria gate, `FRESH_ACKS`, the
ADR 0012 downgrade, Branch-Currency, Approver-Gap Detection, the
`pr-grind-clean.local` marker write, and both merge blocks — lives in
`references/completion.md` (this skill's directory). It is NOT summarized here.

**Read `references/completion.md` in full before taking ANY merge-path action.**
Do not improvise the marker format, the merge flags, or the marker/merge call
split from memory — `--match-head-commit`, the marker's second field
(`<PR_NUMBER> <REVIEWED_HEAD>`, #505/ADR 0030), and the TOCTOU requirement that the
marker write and `gh pr merge` be SEPARATE Bash tool calls are all defined only
in that file.

Reaching this point without reading it is a bug, not a shortcut. It is split
out solely to keep ~23k tokens of merge-path detail out of every fix/wait round
— it is not optional, and nothing above replaces it.
</CRITICAL>

Enter here when the loop returns `RESULT_STATUS=clean` and Invariants 1–4 pass,
or via the explicit ADR 0012 max-wait downgrade path. On BAIL, go to BAIL — not
here.

## Arguments

| Argument | Description | Default |
|----------|-------------|---------|
| `<PR>` | PR number or URL | Auto-detect from current branch |
| `--max-fix N` | Maximum **fix-rounds** (dispatcher pushed a commit; `RESULT_COMMIT_SHA != "none"`) before bail. Reflects engineering iteration budget. | 5 |
| `--max-wait N` | Maximum **wait-rounds** (worker did not push; `RESULT_COMMIT_SHA == "none"` — polling for slow bots to ack HEAD) before bail. Reflects bot-latency tolerance. | 8 |
| `--max N` | **Deprecated alias** that sets both `--max-fix` and `--max-wait` to N. Emits a `⚠️  --max is deprecated; use --max-fix and --max-wait` warning. Cannot be combined with `--max-fix` or `--max-wait` — combining bails with `conflicting flags`. | unset |
| `--no-worktree` | Skip worktree creation, work in current directory. Same behavior auto-engages without the flag if the branch is already checked out **in this repo**; if another worktree holds it, Step 0 BAILs instead of falling back (#421) — see Step 0 fallback. | Off (creates worktree) |
| `--no-merge` | Skip merge after grinding clean — just declare "Ready for merge" | Off (merges by default) |
| `--admin-on-approver-gap` | Opt-in auto-escalation when the approver gap is the sole remaining merge-gate blocker. Eligibility (ALL must hold): CI green, bots ack HEAD, all threads resolved, no failing required checks; author has `admin` or `maintain` repo permission; `.github/workflows/bypass-audit.yml` exists in the repo. With all gates green, the dispatcher runs `gh pr merge <PR> --squash --delete-branch --admin` and logs the event to `.claude/bypass-log.jsonl` (`event: pr-grind-admin-on-approver-gap`). **Fail-CLOSED when no audit workflow exists** — the flag is ignored without a trail and the dispatcher surfaces the operator-decision message instead. Off by default. **Alternative — per-repo opt-in:** for repos where the operator is structurally the sole human with PR-approval capability (no other humans with write/maintain/admin could ever approve), drop `.claude/pr-grind-auto-admin-solo.local` once (gitignored, same pattern as `skip-litmus.local`) and pr-grind treats the flag as implicit. The same eligibility gates apply, plus a live structural check that `HUMAN_ADMIN_COUNT==1` (counting humans with `permissions.push==true` — write/maintain/admin) and the author is that one approval-capable human. The opt-in self-revokes if a second approval-capable human appears — a contractor with write permission alone is enough to invalidate it. **Anti-self-bypass (snapshot-anchored, three conditions):** the opt-in file must be at least 30s old AT pr-grind INVOCATION START (Step 0), not at Completion. Step 0 snapshots the file's mtime to a per-PR snapshot at `.claude/.pr-grind-solo-opt-in-snapshot-<PR>.local` (written 0600) only when the file is already ≥30s old; Completion auto-fires only when (1) the per-PR snapshot exists, (2) its recorded mtime equals the opt-in file's current mtime, AND (3) the snapshot file's own filesystem mtime is ≥30s after the opt-in file's mtime (defeats a same-NOW forge where an attacker creates both files in one action with identical mtimes). A mid-run touch (no snapshot) or mid-run replacement (mismatch) both invalidate the opt-in for the current run. The per-PR scoping prevents concurrent pr-grind runs on different PRs from racing on shared state. Snapshot and opt-in file both live in the MAIN repo's `.claude/`, not the ephemeral worktree. The audit-log event is distinct: `pr-grind-admin-on-approver-gap-solo-admin-auto` with `trigger: "solo-admin-auto"` and `human_admin_count` recorded (variable name preserved for backward compat; semantic is now "humans with PR-approval capability"). | Off (surfaces decision message) |

## User-Created Skip File

When the user wants to bypass the pre-merge gate (e.g., pr-grind stuck in a loop, or PR ready-enough and the user accepts the risk), they create `.claude/skip-pr-grind.local` manually in their terminal.

**Pre-merge specifics (different from other busdriver gates):**

- Skip file: `.claude/skip-pr-grind.local`
- Trigger: `gh pr merge`
- On <30s rejection: gate **deletes** the file (user must `touch` again).
- **Freshness window: 30s..3600s.** The gate silently deletes files ≥1h old without bypassing — the user has up to 1 hour between `touch` and the merge retry.
- **Deferred consumption** (unique to pre-merge — added to fix the consume-on-gate-pass-but-API-fail bug surfaced during PR #115's dogfood): the PreToolUse gate writes a pending claim to `.claude/.merge-bypass-pending.local` and leaves the skip file alone. The PostToolUse hook `post-merge-confirm-bypass.sh` consumes the skip file ONLY when `gh pr merge` confirms success. On merge failure (`X Pull request is not mergeable`, conflicts, branch protection), `--auto` queued-but-not-yet-merged, ambiguous output, mtime tamper, or PR-number mismatch between the claim and the executed command, the skip file is preserved so the operator can retry without a re-touch. Audit events all log to `.claude/bypass-log.jsonl` — see README event taxonomy.
- **Explicit-PR requirement when using the bypass**: `gh pr merge` (no PR number, auto-detect from current branch) records `merge_pr=unknown` in the pending claim. Confirmation then refuses to consume the bypass token (treated as `-released-mismatch` to prevent cross-PR token reuse via branch-switching). The merge itself proceeds (the gate already authorized it), but the bypass log will show `skip-pr-grind-released-mismatch` rather than `-consumed`, and the skip file remains valid until **1h after the original `touch`** (the 3600s window is anchored to the skip file's mtime, NOT to the failed merge — a released token does not refresh its clock). To get a clean audit trail and consume the bypass token, pass the PR number explicitly: `gh pr merge 42 --squash`.

When emitting the verbatim message template (from the canonical protocol — see below), tell the user "the file must be touched within the last hour — the gate rejects ages of 3600s or more" so they don't sit on it indefinitely. Otherwise the protocol is identical to other gates: 35s `Monitor` wait, no Bash verification, NEVER create the skip file yourself, etc.

**Stale-file recovery (pr-grind only):** If `gh pr merge` blocks after the user has already run `touch` and Claude has waited the 35s, the skip file may have expired (≥3600s since `touch`). The gate silently deletes stale files without bypassing — there's no "stale" message. Ask the user to `touch` again and restart the 35s wait. Note that with deferred consumption, a failed merge no longer requires a re-touch unless the file actually aged past 3600s.

**Full protocol** — verbatim message template (with `<GATE>` substitution), `Monitor`-based 35s wait pattern, and hard rules — lives canonically in `skills/blueprint-review/SKILL.md` → "User-Created Skip File". The protocol is identical across all busdriver gates; only the pre-merge specifics in the bullets above differ.

## Integration

- **Pairs with:** `finishing-a-development-branch` (Phase 6 creates the PR and cleans up its worktree, then `/pr-grind` creates its own ephemeral worktree for the feedback loop)
- **Worktree lifecycle:** pr-grind owns its worktree from creation to cleanup — independent of the pipeline's Phase 3 worktree.
- **Gate:** Litmus runs inside the dispatcher-owned commit block before each fix commit; pre-merge gate fires on `gh pr merge` (skip: `.claude/skip-pr-grind.local`)
- **Subagent:** `pr-grinder` (Sonnet) — receives one-round dispatch, returns RESULT_* tags. See `agents/pr-grinder.md`.
