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
  reviewed <doc>
        #355: exit 0 iff <doc> carries an honorable design-reviewed PASS marker
        (PASS present AND no DEGRADED coverage marker). 1 = not honored / missing /
        unreadable (fail-CLOSED). Single byte-faithful read — the Bash gate readers
        delegate here (gate_design_pass_honored) so there is ONE implementation, no
        two-open race, and no NUL-stripping divergence.
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
# #355 — all reader regexes are WHOLE-LINE (re.MULTILINE `^…$`), matching the writer,
# which emits every marker on its own line. This keeps reader and writer in lockstep:
# a marker string embedded in PROSE (`… the <!-- design-reviewed: PASS --> marker …`)
# is ignored by BOTH — the writer never rewrites it and the reader never counts it —
# so a design doc can safely discuss the markers inline. (`.` excludes newline without
# re.DOTALL, so `.*` stays within its line.)
_PASS_LINE_RE = re.compile(r"^[ \t]*<!-- design-reviewed: PASS -->[ \t]*$", re.M)
# A LINE that STARTS with the coverage prefix — the total the FULL count must equal.
# Keyed on the prefix (not a complete `-->`) so a TRUNCATED/split/malformed marker
# on its own line (`<!-- design-review-coverage:` at EOF, or the prefix with `FULL`
# on the next line) still counts toward the total and therefore BLOCKS unless it is
# also a well-formed FULL line. Anchored to line start, so a prefix appearing mid-line
# in PROSE is ignored (writer and reader agree: only own-line markers are real).
#
# DESIGN TRADE-OFF (accepted, operator-approved): line-start detection makes design
# docs that DISCUSS these markers inline (this repo's own docs, incl. #355's plan)
# authorizable — an any-occurrence reader would block them forever. The cost is a
# narrow blind spot: a marker FUSED mid-line by the pre-#355 writer's old missing-
# newline append (`text<!-- design-review-coverage: DEGRADED -->`) is read as prose.
# This is NOT a regression — before #355 the reader did no coverage check at all and
# honored ANY PASS — and the writer's leading-`\n` fix means new writes are always
# own-line. The residual is stale on-disk docs from the old writer that also lacked a
# trailing newline (astronomically rare); those re-anchor the moment the writer runs.
_COVERAGE_LINE_START_RE = re.compile(r"^[ \t]*<!-- design-review-coverage:", re.M)
# A line that is EXACTLY ONE well-formed FULL marker: status token EXACTLY `FULL` and
# count EXACTLY `3/3` — the writer's invariant is FULL ⟺ all 3 lenses fulfilled
# (state_management.sh: count==3 ⇒ FULL), so `FULL 0/3`, `FULL garbage`, or no count
# is contradictory and must NOT count. `(?=[ \t]|-->)` pins the count (a bare `\b`
# would match before `-`,`/`,`.`, letting `3/3-extra`/`3/3/4`/`3/3.5` slip). The body
# `(?:(?!-->)(?!<!--).)*` forbids BOTH a second closer `-->` AND a second opener `<!--`,
# so a line carrying a FULL marker plus another marker — sharing the closer
# (`…FULL 3/3 <!-- …DEGRADED 1/3 -->`) or bringing its own (`…FULL 3/3 --><!-- …DEGRADED -->`)
# — is NOT a valid FULL line ⇒ total>full ⇒ block.
_FULL_LINE_RE = re.compile(
    r"^[ \t]*<!-- design-review-coverage:[ \t]*FULL[ \t]+3/3(?=[ \t]|-->)(?:(?!-->)(?!<!--).)*-->[ \t]*$",
    re.M)


def _doc_reviewed(content):
    """True iff the doc carries an honorable PASS marker: a whole-line PASS marker is
    present AND every own-line coverage marker is a well-formed FULL 3/3 marker (a
    security-gate plan must not be authorized on partial coverage, #355). A doc with
    NO coverage marker stays honorable (pre-provenance docs / provenance off). Single
    source of truth — used by the legacy classifier here AND (via the `reviewed`
    subcommand) by the Bash readers' gate_design_pass_honored() in
    lib/resolve-repo-dir.sh, so they cannot diverge."""
    if not _PASS_LINE_RE.search(content):
        return False
    total = len(_COVERAGE_LINE_START_RE.findall(content))
    if total == 0:
        return True  # no own-line coverage marker at all → honorable
    # Every own-line coverage marker must be a well-formed FULL 3/3 marker line.
    return total == len(_FULL_LINE_RE.findall(content))


