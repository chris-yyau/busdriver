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

## Safety Rails

- **Max iterations:** 5 rounds (override with `--max N`)
- **Autonomous by default:** Grinds without pausing between rounds (override with `--interactive` for human checkpoints)
- **Merges by default:** After grinding clean, pr-grind merges the PR. Pass `--no-merge` to skip the merge and just declare "Ready for merge". This is NOT GitHub auto-merge — pr-grind merges *after* all checks pass and all comments are addressed, inside its own control flow.
- **Bail triggers:** Stop immediately and clean up worktree if:
  - A comment is a design/scope question (not a code fix)
  - CI fails on an unrelated flaky test 3 times in a row
  - The fix would require architectural changes
  - Max iterations reached
  - **On any bail:** if Step 0 created an ephemeral worktree, `cd` back and `git worktree remove "../pr-grind-<PR_NUMBER>" --force 2>/dev/null || true` before exiting. Skip when `--no-worktree` was passed (no worktree to remove). The `|| true` keeps cleanup idempotent if the worktree was already removed.

## The Dispatcher Loop

```text
START
  ├── Resolve PR # (arg, current branch, or ask user)
  ├── Step 0: Create ephemeral worktree
  └── Initialize: PRIOR_COMMIT_SHA=none, PRIOR_ATTEMPTS=[],
                   PRIOR_REVIEWER_ACKS="greptile-apps=none,cubic-dev-ai=none,coderabbitai=none,copilot-pull-request-reviewer=none"

LOOP for round in 1..MAX:
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
  ├── Parse subagent output:
  │     RESULT_STATUS=clean       → validate invariants, go to COMPLETION
  │     RESULT_STATUS=bail        → break loop, go to BAIL
  │     RESULT_STATUS=needs_more  → validate invariant, update state, continue
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
  │        infra-error path (see `ack_for_bot`) will not appear as
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
  │
  └── Update state:
        PRIOR_COMMIT_SHA    = RESULT_COMMIT_SHA
        PRIOR_REVIEWER_ACKS = RESULT_REVIEWER_ACKS
        PRIOR_ATTEMPTS     += "Round N: fixes=<RESULT_FIXES>; failures=<RESULT_REMAINING>; acks=<RESULT_REVIEWER_ACKS>"
        # failures= is required — subagent's flaky-check bail (3+ rounds)
        # reads it. Dropping it makes that bail unreachable and the loop
        # will grind to MAX rounds instead of stopping early on a flaky
        # check.
        # acks= is preserved for diagnostics / human review of the loop
        # transcript; the worker does NOT bail on stale-ack streaks (every
        # commit-round emits all-stale by design, so a streak is the
        # healthy case). Genuinely stuck bots fall out via MAX iterations.

# Loop exits naturally when round > MAX without ever seeing RESULT_STATUS=clean
# → fail-CLOSED to BAIL, NOT to COMPLETION. The PR isn't clean; we just ran
# out of attempts. Writing the marker here would silently merge an unfinished PR.
ON_LOOP_EXHAUSTED → go to BAIL with reason "max iterations (<MAX>) reached without clean status"

COMPLETION:
  ├── Verify checks one more time (defense in depth)
  ├── Recompute ack ledger and assert all entries are <HEAD-SHA> or `none`
  │   (defense in depth — invariant check 2 already gated this, but the
  │   bot may have re-posted between subagent return and merge time)
  ├── Write .claude/pr-grind-clean.local at repo root
  ├── default → gh pr merge --squash --delete-branch
  ├── --no-merge → write marker to original-worktree repo root, report ready
  └── Cleanup ephemeral worktree

BAIL:
  └── Cleanup ephemeral worktree, surface RESULT_BAIL_REASON to user
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
git worktree add "$WORKTREE_DIR" "$PR_BRANCH"
cd "$WORKTREE_DIR"
```

**Why a worktree:** pr-grind is a different operational mode from the pipeline. Pre-PR phases optimize for local delivery; post-PR grind optimizes for async iteration. An ephemeral worktree gives pr-grind its own branch ownership without hijacking the main workspace.

**Skip with `--no-worktree`:** If already on the PR branch, pass `--no-worktree` to skip worktree creation.

### Dispatch a Round (default path)

Build the context block and dispatch the subagent. The block must include everything the subagent needs — it has no memory of prior rounds.

