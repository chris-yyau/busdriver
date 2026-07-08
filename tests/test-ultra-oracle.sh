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
# ...and the floor must NOT reject a verdict at exactly the default threshold (8 non-ws bytes).
# Use a dedicated near-threshold stub so this guard actually exercises the boundary,
# not the full ~30-char 'ok' mock which would pass even with a much higher floor.
cat > "$tmp/bin/oracle" <<'STUB'
#!/bin/bash
[ -n "${ULTRA_ORACLE_ARGV_OUT:-}" ] && for a in "$@"; do printf '%s\n' "$a"; done > "$ULTRA_ORACLE_ARGV_OUT"
out=""
while [ $# -gt 0 ]; do case "$1" in --write-output) out="$2"; shift 2;; *) shift;; esac; done
case "${ULTRA_ORACLE_MOCK_MODE:-ok}" in
  ok)       [ -n "$out" ] && printf 'ULTRA-ORACLE VERDICT: looks good\n' > "$out"; exit 0;;
  empty)    exit 0;;
  degen)    [ -n "$out" ] && printf 'I\n' > "$out"; exit 0;;
  mingood)  [ -n "$out" ] && printf 'abcdefgh\n' > "$out"; exit 0;;  # exactly 8 non-ws bytes
  hang)     sleep 30; exit 0;;
  fail)     exit 7;;
esac
STUB
chmod +x "$tmp/bin/oracle"
export ULTRA_ORACLE_MOCK_MODE=mingood
st="$(ultra_oracle_consult --prompt hi --out "$tmp/vok.md" --mode blocking)"
[ "$st" = "ok" ] || { echo "FAIL floor false-rejects 8-byte verdict got '$st'"; FAIL=1; }

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

# default config (no cookiePath, no hideWindow): no --browser-cookie-path; window VISIBLE
# by default (B8 — --browser-hide-window is now opt-in because hiding it broke oracle's
# ChatGPT browser engine and failed silently).
rm -f "$tmp/.claude/busdriver.json"
: > "$tmp/argv.log"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/c0.md" --mode blocking)"
[ "$st" = "ok" ] || { echo "FAIL c0 status got '$st'"; FAIL=1; }
grep -qx -- "--browser-cookie-path" "$tmp/argv.log" && { echo "FAIL cookie-path leaked when unset"; FAIL=1; }
grep -qx -- "--browser-hide-window" "$tmp/argv.log" && { echo "FAIL window hidden by default (B8: should be VISIBLE)"; FAIL=1; }

# hideWindow=true (opt-in) -> argv carries --browser-hide-window
printf '{ "ultraOracle": { "hideWindow": true } }\n' > "$tmp/.claude/busdriver.json"
: > "$tmp/argv.log"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/c0h.md" --mode blocking)"
[ "$st" = "ok" ] || { echo "FAIL c0h status got '$st'"; FAIL=1; }
grep -qx -- "--browser-hide-window" "$tmp/argv.log" || { echo "FAIL hideWindow=true should add --browser-hide-window"; FAIL=1; }
rm -f "$tmp/.claude/busdriver.json"

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

# --- scripts/ultra-oracle-run.sh wrapper (shell-agnostic entry) ---
# The wrapper exists so the council/etc. SKILL blocks can invoke the bash-only
# oracle lib from ANY caller shell (they are pasted into a zsh Bash tool on
# macOS). HOME=$tmp has no busdriver.json -> council surface disabled by default.
WRAP="$DIR/scripts/ultra-oracle-run.sh"
rm -f "$tmp/.claude/busdriver.json"
wp="$(mktemp)"; printf 'council question' > "$wp"

# bad args -> fail closed
out="$(bash "$WRAP" council 1 "" "")"
[[ "$out" == "FAILED [bad-args]" ]] || { echo "FAIL wrapper bad-args got '$out'"; FAIL=1; }

# surface disabled + not forced -> NOT_ATTEMPTED (caller omits the section)
out="$(bash "$WRAP" council 0 "$wp" "$tmp/wrap_na.md")"
[[ "$out" == "NOT_ATTEMPTED" ]] || { echo "FAIL wrapper NOT_ATTEMPTED got '$out'"; FAIL=1; }

# forced + ok stub -> VERDICT on line 1, verdict text after
export ULTRA_ORACLE_MOCK_MODE=ok
out="$(bash "$WRAP" council 1 "$wp" "$tmp/wrap_ok.md")"
first_line="${out%%$'\n'*}"
[[ "$first_line" == "VERDICT" ]] || { echo "FAIL wrapper VERDICT token got '$first_line'"; FAIL=1; }
printf '%s\n' "$out" | grep -q "ULTRA-ORACLE VERDICT" || { echo "FAIL wrapper verdict body missing"; FAIL=1; }
unset ULTRA_ORACLE_MOCK_MODE

# forced + failing stub -> FAILED [<status>] token (drives the ORACLE_FAILED banner)
export ULTRA_ORACLE_MOCK_MODE=fail
out="$(bash "$WRAP" council 1 "$wp" "$tmp/wrap_fail.md")"
first_line="${out%%$'\n'*}"
[[ "$first_line" == FAILED\ \[*\] ]] || { echo "FAIL wrapper FAILED token got '$first_line'"; FAIL=1; }
unset ULTRA_ORACLE_MOCK_MODE

