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
# precondition (unprobed pi version, underivable provider, no projectable
# credential) is not a CLI that ran and failed. Merging the two as `error` let
# one ineligible voice fail an entire `--cli all` batch for every other voice.
#
# WHY THE RUNTIME CASES ARE DRIVEN THROUGH pi: `_pi_setup_fail` is the only site
# that sets the setup-failure flag today, so pi is the only voice that can
# currently produce a `skipped`. The forcing mechanism is `--model` with no
# `provider/` prefix, which fails provider derivation BEFORE any network call —
# deterministic, offline, and independent of which pi (if any) is installed:
# a missing pi fails earlier on binary-not-found, through the same helper, to
# the same status. The other voices are PATH stubs, the pattern already used by
# tests/test-cli-retry.sh Part C.
#
# EVERY dispatch below passes `--model noproviderprefix`, including the cases
# that are only about exit codes. Without it a host with a working pi resolves
# the REAL configured model, projects a REAL credential and makes a REAL billed
# LLM call — a test suite must not spend quota or depend on the network.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
DISPATCH="skills/dispatch-cli/scripts/dispatch.sh"

# Run the script under the bash running THIS test, captured before BASE_PATH
# narrows anything. BASE_PATH exists to hide other CLIs from `--cli all`
# selection; letting it choose the interpreter too selected macOS's /bin/bash
# (3.2), where the pi arm dies at here-document expansion and the script exits
# 0 — issue #595, a pre-existing defect unrelated to what this file tests.
RUN_BASH="$BASH"

