#!/usr/bin/env bash
# tests/test-enable-advisory-downgrade.sh
#
# Verifies scripts/enable-advisory-downgrade.py — the issue #326 bulk enroller that
# places the ADR 0012 per-repo opt-in marker and delegates acceptance to the resolver
# (scripts/advisory-downgrade-optin.sh). Focus: it enrolls a real git work-tree, is
# idempotent, honors --dry-run, and FAILS CLOSED on ambiguous targets — including the
# symlinked-state-dir vector, where openat + O_NOFOLLOW must refuse to write through
# the symlink (the guarantee portable bash lacked).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
E="$SCRIPT_DIR/scripts/enable-advisory-downgrade.py"
R="$SCRIPT_DIR/scripts/advisory-downgrade-optin.sh"
BASH_BIN="$(command -v bash)"
FILE="pr-grind-advisory-downgrade.local"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 0; }

passed=0; failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }
assert_eq()     { if [[ "$2" == "$1" ]]; then ok "$3"; else fail "$3 (expected '$1', got '$2')"; fi; }
assert_prefix() { if [[ "$2" == "$1"* ]]; then ok "$3"; else fail "$3 (got '$2')"; fi; }   # $2 starts with $1
assert_true()   { if "$@"; then ok "$*"; else fail "$*"; fi; }                              # test-cmd + args

[[ -f "$E" ]] || { fail "missing $E"; echo "Results: $passed passed, $failed failed"; exit 1; }

TMPROOT=$(mktemp -d)
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT
mk() { mktemp -d "$TMPROOT/XXXXXX"; }
mkrepo() { local d; d=$(mk); git -C "$d" init -q; printf '%s' "$d"; }

enroll() {
    local repo="$1" sdir="${2:-}"
    if [[ -n "$sdir" ]]; then env BUSDRIVER_STATE_DIR="$sdir" python3 "$E" "$repo"
    else python3 "$E" "$repo"; fi
}
# Resolver run from inside <dir> (root is git-derived from CWD; same env as enroll).
optin() { local dir="$1" sdir="${2:-.claude}"; ( cd "$dir" && env BUSDRIVER_STATE_DIR="$sdir" "$BASH_BIN" "$R" ); }

# 1. Fresh git repo → ENROLLED, marker is a regular file, resolver accepts it.
ROOT=$(mkrepo)
out=$(enroll "$ROOT"); code=$?
assert_eq 0 "$code" "fresh repo → exit 0"
assert_prefix ENROLLED "$out" "fresh repo → ENROLLED"
assert_true test -f "$ROOT/.claude/$FILE" -a ! -L "$ROOT/.claude/$FILE"
verdict=$(optin "$ROOT")
assert_eq 1 "$verdict" "resolver accepts placed marker"

# 2. Idempotent → ALREADY, still accepted, exit 0.
out=$(enroll "$ROOT"); code=$?
assert_eq 0 "$code" "re-run → exit 0"
assert_prefix ALREADY "$out" "re-run → ALREADY (idempotent)"

# 3. --dry-run on a fresh repo → does NOT create the marker, reports WOULD-ENROLL.
ROOT=$(mkrepo)
out=$(python3 "$E" --dry-run "$ROOT")
assert_prefix WOULD-ENROLL "$out" "dry-run → WOULD-ENROLL"
assert_true test ! -e "$ROOT/.claude/$FILE"

# 4. Symlinked state dir → SKIPPED, exit 1, and O_NOFOLLOW must NOT write through it.
ROOT=$(mkrepo); mkdir -p "$ROOT/real"; ln -s "$ROOT/real" "$ROOT/.claude"
set +e; out=$(enroll "$ROOT"); code=$?; set -e
assert_eq 1 "$code" "symlinked state dir → exit 1"
assert_prefix SKIPPED "$out" "symlinked state dir → SKIPPED"
assert_true test ! -e "$ROOT/real/$FILE"   # O_NOFOLLOW did not write through the symlink

# 5. Symlinked marker (final component) → SKIPPED, exit 1, target untouched.
ROOT=$(mkrepo); mkdir -p "$ROOT/.claude" "$ROOT/elsewhere"; ln -s "$ROOT/elsewhere/x" "$ROOT/.claude/$FILE"
set +e; out=$(enroll "$ROOT"); code=$?; set -e
assert_eq 1 "$code" "symlinked marker → exit 1"
assert_prefix SKIPPED "$out" "symlinked marker → SKIPPED"
assert_true test ! -e "$ROOT/elsewhere/x"   # did not write through the marker symlink

# 6. Non-git dir → SKIPPED, exit 1.
NG=$(mk)
set +e; out=$(enroll "$NG"); code=$?; set -e
assert_eq 1 "$code" "non-git dir → exit 1"
assert_prefix SKIPPED "$out" "non-git dir → SKIPPED"

# 7. Custom BUSDRIVER_STATE_DIR → marker lands there, resolver (same env) accepts.
ROOT=$(mkrepo)
out=$(enroll "$ROOT" state)
assert_prefix ENROLLED "$out" "custom STATE_DIR → ENROLLED"
assert_true test -f "$ROOT/state/$FILE"
verdict=$(optin "$ROOT" state)
assert_eq 1 "$verdict" "resolver accepts custom-STATE_DIR marker"

# 8. Injected GIT_DIR must not redirect discovery — scrubbed env still resolves the
#    real repo and enrolls it (regression for the git-env-injection finding).
ROOT=$(mkrepo)
out=$(GIT_DIR=/nonexistent-gitdir GIT_WORK_TREE=/nonexistent-wt python3 "$E" "$ROOT")
assert_prefix ENROLLED "$out" "injected GIT_DIR/GIT_WORK_TREE ignored → ENROLLED"
assert_true test -f "$ROOT/.claude/$FILE"

