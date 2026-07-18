#!/usr/bin/env bash
# design-clear — audited operator release of ONE pending design-review token.
#
# The sanctioned analogue of the `skip-*.local` escape hatches, per ADR 0017
# (#405). ADR 0017 settled that the design-review block's repo-wide blast radius
# is CORRECT fail-CLOSED behavior and must not be narrowed; this helper relieves
# the ergonomic pain of a bare `rm` WITHOUT weakening the gate:
#
#   - lists pending tokens through the same `marker_ops.py classify` the gate
#     uses (never a blind glob),
#   - clears exactly ONE named token, never a blanket wipe,
#   - requires deliberate confirmation (interactive y/N, or explicit --yes),
#   - writes one bypass-log.jsonl event per clear — the durable audit trail that
#     a review requirement was operator-released.
#
# NOT in scope (settled by ADR 0017): narrowing what the marker blocks.
#
# WHAT THIS DOES *NOT* GUARANTEE — read before trusting it as a boundary.
# There is NO operator authentication here, and none is possible from a script
# an agent session can execute. `--yes` is a documented, AUDITABLE SELF-BYPASS:
# anything holding Bash can pass it and release its own just-armed marker. That
# is not a regression — the same session can `rm` the token directly, so this
# helper grants no new power — but it means the #347 anti-forge invariant is NOT
# enforced by this script. What the script actually provides is narrower and
# real: a clear is never a blanket wipe, never touches an unvalidated marker,
# and never happens without a durable audit record naming the doc and how it was
# authorized (`confirmed: tty` vs `no-tty-assumed-yes` — the latter is the
# fingerprint of an unattended self-release). Detection, not prevention.
# Enforcement would need an out-of-process operator-held capability; if that is
# ever required, build it there and delete this paragraph.
#
# SCOPE — assumed trusted: the git common-dir. The marker directory lives under
# <git-common-dir>/busdriver/, and this helper does not defend against that
# directory being swapped between classification and unlink (a TOCTOU on the
# token'"'"'s parent). Anyone who can write there can already delete every token
# directly, so the design-review gate has no integrity left to protect at that
# point — the same assumption the gate scripts themselves make. Documented, not
# silently ignored; see #377 for the repo'"'"'s precedent on recording residuals
# on an advisory surface instead of chasing brittle mitigations.
#
# Usage:
#   design-clear.sh                 # list pending tokens, change nothing
#   design-clear.sh <index>         # clear the Nth listed token (confirms)
#   design-clear.sh <doc-path>      # clear the token bound to that design doc
#   design-clear.sh <sel> --yes     # skip the interactive confirmation
#
# Exit: 0 ok / 1 nothing to do or refused / 2 cannot resolve marker state.

set -uo pipefail

# The AUDIT PATH IS A CONSTANT, deliberately. The gates read
# $BUSDRIVER_STATE_DIR, but they run as hooks whose env sanitized-gate.sh
# controls; this helper is invoked directly by whoever holds a shell. Honoring a
# caller-supplied state dir would let `BUSDRIVER_STATE_DIR=elsewhere
# design-clear.sh <doc> --yes` delete the shared token while writing the only
# record to a path nobody monitors — silently defeating the one guarantee this
# tool exists to provide. A durable audit trail cannot have a movable target.
# The classifier still resolves its own state dir internally for legacy markers;
# only the log destination is pinned here.
STATE_DIR=".claude"

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../hooks/gate-scripts/lib/resolve-repo-dir.sh disable=SC1091
source "$_SELF_DIR/../hooks/gate-scripts/lib/resolve-repo-dir.sh"

SELECTOR=""
ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y) ASSUME_YES=1 ;;
        -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}"; exit 0 ;;
        -*) printf 'design-clear: unknown flag %s\n' "$arg" >&2; exit 2 ;;
        *)
            if [ -n "$SELECTOR" ]; then
                printf 'design-clear: clear ONE token at a time (got %s and %s)\n' "$SELECTOR" "$arg" >&2
                exit 2
            fi
            SELECTOR="$arg" ;;
    esac