def _sha(norm):
    # surrogateescape so a non-UTF-8 filesystem path round-trips deterministically
    # between arm (write) and classify (verify).
    return hashlib.sha256(norm.encode("utf-8", "surrogateescape")).hexdigest()


def cmd_sha(argv):
    if len(argv) != 1:
        return 2
    sys.stdout.write(_sha(argv[0]))
    return 0


def cmd_reviewed(argv):
    # #355: exit 0 iff the doc is honorably reviewed. Single byte-faithful read;
    # missing/unreadable → fail-CLOSED (exit 1, not honored).
    if len(argv) != 1:
        return 2
    try:
        with open(argv[0], "r", errors="surrogateescape") as fh:
            content = fh.read()
    except OSError:
        return 1
    return 0 if _doc_reviewed(content) else 1


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
        # KEEP any partially-written token on write/close failure — do NOT unlink.
        # The classifier reads a malformed/truncated token as `unparseable` →
        # PENDING → block, so a failed arm still leaves durable FAIL-CLOSED state
        # rather than silently losing the review requirement (a fail-OPEN). The
        # operator drains a genuinely spurious token via the §6 manual `rm`.
        try:
            off = 0
            while off < len(data):  # os.write may short-write
                off += os.write(fd, data[off:])
        except OSError:
            return 1
        finally:
            try:
                os.close(fd)
            except OSError:
                pass
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
        # arm ALWAYS writes norm + exactly one trailing LF; a body missing it is a
        # truncated/forged token → unparseable (not silently accepted).
        if not raw.endswith(b"\n"):
            em.add("token", tok, "", "unparseable")
            continue
        body = raw[:-1]
        if b"\n" in body or b"\r" in body:  # only the one trailing LF allowed
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
                    reviewed = _doc_reviewed(dfh.read())
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


# #347 — design-doc grammar, in lockstep with the detector (check-design-document.sh)
# and the pre-implementation exemption. Basename PLAN/DESIGN/ARCHITECTURE*.md
# (case-insensitive) OR under (STATE_DIR|docs)/(…/)?(plans|specs)/*.md.
_DD_BASENAME_RE = re.compile(r"(^|/)(PLAN|DESIGN|ARCHITECTURE)[^/]*\.md$", re.I)


def _is_design_doc(path, state_dir):
    if _DD_BASENAME_RE.search(path):
        return True
    return bool(re.search(
        r"(^|/)(" + re.escape(state_dir) + r"|docs)/([^/]+/)*(plans|specs)/.*\.md$", path))


def _repo_relative(abspath):
    """Path of abspath relative to its git worktree root, or abspath unchanged when it
    is not inside a repo. Used so the design-doc grammar is applied to the REPO-RELATIVE
    path — a repo checked out under an ancestor like /x/docs/plans/repo/ must not have its
    own src/impl.md classified a design doc just because the ANCESTOR chain says docs/plans."""
    import subprocess
    d = os.path.dirname(abspath) or "."
    # Walk up to the deepest EXISTING dir: a new nested doc's immediate parent may not exist
    # yet, and `git -C <missing>` fails → we'd fall back to the absolute path and re-expose
    # the ancestor-docs/plans bypass for not-yet-created parents.
    while d and not os.path.isdir(d) and d != os.path.dirname(d):
        d = os.path.dirname(d)
    if not d:
        d = "."
    try:
        r = subprocess.run(["git", "-C", d, "rev-parse", "--show-toplevel"],
                           capture_output=True)
        if r.returncode == 0:
            root = r.stdout.decode("utf-8", "surrogateescape").strip()
            if root:
                root = os.path.realpath(root)
                if abspath == root:
                    return os.path.basename(abspath)
                if abspath.startswith(root + "/"):
                    return abspath[len(root) + 1:]
    except Exception:
        pass
    return abspath  # not in a repo / git error → absolute (the basename arm still applies)


