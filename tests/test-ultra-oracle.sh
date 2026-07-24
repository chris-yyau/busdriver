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
# This suite exercises the #458 watched-run/salvage timing, firing many rapid same-key background
# consults; opt out of the #477 browser mutex so it doesn't (correctly) serialize them and skew the
# elapsed-time assertions. The mutex itself is covered by tests/test-ultra-oracle-lock.sh.
export ULTRA_ORACLE_TEST_NO_LOCK=1
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
# Record the received ORACLE_REMOTE_TOKEN env (the secret delivery channel) for assertions.
[ -n "${ULTRA_ORACLE_ENV_OUT:-}" ] && printf '%s' "${ORACLE_REMOTE_TOKEN-}" > "$ULTRA_ORACLE_ENV_OUT"
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
# --force is ALWAYS passed (#333): bypasses oracle's prompt-keyed duplicate guard so a
# stale phantom "running" session can't permanently block future same-prompt dispatches.
grep -qx -- "--force" "$tmp/argv.log" || { echo "FAIL --force missing (#333 dup-guard)"; FAIL=1; }

# #458 GAP 1 root cause — per-dispatch UNIQUE slug. oracle 0.16.0 truncates each slug word to 10
# chars and keeps only the first 5 words, so the nonce is TWO <=10-char words PREPENDED (both survive).
# Assert: the --slug value's first two words are "x"+8hex and "y"+8hex (each <=10 chars), the caller
# slug follows, and two consecutive dispatches get DIFFERENT nonce prefixes (no reuse -> no stale tab).
_slug_of() { awk '/^--slug$/{getline; print; exit}' "$1"; }
: > "$tmp/argv.log"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/n1.md" --mode blocking --slug "ultra oracle plan review")"
[ "$st" = "ok" ] || { echo "FAIL nonce d1 status got '$st'"; FAIL=1; }
_slug1="$(_slug_of "$tmp/argv.log")"
_w1="${_slug1%% *}"; _rest1="${_slug1#* }"; _w2="${_rest1%% *}"
_nonce1="$_w1 $_w2"
[[ "$_w1" =~ ^x[0-9a-f]{8}$ ]] || { echo "FAIL nonce word1 not x+8hex: '$_w1'"; FAIL=1; }
[[ "$_w2" =~ ^y[0-9a-f]{8}$ ]] || { echo "FAIL nonce word2 not y+8hex: '$_w2'"; FAIL=1; }
{ [ "${#_w1}" -le 10 ] && [ "${#_w2}" -le 10 ]; } || { echo "FAIL nonce word exceeds 10 chars: '$_nonce1'"; FAIL=1; }
[ "$_slug1" = "$_nonce1 ultra oracle plan review" ] || { echo "FAIL nonce not prepended to caller slug: '$_slug1'"; FAIL=1; }
: > "$tmp/argv.log"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/n2.md" --mode blocking --slug "ultra oracle plan review")"
_slug2="$(_slug_of "$tmp/argv.log")"; _w1b="${_slug2%% *}"; _rest2="${_slug2#* }"; _w2b="${_rest2%% *}"
[ "$_w1 $_w2" != "$_w1b $_w2b" ] || { echo "FAIL two dispatches got the SAME nonce (collision -> tab reuse): '$_nonce1'"; FAIL=1; }

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

# --- attach-running wiring (ADR 0020) ---
# attachRunning is the highest-precedence session source: oracle's OWN Chrome launches are
# Cloudflare-fingerprinted, so attaching to a vanilla browser is the only path that
# completes. Stub the preflight in-process (see _ULTRA_ORACLE_PREFLIGHT) so the test never
# launches a real Chrome.
export ULTRA_ORACLE_MOCK_MODE=ok
export ULTRA_ORACLE_ENV_OUT="$tmp/env.log"
cat > "$tmp/bin/preflight-ok.sh" <<'EOF'
#!/bin/bash
echo "ok 127.0.0.1:61850"
EOF
cat > "$tmp/bin/preflight-fail.sh" <<'EOF'
#!/bin/bash
echo "ultra-oracle-attach: Chrome did not expose a DevTools endpoint within 15s" >&2
exit 1
EOF
cat > "$tmp/bin/preflight-junk.sh" <<'EOF'
#!/bin/bash
echo "something unparseable"
EOF
chmod +x "$tmp/bin/preflight-ok.sh" "$tmp/bin/preflight-fail.sh" "$tmp/bin/preflight-junk.sh"
_ULTRA_ORACLE_PREFLIGHT="$tmp/bin/preflight-ok.sh"

# attachRunning true -> argv carries --browser-attach-running + --remote-chrome <target>.
# cookiePath AND remoteHost are ALSO set here: attach must win over both, and neither
# --browser-cookie-path nor --remote-host may appear (a second session source confuses oracle).
printf '{ "ultraOracle": { "attachRunning": true, "remoteHost": "127.0.0.1:8765", "remoteToken": "tok-xyz", "cookiePath": "%s" } }\n' "$ck" > "$tmp/.claude/busdriver.json"
: > "$tmp/argv.log"; : > "$tmp/env.log"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/at.md" --mode blocking)"
[ "$st" = "ok" ] || { echo "FAIL attach status got '$st'"; FAIL=1; }
grep -qx -- "--browser-attach-running" "$tmp/argv.log" || { echo "FAIL attach flag missing"; FAIL=1; }
grep -qxF -- "127.0.0.1:61850" "$tmp/argv.log" || { echo "FAIL attach target missing"; FAIL=1; }
grep -qx -- "--remote-host" "$tmp/argv.log" && { echo "FAIL remoteHost must yield to attachRunning"; FAIL=1; }
grep -qx -- "--browser-cookie-path" "$tmp/argv.log" && { echo "FAIL cookiePath must yield to attachRunning"; FAIL=1; }
# oracle REJECTS --browser-attach-running combined with --browser-port/--browser-debug-port.
grep -qx -- "--browser-port" "$tmp/argv.log" && { echo "FAIL browser-port incompatible with attach"; FAIL=1; }
# The serve token must not be delivered when the attach path is taken (no remoteHost on argv).
[ -z "$(cat "$tmp/env.log")" ] || { echo "FAIL token delivered via env on attach path"; FAIL=1; }

# attachRunning=true AND hideWindow=true -> --browser-hide-window must be SUPPRESSED.
# Oracle rejects --browser-attach-running combined with --browser-hide-window outright, so
# a user carrying over an old hideWindow=true setting would otherwise get a CLI rejection
# instead of the new attach transport working (Codex P2, PR #409).
printf '{ "ultraOracle": { "attachRunning": true, "hideWindow": true } }\n' > "$tmp/.claude/busdriver.json"
: > "$tmp/argv.log"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/athw.md" --mode blocking)"
[ "$st" = "ok" ] || { echo "FAIL attach+hideWindow status got '$st'"; FAIL=1; }
grep -qx -- "--browser-attach-running" "$tmp/argv.log" || { echo "FAIL attach+hideWindow: attach flag missing"; FAIL=1; }
grep -qx -- "--browser-hide-window" "$tmp/argv.log" && { echo "FAIL attach+hideWindow: hide-window must be suppressed under attach"; FAIL=1; }

# preflight failure -> fail CLOSED ('error'), oracle NEVER invoked. Proceeding would let
# oracle silently launch its own Chrome and walk back into the Cloudflare wall.
_ULTRA_ORACLE_PREFLIGHT="$tmp/bin/preflight-fail.sh"
printf '{ "ultraOracle": { "attachRunning": true } }\n' > "$tmp/.claude/busdriver.json"
: > "$tmp/argv.log"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/at2.md" --mode blocking 2> "$tmp/at2.err")"
[ "$st" = "error" ] || { echo "FAIL attach preflight failure should be 'error' got '$st'"; FAIL=1; }
[ -s "$tmp/argv.log" ] && { echo "FAIL failed preflight must not invoke oracle"; FAIL=1; }
grep -qi "attach preflight failed" "$tmp/at2.err" || { echo "FAIL preflight failure message missing"; FAIL=1; }

