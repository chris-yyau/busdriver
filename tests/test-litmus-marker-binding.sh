#!/usr/bin/env bash
# Tests for #576 — what the litmus commit marker is bound to.
#
# #545 made the pre-commit gate COMPARE the marker to the staged diff instead of
# merely checking that a marker exists. #576 is about the two ways that binding was
# still forgeable:
#
#   1. LATE HASH. The marker was hashed from a FRESH `git diff --cached` at PASS
#      time, not from the diff the reviewer was handed. If the index moved during
#      the review window, a PASS for diff A minted a marker naming diff B — so the
#      mismatch stopped blocking and started CERTIFYING.
#
#   2. UNPINNED HASH. All four sites used a bare `git diff --cached`, which honors
#      GIT_EXTERNAL_DIFF / diff.external and per-path textconv drivers, all
#      reachable from repo-controlled config. A driver emitting constant output
#      collapses every distinct diff onto one hash, dissolving the binding entirely.
#
# Every case below drives the real bypass against the real scripts and asserts the
# block — plus the positive controls, because a gate that blocks everything is not
# a fixed gate.
#
# Usage: bash tests/test-litmus-marker-binding.sh
# Exit: 0 if all pass, 1 if any fail.

set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT=$(pwd)

# Same reasoning as tests/test-pre-commit-gate.sh: the gate resolves its marker
# directory from BUSDRIVER_STATE_DIR, but every fixture here hardcodes ".claude".
unset BUSDRIVER_STATE_DIR

PASS=0
FAIL=0
TOTAL=0

GATE_SCRIPT="hooks/gate-scripts/pre-commit-gate.sh"
MARKER_WRITER="skills/litmus/scripts/write-review-marker.sh"
PRODUCER="skills/litmus/scripts/run-review-loop.sh"
DISPATCHER="scripts/dispatcher-commit-block.sh"
PRODUCER_LIB="scripts/lib/exclusion-integrity.sh"

# THE CANONICAL FORM under test. Deliberately spelled out here rather than sourced
# from the scripts: a test that derives the expression from the code it checks
# cannot detect the code changing. This literal is the specification.
CANON_FLAGS='--no-replace-objects -c color.ui=never -c core.quotePath=false diff --cached --no-ext-diff --no-textconv --full-index --ignore-submodules=none'

hash_canonical() { # $1 = repo dir
    # shellcheck disable=SC2086
    git -C "$1" $CANON_FLAGS 2>/dev/null | (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1
}
hash_bare() { # $1 = repo dir — the PRE-#576 expression, kept to prove the bypass
    git -C "$1" diff --cached 2>/dev/null | (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1
}

make_hook_input_cwd() {
    local cmd="$1" cwd="$2"
    python3 -c "
import json, sys
print(json.dumps({'tool_name':'Bash','tool_input':{'command':sys.argv[1]},'cwd':sys.argv[2]}))
" "$cmd" "$cwd"
}

new_repo() { # echoes a fresh sandbox repo path with one commit
    local d
    d=$(mktemp -d)
    git -C "$d" init -q -b main 2>/dev/null || git -C "$d" init -q
    git -C "$d" config commit.gpgsign false
    git -C "$d" config user.email "test@test.com"
    git -C "$d" config user.name "Test"
    printf 'original\n' > "$d/f.txt"
    git -C "$d" add f.txt
    git -C "$d" commit -qm "initial" --no-verify
    printf '%s' "$d"
}

gate_decision() { # $1 = repo dir → prints "block" or "allow"
    local out
    out=$(make_hook_input_cwd "git commit -m x" "$1" | bash "$GATE_SCRIPT" 2>/dev/null || true)
    if printf '%s' "$out" | grep -q '"block"' 2>/dev/null; then printf 'block'; else printf 'allow'; fi
}

ok()  { printf "  PASS  %s\n" "$1"; PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); }
bad() { printf "  FAIL  %s\n" "$1"; FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); }
check() { # $1 = actual  $2 = expected  $3 = label
    if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi
}

echo ""
echo "── 1. Late hash: the marker must name the REVIEWED diff ───"

# The builtin fallback is the widest instance of the late-hash window:
# run-review-loop.sh exits 3, an agent reviews, and a SEPARATE process
# (write-review-marker.sh) mints the marker. Everything in between is the review.
# Pre-#576 that writer re-hashed `git diff --cached` at write time, so it described
# whatever was staged when the review FINISHED. Now it consumes the reviewed-diff
# hash handed over at exit 3.
t1=$(new_repo)
printf 'REVIEWED-CONTENT\n' > "$t1/f.txt"; git -C "$t1" add f.txt
reviewed_hash=$(hash_canonical "$t1")
mkdir -p "$t1/.claude"
# Simulate run-review-loop.sh's exit-3 handoff (both files, same moment).
pf1=$(mktemp -t busdriver-review-XXXXXX)
printf '%s\n' "$pf1" > "$t1/.claude/builtin-review-prompt-path.local"
# The #790 baseline is armed by the same exit 3 — the writer refuses without it.
printf 'ABSENT\n' > "$t1/.claude/builtin-review-marker-baseline.local"
printf '%s\n' "$reviewed_hash" > "$t1/.claude/builtin-review-${pf1##*/}.hash"
# THE BYPASS: the index moves while the "review" is in flight.
printf 'SNEAKED-IN-AFTER-REVIEW\n' > "$t1/f.txt"; git -C "$t1" add f.txt
mutated_hash=$(hash_canonical "$t1")
MW_ARG="$pf1"; ( cd "$t1" && bash "$REPO_ROOT/$MARKER_WRITER" "$MW_ARG" >/dev/null 2>&1 ) || true
marker=$(cat "$t1/.claude/litmus-passed.local" 2>/dev/null || echo "")
check "$marker" "BUILTIN-${reviewed_hash}" "builtin marker names the REVIEWED diff, not the one staged at write time"
if [ "$reviewed_hash" = "$mutated_hash" ]; then
    bad "fixture broken: reviewed and mutated diffs hash the same"
else
    ok "fixture sanity: the index really did move during the review window"
fi
check "$(gate_decision "$t1")" "block" "...and the gate BLOCKS the mutated index against that marker"
rm -rf "$t1"

# Positive control: an index that did NOT move must still commit.
t1b=$(new_repo)
printf 'REVIEWED-CONTENT\n' > "$t1b/f.txt"; git -C "$t1b" add f.txt
mkdir -p "$t1b/.claude"
pf2=$(mktemp -t busdriver-review-XXXXXX)
printf '%s\n' "$pf2" > "$t1b/.claude/builtin-review-prompt-path.local"
# The #790 baseline is armed by the same exit 3 — the writer refuses without it.
printf 'ABSENT\n' > "$t1b/.claude/builtin-review-marker-baseline.local"
hash_canonical "$t1b" > "$t1b/.claude/builtin-review-${pf2##*/}.hash"
MW_ARG="$pf2"; ( cd "$t1b" && bash "$REPO_ROOT/$MARKER_WRITER" "$MW_ARG" >/dev/null 2>&1 ) || true
check "$(gate_decision "$t1b")" "allow" "an unmoved index still commits (the fix does not block honest work)"
rm -rf "$t1b"

