#!/usr/bin/env bash
# gate-integrity.sh — content lock over the hook execution surface (#742).
#
# WHAT THIS CLOSES
# `tests/test-node-hook-containment.sh` pins the two plain-bash launcher
# registrations VERBATIM, which freezes the COMMAND and nothing else. Either
# launcher can grow a node dispatch without its registration changing:
#
#     # appended to hooks/gate-scripts/load-orchestrator.sh
#     node "$CLAUDE_PLUGIN_ROOT/scripts/hooks/blocking.js"
#
# The hook is then named nowhere in hooks.json, so the containment suite's
# wired-check skips it and stays green with an uncontained blocking hook
# running. Three in-suite fixes were built and refuted in #737: extracting the
# dispatched hook (defeated by `node ".../$hook"`), failing closed on any
# `node` mention (defeated by `no""de`), and pinning the launcher plus its
# three direct helpers by digest (correct, but the closure keeps going through
# lib/resolve-repo-dir.sh -> lib/marker_ops.py -> ...). The closure IS the
# directory, so pin the directory — a lockfile, not a heuristic net.
#
# WHAT IT GUARANTEES — AND WHAT IT DOES NOT
# This is VISIBILITY, not prevention, exactly like any dependency lockfile. It
# does not stop a malicious edit; anyone who can edit a gate script can also run
# `--update`. What it makes impossible is landing a gate-area edit WITHOUT a
# lockfile diff in the same commit: CI fails until the two agree, so every
# content change to the hook execution surface arrives in review as an explicit,
# named line rather than as a body change under an unchanged registration.
#
# SCOPE — two whole directories, no extension filter:
#   hooks/gate-scripts/**   every gate script and its lib/ helpers
#   scripts/hooks/**        every node hook AND run-with-flags-shell.sh, whose
#                           registration is likewise shape-pinned while its body
#                           is pinned by nothing — the same #742 gap one
#                           directory over
# hooks/hooks.json is deliberately NOT locked: the containment suite's shape
# allowlist already owns it, and double-controlling it is churn with no new
# invariant.
#
# COST, ON THE RECORD: 97 commits touched these two directories in the 90 days
# before this landed (~1/day). Each such commit now needs `--update` in the same
# commit. That deliberate maintenance IS the control.
#
#   ./scripts/gate-integrity.sh            # verify (default); rc 1 on mismatch
#   ./scripts/gate-integrity.sh --update   # regenerate the lock
#   ./scripts/gate-integrity.sh --root DIR # verify a tree other than this repo
#
# `--root` is argv, never an env var: an env-overridable root on integrity
# tooling is repo-injectable via a committed settings.json `env` block.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_NAME=".gate-integrity.lock"
LOCKED_DIRS=(hooks/gate-scripts scripts/hooks)

