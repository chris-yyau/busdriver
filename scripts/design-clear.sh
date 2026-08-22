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
#   - clears exactly ONE named token — or, with --all-for-doc, every token bound
#     to ONE NAMED document — never a blanket wipe,
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
#   design-clear.sh --all-for-doc <doc-path>
#                                   # clear every LISTED token for that ONE named
#                                   # doc, one audit event each, one confirmation
#   design-clear.sh --skip <name>   # DISARM one spent skip/review marker in
#                                   # $STATE_DIR (see the drainable list below)
#   design-clear.sh --skip          # list what is drainable, change nothing
#
# --skip is the #516 drain, in this tool rather than a second one. It covers only
# markers whose REMOVAL TIGHTENS a gate -- a spent skip file, a consumed review
# artifact -- so the worst case is an unnecessary review. Markers whose removal
# LOOSENS a gate (the design tokens above, the skip lease ledger) or erases the
# trail (bypass-log.jsonl) are refused by name, and forging any of them stays
# blocked by the gate exactly as before.
#
# It exists because #638 closed the accidental workaround: a loop binding
# (a for-loop over the marker with rm in its body) used to walk straight past the
# marker-forge guard, which was the only way an agent could disarm its own spent
# skip file. Closing that without landing this would have traded a fail-open for
# a harder fail-closed.
#
# Editing a design doc arms a FRESH token each time, so one document routinely
# accumulates a dozen or more (#665). --all-for-doc drains exactly that: the doc
# is named (stable, unlike an index), no other doc can be touched, and the trail
# still gets one design-marker-cleared event per released token.
# It clears every token the CLASSIFIER LISTED. The classifier's emit budget is
# PER-KIND: TOKEN records are capped at 20, legacy records at a far higher
# backstop, so an unrelated legacy backlog can never hide a doc's tokens. When
# either budget truncates, the classifier says so explicitly and this helper acts
# on the signal rather than guessing (#671): a cut TOKEN listing under-reports
# and the closing line says to re-run; a cut LEGACY listing makes the
# same-document screen unsound, so every by-name release is refused outright.
# A doc holding more than 20 tokens takes more than one run. It is not
# a promise to empty the directory in one shot; it is a promise never to touch a
# token belonging to another doc.
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
ALL_FOR_DOC=0
SKIP_MODE=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y) ASSUME_YES=1 ;;
        --all-for-doc) ALL_FOR_DOC=1 ;;
        --skip) SKIP_MODE=1 ;;
        # Address the header block by its terminator, not by line numbers: the
        # old '2,28p' silently stopped short of Usage:, so every mode added since
        # was undiscoverable from --help. A pattern range cannot drift.
        -h|--help) sed -n '2,/^# Exit:/p' "${BASH_SOURCE[0]}"; exit 0 ;;
        -*) printf 'design-clear: unknown flag %s\n' "$arg" >&2; exit 2 ;;
        *)
            if [ -n "$SELECTOR" ]; then
                printf 'design-clear: clear ONE token at a time (got %s and %s)\n' "$SELECTOR" "$arg" >&2
                exit 2
            fi
            SELECTOR="$arg" ;;
    esac
done

if [ "$SKIP_MODE" -eq 1 ] && [ "$ALL_FOR_DOC" -eq 1 ]; then
    echo "design-clear: --skip and --all-for-doc are different drains; pick one." >&2
    exit 2
fi

# Needed by BOTH modes (the audit log is anchored off it), so it is resolved
# before the design-token enumeration that --skip skips.
SELF_ROOT="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"

