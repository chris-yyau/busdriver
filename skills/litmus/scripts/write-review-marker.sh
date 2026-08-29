#!/bin/bash -p
# #576: this script is an AUTHORIZATION component — it mints the commit marker — so it
# must refuse to import environment shell functions like the producer and the gates. A
# repo-injected exported `cat` could return an attacker-chosen 64-hex value after the
# index moved, making this writer emit BUILTIN-<current unreviewed diff> even though the
# reviewer saw the earlier prompt — so this file must never run with those functions
# imported. SKILL.md invokes it as `bash -p <script>`, which is the authoritative hop;
# the re-exec immediately below is the fallback for any other caller, and its own `exec`
# is shadowable. The shebang deliberately does NOT carry -p: this script is run as
# `bash <script>`, so a shebang would not apply, and pinning /bin/bash there would
# downgrade macOS to bash 3.2. See run-review-loop.sh for the full reasoning.
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
# CLAIM the pointer by renaming it, then read the claim. `mv` within a directory is
# atomic, so exactly one party can win: a comparison done by reading the pointer in
# place is a check-then-use window — a newer review can delete the handoff and write its
# marker between our read and our write, and we would then overwrite that newer marker
# with this run's older hash. Whoever wins the rename owns the turn.
_CLAIM_FILE="$HANDOFF_FILE.claim.$$"
# PEEK before claiming. This narrows, but does NOT eliminate, the window — a newer review
# can still replace the shared handoff between the peek and the rename, in which case this
# writer briefly holds it and the newer writer can observe it missing and fail. That is
# the same LIVENESS residual as the overwrite below: a spurious failure costing a re-run,
# never a false authorization, because the marker is diff-bound. Closing it needs the
# handoff to have its own lock spanning the agent phase — tracked as #790, deliberately
# out of scope for #576.
#
# Renaming first and asking questions afterwards lets this writer
# temporarily STEAL a handoff belonging to a newer review — that review's own writer then
# fails on a missing pointer — and the restore afterwards could clobber a third handoff
# armed while the shared path was briefly absent. Read it in place, refuse if it is not
# ours, and only then claim.
_ptr_base=$(head -n 1 "$HANDOFF_FILE" 2>/dev/null || echo "")
_ptr_base="${_ptr_base##*/}"
if [ "$_ptr_base" = "$PROMPT_BASE" ]; then
    if ! mv "$HANDOFF_FILE" "$_CLAIM_FILE" 2>/dev/null; then
        echo "ERROR: The builtin handoff is gone — another review claimed or superseded it." >&2
        echo "       Refusing to write: this review's hash is no longer the current one." >&2
        exit 1
    fi
    # Re-read after the claim: the peek above is advisory, and the rename is the only
    # atomic step. If the file changed between the two, this is the value that counts.
    _ptr_base=$(head -n 1 "$_CLAIM_FILE" 2>/dev/null || echo "")
    _ptr_base="${_ptr_base##*/}"
fi
if [ -n "$HASH_FILE" ]; then
    rm -f "$HASH_FILE"
fi
# The pointer is also the TURN token, not just a handoff. If it no longer names this
# review, another one has armed since — writing now would overwrite that newer review's
# marker with this run's older hash. Refuse instead, and leave the newer pointer alone.
if [ "$_ptr_base" != "$PROMPT_BASE" ]; then
    # Not ours. If we did claim it (the value changed under the rename), put it back so
    # its own writer can still find it — but NEVER over an existing handoff: one armed
    # while the shared path was absent is newer than what we hold, and clobbering it
    # would break that review instead. `mv -n` fails rather than overwrites; the
    # orphaned claim is then dropped by the caller re-running litmus.
    # `mv -n` declines silently and STILL exits 0 (measured, BSD/macOS), leaving the
    # source in place — so the unconditional cleanup after it is what stops an orphaned
    # claim file accumulating when the restore is refused.
    if [ -f "$_CLAIM_FILE" ]; then
        mv -n "$_CLAIM_FILE" "$HANDOFF_FILE" 2>/dev/null || true
        rm -f "$_CLAIM_FILE" 2>/dev/null || true
    fi
    echo "ERROR: The builtin handoff no longer names this review — refusing to write." >&2
    echo "       Another review armed a handoff while this one was running; writing now" >&2
    echo "       would overwrite its marker with a stale hash. Re-run litmus." >&2
    exit 1
fi

case "$HASH" in
    *[!0-9a-f]* | "") HASH="" ;;
esac
if [ "${#HASH}" -ne 64 ]; then
    # Ours and unusable: release the turn so the next review can arm. Leaving it would
    # lock every later builtin fallback out of the O_EXCL arming with no way back.
    rm -f "$_CLAIM_FILE"
    echo "ERROR: Missing or malformed reviewed-diff hash handoff — marker cannot be written." >&2
    echo "       Expected a 64-char SHA-256 in the .hash sidecar of the mktemp prompt file," >&2
    echo "       written by run-review-loop.sh at exit code 3." >&2
    exit 1
fi

# RESIDUAL, tracked as #790, and why it is not closed here. A delayed writer can still
# overwrite a newer review's marker with this run's hash: the atomic claim above makes
# exactly one writer own the handoff, but it cannot order this write against a marker
# another run wrote through the ordinary PASS path.
#
# That overwrite has no security consequence, precisely because of what #576 makes true.
# The marker is DIFF-BOUND, so the gate compares it to the staged diff: if the index
# moved between the two reviews the hashes differ and the gate BLOCKS (fail-closed,
# costing a re-run); if the index did not move both reviews name the same hash and the
# overwrite is a no-op. A stale marker can no longer authorise anything — that is the
# whole point of the change, and it is what turns this race from an authorisation bug
# into at worst a spurious block.
#
# An earlier revision added a freshness check here that refused when the reviewed hash
# no longer matched the current index. It was removed: it also refused in the ordinary
# late-hash case this file exists to handle, where the correct behaviour is to mint the
# marker for the REVIEWED diff and let the gate block the mutated one — the property
# tests/test-litmus-marker-binding.sh asserts first.

mkdir -p "$REPO_DIR/$STATE_DIR"
# Guarded: the sidecar is already consumed, so if this redirection fails under `set -e`
# the pointer would survive with no hash behind it and the producer's noclobber arming
# would reject every later builtin handoff until someone cleaned up by hand.
if ! echo "BUILTIN-${HASH}" > "$REPO_DIR/$STATE_DIR/litmus-passed.local"; then
    rm -f "$_CLAIM_FILE"
    echo "ERROR: Could not write the review marker — handoff released, re-run litmus." >&2
    exit 1
fi
# Release the claim only AFTER the marker exists.
rm -f "$_CLAIM_FILE"
echo "Review marker written (builtin)"
