#!/bin/bash
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
# Contention is a refusal, not a wait: the other run holds the lock because it is
# reviewing. The handoff is left ARMED in that case (unlike the refusal below) —
# nothing was written, so a retry once the other run finishes is the cheapest correct
# outcome, and the token was already armed anyway.
#
# KNOWN RESIDUAL (#794): "it will publish its own marker" holds only when that run
# PASSES. A run that ends with findings, a timeout or an infra error publishes nothing,
# and this already-passed review has refused too — so no marker exists and the next
# commit is spuriously blocked until the retry above actually happens. Nothing performs
# that retry automatically: SKILL.md's builtin flow invokes this writer once. The cost
# is bounded at the level #790 already accepted (a re-run), so the diagnostic below
# NAMES the retry rather than the design changing here; waiting for the lock instead is
# tracked in #794.
#
# --discard inherits that residual and is the sharper half of it: a FAILED review that
# refuses here leaves its own arming live, where the caller-side `rm` this replaced would
# have retired it unconditionally. Nothing else retires it, so until the retry happens
# that arming can still be handed back to this script and mint a marker for the current
# index despite the FAILED verdict. It is not fixed by deleting anyway on contention —
# that is precisely the unsynchronized delete this mode exists to remove, and it can
# destroy a newer run's pair. So the refusal is mode-aware below and says to retry, and
# the wait-instead-of-refuse design change is tracked in #794 for both modes together.
cd "$REPO_DIR"
# shellcheck source=lib/review-lock.sh
source "$SCRIPT_DIR/lib/review-lock.sh"
_LOCK_RC=0
review_lock_acquire || _LOCK_RC=$?
if [[ "$_LOCK_RC" -ne 0 ]]; then
    _LOCK_PATH=$(review_lock_path)
    _LOCK_OWNER=$(review_lock_owner)
    _LOCK_STATE=$(review_lock_owner_state)
    if [ "$DISCARD" -eq 1 ]; then
        echo "ERROR: Could not take the review lock — handoff NOT discarded." >&2
        echo "       Lock: $_LOCK_PATH (owner pid $_LOCK_OWNER, $_LOCK_STATE)" >&2
        echo "       Your failed review's handoff is STILL ARMED and nothing else retires it." >&2
        echo "       Re-run this --discard with the same prompt path once that run finishes;" >&2
        echo "       until you do, that arming can still be handed back here and mint a marker" >&2
        echo "       for whatever is staged, despite your FAILED verdict. (#794)" >&2
        echo "       If that owner is NOT running, the lock is an orphan — remove it yourself." >&2
        exit 1
    fi
    echo "ERROR: Could not take the review lock — marker not written." >&2
    echo "       Lock: $_LOCK_PATH (owner pid $_LOCK_OWNER, $_LOCK_STATE)" >&2
    echo "       Another litmus review is in flight. If it PASSES it publishes its own" >&2
    echo "       marker; if it ends with findings, a timeout or an infra error it does not." >&2
    echo "       Nothing was consumed here and the handoff is still armed, so once that run" >&2
    echo "       finishes, re-run THIS script with the same prompt path to publish your" >&2
    echo "       result — or re-run /litmus if the handoff is gone. (#794)" >&2
    echo "       If that owner is NOT running, the lock is an orphan — remove it yourself." >&2
    exit 1
fi
trap 'review_lock_release' EXIT

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

# --discard: the arming is ours and this review is not going to publish. Retire the pair
# under the lock and stop — no marker, no generation stamp, nothing for the gate to read.
if [ "$DISCARD" -eq 1 ]; then
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
if [[ -f "$MARKER_FILE" ]]; then
    MARKER_GEN_NOW="ABSENT"
    if [[ -f "$GEN_FILE" ]]; then
        MARKER_GEN_NOW=$(cat "$GEN_FILE")
    fi
    MARKER_BASELINE=$(cat "$BASELINE_FILE")
    if [[ "$MARKER_GEN_NOW" != "$MARKER_BASELINE" ]]; then
        rm -f "$HANDOFF_FILE" "$BASELINE_FILE"
        echo "ERROR: A newer review already published $STATE_DIR/litmus-passed.local — not overwriting it." >&2
        echo "       Another litmus run finished while this builtin review was in flight." >&2
        echo "       Its marker stands. If your commit is blocked, re-run /litmus." >&2
        exit 1
    fi
fi

# Consume the handoff file (single-use token) and its baseline
rm -f "$HANDOFF_FILE" "$BASELINE_FILE"

mkdir -p "$REPO_DIR/$STATE_DIR"
# Bare `git diff --cached` — must stay byte-identical to pre-commit-gate.sh's
# STAGED_HASH, the writes in run-review-loop.sh, and dispatcher-commit-block.sh.
# Since #545 the gate COMPARES this hash to the staged diff instead of merely
# checking the marker exists, so any flag added on one side and not the others
# stops every marker from matching and blocks every commit.
#
# SCOPE: this hashes the index as it stands NOW, not the diff the agent was handed at
# exit 3, so an index that moved mid-review yields a marker for something nobody
# reviewed. Pre-existing and deliberately untouched by #790, which is about ordering
# this write against other publishers; minting for the REVIEWED diff is #576's change
# and needs the reviewed hash carried through the handoff.
HASH=$(git diff --cached 2>/dev/null | (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1)
# Stamp the generation BEFORE the marker, same ordering and reason as
# publish_marker_gen in run-review-loop.sh: a crash between the two must leave a moved
# token in front of an old marker (the next delayed writer refuses), never the reverse.
# Unlink first for the same reason it does: `>` follows a symlink parked at the path
# and truncates its target, and the state dir is repo-controlled.
GEN_NONCE=$(mktemp -u "genXXXXXXXX" 2>/dev/null || printf 'g%s%s' "$RANDOM" "$RANDOM")
rm -f "$GEN_FILE"
printf '%s-%s-%s\n' "$$" "$(date +%s)" "${GEN_NONCE##*/}" > "$GEN_FILE"
echo "BUILTIN-${HASH}" > "$MARKER_FILE"
echo "Review marker written (builtin)"
