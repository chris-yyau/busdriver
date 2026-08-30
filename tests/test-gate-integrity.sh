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
    # Host __pycache__ from earlier suite tests must not ride into the fixture —
    # those caches are authenticated against THIS check's python, and a polluted
    # live tree would make every control look like a body mismatch.
    find "$_fix/hooks/gate-scripts" "$_fix/scripts/hooks" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
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
#
# The fixture is a REAL cache written by python3, not a stub with a `.pyc` name:
# since #797 the exemption covers only caches Python revalidates against their
# source, so a stub would no longer be exempt and would prove nothing about the
# tree that has merely run the gates.
compile_pyc() {  # compile_pyc <TIMESTAMP|CHECKED_HASH|UNCHECKED_HASH>
    # Status is load-bearing: without `set -e`, a failed compile leaves an empty
    # __pycache__ and the next --check passes for the wrong reason. Callers must
    # assert $? (and we refuse to report success unless a .pyc actually exists).
    rm -rf "$_fix/hooks/gate-scripts/lib/__pycache__"
    _PYC_SRC="$_fix/hooks/gate-scripts/lib/marker_ops.py" _PYC_MODE="$1" python3 -c '
import os, py_compile
py_compile.compile(os.environ["_PYC_SRC"], doraise=True,
                   invalidation_mode=py_compile.PycInvalidationMode[os.environ["_PYC_MODE"]])'         || return 1
    find "$_fix/hooks/gate-scripts/lib/__pycache__" -name '*.pyc' ! -type d | grep -q .
}

fresh_fixture
compile_pyc TIMESTAMP
assert $? "↳ fixture: python3 wrote a real timestamp cache into lib/__pycache__"
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

# ── 2d-bis. #797: an UNTRACKED unchecked-hash .pyc inside __pycache__ ────────
# The exemption used to be bounded on TRACKEDNESS alone: a `.pyc` arriving
# through a PR is refused by name, but one dropped straight onto disk was
# neither hashed nor refused, so it produced no lockfile diff and `--check`
# still succeeded. PEP 552 is what makes that matter — an UNCHECKED hash-based
# cache (flags bit 0 set, bit 1 clear) is loaded with NO comparison to its
# source at all, not mtime, not size, not hash — so it replaces a locked
# module's behaviour inside a blocking gate. The asymmetry is the whole point:
# editing the locked `.py` is DETECTED, dropping the `.pyc` beside it was not.
fresh_fixture
compile_pyc UNCHECKED_HASH
assert $? "↳ fixture: wrote an UNCHECKED_HASH cache"
_out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
if [[ $? -ne 0 && "$_out" == *"marker_ops"* && "$_out" == *"UNCHECKED"* ]]; then
    assert 0 "an UNTRACKED unchecked-hash .pyc inside __pycache__ fails the check, by name"
else
    printf '  ↳ output: %s\n' "$_out"
    assert 1 "an UNTRACKED unchecked-hash .pyc inside __pycache__ fails the check, by name"
fi

# `--update` refuses it too. The classification runs BEFORE the mode dispatch,
# so the forgery cannot be laundered by recording a fresh lock over the tree
# holding it — and the operator is told to delete regenerable bytecode instead.
_out="$("$GATE_INTEGRITY" --root "$_fix" --update 2>&1)"
if [[ $? -ne 0 && "$_out" == *"marker_ops"* ]]; then
    assert 0 "↳ --update refuses it as well (classification precedes the mode dispatch)"
else
    printf '  ↳ output: %s\n' "$_out"
    assert 1 "↳ --update refuses it as well (classification precedes the mode dispatch)"
fi

# The narrowing is on UNVALIDATED content, not on hash-based caches: a
# checked-hash cache is rehashed against the `.py` beside it, which IS locked,
# so it stays exempt exactly like the timestamp cache in 2d.
compile_pyc CHECKED_HASH
assert $? "↳ fixture: wrote a CHECKED_HASH cache"
"$GATE_INTEGRITY" --root "$_fix" --check >/dev/null 2>&1
assert $? "↳ a CHECKED-hash cache still passes (the exemption is narrowed, not removed)"

# Header flags alone are not authentication: PEP 552's timestamp / checked-hash
# modes only bind the SOURCE's metadata or hash, so a valid header spliced onto
# a malicious marshal body still loads. The body-match half of the classifier
# is what closes that — prove it with a real splice, not a stub name.
compile_pyc TIMESTAMP
assert $? "↳ fixture: wrote a TIMESTAMP cache for the splice"
_PYC="$(find "$_fix/hooks/gate-scripts/lib/__pycache__" -name 'marker_ops*.pyc' ! -type d | head -n1)"
if [[ -n "$_PYC" && -f "$_PYC" ]]; then
    assert 0 "↳ fixture: located the timestamp cache to splice"
