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
# Values: auto (default) | codex | gemini | claude | aider | builtin | none

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
    *)      echo "Install '$cli' and ensure it is in your PATH" ;;
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

# ── Review CLI resolution: resolve to ONE cli based on env var ──

resolve_review_cli() {
  local cli="${BUSDRIVER_REVIEW_CLI:-auto}"
  case "$cli" in
    auto)
      is_cli_available codex && echo "codex" && return
      is_cli_available gemini && echo "gemini" && return
      echo "builtin" ;;
    none)    echo "none" ;;
    builtin) echo "builtin" ;;
    codex|gemini|claude|aider)
      is_cli_available "$cli" && echo "$cli" && return
      echo "missing:$cli" ;;
    *)
      echo "unsupported:$cli" ;;
  esac
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
    codex|gemini|claude|aider) version=$(get_cli_version "$resolved") ;;
    builtin|none|missing:*|unsupported:*) version="n/a" ;;
  esac

  # Sanitize strings for JSON (strip quotes, backslashes, newlines)
  _json_safe() { tr -d '"\\\n' | head -1; }

  configured=$(echo "$configured" | _json_safe)
  resolved=$(echo "$resolved" | _json_safe)
  version=$(echo "$version" | _json_safe)

  # Report availability for all supported CLIs
  clis_json=""
  for cli in codex gemini claude aider; do
    avail=$(is_cli_available "$cli" && echo true || echo false)
    ver=$(get_cli_version "$cli" | _json_safe)
    clis_json="${clis_json}\"${cli}\":{\"available\":${avail},\"version\":\"${ver}\"},"
  done
  clis_json="{${clis_json%,}}"

  printf '{"configured":"%s","resolved":"%s","version":"%s","clis":%s}\n' \
    "$configured" "$resolved" "$version" "$clis_json"
  exit 0
fi
