#!/bin/bash
# resolve-cli.sh — Plugin-wide shared CLI library
#
# Single source of truth for CLI availability and resolution.
# Sourced by litmus, blueprint-review, and council.
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
# Values: auto (default) | codex | agy | droid | grok | builtin | none

# Intentional pipeline patterns throughout: ls | sort | tail for semver
# ordering, tr | head for JSON sanitisation, etc. — masked return values
# from the inner command are not load-bearing here.
# shellcheck disable=SC2312

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
    agy)    echo "See https://antigravity.google/docs/cli/" ;;
    droid)  echo "See https://droid.dev" ;;
    grok)   echo "See xAI Grok Build documentation (https://x.ai)" ;;
    *)      echo "Install '$cli' and ensure it is in your PATH" ;;
  esac
}

# ── Config file reader (jq preferred, python3 fallback) ──────
# Usage: _read_config_value "/path/to/busdriver.json" '.routes["council.critic"][0]'
# Returns: extracted value on stdout, empty if missing/error. Exit 1 on parse error.

# `${_JSON_PARSER:-}` (not a bare "") preserves a value inherited from the
# environment across re-sourcing — the deliberate test hook that lets
# test-ultimate-config.sh force `_JSON_PARSER=python3` to exercise the
# python3 normalization branch. Prod never sets it, so behavior is unchanged.
_JSON_PARSER="${_JSON_PARSER:-}"
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
except (KeyError, IndexError, TypeError, ValueError):
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

