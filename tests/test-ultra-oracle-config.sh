#!/bin/bash
# tests/test-ultra-oracle-config.sh
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
tmp="$(mktemp -d)"; export HOME="$tmp"; mkdir -p "$tmp/.claude"; cd "$tmp" || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM   # clean up temp dir even if killed mid-run
# Pin env so inherited values can't make the clamp/path assertions host-dependent:
# a stray ULTRA_ORACLE_CAP_CEILING would change the oversized-cap -> 3600 expectation,
# and a stray BUSDRIVER_STATE_DIR would point reads at the wrong config path.
unset ULTRA_ORACLE_CAP_CEILING
export BUSDRIVER_STATE_DIR=".claude"
git init -q .
mkdir -p "$tmp/proj/.claude"; cd "$tmp/proj" || exit 1; git init -q .

# USER config: the ONLY source ultra-oracle reads.
cat > "$tmp/.claude/busdriver.json" <<'JSON'
{ "ultraOracle": { "model": "user-model", "timeoutCapSeconds": 1234,
  "brainstorming": { "enabled": true }, "council": { "enabled": false } } }
JSON
# PROJECT config (repo-controlled): everything here MUST be ignored.
cat > "$tmp/proj/.claude/busdriver.json" <<'JSON'
{ "ultraOracle": { "model": "evil-model", "timeoutCapSeconds": 99999,
  "blueprintReview": { "enabled": true } } }
JSON
# shellcheck source=/dev/null
source "$DIR/scripts/lib/ultra-oracle-config.sh"

# User values win; project config is fully ignored.
[ "$(ultra_oracle_model)" = "user-model" ] || { echo "FAIL model user-only"; FAIL=1; }
[ "$(ultra_oracle_timeout_cap)" = "1234" ] || { echo "FAIL cap user-only"; FAIL=1; }
ultra_oracle_surface_enabled brainstorming || { echo "FAIL user brainstorming enabled"; FAIL=1; }
ultra_oracle_surface_enabled council && { echo "FAIL user council should be off"; FAIL=1; }
# SECURITY: a repo-controlled PROJECT config must NOT enable a surface, change the
# model, or change the timeout.
ultra_oracle_surface_enabled blueprintReview && { echo "FAIL project must NOT enable surface"; FAIL=1; }
[ "$(ultra_oracle_model)" != "evil-model" ] || { echo "FAIL project model leaked"; FAIL=1; }
[ "$(ultra_oracle_timeout_cap)" != "99999" ] || { echo "FAIL project cap leaked"; FAIL=1; }

# timeoutCap validation (USER config): non-numeric -> 900; oversized -> clamp 3600.
cat > "$tmp/.claude/busdriver.json" <<'JSON'
{ "ultraOracle": { "timeoutCapSeconds": "15m" } }
JSON
[ "$(ultra_oracle_timeout_cap 2>/dev/null)" = "900" ] || { echo "FAIL non-numeric cap -> 900"; FAIL=1; }
cat > "$tmp/.claude/busdriver.json" <<'JSON'
{ "ultraOracle": { "timeoutCapSeconds": 99999 } }
JSON
[ "$(ultra_oracle_timeout_cap 2>/dev/null)" = "3600" ] || { echo "FAIL oversized cap -> clamp 3600"; FAIL=1; }
# all-zero cap ("00") must NOT pass through: timeout 0 / alarm 0 disable the timeout.
cat > "$tmp/.claude/busdriver.json" <<'JSON'
{ "ultraOracle": { "timeoutCapSeconds": "00" } }
JSON
[ "$(ultra_oracle_timeout_cap 2>/dev/null)" = "900" ] || { echo "FAIL all-zero cap -> 900"; FAIL=1; }
# leading zeros normalize ("0600" -> "600"), not passed through verbatim.
cat > "$tmp/.claude/busdriver.json" <<'JSON'
{ "ultraOracle": { "timeoutCapSeconds": "0600" } }
JSON
[ "$(ultra_oracle_timeout_cap 2>/dev/null)" = "600" ] || { echo "FAIL leading-zero cap -> 600"; FAIL=1; }
# all-zero CEILING ("00") must reset to 3600, not clamp the cap to 0 (disabled timeout).
cat > "$tmp/.claude/busdriver.json" <<'JSON'
{ "ultraOracle": { "timeoutCapSeconds": 5000 } }
JSON
[ "$(ULTRA_ORACLE_CAP_CEILING=00 ultra_oracle_timeout_cap 2>/dev/null)" = "3600" ] || { echo "FAIL all-zero ceiling -> 3600"; FAIL=1; }
# zero-padded small CEILING must normalize (not be mistaken for 19+ digit overflow):
# ceiling 0000000000000000500 == 500, so a 1000 cap clamps to 500, not 3600.
cat > "$tmp/.claude/busdriver.json" <<'JSON'
{ "ultraOracle": { "timeoutCapSeconds": 1000 } }
JSON
[ "$(ULTRA_ORACLE_CAP_CEILING=0000000000000000500 ultra_oracle_timeout_cap 2>/dev/null)" = "500" ] || { echo "FAIL zero-padded ceiling -> 500"; FAIL=1; }

# malformed USER config -> defaults/off, no crash.
printf '{ this is not json' > "$tmp/.claude/busdriver.json"
[ "$(ultra_oracle_model 2>/dev/null)" = "gpt-5.5-pro" ] || { echo "FAIL malformed -> default model"; FAIL=1; }
ultra_oracle_surface_enabled brainstorming && { echo "FAIL malformed -> off"; FAIL=1; }

