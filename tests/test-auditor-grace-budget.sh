#!/usr/bin/env bash
# shellcheck disable=SC2016  # grep/awk patterns intentionally contain literal $ ( )
# shellcheck disable=SC2310,SC2312  # test helpers (eq/bp_norm/cn_norm) intentionally use command substitution in assertions; masking return values is by design here
# tests/test-auditor-grace-budget.sh — guard for the advisory Auditor
# (opencode) reap in blueprint-review + council.
#
# The old code reaped the Auditor a fixed 20s after the fixed voices finished,
# killing a slow reasoning model mid-flight (zero auditor.json ever produced).
# The fix: the reap waits the Auditor's OWN budget + 10s (like the UltraOracle's
# `cap + 10` poll), with guards so a repo-injectable env value can't weaponize
# the wider window:
#   - base-10 canonicalization (10#) BEFORE compare — zero-padded / leading-zero safe
#   - an UPPER clamp (council <=900 = oracle default; blueprint <=1800) — repo-injectable env, so hard-bounded
#   - the grace override may only SHORTEN            — never extend past budget+10
#
# Two layers: (1) golden-grep anchored to the real assignment lines proves the
# wiring is present; (2) an EXECUTABLE pass extracts the real normalization lines
# from source and runs them at the 0 / padded / ceiling / ceiling+1 / overflow boundaries,
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
assert_present "$COUNCIL" '_ag_cap=\$\(\( _AUD_TO \+ 10 \)\)' \
  "council reap default = _AUD_TO + 10" "council reap default is not _AUD_TO+10 (regressed #435)"
# #813: both council normalizers moved from a case-glob chain to ONE regex each. That block
# is pasted into a Bash tool call whose command string the gate classifier scans, and a glob
# carrying literals at a guarded helper's character offsets is a known over-block there. Pin
# the regex validation itself, so a silent drop back to an unvalidated env read fails here
# rather than shipping a repo-injectable timeout.
assert_present "$COUNCIL" '\[\[ "\$\{COUNCIL_AUDITOR_TIMEOUT:-\}" =~ ' \
  "council timeout is numerically validated" "council timeout lost its numeric validation (#813)"
assert_present "$COUNCIL" '\[\[ "\$\{COUNCIL_AUDITOR_GRACE:-\}" =~ ' \
  "council grace is numerically validated" "council grace lost its numeric validation (#813)"
# #813, and this one is not cosmetic. The block is pasted into the executor's Bash tool,
# which on a zsh-default machine runs ZSH — and zsh populates $match, not $BASH_REMATCH.
# A capture-group form therefore evaluates to $((10#)) there and pins the value at the
# default, silently killing the operator override on the shell this skill elsewhere warns
# about. Measured: zsh 5.9 answered 0 for both 07 and 900 through BASH_REMATCH.
assert_absent "$COUNCIL" 'BASH_REMATCH\[' \
  "council normalizers are zsh-safe" "council normalizer uses BASH_REMATCH — dead under zsh (#813)"
assert_present "$COUNCIL" '\[\[ "\$_ag_cap" -gt \$\(\( _AUD_TO \+ 10 \)\) \]\]' \
  "council grace override may only shorten" "council grace override can extend past budget+10"

