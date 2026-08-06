#!/usr/bin/env bash
# review-lock.sh — mutual exclusion between litmus review runs (#569).
#
# WHY A LOCK AT ALL. Every reader of litmus-state.md that wants to know "is a review
# in flight?" is otherwise doing check-then-act on a file anyone may rewrite. No
# amount of care in the classification closes that: the answer can go stale between
# the read and the act. The state file cannot carry the answer either — `active: true`
# survives a killed run, and `terminal_status` cannot describe a run that has been set
# up but not started. A lock held for the lifetime of a run can.
#
# WHY A SYMLINK. symlink(2) creates the lock AND publishes its owner in ONE atomic
# operation — the pid rides in the link target. A mkdir-based lock needs a second
# write to record ownership, and in the window between the two the lock exists with no
# owner: a concurrent process reads it as an orphan and reclaims a LIVE lock. That was
# a real defect in an earlier draft, not a hypothetical.
#
# WHY NO AUTOMATIC RECLAIM. A lock whose owner was SIGKILLed is an orphan, and it is
# tempting to reclaim it. Every shell-level way to do so is a race:
#
#   - `rm` + create loses arbitration outright — of two processes that both judge the
#     lock orphaned, the loser deletes the WINNER's fresh live lock and takes it.
#   - `mv` + create looks atomic but is not, because rename(2) moves whatever occupies
#     the PATH, not the specific symlink that was inspected. The winner replaces the
#     orphan with its own live lock; the loser's `mv` then carries THAT away and
#     installs its own. Both return success.
#   - Verify-after-move needs an undo, and the undo races the next acquirer.
#
# There is no compare-and-swap on a path in POSIX shell, so instead of arbitrating the
# reclaim we do not reclaim. An orphan is reported, with its owner's liveness and the
# exact path, and a human unlinks it. That trades a rare, visible, fail-CLOSED stall
# after a SIGKILL for a class of silent double-review corruption — the right direction,
# and the same reasoning that keeps `kill -0` out of the decision: pid reuse would
# otherwise let an unrelated process make an orphan look live forever.
#
# The lock is cooperative: it binds the scripts that take it. That is enough only
# because every script that writes litmus-state.md does.

review_lock_path() {
    local dir="${BUSDRIVER_STATE_DIR:-.claude}"
    # Normalize HERE, not only in the callers: this library is the single choke point
    # every lock path flows through, and init-review-loop.sh reads the env var raw.
    # The leading-hyphen case is the one that bites hardest — `-state` satisfies a
    # character-class check, and then dirname, mkdir, ln, mktemp and rm all read the
    # path as OPTIONS, so every acquisition fails as an unusable directory.
    case "$dir" in ""|-*|/*|*..*|*[!a-zA-Z0-9._/-]*) dir=".claude" ;; esac
    printf '%s/litmus-review.lock' "$dir"
}

# The link target is "pid-<pid>-<nonce>". Two things are encoded because two different
# questions get asked of it:
#
#   OWNERSHIP  — must be unique per acquisition. `$$` alone is not a credential: bash
#                subshells share it, separate PID namespaces can hold the same numeric
#                pid over one shared state dir, and a dead pid is eventually reused.
#                Any of those lets two live processes each conclude the lock is theirs,
#                which is precisely the mutual exclusion this file claims to provide.
#   LIVENESS   — needs the real pid, for `kill -0` and for signalling.
#
# review_lock_token returns the whole credential; review_lock_owner returns just the
# pid. Compare tokens, signal pids.
# A token is minted FRESH at each acquisition and is NOT exported. An earlier draft
# derived it from a nonce created once at source time and exported — which defeated the
# whole point: bash subshells retain the same `$$` AND inherit the same exported nonce,
# so siblings produced identical tokens and both passed the ownership check. Exporting
# it reproduced the very PID-namespace collision the token was meant to remove.
#
# The two needs are met separately:
#   OWNERSHIP    — _REVIEW_LOCK_MY_TOKEN, minted per acquisition, never exported. Only
#                  the process that actually took the lock holds this value.
#   INHERITANCE  — BUSDRIVER_REVIEW_LOCK_OWNER, exported deliberately by a holder that
#                  is about to shell out. A child recognises the lock as its parent's
#                  and does not release it.
# Holding the token is not enough to prove ownership: bash FORKED SUBSHELLS inherit
# non-exported shell variables, so a subshell of the holder sees _REVIEW_LOCK_MY_TOKEN
# and would pass an ownership check — then release its parent's live lock on the way
# out. `$$` cannot discriminate either, because a subshell reports its PARENT's pid.
# BASHPID is the actual pid of the current shell and differs in a subshell, so the
# minting shell records its own and every ownership decision requires that match.
_REVIEW_LOCK_MY_TOKEN=""
_REVIEW_LOCK_MY_BASHPID=""

# Ownership identity is read DIRECTLY, never through a command substitution.
#
# `$(_review_lock_shell_pid)` was tried and is wrong for the same reason building the
# token inside `$( )` was: the substitution forks, so whatever it reports is the
# SUBSTITUTION subshell, not the caller. Ownership then records a pid that exits
# immediately, minted_here never matches, and the lock is acquired but never freed.
# That mistake has now been made twice in this file; read `$BASHPID` inline.
#
# KNOWN LIMIT, bash 3.2 (what macOS ships as /bin/bash, and several scripts here use
# `#!/bin/bash`): BASHPID does not exist, the fallback is `$$`, and `$$` does NOT change
# in a forked subshell — so on that shell a subshell of the holder is indistinguishable
# from the holder. The practical exposure is narrow: bash does not inherit EXIT traps
# into subshells, so review_lock_release is not reached spontaneously there; it would
# take an explicit call from inside a subshell, which no caller in this repo makes.
# Getting a true per-shell pid on 3.2 requires a fork per check (`sh -c 'echo $PPID'`),
# and a fork cannot be used here precisely because it would have to run in a
# substitution. Documented rather than papered over.
# Record ownership. ALWAYS via this function: the token and the minting shell must be
# set together, and an acquire path that sets only the token leaves minted_here false —
# so the lock is held but never freed. That shipped once, on the retry branch.
_review_lock_claim() {
    _REVIEW_LOCK_MY_TOKEN="$1"
    _REVIEW_LOCK_MY_BASHPID="${BASHPID:-$$}"
}

# NOTE the assignment shape: the nonce comes from a command substitution, but the pid
# is read in THIS shell. Building the whole token inside `$( )` would stamp it with the
# substitution subshell's BASHPID — a pid that exits immediately, making every later
# ownership and liveness check false.
_review_lock_mint_token() {
    local _n
    _n=$(mktemp -u "tokXXXXXXXX" 2>/dev/null || printf 't%s%s' "$RANDOM" "$RANDOM")
    _REVIEW_LOCK_MINTED="pid-${BASHPID:-$$}-${_n##*/}"
}