# ── --skip: disarm ONE spent skip/review marker (#516) ────────────────────
# An ALLOWLIST BY NAME, not a path the caller chooses: the drain must not become a
# way to unlink an arbitrary file with an audit event stamped on it. Membership is
# decided by ONE question -- does removing this marker make the next gate stricter?
# If yes it is drainable; if removing it lifts a block or erases the trail it is
# refused here and stays refused by the gate.
DRAINABLE="skip-litmus.local skip-design-review.local litmus-passed.local pr-review-passed.local pr-codex-lead.local.json pr-backstop-verdict.local.json"
# Named explicitly so the refusal can say WHY rather than "not on the list".
# The lease ledger bounds the skip bypass to 20 writes (#519) -- draining it resets
# the ceiling; bypass-log.jsonl IS the audit trail this tool exists to write;
# design-review-needed.local blocks until a review happens, so removing it is the
# bypass, not the cleanup.
# reviewed-commits.local is here for a DIFFERENT reason than the other three: no gate
# in this repo reads it (post-commit-consume-marker.sh only appends to it and
# invalidates it on a SHA change), so removing it tightens nothing and simply destroys
# the accumulated branch:SHA review records. It fails the drain invariant from the
# other side.
NEVER_DRAINABLE=".skip-design-review-lease.d bypass-log.jsonl design-review-needed.local reviewed-commits.local"

TRUNCATED=0
LEGACY_OVERFLOW=0
CLEAR_EVENT="design-marker-cleared"
FAIL_EVENT="design-marker-clear-failed"

# Resolve $STATE_DIR from the repo root with O_NOFOLLOW on EVERY component, then stat
# (and later unlink) the marker BY NAME relative to that descriptor. A `-L` test checks
# only the final component, and `.claude/` itself is repo-controlled -- in a linked
# worktree it can be a symlink to the MAIN worktree state dir -- so a shell test plus
# `rm -f "$path"` would unlink an allowlisted basename outside this repo, with the audit
# event claiming otherwise. `open_state_dir` is the same containment the gate own state
# writers use (#519), so both halves of this file contain the path identically.
# Exit: 0 regular file (unlinked, in unlink mode) / 2 absent / 3 not a regular file /
#       4 state dir unopenable without following a symlink / 5 unlink failed /
#       6 the state dir was swapped out from under the open descriptor.
skip_probe() {   # [unlink]
    ( cd "$SELF_ROOT" || exit 4
      MODE="${1:-probe}" NAME="$SELECTOR" STATE="$STATE_DIR" \
      LIB="$_SELF_DIR/../hooks/gate-scripts/lib" python3 -I -c '
import os, stat, sys
sys.path.insert(0, os.environ["LIB"])
import audit_append
dfd = audit_append.open_state_dir(os.environ["STATE"])
if dfd is None:
    sys.exit(4)
name = os.environ["NAME"]
try:
    st = os.stat(name, dir_fd=dfd, follow_symlinks=False)
except OSError:
    sys.exit(2)
if not stat.S_ISREG(st.st_mode):
    sys.exit(3)
# A directory DESCRIPTOR outlives its own entry: rename the state dir after the open and
# every name checked through dfd lands in a detached tree, so the unlink would report
# success while the real marker stayed armed and the audit event claimed otherwise.
# Checked on both sides of the unlink -- same reasoning, and the same helper, as the
# gate own state writers (#519).
if not audit_append.state_dir_unchanged(dfd, os.environ["STATE"]):
    sys.exit(6)
if os.environ["MODE"] == "unlink":
    try:
        os.unlink(name, dir_fd=dfd)
    except OSError:
        sys.exit(5)
    if not audit_append.state_dir_unchanged(dfd, os.environ["STATE"]):
        sys.exit(6)
' )
}

if [ "$SKIP_MODE" -eq 1 ]; then
    CLEAR_EVENT="skip-marker-cleared"
    FAIL_EVENT="skip-marker-clear-failed"
    if [ -z "$SELF_ROOT" ]; then
        echo "design-clear: not inside a git work tree - cannot locate the state dir." >&2
        exit 2
    fi
    if [ -z "$SELECTOR" ]; then
        printf 'Drainable with --skip <name> (removal makes the next gate STRICTER):\n\n'
        for _n in $DRAINABLE; do
            if [ -e "$SELF_ROOT/$STATE_DIR/$_n" ]; then
                printf '  %-34s ARMED\n' "$_n"
            else
                printf '  %-34s -\n' "$_n"
            fi
        done
        printf '\nNever drainable (removal would loosen a gate or erase the trail):\n\n'
        for _n in $NEVER_DRAINABLE; do printf '  %s\n' "$_n"; done
        exit 1
    fi
    # Basename only: a caller-supplied path is how a drain turns into an arbitrary
    # unlink, and every one of these markers lives at exactly one place.
    case "$SELECTOR" in
        *[/]*|..|.) echo "design-clear: --skip takes a bare marker NAME, not a path." >&2; exit 2 ;;
    esac
    for _n in $NEVER_DRAINABLE; do
        if [ "$SELECTOR" = "$_n" ]; then
            printf 'design-clear: %s is NOT drainable.\n' "$SELECTOR" >&2
            printf 'Removing it would loosen a gate, or destroy records nothing re-creates - the\n' >&2
            printf 'opposite of\n' >&2
            printf 'what this drain is for. Run --skip with no name to see what IS drainable.\n' >&2
            exit 1
        fi
    done
    _ok=0
    for _n in $DRAINABLE; do
        [ "$SELECTOR" = "$_n" ] && _ok=1
    done
    if [ "$_ok" -eq 0 ]; then
        printf 'design-clear: %s is not a drainable marker. Run --skip with no name.\n' "$SELECTOR" >&2
        exit 2
    fi
    SKIP_PATH="$SELF_ROOT/$STATE_DIR/$SELECTOR"
    skip_probe   # sets nothing; exit code classifies (see the helper above)
    case $? in
        0) : ;;
        2) printf '%s is not armed. Nothing to drain.\n' "$SELECTOR"; exit 1 ;;
        3) printf 'design-clear: %s is not a regular file (symlink, dir, or device) -\n' "$SELECTOR" >&2
           printf 'refusing to unlink it. That is anomalous marker state, not a spent marker.\n' >&2
           exit 2 ;;
        6) printf 'design-clear: %s/ changed under us mid-check - refusing.\n' "$STATE_DIR" >&2
           exit 2 ;;
        *) printf 'design-clear: cannot open %s/ without following a symlink - refusing.\n' "$STATE_DIR" >&2
           exit 2 ;;
    esac
    DOC="$SKIP_PATH"
    DOCS=("$SKIP_PATH")
    SRCS=("$SKIP_PATH")
    KINDS=("skip")
    REASONS=("")
    TARGETS=(0)
    N_TARGETS=1
    printf '\nAbout to DISARM the spent gate marker:\n\n  %s\n\n' "$SKIP_PATH"
    printf 'Removing it makes the next gate STRICTER, never looser. This is logged to\n'
    printf '%s/bypass-log.jsonl as a %s event.\n' "$STATE_DIR" "$CLEAR_EVENT"