# preflight exits 0 but prints no parseable host:port -> still fail CLOSED. An exit-0
# stub whose output we cannot parse would otherwise pass an empty --remote-chrome value.
_ULTRA_ORACLE_PREFLIGHT="$tmp/bin/preflight-junk.sh"
: > "$tmp/argv.log"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/at3.md" --mode blocking 2> "$tmp/at3.err")"
[ "$st" = "error" ] || { echo "FAIL unparseable preflight output should be 'error' got '$st'"; FAIL=1; }
[ -s "$tmp/argv.log" ] && { echo "FAIL unparseable preflight must not invoke oracle"; FAIL=1; }

# Malformed preflight targets must ALL fail closed. Whatever survives parsing becomes
# --remote-chrome, i.e. the address a browser session is driven through, so a loose match
# (`*:[0-9]*` accepted every one of these) is a real hazard, not a cosmetic one.
printf '{ "ultraOracle": { "attachRunning": true } }\n' > "$tmp/.claude/busdriver.json"
for bad in 'ok garbage:1x' 'ok 10.0.0.9:9222' 'ok 127.0.0.1:99999' 'ok 127.0.0.1:0' 'ok 127.0.0.1:' 'ok 127.0.0.1:8080 extra'; do
  printf '#!/bin/bash\necho "%s"\n' "$bad" > "$tmp/bin/preflight-bad.sh"; chmod +x "$tmp/bin/preflight-bad.sh"
  _ULTRA_ORACLE_PREFLIGHT="$tmp/bin/preflight-bad.sh"
  : > "$tmp/argv.log"
  st="$(ultra_oracle_consult --prompt hi --out "$tmp/atbad.md" --mode blocking 2>/dev/null)"
  [ "$st" = "error" ] || { echo "FAIL malformed target '$bad' should be 'error' got '$st'"; FAIL=1; }
  [ -s "$tmp/argv.log" ] && { echo "FAIL malformed target '$bad' must not invoke oracle"; FAIL=1; }
done
# ...while a valid target preceded by diagnostic chatter is still accepted (last line wins).
printf '#!/bin/bash\necho "launching chrome..."\necho "ok 127.0.0.1:61850"\n' > "$tmp/bin/preflight-chatty.sh"
chmod +x "$tmp/bin/preflight-chatty.sh"
_ULTRA_ORACLE_PREFLIGHT="$tmp/bin/preflight-chatty.sh"
: > "$tmp/argv.log"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/atchat.md" --mode blocking)"
[ "$st" = "ok" ] || { echo "FAIL chatty-but-valid preflight got '$st'"; FAIL=1; }
grep -qxF -- "127.0.0.1:61850" "$tmp/argv.log" || { echo "FAIL chatty preflight target not parsed"; FAIL=1; }
rm -f "$tmp/.claude/busdriver.json"

# attachRunning ABSENT (default) -> preflight is never consulted and the pre-ADR-0020
# precedence is untouched (cookiePath path still taken). Guards against the new branch
# hijacking existing installs.
_ULTRA_ORACLE_PREFLIGHT="$tmp/bin/preflight-fail.sh"   # would error if wrongly invoked
printf '{ "ultraOracle": { "cookiePath": "%s" } }\n' "$ck" > "$tmp/.claude/busdriver.json"
: > "$tmp/argv.log"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/at4.md" --mode blocking)"
[ "$st" = "ok" ] || { echo "FAIL default (no attachRunning) status got '$st'"; FAIL=1; }
grep -qx -- "--browser-attach-running" "$tmp/argv.log" && { echo "FAIL attach flag leaked with attachRunning absent"; FAIL=1; }
grep -qx -- "--browser-cookie-path" "$tmp/argv.log" || { echo "FAIL cookiePath path not taken by default"; FAIL=1; }
_ULTRA_ORACLE_PREFLIGHT="$DIR/scripts/ultra-oracle-attach-preflight.sh"   # restore
rm -f "$tmp/.claude/busdriver.json"

# --- serve delegation wiring (remoteHost/remoteToken, #340) ---
# remoteHost set -> argv carries --remote-host <hv>; the SECRET token is delivered via the
# ORACLE_REMOTE_TOKEN env, NOT --remote-token argv (which `ps` would expose). serve owns
# its own signed-in session, so NO --browser-cookie-path even when cookiePath is ALSO set
# (mutually exclusive; remoteHost wins).
export ULTRA_ORACLE_ENV_OUT="$tmp/env.log"
printf '{ "ultraOracle": { "remoteHost": "127.0.0.1:8765", "remoteToken": "tok-xyz", "cookiePath": "%s" } }\n' "$ck" > "$tmp/.claude/busdriver.json"
: > "$tmp/argv.log"; : > "$tmp/env.log"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/rh.md" --mode blocking)"
[ "$st" = "ok" ] || { echo "FAIL rh status got '$st'"; FAIL=1; }
grep -qx -- "--remote-host" "$tmp/argv.log" || { echo "FAIL remote-host flag missing"; FAIL=1; }
grep -qxF -- "127.0.0.1:8765" "$tmp/argv.log" || { echo "FAIL remote-host value missing"; FAIL=1; }
grep -qx -- "--remote-token" "$tmp/argv.log" && { echo "FAIL token must NOT be on argv (ps-visible)"; FAIL=1; }
grep -qxF -- "tok-xyz" "$tmp/argv.log" && { echo "FAIL token value leaked to argv"; FAIL=1; }
[ "$(cat "$tmp/env.log")" = "tok-xyz" ] || { echo "FAIL token not delivered via ORACLE_REMOTE_TOKEN env"; FAIL=1; }
grep -qx -- "--browser-cookie-path" "$tmp/argv.log" && { echo "FAIL cookie-path must yield to remoteHost"; FAIL=1; }

# injection scope (#340): remoteToken configured but NO remoteHost -> the token is NEVER
# delivered via env, so it can't pair with an ambient host (config/env remoteHost) and
# transmit off-pin. cookiePath present so oracle still runs; env.log must stay EMPTY.
printf '{ "ultraOracle": { "remoteToken": "orphan-tok", "cookiePath": "%s" } }\n' "$ck" > "$tmp/.claude/busdriver.json"
: > "$tmp/argv.log"; : > "$tmp/env.log"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/rho.md" --mode blocking)"
[ "$st" = "ok" ] || { echo "FAIL rho status got '$st'"; FAIL=1; }
[ -z "$(cat "$tmp/env.log")" ] || { echo "FAIL token delivered via env with no remoteHost"; FAIL=1; }
grep -qx -- "--browser-cookie-path" "$tmp/argv.log" || { echo "FAIL cookiePath path not taken (no remoteHost)"; FAIL=1; }

# remoteHost set, remoteToken EMPTY -> FAIL CLOSED ('error'), oracle NOT invoked. Oracle
# resolves its token as cliToken ?? config.browser.remoteToken ?? ORACLE_REMOTE_TOKEN,
# so proceeding could silently authenticate a transmission via oracle's ambient token —
# outside busdriver's USER-config trust boundary. argv.log must stay empty (never called).
printf '{ "ultraOracle": { "remoteHost": "127.0.0.1:8765" } }\n' > "$tmp/.claude/busdriver.json"
: > "$tmp/argv.log"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/rh2.md" --mode blocking 2> "$tmp/rh2.err")"
[ "$st" = "error" ] || { echo "FAIL rh2 empty-token should fail closed got '$st'"; FAIL=1; }
[ -s "$tmp/argv.log" ] && { echo "FAIL empty remoteToken must not invoke oracle"; FAIL=1; }
grep -qi "remoteToken empty" "$tmp/rh2.err" || { echo "FAIL empty remoteToken message missing"; FAIL=1; }

# token containment (secret hygiene): a token with spaces + shell metacharacters must be
# delivered VERBATIM via the ORACLE_REMOTE_TOKEN env, and must NEVER appear on argv
# (ps-visible) or in stderr (no-secrets-in-logs).
# shellcheck disable=SC2016  # $(id)/backticks are DELIBERATELY literal — an injection probe, not expansion
tok='a b;$(id)`x` &|>'
printf '{ "ultraOracle": { "remoteHost": "127.0.0.1:8765", "remoteToken": "%s" } }\n' "$tok" > "$tmp/.claude/busdriver.json"
: > "$tmp/argv.log"; : > "$tmp/env.log"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/rh3.md" --mode blocking 2> "$tmp/rh3.err")"
[ "$st" = "ok" ] || { echo "FAIL rh3 status got '$st'"; FAIL=1; }
[ "$(cat "$tmp/env.log")" = "$tok" ] || { echo "FAIL token not delivered verbatim via env"; FAIL=1; }
grep -qF -- "$tok" "$tmp/argv.log" && { echo "FAIL token value leaked to argv"; FAIL=1; }
grep -qF -- "$tok" "$tmp/rh3.err" && { echo "FAIL token value leaked to stderr"; FAIL=1; }
rm -f "$tmp/.claude/busdriver.json"
unset ULTRA_ORACLE_MOCK_MODE ULTRA_ORACLE_ARGV_OUT ULTRA_ORACLE_ENV_OUT

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

