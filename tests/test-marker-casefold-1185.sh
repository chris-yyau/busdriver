#!/usr/bin/env bash
# Regression tests for #1185 -- marker_check.py matched marker names case-sensitively, but
# macOS APFS (case-insensitive by default) resolves .claude/SKIP-LITMUS.local to the same
# file the gates read as skip-litmus.local. So a differently spelled name forged a marker
# on the Write/Edit path and on every Bash path (touch, rm, redirect).
#
# Measured on APFS over every code point whose case or normal form is ASCII: besides ASCII
# case, it folds 11 characters, some to two or three letters (long s U+017F to s, Kelvin
# sign U+212A to k, sharp s U+00DF to ss, the ff/fi/fl/ffi/ffl/st ligatures). casefold()
# maps all 11; one- and two-letter folds are pinned here. A fullwidth s (U+FF53)
# names a DIFFERENT file there, so it stays allowed.
set -u
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT/hooks/gate-scripts/lib/marker_check.py"
# shellcheck source=/dev/null
. "$ROOT/tests/lib/gate-cwd-isolation.sh" || exit 1   # #1064
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; }

verdict() { # <tool> <field> <value> -> the verdict line, or ERROR
    local payload
    payload=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":sys.argv[1],"tool_input":{sys.argv[2]:sys.argv[3]}}))' \
        "$1" "$2" "$3" 2>/dev/null) || { printf 'ERROR'; return; }
    python3 -I "$CLASSIFIER" <<<"$payload" 2>/dev/null || printf 'ERROR'
}

expect() { # <want-verdict> <tool> <field> <value> <label>
    local got
    got="$(verdict "$2" "$3" "$4")"
    if [[ "$got" == "$1" ]]; then ok "$5"; else no "$5" "got=${got:-<empty>} -- expected $1"; fi
}

LONG_S=$'\xc5\xbf'      # U+017F, folds to s on APFS
KELVIN=$'\xe2\x84\xaa'  # U+212A, folds to k on APFS
WIDE_S=$'\xef\xbd\x93'  # U+FF53, a different name on APFS
SHARP_S=$'\xc3\x9f'     # U+00DF, folds to ss on APFS
LIG_FF=$'\xef\xac\x80'  # U+FB00, folds to ff on APFS

echo "-- A. Write/Edit/MultiEdit of a differently spelled marker BLOCK --"
expect "BLOCK_MARKER|skip-litmus.local" Write file_path "/r/.claude/SKIP-LITMUS.local" "Write SKIP-LITMUS.local"
expect "BLOCK_MARKER|skip-litmus.local" Edit file_path "/r/.claude/Skip-Litmus.Local" "Edit Skip-Litmus.Local"
expect "BLOCK_MARKER|bypass-log.jsonl" MultiEdit file_path "/r/.claude/BYPASS-LOG.JSONL" "MultiEdit BYPASS-LOG.JSONL"
expect "BLOCK_MARKER|skip-litmus.local" Write file_path "/r/.claude/${LONG_S}kip-litmus.local" "Write long-s spelling"
expect "BLOCK_MARKER|skip-litmus.local" Write file_path "/r/.claude/s${KELVIN}ip-litmus.local" "Write Kelvin-sign spelling"
expect "BLOCK_MARKER|bypass-log.jsonl" Write file_path "/r/.claude/bypa${SHARP_S}-log.jsonl" "Write sharp-s spelling (ss)"
expect "BLOCK_MARKER|.skip-design-review-lease.d" Write file_path "/r/.claude/.SKIP-DESIGN-REVIEW-LEASE.D/1" "Write into the LEASE dir"

echo "-- B. Bash writes and deletes of a differently spelled marker BLOCK --"
expect "BLOCK_MARKER|skip-litmus.local" Bash command "touch .claude/SKIP-LITMUS.local" "touch SKIP-LITMUS.local"
expect "BLOCK_MARKER|bypass-log.jsonl" Bash command "rm .claude/Bypass-Log.jsonl" "rm Bypass-Log.jsonl"
expect "BLOCK_MARKER|skip-pr-grind.local" Bash command "echo x > .claude/SKIP-PR-GRIND.LOCAL" "redirect into SKIP-PR-GRIND.LOCAL"
expect "BLOCK_MARKER|skip-litmus.local" Bash command "m=.claude/Skip-Litmus.local; rm \"\$m\"" "rm through a variable"
expect "BLOCK_MARKER|skip-litmus.local" Bash command "touch .claude/s${KELVIN}ip-litmus.local" "touch Kelvin-sign spelling"
expect "BLOCK_MARKER|ref-ff-authorized.local" Bash command "touch .claude/ref-${LIG_FF}-authorized.local" "touch ff-ligature spelling"
expect "BLOCK_MARKER_UNPARSED|skip-litmus.local" Bash command "touch .claude/SKIP-LITMUS.local 'x" "unparseable command still matches folded"

echo "-- C. reads, and names APFS does not fold, stay allowed --"
expect "OK|" Bash command "cat .claude/SKIP-LITMUS.local" "cat SKIP-LITMUS.local"
expect "OK|" Bash command "test -f .claude/Skip-Litmus.local" "test -f Skip-Litmus.local"
expect "OK|" Write file_path "/r/.claude/${WIDE_S}kip-litmus.local" "Write fullwidth-s name (a different file)"
expect "OK|" Write file_path "/r/docs/notes.md" "Write an unrelated file"

# Positive control: the lowercase spelling, which blocked before #1185 too.
expect "BLOCK_MARKER|skip-litmus.local" Bash command "touch .claude/skip-litmus.local" "control: touch skip-litmus.local"

printf '\n==== marker-casefold-1185: %d passed, %d failed ====\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
