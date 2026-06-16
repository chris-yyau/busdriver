#!/usr/bin/env bash
# Tests for the gateway-fallback arbiter dispatch script
# (skills/blueprint-review/scripts/dispatch-gateway-arbiter.sh — SKILL.md
# "Gateway-Fallback Rung").
#
# The script must: skip cleanly (exit 3) when the gateway is unconfigured,
# pass exactly one credential to the subprocess (unsetting the other so a
# parent-shell export can't win auth precedence), build the fixed dispatch
# template from its two arguments only, honor the model override, and
# fail-closed (exit 1, bad file deleted) on garbage verdicts.
#
# Uses a stub `claude` binary via CLAUDE_BIN — no network, no real dispatch.
#
# Usage: bash tests/test-gateway-arbiter-dispatch.sh
# Exit: 0 if all pass, 1 if any fail.

set -euo pipefail
cd "$(dirname "$0")/.."

PASS=0
FAIL=0
TOTAL=0

SCRIPT="skills/blueprint-review/scripts/dispatch-gateway-arbiter.sh"

TMPDIR_T=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T"' EXIT

PROMPT_FILE="$TMPDIR_T/claude-validation-prompt.txt"
OUTPUT_FILE="$TMPDIR_T/claude.json"
STUB_LOG="$TMPDIR_T/stub-invocation.log"
echo "validation prompt body" > "$PROMPT_FILE"

# Stub claude binary: records parsed args + the auth env it sees (prompt goes
# to its own file — it is multi-line), then writes a verdict per
# STUB_BEHAVIOR (good | badjson | badstatus | silent).
STUB_BIN="$TMPDIR_T/claude-stub"
cat > "$STUB_BIN" <<'EOF'
#!/bin/bash
# Capability-probe mode: the dispatcher runs `claude --help` to confirm
# --setting-sources support before dispatching. Advertise the flag and exit
# without writing a log (a probe is not a dispatch).
for _a in "$@"; do
  if [[ "$_a" == "--help" ]]; then
    # Record the env this probe was invoked with so the harness can assert the
    # capability probe ran under `env "${ENV_ARGS[@]}"` scrubbing — i.e. it never
    # receives the gateway/Anthropic secrets (issue #198 review). Overwrite (not
    # append); only this --help path writes it, and run_script resets it per run,
    # so the dispatch invocation in the same run cannot clobber the probe record.
    {
      echo "PROBE_AUTH_TOKEN: ${ANTHROPIC_AUTH_TOKEN:-}"
      echo "PROBE_API_KEY: ${ANTHROPIC_API_KEY:-}"
      echo "PROBE_GW_AUTH_TOKEN: ${BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN:-}"
      echo "PROBE_GW_API_KEY: ${BLUEPRINT_ARBITER_GATEWAY_API_KEY:-}"
    } > "${STUB_PROBE_LOG:-/dev/null}"
    printf '%s\n' '  --setting-sources <sources>  Comma-separated list of setting sources to load (user, project, local).'
    printf '%s\n' '  --settings <file-or-json>'
    exit 0
  fi
done
prompt="" model="" tools_restrict="" tools_approve="" strict_mcp=0 bare=0 settings="" disallowed="" perm_mode="" ss_present=no ss_value="__UNSET__"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) prompt="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    --settings) settings="$2"; shift 2 ;;
    --tools) tools_restrict="$2"; shift 2 ;;
    --allowedTools) tools_approve="$2"; shift 2 ;;
    --disallowedTools) disallowed="$disallowed $2"; shift 2 ;;
    --permission-mode) perm_mode="$2"; shift 2 ;;
    --setting-sources) ss_present=yes; ss_value="$2"; shift 2 ;;
    --strict-mcp-config) strict_mcp=1; shift ;;
    --bare) bare=1; shift ;;
    *) shift ;;
  esac
