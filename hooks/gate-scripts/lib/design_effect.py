#!/usr/bin/env python3
"""Arm the design-review gate on a Bash call's EFFECT, not its spelling (#921).

    python3 -I design_effect.py snap <libdir>   < PreToolUse payload
    python3 -I design_effect.py diff <libdir>   < PostToolUse / PostToolUseFailure payload

`snap` records, per repository root the call can touch, the pre-call HEAD and a body
hash of every dirty design document. `diff` recomputes the dirty set after the call and
arms a review token for every design document whose working-tree content the call
changed and that is not committed at HEAD or at a revision being brought in
(MERGE_HEAD, CHERRY_PICK_HEAD, REBASE_HEAD). Per-document work goes through the same
marker_ops functions the shell helpers delegate to, so classification, token format and
PASS handling cannot diverge from the Write/Edit path.

Non-blocking by design: warnings go to stderr and the process exits 0 once it has parsed
its input. Spec: docs/specs/2026-10-22-issue-921-design-gate-bash-effect-design.md.
"""
import sys

# -I implies -P, so this dir is NOT on sys.path; the caller passes it (BASH_SOURCE-derived).
sys.path[:] = [p for p in sys.path if p not in ("", ".")]

import hashlib
import json
import os
import re
import stat
import subprocess
import time

DEADLINE_S = 3.0
GIT_TIMEOUT_S = 1.5
PRUNE_AGE_S = 24 * 3600
# A larger doc is not normalized: its raw bytes are hashed in chunks under the deadline
# (`bighash:`), so memory stays bounded and any byte change arms (no downgrade).
MAX_BODY_BYTES = 4 * 1024 * 1024
MAX_BATCH_BYTES = 4 * MAX_BODY_BYTES  # one revision read; past it, a failed read
OVERSIZE = "oversize:"  # a revision blob past MAX_BODY_BYTES, never fetched
HEAD_UNKNOWN = "unknown"  # the pre-call HEAD lookup failed (not an unborn HEAD)
_START = time.monotonic()

