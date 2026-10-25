#!/usr/bin/env bash
# shellcheck disable=SC2310,SC2312  # assertions intentionally use command substitution
# shellcheck disable=SC2015  # `ok` always returns 0, so A && ok || bad is a real if-then-else here
# shellcheck disable=SC2016  # the static assertions grep for LITERAL source text; expansion is exactly what must not happen
# tests/test-dispatch-skipped-status.sh
#
# Covers the `skipped` dispatch status (#594) and the batch exit contract it
# rides on, in skills/dispatch-cli/scripts/dispatch.sh.
#
# The premise being tested: a CLI that refuses to run on a DETERMINISTIC
# precondition is not a CLI that ran and failed. Merging the two as `error` let
# one ineligible voice fail an entire `--cli all` batch for every other voice.
#
# WHY THE RUNTIME CASES ARE DRIVEN THROUGH grok: grok rejects `--model`
# (grok-build accepts none) and records that as a refusal BEFORE any launch,
# preflight or network call — deterministic and offline on every host, with or
# without grok installed (a missing grok is refused by its preflight, to the same
# status). grok also joins every readonly `--cli all` batch without a PATH probe,
# so the batch cases need no host-specific gate. The other voices are PATH stubs,
# the pattern already used by tests/test-cli-retry.sh Part C.
#
# Every `--cli grok` / `--cli all` dispatch below passes `--model noproviderprefix`:
# it is the forcing mechanism for grok, and the stubs ignore it. (`--cli both`,
# case 6, has no grok voice and needs none.)

set -uo pipefail
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
DISPATCH="skills/dispatch-cli/scripts/dispatch.sh"

# Run the script under its shebang's interpreter (macOS /bin/bash is 3.2), so the
# runtime cases cover the bash that actually ships rather than the test's own.
RUN_BASH=/bin/bash

PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS + 1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# Validate BEFORE arming the trap or deriving any path from it. An unchecked
# `TMP="$(mktemp -d)"` that fails leaves TMP empty, making STUB `/stub` — and the
# run then creates, overwrites and finally `rm -rf`s files at the filesystem
# root. A test must fail safely, not relocate its scratch space to `/`.
TMP="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
case "$TMP" in
  /*) [[ -d "$TMP" ]] || { echo "FATAL: mktemp -d gave a non-directory: $TMP" >&2; exit 1; } ;;
  *)  echo "FATAL: mktemp -d gave a non-absolute path: '$TMP'" >&2; exit 1 ;;
esac
trap 'rm -rf "$TMP"' EXIT
STUB="$TMP/stub"; mkdir -p "$STUB"

# A codex stub that succeeds, and one that fails. dispatch_one's codex arm
# passes flags the stub ignores; all that matters is stdout + exit status.
mk_codex_ok()   { printf '#!/usr/bin/env bash\necho CODEX_OK\n'               > "$STUB/codex"; chmod +x "$STUB/codex"; }
mk_codex_fail() { printf '#!/usr/bin/env bash\necho "hard failure"\nexit 3\n' > "$STUB/codex"; chmod +x "$STUB/codex"; }

# PATH holding the stubs plus the dirs dispatch.sh needs for coreutils/perl.
# The caller's PATH is deliberately NOT inherited, so agy and grok
# are genuinely absent from `--cli all` selection. Do not add
# /opt/homebrew/bin back — that re-admits real CLIs and breaks the premise of
# the batch cases. grok is unaffected either way: it runs from a pinned path.
BASE_PATH="$STUB:/usr/bin:/bin:/usr/sbin:/sbin"

echo "── dispatch.sh skipped status (#594) ───────────────────────"

# ── 1. Single-CLI: an explicitly requested voice that cannot run is a FAILURE.
#      The whole request was for that voice; there is nothing left to succeed.
O="$TMP/single.out"
PATH="$BASE_PATH" "$RUN_BASH" "$DISPATCH" --cli grok --model noproviderprefix --prompt p >"$O" 2>&1
rc=$?
{ [[ "$rc" -ne 0 ]] && grep -q "grok → skipped" "$O"; } \
  && ok "explicit --cli grok that cannot run → status skipped, exit nonzero" \
  || bad "explicit --cli grok → skipped + nonzero (rc=$rc, out=[$(tr -d '\n' <"$O" | tail -c 200)])"

# ── 2. Batch: one skipped voice must NOT fail the batch for the others.
#      This is the reported bug (#594).
mk_codex_ok
O="$TMP/batch-ok.out"
PATH="$BASE_PATH" BUSDRIVER_CLI_RETRIES=0 BUSDRIVER_CLI_RETRY_DELAY=0 \
  "$RUN_BASH" "$DISPATCH" --cli all --model noproviderprefix --timeout 20 --prompt p >"$O" 2>&1
rc=$?
{ [[ "$rc" -eq 0 ]] && grep -q CODEX_OK "$O" && grep -qi "GROK  *(skipped" "$O"; } \
  && ok "--cli all: skipped grok does not fail a batch another voice completed" \
  || bad "--cli all: skipped grok failed the batch (rc=$rc, out=[$(tr -d '\n' <"$O" | tail -c 300)])"

# ── 3. ...but `skipped` must not MASK a real failure either. Same batch
#      shape, codex now failing hard → the batch still reports failure.
mk_codex_fail
O="$TMP/batch-fail.out"
PATH="$BASE_PATH" BUSDRIVER_CLI_RETRIES=0 BUSDRIVER_CLI_RETRY_DELAY=0 \
  "$RUN_BASH" "$DISPATCH" --cli all --model noproviderprefix --timeout 20 --prompt p >"$O" 2>&1
rc=$?
[[ "$rc" -ne 0 ]] \
  && ok "--cli all: a genuinely failing voice still fails the batch" \
  || bad "--cli all: real failure was masked (rc=$rc)"

# ── 4. A batch in which EVERY voice was skipped ran nothing, and nothing
#      must never report success. No codex stub → grok is the only candidate.
rm -f "$STUB/codex"
O="$TMP/batch-allskip.out"
PATH="$BASE_PATH" BUSDRIVER_CLI_RETRIES=0 BUSDRIVER_CLI_RETRY_DELAY=0 \
  "$RUN_BASH" "$DISPATCH" --cli all --model noproviderprefix --timeout 20 --prompt p >"$O" 2>&1
rc=$?
{ [[ "$rc" -ne 0 ]] && grep -q "every CLI in the batch was skipped" "$O"; } \
  && ok "--cli all: an all-skipped batch fails (nothing ran ≠ success)" \
  || bad "--cli all: all-skipped batch reported success (rc=$rc, out=[$(tr -d '\n' <"$O" | tail -c 300)])"

# ── 5. A fully successful batch must exit 0. Regression guard: the branch's
#      last statement used to be `[[ "$any_failed" == "true" ]] && exit 1`, so a
#      clean run fell off the end of the script carrying that test's own status
#      and reported failure. grok is skipped (it rejects --model), so codex is
#      the one voice that runs: the pure clean-batch guard.
mk_codex_ok
O="$TMP/batch-clean.out"
PATH="$BASE_PATH" BUSDRIVER_CLI_RETRIES=0 BUSDRIVER_CLI_RETRY_DELAY=0 \
  "$RUN_BASH" "$DISPATCH" --cli all --model noproviderprefix --timeout 20 --prompt p >"$O" 2>&1
rc=$?
{ [[ "$rc" -eq 0 ]] && grep -q CODEX_OK "$O"; } \
  && ok "--cli all: a fully successful batch exits 0" \
  || bad "--cli all: successful batch did not exit 0 (rc=$rc, out=[$(tr -d '\n' <"$O" | tail -c 300)])"

# ── 6. Same regression for --cli both, whose branch ended the same way.
printf '#!/usr/bin/env bash\necho AGY_OK\n' > "$STUB/agy"; chmod +x "$STUB/agy"
O="$TMP/both-clean.out"
PATH="$BASE_PATH" BUSDRIVER_CLI_RETRIES=0 BUSDRIVER_CLI_RETRY_DELAY=0 \
  "$RUN_BASH" "$DISPATCH" --cli both --timeout 20 --prompt p >"$O" 2>&1
rc=$?
{ [[ "$rc" -eq 0 ]] && grep -q CODEX_OK "$O" && grep -q AGY_OK "$O"; } \
  && ok "--cli both: a fully successful pair exits 0" \
  || bad "--cli both: successful pair did not exit 0 (rc=$rc, out=[$(tr -d '\n' <"$O" | tail -c 300)])"

# ── 7. Static: `skipped` is assigned LAST in the status ladder. Ordering is
#      load-bearing — a setup failure also carries exit_code=1, so an earlier
#      assignment would be overwritten by `error` and the whole fix would be
#      inert while every runtime case above still passed.
LADDER="$(grep -n 'status="' "$DISPATCH" | grep -E 'status="(success|timeout|error|skipped)"')"
[[ "$(echo "$LADDER" | tail -1)" == *'status="skipped"'* ]] \
  && ok "skipped is the final status assignment (wins over error/timeout)" \
  || bad "skipped is no longer assigned last — the error classification overwrites it"

# ── 7b. Static: grok's refusal is what assigns `skipped`. Since ADR 0060 it is
#      the only producer, so losing this line would leave `skipped` unreachable
#      while case 7 (which only checks ordering) still passed.
grep -q '\[\[ "${_grok_refused:-0}" == "1" \]\] && status="skipped"' "$DISPATCH" \
  && ok "the grok refusal assigns skipped" \
  || bad "nothing assigns skipped from the grok refusal — the batch contract has no producer"

# ── 8. Static: the batch failure test must not count `skipped`. Guards against
#      a well-meaning "handle every status" edit re-merging the two.
grep -q '\[\[ "\$STATUS" == "error" || "\$STATUS" == "timeout" \]\] && any_failed=true' "$DISPATCH" \
  && ok "batch failure test still keys on error/timeout only" \
  || bad "batch failure test changed shape — verify skipped is still excluded"

echo ""
echo "── $PASS passed, $FAIL failed ───────────────"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