# _read_user_config_value <jq-path> <default>
# Reads ONLY the USER config (~/${BUSDRIVER_STATE_DIR:-.claude}/busdriver.json) —
# NEVER repo-controlled project config. Security-sensitive: callers gate
# external-transmission / cost / model surfaces on this, so a malicious branch
# must never be able to opt a reviewer in via committed project config.
# Returns the value, or <default> when absent/null/unreadable.
_read_user_config_value() {
    local jq_path="$1" default="$2" val="" state_dir="${BUSDRIVER_STATE_DIR:-.claude}"
    local user_config="$HOME/$state_dir/busdriver.json"
    if [[ -f "$user_config" ]]; then
        val="$(_read_config_value "$user_config" "$jq_path" 2>/dev/null || true)"
    fi
    if [[ -n "$val" && "$val" != "null" ]]; then printf '%s' "$val"; else printf '%s' "$default"; fi
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

# ── Runtime droid fallback predicate ────────────────────────────
# Should a FAILED primary CLI fall back to droid at runtime? Shared by the
# council (dispatch.sh — per-voice, no cap) and blueprint-review
# (run-design-review-loop.sh — capped at one voice). This is the RUNTIME
# fallback (a voice ran but failed), distinct from the resolve-time
# availability fallback (a binary is missing) handled by the route arrays below.
# Args: primary_cli exit_code output_file
# Returns 0 (escalate) iff: primary != droid AND droid installed AND
#   (exit_code != 0 [includes 124 timeout] OR output_file empty/missing).
should_escalate_to_droid() {
  local primary_cli="$1" exit_code="$2" output_file="$3"
  [[ "$primary_cli" == "droid" ]] && return 1
  is_cli_available droid || return 1
  [[ "$exit_code" -ne 0 ]] && return 0
  [[ ! -s "$output_file" ]] && return 0
  return 1
}

# ── Per-role CLI resolution with config + fallback chain ─────
# Usage: resolve_role_cli "council.critic"
# Precedence: env var > project config > user config > defaults > auto-detect
# Returns: CLI name, "builtin", "none", or "missing:<cli>"

_resolve_from_route_array() {
  local config_path="$1" role_key="$2"
  local i=0 cli
  local warned_deprecated_gemini=0
  local warned_deprecated_removed=0
  local last_rejected=""
  local saw_other_entry=0  # any non-rejected, non-resolving entry (missing binary, "auto" fallthrough, etc.)
  while true; do
    cli=$(_read_config_value "$config_path" ".routes[\"$role_key\"][$i]")
    [[ -z "$cli" ]] && break
    if [[ "$cli" == "gemini" ]]; then
      # Skip deprecated entries — config arrays support fallback, so the user's
      # ["gemini", "droid"] route gracefully degrades to droid instead of failing.
      # Warn once per call so a stale config gets visible feedback without spam.
      if [[ "$warned_deprecated_gemini" -eq 0 ]]; then
        echo "busdriver: config route '$role_key' references deprecated 'gemini'; use 'agy' (antigravity) instead — skipping" >&2
        warned_deprecated_gemini=1
      fi
      last_rejected="gemini"
    elif [[ "$cli" == "amp" || "$cli" == "opencode" || "$cli" == "claude" || "$cli" == "aider" ]]; then
      # Removed in the 2026-05-21 dispatch-surface cleanup. Without this skip,
      # a stale ["codex", "amp", "droid"] route would resolve to amp if the
      # binary is still on PATH, then execute_review fails with "Unsupported
      # CLI" because the dispatch case was deleted. Treat as missing so the
      # route walker continues to the next entry.
      if [[ "$warned_deprecated_removed" -eq 0 ]]; then
        echo "busdriver: config route '$role_key' references unsupported '$cli'; use 'codex', 'agy', 'droid', or 'grok' instead — skipping" >&2
        warned_deprecated_removed=1
        last_rejected="$cli"
      fi
    elif [[ "$cli" == "auto" ]]; then
      # grok is INTENTIONALLY excluded from the auto-detect cascade: its
      # safety model (--sandbox readonly + user-config "always approve"
      # disabled) is documented but not enforceable from code, so silently
      # picking grok via auto would extend its exposure surface to contexts
      # whose threat model wasn't reviewed. Grok must be explicitly named
      # (BUSDRIVER_REVIEW_CLI=grok, route array entry, or per-role default).
      for auto_cli in codex agy droid; do
        is_cli_available "$auto_cli" && echo "$auto_cli" && return 0
      done
      saw_other_entry=1  # auto fell through — entry wasn't a removed CLI
    elif [[ "$cli" == "none" || "$cli" == "builtin" ]]; then
      echo "$cli" && return 0
    elif is_cli_available "$cli"; then
      echo "$cli" && return 0
    else
      saw_other_entry=1  # named CLI that just isn't installed (e.g., codex missing)
    fi
    i=$((i + 1))
  done
  # Route exhausted without resolution. Only emit the hard unsupported sentinel
  # if every entry was a rejected (deprecated/removed) CLI — e.g., a pure stale
  # ["amp"] or ["gemini", "opencode"] route. If the route mixed rejected entries
  # with missing-binary ones (e.g., ["amp", "codex"] with codex not installed),
  # fall through to legacy defaults instead — the user clearly wanted something
  # working, and a missing codex shouldn't bake in unsupported:amp as the
  # answer just because amp came first in the array.
  if [[ -n "$last_rejected" && "$saw_other_entry" -eq 0 ]]; then
    echo "unsupported:$last_rejected"
    return 0
  fi
  return 1
}

resolve_role_cli() {
  local role_key="$1"
  local env_cli="${BUSDRIVER_REVIEW_CLI:-}"
  # All function-scoped locals declared ONCE up front. Re-declaring `local`
  # for the same name within a function leaks `name=value` to stdout under
  # zsh (silent under bash). This file is sourced; macOS callers run zsh by
  # default, so any re-declaration corrupts the single-line return contract.
  # Never reintroduce `local` inside the if-blocks or for-loop below.
  local ver default_primary default_fallback project_config user_config
  local _git_root cfg cfg_last_rejected cfg_saw_other

  # Step 1: Env var override (hard-fail if unavailable)
  if [[ -n "$env_cli" && "$env_cli" != "auto" ]]; then
    # Reject deprecated CLI names — this is the hard-cutover migration point
    # (gemini → agy). A stale BUSDRIVER_REVIEW_CLI=gemini from before the
    # migration would otherwise resolve to "gemini" (if the binary is still
    # installed) and crash downstream with a cryptic "Unsupported CLI: gemini".
    # Surfacing it here gives the user a clear migration pointer.
    if [[ "$env_cli" == "gemini" ]]; then
      echo "busdriver: BUSDRIVER_REVIEW_CLI=gemini is deprecated; use 'agy' (antigravity) instead" >&2
      echo "unsupported:gemini"
      return
    fi
    case "$env_cli" in
      amp|opencode|claude|aider)
        echo "busdriver: BUSDRIVER_REVIEW_CLI=$env_cli is no longer supported; use 'codex', 'agy', 'droid', or 'grok' instead" >&2
        echo "unsupported:$env_cli"
        return ;;
    esac
    if [[ "$env_cli" == "none" || "$env_cli" == "builtin" ]]; then
      echo "$env_cli" && return
    fi
    is_cli_available "$env_cli" && echo "$env_cli" && return
    echo "missing:$env_cli" && return
  fi

  # Step 2: Project config routes
  _git_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  project_config="${_git_root:+$_git_root/${BUSDRIVER_STATE_DIR:-.claude}/busdriver.json}"
  [[ -z "$project_config" ]] && project_config=""  # empty _git_root → skip
  if [[ -f "$project_config" ]]; then
    ver=$(_read_config_value "$project_config" '.version')
    if [[ -n "$ver" && "$ver" != "1" ]]; then
      echo "busdriver: ignoring $project_config (version $ver != 1)" >&2
    else
      _resolve_from_route_array "$project_config" "$role_key" && return
    fi
  fi

  # Step 3: User config routes
  user_config="$HOME/${BUSDRIVER_STATE_DIR:-.claude}/busdriver.json"
  if [[ -f "$user_config" ]]; then
    ver=$(_read_config_value "$user_config" '.version')
    if [[ -n "$ver" && "$ver" != "1" ]]; then
      echo "busdriver: ignoring $user_config (version $ver != 1)" >&2
    else
      _resolve_from_route_array "$user_config" "$role_key" && return
    fi
  fi

  # Step 4: Defaults from project config, then user config
  #
  # Per-cfg "all rejected" tracking (mirrors _resolve_from_route_array): when
  # every entry in this cfg's defaults chain is a removed CLI (amp/opencode/
  # claude/aider) and none resolved, emit the unsupported sentinel so the
  # user's stale-but-explicit defaults aren't silently overridden by legacy
  # defaults / auto-detect. Mixed chains (some rejected + some missing-binary)
  # fall through normally — the user clearly intended a working reviewer.
  for cfg in "$project_config" "$user_config"; do
    [[ ! -f "$cfg" ]] && continue
    cfg_last_rejected=""
    cfg_saw_other=0
    default_primary=$(_read_config_value "$cfg" '.defaults.primary')
    if [[ -n "$default_primary" ]]; then
      if [[ "$default_primary" == "auto" ]]; then
        break
      elif [[ "$default_primary" == "gemini" ]]; then
        # Reject deprecated CLI in defaults path — same hard-cutover as Step 1
        echo "busdriver: defaults.primary=gemini is deprecated; use 'agy' (antigravity) instead" >&2
        echo "unsupported:gemini" && return
      elif [[ "$default_primary" == "amp" || "$default_primary" == "opencode" || "$default_primary" == "claude" || "$default_primary" == "aider" ]]; then
        # Removed CLI in defaults.primary — warn and let execution fall through
        # to defaults.fallback below. Track for the all-rejected check.
        echo "busdriver: defaults.primary=$default_primary is no longer supported; use 'codex', 'agy', 'droid', or 'grok' instead — trying defaults.fallback" >&2
        cfg_last_rejected="$default_primary"
      elif [[ "$default_primary" == "none" || "$default_primary" == "builtin" ]]; then
        echo "$default_primary" && return
      elif is_cli_available "$default_primary"; then
        echo "$default_primary" && return
      else
        cfg_saw_other=1  # named CLI not installed — valid intent, just unavailable
      fi
    fi
    # Fallback evaluation runs whether or not defaults.primary was set —
    # a config like {"defaults":{"fallback":"droid"}} (no primary) must
    # still honor the explicit fallback. Pre-fix this block was nested
    # inside `if -n primary`, which silently ignored fallback-only configs.
    default_fallback=$(_read_config_value "$cfg" '.defaults.fallback')
    if [[ "$default_fallback" == "auto" ]]; then
      # Explicit "auto" fallback — run auto-detect inline and return, bypassing
      # Step 4b legacy per-role defaults. "break" would fall into Step 4b first,
      # defeating the user's intent to let auto-detect handle resolution.
      # grok intentionally excluded — see Step 1 (config route "auto") for
      # the rationale: grok's safety model is documented but unenforceable
      # from code, so it must be explicitly named to opt in.
      for cli in codex agy droid; do
        is_cli_available "$cli" && echo "$cli" && return 0
      done
      echo "builtin" && return 0
    fi
    if [[ -n "$default_fallback" ]]; then
      if [[ "$default_fallback" == "gemini" ]]; then
        # Reject deprecated CLI in defaults path — same hard-cutover as Step 1
        echo "busdriver: defaults.fallback=gemini is deprecated; use 'agy' (antigravity) instead" >&2
        echo "unsupported:gemini" && return
      elif [[ "$default_fallback" == "amp" || "$default_fallback" == "opencode" || "$default_fallback" == "claude" || "$default_fallback" == "aider" ]]; then
        # Removed CLI in defaults.fallback — warn and continue.
        echo "busdriver: defaults.fallback=$default_fallback is no longer supported; use 'codex', 'agy', 'droid', or 'grok' instead" >&2
        cfg_last_rejected="$default_fallback"
      elif [[ "$default_fallback" == "none" || "$default_fallback" == "builtin" ]]; then
        echo "$default_fallback" && return
      elif is_cli_available "$default_fallback"; then
        echo "$default_fallback" && return
      else
        cfg_saw_other=1
      fi
    fi
    # All-rejected detection: this cfg's defaults chain contained only
    # removed CLIs and nothing else. Emit unsupported so the user's
    # explicit (if stale) intent isn't silently bypassed.
    if [[ -n "$cfg_last_rejected" && "$cfg_saw_other" -eq 0 ]]; then
      echo "unsupported:$cfg_last_rejected"
      return 0
    fi
  done

  # Step 4b: Legacy per-role defaults (backward compat when no config exists)
  case "$role_key" in
    blueprint-review.reviewer_1) is_cli_available agy && echo "agy" && return ;;
    blueprint-review.reviewer_2) is_cli_available codex && echo "codex" && return ;;
    # reviewer_3 (grok) added 2026-05-26: adds xAI lineage to blueprint-review,
    # mirroring the council Researcher promotion. Walks grok → droid → none
    # to match council.researcher and the existing reviewer_1/_2 droid-fallback
    # pattern (all three reviewer slots fall to droid when their primary is
    # missing). Duplicate-droid risk (e.g., both reviewer_1 and reviewer_3
    # landing on droid when agy and grok are both missing) is handled by the
    # loop's REVIEWER_3_DUPLICATE check, which skips reviewer_3 when it
    # collides with a higher slot.
    blueprint-review.reviewer_3) is_cli_available grok  && echo "grok"  && return
                                 is_cli_available droid && echo "droid" && return
                                 echo "none" && return ;;
    blueprint-review.arbiter)    echo "builtin" && return ;;  # arbiter is always Claude
    # Trade-off: when agy/codex are unavailable, these roles fall back to
    # droid. Droid runs at DROID_AUTO_LEVEL=low when invoked from council's
    # pragmatist/critic templates (file-write tier only, no installs/network/
    # git push). This is wider than "voice skipped" but the user opted into
    # this by adopting the droid-fallback default. Override by configuring
    # `"council.pragmatist": ["agy", "none"]` in .claude/busdriver.json to
    # keep the lens pure and let the voice drop when agy is missing.
    council.pragmatist)         is_cli_available agy   && echo "agy"   && return
                                is_cli_available droid && echo "droid" && return
                                echo "none" && return ;;
    council.critic)             is_cli_available codex && echo "codex" && return
                                is_cli_available droid && echo "droid" && return
                                echo "none" && return ;;
    # Grok was promoted to primary on 2026-05-26: xAI lineage adds the only
    # consistent non-Anthropic/non-OpenAI/non-Gemini voice to council Researcher,
    # and demonstrated Researcher-role competencies (file reads, cited external
    # evidence, self-flagging ungrounded claims) match Droid's. Droid stays as
    # fallback so users without grok installed get identical behavior to
    # pre-2026-05-26. This reverses PR #134's "Researcher stays single-CLI"
    # decision — that PR pruned unused backends (opencode/amp/claude/aider) and
    # Grok hadn't shipped yet.
    council.researcher)         is_cli_available grok  && echo "grok"  && return
                                is_cli_available droid && echo "droid" && return
                                echo "none" && return ;;
  esac

  # Step 5: Auto-detect — grok intentionally excluded. Its safety model
  # (--sandbox readonly + user-config "always approve" disabled) is
  # documented but not enforceable from code, so it must be explicitly
  # named via BUSDRIVER_REVIEW_CLI / route arrays / per-role defaults to
  # opt in. Auto-picking grok would extend its exposure surface to contexts
  # whose threat model wasn't reviewed.
  for cli in codex agy droid; do
    is_cli_available "$cli" && echo "$cli" && return
  done

  # Step 6: Ultimate fallback
  echo "builtin"
}

