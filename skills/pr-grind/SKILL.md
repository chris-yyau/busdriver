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
- Required status checks: green — per `.github/required-checks.lock` `required[]` when present (allowlist mode: only those names block); otherwise all checks except `ADVISORY_PATTERN`/CodeScene (advisory-fallback mode). The lock is the single source of truth for both the pre-merge gate and pr-grind, computed by `scripts/relevant-check-status.sh`.
- Actionable findings on YOUR PR's changed lines: addressed (fix or justified reply)
- PR title/body: conventional commit + scope

**Bounded-wait advisory (best-effort, capped by `--max-wait`):**
- AI reviewer acks (Cursor, CodeRabbit, Cubic, etc.)

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

**Override with `--opus`:** Run the loop inline in the parent Opus context (skips dispatch). Use when a PR has known nuance — multi-file architectural fixes, subtle review threads, etc.

## Anti-Patterns (DO NOT)

| Trap | Why it breaks the loop |
|------|----------------------|
| Looping rounds inside the subagent | Subagent contract is one round per dispatch. The dispatcher owns the loop. |
| Collecting feedback while checks are still pending | You'll miss reviewer findings, fix a partial set, push, and trigger a second review cycle unnecessarily |
| Declaring "Round complete" after push without waiting | The push triggers a new review cycle — you must wait for IT to finish before declaring done |
| Only waiting for CI (build/lint/test), ignoring reviewer bots | CodeRabbit, Cursor, Cubic are checks too — `gh pr checks` shows them as pending |
| Fixing pre-existing issues flagged by automated reviewers | Scope creep — only fix issues in YOUR changed code |
| Enabling GitHub auto-merge before pr-grind completes | The PR merges as soon as CI passes — before reviewer comments are addressed. pr-grind merges by default after all checks pass and comments are addressed. |
| Giving compound "grind then merge" instructions | Agent optimizes for merge as terminal goal, skipping CI wait. Just invoke `/pr-grind` — merge is the default. |
| Declaring PR clean without verifying check results | Checks completing (pass/fail/skip) ≠ checks passing — always verify status before writing the clean marker |

## Safety Rails

- **Max iterations:** Two independent budgets — **fix-rounds** (default 5, override with `--max-fix N`) cap how many dispatcher-owned fix commits can be pushed; **wait-rounds** (default 8, override with `--max-wait N`) cap how many polling rounds spent waiting for slow bots to ack HEAD. A round is classified as a *fix round* when `RESULT_COMMIT_SHA != "none"` and as a *wait round* otherwise. Bail when EITHER counter exhausts its budget. Both `--max-fix` and `--max-wait` must be `>= 1` — there is no "zero means unlimited" or "zero disables this class" form; if you want a larger budget, pass a larger number. The legacy `--max N` flag is accepted as a deprecated alias that sets both budgets to N (emits a deprecation warning). The split exists because under the old unified `--max`, every wait-round consumed a fix slot — so a PR with 3 fix iterations + 4 slow-bot polls would exhaust at MAX=5 even though only 3 fixes happened.
- **Autonomous by default:** Grinds without pausing between rounds (override with `--interactive` for human checkpoints)
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
                   PRIOR_REVIEWER_ACKS="cursor=none,cubic-dev-ai=none,coderabbitai=none,devin-ai-integration=none",
                   PRIOR_CODEX_ACK="none"
                   # PRIOR_CODEX_ACK persists Codex's RESULT_CODEX_ACK across
                   # rounds (parallel to PRIOR_REVIEWER_ACKS), so the max-wait
                   # bail's STALE_AT_BAIL can name Codex when a Codex-only wait
                   # exhausts the budget. Reset per invocation.

LOOP (terminates when fix_round >= MAX_FIX OR wait_round >= MAX_WAIT):
  │
  ├── round_number += 1                  # pre-increment so ROUND=<N> is 1-indexed at dispatch time
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
  │         fix/wait round where, e.g., cursor's check-run registers before
  │         slower bots (cursor=<sha> tier=D exempts; the others stay stale).
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
  │        RESULT_REVIEWER_ACKS, so a Codex-only wait-round — all four
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
  │        in <list> when RESULT_CODEX_ACK=stale). Slow-Cursor / slow-Cubic
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
  │        scoped to the four registered ack-bots that the worker can
  │        cross-correlate.
  │
  │        Parse RESULT_BOT_LEDGER as comma-separated entries of shape
  │        `<login>=<n_actionable>/<n_total>:<disposition>`.
  │
  │        **Defensive count check FIRST.** The known-bot set is fixed
  │        (6 bots: `cursor`, `cubic-dev-ai`, `coderabbitai`,
  │        `devin-ai-integration`, `codescene-delta-analysis`,
  │        `chatgpt-codex-connector`).
  │        After comma-splitting, the number of entries MUST equal 6; if
  │        it doesn't, BAIL with reason "malformed bot ledger: expected 6
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
  │                  with no enumerable Source 2/3/4 body — e.g., Cursor
  │                  Bugbot on a clean run. By ack-ledger's tier order (A→E,
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
# marker here would silently merge an unfinished PR.
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
                          and read as a classification bug). Then BAIL with reason
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
  │   bot may have re-posted between subagent return and merge time)
  ├── Write .claude/pr-grind-clean.local at repo root
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
- `NO_WORKTREE` - `1` enables the pre-dispatch baseline check for inline/no-worktree mode.
- `PRE_DISPATCH_BASELINE` - JSON array of paths staged before worker dispatch; required when `NO_WORKTREE=1`.
- `BUSDRIVER_ALLOW_NO_COMMITLINT` - `1` allows a missing local commitlint binary.

Outputs (stdout, exactly one JSON object on the last line):
Every success envelope carries `result_ack_tiers` AND `result_codex_ack`, ALWAYS computed from the same ack-ledger pass as `result_reviewer_acks` (ADR 0001 core invariant — they are never desynced):
- Success (fix-round): `{"status":"success","result_commit_sha":"<sha>","result_reviewer_acks":"login=value,...","result_ack_tiers":"login=tier,...","result_codex_ack":"<sha|stale|none>"}` — post-push synthesis computes acks, tiers, AND codex_ack from one ack-ledger pass over the new HEAD. Degrades to all-`stale` acks + all-`none` tiers + `"stale"` codex_ack if the post-push GitHub-state fetch fails (stale-codex on degraded fetch prevents Invariant 1 from misclassifying as no-progress).
- Success (wait-round): `{"status":"success","result_commit_sha":"none","result_reviewer_acks":"login=value,...","result_ack_tiers":"login=tier,...","result_codex_ack":"<sha|stale|none>"}` — refreshes acks, tiers, AND codex_ack from one ack-ledger pass, so a bot that bodyless-acks HEAD (e.g. cursor=<sha> tier=D) is exemptible even while slower bots stay stale. Codex ack reflects the current reaction state.
- Success (clean pass-through): `{"status":"success","result_commit_sha":"none","result_reviewer_acks":"login=value,...","result_ack_tiers":"<worker RESULT_ACK_TIERS verbatim>","result_codex_ack":"<worker RESULT_CODEX_ACK verbatim>"}` — passes the worker's acks, tiers, AND codex_ack through unchanged (one worker Step 6.5 pass). Falls back to all-`none` tiers / `"none"` codex_ack only if the caller omitted the respective tags (fail-CLOSED for tiers; `"none"` default for codex is safe on clean path since a stale Codex would block clean).
- Bail: `{"bail_category":"judgment|env|budget|policy","bail_reason":"<string>"}`

Exit code:
- `0` on success envelope.
- `1` on bail envelope.
- `2` on internal-error precondition failures.

**Stdout-parse fallback to the dispatcher-allocated `RESULT_FILE`:** if scanning the worker's stdout for `^RESULT_<NAME>: ` produces no `RESULT_STATUS` after alias resolution **OR** produces a `RESULT_STATUS` whose value isn't one of `clean`, `needs_more`, `bail`, DO NOT immediately bail. First try reading `$RESULT_FILE` (the unique path you allocated in the context block above); if it exists and yields a `RESULT_STATUS` whose value IS one of the three canonical values (after the same alias resolution and last-occurrence rules), use those tags. The worker writes this file immediately before stdout emission per the contract in `agents/pr-grinder.md`, so it should be present on the filesystem even when stdout was truncated, reformatted by the SDK, polluted by mid-prompt output, OR contained a malformed `RESULT_STATUS` value. Only bail "subagent output unparseable" if BOTH stdout and the file fail to yield a `RESULT_STATUS` with a canonical value.

The fallback fires on EITHER missing OR invalid `RESULT_STATUS`. A worker that emitted `RESULT_STATUS: garbage` on stdout and `RESULT_STATUS: clean` to the file should be treated as `clean`, not bailed — stdout pollution should not override a well-formed file backup.

If after both probes `RESULT_STATUS` is still missing or its value still isn't one of the three valid options, then bail "subagent output unparseable" — do not guess.

### Inline Execution (`--opus`, `--interactive`, `--ci-only`, or `--comments-only`)

When inline, the dispatcher executes the round triage/fix/stage body itself in the parent Opus context. Commit, litmus, push, and post-push ack synthesis still go through `scripts/dispatcher-commit-block.sh`, exactly like subagent mode.

<EXTREMELY-IMPORTANT>
YOU MUST COMPLETE STEP 1 BEFORE PROCEEDING. Do NOT skip, abbreviate, or defer CI waiting.
The entire pr-grind workflow depends on checks being complete. If you proceed without waiting,
you will be blocked by the pre-merge gate and waste the user's time.
</EXTREMELY-IMPORTANT>

#### Step 1: Wait for ALL Checks + Reviewers

**DO NOT skip this step. DO NOT proceed while checks are still pending.**

Automated reviewers (CodeRabbit, Cursor, Cubic, CodeScene, GitGuardian) register as GitHub checks. `gh pr checks --watch` blocks until ALL of them complete — not just CI build/lint/test.

**Advisory checks (CodeScene):** CodeScene is non-blocking — its feedback is still collected and you MUST attempt to fix its issues, but its pass/fail status does not block the clean marker or merge gate. If a CodeScene finding requires architectural changes beyond PR scope, note it and proceed.

