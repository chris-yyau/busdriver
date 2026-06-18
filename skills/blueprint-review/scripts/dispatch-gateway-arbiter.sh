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
#   - Secret handling: credentials are read from the environment here, written to
#     a 0600 temp --settings file, and delivered to the subprocess via that file
#     ONLY — never the subprocess environment, never argv. The calling Claude
#     session never handles them.
#   - Edit confinement: dispatched with --setting-sources '' so the operator's
#     user/project/local settings (which may carry a broad `permissions.allow`
#     Edit rule) are NOT loaded — an inherited allow cannot widen the arbiter's
#     Edit scope past the single verdict file (issue #198). --settings (the
#     credential channel) is an explicit, separate input and still applies. A
#     capability guard fails the dispatch closed on a claude too old for the flag.
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
_PLUGIN_ROOT="${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}}"
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
# Shell-significant chars (backtick, $, backslash, quotes) and control chars are
# rejected for BOTH paths here; glob/list/paren metacharacters are rejected for the
# OUTPUT path ONLY, just after this loop.
for _path in "$PROMPT_FILE" "$OUTPUT_FILE"; do
  case "$_path" in
    *\`*|*\$*|*\\*|*\"*|*\'*) die "path must not contain shell-significant characters (backtick, \$, backslash, quotes): $_path" ;;
  esac
  if printf '%s' "$_path" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    die "path must not contain control characters"
  fi
done
# Glob/list/paren metacharacters are rejected for the OUTPUT path ONLY: it is spliced
# into the --allowedTools "Edit(//<path>)" scope below — a COMMA-separated list of
# glob-syntax permission rules — so ( ) (the rule delimiters), a comma (the list
# separator), or * ? [ ] (glob wildcards — Claude Code interprets globs in rule paths;
# cf. the ** deny rules below) could malform the rule or BROADEN the Edit scope beyond
# the single intended file (e.g. Edit(//docs/reviews/x*/claude.json) would match
# siblings). The PROMPT path is exempt — it only appears as prompt text + the -f check,
# so a prompt file under e.g. "Project (copy)/" is harmless. Whitespace is allowed for
# both (the list separator is the comma, not space), so a legitimate absolute path with
# spaces stays inside the Edit() parens rather than needlessly failing the rung.
case "$OUTPUT_FILE" in
  *\(*|*\)*|*\**|*\?*|*\[*|*\]*|*,*) die "claude.json output path must not contain glob/list/paren metacharacters (( ) * ? [ ], comma) — it is spliced into the Edit(...) permission scope: $OUTPUT_FILE" ;;
esac

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
  "The file \`${OUTPUT_FILE}\` already exists with a one-line JSON placeholder; Read it," \
  "then use Edit to replace its ENTIRE contents with your strict-JSON verdict" \
  "(the placeholder status is not PASS/FAIL, so leaving it unedited fails the run)." \
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
#   - CLAUDE_CODE_USE_{BEDROCK,VERTEX,FOUNDRY,ANTHROPIC_AWS,MANTLE}: cloud-provider
#     routing outranks ANTHROPIC_* in Claude Code's auth precedence; an inherited
#     selector would route the arbiter to the parent's provider and ignore the
#     gateway entirely. (MANTLE is the Bedrock Mantle backend selector, undocumented
#     as of 2026-06 — claude-code#44899; env -u of an unset variable is harmless.)
#     The AWS selector is CLAUDE_CODE_USE_ANTHROPIC_AWS — verified against the
#     claude 2.1.181 binary's embedded token table (#202 review): an earlier
#     CLAUDE_CODE_USE_AWS spelling here was a phantom (no such var) that left the
#     real selector un-neutralized.
# NB: env(1) requires -u options BEFORE the NAME=VALUE assignment.
ENV_ARGS=(-u BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN -u BLUEPRINT_ARBITER_GATEWAY_API_KEY
          -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY
          -u ANTHROPIC_CUSTOM_HEADERS
          -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY
          -u CLAUDE_CODE_USE_ANTHROPIC_AWS -u CLAUDE_CODE_USE_MANTLE
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
# The credential is fed to jq through STDIN (printf … | jq --rawfile cred /dev/stdin),
# NOT --arg and NOT the environment: a --arg value lands in jq's argv
# (/proc/<pid>/cmdline) and an env value lands in jq's /proc/<pid>/environ — both
# readable by same-user processes / process accounting for jq's lifetime, which would
# breach the "secret never in argv or environ" guarantee before the arbiter even
# starts. The pipe keeps the secret out of both (printf is a bash builtin, so no
# separate process; $cred is a non-exported shell var, so not in this script's environ
# either). Only the non-secret base URL and the var NAMES travel via --arg. $cred
# carries the chosen credential; $cred_var names which ANTHROPIC_* key it fills,
# $other_var the unused one (pinned empty). ($cred_var avoids shadowing the `which`
# builtin.)
# Capability guard (fail-CLOSED, issue #198): the arbiter is confined by NOT
# loading the operator's user/project/local setting sources (--setting-sources ''
# in the dispatch below), so an inherited broad `permissions.allow` Edit rule
# cannot widen the arbiter's Edit scope past the single verdict file. If this
# claude predates --setting-sources, those operator allow rules would merge in
# unneutralized (settings merge; allow arrays concatenate; --permission-mode
# dontAsk still honors a pre-approved Edit) and a prompt-injected arbiter could
# Edit arbitrary workspace files. Refuse to dispatch rather than run unconfined —
# the caller's fallback chain still provides arbitration via the opus rung.
# The probe runs under the SAME `env "${ENV_ARGS[@]}"` scrubbing as the real
# dispatch, so this extra `claude` invocation never receives the gateway or
# ANTHROPIC_* secrets (it must honor the credential-containment invariant too).
# Runs before the credential file is written, so an old binary fails closed with
# no secrets on disk.
# Capture-then-match rather than `--help | grep -q`: under `set -o pipefail`,
# grep -q closes the pipe on first match and claude can take SIGPIPE (exit 141),
# which would fail the pipeline and FALSELY reject a supported binary. The `|| true`
# keeps a non-zero --help (older builds) from tripping `set -e` — an absent flag is
# handled by the glob test below, not by the exit status. 2>&1 (not 2>/dev/null)
# so a build that prints --help to stderr is matched, not falsely rejected.
_gw_help="$(env "${ENV_ARGS[@]}" "$CLAUDE_BIN" --help 2>&1 || true)"
[[ "$_gw_help" == *--setting-sources* ]] \
  || die "claude ($CLAUDE_BIN) does not support --setting-sources; cannot neutralize operator permission scopes for the arbiter — upgrade claude or unset the gateway config (the caller retries once, then falls through to the opus rung)"

SETTINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/bp-gw-settings.XXXXXX")"
chmod 600 "$SETTINGS_FILE"
trap 'rm -f "${SETTINGS_FILE:-}"' EXIT
if [[ -n "$AUTH_TOKEN" ]]; then
  cred="$AUTH_TOKEN"; cred_var="ANTHROPIC_AUTH_TOKEN"; other_var="ANTHROPIC_API_KEY"
else
  cred="$API_KEY"; cred_var="ANTHROPIC_API_KEY"; other_var="ANTHROPIC_AUTH_TOKEN"
fi
# A jq failure (e.g. a full disk) must fail CLOSED: an empty/partial settings file
# would hand --settings a file with no credential, and the dispatch would 401
# confusingly instead of erroring here. Check the exit status AND that the file is
# non-empty before relying on it (the trap still cleans it up on die).
printf '%s' "$cred" | jq -n --rawfile cred /dev/stdin --arg url "$BASE_URL" --arg cred_var "$cred_var" --arg other_var "$other_var" '{
  env: ({
    ANTHROPIC_BASE_URL: $url,
    ANTHROPIC_CUSTOM_HEADERS: "",
    CLAUDE_CODE_USE_BEDROCK: "", CLAUDE_CODE_USE_VERTEX: "", CLAUDE_CODE_USE_FOUNDRY: "",
    CLAUDE_CODE_USE_ANTHROPIC_AWS: "", CLAUDE_CODE_USE_MANTLE: ""
  } + { ($cred_var): $cred, ($other_var): "" })
}' >"$SETTINGS_FILE" || die "failed to write gateway settings file (jq error)"
[[ -s "$SETTINGS_FILE" ]] || die "gateway settings file is empty after jq write"

echo "gateway-arbiter: dispatching headless arbiter (model: $MODEL, timeout: ${TIMEOUT_S}s)" >&2
# --bare skips auto-discovery of hooks, skills, plugins, MCP servers, auto
# memory, and CLAUDE.md — the arbiter sees ONLY the fixed prompt plus the
# codebase (no author-side CLAUDE.md context, and busdriver's own PreToolUse
# gates can't fire inside the subprocess). It also skips OAuth/keychain
# reads, so auth comes solely from the gateway --settings file above.
# --permission-mode dontAsk is the KEYSTONE: it makes the run deny-by-default —
# only tools matching an --allowedTools rule (and read-only Bash, which is moot
# since Bash isn't in --tools) execute; everything else is DENIED, never prompted.
# It also OVERRIDES the operator's settings `defaultMode`, so an operator who runs
# with acceptEdits/auto/bypassPermissions cannot widen the arbiter: without dontAsk,
# --allowedTools merely ADDS auto-approvals (it does not restrict), so a permissive
# inherited mode would auto-approve Edit workspace-wide and defeat the Edit scope.
# --tools RESTRICTS which tools exist (the firewall); --allowedTools only
# pre-approves, so without --tools a permissive permission config would let the
# arbiter reach other tools. --strict-mcp-config keeps
# MCP servers from loading even if a future flag change re-enables discovery.
# Tool names: under --bare the built-in selectable set is {Bash, Edit, Read};
# Grep/Glob/Write are NOT selectable there (passing them silently collapses the
# set to Read alone). Grant ONLY Read (inspect the files the reviews cite) and
# Edit (write the verdict) — no shell. Read is broad (the arbiter must open many
# cited files); Edit is pre-approved for EXACTLY ONE path — the verdict file
# ($OUTPUT_FILE) — via the --allowedTools "Edit(//<path>)" scope below, because
# the arbiter has exactly one legitimate write target. Edit is exact-string
# replacement and CANNOT create a file (Write is not selectable under --bare), so
# the script pre-creates $OUTPUT_FILE with a placeholder below (the full loop
# cleans claude.json before each dispatch, so it is otherwise absent); the arbiter
# Reads that placeholder, then Edits it to the verdict.
#
# Containment vs. a prompt-injected arbiter (it reads reviewer-authored content,
# so treat it as hostile). Defence in depth, all deterministic:
#   1. No shell — Bash withheld, so no env/printenv.
#   2. No env token — the credential is NOT in the subprocess environment (see
#      ENV_ARGS above); it arrives only via the --settings file. So a Read of
#      /proc/self/environ exposes no credential (only the non-secret base URL,
#      which is also the belt-and-suspenders ANTHROPIC_BASE_URL in ENV_ARGS).
#   3. Read confined — --disallowedTools blocks the residual Read vectors:
#      (a) /proc, /sys, /dev (so the arbiter cannot Read /proc/self/environ, nor
#      /proc/self/cmdline to learn the random --settings path), plus the settings
#      file path itself. /proc, /sys, /dev are fixed kernel mounts with no symlink
#      alternate-spelling; the userspace paths (the settings file and the
#      credential stores below) ARE alternate-spellable, so each is denied in both
#      its raw and its pwd -P-resolved spelling (see the construction below).
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
#   4. Edit confined — Edit is pre-approved (--allowedTools) for the verdict file
#      ALONE, not workspace-wide. The deny rules above only bound Read; without an
#      Edit scope a prompt-injected arbiter could Edit ARBITRARY workspace files —
#      inject code into a source file, rewrite a settings/config file, tamper with
#      another review's artifacts. Under --permission-mode dontAsk (the keystone,
#      above) the run is deny-by-default, so an Edit to any path the allow-rule
#      doesn't cover is denied (never prompted) regardless of the operator's
#      settings defaultMode — scoping the allow to $OUTPUT_FILE thus confines all
#      writes to the one legitimate target. (Edit is an allowlist — exactly one
#      valid target — whereas Read stays a blocklist — many valid targets. dontAsk
#      also denies writes to protected paths like .claude/.git as a bonus.)
#      This holds ONLY because the operator's own settings are not loaded: their
#      user/project/local permissions.allow would otherwise CONCATENATE with our
#      scoped allow (and dontAsk honors anything pre-approved), so a broad
#      Edit(//**) the operator once approved would re-widen the scope. That is why
#      the dispatch passes --setting-sources '' and the capability guard above
#      fails closed when the flag is unavailable (issue #198).
#      Residual checked (issue #202): --setting-sources '' neutralizes only the
#      user/project/local SETTINGS sources. The global ~/.claude.json
#      (projects[<cwd>].allowedTools — the per-project "don't ask again" store) is
#      NOT a setting source and is read regardless, so #202 asked whether a broad
#      Edit allow stashed there could re-widen scope on the WRITE side. A live
#      spike (Claude 2.1.181), planting Edit(//**) under BOTH the raw and the
#      pwd -P-resolved cwd key (the key claude actually looks up), settled it: with
#      the planted allow as the ONLY possible source (dontAsk, no --allowedTools)
#      the Edit was still DENIED — so the projects[].allowedTools store is not
#      consulted as an allow source under `claude -p --permission-mode dontAsk` at
#      all (it is interactive-only persistence). Malicious-vs-control arms with the
#      real flags were identical: out-of-scope Edit denied, in-scope verdict Edit
#      (approved solely by --allowedTools) succeeded. The only allow-state neither
#      --setting-sources '' nor a CLAUDE_CONFIG_DIR redirect can strip is
#      enterprise MANAGED policy, which is admin-controlled (an attacker who can
#      write managed-settings has already won). Locked in by the gated regression
#      test tests/test-gateway-arbiter-claude-json-residual.sh.
# Net: no shell, no env token, no way to discover the settings path, settings file
# + Anthropic credential stores Read-denied, Edit scoped to the verdict file — the
# arbiter has no route to the gateway secret OR the operator's own credential, and
# cannot write anywhere but its verdict. Read remains a blocklist, not an allowlist:
# arbitrary non-credential reads (like every Read-granted subagent) stay in scope of
# the model's judgement, out of scope for this credential hardening. The cost is no
# free-form codebase search (Grep/Glob unavailable under --bare), so validation is
# by reading the cited files, like the non-gateway arbiter.
# The deny rules use the //<abs-path> form (the leading-// form is what Claude
# Code's matcher honours for absolute-path rules); the Edit allow-scope uses the
# same form. Two robustness measures on the credential-bearing paths:
#   - Absolute guard: $HOME/$PWD are spliced into //${VAR#/} rules, so an empty or
#     relative value would yield a no-op rule (//.claude/**) that protects nothing
#     while the dispatch still proceeds — a fail-OPEN. Require both absolute.
#   - Alternate-spelling coverage: a deny pins ONE spelling, but a symlinked prefix
#     (macOS $TMPDIR /var->/private/var; a relocated $HOME; a $PWD under a symlinked
#     mount) reaches the same file by an undenied canonical spelling. Since we can't
#     assume the matcher canonicalizes the requested path before matching, emit BOTH
#     the raw and the resolved (pwd -P) spelling for each credential path. Duplicate
#     rules when raw==resolved are harmless.
[[ "$HOME" == /* ]] || die "HOME must be absolute to build credential-deny rules: $HOME"
[[ "$PWD" == /* ]] || die "PWD must be absolute to build credential-deny rules: $PWD"
# Anchor the PROJECT credential-store deny to the repo ROOT, not $PWD: the helper
# is documented to run from the project root, but if it is invoked from a
# subdirectory a $PWD/.claude/** rule would deny the wrong directory and leave the
# repo-root .claude/ (which can hold a settings.local.json credential) readable.
# git finds the real root regardless of CWD; fall back to $PWD when not in a git
# repo (this deny is defense-in-depth — the $HOME stores below are the primary
# guard).
_proj_root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$_proj_root" && "$_proj_root" == /* ]] || _proj_root="$PWD"
_resolve_dir() { (cd "$1" 2>/dev/null && pwd -P) || true; }
_home_real="$(_resolve_dir "$HOME")"
_proj_real="$(_resolve_dir "$_proj_root")"
_settings_dir_real="$(_resolve_dir "$(dirname "$SETTINGS_FILE")")"
DISALLOW_ARGS=(--disallowedTools 'Read(//proc/**)'
               --disallowedTools 'Read(//sys/**)'
               --disallowedTools 'Read(//dev/**)')
# Append a Read deny for the raw path, and a second for its resolved spelling when
# that differs. Always returns 0 so a no-op (raw==resolved) can't trip set -e.
_deny_read() {  # $1 raw abs path, $2 resolved abs path (may be empty or == $1)
  DISALLOW_ARGS+=(--disallowedTools "Read(//${1#/})")
  [[ -n "$2" && "$2" != "$1" ]] && DISALLOW_ARGS+=(--disallowedTools "Read(//${2#/})")
  return 0
}
_deny_read "$SETTINGS_FILE"     "${_settings_dir_real:+$_settings_dir_real/$(basename "$SETTINGS_FILE")}"
_deny_read "$HOME/.claude/**"   "${_home_real:+$_home_real/.claude/**}"
_deny_read "$HOME/.claude.json" "${_home_real:+$_home_real/.claude.json}"
_deny_read "$_proj_root/.claude/**" "${_proj_real:+$_proj_real/.claude/**}"

# Pre-create the verdict file with a placeholder. Under --bare the arbiter holds
# Read,Edit only (no Bash; Write is not selectable under --bare), and Edit is
# exact-string replacement that REQUIRES the target to already exist — it cannot
# create one. The full loop cleans claude.json before each dispatch, so without
# this the arbiter would have no tool able to create the verdict and every gateway
# dispatch would fail the post-check (the rung silently degrades to opus). The
# placeholder is valid JSON whose status is deliberately NOT PASS/FAIL, so if the
# arbiter fails to overwrite it the post-check below still fails closed (deleted as
# garbage). The arbiter Reads this placeholder, then Edits the whole object.
printf '%s\n' '{"status":"PENDING_ARBITER_WRITE","_note":"placeholder — replace this entire object via Edit with the strict-JSON verdict"}' > "$OUTPUT_FILE" \
  || die "failed to pre-create verdict placeholder at $OUTPUT_FILE"

DISPATCH_RC=0
_portable_timeout "$TIMEOUT_S" env "${ENV_ARGS[@]}" "$CLAUDE_BIN" --bare -p "$DISPATCH_PROMPT" \
  --settings "$SETTINGS_FILE" \
  --setting-sources '' \
  --model "$MODEL" \
  --permission-mode dontAsk \
  --tools Read,Edit \
  --allowedTools "Read,Edit(//${OUTPUT_FILE#/})" \
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
