#!/bin/bash
# Cover scripts/install-git-hooks.sh — specifically the gate-closure digest pin.
#
# Why the pin exists: pre-merge-commit and reference-transaction run AFTER git
# has updated the worktree. When the gated repo IS the busdriver checkout
# (PLUGIN_ROOT == REPO_ROOT, the documented default invocation), the merge being
# gated supplies the gate's own code, so hostile branch content can turn both
# gates into no-ops before either evaluates. The installed wrapper therefore
# pins a digest of the whole hooks/gate-scripts closure and refuses to exec when
# the tree no longer matches.
#
# Every fixture is self-contained: a copied PLUGIN_ROOT so gate scripts can be
# mutated, and an explicit core.hooksPath so a GLOBAL core.hooksPath can never
# make this suite write outside its own temp dir.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO_SRC=$PWD

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

# git commit-tree in case 6c needs an identity, and a CI runner has no global
# git config — without this it fails there and the assertions report as
# failures instead of exercising the hooks.
export GIT_AUTHOR_NAME=busdriver-test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=busdriver-test GIT_COMMITTER_EMAIL=test@example.invalid

PASS=0
FAIL=0
assert() {
    local what="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        PASS=$((PASS + 1)); printf '  PASS  %s\n' "$what"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected=%s\n        got=%s\n' "$what" "$want" "$got"
    fi
}

# Isolated PLUGIN_ROOT we are free to mutate.
PR="$WORK/plugin"
mkdir -p "$PR/scripts"
cp -R "$REPO_SRC/hooks" "$PR/hooks"
rm -rf "$PR/hooks/gate-scripts/lib/__pycache__"
cp "$REPO_SRC/scripts/install-git-hooks.sh" "$PR/scripts/install-git-hooks.sh"

REPO="$WORK/repo"
git init -q "$REPO"
git -C "$REPO" config commit.gpgsign false
# Pin the fixture's hooks dir so a global core.hooksPath cannot redirect the
# install outside $WORK. Without this the installer honours ~/.gitconfig.
git -C "$REPO" config core.hooksPath "$REPO/.git/fixture-hooks"

install_hooks() { bash "$PR/scripts/install-git-hooks.sh" "$REPO" >/dev/null 2>&1; }
GATES="$REPO/.git/fixture-hooks/.busdriver-gates"
# Snapshots are named per install and never removed, so several coexist. Read
# the live one out of the wrapper that hard-codes it rather
# than guessing by mtime: two installs inside the same second are indistinguish-
# able by timestamp, which made this flaky about one run in three.
current_snap() {
    grep -o "$GATES/[^\"']*/" "$REPO/.git/fixture-hooks/reference-transaction" \
        2>/dev/null | head -1
}
# `committed` is a phase the gate itself exits 0 on, so a clean run reaching the
# gate is distinguishable from the pin refusing before exec.
run_hook() { "$REPO/.git/fixture-hooks/reference-transaction" committed </dev/null 2>&1; }

install_hooks
rc_install=$?
assert "installer succeeds" "0" "$rc_install"
assert "wrapper landed in the fixture hooks dir" "yes" \
    "$([[ -x "$REPO/.git/fixture-hooks/reference-transaction" ]] && echo yes || echo no)"
assert "nothing was installed into the real repo" "no" \
    "$([[ -e "$REPO_SRC/.git/hooks/reference-transaction" ]] && echo yes || echo no)"

# 1. Clean tree: the pin passes and the gate runs.
out=$(run_hook); rc=$?
assert "clean tree runs the gate" "0" "$rc"

# 2. Edited gate script: refused, and the message says what to do.
GATE="$PR/hooks/gate-scripts/merge-reference-transaction-gate.sh"
cp "$GATE" "$WORK/gate.orig"
printf '\n# hostile edit\n' >> "$GATE"
out=$(run_hook); rc=$?
assert "edited gate script is refused" "1" "$rc"
assert "refusal names the cause" "yes" \
    "$([[ "$out" == *"gate scripts changed since these hooks were installed"* ]] && echo yes || echo no)"
assert "refusal names the remedy" "yes" \
    "$([[ "$out" == *"install-git-hooks.sh"* ]] && echo yes || echo no)"
