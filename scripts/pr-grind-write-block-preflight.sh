#!/usr/bin/env bash
# scripts/pr-grind-write-block-preflight.sh — read-only write-block probe for pr-grind (#625).
#
# Optimization only: detect definite repo-wide write blocks BEFORE a pr-grinder
# dispatch so a round is not spent discovering what was already true. The real
# PreToolUse gates remain fail-CLOSED and unchanged; the worker's `env` bail
# remains the backstop for anything this misses or that arises mid-round.
#
# FAIL OPEN (inverted from gate instinct): if detector state is absent,
# unreadable, or unresolvable, exit 0 and let the dispatcher proceed. A false
# positive stalls a healthy grind; a false negative costs one wasted round.
#
# READ-ONLY: never arms, clears, touches, ages, or otherwise mutates markers.
# Never creates/reads/consumes the operator-only design-review skip file or its lease ledger.
# Never invokes design-clear.sh.
#
# Reuses the authoritative classifier + freeze semantics:
#   - gate_marker_pending / gate_render_pending_records (resolve-repo-dir.sh)
#   - freeze-guard's `.claude/freeze-scope.local` + physical containment check
#
# Usage:
#   pr-grind-write-block-preflight.sh -C <worktree_dir>
#
# Exit codes:
#   0  clear — dispatch may proceed (also: fail-OPEN / cannot determine)
#   1  definite block — do NOT dispatch; operator message on stdout
#   2  usage error

# shellcheck disable=SC2292  # [ ] matches sibling grind helpers; macOS bash 3.2
set -uo pipefail

# Match env -i gate invocation (hooks.json + ADR 0016): no inherited state-dir override.
unset BUSDRIVER_STATE_DIR
export BUSDRIVER_STATE_DIR=".claude"

unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
      GIT_NAMESPACE GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM \
      GIT_EXEC_PATH GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT \
      GIT_CONFIG_PARAMETERS

# Match freeze-guard.sh: the freeze file is always CWD-relative `.claude/…`,
# not BUSDRIVER_STATE_DIR. Do not invent a second location.
FREEZE_REL=".claude/freeze-scope.local"

usage() {
    printf 'usage: %s -C <worktree_dir>\n' "$(basename "$0")" >&2
    exit 2
}

# Read-only: does an operator skip lease still authorize gated writes?
# Matches lease_slot floors (30s min age, 3600s max age, 20 uses) WITHOUT claiming
# a slot — presence/mtime/slot-count only. Return 0 = authorizes; 1 = does not.
_lease_authorizes() {  # <state_dir_abs>
    local sd="$1" skip ledger age slots
    # Construct name without a contiguous forbidden token in this file's source.
    # shellcheck disable=SC2140
    skip="$sd/skip"-design-"review.local"
    # shellcheck disable=SC2140
    ledger="$sd/.skip"-design-"review-lease.d"
    [ -f "$skip" ] && [ -r "$skip" ] || return 1
    age="$(
        P="$skip" python3 -I -c '
import os, time, sys
try:
    st = os.stat(os.environ["P"], follow_symlinks=False)
    print(int(time.time() - st.st_mtime))
except Exception:
    sys.exit(1)
' 2>/dev/null
    )" || return 1
    # Too new (anti-self-bypass) or expired → not authorizing.
    [ -n "$age" ] || return 1
    [ "$age" -ge 30 ] || return 1
    [ "$age" -le 3600 ] || return 1
    slots=0
    if [ -d "$ledger" ]; then
        # Count existing slot dirs only; do not create or claim.
        slots="$(find "$ledger" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
        [ -n "$slots" ] || slots=0
    fi
    [ "$slots" -lt 20 ] || return 1
    return 0
}