else
    assert 1 "↳ fixture: located the timestamp cache to splice"
fi
_evil_src="$_fix/hooks/gate-scripts/lib/__spliced_evil.py"
_evil_pyc="$_fix/hooks/gate-scripts/lib/__pycache__/__spliced_evil.pyc"
printf 'x = 999\n' > "$_evil_src"
E="$_evil_src" P="$_evil_pyc" python3 -c \
    'import os, py_compile; py_compile.compile(os.environ["E"], cfile=os.environ["P"], doraise=True)'
G="$_PYC" E="$_evil_pyc" O="$_PYC" python3 -c '
import os
good, evil, out = os.environ["G"], os.environ["E"], os.environ["O"]
with open(good, "rb") as fh: hdr = fh.read(16)
with open(evil, "rb") as fh: body = fh.read()[16:]
with open(out, "wb") as fh: fh.write(hdr + body)
'
rm -f "$_evil_src" "$_evil_pyc"
_out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
_rc=$?
if [[ "$_rc" -ne 0 && "$_out" == *"marker_ops"* && "$_out" == *"body"* ]]; then
    assert 0 "↳ a TIMESTAMP header spliced onto a foreign bytecode body fails, by name"
else
    printf '  ↳ output: %s\n' "$_out"
    assert 1 "↳ a TIMESTAMP header spliced onto a foreign bytecode body fails, by name"
fi

# CodeType == ignores co_stacksize; a body that only inflates it must still fail.
compile_pyc TIMESTAMP
assert $? "↳ fixture: wrote a TIMESTAMP cache for the stacksize forgery"
_PYC="$(find "$_fix/hooks/gate-scripts/lib/__pycache__" -name 'marker_ops*.pyc' ! -type d | head -n1)"
_PYC="$_PYC" python3 -c '
import marshal, os, types
path = os.environ["_PYC"]
with open(path, "rb") as fh:
    data = fh.read()
code = marshal.loads(data[16:])
fat = code.replace(co_stacksize=2147483647)
with open(path, "wb") as fh:
    fh.write(data[:16] + marshal.dumps(fat))
'
_out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
_rc=$?
if [[ "$_rc" -ne 0 && "$_out" == *"marker_ops"* && "$_out" == *"body"* ]]; then
    assert 0 "↳ a cache whose only mutation is co_stacksize still fails (structural compare includes co_stacksize)"
else
    printf '  ↳ output: %s\n' "$_out"
    assert 1 "↳ a cache whose only mutation is co_stacksize still fails (structural compare includes co_stacksize)"
fi

# co_filename is observable at runtime; a body that only retargets it must fail.
compile_pyc TIMESTAMP
assert $? "↳ fixture: wrote a TIMESTAMP cache for the co_filename forgery"
_PYC="$(find "$_fix/hooks/gate-scripts/lib/__pycache__" -name 'marker_ops*.pyc' ! -type d | head -n1)"
_PYC="$_PYC" python3 -c '
import marshal, os
path = os.environ["_PYC"]
with open(path, "rb") as fh:
    data = fh.read()
code = marshal.loads(data[16:])
forged = code.replace(co_filename="/attacker/chosen.py")
with open(path, "wb") as fh:
    fh.write(data[:16] + marshal.dumps(forged))
'
_out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
_rc=$?
if [[ "$_rc" -ne 0 && "$_out" == *"marker_ops"* && "$_out" == *"body"* ]]; then
    assert 0 "↳ a cache whose only mutation is co_filename still fails"
else
    printf '  ↳ output: %s\n' "$_out"
    assert 1 "↳ a cache whose only mutation is co_filename still fails"
fi

# A consts-only mutation (same shape, different value) must fail too.
compile_pyc TIMESTAMP
assert $? "↳ fixture: wrote a TIMESTAMP cache for the consts forgery"
_PYC="$(find "$_fix/hooks/gate-scripts/lib/__pycache__" -name 'marker_ops*.pyc' ! -type d | head -n1)"
_PYC="$_PYC" python3 -c '
import marshal, os
path = os.environ["_PYC"]
with open(path, "rb") as fh:
    data = fh.read()
code = marshal.loads(data[16:])
# Flip a string constant if present; otherwise append a sentinel.
consts = list(code.co_consts)
for i, c in enumerate(consts):
    if isinstance(c, str) and c:
        consts[i] = c + "/forged"
        break
else:
    consts.append("__forged__")