# The two assertions above are substring matches, and a substring match is blind
# to escaping: an earlier round shipped a digest program whose backslashes were
# doubled, so every \n arrived as a literal backslash-n and the whole refusal
# rendered as ONE run-on line with no trailing newline — while both assertions
# above still passed. Pin the physical shape too. Same escaping bug silently
# turned the listing digest's NUL separator into the two bytes \ and 0, which is
# why the separator is asserted directly further down.
assert "refusal is multi-line, not one run-on string" "yes" \
    "$([[ "$(printf '%s\n' "$out" | wc -l)" -ge 4 ]] && echo yes || echo no)"

# 3. Restored: passes again. Proves the refusal tracks content, not a latch.
cp "$WORK/gate.orig" "$GATE"
out=$(run_hook); rc=$?
assert "restoring the gate script clears the refusal" "0" "$rc"

# 4. An ADDED file is caught too — a digest over the listing, not just contents.
printf 'x\n' > "$PR/hooks/gate-scripts/lib/stray.py"
out=$(run_hook); rc=$?
assert "an added file under gate-scripts is refused" "1" "$rc"
rm -f "$PR/hooks/gate-scripts/lib/stray.py"

# 5. A DELETED file likewise.
rm -f "$PR/hooks/gate-scripts/lib/skip_age.py"
out=$(run_hook); rc=$?
assert "a deleted file under gate-scripts is refused" "1" "$rc"
cp "$REPO_SRC/hooks/gate-scripts/lib/skip_age.py" "$PR/hooks/gate-scripts/lib/skip_age.py"
out=$(run_hook); rc=$?
assert "restoring the deleted file clears the refusal" "0" "$rc"

# 6. Source-adjacent bytecode in the LIVE tree is inert. An UNCHECKED hash-based
# .pyc executes in place of its .py without Python reading the source at all, so
# while the wrapper still exec-ed the live tree this was a real bypass — a merge
# plants bytecode, the digest exempts it, the gate runs it — and the digest had
# to purge it. Exec-from-snapshot removes the dependency: the live tree is only
# ever hashed, never imported, so planted bytecode can sit there untouched.
# Plant a REAL one (junk bytes are rejected by the loader anyway and would prove
# nothing) and show it neither trips the pin nor reaches the executed tree.
HOSTILE_SRC="$WORK/hostile.py"
printf 'raise SystemExit(0)\n' > "$HOSTILE_SRC"
python3 - "$PR/hooks/gate-scripts/lib" "$HOSTILE_SRC" <<'PLANT'
import importlib.util, os, py_compile, sys
lib, hostile = sys.argv[1], sys.argv[2]
target = importlib.util.cache_from_source(os.path.join(lib, "merge_pending.py"))
os.makedirs(os.path.dirname(target), exist_ok=True)
py_compile.compile(hostile, cfile=target,
                   invalidation_mode=py_compile.PycInvalidationMode.UNCHECKED_HASH)
PLANT
PLANTED=$(python3 -I -S -c 'import importlib.util,os,sys; print(importlib.util.cache_from_source(os.path.join(sys.argv[1],"merge_pending.py")))' "$PR/hooks/gate-scripts/lib")
assert "the hostile bytecode really was planted" "yes" \
    "$([[ -f "$PLANTED" ]] && echo yes || echo no)"
out=$(run_hook); rc=$?
assert "a bytecode cache does not trip the pin" "0" "$rc"
assert "live-tree bytecode is left alone, not purged" "yes" \
    "$([[ -f "$PLANTED" ]] && echo yes || echo no)"
# The executed tree is the snapshot, and the snapshot never received it.
SNAP_DIR=$(current_snap)
assert "exactly one snapshot exists" "yes" \
    "$([[ -n "$SNAP_DIR" && -f "$SNAP_DIR/merge-reference-transaction-gate.sh" ]] && echo yes || echo no)"
# 6b. THE snapshot is what runs. Break the snapshot copy only — leave the live
# tree byte-identical, so the digest passes — and the wrapper must carry the
# break through. Without this the suite cannot tell exec-from-snapshot apart
# from exec-from-live-tree: every other case here mutates the live tree, which
# the digest catches first and which would pass either way. This is also what
# closes the TOCTOU the pin alone left open — hash by pathname, then re-open by
# pathname is two different reads, and only one of them is verified.
cp "$SNAP_DIR/merge-reference-transaction-gate.sh" "$WORK/snap-gate.orig"
printf '#!/bin/bash\nexit 42\n' > "$SNAP_DIR/merge-reference-transaction-gate.sh"
out=$(run_hook); rc=$?
assert "the snapshot copy is what executes" "42" "$rc"
cp "$WORK/snap-gate.orig" "$SNAP_DIR/merge-reference-transaction-gate.sh"
out=$(run_hook); rc=$?
assert "restoring the snapshot restores the gate" "0" "$rc"

