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
# Portable dir resolution. BASH_SOURCE is unset under zsh (and other non-bash shells), where
# `dirname "${BASH_SOURCE[0]}"` silently collapses to "." and mis-sources the sibling libs from
# the CWD — functions end up undefined with no error. Guard loudly: this lib is bash-only, so
# fail closed rather than half-load.
if [ -z "${BASH_SOURCE:-}" ]; then
  echo "ultra-oracle.sh: ERROR — must be sourced under bash (BASH_SOURCE unset; zsh/other shells mis-resolve the script dir and half-load)" >&2
  # shellcheck disable=SC2317  # reached when sourced under a non-bash shell
  return 1 2>/dev/null || exit 1
fi
_ULTRA_ORACLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_ULTRA_ORACLE_DIR}/ultra-oracle-config.sh"   # also transitively sources resolve-cli.sh

# _ultra_oracle_verdict_ok <file> -> 0 if the file holds a usable verdict.
# A usable verdict must be more than a degenerate token. The oracle browser engine can
# exit 0 yet write a near-empty body (observed live: a 2-byte "I\n" when extraction
# races the response stream or the ChatGPT session is stale). A bare `-s` (non-empty)
# check accepts that and renders junk as a successful verdict (false-ok). Require a
# minimum count of NON-WHITESPACE bytes so single-token captures ("I", "ok", "n/a")
# fail closed while any real one-sentence advisory passes. Tunable via
# ULTRA_ORACLE_MIN_VERDICT_BYTES (default 8; invalid/empty/zero falls back to 8).
# Note: wc -c counts bytes, not Unicode characters — multibyte chars count more than
# one toward the floor. ASCII verdicts dominate in practice; the byte floor is the
# correct primitive here (we're guarding against near-empty captures, not charset issues).
_ultra_oracle_verdict_ok() {
  local f="$1" min nonws
  min="${ULTRA_ORACLE_MIN_VERDICT_BYTES:-8}"
  case "$min" in ''|*[!0-9]*|0) min=8;; esac
  [[ -s "$f" ]] || return 1
  nonws="$(tr -d '[:space:]' < "$f" 2>/dev/null | wc -c | tr -dc '0-9')"
  [[ -n "$nonws" ]] || return 1
  [ "$nonws" -ge "$min" ]
}

