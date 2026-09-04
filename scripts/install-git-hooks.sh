#!/bin/bash -p
# Install native Git hooks that enforce busdriver review gates inside a repo.
#
# Usage:
#   bash scripts/install-git-hooks.sh [REPO_ROOT]
#
# Installs (into the repo's effective hooks directory):
#   pre-merge-commit       → hooks/gate-scripts/pre-merge-commit-gate.sh
#   post-merge             → hooks/gate-scripts/post-merge-consume-marker.sh
#   pre-commit             → hooks/gate-scripts/merge-pre-commit-gate.sh
#                            (MERGE_HEAD only — merge --no-commit → git commit)
#   prepare-commit-msg     → hooks/gate-scripts/merge-prepare-commit-msg-gate.sh
#   reference-transaction  → hooks/gate-scripts/merge-reference-transaction-gate.sh
#   post-commit            → hooks/gate-scripts/merge-post-commit-consume.sh
#
# Resolves the effective hooks directory via `git config --path core.hooksPath`
# when set (pathname-expanded), otherwise `git rev-parse --git-path hooks`
# (worktree-safe). Refuses to overwrite a non-Busdriver hook without --force.
# `--no-verify` skips pre-commit / commit-msg / pre-merge-commit verification
# hooks; prepare-commit-msg and reference-transaction still run. Agent-layer
# PreToolUse gates block bypass paths where applicable.

set -euo pipefail
unset BASH_ENV ENV
export PATH=/usr/bin:/bin

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORCE=false
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=true ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done
REPO_ROOT="${POSITIONAL[0]:-$(git -C "${PWD}" rev-parse --show-toplevel 2>/dev/null || true)}"

if [[ -z "$REPO_ROOT" ]]; then
    printf 'install-git-hooks: target is not a git repository: %s\n' "${REPO_ROOT:-<unset>}" >&2
    exit 1
fi
if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'install-git-hooks: target is not a git repository: %s\n' "$REPO_ROOT" >&2
    exit 1
fi

if git -C "$REPO_ROOT" config --get core.hooksPath >/dev/null 2>&1; then
    HOOK_DIR=$(
        python3 -I -S -c '
import subprocess, sys
r = subprocess.run(
    ["git", "-C", sys.argv[1], "config", "--path", "--get", "core.hooksPath"],
    capture_output=True,
)
if r.returncode != 0:
    sys.exit(r.returncode)
b = r.stdout
if b.endswith(b"\n"):
    b = b[:-1]
sys.stdout.buffer.write(b)
' "$REPO_ROOT"
        printf x
    ) || {
        printf 'install-git-hooks: failed to read core.hooksPath\n' >&2
        exit 1
    }
    HOOK_DIR=${HOOK_DIR%x}
    if [[ -z "$HOOK_DIR" || "$HOOK_DIR" == *$'\n'* || "$HOOK_DIR" == *$'\r'* ]]; then
        printf 'install-git-hooks: core.hooksPath is set but empty or invalid\n' >&2
        exit 1
    fi
else
    HOOK_DIR=$(git -C "$REPO_ROOT" rev-parse --git-path hooks)
