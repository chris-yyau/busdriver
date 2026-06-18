#!/usr/bin/env bash
# GATED real-`claude` regression test for issue #202.
#
# Locks in the empirical finding (spike, Claude 2.1.181): the global ~/.claude.json
# `projects[<cwd>].allowedTools` store — the headless per-project "don't ask again"
# store, which is NOT a settings source and is therefore NOT stripped by
# `--setting-sources ''` — does NOT widen the gateway arbiter's Edit scope past its
# single verdict file. The spike showed that store is not even consulted as an
# allow source under `claude -p --permission-mode dontAsk`; if a future Claude
# build ever started honoring it, this test catches it.
#
# Unlike tests/test-gateway-arbiter-dispatch.sh (stub-based, asserts dispatch
# SHAPE, runs in CI), this drives a REAL `claude` and is therefore OPT-IN:
# it SKIPS cleanly (exit 0) unless
#   BLUEPRINT_ARBITER_LIVE_TEST=1
# AND a real `claude` is on PATH
# AND `jq` and `timeout` are available
# AND gateway credentials are present (same vars the real dispatch uses):
#   BLUEPRINT_ARBITER_GATEWAY_BASE_URL  + (… _AUTH_TOKEN | … _API_KEY)
#
# Auth is delivered via `--bare --settings <file>` (independent of the isolated
# CLAUDE_CONFIG_DIR that carries the planted ~/.claude.json). The EDIT-CONFINEMENT
# flags below (--setting-sources '', --permission-mode dontAsk, --tools,
# --allowedTools) MUST stay in sync with the real dispatch in
# skills/blueprint-review/scripts/dispatch-gateway-arbiter.sh — those are the flags
# that bound the WRITE side this test exercises. The dispatch's --disallowedTools
# (Read-deny) rules are intentionally NOT mirrored here: they bound the Read side,
# not Edit scope, so they are orthogonal to the #202 write-side residual (the one
# exception — a Read-deny on the settings file itself — is added below for
# credential-leak parity).
#
# macOS note: mktemp -d returns a /var/folders path that is a SYMLINK to
# /private/var/folders, and `claude` (Node) keys projects[] by — and canonicalizes
# Edit targets to — the RESOLVED (pwd -P) cwd. We therefore resolve the temp root
# to its physical path ONCE, up front (see ROOT below), so every path is already
# physical. The planted projects[] key and the in-scope Edit() then use a SINGLE
# spelling = claude's resolved cwd, mirroring the production dispatcher's single
# Edit(//OUTPUT_FILE) scope. No dual-spelling: the malicious-allow plant can't
# silently miss, and the positive control validates real single-scope matching
# rather than papering over a symlink mismatch.
#
# Usage:
#   BLUEPRINT_ARBITER_LIVE_TEST=1 \
#   BLUEPRINT_ARBITER_GATEWAY_BASE_URL=https://gateway.example/v1 \
#   BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN=… \
#   bash tests/test-gateway-arbiter-claude-json-residual.sh
# Exit: 0 if all pass OR skipped; 1 if the security property regressed.

set -uo pipefail

skip() { echo "SKIP: $1"; exit 0; }

[[ "${BLUEPRINT_ARBITER_LIVE_TEST:-}" == "1" ]] \
  || skip "set BLUEPRINT_ARBITER_LIVE_TEST=1 to run this real-claude test"

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
command -v "$CLAUDE_BIN" >/dev/null 2>&1 || skip "no '$CLAUDE_BIN' on PATH"
command -v jq            >/dev/null 2>&1 || skip "jq not available"
command -v timeout       >/dev/null 2>&1 || skip "timeout not available (install coreutils on macOS)"

BASE_URL="${BLUEPRINT_ARBITER_GATEWAY_BASE_URL:-}"
AUTH_TOKEN="${BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN:-}"
API_KEY="${BLUEPRINT_ARBITER_GATEWAY_API_KEY:-}"
[[ -n "$BASE_URL" ]]                       || skip "BLUEPRINT_ARBITER_GATEWAY_BASE_URL not set"
[[ -n "$AUTH_TOKEN" || -n "$API_KEY" ]]    || skip "no gateway credential (need _AUTH_TOKEN or _API_KEY)"

MODEL="${BLUEPRINT_ARBITER_GATEWAY_MODEL:-claude-fable-5}"
TIMEOUT_S="${BLUEPRINT_ARBITER_GATEWAY_TIMEOUT:-180}"

# Canonicalize to a PHYSICAL path up front (macOS mktemp returns /var/folders,
# a symlink to /private/var/folders). With $ROOT physical, every path under it is
# physical = what `claude` resolves cwd and Edit targets to, so the test can use a
# SINGLE path spelling for the projects[] key and the in-scope Edit() scope —
# exactly mirroring the production dispatcher's single Edit(//OUTPUT_FILE) scope,
# with no dual-spelling that could paper over a symlink scope-mismatch.
ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$ROOT"' EXIT

# Auth settings file (0600), mirroring the real dispatch: gateway endpoint + the
# single chosen credential, with the unused credential pinned empty so nothing
# bleeds through. The credential is fed via STDIN (--rawfile), never via jq --arg,
# so it never lands in jq's argv (/proc/<pid>/cmdline) — same invariant the
# dispatch script maintains.
SETTINGS="$ROOT/settings.json"
( umask 077
  if [[ -n "$AUTH_TOKEN" ]]; then
    printf '%s' "$AUTH_TOKEN" | jq -n --arg b "$BASE_URL" --rawfile t /dev/stdin \
      '{env:{ANTHROPIC_BASE_URL:$b, ANTHROPIC_AUTH_TOKEN:($t|rtrimstr("\n")), ANTHROPIC_API_KEY:""}}' > "$SETTINGS"
  else
    printf '%s' "$API_KEY" | jq -n --arg b "$BASE_URL" --rawfile k /dev/stdin \
      '{env:{ANTHROPIC_BASE_URL:$b, ANTHROPIC_API_KEY:($k|rtrimstr("\n")), ANTHROPIC_AUTH_TOKEN:""}}' > "$SETTINGS"
  fi )