done
{
  echo "MODEL: $model"
  echo "SETTINGS: $settings"
  if [[ -n "$settings" && -f "$settings" ]]; then
    s_mode="$(stat -c '%a' "$settings" 2>/dev/null || stat -f '%Lp' "$settings" 2>/dev/null)"
    s_base="$(jq -r '.env.ANTHROPIC_BASE_URL // empty' "$settings" 2>/dev/null)"
    s_auth="$(jq -r '.env.ANTHROPIC_AUTH_TOKEN // empty' "$settings" 2>/dev/null)"
    s_key="$(jq -r '.env.ANTHROPIC_API_KEY // empty' "$settings" 2>/dev/null)"
    echo "SETTINGS_IS_FILE: yes"
    echo "SETTINGS_MODE: $s_mode"
    echo "SETTINGS_BASE: $s_base"
    echo "SETTINGS_AUTH_PRESENT: $([ -n "$s_auth" ] && echo yes || echo no)"
    echo "SETTINGS_APIKEY_PRESENT: $([ -n "$s_key" ] && echo yes || echo no)"
    echo "SETTINGS_NEUTRALIZED: $(jq -r '[.env.ANTHROPIC_CUSTOM_HEADERS, .env.CLAUDE_CODE_USE_BEDROCK, .env.CLAUDE_CODE_USE_VERTEX, .env.CLAUDE_CODE_USE_FOUNDRY, .env.CLAUDE_CODE_USE_AWS, .env.CLAUDE_CODE_USE_MANTLE] | all(. == "")' "$settings" 2>/dev/null)"
  else
    echo "SETTINGS_IS_FILE: no"
  fi
  echo "TOOLS_RESTRICT: $tools_restrict"
  echo "TOOLS_APPROVE: $tools_approve"
  echo "DISALLOWED:$disallowed"
  echo "STRICT_MCP: $strict_mcp"
  echo "BARE: $bare"
  echo "PERM_MODE: $perm_mode"
  echo "SETTING_SOURCES_PRESENT: $ss_present"
  echo "SETTING_SOURCES_VALUE: $ss_value"
  echo "OUT_PREEXISTING: $([ -s "${STUB_OUT:-/nonexistent}" ] && echo yes || echo no)"
  echo "BASE_URL: ${ANTHROPIC_BASE_URL:-}"
  echo "AUTH_TOKEN: ${ANTHROPIC_AUTH_TOKEN:-}"
  echo "API_KEY: ${ANTHROPIC_API_KEY:-}"
  echo "GW_AUTH_TOKEN: ${BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN:-}"
  echo "GW_API_KEY: ${BLUEPRINT_ARBITER_GATEWAY_API_KEY:-}"
  echo "CUSTOM_HEADERS: ${ANTHROPIC_CUSTOM_HEADERS:-}"
  echo "USE_BEDROCK: ${CLAUDE_CODE_USE_BEDROCK:-}"
  echo "USE_MANTLE: ${CLAUDE_CODE_USE_MANTLE:-}"
} > "$STUB_LOG"
printf '%s' "$prompt" > "$STUB_PROMPT"
case "${STUB_BEHAVIOR:-good}" in
  good)
    printf '{"status":"PASS","reviewer_id":"claude","issues":[],"metadata":{"run_id":"r1","spec_hash":"h1"},"validation_notes":"executed_model: fable"}\n' > "$STUB_OUT"
    ;;
  badjson)   echo '{ not json' > "$STUB_OUT" ;;
  badstatus) printf '{"status":"MAYBE","metadata":{"run_id":"r1"}}\n' > "$STUB_OUT" ;;
  silent)    : ;;
esac
EOF
chmod +x "$STUB_BIN"

# Stub for an OLDER claude whose --help does NOT advertise --setting-sources.
# If the dispatcher's capability guard were missing, this stub would still write
# a valid verdict on dispatch (exit 0) — so the fail-closed test below catches a
# fail-OPEN (running the arbiter unconfined on a binary that can't honor scope
# isolation), not just a crash.
STUB_BIN_OLD="$TMPDIR_T/claude-stub-old"
cat > "$STUB_BIN_OLD" <<'EOF'
#!/bin/bash
for _a in "$@"; do
  if [[ "$_a" == "--help" ]]; then
    printf '%s\n' '  --settings <file-or-json>   (older build; per-scope source selection unsupported)'
    exit 0
  fi