fi
# Make absolute when relative (worktree / linked / core.hooksPath cases)
if [[ "$HOOK_DIR" != /* ]]; then
    HOOK_DIR="$REPO_ROOT/$HOOK_DIR"
fi

# Digest the gate-script closure. Embedded verbatim in every installed wrapper,
# so it lives OUTSIDE the worktree it checks — a merge cannot rewrite the check
# along with the scripts it checks.
#
# It PURGES source-adjacent bytecode rather than exempting it. An UNCHECKED
# hash-based .pyc runs in place of its .py without Python reading the source at
# all (measured: source says SOURCE, interpreter prints HOSTILE-BYTECODE), and
# the gates import merge_pending / audit_append / skip_age through the ordinary
# import machinery under `python3 -I`, which ignores PYTHON* env vars — so
# neither PYTHONPYCACHEPREFIX nor PYTHONDONTWRITEBYTECODE can redirect the
# lookup from out here. Purging costs one recompile per gate run and makes the
# exemption unnecessary: what executes is the source that was digested.
GATE_DIGEST_PY='import hashlib,os,sys
base=sys.argv[1]
if not os.path.isdir(base):
    sys.stderr.write("busdriver: gate directory missing: %s\n"%base)
    raise SystemExit(1)
h=hashlib.sha256()
names=[]
for dp,dns,fns in os.walk(base):
    for d in list(dns):
        q=os.path.join(dp,d)
        if os.path.islink(q):
            sys.stderr.write("busdriver: symlinked directory under gate-scripts: %s\n"%q)
            raise SystemExit(1)
        if d=="__pycache__":
            dns.remove(d)
    for fn in fns:
        names.append(os.path.relpath(os.path.join(dp,fn),base))
if not names:
    sys.stderr.write("busdriver: no gate scripts under %s\n"%base)
    raise SystemExit(1)
names.sort()
for r in names:
    q=os.path.join(base,r)
    if os.path.islink(q) or not os.path.isfile(q):
        sys.stderr.write("busdriver: not a regular file: %s\n"%q)
        raise SystemExit(1)
    with open(q,"rb") as f:
        d=hashlib.sha256(f.read()).hexdigest()
    h.update(r.encode("utf-8")+b"\0"+d.encode("ascii")+b"\0")
got=h.hexdigest()
if len(sys.argv)<3:
    sys.stdout.write(got)
    raise SystemExit(0)
if got!=sys.argv[2]:
    sys.stderr.write("busdriver: gate scripts changed since these hooks were installed.\n  expected %s\n  found    %s\nRerun: bash scripts/install-git-hooks.sh\nRefusing to run a gate this repo could have rewritten.\n"%(sys.argv[2],got))
    raise SystemExit(1)
'

# The wrapper is only trustworthy if a merge cannot rewrite IT. A core.hooksPath
# aimed at tracked content (.githooks/, say) would let hostile branch content
# replace the wrapper before pre-merge-commit or reference-transaction runs, so
# the embedded digest check would never execute at all. Inside the git dir is
# safe (git never lands tree content there); wholly outside the work tree is
# safe. Inside the work tree but outside the git dir is the bypass.
GIT_DIR_ABS=$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir 2>/dev/null) || GIT_DIR_ABS=""
if [[ -z "$GIT_DIR_ABS" ]]; then
    printf 'install-git-hooks: cannot resolve the git directory for %s\n' "$REPO_ROOT" >&2
    exit 1
fi
python3 -I -S -c '
import os,sys
raw,wt,gd=sys.argv[1:4]
wt,gd=os.path.realpath(wt),os.path.realpath(gd)
def key(p):
    try:
        st=os.stat(p)
    except OSError:
        return None
    return (st.st_dev,st.st_ino)
def inside(child,parent):
    # Identity by (dev,ino), not by string prefix. macOS volumes are
    # case-INSENSITIVE by default while realpath() preserves whatever spelling
    # it was handed, so /repo/.githooks and /REPO/.githooks are one directory
    # that no string prefix relates. Walking up by dirname and comparing inodes
    # reads the filesystem the way git will. A component that does not exist
    # yet has no inode, so the string equality below still carries the tail.
    pk=key(parent)
    c=child
    while True:
        if pk is not None and key(c)==pk:
            return True
        if c==parent:
            return True
        nxt=os.path.dirname(c)
        if nxt==c:
            return False
        c=nxt
def bad(path):
    return inside(path,wt) and not inside(path,gd)
# Walk the path one component at a time, each against a REALPATH-resolved
# parent. Resolving the whole path in one go is not enough: an in-worktree
# symlink (.githooks -> /somewhere/outside) resolves outside and would pass,
# but the symlink itself is tracked content, so a merge can replace it with a
# real directory of hostile hooks that git uses INSTEAD of our wrapper. The
# walk tests each component where it actually LIVES, so a replaceable component
# is caught at any depth, and resolving the parent keeps the comparison honest
# on platforms where the work tree itself sits behind a link (macOS /var).
hook=os.path.abspath(raw)
parts=hook.split(os.sep)[1:]
cur=os.sep
escape=False
for i,part in enumerate(parts):
    cand=os.path.join(cur,part)
    last=(i==len(parts)-1)
    # Traversing THROUGH an ancestor of the git dir is fine — the walk has to
    # pass the work tree root to reach .git/hooks, and a merge cannot replace
    # the root or .git itself. The DESTINATION is always checked, so
    # core.hooksPath pointing at the work tree root is still refused.
    if (last or not inside(gd,cand)) and bad(cand):
        escape=True
        break
    cur=os.path.realpath(cand)
# And check where the final component actually LANDS: a hooks dir inside .git
# may itself be a symlink into tracked content.
if not escape and bad(cur):
    escape=True
if escape:
    sys.stderr.write("install-git-hooks: refusing to install into %s\n" % hook)
    sys.stderr.write("  That directory is inside the work tree, so a merge can replace the\n")
    sys.stderr.write("  hook wrapper itself before the gate runs and the digest check would\n")
    sys.stderr.write("  never execute. Point core.hooksPath outside the work tree, or unset\n")
    sys.stderr.write("  it to use the default hooks directory inside .git.\n")
    raise SystemExit(1)
raise SystemExit(0)
' "$HOOK_DIR" "$REPO_ROOT" "$GIT_DIR_ABS" || exit 1

GATE_DIR="$PLUGIN_ROOT/hooks/gate-scripts"
GATE_DIGEST=$(python3 -I -S -c "$GATE_DIGEST_PY" "$GATE_DIR") || {
    printf 'install-git-hooks: could not digest %s\n' "$GATE_DIR" >&2
    exit 1
}

install_one() {
    local hook_name="$1"
    local gate_src="$2"
    local gate_exec="$SNAP/${gate_src##*/}"
    local hook_path="$HOOK_DIR/$hook_name"
    local sig='# Installed by busdriver scripts/install-git-hooks.sh'

    mkdir -p "$HOOK_DIR"
    python3 -I -S - "$HOOK_DIR" "$hook_name" "$hook_path" "$sig" "$PLUGIN_ROOT" "$gate_exec" \
        "$GATE_DIR" "$GATE_DIGEST" "$GATE_DIGEST_PY" <<'PY'
import os
import shlex
import stat
import sys
import tempfile

hook_dir, hook_name, hook_path, sig, plugin_root, gate_exec = sys.argv[1:7]
gate_dir, gate_digest, digest_py = sys.argv[7:10]
body = (
    "#!/bin/bash -p\n"
    f"{sig} — do not edit by hand.\n"
    "unset BASH_ENV ENV\n"
    "export PATH=/usr/bin:/bin\n"
    f"export CLAUDE_PLUGIN_ROOT={shlex.quote(plugin_root)}\n"
    f"export BUSDRIVER_PLUGIN_ROOT={shlex.quote(plugin_root)}\n"
    # Verify the gate closure BEFORE exec. pre-merge-commit and
    # reference-transaction run AFTER git has updated the worktree, so without
    # this the merge being gated supplies the gate's own code.
    "python3 -I -S -c "
    + shlex.quote(digest_py)
    + " "
    + shlex.quote(gate_dir)
    + " "
    + shlex.quote(gate_digest)
    + " || exit 1\n"
    # Long options MUST precede short ones: bash 3.2 (macOS /bin/bash)
    # rejects `-p --noprofile` with "--: invalid option" and exit 2 — which
    # at reference-transaction `prepared` aborts EVERY ref transaction.
    "exec /bin/bash --noprofile --norc -p "
    + shlex.quote(gate_exec)
    + ' "$@"\n'
).encode("utf-8")
fd, tmp = tempfile.mkstemp(prefix=f".busdriver-{hook_name}.", dir=hook_dir)
try:
    off = 0
    while off < len(body):
        wrote = os.write(fd, body[off:])
        if wrote == 0:
            raise OSError("short write")
        off += wrote
    os.fchmod(fd, stat.S_IRWXU | stat.S_IRGRP | stat.S_IXGRP | stat.S_IROTH | stat.S_IXOTH)
finally:
    os.close(fd)
try:
    os.replace(tmp, hook_path)
except OSError:
    os.unlink(tmp)
    raise
PY
    printf 'Installed %s → %s\n' "$hook_name" "$hook_path"
}