done

# ── Enumerate through the gate's own classifier ───────────────────────────────
RECS="$(mktemp)" || { echo "design-clear: mktemp failed" >&2; exit 2; }
trap 'rm -f "$RECS"' EXIT
CODE=0
gate_marker_pending "$PWD" >"$RECS" 2>/dev/null || CODE=$?

case "$CODE" in
    0) echo "No pending design-review tokens. Nothing to clear."; exit 1 ;;
    1) : ;;
    *) echo "design-clear: cannot resolve marker state (classifier exit $CODE)." >&2
       echo "The gate is failing CLOSED for the same reason; fix that before clearing." >&2
       exit 2 ;;
esac

# Records are 4 NUL-terminated fields each: kind, source_path, doc_path, reason.
KINDS=() SRCS=() DOCS=() REASONS=()
_i=0
while IFS= read -r -d '' _field; do
    case $(( _i % 4 )) in
        0) KINDS+=("$_field") ;;
        1) SRCS+=("$_field") ;;
        2) DOCS+=("$_field") ;;
        3) REASONS+=("$_field") ;;
    esac
    _i=$(( _i + 1 ))
done <"$RECS"

if [ "${#SRCS[@]}" -eq 0 ]; then
    echo "design-clear: gate reports pending but emitted no records — refusing to guess." >&2
    exit 2
fi

SELF_ROOT="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"

# The classifier caps emitted records at K=20 (marker_ops.py, ADR-C) — the gate
# only needs "is anything pending", so it stops counting. Hitting the cap means
# this listing may be INCOMPLETE, which bounds what the helper may honestly say:
# no remaining-count arithmetic, and a doc selector that finds no match could
# still be pending but unlisted. Clearing stays exact (one named token), so a
# truncated list never over-deletes — it only under-reports.
# ponytail: warn on truncation instead of adding an uncapped classify-all mode —
# that means editing a fail-CLOSED security classifier for a case needing 21
# simultaneously-pending design docs. Add the mode if that ever happens for real.
CAP=20
TRUNCATED=0
[ "${#SRCS[@]}" -ge "$CAP" ] && TRUNCATED=1

truncation_note() {
    [ "$TRUNCATED" -eq 1 ] || return 0
    printf '\nNOTE: the classifier caps its listing at %d records and that cap was hit.\n' "$CAP"
    printf '      More tokens may be pending than are shown. Clear a few, then re-run.\n'
}

list_tokens() {
    local n=0 note
    printf 'Pending design-review tokens:\n\n'
    while [ "$n" -lt "${#SRCS[@]}" ]; do
        note=""
        [ -n "${DOCS[$n]}" ] && note="$(gate_marker_owner_note "${DOCS[$n]}" "$SELF_ROOT")"
        if [ -n "${DOCS[$n]}" ]; then
            printf '  [%d] %s%s\n' "$(( n + 1 ))" "${DOCS[$n]}" "$note"
        else
            printf '  [%d] %s  [%s]  (not clearable here — see below)\n' \
                "$(( n + 1 ))" "${SRCS[$n]}" "${REASONS[$n]}"
        fi
        printf '      token: %s\n' "${SRCS[$n]}"
        n=$(( n + 1 ))
    done
    truncation_note
}

if [ -z "$SELECTOR" ]; then
    list_tokens
    printf '\nClear one with:  design-clear.sh <index>   or   design-clear.sh <doc-path>\n'
    exit 0
fi