```bash
# Phase 1: Wait for all GitHub-registered checks (CI + automated reviewers).
# NOTE: --watch has no allowlist knob, so it waits for the FULL GitHub check
# set; lock-aware filtering applies to the DECISION below (Phase 2/2.5), not
# this wait. A perpetually-pending NON-required check can delay this up to the
# timeout — a known minor latency caveat, not a correctness issue.
timeout 900 gh pr checks <PR_NUMBER> --watch 2>&1 || true

# Lock-aware check filter — single source of truth across this skill, the
# pre-merge gate, and the pr-grinder worker (scripts/relevant-check-status.sh,
# issue #154). Pass the repo-ROOT DIR so it can read .github/required-checks.lock
# — NOT the repo name (a bare name resolves the lock at ./name/.github/... and
# silently falls back to mode=all). It emits "<failed> <pending> <mode> <kept>"
# on line 1 (read consumes only line 1) and the failing rows on lines 2..N.
# Fail-CLOSED: any error → conservative blocking "1 0 all 0".
REPO_DIR=$(git rev-parse --show-toplevel)
RCS="${CLAUDE_PLUGIN_ROOT}/scripts/relevant-check-status.sh"

# Phase 2: Verify no REQUIRED checks are still pending (lock-aware; defensive).
for i in 1 2 3 4 5; do
  COUNTS=$(gh pr checks <PR_NUMBER> 2>&1 | bash "$RCS" "$REPO_DIR" 2>/dev/null || printf '1 0 all 0\n')
  read -r _F PENDING _M _K <<<"$COUNTS"
  [ "${PENDING:-1}" -eq 0 ] && break
  echo "⏳ $PENDING required checks still pending — waiting 60s (attempt $i/5)..."
  sleep 60
done
if [ "${PENDING:-1}" -gt 0 ]; then
  echo "❌ $PENDING required checks still pending after 5 retries. Cannot proceed."
  exit 1
fi

# Phase 2.5: Verify all REQUIRED checks PASSED (not just completed).
GH_EXIT=0
CHECKS_RAW=$(gh pr checks <PR_NUMBER> 2>&1) || GH_EXIT=$?
if [ "$GH_EXIT" -ne 0 ] && ! printf '%s\n' "$CHECKS_RAW" | grep -qE "pass|fail|pending"; then
  echo "❌ gh pr checks failed (exit $GH_EXIT). Resolve CLI/auth issues."
  exit 1
fi
COUNTS=$(printf '%s\n' "$CHECKS_RAW" | bash "$RCS" "$REPO_DIR" 2>/dev/null || printf '1 0 all 0\n')
read -r FAILED PENDING MODE KEPT <<<"$COUNTS"
# Guard (mirror the gate): empty/garbled output → treat as blocking.
if [ -z "${MODE:-}" ] || [ -z "${FAILED:-}" ] || [ -z "${KEPT:-}" ]; then FAILED=1; fi
# No relevant-check evidence (KEPT=0 — e.g. a required check never posted) must
# NOT read as clean; mirror the gate's KEPT>0 bootstrap guard.
if [ "${KEPT:-0}" -eq 0 ]; then FAILED=1; fi
# Advisory (cosmetic, mode-independent FYI): CodeScene failing is non-blocking.
ADVISORY_FAILED=$(printf '%s\n' "$CHECKS_RAW" | grep -iE "CodeScene" | grep -cE "fail" || true)
if [ "$ADVISORY_FAILED" -gt 0 ]; then
  echo "⚠️  $ADVISORY_FAILED advisory checks failing (non-blocking)."
fi
if [ "${FAILED:-1}" -gt 0 ]; then
  echo "❌ $FAILED required checks FAILED. Continuing to Step 2 to collect details."
  printf '%s\n' "$COUNTS" | tail -n +2
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
- **Source 4 (issue comments):** no GitHub-side flag exists. Each bot's latest comment body is canonical; older comments from same bot are superseded. **CodeRabbit-Pro posts its findings only here** — running Source 2 alone misses them. See `agents/pr-grinder.md` Step 2 for concrete bot-by-bot parsing rules.

Re-fetching all four sources each round is cheap; the cost we cared about was conversation-context accumulation, not API traffic, and per-round subagent dispatch already solves that.

#### Step 3: Triage

Classify each piece of feedback:

| Category | Action |
|----------|--------|
| **CI failure — test/lint/build** | Fix it |
| **CI failure — flaky/infra** | Note it, skip after 3 consecutive identical failures |
| **Automated reviewer — specific fix** (CodeRabbit, Cursor, Cubic, Codex) | Fix it — treat like human review |
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

#### Step 6: Stage Intent; Dispatcher Commits

Stage only the files changed by this round and record the fix summary in `RESULT_FIXES`. Do not run `git commit`, `git push`, litmus, or commitlint from the inline body. The dispatcher commit/state-synthesis block invokes `scripts/dispatcher-commit-block.sh` with `NO_WORKTREE=1`; that script enforces the clean-index pre-condition, runs litmus, commits, pushes, and returns the authoritative `RESULT_COMMIT_SHA` / `RESULT_REVIEWER_ACKS` envelope.

If you didn't change any files this round (no actionable findings — only waiting for bots to re-review), skip the commit-block and proceed to Step 6.5; HEAD is unchanged and the ledger will reflect bot acks against the existing HEAD.

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
            resolvedBy { login }
            comments(first:1) { nodes { author { login } createdAt } }
            resolutionComments: comments(last:10) { nodes { author { login } createdAt } }
          }
        }
      }
    }
  }
' -f owner="$OWNER" -f repo="$REPO" -F pr="$PR" 2>/dev/null) || FETCH_OK=0
ALL_REVIEWS=$(gh api --paginate "repos/$OWNER/$REPO/pulls/$PR/reviews" 2>/dev/null) || FETCH_OK=0
ALL_COMMENTS=$(gh pr view "$PR" --comments --json comments 2>/dev/null) || FETCH_OK=0
# Content-identity carry-forward: a bot ack on SHA_old still HEAD-acks when git
# PROVES SHA_old is content-identical to HEAD — same tree AND same parents, i.e. a
# message-only `git commit --amend` force-push (commitlint fix, DCO sign-off, GPG
# re-sign, message typo). Without it, a fresh SHA with zero code delta makes every
# SHA-anchored tier miss and the gate poll-then-bail at --max-wait every time.
# Tiers B (/reviews) and C (body-SHA) are PR-wide, so ack-ledger.sh's acks_head()
# carries them forward on its own. Tier D (check-runs) is HEAD-scoped — the augment
# source below (run after this fetch, before the ledger call) widens ALL_CHECK_RUNS
# with the content-identical predecessor's check-runs so Tier D can ack them
# (re-proven via acks_head(head_sha)). Tier E
# (statuses) is NOT carried forward (no SHA to re-prove); it stays correct on its own
# HEAD fetch. Timestamp-FREE (git object hashes, not backdatable dates — does NOT relax
# the #186/#189 posture), parent-pinned (rejects rebases), fails CLOSED. Disable with
# ACK_CONTENT_IDENTITY=0. See ack-ledger.sh, augment-equiv-acks.sh + ADR 0004.
# Source 5: check-runs on HEAD — bots like Cubic emit a check-run instead of
# a /reviews entry; tier D in scripts/ack-ledger.sh treats a passing check_run
# whose head_sha == HEAD as a HEAD-ack. (CodeRabbit uses a separate Source 6
# below — its private-repo signal lives in the legacy commit-statuses API.)
ALL_CHECK_RUNS=$(gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_SHA/check-runs" 2>/dev/null) || FETCH_OK=0
# Source 6: commit statuses on HEAD — CodeRabbit on private repos uses the
# legacy commit-statuses API (no check-run registered). Tier E in
# scripts/ack-ledger.sh maps the bot login to a context string and treats a
# latest-by-timestamp `state=success` as a HEAD-ack.
ALL_STATUSES=$(gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_SHA/statuses" 2>/dev/null) || FETCH_OK=0
# Source 7: issue-level reactions + HEAD push time — Codex's clean signal is
# a 👍 reaction (Tier F), not a SHA-keyed ack. --paginate so Codex's reaction
# isn't missed behind >30 human PR-body reactions (Tier F slurps the stream).
ALL_REACTIONS=$(gh api --paginate "repos/$OWNER/$REPO/issues/$PR/reactions" 2>/dev/null) || FETCH_OK=0
HEAD_COMMITTED_DATE=$(gh api "repos/$OWNER/$REPO/commits/$HEAD_SHA" --jq '.commit.committer.date' 2>/dev/null || echo "")
# HEAD_PUSH_DATE: push event timestamp — the SOLE Tier-F +1 freshness anchor.
# --paginate + slurp (jq -rs) so the PushEvent for HEAD is found even when it lands
# on a later events page; without pagination a HEAD push beyond the first page yields
# empty. Best-effort; exports empty on failure or no match, in which case Tier F fails
# CLOSED to stale (no committer fallback — the committer date is backdatable, #189).
# HEAD_COMMITTED_DATE is fetched best-effort and NOT gated on FETCH_OK (nothing reads it).
HEAD_FULL_SHA=$(git rev-parse HEAD)
# Branch filter prevents anchoring on a PushEvent from a different branch that
# shares the same tip SHA. fetch-pr-state.sh uses the same guard; keep in sync.
PR_BRANCH=$(gh pr view "$PR" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")
_ref="refs/heads/${PR_BRANCH:-}"
HEAD_PUSH_DATE=$(gh api --paginate "repos/$OWNER/$REPO/events?per_page=100" 2>/dev/null \
  | jq -rs --arg head "$HEAD_FULL_SHA" --arg ref "$_ref" \
    '[.[]? | .[]? | select(.type=="PushEvent" and .payload.head==$head and (if $ref != "refs/heads/" then .payload.ref==$ref else false end))] | sort_by(.created_at) | last | .created_at // empty' 2>/dev/null || echo "")
# HEAD_CHECKS_DATE (#269): BRANCH+SHA-bound fallback freshness anchor. HEAD_PUSH_DATE
# (PushEvent) is preferred, but it is empty for a brand-new branch whose FIRST push CREATED
# the ref (GitHub emits a CreateEvent, not a PushEvent) — a genuine fresh Codex 👍 then
# fail-closes to stale forever. Fall back to the earliest check-SUITE created_at stamped for
# THIS branch AND THIS HEAD SHA (select head_branch==branch AND head_sha==full-oid). GitHub
# stamps the suite created_at when HEAD is pushed to the branch, marking when THIS SHA landed
# on THIS branch — a suite from another branch/run that merely shares the SHA has a different
# head_branch and is EXCLUDED, so it cannot make a stale +1 look fresh. Unlike a check-RUN
# started_at or the committer date, the suite created_at is NOT app/client-settable (preserves
# #186/#189). No matching suite (no CI yet, fork ns) → empty → ack-ledger fails closed.
HEAD_CHECKS_DATE=""
if [ -z "$HEAD_PUSH_DATE" ] && [ -n "${PR_BRANCH:-}" ] && [ -n "${HEAD_FULL_SHA:-}" ]; then
  HEAD_CHECKS_DATE=$(gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_FULL_SHA/check-suites" 2>/dev/null \
    | jq -rs --arg branch "$PR_BRANCH" --arg sha "$HEAD_FULL_SHA" \
      '[.[].check_suites[]? | select(.head_branch==$branch and .head_sha==$sha) | .created_at] | map(select(. != null and . != "")) | sort | .[0] // empty' 2>/dev/null || echo "")
fi

# Per-bot ack — algorithm lives in scripts/ack-ledger.sh (single source of
# truth for this site, the worker's Step 6.5 in agents/pr-grinder.md, and the
# dispatcher's Completion site below). The script reads FETCH_OK / ALL_THREADS /
# ALL_REVIEWS / ALL_COMMENTS / ALL_CHECK_RUNS / ALL_STATUSES / ALL_REACTIONS /
# HEAD_COMMITTED_DATE / HEAD_PUSH_DATE / HEAD_SHA from env and the bot login from $1.
# Tier D carry-forward across message-only force-pushes: check-runs are HEAD-scoped,
# so a bot's check-run on the PRE-amend SHA is invisible. Widen ALL_CHECK_RUNS with any
# content-identical predecessor's check-runs before the ledger runs (additive,
# best-effort, git-proven; no-op under ACK_CONTENT_IDENTITY=0; Tier E statuses are NOT
# widened). Keep in sync with scripts/fetch-pr-state.sh, agents/pr-grinder.md, and the
# Completion mirror below.
PR_NUMBER="$PR"; AUGMENT_SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/augment-equiv-acks.sh"
[ -f "$AUGMENT_SCRIPT" ] && . "$AUGMENT_SCRIPT"
export FETCH_OK ALL_THREADS ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS ALL_STATUSES ALL_REACTIONS HEAD_COMMITTED_DATE HEAD_PUSH_DATE HEAD_CHECKS_DATE HEAD_SHA HEAD_FULL_SHA
ACK_SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/ack-ledger.sh"
# One call per bot with ACK_EMIT_TIER=1 → "<sha>:<tier>" on a HEAD-ack, bare
# none/stale otherwise. Derive the plain ack ledger (strip ":<tier>") AND the
# tier map. Inline mode runs the same tier-aware Invariant 3 the subagent path
# does (ADR 0001), so it needs the tiers here just as the worker emits them.
_at() { ACK_EMIT_TIER=1 bash "$ACK_SCRIPT" "$1" 2>/dev/null || echo stale; }
_ackpart() { printf '%s' "${1%%:*}"; }
_tierpart() { case "$1" in *:*) printf '%s' "${1##*:}" ;; *) printf 'none' ;; esac; }
_cur=$(_at cursor); _cub=$(_at cubic-dev-ai); _cod=$(_at coderabbitai); _dev=$(_at devin-ai-integration)
ROUND_ACKS="cursor=$(_ackpart "$_cur"),cubic-dev-ai=$(_ackpart "$_cub"),coderabbitai=$(_ackpart "$_cod"),devin-ai-integration=$(_ackpart "$_dev")"
ROUND_ACK_TIERS="cursor=$(_tierpart "$_cur"),cubic-dev-ai=$(_tierpart "$_cub"),coderabbitai=$(_tierpart "$_cod"),devin-ai-integration=$(_tierpart "$_dev")"
echo "Ack ledger: $ROUND_ACKS"
echo "Ack tiers: $ROUND_ACK_TIERS"
# Codex — gated separately via Tier F (👍 reaction). Tracked in its own var,
# NOT folded into ROUND_ACKS (the four SHA-keyed bots, which Invariant 3
# intersects). A stale Codex blocks `clean` exactly like a stale registered bot.
ROUND_CODEX_ACK=$(_ackpart "$(_at chatgpt-codex-connector)")
echo "Codex ack: $ROUND_CODEX_ACK"

# Compute STALE_BOTS over the registered four PLUS Codex (appended only for
# this throwaway staleness scan — ROUND_ACKS itself stays the four-bot
# contract). A stale entry from either source blocks `clean`.
STALE_BOTS=$(echo "$ROUND_ACKS,chatgpt-codex-connector=$ROUND_CODEX_ACK" | tr ',' '\n' | awk -F= '$2=="stale"{print $1}')
echo "STALE_BOTS: $STALE_BOTS"
```

