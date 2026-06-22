#!/bin/bash
# tests/test-oracle-max-config.sh
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
tmp="$(mktemp -d)"; export HOME="$tmp"; mkdir -p "$tmp/.claude"; cd "$tmp" || exit 1
git init -q .
mkdir -p "$tmp/proj/.claude"; cd "$tmp/proj" || exit 1; git init -q .

# USER config: the ONLY source oracle-max reads.
cat > "$tmp/.claude/busdriver.json" <<'JSON'
{ "oracleMax": { "model": "user-model", "timeoutCapSeconds": 1234,
  "brainstorming": { "enabled": true }, "council": { "enabled": false } } }
JSON
# PROJECT config (repo-controlled): everything here MUST be ignored.
cat > "$tmp/proj/.claude/busdriver.json" <<'JSON'
{ "oracleMax": { "model": "evil-model", "timeoutCapSeconds": 99999,
  "blueprintReview": { "enabled": true } } }
JSON
# shellcheck source=/dev/null
source "$DIR/scripts/lib/oracle-max-config.sh"

# User values win; project config is fully ignored.
[ "$(oracle_max_model)" = "user-model" ] || { echo "FAIL model user-only"; FAIL=1; }
[ "$(oracle_max_timeout_cap)" = "1234" ] || { echo "FAIL cap user-only"; FAIL=1; }
oracle_max_surface_enabled brainstorming || { echo "FAIL user brainstorming enabled"; FAIL=1; }
oracle_max_surface_enabled council && { echo "FAIL user council should be off"; FAIL=1; }
# SECURITY: a repo-controlled PROJECT config must NOT enable a surface, change the
# model, or change the timeout.
oracle_max_surface_enabled blueprintReview && { echo "FAIL project must NOT enable surface"; FAIL=1; }
[ "$(oracle_max_model)" != "evil-model" ] || { echo "FAIL project model leaked"; FAIL=1; }
[ "$(oracle_max_timeout_cap)" != "99999" ] || { echo "FAIL project cap leaked"; FAIL=1; }

# timeoutCap validation (USER config): non-numeric -> 900; oversized -> clamp 3600.
cat > "$tmp/.claude/busdriver.json" <<'JSON'
{ "oracleMax": { "timeoutCapSeconds": "15m" } }
JSON
[ "$(oracle_max_timeout_cap 2>/dev/null)" = "900" ] || { echo "FAIL non-numeric cap -> 900"; FAIL=1; }
cat > "$tmp/.claude/busdriver.json" <<'JSON'
{ "oracleMax": { "timeoutCapSeconds": 99999 } }
JSON
[ "$(oracle_max_timeout_cap 2>/dev/null)" = "3600" ] || { echo "FAIL oversized cap -> clamp 3600"; FAIL=1; }

# malformed USER config -> defaults/off, no crash.
printf '{ this is not json' > "$tmp/.claude/busdriver.json"
[ "$(oracle_max_model 2>/dev/null)" = "gpt-5.5-pro" ] || { echo "FAIL malformed -> default model"; FAIL=1; }
oracle_max_surface_enabled brainstorming && { echo "FAIL malformed -> off"; FAIL=1; }

# empty USER config -> defaults.
echo '{}' > "$tmp/.claude/busdriver.json"
[ "$(oracle_max_model)" = "gpt-5.5-pro" ] || { echo "FAIL default model"; FAIL=1; }
oracle_max_surface_enabled blueprintReview && { echo "FAIL empty -> off"; FAIL=1; }

# boolean normalization in USER config: true -> enabled; false -> disabled.
cat > "$tmp/.claude/busdriver.json" <<'JSON'
{ "oracleMax": { "council": { "enabled": true } } }
JSON
oracle_max_surface_enabled council || { echo "FAIL enabled:true -> enabled"; FAIL=1; }
cat > "$tmp/.claude/busdriver.json" <<'JSON'
{ "oracleMax": { "council": { "enabled": false } } }
JSON
oracle_max_surface_enabled council && { echo "FAIL enabled:false -> disabled"; FAIL=1; }

[ "$FAIL" = 0 ] && echo "PASS test-oracle-max-config" || exit 1