PASS=0; FAIL=0; SKIP=0
ok()   { echo "  ✅ $1"; PASS=$((PASS + 1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  ⏭️  SKIP: $1"; SKIP=$((SKIP + 1)); }

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
# The caller's PATH is deliberately NOT inherited, so agy, droid, grok and
# opencode are genuinely absent from `--cli all` selection. Do not add
# /opt/homebrew/bin back — that re-admits real CLIs and breaks the premise of
# the batch cases. pi is unaffected either way: it resolves from password-db
# home candidates, not PATH.
BASE_PATH="$STUB:/usr/bin:/bin:/usr/sbin:/sbin"

# Is pi selectable for `--cli all`? Mirrors _pi_available's candidate list AND
# its trusted-home lookup (password database via `id -un` + `eval echo ~$u`,
# NOT $HOME) — dispatch.sh deliberately does not trust $HOME because it's
# repo-injectable; matching that here keeps this gate's pass/fail decision
# aligned with what dispatch.sh will actually do when $HOME is remapped.
pi_selectable() {
  /usr/bin/env -i "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    /bin/bash --noprofile --norc <<'CHILD'
    u="$(/usr/bin/id -un)" || exit 1
    case "$u" in ''|*[!A-Za-z0-9._-]*) exit 1 ;; esac
    h="$(eval echo "~$u")" || exit 1
    case "$h" in /*) ;; *) exit 1 ;; esac
    [ -d "$h" ] || exit 1
    for c in "$h/.local/bin/pi" "$h/.pi/bin/pi" /opt/homebrew/bin/pi /usr/local/bin/pi /usr/bin/pi /bin/pi; do
      [ -f "$c" ] && [ -x "$c" ] && exit 0
    done
    exit 1
CHILD
}

echo "── dispatch.sh skipped status (#594) ───────────────────────"

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  skip "running under bash ${BASH_VERSINFO[0]} — dispatch.sh's pi arm is broken below bash 4 (#595); runtime cases need bash >= 4"
else

# ── 1. Single-CLI: an explicitly requested voice that cannot run is a FAILURE.
#      The whole request was for that voice; there is nothing left to succeed.
O="$TMP/single.out"
PATH="$BASE_PATH" "$RUN_BASH" "$DISPATCH" --cli pi --model noproviderprefix --prompt p >"$O" 2>&1
rc=$?
{ [[ "$rc" -ne 0 ]] && grep -q "pi → skipped" "$O"; } \
  && ok "explicit --cli pi that cannot run → status skipped, exit nonzero" \
  || bad "explicit --cli pi → skipped + nonzero (rc=$rc, out=[$(tr -d '\n' <"$O" | tail -c 200)])"

# ── 2. Batch: one skipped voice must NOT fail the batch for the others.
#      This is the reported bug (#594).
if pi_selectable; then
  mk_codex_ok
  O="$TMP/batch-ok.out"
  PATH="$BASE_PATH" BUSDRIVER_CLI_RETRIES=0 BUSDRIVER_CLI_RETRY_DELAY=0 \
    "$RUN_BASH" "$DISPATCH" --cli all --model noproviderprefix --timeout 20 --prompt p >"$O" 2>&1
  rc=$?
  { [[ "$rc" -eq 0 ]] && grep -q CODEX_OK "$O" && grep -qi "PI  *(skipped" "$O"; } \
    && ok "--cli all: skipped pi does not fail a batch another voice completed" \
    || bad "--cli all: skipped pi failed the batch (rc=$rc, out=[$(tr -d '\n' <"$O" | tail -c 300)])"

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
  #      must never report success. No codex stub → pi is the only candidate.
  rm -f "$STUB/codex"
  O="$TMP/batch-allskip.out"
  PATH="$BASE_PATH" BUSDRIVER_CLI_RETRIES=0 BUSDRIVER_CLI_RETRY_DELAY=0 \
    "$RUN_BASH" "$DISPATCH" --cli all --model noproviderprefix --timeout 20 --prompt p >"$O" 2>&1
  rc=$?
  { [[ "$rc" -ne 0 ]] && grep -q "every CLI in the batch was skipped" "$O"; } \
    && ok "--cli all: an all-skipped batch fails (nothing ran ≠ success)" \
    || bad "--cli all: all-skipped batch reported success (rc=$rc, out=[$(tr -d '\n' <"$O" | tail -c 300)])"
else
  skip "pi is not installed on a trusted path — batch cases 2–4 need a selectable pi"
fi

# ── 5. A fully successful batch must exit 0. Regression guard: the branch's
#      last statement used to be `[[ "$any_failed" == "true" ]] && exit 1`, so a
#      clean run fell off the end of the script carrying that test's own status
#      and reported failure. On a pi-ful host this repeats case 2's shape; on a
#      pi-less host (Linux CI) codex is the only voice and this is the pure
#      clean-batch guard.
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

fi  # bash >= 4

# ── 7. Static: `skipped` is assigned LAST in the status ladder. Ordering is
#      load-bearing — a setup failure also carries exit_code=1, so an earlier
#      assignment would be overwritten by `error` and the whole fix would be
#      inert while every runtime case above still passed on a pi-less host.
LADDER="$(grep -n 'status="' "$DISPATCH" | grep -E 'status="(success|timeout|error|droid-fallback|skipped)"')"
[[ "$(echo "$LADDER" | tail -1)" == *'status="skipped"'* ]] \
  && ok "skipped is the final status assignment (wins over error/timeout)" \
  || bad "skipped is no longer assigned last — the error classification overwrites it"

# ── 8. Static: `skipped` is conditional on the credential jail being CONFIRMED
#      GONE. `_pi_wipe` clears `_pi_jail` only after verifying the path is
#      absent, so a surviving name means a projected credential may still be on
#      disk — and since the batch loop treats `skipped` as "not a failure", that
#      case must stay `error` or a leaked key rides out on another voice's
#      success. Static because forcing a wipe failure needs an unlink that fails,
#      which no portable test can arrange without running as another user.
grep -q '\[\[ "${_pi_setup_failed:-0}" == "1" && "${_pi_jail_survived:-0}" != "1" \]\] && status="skipped"' "$DISPATCH" \
  && ok "skipped is refused when a teardown left the credential jail behind" \
  || bad "skipped is no longer gated on _pi_jail_survived — a failed credential wipe would stop failing the batch"
# ...and the flag must actually be SET where the teardown can fail, or the guard
# above is decorative: it would read a variable nothing ever assigns.
grep -q '\[\[ -z "${_pi_jail:-}" \]\] || _pi_jail_survived=1' "$DISPATCH" \
  && ok "_pi_jail_survived is set after the projection-failure teardown" \
  || bad "nothing sets _pi_jail_survived — the leaked-credential guard cannot fire"

# ── 9. Static: the batch failure test must not count `skipped`. Guards against
#      a well-meaning "handle every status" edit re-merging the two.
grep -q '\[\[ "\$STATUS" == "error" || "\$STATUS" == "timeout" \]\] && any_failed=true' "$DISPATCH" \
  && ok "batch failure test still keys on error/timeout only" \
  || bad "batch failure test changed shape — verify skipped is still excluded"

echo ""
echo "── $PASS passed, $FAIL failed, $SKIP skipped ───────────────"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
