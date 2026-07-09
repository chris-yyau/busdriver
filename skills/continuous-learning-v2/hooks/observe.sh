#!/usr/bin/env bash
# Continuous Learning v2 - Observation Hook
#
# Captures tool use events for pattern analysis.
# Claude Code passes hook data via stdin as JSON.
#
# v2.1: Project-scoped observations — detects current project context
#       and writes observations to project-specific directory.
#
# Registered via plugin hooks/hooks.json (auto-loaded when plugin is enabled).
# Can also be registered manually in ~/.claude/settings.json.

set -e

# Hook phase from CLI argument: "pre" (PreToolUse) or "post" (PostToolUse).
# Manual settings.json installs can call this script without the plugin
# wrapper's positional phase argument, but Claude Code still exposes the hook
# event name in CLAUDE_HOOK_EVENT_NAME.  Fall back to that env var before
# defaulting to post so manually registered PreToolUse hooks are recorded as
# tool_start instead of being silently misclassified as tool_complete.
HOOK_PHASE="${1:-}"
if [ -z "$HOOK_PHASE" ]; then
  case "${CLAUDE_HOOK_EVENT_NAME:-}" in
    PreToolUse|pretooluse|pre_tool_use|pre) HOOK_PHASE="pre" ;;
    PostToolUse|posttooluse|post_tool_use|post) HOOK_PHASE="post" ;;
    *) HOOK_PHASE="post" ;;
  esac
fi

# ─────────────────────────────────────────────
# Read stdin first (before project detection)
# ─────────────────────────────────────────────

# Read JSON from stdin (Claude Code hook format)
INPUT_JSON=$(cat)

# Exit if no input
if [ -z "$INPUT_JSON" ]; then
  exit 0
fi

_is_windows_app_installer_stub() {
  # Windows 10/11 ships an "App Execution Alias" stub at
  #   %LOCALAPPDATA%\Microsoft\WindowsApps\python.exe
  #   %LOCALAPPDATA%\Microsoft\WindowsApps\python3.exe
  # Both are symlinks to AppInstallerPythonRedirector.exe which, when Python
  # is not installed from the Store, neither launches Python nor honors "-c".
  # Calls to it hang or print a bare "Python " line, silently breaking every
  # JSON-parsing step in this hook. Detect and skip such stubs here.
  local _candidate="$1"
  [ -z "$_candidate" ] && return 1
  local _resolved
  _resolved="$(command -v "$_candidate" 2>/dev/null || true)"
  [ -z "$_resolved" ] && return 1
  case "$_resolved" in
    *AppInstallerPythonRedirector.exe|*AppInstallerPythonRedirector.EXE) return 0 ;;
  esac
  # Also resolve one level of symlink on POSIX-like shells (Git Bash, WSL).
  if command -v readlink >/dev/null 2>&1; then
    local _target
    _target="$(readlink -f "$_resolved" 2>/dev/null || readlink "$_resolved" 2>/dev/null || true)"
    case "$_target" in
      *AppInstallerPythonRedirector.exe|*AppInstallerPythonRedirector.EXE) return 0 ;;
    esac
  fi
  return 1
}

resolve_python_cmd() {
  if [ -n "${CLV2_PYTHON_CMD:-}" ] && command -v "$CLV2_PYTHON_CMD" >/dev/null 2>&1; then
    printf '%s\n' "$CLV2_PYTHON_CMD"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1 && ! _is_windows_app_installer_stub python3; then
    printf '%s\n' python3
    return 0
  fi

  if command -v python >/dev/null 2>&1 && ! _is_windows_app_installer_stub python; then
    printf '%s\n' python
    return 0
  fi

  return 1
}

PYTHON_CMD="$(resolve_python_cmd 2>/dev/null || true)"
if [ -z "$PYTHON_CMD" ]; then
  echo "[observe] No python interpreter found, skipping observation" >&2
  exit 0
fi

# Propagate our stub-aware selection so detect-project.sh (which is sourced
# below) does not re-resolve and silently fall back to the App Installer stub.
# detect-project.sh honors an already-set CLV2_PYTHON_CMD.
export CLV2_PYTHON_CMD="${CLV2_PYTHON_CMD:-$PYTHON_CMD}"

# ─────────────────────────────────────────────
# Extract cwd from stdin for project detection
# ─────────────────────────────────────────────

