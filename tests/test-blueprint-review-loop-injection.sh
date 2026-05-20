#!/usr/bin/env bash
# Regression tests for python-heredoc hardening in run-design-review-loop.sh.
#
# Three sites in the loop script previously interpolated bash variables
# directly into python source:
#   1. compute_spec_hash python fallback — `$file` path
#   2. Gemini metadata-injection heredoc — RUN_ID/SPEC_HASH/ITERATION/DURATION
#   3. Codex metadata-injection heredoc — same shape, different variables
# All three now pass values via env vars and use single-quoted python sources.
# These tests exercise each pattern in isolation against malicious payloads.
#
# Usage: bash tests/test-blueprint-review-loop-injection.sh
# Exit:  0 if all pass, 1 if any fail.

# Test harness uses command substitutions with pipelines and conditional lists
# (e.g. `$(sha256sum "$f" | cut -d' ' -f1)`, `$([[ ! -e "$f" ]] && echo true || echo false)`)
# where the inner exit code is intentionally not propagated — disable SC2312.
# shellcheck disable=SC2312

set -euo pipefail

PASS=0
FAIL=0
TOTAL=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    printf "  PASS  %s\n" "$name"
    PASS=$((PASS + 1))
  else
    printf "  FAIL  %s\n        expected: %q\n        actual:   %q\n" \
      "$name" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_true() {
  local name="$1" condition="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$condition" == "true" ]]; then
    printf "  PASS  %s\n" "$name"
    PASS=$((PASS + 1))
  else
    printf "  FAIL  %s\n" "$name"
    FAIL=$((FAIL + 1))
  fi
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# ── compute_spec_hash python fallback: env-var path is injection-safe ─
echo "── compute_spec_hash python fallback ────────────────────────"

# Direct invocation of the same env-var-based python command used in the
# fallback path. We exercise it with a path containing single quotes — the
# pre-fix `open('$file', 'rb')` would have either crashed on the quote or
# (with a crafted payload) executed code. Post-fix, the path is a literal
# read from os.environ and quote characters are part of the filename.
TRICKY_PATH="$SANDBOX/file with 'single quotes' in name.md"
echo "predictable-content" > "$TRICKY_PATH"

ACTUAL_HASH=$(_CSH_FILE="$TRICKY_PATH" python3 -c \
  'import hashlib, os; print(hashlib.sha256(open(os.environ["_CSH_FILE"], "rb").read()).hexdigest())')
# Mirror the production fallback chain (sha256sum → shasum → python) so the
# oracle resolves on macOS (shasum) AND Linux (sha256sum); under set -euo
# pipefail, hard-coding `shasum` would crash on Linux before the assertion
# below ever fires.
if command -v sha256sum &>/dev/null; then
  EXPECTED_HASH=$(sha256sum "$TRICKY_PATH" | cut -d' ' -f1)
elif command -v shasum &>/dev/null; then
  EXPECTED_HASH=$(shasum -a 256 "$TRICKY_PATH" | cut -d' ' -f1)
else
  EXPECTED_HASH=$(_ORACLE_FILE="$TRICKY_PATH" python3 -c \
    'import hashlib, os; print(hashlib.sha256(open(os.environ["_ORACLE_FILE"], "rb").read()).hexdigest())')
fi
assert_eq "python fallback handles paths with single quotes" \
  "$EXPECTED_HASH" "$ACTUAL_HASH"

# Path-with-injection-payload: the env-var pathway treats the whole string
# as a literal filename (which doesn't exist), so python raises FileNotFoundError
# rather than executing anything. We verify by running with `|| true` and
# observing the absence of a side-effect marker file.
LOOP_INJECTION_FILE="$SANDBOX/csh-injection-marker.txt"
rm -f "$LOOP_INJECTION_FILE"
EVIL_PATH="${SANDBOX}/x'); open('${LOOP_INJECTION_FILE}','w').close(); ('"
_CSH_FILE="$EVIL_PATH" python3 -c \
  'import hashlib, os; print(hashlib.sha256(open(os.environ["_CSH_FILE"], "rb").read()).hexdigest())' \
  >/dev/null 2>&1 || true
