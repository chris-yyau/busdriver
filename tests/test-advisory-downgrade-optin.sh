#!/usr/bin/env bash
# tests/test-advisory-downgrade-optin.sh
#
# Verifies scripts/advisory-downgrade-optin.sh — the ADR 0012 opt-in resolver that
# prints `1` iff the advisory-bot stale-ack downgrade is opted in for this repo via
# EITHER the per-repo file (`<main-root>/<STATE_DIR>/pr-grind-advisory-downgrade.local`)
# OR the global file (`<GLOBAL_STATE_DIR>/pr-grind-advisory-downgrade.local`).
#
# Env seams: BUSDRIVER_MAIN_ROOT pins the per-repo root, BUSDRIVER_GLOBAL_STATE_DIR
# the global dir, BUSDRIVER_STATE_DIR the per-repo state dir name. The per-repo path
# requires a real git repo (operator-consent boundary: the marker must be untracked
# / not committed / not a symlink / not inside a gitlink), so per-repo cases init a
# throwaway repo; global/unresolvable cases need no git. We assert the OBSERVABLE
# contract: opted-in IFF an eligible file is present, and FAIL-CLOSED (`0`) on any
# ambiguity — unresolvable root, unqueryable repo, or a repo-controlled marker.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SCRIPT_DIR/scripts/advisory-downgrade-optin.sh"
BASH_BIN="$(command -v bash)"
FILE="pr-grind-advisory-downgrade.local"

passed=0; failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }
assert_eq() { # <expected> <actual> <label>
  if [[ "$2" == "$1" ]]; then ok "$3"; else fail "$3 (expected '$1', got '$2')"; fi
}

[[ -f "$S" ]] || { fail "missing $S"; echo "Results: $passed passed, $failed failed"; exit 1; }

# One sandbox root; sub-dirs live under it and are removed by a single recursive
# cleanup. (Avoids relying on an array mutated inside command substitution — `mk`
# runs in a subshell via `$(mk)`, so a parent-scope array would stay empty and leak.)
TMPROOT=$(mktemp -d)
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT
mk() { mktemp -d "$TMPROOT/XXXXXX"; }          # bare temp dir (NOT a git repo)
mkrepo() { local d; d=$(mk); git -C "$d" init -q; printf '%s' "$d"; }   # git repo

# Run the resolver with pinned roots; echo its stdout. GLOBAL points at an empty
# dir by default so only files the test creates count.
run() { # <main_root> <global_dir> [state_dir]
  local root="$1" gdir="$2" sdir="${3:-.claude}"
  env BUSDRIVER_MAIN_ROOT="$root" BUSDRIVER_GLOBAL_STATE_DIR="$gdir" \
      BUSDRIVER_STATE_DIR="$sdir" "$BASH_BIN" "$S"
}

# 1. Neither file present → 0
ROOT=$(mkrepo); GDIR=$(mk); mkdir -p "$ROOT/.claude"
out=$(run "$ROOT" "$GDIR")
assert_eq 0 "$out" "neither present → 0"

# 2. Per-repo untracked marker (operator consent) → 1
ROOT=$(mkrepo); GDIR=$(mk); mkdir -p "$ROOT/.claude"; : > "$ROOT/.claude/$FILE"
out=$(run "$ROOT" "$GDIR")
assert_eq 1 "$out" "per-repo untracked marker → 1"

# 3. Global file only → 1 (global is repo-independent; no git needed)
ROOT=$(mk); GDIR=$(mk); : > "$GDIR/$FILE"
out=$(run "$ROOT" "$GDIR")
assert_eq 1 "$out" "global only → 1"

# 4. Both present → 1 (global short-circuits first)
ROOT=$(mkrepo); GDIR=$(mk); mkdir -p "$ROOT/.claude"; : > "$ROOT/.claude/$FILE"; : > "$GDIR/$FILE"
out=$(run "$ROOT" "$GDIR")
assert_eq 1 "$out" "both present → 1"

# 5. Custom BUSDRIVER_STATE_DIR respected for the per-repo marker → 1
ROOT=$(mkrepo); GDIR=$(mk); mkdir -p "$ROOT/state"; : > "$ROOT/state/$FILE"
out=$(run "$ROOT" "$GDIR" "state")
assert_eq 1 "$out" "custom STATE_DIR per-repo → 1"

