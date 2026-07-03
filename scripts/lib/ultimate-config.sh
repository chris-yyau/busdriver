#!/bin/bash
# ultimate-config.sh — read the `ultimate` tier opt-in from the USER busdriver.json ONLY.
# Reuses resolve-cli.sh's _read_config_value (jq preferred, python3 fallback).
# Harness-neutral: ${BUSDRIVER_STATE_DIR:-.claude}, no bash-4-isms.
#
# The "ultimate" tier is the opt-in Claude-Fable-via-zenmux-gateway surface set (ADR 0011).
# Two surfaces ship today, each config-gated independently:
#   - arbiter  — the blueprint-review "ultimate arbiter" escalation ABOVE the default opus
#                (SKILL.md "Ultimate-Arbiter Escalation").
#   - council  — the council "Mythos Witness" (Fable expert witness, rendered separately).
# Enabling either transmits the design/validation/question prompt to an external
# Anthropic-API-compatible gateway, so — like the ultraOracle boundary it mirrors — the
# enable MUST be user-local: a repo-controlled project config or reviewed branch content
# can never opt a reviewer into the escalation.
# Portable dir resolution. BASH_SOURCE is unset under zsh (and other non-bash shells), where
# `dirname "${BASH_SOURCE[0]}"` silently collapses to "." and mis-sources resolve-cli.sh from
# the CWD — functions end up undefined with no error. Guard loudly: this lib is bash-only.
if [ -z "${BASH_SOURCE:-}" ]; then
  echo "ultimate-config.sh: ERROR — must be sourced under bash (BASH_SOURCE unset; zsh/other shells mis-resolve the script dir and half-load)" >&2
  # shellcheck disable=SC2317  # reached when sourced under a non-bash shell
  return 1 2>/dev/null || exit 1
fi
_ULTIMATE_CFG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_ULTIMATE_CFG_DIR}/resolve-cli.sh"

# ultimate_config_get_user <jq-path> <default>
# Reads ONLY the user config (~/.claude/busdriver.json) — NEVER the repo-controlled
# project config (mirrors ultra_oracle_config_get_user).
ultimate_config_get_user() {
  local jq_path="$1" default="$2" val="" state_dir="${BUSDRIVER_STATE_DIR:-.claude}"
  local user_config="$HOME/$state_dir/busdriver.json"
  if [[ -f "$user_config" ]]; then
    val="$(_read_config_value "$user_config" "$jq_path" 2>/dev/null || true)"
  fi
  if [[ -n "$val" && "$val" != "null" ]]; then printf '%s' "$val"; else printf '%s' "$default"; fi
}

# ultimate_surface_enabled <arbiter|council> -> exit 0 if that ultimate surface is opted in.
# USER config ONLY (security-sensitive — enabling transmits content to an external gateway).
# `BUSDRIVER_ULTIMATE` is a global operator force (mirroring ULTRA_ORACLE_COUNCIL_FORCE):
#   BUSDRIVER_ULTIMATE=1 forces the whole tier ON; BUSDRIVER_ULTIMATE=0 forces it OFF,
#   overriding config. Any other value falls through to the per-surface config flag
#   `.ultimate.surfaces.<arbiter|council>` (a plain boolean). Normalize the config value:
# jq emits `true`, but resolve-cli.sh's python3 fallback emits `True`.
ultimate_surface_enabled() {
  case "${BUSDRIVER_ULTIMATE:-}" in
    1) return 0;;
    0) return 1;;
  esac
  local surface="$1" v
  v="$(ultimate_config_get_user ".ultimate.surfaces.${surface}" 'false')"
  case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in true|1) return 0;; *) return 1;; esac
}