def cmd_dd_exempt(argv):
    # exit 0 iff <lexical_path> is a design doc BOTH lexically AND after os.path.realpath
    # — which resolves EVERY symlink on the path (leaf AND parents) while keeping a
    # not-yet-created tail lexical, so it never fails on a new doc. A symlinked parent
    # (`docs/plans -> src`) OR a symlinked leaf (`docs/plans/x.md -> ../src/impl.sh`) that
    # escapes the design-doc location is therefore NOT exempt, and a pending review blocks
    # the impl write it was laundering. A genuinely new doc keeps its lexical location and
    # stays exempt (no deadlock). The physical grammar runs on the REPO-RELATIVE path so an
    # ancestor named docs/plans cannot launder an impl .md. Return 0=exempt, 1=not a design
    # doc, 2=usage error (the caller fails CLOSED on 2).
    if len(argv) != 2:
        return 2
    path, state_dir = argv
    if not _is_design_doc(path, state_dir):
        return 1
    try:
        phys = os.path.realpath(path)
    except OSError:
        return 1
    return 0 if _is_design_doc(_repo_relative(phys), state_dir) else 1


# #449 — downgrade every honorable whole-line PASS marker to PENDING, in the SAME
# engine that reads it (cmd_reviewed / _PASS_LINE_RE), so the strip and the honored-set
# can never diverge. A shell grep/sed strip cannot: it is byte-level and LF-only, while
# _doc_reviewed reads in TEXT mode where Python universal-newline translation makes `\r`,
# `\n`, AND `\r\n` all line boundaries — so a CRLF or bare-CR doc's marker is honored but
# a shell strip misses it, recreating the stale-PASS-with-armed-token bug. We split on
# the SAME three boundaries, match each line with the reader's `[ \t]`-padded whole-line
# grammar (capturing leading/trailing padding so only the token changes), and rejoin with
# the ORIGINAL separators via newline='' — preserving every byte and line ending except
# PASS→PENDING. Best-effort (the caller is a fail-open PostToolUse hook): unreadable /
# unwritable → return 1 so the caller's post-check can warn.
_PASS_LINE_SUB_RE = re.compile(r"^([ \t]*)<!-- design-reviewed: PASS -->([ \t]*)$")


def cmd_downgrade_pass(argv):
    if len(argv) != 1:
        return 2
    path = argv[0]
    try:
        with open(path, "r", newline="", errors="surrogateescape") as fh:
            content = fh.read()
    except OSError:
        return 1
    parts = re.split(r"(\r\n|\r|\n)", content)  # even idx = line text, odd = separators
    changed = False
    for i in range(0, len(parts), 2):
        m = _PASS_LINE_SUB_RE.match(parts[i])
        if m:
            parts[i] = m.group(1) + "<!-- design-reviewed: PENDING -->" + m.group(2)
            changed = True
    if not changed:
        return 0
    # Atomic replace: write a sibling temp then os.replace over the original, so a
    # disk-full / interrupted / partial write can never truncate or corrupt the doc —
    # the original is untouched until the rename (open("w") would truncate first: Codex
    # PR review). Preserve the original mode. Any failure leaves the doc intact and
    # returns 1 so the caller's post-check warns.
    import tempfile
    import stat as _stat
    d = os.path.dirname(path) or "."
    try:
        orig_mode = _stat.S_IMODE(os.stat(path).st_mode)
        fd, tmp = tempfile.mkstemp(prefix=".dr-dg-", dir=d)
    except OSError:
        return 1
    try:
        with os.fdopen(fd, "w", newline="", errors="surrogateescape") as fh:
            fh.write("".join(parts))
        os.chmod(tmp, orig_mode)
        os.replace(tmp, path)
        return 0
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return 1


_DISPATCH = {"sha": cmd_sha, "arm": cmd_arm, "classify": cmd_classify,
             "reviewed": cmd_reviewed, "dd-exempt": cmd_dd_exempt,
             "downgrade-pass": cmd_downgrade_pass}


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
