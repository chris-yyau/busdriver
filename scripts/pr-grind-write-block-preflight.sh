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
# May read the operator skip file / lease ledger only to detect an already-active
# authorization (mtime + slot count) — never claims a lease slot, never creates
# or disarms the skip file, never invokes design-clear.sh.
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
    local sd="$1" skip ledger meta age key slots
    # Symlinked state dir or skip/ledger → not authorizing (do not follow).
    if [ -L "$sd" ]; then
        return 1
    fi
    # shellcheck disable=SC2140
    skip="$sd/skip"-design-"review.local"
    # shellcheck disable=SC2140
    ledger="$sd/.skip"-design-"review-lease.d"
    if [ -L "$skip" ] || [ -L "$ledger" ]; then
        return 1
    fi
    [ -f "$skip" ] && [ -r "$skip" ] || return 1
    # ONE stat yields both the age and the lease key, so the 30s floor and the
    # slot prefix can never end up describing two different leases.
    meta="$(
        P="$skip" python3 -I -c '
import os, time, sys
try:
    st = os.stat(os.environ["P"], follow_symlinks=False)
    print("%d %d" % (int(time.time() - st.st_mtime), st.st_mtime_ns))
except Exception:
    sys.exit(1)
' 2>/dev/null
    )" || return 1
    age="${meta%% *}"
    key="${meta##* }"
    # Too new (anti-self-bypass) or expired → not authorizing.
    [ -n "$age" ] && [ -n "$key" ] || return 1
    [ "$age" -ge 30 ] || return 1
    [ "$age" -le 3600 ] || return 1
    slots=0
    if [ -d "$ledger" ]; then
        # Count slots for THIS lease only. lease_slot.py keys uses as
        # `<st_mtime_ns>.<n>` and prunes other prefixes on the next claim, so
        # counting the whole ledger reports a freshly re-armed skip file as
        # exhausted and manufactures a block the real gate would not raise.
        # A `<st_mtime_ns>.poison` sentinel means the gate refuses this lease
        # outright, so it is not authorizing regardless of the slot count.
        slots="$(
            L="$ledger" K="$key" python3 -I -c '
import os, stat as stmod, sys
ledger = os.environ["L"]
key = os.environ["K"]
prefix = key + "."
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
# Open ledger inode without following a post-check symlink swap; count only
# the exact claimable slots the gate helper would mkdir: <key>.1..<key>.20.
try:
    flags = os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW
    lfd = os.open(ledger, flags)
except OSError:
    sys.exit(1)
try:
    entries = set(os.listdir(lfd))
    if key + ".poison" in entries:
        print("poison")
        sys.exit(0)
    n = 0
    for i in range(1, 21):
        name = "%s%d" % (prefix, i)
        if name not in entries:
            continue
        try:
            if stmod.S_ISDIR(os.stat(name, dir_fd=lfd, follow_symlinks=False).st_mode):
                n += 1
        except OSError:
            continue
    print(n)
finally:
    try:
        os.close(lfd)
    except OSError:
        pass
' 2>/dev/null
        )" || slots=0  # unenumerable ledger → fail OPEN, as everywhere else here
        [ "$slots" = "poison" ] && return 1
        case "$slots" in ''|*[!0-9]*) slots=0 ;; esac
    fi
    [ "$slots" -lt 20 ] || return 1
    return 0
}

