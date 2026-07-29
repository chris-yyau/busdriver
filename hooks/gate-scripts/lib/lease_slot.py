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

import os
import sys
import time

# `python3 -I` implies -P, which strips the script's own directory from sys.path, so the
# sibling import below needs it back. Inserting THIS FILE's resolved directory is safe
# and deliberate: it is the trusted gate lib/, the same directory the gate scripts pass
# explicitly to their inline parsers. -I still ignores PYTHONPATH and site, so nothing
# else can shadow the import.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from audit_append import append, open_state_dir  # noqa: E402  (needs the path fix above)

LEASE_DIRNAME = ".skip-design-review-lease.d"
# The skip file name is a CONSTANT, not an argument. Accepting any slash-free name let a
# caller point the lease key at `.`, `..`, the ledger itself, or an unrelated state file,
# whose unrelated mtime then became the prefix — pruning the genuine slots as stale and
# restarting the ceiling.
SKIP_NAME = "skip-design-review.local"

# Verdicts. Distinct codes so the caller can emit the right message from ONE mtime read.
OK, ERROR, EXHAUSTED, TOO_NEW, EXPIRED = 0, 1, 2, 3, 4


def _log_use(state_dir, slot, max_uses):
    """Append the bypass-telemetry event for ONE granted use. True only when durable.

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
    return append(state_dir, rec)


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
    """
    sfd = open_state_dir(state_dir)
    if sfd is None:
        return (ERROR, 0)
    try:
        st = os.stat(SKIP_NAME, dir_fd=sfd, follow_symlinks=False)
    except OSError:
        os.close(sfd)
        return (ERROR, 0)             # no skip file ⇒ no lease to claim
    age = now - int(st.st_mtime)
    if age < min_age:
        os.close(sfd)
        return (TOO_NEW, 0)
    if age > max_age:
        os.close(sfd)
        return (EXPIRED, 0)
    mtime = str(int(st.st_mtime))
    try:
        try:
            os.mkdir(LEASE_DIRNAME, 0o755, dir_fd=sfd)
        except FileExistsError:
            pass
        except OSError:
            return (ERROR, 0)
        else:
            # fsync the STATE dir as well: fsyncing the ledger persists entries INSIDE
            # it, never the ledger's own directory entry. A crash could otherwise lose
            # the whole ledger while the audit event survived, letting the same lease
            # reclaim its slots and exceed the ceiling.
            try:
                os.fsync(sfd)
            except OSError:
                return (ERROR, 0)
        try:
            lfd = os.open(LEASE_DIRNAME, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                          dir_fd=sfd)
        except OSError:
            return (ERROR, 0)         # symlinked ledger, or not a directory
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
                if not name.startswith(prefix):
                    try:
                        os.rmdir(name, dir_fd=lfd)
                    except OSError:
                        pass          # best effort; a stale name is inert anyway
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
                if not _log_use(state_dir, n, max_uses):
                    return (ERROR, 0)
                return (OK, n)
            # Every slot exists. Distinguish exhausted from unwritable by re-counting,
            # so a permissions failure is never reported as a spent budget.
            try:
                used = sum(1 for e in os.listdir(lfd) if e.startswith(prefix))
            except OSError:
                return (ERROR, 0)
            return (EXHAUSTED, 0) if used >= max_uses else (ERROR, 0)
        finally:
            os.close(lfd)
    finally:
        os.close(sfd)