preflight_install() {
    local sig='# Installed by busdriver scripts/install-git-hooks.sh'
    local spec hook_name gate_src hook_path
    # Publication gate first in preflight + install so a partial install still
    # blocks unreviewed merge tips even if --no-verify skips pre-merge-commit.
    for spec in \
        "reference-transaction:$PLUGIN_ROOT/hooks/gate-scripts/merge-reference-transaction-gate.sh" \
        "prepare-commit-msg:$PLUGIN_ROOT/hooks/gate-scripts/merge-prepare-commit-msg-gate.sh" \
        "pre-merge-commit:$PLUGIN_ROOT/hooks/gate-scripts/pre-merge-commit-gate.sh" \
        "post-merge:$PLUGIN_ROOT/hooks/gate-scripts/post-merge-consume-marker.sh" \
        "pre-commit:$PLUGIN_ROOT/hooks/gate-scripts/merge-pre-commit-gate.sh" \
        "post-commit:$PLUGIN_ROOT/hooks/gate-scripts/merge-post-commit-consume.sh"
    do
        hook_name="${spec%%:*}"
        gate_src="${spec#*:}"
        hook_path="$HOOK_DIR/$hook_name"
        if [[ ! -f "$gate_src" ]]; then
            printf 'install-git-hooks: gate script missing: %s\n' "$gate_src" >&2
            exit 1
        fi
        if [[ -e "$hook_path" || -L "$hook_path" ]]; then
            if ! grep -qF "$sig" "$hook_path" 2>/dev/null; then
                if [[ "$FORCE" != true ]]; then
                    printf 'install-git-hooks: refusing to overwrite non-Busdriver %s (%s). Re-run with --force to replace.\n' \
                        "$hook_name" "$hook_path" >&2
                    exit 1
                fi
            fi
        fi
    done
}

