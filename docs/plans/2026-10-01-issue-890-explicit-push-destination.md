# Issue #890: dispatcher-commit-block explicit push destination

**Status:** Draft
**Author:** agent bd-890-cursor
**Date:** 2026-10-01
**Revised:** 2026-10-04 — native Claude owner (session d0c231bd) applying the Chris-approved scope boundary (see **Scope and trust boundary**). 2026-10-06 — condensed to one normative copy of each rule (the 133877-byte text exceeded the Codex reviewer's per-argument prompt limit in run `d8089ca3`); no requirement, guarantee, decision or test was dropped. Every earlier variant is preserved in `/home/chris/busdriver-evidence/issue-890/` and the coordinator's round archives.

## Problem

**Historical baseline:** pr-grind worktrees often have no upstream (Dependabot branches; PRs opened elsewhere). pr-grind Step 0 materializes the branch with `git fetch origin "refs/heads/<branch>:refs/heads/<branch>"`, `resolve-pr-worktree.sh:153` creates the worktree on it, and under `push.default=simple`/`upstream` with `push.autoSetupRemote` unset the pre-#890 bare `git push` failed with "no upstream branch". That was the original Step 11 shape.

**Live tree today (already landed, not this design's delta):** `scripts/dispatcher-commit-block.sh` pins `full_ref` at :449-460, pushes `git -c remote.origin.mirror=false -c push.followTags=false -c advice.pushUpdateRejected=false push origin "${NEW_COMMIT_SHA}:$full_ref"` at :1276-1279, and classifies at :1283-1285. Lines ~1248-1260 are Step 10a Grind-PR trailer verification, not a push. Do **not** re-land the explicit push.

**Remaining delta (proposed, not implemented):** one-destination refuse; PR-home identity from GitHub PR metadata (not origin config, not branch+SHA) bound to Git's **effective** push URL (`git remote get-url --push --all origin`, rewrites applied by Git); credential-safe `push_dest_id` display; refuse a credential-bearing or `http://` effective URL; HTTPS and SSH (`ssh://`, scp) both supported, including credential-free same-repository HTTPS↔SSH aliases (option A; #890 does not ban them, and the original no-upstream success is preserved); optional bounded `pre_push_tip`; durable trailer tokens; immutable SHA from pinned `full_ref` with a pre-commit snapshot; classifier MUSTs; `push.recurseSubmodules=no`; an operator recovery procedure published in `skills/pr-grind/SKILL.md`.

**Unpushed-commit consequence:** after any Step 11 bail the fix commit stays on the local branch, pr-grind removes the ephemeral worktree (SKILL.md:92), the next grind's non-forced Step 0 fetch does not rewind a local-ahead branch, and `resolve-pr-worktree.sh:214-215` stops because local SHA ≠ `headRefOid`. Automation never retries, resets or forces; recovery is the manual procedure below.

## Scope and trust boundary (Chris-approved 2026-10-04)

**Provenance.** Issue #890 requires an explicit-destination push for no-upstream worktrees ("Push to an explicit destination, not a bare push, e.g. `git push origin "HEAD:refs/heads/${PR_BRANCH}"` … That also removes the reliance on `remote.pushDefault` / `push.default`"), `env` classification of a missing upstream, and handling of the unpushed commit. Later agent Drafts (snapshot `5e0d5885` L427; `8c78d0ff` L484) added an unconditional "no Git child in the tip/push pipeline has userinfo/query in argv", including inherited `GIT_CONFIG_*` overlays, and run `579e93c6` reviewers extended it to overlay indexing, `GIT_CONFIG_PARAMETERS` and non-URL transport keys. That blanket guarantee came from neither the issue nor an accepted ADR (ADR 0016 governs review-gate environments). Chris approved the narrower boundary below: Slack C0C64DU9DA9, thread 1790947144.979399, message 1791061940.595679 ("批准"), replying to the boundary statement in message 1791054605.453259. That approval authorizes this revision and a full normal review; it is **not** design acceptance.

**Guarantees (dispatcher-introduced behavior):**
- **G1 Explicit destination.** Push named remote `origin` with `"${NEW_COMMIT_SHA}:$full_ref"`. No reliance on upstream, `remote.pushDefault` or `push.default`.
- **G2 One PR-bound endpoint, Git-native.** Git's effective push URL list (git-remote(1): "Configurations for insteadOf and pushInsteadOf are expanded here") has exactly one entry; it parses as `https://`, `ssh://` or scp and matches the GitHub PR tuple (`PR_HEAD_*`). It is re-read and byte-compared to the pin **after the tip lookup, immediately before push**. The dispatcher checks Git's answer and does not re-implement rewrite or overlay semantics.
- **G3 No dispatcher-introduced credential exposure.** No URL on any child argv (lookup and push name `origin`); the pinned URL is never logged or emitted; any effective push URL outside the closed transport grammar — including any HTTPS userinfo, an SSH/scp user containing `:`, a query, a `#`, or `http://` — is refused before any network operation; tip lookup is skipped when the effective fetch URL fails the same grammar or is not PR-bound; URL-shaped tokens are redacted in `PUSH_DIAG` and `push_dest_id`. Because the checked URL is the URL Git resolves for `origin` (documented, git-remote(1); fixtures 7c/8b exercise it on real Git), Git-derived transport argv for this push and lookup never carries a password/token userinfo, query or fragment. An allowed SSH/scp URL may put its public, colon-free user (e.g. `git`) on the ssh command line; that user is not a credential. Helpers / SSH agent hold secrets; display redaction alone is not sufficient, hence the refuse.
- **G4 Immutable SHA, one attempt.** One `NEW_COMMIT_SHA` captured from `full_ref`; exactly one automatic push attempt; no automatic retry, reset or force.
- **G5 Honest classification and recovery.** Uncertain outcomes bail with the unknown-outcome prefix. Manual recovery acts only on `observed` lookups (`verified-absent` authorizes nothing); an empty or unverified observation never authorizes a push; at most one guarded manual non-force push after fresh reconciliation.

**Trust assumption (explicit, Chris-approved).** Existing Git/SSH transport configuration and environment are trusted exactly as a plain `git push origin` trusts them: credential helpers, `core.sshCommand` / `GIT_SSH_COMMAND`, `~/.ssh/config`, known_hosts, proxies, `http.*` (headers, CA), inherited `GIT_CONFIG_*` command-scope config and repository hooks. The feature does **not** defend against an already-malicious Git/SSH environment and makes **no** all-child, arbitrary-configuration guarantee. Config that changes the **URL** (any scope, including inherited overlays) is still checked because its effect appears in Git's effective URL; config that changes **non-URL** transport behavior is under this assumption.

**Deliberately not added:** no SSH-only narrowing; no override of `core.sshCommand`, SSH config, proxies or helpers; no blanket overlay refusal; no `unset`/strip of `GIT_CONFIG_*` or any variable; no `env -i`; no change to gate/env sanitization (ADR 0016 untouched); no dispatcher-wide GH_HOST pin (ADR 0026 residual stays documented); do not cite ADR 0050. Hostile-environment containment would be a separate decision.

**Superseded Draft text (removed by scope, not by waiving a finding):** `_bd890_git_config_overlay_refuse`, `_bd890_rewrite_would_retarget` and the blanket all-child argv MUST (preserved in Draft `8c78d0ff`).

**Review history (condensed; full raw findings and dispositions are archived).**
- Run `579e93c6` (pre-scope batch): overlay-parser findings resolved by removing the parser under the approved boundary; non-URL overlay keys recorded as residual R1; `nameWithOwner` assert dropped (redundant with the login/name ↔ `.url` check); agy's explicit-pushurl + `pushInsteadOf` point is no defect (git-config(1): "If a remote has an explicit pushurl, Git will ignore this setting for that remote"); a mandatory git-dir identity file is not adopted (R3).
- Run `31043ad4`: its arbiter verdict is **inadmissible and excluded from proof** (the verdict write was denied, then re-written through a different tool); its findings were nevertheless taken as design input (litmus suite migration, row 3d `failed`, diag builder contract, identity helper, number-only repo selection → R5, fetch-URL skip, fixture isolation, errexit).
- Batch `cb57f5ef` (runs `cb57f5ef`, `7a65042d`, `7caa34e7`; native early stop `parked_no_progress`, plan-blocking MEDIUM history `[7,1,1]`). Coordinator's evidence disposition for run `cb57f5ef`, verbatim: "2026-10-05T16:23:41.629Z Bash toolu_017eTTySCG6QjwqMb5eH31L2 date+%s%3N redirected to /tmp/claude-1000/-home-chris--cursor-worktrees-busdriver-bd-890-cursor/d0c231bd-823a-4038-b532-812ab0eb95ab/scratchpad/start; gate denial16:23:41.902Z. Target NOT claude.json; no alternate timing-file write, fileabsent. FirstWrite toolu_01CjSgAB3ej6Poapyfu5yJox16:28:32.353Z toclaude.json succeeded16:28:32.633Z. Arbiter taska8d5989f547fd436f violatedSTOPsentence bycontinuingreads/verdict. This is instructionfailure, not proofsame-actionbypass." All findings of that batch are fixed below. Two were contradicted (a SIGPIPE race in the hex check; grep on an unterminated last line).
- Batch 2 run `d8089ca3` (iteration 1, coverage incomplete: Codex `ERROR` — `/usr/bin/printf: Argument list too long` on the 136192-byte prompt; no arbiter). Its Agy HIGH and Grok findings are all fixed below.
- Batch 2 run `e9ff013b` (iteration 1, FULL 3/3, FAIL 0H/4M/3L). All fixed below (7f(i)–(v)); the `push_repo_id` format finding was contradicted.
- Batch 2 run `255f3b20` (iteration 2, FULL 3/3, FAIL 0 HIGH / 5 MEDIUM / 4 LOW; native early stop `parked_no_progress`, history `[1,3]`). Its five MEDIUMs (test_grind_f words, dash-led branch, blank push-URL records, duplicate keys, no real carrier) are carried into the batch-3 revision below.
- Batch 3 run `a8116816` (iteration 1, recorded natively as FAIL 0 HIGH / 4 MEDIUM / 6 LOW). **Provenance caveats, disclosed and not relied on as a PASS basis:**
  - coverage was DEGRADED 2/3 (Grok exit 124 at the 1200s limit; no droid rescue);
  - the reviewed document was a partial revision, after a Bash rewrite of it was refused by the design gate;
  - the arbiter's one read-only Bash call was refused as a gate false positive, and it then ran a narrower read-only command. That is a re-route, which the dispatch had not forbidden for reads.
- Batch 3 run `f12d14d9` (iteration 2, FULL 3/3, FAIL 0 HIGH / 6 MEDIUM / 8 LOW; native early stop `parked_no_progress`, history `[2,3]`; arbiter timing read refused, not retried). All its MEDIUMs and LOWs are fixed below (carrier, basename-only paste, row-2 hooks, relay, reader consistency, tests).
- Batch 3 run `f5eb40ed` (iteration 2, FULL 3/3, FAIL 0H/1M/4L). **Native state discontinuity, retained and not repaired:** recording turned `medium_issues_history` `[2,3]` into `[1]` and left `early_stopped` set. Fixed: recovery step 0, the non-zero exit on `cat` failure, the `eval` guard, and the wrapper fence.
- Batch 3 run `01d0779c` (iteration 3, FULL 3/3, FAIL 0H/3M/5L; parked, history `[1,2]`; one arbiter read was refused, so its `resolve-pr-worktree.sh:85` citation is unverified). Fixed: the root is passed as `BUSDRIVER_PLUGIN_ROOT`, row-2 preconditions and the detached rebase, per-bail-type tokens, and `push_dest_id || emit_bail`.
- Run `ba23a826` (iteration 3, FULL 3/3, FAIL 0H/3M/4L; native PASS because all three MEDIUMs were in deferrable categories). Those MEDIUMs are fixed here, not carried: the anchored starts-with class allowlist (live :1285 writes `PREFIX: diag`), `rebase.updateRefs=false`, and the hook-less return; 7f(x)–(x-c).
- Run `4b3104ae` (iteration 3, FULL 3/3, FAIL 0H/1M/9L; recorded, advanced to iteration 4, `medium_issues_history` reset to `[1]`, retained). The MEDIUM (a Step 10a bail had no safe exit) is fixed by recovery step 5's `full_ref` compare-and-swap discard, not by Grok's amend-and-push, which would bypass Rail A. The LOWs are fixed in row 2, step 1, the gate scope, 7f(xi) and `dirname`. Contradicted: Grok's gate-hoist HIGH, its `timeout` function import (the dispatcher runs `bash -p`), and its `switch -` target.
- In `f5eb40ed` and `ba23a826`, the Grok HIGH that `local raw=$1` word-splits was contradicted.
- **Accepted residual:** separate-git-dir and bare-hub layouts fail step 0's common-dir check, and recovery STOPs.

**Review evidence constraints (normative for implementers and reviewers):** use this document and the cited live tree only. Do **not** execute `_probe.sh`, `/tmp/bd890-probe.sh`, `/tmp/bd890-probe2.sh` or any runtime probe; do **not** fetch Git `transport.c` / `remote.c` by any route; do **not** treat excluded L15/L16, refused or alternate-route outputs as verification. GitHub PR-object identity and the `PR_HEAD_*` hand-off are **proposed contracts**, not proven runtime behavior.

## Proposed Solution

Push to an explicit destination using a full branch ref pinned early in the fix-round path, and push the SHA Step 10a already verified.

**Errexit:** the live dispatcher runs with `set -e` active through Steps 10–11 (bare `set -e` at :884; `set -uo pipefail` at :90). Every new command there is followed by `|| emit_bail …` / `|| { …; }`, sits in an `if`/`case` condition or a `$(…) || …` guard, or runs in the existing `set +e … set -e` push window. A failing command must never exit without the one JSON envelope.

**Normative implementation (single source of truth):**

```bash
# --- Lib sourcing block (live :175-193): the ONE PR_HEAD_* validation site ---
# After push-failure-classify.sh; bail-envelope.sh is sourced at :177, so emit_bail exists.
# shellcheck source=/dev/null
. "$SCRIPT_LIB/push-dest-id.sh" || \
    emit_bail "env" "dispatcher-commit-block: failed to source push-dest-id.sh"
# Runs on EVERY dispatcher invocation (including the in-script clean-index / #668
# branch), before fix-round routing, Litmus and any review-lock mutation. Prints
# exactly host/owner/name (ASCII-lowercase, no scheme/port/leading slash, one
# trailing .git stripped). The pin reuses pin_repo_id; nothing re-reads PR_HEAD_*.
pin_repo_id=$(_bd890_pr_identity_from_env) || \
    emit_bail "env" "dispatcher-commit-block: missing/malformed PR_HEAD_HOST/OWNER/NAME"

# --- Immediately after fix-round routing esac (~445), BEFORE Litmus init ---
full_ref=$(git symbolic-ref -q HEAD) || \
    emit_bail "env" "dispatcher-commit-block: not on a branch (detached HEAD)"
case "$full_ref" in
    refs/heads/*) ;;
    *) emit_bail "env" "dispatcher-commit-block: ref '$full_ref' is not a branch" ;;
esac
git check-ref-format "$full_ref" || \
    emit_bail "env" "dispatcher-commit-block: ref '$full_ref' invalid"

# Pin ONE effective push URL. get-url is a local config read (no network, no
# helper, no URL on argv) and reports insteadOf/pushInsteadOf from every scope,
# inherited command-scope config included. Read through the ONE raw-record reader
# _bd890_read_one_push_url (push-dest-id.sh, specified under "Raw push-URL record
# reader"; bash-3.2-safe, no mapfile, no awk NF count). Never first-of-many,
# never fetch-URL substitution. Existing transport config is neither overridden
# nor unset (trust assumption). PR identity is NOT origin.url and NOT
# resolve-pr-worktree.sh:202-216 (branch+SHA only; two remotes can share a commit).
unset push_dest_id PUSH_URL   # never inherit a repo-injectable value (ADR 0016)
_rd=0; _bd890_read_one_push_url || _rd=$?
case $_rd in
  0) ;;
  1) emit_bail "env" "dispatcher-commit-block: cannot resolve origin push URL(s) (git exit $_BD890_GIT_RC) [full_ref=$full_ref]" ;;
  *) emit_bail "env" "dispatcher-commit-block: need exactly one non-blank effective push URL record (none, blank, whitespace or several); multi-dest unsupported [full_ref=$full_ref]" ;;
esac
PUSH_URL=$_BD890_ONE_URL   # never logged, never on argv
unset _rd _BD890_ONE_URL _BD890_GIT_RC
# _bd890_transport_cred_ok (0 = safe) is a CLOSED ALLOWLIST, refuse by default —
# see "Transport URL grammar" (shared with _bd890_endpoint_identity).
_bd890_transport_cred_ok "$PUSH_URL" || \
    emit_bail "env" "dispatcher-commit-block: origin push URL is credential-bearing or http://; use helpers/SSH agent [full_ref=$full_ref]"
_bd890_endpoint_matches_pr "$PUSH_URL" "$pin_repo_id" || \
    emit_bail "env" "dispatcher-commit-block: effective push URL is not the PR repository [full_ref=$full_ref]"
push_dest_id=$(_bd890_dest_id "$PUSH_URL") || \
    emit_bail "env" "dispatcher-commit-block: cannot derive a credential-safe push_dest_id [full_ref=$full_ref]"
push_repo_id=$pin_repo_id
case "$push_dest_id" in   # backstop glob; '@' before ':' (scp leftover user) or ':' before '@'
  *'?'*|*'#'*|*://*@*|*'@'*':'*|*':'*'@'*)
    emit_bail "env" "dispatcher-commit-block: push_dest_id still looks credential-bearing; refusing" ;;
esac
[ -n "$push_dest_id" ] && [ -n "$push_repo_id" ] || \
    emit_bail "env" "dispatcher-commit-block: empty credential-safe push_dest_id or push_repo_id"
# PUSH_URL lives until the Step 11 byte-compare. _bd890_* functions stay defined
# until the success-path unset -f (the classifier sources push-dest-id.sh itself).

# ... Litmus, Steps 1–8: stage / preflight ...

# --- Step 9: Commit (post-commit hooks run inside `git commit`) ---
# Snapshot BEFORE commit so a pre-commit HEAD switch cannot label the old oid as the fix.
pre_commit_tip=$(git rev-parse --verify "$full_ref") || \
    emit_bail "env" "dispatcher-commit-block: cannot snapshot full_ref before commit [full_ref=$full_ref pr_number=$PR_NUMBER push_dest_id=$push_dest_id push_repo_id=$push_repo_id]"
# printf '%s' "$COMMIT_MSG" | git commit -F - …   (non-zero → emit_bail judgment; no NEW_COMMIT_SHA yet)

# --- Step 10: Immutable SHA capture from the pinned branch tip, NOT HEAD ---
# A post-commit checkout to another branch cannot poison it; never recaptured.
# sha1 → 40 hex, sha256 → 64 hex (sha256 width unverified without probes; accept either).
NEW_COMMIT_SHA=$(git rev-parse --verify "$full_ref") || \
    emit_bail "env" "dispatcher-commit-block: cannot resolve pinned full_ref after commit [full_ref=$full_ref pr_number=$PR_NUMBER push_dest_id=$push_dest_id push_repo_id=$push_repo_id]"
printf '%s' "$NEW_COMMIT_SHA" | grep -Eq '^[0-9a-f]{40}$|^[0-9a-f]{64}$' || \
    emit_bail "env" "dispatcher-commit-block: NEW_COMMIT_SHA not object-format hex after commit [full_ref=$full_ref pr_number=$PR_NUMBER push_dest_id=$push_dest_id push_repo_id=$push_repo_id]"
if [ "$NEW_COMMIT_SHA" = "$pre_commit_tip" ]; then
    emit_bail "env" "dispatcher-commit-block: pinned full_ref did not advance at commit (pre=$pre_commit_tip) [full_ref=$full_ref pr_number=$PR_NUMBER push_dest_id=$push_dest_id push_repo_id=$push_repo_id]"
fi
unset pre_commit_tip
RESULT_COMMIT_SHA="$NEW_COMMIT_SHA"   # Step 12 success SHA; same as live :1198-1200
# Durable identity tokens for every later bail (PR_NUMBER is already validated
# ^[1-9][0-9]*$ at bootstrap :168-170, so it is safe in the envelope).
_dur="full_ref=$full_ref NEW_COMMIT_SHA=$NEW_COMMIT_SHA pr_number=$PR_NUMBER push_dest_id=$push_dest_id push_repo_id=$push_repo_id"

# --- Step 10a: Grind-PR trailer verify on object $NEW_COMMIT_SHA (not HEAD) ---
# Runs before any drift/detach bail, so every envelope that could later authorize
# a manual push (rows 3c/3d) is emitted only for an object that passed Rail A
# (ADR 0036). Live checks are already by SHA (:1247 `rev-list --no-walk
# --grep="^Grind-PR: ${PR_NUMBER}\$"`, :1257 `%(trailers)` case), so no predicate changes.
# ... existing trailer checks on $NEW_COMMIT_SHA ...
# BAIL TEXT CHANGES: live :1215 says "Fix the hook, then 'git reset --soft
# HEAD~1' in $WORKTREE_DIR and re-grind". With Step 10a before the drift check,
# HEAD may be on another branch, so HEAD~1 would rewind an unrelated ref, and
# SKILL.md:92 removes $WORKTREE_DIR anyway. The HEAD-relative reset is REPLACED
# by the full_ref-scoped compare-and-swap discard (recovery step 5). Two
# replacement contexts (category unchanged; one line each, no embedded quotes).
# The two MISMATCH arms (live :1250 rev-list result != SHA, :1259 trailer not
# exact) append _grind_bail_ctx, which keeps the live words test_grind_f
# (tests/test-dispatcher-commit-block.sh:1858-1891) asserts — the SHA,
# UNPUSHED, commit-msg:
#   commit $NEW_COMMIT_SHA is LOCAL and UNPUSHED on full_ref; a commit-msg hook
#   altered the Grind-PR: trailer. Do NOT push this commit; no HEAD-relative
#   reset. Fix the hook, then follow step 5 (discard) of skills/pr-grind/SKILL.md
#   section Push bail recovery in the clone that still holds the branch, and
#   re-grind [full_ref=$full_ref NEW_COMMIT_SHA=$NEW_COMMIT_SHA]
# The two READ-FAILURE arms (live :1248 re-scan failed, :1254 trailer parse
# failed) do not claim a hook cause; they append _grind_verify_ctx:
#   cannot verify the Grind-PR: trailer; commit $NEW_COMMIT_SHA is LOCAL and
#   UNPUSHED on full_ref. Do NOT push this commit; no HEAD-relative reset. Follow
#   step 5 (discard) of skills/pr-grind/SKILL.md section Push bail recovery in
#   the clone that still holds the branch, and re-grind
#   [full_ref=$full_ref NEW_COMMIT_SHA=$NEW_COMMIT_SHA]
# No pr_number=/push_dest_id=/push_repo_id=/pre_push_tip=/tip_lookup= tokens:
# the trailer class can reach only step 5, which never pushes. No retry or push.

# --- Step 11: Checked push ---
# ONE branch-identity check (nothing runs between Step 10a and here that could
# move HEAD). Detached/switched → durable tokens, no pre_push_tip= (push not attempted).
current_ref=$(git symbolic-ref -q HEAD) || \
    emit_bail "env" "dispatcher-commit-block: detached HEAD before push [$_dur]"
if [ "$current_ref" != "$full_ref" ]; then
    emit_bail "env" "dispatcher-commit-block: branch changed before push ('$current_ref' != '$full_ref') [$_dur]"
fi
unset current_ref

# Tip-lookup eligibility — the ONLY place it is decided. `ls-remote origin` uses
# the EFFECTIVE fetch URL (insteadOf applied; a distinct pushurl is ignored).
# Skip only when the fetch URL is unresolvable, fails the PR tuple, or fails the
# credential check; never on dest-id inequality (HTTPS fetch + SSH pushurl of the
# same PR must still look up); never bail on the fetch URL alone.
_tip_dest_mismatch=0
_fetch_url=$(git remote get-url origin 2>/dev/null) || { _fetch_url=""; _tip_dest_mismatch=1; }
_bd890_endpoint_matches_pr "$_fetch_url" "$pin_repo_id" || _tip_dest_mismatch=1
_bd890_transport_cred_ok "$_fetch_url" || _tip_dest_mismatch=1
unset _fetch_url

# Optional pre_push_tip — named remote only. Bounded: GIT_HTTP_LOW_SPEED_LIMIT=1024
# GIT_HTTP_LOW_SPEED_TIME=10 (HTTP(S)), plus a wall-clock wrapper that can escalate
# past SIGTERM. _bd890_select_tip_wrapper (push-dest-id.sh, unit-tested) probes
# `timeout -k` then `gtimeout -k` after the :110 PATH prepend; on success sets
# _tip_wrap=(timeout -k 2 10) (or gtimeout) and returns 0, else returns 1. There is
# NO no-`-k` fallback and never an unbounded ls-remote; GNU timeout is not required.
_tip_wrap=()
_skip_tip=0
if [ "$_tip_dest_mismatch" -ne 0 ]; then
  _skip_tip=1
else
  _bd890_select_tip_wrapper || _skip_tip=1
fi
pre_push_tip=""
if [ "$_skip_tip" -eq 0 ]; then
  pre_push_tip=$(
    set -o pipefail
    GIT_HTTP_LOW_SPEED_LIMIT=1024 GIT_HTTP_LOW_SPEED_TIME=10 \
      ${_tip_wrap[@]+"${_tip_wrap[@]}"} git ls-remote --refs origin "$full_ref" 2>/dev/null \
      | awk -v ref="$full_ref" '$2 == ref { print $1; n++; if (n>1) exit 2 } END { exit (n!=1) }'
  ) || pre_push_tip=""
  printf '%s\n' "$pre_push_tip" | grep -Eq '^[0-9a-f]{40}$|^[0-9a-f]{64}$' || pre_push_tip=""
fi
if [ "$_skip_tip" -eq 1 ]; then TIP_LOOKUP=skipped
elif [ -n "$pre_push_tip" ]; then TIP_LOOKUP=observed
else TIP_LOOKUP=failed; fi
unset _tip_wrap _skip_tip _tip_dest_mismatch

# Destination revalidation — AFTER the lookup window, immediately before push
# (Litmus, commit and hooks may rewrite pushurl, add a URL or add a rewrite).
# _bd890_read_one_push_url returns 0 (exactly one raw record) and the record is
# byte-equal to the pinned PUSH_URL; both predicates are pure
# functions of the string, so byte-equality means the pushed-to endpoint is the
# checked one. Mismatch → env bail, local commit preserved, no push, no retry.
_rd=0; _bd890_read_one_push_url || _rd=$?   # same reader as the pin; errexit-safe
case $_rd in
  0) ;;
  1) emit_bail "env" "dispatcher-commit-block: cannot re-resolve origin push URL(s) (git exit $_BD890_GIT_RC) [$_dur]" ;;
  *) emit_bail "env" "dispatcher-commit-block: push destination changed after pin [$_dur]" ;;
