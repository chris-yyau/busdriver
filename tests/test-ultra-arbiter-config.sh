#!/usr/bin/env bash
# tests/test-ultra-arbiter-config.sh
# Unit tests for scripts/lib/ultra-arbiter-config.sh (#265).
#
# ultra_arbiter_enabled gates the opt-in gateway-fable "ultra arbiter" escalation.
# The enable is SECURITY-SENSITIVE (it transmits the design to an external gateway), so
# it must come from the USER config (~/.claude/busdriver.json) ONLY — never a
# repo-controlled project config — or from the BLUEPRINT_ARBITER_ULTRA=1 operator force.
#
# Every case ISOLATES $HOME to a throwaway dir so the developer's real
# ~/.claude/busdriver.json can't make the suite flaky (the crit-4 requirement).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$DIR/scripts/lib/ultra-arbiter-config.sh"
FAIL=0

[[ -f "$HELPER" ]] || { echo "FAIL helper not found: $HELPER"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# run_enabled <case-dir> [env-assignment ...]
# Sources the helper under an isolated HOME (=<case-dir>) with a clean environment and
# echoes 0 (enabled) or 1 (disabled). env -i so no ambient BLUEPRINT_ARBITER_ULTRA /
# BUSDRIVER_STATE_DIR / real HOME leaks in.
run_enabled() {
  local home="$1"; shift
  env -i PATH="$PATH" HOME="$home" "$@" \
    bash -c 'source "$0"; ultra_arbiter_enabled && echo 0 || echo 1' "$HELPER"
}

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; else
    echo "  FAIL  $1"; echo "        expected [$2] got [$3]"; FAIL=1; fi
}

write_cfg() { # dir relpath json
  mkdir -p "$1/$(dirname "$2")"; printf '%s' "$3" > "$1/$2"
}

# 1. No config, no env → disabled (fail-closed default).
H="$TMP/none"; mkdir -p "$H"
check "no config and no env → disabled" 1 "$(run_enabled "$H")"

# 2. USER config enabled:true → enabled.
H="$TMP/user-true"; write_cfg "$H" ".claude/busdriver.json" '{"ultraArbiter":{"enabled":true}}'
check "USER config enabled:true → enabled" 0 "$(run_enabled "$H")"

# 3. USER config enabled:false → disabled.
H="$TMP/user-false"; write_cfg "$H" ".claude/busdriver.json" '{"ultraArbiter":{"enabled":false}}'
check "USER config enabled:false → disabled" 1 "$(run_enabled "$H")"

# 4. Env force wins over an absent/false config (precedence).
H="$TMP/force-empty"; mkdir -p "$H"
check "BLUEPRINT_ARBITER_ULTRA=1 forces enabled with no config" 0 "$(run_enabled "$H" BLUEPRINT_ARBITER_ULTRA=1)"
H="$TMP/force-over-false"; write_cfg "$H" ".claude/busdriver.json" '{"ultraArbiter":{"enabled":false}}'
check "BLUEPRINT_ARBITER_ULTRA=1 overrides config false" 0 "$(run_enabled "$H" BLUEPRINT_ARBITER_ULTRA=1)"

# 5. Env force must be exactly 1 (not any truthy string) — mirrors ULTRA_ORACLE_COUNCIL_FORCE.
H="$TMP/force-zero"; mkdir -p "$H"
check "BLUEPRINT_ARBITER_ULTRA=0 does not enable" 1 "$(run_enabled "$H" BLUEPRINT_ARBITER_ULTRA=0)"
check "BLUEPRINT_ARBITER_ULTRA=true does not enable (only =1)" 1 "$(run_enabled "$H" BLUEPRINT_ARBITER_ULTRA=true)"

# 6. Repo-controlled project config MUST be ignored (USER-only boundary). A malicious
#    branch that drops .claude/busdriver.json into the repo cannot opt a reviewer in.
#    Isolated HOME has NO user config; the "repo" config lives under a separate CWD.
H="$TMP/repo-ignored-home"; mkdir -p "$H"
REPO="$TMP/repo-ignored-cwd"; write_cfg "$REPO" ".claude/busdriver.json" '{"ultraArbiter":{"enabled":true}}'
check "repo/project config with enabled:true is IGNORED (USER-only)" 1 \
  "$(cd "$REPO" && run_enabled "$H")"

# 7. BUSDRIVER_STATE_DIR is honored for the USER config location.
H="$TMP/statedir"; write_cfg "$H" ".config/busdriver.json" '{"ultraArbiter":{"enabled":true}}'
check "BUSDRIVER_STATE_DIR relocates the USER config" 0 \
  "$(run_enabled "$H" BUSDRIVER_STATE_DIR=.config)"

# 8. python3-fallback normalization: resolve-cli.sh's python3 path emits `True`, so the
#    helper must lowercase-normalize. Force the python3 parser to exercise that branch.
#    `_JSON_PARSER=python3` is honored via resolve-cli.sh's `${_JSON_PARSER:-}` init
#    (a deliberate test hook); without it resolve-cli re-detects and picks jq on CI.
if command -v python3 >/dev/null 2>&1; then
  H="$TMP/py-true"; write_cfg "$H" ".claude/busdriver.json" '{"ultraArbiter":{"enabled":true}}'
  check "python3 fallback True normalizes to enabled" 0 \
    "$(run_enabled "$H" _JSON_PARSER=python3)"
else
  echo "  SKIP  python3 normalization (python3 not installed)"
fi

[[ "$FAIL" = 0 ]] && echo "PASS test-ultra-arbiter-config" || { echo "FAIL test-ultra-arbiter-config"; exit 1; }
