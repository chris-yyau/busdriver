#!/usr/bin/env bash
# careful-guard.sh — PreToolUse hook for Bash commands
# Detects destructive operations and triggers confirmation prompt.
# Returns {"permissionDecision":"ask","message":"..."} to warn, or {} to allow.
#
# Ported from garrytan/gstack careful/bin/check-careful.sh (MIT)
# Stripped: telemetry, kubectl/docker patterns (not relevant for solo dev)
# Added: git clean -f detection
set -euo pipefail

INPUT=$(cat)

# Extract the "command" field from tool_input JSON
# Prefer Python for correct JSON parsing (handles escaped quotes, multiline commands)
# Fall back to grep only when Python is unavailable
if command -v python3 &>/dev/null; then
  CMD=$(printf '%s' "$INPUT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("tool_input",{}).get("command",""))' 2>/dev/null || true)
fi

# Grep fallback when Python is not available
if [[ -z "$CMD" ]]; then
  CMD=$(printf '%s' "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//;s/"$//' || true)
fi

# No command extracted — allow
if [[ -z "$CMD" ]]; then
  echo '{}'
  exit 0
fi

CMD_LOWER=$(printf '%s' "$CMD" | tr '[:upper:]' '[:lower:]')

# --- Safe exceptions: rm -rf of known build artifacts ---
if printf '%s' "$CMD" | grep -qE 'rm\s+(-[a-zA-Z]*r[a-zA-Z]*\s+|--recursive\s+)' 2>/dev/null; then
  SAFE_ONLY=true
  RM_ARGS=$(printf '%s' "$CMD" | sed -E 's/.*rm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*//;s/--recursive[[:space:]]*//')
  set -f  # disable glob expansion on unquoted vars
  for target in $RM_ARGS; do
    case "$target" in
      */node_modules|node_modules|*/\.next|\.next|*/dist|dist|*/__pycache__|__pycache__|*/\.cache|\.cache|*/build|build|*/\.turbo|\.turbo|*/coverage|coverage|*/target|target)
        ;; # safe build artifact
      -*)
        ;; # flag, skip
      *)
        SAFE_ONLY=false
        break
        ;;
    esac
  done
  set +f  # restore glob expansion
  if [[ "$SAFE_ONLY" == true ]]; then
    echo '{}'
    exit 0
  fi
fi

# --- Destructive pattern checks (first match wins) ---
WARN=""

# rm -rf / rm -r / rm --recursive (non-safe targets)
if printf '%s' "$CMD" | grep -qE 'rm\s+(-[a-zA-Z]*r|--recursive)' 2>/dev/null; then
  WARN="Destructive: recursive delete (rm -r). This permanently removes files."
fi

# DROP TABLE / DROP DATABASE
if [[ -z "$WARN" ]] && printf '%s' "$CMD_LOWER" | grep -qE 'drop\s+(table|database)' 2>/dev/null; then
  WARN="Destructive: SQL DROP detected. This permanently deletes database objects."
fi

# TRUNCATE
if [[ -z "$WARN" ]] && printf '%s' "$CMD_LOWER" | grep -qE '\btruncate\b' 2>/dev/null; then
  WARN="Destructive: SQL TRUNCATE detected. This deletes all rows from a table."
fi

# git push --force / git push -f (but NOT --force-with-lease which is the safe alternative)
if [[ -z "$WARN" ]] && printf '%s' "$CMD" | grep -qE 'git\s+push\s+.*(-f\b|--force\b)' 2>/dev/null && ! printf '%s' "$CMD" | grep -qE -- '--force-with-lease' 2>/dev/null; then
  WARN="Destructive: git force-push rewrites remote history."
fi

# git reset --hard
if [[ -z "$WARN" ]] && printf '%s' "$CMD" | grep -qE 'git\s+reset\s+--hard' 2>/dev/null; then
  WARN="Destructive: git reset --hard discards all uncommitted changes."
fi

# git checkout . / git restore . (standalone . only, not .gitignore etc)
if [[ -z "$WARN" ]] && printf '%s' "$CMD" | grep -qE 'git\s+(checkout|restore)\s+\.(\s|$)' 2>/dev/null; then
  WARN="Destructive: discards all uncommitted changes in the working tree."
fi

# git clean -f (removes untracked files)
if [[ -z "$WARN" ]] && printf '%s' "$CMD" | grep -qE 'git\s+clean\s+.*-[a-zA-Z]*f' 2>/dev/null; then
  WARN="Destructive: git clean -f removes untracked files permanently."
fi

# --- Output ---
if [[ -n "$WARN" ]]; then
  WARN_ESCAPED=$(printf '%s' "$WARN" | sed 's/"/\\"/g')
  printf '{"permissionDecision":"ask","message":"[careful] %s"}\n' "$WARN_ESCAPED"
else
  echo '{}'
fi
