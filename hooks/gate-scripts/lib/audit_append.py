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


def append(state_dir, record_line):
    """Append record_line (no trailing newline) under <cwd>/<state_dir>/bypass-log.jsonl.
    Returns True only when the whole line is durably written."""
    dfd = open_state_dir(state_dir)
    if dfd is None:
        return False
    try:
        return append_at(dfd, record_line)
    finally:
        os.close(dfd)


def append_at(dfd, record_line):
    """append() against an ALREADY-VALIDATED state dir fd. Does not close dfd.

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
        return False              # symlinked log, or unwritable
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return False          # fifo/device posing as the log
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
            return False
        size = os.fstat(fd).st_size
        if size and os.pread(fd, 1, size - 1) != b"\n":
            return False          # pre-existing torn line — refuse, never repair
        data = (record_line + "\n").encode()
        if os.write(fd, data) != len(data):
            return False          # short write (storage exhausted)
        os.fsync(fd)
        # ...and the directory entry. fsync of a file persists its CONTENTS, never
        # its name, so a freshly created log could vanish on a crash and leave a
        # granted lease with no record. design-clear.sh fsyncs the parent for the
        # same reason.
        try:
            os.fsync(dfd)
        except OSError:
            return False
        return True
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
