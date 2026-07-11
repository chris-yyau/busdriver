#!/usr/bin/env python3
"""enable-advisory-downgrade.py — bulk-enroll repos in the ADR 0012 advisory-bot
stale-ack timeout downgrade by placing the per-repo opt-in marker.

Issue #326 follow-up to PR #314. The resolver
(scripts/advisory-downgrade-optin.sh) is the SINGLE source of truth for whether a
marker counts as operator consent; this enroller only *places* markers, then asks
the resolver to confirm each one took (no second, divergent acceptance check).

Usage:
    enable-advisory-downgrade.py [--dry-run] REPO [REPO ...]

REPO is an EXPLICIT path to a git work-tree — there is deliberately no globbing or
auto-discovery (a recursive scan could wander into an untrusted tree). For each
repo the marker lands at
<main-worktree-root>/<STATE_DIR>/pr-grind-advisory-downgrade.local, where the
main-worktree root is resolved via git exactly like the resolver reads it.

Safety (operator-machine-local threats named in ADR 0012's "Deferred" section):
  * No redirection, BY CONSTRUCTION: the marker is always written under the operator's
    EXPLICIT path (realpath'd), which is opened ONCE component-by-component with openat
    + O_NOFOLLOW (emulating openat2(RESOLVE_NO_SYMLINKS)) — a per-component symlink
    guarantee portable bash could not give (the reason #314 deferred this enroller).
    git is used only to VALIDATE that path is a main worktree root, never to CHOOSE the
    write target — so a forged `.git` gitfile (which could make `git -C repo` resolve
    ANOTHER repo) can at most cause a wrong skip/accept decision, never send the marker
    to a repo the operator did not name. Only explicit paths are accepted (no
    globbing/auto-discovery).
  * Stable fds, not re-resolved paths: the root is opened ONCE and the resolver's
    acceptance check binds to it via fchdir (not a path cwd that could re-resolve to a
    swapped dir); the state dir is opened ONCE and that fd is shared by placement AND
    rollback — so a directory rename/replace between the write and the rollback cannot
    make them act on different objects (the rollback removes exactly what was placed).
    The resolver still re-resolves STATE_DIR by name inside root — by design, as the
    independent authority; on a mid-run swap it rejects and the shared-fd rollback cleans
    up what we placed, so the net result stays fail-closed.
  * Injectable-env defense is by ALLOWLIST, not blocklist: every git/resolver
    subprocess gets ONLY a fixed PATH (/usr/bin:/bin) and the validated
    BUSDRIVER_STATE_DIR. So a committed .claude/settings.json `env` block cannot reach
    them with GIT_DIR/…, BASH_ENV / ENV / BASH_FUNC_* (bash startup code exec), a
    shadowing PATH, or anything else — those are dropped by construction rather than
    enumerated. This is what prevents a poisoned child from forging the resolver's
    verdict; the resolver is the security-relevant subprocess.
  * Residuals (accepted, operator-machine-local — the threat model per ADR 0012 is the
    operator running this over THEIR OWN repos, not untrusted PR content; the resolver
    is the piece that faces untrusted content and holds by construction):
      - The operator's own named path being swapped between realpath and open lands the
        marker at that path's current contents — but never at a DIFFERENT path than the
        one named, and enabling advisory-downgrade on a repo grants nothing (it never
        opens the merge gate; the operator can opt in any repo trivially).
      - A poisoned session that runs code in THIS interpreter before it defends itself —
        PYTHONPATH/sitecustomize or LD_PRELOAD/DYLD_* set by a committed settings.json
        `env` block, which execute during interpreter startup. This is irreducible in a
        script the operator launches from the poisoned session (an in-process re-exec is
        already too late — startup ran first), and is the same session-wide residual
        ADR 0016 accepts as outside the (server-side) merge-security boundary; the
        resolver and gates run under the same assumption. The subprocess allowlist above
        still prevents this from forging the resolver's independent verdict.
  * Fail-closed per target: any ambiguity (not the main worktree root, symlinked state
    dir or marker, or the resolver rejecting the placed marker) SKIPS that repo and is
    reported; other repos continue.

Exit status: 0 if every given repo ended ENROLLED / ALREADY (or WOULD-ENROLL under
--dry-run); 1 if any repo was SKIPPED / WOULD-SKIP; 2 on a usage/config error.
"""

import os
import stat
import subprocess
import sys