def unlink_in_state(state_dir, name):
    """Unlink <cwd>/<state_dir>/<name> with the same O_NOFOLLOW component walk.

    A shell `rm -f "$STATE_DIR/skip-design-review.local"` resolves the path afresh and
    follows a symlinked INTERMEDIATE component, so it can delete outside the repository
    — and it runs BEFORE lease_slot.py ever validates anything. Routing the unlink
    through the validated dir fd removes that window. Returns True if the file is gone.
    """
    if "/" in name:
        return False
    sfd = open_state_dir(state_dir)
    if sfd is None:
        return False
    try:
        try:
            os.unlink(name, dir_fd=sfd)
        except FileNotFoundError:
            return True
        except OSError:
            return False
        return True
    finally:
        os.close(sfd)


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
            open(skip, "w").close()
            os.utime(skip, (1000, 1000))
            NOW = 1000 + 120                      # 120s old: past the floor, inside the cap
            assert claim(".claude", 3, 30, 3600, NOW) == (OK, 1)
            assert claim(".claude", 3, 30, 3600, NOW) == (OK, 2)
            assert claim(".claude", 3, 30, 3600, NOW) == (OK, 3)
            assert claim(".claude", 3, 30, 3600, NOW) == (EXHAUSTED, 0)

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
                t0 = 3000 + base          # a distinct mtime = a distinct lease per case
                os.utime(skip, (t0, t0))
                assert claim(".claude", cap, floor, 3600, t0 + floor - 1)[0] == TOO_NEW
                assert claim(".claude", cap, floor, 3600, t0 + floor) == (OK, 1)
                assert claim(".claude", cap, floor, 3600, t0 + 3600) == (OK, 2)
                assert claim(".claude", cap, floor, 3600, t0 + 3601)[0] == EXPIRED
                # ...and the ceiling holds at exactly cap uses, for every cap.
                for n in range(3, cap + 1):
                    assert claim(".claude", cap, floor, 3600, t0 + floor) == (OK, n)
                assert claim(".claude", cap, floor, 3600, t0 + floor)[0] == EXHAUSTED

            os.utime(skip, (1000, 1000))

            # A new operator touch (new mtime) starts a fresh lease and prunes the old.
            os.utime(skip, (2000, 2000))
            assert claim(".claude", 3, 30, 3600, 2000 + 120) == (OK, 1)
            names = os.listdir(os.path.join(".claude", LEASE_DIRNAME))
            assert all(n.startswith("2000.") for n in names), names

            # No skip file at all: nothing to claim.
            os.mkdir("empty")
            assert claim("empty", 3, 30, 3600, NOW)[0] == ERROR

            # A symlinked ledger must refuse rather than place slots outside the repo.
            os.makedirs("s")
            open(os.path.join("s", SKIP_NAME), "w").close()
            os.utime(os.path.join("s", SKIP_NAME), (1000, 1000))
            os.symlink("/tmp", os.path.join("s", LEASE_DIRNAME))
            assert claim("s", 3, 30, 3600, NOW)[0] == ERROR

            # A symlinked PREFIX of a nested state dir must refuse too — the case a
            # shell `-L "$STATE_DIR"` test silently passes.
            os.mkdir("real")
            os.symlink("real", "link")
            assert claim("link/state", 3, 30, 3600, NOW)[0] == ERROR
            assert not os.path.exists(os.path.join("real", "state"))

            assert claim("../outside", 3, 30, 3600, NOW)[0] == ERROR
            assert claim("/tmp/outside", 3, 30, 3600, NOW)[0] == ERROR

            # unlink_in_state: removes a real file, refuses a symlinked prefix and a
            # path separator, and treats an already-absent file as success.
            open(os.path.join(".claude", "skipf"), "w").close()
            assert unlink_in_state(".claude", "skipf")
            assert not os.path.exists(os.path.join(".claude", "skipf"))
            assert unlink_in_state(".claude", "skipf")          # already gone
            assert not unlink_in_state("link/state", "skipf")   # symlinked prefix
            assert not unlink_in_state(".claude", "a/b")        # no separators
        finally:
            os.chdir(cwd)
    print("lease_slot self-check OK")


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--self-check":
        _demo()
        raise SystemExit(0)
    if len(sys.argv) == 4 and sys.argv[1] == "--unlink":
        raise SystemExit(0 if unlink_in_state(sys.argv[2], sys.argv[3]) else 1)
    #   lease_slot.py <state_dir> <max_uses> <min_age> <max_age>
    # Exit: 0 claimed (slot on stdout) / 1 error / 2 exhausted / 3 too new / 4 expired.
    if len(sys.argv) != 5:
        raise SystemExit(ERROR)
    try:
        verdict, slot = claim(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]),
                              int(sys.argv[4]), int(time.time()))
    except Exception:
        raise SystemExit(ERROR)
    if verdict == OK:
        sys.stdout.write(str(slot))
    raise SystemExit(verdict)
