#!/bin/bash -p
# #576: this script is an AUTHORIZATION component — it mints the commit marker — so it
# must refuse to import environment shell functions like the producer and the gates. A
# repo-injected exported `cat` could return an attacker-chosen 64-hex value after the
# index moved, making this writer emit BUILTIN-<current unreviewed diff> even though the
# reviewer saw the earlier prompt — so this file must never run with those functions
# imported. The protection is layered OUTSIDE-IN, and only the outer layers are
# authoritative:
#   1. The `#!/bin/bash -p` shebang on line 1, matching the gates, the producer and the
#      dispatcher. The kernel applies it, so nothing in the environment can shadow it —
#      but it only takes effect when the file is EXECUTED directly.
#   2. The explicit `-p` at the call site, which is the hop that actually happens:
#      SKILL.md invokes this as `/bin/bash -p <script>`, which bypasses the shebang. That
#      `-p` is authoritative and must never be dropped to a plain `bash`.
#   3. The re-exec immediately below — a last-resort fallback for a caller that did
#      neither. It is the WEAKEST layer: by the time it runs, bash has already processed
#      BASH_ENV and imported exported functions, so its own `exec` is shadowable.
# See run-review-loop.sh for the full reasoning.
if [[ "$-" != *p* ]]; then
    # "$BASH", not /bin/bash. bash sets BASH to its own path at startup (overwriting any
    # inherited value), so this re-execs the SAME interpreter with -p added. Hardcoding
    # /bin/bash silently DOWNGRADED the shell — on macOS that is bash 3.2, where an empty
    # `"${arr[@]}"` under `set -u` is an unbound-variable error, and the review aborted
    # on exactly the path that clears REVIEW_EXCLUDE_ARGS. Measured, in the #252 fixture.
    exec "${BASH:-/bin/bash}" -p "$0" "$@"
fi
# #576: put the system directories FIRST so security-critical tools resolve to the real
# binaries. Privileged mode stops exported FUNCTIONS from being imported, but it leaves
# PATH alone — and PATH is repo-injectable the same way env is (#325 / ADR 0016). A
# planted `git` earlier in PATH could emit benign reviewer-facing output while
# delegating the canonical hash to the real git, minting a marker the fixed-PATH gate
# then accepts for content nobody reviewed.
#
# Prepending rather than replacing is deliberate: the review CLI (codex/agy/droid) and
# the SAST tools legitimately live elsewhere, and pinning PATH outright would break
# their resolution — including the PATH stubs the test fixtures rely on. Prepending is
# enough for the tools that matter here, because /usr/bin and /bin are the ones a
# planted git/sha256sum/od/stat/cat would have to beat.
PATH="/usr/bin:/bin:$PATH"
export PATH

# Trusted marker writer for builtin review fallback
# Called via Bash tool (not Write tool) to avoid pre-implementation gate block
# Prefix with BUILTIN- so post-commit-consume-marker.sh can distinguish
# self-reviewed commits from externally-reviewed ones.
#
# Defense-in-depth: validates that run-review-loop.sh actually triggered
# the builtin fallback by checking for the handoff file it creates (exit 3).
# The handoff file is consumed after use (single-use token).
#
# Usage: write-review-marker.sh [--discard] <prompt-path>
#   --discard retires this arming WITHOUT writing a marker — for a builtin review that
#   FAILED, or that is being abandoned. Nothing else retires it: the writer is not
#   invoked on that path, so the handoff would stay armed indefinitely and a later call
#   could mint a marker off a review that never passed. It lives here, not in the
#   caller's cleanup step, because a check-then-delete in the caller is not atomic
#   against a concurrent exit 3 re-arming the pair — the disarm has to hold the review
#   lock, exactly like the write.
#
#   <prompt-path> is the path the caller read from the handoff file and reviewed.
#   It identifies WHICH arming this write belongs to (#790): the handoff lives at one
#   fixed path, so a later exit 3 re-arms it, and a delayed agent that skipped this
#   check would consume somebody else's handoff and compare against somebody else's
#   baseline. NOT an anti-forgery control — a caller holding Bash can read the handoff
#   and pass its content back; it orders concurrent writers, nothing more.
#
#   BUSDRIVER_REVIEW_LOCK_WAIT (seconds, default 90, 0 = one attempt) bounds how long
#   either mode waits for a contended review lock before refusing (#794).
set -euo pipefail
DISCARD=0
if [ "${1:-}" = "--discard" ]; then
    DISCARD=1
    shift
