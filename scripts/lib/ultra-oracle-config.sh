#!/bin/bash
# ultra-oracle-config.sh — read the `ultraOracle` block from the USER busdriver.json ONLY.
# Reuses resolve-cli.sh's _read_config_value (jq preferred, python3 fallback) and
# _portable_timeout. Harness-neutral: ${BUSDRIVER_STATE_DIR:-.claude}, no bash-4-isms.
# Conditional style: [[ ]] for string/file tests; POSIX [ ] for integer -gt/-ge
# comparisons ([ ] does base-10 strtol with no arithmetic eval — avoids [[ ]]'s
# octal-parse of leading-zero values and command-sub-in-arithmetic injection).
_ULTRA_ORACLE_CFG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_ULTRA_ORACLE_CFG_DIR}/resolve-cli.sh"

# ultra_oracle_config_get_user <jq-path> <default>
# Reads ONLY the user config (~/.claude/busdriver.json) — NEVER the repo-controlled
# project config. The whole ultraOracle block is user-only so a malicious branch cannot
# opt a reviewer into transmitting the design to ChatGPT Pro, clone their browser
# profile, change the model, or stall them with a huge timeout — all without a
# user-local opt-in.
ultra_oracle_config_get_user() {
  local jq_path="$1" default="$2" val="" state_dir="${BUSDRIVER_STATE_DIR:-.claude}"
  local user_config="$HOME/$state_dir/busdriver.json"
  if [[ -f "$user_config" ]]; then
    val="$(_read_config_value "$user_config" "$jq_path" 2>/dev/null || true)"
  fi
  if [[ -n "$val" && "$val" != "null" ]]; then printf '%s' "$val"; else printf '%s' "$default"; fi
}

# The ENTIRE ultraOracle block is read from USER config only — a repo-controlled
# project config has zero influence on ultra-oracle (no enable, no model, no timing).
ultra_oracle_model() { ultra_oracle_config_get_user '.ultraOracle.model' 'gpt-5.5-pro'; }

# Validate as a positive integer; non-numeric/empty/zero -> warn + 900 default.
# Clamp to ULTRA_ORACLE_CAP_CEILING (default 3600s = 1h) so a repo-controlled project
# config cannot set an arbitrarily large cap and stall a reviewer (availability DoS).
ultra_oracle_timeout_cap() {
  local v ceil="${ULTRA_ORACLE_CAP_CEILING:-3600}"
  # Validate the ceiling itself before the `-gt` below — a non-numeric OR absurdly
  # long (19+ digit, overflow-prone) ULTRA_ORACLE_CAP_CEILING would make
  # `[ "$v" -gt "$ceil" ]` error out (and could let an oversized cap through), so
  # fall back to the 3600s default in either case. This keeps the `-gt` operand
  # bounded so the value-side guard below is sufficient for overflow safety.
  case "$ceil" in ''|*[!0-9]*|0) ceil=3600;; esac
  [ "${#ceil}" -ge 19 ] && ceil=3600
  v="$(ultra_oracle_config_get_user '.ultraOracle.timeoutCapSeconds' '900')"
  case "$v" in
    ''|*[!0-9]*) echo "ultra-oracle: invalid timeoutCapSeconds '$v' — using 900" >&2; printf '900'; return;;
  esac
  # Strip leading zeros so "0600" normalizes to "600" and any all-zero string
  # ("0", "00", ...) collapses to "" — which we reject below. A 0 cap is unsafe:
  # `timeout 0` / the Perl fallback's `alarm 0` DISABLE the timeout, letting an
  # opt-in consult run unbounded instead of falling back to the safe default.
  v="${v#"${v%%[!0]*}"}"
  case "$v" in ''|0) echo "ultra-oracle: timeoutCapSeconds resolves to 0 — using 900" >&2; printf '900'; return;; esac
  # A value with 19+ digits would overflow bash's signed-64-bit `-gt` (INT64_MAX is
  # 19 digits) and could wrap to compare as SMALLER, letting an absurd cap through;
  # anything that long is nonsensical as a second count, so clamp it outright. Below
  # 19 digits the numeric `-gt` is safe.
  if [ "${#v}" -ge 19 ] || [ "$v" -gt "$ceil" ]; then
    echo "ultra-oracle: timeoutCapSeconds $v exceeds ceiling $ceil — clamping" >&2; printf '%s' "$ceil"
  else
    printf '%s' "$v"
  fi
}

ultra_oracle_chrome_profile() {
  # USER config only (security-sensitive — clones a browser session). Returns "" by
  # default (no --copy-profile) so we do NOT clone the operator's main Chrome
  # profile — and its cookies/sessions — by default. Set ultraOracle.chromeProfileDir
  # in ~/.claude/busdriver.json to a dedicated, ChatGPT-only Chrome profile to opt
  # into login-free runs. Supports `~` and `~/...` only (not `~user/...`). Value
  # may contain spaces — callers MUST keep it quoted.
  local d; d="$(ultra_oracle_config_get_user '.ultraOracle.chromeProfileDir' '')"
  # Matching a literal leading tilde from config (not requesting expansion).
  # shellcheck disable=SC2088
  case "$d" in "~"|"~/"*) d="$HOME${d#\~}";; esac
  printf '%s' "$d"
}

ultra_oracle_cookie_path() {
  # USER config only (security-sensitive — reuses a live ChatGPT session). Path to a
  # Chrome/Chromium Cookies DB (`--browser-cookie-path`). Unlike chromeProfileDir's
  # full-profile clone, this decrypts the existing session in place via the OS keychain
  # — the reliable headless path on Chrome builds whose app-bound cookie encryption
  # defeats --copy-profile. Returns "" by default (no reuse). Supports `~`/`~/...` only
  # (not `~user/...`). Value may contain spaces — callers MUST keep it quoted.
  local d; d="$(ultra_oracle_config_get_user '.ultraOracle.cookiePath' '')"
  # Matching a literal leading tilde from config (not requesting expansion).
  # shellcheck disable=SC2088
  case "$d" in "~"|"~/"*) d="$HOME${d#\~}";; esac
  printf '%s' "$d"
}

# NOTE: the automation Chrome window is ALWAYS hidden by the consult (these are
# non-interactive background advisory runs reusing a stored session). A default-true
# boolean toggle is intentionally NOT offered here: the shared _read_config_value uses
# jq's `// empty`, which collapses a configured `false` to empty (jq treats false as a
# null-alternative), so a `false` could never override a `true` default anyway.

# ultra_oracle_surface_enabled <brainstorming|blueprintReview|council> -> exit 0 if true.
# USER config ONLY (security-sensitive — enabling transmits content to ChatGPT Pro;
# a repo-controlled project config must NOT be able to opt a reviewer in).
# Normalize: jq emits `true`, but resolve-cli.sh's python3 fallback emits `True`.
ultra_oracle_surface_enabled() {
  local v; v="$(ultra_oracle_config_get_user ".ultraOracle.${1}.enabled" 'false')"
  case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in true|1) return 0;; *) return 1;; esac
}