```text
Agent invocation:
  subagent_type: pr-grinder
  description: pr-grind round N
  prompt: |
    PR_NUMBER=<N>
    OWNER=<owner>
    REPO=<repo>
    WORKTREE_DIR=<absolute path>
    ROUND=<N> of <MAX>
    PRIOR_COMMIT_SHA=<sha or "none">
    PRIOR_REVIEWER_ACKS=<login=value,login=value,...> (round 1: every registered bot = none)
    PRIOR_ATTEMPTS:
      - Round 1: fixes=<summary>; failures=<failed-check-names or "none">; acks=<login=value,...>
      - Round 2: fixes=<summary>; failures=<failed-check-names or "none">; acks=<login=value,...>
      ...

    Execute one round per agents/pr-grinder.md. Return RESULT_* tags.
```

After the subagent returns, **scan the response for lines matching `^RESULT_<NAME>: ` and extract each tag's value**. Don't rely on a fixed line count — `RESULT_BAIL_REASON` is only present on bail. Parsing by tag prefix is robust to additions/omissions. If the same tag appears multiple times (e.g., the subagent quotes a review comment that happens to contain `RESULT_STATUS:`), use the **last** occurrence — the canonical block is at the end of the response.

The full tag set:

```
RESULT_STATUS: clean | needs_more | bail              (always present)
RESULT_COMMIT_SHA: <sha or "none">                    (always present)
RESULT_FIXES: <one-line summary>                      (always present)
RESULT_REMAINING: <one-line or "none">                (always present)
RESULT_REVIEWER_ACKS: <login=value,login=value,...>   (always present; values: <short-sha> | none | stale; early-bail paths emit the all-`none` default initialized before Step 0)
RESULT_BAIL_REASON: <one-line>                        (present only when status=bail)
```

If `RESULT_STATUS` is missing or its value isn't one of the three valid options, treat as `bail` with reason "subagent output unparseable" — do not guess.

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
| **Automated reviewer — stale/pre-existing issue** | Skip — only fix issues in YOUR changed code |
| **Resolved or outdated thread** | Skip — already filtered out by GraphQL (`isResolved`, `isOutdated`) |
| **Human review — specific fix request** | Fix it |
| **Human review — question/clarification** | Reply with explanation, don't change code |
| **Human review — design/scope concern** | **BAIL** — surface to user, this needs human judgment |
| **Code review — nit/style** | Fix it (low effort, high goodwill) |

**Important:** Automated reviewers often post on code that was already in the repo before your PR. Only fix issues in files/lines that YOUR PR changed.

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

This block intentionally mirrors `agents/pr-grinder.md` Step 6.5 (the Sonnet worker copy) and the dispatcher's `dispatcher_ack_for_bot` in COMPLETION below. **All three copies must stay in sync** — if one changes, update the other two. Function name (`inline_ack_for_bot`) and result-var name (`ROUND_ACKS`) differ from the worker/dispatcher to avoid namespace shadowing if multiple snippets ever run in the same Bash invocation.

The `<PR_NUMBER>`, `<owner>`, `<repo>` placeholders below follow the same template-substitution convention used by COMPLETION — Claude substitutes the literal owner / repo / PR-number values at run time before executing the bash.

