#!/bin/bash
# resolve-cli.sh — Plugin-wide shared CLI library
#
# Single source of truth for CLI availability and resolution.
# Sourced by codex-reviewer, design-reviewer, and council.
#
# Usage (sourced):
#   source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve-cli.sh"
#   is_cli_available codex && echo "codex is installed"
#   resolved=$(resolve_review_cli)
#
# Usage (direct, machine-readable):
#   bash resolve-cli.sh --json
#
# Env var: BUSDRIVER_REVIEW_CLI
# Values: auto (default) | codex | gemini | droid | amp | opencode | claude | aider | builtin | none

# ── Low-level utilities (used by all three systems) ──────────────

is_cli_available() {
  local cli_name="$1"
  command -v "$cli_name" &>/dev/null
}

get_cli_version() {
  local cli_name="$1"
  if is_cli_available "$cli_name"; then
    "$cli_name" --version 2>/dev/null || echo "unknown"
  else
    echo "not-installed"
  fi
}

get_cli_install_hint() {
  local cli="$1"
  case "$cli" in
    codex)  echo "npm install -g @openai/codex" ;;
    gemini) echo "See https://github.com/google-gemini/gemini-cli" ;;
    claude) echo "See https://docs.anthropic.com/en/docs/claude-code" ;;
    aider)  echo "pip install aider-chat" ;;
    droid)  echo "See https://droid.dev" ;;
    amp)    echo "See https://ampcode.com" ;;
    opencode) echo "go install github.com/opencode-ai/opencode@latest" ;;
    *)      echo "Install '$cli' and ensure it is in your PATH" ;;
  esac
}

# ── Config file reader (jq preferred, python3 fallback) ──────
# Usage: _read_config_value "/path/to/busdriver.json" '.routes["council.critic"][0]'
# Returns: extracted value on stdout, empty if missing/error. Exit 1 on parse error.

_JSON_PARSER=""
_detect_json_parser() {
  if [[ -n "$_JSON_PARSER" ]]; then return; fi
  if command -v jq &>/dev/null; then
    _JSON_PARSER="jq"
  elif command -v python3 &>/dev/null; then
    _JSON_PARSER="python3"
  else
    echo "busdriver: cannot parse config — install jq or python3" >&2
    _JSON_PARSER="none"
  fi
}

_read_config_value() {
  local config_path="$1" jq_query="$2"
  [[ ! -f "$config_path" ]] && return 0

  _detect_json_parser

  case "$_JSON_PARSER" in
    jq)
      jq -r "$jq_query // empty" "$config_path" 2>/dev/null || return 1
      ;;
    python3)
      python3 -c "
import json, sys, re

def parse_jq_path(query):
    query = query.lstrip('.')
    parts = []
    while query:
        if query.startswith('[\"'):
            end = query.index('\"]')
            parts.append(query[2:end])
            query = query[end+2:]
        elif query.startswith('['):
            end = query.index(']')
            parts.append(query[1:end])
            query = query[end+1:]
        elif query.startswith('.'):
            query = query[1:]
        else:
            dot = query.find('.')
            bracket = query.find('[')
            if dot == -1 and bracket == -1:
                parts.append(query)
                break
            elif bracket != -1 and (dot == -1 or bracket < dot):
                parts.append(query[:bracket])
                query = query[bracket:]
            else:
                parts.append(query[:dot])
                query = query[dot:]
    return parts

try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    for k in parse_jq_path(sys.argv[2]):
        if isinstance(data, list):
            data = data[int(k)]
        elif isinstance(data, dict):
            data = data.get(k)
        else:
            sys.exit(0)
        if data is None:
            sys.exit(0)
    if data is not None:
        print(data)
except (KeyError, IndexError, TypeError):
    pass
except (json.JSONDecodeError, OSError) as e:
    print('busdriver: config parse error: ' + str(e), file=sys.stderr)
    sys.exit(1)
" "$config_path" "$jq_query" 2>/dev/null || return 1
      ;;
    none)
      return 0
      ;;
  esac
}

# ── Portable timeout wrapper ────────────────────────────────────
# macOS does not ship GNU timeout. Try timeout, then gtimeout,
# then fall back to a Perl alarm wrapper.

