"""Claim ONE skip-lease slot, atomically and inside the repo (#519).

Usage:  python3 -I lease_slot.py <state_dir> <max_uses> <min_age> <max_age>
Exit:   0 = claimed (slot number on stdout) AND the audit event is durably logged
        1 = could NOT record a claim — caller must refuse the bypass (fail-closed)
        2 = exhausted (all <max_uses> slots already taken)
        3 = the skip file is younger than <min_age> (anti-self-bypass floor)
        4 = the lease is older than <max_age> (expired)

WHY NOT SHELL
The lease ledger is gate state: its slots are what bound the bypass to N writes. Doing
this in shell meant `mkdir -p`, a `*` glob, and `-L` tests, which together left three
holes:

  - `-L "$STATE_DIR"` checks only the FINAL pathname. A nested state dir (`link/state`)
    whose PREFIX is a symlink passes the test, and mkdir/glob/claim then operate outside
    the repository — where the slots are not covered by the protected-marker guard and
    can be erased through the external name, resetting the ceiling indefinitely.
  - the check was separated from the use, so the path could be swapped in between.
  - pruning with `rm -rf` on a glob result would follow such a symlink into a tree.

Here every component is opened with dir_fd + O_NOFOLLOW, and every subsequent operation
is performed *at that fd* — so the directory that was validated is the same one written
to, with no second path resolution to race. Parent traversal is rejected outright since
O_NOFOLLOW does nothing about `..`.

WHY IMMUTABLE SLOTS
Uses are `<mtime>.<n>` directories created with mkdir, which is atomic and fails if the
name exists — so exactly one process can own slot n. A mutable counter would be a
read-modify-write: two concurrent gates both read k and both write k+1, silently
overshooting the ceiling. Keying on the skip file mtime means a fresh operator touch
starts a new lease, and slots from a previous one are pruned rather than trusted.
"""

import fcntl
import os
import sys
import time

# ~0.5s ceiling, same shape as the audit appender: bounded, never blocking.
_LOCK_TRIES = 10
_LOCK_WAIT = 0.05

# `python3 -I` implies -P, which strips the script's own directory from sys.path, so the
# sibling import below needs it back. Inserting THIS FILE's resolved directory is safe
# and deliberate: it is the trusted gate lib/, the same directory the gate scripts pass
# explicitly to their inline parsers. -I still ignores PYTHONPATH and site, so nothing
# else can shadow the import.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from audit_append import append_at, open_state_dir  # noqa: E402  (path fix above)

LEASE_DIRNAME = ".skip-design-review-lease.d"
# The skip file name is a CONSTANT, not an argument. Accepting any slash-free name let a
# caller point the lease key at `.`, `..`, the ledger itself, or an unrelated state file,
# whose unrelated mtime then became the prefix — pruning the genuine slots as stale and
# restarting the ceiling.
SKIP_NAME = "skip-design-review.local"

NS = 10 ** 9   # `now` and every age in this module are integer NANOSECONDS.
# Verdicts. Distinct codes so the caller can emit the right message from ONE mtime read.
OK, ERROR, EXHAUSTED, TOO_NEW, EXPIRED = 0, 1, 2, 3, 4


def _log_use(sfd, slot, max_uses):
    """Append the bypass-telemetry event for ONE granted use. True only when durable.

    Written at the ALREADY-VALIDATED state dir fd, never by pathname. The slot was created
    through sfd; resolving the repo-controlled path a second time meant a rename between
    the two could put the slot and its audit event in different directory inodes, and this
    would report a granted use whose accounting is not in the ledger anyone reads.

    One event per use, recording the SLOT claimed and the ceiling, so lease state is
    observable from the log without consuming a use to check it. Deliberately NOT a
    "remaining" count: the slot number is what this process actually knows. Under
    concurrency (or after a refused use left a hole that is later reclaimed) a computed
    remaining would be wrong in a way the reader could not detect. Count the events, or
    the slot dirs, for the live figure.

    COMPACT separators, matching the printf format the other gates use. The default
    json.dumps spacing (`"event": "..."`) would no longer match the exact substring
    post-commit-consume-marker.sh greps for, so lease events would stop suppressing the
    false unreviewed-commit audit entry — an integration break invisible from here.
    """
    import datetime
    import json
    rec = json.dumps({
        "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "event": "skip-review-consumed",
        "gate": "pre-implementation",
        "lease_slot": slot,
        "lease_max": max_uses,
    }, separators=(",", ":"))
    return append_at(sfd, rec)