preflight_install

# Exec the bytes we verified. The digest above proves the live tree is intact
# at check time, but the wrapper then re-opens the gate BY PATHNAME — a writer
# racing that window executes bytes the digest never saw. So keep a private
# snapshot under HOOK_DIR, which the containment check above already proved a
# merge cannot reach, and exec from there: verified bytes and executed bytes
# become the same bytes. The live-tree digest still runs first, so a stale
# install fails LOUD instead of silently running the old snapshot. Sourced
# libs and any bytecode they generate resolve inside the snapshot too, which
# is why the digest no longer has to purge __pycache__ from the live tree.
# Built AFTER preflight: pruning superseded snapshots is destructive, and a
# preflight that then refuses (a non-Busdriver hook, no --force) would leave
# the already-installed wrappers pointing at a snapshot this run deleted.
SNAP_ROOT="$HOOK_DIR/.busdriver-gates"
SNAP="$SNAP_ROOT/$GATE_DIGEST"
python3 -I -S - "$GATE_DIR" "$SNAP_ROOT" "$GATE_DIGEST" "$GATE_DIGEST_PY" <<'PY' || exit 1
import os
import shutil
import subprocess
import sys

src, root, digest, digest_py = sys.argv[1:5]
snap = os.path.join(root, digest)
os.makedirs(root, exist_ok=True)

def rm_any(path):
    """Remove `path` without ever following it out of `root`."""
    if os.path.islink(path):
        os.unlink(path)
    elif os.path.isdir(path):
        shutil.rmtree(path, ignore_errors=True)
    elif os.path.exists(path):
        os.unlink(path)


def check_root(root):
    # Refuse a symlinked snapshot root. Pruning recursively deletes every entry
    # under it that is not the current digest, so following a link here turns a
    # hook install into an rm -rf of whatever it points at. The same reasoning
    # applies to each entry, which is why rm_any unlinks rather than descends.
    if os.path.islink(root):
        sys.stderr.write(
            "install-git-hooks: %s is a symlink. The snapshot root is pruned\n"
            "recursively, so following it would delete the target's contents.\n"
            "Remove it and rerun.\n" % root)
        raise SystemExit(1)


