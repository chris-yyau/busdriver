# Issue #890: dispatcher-commit-block explicit push destination

**Status:** Draft
**Author:** agent bd-890-cursor
**Date:** 2026-10-01

## Problem

`dispatcher-commit-block.sh` Step 11 (line ~1248) uses a bare `git push` to push the fix-round commit. This fails on pr-grind worktrees where the branch was materialized without upstream tracking under usual `push.default=simple`/`upstream` and `push.autoSetupRemote` unset:

```bash
git push
# → fatal: The current branch <name> has no upstream branch.
#   To push the current branch and set the upstream, use
#       git push --set-upstream origin <branch>
```

Common examples of that shape:
- Dependabot PRs (branch created server-side, materialized locally via fetch-refspec)
- PRs opened from another machine/person (never checked out locally with `git push -u`)

**Root cause chain:**
1. pr-grind Step 0 materializes the PR branch with `git fetch origin "refs/heads/<branch>:refs/heads/<branch>"` (no upstream)
2. `resolve-pr-worktree.sh:153` creates the ephemeral worktree on that branch
3. `dispatcher-commit-block.sh:1248` does `git push` with no destination, which requires an upstream under simple/upstream defaults

**Secondary issues from the same path:**
- The bail category is `judgment`, but missing upstream is an `env`/config fault (fixed by updated bail classification)
- The commit is already made when push fails, so the fix round leaves an unpushed local commit on the shared branch ref

**Note on unpushed commit recovery:** Out of scope for automation. After any Step 11 bail (env or judgment), the fix commit remains on the local branch; pr-grind removes the ephemeral worktree (SKILL.md:92). The next grind's Step 0 non-forced fetch does not rewind a local-ahead branch, and `resolve-pr-worktree.sh:214-215` then stops because local SHA ≠ `headRefOid`. Operator must push that commit or reset onto the PR head before re-grind. For history refusals specifically, local and remote have **diverged**; rebase only unpublished fix commits onto the fetched remote tip.

## Proposed Solution

Push to an explicit destination using a full branch ref pinned early in the fix-round path, and push the SHA Step 10a already verified.

**Normative implementation (single source of truth):**

```bash
# --- Immediately after fix-round routing esac (~line 445), BEFORE Litmus init ---
# Fail closed before Litmus / review-lock mutation on detached or non-branch HEAD.
full_ref=$(git symbolic-ref -q HEAD) || \
    emit_bail "env" "dispatcher-commit-block: not on a branch (detached HEAD)"

case "$full_ref" in
    refs/heads/*) ;;
    *) emit_bail "env" "dispatcher-commit-block: ref '$full_ref' is not a branch" ;;
esac

git check-ref-format "$full_ref" || \
    emit_bail "env" "dispatcher-commit-block: ref '$full_ref' invalid"

# ... Litmus, Steps 1–10a: stage, commit, capture NEW_COMMIT_SHA, verify object ...

# --- Step 11: Checked push ---
current_ref=$(git symbolic-ref -q HEAD) || \
    emit_bail "env" "dispatcher-commit-block: detached HEAD before push"
if [ "$current_ref" != "$full_ref" ]; then
    emit_bail "env" "dispatcher-commit-block: branch changed before push ('$current_ref' != '$full_ref')"
fi

# Push the verified object (not mutable HEAD).
# -c remote.origin.mirror=false: a mirror=true remote would otherwise make bare
# `git push` act as --mirror; with an explicit refspec the combination is fatal —
# forcing false keeps a single-ref update.
set +e
push_output=$(LC_ALL=C git -c remote.origin.mirror=false \
    -c advice.pushUpdateRejected=false \
    push origin "${NEW_COMMIT_SHA}:$full_ref" 2>&1)
push_exit=$?
set -e

if [ "$push_exit" != "0" ]; then
    # Failure-tolerant captures (match dispatcher :934-937 `|| true`): under
    # `set -euo pipefail`, zero-match grep exits 1 and multi-match|head can
    # SIGPIPE — without `|| true` the script dies with no bail envelope.
    push_status=$(printf '%s\n' "$push_output" \
        | grep -E '\[rejected\]|\[remote rejected\]|^fatal:' | head -n 1) || true
    push_remote=$(printf '%s\n' "$push_output" \
        | grep -E '^remote:' | tail -n 2) || true
    push_tail=$(printf '%s\n' "$push_output" \
        | grep -v '^hint:' | tail -n 3) || true
    # Keep bounded remote: context with the status line (hook/GH00x text often
    # lives on remote: lines; status alone is "! [remote rejected] …").
    if [ -n "$push_status" ] && [ -n "$push_remote" ]; then
        push_diag=$(printf '%s\n%s' "$push_remote" "$push_status")
    elif [ -n "$push_status" ]; then
        push_diag=$push_status
    else
        push_diag=$push_tail
    fi

    # Drain pattern: redirect to /dev/null (NOT grep -q) so pipefail + large
    # push_output cannot SIGPIPE printf and flip the branch (script has set -o pipefail).
    # Order: history → phrase-level auth/transport → remote-rejected/hook → default.
    # Never use bare `network` or `timeout` (false-positive on hook text / refnames).
    if printf '%s\n' "$push_output" | grep -E '\(non-fast-forward\)|\(fetch first\)' >/dev/null; then
        emit_bail "judgment" \
            "git push non-fast-forward; local commit preserved: $push_diag"
    elif printf '%s\n' "$push_output" | grep -iE \
        'Authentication failed|could not resolve|Could not read from remote|does not appear to be a git repository|no upstream branch|Permission denied|Permission to .+ denied|Write access to repository not granted|returned error: (401|403)|Connection timed out|Operation timed out|Failed to connect|Connection refused|Repository not found|Could not resolve host' >/dev/null; then
        emit_bail "env" "git push auth/network/config: $push_diag"
    elif printf '%s\n' "$push_output" | grep -E '\[remote rejected\]|hook declined' >/dev/null; then
        emit_bail "judgment" \
            "git push rejected; local commit preserved: $push_diag"
    else
        # Fail-closed default matches today's unrecognized-failure arm.
        emit_bail "judgment" "git push failed; local commit preserved: $push_diag"
    fi
fi
```

