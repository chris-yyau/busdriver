#!/bin/bash
# ultra-arbiter-config.sh — read the `ultraArbiter` opt-in from the USER busdriver.json ONLY.
# Reuses resolve-cli.sh's _read_config_value (jq preferred, python3 fallback).
# Harness-neutral: ${BUSDRIVER_STATE_DIR:-.claude}, no bash-4-isms.
#
# The "ultra arbiter" is the opt-in gateway-fable escalation ABOVE the default opus
# blueprint-review arbiter (SKILL.md "Ultra-Arbiter Escalation"). Enabling it transmits
# the design/validation prompt to an external Anthropic-API-compatible gateway, so — like
# the ultraOracle boundary it mirrors — the enable MUST be user-local: a repo-controlled
# project config or reviewed branch content can never opt a reviewer into the escalation.
_ULTRA_ARBITER_CFG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_ULTRA_ARBITER_CFG_DIR}/resolve-cli.sh"

# ultra_arbiter_config_get_user <jq-path> <default>
# Reads ONLY the user config (~/.claude/busdriver.json) — NEVER the repo-controlled
# project config (mirrors ultra_oracle_config_get_user).
ultra_arbiter_config_get_user() {
  local jq_path="$1" default="$2" val="" state_dir="${BUSDRIVER_STATE_DIR:-.claude}"
  local user_config="$HOME/$state_dir/busdriver.json"
  if [[ -f "$user_config" ]]; then
    val="$(_read_config_value "$user_config" "$jq_path" 2>/dev/null || true)"
  fi
  if [[ -n "$val" && "$val" != "null" ]]; then printf '%s' "$val"; else printf '%s' "$default"; fi
}

# ultra_arbiter_enabled -> exit 0 if the ultra-arbiter escalation is opted in.
# USER config ONLY (security-sensitive — enabling transmits content to an external gateway).
# `BLUEPRINT_ARBITER_ULTRA=1` takes precedence over the config flag (an operator force,
# mirroring ULTRA_ORACLE_COUNCIL_FORCE). Normalize the config value: jq emits `true`,
# but resolve-cli.sh's python3 fallback emits `True`.
ultra_arbiter_enabled() {
  [ "${BLUEPRINT_ARBITER_ULTRA:-0}" = 1 ] && return 0
  local v; v="$(ultra_arbiter_config_get_user '.ultraArbiter.enabled' 'false')"
  case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in true|1) return 0;; *) return 1;; esac
}