check_root(root)
if os.path.islink(snap):
    os.unlink(snap)


def digest_of(path):
    """Run the wrapper's own digest program over `path`."""
    out = subprocess.run([sys.executable, "-I", "-S", "-c", digest_py, path],
                         stdout=subprocess.PIPE)
    return out.stdout.decode("utf-8") if out.returncode == 0 else None


# Verify the COPY, never just the source it was made from. Hashing the live
# tree and then copying it are two reads of two different moments: a writer
# racing between them can put unverified bytes in the snapshot and restore the
# live tree, and the wrapper would exec what nothing checked. Re-hashing the
# copy is also what makes a snapshot dir that ALREADY exists safe to reuse --
# the path is named by a digest, but until this runs nothing has confirmed its
# contents match that name.
for attempt in range(3):
    if os.path.isdir(snap) and digest_of(snap) == digest:
        break
    tmp = snap + ".tmp.%d" % os.getpid()
    rm_any(tmp)
    # Build under a temp name and rename, so a snapshot dir named by a digest
    # is never half-populated: the wrapper's exec target either is not there
    # or is complete.
    shutil.copytree(src, tmp, ignore=shutil.ignore_patterns("__pycache__"))
    rm_any(snap)
    os.rename(tmp, snap)
else:
    sys.stderr.write(
        "install-git-hooks: snapshot under %s does not match the digest it is\n"
        "named by, after 3 attempts. The gate tree is being written while this\n"
        "installer runs. Refusing to pin hooks to bytes nothing verified.\n" % root)
    raise SystemExit(1)
PY

install_one reference-transaction \
    "$PLUGIN_ROOT/hooks/gate-scripts/merge-reference-transaction-gate.sh"
install_one prepare-commit-msg \
    "$PLUGIN_ROOT/hooks/gate-scripts/merge-prepare-commit-msg-gate.sh"
install_one pre-merge-commit \
    "$PLUGIN_ROOT/hooks/gate-scripts/pre-merge-commit-gate.sh"
install_one post-merge \
    "$PLUGIN_ROOT/hooks/gate-scripts/post-merge-consume-marker.sh"
install_one pre-commit \
    "$PLUGIN_ROOT/hooks/gate-scripts/merge-pre-commit-gate.sh"
install_one post-commit \
    "$PLUGIN_ROOT/hooks/gate-scripts/merge-post-commit-consume.sh"

# Only now that every wrapper is in place, drop snapshots from earlier installs.
# Pruning is the one destructive step here, so it goes AFTER the commit point:
# doing it up front meant an install that failed or was interrupted partway
# left the PREVIOUS wrappers pointing at a snapshot this run had already
# deleted — fail-closed, but a brick that needs a reinstall to clear. Two
# installers racing in one plugin root can still prune each other's snapshots;
# they are named by digest, so the loser is fail-closed until rerun, and adding
# locking for a case a single-operator repo does not have is not worth it.
python3 -I -S - "$SNAP_ROOT" "$GATE_DIGEST" <<'PY' || exit 1
import os
import shutil
import sys

root, digest = sys.argv[1:3]

def rm_any(path):
    """Remove `path` without ever following it out of `root`."""
    if os.path.islink(path):
        os.unlink(path)
    elif os.path.isdir(path):
        shutil.rmtree(path, ignore_errors=True)
    elif os.path.exists(path):
        os.unlink(path)


def check_root(root):
    # Refuse a symlinked snapshot root. Pruning recursively deletes every entry
    # under it that is not the current digest, so following a link here turns a
    # hook install into an rm -rf of whatever it points at. The same reasoning
    # applies to each entry, which is why rm_any unlinks rather than descends.
    if os.path.islink(root):
        sys.stderr.write(
            "install-git-hooks: %s is a symlink. The snapshot root is pruned\n"
            "recursively, so following it would delete the target's contents.\n"
            "Remove it and rerun.\n" % root)
        raise SystemExit(1)


check_root(root)
for name in os.listdir(root):
    if name != digest:
        rm_any(os.path.join(root, name))
PY
