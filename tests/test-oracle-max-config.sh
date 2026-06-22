#!/bin/bash
# tests/test-oracle-max-config.sh
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
tmp="$(mktemp -d)"; export HOME="$tmp"; mkdir -p "$tmp/.claude"; cd "$tmp" || exit 1
git init -q .
mkdir -p "$tmp/proj/.claude"; cd "$tmp/proj" || exit 1; git init -q .

# USER config: security-sensitive enablement + a model (to test non-sensitive precedence).
cat > "$tmp/.claude/busdriver.json" <<'JSON'
{ "oracleMax": { "model": "user-model",
  "brainstorming": { "enabled": true }, "council": { "enabled": false } } }
JSON
# PROJECT config: non-sensitive overrides + a sensitive enable that MUST be ignored.
cat > "$tmp/proj/.claude/busdriver.json" <<'JSON'
{ "oracleMax": { "model": "gpt-5.5-pro", "timeoutCapSeconds": 1234,
  "blueprintReview": { "enabled": true } } }
JSON
# shellcheck source=/dev/null
source "$DIR/scripts/lib/oracle-max-config.sh"

# Non-sensitive fields: project overrides user.
[ "$(oracle_max_model)" = "gpt-5.5-pro" ] || { echo "FAIL project>user model"; FAIL=1; }
[ "$(oracle_max_timeout_cap)" = "1234" ] || { echo "FAIL cap"; FAIL=1; }
# Sensitive enablement: USER config only.
oracle_max_surface_enabled brainstorming || { echo "FAIL user brainstorming enabled"; FAIL=1; }
oracle_max_surface_enabled council && { echo "FAIL user council should be off"; FAIL=1; }
# SECURITY: a repo-controlled PROJECT config must NOT be able to enable a surface.
oracle_max_surface_enabled blueprintReview && { echo "FAIL project config must NOT enable surface"; FAIL=1; }

# timeoutCapSeconds validation (project, non-sensitive): non-numeric -> 900 default.
cat > "$tmp/proj/.claude/busdriver.json" <<'JSON'
{ "oracleMax": { "timeoutCapSeconds": "15m" } }
JSON
[ "$(oracle_max_timeout_cap 2>/dev/null)" = "900" ] || { echo "FAIL non-numeric cap -> 900"; FAIL=1; }

# malformed USER config -> sensitive surfaces OFF, model default (no crash).
rm -f "$tmp/proj/.claude/busdriver.json"
printf '{ this is not json' > "$tmp/.claude/busdriver.json"
[ "$(oracle_max_model 2>/dev/null)" = "gpt-5.5-pro" ] || { echo "FAIL malformed -> default model"; FAIL=1; }
oracle_max_surface_enabled brainstorming && { echo "FAIL malformed user -> off"; FAIL=1; }

# empty USER config -> defaults.
echo '{}' > "$tmp/.claude/busdriver.json"
[ "$(oracle_max_model)" = "gpt-5.5-pro" ] || { echo "FAIL default model"; FAIL=1; }
oracle_max_surface_enabled blueprintReview && { echo "FAIL empty -> off"; FAIL=1; }

# boolean normalization in USER config: true -> enabled; false -> disabled
# (parser-agnostic: oracle_max_surface_enabled lowercases jq's `true` AND python3's `True`).
cat > "$tmp/.claude/busdriver.json" <<'JSON'
{ "oracleMax": { "council": { "enabled": true } } }
JSON
oracle_max_surface_enabled council || { echo "FAIL enabled:true -> enabled"; FAIL=1; }
cat > "$tmp/.claude/busdriver.json" <<'JSON'
{ "oracleMax": { "council": { "enabled": false } } }
JSON
oracle_max_surface_enabled council && { echo "FAIL enabled:false -> disabled"; FAIL=1; }

[ "$FAIL" = 0 ] && echo "PASS test-oracle-max-config" || exit 1