forged = code.replace(co_consts=tuple(consts))
with open(path, "wb") as fh:
    fh.write(data[:16] + marshal.dumps(forged))
'
_out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
_rc=$?
if [[ "$_rc" -ne 0 && "$_out" == *"marker_ops"* && "$_out" == *"body"* ]]; then
    assert 0 "↳ a cache whose only mutation is a co_consts string still fails"
else
    printf '  ↳ output: %s\n' "$_out"
    assert 1 "↳ a cache whose only mutation is a co_consts string still fails"
fi

# 0.0 == -0.0 under Python ==, but math.copysign diverges — marshal.dumps must
# catch a signbit-only const mutation. Use a dedicated module that ALREADY
# contains a +0.0 literal so the flip is length-preserving (appending a const
# would fail same_code on length alone and miss the signed-zero path).
rm -rf "$_fix/hooks/gate-scripts/lib/__pycache__"
mkdir -p "$_fix/hooks/gate-scripts/lib/__pycache__"
printf 'X = 0.0\n' > "$_fix/hooks/gate-scripts/lib/signed_zero.py"
_tag="$(python3 -c 'import sys; print("".join(str(x) for x in sys.version_info[:2]))')"
_zero_pyc="$_fix/hooks/gate-scripts/lib/__pycache__/signed_zero.cpython-${_tag}.pyc"
_PYC_SRC="$_fix/hooks/gate-scripts/lib/signed_zero.py" _ZERO="$_zero_pyc" python3 -c '
import os, py_compile
py_compile.compile(os.environ["_PYC_SRC"], cfile=os.environ["_ZERO"], doraise=True,
                   invalidation_mode=py_compile.PycInvalidationMode.TIMESTAMP)'
assert $? "↳ fixture: wrote a signed-zero module cache"
_ZERO="$_zero_pyc" python3 -c '
import marshal, os, math
path = os.environ["_ZERO"]
with open(path, "rb") as fh:
    data = fh.read()
code = marshal.loads(data[16:])
assert any(isinstance(c, float) and c == 0.0 for c in code.co_consts), "fixture lacks +0.0"

def flip(obj):
    if isinstance(obj, float) and obj == 0.0 and not math.copysign(1.0, obj) < 0:
        return -0.0
    if isinstance(obj, tuple):
        return tuple(flip(x) for x in obj)
    if hasattr(obj, "co_code"):
        return obj.replace(co_consts=tuple(flip(c) for c in obj.co_consts))
    return obj

forged = flip(code)
assert forged.co_consts != code.co_consts or any(
    isinstance(a, float) and isinstance(b, float) and a == b == 0.0
    and math.copysign(1.0, a) != math.copysign(1.0, b)
    for a, b in zip(forged.co_consts, code.co_consts)
)
# Length preserved — only the signbit changed.
assert len(forged.co_consts) == len(code.co_consts)
with open(path, "wb") as fh:
    fh.write(data[:16] + marshal.dumps(forged))
'
_out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
_rc=$?
rm -f "$_fix/hooks/gate-scripts/lib/signed_zero.py"
if [[ "$_rc" -ne 0 && "$_out" == *"signed_zero"* && "$_out" == *"body"* ]]; then
    assert 0 "↳ a cache whose only mutation is a +0.0→-0.0 const still fails"
else
    printf '  ↳ output: %s\n' "$_out"
    assert 1 "↳ a cache whose only mutation is a +0.0→-0.0 const still fails"
fi

# Line tables are compared: frame.f_lineno / tracing observe them.
compile_pyc TIMESTAMP
assert $? "↳ fixture: wrote a TIMESTAMP cache for the linetable forgery"
_PYC="$(find "$_fix/hooks/gate-scripts/lib/__pycache__" -name 'marker_ops*.pyc' ! -type d | head -n1)"
_mut_out="$(_PYC="$_PYC" python3 -c '
import marshal, os, sys
path = os.environ["_PYC"]
with open(path, "rb") as fh:
    data = fh.read()
code = marshal.loads(data[16:])
if hasattr(code, "co_linetable") and code.co_linetable:
    forged = code.replace(co_linetable=code.co_linetable + b"\x00")
elif hasattr(code, "co_lnotab") and code.co_lnotab:
    forged = code.replace(co_lnotab=code.co_lnotab + b"\x00")
else:
    sys.stdout.write("SKIP")
    raise SystemExit(0)
with open(path, "wb") as fh:
    fh.write(data[:16] + marshal.dumps(forged))
sys.stdout.write("MUTATED")
')"
if [[ "$_mut_out" == "SKIP" ]]; then
    assert 0 "↳ a cache whose only mutation is co_linetable still fails (skipped: no line table on this Python)"
