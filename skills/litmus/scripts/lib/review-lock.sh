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

# The link target is "pid-<n>", not a bare number, so it can never name a real path
# inside the state dir. That matters because `ln -s` FOLLOWS a destination that is a
# directory: with a bare numeric target, a coincidental `.claude/12345` directory would
# make the lock path resolve to a directory and silently break the mutex (see acquire).
review_lock_owner() {
    local target
    target=$(readlink "$(review_lock_path)" 2>/dev/null || true)
    printf '%s' "${target#pid-}"
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
    [ -d "$lock" ] && return 2

    if ln -s "pid-$$" "$lock" 2>/dev/null; then
        # Confirm we created the link we think we did, rather than a file inside
        # something. Belt to the -d check's braces: the two together mean a success
        # return always corresponds to a symlink whose target names this process.
        [ "$(readlink "$lock" 2>/dev/null || true)" = "pid-$$" ] || return 2
        return 0
    fi

    # Re-entrant two ways. Same pid: run-review-loop.sh re-executes itself on one mode
    # switch, and exec(2) keeps the pid, so the new image must not read the lock it
    # already owns as somebody else's. Inherited owner: a holder that shells out to
    # another lock-taking script exports its pid, and the child treats that lock as its
    # own rather than deadlocking against its parent. Cooperative, like the lock itself
    # — a correctness mechanism between our own scripts, not a boundary against a
    # hostile caller, who could simply unlink the lock.
    owner=$(review_lock_owner)
    if [ -n "$owner" ]; then
        [ "$owner" = "$$" ] && return 0
        [ "$owner" = "${BUSDRIVER_REVIEW_LOCK_OWNER:-}" ] && return 0
        return 1
    fi
    # Nothing occupies the path, yet ln failed. Retry once — the holder may simply have
    # released between the two.
    if ln -s "pid-$$" "$lock" 2>/dev/null; then
        [ "$(readlink "$lock" 2>/dev/null || true)" = "pid-$$" ] || return 2
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
    owner=$(review_lock_owner)
    [ -n "$owner" ] || return 0
    BUSDRIVER_REVIEW_LOCK_OWNER="$owner"
    export BUSDRIVER_REVIEW_LOCK_OWNER
}

# Only ever release a lock we still own — never unlink a successor's.
review_lock_release() {
    local lock
    lock=$(review_lock_path)
    [ "$(review_lock_owner)" = "$$" ] || return 0
    rm -f "$lock"
}
