#!/usr/bin/env python3
"""Token operations for the worktree-safe design-review marker (Task 2).

Invoked as a FILE (never `-c`) so sys.path[0] is this trusted lib/ dir, not CWD:
    python3 -S marker_ops.py <subcommand> [args...]

Subcommands
-----------
  sha <norm>
        Print sha256(norm) hexdigest. Used by the loop's prune glob.
  arm <marker_dir> <norm>
        ADR-D: create-only, no-clobber token `<sha(norm)>.<nonce>` whose body is
        exactly `norm` + one trailing LF. Never reads/dedups existing tokens
        (that read-before-write is the race). exit 0 = armed; 1 = best-effort miss.
  classify <marker_dir> <anchor> <state_dir>
        ADR-C: pure, EXISTENCE-keyed classifier + bounded legacy union. Emits one
        NUL-delimited record per pending finding as four NUL-TERMINATED fields
        (source_kind, source_path, doc_path, reason). Never mutates.
        exit 0 = nothing pending; 1 = >=1 pending (records on stdout);
        2 = enumerate/list failure (caller blocks fail-CLOSED).

The classifier NEVER opens the design doc for new tokens: a token's *existence*
is the pending signal (existence-keyed — kills the lost-rearm race by
construction). It opens only the token body to validate the hash for the message.
"""
import sys
# Defense-in-depth (§11 / matches pre-commit-gate.sh:78-80): drop CWD entries so a
# repo-planted hashlib.py / os.py / secrets.py cannot hijack the gate. `-S` already
# skips site and a FILE invocation already excludes CWD from sys.path[0]; this keeps
# parity with the vetted gates regardless of how python was launched.
sys.path[:] = [p for p in sys.path if p not in ("", ".")]

import os
import re
import hashlib

# Cap records emitted on the hot path (ADR-C: K = 20). The block decision needs
# only "any pending"; the records are for the operator-facing message.
K = 20

# A token filename is <64 lowercase-hex sha256>.<hex nonce>.
_TOKEN_RE = re.compile(r"([0-9a-f]{64})\.[0-9a-f]+\Z")
_PASS_MARKER = "<!-- design-reviewed: PASS -->"


def _sha(norm):
    # surrogateescape so a non-UTF-8 filesystem path round-trips deterministically
    # between arm (write) and classify (verify).
    return hashlib.sha256(norm.encode("utf-8", "surrogateescape")).hexdigest()


def cmd_sha(argv):
    if len(argv) != 1:
        return 2
    sys.stdout.write(_sha(argv[0]))
    return 0


def cmd_arm(argv):
    if len(argv) != 2:
        return 1
    marker_dir, norm = argv
    import secrets

    try:
        os.makedirs(marker_dir, exist_ok=True)
    except OSError:
        return 1  # §2 best-effort miss
    sha = _sha(norm)
    data = (norm + "\n").encode("utf-8", "surrogateescape")
    for _ in range(2):  # one retry on nonce collision
        nonce = secrets.token_hex(8)
        path = os.path.join(marker_dir, "{}.{}".format(sha, nonce))
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except FileExistsError:
            continue
        except OSError:
            return 1
        try:
            off = 0
            while off < len(data):  # os.write may short-write
                off += os.write(fd, data[off:])
        except OSError:
            return 1
        finally:
            os.close(fd)
        return 0
    return 1


class _Emitter:
    """Streams NUL-terminated fields, four per pending record, capped at K."""

    def __init__(self):
        self.pending = False
        self._n = 0
        self._w = sys.stdout.buffer

    def add(self, kind, source_path, doc_path, reason):
        self.pending = True
        if self._n >= K:
            return
        for field in (kind, source_path, doc_path, reason):
            self._w.write(field.encode("utf-8", "surrogateescape"))
            self._w.write(b"\0")
        self._n += 1