else
    _out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
    _rc=$?
    if [[ "$_rc" -ne 0 && "$_out" == *"marker_ops"* && "$_out" == *"body"* ]]; then
        assert 0 "↳ a cache whose only mutation is co_linetable still fails"
    else
        printf '  ↳ output: %s\n' "$_out"
        assert 1 "↳ a cache whose only mutation is co_linetable still fails"
    fi
fi

# samefile would accept a hardlink alias; the allowlist must not.
compile_pyc TIMESTAMP
assert $? "↳ fixture: wrote a TIMESTAMP cache for the hardlink alias forgery"
_PYC="$(find "$_fix/hooks/gate-scripts/lib/__pycache__" -name 'marker_ops*.pyc' ! -type d | head -n1)"
_alias="$_fix/hooks/gate-scripts/lib/marker_ops.alias.py"
ln "$_fix/hooks/gate-scripts/lib/marker_ops.py" "$_alias" 2>/dev/null \
    || cp "$_fix/hooks/gate-scripts/lib/marker_ops.py" "$_alias"
_PYC="$_PYC" _ALIAS="$_alias" python3 -c '
import marshal, os
path, alias = os.environ["_PYC"], os.environ["_ALIAS"]
with open(path, "rb") as fh:
    data = fh.read()
code = marshal.loads(data[16:])
forged = code.replace(co_filename=alias)
with open(path, "wb") as fh:
    fh.write(data[:16] + marshal.dumps(forged))
'
_out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
_rc=$?
rm -f "$_alias"
if [[ "$_rc" -ne 0 && "$_out" == *"marker_ops"* && "$_out" == *"body"* ]]; then
    assert 0 "↳ a cache whose co_filename is only a hardlink alias of the source still fails"
else
    printf '  ↳ output: %s\n' "$_out"
    assert 1 "↳ a cache whose co_filename is only a hardlink alias of the source still fails"
fi

# Non-canonical ./ spelling that still realpaths to the source must fail.
compile_pyc TIMESTAMP
assert $? "↳ fixture: wrote a TIMESTAMP cache for the ./ co_filename forgery"
_PYC="$(find "$_fix/hooks/gate-scripts/lib/__pycache__" -name 'marker_ops*.pyc' ! -type d | head -n1)"
_PYC="$_PYC" python3 -c '
import marshal, os
path = os.environ["_PYC"]
with open(path, "rb") as fh:
    data = fh.read()
code = marshal.loads(data[16:])
alias = os.path.dirname(code.co_filename) + "/./" + os.path.basename(code.co_filename)
forged = code.replace(co_filename=alias)
with open(path, "wb") as fh:
    fh.write(data[:16] + marshal.dumps(forged))
'
_out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
_rc=$?
if [[ "$_rc" -ne 0 && "$_out" == *"marker_ops"* && "$_out" == *"body"* ]]; then
    assert 0 "↳ a cache whose co_filename uses a ./ alias of the source still fails"
else
    printf '  ↳ output: %s\n' "$_out"
    assert 1 "↳ a cache whose co_filename uses a ./ alias of the source still fails"
fi

# Oversized cache: refuse by bound rather than attempting to decode it.
compile_pyc TIMESTAMP
assert $? "↳ fixture: wrote a TIMESTAMP cache before the oversized case"
_PYC="$(find "$_fix/hooks/gate-scripts/lib/__pycache__" -name 'marker_ops*.pyc' ! -type d | head -n1)"
P="$_PYC" python3 -c '
import os
path = os.environ["P"]
with open(path, "wb") as fh:
    fh.write(b"\0" * 16)
    fh.write(b"x" * (8 * 1024 * 1024 + 1))
'
_out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
_rc=$?
if [[ "$_rc" -ne 0 && "$_out" == *"marker_ops"* && "$_out" == *"bound"* ]]; then
    assert 0 "↳ a cache exceeding the classifier size bound fails closed"
else
    printf '  ↳ output: %s\n' "$_out"
    assert 1 "↳ a cache exceeding the classifier size bound fails closed"
fi

# Trusted py_compile body equality preserves constant identity: a body that
# only breaks sharing (values equal, identity not) must fail --check.
rm -rf "$_fix/hooks/gate-scripts/lib/__pycache__"
_share_src="$_fix/hooks/gate-scripts/lib/marker_ops.py"
cp "$_share_src" "$_share_src.bak"
printf 'X = ((1, 2), (1, 2))\n' > "$_share_src"
"$GATE_INTEGRITY" --root "$_fix" --update >/dev/null
compile_pyc TIMESTAMP
assert $? "↳ fixture: wrote a TIMESTAMP cache for the shared-tuple forgery"
_PYC="$(find "$_fix/hooks/gate-scripts/lib/__pycache__" -name 'marker_ops*.pyc' ! -type d | head -n1)"
_PYC="$_PYC" python3 -c '
import marshal, os
path = os.environ["_PYC"]
with open(path, "rb") as fh:
    data = fh.read()
