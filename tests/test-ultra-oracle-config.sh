#!/bin/bash
# tests/test-ultra-oracle-config.sh
set -u
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
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
{ "ultraOracle": { "timeoutCapSeconds": 1234,
  "brainstorming": { "enabled": true }, "council": { "enabled": false } } }
JSON
# PROJECT config (repo-controlled): everything here MUST be ignored.
cat > "$tmp/proj/.claude/busdriver.json" <<'JSON'
{ "ultraOracle": { "timeoutCapSeconds": 99999,
  "blueprintReview": { "enabled": true } } }
JSON
# shellcheck source=/dev/null
source "$DIR/scripts/lib/ultra-oracle-config.sh"

# User values win; project config is fully ignored.
[ "$(ultra_oracle_timeout_cap)" = "1234" ] || { echo "FAIL cap user-only"; FAIL=1; }
ultra_oracle_surface_enabled brainstorming || { echo "FAIL user brainstorming enabled"; FAIL=1; }
ultra_oracle_surface_enabled council && { echo "FAIL user council should be off"; FAIL=1; }
# SECURITY: a repo-controlled PROJECT config must NOT enable a surface or change the
# timeout.
ultra_oracle_surface_enabled blueprintReview && { echo "FAIL project must NOT enable surface"; FAIL=1; }
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
ultra_oracle_surface_enabled brainstorming && { echo "FAIL malformed -> off"; FAIL=1; }

# empty USER config -> defaults.
echo '{}' > "$tmp/.claude/busdriver.json"
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

# §8: the legacy-keys notice names removed keys only, never a value, and is silent otherwise.
printf '{"ultraOracle":{"remoteHost":"h","remoteToken":"SECRET-TOKEN-XYZ","timeoutCapSeconds":900}}\n' > "$tmp/.claude/busdriver.json"
n="$(_ultra_oracle_legacy_keys_notice)"
[[ "$n" == *remoteHost*remoteToken* ]] || { echo "FAIL notice does not name both keys: $n"; FAIL=1; }
[[ "$n" != *SECRET-TOKEN-XYZ* && "$n" != *'"h"'* ]] || { echo "FAIL notice leaked a value"; FAIL=1; }
printf '{"ultraOracle":{"timeoutCapSeconds":900,"council":{"enabled":true}}}\n' > "$tmp/.claude/busdriver.json"
[ -z "$(_ultra_oracle_legacy_keys_notice)" ] || { echo "FAIL notice for a clean config"; FAIL=1; }
printf '{"ultraOracle":"nonsense"}\n' > "$tmp/.claude/busdriver.json"
[ -z "$(_ultra_oracle_legacy_keys_notice)" ] || { echo "FAIL notice for a non-object"; FAIL=1; }
rm -f "$tmp/.claude/busdriver.json"
[ -z "$(_ultra_oracle_legacy_keys_notice)" ] || { echo "FAIL notice without a config file"; FAIL=1; }
for g in ultra_oracle_model ultra_oracle_remote_token ultra_oracle_attach_running ultra_oracle_cookie_path; do
  declare -F "$g" >/dev/null && { echo "FAIL removed getter $g still defined"; FAIL=1; }
done

[ "$FAIL" = 0 ] && echo "PASS test-ultra-oracle-config" || exit 1