```bash
PR=<PR_NUMBER>
OWNER=<owner>
REPO=<repo>
HEAD_SHA=$(git rev-parse HEAD | cut -c1-8)

# One-shot fetches. FETCH_OK tracks any source failure; if any source failed,
# inline_ack_for_bot fails-CLOSED to `stale` for every bot (fail-OPEN
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

# Three-tier ack — same algorithm as worker's `ack_for_bot` in agents/pr-grinder.md
# and dispatcher's `dispatcher_ack_for_bot` in COMPLETION below.
inline_ack_for_bot() {
  local login="$1"
  local unresolved outdated commit_id body_sha downgrade_pair ever_approved last_body

  # Fail-CLOSED on any source-fetch failure
  if [ "$FETCH_OK" -eq 0 ]; then echo "stale"; return; fi

  # (A) Source 2 thread state — unresolved+non-outdated → stale; outdated-only → effectively acked
  # jq -s slurps paginated graphql output (multiple JSON docs → single array)
  unresolved=$(printf '%s' "$ALL_THREADS" | jq -rs --arg login "$login" --arg login_bot "${login}[bot]" \
    '[.[].data.repository.pullRequest.reviewThreads.nodes[]
      | select(.comments.nodes[0].author.login == $login or .comments.nodes[0].author.login == $login_bot)
      | select(.isResolved == false and .isOutdated == false)] | length' 2>/dev/null || echo 0)
  if [ "$unresolved" -gt 0 ]; then echo "stale"; return; fi
  outdated=$(printf '%s' "$ALL_THREADS" | jq -rs --arg login "$login" --arg login_bot "${login}[bot]" \
    '[.[].data.repository.pullRequest.reviewThreads.nodes[]
      | select(.comments.nodes[0].author.login == $login or .comments.nodes[0].author.login == $login_bot)
      | select(.isOutdated == true)] | length' 2>/dev/null || echo 0)
  if [ "$outdated" -gt 0 ]; then echo "$HEAD_SHA"; return; fi

  # (B) /reviews commit_id — explicit per-commit review submission
  commit_id=$(printf '%s' "$ALL_REVIEWS" | jq -rs --arg login "$login" --arg login_bot "${login}[bot]" \
    '[.[] | .[] | select(.user.login == $login or .user.login == $login_bot)] | last | .commit_id // empty' 2>/dev/null || echo "")
  if [ -n "$commit_id" ] && [ "${commit_id:0:8}" = "$HEAD_SHA" ]; then echo "${commit_id:0:8}"; return; fi

  # (C) Issue-comment body SHA fallback (Greptile-style — single comment updated per commit)
  body_sha=$(printf '%s' "$ALL_COMMENTS" | jq -r --arg login "$login" --arg login_bot "${login}[bot]" \
    '[.comments[] | select(.author.login == $login or .author.login == $login_bot)] | last | .body // empty' 2>/dev/null \
    | grep -oE 'commit/[a-f0-9]{7,40}' | sed 's|.*/||' | tail -1 | cut -c1-8)
  if [ -n "$body_sha" ] && [ "$body_sha" = "$HEAD_SHA" ]; then echo "$body_sha"; return; fi

  # No HEAD-ack signal — distinguish never-posted (none) from posted-on-older (stale)
  if [ -z "$commit_id" ] && [ -z "$body_sha" ]; then echo "none"; return; fi

  # Infra-error / rate-limit downgrade — if the latest review body is a known
  # "tooling failed, try again later" marker (Copilot's permanent error review
  # frozen on an older SHA is the canonical case), treat as `none` not `stale`.
  # The bot left a review object behind but waiting for it to ack HEAD is futile
  # until a human re-requests review. Without this downgrade, a single rate-limit
  # event blocks the merge gate indefinitely.
  #
  # Defense: only fire when the bot has NEVER submitted an APPROVED or DISMISSED
  # review on this PR (`ever_approved == 0`). DISMISSED counts as "ever approved"
  # because a dismissed approval is a historical signal the bot genuinely approved
  # at some point. If the bot ever approved/dismissed any commit, an error in its
  # latest body is transient and `stale` is the correct signal. The guard also
  # prevents an admin-edit bypass where an APPROVED/DISMISSED bot review's body
  # is PATCHed to inject the trigger phrase.
  #
  # Note: the FETCH_OK guard at the top of this function already returns
  # `stale` on any source-fetch failure, so this block only runs on
  # successful fetches.
  #
  # Keep this block in lockstep with `ack_for_bot` (agents/pr-grinder.md) and
  # `dispatcher_ack_for_bot` (below in this file).
  downgrade_pair=$(printf '%s' "$ALL_REVIEWS" | jq -rs --arg login "$login" --arg login_bot "${login}[bot]" \
    '[ .[] | .[] | select(.user.login == $login or .user.login == $login_bot) ]
     | [ (map(select(.state == "APPROVED" or .state == "DISMISSED")) | length),
         (last | .body // empty) ]' 2>/dev/null || echo '[0,""]')
  ever_approved=$(printf '%s' "$downgrade_pair" | jq -r '.[0]' 2>/dev/null || echo 0)
  if [ "$ever_approved" -eq 0 ]; then
    last_body=$(printf '%s' "$downgrade_pair" | jq -r '.[1]' 2>/dev/null || echo "")
    if printf '%s' "$last_body" | grep -qiE 'encountered an error|rate.?limit|unable to review|try again by re-requesting'; then
      echo "none"; return
    fi
  fi

  echo "stale"
}

ROUND_ACKS="greptile-apps=$(inline_ack_for_bot greptile-apps),cubic-dev-ai=$(inline_ack_for_bot cubic-dev-ai),coderabbitai=$(inline_ack_for_bot coderabbitai),copilot-pull-request-reviewer=$(inline_ack_for_bot copilot-pull-request-reviewer)"
echo "Ack ledger: $ROUND_ACKS"

STALE_BOTS=$(echo "$ROUND_ACKS" | tr ',' '\n' | awk -F= '$2=="stale"{print $1}')
echo "STALE_BOTS: $STALE_BOTS"
```

