#!/usr/bin/env bash
# run-shell-tests.sh — full-glob runner for the tests/test-*.sh gate suite.
#
# Replaces the hand-picked list that previously ran in CI (only ~15 of the
# suites), so a gate regression can no longer slip past because its test was
# never wired in. Local and CI run this SAME script, so "green here" means
# "green there".
#
# Classification per test:
#   PASS  — exit 0 and the last non-empty output line is NOT a `SKIP:` marker.
#   SKIP  — exit 0 and the last non-empty output line matches `^SKIP:`
#           (the repo's established self-skip convention: `echo "SKIP: …"; exit 0`).
#           A mid-test sub-case SKIP print does NOT count — the test still ends
#           on its pass/fail summary line, so only whole-test skips are caught.
#   FAIL  — any non-zero exit (including 124 = timeout).
#
# Skip-masking guard (fail-closed ALLOWLIST): only the tests in SKIP_ALLOWED
# below may report SKIP. ANY other test that skips — a gate/security suite, or a
# test that started self-skipping because a CI dependency went missing — fails
# the job as a coverage regression. An allowlist (not a denylist of "protected"
# suites) is the fail-closed choice: coverage can only be dropped by a conscious
# edit here, which is exactly the "gate suites always PASS, never SKIP" invariant
# the plan requires, extended to every non-allowlisted suite.
#
# Exit 0 iff every discovered test PASSed or (permissibly) SKIPped; exit 1 on
# any FAIL or skip-masking violation.
#
# Env:
#   SHELL_TEST_TIMEOUT   per-test timeout in seconds (default 120)
set -uo pipefail   # NOT -e: each test's exit is handled explicitly below.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

# Portable per-test timeout (timeout → gtimeout → perl alarm). Reuse the repo
# helper so macOS/BSD (no GNU `timeout`) and Linux CI behave identically.
# resolve-cli.sh only runs top-level code under a `--json` direct-exec guard, so
# sourcing it is side-effect-free.
# shellcheck source=scripts/lib/resolve-cli.sh
# shellcheck disable=SC1091  # sourced at runtime; path is not statically followable without -x
source "$REPO_ROOT/scripts/lib/resolve-cli.sh"

PER_TEST_TIMEOUT="${SHELL_TEST_TIMEOUT:-120}"

# The ONLY tests permitted to SKIP. Everything else — every gate/security suite
# included — must run to completion; an unexpected SKIP fails the job (see the
# skip-masking guard above). Keep this list minimal and justify each entry.
SKIP_ALLOWED=(
  # Real-claude round-trip, gated behind BLUEPRINT_ARBITER_LIVE_TEST=1 — correct
  # to skip in headless CI. See docs/ci/shell-test-inventory.md.
  test-gateway-arbiter-claude-json-residual
)

is_skip_allowed() {
  local base="$1" n
  for n in "${SKIP_ALLOWED[@]}"; do
    [[ "$n" == "$base" ]] && return 0
  done
  return 1
}

pass=0 skip=0 fail=0
failed_names=()
skipped_names=()

# Capture each test's output to a regular file, NOT a `$(…)` pipe. A timed-out
# test may leave a descendant that survives the TERM (the portable-timeout
# helpers signal only the direct child); a surviving descendant holding a
# command-substitution pipe's write end would block us past the timeout. A file
# redirect has no such back-pressure — we read the file after the helper returns.
out_file="$(mktemp)"
trap 'rm -f "$out_file"' EXIT

shopt -s nullglob
tests=(tests/test-*.sh)
if [[ "${#tests[@]}" -eq 0 ]]; then
  echo "ERROR: no tests matched tests/test-*.sh" >&2
  exit 1
fi

echo "Discovered ${#tests[@]} shell tests (per-test timeout ${PER_TEST_TIMEOUT}s)"
echo

for t in "${tests[@]}"; do
  base="$(basename "$t" .sh)"
  _portable_timeout "$PER_TEST_TIMEOUT" bash "$t" >"$out_file" 2>&1
  rc=$?
  last="$(grep -vE '^[[:space:]]*$' "$out_file" | tail -n1)"

  if [[ "$rc" -eq 0 ]] && printf '%s' "$last" | grep -q '^SKIP:'; then
    if is_skip_allowed "$base"; then
      echo "SKIP: $base — ${last#SKIP:}"
      skip=$((skip + 1))
      skipped_names+=("$base")
    else
      echo "FAIL (unexpected skip — coverage regression): $base → $last"
      echo "    (if this skip is intentional, add $base to SKIP_ALLOWED with a reason)"
      fail=$((fail + 1))
      failed_names+=("$base")
    fi
  elif [[ "$rc" -eq 0 ]]; then
    echo "PASS: $base"
    pass=$((pass + 1))
  else
    if [[ "$rc" -eq 124 ]]; then
      echo "FAIL (timeout ${PER_TEST_TIMEOUT}s): $base"
    else
      echo "FAIL (rc=$rc): $base"
    fi
    # Surface explicit failure/error lines first — for a suite with many
    # assertions the failing ones are often earlier than the tail, so a bare
    # `tail` hides them (esp. for CI-only failures). Then show the tail for context.
    grep -nE 'FAIL|Error|error:|not found|expected=' "$out_file" | head -n 30 | sed 's/^/    ! /'
    tail -n 20 "$out_file" | sed 's/^/    | /'
    fail=$((fail + 1))
    failed_names+=("$base")
  fi
done

echo
echo "──────────────────────────────────────────"
echo "discovered=${#tests[@]}  pass=$pass  skip=$skip  fail=$fail"
[[ "$skip" -gt 0 ]] && printf 'skipped: %s\n' "${skipped_names[*]}"
if [[ "$fail" -gt 0 ]]; then
  printf 'FAILED: %s\n' "${failed_names[*]}"
  exit 1
fi
echo "OK: all discovered shell tests passed (or permissibly skipped)."
exit 0
