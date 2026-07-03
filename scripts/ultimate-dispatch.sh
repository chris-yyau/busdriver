#!/bin/bash
# ultimate-dispatch.sh — shared entry point for the "ultimate" tier (Claude Fable via the
# zenmux/Anthropic-API-compatible gateway). BOTH ultimate surfaces route through here:
#   - the blueprint-review "ultimate arbiter" escalation, and
#   - the council "Mythos Witness" expert witness.
#
# It does NOT reinvent the hardened gateway `claude -p` dispatch — it REUSES the
# credential-contained helper the arbiter already ships:
#   - role slug "arbiter" delegates to skills/blueprint-review/scripts/dispatch-gateway-arbiter.sh
#     (the verdict-JSON path: pre-created placeholder, Edit-scoped to the output, structural
#     post-check). That script owns the full credential-containment + provider scrub; this
#     wrapper only adds the one-retry / fail-closed loudness contract on top.
#   - any other role slug (e.g. "mythos-witness") runs a generic TEXT dispatch: a `claude -p
#     --bare` subprocess pinned to claude-fable-5 through the gateway whose final response is
#     captured to the output path. Read-only tools, no Edit/Bash, credential delivered ONLY
#     through a 0600 --settings file (never argv, never the subprocess environment) — the same
#     containment pattern as the arbiter helper.
#
# Contract:
#   ultimate-dispatch.sh <role-slug> <prompt-file> <output-path>
#   - <prompt-file>  absolute path to a readable, non-empty prompt file
#   - <output-path>  absolute path the verdict/response is written to
# Pins claude-fable-5 (override BLUEPRINT_ARBITER_GATEWAY_MODEL). Fail-CLOSED: prints a loud
# WARNING and exits non-zero when gateway creds are missing or the dispatch fails twice.
#
# Exit codes:
#   0  dispatch ran and wrote output
#   3  gateway not configured (creds missing) — caller falls back to its non-ultimate path
#   1  gateway configured but the dispatch failed twice (fail-closed)
#
# bash ONLY. Sourcing under zsh silently mis-binds BASH_SOURCE and half-loads; guard loudly.
if [ -n "${ZSH_VERSION:-}" ]; then
  echo "ultimate-dispatch: ERROR — this script requires bash, not zsh (BASH_SOURCE-based path resolution mis-binds under zsh)" >&2
  # `return` succeeds when sourced; the `|| exit` covers the executed-as-command case.
  # shellcheck disable=SC2317
  return 1 2>/dev/null || exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
# shellcheck source=/dev/null
source "$_PLUGIN_ROOT/scripts/lib/resolve-cli.sh"

warn_closed() { echo "ultimate-dispatch: FAIL-CLOSED — $1" >&2; }
skip()        { echo "ultimate-dispatch: $1 — gateway not configured (exit 3)" >&2; exit 3; }
die()         { warn_closed "$1"; exit 1; }

