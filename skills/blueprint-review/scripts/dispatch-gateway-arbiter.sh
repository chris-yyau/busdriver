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
#   (run from the project root — the arbiter's Read resolves relative paths there)
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
    *\`*|*\$*|*\\*|*\"*|*\'*) die "path must not contain shell-significant characters (backtick, \$, backslash, quotes): $_path" ;;
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
  "Use Read to open the files the reviews cite and verify every claim against the codebase." \
  "Write your strict-JSON verdict to \`${OUTPUT_FILE}\`." \
  "Report the model you are running as in the verdict's validation_notes" \
  "using the canonical field: \"executed_model\": \"<model-name>\" (e.g.," \
  "\"executed_model\": \"fable\")." \
  "Return a one-paragraph summary: status, plus issue counts by severity.")

# Environment for the subprocess. The gateway credential is delivered ONLY
# through the --settings file built below — NEVER through the environment — so
# that /proc/self/environ holds no token for a prompt-injected, Read-capable
# arbiter to recover. Here we only STRIP every credential/routing variable that
# could leak in or mis-route the dispatch, and set the (non-secret) base URL:
#   - ANTHROPIC_AUTH_TOKEN / ANTHROPIC_API_KEY: BOTH unset. A value exported in
#     the parent shell would otherwise win Claude Code's auth precedence and pair
#     the wrong key with the gateway endpoint; the real gateway credential
#     arrives via --settings (which outranks even a settings-file value — below).
#   - BLUEPRINT_ARBITER_GATEWAY_*: unset so the source secrets do not sit in the
#     arbiter's environment alongside the dispatch.
#   - ANTHROPIC_CUSTOM_HEADERS: a parent shell may set it for a DIFFERENT proxy;
#     inherited headers would ride along into every gateway request, leaking
#     unrelated header secrets/routing metadata.
#   - CLAUDE_CODE_USE_{BEDROCK,VERTEX,FOUNDRY,AWS,MANTLE}: cloud-provider routing
#     outranks ANTHROPIC_* in Claude Code's auth precedence; an inherited selector
#     would route the arbiter to the parent's provider and ignore the gateway
#     entirely. (MANTLE is the Bedrock Mantle backend selector, undocumented as of
#     2026-06 — claude-code#44899; env -u of an unset variable is harmless.)
# NB: env(1) requires -u options BEFORE the NAME=VALUE assignment.
ENV_ARGS=(-u BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN -u BLUEPRINT_ARBITER_GATEWAY_API_KEY
          -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY
          -u ANTHROPIC_CUSTOM_HEADERS
          -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY
          -u CLAUDE_CODE_USE_AWS -u CLAUDE_CODE_USE_MANTLE
          "ANTHROPIC_BASE_URL=$BASE_URL")

# Force the gateway endpoint AND the gateway credential to win over the
# operator's own settings file. Claude Code applies a settings file's `env` block
# OVER the inherited process environment, so the per-process overrides above are
# clobbered for any operator whose ~/.claude/settings.json sets the same vars:
#   - env.ANTHROPIC_BASE_URL (a local proxy — the common case for this rung's
#     audience) would silently redirect the arbiter off the gateway; and, worse,
#   - env.ANTHROPIC_AUTH_TOKEN / env.ANTHROPIC_API_KEY would pair the operator's
#     OWN secret with the forced gateway URL and ship it to the third-party
#     gateway (auth failure at best, credential disclosure at worst).
# A CLI --settings value outranks the default settings file, so we route the
# endpoint AND the one gateway credential through it, pinning the unused
# credential var to empty so a settings.json value cannot reintroduce it. The
# same file ALSO pins ANTHROPIC_CUSTOM_HEADERS and the CLAUDE_CODE_USE_* provider
# selectors to empty: ENV_ARGS strips those from the INHERITED environment, but a
# settings.json `env` value would outrank that strip and could re-introduce proxy
# headers (leaked to the gateway) or provider routing (sending the arbiter away
# from the gateway entirely). Pinning them empty in the higher-precedence
# --settings file neutralizes any settings.json value.
# The file carries a secret, so: a private temp file (mode 0600), passed as
# --settings <path> (NOT inline) so no secret ever reaches the process argument
# list, removed on exit. Built with jq (a hard dep, checked above) for escaping.
# The credential value is bound with --arg (jq escapes it); the routing/header
# selectors are pinned to constant empty strings. $cred carries the chosen
# credential; $which names which ANTHROPIC_* key it fills.
SETTINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/bp-gw-settings.XXXXXX")"
chmod 600 "$SETTINGS_FILE"
trap 'rm -f "${SETTINGS_FILE:-}"' EXIT
if [[ -n "$AUTH_TOKEN" ]]; then
  cred="$AUTH_TOKEN"; which="ANTHROPIC_AUTH_TOKEN"; other="ANTHROPIC_API_KEY"
else
  cred="$API_KEY"; which="ANTHROPIC_API_KEY"; other="ANTHROPIC_AUTH_TOKEN"
fi
jq -n --arg url "$BASE_URL" --arg cred "$cred" --arg which "$which" --arg other "$other" '{
  env: ({
    ANTHROPIC_BASE_URL: $url,
    ANTHROPIC_CUSTOM_HEADERS: "",
    CLAUDE_CODE_USE_BEDROCK: "", CLAUDE_CODE_USE_VERTEX: "", CLAUDE_CODE_USE_FOUNDRY: "",
    CLAUDE_CODE_USE_AWS: "", CLAUDE_CODE_USE_MANTLE: ""
  } + { ($which): $cred, ($other): "" })
}' >"$SETTINGS_FILE"

echo "gateway-arbiter: dispatching headless arbiter (model: $MODEL, timeout: ${TIMEOUT_S}s)" >&2
# --bare skips auto-discovery of hooks, skills, plugins, MCP servers, auto
# memory, and CLAUDE.md — the arbiter sees ONLY the fixed prompt plus the
# codebase (no author-side CLAUDE.md context, and busdriver's own PreToolUse
# gates can't fire inside the subprocess). It also skips OAuth/keychain
# reads, so auth comes solely from the gateway --settings file above.
# --tools RESTRICTS the tool set (the firewall); --allowedTools only
# pre-approves, so without --tools a permissive user/project permission
# config would let the arbiter reach other tools. --strict-mcp-config keeps
# MCP servers from loading even if a future flag change re-enables discovery.
# Tool names: under --bare the built-in selectable set is {Bash, Edit, Read};
# Grep/Glob/Write are NOT selectable there (passing them silently collapses the
# set to Read alone). Grant ONLY Read (inspect the files the reviews cite) and
# Edit (write claude.json; Edit creates the file when absent) — no shell.
#
# Credential containment vs. a prompt-injected arbiter (it reads reviewer-authored
# content, so treat it as hostile). Defence in depth, all deterministic:
#   1. No shell — Bash withheld, so no env/printenv.
#   2. No env token — the credential is NOT in the subprocess environment (see
#      ENV_ARGS above); it arrives only via the --settings file. So a Read of
#      /proc/self/environ exposes nothing.
#   3. Read confined — --disallowedTools blocks the residual Read vectors:
#      (a) /proc, /sys, /dev (so the arbiter cannot Read /proc/self/environ, nor
#      /proc/self/cmdline to learn the random --settings path), plus the settings
#      file path itself. /proc is a fixed kernel mount with no symlink
#      alternate-spelling, so unlike a userspace path glob this deny is not
#      trivially bypassable.
#      (b) the operator's OWN Anthropic credential stores: $HOME/.claude/**
#      (settings.json / settings.local.json carry an `env` block that may hold
#      ANTHROPIC_AUTH_TOKEN/_API_KEY), $HOME/.claude.json (the global state file
#      holding the subscription/API credential), and the project's .claude/**
#      (settings.local.json). Without these the gateway-credential containment is
#      hollow: a prompt-injected arbiter could Read the operator's own Anthropic
#      secret — which these very docs name as a possible settings.json value — and
#      exfiltrate it through the transcript or claude.json, even though the gateway
#      secret never leaves the --settings file. These paths are NOT where the loop
#      puts the arbiter's prompt/verdict (those live under docs/reviews/<slug>/),
#      so the deny costs the arbiter nothing it needs.
# Net: no shell, no env token, no way to discover the settings path, settings file
# + Anthropic credential stores denied — Read+Edit give the arbiter no route to the
# gateway secret OR the operator's own credential. Read remains a blocklist, not an
# allowlist: arbitrary non-credential reads (like every Read-granted subagent) stay
# in scope of the model's judgement, out of scope for this credential hardening. The
# cost is no free-form codebase search (Grep/Glob unavailable under --bare), so
# validation is by reading the cited files, like the non-gateway arbiter.
# The deny rules use the //<abs-path> form (the leading-// form is what Claude
# Code's matcher honours for absolute-path rules).
DISALLOW_ARGS=(--disallowedTools 'Read(//proc/**)'
               --disallowedTools 'Read(//sys/**)'
               --disallowedTools 'Read(//dev/**)'
               --disallowedTools "Read(//${SETTINGS_FILE#/})"
               --disallowedTools "Read(//${HOME#/}/.claude/**)"
               --disallowedTools "Read(//${HOME#/}/.claude.json)"
               --disallowedTools "Read(//${PWD#/}/.claude/**)")
DISPATCH_RC=0
_portable_timeout "$TIMEOUT_S" env "${ENV_ARGS[@]}" "$CLAUDE_BIN" --bare -p "$DISPATCH_PROMPT" \
  --settings "$SETTINGS_FILE" \
  --model "$MODEL" \
  --tools Read,Edit \
  --allowedTools Read,Edit \
  "${DISALLOW_ARGS[@]}" \
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
