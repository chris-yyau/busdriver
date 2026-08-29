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
# lockfile diff: the check compares the CHECKED-OUT TREE, so a regen in a later
# commit on the same branch still verifies at HEAD — what cannot happen is the
# branch reaching CI with the two out of sync. Every content change to the hook
# execution surface therefore arrives in review as an explicit, named line
# rather than as a body change under an unchanged registration.
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
        # `-I`, never bare `python3`: this runs AFTER compute_lock has cd'd INTO the
        # tree being hashed, so a repo-local `hashlib.py` would be importable and
        # could forge every digest — changed files matching the old lock. Isolated
        # mode drops the script directory and PYTHONPATH from sys.path.
        out="$(_GI_FILE="$1" python3 -I -c \
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
# The exemption is bounded on the side that actually matters — TRACKEDNESS. A
# `.pyc` that reaches this repo through a PR is checked below and refused by
# name, because PEP 552 makes an unvalidated one trivial: an UNCHECKED
# hash-based `.pyc` (flags bit 1 clear) is loaded with NO comparison to its
# source at all — not mtime, not size, not hash — so a tracked
# `lib/__pycache__/marker_ops.cpython-XXX.pyc` would simply replace the locked
# `marker_ops.py`'s behaviour while both `--check` and `--update` omitted it.
# RESIDUAL, named rather than waved away: an UNTRACKED forged `.pyc` dropped
# straight onto disk still executes unlocked. That needs local write access to
# the gate directory, which already implies the ability to edit the locked
# `.py` beside it.
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
    # `CDPATH= cd -P --`: bare `cd` honours an exported CDPATH, so a relative --root
    # can resolve to a DIFFERENT tree than the one `lock_path` was built from — and cd
    # then ECHOES the path it chose, which would land in the captured listing. `--`
    # also stops a root named `-` being read as the previous-directory operand.
    CDPATH='' cd -P -- "$base" || return 1

    # EVERY enumeration is captured and its status checked. `find` can emit a PARTIAL
    # listing and THEN exit nonzero — an unreadable or vanishing subtree does exactly
    # that — and with `pipefail` but no `set -e` a bare pipeline would swallow it:
    # --update would record the partial lock and --check would accept the same partial
    # tree. A listing this function cannot vouch for is not a listing.
    local n_lines n_paths listing
    n_lines="$(lockable_paths | wc -l | tr -d ' ')" \
        || { printf 'gate-integrity: could not enumerate the locked directories\n' >&2; return 1; }
    n_paths="$(lockable_paths -print0 | tr -dc '\0' | wc -c | tr -d ' ')" \
        || { printf 'gate-integrity: could not enumerate the locked directories\n' >&2; return 1; }
    # A path containing a NEWLINE would split one entry into two unhashable lines
    # that --check and --update agree on — a silent pass over a smuggled file. The
    # line count and the NUL-delimited count diverge exactly when one exists, so
    # compare them and fail closed rather than record the garbage.
    if [[ "$n_lines" != "$n_paths" ]]; then
        printf 'gate-integrity: a locked path contains a newline (%s lines vs %s paths)\n' \
            "$n_lines" "$n_paths" >&2
        return 1
    fi
    listing="$(lockable_paths | LC_ALL=C sort)" \
        || { printf 'gate-integrity: could not enumerate the locked directories\n' >&2; return 1; }

    # Paths stay repo-relative so a lock recorded here verifies in any checkout.
    local digest
    while IFS= read -r f; do
        # `<<<` on an empty listing still yields one empty line — the caller's
        # empty-listing refusal is what reports that, with the right message.
        [[ -z "$f" ]] && continue
        if [[ -L "$f" || ! -f "$f" ]]; then
            printf 'gate-integrity: not a regular file (symlinks and special files are not lockable): %s\n' "$f" >&2
            return 1
        fi
        digest="$(sha256_of "$f")" || {
            printf 'gate-integrity: could not hash: %s\n' "$f" >&2
            return 1
        }
        printf '%s  %s\n' "$digest" "$f"
    done <<< "$listing"
}