mod = marshal.loads(data[16:])
# Module consts include X=((1,2),(1,2)) with the inner tuple shared. Replace
# X with equal values but distinct tuple objects so marshal REFs diverge.
t = (1, 2)
broken_x = (tuple(list(t)), tuple(list(t)))
new_consts = []
for c in mod.co_consts:
    if isinstance(c, tuple) and len(c) == 2 and c[0] == (1, 2) and c[1] == (1, 2) and c[0] is c[1]:
        new_consts.append(broken_x)
    else:
        new_consts.append(c)
broken = mod.replace(co_consts=tuple(new_consts))
assert any(
    isinstance(c, tuple) and len(c) == 2 and c[0] == (1, 2) and c[0] is not c[1]
    for c in broken.co_consts
), "forge did not break sharing"
with open(path, "wb") as fh:
    fh.write(data[:16] + marshal.dumps(broken))
'
_out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
_rc=$?
mv "$_share_src.bak" "$_share_src"
rm -rf "$_fix/hooks/gate-scripts/lib/__pycache__"
"$GATE_INTEGRITY" --root "$_fix" --update >/dev/null
if [[ "$_rc" -ne 0 && "$_out" == *"marker_ops"* && "$_out" == *"body"* ]]; then
    assert 0 "↳ a cache that only breaks shared-tuple identity still fails"
else
    printf '  ↳ output: %s\n' "$_out"
    assert 1 "↳ a cache that only breaks shared-tuple identity still fails"
fi

# Sibling source size bound: a huge .py next to a small cache must refuse.
compile_pyc TIMESTAMP
assert $? "↳ fixture: wrote a TIMESTAMP cache before the oversized-source case"
_PYC="$(find "$_fix/hooks/gate-scripts/lib/__pycache__" -name 'marker_ops*.pyc' ! -type d | head -n1)"
_src="$_fix/hooks/gate-scripts/lib/marker_ops.py"
cp "$_src" "$_src.bak"
# Keep the file readable but oversized; body decode is never reached.
dd if=/dev/zero of="$_src" bs=1024 count=$((8 * 1024 + 1)) 2>/dev/null
_out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
_rc=$?
mv "$_src.bak" "$_src"
if [[ "$_rc" -ne 0 && "$_out" == *"marker_ops"* && "$_out" == *"source exceeds"* ]]; then
    assert 0 "↳ a sibling source exceeding the classifier size bound fails closed"
else
    printf '  ↳ output: %s\n' "$_out"
    assert 1 "↳ a sibling source exceeding the classifier size bound fails closed"
fi

# Optimization level is part of the cache identity (PEP 3147 `.opt-N`). The
# classifier always runs under `python3 -I` (optimize 0); a gate that ran under
# `-O` writes `.opt-1` caches whose bodies only match a compile at that level.
# Compile one directly to the opt-1 name and require --check to still pass.
rm -rf "$_fix/hooks/gate-scripts/lib/__pycache__"
mkdir -p "$_fix/hooks/gate-scripts/lib/__pycache__"
_tag="$(python3 -c 'import sys; print("".join(str(x) for x in sys.version_info[:2]))')"
_opt1="$_fix/hooks/gate-scripts/lib/__pycache__/marker_ops.cpython-${_tag}.opt-1.pyc"
_PYC_SRC="$_fix/hooks/gate-scripts/lib/marker_ops.py" _OPT1="$_opt1" python3 -c '
import os, py_compile
py_compile.compile(os.environ["_PYC_SRC"], cfile=os.environ["_OPT1"], doraise=True,
                   optimize=1, invalidation_mode=py_compile.PycInvalidationMode.TIMESTAMP)'
assert $? "↳ fixture: wrote an .opt-1 cache"
if [[ -f "$_opt1" ]]; then
    assert 0 "↳ fixture: .opt-1 cache path exists"
else
    assert 1 "↳ fixture: .opt-1 cache path exists"
fi
"$GATE_INTEGRITY" --root "$_fix" --check >/dev/null 2>&1
assert $? "↳ an .opt-1 cache still passes (optimize level taken from the PEP 3147 name)"

