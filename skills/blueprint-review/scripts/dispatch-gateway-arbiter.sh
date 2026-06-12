#!/bin/bash
# Gateway-fallback arbiter dispatch (SKILL.md "Gateway-Fallback Rung").
#
# Dispatches the blueprint-review arbiter as a headless `claude -p` subprocess
# routed through an Anthropic-API-compatible gateway (e.g., ZenMux), for the
# case where the `fable` tier is unavailable on the calling session's
# subscription but reachable via gateway API. Agent-tool subagents always
# inherit the parent session's auth/endpoint, so this rung MUST be a separate
# process with per-process environment overrides.
#
# The script enforces the dispatch protocol structurally:
#   - Context firewall: the prompt is the fixed template plus exactly the two
#     paths given as arguments — the caller cannot inject anything else.
#   - Secret handling: credentials are read from the environment here and
#     passed only to the subprocess; the calling session never handles them.
#
# Usage:
#   dispatch-gateway-arbiter.sh <validation-prompt-path> <claude-json-output-path>
#   (run from the project root — the arbiter's Read/Grep/Glob resolve there)
#
# Environment (opt-in — see SKILL.md table):
#   BLUEPRINT_ARBITER_GATEWAY_BASE_URL     gateway endpoint (required to opt in)
#   BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN   bearer-style key   } exactly one is
#   BLUEPRINT_ARBITER_GATEWAY_API_KEY      X-Api-Key-style key } required;
#                                          AUTH_TOKEN wins if both are set
#   BLUEPRINT_ARBITER_GATEWAY_MODEL        gateway model id (default claude-fable-5)
#   BLUEPRINT_ARBITER_GATEWAY_TIMEOUT      seconds before the dispatch is killed
#                                          (default 600)
#   CLAUDE_BIN                             claude binary override (tests)
#
# Exit codes:
#   0  arbiter ran and wrote a structurally valid claude.json
#   3  gateway not configured — skip this rung, fall through to `opus`
#   1  gateway configured but dispatch failed (fail-closed; the caller applies
#      the dispatch protocol's one-retry rule)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Shared lib for _portable_timeout — macOS does not ship GNU timeout.
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
# shellcheck source=../../../scripts/lib/resolve-cli.sh
source "$_PLUGIN_ROOT/scripts/lib/resolve-cli.sh"

skip() { echo "gateway-arbiter: $1 — skipping rung (fall through to opus)" >&2; exit 3; }
die()  { echo "gateway-arbiter: ERROR: $1" >&2; exit 1; }

