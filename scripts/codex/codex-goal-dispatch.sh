#!/usr/bin/env bash
# codex-goal-dispatch.sh — single codex exec call for the codex-goal-handover skill loop.
#
# Each invocation runs ONE Codex iteration (first-call or resume), enforces the
# CodexGoalIterationReport schema on the final response, writes the result to a
# numbered file in the run directory, and prints that path to stdout.
#
# Usage:
#   codex-goal-dispatch.sh --first  --run-dir DIR [--model M] [--effort E] -- "$PROMPT"
#   codex-goal-dispatch.sh --resume --run-dir DIR [--model M] [--effort E] -- "$PROMPT"
#
# Prompt is read from the trailing arg OR stdin (use '--' before the arg to be safe).
#
# Writes:
#   $RUN_DIR/iter-$N-result.json   (schema-enforced final response from Codex)
#   $RUN_DIR/iter-$N-codex.log     (full codex exec stderr/stdout for debug)
# Prints to stdout:
#   $RUN_DIR/iter-$N-result.json   (caller reads and parses)
#
# Exit codes:
#   0 — Codex returned a schema-valid response
#   1 — Codex exited non-zero
#   2 — Result file missing or schema-invalid
#  64 — Bad usage
#  66 — Required file (schema) not found
# 127 — codex CLI not installed

set -euo pipefail

MODE=""
RUN_DIR=""
MODEL=""
EFFORT=""
PROMPT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --first)   MODE=first;  shift ;;
    --resume)  MODE=resume; shift ;;
    --run-dir) RUN_DIR="${2:?--run-dir requires a value}"; shift 2 ;;
    --model)   MODEL="${2:?--model requires a value}";     shift 2 ;;
    --effort)  EFFORT="${2:?--effort requires a value}";   shift 2 ;;
    --)        shift; PROMPT="${1:-}"; break ;;
    -h|--help) sed -n '2,/^$/p' "$0" >&2; exit 0 ;;
    *)         echo "[codex-goal-dispatch] unknown arg: $1" >&2; exit 64 ;;
  esac
done

[[ -z "$MODE"    ]] && { echo "[codex-goal-dispatch] specify --first or --resume" >&2; exit 64; }
[[ -z "$RUN_DIR" ]] && { echo "[codex-goal-dispatch] specify --run-dir" >&2; exit 64; }

command -v codex >/dev/null 2>&1 || { echo "[codex-goal-dispatch] codex CLI not on PATH" >&2; exit 127; }
command -v jq    >/dev/null 2>&1 || { echo "[codex-goal-dispatch] jq required" >&2; exit 127; }

if [[ -z "$PROMPT" ]] && ! [[ -t 0 ]]; then
  PROMPT="$(cat)"
fi
[[ -z "$PROMPT" ]] && { echo "[codex-goal-dispatch] empty prompt" >&2; exit 64; }

mkdir -p "$RUN_DIR"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="$SCRIPT_DIR/goal-result.schema.json"
[[ -f "$SCHEMA" ]] || { echo "[codex-goal-dispatch] schema not found at $SCHEMA" >&2; exit 66; }

# Determine next iter number by counting existing result files
EXISTING=$(find "$RUN_DIR" -maxdepth 1 -name 'iter-*-result.json' 2>/dev/null | wc -l | tr -d ' ')
N=$((EXISTING + 1))
RESULT_FILE="$RUN_DIR/iter-$N-result.json"
LOG_FILE="$RUN_DIR/iter-$N-codex.log"

# First-iter must use --first; subsequent must use --resume — enforce.
if [[ "$MODE" == "first" && "$N" -gt 1 ]]; then
  echo "[codex-goal-dispatch] --first passed but iter $N already exists in $RUN_DIR" >&2
  exit 64
fi
if [[ "$MODE" == "resume" && "$N" -eq 1 ]]; then
  echo "[codex-goal-dispatch] --resume passed but no prior iter exists in $RUN_DIR" >&2
  exit 64
fi

# Capture HEAD before so the helper can detect whether Codex committed
PRE_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "no-git")
echo "$PRE_HEAD" > "$RUN_DIR/iter-$N-pre-head.txt"

# Build codex command. exec resume puts the subcommand FIRST; opts apply to it.
if [[ "$MODE" == "first" ]]; then
  set -- exec \
    --sandbox workspace-write \
    --output-schema "$SCHEMA" \
    -o "$RESULT_FILE"
  [[ -n "$MODEL"  ]] && set -- "$@" --model "$MODEL"
  [[ -n "$EFFORT" ]] && set -- "$@" -c "model_reasoning_effort=\"$EFFORT\""
  set -- "$@" "$PROMPT"
else
  set -- exec resume --last \
    --sandbox workspace-write \
    --output-schema "$SCHEMA" \
    -o "$RESULT_FILE"
  [[ -n "$MODEL"  ]] && set -- "$@" --model "$MODEL"
  [[ -n "$EFFORT" ]] && set -- "$@" -c "model_reasoning_effort=\"$EFFORT\""
  set -- "$@" "$PROMPT"
fi

# Run. Tee log for debug; codex emits commentary on stderr/stdout, the final
# schema-valid JSON lands in $RESULT_FILE via -o.
if ! codex "$@" >"$LOG_FILE" 2>&1; then
  echo "[codex-goal-dispatch] codex exec failed; see $LOG_FILE" >&2
  exit 1
fi

# Validate the result file exists, is non-empty, and matches schema essentials
if [[ ! -s "$RESULT_FILE" ]]; then
  echo "[codex-goal-dispatch] codex did not write a result file at $RESULT_FILE" >&2
  exit 2
fi
if ! jq -e '.summary and .self_assessed_status and (.committed != null)' "$RESULT_FILE" >/dev/null 2>&1; then
  echo "[codex-goal-dispatch] result JSON missing required fields. See $RESULT_FILE" >&2
  exit 2
fi

echo "$RESULT_FILE"
