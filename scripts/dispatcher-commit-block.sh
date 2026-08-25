#!/usr/bin/env bash
# scripts/dispatcher-commit-block.sh - orchestrated dispatcher commit block for
# the pr-grind commit-ownership inversion. Invoked once per fix-round.
#
# Inputs (required env vars; parent dispatcher injects):
#   WORKTREE_DIR            - absolute path to worktree (cwd inside script)
#   BUSDRIVER_PLUGIN_ROOT   - busdriver plugin root; falls back to CLAUDE_PLUGIN_ROOT
#   PR_NUMBER               - GitHub PR number
#   RESULT_STATUS           - "needs_more" | "clean" | "bail" (from worker)
#   RESULT_FIXES            - worker's intent statement (string)
#
# Inputs (optional env vars; default 0/empty):
#   NO_WORKTREE             - "1" no-worktree mode (worker shares parent repo index)
#   PRE_DISPATCH_BASELINE   - JSON array of paths staged before worker dispatch
#   BUSDRIVER_ALLOW_NO_COMMITLINT - "1" allows missing local commitlint
#   PRIOR_COMMIT_SHA        - the LAST FIX-ROUND's reported commit SHA
#                             (dispatcher state, default "none"; RETAINED
#                             across wait-rounds, which report "none" — see
#                             pr-grind SKILL.md "Update state"). Used by the
#                             wait-round landed-fix check (#668) to bind the
#                             reported SHA to THIS round: a clean-index
#                             invocation whose pinned HEAD equals
#                             PRIOR_COMMIT_SHA is sitting on a fix that was
#                             already counted and must report "none", not
#                             double-count it.
#   RESULT_REVIEWER_ACKS    - worker-computed ack ledger; passed through on
#                             clean-path (no recompute); required for the
#                             defensive clean-round routing path to return
#                             correct acks rather than the all-"none" fallback
#   RESULT_ACK_TIERS        - worker-computed ack-tier map (ADR 0001); passed
#                             through VERBATIM on the clean path so a valid D/E
#                             bodyless-ack exemption survives. Defaults to
#                             all-"none" (fail-CLOSED) when absent. The
#                             wait-round path ignores it and emits all-"none"
#                             because it refreshes acks (stale tier snapshot).
#   RESULT_CODEX_ACK        - worker-computed Codex Tier-F ack; passed through
#                             VERBATIM on the clean path; recomputed from the
#                             post-push fetch on fix-rounds and wait-rounds so
#                             the dispatcher's PRIOR_CODEX_ACK always reflects
#                             post-push state (closes the pre-push staleness gap
#                             identified by Cursor Bugbot). Defaults to "none"
#                             when absent (backward-compat with old workers).
#
# Outputs (stdout):
#   Exactly one structured JSON line, either:
#   - Success: {"status":"success","result_commit_sha":"<sha>","result_reviewer_acks":"login=value,...","result_ack_tiers":"login=tier,...","result_codex_ack":"<sha|stale|none>"}
#   - Bail:    {"bail_category":"judgment|env|budget|policy","bail_reason":"<string>"}
#
# Exit code:
#   0 on success envelope; 1 on bail envelope.

set -uo pipefail

emit_bootstrap_bail() {
    local category="${1:-judgment}"
    local reason="${2:-dispatcher-commit-block bootstrap failure}"

    jq -nc --arg c "$category" --arg r "$reason" \
        '{bail_category: $c, bail_reason: $r}'
    exit 1
}

# Required env var check must run before sourcing helpers from
# CLAUDE_PLUGIN_ROOT, because the missing-env contract itself is testable.
# Accept either BUSDRIVER_PLUGIN_ROOT or CLAUDE_PLUGIN_ROOT (the latter is the default)
_PLUGIN_ROOT="${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"
for var in WORKTREE_DIR PR_NUMBER RESULT_STATUS RESULT_FIXES; do
    if [ -z "${!var:-}" ]; then
        emit_bootstrap_bail "env" "dispatcher-commit-block: missing required env var $var"
    fi
done

if [ -z "$_PLUGIN_ROOT" ]; then
    emit_bootstrap_bail "env" "dispatcher-commit-block: missing PLUGIN_ROOT (set BUSDRIVER_PLUGIN_ROOT or CLAUDE_PLUGIN_ROOT)"
fi

# PR_NUMBER is interpolated into the Grind-PR: trailer (Step 7) that
# scripts/grind-pr-commits.sh later scans for with a BRE, so shape-check it here
# rather than only for non-emptiness. Leading zeros are rejected, not merely
# non-digits: "0617" would stamp a trailer that a later "617" scan silently
# misses - an under-count with no error, which is the inert-gate failure Rail A
# exists to end (ADR 0036).
case "$PR_NUMBER" in
    ''|*[!0-9]*|0*)
        emit_bootstrap_bail "env" "dispatcher-commit-block: PR_NUMBER must match ^[1-9][0-9]*\$, got '$PR_NUMBER'"
        ;;
esac

# Resolve script lib paths.
SCRIPT_LIB="${_PLUGIN_ROOT}/scripts/lib"
# shellcheck source=/dev/null
. "$SCRIPT_LIB/bail-envelope.sh" || \
    emit_bootstrap_bail "env" "dispatcher-commit-block: failed to source bail-envelope.sh"
# shellcheck source=/dev/null
. "$SCRIPT_LIB/staged-diff-hash.sh" || \
    emit_bail "env" "dispatcher-commit-block: failed to source staged-diff-hash.sh"

# shellcheck source=/dev/null
. "$SCRIPT_LIB/dispatcher-proc-state.sh" || \
    emit_bail "env" "dispatcher-commit-block: failed to source dispatcher-proc-state.sh"

FETCH_PR_STATE_SCRIPT="${_PLUGIN_ROOT}/scripts/fetch-pr-state.sh"
ACK_SCRIPT="${_PLUGIN_ROOT}/scripts/ack-ledger.sh"
LITMUS_SCRIPTS="${_PLUGIN_ROOT}/skills/litmus/scripts"

