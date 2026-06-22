#!/bin/bash
# tests/test-oracle-max.sh
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
tmp="$(mktemp -d)"; export HOME="$tmp"; mkdir -p "$tmp/.claude" "$tmp/bin"; cd "$tmp" || exit 1
# Functional oracle stub: parses argv for --write-output; behavior from ORACLE_MAX_MOCK_MODE.
cat > "$tmp/bin/oracle" <<'EOF'
#!/bin/bash
out=""
while [ $# -gt 0 ]; do case "$1" in --write-output) out="$2"; shift 2;; *) shift;; esac; done
case "${ORACLE_MAX_MOCK_MODE:-ok}" in
  ok)    [ -n "$out" ] && printf 'ORACLE-MAX VERDICT: looks good\n' > "$out"; exit 0;;
  empty) exit 0;;                 # exits 0 but writes nothing (browser no-op)
  hang)  sleep 30; exit 0;;
  fail)  exit 7;;
esac
EOF
chmod +x "$tmp/bin/oracle"; export PATH="$tmp/bin:$PATH"
# shellcheck source=/dev/null
source "$DIR/scripts/lib/oracle-max.sh"

# NOTE: `VAR=x st=$(...)` is a pure assignment — it does NOT export VAR to the
# oracle stub subprocess. Each case must `export` the mock mode.
export ORACLE_MAX_MOCK_MODE=ok
st="$(oracle_max_consult --prompt hi --out "$tmp/v.md" --mode blocking)"
[ "$st" = "ok" ] || { echo "FAIL ok got '$st'"; FAIL=1; }
grep -q "ORACLE-MAX VERDICT" "$tmp/v.md" || { echo "FAIL verdict not captured"; FAIL=1; }

# exit 0 but empty output -> error (fail-closed file check)
export ORACLE_MAX_MOCK_MODE=empty
st="$(oracle_max_consult --prompt hi --out "$tmp/v_e.md" --mode blocking)"
[ "$st" = "error" ] || { echo "FAIL empty->error got '$st'"; FAIL=1; }

# operator skip file -> skipped:user (checked before availability, so mock mode irrelevant)
export ORACLE_MAX_MOCK_MODE=ok
touch "$tmp/.claude/skip-oracle-max.local"
st="$(oracle_max_consult --prompt hi --out "$tmp/v_s.md" --mode blocking)"
[ "$st" = "skipped:user" ] || { echo "FAIL skip got '$st'"; FAIL=1; }
rm -f "$tmp/.claude/skip-oracle-max.local"

# unavailable -> skipped:unavailable. Restrict PATH to system dirs so BOTH the stub
# AND any real homebrew-installed oracle are hidden (keeps git/cat/perl available).
OLDPATH="$PATH"; PATH="/usr/bin:/bin"
st="$(oracle_max_consult --prompt hi --out "$tmp/v2.md" --mode blocking)"
[ "$st" = "skipped:unavailable" ] || { echo "FAIL unavail got '$st'"; FAIL=1; }
PATH="$OLDPATH"

# timeout (cap fires even if timeout/gtimeout hidden -> perl fallback via _portable_timeout)
export ORACLE_MAX_MOCK_MODE=hang
st="$(oracle_max_consult --prompt hi --out "$tmp/v3.md" --mode blocking --timeout-cap-seconds 1)"
[ "$st" = "timeout" ] || { echo "FAIL timeout got '$st'"; FAIL=1; }

# non-zero exit -> error
export ORACLE_MAX_MOCK_MODE=fail
st="$(oracle_max_consult --prompt hi --out "$tmp/v4.md" --mode blocking)"
[ "$st" = "error" ] || { echo "FAIL fail->error got '$st'"; FAIL=1; }

# malformed call: a value-flag missing its argument -> typed 'error', not a set -u crash
export ORACLE_MAX_MOCK_MODE=ok
st="$(oracle_max_consult --prompt hi --out)"
[ "$st" = "error" ] || { echo "FAIL missing-value got '$st'"; FAIL=1; }
unset ORACLE_MAX_MOCK_MODE

[ "$FAIL" = 0 ] && echo "PASS test-oracle-max" || exit 1