# Extract cwd from the hook JSON to use for project detection.
# If cwd is a subdirectory inside a git repo, resolve it to the repo root so
# observations attach to the project instead of a nested path.
STDIN_CWD=$(echo "$INPUT_JSON" | "$PYTHON_CMD" -c '
import json, sys
try:
    data = json.load(sys.stdin)
    cwd = data.get("cwd", "")
    print(cwd)
except(KeyError, TypeError, ValueError):
    print("")
' 2>/dev/null || echo "")

# If cwd was provided in stdin, use it for project detection
if [ -n "$STDIN_CWD" ] && [ -d "$STDIN_CWD" ]; then
  _GIT_ROOT=$(git -C "$STDIN_CWD" rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$_GIT_ROOT" ]; then
    export CLAUDE_PROJECT_DIR="$_GIT_ROOT"
    unset CLV2_NO_PROJECT
  else
    unset CLAUDE_PROJECT_DIR
    export CLV2_NO_PROJECT=1
  fi
fi

# ─────────────────────────────────────────────
# Lightweight config and automated session guards
# ─────────────────────────────────────────────
#
# IMPORTANT: keep these guards above detect-project.sh.
# Sourcing detect-project.sh creates project-scoped directories and updates
# projects.json, so automated sessions must return before that point.

# shellcheck disable=SC1091
. "$(dirname "$0")/../scripts/lib/homunculus-dir.sh"
CONFIG_DIR="$(_clv2_resolve_homunculus_dir)"

# Skip if disabled (check both default and CLV2_CONFIG-derived locations)
if [ -f "$CONFIG_DIR/disabled" ]; then
  exit 0
fi
if [ -n "${CLV2_CONFIG:-}" ] && [ -f "$(dirname "$CLV2_CONFIG")/disabled" ]; then
  exit 0
fi

# Prevent observe.sh from firing on non-human sessions to avoid:
#   - ECC observing its own Haiku observer sessions (self-loop)
#   - ECC observing other tools' automated sessions
#   - automated sessions creating project-scoped homunculus metadata

# Layer 1: entrypoint. Only interactive terminal sessions should continue.
# sdk-ts: Agent SDK sessions can be human-interactive (e.g. via Happy).
# Non-interactive SDK automation is still filtered by Layers 2-5 below
# (ECC_HOOK_PROFILE=minimal, ECC_SKIP_OBSERVE=1, agent_id, path exclusions).
case "${CLAUDE_CODE_ENTRYPOINT:-cli}" in
  cli|sdk-ts|claude-desktop|claude-vscode) ;;
  *) exit 0 ;;
esac

# Layer 2: minimal hook profile suppresses non-essential hooks.
[ "${ECC_HOOK_PROFILE:-standard}" = "minimal" ] && exit 0

# Layer 3: cooperative skip env var for automated sessions.
[ "${ECC_SKIP_OBSERVE:-0}" = "1" ] && exit 0

# Layer 4: subagent sessions are automated by definition.
_ECC_AGENT_ID=$(echo "$INPUT_JSON" | "$PYTHON_CMD" -c "import json,sys; print(json.load(sys.stdin).get('agent_id',''))" 2>/dev/null || true)
[ -n "$_ECC_AGENT_ID" ] && exit 0

# Layer 5: known observer-session path exclusions.
_ECC_SKIP_PATHS="${ECC_OBSERVE_SKIP_PATHS:-observer-sessions,.claude-mem}"
if [ -n "$STDIN_CWD" ]; then
  IFS=',' read -ra _ECC_SKIP_ARRAY <<< "$_ECC_SKIP_PATHS"
  for _pattern in "${_ECC_SKIP_ARRAY[@]}"; do
    _pattern="${_pattern#"${_pattern%%[![:space:]]*}"}"
    _pattern="${_pattern%"${_pattern##*[![:space:]]}"}"
    [ -z "$_pattern" ] && continue
    case "$STDIN_CWD" in *"$_pattern"*) exit 0 ;; esac
  done
fi

# ─────────────────────────────────────────────
# Project detection
# ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source shared project detection helper
# This sets: PROJECT_ID, PROJECT_NAME, PROJECT_ROOT, PROJECT_DIR
# ponytail: cwd-keyed detect-project cache, 5-min TTL — delete the cache file
# (or wait 5 min) after a git init/root change; atomic mktemp+mv write.
# CACHE CONTRACT: every `export`ed var of detect-project.sh must be cached
# (grep the script; extend the printf below if upstream adds exports).
_PROJ_CACHE=""
_sha_cmd=""
if command -v sha256sum >/dev/null 2>&1; then _sha_cmd="sha256sum";
elif command -v shasum >/dev/null 2>&1; then _sha_cmd="shasum -a 256"; fi
if [[ -n "$_sha_cmd" && -n "${CONFIG_DIR:-}" ]]; then
  _key=$(printf '%s' "${STDIN_CWD:-}" | $_sha_cmd | cut -c1-16) || _key=""
  [[ -n "$_key" ]] && _PROJ_CACHE="${CONFIG_DIR}/.proj-cache-${_key}"
