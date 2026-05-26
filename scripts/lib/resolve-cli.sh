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
# Values: auto (default) | codex | agy | droid | builtin | none

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
        echo "busdriver: config route '$role_key' references unsupported '$cli'; use 'codex', 'agy', or 'droid' instead — skipping" >&2
        warned_deprecated_removed=1
        last_rejected="$cli"
      fi
    elif [[ "$cli" == "auto" ]]; then
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
        echo "busdriver: BUSDRIVER_REVIEW_CLI=$env_cli is no longer supported; use 'codex', 'agy', or 'droid' instead" >&2
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
  project_config="${_git_root:+$_git_root/.claude/busdriver.json}"
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
  user_config="$HOME/.claude/busdriver.json"
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
        echo "busdriver: defaults.primary=$default_primary is no longer supported; use 'codex', 'agy', or 'droid' instead — trying defaults.fallback" >&2
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
        echo "busdriver: defaults.fallback=$default_fallback is no longer supported; use 'codex', 'agy', or 'droid' instead" >&2
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
    # mirroring the council Researcher promotion. Falls back to "none" (voice
    # skipped, arbitration proceeds with whatever reviewers returned) when
    # grok is unavailable. Unlike reviewer_1/_2 which can fall through to the
    # Step 5 auto-detect cascade (codex > agy > droid) — and silently
    # duplicate a higher reviewer slot — reviewer_3 explicitly returns "none"
    # so a missing grok skips the voice rather than introducing a duplicate.
    blueprint-review.reviewer_3) is_cli_available grok && echo "grok" && return
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

  # Step 5: Auto-detect
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