fi

if [ "$SKIP_MODE" -eq 0 ]; then
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


# The classifier's emit budgets are PER-KIND, and a truncated kind is announced
# EXPLICITLY: one trailing `overflow` record naming which kind was cut (#671).
# Read that signal rather than inferring truncation from "I counted exactly the
# cap" — the old inference false-positived on a set that landed on the cap
# exactly, and could not see valid tokens dropped before they ever reached the
# emitter (marker_ops _classify_tokens buffers at K).
#
# The two kinds mean different things and are handled differently:
#   token-overflow  — under-reports. Clearing stays exact (one named token), so
#                     a short list never over-deletes; say so and let the
#                     operator drain what IS listed and re-run. Refusing here
#                     instead would refuse in #665's own motivating scenario.
#   legacy-overflow — NOT safe the same way. The all-or-nothing screen below can
#                     only refuse on records it was handed, so a cut legacy list
#                     may be hiding the very entry that names the doc being
#                     released. Every name-based selector is refused outright.
TRUNCATED=0
LEGACY_OVERFLOW=0
_n=0
while [ "$_n" -lt "${#KINDS[@]}" ]; do
    if [ "${KINDS[$_n]}" = "overflow" ]; then
        case "${REASONS[$_n]}" in
            token-overflow)  TRUNCATED=1 ;;
            legacy-overflow) LEGACY_OVERFLOW=1 ;;
        esac
    fi
    _n=$(( _n + 1 ))
