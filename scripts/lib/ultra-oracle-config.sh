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
# project config has zero influence on ultra-oracle (no enable, no model, no timing).
ultra_oracle_model() { ultra_oracle_config_get_user '.ultraOracle.model' 'gpt-5.5-pro'; }

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

# ultra_oracle_remote_host -> `host:port` of a running `oracle serve` instance, or "".
# USER config only. This is the cookie-decryption-blocked path (issue #340): on recent
# Chrome builds the browser blocks PROGRAMMATIC cookie decryption (App-Bound Encryption
# on Windows, Keychain-bound on macOS; observed on macOS Chrome 149), so
# --browser-cookie-path / --copy-profile cannot reuse the ChatGPT session at all.
# `oracle serve --manual-login`
# keeps a dedicated, human-signed-in Chrome profile warm; each run DELEGATES to it via
# oracle's --remote-host, sidestepping ABE entirely. When set it takes precedence over
# cookiePath/chromeProfileDir in the adapter (serve owns its own browser session).
# Pin serve to 127.0.0.1 — it defaults to --host 0.0.0.0 and would otherwise be
# reachable over LAN/Tailscale. Empty default.
ultra_oracle_remote_host() { ultra_oracle_config_get_user '.ultraOracle.remoteHost' ''; }

# ultra_oracle_remote_token -> access token for the `oracle serve` instance, or "".
# USER config only, and a SECRET: never repo-committed — a repo-controlled project
# config supplying it would hand a malicious branch the key to the operator's serve
# instance. REQUIRED whenever remoteHost is set: the adapter fails CLOSED (never invokes
# oracle) if remoteHost is set without it, so oracle's own ambient token
# (ORACLE_REMOTE_TOKEN / ~/.oracle/config.json browser.remoteToken) can never silently
# authenticate a busdriver transmission. Empty default. Never logged.
ultra_oracle_remote_token() { ultra_oracle_config_get_user '.ultraOracle.remoteToken' ''; }

# ultra_oracle_hide_window -> exit 0 if the automation Chrome window should be HIDDEN.
# Opt-in, VISIBLE by default (B8). Passing --browser-hide-window to oracle was
# root-caused as breaking its ChatGPT browser engine (the consult failed silently;
# see the STDOUT-to-.err capture in ultra-oracle.sh). The window is now VISIBLE by
# default; set `ultraOracle.hideWindow` to true in ~/.claude/busdriver.json to restore
# hiding. Opt-in-TRUE semantics sidestep the jq `// empty` collapse-false problem that
# previously made a default-true toggle unworkable: absent OR explicit-false both
# resolve to the 'false' default (visible); only an explicit true hides. USER config
# only (consistent with the rest of the ultraOracle block).
ultra_oracle_hide_window() {
  local v; v="$(ultra_oracle_config_get_user '.ultraOracle.hideWindow' 'false')"
  case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in true|1) return 0;; *) return 1;; esac
}

# ultra_oracle_surface_enabled <brainstorming|blueprintReview|council> -> exit 0 if true.
# USER config ONLY (security-sensitive — enabling transmits content to ChatGPT Pro;
# a repo-controlled project config must NOT be able to opt a reviewer in).
# Normalize: jq emits `true`, but resolve-cli.sh's python3 fallback emits `True`.
ultra_oracle_surface_enabled() {
  local v; v="$(ultra_oracle_config_get_user ".ultraOracle.${1}.enabled" 'false')"
  case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in true|1) return 0;; *) return 1;; esac
}