# ── Review CLI resolution: resolve to ONE cli based on env var ──

resolve_review_cli() {
  resolve_role_cli "litmus.reviewer"
}

# ── Coverage provenance (read-only; does NOT alter resolve_role_cli) ──
# describe_role_resolution <role_key>
# Emits ONE tab-separated line: "<requested>\t<actual>\t<resolution_reason>"
# requested = intended primary (env override, else first non-deprecated route
#   entry, else defaults.primary, else "auto"); actual = resolve_role_cli output.
# reason ∈ ok | resolve-droid-fallback | builtin | missing-cli | unsupported-cli | explicit-none
# Used only by blueprint-review coverage tracking. resolve_role_cli's single-token
# stdout contract is untouched. zsh-safe: all locals declared ONCE up front
# (re-declaring `local` for a name leaks name=value to stdout under zsh).
describe_role_resolution() {
  local role_key="$1"
  local env_cli requested actual reason _git_root project_config user_config cfg i cli
  env_cli="${BUSDRIVER_REVIEW_CLI:-}"
  requested=""

  if [[ -n "$env_cli" && "$env_cli" != "auto" ]]; then
    requested="$env_cli"
  else
    _git_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
    project_config="${_git_root:+$_git_root/${BUSDRIVER_STATE_DIR:-.claude}/busdriver.json}"
    user_config="$HOME/${BUSDRIVER_STATE_DIR:-.claude}/busdriver.json"
    for cfg in "$project_config" "$user_config"; do
      [[ -z "$cfg" || ! -f "$cfg" ]] && continue
      i=0
      while true; do
        cli=$(_read_config_value "$cfg" ".routes[\"$role_key\"][$i]")
        [[ -z "$cli" ]] && break
        case "$cli" in
          gemini|amp|opencode|claude|aider) i=$((i + 1)); continue ;;
        esac
        requested="$cli"; break
      done
      [[ -n "$requested" ]] && break
      cli=$(_read_config_value "$cfg" ".defaults.primary")
      if [[ -n "$cli" ]]; then requested="$cli"; break; fi
    done
    [[ -z "$requested" ]] && requested="auto"
  fi

  actual=$(resolve_role_cli "$role_key")

  case "$actual" in
    none)           reason="explicit-none" ;;
    builtin)        reason="builtin" ;;
    missing:*)      reason="missing-cli" ;;
    unsupported:*)  reason="unsupported-cli" ;;
    droid)
      if [[ "$requested" == "droid" ]]; then reason="ok"; else reason="resolve-droid-fallback"; fi ;;
    *)              reason="ok" ;;
  esac

  printf '%s\t%s\t%s\n' "$requested" "$actual" "$reason"
}

# ── Codex invocation: app-server (preferred) → CLI fallback ────
# The official codex-plugin-cc uses a JSON-RPC app-server protocol that is
# more reliable than piping to `codex exec` (which can hang on stdin).
# We prefer the plugin's companion script when installed; fall back to
# direct CLI invocation otherwise.