# --surface followed by a flag (no real value) -> fail closed to `error`
# (must NOT consume `--mode` as the surface name and silently skip)
out="$(bash "$CWRAP" --surface --mode blocking --prompt-file "$cwp" --out "$tmp/cr_flagval.md")"
[[ "$out" == "error" ]] || { echo "FAIL consult-run --surface-eats-flag got '$out'"; FAIL=1; }

# --surface-check gate query (used by brainstorming to gate BEFORE writing the design)
out="$(bash "$CWRAP" --surface-check)"                       # no name -> error
[[ "$out" == "error" ]] || { echo "FAIL surface-check no-name got '$out'"; FAIL=1; }
out="$(bash "$CWRAP" --surface-check brainstorming)"         # config disabled -> disabled
[[ "$out" == "disabled" ]] || { echo "FAIL surface-check disabled got '$out'"; FAIL=1; }

# --surface brainstorming, config disabled (no busdriver.json) -> skipped:disabled
out="$(bash "$CWRAP" --surface brainstorming --mode blocking --prompt-file "$cwp" --out "$tmp/cr_dis.md")"
[[ "$out" == "skipped:disabled" ]] || { echo "FAIL consult-run disabled surface got '$out'"; FAIL=1; }

# enable the brainstorming surface via USER config for the remaining surface-gated cases
printf '{"ultraOracle":{"brainstorming":{"enabled":true}}}' > "$tmp/.claude/busdriver.json"

# --surface-check now reports enabled
out="$(bash "$CWRAP" --surface-check brainstorming)"
[[ "$out" == "enabled" ]] || { echo "FAIL surface-check enabled got '$out'"; FAIL=1; }

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

# --- failure-hint surfacing (#340): ABE / login signature -> actionable message ---
# Swap in a stub that emits oracle's REAL "session not detected / Login button
# detected" signature on STDOUT (captured to $out.err), then fails. Done LAST so it
# does not clobber the functional stub the wrapper tests above rely on.
cat > "$tmp/bin/oracle" <<'STUB'
#!/bin/bash
out=""
while [ $# -gt 0 ]; do case "$1" in --write-output) out="$2"; shift 2;; *) shift;; esac; done
echo "ERROR: ChatGPT session not detected. Login button detected on page."
exit 7
STUB
chmod +x "$tmp/bin/oracle"
rm -f "$tmp/.claude/busdriver.json"

# blocking mode: status 'error' AND the actionable hint reaches stderr (not just the
# generic "captured at ...err" pointer).
st="$(ultra_oracle_consult --prompt hi --out "$tmp/hint.md" --mode blocking 2> "$tmp/hint.err")"
[ "$st" = "error" ] || { echo "FAIL hint blocking status got '$st'"; FAIL=1; }
grep -qi "sign in to the" "$tmp/hint.err" || { echo "FAIL blocking hint not surfaced to stderr"; FAIL=1; }

# The recovery hint is TRANSPORT-CONDITIONAL (ADR 0020 review): attach mode has one
# operator-visible browser to sign into; remoteHost/cookiePath/profile do not, so naming
# the attached window there would misdirect. Assert both branches.
printf '{ "ultraOracle": { "attachRunning": true } }\n' > "$tmp/.claude/busdriver.json"
_ULTRA_ORACLE_PREFLIGHT="$tmp/bin/preflight-ok.sh"   # stub: never launch a real Chrome
st="$(ultra_oracle_consult --prompt hi --out "$tmp/hintA.md" --mode blocking 2> "$tmp/hintA.err")"
_ULTRA_ORACLE_PREFLIGHT="$DIR/scripts/ultra-oracle-attach-preflight.sh"
grep -qi "attached Chrome window" "$tmp/hintA.err" || { echo "FAIL attach-mode hint should name the attached window"; FAIL=1; }
rm -f "$tmp/.claude/busdriver.json"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/hintB.md" --mode blocking 2> "$tmp/hintB.err")"
grep -qi "attached Chrome window" "$tmp/hintB.err" && { echo "FAIL non-attach hint must not name the attached window"; FAIL=1; }
grep -qi "sign in to the browser session this transport uses" "$tmp/hintB.err" || { echo "FAIL non-attach hint missing transport-neutral guidance"; FAIL=1; }

# background mode: adapter persists $out.hint and ultra-oracle-run.sh folds it into the
# FAILED banner (the blueprint-review path that motivated #340). FORCE=1 bypasses the
# surface gate so a disabled config does not short-circuit to NOT_ATTEMPTED.
hwp="$(mktemp)"; printf 'design' > "$hwp"
out="$(bash "$DIR/scripts/ultra-oracle-run.sh" blueprintReview 1 "$hwp" "$tmp/hintbg.md")"
first_line="${out%%$'\n'*}"
[[ "$first_line" == FAILED\ * ]] || { echo "FAIL hint bg first line got '$first_line'"; FAIL=1; }
printf '%s\n' "$first_line" | grep -qi "sign in to the" || { echo "FAIL hint bg banner missing operator action"; FAIL=1; }
[ -f "$tmp/hintbg.md.hint" ] || { echo "FAIL hint file not persisted in bg mode"; FAIL=1; }
rm -f "$hwp"

# wrapper timeout surfaces the hint (#340 race fix): a login/Cloudflare wall manifests AS
# a timeout — oracle emits the signature then hangs past the cap. The background child
# writes .rc=124 + .hint only AFTER _portable_timeout kills oracle, so ultra-oracle-run.sh
# must poll BEYOND the cap and fold the hint into the FAILED [timeout] banner.
cat > "$tmp/bin/oracle" <<'STUB'
#!/bin/bash
echo "ERROR: ChatGPT session not detected. Login button detected on page."
sleep 30
STUB
chmod +x "$tmp/bin/oracle"
twp="$(mktemp)"; printf 'q' > "$twp"
printf '{ "ultraOracle": { "timeoutCapSeconds": 1 } }\n' > "$tmp/.claude/busdriver.json"  # tiny cap -> fast timeout
out="$(bash "$WRAP" council 1 "$twp" "$tmp/wto.md")"
first_line="${out%%$'\n'*}"
[[ "$first_line" == FAILED\ \[timeout\]* ]] || { echo "FAIL wrapper timeout token got '$first_line'"; FAIL=1; }
printf '%s\n' "$first_line" | grep -qi "sign in to the" || { echo "FAIL wrapper timeout banner missing hint"; FAIL=1; }
rm -f "$twp" "$tmp/.claude/busdriver.json"

# --- #458 salvage: harvest a completed-but-hung / empty-verdict response via `oracle session --harvest` ---
# oracle 0.16.0's browser engine can wait out its whole --timeout on a fast response that
# already FINISHED (completion-detection bug). In ATTACH mode the answer is still in the live
# tab, so `oracle session <id> --harvest` recovers it. Salvage must NOT fire outside attach
# mode (no live tab). A self-contained mock that also serves the `session` harvest subcommand.
cat > "$tmp/bin/oracle" <<'STUB'
#!/bin/bash
# Status subcommand: `oracle status --browser-tabs` lists live tabs for the #458 GAP 1 probe.
# Controlled by ULTRA_ORACLE_TABS_MODE (default none). Output mirrors oracle 0.16.0's REAL
# multi-line-block-per-tab shape (verified live): a `- <TABID> <status> …` header followed by
# indented title=/url=/session=/last= lines.
if [ "${1:-}" = "status" ]; then
  _sid="${ULTRA_ORACLE_TEST_SID:-sess-458}"
  _last="recovered from live tab"
  # UNSTABLE: make last= change every second so two consecutive probes never agree -> the stability
  # guard must NEVER fire (models a mid-render completed+partial flit).
  [ "${ULTRA_ORACLE_TABS_UNSTABLE:-0}" = 1 ] && _last="rendering-$(date +%s)"
  case "${ULTRA_ORACLE_TABS_MODE:-none}" in
    completed) printf -- '- CD7A completed model=Pro turns=1 stop=no send=no\n  title=Q\n  url=https://chatgpt.com/c/WEB:abc\n  session=%s\n  last=%s\n' "$_sid" "$_last";;
    running)   printf -- '- CD7A running model=Pro turns=1 stop=no send=no\n  title=Q\n  url=https://chatgpt.com/c/WEB:abc\n  session=%s\n  last=\n' "$_sid";;
    none)      printf '🧿 oracle 0.16.0\nBrowser Tabs 127.0.0.1:55022\n';;   # header only, no tabs
  esac
  exit 0
