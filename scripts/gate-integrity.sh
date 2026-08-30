#!/bin/bash
# gate-integrity.sh — content lock over the hook execution surface (#742).
#
# Interpreter is ABSOLUTE (`#!/bin/bash`, not `/usr/bin/env bash`) so PATH cannot
# select a fake bash. `BASH_ENV` executes before line 1 and no line here can undo it,
# so the CI step invokes this through `env -i` — the first hop is the caller's to make
# fail-closed, exactly as ADR 0016 / ADR 0049 settled for the gate registrations.
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
# before this landed (~1/day). Each such change now needs `--update` recorded
# before the branch is reviewed — not necessarily in the same commit, since the
# check compares the checked-out TREE and a regen later on the same branch still
# verifies at HEAD. That deliberate maintenance IS the control.
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
# The bytecode exemption, as ONE pattern: `lockable_paths` skips exactly what
# `unvalidated_bytecode` classifies, so no future edit can widen one without
# widening the other and leave a file exempt from both.
PYC_EXEMPT_PATH='*/__pycache__/*.pyc'

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
#
# The two CLI hashers read STDIN, never a filename operand. Handed a name, both
# GNU `sha256sum` and `shasum` C-ESCAPE it — a backslash in the path prefixes the
# whole output line with `\` (documented in `shasum --help`; `sha256sum --help`
# notes `--zero` is what disables the escaping) — so `${out%% *}` would keep that
# leading `\`, the 64-hex test below would reject a digest that was computed
# perfectly well, and `hooks/gate-scripts/a\b.sh` would be unlockable by BOTH
# `--update` and `--check`. Reading from stdin puts no filename in the output at
# all (`<digest>  -`), so every path the enumerator accepts can actually be
# hashed, and a leading `-` in a name likewise stops being an operand. A file
# this shell cannot open fails the redirect, so the subshell still exits nonzero
# and the `|| return 1` below still fires.
sha256_of() {  # sha256_of <file>
    local out
    if command -v sha256sum >/dev/null 2>&1; then
        out="$(sha256sum < "$1")" || return 1
    elif command -v shasum >/dev/null 2>&1; then
        out="$(shasum -a 256 < "$1")" || return 1
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
# The exemption is bounded on BOTH ways a `.pyc` can arrive, because PEP 552
# makes an unvalidated one trivial: an UNCHECKED hash-based `.pyc` (flags bit 0
# set, bit 1 clear) is loaded with NO comparison to its source at all — not
# mtime, not size, not hash — so `lib/__pycache__/marker_ops.cpython-XXX.pyc`
# replaces the locked `marker_ops.py`'s behaviour while both `--check` and
# `--update` omit it. Through a PR: `tracked_bytecode` below refuses it by name.
# Dropped straight onto disk: `unvalidated_bytecode` below refuses it too (#797).
# That asymmetry WAS the gap — editing the locked `.py` is DETECTED, dropping
# the `.pyc` beside it was not, which is strictly the more useful move for the
# local-write attacker this lock exists to make noisy.
#
# Header flags alone are not enough. PEP 552's timestamp and checked-hash modes
# authenticate the SOURCE (mtime/size or a source hash), not the marshaled
# body: splicing a valid header onto malicious bytecode still loads, and
# `--check` would pass. So the classifier also compiles the sibling `.py` and
# requires the cache's body to match — which is exactly what a cache written by
# merely running the gates is, and what a forgery is not. Unchecked-hash is
# still refused by flags even when the body currently matches: CPython never
# writes that mode by default, and it would keep executing after every later
# edit to the locked source.
lockable_paths() {  # lockable_paths [find-args...]
    find "${LOCKED_DIRS[@]}" ! -type d ! -path "$PYC_EXEMPT_PATH" "$@"
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
# The tracked-bytecode check is the only cover against a TRACKED .pyc (the untracked
# ones are `unvalidated_bytecode`'s, below), and the digest omits both.
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
        -u GIT_LITERAL_PATHSPECS -u GIT_GLOB_PATHSPECS -u GIT_NOGLOB_PATHSPECS \
        -u GIT_ICASE_PATHSPECS \
        git "$@"
}

# Tracked bytecode, from the index AND from HEAD. Both, because each alone is empty in
# a state the other is not: `ls-files` treats a MISSING `.git/index` as an empty index
# and exits 0 (delete it and the check goes vacuous), while a fresh repository has no
# HEAD at all.
#
# Pathspecs are DIRECTORIES, never `*.pyc` — a glob pathspec is read literally under
# GIT_LITERAL_PATHSPECS / GIT_NOGLOB_PATHSPECS, so it would match nothing and exit 0.
# Output is `-z`: git's default listing C-QUOTES a path containing a newline or a
# non-printable byte, so such a name ends in a QUOTE and a `\.pyc$` match on it fails —
# a tracked file slipping past on the strength of its own name. NUL delimiting emits
# the raw bytes and needs no unquoting. The suffix test is case-folded for the same
# reason the containment suite folds: this filesystem is case-insensitive, so `MOD.PYC`
# loads as `mod.pyc`.
tracked_bytecode() {  # tracked_bytecode <root> — prints paths, nonzero on query failure
    local r="$1" tmp f head_ref probe_rc
    # The HEAD half is gated on HEAD RESOLVING, not on the repository having commits
    # SOMEWHERE. `rev-list -n1 --all` answered the second question and was read as the
    # first: on a legitimate orphan branch (`git switch --orphan fresh`) another ref
    # still carries commits while this HEAD is unborn, so `--all` came back nonempty
    # and `ls-tree ... HEAD` died with "Not a valid object name HEAD" — failing both
    # `--check` and `--update` on a perfectly queryable repository.
    #
    # `rev-parse -q --verify HEAD` asks about HEAD itself and still separates the two
    # outcomes the old probe was chosen to separate: exit 1 is "HEAD does not resolve"
    # (nothing to read), and any OTHER nonzero — an unreadable `packed-refs`, a
    # malformed HEAD — is a real failure that must not be swallowed.
    #
    # Deliberately plain `HEAD`, never `HEAD^{commit}`: the peel form ALSO exits 1
    # when the ref resolves but its object is missing, which would turn a corrupt
    # repository into a silent skip. The plain form resolves there (exit 0), reaches
    # `ls-tree`, and fails loudly.
    #
    # Exit 1 is not exclusively "unborn" — an unreadable LOOSE `refs/heads` also
    # yields it. That is not a regression: `rev-list -n1 --all` returned exit 0 with
    # EMPTY output in the same state, so it skipped the HEAD half there too. The
    # index half below still runs, and `rev-parse --git-dir` has already passed.
    head_ref="$(git_clean -C "$r" rev-parse -q --verify HEAD)" || {
        probe_rc=$?
        [[ $probe_rc -eq 1 ]] || return 1
        head_ref=""
    }
    tmp="$(mktemp)" || return 1
    if ! git_clean -C "$r" ls-files -z -- "${LOCKED_DIRS[@]}" > "$tmp"; then
        rm -f "$tmp"; return 1
    fi
    if [[ -n "$head_ref" ]]; then
        if ! git_clean -C "$r" ls-tree -r -z --name-only HEAD -- "${LOCKED_DIRS[@]}" >> "$tmp"; then
            rm -f "$tmp"; return 1
        fi
    fi
    # Captured, not streamed: `rm` and a trailing `return 0` would OVERWRITE the
    # pipeline status, so a decode or sort failure with no output would leave the
    # caller holding an empty result and accepting tracked bytecode — the fail-open
    # this whole function exists to prevent.
    local found
    if ! found="$(while IFS= read -r -d '' f; do
                      # `(pattern)` form: inside `$( )` an unbalanced `)` ends the
                      # substitution, so the case arm must open its own paren.
                      case "$f" in (*.[pP][yY][cC]) printf '%s\n' "$f" ;; esac
                  done < "$tmp" | LC_ALL=C sort -u)"; then
        rm -f "$tmp"; return 1
    fi
    rm -f "$tmp"
    printf '%s' "$found"
}

