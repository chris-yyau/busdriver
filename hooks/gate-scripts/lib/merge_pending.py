#!/usr/bin/env python3
"""Hardened merge-litmus-pending claim for native Git merge hooks (#622)."""

import datetime
import errno
import hashlib
import json
import os
import secrets
import stat
import subprocess
import sys

sys.path[:] = [p for p in sys.path if p not in ("", ".")]

from audit_append import append_at, open_state_dir, state_dir_unchanged  # noqa: E402
from skip_age import skip_file_too_young  # noqa: E402

PENDING = "merge-litmus-pending.local"
PENDING_TMP = "merge-litmus-pending.local.tmp"
ARMED = "merge-litmus-armed.local"  # legacy state-dir name; cleared on cleanup
ARMED_GIT = "busdriver-merge-litmus-armed"
SPENT_GIT = "busdriver-merge-litmus-spent"
MARKER = "litmus-passed.local"
REVIEWED = "reviewed-commits.local"
SKIP = "skip-litmus.local"
_BLOCK_COUNT = ".gate-block-count.local"

def _git(repo, *args):
    return subprocess.run(
        ["git", "--no-replace-objects", "-C", repo, *args],
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
    except OSError as exc:
        if exc.errno == errno.ENOENT:
            return True
        return False
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

def _is_commit_oid(value):
    if not value or len(value) not in (40, 64):
        return False
    try:
        int(value, 16)
    except ValueError:
        return False
    return True

def _peel_commit_oid(repo, value):
    """Return the commit OID for a commit/tag OID, or None if unpeelable."""
    if not value:
        return None
    r = _git(repo, "rev-parse", "--verify", f"{value}^{{commit}}")
    if r.returncode != 0:
        return None
    sha = r.stdout.strip()
    return sha if _is_commit_oid(sha) else None

def _merge_head_path(repo):
    path = _git(repo, "rev-parse", "--git-path", "MERGE_HEAD")
    if path.returncode != 0 or not path.stdout.strip():
        return None
    return path.stdout.strip()

def _merge_heads(repo):
    """Peeled MERGE_HEAD parents.

    Returns:
      list: peeled commit OIDs (possibly empty when MERGE_HEAD is absent/unbound)
      None: I/O or peel failure — callers must fail closed, not treat as unbound
    """
    merge_file = _merge_head_path(repo)
    if merge_file is None:
        return None
    if os.path.isfile(merge_file):
        try:
            with open(merge_file, encoding="utf-8") as fh:
                raw_heads = [line.strip() for line in fh if line.strip()]
        except OSError:
            return None
        if not raw_heads:
            return []
        heads = []
        for raw in raw_heads:
            peeled = _peel_commit_oid(repo, raw)
            if peeled is None:
                return None
            heads.append(peeled)
        return heads
    env_head = os.environ.get("BUSDRIVER_MERGE_HEAD", "").strip()
    if env_head:
        peeled = _peel_commit_oid(repo, env_head)
        return [peeled] if peeled else None
    r = _git(repo, "rev-parse", "--verify", "MERGE_HEAD^{commit}")
    if r.returncode != 0:
        return []
    sha = r.stdout.strip()
    return [sha] if _is_commit_oid(sha) else None

def _absent_claim_should_rollback(repo, gate_name, armed):
    """Roll back only when a protected .git arm shows authorization was in flight.

    Absent/malformed claims without that arm must not rewind HEAD: that shape is
    shared by fast-forwards onto merge commits and by `commit --amend` of an
    existing merge. `--no-verify` bypasses are outside hook reach either way.
    """
    del repo, gate_name
    return bool(armed)

def _serialize_merge_heads(heads):
    return json.dumps(heads, separators=(",", ":"))

def _parse_merge_heads(raw):
    if not raw:
        return []
    try:
        heads = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if not isinstance(heads, list):
        return None
    parsed = []
    for head in heads:
        if not isinstance(head, str) or not _is_commit_oid(head):
            return None
        parsed.append(head)
    return parsed

def _write_claim_body(
    dfd, state_dir, claim_head, marker_content, staged_tree, merge_heads=None, *, allow_unbound_upgrade=False
):
    merge_heads = merge_heads or []
    prior_payload = None
    merge_json = _serialize_merge_heads(merge_heads)
    body = "\n".join([claim_head, marker_content, staged_tree, merge_json]) + "\n"
    data = body.encode("utf-8")
    existing = _read_claim(dfd)
    if existing is False:
        return False
    if existing is not None:
        ex_head, ex_marker, ex_tree, ex_merge = existing
        if (ex_head, ex_marker) != (claim_head, marker_content):
            if not _retire_claim(dfd):
                return False
            return False
        if ex_tree == staged_tree and ex_merge == merge_heads:
            if ex_merge or merge_heads:
                payload = _claim_arm_payload(
                    claim_head, marker_content, staged_tree, merge_heads
                )
                # Idempotent refresh only — never mint an arm from a re-written claim.
                return _is_armed(".", payload) and state_dir_unchanged(dfd, state_dir)
            if not _retire_claim(dfd):
                return False
            return False
        elif not ex_merge and merge_heads and ex_tree == staged_tree:
            if allow_unbound_upgrade:
                unbound_payload = _claim_arm_payload(
                    claim_head, marker_content, staged_tree, []
                )
                if not _is_armed(".", unbound_payload):
                    if not _retire_claim(dfd):
                        return False
                    return False
                prior_payload = unbound_payload
                # Keep PENDING until os.replace below so a failed rewrite cannot
                # orphan the live unbound arm.
            else:
                if not _retire_claim(dfd):
                    return False
                return False
        elif not ex_merge and not merge_heads:
            if not _retire_claim(dfd):
                return False
            return False
        else:
            if not _retire_claim(dfd):
                return False
            return False
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
        _unlink_if_exists(dfd, PENDING_TMP)
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
        if not _retire_claim(dfd):
            return False
        return False
    if not state_dir_unchanged(dfd, state_dir):
        if not _retire_claim(dfd):
            return False
        return False
    if not _arm_merge(
        ".",
        claim_head,
        _claim_arm_payload(claim_head, marker_content, staged_tree, merge_heads),
        prior_payload=prior_payload,
    ):
        if not _retire_claim(dfd):
            return False
        return False
    return True

def _retire_claim(dfd):
    """Disarm first, then drop claim/marker. Fail closed if disarm fails."""
    if not _disarm_merge("."):
        return False
    ok = _unlink_marker(dfd)
    ok = _unlink_if_exists(dfd, PENDING) and ok
    ok = _unlink_if_exists(dfd, ARMED) and ok
    return ok

def _claim_arm_payload(claim_head, marker_content, staged_tree, merge_heads):
    body = "\n".join(
        [
            claim_head,
            marker_content,
            staged_tree,
            _serialize_merge_heads(merge_heads or []),
        ]
    ) + "\n"
    return hashlib.sha256(body.encode("utf-8")).hexdigest()

def _armed_path(repo):
    r = _git(repo, "rev-parse", "--git-path", ARMED_GIT)
    if r.returncode != 0 or not r.stdout.strip():
        return None
    return r.stdout.strip()

def _head_branch_ref(repo):
    r = _git(repo, "symbolic-ref", "-q", "HEAD")
    ref = r.stdout.strip() if r.returncode == 0 else ""
    return ref if ref.startswith("refs/heads/") else None

def _read_arm_record(repo):
    """Return (authorized_claim_head, digest, target_ref) from the protected .git arm."""
    path = _armed_path(repo)
    if not path:
        return None
    try:
        st = os.lstat(path)
    except OSError:
        return None
    if not stat.S_ISREG(st.st_mode) or st.st_size > 4096:
        return None
    try:
        with open(path, "rb") as fh:
            lines = fh.read().decode("utf-8", errors="replace").splitlines()
    except OSError:
        return None
    if len(lines) != 3:
        return None
    claim_head, digest, target = lines[0].strip(), lines[1].strip(), lines[2].strip()
    if not _is_commit_oid(claim_head) or len(digest) != 64:
        return None
    if not target.startswith("refs/heads/"):
        return None
    try:
        int(digest, 16)
    except ValueError:
        return None
    return claim_head, digest, target

def _read_arm_payload(repo):
    rec = _read_arm_record(repo)
    return None if rec is None else rec[1]

def _is_armed(repo, expected_payload=None):
    rec = _read_arm_record(repo)
    if rec is None:
        return False
    if expected_payload is None:
        return True
    return rec[1] == expected_payload

def _disarm_merge(repo):
    ok = True
    for name in (ARMED_GIT, SPENT_GIT):
        r = _git(repo, "rev-parse", "--git-path", name)
        if r.returncode != 0 or not r.stdout.strip():
            return False
        path = r.stdout.strip()
        try:
            st = os.lstat(path)
        except OSError as exc:
            if exc.errno != errno.ENOENT:
                ok = False
            continue
        if not stat.S_ISREG(st.st_mode):
            ok = False
            continue
        try:
            os.unlink(path)
        except OSError:
            ok = False
    return ok

def _read_spent_oid(repo):
    r = _git(repo, "rev-parse", "--git-path", SPENT_GIT)
    if r.returncode != 0 or not r.stdout.strip():
        return None
    try:
        with open(r.stdout.strip(), "r", encoding="utf-8") as fh:
            oid = fh.read().strip()
    except OSError:
        return None
    return oid if _is_commit_oid(oid) else None

def _arm_merge(repo, claim_head, payload, *, prior_payload=None):
    """Arm merge authorization under .git/, bound to claim_head + claim digest."""
    if not _is_commit_oid(claim_head):
        return False
    if not payload or len(payload) != 64:
        return False
    try:
        int(payload, 16)
    except ValueError:
        return False
    path = _armed_path(repo)
    if not path:
        return False
    target = _head_branch_ref(repo)
    if not target:
        return False
    parent = os.path.dirname(path) or "."
    name = os.path.basename(path)
    try:
        pfd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
    except OSError:
        return False
    try:
        try:
            fd = os.open(
                name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o644,
                dir_fd=pfd,
            )
        except OSError:
            rec = _read_arm_record(repo)
            if rec and rec[0] == claim_head and rec[1] == payload and rec[2] == target:
                return True
            if (
                prior_payload
                and rec
                and rec[0] == claim_head
                and rec[1] == prior_payload
                and rec[2] == target
                and _disarm_merge(repo)
            ):
                return _arm_merge(repo, claim_head, payload)
            return False
        try:
            data = f"{claim_head}\n{payload}\n{target}\n".encode("utf-8")
            if os.write(fd, data) != len(data):
                raise OSError("short write")
            os.fsync(fd)
        except OSError:
            os.close(fd)
            try: os.unlink(name, dir_fd=pfd)
            except OSError: pass
            return False
        os.close(fd)
        try:
            os.fsync(pfd)
            return True
        except OSError:
            try: os.unlink(name, dir_fd=pfd)
            except OSError: pass
            return False
    finally:
        os.close(pfd)

def write_claim(repo, state_dir, claim_head, marker_content):
    """Persist claim_head, marker, and the authorized staged tree (git write-tree)."""

    def _write():
        staged_tree = _staged_tree(".")
        if not staged_tree:
            return False
        merge_heads = _merge_heads(".")
        if merge_heads is None:
            return False
        dfd = open_state_dir(state_dir)
        if dfd is None:
            return False
        try:
            return _write_claim_body(
                dfd, state_dir, claim_head, marker_content, staged_tree, merge_heads
            )
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
            staged_tree = _staged_tree(".")
            if not staged_tree:
                return False
            merge_heads = _merge_heads(".")
            if merge_heads is None:
                return False
            consume_id = secrets.token_hex(16)
            started = {
                "ts": datetime.datetime.now(datetime.timezone.utc).strftime(
                    "%Y-%m-%dT%H:%M:%SZ"
                ),
                "event": "skip-review-consume-started",
                "gate": gate_name,
                "consume_id": consume_id,
                "pre_head": claim_head,
                "tree": staged_tree,
            }
            if not append_at(dfd, json.dumps(started, separators=(",", ":"))):
                return False
            if not _write_claim_body(
                dfd, state_dir, claim_head, marker_content, staged_tree, merge_heads
            ):
                return False
            completed = dict(started)
            completed["ts"] = datetime.datetime.now(datetime.timezone.utc).strftime(
                "%Y-%m-%dT%H:%M:%SZ"
            )
            completed["event"] = "skip-review-consumed"
            if not append_at(dfd, json.dumps(completed, separators=(",", ":"))):
                if not _retire_claim(dfd):
                    return False
                return False
            if not state_dir_unchanged(dfd, state_dir):
                if not _retire_claim(dfd):
                    return False
                return False
            return True
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
                return _disarm_merge(".")
            os.close(dfd)
            dfd = nfd
        if not _disarm_merge("."):
            return False
        ok = _unlink_if_exists(dfd, PENDING_TMP)
        ok = _unlink_if_exists(dfd, PENDING) and ok
        ok = _unlink_if_exists(dfd, ARMED) and ok
        return ok
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

def _head_matches_claim(repo, claim_head, staged_tree, merge_heads=None):
    head, parents = _head_parents(repo)
    if head is None or len(parents) < 2:
        return False
    if parents[0] != claim_head:
        return False
    merge_heads = merge_heads or []
    # Require prepare-commit-msg binding: empty merge_heads is not authorizing.
    if not merge_heads or parents[1:] != merge_heads:
        return False
    tree = _head_tree(repo)
    return tree is not None and tree == staged_tree

def bind_pending_merge_heads(repo, state_dir):
    """prepare-commit-msg: bind MERGE_HEAD after Git creates it."""

    def _bind():
        dfd = open_state_dir(state_dir)
        if dfd is None:
            return False
        try:
            claim = _read_claim(dfd)
            if claim is None:
                heads = _merge_heads(".")
                if heads is None:
                    return False
                return heads == []
            if claim is False:
                return False
            claim_head, claim_marker, staged_tree, merge_heads = claim
            if merge_heads:
                payload = _claim_arm_payload(
                    claim_head, claim_marker, staged_tree, merge_heads
                )
                if not _is_armed(".", payload):
                    return False
                arm_rec = _read_arm_record(".")
                target = _head_branch_ref(".")
                if not arm_rec or not target or arm_rec[2] != target:
                    return False
                head = _git(".", "rev-parse", "HEAD").stdout.strip()
                if not head or head != claim_head:
                    return False
                current_tree = _staged_tree(".")
                if current_tree is None or current_tree != staged_tree:
                    return False
                current_heads = _merge_heads(".")
                if not current_heads or current_heads != merge_heads:
                    return False
                return True
            head = _git(".", "rev-parse", "HEAD").stdout.strip()
            if not head or head != claim_head:
                return False
            current_tree = _staged_tree(".")
            if current_tree is None or current_tree != staged_tree:
                return False
            current_heads = _merge_heads(".")
            if not current_heads:
                return False
            return _write_claim_body(
                dfd,
                state_dir,
                claim_head,
                claim_marker,
                staged_tree,
                current_heads,
                allow_unbound_upgrade=True,
            )
        finally:
            os.close(dfd)

    return _in_repo(repo, _bind)

def _unlink_git_state(repo, name):
    r = _git(repo, "rev-parse", "--git-path", name)
    if r.returncode != 0 or not r.stdout.strip():
        return False
    path = r.stdout.strip()
    try:
        st = os.lstat(path)
    except OSError as exc:
        return exc.errno == errno.ENOENT
    if not stat.S_ISREG(st.st_mode):
        return False
    try:
        os.unlink(path)
        return True
    except OSError:
        return False

def _finish_published_cleanup(dfd, repo, state_dir):
    if not _unlink_git_state(repo, ARMED_GIT):
        return False
    ok = _unlink_marker(dfd)
    ok = _unlink_if_exists(dfd, PENDING) and ok
    ok = _unlink_if_exists(dfd, ARMED) and ok
    ok = _unlink_if_exists(dfd, _BLOCK_COUNT) and ok
    if not ok:
        return False
    if not _unlink_git_state(repo, SPENT_GIT):
        return False
    return state_dir_unchanged(dfd, state_dir)

def _rollback_merge(repo, head, parents, restore_to=None, *, target_ref=None):
    """Rewind unauthorized merge tip on the arm's target branch only."""
    if head is None or len(parents) < 2:
        return True
    target = restore_to or parents[0]
    if not _is_commit_oid(target):
        return False
    if parents[0] != target:
        print("Busdriver: CRITICAL: unauthorized merge remains at HEAD.", file=sys.stderr)
        return False
    cur = _head_branch_ref(repo)
    if target_ref is not None:
        if not cur or cur != target_ref:
            return True
        ref = target_ref
    else:
        if not cur:
            return True
        ref = cur
    r = _git(
        repo,
        "-c",
        "core.hooksPath=/dev/null",
        "update-ref",
        "-m",
        "busdriver: reject unauthorized merge commit",
        ref,
        target,
        head,
    )
    if r.returncode == 0:
        print(
            "Busdriver: merge commit did not match its reviewed claim; "
            "HEAD was restored to the authorized pre-merge tip. "
            "The index and worktree were kept for retry.",
            file=sys.stderr,
        )
        return True
    print(
        "Busdriver: CRITICAL: unauthorized merge remains at HEAD; arm kept for retry.",
        file=sys.stderr,
    )
    return False

def _read_claim(dfd):
    try:
        st = os.lstat(PENDING, dir_fd=dfd)
    except OSError as exc:
        if exc.errno == errno.ENOENT:
            return None
        return False
    if not stat.S_ISREG(st.st_mode):
        return False
    try:
        fd = os.open(PENDING, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dfd)
    except OSError:
        return False
    try:
        raw = os.read(fd, 65536)
    finally:
        os.close(fd)
    lines = raw.decode("utf-8", errors="replace").splitlines()
    if len(lines) < 4:
        return False
    merge_raw = lines[3]
    merge_heads = _parse_merge_heads(merge_raw)
    if merge_heads is None:
        return False
    return lines[0], lines[1], lines[2], merge_heads

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
    """Keep only a merge commit whose immutable parents/tree match its claim."""

    def _consume():
        head, parents = _head_parents(".")
        if head is None:
            return False
        dfd = open_state_dir(state_dir)
        if dfd is None:
            arm_rec = _read_arm_record(".")
            armed = arm_rec is not None
            restore = arm_rec[0] if arm_rec else None
            target_ref = arm_rec[2] if arm_rec else None
            if _absent_claim_should_rollback(".", gate_name, armed):
                if not _rollback_merge(
                    ".", head, parents, restore, target_ref=target_ref
                ):
                    return False
            return _disarm_merge(".")
        try:
            claim = _read_claim(dfd)
            if claim is False:
                arm_rec = _read_arm_record(".")
                armed = arm_rec is not None
                restore = arm_rec[0] if arm_rec else None
                target_ref = arm_rec[2] if arm_rec else None
                if _absent_claim_should_rollback(".", gate_name, armed):
                    if not _rollback_merge(
                        ".", head, parents, restore, target_ref=target_ref
                    ):
                        return False
                return _retire_claim(dfd)
            if claim is None:
                arm_rec = _read_arm_record(".")
                armed = arm_rec is not None
                restore = arm_rec[0] if arm_rec else None
                target_ref = arm_rec[2] if arm_rec else None
                if _absent_claim_should_rollback(".", gate_name, armed):
                    if not _rollback_merge(
                        ".", head, parents, restore, target_ref=target_ref
                    ):
                        return False
                _unlink_if_exists(dfd, ARMED)
                return _disarm_merge(".")
            claim_head, claim_marker, staged_tree, merge_heads = claim
            payload = _claim_arm_payload(
                claim_head, claim_marker, staged_tree, merge_heads
            )
            arm_rec = _read_arm_record(".")
            if arm_rec is None:
                spent = _read_spent_oid(".")
                if spent and spent == head:
                    return _finish_published_cleanup(dfd, ".", state_dir)
                if (
                    len(parents) >= 2
                    and _is_commit_oid(claim_head)
                    and parents[0] == claim_head
                ):
                    if not _rollback_merge(
                        ".", head, parents, claim_head, target_ref=_head_branch_ref(".")
                    ):
                        return False
                return _retire_claim(dfd)
            arm_head, arm_payload, arm_target = arm_rec[0], arm_rec[1], arm_rec[2]
            cur_branch = _head_branch_ref(".")
            if not cur_branch or cur_branch != arm_target:
                return _retire_claim(dfd)
            if arm_payload != payload:
                if not _rollback_merge(
                    ".", head, parents, arm_head, target_ref=arm_target
                ):
                    return False
                return _retire_claim(dfd)
            if arm_head != claim_head:
                if not _rollback_merge(
                    ".", head, parents, arm_head, target_ref=arm_target
                ):
                    return False
                return _retire_claim(dfd)

            if not _head_matches_claim(".", claim_head, staged_tree, merge_heads):
                if not _rollback_merge(
                    ".", head, parents, arm_head, target_ref=arm_target
                ):
                    return False
                return _retire_claim(dfd)

            marker_content = _read_marker_line(dfd)
            if marker_content is None:
                marker_content = claim_marker or ""
            if not marker_content:
                return _retire_claim(dfd)
            if claim_marker and marker_content != claim_marker:
                return _retire_claim(dfd)

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

            if not _finish_published_cleanup(dfd, ".", state_dir):
                return False
            return True
        finally:
            os.close(dfd)

    return _in_repo(repo, _consume)

def _demo():
    assert _absent_claim_should_rollback(".", "post-merge", False) is False
    assert _absent_claim_should_rollback(".", "post-commit-merge", True) is True
    heads = ["a" * 40, "b" * 40]
    assert _parse_merge_heads(_serialize_merge_heads(heads)) == heads
    assert _parse_merge_heads("not-json") is None
    assert _claim_arm_payload("c" * 40, "BUILTIN-x", "d" * 40, heads)
    print("merge_pending self-check OK")


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--self-check":
        _demo()
        raise SystemExit(0)
    raise SystemExit(2)