_CODEX_COMPANION=""
_resolve_codex_companion() {
  [[ -n "$_CODEX_COMPANION" ]] && return
  # Check common plugin cache locations
  local base="${HOME}/.claude/plugins/cache/openai-codex/codex"
  if [[ -d "$base" ]]; then
    # Find the latest installed version
    local latest
    # sort -t. -k1,1n -k2,2n -k3,3n is portable semver sort (no GNU sort -V needed)
    # shellcheck disable=SC2012 # ls is safe here: version dirs are numeric semver only
    latest=$(ls -1 "$base" 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
    if [[ -n "$latest" && -f "$base/$latest/scripts/codex-companion.mjs" ]]; then
      _CODEX_COMPANION="$base/$latest/scripts/codex-companion.mjs"
      return
    fi
  fi
  _CODEX_COMPANION="none"
}

# ── Shared transient-error predicate ────────────────────────────
# Reads candidate CLI output from stdin; returns 0 (true) if it looks like a
# transient failure worth retrying: connection resets, rate-limits, 5xx,
# EAGAIN I/O races. Single source of truth for _execute_codex's retry loop,
# the agy/grok retry wrapper below, and dispatch.sh's dispatch_one (council).
# Match only the `EAGAIN` token (not the phrase "resource temporarily
# unavailable") to avoid false-positives on fork/thread exhaustion that shares
# the same strerror text. The 5xx match is context-qualified (an HTTP/status
# word within a few non-digit chars, or a 5xx reason phrase) so incidental
# 3-digit runs — "line 503", "port 5000", "1500 tokens" — are NOT misread as
# transient server errors and needlessly retried + droid-escalated.
# Keep this regex in sync with the fallback copy in dispatch.sh.
_is_transient_cli_error() {
  grep -qiE 'ECONNREFUSED|ECONNRESET|ETIMEDOUT|EPIPE|EAGAIN|socket hang up|fetch failed|rate.limit|overloaded|capacity|too many requests|(http|status|code|response)[^0-9]{0,6}(429|5[0-9][0-9])|internal server error|bad gateway|service unavailable|gateway time-?out|getaddrinfo'
}

# Strict transient signal — only unambiguous network/protocol/5xx error TOKENS
# that never occur in human review prose. This is DELIBERATELY narrower than
# _is_transient_cli_error: it drops the ambiguous words "rate.limit", "overloaded",
# and "capacity", which legitimately appear in review text ("capacity handling
# looks correct"). For the same reason the HTTP reason phrases (bad gateway,
# service unavailable, gateway timeout, internal server error, too many requests)
# match ONLY when adjacent to their numeric status code, in either word order
# ("502 Bad Gateway" or "Bad Gateway (502)") — a bare phrase in clean exit-0
# prose ("bad gateway handling looks correct") is a
# review, not a transient notice, and must not be retried/replaced away. Real
# wrapper notices carry the code; prose does not. Used ONLY to judge whether
# *clean-exit* output is a bare error notice; the broad predicate stays for
# non-zero-exit output, which is genuine error text rather than a possible review.
_is_hard_transient_signal() {
  grep -qiE 'ECONNREFUSED|ECONNRESET|ETIMEDOUT|EPIPE|EAGAIN|socket hang up|fetch failed|getaddrinfo|(http|status|code|response)[^0-9]{0,6}(429|5[0-9][0-9])|(429|5[0-9][0-9])[^0-9a-z]{0,4}(too many requests|bad gateway|service unavailable|gateway time-?out|internal server error)|(too many requests|bad gateway|service unavailable|gateway time-?out|internal server error)[^0-9a-z]{0,4}(429|5[0-9][0-9])'
}

# Max size (chars) of a "bare error notice" — output from a CLI that exits 0
# while printing only a short transient-error message (some wrappers emit a
# network/5xx notice and still exit 0) instead of a real review. A genuine
# review is a substantial JSON/structured payload; this bound plus the JSON-brace
# check below separate the two so a review that merely *discusses* rate limits /
# 5xx (this repo's own reviews do) is never misread as a transient failure.
CLI_BARE_ERROR_MAX_CHARS="${CLI_BARE_ERROR_MAX_CHARS:-512}"

# True (0) when exit-0 output is a bare transient-error notice masquerading as a
# successful review: it is short AND carries a HARD transient signal (a machine
# error token — ECONNRESET, "fetch failed", a context-qualified 5xx, etc. — not a
# mere prose word). A genuine litmus review payload carries the review schema
# (top-level "status" + "issues") and is exempted up front: such a review may
# legitimately *discuss* a 5xx / network condition in a finding (e.g. an "HTTP
# 500 handler lacks tests" description) without being a transient notice. A bare
# error *envelope* like {"error":"ECONNRESET ..."} lacks that schema, so braces
# alone do not exempt it — it still retries. Reviews also typically exceed the
# size bound, a second backstop against misreading them as transient failures.
# True (0) when output reads like a code review *discussing* an error term rather
# than *being* a bare error notice. Freeform council prose (Pragmatist/Critic/
# Researcher) has no "status"/"issues" envelope to key off, so a terse but valid
# reply that names an HTTP/5xx code ("the HTTP 500 handler lacks tests", "503 retry
# path looks correct") would otherwise trip _is_hard_transient_signal and be retried
# away. Every term below is review-assessment vocabulary that does NOT appear in a
# genuine network/5xx error notice ("502 Bad Gateway", "ECONNRESET: socket hang up",
# "fetch failed"), so this guard cannot reclassify a true notice as a review — it
# only rescues prose that the bare-notice heuristic would misfire on.
_reads_as_review_prose() {
  grep -qiE '\b(lacks?|looks (correct|good|fine|right|ok)|need(s|ed)? (a|an|to|more|tests?)|should (add|be|use|have|handle|return|check|verify|guard|consider)|consider|recommend|suggest|missing (a|an|tests?|guards?|checks?|coverage|handling)|edge case|refactor|rename|nit|LGTM|no issues|test coverage|docstring|assertion)\b'
}

_is_bare_transient_notice() {
  local out="$1"
  [[ "${#out}" -le "$CLI_BARE_ERROR_MAX_CHARS" ]] || return 1
  # Review schema present → it's a verdict, not a notice. Never bare.
  if printf '%s' "$out" | grep -qiE '"status"[[:space:]]*:' \
     && printf '%s' "$out" | grep -qiE '"issues"[[:space:]]*:'; then
    return 1
  fi
  # Reads like a review discussing an error term → a verdict, not a notice. Closes
  # the gap the schema exemption leaves open for *freeform* (non-schema) prose.
  if printf '%s' "$out" | _reads_as_review_prose; then
    return 1
  fi
  printf '%s' "$out" | _is_hard_transient_signal
}

# ── Retry wrapper for non-codex review CLIs (agy / grok) ────────
# Codex has its own richer retry loop in _execute_codex. agy and grok were
# single-shot until now, so one transient hiccup dropped the voice straight to
# droid. This retries up to BUSDRIVER_CLI_RETRIES (default 3; blueprint-review
# exports 5) on a transient failure or an empty-but-clean exit, with short
# exponential backoff. It NEVER retries a timeout (124) — re-running the full
# window is too costly; the caller's droid fallback catches that. Echoes the
# final output to stdout and returns the final exit code.
# Args: <label> <prompt> <duration> <cmd...>  (cmd reads the prompt from stdin)
_run_review_with_retries() {
  local label="$1" prompt="$2" duration="$3"; shift 3
  local max_retries="${BUSDRIVER_CLI_RETRIES:-3}"
  local retry_delay="${BUSDRIVER_CLI_RETRY_DELAY:-5}"
  case "$max_retries" in ''|*[!0-9]*) max_retries=3 ;; esac
  case "$retry_delay" in ''|*[!0-9]*) retry_delay=5 ;; esac
  # The WHOLE retry sequence — every attempt PLUS all backoff sleeps — is bounded
  # to ~"$duration" (the caller's total budget): each attempt's timeout is the
  # REMAINING budget (equals "$duration" on the first attempt), and each backoff
  # is capped to the remaining budget so the sleep itself can't overrun. Retries
  # therefore never multiply the wall-clock to (retries+1)× the timeout; once the
  # budget is spent we stop and let the caller's droid fallback take over.
  local attempt=0 exit_code=0 output="" start now remaining cap
  start=$(date +%s)
  while [[ "$attempt" -le "$max_retries" ]]; do
    exit_code=0
    if [[ "$attempt" -eq 0 ]]; then
      # The FIRST attempt always runs with the full budget — set it directly (not
      # via now-start) so a sub-second clock tick can never zero it out and skip
      # the only invocation. Only RETRIES are budget-gated below.
      remaining="$duration"
    else
      now=$(date +%s); remaining=$(( duration - (now - start) ))
      # A retry needs budget for the backoff PLUS at least a 1s attempt; if the
      # remaining budget can't fund a 1s attempt, escalate now instead of
      # sleeping the rest of the budget away for a retry that can't run.
      if [[ "$remaining" -le 1 ]]; then
        echo "⟳ ${label}: retry budget (${duration}s) spent — escalating instead of retrying" >&2
        # Budget exhaustion is a CLI FAILURE, not a real timeout — use a generic
        # non-zero (1), never 124, so callers don't trip their timeout/split path.
        [[ "$exit_code" -eq 0 ]] && exit_code=1
        break
      fi
      # Cap backoff to leave >= 1s for the attempt — never sleep the whole budget.
      cap=$(( remaining - 1 ))
      [[ "$retry_delay" -gt "$cap" ]] && retry_delay="$cap"
      if [[ "$retry_delay" -gt 0 ]]; then
        echo "⟳ ${label} retry ${attempt}/${max_retries} (waiting ${retry_delay}s)..." >&2
        sleep "$retry_delay"
      fi
      retry_delay=$((retry_delay * 2))
      now=$(date +%s); remaining=$(( duration - (now - start) ))
      if [[ "$remaining" -le 0 ]]; then
        echo "⟳ ${label}: retry budget (${duration}s) spent — escalating instead of retrying" >&2
        # Budget exhaustion is a CLI FAILURE, not a real timeout — use a generic
        # non-zero (1), never 124, so callers don't trip their timeout/split path.
        [[ "$exit_code" -eq 0 ]] && exit_code=1
        break
      fi
    fi
    output=$(printf '%s' "$prompt" | _portable_timeout "$remaining" "$@" 2>&1) || exit_code=$?
    # Timeout → don't retry; let the caller's droid fallback handle it.
    [[ "$exit_code" -eq 124 ]] && break
    # A clean exit with non-empty output is success — UNLESS it is a bare
    # transient notice the CLI emitted while still exiting 0 (a rate-limit/5xx
    # message in place of a review). Those fall through to the retry/droid path
    # below; a real review payload — even one discussing rate limits / 5xx — is
    # accepted here because it carries a JSON object and/or is substantial.
    if [[ "$exit_code" -eq 0 && -n "$output" ]] && ! _is_bare_transient_notice "$output"; then
      break
    fi
    # Retry if the attempt produced NO output (a CLI that died before writing a
    # review — empty is never a valid review, whatever the exit code) OR the
    # failure text looks transient. Otherwise bail (non-transient hard failure
    # that did produce output → the caller's droid fallback owns the rescue).
    if [[ -z "$output" ]] || printf '%s' "$output" | _is_transient_cli_error; then
      attempt=$((attempt + 1))
      continue
    fi
    break
  done
  # Exhausted retries while still empty OR while still emitting a bare transient
  # notice on a clean exit → report a FAILURE, not a silent success: neither an
  # empty review nor a rate-limit/5xx notice is a passing review, and callers key
  # fallback/error handling off this exit status (e.g. execute_review → blueprint
  # droid rescue / litmus error path). Without this, an always-empty or
  # always-rate-limited reviewer would return exit 0 and be treated as a clean run.
  if [[ "$exit_code" -eq 0 ]] && { [[ -z "$output" ]] || _is_bare_transient_notice "$output"; }; then
    exit_code=1
  fi
  printf '%s' "$output"
  return "$exit_code"
}