done
# Reached only if the guard failed to stop the dispatch — emit a passing verdict
# so the test observes the (wrong) success.
printf '{"status":"PASS","metadata":{"run_id":"r1"}}\n' > "${STUB_OUT:-/dev/null}"
EOF
chmod +x "$STUB_BIN_OLD"

export STUB_LOG
export STUB_OUT="$OUTPUT_FILE"
export STUB_PROMPT="$TMPDIR_T/stub-prompt.txt"
# Records the environment the capability probe (`claude --help`) was invoked
# with, so the harness can assert the probe ran under env-scrubbing (issue #198
# review: prove the probe never receives the gateway/Anthropic secrets).
export STUB_PROBE_LOG="$TMPDIR_T/stub-probe.log"

run_script() {
  # $1 = extra env assignments (string, eval-ed), rest handled via globals.
  # Echoes the exit code; never aborts the harness.
  local extra_env="$1" rc=0
  rm -f "$OUTPUT_FILE" "$STUB_LOG" "$STUB_PROBE_LOG"
  env -i PATH="$PATH" HOME="$HOME" \
    STUB_LOG="$STUB_LOG" STUB_OUT="$STUB_OUT" STUB_PROMPT="$STUB_PROMPT" \
    STUB_PROBE_LOG="$STUB_PROBE_LOG" \
    STUB_BEHAVIOR="${STUB_BEHAVIOR:-good}" \
    CLAUDE_BIN="$STUB_BIN" \
    $extra_env \
    bash "$SCRIPT" "$PROMPT_FILE" "$OUTPUT_FILE" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}

check() {
  # $1 = description, $2 = expected, $3 = got
  local desc="$1" expected="$2" got="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$got" == "$expected" ]]; then
    printf "  PASS  %s\n" "$desc"
    PASS=$((PASS + 1))
  else
    printf "  FAIL  %s (expected '%s', got '%s')\n" "$desc" "$expected" "$got"
    FAIL=$((FAIL + 1))
  fi
}

GATEWAY="BLUEPRINT_ARBITER_GATEWAY_BASE_URL=https://gateway.example/v1"

echo "── opt-in gating (exit 3 = skip rung, never an error) ────────"

rc=$(run_script "")
check "no gateway env at all skips with exit 3" 3 "$rc"
check "stub not invoked when unconfigured" "absent" "$([[ -f "$STUB_LOG" ]] && echo present || echo absent)"

rc=$(run_script "$GATEWAY")
check "base URL without any credential skips with exit 3" 3 "$rc"

rc=$(run_script "BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN=tok-secret-123")
check "credential without base URL skips with exit 3" 3 "$rc"

rc=0
env -i PATH="$PATH" CLAUDE_BIN="$STUB_BIN" \
  bash "$SCRIPT" "$TMPDIR_T/evil\`whoami\`.txt" "$OUTPUT_FILE" >/dev/null 2>&1 || rc=$?
check "unconfigured env skips with exit 3 even for a bad path (opt-in gate runs first)" 3 "$rc"

echo ""
echo "── credential isolation ──────────────────────────────────────"

rc=$(run_script "$GATEWAY BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN=tok-secret-123")
check "AUTH_TOKEN dispatch succeeds" 0 "$rc"
check "subprocess sees gateway base URL (env, non-secret)" "yes" "$(grep -q 'BASE_URL: https://gateway.example/v1' "$STUB_LOG" && echo yes || echo no)"
check "credential NOT in subprocess env — AUTH_TOKEN empty (delivered via settings file; /proc/self/environ safe)" "yes" "$(grep -q '^AUTH_TOKEN: $' "$STUB_LOG" && echo yes || echo no)"
check "credential NOT in subprocess env — API_KEY empty" "yes" "$(grep -q '^API_KEY: $' "$STUB_LOG" && echo yes || echo no)"
check "settings file carries the gateway AUTH_TOKEN (authoritative auth source)" "yes" "$(grep -q '^SETTINGS_AUTH_PRESENT: yes$' "$STUB_LOG" && echo yes || echo no)"