# ── Resolve the selector to exactly one record ────────────────────────────────
# An INDEX is a position in a listing built from an unsorted os.listdir(), so it
# is only meaningful for the listing the operator just read. Between a list run
# and a clear run, a concurrent arming or filesystem reordering can slide a
# different token under the same number. Interactively that is caught — the
# confirmation prompt names the doc before anything is deleted. Under --yes
# nothing re-checks it, so an index could silently release the WRONG review.
# Non-interactive callers must name the doc, which is stable.
TARGET=-1
if [[ "$SELECTOR" =~ ^[0-9]+$ ]]; then
    if [ "$ASSUME_YES" -eq 1 ]; then
        printf 'design-clear: refusing an index selector with --yes.\n\n' >&2
        printf 'Indexes are positions in a listing that can shift between runs (a token\n' >&2
        printf 'armed concurrently reorders them), and --yes skips the prompt that would\n' >&2
        printf 'name the doc before it is released. Name the design doc instead:\n' >&2
        printf '  design-clear.sh <doc-path> --yes\n' >&2
        exit 2
    fi
    if [ "$SELECTOR" -ge 1 ] && [ "$SELECTOR" -le "${#SRCS[@]}" ]; then
        TARGET=$(( SELECTOR - 1 ))
    fi
else
    # Match on the doc path the classifier VALIDATED (token body), not on user
    # spelling: normalize the selector the same way arming did, so a relative
    # path or a `..` spelling still resolves to the one true token.
    NORM="$(gate_marker_norm_path "$SELECTOR" 2>/dev/null || printf '%s' "$SELECTOR")"
    n=0
    while [ "$n" -lt "${#DOCS[@]}" ]; do
        if [ -n "${DOCS[$n]}" ] && [ "${DOCS[$n]}" = "$NORM" ]; then
            if [ "$TARGET" -ge 0 ]; then
                echo "design-clear: '$SELECTOR' matches more than one token — select by index." >&2
                exit 2
            fi
            TARGET=$n
        fi
        n=$(( n + 1 ))
    done
fi

if [ "$TARGET" -lt 0 ]; then
    printf 'design-clear: no pending token matches %s\n\n' "$SELECTOR" >&2
    list_tokens >&2
    exit 1
fi

# Only a FULLY VALIDATED `<sha>.<nonce>` token is unlinkable here. Two distinct
# refusals, and `kind` alone does NOT separate them: _classify_tokens emits
# kind="token" for stray/truncated/unreadable files too, with reason
# unparseable|unreadable and an EMPTY doc_path. Gating on kind alone would let an
# index selector delete a fail-CLOSED marker whose subject is unknown — releasing
# a review requirement with nothing to name in the audit trail. Require the
# reason to be "token" AND a non-empty validated doc.
if [ "${KINDS[$TARGET]}" != "token" ]; then
    # A legacy list-file marker holds several docs at once, so removing it is the
    # blanket wipe this helper exists to avoid.
    printf 'design-clear: [%d] is a %s marker (%s), not a per-doc token.\n' \
        "$(( TARGET + 1 ))" "${KINDS[$TARGET]}" "${REASONS[$TARGET]}" >&2
    printf 'It lists several docs at once; clearing it is a blanket wipe. Edit or remove it by hand:\n  %s\n' \
        "${SRCS[$TARGET]}" >&2
    exit 1
fi
if [ "${REASONS[$TARGET]}" != "token" ] || [ -z "${DOCS[$TARGET]}" ]; then
    printf 'design-clear: [%d] is an UNVALIDATED marker (%s) — refusing to clear it.\n\n' \
        "$(( TARGET + 1 ))" "${REASONS[$TARGET]}" >&2
    printf 'The classifier could not bind it to a design document, so there is no\n' >&2
    printf 'reviewable subject to release and nothing meaningful to record in the\n' >&2
    printf 'audit log. It is anomalous marker state (truncated, forged, or tampered),\n' >&2
    printf 'which the gate blocks on deliberately. Inspect it, then remove by hand:\n  %s\n' \
        "${SRCS[$TARGET]}" >&2
    exit 1
fi