**Acting on the result (instruction to Claude, not shell control flow):** the `STALE_BOTS` variable lives only inside the Bash invocation that runs the snippet above — it does NOT persist into a subsequent inline-loop iteration. After the snippet runs, **Claude reads the printed `Ack ledger:` and `STALE_BOTS:` lines from stdout** and decides:

- **STALE_BOTS empty** → round genuinely complete; proceed to Step 7 (autonomous summary or interactive checkpoint), which will either continue to the next round or dispatch Completion depending on whether checks are green and all findings are resolved.
- **STALE_BOTS non-empty** → round is in waiting-for-bots state; **skip Step 7 entirely** and re-dispatch Step 1 directly (analogous to the Sonnet subagent's `needs_more + RESULT_COMMIT_SHA=none + stale-acks` flow that the dispatcher's relaxed Invariant 1 permits). Increment the round counter as normal.

**Interaction with `--max`:** wait-rounds DO count against `--max` (default 5). If a slow bot consistently takes longer than ~5 minutes per round and never catches up, the loop exhausts and bails with reason `max iterations (<MAX>) reached without all bots acking HEAD; latest stale: <STALE_BOTS>`. Increase `--max` if you're grinding a PR with known-slow reviewer bots, or accept the bail and re-run later.

#### Step 7: Round summary / checkpoint

**Gate:** Step 7 only runs when Step 6.5's `STALE_BOTS` was empty (every registered bot is `<HEAD-SHA>` or `none`). When `STALE_BOTS` is non-empty, the round is in waiting-for-bots state — skip Step 7 entirely and re-dispatch Step 1 directly (mirrors the dispatcher's relaxed Invariant 1 handling for stale-ack rounds).

In autonomous mode (default), log a brief summary and continue immediately to the next round (or to Completion if every check is green and no findings remain). In interactive mode (`--interactive`), present to user and wait:

```text
## PR Grind — Round N/MAX complete

**Fixed:**
- [ ] CI: <what failed and how you fixed it>
- [ ] Review: <comment summary and what you changed>

**Skipped:**
- <design questions, flaky tests, etc.>

**Status:** Pushed. CI will re-run.

Continue grinding?
```

## Completion (post-loop, dispatcher only)

**All of these must be true before declaring done:**
1. Subagent returned `RESULT_STATUS=clean` (or inline mode reached the same state)
2. All required CI checks passing (build, lint, test)
3. All automated reviewers completed (CodeRabbit, Greptile, Cubic, etc.)
4. No unresolved actionable comments from any source
5. No new comments arrived after your last push (wait for the full cycle)
6. Advisory check issues either fixed or noted as beyond PR scope
7. **Reviewer ack ledger**: every registered bot (Greptile, Cubic, CodeRabbit, Copilot) is either `<HEAD-short-SHA>` or `none` in `RESULT_REVIEWER_ACKS`. Any `stale` entry blocks completion — the bot finished its check but hasn't re-reviewed HEAD yet, and merging now would race ahead of its findings. (`none` here can mean either "bot doesn't operate on this repo" OR "bot's only reviews are infra-error/rate-limit markers that cannot self-recover" — both are non-gating; see `ack_for_bot`'s infra-error downgrade.)

**Re-query the ack ledger fresh (REQUIRED — defense in depth against late posts between subagent return and merge time):**

The dispatcher must re-run the same `ack_for_bot` lookup the worker used in Step 6.5, against the live `/reviews` endpoint, with HEAD recomputed against the current branch state. Just re-parsing `$RESULT_REVIEWER_ACKS` would only validate the worker's snapshot — it can't catch a bot that finished re-reviewing in the seconds between subagent return and merge.

The `<PR_NUMBER>`, `<owner>`, `<repo>` placeholders below follow the same template-substitution convention as `<PR_NUMBER>` elsewhere in this Completion section — Claude substitutes the literal owner / repo / PR-number values at run time before executing the bash.