fi
_cache_stale=""
if [[ -n "$_PROJ_CACHE" && -f "$_PROJ_CACHE" ]]; then
  _cache_stale=$(find "$_PROJ_CACHE" -mmin +5 2>/dev/null) || _cache_stale="expired"
fi
if [[ -n "$_PROJ_CACHE" && -f "$_PROJ_CACHE" && -z "$_cache_stale" ]]; then
  # shellcheck disable=SC1090
  . "$_PROJ_CACHE"
  mkdir -p "$PROJECT_DIR" 2>/dev/null || true   # re-apply dir side-effect
else
  # shellcheck disable=SC1091
  source "${SKILL_ROOT}/scripts/detect-project.sh"
  if [[ -n "$_PROJ_CACHE" ]]; then
    _tmp=$(mktemp "${CONFIG_DIR}/.proj-cache.XXXXXX" 2>/dev/null) && {
      printf 'export PROJECT_ID=%q PROJECT_NAME=%q PROJECT_ROOT=%q PROJECT_DIR=%q\n' \
        "$PROJECT_ID" "$PROJECT_NAME" "$PROJECT_ROOT" "$PROJECT_DIR" > "$_tmp"
      printf 'export CLV2_PYTHON_CMD=%q CLV2_OBSERVER_PROMPT_PATTERN=%q CLV2_OBSERVER_SENTINEL_FILE=%q\n' \
        "${CLV2_PYTHON_CMD:-}" "${CLV2_OBSERVER_PROMPT_PATTERN:-}" "${CLV2_OBSERVER_SENTINEL_FILE:-}" >> "$_tmp"
      mv "$_tmp" "$_PROJ_CACHE"
    }
  fi
fi
PYTHON_CMD="${CLV2_PYTHON_CMD:-$PYTHON_CMD}"

# ─────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────

# ─────────────────────────────────────────────
# Fast path: parse + scrub + rotate + purge + append in ONE python spawn
# (observe_fast.py). Replaces the three legacy inline python blocks.
# printf, NOT a heredoc: an unquoted heredoc would shell-expand $/backticks
# inside the JSON payload; a quoted delimiter would block $INPUT_JSON itself.
# ─────────────────────────────────────────────
printf '%s' "$INPUT_JSON" | HOOK_PHASE="$HOOK_PHASE" PROJECT_ID="$PROJECT_ID" \
  PROJECT_NAME="$PROJECT_NAME" PROJECT_DIR="$PROJECT_DIR" \
  "$PYTHON_CMD" "${SCRIPT_DIR}/observe_fast.py" || true

# Lazy-start observer if enabled but not running (first-time setup)
# Use flock for atomic check-then-act to prevent race conditions
# Fallback for macOS (no flock): use lockfile or skip
LAZY_START_LOCK="${PROJECT_DIR}/.observer-start.lock"
_REMOVE_FILE_IF_PRESENT() {
  local target="$1"
  if [ -n "$target" ] && [ -e "$target" ]; then
    rm -- "$target" 2>/dev/null || true
  fi
}

_START_OBSERVER_LOGGED() {
  local bootstrap_log="${PROJECT_DIR}/observer-start.log"
  mkdir -p "$PROJECT_DIR"
  "${SKILL_ROOT}/agents/start-observer.sh" start >> "$bootstrap_log" 2>&1 || true
}

_CHECK_OBSERVER_RUNNING() {
  local pid_file="$1"
  if [ -f "$pid_file" ]; then
    local pid
    pid=$(cat "$pid_file" 2>/dev/null)
    # Validate PID is a positive integer (>1) to prevent signaling invalid targets
    case "$pid" in
      ''|*[!0-9]*|0|1)
        _REMOVE_FILE_IF_PRESENT "$pid_file"
        return 1
        ;;
    esac
    if kill -0 "$pid" 2>/dev/null; then
      return 0  # Process is alive
    fi
    # Stale PID file - remove it
    _REMOVE_FILE_IF_PRESENT "$pid_file"
  fi
  return 1  # No PID file or process dead
}

if [ -f "${CONFIG_DIR}/disabled" ]; then
  OBSERVER_ENABLED=false
