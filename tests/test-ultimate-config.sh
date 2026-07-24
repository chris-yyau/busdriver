#!/usr/bin/env bash
# tests/test-ultimate-config.sh
# Unit tests for scripts/lib/ultimate-config.sh (ADR 0011, as amended by ADR 0019).
#
# ultimate_surface_enabled <surface> gates the opt-in Claude-Fable "ultimate" tier surfaces,
# now reached via an in-harness Agent subagent (the gateway transport was removed in ADR 0019,
# so enabling transmits nothing externally). The enable still must come from the USER config
# (~/.claude/busdriver.json) ONLY — never a repo-controlled project config — or from the
# BUSDRIVER_ULTIMATE=1 operator force.
#
# These cases exercise the SURFACE-GENERIC reader. `council` is the only LIVE config surface
# with a caller; the `arbiter` config surface was dropped in ADR 0027 (arbiter elevation is
# now the in-band "ultimate arbiter" trigger phrase ONLY — BUSDRIVER_ULTIMATE has no effect on
# the arbiter, which has no caller of this reader; it still forces council, the live surface).
# We keep
# `arbiter` below purely as a REPRESENTATIVE surface string to prove the reader is generic and
# its USER-only / precedence / normalization guarantees hold for any `.ultimate.surfaces.<name>`
# — NOT as an assertion that `arbiter` is a live config opt-in (it is not).
#
# Every case ISOLATES $HOME to a throwaway dir so the developer's real
# ~/.claude/busdriver.json can't make the suite flaky (the crit-4 requirement).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$DIR/scripts/lib/ultimate-config.sh"
FAIL=0

[[ -f "$HELPER" ]] || { echo "FAIL helper not found: $HELPER"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# run_enabled <case-dir> <surface> [env-assignment ...]
# Sources the helper under an isolated HOME (=<case-dir>) with a clean environment and
# echoes 0 (enabled) or 1 (disabled). env -i so no ambient BUSDRIVER_ULTIMATE /
# BUSDRIVER_STATE_DIR / real HOME leaks in.
run_enabled() {
  local home="$1" surface="$2"; shift 2
  env -i PATH="$PATH" HOME="$home" "$@" \
    bash -c 'source "$0"; ultimate_surface_enabled "$1" && echo 0 || echo 1' "$HELPER" "$surface"
}

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; else
    echo "  FAIL  $1"; echo "        expected [$2] got [$3]"; FAIL=1; fi
}

write_cfg() { # dir relpath json
  mkdir -p "$1/$(dirname "$2")"; printf '%s' "$3" > "$1/$2"
}

# 1. No config, no env → disabled (fail-closed default), both surfaces.
H="$TMP/none"; mkdir -p "$H"
check "no config and no env → arbiter disabled" 1 "$(run_enabled "$H" arbiter)"
check "no config and no env → council disabled" 1 "$(run_enabled "$H" council)"

# 2. USER config surfaces.arbiter:true → arbiter enabled (council still off).
H="$TMP/user-arb"; write_cfg "$H" ".claude/busdriver.json" '{"ultimate":{"surfaces":{"arbiter":true}}}'
check "USER surfaces.arbiter:true → arbiter enabled" 0 "$(run_enabled "$H" arbiter)"
check "USER surfaces.arbiter:true → council still disabled" 1 "$(run_enabled "$H" council)"

# 3. USER config surfaces.council:true → council enabled independently.
H="$TMP/user-council"; write_cfg "$H" ".claude/busdriver.json" '{"ultimate":{"surfaces":{"council":true,"arbiter":false}}}'
check "USER surfaces.council:true → council enabled" 0 "$(run_enabled "$H" council)"
check "USER surfaces.arbiter:false → arbiter disabled" 1 "$(run_enabled "$H" arbiter)"

# 4. Env force wins over an absent/false config (precedence), both surfaces.
H="$TMP/force-empty"; mkdir -p "$H"
check "BUSDRIVER_ULTIMATE=1 forces arbiter enabled with no config" 0 "$(run_enabled "$H" arbiter BUSDRIVER_ULTIMATE=1)"
check "BUSDRIVER_ULTIMATE=1 forces council enabled with no config" 0 "$(run_enabled "$H" council BUSDRIVER_ULTIMATE=1)"
H="$TMP/force-over-false"; write_cfg "$H" ".claude/busdriver.json" '{"ultimate":{"surfaces":{"arbiter":false}}}'
check "BUSDRIVER_ULTIMATE=1 overrides config false" 0 "$(run_enabled "$H" arbiter BUSDRIVER_ULTIMATE=1)"

# 5. BUSDRIVER_ULTIMATE=0 forces OFF even when config says true.
H="$TMP/force-off"; write_cfg "$H" ".claude/busdriver.json" '{"ultimate":{"surfaces":{"arbiter":true}}}'
check "BUSDRIVER_ULTIMATE=0 forces disabled over config true" 1 "$(run_enabled "$H" arbiter BUSDRIVER_ULTIMATE=0)"
# Any other value falls through to config (not a truthy-string enable).
H="$TMP/force-other"; mkdir -p "$H"
check "BUSDRIVER_ULTIMATE=true (not 1) falls through to config → disabled" 1 "$(run_enabled "$H" arbiter BUSDRIVER_ULTIMATE=true)"

# 6. Repo-controlled project config MUST be ignored (USER-only boundary). A malicious
#    branch that drops .claude/busdriver.json into the repo cannot opt a reviewer in.
#    Isolated HOME has NO user config; the "repo" config lives under a separate CWD.
H="$TMP/repo-ignored-home"; mkdir -p "$H"
REPO="$TMP/repo-ignored-cwd"; write_cfg "$REPO" ".claude/busdriver.json" '{"ultimate":{"surfaces":{"arbiter":true}}}'
check "repo/project config with arbiter:true is IGNORED (USER-only)" 1 \
  "$(cd "$REPO" && run_enabled "$H" arbiter)"

# 7. BUSDRIVER_STATE_DIR is honored for the USER config location.
H="$TMP/statedir"; write_cfg "$H" ".config/busdriver.json" '{"ultimate":{"surfaces":{"arbiter":true}}}'
check "BUSDRIVER_STATE_DIR relocates the USER config" 0 \
  "$(run_enabled "$H" arbiter BUSDRIVER_STATE_DIR=.config)"

# 8. python3-fallback normalization: resolve-cli.sh's python3 path emits `True`, so the
#    helper must lowercase-normalize. Force the python3 parser to exercise that branch.
#    `_JSON_PARSER=python3` is honored via resolve-cli.sh's `${_JSON_PARSER:-}` init
#    (a deliberate test hook); without it resolve-cli re-detects and picks jq on CI.
if command -v python3 >/dev/null 2>&1; then
  H="$TMP/py-true"; write_cfg "$H" ".claude/busdriver.json" '{"ultimate":{"surfaces":{"arbiter":true}}}'
  check "python3 fallback True normalizes to enabled" 0 \
    "$(run_enabled "$H" arbiter _JSON_PARSER=python3)"
else
  echo "  SKIP  python3 normalization (python3 not installed)"
fi

[[ "$FAIL" = 0 ]] && echo "PASS test-ultimate-config" || { echo "FAIL test-ultimate-config"; exit 1; }