_REV_DROPS = ("HEAD", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REBASE_HEAD")
# A marker line is dropped from the hash only when it holds nothing but the marker: the
# comment may not contain another `<!--` or `-->`, and nothing but blanks may follow it, so
# text added on a marker line still changes the hash. A coverage line may also be
# truncated (no `-->`), the shape the review loop repairs.
_MARKER_LINE_RE = re.compile(r"^[ \t]*<!-- design-reviewed:(?:(?!-->|<!--).)*-->[ \t]*$")
_COVERAGE_LINE_RE = re.compile(
    r"^[ \t]*<!-- design-review-coverage:(?:(?!-->|<!--).)*(?:-->[ \t]*)?$")
# The shell detector's exclusions, mirrored (check-design-document.sh).
_REVIEW_OUT_RE = re.compile(r"(reviews/|review-needed|review-state|review-agy|review-codex|"
                            r"review-claude|review-consensus|review-autofix|review-decisions)",
                            re.IGNORECASE)
_MEMORY_RE = re.compile(r"(memory/|lesson-)")
_STRUCTURAL_RE = re.compile(r"(^|/)(agents|commands|scripts|hooks|tests|src|lib|skills)/")
_DESIGN_RE = re.compile(r"(?:^|/)(?:PLAN|DESIGN|ARCHITECTURE)[^/]*\.md$", re.IGNORECASE)


# GIT_ALLOW_PROTOCOL overrides every protocol.* setting, including a repository's own
# `protocol.<name>.allow=always`, which beats a `-c protocol.allow=never` default; no
# protocol is named "none", so no transport (and no core.sshCommand) can start.
_GIT_ENV = dict(os.environ, GIT_NO_LAZY_FETCH="1", GIT_ALLOW_PROTOCOL="none")


class Deadline(Exception):
    pass


class GitError(Exception):
    def __init__(self, msg, rc=None):
        super().__init__(msg)
        self.rc = rc


def warn(msg):
    sys.stderr.write("WARNING: design-review effect check: " + msg + "\n")


def remaining():
    return DEADLINE_S - (time.monotonic() - _START)


def check_deadline():
    if remaining() <= 0:
        raise Deadline()


def git(root, args, stdin=None, literal=False, deadline=True):
    if deadline:
        check_deadline()
    # The PreToolUse half runs before the call is approved, so a repository's own config
    # must not start a program: core.fsmonitor runs one during `status`, and a lazy fetch
    # of a missing object in a partial clone runs a transport (blocked by _GIT_ENV).
    cmd = (["git", "-c", "core.fsmonitor=false"]
           + (["--literal-pathspecs"] if literal else []) + ["-C", root] + args)
    try:
        r = subprocess.run(cmd, input=stdin, capture_output=True, env=_GIT_ENV,
                           timeout=min(GIT_TIMEOUT_S, remaining()) if deadline else GIT_TIMEOUT_S)
    except subprocess.TimeoutExpired:
        raise GitError("timed out: git " + " ".join(args[:2]))
    except OSError as e:
        raise GitError(str(e))
    if r.returncode != 0:
        raise GitError("git {} failed (rc={})".format(" ".join(args[:2]), r.returncode),
                       r.returncode)
    return r.stdout


def _decode(b):
    return b.decode("utf-8", "surrogateescape")


def _path_line(out):
    """A path git printed: only its own LF terminator comes off (the path may end in
    whitespace, a newline included)."""
    s = _decode(out)
    return s[:-1] if s.endswith("\n") else s


# ── body hash ──────────────────────────────────────────────────────────────

def body_hash(data):
    lines = re.split(r"\r\n|\r|\n", _decode(data))
    lines = [ln for ln in lines
             if not _MARKER_LINE_RE.match(ln) and not _COVERAGE_LINE_RE.match(ln)]
    while lines and lines[-1].strip() == "":
        lines.pop()
    return hashlib.sha256("\n".join(lines).encode("utf-8", "surrogateescape")).hexdigest()


def _open_regular(path):
    """Open for reading; a call can leave a FIFO at any path, and a blocking open() on one
    outlives every deadline, so anything but a regular file raises OSError instead."""
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError("not a regular file: " + path)
        return os.fdopen(fd, "rb")
    except BaseException:
        os.close(fd)
        raise


def _bounded_hash(abspath, deadline=True):
    """Body hash; past MAX_BODY_BYTES a chunked raw `bighash:` (Deadline can interrupt
    it), or, without a deadline, `oversize:` once the budget is spent, which equals no
    snapshot entry."""
    with _open_regular(abspath) as fh:
        data = fh.read(MAX_BODY_BYTES + 1)
        if len(data) <= MAX_BODY_BYTES:
            return body_hash(data)
        h = hashlib.sha256(data)
        while True:
            if deadline:
                check_deadline()
            elif remaining() <= 0:
                return OVERSIZE
            chunk = fh.read(1024 * 1024)
            if not chunk:
                return "bighash:" + h.hexdigest()
            h.update(chunk)


def _unreadable(abspath):
    try:
        st = os.lstat(abspath)
        return "unreadable:{}:{}".format(st.st_size, st.st_mtime_ns)
    except OSError:
        return "unreadable:-:-"


def file_entry(abspath):
    """Body hash of a working-tree file, or the `unreadable:` sentinel from lstat."""
    check_deadline()
    try:
        return _bounded_hash(abspath)
    except OSError:
        return _unreadable(abspath)


def fallback_entry(abspath):
    """file_entry without the deadline, for the post-status-failure fallback."""
    try:
        return _bounded_hash(abspath, deadline=False)
    except FileNotFoundError:
        return "gone"
    except OSError:
        return _unreadable(abspath)


def fallback_candidates(root, files):
    """[(rel, False)] for the snapshotted docs whose bytes now differ, when the post-call
    status failed. Each read is capped; once the deadline passes, or for a doc that was
    never hashed, a doc still present arms unread (the over-arm direction)."""
    out = []
    for rel, h in files.items():
        abspath = os.path.join(root, rel)
        if is_unhashed(h) or remaining() <= 0:
            if os.path.lexists(abspath):
                out.append((rel, False))
        elif fallback_entry(abspath) not in (h, "gone"):
            out.append((rel, False))
    return out


def is_unhashed(entry):
    return entry.startswith("unhashed:")


def is_uncompared(entry):
    """Not a body hash: the content was not read (unreadable, or cut off by the deadline)
    or not normalized (oversize), so a changed doc is armed without a PASS downgrade."""
    return entry.startswith(("unreadable:", "unhashed:", "bighash:"))


# ── dirty set ──────────────────────────────────────────────────────────────

def _dir_pathspecs(state_dir):
    pats = ["**/docs/**/plans/**/*.md", "**/docs/**/specs/**/*.md",
            "**/{}/**/plans/**/*.md".format(state_dir),
            "**/{}/**/specs/**/*.md".format(state_dir)]
    return [":(top,icase,glob)" + p for p in pats]


def _pathspecs(state_dir):
    pats = ["**/plan*.md", "**/design*.md", "**/architecture*.md"]
    return [":(top,icase,glob)" + p for p in pats] + _dir_pathspecs(state_dir)


def _in_design_dir(rel, state_dir):
    return bool(re.search(r"(?:^|/)(?:" + re.escape(state_dir)
                          + r"|docs)/(?:[^/]+/)*(?:plans|specs)/.*\.md$", rel))


def lexical_design(rel, state_dir):
    return bool(_DESIGN_RE.search(rel) or _in_design_dir(rel, state_dir))


def dirty_set(root, state_dir):
    """relpath -> body hash (or sentinel) for every dirty, non-unmerged, regular design doc.

    Gitignored docs are listed separately, and only inside a plans/ or specs/ directory
    (an ignored `docs/plans/` or `<STATE_DIR>/specs/`). An ignored file matched only by its
    basename is left out: blueprint-review's own run rewrites the ignored
    `.claude/ultra-oracle/plan-consult-verdict.md`, so covering `plan*.md` would arm a
    token every review round that its PASS never prunes. That listing failing only warns.
    shortcut: assume-unchanged / skip-worktree docs stay invisible (spec Residuals); the
    Write/Edit path and the redirect parser still cover them.

    A path whose hashing the deadline cuts off gets the `unhashed:` sentinel, so the
    caller still knows it was dirty."""
    out = git(root, ["--no-optional-locks", "status", "--porcelain", "-z", "-uall",
                     "--no-renames", "--ignore-submodules=all", "--"] + _pathspecs(state_dir))
    rels = []
    for rec in out.split(b"\0"):
        if len(rec) < 4:
            continue
        xy, rel = _decode(rec[:2]), _decode(rec[3:])
        if "U" in xy or xy in ("AA", "DD"):
            continue
        if lexical_design(rel, state_dir):
            rels.append(rel)
    # Top-anchored first: a literal first component lets git prune, so `docs/` and
    # `<STATE_DIR>/` are listed fast. The `**/` pass then adds nested `pkg/docs/plans/` docs;
    # it walks every ignored tree (node_modules), so its failure cannot cost the first.
    anchored = [":(top,icase,glob){}/**/{}/**/*.md".format(d, k)
                for d in ("docs", state_dir) for k in ("plans", "specs")]
    ignored = []
    for specs in (anchored, _dir_pathspecs(state_dir)):
        try:
            out = git(root, ["ls-files", "-z", "--others", "--ignored", "--exclude-standard",
                             "--"] + specs)
        except (GitError, Deadline) as e:
            warn("ignored design docs in {} not listed ({})".format(root, e or "deadline"))
            continue
        ignored += [_decode(x) for x in out.split(b"\0") if x]
    rels += [r for r in dict.fromkeys(ignored) if _in_design_dir(r, state_dir)]
    result, late = {}, False
    for rel in rels:
        abspath = os.path.join(root, rel)
        try:
            if not stat.S_ISREG(os.lstat(abspath).st_mode):
                continue
        except OSError:
            continue
        if late:
            result[rel] = "unhashed:"
            continue
        try:
            result[rel] = file_entry(abspath)
        except Deadline:
            late = True
            result[rel] = "unhashed:"
    return result


def resolve_commit(root, rev):
    """Commit oid, None when `rev` does not exist; any other failure raises GitError."""
    try:
        out = git(root, ["rev-parse", "-q", "--verify", rev + "^{commit}"])
    except GitError as e:
        if e.rc == 1:
            return None
        raise
    oid = _decode(out).strip()
    return oid or None


def revision_hashes(root, rev, paths):
    """relpath -> body hash of P at commit `rev`, for regular blobs only (absent = no key).

    Raises GitError on any failed read or malformed record."""
    if not paths:
        return {}
    listing = git(root, ["ls-tree", "-z", "-l", rev, "--"] + list(paths), literal=True)
    want, sizes, oversize = {}, {}, []
    for ent in listing.split(b"\0"):
        if not ent:
            continue
        meta, sep, path = ent.partition(b"\t")
        if not sep:
            raise GitError("malformed ls-tree entry")
        parts = meta.split()
        if len(parts) != 4:
            raise GitError("malformed ls-tree entry")
        mode, typ, oid, size = parts
        if typ != b"blob" or mode not in (b"100644", b"100755"):
            continue
        # An oversize blob is not fetched (cat-file's output stays bounded): it gets the
        # OVERSIZE value, which equals no hash and keeps the doc's PASS.
        if not size.isdigit() or int(size) > MAX_BODY_BYTES:
            oversize.append(_decode(path))
            continue
        want[_decode(path)] = oid
        sizes[oid] = int(size)
    result = {p: OVERSIZE for p in oversize}
    if not want:
        return result
    if sum(sizes.values()) > MAX_BATCH_BYTES:
        raise GitError("revision blobs exceed {} bytes".format(MAX_BATCH_BYTES))
    check_deadline()
    oids = sorted(set(want.values()))
    out = git(root, ["cat-file", "--batch"], stdin=b"".join(o + b"\n" for o in oids))
    hashes = {}
    pos = 0
    for _ in oids:
        nl = out.find(b"\n", pos)
        if nl < 0:
            raise GitError("malformed cat-file record")
        header = out[pos:nl].split(b" ")
        pos = nl + 1
        if len(header) == 2 and header[1] == b"missing":
            # ls-tree listed this blob, so the path exists at `rev`: the object is
            # unreadable (pruned, promisor), not absent. A failed read keeps the PASS.
            raise GitError("blob {} unreadable at {}".format(_decode(header[0]), rev))
        if len(header) != 3 or not header[2].isdigit():
            raise GitError("malformed cat-file record")
        size = int(header[2])
        if pos + size + 1 > len(out) or out[pos + size:pos + size + 1] != b"\n":
            raise GitError("malformed cat-file record")
        check_deadline()
        hashes[header[0]] = body_hash(out[pos:pos + size])
        pos += size + 1
    if pos != len(out):
        raise GitError("malformed cat-file stream")
    result.update((p, hashes[o]) for p, o in want.items() if o in hashes)
    return result


# ── payload and storage ────────────────────────────────────────────────────

def read_payload():
    d = json.load(sys.stdin)
    if not isinstance(d, dict):
        raise ValueError("payload is not an object")
    inp = d.get("tool_input", d.get("toolInput", {}))
    if isinstance(inp, str):
        inp = json.loads(inp)
    cmd = inp.get("command", "") if isinstance(inp, dict) else ""
    return d, (cmd if isinstance(cmd, str) else "")


def store_path(payload, cmd):
    home = os.environ.get("HOME", "")
    if not os.path.isabs(home):
        raise OSError("HOME unresolvable")
    session = payload.get("session_id") or "-"
    key = payload.get("tool_use_id")
    degraded = not key
    if degraded:
        key = hashlib.sha256(cmd.encode("utf-8", "surrogateescape")).hexdigest()
    digest = hashlib.sha256(str(session).encode("utf-8", "surrogateescape") + b"\0"
                            + str(key).encode("utf-8", "surrogateescape")).hexdigest()
    store = os.path.join(home, ".claude", "busdriver", "design-effect.d")
    return store, os.path.join(store, digest + ".json"), degraded


def toplevel(path):
    try:
        out = git(path, ["rev-parse", "--show-toplevel"])
    except (GitError, Deadline):  # a Deadline here must not cost the whole snapshot
        return None
    top = _path_line(out)
    return top or None


def snap_roots(payload, cmd):
    cwd = payload.get("cwd") or ""
    if not os.path.isabs(cwd):
        warn("payload cwd is missing or not absolute; the hook cwd is compared instead")
        try:
            cwd = os.getcwd()
        except OSError:  # a deleted hook cwd must not cost the whole snapshot
            warn("hook cwd is unresolvable; only an absolute `cd` target is compared")
            cwd = ""
    roots = []
    top = toplevel(cwd) if cwd else None
    if top:
        roots.append(top)
    elif cwd:
        warn("payload cwd is not inside a repository; it is not compared")
    try:
        from gitcmd_detect import effective_cwd
        eff, ok = effective_cwd(cmd, cwd or ".")
    except Exception:
        eff, ok = None, False
    if ok and eff and os.path.isabs(eff) and eff != cwd:
        top = toplevel(eff)
        if top and top not in roots:
            if names_filter_program(top):
                warn("{} configures a clean/process filter that `git status` could run "
                     "before the call is approved; it is not compared".format(top))
            else:
                roots.append(top)
    return roots


def names_filter_program(root):
    """True (fail closed) unless the repo's config provably names no filter program.

    `git status` can run a clean filter on a stat-dirty file. That is the session
    repository's own config for the payload-cwd root, the same trust every other gate
    gives it; a repository the command only `cd`s into gets no such trust before the
    call is approved. Reading config runs nothing."""
    try:
        r = subprocess.run(["git", "-C", root, "config", "--name-only", "--get-regexp",
                            r"^filter\..*\.(clean|process)$"],
                           capture_output=True, timeout=GIT_TIMEOUT_S)
    except (OSError, subprocess.TimeoutExpired):
        return True
    return r.returncode != 1


def cmd_snap(payload, cmd, state_dir):
    store, path, degraded = store_path(payload, cmd)
    if degraded:
        warn("no tool_use_id in payload; snapshot keyed by command text")
    os.makedirs(store, mode=0o700, exist_ok=True)
    now = time.time()
    for name in os.listdir(store):
        p = os.path.join(store, name)
        try:
            if now - os.lstat(p).st_mtime > PRUNE_AGE_S:
                os.unlink(p)
        except OSError:
            pass
    recs, skipped = [], []
    for root in snap_roots(payload, cmd):
        rec = {"root": root, "head": None, "files": None}
        try:
            try:
                rec["head"] = resolve_commit(root, "HEAD")
            except GitError as e:
                rec["head"] = HEAD_UNKNOWN
                warn("could not resolve HEAD in {} ({}); its newly dirty docs will be "
                     "armed without a PASS downgrade".format(root, e))
            rec["files"] = dirty_set(root, state_dir)
            if any(v == "unhashed:" for v in rec["files"].values()):
                warn("deadline passed while hashing {}; its unhashed dirty docs will be "
                     "armed after the call".format(root))
        except (GitError, Deadline) as e:
            skipped.append("{} ({})".format(root, e or "deadline"))
        recs.append(rec)
    # After every root's dirty set, so a lookup never costs a comparison; recorded, it
    # spares cmd_diff a git call before its own comparison (Kody v5eSy).
    for rec in recs:
        if rec["files"] is not None:
            try:
                rec["mdir"] = marker_dir_for(rec["root"], deadline=True)
            except Deadline:
                break
    if skipped:
        warn("roots left uncompared: " + ", ".join(skipped))
    tmp = "{}.{}.tmp".format(path, os.getpid())
    with open(tmp, "w") as fh:
        json.dump({"roots": recs}, fh)
    os.replace(tmp, path)


# ── per-document processing ────────────────────────────────────────────────

def marker_dir_for(root, deadline=False):
    try:
        # cmd_snap looks it up under its deadline (a Deadline propagates) and records it.
        # cmd_diff only falls back to this, with no deadline (the git timeout still
        # bounds it): a passed deadline must never be the reason a doc goes unarmed.
        out = git(root, ["rev-parse", "--path-format=absolute", "--git-common-dir"],
                  deadline=deadline)
    except GitError:
        return None
    common = _path_line(out)
    if not common:
        return None
    return os.path.join(os.path.realpath(common), "busdriver", "design-review-needed.local.d")


def _fs_common_dir(root):
    """The root's common git dir read from the filesystem (`.git` dir, or gitfile →
    gitdir → `commondir`), or None when the layout is anything else. A file must hold
    exactly one plain line: git trims what this does not, and None only reruns the lookup."""
    def one_line(path):
        with _open_regular(path) as fh:
            data = fh.read(4097)
        text = data[:-1] if data.endswith(b"\n") else data
        if not text or len(data) > 4096 or text != text.strip() or b"\n" in text \
                or b"\r" in text:
            return None
        return text.decode("utf-8", "surrogateescape")
    dotgit = os.path.join(root, ".git")
    try:
        if os.path.isdir(dotgit):
            gitdir = dotgit
        else:
            line = one_line(dotgit)
            if not line or not line.startswith("gitdir: "):
                return None
            gitdir = os.path.join(root, line[len("gitdir: "):])
        try:
            rel = one_line(os.path.join(gitdir, "commondir"))
        except FileNotFoundError:
            return os.path.realpath(gitdir)
        return os.path.realpath(os.path.join(gitdir, rel)) if rel else None
    except (OSError, ValueError):
        return None


def _recorded_mdir(rec):
    """The snapshot's marker dir, only while the root's common dir as the filesystem now
    shows it is the one it sits under: a call that moved or retargeted the git dir
    (`git init --separate-git-dir`, an edited gitfile) makes the lookup rerun."""
    m = rec.get("mdir")
    if not (isinstance(m, str) and os.path.isabs(m)):
        return None
    common = _fs_common_dir(rec["root"])
    if common and m == os.path.join(common, "busdriver", "design-review-needed.local.d"):
        return m
    return None


def norm_key(abspath):
    out = os.path.realpath(os.path.dirname(abspath)) + "/" + os.path.basename(abspath)
    while out.startswith("//"):
        out = out[1:]
    return out


def excluded(root, abspath):
    """The shell detector's three string exclusions (no subprocess)."""
    if _REVIEW_OUT_RE.search(abspath) or _MEMORY_RE.search(abspath):
        return True
    real_root = os.path.realpath(root)
    phys = os.path.realpath(os.path.dirname(abspath)) + "/" + os.path.basename(abspath)
    rel = phys[len(real_root) + 1:] if phys.startswith(real_root + "/") else abspath
    return bool(_STRUCTURAL_RE.search(rel))


def process_doc(mo, root, rel, downgrade, marker_dir, state_dir, classify=True):
    abspath = os.path.join(root, rel)
    if excluded(root, abspath):
        return
    real_root = os.path.realpath(root)
    base = os.path.basename(abspath)
    if classify:
        try:
            rc = mo.cmd_dd_exempt([abspath, state_dir])
        except Exception:
            rc = 2
        if rc == 1:
            return
        if rc != 0:
            warn("could not classify {}; treating it as a design doc".format(abspath))
    # Arm first: the downgrade and the PASS probe read the whole doc, and their failure
    # (MemoryError on a huge one) must not cost the token.
    if marker_dir is None or mo.cmd_arm([marker_dir, norm_key(abspath)]) != 0:
        sys.stderr.write(
            "WARNING: could not arm the design-review marker for {}. If the repo state is "
            "resolvable the review gate may not fire for this doc — re-save it, or run "
            "/blueprint-review before implementing.\n".format(base))
    if downgrade:
        target = os.path.realpath(abspath)
        try:
            contained = (target.startswith(real_root + "/")
                         and stat.S_ISREG(os.lstat(target).st_mode))
            if contained:
                mo.cmd_downgrade_pass([target])
        except Exception as e:
            warn("{} armed; PASS downgrade failed: {}".format(abspath, e or type(e).__name__))
    else:
        warn("{} armed without a PASS downgrade".format(abspath))
    try:
        # The probe is a diagnostic: never read a doc past MAX_BODY_BYTES for it, nor
        # anything but a regular file (its open blocks on a FIFO).
        st = os.stat(abspath)
        reviewed = (stat.S_ISREG(st.st_mode) and st.st_size <= MAX_BODY_BYTES
                    and mo.cmd_reviewed([abspath]) == 0)
    except Exception:
        reviewed = False
    if reviewed:
        sys.stderr.write(
            "WARNING: {} still reads PASS (a reviewed 'design-reviewed: PASS' marker) but its "
            "review token is armed (this write re-opened review). Run /blueprint-review "
            "before implementing, or re-save the doc to retry the downgrade.\n".format(base))
    print("Design document written: " + base)
    print("REQUIRED: Invoke /blueprint-review skill (Skill tool) before committing.")
    print("Do NOT use code-reviewer agent — it cannot mark design docs as reviewed.")


def candidates_for(rec, state_dir):
    """[(rel, downgrade)] for one recorded root; raises GitError/Deadline on status failure."""
    root, pre = rec["root"], rec["files"]
    post = dirty_set(root, state_dir)
    decided, pending, nodown = [], {}, set()
    need_pre_head = []
    for rel, entry in post.items():
        if rel in pre and is_unhashed(pre[rel]):
            decided.append((rel, False))  # cut off before the call: changed or not is unknown
        elif rel in pre:
            if entry != pre[rel]:
                pending[rel] = entry
                if is_uncompared(pre[rel]):
                    nodown.add(rel)  # the pre-call content was never compared
        else:
            need_pre_head.append(rel)
    for rel in need_pre_head:
        pending[rel] = post[rel]
    for rel in [r for r, e in pending.items() if is_uncompared(e)]:
        decided.append((rel, False))
        del pending[rel]
    pre_head = rec["head"]
    # A failed pre-call HEAD lookup leaves a newly dirty doc compared only against the
    # drop revisions; if it still arms, nothing showed it changed, so keep its PASS.
    if pre_head == HEAD_UNKNOWN:
        nodown.update(need_pre_head)
    try:
        if need_pre_head and pre_head and pre_head != HEAD_UNKNOWN:
            at_pre = revision_hashes(root, pre_head, [r for r in need_pre_head if r in pending])
            for rel in need_pre_head:
                if rel in pending and at_pre.get(rel) == pending[rel]:
                    del pending[rel]
                elif at_pre.get(rel) == OVERSIZE:
                    nodown.add(rel)  # the pre-call content was never compared
        seen = set()
        for rev in _REV_DROPS:
            if not pending:
                break
            oid = resolve_commit(root, rev)
            if not oid or oid in seen:
                continue
            seen.add(oid)
            at_rev = revision_hashes(root, oid, list(pending))
            for rel in list(pending):
                if at_rev.get(rel) == pending[rel]:
                    del pending[rel]
                elif at_rev.get(rel) == OVERSIZE:
                    nodown.add(rel)  # it may be what this revision brings in
    except (GitError, Deadline) as e:
        warn("revision read failed in {} ({}); arming without a PASS downgrade".format(
            root, e or "deadline"))
        decided.extend((rel, False) for rel in pending)
        return decided
    decided.extend((rel, rel not in nodown) for rel in pending)
    return decided


def cmd_diff(payload, cmd, state_dir, mo):
    path = store_path(payload, cmd)[1]
    try:
        with open(path) as fh:
            snap = json.load(fh)
    except (OSError, ValueError):
        warn("no pre-call snapshot; Bash effect check skipped")
        return
    try:
        os.unlink(path)
    except OSError:
        pass
    # Arming needs a marker dir per root. The one cmd_snap recorded costs no git call;
    # a root without one is looked up first, before the comparison spends the deadline.
    mdirs = {rec["root"]: _recorded_mdir(rec) or marker_dir_for(rec["root"])
             for rec in snap.get("roots", []) if rec.get("files") is not None}
    work, uncompared = [], []
    for rec in snap.get("roots", []):
        if rec.get("files") is None:
            uncompared.append(rec.get("root", "?"))
            continue
        try:
            work.append((rec["root"], candidates_for(rec, state_dir)))
        except (GitError, Deadline) as e:
            # No post-call dirty set: a snapshotted doc whose bytes now differ still arms
            # (without a downgrade). A doc the call newly created stays unseen.
            uncompared.append("{} ({}; only snapshotted docs re-checked)".format(
                rec["root"], e or "deadline"))
            work.append((rec["root"], fallback_candidates(rec["root"], rec["files"])))
    # Past the 3 s deadline a candidate is still armed, but without the classifier (its
    # `git rev-parse` child has no timeout) and without a PASS downgrade: the string
    # exclusions still apply, and a symlink-escaped doc can over-arm, the safe direction.
    late = []
    for root, cands in work:
        mdir = mdirs.get(root)
        for rel, downgrade in cands:
            on_time = not late and remaining() > 0
            if not on_time:
                late.append(os.path.join(root, rel))
            try:
                process_doc(mo, root, rel, downgrade and on_time, mdir, state_dir,
                            classify=on_time)
            except Exception as e:
                warn("processing {} failed: {}".format(os.path.join(root, rel), e))
    if uncompared:
        warn("roots left uncompared: " + ", ".join(uncompared))
    if late:
        warn("deadline passed; armed without classification: " + ", ".join(late))


def main(argv):
    if len(argv) != 2 or argv[0] not in ("snap", "diff"):
        return 2
    sys.path.insert(0, argv[1])
    try:
        payload, cmd = read_payload()
    except Exception:
        warn("unparseable hook payload")
        return 1
    state_dir = os.environ.get("BUSDRIVER_STATE_DIR") or ".claude"
    try:
        if argv[0] == "snap":
            cmd_snap(payload, cmd, state_dir)
        else:
            import marker_ops
            cmd_diff(payload, cmd, state_dir, marker_ops)
    except Deadline:
        warn("deadline passed before the {} finished".format(argv[0]))
    except Exception as e:
        warn("{} failed: {}".format(argv[0], e))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