else
  OBSERVER_ENABLED=false
  if [ -n "${CLV2_CONFIG:-}" ]; then
    CONFIG_FILE="$CLV2_CONFIG"
  elif [ -f "${CONFIG_DIR}/config.json" ]; then
    CONFIG_FILE="${CONFIG_DIR}/config.json"
  else
    CONFIG_FILE="${SKILL_ROOT}/config.json"
  fi
  # Use effective config path for both existence check and reading
  EFFECTIVE_CONFIG="$CONFIG_FILE"
  if [ -f "$EFFECTIVE_CONFIG" ] && [ -n "$PYTHON_CMD" ]; then
    _enabled=$(CLV2_CONFIG_PATH="$EFFECTIVE_CONFIG" "$PYTHON_CMD" -c "
import json, os
with open(os.environ['CLV2_CONFIG_PATH']) as f:
    cfg = json.load(f)
print(str(cfg.get('observer', {}).get('enabled', False)).lower())
" 2>/dev/null || echo "false")
    if [ "$_enabled" = "true" ]; then
      OBSERVER_ENABLED=true
    fi
  fi
fi

# Check both project-scoped AND global PID files (with stale PID recovery)
if [ "$OBSERVER_ENABLED" = "true" ]; then
  # Clean up stale PID files first
  _CHECK_OBSERVER_RUNNING "${PROJECT_DIR}/.observer.pid" || true
  _CHECK_OBSERVER_RUNNING "${CONFIG_DIR}/.observer.pid" || true

  # Check if observer is now running after cleanup
  if [ ! -f "${PROJECT_DIR}/.observer.pid" ] && [ ! -f "${CONFIG_DIR}/.observer.pid" ]; then
    # Use flock if available (Linux), fallback for macOS
    if command -v flock >/dev/null 2>&1; then
      (
        flock -n 9 || exit 0
        # Double-check PID files after acquiring lock
        _CHECK_OBSERVER_RUNNING "${PROJECT_DIR}/.observer.pid" || true
        _CHECK_OBSERVER_RUNNING "${CONFIG_DIR}/.observer.pid" || true
        if [ ! -f "${PROJECT_DIR}/.observer.pid" ] && [ ! -f "${CONFIG_DIR}/.observer.pid" ]; then
          _START_OBSERVER_LOGGED
        fi
      ) 9>"$LAZY_START_LOCK"
    else
      # macOS fallback: use lockfile if available, otherwise mkdir-based lock
      if command -v lockfile >/dev/null 2>&1; then
        # Use subshell to isolate exit and add trap for cleanup
        (
          trap '_REMOVE_FILE_IF_PRESENT "$LAZY_START_LOCK"' EXIT
          lockfile -r 1 -l 30 "$LAZY_START_LOCK" 2>/dev/null || exit 0
          _CHECK_OBSERVER_RUNNING "${PROJECT_DIR}/.observer.pid" || true
          _CHECK_OBSERVER_RUNNING "${CONFIG_DIR}/.observer.pid" || true
          if [ ! -f "${PROJECT_DIR}/.observer.pid" ] && [ ! -f "${CONFIG_DIR}/.observer.pid" ]; then
            _START_OBSERVER_LOGGED
          fi
          _REMOVE_FILE_IF_PRESENT "$LAZY_START_LOCK"
        )
      else
        # POSIX fallback: mkdir is atomic -- fails if dir already exists
        (
          trap 'rmdir "${LAZY_START_LOCK}.d" 2>/dev/null || true' EXIT
          mkdir "${LAZY_START_LOCK}.d" 2>/dev/null || exit 0
          _CHECK_OBSERVER_RUNNING "${PROJECT_DIR}/.observer.pid" || true
          _CHECK_OBSERVER_RUNNING "${CONFIG_DIR}/.observer.pid" || true
          if [ ! -f "${PROJECT_DIR}/.observer.pid" ] && [ ! -f "${CONFIG_DIR}/.observer.pid" ]; then
            _START_OBSERVER_LOGGED
          fi
        )
      fi
    fi
  fi
fi

# Throttle SIGUSR1: only signal observer every N observations (#521)
# This prevents rapid signaling when tool calls fire every second,
# which caused runaway parallel Claude analysis processes.
SIGNAL_EVERY_N="${ECC_OBSERVER_SIGNAL_EVERY_N:-20}"
SIGNAL_COUNTER_FILE="${PROJECT_DIR}/.observer-signal-counter"
SIGNAL_COUNTER_LOCK="${SIGNAL_COUNTER_FILE}.lock"
ACTIVITY_FILE="${PROJECT_DIR}/.observer-last-activity"

touch "$ACTIVITY_FILE" 2>/dev/null || true

# Serialize the throttle-counter read-modify-write. observe.sh runs on every
# tool call (which can fire every second), so concurrent invocations previously
# raced on this counter: both read the same value, both incremented, and one
# write was lost, signaling the observer at unpredictable intervals (#2296).
# Prefer flock (a kernel advisory lock the OS releases automatically if the hook
# is killed); fall back to the atomic mkdir lock this script already uses for
# the lazy-start path above. Both wrap the same read-modify-write below.
should_signal=0

_clv2_bump_signal_counter() {
  if [ -f "$SIGNAL_COUNTER_FILE" ]; then
    counter=$(cat "$SIGNAL_COUNTER_FILE" 2>/dev/null || echo 0)
    # Guard against a corrupt counter file: a non-integer value would abort the
    # hook under `set -e` at the arithmetic below.
    case "$counter" in
      ''|*[!0-9]*) counter=0 ;;
    esac
    counter=$((counter + 1))
    if [ "$counter" -ge "$SIGNAL_EVERY_N" ]; then
      should_signal=1
      counter=0
    fi
    echo "$counter" > "$SIGNAL_COUNTER_FILE"
  else
    echo "1" > "$SIGNAL_COUNTER_FILE"
  fi
}