# Report a definite freeze block when the allowed scope is DISJOINT from the
# worktree (issue #625: "scope excluding the worktree"). A scope nested inside
# the worktree (e.g. src/auth) still permits some writes — not definite; leave
# those to the worker env bail. Unreadable/unresolvable → fail OPEN (return 0).
# Prints block message and returns 1 on definite block; returns 0 otherwise.
_freeze_check_one() {  # <resolve_base> <worktree_abs>
    local base="$1" wt="$2" verdict
    # Entire freeze probe in one O_NOFOLLOW/O_NONBLOCK python walk so a FIFO
    # or symlink component cannot hang or redirect the preflight.
    verdict="$(
        BASE="$base" WT="$wt" python3 -I -c '
import os, sys, stat as stmod
sys.path[:] = [p for p in sys.path if p not in ("", ".")]
base = os.environ["BASE"]
wt = os.environ["WT"]
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
O_NONBLOCK = getattr(os, "O_NONBLOCK", 0)
try:
    dfd = os.open(base, os.O_RDONLY | os.O_DIRECTORY)
except OSError:
    print("open"); sys.exit(0)
try:
    try:
        cfd = os.open(".claude", os.O_RDONLY | os.O_DIRECTORY | O_NOFOLLOW, dir_fd=dfd)
    except OSError:
        print("open"); sys.exit(0)
    try:
        try:
            ffd = os.open("freeze-scope.local", os.O_RDONLY | O_NOFOLLOW | O_NONBLOCK, dir_fd=cfd)
        except OSError:
            print("open"); sys.exit(0)
        try:
            st = os.fstat(ffd)
            if not stmod.S_ISREG(st.st_mode):
                print("open"); sys.exit(0)
            # Read until newline or EOF; cap length so a huge first line fails OPEN
            # rather than a truncated prefix producing a false disjoint.
            chunks = []
            total = 0
            MAX = 65536
            while total < MAX:
                b = os.read(ffd, min(4096, MAX - total))
                if not b:
                    break
                chunks.append(b)
                total += len(b)
                if b"\n" in b:
                    break
            data = b"".join(chunks)
            if b"\n" not in data and total >= MAX:
                print("open"); sys.exit(0)
        finally:
            os.close(ffd)
    finally:
        os.close(cfd)
finally:
    os.close(dfd)
raw = data.split(b"\n", 1)[0].decode("utf-8", "surrogateescape").strip("\r")
if not raw:
    print("open"); sys.exit(0)
scope_abs = raw if raw.startswith("/") else os.path.join(base, raw)
try:
    wt_r = os.path.realpath(wt)
    sc_r = os.path.realpath(scope_abs)
except OSError:
    print("open"); sys.exit(0)
wt_sep = wt_r if wt_r.endswith("/") else wt_r + "/"
sc_sep = sc_r if sc_r.endswith("/") else sc_r + "/"
overlap = (wt_r == sc_r or wt_r.startswith(sc_sep) or sc_r.startswith(wt_sep))
# Display sanitization only — containment used raw above.
safe = "".join(ch if 32 <= ord(ch) < 127 else "?" for ch in raw)
if overlap:
    print("overlap")
else:
    print("disjoint|" + safe)
' 2>/dev/null || echo open
    )"
    case "$verdict" in
        disjoint\|*)
            _scope_safe="${verdict#disjoint|}"
            printf '%s\n' "WRITE_BLOCK_PREFLIGHT: blocked — do not dispatch this round"
            printf '\n'
            printf '%s\n' "Freeze scope is active and excludes this worktree, so worker Write/Edit will fail."
            printf 'Allowed scope: %s\n' "$_scope_safe"
            printf 'Freeze file:   %s/%s\n' "$base" "$FREEZE_REL"
            printf '%s\n' "Release path: rm .claude/freeze-scope.local (from the checkout that holds the freeze)."
            printf '%s\n' "Worker env bail is unchanged if a block arises mid-round."
            return 1
            ;;
        overlap) return 0 ;;
        *) return 0 ;;
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
# Soft deadline: a hung classify must not stall the dispatcher (optimization
# that never returns is worse than one wasted round). Timeout → fail OPEN.
_MK_RECS="$(mktemp 2>/dev/null)" || _MK_RECS=""
_MK_RCFILE="$(mktemp 2>/dev/null)" || _MK_RCFILE=""
_MK_CODE=2
if [ -n "$_MK_RECS" ] || [ -n "$_MK_RCFILE" ]; then
    # shellcheck disable=SC2064
    trap 'rm -f "$_MK_RECS" "$_MK_RCFILE" 2>/dev/null || true' EXIT
