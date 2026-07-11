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
  * The write path is opened component-by-component with openat + O_NOFOLLOW
    (os.open(dir_fd=...)), so an intermediate symlink-swap TOCTOU on <STATE_DIR> or
    the marker cannot redirect the write outside the resolved repo root. This is the
    guarantee portable bash could not give — the reason #314 deferred this enroller.
  * No redirection, BY CONSTRUCTION: the marker is always written under the operator's
    EXPLICIT path (realpath'd), opened component-by-component with openat + O_NOFOLLOW.
    git is used only to VALIDATE that path is a main worktree root — never to CHOOSE
    the write target — so a forged `.git` gitfile (which could make `git -C repo`
    resolve ANOTHER repo) can at most cause a wrong skip/accept decision, never send
    the marker to a repo the operator did not name. Only explicit paths are accepted
    (no globbing/auto-discovery). Every git invocation also runs with the
    repo-discovery environment scrubbed (GIT_DIR / GIT_WORK_TREE / GIT_COMMON_DIR / …
    — the set the resolver unsets internally), so a committed .claude/settings.json
    `env` block cannot redirect discovery either.
  * Residuals (accepted, operator-machine-local — the threat model per ADR 0012 is the
    operator running this over THEIR OWN repos, not untrusted PR content; the resolver
    is the piece that faces untrusted content and holds by construction):
      - The operator's own named path being swapped between realpath and open lands the
        marker at that path's current contents — but never at a DIFFERENT path than the
        one named, and enabling advisory-downgrade on a repo grants nothing (it never
        opens the merge gate; the operator can opt in any repo trivially).
      - PATH / BASH_ENV poisoning: a committed settings.json `env` block can prepend
        PATH, and git/bash are invoked by name. We prefer trusted system dirs
        (/usr/bin, /bin), defeating the naive prepend, but a fully poisoned session
        PATH is the session-wide residual ADR 0016 accepts as outside the (server-side)
        merge-security boundary — the resolver and gates call bare `git` too.
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
RESOLVER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "advisory-downgrade-optin.sh")

# Scrub git repo-discovery vars (the set the resolver unsets internally) from the
# environment handed to every git/resolver subprocess: a committed
# .claude/settings.json `env` block could otherwise set GIT_DIR / GIT_WORK_TREE / …
# to redirect discovery at another checkout and plant the marker there.
_GIT_DISCOVERY_VARS = (
    "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM", "GIT_NAMESPACE",
    "GIT_CONFIG", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_COUNT",
)
_CLEAN_ENV = {k: v for k, v in os.environ.items() if k not in _GIT_DISCOVERY_VARS}
# Prefer trusted system locations for `git`/`bash` so a repo-prepended PATH (a
# committed .claude/settings.json `env` block) cannot shadow them with a planted
# binary. Reduces — does not eliminate — PATH poisoning; the broader PATH/BASH_ENV
# lever is the session-wide residual ADR 0016 accepts (outside the merge-security
# boundary), not unique to this tool. rstrip avoids a trailing empty entry (== CWD).
_CLEAN_ENV["PATH"] = os.pathsep.join(["/usr/bin", "/bin", _CLEAN_ENV.get("PATH", "")]).rstrip(os.pathsep)


def git_out(cwd, *args):
    """`git -C <cwd> <args>` stdout on success, else None (fail-closed). Runs with
    the repo-discovery environment scrubbed (see _CLEAN_ENV)."""
    try:
        r = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True,
                           check=False, env=_CLEAN_ENV)
    except OSError:
        return None
    return r.stdout if r.returncode == 0 else None


def git_rc(cwd, *args):
    """git's exit code, or None if git couldn't run at all. Lets callers distinguish a
    real answer (0 / 1) from a repository/exec error (>=2, or None), which stdout-only
    git_out() cannot — needed to fail CLOSED on errors rather than read them as 'no'."""
    try:
        return subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True,
                              check=False, env=_CLEAN_ENV).returncode
    except OSError:
        return None


def main_root(repo):
    """Return the operator's EXPLICIT path (realpath'd) IFF it is the MAIN worktree
    root of a git repository; else None (fail closed).

    The returned path is the operator's OWN path — git is used only to VALIDATE it,
    never to CHOOSE the write target. Every caller anchors the marker under this
    returned path, so a forged `.git` gitfile (which could make `git -C repo` resolve
    ANOTHER repository) can at most cause a wrong skip/accept decision — it can NEVER
    redirect the marker into a repo the operator did not name. That closes the
    redirection class by construction, without trusting any git-reported path.

    Consent is read at the MAIN worktree root, so a linked worktree or a subdirectory
    is rejected (the operator must name the main root)."""
    repo_real = os.path.realpath(repo)
    top = git_out(repo_real, "rev-parse", "--show-toplevel")
    if top is None or os.path.realpath(top.strip()) != repo_real:
        return None  # not a work-tree ROOT (subdir, non-repo, or unresolvable) → fail closed
    # MAIN worktree iff git-dir == git-common-dir. A LINKED worktree's git-dir is
    # <main>/.git/worktrees/<name> while its common-dir is <main>/.git, so they differ.
    # This is robust to `git init --separate-git-dir` (where `worktree list` reports the
    # separate git dir, not the checkout) — matching how the resolver resolves the main
    # root, so the enroller stays consistent with the authority it delegates to.
    gd = git_out(repo_real, "rev-parse", "--path-format=absolute", "--git-dir")
    gcd = git_out(repo_real, "rev-parse", "--path-format=absolute", "--git-common-dir")
    if gd is None or gcd is None:
        return None
    if os.path.realpath(gd.strip()) != os.path.realpath(gcd.strip()):
        return None  # linked worktree — consent is read at the main root; name that instead
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


