"""Hardened append of ONE record to the bypass audit log (#519).

Imported by lease_slot.py; `--self-check` is its only command line. There is no CLI that
writes a record — see the `__main__` block for why that entry point was removed.

WHY A HELPER AND NOT `>>`
A shell redirect follows symlinks at EVERY path component, so a repo-writable
`.claude/bypass-log.jsonl -> /dev/null` — or a symlinked `.claude/`, or a symlinked
intermediate when BUSDRIVER_STATE_DIR is nested like `a/b` — makes the write "succeed"
while retaining nothing. Any caller that treats a successful `>>` as proof of a durable
audit record is then trusting a write that never landed. That matters here because the
gate REFUSES a skip-lease use whose audit append fails: the guarantee is only worth as
much as the check behind it.

The path is attacker-influenced (the state dir is repo-relative and repo-controlled),
so every component is walked from the CWD with dir_fd + O_NOFOLLOW, creating as needed,
refusing the moment one is a symlink or not a directory. Same reasoning, and the same
shape, as the writer in scripts/design-clear.sh.

TORN LINES
A pre-existing partial line poisons every later append: this record would concatenate
onto the fragment and the joined line is not valid JSONL. Refuse rather than compound
it — and deliberately do NOT ftruncate a rollback, because other gate scripts append to
this same log with unlocked `>>` and do not honor our flock; rolling back could erase an
unrelated writer's event. The fragment stays, this append refuses, and the next one
refuses too, so an operator is forced to repair the log rather than accumulate silent
corruption. Fail-closed, never destructive.
"""

import fcntl
import os
import stat
import sys
import time


# ~0.5s ceiling total — comfortably inside the 5s PreToolUse hook budget.
_LOCK_TRIES = 10
_LOCK_WAIT = 0.05

# Three-valued append outcome (#549). Callers that refund a lease slot may do so ONLY
# on DID_NOT_WRITE; UNKNOWN means a record may already be in the log.
WROTE, DID_NOT_WRITE, UNKNOWN = 1, 0, -1


def open_state_dir(state_dir):
    """Open <cwd>/<state_dir> as a dir fd, creating components, with NO symlink or
    parent traversal anywhere in the path. Returns the fd, or None on refusal.

    Shared with lease_slot.py so both gate-state writers contain the path identically —
    a `-L` test in shell checks only the FINAL name, passes a nested `link/state` whose
    PREFIX is a symlink, and is separated from the later use by a TOCTOU window.
    """
    if state_dir.startswith("/"):
        return None
    parts = [p for p in state_dir.split("/") if p and p != "."]
    if any(p == ".." for p in parts):
        return None
    dfd = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
    for part in parts:
        try:
            os.mkdir(part, 0o755, dir_fd=dfd)
        except FileExistsError:
            pass
        except OSError:
            os.close(dfd)
            return None
        try:
            nfd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dfd)
        except OSError:
            os.close(dfd)
            return None               # symlinked or not a directory
        os.close(dfd)
        dfd = nfd
    return dfd


def state_dir_unchanged(dfd, state_dir):
    """Does <cwd>/<state_dir> STILL resolve to the directory `dfd` is open on?

    Every check that validates a NAME inside dfd assumes dfd is still the directory that
    name refers to -- and a directory descriptor outlives its own entry exactly as a file
    descriptor does. A concurrent rename of the state dir (or any component), followed by
    a replacement, leaves the slot and the audit record landing in a detached tree where
    each one verifies perfectly, while a reader opening the NAME sees an empty ledger.

    The regress TERMINATES HERE, and that is the point of putting it at this level: the
    walk is anchored at the process CWD, which is a descriptor rather than a name, so
    nothing above it can be swapped out from under the check. Verifying one more entry
    without reaching an anchor would just move the window; reaching the anchor closes it.
    """
    probe = open_state_dir(state_dir)
    if probe is None:
        return False
    try:
        mine, now = os.fstat(dfd), os.fstat(probe)
        return (mine.st_dev, mine.st_ino) == (now.st_dev, now.st_ino)
    finally:
        os.close(probe)


def append(state_dir, record_line):
    """Append record_line (no trailing newline) under <cwd>/<state_dir>/bypass-log.jsonl.
    Returns True only when the whole line is durably written."""
    dfd = open_state_dir(state_dir)
    if dfd is None:
        return False
    try:
        # The dir the record landed in must still BE the named state dir -- see
        # state_dir_unchanged for why that check belongs at this level and stops here.
        return (append_at(dfd, record_line) == WROTE
                and state_dir_unchanged(dfd, state_dir))
    finally:
        os.close(dfd)


