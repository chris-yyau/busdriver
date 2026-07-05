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
#   NO_WORKTREE             - "1" inline / no-worktree mode
#   PRE_DISPATCH_BASELINE   - JSON array of paths staged before worker dispatch
#   BUSDRIVER_ALLOW_NO_COMMITLINT - "1" allows missing local commitlint
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

# Resolve script lib paths.
SCRIPT_LIB="${_PLUGIN_ROOT}/scripts/lib"
# shellcheck source=/dev/null
. "$SCRIPT_LIB/bail-envelope.sh" || \
    emit_bootstrap_bail "env" "dispatcher-commit-block: failed to source bail-envelope.sh"
# shellcheck source=/dev/null
. "$SCRIPT_LIB/staged-diff-hash.sh" || \
    emit_bail "env" "dispatcher-commit-block: failed to source staged-diff-hash.sh"

FETCH_PR_STATE_SCRIPT="${_PLUGIN_ROOT}/scripts/fetch-pr-state.sh"
ACK_SCRIPT="${_PLUGIN_ROOT}/scripts/ack-ledger.sh"
LITMUS_SCRIPTS="${_PLUGIN_ROOT}/skills/litmus/scripts"
LITMUS_STATE_FILE="${BUSDRIVER_STATE_DIR:-.claude}/litmus-state.md"

cd "$WORKTREE_DIR" || \
    emit_bail "env" "dispatcher-commit-block: cd to WORKTREE_DIR ($WORKTREE_DIR) failed"

# Single authoritative list of bots whose ack-ledger entries the dispatcher gates on.
# Referenced by both the wait-round path and the post-push synthesis (Step 12).
REGISTERED_ACK_BOTS=(cursor cubic-dev-ai coderabbitai devin-ai-integration)

# Pre-dispatch baseline guard (NO_WORKTREE mode only).
# Parent dispatcher must ensure `git diff --cached --quiet` before worker
# dispatch. This defense-in-depth check rejects any known pre-dispatch staged
# paths because the shared index cannot attribute them to worker intent.
if [ "${NO_WORKTREE:-0}" = "1" ]; then
    if [ -n "${PRE_DISPATCH_BASELINE:-}" ]; then
        baseline_count=$(printf '%s' "$PRE_DISPATCH_BASELINE" | jq -r 'length' 2>/dev/null || echo invalid)
        case "$baseline_count" in
            ''|*[!0-9]*)
                emit_bail "judgment" "inline mode received invalid PRE_DISPATCH_BASELINE JSON"
                ;;
        esac

        if [ "$baseline_count" -gt 0 ]; then
            emit_bail "judgment" "inline mode requires clean index before worker dispatch; baseline had $baseline_count staged paths"
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
    # $1 = acks ledger, $2 = ack-tier map, $3 = codex ack (callers pass all explicitly).
    # The CLEAN pass-through caller passes the worker's RESULT_ACK_TIERS verbatim
    # so a valid bodyless-ack exemption (cursor=D / coderabbitai=E) survives to
    # the dispatcher's Invariant 3. The WAIT-ROUND caller passes the all-`none`
    # default because it REFRESHES acks via the ack-ledger and the worker's tier
    # snapshot would be stale against those refreshed acks (fail-CLOSED). Erasing
    # tiers on the clean path would fail-closed-bail Invariant 3 on a legitimate
    # bodyless ack — the regression this split fixes. See ADR 0001.
    # $3 = codex ack: WAIT-ROUND callers pass freshly-computed value; CLEAN
    # pass-through passes RESULT_CODEX_ACK from the worker (worker is authoritative
    # on the clean path). Defaults to "none" when absent (backward-compat).
    local _acks="$1"
    local _tiers="$2"
    local _codex_ack="${3:-none}"
    jq -nc --arg acks "$_acks" --arg tiers "$_tiers" --arg codex_ack "$_codex_ack" \
        '{status:"success", result_commit_sha:"none", result_reviewer_acks:$acks, result_ack_tiers:$tiers, result_codex_ack:$codex_ack}' || \
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
            "${RESULT_ACK_TIERS:-cursor=none,cubic-dev-ai=none,coderabbitai=none,devin-ai-integration=none}" \
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
                # consistent — a Tier-D cursor ack is immediately paired with tier=D,
                # allowing Invariant 3's bodyless-ack exemption on wait-rounds where
                # cursor has no Source-2/3/4 body to enumerate (cursor=0/0:none ledger).
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
            # Wait-round: acks, tiers, and codex_ack are all FRESHLY computed from the same
            # ack-ledger pass, so they are mutually consistent. Pass the fresh
            # tiers so Invariant 3's D/E bodyless-ack exemption can fire on
            # wait-rounds (e.g. cursor acks via check-run while other bots are
            # still stale). The worker's old tier and codex snapshots are discarded.
            emit_success_no_commit "$(IFS=,; echo "${wait_entries[*]}")" \
                "$(IFS=,; echo "${tier_entries[*]}")" \
                "$wait_codex_ack"
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
bash "$LITMUS_SCRIPTS/init-review-loop.sh" >/dev/null 2>&1 || \
    emit_bail "judgment" "litmus init-review-loop.sh failed"

# --- Step 4: Invoke litmus (capture stdout + exit code) ---
# Litmus's inner loop owns review iteration. The dispatcher invokes it once per
# fix-round and bails on any non-PASS terminal status.
LITMUS_OUT="$RUN_DIR/litmus.out"

# LITMUS_SHORTCIRCUIT_DISABLED=1 is load-bearing for the pr-grind commit path:
# small staged diffs must still receive external review rather than the local
# hash-only short-circuit used by interactive litmus flows.
LITMUS_EXIT=0
set +e
LITMUS_SHORTCIRCUIT_DISABLED=1 bash "$LITMUS_SCRIPTS/run-review-loop.sh" > "$LITMUS_OUT" 2>&1
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

        case "$LITMUS_STATUS" in
            review_findings)
                emit_bail "judgment" "litmus review_findings - dispatcher-side fix loop not yet implemented; operator must address inline"
                ;;
            stall|max_iterations|infra_failure|setup_error)
                emit_bail "judgment" "litmus exit 1 (${LITMUS_STATUS})"
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
        # post-push HEAD (e.g. cursor's check-run registers fast) is paired with
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