fi
# Harvest subcommand: `oracle session <id> --harvest [--browser-tab <ref>] --write-output <out>`.
if [ "${1:-}" = "session" ]; then
  out=""; hastab=0
  while [ $# -gt 0 ]; do case "$1" in --write-output) out="$2"; shift 2;; --browser-tab) hastab=1; shift 2;; *) shift;; esac; done
  # #458 GAP 2: model the REAL oracle behavior — a plain `--harvest` (no --browser-tab) can't match
  # the live tab via its WEB: placeholder URL and FAILS; only `--harvest --browser-tab <target-id>`
  # binds and recovers. Under this flag the harvest fails UNLESS the ref was threaded through.
  if [ "${ULTRA_ORACLE_HARVEST_NEEDS_TAB:-0}" = 1 ] && [ "$hastab" = 0 ]; then exit 1; fi
  case "${ULTRA_ORACLE_SALVAGE_MODE:-ok}" in
    ok)          [ -n "$out" ] && printf 'SALVAGED VERDICT: recovered from live tab\n' > "$out"; exit 0;;
    fail)        exit 1;;          # dead tab ("No ChatGPT tab matched") -> nothing harvested
    partialfail) [ -n "$out" ] && printf 'harvest fragment truncated mid-stream\n' > "$out"; exit 1;;  # wrote >8 bytes THEN failed
  esac
fi
# Main run: announce the session id (parsed by _ultra_oracle_salvage from "Session: <id>"),
# then reproduce a completion signature or exit empty per mode. The id is overridable so a test
# can feed a MALFORMED one (leading dash / internal space) and assert salvage fails closed.
echo "Session: ${ULTRA_ORACLE_TEST_SID:-sess-458}"
mout=""
while [ $# -gt 0 ]; do case "$1" in --write-output) mout="$2"; shift 2;; *) shift;; esac; done
_hungsig() {
  # A streaming tick reporting content STABLE for 3m (matches the #458 real-world log), then the
  # heartbeat stuck in the waiting branch — BOTH signals the watchdog requires.
  echo "[browser] ChatGPT thinking - status=response streaming; last change 3m 0s ago; source=inline"
  echo "[browser] Waiting for ChatGPT response - no thinking status detected yet."
  echo "[browser] Waiting for ChatGPT response - no thinking status detected yet."
}
case "${ULTRA_ORACLE_MOCK_MODE:-empty}" in
  empty)        exit 0;;           # exit 0, no verdict written (browser extraction no-op)
  hung)         _hungsig; sleep 30;;   # completed-but-hung: stream, then stuck in the waiting branch
  hungwrote)    # oracle wrote something to --write-output (possibly a NON-atomic partial), THEN
                # the heartbeat still shows the hung signature. Salvage must DISCARD this and
                # re-harvest the tab — never trust oracle's $out.
                [ -n "$mout" ] && printf 'ORACLE PARTIAL WRITE do not trust\n' > "$mout"
                _hungsig; sleep 30;;
  hungnostream) sleep 30;;         # hangs WITHOUT ever streaming -> no hung signature -> hard cap only
  hungnostreamlong) sleep 300;;    # #458 GAP 1: no streaming AND outlives the test window, so ONLY the
                                   # tab-status probe (not a self-exit / empty-salvage race) can recover it
  hungactive)   # ACTIVE stream: the streaming indicator keeps returning, with only single transient
                # null polls between streaming lines. Each streaming line resets the waiting counter,
                # so it never reaches 2 sustained ticks -> the watchdog must NOT early-exit.
                for _ in 1 2 3 4 5; do
                  echo "[browser] ChatGPT thinking - status=response streaming; last change 1s ago; source=inline"
                  echo "[browser] Waiting for ChatGPT response - no thinking status detected yet."
                done
                sleep 30;;
esac
STUB
chmod +x "$tmp/bin/oracle"
_ULTRA_ORACLE_PREFLIGHT="$tmp/bin/preflight-ok.sh"
printf '{ "ultraOracle": { "attachRunning": true } }\n' > "$tmp/.claude/busdriver.json"

# blocking, exit-0-but-empty verdict + attach -> salvage harvests (oracle concluded, safe) -> 'ok'
export ULTRA_ORACLE_MOCK_MODE=empty ULTRA_ORACLE_SALVAGE_MODE=ok
st="$(ultra_oracle_consult --prompt hi --out "$tmp/sv1.md" --mode blocking)"
[[ "$st" = "ok" ]] || { echo "FAIL salvage empty->ok got '$st'"; FAIL=1; }
grep -q "SALVAGED VERDICT" "$tmp/sv1.md" || { echo "FAIL salvage empty: harvested body missing"; FAIL=1; }

# blocking HARD-CAP timeout must NOT salvage (cap fires before the hung signature is confirmed ->
# ambiguous, could be mid-stream) -> stays 'timeout'. A 1s cap is reached (rc 124) well before the
# 45s default HUNG_GRACE, so the #481 watchdog can never confirm-hung here.
export ULTRA_ORACLE_MOCK_MODE=hung ULTRA_ORACLE_SALVAGE_MODE=ok
st="$(ultra_oracle_consult --prompt hi --out "$tmp/sv2.md" --mode blocking --timeout-cap-seconds 1)"
[[ "$st" = "timeout" ]] || { echo "FAIL blocking timeout must not salvage got '$st'"; FAIL=1; }
grep -q "SALVAGED" "$tmp/sv2.md" 2>/dev/null && { echo "FAIL blocking timeout salvaged (should not)"; FAIL=1; }

# #481: blocking + attach + CONFIRMED completed-but-hung (streamed then stuck) MUST salvage -> 'ok'.
# This is the exact failure #458 fixed for background mode but MISSED for the blocking consult path
# (brainstorming / writing-plans / ultraoracle). HUNG_GRACE=0 arms the watchdog as soon as the
# stream-then-wait signature is captured, so the 120s cap is never approached — a 'timeout' here
# would mean the watchdog is still not wired into blocking mode. Salvage re-reads the live tab.
export ULTRA_ORACLE_MOCK_MODE=hung ULTRA_ORACLE_SALVAGE_MODE=ok ULTRA_ORACLE_HUNG_GRACE=0
st="$(ultra_oracle_consult --prompt hi --out "$tmp/sv2b.md" --mode blocking --timeout-cap-seconds 120)"
[[ "$st" = "ok" ]] || { echo "FAIL blocking attach completed-but-hung should salvage->ok got '$st'"; FAIL=1; }
grep -q "SALVAGED VERDICT" "$tmp/sv2b.md" || { echo "FAIL blocking salvage harvested body missing"; FAIL=1; }
unset ULTRA_ORACLE_HUNG_GRACE