# 6. FAIL-CLOSED: unresolvable main root (empty, run from a non-git dir) + no global → 0
NONGIT=$(mk); GDIR=$(mk)
out=$(cd "$NONGIT" && env BUSDRIVER_MAIN_ROOT="" BUSDRIVER_GLOBAL_STATE_DIR="$GDIR" \
        BUSDRIVER_STATE_DIR=".claude" "$BASH_BIN" "$S")
assert_eq 0 "$out" "unresolvable root + no global → 0 (fail-closed)"

# 7. Global still wins even when the root is unresolvable (standing consent) → 1
NONGIT=$(mk); GDIR=$(mk); : > "$GDIR/$FILE"
out=$(cd "$NONGIT" && env BUSDRIVER_MAIN_ROOT="" BUSDRIVER_GLOBAL_STATE_DIR="$GDIR" \
        BUSDRIVER_STATE_DIR=".claude" "$BASH_BIN" "$S")
assert_eq 1 "$out" "global present, unresolvable root → 1"

# 8. FAIL-CLOSED: both HOME and BUSDRIVER_GLOBAL_STATE_DIR unset makes the global
#    root unresolvable — skip the global check (never probe a root-level /.claude);
#    with no per-repo file + non-git cwd → 0, no crash under `set -u`.
NONGIT=$(mk)
out=$(cd "$NONGIT" && env -u HOME -u BUSDRIVER_GLOBAL_STATE_DIR BUSDRIVER_MAIN_ROOT="" \
        BUSDRIVER_STATE_DIR=".claude" "$BASH_BIN" "$S")
assert_eq 0 "$out" "HOME + global unset, unresolvable root → 0 (fail-closed)"

# 9. A TRACKED per-repo marker is repo-controlled (a PR author could `git add -f`
#    it), NOT operator consent → 0.
ROOT=$(mkrepo); GDIR=$(mk); mkdir -p "$ROOT/.claude"
: > "$ROOT/.claude/$FILE"; git -C "$ROOT" add -f ".claude/$FILE"
out=$(run "$ROOT" "$GDIR")
assert_eq 0 "$out" "tracked per-repo marker → 0 (repo-controlled, rejected)"

# 10. A SYMLINK per-repo marker is rejected (must be a regular non-symlink file).
ROOT=$(mkrepo); GDIR=$(mk); mkdir -p "$ROOT/.claude"
ln -s /dev/null "$ROOT/.claude/$FILE"
out=$(run "$ROOT" "$GDIR")
assert_eq 0 "$out" "symlink per-repo marker → 0 (rejected)"

# 11. FAIL-CLOSED: MAIN_ROOT is NOT a git repo — consent is unprovable even though
#     the marker file is present → 0 (a git error must never read as "untracked").
ROOT=$(mk); GDIR=$(mk); mkdir -p "$ROOT/.claude"; : > "$ROOT/.claude/$FILE"
out=$(run "$ROOT" "$GDIR")
assert_eq 0 "$out" "non-git root with marker → 0 (fail-closed)"

# 12. A GLOBAL marker that sits inside a git repo AND is tracked there (dotfiles
#     repo rooted at the global dir) is repo-controlled → 0. Per-repo root is a
#     fresh empty repo so it doesn't independently opt in.
GREPO=$(mkrepo); PREPO=$(mkrepo); mkdir -p "$GREPO/gstate"; : > "$GREPO/gstate/$FILE"
git -C "$GREPO" add -f "gstate/$FILE"
out=$(run "$PREPO" "$GREPO/gstate")
assert_eq 0 "$out" "tracked global marker inside a repo → 0 (rejected)"

# 13. A per-repo marker committed in HEAD but removed from the index (`git rm
#     --cached`) is still repo-originated → 0 (HEAD-tree check, not just index).
ROOT=$(mkrepo); GDIR=$(mk); mkdir -p "$ROOT/.claude"; : > "$ROOT/.claude/$FILE"
git -C "$ROOT" add -f ".claude/$FILE"
git -C "$ROOT" -c user.email=t@t -c user.name=t commit -q -m init
git -C "$ROOT" rm --cached -q ".claude/$FILE"   # out of index, still in HEAD + worktree
out=$(run "$ROOT" "$GDIR")
assert_eq 0 "$out" "marker in HEAD but not index → 0 (rejected)"

echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