# empty USER config -> defaults.
echo '{}' > "$tmp/.claude/busdriver.json"
[ "$(ultra_oracle_model)" = "gpt-5.5-pro" ] || { echo "FAIL default model"; FAIL=1; }
ultra_oracle_surface_enabled blueprintReview && { echo "FAIL empty -> off"; FAIL=1; }

# boolean normalization in USER config: true -> enabled; false -> disabled.
cat > "$tmp/.claude/busdriver.json" <<'JSON'
{ "ultraOracle": { "council": { "enabled": true } } }
JSON
ultra_oracle_surface_enabled council || { echo "FAIL enabled:true -> enabled"; FAIL=1; }
cat > "$tmp/.claude/busdriver.json" <<'JSON'
{ "ultraOracle": { "council": { "enabled": false } } }
JSON
ultra_oracle_surface_enabled council && { echo "FAIL enabled:false -> disabled"; FAIL=1; }

# ultra_oracle_cookie_path: user config only; tilde expansion; empty default.
echo '{}' > "$tmp/.claude/busdriver.json"
[ "$(ultra_oracle_cookie_path)" = "" ] || { echo "FAIL cookiePath empty default"; FAIL=1; }
cat > "$tmp/.claude/busdriver.json" <<JSON
{ "ultraOracle": { "cookiePath": "$tmp/Cookies" } }
JSON
[ "$(ultra_oracle_cookie_path)" = "$tmp/Cookies" ] || { echo "FAIL cookiePath absolute passthrough"; FAIL=1; }
cat > "$tmp/.claude/busdriver.json" <<'JSON'
{ "ultraOracle": { "cookiePath": "~/Library/Cookies" } }
JSON
[ "$(ultra_oracle_cookie_path)" = "$HOME/Library/Cookies" ] || { echo "FAIL cookiePath tilde expansion"; FAIL=1; }
# SECURITY: project config must NOT supply cookiePath (user-only).
cat > "$tmp/.claude/busdriver.json" <<'JSON'
{}
JSON
cat > "$tmp/proj/.claude/busdriver.json" <<'JSON'
{ "ultraOracle": { "cookiePath": "/attacker/Cookies" } }
JSON
[ "$(ultra_oracle_cookie_path)" = "" ] || { echo "FAIL project cookiePath must not leak"; FAIL=1; }

# ultra_oracle_chrome_profile: empty default; tilde expansion; project-isolation.
echo '{}' > "$tmp/.claude/busdriver.json"
[ "$(ultra_oracle_chrome_profile)" = "" ] || { echo "FAIL chromeProfileDir empty default"; FAIL=1; }
cat > "$tmp/.claude/busdriver.json" <<'JSON'
{ "ultraOracle": { "chromeProfileDir": "~/Library/Application Support/Chromium/oracle" } }
JSON
[ "$(ultra_oracle_chrome_profile)" = "$HOME/Library/Application Support/Chromium/oracle" ] || { echo "FAIL chromeProfileDir tilde expansion"; FAIL=1; }
# SECURITY: project config must NOT supply chromeProfileDir (user-only).
echo '{}' > "$tmp/.claude/busdriver.json"
cat > "$tmp/proj/.claude/busdriver.json" <<'JSON'
{ "ultraOracle": { "chromeProfileDir": "/attacker/Profile" } }
JSON
[ "$(ultra_oracle_chrome_profile)" = "" ] || { echo "FAIL project chromeProfileDir must not leak"; FAIL=1; }

# ultra_oracle_remote_host / ultra_oracle_remote_token (#340 serve delegation):
# user config only; empty by default; project config must NOT leak (host = attacker
# redirect; token = handing a branch the serve key).
echo '{}' > "$tmp/.claude/busdriver.json"; echo '{}' > "$tmp/proj/.claude/busdriver.json"
[ "$(ultra_oracle_remote_host)" = "" ] || { echo "FAIL remoteHost empty default"; FAIL=1; }
[ "$(ultra_oracle_remote_token)" = "" ] || { echo "FAIL remoteToken empty default"; FAIL=1; }
cat > "$tmp/.claude/busdriver.json" <<'JSON'
{ "ultraOracle": { "remoteHost": "127.0.0.1:8765", "remoteToken": "s3cr3t-tok" } }
JSON
[ "$(ultra_oracle_remote_host)" = "127.0.0.1:8765" ] || { echo "FAIL remoteHost passthrough"; FAIL=1; }
[ "$(ultra_oracle_remote_token)" = "s3cr3t-tok" ] || { echo "FAIL remoteToken passthrough"; FAIL=1; }
# SECURITY: project config must NOT supply either.
echo '{}' > "$tmp/.claude/busdriver.json"
cat > "$tmp/proj/.claude/busdriver.json" <<'JSON'
{ "ultraOracle": { "remoteHost": "10.0.0.9:9999", "remoteToken": "evil" } }
JSON
[ "$(ultra_oracle_remote_host)" = "" ] || { echo "FAIL project remoteHost must not leak"; FAIL=1; }
[ "$(ultra_oracle_remote_token)" = "" ] || { echo "FAIL project remoteToken must not leak"; FAIL=1; }

[ "$FAIL" = 0 ] && echo "PASS test-ultra-oracle-config" || exit 1
