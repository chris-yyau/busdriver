#!/usr/bin/env bash
# Test: gate-integrity content lock over the hook execution surface (#742).
#
# The control under test is scripts/gate-integrity.sh. #742's bypass is that the
# containment suite pins the two plain-bash launcher REGISTRATIONS verbatim and
# nothing about their BODIES, so a launcher can grow a node dispatch that is
# named nowhere in hooks.json and therefore skipped by every wired-check. The
# first fixture below drives exactly that append and asserts the lock blocks it.
#
# What is asserted is a lockfile's guarantee, not a firewall's: the control does
# not prevent the edit, it makes the edit impossible to land without a lockfile
# diff in the same commit. Every assertion here is therefore about the CHECK
# failing on a divergent tree and passing on a recorded one — both outcomes of
# the guard, never just the green one.
#
# Deliberately NOT touching tests/test-node-hook-containment.sh: #742 rejected
# bolting a partial closure onto that suite, and its PLAIN_BASH verbatim pins
# remain the command-side control this one complements.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE_INTEGRITY="$REPO_ROOT/scripts/gate-integrity.sh"
PASS=0
FAIL=0
assert() {  # assert <rc:0/1> <message>
    if [[ "$1" -eq 0 ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$2"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$2"; fi
}

# ── 0. The real tree is recorded ───────────────────────────────────────────────
# This is the assertion that costs a commit: any change under hooks/gate-scripts/
# or scripts/hooks/ must carry `./scripts/gate-integrity.sh --update` alongside
# it. That maintenance IS the control — see the script header.
"$GATE_INTEGRITY" --check >/dev/null 2>&1
assert $? "the live tree matches .gate-integrity.lock (run --update after any gate-script edit)"

# ── Fixture: an isolated copy of the two locked directories ───────────────────
# A copy, never the live worktree: every case below mutates the tree on purpose.
_fix="$(mktemp -d)"
# Fail CLOSED on a mktemp failure — an empty $_fix would have the cases below
# mutate `/hooks` and `/scripts`, and leave the EXIT trap unable to clean up.
[[ -n "$_fix" && -d "$_fix" ]] || { printf '  FAIL %s\n' "fixture tempdir created"; exit 1; }
trap 'rm -rf "$_fix"' EXIT

fresh_fixture() {  # rebuild the fixture tree + its lock from the live tree
    rm -rf "${_fix:?}/hooks" "${_fix:?}/scripts" "${_fix:?}/.gate-integrity.lock"
    mkdir -p "$_fix/hooks" "$_fix/scripts"
    cp -R "$REPO_ROOT/hooks/gate-scripts" "$_fix/hooks/gate-scripts"
    cp -R "$REPO_ROOT/scripts/hooks" "$_fix/scripts/hooks"
    # A real repository: the script requires a queryable index rather than inferring
    # its absence, so every fixture is one.
    git -C "$_fix" init -q 2>/dev/null
    git -C "$_fix" config user.email t@t.invalid 2>/dev/null
    git -C "$_fix" config user.name t 2>/dev/null
    "$GATE_INTEGRITY" --root "$_fix" --update >/dev/null
}

# A fixture that has just been recorded must verify — otherwise every failure
# below would be indistinguishable from a broken producer.
fresh_fixture
"$GATE_INTEGRITY" --root "$_fix" --check >/dev/null 2>&1
assert $? "↳ control: a freshly recorded fixture tree verifies clean"

# ── 1. The #742 bypass: a node dispatch appended to a plain-bash launcher ─────
# The exact shape from the issue. Its registration in hooks.json is UNCHANGED,
# so the containment suite's verbatim pin still matches and the dispatched hook
# is named nowhere — the lock is what has to see it.
fresh_fixture
# shellcheck disable=SC2016 # Intentional: a literal $CLAUDE_PLUGIN_ROOT / backtick, not an expansion
printf '\nnode "$CLAUDE_PLUGIN_ROOT/scripts/hooks/blocking.js"\n' \
    >> "$_fix/hooks/gate-scripts/load-orchestrator.sh"
_out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
if [[ $? -ne 0 && "$_out" == *"load-orchestrator.sh"* ]]; then
    assert 0 "#742 repro: a node dispatch appended to load-orchestrator.sh fails the check, by name"
else
    printf '  ↳ output: %s\n' "$_out"
    assert 1 "#742 repro: a node dispatch appended to load-orchestrator.sh fails the check, by name"
fi

# ── 1b. The same gap one directory over ───────────────────────────────────────
# run-with-flags-shell.sh is registered through a SHAPE (SHELL_RUNNER), which
# pins its command and not its body — #742 in scripts/hooks/. The lock covers
# the whole directory rather than a `*.js` glob precisely so this is not a
# second, separately-argued hole.
fresh_fixture
# shellcheck disable=SC2016 # Intentional: a literal $CLAUDE_PLUGIN_ROOT / backtick, not an expansion
printf '\nnode "$CLAUDE_PLUGIN_ROOT/scripts/hooks/blocking.js"\n' \
    >> "$_fix/scripts/hooks/run-with-flags-shell.sh"
_out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
if [[ $? -ne 0 && "$_out" == *"run-with-flags-shell.sh"* ]]; then
    assert 0 "a body edit to run-with-flags-shell.sh fails the check (shape-pinned command, unpinned body)"
else
    printf '  ↳ output: %s\n' "$_out"
    assert 1 "a body edit to run-with-flags-shell.sh fails the check (shape-pinned command, unpinned body)"
fi

# ── 2. A NEW unlocked file in either directory ────────────────────────────────
# The dispatched hook has to live somewhere, and a helper dropped beside the
# launchers executes exactly like a tracked one. Enumeration is from disk for
# this reason, so an untracked addition is a failure rather than an invisible.
fresh_fixture
# shellcheck disable=SC2016 # Intentional: a literal $CLAUDE_PLUGIN_ROOT / backtick, not an expansion
printf 'node "$CLAUDE_PLUGIN_ROOT/scripts/hooks/blocking.js"\n' \
    > "$_fix/hooks/gate-scripts/lib/smuggled.sh"
_out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
if [[ $? -ne 0 && "$_out" == *"smuggled.sh"* ]]; then
    assert 0 "a new unlocked file under hooks/gate-scripts/ fails the check, by name"
else
    printf '  ↳ output: %s\n' "$_out"
    assert 1 "a new unlocked file under hooks/gate-scripts/ fails the check, by name"
fi

fresh_fixture
printf 'module.exports = () => ({ exitCode: 2 });\n' > "$_fix/scripts/hooks/smuggled.js"
_out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
if [[ $? -ne 0 && "$_out" == *"smuggled.js"* ]]; then
    assert 0 "a new unlocked file under scripts/hooks/ fails the check, by name"
else
    printf '  ↳ output: %s\n' "$_out"
    assert 1 "a new unlocked file under scripts/hooks/ fails the check, by name"
fi

# ── 2b. A SYMLINK dropped into a locked directory ─────────────────────────────
# bash executes `hooks/gate-scripts/lib/evil.sh -> /elsewhere/evil.sh` exactly
# like a regular file. Under a `-type f` enumeration it appears in NEITHER the
# lock nor the recomputed listing, so a diff of the two sees nothing — the one
# addition shape that can be invisible rather than merely unrecorded. It must be
# named and refused, not skipped.
fresh_fixture
# shellcheck disable=SC2016 # Intentional: a literal $CLAUDE_PLUGIN_ROOT / backtick, not an expansion
printf 'node "$CLAUDE_PLUGIN_ROOT/scripts/hooks/blocking.js"\n' > "$_fix/outside-the-lock.sh"
ln -s "$_fix/outside-the-lock.sh" "$_fix/hooks/gate-scripts/lib/evil.sh"
_out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
if [[ $? -ne 0 && "$_out" == *"evil.sh"* ]]; then
    assert 0 "a SYMLINK into a locked directory fails the check, by name (not silently skipped)"
else
    printf '  ↳ output: %s\n' "$_out"
    assert 1 "a SYMLINK into a locked directory fails the check, by name (not silently skipped)"
fi
# The same refusal on the producing side: `--update` must not be able to record a
# tree it cannot lock, or the check above is one regen away from being retired.
"$GATE_INTEGRITY" --root "$_fix" --update >/dev/null 2>&1
assert "$(( $? == 0 ? 1 : 0 ))" "↳ --update also refuses the symlinked tree (cannot record what it cannot lock)"

# ── 2c. A path containing a NEWLINE ───────────────────────────────────────────
# One entry splits into two lines that neither the producer nor the checker can
# hash — and both agree on the same garbage, so a naive line-wise reader passes.
fresh_fixture
touch "$_fix/hooks/gate-scripts/lib/two
lines.sh" 2>/dev/null
if [[ -e "$_fix/hooks/gate-scripts/lib/two
lines.sh" ]]; then
    "$GATE_INTEGRITY" --root "$_fix" --check >/dev/null 2>&1
    assert "$(( $? == 0 ? 1 : 0 ))" "a locked path containing a NEWLINE fails closed"
else
    # Refuse to pass by not-testing: a filesystem that cannot hold the name makes
    # the assertion unprovable here, and a silent skip is what the CI runner's
    # skip-masking guard exists to catch.
    assert 1 "a locked path containing a NEWLINE fails closed (could not create the fixture name)"
fi

# ── 2d. The ONE exemption is bytecode INSIDE __pycache__, and no wider ───────
# Python writes `lib/__pycache__/*.pyc` the first time a gate imports a locked
# module — including while this very suite runs — so that bytecode is exempt or
# the check fails on an otherwise untouched tree.
fresh_fixture
mkdir -p "$_fix/hooks/gate-scripts/lib/__pycache__"
printf 'not really bytecode\n' > "$_fix/hooks/gate-scripts/lib/__pycache__/marker_ops.cpython-314.pyc"
"$GATE_INTEGRITY" --root "$_fix" --check >/dev/null 2>&1
assert $? "a regenerated __pycache__/*.pyc does not break the check (the one exemption)"

# shellcheck disable=SC2016 # Intentional: a literal $CLAUDE_PLUGIN_ROOT / backtick, not an expansion
printf 'node "$CLAUDE_PLUGIN_ROOT/scripts/hooks/blocking.js"\n' \
    > "$_fix/hooks/gate-scripts/lib/__pycache__/evil.sh"
_out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
if [[ $? -ne 0 && "$_out" == *"evil.sh"* ]]; then
    assert 0 "↳ a non-.pyc file parked inside __pycache__ still fails, by name"
else
    printf '  ↳ output: %s\n' "$_out"
    assert 1 "↳ a non-.pyc file parked inside __pycache__ still fails, by name"
fi

# The direction an UNANCHORED `! -name '*.pyc'` gets wrong, and the one that
# matters most: a SOURCELESS `.pyc` sitting beside the locked modules, with no
# `.py` of its own. Four gates do `sys.path.insert(0, <lib dir>)` and then
# `import json, re, os`, and Python 3's SourcelessFileLoader imports a bare
# `.pyc` — so `lib/json.pyc` shadows stdlib `json` at sys.path[0] inside a
# blocking gate, needing no matching mtime or size. CPython never writes
# bytecode there (PEP 3147: always `__pycache__`), so nothing legitimate is
# lost by refusing it.
fresh_fixture
printf 'sourceless bytecode\n' > "$_fix/hooks/gate-scripts/lib/json.pyc"
_out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
if [[ $? -ne 0 && "$_out" == *"json.pyc"* ]]; then
    assert 0 "↳ a SOURCELESS .pyc beside the locked modules fails, by name (exemption is -path-anchored)"
else
    printf '  ↳ output: %s\n' "$_out"
    assert 1 "↳ a SOURCELESS .pyc beside the locked modules fails, by name (exemption is -path-anchored)"
fi

# ── 2e. Empty locked directories are a disarmed tree, not a recordable one ────
# `printf '%s\n' ""` writes a lone newline: 1 byte, which clears a `-s` test and
# has a gate surface holding ZERO scripts certify as "OK — 1 files match".
fresh_fixture
rm -rf "${_fix:?}/hooks/gate-scripts" "${_fix:?}/scripts/hooks"
mkdir -p "$_fix/hooks/gate-scripts" "$_fix/scripts/hooks"
"$GATE_INTEGRITY" --root "$_fix" --update >/dev/null 2>&1
assert "$(( $? == 0 ? 1 : 0 ))" "--update refuses to record an EMPTY listing (two present-but-empty locked dirs)"
"$GATE_INTEGRITY" --root "$_fix" --check >/dev/null 2>&1
assert "$(( $? == 0 ? 1 : 0 ))" "↳ and --check on that tree fails closed rather than certifying zero scripts"

# ── 3. A locked file DELETED ──────────────────────────────────────────────────
# Removing a gate script disarms whatever it enforced. That is a content change
# in the direction the lock most has to notice, so it is asserted separately
# from the modify case rather than assumed to fall out of the same diff.
fresh_fixture
rm -f "$_fix/hooks/gate-scripts/pre-commit-gate.sh"
_out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
if [[ $? -ne 0 && "$_out" == *"pre-commit-gate.sh"* ]]; then
    assert 0 "deleting a locked gate script fails the check, by name"
else
    printf '  ↳ output: %s\n' "$_out"
    assert 1 "deleting a locked gate script fails the check, by name"
fi

# ── 4. Fail CLOSED on a missing or empty lock ─────────────────────────────────
# An absent lock is the state a bypass leaves behind. "No lock, nothing to
# compare, pass" is the silent fail-open this whole control exists to avoid.
fresh_fixture
rm -f "$_fix/.gate-integrity.lock"
"$GATE_INTEGRITY" --root "$_fix" --check >/dev/null 2>&1
assert "$(( $? == 0 ? 1 : 0 ))" "a MISSING lock fails closed (never 'nothing to compare, pass')"

fresh_fixture
: > "$_fix/.gate-integrity.lock"
"$GATE_INTEGRITY" --root "$_fix" --check >/dev/null 2>&1
assert "$(( $? == 0 ? 1 : 0 ))" "an EMPTY lock fails closed"

# ── 4c. The lock file itself must be a regular file ───────────────────────────
# `.gate-integrity.lock` is TRACKED, so a PR controls what it is — including
# making it a symlink. `>` follows one, which turns the documented `--update`
# into an arbitrary write against any target the operator can write; reading
# through one sources the comparison from outside the tree. Both modes refuse.
fresh_fixture
_target="$_fix/would-be-overwritten"
printf 'ORIGINAL\n' > "$_target"
rm -f "$_fix/.gate-integrity.lock"
ln -s "$_target" "$_fix/.gate-integrity.lock"
"$GATE_INTEGRITY" --root "$_fix" --update >/dev/null 2>&1
assert "$(( $? == 0 ? 1 : 0 ))" "--update refuses a SYMLINKED lock (no arbitrary write through it)"
_target_after="$(cat "$_target")"
if [[ "$_target_after" == "ORIGINAL" ]]; then
    assert 0 "↳ and the symlink target is untouched"
else
    assert 1 "↳ and the symlink target is untouched"
fi
"$GATE_INTEGRITY" --root "$_fix" --check >/dev/null 2>&1
assert "$(( $? == 0 ? 1 : 0 ))" "↳ --check refuses to verify against a SYMLINKED lock"
rm -f "$_fix/.gate-integrity.lock"

# ── 4d. A partial enumeration is never recorded or accepted ───────────────────
# `find` can emit a PARTIAL listing and THEN exit nonzero — an unreadable subtree
# does exactly that. Under `pipefail` with no `set -e` a bare pipeline swallows
# that status, so --update records the partial lock and --check accepts the same
# partial tree: a fail-OPEN over precisely the files that could not be read.
fresh_fixture
chmod 000 "$_fix/hooks/gate-scripts/lib" 2>/dev/null
if [[ ! -r "$_fix/hooks/gate-scripts/lib" ]]; then
    "$GATE_INTEGRITY" --root "$_fix" --check >/dev/null 2>&1
    assert "$(( $? == 0 ? 1 : 0 ))" "an UNREADABLE locked subtree fails closed (partial find listing not accepted)"
    "$GATE_INTEGRITY" --root "$_fix" --update >/dev/null 2>&1
    assert "$(( $? == 0 ? 1 : 0 ))" "↳ and --update refuses to record the partial listing"
    chmod 755 "$_fix/hooks/gate-scripts/lib" 2>/dev/null
else
    # Running as root, or a filesystem that ignores the mode: `chmod 000` cannot
    # make the subtree unreadable, so this PARTICULAR fixture is unprovable. Not
    # a failure and not a silent hole either — the deterministic `find` shim
    # below asserts the same guard unconditionally, on every host.
    chmod 755 "$_fix/hooks/gate-scripts/lib" 2>/dev/null
    printf '  note the chmod fixture is inert here (root or a mode-ignoring filesystem) — the find shim below covers the same guard\n'
fi

# The same guard, proven WITHOUT depending on filesystem permissions. A `find`
# that emits its full listing and THEN exits nonzero is the general shape of the
# fail-OPEN above (an unreadable subtree is only one way to produce it), and a
# PATH shim reproduces it deterministically as root and non-root alike. The
# assertion matches the enumeration message, not just the exit code: a shim that
# failed to intercept would otherwise "pass" for the wrong reason.
fresh_fixture
_shim="$(mktemp -d)"
# `command -v find` returns the bare word `find` when a shell FUNCTION or ALIAS
# by that name is in scope. The shim would then re-invoke `find` through a PATH
# whose first entry is the shim itself — unbounded recursive process creation,
# not a test. Resolve with `-p` (the standard utility PATH, which ignores
# functions and aliases) and accept only an ABSOLUTE path.
_real_find="$(command -v -p find 2>/dev/null)"
case "$_real_find" in
    /*) ;;
    *) _real_find="" ;;
esac
if [[ -n "$_shim" && -d "$_shim" && -n "$_real_find" && -x "$_real_find" ]]; then
    {
        printf '#!/usr/bin/env bash\n'
        printf '%s "$@"\n' "$_real_find"
        printf 'exit 1\n'
    } > "$_shim/find"
    chmod 755 "$_shim/find"
    _out="$(PATH="$_shim:$PATH" "$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
    _rc=$?
    if [[ "$_rc" -ne 0 && "$_out" == *"could not enumerate the locked directories"* ]]; then
        assert 0 "a find that lists and THEN fails is refused by --check (status not swallowed)"
    else
        printf '  ↳ rc=%s output: %s\n' "$_rc" "$_out"
        assert 1 "a find that lists and THEN fails is refused by --check (status not swallowed)"
    fi
    _out="$(PATH="$_shim:$PATH" "$GATE_INTEGRITY" --root "$_fix" --update 2>&1)"
    _rc=$?
    if [[ "$_rc" -ne 0 && "$_out" == *"could not enumerate the locked directories"* ]]; then
        assert 0 "↳ and --update refuses to record that listing"
    else
        printf '  ↳ rc=%s output: %s\n' "$_rc" "$_out"
        assert 1 "↳ and --update refuses to record that listing"
    fi
    rm -rf "$_shim"
else
    assert 1 "a find that lists and THEN fails is refused by --check (no tempdir, or no absolute find to shim)"
fi

# ── 4e. A TRACKED .pyc under a locked directory is refused ────────────────────
# The `.pyc` exemption is only safe if what it skips cannot arrive through a PR.
# PEP 552 makes that sharp: an UNCHECKED hash-based .pyc (flags bit 1 clear) is
# loaded with NO comparison to its source — not mtime, not size, not hash — so a
# tracked `lib/__pycache__/marker_ops.cpython-XXX.pyc` would replace the locked
# marker_ops.py's behaviour while both --check and --update omitted it.
_repo="$(mktemp -d)"
if [[ -n "$_repo" && -d "$_repo" ]]; then
    mkdir -p "$_repo/hooks" "$_repo/scripts"
    cp -R "$REPO_ROOT/hooks/gate-scripts" "$_repo/hooks/gate-scripts"
    cp -R "$REPO_ROOT/scripts/hooks" "$_repo/scripts/hooks"
    git -C "$_repo" init -q 2>/dev/null
    git -C "$_repo" config user.email t@t.invalid 2>/dev/null
    git -C "$_repo" config user.name t 2>/dev/null
    "$GATE_INTEGRITY" --root "$_repo" --update >/dev/null 2>&1
    "$GATE_INTEGRITY" --root "$_repo" --check >/dev/null 2>&1
    assert $? "↳ control: a git-repo fixture with no tracked bytecode verifies clean"

    mkdir -p "$_repo/hooks/gate-scripts/lib/__pycache__"
    printf 'unchecked hash-based bytecode\n' \
        > "$_repo/hooks/gate-scripts/lib/__pycache__/marker_ops.cpython-314.pyc"
    # `-f`: the exemption's whole point is that this path is gitignored, and the
    # attack is precisely someone forcing it into the index anyway.
    git -C "$_repo" add -f hooks/gate-scripts/lib/__pycache__/marker_ops.cpython-314.pyc 2>/dev/null
    _out="$("$GATE_INTEGRITY" --root "$_repo" --check 2>&1)"
    if [[ $? -ne 0 && "$_out" == *"marker_ops.cpython-314.pyc"* ]]; then
        assert 0 "a TRACKED .pyc under a locked directory fails the check, by name"
    else
        printf '  ↳ output: %s\n' "$_out"
        assert 1 "a TRACKED .pyc under a locked directory fails the check, by name"
    fi
    "$GATE_INTEGRITY" --root "$_repo" --update >/dev/null 2>&1
    assert "$(( $? == 0 ? 1 : 0 ))" "↳ and --update refuses to record a tree with tracked bytecode"
    # An INHERITED `tracked_pyc` must not stand in for the query: `${tracked_pyc+x}`
    # used to gate the `git ls-files` call, so an exported empty value had a detected
    # repository skip it. Asserted HERE, on a tree that DOES have tracked bytecode —
    # against a clean tree the check returns OK either way and proves nothing.
    _out="$(tracked_pyc="" "$GATE_INTEGRITY" --root "$_repo" --check 2>&1)"
    if [[ $? -ne 0 && "$_out" == *"marker_ops.cpython-314.pyc"* ]]; then
        assert 0 "↳ an exported tracked_pyc does not stand in for the index query"
    else
        printf '  ↳ output: %s\n' "$_out"
        assert 1 "↳ an exported tracked_pyc does not stand in for the index query"
    fi
    # `GIT_INDEX_FILE` pointing at a nonexistent path leaves `rev-parse --git-dir`
    # succeeding while `ls-files` returns EMPTY with exit 0 — a clean bill of health
    # for a query that read nothing. Gate env is repo-injectable, so the check has to
    # strip it rather than trust it.
    _out="$(GIT_INDEX_FILE=/nonexistent-gate-integrity-index "$GATE_INTEGRITY" --root "$_repo" --check 2>&1)"
    if [[ $? -ne 0 && "$_out" == *"marker_ops.cpython-314.pyc"* ]]; then
        assert 0 "↳ GIT_INDEX_FILE cannot redirect the index query to an empty result"
    else
        printf '  ↳ output: %s\n' "$_out"
        assert 1 "↳ GIT_INDEX_FILE cannot redirect the index query to an empty result"
    fi
    _out="$(GIT_DIR=/nonexistent-gate-integrity-gitdir "$GATE_INTEGRITY" --root "$_repo" --check 2>&1)"
    if [[ $? -ne 0 && "$_out" == *"marker_ops.cpython-314.pyc"* ]]; then
        assert 0 "↳ nor can GIT_DIR"
    else
        printf '  ↳ output: %s\n' "$_out"
        assert 1 "↳ nor can GIT_DIR"
    fi
    # Pathspec MODE is env-selectable too: under GIT_LITERAL_PATHSPECS a `*.pyc`
    # pathspec matches nothing and ls-files exits 0 with empty output. The query uses
    # directory pathspecs and filters afterwards, so the mode cannot reach it.
    for _v in GIT_LITERAL_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS; do
        _out="$(env "$_v=1" "$GATE_INTEGRITY" --root "$_repo" --check 2>&1)"
        if [[ $? -ne 0 && "$_out" == *"marker_ops.cpython-314.pyc"* ]]; then
            assert 0 "↳ nor can $_v"
        else
            printf '  ↳ output: %s\n' "$_out"
            assert 1 "↳ nor can $_v"
        fi
    done
    # A MISSING `.git/index` is read by ls-files as an empty index, exit 0 — so a
    # local `rm .git/index` used to make the whole check vacuous. HEAD is queried
    # alongside it for exactly this.
    git -C "$_repo" commit -qm "bytecode" 2>/dev/null
    rm -f "$_repo/.git/index"
    _out="$("$GATE_INTEGRITY" --root "$_repo" --check 2>&1)"
    if [[ $? -ne 0 && "$_out" == *"marker_ops.cpython-314.pyc"* ]]; then
        assert 0 "↳ nor does deleting .git/index (HEAD is queried alongside the index)"
    else
        printf '  ↳ output: %s\n' "$_out"
        assert 1 "↳ nor does deleting .git/index (HEAD is queried alongside the index)"
    fi
    # git's DEFAULT listing C-QUOTES a path containing a newline, so such a name is
    # emitted ending in a QUOTE and a `\.pyc$` match on it fails — the file slips
    # past on the strength of its own name, and the digest never sees it either
    # because `__pycache__/*.pyc` is exempt from the enumeration. `-z` emits raw
    # bytes. This is the one bytecode shape that no other assertion here covers.
    _nl_name="hooks/gate-scripts/lib/__pycache__/we
ird.pyc"
    printf 'quoted-path bytecode\n' > "$_repo/$_nl_name" 2>/dev/null
    if [[ -e "$_repo/$_nl_name" ]]; then
        git -C "$_repo" add -f -- "$_nl_name" 2>/dev/null
        _out="$("$GATE_INTEGRITY" --root "$_repo" --check 2>&1)"
        if [[ $? -ne 0 && "$_out" == *"ird.pyc"* ]]; then
            assert 0 "↳ a tracked .pyc whose NAME contains a newline is still found (-z, not C-quoted)"
        else
            printf '  ↳ output: %s\n' "$_out"
            assert 1 "↳ a tracked .pyc whose NAME contains a newline is still found (-z, not C-quoted)"
        fi
        git -C "$_repo" rm -q --cached -- "$_nl_name" 2>/dev/null
        rm -f "$_repo/$_nl_name"
    else
        assert 1 "↳ a tracked .pyc whose NAME contains a newline is still found (fixture name unavailable)"
    fi
    rm -rf "$_repo"
else
    assert 1 "a TRACKED .pyc under a locked directory fails the check (no fixture tempdir)"
fi

# ── 4e-bis. An ORPHAN branch is a queryable repository, not a query failure ───
# `git switch --orphan` leaves HEAD unborn while other refs still carry commits.
# Gating the HEAD half of the tracked-bytecode query on "does the repository have
# commits anywhere" (rev-list --all) rather than on "does HEAD resolve" made
# `ls-tree ... HEAD` die with "Not a valid object name HEAD" and failed BOTH modes
# on a tree with nothing wrong with it. The index half still covers this state.
_orph="$(mktemp -d)"
if [[ -n "$_orph" && -d "$_orph" ]]; then
    git -C "$_orph" init -q 2>/dev/null
    git -C "$_orph" config user.email t@t.invalid 2>/dev/null
    git -C "$_orph" config user.name t 2>/dev/null
    printf 'base\n' > "$_orph/base.txt"
    git -C "$_orph" add -A 2>/dev/null
    git -C "$_orph" commit -qm "base" 2>/dev/null
    # After the switch: `rev-list -n1 --all` is NONEMPTY (the base commit is still
    # reachable through the original branch) while HEAD itself is unborn. The switch
    # also EMPTIES the working tree, so the locked directories are populated after it
    # — an empty listing is refused for its own reasons and would not test this.
    git -C "$_orph" switch -q --orphan fresh 2>/dev/null
    mkdir -p "$_orph/hooks" "$_orph/scripts"
    cp -R "$REPO_ROOT/hooks/gate-scripts" "$_orph/hooks/gate-scripts"
    cp -R "$REPO_ROOT/scripts/hooks" "$_orph/scripts/hooks"
    _unborn=1
    git -C "$_orph" rev-parse -q --verify HEAD >/dev/null 2>&1 && _unborn=0
    [[ -n "$(git -C "$_orph" rev-list -n1 --all 2>/dev/null)" ]] || _unborn=0
    if [[ "$_unborn" -eq 1 ]]; then
        "$GATE_INTEGRITY" --root "$_orph" --update >/dev/null 2>&1
        assert $? "--update succeeds on an orphan branch (unborn HEAD, commits on another ref)"
        _out="$("$GATE_INTEGRITY" --root "$_orph" --check 2>&1)"; _rc=$?
        if [[ "$_rc" -eq 0 ]]; then
            assert 0 "↳ and --check verifies it rather than reporting a git query failure"
        else
            printf '  ↳ output: %s\n' "$_out"
            assert 1 "↳ and --check verifies it rather than reporting a git query failure"
        fi
    else
        printf '  ↳ SKIP: this git does not produce the unborn-HEAD-with-commits state\n'
    fi
    rm -rf "$_orph"
else
    assert 1 "--update succeeds on an orphan branch (no fixture tempdir)"
fi

# ── 4f. --update leaves the lock world-readable ───────────────────────────────
# The atomic write goes through mkstemp, which creates 0600. A bare rename would
# hand the tracked lock that mode and make it unreadable to another account in a
# shared checkout — and inheriting the existing mode would perpetuate a 0600 lock
# once one had been produced.
fresh_fixture
chmod 600 "$_fix/.gate-integrity.lock"
"$GATE_INTEGRITY" --root "$_fix" --update >/dev/null 2>&1
_mode="$(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$_fix/.gate-integrity.lock")"
if [[ "$_mode" == "0o644" ]]; then
    assert 0 "--update writes a 0644 lock (mkstemp's 0600 is not handed to a tracked file)"
else
    printf '  ↳ mode: %s\n' "$_mode"
    assert 1 "--update writes a 0644 lock (mkstemp's 0600 is not handed to a tracked file)"
fi

# A root BELOW the repository top level has no `.git` of its own, so a marker-only
# test would read it as "not a repository" and skip the check entirely. The probe
# is what recognises it — this is the regression that shape caused.
_sub="$(mktemp -d)"
if [[ -n "$_sub" && -d "$_sub" ]]; then
    git -C "$_sub" init -q 2>/dev/null
    git -C "$_sub" config user.email t@t.invalid 2>/dev/null
    git -C "$_sub" config user.name t 2>/dev/null
    mkdir -p "$_sub/nested/hooks" "$_sub/nested/scripts"
    cp -R "$REPO_ROOT/hooks/gate-scripts" "$_sub/nested/hooks/gate-scripts"
    cp -R "$REPO_ROOT/scripts/hooks" "$_sub/nested/scripts/hooks"
    mkdir -p "$_sub/nested/hooks/gate-scripts/lib/__pycache__"
    printf 'unchecked hash-based bytecode\n' \
        > "$_sub/nested/hooks/gate-scripts/lib/__pycache__/marker_ops.cpython-314.pyc"
    git -C "$_sub" add -f nested/hooks/gate-scripts/lib/__pycache__/marker_ops.cpython-314.pyc 2>/dev/null
    _out="$("$GATE_INTEGRITY" --root "$_sub/nested" --check 2>&1)"
    # The STATUS as well as the message: a --check that named the tracked bytecode
    # and then exited 0 would violate the fail-closed contract while still matching
    # on output alone.
    _rc=$?
    if [[ "$_rc" -ne 0 && ( "$_out" == *"marker_ops.cpython-314.pyc"* || "$_out" == *"TRACKED"* ) ]]; then
        assert 0 "↳ a root BELOW the repo top level is still recognised as a repository"
    else
        printf '  ↳ rc=%s output: %s\n' "$_rc" "$_out"
        assert 1 "↳ a root BELOW the repo top level is still recognised as a repository"
    fi
    rm -rf "$_sub"
else
    assert 1 "↳ a root BELOW the repo top level is still recognised as a repository (no tempdir)"
fi

# ── 4g. A checkout whose index cannot be queried fails closed ─────────────────
# The tracked-bytecode check is the ONLY cover for the .pyc files the digest
# omits, so "the git probe failed, assume not a repository" would silently retire
# it on an absent git binary or unreadable metadata. Presence of `.git` — not the
# probe succeeding — is what says a real checkout is here.
fresh_fixture
rm -rf "$_fix/.git"; printf 'not a git directory\n' > "$_fix/.git"
_out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
if [[ $? -ne 0 && "$_out" == *"no queryable git repository"* ]]; then
    assert 0 "a checkout with an UNQUERYABLE index fails closed (not read as 'no repository')"
else
    printf '  ↳ output: %s\n' "$_out"
    assert 1 "a checkout with an UNQUERYABLE index fails closed (not read as 'no repository')"
fi
rm -rf "$_fix/.git"

# A DANGLING `.git` symlink is the same case wearing the shape `-e` cannot see:
# `-e` follows the link and is false, so a bare `-e` test reads unqueryable
# metadata as "no repository" and skips the check.
rm -rf "$_fix/.git"; ln -s "$_fix/nonexistent-git-dir" "$_fix/.git"
_out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
if [[ $? -ne 0 && "$_out" == *"no queryable git repository"* ]]; then
    assert 0 "↳ a DANGLING .git symlink fails closed too (-e alone would miss it)"
else
    printf '  ↳ output: %s\n' "$_out"
    assert 1 "↳ a DANGLING .git symlink fails closed too (-e alone would miss it)"
fi
rm -rf "$_fix/.git"

# ── 4h. A broken or absent git fails closed ───────────────────────────────────
# With git unavailable the probe fails for a reason that proves nothing, and a root
# below the repository top level legitimately has no `.git` marker — so a
# probe-then-marker shape falls straight through and disables the check. `git
# --version` covers both "not installed" and "broken binary"; a stub that exits 1
# drives the second.
fresh_fixture
_stub="$(mktemp -d)"
if [[ -n "$_stub" && -d "$_stub" ]]; then
    printf '#!/bin/sh\nexit 1\n' > "$_stub/git"
    chmod +x "$_stub/git"
    _out="$(PATH="$_stub:$PATH" "$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
    if [[ $? -ne 0 && "$_out" == *"no queryable git repository"* ]]; then
        assert 0 "a BROKEN or absent git fails closed (the tracked-bytecode check is not skipped)"
    else
        printf '  ↳ output: %s\n' "$_out"
        assert 1 "a BROKEN or absent git fails closed (the tracked-bytecode check is not skipped)"
    fi
    rm -rf "$_stub"
else
    assert 1 "a BROKEN or absent git fails closed (no stub tempdir)"
fi

# ── 4b. Argument handling terminates and rejects ──────────────────────────────
# A trailing bare `--root` used to leave $# at 1 and spin the parse loop forever
# — a hang, which in CI reads as a per-test timeout rather than as a refusal.
_rc=0
"$GATE_INTEGRITY" --root >/dev/null 2>&1 || _rc=$?
assert "$(( _rc == 2 ? 0 : 1 ))" "a trailing bare --root exits 2 rather than looping forever"
_rc=0
"$GATE_INTEGRITY" --root /nonexistent-gate-integrity-root >/dev/null 2>&1 || _rc=$?
assert "$(( _rc == 2 ? 0 : 1 ))" "a --root that is not a directory exits 2"
_rc=0
"$GATE_INTEGRITY" --bogus >/dev/null 2>&1 || _rc=$?
assert "$(( _rc == 2 ? 0 : 1 ))" "an unknown argument exits 2 rather than defaulting to a check"

# ── 5. --update records the change, and only then does the check pass ─────────
# The lockfile trade, asserted end to end: the edit is not prevented, it is made
# to surface as a recorded diff. `--update` after the #742 append must both make
# the check green AND move the launcher's digest — a regen that changed nothing
# would mean the producer never saw the edit.
fresh_fixture
_before="$(grep 'load-orchestrator\.sh$' "$_fix/.gate-integrity.lock")"
# shellcheck disable=SC2016 # Intentional: a literal $CLAUDE_PLUGIN_ROOT / backtick, not an expansion
printf '\nnode "$CLAUDE_PLUGIN_ROOT/scripts/hooks/blocking.js"\n' \
    >> "$_fix/hooks/gate-scripts/load-orchestrator.sh"
"$GATE_INTEGRITY" --root "$_fix" --update >/dev/null
_after="$(grep 'load-orchestrator\.sh$' "$_fix/.gate-integrity.lock")"
"$GATE_INTEGRITY" --root "$_fix" --check >/dev/null 2>&1
_rc=$?
if [[ "$_rc" -eq 0 && -n "$_before" && "$_before" != "$_after" ]]; then
    assert 0 "--update records the edit as a digest change, and the check then passes (visibility, not prevention)"
else
    assert 1 "--update records the edit as a digest change, and the check then passes (visibility, not prevention)"
fi

# ── 6. A missing locked DIRECTORY fails closed ────────────────────────────────
# Deleting the directory outright, rather than a file in it, must not read as
# "nothing to enumerate" — the same unresolvable-inputs-means-block rule.
fresh_fixture
rm -rf "$_fix/scripts/hooks"
"$GATE_INTEGRITY" --root "$_fix" --check >/dev/null 2>&1
assert "$(( $? == 0 ? 1 : 0 ))" "a missing locked DIRECTORY fails closed"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "ALL GATE-INTEGRITY ASSERTIONS PASSED"
