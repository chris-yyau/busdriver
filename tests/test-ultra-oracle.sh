#!/bin/bash
# tests/test-ultra-oracle.sh
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
tmp="$(mktemp -d)"; export HOME="$tmp"; mkdir -p "$tmp/.claude" "$tmp/bin"; cd "$tmp" || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM   # clean up temp dir even if killed mid-run
# Functional oracle stub: parses argv for --write-output; behavior from ULTRA_ORACLE_MOCK_MODE.
cat > "$tmp/bin/oracle" <<'EOF'
#!/bin/bash
# Record argv (one arg per line so paths with spaces survive) for flag assertions.
[ -n "${ULTRA_ORACLE_ARGV_OUT:-}" ] && for a in "$@"; do printf '%s\n' "$a"; done > "$ULTRA_ORACLE_ARGV_OUT"
out=""
while [ $# -gt 0 ]; do case "$1" in --write-output) out="$2"; shift 2;; *) shift;; esac; done
case "${ULTRA_ORACLE_MOCK_MODE:-ok}" in
  ok)    [ -n "$out" ] && printf 'ULTRA-ORACLE VERDICT: looks good\n' > "$out"; exit 0;;
  empty) exit 0;;                 # exits 0 but writes nothing (browser no-op)
  degen) [ -n "$out" ] && printf 'I\n' > "$out"; exit 0;;  # exit 0 + degenerate 2-byte capture
  hang)  sleep 30; exit 0;;
  fail)  exit 7;;
esac
EOF
chmod +x "$tmp/bin/oracle"; export PATH="$tmp/bin:$PATH"
# shellcheck source=/dev/null
source "$DIR/scripts/lib/ultra-oracle.sh"

# NOTE: `VAR=x st=$(...)` is a pure assignment — it does NOT export VAR to the
# oracle stub subprocess. Each case must `export` the mock mode.
export ULTRA_ORACLE_MOCK_MODE=ok
st="$(ultra_oracle_consult --prompt hi --out "$tmp/v.md" --mode blocking)"
[ "$st" = "ok" ] || { echo "FAIL ok got '$st'"; FAIL=1; }
grep -q "ULTRA-ORACLE VERDICT" "$tmp/v.md" || { echo "FAIL verdict not captured"; FAIL=1; }

# exit 0 + degenerate near-empty capture ("I\n") -> error (fail-closed verdict floor)
export ULTRA_ORACLE_MOCK_MODE=degen
st="$(ultra_oracle_consult --prompt hi --out "$tmp/vd.md" --mode blocking)"
[ "$st" = "error" ] || { echo "FAIL degen->error got '$st'"; FAIL=1; }
# ...and the floor must NOT reject a real short verdict (regression guard on the default)
export ULTRA_ORACLE_MOCK_MODE=ok
st="$(ultra_oracle_consult --prompt hi --out "$tmp/vok.md" --mode blocking)"
[ "$st" = "ok" ] || { echo "FAIL floor false-rejects real verdict got '$st'"; FAIL=1; }

# exit 0 but empty output -> error (fail-closed file check)
export ULTRA_ORACLE_MOCK_MODE=empty
st="$(ultra_oracle_consult --prompt hi --out "$tmp/v_e.md" --mode blocking)"
[ "$st" = "error" ] || { echo "FAIL empty->error got '$st'"; FAIL=1; }

# operator skip file -> skipped:user (checked before availability, so mock mode irrelevant)
export ULTRA_ORACLE_MOCK_MODE=ok
touch "$tmp/.claude/skip-ultra-oracle.local"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/v_s.md" --mode blocking)"
[ "$st" = "skipped:user" ] || { echo "FAIL skip got '$st'"; FAIL=1; }
rm -f "$tmp/.claude/skip-ultra-oracle.local"

# unavailable -> skipped:unavailable. Restrict PATH to system dirs so BOTH the stub
# AND any real homebrew-installed oracle are hidden (keeps git/cat/perl available).
OLDPATH="$PATH"; PATH="/usr/bin:/bin"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/v2.md" --mode blocking)"
[ "$st" = "skipped:unavailable" ] || { echo "FAIL unavail got '$st'"; FAIL=1; }
PATH="$OLDPATH"

# timeout (cap fires even if timeout/gtimeout hidden -> perl fallback via _portable_timeout)
export ULTRA_ORACLE_MOCK_MODE=hang
st="$(ultra_oracle_consult --prompt hi --out "$tmp/v3.md" --mode blocking --timeout-cap-seconds 1)"
[ "$st" = "timeout" ] || { echo "FAIL timeout got '$st'"; FAIL=1; }