# 6c. Everything above runs the wrapper at `committed`, where the gate exits on
# its first line — before it sources anything. So none of it proves the part
# that matters most: that $_SCRIPT_DIR/lib resolves INSIDE the snapshot. Drive a
# real `prepared` decision, the phase whose non-zero exit aborts the
# transaction, and plant a sentinel in the SNAPSHOT's lib to show which copy was
# sourced. Plumbing only (commit-tree, a direct ref write) so building the
# fixture fires no hooks of its own.
# This suite runs without `set -e` on purpose, so a fixture command that fails
# would otherwise leave empty oids behind and the assertions below would be
# satisfied by the gate crashing on garbage input rather than by its merge
# policy. Check the build, and assert it, before trusting anything after it.
fixture_ok=yes
# -w writes the object. git special-cases the empty tree and resolves it
# without this (checked on 2.55), but relying on that is a version dependence
# the fixture does not need.
EMPTY_TREE=$(git -C "$REPO" hash-object -w -t tree /dev/null) || fixture_ok=no
C1=$(git -C "$REPO" commit-tree "$EMPTY_TREE" -m one) || fixture_ok=no
C2=$(git -C "$REPO" commit-tree "$EMPTY_TREE" -m two) || fixture_ok=no
MERGE=$(git -C "$REPO" commit-tree "$EMPTY_TREE" -p "$C1" -p "$C2" -m merge) || fixture_ok=no
printf '%s\n' "$C1" > "$REPO/.git/refs/heads/main" || fixture_ok=no
git -C "$REPO" symbolic-ref HEAD refs/heads/main || fixture_ok=no
[[ -n "$C1" && -n "$C2" && -n "$MERGE" ]] || fixture_ok=no
assert "the prepared-phase fixture built" "yes" "$fixture_ok"
run_prepared() {
    (cd "$REPO" && printf '%s %s refs/heads/main\n' "$C1" "$MERGE" \
        | "$REPO/.git/fixture-hooks/reference-transaction" prepared 2>&1)
}
out=$(run_prepared); rc=$?
# Pin the gate's OWN refusal text. "non-zero and not the digest message" would
# also be satisfied by the gate crashing on a parse error or a missing lib --
# exactly the failures this case exists to rule out.
assert "an unauthorized merge tip is refused at prepared" "1" "$rc"
assert "the refusal is the gate's merge policy, not an incidental failure" "yes" \
    "$([[ "$out" == *"merge reference-transaction gate: refusing unauthorized merge commit."* ]] && echo yes || echo no)"

# The reference-transaction gate is self-contained, so it cannot show WHICH
# copy of lib/ a gate sources. The commit-chain gates do source it, so plant a
# sentinel in the SNAPSHOT's lib and run the installed pre-commit wrapper: the
# sentinel fires at source time, before any gate logic decides anything.
# The gate exits on line 20 unless a merge is actually in progress, so give it
# a MERGE_HEAD; without one it never reaches its source lines and the sentinel
# below would prove nothing.
printf '%s\n' "$C2" > "$REPO/.git/MERGE_HEAD"
run_precommit() { (cd "$REPO" && "$REPO/.git/fixture-hooks/pre-commit" </dev/null 2>&1); }
# A SYMLINK must never end up as the tree a wrapper execs. Every install
# reserves its own unique name, so a link parked where a snapshot used to be is
# never adopted: the wrapper points at the tree this install created.
STALE_LINK="${SNAP_DIR%/}"
mv "$STALE_LINK" "$WORK/real-snap"
ln -s "$WORK/real-snap" "$STALE_LINK"
install_hooks
SNAP_DIR=$(current_snap)
# The link is left where it is -- nothing here deletes. What matters is that
# nothing execs through it.
assert "the live snapshot is a real directory, not a link" "yes" \
    "$([[ -n "$SNAP_DIR" && -d "${SNAP_DIR%/}" && ! -L "${SNAP_DIR%/}" ]] && echo yes || echo no)"
out=$(run_hook); rc=$?
assert "the gate still runs after the symlink is cleared" "0" "$rc"

