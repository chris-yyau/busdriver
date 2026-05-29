#!/usr/bin/env bash
# Tests for runtime droid fallback.
#   Part A: should_escalate_to_droid() predicate (resolve-cli.sh)
#   Part B: dispatch.sh per-voice droid fallback (PATH-stubbed CLIs)
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
should_escalate_to_droid grok 124 "$NE" && ok "timeout(124) → escalate"      || bad "timeout(124) → escalate"
should_escalate_to_droid grok 1   "$NE" && ok "error(1) → escalate"          || bad "error(1) → escalate"
should_escalate_to_droid agy  0   "$EM" && ok "exit0 + empty → escalate"     || bad "exit0 + empty → escalate"
should_escalate_to_droid agy  0   "$MI" && ok "exit0 + missing → escalate"   || bad "exit0 + missing → escalate"
should_escalate_to_droid agy  0   "$NE" && bad "exit0 + good output → NO"     || ok "exit0 + good output → NO"
should_escalate_to_droid droid 1  "$NE" && bad "primary IS droid → NO"        || ok "primary IS droid → NO"
is_cli_available() { return 1; }                 # droid absent
should_escalate_to_droid grok 124 "$NE" && bad "droid absent → NO"            || ok "droid absent → NO"

# ── Part B: dispatch.sh per-voice fallback (PATH-stubbed) ───────────
echo ""
echo "── dispatch.sh droid fallback ──────────────────────────────"
STUB="$TMP/bin"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\nexit 124\n' > "$STUB/grok"            # simulate web_search timeout
printf '#!/usr/bin/env bash\necho DROID_RESCUE\n' > "$STUB/droid"
chmod +x "$STUB/grok" "$STUB/droid"

O="$TMP/d.out"; E="$TMP/d.err"
PATH="$STUB:$PATH" BUSDRIVER_GROK_QUIET_SANDBOX_WARN=1 \
  bash skills/dispatch-cli/scripts/dispatch.sh --cli grok --timeout 5 --prompt p >"$O" 2>"$E" || true
grep -q DROID_RESCUE "$O"   && ok "grok failure falls back to droid"   || bad "grok failure falls back to droid"
grep -q "from droid" "$O"   && ok "fallback output carries marker"     || bad "fallback output carries marker"
grep -q droid-fallback "$E" && ok "status reports droid-fallback"      || bad "status reports droid-fallback"

# When droid also fails, the voice drops (no rescue marker, non-zero status).
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/droid"; chmod +x "$STUB/droid"
O2="$TMP/d2.out"
PATH="$STUB:$PATH" BUSDRIVER_GROK_QUIET_SANDBOX_WARN=1 \
  bash skills/dispatch-cli/scripts/dispatch.sh --cli grok --timeout 5 --prompt p >"$O2" 2>/dev/null || true
grep -q DROID_RESCUE "$O2" && bad "droid-also-fails → voice drops" || ok "droid-also-fails → voice drops"

# Primary exits 0 but EMPTY output + droid rescue fails → must NOT report success.
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/grok"   # exit 0, no output
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/droid"
chmod +x "$STUB/grok" "$STUB/droid"
PATH="$STUB:$PATH" BUSDRIVER_GROK_QUIET_SANDBOX_WARN=1 \
  bash skills/dispatch-cli/scripts/dispatch.sh --cli grok --timeout 5 --prompt p >/dev/null 2>/dev/null
RC=$?
[[ "$RC" -ne 0 ]] && ok "exit0+empty+droid-fail → non-zero exit (not false success)" \
                  || bad "exit0+empty+droid-fail → non-zero exit (not false success)"

echo ""
echo "── Results: $PASS/$TOTAL passed ────────────────────────────"
[[ "$FAIL" -gt 0 ]] && { echo "   $FAIL FAILED"; exit 1; }
echo "   All passed."
exit 0