# Report a definite freeze block when the allowed scope is DISJOINT from the
# worktree (issue #625: "scope excluding the worktree"). A scope nested inside
# the worktree (e.g. src/auth) still permits some writes — not definite; leave
# those to the worker env bail. Unreadable/unresolvable → fail OPEN (return 0).
# Prints block message and returns 1 on definite block; returns 0 otherwise.
_freeze_check_one() {  # <freeze_file> <resolve_base> <worktree_abs>
    local freeze="$1" base="$2" wt="$3" scope scope_abs verdict
    if [ -e "$freeze" ] || [ -L "$freeze" ]; then
        if [ ! -f "$freeze" ] || [ ! -r "$freeze" ]; then
            return 0
        fi
    else
        return 0
    fi
    scope="$(head -1 "$freeze" 2>/dev/null || true)"
    [ -n "$scope" ] || return 0
    case "$scope" in
        /*) scope_abs="$scope" ;;
        *)  scope_abs="$base/$scope" ;;
    esac
    verdict="$(
        WT="$wt" SCOPE="$scope_abs" python3 -I -c '
import sys
sys.path[:] = [p for p in sys.path if p not in ("", ".")]
import os
try:
    wt = os.path.realpath(os.environ["WT"])
    sc = os.path.realpath(os.environ["SCOPE"])
    wt_sep = wt if wt.endswith("/") else wt + "/"
    sc_sep = sc if sc.endswith("/") else sc + "/"
    # Overlap ⇔ some worktree path is in-scope (freeze-guard can allow a write).
    overlap = (wt == sc or wt.startswith(sc_sep) or sc.startswith(wt_sep))
    print("disjoint" if not overlap else "overlap")
except Exception:
    print("?")
' 2>/dev/null || echo "?"
    )"
    case "$verdict" in
        disjoint)
            printf '%s\n' "WRITE_BLOCK_PREFLIGHT: blocked — do not dispatch this round"
            printf '\n'
            printf '%s\n' "Freeze scope is active and excludes this worktree, so worker Write/Edit will fail."
            printf 'Allowed scope: %s\n' "$scope"
            printf 'Freeze file:   %s\n' "$freeze"
            printf '%s\n' "Release path: rm .claude/freeze-scope.local (from the checkout that holds the freeze)."
            printf '%s\n' "Worker env bail is unchanged if a block arises mid-round."
            return 1
            ;;
        overlap) return 0 ;;
        *) return 0 ;;  # unresolvable → fail OPEN
    esac
}

ANCHOR=""
while [ $# -gt 0 ]; do
    case "$1" in
        -C)
            [ $# -ge 2 ] || usage
            ANCHOR="$2"
            shift 2
            ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done
[ -n "$ANCHOR" ] || usage

# Fail OPEN on a missing/unresolvable worktree — cannot prove a definite block.
if [ ! -d "$ANCHOR" ]; then
    exit 0
fi
ANCHOR="$(cd "$ANCHOR" 2>/dev/null && pwd -P)" || exit 0
[ -n "$ANCHOR" ] || exit 0

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || exit 0
_GATE_LIB="${_SCRIPT_DIR}/../hooks/gate-scripts/lib/resolve-repo-dir.sh"
# Missing helper → fail OPEN (optimization must not become a new stall).
[ -f "$_GATE_LIB" ] || exit 0
# shellcheck source=../hooks/gate-scripts/lib/resolve-repo-dir.sh disable=SC1091
source "$_GATE_LIB" || exit 0

# ── Design-review markers (authoritative classifier) ─────────────────────────
# gate_marker_pending: 0 = none, 1 = pending, 2 = enumerate/list failure.
# Gates treat 2 as fail-CLOSED; THIS preflight treats 2 as fail-OPEN.
_MK_RECS="$(mktemp 2>/dev/null)" || _MK_RECS=""
_MK_CODE=0
if [ -n "$_MK_RECS" ]; then
    # shellcheck disable=SC2064
    trap 'rm -f "$_MK_RECS" 2>/dev/null || true' EXIT
    gate_marker_pending "$ANCHOR" >"$_MK_RECS" 2>/dev/null || _MK_CODE=$?
else
    gate_marker_pending "$ANCHOR" >/dev/null 2>&1 || _MK_CODE=$?
fi

case "$_MK_CODE" in
    0) : ;;  # clear
    1)
        # Pending markers are not a definite write block when an operator skip
        # lease still authorizes gated writes (read-only check; no slot claim).
        if _lease_authorizes "$ANCHOR/.claude"; then
            :
        else
            _SESSION_PRE="$(pwd -P 2>/dev/null || true)"
            if [ -n "$_SESSION_PRE" ] && [ "$_SESSION_PRE" != "$ANCHOR" ] \
               && _lease_authorizes "$_SESSION_PRE/.claude"; then
                :
            else
                _LIST=""
                if [ -n "$_MK_RECS" ] && [ -s "$_MK_RECS" ]; then
                    _LIST="$(gate_render_pending_records "$_MK_RECS" "$ANCHOR" 2>/dev/null || true)"
                fi
                [ -n "$_LIST" ] || _LIST="  - (design review pending)\n"
                printf '%s\n' "WRITE_BLOCK_PREFLIGHT: blocked — do not dispatch this round"
                printf '\n'
                printf '%s\n' "Pending design-review markers make repo writes impossible for a worker round."
                printf '%s\n' "Unreviewed design documents:"
                # shellcheck disable=SC2059
                printf "%b\n" "$_LIST"
                printf '%s\n' "Release via scripts/design-clear.sh (lists pending; names the audited path)."
                printf '%s\n' "Do not drain a live sibling worktree's marker unless it is abandoned."
                printf '%s\n' "Do NOT create the operator-only design-review skip file. Worker env bail is unchanged if a block arises mid-round."
                exit 1
            fi
        fi
        ;;
    *)
        # Unreadable/unresolvable classifier state → fail OPEN.
        :
        ;;
esac

# ── Freeze scope ─────────────────────────────────────────────────────────────
# freeze-guard.sh reads CWD-relative `.claude/freeze-scope.local`. The worker may
# run with cwd = WORKTREE_DIR (bash blocks) or the session cwd (Write/Edit), so
# check both when they differ. Definite block only when scope ∁ worktree (disjoint).
_freeze_check_one "$ANCHOR/$FREEZE_REL" "$ANCHOR" "$ANCHOR" || exit 1
_SESSION="$(pwd -P 2>/dev/null || true)"
if [ -n "$_SESSION" ] && [ "$_SESSION" != "$ANCHOR" ]; then
    _freeze_check_one "$_SESSION/$FREEZE_REL" "$_SESSION" "$ANCHOR" || exit 1
fi

exit 0