rc=$(run_script "$GATEWAY BLUEPRINT_ARBITER_GATEWAY_API_KEY=key-secret-456 ANTHROPIC_AUTH_TOKEN=parent-shell-token ANTHROPIC_CUSTOM_HEADERS=x-other-proxy-secret:abc CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_USE_MANTLE=1")
check "API_KEY dispatch succeeds" 0 "$rc"
check "API_KEY credential NOT in subprocess env (delivered via settings file)" "yes" "$(grep -q '^API_KEY: $' "$STUB_LOG" && echo yes || echo no)"
check "settings file carries the gateway API_KEY" "yes" "$(grep -q '^SETTINGS_APIKEY_PRESENT: yes$' "$STUB_LOG" && echo yes || echo no)"
check "parent-shell ANTHROPIC_AUTH_TOKEN is unset for subprocess (env -u)" "yes" "$(grep -q '^AUTH_TOKEN: $' "$STUB_LOG" && echo yes || echo no)"
check "parent-shell ANTHROPIC_CUSTOM_HEADERS is unset for subprocess" "yes" "$(grep -q '^CUSTOM_HEADERS: $' "$STUB_LOG" && echo yes || echo no)"
check "parent-shell CLAUDE_CODE_USE_BEDROCK is unset for subprocess (provider routing)" "yes" "$(grep -q '^USE_BEDROCK: $' "$STUB_LOG" && echo yes || echo no)"
check "parent-shell CLAUDE_CODE_USE_MANTLE is unset for subprocess (provider routing)" "yes" "$(grep -q '^USE_MANTLE: $' "$STUB_LOG" && echo yes || echo no)"

rc=$(run_script "$GATEWAY BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN=tok-secret-123 BLUEPRINT_ARBITER_GATEWAY_API_KEY=key-secret-456")
check "both gateway creds set: settings file uses AUTH_TOKEN (preferred)" "yes" "$(grep -q '^SETTINGS_AUTH_PRESENT: yes$' "$STUB_LOG" && echo yes || echo no)"
check "both gateway creds set: settings file API_KEY pinned empty (AUTH_TOKEN wins)" "no" "$(grep -q '^SETTINGS_APIKEY_PRESENT: yes$' "$STUB_LOG" && echo yes || echo no)"
check "neither credential in subprocess env — AUTH_TOKEN empty" "yes" "$(grep -q '^AUTH_TOKEN: $' "$STUB_LOG" && echo yes || echo no)"
check "neither credential in subprocess env — API_KEY empty" "yes" "$(grep -q '^API_KEY: $' "$STUB_LOG" && echo yes || echo no)"
check "BLUEPRINT_* source secrets stripped from subprocess (no source secret inherited)" "yes" "$(grep -q '^GW_AUTH_TOKEN: $' "$STUB_LOG" && grep -q '^GW_API_KEY: $' "$STUB_LOG" && echo yes || echo no)"

echo ""
echo "── dispatch shape (fixed template, model, tools) ─────────────"

