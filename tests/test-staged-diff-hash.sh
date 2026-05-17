#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO_ROOT/scripts/lib/staged-diff-hash.sh"

output=$(printf 'hello world' | bash -c "source '$HELPER'; hash_stdin")
[ ${#output} -eq 64 ] || { echo "FAIL: expected 64-char hex, got $output"; exit 1; }
[[ "$output" =~ ^[0-9a-f]{64}$ ]] || { echo "FAIL: not all hex"; exit 1; }

a=$(printf 'x' | bash -c "source '$HELPER'; hash_stdin")
b=$(printf 'x' | bash -c "source '$HELPER'; hash_stdin")
[ "$a" = "$b" ] || { echo "FAIL: non-deterministic"; exit 1; }
echo "All staged-diff-hash tests passed"
