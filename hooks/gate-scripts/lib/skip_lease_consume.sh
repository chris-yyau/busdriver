# shellcheck shell=bash
# Shared design-review skip-lease consumer (#519 / #852).
# Sourced by pre-implementation-gate.sh and pre-commit-gate.sh.
# Callers must define before source/use:
#   STATE_DIR, LEASE_MAX_USES, LEASE_MAX_AGE, _SKIP_FILE, _LEASE_DIR, _GATE_LIBDIR
#   block_emit, gate_skip_file_repo_controlled
# Callers must initialize before each consume attempt:
#   _LEASE_REFUSAL=""  _LEASE_HELPER_UNAVAILABLE=0
#
# Exit: 0 = a lease use was granted
#       1 = no usable skip file (fall through to the normal block)
#       2 = a block decision has ALREADY been emitted on stdout (caller exits)

# #852 — the worktree + staged-digest pin.
#
# Without it the hatch is identity-blind: ANY repo holding a valid operator skip file
# would skip Gate 1, so the authorization could not be confined to the change it was
# written for. Both halves are computed HERE, from the same REPO_DIR the gate is about
# to let commit — never read from hook JSON, argv or env. A spoofed cwd therefore yields
# THAT repo's identity and digest, which cannot match an authorization written for this
# one, instead of letting the caller assert what it wants the gate to believe.
#
# Returns 0 only when the authorization names this exact worktree AND this exact staged
# diff. Every other outcome returns 1 (fall through to the normal Gate 1 block) with
# _LEASE_REFUSAL set to say why.
_bd852_lease_binding_ok() {
    local _got_id _got_hash
    # The digest half must be the SAME computation Gate 2 binds its marker to, or the pin
    # authorizes a different byte-stream than the review validated. Fail closed if the
    # caller did not provide it rather than silently falling back to a second one.
    if ! declare -F _bd852_canonical_staged_hash >/dev/null 2>&1; then
        _LEASE_REFUSAL="[skip lease: REFUSED — no canonical digest function available]

The caller required a binding but did not define _bd852_canonical_staged_hash, so the
staged digest cannot be computed the same way Gate 2 computes it. Refusing rather than
binding to a second, possibly divergent computation. No lease use was spent."
        return 1
    fi
    # THIS FUNCTION DOES NOT READ THE SKIP FILE. It builds the line the file is REQUIRED
    # to carry, from values it computes itself, and lease_slot.py performs the only read
    # — under the ledger lock, with O_NONBLOCK + a regular-file check + a bounded read,
    # on the very fd it claims against.
    #
    # An earlier revision read the first line here and compared fields in shell. Two
    # defects came from that read, both found in review and both structural rather than
    # incidental: a FIFO substituted at the path blocked the shell open outright, and
    # `read` on a newline-free file allocated the whole payload before rejecting it.
    # Guarding a read the gate does not need is worse than not doing it — so the read is
    # gone, and with it both defects and the chance of the two sides parsing differently.
    #
    # --absolute-git-dir names the per-worktree git dir (…/.git/worktrees/<name>), which
    # is what makes this worktree-scoped rather than repo-scoped: sibling worktrees of
    # the same repository produce different values.
    _got_id=$(git -C "$REPO_DIR" rev-parse --absolute-git-dir 2>/dev/null) || _got_id=""
    _got_hash=$(_bd852_canonical_staged_hash) || _got_hash=""
    if [ -z "$_got_id" ] || [ -z "$_got_hash" ]; then
        _LEASE_REFUSAL="[skip lease: REFUSED — the gate could not establish what to require]

The worktree identity or the staged digest could not be computed, so there is no
authorization to match against. Fail-CLOSED; no lease use was spent.
    this worktree     : ${_got_id:-<unresolvable>}
    staged digest now : ${_got_hash:-<uncomputable>}"
        return 1
    fi
    _BD852_BINDING_LINE="PASS-DESIGN $_got_id $_got_hash"
    return 0
}

