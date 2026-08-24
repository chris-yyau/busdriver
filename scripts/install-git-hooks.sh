#!/bin/bash -p
# Install native Git hooks that enforce busdriver review gates inside a repo.
#
# Usage:
#   bash scripts/install-git-hooks.sh [REPO_ROOT]
#
# Installs (into the repo's effective hooks directory):
#   pre-merge-commit  → hooks/gate-scripts/pre-merge-commit-gate.sh
#   post-merge        → hooks/gate-scripts/post-merge-consume-marker.sh
#   pre-commit        → hooks/gate-scripts/merge-pre-commit-gate.sh
#                       (MERGE_HEAD only — merge --no-commit → git commit)
#   post-commit       → hooks/gate-scripts/merge-post-commit-consume.sh
#
# Resolves hooks via `git rev-parse --git-path hooks` (worktree-safe) and honors
# core.hooksPath. Refuses to overwrite a non-Busdriver hook without --force.
# Native hooks are not invoked when Git suppresses hooks (--no-verify, alternate
# core.hooksPath). Agent-layer PreToolUse gates block those paths where applicable.

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

HOOK_DIR=$(git -C "$REPO_ROOT" rev-parse --git-path hooks)
# Make absolute when relative (worktree / linked cases)
if [[ "$HOOK_DIR" != /* ]]; then
    HOOK_DIR="$REPO_ROOT/$HOOK_DIR"
fi

install_one() {
    local hook_name="$1"
    local gate_src="$2"
    local hook_path="$HOOK_DIR/$hook_name"
    local sig='# Installed by busdriver scripts/install-git-hooks.sh'

    mkdir -p "$HOOK_DIR"
    python3 - "$HOOK_DIR" "$hook_name" "$hook_path" "$sig" "$PLUGIN_ROOT" "$gate_src" <<'PY'
import os
import shlex
import stat
import sys
import tempfile

hook_dir, hook_name, hook_path, sig, plugin_root, gate_src = sys.argv[1:7]
body = (
    "#!/bin/bash -p\n"
    f"{sig} — do not edit by hand.\n"
    "unset BASH_ENV ENV\n"
    "export PATH=/usr/bin:/bin\n"
    f"export CLAUDE_PLUGIN_ROOT={shlex.quote(plugin_root)}\n"
    f"export BUSDRIVER_PLUGIN_ROOT={shlex.quote(plugin_root)}\n"
    f"exec /bin/bash -p --noprofile --norc {shlex.quote(gate_src)}\n"
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
    for spec in \
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

install_one pre-merge-commit \
    "$PLUGIN_ROOT/hooks/gate-scripts/pre-merge-commit-gate.sh"
install_one post-merge \
    "$PLUGIN_ROOT/hooks/gate-scripts/post-merge-consume-marker.sh"
install_one pre-commit \
    "$PLUGIN_ROOT/hooks/gate-scripts/merge-pre-commit-gate.sh"
install_one post-commit \
    "$PLUGIN_ROOT/hooks/gate-scripts/merge-post-commit-consume.sh"
