#!/bin/bash
# Trusted marker writer for builtin review fallback
# Called via Bash tool (not Write tool) to avoid pre-implementation gate block
# Prefix with BUILTIN- so post-commit-consume-marker.sh can distinguish
# self-reviewed commits from externally-reviewed ones.
#
# Defense-in-depth: validates that run-review-loop.sh actually triggered
# the builtin fallback by checking for the handoff file it creates (exit 3).
# The handoff file is consumed after use (single-use token).
set -euo pipefail
STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
# Constrain to a safe relative name (reject absolute/traversal/unsafe chars) so
# the "$REPO_DIR/$STATE_DIR" joins below resolve to the configured state dir.
case "$STATE_DIR" in ""|/*|*..*|*[!a-zA-Z0-9._/-]*) STATE_DIR=".claude" ;; esac
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

# #576: the reviewed-snapshot hash, handed over by run-review-loop.sh at the same
# moment it wrote the prompt-path handoff above (immediately before its exit 3).
#
# This script used to recompute `git diff --cached` right here. That is the #576
# late-hash bug in its widest form: everything between exit 3 and this line is the
# builtin review itself, so the recomputed hash described whatever was staged when
# the agent FINISHED, not what it was asked to review. A marker minted for diff A
# would name diff B — and since #545 the gate compares marker to staged diff, so
# that mismatch stopped blocking and started certifying.
#
# Fail CLOSED and do NOT fall back to a fresh diff: a missing or malformed hash
# means the handoff was not the one this review started from, and re-deriving it
# here would reinstate exactly the bug. Refusing the marker costs a re-run; a
# forged binding costs an unreviewed commit.
# The sidecar is keyed to the PER-RUN mktemp prompt path recorded in the pointer file,
# not a second fixed name: two builtin reviews can overlap (run-review-loop.sh releases
# the review lock when it exits 3), and a fixed name would let the second run's hash
# replace the first's, so a writer could certify a diff its own reviewer never saw.
#
# PROMPT_PATH is read from a state file, so it is UNTRUSTED INPUT, not a constant, and
# this script both reads AND unlinks the sidecar derived from it. Take only the
# BASENAME and rebuild the path inside the state dir we already own. An earlier attempt
# validated the full absolute path by prefix and read "${PROMPT_PATH}.hash" in place;
# that was still an arbitrary-file delete, because the prefix constrains only the last
# component — "/anywhere/busdriver-review-data.hash" passed. Deriving the directory
# ourselves rather than trusting it means the only path this can ever unlink is one
# inside $STATE_DIR. (Anyone able to write the handoff can already write the marker
# directly, so this is not the last line of defence — it just refuses to lend them a
# delete primitive that reaches outside the state dir.)
# Prefer the prompt path the CALLER was given ($1) over re-reading the global pointer.
# The pointer is a single fixed name, so a writer that re-reads it picks up whichever
# review armed it LAST: if review A is slow and review B arms a new handoff, A's writer
# would consume B's hash and certify a diff A never saw. The caller already holds its
# own prompt path (the skill reads it from the pointer before dispatching the reviewer),
# so passing it back binds this write to that specific invocation. The pointer remains
# the fallback for callers that do not pass it, and still carries that residual race.
# REQUIRED, not optional. Falling back to re-reading the pointer would leave the whole
# binding dependent on a caller remembering to pass it, and the pointer is a single
# fixed name: if a second review armed a handoff while yours was running, the fallback
# consumes ITS hash and certifies a diff this reviewer never saw. Refusing is
# fail-closed and costs a re-run; the silent fallback costs an unreviewed commit.
PROMPT_BASE="${1:-}"
if [ -z "$PROMPT_BASE" ]; then
    echo "ERROR: No prompt path given — marker cannot be written." >&2
    echo "       Pass the prompt path you read from $STATE_DIR/builtin-review-prompt-path.local" >&2
    echo "       as the first argument, so the marker binds to YOUR review's diff hash." >&2
    exit 1
fi
PROMPT_BASE="${PROMPT_BASE##*/}"
# Match the template's PREFIX, not a fixed width: `mktemp -t busdriver-review-XXXXXX`
# yields different basenames per platform — BSD/macOS keeps the literal XXXXXX and
# appends its own random suffix (busdriver-review-XXXXXX.2TffGvE47r), GNU substitutes
# the X's. A fixed-width pattern silently rejects every real handoff on one of them.
case "$PROMPT_BASE" in
    busdriver-review-?*) : ;;
    *) PROMPT_BASE="" ;;
esac
# Belt and braces after the basename strip: no separator, no traversal, no newline.
case "$PROMPT_BASE" in
    */*|*..*|*'
'*) PROMPT_BASE="" ;;
esac
HASH=""
HASH_FILE=""
if [ -n "$PROMPT_BASE" ]; then
    HASH_FILE="$REPO_DIR/$STATE_DIR/builtin-review-${PROMPT_BASE}.hash"
    # Refuse a symlink: run-review-loop.sh creates the sidecar with O_EXCL (which never
    # follows one), so a symlink here means someone else made it.
    if [ -L "$HASH_FILE" ] || [ ! -f "$HASH_FILE" ]; then
        HASH_FILE=""
    else
        HASH=$(cat "$HASH_FILE" 2>/dev/null || echo "")
    fi
fi

# Consume BOTH handoff files (single-use token), BEFORE validating the value. The
# read above already has what we need, and consuming up front keeps the original
# strict single-use property: every attempt spends the token, so a malformed or
# missing hash costs a litmus re-run rather than leaving an armed handoff behind
# for a second try. Fail-closed work is supposed to cost a re-run.
# Consume the GLOBAL pointer only when it still names the prompt path we were given.
# Deleting it unconditionally would let a delayed writer for review A destroy review B's
# handoff, leaving B unable to complete — the mirror image of the cross-review problem
# the argument exists to solve. Our own sidecar is always ours, so it always goes.
_ptr_base=$(head -n 1 "$HANDOFF_FILE" 2>/dev/null || echo "")
_ptr_base="${_ptr_base##*/}"
if [ "$_ptr_base" = "$PROMPT_BASE" ]; then
    rm -f "$HANDOFF_FILE"
fi
if [ -n "$HASH_FILE" ]; then
    rm -f "$HASH_FILE"
fi

case "$HASH" in
    *[!0-9a-f]* | "") HASH="" ;;
esac
if [ "${#HASH}" -ne 64 ]; then
    echo "ERROR: Missing or malformed reviewed-diff hash handoff — marker cannot be written." >&2
    echo "       Expected a 64-char SHA-256 in the .hash sidecar of the mktemp prompt file," >&2
    echo "       written by run-review-loop.sh at exit code 3." >&2
    exit 1
fi

mkdir -p "$REPO_DIR/$STATE_DIR"
echo "BUILTIN-${HASH}" > "$REPO_DIR/$STATE_DIR/litmus-passed.local"
echo "Review marker written (builtin)"