# True only in the shell that actually minted the token — not in its subshells.
review_lock_minted_here() {
    _review_lock_minted_here
}

# True only in the shell that actually minted the token — not in its subshells.
_review_lock_minted_here() {
    [ -n "$_REVIEW_LOCK_MY_TOKEN" ] || return 1
    [ "$_REVIEW_LOCK_MY_BASHPID" = "${BASHPID:-$$}" ] || return 1
    return 0
}

review_lock_token() {
    readlink "$(review_lock_path)" 2>/dev/null || true
}

# The pid half, for kill -0 and signalling. Never for ownership.
review_lock_owner() {
    local target
    target=$(review_lock_token)
    target="${target#pid-}"
    printf '%s' "${target%%-*}"
}

# True when the lock is ours: either we minted its token, or exec(2) replaced our image
# while we held it (same pid, and the exported owner still names that token), or a
# parent handed it down.
_review_lock_is_ours() {
    local held
    held=$(review_lock_token)
    [ -n "$held" ] || return 1
    if _review_lock_minted_here && [ "$held" = "$_REVIEW_LOCK_MY_TOKEN" ]; then
        return 0
    fi
    if [ -n "${BUSDRIVER_REVIEW_LOCK_OWNER:-}" ] && [ "$held" = "$BUSDRIVER_REVIEW_LOCK_OWNER" ]; then
        # Adopt across exec: same real pid means this IS the process that took it, just
        # a new image. Without adopting, nothing would ever free the lock afterwards.
        if [ "$(review_lock_owner)" = "${BASHPID:-$$}" ]; then
            _review_lock_claim "$held"
        fi
        return 0
    fi
    return 1
}

# Human-readable liveness of the current owner, for diagnostics ONLY — never for a
# decision. `kill -0` cannot tell a reused pid from the original, so acting on it is
# how an orphan becomes a permanent wedge.
review_lock_owner_state() {
    local owner
    owner=$(review_lock_owner)
    if [ -z "$owner" ]; then
        printf 'unknown'
    elif kill -0 "$owner" 2>/dev/null; then
        printf 'running'
    else
        printf 'not running'
    fi
}