# Fail CLOSED, and do not fall back to a fresh diff: without the hash handoff the
# writer must refuse. A fallback recompute would BE the bug.
t1c=$(new_repo)
printf 'x\n' > "$t1c/f.txt"; git -C "$t1c" add f.txt
mkdir -p "$t1c/.claude"
pf3=$(mktemp -t busdriver-review-XXXXXX)
printf '%s\n' "$pf3" > "$t1c/.claude/builtin-review-prompt-path.local"
# The #790 baseline is armed by the same exit 3 — the writer refuses without it.
printf 'ABSENT\n' > "$t1c/.claude/builtin-review-marker-baseline.local"
if MW_ARG="$pf3"; ( cd "$t1c" && bash "$REPO_ROOT/$MARKER_WRITER" "$MW_ARG" >/dev/null 2>&1 ); then
    bad "writer minted a marker with no reviewed-diff handoff (silent re-hash fallback)"
else
    ok "writer refuses when the reviewed-diff handoff is missing (no re-hash fallback)"
fi
if [ -f "$t1c/.claude/litmus-passed.local" ]; then
    bad "refused writer still left a marker behind"
else
    ok "...and leaves no marker behind"
fi
rm -rf "$t1c"

# A malformed handoff is refused too, and BOTH handoff files are still consumed —
# every attempt spends the single-use token rather than leaving one armed.
t1d=$(new_repo)
printf 'x\n' > "$t1d/f.txt"; git -C "$t1d" add f.txt
mkdir -p "$t1d/.claude"
pf4=$(mktemp -t busdriver-review-XXXXXX)
printf '%s\n' "$pf4" > "$t1d/.claude/builtin-review-prompt-path.local"
# The #790 baseline is armed by the same exit 3 — the writer refuses without it.
printf 'ABSENT\n' > "$t1d/.claude/builtin-review-marker-baseline.local"
printf 'not-a-sha\n' > "$t1d/.claude/builtin-review-${pf4##*/}.hash"
MW_ARG="$pf4"; ( cd "$t1d" && bash "$REPO_ROOT/$MARKER_WRITER" "$MW_ARG" >/dev/null 2>&1 ) && \
    bad "writer accepted a malformed reviewed-diff hash" || \
    ok "writer refuses a malformed reviewed-diff hash"
if [ -f "$t1d/.claude/builtin-review-prompt-path.local" ] \
   || [ -f "$t1d/.claude/builtin-review-${pf4##*/}.hash" ] \
   || [ -f "$t1d/.claude/builtin-review-marker-baseline.local" ]; then
    bad "a refused attempt left an armed handoff token behind (locks out the next review)"
else
    ok "...and releases both handoff tokens on refusal, so the next review can arm"
fi
rm -rf "$t1d"

# The handoff must be armed EXCLUSIVELY: an un-consumed pointer blocks a second
# arming rather than being silently overwritten (which would let reviewer A's writer
# consume run B's hash), and O_EXCL also refuses to follow a pre-created symlink at
# the sidecar path.
if grep -q 'set -o noclobber' "$PRODUCER" && grep -q 'umask 077' "$PRODUCER"; then
    ok "builtin handoff is armed with O_EXCL + a tight umask (no overwrite, no symlink follow)"
else
    bad "builtin handoff arming is not exclusive — a second run can overwrite it"
fi

# The reviewer's material and the marker hash must come from ONE atomic index
# snapshot. Two timed reads cannot be made safe: a before/after hash bracket still
# misses an A->B->A change, where both hashes read A while the diff was captured from B.
if grep -q '_INDEX_SNAPSHOT=$(mktemp' "$PRODUCER" \
   && [ "$(grep -c 'GIT_INDEX_FILE="$_INDEX_SNAPSHOT"' "$PRODUCER")" -ge 4 ]; then
    ok "reviewer material and marker hash are both derived from one atomic index snapshot"
else
    bad "captures are not pinned to a single index snapshot — an A->B->A change can still mis-bind"
fi
if grep -q '_reviewed_hash_recheck' "$PRODUCER"; then
    bad "the superseded before/after hash bracket is still present"
else
    ok "the insufficient before/after bracket was replaced, not merely supplemented"
fi

# The sidecar path is derived from UNTRUSTED state-file content and is unlinked, so a
# crafted handoff must not become an arbitrary-file delete.
t1e=$(new_repo)
printf 'x\n' > "$t1e/f.txt"; git -C "$t1e" add f.txt
mkdir -p "$t1e/.claude"
victim_dir=$(mktemp -d)
victim_hash="$victim_dir/busdriver-review-data.hash"
printf 'precious\n' > "$victim_hash"
printf '%s\n' "$victim_dir/busdriver-review-data" > "$t1e/.claude/builtin-review-prompt-path.local"
# The #790 baseline is armed by the same exit 3 — the writer refuses without it.
printf 'ABSENT\n' > "$t1e/.claude/builtin-review-marker-baseline.local"
MW_ARG="$victim_dir/busdriver-review-data"; ( cd "$t1e" && bash "$REPO_ROOT/$MARKER_WRITER" "$MW_ARG" >/dev/null 2>&1 ) || true
if [ -f "$victim_hash" ]; then
    ok "a crafted handoff cannot delete a .hash file outside the state dir"
else
    bad "crafted handoff DELETED a file outside the state dir — arbitrary-unlink primitive"
fi
rm -rf "$victim_dir"; rm -rf "$t1e"

echo ""
echo "── 2. Unpinned hash: a hostile diff driver must not collapse the binding ───"

# diff.external is repo-controlled config. A driver emitting constant output maps
# every distinct diff onto one hash. Under the pre-#576 bare form that made a marker
# for diff A validate against ANY diff B.
t2=$(new_repo)
cat > "$t2/const.sh" <<'EOF'
#!/bin/sh
echo "CONSTANT"
EOF
chmod +x "$t2/const.sh"
git -C "$t2" config diff.external "$t2/const.sh"
printf 'AAA\n' > "$t2/f.txt"; git -C "$t2" add f.txt
a_bare=$(hash_bare "$t2"); a_canon=$(hash_canonical "$t2")
mkdir -p "$t2/.claude"
printf '%s\n' "$a_canon" > "$t2/.claude/litmus-passed.local"
# THE BYPASS: swap in entirely different content.
printf 'ZZZ-completely-different\n' > "$t2/f.txt"; git -C "$t2" add f.txt
b_bare=$(hash_bare "$t2"); b_canon=$(hash_canonical "$t2")
if [ "$a_bare" = "$b_bare" ]; then
    ok "fixture sanity: the bare pre-#576 form DOES collapse both diffs onto one hash"
else
    bad "fixture broken: the hostile driver did not collapse the bare hash, so this proves nothing"
fi
if [ "$a_canon" != "$b_canon" ]; then
    ok "...while the canonical form still distinguishes them"
else
    bad "canonical form collapsed too — the pin is not working"
fi
check "$(gate_decision "$t2")" "block" "gate BLOCKS a swapped diff despite a constant-output diff.external driver"
rm -rf "$t2"

