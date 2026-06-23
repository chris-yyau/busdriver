#!/bin/bash
# ultra-oracle.sh — the ONLY surface that touches the oracle CLI (Layer-2).
# Advisory GPT-5.5 Pro consult via ChatGPT Pro subscription (--engine browser).
# Fails CLOSED: prints ONE typed status token; callers MUST surface it, never
# silently skip. Reuses resolve-cli.sh _portable_timeout + is_cli_available.
# Harness-neutral; no bash-4-isms (no associative arrays / mapfile).
# Conditional style: [[ ]] for string/file tests; POSIX [ ] for integer -gt/-ge
# comparisons. `[ ]` does base-10 strtol with NO arithmetic evaluation, which
# avoids [[ ]]'s octal-parse of leading-zero values (e.g. "09999") AND its
# command-substitution-in-arithmetic injection surface (e.g. RHS "a[$(cmd)]").
_ULTRA_ORACLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_ULTRA_ORACLE_DIR}/ultra-oracle-config.sh"   # also transitively sources resolve-cli.sh

# ultra_oracle_consult --prompt <t> | --prompt-file <p>  [--context <glob>]... \
#   --out <path> [--mode blocking|background] [--timeout-cap-seconds <n>] [--slug <words>]
# Prints exactly one of: ok | skipped:unavailable | skipped:user | timeout | error | dispatched
#
# --prompt-file is the ADAPTER's interface (injection-safe for untrusted text);
# oracle v0.15.0 has no --prompt-file flag, so the file content is passed via
# --prompt "$(cat ...)". Command-substitution output is NOT re-parsed by the
# shell, so backticks/$()/$VAR in the file stay literal.
ultra_oracle_consult() {
  # oracle requires a 3-5 word --slug; default accordingly (callers override).
  local prompt="" prompt_file="" mode="blocking" out="" slug="ultra oracle consult" cap=""
  local -a ctx_arr=()   # indexed array (bash-3.2 safe) — preserves paths with spaces
  while [ $# -gt 0 ]; do
    # Value-flags require an argument; a missing value returns a typed 'error'
    # rather than an unbound-variable crash under the caller's `set -u`.
    case "$1" in
      --prompt|--prompt-file|--context|--mode|--out|--slug|--timeout-cap-seconds)
        [ $# -ge 2 ] || { printf 'error'; return 1; } ;;
    esac
    case "$1" in
      --prompt) prompt="$2"; shift 2;;
      --prompt-file) prompt_file="$2"; shift 2;;
      --context) ctx_arr+=("$2"); shift 2;;
      --mode) mode="$2"; shift 2;;
      --out) out="$2"; shift 2;;
      --slug) slug="$2"; shift 2;;
      --timeout-cap-seconds) cap="$2"; shift 2;;
      *) shift;;
    esac
  done
  [[ -n "$out" ]] || { printf 'error'; return 1; }
  # Require a prompt source — otherwise oracle would be dispatched with an empty
  # prompt and could return a meaningless advisory.
  [[ -n "$prompt" ]] || [[ -n "$prompt_file" ]] || { printf 'error'; return 1; }
  [[ -n "$cap" ]] || cap="$(ultra_oracle_timeout_cap)"
  # Validate the cap regardless of source (explicit --timeout-cap-seconds bypasses
  # ultra_oracle_timeout_cap); a 0/non-numeric value would break the fail-closed timeout.
  # Strip leading zeros on an all-digit cap so "0600" normalizes to "600" and any
  # all-zero string ("00") collapses to "" — rejected below. A 0 cap is unsafe:
  # `timeout 0` / the Perl fallback's `alarm 0` DISABLE the timeout (unbounded run).
  case "$cap" in *[!0-9]*) : ;; *) cap="${cap#"${cap%%[!0]*}"}" ;; esac
  case "$cap" in ''|*[!0-9]*|0)
    echo "ultra-oracle: invalid timeout cap '$cap' — using config/default" >&2
    cap="$(ultra_oracle_timeout_cap)" ;;
  esac
  # Clamp an explicit numeric --timeout-cap-seconds to the same ceiling
  # ultra_oracle_timeout_cap enforces (default 3600s) — otherwise an explicit cap
  # bypasses the guardrail and can stall a reviewer with an arbitrarily long wait.
  local _omx_cap_ceil="${ULTRA_ORACLE_CAP_CEILING:-3600}"
  case "$_omx_cap_ceil" in ''|*[!0-9]*|0) _omx_cap_ceil=3600;; esac
  # An absurdly long (19+ digit) ceiling would itself overflow the `-gt` below;
  # reset it so the cap-side guard is sufficient for overflow safety.
  [ "${#_omx_cap_ceil}" -ge 19 ] && _omx_cap_ceil=3600
  # A value with 19+ digits would overflow bash's signed-64-bit `-gt` (INT64_MAX is
  # 19 digits) and could wrap to compare as SMALLER, slipping an absurd cap past the
  # guardrail; anything that long is nonsensical as a second count, so clamp it
  # outright. Below 19 digits the numeric `-gt` is safe.
  if [ "${#cap}" -ge 19 ] || [ "$cap" -gt "$_omx_cap_ceil" ]; then
    echo "ultra-oracle: timeout cap $cap exceeds ceiling $_omx_cap_ceil — clamping" >&2
    cap="$_omx_cap_ceil"
  fi
  # Fail closed if the output dir can't be created — otherwise background mode
  # would return 'dispatched' but the child could never write "$out.rc".
  mkdir -p "$(dirname "$out")" 2>/dev/null || { printf 'error'; return 1; }

  # Operator escape (persistent opt-out; fail-closed-with-escape). State-dir resolved.
  local state_dir git_root skip
  state_dir="${BUSDRIVER_STATE_DIR:-.claude}"
  git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  skip="${git_root:+$git_root/}$state_dir/skip-ultra-oracle.local"
  if [[ -f "$skip" ]]; then printf 'skipped:user'; return 0; fi

  # Health check — fail CLOSED (typed), never silent.
  if ! is_cli_available oracle; then printf 'skipped:unavailable'; return 3; fi

  local model profile cookie_path
  model="$(ultra_oracle_model)"; profile="$(ultra_oracle_chrome_profile)"
  cookie_path="$(ultra_oracle_cookie_path)"

  # Build argv (set -- positional building is bash-3.2 safe).
  set -- --engine browser -m "$model" --timeout "$cap" \
         --write-output "$out" --no-notify --heartbeat 30 --slug "$slug"
  # Session reuse (both opt-in; empty by default so we do NOT expose the operator's
  # main browser session unless explicitly configured). Prefer an explicit cookie DB
  # (--browser-cookie-path) — it decrypts the live session in place via the OS keychain
  # and is the reliable headless path where app-bound encryption defeats --copy-profile.
  # A configured cookiePath is AUTHORITATIVE: if it is set we never silently fall back
  # to a full-profile clone (a heavier, different-surface operation the operator did not
  # ask for). If it is set but unreadable, FAIL CLOSED with a typed 'error' rather than
  # run anyway — oracle would otherwise default to the standard Chrome profile and
  # silently reuse whatever ChatGPT session is signed in there (wrong account / a
  # data-boundary surprise the operator did not authorize). Fix the path or unset it.
  if [[ -n "$cookie_path" ]]; then
    if [[ -r "$cookie_path" ]]; then
      set -- "$@" --browser-cookie-path "$cookie_path"
    else
      echo "ultra-oracle: cookiePath '$cookie_path' unreadable — failing closed (configured cookiePath is authoritative; NOT degrading to the default Chrome session or --copy-profile)" >&2
      printf 'error'; return 1
    fi
  elif [[ -n "$profile" ]] && [[ -d "$profile" ]]; then
    set -- "$@" --copy-profile "$profile"
  fi
  # Always hide the automation Chrome window — these are non-interactive background
  # advisory consults; a focus-stealing window is disruptive and never needed here.
  set -- "$@" --browser-hide-window
  local g; for g in "${ctx_arr[@]:-}"; do [[ -n "$g" ]] && set -- "$@" --file "$g"; done
  if [[ -n "$prompt_file" ]]; then
    # Fail closed if the prompt file is unreadable/empty — otherwise a silent cat
    # failure would invoke oracle with an empty prompt.
    if [[ ! -r "$prompt_file" ]] || [[ ! -s "$prompt_file" ]]; then printf 'error'; return 1; fi
    local pf_size; pf_size="$(wc -c < "$prompt_file" 2>/dev/null || echo 0)"
    if [ "$pf_size" -gt "${ULTRA_ORACLE_INLINE_BYTES:-100000}" ]; then
      # Too large to safely inline into argv (ARG_MAX) — attach as a file instead.
      set -- "$@" --file "$prompt_file" \
        --prompt "Follow the instructions in the attached file: $(basename "$prompt_file")"
    else
      local pf_content; pf_content="$(cat "$prompt_file")"
      set -- "$@" --prompt "$pf_content"
    fi
  else set -- "$@" --prompt "$prompt"; fi

  if [[ "$mode" = "background" ]]; then
    # RUN_ID-scoped output is the CALLER's responsibility (--out includes RUN_ID).
    # Emit an .rc marker on completion so the caller can bounded-wait + read status.
    # disown so an early parent exit cannot orphan/kill it before the .rc lands.
    ( set +e   # a caller's errexit must NOT abort the subshell before "$out.rc" is written
      _portable_timeout "${cap}" oracle "$@" >/dev/null 2>&1; _omx_bg_rc=$?
      # Map exit-0-but-empty-verdict to failure so the .rc matches blocking mode's
      # fail-closed contract (timeout already surfaces as rc 124).
      [[ "$_omx_bg_rc" = 0 ]] && [[ ! -s "$out" ]] && _omx_bg_rc=1
      printf '%s' "$_omx_bg_rc" > "$out.rc" ) &
    disown 2>/dev/null || true
    printf 'dispatched'; return 0
  fi

  # blocking, under the portable timeout cap. Keep stderr (oracle's --heartbeat
  # progress) on the terminal; only discard stdout.
  # errexit-safe: capture rc via `|| rc=$?` so a non-zero oracle exit cannot abort
  # the caller (this lib may be sourced under `set -e`) before the status token is
  # printed — the fail-closed 'error'/'timeout' tokens below depend on reaching them.
  local rc=0
  _portable_timeout "${cap}" oracle "$@" >/dev/null || rc=$?
  if [[ "$rc" = 124 ]]; then printf 'timeout'; return 124; fi
  if [[ "$rc" != 0 ]]; then printf 'error'; return 1; fi
  [[ -s "$out" ]] || { printf 'error'; return 1; }   # exit 0 but no verdict = fail-closed
  printf 'ok'; return 0
}
