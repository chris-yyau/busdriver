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

This skill is a **thin dispatcher**. The actual round work runs in a fresh `pr-grinder` subagent (opus, like every Claude route — ADR 0046), dispatched once per round. The split survives the model unification because neither of its reasons was price:

- Flattens conversation context — each round starts with O(1) tokens instead of O(N) accumulation across rounds
- Separates author from reviewer: the dispatcher keeps triage of subagent results, bail handling, merge decisions, and the skip-file protocol out of the worker's context

**This file is dispatcher-only. The worker does not read it.** `agents/pr-grinder.md`
is self-contained for Steps 1–6.5 — the 3-phase check verification, the four feedback
sources, the triage table, the ack ledger, and the bail table are all inline there.
This file holds no worker step protocol at all (no Step 1, no Phase 0/1/2 block, no
ack-ledger function). A worker contract that ordered a wholesale Read of this file was
paying ~25k tokens per round for dispatcher control flow it never executes; that order
was removed. Do not restore it — if the worker needs the dispatcher's side of a contract
it emits into, it reads the *named section*.

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
  ├── Resolve PR # (arg, current branch, or ask user), and record HOW it was named (#890):
  │     - all-digit argument, or auto-detect → PR_NUMBER=<N>; no invocation URL.
  │     - any other argument is a URL: one containing `'` → BAIL "unrecognised PR
  │       argument"; otherwise PR_NUMBER = the digits of the FIRST `/pull/<digits>`
  │       segment (none → BAIL before any worktree) and PR_INVOCATION_URL = the
  │       argument VERBATIM (never normalized or dropped — pr-head-identity.sh is
  │       the only shape validator). Step 0 picks its identity-call form from this.
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
  ├── Derive durable grind provenance — BEFORE the Agent dispatch, EVERY round:
  │     # Rail A / ADR 0036. This is what makes #620's proportionality gate fire
  │     # across invocations instead of only within one.
  │     #
  │     # It must sit HERE, pre-dispatch. `scripts/dispatcher-commit-block.sh` is
  │     # a subprocess invoked AFTER the worker returns and only on fix-rounds,
  │     # so a call placed there could never populate a wait-round or the round-1
  │     # re-invocation this exists to fix — which is #620's defect repeating.
  │     #
  │     # Substitute the literals remembered from Step 0 (<WORKTREE_DIR>,
  │     # <BASE_SHA>); shell state does not survive across Bash tool calls.
  │     #
  │     # `BASH_ENV= ENV= command bash` closes two specific cheap vectors that
  │     # the helper cannot close from inside itself: an inherited `bash`
  │     # FUNCTION (`command` bypasses function lookup) and a startup file
  │     # sourced into the helper's own shell before its first line runs.
  │     #
  │     # It is NOT an environment-sanitization boundary, and must not be read
  │     # as one. PATH is still whatever the caller had, inherited BASH_FUNC_*
  │     # entries still reach the child, and a PATH shim can forge
  │     # `GRIND_SHAS=none` / `STATUS=ok` outright.
  │     #
  │     # Do NOT reach for `env -i` here, and do NOT cite ADR 0016: that
  │     # wrapper protects auto-firing GATES and explicitly does not transfer
  │     # to dispatcher prose, which runs in the operator session's ambient
  │     # environment. **ADR 0026 settled this as an accepted residual** for
  │     # every credentialed call on this path (issue #475, closed as
  │     # documented, deliberately not wrapped) — a plugin cannot sanitize the
  │     # session it runs inside, and a dispatcher-wide wrapper would be false
  │     # assurance. Rail A inherits that bound rather than reopening it; the
  │     # two prefixes above are cheap defense-in-depth within it, nothing more.
  │     HEAD_SHA=$(git -C <WORKTREE_DIR> rev-parse HEAD) \
  │       || { echo "GRIND_PROVENANCE_FAILED rev-parse"; exit 1; }
  │     BASH_ENV= ENV= command bash "${CLAUDE_PLUGIN_ROOT}/scripts/grind-pr-commits.sh" --context \
  │       -C <WORKTREE_DIR> <PR_NUMBER> <BASE_SHA> "$HEAD_SHA" \
  │       || { echo "GRIND_PROVENANCE_FAILED scan"; exit 1; }
  │     #
  │     # rc 0  → stdout is exactly THREE lines — `GRIND_SHAS=…`,
  │     #         `GRIND_SHAS_STATUS=ok` and `GRIND_HEAD_SHA=…`. Copy ALL THREE
  │     #         verbatim into the context block below. Do NOT re-resolve the
  │     #         head in a later block: shell state does not cross a Bash-tool
  │     #         boundary, and a re-resolved head would pair THIS set with a
  │     #         NEWER commit, which the consumer accepts — recreating the very
  │     #         bypass the binding closes. The scanner emits it so all three
  │     #         come from one scan.
  │     #         The certified set is a
  │     #         SNAPSHOT: pr-grind supports concurrent runs, so another
  │     #         invocation can advance the shared worktree between this scan
  │     #         and the worker's blame, and its new commit would be in neither
  │     #         GRIND_SHAS nor this invocation's PRIOR_ATTEMPTS. Binding the
  │     #         set to the HEAD it was derived at turns that into a visible
  │     #         BAIL instead of a silently inert gate. All THREE fields travel
  │     #         together or none do.
  │     # rc ≠ 0 → BAIL `env` BEFORE dispatching. The worker is never launched on
  │     #         an unverifiable set. Do NOT substitute
  │     #         `GRIND_SHAS_STATUS=unavailable` and dispatch anyway — that
  │     #         value exists only to make the worker-side contract explicit.
  │     #
  │     # Use `--context`, not a bare call: it is what makes "an empty set renders
  │     # `none`" executable rather than a rule in the caller's head. `helper |
  │     # wc -l` returns 1 on empty output, and a pipeline would mask the
  │     # helper's exit 3 as rc 0 — fail-open on the exact property Rail A rests
  │     # on. Never pipe this call; never count its lines yourself.
  │     #
  │     # Re-derived every round, not cached per invocation: one rev-list pair is
  │     # cheap, and re-deriving removes any need to reason about whether this
  │     # invocation's own pushes are already reflected. They are, by construction.
  │
  ├── Write-block preflight (every round, BEFORE dispatch) — #625:
  │     # Optimization only; fail-OPEN. The PreToolUse gates stay fail-CLOSED;
  │     # the worker's `env` bail stays the mid-round backstop.
  │     bash "${CLAUDE_PLUGIN_ROOT}/scripts/pr-grind-write-block-preflight.sh" \
  │       -C <WORKTREE_DIR>
  │     # exit 0 → clear (or detector unreadable/unresolvable) → dispatch
  │     # exit 1 → definite block (pending design-review markers, or freeze-scope
  │     #         that excludes this worktree). Surface the script's stdout to the
  │     #         operator (it names the blocking doc / freeze path and the
  │     #         release path, including the "do not drain unless abandoned"
  │     #         caveat). BAIL `env` WITHOUT dispatching — do not spend a round.
  │     # exit 2 → usage error → fail OPEN (dispatch); do not invent a block
  │     # Never create/disarm the operator-only design-review skip file; never
  │     # invoke design-clear.sh from this path. Read-only observation of an
  │     # already-active lease (mtime + slots) is allowed; never claim a slot.
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
  │       Fix-round delegation: run the "Dispatcher invocation (envelope wrapper)" bash block below
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
  │        (5 bots: `cubic-dev-ai`, `coderabbitai`,
  │        `greptile-apps`, `codescene-delta-analysis`,
  │        `chatgpt-codex-connector`).
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
  ├── Codex first-engagement nudge on the CLEAN path (bounded-N per HEAD, ADR 0005 #673) — issue #467.
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
  │     # Safe against the COMPLETION re-nudge: codex-retrigger.sh's per-(PR,HEAD) attempt
  │     # markers plus its cooldown bound the POST, so the two call sites cannot compound —
  │     # at most PR_GRIND_CODEX_RETRIGGER_MAX (default 3) `@codex review` posts per HEAD,
  │     # spaced by PR_GRIND_CODEX_RETRIGGER_COOLDOWN (default 180s). Pre-#673 this was a
  │     # hard one-shot; that made a single dropped nudge terminal for the PR (see ADR 0005).
  │     # COST (stated honestly, per the #467 review): on a clean `none` round this block runs
  │     # the wrapper's detection (`gh repo view` + the Codex-active GraphQL probe) ONCE, and
  │     # COMPLETION later re-derives active-ness independently — so a Codex-active / force-on
  │     # repo pays ONE extra codex-active probe per clean-none merge vs. pre-#467. This is a
  │     # deliberate, bounded tradeoff: the attempt markers + cooldown bound the POST (at most
  │     # PR_GRIND_CODEX_RETRIGGER_MAX per HEAD, never unbounded), but NOT the detection, because
  │     # COMPLETION needs genuine active-ness for its
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
  │     # Codex sole-stale-blocker auto-re-trigger (bounded-N per HEAD, #673) — ADR 0005.
  │     # On this WAIT-round (RESULT_COMMIT_SHA == "none", so HEAD is unchanged)
  │     # where Codex is the SOLE stale ack — RESULT_CODEX_ACK == "stale" AND no
  │     # registered bot in RESULT_REVIEWER_ACKS is "stale" (they all acked HEAD) —
  │     # Codex will never self-ack the unchanged HEAD (it posts COMMENTED reviews /
  │     # 0 reactions; its thread resolutions predate the push, Tier-A.2 fail-closed),
  │     # so the next wait-rounds would just burn --max-wait and BAIL. Post `@codex
  │     # review` so Codex re-reviews HEAD before the next round (→ fresh
  │     # 👍/Tier-F ack → converge, or new findings → worker triages). The helper is
  │     # deduped by attempt markers + cooldown (at most PR_GRIND_CODEX_RETRIGGER_MAX
  │     # posts per (PR,HEAD)) so this is safe even though the
  │     # worker's Step 6.5 mirrors the same call. Opt out: PR_GRIND_CODEX_RETRIGGER=0;
  │     # phrase override (forks): PR_GRIND_CODEX_RETRIGGER_PHRASE. `|| true` keeps a
  │     # failed post from ever staling the gate. Distinct from the COMPLETION
  │     # first-engagement grace, which only RE-POLLS a `none` Codex (never a `stale`).
  │     # #679 — post via the ordinary helper (skip-when-hot; no sleep — preserves
  │     # worker→dispatcher mirror dedupe). Then --await-cooldown with the INTEGER
  │     # remaining wait rounds AFTER this round (`MAX_WAIT - wait_round`, template-
  │     # substituted — these are dispatcher conversation counters, NOT shell
  │     # variables; `$(( MAX_WAIT - wait_round ))` in a fresh Bash would read as 0
  │     # and skip pacing). If the marker is still hot and further rounds remain,
  │     # SLEEP out the cooldown in the dispatcher loop so the next wait-round can
  │     # spend attempt 2..N.
  │     # Bash tool timeout MUST be >= COOLDOWN+60s (default COOLDOWN=180 → use
  │     # timeout ≥ 240000ms on this invocation). A killed await leaves attempts
  │     # 2..N unreachable — the #679 defect. Same class as COMPLETION's 480s Codex
  │     # grace block: the long wait lives in a dispatcher-owned Bash call with an
  │     # explicit raised timeout, never in the worker.
  │     If RESULT_COMMIT_SHA == "none" AND RESULT_CODEX_ACK == "stale"
  │        AND RESULT_REVIEWER_ACKS has no `stale` entry, run this block. Per the
  │        "CWD Reset Across Bash Calls" contract it MUST open with `cd "$WORKTREE_DIR"`
  │        (template-substituted to the literal Step 0 path — do NOT rely on shell-var
  │        persistence or on the inherited CWD; `$PR_NUMBER` is likewise the Step 0
  │        literal, and HEAD is read inside the correct worktree after the cd). The
  │        cd runs in a subshell and ABORTS on failure (`|| exit 0`) so a bad
  │        WORKTREE_DIR never lets git/gh run in the wrong repo:
  │          ( cd "$WORKTREE_DIR" || exit 0
  │            _head="$(git rev-parse HEAD)"
  │            bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-retrigger.sh" "$PR_NUMBER" "$_head" || true
  │            bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-retrigger.sh" --await-cooldown "$PR_NUMBER" "$_head" "<MAX_WAIT - wait_round>" || true )
  │
  └── Update state:
        # PRIOR_COMMIT_SHA is the last FIX-ROUND's reported SHA and is RETAINED
        # on wait-rounds: RESULT_COMMIT_SHA is "none" there, and overwriting
        # would reset the #668 double-count guard — a later clean round sitting
        # on the same Grind-PR commit would pass PRIOR_COMMIT_SHA=none and
        # count the already-counted fix again.
        PRIOR_COMMIT_SHA    = RESULT_COMMIT_SHA if RESULT_COMMIT_SHA != "none"; retained otherwise
        PRIOR_REVIEWER_ACKS = RESULT_REVIEWER_ACKS
        PRIOR_CODEX_ACK     = RESULT_CODEX_ACK   # on fix/wait-rounds: overwrite with result_codex_ack from commit-block envelope (post-push); on clean path: use worker-emitted value. Backward-compat: if result_codex_ack absent from envelope (legacy commit-block), retain worker RESULT_CODEX_ACK unchanged — do NOT default to "none" (that would lose a stale signal from the worker).
        PRIOR_ATTEMPTS     += "Round N (fix=<fix_round>/<MAX_FIX>, wait=<wait_round>/<MAX_WAIT>): commit=<RESULT_COMMIT_SHA>; fixes=<RESULT_FIXES>; failures=<RESULT_REMAINING>; acks=<RESULT_REVIEWER_ACKS>; scope-skipped=<scope_skipped_this_round>; spawned=<issues_spawned_this_round>"
        # commit= is the per-round provenance record: the SHA this round pushed,
        # or the literal `none` on a wait-round. Without it the worker has only
        # free-form `fixes=` prose plus PRIOR_COMMIT_SHA (the LATEST push), so it
        # cannot map a finding back to the round that wrote the line — the Step 3
        # proportionality gate's authorship discriminator then falls through to
        # its uncertainty branch every time and can never fire (Codex + CodeRabbit,
        # PR #620). Emit the SHA verbatim; the worker attributes a finding by
        # blaming its LINE (`git blame -L`) and testing the resulting SHA against
        # these values — not by the summary text, and not by which files a commit
        # touched (a grind commit and an author finding can share a file).
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
                             **Pass the FULL 40-char sha** as `HEAD_SHA` (the same value as
                             `REVIEWED_HEAD`). It is a JOIN KEY, not forensics: it is written
                             verbatim into the event and COMPLETION's revalidator matches against
                             it before it will honor any release, and COMPLETION now passes its own
                             full sha — so full-on-both-sides is an exact 40-char match. The 8-char
                             short form still joins (the revalidator compares over the shorter of
                             the two lengths, with an 8-char floor below which nothing joins at
                             all), but it caps that comparison at a prefix, so prefer the full one.
                             #682: before that fix the comparison was strict equality against
                             COMPLETION's `git rev-parse HEAD | cut -c1-8`, so a full-SHA caller
                             here made the whole release path silently unreachable. Then:
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
                             MUST stay exactly `<PR_NUMBER> <REVIEWED_HEAD>` regardless — it does NOT carry
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
  │   TWO whitespace-separated fields — `<PR_NUMBER> <REVIEWED_HEAD>` (#505). `pre-merge-gate.sh`
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
      together with, VERBATIM, the ENVELOPE_FILE=, RECOVERY_GIT_COMMON_DIR=,
      RECOVERY_CLONE= and RECOVERY_LIB_ROOT= lines that call printed on stderr
      (#890: the operator's only route to "Push bail recovery (manual only)")
```

### Dispatcher invocation (envelope wrapper)

The fix-round dispatcher call. Every line runs in ONE Bash tool call. The wrapper
persists the dispatcher's raw stdout byte for byte to a fresh 0600 file in the git
common directory (shared by every worktree, so it survives the ephemeral worktree's
removal on bail), relays those bytes to stdout unchanged — "parse the last stdout
line" above is unaffected — and prints the recovery coordinates on **stderr**, so
they can never become the last stdout line.

- `PRIOR_COMMIT_SHA` (#668): the dispatcher's remembered LAST FIX-ROUND SHA —
  conversation state, so template-substitute the literal (shell vars do not survive
  Bash tool calls; `"${PRIOR_COMMIT_SHA:-none}"` would always expand to none and
  defeat the double-count guard). RETAINED across wait-rounds (a wait-round's
  `RESULT_COMMIT_SHA=none` must not reset it — see "Update state" above) and `none`
  only until the first fix-round reports a SHA.
- `PR_HEAD_HOST` / `PR_HEAD_OWNER` / `PR_HEAD_NAME` (#890): the literal values from
  Step 0's `pr-head-identity.sh` output. Keep the single quotes — an unsubstituted
  placeholder then reaches the dispatcher as text and fails its validation loudly
  instead of parsing as a shell redirection.
- `PR_BRANCH` (#890 review): the `headRefName` Step 0 resolved, verbatim, as the
  single line between the `BD890 PR BRANCH END` heredoc markers (the space keeps any
  valid branch name from ending the heredoc early). The dispatcher pins
  `full_ref` from HEAD, so the wrapper first requires HEAD to still be that branch —
  a worker that switched branches mid-round bails `env` before anything is committed
  or pushed. The quoted heredoc keeps the name out of shell parsing; an unsubstituted
  placeholder never matches, so it bails too.

```bash
# bd890-envelope-wrapper:begin
_bd890_env_file=""
if _bd890_gcd=$(git -C "$WORKTREE_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
   && case $_bd890_gcd in /*) true ;; *) false ;; esac \
   && [ -d "$_bd890_gcd" ] \
   && printf '%s' "$PR_NUMBER" | grep -Eq '^[1-9][0-9]*$'; then
  _bd890_env_file=$(umask 077; mktemp "$_bd890_gcd/pr-grind-bail-${PR_NUMBER}.XXXXXX") || _bd890_env_file=""
fi
if [ -z "$_bd890_env_file" ]; then
  printf '%s\n' '{"bail_category":"env","bail_reason":"pr-grind: cannot create durable envelope file in the git common dir; dispatcher not run"}'
  exit 1
fi
printf 'ENVELOPE_FILE=%s\n' "$_bd890_env_file" >&2
# Recovery coordinates (stderr, bash %q-quoted so they paste as inert words):
printf 'RECOVERY_GIT_COMMON_DIR=%q\n' "$_bd890_gcd" >&2
printf 'RECOVERY_CLONE=%q\n' "$(dirname -- "$_bd890_gcd")" >&2
_bd890_root=${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}   # the dispatcher's own plugin-root expression
case $_bd890_root in
  /*) printf 'RECOVERY_LIB_ROOT=%q\n' "$_bd890_root/scripts/lib" >&2 ;;
  *)  printf 'RECOVERY_LIB_ROOT=\n' >&2 ;;
esac
IFS= read -r _bd890_branch <<'BD890 PR BRANCH END' || _bd890_branch=""
<PR_BRANCH — the headRefName Step 0 resolved, verbatim>
BD890 PR BRANCH END
if [ "$(git -C "$WORKTREE_DIR" symbolic-ref -q HEAD)" != "refs/heads/$_bd890_branch" ]; then
  printf '%s\n' '{"bail_category":"env","bail_reason":"pr-grind: WORKTREE_DIR is not on the PR head branch Step 0 resolved; dispatcher not run, nothing committed or pushed"}' \
    | tee "$_bd890_env_file"
  exit 1
fi
_bd890_rc=0
BUSDRIVER_PLUGIN_ROOT="$_bd890_root" \
WORKTREE_DIR="$WORKTREE_DIR" \
CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
PR_NUMBER="$PR_NUMBER" \
RESULT_STATUS="$RESULT_STATUS" \
RESULT_FIXES="$RESULT_FIXES" \
RESULT_REVIEWER_ACKS="${RESULT_REVIEWER_ACKS:-}" \
RESULT_ACK_TIERS="${RESULT_ACK_TIERS:-}" \
NO_WORKTREE="${NO_WORKTREE:-0}" \
PRE_DISPATCH_BASELINE="${PRE_DISPATCH_BASELINE:-[]}" \
BUSDRIVER_ALLOW_NO_COMMITLINT="${BUSDRIVER_ALLOW_NO_COMMITLINT:-0}" \
PRIOR_COMMIT_SHA=<PRIOR_COMMIT_SHA — last fix-round SHA, literal, retained across wait-rounds; "none" until first fix-round> \
PR_HEAD_HOST='<PR_HEAD_HOST — literal from pr-head-identity.sh stdout>' \
PR_HEAD_OWNER='<PR_HEAD_OWNER — literal from pr-head-identity.sh stdout>' \
PR_HEAD_NAME='<PR_HEAD_NAME — literal from pr-head-identity.sh stdout>' \
bash "$_bd890_root/scripts/dispatcher-commit-block.sh" >"$_bd890_env_file" || _bd890_rc=$?
if ! cat "$_bd890_env_file"; then
  printf '%s\n' '{"bail_category":"env","bail_reason":"pr-grind: envelope file unreadable after dispatch; see ENVELOPE_FILE"}'
  [ "$_bd890_rc" -ne 0 ] || _bd890_rc=1
fi
exit "$_bd890_rc"
# bd890-envelope-wrapper:end
```

The file is never deleted automatically (one small untracked 0600 file per
dispatch, invisible to `git status`, never pushed, read by no gate); remove it after
recovery. If the common directory cannot be resolved or `mktemp` fails, the
dispatcher never runs — no commit, no push — and the block's last stdout line is an
`env` bail.

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
#
# ONE contained query answers every Step 0 PR read (#890): base, head, fork flag
# and the PR's home repository. Two separate `gh` calls could be answered for
# different repositories. GH_HOST/GH_REPO are pinned only inside this subshell
# (same containment as the Codex nudge), so Step 0 is github.com-only: a PR on
# another host fails here and BAILs before any worktree exists.
BASE_BRANCH_ERR=$(mktemp)
PR_META=$( export GH_HOST=github.com; unset GH_REPO; gh pr view <PR_NUMBER> --json baseRefName,headRefName,headRefOid,isCrossRepository,url,headRepositoryOwner,headRepository 2>"$BASE_BRANCH_ERR" ) || PR_META=""
BASE_BRANCH=$(printf '%s' "$PR_META" | jq -r '.baseRefName // empty' 2>/dev/null || true)
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

# Same PR_META as the base read above — no second gh call.
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

# PR home repository (#890). The dispatcher pushes only to an origin whose
# effective push URL IS this repository, so the tuple must come from GitHub's PR
# object — never from origin config, which the checkout controls. The helper is
# the only parser (no inline jq of identity fields) and fails closed. Claude
# substitutes ONE of two literal forms, chosen by START's "Resolve PR #" record —
# never by a shell test, and never by expanding a shell variable:
#   number-only (`/pr-grind <N>` or auto-detect): the line below as written
#   URL invocation: replace it with
#     PR_HEAD_IDENTITY=$(printf '%s' "$PR_META" | bash "${CLAUDE_PLUGIN_ROOT}/scripts/pr-head-identity.sh" --pr-number <PR_NUMBER> --invocation-url '<PR_INVOCATION_URL>') || PR_HEAD_IDENTITY=""
PR_HEAD_IDENTITY=$(printf '%s' "$PR_META" | bash "${CLAUDE_PLUGIN_ROOT}/scripts/pr-head-identity.sh" --pr-number <PR_NUMBER>) || PR_HEAD_IDENTITY=""
if [ -z "$PR_HEAD_IDENTITY" ]; then
  echo "❌ could not establish PR <PR_NUMBER>'s home repository from GitHub (see pr-head-identity above) — not proceeding."
  exit 1
fi
# Relay the three lines (same stdout contract as WORKTREE_DIR): the fix-round
# dispatcher invocation template-substitutes them as literals.
printf '%s\n' "$PR_HEAD_IDENTITY"

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

# --- Durable grind provenance: resolve the base floor ONCE (Rail A / ADR 0036) ---
# Deliberately HERE, after the resolver produced WORKTREE_DIR and after the `cd`
# above — not up with BASE_BRANCH resolution ~70 lines earlier, where
# WORKTREE_DIR does not exist yet and a `git -C ""` would be fatal on every
# single invocation.
#
# Why not `gh pr view --json baseRefOid`: it does not materialize the object
# locally (the only other fetch, above, fetches the PR head only), so
# `git rev-list <missing-sha>..HEAD` fails rc 128 and hard-BAILs every grind.
# It is also frozen at PR creation, not the live base tip.
# Why not `origin/<base>`: commonly stale in this repo specifically —
# semantic-release pushes a release commit to main after every merge.
#
# The `+` force refspec is load-bearing: fast-forward enforcement applies to
# custom namespaces too, so without it a base retarget or force-push would
# reject the fetch, leave the OLD value in place, and turn a scratch pointer
# into a permanent BAIL with no self-healing path. Forcing is safe because the
# ref names no work and protects no history: it is read once, immediately, and
# deleted in this same block.
#
# The `-$$` suffix is what makes it race-free — NOT the deletion. Linked
# worktrees share the common dir's refs and pr-grind explicitly contemplates
# concurrent runs, so PR-scoping alone still lets two grinds on the SAME PR
# interleave: one deletes the ref between the other's fetch and its merge-base,
# causing a spurious provenance-unavailable bail. A per-invocation name removes
# the shared object outright. The deletion is cleanup, and living in this same
# block is why there is no COMPLETION/BAIL cleanup row to forget.
git fetch --no-tags -q origin \
  "+refs/heads/${BASE_BRANCH}:refs/bd-grind/<PR_NUMBER>/base-$$" || {
  echo "❌ Step 0 could not fetch base branch '$BASE_BRANCH' — grind provenance unavailable."
  exit 1
}
# The floor is the MERGE BASE, not the fetched tip. The live tip is not an
# ancestor of the PR head the moment the base branch advances after the branch
# diverged — the routine `mergeStateStatus=BEHIND` case here — and
# grind-pr-commits.sh refuses a non-ancestor range, so using the tip directly
# would BAIL before every dispatch on ordinary behind-but-valid PRs.
#
# The merge base is an ancestor of HEAD by construction, and `merge-base..HEAD`
# is exactly this branch's own commits: it still excludes the trunk squash
# commits whose concatenated bodies carry Grind-PR: lines, which is the whole
# point of scoping the range.
BASE_SHA=$(git merge-base "refs/bd-grind/<PR_NUMBER>/base-$$" HEAD) || {
  # Delete on the FAILURE path too. Cleaning up only on success means every
  # failed invocation leaves a hidden ref pinning objects indefinitely — and the
  # comment above promises same-block cleanup, so this branch has to honour it.
  git update-ref -d "refs/bd-grind/<PR_NUMBER>/base-$$" \
    || echo "⚠️  also could not delete scratch ref refs/bd-grind/<PR_NUMBER>/base-$$ — remove it manually"
  echo "❌ Step 0 could not find a merge base between '$BASE_BRANCH' and the PR head"
  echo "   (unrelated histories?) — grind provenance unavailable."
  exit 1
}
# Scratch pointer, already consumed. A failure to delete does not invalidate
# BASE_SHA, so it must not abort the grind — but it is not swallowed either:
# a silent `|| true` here is how leaked refs go unnoticed.
git update-ref -d "refs/bd-grind/<PR_NUMBER>/base-$$" \
  || echo "⚠️  could not delete scratch ref refs/bd-grind/<PR_NUMBER>/base-$$ — remove it manually"
# Cross-block record. Shell state does NOT survive across Claude Bash tool calls,
# so Claude MUST remember this literal 40-hex value and template-substitute it
# into every downstream block, exactly as it already does for WORKTREE_DIR and
# NO_WORKTREE (see the substitution convention above). Do NOT write
# `$BASE_SHA` in a later block — it resolves to empty in a fresh shell.
echo "BASE_SHA=$BASE_SHA"

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

**Write-block preflight before every worker dispatch (#625).** A sibling worktree (or this one) can arm a design-review marker or freeze mid-grind; Step 0 does not catch that. Before each `Agent(subagent_type="pr-grinder", …)` call, run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pr-grind-write-block-preflight.sh" -C "$WORKTREE_DIR"
```

- **exit 0** — clear, or detector state absent/unreadable/unresolvable (**fail OPEN**). Dispatch.
- **exit 1** — definite write block. Print the script's stdout (blocking doc + `design-clear.sh` release path, or freeze file + `rm .claude/freeze-scope.local`). BAIL `env` without launching the worker. Do not create the operator-only design-review skip file; do not drain a live sibling marker unless abandoned.
- **exit 2** — malformed CLI usage only (missing/empty `-C` or unknown arguments). Treat as **fail OPEN**: dispatch. A missing, non-directory, or unresolvable `-C` target returns **exit 0** and also fails open — never invent a block from a malformed or unusable probe target.
- This check is read-only: it may observe an already-active operator skip lease (mtime + remaining slots) so a definite-block decision stays accurate, but it must not claim/consume a lease slot. The worker's PreToolUse → `env` bail path in `agents/pr-grinder.md` is unchanged.

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
    GRIND_SHAS=<full-sha,full-sha,... or "none">        (verbatim from the pre-dispatch producer)
    GRIND_SHAS_STATUS=ok                                (verbatim; emitted together with GRIND_SHAS, always)
    GRIND_HEAD_SHA=<full OID>                           (verbatim; the HEAD the set was derived at)
    PRIOR_REVIEWER_ACKS=<login=value,login=value,...> (round 1: every registered bot = none)
    PRIOR_ATTEMPTS:
      - Round 1 (fix=<fix_round>/<MAX_FIX>, wait=<wait_round>/<MAX_WAIT>): commit=<sha or "none">; fixes=<summary>; failures=<failed-check-names or "none">; acks=<login=value,...>
      - Round 2 (fix=<fix_round>/<MAX_FIX>, wait=<wait_round>/<MAX_WAIT>): commit=<sha or "none">; fixes=<summary>; failures=<failed-check-names or "none">; acks=<login=value,...>
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
RESULT_CODEX_ACK: <short-sha | stale | none>          (Codex's ack, gated like a registered bot but tracked SEPARATELY from RESULT_REVIEWER_ACKS because none of its three ack tiers are the SHA-keyed structured acks the other bots use. `stale` blocks `clean` AND counts as a legitimate wait-round in the no-progress invariant (Invariant 1 — a Codex-only wait-round must not be misread as no-progress); `<short-sha>` = acked HEAD via ANY of: a 👍 reaction newer than the last push (Tier F, timestamp-keyed — the freshness check is specific to this tier), a clean-verdict issue comment naming HEAD (Tier G, #690, SHA-keyed — no freshness window, the SHA equality IS the proof), or a resolved-and-current-head inline thread (Tier A, resolution-state-keyed). Codex findings (unresolved/outdated threads, COMMENTED /reviews) resolve to `stale`, never a SHA; `none` = not on this PR, non-gating. Additive/backward-compatible: MISSING TAG (old-contract worker) → treat as empty (`!= stale`), so Invariant 1 falls back to its registered-bot-only behavior. Do NOT bail "subagent output unparseable" on a missing RESULT_CODEX_ACK — additive, not version-pinned.)
RESULT_BOT_LEDGER: <login=n_act/n_total:disp,...>     (always present; entries shape: `<login>=<n_actionable>/<n_total>:<disposition>`; early-bail paths emit the all-`0/0:none` default; gates Invariant 3 — see Dispatcher Loop. n_actionable and n_total are different units — findings (decided per-finding) vs artifacts (review/comment entries examined); a single artifact can contain multiple findings, so n_actionable > n_total (e.g., `<bot>=2/1:fixed both`) is legitimate, not a typo. Invariant 3 only requires n_total >= 1 for HEAD-acked bots; it does NOT enforce n_actionable <= n_total. See `agents/pr-grinder.md` Step 3 worked examples. Disposition prose MUST NOT contain commas; entries are split on `,` and a comma inside a disposition would corrupt the parse. Disposition MAY carry `+`-joined `scope-skipped:<reason>:<count>` segments — Invariant 4 sums those counts across all bots/rounds against the ≤5 cumulative cap)
RESULT_ISSUES_SPAWNED: <issue,issue,... or "none">    (always present in the new contract; comma-separated GitHub issue numbers spawned this round via the out-of-scope-acknowledged workflow; gates Invariant 4 — cumulative count across rounds caps at 3. Backward compatibility: missing tag entirely → treat as "none" / zero contribution. Old-contract workers (pre-out-of-scope-flow) never emitted this tag and operate under pre-Invariant-4 semantics for the rest of their grind; new-contract workers always emit it. Do NOT bail "subagent output unparseable" on a missing RESULT_ISSUES_SPAWNED — the protocol is additive, not version-pinned.)
RESULT_BAIL_REASON: <one-line free-form prose>        (present only when status=bail; for human consumption — NEVER substring-matched for control flow)
RESULT_BAIL_CATEGORY: judgment | env | budget | policy  (present only when status=bail; `budget` and `policy` are dispatcher-only — emitted when the loop exhausts or when an external org-policy gate blocks merge that pr-grind cannot resolve via fix-rounds or wait-rounds, e.g. required-approver gap)
```

### Dispatcher commit-block contract (`scripts/dispatcher-commit-block.sh`)

Inputs (env vars, required):
- `WORKTREE_DIR`, `CLAUDE_PLUGIN_ROOT`, `PR_NUMBER`, `RESULT_STATUS`, `RESULT_FIXES`.
- `PR_HEAD_HOST`, `PR_HEAD_OWNER`, `PR_HEAD_NAME` (#890) — the PR's home repository from Step 0's `pr-head-identity.sh`. Validated on every invocation before routing; missing or malformed → `env` bail. The fix-round push goes only to named `origin` whose single effective push URL is this repository, as `NEW_COMMIT_SHA:refs/heads/<branch>` (no upstream, `pushDefault` or `push.default` dependence). Every post-commit push bail carries a `[full_ref=… NEW_COMMIT_SHA=… pr_number=… push_dest_id=… push_repo_id=… pre_push_tip=… tip_lookup=…]` trailer for "Push bail recovery (manual only)".

Inputs (env vars, optional; default 0/empty):
- `NO_WORKTREE` - `1` enables the pre-dispatch baseline check for no-worktree mode (worker runs in the repo root and shares the parent index).
- `PRE_DISPATCH_BASELINE` - JSON array of paths staged before worker dispatch; required when `NO_WORKTREE=1`.
- `BUSDRIVER_ALLOW_NO_COMMITLINT` - `1` allows a missing local commitlint binary.
- `PRIOR_COMMIT_SHA` - the last FIX-round's reported commit SHA (dispatcher state, default `none`; retained across wait-rounds, which report `none`). The wait-round landed-fix check (#668) uses it to bind the reported SHA to THIS round: a clean-index invocation whose pinned HEAD equals `PRIOR_COMMIT_SHA` is sitting on an already-counted fix and must report `none`, never double-count it.

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

### Push bail recovery (manual only)

After a fix-round bail the fix commit stays on the local branch, the ephemeral worktree is removed, and the next grind's non-forced Step 0 fetch cannot rewind a local-ahead branch, so `resolve-pr-worktree.sh` stops on the SHA mismatch. Automation never retries, resets or forces. This procedure is the only recovery, and the operator runs it by hand.

**Run all of it in bash, from a cleared environment:** `env -i HOME="$HOME" PATH="$PATH" TERM="${TERM-}" SSH_AUTH_SOCK="${SSH_AUTH_SOCK-}" bash --noprofile --norc` (add only what your credential helper needs, e.g. `GH_TOKEN`). `--noprofile --norc` alone skips startup files but still inherits every exported variable — `GIT_DIR`, `GIT_CONFIG_PARAMETERS`/`GIT_CONFIG_COUNT`, `BASH_ENV`, exported `BASH_FUNC_*` — any of which can redirect the repository, config or a command below; `env -i` drops them. `PATH` is still yours, so this is not full sanitization. This is a shell the operator starts by hand, not the dispatcher session ADR 0026 covers. It uses `read -a` and `${a[@]+…}`, which zsh — the macOS default interactive shell — does not accept. It runs in the clone that still holds the branch, never in the removed ephemeral worktree. It reads **only** the envelope file whose basename the bail message named (`ENVELOPE_FILE=`). It never reads conversation prose, `RESULT_BAIL_REASON`, a grind log or a re-typed reason. "Row 4" below means **STOP: no push, reset or rebase; investigate.**

**0. Enter the main clone and load the installed helpers.** Start a fresh shell with the `env -i … bash --noprofile --norc` line above, from any directory. Nothing inherited is used: no plugin-root or library variable from the environment, and not the current directory. Paste the three `RECOVERY_*` values exactly as the bail message printed them; they are `%q`-quoted, so each pastes as one inert word even when the path holds `'`, `$`, `` ` `` or spaces.

```bash
unset bd_detached bd_orig   # bd_stop reads these; never trust inherited values
bd_stop() {   # exits this recovery shell; after the row-2 detach it first returns, hooks disabled
  if [ "${bd_detached:-0}" = 1 ]; then
    git -c core.hooksPath=/dev/null switch - || printf 'note: still detached; restore %s by hand\n' "${bd_orig-}" >&2
  fi
  printf 'STOP (no push, reset or rebase): %s\n' "$1" >&2; exit 1
}
unset bd_clone bd_gcd bd_lib
bd_clone=<RECOVERY_CLONE value as printed>
bd_gcd=<RECOVERY_GIT_COMMON_DIR value as printed>
bd_lib=<RECOVERY_LIB_ROOT value as printed>
cd -- "$bd_clone" || bd_stop "cannot enter the main clone"
[ "$(git rev-parse --path-format=absolute --git-common-dir)" = "$bd_gcd" ] || bd_stop "not the clone that ran the grind"
case $bd_lib in /*) ;; *) bd_stop "library root missing or not absolute" ;; esac
[ -f "$bd_lib/push-dest-id.sh" ] && [ -r "$bd_lib/push-dest-id.sh" ] || bd_stop "installed helper library not found"
. "$bd_lib/push-dest-id.sh" || bd_stop "helper library failed to load"
for _f in _bd890_read_one_push_url _bd890_one_record _bd890_transport_cred_ok _bd890_endpoint_identity _bd890_endpoint_matches_pr; do
  declare -F "$_f" >/dev/null || bd_stop "helper $_f missing"
done
```

`RECOVERY_LIB_ROOT` is the installed plugin version that ran the dispatch — never a checkout's `scripts/lib`. If it has since been removed (a plugin update), recovery STOPs; there is no fallback. No `RECOVERY_*` values (the bail message is lost) → STOP. Separate-git-dir and bare-hub layouts fail the common-dir check → STOP.

**1. Same shell: pinned object view, non-evaluating extraction, validation.**

```bash
export GIT_NO_REPLACE_OBJECTS=1          # the dispatcher's object view; replacement refs are never pushed
unset full_ref NEW_COMMIT_SHA PR_NUMBER push_repo_id push_dest_id pre_push_tip tip_lookup reason category trailer env_file env_name bd_orig bd_detached
env_name='<basename of the ENVELOPE_FILE path in the bail message>'   # closed charset; the directory comes from Git
reason=""; category=""                    # anything below that fails leaves these empty → row 4
if printf '%s' "$env_name" | grep -Eq '^pr-grind-bail-[1-9][0-9]*\.[A-Za-z0-9]{6}$' \
   && env_file=$(git rev-parse --path-format=absolute --git-common-dir)/$env_name \
   && [ -f "$env_file" ] && [ ! -L "$env_file" ]; then
  _env_line=$(tail -n 1 "$env_file") || _env_line=""
  _env_ok='select(type=="object" and (.bail_category|type)=="string" and (.bail_reason|type)=="string")'
  reason=$(printf '%s\n' "$_env_line" | jq -er "$_env_ok | .bail_reason") || reason=""
  category=$(printf '%s\n' "$_env_line" | jq -er "$_env_ok | .bail_category") || category=""
fi
trailer=${reason##*\[}                    # the dispatcher's trailer is the LAST [...] group; refnames cannot contain '['
case $trailer in *']') trailer=${trailer%]} ;; *) trailer="" ;; esac   # no closing ']' → row 4
read -r -a _toks <<<"$trailer"
dup=0; extra=0
for t in ${_toks[@]+"${_toks[@]}"}; do case $t in   # ${v+x}: a key already seen (even with an empty value) → dup
  full_ref=*)       [ -z "${full_ref+x}" ]       || dup=1; full_ref=${t#full_ref=} ;;
  NEW_COMMIT_SHA=*) [ -z "${NEW_COMMIT_SHA+x}" ] || dup=1; NEW_COMMIT_SHA=${t#NEW_COMMIT_SHA=} ;;
  pr_number=*)      [ -z "${PR_NUMBER+x}" ]      || dup=1; PR_NUMBER=${t#pr_number=} ;;
  push_repo_id=*)   [ -z "${push_repo_id+x}" ]   || dup=1; push_repo_id=${t#push_repo_id=} ;;
  push_dest_id=*)   [ -z "${push_dest_id+x}" ]   || dup=1; push_dest_id=${t#push_dest_id=} ;;
  pre_push_tip=*)   [ -z "${pre_push_tip+x}" ]   || dup=1; pre_push_tip=${t#pre_push_tip=} ;;
  tip_lookup=*)     [ -z "${tip_lookup+x}" ]     || dup=1; tip_lookup=${t#tip_lookup=} ;;
  *)                extra=1 ;;                   # unknown token → row 4
esac; done
```

Values are assigned by parameter expansion only — nothing is evaluated or sourced from the envelope, so a branch name holding `$`, backticks, `;` or `(` stays inert data. The only pasted text is the basename, validated against its closed `mktemp` shape before use.

- `dup=1` (any of the seven keys repeated, including a repeated empty `pre_push_tip=`) or `extra=1` → row 4.
- `category` must be `judgment` or `env`, else row 4.
- **Bail class** = an anchored starts-with match of `reason` (`case "$reason" in "<prefix>"*)`), never an equality test — the dispatcher writes `<prefix>: <diagnostic> [<trailer>]`, and the diagnostic can never select a class:
  - **history** (row 2): `judgment` + `git push non-fast-forward; local commit preserved: `
  - **unknown-outcome** (row 3): `env` + `git push outcome unknown — `
  - **phrase-level env** (rows 3b/3d): `env` + `git push auth/network/config: `
  - **pre-push drift** (row 3c): `env` + `dispatcher-commit-block: detached HEAD before push [` or `dispatcher-commit-block: branch changed before push (`
  - **trailer** (step 5 only, never the table): `env` + `failed to re-scan the commit message for verification; `, `Grind-PR: line is not the exact byte sequence the scanner matches; `, `failed to parse trailers for verification; ` or `Grind-PR: is not an exact trailer on the commit (trailer block: `
  - **everything else** → row 4 (including `git push rejected; local commit preserved: `, `git push failed; local commit preserved: `, `dispatcher-commit-block: push destination changed after pin [`, and no match).
- Validate, else row 4: `full_ref` matches `refs/heads/*` and passes `git check-ref-format`; its short name `${full_ref#refs/heads/}` does not start with `-` (defense in depth — no command here takes the short name); `NEW_COMMIT_SHA` is 40/64 lowercase hex; `PR_NUMBER` matches `^[1-9][0-9]*$`, equals the PR being recovered and equals the `<N>` in `env_name`; `push_repo_id` is non-empty; and `git rev-parse --verify "$full_ref"` equals `NEW_COMMIT_SHA` (stale-file guard: an older round's envelope fails here).
- **Required tokens by bail type.** `full_ref`, `NEW_COMMIT_SHA`, `pr_number`, `push_repo_id` and `push_dest_id` for every class except trailer. Push-attempt bails (a classifier prefix or unknown-outcome) also need `tip_lookup=` (`skipped|failed|observed`) and `pre_push_tip=` (empty, or hex when `observed`). Pre-push bails (`detached HEAD before push`, `branch changed before push`, `push destination changed after pin`) must carry **neither**. The **trailer class** carries exactly `full_ref` and `NEW_COMMIT_SHA` (any other key → STOP); its `PR_NUMBER` is the `<N>` of `env_name`, and it goes to step 5, skipping steps 2–4.

The same checks as one block, run in the same shell (any failure is row 4 — it STOPs before any lookup, fetch, switch or push):

```bash
bd_pr=<the PR number you are recovering>
bd_class=other
case "$category:$reason" in
  "judgment:git push non-fast-forward; local commit preserved: "*) bd_class=history ;;
  "env:git push outcome unknown — "*) bd_class=unknown ;;
  "env:git push auth/network/config: "*) bd_class=env ;;
  "env:dispatcher-commit-block: detached HEAD before push ["*|\
  "env:dispatcher-commit-block: branch changed before push ("*) bd_class=drift ;;
  "env:failed to re-scan the commit message for verification; "*|\
  "env:Grind-PR: line is not the exact byte sequence the scanner matches; "*|\
  "env:failed to parse trailers for verification; "*|\
  "env:Grind-PR: is not an exact trailer on the commit (trailer block: "*) bd_class=trailer ;;
esac
bd_n=${env_name#pr-grind-bail-}; bd_n=${bd_n%%.*}
[ "$dup" = 0 ] && [ "$extra" = 0 ] || bd_stop "row 4: duplicate or unknown trailer token"
[ "$bd_class" != other ] || bd_stop "row 4: this bail class has no recovery row"
case ${full_ref-} in refs/heads/*) ;; *) bd_stop "row 4: full_ref is not a branch" ;; esac
git check-ref-format "$full_ref" || bd_stop "row 4: full_ref fails check-ref-format"
case ${full_ref#refs/heads/} in -*) bd_stop "row 4: dash-led branch name" ;; esac
printf '%s' "${NEW_COMMIT_SHA-}" | grep -Eq '^[0-9a-f]{40}$|^[0-9a-f]{64}$' || bd_stop "row 4: NEW_COMMIT_SHA is not object-format hex"
[ "$bd_n" = "$bd_pr" ] || bd_stop "row 4: the envelope is for another PR"
[ "$(git rev-parse --verify "$full_ref")" = "$NEW_COMMIT_SHA" ] || bd_stop "row 4: full_ref is no longer at NEW_COMMIT_SHA (stale envelope)"
if [ "$bd_class" = trailer ]; then
  [ -z "${PR_NUMBER+x}${push_repo_id+x}${push_dest_id+x}${pre_push_tip+x}${tip_lookup+x}" ] || bd_stop "trailer-class envelope carries push tokens"
  PR_NUMBER=$bd_n            # → step 5
else
  [ "${PR_NUMBER-}" = "$bd_pr" ] || bd_stop "row 4: pr_number"
  [ -n "${push_repo_id-}" ] && [ -n "${push_dest_id-}" ] || bd_stop "row 4: push_repo_id / push_dest_id missing"
  if [ "$bd_class" = drift ]; then
    [ -z "${pre_push_tip+x}${tip_lookup+x}" ] || bd_stop "row 4: a pre-push bail carries push-attempt tokens"
  else
    [ -n "${pre_push_tip+x}" ] || bd_stop "row 4: pre_push_tip= missing"
    case ${tip_lookup-} in
      skipped|failed) [ -z "$pre_push_tip" ] || bd_stop "row 4: pre_push_tip without an observed lookup" ;;
      observed) printf '%s' "$pre_push_tip" | grep -Eq '^[0-9a-f]{40}$|^[0-9a-f]{64}$' || bd_stop "row 4: pre_push_tip" ;;
      *) bd_stop "row 4: tip_lookup" ;;
    esac
  fi
fi
printf 'step 1 ok: class=%s\n' "$bd_class"
```

**2. Identity, then a fresh lookup.** Read the push URL with the dispatcher's own reader: `_rd=0; _bd890_read_one_push_url || _rd=$?`. **STOP** unless, in order: `_rd` is 0 (exactly one raw record); `_bd890_transport_cred_ok "$_BD890_ONE_URL"`; `_bd890_endpoint_matches_pr "$_BD890_ONE_URL" "$push_repo_id"` (the recorded PR tuple — never `push_dest_id`, never a parse of origin.url). Then `checked_push_url=$_BD890_ONE_URL` (a shell variable, never printed). Look up only with `git ls-remote --refs origin "$full_ref"`, and only if the effective fetch URL (`git remote get-url origin`) passes the same two checks. Never ls-remote a URL. Record exactly one outcome:

- `observed` — exit 0, exactly one row whose second field equals `$full_ref`, object-format hex oid;
- `verified-absent` — exit 0, no exact row (the PR branch is gone; recreating it is not this recovery → row 4);
- `failed` — non-zero, timeout, more than one exact row, or a malformed oid;
- `skipped` — fetch URL ineligible, or no lookup run.

Every "tip" below is a fresh `observed` outcome. **Strict ancestor** (evaluated only where a row names it — rows 3c and 3d, never before row 1 or 2), in order: `git cat-file -e "$tip^{commit}"`; `git merge-base --is-ancestor "$tip" "$NEW_COMMIT_SHA"`; `[ "$tip" != "$NEW_COMMIT_SHA" ]`. Any failure → row 4.

**3. Pushing.** When a row allows one manual push, the command is exactly:

```bash
git -c remote.origin.mirror=false -c push.followTags=false -c push.recurseSubmodules=no -c advice.pushUpdateRejected=false push origin "${NEW_COMMIT_SHA:?}:${full_ref:?}"
```

Row 2 pushes `"${sha:?}:${full_ref:?}"` instead. The `:?` guards are mandatory: an empty source in a refspec DELETES the PR branch. Never bare `git push`, never force. Immediately before **each** manual push, with `c` the commit to push:

- **Attribution** (the dispatcher's own Step 10a reads): `[ "$(GIT_NO_REPLACE_OBJECTS=1 git rev-list --no-walk --grep="^Grind-PR: ${PR_NUMBER:?}\$" "${c:?}")" = "$c" ]`, and `GIT_NO_REPLACE_OBJECTS=1 git -c trailer.separators=':' log -1 --format='%(trailers)' "${c:?}"` contains the exact line `Grind-PR: $PR_NUMBER`. Failure → row 4.
- **Destination revalidation:** a fresh `_rd=0; _bd890_read_one_push_url || _rd=$?`, then `_rd` is 0, `_bd890_transport_cred_ok`, `_bd890_endpoint_matches_pr … "$push_repo_id"`, and `[ "$_BD890_ONE_URL" = "$checked_push_url" ]`. Anything else → row 4.

Then run the push once.

**4. Decision table** (first matching row wins; exhaustive):

| # | Bail class | Fresh tip vs recorded tokens | Action |
|---|---|---|---|
| 1 | Any | tip == `NEW_COMMIT_SHA` | **Done.** No push, no reset. |
| 2 | History | Foreign tip ≠ `NEW_COMMIT_SHA`; local `full_ref` == `NEW_COMMIT_SHA` | Rebase path below (the only rebase). |
| 3 | Unknown-outcome | Recorded non-empty `pre_push_tip`, and tip == it | At most one manual push (step 3). |
| 3b | Phrase-level env, cause fixed | Recorded `pre_push_tip` non-empty hex; tip == it; tip ≠ `NEW_COMMIT_SHA` | At most one manual push. |
| 3c | Pre-push drift (`detached HEAD before push` / `branch changed before push` only) | Local `full_ref` == `NEW_COMMIT_SHA`; tip is a strict ancestor of it | At most one manual push. |
| 3d | Phrase-level env with `tip_lookup=skipped` or `failed`, cause fixed | Step-2 identity holds; local `full_ref` == `NEW_COMMIT_SHA`; tip is a strict ancestor | At most one manual non-force push. |
| 4 | Everything else: unknown-outcome otherwise; hook / other env / revalidation bails; default judgment; history with a non-`observed` lookup; any `verified-absent`, `failed` or `skipped` lookup; missing or ambiguous tokens | — | **STOP.** No push, reset or rebase. Investigate. |

3d accepts `failed` because neither `skipped` nor `failed` carries a pre-push observation; it decides only from a fresh post-fix one (if the uncertain failure landed the commit, row 1 wins; if someone else advanced the branch, the tip is not an ancestor → row 4; a race after the lookup makes the non-force push fail).

**Row 2 — rebase path (history class only).** Every exit after `bd_detached=1` returns through the hook-less switch — `bd_stop` performs it before exiting, and the success path runs it at the end; exits before it change nothing and never switch.

```bash
# (a) The foreign tip must be present locally. The only retrieval: named remote,
#     no URL, no :<dst>, and an empty --refmap= so a configured remote.origin.fetch
#     mapping updates no ref at all (it writes objects and FETCH_HEAD only).
#     Run it only after the step-2 fetch-URL checks passed.
if ! git cat-file -e "$tip^{commit}" 2>/dev/null; then
  git fetch --no-tags --refmap= origin "${full_ref:?}" || bd_stop "fetch failed"
  [ "$(git rev-parse --verify "FETCH_HEAD^{commit}")" = "$tip" ] || bd_stop "FETCH_HEAD is not the observed tip"
fi
# (b) Preconditions — nothing changed if any fails.
[ -z "$(git status --porcelain --untracked-files=no)" ] || bd_stop "tracked changes present"
for p in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
  [ ! -e "$(git rev-parse --git-path "$p")" ] || bd_stop "operation in progress: $p"
done
[ "$(git rev-parse --verify "$full_ref")" = "$NEW_COMMIT_SHA" ] || bd_stop "full_ref moved"
bd_here=$(git rev-parse --show-toplevel)
[ -z "$(git worktree list --porcelain | awk -v r="branch $full_ref" -v here="worktree $bd_here" '/^worktree /{w=$0} $0==r && w!=here {print w}')" ] \
  || bd_stop "full_ref is checked out in another worktree"
# Rebase on a DETACHED HEAD, so full_ref does not move until the push has landed.
bd_orig=$(git symbolic-ref -q HEAD || git rev-parse --verify HEAD)
# Hooks off: git reports a failing post-checkout hook AFTER it has detached, which
# would skip bd_detached=1 and leave bd_stop unable to return.
git -c core.hooksPath=/dev/null switch --detach "${NEW_COMMIT_SHA:?}" && bd_detached=1 || bd_stop "detach failed"
```

From here on, any failure is row 4, and `bd_stop` returns before it exits. Require `git rev-parse --verify HEAD` == `NEW_COMMIT_SHA` (defense in depth; the detach ran no hook). Then rebase with no branch argument, so it rebases the detached HEAD (`updateRefs=false` stops an operator `rebase.updateRefs=true` from moving `full_ref`; never `pull`, `reset` or `--force`; a conflict → `git rebase --abort`, row 4):

```bash
git -c rebase.updateRefs=false rebase --onto "$tip" "${NEW_COMMIT_SHA:?}^" \
  || { git rebase --abort; bd_stop "row 4: rebase failed (conflict); aborted"; }
sha=$(git rev-parse --verify HEAD)
```

Require: `sha` ≠ `NEW_COMMIT_SHA`; `git merge-base --is-ancestor "$tip" "$sha"`; **`git rev-list --count "$tip..$sha"` is exactly `1`** (a commit a hook injected during the rebase is never pushed); and `git rev-parse --verify "$full_ref"` still == `NEW_COMMIT_SHA`. Run the step-3 checks with `c=$sha` (attribution, then destination revalidation — the switch and rebase ran hooks), then push `"${sha:?}:${full_ref:?}"` once — never the stale `NEW_COMMIT_SHA`. **After a successful push**, while still detached at `$sha`, move the local branch to the pushed commit with a compare-and-swap. A fast-forward cannot do it: `$sha`'s parent is the remote tip, not `NEW_COMMIT_SHA`, so the next grind's non-forced fetch would leave local and remote diverged and Step 0 would stop on the SHA mismatch.

```bash
git update-ref -m "pr-grind: recovery row 2 pushed ${sha:?}" "${full_ref:?}" "${sha:?}" "${NEW_COMMIT_SHA:?}" \
  || bd_stop "full_ref moved during recovery; the push landed — reconcile full_ref with origin by hand"
```

Then return with hooks disabled (`bd_stop` does the same on any row-4 exit after the detach), so no post-checkout hook can commit onto `full_ref`, and check where you landed:

```bash
[ "${bd_detached:-0}" = 1 ] && git -c core.hooksPath=/dev/null switch -
[ "$(git symbolic-ref -q HEAD || git rev-parse --verify HEAD)" = "$bd_orig" ] \
  || printf 'note: HEAD did not return to %s; restore it by hand (no push depends on it)\n' "$bd_orig" >&2
```

Before the push, `full_ref` never moves, so a failed check leaves the branch, the envelope and the stale-file guard exactly as they were. If the clone had `full_ref` checked out, returning to it after the push lands on the pushed commit with a clean tree.

**5. Trailer class only — discard the unattributed commit, never push it.** Runs after steps 0–1 instead of steps 2–4. A local compare-and-swap on `full_ref` alone; it never touches HEAD, the index, the working tree or the remote:

```bash
bd_parent=$(git rev-parse --verify "${NEW_COMMIT_SHA:?}^1^{commit}") || bd_stop "no parent"
! git rev-parse -q --verify "${NEW_COMMIT_SHA:?}^2" >/dev/null || bd_stop "merge commit"
git update-ref -m "pr-grind: discard unattributed ${NEW_COMMIT_SHA:?}" "${full_ref:?}" "$bd_parent" "${NEW_COMMIT_SHA:?}" \
  || bd_stop "full_ref moved since the bail"
```

The old value is checked atomically, so a branch moved since the bail is never rewound. The commit stays in the reflog. If `full_ref` is checked out somewhere, that tree keeps the commit's changes staged — nothing is lost. Then fix the hook and re-grind; Step 0's SHA check sees local == PR head again. Pushing the bailed commit is never a recovery: it would bypass Rail A (ADR 0036).

**6. Same shell, after step 5: clear the discarded commit from this clone's tree.** An in-place re-grind refuses a dirty index, so when this clone has `full_ref` checked out, drop the changes step 5 left staged. It is a no-op otherwise, and it STOPs unless the index and tracked tree hold exactly `NEW_COMMIT_SHA` — your own uncommitted edits are never touched. It also STOPs when the commit deleted or moved a path: switching back would have to create that path, and an untracked or ignored file you put there since would be overwritten. What remains only rewrites or removes tracked files whose content was just checked against `NEW_COMMIT_SHA`. The switch is a two-tree `read-tree -m -u`, never `restore`/`reset`/`checkout --force`. The discarded content stays reachable as `NEW_COMMIT_SHA` in the reflog:

```bash
if [ "$(git symbolic-ref -q HEAD)" = "${full_ref:?}" ]; then
  if ! { git diff --quiet "${NEW_COMMIT_SHA:?}" && git diff --cached --quiet "${NEW_COMMIT_SHA:?}"; }; then
    bd_stop "the tree holds changes beyond the discarded commit; clear them by hand"
  fi
  bd_created=$(git diff --name-only --no-renames --diff-filter=A "${NEW_COMMIT_SHA:?}" HEAD) || bd_stop "cannot list the paths to restore"
  [ -z "$bd_created" ] || bd_stop "the discarded commit deleted or moved paths; restore the tree by hand"
  git read-tree -m -u "${NEW_COMMIT_SHA:?}" HEAD || bd_stop "switching the tree back failed"
fi
```

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
  - Round 3 (fix=2/5, wait=0/8): commit=4361cc54; fixes=remove /blog/* paths from 4 relatedTools blocks; failures=none; acks=cubic-dev-ai=stale,...; scope-skipped=2; spawned=2
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
- **Deferred consumption** (unique to pre-merge — added to fix the consume-on-gate-pass-but-API-fail bug surfaced during PR #115's dogfood): the PreToolUse gate writes a pending claim to `.claude/.merge-bypass-pending.local` and leaves the skip file alone. The PostToolUse hook `post-merge-confirm-bypass.sh` consumes the skip file ONLY when `gh pr merge` confirms success. On merge failure (`X Pull request is not mergeable`, conflicts, branch protection) that the GitHub API does not later confirm `MERGED`, ambiguous output, mtime tamper, or PR-number mismatch between the claim and the executed command, the skip file is preserved so the operator can retry without a re-touch. An **accepted** `--auto` queue is not one of these preserved cases (#664): GitHub lands that merge with no further hook event to confirm it later, so the token is consumed immediately (`reason: auto-merge-accepted-token-spent`) rather than left armed for a merge nothing will ever re-check. Audit events all log to `.claude/bypass-log.jsonl` — see the event taxonomy in `docs/observability.md`.
- **Explicit-PR requirement when using the bypass**: `gh pr merge` (no PR number, auto-detect from current branch) records `merge_pr=unknown` in the pending claim. Confirmation then refuses to consume the bypass token (treated as `-released-mismatch` to prevent cross-PR token reuse via branch-switching). The merge itself proceeds (the gate already authorized it), but the bypass log will show `skip-pr-grind-released-mismatch` rather than `-consumed`, and the skip file remains valid until **1h after the original `touch`** (the 3600s window is anchored to the skip file's mtime, NOT to the failed merge — a released token does not refresh its clock). To get a clean audit trail and consume the bypass token, pass the PR number explicitly: `gh pr merge 42 --squash`.

When emitting the verbatim message template (from the canonical protocol — see below), tell the user "the file must be touched within the last hour — the gate rejects ages of 3600s or more" so they don't sit on it indefinitely. Otherwise the protocol is identical to other gates: 35s `Monitor` wait, no Bash verification, NEVER create the skip file yourself, etc.

**Stale-file recovery (pr-grind only):** If `gh pr merge` blocks after the user has already run `touch` and Claude has waited the 35s, the skip file may have expired (≥3600s since `touch`). The gate silently deletes stale files without bypassing — there's no "stale" message. Ask the user to `touch` again and restart the 35s wait. Note that with deferred consumption, a failed merge no longer requires a re-touch unless the file actually aged past 3600s — or unless GitHub reports the PR `MERGED` anyway (the `--delete-branch` worktree-conflict shape), in which case the token is correctly spent on the merge it authorized (#664).

**Full protocol** — verbatim message template (with `<GATE>` substitution), `Monitor`-based 35s wait pattern, and hard rules — lives canonically in `skills/blueprint-review/SKILL.md` → "User-Created Skip File". The protocol is identical across all busdriver gates; only the pre-merge specifics in the bullets above differ.

## Integration

- **Pairs with:** `finishing-a-development-branch` (Phase 6 creates the PR and cleans up its worktree, then `/pr-grind` creates its own ephemeral worktree for the feedback loop)
- **Worktree lifecycle:** pr-grind owns its worktree from creation to cleanup — independent of the pipeline's Phase 3 worktree.
- **Gate:** Litmus runs inside the dispatcher-owned commit block before each fix commit; pre-merge gate fires on `gh pr merge` (skip: `.claude/skip-pr-grind.local`)
- **Subagent:** `pr-grinder` (opus) — receives one-round dispatch, returns RESULT_* tags. See `agents/pr-grinder.md`.