[[ $# -eq 2 ]] || die "usage: dispatch-gateway-arbiter.sh <validation-prompt-path> <claude-json-output-path>"
PROMPT_FILE="$1"
OUTPUT_FILE="$2"

# Opt-in check FIRST (exit 3 = not configured, not an error) so an
# unconfigured environment never produces a failure the caller must triage —
# all path validation runs after this gate for the same reason.
BASE_URL="${BLUEPRINT_ARBITER_GATEWAY_BASE_URL:-}"
AUTH_TOKEN="${BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN:-}"
API_KEY="${BLUEPRINT_ARBITER_GATEWAY_API_KEY:-}"
[[ -n "$BASE_URL" ]] || skip "BLUEPRINT_ARBITER_GATEWAY_BASE_URL not set"
[[ -n "$AUTH_TOKEN" || -n "$API_KEY" ]] || skip "no gateway credential set (need AUTH_TOKEN or API_KEY)"

[[ "$PROMPT_FILE" == /* ]] || die "validation prompt path must be absolute: $PROMPT_FILE"
[[ "$OUTPUT_FILE" == /* ]] || die "claude.json output path must be absolute: $OUTPUT_FILE"
# Both paths are spliced verbatim into the fixed dispatch template below, so
# reject characters that could smuggle extra instructions past the
# two-paths-only firewall (backticks, newlines, any other control chars).
# $ and \ are also rejected as defense-in-depth: expansion text in a variable's
# VALUE is never shell-re-evaluated (bash does not re-parse expansion results,
# and the prompt reaches claude as a single execve argument), but the
# characters have no legitimate place in these paths and excluding them keeps
# the firewall auditable without reasoning about shell semantics.
for _path in "$PROMPT_FILE" "$OUTPUT_FILE"; do
  case "$_path" in
    *\`*|*\$*|*\\*) die "path must not contain shell-significant characters (backtick, \$, backslash): $_path" ;;
  esac
  if printf '%s' "$_path" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    die "path must not contain control characters"
  fi
done

[[ -f "$PROMPT_FILE" && -r "$PROMPT_FILE" ]] || die "validation prompt not found or unreadable: $PROMPT_FILE"
[[ -s "$PROMPT_FILE" ]] || die "validation prompt is empty: $PROMPT_FILE"

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
command -v "$CLAUDE_BIN" >/dev/null 2>&1 || die "claude binary not found: $CLAUDE_BIN"
command -v jq >/dev/null 2>&1 || die "jq is required for verdict post-check"

MODEL="${BLUEPRINT_ARBITER_GATEWAY_MODEL:-claude-fable-5}"
TIMEOUT_S="${BLUEPRINT_ARBITER_GATEWAY_TIMEOUT:-600}"

# Fixed dispatch template (SKILL.md Arbiter Dispatch Protocol step 1) — two
# absolute paths substituted, nothing more. Building it here, from the two
# arguments only, is what makes the context firewall structural for this rung.
DISPATCH_PROMPT=$(printf '%s\n' \
  "You are the design-review arbiter. Read the validation prompt at" \
  "\`${PROMPT_FILE}\` and follow it exactly." \
  "Use Read/Grep/Glob to verify every claim against the codebase." \
  "Write your strict-JSON verdict to \`${OUTPUT_FILE}\`." \
  "Report the model you are running as in the verdict's validation_notes" \
  "using the canonical field: \"executed_model\": \"<model-name>\" (e.g.," \
  "\"executed_model\": \"fable\")." \
  "Return a one-paragraph summary: status, plus issue counts by severity.")

# Per-process credential override. Exactly one credential variable reaches the
# subprocess: the unused one is explicitly UNSET (env -u) so a credential
# exported in the parent shell cannot win Claude Code's auth precedence and
# silently pair the wrong key with the gateway endpoint.
# NB: env(1) requires -u options BEFORE the NAME=VALUE assignments.
# The BLUEPRINT_ARBITER_GATEWAY_* secrets are also unset: without this the
# subprocess inherits them alongside the ANTHROPIC_* override, so the LOSING
# credential (and the winner, in its source-variable form) would sit in the
# arbiter's environment. The subprocess must see exactly one credential, in
# its ANTHROPIC_* form only.
ENV_ARGS=(-u BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN -u BLUEPRINT_ARBITER_GATEWAY_API_KEY)
if [[ -n "$AUTH_TOKEN" ]]; then
  ENV_ARGS+=(-u ANTHROPIC_API_KEY "ANTHROPIC_BASE_URL=$BASE_URL" "ANTHROPIC_AUTH_TOKEN=$AUTH_TOKEN")
else
  ENV_ARGS+=(-u ANTHROPIC_AUTH_TOKEN "ANTHROPIC_BASE_URL=$BASE_URL" "ANTHROPIC_API_KEY=$API_KEY")
fi

echo "gateway-arbiter: dispatching headless arbiter (model: $MODEL, timeout: ${TIMEOUT_S}s)" >&2
# --bare skips auto-discovery of hooks, skills, plugins, MCP servers, auto
# memory, and CLAUDE.md — the arbiter sees ONLY the fixed prompt plus the
# codebase (no author-side CLAUDE.md context, and busdriver's own PreToolUse
# gates can't fire inside the subprocess). It also skips OAuth/keychain
# reads, so auth comes solely from the gateway env overrides above.
# --tools RESTRICTS the tool set (the firewall); --allowedTools only
# pre-approves, so without --tools a permissive user/project permission
# config would let the arbiter reach Bash/Edit. --strict-mcp-config keeps
# MCP servers from loading even if a future flag change re-enables discovery.
DISPATCH_RC=0
_portable_timeout "$TIMEOUT_S" env "${ENV_ARGS[@]}" "$CLAUDE_BIN" --bare -p "$DISPATCH_PROMPT" \
  --model "$MODEL" \
  --tools Read,Grep,Glob,Write \
  --allowedTools Read,Grep,Glob,Write \
  --strict-mcp-config \
  || DISPATCH_RC=$?
if [[ "$DISPATCH_RC" -ne 0 ]]; then
  rm -f "$OUTPUT_FILE"
  die "headless dispatch failed (exit $DISPATCH_RC)"
fi

# Structural post-check (SKILL.md step 3, cheap half): exists, parses, status
# is PASS/FAIL, run_id present. The loop's --claude-only pass re-validates the
# freshness contract fully; this just avoids burning a loop invocation on a
# garbage file. A bad file is deleted so the caller's one-retry starts clean.
post_fail() { rm -f "$OUTPUT_FILE"; die "verdict post-check failed: $1 (bad claude.json deleted)"; }

[[ -s "$OUTPUT_FILE" ]] || post_fail "arbiter wrote no output to $OUTPUT_FILE"
jq empty "$OUTPUT_FILE" 2>/dev/null || post_fail "output is not valid JSON"
STATUS=$(jq -r '.status // ""' "$OUTPUT_FILE")
[[ "$STATUS" == "PASS" || "$STATUS" == "FAIL" ]] || post_fail "status is '${STATUS:-<missing>}', expected PASS or FAIL"
RUN_ID=$(jq -r '.metadata.run_id // ""' "$OUTPUT_FILE")
[[ -n "$RUN_ID" ]] || post_fail "metadata.run_id missing (freshness contract)"

echo "gateway-arbiter: verdict written ($STATUS, run_id $RUN_ID) — record model_pin_status=gateway_fable_fallback" >&2
exit 0