esac
if [ "$_BD890_ONE_URL" != "$PUSH_URL" ]; then
    emit_bail "env" "dispatcher-commit-block: push destination changed after pin [$_dur]"
fi
unset _rd _BD890_ONE_URL _BD890_GIT_RC PUSH_URL

# One push of the verified object via NAMED origin + single refspec (live
# :1276-1279 plus recurseSubmodules). The -c knobs keep the single-ref promise
# (Test 4): git-push documents --recurse-submodules=only as pushing submodules
# but not the superproject (exact push_ret unverified; do not fetch Git C).
set +e
push_output=$(LC_ALL=C git -c remote.origin.mirror=false \
    -c push.followTags=false \
    -c push.recurseSubmodules=no \
    -c advice.pushUpdateRejected=false \
    push origin "${NEW_COMMIT_SHA}:$full_ref" 2>&1)
push_exit=$?
set -e

if [ "$push_exit" != "0" ]; then
    # Classifier owns classify → winning-arm diag → redaction → byte-cap.
    # The dispatcher only appends the trusted trailer.
    push_failure_classify "$push_output"
    emit_bail "$PUSH_BAIL_CATEGORY" \
      "$PUSH_BAIL_PREFIX: $PUSH_DIAG [$_dur pre_push_tip=${pre_push_tip:-} tip_lookup=$TIP_LOOKUP]"
fi
# emit_bail exits 1 (bail-envelope.sh:23-31); this unset is success-path hygiene only.
unset -f _bd890_dest_id _bd890_transport_cred_ok _bd890_endpoint_identity _bd890_endpoint_matches_pr _bd890_pr_identity_from_env _bd890_pr_identity_valid _bd890_select_tip_wrapper _bd890_read_one_push_url _bd890_one_record 2>/dev/null || true
```

**Raw push-URL record reader (`_bd890_read_one_push_url`, push-dest-id.sh — the ONLY reader at the pin, the Step 11 revalidation and recovery steps 2–3).** Contract: run `git remote get-url --push --all origin` once; preserve Git's exit status; never lose bytes to `$(…)` trailing-newline stripping; accept only output that is exactly one LF-terminated record containing no whitespace.
```bash
_bd890_read_one_push_url() {   # 0 = one record in _BD890_ONE_URL; 1 = git failed (_BD890_GIT_RC); 2 = record shape refused
    local raw
    _BD890_ONE_URL=""; _BD890_GIT_RC=0
    # Sentinel 'x' keeps every trailing LF; `|| rc=$?` keeps git's status even if errexit is inherited.
    raw=$(rc=0; git remote get-url --push --all origin 2>/dev/null || rc=$?; printf x; exit "$rc") \
        || { _BD890_GIT_RC=$?; return 1; }
    _bd890_one_record "${raw%x}"                      # returns 0 or 2
}
_bd890_one_record() {   # pure parse of raw bytes: 0 = exactly one record → _BD890_ONE_URL; 2 = refused
    local raw=$1
    _BD890_ONE_URL=""
    case $raw in *$'\n') ;; *) return 2 ;; esac       # empty output, or no terminating LF
    raw=${raw%$'\n'}                                  # strip exactly ONE terminator
    case $raw in ''|*[[:space:]]*) return 2 ;; esac   # blank, whitespace-only/leading/trailing/CR, or a 2nd record (inner LF)
    _BD890_ONE_URL=$raw
}
```
Two records, a blank or whitespace entry beside a valid one (`url\n\n`, `\nurl\n`, `url \n`, `url\r\n`), no output, and an unterminated record all return 2; only a non-zero Git exit returns 1, and its status is carried into the bail text. Whether Git ever prints an empty pushurl entry is not probed; the reader refuses it either way. No legitimate URL in the closed transport grammar contains whitespace, so this narrows nothing that would otherwise pass. Callers capture with `_rd=0; … || _rd=$?`, which is safe with errexit on or off. The snippet above is the specification; implementation proof is the unit table in the Testing Plan (Raw-record reader), not this text.

**Durable carrier (MUST) — the envelope file.** The only durable carrier is a per-dispatch file holding the dispatcher's raw stdout byte for byte. Conversation state (`RESULT_BAIL_REASON`, SKILL.md:386-387, :894, :1270 — prose for humans) is **not** a carrier, and recovery never reads it. The SKILL.md:340-351 invocation block is the only dispatcher invocation. Today it sits **inside** the ```text "Dispatcher Loop" diagram (the fence opens at SKILL.md:104), and every one of its lines carries the diagram's `│` prefix, so it is not a runnable fence. It therefore **moves out** of the diagram:
- The diagram keeps one line in its place: `│       Fix-round delegation: run the "Dispatcher invocation (envelope wrapper)" bash block below`.
- The full block becomes a real ```bash fence in a new SKILL.md subsection, "Dispatcher invocation (envelope wrapper)", placed immediately after the diagram's closing fence. Its lines carry no `│` prefix, so the test strips nothing.
- Every line stays in that one Bash call, between two marker comments the Testing Plan uses to extract and run it.
- The env block itself is unchanged apart from the three `PR_HEAD_*` lines, and it keeps the existing `"$WORKTREE_DIR"` / `"$PR_NUMBER"` / `"$CLAUDE_PLUGIN_ROOT"` convention.
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
printf 'RECOVERY_CLONE=%q\n' "$(dirname -- "$_bd890_gcd")" >&2   # as SKILL.md:1145
_bd890_root=${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}   # the dispatcher's own :151 expression
case $_bd890_root in
  /*) printf 'RECOVERY_LIB_ROOT=%q\n' "$_bd890_root/scripts/lib" >&2 ;;
  *)  printf 'RECOVERY_LIB_ROOT=\n' >&2 ;;              # not absolute → recovery STOPs (missing root)
esac
_bd890_rc=0
BUSDRIVER_PLUGIN_ROOT="$_bd890_root" \
WORKTREE_DIR="$WORKTREE_DIR" \
…existing env lines, plus the three PR_HEAD_* lines…
bash "$CLAUDE_PLUGIN_ROOT/scripts/dispatcher-commit-block.sh" >"$_bd890_env_file" || _bd890_rc=$?
if ! cat "$_bd890_env_file"; then
  printf '%s\n' '{"bail_category":"env","bail_reason":"pr-grind: envelope file unreadable after dispatch; see ENVELOPE_FILE"}'
  [ "$_bd890_rc" -ne 0 ] || _bd890_rc=1                  # an env-bail last line never exits 0
fi
exit "$_bd890_rc"
# bd890-envelope-wrapper:end
```
- **Location: the git common directory, not a state directory.** The run-time root is `git -C "$WORKTREE_DIR" rev-parse --path-format=absolute --git-common-dir`. That is the same resolver Step 0 already uses (SKILL.md:1142-1150), and with `NO_WORKTREE=1`, `WORKTREE_DIR` is the checkout itself.
  - The directory always exists and is shared by every worktree of the clone, so the file survives `git worktree remove` (SKILL.md:92). No `mkdir` and no `<MAIN_REPO_ROOT>` / `<STATE_DIR>` template are needed. A missing main `.claude/`, which SKILL.md:1151 tolerates, no longer matters.
  - Git never tracks files inside its own directory, so no gitignore rule is relied on. That holds in consumer repositories and under a custom `BUSDRIVER_STATE_DIR` alike, and a broad `git add -A` cannot stage the file.
  - The root comes from Git at run time into a quoted variable and is never pasted as text, so a root containing `'`, `$`, `` ` `` or `"` is inert. Only `$PR_NUMBER`, validated as `^[1-9][0-9]*$`, enters the name.
  - Git itself does not read, prune or garbage-collect unknown files in that directory. No busdriver gate reads the file, and it does not match the `codex-retrigger-gc.sh` prune glob (`.pr-grind-codex-retriggered-pr<PR>-*.local`).