mode="check"
root="$REPO_ROOT"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)  mode="check"; shift ;;
        --update) mode="update"; shift ;;
        # `shift 2` on a trailing bare `--root` fails and leaves $# at 1, which under
        # a `|| true` spins this loop forever — so require the operand first.
        --root)   [[ $# -ge 2 ]] || { printf 'gate-integrity: --root needs a directory\n' >&2; exit 2; }
                  root="$2"; shift 2 ;;
        *) printf 'gate-integrity: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done
[[ -n "$root" && -d "$root" ]] || { printf 'gate-integrity: --root is not a directory: %s\n' "$root" >&2; exit 2; }

# Same fallback chain the rest of this repo's hashing uses: sha256sum (Linux),
# shasum (macOS), then python3 — which is already a hard dependency of the gate
# tooling, so this cannot end up with no hasher at all.
sha256_of() {  # sha256_of <file>
    local out
    if command -v sha256sum >/dev/null 2>&1; then
        out="$(sha256sum "$1")" || return 1
    elif command -v shasum >/dev/null 2>&1; then
        out="$(shasum -a 256 "$1")" || return 1
    else
        out="$(_GI_FILE="$1" python3 -c \
          'import hashlib, os; print(hashlib.sha256(open(os.environ["_GI_FILE"], "rb").read()).hexdigest())')" || return 1
    fi
    out="${out%% *}"
    # An unreadable file must not degrade to an empty digest that both --check and
    # --update agree on — that agreement is a silent pass over a file nobody hashed.
    [[ "$out" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "$out"
}

# The enumeration, in one place so the newline count and the digest loop can never
# disagree about what is in scope. Run from inside <root>.
#
# `! -type d`, NOT `-type f`: `-type f` skips symlinks, and a symlink
# `hooks/gate-scripts/evil.sh -> /tmp/evil.sh` is executed by bash exactly like a
# regular file while appearing in neither the lock nor the recomputed listing —
# invisible to a diff of the two. Everything non-directory is enumerated and
# anything that is not a regular file is refused by name below.
#
# The ONE exemption is bytecode INSIDE a `__pycache__` directory. Python writes
# `lib/__pycache__/*.pyc` the first time a gate imports one of the locked
# modules — including while this suite runs — so locking it would make the check
# fail on an otherwise untouched tree.
#
# It is anchored by `-path`, not by `-name`. An unanchored `! -name '*.pyc'`
# matches a basename ANYWHERE in the locked trees, and that exempts the exact
# position that executes arbitrary code inside a blocking gate: four gates do
# `sys.path.insert(0, <lib dir>)` and then `import json, re, os`
# (check-design-document.sh, pre-implementation-gate.sh), and Python 3's
# SourcelessFileLoader imports a bare `.pyc` with NO `.py` beside it — so
# `hooks/gate-scripts/lib/json.pyc` shadows stdlib `json` at sys.path[0] and
# needs no matching mtime or size to do it. `python3 -I` does not help; `-I`
# drops PYTHONPATH and user-site, not an explicit sys.path.insert. Anchoring
# costs nothing: CPython 3 writes bytecode only into `__pycache__` (PEP 3147),
# never beside the source.
#
# The exemption is a FIXED pattern in this script, never a repo-controlled
# ignore list: a `.gitignore` entry removes nothing from this enumeration (so a
# gitignored `hooks/gate-scripts/lib/evil.sh` is still caught, and `git add -f`
# buys nothing), and widening it means editing this file in the reviewed diff.
# RESIDUAL, named rather than waved away: a forged `__pycache__/*.pyc` whose
# source `.py` is unchanged and whose size and mtime match what CPython recorded
# would execute unlocked.
lockable_paths() {  # lockable_paths [find-args...]
    find "${LOCKED_DIRS[@]}" ! -type d ! -path '*/__pycache__/*.pyc' "$@"
}

# The ONE producer. `--check` and `--update` both call it, so the two can never
# drift into disagreeing about what the lock is supposed to contain.
#
# Enumerated from DISK, not `git ls-files`: the working tree is what executes.
# CLAUDE_PLUGIN_ROOT points at a checkout and the hooks run from those files, so
# an untracked `hooks/gate-scripts/lib/extra.sh` runs exactly like a tracked one
# and must show up as an unlocked file rather than be invisible.
compute_lock() {  # compute_lock <root>
    local base="$1" dir f
    for dir in "${LOCKED_DIRS[@]}"; do
        [[ -d "$base/$dir" ]] || { printf 'gate-integrity: locked directory missing: %s\n' "$dir" >&2; return 1; }
    done
    cd "$base" || return 1

    # A path containing a NEWLINE would split one entry into two unhashable lines
    # that --check and --update agree on — a silent pass over a smuggled file. The
    # line count and the NUL-delimited count diverge exactly when one exists, so
    # compare them and fail closed rather than record the garbage.
    local n_lines n_paths
    n_lines="$(lockable_paths | wc -l | tr -d ' ')"
    n_paths="$(lockable_paths -print0 | tr -dc '\0' | wc -c | tr -d ' ')"
    if [[ "$n_lines" != "$n_paths" ]]; then
        printf 'gate-integrity: a locked path contains a newline (%s lines vs %s paths)\n' \
            "$n_lines" "$n_paths" >&2
        return 1
    fi

    # Paths stay repo-relative so a lock recorded here verifies in any checkout.
    local digest
    while IFS= read -r f; do
        if [[ -L "$f" || ! -f "$f" ]]; then
            printf 'gate-integrity: not a regular file (symlinks and special files are not lockable): %s\n' "$f" >&2
            return 1
        fi
        digest="$(sha256_of "$f")" || {
            printf 'gate-integrity: could not hash: %s\n' "$f" >&2
            return 1
        }
        printf '%s  %s\n' "$digest" "$f"
    done < <(lockable_paths | LC_ALL=C sort)
}

lock_path="$root/$LOCK_NAME"

if [[ "$mode" == "update" ]]; then
    computed="$(compute_lock "$root")" || exit 1
    # An empty listing would write a lone newline — 1 byte, which clears the `-s`
    # guard below and has a zero-script gate surface certify as "OK — 1 files
    # match". Both locked directories existing but empty is a disarmed tree, not
    # a recordable state.
    [[ -n "$computed" ]] || { printf 'gate-integrity: refusing to record an EMPTY lock (the locked directories hold no files)\n' >&2; exit 1; }
    printf '%s\n' "$computed" > "$lock_path" || exit 1
    printf 'gate-integrity: wrote %s (%d files)\n' "$LOCK_NAME" "$(wc -l <<< "$computed" | tr -d ' ')"
    exit 0
fi

# Missing, empty or unreadable lock fails CLOSED — an absent lock is the state a
# bypass would leave behind, not a reason to pass.
if [[ ! -f "$lock_path" || ! -s "$lock_path" ]]; then
    printf 'gate-integrity: FAIL — %s is missing or empty\n' "$LOCK_NAME" >&2
    printf '  run: ./scripts/gate-integrity.sh --update\n' >&2
    exit 1
fi

computed="$(compute_lock "$root")" || exit 1
# Same refusal on the checking side — see --update above.
[[ -n "$computed" ]] || { printf 'gate-integrity: FAIL — the locked directories hold no files\n' >&2; exit 1; }
# One diff reports all three failure modes with the offending path named:
# a changed digest, an added (unlocked) file, and a deleted locked file.
if diff_out="$(diff -u "$lock_path" <(printf '%s\n' "$computed") 2>&1)"; then
    printf 'gate-integrity: OK — %d files match %s\n' \
        "$(wc -l < "$lock_path" | tr -d ' ')" "$LOCK_NAME"
    exit 0
fi

printf 'gate-integrity: FAIL — the hook execution surface does not match %s\n' "$LOCK_NAME" >&2
printf '%s\n' "$diff_out" >&2
printf '\n  A `-` line is a locked file that changed or was deleted; a `+` line is its\n' >&2
printf '  current content or a new unlocked file. Review the change, then record it:\n' >&2
printf '    ./scripts/gate-integrity.sh --update   # and commit the lock alongside it\n' >&2
exit 1
