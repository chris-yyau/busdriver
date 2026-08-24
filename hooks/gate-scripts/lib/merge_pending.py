#!/usr/bin/env python3
"""Hardened merge-litmus-pending claim for native Git merge hooks (#622).

Imported by validate-staged-litmus-marker.sh. Uses audit_append.open_state_dir so
every state-dir component is opened with O_NOFOLLOW — shell redirects cannot follow
attacker-controlled symlinks out of the repository.
"""

import datetime
import json
import os
import stat
import subprocess
import sys

sys.path[:] = [p for p in sys.path if p not in ("", ".")]

from audit_append import append_at, open_state_dir, state_dir_unchanged  # noqa: E402
from skip_age import skip_file_too_young  # noqa: E402

PENDING = "merge-litmus-pending.local"
PENDING_TMP = "merge-litmus-pending.local.tmp"
MARKER = "litmus-passed.local"
REVIEWED = "reviewed-commits.local"
SKIP = "skip-litmus.local"
_BLOCK_COUNT = ".gate-block-count.local"


def _git(repo, *args):
    return subprocess.run(
        ["git", "-C", repo, *args],
        capture_output=True,
        text=True,
        check=False,
    )


def _staged_tree(repo):
    r = _git(repo, "write-tree")
    if r.returncode != 0:
        return None
    tree = r.stdout.strip()
    return tree if tree else None


def _head_tree(repo):
    r = _git(repo, "rev-parse", "HEAD^{tree}")
    if r.returncode != 0:
        return None
    tree = r.stdout.strip()
    return tree if tree else None


def _is_regular(dfd, name):
    try:
        st = os.stat(name, dir_fd=dfd, follow_symlinks=False)
    except OSError:
        return False
    return stat.S_ISREG(st.st_mode)


def _unlink_if_exists(dfd, name):
    try:
        st = os.lstat(name, dir_fd=dfd)
    except OSError:
        return True
    if not stat.S_ISREG(st.st_mode):
        return False
    try:
        os.unlink(name, dir_fd=dfd)
        return True
    except OSError:
        return False


def _in_repo(repo, fn):
    cwd = os.getcwd()
    try:
        os.chdir(repo)
        return fn()
    finally:
        os.chdir(cwd)


def _write_claim_body(dfd, state_dir, claim_head, marker_content, staged_tree):
    body = "\n".join([claim_head, marker_content, staged_tree]) + "\n"
    data = body.encode("utf-8")
    existing = _read_claim(dfd)
    if existing is not None:
        if existing != (claim_head, marker_content, staged_tree):
            _unlink_marker(dfd)
            _unlink_if_exists(dfd, PENDING)
            return False
        return state_dir_unchanged(dfd, state_dir)
    _unlink_if_exists(dfd, PENDING_TMP)
    try:
        fd = os.open(
            PENDING_TMP,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o644,
            dir_fd=dfd,
        )
    except OSError:
        return False
    try:
        off = 0
        while off < len(data):
            off += os.write(fd, data[off:])
        os.fsync(fd)
    except OSError:
        return False
    finally:
        os.close(fd)
    try:
        os.replace(PENDING_TMP, PENDING, src_dir_fd=dfd, dst_dir_fd=dfd)
    except OSError:
        _unlink_if_exists(dfd, PENDING_TMP)
        return False
    try:
        os.fsync(dfd)
    except OSError:
        return False
    return state_dir_unchanged(dfd, state_dir)


def write_claim(repo, state_dir, claim_head, marker_content):
    """Persist claim_head, marker, and the authorized staged tree (git write-tree)."""

    def _write():
        staged_tree = _staged_tree(".")
        if not staged_tree:
            return False
        dfd = open_state_dir(state_dir)
        if dfd is None:
            return False
        try:
            return _write_claim_body(dfd, state_dir, claim_head, marker_content, staged_tree)
        finally:
            os.close(dfd)

    return _in_repo(repo, _write)


