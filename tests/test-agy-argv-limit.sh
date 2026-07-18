#!/usr/bin/env bash
# tests/test-agy-argv-limit.sh — regression coverage for the agy argv size guard.
#
# WHY: the guard is portability-sensitive (Linux-only MAX_ARG_STRLEN vs ARG_MAX)
# and byte-vs-character sensitive. Both are silent-failure modes: a wrong limit
# either rejects valid prompts or lets an E2BIG through, and an E2BIG surfaces as
# "Output was not valid JSON" — the exact silent degrade this guard exists to stop.
set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
# shellcheck source=/dev/null
. "$REPO_ROOT/scripts/lib/resolve-cli.sh" 2>/dev/null

FAILED=0
fail() { echo "FAIL: $*"; FAILED=1; }

# ── byte vs character length (multibyte locale correctness) ──────────────
# ${#var} counts CHARACTERS; the kernel limits BYTES. A CJK prompt reports 1/3
# the byte count, so a ${#var}-based guard would pass a 3x-oversize prompt.
cjk=$(printf '中%.0s' $(seq 1 100))
got=$(_agy_bytelen "$cjk")
[ "$got" = "300" ] || fail "t1: _agy_bytelen on 100 CJK chars = $got, expected 300 bytes"

ascii=$(printf 'a%.0s' $(seq 1 50))
got=$(_agy_bytelen "$ascii")
[ "$got" = "50" ] || fail "t2: _agy_bytelen on 50 ASCII chars = $got, expected 50"

# Empty and unset must not error or return garbage.
got=$(_agy_bytelen "")
[ "$got" = "0" ] || fail "t3: _agy_bytelen on empty string = $got, expected 0"

# ── limit selection ──────────────────────────────────────────────────────
limit=$(_agy_argv_limit)
case "$limit" in
    ''|*[!0-9]*) fail "t4: _agy_argv_limit returned non-numeric '$limit'" ;;
esac
[ "${limit:-0}" -gt 0 ] || fail "t5: _agy_argv_limit returned non-positive '$limit'"

# On Linux the per-argument MAX_ARG_STRLEN (131071) binds whenever it is lower
# than ARG_MAX/2. On macOS/BSD no per-arg cap exists, so ARG_MAX/2 stands and the
# limit must NOT be clamped to the Linux figure.
if [ "$(uname -s 2>/dev/null)" = "Linux" ]; then
    [ "$limit" -le 131071 ] || fail "t6: Linux limit $limit exceeds MAX_ARG_STRLEN 131071"
else
    [ "$limit" -ne 131071 ] || fail "t6: non-Linux limit was clamped to the Linux-only 131071"
fi

# ── boundary behavior ────────────────────────────────────────────────────
_agy_prompt_oversize "$limit" && fail "t7: size exactly at the limit must NOT be oversize"
_agy_prompt_oversize "$(( limit + 1 ))" || fail "t8: size limit+1 must be oversize"
_agy_prompt_oversize 0 && fail "t9: zero-size must not be oversize"

# A real blueprint prompt (~40-100 KB) must pass on every platform, or design
# review silently loses its agy lens again.
_agy_prompt_oversize 100000 && fail "t10: a realistic 100 KB review prompt was rejected"

[ "$FAILED" -eq 0 ] && echo "PASS: test-agy-argv-limit" || exit 1