fi
# Job control so the background classify gets its own process group (pgid ==
# subshell pid). On timeout we kill the whole tree — git/python descendants
# included — not just the wrapper shell.
set -m
(
    _c=0
    if [ -n "$_MK_RECS" ]; then
        gate_marker_pending "$ANCHOR" >"$_MK_RECS" 2>/dev/null || _c=$?
    else
        gate_marker_pending "$ANCHOR" >/dev/null 2>&1 || _c=$?
    fi
    [ -n "$_MK_RCFILE" ] && printf '%s\n' "$_c" >"$_MK_RCFILE"
) &
_MK_PID=$!
# Poll up to ~8s. Fractional sleep is fine on Darwin/bash 3.2.
_MK_I=0
while [ "$_MK_I" -lt 80 ]; do
    if ! kill -0 "$_MK_PID" 2>/dev/null; then
        wait "$_MK_PID" 2>/dev/null || true
        break
    fi
    sleep 0.1
    _MK_I=$((_MK_I + 1))
done
if kill -0 "$_MK_PID" 2>/dev/null; then
    kill -TERM -"$_MK_PID" 2>/dev/null || kill -TERM "$_MK_PID" 2>/dev/null || true
    _MK_J=0
    while [ "$_MK_J" -lt 20 ]; do
        sleep 0.1
        _MK_J=$((_MK_J + 1))
    done
    # Always KILL the process group after grace — do not key off wrapper liveness
    # (a dead wrapper can leave ignoring descendants).
    kill -KILL -"$_MK_PID" 2>/dev/null || kill -KILL "$_MK_PID" 2>/dev/null || true
    wait "$_MK_PID" 2>/dev/null || true
    _MK_CODE=2  # timed out → fail OPEN
elif [ -n "$_MK_RCFILE" ] && [ -s "$_MK_RCFILE" ]; then
    _MK_CODE="$(cat "$_MK_RCFILE" 2>/dev/null || echo 2)"
else
    _MK_CODE=2
fi
set +m
case "$_MK_CODE" in
    0|1|2) : ;;
    *) _MK_CODE=2 ;;
esac

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
                    # Print doc_path fields from NUL records — sanitize to
                    # printable single-line paths (no escape expansion).
                    _LIST="$(
                        python3 -I -c '
import sys
sys.path[:] = [p for p in sys.path if p not in ("", ".")]
path = sys.argv[1]
try:
    data = open(path, "rb").read().split(b"\0")
except OSError:
    sys.exit(0)
out = []
truncated = False
i = 0
while i + 3 < len(data):
    kind, _src, doc, reason = data[i], data[i+1], data[i+2], data[i+3]
    i += 4
    if kind == b"overflow":
        truncated = True
        continue
    if not doc:
        continue
    if len(out) >= 20:
        truncated = True
        continue
    s = doc.decode("utf-8", "replace")
    safe = "".join(ch if 32 <= ord(ch) < 127 else "?" for ch in s)
    if safe:
        out.append("  - " + safe)
if truncated:
    out.append("  - … listing truncated — run design-clear.sh with no args for the full set")
if out:
    sys.stdout.write("\n".join(out) + "\n")
' "$_MK_RECS" 2>/dev/null || true
                    )"
                fi
                [ -n "$_LIST" ] || _LIST="  - (design review pending)"
                printf '%s\n' "WRITE_BLOCK_PREFLIGHT: blocked — do not dispatch this round"
                printf '\n'
                printf '%s\n' "Pending design-review markers make repo writes impossible for a worker round."
                printf '%s\n' "Unreviewed design documents:"
                printf '%s\n' "$_LIST"
                # Absolute, plugin-relative: when pr-grind targets a repo other
                # than the busdriver checkout, a bare `scripts/design-clear.sh`
                # resolves inside the target and does not exist there.
                printf 'Release via %s (lists pending; names the audited path).\n' \
                    "${_SCRIPT_DIR}/design-clear.sh"
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
_freeze_check_one "$ANCHOR" "$ANCHOR" || exit 1
_SESSION="$(pwd -P 2>/dev/null || true)"
if [ -n "$_SESSION" ] && [ "$_SESSION" != "$ANCHOR" ]; then
    _freeze_check_one "$_SESSION" "$ANCHOR" || exit 1
fi

exit 0