# _ultra_oracle_diagnose_hint <err-file> -> print ONE human-actionable line (no
# trailing newline) naming the operator's next step for a KNOWN oracle failure
# signature, else print nothing. Matches the ABE / login / Cloudflare cases from
# issue #340 so a failed consult tells the operator WHAT to do instead of surfacing a
# bare 'error' token. Read-only; matches only oracle's own captured STDOUT text, never
# any secret (the token is never written to the .err file).
_ultra_oracle_diagnose_hint() {
  local f="$1"
  [[ -r "$f" ]] || return 0
  # Backticks below are LITERAL operator-facing command examples, not command
  # substitution — the strings are printed verbatim, never evaluated.
  # shellcheck disable=SC2016
  if grep -qiE 'no chatgpt cookies|cookie extraction is unavailable|cookie sync' "$f" 2>/dev/null; then
    printf 'cookie sync unavailable (this Chrome blocks programmatic cookie decryption, #340): run `oracle serve --manual-login --host 127.0.0.1 --token <T>`, sign in once, then set ultraOracle.remoteHost + ultraOracle.remoteToken in ~/.claude/busdriver.json'
  elif grep -qiE 'login button detected|session not detected|not signed in|please log ?in' "$f" 2>/dev/null; then
    printf 'ChatGPT session not detected: sign in to the `oracle serve --manual-login` browser window (or re-login), then re-run'
  elif grep -qiE 'just a moment|cloudflare|verify you are human|are you human|challenge' "$f" 2>/dev/null; then
    printf 'Cloudflare "Just a moment" challenge: complete the check in the serve browser window, then re-run'
  fi
}

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
  local _uora_cap_ceil
  _uora_cap_ceil="$(_ultra_oracle_sanitize_ceiling "${ULTRA_ORACLE_CAP_CEILING:-3600}")"
  # A value with 19+ digits would overflow bash's signed-64-bit `-gt` (INT64_MAX is
  # 19 digits) and could wrap to compare as SMALLER, slipping an absurd cap past the
  # guardrail; anything that long is nonsensical as a second count, so clamp it
  # outright. Below 19 digits the numeric `-gt` is safe.
  if [ "${#cap}" -ge 19 ] || [ "$cap" -gt "$_uora_cap_ceil" ]; then
    echo "ultra-oracle: timeout cap $cap exceeds ceiling $_uora_cap_ceil — clamping" >&2
    cap="$_uora_cap_ceil"
  fi
  # Fail closed if the output dir can't be created — otherwise background mode
  # would return 'dispatched' but the child could never write "$out.rc".
  mkdir -p "$(dirname "$out")" 2>/dev/null || { printf 'error'; return 1; }
  # Clear any stale output from a prior run at the same path before dispatching.
  # A non-empty leftover "$out" would make the fail-closed verdict check
  # succeed even if this oracle invocation exits 0 but writes nothing — silently
  # returning ok with stale content. Truncate both output and .rc marker so each
  # run starts from a clean slate regardless of caller's output-path reuse policy.
  # `--` guards against option-looking paths; fail CLOSED if the cleanup itself
  # fails — a surviving stale file is the exact bug this prevents, so suppressing
  # the error would defeat the purpose. `rm -f` is a no-op on nonexistent files,
  # so the || branch only fires when a file EXISTS but cannot be removed.
  rm -f -- "$out" "$out.rc" "$out.err" "$out.hint" || {
    echo "ultra-oracle: cannot clear stale output '$out' — failing closed" >&2
    printf 'error'; return 1
  }

  # Operator escape (persistent opt-out; fail-closed-with-escape). State-dir resolved.
  local state_dir git_root skip
  state_dir="${BUSDRIVER_STATE_DIR:-.claude}"
  git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  skip="${git_root:+$git_root/}$state_dir/skip-ultra-oracle.local"
  if [[ -f "$skip" ]]; then printf 'skipped:user'; return 0; fi

  # Health check — fail CLOSED (typed), never silent.
  if ! is_cli_available oracle; then printf 'skipped:unavailable'; return 3; fi

  local model profile cookie_path remote_host remote_token
  model="$(ultra_oracle_model)"; profile="$(ultra_oracle_chrome_profile)"
  cookie_path="$(ultra_oracle_cookie_path)"
  remote_host="$(ultra_oracle_remote_host)"; remote_token="$(ultra_oracle_remote_token)"

  # Build argv (set -- positional building is bash-3.2 safe).
  set -- --engine browser -m "$model" --timeout "$cap" \
         --write-output "$out" --no-notify --heartbeat 30 --slug "$slug"
  # Session source, in precedence order (all opt-in; empty by default so we do NOT
  # expose the operator's main browser session unless explicitly configured):
  #   1. remoteHost   — delegate to a running `oracle serve` (issue #340). The ONLY
  #                     path that works when Chrome blocks programmatic cookie
  #                     decryption (recent cookie-encryption hardening), where
  #                     cookiePath/copy-profile cannot reuse the session. serve owns
  #                     its own signed-in browser.
  #   2. cookiePath   — decrypt a live Cookies DB in place via the OS keychain.
  #   3. chromeProfileDir — clone a dedicated profile (heaviest; last resort).
  # These are MUTUALLY EXCLUSIVE: when remoteHost is set we pass ONLY
  # --remote-host/--remote-token and never also --browser-cookie-path/--copy-profile
  # (a second, ABE-broken session source that would confuse oracle). A configured
  # cookiePath is AUTHORITATIVE within its own branch: if it is set but unreadable we
  # FAIL CLOSED rather than let oracle default to the standard Chrome profile and
  # silently reuse whatever ChatGPT session is signed in there (wrong account / a
  # data-boundary surprise the operator did not authorize). Fix the path or unset it.
  if [[ -n "$remote_host" ]]; then
    # remoteToken is REQUIRED with remoteHost — fail CLOSED if empty rather than invoke
    # oracle with --remote-host alone. Oracle resolves its token as
    #   cliToken ?? userConfig.browser.remoteToken ?? ORACLE_REMOTE_TOKEN
    # (verified in oracle 0.15.2 remoteServiceConfig.js), so proceeding without
    # --remote-token would let a token from oracle's OWN ambient config/env silently
    # authenticate and transmit the design to the configured host — outside busdriver's
    # USER-config trust boundary. The whole ultraOracle block is USER-config-only by
    # design; the delegation credential must come from there too, never from oracle's
    # ambient environment. Same fail-closed posture as the unreadable-cookiePath branch.
    if [[ -z "$remote_token" ]]; then
      echo "ultra-oracle: remoteHost set but remoteToken empty — failing closed (a token from oracle's own config/env must NOT silently authenticate a busdriver transmission). Set ultraOracle.remoteToken in ~/.claude/busdriver.json" >&2
      printf 'error'; return 1
    fi
    set -- "$@" --remote-host "$remote_host" --remote-token "$remote_token"
  elif [[ -n "$cookie_path" ]]; then
    if [[ -r "$cookie_path" ]]; then
      set -- "$@" --browser-cookie-path "$cookie_path"
    else
      echo "ultra-oracle: cookiePath '$cookie_path' unreadable — failing closed (configured cookiePath is authoritative; NOT degrading to the default Chrome session or --copy-profile)" >&2
      printf 'error'; return 1
    fi
  elif [[ -n "$profile" ]] && [[ -d "$profile" ]]; then
    set -- "$@" --copy-profile "$profile"
  fi
  # Hide the automation Chrome window ONLY when explicitly opted in (B8). Passing
  # --browser-hide-window was root-caused as breaking oracle's ChatGPT browser engine,
  # so the window is now VISIBLE by default; set ultraOracle.hideWindow=true to restore.
  if ultra_oracle_hide_window; then set -- "$@" --browser-hide-window; fi
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
      # Capture oracle STDOUT+STDERR to "$out.err" (B8): oracle emits its failure
      # diagnostics on STDOUT, so the old >/dev/null 2>&1 discarded them and every
      # failure looked silent. Keep the file on failure for diagnosis; remove on success.
      _portable_timeout "${cap}" oracle "$@" >"$out.err" 2>&1; _uora_bg_rc=$?
      # Map exit-0-but-empty-verdict to failure so the .rc matches blocking mode's
      # fail-closed contract (timeout already surfaces as rc 124).
      [[ "$_uora_bg_rc" = 0 ]] && ! _ultra_oracle_verdict_ok "$out" && _uora_bg_rc=1
      if [[ "$_uora_bg_rc" = 0 ]]; then
        rm -f "$out.err" "$out.hint"   # success: drop the captured stdout + any stale hint
      else
        # Persist a human-actionable hint (#340) next to the .err so the caller's FAILED
        # banner can name the operator's next step, not just a bare status code.
        _uora_hint="$(_ultra_oracle_diagnose_hint "$out.err")"
        if [[ -n "$_uora_hint" ]]; then printf '%s' "$_uora_hint" > "$out.hint"; else rm -f "$out.hint"; fi
      fi
      printf '%s' "$_uora_bg_rc" > "$out.rc" ) &
    disown 2>/dev/null || true
    printf 'dispatched'; return 0
  fi

  # blocking, under the portable timeout cap. Keep stderr (oracle's --heartbeat
  # progress) on the terminal; capture STDOUT to "$out.err" (B8) — oracle emits its
  # failure diagnostics on STDOUT, so the old >/dev/null hid them and made every
  # failure look silent. The .err file is kept on any failure (a stderr pointer names
  # it) and removed on success.
  # errexit-safe: capture rc via `|| rc=$?` so a non-zero oracle exit cannot abort
  # the caller (this lib may be sourced under `set -e`) before the status token is
  # printed — the fail-closed 'error'/'timeout' tokens below depend on reaching them.
  local rc=0 _hint=""
  _portable_timeout "${cap}" oracle "$@" >"$out.err" || rc=$?
  if [[ "$rc" = 124 ]]; then
    # A login/Cloudflare wall that never clears also manifests AS a timeout — the
    # partial page oracle wrote to $out.err before the cap fired can still carry the
    # signature, so name the operator's next step here too, not only on hard errors.
    _hint="$(_ultra_oracle_diagnose_hint "$out.err")"; [[ -n "$_hint" ]] && echo "ultra-oracle: $_hint" >&2
    echo "ultra-oracle: timed out after ${cap}s — oracle STDOUT captured at $out.err" >&2; printf 'timeout'; return 124
  fi
  if [[ "$rc" != 0 ]]; then
    # Name the operator's next step for a known failure (ABE / login / Cloudflare, #340)
    # before the generic pointer, so a failed consult is actionable, not just 'error'.
    _hint="$(_ultra_oracle_diagnose_hint "$out.err")"; [[ -n "$_hint" ]] && echo "ultra-oracle: $_hint" >&2
    echo "ultra-oracle: oracle exited $rc — STDOUT/diagnostics captured at $out.err" >&2; printf 'error'; return 1
  fi
  _ultra_oracle_verdict_ok "$out" || {
    _hint="$(_ultra_oracle_diagnose_hint "$out.err")"; [[ -n "$_hint" ]] && echo "ultra-oracle: $_hint" >&2
    echo "ultra-oracle: exit 0 but missing/degenerate verdict — oracle STDOUT at $out.err" >&2; printf 'error'; return 1
  }   # exit 0 but missing/degenerate verdict = fail-closed
  rm -f "$out.err"   # success: drop the captured stdout
  printf 'ok'; return 0
}