# #481, tab-status probe variant of the sv2b case: sv2b above exercises the STREAMING heuristic
# (_hungsig lines), which never sets _UORA_CONFIRMED_REF. This covers the OTHER completed-but-hung
# signal — the tab-status probe (#458 GAP 1) — in BLOCKING mode specifically, proving the confirmed
# tab reference survives the command-substitution SUBSHELL this PR introduces for blocking attach
# runs (_UORA_CONFIRMED_REF cannot cross a subshell by variable; the subshell prints it on stdout,
# see the watched-run invocation below `unset ULTRA_ORACLE_HUNG_GRACE` further down). hungnostreamlong
# never streams (no heartbeat), so only the tab probe can recover it; HARVEST_NEEDS_TAB=1 makes the
# harvest FAIL unless salvage receives the propagated --browser-tab ref (fallback rediscovery would
# also need TABS_MODE=completed to succeed, so this alone doesn't distinguish propagation from
# rediscovery — the point is the subshell path is reachable and produces the same 'ok'/SALVAGED
# outcome as the background GAP1 case above).
export ULTRA_ORACLE_MOCK_MODE=hungnostreamlong ULTRA_ORACLE_SALVAGE_MODE=ok ULTRA_ORACLE_HUNG_GRACE=0 ULTRA_ORACLE_TABS_MODE=completed ULTRA_ORACLE_HARVEST_NEEDS_TAB=1
st="$(ultra_oracle_consult --prompt hi --out "$tmp/sv2c.md" --mode blocking --timeout-cap-seconds 120)"
[[ "$st" = "ok" ]] || { echo "FAIL blocking tab-status salvage should be ok got '$st'"; FAIL=1; }
grep -q "SALVAGED VERDICT" "$tmp/sv2c.md" || { echo "FAIL blocking tab-status salvage harvested body missing"; FAIL=1; }
unset ULTRA_ORACLE_HUNG_GRACE ULTRA_ORACLE_TABS_MODE ULTRA_ORACLE_HARVEST_NEEDS_TAB

# HIGH#1 (harvest exit 0 but wrote nothing = dead tab): exit-0-empty + failed harvest -> 'error'.
export ULTRA_ORACLE_MOCK_MODE=empty ULTRA_ORACLE_SALVAGE_MODE=fail
st="$(ultra_oracle_consult --prompt hi --out "$tmp/sv3.md" --mode blocking)"
[ "$st" = "error" ] || { echo "FAIL empty + failed-harvest should be 'error' got '$st'"; FAIL=1; }

# HIGH#1 (round 2): the harvest writes a >8-byte fragment then EXITS NON-ZERO. The harvest-rc
# guard must reject it despite the fragment passing the byte floor -> 'error', fragment cleared.
export ULTRA_ORACLE_MOCK_MODE=empty ULTRA_ORACLE_SALVAGE_MODE=partialfail
st="$(ultra_oracle_consult --prompt hi --out "$tmp/sv3c.md" --mode blocking)"
[ "$st" = "error" ] || { echo "FAIL harvest-fragment-then-nonzero must be 'error' got '$st'"; FAIL=1; }
grep -q "harvest fragment" "$tmp/sv3c.md" 2>/dev/null && { echo "FAIL harvest fragment falsely accepted despite non-zero rc"; FAIL=1; }

# NON-attach: salvage must NOT fire (no discoverable live tab). empty-verdict -> 'error' as before.
rm -f "$tmp/.claude/busdriver.json"
export ULTRA_ORACLE_MOCK_MODE=empty ULTRA_ORACLE_SALVAGE_MODE=ok
st="$(ultra_oracle_consult --prompt hi --out "$tmp/sv4.md" --mode blocking)"
[ "$st" = "error" ] || { echo "FAIL non-attach empty must not salvage got '$st'"; FAIL=1; }

# background watchdog (#458): attach + hung signature -> EARLY exit (rc 125, not full cap) ->
# salvage -> .rc=0. Cap 120s but the watchdog must fire in seconds; HUNG_GRACE=0 arms it as soon
# as the signature is captured. No .rc within 30s would mean the watchdog failed to early-exit.
printf '{ "ultraOracle": { "attachRunning": true } }\n' > "$tmp/.claude/busdriver.json"
export ULTRA_ORACLE_MOCK_MODE=hung ULTRA_ORACLE_SALVAGE_MODE=ok ULTRA_ORACLE_HUNG_GRACE=0
st="$(ultra_oracle_consult --prompt hi --out "$tmp/sv5.md" --mode background --timeout-cap-seconds 120)"
[ "$st" = "dispatched" ] || { echo "FAIL bg salvage dispatch got '$st'"; FAIL=1; }
_w=0; while [ ! -f "$tmp/sv5.md.rc" ] && [ "$_w" -lt 30 ]; do sleep 1; _w=$((_w + 1)); done
if [ -f "$tmp/sv5.md.rc" ]; then
  [ "$(cat "$tmp/sv5.md.rc" 2>/dev/null)" = "0" ] || { echo "FAIL bg salvage .rc not 0 got '$(cat "$tmp/sv5.md.rc" 2>/dev/null)'"; FAIL=1; }
  grep -q "SALVAGED VERDICT" "$tmp/sv5.md" || { echo "FAIL bg salvage harvested body missing"; FAIL=1; }
else
  echo "FAIL bg watchdog did not early-exit within 30s (would have waited the 120s cap)"; FAIL=1
fi

# #458 GAP 1 (the merged fix's blind spot): a FAST response that NEVER streams -> zero
# "response streaming" heartbeats -> the streaming heuristic can never fire. The tab-status probe
# (oracle's OWN `status --browser-tabs` reporting the tab `completed`) MUST early-exit (125) ->
# salvage -> .rc=0. hungnostreamlong sleeps 300s WITHOUT emitting any heartbeat (so it can neither
# self-exit into the empty-salvage path nor trip the streaming heuristic within the window — ONLY the
# tab probe can recover it); TABS_MODE=completed makes oracle's tab listing report our session done.
# HARVEST_NEEDS_TAB=1 additionally proves GAP 2 end-to-end: the harvest fails UNLESS salvage threaded
# the tab's target-id through as --browser-tab. So .rc=0 iff BOTH gaps are fixed (probe fires AND ref
# binds). Cap 120s but recovery must land within ~30s. (Verified failing when the probe is disabled.)
export ULTRA_ORACLE_MOCK_MODE=hungnostreamlong ULTRA_ORACLE_SALVAGE_MODE=ok ULTRA_ORACLE_HUNG_GRACE=0 ULTRA_ORACLE_TABS_MODE=completed ULTRA_ORACLE_HARVEST_NEEDS_TAB=1
st="$(ultra_oracle_consult --prompt hi --out "$tmp/sv5t.md" --mode background --timeout-cap-seconds 120)"
_w=0; while [ ! -f "$tmp/sv5t.md.rc" ] && [ "$_w" -lt 30 ]; do sleep 1; _w=$((_w + 1)); done
if [ -f "$tmp/sv5t.md.rc" ]; then
  [ "$(cat "$tmp/sv5t.md.rc" 2>/dev/null)" = "0" ] || { echo "FAIL bg tab-status salvage .rc not 0 got '$(cat "$tmp/sv5t.md.rc" 2>/dev/null)'"; FAIL=1; }
  grep -q "SALVAGED VERDICT" "$tmp/sv5t.md" || { echo "FAIL bg tab-status salvage harvested body missing"; FAIL=1; }
else
  echo "FAIL bg tab-status watchdog did not early-exit within 30s (fast-response GAP 1 unfixed)"; FAIL=1
fi
unset ULTRA_ORACLE_HUNG_GRACE ULTRA_ORACLE_TABS_MODE ULTRA_ORACLE_HARVEST_NEEDS_TAB

# NEGATIVE guard for the tab-status probe: a fast NO-stream hang whose tab is NOT completed
# (TABS_MODE=running) must NOT early-exit — it runs to the hard cap (.rc=124), no salvage. Proves
# the probe only fires on oracle's authoritative `completed`, never on any live-tab presence.
export ULTRA_ORACLE_MOCK_MODE=hungnostream ULTRA_ORACLE_SALVAGE_MODE=ok ULTRA_ORACLE_HUNG_GRACE=0 ULTRA_ORACLE_TABS_MODE=running
_t0="$(date +%s)"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/sv5n.md" --mode background --timeout-cap-seconds 6)"
_w=0; while [ ! -f "$tmp/sv5n.md.rc" ] && [ "$_w" -lt 20 ]; do sleep 1; _w=$((_w + 1)); done
_elapsed=$(( $(date +%s) - _t0 ))
if [ -f "$tmp/sv5n.md.rc" ]; then
  [ "$(cat "$tmp/sv5n.md.rc" 2>/dev/null)" = "124" ] || { echo "FAIL bg tab-status running should hard-cap 124 got '$(cat "$tmp/sv5n.md.rc" 2>/dev/null)'"; FAIL=1; }
  grep -q "SALVAGED" "$tmp/sv5n.md" 2>/dev/null && { echo "FAIL bg tab-status running salvaged a non-completed tab"; FAIL=1; }
  [ "$_elapsed" -ge 5 ] || { echo "FAIL bg tab-status running exited early (${_elapsed}s, expected ~cap 6s)"; FAIL=1; }