# Constrain BUSDRIVER_STATE_DIR to a safe relative name with the SAME rule
# run-review-loop.sh applies to it (see its header). This is not defence in depth — it
# is agreement. If the two normalize differently, an absolute or traversal value makes
# this script classify and initialize one state file while the reviewer it invokes
# consumes another, and a leftover PR-mode state in the real `.claude` would then be
# resumed to review base...HEAD instead of the staged diff. Re-export so every path
# derived below, here and in the children, is built from the same value.
BUSDRIVER_STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
case "$BUSDRIVER_STATE_DIR" in ""|-*|/*|*..*|*[!a-zA-Z0-9._/-]*) BUSDRIVER_STATE_DIR=".claude" ;; esac
export BUSDRIVER_STATE_DIR
LITMUS_STATE_FILE="${BUSDRIVER_STATE_DIR}/litmus-state.md"

cd "$WORKTREE_DIR" || \
    emit_bail "env" "dispatcher-commit-block: cd to WORKTREE_DIR ($WORKTREE_DIR) failed"

# Single authoritative list of bots whose ack-ledger entries the dispatcher gates on.
# Referenced by both the wait-round path and the post-push synthesis (Step 12).
# cursor (Bugbot) and devin-ai-integration are DROPPED from the registry
# (ADR 0035; cursor half restored by ADR 0047 after ADR 0041's Ultra every-push
# premise was withdrawn): Bugbot is disabled on the Cursor dashboard so Auto can
# keep the shared usage pool, and busdriver Aug 2026 measurement showed ~80% of
# Bugbot findings already same-file with Codex when Codex posted. Without
# every-push re-review, gating it again would reintroduce stranded clean acks
# (ADR 0027). The Case-4 whitelist stays deleted. Cubic/CodeRabbit/Greptile +
# Codex remain the gated load.
REGISTERED_ACK_BOTS=(cubic-dev-ai coderabbitai greptile-apps)

# Pre-dispatch baseline guard (NO_WORKTREE mode only).
# Parent dispatcher must ensure `git diff --cached --quiet` before worker
# dispatch. This defense-in-depth check rejects any known pre-dispatch staged
# paths because the shared index cannot attribute them to worker intent.
if [ "${NO_WORKTREE:-0}" = "1" ]; then
    if [ -n "${PRE_DISPATCH_BASELINE:-}" ]; then
        baseline_count=$(printf '%s' "$PRE_DISPATCH_BASELINE" | jq -r 'length' 2>/dev/null || echo invalid)
        case "$baseline_count" in
            ''|*[!0-9]*)
                emit_bail "judgment" "no-worktree mode received invalid PRE_DISPATCH_BASELINE JSON"
                ;;
        esac

        if [ "$baseline_count" -gt 0 ]; then
            emit_bail "judgment" "no-worktree mode requires clean index before worker dispatch; baseline had $baseline_count staged paths"
        fi
    fi
fi

# --- Routing: RESULT_STATUS validation + non-fix-round shortcuts ---
# Known Residual #4 — the script is the single defensive entry point.
# SKILL.md routes only fix-rounds (needs_more + staged) here, but the
# script must self-validate: bail on unknown statuses, pass-through on
# clean (worker acks authoritative, no recompute), refresh acks only on
# wait-rounds (needs_more + clean index).
emit_success_no_commit() {
    # $1 = acks ledger, $2 = ack-tier map, $3 = codex ack, $4 = commit SHA to
    # report (default "none" — the wait-round/clean contract). Callers pass all
    # explicitly.
    # The CLEAN pass-through caller passes the worker's RESULT_ACK_TIERS verbatim
    # so a valid bodyless-ack exemption (cubic=D / coderabbitai=E) survives to
    # the dispatcher's Invariant 3. The WAIT-ROUND caller passes the all-`none`
    # default because it REFRESHES acks via the ack-ledger and the worker's tier
    # snapshot would be stale against those refreshed acks (fail-CLOSED). Erasing
    # tiers on the clean path would fail-closed-bail Invariant 3 on a legitimate
    # bodyless ack — the regression this split fixes. See ADR 0001.
    # $3 = codex ack: WAIT-ROUND callers pass freshly-computed value; CLEAN
    # pass-through passes RESULT_CODEX_ACK from the worker (worker is authoritative
    # on the clean path). Defaults to "none" when absent (backward-compat).
    # $4 = commit SHA (#668): the WAIT-ROUND caller passes the real SHA when the
    # round's fix already landed before this invocation (see the needs_more
    # branch); everything else defaults to "none".
    local _acks="$1"
    local _tiers="$2"
    local _codex_ack="${3:-none}"
    local _sha="${4:-none}"
    jq -nc --arg sha "$_sha" --arg acks "$_acks" --arg tiers "$_tiers" --arg codex_ack "$_codex_ack" \
        '{status:"success", result_commit_sha:$sha, result_reviewer_acks:$acks, result_ack_tiers:$tiers, result_codex_ack:$codex_ack}' || \
        emit_bail "env" "dispatcher-commit-block: emit_success_no_commit jq call failed (jq binary missing or OOM)"
    exit 0
}

case "$RESULT_STATUS" in
    clean)
        # Guard #2 from SKILL.md: clean + staged changes → BAIL judgment
        # ("orphaned staged changes on clean round"). A worker that declared
        # clean while leaving staged files would silently drop those changes
        # if we proceeded to merge without committing them.
        if ! git diff --cached --quiet 2>/dev/null; then
            emit_bail "judgment" "worker declared clean but staged changes exist (orphaned staged changes on clean round); dispatcher cannot merge with uncommitted work"
        fi
        # Fail-closed: require the worker to provide acks on the clean path.
        # Synthesising all-"none" defaults here would bypass stale-ack
        # protection — a worker that omitted RESULT_REVIEWER_ACKS while
        # declaring clean would appear to have no stale bots.
        if [ -z "${RESULT_REVIEWER_ACKS:-}" ]; then
            emit_bail "judgment" "RESULT_STATUS=clean requires RESULT_REVIEWER_ACKS from worker; worker omitted the tag"
        fi
        # Clean pass-through: preserve the worker's RESULT_ACK_TIERS and
        # RESULT_CODEX_ACK (acks are the worker's, never refreshed here, so the
        # tier map and codex ack are consistent with them — a valid D/E exemption
        # must survive). Fall back to all-`none` tiers / "none" codex only when
        # the worker omitted the tags (fail-CLOSED, pre-ADR-0001 strict).
        emit_success_no_commit "$RESULT_REVIEWER_ACKS" \
            "${RESULT_ACK_TIERS:-cubic-dev-ai=none,coderabbitai=none,greptile-apps=none}" \
            "${RESULT_CODEX_ACK:-none}"
        ;;
    needs_more)
        _cached_exit=0
        git diff --cached --quiet 2>/dev/null || _cached_exit=$?
        if [ "$_cached_exit" -gt 1 ]; then
            emit_bail "env" "git diff --cached failed (exit $_cached_exit); cannot determine staged-index state"
        fi
        if [ "$_cached_exit" -ne 0 ]; then
            # Guard #1 from SKILL.md: needs_more + staged + RESULT_FIXES empty
            # → BAIL judgment ("inconsistent worker state"). The "none" sentinel
            # is the documented absence marker; treat it and whitespace-only as
            # empty rather than later committing a body with literal text "none".
            _fixes_stripped=$(printf '%s' "${RESULT_FIXES:-}" | tr -d '[:space:]')
            if [ "$_fixes_stripped" = "none" ] || [ -z "$_fixes_stripped" ]; then
                emit_bail "judgment" "needs_more with staged changes but RESULT_FIXES is empty or 'none' (inconsistent worker state)"
            fi
        fi
        if [ "$_cached_exit" -eq 0 ]; then
            # shellcheck disable=SC1090
            if ! . "$FETCH_PR_STATE_SCRIPT" "$PR_NUMBER" 2>/dev/null \
                || [[ "${FETCH_OK:-0}" != "1" ]]; then
                emit_bail "env" "wait-round: post-push GitHub-state fetch failed; cannot refresh acks"
            fi
            export FETCH_OK ALL_THREADS ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS ALL_STATUSES \
                ALL_REACTIONS HEAD_COMMITTED_DATE HEAD_PUSH_DATE HEAD_CHECKS_DATE HEAD_SHA
            wait_entries=()
            tier_entries=()
            for bot in "${REGISTERED_ACK_BOTS[@]}"; do
                # ACK_EMIT_TIER=1: HEAD-ack returns "<sha>:<tier>"; none/stale unchanged.
                # Compute tiers from the SAME ack-ledger pass as the acks so they are
                # consistent — a Tier-D cubic ack is immediately paired with tier=D,
                # allowing Invariant 3's bodyless-ack exemption on wait-rounds where
                # cubic has no Source-2/3/4 body to enumerate (cubic=0/0:none ledger).
                raw=$(ACK_EMIT_TIER=1 bash "$ACK_SCRIPT" "$bot" 2>/dev/null || echo "stale")
                ack="${raw%%:*}"
                case "$raw" in
                    *:*) tier="${raw##*:}" ;;
                    *)   tier="none"       ;;
                esac
                wait_entries+=("${bot}=${ack}")
                tier_entries+=("${bot}=${tier}")
            done
            # Codex ack (Tier F) — computed from the same fetch pass so it reflects
            # the post-push state. ack-ledger.sh reads ALL_REACTIONS / HEAD_COMMITTED_DATE /
            # HEAD_PUSH_DATE which fetch-pr-state.sh already exported above.
            # Fail-CLOSED to `stale` (not `none`) on ack-ledger failure: a helper-
            # resolution or runtime error must not masquerade as a non-gating Codex
            # state, which would let `clean` ship past an unverified Codex signal.
            # Matches the registered-bot `|| echo "stale"` fallback above.
            wait_codex_raw=$(bash "$ACK_SCRIPT" chatgpt-codex-connector 2>/dev/null || echo "stale")
            wait_codex_ack="${wait_codex_raw%%:*}"
            # #668: the dispatcher routes this script ONLY on fix-rounds
            # (needs_more + staged changes + RESULT_FIXES populated). A clean
            # index at this point means the round's fix ALREADY LANDED before
            # this invocation — the lost-envelope re-invocation shape, where a
            # first invocation committed and pushed the fix (Grind-PR trailer
            # stamped) but its envelope was never parsed, so the dispatcher
            # re-invoked and found the index consumed. Reporting "none" then
            # mislabels the round as a wait-round, and the dispatcher classifies
            # rounds by result_commit_sha: fix_round stays 0 and the --max-fix
            # budget can never exhaust. So when RESULT_FIXES names a fix and
            # HEAD carries the Grind-PR trailer for this PR, report the LANDED
            # SHA instead of "none". (Fail-closed direction: a false positive
            # here over-counts fix_round and bails earlier, never later.)
            _report_sha="none"
            _fixes_stripped=$(printf '%s' "${RESULT_FIXES:-}" | tr -d '[:space:]')
            if [[ -n "$_fixes_stripped" && "$_fixes_stripped" != "none" ]]; then
                # #668: a re-invoked fix-round (index consumed by the landed
                # fix) must report the pushed commit, not "none" — the
                # dispatcher classifies rounds by result_commit_sha, so "none"
                # here starves the --max-fix budget. The predicate mirrors
                # Step 10a's FULL trailer validation (rev-list prefilter AND
                # the parsed-trailer block check, byte-for-byte the reader's
                # contract) so a hook-mangled trailer is never treated as
                # landed, and requires HEAD == origin/<branch> so a local-only
                # commit (Step-11 push failure) never counts as pushed. Git
                # read failures bail fail-closed: emitting "none" on a read
                # error would recreate the under-count this guards against.
                _landed_sha="none"
                _grind_rc=0
                _grind_match=""
                # Pin HEAD ONCE: the three predicates below (message prefilter,
                # parsed-trailer block, pushed-state comparison) must all refer
                # to the SAME commit — independent rev-parse calls could each
                # resolve a different HEAD if another process advances it
                # mid-check, attributing the wrong commit to this round.
                _round_head=""
                _round_head=$(git rev-parse HEAD 2>/dev/null) || _grind_rc=$?
                if [[ "$_grind_rc" != "0" ]]; then
                    emit_bail "env" "wait-round: git rev-parse HEAD failed (rc=$_grind_rc) while checking whether the fix landed; refusing to classify the round"
                fi
                _grind_match=$(GIT_NO_REPLACE_OBJECTS=1 git rev-list --no-walk --grep="^Grind-PR: ${PR_NUMBER}\$" "$_round_head" 2>/dev/null) || _grind_rc=$?
                if [[ "$_grind_rc" != "0" ]]; then
                    emit_bail "env" "wait-round: git rev-list failed (rc=$_grind_rc) while checking whether the fix landed; refusing to classify the round"
                fi
                if [[ -n "$_grind_match" ]]; then
                    _grind_block=""
                    _grind_block=$(GIT_NO_REPLACE_OBJECTS=1 git -c trailer.separators=':' log -1 --format='%(trailers)' "$_round_head" 2>/dev/null) || _grind_rc=$?
                    if [[ "$_grind_rc" != "0" ]]; then
                        emit_bail "env" "wait-round: git trailer read failed (rc=$_grind_rc) while checking whether the fix landed; refusing to classify the round"
                    fi
                    case $'\n'"$_grind_block"$'\n' in
                        *$'\n'"Grind-PR: ${PR_NUMBER}"$'\n'*)
                            # Pushed check against the PR's ACTUAL head on
                            # GitHub — HEAD_FULL_SHA (full OID, from the fetch
                            # above) is the authoritative pushed state, immune
                            # to remote.pushDefault / push.default config that
                            # can make a bare `git push` target somewhere other
                            # than @{u} or origin/<branch>. Full-OID compare:
                            # an 8-char prefix could collide with an unrelated
                            # local-only commit.
                            # Round binding: the landed commit must NOT be the
                            # PRIOR_COMMIT_SHA the dispatcher already recorded
                            # for the last round — if it is, this is a LATER
                            # clean round still sitting on the previous fix,
                            # and reporting it again would double-count
                            # fix_round and exhaust --max-fix prematurely.
                            # (The re-invoked round's fix is by construction a
                            # different commit than the last reported one.)
                            if [[ -n "$HEAD_FULL_SHA" \
                                  && "$_round_head" = "$HEAD_FULL_SHA" \
                                  && "$_round_head" != "${PRIOR_COMMIT_SHA:-none}" ]]; then
                                _landed_sha="$_round_head"
                            fi
                            ;;
                    esac
                fi
                _report_sha="$_landed_sha"
            fi
            # Wait-round: acks, tiers, and codex_ack are all FRESHLY computed from the same
            # ack-ledger pass, so they are mutually consistent. Pass the fresh
            # tiers so Invariant 3's D/E bodyless-ack exemption can fire on
            # wait-rounds (e.g. cubic acks via check-run while other bots are
            # still stale). The worker's old tier and codex snapshots are discarded.
            emit_success_no_commit "$(IFS=,; echo "${wait_entries[*]}")" \
                "$(IFS=,; echo "${tier_entries[*]}")" \
                "$wait_codex_ack" "$_report_sha"
        fi
        ;;
    bail)
        emit_bail "judgment" "worker bail status routed through commit-block; SKILL.md should route bail directly"
        ;;
    *)
        emit_bail "judgment" "unrecognized RESULT_STATUS=${RESULT_STATUS}"
        ;;
esac

# Run dir for per-invocation artifacts (litmus output capture, etc.).
RUN_DIR=$(mktemp -d -t dispatcher-XXXXXX) || \
    emit_bail "env" "dispatcher-commit-block: mktemp failed"
trap 'rm -rf "$RUN_DIR"' EXIT

# --- Step 1: Read RESULT_FIXES (worker's intent) ---
# RESULT_FIXES is injected by the parent dispatcher.

# --- Step 2: Snapshot worker's staged content for litmus-auto-fix detection ---
# Match the marker writer's hash form exactly: bare `git diff --cached`, no
# `--binary`. The litmus marker is validated later by re-running the same form.
PRE_LITMUS_DIFF_SHA=$(git diff --cached | hash_stdin) || \
    emit_bail "env" "failed to hash pre-litmus staged diff"
PRE_LITMUS_PATHS=$(git diff --cached --name-only | sort) || \
    emit_bail "env" "failed to list pre-litmus staged paths"

# --- Step 3: Initialize litmus loop ---
# run-review-loop.sh deletes litmus-state.md ONLY on PASS. Every other terminal
# status (review_findings, stall, infra_failure, setup_error) leaves the file behind
# with `active: true` — and init-review-loop.sh then refuses for EVERY active state,
# because `active: true` alone cannot tell a KILLED or PAUSED loop from a LIVE one
# (see the guard's own comment block). So a single non-PASS review wedged this script
# for every LATER invocation: the observed "litmus init-review-loop.sh failed" bail
# was never an infra failure, it was the previous round's state never being cleared
# (#569). The same leak crosses the `gh pr create` → pr-grind boundary, where the
# pre-PR gate leaves a pr-MODE file — and run-review-loop.sh lets a state-file
# review_mode OVERRIDE $LITMUS_MODE, so resuming that would silently review
# base...HEAD instead of this round's staged diff.
#
# Supply the discriminator the guard lacks: `terminal_status`. run-review-loop.sh
# deletes the state file on PASS, records a terminal_status on every non-PASS exit, and
# CLEARS the field when a run starts — so its PRESENCE proves the most recent run
# reached its end, the exact fact `active: true` cannot express. (The clear is what
# makes it trustworthy: without it a resumed loop carries the previous iteration's
# terminal_status for the whole of the next review, and a live review reads as
# finished.) Forcing on that proof is sound for this caller
# specifically: the block owns one self-contained review per invocation against a fresh
# staged diff, and a litmus FAIL ends the grind, so no iteration history is ever worth
# carrying forward.
#
# Scope note — this is a STALENESS fix, not a concurrency fix. Nothing here serializes
# against a reviewer running in the same state dir, and nothing did before either: two
# invocations that both find no state file have always both initialized. That is
# unchanged, unobserved in practice (pr-grind reviews inside its own ephemeral
# worktree, so the state dir has one writer by construction), and genuinely unclosable
# from this side — an interactive /litmus takes no lock, so real mutual exclusion needs
# run-review-loop.sh itself to participate. An earlier draft carried a pid lock and a
# pgrep probe for it; both were removed as speculative guards whose failure modes cost
# more than the race they chased. See the ADR.
#
# Rationale and the alternatives weighed: docs/adr/0033-commit-block-stale-litmus-state.md

# --- Step 3a: hold the review lock across classify-and-init ---
# Classifying the state and then acting on it is check-then-act; nothing about reading
# `terminal_status` more carefully makes the answer survive to the next line. The lock
# is what does: run-review-loop.sh takes the same one for the lifetime of a run, so
# while we hold it no review can start, resume, or clear the status we just read.
# shellcheck source=/dev/null
. "$LITMUS_SCRIPTS/lib/review-lock.sh" || \
    emit_bail "env" "dispatcher-commit-block: failed to source review-lock.sh"
# `|| LITMUS_LOCK_RC=$?`, not a bare call. errexit is off here (line 1 sets only
# `-uo pipefail`) but this script TOGGLES it mid-file, so a bare non-zero call is a
# latent hazard: move that `set -e` earlier and this acquire would abort the script
# before either bail below could emit its envelope — a silent exit where the contract
# promises JSON. The `||` form is correct under either setting.
LITMUS_LOCK_RC=0
review_lock_acquire || LITMUS_LOCK_RC=$?
if [ "$LITMUS_LOCK_RC" = "2" ]; then
    emit_bail "env" "dispatcher-commit-block: cannot use the litmus state directory $BUSDRIVER_STATE_DIR — the lock could not be created: $(review_lock_path). Inspect that path — a file or directory may already occupy it, a stale symlink may point at an unreadable target, or the directory may reject symlink creation."
fi
if [ "$LITMUS_LOCK_RC" != "0" ]; then
    emit_bail "env" "dispatcher-commit-block: the litmus review lock $(review_lock_path) is held by pid $(review_lock_owner) ($(review_lock_owner_state)). If it is running, wait; if not, that review was killed and the lock is an orphan a human must remove (reclaiming it automatically cannot be made race-free in shell — see lib/review-lock.sh)."
fi
# init-review-loop.sh takes the lock too. Export our ownership so it inherits rather
# than deadlocking against us.
review_lock_export_owner
# Extend the RUN_DIR trap rather than replacing it. review_lock_release is a no-op
# unless we still own the lock, so this cannot unlink a successor's.
# The release is CONDITIONAL: a signal path that could not prove the child group is
# gone sets LITMUS_LOCK_UNSAFE_TO_RELEASE, and an orphan a human removes beats handing
# the next invocation a lock over a file something may still be writing.
LITMUS_LOCK_UNSAFE_TO_RELEASE=0
trap 'if [ "$LITMUS_LOCK_UNSAFE_TO_RELEASE" != "1" ]; then review_lock_release; fi; rm -rf "$RUN_DIR"' EXIT

# Every child that mutates litmus-state.md — both init calls and the reviewer — runs
# through here, backgrounded and waited on. A FOREGROUND child cannot honour the lock's
# lifetime guarantee under a signal: TERM/INT/HUP reaching this process alone fires the
# EXIT trap, dropping the lock while the child keeps writing, and the next invocation
# then acquires a lock that guards nothing. Backgrounding lets bash service the traps
# below immediately (it does so while in `wait`), so the child is stopped BEFORE the
# lock is released. Installed here, before the first such child, because covering only
# the reviewer would leave the same race open across the two init calls.
LITMUS_CHILD_PID=""
LITMUS_CHILD_PGID=""
run_locked_child() {
    local rc=0
    # `set -m` makes the child lead its OWN process group, which is what lets the
    # handler signal the whole tree. Without it, a background job in a non-interactive
    # shell shares our group, `kill -PID` reaches only the immediate shell, and its
    # descendants — codex, git, the review CLI — keep running and keep writing state
    # after the lock is gone.
    set -m
    # Close the launch/capture window with a RECORDING trap, never `trap '' SIG`.
    # An ignored signal is SIG_IGN, and SIG_IGN is INHERITED across fork+exec — the
    # child would start with TERM ignored, so the handler's kill below would do nothing
    # and the child would run to natural completion while we blocked waiting for it.
    # A trap bound to a COMMAND is reset to SIG_DFL in the child, so the child stays
    # killable; the flag then lets us react the moment the pid is known.
    LITMUS_PENDING_SIGNAL=""
    trap 'LITMUS_PENDING_SIGNAL=TERM' TERM
    trap 'LITMUS_PENDING_SIGNAL=INT' INT
    trap 'LITMUS_PENDING_SIGNAL=HUP' HUP
    "$@" &
    LITMUS_CHILD_PID=$!
    # `set -m` USUALLY makes the child a process-group leader, but verify rather than
    # assume: where it does not, every group-based operation below degrades to a no-op
    # that looks like success. Empty means "no group — use the bare pid".
    #
    # Residual, stated rather than papered over: on the bare-pid path we can stop the
    # direct child but cannot reach its descendants, so a grandchild may outlive the
    # dispatcher. That path is now reached ONLY when the kernel says no such group
    # exists — not when a helper binary happens to be missing — so it is as narrow as
    # this layer can make it. It is untestable here because this platform always does
    # give the child its own group, so it is documented rather than covered.
    # Probe with the SAME primitive the handler will use, not with `ps`. Asking `ps`
    # adds a dependency that can be absent or denied in a container — and when it is,
    # the answer degrades to "no group", silently dropping back to a bare-pid kill that
    # cannot reach descendants. `kill -0 -PID` asks the kernel the exact question that
    # matters: does a process group with this id exist and may we signal it? Signal 0
    # checks existence and permission without delivering anything.
    if kill -0 -"$LITMUS_CHILD_PID" 2>/dev/null; then
        LITMUS_CHILD_PGID="$LITMUS_CHILD_PID"
    else
        LITMUS_CHILD_PGID=""
    fi
    trap '_dispatcher_signal_exit TERM' TERM
    trap '_dispatcher_signal_exit INT' INT
    trap '_dispatcher_signal_exit HUP' HUP
    set +m
    if [ -n "$LITMUS_PENDING_SIGNAL" ]; then
        _dispatcher_signal_exit "$LITMUS_PENDING_SIGNAL"
    fi
    wait "$LITMUS_CHILD_PID" || rc=$?
    LITMUS_CHILD_PID=""
    return "$rc"
}
# Poll a direct child until it exits or becomes a zombie we can reap. Uses wait only
# once the child is provably not running — blocking wait on a TERM-ignoring child would
# wedge the lock forever.
_dispatcher_await_child_dead() {
    local _limit="$1" _i=0
    while [ -n "${LITMUS_CHILD_PID:-}" ]; do
        if ! _dispatcher_pid_alive "$LITMUS_CHILD_PID"; then
            wait "$LITMUS_CHILD_PID" 2>/dev/null || true
            return 0
        fi
        _i=$((_i + 1))
        [ "$_i" -ge "$_limit" ] && return 1
        sleep 0.1
    done
    return 0
}

# Poll a process-group target ("-pgid") until the kernel reports it gone. Reap the
# known direct child once it is exited/zombie so zombie-only groups can drain.
# Returns 1 if the group still exists after $2 tenth-of-a-second ticks.
_dispatcher_await_dead() {
    local _target="$1" _limit="$2" _i=0
    while kill -0 "$_target" 2>/dev/null; do
        if [ -n "${LITMUS_CHILD_PID:-}" ] && ! _dispatcher_pid_alive "$LITMUS_CHILD_PID"; then
            wait "$LITMUS_CHILD_PID" 2>/dev/null || true
            LITMUS_CHILD_PID=""
        fi
        _i=$((_i + 1))
        [ "$_i" -ge "$_limit" ] && return 1
        sleep 0.1
    done
    return 0
}

_dispatcher_signal_exit() {
    # Conventional 128+signo, not a blanket 143: reporting Ctrl-C and HUP as SIGTERM
    # misleads whoever reads the exit status.
    local _sig="${1:-TERM}" _target _child_was_alive=0
    if [ -n "$LITMUS_CHILD_PID" ]; then
        # Snapshot liveness BEFORE signalling: afterwards every child looks dead, and
        # "was there anything to lose" is the question the no-group branch below needs
        # answered.
        # Deliberately `kill -0`, NOT _dispatcher_pid_alive. This snapshot does not ask
        # "can we reap the child" — it asks "was there a tree that could still be
        # writing", which is what the no-group branch below decides the lock on. A
        # zombie child is exactly the dangerous answer there: the child is gone, so its
        # descendants are orphaned AND unreachable without a group, yet may still be
        # writing litmus-state.md. Zombie-awareness is only sound for the reap decision;
        # applying it here would drop the lock on that case and fail OPEN.
        kill -0 "$LITMUS_CHILD_PID" 2>/dev/null && _child_was_alive=1
        # Signal the whole group when we actually HAVE one. LITMUS_CHILD_PGID is set
        # only after confirming `set -m` gave the child its own group — assuming it did
        # is how both the kill and the liveness poll become silent no-ops: `kill -0
        # -PID` against a non-group fails instantly, which reads as "already dead".
        if [ -n "$LITMUS_CHILD_PGID" ]; then
            _target="-$LITMUS_CHILD_PGID"
        else
            _target="$LITMUS_CHILD_PID"
        fi
        kill -TERM "$_target" 2>/dev/null || true
        if [ -n "$LITMUS_CHILD_PGID" ]; then
            if ! _dispatcher_await_dead "$_target" 20; then
                # kill(2) only QUEUES a signal; a descendant can still be completing a
                # state-file write, which is exactly what the lock excludes.
                kill -KILL "$_target" 2>/dev/null || true
                if ! _dispatcher_await_dead "$_target" 50; then
                    # Unkillable (uninterruptible sleep, or a pid we cannot signal). We
                    # cannot prove nothing is writing, so do NOT drop the lock: an orphan a
                    # human removes is the fail-CLOSED outcome, and the block message
                    # already names that remedy.
                    LITMUS_LOCK_UNSAFE_TO_RELEASE=1
                fi
            fi
        elif ! _dispatcher_await_child_dead 20; then
            kill -KILL "$_target" 2>/dev/null || true
            if ! _dispatcher_await_child_dead 50; then
                LITMUS_LOCK_UNSAFE_TO_RELEASE=1
            fi
        fi
        if [ -z "$LITMUS_CHILD_PGID" ] && [ "$_child_was_alive" = "1" ]; then
            # No group AND the child was still running when the signal landed: we can
            # stop the child, but its descendants are unreachable from here and may
            # still be writing litmus-state.md — the concurrent-writer race the lock
            # exists to exclude. Hold the lock and let a human clear it; proving the
            # child dead is NOT proving the tree dead.
            #
            # The liveness half matters as much as the group half. An empty PGID also
            # means "the child had already exited when we probed", and flagging THAT
            # would strand a permanent orphan lock over a run that finished cleanly —
            # turning a successful round into a wedge.
            LITMUS_LOCK_UNSAFE_TO_RELEASE=1
        fi
        # Reap ONLY once it is provably gone (exited or zombie). `wait` on a live
        # TERM-ignoring child blocks forever, and the dispatcher would then hold the
        # lock indefinitely — a worse failure than the race this handler exists to
        # prevent.
        if [ -n "$LITMUS_CHILD_PID" ] && ! _dispatcher_pid_alive "$LITMUS_CHILD_PID"; then
            wait "$LITMUS_CHILD_PID" 2>/dev/null || true
        fi
    fi
    # The EXIT trap fires after this — and frees the lock unless the group could not be
    # confirmed dead, which is the one case where holding it is correct.
    case "$_sig" in
        INT) exit 130 ;;
        HUP) exit 129 ;;
        *)   exit 143 ;;
    esac
}
trap '_dispatcher_signal_exit TERM' TERM
trap '_dispatcher_signal_exit INT' INT
trap '_dispatcher_signal_exit HUP' HUP

# --- Step 3b: try the ORDINARY init first ---
# --force is only ever needed to get past init-review-loop.sh's active-state guard, so
# reach for it only once that guard has actually fired. With no state file, or a
# completed one, the plain call succeeds and this round never carries the force's
# overwrite risk at all. That keeps the widened window — where --force overrides a
# refusal the plain call would have honoured — off the common path entirely.
if run_locked_child bash "$LITMUS_SCRIPTS/init-review-loop.sh" >/dev/null 2>&1; then
    LITMUS_INIT_DONE=1
else
    LITMUS_INIT_DONE=0
fi

# --- Step 3c: force only against a state file that PROVES a run reached its end ---
# An absent terminal_status means one of three things, all of which must NOT be forced:
# a review running right now, an interactive /litmus that has run init-review-loop.sh
# and not yet started the loop, or a run killed before it could record its outcome.
# They are indistinguishable without a clock, and forcing would erase a review somebody
# is running or is about to — a regression, since refusing on `active: true` did protect
# those, however bluntly. So refuse too, but say which remedy applies. The
# FAIL → terminal_status: review_findings case — every occurrence observed in #569 —
# stays fully automatic.
if [ "$LITMUS_INIT_DONE" != "1" ]; then
    STATE_ACTIVE=""
    STATE_TERMINAL=""
    if [ -f "$LITMUS_STATE_FILE" ]; then
        # Anchor the value to the END of the line. The previous expressions ended in
        # `.*$`, which SWALLOWED trailing content: `terminal_status: "review_findings"x`
        # parsed as the recognized value `review_findings`, and `active: "true"x` as
        # `true` — malformed state authorizing --force, the exact opposite of the
        # fail-closed rule this classification exists to enforce. `sed -n …p` emits
        # nothing when the line does not match exactly, so garbage now yields an empty
        # value, which no allowlist accepts and no active check reads as true.
        # Two BALANCED alternatives per field — quoted or bare — never `"?…"?`, whose
        # independently optional quotes accept `active: "true` and
        # `terminal_status: review_findings"`. Those are malformed by construction, and
        # a parser that resolves them to `true` / `review_findings` authorizes --force
        # on exactly the input the fail-closed rule exists to reject.
        # Select the last DECLARATION, then validate it — not the last line that
        # happens to validate. `sed -n …p` emits only matches, so filtering first and
        # taking the tail silently skips a malformed duplicate and resurrects an
        # earlier valid value: given `active: true` followed by `active: "true"JUNK`,
        # the garbage line is the one in effect under last-key-wins, yet the old order
        # returned `true` and authorized --force. Pick the line by KEY, validate that
        # one, and let a malformed final declaration resolve to empty.
        #
        # KNOWN DISAGREEMENT (tracked, not fixed here — see the linked issue): this
        # last-key-wins + strict-validate read can disagree with
        # validation.sh's get_yaml_value(), which init-review-loop.sh calls to decide
        # whether to refuse — get_yaml_value takes the FIRST `^active:` match with NO
        # format validation (naive `tr -d '"'` quote-stripping). Given a duplicated
        # `active: true` followed by a later, differently-valued `active: false`, or a
        # first line malformed in a way get_yaml_value's lenient stripping still
        # resolves to "true"/"false", the two readers can reach different verdicts
        # about whether the prior run was active — and this classifier's bail message
        # can then misdescribe why init-review-loop.sh actually refused. Reconciling
        # the two exactly requires either hardening get_yaml_value with the same
        # strict validation this block applies (a shared-library change touching every
        # get_yaml_value caller) or teaching this block to replicate get_yaml_value's
        # specific leniency — both larger than a one-line parity fix, and getting it
        # wrong risks the opposite regression (test_aj_trailing_garbage_is_not_valid_state
        # exists specifically to pin the last-key-wins + strict-validate contract).
        STATE_ACTIVE_LINE=$(grep -E '^active:' "$LITMUS_STATE_FILE" 2>/dev/null | tail -n 1 || true)
        STATE_TERMINAL_LINE=$(grep -E '^terminal_status:' "$LITMUS_STATE_FILE" 2>/dev/null | tail -n 1 || true)
        STATE_ACTIVE=$(printf '%s\n' "$STATE_ACTIVE_LINE" | sed -nE \
            -e 's/^active:[[:space:]]*(true|false)[[:space:]]*$/\1/p' \
            -e 's/^active:[[:space:]]*"(true|false)"[[:space:]]*$/\1/p' || true)
        STATE_TERMINAL=$(printf '%s\n' "$STATE_TERMINAL_LINE" | sed -nE \
            -e 's/^terminal_status:[[:space:]]*([a-z_]+)[[:space:]]*$/\1/p' \
            -e 's/^terminal_status:[[:space:]]*"([a-z_]+)"[[:space:]]*$/\1/p' || true)
    fi
    # Match the VALUE against run-review-loop.sh's own allowlist, not merely the
    # presence of a `terminal_status:` line. An empty, null, unknown, or malformed
    # value is not evidence a run finished — treating any such line as proof would let
    # corrupted state authorize a force, which is a fail-OPEN on the one check standing
    # between this script and overwriting a live review.
    case "$STATE_TERMINAL" in
        review_findings|stall|max_iterations|infra_failure|setup_error|too_large)
            STATE_FINISHED=1
            ;;
        *)
            STATE_FINISHED=0
            ;;
    esac
    # Force ONLY on the one refusal --force is the documented answer to: an active
    # state that provably finished. Every other reason the plain init can fail — not a
    # git repo, bad arguments, an unwritable state dir, an inactive or unreadable file
    # — has nothing to do with the active-state guard, and forcing there would paper
    # over the real error with an unrelated remedy. Bail and say what the state looked
    # like instead.
    if [ "$STATE_ACTIVE" = "true" ] && [ "$STATE_FINISHED" = "1" ]; then
        run_locked_child bash "$LITMUS_SCRIPTS/init-review-loop.sh" --force >/dev/null 2>&1 || \
            emit_bail "judgment" "litmus init-review-loop.sh --force failed on a state that reported terminal_status '${STATE_TERMINAL}'"
    elif [ "$STATE_ACTIVE" = "true" ]; then
        emit_bail "judgment" "litmus state is active with no recognized terminal_status (saw '${STATE_TERMINAL}') — a review running now, one initialized and not yet started, or one killed before it could record its outcome. Refusing to force-reset it; resolve with 'init-review-loop.sh --force' if it is genuinely dead."
    else
        emit_bail "judgment" "litmus init-review-loop.sh failed for a reason the state file does not explain (active='${STATE_ACTIVE}', terminal_status='${STATE_TERMINAL}'). --force answers only the active-state guard, so forcing here would mask the real failure."
    fi
fi

# --- Step 4: Invoke litmus (capture stdout + exit code) ---
# Litmus's inner loop owns review iteration. The dispatcher invokes it once per
# fix-round and bails on any non-PASS terminal status.
LITMUS_OUT="$RUN_DIR/litmus.out"

# LITMUS_SHORTCIRCUIT_DISABLED=1 is load-bearing for the pr-grind commit path:
# small staged diffs must still receive external review rather than the local
# hash-only short-circuit used by interactive litmus flows.
# Keep holding the lock through the review. run-review-loop.sh inherits it via the
# exported owner rather than acquiring its own, so classify → init → review is ONE
# uninterrupted transaction with no handover gap for a third party to win. (An earlier
# draft released here and let the reviewer re-acquire; that left a window in which
# another invocation could take the lock and replace the state we had just
# initialized.) The child will not release what it did not take, and our EXIT trap
# frees it once the review returns.
# Run the reviewer in the BACKGROUND and `wait`, rather than as a foreground command.
# The lock's guarantee is "held for the lifetime of the review", and a foreground
# invocation cannot honour that under a signal: if TERM/INT/HUP reaches this process
# alone, the EXIT trap releases the lock while the child is still writing
# litmus-state.md — and the next invocation acquires a lock that guards nothing.
# Backgrounding lets the signal traps below run immediately (bash services traps while
# in `wait`), so the reviewer is stopped BEFORE the lock is dropped.
LITMUS_EXIT=0
set +e
run_locked_child env LITMUS_SHORTCIRCUIT_DISABLED=1 \
    bash "$LITMUS_SCRIPTS/run-review-loop.sh" > "$LITMUS_OUT" 2>&1
LITMUS_EXIT=$?
set -e

# --- Step 5: Litmus disambiguation + marker validation ---
# Branch on exit code first. Exit 1 is the multi-mode FAIL family and needs
# terminal_status/stdout disambiguation.
case "$LITMUS_EXIT" in
    0)
        # PASS - proceed to marker validation below.
        ;;
    2)
        emit_bail "judgment" "litmus exit 2: review budget exceeded (TOO LARGE); worker's diff is unreviewable"
        ;;
    3)
        emit_bail "judgment" "litmus exit 3: review infrastructure unavailable (BUILTIN fallback only); dispatcher requires external CLI"
        ;;
    124)
        emit_bail "judgment" "litmus exit 124: timeout (21-min cap reached); diff convergence not achieved within time budget"
        ;;
    1)
        LITMUS_STATUS=""
        if [ -f "$LITMUS_STATE_FILE" ]; then
            LITMUS_STATUS=$(grep -E '^terminal_status:' "$LITMUS_STATE_FILE" 2>/dev/null \
                | sed -E 's/^terminal_status:[[:space:]]*"?([^"]+)"?.*$/\1/' \
                | tail -n 1 || true)
        fi

        # Fallback to stdout marker matching if the structured field is absent.
        if [ -z "$LITMUS_STATUS" ]; then
            if grep -q "STALL DETECTED" "$LITMUS_OUT"; then
                LITMUS_STATUS="stall"
            elif grep -q "Max iterations" "$LITMUS_OUT"; then
                LITMUS_STATUS="max_iterations"
            elif grep -q "FAIL - Issues found" "$LITMUS_OUT"; then
                LITMUS_STATUS="review_findings"
            else
                LITMUS_STATUS="infra_failure"
            fi
        fi

        # Lift the blocking findings into the bail reason. Without this the envelope
        # named a status and nothing else, and there was nowhere to go read the
        # detail: litmus only writes /tmp/litmus-raw-output.* when it CANNOT parse
        # the reviewer, so a parseable FAIL left an older, unrelated raw file as the
        # newest on disk — actively misleading. The state file's own `last_result` is
        # no better: it is a JSON document stored as a YAML double-quoted scalar and
        # is not round-trip-safe (a suggestion containing \" terminates the scalar
        # early, so a parser fails on it). Litmus's stdout, which we already captured,
        # renders each blocking issue as `  [severity] file:line - description` on both
        # the FAIL and the STALL path — parse that instead of the lossy stored copy.
        # Bounded on both axes (10 findings, 1500 chars) so one verbose review cannot
        # produce an envelope the dispatcher chokes on.
        #
        # NO length-slice is safe on its own. `cut -c1-1500` counts BYTES in a
        # non-UTF-8 locale, and so does `${var:0:1500}` — bash counts characters only
        # when the locale says the encoding is multibyte, so under the `LC_ALL=C` this
        # gate runs with, the 1500-byte boundary can still land inside a multibyte
        # sequence. Litmus findings are model-generated text and routinely contain
        # non-ASCII characters. Measured, not assumed: under `LC_ALL=C`, slicing
        # "abc\xC3\xA9xyz" at 4 leaves a dangling \xC3, and `emit_bail`'s `jq --arg`
        # accepts it — substituting U+FFFD — rather than failing (jq 1.7, exit 0). So
        # the cost is a corrupted character in the one diagnostic the operator has,
        # NOT a lost envelope; other jq builds may be stricter.
        # So slice first, then REPAIR: `iconv -c` drops any byte that is not part of a
        # valid sequence, which is exactly the dangling head the slice can leave. Where
        # iconv is absent, fall back to dropping every non-ASCII byte — lossier for the
        # diagnostic text, but it cannot emit an invalid sequence either. Both branches
        # only ever remove bytes, so neither can grow the string past the bound.
        LITMUS_FINDINGS=$(grep -E '^[[:space:]]+\[(high|medium|low)\] ' "$LITMUS_OUT" 2>/dev/null \
            | head -n 10 \
            | sed -e 's/^[[:space:]]*//' -e 's/$/;/' \
            | tr '\n' ' ' || true)
        LITMUS_FINDINGS="${LITMUS_FINDINGS:0:1500}"
        if command -v iconv >/dev/null 2>&1; then
            LITMUS_FINDINGS=$(printf '%s' "$LITMUS_FINDINGS" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null || true)
        else
            LITMUS_FINDINGS=$(printf '%s' "$LITMUS_FINDINGS" | LC_ALL=C tr -d '\200-\377' || true)
        fi
        [ -n "$LITMUS_FINDINGS" ] || LITMUS_FINDINGS="(none parsed from litmus stdout)"

        case "$LITMUS_STATUS" in
            review_findings)
                emit_bail "judgment" "litmus review_findings - dispatcher-side fix loop not yet implemented; operator must address them manually. Findings: ${LITMUS_FINDINGS}"
                ;;
            stall|max_iterations|infra_failure|setup_error)
                emit_bail "judgment" "litmus exit 1 (${LITMUS_STATUS}). Findings: ${LITMUS_FINDINGS}"
                ;;
            *)
                emit_bail "judgment" "litmus exit 1: unrecognized terminal_status '$LITMUS_STATUS'"
                ;;
        esac
        ;;
    *)
        emit_bail "judgment" "litmus unrecognized exit code: $LITMUS_EXIT"
        ;;