TOKEN="${SRCS[$TARGET]}"
DOC="${DOCS[$TARGET]}"
TOKEN_SHA="$(basename -- "$TOKEN")"; TOKEN_SHA="${TOKEN_SHA%%.*}"

printf '\nAbout to release the design-review requirement for:\n\n  %s\n\ntoken: %s\n\n' "$DOC" "$TOKEN"
printf 'The gate will stop blocking on this doc. This is logged to %s/bypass-log.jsonl.\n' "$STATE_DIR"

# How this release was authorized, recorded in the audit event. `--yes` is
# sanctioned by ADR 0017 (an operator scripting their own drain), but it is NOT a
# proof of human intent: anything holding Bash can pass it. The honest control is
# the trail, not the flag — a `"confirmed":"no-tty-assumed-yes"` line is exactly
# the fingerprint of an unattended self-release, and the #347 invariant is
# enforced by that being visible, not by pretending the flag cannot be set.
# (A Bash-holding session could `rm` the token directly regardless; this helper
# grants no new power, it only makes the release legible.)
# `[ -r /dev/tty ]` tests the device node's permission bits, NOT whether this
# process has a controlling terminal — on a headless runner it passes while the
# open fails, which would stamp an unattended release as "assumed-yes" and blur
# the one fingerprint the trail exists to show. Probe the actual open instead.
has_tty() { (: </dev/tty) 2>/dev/null; }

CONFIRM_MODE="tty"
if [ "$ASSUME_YES" -eq 1 ]; then
    if has_tty; then CONFIRM_MODE="assumed-yes"; else CONFIRM_MODE="no-tty-assumed-yes"; fi
else
    if ! has_tty; then
        echo "design-clear: no terminal to confirm on. Re-run with --yes if you mean it." >&2
        exit 1
    fi
    printf 'Clear it? [y/N] '
    read -r reply </dev/tty || reply=""
    case "$reply" in
        y|Y|yes|YES) : ;;
        *) echo "Aborted — nothing was cleared."; exit 1 ;;
    esac
fi

# ── Audit FIRST, then unlink ──────────────────────────────────────────────────
# Ordering is the guarantee, not an implementation detail. ADR 0017 promises a
# DURABLE record that a review requirement was operator-released; unlinking first
# and warning on a failed append means a full or read-only log filesystem yields
# a silent, unlogged bypass — the exact hole the audit trail exists to close.
# So: append + flush + fsync the event, and refuse to clear at all if that fails.
# The cost is a possible over-record (logged, then the unlink fails), which the
# compensating event below corrects. Over-recording is the safe direction.
#
# python3 (already a hard dependency of the gate lib) builds the line so a doc
# path carrying a quote, backslash, or newline cannot inject keys or break the
# JSONL framing. `-I` isolates it from a repo-controlled sitecustomize/PYTHONPATH.
# ponytail: O_APPEND on a short line, no flock — appends under PIPE_BUF are
# atomic and this is a single-operator interactive tool. Add locking if it ever
# runs concurrently.
# The marker is shared through the git COMMON dir, so a token armed anywhere
# blocks everywhere — which means the release of that shared token must be
# recorded in ONE canonical place. `git rev-parse --show-toplevel` names the
# CURRENT worktree, so clearing from a linked/disposable worktree would file the
# only audit event in that worktree's .claude/ (and vanish with it). Anchor the
# log to the main worktree root, derived from the common dir, and fail closed if
# that cannot be established.
# Pick the canonical root for the audit log. Neither obvious signal is right on
# its own, and each fails a case the other handles:
#   * `git rev-parse --show-toplevel` names the CURRENT worktree, so a clear run
#     from a linked/disposable worktree would file the only record there — and it
#     vanishes with the worktree, even though the token was repo-wide.
#   * `git worktree list --porcelain` lists the main worktree first, which fixes
#     that — EXCEPT under `git init --separate-git-dir`, where (verified locally)
#     it reports the GIT DIR path instead of the worktree.
# So: take the first worktree-list entry, but only trust it if it actually looks
# like a worktree root (has a .git entry); otherwise fall back to the toplevel.
# Read it NUL-delimited (-z): the plain --porcelain form C-quotes any path with
# a newline, and silently falling back on such a path would file the record in
# the disposable linked worktree — exactly the failure this block prevents. With
# -z there is no quoting, so every valid path is handled.
_MAIN_WT=""
while IFS= read -r -d '' _wt_field; do
    case "$_wt_field" in
        "worktree "*) _MAIN_WT="${_wt_field#worktree }"; break ;;
    esac