# Compact matrix over the three PEP 552 invalidation modes + a truncated header:
# each mode's expected outcome, without a separate property-testing dependency.
for _mode in TIMESTAMP CHECKED_HASH UNCHECKED_HASH; do
    compile_pyc "$_mode"
    assert $? "↳ fixture: matrix wrote $_mode cache"
    _out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
    _rc=$?
    case "$_mode" in
        UNCHECKED_HASH)
            if [[ "$_rc" -ne 0 && "$_out" == *"UNCHECKED"* ]]; then
                assert 0 "↳ matrix: $_mode refused"
            else
                printf '  ↳ output: %s\n' "$_out"
                assert 1 "↳ matrix: $_mode refused"
            fi
            ;;
        *)
            if [[ "$_rc" -eq 0 ]]; then
                assert 0 "↳ matrix: $_mode accepted"
            else
                printf '  ↳ output: %s\n' "$_out"
                assert 1 "↳ matrix: $_mode accepted"
            fi
            ;;
    esac
done
printf 'x' > "$_fix/hooks/gate-scripts/lib/__pycache__/marker_ops.cpython-${_tag}.pyc"
_out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
_rc=$?
if [[ "$_rc" -ne 0 && "$_out" == *"too short"* ]]; then
    assert 0 "↳ matrix: truncated header refused"
else
    printf '  ↳ output: %s\n' "$_out"
    assert 1 "↳ matrix: truncated header refused"
fi

# A SYMLINK parked in __pycache__ is refused rather than classified by whatever
# its target's header says — CPython never writes one there, and compute_lock
# refuses symlinks everywhere else in the locked trees.
compile_pyc TIMESTAMP
assert $? "↳ fixture: wrote a TIMESTAMP cache before the symlink case"
ln -s "$_fix/hooks/gate-scripts/lib/marker_ops.py" \
    "$_fix/hooks/gate-scripts/lib/__pycache__/smuggled.cpython-314.pyc"
_out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
_rc=$?
if [[ "$_rc" -ne 0 && "$_out" == *"smuggled.cpython-314.pyc"* ]]; then
    assert 0 "↳ a SYMLINKED .pyc inside __pycache__ fails, by name (never classified by its target)"
else
    printf '  ↳ output: %s\n' "$_out"
    assert 1 "↳ a SYMLINKED .pyc inside __pycache__ fails, by name (never classified by its target)"
fi

# A FIFO planted as *.pyc must refuse quickly — not block forever on open/read.
rm -rf "$_fix/hooks/gate-scripts/lib/__pycache__"
mkdir -p "$_fix/hooks/gate-scripts/lib/__pycache__"
_tag="$(python3 -c 'import sys; print("".join(str(x) for x in sys.version_info[:2]))')"
_fifo="$_fix/hooks/gate-scripts/lib/__pycache__/marker_ops.cpython-${_tag}.pyc"
mkfifo "$_fifo"
_fifo_out="$(
    GATE_INTEGRITY="$GATE_INTEGRITY" FIX="$_fix" python3 - <<'PY'
import os, subprocess, sys
cmd = [os.environ["GATE_INTEGRITY"], "--root", os.environ["FIX"], "--check"]
try:
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
except subprocess.TimeoutExpired:
    print("TIMEOUT")
    sys.exit(99)
sys.stdout.write(p.stdout)
sys.stdout.write(p.stderr)
sys.exit(p.returncode)
PY
)"
_fifo_rc=$?
if [[ "$_fifo_rc" -ne 0 && "$_fifo_rc" -ne 99 && "$_fifo_out" == *"marker_ops"* && "$_fifo_out" == *"regular file"* ]]; then
    assert 0 "↳ a FIFO planted as *.pyc fails closed without hanging"
else
    printf '  ↳ rc=%s output: %s\n' "$_fifo_rc" "$_fifo_out"
    assert 1 "↳ a FIFO planted as *.pyc fails closed without hanging"
fi
rm -f "$_fifo"

# A source that triggers SyntaxWarning must still authenticate — warnings go to
# stderr, which the gate captures with stdout, so an unfiltered warning would
# false-fail a valid TIMESTAMP cache.
rm -rf "$_fix/hooks/gate-scripts/lib/__pycache__"
_share_src="$_fix/hooks/gate-scripts/lib/marker_ops.py"
cp "$_share_src" "$_share_src.bak"
printf 'X = 1 is 1\n' > "$_share_src"
"$GATE_INTEGRITY" --root "$_fix" --update >/dev/null
compile_pyc TIMESTAMP
assert $? "↳ fixture: wrote a TIMESTAMP cache for a SyntaxWarning source"
_out="$("$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
_rc=$?
mv "$_share_src.bak" "$_share_src"
rm -rf "$_fix/hooks/gate-scripts/lib/__pycache__"
"$GATE_INTEGRITY" --root "$_fix" --update >/dev/null
if [[ "$_rc" -eq 0 ]]; then
    assert 0 "↳ a valid cache beside a SyntaxWarning source still passes"
