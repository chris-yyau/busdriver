#!/usr/bin/env bash
# Tests for runtime droid fallback.
#   Part A: should_escalate_to_droid() predicate (resolve-cli.sh)
#   Part B: dispatch.sh per-voice droid fallback (PATH-stubbed CLIs)
#   Part C: blueprint-review's SEPARATE droid rescue (_bp_droid_rescue)
#
# Usage: bash tests/test-droid-escalation.sh
# Exit: 0 if all pass, 1 if any fail.

# SC2015: `cmd && ok || bad` is intentional — ok()/bad() always return 0, so the
#         || branch only runs when cmd fails. SC2329: the is_cli_available()
#         overrides are invoked indirectly by should_escalate_to_droid().
# shellcheck disable=SC2015,SC2329
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0; TOTAL=0
ok()  { printf "  PASS  %s\n" "$1"; PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); }
bad() { printf "  FAIL  %s\n" "$1"; FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); }

# shellcheck disable=SC1091
source scripts/lib/resolve-cli.sh

TMP=$(mktemp -d) || { echo "mktemp -d failed"; exit 1; }
[[ -n "$TMP" && -d "$TMP" ]] || { echo "mktemp -d produced no directory"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
NE="$TMP/ne"; printf x > "$NE"; EM="$TMP/em"; : > "$EM"; MI="$TMP/mi"

# ── Part A: should_escalate_to_droid ────────────────────────────────
echo "── should_escalate_to_droid ────────────────────────────────"
is_cli_available() { [[ "$1" == "droid" ]]; }   # droid present
# The escalating vehicle is CODEX, not grok: grok is now excluded by name (see
# below), so using it here would assert the opposite of the rule.
should_escalate_to_droid codex 124 "$NE" && ok "timeout(124) → escalate"      || bad "timeout(124) → escalate"
should_escalate_to_droid codex 1   "$NE" && ok "error(1) → escalate"          || bad "error(1) → escalate"
should_escalate_to_droid agy  0   "$EM" && ok "exit0 + empty → escalate"     || bad "exit0 + empty → escalate"
should_escalate_to_droid agy  0   "$MI" && ok "exit0 + missing → escalate"   || bad "exit0 + missing → escalate"
should_escalate_to_droid agy  0   "$NE" && bad "exit0 + good output → NO"     || ok "exit0 + good output → NO"
should_escalate_to_droid droid 1  "$NE" && bad "primary IS droid → NO"        || ok "primary IS droid → NO"

# grok is a DIFFERENT third party from droid, and its containment can fail at
# RUNTIME after a clean static preflight — the profile may turn out to be
# unappliable, and grok then refuses to start. `_grok_refused` does not cover
# that case (it is set only on the static refusals), so without this exclusion
# the prompt and the repo content quoted in it would be forwarded to droid at
# the exact moment grok's sandbox proved it could not protect them. Every
# failure shape must be refused, not just the ones a message matcher predicts.
# Codex P1, PR #704.
should_escalate_to_droid grok 1   "$NE" && bad "grok error(1) → NO cross-provider fallback"   || ok "grok error(1) → NO cross-provider fallback"
should_escalate_to_droid grok 124 "$NE" && bad "grok timeout(124) → NO cross-provider fallback" || ok "grok timeout(124) → NO cross-provider fallback"
should_escalate_to_droid grok 0   "$EM" && bad "grok exit0+empty → NO cross-provider fallback"  || ok "grok exit0+empty → NO cross-provider fallback"
should_escalate_to_droid grok 0   "$MI" && bad "grok exit0+missing → NO cross-provider fallback" || ok "grok exit0+missing → NO cross-provider fallback"

# The concrete scenario, not just its shape: the static preflight PASSED, grok
# launched, and the kernel profile then could not be applied — grok refuses to
# start and exits non-zero having written its refusal to the output file. This
# is the state in which `_grok_refused` is still 0, so before the name-based
# exclusion the very next step was `droid exec` with the same prompt.
is_cli_available() { [[ "$1" == "droid" ]]; }   # droid present again
RT="$TMP/runtime-sandbox-failure"
printf 'Refusing to start with its protections missing\n' > "$RT"
should_escalate_to_droid grok 1 "$RT" \
  && bad "runtime sandbox failure after a PASSING preflight → NO droid fallback" \
  || ok  "runtime sandbox failure after a PASSING preflight → NO droid fallback"

is_cli_available() { return 1; }                 # droid absent
should_escalate_to_droid codex 124 "$NE" && bad "droid absent → NO"            || ok "droid absent → NO"

# ── Part B: dispatch.sh per-voice fallback (PATH-stubbed) ───────────
echo ""
echo "── dispatch.sh droid fallback ──────────────────────────────"
# The stubbed vehicle is CODEX, not grok. grok used to play this role, but its
# arm now runs a sandbox preflight first, and on any host without an operator
# `~/.grok/sandbox.toml` that preflight REFUSES — so grok never reaches the
# runtime failure this part is about, and three of these cases started failing
# in CI while two others passed vacuously (a refusal has no rescue marker
# either). A test must not depend on whether the machine running it has the
# operator profile installed, and it must not write one into a developer's real
# home to get it. codex's arm is a plain `codex exec` with no preflight, which
# is what makes it the right vehicle for testing the SHARED escalation path.
# grok's own refusal behaviour — which must NOT escalate — is pinned in
# tests/test-grok-sandbox-arm.sh.
STUB="$TMP/bin"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\nexit 124\n' > "$STUB/codex"           # simulate a timeout
printf '#!/usr/bin/env bash\necho DROID_RESCUE\n' > "$STUB/droid"
chmod +x "$STUB/codex" "$STUB/droid"

O="$TMP/d.out"; E="$TMP/d.err"
PATH="$STUB:$PATH" BUSDRIVER_CLI_RETRIES=0 \
  bash skills/dispatch-cli/scripts/dispatch.sh --cli codex --timeout 5 --prompt p >"$O" 2>"$E" || true
grep -q DROID_RESCUE "$O"   && ok "primary failure falls back to droid"   || bad "primary failure falls back to droid"
grep -q "from droid" "$O"   && ok "fallback output carries marker"        || bad "fallback output carries marker"
grep -q droid-fallback "$E" && ok "status reports droid-fallback"         || bad "status reports droid-fallback"

# When droid also fails, the voice drops (no rescue marker, non-zero status).
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/droid"; chmod +x "$STUB/droid"
O2="$TMP/d2.out"
PATH="$STUB:$PATH" BUSDRIVER_CLI_RETRIES=0 \
  bash skills/dispatch-cli/scripts/dispatch.sh --cli codex --timeout 5 --prompt p >"$O2" 2>/dev/null || true
grep -q DROID_RESCUE "$O2" && bad "droid-also-fails → voice drops" || ok "droid-also-fails → voice drops"

# Primary exits 0 but EMPTY output + droid rescue fails → must NOT report success.
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/codex"   # exit 0, no output
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/droid"
chmod +x "$STUB/codex" "$STUB/droid"
PATH="$STUB:$PATH" BUSDRIVER_CLI_RETRIES=0 \
  bash skills/dispatch-cli/scripts/dispatch.sh --cli codex --timeout 5 --prompt p >/dev/null 2>/dev/null
RC=$?
[[ "$RC" -ne 0 ]] && ok "exit0+empty+droid-fail → non-zero exit (not false success)" \
                  || bad "exit0+empty+droid-fail → non-zero exit (not false success)"

# ── Part C: blueprint-review's independent droid rescue ────────────
# blueprint-review does NOT call should_escalate_to_droid. Its post-run loop
# reaches `_bp_droid_rescue` directly, so Part A proves nothing about it and the
# two guards do not subsume each other. Behavioural, not a source grep: the
# function is extracted and run with `execute_review` stubbed to record that it
# was reached, because reaching it IS the leak — that is the call that hands
# `$FULL_PROMPT`, and the repo content quoted inside it, to a different provider.
echo ""
echo "── blueprint _bp_droid_rescue ──────────────────────────────"
BPLOOP="skills/blueprint-review/scripts/run-design-review-loop.sh"
_bp_fn=$(sed -n '/^_bp_droid_rescue()/,/^}/p' "$BPLOOP")
if [[ -z "$_bp_fn" ]]; then
  bad "could not extract _bp_droid_rescue from $BPLOOP (renamed? guard unverified)"
else
  _bp_probe() {  # $1=slot [$2=resolved cli] → records CALLED if the rescue reached execute_review
    local slot="$1" cli="${2:-}"
    (
      set +u
      # SC2034: read by the eval'd _bp_droid_rescue body below, which the
      # linter cannot follow — these are the function's real inputs.
      # shellcheck disable=SC2034
      FULL_PROMPT="design spec plus quoted repository content"
      # shellcheck disable=SC2034
      RUN_ID=r1
      # shellcheck disable=SC2034
      CURRENT_ITERATION=1
      # shellcheck disable=SC2034
      SPEC_HASH=h1
      # shellcheck disable=SC2034
      SCRIPT_DIR="$PWD/skills/blueprint-review/scripts"
      log_warning() { :; }; log_info() { :; }
      get_review_file() { echo "$TMP/$1"; }
      execute_review() { echo CALLED >> "$TMP/reached"; printf '{}\n'; }
      eval "$_bp_fn"
      if [[ -n "$cli" ]]; then
        _bp_droid_rescue "$slot" "$TMP/${slot}.json" "$cli" >/dev/null 2>&1
      else
        _bp_droid_rescue "$slot" "$TMP/${slot}.json" >/dev/null 2>&1
      fi
    )
  }

  # grok: the runtime-sandbox-failure slot must never reach droid.
  : > "$TMP/reached"
  _bp_probe grok
  grep -q CALLED "$TMP/reached" \
    && bad "blueprint: grok slot → NO droid rescue (prompt not forwarded)" \
    || ok  "blueprint: grok slot → NO droid rescue (prompt not forwarded)"

  # The slot label is NOT the CLI. `blueprint-review.reviewer_N` is resolved by
  # `resolve_role_cli`, so operator config can put grok's CLI in the agy or codex
  # slot while the output-file position keeps its historical name. A guard keyed
  # on the slot would wave that case straight through to droid — the same leak,
  # reached by configuration instead of by failure mode. Cursor Bugbot, PR #704.
  : > "$TMP/reached"
  _bp_probe agy grok
  grep -q CALLED "$TMP/reached" \
    && bad "blueprint: grok CLI in the agy slot → NO droid rescue (guard keys on CLI, not slot)" \
    || ok  "blueprint: grok CLI in the agy slot → NO droid rescue (guard keys on CLI, not slot)"

  # Negative control — the guard must be load-bearing, not a dead branch that
  # would pass the assertion above even if rescue were broken for everyone.
  : > "$TMP/reached"
  _bp_probe codex
  grep -q CALLED "$TMP/reached" \
    && ok  "blueprint: codex slot STILL rescued (grok guard is name-scoped, not a blanket kill)" \
    || bad "blueprint: codex slot STILL rescued (grok guard is name-scoped, not a blanket kill)"
fi

echo ""
echo "── Results: $PASS/$TOTAL passed ────────────────────────────"
[[ "$FAIL" -gt 0 ]] && { echo "   $FAIL FAILED"; exit 1; }
echo "   All passed."
exit 0
