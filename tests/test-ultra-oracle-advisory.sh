#!/bin/bash
# tests/test-ultra-oracle-advisory.sh
# Exercises the background-dispatch mechanism the blueprint-review auxiliary
# advisory relies on: ultra_oracle_consult --mode background must return a typed
# status, and on a real dispatch must eventually write "$out.rc" + the verdict.
set -u
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
tmp="$(mktemp -d)"; export HOME="$tmp"; mkdir -p "$tmp/.claude" "$tmp/bin"; cd "$tmp" || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM   # clean up temp dir even if killed mid-run
# shellcheck source=/dev/null
. "$DIR/tests/lib/uora-test-env.sh"
T="$tmp"; export HOME="$tmp"; uora_fake_home; uora_shims "$tmp/bin"
export PATH="$tmp/bin:$PATH"
# shellcheck source=/dev/null
source "$DIR/scripts/lib/ultra-oracle.sh"
uora_inproc

# helper: bounded wait for the .rc completion marker
wait_rc() {
  local f="$1" n=0
  # up to 30 s: a fake Chrome consult takes a few seconds
  while [ ! -f "$f.rc" ] && [ "$n" -lt 150 ]; do sleep 0.2; n=$((n + 1)); done
  # Return non-zero on timeout so callers can distinguish "never wrote .rc" (a real
  # dispatcher bug) from "wrote .rc=0". Without this a missing .rc reads as empty
  # and trivially != "0", silently false-passing the failure-path assertion.
  [ -f "$f.rc" ]
}

# (a) background dispatch -> 'dispatched', then .rc=0 and verdict written
uora_scenario $UORA_HAPPY
st="$(ultra_oracle_consult --mode background --prompt "review the plan" --slug "ultra oracle plan review" --out "$tmp/a.md")"
[ "$st" = "dispatched" ] || { echo "FAIL background status got '$st'"; FAIL=1; }
wait_rc "$tmp/a.md" || { echo "FAIL .rc never written (a)"; FAIL=1; }
[ "$(cat "$tmp/a.md.rc" 2>/dev/null)" = "0" ] || { echo "FAIL .rc not 0"; FAIL=1; }
grep -q "QUALIFY-ONE" "$tmp/a.md" || { echo "FAIL verdict not written"; FAIL=1; }

# (b) background dispatch with a crashing child -> .rc 1, .err child-died (caller banners failure)
uora_scenario ctx nav home '{"exit":9}'
st="$(ultra_oracle_consult --mode background --prompt "review the plan" --slug "ultra oracle plan review" --out "$tmp/b.md")"
[ "$st" = "dispatched" ] || { echo "FAIL background(fail) status got '$st'"; FAIL=1; }
wait_rc "$tmp/b.md" || { echo "FAIL .rc never written on fail path (b)"; FAIL=1; }
_rc_b="$(cat "$tmp/b.md.rc" 2>/dev/null)"
[ "$_rc_b" = 1 ] || { echo "FAIL .rc should be 1 on fail (got '$_rc_b')"; FAIL=1; }
[ "$(head -1 "$tmp/b.md.err" 2>/dev/null)" = child-died ] || { echo "FAIL .err should read child-died (got '$(head -1 "$tmp/b.md.err" 2>/dev/null)')"; FAIL=1; }

# (b2) background failure with a KNOWN signature (a signed-out child) -> adapter writes "$out.hint"
# with the actionable operator step (#340, spec 2026-11-01 §6). This is the exact channel the blueprint-review loop
# consumes to render its "ULTRA-ORACLE ADVISORY FAILED [...]" banner, since it calls the
# adapter directly (not via ultra-oracle-run.sh).
uora_scenario @auth
st="$(ultra_oracle_consult --mode background --prompt "review the plan" --slug "ultra oracle plan review" --out "$tmp/b2.md")"
[ "$st" = "dispatched" ] || { echo "FAIL background(signed-out) status got '$st'"; FAIL=1; }
wait_rc "$tmp/b2.md" || { echo "FAIL .rc never written on signed-out path (b2)"; FAIL=1; }
[ "$(cat "$tmp/b2.md.rc" 2>/dev/null)" = 1 ] || { echo "FAIL signed-out path should be rc 1"; FAIL=1; }
[ -f "$tmp/b2.md.hint" ] || { echo "FAIL .hint not written on known-signature failure"; FAIL=1; }
grep -q "not signed in" "$tmp/b2.md.hint" 2>/dev/null || { echo "FAIL .hint missing operator action"; FAIL=1; }

# (c) operator skip -> 'skipped:user', no dispatch, no .rc
uora_scenario $UORA_HAPPY
touch "$tmp/.claude/skip-ultra-oracle.local"
st="$(ultra_oracle_consult --mode background --prompt "review the plan" --slug "ultra oracle plan review" --out "$tmp/c.md")"
[ "$st" = "skipped:user" ] || { echo "FAIL skip status got '$st'"; FAIL=1; }
[ -f "$tmp/c.md.rc" ] && { echo "FAIL skip should not write .rc"; FAIL=1; }
rm -f "$tmp/.claude/skip-ultra-oracle.local"

# (d) unavailable -> 'skipped:unavailable' (caller banners; never spins on a missing .rc)
OLDPATH="$PATH"; _ULTRA_ORACLE_CLAUDE_BIN=""; PATH="/usr/bin:/bin"
st="$(ultra_oracle_consult --mode background --prompt "review the plan" --slug "ultra oracle plan review" --out "$tmp/d.md")"
[ "$st" = "skipped:unavailable" ] || { echo "FAIL unavail status got '$st'"; FAIL=1; }
# Unavailable is a no-dispatch path: assert no .rc was written, catching an
# accidental background child that would violate the "never dispatched" contract.
[ -f "$tmp/d.md.rc" ] && { echo "FAIL unavailable should not write .rc"; FAIL=1; }
PATH="$OLDPATH"; _ULTRA_ORACLE_CLAUDE_BIN="$T/bin/claude"

[ "$FAIL" = 0 ] && echo "PASS test-ultra-oracle-advisory" || exit 1