def _worktree_roots(anchor):
    """All worktree roots for anchor's repo (main + linked), + the toplevel.

    Returns a de-duplicated list, or None on enumeration failure (=> exit 2).
    `git worktree list` from any worktree lists them all; the toplevel is added
    defensively per Decision-D3. NUL I/O (--porcelain -z): worktree paths may
    contain newlines.
    """
    import subprocess

    roots = []
    try:
        top = subprocess.run(
            ["git", "-C", anchor, "rev-parse", "--show-toplevel"],
            capture_output=True,
        )
        if top.returncode == 0:
            t = top.stdout.decode("utf-8", "surrogateescape").strip()
            if t:
                roots.append(t)
    except Exception:
        return None
    try:
        wl = subprocess.run(
            ["git", "-C", anchor, "worktree", "list", "--porcelain", "-z"],
            capture_output=True,
        )
        if wl.returncode != 0:
            return None
        data = wl.stdout.decode("utf-8", "surrogateescape")
        for field in data.split("\0"):
            if field.startswith("worktree "):
                roots.append(field[len("worktree "):])
    except Exception:
        return None
    seen, uniq = set(), []
    for r in roots:
        try:
            key = os.path.realpath(r)
        except OSError:
            key = r
        if key not in seen:
            seen.add(key)
            uniq.append(r)
    return uniq


def _classify_tokens(marker_dir, em):
    """Existence-keyed scan of the token directory. Returns False on a hard
    list failure of an EXISTING dir (=> exit 2); True otherwise. An absent dir
    (ENOENT) is zero tokens, not an error."""
    try:
        names = os.listdir(marker_dir)
    except FileNotFoundError:
        # A genuinely absent dir is zero tokens (fine). A DANGLING symlink at
        # marker_dir also raises FileNotFoundError but is anomalous marker state
        # (tampering) — fail-CLOSED (exit 2), never "empty".
        return not os.path.lexists(marker_dir)
    except OSError:
        return False  # existing dir we cannot list -> cannot build the set
    for name in names:
        tok = os.path.join(marker_dir, name)
        m = _TOKEN_RE.match(name)
        if not m:
            em.add("token", tok, "", "unparseable")  # stray file, fail-closed
            continue
        try:
            with open(tok, "rb") as fh:
                raw = fh.read()
        except FileNotFoundError:
            continue  # TOCTOU: unlinked between list and read -> gone, not unreadable
        except OSError:
            em.add("token", tok, "", "unreadable")
            continue
        body = raw[:-1] if raw.endswith(b"\n") else raw
        if b"\n" in body or b"\r" in body:  # exactly one trailing LF allowed
            em.add("token", tok, "", "unparseable")
            continue
        norm = body.decode("utf-8", "surrogateescape")
        if not norm.startswith("/") or _sha(norm) != m.group(1):
            em.add("token", tok, "", "unparseable")
            continue
        em.add("token", tok, norm, "token")  # valid: trusted doc_path for the message
    return True


def _classify_legacy(roots, state_dir, em):
    """Bounded per-worktree-root legacy union (PASS-keyed). No subtree walk."""
    for root in roots:
        m = os.path.join(root, state_dir, "design-review-needed.local.md")
        if not os.path.lexists(m):
            continue
        if not os.access(m, os.R_OK):
            em.add("legacy", m, "", "unreadable")  # exists but unreadable -> pending
            continue
        try:
            with open(m, "r", errors="surrogateescape") as fh:
                content = fh.read()
        except OSError:
            em.add("legacy", m, "", "unreadable")
            continue
        for line in content.splitlines():
            if not line.startswith("- "):
                continue
            entry = line[2:].strip()
            if not entry:
                continue
            doc = entry if entry.startswith("/") else os.path.join(root, entry)
            reviewed = False
            try:
                with open(doc, "r", errors="surrogateescape") as dfh:
                    reviewed = _PASS_MARKER in dfh.read()
            except OSError:
                reviewed = False  # absent / unreadable doc -> pending (fail-closed)
            if not reviewed:
                em.add("legacy", m, doc if os.path.isabs(doc) else "", "legacy-pending")


def cmd_classify(argv):
    if len(argv) != 3:
        return 2
    marker_dir, anchor, state_dir = argv
    roots = _worktree_roots(anchor)
    if roots is None:
        return 2  # git enumeration failure -> cannot build the set
    em = _Emitter()
    if not _classify_tokens(marker_dir, em):
        return 2  # existing token dir could not be listed
    _classify_legacy(roots, state_dir, em)
    return 1 if em.pending else 0


_DISPATCH = {"sha": cmd_sha, "arm": cmd_arm, "classify": cmd_classify}


def main(argv):
    if not argv:
        return 2
    fn = _DISPATCH.get(argv[0])
    if fn is None:
        return 2
    try:
        return fn(argv[1:])
    except Exception:
        return 2  # fail-CLOSED for the classifier; arm's caller treats 2 as a miss


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