# Positive control: the hostile driver must not break a legitimate commit either.
t2b=$(new_repo)
cat > "$t2b/const.sh" <<'EOF'
#!/bin/sh
echo "CONSTANT"
EOF
chmod +x "$t2b/const.sh"
git -C "$t2b" config diff.external "$t2b/const.sh"
printf 'AAA\n' > "$t2b/f.txt"; git -C "$t2b" add f.txt
mkdir -p "$t2b/.claude"
hash_canonical "$t2b" > "$t2b/.claude/litmus-passed.local"
check "$(gate_decision "$t2b")" "allow" "...and still ALLOWS the matching diff under the same driver"
rm -rf "$t2b"

# textconv is the same collapse through a committed .gitattributes.
t2c=$(new_repo)
cat > "$t2c/const.sh" <<'EOF'
#!/bin/sh
echo "CONSTANT"
EOF
chmod +x "$t2c/const.sh"
printf '* diff=collapse\n' > "$t2c/.gitattributes"
git -C "$t2c" config diff.collapse.textconv "$t2c/const.sh"
printf 'AAA\n' > "$t2c/f.txt"; git -C "$t2c" add f.txt .gitattributes
mkdir -p "$t2c/.claude"
hash_canonical "$t2c" > "$t2c/.claude/litmus-passed.local"
printf 'ZZZ-completely-different\n' > "$t2c/f.txt"; git -C "$t2c" add f.txt
check "$(gate_decision "$t2c")" "block" "gate BLOCKS a swapped diff despite a constant-output textconv driver"
rm -rf "$t2c"

echo ""
echo "── 3. Binary changes bind exactly (--full-index) ───"

# A binary change renders as "Binary files a/x and b/x differ" and is distinguished
# ONLY by the `index <old>..<new>` line — a 7-char abbreviation without --full-index.
t3=$(new_repo)
printf 'AAAA\000\001\002BBBB' > "$t3/blob.bin"; git -C "$t3" add blob.bin
# shellcheck disable=SC2086
idx_line=$(git -C "$t3" $CANON_FLAGS | grep -m1 '^index ' || echo "")
sha_pair=${idx_line#index }
sha_old=${sha_pair%%..*}
if [ "${#sha_old}" -eq 40 ]; then
    ok "a binary path's index line carries FULL 40-hex blob SHAs (abbreviation would be 7)"
else
    bad "binary index line is not full-width: '$idx_line'"
fi
mkdir -p "$t3/.claude"
hash_canonical "$t3" > "$t3/.claude/litmus-passed.local"
printf 'ZZZZ\003\004\005YYYY' > "$t3/blob.bin"; git -C "$t3" add blob.bin
check "$(gate_decision "$t3")" "block" "a marker for binary blob A does not authorize blob B"
rm -rf "$t3"

echo ""
echo "── 4. Flag parity: the sites that must agree, do ───"

# This is the guard that a comment could not provide. #576 exists partly because an
# earlier attempt pinned the WRITERS and not dispatcher-commit-block.sh, which broke
# every commit carrying a binary change. Prose saying "keep these identical" is not
# enforcement; this is.
parity_fail=0
for f in "$GATE_SCRIPT" "$PRODUCER" "$DISPATCHER"; do
    n=$(grep -c -- "$CANON_FLAGS" "$f" || true)
    if [ "$n" -eq 0 ]; then
        bad "no canonical hash expression found in $f"
        parity_fail=1
    fi
done
[ "$parity_fail" -eq 0 ] && ok "all three hash-bearing files spell the canonical form identically"

# ...and nobody quietly reintroduces a bare re-hash into a marker write.
if grep -nE 'diff --cached[^|]*\|[^|]*(sha256sum|shasum)' "$PRODUCER" "$MARKER_WRITER" \
     | grep -v -- "$CANON_FLAGS" | grep -q .; then
    bad "a marker-writing script still hashes a BARE/unpinned \`git diff --cached\`"
    grep -nE 'diff --cached[^|]*\|[^|]*(sha256sum|shasum)' "$PRODUCER" "$MARKER_WRITER" \
        | grep -v -- "$CANON_FLAGS" | sed 's/^/        /'
else
    ok "no marker-writing script hashes an unpinned \`git diff --cached\`"
fi

# Every commit-mode marker write must emit the pre-captured hash, never a fresh one.
writes=$(grep -c 'REVIEWED_DIFF_HASH' "$PRODUCER" || true)
if [ "$writes" -ge 4 ]; then
    ok "producer routes its marker writes through the pre-review capture ($writes references)"
else
    bad "producer references REVIEWED_DIFF_HASH only $writes times — expected the capture plus every write site"
fi

# The material handed to the REVIEWER must be pinned too, not just the marker hash.
# Pinning only the marker is worse than useless: a constant-output driver hides staged
# content from the reviewer while the marker still binds the real index, so the gate
# certifies content nobody read.
if grep -q 'GIT_INDEX_FILE="$_INDEX_SNAPSHOT" git --no-replace-objects -c color.ui=never -c core.quotePath=false diff --cached --no-ext-diff --no-textconv --text --ignore-submodules=none' "$PRODUCER" \
   && grep -qF 'STAGED_DIFF=$(cat "$_diff_tmp")' "$PRODUCER"; then
    ok "the reviewer-facing staged diff is pinned against diff drivers, not just the marker"
else
    bad "commit-mode STAGED_DIFF is not pinned — a hostile driver can hide content from the reviewer"
fi

# `--no-textconv` does NOT neutralize a .gitattributes `-diff` rule: a committed
# `*.sh -diff` renders staged source as "Binary files differ", so the reviewer gets
# nothing while the full-index-bound marker stays valid. --text forces it back.
if grep -q 'diff --cached --no-ext-diff --no-textconv --text --ignore-submodules=none' "$PRODUCER"; then
    ok "reviewer-facing diffs force --text, so a \`-diff\` attribute cannot blind the reviewer"
else
    bad "reviewer-facing diffs omit --text — a .gitattributes \`-diff\` rule hides source from review"
fi

# The snapshot must cover the WHOLE run (short-circuit classification included), not
# just the capture block.
if grep -q 'export GIT_INDEX_FILE="$_INDEX_SNAPSHOT"' "$PRODUCER"; then
    ok "the index snapshot is exported for the whole run, not deleted after capture"
else
    bad "downstream index reads are not pinned to the snapshot"
fi

# `--cached` re-resolves HEAD on every call, so the comparison base needs pinning too.
if grep -q '_HEAD_BASE=("$_HEAD_SHA")' "$PRODUCER" \
   && grep -q 'verify_exclusion_policy "$_excl_worktree" "$STATE_DIR" "$_excl_base"' "$PRODUCER"; then
    ok "the comparison base is pinned once and reused by the exclusion guards and the hash"
else
    bad "HEAD is not pinned — an A->B->A HEAD change can desync hash and reviewed material"
fi

# Check-vs-use ordering: the exclusion logic must be VERIFIED BEFORE it is sourced.
# Verifying afterwards checks the wrong instant — REVIEW_EXCLUDE_ARGS would already
# have shaped the reviewed diff, and the file could be restored before the check.
verify_ln=$(grep -n 'verify_exclusion_logic "$_excl_worktree"' "$PRODUCER" | head -1 | cut -d: -f1 || true)
source_ln=$(grep -n 'source "$EXCL_LOGIC_SOURCE"' "$PRODUCER" | grep -v ':[[:space:]]*#' | head -1 | cut -d: -f1 || true)
if [ -n "$verify_ln" ] && [ -n "$source_ln" ] && [ "$verify_ln" -lt "$source_ln" ]; then
    ok "exclusion logic is verified BEFORE it is sourced (line $verify_ln < $source_ln)"
else
    bad "exclusion logic is not verified before use (verify=$verify_ln, source=$source_ln)"
fi

# Pinning the index alone is not enough: `--cached` re-resolves HEAD on every call, so
# the downstream reads that decide SIZE and SHORT-CIRCUIT classification must name the
# same base the marker was hashed against.
missing_base=""
for pat in 'FILTERED_FILES=$(GIT_INDEX_FILE' 'SC_PATHS=$(git --no-replace-objects' 'DIFF_FOR_FILTER=$(git --no-replace-objects -c color.ui=never'; do
    line=$(grep -F "$pat" "$PRODUCER" | grep -v '^ *#' | head -1 || true)
    # Either pinned endpoint form counts: commit mode names _HEAD_BASE, PR mode names
    # the pinned _PR_BASE_REF/_PR_TIP pair. What must NOT appear is a bare HEAD.
    case "$line" in
        *'_HEAD_BASE[@]'*|*'_PR_BASE_REF'*) : ;;
        *) missing_base="$missing_base $pat" ;;
    esac
