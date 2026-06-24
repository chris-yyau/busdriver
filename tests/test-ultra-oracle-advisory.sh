#!/bin/bash
# tests/test-ultra-oracle-advisory.sh
# Exercises the background-dispatch mechanism the blueprint-review auxiliary
# advisory relies on: ultra_oracle_consult --mode background must return a typed
# status, and on a real dispatch must eventually write "$out.rc" + the verdict.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
tmp="$(mktemp -d)"; export HOME="$tmp"; mkdir -p "$tmp/.claude" "$tmp/bin"; cd "$tmp" || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM   # clean up temp dir even if killed mid-run
cat > "$tmp/bin/oracle" <<'EOF'
#!/bin/bash
out=""
while [ $# -gt 0 ]; do case "$1" in --write-output) out="$2"; shift 2;; *) shift;; esac; done
case "${ULTRA_ORACLE_MOCK_MODE:-ok}" in
  ok)   [ -n "$out" ] && printf 'ADVISORY: plan looks sound\n' > "$out"; exit 0;;
  fail) exit 9;;
esac
EOF
chmod +x "$tmp/bin/oracle"; export PATH="$tmp/bin:$PATH"
# shellcheck source=/dev/null
source "$DIR/scripts/lib/ultra-oracle.sh"

# helper: bounded wait for the .rc completion marker
wait_rc() {
  local f="$1" n=0
  while [ ! -f "$f.rc" ] && [ "$n" -lt 50 ]; do sleep 0.2; n=$((n + 1)); done
  # Return non-zero on timeout so callers can distinguish "never wrote .rc" (a real
  # dispatcher bug) from "wrote .rc=0". Without this a missing .rc reads as empty
  # and trivially != "0", silently false-passing the failure-path assertion.
  [ -f "$f.rc" ]
}

# (a) background dispatch -> 'dispatched', then .rc=0 and verdict written
export ULTRA_ORACLE_MOCK_MODE=ok
st="$(ultra_oracle_consult --mode background --prompt "review the plan" --slug "ultra oracle plan review" --out "$tmp/a.md")"
[ "$st" = "dispatched" ] || { echo "FAIL background status got '$st'"; FAIL=1; }
wait_rc "$tmp/a.md" || { echo "FAIL .rc never written (a)"; FAIL=1; }
[ "$(cat "$tmp/a.md.rc" 2>/dev/null)" = "0" ] || { echo "FAIL .rc not 0"; FAIL=1; }
grep -q "ADVISORY:" "$tmp/a.md" || { echo "FAIL verdict not written"; FAIL=1; }

# (b) background dispatch with failing oracle -> .rc non-zero (caller banners failure)
export ULTRA_ORACLE_MOCK_MODE=fail
st="$(ultra_oracle_consult --mode background --prompt "review the plan" --slug "ultra oracle plan review" --out "$tmp/b.md")"
[ "$st" = "dispatched" ] || { echo "FAIL background(fail) status got '$st'"; FAIL=1; }
wait_rc "$tmp/b.md" || { echo "FAIL .rc never written on fail path (b)"; FAIL=1; }
_rc_b="$(cat "$tmp/b.md.rc" 2>/dev/null)"
{ [ -n "$_rc_b" ] && [ "$_rc_b" != "0" ]; } || { echo "FAIL .rc should exist and be non-zero on fail (got '$_rc_b')"; FAIL=1; }

# (c) operator skip -> 'skipped:user', no dispatch, no .rc
export ULTRA_ORACLE_MOCK_MODE=ok
touch "$tmp/.claude/skip-ultra-oracle.local"
st="$(ultra_oracle_consult --mode background --prompt "review the plan" --slug "ultra oracle plan review" --out "$tmp/c.md")"
[ "$st" = "skipped:user" ] || { echo "FAIL skip status got '$st'"; FAIL=1; }
[ -f "$tmp/c.md.rc" ] && { echo "FAIL skip should not write .rc"; FAIL=1; }
rm -f "$tmp/.claude/skip-ultra-oracle.local"

# (d) unavailable -> 'skipped:unavailable' (caller banners; never spins on a missing .rc)
OLDPATH="$PATH"; PATH="/usr/bin:/bin"
st="$(ultra_oracle_consult --mode background --prompt "review the plan" --slug "ultra oracle plan review" --out "$tmp/d.md")"
[ "$st" = "skipped:unavailable" ] || { echo "FAIL unavail status got '$st'"; FAIL=1; }
# Unavailable is a no-dispatch path: assert no .rc was written, catching an
# accidental background child that would violate the "never dispatched" contract.
[ -f "$tmp/d.md.rc" ] && { echo "FAIL unavailable should not write .rc"; FAIL=1; }
PATH="$OLDPATH"
unset ULTRA_ORACLE_MOCK_MODE

[ "$FAIL" = 0 ] && echo "PASS test-ultra-oracle-advisory" || exit 1