def place_marker(root, dry_run):
    """Place the marker under <root>/<STATE_DIR> via openat + O_NOFOLLOW.
    Returns (status, detail). Status ∈ {ENROLLED, ALREADY, WOULD-ENROLL, SKIPPED}."""
    root_fd = open_dir_nofollow(root)  # symlink-free walk, anchored on the operator's path
    try:
        if not dry_run:
            try:
                os.mkdir(STATE_DIR, 0o755, dir_fd=root_fd)
            except FileExistsError:
                pass
        try:
            sd_fd = os.open(STATE_DIR, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
        except FileNotFoundError:
            return ("WOULD-ENROLL", None)  # dry-run: state dir not created yet
        except OSError as e:
            return ("SKIPPED", f"{STATE_DIR} is a symlink or not a directory ({e.strerror})")
        try:
            # Inspect the existing marker without following a symlink (fstatat NOFOLLOW).
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
            # Create atomically, never following a final-component symlink. A failure
            # from EITHER the write OR the close (e.g. EIO) must leave nothing behind —
            # a half-written/regular marker still reads as a valid opt-in the resolver
            # would ACCEPT, so a SKIPPED report must not sit over a live marker.
            fd = os.open(MARKER, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644, dir_fd=sd_fd)
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
                    # Rollback of the just-created marker failed — it may still be a
                    # valid opt-in. Say so LOUDLY rather than claim it was removed.
                    detail = (f"write failed AND rollback FAILED — remove the marker under "
                              f"{STATE_DIR}/ MANUALLY ({err.strerror})")
                return ("SKIPPED", detail)
            return ("ENROLLED", None)
        finally:
            # The marker fd was already written+closed above (its close failure is
            # handled there). A failure closing these read-only DIRECTORY fds does not
            # affect the on-disk marker, so swallow it — otherwise it would override a
            # successful ENROLLED return with an exception, and main() would report a
            # bare filesystem-error SKIPPED WITHOUT rolling back the live marker.
            try:
                os.close(sd_fd)
            except OSError:
                pass
    finally:
        try:
            os.close(root_fd)
        except OSError:
            pass


def resolver_accepts(root):
    """Delegate acceptance to the resolver (single source of truth). Run it from the
    resolved root so its git/CWD lookup matches. The resolver's contract is "print 0/1,
    ALWAYS exit 0", so a nonzero exit (crash, signal after flushing stdout) means it
    malfunctioned — fail CLOSED and do not trust the printed verdict. True iff exit 0
    AND stdout is `1`."""
    try:
        r = subprocess.run(["bash", RESOLVER], cwd=root, capture_output=True, text=True,
                           check=False, env=_CLEAN_ENV)
    except OSError:
        return False
    return r.returncode == 0 and r.stdout.strip() == "1"


def remove_marker(root):
    """Roll back a marker WE just created (openat + O_NOFOLLOW, same anchoring as the
    write). Returns True iff the marker is gone afterward (removed or already absent),
    False if it may still exist — so the caller can surface a LOUD manual-cleanup
    warning instead of a SKIPPED that silently sits over a live opt-in marker."""
    try:
        root_fd = open_dir_nofollow(root)
    except OSError:
        return False
    try:
        try:
            sd_fd = os.open(STATE_DIR, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
        except FileNotFoundError:
            return True  # state dir gone → marker gone
        except OSError:
            return False
        try:
            os.unlink(MARKER, dir_fd=sd_fd)
            return True
        except FileNotFoundError:
            return True  # already absent
        except OSError:
            return False
        finally:
            try:
                os.close(sd_fd)
            except OSError:
                pass
    finally:
        try:
            os.close(root_fd)
        except OSError:
            pass


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
        try:
            status, detail = place_marker(root, dry_run)
        except OSError as e:  # fail-closed per target; keep going for the rest
            print(f"SKIPPED       {repo}  (filesystem error: {e.strerror})")
            any_skipped = True
            continue
        target = f"{root}/{STATE_DIR}/{MARKER}"
        if status == "SKIPPED":
            print(f"SKIPPED       {repo}  ({detail})")
            any_skipped = True
        elif dry_run:
            # Predict honestly: consult the resolver for an existing marker, and for an
            # absent one check whether the PATH is already tracked (index/HEAD) — a real
            # run would create the file but the resolver would then reject it.
            if status == "ALREADY":
                if resolver_accepts(root):
                    print(f"ALREADY       {repo}  (opted-in) -> {target}")
                else:
                    print(f"WOULD-SKIP    {repo}  (marker present but resolver rejects it — tracked/repo-controlled)")
                    any_skipped = True
            elif marker_repo_tracked(root):  # WOULD-ENROLL path, but the path is tracked
                print(f"WOULD-SKIP    {repo}  (marker path is tracked in index/HEAD — resolver would reject a real run)")
                any_skipped = True
            else:
                print(f"WOULD-ENROLL  {repo}  [dry-run] -> {target}")
        elif resolver_accepts(root):  # single source of truth confirms it took
            print(f"{status:<12}  {repo}  -> {target}")
        else:
            # Resolver rejects. If WE just created the marker, roll it back so a
            # transient resolver failure cannot become a silent opt-in later; a
            # pre-existing (ALREADY) marker is the operator's — leave it untouched.
            if status == "ENROLLED" and not remove_marker(root):
                # Rollback failed — the marker we created is still there and could be
                # accepted once a transient rejection clears. Make that LOUD, not silent.
                print(f"SKIPPED       {repo}  (resolver rejected the marker AND rollback FAILED — remove {target} MANUALLY)")
            else:
                print(f"SKIPPED       {repo}  (resolver rejects the marker — tracked/repo-controlled or resolver unavailable; inspect {root}/{STATE_DIR})")
            any_skipped = True
    return 1 if any_skipped else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