# REGRESSION (the actual bug): invoked from a NON-bash caller shell it must still
# work — an in-shell `source ultra-oracle.sh` aborted under zsh, but `bash $WRAP`
# runs the wrapper under bash regardless. Skip cleanly if zsh is absent.
if command -v zsh >/dev/null 2>&1; then
  out="$(zsh -c 'bash "$1" council 0 "$2" "$3"' _ "$WRAP" "$wp" "$tmp/wrap_zsh.md" 2>&1)"
  [[ "$out" == "NOT_ATTEMPTED" ]] || { echo "FAIL wrapper under zsh caller got '$out'"; FAIL=1; }
fi
rm -f "$wp"

# --- scripts/ultra-oracle-consult-run.sh wrapper (blocking, raw-token passthrough) ---
# The BLOCKING sibling of ultra-oracle-run.sh: brainstorming + ultraoracle SKILL
# blocks call it instead of sourcing the bash-only lib in a zsh Bash tool (#296).
# It passes ultra_oracle_consult's raw token through (ok|skipped:*|timeout|error),
# with an optional --surface gate.
CWRAP="$DIR/scripts/ultra-oracle-consult-run.sh"
rm -f "$tmp/.claude/busdriver.json"
cwp="$(mktemp)"; printf 'design to critique' > "$cwp"

# no forwarded args (no --out) -> fail closed to `error`
out="$(bash "$CWRAP")"
[[ "$out" == "error" ]] || { echo "FAIL consult-run no-args got '$out'"; FAIL=1; }

# dangling --surface with no value -> fail closed to `error`
out="$(bash "$CWRAP" --surface)"
[[ "$out" == "error" ]] || { echo "FAIL consult-run dangling --surface got '$out'"; FAIL=1; }

# --surface brainstorming, config disabled (no busdriver.json) -> skipped:disabled
out="$(bash "$CWRAP" --surface brainstorming --mode blocking --prompt-file "$cwp" --out "$tmp/cr_dis.md")"
[[ "$out" == "skipped:disabled" ]] || { echo "FAIL consult-run disabled surface got '$out'"; FAIL=1; }

# enable the brainstorming surface via USER config for the remaining surface-gated cases
printf '{"ultraOracle":{"brainstorming":{"enabled":true}}}' > "$tmp/.claude/busdriver.json"

# --surface brainstorming, enabled + ok stub -> raw `ok` + verdict body at --out
export ULTRA_ORACLE_MOCK_MODE=ok
out="$(bash "$CWRAP" --surface brainstorming --mode blocking --prompt-file "$cwp" --out "$tmp/cr_ok.md")"
[[ "$out" == "ok" ]] || { echo "FAIL consult-run enabled ok got '$out'"; FAIL=1; }
grep -q "ULTRA-ORACLE VERDICT" "$tmp/cr_ok.md" || { echo "FAIL consult-run verdict not captured"; FAIL=1; }

# no --surface (ultraoracle shape) + ok stub -> `ok` even with no config gate
out="$(bash "$CWRAP" --mode blocking --prompt-file "$cwp" --out "$tmp/cr_noguard.md")"
[[ "$out" == "ok" ]] || { echo "FAIL consult-run no-surface ok got '$out'"; FAIL=1; }

# --context globs (ultraoracle evidence pack) must reach oracle as --file args
export ULTRA_ORACLE_ARGV_OUT="$tmp/cr_argv.log"
ctx="$(mktemp)"; printf 'evidence' > "$ctx"
bash "$CWRAP" --prompt-file "$cwp" --context "$ctx" --out "$tmp/cr_ctx.md" --mode blocking >/dev/null
if ! grep -qxF -- "--file" "$tmp/cr_argv.log" || ! grep -qxF -- "$ctx" "$tmp/cr_argv.log"; then
  echo "FAIL consult-run --context not forwarded to oracle --file"; FAIL=1
fi
rm -f "$ctx"; unset ULTRA_ORACLE_ARGV_OUT

# failing oracle -> raw `error` token (drives caller's ORACLE_FAILED / block-and-ask)
export ULTRA_ORACLE_MOCK_MODE=fail
out="$(bash "$CWRAP" --mode blocking --prompt-file "$cwp" --out "$tmp/cr_fail.md")"
[[ "$out" == "error" ]] || { echo "FAIL consult-run fail stub got '$out'"; FAIL=1; }
unset ULTRA_ORACLE_MOCK_MODE

# REGRESSION (#296): invoked from a NON-bash (zsh) caller it must still work — an
# in-shell `source ultra-oracle.sh` aborted under zsh, but `bash $CWRAP` runs under
# bash regardless. Surface is enabled + ok stub, so a working wrapper returns `ok`;
# the pre-fix in-shell source would have half-loaded and produced no verdict.
export ULTRA_ORACLE_MOCK_MODE=ok
if command -v zsh >/dev/null 2>&1; then
  out="$(zsh -c 'bash "$1" --surface brainstorming --mode blocking --prompt-file "$2" --out "$3"' \
        _ "$CWRAP" "$cwp" "$tmp/cr_zsh.md" 2>&1)"
  [[ "$out" == "ok" ]] || { echo "FAIL consult-run under zsh caller got '$out'"; FAIL=1; }
fi
unset ULTRA_ORACLE_MOCK_MODE
rm -f "$cwp" "$tmp/.claude/busdriver.json"

[ "$FAIL" = 0 ] && echo "PASS test-ultra-oracle" || exit 1