done
if [ -z "$missing_base" ]; then
    ok "downstream size/short-circuit reads name the pinned base, not a freshly resolved HEAD"
else
    bad "these reads re-resolve HEAD:$missing_base"
fi

# --text unbounds a genuine binary's rendering, so the size must be measured by
# STREAMING before the diff lands in a shell variable.
if grep -q '_staged_diff_bytes=$(wc -c < "$_diff_tmp"' "$PRODUCER" \
   && grep -q 'head -c "$(( _staged_diff_max + 2 ))"' "$PRODUCER" \
   && grep -q 'LITMUS_MAX_DIFF_BYTES' "$PRODUCER"; then
    ok "the diff is rendered ONCE into a head-bounded temp file, then compared against its own capture"
else
    bad "the diff is not rendered once into a bounded file (a second rendering cannot be proven identical)"
fi

echo ""
echo "── 5. The exclusion LOGIC is an integrity input (item 3) ───"

# The excluded-only auto-pass asserts "nothing here needs review". It verified the
# POLICY (.claude/review-exclude) but not the LOGIC that parses it, so an in-worktree
# edit to exclude-generated.sh widened exclusions the same way — and the marker
# minted afterwards was CORRECTLY hash-bound to a diff no reviewer ever saw.
# shellcheck source=/dev/null
. "$REPO_ROOT/scripts/lib/exclusion-integrity.sh"

t5=$(new_repo)
mkdir -p "$t5/skills/litmus/scripts/lib"
cp "$REPO_ROOT/skills/litmus/scripts/lib/exclude-generated.sh" "$t5/skills/litmus/scripts/lib/"
git -C "$t5" add skills; git -C "$t5" commit -qm "add exclusion logic" --no-verify

if verify_exclusion_logic "$t5" "$t5/skills/litmus/scripts"; then
    ok "committed-clean exclusion logic is accepted"
else
    bad "committed-clean exclusion logic was refused: $EXCL_LOGIC_ERROR"
fi

# THE BYPASS: widen exclusions by editing the logic, without committing it.
printf '\n_DEFAULT_EXCLUDE+=("**/*")\n' >> "$t5/skills/litmus/scripts/lib/exclude-generated.sh"
if verify_exclusion_logic "$t5" "$t5/skills/litmus/scripts"; then
    bad "an UNCOMMITTED widening edit to the exclusion logic was accepted"
else
    ok "an uncommitted widening edit to the exclusion logic is refused"
fi

# An untracked logic file is refused for the same reason.
git -C "$t5" checkout -q -- skills/litmus/scripts/lib/exclude-generated.sh
git -C "$t5" rm -q --cached skills/litmus/scripts/lib/exclude-generated.sh
if verify_exclusion_logic "$t5" "$t5/skills/litmus/scripts"; then
    bad "an untracked exclusion-logic copy was accepted"
else
    ok "an untracked exclusion-logic copy is refused (git rm --cached does not launder it)"
fi
rm -rf "$t5"

# A symlinked path COMPONENT is refused: git status verifies the symlink blob, not
# the target's content, so the guard cannot vouch for what would actually be sourced.
t5b=$(new_repo)
mkdir -p "$t5b/elsewhere" "$t5b/skills/litmus/scripts"
cp "$REPO_ROOT/skills/litmus/scripts/lib/exclude-generated.sh" "$t5b/elsewhere/"
( cd "$t5b/skills/litmus/scripts" && ln -s ../../../elsewhere lib )
git -C "$t5b" add -A; git -C "$t5b" commit -qm "symlinked lib" --no-verify
if verify_exclusion_logic "$t5b" "$t5b/skills/litmus/scripts"; then
    bad "a symlinked path component on the exclusion-logic path was accepted"
else
    ok "a symlinked path component on the exclusion-logic path is refused"
fi
rm -rf "$t5b"

# An EXTERNAL directory holding a symlink that points INTO the worktree must be
# refused: a dirname-only physical check sees an outside directory and waves it
# through, while sourcing follows the link into mutable worktree bytes.
t5c=$(new_repo)
ext5=$(mktemp -d)
mkdir -p "$t5c/skills/litmus/scripts/lib" "$ext5/lib"
cp "$REPO_ROOT/skills/litmus/scripts/lib/exclude-generated.sh" "$t5c/skills/litmus/scripts/lib/"
git -C "$t5c" add -A; git -C "$t5c" commit -qm "logic" --no-verify
ln -s "$t5c/skills/litmus/scripts/lib/exclude-generated.sh" "$ext5/lib/exclude-generated.sh"
if verify_exclusion_logic "$t5c" "$ext5"; then
    bad "an external symlink pointing INTO the worktree was accepted as trusted-external"
else
    ok "an external symlink pointing INTO the worktree is refused"
fi
rm -rf "$t5c" "$ext5"

# The POLICY is the other half: a review-exclude that hides ONE staged file leaves the
# rest visible, so the all-excluded branch never runs, yet the marker binds the full
# snapshot and authorizes the hidden file. It must be verified before it is read.
t5d=$(new_repo)
mkdir -p "$t5d/.claude"
printf '**/secret.js\n' > "$t5d/.claude/review-exclude"
git -C "$t5d" add -A; git -C "$t5d" commit -qm "policy" --no-verify
if verify_exclusion_policy "$t5d" ".claude"; then
    ok "a committed-clean exclusion policy is accepted"
else
    bad "committed-clean policy refused: $EXCL_LOGIC_ERROR"
fi
printf '**/secret.js\n*\n' > "$t5d/.claude/review-exclude"
if verify_exclusion_policy "$t5d" ".claude"; then
    bad "an UNCOMMITTED widening edit to the exclusion policy was accepted"
else
    ok "an uncommitted widening edit to the exclusion policy is refused"
fi
rm -rf "$t5d"