else
    printf '  ↳ output: %s\n' "$_out"
    assert 1 "↳ a valid cache beside a SyntaxWarning source still passes"
fi

# NUL-listing streamer bounds: empty records, chunk-spanning separators,
# unterminated trailing record, exact limit, and limit-plus-one.
python3 - <<'PY'
import io, sys

def iter_nul_paths(buf, max_bytes):
    pending = b""
    total = 0
    while True:
        chunk = buf.read(4)  # small chunks to hit span cases
        if not chunk:
            break
        total += len(chunk)
        if total > max_bytes or len(pending) + len(chunk) > max_bytes:
            raise OSError(0, "listing too large")
        pending += chunk
        while True:
            i = pending.find(b"\0")
            if i < 0:
                break
            yield pending[:i]
            pending = pending[i + 1:]
    if pending:
        yield pending

def take(data, limit):
    return list(iter_nul_paths(io.BytesIO(data), limit))

assert take(b"", 8) == []
assert take(b"\0", 8) == [b""]
assert take(b"a\0b\0", 8) == [b"a", b"b"]
assert take(b"abcd\0ef", 8) == [b"abcd", b"ef"]  # span + unterminated
assert take(b"12345678", 8) == [b"12345678"]  # exact limit, no NUL
try:
    take(b"123456789", 8)
except OSError as e:
    assert "listing too large" in (e.strerror or str(e))
else:
    raise SystemExit("limit-plus-one did not raise")
print("nul-stream bounds ok")
PY
assert $? "↳ NUL-listing streamer covers empty/span/unterminated/limit bounds"

