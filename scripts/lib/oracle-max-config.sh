#!/bin/bash
# oracle-max-config.sh — read the `oracleMax` block from the USER busdriver.json ONLY.
# Reuses resolve-cli.sh's _read_config_value (jq preferred, python3 fallback) and
# _portable_timeout. Harness-neutral: ${BUSDRIVER_STATE_DIR:-.claude}, no bash-4-isms.
_ORACLE_MAX_CFG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_ORACLE_MAX_CFG_DIR}/resolve-cli.sh"

# oracle_max_config_get_user <jq-path> <default>
# Reads ONLY the user config (~/.claude/busdriver.json) — NEVER the repo-controlled
# project config. The whole oracleMax block is user-only so a malicious branch cannot
# opt a reviewer into transmitting the design to ChatGPT Pro, clone their browser
# profile, change the model, or stall them with a huge timeout — all without a
# user-local opt-in.
oracle_max_config_get_user() {
  local jq_path="$1" default="$2" val="" state_dir="${BUSDRIVER_STATE_DIR:-.claude}"
  local user_config="$HOME/$state_dir/busdriver.json"
  if [ -f "$user_config" ]; then
    val="$(_read_config_value "$user_config" "$jq_path" 2>/dev/null || true)"
  fi
  if [ -n "$val" ] && [ "$val" != "null" ]; then printf '%s' "$val"; else printf '%s' "$default"; fi
}

# The ENTIRE oracleMax block is read from USER config only — a repo-controlled
# project config has zero influence on oracle-max (no enable, no model, no timing).
oracle_max_model() { oracle_max_config_get_user '.oracleMax.model' 'gpt-5.5-pro'; }

# Validate as a positive integer; non-numeric/empty/zero -> warn + 900 default.
# Clamp to ORACLE_MAX_CAP_CEILING (default 3600s = 1h) so a repo-controlled project
# config cannot set an arbitrarily large cap and stall a reviewer (availability DoS).
oracle_max_timeout_cap() {
  local v ceil="${ORACLE_MAX_CAP_CEILING:-3600}"
  # Validate the ceiling itself is numeric before the `-gt` below — a non-numeric
  # ORACLE_MAX_CAP_CEILING would make `[ "$v" -gt "$ceil" ]` error out (and could
  # let an oversized cap through), so fall back to the 3600s default.
  case "$ceil" in ''|*[!0-9]*|0) ceil=3600;; esac
  v="$(oracle_max_config_get_user '.oracleMax.timeoutCapSeconds' '900')"
  case "$v" in
    ''|*[!0-9]*) echo "oracle-max: invalid timeoutCapSeconds '$v' — using 900" >&2; printf '900'; return;;
    0)           echo "oracle-max: timeoutCapSeconds 0 — using 900" >&2; printf '900'; return;;
  esac
  if [ "$v" -gt "$ceil" ]; then
    echo "oracle-max: timeoutCapSeconds $v exceeds ceiling $ceil — clamping" >&2; printf '%s' "$ceil"
  else
    printf '%s' "$v"
  fi
}

oracle_max_chrome_profile() {
  # USER config only (security-sensitive — clones a browser session). Returns "" by
  # default (no --copy-profile) so we do NOT clone the operator's main Chrome
  # profile — and its cookies/sessions — by default. Set oracleMax.chromeProfileDir
  # in ~/.claude/busdriver.json to a dedicated, ChatGPT-only Chrome profile to opt
  # into login-free runs. Supports `~` and `~/...` only (not `~user/...`). Value
  # may contain spaces — callers MUST keep it quoted.
  local d; d="$(oracle_max_config_get_user '.oracleMax.chromeProfileDir' '')"
  # Matching a literal leading tilde from config (not requesting expansion).
  # shellcheck disable=SC2088
  case "$d" in "~"|"~/"*) d="$HOME${d#\~}";; esac
  printf '%s' "$d"
}

# oracle_max_surface_enabled <brainstorming|blueprintReview|council> -> exit 0 if true.
# USER config ONLY (security-sensitive — enabling transmits content to ChatGPT Pro;
# a repo-controlled project config must NOT be able to opt a reviewer in).
# Normalize: jq emits `true`, but resolve-cli.sh's python3 fallback emits `True`.
oracle_max_surface_enabled() {
  local v; v="$(oracle_max_config_get_user ".oracleMax.${1}.enabled" 'false')"
  case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in true|1) return 0;; *) return 1;; esac
}
