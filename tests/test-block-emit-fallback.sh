#!/usr/bin/env bash
# Regression: block_emit must emit VALID JSON on EVERY tier, not just jq.
# Pre-fix, the jq-absent fallback escaped only `"` with sed, so a reason
# containing a backslash or newline produced malformed JSON (Task 8).
#
# block_emit has three tiers: jq → python3 (json.dumps) → pure-shell.
# For each gate script we extract its block_emit function and exercise BOTH
# fallback tiers by masking `command -v` for the relevant binaries:
#   - python3 tier: mask jq only
#   - pure-shell tier: mask jq AND python3
# Then we assert the output parses as JSON with decision=block. The python3
# tier must round-trip the reason exactly; the pure-shell last resort DELETES
# the JSON-special bytes (quote, backslash) and all control chars, so we assert
# valid JSON containing neither of those two bytes.
#
# Usage: bash tests/test-block-emit-fallback.sh
# Exit: 0 if all pass, 1 if any fail.

set -euo pipefail
cd "$(dirname "$0")/.."

PASS=0
FAIL=0

# A reason exercising every char the old sed missed: backslash, newline,
# carriage return, tab, a raw control byte (0x01), double-quote, and a
# command-substitution snippet the gate messages really contain.
REASON=$'CRITICAL: cd "$(...)"\r\nbackslash \\ and tab\there \x01ctrl `backtick`'

# emit_masked <script> <mask...> — run the script's block_emit with the named
# binaries hidden from `command -v`, printing its output.
emit_masked() {
    local script="$1"; shift
    local fn masked
    fn=$(awk '/^block_emit\(\)/{p=1} p{print} /^}/{if(p){print "";exit}}' "$script")
    masked="$*"
    (
        eval "$fn"
        # shellcheck disable=SC2329  # invoked indirectly via block_emit's `command -v`
        command() {
            if [[ "$1" == -v ]]; then
                local b
                for b in $masked; do [[ "$2" == "$b" ]] && return 1; done
            fi
            builtin command "$@"
        }
        block_emit "$REASON"
    )
}

for f in pre-commit-gate pre-pr-gate pre-merge-gate freeze-guard; do
    script="hooks/gate-scripts/$f.sh"

    # python3 tier (jq masked) — must round-trip the reason EXACTLY.
    out_py=$(emit_masked "$script" jq)
    if printf '%s' "$out_py" | REASON="$REASON" python3 -c \
        'import json,os,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("decision")=="block" and d.get("reason")==os.environ["REASON"] else 1)'; then
        echo "PASS: $f python3 tier round-trips reason exactly"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $f python3 tier — $out_py"
        FAIL=$((FAIL + 1))
    fi

    # pure-shell tier (jq AND python3 masked) — valid JSON with the two
    # JSON-special bytes (chr(34)='"', chr(92)='\') deleted. chr() keeps this
    # assertion free of literal backslashes in the source.
    out_sh=$(emit_masked "$script" jq python3)
    if printf '%s' "$out_sh" | python3 -c \
        'import json,sys; d=json.load(sys.stdin); r=d.get("reason",""); sys.exit(0 if d.get("decision")=="block" and chr(34) not in r and chr(92) not in r else 1)'; then
        echo "PASS: $f pure-shell tier emits valid JSON"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $f pure-shell tier — $out_sh"
        FAIL=$((FAIL + 1))
    fi
done

echo "----"
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
