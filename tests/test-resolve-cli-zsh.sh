#!/usr/bin/env bash
# test-resolve-cli-zsh.sh — #914: resolve-cli.sh sourced from zsh must still find
# the grok children beside itself.
#
# The council Step 4 block sources resolve-cli.sh in the executor's Bash tool,
# which is zsh on macOS. zsh never sets ${BASH_SOURCE[0]}, so the preflight child
# resolved to /dev/null, the preflight refused, and the Researcher silently became
# `none` on every council run. No grok binary or sandbox profile is needed: the
# assertion is on the child path the parent resolved, which is the defect.
set -uo pipefail
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
LIB="$ROOT/scripts/lib/resolve-cli.sh"
FAILED=0
pass() { printf 'ok   — %s\n' "$1"; }
fail() { printf 'FAIL — %s\n' "$1"; FAILED=1; }

if ! command -v zsh >/dev/null 2>&1; then
  printf 'SKIP: zsh not installed; #914 is a zsh-only defect\n'
  exit 0
fi

# Run from a scratch CWD so a relative-path fallback could not pass by accident.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

out="$(cd "$SCRATCH" && HINDSIGHT_DISABLED=1 zsh -fc '
  source "$1" 2>/dev/null
  grok_sandbox_preflight "" >/dev/null 2>&1
  grok_hindsight_prefetch "" >/dev/null 2>&1
  print -r -- "GSP=$_GSP_CHILD"
  print -r -- "GHP=$_GHP_CHILD"
' _ "$LIB")"

want_gsp="GSP=$ROOT/scripts/lib/grok-preflight.sh"
want_ghp="GHP=$ROOT/scripts/lib/grok-hindsight-prefetch.py"
if grep -qxF "$want_gsp" <<<"$out"; then pass "zsh: preflight child resolves beside the library"
else fail "zsh: preflight child — want '$want_gsp', got: $(grep '^GSP=' <<<"$out" || true)"; fi
if grep -qxF "$want_ghp" <<<"$out"; then pass "zsh: hindsight prefetch child resolves beside the library"
else fail "zsh: prefetch child — want '$want_ghp', got: $(grep '^GHP=' <<<"$out" || true)"; fi

# Sourced by a RELATIVE path, then cd elsewhere: the child must not re-resolve
# against the new CWD, or that directory could supply it.
mkdir -p "$SCRATCH/scripts/lib" && : >"$SCRATCH/scripts/lib/grok-preflight.sh" \
  && : >"$SCRATCH/scripts/lib/grok-hindsight-prefetch.py"
out="$(cd "$ROOT" && HINDSIGHT_DISABLED=1 zsh -fc '
  source scripts/lib/resolve-cli.sh 2>/dev/null
  cd "$1" || exit 1
  grok_sandbox_preflight "" >/dev/null 2>&1
  grok_hindsight_prefetch "" >/dev/null 2>&1
  print -r -- "GSP=$_GSP_CHILD"
  print -r -- "GHP=$_GHP_CHILD"
' _ "$SCRATCH")"
if grep -qxF "$want_gsp" <<<"$out"; then pass "zsh: relative source + cd keeps the preflight child beside the library"
else fail "zsh: relative source + cd — want '$want_gsp', got: $(grep '^GSP=' <<<"$out" || true)"; fi
if grep -qxF "$want_ghp" <<<"$out"; then pass "zsh: relative source + cd keeps the prefetch child beside the library"
else fail "zsh: relative source + cd — want '$want_ghp', got: $(grep '^GHP=' <<<"$out" || true)"; fi

# bash must be unchanged: BASH_SOURCE still wins.
out="$(cd "$SCRATCH" && HINDSIGHT_DISABLED=1 bash -c '
  source "$1" 2>/dev/null
  grok_sandbox_preflight "" >/dev/null 2>&1
  printf "GSP=%s\n" "$_GSP_CHILD"
' _ "$LIB")"
if grep -qxF "$want_gsp" <<<"$out"; then pass "bash: preflight child unchanged"
else fail "bash: preflight child — want '$want_gsp', got: $out"; fi

# bash that inherited an exported ZSH_VERSION must not take the zsh branch: the
# zsh-only eval is a bad substitution there and would abort a `set -e` caller.
out="$(cd "$SCRATCH" && ZSH_VERSION=5.9 bash -ec 'source "$1"; echo SURVIVED' _ "$LIB" 2>&1)"
if grep -qx SURVIVED <<<"$out"; then pass "bash + exported ZSH_VERSION: sourcing survives set -e"
else fail "bash + exported ZSH_VERSION: sourcing aborted — $out"; fi

# ...and zsh that inherited an exported BASH_VERSION must still find the children.
out="$(cd "$SCRATCH" && BASH_VERSION=5.2 zsh -fc '
  source "$1" 2>/dev/null
  grok_sandbox_preflight "" >/dev/null 2>&1
  print -r -- "GSP=$_GSP_CHILD"
' _ "$LIB")"
if grep -qxF "$want_gsp" <<<"$out"; then pass "zsh + exported BASH_VERSION: preflight child resolves beside the library"
else fail "zsh + exported BASH_VERSION — want '$want_gsp', got: $out"; fi

exit "$FAILED"