else
  echo "FAIL bg tab-status running never wrote .rc"; FAIL=1
fi
unset ULTRA_ORACLE_TABS_MODE

# STABILITY GUARD (PR #460 review, HIGH): a `completed` tab whose last= CHANGES every probe (a
# mid-render partial flit) must NOT early-exit — the guard requires two consecutive probes to agree.
# TABS_UNSTABLE makes the mock's last= differ each second, so stability is never reached -> hard cap
# .rc=124, no salvage. cap=20 gives several ~15s-apart probes without agreement.
export ULTRA_ORACLE_MOCK_MODE=hungnostreamlong ULTRA_ORACLE_SALVAGE_MODE=ok ULTRA_ORACLE_HUNG_GRACE=0 ULTRA_ORACLE_TABS_MODE=completed ULTRA_ORACLE_TABS_UNSTABLE=1
_t0="$(date +%s)"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/sv5s.md" --mode background --timeout-cap-seconds 20)"
_w=0; while [ ! -f "$tmp/sv5s.md.rc" ] && [ "$_w" -lt 40 ]; do sleep 1; _w=$((_w + 1)); done
if [ -f "$tmp/sv5s.md.rc" ]; then
  [ "$(cat "$tmp/sv5s.md.rc" 2>/dev/null)" = "124" ] || { echo "FAIL unstable-last should hard-cap 124 got '$(cat "$tmp/sv5s.md.rc" 2>/dev/null)'"; FAIL=1; }
  grep -q "SALVAGED" "$tmp/sv5s.md" 2>/dev/null && { echo "FAIL unstable-last early-killed on a flickering answer"; FAIL=1; }
else
  echo "FAIL unstable-last never wrote .rc"; FAIL=1
fi
unset ULTRA_ORACLE_TABS_MODE ULTRA_ORACLE_TABS_UNSTABLE

# NO-STREAM GATE (PR #460 review, HIGH — truncated preview trap): the tab probe is confined to the
# never-streamed signature (streamed==0). A response that DID stream must be left to the streaming
# heuristic even if its tab reports `completed`, because oracle's ~120-char `last=` preview can look
# stable while a long answer is still growing. hungactive streams (laststream=1) with only 1s
# stability, so the streaming heuristic does NOT fire; TABS_MODE=completed would make an UNGATED tab
# probe fire and harvest a still-growing answer. Correct behavior: gated out -> hard cap .rc=124.
export ULTRA_ORACLE_MOCK_MODE=hungactive ULTRA_ORACLE_SALVAGE_MODE=ok ULTRA_ORACLE_HUNG_GRACE=0 ULTRA_ORACLE_TABS_MODE=completed
_t0="$(date +%s)"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/sv5g.md" --mode background --timeout-cap-seconds 8)"
_w=0; while [ ! -f "$tmp/sv5g.md.rc" ] && [ "$_w" -lt 20 ]; do sleep 1; _w=$((_w + 1)); done
_elapsed=$(( $(date +%s) - _t0 ))
if [ -f "$tmp/sv5g.md.rc" ]; then
  [ "$(cat "$tmp/sv5g.md.rc" 2>/dev/null)" = "124" ] || { echo "FAIL no-stream-gate streaming+completed should hard-cap 124 got '$(cat "$tmp/sv5g.md.rc" 2>/dev/null)'"; FAIL=1; }
  grep -q "SALVAGED" "$tmp/sv5g.md" 2>/dev/null && { echo "FAIL no-stream-gate tab-probe fired on a streaming response"; FAIL=1; }
  [ "$_elapsed" -ge 7 ] || { echo "FAIL no-stream-gate exited early (${_elapsed}s, expected ~cap 8s)"; FAIL=1; }
else
  echo "FAIL no-stream-gate never wrote .rc"; FAIL=1
fi
unset ULTRA_ORACLE_TABS_MODE

# background hung + harvest FAILS -> confirmed-hung (125) that salvage can't recover normalizes
# to timeout -> .rc=124, and $out is left clean (no partial).
export ULTRA_ORACLE_MOCK_MODE=hung ULTRA_ORACLE_SALVAGE_MODE=partialfail ULTRA_ORACLE_HUNG_GRACE=0
st="$(ultra_oracle_consult --prompt hi --out "$tmp/sv5b.md" --mode background --timeout-cap-seconds 120)"
_w=0; while [ ! -f "$tmp/sv5b.md.rc" ] && [ "$_w" -lt 30 ]; do sleep 1; _w=$((_w + 1)); done
if [ -f "$tmp/sv5b.md.rc" ]; then
  [ "$(cat "$tmp/sv5b.md.rc" 2>/dev/null)" = "124" ] || { echo "FAIL bg hung+failed-harvest .rc should be 124 got '$(cat "$tmp/sv5b.md.rc" 2>/dev/null)'"; FAIL=1; }
  grep -q "harvest fragment" "$tmp/sv5b.md" 2>/dev/null && { echo "FAIL bg hung+failed-harvest left a partial in \$out"; FAIL=1; }
else
  echo "FAIL bg hung+failed-harvest never wrote .rc"; FAIL=1
fi

# NON-ATOMIC WRITE GUARD (PR-review HIGH): oracle left a partial in $out just before termination.
# Salvage must DISCARD it and re-harvest — never promote oracle's possibly-truncated $out. With a
# working harvest the tab's complete answer replaces the partial (.rc=0, harvest body, NOT the
# partial); with a FAILED harvest it fails CLOSED to timeout (.rc=124) and the partial is cleared.
export ULTRA_ORACLE_MOCK_MODE=hungwrote ULTRA_ORACLE_SALVAGE_MODE=ok ULTRA_ORACLE_HUNG_GRACE=0
st="$(ultra_oracle_consult --prompt hi --out "$tmp/sv6r.md" --mode background --timeout-cap-seconds 120)"
_w=0; while [ ! -f "$tmp/sv6r.md.rc" ] && [ "$_w" -lt 30 ]; do sleep 1; _w=$((_w + 1)); done
if [ -f "$tmp/sv6r.md.rc" ]; then
  [ "$(cat "$tmp/sv6r.md.rc" 2>/dev/null)" = "0" ] || { echo "FAIL non-atomic-write .rc should be 0 got '$(cat "$tmp/sv6r.md.rc" 2>/dev/null)'"; FAIL=1; }
  grep -q "SALVAGED VERDICT" "$tmp/sv6r.md" || { echo "FAIL non-atomic-write: harvest body missing"; FAIL=1; }
  grep -q "ORACLE PARTIAL WRITE" "$tmp/sv6r.md" && { echo "FAIL non-atomic-write: oracle partial was NOT discarded"; FAIL=1; }
else
  echo "FAIL non-atomic-write never wrote .rc"; FAIL=1
fi
# ...and with a failing harvest the partial is discarded and it fails closed to timeout.
export ULTRA_ORACLE_MOCK_MODE=hungwrote ULTRA_ORACLE_SALVAGE_MODE=fail ULTRA_ORACLE_HUNG_GRACE=0
st="$(ultra_oracle_consult --prompt hi --out "$tmp/sv6f.md" --mode background --timeout-cap-seconds 120)"
_w=0; while [ ! -f "$tmp/sv6f.md.rc" ] && [ "$_w" -lt 30 ]; do sleep 1; _w=$((_w + 1)); done
if [ -f "$tmp/sv6f.md.rc" ]; then
  [ "$(cat "$tmp/sv6f.md.rc" 2>/dev/null)" = "124" ] || { echo "FAIL non-atomic-write+failed-harvest .rc should be 124 got '$(cat "$tmp/sv6f.md.rc" 2>/dev/null)'"; FAIL=1; }
  grep -q "ORACLE PARTIAL WRITE" "$tmp/sv6f.md" 2>/dev/null && { echo "FAIL non-atomic-write+failed-harvest: partial not cleared"; FAIL=1; }