STATE_DIR = os.environ.get("BUSDRIVER_STATE_DIR", ".claude")
MARKER = "pr-grind-advisory-downgrade.local"
CONTENT = (
    "# ADR 0012 advisory-bot stale-ack timeout downgrade — per-repo operator opt-in.\n"
    "# Placed by scripts/enable-advisory-downgrade.py (issue #326). Keep untracked /\n"
    "# gitignored; acceptance is decided by scripts/advisory-downgrade-optin.sh.\n"
)
# realpath (not abspath) so invoking this script through a SYMLINK still resolves the
# resolver next to the REAL script, never a same-named file beside the symlink.
RESOLVER = os.path.join(os.path.dirname(os.path.realpath(__file__)), "advisory-downgrade-optin.sh")

# Build the git/resolver subprocess environment as a strict ALLOWLIST, not a blocklist:
# a committed .claude/settings.json `env` block can set ARBITRARY vars, and enumerating
# every dangerous one (GIT_DIR/…, BASH_ENV, ENV, BASH_FUNC_* exported functions,
# LD_PRELOAD, …) is a losing game. Instead we pass ONLY what git's read-only plumbing
# and the resolver need, so every injected variable is dropped by construction.
#   * PATH: fixed to trusted system dirs (git → /usr/bin/git, bash → /bin/bash), so a
#     planted binary on a repo-prepended PATH cannot shadow them.
#   * BUSDRIVER_STATE_DIR: forwarded so the resolver reads the SAME state dir; both it
#     and this script validate it (single component), so a hostile value fails closed.
# HOME is deliberately omitted: git's plumbing (ls-files/ls-tree/rev-parse/worktree
# list) works without it and then cannot be steered by a repo-controlled ~/.gitconfig.
_CLEAN_ENV = {"PATH": "/usr/bin:/bin", "BUSDRIVER_STATE_DIR": STATE_DIR}


def _chomp(s):
    """Strip the SINGLE trailing newline git appends to a path-valued line, WITHOUT
    touching trailing spaces/tabs that may be part of the filename. (A path with an
    EMBEDDED newline can't be disambiguated from rev-parse output — accepted residual,
    absurdly pathological on an operator's own repo.)"""
    return s[:-1] if s.endswith("\n") else s


# errors="surrogateescape": git paths can hold bytes invalid in the locale encoding; a
# strict decode would raise UnicodeDecodeError and abort the WHOLE run. surrogateescape
# round-trips such bytes losslessly, and os.* filesystem calls accept the result.
def git_out(cwd, *args):
    """`git -C <cwd> <args>` stdout on success, else None (fail-closed). Runs with
    the minimal allowlist environment (see _CLEAN_ENV)."""
    try:
        r = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True,
                           errors="surrogateescape", check=False, env=_CLEAN_ENV)
    except OSError:
        return None
    return r.stdout if r.returncode == 0 else None


def git_rc(cwd, *args):
    """git's exit code, or None if git couldn't run at all. Lets callers distinguish a
    real answer (0 / 1) from a repository/exec error (>=2, or None), which stdout-only
    git_out() cannot — needed to fail CLOSED on errors rather than read them as 'no'."""
    try:
        return subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True,
                              errors="surrogateescape", check=False, env=_CLEAN_ENV).returncode
    except OSError:
        return None


def main_root(repo):
    """Return the operator's EXPLICIT path (realpath'd) IFF it is the MAIN worktree
    root of a git repository; else None (fail closed).

    The returned path is the operator's OWN path — git is used only to VALIDATE it,
    never to CHOOSE the write target. Every caller anchors the marker under this
    returned path, so the marker can NEVER be redirected into a repo the operator did
    not name. As defense-in-depth we ALSO reject the case where the dir the resolver
    would read consent from diverges from the named dir (a forged `.git` gitfile
    pointing at another repo), so we never even place a marker the resolver would then
    evaluate against a FOREIGN index/HEAD.

    Consent is read at the MAIN worktree root, so a linked worktree or a subdirectory
    is rejected (the operator must name the main root)."""
    repo_real = os.path.realpath(repo)
    top = git_out(repo_real, "rev-parse", "--show-toplevel")
    if top is None or os.path.realpath(_chomp(top)) != repo_real:
        return None  # not a work-tree ROOT (subdir, non-repo, or unresolvable) → fail closed
    # MAIN (not linked) worktree: git-dir == git-common-dir. A LINKED worktree's git-dir
    # is <main>/.git/worktrees/<name> while its common-dir is <main>/.git, so they differ.
    gd = git_out(repo_real, "rev-parse", "--path-format=absolute", "--git-dir")
    gcd = git_out(repo_real, "rev-parse", "--path-format=absolute", "--git-common-dir")
    if gd is None or gcd is None or os.path.realpath(_chomp(gd)) != os.path.realpath(_chomp(gcd)):
        return None
    # The dir the RESOLVER reads consent from (`worktree list` first entry) must be
    # repo_real. A forged `.git` gitfile pointing at ANOTHER repo makes that first entry
    # the FOREIGN checkout (≠ repo_real) — reject, so we never place a marker the resolver
    # would grade against a foreign index/HEAD. The lone exception is a
    # `--separate-git-dir` main checkout, whose first entry is the git DIR (not a work
    # tree); repo_real is already confirmed as the checkout via show-toplevel above.
    # `-z` (NUL-separated) so a path with a newline / tab / non-ASCII byte is emitted
    # RAW, not C-quoted — the default `--porcelain` would quote it and we'd compare a
    # quoted string against realpath and wrongly reject a valid worktree.
    wt = git_out(repo_real, "worktree", "list", "--porcelain", "-z")
    if not wt:
        return None
    first = next((f[len("worktree "):] for f in wt.split("\0") if f.startswith("worktree ")), None)
    if first is None:
        return None
    if os.path.realpath(first) != repo_real:
        chk = git_out(first, "rev-parse", "--is-inside-work-tree")
        if chk is None or chk.strip() == "true":
            return None  # first entry is a DIFFERENT real work tree (forged gitfile) → reject
        # else chk == "false": separate-git-dir, first entry is the git dir → allow
    return repo_real