# ── Layer 2: execute the REAL normalization lines at boundaries ──
# Extract the timeout-normalization block straight from source (start at the
# assignment, stop after the upper clamp) and eval it with a seeded env value.
bp_norm() {  # <BLUEPRINT_AUDITOR_TIMEOUT value> -> normalized _AUD_TIMEOUT
  # shellcheck disable=SC2034  # BLUEPRINT_AUDITOR_TIMEOUT is read by the eval'd source below
  local BLUEPRINT_AUDITOR_TIMEOUT="$1" _AUD_TIMEOUT code
  code="$(awk '/_AUD_TIMEOUT="\$\{BLUEPRINT_AUDITOR_TIMEOUT/{p=1} p{print} p&&/_AUD_TIMEOUT" -gt 1800/{exit}' "$LOOP")"
  eval "$code"; echo "$_AUD_TIMEOUT"
}
cn_norm() {  # <COUNCIL_AUDITOR_TIMEOUT value> -> normalized _AUD_TO
  # shellcheck disable=SC2034  # COUNCIL_AUDITOR_TIMEOUT is read by the eval'd source below
  local COUNCIL_AUDITOR_TIMEOUT="$1" _AUD_TO code
  # Anchored on the literal default line the #813 regex form opens with. The old anchor was
  # the `_AUD_TO="${COUNCIL_AUDITOR_TIMEOUT...` assignment, which no longer exists — the
  # extractor would have captured ZERO bytes and every boundary case below would have run
  # against nothing, passing vacuously.
  code="$(awk '/^  _AUD_TO=900$/{p=1} p{print} p&&/_AUD_TO" -gt 900/{exit}' "$COUNCIL")"
  eval "$code"; echo "$_AUD_TO"
}

# sanity: extraction actually captured runnable code
if [[ -z "$(bp_norm 300)" ]]; then fail "could not extract blueprint normalization block"; fi
if [[ -z "$(cn_norm 120)" ]]; then fail "could not extract council normalization block"; fi

# Blueprint: default AND hard clamp 1800 (ADR 0027, 2026-08-03 revision). The
# clamp bounds the env vector at the same value the default already allows — it
# is NOT a trust boundary, because omitting the variable reaches 1800 anyway.
eq "$(bp_norm 300)"      300  "blueprint 300 (in-range)"
eq "$(bp_norm 00000600)" 600  "blueprint 00000600 (zero-padded → not octal, not default)"
eq "$(bp_norm 600)"      600  "blueprint 600 (former ceiling, now in-range)"
eq "$(bp_norm 1800)"     1800 "blueprint 1800 (at ceiling)"
eq "$(bp_norm 1801)"     1800 "blueprint 1801 (upper clamp)"
eq "$(bp_norm 3600)"     1800 "blueprint 3600 (repo-injected → clamped to 1800)"
eq "$(bp_norm 12345678)" 1800 "blueprint 12345678 (>7 digits → length guard → max)"
eq "$(bp_norm 0)"        1800 "blueprint 0 (→ default)"
eq "$(bp_norm 9999999)"  1800 "blueprint 9999999 (DoS bound → max clamp)"
eq "$(bp_norm abc)"      1800 "blueprint abc (non-numeric → default)"

# Council: default AND hard clamp 900 (UltraOracle-parity default; repo-injectable → not raisable).
eq "$(cn_norm 120)"      120  "council 120 (in-range)"
eq "$(cn_norm 00000600)" 600  "council 00000600 (zero-padded)"
eq "$(cn_norm 900)"      900  "council 900 (at ceiling)"
eq "$(cn_norm 901)"      900  "council 901 (upper clamp)"
eq "$(cn_norm 3600)"     900  "council 3600 (repo-injected → clamped to 900)"
eq "$(cn_norm 12345678)" 900  "council 12345678 (>7 digits → length guard → max)"
eq "$(cn_norm 0)"        900  "council 0 (→ default)"
eq "$(cn_norm 9999999)"  900  "council 9999999 (DoS bound)"
eq "$(cn_norm 07)"       7    "council 07 (leading zero -> 7, never octal)"
eq "$(cn_norm 0012345678)" 900 "council 0012345678 (padded, >7 significant digits -> max)"

# ...and the SAME extracted lines under ZSH, which is what the executor actually runs on a
# macOS default shell. This file is bash, so every case above proves only the bash half; a
# zsh-only regression (the BASH_REMATCH shape) would pass all of them. Skipped, not failed,
# where zsh is absent — the assertion is about portability, not about having zsh installed.
if command -v zsh >/dev/null 2>&1; then
  _zsh_cn() {  # <COUNCIL_AUDITOR_TIMEOUT value> -> normalized _AUD_TO, under zsh
    # Through a FILE, never `zsh -c "$code"`: the double quotes would let THIS bash expand
    # ${COUNCIL_AUDITOR_TIMEOUT} and $((10#...)) before zsh ever saw them, and the rows would
    # measure bash wearing a zsh costume.
    local f
    f="$(mktemp)"
    awk '/^  _AUD_TO=900$/{p=1} p{print} p&&/_AUD_TO" -gt 900/{exit}' "$COUNCIL" > "$f"
    printf '%s\n' 'print -r -- "$_AUD_TO"' >> "$f"
    COUNCIL_AUDITOR_TIMEOUT="$1" zsh "$f" 2>/dev/null
    rm -f "$f"
  }
  eq "$(_zsh_cn 120)"  120 "council 120 under zsh (override survives a non-bash shell)"
  eq "$(_zsh_cn 07)"   7   "council 07 under zsh (leading zero, never octal)"
  eq "$(_zsh_cn 3600)" 900 "council 3600 under zsh (clamped)"
  eq "$(_zsh_cn abc)"  900 "council abc under zsh (non-numeric -> default)"
else
  echo "SKIP: zsh not installed — zsh-portability rows not exercised"
fi

# Actual >64-bit overflow-sized digit strings must land on EXACTLY each
# normalizer's ceiling — bp 1800, cn 900. Asserting an exact value rather than a
# 1..max range is deliberate: a range accepts a regression that normalizes the
# oversized input to any in-range garbage (42 would pass), which is precisely the
# 64-bit-wrap failure this guard exists to catch.
eq "$(bp_norm 999999999999999999999)" 1800 "bp_norm overflow-sized input → ceiling"
eq "$(cn_norm 999999999999999999999)" 900 "cn_norm overflow-sized input → ceiling"

echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