# non-zero exit -> error
export ULTRA_ORACLE_MOCK_MODE=fail
st="$(ultra_oracle_consult --prompt hi --out "$tmp/v4.md" --mode blocking)"
[ "$st" = "error" ] || { echo "FAIL fail->error got '$st'"; FAIL=1; }

# malformed call: a value-flag missing its argument -> typed 'error', not a set -u crash
export ULTRA_ORACLE_MOCK_MODE=ok
st="$(ultra_oracle_consult --prompt hi --out)"
[ "$st" = "error" ] || { echo "FAIL missing-value got '$st'"; FAIL=1; }
# no prompt source (neither --prompt nor --prompt-file) -> typed 'error'
st="$(ultra_oracle_consult --out "$tmp/np.md")"
[ "$st" = "error" ] || { echo "FAIL missing-prompt got '$st'"; FAIL=1; }
unset ULTRA_ORACLE_MOCK_MODE

# --- session-reuse argv wiring (cookiePath / hideWindow) ---
export ULTRA_ORACLE_MOCK_MODE=ok
export ULTRA_ORACLE_ARGV_OUT="$tmp/argv.log"
ck="$tmp/Cookies"; : > "$ck"   # a readable cookie DB stand-in

# Each case clears argv.log and asserts an 'ok' status BEFORE grepping flags —
# otherwise a failed/short-circuited call leaves the prior case's argv in place
# and the flag assertions false-pass against stale content.

# default config (no cookiePath): no --browser-cookie-path; window always hidden
rm -f "$tmp/.claude/busdriver.json"
: > "$tmp/argv.log"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/c0.md" --mode blocking)"
[ "$st" = "ok" ] || { echo "FAIL c0 status got '$st'"; FAIL=1; }
grep -qx -- "--browser-cookie-path" "$tmp/argv.log" && { echo "FAIL cookie-path leaked when unset"; FAIL=1; }
grep -qx -- "--browser-hide-window" "$tmp/argv.log" || { echo "FAIL window not hidden"; FAIL=1; }

# cookiePath set + readable -> argv carries --browser-cookie-path <path>
printf '{ "ultraOracle": { "cookiePath": "%s" } }\n' "$ck" > "$tmp/.claude/busdriver.json"
: > "$tmp/argv.log"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/c1.md" --mode blocking)"
[ "$st" = "ok" ] || { echo "FAIL c1 status got '$st'"; FAIL=1; }
grep -qx -- "--browser-cookie-path" "$tmp/argv.log" || { echo "FAIL cookie-path flag missing"; FAIL=1; }
grep -qxF -- "$ck" "$tmp/argv.log" || { echo "FAIL cookie-path value missing"; FAIL=1; }

# cookiePath wins over chromeProfileDir (mutually exclusive: no --copy-profile)
mkdir -p "$tmp/prof"
printf '{ "ultraOracle": { "cookiePath": "%s", "chromeProfileDir": "%s" } }\n' "$ck" "$tmp/prof" > "$tmp/.claude/busdriver.json"
: > "$tmp/argv.log"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/c3.md" --mode blocking)"
[ "$st" = "ok" ] || { echo "FAIL c3 status got '$st'"; FAIL=1; }
grep -qx -- "--browser-cookie-path" "$tmp/argv.log" || { echo "FAIL cookie-path flag missing in precedence case"; FAIL=1; }
grep -qxF -- "$ck" "$tmp/argv.log" || { echo "FAIL cookie-path value missing in precedence case"; FAIL=1; }
grep -qx -- "--copy-profile" "$tmp/argv.log" && { echo "FAIL copy-profile should yield to cookie-path"; FAIL=1; }

# configured-but-UNREADABLE cookiePath is a fail-closed misconfiguration: return a
# typed 'error' WITHOUT invoking oracle (never silently reuse the default Chrome
# session, never fall back to --copy-profile). Assert oracle was never called by
# checking argv.log stays empty.
printf '{ "ultraOracle": { "cookiePath": "%s/nope/Cookies", "chromeProfileDir": "%s" } }\n' "$tmp" "$tmp/prof" > "$tmp/.claude/busdriver.json"
: > "$tmp/argv.log"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/c4.md" --mode blocking)"
[ "$st" = "error" ] || { echo "FAIL unreadable cookiePath should be 'error' got '$st'"; FAIL=1; }
[ -s "$tmp/argv.log" ] && { echo "FAIL unreadable cookiePath must not invoke oracle"; FAIL=1; }
rm -f "$tmp/.claude/busdriver.json"
unset ULTRA_ORACLE_MOCK_MODE ULTRA_ORACLE_ARGV_OUT

[ "$FAIL" = 0 ] && echo "PASS test-ultra-oracle" || exit 1
