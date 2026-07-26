#!/usr/bin/env bash
# tests/test-codex-retry-budget.sh
#
# Enforces the RETRY BUDGET INVARIANT for the review retry engines in
# scripts/lib/resolve-cli.sh:
#
#   The WHOLE retry sequence — every attempt PLUS every backoff sleep —
#   must finish within the caller's "$duration" budget.
#
# WHY THIS IS A TEST, NOT PROSE: `_execute_codex` violated this for months while
# the violation was *accurately documented* in skills/litmus/SKILL.md — every
# attempt got the FULL duration, so the PR path (5 retries x 540s) could spend
# ~6x its timeout against a 600s harness Bash cap. Prose describing a bound is
# not a bound. Neither is a bound nobody executes: the fix is ~10 lines of
# arithmetic that a future caller can silently reintroduce by passing "$duration"
# where "$remaining" belongs, and nothing else in the suite would notice.
#
# Both directions are asserted per engine, because an upper bound alone is
# trivially satisfiable by a function that fails instantly:
#   (i)  BOUNDED  — a forced retry storm stays inside the budget
#   (ii) LIVE     — a run that would SUCCEED still gets its full attempt window
#                   (i.e. the bound did not simply strangle the reviewer)
#
# The stub CLI is a plain shell script on PATH, so no network, no real codex,
# and no framework. Total runtime ~20s.

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

# _portable_timeout falls back to perl when timeout/gtimeout are absent; without
# any of them the budget cannot be enforced at all and this test is meaningless.
if ! command -v timeout >/dev/null 2>&1 \
   && ! command -v gtimeout >/dev/null 2>&1 \
   && ! command -v perl >/dev/null 2>&1; then
  echo "SKIP: no timeout/gtimeout/perl available — cannot enforce a wall-clock budget"
  exit 0
fi

STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
CALLS="$STUB_DIR/calls"

# Every stub invocation appends a line, so the tests can assert HOW MANY attempts
# ran — an elapsed-time bound alone is satisfiable by an engine that gave up
# after one try, which would "pass" while silently deleting the retry behaviour.
reset_calls() { : > "$CALLS"; }
call_count()  { wc -l < "$CALLS" | tr -d ' '; }

# Stub A — burns time, then exits 0 with EMPTY output. Empty is never a valid
# review, so every engine treats it as a flake and retries: a forced retry storm.
write_stub_empty() {
  printf '#!/bin/sh\necho x >> "%s"\nsleep %s\nexit 0\n' "$CALLS" "$1" > "$STUB_DIR/codex"
  chmod +x "$STUB_DIR/codex"
}

# Stub B — burns time, then returns a real review payload: the success path.
write_stub_ok() {
  printf '#!/bin/sh\necho x >> "%s"\nsleep %s\necho "{\\"status\\":\\"PASS\\",\\"issues\\":[]}"\n' "$CALLS" "$1" > "$STUB_DIR/codex"
  chmod +x "$STUB_DIR/codex"
}

# Run a snippet against the lib in a scrubbed env.
#
# `_CODEX_COMPANION=none` pins _execute_codex to the direct-CLI arm so it hits
# our stub `codex`. Do NOT rely on node being absent from PATH instead: node
# lives in /usr/bin on many Linux images, so a PATH-based assumption would
# silently route the test through the companion arm (and could invoke a REAL
# companion). _resolve_codex_companion returns early when the var is already
# set, so this is a supported override rather than a monkey-patch.
# Echoes: "<rc> <elapsed_seconds>"
run_timed() {
  local snippet="$1"; shift
  local start end rc=0
  start=$(date +%s)
  env -i HOME="$HOME" PATH="$STUB_DIR:/usr/bin:/bin" "$@" \
    bash -c "cd '$SCRIPT_DIR'; source '$LIB' >/dev/null 2>&1; _CODEX_COMPANION=none; $snippet" >/dev/null 2>&1 || rc=$?
  end=$(date +%s)
  echo "$rc $((end - start))"
}

BUDGET=8
SLACK=4   # process startup + coarse 1s clock granularity