(The Codex sole-stale-blocker auto-re-trigger is **not** invoked inside this Bash block — this block runs *after* the commit-block (Step 6), so the working tree is clean even on a fix-round and a shell guard cannot tell a wait-round apart. It is invoked from the Claude-interpreted "Acting on the result" step below, where the wait-round vs fix-round distinction is known.)

**Acting on the result (instruction to Claude, not shell control flow):** the `STALE_BOTS` variable lives only inside the Bash invocation that runs the snippet above — it does NOT persist into a subsequent inline-loop iteration. After the snippet runs, **Claude reads the printed `Ack ledger:` and `STALE_BOTS:` lines from stdout** and decides:

- **STALE_BOTS empty** → round genuinely complete; proceed to Step 7 (autonomous summary or interactive checkpoint), which will either continue to the next round or dispatch Completion depending on whether checks are green and all findings are resolved.
- **STALE_BOTS non-empty** → round is in waiting-for-bots state; **skip Step 7 entirely** and re-dispatch Step 1 directly (analogous to the Sonnet subagent's `needs_more + RESULT_COMMIT_SHA=none + stale-acks` flow that the dispatcher's relaxed Invariant 1 permits). Increment the round counter as normal.
  - **Codex sole-stale-blocker auto-re-trigger (one-shot per HEAD; ADR 0005).** If — AND ONLY IF — this is a **wait-round** (you did NOT run the commit-block this round, so HEAD is unchanged) **and** `STALE_BOTS` is *exactly* `chatgpt-codex-connector` (every registered bot already acked HEAD; Codex is the sole blocker), run the helper ONCE before re-dispatching so Codex re-reviews the unchanged HEAD it would otherwise never self-ack (it posts COMMENTED reviews / 0 reactions, and its thread resolutions predate the last push) — without it the gate dead-ends at `--max-wait`:

    This runs as its own Bash invocation, so per the "CWD Reset Across Bash Calls" contract it MUST open with `cd "$WORKTREE_DIR"` (template-substituted to the literal Step 0 path). Do NOT rely on `$PR` / `$HEAD_SHA` persisting from the Step 6.5 block (shell vars do not survive across Bash calls) and do NOT trust the inherited CWD: `$WORKTREE_DIR` and `$PR_NUMBER` are the Step 0 literals, and HEAD is read inside the correct worktree after the cd. The cd runs in a subshell and ABORTS on failure (`|| exit 0`) so a bad `WORKTREE_DIR` never lets git/gh run in the wrong repo:

    ```bash
    ( cd "$WORKTREE_DIR" || exit 0
      bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-retrigger.sh" "$PR_NUMBER" "$(git rev-parse HEAD)" || true )
    ```

    Do NOT run it on a fix-round: the commit-block already pushed a new HEAD, which re-triggers Codex on its own. The wait-round condition is the inline analogue of the dispatcher's `RESULT_COMMIT_SHA == "none"` and the worker's clean-working-tree gate. One-shot + opt-out (`PR_GRIND_CODEX_RETRIGGER=0`) + phrase override (`PR_GRIND_CODEX_RETRIGGER_PHRASE`) live in the helper (`${CLAUDE_PLUGIN_ROOT}` is a session env var, so it persists). `|| true` keeps a failed post from ever staling the gate. Distinct from the COMPLETION first-engagement grace, which only RE-POLLS a `none` Codex (never a `stale` one).

