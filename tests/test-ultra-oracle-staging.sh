#!/bin/bash
# tests/test-ultra-oracle-staging.sh — spec §2 staging, run dir and record (§11 staging cases).
set -u
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; export HOME="$T/home"; mkdir -p "$HOME"; cd "$T" || exit 1
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT INT TERM
FAIL=0; pass() { echo "OK:   $1"; }; fail() { echo "FAIL: $1"; FAIL=1; }
# shellcheck source=/dev/null
source "$DIR/scripts/lib/ultra-oracle.sh"

run="$(_uora_new_run)" || fail "new run"
tag="${run%%$'\t'*}"; rd="${run#*$'\t'}"
[[ "$tag" =~ ^[0-9a-f]{16}$ ]] && pass "16-hex tag" || fail "tag '$tag'"
[ "$rd" = "$(cd "$HOME/.cache/busdriver/ultra-oracle/run-$tag" && pwd -P)" ] && pass "run dir under \$HOME/.cache, canonical" || fail "rd=$rd"
case "$rd" in "$DIR"*) fail "run dir inside the repository" ;; *) pass "run dir outside the repository" ;; esac
[ -n "$(find "$rd" -prune -perm 700)" ] && pass "run dir 0700" || fail "run dir mode"

dst="$rd/uora-$tag.txt"
printf 'Q' > "$T/p"; printf 'A' > "$T/a.txt"; mkdir -p "$T/x"; printf 'B' > "$T/x/a.txt"
_uora_stage "$dst" "" "$T/p" "$T/a.txt" "$T/x/a.txt" && pass "stage ok" || fail "stage"
[ "$(cat "$dst")" = "$(printf 'Q\n=== [1] a.txt ===\nA\n=== [2] a.txt ===\nB')" ] \
  && pass "duplicate basenames keep their indices; a prompt with no trailing newline still gets one before the header" || fail "staged: $(od -c "$dst" | head)"
grep -qF "$T" "$dst" && fail "the staged file carries a full local path" || pass "basename only"
_uora_stage "$dst" "inline prompt" "" && [ "$(cat "$dst")" = "inline prompt" ] && pass "--prompt text" || fail "--prompt text"
rm -f "$T/a.txt"; [ -f "$dst" ] && pass "callers may delete their files after staging" || fail "staged file gone"

ln -s "$T/p" "$T/link"
_uora_stage "$dst" "" "$T/link" 2>/dev/null && fail "symlink prompt accepted" || pass "symlink prompt -> error"
_uora_stage "$dst" "" "$T/p" "$T/link" 2>/dev/null && fail "symlink context accepted" || pass "symlink context -> error"
chmod 000 "$T/x/a.txt"; _uora_stage "$dst" "" "$T/p" "$T/x/a.txt" 2>/dev/null && fail "unreadable accepted" || pass "unreadable -> error"; chmod 600 "$T/x/a.txt"
: > "$T/empty"; _uora_stage "$dst" "" "$T/empty" 2>/dev/null && fail "empty prompt file accepted" || pass "empty prompt file -> error"

# A regular file named '-' is that file, never stdin (cat reads an operand '-' as stdin).
printf 'D' > "$T/-"
echo STDIN | _uora_stage "$dst" "" "-" && [ "$(cat "$dst")" = "D" ] && pass "prompt file named '-' is the file" || fail "prompt '-': $(cat "$dst")"
echo STDIN | _uora_stage "$dst" "" "$T/p" "-" && [ "$(cat "$dst")" = "$(printf 'Q\n=== [1] - ===\nD')" ] && pass "context named '-' is the file" || fail "context '-': $(cat "$dst")"

# None of these may block: each must return within 10 s. The watchdog runs beside the command, so a
# hang is reported as one (exit 124) instead of stalling the suite.
killtree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do killtree "$c"; done; kill "$1" 2>/dev/null; }
run10() { # <cmd...> — the command's status, or 124 after killing it at 10 s
  local p i=0
  "$@" & p=$!
  while kill -0 "$p" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$p" 2>/dev/null; then killtree "$p"; wait "$p" 2>/dev/null; return 124; fi
  wait "$p"
}
bounded() { # <label> <cmd...>   — the label is not part of the command
  local label="$1" rc
  shift
  run10 "$@" 2> "$T/bounded.err"; rc=$?
  if [ "$rc" = 124 ]; then fail "$label blocked"
  elif [ "$rc" = 0 ]; then fail "$label accepted"
  elif ! grep -q '^ultra-oracle: ' "$T/bounded.err"; then fail "$label: _uora_stage never ran (rc=$rc: $(head -c 200 "$T/bounded.err"))"
  else pass "$label -> error, bounded"; fi
}
mkfifo "$T/fifo"; bounded "FIFO" _uora_stage "$dst" "" "$T/p" "$T/fifo"
bounded "/dev/zero" _uora_stage "$dst" "" "$T/p" /dev/zero
head -c 6000000 /dev/zero | tr '\0' a > "$T/big1"; head -c 6000000 /dev/zero | tr '\0' b > "$T/big2"
bounded "a combined set over 10 MB" _uora_stage "$dst" "" "$T/p" "$T/big1" "$T/big2"
# A file that grows during staging: whether its read ends under or over the cap is a race, so only
# the bound is asserted, plus that an accepted result is within the cap and an error is reported.
: > "$T/grow"; ( while :; do printf '%065536d' 0 >> "$T/grow"; done ) & gp=$!
run10 _uora_stage "$dst" "" "$T/p" "$T/grow" 2> "$T/grow.err"; rc=$?; kill "$gp" 2>/dev/null; wait "$gp" 2>/dev/null
if [ "$rc" = 124 ]; then fail "a growing file blocked staging"
elif [ "$rc" = 0 ] && [ "$(wc -c < "$dst" | tr -dc 0-9)" -le $((10 * 1024 * 1024)) ]; then pass "a growing file: staged within the cap, bounded"
elif [ "$rc" != 0 ] && grep -q '^ultra-oracle: ' "$T/grow.err"; then pass "a growing file: refused, bounded"
else fail "a growing file: rc=$rc, $(head -c 200 "$T/grow.err")"; fi
printf 'a\000b' > "$T/nul"; bounded "a NUL-containing context" _uora_stage "$dst" "" "$T/p" "$T/nul"
# A read that fails part-way (an I/O error, or the file made unreadable after _uora_input_ok)
# must not stage a partial prompt. A function named cat shadows the binary inside the staging
# subshell: it emits one byte of the second context and then fails.
printf 'first' > "$T/c1"; printf 'second' > "$T/c2"
cat() { if [ "${2-}" = "$T/c2" ]; then printf 's'; return 1; fi; command cat "$@"; }
bounded "a context whose read fails after some bytes" _uora_stage "$dst" "" "$T/p" "$T/c1" "$T/c2"
unset -f cat
[ ! -e "$dst.rerr" ] && pass "no .rerr left behind" || fail ".rerr left behind"

h="$(_uora_sha256 "$T/p")"
[ "$h" = "$(printf 'Q' | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)" ] && pass "sha256" || fail "sha256 '$h'"
_uora_record "$rd" --arg h "$h" '.staged_sha256 = $h' && _uora_record "$rd" '.phase = "setup"'
[ "$(/usr/bin/jq -r '.staged_sha256 + " " + .phase' "$rd/record.json")" = "$h setup" ] && pass "record.json updates merge" || fail "record.json"

[ "$FAIL" = 0 ] && echo "PASS test-ultra-oracle-staging" || exit 1
