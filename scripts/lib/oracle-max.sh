#!/bin/bash
# oracle-max.sh — the ONLY surface that touches the oracle CLI (Layer-2).
# Advisory GPT-5.5 Pro consult via ChatGPT Pro subscription (--engine browser).
# Fails CLOSED: prints ONE typed status token; callers MUST surface it, never
# silently skip. Reuses resolve-cli.sh _portable_timeout + is_cli_available.
# Harness-neutral; no bash-4-isms (no associative arrays / mapfile).
_ORACLE_MAX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_ORACLE_MAX_DIR}/oracle-max-config.sh"   # also transitively sources resolve-cli.sh

# oracle_max_consult --prompt <t> | --prompt-file <p>  [--context <glob>]... \
#   --out <path> [--mode blocking|background] [--timeout-cap-seconds <n>] [--slug <words>]
# Prints exactly one of: ok | skipped:unavailable | skipped:user | timeout | error | dispatched
#
# --prompt-file is the ADAPTER's interface (injection-safe for untrusted text);
# oracle v0.15.0 has no --prompt-file flag, so the file content is passed via
# --prompt "$(cat ...)". Command-substitution output is NOT re-parsed by the
# shell, so backticks/$()/$VAR in the file stay literal.
oracle_max_consult() {
  # oracle requires a 3-5 word --slug; default accordingly (callers override).
  local prompt="" prompt_file="" mode="blocking" out="" slug="oracle max consult" cap=""
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
  [ -n "$out" ] || { printf 'error'; return 1; }
  # Require a prompt source — otherwise oracle would be dispatched with an empty
  # prompt and could return a meaningless advisory.
  [ -n "$prompt" ] || [ -n "$prompt_file" ] || { printf 'error'; return 1; }
  [ -n "$cap" ] || cap="$(oracle_max_timeout_cap)"
  # Validate the cap regardless of source (explicit --timeout-cap-seconds bypasses
  # oracle_max_timeout_cap); a 0/non-numeric value would break the fail-closed timeout.
  case "$cap" in ''|*[!0-9]*|0)
    echo "oracle-max: invalid timeout cap '$cap' — using config/default" >&2
    cap="$(oracle_max_timeout_cap)" ;;
  esac
  # Fail closed if the output dir can't be created — otherwise background mode
  # would return 'dispatched' but the child could never write "$out.rc".
  mkdir -p "$(dirname "$out")" 2>/dev/null || { printf 'error'; return 1; }

  # Operator escape (persistent opt-out; fail-closed-with-escape). State-dir resolved.
  local state_dir git_root skip
  state_dir="${BUSDRIVER_STATE_DIR:-.claude}"
  git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  skip="${git_root:+$git_root/}$state_dir/skip-oracle-max.local"
  if [ -f "$skip" ]; then printf 'skipped:user'; return 0; fi

  # Health check — fail CLOSED (typed), never silent.
  if ! is_cli_available oracle; then printf 'skipped:unavailable'; return 3; fi

  local model profile; model="$(oracle_max_model)"; profile="$(oracle_max_chrome_profile)"

  # Build argv (set -- positional building is bash-3.2 safe).
  set -- --engine browser -m "$model" --timeout "$cap" \
         --write-output "$out" --no-notify --heartbeat 30 --slug "$slug"
  # Opt-in profile clone (see oracle_max_chrome_profile): empty by default so we
  # do NOT expose the operator's main browser session unless explicitly configured.
  [ -n "$profile" ] && [ -d "$profile" ] && set -- "$@" --copy-profile "$profile"
  local g; for g in "${ctx_arr[@]:-}"; do [ -n "$g" ] && set -- "$@" --file "$g"; done
  if [ -n "$prompt_file" ]; then
    # Fail closed if the prompt file is unreadable/empty — otherwise a silent cat
    # failure would invoke oracle with an empty prompt.
    [ -r "$prompt_file" ] && [ -s "$prompt_file" ] || { printf 'error'; return 1; }
    local pf_size; pf_size="$(wc -c < "$prompt_file" 2>/dev/null || echo 0)"
    if [ "$pf_size" -gt "${ORACLE_MAX_INLINE_BYTES:-100000}" ]; then
      # Too large to safely inline into argv (ARG_MAX) — attach as a file instead.
      set -- "$@" --file "$prompt_file" \
        --prompt "Follow the instructions in the attached file: $(basename "$prompt_file")"
    else
      local pf_content; pf_content="$(cat "$prompt_file")"
      set -- "$@" --prompt "$pf_content"
    fi
  else set -- "$@" --prompt "$prompt"; fi

  if [ "$mode" = "background" ]; then
    # RUN_ID-scoped output is the CALLER's responsibility (--out includes RUN_ID).
    # Emit an .rc marker on completion so the caller can bounded-wait + read status.
    # disown so an early parent exit cannot orphan/kill it before the .rc lands.
    ( set +e   # a caller's errexit must NOT abort the subshell before "$out.rc" is written
      _portable_timeout "${cap}" oracle "$@" >/dev/null 2>&1; _omx_bg_rc=$?
      # Map exit-0-but-empty-verdict to failure so the .rc matches blocking mode's
      # fail-closed contract (timeout already surfaces as rc 124).
      [ "$_omx_bg_rc" = 0 ] && [ ! -s "$out" ] && _omx_bg_rc=1
      printf '%s' "$_omx_bg_rc" > "$out.rc" ) &
    disown 2>/dev/null || true
    printf 'dispatched'; return 0
  fi

  # blocking, under the portable timeout cap. Keep stderr (oracle's --heartbeat
  # progress) on the terminal; only discard stdout.
  local rc
  _portable_timeout "${cap}" oracle "$@" >/dev/null; rc=$?
  if [ "$rc" = 124 ]; then printf 'timeout'; return 124; fi
  if [ "$rc" != 0 ]; then printf 'error'; return 1; fi
  [ -s "$out" ] || { printf 'error'; return 1; }   # exit 0 but no verdict = fail-closed
  printf 'ok'; return 0
}