if grep -q 'verify_exclusion_policy "$_excl_worktree"' "$PRODUCER"; then
    ok "the producer verifies the exclusion POLICY before the patterns are used"
else
    bad "the producer does not verify the policy before use"
fi

# A HARDLINK defeats every path-based check: not a symlink, and its external pathname
# genuinely resolves outside the worktree — yet editing the worktree's link mutates the
# bytes that get sourced as trusted-external logic. Both directions are asserted,
# because a guard that never accepts anything is not a guard.
t5e=$(new_repo)
ext5b=$(mktemp -d); mkdir -p "$ext5b/lib" "$t5e/skills/litmus/scripts/lib"
cp "$REPO_ROOT/skills/litmus/scripts/lib/exclude-generated.sh" "$t5e/skills/litmus/scripts/lib/"
git -C "$t5e" add -A; git -C "$t5e" commit -qm "logic" --no-verify
cp "$REPO_ROOT/skills/litmus/scripts/lib/exclude-generated.sh" "$ext5b/lib/"
if verify_exclusion_logic "$t5e" "$ext5b"; then
    ok "a plain external copy of the exclusion logic is accepted (guard is not blanket-deny)"
else
    bad "plain external copy refused: $EXCL_LOGIC_ERROR"
fi
rm -f "$ext5b/lib/exclude-generated.sh"
ln "$t5e/skills/litmus/scripts/lib/exclude-generated.sh" "$ext5b/lib/exclude-generated.sh"
if verify_exclusion_logic "$t5e" "$ext5b"; then
    bad "exclusion logic HARDLINKED into the worktree was accepted as trusted-external"
else
    ok "exclusion logic hardlinked into the worktree is refused"
fi
rm -rf "$t5e" "$ext5b"

# The link-count probe must try GNU `-c %h` BEFORE BSD `-f %l`: on GNU, `-f` means
# --file-system and treats `%l` as a filename, so a stray file named `%l` makes it
# succeed with non-numeric output and the rejection is silently skipped.
probe_line=$(grep -n '_excl_nlink=$(stat -c %h' "$PRODUCER_LIB" | head -1 | cut -d: -f1 || true)
probe_line2=$(grep -n '_excl_nlink=$(stat -f %l' "$PRODUCER_LIB" | head -1 | cut -d: -f1 || true)
if [ -n "$probe_line" ] && [ -n "$probe_line2" ] && [ "$probe_line" -lt "$probe_line2" ]; then
    ok "link-count probe tries GNU before BSD (a stray '%l' file cannot skip the check)"
else
    bad "link-count probe order is wrong (GNU=$probe_line, BSD=$probe_line2)"
fi

# The pinned read MUST describe and return the file it actually opened, on every
# platform, and it must never be able to hang. `stat` cannot do the first: on Linux
# /dev/fd is a symlink into /proc/self/fd, so a probe without -L reports the PROCFS
# SYMLINK — wrong inode (every legitimate external file refused) and link count 1 (a
# hardlink into the worktree reads as safe); measured on Ubuntu as 26:3867899 nlink=1
# for a file whose real identity was 66306:47717019 nlink=2. On macOS /dev/fd is its own
# pseudo-filesystem reporting the fdesc device for every open file, so only the inode is
# usable there — which a same-numbered file on another filesystem satisfies. And a shell
# redirection cannot do the second: `9< fifo` blocks until a writer appears. Assert
# against files built here, so whichever platform runs the suite checks its own
# behaviour.
# shellcheck source=/dev/null
. "$REPO_ROOT/$PRODUCER_LIB"
tfd=$(mktemp -d)
mkdir -p "$tfd/wt"                # a "worktree" the fixture is NOT inside
printf 'fd-probe\n' > "$tfd/one"
pin_stat=$(_excl_pin_external "$tfd/one" "$tfd/wt" "$tfd/copy" || echo "")
IFS=: read -r pin_dev pin_num pin_nlink <<< "$pin_stat"
pin_ident="${pin_dev}:${pin_num}"
path_ident=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print("%d:%d" % (s.st_dev, s.st_ino))' "$tfd/one")
if [ "$pin_nlink" = "1" ]; then
    ok "the pinned read reports the open file's link count, not a /dev/fd entry's"
else
    bad "pinned link count is '$pin_nlink', not 1 — the probe is not describing the open file"
fi
# ...and a second name must be REFUSED. This is the case a /dev/fd probe gets wrong on
# Linux (it reports the procfs symlink's link count, 1, for a file that has two names).
printf 'fd-probe\n' > "$tfd/linked"
ln "$tfd/linked" "$tfd/linked2"
if _excl_pin_external "$tfd/linked" "$tfd/wt" "$tfd/linked-copy" >/dev/null 2>&1; then
    bad "a file with two names was accepted — a hardlink into the worktree would read as safe"
else
    ok "a file with more than one name is refused by the pinned read"
fi
if [ -n "$pin_ident" ] && [ "$pin_ident" = "$path_ident" ]; then
    ok "the pinned read's identity matches its path's, so the binding can be checked at all"
else
    bad "pinned identity '$pin_ident' != path identity '$path_ident' — every trusted-external file would be refused"
fi
# Device-qualified, unconditionally: inode numbers repeat across filesystems, so an
# inode-only binding is satisfiable by a same-numbered file on another device.
case "$pin_ident" in
    *:*) ok "the pinned identity is device-qualified" ;;
    *)   bad "the pinned identity is inode-only — a cross-device inode collision satisfies the binding" ;;
esac
if cmp -s "$tfd/one" "$tfd/copy"; then
    ok "the pinned read copies the bytes it opened"
else
    bad "the pinned copy does not match the source"
fi
# The copy must be bracketed on BOTH sides. Every identity check happens before a byte
# is read, and the read loop is not instantaneous: a second name linked onto the inode,
# or a rewrite, lands mid-copy while device and inode stay identical. Only a re-read
# after the last byte catches that, and st_ctime_ns is the kernel-maintained witness
# (linking bumps it, writing bumps it, utimes cannot backdate it). This one is pinned
# structurally rather than raced: the window is real but not deterministically
# reproducible in a test, and a pin that always runs beats a probe that sometimes does.
# A SYMLINK at the source path must be refused outright. O_NOFOLLOW refuses to open one,
# and the identity comparison uses lstat rather than stat — without that, a symlink
# planted at the source pointing back at the opened inode passes every check while the
# real file has been renamed into the worktree, where its bytes are editable.
ln -s "$tfd/one" "$tfd/link-to-one"
if _excl_pin_external "$tfd/link-to-one" "$tfd/wt" "$tfd/symlink-copy" >/dev/null 2>&1; then
    bad "a symlink was accepted as the exclusion logic source"
else
    ok "a symlink at the source path is refused by the pinned read"
fi
if grep -q 'ps = os.lstat(src)' "$PRODUCER_LIB" && ! grep -q 'ps = os.stat(src)' "$PRODUCER_LIB"; then
    ok "the identity comparison uses lstat, so a symlink cannot stand in for its target"
else
    bad "the identity comparison follows symlinks — a symlink to the opened inode satisfies it"
fi