# 9. --dry-run over a TRACKED marker (resolver rejects it) → WOULD-SKIP, exit 1.
#    Dry-run must consult the resolver, not just the filesystem, or it would mislead
#    with ALREADY/exit 0 (regression for the dry-run finding).
ROOT=$(mkrepo); mkdir -p "$ROOT/.claude"; : > "$ROOT/.claude/$FILE"
git -C "$ROOT" add -f ".claude/$FILE"
set +e; out=$(python3 "$E" --dry-run "$ROOT"); code=$?; set -e
assert_eq 1 "$code" "dry-run over tracked marker → exit 1"
assert_prefix WOULD-SKIP "$out" "dry-run over tracked marker → WOULD-SKIP"

# 10. Forged `.git` gitfile pointing at another repo → rejected at main_root because the
#     dir the resolver would read consent from (worktree-list first entry = REAL) diverges
#     from the named dir (DECOY). Marker never lands in EITHER repo (regression for the
#     forged-.git / foreign-index findings).
REAL=$(mkrepo)
DECOY=$(mk); printf 'gitdir: %s/.git\n' "$REAL" > "$DECOY/.git"
set +e; out=$(enroll "$DECOY"); code=$?; set -e
assert_eq 1 "$code" "forged .git gitfile → exit 1"
assert_prefix SKIPPED "$out" "forged .git gitfile → SKIPPED"
assert_true test ! -e "$REAL/.claude/$FILE"     # not redirected into the foreign repo
assert_true test ! -e "$DECOY/.claude/$FILE"    # nor left in the named decoy dir

# 11. Resolver rejects a marker we JUST created (path tracked in HEAD, absent from the
#     working tree) → the enroller rolls the created marker back, so a transient
#     rejection can't linger as a silent opt-in (regression for the no-rollback finding).
ROOT=$(mkrepo); mkdir -p "$ROOT/.claude"; : > "$ROOT/.claude/$FILE"
git -C "$ROOT" add -f ".claude/$FILE"
git -C "$ROOT" -c user.email=t@t -c user.name=t commit -q -m init
git -C "$ROOT" rm -q --cached ".claude/$FILE"   # drop from index, keep in HEAD
rm -f "$ROOT/.claude/$FILE"                       # absent from working tree
set +e; out=$(enroll "$ROOT"); code=$?; set -e
assert_eq 1 "$code" "resolver-reject rollback → exit 1"
assert_prefix SKIPPED "$out" "resolver-reject rollback → SKIPPED"
assert_true test ! -e "$ROOT/.claude/$FILE"       # the marker we created was rolled back

# 12. Dry-run over that same absent-but-HEAD-tracked path → WOULD-SKIP, never a
#     misleading WOULD-ENROLL/exit 0 (regression for the dry-run absent-tracked finding).
set +e; out=$(python3 "$E" --dry-run "$ROOT"); code=$?; set -e
assert_eq 1 "$code" "dry-run over HEAD-tracked-absent marker → exit 1"
assert_prefix WOULD-SKIP "$out" "dry-run over HEAD-tracked-absent marker → WOULD-SKIP"

# 13. STATE_DIR as a gitlink/submodule (mode 160000) → the resolver rejects it, so
#     dry-run must predict WOULD-SKIP, not WOULD-ENROLL (regression for the gitlink
#     finding — the marker path itself isn't tracked, the PARENT is a gitlink).
ROOT=$(mkrepo)
git -C "$ROOT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
SHA=$(git -C "$ROOT" rev-parse HEAD)
mkdir -p "$ROOT/.claude"
git -C "$ROOT" update-index --add --cacheinfo "160000,$SHA,.claude"
set +e; out=$(python3 "$E" --dry-run "$ROOT"); code=$?; set -e
assert_eq 1 "$code" "dry-run over gitlink state dir → exit 1"
assert_prefix WOULD-SKIP "$out" "dry-run over gitlink state dir → WOULD-SKIP"

# 14. `--separate-git-dir` MAIN checkout must still be enrollable — `worktree list`
#     reports the git dir, not the checkout, so main_root distinguishes main-vs-linked
#     by git-dir==git-common-dir (regression for the separate-git-dir finding).
SGD=$(mk); mkdir -p "$SGD/co"
git init -q --separate-git-dir "$SGD/gd" "$SGD/co"
out=$(enroll "$SGD/co")
assert_prefix ENROLLED "$out" "separate-git-dir checkout → ENROLLED"
assert_true test -f "$SGD/co/.claude/$FILE"
verdict=$(optin "$SGD/co")
assert_eq 1 "$verdict" "resolver accepts separate-git-dir enrollment"

# 15. A repo whose path has a space, a non-ASCII char, AND a trailing space must still
#     enroll end-to-end — exercises the NUL-safe `worktree list -z` parse,
#     surrogateescape decoding, and _chomp (strips only git's trailing newline, not the
#     path's own trailing space). Regression for the byte-safety findings.
WEIRD="$TMPROOT/spacé dir "   # trailing space is part of the directory name
mkdir -p "$WEIRD"; git -C "$WEIRD" init -q
out=$(enroll "$WEIRD")
assert_prefix ENROLLED "$out" "special-char path (space / non-ASCII / trailing-space) → ENROLLED"
assert_true test -f "$WEIRD/.claude/$FILE"

echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