def _landed_on_its_own_line(fd, data):
    """Is `data`, just appended to `fd`, present AND starting a line?

    O_APPEND puts the file offset at the end of our own write, so the record occupies
    `[here - len(data), here)`. Byte `here - len(data) - 1` therefore belongs to whatever
    preceded us -- a newline if the log was intact, anything else if an unlocked
    appender interleaved a partial line after our pre-write check.

    The record is READ BACK rather than assumed: our offset survives a concurrent
    truncate, so trusting it alone reported a durable record for a log another writer had
    already emptied. Best effort by construction -- the lock is advisory and the file can
    be truncated a microsecond later -- but it never reports success against a state we
    can still see is wrong.
    """
    try:
        here = os.lseek(fd, 0, os.SEEK_CUR)
    except OSError:
        return False
    start = here - len(data)
    if start < 0 or os.fstat(fd).st_size < here:
        return False              # truncated under us: the record is gone
    try:
        if os.pread(fd, len(data), start) != data:
            return False          # not our bytes -- rewritten or replaced
        return start == 0 or os.pread(fd, 1, start - 1) == b"\n"
    except OSError:
        return False


def _still_the_named_log(fd, dfd):
    """Does `bypass-log.jsonl` in `dfd` still name the inode `fd` is open on?

    Every other check here interrogates the open descriptor, and a descriptor survives
    its own directory entry: an unlocked writer can unlink or rename the log and drop a
    fresh one in its place, after which our writes and read-backs all still succeed
    against an inode nobody will ever read again. Comparing the ENTRY to the fd is what
    turns that into a refusal. Best effort, like the advisory lock -- the entry can be
    replaced a microsecond later -- but it never reports a record into a ledger we can
    already see has been swapped out.
    """
    try:
        ent = os.stat("bypass-log.jsonl", dir_fd=dfd, follow_symlinks=False)
    except OSError:
        return False                  # unlinked outright
    mine = os.fstat(fd)
    return (ent.st_dev, ent.st_ino) == (mine.st_dev, mine.st_ino)


def append_at(dfd, record_line):
    """append() against an ALREADY-VALIDATED state dir fd. Does not close dfd.

    Returns WROTE, DID_NOT_WRITE, or UNKNOWN. DID_NOT_WRITE means no complete record
    reached the log; UNKNOWN means a record may have been written but durability or
    ledger identity could not be confirmed — callers must not refund a lease slot on
    UNKNOWN (#549).

    Callers that have opened the state dir once should use this rather than resolving the
    repo-controlled path a second time. lease_slot creates the slot at its own validated
    fd; if it then logged by pathname, a rename or replacement between the two could put
    the slot and its audit event in different directory inodes — reporting a granted use
    whose accounting is not in the ledger anyone will read.
    """
    try:
        # O_RDWR, not O_WRONLY: the torn-line check below pread()s the last byte,
        # which a write-only fd cannot do. O_APPEND still lands every write at EOF.
        fd = os.open("bypass-log.jsonl",
                     os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW,
                     0o644, dir_fd=dfd)
    except OSError:
        return DID_NOT_WRITE     # symlinked log, or unwritable
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return DID_NOT_WRITE  # fifo/device posing as the log
        # BOUNDED lock. A blocking flock has no deadline, and this runs inside a
        # PreToolUse hook with a 5s budget — a hook that times out emits no block
        # and therefore fails OPEN, so any process holding this advisory lock could
        # turn a gated write into a free one. Poll briefly, then give up and refuse:
        # a refused lease is safe, a stalled hook is not.
        for _ in range(_LOCK_TRIES):
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                time.sleep(_LOCK_WAIT)
        else:
            return DID_NOT_WRITE
        size = os.fstat(fd).st_size
        if size and os.pread(fd, 1, size - 1) != b"\n":
            return DID_NOT_WRITE   # pre-existing torn line — refuse, never repair
        data = (record_line + "\n").encode()
        try:
            written = os.write(fd, data)
        except OSError:
            return DID_NOT_WRITE
        if written == 0:
            return DID_NOT_WRITE
        if written != len(data):
            return UNKNOWN     # a partial record may already be in the log
        # The lock above is ADVISORY, and the plain `>>` appenders elsewhere in the gate
        # do not take it, so the newline check and the write are not one atomic step: an
        # unlocked writer can land a partial line in between and our record concatenates
        # onto it. O_APPEND makes OUR bytes contiguous, so the interleave is visible as
        # the byte immediately before them -- read it back and refuse if it is not a
        # newline. Detection, not repair: the record stands, but the caller is told the
        # ledger did not accept it, so a lease is never granted against a torn log.
        if not _landed_on_its_own_line(fd, data):
            return UNKNOWN
        try:
            os.fsync(fd)
        except OSError:
            return UNKNOWN
        # ...and the directory entry. fsync of a file persists its CONTENTS, never
        # its name, so a freshly created log could vanish on a crash and leave a
        # granted lease with no record. design-clear.sh fsyncs the parent for the
        # same reason.
        try:
            os.fsync(dfd)
        except OSError:
            return UNKNOWN
        # LAST, so the window it cannot see is as small as it can be made: the record is
        # durable, but only in the inode our fd holds. If the NAME now points somewhere
        # else, the ledger a reader opens has no such record and the lease must not be
        # granted on the strength of it.
        if not _still_the_named_log(fd, dfd):
            return UNKNOWN
        return WROTE
    finally:
        os.close(fd)


