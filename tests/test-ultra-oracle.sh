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

[[ "$FAIL" = 0 ]] && echo "PASS test-ultra-oracle" || exit 1