post_missing=""
grep -q 'st2 = os.fstat(fd)' "$PRODUCER_LIB" || post_missing="$post_missing re-fstat"
grep -q 'if st2.st_nlink != 1:' "$PRODUCER_LIB" || post_missing="$post_missing nlink"
grep -q 'st.st_size, st.st_mtime_ns, st.st_ctime_ns' "$PRODUCER_LIB" || post_missing="$post_missing ctime"
if [ -z "$post_missing" ]; then
    ok "the pinned read re-validates the inode after copying, not only before"
else
    bad "the pinned read never re-checks the source after the copy:$post_missing"
fi
# A FIFO must be REFUSED, promptly. This is the case a `[[ -f ]]` guard plus a shell
# redirection cannot cover: the open itself blocks, so the gate hangs before any check
# can run. The timeout is the assertion — without a non-blocking open this never returns.
mkfifo "$tfd/pipe"
# `timeout` is NOT assumed: stock macOS ships none, and a missing binary exits 127 —
# which would land in the generic "refused" branch and record a PASS without ever
# running the code under test. Use it when present, otherwise a plain watchdog.
deadline_run() {  # $1 = seconds; rest = command
    local _secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$_secs" "$@"; return $?
    fi
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$_secs" "$@"; return $?
    fi
    "$@" & local _pid=$!
    ( command sleep "$_secs"; kill -9 "$_pid" 2>/dev/null ) & local _watch=$!
    local _rc=0
    wait "$_pid" || _rc=$?
    kill "$_watch" 2>/dev/null || true
    wait "$_watch" 2>/dev/null || true
    return "$_rc"
}
fifo_rc=0
deadline_run 5 bash -c '. "$1/$2"; _excl_pin_external "$3" "$4" "$5"' _ \
    "$REPO_ROOT" "$PRODUCER_LIB" "$tfd/pipe" "$tfd/wt" "$tfd/fifo-copy" >/dev/null 2>&1 || fifo_rc=$?
if [ "$fifo_rc" = "0" ]; then
    bad "a FIFO was accepted as exclusion logic"
elif [ "$fifo_rc" = "124" ] || [ "$fifo_rc" -gt 128 ]; then
    # 124 is what `timeout` reports; >128 is a signal, which is how the fallback
    # watchdog kills a stuck child. Both mean the open never returned.
    bad "opening a FIFO hung the pinned read (killed with rc $fifo_rc) — the open is not non-blocking"
else
    ok "a FIFO is refused promptly instead of hanging the gate"
fi
# The interpreter is resolved by absolute path, not PATH: a PATH entry is repo-reachable,
# and this decides whether unreviewed code may be sourced.
# shellcheck disable=SC2123  # emptying PATH is the point: the helper must not need it
if ( PATH=/nonexistent; _excl_python >/dev/null 2>&1 ); then
    ok "the pinned read resolves python3 by absolute path, not through PATH"
else
    bad "the pinned read lost python3 when PATH was emptied — it is resolving through PATH"
fi
# PYTHONPATH is REPO-INJECTABLE — a committed .claude/settings.json `env` block sets it —
# and an injected sitecustomize is imported before the -c program runs. That puts
# repo-controlled code inside the helper that decides whether unreviewed exclusion logic
# may be sourced, where it can simply forge the answer. Mount the real attack: a
# sitecustomize that monkeypatches os.fstat to report a single-name file, then assert the
# helper still sees both names.
pyd=$(mktemp -d)
cat > "$pyd/sitecustomize.py" <<'PYFORGE'
import os, stat
class _Forged:
    st_dev = 1
    st_ino = 1
    st_nlink = 1
    st_mode = stat.S_IFREG | 0o644
os.fstat = lambda fd: _Forged()
os.stat = lambda p, **kw: _Forged()
PYFORGE
# The forge reports a fabricated device, inode and single-name count for a "regular"
# file. If the injected module ran at all, the helper echoes 1:1:1 instead of the honest
# identity — or refuses; either way the result stops matching the un-injected run.
forged=$(PYTHONPATH="$pyd" _excl_pin_external "$tfd/one" "$tfd/wt" "$tfd/forge-copy" || echo "")
if [ "$forged" = "$pin_stat" ]; then
    ok "an injected PYTHONPATH sitecustomize cannot forge the pinned identity"
else
    bad "PYTHONPATH injection changed the pinned result to '$forged' (honest: '$pin_stat') — the helper is missing -I/-S"
fi
rm -rf "$pyd" "$tfd"

# PR mode must validate the exclusion inputs against the MERGE BASE, not the branch
# tip: the branch IS the artifact under review, so a PR that commits `*` into
# review-exclude would otherwise be "clean" against itself and hide its own diff.
if grep -q 'git merge-base "$_PR_BASE_SHA" "${_HEAD_SHA:-HEAD}"' "$PRODUCER"; then
    ok "PR mode anchors the exclusion inputs on the merge base, not the branch tip"
else
    bad "PR mode validates exclusions against its own HEAD — a branch can widen them for itself"
fi

# Both exclusion guards must be anchored on the SAME resolved base in BOTH callers.
# Passing different bases (or letting a callee default to a fresh HEAD) lets a policy
# from one commit combine with logic from another.
prod_pol=$(grep -c 'verify_exclusion_policy "$_excl_worktree" "$STATE_DIR" "$_excl_base"' "$PRODUCER" || true)
prod_log=$(grep -c 'verify_exclusion_logic "$_excl_worktree" "$SCRIPT_DIR" "$_excl_base"' "$PRODUCER" || true)
disp_pol=$(grep -c 'verify_exclusion_policy "$WORKTREE_DIR" "$_policy_state_dir" "$_excl_base"' "$DISPATCHER" || true)
disp_log=$(grep -c 'verify_exclusion_logic "$WORKTREE_DIR" "$LITMUS_SCRIPTS" "$_excl_base"' "$DISPATCHER" || true)
if [ "$prod_pol" -ge 1 ] && [ "$prod_log" -ge 1 ] && [ "$disp_pol" -ge 1 ] && [ "$disp_log" -ge 1 ]; then
    ok "policy and logic guards share one pinned base in both the producer and the dispatcher"
else
    bad "exclusion guards do not share a pinned base (producer $prod_pol/$prod_log, dispatcher $disp_pol/$disp_log)"
fi

# The pinned policy is only worth something if the parser actually read it. The logic
# is sourced from the ANCHOR commit, which in PR mode predates this override, so an
# unverified live policy would be used silently. Both callers must PROVE the pin took.
if grep -q '_excl_probe=' "$PRODUCER" && grep -q '_excl_probe=' "$DISPATCHER"; then
    ok "both callers prove the exclusion parser honoured the pinned policy"
else
    bad "no sentinel probe — an older parser would silently read the live policy"
fi

# The sentinel must not survive into the built args: it would become a live exclude
# pathspec under a derivable name, dropping a file staged under it from review while
# the full-snapshot marker still authorised it.
if grep -q 'excl_arg" = ":(exclude)\$_excl_probe"' "$PRODUCER"; then
    ok "the pin sentinel is stripped from the exclusion args after it is observed"
else
    bad "the pin sentinel stays in REVIEW_EXCLUDE_ARGS as a live exclude pattern"
fi