**Why this fixes it:**
- No dependency on upstream tracking or `pushDefault`/`push.default` (hazard noted at #668 wait-round comment ~401-408)
- No new GitHub API call; no new `PR_BRANCH` env var (Option B not adopted)
- Explicit `"${NEW_COMMIT_SHA}:$full_ref"` pushes the verified object to a pinned full ref
- Classification order: history tokens → phrase-level env auth/transport → remote-rejected/hook → default judgment. Never keys off the generic `error: failed to push some refs` trailer alone; never labels hook declines as "non-fast-forward"; never uses bare `network`/`timeout`
- Both bail categories hard-stop the grind. Neither debits `--max-fix`. After either bail the operator must reconcile the unpushed local commit before the next grind (see recovery note)
- `set +e`/`set -e` wrapper preserved around the push capture; diagnostic extractors use `|| true` so classification always reaches `emit_bail`. Bail reasons keep a bounded `remote:` + status (or hint-filtered tail) so `(fetch first)` / `(non-fast-forward)` / hook text survive

**Implementation approach:**
1. Pin `full_ref` immediately after fix-round routing (~445), before Litmus
2. Validate `refs/heads/*` + `git check-ref-format` (no `--`; git 2.43 rejects it with exit 129)
3. Re-check the same full ref immediately before push
4. Push `"${NEW_COMMIT_SHA}:$full_ref"` under `LC_ALL=C`, `mirror=false`, `advice.pushUpdateRejected=false`
5. Classify with drain-safe `grep ... >/dev/null` and the ordered arms above

## Design Constraints

**MUST preserve:**
- History refusals `(non-fast-forward)` / `(fetch first)` → `judgment` with "local commit preserved" and those tokens visible in the reason
- Hook / `[remote rejected]` (non-auth) → `judgment` with neutral "git push rejected" (must **not** claim non-fast-forward)
- Auth/permission/network/missing-remote/no-upstream → `env` via **phrase-level** patterns only (HTTPS `Permission to … denied`, `returned error: 401|403`, `Write access…`, `timed out` / `Failed to connect` / `Connection refused`, missing-remote fatals). Bare substring `network` or `timeout` is **forbidden** in the env arm.
- No force push
- No new `PR_BRANCH` env contract from pr-grind for this ticket

**Branch identity without a new env var:**
`resolve-pr-worktree.sh:202-216` asserts grind checkout equals the PR branch/SHA at Step 0 (before the worker). Pin+recheck inside the dispatcher only detects branch changes **after** the pin (e.g. a commit hook switching branches). A worker that checks out a different branch before the dispatcher runs is an accepted limitation of rejecting Option B; initial correctness remains the grind-start assert.

**Clarification on explicit refspec:**
Destination is always `origin` + the pinned full ref. Prerequisite (unchanged from today's bare push): `origin`'s effective push URL must identify the same repository as the PR.

## Implementation Details

### Branch ref resolution / Push command / Bail classification

See the normative snippet in Proposed Solution. It replaces bare `git push` (line 1248) and the case statement (lines 1252-1264). Validation is hoisted to ~445; Step 11 only re-checks and pushes.

**Test update required (`test_k_push_failure`, tests/test-dispatcher-commit-block.sh:498-518):** Today it asserts `.bail_category == "judgment" and (.bail_reason | contains("git push failed"))`. After this change the missing-remote path matches the env arm (`does not appear to be a git repository` / `Could not read from remote`) and the reason prefix is `git push auth/network/config:`. Replace the assertion with **all** of:
1. `bail_category == "env"`
2. `bail_reason` contains `git push auth/network/config`
3. `bail_reason` contains `does not appear to be a git repository` (or the fixture's stable missing-remote substring)
4. Keep existing local-commit-preserved / remote-unchanged checks
Do **not** keep `contains("git push failed")` (that string is only the default judgment prefix). Cover judgment via Tests 3a–3c.

## Testing Plan

All tests extend `tests/test-dispatcher-commit-block.sh` on `make_dispatcher_fixture`. Do not call `gh`. Assert against the bare remote with `git -C "$remote" rev-parse ...`.

### Test 1: No-upstream branch push succeeds

1. `git branch --unset-upstream`; `push.default=simple`; `push.autoSetupRemote=false`
2. Assert `! git rev-parse --abbrev-ref '@{u}' 2>/dev/null`
3. Stage + `run_dispatcher_capture`
4. Assert success and bare remote `refs/heads/main` equals new SHA

### Test 2: Negative control (in-suite, no whole-file re-exec)

1. Inside one `test_*`: copy script to temp; restore only the bare `git push` line
2. `local SCRIPT="$temp_copy"` then one `run_dispatcher_capture` (bash dynamic scope; do **not** re-exec the suite)
3. Same no-upstream fixture as Test 1
4. Assert `bail_category=env` and a reason substring that survives the diagnostic bound (e.g. `--set-upstream` or `no upstream`)

### Test 3a: Judgment — fetch-first

1. From a second clone, advance bare remote `main` (sandbox never fetches)
2. Stage divergent fix; one `run_dispatcher_capture`
3. Assert `judgment`, reason contains `(fetch first)`, contains "local commit preserved", local HEAD advanced

### Test 3b: Judgment — true non-fast-forward (own fixture, not a continuation of 3a)

1. Fresh fixture: advance bare remote, `git fetch origin` while the sandbox still has a **staged** (uncommitted) change
2. One `run_dispatcher_capture` so Step 9 and Step 11 both run with the remote tip already known
3. Assert `judgment`, reason contains `(non-fast-forward)`, local commit preserved
4. Do not re-invoke after a failed push on a clean index (that takes the #668 wait-round path and never reaches Step 11)

### Test 3c: Judgment — hook declined (mandatory)

1. Pre-receive hook on bare remote exits 1 (emit a distinctive `remote:` line, e.g. `remote: GH006 test-hook`)
2. Otherwise-valid push
3. Assert `judgment`, reason contains `[remote rejected]` **and** the bounded `remote:` / hook text, and reason does **not** contain `non-fast-forward`
4. **Negative control (bare token false-positive):** pre-receive decline whose `remote:` or refname contains `network` / `timeout` / `deploy timeout` (e.g. `remote: GH006: network policy changes require review` or branch `feature/network-policy`) — assert still `judgment` with `[remote rejected]`, reason prefix is **not** `git push auth/network/config`

### Env-classifier auth/transport fixtures (new)

Positive (must be `env`, exactly one bail envelope, reason prefix `git push auth/network/config`):
1. Stubbed HTTPS: `remote: Permission to owner/repo.git denied to user` + `fatal: unable to access ...`
2. Stubbed HTTPS: `The requested URL returned error: 403` (and/or `401`)
3. Stubbed transport: `Connection timed out` / `Operation timed out` / `Failed to connect` / `Connection refused`
4. Stubbed: `remote: Write access to repository not granted` and/or `Repository not found`

Keep history-arm precedence: a payload that also contains `(fetch first)` still maps to judgment.

### Test 4: Explicit destination vs config

1. Bogus `remote.pushDefault`; assert push still updates `origin`'s `refs/heads/main`
2. With `remote.origin.mirror=true`: assert push succeeds, bare `refs/heads/main` equals `NEW_COMMIT_SHA`, and no other remote refs were deleted/created (`-c remote.origin.mirror=false` on the command is load-bearing)

### Test 5: Local-only commits not misreported

1. After rejected push, stub `fetch-pr-state.sh` so `HEAD_FULL_SHA` is bare remote pre-push oid; re-invoke clean index → `result_commit_sha == "none"`
2. Inverse stub matching local unpushed oid → that oid reported

### Test 6: Pin / recheck / verified-SHA safety (new)

1. Detached HEAD before dispatch → `env`, HEAD unchanged (no new commit)
2. Post-commit hook checks out another branch → `env` at Step 11 recheck; bare remote unchanged
3. Hook creates another commit after Step 10a SHA capture → remote equals verified `NEW_COMMIT_SHA`, not the later HEAD

### Classifier / diagnostic pipefail fixtures (new)

All run under the script's `set -euo pipefail` after the push-capture `set -e` restore. Assert exactly one bail envelope (no silent exit):

1. **Drain-safe classifier ifs:** early matching token plus >64KB trailing payload — history arm still emits "local commit preserved"; early `Authentication` still maps to `env`
2. **Zero-match status extractor:** push stderr is only `error: failed to push some refs to '…'` (no `fatal:` / `[rejected]` / `[remote rejected]`) — `push_status`/`push_remote` empty, fallback `push_tail` used, default judgment arm emits envelope with "local commit preserved"
3. **Multi-match status extractor:** payload with ≥2 `^fatal:` lines (missing-remote shape) — `push_status|head -n 1` plus `|| true` still yields one env envelope (does not die on SIGPIPE before classification); reason contains `git push auth/network/config`

## Alternative Considered: Set upstream in resolve-pr-worktree.sh

**Rejected:** worktree resolution should not configure push behavior; upstream is mutable; explicit refspec is more robust.

## Alternative Considered: Pass PR_BRANCH env from pr-grind

**Rejected for this ticket (Option B).** Branch identity: grind-start assert + early pin + Step 11 recheck. Worker pre-pin checkout swap remains an accepted limitation.

## Risks

### Risk 1: Branch ref validation / drift

Pin immediately after routing (~445), before Litmus mutation. Re-check before push. `check-ref-format` without `--`.

### Risk 2: Fork PRs

Already blocked in pr-grind Step 0. Out of scope.

### Risk 3: Special characters in branch names

Quoted `"${NEW_COMMIT_SHA}:$full_ref"` plus `git check-ref-format "$full_ref"`.

## Success Criteria

1. No-upstream fix-round push succeeds
2. `(fetch first)` and `(non-fast-forward)` remain `judgment` with those tokens and "local commit preserved" in the reason
3. Hook/`[remote rejected]` judgment does not claim non-fast-forward
4. Push not misguided by `pushDefault`/`push.default`; mirror=true still single-ref
5. Tests 1–6 + classifier fixture pass; no new suite failures

## References

- Issue #890: https://github.com/chris-yyau/busdriver/issues/890
- `scripts/dispatcher-commit-block.sh` ~445 (fix-round fall-through), 1248 (push), 1252-1264 (bail case), 90 (`pipefail`)
- `scripts/resolve-pr-worktree.sh` 153, 202-216
- #668 wait-round comment ~401-408
- `skills/pr-grind/SKILL.md` ~92, ~340-351, ~1023

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
