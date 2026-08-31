"""Atomic skip-litmus.local age/provenance checks (#622)."""
import os, stat, sys, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from audit_append import open_state_dir
SKIP = "skip-litmus.local"
_MIN_AGE = 30

def _birth(st):
    return getattr(st, "st_birthtime", 0) or 0

def _st_too_young(st, parent_st, now=None):
    if now is None:
        now = time.time()
    if not stat.S_ISREG(st.st_mode) or st.st_nlink > 1:
        return True
    if now - st.st_mtime < _MIN_AGE or now - st.st_ctime < _MIN_AGE:
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

def skip_file_too_young(dfd, name=SKIP):
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
    except OSError:
        return True
    try:
        return _st_too_young(os.fstat(fd), os.fstat(dfd))
    finally:
        os.close(fd)

def open_skip_for_authorization(dfd, name=SKIP):
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
    except OSError:
        return None
    try:
        if _st_too_young(os.fstat(fd), os.fstat(dfd)):
            os.close(fd)
            return None
        return fd
    except OSError:
        os.close(fd)
        return None

def finish_skip_consume(dfd, name, skip_fd):
    try:
        try:
            held = os.fstat(skip_fd)
            try:
                named = os.stat(name, dir_fd=dfd, follow_symlinks=False)
            except OSError:
                return False
            if not stat.S_ISREG(named.st_mode):
                return False
            if (named.st_ino, named.st_dev) != (held.st_ino, held.st_dev):
                return False
            os.unlink(name, dir_fd=dfd)
            return os.fstat(skip_fd).st_nlink == 0
        except OSError:
            return False
    finally:
        os.close(skip_fd)

def consume_skip_if_aged(dfd, name=SKIP):
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
    except OSError:
        return False
    try:
        if _st_too_young(os.fstat(fd), os.fstat(dfd)):
            os.close(fd)
            return False
        return finish_skip_consume(dfd, name, fd)
    except Exception:
        try:
            os.close(fd)
        except OSError:
            pass
        return False

def skip_litmus_too_young(state_dir=".claude"):
    dfd = open_state_dir(state_dir)
    if dfd is None:
        return True
    try:
        return skip_file_too_young(dfd, SKIP)
    finally:
        os.close(dfd)

def _self_check():
    import shutil, tempfile
    global _MIN_AGE
    tmp = tempfile.mkdtemp()
    saved = _MIN_AGE
    try:
        state = os.path.join(tmp, ".claude")
        os.makedirs(state, mode=0o755)
        skip = os.path.join(state, SKIP)
        open(skip, "w", encoding="utf-8").write("skip\n")
        os.chdir(tmp)
        if not skip_litmus_too_young(".claude"):
            return 1
        _MIN_AGE = 0
        if skip_litmus_too_young(".claude"):
            return 1
        decoy = os.path.join(tmp, "decoy")
        open(decoy, "w", encoding="utf-8").write("old\n")
        os.remove(skip)
        os.link(decoy, skip)
        _MIN_AGE = saved
        if not skip_litmus_too_young(".claude"):
            return 1
        os.remove(skip)
        open(skip, "w", encoding="utf-8").write("skip\n")
        _MIN_AGE = 0
        dfd = open_state_dir(".claude")
        if dfd is None:
            return 1
        fd = open_skip_for_authorization(dfd, SKIP)
        if fd is None:
            os.close(dfd)
            return 1
        os.remove(skip)
        open(skip, "w", encoding="utf-8").write("replaced\n")
        if finish_skip_consume(dfd, SKIP, fd):
            os.close(dfd)
            return 1
        fd = open_skip_for_authorization(dfd, SKIP)
        if fd is None or not finish_skip_consume(dfd, SKIP, fd):
            os.close(dfd)
            return 1
        os.close(dfd)
        print("skip_age self-check OK")
        return 0
    finally:
        _MIN_AGE = saved
        os.chdir("/")
        shutil.rmtree(tmp, ignore_errors=True)

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--self-check":
        raise SystemExit(_self_check())
    state_dir = sys.argv[1] if len(sys.argv) > 1 else ".claude"
    raise SystemExit(0 if skip_litmus_too_young(state_dir) else 1)
