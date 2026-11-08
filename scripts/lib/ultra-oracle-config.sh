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
ultra_oracle_config_get_user() { _read_user_config_value "$1" "$2"; }

# _ultra_oracle_sanitize_ceiling <raw-value>
# Internal helper: validate and sanitize an ULTRA_ORACLE_CAP_CEILING value.
# Prints the safe ceiling (numeric, non-zero, < 19 digits); falls back to 3600 on
# any invalid input. Shared by ultra_oracle_timeout_cap() and ultra_oracle_consult()
# so the safety-critical ceiling logic cannot drift between the two call sites.
_ultra_oracle_sanitize_ceiling() {
  local ceil="${1:-3600}"
  # Non-numeric or empty → default.
  case "$ceil" in ''|*[!0-9]*) ceil=3600;; esac
  # Strip leading zeros so "00" collapses to "" (all-zero → rejected below) and
  # "000500" is not mistaken for a 19+ digit overflow.
  ceil="${ceil#"${ceil%%[!0]*}"}"
  # All-zero input collapses to "" after stripping.
  case "$ceil" in '') ceil=3600;; esac
  # 19+ digit value would overflow signed-64-bit arithmetic; reset to default.
  [ "${#ceil}" -ge 19 ] && ceil=3600
  printf '%s' "$ceil"
}

# The ENTIRE ultraOracle block is read from USER config only — a repo-controlled
# project config has zero influence on ultra-oracle (no enable, no timing).
# Validate as a positive integer; non-numeric/empty/zero -> warn + 900 default.
# Clamp to ULTRA_ORACLE_CAP_CEILING (default 3600s = 1h) so a repo-controlled project
# config cannot set an arbitrarily large cap and stall a reviewer (availability DoS).
ultra_oracle_timeout_cap() {
  local v ceil
  # Validate the ceiling itself before the `-gt` below — a non-numeric OR absurdly
  # long (19+ digit, overflow-prone) ULTRA_ORACLE_CAP_CEILING would make
  # `[ "$v" -gt "$ceil" ]` error out (and could let an oversized cap through), so
  # fall back to the 3600s default in either case. This keeps the `-gt` operand
  # bounded so the value-side guard below is sufficient for overflow safety.
  ceil="$(_ultra_oracle_sanitize_ceiling "${ULTRA_ORACLE_CAP_CEILING:-3600}")"
  v="$(ultra_oracle_config_get_user '.ultraOracle.timeoutCapSeconds' '900')"
  case "$v" in
    ''|*[!0-9]*) echo "ultra-oracle: invalid timeoutCapSeconds '$v' — using 900" >&2; printf '900'; return;;
  esac
  # Strip leading zeros so "0600" normalizes to "600" and any all-zero string
  # ("0", "00", ...) collapses to "" — which we reject below. A 0 cap is unsafe:
  # `timeout 0` / the Perl fallback's `alarm 0` DISABLE the timeout, letting an
  # opt-in consult run unbounded instead of falling back to the safe default.
  v="${v#"${v%%[!0]*}"}"
  case "$v" in '') echo "ultra-oracle: timeoutCapSeconds resolves to 0 — using 900" >&2; printf '900'; return;; esac
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

# ultra_oracle_surface_enabled <brainstorming|blueprintReview|council> -> exit 0 if true.
# USER config ONLY (security-sensitive — enabling transmits content to ChatGPT Pro;
# a repo-controlled project config must NOT be able to opt a reviewer in).
# Normalize: jq emits `true`, but resolve-cli.sh's python3 fallback emits `True`.
ultra_oracle_surface_enabled() {
  local v; v="$(ultra_oracle_config_get_user ".ultraOracle.${1}.enabled" 'false')"
  case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in true|1) return 0;; *) return 1;; esac
}

# _ultra_oracle_legacy_keys_notice -> one line naming every removed ultraOracle key still present in
# USER config (spec 2026-11-01 §8), or nothing. It lists key NAMES only and never reads a value, so
# remoteToken is never touched. A missing config file counts as no keys.
_ULTRA_ORACLE_REMOVED_KEYS='model browserModelStrategy chromeProfileDir cookiePath remoteHost remoteToken hideWindow attachRunning attachProfileDir'
_ultra_oracle_legacy_keys_notice() {
  local f="$HOME/${BUSDRIVER_STATE_DIR:-.claude}/busdriver.json" k found=""
  [ -f "$f" ] || return 0
  while IFS= read -r k; do
    case " $_ULTRA_ORACLE_REMOVED_KEYS " in *" $k "*) found="${found:+$found, }$k" ;; esac
  done < <(/usr/bin/jq -r '(.ultraOracle // {}) | if type == "object" then keys[] else empty end' "$f" 2>/dev/null)
  [ -n "$found" ] && printf 'ultraOracle settings no longer read since 4.0.0 (Chrome transport): %s. Delete them from %s.' "$found" "$f"
  return 0
}