assert_true "compute_spec_hash injection payload did not execute" \
  "$([[ ! -e "$LOOP_INJECTION_FILE" ]] && echo true || echo false)"

# ── Metadata injection heredoc: env-var path is injection-safe ────────
echo "── metadata-injection heredoc (Gemini/Codex shared) ─────────"

# Build a pending JSON file and run the same env-var-based metadata-injection
# command that lives inside the loop. The payload is a malicious RUN_ID that,
# pre-fix, would have closed the python single-quoted string and executed the
# embedded code. Post-fix, RUN_ID is read from os.environ and the literal
# characters are stored in the JSON unchanged.
PENDING="$SANDBOX/metadata-pending.json"
echo '{"status": "pass", "issues": []}' > "$PENDING"

MIM_INJECTION_FILE="$SANDBOX/mim-injection-marker.txt"
rm -f "$MIM_INJECTION_FILE"
MALICIOUS_RUN_ID="'; open('${MIM_INJECTION_FILE}','w').close(); '"

_MIM_PENDING="$PENDING" \
_MIM_RUN_ID="$MALICIOUS_RUN_ID" \
_MIM_ITERATION="1" \
_MIM_SPEC_HASH="abc123" \
_MIM_DURATION="42" \
python3 -c '
import json, os, sys
pending = os.environ["_MIM_PENDING"]
with open(pending) as f:
    data = json.load(f)
if not isinstance(data, dict) or "status" not in data:
    sys.exit(0)
data.setdefault("metadata", {})
data["metadata"]["run_id"] = os.environ["_MIM_RUN_ID"]
data["metadata"]["iteration"] = int(os.environ["_MIM_ITERATION"])
data["metadata"]["spec_hash"] = os.environ["_MIM_SPEC_HASH"]
data["metadata"]["review_duration_ms"] = int(os.environ["_MIM_DURATION"])
with open(pending, "w") as f:
    json.dump(data, f, indent=2)
'

assert_true "metadata-injection heredoc: malicious RUN_ID did not execute" \
  "$([[ ! -e "$MIM_INJECTION_FILE" ]] && echo true || echo false)"

# Verify the literal payload was stored verbatim (proving the env-var pathway).
STORED=$(python3 -c \
  'import json, sys; print(json.load(open(sys.argv[1]))["metadata"]["run_id"])' \
  "$PENDING")
assert_eq "metadata-injection: payload stored as literal string" \
  "$MALICIOUS_RUN_ID" "$STORED"

# Non-numeric ITERATION must fail at int() conversion, not execute.
# `|| true` swallows the python failure exactly like the loop subshell does.
ITER_INJECTION_FILE="$SANDBOX/iter-injection-marker.txt"
rm -f "$ITER_INJECTION_FILE"

# Reset pending so the prior test's metadata writes don't influence this one.
echo '{"status": "pass", "issues": []}' > "$PENDING"

_MIM_PENDING="$PENDING" \
_MIM_RUN_ID="ok" \
_MIM_ITERATION="1; open('${ITER_INJECTION_FILE}','w').close()" \
_MIM_SPEC_HASH="abc" \
_MIM_DURATION="42" \
python3 -c '
import json, os, sys
pending = os.environ["_MIM_PENDING"]
with open(pending) as f:
    data = json.load(f)
if not isinstance(data, dict) or "status" not in data:
    sys.exit(0)
data.setdefault("metadata", {})
data["metadata"]["run_id"] = os.environ["_MIM_RUN_ID"]
data["metadata"]["iteration"] = int(os.environ["_MIM_ITERATION"])
data["metadata"]["spec_hash"] = os.environ["_MIM_SPEC_HASH"]
data["metadata"]["review_duration_ms"] = int(os.environ["_MIM_DURATION"])
with open(pending, "w") as f:
    json.dump(data, f, indent=2)
' >/dev/null 2>&1 || true
assert_true "metadata-injection: non-numeric ITERATION did not execute" \
  "$([[ ! -e "$ITER_INJECTION_FILE" ]] && echo true || echo false)"

# ── Summary ───────────────────────────────────────────────────────────
echo ""
echo "── Summary ──────────────────────────────────────────────────"
echo "Total: $TOTAL  Pass: $PASS  Fail: $FAIL"
[[ $FAIL -eq 0 ]]