SNAP_LIB="$SNAP_DIR/lib/validate-staged-litmus-marker.sh"
cp "$SNAP_LIB" "$WORK/snap-lib.orig"
printf '\necho SNAPSHOT-LIB-WAS-SOURCED >&2\n' >> "$SNAP_LIB"
out=$(run_precommit)
assert "the sourced lib comes from the snapshot, not the live tree" "yes" \
    "$([[ "$out" == *"SNAPSHOT-LIB-WAS-SOURCED"* ]] && echo yes || echo no)"
cp "$WORK/snap-lib.orig" "$SNAP_LIB"
# ...and an edit to the live tree's copy is caught by the pin rather than
# silently sourced, which is the same claim from the other side.
LIVE_LIB="$PR/hooks/gate-scripts/lib/validate-staged-litmus-marker.sh"
cp "$LIVE_LIB" "$WORK/live-lib.orig"
printf '\necho LIVE-LIB-WAS-SOURCED >&2\n' >> "$LIVE_LIB"
out=$(run_precommit)
assert "editing the live lib is caught by the pin, not silently sourced" "yes" \
    "$([[ "$out" == *"gate scripts changed since"* && "$out" != *"LIVE-LIB-WAS-SOURCED"* ]] && echo yes || echo no)"
cp "$WORK/live-lib.orig" "$LIVE_LIB"
rm -f "$REPO/.git/MERGE_HEAD"

# 7. Reinstalling after a legitimate edit re-pins to the new content — and,
# because the hostile bytecode from case 6 is STILL sitting in the live tree,
# this is also the case that pins the snapshot against it. The digest skips
# __pycache__, so a plant does not change the digest -- but every install
# rebuilds regardless, which makes each re-pin a moment the planted bytecode
# could be copied into the tree that executes.
printf '\n# legitimate edit\n' >> "$GATE"
out=$(run_hook); rc=$?
assert "edit before reinstall is still refused" "1" "$rc"
install_hooks
out=$(run_hook); rc=$?
assert "reinstall re-pins to the edited tree" "0" "$rc"
assert "the planted bytecode is still in the live tree at re-pin time" "yes" \
    "$([[ -f "$PLANTED" ]] && echo yes || echo no)"
SNAP_DIR=$(current_snap)
cp "$GATE" "$WORK/gate.repin"
assert "re-pin snapshots the edited tree" "yes" \
    "$([[ -n "$SNAP_DIR" ]] && grep -qF 'legitimate edit' "$SNAP_DIR/merge-reference-transaction-gate.sh" && echo yes || echo no)"
assert "re-pin does not carry planted bytecode into the executed tree" "no" \
    "$([[ -e "$SNAP_DIR/lib/__pycache__" ]] && echo yes || echo no)"
# Superseded snapshots are KEPT, however old. A hook that started before its
# wrapper was rewritten is still about to exec the snapshot that old wrapper
# names, and no install can know whether one is in flight. Deleting was the
# only destructive act here and it was removed; this pins that, so restoring a
# sweep has to fail a test rather than pass review.
# Name the exact directory that is about to be superseded and look for THAT
# one afterwards. A count would not do: the symlink parked in $GATES by the
# case above also matches */ and cannot be rmtree'd, so a sweep still leaves
# two entries and the assertion would pass without exercising anything.
PREV_SNAP="${SNAP_DIR%/}"
touch -t 200001010000 "$PREV_SNAP"
install_hooks
SNAP_DIR=$(current_snap)
assert "the install really did supersede it" "no" \
    "$([[ "${SNAP_DIR%/}" == "$PREV_SNAP" ]] && echo yes || echo no)"
assert "an old superseded snapshot is still kept" "yes" \
    "$([[ -d "$PREV_SNAP" && ! -L "$PREV_SNAP" ]] && echo yes || echo no)"

# 7b. Because nothing is ever deleted, the pile is bounded by a REFUSAL. Cross
# the ceiling and the install must stop, name the directory, leave the working
# hooks alone -- the whole reason a refusal is usable here where a sweep is not
# -- and warn AGAINST removing the directory itself, which would take the live
# snapshot with it and abort every ref update in the repo until an install
# succeeded again. It must also print no command to paste: a hooks path may
# contain a space or a bracket, and an unquoted rm -rf is the escaping bug this
# branch removes elsewhere.
for i in $(seq 1 100); do mkdir -p "$GATES/filler-$i"; done
err=$(bash "$PR/scripts/install-git-hooks.sh" "$REPO" 2>&1); rc=$?
assert "an over-full snapshot root refuses the install" "1" "$rc"
assert "the refusal names the directory to clear" "yes" \
    "$([[ "$err" == *"$GATES"* ]] && echo yes || echo no)"