esac

# The dispatcher must recompute and verify the marker hash itself; the
# pre-commit gate is defense-in-depth, not the only verifier.
LITMUS_MARKER="${BUSDRIVER_STATE_DIR:-.claude}/litmus-passed.local"
if [ ! -f "$LITMUS_MARKER" ]; then
    emit_bail "judgment" "litmus PASS but marker file $LITMUS_MARKER missing"
fi
MARKER_CONTENT=$(head -n 1 "$LITMUS_MARKER")

case "$MARKER_CONTENT" in
    SKIPPED-NONE*|DEGRADED*|BUILTIN-*)
        emit_bail "judgment" "external review marker rejected ($MARKER_CONTENT); pr-grind requires real external-CLI review-PASS"
        ;;
esac

if [[ "$MARKER_CONTENT" == PASS-EXCLUDED-* ]]; then
    # #278: litmus commit-mode writes PASS-EXCLUDED-<epoch> when the ENTIRE
    # staged diff is review-excluded (all paths under .claude/review-exclude or
    # the hardcoded defaults). There is no reviewer and no 64-hex diff hash to
    # bind to, so instead of demanding one we re-verify the claim ourselves,
    # fail-closed.
    #
    # STEP 1 (BEFORE trusting any worktree exclusion pattern): prove the policy
    # that certifies "nothing needs review" is the COMMITTED policy.
    # build_exclude_args reads $STATE_DIR/review-exclude from the WORKTREE, so an
    # unstaged, staged, or UNTRACKED review-exclude could over-exclude real source,
    # empty NON_EXCLUDED_DIFF, and let an excluded-only marker commit unreviewed
    # content. Require the policy to match HEAD with no uncommitted divergence
    # FIRST — `git diff HEAD` catches any staged/unstaged modification or deletion,
    # and ls-files --others catches an untracked policy file — so the filtering
    # below can only ever use a committed, reviewed policy. (This also subsumes
    # the #252 staged-policy-change guard.)
    # git status --porcelain reports ALL divergence for the path in one shot —
    # staged modification/deletion (incl. `git rm --cached`, which git diff HEAD
    # misses because the worktree copy still matches HEAD), unstaged modification,
    # and untracked (`??`). Any non-empty output ⇒ the policy is not the committed
    # one ⇒ bail.
    # Sanitize STATE_DIR EXACTLY as exclude-generated.sh does (reject empty /
    # absolute / traversal / unsafe chars → .claude) so STEP 1's divergence check
    # and STEP 2's actual policy read anchor on an IDENTICAL path — otherwise an
    # unsafe operator-set BUSDRIVER_STATE_DIR could make the two target different
    # files (backstop advisory, defense-in-depth).
    _policy_state_dir="${BUSDRIVER_STATE_DIR:-.claude}"
    case "$_policy_state_dir" in ""|/*|*..*|*[!a-zA-Z0-9._/-]*) _policy_state_dir=".claude" ;; esac
    _policy_rel="$_policy_state_dir/review-exclude"
    # Reject an UNTRUSTED path component (COMMITTED symlink OR gitlink/submodule) at
    # ANY in-worktree component (leaf OR parent dir) of the policy/logic files:
    #   - symlink: `git status --porcelain` tracks only a symlink's target-string
    #     blob, not its target's content, so a symlinked component (e.g. `lib/` → an
    #     external dir) makes a leaf-only -L test pass while the later exclusion read
    #     / `.`-source follows it to unverified, mutated content (Cursor/Cubic/Codex
    #     + litmus, PR #280).
    #   - gitlink: a committed submodule (mode 160000) is a directory, not a symlink,
    #     so the -L test never fires; and `git status --porcelain -- <path-inside>`
    #     does not descend into a submodule (its dirtiness surfaces only as
    #     `M <submodule>`, scoped to the gitlink path), so the committed-clean check
    #     below is blind to divergent review-exclude / logic bytes read through it
    #     (Codex P2, issue #281). busdriver has no submodules, so any gitlink on this
    #     path is anomalous — reject it fail-closed.
    # Walk every prefix and bail on the first untrusted component.
    # $1 = worktree root, $2 = path relative to it.
    _reject_untrusted_components() {
        local _root="$1" _rel="$2" _prefix="" _seg _segs _mode
        IFS=/ read -r -a _segs <<< "$_rel"
        for _seg in "${_segs[@]}"; do
            [[ -z "$_seg" || "$_seg" == "." ]] && continue
            _prefix="${_prefix:+$_prefix/}$_seg"
            if [[ -L "$_root/$_prefix" ]]; then
                emit_bail "judgment" "excluded-only marker but in-worktree path component '$_prefix' is a symlink; a symlinked component cannot be trusted since git status verifies only the symlink blob, not its target's content"
            fi
            # gitlink (submodule) = mode 160000 in the index. Match the EXACT index
            # entry for this prefix ($2==p after a tab split), NOT merely the first
            # ls-files row: for a normal directory prefix, ls-files lists its
            # DESCENDANTS, and a gitlink descendant sorted first (e.g. `.claude/sub`
            # before `.claude/review-exclude`) would otherwise set _mode=160000 and
            # falsely bail a valid excluded-only commit (Codex/cubic, PR #282). A
            # gitlink AT the prefix is the sole index entry whose path == prefix.
            # No early awk `exit` → no SIGPIPE under set -e/pipefail (the path is
            # unique, so awk matches at most one line while reading to EOF). Fail
            # CLOSED on a genuine probe error — a git/awk failure must not leave
            # _mode empty and silently skip the gitlink check (CodeRabbit, PR #282);
            # an empty _mode from a SUCCESSFUL run (prefix has no exact index entry —
            # a normal dir or untracked component) is legitimately not a gitlink.
            if ! _mode=$(git -C "$_root" ls-files --stage -- "$_prefix" 2>/dev/null \
                    | awk -F'\t' -v p="$_prefix" '$2==p{split($1,h," "); print h[1]}'); then
                emit_bail "judgment" "excluded-only marker but could not verify the index mode of in-worktree path component '$_prefix' (git ls-files failed); rejecting fail-closed"
            fi
            if [[ "$_mode" == "160000" ]]; then
                emit_bail "judgment" "excluded-only marker but in-worktree path component '$_prefix' is a gitlink/submodule (mode 160000); a submodule cannot be trusted since git status of a path inside it does not descend to verify the committed content"
            fi
        done
    }
    _reject_untrusted_components "$WORKTREE_DIR" "$_policy_rel"
    # Distinguish "git status succeeded, output empty (clean)" from "git status
    # FAILED": a bare `2>/dev/null || true` would collapse an error into empty and
    # fail OPEN. Only an empty status from a SUCCESSFUL run means clean.
    if _policy_status=$(git status --porcelain --untracked-files=all --ignored -- "$_policy_rel" 2>/dev/null); then
        if [[ -n "$_policy_status" ]]; then
            emit_bail "judgment" "excluded-only marker but the exclusion policy ($_policy_rel) has uncommitted or untracked changes; the policy governing an excluded-only auto-pass must be committed and reviewed"
        fi
    else
        emit_bail "judgment" "excluded-only marker but could not verify the exclusion policy ($_policy_rel) is committed-clean (git status failed); fail-closed"
    fi
    # The exclusion LOGIC (exclude-generated.sh) is the OTHER input to the filter:
    # sourcing it runs its code AND its hardcoded defaults + review-exclude parse
    # decide what counts as excluded. It is normally trusted plugin code OUTSIDE
    # the reviewed worktree (the plugin cache), but when the plugin root IS the
    # worktree (busdriver self-review) a tampered copy could redefine
    # REVIEW_EXCLUDE_ARGS (or run arbitrary code) to over-exclude real source.
    # Decide membership LEXICALLY against WORKTREE_DIR (a trusted dispatcher input,
    # cwd since line 81) rather than by index or physical realpath. Both prior
    # approaches were defeatable: `git ls-files --error-unmatch` by `git rm
    # --cached` (untracks but keeps the tamperable copy), and `pwd -P` by swapping
    # an in-worktree path component for a symlink to an external dir. A lexical
    # prefix check + `git status` on the tracked path sidesteps both: git reports
    # divergence on the TRACKED path regardless of physical resolution, so a
    # swapped-to-symlink `lib/` shows its tracked files as deleted and an
    # rm --cached shows the copy as untracked — either way non-empty ⇒ bail. If the
    # logic file is not lexically under the worktree (the usual plugin-cache case)
    # this is a no-op (trusted).
    _excl_logic_file="$LITMUS_SCRIPTS/lib/exclude-generated.sh"
    # Strip trailing slashes from WORKTREE_DIR (an operator-supplied input): with a
    # trailing slash the "$WORKTREE_DIR"/* pattern becomes `/repo//*` and fails to
    # match a normal `/repo/skills/...` path, silently SKIPPING the guard. Keep "/"
    # itself intact (degenerate root case).
    _wt="$WORKTREE_DIR"
    while [[ "$_wt" == */ && "$_wt" != "/" ]]; do _wt="${_wt%/}"; done
    # Normalize to absolute: a RELATIVE plugin root (e.g. CLAUDE_PLUGIN_ROOT=.)
    # resolves against cwd, which is WORKTREE_DIR (line 81). Without this, a
    # relative path would fail the "$_wt"/* prefix test and skip the guard even
    # though the file is in-worktree.
    case "$_excl_logic_file" in
        /*) : ;;
        *)  _excl_logic_file="$_wt/$_excl_logic_file" ;;
    esac
    # Collapse ".." (and "." and duplicate "/") segments PURELY LEXICALLY
    # (string manipulation only — no filesystem access, so this cannot be
    # fooled by a symlink swap the way `realpath`/`pwd -P` could). A relative
    # LITMUS_SCRIPTS containing ".." (e.g. `../external-plugin/scripts`, a
    # legitimate trusted-external plugin root) would otherwise
    # string-prefix-match "$_wt"/* even though it actually escapes $_wt,
    # making the guard run `git status` on a bogus out-of-repo pathspec and
    # fail-close every excluded-only commit for that trusted case
    # (Cursor/Cubic, PR #280). Collapsing first makes the prefix check answer
    # the real question: does the file resolve INSIDE $_wt?
    #
    # Apply the IDENTICAL collapse to $_wt itself, not just $_excl_logic_file:
    # collapsing normalizes away incidental double-slashes too (e.g. an
    # operator-supplied WORKTREE_DIR with a trailing-slash directory
    # component), and comparing an un-collapsed $_wt against a collapsed
    # $_excl_logic_file would desync the prefix match even when both
    # genuinely point at the same in-worktree file.
    _lexical_collapse() {
        local _path="$1" _out="" _s _parts
        # Split on "/" WITHOUT pathname (glob) expansion. An unquoted array
        # assignment `_parts=($_path)` under IFS=/ ALSO globs each segment, so a
        # "*"/"?"/"[" in WORKTREE_DIR or LITMUS_SCRIPTS would expand against the
        # filesystem and normalize to the wrong path (litmus, PR #280). `read -ra`
        # word-splits on IFS only — no globbing. The `IFS=/` prefix scopes IFS to
        # the read builtin, so no save/restore of the shell's IFS is needed.
        IFS=/ read -r -a _parts <<< "$_path"
        for _s in "${_parts[@]}"; do
            case "$_s" in
                ""|".") continue ;;
                "..") _out="${_out%/*}" ;;
                *) _out="$_out/$_s" ;;
            esac
        done
        [[ -z "$_out" ]] && _out="/"
        printf '%s' "$_out"
    }
    _wt=$(_lexical_collapse "$_wt")
    _excl_logic_file=$(_lexical_collapse "$_excl_logic_file")
    # Check-vs-use consistency (litmus, PR #280): Step 2 below MUST source the
    # exact path the guard validated. Sourcing the ORIGINAL, un-collapsed
    # "$LITMUS_SCRIPTS/lib/exclude-generated.sh" while validating the collapsed
    # path lets the two diverge when the path contains ".." across a symlink
    # component (verify one file, execute another). Pin the source to the
    # collapsed path here so both branches (in-worktree + trusted-external) run
    # the same file that was checked.
    _excl_logic_source="$_excl_logic_file"
    # Symlinked-plugin-root defense (Codex, PR #280): the LEXICAL prefix check
    # below only classifies "$_excl_logic_file" as in-worktree when it is
    # lexically under "$_wt". If BUSDRIVER_PLUGIN_ROOT/CLAUDE_PLUGIN_ROOT is
    # itself a symlink whose TARGET lives inside the worktree (a self-review
    # layout where the plugin root is symlinked to the checkout rather than
    # set to it directly), _excl_logic_file's lexical path runs through the
    # symlink and never matches "$_wt"/*, so the classification below falls
    # through to "trusted-external" and skips the committed-clean guard
    # entirely. But `. "$_excl_logic_source"` two steps down follows the
    # symlink at execution time and loads the file's real (physical) bytes —
    # which DO live in the mutable worktree and could carry an uncommitted or
    # tampered redefinition of REVIEW_EXCLUDE_ARGS. This resolves the plugin
    # root and worktree to their PHYSICAL paths ONCE, using only trusted
    # operator/environment-set roots (not attacker-controlled path
    # components), purely to catch that classification mismatch — it does not
    # replace or weaken the lexical + _reject_untrusted_components defense used
    # for the already-in-worktree case below (that stays lexical-only, per
    # the rationale a few lines up).
    if [[ "$_excl_logic_file" != "$_wt"/* ]]; then
        _real_wt=$(cd "$_wt" 2>/dev/null && pwd -P) || \
            emit_bail "env" "could not resolve real path of worktree ($_wt) to check for a symlinked plugin root"
        _real_excl_dir=$(cd "$(dirname "$_excl_logic_file")" 2>/dev/null && pwd -P) || _real_excl_dir=""
        if [[ -n "$_real_excl_dir" ]] && { [[ "$_real_excl_dir" == "$_real_wt" ]] || [[ "$_real_excl_dir" == "$_real_wt"/* ]]; }; then
            emit_bail "judgment" "exclusion logic path ($_excl_logic_file) is lexically outside the worktree but physically resolves inside it ($_real_excl_dir) — the plugin root is likely a symlink into the worktree, so it cannot safely be treated as trusted-external. Point BUSDRIVER_PLUGIN_ROOT/CLAUDE_PLUGIN_ROOT at a location outside the worktree, or set it to the worktree path directly so the in-worktree guard applies."
        fi
    fi
    case "$_excl_logic_file" in
        "$_wt"/*)
            _excl_logic_rel="${_excl_logic_file#"$_wt"/}"
            # Reject a committed symlink or gitlink at any component of the logic path
            # (leaf or a parent dir), same rationale as the policy check above — a
            # leaf-only -L test misses a symlinked parent like `lib/` (litmus, PR #280)
            # and a submodule component entirely (Codex P2, issue #281).
            _reject_untrusted_components "$_wt" "$_excl_logic_rel"
            # Same fail-CLOSED discipline as the policy guard: a git status error
            # must bail, not collapse to empty (clean) via `|| true`.
            if _excl_logic_status=$(git status --porcelain --untracked-files=all --ignored -- "$_excl_logic_rel" 2>/dev/null); then
                if [[ -n "$_excl_logic_status" ]]; then
                    emit_bail "judgment" "excluded-only marker but the exclusion logic ($_excl_logic_rel) has uncommitted, untracked, or deleted changes; the logic governing an excluded-only auto-pass must be committed and reviewed"
                fi
            else
                emit_bail "judgment" "excluded-only marker but could not verify the exclusion logic ($_excl_logic_rel) is committed-clean (git status failed); fail-closed"
            fi
            ;;
    esac
    # STEP 2 (policy + logic now proven committed): the staged diff filtered through
    # the SAME exclusion logic the producer used must be empty. Any non-excluded
    # staged content ⇒ stale or mismatched marker ⇒ bail.
    # shellcheck source=/dev/null
    . "$_excl_logic_source" || \
        emit_bail "env" "failed to source exclude-generated.sh for excluded-only marker re-verify"
    NON_EXCLUDED_DIFF=$(git diff --cached --no-color -- :/ "${REVIEW_EXCLUDE_ARGS[@]}") || \
        emit_bail "env" "failed to compute non-excluded staged diff for excluded-only marker re-verify"
    if [[ -n "$NON_EXCLUDED_DIFF" ]]; then
        emit_bail "judgment" "excluded-only marker ($MARKER_CONTENT) but staged diff contains non-excluded content; marker is stale or the staged diff was mutated post-PASS — review required"
    fi
    # Verified excluded-only auto-pass — no reviewed diff to hash-bind against.
else
    if ! [[ "$MARKER_CONTENT" =~ ^[0-9a-f]{64}$ ]]; then
        emit_bail "judgment" "marker is not a valid 64-char SHA-256 hex string: '$MARKER_CONTENT'"
    fi

    EXPECTED_HASH=$(git diff --cached | hash_stdin) || \
        emit_bail "env" "failed to hash post-litmus staged diff"
    if [[ "$MARKER_CONTENT" != "$EXPECTED_HASH" ]]; then
        emit_bail "judgment" "marker/staged-diff hash mismatch (marker=$MARKER_CONTENT vs computed=$EXPECTED_HASH); marker may be stale or the staged diff was mutated post-PASS"
    fi
fi

# --- Step 6: Commit message composition + commit-type derivation ---
POST_LITMUS_DIFF_SHA=$(git diff --cached | hash_stdin) || \
    emit_bail "env" "failed to hash post-litmus staged diff for commit message"
POST_LITMUS_PATHS=$(git diff --cached --name-only | sort) || \
    emit_bail "env" "failed to list post-litmus staged paths"

# All dispatcher-owned PR-feedback commits use type "fix": every commit in this
# path is by definition addressing review feedback on the PR, which is fix
# semantics. Inferring type from free-form RESULT_FIXES prose via unanchored
# substring patterns produces a high rate of mislabeled commits (e.g.,
# "fix the comment-parsing bug" → "docs"; "fix version comparison" → "chore").
RESULT_COMMIT_TYPE="fix"

# --- Step 7: Compose the commit message ---
COMMIT_MSG=$({
    printf '%s: address PR #%s feedback\n' "$RESULT_COMMIT_TYPE" "$PR_NUMBER"
    printf '\n%s\n' "$RESULT_FIXES"
    if [ "$POST_LITMUS_DIFF_SHA" != "$PRE_LITMUS_DIFF_SHA" ]; then
        added_paths=$(comm -13 \
            <(printf '%s\n' "$PRE_LITMUS_PATHS") \
            <(printf '%s\n' "$POST_LITMUS_PATHS") \
            | tr '\n' ' ' \
            | sed 's/ $//')
        printf '\nLitmus-Auto-Fix: %s\n' "${added_paths:-content-only-edits}"
    fi
    # Durable grind provenance (Rail A / ADR 0036). This is the sole commit path,
    # so this is the only place the marker can be stamped.
    #
    # The leading newline is load-bearing: Litmus-Auto-Fix: gets its own blank
    # separator only on the litmus path, so an unconditional bare append would,
    # on the no-litmus path, glue Grind-PR: onto the body's last paragraph -
    # where git's trailer-ratio rule makes recognition shape-dependent on
    # RESULT_FIXES. Emitting the newline here puts exactly one blank line before
    # it in both shapes.
    printf '\nGrind-PR: %s\n' "$PR_NUMBER"
})

# --- Step 8: Local commitlint pre-flight (BEFORE commit; fail-CLOSED before
# any state mutation). Validates the composed message with a trailing newline
# restored so commitlint sees the same byte stream `git commit -F -` would
# normalize to (command substitution above strips trailing newlines). If this
# bails, no commit has happened — the staged index is preserved for the
# operator's next attempt. Closes #114 (orphaned-local-commit-on-env-bail bug).
if command -v npx >/dev/null 2>&1 && npx --no-install commitlint --version >/dev/null 2>&1; then
    if ! printf '%s\n' "$COMMIT_MSG" | npx --no-install commitlint; then
        emit_bail "judgment" "commitlint pre-flight failed on composed message; staged index preserved, fix RESULT_FIXES content and re-grind"
    fi
else
    if [ "${BUSDRIVER_ALLOW_NO_COMMITLINT:-0}" != "1" ]; then
        emit_bail "env" "local commitlint unavailable; install as devDep or set BUSDRIVER_ALLOW_NO_COMMITLINT=1 to proceed"
    fi
fi

# --- Step 9: Commit (only after pre-flight passes) ---
# The repository hooks (pre-commit gate, post-commit) run as part of
# `git commit`; the post-commit hook consumes the litmus marker after the
# pre-commit gate accepts it.
set +e
printf '%s' "$COMMIT_MSG" | git commit -F - >/dev/null 2>&1
GIT_COMMIT_EXIT=$?
set -e

if [ "$GIT_COMMIT_EXIT" != "0" ]; then
    emit_bail "judgment" "git commit failed (exit $GIT_COMMIT_EXIT)"
fi

# --- Step 10: Pre-push SHA synthesis ---
NEW_COMMIT_SHA=$(git rev-parse HEAD) || \
    emit_bail "env" "failed to resolve HEAD after dispatcher commit"
RESULT_COMMIT_SHA="$NEW_COMMIT_SHA"

# --- Step 10a: Verify the Grind-PR: trailer actually landed (Rail A / ADR 0036) ---
# Step 9 commits through the repository's normal hooks, deliberately. A
# commit-msg hook that rewrites or drops trailers would therefore defeat Rail A
# silently, on the one property it exists to guarantee. --no-verify is not the
# answer (it would bypass the gates the dispatcher is required to commit
# through), so verify after the fact instead, fail-CLOSED.
#
# Errexit is ARMED here: :984 does a bare `set -e` rather than restoring the
# original state, and the next `set +e` is in Step 11. So both checks are
# written capture-first with an explicit `|| emit_bail`. A bare
# `git log … | grep -q …` returning 1 would terminate the script instantly -
# no envelope on stdout - and the dispatcher, which parses the last stdout line
# as exactly one JSON envelope, would see a silent exit instead of a typed BAIL.
_grind_bail_ctx="commit $NEW_COMMIT_SHA is LOCAL and UNPUSHED; a commit-msg hook altered the Grind-PR: trailer. Fix the hook, then 'git reset --soft HEAD~1' in $WORKTREE_DIR and re-grind"

# ONE predicate, and it is byte-for-byte the reader's: the exact line
# `Grind-PR: <N>` must appear in the PARSED TRAILER BLOCK. That is exactly what
# scripts/grind-pr-commits.sh requires, down to the pinned
# `trailer.separators=':'`, so writer and reader enforce a single contract.
#
# An earlier version checked two things separately - the exact bytes anywhere in
# %B, plus a case-insensitive parsed key - and that pair validated two DIFFERENT
# occurrences. A commit-msg hook could move `Grind-PR: N` into the body and
# append `grind-pr:N` as the real trailer: both checks passed, the commit was
# pushed, and the scanner then matched it zero times. Under-counting was masked
# only by the transitional subject arm, which ADR 0036 schedules for removal.
#
# Capture-first throughout: errexit is armed here (:984 arms a bare `set -e`),
# so a bare pipeline returning 1 would kill the script with no bail envelope on
# stdout, and the dispatcher would see a silent exit instead of a typed BAIL.
# The reader runs TWO steps - a `rev-list --grep` prefilter over the raw
# message, then the exact-line check against the parsed block - so the writer
# runs both, in the same order. Mirroring the whole predicate rather than its
# second half means no assumption about how `%(trailers)` renders can put the
# two ends out of agreement.
#
# (Measured, git 2.55.0: `%(trailers)` DOES preserve the raw bytes - `Grind-PR:1`
# stays `Grind-PR:1`, `grind-pr:1` stays `grind-pr:1` - so the block check alone
# is already correct. The prefilter is here so correctness does not rest on that
# observation holding across git versions.)
# GIT_NO_REPLACE_OBJECTS=1 on both reads, matching grind-pr-commits.sh. Without
# it a post-commit hook could install a refs/replace entry whose object carries
# the expected trailer: verification would read the replacement and pass, while
# the push sends the ORIGINAL, unattributable commit — replacement refs are not
# pushed. Verification must see the object that will actually travel.
_grind_selected=$(GIT_NO_REPLACE_OBJECTS=1 git rev-list --no-walk --grep="^Grind-PR: ${PR_NUMBER}\$" "$NEW_COMMIT_SHA") || \
    emit_bail "env" "failed to re-scan the commit message for verification; $_grind_bail_ctx"
[ "$_grind_selected" = "$NEW_COMMIT_SHA" ] || \
    emit_bail "env" "Grind-PR: line is not the exact byte sequence the scanner matches; $_grind_bail_ctx"

_grind_block=$(GIT_NO_REPLACE_OBJECTS=1 git -c trailer.separators=':' log -1 \
    --format='%(trailers)' "$NEW_COMMIT_SHA") || \
    emit_bail "env" "failed to parse trailers for verification; $_grind_bail_ctx"

case $'\n'"$_grind_block"$'\n' in
    *$'\n'"Grind-PR: $PR_NUMBER"$'\n'*) : ;;
    *)
        emit_bail "env" "Grind-PR: is not an exact trailer on the commit (trailer block: $(printf '%s' "$_grind_block" | tr '\n' ';')); $_grind_bail_ctx"
        ;;
esac

# --- Step 11: Checked push ---
set +e
push_output=$(git push 2>&1)
push_exit=$?
set -e

if [ "$push_exit" != "0" ]; then
    case "$push_output" in
        *Authentication*|*"could not resolve"*|*network*|*timeout*)
            emit_bail "env" "git push auth/network: $(printf '%s\n' "$push_output" | tail -n 3)"
            ;;
        *non-fast-forward*|*rejected*|*history*)
            emit_bail "judgment" "git push non-fast-forward; local commit preserved"
            ;;
        *)
            emit_bail "judgment" "git push failed: $(printf '%s\n' "$push_output" | tail -n 3)"
            ;;
    esac
fi

# --- Step 12: Post-push GitHub state synthesis ---
# Post-push: the commit is already on the remote. Failures here must NOT bail —
# doing so would emit a bail envelope after a successful push, breaking the
# "exactly one JSON line" invariant. Instead, degrade gracefully to all-stale
# acks and emit a success envelope. The dispatcher's next round will recompute.
_fetch_ok=0
# shellcheck disable=SC1090
if . "$FETCH_PR_STATE_SCRIPT" "$PR_NUMBER" 2>/dev/null; then
    if [ "${FETCH_OK:-0}" = "1" ]; then
        _fetch_ok=1
    else
        printf 'warning: post-push GitHub-state fetch completed but FETCH_OK!=1; degrading to stale acks\n' >&2
    fi
else
    printf 'warning: post-push GitHub-state helper failed; degrading to stale acks\n' >&2
fi

reviewer_ack_entries=()
tier_entries=()
if [ "$_fetch_ok" = "1" ]; then
    export FETCH_OK ALL_THREADS ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS ALL_STATUSES \
        ALL_REACTIONS HEAD_COMMITTED_DATE HEAD_PUSH_DATE HEAD_CHECKS_DATE HEAD_SHA
    for bot in "${REGISTERED_ACK_BOTS[@]}"; do
        # ACK_EMIT_TIER=1: HEAD-ack returns "<sha>:<tier>"; none/stale unchanged.
        # Compute acks AND tiers from the SAME ack-ledger pass so they are mutually
        # consistent (the core ADR 0001 invariant). A bot that bodyless-acks the
        # post-push HEAD (e.g. cubic's check-run registers fast) is paired with
        # its real D/E tier, so Invariant 3's exemption fires correctly instead of
        # fail-closed-bailing — no stale-snapshot pairing is possible.
        raw=$(ACK_EMIT_TIER=1 bash "$ACK_SCRIPT" "$bot" 2>/dev/null || echo "stale")
        ack="${raw%%:*}"
        case "$raw" in
            *:*) tier="${raw##*:}" ;;
            *)   tier="none"       ;;
        esac
        reviewer_ack_entries+=("${bot}=${ack}")
        tier_entries+=("${bot}=${tier}")
    done
    # Codex ack (Tier F) — computed from the same post-push fetch pass so it reflects
    # the new HEAD. ack-ledger.sh reads ALL_REACTIONS / HEAD_COMMITTED_DATE /
    # HEAD_PUSH_DATE which fetch-pr-state.sh exported above.
    # Fail-CLOSED to `stale` (not `none`) on ack-ledger failure so a real Codex
    # gating signal is never suppressed into a non-gating state after a successful
    # push. Matches the registered-bot `|| echo "stale"` fallback above.
    codex_raw=$(bash "$ACK_SCRIPT" chatgpt-codex-connector 2>/dev/null || echo "stale")
    RESULT_CODEX_ACK_OUT="${codex_raw%%:*}"
else
    # Degrade to all-stale acks + all-none tiers: the dispatcher retries next round.
    for bot in "${REGISTERED_ACK_BOTS[@]}"; do
        reviewer_ack_entries+=("${bot}=stale")
        tier_entries+=("${bot}=none")
    done
    # Degrade codex to stale so the dispatcher's Invariant 1 treats this as a
    # wait-round rather than a no-progress bail.
    RESULT_CODEX_ACK_OUT="stale"
fi
RESULT_REVIEWER_ACKS=$(IFS=,; echo "${reviewer_ack_entries[*]}")
RESULT_ACK_TIERS_OUT=$(IFS=,; echo "${tier_entries[*]}")

# Uniform contract: every success envelope carries result_ack_tiers and
# result_codex_ack, all computed from the SAME post-push ack-ledger pass so
# they are mutually consistent (ADR 0001). Invariant 3's bodyless-ack exemption
# fires iff a registered bot acked the post-push HEAD via tier D/E with n_total==0.
jq -nc \
    --arg sha "$RESULT_COMMIT_SHA" \
    --arg acks "$RESULT_REVIEWER_ACKS" \
    --arg tiers "$RESULT_ACK_TIERS_OUT" \
    --arg codex_ack "$RESULT_CODEX_ACK_OUT" \
    '{status:"success", result_commit_sha:$sha, result_reviewer_acks:$acks, result_ack_tiers:$tiers, result_codex_ack:$codex_ack}' || \
    emit_bail "env" "dispatcher-commit-block: final success-envelope jq call failed (jq binary missing or OOM)"
