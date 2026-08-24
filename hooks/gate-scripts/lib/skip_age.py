"""Atomic skip-litmus.local age/provenance checks via dir-fd + fstat (#622).

The 30-second minimum age is an anti-self-bypass for the agent harness (which is
blocked from creating skip-litmus.local by pre-implementation-gate). Operator
consent via a user-created skip file after 30s is an intentional, audited escape
hatch — same contract as pre-commit-gate.sh.

Exit 0 = too young / invalid provenance (caller should block).
Exit 1 = age checks passed.
"""

import os
import stat
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from audit_append import open_state_dir

SKIP = "skip-litmus.local"
_MIN_AGE = 30


def _birth(st):
    return getattr(st, "st_birthtime", 0) or 0


def skip_file_too_young(dfd, name=SKIP):
    """Return True when skip file must be rejected (too young / bad provenance)."""

    try:
        fd = os.open(
            name,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
            dir_fd=dfd,
        )
    except OSError:
        return True
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return True
        parent_st = os.fstat(dfd)
        now = time.time()
        if st.st_nlink > 1:
            return True
        if now - st.st_mtime < _MIN_AGE:
            return True
        if now - st.st_ctime < _MIN_AGE:
            return True
        if now - parent_st.st_ctime < _MIN_AGE:
            return True
        birth = _birth(st)
        if birth:
            if now - birth < _MIN_AGE:
                return True
            parent_birth = _birth(parent_st)
            if parent_birth and birth < parent_birth:
                return True
        return False
    finally:
        os.close(fd)


def skip_litmus_too_young(state_dir=".claude"):
    dfd = open_state_dir(state_dir)
    if dfd is None:
        return True
    try:
        return skip_file_too_young(dfd, SKIP)
    finally:
        os.close(dfd)


def _self_check():
    import shutil
    import tempfile

    tmp = tempfile.mkdtemp()
    try:
        state = os.path.join(tmp, ".claude")
        os.makedirs(state, mode=0o755)
        skip = os.path.join(state, SKIP)
        with open(skip, "w", encoding="utf-8") as fh:
            fh.write("skip\n")
        os.chdir(tmp)
        if not skip_litmus_too_young(".claude"):
            print("fresh skip should be too young", file=sys.stderr)
            return 1
        time.sleep(31)
        if skip_litmus_too_young(".claude"):
            print("aged skip should pass age check", file=sys.stderr)
            return 1
        decoy = os.path.join(tmp, "decoy")
        with open(decoy, "w", encoding="utf-8") as fh:
            fh.write("old\n")
        old = time.time() - 120
        os.utime(decoy, (old, old))
        os.remove(skip)
        os.link(decoy, skip)
        if not skip_litmus_too_young(".claude"):
            print("hardlinked skip should be too young", file=sys.stderr)
            return 1
        print("skip_age self-check OK")
        return 0
    finally:
        os.chdir("/")
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--self-check":
        raise SystemExit(_self_check())
    state_dir = sys.argv[1] if len(sys.argv) > 1 else ".claude"
    raise SystemExit(0 if skip_litmus_too_young(state_dir) else 1)