done < <(git -C "$PWD" worktree list --porcelain -z 2>/dev/null || true)
if [ -n "$_MAIN_WT" ] && [ ! -e "$_MAIN_WT/.git" ]; then
    _MAIN_WT=""                      # separate-git-dir: that was the git dir
fi
[ -n "$_MAIN_WT" ] || _MAIN_WT="$SELF_ROOT"
if [ -z "$_MAIN_WT" ] || [ ! -d "$_MAIN_WT" ]; then
    echo "design-clear: cannot resolve the canonical repo root for the audit log." >&2
    echo "Refusing to clear rather than file the record somewhere unmonitored." >&2
    exit 2
fi
ROOT_DIR="$_MAIN_WT"
LOG="$ROOT_DIR/$STATE_DIR/bypass-log.jsonl"
HEAD_SHA="$(git -C "$PWD" rev-parse HEAD 2>/dev/null || true)"

log_event() {   # <event>
    # shellcheck disable=SC2016 # the whole python3 -I -c '...' body below is
    # intentionally single-quoted (it's Python source, not shell) and passes
    # values in via the env vars above, not shell interpolation; the embedded
    # '"'"' quote-escape trick later in the block re-triggers this per segment.
    EVENT="$1" DOC="$DOC" TOKEN_SHA="$TOKEN_SHA" HEAD_SHA="$HEAD_SHA" \
    ROOT_DIR="$ROOT_DIR" CONFIRM="$CONFIRM_MODE" \
    python3 -I -c '
import datetime, fcntl, json, os, stat, sys

# The audit path is attacker-influenced: STATE_DIR is repo-relative and may be
# NESTED (a/b), and .claude/ is repo-controlled. A plain open(..., "a") — or a
# shell `mkdir -p` — FOLLOWS symlinks at every component, so a symlinked
# INTERMEDIATE directory could redirect the append outside the repo. The clear
# would then look audited while the documented log stayed empty. O_NOFOLLOW on
# the final component alone does not cover that, so walk EVERY component from
# the repo root with dir_fd + O_NOFOLLOW, creating as needed, and refuse the
# moment one is a symlink or not a directory.
root = os.environ["ROOT_DIR"]
try:
    dfd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
except OSError:
    sys.exit(1)
try:
    # One fixed component. O_NOFOLLOW at each step so a symlinked .claude/ or a
    # symlinked log cannot redirect the append outside the repo.
    try:
        os.mkdir(".claude", 0o755, dir_fd=dfd)
    except FileExistsError:
        pass
    except OSError:
        sys.exit(1)
    else:
        # fsync the PARENT so a freshly created dir survives a crash; fsync of a
        # file persists contents, never its directory entry.
        try:
            os.fsync(dfd)
        except OSError:
            sys.exit(1)
    try:
        nfd = os.open(".claude", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                      dir_fd=dfd)
    except OSError:
        sys.exit(1)                           # symlinked or non-dir .claude
    os.close(dfd)
    dfd = nfd
    try:
        # O_RDWR, not O_WRONLY: the torn-line pre-check below pread()s the last
        # byte, which a write-only fd cannot do. O_APPEND still makes every
        # write land at EOF.
        fd = os.open("bypass-log.jsonl",
                     os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW,
                     0o644, dir_fd=dfd)
    except OSError:
        sys.exit(1)                           # symlinked log, or unwritable
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            sys.exit(1)                       # fifo/device posing as the log
        # Serialize the read-check/append/rollback section. Without it two
        # concurrent clears can both pass the trailing-newline check, and a
        # short-write rollback in one can ftruncate away the other'"'"'s durable
        # event after that process already deleted its token.
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
        except OSError:
            sys.exit(1)
        rec = {
            "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "event": os.environ["EVENT"],
            "doc": os.environ["DOC"],
            "token_sha": os.environ["TOKEN_SHA"],
            "head": os.environ["HEAD_SHA"],
            # Distinguishes a human who answered the prompt from an unattended
            # --yes caller, so the trail says HOW the release was authorized.
            "confirmed": os.environ["CONFIRM"],
        }
        # A pre-existing torn line poisons every later append: this record would
        # concatenate onto the fragment and the joined line is not valid JSONL.
        # Refuse rather than compound it.
        size = os.fstat(fd).st_size
        if size:
            if os.pread(fd, 1, size - 1) != b"\n":
                sys.exit(1)
        data = (json.dumps(rec) + "\n").encode()
        # A SHORT write (storage exhausted) would append a truncated record and
        # still exit 0, so the caller would delete the token believing the event
        # was durable. Require the whole line — and on failure roll the file back
        # to its pre-write size so the NEXT run does not inherit a fragment.
        # NO ftruncate rollback here, deliberately. The gate scripts append to
        # this same log with unlocked `>>`, so they do not honor our flock: a
        # rollback racing one of their appends would erase an unrelated event —
        # destroying another writer record just to tidy up our own fragment.
        # Detect and refuse instead. The fragment stays, the token is NOT
        # deleted, and the trailing-newline check above makes the next run
        # refuse too, so the operator is forced to repair the log rather than
        # accumulate silent corruption. Fail-closed, and never destructive.
        if os.write(fd, data) != len(data):
            sys.stderr.write(
                "design-clear: SHORT WRITE to the audit log — it now ends in a "
                "partial line and must be repaired by hand before any token can "
                "be cleared. Nothing was deleted.\n")
            sys.exit(1)
        os.fsync(fd)
        # ...and the directory entry, in case bypass-log.jsonl was just created.
        os.fsync(dfd)
    finally:
        os.close(fd)
finally:
    os.close(dfd)
'
}