fi
BUILTIN_PROMPT_PATH="${1:-}"
STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
# Constrain to a safe relative name (reject leading-hyphen/absolute/traversal/unsafe
# chars) so the "$REPO_DIR/$STATE_DIR" joins below resolve to the configured state dir.
# The pattern must stay byte-identical to run-review-loop.sh and review_lock_path: a
# value they normalize to .claude but this script accepts (e.g. "-foo") would take the
# .claude review lock while reading a handoff and baseline that live nowhere.
case "$STATE_DIR" in ""|-*|/*|*..*|*[!a-zA-Z0-9._/-]*) STATE_DIR=".claude" ;; esac
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# Validate builtin review was triggered — handoff file is created by
# run-review-loop.sh at exit code 3 (line 495). Without this, the script
# could be called to forge a marker without any review having occurred.
HANDOFF_FILE="$REPO_DIR/$STATE_DIR/builtin-review-prompt-path.local"
if [ ! -f "$HANDOFF_FILE" ]; then
    echo "ERROR: No builtin review handoff found — marker cannot be written." >&2
    echo "       This script should only be called after run-review-loop.sh exits with code 3." >&2
    exit 1
fi
if [ -z "$BUILTIN_PROMPT_PATH" ]; then
    echo "ERROR: No prompt path given — marker cannot be written." >&2
    echo "       Usage: write-review-marker.sh <the prompt path you read from" >&2
    echo "       $STATE_DIR/builtin-review-prompt-path.local and reviewed>" >&2
    exit 1
fi

MARKER_FILE="$REPO_DIR/$STATE_DIR/litmus-passed.local"
BASELINE_FILE="$REPO_DIR/$STATE_DIR/builtin-review-marker-baseline.local"
GEN_FILE="$REPO_DIR/$STATE_DIR/litmus-marker-gen.local"

# Do not overwrite a marker some OTHER run published after our handoff was armed
# (#790). The review lock is released at exit 3 so the agent can run, so a second
# litmus run can complete an ordinary review and publish its marker while this
# run's agent is still thinking. Our write would then replace a newer review's
# marker with an older hash — the gate compares marker to staged diff, so the
# result is a spuriously blocked commit, not a forged authorization.
#
# The test is the marker GENERATION token against the baseline run-review-loop.sh
# snapshotted at exit 3. Every publisher stamps a fresh token before writing the marker
# (publish_marker_gen there, and this script below), so any publication moves it.
# Neither cheaper test works: a timestamp is only as fine as `-nt`, which on bash 3.2
# — this script's interpreter on macOS — is seconds-granular; and a content digest
# misses an ABA republication of byte-identical content.
#
# NOT the freshness check that was tried and reverted (refusing when the reviewed
# hash no longer matches the current index). That one also refuses in the ordinary
# late-hash case this writer exists to handle, where the correct behaviour is to
# mint the marker for the REVIEWED diff and let the gate block the mutated one.
# This compares the marker against its OWN baseline: with nobody else publishing,
# the write always proceeds however far the index has moved.
#
# The check and the write are made atomic against the ordinary PASS path by taking
# the SAME review lock that path holds for its whole run (lib/review-lock.sh). Without
# it the ordering test is check-then-act: a marker published between the test and the
# redirection below is clobbered anyway, which is the very race this closes. We hold it
# only for the write — not across the agent phase, which is what exit 3 releases it for.
#
# Contention is a bounded WAIT, then a refusal (#794). It used to be an immediate
# refusal, on the reasoning that the run holding the lock would publish its own marker.
# That holds only when that run PASSES: one ending in findings, a timeout or an infra
# error publishes nothing, and this already-passed review had refused too — so no marker
# existed and the next commit was spuriously blocked. Nothing performed the documented
# retry automatically, because SKILL.md's builtin flow invokes this writer once.
#
# Waiting is safe precisely because none of the ordering checks move: whatever the other
# run did while we waited is caught AFTER we acquire. If it published, the generation
# comparison below refuses and its marker stands. If it re-armed the handoff, the
# identity check refuses and consumes nothing. If it published nothing, we publish —
# which is the case this wait exists for. We are only retrying the acquisition.
#
# --discard waits for the same reason, in its sharper form: a FAILED review that refused
# here left its own arming live (the caller-side `rm` this mode replaced always retired
# it), and until the retry happened that arming could be handed back here and mint a
# marker for the current index despite the FAILED verdict. Deleting anyway on contention
# is still NOT the fix — that is the unsynchronized delete this mode exists to remove.
#
# Bounded, not unbounded: this runs inside a Bash tool call, so an unbounded wait is not
# actually available — exceeding the caller's timeout kills the writer mid-wait, which
# lands in the same armed-retry state as the timeout refusal but without the diagnostic.
# The default sits under the Bash tool's own 120s default for that reason. Raising
# BUSDRIVER_REVIEW_LOCK_WAIT past it requires raising the caller's timeout to match.
#
# An ORPHANED lock (owner SIGKILLed) now costs the full wait before the "remove it
# yourself" hint. Deliberate: `kill -0` liveness is diagnostic-only by lib/review-lock.sh's
# own doctrine — pid reuse makes it unsafe to shortcut a decision on — and the library
# does not reclaim orphans for the same reason.
LOCK_WAIT="${BUSDRIVER_REVIEW_LOCK_WAIT:-90}"
# Digits only. A garbage value must fall back, not crash the comparison under `set -u`
# / bash 3.2 arithmetic. 0 means "one attempt", i.e. the pre-#794 behaviour.
case "$LOCK_WAIT" in ""|*[!0-9]*) LOCK_WAIT=90 ;; esac
cd "$REPO_DIR"
# shellcheck source=lib/review-lock.sh
source "$SCRIPT_DIR/lib/review-lock.sh"
# review_lock_acquire MUST run in this shell, never in `$( )` or a pipeline: it records
# ownership in shell variables keyed to BASHPID, and a subshell claim leaves the lock
# held but never released. Retry only rc=1 (someone holds it); rc=2 is an unusable state
# dir, which no amount of waiting fixes.
_LOCK_RC=0
review_lock_acquire || _LOCK_RC=$?
_WAITED=0
while [ "$_LOCK_RC" -eq 1 ] && [ "$_WAITED" -lt "$LOCK_WAIT" ]; do
    sleep 1
    _WAITED=$((_WAITED + 1))
    _LOCK_RC=0
    review_lock_acquire || _LOCK_RC=$?
done
if [[ "$_LOCK_RC" -ne 0 ]]; then
    _LOCK_PATH=$(review_lock_path)
    _LOCK_OWNER=$(review_lock_owner)
    _LOCK_STATE=$(review_lock_owner_state)
    if [ "$DISCARD" -eq 1 ]; then
        # Before refusing, make the arming UNUSABLE. Documenting "re-run this later" is
        # not a cleanup mechanism: until that retry happens, a FAILED review's arming can
        # still be handed to the normal write path and mint a marker for whatever is
        # staged. Retiring the #576 hash sidecar closes that without reintroducing the
        # unsynchronized delete this mode exists to remove — the sidecar is keyed to THIS
        # prompt's basename (a per-run mktemp name), so it is ours alone and cannot be a
        # newer run's, whereas the handoff and baseline live at shared fixed paths and
        # must not be touched without the lock. With no sidecar the writer refuses for
        # want of a reviewed hash, which is the fail-CLOSED direction; the pair itself is
        # still retired by the retry below (#794).
        _DC_BASE="${BUILTIN_PROMPT_PATH##*/}"
        case "$_DC_BASE" in
            busdriver-review-?*) : ;;
            *) _DC_BASE="" ;;
        esac
        case "$_DC_BASE" in
            */*|*..*|*'
'*) _DC_BASE="" ;;
        esac
        if [ -n "$_DC_BASE" ]; then
            rm -f "$REPO_DIR/$STATE_DIR/builtin-review-${_DC_BASE}.hash"
        fi
        echo "ERROR: Could not take the review lock — handoff NOT discarded." >&2
        echo "       Lock: $_LOCK_PATH (owner pid $_LOCK_OWNER, $_LOCK_STATE)" >&2
        echo "       Waited ${_WAITED}s (BUSDRIVER_REVIEW_LOCK_WAIT=$LOCK_WAIT) and it is still held." >&2
        echo "       Your failed review's handoff is STILL ARMED and nothing else retires it." >&2
        echo "       Its reviewed-diff hash HAS been retired, so the handoff can no longer" >&2
        echo "       mint a marker — but re-run this --discard with the same prompt path once" >&2
        echo "       that run finishes, or the pair stays armed and blocks the next review" >&2
        echo "       from arming its own. (#794)" >&2
        echo "       If that owner is NOT running, the lock is an orphan — remove it yourself." >&2
        exit 1
    fi
    echo "ERROR: Could not take the review lock — marker not written." >&2
    echo "       Lock: $_LOCK_PATH (owner pid $_LOCK_OWNER, $_LOCK_STATE)" >&2
    echo "       Waited ${_WAITED}s (BUSDRIVER_REVIEW_LOCK_WAIT=$LOCK_WAIT) and it is still held." >&2
    echo "       Nothing was consumed here and the handoff is still armed, so once that run" >&2
    echo "       finishes, re-run THIS script with the same prompt path to publish your" >&2
    echo "       result — or re-run /litmus if the handoff is gone. (#794)" >&2
    echo "       If that owner is NOT running, the lock is an orphan — remove it yourself." >&2
    exit 1
fi
trap 'review_lock_release' EXIT

# The wait above stretches the window between the existence check at the top and the
# read below, so re-check rather than letting `cat` die as a bare set -e failure.
if [ ! -f "$HANDOFF_FILE" ]; then
    echo "ERROR: The builtin handoff disappeared while waiting for the review lock." >&2
    echo "       Nothing was written. Re-run /litmus to arm a fresh one." >&2
    exit 1
fi

# Is the armed handoff still OURS? Both the handoff and its baseline are rewritten by
# every exit 3, so a builtin fallback that started after ours has replaced the pair —
# and the baseline below would then describe ITS starting point, not ours, which is
# exactly how a marker published in between reads as "unchanged". Refuse, and consume
# NOTHING: the armed pair belongs to that other run's agent.
HANDOFF_PATH_NOW=$(cat "$HANDOFF_FILE")
if [[ "$HANDOFF_PATH_NOW" != "$BUILTIN_PROMPT_PATH" ]]; then
    echo "ERROR: The builtin handoff was re-armed by a later review — marker not written." >&2
    echo "       Armed for: $HANDOFF_PATH_NOW" >&2
    echo "       You reviewed: $BUILTIN_PROMPT_PATH" >&2
    echo "       That review publishes its own marker. Re-run /litmus if yours must land." >&2
    exit 1
fi

# --discard: the arming is ours and this review is not going to publish. Retire the set
# under the lock and stop — no marker, no generation stamp, nothing for the gate to read.
if [ "$DISCARD" -eq 1 ]; then
    # The #576 hash sidecar belongs to this arming too — leaving it behind would strand
    # a private temp file naming a diff nothing will ever mint a marker for.
    _DISCARD_BASE="${BUILTIN_PROMPT_PATH##*/}"
    case "$_DISCARD_BASE" in
        busdriver-review-?*) : ;;
        *) _DISCARD_BASE="" ;;
    esac
    case "$_DISCARD_BASE" in
        */*|*..*|*'
'*) _DISCARD_BASE="" ;;
    esac
    if [ -n "$_DISCARD_BASE" ]; then
        rm -f "$REPO_DIR/$STATE_DIR/builtin-review-${_DISCARD_BASE}.hash"
    fi
    rm -f "$HANDOFF_FILE" "$BASELINE_FILE"
    echo "Builtin review handoff discarded (no marker written)"
    exit 0
fi

# No baseline means the handoff was armed by a version that did not record one, or it
# was removed — either way this write cannot be ordered against a concurrent one, so
# refuse rather than assume. Fail-CLOSED, and cheap to recover from: re-run /litmus.
if [[ ! -f "$BASELINE_FILE" ]]; then
    rm -f "$HANDOFF_FILE"
    echo "ERROR: No marker baseline for this handoff — marker cannot be written." >&2
    echo "       Expected $STATE_DIR/builtin-review-marker-baseline.local, written at exit 3." >&2
    echo "       Re-run /litmus so the builtin handoff is armed afresh." >&2
    exit 1
fi

# Refuse only when a marker EXISTS and the generation has moved — that pair means
# somebody else published. A marker that has since been REMOVED (post-commit consume)
# leaves nothing to clobber, so the write proceeds however far the token has moved.
# The generation THIS arming stamps when it publishes, derived from the per-run mktemp
# prompt basename (validated just below, and equal to the handoff we matched above). Only
# this arming ever writes it: the runner stamps pid-epoch-nonce, and another arming has
# another basename — so a genuinely newer publication still moves the token off BOTH the
# baseline and this value and is still refused. Recognising our own stamp is what lets a
# retry finish a publication that was interrupted between the two renames below, instead of
# reading our own token as somebody else's review and spending a reviewed arming (#847).
# It is not authorization: like the baseline it is compared against, the token only toggles
# a liveness refusal, and whoever can forge it can write the marker directly.
PROMPT_BASE="${BUILTIN_PROMPT_PATH##*/}"
# Match the template's PREFIX, not a fixed width: `mktemp -t busdriver-review-XXXXXX`
# yields different basenames per platform — BSD/macOS keeps the literal XXXXXX and
# appends its own random suffix, GNU substitutes the X's. A fixed-width pattern
# silently rejects every real handoff on one of them.
case "$PROMPT_BASE" in
    busdriver-review-?*) : ;;
    *) PROMPT_BASE="" ;;