# The other half of the `.pyc` exemption: anything the exemption skips must not be
# able to arrive through a PR. Asked of the INDEX, not the worktree — a `.pyc` is a
# build artifact, and a tracked one is a deliberate act, never a side effect of
# running a gate. A non-repo `--root` (the test fixtures) has no index to ask, which
# is why this is a separate check rather than a condition inside the enumeration.
# The tracked-bytecode check is the ONLY cover for the .pyc files the digest omits.
# Four shapes were tried to decide "is there an index to ask", and each INFERRED the
# answer, leaving a hole:
#   - probe-only read EVERY rev-parse failure as "not a repository", so an absent git
#     binary or unreadable metadata silently skipped the check;
#   - marker-only (`[[ -e "$root/.git" ]]`) missed a queryable work tree with no `.git`
#     of its own — a root BELOW the repository top level — and `-e` follows a symlink,
#     so it was also false for the dangling `.git` that IS the broken-metadata case;
#   - probe-then-marker fell through for a root below the top level when git was
#     missing: probe fails, `$root/.git` legitimately absent, else branch disables it;
#   - adding a `git --version` guard only proves git STARTS. For a root below the top
#     level the metadata lives in an ANCESTOR, so corrupt, unreadable or
#     ownership-rejected (`safe.directory`) state fails rev-parse with no `.git` here
#     to notice — indistinguishable, by inference, from a plain non-repository.
# Inference cannot separate "not a repository" from "a repository I could not
# classify", so it is not used: a queryable repository is REQUIRED, and every
# rev-parse failure blocks. The test fixtures `git init` for this reason.
#
# No sentinel on `tracked_pyc` either: `${tracked_pyc+x}` would have trusted INHERITED
# shell state, so an exported `tracked_pyc=""` made a detected repository skip the
# query entirely.
#
# Both queries run through `git_clean`, never bare `git`. A successful `ls-files` is
# only proof of a real index if the environment did not choose the index: with
# `GIT_INDEX_FILE` pointing at a nonexistent path, `rev-parse --git-dir` still
# succeeds and `ls-files` returns EMPTY with exit 0 — a clean bill of health for a
# query that read nothing, and every `__pycache__/*.pyc` then stays exempt. Gate env
# is repo-injectable through a committed settings.json `env` block (#325 / ADR 0016),
# so the location-selecting variables are stripped for these two calls.
git_clean() {  # git_clean <args...> — git with the repo-selecting env stripped
    env -u GIT_INDEX_FILE -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR \
        -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
        -u GIT_CEILING_DIRECTORIES -u GIT_DISCOVERY_ACROSS_FILESYSTEM \
        -u GIT_NAMESPACE -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM \
        git "$@"
}

tracked_pyc=""
if ! rev_parse_err="$(git_clean -C "$root" rev-parse --git-dir 2>&1)"; then
    printf 'gate-integrity: FAIL — no queryable git repository at %s\n' "$root" >&2
    printf '  %s\n' "$rev_parse_err" >&2
    printf '  Bytecode is exempt from the digest, so the git index is its only cover:\n' >&2
    printf '  a missing git, corrupt or unreadable metadata (including in an ANCESTOR),\n' >&2
    printf '  a safe.directory rejection, and a plain non-repository are not\n' >&2
    printf '  distinguishable here, so all of them refuse rather than skip the check.\n' >&2
    exit 1
