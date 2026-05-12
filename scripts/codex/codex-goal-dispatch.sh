#!/usr/bin/env bash
# codex-goal-dispatch.sh — single codex exec call for the codex-goal-handover skill.
#
# Runs ONE Codex iteration with a fresh session (no resume). Enforces the
# CodexGoalIterationReport schema on the final response. Writes the result
# to the caller-supplied path and prints that path to stdout.
#
# Fresh-context-per-iter is intentional. Rationale:
#   - `codex exec resume` does not accept --sandbox or --output-schema, so
#     iter >= 2 would lose schema enforcement.
#   - Geoffrey Huntley's published Ralph Loop principle is fresh context per
#     iter; preserved context is documented as a failure-prone variant.
#   - Each call is therefore independent — the calling skill is responsible
#     for replaying the spec and any steering prompt on subsequent iters.
#
# Usage:
#   codex-goal-dispatch.sh --result-file PATH [--model M] [--effort E] -- "$PROMPT"
#
# Prompt is read from the trailing arg OR stdin if no arg is given after `--`.
#
# Writes:
#   $RESULT_FILE              (schema-enforced final response from Codex)
#   $RESULT_FILE.codex.log    (codex stderr/stdout for debug)
#   $RESULT_FILE.pre-head.txt (HEAD before this iter, for caller commit-detect)
# Prints to stdout:
#   $RESULT_FILE              (caller reads and parses)
#
# Exit codes:
#   0 — Codex returned a schema-valid response
#   1 — Codex exited non-zero
#   2 — Result file missing or schema-invalid
#  64 — Bad usage / invalid arg value
#  66 — Required file (schema) not found
# 127 — Required CLI not installed

set -euo pipefail

RESULT_FILE=""
MODEL=""
EFFORT=""
PROMPT=""

# Explicit value check (NOT ${2:?...}) so missing-value errors exit with the
# documented bad-usage code 64 rather than Bash's parameter-expansion default (1).
require_value() {
  if [[ -z "${2:-}" ]]; then
    echo "[codex-goal-dispatch] $1 requires a value" >&2
    exit 64
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --result-file) require_value "$1" "${2:-}"; RESULT_FILE="$2"; shift 2 ;;
    --model)       require_value "$1" "${2:-}"; MODEL="$2";       shift 2 ;;
    --effort)      require_value "$1" "${2:-}"; EFFORT="$2";      shift 2 ;;
    --)            shift; PROMPT="$*"; break ;;
    -h|--help)     sed -n '2,/^$/p' "$0" >&2; exit 0 ;;
    *)             echo "[codex-goal-dispatch] unknown arg: $1 (prompt must be after --)" >&2; exit 64 ;;
  esac
done

[[ -z "$RESULT_FILE" ]] && { echo "[codex-goal-dispatch] specify --result-file" >&2; exit 64; }

# Allowlist MODEL and EFFORT to prevent TOML-string breakout via `-c key="value"`
# which could otherwise escalate to sandbox_mode=danger-full-access etc.
if [[ -n "$MODEL" && ! "$MODEL" =~ ^[A-Za-z0-9._/:-]+$ ]]; then
  echo "[codex-goal-dispatch] --model contains unsupported characters: $MODEL" >&2
  exit 64
fi
case "${EFFORT:-}" in
  ''|minimal|low|medium|high|xhigh) ;;
  *) echo "[codex-goal-dispatch] --effort must be one of: minimal|low|medium|high|xhigh (got: $EFFORT)" >&2; exit 64 ;;
esac

command -v codex >/dev/null 2>&1 || { echo "[codex-goal-dispatch] codex CLI not on PATH" >&2; exit 127; }
command -v jq    >/dev/null 2>&1 || { echo "[codex-goal-dispatch] jq required" >&2; exit 127; }

if [[ -z "$PROMPT" ]] && ! [[ -t 0 ]]; then
  PROMPT="$(cat)"
fi
[[ -z "$PROMPT" ]] && { echo "[codex-goal-dispatch] empty prompt" >&2; exit 64; }

mkdir -p "$(dirname "$RESULT_FILE")"
LOG_FILE="${RESULT_FILE}.codex.log"
PRE_HEAD_FILE="${RESULT_FILE}.pre-head.txt"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="$SCRIPT_DIR/goal-result.schema.json"
[[ -f "$SCHEMA" ]] || { echo "[codex-goal-dispatch] schema not found at $SCHEMA" >&2; exit 66; }

git rev-parse HEAD 2>/dev/null > "$PRE_HEAD_FILE" || echo "no-git" > "$PRE_HEAD_FILE"

# Build codex exec invocation. Fresh session every call (no resume).
CODEX_ARGS=(exec --sandbox workspace-write --output-schema "$SCHEMA" -o "$RESULT_FILE")
[[ -n "$MODEL" ]] && CODEX_ARGS+=(--model "$MODEL")
# Pass effort as a separate -c key=value (no embedded quotes) so even if EFFORT
# ever bypasses the allowlist it cannot expand into additional TOML keys.
[[ -n "$EFFORT" ]] && CODEX_ARGS+=(-c "model_reasoning_effort=$EFFORT")
CODEX_ARGS+=("$PROMPT")

if ! codex "${CODEX_ARGS[@]}" >"$LOG_FILE" 2>&1; then
  echo "[codex-goal-dispatch] codex exec failed; see $LOG_FILE" >&2
  exit 1
fi

if [[ ! -s "$RESULT_FILE" ]]; then
  echo "[codex-goal-dispatch] codex did not write a result file at $RESULT_FILE (see $LOG_FILE)" >&2
  exit 2
fi
# Strict type check (not null-only): defense in depth against future CLI regressions
# where --output-schema enforcement could be weakened or bypassed via -c overrides.
if ! jq -e '
  (.summary | type == "string") and
  (.self_assessed_status as $s | $s == "complete" or $s == "in_progress" or $s == "blocked") and
  (.committed | type == "boolean")
' "$RESULT_FILE" >/dev/null 2>&1; then
  echo "[codex-goal-dispatch] result JSON failed type check. See $RESULT_FILE" >&2
  exit 2
fi

echo "$RESULT_FILE"