- **Identity.** `mktemp` creates a new 0600 file with `O_EXCL` and a random suffix (alphanumeric `XXXXXX`), so every dispatch gets a fresh, unpredictable name. No earlier round's file is reused or overwritten, and an existing path or symlink is never followed. The basename has the closed shape `pr-grind-bail-<N>.<6 alphanumerics>`, which recovery validates before use.
- **Fail-closed handling.** If the common directory cannot be resolved, or is not an absolute existing directory, or `PR_NUMBER` is malformed, or `mktemp` fails: the dispatcher never runs, so there is no commit and no push, and an `env` bail goes to stdout. If a write fails mid-dispatch, or the file is truncated, unreadable or missing its envelope line, recovery treats it as unusable and goes to row 4. A missing carrier never authorizes a push.
  - `_bd890_rc=0; … || _bd890_rc=$?` captures the dispatcher status whether or not errexit is inherited. (SKILL.md has no `set -e`; this is hardening.)
  - The stdout seen by pr-grind is the file's bytes, so "parse the last stdout line" (SKILL.md:353) is unchanged. `ENVELOPE_FILE=` and the three `RECOVERY_*` lines go to **stderr**, so they can never become the last stdout line.
  - **Relay failure is never a success.** If `cat` fails after the dispatcher ran, stdout's last line is the `envelope file unreadable` env bail, and the block exits with the dispatcher's non-zero status, or `1` if the dispatcher had exited 0. The final stdout line and the exit status therefore always agree: an env-bail line never comes with exit 0.
- **Relay (MUST, checklist item 5).** The BAIL bullet (SKILL.md:893-894, "surface RESULT_BAIL_REASON to user") changes to also surface, verbatim, the `ENVELOPE_FILE=`, `RECOVERY_GIT_COMMON_DIR=`, `RECOVERY_CLONE=` and `RECOVERY_LIB_ROOT=` lines from that call. The bail message is the only place the operator learns these. Without them, recovery has no carrier, clone or library root and goes to row 4 / STOP.
- **Recovery library root (stable, explicit).** `RECOVERY_LIB_ROOT` is `$_bd890_root/scripts/lib`. `_bd890_root` is computed with the dispatcher's own expression (`${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}`, dispatcher :151), **and the wrapper passes it to the dispatcher explicitly as `BUSDRIVER_PLUGIN_ROOT`**. The dispatcher's `SCRIPT_LIB` (:175) is therefore byte-equal to the recorded root even when both variables are set to different installs, or when one is an unexported shell variable. Recovery uses exactly the helper code that produced the envelope. (Which `dispatcher-commit-block.sh` file runs is unchanged.)
  - It never uses an inherited `CLAUDE_PLUGIN_ROOT` / `SCRIPT_LIB`, which a fresh operator shell does not have, and never a relative `scripts/lib` from whatever branch a checkout has.
  - If that directory has since been removed (for example by a plugin update), recovery STOPs. There is no fallback to another version or path.
- **Redaction and content.** The file holds exactly what the dispatcher already prints to the session: the classifier-redacted diag plus credential-safe tokens. `PUSH_URL` is never emitted (G3), and nothing is added to the envelope.
- **Retention.** Files are kept, one per dispatcher invocation, so at most `MAX_FIX` per grind. Nothing deletes them automatically, so no deletion path is added; the operator may remove a file after recovery. Accepted residual **R6**: if nobody cleans up, small 0600 untracked files accumulate in the git common directory. They are invisible to `git status` and never pushed.
- **Stale-file guard (recovery).** Recovery uses the basename named in the latest bail message. Step 1 also requires that the basename's `<N>` and the trailer's `pr_number` both equal the PR being recovered, and that local `full_ref` still resolves to `NEW_COMMIT_SHA`. An older round's file therefore fails, because its `NEW_COMMIT_SHA` is no longer the branch tip, and goes to row 4.

**Envelope contents (MUST).** `emit_bail` JSON on dispatcher stdout (`bail_category` + `bail_reason`), persisted through the envelope file above. Every post-commit push-failure bail carries `full_ref=`, `NEW_COMMIT_SHA=`, `pr_number=`, credential-safe `push_dest_id=`, `push_repo_id=` (the PR tuple from the pin, never dest-id or origin.url), `pre_push_tip=` (empty unless observed) and `tip_lookup=skipped|failed|observed`. Pre-push drift/detached and revalidation bails carry `$_dur` only — no `pre_push_tip=`, so they never imply a push attempt. Missing/unverifiable tokens → recovery row 4. Fixtures assert these tokens on the dispatcher path.

**Classifier library (algorithm SSOT — owns diag end-to-end).** `scripts/lib/push-failure-classify.sh` sources `scripts/lib/push-dest-id.sh` via `SCRIPT_LIB` or its own `BASH_SOURCE` directory, so redaction works standalone in unit tests and after the dispatcher's `unset -f`. The dispatcher MUST NOT re-select or re-cap diagnostics. The algorithm lives only in this library.
- `push_failure_build_diag` **is** the shared builder, rewritten in place: new signature `push_failure_build_diag <raw_output> [<arm>]` (`history|unknown|hook|env|default`; omitted = `default`); sets `PUSH_DIAG` only. `push_failure_classify` decides the arm on the full raw output first, then calls the builder exactly once; there is one diagnostic path, and the live remote-prose-first concat (:21-23) is deleted, not kept beside the new code. It stays callable standalone.
- `test_890_diag_zero_and_multi_match` is updated with the rewrite: zero/multi-match inputs assert winning-first order and the cap; its `|| true` guard count (3 today) becomes the new function's exact count; its mutation negative still strips every extractor guard and must abort under `set -euo pipefail`.
- **Mutation-test dependency setup:** the mutated copy lives in `$TMPDIR`, whose `BASH_SOURCE` dir has no `push-dest-id.sh`, so the subprocess exports `SCRIPT_LIB="$REPO_ROOT/scripts/lib"` and asserts `declare -F _bd890_dest_id` before calling the mutated builder (a missing dependency fails as its own assertion). The count and the `sed` strip are restricted to the extractor lines in `/^push_failure_build_diag()/,/^}/` (today all three guards are at :16-20), so the sourcing guard neither changes the count nor is stripped.

