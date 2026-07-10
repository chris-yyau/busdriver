#!/usr/bin/env bash
# tests/test-advisory-downgrade-optin.sh
#
# Verifies scripts/advisory-downgrade-optin.sh — the ADR 0012 opt-in resolver that
# prints `1` iff the advisory-bot stale-ack downgrade is opted in for this repo via
# EITHER the per-repo file (`<main-root>/<STATE_DIR>/pr-grind-advisory-downgrade.local`)
# OR the global file (`<GLOBAL_STATE_DIR>/pr-grind-advisory-downgrade.local`).
#
# Env seams (no real git/HOME needed): BUSDRIVER_MAIN_ROOT pins the per-repo root,
# BUSDRIVER_GLOBAL_STATE_DIR pins the global dir, BUSDRIVER_STATE_DIR the per-repo
# state dir name. We assert the OBSERVABLE contract: opted-in IFF a file is present,
# and FAIL-CLOSED (`0`) when the root is unresolvable and no global file exists.

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
mk() { mktemp -d "$TMPROOT/XXXXXX"; }

# Run the resolver with pinned roots; echo its stdout. GLOBAL points at an empty
# dir by default so only files the test creates count.
run() { # <main_root> <global_dir> [state_dir]
  local root="$1" gdir="$2" sdir="${3:-.claude}"
  env BUSDRIVER_MAIN_ROOT="$root" BUSDRIVER_GLOBAL_STATE_DIR="$gdir" \
      BUSDRIVER_STATE_DIR="$sdir" "$BASH_BIN" "$S"
}

# 1. Neither file present → 0
ROOT=$(mk); GDIR=$(mk); mkdir -p "$ROOT/.claude"
out=$(run "$ROOT" "$GDIR")
assert_eq 0 "$out" "neither present → 0"

# 2. Per-repo file only → 1
ROOT=$(mk); GDIR=$(mk); mkdir -p "$ROOT/.claude"; : > "$ROOT/.claude/$FILE"
out=$(run "$ROOT" "$GDIR")
assert_eq 1 "$out" "per-repo only → 1"

# 3. Global file only → 1
ROOT=$(mk); GDIR=$(mk); mkdir -p "$ROOT/.claude"; : > "$GDIR/$FILE"
out=$(run "$ROOT" "$GDIR")
assert_eq 1 "$out" "global only → 1"

# 4. Both present → 1
ROOT=$(mk); GDIR=$(mk); mkdir -p "$ROOT/.claude"; : > "$ROOT/.claude/$FILE"; : > "$GDIR/$FILE"
out=$(run "$ROOT" "$GDIR")
assert_eq 1 "$out" "both present → 1"

# 5. Custom BUSDRIVER_STATE_DIR respected for the per-repo file → 1
ROOT=$(mk); GDIR=$(mk); mkdir -p "$ROOT/state"; : > "$ROOT/state/$FILE"
out=$(run "$ROOT" "$GDIR" "state")
assert_eq 1 "$out" "custom STATE_DIR per-repo → 1"

# 6. FAIL-CLOSED: unresolvable main root (empty BUSDRIVER_MAIN_ROOT, run from a
#    non-git dir) and no global file → 0.
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
#    root unresolvable — the resolver must skip the global check (never probe a
#    root-level /.claude) and, with no per-repo file + non-git cwd, print 0 without
#    crashing under `set -u`.
NONGIT=$(mk)
out=$(cd "$NONGIT" && env -u HOME -u BUSDRIVER_GLOBAL_STATE_DIR BUSDRIVER_MAIN_ROOT="" \
        BUSDRIVER_STATE_DIR=".claude" "$BASH_BIN" "$S")
assert_eq 0 "$out" "HOME + global unset, unresolvable root → 0 (fail-closed)"

echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
