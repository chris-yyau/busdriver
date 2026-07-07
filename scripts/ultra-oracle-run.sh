#!/usr/bin/env bash
# ultra-oracle-run.sh — shell-agnostic entry point for the UltraOracle expert
# witness. Encapsulates the full lifecycle (surface-gate -> consult -> wait ->
# emit) behind a bash shebang so it runs correctly no matter what shell the
# CALLER uses.
#
# WHY THIS EXISTS: scripts/lib/ultra-oracle.sh is deliberately bash-only — it
# resolves its own dir via ${BASH_SOURCE[0]} and uses `local -a` arrays, and it
# fail-closes loudly when sourced outside bash (BASH_SOURCE unset under zsh).
# The council / brainstorming / ultraoracle SKILL.md blocks are pasted verbatim
# into the executor's Bash tool, which on a zsh-default machine (macOS) runs zsh
# — so an in-block `source ultra-oracle.sh` aborted with rc=1 and every
# ultra-council/ultimate-council run silently rendered ORACLE_FAILED
# [adapter-unavailable]; the oracle never launched. The voice dispatches were
# immune only because dispatch.sh has its own bash shebang. This wrapper gives
# the oracle the same immunity: callers invoke `bash ultra-oracle-run.sh ...`
# instead of sourcing the lib into their own shell.
#
# Usage:
#   bash ultra-oracle-run.sh <surface> <force> <prompt-file> <out-path>
#     <surface>     brainstorming | blueprintReview | council
#     <force>       1 to force the run (per-invocation escalation) else 0
#     <prompt-file> file whose contents are the oracle prompt
#     <out-path>    where the verdict markdown is written (also <out>.rc marker)
#
# Emits to stdout exactly ONE of these on the FIRST line, blocking until done:
#   NOT_ATTEMPTED            gate disabled AND not forced -> caller omits section
#   FAILED [<status>]        attempted but no usable verdict -> caller renders banner
#   VERDICT                  followed by the verdict text on subsequent lines
# Always exits 0 (typed token carries the status; a non-zero exit under the
# caller's `set -e` must never abort the surrounding council).
set -u

SURFACE="${1:-}"; FORCE="${2:-0}"; PROMPT_FILE="${3:-}"; OUT="${4:-}"
if [[ -z "$SURFACE" || -z "$PROMPT_FILE" || -z "$OUT" ]]; then
  echo "FAILED [bad-args]"; exit 0
fi

# Derive plugin root from our own location (bash guarantees BASH_SOURCE here) so
# we do not depend on the caller exporting CLAUDE_PLUGIN_ROOT.
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$_SELF_DIR/.." && pwd)}"

# Decide attempt-worthiness (forced OR surface-enabled) BEFORE paying the cost of
# sourcing the full bash-only adapter. This must come first: on a normal
# (disabled, non-forced) run, an adapter that fails to source is NOT a real
# failure from the caller's perspective — nothing was ever going to run — so it
# must stay NOT_ATTEMPTED, matching the pre-wrapper `if source && gate` behavior
# that omitted the Expert Witness section entirely. Checking gate first (via the
# lightweight config-only lib, not the full adapter) prevents a broken/missing
# adapter from manufacturing a loud FAILED banner on every ordinary council run.
_SHOULD_ATTEMPT=0
if [[ "$FORCE" == 1 ]]; then
  _SHOULD_ATTEMPT=1
else
  # shellcheck source=/dev/null
  if source "$ROOT/scripts/lib/ultra-oracle-config.sh" 2>/dev/null && ultra_oracle_surface_enabled "$SURFACE"; then
    _SHOULD_ATTEMPT=1
  fi
fi
if [[ "$_SHOULD_ATTEMPT" != 1 ]]; then
  echo "NOT_ATTEMPTED"; exit 0
fi

# shellcheck source=/dev/null
if ! source "$ROOT/scripts/lib/ultra-oracle.sh" 2>/dev/null; then
  echo "FAILED [adapter-unavailable]"; exit 0
fi

mkdir -p "$(dirname "$OUT")"
STATUS="$(ultra_oracle_consult --mode background --slug "ultra oracle expert witness" \
  --out "$OUT" --prompt-file "$PROMPT_FILE" 2>/dev/null || true)"
if [[ "$STATUS" != dispatched ]]; then
  echo "FAILED [${STATUS:-adapter-unavailable}]"; exit 0
fi

# Block until the backgrounded consult writes its .rc marker (or the cap elapses).
_n=0; _cap="$(ultra_oracle_timeout_cap)"
while [[ ! -f "$OUT.rc" && "$_n" -lt "$_cap" ]]; do sleep 2; _n=$((_n + 2)); done
_rc="$(cat "$OUT.rc" 2>/dev/null)"
if [[ -s "$OUT" && "$_rc" == 0 ]]; then
  echo "VERDICT"; cat "$OUT"
elif [[ "$_rc" == 0 ]]; then
  echo "FAILED [empty verdict]"
elif [[ "$_rc" == 124 ]]; then
  echo "FAILED [timeout]"
elif [[ -n "$_rc" ]]; then
  echo "FAILED [error rc=$_rc]"
else
  echo "FAILED [timeout]"
fi
exit 0