assert "the refusal warns against removing the directory itself" "yes" \
    "$([[ "$err" == *"Do NOT remove the directory itself"* ]] && echo yes || echo no)"
assert "the refusal hands over no rm command to paste" "no" \
    "$([[ "$err" == *"rm -rf"* ]] && echo yes || echo no)"
# "keep the one the hooks use" is wrong guidance: an interrupted install leaves
# the six wrappers split across two snapshots and BOTH are live, so a reader
# who checks a single wrapper deletes a tree another wrapper still execs.
assert "the refusal says to check all six wrappers, not one" "yes" \
    "$([[ "$err" == *"Check all six wrappers"* ]] && echo yes || echo no)"
# The comment and the ADR both require this; the operator only ever reads the
# message, so the precondition has to survive there or it does not exist.
assert "the refusal states the no-hooks-running precondition" "yes" \
    "$([[ "$err" == *"NO hooks are running"* ]] && echo yes || echo no)"
out=$(run_hook); rc=$?
assert "the refused install leaves the working hooks intact" "0" "$rc"
rm -rf "${GATES:?}"/filler-*
install_hooks; rc=$?
# Assert the INSTALL succeeded, not just that a hook still runs: this suite has
# no set -e, and a failed reinstall leaves the previous wrapper working, so the
# hook check below would pass while proving nothing about recovery.
assert "clearing the pile lets the install proceed again" "0" "$rc"
out=$(run_hook); rc=$?
assert "the gate still runs after recovery" "0" "$rc"
# That install published a new snapshot, so anything below that reaches for the
# LIVE one has to re-read it rather than reuse the name captured earlier.
SNAP_DIR=$(current_snap)

# 8. A core.hooksPath aimed at TRACKED content is refused. The wrapper carries
# the digest check, so a merge that can replace the wrapper skips the check
# entirely — pinning the gate scripts would be pointless there.
REPO2="$WORK/repo2"
git init -q "$REPO2"
git -C "$REPO2" config core.hooksPath "$REPO2/.githooks"
err=$(bash "$PR/scripts/install-git-hooks.sh" "$REPO2" 2>&1); rc=$?
assert "in-worktree hooks dir is refused" "1" "$rc"
assert "refusal explains the wrapper is replaceable" "yes" \
    "$([[ "$err" == *"inside the work tree"* ]] && echo yes || echo no)"
assert "nothing was installed there" "no" \
    "$([[ -e "$REPO2/.githooks/reference-transaction" ]] && echo yes || echo no)"

# 8b. An in-worktree SYMLINK is refused even when it resolves OUTSIDE the tree.
# realpath alone would clear this: the target is out of tree, so containment
# looks fine. But the symlink is tracked content — a merge replaces it with a
# real directory of hostile hooks, which git then uses instead of our wrapper.
REPO2B="$WORK/repo2b"
git init -q "$REPO2B"
mkdir -p "$WORK/outside-hooks"
ln -s "$WORK/outside-hooks" "$REPO2B/.githooks"
git -C "$REPO2B" config core.hooksPath "$REPO2B/.githooks"
err=$(bash "$PR/scripts/install-git-hooks.sh" "$REPO2B" 2>&1); rc=$?
assert "in-worktree symlink to an outside dir is refused" "1" "$rc"
assert "nothing was installed through the symlink" "no" \
    "$([[ -e "$WORK/outside-hooks/reference-transaction" ]] && echo yes || echo no)"

# 8c. core.hooksPath pointing at the work tree ROOT is refused. Traversal has
# to pass the root to reach .git/hooks, but the root as a DESTINATION means
# hook files land directly in tracked content.
REPO2R="$WORK/repo2r"
git init -q "$REPO2R"
git -C "$REPO2R" config core.hooksPath "$REPO2R"
err=$(bash "$PR/scripts/install-git-hooks.sh" "$REPO2R" 2>&1); rc=$?
assert "work tree root as hooks dir is refused" "1" "$rc"
assert "no hook landed in the work tree root" "no" \
    "$([[ -e "$REPO2R/reference-transaction" ]] && echo yes || echo no)"

