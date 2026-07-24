#!/usr/bin/env bash
# shellcheck disable=SC2016  # grep/awk patterns intentionally contain literal $ ( )
# shellcheck disable=SC2310,SC2312  # test helpers (eq/bp_norm/cn_norm) intentionally use command substitution in assertions; masking return values is by design here
# tests/test-auditor-grace-budget.sh — guard for the advisory Auditor
# (opencode/kimi-k3) reap in blueprint-review + council.
#
# The old code reaped the Auditor a fixed 20s after the fixed voices finished,
# killing a slow reasoning model mid-flight (zero auditor.json ever produced).
# The fix: the reap waits the Auditor's OWN budget + 10s (like the UltraOracle's
# `cap + 10` poll), with guards so a repo-injectable env value can't weaponize
# the wider window:
#   - base-10 canonicalization (10#) BEFORE compare — zero-padded / leading-zero safe
#   - an UPPER clamp (council <=900 = oracle default; blueprint <=600) — repo-injectable env, so hard-bounded
#   - the grace override may only SHORTEN            — never extend past budget+10
#
# Two layers: (1) golden-grep anchored to the real assignment lines proves the
# wiring is present; (2) an EXECUTABLE pass extracts the real normalization lines
# from source and runs them at the 0 / padded / 600 / 601 / overflow boundaries,
# so a broken reorder or a restored fixed tail actually fails the test.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOOP="$SCRIPT_DIR/skills/blueprint-review/scripts/run-design-review-loop.sh"
COUNCIL="$SCRIPT_DIR/skills/council/SKILL.md"

passed=0; failed=0
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }

assert_present() {  # <file> <ere> <ok-msg> <fail-msg>
  if grep -qE "$2" "$1"; then ok "$3"; else fail "$4"; fi
}
assert_absent() {   # <file> <ere> <ok-msg> <fail-msg>
  if grep -qE "$2" "$1"; then fail "$4"; else ok "$3"; fi
}
eq() {  # <got> <want> <label>
  if [[ "$1" == "$2" ]]; then ok "$3 → $1"; else fail "$3 → got '$1', want '$2'"; fi
}

for f in "$LOOP" "$COUNCIL"; do
  if [[ ! -f "$f" ]]; then
    fail "missing $f"; echo "Results: $passed passed, $failed failed"; exit 1
  fi
done

# ── Layer 1: anchored wiring (matches the assignment lines, not comments) ──
assert_absent  "$LOOP" 'BLUEPRINT_AUDITOR_GRACE:-20' \
  "blueprint 20s tail reap removed" "blueprint still has BLUEPRINT_AUDITOR_GRACE:-20"
assert_present "$LOOP" '_aud_grace_cap="\$\{BLUEPRINT_AUDITOR_GRACE:-\$\(\( _AUD_TIMEOUT \+ 10 \)\)\}"' \
  "blueprint reap default = _AUD_TIMEOUT + 10" "blueprint reap default is not _AUD_TIMEOUT+10 (regressed #435)"
assert_present "$LOOP" '\[\[ "\$_aud_grace_cap" -gt \$\(\( _AUD_TIMEOUT \+ 10 \)\) \]\]' \
  "blueprint grace override may only shorten" "blueprint grace override can extend past budget+10"
assert_absent  "$COUNCIL" 'COUNCIL_AUDITOR_GRACE:-20' \
  "council 20s tail reap removed" "council still has COUNCIL_AUDITOR_GRACE:-20"
assert_present "$COUNCIL" '_ag_cap="\$\{COUNCIL_AUDITOR_GRACE:-\$\(\( _AUD_TO \+ 10 \)\)\}"' \
  "council reap default = _AUD_TO + 10" "council reap default is not _AUD_TO+10 (regressed #435)"
assert_present "$COUNCIL" '\[\[ "\$_ag_cap" -gt \$\(\( _AUD_TO \+ 10 \)\) \]\]' \
  "council grace override may only shorten" "council grace override can extend past budget+10"