else
  echo "FAIL non-atomic-write+failed-harvest never wrote .rc"; FAIL=1
fi

# SID VALIDATION (PR-review MEDIUM, option-injection): a malformed "Session: -danger" id must be
# REJECTED (leading '-' would be parsed as an oracle option) — salvage fails closed, so a confirmed
# hung run normalizes to timeout .rc=124 rather than harvesting with an injected argument.
export ULTRA_ORACLE_MOCK_MODE=hung ULTRA_ORACLE_SALVAGE_MODE=ok ULTRA_ORACLE_HUNG_GRACE=0 ULTRA_ORACLE_TEST_SID="-danger"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/svsid.md" --mode background --timeout-cap-seconds 120)"
_w=0; while [ ! -f "$tmp/svsid.md.rc" ] && [ "$_w" -lt 30 ]; do sleep 1; _w=$((_w + 1)); done
if [ -f "$tmp/svsid.md.rc" ]; then
  [ "$(cat "$tmp/svsid.md.rc" 2>/dev/null)" = "124" ] || { echo "FAIL malformed sid should reject -> 124 got '$(cat "$tmp/svsid.md.rc" 2>/dev/null)'"; FAIL=1; }
  grep -q "SALVAGED" "$tmp/svsid.md" 2>/dev/null && { echo "FAIL malformed sid was harvested"; FAIL=1; }
else
  echo "FAIL malformed sid never wrote .rc"; FAIL=1
fi
unset ULTRA_ORACLE_TEST_SID

# HIGH#1 CORE: background ATTACH hard cap with NO hung signature (hungnostream) must NOT salvage
# -> runs to the cap and reports .rc=124 (a still-streaming response is never harvested as a
# partial). cap=6, HUNG_GRACE=0: an over-eager salvage would flip this to 0.
export ULTRA_ORACLE_MOCK_MODE=hungnostream ULTRA_ORACLE_SALVAGE_MODE=ok ULTRA_ORACLE_HUNG_GRACE=0
_t0="$(date +%s)"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/sv7.md" --mode background --timeout-cap-seconds 6)"
_w=0; while [ ! -f "$tmp/sv7.md.rc" ] && [ "$_w" -lt 20 ]; do sleep 1; _w=$((_w + 1)); done
_elapsed=$(( $(date +%s) - _t0 ))
if [ -f "$tmp/sv7.md.rc" ]; then
  [ "$(cat "$tmp/sv7.md.rc" 2>/dev/null)" = "124" ] || { echo "FAIL bg attach hard-cap should be 124 got '$(cat "$tmp/sv7.md.rc" 2>/dev/null)'"; FAIL=1; }
  grep -q "SALVAGED" "$tmp/sv7.md" 2>/dev/null && { echo "FAIL bg attach hard-cap salvaged an ambiguous timeout"; FAIL=1; }
  [ "$_elapsed" -ge 5 ] || { echo "FAIL bg attach hard-cap exited early (${_elapsed}s, expected ~cap 6s)"; FAIL=1; }
else
  echo "FAIL bg attach hard-cap never wrote .rc"; FAIL=1
fi
# CONTENT-STABILITY GUARD (PR-review HIGH): a waiting heartbeat that follows RECENT content change
# (last change 2s) is a transient null, NOT completion — the watchdog must NOT early-exit. cap=6,
# HUNG_GRACE=0: an over-eager watchdog would flip this to a fast 125/salvage; correct behavior runs
# to the cap (.rc=124, ~6s) because the stability floor (default 45s) is not met.
export ULTRA_ORACLE_MOCK_MODE=hungactive ULTRA_ORACLE_SALVAGE_MODE=ok ULTRA_ORACLE_HUNG_GRACE=0
_t0="$(date +%s)"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/sv8.md" --mode background --timeout-cap-seconds 6)"
_w=0; while [ ! -f "$tmp/sv8.md.rc" ] && [ "$_w" -lt 20 ]; do sleep 1; _w=$((_w + 1)); done
_elapsed=$(( $(date +%s) - _t0 ))
if [ -f "$tmp/sv8.md.rc" ]; then
  [ "$(cat "$tmp/sv8.md.rc" 2>/dev/null)" = "124" ] || { echo "FAIL active-stream should hard-cap 124 got '$(cat "$tmp/sv8.md.rc" 2>/dev/null)'"; FAIL=1; }
  grep -q "SALVAGED" "$tmp/sv8.md" 2>/dev/null && { echo "FAIL active-stream early-killed + salvaged a still-changing response"; FAIL=1; }
  [ "$_elapsed" -ge 5 ] || { echo "FAIL active-stream exited early (${_elapsed}s, expected ~cap 6s)"; FAIL=1; }
else
  echo "FAIL active-stream never wrote .rc"; FAIL=1
fi
unset ULTRA_ORACLE_MOCK_MODE ULTRA_ORACLE_SALVAGE_MODE ULTRA_ORACLE_HUNG_GRACE
_ULTRA_ORACLE_PREFLIGHT="$DIR/scripts/ultra-oracle-attach-preflight.sh"
rm -f "$tmp/.claude/busdriver.json"

# early-kill GATING (PR-review HIGH): the hung-signature early-exit must fire ONLY when salvage
# can recover (attach mode). In NON-attach background mode the same hung signature must NOT cut
# the consult early — there is no live tab to harvest, so it would only truncate a slow
# response. Prove it runs to the hard cap instead of exiting at ~grace. cap=6, grace=0: an
# early-kill bug would land .rc at ~3s; correct gating lands it at ~cap (>=5s).
export ULTRA_ORACLE_MOCK_MODE=hung ULTRA_ORACLE_HUNG_GRACE=0
rm -f "$tmp/.claude/busdriver.json"                        # non-attach (no attachRunning)
_t0="$(date +%s)"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/sv6.md" --mode background --timeout-cap-seconds 6)"
[ "$st" = "dispatched" ] || { echo "FAIL non-attach bg dispatch got '$st'"; FAIL=1; }
_w=0; while [ ! -f "$tmp/sv6.md.rc" ] && [ "$_w" -lt 20 ]; do sleep 1; _w=$((_w + 1)); done
_elapsed=$(( $(date +%s) - _t0 ))
[ -f "$tmp/sv6.md.rc" ] || { echo "FAIL non-attach bg never wrote .rc"; FAIL=1; }
[ "$_elapsed" -ge 5 ] || { echo "FAIL non-attach hung was early-killed (ran ${_elapsed}s, expected ~cap 6s)"; FAIL=1; }
[ "$(cat "$tmp/sv6.md.rc" 2>/dev/null)" = "124" ] || { echo "FAIL non-attach hung .rc should be 124 got '$(cat "$tmp/sv6.md.rc" 2>/dev/null)'"; FAIL=1; }
unset ULTRA_ORACLE_MOCK_MODE ULTRA_ORACLE_HUNG_GRACE

