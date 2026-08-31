#!/usr/bin/env bash
# tests/test-droid-escalation-outcome.sh
#
# #804: empty droid escalation inside budget must not be logged as timeout 124.
# Covers:
#   (i)  classifier table for _classify_droid_escalation_outcome
#   (ii) stubbed _execute_codex path: Codex sleeps past budget (timed_out=1),
#        droid exits 0 with empty stdout → rc 3 (BUILTIN_FALLBACK), not 124
#
# Usage: bash tests/test-droid-escalation-outcome.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/resolve-cli.sh"

passed=0
failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

if [[ ! -f "$LIB" ]]; then
  echo "FAIL: resolve-cli.sh not found at $LIB"
  exit 1
fi

# LIB is resolved at runtime from this checkout.
# shellcheck disable=SC1090,SC1091
source "$LIB"

# ── (i) classifier table ────────────────────────────────────────────────────
assert_outcome() {
  local exit_code="$1" out="$2" want="$3" label="$4"
  local got
  got=$(_classify_droid_escalation_outcome "$exit_code" "$out")
  if [[ "$got" == "$want" ]]; then
    ok "classifier: $label → $want"
  else
    fail "classifier: $label → expected $want, got $got"
  fi
}

assert_outcome 0   "review ok" ok        "exit0+output"
assert_outcome 124 ""          timeout   "exit124+empty"
assert_outcome 124 "partial"   timeout   "exit124+partial"
assert_outcome 0   ""          no-output "exit0+empty"
assert_outcome 1   ""          no-output "exit1+empty"
assert_outcome 1   "boom"      failed    "exit1+output"

# ── (ii) stubbed escalation path ────────────────────────────────────────────
# Codex sleeps past the budget so _portable_timeout returns 124 and timed_out=1.
# Droid exits instantly with empty stdout — before the fix this still returned
# 124 because the post-escalation `if timed_out==1` fired. After the fix it
# must clear timed_out and fall through to BUILTIN_FALLBACK (rc 3).

if ! command -v timeout >/dev/null 2>&1 \
   && ! command -v gtimeout >/dev/null 2>&1 \
   && ! command -v perl >/dev/null 2>&1; then
  echo "SKIP path proof: no timeout/gtimeout/perl — classifier table still ran"
  echo
  echo "Results: $passed passed, $failed failed"
  [[ "$failed" -eq 0 ]]
  exit 0
fi

STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

# Isolate telemetry: resolve-cli writes under $_git_root/$BUSDRIVER_STATE_DIR.
# Point at a name that does NOT exist under the checkout so synthetic escalations
# never append to the live .claude/bypass-log.jsonl.
ISO_STATE=".busdriver-test-state-absent-804"
[[ ! -e "$SCRIPT_DIR/$ISO_STATE" ]] || { echo "FAIL: isolation dir unexpectedly exists"; exit 1; }

# Codex stub: sleep past any reasonable small budget.
cat > "$STUB_DIR/codex" <<'EOF'
#!/bin/sh
sleep 20
echo should-not-appear
EOF
chmod +x "$STUB_DIR/codex"

# Droid stub: instant empty success (silent refusal).
cat > "$STUB_DIR/droid" <<'EOF'
#!/bin/sh
# named "droid" but execute_review / escalation invokes `droid exec`
# Accept any argv; produce zero bytes and exit 0.
exit 0
EOF
chmod +x "$STUB_DIR/droid"

# Shared runner: pass paths via env (not interpolated into the -c string) so a
# checkout path containing a quote cannot break the snippet.
run_execute_codex() {
  local rc=0 out
  out=$(
    env -i HOME="$HOME" PATH="$STUB_DIR:/opt/homebrew/bin:/usr/bin:/bin" \
      LITMUS_CODEX_RETRIES=0 LITMUS_CODEX_RETRY_DELAY=0 \
      BUSDRIVER_STATE_DIR="$ISO_STATE" \
      SCRIPT_DIR="$SCRIPT_DIR" LIB="$LIB" BUDGET="$BUDGET" \
      # Env-passed SCRIPT_DIR/LIB/BUDGET must expand in the child, not here.
      # shellcheck disable=SC2016
      bash -c '
        cd "$SCRIPT_DIR" || exit 97
        # shellcheck disable=SC1091
        source "$LIB" >/dev/null 2>&1
        _CODEX_COMPANION=none
        is_cli_available() { [[ "$1" == droid ]]; }
        _execute_codex "p" "$BUDGET"
      ' 2>/dev/null
  ) || rc=$?
  printf '%s\n' "$out"
  return "$rc"
}

BUDGET=3
set +e
out=$(run_execute_codex)
rc=$?
set -e

if [[ "$rc" -eq 3 && "$out" == "BUILTIN_FALLBACK" ]]; then
  ok "_execute_codex: codex timeout + droid empty → rc 3 BUILTIN_FALLBACK (not 124)"
else
  fail "_execute_codex: expected rc 3 BUILTIN_FALLBACK, got rc=$rc out=$(printf '%q' "$out")"
fi

# Spent-budget droid 124 must still preserve timeout.
cat > "$STUB_DIR/droid" <<'EOF'
#!/bin/sh
sleep 20
EOF
chmod +x "$STUB_DIR/droid"

set +e
out2=$(run_execute_codex)
rc2=$?
set -e

if [[ "$rc2" -eq 124 ]]; then
  ok "_execute_codex: codex timeout + droid spent-budget 124 → rc 124 preserved"
else
  fail "_execute_codex: expected rc 124 for spent-budget droid, got rc=$rc2 out=$(printf '%q' "$out2")"
fi

# Codex fails fast with a transient error (not timed_out); droid then spends
# the budget. Outcome timeout must SET timed_out so callers still see rc 124.
cat > "$STUB_DIR/codex" <<'EOF'
#!/bin/sh
echo "429 rate limit exceeded" >&2
exit 1
EOF
chmod +x "$STUB_DIR/codex"
cat > "$STUB_DIR/droid" <<'EOF'
#!/bin/sh
sleep 20
EOF
chmod +x "$STUB_DIR/droid"

set +e
out3=$(run_execute_codex)
rc3=$?
set -e

if [[ "$rc3" -eq 124 ]]; then
  ok "_execute_codex: codex transient + droid spent-budget 124 → rc 124 (propagated)"
else
  fail "_execute_codex: expected rc 124 for transient-codex + droid-timeout, got rc=$rc3 out=$(printf '%q' "$out3")"
fi

# Prove the isolation path was not created (no live telemetry pollution).
if [[ -e "$SCRIPT_DIR/$ISO_STATE" ]]; then
  fail "isolation dir was created — telemetry may have leaked into the checkout"
else
  ok "BUSDRIVER_STATE_DIR isolation kept telemetry out of the live checkout"
fi

echo
echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
