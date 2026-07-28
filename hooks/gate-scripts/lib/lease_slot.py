"""Claim ONE skip-lease slot, atomically and inside the repo (#519).

Usage:  python3 -I lease_slot.py <state_dir> <mtime> <max_uses>
Exit:   0 = claimed (slot number on stdout)
        1 = could NOT record a claim — caller must refuse the bypass (fail-closed)
        2 = exhausted (all <max_uses> slots already taken)

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

# `python3 -I` implies -P, which strips the script's own directory from sys.path, so the
# sibling import below needs it back. Inserting THIS FILE's resolved directory is safe
# and deliberate: it is the trusted gate lib/, the same directory the gate scripts pass
# explicitly to their inline parsers. -I still ignores PYTHONPATH and site, so nothing
# else can shadow the import.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from audit_append import open_state_dir  # noqa: E402  (needs the path fix above)

LEASE_DIRNAME = ".skip-design-review-lease.d"


def claim(state_dir, mtime, max_uses):
    """Returns the claimed slot number, 0 if exhausted, or None if nothing could be
    recorded (which the caller must treat as a refusal, never as a free pass)."""
    sfd = open_state_dir(state_dir)
    if sfd is None:
        return None
    try:
        try:
            os.mkdir(LEASE_DIRNAME, 0o755, dir_fd=sfd)
        except FileExistsError:
            pass
        except OSError:
            return None
        try:
            lfd = os.open(LEASE_DIRNAME, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                          dir_fd=sfd)
        except OSError:
            return None               # symlinked ledger, or not a directory
        try:
            # Prune slots from a PREVIOUS lease (different mtime prefix). rmdir, not a
            # recursive delete: slots are empty directories, so this both suffices and
            # cannot walk into a tree if something unexpected is present.
            prefix = mtime + "."
            try:
                entries = os.listdir(lfd)
            except OSError:
                return None           # cannot enumerate ⇒ cannot bound ⇒ refuse
            for name in entries:
                if not name.startswith(prefix):
                    try:
                        os.rmdir(name, dir_fd=lfd)
                    except OSError:
                        pass          # best effort; a stale name is inert anyway
            for n in range(1, max_uses + 1):
                try:
                    os.mkdir("%s%d" % (prefix, n), 0o755, dir_fd=lfd)
                    return n
                except FileExistsError:
                    continue
                except OSError:
                    return None       # cannot record ⇒ refuse
            # Every slot exists. Distinguish exhausted from unwritable by re-counting,
            # so a permissions failure is never reported as a spent budget.
            try:
                used = sum(1 for e in os.listdir(lfd) if e.startswith(prefix))
            except OSError:
                return None
            return 0 if used >= max_uses else None
        finally:
            os.close(lfd)
    finally:
        os.close(sfd)


def _demo():
    """Self-check: slots increment, exhaust, reset on a new mtime, and refuse escapes."""
    import tempfile
    cwd = os.getcwd()
    with tempfile.TemporaryDirectory() as t:
        os.chdir(t)
        try:
            assert claim(".claude", "111", 3) == 1
            assert claim(".claude", "111", 3) == 2
            assert claim(".claude", "111", 3) == 3
            assert claim(".claude", "111", 3) == 0          # exhausted
            # A new operator touch (new mtime) starts a fresh lease and prunes the old.
            assert claim(".claude", "222", 3) == 1
            names = os.listdir(os.path.join(".claude", LEASE_DIRNAME))
            assert all(n.startswith("222.") for n in names), names

            # A symlinked ledger must refuse rather than place slots outside the repo.
            os.makedirs("s")
            os.symlink("/tmp", os.path.join("s", LEASE_DIRNAME))
            assert claim("s", "111", 3) is None

            # A symlinked PREFIX of a nested state dir must refuse too — this is the
            # case a shell `-L "$STATE_DIR"` test silently passes.
            os.mkdir("real")
            os.symlink("real", "link")
            assert claim("link/state", "111", 3) is None
            assert not os.path.exists(os.path.join("real", "state"))

            assert claim("../outside", "111", 3) is None
            assert claim("/tmp/outside", "111", 3) is None
        finally:
            os.chdir(cwd)
    print("lease_slot self-check OK")


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--self-check":
        _demo()
        raise SystemExit(0)
    if len(sys.argv) != 4:
        raise SystemExit(1)
    try:
        got = claim(sys.argv[1], sys.argv[2], int(sys.argv[3]))
    except Exception:
        raise SystemExit(1)
    if got is None:
        raise SystemExit(1)
    if got == 0:
        raise SystemExit(2)
    sys.stdout.write(str(got))
    raise SystemExit(0)