esac
# Belt and braces after the basename strip: no separator, no traversal, no newline.
case "$PROMPT_BASE" in
    */*|*..*|*'
'*) PROMPT_BASE="" ;;
esac
OWN_GEN="builtin-$PROMPT_BASE"
if [[ -f "$MARKER_FILE" ]]; then
    MARKER_GEN_NOW="ABSENT"
    if [[ -f "$GEN_FILE" ]]; then
        MARKER_GEN_NOW=$(cat "$GEN_FILE")
    fi
    MARKER_BASELINE=$(cat "$BASELINE_FILE")
    if [[ "$MARKER_GEN_NOW" != "$MARKER_BASELINE" ]] \
       && { [[ -z "$PROMPT_BASE" ]] || [[ "$MARKER_GEN_NOW" != "$OWN_GEN" ]]; }; then
        rm -f "$HANDOFF_FILE" "$BASELINE_FILE"
        echo "ERROR: A newer review already published $STATE_DIR/litmus-passed.local — not overwriting it." >&2
        echo "       Another litmus run finished while this builtin review was in flight." >&2
        echo "       Its marker stands. If your commit is blocked, re-run /litmus." >&2
        exit 1
    fi
fi

# The handoff (single-use token), its baseline and the #576 hash sidecar are ONE arming,
# spent only once the marker is published (#847): a completion that cannot be recorded or
# a marker that cannot be written leaves the whole arming for a retry with the same prompt
# path, instead of throwing away a finished review. Retrying grants nothing the arming did
# not already hold — the same reviewed hash, the same lock, identity and generation checks.

mkdir -p "$REPO_DIR/$STATE_DIR"
# #576 closes the SCOPE caveat #790 left open here. This used to re-hash the index as
# it stood NOW — but everything between exit 3 and this line IS the builtin review, so
# the recomputed hash described whatever was staged when the agent FINISHED, not what
# it was asked to review. A marker minted for diff A would name diff B, and since #545
# the gate compares marker to staged diff: that mismatch stopped blocking and started
# certifying. The reviewed hash travels through the handoff instead, in a sidecar
# written beside the prompt at exit 3.
#
# Fail CLOSED, with no fall back to a fresh diff: a missing or malformed sidecar means
# this is not the handoff the review started from, and re-deriving the hash here would
# reinstate exactly that bug. Refusing costs a re-run; a forged binding costs an
# unreviewed commit.
#
# The sidecar is keyed to the PER-RUN mktemp prompt basename, and the path is rebuilt
# inside the state dir we already own rather than trusted from the handoff. The handoff
# is a state file, so its content is UNTRUSTED INPUT — and this script both reads and
# unlinks the sidecar derived from it. Validating an absolute path by prefix is not
# enough: the prefix constrains only the last component, so "/anywhere/
# busdriver-review-data.hash" would pass and the unlink would reach outside the state
# dir. (Anyone able to write the handoff can already write the marker directly, so this
# is not the last line of defence — it just refuses to lend them a delete primitive.)
# PROMPT_BASE was derived and validated with OWN_GEN above, before the generation check.
HASH=""
HASH_FILE=""
BIND=""
if [ -n "$PROMPT_BASE" ]; then
    HASH_FILE="$REPO_DIR/$STATE_DIR/builtin-review-${PROMPT_BASE}.hash"
    # Refuse a symlink: run-review-loop.sh creates the sidecar with O_EXCL, which never
    # follows one, so a symlink here means somebody else made it.
    if [ ! -L "$HASH_FILE" ] && [ -f "$HASH_FILE" ]; then
        HASH=$(sed -n 1p "$HASH_FILE" 2>/dev/null || echo "")
        # #847 line 2: the cycle, the attempt COUNT the arming was made at, and the attempt
        # SEQUENCE this review inherited (0 for a direct builtin, which inherits none) — or "-"
        # for a run that had no identity. The hash names a DIFF, never a cycle — a later attempt
        # reviewing the same diff carries it too — so the binding travels beside it and is
        # exactly as mandatory: a sidecar without one is not a handoff this writer can place.
        BIND=$(sed -n 2p "$HASH_FILE" 2>/dev/null || echo "")
    fi
fi
case "$HASH" in
    *[!0-9a-f]* | "") HASH="" ;;
esac
[[ "$BIND" =~ ^(-|[0-9a-f]{32}\ [0-9]+\ [0-9]+)$ ]] || BIND=""
if [ "${#HASH}" -ne 64 ] || [ -z "$BIND" ]; then
    # A missing or malformed binding is never retried: the whole arming is spent here, so it
    # costs a litmus re-run rather than leaving a sidecar armed for a second try.
    rm -f "$HANDOFF_FILE" "$BASELINE_FILE" ${HASH_FILE:+"$HASH_FILE"}
    echo "ERROR: Missing or malformed reviewed-diff handoff — marker cannot be written." >&2
    echo "       Expected a 64-char SHA-256 on line 1 of the .hash sidecar of the mktemp prompt" >&2
    echo "       file, and on line 2 its cycle binding (\"<cycle_id> <attempt_count> <attempt_seq>\"," >&2
    echo "       or \"-\" for a run with no identity), both written by run-review-loop.sh at" >&2
    echo "       exit code 3. Re-run /litmus." >&2
    exit 1
fi

# #847: a reviewed PASS completes an identity-bearing cycle the way the runner's own PASS
# does — ledger first, then the marker, then state and per-run history; the lineage ledger
# keeps the count. Only the cycle THIS arming parked, which the sidecar binding names and the
# ledger confirms is still owed it — so a newer verdict or attempt is never settled here.
# Deliberately NOT read from the state file: `builtin_handoff` was the old gate and a later
# dispatch clears it, which turned "no cycle named" into "publish anyway". The `pass builtin` record is what
# closes the cycle: an external attempt that failed over to this review was charged and has
# no verdict, and without the record it stays the lineage tail, so the finished cycle would
# be resumed (same mode) or refused (other mode). A cycle that is not open (ledger_admit:
# unknown, retired or already completed), or an append that fails, publishes nothing and keeps
# state, history and the arming, so the same prompt path retries once the ledger is repaired.
# The one closed cycle a retry may publish over is one this arming itself closed as builtin on
# an earlier call whose marker could not be written: the state still names this handoff, and a
# cycle closes once, so no other arming can have closed it. Nothing is recorded a second time.
STATE_FILE="$REPO_DIR/$STATE_DIR/litmus-state.md"
_COMPLETE=0
_CYCLE=""; _LINEAGE=""; _LEDGER_SOURCED=0
_use_ledger() {
    [ "$_LEDGER_SOURCED" = 1 ] && return 0
    # The library derives its paths from BUSDRIVER_STATE_DIR: hand it the validated value.
    export BUSDRIVER_STATE_DIR="$STATE_DIR"
    # shellcheck source=lib/iteration-history.sh
    source "$SCRIPT_DIR/lib/iteration-history.sh"
    # get_yaml_value, for the state-OWNERSHIP test below — the same reader the runner uses on
    # the same field of the same file, so the two can never disagree about which cycle the
    # state names. Sourced AFTER the export above: validation.sh re-derives STATE_DIR from the
    # environment with a laxer pattern than this script's, and the exported value is what
    # keeps it at the one already validated here.
    # shellcheck source=lib/validation.sh
    source "$SCRIPT_DIR/lib/validation.sh"
    _LEDGER_SOURCED=1
}
# ONE identity path, and the arming binding is the authority on it. Identity used to be read
# from the state file when it was PRESENT and from the ledger only when it was GONE — and the
# state-present branch asked `builtin_handoff`, which every later external dispatch clears
# before it runs. So with the state file KEPT that branch read no cycle, never consulted the
# ledger at all, and published: the stale-arming refusal the ledger path enforces sat one
# branch away, reachable by leaving the state file in place instead of deleting it. On the
# same diff the older armed hash still matches the staged index, so the marker it published
# authorized at the gate the very diff the later review had just FAILed. Collapsing the two
# branches is the fix — there is no second path left to fall through.
#
# The binding is the cycle and the attempt sequence this arming was made at, plus the reviewed
# diff hash the runner wrote onto that very attempt; all three were validated above. A "-"
# binding is a run that had no identity: no cycle is owed a completion, the pre-identity case.
# Otherwise a ledger that cannot confirm the NAMED cycle still owes this completion refuses and
# keeps the whole arming, so the cost is a litmus re-run rather than an authorization minted
# over a superseded review.
_use_ledger
_OWNER=""; _BC=""; _BA=""; _BS=""
[ "$BIND" = "-" ] || read -r _BC _BA _BS <<<"$BIND"
if [ -z "$_BC" ]; then
    # "-" used to be exempt from every check below simply by NAMING nothing — the same shape
    # the cycle-less PR lead artifact had, and the same defect: an authorization carrying less
    # information was asked for less proof. Retain such a handoff, init an identity-bearing
    # cycle, let it FAIL on this very diff, and this writer still published BUILTIN-<hash> —
    # authorizing at the gate the diff that review had just rejected, with no newer marker
    # generation in the way, because a FAIL publishes none.
    #
    # It is honoured only where its own story holds: a checkout that has minted no cycle at
    # all, which is the ledger being absent or holding nothing. An unreadable ledger is not
    # that checkout either, and refuses with it. Its other half — a state file that DOES name
    # a cycle — is the ownership test below, which "" fails against any named cycle.
    # -e FOLLOWS the link, so a DANGLING symlink at the ledger path reads as "no ledger here"
    # — the one shape that is neither of the two this branch is allowed to honour. It is not a
    # checkout that minted nothing (something put a ledger path there on purpose) and it is
    # not an empty one; it is a ledger that cannot be read, which the very next clause exists
    # to refuse. Skipping the query on it let a retained "-" arming publish its marker against
    # an explicitly unusable ledger. -L catches the link whether or not it resolves, and the
    # query then refuses it, as it already does for a symlink that points somewhere real.
    if { [ -e "$LINEAGE_LEDGER_FILE" ] || [ -L "$LINEAGE_LEDGER_FILE" ]; } && ! ledger_query empty; then
        echo "ERROR: This arming names no cycle, but $LINEAGE_LEDGER_FILE holds cycles minted in this checkout — marker not written." >&2
        echo "       Nothing was consumed: state, history and this arming are kept. Re-run" >&2
        echo "       /litmus so the review is armed with the cycle it is reviewing." >&2
        exit 1
    fi
else
    # KEEPING THE ARMING IS RIGHT; the advice that went with it was not. Both refusals below
    # keep everything — that is deliberate, and the three checks further down rely on it: an
    # arming may belong to a checkout that is not this one, so nothing here may destroy it.
    # But they are not the same refusal. 8 says the ledger was READ and can never owe this
    # completion again: a newer cycle superseded this one, or this cycle holds an attempt
    # past the one armed, and the ledger is append-only. "Repair the ledger, then re-run"
    # cannot resolve that — there is nothing to repair — and since the runner only names the
    # handoff files in its own arming message, an operator following this one had no way
    # forward at all while the un-consumed handoff blocked every later arming. Name the
    # retirement this script already implements instead. Any OTHER status is a ledger that
    # is unreadable, unparseable or gone, where repair-and-retry is exactly right.
    _BO_RC=0
    _OWNER=$(ledger_query builtin_owner "$HASH" "$_BC" "$_BA" "$_BS") || _BO_RC=$?
    if [ "$_BO_RC" = 8 ]; then
        echo "ERROR: cycle $_BC can no longer be owed this completion — it is superseded, or it has been reviewed again since this handoff was armed — marker not written." >&2
        echo "       Nothing was consumed: state, history and this arming are kept, and no" >&2
        echo "       repair can make this binding valid again — the ledger is append-only." >&2
        echo "       Retire this arming with:  $0 --discard $BUILTIN_PROMPT_PATH" >&2
        echo "       then re-run /litmus to review the current diff." >&2
        exit 1
    elif [ "$_BO_RC" != 0 ]; then
        echo "ERROR: $LINEAGE_LEDGER_FILE cannot confirm cycle $_BC still owes this review its completion — marker not written." >&2
        echo "       Nothing was consumed: state, history and this arming are kept. Repair the" >&2
        echo "       ledger, then re-run this writer with the same prompt path." >&2
        exit 1
    fi
fi
read -r _LINEAGE _CYCLE <<<"$_OWNER" || true

# WHOSE CHECKOUT IS THIS. builtin_owner decides supersession WITHIN a key: it refuses once a
# newer cycle is born under the key the armed cycle was born under. What it cannot see is the
# checkout moving OUT of that key — switch to another branch, force-init there, and the newer
# cycle is born under a key the armed cycle never had, so no record of the armed cycle changes
# and the query still accepts it. Publishing then minted a marker over that other branch review
# and deleted its history.
#
# So publication is bound to the key of the checkout it is publishing INTO, not only to the
# armed cycle: the current key must be the key this cycle was born under. The two halves cover
# each other — same key is decided in the ledger, a different key is refused here — and both are
# read from append-only records and from git, never from the state file, whose deletion is what
# defeated the previous form of this check.
#
# EQUALITY, and nothing else. An unprovable key (detached HEAD, shallow clone, unborn branch —
# lineage_key returns non-zero) was refused outright, and that was too broad: init PERMITS a
# keyless cycle in exactly those checkouts and the runner arms its builtin handoff, so refusing
# left a review that could never be completed, and re-arming produced another one. The two
# keyless situations are not the same question. Born keyless and still keyless is the checkout
# that armed it, as attributable as it ever was — accept, still subject to supersession, which
# compares keyless births against keyless births. Born under a KEY and now unprovable is a
# checkout that may have moved, which equality already refuses, because "" is not that key.
_CUR_KEY=$(lineage_key || true)
if [ -n "$_CYCLE" ]; then
    _ARM_KEY=$(ledger_query birth_key "$_CYCLE" || true)
    if [ "$_CUR_KEY" != "$_ARM_KEY" ]; then
        echo "ERROR: This arming completes cycle $_CYCLE, born under '${_ARM_KEY:-<none>}', but this checkout is '${_CUR_KEY:-<unprovable>}' — marker not written." >&2
        echo "       The checkout moved, or cannot prove which lineage it is on, so this review" >&2
        echo "       is not the one it is being asked to authorize. Nothing was consumed: state," >&2
        echo "       history and this arming are kept. Re-run /litmus where the cycle was armed." >&2
        exit 1
    fi
fi

# WHOSE STATE IS THIS. The completion below deletes the state file and the findings history,
# and nothing asked whose they were: both live at a fixed path in the state dir, one per
# CHECKOUT and not one per cycle. So an arming made on branch A, completed after a force-init
# FAILed cycle B on another branch, passed both checks above — B is born under another key, so
# it is invisible to supersession and to the key equality — and the cleanup then erased B's
# state and B's findings, losing the convergence history B is still owed.
#
# The state file is read here ONLY to answer that question, never as a source of identity: the
# binding names the cycle, and reading identity from this file is the bypass this writer
# already closed (a deleted state file must not authorize anything, and still does not — an
# absent one proves nothing and settles nothing). A state file naming ANOTHER cycle refuses
# before the marker, which is also the "-" arming's second half: "" owns no named cycle.
_STATE_CYCLE=""
if [ -f "$STATE_FILE" ]; then
    _STATE_CYCLE=$(get_yaml_value "cycle_id" "$STATE_FILE" 2>/dev/null || true)
fi
case "$_STATE_CYCLE" in null) _STATE_CYCLE="" ;; esac
if [ -n "$_STATE_CYCLE" ] && [ "$_STATE_CYCLE" != "$_CYCLE" ]; then
    echo "ERROR: $STATE_FILE belongs to cycle $_STATE_CYCLE, not to ${_CYCLE:-the cycle-less review} this arming completes — marker not written." >&2
    echo "       Completing here would delete that cycle's state and findings. Nothing was" >&2
    echo "       consumed: state, history and this arming are kept. Re-run /litmus in the" >&2
    echo "       checkout this review was armed in." >&2
    exit 1
fi
case "$_CYCLE" in ""|null) ;; *)
    _use_ledger
    if ledger_admit "$_LINEAGE" "$_CYCLE"; then
        if ! ledger_append pass "lineage_id=$_LINEAGE" "cycle_id=$_CYCLE" "review_basis=builtin" \
           || ! ledger_query usable; then
            echo "ERROR: Could not close cycle $_CYCLE in $LINEAGE_LEDGER_FILE — marker not written." >&2
            echo "       Nothing was consumed: state, history and this arming are kept. Repair the" >&2
            echo "       ledger, then re-run this writer with the same prompt path." >&2
            exit 1
        fi
    elif [ "$(ledger_query closed "$_CYCLE" || true)" != 1 ] \
         || [ "$(ledger_query completion_basis "$_CYCLE" || true)" != builtin ]; then
        echo "ERROR: Cycle $_CYCLE is not open in $LINEAGE_LEDGER_FILE (missing, unreadable, unknown, retired or completed) — marker not written." >&2
        echo "       Nothing was consumed: state, history and this arming are kept. Repair the" >&2
        echo "       ledger and re-run this writer with the same prompt path, or re-run /litmus." >&2
        exit 1
    fi
    _COMPLETE=1 ;;
esac

# Stamp the generation BEFORE the marker, same ordering and reason as
# publish_marker_gen in run-review-loop.sh: a crash between the two must leave a moved
# token in front of an old marker (the next delayed writer refuses), never the reverse.
# #847: both land by rename, never by writing through the path. Writing into an existing
# marker could fail AFTER the generation moved, and the retry of this same arming then read
# its own stamp as a newer publication and spent itself. Each file is complete in a private
# temp (mktemp: O_EXCL, never follows a link) before anything moves, so any failure up to the
# first rename moves nothing and leaves the arming for a retry; rename replaces a link or a
# read-only file at the path without following or opening it. A directory there would take
# the temp INTO it, so that is refused first. Only a crash between the two renames still
# leaves a moved token in front of the old marker — refused on retry, the fail-CLOSED side.
_MTMP=""; _GTMP=""
if [ -d "$MARKER_FILE" ] || [ -d "$GEN_FILE" ] \
   || ! _MTMP=$(mktemp "$REPO_DIR/$STATE_DIR/.pub-marker.XXXXXX") \
   || ! printf 'BUILTIN-%s\n' "$HASH" > "$_MTMP" \
   || ! _GTMP=$(mktemp "$REPO_DIR/$STATE_DIR/.pub-gen.XXXXXX") \
   || ! printf '%s\n' "$OWN_GEN" > "$_GTMP" \
   || ! mv -f "$_GTMP" "$GEN_FILE" || ! mv -f "$_MTMP" "$MARKER_FILE"; then
    rm -f ${_MTMP:+"$_MTMP"} ${_GTMP:+"$_GTMP"}
    echo "ERROR: Could not publish $MARKER_FILE — marker not written." >&2
    echo "       Nothing was consumed: this arming is kept. Repair the state directory, then" >&2
    echo "       re-run this writer with the same prompt path." >&2
    exit 1
fi
echo "Review marker written (builtin)"
# Published: only now is the arming spent, so a replay finds no handoff.
rm -f "$HANDOFF_FILE" "$BASELINE_FILE" "$HASH_FILE"

# After the marker, never before: a crash in between leaves the cycle parked, not erased.
# Only the files the completed cycle OWNS are removed — the state file that names it, and the
# findings history beside it. Anything else at those paths belongs to another cycle (refused
# above) or to nobody provable (an absent state file), and a fresh init clears the history it
# does not archive or resume, so leaving it costs nothing the next cycle keeps.
if [ "$_COMPLETE" -eq 1 ]; then
    if [ "$_STATE_CYCLE" = "$_CYCLE" ]; then
        rm -f "$STATE_FILE" "$REPO_DIR/$STATE_DIR/litmus-iteration-history.local.jsonl"
    fi
    echo "Review cycle completed (builtin PASS)"
fi