# HIGH#2 (watchdog signal): assert the REAL primitive (_ultra_oracle_hung_signal, sourced from the
# lib — the SAME awk the watchdog calls, so the test cannot drift from the code — CodeRabbit #460)
# directly on crafted heartbeat fixtures. It prints "<waits> <laststable> <laststream> <everstreamed>".
# Covers the reset-on-ANY-active-heartbeat behavior (streaming AND reasoning/tool use), which is what
# prevents an active stream from being cut and a partial harvested, PLUS the MONOTONIC everstreamed.
_sig() { local f; f="$(mktemp)"; printf '%s\n' "$1" > "$f"; _ultra_oracle_hung_signal "$f"; rm -f "$f"; }
# Two waiting ticks BEFORE any active heartbeat, then streaming that keeps going -> waits 0, laststream 1, everstreamed 1.
[ "$(_sig 'Waiting no thinking status detected yet
Waiting no thinking status detected yet
[browser] ChatGPT thinking - status=response streaming; last change 5s ago
[browser] ChatGPT thinking - status=response streaming; last change 5s ago')" = "0 5 1 1" ] \
  || { echo "FAIL hung-signal counts pre-stream waiting ticks"; FAIL=1; }
# Streaming (stable 3m), then two waiting ticks after -> waits 2, laststable 180, laststream 1 (hung).
[ "$(_sig '[browser] ChatGPT thinking - status=response streaming; last change 3m 0s ago
Waiting no thinking status detected yet
Waiting no thinking status detected yet')" = "2 180 1 1" ] \
  || { echo "FAIL hung-signal misses post-stream waiting ticks"; FAIL=1; }
# A later streaming tick RESETS waits -> a response that resumed streaming is not cut (waits 1).
[ "$(_sig '[browser] ChatGPT thinking - status=response streaming; last change 3m 0s ago
Waiting no thinking status detected yet
Waiting no thinking status detected yet
[browser] ChatGPT thinking - status=response streaming; last change 1s ago
Waiting no thinking status detected yet')" = "1 1 1 1" ] \
  || { echo "FAIL hung-signal does not reset on resumed streaming"; FAIL=1; }
# A REASONING/tool-use heartbeat between two waiting ticks ALSO resets waits (regression guard for
# the reset-on-any-active-line fix) AND sets laststream=0 (most recent activity was not streaming) —
# BUT everstreamed stays 1 (it streamed earlier). This is the monotonic-flag guard: the tab probe
# gates on everstreamed==0, so this stream->reasoning->idle case must NOT be treated as never-streamed.
[ "$(_sig '[browser] ChatGPT thinking - status=response streaming; last change 3m 0s ago
Waiting no thinking status detected yet
[browser] ChatGPT thinking - status=reasoning
Waiting no thinking status detected yet')" = "1 180 0 1" ] \
  || { echo "FAIL hung-signal everstreamed not monotonic after reasoning"; FAIL=1; }
# Never streamed at all (reasoning only) -> everstreamed 0 (the tab probe's eligible signature).
[ "$(_sig '[browser] ChatGPT thinking - status=reasoning
Waiting no thinking status detected yet
Waiting no thinking status detected yet')" = "2 0 0 0" ] \
  || { echo "FAIL hung-signal everstreamed should be 0 when never streamed"; FAIL=1; }

# GAP 1/2 primitive (_ultra_oracle_tab_ref): parse oracle's REAL multi-line-block `status
# --browser-tabs` output (verified live 2026-07-23) and return the target-id of the session's
# COMPLETED tab (empty = not completed). Same primitive the watchdog probe AND the salvage call, so
# the test cannot drift from code. Blocks are `- <TARGET-ID> <status> …` headers with indented
# title=/url=/session=/last= lines. Non-empty return = completion signal AND the --browser-tab handle.
# _ultra_oracle_tab_ref returns "<tid>\t<last>"; this helper checks the tid (field 1).
_tab() { local f; f="$(mktemp)"; printf '%s\n' "$1" > "$f"; _ultra_oracle_tab_ref "$f" "$2" | cut -f1; rm -f "$f"; }
# our session `completed` with a non-empty last= -> its target-id (the fast-response recovery
# trigger). Uses the exact real shape incl. the WEB: placeholder URL that motivated GAP 2.
[ "$(_tab '- CD7A completed model=Pro turns=1 stop=no send=no
  title=Confirmation Request
  url=https://chatgpt.com/c/WEB:b207ce9f
  session=verify-458-fix
  last=I received this.' 'verify-458-fix')" = "CD7A" ] \
  || { echo "FAIL tab-ref misses a completed multi-line block"; FAIL=1; }
# same tab but `running` header -> empty (only oracle's authoritative `completed` yields a ref).
[ -z "$(_tab '- CD7A running model=Pro turns=1 stop=no send=no
  session=verify-458-fix
  last=partial so far' 'verify-458-fix')" ] \
  || { echo "FAIL tab-ref fired on a running tab"; FAIL=1; }
# completed but EMPTY last= -> empty (no answer preview yet; don't salvage an empty tab).
[ -z "$(_tab '- CD7A completed model=Pro turns=1 stop=no send=no
  session=verify-458-fix
  last=' 'verify-458-fix')" ] \
  || { echo "FAIL tab-ref fired on an empty last="; FAIL=1; }
# session matched EXACTLY, not by prefix: session=verify-458-fix-2 must NOT match sid verify-458-fix.
[ -z "$(_tab '- CD7A completed model=Pro turns=1 stop=no send=no
  session=verify-458-fix-2
  last=other answer' 'verify-458-fix')" ] \
  || { echo "FAIL tab-ref prefix-matched a different session"; FAIL=1; }
# TWO blocks: a completed tab for a DIFFERENT session, ours only `running` -> empty (status/session
# must come from the SAME block — the core multi-line-block cross-contamination regression guard).
[ -z "$(_tab '- AAAA completed model=Pro turns=1 stop=no send=no
  session=someone-else
  last=their answer
- BBBB running model=Pro turns=1 stop=no send=no
  session=verify-458-fix
  last=' 'verify-458-fix')" ] \
  || { echo "FAIL tab-ref cross-matched status from another block"; FAIL=1; }
# TWO blocks, ours is the completed one (second block) -> ITS target-id (BBBB), not the other's.
[ "$(_tab '- AAAA running model=Pro turns=1 stop=no send=no
  session=someone-else
  last=
- BBBB completed model=Pro turns=1 stop=no send=no
  session=verify-458-fix
  last=here it is' 'verify-458-fix')" = "BBBB" ] \
  || { echo "FAIL tab-ref misses our completed block among several"; FAIL=1; }
# header-only listing (no tabs) -> empty.
[ -z "$(_tab '🧿 oracle 0.16.0
Browser Tabs 127.0.0.1:55022' 'verify-458-fix')" ] || { echo "FAIL tab-ref fired on empty listing"; FAIL=1; }
# AMBIGUOUS (PR #460 HIGH): TWO completed tabs share the session -> FAIL CLOSED (empty), never pick
# one arbitrarily to kill/harvest. Guards the nonce-collision / transient-double-bind case.
[ -z "$(_tab '- AAAA completed model=Pro turns=1 stop=no send=no
  session=verify-458-fix
  last=one answer
- BBBB completed model=Pro turns=1 stop=no send=no
  session=verify-458-fix
  last=other answer' 'verify-458-fix')" ] || { echo "FAIL tab-ref did not fail closed on duplicate-session tabs"; FAIL=1; }
# AMBIGUOUS (Greptile P1, PR #465): ONE completed + ONE running tab share the session -> FAIL CLOSED
# (empty). Counting only completed tabs previously let this through and returned the stale completed
# tab's target-id even though the SAME session has a tab still `running` — the reused-session failure
# mode this guard exists for, just split across statuses instead of two `completed` tabs.
[ -z "$(_tab '- AAAA completed model=Pro turns=1 stop=no send=no
  session=verify-458-fix
  last=stale prior answer
- BBBB running model=Pro turns=1 stop=no send=no
  session=verify-458-fix
  last=' 'verify-458-fix')" ] || { echo "FAIL tab-ref did not fail closed on completed+running duplicate-session tabs"; FAIL=1; }

# P2 (Codex #460): the watched-run signal trap must be bash-3.2-safe — NO BASHPID (unset on macOS
# bash 3.2, aborts under `set -u`). Run a watched `sleep` UNDER `set -u`, TERM it, and assert it
# exits with the signal's conventional code (143) and reaps its child rather than aborting on an
# unbound variable. HUNG_GRACE huge so the early-kill path can't fire — this exercises the SIGNAL arm.
( set -u; ULTRA_ORACLE_HUNG_GRACE=99999 _ultra_oracle_run_watched 60 "$tmp/sigtrap.err" 0 sleep 30 ) &
_sig_wpid=$!
sleep 1                                   # let the trap install + the child start
_sig_child="$(pgrep -P "$_sig_wpid" 2>/dev/null | head -1)"
kill -TERM "$_sig_wpid" 2>/dev/null
_sig_rc=0; wait "$_sig_wpid" || _sig_rc=$?
[ "$_sig_rc" = "143" ] || { echo "FAIL signal trap not bash-3.2-safe / wrong exit under set -u (got '$_sig_rc', want 143)"; FAIL=1; }
if [ -n "$_sig_child" ]; then
  kill -0 "$_sig_child" 2>/dev/null && { echo "FAIL signal trap orphaned the watched child ($_sig_child)"; FAIL=1; }
fi

[[ "$FAIL" = 0 ]] && echo "PASS test-ultra-oracle" || exit 1
