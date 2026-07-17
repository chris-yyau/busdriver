#!/usr/bin/env bash
# Task 7: an async run() blocking decision must be honored through the REAL
# gate dispatch path (sanitized-node.sh → run-with-flags.js), not just the unit.
#
# sanitized-node.sh is exactly what hooks.json invokes for the pure-block gates;
# it appends --fail-closed. Before the run-with-flags.js `await` fix, an async
# run()'s Promise was swallowed to exit 0 here — the gate would fail OPEN. This
# drives the launcher with a temp async-block fixture and asserts it blocks.
#
# Usage: bash tests/test-run-with-flags-blocking.sh
# Exit: 0 if all pass, 1 if any fail.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd)
LAUNCHER="hooks/gate-scripts/lib/sanitized-node.sh"

PASS=0
FAIL=0
FIXTURE_REL="tests/.tmp-rwf-fixture-$$.js"
cleanup() { rm -f "$ROOT/$FIXTURE_REL"; }
trap cleanup EXIT

# node must be resolvable for the launcher to run; skip cleanly if absent (the
# launcher would fail-closed on no-node, which is a different code path).
if ! command -v node >/dev/null; then
  echo "SKIP: node not found — cannot exercise the node dispatch path"
  exit 0
fi

run_launcher() { # <fixture-body>  -> sets OUT / RC
  printf '%s' "$1" > "$ROOT/$FIXTURE_REL"
  OUT=$(printf '%s' '{"tool":"Bash","tool_input":{"command":"echo hi"}}' \
    | CLAUDE_PLUGIN_ROOT="$ROOT" HOME="${HOME:-/tmp}" \
      bash "$ROOT/$LAUNCHER" "pre:test-async-shell" "$FIXTURE_REL" "standard" 2>/dev/null)
  RC=$?
}

# 1. async run() returning a block → launcher exits 2 with a block decision.
run_launcher 'module.exports = { run: async () => ({ exitCode: 2, stdout: "{\"decision\":\"block\",\"reason\":\"async gate\"}" }) };'
blocked=no
if printf '%s' "$OUT" | grep -q '"decision":"block"'; then blocked=yes; fi
ok=no
if [[ "$RC" -eq 2 ]]; then
  if [[ "$blocked" == yes ]]; then ok=yes; fi
fi
if [[ "$ok" == yes ]]; then
  echo "PASS: async run() block honored through sanitized-node.sh (rc=$RC)"
  PASS=$((PASS + 1))
else
  echo "FAIL: async run() block NOT honored (rc=$RC, out=$OUT)"
  FAIL=$((FAIL + 1))
fi

# 2. async run() returning allow (exit 0) → launcher exits 0 (no false block).
run_launcher 'module.exports = { run: async () => ({ exitCode: 0 }) };'
if [[ "$RC" -eq 0 ]]; then
  echo "PASS: async run() allow passes through (rc=$RC)"
  PASS=$((PASS + 1))
else
  echo "FAIL: async run() allow should exit 0 (rc=$RC, out=$OUT)"
  FAIL=$((FAIL + 1))
fi

echo "----"
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