done

truncation_note() {
    if [ "$TRUNCATED" -eq 1 ]; then
        printf '\nNOTE: the classifier truncated its TOKEN listing (it said so explicitly).\n'
        printf '      More tokens are pending than are shown. Clear a few, then re-run.\n'
    fi
    if [ "$LEGACY_OVERFLOW" -eq 1 ]; then
        printf '\nNOTE: the classifier truncated its LEGACY listing (it said so explicitly).\n'
        printf '      Releasing by doc path is refused while that is true: the same-document\n'
        printf '      screen needs the complete legacy set, and an unlisted entry could name\n'
        printf '      the very doc being released. Trim the legacy list file first.\n'
    fi
}

list_tokens() {
    # `gate_marker_owner_note` shells out to git once or twice PER RECORD, and
    # the classifier's legacy budget is a high BACKSTOP (marker_ops L=500), not
    # a listing size, so a long legacy list still means hundreds of subprocesses
    # here where the token cap alone would have bounded it. Bound the
    # NOTES rather than the listing: this is the tool that is supposed to show
    # the complete set, and the note is a which-worktree convenience, not part
    # of the record. Records past the budget still list, just without it.
    local n=0 note notes_left=20
    printf 'Pending design-review tokens:\n\n'
    while [ "$n" -lt "${#SRCS[@]}" ]; do
        note=""
        if [ -n "${DOCS[$n]}" ] && [ "$notes_left" -gt 0 ]; then
            note="$(gate_marker_owner_note "${DOCS[$n]}" "$SELF_ROOT")"
            notes_left=$(( notes_left - 1 ))
        fi
        if [ -n "${DOCS[$n]}" ] && [ "${KINDS[$n]}" = "token" ]; then
            printf '  [%d] %s%s\n' "$(( n + 1 ))" "${DOCS[$n]}" "$note"
        elif [ -n "${DOCS[$n]}" ]; then
            # A legacy list-file record IS bound to a doc_path (needed for the
            # all-or-nothing safety check below), but it can never be cleared by
            # naming that doc -- unlinking it would drop the whole shared list
            # file, releasing every OTHER doc named in it too (a blanket wipe).
            # Rendering it identically to a real per-doc token, as before,
            # advertised `design-clear.sh '<doc>'` / --all-for-doc for a
            # selector that always refuses. Show the doc for context but drop
            # the clearable-looking format (cubic, PR #670).
            printf '  [%d] %s%s  [%s]  (not clearable by name — edit the legacy list file, see below)\n' \
                "$(( n + 1 ))" "${DOCS[$n]}" "$note" "${REASONS[$n]}"
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
    if [ "$ALL_FOR_DOC" -eq 1 ]; then
        printf 'design-clear: --all-for-doc needs the design doc to drain.\n' >&2
        printf '  design-clear.sh --all-for-doc <doc-path>\n' >&2
        exit 2
    fi
    list_tokens
    if [ "$LEGACY_OVERFLOW" -eq 1 ]; then
        printf '\nLEGACY listing is truncated: by-name release (doc-path or --all-for-doc) is\n'
        printf 'refused until you trim the legacy list file. Until then:\n'
        printf '  design-clear.sh <index>   # needs a tty — an index is refused with --yes\n'
    else
        printf '\nClear one with:  design-clear.sh <index>   or   design-clear.sh <doc-path>\n'
        printf 'Drain one doc:   design-clear.sh --all-for-doc <doc-path>\n'
    fi
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
TARGETS=()
if [[ "$SELECTOR" =~ ^[0-9]+$ ]]; then
    # --all-for-doc releases a SET, and only a doc path can name a set: it is the
    # stable key the classifier validated, so every token it selects is bound to
    # the document the operator typed. An index names one position in a listing
    # that reorders between runs — it cannot identify a set at all, and honoring
    # it here would silently reinterpret "index 3" as "everything sharing index
    # 3's doc", releasing reviews the operator never named.
    if [ "$ALL_FOR_DOC" -eq 1 ]; then
        printf 'design-clear: --all-for-doc takes a DOC PATH, not an index (%s).\n\n' "$SELECTOR" >&2
        printf 'It releases every token bound to one document, so the selector has to name\n' >&2
        printf 'that document. Indexes are positions in a listing that shift between runs:\n' >&2
        printf '  design-clear.sh --all-for-doc <doc-path>\n' >&2
        exit 2
    fi
    if [ "$ASSUME_YES" -eq 1 ]; then
        printf 'design-clear: refusing an index selector with --yes.\n\n' >&2
        printf 'Indexes are positions in a listing that can shift between runs (a token\n' >&2
        printf 'armed concurrently reorders them), and --yes skips the prompt that would\n' >&2
        printf 'name the doc before it is released. Name the design doc instead:\n' >&2
        printf '  design-clear.sh <doc-path> --yes\n' >&2
        exit 2
    fi
    if [ "$SELECTOR" -ge 1 ] && [ "$SELECTOR" -le "${#SRCS[@]}" ]; then
        TARGETS+=( "$(( SELECTOR - 1 ))" )
    fi
else
    # #671 — fail CLOSED on a truncated LEGACY listing. Both name-based forms
    # depend on having been handed every legacy record for the doc: --all-for-doc
    # refuses all-or-nothing on a non-token record in the set, and the plain
    # selector's ">1 match" refusal is the same screen wearing a different hat.
    # Neither can refuse on a record it never saw, so a cut legacy list would
    # release a doc's tokens while an unlisted legacy entry for it stayed armed —
    # the bypass PR #670 spent seven rounds closing, through a new door. An index
    # selector never claimed that screen (it releases exactly one named token),
    # so it stays available, as does the no-arg listing.
    if [ "$LEGACY_OVERFLOW" -eq 1 ]; then
        printf 'design-clear: refusing a doc-path selector — the legacy listing was truncated.\n\n' >&2
        printf 'Releasing by name screens for a legacy list entry naming the SAME document,\n' >&2
        printf 'and that screen can only see records the classifier emitted. It did not emit\n' >&2
        printf 'them all, so an entry for %s could be pending and unlisted.\n\n' "$SELECTOR" >&2
        printf 'Trim the legacy list file, then re-run — or, AT A TERMINAL, release one\n' >&2
        printf 'token by its listed index, which never depended on that screen:\n' >&2
        printf '  design-clear.sh            # full listing, names the file to trim\n' >&2
        printf '  design-clear.sh <index>    # needs a tty — an index is refused with --yes,\n' >&2
        printf '                             # so the prompt that names the doc always runs\n' >&2
        exit 2
    fi
    # Match on the doc path the classifier VALIDATED (token body), not on user
    # spelling: normalize the selector the same way arming did, so a relative
    # path or a `..` spelling still resolves to the one true token.
    NORM="$(gate_marker_norm_path "$SELECTOR" 2>/dev/null || printf '%s' "$SELECTOR")"
    # Collect EVERY match first, then decide what to say. Erroring on the second
    # match (as this used to) meant the message was chosen before the rest of the
    # set was known — so a doc whose set includes a legacy record still got told
    # to run --all-for-doc, which the all-or-nothing check below then refuses.
    # Same rule the gate renderer follows: never print a command that cannot
    # succeed (Codex, PR #670).
    MIXED_SRC=""
    n=0
    while [ "$n" -lt "${#DOCS[@]}" ]; do
        if [ -n "${DOCS[$n]}" ] && [ "${DOCS[$n]}" = "$NORM" ]; then
            TARGETS+=( "$n" )
            if [ "${KINDS[$n]}" != "token" ] && [ -z "$MIXED_SRC" ]; then
                MIXED_SRC="${SRCS[$n]}"
            fi
        fi
        n=$(( n + 1 ))
    done
    if [ "$ALL_FOR_DOC" -eq 0 ] && [ "${#TARGETS[@]}" -gt 1 ]; then
        printf "design-clear: '%s' matches more than one pending record.\n\n" "$SELECTOR" >&2
        if [ -n "$MIXED_SRC" ]; then
            printf 'One of them is a legacy list-file marker, which names several docs at\n' >&2
            printf 'once — clearing it would be a blanket wipe, so NO selector can release\n' >&2
            printf 'this doc while that entry stands (--all-for-doc refuses it too). Remove\n' >&2
            printf 'this doc from the list file by hand first:\n  %s\n' "$MIXED_SRC" >&2
        else
            printf 'Editing a doc arms a fresh token each time, so this is the normal state\n' >&2
            printf 'of a doc that went through a few review rounds. Release them together:\n' >&2
            # Shell-quote it: this line is meant to be COPIED and run, so a
            # path with a space or apostrophe must survive the round trip.
            printf "  design-clear.sh --all-for-doc '%s'\n\n" "${SELECTOR//\'/\'\\\'\'}" >&2
            printf 'Or pick exactly one by its listed index:  design-clear.sh <index>\n' >&2
        fi
        exit 2
    fi
    # --all-for-doc: also catch UNVALIDATED "token" records for the SAME doc.
    # `arm` names a token `<sha(norm)>.<nonce>` before writing its body, so a
    # write that fails partway (truncated/forged) leaves a correctly-named file
    # with an unparseable body -- _classify_tokens emits it with an EMPTY
    # doc_path (the body is untrusted, so it cannot bind one) and the doc-match
    # loop above can therefore never select it. Left out of TARGETS, it is
    # invisible to the all-or-nothing check below: every healthy sibling for
    # the doc drains, the command exits 0, and the malformed marker for the
    # SAME document stays armed -- reopening Codex's bypass (PR #670) through
    # an unvalidated TOKEN instead of an unbound legacy record. The filename
    # prefix is server-derived (arm writes it, independent of the body it
    # failed to write), so it is trustworthy enough to route the record into
    # the refusal below even though its content cannot be shown.
    if [ "$ALL_FOR_DOC" -eq 1 ]; then
        DOC_SHA="$(python3 -I "$_SELF_DIR/../hooks/gate-scripts/lib/marker_ops.py" sha "$NORM" 2>/dev/null || true)"
        # Fail CLOSED. Without the digest this scan cannot run, and skipping it
        # silently is the whole bypass: the drain would proceed exactly as if no
        # malformed same-doc token existed. python3 is already a hard dependency
        # (the classifier above ran through it), so an empty digest here means
        # something is broken, not absent — refuse rather than release blind.
        if [ -z "$DOC_SHA" ]; then
            printf 'design-clear: cannot compute the doc digest needed to screen for\n' >&2
            printf 'malformed same-document tokens — refusing --all-for-doc.\n\n' >&2
            printf 'Releasing without that screen could drain every healthy token for %s\n' "$SELECTOR" >&2
            printf 'while leaving an unvalidated marker for the SAME doc armed.\n' >&2
            exit 2
        fi
        n=0
        while [ "$n" -lt "${#SRCS[@]}" ]; do
            if [ "${KINDS[$n]}" = "token" ] && [ -z "${DOCS[$n]}" ]; then
                case "$(basename -- "${SRCS[$n]}")" in
                    "$DOC_SHA".*) TARGETS+=( "$n" ) ;;
                esac
            fi
            n=$(( n + 1 ))
        done
    fi
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
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
# Validate EVERY selected record before releasing any of them. Under
# --all-for-doc this is all-or-nothing on purpose: a doc whose token set contains
# an anomalous marker is exactly the state the gate blocks on deliberately, and
# draining the healthy siblings around it would clear the block while leaving the
# anomaly — quietly converting "inspect this" into "already released most of it".
_t=0
while [ "$_t" -lt "${#TARGETS[@]}" ]; do
TARGET="${TARGETS[$_t]}"
if [ "${KINDS[$TARGET]}" = "overflow" ]; then
    # Not a marker at all — the classifier's "this listing was cut" signal
    # (#671). It occupies an index, so an index selector can land on it; there
    # is nothing on disk behind it to release.
    printf 'design-clear: [%d] is a listing-truncation notice (%s), not a marker.\n' \
        "$(( TARGET + 1 ))" "${REASONS[$TARGET]}" >&2
    printf 'It records that the classifier stopped emitting records of that kind;\n' >&2
    printf 'there is nothing to clear. Re-run for the rest, or trim:\n  %s\n' \
        "${SRCS[$TARGET]}" >&2
    exit 1
