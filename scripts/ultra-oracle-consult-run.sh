#!/usr/bin/env bash
# ultra-oracle-consult-run.sh — shell-agnostic BLOCKING passthrough to
# ultra_oracle_consult for the brainstorming + ultraoracle surfaces.
#
# WHY THIS EXISTS (issue #296): scripts/lib/ultra-oracle.sh is deliberately
# bash-only — it resolves its own dir via ${BASH_SOURCE[0]} and uses `local -a`
# arrays, and it fail-closes loudly when sourced outside bash (BASH_SOURCE unset
# under zsh). The brainstorming and ultraoracle SKILL.md blocks are pasted
# verbatim into the executor's Bash tool, which on a zsh-default machine (macOS)
# runs zsh — so an in-block `source ultra-oracle.sh` aborted with rc=1 and the
# consult silently never launched. This wrapper runs the source+consult under a
# guaranteed bash shebang (the same immunity council's ultra-oracle-run.sh and
# dispatch.sh already have).
#
# Unlike the council wrapper, this one PASSES THROUGH ultra_oracle_consult's raw
# typed token (ok | skipped:user | skipped:disabled | skipped:unavailable |
# timeout | error) instead of collapsing to VERDICT/FAILED/NOT_ATTEMPTED — both
# callers render distinct messages per status (brainstorming: skipped:user →
# proceed vs error → block; ultraoracle: ORACLE_FAILED [$STATUS]), so the
# distinction must survive.
#
# Usage:
#   bash ultra-oracle-consult-run.sh [--surface <name>] <ultra_oracle_consult args...>
#     --surface <name>  (optional, leading) run ONLY when that USER-config surface
#                       is enabled; otherwise print `skipped:disabled` and exit 0.
#                       Used by brainstorming (its opt-in gate). Omitted by
#                       ultraoracle, which always runs when the skill is invoked.
#     remaining args    forwarded verbatim to ultra_oracle_consult, e.g.
#                       --mode blocking --prompt-file <p> --out <o>
#                       [--context <glob>]... --slug <words>
#
# Prints ultra_oracle_consult's raw token on stdout; the verdict lands at --out.
# stderr (oracle's --heartbeat progress) flows to the terminal, as it did when the
# SKILL sourced the lib directly. Always exits 0 — the token carries the status; a
# non-zero exit under the caller's shell must never abort the surrounding skill.
set -u

# Derive plugin root from our own location (bash guarantees BASH_SOURCE here) so
# our sibling libs are ALWAYS co-located under our own scripts/lib. Resolve ROOT
# from our own on-disk location (bash guarantees BASH_SOURCE here) and do NOT let a
# caller's CLAUDE_PLUGIN_ROOT override where we source our own libraries from — a
# stale/mismatched env var could otherwise run this wrapper from one plugin checkout
# while sourcing the adapter from another.
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$_SELF_DIR/.." && pwd)"

# Extract an optional --surface flag; forward everything else to the adapter.
SURFACE=""
_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --surface)
      # A missing value — no arg at all, OR the next token is itself a flag
      # (e.g. `--surface --mode`) — is a caller bug. Fail CLOSED rather than
      # consume a flag as the surface name and silently skip the consult.
      { [[ $# -ge 2 ]] && [[ "$2" != --* ]]; } || { echo "error"; exit 0; }
      SURFACE="$2"; shift 2 ;;
    *) _ARGS+=("$1"); shift ;;
  esac
done

# Surface gate (brainstorming only). Use the lightweight config-only lib — no need
# to pay for the full adapter just to decide the surface is disabled. A source
# FAILURE (missing/misresolved lib) must fail CLOSED to `error`, NOT collapse to
# `skipped:disabled` — a silent skip would reintroduce the very silent-no-consult
# bug this wrapper exists to prevent. Only a genuinely-disabled surface skips.
if [[ -n "$SURFACE" ]]; then
  # shellcheck source=/dev/null
  if ! source "$ROOT/scripts/lib/ultra-oracle-config.sh" 2>/dev/null; then
    echo "error"; exit 0
  fi
  if ! ultra_oracle_surface_enabled "$SURFACE"; then
    echo "skipped:disabled"; exit 0
  fi
fi

# shellcheck source=/dev/null
if ! source "$ROOT/scripts/lib/ultra-oracle.sh" 2>/dev/null; then
  echo "error"; exit 0
fi

# No forwarded args means no --out — ultra_oracle_consult would reject it; short
# circuit to the same fail-closed token (guards "${_ARGS[@]}" under set -u/bash 3.2).
if [[ "${#_ARGS[@]}" -eq 0 ]]; then echo "error"; exit 0; fi

STATUS="$(ultra_oracle_consult "${_ARGS[@]}")"
[[ -n "$STATUS" ]] || STATUS="error"
printf '%s\n' "$STATUS"
exit 0