**Interaction with `--max-fix` / `--max-wait`:** wait-rounds count against `--max-wait` (default 8), NOT against `--max-fix` (default 5). The split fixed a real failure mode in the previous unified `--max` budget: every wait-round consumed a fix slot, so a PR with 3 fix iterations + 4 slow-bot polls would exhaust at `--max=5` even though only 3 fixes happened. With the dual budget, fix-budget reflects *engineering effort* and wait-budget reflects *bot latency tolerance* — orthogonal concerns. Either exhausted budget bails with a specific reason: `max-fix iterations (<MAX_FIX>) reached without clean status` (raise `--max-fix` if grinding a PR with many feedback rounds) or `max-wait iterations (<MAX_WAIT>) reached without all bots acking HEAD; latest stale: <STALE_AT_BAIL>` (raise `--max-wait` if grinding a PR with known-slow reviewer bots; `STALE_AT_BAIL` is the dispatcher-side derivation from `PRIOR_REVIEWER_ACKS` plus `PRIOR_CODEX_ACK` — see `ON_LOOP_EXHAUSTED` in the Dispatcher Loop above. Note: this is distinct from Step 6.5's transient `$STALE_BOTS` bash variable, which lives only inside the ledger snippet and does not survive into the bail handler). The legacy `--max N` flag is a deprecated alias that sets both budgets to N (emits a `⚠️  --max is deprecated; use --max-fix and --max-wait` warning at dispatch start) and CANNOT be combined with `--max-fix` or `--max-wait` — combining them bails with reason `conflicting flags: --max cannot be combined with --max-fix or --max-wait`.

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
RESULT_REVIEWER_ACKS: cursor=stale,cubic-dev-ai=stale,coderabbitai=stale,devin-ai-integration=stale
RESULT_ACK_TIERS: cursor=none,cubic-dev-ai=none,coderabbitai=none,devin-ai-integration=none
RESULT_CODEX_ACK: stale
RESULT_BOT_LEDGER: cursor=0/0:none,cubic-dev-ai=0/0:none,coderabbitai=3/3:fixed relatedTools paths+scope-skipped:schema-refactor:1+scope-skipped:external-research:1,devin-ai-integration=0/0:none,codescene-delta-analysis=0/0:none,chatgpt-codex-connector=0/0:none
RESULT_ISSUES_SPAWNED: 847,848
```

**Dispatcher state after Round 3:**

```text
total_scope_skipped: 0 + 2 = 2  (well under cap of 5)
total_issues_spawned: 0 + 2 = 2  (well under cap of 3)
Invariant 4: pass (both under cap)
PRIOR_ATTEMPTS:
  - Round 3 (fix=2/5, wait=0/8): fixes=remove /blog/* paths from 4 relatedTools blocks; failures=none; acks=cursor=stale,...; scope-skipped=2; spawned=2
```

**Round 4 (next worker dispatch).** Bots re-review `4361cc54`. CodeRabbit's prior threads are now resolved (worker closed them in Round 3); `scripts/ack-ledger.sh` tier A counts the resolved threads against HEAD-ack rather than `stale` (the change in this PR). All four bots clear, grind converges to `clean`, dispatcher hits COMPLETION.

**Total grind:** 4 rounds (was 7+ rounds + manual intervention before this carve-out existed). 2 dismissals consumed (under cap), 2 follow-up issues spawned (under cap). The two architectural findings live as `#847` and `#848` for separate PRs to address with proper scope.

**What would BAIL.** If the worker dismisses a 6th finding across the grind (cumulative cap ≤5 inclusive — 5 allowed, 6th BAILs), Invariant 4 fires at the start of the next round with `RESULT_BAIL_CATEGORY=judgment` and reason `out-of-scope dismissal count is 6 across N rounds — exceeds discipline rail of 5; operator review required`. Operator decides whether the PR's scope is wrong (split it) or the worker is misclassifying (interactive review of the dismissals). Same shape applies to the spawn cap: 3 spawns allowed, the 4th BAILs.

## Completion (post-loop, dispatcher only)

**All of these must be true before declaring done:**
1. Subagent returned `RESULT_STATUS=clean` (or inline mode reached the same state)
2. All required CI checks passing (build, lint, test)
3. All automated reviewers completed (CodeRabbit, Cursor, Cubic, etc.). Codex (`chatgpt-codex-connector`) has no GitHub check, but it IS waited on via `ack-ledger.sh` Tier F: its 👍 reaction (clean) or findings on HEAD (Tiers A/B) must ack the current HEAD, surfaced as `RESULT_CODEX_ACK` and re-checked in the COMPLETION gate's `FRESH_ACKS` scan. A `stale` Codex blocks completion just like a stale registered bot; its findings are additionally triaged via Step 2.6 enumeration.
4. No unresolved actionable comments from any source
5. No new comments arrived after your last push (wait for the full cycle)
6. Advisory check issues either fixed or noted as beyond PR scope
7. **Reviewer ack ledger**: every registered bot (Cursor, Cubic, CodeRabbit) is either `<HEAD-short-SHA>` or `none` in `RESULT_REVIEWER_ACKS`. Any `stale` entry blocks completion — the bot finished its check but hasn't re-reviewed HEAD yet, and merging now would race ahead of its findings. (`none` here can mean "bot doesn't operate on this repo" OR "bot's only reviews are infra-error/rate-limit markers that cannot self-recover" OR "bot only posted a non-actionable PR-overview summary on an older commit" OR "bot acknowledged HEAD via a check-run with conclusion=skipped and non-actionable body (e.g., cubic-dev-ai on merge commits)" — all four cases are non-gating; see `scripts/ack-ledger.sh`'s downgrade Cases 1, 2, and 3. Note: Tier E (commit-statuses API) does NOT produce `none` — a `success` status returns HEAD-ack, and a `pending`/`failure`/`error` status returns `stale` to block on the live reviewer signal.) Codex is gated too, but tracked in its own `RESULT_CODEX_ACK` field (Tier F 👍 reaction), not in `RESULT_REVIEWER_ACKS` — a `stale` Codex blocks completion identically; `none` (never reacted/reviewed on this PR) is non-gating.

**Re-query the ack ledger fresh (REQUIRED — defense in depth against late posts between subagent return and merge time):**

The dispatcher must re-run the same `scripts/ack-ledger.sh` lookup the worker used in Step 6.5, against all live ack-ledger sources (review threads, `/reviews`, issue comments, check-runs, and commit statuses), with HEAD recomputed against the current branch state. Just re-parsing `$RESULT_REVIEWER_ACKS` would only validate the worker's snapshot — it can't catch a bot that finished re-reviewing in the seconds between subagent return and merge.

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
            resolvedBy { login }
            comments(first:1) { nodes { author { login } createdAt } }
            resolutionComments: comments(last:10) { nodes { author { login } createdAt } }
          }
        }
      }
    }
  }
' -f owner="$OWNER" -f repo="$REPO" -F pr="$PR" 2>/dev/null) || FETCH_OK=0
ALL_REVIEWS=$(gh api --paginate "repos/$OWNER/$REPO/pulls/$PR/reviews" 2>/dev/null) || FETCH_OK=0
ALL_COMMENTS=$(gh pr view "$PR" --comments --json comments 2>/dev/null) || FETCH_OK=0
# Source 5: check-runs on HEAD — same as worker/Step 6.5 fetch above.
# (Despite "same four sources" wording elsewhere — that count refers to
# findings sources; ack-ledger reads six sources: 1-4 above plus check-runs
# and commit statuses.)
ALL_CHECK_RUNS=$(gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_SHA/check-runs" 2>/dev/null) || FETCH_OK=0
# Source 6: commit statuses on HEAD — same as worker/Step 6.5 fetch above.
ALL_STATUSES=$(gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_SHA/statuses" 2>/dev/null) || FETCH_OK=0
# Source 7: issue-level reactions + HEAD push time for Codex's Tier-F gate
# (👍 reaction). --paginate so Codex's reaction isn't missed behind >30 human
# PR-body reactions (Tier F slurps the page stream).
ALL_REACTIONS=$(gh api --paginate "repos/$OWNER/$REPO/issues/$PR/reactions" 2>/dev/null) || FETCH_OK=0
HEAD_COMMITTED_DATE=$(gh api "repos/$OWNER/$REPO/commits/$HEAD_SHA" --jq '.commit.committer.date' 2>/dev/null || echo "")
# HEAD_PUSH_DATE: push event timestamp — the SOLE Tier-F +1 freshness anchor.
# --paginate + slurp (jq -rs) so the PushEvent for HEAD is found even when it lands
# on a later events page; without pagination a HEAD push beyond the first page yields
# empty. Best-effort; exports empty on failure or no match, in which case Tier F fails
# CLOSED to stale (no committer fallback — the committer date is backdatable, #189).
# HEAD_COMMITTED_DATE is fetched best-effort and NOT gated on FETCH_OK (nothing reads it).
HEAD_FULL_SHA=$(git rev-parse HEAD)
# Branch filter prevents anchoring on a PushEvent from a different branch that
# shares the same tip SHA. fetch-pr-state.sh uses the same guard; keep in sync.
PR_BRANCH=$(gh pr view "$PR" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")
_ref="refs/heads/${PR_BRANCH:-}"
HEAD_PUSH_DATE=$(gh api --paginate "repos/$OWNER/$REPO/events?per_page=100" 2>/dev/null \
  | jq -rs --arg head "$HEAD_FULL_SHA" --arg ref "$_ref" \
    '[.[]? | .[]? | select(.type=="PushEvent" and .payload.head==$head and (if $ref != "refs/heads/" then .payload.ref==$ref else false end))] | sort_by(.created_at) | last | .created_at // empty' 2>/dev/null || echo "")
# HEAD_CHECKS_DATE (#269): BRANCH+SHA-bound fallback freshness anchor. HEAD_PUSH_DATE
# (PushEvent) is preferred, but it is empty for a brand-new branch whose FIRST push CREATED
# the ref (GitHub emits a CreateEvent, not a PushEvent) — a genuine fresh Codex 👍 then
# fail-closes to stale forever. Fall back to the earliest check-SUITE created_at stamped for
# THIS branch AND THIS HEAD SHA (select head_branch==branch AND head_sha==full-oid). GitHub
# stamps the suite created_at when HEAD is pushed to the branch, marking when THIS SHA landed
# on THIS branch — a suite from another branch/run that merely shares the SHA has a different
# head_branch and is EXCLUDED, so it cannot make a stale +1 look fresh. Unlike a check-RUN
# started_at or the committer date, the suite created_at is NOT app/client-settable (preserves
# #186/#189). No matching suite (no CI yet, fork ns) → empty → ack-ledger fails closed.
HEAD_CHECKS_DATE=""
if [ -z "$HEAD_PUSH_DATE" ] && [ -n "${PR_BRANCH:-}" ] && [ -n "${HEAD_FULL_SHA:-}" ]; then
  HEAD_CHECKS_DATE=$(gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_FULL_SHA/check-suites" 2>/dev/null \
    | jq -rs --arg branch "$PR_BRANCH" --arg sha "$HEAD_FULL_SHA" \
      '[.[].check_suites[]? | select(.head_branch==$branch and .head_sha==$sha) | .created_at] | map(select(. != null and . != "")) | sort | .[0] // empty' 2>/dev/null || echo "")
fi

# Per-bot ack — same single-sourced algorithm as the worker's Step 6.5 and
# the inline ledger block in Step 6.5 above. All three sites invoke
# scripts/ack-ledger.sh; algorithm edits live in that one file.
# Tier D carry-forward across message-only force-pushes: widen the HEAD-scoped
# check-runs with any content-identical predecessor's check-runs before the ledger
# runs (additive, best-effort, git-proven; no-op under ACK_CONTENT_IDENTITY=0; Tier E
# statuses are NOT widened). Keep in sync with scripts/fetch-pr-state.sh,
# agents/pr-grinder.md, and the worker mirror above.
PR_NUMBER="$PR"; AUGMENT_SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/augment-equiv-acks.sh"
[ -f "$AUGMENT_SCRIPT" ] && . "$AUGMENT_SCRIPT"
export FETCH_OK ALL_THREADS ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS ALL_STATUSES ALL_REACTIONS HEAD_COMMITTED_DATE HEAD_PUSH_DATE HEAD_CHECKS_DATE HEAD_SHA HEAD_FULL_SHA
ACK_SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/ack-ledger.sh"
# Codex (chatgpt-codex-connector) is appended as a fourth gated reviewer here:
# its Tier-F 👍 reaction is the authoritative clean signal, and a `stale` value
# (still reviewing, or hasn't re-acked HEAD after the last push) must block the
# merge exactly like a stale registered bot. It is NOT in RESULT_REVIEWER_ACKS
# (the four SHA-keyed bots feeding Invariant 3) — only in this final gate scan.
FRESH_ACKS="cursor=$(bash "$ACK_SCRIPT" cursor 2>/dev/null || echo stale),cubic-dev-ai=$(bash "$ACK_SCRIPT" cubic-dev-ai 2>/dev/null || echo stale),coderabbitai=$(bash "$ACK_SCRIPT" coderabbitai 2>/dev/null || echo stale),devin-ai-integration=$(bash "$ACK_SCRIPT" devin-ai-integration 2>/dev/null || echo stale),chatgpt-codex-connector=$(bash "$ACK_SCRIPT" chatgpt-codex-connector 2>/dev/null || echo stale)"
# Codex first-engagement grace. If Codex resolved to `none` — zero reaction/
# review on the PR — it may simply not have posted its initial 👀 on a just-
# pushed HEAD yet; without this a Codex-ONLY repo (no registered bots forcing
# wait-rounds) could merge in the gap before Codex starts. Give it ONE bounded
# re-poll. This rarely fires: COMPLETION is reached only after the loop has
# converged, by which point an active Codex has long since engaged (ack is a
# SHA/stale, not `none`) — so on repos where Codex runs there is no wait here.
# Set PR_GRIND_CODEX_GRACE_SECS=0 on repos that do not use Codex to skip the
# one-time wait. Bounded by design; never an unbounded hang.
# This grace handles ONLY the `none` case (Codex never engaged). The `stale` case —
# Codex reviewed but won't re-ack an UNCHANGED HEAD — is handled earlier, in the
# LOOP, by the codex-retrigger one-shot (ADR 0005, scripts/codex-retrigger.sh):
# COMPLETION is unreachable while Codex is `stale` (Invariant 2 blocks `clean`), so
# the recovery for `stale` must live in the wait-round, not here.
CODEX_DONE=$(printf '%s' "$FRESH_ACKS" | tr ',' '\n' | awk -F= '$1=="chatgpt-codex-connector"{print $2}')
CODEX_GRACE="${PR_GRIND_CODEX_GRACE_SECS:-20}"
if [ "$CODEX_DONE" = "none" ] && [ "${CODEX_GRACE}" -gt 0 ] 2>/dev/null; then
  echo "ℹ️  Codex shows no engagement on HEAD; ${CODEX_GRACE}s first-engagement grace re-poll…"
  sleep "$CODEX_GRACE"
  # Refresh ALL Codex-relevant sources, not just reactions: during the grace
  # Codex may post FINDINGS (inline threads → Tier A, or a /reviews entry whose
  # commit_id is HEAD → Tier B), not only a clean 👍. Refreshing reactions alone
  # would leave ack-ledger reading the stale pre-sleep threads/reviews and miss
  # findings that arrived in the window — passing the gate with untriaged Codex
  # findings. (Tiers C/D/E don't apply to Codex, so their snapshots can stand.)
  ALL_REACTIONS=$(gh api --paginate "repos/$OWNER/$REPO/issues/$PR/reactions" 2>/dev/null) || FETCH_OK=0
  ALL_REVIEWS=$(gh api --paginate "repos/$OWNER/$REPO/pulls/$PR/reviews" 2>/dev/null) || FETCH_OK=0
  ALL_THREADS=$(gh api graphql --paginate -f query='
    query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String) {
      repository(owner:$owner,name:$repo) {
        pullRequest(number:$pr) {
          reviewThreads(first:100, after:$endCursor) {
            pageInfo { hasNextPage endCursor }
            nodes {
              isResolved isOutdated
              resolvedBy { login }
              comments(first:1) { nodes { author { login } createdAt } }
              resolutionComments: comments(last:10) { nodes { author { login } createdAt } }
            }
          }
        }
      }
    }
  ' -f owner="$OWNER" -f repo="$REPO" -F pr="$PR" 2>/dev/null) || FETCH_OK=0
  export ALL_REACTIONS ALL_REVIEWS ALL_THREADS FETCH_OK
  CODEX_REGRACE=$(bash "$ACK_SCRIPT" chatgpt-codex-connector 2>/dev/null || echo stale)
  # Re-fold only if Codex engaged during the grace (now `stale` or a fresh SHA);
  # SHA → still passes, `stale` → blocks below. SHAs/stale/none are sed-safe.
  [ "$CODEX_REGRACE" != "none" ] && FRESH_ACKS=$(printf '%s' "$FRESH_ACKS" | sed "s/chatgpt-codex-connector=none/chatgpt-codex-connector=${CODEX_REGRACE}/")
fi
STALE_BOTS=$(echo "$FRESH_ACKS" | tr ',' '\n' | awk -F= '$2=="stale"{print $1}')
if [ -n "$STALE_BOTS" ]; then
  echo "❌ BLOCKED: AI reviewer(s) with stale ack at merge time: $STALE_BOTS"
  echo "   Re-run the loop or wait for the bot(s) to ack HEAD ($HEAD_SHA)."
  echo "   (chatgpt-codex-connector stale = Codex still reviewing / no 👍 newer than HEAD.)"
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
# Lock-aware filter — scripts/relevant-check-status.sh (issue #154). Pass the
# repo-ROOT DIR (reads .github/required-checks.lock), NOT the repo name.
# Fail-CLOSED: any error → conservative blocking "1 0 all 0".
REPO_DIR=$(git rev-parse --show-toplevel)
COUNTS=$(printf '%s\n' "$CHECKS_RAW" | bash "${CLAUDE_PLUGIN_ROOT}/scripts/relevant-check-status.sh" "$REPO_DIR" 2>/dev/null || printf '1 0 all 0\n')
read -r FAILED PENDING MODE KEPT <<<"$COUNTS"
# Guards (mirror the gate): empty/garbled output → blocking; and green requires
# no failures AND nothing pending AND at least one relevant check ran. KEPT=0 in
# required mode means a required check never posted (no evidence) — the gate's
# KEPT>0 bootstrap guard refuses that, so the clean marker must too.
if [ -z "${MODE:-}" ] || [ -z "${FAILED:-}" ] || [ -z "${KEPT:-}" ]; then FAILED=1; fi
if [ "${FAILED:-1}" -gt 0 ] || [ "${PENDING:-1}" -gt 0 ] || [ "${KEPT:-0}" -eq 0 ]; then
  echo "❌ BLOCKED: cannot declare PR clean (failed=${FAILED} pending=${PENDING} kept=${KEPT} mode=${MODE})."
  printf '%s\n' "$COUNTS" | tail -n +2
  exit 1
fi
```

<EXTREMELY-IMPORTANT>
**CRITICAL: the marker write and `gh pr merge` MUST be TWO SEPARATE Bash tool calls.** Not chained with `&&`/`;`/`|`, not a heredoc that runs both, not a single multi-line command, not a single Bash call that just happens to contain both lines. Two distinct tool calls — first call writes the marker and exits; second call invokes `gh pr merge`. This applies identically to the default-merge block AND the `--admin-on-approver-gap` auto-admin-merge block below — both consume the same marker; the gate fires on both invocation paths.

**Why a single call deadlocks.** `hooks/gate-scripts/pre-merge-gate.sh` is a PreToolUse hook — it fires BEFORE the bash command executes, scans the command argv string for `gh pr merge`, and reads `.claude/pr-grind-clean.local` from disk at that moment. If the marker `echo` lives in the same tool call, the hook samples the filesystem *before* the echo runs, finds no marker, and blocks the entire tool call — NONE of the bash executes, the marker is never written, and the operator sees a misleading "pr-grind has not declared this PR clean" error after pr-grind just finished successfully. This is a TOCTOU between the hook's filesystem read at tool-invocation time and the marker write at bash-execution time inside the same tool call. Splitting into two tool calls separates the two events: the first tool call completes (marker on disk, hook didn't fire), then the hook fires on the second call's `gh pr merge` and sees the marker the first call left behind.

**Confirmed recurrences:** PR #93 (2026-05-12) — the deadlock the PR-#94 callout was first written for. PR #95 (2026-05-13) — recurred *despite* the prior callout because the previous prose was easy to skim past on a top-down read. The "CRITICAL" headline above is the current attempt to make the contract unmissable; do not soften it back into a paragraph.

**The contract:** marker write completes → next Bash call runs the merge. Do NOT inline-combine, even if the chain "looks natural" while you're reading this section.
</EXTREMELY-IMPORTANT>

**Write the pr-grind-clean marker (REQUIRED — pre-merge gate checks `.claude/` at the REPO ROOT of the worktree the merge runs in). Run this as its own Bash tool call:**
```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
mkdir -p "$REPO_ROOT/.claude"
echo "<PR_NUMBER>" > "$REPO_ROOT/.claude/pr-grind-clean.local"
rm -f "$REPO_ROOT/.claude/pr-pending-grind.local"
```

**Branch-Currency Detection (run BEFORE approver-gap):**

After CI is green and bots ack HEAD, GitHub may still reject the merge because branch protection requires the head branch to be up-to-date with the base. This is a different structural gap from approver-count: it surfaces as `mergeStateStatus=BEHIND` and the raw failure is `Pull request is not mergeable: the head branch is not up to date with the base branch`. Detect it up front so the operator sees a tailored decision message instead of a raw `gh pr merge` failure.

**The detection is scoped narrowly:** only `mergeStateStatus=BEHIND` qualifies. Other mergeStateStatus values (`BLOCKED`, `DIRTY`, `UNSTABLE`, `UNKNOWN`) surface via their existing paths (approver-gap detection, failing-required-checks, merge-conflict, etc.). Branch-currency is the specific case where the PR is functionally ready BUT lags behind base; the fix is "incorporate base into the PR branch," which has three legitimate paths.

```bash
PR=<PR_NUMBER>
MERGE_STATE_STATUS=$(gh pr view "$PR" --json mergeStateStatus -q .mergeStateStatus 2>/dev/null || echo "")
case "$MERGE_STATE_STATUS" in
  BEHIND)
    # Surface decision with three operator options below; do NOT auto-pick.
    # Excluded from MAX_FIX/MAX_WAIT accounting — nothing to fix, nothing to wait for.
    # pr-grind BAILs with RESULT_BAIL_CATEGORY=policy (same enum as approver-gap;
    # `policy` covers all dispatcher-emitted structural-blocker bails).
    ;;
  CLEAN|UNSTABLE|HAS_HOOKS|"")
    # Pass through — proceed to Approver-Gap Detection below.
    # UNSTABLE = advisory check failing (e.g., CodeScene); not branch-currency.
    # Empty (mergeStateStatus query failed) = degrade-to-attempt; the merge
    # will surface its own error if base-currency is actually the blocker.
    ;;
  *)
    # BLOCKED / DIRTY / etc. — surface via existing approver-gap or
    # failing-checks paths. Do not BAIL here; let the downstream
    # detection blocks handle their specific cases.
    ;;
esac
echo "MERGE_STATE_STATUS=$MERGE_STATE_STATUS"
```

**Decision tree** (based on `MERGE_STATE_STATUS`):

- **`CLEAN` / `UNSTABLE` / `HAS_HOOKS` / empty** → fall through to Approver-Gap Detection below.
- **`BEHIND`** → BAIL with `RESULT_BAIL_CATEGORY=policy` and surface the operator-decision message (template below). Excluded from MAX_FIX/MAX_WAIT accounting — nothing to fix, nothing to wait for.
- **`BLOCKED` / `DIRTY` / other** → fall through; handled by approver-gap or failing-checks paths.

**Operator-decision message template** (rendered to stdout on BAIL when `MERGE_STATE_STATUS=BEHIND`). Two variants keyed on `AUDIT_WORKFLOW_PRESENT` — same conditional framing as the approver-gap path:

**When `AUDIT_WORKFLOW_PRESENT=1`:**

```text
pr-grind: PR is functionally clean (CI green, bots ack HEAD, threads resolved)
but base branch (<base>) has advanced since the PR branched. Branch protection
requires the head branch to be up-to-date with the base before merge.

Options:
  [update-merge]  gh pr update-branch <PR_NUMBER>
                    # creates a merge commit bringing base into the PR branch.
                    # No force-push; ack-ledger SHAs stay valid. Triggers a
                    # CI re-run + bot re-review on the new merge commit;
                    # plan for 1-2 additional wait-rounds. Cleanest correctness
                    # path when bots tolerate merge commits.
                    # Note on cubic-dev-ai: cubic skips reviewing merge commits
                    # (check-run conclusion=skipped). Ack-ledger Case 3 maps
                    # that to `none` so [update-merge] still converges, but
                    # cubic will appear as `none` rather than HEAD-acked in
                    # the final ledger. If a positive cubic HEAD-ack matters
                    # (e.g., for audit), use [update-rebase] instead — it
                    # forces a fresh review at the cost of 3-5 wait-rounds.
  [update-rebase] gh pr update-branch <PR_NUMBER> --rebase
                    # rebases PR onto base. Force-push, rewrites published
                    # SHAs, invalidates ack-ledger entries (all bots stale).
                    # Triggers full re-review cycle. Cleaner history but
                    # reignites grind — 3-5 rounds likely. Pick when bot
                    # configurations dislike merge commits OR when the PR
                    # history matters for downstream reviewers.
  [admin]         gh pr merge <PR_NUMBER> --squash --delete-branch --admin
                    # admin-merge bypasses the up-to-date requirement.
                    # Defensible when the PR is small + conflict-free and
                    # the base advance was unrelated. Runs outside pr-grind
                    # and writes NO entry to .claude/bypass-log.jsonl. Same
                    # audit posture as the approver-gap [admin] command path.
                    # verify: gh pr view <PR_NUMBER> --json state -q .state
                    # (retry up to 3x with 2s backoff — `gh pr merge
                    #  --delete-branch` can exit non-zero on a worktree-
                    #  checkout conflict even after the remote merge succeeded;
                    #  trust the API state, not the merge exit code)
  [wait]          exit; manually update later
```

**When `AUDIT_WORKFLOW_PRESENT=0`**, demote `[admin]` to last position and prepend a no-audit-trail warning (consistent with the approver-gap path):

```text
pr-grind: PR is functionally clean (CI green, bots ack HEAD, threads resolved)
but base branch (<base>) has advanced since the PR branched. Branch protection
requires the head branch to be up-to-date with the base before merge.
⚠️  This repo has NO bypass-audit.yml — an admin-merge here would leave NO
audit trail. Strongly consider [update-merge] or [update-rebase].

Options:
  [update-merge]  gh pr update-branch <PR_NUMBER>
                    # creates a merge commit bringing base into the PR branch.
                    # No force-push; ack-ledger SHAs stay valid. Triggers a
                    # CI re-run + bot re-review on the new merge commit;
                    # plan for 1-2 additional wait-rounds. Cleanest correctness
                    # path when bots tolerate merge commits.
                    # Note on cubic-dev-ai: cubic skips reviewing merge commits
                    # (check-run conclusion=skipped). Ack-ledger Case 3 maps
                    # that to `none` so [update-merge] still converges, but
                    # cubic will appear as `none` rather than HEAD-acked in
                    # the final ledger. If a positive cubic HEAD-ack matters
                    # (e.g., for audit), use [update-rebase] instead — it
                    # forces a fresh review at the cost of 3-5 wait-rounds.
  [update-rebase] gh pr update-branch <PR_NUMBER> --rebase
                    # rebases PR onto base. Force-push, rewrites published
                    # SHAs, invalidates ack-ledger entries (all bots stale).
                    # Triggers full re-review cycle. Cleaner history but
                    # reignites grind — 3-5 rounds likely. Pick when bot
                    # configurations dislike merge commits OR when the PR
                    # history matters for downstream reviewers.
  [wait]          exit; manually update later
  [admin]         gh pr merge <PR_NUMBER> --squash --delete-branch --admin
                    (no audit trail — proceed only with explicit operator authorization)
                    # verify: gh pr view <PR_NUMBER> --json state -q .state
                    # (retry up to 3x with 2s backoff — trust the API state,
                    #  not the merge exit code)
```

After the operator picks `[update-merge]` or `[update-rebase]`, pr-grind should be re-invoked on the same PR — the new HEAD will trigger fresh bot reviews and (probably) a short wait-round sequence to convergence. After `[admin]`, the PR is merged; pr-grind exits clean.

**Approver-Gap Detection (run BEFORE the merge attempt):**

After CI is green, threads are resolved, and bot acks are HEAD, GitHub may still reject the merge because branch protection demands `required_approving_review_count >= 1` human APPROVED reviews the author cannot self-provide. The dispatcher detects this structural gap up front so the operator sees a tailored decision message instead of a raw `gh pr merge` failure.

**The detection is scoped narrowly:** only the `required_approving_review_count` axis qualifies, and only when CI is green AND every required status check has passed. Other branch-protection failures (failing required checks, missing required signatures, etc.) are NOT approver-gap bails — they surface via their existing paths.

The detection algorithm lives at `scripts/approver-gap-detect.sh` (single source of truth, same factoring pattern as `scripts/ack-ledger.sh`). Callers compose the inputs from `gh api`, export them, and switch on the script's JSON decision:

```bash
PR=<PR_NUMBER>
# Mirror $PR into $PR_NUMBER as a shell variable so the OPTIN_SNAPSHOT path
# below can use `${PR_NUMBER}` consistently with Step 0's writer template.
# Without this, `${PR_NUMBER}` expands to empty in this fresh shell (each
# Bash tool call has fresh shell state) and the detector looks for
# `.pr-grind-solo-opt-in-snapshot-.local`, silently disabling solo-admin
# auto-detect even when Step 0 wrote the correct per-PR snapshot.
PR_NUMBER="$PR"
OWNER=<owner>
REPO=<repo>
# WORKTREE_DIR is propagated from Step 0 (see "WORKTREE_DIR=$WORKTREE_DIR"
# marker line). Required here because the solo-admin opt-in resolution below
# uses `git -C "$WORKTREE_DIR"` to derive MAIN_REPO_ROOT_FOR_OPTIN — a plain
# `git rev-parse` is CWD-sensitive, and CWD does not reliably persist across
# Claude Bash tool calls (see EXTREMELY-IMPORTANT block near top). If CWD has
# drifted to another repo checkout when Completion runs, a bare `git rev-parse`
# could read another repo's opt-in/snapshot for the same PR number, enabling
# unintended auto-merge or silently missing the target repo's valid opt-in.
WORKTREE_DIR=<absolute path from Step 0>

BRANCH=$(gh pr view "$PR" --json baseRefName -q .baseRefName 2>/dev/null || echo "")
AUTHOR=$(gh pr view "$PR" --json author -q .author.login 2>/dev/null || echo "")

# Compose the input JSON blobs / status flags the detection script consumes
# (see scripts/approver-gap-detect.sh header for the contract). Empty/missing
# inputs degrade the decision toward "surface-decision" or "no-gap"; the
# script NEVER auto-escalates without complete inputs.
BRANCH_RULES_JSON=""
CLASSIC_PROTECTION_JSON=""
if [ -n "$BRANCH" ]; then
  BRANCH_ENCODED=$(printf '%s' "$BRANCH" | jq -sRr @uri)
  BRANCH_RULES_JSON=$(gh api "repos/$OWNER/$REPO/rules/branches/$BRANCH_ENCODED" 2>/dev/null || echo "")
  # Classic branch protection — the detector reads the required-review count from
  # BOTH rulesets AND classic protection (max), because a repo can enforce the
  # approver requirement via either mechanism. MUST be the PARENT endpoint
  # /branches/<b>/protection: its .required_pull_request_reviews is ground truth,
  # whereas the /required_pull_request_reviews SUB-endpoint phantom-reports
  # count=1 even when unenforced (would manufacture a false approver gap).
  CLASSIC_PROTECTION_JSON=$(gh api "repos/$OWNER/$REPO/branches/$BRANCH_ENCODED/protection" 2>/dev/null || echo "")
fi
PR_REVIEWS_JSON=$(gh api "repos/$OWNER/$REPO/pulls/$PR/reviews" 2>/dev/null || echo "")
AUTHOR_PERM_JSON=""
if [ -n "$AUTHOR" ]; then
  AUTHOR_PERM_JSON=$(gh api "repos/$OWNER/$REPO/collaborators/$AUTHOR/permission" 2>/dev/null || echo "")
fi
AUDIT_WORKFLOW_PRESENT=0
if gh api "repos/$OWNER/$REPO/contents/.github/workflows/bypass-audit.yml" >/dev/null 2>&1; then
  AUDIT_WORKFLOW_PRESENT=1
fi
# Caller asserts CI/bots clean: the Completion path runs this script only
# after the `gh pr checks` verification + `scripts/ack-ledger.sh` re-query
# both pass. If either fails earlier, the script is not invoked at all.
CI_AND_BOTS_CLEAN=1
# --admin-on-approver-gap flag from the pr-grind invocation. Off by default.
# Template-substituted by the dispatcher (Claude) at run time — the literal
# 0 or 1 is written into the script before bash sees it. See "Resolve
# flag-to-state translations" in START for the producer site. The reason
# this is NOT `${ADMIN_FLAG_PASSED:-0}` is that bash exports do not survive
# across Claude Bash tool calls (each call gets a fresh shell), so the
# fallback would always resolve to 0 regardless of what the operator
# passed — silently neutralizing --admin-on-approver-gap.
ADMIN_FLAG_PASSED=<0|1 — see "Resolve flag-to-state translations" in START>

# Solo-admin auto-detect (per-repo opt-in). The .local file is the operator's
# durable consent for this repo — when present AND the structural sole-admin
# check still holds, the detector treats it as equivalent to passing
# --admin-on-approver-gap, but logs with a distinct event for forensics. The
# count is computed via gh api so the script can verify the assumption is
# STILL TRUE at merge time (a contractor added since the opt-in invalidates
# it). Fail-CLOSED: any gh failure leaves HUMAN_ADMIN_COUNT=0, which the
# script treats as "unknown" and refuses to auto-escalate.
#
# Anti-self-bypass: opt-in fires ONLY when the Step 0 snapshot file
# `.claude/.pr-grind-solo-opt-in-snapshot-${PR_NUMBER}.local` exists AND its
# recorded mtime matches the opt-in file's current mtime. Step 0 writes
# the snapshot only when the opt-in file was already ≥30s old at pr-grind
# invocation start (NOT at Completion time — a slow pr-grind run can
# easily exceed 30s, so checking at Completion would defeat the freshness
# gate). A mid-run touch/replace produces a snapshot/current-mtime
# mismatch → opt-in invalidated. The snapshot path is per-PR so concurrent
# pr-grind runs on different PRs don't collide on shared state. Both the
# opt-in file and the snapshot live in the MAIN repo's .claude/ (not the
# ephemeral worktree's). See Step 0's snapshot writer for the producer side.
# Resolve MAIN_REPO_ROOT via `git -C "$WORKTREE_DIR"` (NOT bare `git rev-parse`)
# to anchor against the dispatcher's known worktree path rather than current
# CWD. CWD drift between Bash tool calls would otherwise let this block read
# another repo's opt-in/snapshot for the same PR number. WORKTREE_DIR
# correctly resolves to the main-repo .git/ via --git-common-dir in both
# worktree mode (linked worktree → shared .git/) and --no-worktree mode
# (WORKTREE_DIR == main repo, --git-common-dir → .git/).
#
# Two-step resolve so a failed `git -C` doesn't pass `dirname ""` ⇒ "."
# silently through the non-empty check below and reintroduce the wrong-repo
# read this whole resolver exists to prevent. Require an absolute path
# (leading slash) before accepting MAIN_REPO_ROOT_FOR_OPTIN.
MAIN_REPO_ROOT_FOR_OPTIN=""
if [ -n "$WORKTREE_DIR" ]; then
  GIT_COMMON_DIR=$(git -C "$WORKTREE_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  if [ -n "$GIT_COMMON_DIR" ]; then
    CANDIDATE=$(dirname "$GIT_COMMON_DIR")
    case "$CANDIDATE" in
      /*) MAIN_REPO_ROOT_FOR_OPTIN="$CANDIDATE" ;;
      *)  : ;;   # reject anything not absolute (defends against dirname returning ".")
    esac
  fi
fi
SOLO_ADMIN_OPT_IN=0
if [ -n "$MAIN_REPO_ROOT_FOR_OPTIN" ]; then
  OPTIN_FILE="$MAIN_REPO_ROOT_FOR_OPTIN/.claude/pr-grind-auto-admin-solo.local"
  # Per-PR snapshot path — must match Step 0's snapshot writer exactly.
  # Step 0 uses ${PR_NUMBER} as the template placeholder; use the same name
  # here so a future change that treats these as actual shell variables rather
  # than dispatcher-substituted literals cannot silently diverge the two paths.
  OPTIN_SNAPSHOT="$MAIN_REPO_ROOT_FOR_OPTIN/.claude/.pr-grind-solo-opt-in-snapshot-${PR_NUMBER}.local"
  if [ -f "$OPTIN_FILE" ] && [ -f "$OPTIN_SNAPSHOT" ]; then
    CURRENT_MTIME=$(stat -c %Y "$OPTIN_FILE" 2>/dev/null || stat -f %m "$OPTIN_FILE" 2>/dev/null || echo 0)
    SNAPSHOT_MTIME=$(head -n1 "$OPTIN_SNAPSHOT" 2>/dev/null | tr -dc '0-9')
    # Snapshot FILE mtime (filesystem) — must be ≥30s AFTER opt-in mtime.
    # Defends against the naive forge where an autonomous run creates both
    # files with the same fresh mtime: opt-in.mtime == snapshot-content,
    # which would otherwise pass the content-match check below. By
    # requiring `snapshot.fs_mtime - opt-in.mtime >= 30`, a same-NOW forge
    # has diff=0 and fails. Step 0's legitimate write produces
    # diff >= 30 (Step 0 only snapshots opt-in files already ≥30s old,
    # and the snapshot is written ~now relative to the opt-in mtime).
    # NOTE: `touch -t` backdating of the opt-in file by a sophisticated
    # attacker still bypasses this — defeating that requires file
    # birth-time (btime) checks which aren't portable across macOS/Linux.
    # The threat model already assumes attacker has same-user write access
    # in which case `gh pr merge --admin` is directly accessible too;
    # this is defense-in-depth, not a security boundary.
    SNAPSHOT_FILE_MTIME=$(stat -c %Y "$OPTIN_SNAPSHOT" 2>/dev/null || stat -f %m "$OPTIN_SNAPSHOT" 2>/dev/null || echo 0)
    case "$CURRENT_MTIME" in ''|*[!0-9]*) CURRENT_MTIME=0 ;; esac
    case "$SNAPSHOT_MTIME" in '') SNAPSHOT_MTIME=0 ;; esac
    case "$SNAPSHOT_FILE_MTIME" in ''|*[!0-9]*) SNAPSHOT_FILE_MTIME=0 ;; esac
    SNAPSHOT_VS_OPTIN_DIFF=$((SNAPSHOT_FILE_MTIME - CURRENT_MTIME))
    if [ "$SNAPSHOT_MTIME" -gt 0 ] \
       && [ "$CURRENT_MTIME" = "$SNAPSHOT_MTIME" ] \
       && [ "$SNAPSHOT_VS_OPTIN_DIFF" -ge 30 ]; then
      SOLO_ADMIN_OPT_IN=1
    fi
  fi
fi
HUMAN_ADMIN_COUNT=0
AUTHOR_IS_SOLE_ADMIN=0
if [ "$SOLO_ADMIN_OPT_IN" = "1" ]; then
  # Only spend the API call(s) when the opt-in file exists — no point
  # paginating collaborators on every pr-grind run.
  #
  # Count humans with PR-APPROVAL capability, not just admins. Anyone with
  # write/maintain/admin permission (i.e., `permissions.push == true`) can
  # submit an APPROVED review under default branch protection. Filtering
  # only `permission=admin` would let the solo-admin trigger fire even when
  # another human collaborator with maintain/write could approve, which
  # contradicts the "no other human can approve" promise. Query all
  # collaborators (no permission filter) and select those whose
  # `permissions.push` is true.
  #
  # Variable kept as HUMAN_ADMIN_COUNT for backward-compat with
  # approver-gap-detect.sh's input contract; the semantic is now "count of
  # humans with PR-approval capability". The script doc + log field
  # `human_admin_count` carries the same semantic.
  # `gh api --paginate` emits one JSON array per page (e.g.
  # `[page1]\n[page2]`), NOT a single merged array. Need to slurp all
  # pages and concatenate into one array; without this, downstream
  # `jq '.[]'` consumers below would only iterate the first page on
  # repos with >30 collaborators and the numeric guard would normalize
  # the resulting multi-line "0\n1" to 0.
  #
  # Capture to a tmpfile + check gh's exit code BEFORE jq. A naive
  # `gh ... | jq -s 'add // []'` pipeline without pipefail (which we
  # cannot enable globally inside a larger SKILL.md template) would let
  # jq succeed over PARTIAL pages when gh fails on a later page (rate
  # limit, transient network) — yielding an incomplete collaborator list
  # that could miss a write-capable human on an unfetched page and
  # wrongly satisfy HUMAN_ADMIN_COUNT=1. Fail-CLOSED on any gh failure.
  COLLABORATORS_TMP=$(mktemp -t pr-grind-collab.XXXXXXXX)
  if gh api "repos/$OWNER/$REPO/collaborators?affiliation=all" --paginate >"$COLLABORATORS_TMP" 2>/dev/null; then
    COLLABORATORS_JSON=$(jq -s 'add // []' "$COLLABORATORS_TMP" 2>/dev/null || echo "[]")
  else
    COLLABORATORS_JSON="[]"
  fi
  rm -f "$COLLABORATORS_TMP"
  # Parse count and first login in a single jq pass — avoids filtering
  # COLLABORATORS_JSON twice with identical predicates, eliminating a second
  # jq-failure window that could leave SOLE_APPROVER_LOGIN empty and
  # silently prevent auto-merge even when the structural check should pass.
  APPROVERS_RESULT=$(printf '%s' "$COLLABORATORS_JSON" \
    | jq -r '[.[]
        | select((.type // "User") == "User"
                 and ((.login // "") | endswith("[bot]") | not)
                 and ((.permissions.push // false) == true))
        | .login]
      | { count: length, first: (.[0] // "") }
      | "\(.count) \(.first)"' 2>/dev/null || echo "0 ")
  HUMAN_ADMIN_COUNT="${APPROVERS_RESULT%% *}"
  SOLE_APPROVER_LOGIN="${APPROVERS_RESULT#* }"
  case "$HUMAN_ADMIN_COUNT" in ''|*[!0-9]*) HUMAN_ADMIN_COUNT=0 ;; esac
  if [ "$HUMAN_ADMIN_COUNT" = "1" ] && [ -n "$AUTHOR" ]; then
    if [ "$SOLE_APPROVER_LOGIN" = "$AUTHOR" ]; then
      AUTHOR_IS_SOLE_ADMIN=1
    fi
  fi
fi

export BRANCH_RULES_JSON CLASSIC_PROTECTION_JSON PR_REVIEWS_JSON AUTHOR_PERM_JSON \
       AUDIT_WORKFLOW_PRESENT CI_AND_BOTS_CLEAN ADMIN_FLAG_PASSED \
       SOLO_ADMIN_OPT_IN HUMAN_ADMIN_COUNT AUTHOR_IS_SOLE_ADMIN

GAP_DECISION_JSON=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/approver-gap-detect.sh" 2>/dev/null \
  || echo '{"decision":"surface-decision","trigger":"none","reason":"approver-gap detector failed; require operator decision"}')
GAP_DECISION=$(printf '%s' "$GAP_DECISION_JSON" | jq -r '.decision' 2>/dev/null || echo surface-decision)
GAP_TRIGGER=$(printf '%s' "$GAP_DECISION_JSON" | jq -r '.trigger // "none"' 2>/dev/null || echo none)
```

**Decision tree** (based on `GAP_DECISION`):

- **`no-gap`** → fall through to the normal `gh pr merge` path below.
- **`surface-decision`** → BAIL with `RESULT_BAIL_CATEGORY=policy` and surface the operator-decision message (template below). Excluded from MAX_FIX/MAX_WAIT accounting. The `audit_workflow_present` field in the JSON controls whether `[admin]` appears as the first/default option.
- **`auto-admin-merge`** → log to `.claude/bypass-log.jsonl` and run `gh pr merge <PR> --squash --delete-branch --admin`. Two triggers can reach this decision: `trigger=flag` (operator passed `--admin-on-approver-gap` per-invocation) or `trigger=solo-admin-auto` (operator placed `.claude/pr-grind-auto-admin-solo.local` AND remains the sole human admin — see the "Solo-admin auto-detect" composer above). Both require the baseline gates: CI/bots clean (asserted by caller) AND author has admin/maintain AND `bypass-audit.yml` exists. Fail-CLOSED on any missing condition. The caller selects the bypass-log `event` value from `GAP_TRIGGER` so explicit vs. structural bypasses are distinguishable in forensics.

**Bypass-log format** (append-only JSONL; gitignored under `.claude/`):

```bash
# Same-call-scope contract: this block executes INSIDE the auto-admin-merge
# branch of the approver-gap detection bash call above, so PR / OWNER /
# REPO / BRANCH / AUTHOR / GAP_DECISION_JSON are all in scope from that
# parent block. Defense-in-depth re-derivations below cover the
# single-call-shared-shell case:
#   - PR / OWNER / REPO: re-template-substituted by the dispatcher (Claude)
#     so the values match the parent block's substitutions even if the
#     dispatcher chooses to split this into its own Bash tool call.
#   - BRANCH / AUTHOR: re-derived via `gh -R "$OWNER/$REPO"` (NOT bare
#     `gh pr view`, which resolves the repo from CWD — in a CWD-drift
#     scenario it could record a different repo's PR with the same number
#     while the audit log says this OWNER/REPO).
#   - REPO_ROOT: recomputed locally because the marker-write block above
#     runs as its own Bash tool call (see the EXTREMELY-IMPORTANT block
#     before the marker-write subsection) and its variables don't survive
#     into a subsequent call.
# Three fields live ONLY inside the script's emitted JSON (.author_perm,
# .required_approving_review_count, .human_approvals — see
# scripts/approver-gap-detect.sh "Output"); extract them from
# $GAP_DECISION_JSON before composing the log line. $GAP_DECISION_JSON
# itself is NOT re-derivable here; it must remain in shell scope from the
# parent approver-gap detection call. If the dispatcher splits this into
# a separate Bash call and $GAP_DECISION_JSON is empty, the authorization
# gate below aborts (see next paragraph) — the merge does NOT run.
#
# Fail-CLOSED on missing/malformed $GAP_DECISION_JSON: this block is the
# `auto-admin-merge` branch, and that branch is only legal if the detector
# emitted `decision=auto-admin-merge` AND `trigger in {flag,solo-admin-auto}`.
# Treating either as missing/unverifiable as a license to proceed would
# convert the authorization input into a fail-OPEN trust boundary —
# wrong even though the merge command runs next. Verify the detector
# decision is in scope and consistent before logging + merging.
PR=<PR_NUMBER>
OWNER=<owner>
REPO=<repo>
# Preserve any already-in-scope BRANCH / AUTHOR from the parent
# approver-gap detection call. Only re-derive (via `gh -R "$OWNER/$REPO"`
# to avoid CWD-based repo inference) if they're empty AND the gh call
# succeeds — a transient gh failure must NOT overwrite a known-good value
# with empty string, which would weaken the bypass-log audit trail.
if [ -z "${BRANCH:-}" ]; then
  GH_BRANCH=$(gh -R "$OWNER/$REPO" pr view "$PR" --json baseRefName -q .baseRefName 2>/dev/null)
  [ -n "$GH_BRANCH" ] && BRANCH="$GH_BRANCH"
fi
if [ -z "${AUTHOR:-}" ]; then
  GH_AUTHOR=$(gh -R "$OWNER/$REPO" pr view "$PR" --json author -q .author.login 2>/dev/null)
  [ -n "$GH_AUTHOR" ] && AUTHOR="$GH_AUTHOR"
fi
REPO_ROOT=$(git rev-parse --show-toplevel)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HEAD_SHA=$(git rev-parse HEAD | cut -c1-8)

# Fail-CLOSED authorization gate. $GAP_DECISION_JSON must be in scope from
# the parent approver-gap detection call AND contain a valid auto-admin-merge
# decision with a known trigger. Empty / malformed / wrong-decision / unknown-
# trigger inputs ABORT before the merge — the bypass-log entry and `gh pr
# merge --admin` only run on a verified authorization.
if [ -z "${GAP_DECISION_JSON:-}" ]; then
  echo "❌ approver-gap auto-admin: GAP_DECISION_JSON empty (split-call broke same-call-scope contract) — aborting before bypass-log + merge"; exit 1
fi
GAP_DECISION_FOR_MERGE=$(printf '%s' "$GAP_DECISION_JSON" | jq -r '.decision // "missing"' 2>/dev/null || echo "parse-error")
GAP_TRIGGER_FOR_MERGE=$(printf '%s' "$GAP_DECISION_JSON" | jq -r '.trigger // "missing"' 2>/dev/null || echo "parse-error")
if [ "$GAP_DECISION_FOR_MERGE" != "auto-admin-merge" ]; then
  echo "❌ approver-gap auto-admin: detector decision is '$GAP_DECISION_FOR_MERGE', not 'auto-admin-merge' — aborting before bypass-log + merge"; exit 1
fi
case "$GAP_TRIGGER_FOR_MERGE" in
  flag|solo-admin-auto) ;;
  *) echo "❌ approver-gap auto-admin: detector trigger is '$GAP_TRIGGER_FOR_MERGE', not 'flag' or 'solo-admin-auto' — aborting before bypass-log + merge"; exit 1 ;;
esac

# After the authorization gate, the remaining jq reads are pulling forensic
# metadata from a known-valid JSON object — defaults via `// X` are
# appropriate here (those fields may legitimately be missing if the detector
# is upgraded incrementally; the merge is already authorized).
AUTHOR_PERM=$(printf '%s' "$GAP_DECISION_JSON" | jq -r '.author_perm // "read"' 2>/dev/null || echo "read")
REQUIRED_APPROVALS=$(printf '%s' "$GAP_DECISION_JSON" | jq -r '.required_approving_review_count // 0' 2>/dev/null || echo 0)
case "$REQUIRED_APPROVALS" in ''|*[!0-9]*) REQUIRED_APPROVALS=0 ;; esac
HUMAN_APPROVALS=$(printf '%s' "$GAP_DECISION_JSON" | jq -r '.human_approvals // 0' 2>/dev/null || echo 0)
case "$HUMAN_APPROVALS" in ''|*[!0-9]*) HUMAN_APPROVALS=0 ;; esac
# Trigger-derived fields: forensics depends on knowing WHY the bypass fired.
# `event` distinguishes explicit-flag from structural sole-admin in audits;
# human_admin_count records the structural assumption at decision time so a
# later audit can detect if the repo's admin roster changed post-merge.
# LOG_TRIGGER is the already-validated value from the authorization gate.
LOG_TRIGGER="$GAP_TRIGGER_FOR_MERGE"
LOG_HUMAN_ADMIN_COUNT=$(printf '%s' "$GAP_DECISION_JSON" | jq -r '.human_admin_count // 0' 2>/dev/null || echo 0)
case "$LOG_HUMAN_ADMIN_COUNT" in ''|*[!0-9]*) LOG_HUMAN_ADMIN_COUNT=0 ;; esac
case "$LOG_TRIGGER" in
  solo-admin-auto) LOG_EVENT="pr-grind-admin-on-approver-gap-solo-admin-auto" ;;
  flag)            LOG_EVENT="pr-grind-admin-on-approver-gap" ;;
  *)               LOG_EVENT="pr-grind-admin-on-approver-gap" ;;
esac
# Validate $PR is numeric before passing to --argjson — defense in depth so a
# `gh pr view` failure upstream (returning empty string or "null") can't cause
# jq to abort the log composition with "Invalid numeric literal". The audit
# trail is load-bearing; silently dropping the entry defeats the
# audit_workflow_present eligibility gate.
case "$PR" in
  ''|*[!0-9]*)
    echo "❌ approver-gap admin escalation: invalid PR number '$PR' — aborting before bypass-log + merge"; exit 1 ;;
esac
mkdir -p "$REPO_ROOT/.claude"
jq -c -n \
  --arg ts "$TS" \
  --arg event "$LOG_EVENT" \
  --arg trigger "$LOG_TRIGGER" \
  --argjson pr "$PR" \
  --arg owner "$OWNER" \
  --arg repo "$REPO" \
  --arg branch "$BRANCH" \
  --arg author "$AUTHOR" \
  --arg author_perm "$AUTHOR_PERM" \
  --argjson required "$REQUIRED_APPROVALS" \
  --argjson approvals "$HUMAN_APPROVALS" \
  --argjson human_admin_count "$LOG_HUMAN_ADMIN_COUNT" \
  --arg head_sha "$HEAD_SHA" \
  '{ts:$ts, event:$event, trigger:$trigger, pr:$pr, owner:$owner, repo:$repo, branch:$branch, author:$author, author_perm:$author_perm, required_approving_review_count:$required, human_approvals:$approvals, human_admin_count:$human_admin_count, head_sha:$head_sha}' \
  >> "$REPO_ROOT/.claude/bypass-log.jsonl" || { echo "❌ failed to append bypass-log entry; aborting admin merge"; exit 1; }
gh pr merge "$PR" --squash --delete-branch --admin || true
# Verify via authoritative source — `gh pr merge --delete-branch` can
# exit non-zero on a post-merge local worktree-checkout conflict (e.g.,
# "main is already used by worktree at ...") even after the remote merge
# succeeded. Trust `gh pr view --json state` instead. See the
# default-merge block below for the full failure-mode walkthrough.
# Retry up to 3 times with 2s backoff. Two real failure modes the retry
# absorbs: (1) the worktree-checkout conflict above makes `gh pr merge`
# exit non-zero even though the remote merge succeeded — the next `gh pr
# view` may briefly still see state=OPEN; (2) transient post-merge
# replication lag in the GitHub API (queried via gh). The retry is idempotent (read-only poll).
MERGE_STATE=""
for attempt in 1 2 3; do
  MERGE_STATE=$(gh pr view "$PR" --json state -q .state 2>/dev/null || echo "")
  [ "$MERGE_STATE" = "MERGED" ] && break
  [ "$attempt" -lt 3 ] && sleep 2
done
if [ "$MERGE_STATE" != "MERGED" ]; then
  echo "❌ approver-gap admin merge: PR #$PR not merged after 3 attempts (state=$MERGE_STATE); bypass-log entry was written but merge did not land."
  exit 1
fi
```

**Operator-decision message template** (rendered to stdout on BAIL; `[admin]` is omitted when no audit workflow exists). Placeholders: `{REQUIRED_COUNT}` is the branch-protection rule's `required_approving_review_count` (from `$GAP_DECISION_JSON`); `<PR_NUMBER>` is the PR number — distinct values, distinct placeholders so the rendering layer doesn't conflate them:

```text
pr-grind: PR is functionally clean (CI green, bots ack HEAD, threads resolved)
but branch protection requires {REQUIRED_COUNT} human APPROVED review(s) the
author cannot self-provide. Project has bypass-audit.yml — note: the [admin]
command below runs outside pr-grind and writes NO entry to
.claude/bypass-log.jsonl. For a logged merge, re-invoke with
--admin-on-approver-gap instead (bypass-audit.yml audits direct pushes only;
it does not detect gh pr merge --admin regardless of path).

Options:
  [admin]        gh pr merge <PR_NUMBER> --squash --delete-branch --admin
                   # verify: gh pr view <PR_NUMBER> --json state -q .state
                   # (retry up to 3x with 2s backoff — the GitHub API (queried
                   #  via gh) can briefly return state=OPEN due to post-merge
                   #  replication lag, and `gh pr merge --delete-branch` can
                   #  exit non-zero on a worktree-checkout conflict even after
                   #  the remote merge succeeded; trust the API state, not the
                   #  merge exit code)
  [wait]         exit; wait for a human reviewer
  [add-reviewer] gh pr edit <PR_NUMBER> --add-reviewer <user>; exit
```

When `AUDIT_WORKFLOW_PRESENT=0`, omit `[admin]` from the first/default position and prepend a stronger warning that no audit trail exists:

```text
pr-grind: PR is functionally clean (CI green, bots ack HEAD, threads resolved)
but branch protection requires {REQUIRED_COUNT} human APPROVED review(s) the
author cannot self-provide. ⚠️  This repo has NO bypass-audit.yml — an
admin-merge here would leave NO audit trail. Strongly consider [add-reviewer]
or [wait].

Options:
  [wait]         exit; wait for a human reviewer
  [add-reviewer] gh pr edit <PR_NUMBER> --add-reviewer <user>; exit
  [admin]        gh pr merge <PR_NUMBER> --squash --delete-branch --admin
                   (no audit trail — proceed only with explicit operator authorization)
                   # verify: gh pr view <PR_NUMBER> --json state -q .state
                   # (retry up to 3x with 2s backoff — the GitHub API (queried
                   #  via gh) can briefly return state=OPEN due to post-merge
                   #  replication lag, and `gh pr merge --delete-branch` can
                   #  exit non-zero on a worktree-checkout conflict even after
                   #  the remote merge succeeded; trust the API state, not the
                   #  merge exit code)
```

<EXTREMELY-IMPORTANT>
**DO NOT use `gh pr merge` exit code as merge authority.** The retry block below MUST be run as-written; do NOT simplify it to `if gh pr merge ...; then ... else "Merge failed" fi` — that drift makes the dispatcher misread a SUCCESSFUL remote merge as a failure. The failure mode is post-merge local-cleanup: `gh pr merge --delete-branch` runs `git fetch && git checkout <base>` locally after the API merge, and on a multi-worktree setup where the base branch is already checked out elsewhere, that local step exits non-zero with `fatal: 'main' is already used by worktree at ...` AFTER the remote PR is already merged. Trusting the exit code makes pr-grind print "preserving worktree for inspection" while the PR is in fact merged on GitHub — a misleading state that leads operators to re-attempt the merge (failing with "PR already merged"), think the first attempt failed, and waste a session debugging a non-bug.

**Confirmed recurrences:** PR #98 (2026-05-13) — the original failure that motivated the retry block. PR #102 (2026-05-18) — recurred *despite* the comment-buried explanation because the prose was easy to skim past while writing dispatcher code. This headline callout is the current attempt to make the contract unmissable; do not soften it back into a comment.

**The contract:** `gh pr merge ... || true` (do not fail on non-zero exit) → `gh pr view --json state` with 3-attempt 2s-backoff retry as the authoritative source. Use the block below verbatim.
</EXTREMELY-IMPORTANT>

**Default: merge, then clean up the worktree (skip cleanup with `--no-worktree`). Run this as its own Bash tool call — DO NOT prefix it with the marker-write block above; see the `<EXTREMELY-IMPORTANT>` block immediately preceding "Write the pr-grind-clean marker" for why:**
```bash
# NO_WORKTREE template-substituted by the dispatcher at run time — the
# literal 0 or 1 from "Resolve flag-to-state translations" in START is
# written here before bash executes. Do NOT use `${NO_WORKTREE:-0}`:
# bash exports do not survive across Claude Bash tool calls, so the
# fallback always resolves to 0 and the cleanup branch always runs
# (wrong when Step 0's auto-fallback engaged or --no-worktree was passed).
NO_WORKTREE=<0|1 — see "Resolve flag-to-state translations" in START>
gh pr merge <PR_NUMBER> --squash --delete-branch || true
# Verify via authoritative source — `gh pr merge` exit code is unreliable
# when --delete-branch hits a post-merge worktree-checkout conflict (the
# remote merge has already SUCCEEDED, but gh tries to update the local
# main-branch checkout and fails when main is checked out in another
# worktree). The "main is already used by worktree at ..." error makes gh
# exit non-zero AFTER the remote PR is already merged. Trusting the exit
# code would make the dispatcher think the merge failed and either retry
# (no-op — PR is already merged) or bail with stale state. The merge
# state on GitHub is the authoritative source. Empirical: surfaced
# during PR #98's grind (2026-05-13).
# Retry up to 3 times with 2s backoff. Two real failure modes the retry
# absorbs: (1) the worktree-checkout conflict above makes `gh pr merge`
# exit non-zero even though the remote merge succeeded — the next `gh pr
# view` may briefly still see state=OPEN; (2) transient post-merge
# replication lag in the GitHub API (queried via gh). The retry is idempotent (read-only poll).
MERGE_STATE=""
for attempt in 1 2 3; do
  MERGE_STATE=$(gh pr view <PR_NUMBER> --json state -q .state 2>/dev/null || echo "")
  [ "$MERGE_STATE" = "MERGED" ] && break
  [ "$attempt" -lt 3 ] && sleep 2
done
if [ "$MERGE_STATE" != "MERGED" ]; then
  echo "❌ PR #<PR_NUMBER> not merged after 3 attempts (state=$MERGE_STATE); preserving worktree for inspection."
  exit 1
fi
# Only return to a separate worktree and remove the ephemeral one if Step 0
# actually created it. With --no-worktree we ran in-place — there is no
# separate worktree to leave or remove.
if [ "$NO_WORKTREE" != "1" ]; then
  cd <original-worktree-path>
  git worktree remove "../pr-grind-<PR_NUMBER>" --force 2>/dev/null || true
fi
```

**If `--no-merge`: write marker to the repo root of the worktree the user will merge from, clean up, report ready (also `--no-worktree`-aware):**
```bash
# NO_WORKTREE template-substituted same as Default-merge block above —
# `${NO_WORKTREE:-0}` would silently default to 0 across Bash tool calls
# and the wrong cleanup branch would fire.
NO_WORKTREE=<0|1 — see "Resolve flag-to-state translations" in START>
# When --no-worktree, the dispatcher already runs in the user's worktree, so
# the marker target is the same repo root we're in — no cross-worktree copy.
if [ "$NO_WORKTREE" = "1" ]; then
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
| `--max-fix N` | Maximum **fix-rounds** (dispatcher pushed a commit; `RESULT_COMMIT_SHA != "none"`) before bail. Reflects engineering iteration budget. | 5 |
| `--max-wait N` | Maximum **wait-rounds** (worker did not push; `RESULT_COMMIT_SHA == "none"` — polling for slow bots to ack HEAD) before bail. Reflects bot-latency tolerance. | 8 |
| `--max N` | **Deprecated alias** that sets both `--max-fix` and `--max-wait` to N. Emits a `⚠️  --max is deprecated; use --max-fix and --max-wait` warning. Cannot be combined with `--max-fix` or `--max-wait` — combining bails with `conflicting flags`. | unset |
| `--opus` | Run rounds inline in parent Opus context (no Sonnet dispatch) | Off (dispatches Sonnet subagent) |
| `--interactive` | Pause for human confirmation each round (forces inline; subagent can't pause) | Off (autonomous) |
| `--no-worktree` | Skip worktree creation, work in current directory. Same behavior auto-engages without the flag if `git worktree add` reports the branch is already checked out elsewhere — see Step 0 fallback. | Off (creates worktree) |
| `--ci-only` | Only fix CI failures, ignore comments. Forces inline mode (Step 2 branching not yet wired into the subagent). | Off |
| `--no-merge` | Skip merge after grinding clean — just declare "Ready for merge" | Off (merges by default) |
| `--comments-only` | Only address comments, ignore CI. Forces inline mode (same reason as `--ci-only`). | Off |
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