[[ $# -eq 3 ]] || die "usage: ultimate-dispatch.sh <role-slug> <prompt-file> <output-path>"
ROLE="$1"
PROMPT_FILE="$2"
OUTPUT_FILE="$3"

# Gateway credential gate FIRST (exit 3 = not configured, not an error) — mirrors
# dispatch-gateway-arbiter.sh so an unconfigured environment never produces a triage-worthy
# failure. Same env var names as the arbiter helper (the gateway creds are shared).
BASE_URL="${BLUEPRINT_ARBITER_GATEWAY_BASE_URL:-}"
AUTH_TOKEN="${BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN:-}"
API_KEY="${BLUEPRINT_ARBITER_GATEWAY_API_KEY:-}"
[[ -n "$BASE_URL" ]] || skip "BLUEPRINT_ARBITER_GATEWAY_BASE_URL not set"
[[ -n "$AUTH_TOKEN" || -n "$API_KEY" ]] || skip "no gateway credential set (need AUTH_TOKEN or API_KEY)"

[[ "$PROMPT_FILE" == /* ]] || die "prompt path must be absolute: $PROMPT_FILE"
[[ "$OUTPUT_FILE" == /* ]] || die "output path must be absolute: $OUTPUT_FILE"

# ---------------------------------------------------------------------------
# Arbiter role: delegate to the hardened verdict-JSON helper, adding the tier's
# one-retry / fail-closed contract. That helper owns the credential containment.
# ---------------------------------------------------------------------------
if [[ "$ROLE" == "arbiter" ]]; then
  ARBITER_HELPER="$_PLUGIN_ROOT/skills/blueprint-review/scripts/dispatch-gateway-arbiter.sh"
  [[ -x "$ARBITER_HELPER" || -f "$ARBITER_HELPER" ]] || die "arbiter helper not found: $ARBITER_HELPER"
  rc=0
  bash "$ARBITER_HELPER" "$PROMPT_FILE" "$OUTPUT_FILE" || rc=$?
  if [[ "$rc" -eq 3 ]]; then exit 3; fi          # gateway not configured — propagate
  if [[ "$rc" -eq 0 ]]; then exit 0; fi
  # exit 1 = configured but failed; retry ONCE, then fail closed loudly.
  echo "ultimate-dispatch: arbiter dispatch failed (rc=$rc) — retrying once" >&2
  rc=0
  bash "$ARBITER_HELPER" "$PROMPT_FILE" "$OUTPUT_FILE" || rc=$?
  [[ "$rc" -eq 0 ]] && exit 0
  die "arbiter gateway dispatch failed twice (rc=$rc)"
fi

# ---------------------------------------------------------------------------
# Generic TEXT dispatch (e.g. mythos-witness): capture the model's final response.
# ---------------------------------------------------------------------------
# Defense in depth: enforce the USER-config surface opt-in HERE, not only in the
# calling skill snippet — a caller that skips the SKILL.md gate must still be
# refused. Only known generic roles dispatch; BUSDRIVER_ULTIMATE=0 (global
# force-off) outranks the per-run ULTIMATE_COUNCIL_FORCE escape hatch.
case "$ROLE" in
  mythos-witness)
    # shellcheck source=/dev/null
    source "$_PLUGIN_ROOT/scripts/lib/ultimate-config.sh" 2>/dev/null       || die "cannot load ultimate-config.sh for surface gate"
    [[ "${BUSDRIVER_ULTIMATE:-}" != "0" ]] || skip "BUSDRIVER_ULTIMATE=0 (global force-off)"
    if ! ultimate_surface_enabled council && [[ "${ULTIMATE_COUNCIL_FORCE:-0}" != "1" ]]; then
      skip "ultimate council surface not enabled (user config) and not force-enabled for this run"
    fi
    ;;
  *) die "unknown generic dispatch role: $ROLE (only mythos-witness is supported)" ;;
esac
[[ -f "$PROMPT_FILE" && -r "$PROMPT_FILE" ]] || die "prompt file not found or unreadable: $PROMPT_FILE"
[[ -s "$PROMPT_FILE" ]] || die "prompt file is empty: $PROMPT_FILE"
# Reject shell-significant / control chars in paths spliced into the dispatch (defense in depth,
# matching the arbiter helper's firewall).
for _p in "$PROMPT_FILE" "$OUTPUT_FILE"; do
  case "$_p" in
    *\`*|*\$*|*\\*|*\"*|*\'*) die "path must not contain shell-significant characters: $_p" ;;
  esac
  if printf '%s' "$_p" | LC_ALL=C grep -q '[[:cntrl:]]'; then die "path must not contain control characters"; fi
done

# Containment: the generic dispatch only ever writes into the caller's configured ultimate
# state dir (${BUSDRIVER_STATE_DIR:-.claude}/ultimate) — refuse arbitrary absolute targets so
# a buggy/compromised caller cannot use the helper to overwrite unrelated writable paths.
# The expected dir is created first (the helper owned dir creation before this check existed),
# then both sides are canonicalized and compared exactly — no suffix wildcard.
# Anchor the expected dir to the repo that OWNS the output path (CWD-independent): a caller
# composing an absolute OUTPUT_FILE in one CWD and dispatching the helper from another still
# validates against the same repo-rooted ${BUSDRIVER_STATE_DIR:-.claude}/ultimate. Falls back
# to the helper's CWD when the output path is not inside a git repo.
# Never create the caller-supplied parent before validation — anchor from the nearest
# EXISTING ancestor instead, so a rejected path leaves no directories behind.
_OUTPUT_DIR="$(dirname "$OUTPUT_FILE")"
_EXISTING_ANCESTOR="$_OUTPUT_DIR"
while [[ ! -d "$_EXISTING_ANCESTOR" && "$_EXISTING_ANCESTOR" != "/" ]]; do
  _EXISTING_ANCESTOR="$(dirname "$_EXISTING_ANCESTOR")"
done
_ANCHOR_ROOT="$(git -C "$_EXISTING_ANCESTOR" rev-parse --show-toplevel 2>/dev/null)" || _ANCHOR_ROOT="$PWD"
_EXPECTED_ULTIMATE_DIR="$_ANCHOR_ROOT/${BUSDRIVER_STATE_DIR:-.claude}/ultimate"
mkdir -p "$_EXPECTED_ULTIMATE_DIR" 2>/dev/null || die "cannot create ultimate state dir: $_EXPECTED_ULTIMATE_DIR"
_EXPECTED_ULTIMATE_DIR="$(cd "$_EXPECTED_ULTIMATE_DIR" && pwd -P)" || die "cannot resolve ultimate state dir"
# Only the expected dir was created above; the output parent must already resolve to it.
_OUTPUT_PARENT="$(cd "$_OUTPUT_DIR" 2>/dev/null && pwd -P)" || die "output dir does not exist (only $_EXPECTED_ULTIMATE_DIR is created by this helper): $_OUTPUT_DIR"
[[ "$_OUTPUT_PARENT" == "$_EXPECTED_ULTIMATE_DIR" ]] || die "output file must live directly under $_EXPECTED_ULTIMATE_DIR: $OUTPUT_FILE"

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
command -v "$CLAUDE_BIN" >/dev/null 2>&1 || die "claude binary not found: $CLAUDE_BIN"
# jq preferred; python3 accepted as fallback for the settings-file write below.
JSON_WRITER=""
if command -v jq >/dev/null 2>&1; then JSON_WRITER=jq
elif command -v python3 >/dev/null 2>&1; then JSON_WRITER=python3
else die "jq or python3 is required to write the gateway settings file"; fi

MODEL="${BLUEPRINT_ARBITER_GATEWAY_MODEL:-claude-fable-5}"
TIMEOUT_S="${BLUEPRINT_ARBITER_GATEWAY_TIMEOUT:-600}"

# Strip every credential/routing var from the subprocess environment (the credential arrives
# ONLY via the 0600 --settings file below); set the non-secret base URL. Same scrub set as
# dispatch-gateway-arbiter.sh (kept in sync — the provider list is frozen per CLAUDE.md).
ENV_ARGS=(-u BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN -u BLUEPRINT_ARBITER_GATEWAY_API_KEY
          -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY
          -u ANTHROPIC_CUSTOM_HEADERS
          -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY
          -u CLAUDE_CODE_USE_ANTHROPIC_AWS -u CLAUDE_CODE_USE_MANTLE
          "ANTHROPIC_BASE_URL=$BASE_URL")

# Capability guard (fail-CLOSED): the witness is confined by NOT loading the operator's
# setting sources (--setting-sources '' below); refuse to dispatch on a claude too old for
# the flag rather than run with the operator's permissions merged in.
_help="$(env "${ENV_ARGS[@]}" "$CLAUDE_BIN" --help 2>&1 || true)"
[[ "$_help" == *--setting-sources* ]] \
  || die "claude ($CLAUDE_BIN) does not support --setting-sources; cannot confine the witness — upgrade claude or unset the gateway config"

SETTINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/ultimate-gw-settings.XXXXXX")"
chmod 600 "$SETTINGS_FILE"
trap 'rm -f "${SETTINGS_FILE:-}"' EXIT
if [[ -n "$AUTH_TOKEN" ]]; then
  cred="$AUTH_TOKEN"; cred_var="ANTHROPIC_AUTH_TOKEN"; other_var="ANTHROPIC_API_KEY"
else
  cred="$API_KEY"; cred_var="ANTHROPIC_API_KEY"; other_var="ANTHROPIC_AUTH_TOKEN"
fi
# Credential fed to the JSON writer via STDIN (never argv / never env) so it never lands in
# the writer's argv or environ. Pin the unused credential var + the provider selectors empty
# so a settings.json value cannot reintroduce them (the --settings file outranks the default
# settings file). jq preferred; python3 fallback keeps the shared dispatcher as portable as
# the existing arbiter helper on jq-less machines.
if [[ "$JSON_WRITER" == jq ]]; then
  # -Rs slurps stdin as one raw string (`.`) — portable, unlike --rawfile /dev/stdin
  # which is unreliable when jq's program context also owns stdin under -n.
  printf '%s' "$cred" | jq -Rs --arg url "$BASE_URL" --arg cred_var "$cred_var" --arg other_var "$other_var" '{
    env: ({
      ANTHROPIC_BASE_URL: $url,
      ANTHROPIC_CUSTOM_HEADERS: "",
      CLAUDE_CODE_USE_BEDROCK: "", CLAUDE_CODE_USE_VERTEX: "", CLAUDE_CODE_USE_FOUNDRY: "",
      CLAUDE_CODE_USE_ANTHROPIC_AWS: "", CLAUDE_CODE_USE_MANTLE: ""
    } + { ($cred_var): ., ($other_var): "" })
  }' >"$SETTINGS_FILE" || die "failed to write gateway settings file (jq error)"
else
  # Non-secret values via argv (mirrors jq --arg); ONLY the secret rides stdin.
  printf '%s' "$cred" | python3 -c '
import json, sys
base_url, cred_var, other_var = sys.argv[1:4]
env = {
    "ANTHROPIC_BASE_URL": base_url,
    "ANTHROPIC_CUSTOM_HEADERS": "",
    "CLAUDE_CODE_USE_BEDROCK": "", "CLAUDE_CODE_USE_VERTEX": "", "CLAUDE_CODE_USE_FOUNDRY": "",
    "CLAUDE_CODE_USE_ANTHROPIC_AWS": "", "CLAUDE_CODE_USE_MANTLE": "",
    cred_var: sys.stdin.read(),
    other_var: "",
}
json.dump({"env": env}, sys.stdout)
' "$BASE_URL" "$cred_var" "$other_var" >"$SETTINGS_FILE" || die "failed to write gateway settings file (python3 error)"
fi
[[ -s "$SETTINGS_FILE" ]] || die "gateway settings file is empty after JSON write"

mkdir -p "$(dirname "$OUTPUT_FILE")" 2>/dev/null || die "cannot create output dir for $OUTPUT_FILE"

# One dispatch attempt → prints the model's final response on stdout, captured to OUTPUT_FILE.
# Read-only (no Edit, no Bash); credential via --settings only; operator settings not loaded.
_run_once() {
  local out_tmp rc=0
  out_tmp="$(mktemp "${TMPDIR:-/tmp}/ultimate-out.XXXXXX")"
  # Clean the temp output on ANY function return (incl. signal/timeout edge cases) so
  # council prompts/responses never linger in $TMPDIR; the success path mv's it first.
  # shellcheck disable=SC2064  # expand $out_tmp now — it is function-local
  trap "rm -f '$out_tmp' 2>/dev/null || true" RETURN
  # Prompt via stdin (not argv): council prompts can be large (ARG_MAX) and
  # sensitive (argv is visible in local process listings). No tools granted:
  # the witness only needs the supplied prompt — a prompt-injected witness
  # must not be able to read local files (--tools "" closes that boundary).
  _portable_timeout "$TIMEOUT_S" env "${ENV_ARGS[@]}" "$CLAUDE_BIN" --bare -p \
    --settings "$SETTINGS_FILE" \
    --setting-sources '' \
    --model "$MODEL" \
    --permission-mode dontAsk \
    --tools "" \
    --strict-mcp-config <"$PROMPT_FILE" >"$out_tmp" 2>/dev/null || rc=$?
  if [[ "$rc" -eq 0 && -s "$out_tmp" ]]; then
    # Explicit failure path: _run_once is called inside `if`, which disables set -e —
    # a failed final write must not fall through to a success return.
    mv "$out_tmp" "$OUTPUT_FILE" || { rm -f "$out_tmp"; return 1; }
    return 0
  fi
  rm -f "$out_tmp"
  # A zero exit with empty stdout is NOT success — `${rc:-1}` only substitutes when rc is
  # unset/empty, and rc is the literal string "0" here, so it would return 0 (success) and
  # let the caller print "verdict written" for a file that was never created. Force non-zero
  # so the fail-closed retry/failure contract holds for the empty-but-clean-exit case too.
  if [[ "$rc" -eq 0 ]]; then
    return 1
  fi
  return "$rc"
}

echo "ultimate-dispatch: dispatching '$ROLE' witness (model: $MODEL, timeout: ${TIMEOUT_S}s)" >&2
if _run_once; then
  echo "ultimate-dispatch: '$ROLE' verdict written to $OUTPUT_FILE" >&2
  exit 0
fi
echo "ultimate-dispatch: '$ROLE' dispatch failed — retrying once" >&2
if _run_once; then
  echo "ultimate-dispatch: '$ROLE' verdict written to $OUTPUT_FILE (retry)" >&2
  exit 0
fi
die "'$ROLE' gateway dispatch failed twice — no verdict written"