# Exit: 0 = a lease use was granted (allow the write)
#       1 = no usable skip file (fall through to the normal block)
#       2 = a block decision has ALREADY been emitted on stdout (caller exits)
_skip_lease_consume() {
    local claimed
    [[ -f "$_SKIP_FILE" ]] || return 1
    # A git-tracked (git add -f'd) skip file is repo-controlled, not operator consent
    # (#325). Anchor the guard on the SAME path the `-f` check tests — that check is
    # relative to the hook CWD, so resolve against the CWD too, or a committed
    # subdir/.claude skip file could satisfy one check and evade the other.
    # FAIL-CLOSED: outside a git repo the helper reports repo-controlled → refuse.
    # `if`, not `&& return`: under `set -e` a naked `cmd && return 1` whose cmd fails
    # makes the whole list non-zero and trips the ERR trap before the next line runs.
    if gate_skip_file_repo_controlled "." "$_SKIP_FILE"; then
        _LEASE_REFUSAL="[skip lease: REFUSED — the skip file is repo-controlled, not operator consent (#325)]

$_SKIP_FILE is tracked by git (in the index or in HEAD), sits behind a tracked
symlink or gitlink, or the git state of this repository could not be read. A
committed skip file can be injected by the repository itself, so it is not accepted
as operator consent.

Re-creating the file will NOT clear this. The remedy depends on which of those
is true, and only the first is a plain untrack:
    tracked in the index               -> git rm --cached $_SKIP_FILE
    committed in HEAD                  -> remove it and commit the removal
    tracked parent symlink or gitlink  -> that parent path is what must change
    unreadable git state               -> repair the repository
Running /blueprint-review does not repair the lease, but it does clear the
pending review below, which unblocks this write."
        return 1
    fi

    # #852 pin. Pre-commit sets _LEASE_BINDING_REQUIRED=1; pre-implementation leaves it
    # unset, so its content-free lease is untouched.
    #
    # ORDER IS LOAD-BEARING: this runs BEFORE lease_slot.py, which is what spends a use.
    # A wrong worktree, a changed staged digest, or a malformed binding is not an
    # exhausted lease — it never qualified — so it must cost the operator nothing to
    # correct and retry. Moving this below the claim would silently burn the
    # authorization on attempts that were never eligible.
    if [ "${_LEASE_BINDING_REQUIRED:-0}" = "1" ]; then
        # `if !`, not `&& return`: under `set -e` a naked `cmd || return 1` whose cmd
        # fails trips the ERR trap before the next line runs (same trap documented above).
        if ! _bd852_lease_binding_ok; then
            return 1
        fi
    fi

    # ── Age checks AND the claim, from ONE stat ─────────────────────────────
    # Both live in lease_slot.py. The shell used to stat the file for the 30s floor and
    # the 3600s ceiling and then let the helper stat it AGAIN for the lease key, so a
    # touch or replacement between the two produced a lease whose new mtime had passed
    # neither check. One read, one decision.
    #
    # Every path component is opened with dir_fd + O_NOFOLLOW and every operation happens
    # AT that fd, so the directory validated is the one written to. The shell version
    # could not hold that: `-L "$STATE_DIR"` tests only the final name (a nested
    # `link/state` with a symlinked PREFIX passes), the check was separated from the use,
    # and a glob + `rm -rf` prune would follow such a symlink into a tree outside the
    # repo — where slots are also outside the protected-marker guard, so they could be
    # erased through the external name and the ceiling reset indefinitely.
    #
    # Exit 0 = claimed (slot on stdout); 2 = exhausted; 3 = too new; 4 = expired;
    # anything else = could not record, which must REFUSE the bypass —
    # unbounded-because-unrecordable is the fail-open this whole block exists to avoid.
    _CLAIM_RC=0
    # A missing/unreadable helper also exits 2 (CPython's own "can't open file"
    # exit code), which the `2)` branch below would misreport as a spent lease --
    # naming a use that was never granted and a file that was never removed. Route
    # that case to the generic fail-closed refusal (`*)`) instead, before invoking
    # python3, so exit code 2 stays exclusively the helper's own spent-lease signal.
    [ -f "$_GATE_LIBDIR/lease_slot.py" ] || { _CLAIM_RC=1; _LEASE_HELPER_UNAVAILABLE=1; }
    if [ "$_CLAIM_RC" -eq 0 ]; then
        if [ "${_LEASE_BINDING_REQUIRED:-0}" = "1" ]; then
            # The 6th argument is the line the file must STILL carry. It is not trusted
            # as truth — _bd852_lease_binding_ok already decided that this line
            # authorizes this worktree and this staged diff, against values it computed
            # itself. This only closes the read→claim window.
            claimed="$(python3 -I "$_GATE_LIBDIR/lease_slot.py" "$STATE_DIR" "$LEASE_MAX_USES" 30 "$LEASE_MAX_AGE" "${_BD852_BINDING_LINE:-}" 2>/dev/null)" || _CLAIM_RC=$?
        else
            claimed="$(python3 -I "$_GATE_LIBDIR/lease_slot.py" "$STATE_DIR" "$LEASE_MAX_USES" 30 "$LEASE_MAX_AGE" 2>/dev/null)" || _CLAIM_RC=$?
        fi
    fi
    # The `-f` test above is a cheap early exit, NOT the discriminator: it cannot see an
    # UNREADABLE regular file, and the helper can be removed between the test and the
    # interpreter opening it. Both still exit 2. So exit 2 is re-verified rather than
    # trusted -- if the helper is not openable now, that 2 was CPython refusing to open
    # a file, not the helper reporting a spent lease. Costs one probe, and only on the
    # exhausted path. Both branches BLOCK either way; what this buys is that the operator
    # is told the truth, instead of being sent to re-touch a lease that was never spent
    # and hunting for a skip file that was never removed.
    if [ "$_CLAIM_RC" -eq 2 ] \
       && ! python3 -I -c 'import sys; open(sys.argv[1], "rb").close()' \
                    "$_GATE_LIBDIR/lease_slot.py" 2>/dev/null; then
        _CLAIM_RC=1
        _LEASE_HELPER_UNAVAILABLE=1
    fi
    case "$_CLAIM_RC" in
        0) : ;;
        3)
            # Created moments ago — likely a self-bypass, not operator consent.
            # lease_slot.py has already disarmed it, and if it could NOT (an immutable
            # file in a writable dir) it poisoned the lease instead, so aging past the
            # floor buys nothing.
            block_emit "BLOCKED: skip-design-review.local was created moments ago (likely self-bypass).