_execute_codex() {
  local prompt="$1"
  local duration="${2:-1200}"
  # Defaults sized for codex rate-limit windows. At the default 3 retries the
  # backoff sequence is 30, 60, 120 seconds — ~3.5 min total wait before
  # exhausting and escalating to droid. From retry 2 onward (t≥90s) the
  # sequence clears OpenAI's per-minute (60s) window. The MOST IMPORTANT review
  # paths raise this to 5: blueprint-review and litmus PR mode both export
  # LITMUS_CODEX_RETRIES=5 (backoff 30,60,120,240,480 ≈ 15.5 min, also clearing
  # the per-5min window) because those reviews are the gate of record and have
  # no/limited droid net. Sustained outages still fall through to droid as the
  # external-voice safety net. Override via env vars for faster bail or longer
  # patience.
  local max_retries="${LITMUS_CODEX_RETRIES:-3}"
  local retry_delay="${LITMUS_CODEX_RETRY_DELAY:-30}"
  local high_from="${LITMUS_CODEX_HIGH_FROM:-3}"  # switch to high reasoning from this attempt

  # Validate env vars are non-negative integers
  local _v
  for _v in "$max_retries" "$retry_delay" "$high_from"; do
    case "$_v" in
      ''|*[!0-9]*)
        echo "busdriver: LITMUS_CODEX_RETRIES, LITMUS_CODEX_RETRY_DELAY, and LITMUS_CODEX_HIGH_FROM must be non-negative integers" >&2
        return 1
        ;;
    esac
  done

  _resolve_codex_companion

  # Pre-buffer the prompt to a file so the companion path can read via
  # --prompt-file instead of fd 0. The companion's stdin reader
  # (lib/fs.mjs readStdinIfPiped → fs.readFileSync(0, ...)) throws
  # "EAGAIN: resource temporarily unavailable, read" when fd 0 has
  # O_NONBLOCK set — a stable condition under Claude Code's Bash tool that
  # retry+backoff cannot clear (the fd flag does not change between
  # attempts). --prompt-file reads via fs.readFileSync(absolutePath) and
  # is unaffected. The direct codex CLI fallback further down still uses
  # stdin; that path only fires when the companion plugin is uninstalled,
  # and codex exec lacks an equivalent file-input flag at present.
  local _prompt_file=""
  if [[ "$_CODEX_COMPANION" != "none" ]] && command -v node &>/dev/null; then
    _prompt_file=$(mktemp -t codex-prompt 2>/dev/null) || _prompt_file=$(mktemp 2>/dev/null) || _prompt_file=""
    if [[ -z "$_prompt_file" || ! -f "$_prompt_file" ]]; then
      echo "busdriver: failed to create temp file for codex prompt" >&2
      return 1
    fi
    if ! printf '%s' "$prompt" > "$_prompt_file"; then
      rm -f "$_prompt_file"
      echo "busdriver: failed to write codex prompt to temp file" >&2
      return 1
    fi
  fi

  local attempt=0
  local exit_code=0
  local output=""
  local last_was_transient=0  # narrows droid fallback to rate-limit/network exhaustion
  local timed_out=0           # a single full-duration timeout is droid-eligible (not retried)

  while [[ "$attempt" -le "$max_retries" ]]; do
    exit_code=0
    # Reflect only THIS attempt's classification — never carry a prior attempt's
    # transience into the post-loop droid decision. A timeout escalates via its
    # own `timed_out` flag, so resetting here does not weaken timeout handling.
    last_was_transient=0
    local effort_args=()
    if [[ "$attempt" -gt 0 ]]; then
      # No --effort flag = codex config default (xhigh in config.toml)
      local effort_label="xhigh"
      if [[ "$attempt" -ge "$high_from" ]]; then
        effort_args=(--effort high)
        effort_label="high"
      fi
      echo "⟳ Codex retry $attempt/$max_retries (reasoning: $effort_label, waiting ${retry_delay}s)..." >&2
      sleep "$retry_delay"
      # Exponential backoff: double delay each retry
      retry_delay=$((retry_delay * 2))
    fi

    if [[ "$_CODEX_COMPANION" != "none" ]] && command -v node &>/dev/null; then
      # Use official plugin's app-server protocol via --prompt-file — see the
      # pre-loop comment for the EAGAIN background. Omit --json to get raw
      # review output (--json wraps in an envelope that breaks downstream
      # extract_review_json.py parsing).
      # ${effort_args[@]+...} guards against "unbound variable" when array is
      # empty under set -u (macOS bash 3.2).
      output=$(_portable_timeout "$duration" node "$_CODEX_COMPANION" task --prompt-file "$_prompt_file" ${effort_args[@]+"${effort_args[@]}"} 2>&1) || exit_code=$?
    else
      # Fallback: direct CLI invocation
      local config_args=()
      if [[ ${#effort_args[@]} -gt 0 ]]; then
        config_args=(-c 'model_reasoning_effort="high"')
      fi
      output=$(printf '%s' "$prompt" | _portable_timeout "$duration" codex exec -s read-only ${config_args[@]+"${config_args[@]}"} - 2>&1) || exit_code=$?
    fi

    # Success — a clean exit WITH a real review payload. An exit-0 that is empty
    # or only a bare transient notice (a network/5xx envelope the companion
    # emitted while still exiting 0) is NOT a review; fall through to the
    # retry/droid path, mirroring _run_review_with_retries and dispatch_one.
    if [[ "$exit_code" -eq 0 && -n "$output" ]] && ! _is_bare_transient_notice "$output"; then
      break
    fi

    # Timeout (124) — retrying burns the whole window again, so don't; but a
    # timeout IS droid-eligible (a different backend may still answer in time).
    if [[ "$exit_code" -eq 124 ]]; then
      timed_out=1
      break
    fi

    # Only retry on transient Codex service errors (network, API, rate-limit)
    # AND on non-blocking I/O races (EAGAIN). Script bugs (unbound variable,
    # syntax error, command not found) should not be retried.
    #
    # EAGAIN history: the primary historical trigger was the codex-companion
    # reading stdin via fs.readFileSync(0) under Claude Code's Bash tool,
    # where fd 0 has O_NONBLOCK set. That path is now bypassed by writing the
    # prompt to a temp file and passing --prompt-file (see pre-loop block).
    # EAGAIN remains in the retry regex as defense-in-depth in case a future
    # codex version or codepath regresses. We match only the `EAGAIN` token
    # (not the phrase "resource temporarily unavailable") to avoid false-
    # positives on unrelated fork/thread exhaustion errors that share the
    # same strerror text.
    # Retry on transient service errors, OR on a clean exit that produced no real
    # review (empty, or a bare transient notice) — a flake, not a verdict.
    if { [[ "$exit_code" -eq 0 ]] && { [[ -z "$output" ]] || _is_bare_transient_notice "$output"; }; } \
       || printf '%s' "$output" | _is_transient_cli_error; then
      last_was_transient=1
      attempt=$((attempt + 1))
    else
      last_was_transient=0
      echo "⚠️  Codex failed with non-transient error (exit $exit_code) — not retrying" >&2
      break
    fi
  done

  # A clean exit that never yielded a real review (empty, or a bare transient
  # notice, through exhaustion) is not success — promote it to a transient
  # failure so the droid/builtin fallback below engages instead of returning a
  # blank PASS. Mirrors _run_review_with_retries' exhaustion guard.
  if [[ "$exit_code" -eq 0 ]] && { [[ -z "$output" ]] || _is_bare_transient_notice "$output"; }; then
    exit_code=1
    last_was_transient=1
  fi

  # All retries exhausted, non-transient error, or a timeout — try droid (if
  # eligible), else fall back to builtin (or preserve the timeout signal).
  if [[ "$exit_code" -ne 0 ]]; then
    local attempts_run=$(( attempt > max_retries ? max_retries + 1 : attempt + 1 ))
    # Surface codex's captured stderr/stdout so callers writing 2>&1 to a raw
    # log can diagnose the failure. Without this, only the wrapper's own
    # messages survive and the underlying cause is unrecoverable.
    if [[ -n "$output" ]]; then
      printf '%s\n%s\n%s\n' \
        "----- codex output (exit $exit_code) -----" \
        "$output" \
        "----- end codex output -----" >&2
    fi

    # Droid escalation: on transient-error exhaustion (rate-limit, network, 5xx)
    # OR a single full-duration timeout (a different backend may still answer).
    # Non-transient codex failures (script bugs, malformed prompt) would likely
    # break droid too — go straight to builtin in that case.
    #
    # Three opt-outs honored:
    #   1. LITMUS_CODEX_DROID_FALLBACK_DISABLED=1 — matches opt-out convention
    #      (LITMUS_SHORTCIRCUIT_DISABLED, LITMUS_SKIP_*).
    #   2. LITMUS_CODEX_DROID_FALLBACK=0 — earlier name used in pre-merge drafts
    #      of this feature, kept as an alias to avoid silently re-enabling droid
    #      for anyone who adopted that env var.
    #   3. BUSDRIVER_REVIEW_CLI=codex — explicit codex pin. Treat as "user wants
    #      only codex, fall through to builtin if codex fails" — matches the
    #      semantics implied by pinning a single backend.
    local _droid_disabled="${LITMUS_CODEX_DROID_FALLBACK_DISABLED:-0}"
    # Widen to accept common truthy shell boolean conventions (1/true/yes/on).
    if [[ "$_droid_disabled" =~ ^(1|true|yes|on)$ ]]; then _droid_disabled=1; fi
    [[ "${LITMUS_CODEX_DROID_FALLBACK:-1}" =~ ^(0|false|no|off)$ ]] && _droid_disabled=1
    [[ "${BUSDRIVER_REVIEW_CLI:-auto}" == "codex" ]] && _droid_disabled=1
    if { [[ "$last_was_transient" -eq 1 ]] || [[ "$timed_out" -eq 1 ]]; } && \
       [[ "$_droid_disabled" != "1" ]] && \
       is_cli_available droid; then
      local _fail_reason="transient errors"
      [[ "$timed_out" -eq 1 ]] && _fail_reason="timeout"
      echo "⚠️  Codex failed after ${attempts_run} attempt(s) (${_fail_reason}) — escalating to droid" >&2
      local droid_out='' droid_exit=0
      # Bare `droid exec` (default read-only mode, Create/Edit blocked) matches
      # execute_review's posture and the codex `-s read-only` posture this is
      # escalating from. See execute_review droid case for PR #97 historical context.
      droid_out=$(printf '%s' "$prompt" | _portable_timeout "$duration" droid exec 2>&1) || droid_exit=$?

      # Require both clean exit AND non-empty output — droid killed by signal
      # can exit 0 with empty stdout, which would surface as a successful but
      # blank review verdict downstream.
      local _droid_ok=0
      [[ "$droid_exit" -eq 0 ]] && [[ -n "$droid_out" ]] && _droid_ok=1

      # Telemetry: log every escalation regardless of outcome, with droid_ok
      # reflecting the actual success/failure determination. Resolve .claude
      # against the git root, not cwd — hooks fire from whatever subdir the
      # user ran `git commit` in, so a cwd-relative check would silently drop
      # events for any non-root invocation.
      local _git_root=""
      _git_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
      if [[ -n "$_git_root" && -d "$_git_root/${BUSDRIVER_STATE_DIR:-.claude}" ]]; then
        printf '{"ts":"%s","event":"codex-droid-fallback","codex_exit":%d,"droid_exit":%d,"droid_ok":%d,"codex_attempts":%d}\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$exit_code" "$droid_exit" "$_droid_ok" "$attempts_run" \
          >> "$_git_root/${BUSDRIVER_STATE_DIR:-.claude}/bypass-log.jsonl" 2>/dev/null || true
      fi

      if [[ "$_droid_ok" -eq 1 ]]; then
        [[ -n "$_prompt_file" ]] && rm -f "$_prompt_file"
        printf '%s' "$droid_out"
        return 0
      fi
      echo "⚠️  Droid escalation failed (exit $droid_exit, output_bytes=${#droid_out}) — falling back to built-in review" >&2
    fi

    [[ -n "$_prompt_file" ]] && rm -f "$_prompt_file"
    # Timeout with no droid rescue (droid disabled/unavailable, e.g. litmus PR
    # mode or blueprint's one-voice cap) — preserve the timeout signal (exit
    # 124) so the caller can react (litmus: split into smaller commits). Do NOT
    # emit BUILTIN_FALLBACK for a timeout.
    if [[ "$timed_out" -eq 1 ]]; then
      printf '%s' "$output"
      return 124
    fi
    echo "⚠️  Codex failed after ${attempts_run} attempt(s) — falling back to built-in review" >&2
    echo "BUILTIN_FALLBACK"
    return 3
  fi

  [[ -n "$_prompt_file" ]] && rm -f "$_prompt_file"
  printf '%s' "$output"
  return "$exit_code"
}

# ── SECURITY TRADE-OFF: agy prompt travels in argv (accepted residual) ────────
# Delivering the prompt as `--print "$prompt"` puts the ENTIRE review prompt —
# repo content, the full diff, and anything embedded in it — into the process
# argument list. The old `--print /dev/stdin` form did not: fd 0 is not visible
# to `ps`, /proc/<pid>/cmdline, or command-line auditing.
#
# This is a REAL regression in exposure, accepted because there is no alternative
# that works: agy 1.1.4 has no file-input flag, bare `--print` errors with "flag
# needs an argument", and the stdin form is simply broken (it sends the literal
# string "/dev/stdin"). The choice is argv delivery or no agy reviewer at all.
#
# Exposure bounds: on Linux /proc/<pid>/cmdline is world-readable by default
# (mitigate with hidepid, or don't run reviews on a shared host); on macOS other
# users' full argv requires root. The content is the repo's own working tree,
# already readable by the same user — the marginal leak is to OTHER local users
# for the lifetime of the process.
#
# Revisit if: agy gains a file/stdin input flag, or these reviews ever run on a
# multi-tenant host. Do not "fix" by moving the prompt to an env var without
# checking agy supports it — /proc/<pid>/environ has its own exposure profile.
#
# ── agy argv size ceiling (shared by execute_review and dispatch.sh) ──────────
# agy 1.1.x takes the prompt as `--print`'s argv VALUE, so it is subject to the
# kernel's exec limits. TWO independent ceilings apply and they differ by OS:
#   - ARG_MAX          total argv+envp; getconf reports it (macOS 1 MB, Linux ~2 MB)
#   - MAX_ARG_STRLEN   per-ARGUMENT, LINUX ONLY, 32 pages - 1 = 131071 B. Not
#                      reported by getconf, not derived from ARG_MAX, and NOT
#                      present on macOS/BSD — where a single 500 KB argv element
#                      is fine as long as the ARG_MAX total holds.
# Applying the Linux figure unconditionally would reject prompts that macOS
# delivers happily, so it is gated on uname. Review prompts run ~40-100 KB, so on
# Linux the headroom is modest (~30% at the top end) — this is a live constraint,
# not a theoretical one.
_agy_argv_limit() {
    local total linux_strmax=131071
    total=$(( $(getconf ARG_MAX 2>/dev/null || echo 1048576) / 2 ))
    if [[ "$(uname -s 2>/dev/null)" == "Linux" ]] && [[ "$linux_strmax" -lt "$total" ]]; then
        printf '%s\n' "$linux_strmax"
    else
        printf '%s\n' "$total"
    fi
}

# BYTE length of $1 — NOT ${#var}, which counts CHARACTERS under a multibyte
# locale (LANG=*.UTF-8). MAX_ARG_STRLEN and ARG_MAX are byte limits, so a prompt
# of non-ASCII text (CJK review comments, em-dashes, box-drawing in a diff) can
# report far fewer characters than bytes and slip past a ${#var} guard straight
# into the E2BIG this check exists to prevent. LC_ALL=C forces byte semantics.
_agy_bytelen() {
    local LC_ALL=C
    printf '%s' "${1-}" | wc -c | tr -d '[:space:]'
}

# Does this agy read `--print`'s value as PROMPT TEXT (>=1.1) or as a PATH (1.0.x)?
# 1.0.x resolved the value as a file, which is why `--print /dev/stdin` worked
# there; 1.1.x sends it verbatim. Delivering argv unconditionally would break a
# 1.0.x install (it would treat the whole prompt as a filename), so probe once.
# Unknown/unparseable version => assume modern: every current release is >=1.1,
# and guessing "old" would reintroduce the /dev/stdin bug on a working install.
_agy_wants_argv_prompt() {
    local v maj min
    v=$(agy --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
    [[ -z "$v" ]] && return 0
    maj="${v%%.*}"; min="${v#*.}"
    [[ "$maj" -gt 1 ]] && return 0
    [[ "$maj" -eq 1 && "$min" -ge 1 ]]
}

# Returns 0 (true) when $1 bytes exceeds the agy argv ceiling. Callers fail loudly;
# the alternative is a raw E2BIG at exec, which surfaces as an empty/garbled reply
# and degrades to "Output was not valid JSON" — the silent failure this whole
# change exists to remove.
_agy_prompt_oversize() {
    local size="${1:-0}" limit
    limit=$(_agy_argv_limit)
    [[ "$size" -gt "$limit" ]]
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
  # Codex uses the app-server protocol via _execute_codex() when the official
  # plugin is installed, falling back to direct CLI. Other CLIs use stdin piping.
  case "$cli" in
    codex)   _execute_codex "$prompt" "$duration" ;;
    # agy takes the prompt as `--print`'s ARGV VALUE. The former
    # (see _agy_argv_limit / _agy_prompt_oversize above for the size ceiling)
    # `--print /dev/stdin` idiom read fd 0 on agy v1.0.0, but 1.1.x treats the
    # value as literal prompt text: agy answers "It looks like you just sent
    # `/dev/stdin`" — prose, never JSON — so the reviewer slot failed as "Output
    # was not valid JSON", fell back to droid, and silently degraded blueprint
    # coverage below FULL (which withholds the PASS marker entirely). 1.1.4 has no
    # file-input flag and bare `--print` errors with "flag needs an argument", so
    # argv is the only delivery path. SIZE CEILING: the binding limit is NOT the
    # ~1 MB ARG_MAX the old comment cited but Linux's per-argument MAX_ARG_STRLEN
    # (32 pages - 1 = 131071 B), which getconf does not report and which applies to
    # the prompt as a single argv element. Review prompts run ~40-100 KB, so the
    # headroom is real but modest — roughly 30% at the top end, not the 10x the old
    # comment implied. Exceeding it fails loudly (E2BIG at exec) rather than
    # silently truncating; if blueprint prompts grow past ~120 KB, this needs a
    # pre-flight guard like the one in dispatch.sh's agy case.
    # --sandbox restricts terminal capabilities (matching dispatch.sh's readonly
    # mode): review prompts emit JSON verdicts and never mutate the repo or fetch.
    # Align --print-timeout with our outer duration so agy's internal 5m default
    # doesn't abort before _portable_timeout does.
    agy)     if _agy_wants_argv_prompt; then
               _agy_psize=$(_agy_bytelen "$prompt")
               if _agy_prompt_oversize "$_agy_psize"; then
                 echo "agy: review prompt is ${_agy_psize}B, over the argv ceiling ($(_agy_argv_limit)B) — agy >=1.1 has no file-input flag. Split the diff or route this review to codex." >&2
                 return 1
               fi
               _run_review_with_retries agy "$prompt" "$duration" \
                 agy --sandbox --print-timeout "${duration}s" --print "$prompt"
             else
               # agy 1.0.x resolves --print's value as a PATH, so fd 0 works and
               # the argv size ceiling and exposure do not apply on this rung.
               _run_review_with_retries agy "$prompt" "$duration" \
                 agy --sandbox --print-timeout "${duration}s" --print /dev/stdin
             fi ;;
    # Review path: bare `droid exec` (default read-only mode) is the tightest
    # posture that works for stdin-piped review. Create/Edit are blocked at this
    # tier (verified via `droid exec --list-tools` on v0.131.0+); reviews emit
    # JSON verdicts and never need to mutate the repo.
    # NOTE: PR #97 (May 2026) used `--auto low` because earlier droid versions
    # failed on first read under stdin pipe ("Exec ended early: insufficient
    # permission"). Empirically verified fixed on v0.131.0. If a future droid
    # release regresses this, restore `--auto low` (accepts file-write tier as
    # the cost of stdin-pipe working).
    droid)   printf '%s' "$prompt" | _portable_timeout "$duration" droid exec 2>&1 ;;
    # Grok (xAI Grok Build) added 2026-05-26 for blueprint-review reviewer_3.
    #
    # SAFETY MODEL (must match dispatch.sh's grok case — single source of truth
    # for the threat model lives there; this is the mirrored summary):
    #   * --sandbox readonly blocks project-root writes (verified empirically).
    #     Does NOT block shell exec, /tmp writes, or network.
    #   * End-to-end safety requires "always approve" DISABLED in the grok
    #     user-config (per-machine setting via `grok` `/permissions`).
    #     With that, writes/shell denied in headless; without it, grok auto-
    #     approves arbitrary tool use including the bash tool.
    #   * Threat surface here: blueprint-review feeds design-document content
    #     into this path. A prompt-injected design doc on a host where grok
    #     user-config is permissive could get shell/write actions auto-
    #     approved. This is the same residual risk class as dispatch.sh's
    #     grok path and is documented in skills/dispatch-cli/scripts/dispatch.sh.
    #   * No --always-approve / --disallowed-tools / --deny flags passed:
    #     empirically they are no-ops in headless mode (false safety).
    #
    # The stderr warning below is captured by run-design-review-loop.sh into
    # the per-reviewer raw file (e.g. grok-raw.txt). It will not surface to
    # the operator in real time the way dispatch.sh's stderr does, but it
    # remains in the audit trail.
    #
    # --max-turns 150: grok counts every internal message; review prompts
    # often consume 50-100 turns; 150 is the safety margin (max_turns_exceeded
    # is destructive — whole output discarded — so err generous, not tight).
    # --prompt-file /dev/stdin: bypasses argv length limits (mirrors agy's
    # --print pattern).
    grok)    echo "Note: grok blueprint-review dispatch — safety relies on user-config 'always approve' being DISABLED. See scripts/lib/resolve-cli.sh and skills/dispatch-cli/scripts/dispatch.sh grok-case comments for the full threat model." >&2
             _run_review_with_retries grok "$prompt" "$duration" \
               grok --prompt-file /dev/stdin --max-turns 150 --sandbox readonly ;;
    builtin) echo "BUILTIN_FALLBACK"; return 3 ;;
    unsupported:*)
             # CLI was rejected upstream (deprecated/removed). Migration warning
             # was already emitted to stderr by resolve_role_cli; surface the
             # cause cleanly here instead of falling through to the wildcard
             # "Unsupported CLI: unsupported:amp" garbage.
             local _removed="${cli#unsupported:}"
             echo "busdriver: review CLI '$_removed' is no longer supported; use codex, agy, droid, or grok" >&2
             return 1 ;;
    missing:*)
             # CLI is configured but not installed. Same surface-clean intent as
             # unsupported:* above — let the caller see a recognizable failure
             # mode rather than a garbled wildcard match.
             local _absent="${cli#missing:}"
             echo "busdriver: review CLI '$_absent' is configured but not installed" >&2
             return 1 ;;
    *)       echo "Unsupported CLI: $cli" >&2; return 1 ;;
  esac
}