def authorize_operator_skip(repo, state_dir, gate_name, claim_head, marker_content):
    """Consume skip-litmus.local and write audit + pending claim without shell redirects."""

    def _authorize():
        dfd = open_state_dir(state_dir)
        if dfd is None:
            return False
        try:
            if skip_file_too_young(dfd, SKIP):
                return False
            if not _unlink_if_exists(dfd, SKIP):
                return False
            _unlink_if_exists(dfd, _BLOCK_COUNT)
            ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            record = {"ts": ts, "event": "skip-review-consumed", "gate": gate_name}
            if not append_at(dfd, json.dumps(record, separators=(",", ":"))):
                return False
            if not state_dir_unchanged(dfd, state_dir):
                return False
            staged_tree = _staged_tree(".")
            if not staged_tree:
                return False
            return _write_claim_body(dfd, state_dir, claim_head, marker_content, staged_tree)
        finally:
            os.close(dfd)

    return _in_repo(repo, _authorize)


def _unlink_marker(dfd):
    return _unlink_if_exists(dfd, MARKER)


def read_marker_content(repo, state_dir):
    def _read():
        dfd = open_state_dir(state_dir)
        if dfd is None:
            return None
        try:
            return _read_marker_line(dfd)
        finally:
            os.close(dfd)

    return _in_repo(repo, _read)


def unlink_marker(repo, state_dir):
    def _unlink():
        dfd = open_state_dir(state_dir)
        if dfd is None:
            return False
        try:
            return _unlink_if_exists(dfd, MARKER)
        finally:
            os.close(dfd)

    return _in_repo(repo, _unlink)


def clear_claim_repo(repo, state_dir):
    return _in_repo(repo, lambda: clear_claim(state_dir))


def clear_claim(state_dir):
    """Remove pending claim files without creating a state directory."""
    if state_dir.startswith("/") or ".." in state_dir.split("/"):
        return False
    parts = [p for p in state_dir.split("/") if p and p != "."]
    if not parts:
        return False
    dfd = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in parts:
            try:
                nfd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dfd)
            except OSError:
                return True
            os.close(dfd)
            dfd = nfd
        return _unlink_if_exists(dfd, PENDING_TMP) and _unlink_if_exists(dfd, PENDING)
    finally:
        os.close(dfd)


def _head_parents(repo):
    r = _git(repo, "log", "-1", "--format=%H %P")
    if r.returncode != 0:
        return None, []
    parts = r.stdout.strip().split()
    if not parts:
        return None, []
    return parts[0], parts[1:]


def _head_matches_claim(repo, claim_head, staged_tree):
    head, parents = _head_parents(repo)
    if head is None or len(parents) < 2:
        return False
    if parents[0] != claim_head:
        return False
    tree = _head_tree(repo)
    return tree is not None and tree == staged_tree


def _read_claim(dfd):
    if not _is_regular(dfd, PENDING):
        return None
    try:
        fd = os.open(PENDING, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dfd)
    except OSError:
        return None
    try:
        raw = os.read(fd, 65536)
    finally:
        os.close(fd)
    lines = raw.decode("utf-8", errors="replace").splitlines()
    if len(lines) < 3:
        return None
    return lines[0], lines[1], lines[2]


def _read_marker_line(dfd):
    if not _is_regular(dfd, MARKER):
        return None
    try:
        fd = os.open(MARKER, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dfd)
    except OSError:
        return None
    try:
        raw = os.read(fd, 4096)
    finally:
        os.close(fd)
    lines = raw.decode("utf-8", errors="replace").splitlines()
    if len(lines) != 1:
        return None
    line = lines[0].strip()
    return line if line else None


def _append_reviewed(dfd, line):
    try:
        fd = os.open(
            REVIEWED,
            os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW,
            0o644,
            dir_fd=dfd,
        )
    except OSError:
        return False
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return False
        data = (line + "\n").encode("utf-8")
        if os.write(fd, data) != len(data):
            return False
        os.fsync(fd)
        return True
    except OSError:
        return False
    finally:
        os.close(fd)


