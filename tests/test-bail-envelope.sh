#!/usr/bin/env bash
# tests/test-bail-envelope.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/lib/bail-envelope.sh"

# Test 1: emit_bail prints single-line JSON + exits 1
output=$(bash -c "source '$HELPER'; emit_bail 'judgment' 'litmus stall'" 2>&1 || true)
echo "$output" | jq -e '.bail_category == "judgment" and .bail_reason == "litmus stall"' >/dev/null \
    || { echo "FAIL t1: $output"; exit 1; }

# Test 2: safe parent-parse pattern (MED #1 — explicit pattern documented)
parent_test=$(bash -c '
    source '"$HELPER"'
    child_output=$(bash -c "source \"'"$HELPER"'\"; emit_bail env network" 2>&1 || true)
    bail_json=$(printf "%s\n" "$child_output" | parse_bail_envelope)
    echo "$bail_json"
')
echo "$parent_test" | jq -e '.bail_category == "env" and .bail_reason == "network"' >/dev/null \
    || { echo "FAIL t2: $parent_test"; exit 1; }

# Test 3: invalid category rejected (tooling removed by inversion)
invalid_output=$(bash -c "source '$HELPER'; emit_bail 'tooling' 'recovery'" 2>&1 || true)
if printf '%s\n' "$invalid_output" | grep -q "invalid bail_category"; then :; else
    echo "FAIL t3: bogus 'tooling' should be rejected"; exit 1
fi

# Test 4: parent-parse skips noise, finds the envelope at any position
output=$(printf 'noise line\n{"bail_category":"budget","bail_reason":"loop"}\nmore noise\n' \
    | bash -c "source '$HELPER'; parse_bail_envelope")
echo "$output" | jq -e '.bail_category == "budget"' >/dev/null \
    || { echo "FAIL t4: $output"; exit 1; }

# Test 5: reason with embedded quotes JSON-safe-encoded
output=$(bash -c "source '$HELPER'; emit_bail 'judgment' 'msg with \"quotes\" inside'" 2>&1 || true)
echo "$output" | jq -e '.bail_reason' >/dev/null || { echo "FAIL t5: not JSON-safe"; exit 1; }

echo "All bail-envelope tests passed"
