#!/bin/bash
# tests/test-oracle-max-advisory.sh
# Exercises the background-dispatch mechanism the blueprint-review auxiliary
# advisory relies on: oracle_max_consult --mode background must return a typed
# status, and on a real dispatch must eventually write "$out.rc" + the verdict.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
tmp="$(mktemp -d)"; export HOME="$tmp"; mkdir -p "$tmp/.claude" "$tmp/bin"; cd "$tmp" || exit 1
cat > "$tmp/bin/oracle" <<'EOF'
#!/bin/bash
out=""
while [ $# -gt 0 ]; do case "$1" in --write-output) out="$2"; shift 2;; *) shift;; esac; done
case "${ORACLE_MAX_MOCK_MODE:-ok}" in
  ok)   [ -n "$out" ] && printf 'ADVISORY: plan looks sound\n' > "$out"; exit 0;;
  fail) exit 9;;
esac
EOF
chmod +x "$tmp/bin/oracle"; export PATH="$tmp/bin:$PATH"
# shellcheck source=/dev/null
source "$DIR/scripts/lib/oracle-max.sh"

# helper: bounded wait for the .rc completion marker
wait_rc() { local f="$1" n=0; while [ ! -f "$f.rc" ] && [ "$n" -lt 50 ]; do sleep 0.2; n=$((n + 1)); done; }

# (a) background dispatch -> 'dispatched', then .rc=0 and verdict written
export ORACLE_MAX_MOCK_MODE=ok
st="$(oracle_max_consult --mode background --prompt "review the plan" --slug "oracle max plan review" --out "$tmp/a.md")"
[ "$st" = "dispatched" ] || { echo "FAIL background status got '$st'"; FAIL=1; }
wait_rc "$tmp/a.md"
[ "$(cat "$tmp/a.md.rc" 2>/dev/null)" = "0" ] || { echo "FAIL .rc not 0"; FAIL=1; }
grep -q "ADVISORY:" "$tmp/a.md" || { echo "FAIL verdict not written"; FAIL=1; }

# (b) background dispatch with failing oracle -> .rc non-zero (caller banners failure)
export ORACLE_MAX_MOCK_MODE=fail
st="$(oracle_max_consult --mode background --prompt "review the plan" --slug "oracle max plan review" --out "$tmp/b.md")"
[ "$st" = "dispatched" ] || { echo "FAIL background(fail) status got '$st'"; FAIL=1; }
wait_rc "$tmp/b.md"
[ "$(cat "$tmp/b.md.rc" 2>/dev/null)" = "0" ] && { echo "FAIL .rc should be non-zero on fail"; FAIL=1; }

# (c) operator skip -> 'skipped:user', no dispatch, no .rc
export ORACLE_MAX_MOCK_MODE=ok
touch "$tmp/.claude/skip-oracle-max.local"
st="$(oracle_max_consult --mode background --prompt "review the plan" --slug "oracle max plan review" --out "$tmp/c.md")"
[ "$st" = "skipped:user" ] || { echo "FAIL skip status got '$st'"; FAIL=1; }
[ -f "$tmp/c.md.rc" ] && { echo "FAIL skip should not write .rc"; FAIL=1; }
rm -f "$tmp/.claude/skip-oracle-max.local"

# (d) unavailable -> 'skipped:unavailable' (caller banners; never spins on a missing .rc)
OLDPATH="$PATH"; PATH="/usr/bin:/bin"
st="$(oracle_max_consult --mode background --prompt "review the plan" --slug "oracle max plan review" --out "$tmp/d.md")"
[ "$st" = "skipped:unavailable" ] || { echo "FAIL unavail status got '$st'"; FAIL=1; }
PATH="$OLDPATH"
unset ORACLE_MAX_MOCK_MODE

[ "$FAIL" = 0 ] && echo "PASS test-oracle-max-advisory" || exit 1