# ── Machine-readable interface (--json) ─────────────────────────
# Guard: only runs when executed directly, not when sourced
if [[ "${BASH_SOURCE[0]}" = "$0" ]] && [[ "${1:-}" = "--json" ]]; then
  configured="${BUSDRIVER_REVIEW_CLI:-auto}"
  resolved=$(resolve_review_cli)
  version=""
  case "$resolved" in
    codex|agy|droid|grok) version=$(get_cli_version "$resolved") ;;
    builtin|none|missing:*|unsupported:*) version="n/a" ;;
  esac

  # Sanitize strings for JSON (strip quotes, backslashes, newlines)
  _json_safe() { tr -d '"\\\n' | head -1; }

  configured=$(echo "$configured" | _json_safe)
  resolved=$(echo "$resolved" | _json_safe)
  version=$(echo "$version" | _json_safe)

  # Report availability for all supported CLIs
  clis_json=""
  # grok included here for accurate availability metadata (not auto-detect);
  # downstream consumers inspecting `clis[resolved]` get an entry when the
  # resolved CLI is grok (e.g., via explicit BUSDRIVER_REVIEW_CLI=grok or
  # blueprint-review.reviewer_3 route).
  for cli in codex agy droid grok; do
    avail=$(is_cli_available "$cli" && echo true || echo false)
    ver=$(get_cli_version "$cli" | _json_safe)
    clis_json="${clis_json}\"${cli}\":{\"available\":${avail},\"version\":\"${ver}\"},"
  done
  clis_json="{${clis_json%,}}"

  printf '{"configured":"%s","resolved":"%s","version":"%s","clis":%s}\n' \
    "$configured" "$resolved" "$version" "$clis_json"
  exit 0
fi