# NOT 2>/dev/null: the writer prints a specific SHORT WRITE diagnostic telling
# the operator the log must be REPAIRED, which the generic advice below would
# contradict. The Python block exits quietly on the expected path errors.
if ! log_event "design-marker-cleared"; then
    printf 'design-clear: could not write the audit event to %s — REFUSING to clear.\n' "$LOG" >&2
    printf 'An unlogged release is not a sanctioned bypass. Resolve the above, then retry.\n' >&2
    exit 2
fi

if ! rm -f -- "$TOKEN"; then
    # Already recorded as cleared, but it is not — emit the correction so the
    # trail stays truthful rather than leaving a phantom release on the record.
    if ! log_event "design-marker-clear-failed"; then
        # The log now claims a release that did not happen and the correction
        # could not be appended. Say so loudly — a silently inconsistent audit
        # trail is worse than a noisy one.
        printf 'design-clear: WARNING — the audit log records this token as CLEARED but it\n' >&2
        printf 'was NOT removed, and the correcting entry could not be written. The log at\n' >&2
        printf '%s is INCONSISTENT and needs manual reconciliation.\n' "$LOG" >&2
    fi
    printf 'design-clear: could not remove %s.\n' "$TOKEN" >&2
    exit 2
fi

if [ "$TRUNCATED" -eq 1 ]; then
    printf 'Cleared. Others remain pending (listing was capped — re-run to see them).\n'
else
    printf 'Cleared. %d token(s) still pending.\n' "$(( ${#SRCS[@]} - 1 ))"
fi