fi
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
_t=$(( _t + 1 ))
done

# NOTE on the caps and the all-or-nothing check above. The check can only refuse
# on records the classifier EMITTED, and the emitter budgets are capped — so it
# is only sound if a same-doc anomaly can never be the thing that got truncated.
# Two mechanisms hold that, both upstream rather than here:
#   * marker_ops.cmd_classify runs _classify_legacy BEFORE _classify_tokens and
#     the budgets are per-kind (#665 review, Codex), so a token being visible
#     never implies a legacy record was crowded out;
#   * when the legacy budget itself truncates, the classifier says so with an
#     explicit overflow record and every name-based selector is refused before
#     reaching this point (#671) — the screen is never run against a set that is
#     knowably partial.
# What remains is TOKEN truncation, which only under-drains — handled honestly
# by the closing message.
#
# A blanket "refuse whenever TRUNCATED" was the other candidate fix and is NOT
# used: the cap is hit at ~20 pending records, which is precisely the backlog
# size #665 exists to drain, so it would refuse in the feature's own motivating
# scenario (verified: 0 of 23 tokens released) and leave the gate's hint pointing
# at a command that always fails — the defect this change set removes.

# Every target is a validated token for the same doc, so one name covers them all.
DOC="${DOCS[${TARGETS[0]}]}"
N_TARGETS="${#TARGETS[@]}"