# ── Layer 2: execute the REAL normalization lines at boundaries ──
# Extract the timeout-normalization block straight from source (start at the
# assignment, stop after the upper clamp) and eval it with a seeded env value.
bp_norm() {  # <BLUEPRINT_AUDITOR_TIMEOUT value> -> normalized _AUD_TIMEOUT
  # shellcheck disable=SC2034  # BLUEPRINT_AUDITOR_TIMEOUT is read by the eval'd source below
  local BLUEPRINT_AUDITOR_TIMEOUT="$1" _AUD_TIMEOUT code
  code="$(awk '/_AUD_TIMEOUT="\$\{BLUEPRINT_AUDITOR_TIMEOUT/{p=1} p{print} p&&/_AUD_TIMEOUT" -gt 600/{exit}' "$LOOP")"
  eval "$code"; echo "$_AUD_TIMEOUT"
}
cn_norm() {  # <COUNCIL_AUDITOR_TIMEOUT value> -> normalized _AUD_TO
  # shellcheck disable=SC2034  # COUNCIL_AUDITOR_TIMEOUT is read by the eval'd source below
  local COUNCIL_AUDITOR_TIMEOUT="$1" _AUD_TO code
  code="$(awk '/_AUD_TO="\$\{COUNCIL_AUDITOR_TIMEOUT/{p=1} p{print} p&&/_AUD_TO" -gt 900/{exit}' "$COUNCIL")"
  eval "$code"; echo "$_AUD_TO"
}

# sanity: extraction actually captured runnable code
if [[ -z "$(bp_norm 300)" ]]; then fail "could not extract blueprint normalization block"; fi
if [[ -z "$(cn_norm 120)" ]]; then fail "could not extract council normalization block"; fi

# Blueprint: default AND hard clamp 600 (repo-injectable env → not raisable past the safe bound).
eq "$(bp_norm 300)"      300  "blueprint 300 (in-range)"
eq "$(bp_norm 00000600)" 600  "blueprint 00000600 (zero-padded → not octal, not default)"
eq "$(bp_norm 600)"      600  "blueprint 600 (at ceiling)"
eq "$(bp_norm 601)"      600  "blueprint 601 (upper clamp)"
eq "$(bp_norm 3600)"     600  "blueprint 3600 (repo-injected → clamped to 600)"
eq "$(bp_norm 12345678)" 600  "blueprint 12345678 (>7 digits → length guard → max)"
eq "$(bp_norm 0)"        600  "blueprint 0 (→ default)"
eq "$(bp_norm 9999999)"  600  "blueprint 9999999 (DoS bound → max clamp)"
eq "$(bp_norm abc)"      600  "blueprint abc (non-numeric → default)"

# Council: default AND hard clamp 900 (UltraOracle-parity default; repo-injectable → not raisable).
eq "$(cn_norm 120)"      120  "council 120 (in-range)"
eq "$(cn_norm 00000600)" 600  "council 00000600 (zero-padded)"
eq "$(cn_norm 900)"      900  "council 900 (at ceiling)"
eq "$(cn_norm 901)"      900  "council 901 (upper clamp)"
eq "$(cn_norm 3600)"     900  "council 3600 (repo-injected → clamped to 900)"
eq "$(cn_norm 12345678)" 900  "council 12345678 (>7 digits → length guard → max)"
eq "$(cn_norm 0)"        900  "council 0 (→ default)"
eq "$(cn_norm 9999999)"  900  "council 9999999 (DoS bound)"

# Actual >64-bit overflow-sized digit strings: the result must stay bounded in
# 1..900 for BOTH normalizers (bp clamps to 600, cn to 900 — both ≤900; never
# abort, never wrap to an in-range garbage value that escapes the clamp).
for _nz in bp_norm cn_norm; do
  _ov="$("$_nz" 999999999999999999999)"
  if [[ "$_ov" -ge 1 && "$_ov" -le 900 ]]; then ok "$_nz overflow-sized input bounded → $_ov"
  else fail "$_nz overflow-sized input escaped 1..900 → $_ov"; fi
done

echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