# 8d. A hooks dir INSIDE .git that is a symlink into tracked content is refused.
# Every component clears the walk (.git is exempt as a git-dir ancestor), so
# only resolving where the final component LANDS catches this one.
REPO2S="$WORK/repo2s"
git init -q "$REPO2S"
mkdir -p "$REPO2S/tracked-hooks"
ln -s "$REPO2S/tracked-hooks" "$REPO2S/.git/linked-hooks"
git -C "$REPO2S" config core.hooksPath "$REPO2S/.git/linked-hooks"
err=$(bash "$PR/scripts/install-git-hooks.sh" "$REPO2S" 2>&1); rc=$?
assert "hooks dir in .git symlinked to tracked content is refused" "1" "$rc"
assert "nothing was installed through the .git symlink" "no" \
    "$([[ -e "$REPO2S/tracked-hooks/reference-transaction" ]] && echo yes || echo no)"

# ...but a hooks dir that is genuinely outside the work tree is still accepted,
# so the check refuses replaceable locations rather than every non-default one.
REPO2C="$WORK/repo2c"
git init -q "$REPO2C"
mkdir -p "$WORK/real-outside-hooks"
git -C "$REPO2C" config core.hooksPath "$WORK/real-outside-hooks"
bash "$PR/scripts/install-git-hooks.sh" "$REPO2C" >/dev/null 2>&1
assert "a genuinely out-of-tree hooks dir is accepted" "yes" \
    "$([[ -x "$WORK/real-outside-hooks/reference-transaction" ]] && echo yes || echo no)"

# ...but the default hooks dir INSIDE the git dir is still accepted.
REPO3="$WORK/repo3"
git init -q "$REPO3"
git -C "$REPO3" config --unset core.hooksPath 2>/dev/null
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    bash "$PR/scripts/install-git-hooks.sh" "$REPO3" >/dev/null 2>&1
assert "default .git/hooks is still accepted" "yes" \
    "$([[ -x "$REPO3/.git/hooks/reference-transaction" ]] && echo yes || echo no)"

# 8e. Containment must read the FILESYSTEM, not the spelling. macOS volumes are
# case-insensitive by default, and realpath() preserves whatever spelling it was
# handed, so a differently-cased core.hooksPath names the same tracked directory
# that a string prefix says is elsewhere. Only meaningful where the volume
# actually is case-insensitive; elsewhere the alternate spelling is a genuinely
# different (missing) path and the case proves nothing, so it is skipped rather
# than asserted vacuously.
# The re-cased component must be part of the WORK TREE path, not the tail: a
# tail-only variant (…/repo2d/GITHOOKS) still shares the …/repo2d/ prefix and
# a string compare catches it anyway, which would make this case vacuous.
REPO2D="$WORK/repo2d"
git init -q "$REPO2D"
mkdir -p "$REPO2D/githooks"
if [[ -d "$WORK/REPO2D/githooks" ]]; then
    git -C "$REPO2D" config core.hooksPath "$WORK/REPO2D/githooks"
    err=$(bash "$PR/scripts/install-git-hooks.sh" "$REPO2D" 2>&1); rc=$?
    assert "case-variant in-worktree hooks dir is refused" "1" "$rc"
    assert "nothing was installed through the case variant" "no" \
        "$([[ -e "$REPO2D/githooks/reference-transaction" ]] && echo yes || echo no)"
else
    printf '  SKIP  case-variant containment (volume is case-sensitive)\n'
fi

# 8f. An existing snapshot is VERIFIED, not trusted for its name. The directory
# is named by a digest, but nothing about the name proves its contents — so a
# reinstall must not adopt a tampered one. Reuse case 6b's broken snapshot: the
# live tree is untouched, so the digest is unchanged and nothing about the
# situation would tell a name-trusting installer to rebuild.
printf '#!/bin/bash\nexit 42\n' > "$SNAP_DIR/merge-reference-transaction-gate.sh"
out=$(run_hook); rc=$?
assert "the tampered snapshot is live before reinstall" "42" "$rc"
install_hooks
out=$(run_hook); rc=$?
assert "reinstall rebuilds a snapshot that does not match its digest" "0" "$rc"