printf '\nAbout to release the design-review requirement for:\n\n  %s\n\n' "$DOC"
if [ "$N_TARGETS" -gt 1 ]; then
    printf '%d tokens are bound to it (one per edit that armed a review):\n\n' "$N_TARGETS"
    _t=0
    while [ "$_t" -lt "$N_TARGETS" ]; do
        printf '  %s\n' "${SRCS[${TARGETS[$_t]}]}"
        _t=$(( _t + 1 ))
    done
    printf '\n'
else
    printf 'token: %s\n\n' "${SRCS[${TARGETS[0]}]}"
fi
printf 'The gate will stop blocking on this doc. This is logged to %s/bypass-log.jsonl\n' "$STATE_DIR"
printf '(one event per released token).\n'
fi   # end design-token mode (--skip built its own single target above)

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
    if [ "$N_TARGETS" -gt 1 ]; then
        printf 'Clear all %d? [y/N] ' "$N_TARGETS"
    else
        printf 'Clear it? [y/N] '
    fi
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
    # #519 item 2 — record WHAT was accepted, not just that something was. A doc
    # approved under DEGRADED reviewer coverage has its PASS withheld (#355), so an
    # operator release is the only way forward; the trail must name the coverage the
    # release accepted. Advisory read, never a gate: `|| true` because a doc that
    # cannot be inspected must not abort an otherwise-authorized clear — the helper
    # already prints `none`/`unreadable` rather than failing.
    COVERAGE="$(python3 -I "$_SELF_DIR/../hooks/gate-scripts/lib/marker_ops.py" coverage "$DOC" 2>/dev/null || true)"
    # shellcheck disable=SC2016 # the whole python3 -I -c '...' body below is
    # intentionally single-quoted (it's Python source, not shell) and passes
    # values in via the env vars above, not shell interpolation; the embedded
    # '"'"' quote-escape trick later in the block re-triggers this per segment.
    EVENT="$1" DOC="$DOC" TOKEN_SHA="$TOKEN_SHA" HEAD_SHA="$HEAD_SHA" \
    ROOT_DIR="$ROOT_DIR" CONFIRM="$CONFIRM_MODE" COVERAGE="${COVERAGE:-unknown}" \
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
            # The doc own-line review-coverage marker(s) at release time, verbatim
            # (e.g. "<!-- design-review-coverage: DEGRADED 1/3 -->"), or
            # none/unreadable/unknown. Says WHAT residual the release accepted.
            "coverage": os.environ.get("COVERAGE", "unknown"),
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
# One event per released token, never a single summary event: the trail's unit is
# the review requirement, and #665 asked for the drain to stay as legible as the
# 14 individual clears it replaces. A partial run is therefore fully truthful —
# every token released before the abort has its own durable record.
CLEARED=0
partial_note() {
    [ "$CLEARED" -gt 0 ] || return 0
    printf 'Released %d of %d token(s) for this doc before stopping; the rest stay armed.\n' \
        "$CLEARED" "$N_TARGETS" >&2
}