_execute_codex() {
  local prompt="$1"
  local duration="${2:-1200}"
  local max_retries="${LITMUS_CODEX_RETRIES:-4}"
  local retry_delay="${LITMUS_CODEX_RETRY_DELAY:-5}"
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

  local attempt=0
  local exit_code=0
  local output=""
  local last_was_transient=0  # narrows droid fallback to rate-limit/network exhaustion

  while [[ "$attempt" -le "$max_retries" ]]; do
    exit_code=0
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
      # Use official plugin's app-server protocol (stable, no stdin hang).
      # Pipe via stdin to avoid ARG_MAX limits on large diffs — the companion
      # reads piped stdin when no positional prompt is provided.
      # Omit --json to get raw review output (--json wraps in an envelope
      # that breaks downstream extract_review_json.py parsing)
      # ${effort_args[@]+...} guards against "unbound variable" when array is empty under set -u (macOS bash 3.2)
      output=$(printf '%s' "$prompt" | _portable_timeout "$duration" node "$_CODEX_COMPANION" task ${effort_args[@]+"${effort_args[@]}"} 2>&1) || exit_code=$?
    else
      # Fallback: direct CLI invocation
      local config_args=()
      if [[ ${#effort_args[@]} -gt 0 ]]; then
        config_args=(-c 'model_reasoning_effort="high"')
      fi
      output=$(printf '%s' "$prompt" | _portable_timeout "$duration" codex exec -s read-only ${config_args[@]+"${config_args[@]}"} - 2>&1) || exit_code=$?
    fi

    # Success — done
    if [[ "$exit_code" -eq 0 ]]; then
      break
    fi

    # Timeout (124) — retrying won't help, bail immediately
    if [[ "$exit_code" -eq 124 ]]; then
      break
    fi

    # Only retry on transient Codex service errors (network, API, rate-limit)
    # AND on non-blocking I/O races (EAGAIN). Script bugs (unbound variable,
    # syntax error, command not found) should not be retried.
    #
    # EAGAIN rationale: when multiple codex-companion sessions run in parallel,
    # the inherited stdin fd can be in non-blocking mode, causing fs.readFileSync(0)
    # inside the companion to throw "EAGAIN: resource temporarily unavailable, read"
    # instead of blocking. EAGAIN literally means "try again later" — exactly the
    # retry semantics we want. We match only the `EAGAIN` token (not the phrase
    # "resource temporarily unavailable") to avoid false-positives on unrelated
    # fork/thread exhaustion errors that share the same strerror text.
    if printf '%s' "$output" | grep -qiE 'ECONNREFUSED|ECONNRESET|ETIMEDOUT|EPIPE|EAGAIN|socket hang up|fetch failed|rate.limit|overloaded|capacity|5[0-9][0-9]|getaddrinfo'; then
      last_was_transient=1
      attempt=$((attempt + 1))
    else
      last_was_transient=0
      echo "⚠️  Codex failed with non-transient error (exit $exit_code) — not retrying" >&2
      break
    fi
  done

  # All retries exhausted or non-transient error — fall back to builtin
  if [[ "$exit_code" -ne 0 ]] && [[ "$exit_code" -ne 124 ]]; then
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

    # Droid escalation (narrow): only on transient-error exhaustion (rate-limit,
    # network, 5xx). Non-transient codex failures (script bugs, malformed prompt)
    # would likely break droid too — go straight to builtin in that case.
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
    if [[ "$last_was_transient" -eq 1 ]] && \
       [[ "$_droid_disabled" != "1" ]] && \
       is_cli_available droid; then
      echo "⚠️  Codex exhausted ${attempts_run} attempt(s) on transient errors — escalating to droid" >&2
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
      if [[ -n "$_git_root" && -d "$_git_root/.claude" ]]; then
        printf '{"ts":"%s","event":"codex-droid-fallback","codex_exit":%d,"droid_exit":%d,"droid_ok":%d,"codex_attempts":%d}\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$exit_code" "$droid_exit" "$_droid_ok" "$attempts_run" \
          >> "$_git_root/.claude/bypass-log.jsonl" 2>/dev/null || true
      fi

      if [[ "$_droid_ok" -eq 1 ]]; then
        printf '%s' "$droid_out"
        return 0
      fi
      echo "⚠️  Droid escalation failed (exit $droid_exit, output_bytes=${#droid_out}) — falling back to built-in review" >&2
    fi

    echo "⚠️  Codex failed after ${attempts_run} attempt(s) — falling back to built-in review" >&2
    echo "BUILTIN_FALLBACK"
    return 3
  fi

  printf '%s' "$output"
  return "$exit_code"
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
    # agy normally takes the prompt as an argv arg (and would be ARG_MAX-limited),
    # but `agy --print /dev/stdin` makes it read the prompt from fd 0 — so we pipe
    # and bypass the ~1MB argv limit for big review diffs. --sandbox restricts
    # terminal capabilities (matching dispatch.sh's readonly mode) — review prompts
    # emit JSON verdicts and never need to mutate the repo or fetch. Align
    # --print-timeout with our outer duration so agy's internal 5m default doesn't
    # abort before _portable_timeout does.
    agy)     printf '%s' "$prompt" | _portable_timeout "$duration" agy --sandbox --print-timeout "${duration}s" --print /dev/stdin 2>&1 ;;
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
             printf '%s' "$prompt" | _portable_timeout "$duration" grok --prompt-file /dev/stdin --max-turns 150 --sandbox readonly 2>&1 ;;
    builtin) echo "BUILTIN_FALLBACK"; return 3 ;;
    unsupported:*)
             # CLI was rejected upstream (deprecated/removed). Migration warning
             # was already emitted to stderr by resolve_role_cli; surface the
             # cause cleanly here instead of falling through to the wildcard
             # "Unsupported CLI: unsupported:amp" garbage.
             local _removed="${cli#unsupported:}"
             echo "busdriver: review CLI '$_removed' is no longer supported; use codex, agy, or droid" >&2
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
    codex|agy|droid) version=$(get_cli_version "$resolved") ;;
    builtin|none|missing:*|unsupported:*) version="n/a" ;;
  esac

  # Sanitize strings for JSON (strip quotes, backslashes, newlines)
  _json_safe() { tr -d '"\\\n' | head -1; }

  configured=$(echo "$configured" | _json_safe)
  resolved=$(echo "$resolved" | _json_safe)
  version=$(echo "$version" | _json_safe)

  # Report availability for all supported CLIs
  clis_json=""
  for cli in codex agy droid; do
    avail=$(is_cli_available "$cli" && echo true || echo false)
    ver=$(get_cli_version "$cli" | _json_safe)
    clis_json="${clis_json}\"${cli}\":{\"available\":${avail},\"version\":\"${ver}\"},"
  done
  clis_json="{${clis_json%,}}"

  printf '{"configured":"%s","resolved":"%s","version":"%s","clis":%s}\n' \
    "$configured" "$resolved" "$version" "$clis_json"
  exit 0
fi