# The pin challenge must be UNPREDICTABLE, not merely unique: it is checked against
# output from a parser that may be reading the attacker-controlled live policy, so a
# $$/$RANDOM value could be pre-seeded there to fake a pin that never happened.
if grep -q '/dev/urandom' "$PRODUCER" && grep -q '/dev/urandom' "$DISPATCHER"; then
    ok "the exclusion pin challenge is drawn from /dev/urandom, not \$\$/\$RANDOM"
else
    bad "the pin challenge is guessable — it can be pre-seeded into the live policy"
fi

# PR mode must carry the same two anti-blinding measures as commit mode.
if grep -q 'diff --no-ext-diff --no-textconv --text --ignore-submodules=none "${_PR_BASE_REF}' "$PRODUCER" \
   && grep -q 'diff --no-ext-diff --no-textconv --full-index --ignore-submodules=none "${mb}' "$PRODUCER"; then
    ok "PR mode forces --text for the reviewer and --full-index for its marker hash"
else
    bad "PR mode is missing --text and/or --full-index"
fi

# ...and the pre-PR gate must agree with compute_pr_diff_hash, or every PR marker
# breaks. Two assertions, because either one alone passes for the wrong reason. The
# literal below is the SPECIFICATION (same reasoning as CANON_FLAGS): both sides must
# spell the canonical PR-mode flags out, so neither can quietly drop --full-index or
# re-enable a repo-controlled diff driver.
CANON_PR_FLAGS='--no-replace-objects -c color.ui=never -c core.quotePath=false diff --no-ext-diff --no-textconv --full-index --ignore-submodules=none'
# `--` is load-bearing: the pattern starts with `--`, which grep would read as an
# option and abort — turning the assertion into an error rather than a comparison.
if grep -qF -- "$CANON_PR_FLAGS" hooks/gate-scripts/pre-pr-gate.sh && grep -qF -- "$CANON_PR_FLAGS" "$PRODUCER"; then
    ok "both PR-mode hash sites spell out the canonical flags"
else
    bad "a PR-mode hash site is missing the canonical flags — the binding is forgeable"
fi

# The second assertion is BEHAVIORAL, and it is the one that catches a real divergence:
# a grep for one command string still passes the moment either side is reworded, and a
# rewording can silently change the digest (a command substitution strips trailing
# newlines; a stream does not). Run both over the SAME repo and require identical
# output. The producer's function is evaluated as written and the gate's hashing
# pipeline is evaluated as the gate file spells it — neither is re-implemented here, so
# this cannot pass by agreeing with a copy of itself.
tpr=$(new_repo)
git -C "$tpr" branch -f prbase HEAD
printf 'changed\n' > "$tpr/f.txt"
printf '\000\001binary\n' > "$tpr/b.bin"
git -C "$tpr" add -A
git -C "$tpr" commit -qm "work" --no-verify
_prod_fn=$(awk '/^compute_pr_diff_hash\(\)/,/^}/' "$PRODUCER")
h_prod=$( cd "$tpr" && set -o pipefail && eval "$_prod_fn" && compute_pr_diff_hash prbase HEAD )
# Strip the `if ! ` / `; then` scaffolding so the assignment can be evaluated alone.
# `|| true`: if the gate stops streaming, this grep finds nothing and would ABORT the
# suite under `set -e` — a divergence must be reported as a failing case, not as the
# test dying. An empty extraction yields an empty digest, which the comparison below
# reports.
_gate_expr=$(grep -F 'CURRENT_HASH=$(git -C "$REPO_DIR"' hooks/gate-scripts/pre-pr-gate.sh \
    | sed 's/^[[:space:]]*if ! //; s/; then$//' || true)
h_gate=$(
    set -o pipefail
    # These four are consumed INSIDE the eval'd gate expression, which shellcheck
    # cannot see into.
    # shellcheck disable=SC2034
    REPO_DIR="$tpr"
    # shellcheck disable=SC2034
    MERGE_BASE=$(git -C "$tpr" merge-base prbase HEAD)
    # shellcheck disable=SC2034
    HEAD_SHA=$(git -C "$tpr" rev-parse --verify HEAD)
    # shellcheck disable=SC2034
    PR_HASH_CMD=()
    # shellcheck disable=SC2034  # both assignments feed the eval'd gate expression
    for _hd in /usr/bin /bin /sbin /usr/sbin; do
        if [ -x "$_hd/sha256sum" ]; then PR_HASH_CMD=("$_hd/sha256sum"); break; fi
        if [ -x "$_hd/shasum" ]; then PR_HASH_CMD=("$_hd/shasum" -a 256); break; fi
    done
    CURRENT_HASH=""
    [ -n "$_gate_expr" ] && eval "$_gate_expr"
    printf '%s' "$CURRENT_HASH"
)
if [ -n "$h_prod" ] && [ "$h_prod" = "$h_gate" ]; then
    ok "pre-PR gate and compute_pr_diff_hash produce the same digest on the same diff"
else
    bad "pre-PR gate and compute_pr_diff_hash disagree ('$h_gate' vs '$h_prod') — every PR marker would mismatch"
fi

# Neither side may hold the whole canonical diff in a shell variable: the reviewer's
# view is size-capped but this stream is not, so an excluded multi-megabyte text file —
# or binary content forced to text by a committed .gitattributes rule — would sit
# entirely in gate memory. Both must pipe git straight into the hash utility.
if grep -qE 'CURRENT_HASH=\$\(git .*\| "\$\{PR_HASH_CMD\[@\]\}"' hooks/gate-scripts/pre-pr-gate.sh \
   && ! printf '%s' "$_prod_fn" | grep -q 'diff=\$(git'; then
    ok "both PR-mode hash sites stream the diff instead of buffering it"
else
    bad "a PR-mode hash site buffers the entire canonical diff in a shell variable"
fi
rm -rf "$tpr"

# The pointer doubles as a TURN token: if another review armed one while this reviewer
# was running, writing now would overwrite that newer review's marker with a stale hash.
# The writer must refuse — and must NOT consume the other review's pointer.
t1f=$(new_repo)
printf 'x\n' > "$t1f/f.txt"; git -C "$t1f" add f.txt
mkdir -p "$t1f/.claude"
pf5=$(mktemp -t busdriver-review-XXXXXX)
pf6=$(mktemp -t busdriver-review-XXXXXX)
hash_canonical "$t1f" > "$t1f/.claude/builtin-review-${pf5##*/}.hash"
# The pointer names a DIFFERENT (later) review than the one we pass.
printf '%s\n' "$pf6" > "$t1f/.claude/builtin-review-prompt-path.local"
# The #790 baseline is armed by the same exit 3 — the writer refuses without it.
printf 'ABSENT\n' > "$t1f/.claude/builtin-review-marker-baseline.local"
if ( cd "$t1f" && bash "$REPO_ROOT/$MARKER_WRITER" "$pf5" >/dev/null 2>&1 ); then
    bad "a superseded reviewer overwrote the newer review's marker"
else
    ok "a superseded reviewer refuses to write once another review owns the handoff"
fi
if [ -f "$t1f/.claude/builtin-review-prompt-path.local" ]; then
    ok "...and leaves the newer review's pointer intact"
else
    bad "the superseded reviewer consumed another review's handoff"
fi
rm -f "$pf5" "$pf6"; rm -rf "$t1f"