POISON_SUFFIX = ".poison"


def _poison(lfd, sfd, mtime):
    """Mark the lease keyed to `mtime` permanently refused, so a skip file that survived
    its own rejection is dead the moment it would otherwise become acceptable.

    ONE sentinel directory, not max_uses filled slots. Filling slots one at a time was
    only best-effort: a transient ENOSPC partway through — or a crash before the parent
    fsync — left unused slots behind, and a later claim happily granted them. A single
    atomic mkdir either exists or does not.

    Returns True only when the sentinel is durably on disk. An UNSYNCED sentinel is
    reported as failure, not success: a crash could lose it while the still-armed skip
    file survived, which is precisely the state the seal exists to prevent.
    """
    try:
        os.mkdir(mtime + POISON_SUFFIX, 0o755, dir_fd=lfd)
    except FileExistsError:
        pass
    except OSError:
        return False
    try:
        os.fsync(lfd)
        os.fsync(sfd)
    except OSError:
        return False
    return True


def _open_locked_ledger(sfd):
    """Open the lease ledger and hold an EXCLUSIVE lock on it. None on refusal.

    THE LOCK IS ON THE LEDGER, not on the skip file. flock attaches to an inode, and the
    skip file is the one object here that is *expected* to be replaced — re-arming is
    exactly `rm && touch`. Locking it meant two claimants could hold locks on two
    different inodes and mutate the same ledger at once, and one could then prune the
    other`s just-created slot so it was reclaimed and the ceiling exceeded. The ledger is
    created by this module, is a protected marker, and is never replaced in normal
    operation, so every claimant serializes on the same inode.

    Bounded acquisition, like the audit appender: a blocking flock has no deadline, and a
    PreToolUse hook that overruns its 5s budget emits no decision and therefore fails
    OPEN, so a process squatting the lock could turn a gated write into a free one.
    """
    try:
        try:
            os.mkdir(LEASE_DIRNAME, 0o755, dir_fd=sfd)
        except FileExistsError:
            pass
        else:
            # fsync the STATE dir: fsyncing the ledger persists entries INSIDE it, never
            # the ledger`s own directory entry. A crash could otherwise lose the whole
            # ledger while an audit event survived, letting the lease reclaim its slots.
            os.fsync(sfd)
        lfd = os.open(LEASE_DIRNAME, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                      dir_fd=sfd)
    except OSError:
        return None                   # symlinked ledger, not a directory, or unwritable
    for _ in range(_LOCK_TRIES):
        try:
            fcntl.flock(lfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return lfd
        except OSError:
            time.sleep(_LOCK_WAIT)
    os.close(lfd)
    return None                       # contended ⇒ refuse; never proceed unserialized


def _disarm(sfd, st):
    """Unlink the skip file, but only while it is still the one `st` describes.

    unlinkat() takes a name, not an inode, so a bare unlink races an operator who
    re-touches between the stat and the removal — destroying a freshly armed lease and
    making them arm it twice. Re-stating first closes that for a REPLACED file (a new
    inode, the `rm && touch` and copy-restore spellings).

    It does NOT close a same-inode `touch` landing between the comparison and the unlink;
    unlinkat has no by-inode form, so nothing here can. That residual costs the operator
    one extra `touch` and can never grant a use, which is the direction to err in.
    """
    try:
        cur = os.stat(SKIP_NAME, dir_fd=sfd, follow_symlinks=False)
    except FileNotFoundError:
        return True                   # genuinely gone
    except OSError:
        return False                  # EACCES/EIO -- unknown is NOT gone
    # st_mtime_ns, matching the lease key. Comparing whole seconds let a same-inode
    # re-touch inside one second change the key while still looking identical here, so a
    # freshly armed lease was unlinked as if it were the rejected one.
    if (cur.st_ino, cur.st_mtime_ns) != (st.st_ino, st.st_mtime_ns):
        return True                   # a different file now — not ours to remove
    try:
        os.unlink(SKIP_NAME, dir_fd=sfd)
        # fsync the STATE dir: an unlink is a directory-entry change, and until the
        # parent is synced a crash can bring the file back. The TOO_NEW path accepts a
        # successful disarm as an ALTERNATIVE to a durable poison sentinel, so an
        # unsynced removal would let a rejected file reappear with no sentinel behind it
        # and go valid once it aged past the floor.
        os.fsync(sfd)
    except OSError:
        return False
    return True


def claim(state_dir, max_uses, min_age, max_age, now):
    """Claim one slot for the lease keyed to <state_dir>/<skip_name>.

    Returns the claimed slot number, 0 if exhausted, or None if nothing could be
    recorded (which the caller must treat as a refusal, never as a free pass).

    Returns (verdict, slot). The AGE CHECKS happen here, against the SAME stat that
    produces the lease key — the shell used to read the mtime for the 30s floor and the
    3600s ceiling and then let this function read it again, so a touch or replacement
    between the two obtained a lease whose new mtime passed neither check.

    Reading the mtime here rather than accepting it is also what makes the helper safe by
    construction: a caller-supplied mtime is forgeable, and a fabricated one prunes the
    genuine slots below, resetting the ceiling no matter how the helper was reached.
    Blocking direct invocation from a Bash call is still done, but it is defence in depth
    now rather than the only thing in the way.

    The whole decision — stat, age verdict, poison, prune, slot claim, audit append — is
    SERIALIZED under an exclusive lock on the LEDGER. Without it, a process could classify
    mtime M as too-new and be descheduled before writing the poison, while a second
    process past the age boundary listed the ledger, saw no poison, and granted a slot;
    and a claim could act on an `entries` snapshot that a concurrent poison had already
    invalidated. Immutable slots make the COUNTING race-free on their own, but the
    age/poison decision spans several syscalls and needs the lock.
    """
    sfd = open_state_dir(state_dir)
    if sfd is None:
        return (ERROR, 0)
    try:
        lfd = _open_locked_ledger(sfd)
        if lfd is None:
            return (ERROR, 0)
        try:
            return _claim_locked(sfd, lfd, max_uses, min_age, max_age, now)
        finally:
            os.close(lfd)
    finally:
        os.close(sfd)


def _claim_locked(sfd, lfd, max_uses, min_age, max_age, now):
    """The body of claim(), under the ledger lock. Closes neither fd."""
    try:
        st = os.stat(SKIP_NAME, dir_fd=sfd, follow_symlinks=False)
    except OSError:
        return (ERROR, 0)             # no skip file ⇒ no lease to claim
    # INTEGER NANOSECONDS on both sides. Whole seconds let a file 29.1s old measure as
    # 30 and clear the anti-self-bypass floor; binary floats then left a ~238ns window at
    # contemporary timestamps where 29.9999999 rounds up to exactly 30.0. Neither side
    # is a float now, so both boundaries are exact at every epoch.
    age = now - st.st_mtime_ns
    # NANOSECOND lease key. Truncating to whole seconds meant a poisoned lease and a
    # genuine re-`touch` inside the same second shared a key, so the fresh lease matched
    # the old poison and reported EXHAUSTED -- contradicting the ADR promise that a real
    # touch always starts clean. (On a filesystem with 1s mtime granularity the two are
    # indistinguishable at the syscall level and the collision remains; the operator waits
    # a second. Every filesystem this runs on in practice stores sub-second times.)
    mtime = str(st.st_mtime_ns)
    if age < min_age * NS or age > max_age * NS:
        # DISARM HERE, at the fd already validated, rather than leaving it to the caller.
        # The shell ran a second `--unlink <dir> <name>` command that swallowed failures
        # with `|| true`, so a skip file that could not be removed (immutable file in a
        # writable dir) simply survived its own rejection — and a TOO_NEW one then aged
        # past the floor and became a perfectly valid lease, which is exactly the
        # self-bypass the floor exists to stop.
        #
        # A TOO_NEW lease is poisoned FIRST and unconditionally, before the unlink is even
        # attempted: poisoning is what actually enforces the floor, and doing it only in
        # the unlink's failure branch made the enforcement conditional on a syscall that
        # can fail transiently. Poisoning a lease that then gets removed anyway costs one
        # inert directory, which the next operator touch prunes.
        sealed = _poison(lfd, sfd, mtime) if age < min_age * NS else False
        gone = _disarm(sfd, st)
        if age > max_age * NS:
            return (EXPIRED, 0)       # age only grows; it can never come back
        if not sealed and not gone:
            # Neither enforcement landed, so this process could not make the floor stick.
            # The two failures are complementary rather than independent: sealing needs a
            # writable ledger, and if the ledger is NOT writable the claim path below
            # cannot mkdir or fsync either, so every later claim returns ERROR anyway.
            # Report ERROR rather than TOO_NEW so the caller emits a hard refusal instead
            # of a self-bypass message describing a file it says it removed.
            return (ERROR, 0)
        return (TOO_NEW, 0)
    try:
        # Prune slots from a PREVIOUS lease (different mtime prefix). rmdir, not a
        # recursive delete: slots are empty directories, so this both suffices and
        # cannot walk into a tree if something unexpected is present.
        prefix = mtime + "."
        try:
            entries = os.listdir(lfd)
        except OSError:
            return (ERROR, 0)     # cannot enumerate ⇒ cannot bound ⇒ refuse
        for name in entries:
            if name.startswith(prefix):
                continue
            # A POISON SENTINEL FROM ANOTHER LEASE IS NOT STALE. Pruning it broke the
            # permanently-dead guarantee outright: reject mtime M, claim once under
            # M+1 to sweep `M.poison` away, then restore the file at M and the seal is
            # gone. Sentinels are kept until their own mtime falls outside the expiry
            # window, past which a restored file is EXPIRED anyway -- so they cannot
            # accumulate without bound either.
            if name.endswith(POISON_SUFFIX):
                try:
                    # >=, not >: expiry is `age > max_age`, so a file whose mtime is
                    # exactly `now - max_age` is still VALID. Dropping its sentinel one
                    # second early let a restore at that timestamp claim a slot.
                    # Keys are ns since #519 review round 9; compare in ns.
                    if int(name[:-len(POISON_SUFFIX)]) >= now - max_age * NS:
                        continue
                except ValueError:
                    pass          # not a timestamp we wrote; treat as prunable
            try:
                os.rmdir(name, dir_fd=lfd)
            except OSError:
                pass              # best effort; a stale name is inert anyway
        # POISONED: this lease was rejected as too-new earlier and could not be
        # removed, so it is dead however old it has since become. Reported as
        # exhausted because that is what it is — a lease with nothing left to give.
        # The sentinel shares the mtime prefix, so the prune above keeps it for THIS
        # lease and clears it for any other.
        if mtime + POISON_SUFFIX in entries:
            _disarm(sfd, st)
            return (EXHAUSTED, 0)
        for n in range(1, max_uses + 1):
            try:
                os.mkdir("%s%d" % (prefix, n), 0o755, dir_fd=lfd)
            except FileExistsError:
                continue
            except OSError:
                return (ERROR, 0)  # cannot record ⇒ refuse
            # fsync the LEDGER directory before reporting the claim. mkdir returning
            # success does not make the directory ENTRY durable, so a crash could
            # lose the slot while the skip file and the fsynced audit event survive —
            # the next run would then reclaim it and exceed the ceiling. Treat an
            # unsyncable claim as unrecorded and refuse, rather than granting a use
            # whose accounting might evaporate.
            try:
                os.fsync(lfd)
            except OSError:
                return (ERROR, 0)
            # The audit event is minted HERE, in the same call that created the
            # slot, and never from a CLI. A standalone `audit_append.py <dir> 1 20`
            # could forge a `skip-review-consumed` record with no lease behind it —
            # and post-commit-consume-marker.sh treats a recent one of those as
            # proof that a bypass was sanctioned, so the forged line suppressed a
            # genuine unreviewed-commit entry. Binding the write to the mkdir that
            # just succeeded means an event exists only where a use was really
            # spent, instead of leaving the Bash invocation detector as the only
            # thing standing between a caller and the protected log.
            #
            # FAIL-CLOSED, and the slot stays SPENT. An unlogged use is not a
            # sanctioned bypass -- the docs promise every use is recorded, so the
            # promise is enforced rather than merely stated. Keeping the slot can
            # only make the lease shorter, never longer.
            if not _log_use(sfd, n, max_uses):
                return (ERROR, 0)
            return (OK, n)
        # Every slot exists. Distinguish exhausted from unwritable by re-counting,
        # so a permissions failure is never reported as a spent budget.
        try:
            used = sum(1 for e in os.listdir(lfd) if e.startswith(prefix))
        except OSError:
            return (ERROR, 0)
        if used < max_uses:
            return (ERROR, 0)
        # Disarm the spent file here too. The SLOTS deliberately stay: they are the
        # exhaustion proof and must outlive the file that spent them, or a concurrent
        # gate that already passed the mtime checks would recreate the ledger, claim
        # slot 1 under the same mtime, and be granted a use past the ceiling.
        # _disarm, not a bare unlink: an operator who re-touches while this process is
        # between the stat and the removal would otherwise lose their fresh lease.
        _disarm(sfd, st)
        return (EXHAUSTED, 0)
    except OSError:
        return (ERROR, 0)             # fail-closed catch-all; never a free pass


def _demo():
    """Self-check: slots increment, exhaust, reset on a new mtime, age checks fire, and
    every path escape refuses, and every granted use is logged."""
    import json
    import tempfile
    cwd = os.getcwd()
    with tempfile.TemporaryDirectory() as t:
        os.chdir(t)
        try:
            os.mkdir(".claude")
            skip = os.path.join(".claude", SKIP_NAME)

            def _ns(sec):
                """Readable seconds -> the integer nanoseconds claim() takes. Rounded,
                not truncated, so a case written as 29.1 is the age it reads as."""
                return round(sec * NS)

            def arm(t, where=".claude"):
                """(Re-)create the skip file with mtime t. Needed after every refusal:
                claim() disarms the file itself on TOO_NEW / EXPIRED / EXHAUSTED."""
                p = os.path.join(where, SKIP_NAME)
                open(p, "w").close()
                os.utime(p, (t, t))

            arm(1000)
            NOW = 1000 + 120                      # 120s old: past the floor, inside the cap
            assert claim(".claude", 3, 30, 3600, _ns(NOW)) == (OK, 1)
            assert claim(".claude", 3, 30, 3600, _ns(NOW)) == (OK, 2)
            assert claim(".claude", 3, 30, 3600, _ns(NOW)) == (OK, 3)
            assert claim(".claude", 3, 30, 3600, _ns(NOW)) == (EXHAUSTED, 0)
            # ...and each refusal DISARMED the file, so it cannot stay armed and silently
            # authorize a later session.
            assert not os.path.exists(skip)

            # Every granted use logged exactly one event; a refused one logged none.
            log = open(os.path.join(".claude", "bypass-log.jsonl")).read().splitlines()
            assert len(log) == 3, log
            assert all('"event":"skip-review-consumed"' in ln for ln in log), log
            assert [json.loads(ln)["lease_slot"] for ln in log] == [1, 2, 3], log

            # Age checks run against the SAME stat that keys the lease, and BOTH
            # boundaries are exact: age < min_age refuses, age == min_age passes;
            # age <= max_age passes, age > max_age expires. Off-by-one either way
            # would widen the self-bypass floor or the expiry window silently.
            for base, (cap, floor) in enumerate(((3, 30), (5, 30), (5, 120))):
                # A distinct mtime per sub-case AND per too-new probe: a TOO_NEW verdict
                # poisons the lease it rejected, so re-arming at the same mtime is (by
                # design) still dead.
                t0 = 3000 + 2 * base
                arm(t0)
                assert claim(".claude", cap, floor, 3600, _ns(t0 + floor - 1))[0] == TOO_NEW
                t0 += 1
                arm(t0)
                assert claim(".claude", cap, floor, 3600, _ns(t0 + floor)) == (OK, 1)
                assert claim(".claude", cap, floor, 3600, _ns(t0 + 3600)) == (OK, 2)
                assert claim(".claude", cap, floor, 3600, _ns(t0 + 3601))[0] == EXPIRED
                arm(t0)
                # ...and the ceiling holds at exactly cap uses, for every cap.
                for n in range(3, cap + 1):
                    assert claim(".claude", cap, floor, 3600, _ns(t0 + floor)) == (OK, n)
                assert claim(".claude", cap, floor, 3600, _ns(t0 + floor))[0] == EXHAUSTED

            # ...and SUB-SECOND ages land on the right side of both boundaries, to the
            # nanosecond. Whole seconds let a file 29.1s old measure as 30 and clear the
            # anti-self-bypass floor -- the one number this control exists to enforce --
            # and binary floats then left a ~238ns window at contemporary timestamps
            # where 29.9999999 rounded up to exactly 30.0. Run at BOTH a tiny epoch and a
            # present-day one: float spacing grows with the epoch, so a test pinned near
            # zero cannot see the failure that only appears in production.
            _CASES = ((29 * NS + NS // 10, TOO_NEW),    # 29.1s
                      (30 * NS - 1, TOO_NEW),           # one nanosecond short of the floor
                      (30 * NS, OK),                    # exactly the floor passes
                      (3600 * NS, OK),                  # exactly the ceiling is still valid
                      (3600 * NS + 1, EXPIRED))         # one nanosecond past it
            for epoch in (5000, 1_780_000_000):
                for k, (age_ns, want) in enumerate(_CASES):
                    t0 = epoch + k          # distinct mtime: TOO_NEW poisons its key
                    arm(t0)
                    got = claim(".claude", 3, 30, 3600, t0 * NS + age_ns)[0]
                    assert got == want, (epoch, age_ns, got, want)

            # A too-new lease is POISONED, so a file that survives its own rejection
            # (immutable file in a writable dir) is dead however old it later becomes.
            # Re-armed at the SAME mtime here, which is what an unremovable file amounts
            # to; a genuine new touch gets a new mtime and a clean lease (below).
            arm(9000)
            assert claim(".claude", 3, 30, 3600, _ns(9000 + 5))[0] == TOO_NEW
            assert os.path.exists(os.path.join(".claude", LEASE_DIRNAME,
                                               str(9000 * 10**9) + POISON_SUFFIX))
            arm(9000)
            assert claim(".claude", 3, 30, 3600, _ns(9000 + 120))[0] == EXHAUSTED
            assert not os.path.exists(skip)      # ...and disarmed again on the way out

            # _disarm declines to remove a DIFFERENT file than the one it statted, so an
            # operator re-touch mid-decision is not destroyed.
            arm(4000)
            _sfd = open_state_dir(".claude")
            _st = os.stat(SKIP_NAME, dir_fd=_sfd, follow_symlinks=False)
            arm(4500)                            # the operator re-touches: new mtime
            assert _disarm(_sfd, _st)            # reports done...
            assert os.path.exists(skip)          # ...without taking the new lease
            assert _disarm(_sfd, os.stat(SKIP_NAME, dir_fd=_sfd, follow_symlinks=False))
            assert not os.path.exists(skip)      # ...but does remove a matching one
            os.close(_sfd)

            # A new operator touch (new mtime) starts a fresh lease and prunes the old.
            arm(2000)
            assert claim(".claude", 3, 30, 3600, _ns(2000 + 120)) == (OK, 1)
            names = os.listdir(os.path.join(".claude", LEASE_DIRNAME))
            assert all(n.startswith(str(2000 * 10**9) + ".") or n.endswith(POISON_SUFFIX)
                       for n in names), names

            # ...but a POISON SENTINEL survives another lease's prune, or the seal could
            # be swept away by claiming once under any other mtime and the file then
            # restored at the poisoned one.
            assert str(9000 * 10**9) + POISON_SUFFIX in names, names
            arm(9000)
            assert claim(".claude", 3, 30, 3600, _ns(9000 + 200))[0] == EXHAUSTED

            # No skip file at all: nothing to claim.
            os.mkdir("empty")
            assert claim("empty", 3, 30, 3600, _ns(NOW))[0] == ERROR

            # A symlinked ledger must refuse rather than place slots outside the repo.
            os.makedirs("s")
            arm(1000, "s")
            os.symlink("/tmp", os.path.join("s", LEASE_DIRNAME))
            assert claim("s", 3, 30, 3600, _ns(NOW))[0] == ERROR

            # A symlinked PREFIX of a nested state dir must refuse too — the case a
            # shell `-L "$STATE_DIR"` test silently passes.
            os.mkdir("real")
            os.symlink("real", "link")
            assert claim("link/state", 3, 30, 3600, _ns(NOW))[0] == ERROR
            assert not os.path.exists(os.path.join("real", "state"))

            assert claim("../outside", 3, 30, 3600, _ns(NOW))[0] == ERROR
            assert claim("/tmp/outside", 3, 30, 3600, _ns(NOW))[0] == ERROR

        finally:
            os.chdir(cwd)
    print("lease_slot self-check OK")


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--self-check":
        _demo()
        raise SystemExit(0)
    # NO `--unlink <dir> <name>` SUBCOMMAND. It accepted any slash-free basename, so
    # anything that reached it could delete `bypass-log.jsonl` — the protected audit log
    # — and it needed no modification verb, so the gate's Bash detector was the only
    # thing in its way. claim() disarms the skip file itself, at the dir fd it has
    # already validated, which is both the only caller this ever had and one fewer
    # entry point to guard.
    #   lease_slot.py <state_dir> <max_uses> <min_age> <max_age>
    # Exit: 0 claimed (slot on stdout) / 1 error / 2 exhausted / 3 too new / 4 expired.
    if len(sys.argv) != 5:
        raise SystemExit(ERROR)
    try:
        verdict, slot = claim(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]),
                              int(sys.argv[4]), time.time_ns())
    except Exception:
        raise SystemExit(ERROR)
    if verdict == OK:
        sys.stdout.write(str(slot))
    raise SystemExit(verdict)
