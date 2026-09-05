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

SNAP_ROOT="$HOOK_DIR/.busdriver-gates"

# Snapshots are never deleted, so BOUND the pile instead of letting it grow
# without limit. Past the ceiling this refuses and names the remedy. A refusal
# is safe exactly where a sweep is not: nothing is deleted, and the wrappers
# already installed keep working because they point at a snapshot this run
# never touched (tests/test-install-git-hooks.sh proves a refused install
# leaves working hooks intact). What it must NOT tell the operator to do is
# clear the whole directory -- that takes the live snapshots too, and until an
# install succeeds again every ref update in the repo aborts, including the
# commit needed to fix whatever made the rerun fail. So the remedy names the
# inert entries only, and prints no command to paste: a hooks path may legally
# contain a space, a bracket or an apostrophe, and an unquoted `rm -rf` handed
# to an operator is the same escaping bug this branch removes elsewhere.
# The count is read before the snapshot is created, so two installers racing in
# one hooks directory can both pass at 99 and land 101. That is deliberate: the
# overshoot is bounded by the number of concurrent installers, the next install
# refuses anyway, and nothing here grows without limit -- which is the property
# being bought. A lock would buy exactness for a single-operator repo that does
# not run concurrent installs, and this file already declined that trade once.
# ponytail: fixed ceiling, ~180 MB of snapshots; make it a flag if anyone asks.
SNAP_MAX=100
if [[ -d "$SNAP_ROOT" ]]; then
    snap_count=$(find "$SNAP_ROOT" -mindepth 1 -maxdepth 1 | wc -l)
    if (( snap_count >= SNAP_MAX )); then
        {
            printf 'install-git-hooks: %q holds %d snapshots (ceiling %d).\n' \
                "$SNAP_ROOT" "$snap_count" "$SNAP_MAX"
            printf 'Superseded snapshots are never deleted. Remove the inert ones -- every\n'
            printf 'entry in that directory that NO installed wrapper names on its exec\n'
            printf 'line. Check all six wrappers, not one: an interrupted install can leave\n'
            printf 'them split across two snapshots, and both are live. Do this only when\n'
            printf 'NO hooks are running: one that started earlier read an older wrapper and\n'
            printf 'is still about to exec the snapshot it names. Then rerun this installer.\n'
            printf 'Do NOT remove the directory itself. That takes the LIVE snapshot with\n'
            printf 'it, and until an install succeeds again every wrapper execs a missing\n'
            printf 'file, which at the reference-transaction prepared phase aborts every ref\n'
            printf 'update in the repo -- including the commits you would need to fix it.\n'
        } >&2
        exit 1
    fi
fi

# Exec the bytes we verified. The digest above proves the live tree is intact
# at check time, but the wrapper then re-opens the gate BY PATHNAME — a writer
# racing that window executes bytes the digest never saw. So keep a private
# snapshot under HOOK_DIR, which the containment check above already proved a
# merge cannot reach, and exec from there: verified bytes and executed bytes
# become the same bytes. The live-tree digest still runs first, so a stale
# install fails LOUD instead of silently running the old snapshot. Sourced
# libs and any bytecode they generate resolve inside the snapshot too, which
# is why the digest no longer has to purge __pycache__ from the live tree.
# Each install gets its OWN snapshot directory, and the wrapper it generates
# hard-codes that exact path -- so a snapshot is only ever created, never
# replaced. Replacing one is what forces a gap: POSIX rename cannot atomically
# overwrite a non-empty directory, so every ordering (delete-then-rename,
# rename-aside-then-rename) leaves a window in which the path the INSTALLED
# wrappers already point at does not exist. Creating under a fresh name has no
# such window: the old snapshot stays intact and in use until its wrapper is
# overwritten, and nothing deletes it afterwards.


SNAP_NAME=$(python3 -I -S - "$GATE_DIR" "$SNAP_ROOT" "$GATE_DIGEST" "$GATE_DIGEST_PY" <<'PY'
import os
import shutil
import subprocess
import sys
import tempfile

src, root, digest, digest_py = sys.argv[1:5]
os.makedirs(root, exist_ok=True)

if os.path.islink(root):
    sys.stderr.write(
        "install-git-hooks: %s is a symlink.\n"
        "The snapshot must live inside the hooks directory -- that containment\n"
        "is what keeps a merge from reaching it. Remove it and rerun.\n" % root)
    raise SystemExit(1)


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
# ALWAYS rebuild. There used to be a "reuse it if it already hashes right"
# branch here, and every form of it was the same defect: deciding to trust a
# directory this process did not create means checking it and then using it,
# and any pathname between those two steps can be swapped for a symlink to a
# tree that hashes correctly. Removing the decision removes the race -- and
# costs one copy of ~30 small files per install, which is not worth defending
# against. What gets verified is the copy WE just made, under a name only this
# process uses, before it is renamed into place.
# mkdtemp reserves the name ATOMICALLY (O_EXCL), so it is unique against every
# other installer and against this directory's own history. A pid is not --
# pids are recycled, and a name colliding with the snapshot the INSTALLED
# wrappers already point at would overwrite the tree they are about to exec.
snap = tempfile.mkdtemp(prefix=digest + ".", dir=root)
snap_name = os.path.basename(snap)
# Copy INTO the reserved directory rather than removing it first: an rmdir
# would hand the name back, and between that and copytree another writer could
# claim it -- which is the whole property mkdtemp was used for.
# Anything that goes wrong from here leaves a half-built tree behind, and
# since superseded snapshots are never swept there is nothing to collect it
# later -- a repeatable failure would add ~2 MB per attempt. Removing it is
# safe in a way removing a SUPERSEDED snapshot never is: mkdtemp made this
# directory, this process is the only thing that knows its name, and no
# wrapper points at it until one is generated below.
try:
    shutil.copytree(src, snap, ignore=shutil.ignore_patterns("__pycache__"),
                    dirs_exist_ok=True)
    # Verify the copy WE just made: hashing the live tree and copying it are
    # two reads of two different moments, and only this proves the bytes about
    # to be pinned are the bytes that were hashed.
    if digest_of(snap) != digest:
        sys.stderr.write(
            "install-git-hooks: the gate tree changed while it was being copied.\n"
            "Refusing to pin hooks to bytes nothing verified. Rerun when the tree\n"
            "is settled.\n")
        raise SystemExit(1)
except BaseException:
    shutil.rmtree(snap, ignore_errors=True)
    raise
sys.stdout.write(snap_name)
PY
) || exit 1
SNAP="$SNAP_ROOT/$SNAP_NAME"
if [[ -z "$SNAP_NAME" || ! -d "$SNAP" ]]; then
    printf 'install-git-hooks: snapshot was not created under %s\n' "$SNAP_ROOT" >&2
    exit 1
fi

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

# Superseded snapshots are left in place. Removing one is the only
# destructive thing this installer could do, and it can never be proven
# safe: a hook that already read its wrapper is about to exec the snapshot
# that wrapper names, and no design short of refcounting every hook knows
# whether one is in flight. Each is ~2 MB of inert shell that nothing points
# at once its wrapper is overwritten, so any entry below OTHER than the one the
# wrappers name can be deleted by hand when no hooks are running -- all six
# wrappers, since an interrupted install can leave them split across two live
# snapshots. Never the whole directory: that takes the live ones too, leaving
# every wrapper
# exec-ing a missing file -- and at the reference-transaction `prepared` phase
# that aborts every ref update in the repo until an install succeeds again.
# The pile cannot grow without limit: the ceiling above refuses first.
printf 'install-git-hooks: gate snapshots live in %s (old ones are inert).\n' \
    "$SNAP_ROOT"