def _demo():
    """Self-check: a real file accepts, a symlink and a torn line refuse."""
    import tempfile
    cwd = os.getcwd()
    with tempfile.TemporaryDirectory() as t:
        os.chdir(t)
        try:
            assert append(".claude", '{"a":1}')
            assert open(".claude/bypass-log.jsonl").read() == '{"a":1}\n'
            assert append(".claude", '{"a":2}')          # clean append onto a full line

            # A torn trailing line must refuse rather than concatenate.
            with open(".claude/bypass-log.jsonl", "a") as fh:
                fh.write('{"partial"')
            assert not append(".claude", '{"a":3}')

            # The post-write interleave check, exercised on the shapes it must tell
            # apart. The race it detects cannot be scheduled deterministically, so the
            # PREDICATE is driven directly: a record preceded by a newline accepted, the
            # same record concatenated onto an unlocked writer's partial line refused.
            rec = b'{"a":9}\n'
            for tail, want in (("", True), ("prev\n", True),
                               ("{\"partial\"", False), ("prev\nx", False)):
                with open("probe", "wb") as fh:
                    fh.write(tail.encode() + rec)
                pfd = os.open("probe", os.O_RDWR | os.O_APPEND)
                try:
                    os.lseek(pfd, 0, os.SEEK_END)
                    assert _landed_on_its_own_line(pfd, rec) is want, tail
                    # A claim longer than the file is a truncation, never a pass...
                    assert not _landed_on_its_own_line(pfd, tail.encode() + rec + b"x")
                    # ...and so is a log emptied AFTER the write, which leaves our
                    # offset intact and once reported a record that no longer existed.
                    os.truncate("probe", 0)
                    assert not _landed_on_its_own_line(pfd, rec)
                finally:
                    os.close(pfd)
            os.remove("probe")

            # A descriptor outlives its directory entry, so the entry is compared to the
            # fd. Same inode accepts; an unlink, and a replacement dropped on the name,
            # both refuse -- a record durable only in an orphaned inode is not a record.
            os.mkdir("ent")
            efd = os.open("ent", os.O_RDONLY | os.O_DIRECTORY)
            try:
                lfd = os.open("bypass-log.jsonl", os.O_RDWR | os.O_CREAT, 0o644,
                              dir_fd=efd)
                try:
                    assert _still_the_named_log(lfd, efd)
                    with open("ent/other", "w") as fh:
                        fh.write("{}\n")
                    os.replace("other", "bypass-log.jsonl", src_dir_fd=efd,
                               dst_dir_fd=efd)
                    assert not _still_the_named_log(lfd, efd)
                    os.unlink("bypass-log.jsonl", dir_fd=efd)
                    assert not _still_the_named_log(lfd, efd)
                finally:
                    os.close(lfd)
            finally:
                os.close(efd)

            # A directory descriptor outlives its own entry too, so the state dir is
            # re-resolved from the CWD anchor and compared. Renaming the FINAL component
            # and renaming an INTERMEDIATE one are separate escapes; both must refuse,
            # or the slot and its record land in a detached tree where every other check
            # in this file passes while a reader sees an empty ledger.
            for depth in ("st", "outer/st"):
                sfd = open_state_dir(depth)
                try:
                    assert state_dir_unchanged(sfd, depth)
                    head = depth.split("/")[0]
                    os.rename(head, head + "-detached")
                    # The probe re-creates whatever the rename removed, which is exactly
                    # the attack: the NAME resolves again, to an inode the held fd is
                    # not open on. That mismatch is what has to refuse.
                    assert not state_dir_unchanged(sfd, depth)
                finally:
                    os.close(sfd)

            # A symlinked log must refuse (a plain >> would happily "succeed").
            os.mkdir("s")
            os.symlink("/dev/null", "s/bypass-log.jsonl")
            assert not append("s", '{"a":4}')

            # A symlinked INTERMEDIATE component must refuse too.
            os.mkdir("real")
            os.symlink("real", "link")
            assert not append("link/inner", '{"a":5}')

            # Parent traversal is a separate escape from symlinks; O_NOFOLLOW does not
            # cover it, so it is rejected explicitly.
            assert not append("../outside", '{"a":6}')
            assert not append("a/../../outside", '{"a":7}')
            assert not append("/tmp/outside", '{"a":8}')
            assert not os.path.exists(os.path.join("..", "outside"))
        finally:
            os.chdir(cwd)
    print("audit_append self-check OK")


if __name__ == "__main__":
    # THERE IS NO WRITING CLI, deliberately. This module is imported by lease_slot.py,
    # which mints the audit event in the same call that creates the slot. A CLI that
    # wrote a record — even one built from fixed fields, taking only integers — let any
    # caller reaching it forge a `skip-review-consumed` line with no lease behind it,
    # and post-commit-consume-marker.sh reads a recent one of those as proof that a
    # bypass was sanctioned, suppressing a genuine unreviewed-commit entry. The Bash
    # invocation detector in the gate would then have been the ONLY thing in the way,
    # which is exactly the guess-every-spelling arms race this design is trying to
    # leave. No entry point, nothing to guess.
    if len(sys.argv) == 2 and sys.argv[1] == "--self-check":
        _demo()
        raise SystemExit(0)
    sys.stderr.write("audit_append: library only; use --self-check\n")
    raise SystemExit(2)