fi
# An UNQUERYABLE index fails CLOSED for the same reason.
if ! tracked_pyc="$(git_clean -C "$root" ls-files -- "${LOCKED_DIRS[@]/%//*.pyc}" 2>&1)"; then
    printf 'gate-integrity: FAIL — could not query the git index for tracked bytecode:\n' >&2
    printf '  %s\n' "$tracked_pyc" >&2
    exit 1
fi
if [[ -n "$tracked_pyc" ]]; then
    printf 'gate-integrity: FAIL — bytecode is TRACKED under a locked directory:\n' >&2
    # Quoted, line-wise: an unquoted expansion would GLOB a path containing `*`.
    while IFS= read -r _pyc; do printf '  %s\n' "$_pyc" >&2; done <<< "$tracked_pyc"
    printf '  A .pyc is exempt from the digest, so a tracked one executes unlocked —\n' >&2
    printf '  PEP 552 unchecked hash-based bytecode is not validated against its source\n' >&2
    printf '  at all. Remove it from the index (git rm --cached) and keep it ignored.\n' >&2
    exit 1
fi

lock_path="$root/$LOCK_NAME"

# The lock is a TRACKED file, so a PR controls what it is — including making it a
# symlink. `>` follows one, which would turn the documented `--update` into an
# arbitrary write against any target the operator can write (`~/.ssh/authorized_keys`,
# a shell rc). Reading through one is the mirror problem: the lock a check verifies
# against would come from outside the tree. Refuse it in both modes; a regular file or
# nothing are the only two states this tool handles.
if [[ -L "$lock_path" ]]; then
    printf 'gate-integrity: %s is a symlink — refusing to read or write through it\n' "$LOCK_NAME" >&2
    exit 1
fi
if [[ -e "$lock_path" && ! -f "$lock_path" ]]; then
    printf 'gate-integrity: %s is not a regular file\n' "$LOCK_NAME" >&2
    exit 1
fi

if [[ "$mode" == "update" ]]; then
    computed="$(compute_lock "$root")" || exit 1
    # An empty listing would write a lone newline — 1 byte, which clears the `-s`
    # guard below and has a zero-script gate surface certify as "OK — 1 files
    # match". Both locked directories existing but empty is a disarmed tree, not
    # a recordable state.
    [[ -n "$computed" ]] || { printf 'gate-integrity: refusing to record an EMPTY lock (the locked directories hold no files)\n' >&2; exit 1; }
    # Write-then-rename. `>` follows a symlink, and the refusal above ran BEFORE the
    # whole hashing pass — wide enough for the lock to be swapped for a symlink in
    # between. rename(2) does not follow a symlink destination, so the move replaces
    # the link itself and the target is never written through.
    # The write goes through an OPEN FD and lands via an exact rename(2). Shell has
    # neither primitive, and each substitute leaks the arbitrary write back in:
    #   - `> "$lock_path"` follows a symlink at the destination;
    #   - a predictable `$lock_path.tmp.$$` can be pre-symlinked and followed;
    #   - `mktemp` returns a NAME, and the following `>` REOPENS it — unlink it and
    #     drop a symlink in the gap and the redirect writes through that;
    #   - `mv` is not rename(2): given a destination that is a symlink to a
    #     DIRECTORY, common implementations move the file INTO it.
    # mkstemp creates O_EXCL and hands back the fd, so the path is never reopened,
    # and os.rename replaces a symlink at the destination rather than following it.
    # The temp file is made in the lock's own directory to keep the rename atomic.
    #
    # The chmod 0644 inside is not cosmetic: mkstemp creates 0600, and handing that
    # to a TRACKED, world-readable file makes the lock unreadable to another account
    # in a shared checkout. It is unconditional rather than inherit-the-existing-mode
    # because one run that had already produced a 0600 lock would perpetuate it.
    #
    # `python3 -I`, never bare `python3`: isolated mode drops the script directory
    # and PYTHONPATH from sys.path, so a repo-local `tempfile.py` / `os.py` cannot
    # be imported here to replace mkstemp or monkey-patch rename and defeat the very
    # protection this block adds. Same reason resolve-repo-dir.sh uses `-I`/`-S`.
    if ! printf '%s\n' "$computed" | _GI_LOCK="$lock_path" python3 -I -c '
import os, sys, tempfile
lock = os.environ["_GI_LOCK"]
data = sys.stdin.read()
fd, tmp = tempfile.mkstemp(prefix=os.path.basename(lock) + ".", dir=os.path.dirname(lock) or ".")
try:
    with os.fdopen(fd, "w") as fh:
        fh.write(data)
    os.chmod(tmp, 0o644)
    os.rename(tmp, lock)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
'; then
        printf 'gate-integrity: could not write %s\n' "$LOCK_NAME" >&2
        exit 1
    fi
    n_written="$(wc -l <<< "$computed")" || n_written="?"
    printf 'gate-integrity: wrote %s (%s files)\n' "$LOCK_NAME" "${n_written// /}"
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
    n_locked="$(wc -l < "$lock_path")" || n_locked="?"
    printf 'gate-integrity: OK — %s files match %s\n' "${n_locked// /}" "$LOCK_NAME"
    exit 0
fi

printf 'gate-integrity: FAIL — the hook execution surface does not match %s\n' "$LOCK_NAME" >&2
printf '%s\n' "$diff_out" >&2
# shellcheck disable=SC2016 # Intentional: a literal $CLAUDE_PLUGIN_ROOT / backtick, not an expansion
printf '\n  A `-` line is a locked file that changed or was deleted; a `+` line is its\n' >&2
printf '  current content or a new unlocked file. Review the change, then record it:\n' >&2
printf '    ./scripts/gate-integrity.sh --update   # and commit the lock alongside it\n' >&2
exit 1