```bash
PR=<PR_NUMBER>
OWNER=<owner>
REPO=<repo>
HEAD_SHA=$(git rev-parse HEAD | cut -c1-8)

# One-shot fetches — same three sources as worker's Step 6.5.
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

# Three-tier ack — same algorithm as worker `ack_for_bot` and inline `inline_ack_for_bot`.
dispatcher_ack_for_bot() {
  local login="$1"
  local unresolved outdated commit_id body_sha downgrade_pair ever_approved last_body

  if [ "$FETCH_OK" -eq 0 ]; then echo "stale"; return; fi

  unresolved=$(printf '%s' "$ALL_THREADS" | jq -rs --arg login "$login" --arg login_bot "${login}[bot]" \
    '[.[].data.repository.pullRequest.reviewThreads.nodes[]
      | select(.comments.nodes[0].author.login == $login or .comments.nodes[0].author.login == $login_bot)
      | select(.isResolved == false and .isOutdated == false)] | length' 2>/dev/null || echo 0)
  if [ "$unresolved" -gt 0 ]; then echo "stale"; return; fi
  outdated=$(printf '%s' "$ALL_THREADS" | jq -rs --arg login "$login" --arg login_bot "${login}[bot]" \
    '[.[].data.repository.pullRequest.reviewThreads.nodes[]
      | select(.comments.nodes[0].author.login == $login or .comments.nodes[0].author.login == $login_bot)
      | select(.isOutdated == true)] | length' 2>/dev/null || echo 0)
  if [ "$outdated" -gt 0 ]; then echo "$HEAD_SHA"; return; fi

  commit_id=$(printf '%s' "$ALL_REVIEWS" | jq -rs --arg login "$login" --arg login_bot "${login}[bot]" \
    '[.[] | .[] | select(.user.login == $login or .user.login == $login_bot)] | last | .commit_id // empty' 2>/dev/null || echo "")
  if [ -n "$commit_id" ] && [ "${commit_id:0:8}" = "$HEAD_SHA" ]; then echo "${commit_id:0:8}"; return; fi

  body_sha=$(printf '%s' "$ALL_COMMENTS" | jq -r --arg login "$login" --arg login_bot "${login}[bot]" \
    '[.comments[] | select(.author.login == $login or .author.login == $login_bot)] | last | .body // empty' 2>/dev/null \
    | grep -oE 'commit/[a-f0-9]{7,40}' | sed 's|.*/||' | tail -1 | cut -c1-8)
  if [ -n "$body_sha" ] && [ "$body_sha" = "$HEAD_SHA" ]; then echo "$body_sha"; return; fi

  if [ -z "$commit_id" ] && [ -z "$body_sha" ]; then echo "none"; return; fi

  # Infra-error / rate-limit downgrade — see `inline_ack_for_bot` above for the
  # rationale, the `ever_approved` defense, and the FETCH_OK interaction.
  # Keep this block in lockstep with `ack_for_bot` (agents/pr-grinder.md) and
  # `inline_ack_for_bot` (above in this file).
  downgrade_pair=$(printf '%s' "$ALL_REVIEWS" | jq -rs --arg login "$login" --arg login_bot "${login}[bot]" \
    '[ .[] | .[] | select(.user.login == $login or .user.login == $login_bot) ]
     | [ (map(select(.state == "APPROVED" or .state == "DISMISSED")) | length),
         (last | .body // empty) ]' 2>/dev/null || echo '[0,""]')
  ever_approved=$(printf '%s' "$downgrade_pair" | jq -r '.[0]' 2>/dev/null || echo 0)
  if [ "$ever_approved" -eq 0 ]; then
    last_body=$(printf '%s' "$downgrade_pair" | jq -r '.[1]' 2>/dev/null || echo "")
    if printf '%s' "$last_body" | grep -qiE 'encountered an error|rate.?limit|unable to review|try again by re-requesting'; then
      echo "none"; return
    fi
  fi

  echo "stale"
}

FRESH_ACKS="greptile-apps=$(dispatcher_ack_for_bot greptile-apps),cubic-dev-ai=$(dispatcher_ack_for_bot cubic-dev-ai),coderabbitai=$(dispatcher_ack_for_bot coderabbitai),copilot-pull-request-reviewer=$(dispatcher_ack_for_bot copilot-pull-request-reviewer)"
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
| `--max N` | Maximum iterations | 5 |
| `--opus` | Run rounds inline in parent Opus context (no Sonnet dispatch) | Off (dispatches Sonnet subagent) |
| `--interactive` | Pause for human confirmation each round (forces inline; subagent can't pause) | Off (autonomous) |
| `--no-worktree` | Skip worktree creation, work in current directory | Off (creates worktree) |
| `--ci-only` | Only fix CI failures, ignore comments. Forces inline mode (Step 2 branching not yet wired into the subagent). | Off |
| `--no-merge` | Skip merge after grinding clean — just declare "Ready for merge" | Off (merges by default) |
| `--comments-only` | Only address comments, ignore CI. Forces inline mode (same reason as `--ci-only`). | Off |

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
