<!-- Extracted verbatim from SKILL.md. Read this file when the dispatcher loop
     exits with RESULT_STATUS=clean, or via the ADR 0012 max-wait downgrade
     path. It is the tail of SKILL.md and MUST be concatenated after it when
     asserting on document order (see tests/test-pr-grind-codex-wiring.sh). -->

## Completion (post-loop, dispatcher only)

**All of these must be true before declaring done:**
1. Subagent returned `RESULT_STATUS=clean`
2. All required CI checks passing (build, lint, test)
3. All automated reviewers completed (Kody — compulsory, ADR 0058: Kody counts as completed when Tier K acked HEAD, or when its run on HEAD was skipped because the Cursor-bot author has no Kodus seat AND the ADR 0064 waiver step printed `waived` (documentation-only PR). The waiver is not a review.) Codex (`chatgpt-codex-connector`) has no GitHub check, but it IS waited on via `ack-ledger.sh`: it acks the current HEAD via a fresh 👍 reaction (Tier F), a clean-verdict issue comment naming HEAD (Tier G, #690; also the review-summary comment whose state line names HEAD as completed with no unresolved findings, #992), or a resolved-and-current-head inline thread (Tier A). Unresolved or outdated Codex threads, and COMMENTED `/reviews` findings, are NOT acks — they are blockers that must be triaged (Step 2.6 enumeration) and either fixed or resolved on the current head before Codex can ack. Whichever tier decides, the result is surfaced as `RESULT_CODEX_ACK` and re-checked in the COMPLETION gate's `FRESH_ACKS` scan; a `stale` Codex blocks completion just like a stale registered bot.
4. No unresolved actionable comments from any source
5. No new comments arrived after your last push (wait for the full cycle)
6. Advisory check issues either fixed or noted as beyond PR scope
7. **Reviewer ack ledger**: every registered bot (`kody-ai`) is `<HEAD-short-SHA>` in `RESULT_REVIEWER_ACKS` — or, for `kody-ai` only, the ADR 0064 waiver token `skipped-unlicensed` (a waiver, not an ack); any other `kody-ai` value blocks (`kody-ai` never reads `none`; a `kody-ai=none` blocks like `stale` — ADR 0058). `skipped-unlicensed` only lets completion reach the waiver step; without `waived` it blocks. Any `stale` entry blocks completion — the bot finished its check but hasn't re-reviewed HEAD yet, and merging now would race ahead of its findings. (`none` here can mean "bot doesn't operate on this repo" OR "bot's only reviews are infra-error/rate-limit markers that cannot self-recover" OR "bot only posted a non-actionable PR-overview summary on an older commit" — all three cases are non-gating for logins other than `kody-ai`, which Tier K answers before any of them; see `scripts/ack-ledger.sh`'s downgrade Cases 1 and 2. Note: Tier E (commit-statuses API, no login mapped today — #985) does NOT produce `none` — a `success` status returns HEAD-ack, and a `pending`/`failure`/`error` status returns `stale` to block on the live reviewer signal.) Codex is gated too, but tracked in its own `RESULT_CODEX_ACK` field (Tier F 👍 reaction, or the Tier G clean-verdict comment — #690), not in `RESULT_REVIEWER_ACKS` — a `stale` Codex blocks completion identically; `none` (never reacted/reviewed on this PR) is non-gating.

**Re-query the ack ledger fresh (REQUIRED — defense in depth against late posts between subagent return and merge time):**

The dispatcher must re-run the same `scripts/ack-ledger.sh` lookup the worker used in Step 6.5, against all live ack-ledger sources (review threads, `/reviews`, issue comments, check-runs, and commit statuses), with HEAD recomputed against the current branch state. Just re-parsing `$RESULT_REVIEWER_ACKS` would only validate the worker's snapshot — it can't catch a bot that finished re-reviewing in the seconds between subagent return and merge.

The `<PR_NUMBER>`, `<owner>`, `<repo>` placeholders below follow the same template-substitution convention as `<PR_NUMBER>` elsewhere in this Completion section — Claude substitutes the literal owner / repo / PR-number values at run time before executing the bash. `<DOWNGRADED_BOTS>` follows the same convention: if COMPLETION was reached via the ADR 0012 wait-round downgrade path (ON_LOOP_EXHAUSTED step 5), Claude substitutes the comma-separated released-login list computed there; on the normal `RESULT_STATUS=clean` path (no downgrade involved) it substitutes the empty string. `<WORKTREE_DIR>` is the literal Step 0 worktree path (the checkout itself with `NO_WORKTREE=1`); the script runs from there, so HEAD and the main-repo root never come from a drifted CWD.

The re-query lives in `scripts/completion-ack-requery.sh` (#1078: inline, its `case` patterns made the helper guard refuse it). Run it as its own Bash call with a timeout of at least 600000 ms — Codex's first-engagement grace can poll for 480 s. Exit 0: every gated ack is fresh; its last line, `HEAD_FULL_SHA=<40 hex>`, is the classification SHA — remember it as `REVIEWED_HEAD` — and carry its `ADR 0064:` line, if printed, to the waiver step. Exit 1: it printed `❌ BLOCKED` with the stale reviewer(s), or with the `gh` error when the worktree's repository could not be looked up — re-run the loop. Exit 2: bad arguments — fix the substitution and re-run; never treat it as clean.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/completion-ack-requery.sh" <PR_NUMBER> "<owner>" "<repo>" "<WORKTREE_DIR>" "<DOWNGRADED_BOTS>"
```

**ADR 0064 waiver step (only when the fence above printed its `ADR 0064:` line; its own Bash call, timeout 1800000 ms):**

Kody's run on HEAD was skipped because the Cursor-bot author has no Kodus seat. `scripts/kody-waiver.py` grants the waiver only for a documentation-only PR (every changed path a plain `.md` file under `docs/` or an allowlisted root file such as `README.md`, none of it agent config) and records it, in the same process, as one `kody-unlicensed-skip-waived` event in the main checkout's `.claude/bypass-log.jsonl`. Remember whether the fence printed that line (`KODY_WAIVER_REQUIRED`) and whether this step granted the waiver (`WAIVER_GRANTED`); both marker blocks below read them. `<WORKTREE_DIR>` is the literal path resolved in Step 0 (the checkout itself with `NO_WORKTREE=1`); substitute the placeholders exactly as for the needs-shipping call.
```bash
cd "<WORKTREE_DIR>" && /usr/bin/python3 -I "${CLAUDE_PLUGIN_ROOT}/scripts/kody-waiver.py" "<owner>/<repo>" <PR_NUMBER> <full 40-char HEAD_FULL_SHA from the classification block>
```
Branch on **stdout and exit code together**:
- **exit 0, stdout exactly `waived`:** print `ℹ️  kody-ai: Kody did NOT review HEAD; documentation-only Cursor-bot PR; ADR 0064 licensing waiver applied (a waiver, not an ack).` and continue with `WAIVER_GRANTED=1`.
- **exit 10** (`not-docs-only` or `incomplete`): run the Shipping block below, which removes both markers on every root, then BAIL with `RESULT_BAIL_CATEGORY=policy`, quoting the token: "Kody must review this PR; the merge decision is the operator's." Do not tell anyone to merge.
- **anything else** (exit 1 `error: <reason>`, any other code, or stdout that does not match): run the same Shipping block, then BAIL with `RESULT_BAIL_CATEGORY=env`, surfacing the line as data. Never paste it into a shell line.

Never write a clean marker, merge, or re-wait after a non-zero exit. The marker removal covers a marker an earlier `--no-merge` run left for the same PR and HEAD, which would otherwise let the pre-merge gate authorize a later merge.

**Verify checks are green (REQUIRED — do NOT skip, even if subagent said clean):**
```bash
GH_EXIT=0
CHECKS_RAW=$(gh pr checks <PR_NUMBER> 2>&1) || GH_EXIT=$?
# A genuine `gh pr checks` row carries a KNOWN status token (pass/fail/pending/...)
# as its OWN tab-separated column, never as a loose substring. A CLI error line
# like "failed to connect to api.github.com" contains "fail" but is not a status
# column — a plain `grep -qE "pass|fail|pending"` misclassifies that error text
# as valid check output (Codex finding on #522), masking a real `gh` failure.
if [ "$GH_EXIT" -ne 0 ] && ! printf '%s\n' "$CHECKS_RAW" | awk -F'\t' 'NF>=2 { s=tolower($2); gsub(/^[ \t]+|[ \t]+$/,"",s); if (s ~ /^(pass|fail|failure|pending|queued|in_progress|expected|cancel|cancelled|skipping|neutral)$/) f=1 } END{exit !f}'; then
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

**Shipping routing (REQUIRED on every clean completion, `--no-merge` included; run BEFORE the marker write, as its own Bash call):**

ADR 0054, amended by ADR 0055. A repo opts into Cursor Cloud Shipping by carrying a `.cursor/skills/verify-*/` directory in the tree of its base branch's live tip. In an opted-in repo, a PR that touches anything outside the built-in skip list (docs, root `*.md`, tests; agent-config paths such as `.cursor/`, `.claude/`, `.codex/`, `.agents/`, `AGENTS.md`, `CLAUDE.md`, `CLAUDE.local.md` and `.mcp.json` are never skipped, and neither is a file those agent-config files import with `@path` (#936); a JSON, JSONC, TOML or YAML file in an agent directory or any `.mcp.json` (`.cursor/environment.json` exempt), a `hooks`, `mcpServers`, `lspServers`, `monitors` or `settings` key or unreadable frontmatter in agent Markdown, a `!` command in a skill or command body, or a `!` or backtick in a skill or command path, makes every path agent config (#950)) is landed by Shipping, not by pr-grind. Repos that have not opted in, busdriver included, get `merge` and continue exactly as before. Run at the AMBIENT session cwd, with no `cd`. Pass `<REVIEWED_HEAD>` inline as the third argument, the same 40-char HEAD_FULL_SHA the marker block below uses. The classifier compares it to the PR's live head, so a short or wrong SHA exits 1. Run it with a Bash timeout of 1800000 ms: its import walk can take up to 600s, about 1560s in all (#936).
```bash
/usr/bin/python3 -I "${CLAUDE_PLUGIN_ROOT}/scripts/needs-shipping.py" "<owner>/<repo>" <PR_NUMBER> <full 40-char HEAD_FULL_SHA from the classification block>
```
Branch on **stdout and exit code together**. Exit 10 is an expected outcome, not an error:
- **stdout `merge`, exit 0:** continue to the marker write below and then the default-merge or `--no-merge` path, unchanged.
- **stdout `shipping mergeStateStatus=<S> base_ref=<name> base_tip=<40-hex> skills=<a,b|-> agent_config_edited=<0|1> files_incomplete=<0|1> author=<login|-> cross_repo=<0|1>`, exit 10** (exactly these eight fields, in this order, on one line): run the Shipping block below as its own Bash call, then the Shipping kick below, print the completion output with the Ready-for-Shipping line, and **stop**. Do NOT write or copy the clean marker, and do NOT run Branch-Currency Detection, Approver-Gap Detection, any merge block, or the `--no-merge` block. `--no-merge` does not override this; it only skips the kick.
- **anything else** (any other exit code, a missing interpreter, or stdout that does not match the exit code): run the Shipping block below to remove any marker, then BAIL with `RESULT_BAIL_CATEGORY=env` and surface the classifier's `error:` line. Never merge.

**Shipping block: remove both markers and clean up the worktree.** This is NOT the `--no-merge` block, which writes and copies the marker; never use that block as a template here. A non-zero exit from this block is handled as the catch-all BAIL `env`.
```bash
NO_WORKTREE=<0|1 — see "Resolve flag-to-state translations" in START>
# NO `cd` above this line: the session cwd is the root the marker block and the gate use.
# Try EVERY root even when one fails, and report failure only at the end, so a
# failure on one root never leaves another root's marker standing.
CLEAN_FAIL=0
ROOTS=()
REPO_ROOT=$(git rev-parse --show-toplevel) && [ -n "$REPO_ROOT" ] && ROOTS+=("$REPO_ROOT") || CLEAN_FAIL=1
if [ "$NO_WORKTREE" != "1" ]; then
  # An earlier --no-merge run may have copied a marker into the original worktree.
  ORIG_ROOT=$(git -C <original-worktree-path> rev-parse --show-toplevel) && [ -n "$ORIG_ROOT" ] && ROOTS+=("$ORIG_ROOT") || CLEAN_FAIL=1
fi
for R in "${ROOTS[@]}"; do
  rm -f "$R/.claude/pr-grind-clean.local" "$R/.claude/pr-pending-grind.local" || CLEAN_FAIL=1
  [ ! -e "$R/.claude/pr-grind-clean.local" ] || CLEAN_FAIL=1
done
[ "$CLEAN_FAIL" = 0 ] || exit 1
if [ "$NO_WORKTREE" != "1" ]; then
  cd <original-worktree-path>
  git worktree remove "../pr-grind-<PR_NUMBER>" --force 2>/dev/null || true
fi
```
This path does not prune the per-PR Codex retrigger markers: the PR is not merged, so they are left as after any other unmerged completion.

**Shipping kick (exit 10 only, after the Shipping block; ADR 0055):**
- **With `--no-merge`:** do not run the kicker; a kick authorizes a merge. The Ready line reports `auto-kick skipped: --no-merge; the operator may kick Shipping by hand`. Stop.
- **Otherwise** run the kicker as its own Bash call at the AMBIENT session cwd, with the same `<REVIEWED_HEAD>` routing used. It runs the classifier itself and applies every other gate. Run it with a Bash timeout of 3300000 ms: its worst case is about 3050s (#936). An interrupted kick can still have posted; a re-run dedupes on the head marker.
```bash
/usr/bin/python3 -I "${CLAUDE_PLUGIN_ROOT}/scripts/shipping-kick.py" "<owner>/<repo>" <PR_NUMBER> <full 40-char HEAD_FULL_SHA from the classification block>
```
It prints exactly one line and never the comment body. Report that line verbatim in the Ready line, then print exactly ONE follow-up, chosen by exit code and line prefix:

| Exit | Line starts with | Follow-up |
|---|---|---|
| 0 | `kicked:` | none |
| 1 | `error:` | none; the line says what to do |
| 2 | `not kicked: mergeStateStatus=BEHIND` | `the cloud agent cannot update a branch (#986): run gh pr update-branch <PR_NUMBER> -R <owner>/<repo> yourself, comment @kody review --force on the PR (Kody skips a merge-only head), then re-run /pr-grind on the new head`; when the line ends `; also: agent-config`, print the operator-only D4 escape below, with its BEHIND step, instead of the re-run (step 5 refuses BEHIND before step 8 can name it) |
| 2 | `not kicked: mergeStateStatus=` (any other) | `fix that (conflict, draft, failing check or uncomputed status), then re-run /pr-grind to evaluate the remaining gates` |
| 2 | `not kicked: protection precondition` | `fix that, then re-run /pr-grind` |
| 3 | `not eligible:` naming `author` or `cross-repo` | `security refusal: review this PR yourself before landing it by any route` |
| 3 | `not eligible:` naming only `files-incomplete` and/or `agent-config` | the operator-only D4 escape below |
| 4 | `already kicked:` | `to retry this head, delete that comment, then re-run /pr-grind` |
| 5 | `not kicked: no usable verify skill name` | `fix that, then re-run /pr-grind` |
| 6 | `stale or not shipping-routed` | none |
| 7 | `post failed:` | none |
| anything else | | none; report the line |

Whenever the line contains `agent-config` (the token or the `; also: agent-config` suffix), also print `this PR edits agent configuration: review it before landing it by any route`.

**Shipping merge watch (kicker exit 0 `kicked:` or exit 4 `already kicked:` only).** Shipping merges the PR from the cloud, so nothing in the session learns about it and the operator's branch and worktree go stale. After printing the Ready line, start the watcher with the Bash tool's `run_in_background`, at the AMBIENT session cwd. Do not wait on it; the session gets one notification when it exits.
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/shipping-merge-watch.sh" "<owner>/<repo>" <PR_NUMBER>
```
It polls every 60s for up to 90 min (measured kick-to-merge: 6.9-12.5 min across 15 PRs, with one 54 min outlier) and prints one line. When it exits:
- `merged <PR> <oid>`: tell the operator the PR merged, then offer cleanup and **never run it yourself**: deleting a worktree or branch is the operator's call. Build the commands with the script, never by hand: substitute nothing but the repo and PR number, because a branch name can carry shell syntax. The script reads the branch names from GitHub, finds the worktree from `git worktree list`, and shell-quotes everything it prints. Run it at the AMBIENT session cwd:
  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/shipping-merge-watch.sh" --cleanup "<owner>/<repo>" <PR_NUMBER>
  ```
  Print its lines verbatim and ask whether to run them; they start with `!` so the operator can paste them. It offers anything only when the local branch tip is the PR head or behind it, which proves the branch belongs to this PR and holds no later work; otherwise it prints one `note:` line instead, which you report as is. When it does offer, it prints `worktree remove` for a linked worktree (which refuses a dirty tree), `switch <base>` when the branch is checked out in the main repo root, and `branch -D` (`-D` because a squash merge leaves the branch unmerged by ancestry; it is the same unguarded delete `gh pr merge --delete-branch` runs, so a commit made on the branch after the offer is lost with it, and git still refuses a branch any worktree has checked out). The steps are joined with `&&` on one line, so the branch is not deleted if the worktree step fails. A `warning:` line before `worktree remove` means the worktree holds ignored files (a `.env`, a `.claude/*.local` skip file) that the remove deletes; repeat it to the operator. No output means nothing is left to clean.
- `closed <PR>`: report that the PR was closed without merging. No cleanup offer.
- `behind <PR>`: the base moved after the kick and the cloud agent cannot update a branch (#986), so Shipping cannot land it (#1099). Print the follow-up from the kicker table's exit-2 `not kicked: mergeStateStatus=BEHIND` row: run `gh pr update-branch <PR_NUMBER> -R <owner>/<repo>`, comment `@kody review --force`, then re-run /pr-grind on the new head. No cleanup offer.
- `timeout <PR> ...`: report that Shipping had not merged it within 90 min and give the PR URL. No cleanup offer.
- anything else: report the line verbatim.

The watch dies with the session. A session that ends first gets no notice; the operator checks the PR by hand.

**Operator-only D4 escape** (printed for the operator; never run by pr-grind or the session). BEHIND is read from the kicker's line when it ends `mergeStateStatus=<S>`, optionally followed by `; also: agent-config`, otherwise from the classifier's exit-10 line:
```text
Operator only, in your own terminal, after reviewing the full change yourself:
  (only when BEHIND) gh pr update-branch <PR_NUMBER> -R <owner>/<repo>, then wait for the new head's required checks to pass
  touch <PROJECT_ROOT>/.claude/skip-pr-grind.local   (wait at least 30s before merging; it is valid for 3600s)
  gh pr merge <PR_NUMBER> -R <owner>/<repo> --squash --delete-branch --match-head-commit <the head you reviewed, or after update-branch the new head>
```
Exits 1-7 are expected outcomes, not errors: none is a BAIL, and no kicker exit leads to a `RESULT_BAIL_CATEGORY` or to `gh pr merge` run by pr-grind. If the Shipping block itself exits non-zero, BAIL `env` as the routing section says and do not run the kicker. The classifier's `mergeStateStatus` warnings are not printed.

<EXTREMELY-IMPORTANT>
**Only when Shipping routing exited 0 (stdout `merge`). On exit 10 or any routing failure, never write or copy the clean marker and never merge.**

**CRITICAL: the marker write and `gh pr merge` MUST be TWO SEPARATE Bash tool calls.** Not chained with `&&`/`;`/`|`, not a heredoc that runs both, not a single multi-line command, not a single Bash call that just happens to contain both lines. Two distinct tool calls — first call writes the marker and exits; second call invokes `gh pr merge`. This applies identically to the default-merge block AND the `--admin-on-approver-gap` auto-admin-merge block below — both consume the same marker; the gate fires on both invocation paths.

**Why a single call deadlocks.** `hooks/gate-scripts/pre-merge-gate.sh` is a PreToolUse hook — it fires BEFORE the bash command executes, scans the command argv string for `gh pr merge`, and reads `.claude/pr-grind-clean.local` from disk at that moment. If the marker `echo` lives in the same tool call, the hook samples the filesystem *before* the echo runs, finds no marker, and blocks the entire tool call — NONE of the bash executes, the marker is never written, and the operator sees a misleading "pr-grind has not declared this PR clean" error after pr-grind just finished successfully. This is a TOCTOU between the hook's filesystem read at tool-invocation time and the marker write at bash-execution time inside the same tool call. Splitting into two tool calls separates the two events: the first tool call completes (marker on disk, hook didn't fire), then the hook fires on the second call's `gh pr merge` and sees the marker the first call left behind.

**Confirmed recurrences:** PR #93 (2026-05-12) — the deadlock the PR-#94 callout was first written for. PR #95 (2026-05-13) — recurred *despite* the prior callout because the previous prose was easy to skim past on a top-down read. The "CRITICAL" headline above is the current attempt to make the contract unmissable; do not soften it back into a paragraph.

**The contract:** marker write completes → next Bash call runs the merge. Do NOT inline-combine, even if the chain "looks natural" while you're reading this section.
</EXTREMELY-IMPORTANT>

**Write the pr-grind-clean marker (REQUIRED — only when Shipping routing exited 0 (stdout `merge`); on exit 10 or any routing failure, never write or copy this marker). Run this as its own Bash tool call. ⚠ Unlike most other blocks in this completion specification, do NOT `cd "$WORKTREE_DIR"` first — run it at the AMBIENT session cwd.**

The pre-merge gate anchors its marker lookup (`REPO_DIR`) on the hook's `cwd` — the Claude **session's launch dir** — refining to a `cd` target only for a statically-parseable single-line `cd <path> && …` merge form (`hooks/gate-scripts/lib/resolve-repo-dir.sh`). The default merge below is a **bare** `gh pr merge`, so the gate anchors on the **session cwd**. That is exactly the directory the Bash tool lands in when a block does **not** `cd` (the "CWD Reset Across Bash Calls" invariant) — so `git rev-parse --show-toplevel` at the ambient cwd resolves to the very repo root the gate will read. This is the whole fix: writing the marker to any *other* root (the grind worktree, or the main-repo root) is what lets the two diverge. The bug it closes: if this block first `cd`s into a checkout that is NOT the session cwd — e.g. the grind resolved `WORKTREE_DIR` to a linked sibling worktree while you invoked `/pr-grind <PR>` from the main checkout — the marker lands in the worktree while the gate still reads the session cwd, and the merge blocks with "pr-grind has not declared this PR clean" right after a clean grind.
```bash
# NO `cd` above this line — the ambient cwd must stay the session cwd (= gate anchor).
# ADR 0064: a skipped-unlicensed Kody run needs the waiver step's `waived` (literal 0/1 only).
KODY_WAIVER_REQUIRED=<0|1: 1 if the first fence printed the ADR 0064 line>
WAIVER_GRANTED=<0|1: 1 only if the waiver step exited 0 AND its stdout was exactly `waived`>
[ "$KODY_WAIVER_REQUIRED" = 0 ] || [ "$WAIVER_GRANTED" = 1 ] \
  || { echo "❌ BLOCKED: ADR 0064 waiver not granted for this HEAD; no clean marker"; exit 1; }
REPO_ROOT=$(git rev-parse --show-toplevel)
mkdir -p "$REPO_ROOT/.claude"
# The marker asserts "<PR> AT THIS COMMIT is clean" — the SHA is load-bearing,
# not decoration (#505). It MUST be REVIEWED_HEAD (the same value already
# substituted into `--match-head-commit` below, #427): the commit the ack ledger
# actually classified against. Do NOT re-query `gh pr view --json headRefOid`
# here — that re-derives HEAD at marker-write time, so a push landing between
# classification and this line would stamp a NEW, UNREVIEWED commit as clean and
# the gate would then faithfully authorize it. Re-deriving launders exactly the
# commit #505 exists to catch. (`git rev-parse HEAD` is wrong for a second
# reason: this block runs at the ambient session cwd, routinely on another branch.)
REVIEWED_HEAD=<full 40-char SHA — the HEAD_FULL_SHA from the classification block>
if [ "${#REVIEWED_HEAD}" -ne 40 ]; then
  echo "ABORT: REVIEWED_HEAD is not a full 40-char SHA — marker NOT written. Do not merge; re-run /pr-grind." >&2
  exit 1
fi
printf '%s %s\n' "<PR_NUMBER>" "$REVIEWED_HEAD" > "$REPO_ROOT/.claude/pr-grind-clean.local"
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
                    # No force-push, so no SHA is *rewritten* — but HEAD MOVES
                    # to the merge commit, so every HEAD-pinned ack strands on
                    # the parent until its bot re-reviews the new HEAD. Triggers
                    # a CI re-run + bot re-review; plan for 1-2 additional
                    # wait-rounds. Cleanest correctness path when bots re-review
                    # merge commits.
                    # Kody (ADR 0058) skips a merge commit with no effective
                    # changes, and Tier K refuses a skip, so kody-ai stays
                    # `stale` on the merge HEAD. After update-branch, comment
                    # `@kody review --force` on the PR (a plain
                    # `@kody start-review` skips again), then re-run pr-grind.
                    # kody-ai is NOT eligible for the ADR 0012 stale→none
                    # downgrade (compulsory), so without the comment the grind
                    # bails at --max-wait.
                    # devin-ai-integration stays DROPPED from the ack registry
                    # (ADR 0035) — a review-once-at-create bot whose stranded clean
                    # reviews needed the Case-4 whitelist (ADR 0027, now removed).
                    # cursor (Bugbot) is DROPPED again (ADR 0047 / ADR 0035):
                    # dashboard-disabled and ungated; stranded-clean Case 4 stays deleted.
                    # [update-rebase] avoids the merge-commit skip (Kody
                    # reviews the rebased HEAD on push) at the cost of 3-5
                    # wait-rounds.
  [update-rebase] gh pr update-branch <PR_NUMBER> --rebase
                    # rebases PR onto base. Force-push, rewrites published
                    # SHAs, invalidates ack-ledger entries (all bots stale).
                    # Triggers full re-review cycle. Cleaner history but
                    # reignites grind — 3-5 rounds likely. Pick when bot
                    # configurations dislike merge commits OR when the PR
                    # history matters for downstream reviewers.
  [admin]         gh pr merge <PR_NUMBER> --squash --delete-branch --admin --match-head-commit <REVIEWED_HEAD>
                    # head guard (#427). <REVIEWED_HEAD> is substituted by the
                    # dispatcher — same convention as <PR_NUMBER> — with the
                    # classified HEAD_FULL_SHA. Do NOT emit $(git rev-parse HEAD):
                    # that re-derives at merge time and blesses a post-
                    # classification commit, defeating the guard.
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
                    # No force-push, so no SHA is *rewritten* — but HEAD MOVES
                    # to the merge commit, so every HEAD-pinned ack strands on
                    # the parent until its bot re-reviews the new HEAD. Triggers
                    # a CI re-run + bot re-review; plan for 1-2 additional
                    # wait-rounds. Cleanest correctness path when bots re-review
                    # merge commits.
                    # Kody (ADR 0058) skips a merge commit with no effective
                    # changes, and Tier K refuses a skip, so kody-ai stays
                    # `stale` on the merge HEAD. After update-branch, comment
                    # `@kody review --force` on the PR (a plain
                    # `@kody start-review` skips again), then re-run pr-grind.
                    # kody-ai is NOT eligible for the ADR 0012 stale→none
                    # downgrade (compulsory), so without the comment the grind
                    # bails at --max-wait.
                    # devin-ai-integration stays DROPPED from the ack registry
                    # (ADR 0035) — a review-once-at-create bot whose stranded clean
                    # reviews needed the Case-4 whitelist (ADR 0027, now removed).
                    # cursor (Bugbot) is DROPPED again (ADR 0047 / ADR 0035):
                    # dashboard-disabled and ungated; stranded-clean Case 4 stays deleted.
                    # [update-rebase] avoids the merge-commit skip (Kody
                    # reviews the rebased HEAD on push) at the cost of 3-5
                    # wait-rounds.
  [update-rebase] gh pr update-branch <PR_NUMBER> --rebase
                    # rebases PR onto base. Force-push, rewrites published
                    # SHAs, invalidates ack-ledger entries (all bots stale).
                    # Triggers full re-review cycle. Cleaner history but
                    # reignites grind — 3-5 rounds likely. Pick when bot
                    # configurations dislike merge commits OR when the PR
                    # history matters for downstream reviewers.
  [wait]          exit; manually update later
  [admin]         gh pr merge <PR_NUMBER> --squash --delete-branch --admin --match-head-commit <REVIEWED_HEAD>
                    # head guard (#427). <REVIEWED_HEAD> is substituted by the
                    # dispatcher — same convention as <PR_NUMBER> — with the
                    # classified HEAD_FULL_SHA. Do NOT emit $(git rev-parse HEAD):
                    # that re-derives at merge time and blesses a post-
                    # classification commit, defeating the guard.
                    (no audit trail — proceed only with explicit operator authorization)
                    # verify: gh pr view <PR_NUMBER> --json state -q .state
                    # (retry up to 3x with 2s backoff — trust the API state,
                    #  not the merge exit code)
```

After the operator picks `[update-merge]` or `[update-rebase]`, pr-grind should be re-invoked on the same PR — the new HEAD will trigger fresh bot reviews and (probably) a short wait-round sequence to convergence. After `[update-merge]`, comment `@kody review --force` first: Kody skips a merge-only HEAD, and `kody-ai` stays `stale` until it reviews it (ADR 0058). After `[admin]`, the PR is merged; pr-grind exits clean.

**Approver-Gap Detection (run BEFORE the merge attempt):**

After CI is green, threads are resolved, and bot acks are HEAD, GitHub may still reject the merge because branch protection demands `required_approving_review_count >= 1` human APPROVED reviews the author cannot self-provide. The dispatcher detects this structural gap up front so the operator sees a tailored decision message instead of a raw `gh pr merge` failure.

**The detection is scoped narrowly:** only the `required_approving_review_count` axis qualifies, and only when CI is green AND every required status check has passed. Other branch-protection failures (failing required checks, missing required signatures, etc.) are NOT approver-gap bails — they surface via their existing paths.

The detection algorithm lives at `scripts/approver-gap-detect.sh` (single source of truth, same factoring pattern as `scripts/ack-ledger.sh`). Its inputs are composed from `gh api` by `scripts/approver-gap-compose.sh`: branch rules, classic protection (the PARENT `/protection` endpoint), reviews, the author's permission, the `bypass-audit.yml` probe and the solo-admin opt-in with its Step 0 snapshot check. Read that script for the input contract and the fail-CLOSED rules (it is a script because inline its `case` patterns made the helper guard refuse it — #1078). Run this as one Bash call and switch on the printed `GAP_DECISION`; `<ADMIN_FLAG_PASSED>` is the literal 0 or 1 from START. Any composer failure reads as `surface-decision`, never as an authorization:

```bash
GAP_DECISION_JSON=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/approver-gap-compose.sh" <PR_NUMBER> "<owner>" "<repo>" "<WORKTREE_DIR>" <ADMIN_FLAG_PASSED>) \
  && [ -n "$GAP_DECISION_JSON" ] \
  || GAP_DECISION_JSON='{"decision":"surface-decision","trigger":"none","reason":"approver-gap composer failed; require operator decision"}'
printf 'GAP_DECISION=%s\n' "$(printf '%s' "$GAP_DECISION_JSON" | jq -r '.decision' 2>/dev/null || echo surface-decision)"
printf '%s\n' "$GAP_DECISION_JSON"
```

**Decision tree** (based on `GAP_DECISION`):

- **`no-gap`** → fall through to the normal `gh pr merge` path below.
- **`surface-decision`** → BAIL with `RESULT_BAIL_CATEGORY=policy` and surface the operator-decision message (template below). Excluded from MAX_FIX/MAX_WAIT accounting. The `audit_workflow_present` field in the JSON controls whether `[admin]` appears as the first/default option.
- **`auto-admin-merge`** → run the auto-admin merge block below: it re-derives the decision, logs to `.claude/bypass-log.jsonl`, and runs `gh pr merge <PR> --squash --delete-branch --admin`. Two triggers can reach this decision: `trigger=flag` (operator passed `--admin-on-approver-gap` per-invocation) or `trigger=solo-admin-auto` (operator placed `.claude/pr-grind-auto-admin-solo.local` AND remains the sole human admin — see the solo-admin auto-detect in `scripts/approver-gap-compose.sh`). Both require the baseline gates: CI/bots clean (asserted by caller) AND author has admin/maintain AND `bypass-audit.yml` exists. Fail-CLOSED on any missing condition. `scripts/approver-gap-admin.sh` selects the bypass-log `event` value from the trigger so explicit vs. structural bypasses are distinguishable in forensics.

**Auto-admin merge** (decision `auto-admin-merge` only; ONE Bash call). `scripts/approver-gap-admin.sh authorize` re-runs the composer in its own process, so the merge never acts on a decision carried over from another Bash call. It refuses unless the decision is `auto-admin-merge` with trigger `flag` or `solo-admin-auto`, then appends the bypass-log entry (append-only JSONL, gitignored under `.claude/`; its fields are in the script). Only its exit 0 lets the typed merge run. Like the marker write and the default merge, this block runs at the AMBIENT session cwd with no `cd`: the pre-merge gate reads the clean marker from there, and `settle` invalidates or drains it at that same root. Only the composer, the audit entry's HEAD and the codex-retrigger GC use `<WORKTREE_DIR>`, and the bypass log goes to the main repo's `.claude/`. `settle` then confirms `MERGED` through `gh pr view` (three tries — `--delete-branch` can fail locally after the remote merge landed): on success it drains the spent clean marker and GCs the codex-retrigger markers; otherwise it removes the clean marker so a later plain `gh pr merge` cannot ride it, and exits 1.

`--match-head-commit` closes the check-then-merge race (#427): GitHub refuses the merge unless the PR head still equals the SHA every ack/CI classification was made against. `<REVIEWED_HEAD>` is that literal 40-char SHA — the `HEAD_FULL_SHA=` line the ack re-query printed. Never substitute `$(git rev-parse HEAD)` or the 8-char display form: re-deriving HEAD here blesses whatever local HEAD is at merge time, including a commit that landed after classification.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/approver-gap-admin.sh" authorize <PR_NUMBER> "<owner>" "<repo>" "<WORKTREE_DIR>" <ADMIN_FLAG_PASSED> \
  && { gh pr merge <PR_NUMBER> --squash --delete-branch --admin --match-head-commit <REVIEWED_HEAD> || true; \
       bash "${CLAUDE_PLUGIN_ROOT}/scripts/approver-gap-admin.sh" settle <PR_NUMBER> "<WORKTREE_DIR>"; }
```

If `authorize` exits non-zero, nothing merged and nothing else runs from this context: no fallback merge, no `settle`, no operator-decision message. A refusal can mean this cwd is not the authorized repository, or that the gap decision changed since detection, so anything built on this call's earlier state may be wrong. BAIL `RESULT_BAIL_CATEGORY=env`, quoting `authorize`'s reason, and tell the operator to re-run `/pr-grind <PR_NUMBER>` with the same flags: a fresh run re-detects the gap and takes `no-gap`, `surface-decision` or `auto-admin-merge` from current state. The clean marker stays. It names this PR and its reviewed head, and the pre-merge gate deletes it once the head moves.

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
  [admin]        gh pr merge <PR_NUMBER> --squash --delete-branch --admin --match-head-commit <REVIEWED_HEAD>
                   # head guard (#427). <REVIEWED_HEAD> is substituted by the
                   # dispatcher — same convention as <PR_NUMBER> — with the
                   # classified HEAD_FULL_SHA. Do NOT emit $(git rev-parse HEAD):
                   # that re-derives at merge time and blesses a post-
                   # classification commit, defeating the guard.
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
  [admin]        gh pr merge <PR_NUMBER> --squash --delete-branch --admin --match-head-commit <REVIEWED_HEAD>
                   # head guard (#427). <REVIEWED_HEAD> is substituted by the
                   # dispatcher — same convention as <PR_NUMBER> — with the
                   # classified HEAD_FULL_SHA. Do NOT emit $(git rev-parse HEAD):
                   # that re-derives at merge time and blesses a post-
                   # classification commit, defeating the guard.
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
# --match-head-commit closes the check-then-merge race (#427). REVIEWED_HEAD is
# template-substituted with the literal 40-char HEAD_FULL_SHA from the
# classification block — NOT re-derived here; see the auto-admin block above for
# why re-deriving at merge time defeats the guard.
REVIEWED_HEAD=<full 40-char SHA — the HEAD_FULL_SHA from the classification block>
gh pr merge <PR_NUMBER> --squash --delete-branch --match-head-commit "$REVIEWED_HEAD" || true
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
  # Invalidate the clean marker (#427 P1 gap, PR #429 review). --match-head-commit
  # correctly rejected because HEAD moved after classification, but a stale
  # pr-grind-clean.local left on disk would let a subsequent PLAIN `gh pr merge`
  # (no head guard) sail through pre-merge-gate.sh, which only re-checks CI on a
  # fresh same-PR marker — silently merging the newly pushed, unclassified head.
  # Remove it so any retry is forced back through a full grind round.
  MARKER_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  [ -n "$MARKER_REPO_ROOT" ] && rm -f "$MARKER_REPO_ROOT/.claude/pr-grind-clean.local"
  exit 1
fi
# Consume the clean marker this merge spent (#842): GitHub reports MERGED, so the one
# merge it authorized has landed. Through the audited drain (a skip-marker-cleared
# event), at the ambient root the marker was written to, and only while it names THIS
# PR — another PR's marker is not this merge's to spend. Best-effort: a marker left
# behind is bound to a merged PR and its head (#505), so it authorizes nothing else.
MARKER_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
MARKER_PR=""
[ -n "$MARKER_REPO_ROOT" ] && read -r MARKER_PR _ 2>/dev/null <"$MARKER_REPO_ROOT/.claude/pr-grind-clean.local" || true
if [ "$MARKER_PR" = "<PR_NUMBER>" ]; then
  ( cd "$MARKER_REPO_ROOT" && bash "${CLAUDE_PLUGIN_ROOT}/scripts/design-clear.sh" --skip pr-grind-clean.local --yes >/dev/null ) \
    || echo "⚠️  could not drain the spent clean marker; run: design-clear.sh --skip pr-grind-clean.local"
fi
# GC the merged PR's codex-retrigger idempotency markers (#327), from $WORKTREE_DIR
# (the CWD codex-retrigger wrote them relative to) BEFORE any worktree removal below,
# so a skipped/failed removal never leaks them. Best-effort. NOTE: this block uses the
# <PR_NUMBER> template literal (Claude substitutes it), NOT the $PR shell var.
( cd "$WORKTREE_DIR" || exit 0; bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-retrigger-gc.sh" "<PR_NUMBER>" ) || true
# Only return to a separate worktree and remove the ephemeral one if Step 0
# actually created it. With --no-worktree we ran in-place — there is no
# separate worktree to leave or remove.
if [ "$NO_WORKTREE" != "1" ]; then
  cd <original-worktree-path>
  git worktree remove "../pr-grind-<PR_NUMBER>" --force 2>/dev/null || true
fi
```

**If `--no-merge` (only when Shipping routing exited 0 (stdout `merge`); on exit 10 or any routing failure, never write or copy this marker): write marker to the repo root of the worktree the user will merge from, clean up, report ready (also `--no-worktree`-aware):**
```bash
# ADR 0064: a skipped-unlicensed Kody run needs the waiver step's `waived` (literal 0/1 only).
KODY_WAIVER_REQUIRED=<0|1: 1 if the first fence printed the ADR 0064 line>
WAIVER_GRANTED=<0|1: 1 only if the waiver step exited 0 AND its stdout was exactly `waived`>
[ "$KODY_WAIVER_REQUIRED" = 0 ] || [ "$WAIVER_GRANTED" = 1 ] \
  || { echo "❌ BLOCKED: ADR 0064 waiver not granted for this HEAD; no clean marker"; exit 1; }
# NO_WORKTREE template-substituted same as Default-merge block above —
# `${NO_WORKTREE:-0}` would silently default to 0 across Bash tool calls
# and the wrong cleanup branch would fire.
NO_WORKTREE=<0|1 — see "Resolve flag-to-state translations" in START>
# When --no-worktree, the dispatcher already runs in the user's worktree, so
# the marker target is the same repo root we're in — no cross-worktree copy.
if [ "$NO_WORKTREE" = "1" ]; then
  REPO_ROOT=$(git rev-parse --show-toplevel)
  mkdir -p "$REPO_ROOT/.claude"
  # Same `<PR> <REVIEWED_HEAD>` contract as the marker-write block above (#505): the
  # CLASSIFIED head (REVIEWED_HEAD), never a fresh headRefOid query.
  REVIEWED_HEAD=<full 40-char SHA — the HEAD_FULL_SHA from the classification block>
  if [ "${#REVIEWED_HEAD}" -ne 40 ]; then
    echo "ABORT: REVIEWED_HEAD is not a full 40-char SHA — marker NOT written. Do not merge; re-run /pr-grind." >&2
    exit 1
  fi
  printf '%s %s\n' "<PR_NUMBER>" "$REVIEWED_HEAD" > "$REPO_ROOT/.claude/pr-grind-clean.local"
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
- Model: opus
- CI: all required checks passing
- Automated reviewers: all completed, no actionable findings (only if the ADR 0064 waiver step printed its notice, write instead: "Kody did NOT review — ADR 0064 waiver (documentation-only Cursor-bot PR); other reviewers completed, no actionable findings")
- Advisory checks: [fixed | N failing — noted as beyond PR scope]
- Human comments: all addressed
- Worktree cleaned up.
```

**Default:** append `- Merged.`

**With `--no-merge`:** append `- Ready for merge.`

**With Shipping routing (exit 10), on any invocation (default or `--no-merge`):** this supersedes the Default and `--no-merge` lines above, so append neither `- Merged.` nor `- Ready for merge.`. Instead append:
- `- Ready for Shipping: this repo opted in (base tip has .cursor/skills/verify-*). Busdriver did not merge and wrote no clean marker. Kick: <the kicker's line, or "auto-kick skipped: --no-merge; the operator may kick Shipping by hand">`
- Then the follow-up chosen in "Shipping kick" above, if any.