if command -v flock >/dev/null 2>&1 && exec 8>"$SIGNAL_COUNTER_LOCK" 2>/dev/null; then
  # flock is auto-released when fd 8 closes or the process dies, so there is no
  # stale lock and no lost increment. Use a bounded -w wait so the hook never
  # blocks indefinitely, and only bump the counter while the lock is held -- on
  # a timeout we skip the tick rather than doing an unlocked read-modify-write.
  if flock -w 2 8 2>/dev/null; then
    _clv2_bump_signal_counter
    flock -u 8 2>/dev/null || true
  fi
  exec 8>&- 2>/dev/null || true
else
  # No flock (e.g. macOS): atomic mkdir lock with a bounded spin so the hook
  # never blocks indefinitely. A trap releases the lock on every exit path --
  # including the async-timeout SIGTERM -- so a killed hook does not strand the
  # directory. We deliberately do NOT hand-roll PID-based stale reclaim:
  # re-verifying then removing another process's lock is racy and can delete a
  # live re-acquirer's directory, reintroducing the very race this fixes.
  _signal_lock_held=0
  _signal_lock_spins=0
  while [ "$_signal_lock_spins" -lt 100 ]; do
    if mkdir "$SIGNAL_COUNTER_LOCK" 2>/dev/null; then
      # EXIT cleans up on normal completion. INT/TERM must release AND exit:
      # a signal trap that only released the lock would otherwise fall through
      # and continue the read-modify-write without ownership.
      trap 'rmdir "$SIGNAL_COUNTER_LOCK" 2>/dev/null || true' EXIT
      trap 'rmdir "$SIGNAL_COUNTER_LOCK" 2>/dev/null || true; exit 130' INT
      trap 'rmdir "$SIGNAL_COUNTER_LOCK" 2>/dev/null || true; exit 143' TERM
      _signal_lock_held=1
      break
    fi
    _signal_lock_spins=$((_signal_lock_spins + 1))
    sleep 0.02
  done
  if [ "$_signal_lock_held" -eq 1 ]; then
    # Bump only under the held lock -- never an unlocked read-modify-write.
    _clv2_bump_signal_counter
    rmdir "$SIGNAL_COUNTER_LOCK" 2>/dev/null || true
    trap - EXIT INT TERM
  fi
  # If the lock could not be acquired within the spin budget we skip this tick
  # rather than racing on an unlocked counter. Dropping one throttle tick under
  # extreme contention only delays the next observer signal slightly; it never
  # corrupts the counter or signals spuriously.
fi

# Signal observer if running and throttle allows (check both project-scoped and global observer, deduplicate)
if [ "$should_signal" -eq 1 ]; then
  signaled_pids=" "
  for pid_file in "${PROJECT_DIR}/.observer.pid" "${CONFIG_DIR}/.observer.pid"; do
    if [ -f "$pid_file" ]; then
      observer_pid=$(cat "$pid_file" 2>/dev/null || true)
      # Validate PID is a positive integer (>1)
      case "$observer_pid" in
        ''|*[!0-9]*|0|1)
          _REMOVE_FILE_IF_PRESENT "$pid_file"
          continue
          ;;
      esac
      # Deduplicate: skip if already signaled this pass
      case "$signaled_pids" in
        *" $observer_pid "*) continue ;;
      esac
      if kill -0 "$observer_pid" 2>/dev/null; then
        kill -USR1 "$observer_pid" 2>/dev/null || true
        signaled_pids="${signaled_pids}${observer_pid} "
      fi
    fi
  done
fi

exit 0