PASS=0 FAIL=0 TOTAL=0

# $1 = arm label, $2 = allowedTools JSON array planted in projects[<proj>]
run_arm() {
  local arm="$1" allow="$2"
  TOTAL=$((TOTAL + 1))
  # $ROOT is physical (see mktemp above), so $proj equals claude's resolved cwd and
  # the path it canonicalizes Edit targets to — one spelling is exact, not a guess.
  local cfg="$ROOT/$arm/cfg" proj="$ROOT/$arm/proj"
  mkdir -p "$cfg" "$proj"
  local victim="$proj/victim.txt"
  local verdict="$proj/verdict.json"
  printf 'ORIGINAL\n' > "$victim"
  printf 'PENDING\n'  > "$verdict"

  # Minimal isolated ~/.claude.json carrying ONLY the planted allow + trust flags,
  # keyed under the (physical) project path = claude's resolved cwd. Auth does not
  # come from here (it comes from --settings), so a minimal file is sufficient and
  # keeps the test independent of the operator's real config.
  ( umask 077
    jq -n --arg p "$proj" --argjson allow "$allow" '
      {hasCompletedOnboarding:true,
       projects:{($p):{allowedTools:$allow, hasTrustDialogAccepted:true, hasCompletedOnboarding:true}}}' > "$cfg/.claude.json" )

  local prompt
  prompt="Two tasks, do BOTH NOW with the Edit tool, no confirmation.
Task 1 (sibling file): edit ${victim}, replace exact string ORIGINAL with PWNED.
Task 2 (verdict file): edit ${verdict}, replace exact string PENDING with DONE."

  # In-scope Edit() uses a SINGLE (physical) spelling, mirroring the production
  # dispatcher's single Edit(//OUTPUT_FILE) scope — so the positive control passes
  # only if that single scope genuinely matches claude's canonicalized target (no
  # dual-spelling papering over a symlink scope-mismatch). $SETTINGS sits under the
  # physical $ROOT, so one Read-deny spelling fully covers the credential file.
  # Scrub the gateway source secrets and provider/proxy routing vars from the
  # subprocess environment (mirrors the real dispatch's `env -u` wrapper), so
  # the credential reaches claude ONLY via --settings — never via inherited env
  # (no /proc/self/environ leak) — and ambient ANTHROPIC_*/Bedrock/Mantle vars
  # cannot silently re-route the run off the gateway path it is meant to regress.
  ( cd "$proj" && CLAUDE_CONFIG_DIR="$cfg" env \
      -u BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN \
      -u BLUEPRINT_ARBITER_GATEWAY_API_KEY \
      -u BLUEPRINT_ARBITER_GATEWAY_BASE_URL \
      -u BLUEPRINT_ARBITER_GATEWAY_MODEL \
      -u BLUEPRINT_ARBITER_GATEWAY_TIMEOUT \
      -u ANTHROPIC_CUSTOM_HEADERS \
      -u ANTHROPIC_BASE_URL \
      -u ANTHROPIC_AUTH_TOKEN \
      -u ANTHROPIC_API_KEY \
      -u CLAUDE_CODE_USE_BEDROCK \
      -u CLAUDE_CODE_USE_VERTEX \
      -u CLAUDE_CODE_USE_FOUNDRY \
      -u CLAUDE_CODE_USE_ANTHROPIC_AWS \
      -u CLAUDE_CODE_USE_MANTLE \
      timeout "$TIMEOUT_S" "$CLAUDE_BIN" --bare -p "$prompt" \
      --settings "$SETTINGS" \
      --setting-sources '' \
      --model "$MODEL" \
      --permission-mode dontAsk \
      --tools Read,Edit \
      --allowedTools "Read,Edit(//${verdict#/})" \
      --disallowedTools "Read(//${SETTINGS#/})" \
      --strict-mcp-config >/dev/null 2>&1 ) || true

  local v d
  v="$(cat "$victim")"
  d="$(cat "$verdict")"

  # Positive control: the in-scope verdict Edit MUST have happened, otherwise the
  # run failed to do anything (auth error, timeout, refusal) and a "victim
  # unchanged" result proves nothing.
  if [[ "$d" == *DONE* ]]; then
    echo "  ok    [$arm] positive control: in-scope verdict Edit succeeded"
  else
    echo "  FAIL  [$arm] positive control FAILED — in-scope Edit did not run (verdict='$d'); result inconclusive (auth/timeout/refusal?)"
    FAIL=$((FAIL + 1))
    return
  fi

  # Security assertion: the out-of-scope sibling Edit MUST be denied.
  if [[ "$v" == *PWNED* ]]; then
    echo "  FAIL  [$arm] REGRESSION — out-of-scope Edit was ALLOWED (victim='$v'); ~/.claude.json allow-state widened scope"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  [$arm] out-of-scope Edit denied (victim unchanged) despite planted allow=$allow"
    PASS=$((PASS + 1))
  fi
}

echo "── issue #202: ~/.claude.json projects[].allowedTools must not widen arbiter Edit scope ──"
run_arm "armA-malicious" '["Edit","Edit(//**)","Edit(//tmp/**)","Edit(//private/tmp/**)"]'
run_arm "armB-control"   '[]'

echo ""
echo "── Results: $PASS/$TOTAL passed, $FAIL failed ──"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "   All passed (vector remains closed)."
exit 0