def open_dir_nofollow(path):
    """Open an absolute directory with EVERY component checked under O_NOFOLLOW —
    emulating openat2(RESOLVE_NO_SYMLINKS). `path` must be absolute and already
    symlink-free (a realpath); a component swapped to a symlink after resolution
    raises OSError, so the caller fails closed. Returns an fd the caller must close."""
    fd = os.open(os.sep, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)  # "/" is never a symlink
    try:
        for comp in [p for p in path.split(os.sep) if p]:
            nxt = os.open(comp, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = nxt
    except BaseException:
        os.close(fd)
        raise
    return fd


def marker_repo_tracked(root):
    """Best-effort DRY-RUN prediction mirroring the resolver's three repo-controlled
    conditions: marker in the index, in HEAD's tree, or STATE_DIR being a gitlink. Such
    a state makes the real run's resolver reject the marker even though it is absent
    from the working tree. The resolver stays the sole authority on real runs — this
    only sharpens the dry-run report, and FAILS CLOSED (→ True) on any git error, so a
    broken/unqueryable repo predicts the SKIP the resolver would also produce."""
    rel = f"{STATE_DIR}/{MARKER}"
    # (1) Index: --error-unmatch exits 0 if tracked, 1 if not; anything else — None
    # (couldn't run), a negative code (killed by signal), or >=2 (repo error) — is a
    # failure, so fail closed rather than misread it as "not tracked".
    rc = git_rc(root, "ls-files", "--error-unmatch", "--", rel)
    if rc not in (0, 1):
        return True   # git/repo error or signal → fail closed
    if rc == 0:
        return True   # tracked in the index
    # (2) HEAD tree: on a born HEAD, ls-tree exits 0 (stdout empty if absent). None ⇒
    # unborn HEAD (nothing tracked — fine) OR a read error against a real HEAD (→ closed).
    head = git_out(root, "ls-tree", "--name-only", "HEAD", "--", rel)
    if head is None:
        if git_out(root, "rev-parse", "--verify", "HEAD") is not None:
            return True   # HEAD exists but ls-tree failed → corrupt tree → fail closed
    elif head.strip():
        return True       # in HEAD's tree
    # (3) STATE_DIR as a gitlink/submodule (mode 160000), checked in the INDEX only —
    # deliberately identical to the resolver, which greps `ls-files --stage` for 160000
    # and does NOT consult HEAD for the gitlink. A gitlink present in HEAD but absent
    # from the index is therefore NOT repo-controlled: verified empirically that the
    # resolver returns `1` (accepts) for that state, so predicting WOULD-ENROLL here is
    # correct — treating it as tracked would make dry-run stricter than the real run.
    # ls-files --stage exits 0 with empty stdout when nothing matches; None ⇒ error ⇒ closed.
    stage = git_out(root, "ls-files", "--stage", "--", STATE_DIR)
    if stage is None:
        return True
    return any(ln.startswith("160000 ") for ln in stage.splitlines())


def open_state_dir(root_fd, dry_run):
    """openat STATE_DIR from root_fd (mkdir first on a real run), O_NOFOLLOW so a
    symlinked state dir fails closed. Returns (sd_fd, None) on success, or
    (None, (status, detail)) when it is not a usable dir: absent under --dry-run →
    WOULD-ENROLL; symlink / non-dir → SKIPPED. The caller owns and closes sd_fd, and
    shares it with both place_marker and remove_marker so placement and rollback act on
    ONE state-dir object even if <STATE_DIR> is renamed/replaced between them."""
    if not dry_run:
        try:
            os.mkdir(STATE_DIR, 0o755, dir_fd=root_fd)
        except FileExistsError:
            pass
    try:
        sd_fd = os.open(STATE_DIR, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
    except FileNotFoundError:
        return (None, ("WOULD-ENROLL", None))  # dry-run: state dir not created yet
    except OSError as e:
        return (None, ("SKIPPED", f"{STATE_DIR} is a symlink or not a directory ({e.strerror})"))
    return (sd_fd, None)


def place_marker(sd_fd, dry_run):
    """Create the marker under the already-open state-dir fd (O_CREAT|O_EXCL|O_NOFOLLOW).
    Returns (status, detail). Status ∈ {ENROLLED, ALREADY, WOULD-ENROLL, SKIPPED}."""
    # Inspect any existing marker without following a symlink (fstatat NOFOLLOW).
    try:
        st = os.stat(MARKER, dir_fd=sd_fd, follow_symlinks=False)
    except FileNotFoundError:
        st = None
    if st is not None:
        if stat.S_ISREG(st.st_mode):
            return ("ALREADY", None)
        return ("SKIPPED", "existing marker is not a regular file")
    if dry_run:
        return ("WOULD-ENROLL", None)
    # Create atomically, never following a final-component symlink. A failure from EITHER
    # the write OR the close (e.g. EIO) must leave nothing behind — a half-written/regular
    # marker still reads as a valid opt-in the resolver would ACCEPT, so a SKIPPED report
    # must not sit over a live marker.
    try:
        fd = os.open(MARKER, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644, dir_fd=sd_fd)
    except FileExistsError:
        # A concurrent enroller created the marker between our stat and this create.
        # That's idempotent success if it's a regular file (the resolver still judges
        # acceptance downstream); a non-regular file fails closed here as elsewhere.
        try:
            st2 = os.stat(MARKER, dir_fd=sd_fd, follow_symlinks=False)
        except FileNotFoundError:
            return ("SKIPPED", "marker raced away during concurrent enrollment")
        if stat.S_ISREG(st2.st_mode):
            return ("ALREADY", None)
        return ("SKIPPED", "existing marker is not a regular file")
    err = None
    try:
        os.write(fd, CONTENT.encode())
    except OSError as e:
        err = e
    finally:
        try:
            os.close(fd)
        except OSError as e:
            err = err or e
    if err is not None:
        detail = f"write failed, marker removed ({err.strerror})"
        try:
            os.unlink(MARKER, dir_fd=sd_fd)
        except FileNotFoundError:
            pass
        except OSError:
            # Rollback of the just-created marker failed — it may still be a valid
            # opt-in. Say so LOUDLY rather than claim it was removed.
            detail = (f"write failed AND rollback FAILED — remove the marker under "
                      f"{STATE_DIR}/ MANUALLY ({err.strerror})")
        return ("SKIPPED", detail)
    return ("ENROLLED", None)


def resolver_accepts(root_fd):
    """Delegate acceptance to the resolver (single source of truth), binding it to the
    SAME directory object as the write via fchdir(root_fd) in the child — NOT a
    path-based cwd that could re-resolve to a swapped directory. The resolver's
    contract is "print 0/1, ALWAYS exit 0", so a nonzero exit (crash, signal after
    flushing stdout) means it malfunctioned — fail CLOSED. True iff exit 0 AND `1`."""
    try:
        r = subprocess.run(["bash", RESOLVER], preexec_fn=lambda: os.fchdir(root_fd),
                           capture_output=True, text=True, check=False, env=_CLEAN_ENV)
    except (OSError, subprocess.SubprocessError):
        # OSError = spawn failure; SubprocessError wraps a preexec_fn (fchdir) failure —
        # fail CLOSED for THIS target rather than crash the whole run.
        return False
    return r.returncode == 0 and r.stdout.strip() == "1"


def remove_marker(sd_fd):
    """Roll back after a rejected placement by ensuring NO marker remains at the name,
    using the SAME state-dir fd placement wrote through (no path re-resolution, so a
    renamed/replaced <STATE_DIR> can't send the unlink to a different directory). The
    security goal is "no opt-in marker at this name" — which unlink achieves for
    whatever regular file is currently there; it is deliberately NOT inode-exact
    ("delete precisely the inode we created"), which name-based unlink cannot guarantee
    against a concurrent same-name replacement (an operator-local write-race on the
    operator's own .claude, outside ADR 0012's threat model). Returns True iff the name
    is gone afterward, False if it may still exist — so the caller can surface a LOUD
    manual-cleanup warning instead of a SKIPPED that silently sits over a live marker."""
    try:
        os.unlink(MARKER, dir_fd=sd_fd)
        return True
    except FileNotFoundError:
        return True  # already absent
    except OSError:
        return False


def main(argv):
    dry_run = False
    repos = []
    for a in argv:
        if a in ("--dry-run", "-n"):
            dry_run = True
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        elif a.startswith("-"):
            sys.stderr.write(f"error: unknown option {a}\n")
            return 2
        else:
            repos.append(a)
    if not repos:
        sys.stderr.write("usage: enable-advisory-downgrade.py [--dry-run] REPO [REPO ...]\n")
        return 2
    # STATE_DIR must be a single dir name — a multi-component / traversal value would
    # place the marker where the resolver (which rejects such values) never reads it.
    if STATE_DIR in ("", ".", "..") or "/" in STATE_DIR:
        sys.stderr.write(f"error: unsafe BUSDRIVER_STATE_DIR={STATE_DIR!r} (must be a single dir name)\n")
        return 2

    any_skipped = False
    for repo in repos:
        root = main_root(repo)
        if root is None:
            print(f"SKIPPED       {repo}  (not the main worktree root of a git repo)")
            any_skipped = True
            continue
        # Open the validated root ONCE (symlink-free); the resolver check binds to it via
        # fchdir. Open STATE_DIR once too and share that fd between placement and rollback,
        # so no path rename/replace between those steps can make them act on different
        # directory objects.
        try:
            root_fd = open_dir_nofollow(root)
        except OSError as e:  # fail-closed per target; keep going for the rest
            print(f"SKIPPED       {repo}  (filesystem error: {e.strerror})")
            any_skipped = True
            continue
        target = f"{root}/{STATE_DIR}/{MARKER}"
        sd_fd = None
        try:
            try:
                sd_fd, early = open_state_dir(root_fd, dry_run)
                status, detail = early if early is not None else place_marker(sd_fd, dry_run)
            except OSError as e:
                print(f"SKIPPED       {repo}  (filesystem error: {e.strerror})")
                any_skipped = True
                continue
            if status == "SKIPPED":
                print(f"SKIPPED       {repo}  ({detail})")
                any_skipped = True
            elif dry_run:
                # Predict honestly: consult the resolver for an existing marker, and for
                # an absent one check whether the PATH is already tracked (index/HEAD) — a
                # real run would create the file but the resolver would then reject it.
                if status == "ALREADY":
                    if resolver_accepts(root_fd):
                        print(f"ALREADY       {repo}  (opted-in) -> {target}")
                    else:
                        print(f"WOULD-SKIP    {repo}  (marker present but resolver rejects it — tracked/repo-controlled)")
                        any_skipped = True
                elif marker_repo_tracked(root):  # WOULD-ENROLL path, but the path is tracked
                    print(f"WOULD-SKIP    {repo}  (marker path is tracked in index/HEAD — resolver would reject a real run)")
                    any_skipped = True
                else:
                    print(f"WOULD-ENROLL  {repo}  [dry-run] -> {target}")
            elif resolver_accepts(root_fd):  # single source of truth confirms it took
                print(f"{status:<12}  {repo}  -> {target}")
            else:
                # Resolver rejects. If WE just created the marker, roll it back (via the
                # SAME sd_fd) so a transient resolver failure cannot become a silent opt-in
                # later; a pre-existing (ALREADY) marker is the operator's — leave it.
                if status == "ENROLLED" and not remove_marker(sd_fd):
                    # Rollback failed — the marker we created is still there and could be
                    # accepted once a transient rejection clears. Make that LOUD.
                    print(f"SKIPPED       {repo}  (resolver rejected the marker AND rollback FAILED — remove {target} MANUALLY)")
                else:
                    print(f"SKIPPED       {repo}  (resolver rejects the marker — tracked/repo-controlled or resolver unavailable; inspect {root}/{STATE_DIR})")
                any_skipped = True
        finally:
            if sd_fd is not None:
                try:
                    os.close(sd_fd)
                except OSError:
                    pass
            try:
                os.close(root_fd)
            except OSError:
                pass
    return 1 if any_skipped else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