rc=$(run_script "$GATEWAY BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN=tok-secret-123")
check "default model is claude-fable-5" "yes" "$(grep -q '^MODEL: claude-fable-5$' "$STUB_LOG" && echo yes || echo no)"
check "tool set restricted to Read,Edit (no shell — credential-exfil guard)" "yes" "$(grep -q '^TOOLS_RESTRICT: Read,Edit$' "$STUB_LOG" && echo yes || echo no)"
check "Edit pre-approved ONLY for the verdict file path (no workspace-wide Edit)" "yes" "$(grep -qF "TOOLS_APPROVE: Read,Edit(//${OUTPUT_FILE#/})" "$STUB_LOG" && echo yes || echo no)"
check "bare workspace-wide Edit NOT pre-approved (scope replaces 'Read,Edit')" "no" "$(grep -q '^TOOLS_APPROVE: Read,Edit$' "$STUB_LOG" && echo yes || echo no)"
check "operator setting sources NOT loaded (--setting-sources passed — neutralizes inherited permissions.allow Edit, issue #198)" "yes" "$(grep -q '^SETTING_SOURCES_PRESENT: yes$' "$STUB_LOG" && echo yes || echo no)"
check "--setting-sources value is empty (loads none of user/project/local — no inherited allow rule can widen Edit scope)" "yes" "$(grep -q '^SETTING_SOURCES_VALUE: $' "$STUB_LOG" && echo yes || echo no)"
check "capability probe was invoked (probe env recorded — guard actually ran claude --help)" "yes" "$([ -s "$STUB_PROBE_LOG" ] && echo yes || echo no)"
check "capability probe ran env-scrubbed (gateway secret NOT visible to claude --help — regression guard for dropping env \${ENV_ARGS[@]})" "no" "$(grep -q 'tok-secret-123' "$STUB_PROBE_LOG" 2>/dev/null && echo yes || echo no)"
check "no shell tool granted (no Bash → no env/printenv exfil path)" "no" "$(grep -qE '^TOOLS_(RESTRICT|APPROVE): .*Bash' "$STUB_LOG" && echo yes || echo no)"
check "Read denied for /proc (blocks /proc/self/environ and cmdline path-discovery)" "yes" "$(grep '^DISALLOWED:' "$STUB_LOG" | grep -qF 'Read(//proc/**)' && echo yes || echo no)"
check "Read denied for /sys" "yes" "$(grep '^DISALLOWED:' "$STUB_LOG" | grep -qF 'Read(//sys/**)' && echo yes || echo no)"
check "Read denied for /dev" "yes" "$(grep '^DISALLOWED:' "$STUB_LOG" | grep -qF 'Read(//dev/**)' && echo yes || echo no)"
check "Read denied for the settings file path itself (defense in depth)" "yes" "$(grep '^DISALLOWED:' "$STUB_LOG" | grep -qF 'bp-gw-settings' && echo yes || echo no)"
check "Read denied for operator's global Claude config dir ~/.claude (settings.json credential store)" "yes" "$(grep '^DISALLOWED:' "$STUB_LOG" | grep -qF "Read(//${HOME#/}/.claude/**)" && echo yes || echo no)"
check "Read denied for operator's global Claude state file ~/.claude.json (holds API/OAuth credential)" "yes" "$(grep '^DISALLOWED:' "$STUB_LOG" | grep -qF "Read(//${HOME#/}/.claude.json)" && echo yes || echo no)"
check "Read denied for project-local .claude (settings.local.json credential store)" "yes" "$(grep '^DISALLOWED:' "$STUB_LOG" | grep -qF "Read(//${PWD#/}/.claude/**)" && echo yes || echo no)"
check "deny-by-default permission mode forced (--permission-mode dontAsk — allowlist authoritative over operator defaultMode)" "yes" "$(grep -q '^PERM_MODE: dontAsk$' "$STUB_LOG" && echo yes || echo no)"
check "MCP servers disabled (--strict-mcp-config)" "yes" "$(grep -q '^STRICT_MCP: 1$' "$STUB_LOG" && echo yes || echo no)"
check "auto-discovery and OAuth/keychain skipped (--bare)" "yes" "$(grep -q '^BARE: 1$' "$STUB_LOG" && echo yes || echo no)"
check "settings passed as a file path (not inline secret-bearing JSON)" "yes" "$(grep -q '^SETTINGS_IS_FILE: yes$' "$STUB_LOG" && echo yes || echo no)"
check "settings file is private (mode 0600)" "600" "$(sed -n 's/^SETTINGS_MODE: //p' "$STUB_LOG")"
SETTINGS_PATH_LOGGED=$(sed -n 's/^SETTINGS: //p' "$STUB_LOG" | head -1)
check "settings file path recorded by stub (sanity)" "yes" "$([ -n "$SETTINGS_PATH_LOGGED" ] && echo yes || echo no)"
check "temp settings file removed after dispatch (trap cleanup — 0600 secret not left on disk)" "yes" "$([ -n "$SETTINGS_PATH_LOGGED" ] && [ ! -e "$SETTINGS_PATH_LOGGED" ] && echo yes || echo no)"
check "gateway base URL forced via settings file (beats operator's default settings.json)" "https://gateway.example/v1" "$(sed -n 's/^SETTINGS_BASE: //p' "$STUB_LOG")"
check "gateway credential carried in settings file (authoritative over a settings.json credential)" "yes" "$(grep -q '^SETTINGS_AUTH_PRESENT: yes$' "$STUB_LOG" && echo yes || echo no)"
check "unused credential var pinned empty in settings file (no settings.json bleed-through)" "no" "$(grep -q '^SETTINGS_APIKEY_PRESENT: yes$' "$STUB_LOG" && echo yes || echo no)"
check "settings file pins proxy headers + provider routing empty (settings.json cannot re-inject)" "true" "$(sed -n 's/^SETTINGS_NEUTRALIZED: //p' "$STUB_LOG")"
check "gateway secret never reaches argv (the --settings value is a path, not the token)" "no" "$(grep '^SETTINGS: ' "$STUB_LOG" | grep -q 'tok-secret-123' && echo yes || echo no)"
check "prompt contains the validation-prompt path" "yes" "$(grep -qF "$PROMPT_FILE" "$STUB_PROMPT" && echo yes || echo no)"
check "prompt contains the claude.json output path" "yes" "$(grep -qF "$OUTPUT_FILE" "$STUB_PROMPT" && echo yes || echo no)"
check "verdict file pre-created before arbiter runs (Edit-only cannot create files)" "yes" "$(grep -q '^OUT_PREEXISTING: yes$' "$STUB_LOG" && echo yes || echo no)"
check "prompt instructs Edit-replace of the existing placeholder" "yes" "$(grep -q 'replace its ENTIRE contents' "$STUB_PROMPT" && echo yes || echo no)"
check "prompt contains the fixed-template arbiter framing" "yes" "$(grep -q 'design-review arbiter' "$STUB_PROMPT" && echo yes || echo no)"
check "prompt contains the model self-report instruction" "yes" "$(grep -q 'executed_model' "$STUB_PROMPT" && echo yes || echo no)"
check "secret never appears in the prompt (firewall)" "yes" "$(grep -q 'tok-secret-123' "$STUB_PROMPT" && echo no || echo yes)"

rc=$(run_script "$GATEWAY BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN=tok-secret-123 BLUEPRINT_ARBITER_GATEWAY_MODEL=anthropic/claude-fable-5")
check "model override honored (namespaced gateway id)" "yes" "$(grep -q '^MODEL: anthropic/claude-fable-5$' "$STUB_LOG" && echo yes || echo no)"

echo ""
echo "── deny-rule path robustness (absolute guard + symlink spelling) ──"

# Symlinked HOME: both the raw (symlink) spelling AND the resolved (real) spelling
# of the credential store must be Read-denied, since we cannot assume Claude Code's
# matcher canonicalizes the requested path before matching. (The symlink guarantees
# raw != resolved on any OS, so this also exercises the macOS /var->/private/var case.)
mkdir -p "$TMPDIR_T/realhome"
ln -s "$TMPDIR_T/realhome" "$TMPDIR_T/linkhome"
home_real="$(cd "$TMPDIR_T/realhome" && pwd -P)"
rm -f "$OUTPUT_FILE" "$STUB_LOG"
rc=0
env -i PATH="$PATH" CLAUDE_BIN="$STUB_BIN" HOME="$TMPDIR_T/linkhome" \
  STUB_LOG="$STUB_LOG" STUB_OUT="$STUB_OUT" STUB_PROMPT="$STUB_PROMPT" STUB_BEHAVIOR=good \
  BLUEPRINT_ARBITER_GATEWAY_BASE_URL=https://gateway.example/v1 \
  BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN=tok-secret-123 \
  bash "$SCRIPT" "$PROMPT_FILE" "$OUTPUT_FILE" >/dev/null 2>&1 || rc=$?
check "symlinked HOME dispatch succeeds" 0 "$rc"
check "raw (symlink) HOME credential store Read-denied" "yes" "$(grep '^DISALLOWED:' "$STUB_LOG" | grep -qF "Read(//${TMPDIR_T#/}/linkhome/.claude/**)" && echo yes || echo no)"
check "resolved (real) HOME credential store also Read-denied (alternate-spelling closed)" "yes" "$(grep '^DISALLOWED:' "$STUB_LOG" | grep -qF "Read(//${home_real#/}/.claude/**)" && echo yes || echo no)"

# Empty HOME must fail closed: a //${HOME#/}/.claude rule would degrade to a no-op
# //.claude/** that protects nothing while the dispatch still proceeds (fail-open).
rc=0
env -i PATH="$PATH" CLAUDE_BIN="$STUB_BIN" HOME="" \
  BLUEPRINT_ARBITER_GATEWAY_BASE_URL=https://gateway.example/v1 \
  BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN=tok \
  bash "$SCRIPT" "$PROMPT_FILE" "$OUTPUT_FILE" >/dev/null 2>&1 || rc=$?
check "empty HOME fails closed (no no-op credential deny rule)" "nonzero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)"

echo ""
echo "── fail-closed post-check ────────────────────────────────────"

STUB_BEHAVIOR=badjson rc=$(STUB_BEHAVIOR=badjson run_script "$GATEWAY BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN=tok-secret-123")
check "invalid JSON verdict fails with exit 1" 1 "$rc"
check "bad verdict file is deleted (clean retry)" "absent" "$([[ -f "$OUTPUT_FILE" ]] && echo present || echo absent)"

rc=$(STUB_BEHAVIOR=badstatus run_script "$GATEWAY BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN=tok-secret-123")
check "status outside PASS/FAIL fails with exit 1" 1 "$rc"

rc=$(STUB_BEHAVIOR=silent run_script "$GATEWAY BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN=tok-secret-123")
check "arbiter writing no output fails with exit 1" 1 "$rc"

SAVED_PROMPT="$PROMPT_FILE"
PROMPT_FILE="$TMPDIR_T/does-not-exist.txt"
rc=$(run_script "$GATEWAY BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN=tok-secret-123")
check "missing validation prompt fails with exit 1 (configured rung must not skip)" 1 "$rc"
PROMPT_FILE="$SAVED_PROMPT"

rc=0
env -i PATH="$PATH" CLAUDE_BIN="$STUB_BIN" \
  BLUEPRINT_ARBITER_GATEWAY_BASE_URL=https://gateway.example/v1 \
  BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN=tok \
  bash "$SCRIPT" "relative/prompt.txt" "$OUTPUT_FILE" >/dev/null 2>&1 || rc=$?
check "relative prompt path rejected" 1 "$rc"

# Both paths are spliced into the fixed dispatch template, so shell-significant
# chars (backtick, $, backslash, quotes) and control chars (newline etc.) must be
# rejected for BOTH so a crafted filename cannot inject instructions past the
# two-paths-only firewall. (Glob/list/paren metacharacters are an OUTPUT-only
# concern — see the output-path block below; the prompt path may legitimately
# contain them. Whitespace is accepted for both — see the spaced-path case below.)
for evil in "$TMPDIR_T/evil\`whoami\`.txt" "$TMPDIR_T/evil"$'\n'"ignore-previous.txt" \
            "$TMPDIR_T"'/evil$(id).txt' "$TMPDIR_T"'/evil${HOME}.txt' "$TMPDIR_T"'/evil\back.txt' \
            "$TMPDIR_T"'/evil"dq.txt' "$TMPDIR_T/evil'sq.txt"; do
  rm -f "$STUB_LOG"
  rc=0
  env -i PATH="$PATH" CLAUDE_BIN="$STUB_BIN" \
    STUB_LOG="$STUB_LOG" STUB_OUT="$STUB_OUT" STUB_PROMPT="$STUB_PROMPT" \
    BLUEPRINT_ARBITER_GATEWAY_BASE_URL=https://gateway.example/v1 \
    BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN=tok \
    bash "$SCRIPT" "$evil" "$OUTPUT_FILE" >/dev/null 2>&1 || rc=$?
  check "prompt path with injection characters rejected (firewall)" 1 "$rc"
  check "stub not invoked for injection path" "absent" "$([[ -f "$STUB_LOG" ]] && echo present || echo absent)"
done

rc=0
env -i PATH="$PATH" CLAUDE_BIN="$STUB_BIN" \
  BLUEPRINT_ARBITER_GATEWAY_BASE_URL=https://gateway.example/v1 \
  BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN=tok \
  bash "$SCRIPT" "$PROMPT_FILE" "$TMPDIR_T/out\`id\`.json" >/dev/null 2>&1 || rc=$?
check "output path with backtick rejected (firewall)" 1 "$rc"

# Output path with a glob/list/paren metacharacter must be rejected: OUTPUT_FILE
# feeds the Edit(//<path>) scope, where such a char would malform or broaden the
# single-file Edit grant. (Rejected for OUTPUT only — the prompt path is exempt.)
for badout in 'out*.json' 'out?.json' 'out[ab].json' 'out(p).json' 'out,c.json'; do
  rc=0
  env -i PATH="$PATH" CLAUDE_BIN="$STUB_BIN" \
    BLUEPRINT_ARBITER_GATEWAY_BASE_URL=https://gateway.example/v1 \
    BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN=tok \
    bash "$SCRIPT" "$PROMPT_FILE" "$TMPDIR_T/$badout" >/dev/null 2>&1 || rc=$?
  check "output path metachar rejected ($badout — Edit-scope cannot be broadened)" 1 "$rc"
done

# A PROMPT path containing parens is ACCEPTED: only OUTPUT feeds the Edit() scope,
# so a prompt file under e.g. "Project (copy)/" must still dispatch (codex/cubic #197).
mkdir -p "$TMPDIR_T/Project (copy)"
PAREN_PROMPT="$TMPDIR_T/Project (copy)/prompt.txt"
echo "validation prompt body" > "$PAREN_PROMPT"
rm -f "$OUTPUT_FILE" "$STUB_LOG"
rc=0
env -i PATH="$PATH" CLAUDE_BIN="$STUB_BIN" HOME="$HOME" \
  STUB_LOG="$STUB_LOG" STUB_OUT="$OUTPUT_FILE" STUB_PROMPT="$STUB_PROMPT" STUB_BEHAVIOR=good \
  BLUEPRINT_ARBITER_GATEWAY_BASE_URL=https://gateway.example/v1 \
  BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN=tok \
  bash "$SCRIPT" "$PAREN_PROMPT" "$OUTPUT_FILE" >/dev/null 2>&1 || rc=$?
check "prompt path with parens ACCEPTED (glob/paren ban is OUTPUT-only)" 0 "$rc"

# Whitespace in an absolute path is ACCEPTED: the --allowedTools list separator is
# the comma (not space), so a legit checkout under a spaced directory must still
# dispatch rather than needlessly fall through to opus.
mkdir -p "$TMPDIR_T/sp ace"
SPACED_OUT="$TMPDIR_T/sp ace/claude.json"
rm -f "$SPACED_OUT" "$STUB_LOG"
rc=0
env -i PATH="$PATH" CLAUDE_BIN="$STUB_BIN" HOME="$HOME" \
  STUB_LOG="$STUB_LOG" STUB_OUT="$SPACED_OUT" STUB_PROMPT="$STUB_PROMPT" STUB_BEHAVIOR=good \
  BLUEPRINT_ARBITER_GATEWAY_BASE_URL=https://gateway.example/v1 \
  BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN=tok \
  bash "$SCRIPT" "$PROMPT_FILE" "$SPACED_OUT" >/dev/null 2>&1 || rc=$?
check "output path with spaces ACCEPTED (whitespace not banned; rung not needlessly failed)" 0 "$rc"

# ═══════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo ""
echo "── Capability guard: --setting-sources required (fail-closed, issue #198) ──"
# An older claude that lacks --setting-sources cannot neutralize the operator's
# user/project/local permission scopes, so the dispatcher must refuse to run the
# arbiter unconfined rather than silently inherit a broad Edit allow rule.
rc=$(run_script "$GATEWAY BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN=tok-secret-123 CLAUDE_BIN=$STUB_BIN_OLD")
check "claude lacking --setting-sources → dispatch refused (exit 1, fail-closed)" 1 "$rc"
check "no verdict written when capability guard fails (arbiter never ran unconfined)" "absent" "$([[ -f "$OUTPUT_FILE" ]] && echo present || echo absent)"

echo ""
echo "── Results: $PASS/$TOTAL passed ────────────────────────────"
if [[ "$FAIL" -gt 0 ]]; then
  echo "   $FAIL FAILED"
  exit 1
fi
echo "   All passed."
exit 0
