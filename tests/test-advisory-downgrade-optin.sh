#!/usr/bin/env bash
# tests/test-advisory-downgrade-optin.sh
#
# Verifies scripts/advisory-downgrade-optin.sh — the ADR 0012 per-repo opt-in resolver.
# It prints `1` iff the per-repo file <main-root>/<STATE_DIR>/pr-grind-advisory-
# downgrade.local is present AND accepted as operator consent (non-repo-controlled,
# non-symlink regular file); else `0`, FAIL-CLOSED on any git error. There is no global
# switch and no repo-root env override by design — the root is derived purely from git
# (CWD), so tests run the resolver from INSIDE a fixture repo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SCRIPT_DIR/scripts/advisory-downgrade-optin.sh"
BASH_BIN="$(command -v bash)"
FILE="pr-grind-advisory-downgrade.local"

passed=0; failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }
assert_eq() { if [[ "$2" == "$1" ]]; then ok "$3"; else fail "$3 (expected '$1', got '$2')"; fi; }

[[ -f "$S" ]] || { fail "missing $S"; echo "Results: $passed passed, $failed failed"; exit 1; }

TMPROOT=$(mktemp -d)
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT
mk() { mktemp -d "$TMPROOT/XXXXXX"; }
mkrepo() { local d; d=$(mk); git -C "$d" init -q; printf '%s' "$d"; }

# Run the resolver FROM INSIDE <dir> (root is git-derived from CWD; no env seam).
run() { local dir="$1" sdir="${2:-.claude}"; ( cd "$dir" && env BUSDRIVER_STATE_DIR="$sdir" "$BASH_BIN" "$S" ); }

# 1. Neither → 0
ROOT=$(mkrepo); mkdir -p "$ROOT/.claude"; out=$(run "$ROOT")
assert_eq 0 "$out" "neither → 0"

# 2. Untracked per-repo marker (operator consent) → 1
ROOT=$(mkrepo); mkdir -p "$ROOT/.claude"; : > "$ROOT/.claude/$FILE"; out=$(run "$ROOT")
assert_eq 1 "$out" "untracked per-repo marker → 1"

# 3. Custom BUSDRIVER_STATE_DIR respected → 1
ROOT=$(mkrepo); mkdir -p "$ROOT/state"; : > "$ROOT/state/$FILE"; out=$(run "$ROOT" state)
assert_eq 1 "$out" "custom STATE_DIR → 1"

# 4. Tracked marker is repo-controlled (a PR could `git add -f` it) → 0
ROOT=$(mkrepo); mkdir -p "$ROOT/.claude"; : > "$ROOT/.claude/$FILE"
git -C "$ROOT" add -f ".claude/$FILE"; out=$(run "$ROOT")
assert_eq 0 "$out" "tracked marker → 0 (repo-controlled)"

# 5. Symlink marker → 0
ROOT=$(mkrepo); mkdir -p "$ROOT/.claude"; ln -s /dev/null "$ROOT/.claude/$FILE"; out=$(run "$ROOT")
assert_eq 0 "$out" "symlink marker → 0"

# 6. Marker in HEAD but removed from index (`git rm --cached`) → 0
ROOT=$(mkrepo); mkdir -p "$ROOT/.claude"; : > "$ROOT/.claude/$FILE"
git -C "$ROOT" add -f ".claude/$FILE"
git -C "$ROOT" -c user.email=t@t -c user.name=t commit -q -m init
git -C "$ROOT" rm --cached -q ".claude/$FILE"; out=$(run "$ROOT")
assert_eq 0 "$out" "marker in HEAD but not index → 0"

# 7. FAIL-CLOSED: non-git dir with a marker present → 0 (git resolution fails)
NG=$(mk); mkdir -p "$NG/.claude"; : > "$NG/.claude/$FILE"; out=$(run "$NG")
assert_eq 0 "$out" "non-git dir with marker → 0 (fail-closed)"

# 8. FAIL-CLOSED: non-git dir, no marker → 0
NG2=$(mk); out=$(run "$NG2")
assert_eq 0 "$out" "non-git dir, no marker → 0"

# 9. FAIL-CLOSED: a multi-component / traversal BUSDRIVER_STATE_DIR (repo-injectable) is
#    rejected even with a marker at that lexical path → 0.
ROOT=$(mkrepo); mkdir -p "$ROOT/alias/.claude"; : > "$ROOT/alias/.claude/$FILE"
out=$(run "$ROOT" "alias/.claude")
assert_eq 0 "$out" "multi-component STATE_DIR → 0 (fail-closed)"

# 10. `--separate-git-dir` checkout, marker in the checkout, resolver run in-place → 1.
#     `git worktree list` reports the SEPARATE GIT DIR (not the checkout) as the worktree
#     path; the fix detects the non-work-tree path and falls back to the current toplevel.
SGD=$(mk); mkdir -p "$SGD/co"
git init -q --separate-git-dir "$SGD/gd" "$SGD/co"
mkdir -p "$SGD/co/.claude"; : > "$SGD/co/.claude/$FILE"
out=$(run "$SGD/co")
assert_eq 1 "$out" "separate-git-dir checkout (in-place) → 1"

# 11. `--separate-git-dir` MAIN repo, resolver run from a LINKED worktree with a
#     marker planted there → 0. The main checkout is unreachable from the linked
#     worktree, so we FAIL CLOSED rather than trust the linked worktree's toplevel.
SGD2=$(mk); mkdir -p "$SGD2/co"
git init -q --separate-git-dir "$SGD2/gd" "$SGD2/co"
git -C "$SGD2/co" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$SGD2/co" worktree add -q "$SGD2/linked" >/dev/null 2>&1
mkdir -p "$SGD2/linked/.claude"; : > "$SGD2/linked/.claude/$FILE"
out=$(run "$SGD2/linked")
assert_eq 0 "$out" "separate-git-dir main + linked-worktree marker → 0 (fail-closed)"

# 12. Symlinked state dir (`.claude` → another dir) with a marker behind it → 0.
#     Guard: `! -L "$pdir"` rejects a symlinked STATE DIR (repo-injectable vector)
#     before the marker is ever considered.
ROOT=$(mkrepo); mkdir -p "$ROOT/real"; ln -s "$ROOT/real" "$ROOT/.claude"; : > "$ROOT/real/$FILE"
out=$(run "$ROOT")
assert_eq 0 "$out" "symlinked state dir → 0"

echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