_portable_timeout() {
  local duration="$1"
  shift

  if command -v timeout &>/dev/null; then
    timeout "$duration" "$@"
  elif command -v gtimeout &>/dev/null; then
    gtimeout "$duration" "$@"
  else
    # Perl alarm fallback (available on all macOS)
    perl -e '
      use POSIX ":sys_wait_h";
      our $pid = fork();
      if (!defined $pid) { die "fork failed: $!"; }
      if ($pid == 0) { alarm 0; exec @ARGV[1..$#ARGV]; die "exec failed: $!"; }
      $SIG{ALRM} = sub { kill "TERM", $pid if $pid; exit 124 };
      alarm $ARGV[0];
      waitpid($pid, 0);
      alarm 0;
      if ($? & 127) { exit(128 + ($? & 127)); }
      exit($? >> 8);
    ' "$duration" "$@"
  fi
}

# ── Per-role CLI resolution with config + fallback chain ─────
# Usage: resolve_role_cli "council.critic"
# Precedence: env var > project config > user config > defaults > auto-detect
# Returns: CLI name, "builtin", "none", or "missing:<cli>"

_resolve_from_route_array() {
  local config_path="$1" role_key="$2"
  local i=0 cli
  while true; do
    cli=$(_read_config_value "$config_path" ".routes[\"$role_key\"][$i]")
    [[ -z "$cli" ]] && break
    if [[ "$cli" == "auto" ]]; then
      for auto_cli in codex gemini droid amp opencode; do
        is_cli_available "$auto_cli" && echo "$auto_cli" && return 0
      done
    elif [[ "$cli" == "none" || "$cli" == "builtin" ]]; then
      echo "$cli" && return 0
    elif is_cli_available "$cli"; then
      echo "$cli" && return 0
    fi
    i=$((i + 1))
  done
  return 1
}

resolve_role_cli() {
  local role_key="$1"
  local env_cli="${BUSDRIVER_REVIEW_CLI:-}"

  # Step 1: Env var override (hard-fail if unavailable)
  if [[ -n "$env_cli" && "$env_cli" != "auto" ]]; then
    if [[ "$env_cli" == "none" || "$env_cli" == "builtin" ]]; then
      echo "$env_cli" && return
    fi
    is_cli_available "$env_cli" && echo "$env_cli" && return
    echo "missing:$env_cli" && return
  fi

  # Step 2: Project config routes
  local project_config _git_root
  _git_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  project_config="${_git_root:+$_git_root/.claude/busdriver.json}"
  [[ -z "$project_config" ]] && project_config=""  # empty _git_root → skip
  if [[ -f "$project_config" ]]; then
    local ver
    ver=$(_read_config_value "$project_config" '.version')
    if [[ -n "$ver" && "$ver" != "1" ]]; then
      echo "busdriver: ignoring $project_config (version $ver != 1)" >&2
    else
      _resolve_from_route_array "$project_config" "$role_key" && return
    fi
  fi

  # Step 3: User config routes
  local user_config="$HOME/.claude/busdriver.json"
  if [[ -f "$user_config" ]]; then
    local ver
    ver=$(_read_config_value "$user_config" '.version')
    if [[ -n "$ver" && "$ver" != "1" ]]; then
      echo "busdriver: ignoring $user_config (version $ver != 1)" >&2
    else
      _resolve_from_route_array "$user_config" "$role_key" && return
    fi
  fi

  # Step 4: Defaults from project config, then user config
  for cfg in "$project_config" "$user_config"; do
    [[ ! -f "$cfg" ]] && continue
    local default_primary
    default_primary=$(_read_config_value "$cfg" '.defaults.primary')
    if [[ -n "$default_primary" ]]; then
      if [[ "$default_primary" == "auto" ]]; then
        break
      elif [[ "$default_primary" == "none" || "$default_primary" == "builtin" ]]; then
        echo "$default_primary" && return
      elif is_cli_available "$default_primary"; then
        echo "$default_primary" && return
      fi
      local default_fallback
      default_fallback=$(_read_config_value "$cfg" '.defaults.fallback')
      if [[ -n "$default_fallback" && "$default_fallback" != "auto" ]]; then
        if [[ "$default_fallback" == "none" || "$default_fallback" == "builtin" ]]; then
          echo "$default_fallback" && return
        elif is_cli_available "$default_fallback"; then
          echo "$default_fallback" && return
        fi
      fi
    fi
  done

  # Step 5: Auto-detect
  for cli in codex gemini droid amp opencode; do
    is_cli_available "$cli" && echo "$cli" && return
  done

  # Step 6: Ultimate fallback
  echo "builtin"
}

# ── Review CLI resolution: resolve to ONE cli based on env var ──

resolve_review_cli() {
  resolve_role_cli "codex-reviewer.reviewer"
}

execute_review() {
  local cli="$1"
  local prompt="$2"
  local duration="${3:-1200}"

  # IMPORTANT: Caller MUST wrap this call to handle non-zero exits under set -e:
  #   execute_review ... || exit_code=$?
  #   case ${exit_code:-0} in 3) handle_builtin ;; 0) handle_pass ;; *) handle_fail ;; esac
  #
  # `none` is NOT handled here — caller intercepts before calling execute_review.
  # All CLIs receive prompts via stdin to avoid ARG_MAX limits on large diffs.
  # Use printf instead of echo for binary-safe output.
  case "$cli" in
    codex)   printf '%s' "$prompt" | _portable_timeout "$duration" codex review - 2>&1 ;;
    gemini)  printf '%s' "$prompt" | _portable_timeout "$duration" gemini 2>&1 ;;
    claude)  printf '%s' "$prompt" | _portable_timeout "$duration" claude -p --output-format text 2>&1 ;;
    aider)   local _tmp; _tmp=$(mktemp -t busdriver-aider-XXXXXX)
             printf '%s' "$prompt" > "$_tmp"
             _portable_timeout "$duration" aider --message-file "$_tmp" --no-auto-commits 2>&1
             local _rc=$?; rm -f "$_tmp"; return $_rc ;;
    droid)   printf '%s' "$prompt" | _portable_timeout "$duration" droid exec 2>&1 ;;
    amp)     local _tmp; _tmp=$(mktemp -t busdriver-amp-XXXXXX)
             printf '%s' "$prompt" > "$_tmp"
             _portable_timeout "$duration" amp review --instructions "$_tmp" 2>&1
             local _rc=$?; rm -f "$_tmp"; return $_rc ;;
    opencode) printf '%s' "$prompt" | _portable_timeout "$duration" opencode 2>&1 ;;
    builtin) echo "BUILTIN_FALLBACK"; return 3 ;;
    *)       echo "Unsupported CLI: $cli" >&2; return 1 ;;
  esac
}