**Normative lib algorithm (pseudocode — executable contract):**
```
push_failure_classify(raw):            # FULL unbounded raw push output
  1. Arm on FULL raw (order fixed; first match wins):
     a. history: a CLIENT status row `[rejected]`, or history-class
        `[remote rejected]`, with `(non-fast-forward)` or `(fetch first)`
        → judgment, "git push non-fast-forward; local commit preserved"
        (reason keeps the decisive parenthetical; either wording accepted).
     b. unknown-outcome: client `! [remote failure]` and/or
        `remote failed to report status` on a client status line (never
        `^remote:` prose alone) → env, EXACT prefix (one line, these bytes,
        no quotes): git push outcome unknown — compare remote tip of
        full_ref to NEW_COMMIT_SHA before any push/reset; do not auto-retry;
        see skills/pr-grind/SKILL.md section Push bail recovery
        Transport phrases never claim a payload that carries these tokens.
     c. client remote-rejected (THE single hook arm): any client line
        `^[[:space:]]*! \[remote rejected\]` whose parenthetical is neither
        `(fetch first)` nor `(non-fast-forward)` — `(hook declined)`,
        `(pre-receive hook declined)`, `(cannot lock ref …)`, … — NOT
        narrowed to "hook declined" → judgment,
        "git push rejected; local commit preserved" (never claims
        non-fast-forward). This deliberately reorders the live classifier,
        which tests env before `[remote rejected]`.
     d. phrase-level env (closed, exhaustive list) → env,
        "git push auth/network/config": HTTPS `Permission to … denied`;
        `returned error: (401|403|50[0234])`; `Write access…`;
        `Connection timed out` / `Operation timed out` / `Failed to
        connect` / `Connection refused`; `the remote end hung up
        unexpectedly`; `Connection reset by peer`; `Recv failure`;
        `Authentication failed`; OpenSSH `user@host: Permission denied
        (publickey).`; `does not appear to be a git repository` /
        `Could not read from remote` / `Could not resolve host` /
        `no upstream branch`. Retained remote permission phrases
        (`remote: Permission to … denied`, `remote: Write access…`,
        `Repository not found`) count only because no client row matched
        (c). Bare `network` / `timeout` substrings are FORBIDDEN; bare
        `unable to access` is not a standalone matcher.
     e. remote-prose hook: no client row, a `^remote:` line containing
        `hook declined` → judgment, "git push rejected; local commit preserved".
     f. default → judgment, "git push failed; local commit preserved".
     Client-status MUST: history / unknown / transport / Authentication
     failed / Permission denied (publickey) match only Git-client status rows
     or client diagnostic lines (`^[[:space:]]*! \[rejected\]`,
     `… \[remote rejected\]`, `… \[remote failure\]`, `^(fatal|error):`,
     the OpenSSH line); `^remote:` prose never satisfies them or impersonates
     a client result. Extra hardening is allowed only if it contradicts none
     of this.
  2. Winning evidence BEFORE redaction/cap: history/hook → the client row;
     unknown → the [remote failure] row; env/default → the decisive client
     fatal/status line; remote-prose hook → that remote: line. Prefer it over
     any earlier ^fatal: or huge remote: prose.
  3. Diagnostic = winning evidence first + optional supporting remote:/tail
     (support never displaces the winning marker or decisive reason).
  4. Redact, then UTF-8-safe byte-cap (≤1500 bytes PUSH_DIAG).
     Redaction runs on the WHOLE candidate (evidence + support) after the arm
     decision, so it cannot change classification. Token grammar:
     * Delimiter: WHITESPACE ONLY; a token is a maximal non-whitespace run.
       No other byte ends a token — quotes, apostrophe (an RFC 3986
       sub-delim), brackets, parentheses, `,` and `;` are legal unencoded in
       userinfo/query, and splitting on them would leave a credential tail
       outside the redacted run. Whitespace is never legal unencoded in a URL.
     * URL-shaped token: contains `://` anywhere (case-insensitive); or scp
       form `<user>@<host>:<path>` (`@` before the first `:`, no `/` before
       the `@`, non-empty path — so `git@github.com: Permission denied
       (publickey).` is untouched); or scheme-less credential form (an `@`
       with a `:` before it, e.g. `x-access-token:T@github.com/o/r.git`).
     * Wrapper rule (allowlisted): if the token's first byte is a quote Q
       (' " `) AND the token ends with Q, or with Q followed by exactly one
       byte from `:` `,` `)` `]`, the candidate is the bytes between the
       first byte and that final Q (internal Q bytes stay inside it as URL
       content) and the leading Q + final Q + allowlisted byte are kept as
       wrapper. ANY other shape — a quote-led token without such an ending,
       anything after the final Q other than one allowlisted byte, a second
       trailing byte — replaces the WHOLE token with `[redacted-url]`
       without calling `_bd890_dest_id`. A token not led by a quote is a
       candidate in full.
     * Candidate → `_bd890_dest_id <candidate>` (the production function;
       no second copy of the strip). If it fails, or its output matches the
       backstop glob `*'?'*|*'#'*|*://*@*|*'@'*':'*|*':'*'@'*`, the WHOLE token
       (wrapper included) becomes `[redacted-url]`.
     * Non-URL tokens are copied byte-for-byte; status markers (`[remote`,
       `rejected]`, `(non-fast-forward)`) are never URL-shaped. A wrapped
       `(https://u:p@h/x)` becomes its redacted dest-id or `[redacted-url]`;
       the secret is absent either way.
     * Git's `fatal: unable to access 'https://…/': …` token is
       `'https://…/':` → candidate between the quotes, output
       `'<dest-id>':`.
     * bash-3.2-safe (awk or while-read; no bash-4 constructs).
     Cap: reuse only the iconv/tr repair at dispatcher-commit-block.sh:956-960,
     never the `${LITMUS_FINDINGS:0:1500}` prefix (:955) and never
     `LC_ALL=C ${var:0:N}` alone on multibyte text — a prefix of the live
     remote-first concat can drop `[remote rejected]` / `[remote failure]` /
     the parenthetical. Reserve the winning marker + decisive reason inside
     1500 bytes; shorten non-decisive fields first (long refname middle,
     supporting remote: prose, trailing noise) with an explicit `…[truncated]`;
     if the decisive parenthetical alone exceeds the remaining budget, keep the
     marker + a UTF-8-safe prefix of it + truncation mark (bounded faithful
     form). Flatten newlines so `bail_reason` stays one JSON string; the
     dispatcher's trailer is appended after and never sliced.
  5. Set PUSH_DIAG, PUSH_BAIL_CATEGORY, PUSH_BAIL_PREFIX. Never invent
     full_ref / NEW_COMMIT_SHA / pre_push_tip / push_dest_id / push_repo_id.
```

**Implementation approach (checklist):**
1. `push-dest-id.sh` sourced in the lib block; `PR_HEAD_*` validated once there (every invocation); pin `full_ref` + one effective push URL; credential and PR-tuple checks; `PUSH_URL` kept only for the pre-push byte-compare.
2. `refs/heads/*` + `git check-ref-format` (no `--`).
3. Step 9 snapshot; Step 10 immutable capture (≠ snapshot, object-format hex) and `RESULT_COMMIT_SHA`; Step 10a on the object with the reset-free reason; one branch check; fetch eligibility; bounded optional tip; push-URL revalidation; one push with the three `-c` knobs.
4. Classifier rewrite per the algorithm (arm order, client-status anchors, winning evidence, redaction grammar, UTF-8 cap) and the updated diag test.
5. `scripts/pr-head-identity.sh`, the one contained Step 0 `gh` call, START invocation-URL record, literal `PR_HEAD_*` hand-off, and the SKILL.md "Push bail recovery (manual only)" section. Also in SKILL.md:
   - the SKILL.md:340-351 invocation block moved out of the ```text diagram into its own ```bash fence ("Dispatcher invocation (envelope wrapper)", right after the diagram), wrapped by the envelope wrapper between its two marker comments, with the diagram keeping a one-line pointer;
   - the BAIL bullet (SKILL.md:893-894) surfacing the `ENVELOPE_FILE=` and three `RECOVERY_*=` lines next to `RESULT_BAIL_REASON`.
6. `_bd890_read_one_push_url` in `push-dest-id.sh`, used at the pin, the Step 11 revalidation and recovery steps 2–3, and added to the success-path `unset -f` list. The two Step 10a contexts: `_grind_bail_ctx` on the mismatch arms, `_grind_verify_ctx` on the read-failure arms.

**Why this fixes #890:** no dependence on upstream tracking or `pushDefault`/`push.default`; no new GitHub API call beyond extending Step 0's existing query; no new `PR_BRANCH` env (Option B not adopted); explicit SHA:ref on named `origin` bound to the PR home; classifier owns diagnostics; exhaustive manual recovery; automation never retries, resets or forces.

## Design Constraints

- No force push; no automatic retry/reset; one automatic push attempt.
- Immutable SHA contract: one `NEW_COMMIT_SHA` from pinned `full_ref` right after a successful commit, before trailer verify; `RESULT_COMMIT_SHA` set in the same breath; no HEAD recapture; unverifiable identity → STOP before push.
- No new `PR_BRANCH` env (branch identity stays Step 0 + pin). `PR_HEAD_HOST/OWNER/NAME` are repository-identity hand-off only.
- **Branch vs repository:** `resolve-pr-worktree.sh:202-216` asserts only `WT_BRANCH == PR_BRANCH` and `WT_SHA == PR_HEAD_SHA` — revision identity on a checkout, not a GitHub host/owner/repo; two repositories can contain the same commit. Forks are refused earlier (`isCrossRepository`, SKILL.md:974-1010), which still does not bind `origin` to the PR home.
- **Destination identity (option A):** exactly one effective push URL is required before Litmus/commit/push. It is the actual endpoint, pinned as `PUSH_URL` until the Step 11 byte-compare, never logged. `push_dest_id` is credential-safe **display** only — never same-repository proof, never on child argv, never an ls-remote URL. Dest-id equality is not proof (scheme dropped, scp keeps `host:path`, userinfo stripped; grammar under "Display identity").
- **Live evidence (why new identity data is needed):** Step 0 `gh pr view <PR_NUMBER> --json headRefName,headRefOid,isCrossRepository` (SKILL.md:974) has no `url`/`headRepository`; dispatcher inputs (SKILL.md:340-351, dispatcher header :43-48) carry `PR_NUMBER` but no owner/repo/host; `<owner>/<repo>` are Claude template values for the worker context and COMPLETION (SKILL.md:148, 619-627, 1226-1227), not dispatcher inputs; `remote.origin.url` is repo-controlled config.

### Authoritative PR repository (proposed data flow — a contract under review, not proven)

1. **Source: GitHub's PR object, via one contained Step 0 query.** Step 0's two uncontained calls (`baseRefName` at SKILL.md:929; `headRefName,headRefOid,isCrossRepository` at :974) could be answered for different repositories, so they become **one** call at the :929 position:
   `PR_META=$( export GH_HOST=github.com; unset GH_REPO; gh pr view <PR_NUMBER> --json baseRefName,headRefName,headRefOid,isCrossRepository,url,headRepositoryOwner,headRepository 2>"$BASE_BRANCH_ERR" ) || PR_META=""`
   The containment mirrors the nudge (SKILL.md:625) and is local to that subshell (no Step-0-wide or dispatcher-wide env change). **Consequence:** this call, and so Step 0, becomes github.com-only (today SKILL.md:927/:972 are host-agnostic); a PR on another host BAILs before worktree creation (fail-closed) — residual **R7**. "No dispatcher-wide `GH_HOST` pin" refers to the dispatcher only. **Order inside Step 0:** the existing reads, `isCrossRepository` validation and fork refuse (SKILL.md:986-1000, existing message) from `PR_META` first; only then is `PR_META` piped to `scripts/pr-head-identity.sh` (no inline jq of identity fields; non-zero exit stops before worktree creation). `BASE_BRANCH` comes from `PR_META` (`jq -r '.baseRefName // empty'`) with normalization, empty-value bail and canonical-base checks unchanged. The :974 block stops calling `gh` and reads `headRefName` / `headRefOid` / `isCrossRepository` from the same `PR_META`. Use `.headRepositoryOwner.login` + `.headRepository.name` (documented sibling fields); do **not** assert `.headRepository.nameWithOwner` (redundant, and canonical case would false-bail mixed-case owners) and do **not** read `.headRepository.owner.login`.
2. **`scripts/pr-head-identity.sh` (new, executable, bash-3.2-safe; the SSOT parse helper for production and tests).**
   - Interface: `PR_META` JSON on stdin; `--pr-number <N>` (required), `--invocation-url <URL>` (optional).
   - Library: sources `"$(dirname "${BASH_SOURCE[0]}")/lib/push-dest-id.sh"` (never an inherited `SCRIPT_LIB`); a failed source, or `declare -F _bd890_pr_identity_valid` failing afterwards → `pr-head-identity: cannot source push-dest-id.sh`, no stdout, non-zero.
   - Checks (all fail-closed): `.url` parses as `https://HOST[:port]/OWNER/REPO/pull/N` with `N` = `--pr-number`; `jq -e '.isCrossRepository == false'` (only the JSON boolean `false` passes; `null`, missing, `"false"`, `true` fail; never `// empty` / `// false`, because jq's `//` treats `false` as absent — SKILL.md:977-979, cited in the helper header); `.headRepositoryOwner.login` / `.headRepository.name` equal `OWNER` / `REPO` (ASCII-lowercased both sides); if `--invocation-url` is given it has exactly the accepted shape `https://HOST/OWNER/REPO/pull/N` (optional single trailing slash; reject `/files`, query, extra segments, trailing `.git`) and the same host/owner/repo/number; host/owner/name pass `_bd890_pr_identity_valid` (the dispatcher's validator, so Step 0 and the dispatcher cannot drift).
   - Output: exactly three lines `PR_HEAD_HOST=…` `PR_HEAD_OWNER=…` `PR_HEAD_NAME=…` (lowercased), exit 0; on failure one `pr-head-identity: <reason>` stderr line, no stdout, non-zero.
   - Tests feed fixture JSON on stdin (never `gh`): accept shapes, mixed-case accept, and every reject (fork flag true / non-boolean / string, url/number mismatch, owner/name mismatch, malformed invocation URL, `/files`, query, extra segment, trailing `.git`, charset rejects).
3. **Host and port:** identity host is the `.url` host (github.com here), never taken from origin. `PR_HEAD_HOST` never carries a port; the PR tuple's port means default 443 (https) / 22 (ssh/scp), so `https://host:8443/org/repo` does not match.
4. **START → Step 0 invocation URL (conversation state, template literal).** START's "Resolve PR #" (SKILL.md:107) records how the PR was named: an all-digit argument or auto-detect → `PR_NUMBER=<N>`, no invocation URL; any other argument is a URL — an argument containing `'` → BAIL `unrecognised PR argument`; otherwise `PR_NUMBER` is the digits of the **first** `/pull/<digits>` segment (none → BAIL before worktree creation) and `PR_INVOCATION_URL` is the argument **verbatim**, never normalized or discarded, so non-accepted shapes reach the helper and are rejected there (the helper is the sole shape validator). Step 0 is a literal bash fence using the `<PR_NUMBER>` placeholder, and shell state does not survive Bash-tool calls (SKILL.md:98-101), so Claude substitutes one of two literal forms, chosen by START's record, never by a shell test:
   - number-only: `… | bash "${CLAUDE_PLUGIN_ROOT}/scripts/pr-head-identity.sh" --pr-number <PR_NUMBER>`
   - URL: `… | bash "${CLAUDE_PLUGIN_ROOT}/scripts/pr-head-identity.sh" --pr-number <PR_NUMBER> --invocation-url '<PR_INVOCATION_URL>'`
   No SKILL.md bash block reads `$PR_INVOCATION_URL` or `$PR_NUMBER` in the identity call. Fail closed when the invocation tuple disagrees with `gh` `.url` or `PR_NUMBER`.
5. **Hand-off to the dispatcher (literal written form).** Step 0 relays the helper's three stdout lines (same stdout contract as `WORKTREE_DIR`). The SKILL.md:340-351 env block — the **only** dispatcher invocation, reached for `needs_more` + staged changes + `RESULT_FIXES` (SKILL.md:320-324; SKILL wait-rounds never call it) — gains three lines in the `PRIOR_COMMIT_SHA` placeholder style, never the `PR_NUMBER="$PR_NUMBER"` expansion form:
   ```
   PR_HEAD_HOST='<PR_HEAD_HOST — literal from pr-head-identity.sh stdout>' \
   PR_HEAD_OWNER='<PR_HEAD_OWNER — literal from pr-head-identity.sh stdout>' \
   PR_HEAD_NAME='<PR_HEAD_NAME — literal from pr-head-identity.sh stdout>' \
   ```
   Values are `[a-z0-9.-]` / `[a-z0-9._-]` after lowercasing, so the single quotes are inert around a substituted value. The quotes exist for the unsubstituted case. Unquoted, `<…>` would parse as shell redirections and fail before the dispatcher runs, which is safe but is not the documented bail. Quoted, an unsubstituted placeholder reaches the dispatcher as literal text, fails `_bd890_pr_identity_valid` and produces the documented `emit_bail env` (loud, fail-closed), never a silent wrong tuple. Test 7e runs exactly this quoted form. The dispatcher's validation site (normative snippet) covers the in-script clean-index / #668 branch (:303-440) because it runs before routing. `_bd890_pr_identity_valid` rules: host `^[A-Za-z0-9.-]+$` with no colon; owner/name non-empty, `^[A-Za-z0-9._-]+$`, no `/`, `%`, space or `+` (encoded / escaped / plus-for-space / `%2F` → env bail); compare lowercased.
   **Grep guards (skill-level test):** in the dispatcher-invocation block (the env block ending `bash "$CLAUDE_PLUGIN_ROOT/scripts/dispatcher-commit-block.sh"`), all three `PR_HEAD_*='<PR_HEAD_*` placeholder lines are present and no `${PR_HEAD_`, `"$PR_HEAD_` or `$PR_HEAD_` occurs; the Step 0 identity call uses `<PR_NUMBER>` / `'<PR_INVOCATION_URL>'` and contains no `${PR_INVOCATION_URL` expansion.
6. **Mismatch:** `_bd890_endpoint_matches_pr "$PUSH_URL" "$pin_repo_id"` false → env bail (no Litmus mutation pre-Litmus, no push). Recovery uses the recorded `push_repo_id=`, never a re-parse of origin.url.
7. **Number-only repository selection (scope statement; unprobed, within the approved boundary).** `gh pr view --help` documents `-R, --repo [HOST/]OWNER/REPO  Select another repository`; `gh help environment` documents `GH_REPO` as the repository "for commands that otherwise operate on a local repository". With `/pr-grind <N>` and `GH_REPO` unset, gh picks PR `N`'s repository from local Git configuration (multi-remote order undocumented). The tuple is still GitHub's answer, so the PR-tuple check still catches every destination error this feature can meet (diverging pushurl / rewrite / overlay, a second URL, a non-default port, `http://`, credentials), but not remotes that all consistently name another repository with a same-repo PR `N` — residual **R5**; URL invocation removes it. No forced URL invocation, no `-R` from local config, no containment expansion.

### Transport URL grammar (one parser contract for `_bd890_transport_cred_ok`, `_bd890_endpoint_identity`, the pin, recovery and unit rows)

`_bd890_transport_cred_ok` returns 0 only for one of these three forms and **refuses everything else** (`http://`, `git://`, `file://`, local paths, any other scheme, any form below that does not match exactly):
- **https:** `https://HOST[:PORT]/PATH` — no `@` anywhere (so no userinfo of any kind, token-as-username included), no `?`, no `#`.
- **ssh:** `ssh://[USER@]HOST[:PORT]/PATH` — at most one `@`, and only before HOST; `USER` matches `^[A-Za-z0-9._-]+$` (colon-free, so never a password); no `@`, `?` or `#` after HOST.
- **scp:** no `://`; split at the **first** `:` (git-push(1) GIT URLS: scp-like `[user@]host.xz:path`, "only recognized if there are no slashes before the first colon"). The pre-colon part is `[USER@]HOST` with no `/`, at most one `@`, `USER` as above; the post-colon PATH is non-empty and contains no `@`, `?` or `#`.
`HOST` matches `^[A-Za-z0-9.-]+$` (no IPv6 brackets); `PORT` is digits. Because the split is at the first colon, `user:secret@github.com:o/r` has Git host `user` and a PATH containing `@` → refused, never read as github.com. `_bd890_endpoint_identity` applies the **same** split, so the host it compares is the host Git connects to. Unit rows: `user:secret@h:o/r` refuse; `git@h:o/r@x` refuse; `ssh://user:secret@h/o/r` refuse; `https://x-access-token:T@h/o/r` refuse; `https://h/o/r?t=1` and `git@h:o/r#x` refuse; `git://h/o/r`, `http://h/o/r`, `file:///srv/r.git`, `/srv/r.git` refuse; `git@h:o/r`, `h:o/r`, `ssh://git@h/o/r`, `ssh://h:22/o/r`, `https://h/o/r` allow.

### Endpoint canonicalization (`_bd890_endpoint_identity` — not dest-id)

- Accepts only what the grammar above accepts; anything else fails closed.
- Drop the colon-free SSH user; ASCII-lowercase host, owner and name.
- Path: strip one leading slash run, trim a trailing `/` run, then strip one trailing `.git`; exactly two non-empty labels must remain (`/org/repo` ≠ `/org/repo/wiki`); the scp path is the repo path.
- Port: rewrite an explicit default port to omitted (https `:443`, ssh `:22`; scp has none). Identity is `(host, port-or-empty, owner, name)`; scheme is not part of identity, so a credential-free HTTPS↔SSH alias matches; any other port (`:8443`, `:2222`, https `:22`, ssh `:443`) never matches the port-less PR tuple.
- Unparseable / empty host / fewer than two labels → fail closed.
- Unit rows: `https://h/o/r/` ≡ `https://h/o/r` ≡ `https://h/o/r.git/`; `https://h/o/r/wiki/` ≢; `git@h:o/r#x`, `ssh://git@h/o/r#x`, `user:secret@h:o/r` → refused; `https://h:443/o/r` ≡ `https://h/o/r`; `ssh://git@h:22/o/r` ≡ `git@h:o/r`; `https://h:443/o/r` ≢ `https://h:8443/o/r`; `https://h/o/r` ≡ `git@h:o/r.git`.

### Display identity (`_bd890_dest_id` — display and redaction only, never identity)

`_bd890_dest_id <url>` prints one credential-free display string and returns 0, or prints nothing and returns non-zero. It is used for the `push_dest_id=` token and as the redaction candidate rewriter. Unlike `_bd890_transport_cred_ok` it accepts credential-bearing inputs, because it exists to sanitize them.
- **Scheme form** `SCHEME://AUTHORITY/PATH[?Q][#F]`. The authority ends at the first `/`, `?` or `#` after `://`. Userinfo is everything up to the **last** `@` in the authority and is dropped, as are the scheme, `?Q` and `#F`. The output is `HOST[:PORT]/PATH`.
- **scp form** (no `://`; split at the first `:` exactly as in the transport grammar): `[USER@]HOST:PATH` gives `HOST:PATH`, with `USER@` dropped.
- **Both forms:** strip a trailing `/` run, then one trailing `.git`.
- **Fail closed:** return non-zero (the caller writes `[redacted-url]` or bails) if the host is empty, or if the output contains `@`, `?`, `#`, `://`, whitespace or a control byte.
- **Unit rows:**
  - `https://x-access-token:T@github.com/o/r.git/` → `github.com/o/r`
  - `https://u:p@ss@h/x` → `h/x`
  - `https://h/o/r?token=T#f` → `h/o/r`
  - `ssh://git@github.com:22/o/r.git` → `github.com:22/o/r`
  - `git@github.com:o/r.git` → `github.com:o/r`
  - `user:secret@github.com:o/r` → non-zero (the first-colon split leaves `@` in PATH)
  - `x-access-token:T@github.com/o/r.git` → non-zero
  - `` (empty) → non-zero

  Every output passes the dispatcher's backstop glob, and Test 8 asserts these rows.

**Rewrites and inherited config (Git-native).** The dispatcher does not model `url.*.insteadOf` / `pushInsteadOf` or parse `GIT_CONFIG_*`; Git applies them (file-backed or inherited) and `get-url` reports the result, which must pass `_bd890_read_one_push_url` (exactly one raw record), the credential check and the PR-tuple match — so a rewrite to another host/owner/name, a non-default port, `http://` or credentials env-bails, and a credential-free HTTPS↔SSH alias of the PR repository passes. Fetch-only rewrites affect only tip eligibility. With an explicit pushurl Git ignores `pushInsteadOf` (git-config(1)); `get-url --push` reflects that. A malformed inherited overlay is Git's error (git-config(1): zero-indexed `GIT_CONFIG_KEY_<n>`/`VALUE_<n>`, "Any missing key or value is treated as an error") → `get-url` fails → env bail (at pin: no commit; at Step 11: durable trailer, commit preserved, no push). Non-URL keys are under the trust assumption.

### Operator recovery (manual only) — published in `skills/pr-grind/SKILL.md`

This procedure is a deliverable: it is added verbatim in substance as `skills/pr-grind/SKILL.md` § **"Push bail recovery (manual only)"**, which the Step 10a reason and the unknown-outcome prefix cite by path. It runs in the clone that still holds the branch, never in the removed ephemeral worktree (SKILL.md:92). It reads **only** the envelope file whose basename the bail message names (`ENVELOPE_FILE=`, see "Durable carrier"), located in that clone's git common directory. It never reads conversation prose, `RESULT_BAIL_REASON`, a grind log, or a re-typed reason. **The whole procedure runs in bash** (`bash --noprofile --norc`; it uses `read -a` and `${a[@]+…}`). In zsh, the macOS default interactive shell, `read -a` is invalid, so the procedure states the bash requirement up front rather than failing to row 4 everywhere.

0. **Enter the main clone and load the installed helpers.** Start a fresh `bash --noprofile --norc` from any directory. Nothing inherited is used: no plugin-root or library variable from the environment, and not the current directory. The three `RECOVERY_*` values are pasted exactly as the bail message printed them. They are bash `%q`-quoted, so each pastes as one inert word even when the path contains `'`, `$`, `` ` `` or spaces.
   ```bash
   bd_stop() { printf 'STOP (no push, reset or rebase): %s\n' "$1" >&2; exit 1; }   # exits this recovery shell
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
   The library root is the installed plugin version that ran the dispatch (see "Recovery library root"), never a checkout's `scripts/lib`. Any STOP here comes before steps 1–4, so nothing is looked up, fetched, switched or pushed. If the operator has lost the bail message, there are no `RECOVERY_*` values and this step STOPs.

1. **Same fresh shell as step 0, pinned object view, non-evaluating extraction, then validation** — before any identity check, lookup, ancestry gate or rebase, never reusing an earlier shell's values:
   ```bash
   export GIT_NO_REPLACE_OBJECTS=1          # same object view as the dispatcher (:97); replacement refs are never pushed
   unset full_ref NEW_COMMIT_SHA PR_NUMBER push_repo_id push_dest_id pre_push_tip tip_lookup reason category trailer env_file env_name bd_orig bd_detached
   env_name='<basename of the ENVELOPE_FILE path in the bail message>'   # closed charset [A-Za-z0-9.-]; the directory comes from Git
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
   Values are assigned by parameter expansion only. There is never `eval`, `source` or an unquoted paste, so a branch name containing `$`, backticks, `;` or `(` is inert data. The only pasted text is the basename. It comes from the `mktemp` template, so its charset is closed, and it is validated against `^pr-grind-bail-[1-9][0-9]*\.[A-Za-z0-9]{6}$` before use. The envelope directory is obtained from Git (in the clone step 0 entered) into a quoted variable. The only paths pasted are step 0's three `%q`-quoted values, which are inert words.
   - `dup=1` (any of the seven keys repeated, including a repeated empty `pre_push_tip=`) or `extra=1` → row 4.
   - `category` must be one of `judgment|env`, else → row 4.
   - **Bail class = an anchored starts-with match of `reason` against a closed allowlist.** It is never an equality test, because the dispatcher writes `"$PUSH_BAIL_PREFIX: $PUSH_DIAG [trailer]"` (live :1285). Each class has an exact `case "$reason" in "<P>"*)` pattern, and the diag that follows can never select a class:
     - **history** (row 2): `judgment` + `git push non-fast-forward; local commit preserved: `;
     - **unknown-outcome** (row 3): `env` + `git push outcome unknown — `;
     - **phrase-level env** (rows 3b/3d): `env` + `git push auth/network/config: `;
     - **pre-push drift** (row 3c): `env` + `dispatcher-commit-block: detached HEAD before push [`, or `dispatcher-commit-block: branch changed before push (`;
     - **trailer** (step 5 only, never the decision table): `env` + `failed to re-scan the commit message for verification; `, `Grind-PR: line is not the exact byte sequence the scanner matches; `, `failed to parse trailers for verification; ` or `Grind-PR: is not an exact trailer on the commit (trailer block: ` (the live Step 10a reasons, :1248-1259);
     - **everything else** → row 4, including `git push rejected; local commit preserved: `, `git push failed; local commit preserved: `, `dispatcher-commit-block: push destination changed after pin [`, and no match at all.
   - Validate:
     - `full_ref` matches `refs/heads/*` and passes `git check-ref-format`;
     - **its short name `${full_ref#refs/heads/}` does not start with `-`**: check-ref-format accepts such a component, and any command given the short name would parse it as an option. No recovery command uses the short name (row 2 switches with `--detach` to a SHA), so this is defense in depth. It is checked here, before any lookup, fetch, switch or hook runs; the dispatcher itself uses only full refnames;
     - `NEW_COMMIT_SHA` is 40/64 lowercase hex;
     - `PR_NUMBER` matches `^[1-9][0-9]*$`, **equals the PR being recovered, and equals the `<N>` in `env_name`**;
     - `push_repo_id` is non-empty (except the trailer class);
     - `git rev-parse --verify "$full_ref"` equals `NEW_COMMIT_SHA` (stale-file guard: the dispatcher never moves `full_ref` after Step 10, so an older round's envelope fails here). Note `push_dest_id` (display only — dest-id equality is never same-repository proof) and the bail category and prefix (the text before the trailer).
   - **Required tokens depend on the bail type.** `full_ref`, `NEW_COMMIT_SHA`, `pr_number`, `push_repo_id` and `push_dest_id` are required for every class except trailer.
     - **Push-attempt bails** (any classifier prefix, or the unknown-outcome prefix) must also carry `tip_lookup=` (`skipped|failed|observed`) and `pre_push_tip=` (empty, or hex when `observed`).
     - **Pre-push bails** (`detached HEAD before push`, `branch changed before push`, `push destination changed after pin`, emitted with `$_dur` only) must carry **neither**. Their absence is expected, and their presence → row 4.
     - **Trailer class** carries exactly `full_ref` and `NEW_COMMIT_SHA`; any other key → STOP. `PR_NUMBER` is the `<N>` of `env_name`, which must equal the PR being recovered. It goes to step 5 and skips steps 2–4.
   - Any other missing, extra (`extra=1`) or invalid token → row 4. Later steps use only these values.
2. **Identity, then a fresh lookup.** The `_bd890_*` helpers were loaded and verified in step 0 from the installed library root; nothing is sourced here. Then read the push URL with the same reader the dispatcher uses: `_rd=0; _bd890_read_one_push_url || _rd=$?`. **STOP** unless all three hold, checked in this order:
   - `_rd` is 0: exactly one raw record. A Git failure, a blank or whitespace entry, or a second record → STOP.
   - `_bd890_transport_cred_ok "$_BD890_ONE_URL"` holds.
   - `_bd890_endpoint_matches_pr "$_BD890_ONE_URL" "$push_repo_id"` holds. This is the recorded PR tuple, not dest-id and not a parse of origin.url.

   Then set `checked_push_url=$_BD890_ONE_URL`, a shell variable only, never printed. A second pushurl, an origin replacement or a credential-bearing URL since the bail → STOP. Look up only with `git ls-remote --refs origin "$full_ref"`, and only if the effective fetch URL (`git remote get-url origin`) passes the credential check and the PR-tuple match (HTTPS fetch + SSH pushurl of the same PR → do look up). Never ls-remote a URL; never pass `push_dest_id` as a URL. Record exactly one outcome:
   - `observed` — exit 0, exactly one row whose second field equals `$full_ref` exactly, object-format hex oid (suffix-only matches ignored);
   - `verified-absent` — exit 0 and no exact row;
   - `failed` — non-zero, timeout, more than one exact row, or malformed oid;
   - `skipped` — fetch URL ineligible, or no lookup run.
   Every "tip" below is a fresh `observed` outcome. `verified-absent` authorizes **no** push (the PR head branch was deleted; recreating it is not this recovery) → row 4. (The dispatcher's envelope `tip_lookup=failed` also covers a ref absent before push.)
   **Ancestry gate (local-only, no fetch)** — evaluated only where a row names "strict ancestor" (rows 3c, 3d); never before row 1 or row 2. "Strict ancestor" means, in order: `git cat-file -e "$tip^{commit}"`; `git merge-base --is-ancestor "$tip" "$NEW_COMMIT_SHA"`; `[ "$tip" != "$NEW_COMMIT_SHA" ]`. Any error, missing object or non-zero → row 4.
3. **Pushing.** When a row allows one manual push, the command is exactly
   `git -c remote.origin.mirror=false -c push.followTags=false -c push.recurseSubmodules=no -c advice.pushUpdateRejected=false push origin "${NEW_COMMIT_SHA:?}:${full_ref:?}"`
   (row 2 uses `"${sha:?}:${full_ref:?}"`). **Empty source = delete:** `:refs/heads/<branch>` deletes the PR head branch (closing the PR); the `:?` guards are mandatory, and no other variable or placeholder may be used. Never bare `git push`, never force. Immediately before **each** manual push (rows 2, 3, 3b, 3c, 3d), in this order, with `c` the commit to be pushed (`$NEW_COMMIT_SHA`, or row 2's `$sha`):
   - **Attribution — byte-identical to live Step 10a (:1247, :1252), under the step-1 `GIT_NO_REPLACE_OBJECTS=1`:** `[ "$(GIT_NO_REPLACE_OBJECTS=1 git rev-list --no-walk --grep="^Grind-PR: ${PR_NUMBER:?}\$" "${c:?}")" = "$c" ]`, and `GIT_NO_REPLACE_OBJECTS=1 git -c trailer.separators=':' log -1 --format='%(trailers)' "${c:?}"` contains the exact line `Grind-PR: $PR_NUMBER`. Failure → row 4.
   - **Destination revalidation** (same rule as the automatic path; switch, rebase and hooks may run in between): run a fresh `_rd=0; _bd890_read_one_push_url || _rd=$?`, then require all of:
     - `_rd` is 0;
     - `_bd890_transport_cred_ok "$_BD890_ONE_URL"`;
     - `_bd890_endpoint_matches_pr "$_BD890_ONE_URL" "$push_repo_id"`;
     - `[ "$_BD890_ONE_URL" = "$checked_push_url" ]` (byte-equal).

     Anything else → row 4, no push.
   Then run the push command above, once.
4. **Decision table** (first matching row wins; exhaustive):

| # | Bail class (from envelope) | Fresh tip vs recorded tokens | Action |
|---|---|---|---|
| 1 | Any | tip == `NEW_COMMIT_SHA` | **Done.** No push, no reset. |
| 2 | History class (step 1 allowlist: the classifier's history-arm prefix, anchored starts-with). The classifier already decided the arm from client status rows, so `remote:` text cannot select row 2. | Foreign tip ≠ `NEW_COMMIT_SHA`, and local `full_ref` still resolves to `NEW_COMMIT_SHA` | **Rebase path (history only).** (a) If `git cat-file -e "$tip^{commit}"` fails, the only retrieval is `git fetch --no-tags --refmap= origin "${full_ref:?}"` — named remote, no URL, no `:<dst>`; the **empty `--refmap=`** stops a configured `remote.origin.fetch` mapping (git-fetch(1); e.g. `+refs/heads/*:refs/heads/*`) from updating any ref; only after the step-2 fetch-URL checks (else row 4). It writes only objects and `FETCH_HEAD`. Require `git rev-parse --verify "FETCH_HEAD^{commit}"` == `$tip` and the object now present, else row 4. (b) **Preconditions, else row 4 with nothing changed:** `git status --porcelain --untracked-files=no` is empty; `for p in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do [ ! -e "$(git rev-parse --git-path "$p")" ] || bd_stop "operation in progress: $p"; done`; and `git rev-parse --verify "$full_ref"` == `NEW_COMMIT_SHA`. **Rebase on a detached HEAD; `full_ref` is never moved locally:** record `bd_orig=$(git symbolic-ref -q HEAD || git rev-parse --verify HEAD)`, then `git switch --detach "${NEW_COMMIT_SHA:?}" && bd_detached=1`, then require `git rev-parse --verify HEAD` == `NEW_COMMIT_SHA` (a post-checkout hook may have moved it), else row 4. Then `git -c rebase.updateRefs=false rebase --onto "$tip" "${NEW_COMMIT_SHA:?}^"` with no branch argument, so it rebases the detached HEAD (`updateRefs=false` stops an operator `rebase.updateRefs=true` from moving `full_ref`; never `pull`, `reset` or `--force`). A conflict → `git rebase --abort`, row 4. (c) `sha=$(git rev-parse --verify HEAD)`. Require, else row 4: `sha` ≠ `NEW_COMMIT_SHA`; `git merge-base --is-ancestor "$tip" "$sha"`; **`git rev-list --count "$tip..$sha"` is exactly `1`**, so a commit injected by a hook during the rebase is never pushed; and `git rev-parse --verify "$full_ref"` still == `NEW_COMMIT_SHA`. Then run the step-3 pre-push checks with `c=$sha` (attribution, then destination revalidation after the switch/rebase hooks), then one manual push of `"${sha:?}:${full_ref:?}"`, never the stale `NEW_COMMIT_SHA`. **Only when `bd_detached=1` (a row-4 exit after the switch, or after the push), return with hooks disabled: `git -c core.hooksPath=/dev/null switch -`.** Exits before the switch never switch (7f(ix)). No post-checkout hook runs on the way back. Then check `[ "$(git symbolic-ref -q HEAD || git rev-parse --verify HEAD)" = "$bd_orig" ]` (the recording expression); a mismatch only prints `$bd_orig` for the operator to restore by hand, and no push depends on it. `full_ref` is never moved, so a failed check leaves the branch, envelope and stale-file guard as before. After a push, local `full_ref` lags the remote by design; the operator fast-forwards it. |
| 3 | Unknown-outcome (exact prefix) | Recorded non-empty `pre_push_tip`, and tip == it | At most one manual push (step 3 command). |
| 3b | Phrase-level env, cause fixed by the operator | Recorded `pre_push_tip` non-empty hex; tip == it; tip ≠ `NEW_COMMIT_SHA` | At most one manual push. Empty `pre_push_tip` never uses 3b. |
| 3c | Pre-push drift/detached — only the reasons `detached HEAD before push` and `branch changed before push` (no `pre_push_tip=`, push never attempted; `push destination changed after pin` is row 4) | Local `full_ref` still resolves to `NEW_COMMIT_SHA`, and tip is a strict ancestor of it | At most one manual push. |
| 3d | Phrase-level env without a pre-push tip (`tip_lookup=skipped` **or** `failed`), cause fixed | Step-2 identity holds; local `full_ref` still resolves to `NEW_COMMIT_SHA`; fresh post-fix tip is a strict ancestor | At most one manual non-force push. |
| 4 | Catch-all: unknown-outcome otherwise (incl. empty `pre_push_tip`); hook / other env / revalidation bails; default judgment; non-history `[rejected]`; history with `verified-absent`/`failed`/`skipped`; any `verified-absent`, `failed` or `skipped` lookup; missing/ambiguous tokens | Anything not claimed above | **STOP.** No push, reset or rebase. Investigate. |

**Why 3d accepts `failed`:** both `skipped` and `failed` mean the envelope carries no pre-push observation (the same outage that failed the push often fails the lookup). 3d decides only from a fresh post-fix observation: if the uncertain failure actually landed the commit, row 1 wins first; if someone else advanced the branch, the tip is not an ancestor → row 4; if the branch moves between lookup and push, the non-force push is rejected and nothing is overwritten. Unknown-outcome never rebases and never uses 3d. **Hard separations:** rebase only in row 2; row 1 always first; row 4 for everything else; automation never retries, resets or forces.

5. **Trailer class only — discard the unattributed commit, never push it.** This step runs after steps 0–1 instead of steps 2–4. It replaces the live HEAD-relative `reset --soft` advice (:1215), which in a fresh shell could rewind whatever branch HEAD is on. It is a local compare-and-swap on `full_ref` alone. It never touches HEAD, the index, the working tree or the remote:
   ```bash
   bd_parent=$(git rev-parse --verify "${NEW_COMMIT_SHA:?}^1^{commit}") || bd_stop "no parent"
   ! git rev-parse -q --verify "${NEW_COMMIT_SHA:?}^2" >/dev/null || bd_stop "merge commit"
   git update-ref -m "pr-grind: discard unattributed ${NEW_COMMIT_SHA:?}" "${full_ref:?}" "$bd_parent" "${NEW_COMMIT_SHA:?}" \
     || bd_stop "full_ref moved since the bail"
   ```
   The old value is checked atomically, so a branch moved since the bail is never rewound. Step 1's `GIT_NO_REPLACE_OBJECTS=1` pins the parent read. The commit stays in the reflog. If `full_ref` is checked out somewhere, that tree keeps the commit's changes staged and nothing is lost, which is the same effect as the live `reset --soft`. No lookup is needed because nothing is pushed. Then fix the hook and re-grind: Step 0's `resolve-pr-worktree.sh:213-216` SHA check sees local == PR head again. Pushing the bailed commit is never a recovery, because that would bypass Rail A (ADR 0036).

## Testing Plan

All dispatcher-path tests extend `tests/test-dispatcher-commit-block.sh` on `make_dispatcher_fixture`; never call `gh`. `write_default_plugin_root` MUST symlink `scripts/lib/push-dest-id.sh` beside the classifier (as at :175-193). `run_dispatcher_capture` MUST export `PR_HEAD_HOST=github.com PR_HEAD_OWNER=bd890-fixture PR_HEAD_NAME=repo` (overridden per test for mismatch cases).

**Fixture migration (both dispatcher-running suites — mandatory, not per-test):**
- `make_dispatcher_fixture` (:221-223), in order: (1) right after `git init --bare -q "$remote"` and **before any push**, create and `export` a test-only `GIT_SSH_COMMAND` adapter serving `$remote` (the :223 seed push `git push -q -u origin main` would otherwise target the real github.com); (2) `git remote add origin ssh://git@github.com/bd890-fixture/repo.git`; (3) seed through the adapter. `run_dispatcher_capture` (`env "${env_args[@]}" bash "$SCRIPT"`, no `-i`) inherits it. Do not leave filesystem `origin "$remote"` as the happy-path default; pin-refusal tests may `git remote set-url origin "$remote"` and run without the adapter.
- `tests/test-litmus-mode-transition.sh` section 11 runs the real dispatcher: `dispatch_sandbox` (:371-374) adds a local-path origin and seeds with `git push -q -u origin HEAD`; `DISPATCH` (:392-396) passes `PR_NUMBER=1` and no `PR_HEAD_*`. Unmigrated, every dispatch env-bails at the pin. Required: the same adapter created and exported right after `git init -q --bare "$S.remote"` and before the seed push, origin `ssh://git@github.com/bd890-fixture/repo.git`, seed through the adapter; `PR_HEAD_HOST=github.com PR_HEAD_OWNER=bd890-fixture PR_HEAD_NAME=repo` in `DISPATCH`; `new_sandbox` already copies `$SRC/scripts/lib/.` (:41). The section-11 assertions (block success, retire, one provider call, `Grind-PR: 1` commit, stall/legacy bails, same-mode legacy success) keep their meaning; success additionally means the push landed in `$S.remote`. Its cases run at top level (:369-418), so each case (`dispatch_sandbox` + `DISPATCH` + checks) is wrapped in a function owning the `local -x` list below, keeping the top-level `check` accounting.
- **Direct invocations:** `test_p_pre_dispatch_baseline` (:738-741, expects the judgment "clean index" bail) and `test_ak_signal_stops_reviewer_before_releasing_lock` (:1556-1559) call `bash "$SCRIPT"` directly; both add the three `PR_HEAD_*` values to their env. A guard test checks every direct `bash "$SCRIPT"` dispatcher call **per call site, not per line**. The enclosing function, or the env block or `env_args` array feeding that call, must contain `PR_HEAD_HOST=`. `run_dispatcher_capture` (:255) satisfies this through its `env_args`, which carry the three `PR_HEAD_*` values. The single named exception is t1 and its helper `run_dispatcher` (:268-269, a bare `bash "$SCRIPT" 2>&1 | tail -n 1` used only by t1 at :276-279), which expects an earlier env bail. Any other call site lacking it fails the guard.
- **Adapter contract:** the sandbox sets `ssh.variant=ssh` (no `-G` probe). The adapter skips leading options (`-o X`, `-p N`, `-4`, `-6`), treats the last argument as `git-receive-pack '<path>'` / `git-upload-pack '<path>'`, maps the path to the sandbox bare repo, and exits non-zero on any other shape. The `ssh://git@github.com:22/…` row (7e) runs on real Git to confirm `-p 22` handling. Production has no knowledge of the adapter (ordinary SSH config under the trust assumption) and reads no disable-identity env.

**Isolation and leak guards (both suites; test-harness only, production never reads or sets these, ADR 0016 untouched).** Every dispatcher-running fixture exports `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1` (a global `url.*.insteadOf` could otherwise reach the real host). Command-scope baseline, at the top and at the start of every test: `unset GIT_CONFIG_PARAMETERS`, unset every `GIT_CONFIG_KEY_*`/`GIT_CONFIG_VALUE_*` (enumerated with `compgen -e`), `export GIT_CONFIG_COUNT=0`; fixtures needing an overlay (7c, 8b) set it only in the test body or as an `env` prefix on the single dispatcher call. Every `test_*` (and section-11 case function) that builds a fixture first declares `local -x GIT_SSH_COMMAND GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM GIT_TERMINAL_PROMPT GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0` (index 0 is the only overlay index used), so the helper's `export` dies with the test. After each test the runner asserts `GIT_SSH_COMMAND`, `GIT_CONFIG_PARAMETERS` and every `GIT_CONFIG_KEY_*`/`VALUE_*` are unset and `GIT_CONFIG_COUNT` is `0`. Repo-local `user.*` / `commit.gpgsign` are already set per sandbox.

**Offline transport contract (both suites).** No fixture may reach a real host.
- **Never push over HTTPS.** Every fixture whose push runs has an SSH/scp effective push URL served by the adapter. HTTPS push URLs appear only in cases that bail before any network op, or in unit rows on strings. The pin-success origin is `ssh://git@github.com/bd890-fixture/repo.git`; there is no HTTPS alternative.
- **HTTPS effective fetch URL ⇒ forced-offline lookup.** Where the fetch URL must stay HTTPS (5b, 7c no-pushurl alias, 8b positive control), the test sets `GIT_TERMINAL_PROMPT=0`, unsets `NO_PROXY`/`no_proxy`, and sets sandbox-local `http.proxy=http://127.0.0.1:1` (closed port).
- **Expectation split on the wrapper (same environment as the dispatcher, after the :110 PATH prepend):** the test sources `push-dest-id.sh` and calls `_bd890_select_tip_wrapper`. If it returns 0 (a `-k` wrapper exists — always so on Ubuntu CI, where `/usr/bin/timeout` supports `-k`, so the "ran" half is required in CI), the envelope must say `tip_lookup=failed` (eligible, ran, refused offline). If it returns non-zero (e.g. stock macOS without `timeout`), the envelope must say `tip_lookup=skipped` and a `GIT_TRACE` file must show no `ls-remote` and no `remote-http`/`remote-https` run. A missing system `timeout` is never itself a suite failure. In either branch, `observed` or `verified-absent` fails the fixture (a real host answered).
- Tip results are read from a bail envelope: a bare-remote `pre-receive` hook rejects the push.

**Local-bare vs PR tuple:** `_bd890_endpoint_matches_pr` never treats a filesystem path or `file://` as the PR home, so identity/pin-success/object-delivery tests never use `git remote add origin "$remote"` as the listed URL. Pin-refusal tests (unparseable, path origin, wrong owner) expect an env bail at the pin and do not set the adapter. Predicate unit tests use synthetic URL strings; identity parsing uses JSON fixture files.

**Unit vs integration (mandatory split).** Unit: call `push_failure_classify`, `_bd890_read_one_push_url` (inside a temp repo whose `remote.origin.*` config produces each shape; table below), `_bd890_dest_id`, `_bd890_transport_cred_ok`, `_bd890_endpoint_identity`, `_bd890_endpoint_matches_pr`, `_bd890_pr_identity_from_env`, `_bd890_select_tip_wrapper` directly with synthetic stderr or an injected wrapper mode, so absent-`timeout`/`-k` paths and arm/diag/cap retention are proven without fighting the :110 PATH prepend, `bash -p` or `unset -f`. No git shim, no env switch that disables PATH/deadline safety, never a copied dest-id sed. Integration: classification stderr comes from **real Git** (bare-remote `pre-receive`/`update` hooks or `ext::` helpers). Unit scope also covers every predicate's 0 = safe polarity (unsafe input → env envelope under `set -u`), the `_bd890_select_tip_wrapper` empty-array / `-k`-required / no-`-k` → skip cases, and a SIGTERM-ignoring child returning within the limit.

**`test_k_push_failure` split:** k-pin — origin absent or listed URL a local path / unparseable → env bail at the pin, no commit, no `NEW_COMMIT_SHA=` in the reason. k-push — origin matches `PR_HEAD_*`, commit succeeds, `git push origin` fails with auth/network/config (adapter or real-Git hook, never PATH git) → trailer has `full_ref=`, `NEW_COMMIT_SHA=`, `pr_number=`, `push_dest_id=`, `push_repo_id=`. Do not reintroduce `contains("git push failed")` as the missing-remote expectation.

### Test 1: No-upstream push succeeds
Origin matches `PR_HEAD_*` (ssh form + adapter); `git branch --unset-upstream`; `push.default=simple`; `push.autoSetupRemote=false`; assert `! git rev-parse --abbrev-ref '@{u}'`; stage + `run_dispatcher_capture`; assert success and bare remote `refs/heads/main` == new SHA.

### Test 2a: Negative control — pre-#890 bare `git push`
Inside one `test_*`: copy the script to temp, restore **only** a bare `git push` (no `origin`, SHA:ref or `-c`), keep `CLAUDE_PLUGIN_ROOT`/`SCRIPT_LIB`; `local SCRIPT="$temp_copy"` then one `run_dispatcher_capture` (dynamic scope; never re-exec the suite); Test 1 fixture; assert `env` and a reason substring that survives the bound (`--set-upstream` or `no upstream`). Update `test_890_negative_bare_push_no_upstream`'s python `old` to the live :1276-1279 after `recurseSubmodules=no` lands, then replace that region with the bare push for this test only.

### Test 2b: `push.recurseSubmodules=no` is load-bearing
Temp copy keeps named `origin` SHA:ref and the other `-c` knobs, deleting only `-c push.recurseSubmodules=no`; fixture with `push.recurseSubmodules=only` **and a real dummy submodule** with its own bare remote (config-only is insufficient); the copy does not advance the superproject `full_ref` as production does, or publishes the submodule; production advances `full_ref` to `NEW_COMMIT_SHA` and leaves the submodule remote unchanged. Do not assert no-upstream here.

### Test 3: Judgment classes (real Git)
- **3a History divergence:** a second clone advances bare `main` (sandbox never fetches); stage a divergent fix; one run; `judgment`, reason contains `(fetch first)` **or** `(non-fast-forward)`, "local commit preserved", local fix SHA preserved, no auto-retry. Assert classification + preserved SHA + no retry, not one Git version's spelling (`[rejected]` or history-class `[remote rejected]`).
- **3b True non-fast-forward (own fixture):** advance the bare remote and `git fetch origin` while a change is still staged; one run (Steps 9 and 11 both run with the tip known); `judgment`, `(non-fast-forward)`, commit preserved. Never re-invoke on a clean index (that takes the #668 path).
- **3c Hook declined (mandatory):** pre-receive exits 1 with a distinctive `remote:` line (e.g. `remote: GH006 test-hook`); `judgment`, reason contains `[remote rejected]` and the bounded hook text, not `non-fast-forward`. Negative control: a decline whose `remote:` text or refname contains `network` / `timeout` / `deploy timeout` → still `judgment`, prefix not `git push auth/network/config`.

### Classifier unit fixtures (synthetic stderr → `push_failure_classify`)
- **Env positives:** every closed-list phrase on client lines → `env`, `git push auth/network/config`; history still wins when a client `(fetch first)` row is also present. Integration: at least one auth/transport failure and one hook negative flow through the dispatcher push with trailer tokens.
- **Hook guards (mandatory):** `remote:` containing `Connection refused` / `Recv failure` / `Authentication failed` / `remote failed to report status` / `(fetch first)` beside a real `! [remote rejected] … (hook declined)` → `judgment` / `git push rejected`. Client hook-declined + `remote: Permission to owner/repo.git denied` → hook/judgment (not env, so never row 3b). `! [remote rejected] refs/heads/main -> refs/heads/main (cannot lock ref 'refs/heads/main': …)` + `remote: Connection refused` → `judgment`, `git push rejected`. Only `remote: error: hook declined` with no client row and no env phrase → `judgment`, `git push rejected`.
- **Unknown-outcome:** `! [remote failure] … (remote failed to report status)` → `env` + the exact prefix, asserted byte-for-byte (ending `see skills/pr-grind/SKILL.md section Push bail recovery`); the parenthetical survives the cap. Mixed: hung-up/reset/recv fatal **plus** `[remote failure]` → unknown-outcome, not env. Integration when feasible (receive-pack or `ext::`): bail contains `full_ref=`, `NEW_COMMIT_SHA=`, `pr_number=`, `push_dest_id=`.
- **Pipefail / cap (under `set -euo pipefail`):** drain-safe ifs (early token + >64KB trailing payload); zero-match extractor → default judgment envelope; multi-match + `|| true` → one envelope; one ~200KB `remote:` line with the winning status **last** → redaction + UTF-8 cap without the `:0:1500` prefix, one parseable envelope, marker + reason retained (or bounded faithful prefix + truncation mark); hung-up + `[remote failure]` and auth fatal + `(fetch first)` keep their marker/parenthetical after the cap; long `refs/heads/*` refname; multibyte UTF-8 in status/remote text; parenthetical alone larger than the remaining budget → marker + UTF-8-safe prefix + mark.
- **Redaction (secret absent from both `PUSH_DIAG` and the emitted `bail_reason` in every row; synthetic marker `BD890SYNTHTOKEN`):**
  - HTTPS userinfo, `?token=`, fragment, scp `user@host:path` → raw token absent.
  - Quoted: `fatal: unable to access 'https://x-access-token:BD890SYNTHTOKEN@github.com/o/r.git/': The requested URL returned error: 403` → `env`; keeps `fatal:` and `returned error: 403`; contains the redacted `github.com/o/r` between the kept `'` and `':`; no `x-access-token`.
  - `! [remote rejected] main -> main (pre-receive hook declined)` + `remote:` prose echoing `https://u:BD890SYNTHTOKEN@h/x?token=BD890SYNTHTOKEN` → marker and parenthetical byte-for-byte, secret absent.
  - Scheme-less `x-access-token:BD890SYNTHTOKEN@github.com/o/r.git`, raw and as a (buggy) dest-id result → `[redacted-url]`; legitimate scp dest-id `github.com:o/r` passes the glob.
  - Split-leak: `https://u:pa,ss@h/x`, `https://h/x?token=a,b;c`, `(https://u:p@h/x)`.
  - Apostrophe: userinfo `https://u:pa'BD890SYNTHTOKEN@h/o/r.git` and query `https://h/o/r?token=pa'BD890SYNTHTOKEN`, bare and wrapped in `fatal: unable to access '<url>': … 403` → secret and `pa'` absent; the wrapped row still classifies `env` and shows the redacted `h/o/r` in its wrapper (or `[redacted-url]`).
  - Wrapper allowlist: `'https://h/x?t=a'BD890SYNTHTOKEN` and `'https://h/o/r'):BD890SYNTHTOKEN` → whole token `[redacted-url]`; `'https://h/o/r',` and `"https://h/o/r")` keep their wrapper; an unbalanced quote-led token with no closing quote → `[redacted-url]`.

### Test 4: Explicit destination vs config
Bogus `remote.pushDefault` → named origin SHA:ref still updates `refs/heads/main`; `remote.origin.mirror=true` with seeded `refs/heads/sentinel` → main advances, sentinel unchanged; `push.followTags=true` + reachable annotated tag → tag absent remotely; `push.recurseSubmodules=only` with a dummy submodule and its own bare remote (mandatory) → production advances `full_ref` to `NEW_COMMIT_SHA` without publishing the submodule, a copy without the `-c` does not satisfy that (exact `push_ret` unverified).

### Test 5: Local-only commits not misreported
After a rejected push, stub `fetch-pr-state.sh` so `HEAD_FULL_SHA` is the bare remote's pre-push oid and re-invoke on a clean index → `result_commit_sha == "none"`; inverse stub matching the local unpushed oid → that oid reported.

### Test 6: Pin / recheck / verified-SHA safety
1. Detached HEAD before dispatch → `env`, no new commit.
2. **Post-commit branch switch:** a post-commit hook checks out another branch; Step 10 captures `NEW_COMMIT_SHA` from `full_ref` (live :1198 uses HEAD — the delta); the single Step 11 branch check → `env` bail with `$_dur` tokens and no `pre_push_tip=`; bare remote unchanged; no push.
2a. **Trailer verify precedes the drift bail:** 6.2 plus a `commit-msg` hook stripping `Grind-PR:` → the Step 10a bail with the **new** reason: contains `full_ref=` and `NEW_COMMIT_SHA=`, `Do NOT push this commit`, `step 5 (discard)` and `skills/pr-grind/SKILL.md section Push bail recovery`; contains neither `reset --soft` nor `HEAD~1`; no `pr_number=`/`push_dest_id=`/`push_repo_id=`/`pre_push_tip=`/`tip_lookup=`; not the drift envelope. `full_ref` still resolves to `NEW_COMMIT_SHA`, the branch HEAD moved to is unchanged, no reset ran, bare remote unchanged. Companion with HEAD still on `full_ref`: same reason, same absences. The existing `test_grind_f_verification_bail_names_unpushed_commit` (tests/test-dispatcher-commit-block.sh:1858-1891) is kept unchanged and must pass. Its commit-msg hook hits the rev-list mismatch arm, whose reason still contains the SHA, `UNPUSHED` and `commit-msg`. It also gains one assertion: the reason contains neither `reset --soft` nor `HEAD~1`.
2c. **Step 10a read-failure arms (unit, temp copy):** a temp copy forces the rev-list re-scan to fail, and separately the `%(trailers)` parse. Each yields `env` with the `_grind_verify_ctx` text: it contains `cannot verify the Grind-PR: trailer`, `UNPUSHED`, `Do NOT push this commit`, `step 5 (discard)` and the `full_ref=` / `NEW_COMMIT_SHA=` tokens, and it does **not** contain `commit-msg hook altered`.
2d. **Step-5 discard (design fixture):** after the 2a bail, steps 0, 1 and 5 in a fresh shell leave `full_ref` == `pre_commit_tip`, HEAD/index/tree and the bare remote unchanged, and `resolve-pr-worktree.sh`'s SHA check then passes. `full_ref` moved after the bail → the CAS fails, STOP, nothing changed. A trailer-class envelope carrying any `pr_number=`/`push_*`/`pre_push_tip=`/`tip_lookup=` token → STOP. No step-5 path pushes.
2b. **Pre-commit branch switch:** HEAD leaves `full_ref` between pin and commit; `full_ref` still names `pre_commit_tip` → env bail (`NEW_COMMIT_SHA == pre_commit_tip`), the old oid never labelled the fix; bare remote unchanged.
3. **HEAD mutation after capture (attached):** Test-2-style temp copy inserting `git update-ref "$full_ref" "$OTHER_SHA"` between the Step 10 capture and the push while staying attached; the remote updates to the **captured** SHA. Forbidden: detaching or switching branch (never reaches the push), production test hooks, PATH-weakening shims. A pre-push hook creating a descendant does not by itself prove capture timing.

### Tip / destination / recovery fixtures
1. Exact-ref lookup via `git ls-remote --refs origin` when the fetch URL is eligible: `$2 == full_ref`, single hex oid.
2. Partial stdout failure → empty tip. 3. Suffix collision → only the exact ref. 4. Wrapper timeout / pipeline failure → empty tip (`failed`).
5. **No `-k` wrapper (unit):** neither wrapper, or one without `-k` → skip, empty tip; never via PATH hiding of the full dispatcher; never an unbounded or no-`-k` fallback. 5a. SIGTERM-ignoring child returns within the limit (unit).
5b. **Fetch ≠ push, both PR-bound** (HTTPS fetch + SSH pushurl) → no env bail; tip not skipped for dest-id inequality; push still `origin` + SHA:ref; no URL on argv; integration under the Offline transport contract with the wrapper-split expectation. A fetch URL failing the PR tuple → `skipped`, no bail.
6. Drift/detached pre-push bails carry `$_dur` and no `pre_push_tip=`.
7. **Multi-URL refuse:** `get-url --push --all` ≠ 1 (two pushurls, or two urls without pushurl) → env bail before commit; remote unchanged.
7b. **Post-pin destination mutation:** a post-commit hook replaces `remote.origin.pushurl` or adds a second URL → bail before push; remote unchanged.
7c. **Rewrites via Git's effective URL:** a file-backed `insteadOf`/`pushInsteadOf`, an inherited `GIT_CONFIG_COUNT` pair, or `GIT_CONFIG_PARAMETERS` that retargets host/owner/name, adds a non-default port, injects credentials or targets `http://` → env bail before any network op. Fetch-only HTTPS→SSH `insteadOf` (repo-local or inherited, never global) with an explicit SSH pushurl → no bail, tip not skipped while the fetch URL matches. Unrelated rewrite keys allowed. Explicit pushurl + matching `pushInsteadOf` → the listed pushurl is used. No pushurl + a credential-free HTTPS→SSH `pushInsteadOf` alias of the PR repo → push succeeds over the adapter (HTTPS fetch stays under the offline contract); dest-id from the effective URL; `push_repo_id` is the PR tuple; the same alias as an inherited `GIT_CONFIG_COUNT` pair (`KEY_0`/`VALUE_0`) also succeeds (no blanket overlay refusal). `GIT_CONFIG_COUNT=1` without `KEY_0` → Git error, env bail, no push. The push lands where get-url said (documented resolution, R2).
7d. **Recovery fanout/creds (design fixture):** after a bail, a second pushurl, an origin replacement or a credential-bearing effective URL → STOP before any operator command; a dest-id match alone is insufficient when the effective URL no longer matches `push_repo_id`.
7e. **PR tuple vs origin:** effective push URL on another host/owner/name, or `https://host:8443/…` → env bail before push. Missing/malformed `PR_HEAD_*`, and unsubstituted placeholder text (`PR_HEAD_HOST='<PR_HEAD_HOST — literal …>'`) → `emit_bail env` from the single validation site (reason `missing/malformed PR_HEAD_HOST/OWNER/NAME`) both for a fix round with staged changes and for the in-script clean-index branch (`RESULT_STATUS=needs_more`, clean index), with no Litmus init and no review-lock change. Mixed-case scp/`ssh://` vs lowercase owner/name → match; `ssh://git@github.com:22/…` → match. HTTPS mixed-case and `:443` rows are unit rows only. The SKILL.md grep guards belong to this group.
7f. **Operator lookup outcomes and table (unit/design fixtures):** the four outcomes (exit 0 + one exact row → `observed`; exit 0 + no exact row, suffix-only included → `verified-absent`; non-zero / timeout / two exact rows / malformed oid → `failed`; ineligible fetch URL → `skipped`). Required: `verified-absent` → row 4 for every class; fresh tip == `NEW_COMMIT_SHA` → row 1 for every class, including unknown-outcome with empty `pre_push_tip`; drift bail with `skipped`/`failed`/`verified-absent` → row 4, never 3c; env bail with `tip_lookup=failed` reaches 3d like `skipped`; unknown-outcome with empty tip → row 4 unless row 1; rows 2/3/3b/3c/3d with a commit failing attribution → row 4; attribution with `PR_NUMBER` from `pr_number=` passes for a legitimate fix commit; ancestry gate with a missing tip object → row 4; row 2 with a missing tip object → guarded fetch only when the fetch URL passes both checks, `FETCH_HEAD` ≠ tip → row 4, `full_ref` unchanged; row 2 rebases only a detached HEAD at `NEW_COMMIT_SHA`, only in the `git rebase --onto "$tip" "${NEW_COMMIT_SHA:?}^"` form, a conflict aborts to row 4, then `sha` ≠ `NEW_COMMIT_SHA` with `$tip` an ancestor of `sha`, else row 4; local `full_ref` == `NEW_COMMIT_SHA` throughout; a fresh shell assigns the step-1 variables from the envelope before any lookup, and a missing `full_ref`, `NEW_COMMIT_SHA`, `pr_number` or `push_repo_id` → row 4 with no lookup. (i) Branch `refs/heads/x$(touch${IFS}PWNED)` (fixture first asserts `git check-ref-format` accepts it; created with `git update-ref`) plus a diag holding a fake earlier `[full_ref=refs/heads/evil …]` group: step 1 assigns the real trailer's values, the refname stays data, `PWNED` is never created; the backtick variant `` refs/heads/x`touch${IFS}PWNED2` `` likewise. (ii) Repo-local `trailer.separators='#'` + a legitimate `Grind-PR: <n>` commit → attribution passes. (iii) `refs/replace/<NEW_COMMIT_SHA>` → an attributed impostor while the real commit lacks the trailer → row 4. (iv) `remote.origin.fetch=+refs/heads/*:refs/heads/*`, foreign tip missing → the `--refmap=` fetch leaves `full_ref` == `NEW_COMMIT_SHA`; `full_ref` moved otherwise before the switch → row 4. (v) A `post-rewrite` (rebase) or `post-checkout` (switch) hook changing `remote.origin.pushurl` → revalidation fails, row 4, no push. (vi) A `post-checkout` hook committing during the detached switch → HEAD ≠ `NEW_COMMIT_SHA` → row 4, no rebase. (vii) A `post-rewrite` hook adding a commit → `rev-list --count` ≠ 1 → row 4, no push. (viii) The "Recovery step-1 fixtures" below. (ix) Dirty tracked file, or `rebase-merge`/`MERGE_HEAD` present → row 4 before any switch, HEAD and `full_ref` unchanged, no `switch -`. (x) In (vi), (vii) and after a row-2 push, `full_ref` == `NEW_COMMIT_SHA` and the hook-less `switch -` restores `bd_orig` (also from a detached start); a committing post-checkout hook does not run on the return. (x-b) Repo-local `rebase.updateRefs=true` → `full_ref` unchanged. (x-c) Classifier-shaped reasons with a diag (`git push non-fast-forward; local commit preserved: ! [rejected] … [trailer]`, likewise each allowlisted class) select their row; a diag merely containing another class's prefix never does. (xi) A drift envelope `dispatcher-commit-block: branch changed before push ('<cur>' != '<full_ref>') [<$_dur tokens>]` with a strict-ancestor fresh tip → **row 3c**, one push; plus a `tip_lookup=` token → row 4; a push-attempt bail without `tip_lookup=` → row 4. (xii) A hook-declined bail whose `remote:` text has `(fetch first)` never reaches row 2. (xiii) Gate-hoist guard: tip == `NEW_COMMIT_SHA` → row 1; a non-ancestor history tip → row-2 rebase. (xiv) An unknown `foo=bar` token → row 4.
8. **Credential-safe display (unit):** production `_bd890_dest_id` on every row of "Display identity" gives exactly the listed output or non-zero. Also: userinfo / `?token=` / fragment / scp `user@host:path` / `ssh://git@host/path` → no userinfo, query or fragment; unsanitizable → env bail at the pin; every zero-return output passes the backstop glob.
8b. **Credential refuse + helper argv (integration):** HTTPS userinfo or `?token=` on the effective **push** URL → env bail before any network op (only local `get-url` reads precede it); plain `http://` → env bail; `ssh://git@host/path` allowed, `ssh://user:secret@` refused. Clean SSH pushurl + tokenized HTTPS **fetch** URL (`https://x-access-token:BD890SYNTHTOKEN@github.com/bd890-fixture/repo.git`), dispatcher run with `GIT_TRACE=<sandbox file>` and a pre-receive rejection: envelope `tip_lookup=skipped`; the trace has no `ls-remote` and no `remote-http`/`remote-https` run; the marker appears nowhere in the trace, envelope or `PUSH_DIAG`. Positive control: the same setup with a clean HTTPS fetch URL under the offline contract follows the wrapper split (with a `-k` wrapper: `tip_lookup=failed` and a `remote-https` trace line, proving the trace can see a helper launch). URL-changing inherited overlays (`GIT_CONFIG_COUNT` index 0, and separately `GIT_CONFIG_PARAMETERS`) that would inject credentials, retarget, or rewrite to `http://` → env bail before any network op, no helper starts. Malformed overlay → Git error → env bail. Credential-free HTTPS↔SSH alias overlay → not refused. Non-URL overlay keys (`core.sshCommand`, `http.extraHeader`) are asserted neither way (R1). Production never unsets `GIT_CONFIG_*`; Test 2 temp copies keep `CLAUDE_PLUGIN_ROOT`/`SCRIPT_LIB`.
9. **Named-remote push:** argv is `origin` + SHA:ref; with `mirror=true` the sentinel survives.

### Raw-record reader (`_bd890_read_one_push_url`, unit table)
Each row runs in a temp repo whose `remote.origin.url` / `remote.origin.pushurl` config produces the listed `get-url --push --all` output. The repo has no adapter and no network; the reader runs only a local config read. Every row runs twice, once with errexit on and once with it off, and asserts the return code and the two variables. On every non-zero return, `_BD890_ONE_URL` is empty.

| Shape (raw stdout of `get-url --push --all origin`) | How produced | Return | `_BD890_ONE_URL` | `_BD890_GIT_RC` |
|---|---|---|---|---|
| `URL\n` | one url | 0 | `URL` | 0 |
| `URL1\nURL2\n` | two pushurls, or two urls without pushurl | 2 | empty | 0 |
| `URL\n\n` / `\nURL\n` | an empty `pushurl` value beside a valid one (if Git prints one; otherwise the row asserts whatever Git prints is not accepted as one record) | 2 | empty | 0 |
| `URL \n`, ` URL\n`, `URL\r\n`, `URL\tX\n` | values with trailing or leading space, CR or tab | 2 | empty | 0 |
| (no remote `origin`) | `git remote remove origin` | 1 | empty | Git's non-zero status, asserted equal to a direct `git remote get-url --push --all origin` run |
| every shape above, plus empty output, an unterminated `URL`, `\n`, `URL\n\nURL2\n` | `_bd890_one_record "<bytes>"` called directly on synthetic bytes (pure function, no Git, no PATH shim) | as above; 2 for the four extra shapes | as above | n/a |

The dispatcher-level fixtures 7, 7b and 7c then assert that a reader return of 1 or 2 at the pin or at Step 11 produces the env bail texts in the snippet, and that the Git status appears in the `(git exit N)` text.

### Envelope wrapper (SKILL.md invocation block, executed)
**Extraction (exact).** In `skills/pr-grind/SKILL.md`, the file must contain exactly one `# bd890-envelope-wrapper:begin` line and exactly one `# bd890-envelope-wrapper:end` line. Both must be inside the **same** ```bash fence, the one in the "Dispatcher invocation (envelope wrapper)" subsection, and that fence must not be inside the ```text Dispatcher Loop diagram. The test takes the lines strictly between the markers, unchanged (no prefix stripping), and fails if any contains `│` (still inside the diagram). The diagram holds the one-line pointer and no `dispatcher-commit-block.sh` invocation. After the template placeholders are replaced with fixture literals (the three `PR_HEAD_*` values, `PRIOR_COMMIT_SHA=none`), `bash -n` must pass on exactly that block (syntax only; not the whole SKILL.md), and the block runs with `bash` under `WORKTREE_DIR`, `PR_NUMBER` and `CLAUDE_PLUGIN_ROOT` = a temp plugin root whose `scripts/dispatcher-commit-block.sh` is a stub with scripted stdout and status. No production file is stubbed. Rows:
1. **Success:** the stub prints two lines and a success envelope and exits 0. The block's stdout is byte-identical (`cmp`) to the file, which is byte-identical to the stub's stdout. Stderr has exactly one `ENVELOPE_FILE=<path>` line. The path is `<git-common-dir>/pr-grind-bail-<PR>.XXXXXX`, mode 0600. The last stdout line is the envelope. The exit status is 0.
2. **Bail:** the stub prints a bail envelope and exits 1. Same byte equality, and the exit status is 1.
3. **Two dispatches:** two runs give two distinct files, and the first is unchanged after the second.
4. **Creation failure:** with `PR_NUMBER=abc`, and separately with `WORKTREE_DIR` set to a non-repository and with a read-only common directory, stdout is exactly the `cannot create durable envelope file` env envelope, the exit status is 1, and the stub never ran (its marker file is absent).
5. **Survives worktree removal:** run with `WORKTREE_DIR` set to a linked worktree, then `git worktree remove --force` it. The file still exists in the main clone's common directory with unchanged bytes.
6. **Hostile root:** a clone whose path contains `'`, `$(touch PWNED3)` and a space. Rows 1–2 still pass, and `PWNED3` is never created.
7. **Not tracked:** after row 1, `git status --porcelain --ignored` in the main clone does not list the file.
8. **Relay failure is non-zero:** the stub prints a success envelope, exits 0, and then makes its own stdout target unreadable by unlinking it: the target is resolved through `/proc/self/fd/1` on Linux (CI). On a platform without `/proc` the row reports **skipped**, never passed. The block's last stdout line is the `envelope file unreadable after dispatch` env envelope and its exit status is **1**, not 0. The same with the stub exiting 3 gives exit 3.
9. **Recovery coordinates:** in rows 1, 2 and 6, stderr also has exactly one each of `RECOVERY_GIT_COMMON_DIR=`, `RECOVERY_CLONE=` and `RECOVERY_LIB_ROOT=`. Each value, evaluated as a bash word in a fresh shell (`bash --noprofile --norc -c 'v=<value>; printf %s "$v"'`), equals the expected path byte for byte, including the hostile root of row 6, and `PWNED3` is never created. With a relative root, `RECOVERY_LIB_ROOT=` is empty. With `BUSDRIVER_PLUGIN_ROOT` and `CLAUDE_PLUGIN_ROOT` set to two different temp roots, and also with `BUSDRIVER_PLUGIN_ROOT` an unexported shell variable, the stub reports the `BUSDRIVER_PLUGIN_ROOT` it received, and `<that>/scripts/lib` equals the decoded `RECOVERY_LIB_ROOT` byte for byte.

### Recovery step-0/step-1 fixtures (design fixtures run against the published SKILL.md snippets)
The step-0 and step-1 snippets are extracted from the section's ```bash fences. `<…>` placeholders are replaced with values captured from the wrapper's stderr, as printed. They run in a **fresh shell**: `env -i HOME="$HOME" PATH=/usr/bin:/bin bash --noprofile --norc`, with no `CLAUDE_PLUGIN_ROOT` and no `SCRIPT_LIB`, started from an unrelated directory. Envelope files are written into a sandbox clone's common directory.

Step-0 rows:
- **Consumer clone, installed root:** the sandbox clone is a consumer repository with no `scripts/lib` in its tree. Pasting the three `RECOVERY_*` values enters the clone and loads every listed helper (each `declare -F` succeeds). A decoy `scripts/lib/push-dest-id.sh` committed in the clone, defining a sentinel function, is never sourced (the sentinel is undefined afterwards).
- **Missing root:** `RECOVERY_LIB_ROOT` names a removed directory, is empty, or is relative → STOP at step 0. A `GIT_TRACE` file shows no `ls-remote`, `fetch`, `switch`, `rebase` or `push`.
- **Broken library:** the file exists but fails to source (a syntax error), or loads without one of the five listed helpers → STOP at step 0, same trace assertion.
- **Wrong clone:** `RECOVERY_CLONE` names another clone whose common directory differs from `RECOVERY_GIT_COMMON_DIR` → STOP.
- **Hostile paths:** a clone path and a library root containing `'`, a space and `$(touch PWNED5)` paste as inert words, the steps succeed, and `PWNED5` is never created.

Step-1 rows:
- **Duplicate keys:** a trailer repeating each of the seven keys in turn (`full_ref`, `NEW_COMMIT_SHA`, `pr_number`, `push_repo_id`, `push_dest_id`, `pre_push_tip`, `tip_lookup`) → `dup=1` → row 4. Repeating an **empty** `pre_push_tip=` also gives `dup=1`. A trailer with each key once gives `dup=0`.
- **Dash-led branch:** `refs/heads/-x` and `refs/heads/--detach` (created with `git update-ref`; check-ref-format accepts both) → row 4 at step 1, before any lookup, fetch or switch. A `GIT_TRACE` file shows no `ls-remote`, `fetch` or `switch`.
- **Basename:** a basename containing `'`, `/`, `..`, a space or a wrong PR number, or a symlink, a missing file, a truncated last line or non-JSON at that name → `reason` empty → row 4.
- **Category:** `bail_category` outside `judgment|env` → row 4. A valid file assigns `category` and `reason` from the same last line.
- **Hostile root:** the clone path contains `'` and `$(touch PWNED4)`. Step 1 still locates and reads the file through `git rev-parse --git-common-dir`, and `PWNED4` is never created.
- **Stale file:** an older round's file whose `NEW_COMMIT_SHA` is no longer `full_ref`'s tip → row 4.
- **Shell:** the section's first instruction names bash; a grep asserts it (SC8).

## Residuals

**Normative above, never re-deferred:** option-A identity and `PR_HEAD_*` hand-off, Git-native pin + revalidation, fetch-vs-push eligibility, predicate polarity (0 = safe, `|| emit_bail`), default ports, lookup outcomes, tip-wrap helper, attached-ref tests, recurseSubmodules `-c`, recovery identity checks, hook-before-permission, pre-commit snapshot, winning-marker cap, dest-id glob, success-path `unset -f`, object-format hex, HTTPS-not-HTTP aliases, credential display, multi-URL refuse, effective-URL credential refuse, skip-tip, named-remote knobs. Fetch==push dest-id narrowing stays **withdrawn**.

**Trust-boundary residuals (accepted per Chris's approval; named, not solved):**
- **R1** Existing Git/SSH transport configuration and environment (helpers, `core.sshCommand`/`GIT_SSH_COMMAND`, `~/.ssh/config`, known_hosts, proxies, `http.*` headers/CA, non-URL keys of inherited `GIT_CONFIG_*`, repository hooks) are trusted as Git trusts them and not defended if already malicious; a malicious `core.sshCommand`, proxy, header or helper could divert or observe the push while the URL checks pass (run `579e93c6` HIGH, recorded not fixed).
- **R2** `git remote get-url --push --all origin` ≡ `git push origin` resolution is documented (git-remote(1)), not source-proven; fixtures 7c/8b exercise it on real Git; do not fetch Git C.
- **R3** `PR_HEAD_*` reaches the dispatcher by template substitution (same trust as `PR_NUMBER`); missing/malformed values bail at the validation site; a wrong-but-consistent tuple is not detectable here. A git-dir identity file is not adopted.
- **R4** Repository-redirect environment (`GIT_DIR`, `GIT_WORK_TREE`, …) is existing dispatcher-wide behavior, unchanged.
- **R5** Number-only invocation: gh selects the queried repository from local Git configuration (item 7); URL invocation removes this; gh's multi-remote order is unverified.
- **R6** Envelope-file retention: one 0600 untracked file per dispatcher invocation accumulates in the git common directory. Nothing deletes it automatically, by design: no deletion path is added. It is invisible to `git status`, never pushed and read by no gate. The operator may remove it after recovery.
- **R7** Step 0 becomes github.com-only. Its gating `gh pr view` runs under `GH_HOST=github.com` (Authoritative PR repository item 1), so a PR on another host BAILs before worktree creation (fail-closed). gh's behaviour under the pin for a non-github.com checkout is unprobed. The operator's repositories are github.com-only.
- **Envelope trust:** the envelope file is written by the operator's own pr-grind run into the clone's own git directory. Anyone who can write there can also rewrite refs and hooks, so a forged file is no new power (same model as R1). Recovery still treats the file as data, never as code: non-evaluating extraction, a closed basename, validated tokens, and a live `full_ref` == `NEW_COMMIT_SHA` check.

**Implementation/TDD residuals:** (1) the `test_890_diag_zero_and_multi_match` `|| true` count updates with the new extractors; (2) bash 3.2 `set -u` empty-array expansion `${_tip_wrap[@]+"${_tip_wrap[@]}"}` gets a unit check (the skip path never expands it); (3) BusyBox-shaped `timeout` without `-k` → unit proof that the helper skips; (4) document grind liveness when the lookup is skipped (contract already STOP); (5) trailer-token forgery / forged-remote risks stay outside the acceptance bar.

**Alternatives rejected:** upstream set in `resolve-pr-worktree.sh` (mutable; resolution should not configure push); `PR_BRANCH` from pr-grind (Option B; identity is the grind-start assert + early pin + Step 11 check).

**Risks (all handled above):** branch drift (pin ~445 before Litmus, one pre-push check, `check-ref-format` without `--`); forks (refused in Step 0); special characters (quoted refspec + `check-ref-format`); no `-k` wrapper or ineligible fetch URL (skip the optional lookup, empty tip, STOP or 3d; never unbounded, never `PUSH_URL` on argv, PATH not weakened, never skipped for HTTPS↔SSH dest-id differences); scheme/host aliases (SSH `Host` aliases such as `github-work` and gist hosts fail the tuple, an `~/.ssh/config` alias keeping the real host is unaffected, non-default ports fail, HTTP refused); existing transport configuration (R1).

## Success Criteria

1. No-upstream fix-round push succeeds via named `origin` + explicit SHA:ref.
2. History divergence classifies `judgment` with "local commit preserved" for client `(fetch first)` or `(non-fast-forward)`.
3. Hook / non-history `[remote rejected]` judgment never claims non-fast-forward; the mandatory hook negatives keep the client-status MUSTs.
4. The push ignores `pushDefault`/`push.default`; with `mirror=true` the seeded sentinel survives while `main` advances; with `followTags=true` the reachable annotated tag is not published; the submodule is not published (Test 4).
5. All of the following pass, with no new suite failures and no mandatory block waived:
   - Tests 1–6, including 6.2, 6.2a, 6.2b, 6.2c and 6.3, with `test_grind_f` unchanged plus its added reset-absence assertion;
   - the tip/destination/recovery fixtures 5–9, including 7c–7f with 7f(i) as the check-ref-format-valid hostile refname and 7f(vi)–(viii), and 8b;
   - the Raw-record reader unit table (both errexit modes);
   - the Envelope wrapper extraction checks (single marker pair in a real bash fence outside the diagram, no `│`, `bash -n`) and rows 1–9 (row 8 may report skipped only on a platform without `/proc`);
   - the Recovery step-0 fixtures (consumer clone with installed root, decoy checkout library never sourced, missing/empty/relative root, broken library, wrong clone, hostile paths);
   - the Recovery step-1 fixtures (all seven duplicate keys plus the empty-value case, dash-led branches, basename, category, hostile root, stale file);
   - the executable-`eval` guard's unit rows (below);
   - the Display identity rows;
   - the classifier unit fixtures (including redaction, apostrophe, wrapper allowlist, mixed hook + Permission-to, cannot-lock-ref).
6. Both dispatcher-running suites pass after migration: `tests/test-dispatcher-commit-block.sh` and `tests/test-litmus-mode-transition.sh` (section 11 included), with the isolation/leak guards and the direct-invocation guard.
7. `scripts/pr-head-identity.sh` fixtures (every accept and reject shape, on stdin, no `gh`) pass; Step 0 uses the helper through the one contained `gh` call; the SKILL.md grep guards for `PR_HEAD_*` and `PR_INVOCATION_URL` pass.
8. `skills/pr-grind/SKILL.md` contains the "Push bail recovery (manual only)" section with the step-1 `export GIT_NO_REPLACE_OBJECTS=1` and non-evaluating extraction, the variable checks (including `pr_number`), the four lookup outcomes, the byte-identical attribution reads, the per-push destination revalidation, rows 1–4, the `--refmap=` row-2 fetch and rebase command, and the exact `"${NEW_COMMIT_SHA:?}:${full_ref:?}"` push command. The section also contains:
   - the bash-only statement;
   - step 0: `bd_stop`, `cd -- "$bd_clone"`, the `--git-common-dir` equality with `bd_gcd`, sourcing from `"$bd_lib/push-dest-id.sh"` with STOP on failure, and the `declare -F` loop;
   - the `env_name` basename check with `git rev-parse --path-format=absolute --git-common-dir`;
   - the seven-key duplicate guard;
   - the dash-led short-name refusal;
   - the `category` extraction;
   - `_bd890_read_one_push_url` and `checked_push_url=$_BD890_ONE_URL` in steps 2–3;
   - the row-2 clean-tree / no-operation-in-progress preconditions, `git switch --detach "${NEW_COMMIT_SHA:?}"`, `-c rebase.updateRefs=false`, `git rev-list --count "$tip..$sha"` and `-c core.hooksPath=/dev/null switch -`;
   - the per-bail-type required-token rule and the anchored starts-with class allowlist;
   - step 5's `git update-ref` compare-and-swap on `"${full_ref:?}"` (a grep also asserts no `HEAD~1` in the section).

   A grep test asserts these are present:
   - the heading;
   - `export GIT_NO_REPLACE_OBJECTS=1`, `-c trailer.separators=':'` and `--refmap=`;
   - the push command;
   - `_bd890_read_one_push_url`, `--git-common-dir`, `rev-list --count`, `switch --detach` and `MERGE_HEAD`;
   - `RECOVERY_LIB_ROOT`, `declare -F` and `bd_stop`.

   It asserts these are absent:
   - in the section: `count==1`, `RESULT/log`, `grind RESULT`, `CLAUDE_PLUGIN_ROOT` and `SCRIPT_LIB` (prose phrases that must not return);
   - in the file: an empty-source refspec (`push origin ":refs/heads/`, or a refspec starting with `:` after `origin`).

   **Executable-`eval` guard.** This replaces the earlier bare-substring ban, which prose such as "revalidation" and "non-evaluating" would trip.
   - **Scope:** only lines inside the section's ```bash fences. Prose outside fences is never scanned.
   - **Fail condition:** a line matches `(^|[;&|({]|\$\(|`)[[:space:]]*((builtin|command|exec)[[:space:]]+)*eval([[:space:]]|;|$)`, which is `eval` in a command position.
   - **Also fails:** any `bash -c`, `sh -c` or `source <(` inside those fences. A nested shell string could hide `eval`, and the procedure needs none.
   - **Unit rows on a fixture file, before the real section is scanned:**
     - flagged: `eval "$x"`, `  eval $y`, `a=1; eval b`, `x && eval y`, `$(eval z)`, `` `eval w` ``, `builtin eval v`, `command eval u`, `bash -c 'true'`;
     - **not** flagged: fenced `# eval in a comment`, `echo "eval"`, `_eval_count=1`, `reevaluate`; unfenced prose `revalidation`, `non-evaluating extraction`, ``There is never `eval` ``.
   - **Then:** the guard over the real section must report no match.

   Outside the section, a grep asserts:
   - the invocation block sits in its own ```bash fence (the Envelope wrapper extraction checks);
   - it carries both `# bd890-envelope-wrapper:` markers, `--git-common-dir`, `mktemp`, `printf 'ENVELOPE_FILE=%s\n' "$_bd890_env_file" >&2`, the three `RECOVERY_*=%q` printf lines and `if ! cat "$_bd890_env_file"`;
   - the diagram holds only the pointer line;
   - the BAIL bullet (SKILL.md:893-894 region) contains `ENVELOPE_FILE=`, `RECOVERY_GIT_COMMON_DIR=`, `RECOVERY_CLONE=` and `RECOVERY_LIB_ROOT=`.

## References

- Issue #890: https://github.com/chris-yyau/busdriver/issues/890
- `scripts/dispatcher-commit-block.sh`: :90 (`pipefail`), :110 (PATH prepend), :168-170 (`PR_NUMBER` check), :175-193 (lib block), :449-460 (`full_ref` pin), :884 (`set -e`), :955-960 (Litmus prefix / UTF-8 repair), :1198 (live HEAD SHA), :1215 (Step 10a reset advice), :1247/:1257 (Step 10a predicates), :1276-1279 (explicit push), :1283-1285 (classify)
- `scripts/lib/push-failure-classify.sh` :16-23 (extractor guards, remote-first concat)
- `skills/pr-grind/SKILL.md`: ~92 (worktree removal on bail), 98-101 (no shell state across calls), 107 (START), 320-351 (dispatcher routing/env), 625 (nudge containment), 929 / 974-1010 (Step 0 `gh` calls, fork refuse), 977-979 (`//` false caveat), 1400 (`<PR>` argument)
- `scripts/resolve-pr-worktree.sh` 153, 202-216, 214-215
- Tests: `tests/test-dispatcher-commit-block.sh` :221-229, :276-279, :738-741, :1556-1559, :2329-2392; `tests/test-litmus-mode-transition.sh` :41, :369-418

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