# EXPORTED SHELL FUNCTIONS shadow builtins and PATH binaries in bash, and travel through
# the environment like any other repo-injectable value. A forged sha256sum emits one
# constant digest for every diff; a forged `od` makes the pin challenge predictable.
# Prefixing with `command` is not enough on its own, because `command` is shadowable too.
# The ONLY thing that actually closes the exported-function class is refusing to import
# them: in bash a function shadows a builtin, `unset`/`set`/`builtin` included, so no
# in-script sanitising is sufficient. Every entry script must re-exec under `bash -p`.
missing_p=""
for f in "$PRODUCER" "$DISPATCHER" "$GATE_SCRIPT" "$MARKER_WRITER" hooks/gate-scripts/pre-pr-gate.sh; do
    grep -q 'exec "${BASH:-/bin/bash}" -p "$0" "$@"' "$f" || missing_p="$missing_p $f"
done
if [ -z "$missing_p" ]; then
    ok "every entry script re-execs under -p, preserving its own interpreter"
else
    bad "no privileged-mode re-exec in:$missing_p"
fi

missing_unset=""
for f in "$PRODUCER" "$DISPATCHER" "$GATE_SCRIPT" hooks/gate-scripts/pre-pr-gate.sh; do
    grep -q 'unset -f command git sha256sum shasum od tr' "$f" || missing_unset="$missing_unset $f"
done
if [ -z "$missing_unset" ]; then
    ok "every hash-bearing script drops inherited shell functions before using them"
else
    bad "inherited shell functions are not dropped in:$missing_unset"
fi

# ...and the behaviour, not just the line: a forged sha256sum must not survive it.
forged=$(bash -c 'sha256sum() { echo "0000000000000000000000000000000000000000000000000000000000000000  -"; }
command() { echo FORGED; }
export -f sha256sum command
bash -c "unset -f command sha256sum 2>/dev/null || true; printf x | command sha256sum | cut -d\" \" -f1"')
if [ "$forged" = "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881" ]; then
    ok "a forged exported sha256sum does not survive the unset (real digest returned)"
else
    bad "forged sha256sum survived: got '$forged'"
fi

# Privileged mode stops exported FUNCTIONS but leaves PATH, which is repo-injectable the
# same way env is. The system dirs must come first so a planted git/sha256sum/od cannot
# win the lookup.
missing_path=""
for f in "$PRODUCER" "$DISPATCHER" "$MARKER_WRITER"; do
    grep -q 'PATH="/usr/bin:/bin:$PATH"' "$f" || missing_path="$missing_path $f"
done
if [ -z "$missing_path" ]; then
    ok "system directories are prepended to PATH in every marker-minting script"
else
    bad "PATH is not hardened in:$missing_path"
fi

# A newer successful review must retire an older builtin handoff, or that run's delayed
# writer overwrites the newer marker with its stale hash.
if grep -q 'rm -f "$STATE_DIR/builtin-review-prompt-path.local"' "$PRODUCER"; then
    ok "minting a marker retires any older builtin handoff (its writer then refuses)"
else
    bad "an older builtin handoff survives a newer review and can overwrite its marker"
fi

# The write must be SERIALIZED, not merely careful about ordering. An earlier revision
# claimed the pointer by atomic rename, which made exactly one delayed writer win — but
# it could not order this write against the ORDINARY pass path, which publishes markers
# without ever touching the handoff. #790 replaced it with the review lock the ordinary
# path already holds for its whole run, plus an equality check that the armed handoff
# still names this caller's prompt. The lock subsumes the rename: nothing else can be
# publishing while it is held.
if grep -q 'review_lock_acquire' "$MARKER_WRITER" && grep -q 'HANDOFF_PATH_NOW' "$MARKER_WRITER"; then
    ok "the builtin write is serialized by the review lock and bound to its own handoff"
else
    bad "the builtin write is not serialized by the review lock — the ordinary pass path can publish underneath it"
fi

# The POINTER must be published last. It is what a marker writer looks for and claims,
# so a pointer visible before its hash sidecar lets a concurrent writer claim it, refuse
# for want of a hash, and remove the claim — leaving this run to create an orphaned
# sidecar and report a handoff with no pointer. Ordering is structural: the race is real
# but not deterministically reproducible, and a pin that always runs beats a probe that
# sometimes does.
sidecar_line=$(grep -n 'builtin-review-\${BUILTIN_PROMPT_FILE##\*/}.hash" || exit 1' "$PRODUCER" | head -1 | cut -d: -f1 || true)
pointer_line=$(grep -n 'echo "\$BUILTIN_PROMPT_FILE" > "\$STATE_DIR/builtin-review-prompt-path.local"' "$PRODUCER" | head -1 | cut -d: -f1 || true)
if [ -n "$sidecar_line" ] && [ -n "$pointer_line" ] && [ "$sidecar_line" -lt "$pointer_line" ]; then
    ok "the handoff hash sidecar is written before the pointer that publishes it"
else
    bad "the handoff pointer is published before its hash sidecar — a concurrent writer can lose the handoff"
fi
# ...and the sidecar must be confirmed to have SURVIVED that pointer write. Ordering
# alone leaves a window: require_reviewed_diff_hash retires older builtin-review-*.hash
# files, so a concurrent run doing that between the two writes publishes a pointer with
# nothing behind it.
if grep -q '\[ -s "\$STATE_DIR/builtin-review-\${BUILTIN_PROMPT_FILE##\*/}.hash" \] ||' "$PRODUCER"; then
    ok "the sidecar is re-confirmed after the pointer is published"
else
    bad "nothing re-checks the sidecar after the pointer write — a concurrent retirement strands the pointer"
fi

# Every predicate whose OUTPUT decides an authorization must be pinned, not just the
# hashes: a constant-output driver that makes staged content look absent, or a driver
# rigged to exit 0, would otherwise hand the excluded-only path a free pass.
unpinned=""
grep -q 'NON_EXCLUDED_DIFF=$(git --no-replace-objects .* --no-ext-diff --no-textconv --ignore-submodules=none' "$DISPATCHER" \
    || unpinned="$unpinned non-excluded-diff"
[ "$(grep -c 'diff --quiet .*--no-ext-diff --no-textconv --ignore-submodules=none' "$PRODUCER_LIB")" -ge 4 ] \
    || unpinned="$unpinned anchor-quiet-diffs"
if [ -z "$unpinned" ]; then
    ok "the excluded-only predicates are pinned against diff drivers too, not just the hashes"
else
    bad "unpinned authorization predicates:$unpinned"
fi

# The producer must actually call the guard — the lib being correct is worth nothing
# if run-review-loop.sh never invokes it before minting an excluded-only marker.
if grep -q 'verify_exclusion_logic' "$PRODUCER"; then
    ok "the producer invokes the shared exclusion-logic guard"
else
    bad "the producer does not invoke verify_exclusion_logic — item 3 is not wired up"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    printf "── Results: %d/%d passed ────────────────────────────\n   All passed.\n" "$PASS" "$TOTAL"
    exit 0
else
    printf "── Results: %d/%d passed, %d FAILED ─────────────────\n" "$PASS" "$TOTAL" "$FAIL"
    exit 1
fi