Do NOT create $STATE_DIR/skip-design-review.local yourself. Run /blueprint-review instead.
If the user wants to skip, they should create the file manually in their terminal."
            return 2 ;;
        4)
            # Disarmed by lease_slot.py. Slots are left in place for the same anti-TOCTOU
            # reason as the exhausted branch; the mtime-keyed prune clears them when a new
            # lease is armed.
            block_emit "BLOCKED: the design-review skip lease has EXPIRED (the limit is ${LEASE_MAX_AGE}s).

The file has been removed so it cannot stay armed and silently authorize a later session.
Run /blueprint-review to clear the review properly. If the user still wants to bypass,
they can create $STATE_DIR/skip-design-review.local again in their terminal."
            return 2 ;;
        2)
            # lease_slot.py removed ONLY the skip file. Deleting the slots would be a
            # TOCTOU: a concurrent gate that already passed the skip-file/mtime checks
            # would recreate the directory, claim slot 1 under the same mtime, and be
            # granted a 21st use. The slots are the exhaustion proof and must outlive the
            # file that spent them; a later touch changes the mtime and lease_slot prunes
            # them. (The ledger is a protected marker, so it cannot be wiped to reset.)
            block_emit "BLOCKED: the design-review skip lease is EXHAUSTED (all $LEASE_MAX_USES uses spent).

