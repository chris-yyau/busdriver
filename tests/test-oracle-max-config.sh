#!/bin/bash
# tests/test-oracle-max-config.sh
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
tmp="$(mktemp -d)"; export HOME="$tmp"; mkdir -p "$tmp/.claude"; cd "$tmp" || exit 1
git init -q .   # so git rev-parse resolves project config (exercises project>user precedence)
# Project config wins over a conflicting user config:
mkdir -p "$tmp/proj/.claude"; cd "$tmp/proj" || exit 1; git init -q .
cat > "$tmp/.claude/busdriver.json" <<'JSON'
{ "oracleMax": { "model": "user-model" } }
JSON
cat > "$tmp/proj/.claude/busdriver.json" <<'JSON'
{ "oracleMax": { "model": "gpt-5.5-pro", "timeoutCapSeconds": 1234,
  "brainstorming": { "enabled": true }, "council": { "enabled": false } } }
JSON
# shellcheck source=/dev/null
source "$DIR/scripts/lib/oracle-max-config.sh"
[ "$(oracle_max_model)" = "gpt-5.5-pro" ] || { echo "FAIL project>user precedence"; FAIL=1; }
[ "$(oracle_max_timeout_cap)" = "1234" ] || { echo "FAIL cap"; FAIL=1; }
oracle_max_surface_enabled brainstorming || { echo "FAIL brainstorming enabled"; FAIL=1; }
oracle_max_surface_enabled council && { echo "FAIL council should be off"; FAIL=1; }
# Contract: field-level fallback (project field, else user field, else built-in default).
# Drop the user config so the malformed/empty cases fall to the BUILT-IN default, not user-model.
rm -f "$tmp/.claude/busdriver.json"
# timeoutCapSeconds validation: non-numeric / zero -> 900 default
cat > "$tmp/proj/.claude/busdriver.json" <<'JSON'
{ "oracleMax": { "timeoutCapSeconds": "15m" } }
JSON
[ "$(oracle_max_timeout_cap 2>/dev/null)" = "900" ] || { echo "FAIL non-numeric cap -> 900"; FAIL=1; }
# malformed JSON -> defaults (no crash)
printf '{ this is not json' > "$tmp/proj/.claude/busdriver.json"
[ "$(oracle_max_model 2>/dev/null)" = "gpt-5.5-pro" ] || { echo "FAIL malformed -> default"; FAIL=1; }
# empty config -> defaults
echo '{}' > "$tmp/proj/.claude/busdriver.json"
[ "$(oracle_max_model)" = "gpt-5.5-pro" ] || { echo "FAIL default model"; FAIL=1; }
oracle_max_surface_enabled blueprintReview && { echo "FAIL default off"; FAIL=1; }
# boolean contract: enabled:true -> enabled; enabled:false -> disabled (parser-agnostic;
# oracle_max_surface_enabled lowercases so it accepts jq's `true` AND python3's `True`).
cat > "$tmp/proj/.claude/busdriver.json" <<'JSON'
{ "oracleMax": { "council": { "enabled": true } } }
JSON
oracle_max_surface_enabled council || { echo "FAIL enabled:true -> enabled"; FAIL=1; }
cat > "$tmp/proj/.claude/busdriver.json" <<'JSON'
{ "oracleMax": { "council": { "enabled": false } } }
JSON
oracle_max_surface_enabled council && { echo "FAIL enabled:false -> disabled"; FAIL=1; }
[ "$FAIL" = 0 ] && echo "PASS test-oracle-max-config" || exit 1