def consume_if_pending(repo, state_dir, gate_name):
    """Consume marker only when HEAD is the merge commit authorized by the claim."""

    def _consume():
        dfd = open_state_dir(state_dir)
        if dfd is None:
            return False
        try:
            claim = _read_claim(dfd)
            if claim is None:
                return True
            claim_head, claim_marker, staged_tree = claim

            if not _head_matches_claim(".", claim_head, staged_tree):
                _unlink_if_exists(dfd, PENDING)
                _unlink_marker(dfd)
                return True

            marker_content = _read_marker_line(dfd)
            if marker_content is None:
                marker_content = claim_marker or ""
            if not marker_content:
                return True
            if claim_marker and marker_content != claim_marker:
                _unlink_if_exists(dfd, PENDING)
                _unlink_marker(dfd)
                return True

            ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            commit_sha = _git(".", "rev-parse", "HEAD").stdout.strip() or "unknown"
            if marker_content.startswith("SKIPPED-NONE") or marker_content.startswith("SKIPPED-OPERATOR"):
                record = {
                    "ts": ts,
                    "event": "review-skipped-none",
                    "gate": gate_name,
                    "sha": commit_sha,
                    "pre_head": claim_head,
                }
                if not append_at(dfd, json.dumps(record, separators=(",", ":"))):
                    return False
            elif marker_content.startswith("BUILTIN-"):
                record = {
                    "ts": ts,
                    "event": "builtin-review-accepted",
                    "gate": gate_name,
                    "sha": commit_sha,
                    "pre_head": claim_head,
                }
                if not append_at(dfd, json.dumps(record, separators=(",", ":"))):
                    return False
            elif len(marker_content) == 64 and all(c in "0123456789abcdef" for c in marker_content):
                branch = _git(".", "symbolic-ref", "--short", "HEAD").stdout.strip()
                if branch and commit_sha:
                    if not _append_reviewed(dfd, f"{branch}:{commit_sha}"):
                        return False

            if not _unlink_marker(dfd):
                return False

            if not _unlink_if_exists(dfd, PENDING):
                return False

            _unlink_if_exists(dfd, _BLOCK_COUNT)
            return state_dir_unchanged(dfd, state_dir)
        finally:
            os.close(dfd)

    return _in_repo(repo, _consume)


def _demo():
    import tempfile

    cwd = os.getcwd()
    with tempfile.TemporaryDirectory() as t:
        os.chdir(t)
        try:
            os.makedirs(".claude", exist_ok=True)
            subprocess.run(["git", "init", "-q"], check=True)
            subprocess.run(["git", "config", "user.email", "t@t.dev"], check=True)
            subprocess.run(["git", "config", "user.name", "t"], check=True)
            open("a", "w", encoding="utf-8").write("a\n")
            subprocess.run(["git", "add", "a"], check=True)
            subprocess.run(["git", "commit", "-qm", "a", "--no-verify"], check=True)
            subprocess.run(["git", "checkout", "-qb", "topic"], check=True)
            open("b", "w", encoding="utf-8").write("b\n")
            subprocess.run(["git", "add", "b"], check=True)
            subprocess.run(["git", "commit", "-qm", "b", "--no-verify"], check=True)
            subprocess.run(["git", "checkout", "-q", "main"], check=True)
            open("c", "w", encoding="utf-8").write("c\n")
            subprocess.run(["git", "add", "c"], check=True)
            subprocess.run(["git", "commit", "-qm", "c", "--no-verify"], check=True)
            pre_merge_head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
            subprocess.run(["git", "merge", "--no-commit", "topic"], check=True)
            assert write_claim(t, ".claude", pre_merge_head, "BUILTIN-deadbeef")
            with open(".claude/litmus-passed.local", "w", encoding="utf-8") as fh:
                fh.write("BUILTIN-deadbeef\n")
            subprocess.run(["git", "commit", "-qm", "merge", "--no-verify"], check=True)
            assert consume_if_pending(t, ".claude", "demo")
            assert not os.path.exists(".claude/litmus-passed.local")
            subprocess.run(["git", "reset", "--hard", "HEAD~1"], check=True)
            pre_abort_head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
            subprocess.run(["git", "merge", "--no-commit", "topic"], check=True)
            assert write_claim(t, ".claude", pre_abort_head, "BUILTIN-cafe")
            with open(".claude/litmus-passed.local", "w", encoding="utf-8") as fh:
                fh.write("BUILTIN-cafe\n")
            subprocess.run(["git", "merge", "--abort"], check=True)
            open("d", "w", encoding="utf-8").write("d\n")
            subprocess.run(["git", "add", "d"], check=True)
            subprocess.run(["git", "commit", "-qm", "plain", "--no-verify"], check=True)
            assert consume_if_pending(t, ".claude", "demo")
            assert not os.path.exists(".claude/litmus-passed.local")
            os.symlink("/dev/null", ".claude/merge-litmus-pending.local.tmp")
            assert not write_claim(t, ".claude", pre_abort_head, "x")
        finally:
            os.chdir(cwd)
    print("merge_pending self-check OK")


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--self-check":
        _demo()
        raise SystemExit(0)
    raise SystemExit(2)