One \`touch\` authorizes $LEASE_MAX_USES gated writes so a whole approved plan can be
implemented without re-arming per write — but not an unbounded number. The file has
been removed.

Run /blueprint-review to clear the pending review properly. To release ONE specific
pending token with a recorded audit event instead, run scripts/design-clear.sh with no
arguments to list what is pending. If the user wants another lease, they can re-create
$STATE_DIR/skip-design-review.local in their terminal."
            return 2 ;;
        5)
            # #852 — the file no longer carries the line that was validated. Nothing was
            # claimed, poisoned or unlinked, so the lease survives for a corrected
            # authorization. Distinct from EXHAUSTED on purpose: telling an operator a
            # lease is spent when it is not sends them to re-arm for no reason.
            _LEASE_REFUSAL="[skip lease: REFUSED — the skip file does not authorize this commit]

$_SKIP_FILE does not carry the line this worktree and this staged diff require. That
covers every shape of the same answer: no authorization line at all (a content-free
lease is accepted by the pre-implementation gate but never by the commit gate), one
naming a different worktree or a different digest, one that is malformed or overlong,
and the file being rewritten or swapped for another inode between the check and the
claim — the comparison is made against CONTENT read from the very descriptor the slot
is claimed on, so copying the original's timestamp does not help.

No lease use was spent and the lease is still armed. The required line is exactly:
    ${_BD852_BINDING_LINE:-<could not be computed>}
Gate 2 (Litmus) still runs afterwards either way — this pin narrows Gate 1, it does not
replace the review."
            return 1 ;;
        *)
            # FAIL-CLOSED: could not record a use → grant none. Two distinct causes
            # land here and the operator needs to know which — see
            # _LEASE_HELPER_UNAVAILABLE above for why the exit code cannot say.
            if [ "$_LEASE_HELPER_UNAVAILABLE" -eq 1 ]; then
                _LEASE_REFUSAL="[skip lease: REFUSED — the lease helper could not be opened]

$_GATE_LIBDIR/lease_slot.py was not openable when the gate checked, so a lease use
can be neither recorded nor bounded — and an unbounded bypass is the fail-open this
gate exists to avoid.

That check runs after the helper has exited, so it reports what the gate OBSERVED,
not a proven cause: if the helper was removed after a genuinely spent lease, the
lease may in fact be exhausted. Both refuse, and the first thing to check is the
same either way.

Re-creating the skip file will NOT clear this — reinstall or repair the busdriver
plugin. Running /blueprint-review does not repair the lease, but it does clear the
pending review below, which unblocks this write."
            else
                _LEASE_REFUSAL="[skip lease: REFUSED — the lease use could not be recorded]

lease_slot.py refused because the slot directory or its bypass-telemetry event did
not land durably. A use that cannot be recorded cannot be bounded, so none is
granted. (The helper exits 1 for every internal error without reporting which, so
the gate cannot narrow this further — see #681.)

Re-creating the skip file will NOT clear this. Check that both paths below are
writable and not a symlink — but they need DIFFERENT shapes: $_LEASE_DIR must be a
directory (lease_slot.py opens it with O_DIRECTORY; a plain file there is refused),
while the audit log must be a regular file:
    $_LEASE_DIR                      (directory)
    $STATE_DIR/bypass-log.jsonl      (regular file)
Running /blueprint-review does not repair the lease, but it does clear the pending
review below, which unblocks this write."
            fi
            return 1 ;;
    esac
    # A claimed slot that is not a number means the helper exited 0 without printing a
    # usable slot id — the ledger cannot be trusted to bound anything, so refuse. Beyond
    # the three paths #681 enumerates, but the same silent-refusal class.
    case "$claimed" in ''|*[!0-9]*)
        _LEASE_REFUSAL="[skip lease: REFUSED — the lease helper returned an unusable slot id]

lease_slot.py exited 0 but did not print a slot number, so there is no proof a use
was recorded and no way to bound the next one.

Re-creating the skip file will NOT clear this — reinstall or repair the busdriver
plugin. Running /blueprint-review does not repair the lease, but it does clear the
pending review below, which unblocks this write."
        return 1 ;;
    esac

    # Exit 0 means the slot is durable on disk AND the bypass-telemetry event for it is
    # durably logged — lease_slot.py mints that event inside the same call that created
    # the slot, and reports ERROR (refuse, slot stays spent) if the append did not land.
    # It is NOT a second command here, because a record-writing CLI is a forge primitive:
    # it needs no protected path and no modification verb, so nothing else in the Bash
    # detector would notice one, and post-commit-consume-marker.sh reads a recent
    # `skip-review-consumed` line as proof that a bypass was sanctioned.
    # #852 — LAST look at the staged diff, after the slot is taken. The binding was
    # validated before the claim (so a mismatch spends nothing); re-reading it here
    # catches a re-stage that happened in between, which the pre-check cannot see.
    #
    # BE PRECISE ABOUT WHAT THIS DOES AND DOES NOT BUY. It makes the pin's guarantee
    # exactly as strong as Gate 2's marker binding and no stronger: both compare the
    # canonical staged hash inside THIS hook invocation. Neither can cover the window
    # between the hook returning and `git commit` actually running — a PreToolUse hook
    # has exited by then, and nothing here makes the commit atomic with the check. That
    # residual is inherent to the hook boundary and is not claimed to be closed.
    #
    # A slot HAS been spent at this point. That is correct rather than unfortunate: the
    # lease was validly claimed at that instant, and what changed afterwards is the diff,
    # not the authorization's standing.
    if [ "${_LEASE_BINDING_REQUIRED:-0}" = "1" ]; then
        _BD852_HASH_NOW="$(_bd852_canonical_staged_hash)" || _BD852_HASH_NOW=""
        if [ -z "$_BD852_HASH_NOW" ] \
           || [ "${_BD852_BINDING_LINE##* }" != "$_BD852_HASH_NOW" ]; then
            _LEASE_REFUSAL="[skip lease: REFUSED — the staged diff changed during the claim]

The authorization named digest ${_BD852_BINDING_LINE##* }, but the staged diff now hashes
to ${_BD852_HASH_NOW:-<uncomputable>}. An authorization covers one reviewed diff, so the
grant is withdrawn.

One lease use WAS spent — the lease was valid when it was claimed; it is the staged diff
that moved. Re-stage as intended, re-issue the authorization for the new digest, and
retry."
            return 1
        fi
    fi
    rm -f "$STATE_DIR/.impl-gate-block-count.local" 2>/dev/null || true
    return 0
}