# ── Engine 1: _execute_codex ────────────────────────────────────────────────
# (i) BOUNDED. Unfixed this runs ~110s: 6 attempts x 8s + sleeps 2+4+8+16+32.
write_stub_empty 3
reset_calls
result=$(run_timed '_execute_codex "p" '"$BUDGET" \
  LITMUS_CODEX_RETRIES=5 LITMUS_CODEX_RETRY_DELAY=2 LITMUS_CODEX_DROID_FALLBACK_DISABLED=1)
read -r _rc elapsed <<<"$result"
attempts=$(call_count)
if [[ "$elapsed" -le $((BUDGET + SLACK)) ]]; then
  ok "_execute_codex: retry storm stayed in budget (${elapsed}s <= ${BUDGET}s+${SLACK}s)"
else
  fail "_execute_codex: retry sequence overran its budget (${elapsed}s > ${BUDGET}s+${SLACK}s) — every attempt is getting the full duration instead of the remaining budget"
fi
# The bound must not have been achieved by abandoning retries altogether.
if [[ "$attempts" -ge 2 ]]; then
  ok "_execute_codex: retries still fire inside the bound (${attempts} attempts)"
else
  fail "_execute_codex: only ${attempts} attempt(s) — the budget bound must not disable retrying"
fi

# (ii) LIVE. A run that succeeds inside the budget must still be allowed to.
write_stub_ok 5
# shellcheck disable=SC2016  # $out is deliberately literal — it is expanded by the child shell
result=$(run_timed 'out=$(_execute_codex "p" '"$BUDGET"'); [ -n "$out" ]' \
  LITMUS_CODEX_RETRIES=5 LITMUS_CODEX_RETRY_DELAY=2 LITMUS_CODEX_DROID_FALLBACK_DISABLED=1)
read -r rc elapsed <<<"$result"
if [[ "$rc" -eq 0 && "$elapsed" -ge 4 && "$elapsed" -le $((BUDGET + SLACK)) ]]; then
  ok "_execute_codex: successful attempt kept its full window (rc=0, ${elapsed}s)"
else
  fail "_execute_codex: success path broken by the bound (rc=$rc, ${elapsed}s) — a first attempt must get the FULL duration, not a truncated remainder"
fi

# ── Engine 2: _run_review_with_retries ──────────────────────────────────────
# Already compliant; asserted so it stays that way.
write_stub_empty 3
reset_calls
result=$(run_timed '_run_review_with_retries stub "p" '"$BUDGET"' pipe codex' \
  BUSDRIVER_CLI_RETRIES=5 BUSDRIVER_CLI_RETRY_DELAY=2)
read -r _rc elapsed <<<"$result"
attempts=$(call_count)
if [[ "$elapsed" -le $((BUDGET + SLACK)) ]]; then
  ok "_run_review_with_retries: retry storm stayed in budget (${elapsed}s <= ${BUDGET}s+${SLACK}s)"
else
  fail "_run_review_with_retries: retry sequence overran its budget (${elapsed}s > ${BUDGET}s+${SLACK}s)"
fi
if [[ "$attempts" -ge 2 ]]; then
  ok "_run_review_with_retries: retries still fire inside the bound (${attempts} attempts)"
else
  fail "_run_review_with_retries: only ${attempts} attempt(s) — the budget bound must not disable retrying"
fi

write_stub_ok 5
# shellcheck disable=SC2016  # $out is deliberately literal — it is expanded by the child shell
result=$(run_timed 'out=$(_run_review_with_retries stub "p" '"$BUDGET"' pipe codex); [ -n "$out" ]' \
  BUSDRIVER_CLI_RETRIES=5 BUSDRIVER_CLI_RETRY_DELAY=2)
read -r rc elapsed <<<"$result"
if [[ "$rc" -eq 0 && "$elapsed" -ge 4 && "$elapsed" -le $((BUDGET + SLACK)) ]]; then
  ok "_run_review_with_retries: successful attempt kept its full window (rc=0, ${elapsed}s)"
else
  fail "_run_review_with_retries: success path broken by the bound (rc=$rc, ${elapsed}s)"
fi

echo
echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