# 0 = acquired (or already ours), 1 = someone else holds it, 2 = the state dir is
# unusable. Distinguishing 2 matters: reporting an unwritable or missing state dir as
# contention tells the operator to remove a lock that does not exist.
review_lock_acquire() {
    local lock owner lock_probe
    lock=$(review_lock_path)
    mkdir -p "$(dirname "$lock")" 2>/dev/null || return 2

    # `ln -s TARGET DEST` FOLLOWS DEST when it is a directory (or a symlink to one):
    # it creates DEST/TARGET and exits 0. A lock path that is a directory would
    # therefore let EVERY acquirer report success — the mutex silently absent rather
    # than merely broken. Refuse that path outright; it is an unusable state dir, not
    # contention.
    # Classify an occupied path BEFORE attempting to write it. Permitting the ln when a
    # symlink is already there is not safe just because the symlink is ours-shaped: if
    # its target resolves to a directory, `ln -s` FOLLOWS it, creates a nested link
    # inside, and returns SUCCESS — after which the post-check reports an unusable
    # directory instead of recognising the holder as contention or inheritance.
    if [ -L "$lock" ]; then
        owner=$(review_lock_token)
        if [ -n "$owner" ]; then
            _review_lock_is_ours && return 0
            return 1
        fi
        # Empty target: the symlink vanished between the test and the read, i.e. the
        # holder released. That is AVAILABILITY, not a broken state dir — reporting 2
        # here would send the operator hunting for a lock that just went away. Only a
        # path that still exists and still cannot be read is a real problem; otherwise
        # fall through and try to take it.
        if [ -L "$lock" ] || [ -e "$lock" ]; then
            return 2
        fi
    fi
    if [ -e "$lock" ]; then
        # A real file or directory sits at the lock path. Not contention — an unusable
        # state dir.
        return 2
    fi

    local _mine
    _review_lock_mint_token
    _mine="$_REVIEW_LOCK_MINTED"
    if ln -s "$_mine" "$lock" 2>/dev/null; then
        # Confirm we created the link we think we did, rather than a file inside
        # something. Belt to the -d check's braces: the two together mean a success
        # return always corresponds to a symlink carrying OUR freshly minted token.
        [ "$(review_lock_token)" = "$_mine" ] || return 2
        _review_lock_claim "$_mine"
        return 0
    fi

    # Re-entrant two ways. Same pid: run-review-loop.sh re-executes itself on one mode
    # switch, and exec(2) keeps the pid, so the new image must not read the lock it
    # already owns as somebody else's. Inherited owner: a holder that shells out to
    # another lock-taking script exports its pid, and the child treats that lock as its
    # own rather than deadlocking against its parent. Cooperative, like the lock itself
    # — a correctness mechanism between our own scripts, not a boundary against a
    # hostile caller, who could simply unlink the lock.
    owner=$(review_lock_token)
    if [ -n "$owner" ]; then
        _review_lock_is_ours && return 0
        return 1
    fi
    # Nothing occupies the path, yet ln failed. Retry once — the holder may simply have
    # released between the two.
    if ln -s "$_mine" "$lock" 2>/dev/null; then
        [ "$(review_lock_token)" = "$_mine" ] || return 2
        _review_lock_claim "$_mine"
        return 0
    fi

    # Still failing. Do NOT infer "unusable" from that: rapid contention — another
    # process acquiring and releasing around each of our probes — looks exactly the
    # same, and no number of retries separates them.
    #
    # Prove the capability instead, by exercising it. Not `-d && -w`: those are
    # permission bits, and a filesystem can report a directory writable while still
    # rejecting symlinks, being out of space, or exceeding a path limit. Create a
    # symlink at a UNIQUE sibling path — same directory, same operation, no collision
    # with the lock itself. If that works, the environment is fine and whatever beat
    # us to the lock was contention.
    # Borrow a collision-free NAME from mktemp -d, then take the directory away and use
    # that path for a symlink. Two constraints have to hold at once:
    #
    #   - The probe must be a SIBLING of the lock, not a symlink inside a child dir. A
    #     directory ACL can permit adding subdirectories while denying symlinks in the
    #     parent, so probing a child would report "usable" for a location where the
    #     real lock cannot be created.
    #   - The name must not be pid-derived. "${lock}.probe.$$" survives a SIGKILL
    #     between creation and cleanup, and when that pid is reused the leftover makes
    #     `ln` fail — a usable directory then reports unusable and blocks every review.
    #     mktemp never returns an existing name, so an orphan is inert litter.
    #
    # Nothing else can claim the name between rmdir and ln: mktemp just proved it was
    # ours alone.
    lock_probe=$(mktemp -d "${lock}.probe.XXXXXX" 2>/dev/null) || return 2
    rmdir "$lock_probe" 2>/dev/null || { rm -rf "$lock_probe"; return 2; }
    if ln -s probe "$lock_probe" 2>/dev/null; then
        rm -f "$lock_probe"
        return 1
    fi
    return 2
}

# Publish the lock's ownership to children so they inherit it rather than deadlock.
#
# Exports whoever ACTUALLY holds the lock, not blindly "$$". A caller that acquired by
# INHERITANCE does not own the lock — its parent does — and exporting its own pid would
# make a grandchild compare against a non-owner and reject the real holder's lock. Read
# the owner from the lock itself so the value propagates unchanged down a chain of any
# depth.
review_lock_export_owner() {
    local owner
    owner=$(review_lock_token)
    [ -n "$owner" ] || return 0
    BUSDRIVER_REVIEW_LOCK_OWNER="$owner"
    export BUSDRIVER_REVIEW_LOCK_OWNER
}

# Only ever release a lock we still own — never unlink a successor's.
review_lock_release() {
    local lock
    lock=$(review_lock_path)
    # Only a token WE minted. Releasing on a pid match would let a recycled pid unlink
    # a lock it never took; releasing on an inherited token would let a child unlink its
    # parent's.
    _review_lock_minted_here || return 0
    [ "$(review_lock_token)" = "$_REVIEW_LOCK_MY_TOKEN" ] || return 0
    rm -f "$lock"
}