# The UNTRACKED half of the same exemption (#797). Trackedness covers a `.pyc`
# that arrives through a PR; one dropped straight onto disk is neither hashed nor
# refused, so it produces no lock diff at all. Classified from DISK for the same
# reason the digest is: the working tree is what executes.
#
# Two independent refusals, both required:
#   1. PEP 552 flags at bytes 4-8 (little-endian): `flags & 3 == 1` is the
#      UNCHECKED hash-based cache — loaded with no source comparison at all.
#   2. Body match: the marshaled code after the 16-byte header must equal a
#      compile of the sibling `.py` (filename-normalized). Timestamp and
#      checked-hash modes only authenticate the source's metadata/hash, so a
#      spliced header+malicious-body cache would otherwise pass.
#
# Everything else under the exemption is refused too, not skipped: a header this
# cannot read, a file too short to hold one, a missing/unreadable sibling source,
# a body that will not marshal, and a SYMLINK (`compute_lock` refuses those
# everywhere else in the locked trees, and CPython never writes one into
# `__pycache__`). The exempt set is the one place nothing is hashed, so "could
# not prove it is the locked source's bytecode" has to mean refuse.
unvalidated_bytecode() {  # unvalidated_bytecode <root> — prints offenders, nonzero on failure
    # Find status is checked BEFORE the classifier reads anything. A bare
    # `find | python` with pipefail would still fail closed here, but it would
    # report as a classifier failure and mask compute_lock's enumeration guard
    # — the same "lists then exits nonzero" shape #742 refuses by name. Capture
    # the listing first (NUL bytes need a file; a bash variable cannot hold them),
    # and reuse that guard's message so a PATH-shimmed find cannot change which
    # check appears to have fired.
    (
        CDPATH='' cd -P -- "$1" || exit 1
        local tmp
        tmp="$(mktemp)" || exit 1
        # `! -type d` mirrors lockable_paths: a DIRECTORY named `x.pyc` inside
        # `__pycache__` is not lockable and not importable, and opening it would
        # report a false offender.
        if ! find "${LOCKED_DIRS[@]}" ! -type d -path "$PYC_EXEMPT_PATH" -print0 >"$tmp"; then
            rm -f "$tmp"
            printf 'gate-integrity: could not enumerate the locked directories\n' >&2
            exit 1
        fi
        # marshal.loads is intentional and compare-only: CPython's import does the
        # same decode on these files, we never exec the result, and a malformed
        # body is refused. Raw-body compare cannot work — co_filename embeds the
        # path used at compile time, so a cache from import and a fresh
        # py_compile of the same source disagree in the bytes after the header.
        # Optimize level is taken from the PEP 3147 name (`.opt-N`), not from
        # this interpreter: the classifier always runs under `python3 -I`
        # (optimize 0), while a gate that ran under `-O`/`-OO` writes `.opt-1`
        # / `.opt-2` caches whose bodies only match a compile at that level.
        # shellcheck disable=SC2016  # python source, not a shell expansion
        python3 -I -c '
import importlib.util, marshal, os, re, sys, warnings
warnings.filterwarnings("ignore", category=DeprecationWarning)

HEADER = 16
# Fields CodeType == considers, PLUS co_stacksize. Line tables (co_linetable /
# co_lnotab) are omitted: they do not change executable behaviour, and Pythons
# -X no_debug_ranges produces legitimate caches whose line tables diverge while
# co_code matches. Non-code constants use marshal.dumps so cases == collapses
# (0.0 vs -0.0) still diverge. Tuples, frozensets, and nested code objects also
# track identity so a forge that breaks sharing (A is f()) while keeping equal
# values cannot pass. co_filename must be an exact allowlisted spelling of the
# sibling source. Reads of both the cache and the sibling source are size-bounded.
_CODE_FIELDS = (
    "co_argcount", "co_posonlyargcount", "co_kwonlyargcount", "co_nlocals",
    "co_stacksize", "co_flags", "co_code", "co_names", "co_varnames",
    "co_freevars", "co_cellvars", "co_name", "co_qualname", "co_firstlineno",
    "co_exceptiontable",
)
_MAX_PYC_BYTES = 8 * 1024 * 1024
_MAX_SRC_BYTES = _MAX_PYC_BYTES

def same_const(a, b, memo, rev):
    a_code, b_code = hasattr(a, "co_code"), hasattr(b, "co_code")
    if a_code or b_code:
        return a_code and b_code and same_code(a, b, memo, rev)
    if isinstance(a, tuple) and isinstance(b, tuple):
        ia, ib = id(a), id(b)
        if ia in memo:
            return memo[ia] == ib
        if ib in rev:
            return False
        memo[ia] = ib
        rev[ib] = ia
        if len(a) != len(b):
            return False
        return all(same_const(x, y, memo, rev) for x, y in zip(a, b))
    if isinstance(a, frozenset) and isinstance(b, frozenset):
        ia, ib = id(a), id(b)
        if ia in memo:
            return memo[ia] == ib
        if ib in rev:
            return False
        memo[ia] = ib
        rev[ib] = ia
        if len(a) != len(b):
            return False
        # Unordered: match each element of a to one unused element of b under
        # the same memo (so shared inners elsewhere in the graph stay linked).
        unused = list(b)
        for ea in a:
            for i, eb in enumerate(unused):
                memo_s, rev_s = dict(memo), dict(rev)
                if same_const(ea, eb, memo_s, rev_s):
                    memo.clear(); memo.update(memo_s)
                    rev.clear(); rev.update(rev_s)
                    unused.pop(i)
                    break
            else:
                return False
        return True
    # Atoms (str/bytes/int/float/complex/...) also participate in identity:
    # a shared bytes/str across nested code objects must stay shared.
    ia, ib = id(a), id(b)
    if ia in memo:
        return memo[ia] == ib
    if ib in rev:
        return False
    memo[ia] = ib
    rev[ib] = ia
    try:
        return marshal.dumps(a) == marshal.dumps(b)
    except Exception:
        return False

def same_code(a, b, memo=None, rev=None):
    if memo is None:
        memo, rev = {}, {}
    if type(a) is not type(b) or not hasattr(a, "co_code"):
        return False
    ia, ib = id(a), id(b)
    if ia in memo:
        return memo[ia] == ib
    if ib in rev:
        return False
    memo[ia] = ib
    rev[ib] = ia
    for f in _CODE_FIELDS:
        if getattr(a, f, None) != getattr(b, f, None):
            return False
    if len(a.co_consts) != len(b.co_consts):
        return False
    return all(same_const(x, y, memo, rev) for x, y in zip(a.co_consts, b.co_consts))

def allowed_filenames(src):
    # Exact lexical allowlist — not realpath-of-anything. That rejects ./ ../
    # spellings, hardlink aliases, and paths reached through a symlinked parent
    # while still accepting the relative source_from_cache name and the
    # absolute / realpath spellings CPython embeds. The macOS /private alias is
    # added only when that spelling exists and resolves to the same source.
    names = {src, os.path.abspath(src), os.path.realpath(src)}
    out = set()
    for n in names:
        n = os.path.normpath(n)
        out.add(n)
        if n.startswith("/private/"):
            alt = "/" + n[len("/private/"):]
            try:
                if os.path.exists(alt) and os.path.realpath(alt) == os.path.realpath(n):
                    out.add(os.path.normpath(alt))
            except OSError:
                pass
        elif n.startswith("/") and not n.startswith("/private/"):
            alt = os.path.normpath("/private" + n)
            try:
                if os.path.exists(alt) and os.path.realpath(alt) == os.path.realpath(n):
                    out.add(alt)
            except OSError:
                pass
    return out

def filenames_ok(code, allowed):
    name = code.co_filename
    # Reject non-canonical spellings before allowlist lookup — normpath would
    # otherwise collapse ./ and ../ aliases into an allowed name.
    if not name or name != os.path.normpath(name):
        return False
    if name not in allowed:
        return False
    return all(
        filenames_ok(c, allowed) if hasattr(c, "co_code") else True
        for c in code.co_consts
    )

def optimize_level(path):
    m = re.search(r"\.opt-(\d+)\.pyc$", path, re.IGNORECASE)
    return int(m.group(1)) if m else 0

for raw in sys.stdin.buffer.read().split(b"\0"):
    if not raw:
        continue
    p = os.fsdecode(raw)
    if os.path.islink(p):
        print(p + "  (symlink — CPython never writes one into __pycache__)")
        continue
    try:
        size = os.stat(p).st_size
    except OSError as exc:
        print(p + "  (unreadable: %s)" % (exc.strerror or exc))
        continue
    if size < HEADER:
        print(p + "  (too short to hold a PEP 552 header)")
        continue
    if size > _MAX_PYC_BYTES:
        print(p + "  (exceeds %d-byte classifier bound)" % _MAX_PYC_BYTES)
        continue
    try:
        with open(p, "rb") as fh:
            data = fh.read(size + 1)
    except OSError as exc:
        print(p + "  (unreadable: %s)" % (exc.strerror or exc))
        continue
    if len(data) != size:
        print(p + "  (size changed underfoot while reading)")
        continue
    flags = int.from_bytes(data[4:8], "little")
    if flags & 3 == 1:
        print(p + "  (PEP 552 UNCHECKED hash-based: never validated against its source)")
        continue
    # Foreign-magic caches cannot be authenticated against this interpreter.
    # Skipping them would reopen #797 whenever a gate later resolves a different
    # python3 from PATH that CAN load the planted cache.
    if data[:4] != importlib.util.MAGIC_NUMBER:
        print(p + "  (foreign-interpreter cache cannot be authenticated)")
        continue
    try:
        src = importlib.util.source_from_cache(p)
    except ValueError:
        print(p + "  (not a PEP 3147 cache name — no sibling source to authenticate against)")
        continue
    if not src or not os.path.isfile(src) or os.path.islink(src):
        print(p + "  (no regular sibling source to authenticate against)")
        continue
    try:
        src_size = os.stat(src).st_size
    except OSError as exc:
        print(p + "  (unreadable source: %s)" % (exc.strerror or exc))
        continue
    if src_size > _MAX_SRC_BYTES:
        print(p + "  (sibling source exceeds %d-byte classifier bound)" % _MAX_SRC_BYTES)
        continue
    try:
        with open(src, "rb") as fh:
            src_bytes = fh.read(src_size + 1)
        if len(src_bytes) != src_size:
            print(p + "  (source size changed underfoot while reading)")
            continue
        expected = compile(
            src_bytes, "<locked>", "exec", dont_inherit=True,
            optimize=optimize_level(p),
        )
        got = marshal.loads(data[HEADER:])
    except OSError as exc:
        print(p + "  (unreadable source: %s)" % (exc.strerror or exc))
        continue
    except Exception as exc:
        print(p + "  (bytecode body unreadable: %s)" % exc.__class__.__name__)
        continue
    if not same_code(got, expected):
        print(p + "  (bytecode body does not match a compile of the locked source beside it)")
        continue
    if not filenames_ok(got, allowed_filenames(src)):
        print(p + "  (co_filename does not name the locked source beside it)")
' <"$tmp"
        local st=$?
        rm -f "$tmp"
        exit "$st"
    )
}