_t=0
while [ "$_t" -lt "$N_TARGETS" ]; do
    TOKEN="${SRCS[${TARGETS[$_t]}]}"
    if [ "$SKIP_MODE" -eq 1 ]; then
        # A skip marker has no <sha>.<nonce> name to report; an empty field is
        # truthful where a basename would read as a token sha that never existed.
        TOKEN_SHA=""
    else
        TOKEN_SHA="$(basename -- "$TOKEN")"; TOKEN_SHA="${TOKEN_SHA%%.*}"
    fi

    if ! log_event "$CLEAR_EVENT"; then
        printf 'design-clear: could not write the audit event to %s — REFUSING to clear.\n' "$LOG" >&2
        printf 'An unlogged release is not a sanctioned bypass. Resolve the above, then retry.\n' >&2
        partial_note
        exit 2
    fi

    if [ "$SKIP_MODE" -eq 1 ]; then
        skip_probe unlink
        _unlinked=$?
    else
        rm -f -- "$TOKEN"
        _unlinked=$?
    fi
    if [ "$_unlinked" -ne 0 ]; then
        # Already recorded as cleared, but it is not — emit the correction so the
        # trail stays truthful rather than leaving a phantom release on the record.
        if ! log_event "$FAIL_EVENT"; then
            # The log now claims a release that did not happen and the correction
            # could not be appended. Say so loudly — a silently inconsistent audit
            # trail is worse than a noisy one.
            printf 'design-clear: WARNING — the audit log records this token as CLEARED but it\n' >&2
            printf 'was NOT removed, and the correcting entry could not be written. The log at\n' >&2
            printf '%s is INCONSISTENT and needs manual reconciliation.\n' "$LOG" >&2
        fi
        printf 'design-clear: could not remove %s.\n' "$TOKEN" >&2
        partial_note
        exit 2
    fi
    CLEARED=$(( CLEARED + 1 ))
    _t=$(( _t + 1 ))
done

if [ "$SKIP_MODE" -eq 1 ]; then
    printf 'Disarmed %s. The next gate it fed will run its review normally.\n' "$SELECTOR"
elif [ "$TRUNCATED" -eq 1 ]; then
    # The classifier declared that it dropped token records (#671), so this doc
    # may still hold tokens that were never listed — "all for doc" is all the
    # tokens it could SEE. The old wording hedged ("MAY remain") because
    # truncation was INFERRED from a count landing on the cap, which is also
    # what an exactly-full-but-complete listing looks like. The signal is
    # positive now: records really were dropped.
    printf 'Cleared %d token(s). More tokens were pending than were listed — re-run to check.\n' \
        "$CLEARED"
else
    # SRCS holds every listed record across ALL docs (plus non-token markers),
    # not just this one's tokens — say so, or an operator reads the count as
    # leftovers for the doc just drained (CodeRabbit, PR #670).
    printf 'Cleared %d token(s). %d marker record(s) still pending across all docs.\n' \
        "$CLEARED" "$(( ${#SRCS[@]} - CLEARED ))"
fi