# ── Machine-readable interface (--json) ─────────────────────────
# Guard: only runs when executed directly, not when sourced
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = "--json" ]; then
  configured="${BUSDRIVER_REVIEW_CLI:-auto}"
  resolved=$(resolve_review_cli)
  version=""
  case "$resolved" in
    codex|gemini|droid|amp|opencode|claude|aider) version=$(get_cli_version "$resolved") ;;
    builtin|none|missing:*|unsupported:*) version="n/a" ;;
  esac

  # Sanitize strings for JSON (strip quotes, backslashes, newlines)
  _json_safe() { tr -d '"\\\n' | head -1; }

  configured=$(echo "$configured" | _json_safe)
  resolved=$(echo "$resolved" | _json_safe)
  version=$(echo "$version" | _json_safe)

  # Report availability for all supported CLIs
  clis_json=""
  for cli in codex gemini droid amp opencode claude aider; do
    avail=$(is_cli_available "$cli" && echo true || echo false)
    ver=$(get_cli_version "$cli" | _json_safe)
    clis_json="${clis_json}\"${cli}\":{\"available\":${avail},\"version\":\"${ver}\"},"
  done
  clis_json="{${clis_json%,}}"

  printf '{"configured":"%s","resolved":"%s","version":"%s","clis":%s}\n' \
    "$configured" "$resolved" "$version" "$clis_json"
  exit 0
fi