# 8g. A refused install must not destroy what is already working. Snapshot
# pruning is destructive and the digest had changed, so building before
# preflight left the installed wrappers pointing at a deleted snapshot — a
# refusal that bricks the hooks it declined to replace.
printf '#!/bin/sh\nexit 0\n' > "$REPO/.git/fixture-hooks/post-commit"
printf '\n# another edit\n' >> "$GATE"
err=$(bash "$PR/scripts/install-git-hooks.sh" "$REPO" 2>&1); rc=$?
assert "a foreign hook makes the install refuse" "1" "$rc"
cp "$WORK/gate.repin" "$GATE"
out=$(run_hook); rc=$?
assert "the refused install left the working hooks intact" "0" "$rc"


# 8h. A symlinked snapshot root is refused. The snapshot has to sit inside the
# hooks directory: that is the containment the case-8 family proves a merge
# cannot reach, and a link relocates the executed tree outside it.
REPO4="$WORK/repo4"
git init -q "$REPO4"
mkdir -p "$REPO4/.git/fixture-hooks" "$WORK/precious"
printf 'do not delete\n' > "$WORK/precious/keep.txt"
mkdir -p "$WORK/precious/some-dir"
git -C "$REPO4" config core.hooksPath "$REPO4/.git/fixture-hooks"
ln -s "$WORK/precious" "$REPO4/.git/fixture-hooks/.busdriver-gates"
err=$(bash "$PR/scripts/install-git-hooks.sh" "$REPO4" 2>&1); rc=$?
assert "a symlinked snapshot root is refused" "1" "$rc"
assert "the refusal says why following it is unsafe" "yes" \
    "$([[ "$err" == *"containment"* ]] && echo yes || echo no)"


# 8i. The copy-verification branch. It can only fire when the gate tree changes
# WHILE the installer copies it, so no ordinary fixture reaches it — and an
# unfired branch is a guard that certifies bytes it never checked. Rather than
# add a test-only seam to a security script, run the shipped snapshot program
# itself with a digest that cannot match, which is exactly the state a lost race
# produces. Extracted from the installer, so it is the real code, not a copy.
sed -n "/^GATE_DIGEST_PY='/,/^'\$/p" "$PR/scripts/install-git-hooks.sh" > "$WORK/dp.sh"
DIGEST_PY=$(bash -c "source '$WORK/dp.sh'; printf '%s' \"\$GATE_DIGEST_PY\"")
assert "the digest program was extracted" "yes" \
    "$([[ "$DIGEST_PY" == *"hashlib"* ]] && echo yes || echo no)"
awk '/python3 -I -S - "\$GATE_DIR" "\$SNAP_ROOT"/{f=1;next} f&&/^PY$/{exit} f' \
    "$PR/scripts/install-git-hooks.sh" > "$WORK/snapblock.py"
assert "the snapshot program was extracted" "yes" \
    "$([[ -s "$WORK/snapblock.py" ]] && grep -q 'copytree' "$WORK/snapblock.py" && echo yes || echo no)"
mkdir -p "$WORK/snaproot-mismatch"
WRONG=0000000000000000000000000000000000000000000000000000000000000000
err=$(python3 -I -S "$WORK/snapblock.py" "$PR/hooks/gate-scripts" \
        "$WORK/snaproot-mismatch" "$WRONG" "$DIGEST_PY" 2>&1); rc=$?
assert "a copy that does not match the pinned digest is refused" "1" "$rc"
assert "the refusal names the cause" "yes" \
    "$([[ "$err" == *"changed while it was being copied"* ]] && echo yes || echo no)"
assert "the unverified copy is not left behind" "0" \
    "$(find "$WORK/snaproot-mismatch" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"


# 9. The listing digest separates records with a real NUL. A filename cannot
# contain NUL, so that separator is what makes the listing encoding injective;
# with the two-byte sequence backslash-zero instead, a file named
# "a\0<sha>\0b" collides with the two-entry listing {a, b}.
sep_ok=$(python3 -I -S - "$PR/scripts/install-git-hooks.sh" <<'SEP'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
start = t.index("GATE_DIGEST_PY=" + chr(39))
end = t.index(chr(10) + chr(39) + chr(10), start)
prog = t[start:end]
sys.stdout.write("yes" if (chr(92) + chr(92)) not in prog else "no")
SEP
)
assert "digest program has no doubled backslashes" "yes" "$sep_ok"

printf '\nResults: %d/%d passed\n' "$PASS" "$((PASS + FAIL))"
[[ "$FAIL" -eq 0 ]]
