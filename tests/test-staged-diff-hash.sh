#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO_ROOT/scripts/lib/staged-diff-hash.sh"

# Test 1: output is a 64-char lowercase hex string
output=$(printf 'hello world' | bash -c "source '$HELPER'; hash_stdin")
[[ ${#output} -eq 64 ]] || { echo "FAIL: expected 64-char hex, got $output"; exit 1; }
[[ "$output" =~ ^[0-9a-f]{64}$ ]] || { echo "FAIL: not all hex"; exit 1; }

# Test 2: deterministic across two calls
a=$(printf 'x' | bash -c "source '$HELPER'; hash_stdin")
b=$(printf 'x' | bash -c "source '$HELPER'; hash_stdin")
[[ "$a" = "$b" ]] || { echo "FAIL: non-deterministic"; exit 1; }

# Test 3: known SHA-256 test vector (input "abc" → known digest per FIPS 180-4)
# This catches a constant or stubbed hash implementation that passes shape checks.
EXPECTED="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
# Note: no trailing newline — use printf, not echo
got=$(printf 'abc' | bash -c "source '$HELPER'; hash_stdin")
[[ "$got" = "$EXPECTED" ]] \
    || { echo "FAIL: known-vector mismatch: expected $EXPECTED got $got"; exit 1; }

echo "All staged-diff-hash tests passed"