# Oversized listing end-to-end: the classifier closes stdin at 8 MiB while find
# is still writing, so find gets SIGPIPE (141). That must keep the listing-bound
# diagnostic — not rename it to #742's enumeration message via PIPESTATUS[0].
fresh_fixture
_shim="$(mktemp -d)"
_real_find="$(command -v -p find 2>/dev/null)"
case "$_real_find" in
    /*) ;;
    *) _real_find="" ;;
esac
if [[ -n "$_shim" && -d "$_shim" && -n "$_real_find" && -x "$_real_find" ]]; then
    # Bash writer (not a Python find): real find exits 141 on SIGPIPE; a Python
    # shim raises BrokenPipeError and exits 1, which wrongly renames the bound.
    # Long paths so the 8 MiB listing bound fires before the 4096 path-count cap.
    _long="hooks/gate-scripts/lib/__pycache__/$(python3 -I -c 'print("x"*4000)').pyc"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' "long=$(printf '%q' "$_long")"
        # Intentional: $long expands in the generated shim, not here.
        # shellcheck disable=SC2016
        printf '%s\n' 'while :; do printf "%s\0" "$long"; done'
    } > "$_shim/find"
    chmod 755 "$_shim/find"
    _out="$(PATH="$_shim:$PATH" "$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
    _rc=$?
    # Output can be huge (paths yielded before the byte bound trips); match via grep.
    if [[ "$_rc" -ne 0 ]] \
       && grep -q "listing exceeds 8 MiB bound" <<<"$_out" \
       && ! grep -q "could not enumerate the locked directories" <<<"$_out"; then
        assert 0 "an oversized exempt listing keeps the 8 MiB diagnostic (SIGPIPE not renamed to enumeration)"
    else
        _tail="$(printf '%s' "$_out" | tail -c 400)" || _tail=""
        printf '  ↳ rc=%s tail: %s\n' "$_rc" "$_tail"
        assert 1 "an oversized exempt listing keeps the 8 MiB diagnostic (SIGPIPE not renamed to enumeration)"
    fi
    rm -rf "$_shim"
else
    assert 1 "an oversized exempt listing keeps the 8 MiB diagnostic (no tempdir, or no absolute find to shim)"
fi

# The converse: a PATH-shimmed find that exits 141 after a short/empty listing
# must NOT be trusted when the classifier reaches EOF successfully — that would
# accept omitted bytecode. Only 141 paired with a nonzero classifier exit keeps
# the classifier diagnostic (listing bound above).
fresh_fixture
_shim="$(mktemp -d)"
_real_find="$(command -v -p find 2>/dev/null)"
case "$_real_find" in
    /*) ;;
    *) _real_find="" ;;
esac
if [[ -n "$_shim" && -d "$_shim" && -n "$_real_find" && -x "$_real_find" ]]; then
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' '# Partial listing then pretend SIGPIPE — must fail closed.'
        printf '%s\n' 'exit 141'
    } > "$_shim/find"
    chmod 755 "$_shim/find"
    _out="$(PATH="$_shim:$PATH" "$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
    _rc=$?
    if [[ "$_rc" -ne 0 && "$_out" == *"could not enumerate the locked directories"* ]]; then
        assert 0 "find exit 141 with a successful classifier still fails closed (no omitted-bytecode trust)"
    else
        printf '  ↳ rc=%s output: %s\n' "$_rc" "$_out"
        assert 1 "find exit 141 with a successful classifier still fails closed (no omitted-bytecode trust)"
    fi
    rm -rf "$_shim"
else
    assert 1 "find exit 141 with a successful classifier still fails closed (no tempdir, or no absolute find to shim)"
fi

# Path-count bound: listing bytes alone allow thousands of tiny paths that would
# each trigger sibling compile work. Fail closed at 4096 paths.
fresh_fixture
_shim="$(mktemp -d)"
_real_find="$(command -v -p find 2>/dev/null)"
case "$_real_find" in
    /*) ;;
    *) _real_find="" ;;
esac
if [[ -n "$_shim" && -d "$_shim" && -n "$_real_find" && -x "$_real_find" ]]; then
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'python3 -I -c "import sys; p=b\"hooks/gate-scripts/lib/__pycache__/pad.cpython-312.pyc\\0\"; sys.stdout.buffer.write(p * 4097)"'
    } > "$_shim/find"
    chmod 755 "$_shim/find"
    _out="$(PATH="$_shim:$PATH" "$GATE_INTEGRITY" --root "$_fix" --check 2>&1)"
    _rc=$?
    if [[ "$_rc" -ne 0 && "$_out" == *"path count exceeds 4096 bound"* ]]; then
        assert 0 "exempt bytecode path count above 4096 fails closed"
    else
        printf '  ↳ rc=%s output: %s\n' "$_rc" "$_out"
        assert 1 "exempt bytecode path count above 4096 fails closed"
    fi
    rm -rf "$_shim"
else
    assert 1 "exempt bytecode path count above 4096 fails closed (no tempdir, or no absolute find to shim)"
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
# The tracked-bytecode check is the only cover against a TRACKED .pyc, which the
# digest omits, so "the git probe failed, assume not a repository" would silently retire
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

# ── 5b. A BACKSLASH in a locked path is hashable, not an unlockable tree ──────
# Handed a filename operand, both GNU `sha256sum` and `shasum` C-escape it: a
# backslash in the name prefixes the whole output line with `\`, so `${out%% *}`
# kept that `\`, the 64-hex validation rejected a correctly computed digest, and
# `--update` AND `--check` both died with "could not hash" on a tree that is
# perfectly well formed. The enumeration refuses exactly ONE character class by
# name — a NEWLINE — so every other byte it admits has to be lockable; a path
# the producer accepts but the hasher cannot record is a tree with no reachable
# green state. Reading the file from STDIN puts no name in the output at all.
# Asserted in both directions: record-then-verify, then tamper-and-detect, so a
# hasher that silently returned a constant would still fail here.
fresh_fixture
_bs_name='hooks/gate-scripts/back\slash.sh'
printf '#!/usr/bin/env bash\ntrue\n' > "$_fix/$_bs_name" 2>/dev/null
if [[ -e "$_fix/$_bs_name" ]]; then
    _out="$("$GATE_INTEGRITY" --root "$_fix" --update 2>&1)"
    _rc=$?
    if [[ "$_rc" -eq 0 ]]; then
        assert 0 "--update records a locked path containing a backslash (no filename escaping in the digest)"
    else
        printf '  ↳ output: %s\n' "$_out"
        assert 1 "--update records a locked path containing a backslash (no filename escaping in the digest)"
    fi
    "$GATE_INTEGRITY" --root "$_fix" --check >/dev/null 2>&1
    assert $? "↳ and --check verifies that recorded tree"
    printf 'tampered\n' >> "$_fix/$_bs_name"
    "$GATE_INTEGRITY" --root "$_fix" --check >/dev/null 2>&1
    assert "$(( $? == 0 ? 1 : 0 ))" "↳ and an edit to it is still DETECTED (the digest is real, not a constant)"
    rm -f "$_fix/$_bs_name"
else
    assert 1 "--update records a locked path containing a backslash (fixture name unavailable)"
    assert 1 "↳ and --check verifies that recorded tree (fixture name unavailable)"
    assert 1 "↳ and an edit to it is still DETECTED (fixture name unavailable)"
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