tracked_pyc=""
if ! rev_parse_err="$(git_clean -C "$root" rev-parse --git-dir 2>&1)"; then
    printf 'gate-integrity: FAIL — no queryable git repository at %s\n' "$root" >&2
    printf '  %s\n' "$rev_parse_err" >&2
    printf '  Bytecode is exempt from the digest, so the git index is the only cover\n' >&2
    printf '  against a TRACKED one:\n' >&2
    printf '  a missing git, corrupt or unreadable metadata (including in an ANCESTOR),\n' >&2
    printf '  a safe.directory rejection, and a plain non-repository are not\n' >&2
    printf '  distinguishable here, so all of them refuse rather than skip the check.\n' >&2
    exit 1
fi
# An UNQUERYABLE index or HEAD fails CLOSED for the same reason.
if ! tracked_pyc="$(tracked_bytecode "$root" 2>&1)"; then
    printf 'gate-integrity: FAIL — could not query git for tracked bytecode:\n' >&2
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

# Same refusal, for the bytecode no index can see. Placed AFTER the tracked check so
# a tracked offender still reports as TRACKED, and BEFORE the mode dispatch so
# `--update` cannot record a lock over a tree holding one.
if ! unvalidated_pyc="$(unvalidated_bytecode "$root" 2>&1)"; then
    # Enumeration failures already carry compute_lock's message; pass them
    # through so #797 cannot rename the #742 find-status guard.
    if [[ "$unvalidated_pyc" == *"could not enumerate the locked directories"* ]]; then
        printf '%s\n' "$unvalidated_pyc" >&2
    else
        printf 'gate-integrity: FAIL — could not classify the exempt bytecode:\n' >&2
        printf '  %s\n' "$unvalidated_pyc" >&2
    fi
    exit 1
fi
if [[ -n "$unvalidated_pyc" ]]; then
    printf 'gate-integrity: FAIL — unvalidated bytecode under a locked directory:\n' >&2
    # Quoted, line-wise: an unquoted expansion would GLOB a path containing `*`.
    while IFS= read -r _pyc; do printf '  %s\n' "$_pyc" >&2; done <<< "$unvalidated_pyc"
    printf '  A .pyc is exempt from the digest only while its body matches a compile of\n' >&2
    printf '  the locked source beside it (and is not an unchecked-hash cache), so these\n' >&2
    printf '  execute unlocked. Bytecode is regenerable: delete the files above (the\n' >&2
    printf '  next import rewrites them).\n' >&2
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
