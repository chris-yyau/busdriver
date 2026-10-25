#!/bin/bash -p
# ── Function-clean boundary (ADR 0016 / #325 class) ───────────────
# SHEBANG: `#!/bin/bash -p` — an ABSOLUTE interpreter (#803), so a hostile PATH
# cannot choose it (the env-resolved form existed only for the withdrawn pi lane's
# bash 4+ floor, ADR 0060; the script is verified on macOS /bin/bash 3.2) AND the
# first process starts with `-p`, so no BASH_FUNC_*
# shadow is imported from the start — the guard's own `exec` cannot be a
# shadow. Every invocation then passes the nonce+sentinel re-exec proof
# below before continuing.
# The proof: a sentinel function is exported before the re-exec — the
# post-re-exec checks verify (a) the marker, (b) the sentinel env export is
# present, and (c) the sentinel was NOT imported (a -p shell never imports
# it; a forged no-p re-exec does). The marker only gates the attempt;
# the sentinel checks are what authorize continuation.
# BOUNDED BY CONSTRUCTION (bash32-unshadowable-abort): the guard's command
# words (`export`, `exec`, `type`) are shadowable, and every bypass probe
# against it — shadowing `type`, `unset -f _bd_sentinel` before re-exec'ing,
# stripping the sentinel from the env — requires the attacker's shadow to
# execute further commands. The moment any imported shadow runs, it already
# has arbitrary code execution: "a set +e-running attacker is total compromise
# anyway", and no in-shell guard survives that. This backstop therefore stops
# every shadow that merely replaces a command word (the realistic #325 probe:
# a fork's settings.json exporting BASH_FUNC_exec%%); it does not — cannot —
# stop an attacker who is already running code. The real trust boundary is
# the env -i child. There is deliberately NO function-export
# encoding probe (an `eval`-defined random-name function): on this build the
# sentinel always exports as BASH_FUNC__bd_sentinel%%, and on a build that
# exports plain names the single-encoding check FAILS CLOSED (abort) — an
# unpatched pre-4.3 Shellshock-era bash is out of scope.
if [[ "${BASH_SOURCE[0]}" == "$0" ]] && [[ "${1:-}" != "_bd_priv_${_bd_nonce:-}" || -z "${_bd_nonce:-}" ]]; then
  # Nonce: the marker is "_bd_priv_<nonce>"; the nonce must be NON-EMPTY, so
  # caller-supplied bare "_bd_priv" / "_bd_priv_" (empty env nonce) never
  # match and fall through to the re-exec. The pre-re-exec branch also exports
  # the sentinel — its env presence is proof the branch ran. This branch runs
  # no probe words beyond reserved-word `[[ ]]` and the builtins it needs
  # (set/export/exec — a shadow of any of them has already executed code,
  # total compromise, out of scope).
  _bd_nonce="${RANDOM}${RANDOM}${RANDOM}"
  export _bd_nonce
  # shellcheck disable=SC2329  # sentinel is exported and probed, never invoked — its import state IS the signal
  _bd_sentinel() { :; }
  export -f _bd_sentinel
  exec "$BASH" -p "$0" "_bd_priv_${_bd_nonce}" "$@"
fi
# Post-re-exec. THREE proofs, all required before continuing:
#  (a) marker == "_bd_priv_<non-empty env nonce>" — the re-exec branch ran.
#  (b) the sentinel env export BASH_FUNC__bd_sentinel%% EXACTLY equals THIS
#      bash's own export of an identically-bodied probe function (defined +
#      exported HERE, post-exec — no eval, no encoding probe): a forged
#      malformed value (`() { x }`, truncated `() {`) is NOT importable and
#      differs from the real export text → rejected; an attacker forging the
#      EXACT valid value makes it importable in their plain shell → caught by
#      (c). The probe lookup failing (a build exporting plain names) fails
#      CLOSED (abort) — an unpatched pre-4.3 Shellshock-era bash is out of
#      scope.
#  (c) the sentinel was NOT imported (`type -t` != function) — proves the
#      re-exec ran under -p (a forged no-p re-exec imports it). `type` is the
#      one shadowable word in this guard; a shadow of it has already executed
#      code — total compromise, out of scope (bash32-unshadowable-abort).
# shellcheck disable=SC2329  # probe is exported and printenv'd, never invoked — its export text IS the signal
_bd_probe2() { :; }
export -f _bd_probe2
_bd_expected_env="$(/usr/bin/printenv "BASH_FUNC__bd_probe2%%" 2>/dev/null || true)"
_bd_sentinel_env="$(/usr/bin/printenv "BASH_FUNC__bd_sentinel%%" 2>/dev/null || true)"
if [[ "${1:-}" != "_bd_priv_${_bd_nonce:-}" || -z "${_bd_nonce:-}" ]] \
   || [[ -z "$_bd_expected_env" || "$_bd_sentinel_env" != "$_bd_expected_env" ]] \
   || [[ "$(type -t _bd_sentinel 2>/dev/null || true)" == "function" ]]; then
  _bd_priv_guard=
  : "${_bd_priv_guard:?refusing to continue: the script is not running privileged (imported function shadows present) — re-run via the shebang in a clean shell}"
fi
[[ "${1:-}" == "_bd_priv_${_bd_nonce:-}" ]] && shift
# #803: scrub BASH_ENV/ENV so unprivileged descendants cannot re-process them --
# privileged mode makes THIS shell ignore them but leaves the entries in environ
# (measured: a child of a privileged parent ran a BASH_ENV file containing `exit 0`
# and never executed its own body). Placed AFTER the sentinel proof above, which
# reads BASH_FUNC__bd_sentinel%% out of the environment. Deliberately just an unset:
# the `env -u` rebuild the other entry points use strips the sentinel and re-execs
# without the nonce marker, which re-arms the proof forever (measured: a hang). This
# script needs no rebuild anyway -- every child it launches is already `env -i`.
unset BASH_ENV ENV
# #803: clean-child scrub, placed AFTER the sentinel proofs above — they read
# BASH_FUNC__bd_sentinel%% out of the environment, so scrubbing earlier would
# destroy the very evidence the proof consumes. Privileged mode stops THIS shell
# from honouring BASH_ENV/ENV, but leaves the entries in the environment for any
# unprivileged child to re-process (measured: a child of a privileged parent ran a
# BASH_ENV file containing `exit 0` and never executed its own body).
# dispatch.sh — Dispatch tasks to Codex, Antigravity (agy), or Grok CLI as autonomous agents
#
# Usage (prefer heredoc or stdin to avoid shell escaping bugs):
#   dispatch.sh --cli codex <<'PROMPT'
#   your task here
#   PROMPT
#   echo "task" | dispatch.sh --cli codex
#   dispatch.sh --cli codex --prompt "simple single-line only"

# `_has_cli` is intentionally used inside `if`/`!`/`||`/`&&` conditions as
# the canonical "is this CLI installed" check. SC2310's "set -e disabled in
# conditional" advisory is the wrong remediation here — the conditional IS
# the point of the helper. Likewise SC2312 fires on intentional pipeline
# patterns where the inner command's exit code is not load-bearing.
# shellcheck disable=SC2310,SC2312

set -euo pipefail

# ── Harness-portable root/state resolution ─────────────────────────────
# BUSDRIVER_PLUGIN_ROOT: plugin-root override; falls back to CLAUDE_PLUGIN_ROOT.
# Falls back to relative path from this script's location.
# BUSDRIVER_STATE_DIR: state-dir override, defaults to .claude.
# Source shared CLI library for _portable_timeout and resolve functions
_PLUGIN_ROOT="${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}}"
STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
# Constrain to a safe relative name (reject absolute/traversal/unsafe chars) so
# it is safe to use as a path segment (e.g. under $HOME) below.
case "$STATE_DIR" in ""|/*|*..*|*[!a-zA-Z0-9._/-]*) STATE_DIR=".claude" ;; esac
# Re-export so the sourced resolve-cli.sh reads the sanitized value when it
# builds its $STATE_DIR config/log paths rather than a raw BUSDRIVER_STATE_DIR.
export BUSDRIVER_STATE_DIR="$STATE_DIR"
_BD_RESOLVE_CLI_SOURCED=0
if [[ -f "$_PLUGIN_ROOT/scripts/lib/resolve-cli.sh" ]]; then
  # shellcheck source=scripts/lib/resolve-cli.sh
  # shellcheck disable=SC1091  # runtime-resolved plugin root; not followable without -x
  source "$_PLUGIN_ROOT/scripts/lib/resolve-cli.sh"
  _BD_RESOLVE_CLI_SOURCED=1
fi

# Fallback if resolve-cli.sh not found
if ! type _portable_timeout &>/dev/null; then
  _portable_timeout() { timeout "$@"; }
fi
if [[ "$_BD_RESOLVE_CLI_SOURCED" != 1 ]]; then
  # Empty is the NORMAL value for the prose lane, not a refusal signal: it
  # means "pass no --model", i.e. agy's own configured model. So a missing
  # library degrades this lane to exactly its documented default rather than
  # aborting.
  _BD_WRITING_PROSE_MODEL=""
  resolve_writing_prose_model() { _BD_WRITING_PROSE_MODEL=""; }
fi
# The grok preflight lives in resolve-cli.sh, and this file deliberately
# tolerates that library being absent. Each helper is shimmed on ITS OWN name,
# not bundled behind another symbol's guard: a resolve-cli.sh from a different
# plugin version can define some of these and not others, and a shim that only
# installs when a DIFFERENT function is missing would be skipped in exactly
# that case. Then the grok arm calls an undefined function (status 127), takes
# the refusal branch anyway, and truncates $outfile to nothing — a voice
# reported `skipped` with no reason at all. Both shims fail CLOSED: no verified
# operator profile, no grok dispatch. Reported by CodeRabbit on PR #704.
# `declare -F`, not `type`: type also succeeds for an ALIAS, a BUILTIN, or any
# same-named EXECUTABLE on PATH, so a stray file called grok_sandbox_preflight
# would satisfy the guard, skip the fail-closed shim, and then be run as the
# verifier. This file already learned that once — see the agy transport
# helpers' guard and its comment.
if ! declare -F grok_sandbox_preflight >/dev/null; then
  grok_sandbox_preflight() { return 1; }
fi
# An older resolve-cli.sh has no auth check (#882): grok then runs as before, and
# an expired login stalls until the timeout. The sandbox boundary is unchanged.
if ! declare -F grok_auth_ready >/dev/null; then
  grok_auth_ready() { :; }
fi
# An older resolve-cli.sh has no prefetch: grok then runs without memory context.
if ! declare -F grok_hindsight_prefetch >/dev/null; then
  grok_hindsight_prefetch() { _GROK_HINDSIGHT_CTX=''; }
fi
if ! declare -F grok_preflight_hint >/dev/null; then
  grok_preflight_hint() {
    printf '%s\n' "Error: grok dispatch refused — the sandbox preflight is unavailable because scripts/lib/resolve-cli.sh could not be sourced, or is a version that does not provide it. This lane will not dispatch grok without verifying the operator's sandbox profile. Fix BUSDRIVER_PLUGIN_ROOT, or use --cli codex/agy."
  }
fi
# Ditto for the username allowlist (resolve-cli.sh owns the canonical copy —
# keep the pattern identical): a missing library must not make the prompt-home
# derivation below die with `command not found` under set -e.
if ! type _bd_valid_username &>/dev/null; then
  _bd_valid_username() {
    [[ -n "${1:-}" ]] || return 1
    case "$1" in
      *[!A-Za-z0-9._-]*) return 1 ;;
    esac
    [[ "$1" =~ ^[-+]?[0-9]*$ ]] && return 1
    return 0
  }
fi
# Fallback transient-error predicate (resolve-cli.sh owns the canonical one).
# Reads candidate output from stdin; returns 0 if it looks transient.
# 5xx is context-qualified (HTTP/status word or reason phrase) so incidental
# 3-digit runs like "line 503"/"port 5000" aren't misread as transient. Keep
# this regex identical to the canonical copy in scripts/lib/resolve-cli.sh.
if ! type _is_transient_cli_error &>/dev/null; then
  _is_transient_cli_error() {
    grep -qiE 'ECONNREFUSED|ECONNRESET|ETIMEDOUT|EPIPE|EAGAIN|socket hang up|fetch failed|rate.limit|overloaded|capacity|too many requests|(http|status|code|response)[^0-9]{0,6}(429|5[0-9][0-9])|internal server error|bad gateway|service unavailable|gateway time-?out|getaddrinfo'
  }
fi
# Strict transient signal — only unambiguous network/protocol/5xx error tokens
# (NOT the prose-ambiguous "rate.limit"/"overloaded"/"capacity"). HTTP reason
# phrases (bad gateway, service unavailable, gateway timeout, internal server
# error, too many requests) match ONLY when adjacent to their numeric status
# code, in either word order ("502 Bad Gateway" or "Bad Gateway (502)") so a
# bare phrase in clean exit-0 prose ("bad gateway handling looks correct") is
# treated as a review, not a transient notice. Mirrors _is_hard_transient_signal
# in resolve-cli.sh; used only for clean-exit output.
if ! type _is_hard_transient_signal &>/dev/null; then
  _is_hard_transient_signal() {
    grep -qiE 'ECONNREFUSED|ECONNRESET|ETIMEDOUT|EPIPE|EAGAIN|socket hang up|fetch failed|getaddrinfo|(http|status|code|response)[^0-9]{0,6}(429|5[0-9][0-9])|(429|5[0-9][0-9])[^0-9a-z]{0,4}(too many requests|bad gateway|service unavailable|gateway time-?out|internal server error)|(too many requests|bad gateway|service unavailable|gateway time-?out|internal server error)[^0-9a-z]{0,4}(429|5[0-9][0-9])'
  }
fi
# True (0) when output reads like a code review discussing an error term rather
# than being a bare error notice — freeform council prose has no "status"/"issues"
# envelope, so a terse valid reply naming an HTTP/5xx code would otherwise be
# retried away. Every term is review-assessment vocabulary absent from genuine
# error notices, so it cannot reclassify a true notice. Mirrors
# _reads_as_review_prose in resolve-cli.sh; keep the word list in sync.
if ! type _reads_as_review_prose &>/dev/null; then
  _reads_as_review_prose() {
    grep -qiE '\b(lacks?|looks (correct|good|fine|right|ok)|need(s|ed)? (a|an|to|more|tests?)|should (add|be|use|have|handle|return|check|verify|guard|consider)|consider|recommend|suggest|missing (a|an|tests?|guards?|checks?|coverage|handling)|edge case|refactor|rename|nit|LGTM|no issues|test coverage|docstring|assertion)\b'
  }
fi
# True (0) when an exit-0 output FILE is a bare transient-error notice
# masquerading as success: short AND carries a HARD transient signal (a machine
# error token, not a mere prose word). A real review/dispatch payload carrying the
# review schema (top-level "status" + "issues") is exempted up front — it may
# legitimately discuss a 5xx / network condition in a finding without being a
# notice. Freeform council prose that names an error term but carries review
# vocabulary is exempted too (_reads_as_review_prose). A bare error envelope like
# {"error":"ECONNRESET ..."} lacks both and still retries. Mirrors
# _is_bare_transient_notice in resolve-cli.sh; CLI_BARE_ERROR_MAX_CHARS and the
# exemptions are kept in sync.
if ! type _is_bare_transient_notice_file &>/dev/null; then
  _is_bare_transient_notice_file() {
    local f="$1" sz
    sz=$(wc -c < "$f" 2>/dev/null | tr -d '[:space:]')
    [[ "${sz:-0}" -le "${CLI_BARE_ERROR_MAX_CHARS:-512}" ]] || return 1
    # Review schema present → a verdict, not a notice. Never bare.
    if grep -qiE '"status"[[:space:]]*:' "$f" && grep -qiE '"issues"[[:space:]]*:' "$f"; then
      return 1
    fi
    # Reads like a review discussing an error term → a verdict, not a notice.
    if _reads_as_review_prose < "$f"; then
      return 1
    fi
    _is_hard_transient_signal < "$f"
  }
fi

LOG_DIR="$HOME/$STATE_DIR/homunculus"
LOG_FILE="$LOG_DIR/dispatch-log.jsonl"

# ── Defaults ───────────────────────────────────
CLI="auto"
MODE="readonly"
# 600, raised from 300 when an in-tree read lane (pi-read, withdrawn in ADR 0060)
# measured successful traces at 315s and 307s — both would have been killed by
# the old default. Kept: a cap that kills its own successful runs reads as an
# unreliable model when it is really a misconfigured number.
#
# Raised globally rather than per-CLI on purpose. `_portable_timeout` is a CAP,
# not a wait: an arm that finishes in 30s is unaffected, so the only cost is that
# a genuinely HUNG voice now takes 600s to kill instead of 300s. Paying that on
# the rare hang is far cheaper than a per-arm value threaded through the shared
# retry budget and agy's four `--print-timeout` sites.
#
# A caller running this BLOCKING needs its own timeout above this one, with room
# for startup and cleanup. Do NOT copy litmus's "600s harness cap" reasoning here
# — that number is specific to LITMUS_TIMEOUT's own budget, not a property of the
# Bash tool, whose ceiling is set by BASH_MAX_TIMEOUT_MS (3600000ms here).
TIMEOUT=600
MODEL=""
PROMPT=""
# Reporting/audit identity for the single-dispatch path. MUST be initialized
# here, unconditionally, and NOT read as an inherited environment variable: it
# feeds the dispatch-log.jsonl entry and the saved-output FILENAME, so an
# inherited value would let a caller both falsify the provider identity in the
# audit trail and inject path components into that filename — on every
# invocation, not just this lane's. A committed `.claude/settings.json` `env`
# block is repo-controlled (#325 / ADR 0016), which is exactly why an ambient
# value must never reach a provenance field. Only the desugar below sets it.
REPORT_CLI_NAME=""

# ── Parse args ─────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cli)     CLI="$2";     shift 2 ;;
        --mode)    MODE="$2";    shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --model)   MODEL="$2";   shift 2 ;;
        --prompt)  PROMPT="$2";  shift 2 ;;
        -h|--help)
            cat <<'USAGE'
dispatch.sh — Dispatch tasks to Codex, Antigravity (agy), or Grok CLI

FLAGS:
  --cli     codex|agy|agy-prose|grok|both|all|auto  (default: auto)
  --mode    readonly|auto           (default: readonly)
  --timeout seconds                 (default: 600)
  --model   model override          (optional)
  --prompt  "task description"      (or pipe via stdin)

USAGE
            exit 0 ;;
        *) echo "Unknown: $1" >&2; exit 1 ;;
    esac
done

# Read prompt from stdin if not provided via flag
if [[ -z "$PROMPT" ]]; then
    if [[ ! -t 0 ]]; then
        # Cross-platform: use perl timeout if GNU timeout unavailable (macOS)
        if command -v timeout &>/dev/null; then
            PROMPT=$(timeout 5 cat 2>/dev/null || true)
        else
            PROMPT=$(perl -e 'alarm 5; while(<STDIN>){print}' 2>/dev/null || cat 2>/dev/null || true)
        fi
    else
        echo "Error: No prompt. Use --prompt or pipe via stdin." >&2
        exit 1
    fi
fi
[[ -z "$PROMPT" ]] && { echo "Error: Empty prompt." >&2; exit 1; }

# Write prompt to temp file (avoids shell escaping with long prompts)
# Prompt file under the PASSWORD-DB home (derived once, top-level): $HOME and
# ${TMPDIR} are both repo-injectable (a fork's settings.json) — a prompt file
# placed there would land in an attacker-selected location. `id` absolute;
# `eval` runs in the function-clean (-p shebang) top level.
_bd_pt_user="$(/usr/bin/id -un 2>/dev/null)"
# shellcheck disable=SC2310  # predicate by design — set -e off in || is intended
_bd_valid_username "$_bd_pt_user" || _bd_pt_user=""
if [[ -z "$_bd_pt_user" ]]; then
  # Fail CLOSED on an empty user: the following `~` expansion would fall back
  # to the repo-injectable $HOME and place the prompt in an attacker-selected
  # location.
  echo "Error: could not derive the operator user from the password database — refusing to dispatch." >&2
  exit 1
fi
_bd_pt_home="$(eval echo "~${_bd_pt_user}" 2>/dev/null)"
if [[ -z "$_bd_pt_home" || ! -d "$_bd_pt_home" ]]; then
  echo "Error: could not derive a trusted home from the password database — refusing to dispatch (cannot place the prompt file safely)." >&2
  exit 1
fi
PROMPT_FILE=$(/usr/bin/mktemp "$_bd_pt_home/.busdriver-dispatch-prompt-XXXXXX")
# #803: compose the staged-lib cleanup — this script sources resolve-cli.sh BEFORE
# installing this trap, so the library's own EXIT handler is registered and then
# overwritten here. Without composing, the ~250KB staged copy is left in TMPDIR on
# every invocation. See run-review-loop.sh for the same composition.
trap 'rm -f "$PROMPT_FILE"; declare -F _bd803_cleanup_review_lib_exec >/dev/null && _bd803_cleanup_review_lib_exec || true' EXIT
printf '%s' "$PROMPT" > "$PROMPT_FILE"

# ── CLI detection ──────────────────────────────
_has_cli() {
  if type is_cli_available &>/dev/null; then
    is_cli_available "$1"
  else
    command -v "$1" &>/dev/null
  fi
}


if [[ "$CLI" == "auto" ]]; then
    if _has_cli codex; then CLI="codex"
    elif _has_cli agy; then CLI="agy"
    # grok is intentionally excluded from --cli auto. Since 2026-08-19 its
    # containment IS enforceable from code (--sandbox busdriver-review + the
    # Bash/Edit/MCPTool denies + the vendor-hook switches), so the old "documented but unenforceable" rationale no longer
    # applies — the exclusion now stands on scope alone: grok still transmits
    # externally and still has open web tools, so silently selecting it via
    # auto would extend its exposure to contexts whose threat model wasn't
    # reviewed.
    # Use --cli grok explicitly (or set BUSDRIVER_REVIEW_CLI=grok) to opt in.
    # This mirrors the resolve-cli.sh auto-detect exclusion.
    else echo "Error: No supported CLI found (tried codex, agy). grok is excluded from auto-selection; use --cli grok to opt in explicitly." >&2; exit 1; fi
elif [[ "$CLI" == "pi" || "$CLI" == "pi-read" ]]; then
    # Exact match only. Withdrawn (ADR 0060): a stale caller gets a migration
    # message instead of the generic "invalid --cli value", and nothing runs.
    echo "busdriver: --cli $CLI was withdrawn (ADR 0060). Read code with codegraph_explore or an Explore subagent, or dispatch --cli codex / --cli agy." >&2; exit 1
elif [[ "$CLI" != "codex" && "$CLI" != "agy" && "$CLI" != "agy-prose" && "$CLI" != "grok" && "$CLI" != "both" && "$CLI" != "all" ]]; then
    echo "Error: Invalid --cli value '$CLI'. Must be codex|agy|agy-prose|grok|both|all|auto." >&2; exit 1
fi

# ── `agy-prose` — the agy PROSE-DRAFTING lane ───────────────────
# Desugars to the ordinary agy arm with three things pinned, so there is ONE agy
# implementation to maintain rather than two that drift:
#   readonly mode  → `agy --sandbox` (never --dangerously-skip-permissions)
#   $MODEL         → `.writing_prose.model`, but UNSET IS NORMAL here (see
#                    resolve_writing_prose_model) — no shipped default, no abort
#   guard workspace → the lane's write boundary (`_agy_guarded`, agy arm below)
#
# Why a lane: the operator's `.writing_prose.model` choice decides which third
# party sees the brief. A failed dispatch fails; nothing re-sends it elsewhere.
#
# CALIBRATE the write boundary: the guard is a PreToolUse hook agy runs, not a
# kernel sandbox — best-effort defense in depth, NOT write-PROOF. (`--mode plan`,
# the previous boundary, was measured writing under always-proceed on
# 2026-10-10.) Nothing in this dispatcher offers an enforced write boundary for agy.
#
# RESIDUALS — deliberately NOT closed here, because they are properties of this
# dispatcher shared by every lane, and closing them piecemeal in one lane buys
# nothing while the larger hole stays open. Named so nobody reads the guards
# above as a complete boundary:
#   * `agy` is invoked as a BARE command word, resolved through the ambient,
#     repo-injectable PATH. PATH is not pinned because agy normally lives outside
#     the system paths (~/.local/bin). An attacker who controls PATH therefore
#     owns the transport regardless of how carefully mktemp/git are resolved
#     above — those are hardened for consistency, not because they are the
#     boundary.
#   * `$HOME/.claude` (logs) and `~/.gemini` (agy's own state) are not
#     proven to lie outside the checkout. A home directory that IS a worktree, or
#     a state dir symlinked into one, still receives writes.
# Both apply equally to the reviewer slots. The lane's own
# claim is narrower and is what the guards above actually enforce: it does not
# write to the repository through $TMPDIR, and it does not silently change which
# third party receives your prose.
if [[ "$CLI" == "agy-prose" ]]; then
    # Preserve the REQUESTED lane name for reporting (output filename, console
    # status line, dispatch-log.jsonl entry) before CLI is overwritten, because
    # the agy lanes differ in model and in which third party receives content,
    # so an audit entry saying plain "agy" cannot tell which lane sent it.
    # Dispatch mechanics stay on the shared `agy` arm; only the reporting
    # identity changes.
    REPORT_CLI_NAME="agy-prose"
    CLI="agy"
    # Validate BEFORE normalising, so an invalid --mode is reported rather than
    # silently swallowed by an unconditional MODE="readonly".
    if [[ "$MODE" == "auto" ]]; then
        echo "Error: --cli agy-prose is the prose lane; --mode auto is not accepted. Use --cli agy --mode auto for a writing agy dispatch." >&2; exit 1
    elif [[ "$MODE" != "readonly" ]]; then
        echo "Error: Invalid --mode '$MODE'. --cli agy-prose accepts only readonly." >&2; exit 1
    fi
    MODE="readonly"
    # $HOME must be password-DB-derived, not inherited — the requirement of every
    # lane that ships content to a configured provider. An inherited $HOME is
    # repo-injectable (a checkout's `.claude/settings.json` can set it), and it
    # selects BOTH `.writing_prose.model` — i.e. WHICH THIRD PARTY the brief is
    # shipped to — and agy's own ~/.gemini config, auth, and persisted
    # conversation state. With an inherited $HOME the agy child reads its config,
    # auth and tool settings from a repo-selected directory (Codex P1 on PR #687).
    # The derived value is EXPORTED, not prefixed onto one call, so every agy
    # exec site is covered uniformly.
    # shellcheck disable=SC2310  # `! fn` condition shape; the else-branch IS
    # the failure handler.
    if ! _agyp_user="$(/usr/bin/id -un 2>/dev/null)" \
       || ! _bd_valid_username "$_agyp_user" \
       || ! _agyp_home="$(eval echo "~${_agyp_user}" 2>/dev/null)" \
       || [[ -z "$_agyp_home" || "$_agyp_home" != /* || ! -d "$_agyp_home" ]]; then
        echo "Error: could not derive a trusted \$HOME for the agy prose lane. Refusing rather than letting an inherited \$HOME select agy's config and ~/.gemini state (and the busdriver.json that names the provider your prose is sent to)." >&2; exit 1
    fi
    export HOME="$_agyp_home"
    # LOG_DIR/LOG_FILE were computed from the INHERITED $HOME far above (see
    # their assignment near the top of this file), so pinning $HOME here is too
    # late for them on its own. A repo-controlled $HOME would otherwise put
    # `$STATE_DIR/homunculus` inside the checkout — and the failure path
    # archives up to 64KB of the OUTPUT there, i.e. the prose itself. Recompute
    # both against the trusted home.
    # $STATE_DIR is PINNED to `.claude` here, not reused: BUSDRIVER_STATE_DIR is
    # repo-injectable, and no shape-check makes an injectable value safe when the
    # checkout normally lives UNDER the trusted home — `src/project/.drafts`
    # resolves straight back inside the repository. Same reasoning, verbatim, as
    # the state-dir pin in _bd_read_lane_model.
    LOG_DIR="$_agyp_home/.claude/homunculus"
    LOG_FILE="$LOG_DIR/dispatch-log.jsonl"
    # $TMPDIR is repo-injectable for the SAME reason $HOME is, and it is not
    # cosmetic here: OUT_DIR is `${TMPDIR:-/tmp}`, so the DRAFT ITSELF is written
    # there. A checkout that points $TMPDIR at itself would collect every draft
    # inside the repository — precisely the write this lane says does not happen,
    # and a path by which prose could reach a commit. Refuse rather than write.
    #
    # Deliberately a CONTAINMENT check, not a reassignment to /tmp: on macOS the
    # inherited per-user $TMPDIR is mode-700 under /var/folders, so forcing the
    # world-readable /tmp would trade a write-location bug for a confidentiality
    # regression. Keep the operator's temp dir; reject only one that is inside
    # the tree being written in.
    # No "unusable $TMPDIR" branch here on purpose: a nonexistent or non-directory
    # $TMPDIR already aborts the script further up (verified — both shapes exit 1
    # before this point), so such a branch could never execute, and a guard that
    # cannot fire certifies a check it never ran. Only the reachable case is
    # guarded.
    # Compare against the REPO ROOT, not $PWD. Dispatching from `/repo/docs`
    # with TMPDIR=/repo/.drafts is still a write into the repository, and a
    # CWD-only test waves it through. Fall back to $PWD only when this is not a
    # git checkout, where $PWD is the best containment boundary available.
    umask 077
    # `|| _agyp_tmp_real=""` is REQUIRED under `set -e`: a nonexistent or
    # non-directory $TMPDIR makes the `cd` fail, and an unguarded assignment
    # kills the dispatch at exit 128 with NO message — which is exactly the
    # silent failure this branch exists to replace.
    _agyp_tmp_real=""
    _agyp_tmp_real="$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)" || _agyp_tmp_real=""
    if [[ -z "$_agyp_tmp_real" ]]; then
        echo "Error: \$TMPDIR ('${TMPDIR:-/tmp}') is not a usable directory. Refusing rather than guessing where your prose is written." >&2; exit 1
    fi
    # The git lookup runs with GIT_* SCRUBBED and a system-only PATH. Both are
    # repo-injectable, and an unscrubbed lookup is worse than none: with
    # GIT_WORK_TREE=/tmp, `rev-parse --show-toplevel` cheerfully reports /tmp,
    # the containment test passes, and the draft lands in the checkout — the
    # attacker chooses the boundary they are being measured against.
    # `env -i`, NOT a -u list. An enumerated denylist is the wrong shape here:
    # it silently misses whatever it does not name, and git honours far more than
    # the obvious five — GIT_TRACE, GIT_TRACE2, GIT_TRACE2_EVENT and friends take
    # a PATH and make `rev-parse` WRITE a trace file there, so a repo-set trace
    # variable turns this very containment check into the repository write it
    # exists to prevent. Wiping the environment is the only shape that cannot be
    # out-enumerated; it also clears the exported-function table (functions ARE
    # environment variables), so git's own name cannot be shadowed.
    # `|| _agyp_root=""` is REQUIRED, not defensive noise: this script runs under
    # `set -e`, and outside a git checkout `rev-parse` exits non-zero, killing the
    # whole dispatch at exit 128 with no message — which would break exactly the
    # standalone prose tasks (an email, a paragraph) this lane exists for, and
    # would make the $PWD fallback below unreachable dead code.
    _agyp_root=""
    _agyp_root="$(/usr/bin/env -i \
        PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
        HOME="$_agyp_home" \
        git rev-parse --show-toplevel 2>/dev/null)" || _agyp_root=""
    _agyp_cwd_real="$(pwd -P)"
    # If git could not answer — not installed, `safe.directory` refusal, damaged
    # metadata — do NOT silently degrade to a $PWD-only check: that is precisely
    # the `<root>/docs` + TMPDIR=`<root>/.drafts` case this boundary exists for,
    # and an attacker who can break the git lookup would get the weaker check for
    # free. Fall back to walking up for a `.git` entry, which needs no external
    # command and cannot be redirected by GIT_* or PATH.
    # Walk to the OUTERMOST enclosing repository, not the nearest. `git
    # rev-parse` reports the innermost, so inside a submodule or a nested
    # checkout the superproject sits ABOVE it — and a $TMPDIR pointing into that
    # superproject is outside both the submodule root and $PWD, slipping through
    # while still writing prose into a repository. Keep walking, keep the last
    # match. Needs no external command, so GIT_* and PATH cannot redirect it.
    _agyp_walk="$_agyp_cwd_real"
    while [[ -n "$_agyp_walk" && "$_agyp_walk" != "/" ]]; do
        [[ -e "$_agyp_walk/.git" ]] && _agyp_root="$_agyp_walk"
        _agyp_walk="${_agyp_walk%/*}"
    done
    # Check BOTH boundaries, never the git root alone. $PWD is derived from the
    # kernel and cannot be redirected by the repo, so it holds even if the git
    # lookup is defeated or unavailable; the root only WIDENS coverage (a
    # dispatch from `<root>/docs` with TMPDIR=`<root>/.drafts`).
    _agyp_root_real="$(cd "${_agyp_root:-$_agyp_cwd_real}" 2>/dev/null && pwd -P)"
    [[ -n "$_agyp_root_real" ]] || _agyp_root_real="$_agyp_cwd_real"
    if [[ "$_agyp_tmp_real" == "$_agyp_root_real" || "$_agyp_tmp_real" == "$_agyp_root_real"/* \
       || "$_agyp_tmp_real" == "$_agyp_cwd_real" || "$_agyp_tmp_real" == "$_agyp_cwd_real"/* ]]; then
        echo "Error: \$TMPDIR ('$_agyp_tmp_real') is inside the repository ('$_agyp_root_real'). Drafts are written to \$TMPDIR, so this would leave prose in the repository. Unset \$TMPDIR or point it outside the checkout." >&2; exit 1
    fi
    # Re-point $TMPDIR at a PRIVATE per-run directory. OUT_DIR is derived from
    # $TMPDIR far below, and the draft filename is
    # `dispatch-agy-prose-<time>-<pid>.txt` — predictable enough that on a shared
    # $TMPDIR (unset, or `/tmp`) another user can pre-create that path, or a
    # symlink at it, and either read the prose or redirect the write onto a file
    # the operator can clobber. `umask 077` alone does not close that: it governs
    # the mode of a file CREATED here, not who got to the name first.
    #
    # `mktemp -d` gives an unpredictable name at mode 0700, so there is nothing to
    # pre-create and nothing for another user to traverse. Created UNDER the
    # caller's $TMPDIR, so it inherits the containment decision just made rather
    # than reopening it. Left in place on exit like every other dispatch output —
    # this lane preserves its artifacts deliberately.
    # The 0700 mode protects the directory's CONTENTS, not its ENTRY in the
    # parent: anyone who can write the parent can rename our directory away and
    # substitute their own holding the predictable output filename.
    #
    # An earlier revision accepted "ours (-O) OR sticky (-k)". That is unsound in
    # both directions — an ATTACKER-owned sticky directory still lets its owner
    # rename our entry, and an operator-owned but group/world-writable directory
    # lets any co-writer do it. Sticky is not a substitute for exclusive write
    # access; it only stops non-owners deleting each OTHER's entries.
    #
    # So require BOTH: the parent is ours, AND no one else can write it. One
    # rule, no OR to erode. `-O` is a bash builtin; the permission digits come
    # from the shell's own `stat`-free `[[ -w ]]`-adjacent tests via a subshell-
    # free ls-free check on the mode bits, done with builtins only so no extra
    # PATH-resolved command word is introduced.
    #
    # Consequence to know: a root-owned sticky /tmp (the Linux default when
    # $TMPDIR is unset) is REFUSED, deliberately. For a lane carrying prose the
    # operator may not want co-tenants reading, "point $TMPDIR somewhere private"
    # is the correct instruction, not a bug. macOS's per-user $TMPDIR passes.
    _agyp_mode=""
    _agyp_mode="$(/usr/bin/stat -f '%Lp' "$_agyp_tmp_real" 2>/dev/null \
        || /usr/bin/stat -c '%a' "$_agyp_tmp_real" 2>/dev/null)" || _agyp_mode=""
    if [[ ! -O "$_agyp_tmp_real" || -z "$_agyp_mode" || "${_agyp_mode: -2}" != "00" ]]; then
        echo "Error: \$TMPDIR ('$_agyp_tmp_real') must be a directory you own with no group/other write access — otherwise another user can substitute the directory your prose is written into. Point \$TMPDIR at a private directory (e.g. mkdir -m 700 ~/.prose-tmp)." >&2; exit 1
    fi
    _agyp_outdir=""
    # Absolute /usr/bin/mktemp, not a bare command word — PATH is repo-injectable,
    # and this file already resolves mktemp absolutely for PROMPT_FILE. Calibrate
    # what that buys: `agy` itself is still invoked as a bare word through the
    # same PATH (see the residuals note in the lane header), so this closes one
    # hole inside a larger one rather than making the lane PATH-proof.
    _agyp_outdir="$(/usr/bin/mktemp -d "${_agyp_tmp_real}/busdriver-prose-XXXXXX")" || _agyp_outdir=""
    if [[ -z "$_agyp_outdir" || ! -d "$_agyp_outdir" ]]; then
        echo "Error: could not create a private output directory under '$_agyp_tmp_real'. Refusing rather than writing your prose to a predictable, shared path." >&2; exit 1
    fi
    export TMPDIR="$_agyp_outdir"
    # An explicit --model still wins; the config is the default, not a clamp.
    # Empty stays empty on purpose — see resolve_writing_prose_model.
    if [[ -z "$MODEL" ]]; then
        # Mixed-version tolerance. The stub far above is installed only when the
        # library was not sourced AT ALL; an OLDER but sourceable resolve-cli.sh
        # (a stale BUSDRIVER_PLUGIN_ROOT) sources fine yet has no
        # resolve_writing_prose_model — and a bare call would then resolve to an
        # ambient PATH executable of that name, or die with command-not-found,
        # instead of taking this lane's documented empty-model default.
        # `declare -F` accepts functions only.
        if ! declare -F resolve_writing_prose_model >/dev/null 2>&1; then
            resolve_writing_prose_model() { _BD_WRITING_PROSE_MODEL=""; }
        fi
        HOME="$_agyp_home" resolve_writing_prose_model
        MODEL="$_BD_WRITING_PROSE_MODEL"
        # ABSENT and INVALID must not look alike. Both resolve empty above — an
        # unset key, and a value the `bare` grammar rejected (a `provider/id`
        # pasted from another lane's config, a typo). Empty is this lane's NORMAL "use
        # agy's own model", so without this the operator's pin silently does not
        # apply and the prose runs on a model they did not pick.
        #
        # The presence probe goes through the SAME hardened reader (`env -i`,
        # absolute parser paths). An earlier revision used `_read_config_value`
        # for this and that was the wrong trade: it selects `jq`/`python3` off the
        # ambient, repo-injectable PATH as bare command words, introducing a
        # code-execution surface to protect a provider selection.
        if [[ -z "$MODEL" ]] && declare -F resolve_writing_prose_raw >/dev/null 2>&1; then
            HOME="$_agyp_home" resolve_writing_prose_raw
            if [[ -n "$_BD_WRITING_PROSE_RAW" ]]; then
                echo "Error: .writing_prose.model is set to '$_BD_WRITING_PROSE_RAW', which is not a valid bare agy model id (no 'provider/' prefix; \`agy models\` enumerates ids). Refusing rather than silently dispatching your prose on a model you did not choose. Fix or remove the key." >&2; exit 1
            fi
        fi
        # Residual, stated so the guard above is not read as total: a present but
        # NON-STRING value (number, bool) is dropped by both readers' string
        # filters and so still looks absent. The fallback in that case remains
        # agy's own configured model — the operator's own choice, never one an
        # attacker selected, since the rejected value is precisely the one that
        # never gets used.
        # An earlier revision added one via `_read_config_value` and it was the
        # wrong trade: that reader selects `jq`/`python3` off the ambient,
        # repo-injectable PATH and resolves them as bare command words, so the
        # check meant to protect the provider selection introduced a fresh
        # code-execution surface — a weaker reader layered on top of the hardened
        # one (`_bd_read_lane_model`, which uses `env -i` and absolute binary
        # paths) purely to improve an error message.
        #
        # What is actually lost by not checking: a MALFORMED `.writing_prose.model`
        # is rejected by the `bare` grammar, resolves empty, and the dispatch runs
        # on agy's OWN configured model. That is a surprise, not a breach — the
        # fallback is the operator's own agy configuration, never a value an
        # attacker chose, because the rejected value is precisely the one that
        # never gets used. Silent-substitution risk is nil; the cost is a pin that
        # quietly does not apply. `agy models` lists valid bare ids.
    fi
fi

# Validate mode
[[ "$MODE" != "readonly" && "$MODE" != "auto" ]] && { echo "Error: Invalid --mode '$MODE'. Must be readonly|auto." >&2; exit 1; }

# Validate timeout is a positive integer (F30 fix)
if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT" -eq 0 ]]; then
    echo "Error: --timeout must be a positive integer (got '$TIMEOUT')." >&2; exit 1
fi

# Validate availability — "both" mode degrades gracefully (F31 fix)
if [[ "$CLI" == "both" ]]; then
    if ! _has_cli codex && ! _has_cli agy; then
        echo "Error: Neither codex nor agy found." >&2; exit 1
    elif ! _has_cli codex; then
        echo "Warning: codex not found, falling back to agy only." >&2
        CLI="agy"
    elif ! _has_cli agy; then
        echo "Warning: agy not found, falling back to codex only." >&2
        CLI="codex"
    fi
else
    [[ "$CLI" == "codex" ]] && ! _has_cli codex && { echo "Error: codex not found." >&2; exit 1; }
    [[ "$CLI" == "agy" ]] && ! _has_cli agy && { echo "Error: agy not found." >&2; exit 1; }
    # grok is deliberately NOT gated on `_has_cli` (ambient PATH). Execution
    # runs it from a PINNED path, so an install that exists only in, say,
    # ~/.grok/bin — not on the caller's PATH — would be rejected here as "not
    # found" while the pinned lookup would have found it, contradicting the
    # preflight's own remediation hint. Reported by Codex on PR #704.
    # grok_sandbox_preflight owns this: it looks in exactly the directories the
    # dispatch will use, and refuses with a reason that says which one failed.
    # Checking availability twice, against two different path sets, is what
    # produced the contradiction.
fi

# Handle --cli all: discover all available supported CLIs (candidates codex,
# agy, grok; the cap of 3 equals the list). When MODE=auto,
# grok is excluded — the grok adapter rejects auto mode at dispatch_one
# time, and including it here would kill the entire batch mid-stream after
# the other CLIs had already launched in parallel.
if [[ "$CLI" == "all" ]]; then
    ALL_CLIS=()
    for c in codex agy grok; do
        [[ "$c" == "grok" && "$MODE" == "auto" ]] && continue
        # grok is included WITHOUT an ambient-PATH probe, for the same reason the
        # direct `--cli grok` gate no longer has one: it runs from a pinned path,
        # so a pinned-only install (~/.grok/bin not on PATH) would be silently
        # dropped from the batch and never reach its own preflight. Including it
        # costs nothing when it is unusable — the preflight refuses with a named
        # reason and the voice is marked `skipped`, which is exactly how a batch
        # is meant to treat a voice that cannot run. Reported by Codex on PR #704.
        if [[ "$c" == "grok" ]]; then ALL_CLIS+=("$c"); continue; fi
        _has_cli "$c" && ALL_CLIS+=("$c")
        [[ ${#ALL_CLIS[@]} -ge 3 ]] && break
    done
    if [[ ${#ALL_CLIS[@]} -eq 0 ]]; then
        echo "Error: No CLIs found for --cli all." >&2; exit 1
    fi
fi

# ── Helpers ────────────────────────────────────
strip_ansi() {
    perl -pe 's/\e\[[0-9;]*[a-zA-Z]//g' 2>/dev/null || cat
}

# Args: cli_name status duration output_file
log_event() {
    # `|| true`: this helper is best-effort by contract, and it now runs BEFORE
    # the dispatch output is emitted. An unguarded `mkdir` under `set -e` would
    # therefore let an unwritable or invalid state dir suppress a COMPLETED CLI
    # result entirely — logging failing closed over the very output it exists to
    # annotate. Everything below already tolerates a missing directory.
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    local ts _logged_out="$4"
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    # PRESERVE THE EVIDENCE OF A FAILED RUN. Output files live in $TMPDIR, which
    # the OS reaps and a reboot wipes — so a failure's only diagnostic routinely
    # vanishes before anyone reads it, leaving a log line that says `error` and
    # points at a path that no longer exists. That is exactly what happened to a
    # 465s dispatch failure whose cause is now unrecoverable.
    #
    # Copy on `error`/`timeout` ONLY. A `skipped` run is deterministic by
    # construction (its reason is a fixed message this script itself wrote), so it
    # needs no forensics; the gap worth closing is the NON-deterministic class.
    # `success` is excluded for the obvious reason — it would archive every
    # dispatch this repo ever makes.
    #
    # Best-effort throughout: on any failure the ORIGINAL path is logged
    # unchanged. Preserving a diagnostic must never fail a dispatch that worked.
    #
    # All three call sites run in the SEQUENTIAL result loops, never inside the
    # backgrounded `dispatch_one &` jobs, so there are no concurrent writers.
    #
    # keep-simple(UPGRADE: prune oldest when failures/ exceeds ~200 files): the
    # directory grows without bound. Each entry is <=64KB and failures are rare;
    # revisit only if it becomes real disk pressure.
    if [[ "$2" == "error" || "$2" == "timeout" ]] && [[ -f "$4" ]]; then
        local _fdir="$LOG_DIR/failures" _fdest
        _fdest="$_fdir/$(basename "$4")"
        # PERMISSIONS ARE PART OF THE FIX, not decoration. The original lives in
        # $TMPDIR, which is per-user mode-700 on macOS; copying it under $HOME at
        # the caller's umask (commonly 022 ⇒ 0644) would DOWNGRADE a protected
        # file to one any local user traversing the home directory can read — and
        # the content is model output, i.e. repo source and whatever a diagnostic
        # happened to quote. mode-700 dir + umask 077 for the file keeps the copy
        # no more exposed than the original.
        #
        # TAIL, not head: a CLI writes progress and generated output first and
        # appends the fatal error LAST to combined stdout+stderr, so on an output
        # past the cap `head` would preserve everything except the failure cause
        # this archive exists to keep. The last 64KB is the part worth having.
        # UNLINK BEFORE WRITING. `>` FOLLOWS a symlink, and the destination
        # basename is predictable, so a link planted in a previously
        # group-writable failures/ would redirect this truncating write onto an
        # arbitrary file the operator can write. `chmod 700` does not remove an
        # entry that is already there — it only stops NEW ones. `rm -f` unlinks
        # the symlink itself rather than following it, and the re-check refuses
        # to proceed if anything still occupies the path.
        # A failures/ owned by another user makes `chmod` fail, which short-
        # circuits this whole chain — fail-closed, no write attempted.
        # The DIRECTORY needs the same treatment as the file: `mkdir -p` succeeds
        # on an existing symlink-to-dir and `chmod` follows it, so a link planted
        # at failures/ would have us chmod an operator-owned directory elsewhere
        # and then unlink a predictable name inside it. Refuse a symlinked dir
        # outright rather than trying to make following one safe.
        #
        # SAME-FILE GUARD. If $TMPDIR ever IS this directory, source and
        # destination are one file, and the unlink below would delete the only
        # diagnostic before `tail` ever read it — archiving the evidence by
        # destroying it, the exact inverse of this block's purpose.
        # Two tests, because a string compare alone is not enough: `-ef` compares
        # DEVICE+INODE, so it also catches the aliases a string misses — a
        # trailing slash (`failures//x` vs `failures/x`) or a symlinked $TMPDIR.
        # It is a bash builtin, so this costs no command word. Applied to the
        # containing DIRECTORY via `${4%/*}` (parameter expansion, not `dirname`)
        # because the destination file itself does not exist yet.
        if [[ ! -L "$_fdir" ]] \
           && mkdir -p "$_fdir" 2>/dev/null && chmod 700 "$_fdir" 2>/dev/null \
           && [[ "$4" != "$_fdest" ]] \
           && ! [[ "${4%/*}" -ef "$_fdir" ]] \
           && rm -f "$_fdest" 2>/dev/null \
           && [[ ! -e "$_fdest" && ! -L "$_fdest" ]] \
           && ( umask 077; tail -c 65536 "$4" > "$_fdest" ) 2>/dev/null; then
            _logged_out="$_fdest"
        fi
    fi
    printf '{"ts":"%s","cli":"%s","mode":"%s","status":"%s","duration":%s,"prompt_len":%d,"output_file":"%s"}\n' \
        "$ts" "$1" "$MODE" "$2" "$3" "${#PROMPT}" "$_logged_out" >> "$LOG_FILE" 2>/dev/null || true
}

# Run "$@" (a readonly agy dispatch: the prose lane, council and reviewer slots)
# from a FRESH workspace holding the plugin's deny-by-default PreToolUse guard
# (scripts/lib/agy-review-guard/, the same pair `_agy_stream_review` in
# resolve-cli.sh stages — keep the two in step). This is the readonly write
# boundary. Measured 2026-10-10 on agy 1.3.2 under toolPermission always-proceed:
# from the checkout, both `--sandbox` and `--sandbox --mode plan` (the prose lane's
# previous boundary) wrote into it on request, while this guard denied both
# `write_to_file` and `call_mcp_tool`. The guard is best-effort defense in depth, NOT enforced
# containment (the limitation the operator accepted for the review rung on
# 2026-09-14), and it never runs from the checkout, whose own .agents/hooks.json
# agy would execute as host commands.
# Refuses rather than falling back to an unguarded run. "$@" must be a
# _portable_timeout call: it runs every checkout check (the agy pin, the timeout
# lookup) from the real CWD and enters the workspace only to launch, so the
# caller's redirects and `--add-dir "$PWD"` keep the real CWD too;
# that `--add-dir` is also what keeps Hindsight on the project's bank rather than
# one named after this workspace.
# shellcheck disable=SC2329,SC2154  # invoked via _agy_run; _bd_git is set by _bd_resolve_git
_agy_guarded() {
    local guard="$_PLUGIN_ROOT/scripts/lib/agy-review-guard" ws rc=0
    # A resolve-cli.sh from another plugin version can lack the launch-dir step and
    # would launch agy from the checkout, outside the guard.
    if ! declare -F _bd_pt_supports_launch_dir >/dev/null; then
        echo "Error: $_PLUGIN_ROOT/scripts/lib/resolve-cli.sh cannot launch agy in a guard workspace — refusing an unguarded agy dispatch." >&2
        return 1
    fi
    # A guard that cannot start returns no decision, which agy treats as allow.
    if [[ ! -f "$guard/hooks.json" || ! -f "$guard/guard.py" ]] \
       || ! /usr/bin/python3 -I -c 'import sys' >/dev/null 2>&1; then
        echo "Error: agy read-only guard unavailable ($guard, /usr/bin/python3) — refusing an unguarded agy dispatch." >&2
        return 1
    fi
    if ! ws="$(/usr/bin/mktemp -d /tmp/agy-review-guard.XXXXXX)"; then
        echo "Error: cannot create the agy guard workspace — refusing." >&2
        return 1
    fi
    # No signal trap removes $ws: timeout runs agy in its own process group, so agy
    # can outlive this shell, and deleting the guard under a live agy turns every
    # later tool call into an allow. A leftover mode-0700 /tmp dir is the safe failure.
    # Its own git root, so agy's customization walk stops at the workspace.
    if /bin/mkdir "$ws/.agents" \
       && /bin/cp "$guard/hooks.json" "$guard/guard.py" "$ws/.agents/" \
       && _bd_resolve_git \
       && _bd_run_clean "$_bd_git" -C "$ws" init -q >/dev/null 2>&1 \
       && [[ -d "$ws/.git" ]]; then
        ( _BD_PT_LAUNCH_DIR="$ws"; "$@" ) || rc=$?
    else
        echo "Error: cannot stage the agy guard workspace — refusing." >&2
        rc=1
    fi
    /bin/rm -rf -- "$ws"
    return "$rc"
}

# ── Single-CLI dispatch ───────────────────────
# Args: cli_name output_file
# Writes: status|duration|exit_code to meta_file
dispatch_one() {
    local name="$1" outfile="$2" meta="${2}.meta"
    local start exit_code=0
    start=$(date +%s)

    # ── Primary-CLI retry (council voices flake intermittently) ──────
    # Retry the primary CLI on a transient failure or empty output — a single
    # rate-limit/network hiccup shouldn't drop a council voice.
    # BUSDRIVER_CLI_RETRIES (default 3; council uses the default, blueprint
    # exports 5 via run-design-review-loop). A timeout (124) is never retried —
    # re-running the full window is too costly.
    local _max_retries="${BUSDRIVER_CLI_RETRIES:-3}"
    case "$_max_retries" in ''|*[!0-9]*) _max_retries=3 ;; esac
    # --cli all/both COMPARE CLIs on one prompt — a failure there is signal, not
    # a flake: no retries in those modes.
    [[ "$CLI" == "all" || "$CLI" == "both" ]] && _max_retries=0
    # NEVER retry in write-capable (auto) mode: the case arms below can run
    # `codex exec --full-auto` / `agy --dangerously-skip-permissions`, which may
    # edit files before exiting with a transient-looking error. Re-running the
    # same write prompt could double-apply or corrupt changes. Retries are only
    # safe for read-only review dispatches (the council voices, MODE=readonly).
    [[ "$MODE" != "readonly" ]] && _max_retries=0
    # Readonly dispatches (council voices, reviewers, the prose lane) READ the
    # project's Hindsight memory but never retain their sessions into it: a
    # dispatched voice's transcript is the dispatcher's prompt plus its own answer,
    # and retaining every one is what drained the Hindsight LLM quota (2026-10-09).
    # Pages, not reflect: reflect is an LLM call per prompt and timed out at 20s on
    # live reviews. Set explicitly, so an inherited value cannot turn retain back on.
    # Measured 2026-10-10 for codex and agy across every launch layer this script
    # uses (read pages from the right bank, `retain_disabled`, no new bank).
    # An inherited bank id would redirect reads, so it is dropped. An operator's
    # HINDSIGHT_DISABLED is honoured: turning Hindsight off is their call.
    # Claude Mem: this drops its per-tool observations (an observer LLM call each)
    # and its end-of-session summary, and keeps the session-start context read. grok launches under `env -i` and does not see
    # these; it sets its own.
    if [[ "$MODE" == "readonly" ]]; then
        unset HINDSIGHT_BANK_ID
        export HINDSIGHT_RETAIN_SESSIONS=false HINDSIGHT_AUTO_INJECT=pages CLAUDE_MEM_DISABLE_OBSERVATION=1 CLAUDE_MEM_DISABLE_SUMMARY=1
    fi
    local _retry_delay="${BUSDRIVER_CLI_RETRY_DELAY:-5}"
    case "$_retry_delay" in ''|*[!0-9]*) _retry_delay=5 ;; esac
    # Cleared per DISPATCH, for grok's refusals. A refusal there is a
    # deterministic precondition failure — the operator's profile is missing or
    # does not meet the contract — so it must not be retried, and must
    # not fail a whole batch for the other voices.
    local _grok_refused=0
    # Separate from `_grok_refused` ON PURPOSE. `_grok_refused` answers "how is
    # this voice REPORTED" (skipped vs error) and is therefore conditional on the
    # skip marker reaching "$outfile". This one answers "may grok be launched at
    # all", and must never depend on a filesystem write succeeding. Conflating
    # them meant an unwritable "$outfile" left _grok_refused=0 and the dispatch
    # gate below fell through into a real `--model` launch of the one CLI that
    # cannot accept --model. Reported by Cursor Bugbot on PR #704.
    local _grok_model_rejected=0
    local _attempt=0
    while [[ "$_attempt" -le "$_max_retries" ]]; do
    exit_code=0
    # The whole retry sequence — every attempt PLUS all backoff sleeps — is
    # bounded to ~TIMEOUT (the caller's --timeout budget): each attempt's timeout
    # is the REMAINING budget (equals "$TIMEOUT" on the first attempt) and each
    # backoff is capped to the remaining budget, so neither the sleep nor the
    # attempt can overrun. Retries thus can't multiply the wall-clock to
    # (retries+1)× the timeout.
    local _now _budget _cap
    if [[ "$_attempt" -eq 0 ]]; then
        # The FIRST attempt always runs with the full budget — set it directly
        # (not via now-start) so a sub-second clock tick can never zero it out and
        # drop the only attempt. Only RETRIES are budget-gated below.
        _budget="$TIMEOUT"
    else
        _now=$(date +%s); _budget=$(( TIMEOUT - (_now - start) ))
        # A retry needs budget for the backoff PLUS at least a 1s attempt; if the
        # remaining budget can't fund a 1s attempt, fall back now instead of
        # sleeping the rest of the budget away for a retry that can't run.
        if [[ "$_budget" -le 1 ]]; then
            echo "⟳ ${name}: retry budget (${TIMEOUT}s) spent — falling back instead of retrying" >&2
            [[ "$exit_code" -eq 0 ]] && exit_code=1
            break
        fi
        # Cap backoff to leave >= 1s for the attempt — never sleep the whole budget.
        _cap=$(( _budget - 1 ))
        [[ "$_retry_delay" -gt "$_cap" ]] && _retry_delay="$_cap"
        if [[ "$_retry_delay" -gt 0 ]]; then
            echo "⟳ ${name} retry ${_attempt}/${_max_retries} (waiting ${_retry_delay}s)..." >&2
            sleep "$_retry_delay"
        fi
        _retry_delay=$((_retry_delay * 2))
        _now=$(date +%s); _budget=$(( TIMEOUT - (_now - start) ))
        if [[ "$_budget" -le 0 ]]; then
            echo "⟳ ${name}: retry budget (${TIMEOUT}s) spent — falling back instead of retrying" >&2
            [[ "$exit_code" -eq 0 ]] && exit_code=1
            break
        fi
    fi

    case "$name" in
        codex)
            if [[ "$MODE" == "auto" ]]; then
                _portable_timeout "$_budget" codex exec --full-auto ${MODEL:+-m "$MODEL"} - \
                    < "$PROMPT_FILE" > "$outfile" 2>&1 || exit_code=$?
            else
                _portable_timeout "$_budget" codex exec -s read-only ${MODEL:+-m "$MODEL"} - \
                    < "$PROMPT_FILE" > "$outfile" 2>&1 || exit_code=$?
            fi ;;
        agy)
            # PROMPT DELIVERY (agy >= 1.1.x): `--print` takes the prompt TEXT as its
            # argument value. The old `--print /dev/stdin < "$PROMPT_FILE"` idiom worked
            # on v1.0.0, where the value was read as a path; on 1.1.4 it sends the
            # LITERAL string "/dev/stdin" and agy replies "It looks like you just sent
            # `/dev/stdin`" — valid prose, never JSON, so every blueprint-review agy slot
            # failed as "Output was not valid JSON" and silently degraded coverage to 2/3.
            # There is no file-input flag in 1.1.4 (`--help` lists only --log-file), and
            # bare `--print` errors with "flag needs an argument", so argv is the only
            # delivery path left. The ARG_MAX ceiling the old comment guarded against is
            # real but distant (blueprint prompts measure ~40-100 KB against a 1 MB
            # limit); the guard below fails LOUDLY rather than truncating silently if
            # that headroom ever shifts. --print-timeout stays aligned with the outer
            # timeout so agy's internal 5m default doesn't abort before _portable_timeout.
            # `--model` IS forwarded (agy >= 1.1 advertises it; verified live on
            # 1.1.13 against a pinned model id). The old refusal branch here
            # was a deliberate non-support decision left over from the prompt-delivery
            # fix, and its own comment carried the follow-up "wire $MODEL through and
            # drop this branch" — this is that. Unset $MODEL still means "agy's
            # configured model", so every existing caller is unaffected.
            # `agy models` enumerates ids.
            #
            # SCOPE NOTE — `--add-dir "$PWD"` is UNCONDITIONAL (#686), and that
            # is a scope decision, not a security one. agy resolves a remembered
            # workspace when unscoped (see below), and the reviewer slot shared
            # the defect: an unscoped `blueprint-review.reviewer_1` could return
            # findings about a DIFFERENT checkout than the one under review.
            # Every agy dispatch now selects the CWD as the workspace, so a
            # reviewer of record cannot cite a remembered foreign tree.
            #
            # What it is NOT is a containment boundary, and that is MEASURED
            # (2026-08-17): plain `agy --sandbox` with NO `--add-dir` was asked to
            # read /tmp/agy-scope-probe.txt — an absolute path outside the CWD — and
            # quoted its contents back. agy's reads are unconfined either way, so
            # `--add-dir` grants no access; it only selects WHICH tree is the
            # workspace. agy has never had an empty-directory confinement:
            # the reviewer slot has always run in the working tree, because
            # reviewing code requires reading it. The boundary that does apply is
            # unchanged and documented in SKILL.md: gate agy on WHO WROTE the
            # content.
            #
            # shellcheck disable=SC2310  # `_portable_timeout ... || exit_code=$?` is
            # the established shape of EVERY arm in this dispatcher; the retry loop
            # below consumes exit_code deliberately. Not introduced here.
            #
            # Workspace argv, built as an ARRAY so a $PWD containing spaces cannot
            # word-split; the `+` expansion form below keeps it safe under
            # `set -u` on bash 3.2.
            #
            # `--add-dir "$PWD"` selects the CWD as agy's workspace on EVERY agy
            # dispatch — the prose lane and the plain `--cli agy` reviewer slots
            # alike (#686). Every READONLY dispatch (both of those) runs from the
            # guard workspace (`_agy_guarded`), the write boundary: a plain readonly
            # agy run from the checkout wrote into it on request (measured
            # 2026-10-10). `_agy_run` is expanded only at the readonly call sites, so
            # `--mode auto` (the writing agent) never takes it. `--mode plan` is not
            # used here (it did not block writes under always-proceed either).
            local _agy_lane=(--add-dir "$PWD") _agy_run=(_agy_guarded)
            # `--add-dir "$PWD"` IS LOAD-BEARING. Without it agy does not scope
            # reads to the CWD: it resolves its own remembered workspace/project.
            # Measured 2026-08-17 dispatching from
            # /Volumes/Work/Projects/busdriver — agy silently answered from a stale
            # ~/src/busdriver checkout (v1.71.0), returning confident,
            # correctly-formatted file:line citations for the WRONG tree. That is
            # the worst failure shape available to a dispatch: it does not error,
            # it lies with citations. With --add-dir the same probe returned the
            # right absolute path and the right verbatim line.
            # Fail loudly before the kernel E2BIGs a prompt into another silent
            # "not valid JSON" degrade. The OS-dependent ceiling logic lives in
            # _agy_argv_limit/_agy_prompt_oversize (scripts/lib/resolve-cli.sh,
            # sourced above) so the two agy call sites cannot drift apart.
            # agy 1.0.x resolves --print's value as a PATH (so /dev/stdin works);
            # >=1.1 sends it verbatim. Branch on the probe in resolve-cli.sh so a
            # 1.0.x install is not broken by the argv switch.
            # HARD REQUIREMENT: the agy transport helpers live in resolve-cli.sh.
            # dispatch.sh tolerates that library being absent (see the
            # `_portable_timeout` fallback near the top), but this branch cannot:
            # with the helpers undefined, `if _agy_wants_argv_prompt` does NOT
            # abort under `set -e` (an undefined command in an `if` CONDITION is
            # exempt) — it silently takes the else branch, which is the agy 1.0.x
            # `--print /dev/stdin` path. On agy >=1.1 that reintroduces the exact
            # bug this code exists to fix, and it does so SILENTLY. Fail loudly
            # instead. Defining local copies here was the alternative and is
            # rejected: three duplicated helpers would drift from the originals,
            # which is the failure this repo already paid for once (see the
            # header of scripts/ack-ledger.sh).
            # `declare -F`, not `type`: type also succeeds for aliases, builtins,
            # and any same-named EXECUTABLE on PATH, so a stray file called
            # `_agy_argv_limit` would satisfy the guard while the real helpers
            # stayed undefined — passing the check and then silently taking the
            # 1.0.x branch, which is exactly what this guard exists to prevent.
            # declare -F matches shell FUNCTIONS only.
            if ! declare -F _agy_wants_argv_prompt >/dev/null \
               || ! declare -F _agy_prompt_oversize >/dev/null \
               || ! declare -F _agy_model_flag_supported >/dev/null \
               || ! declare -F _agy_argv_limit >/dev/null; then
                printf 'Error: agy transport helpers unavailable — %s/scripts/lib/resolve-cli.sh could not be sourced. Cannot choose argv-vs-stdin prompt delivery safely; refusing rather than silently using the 1.0.x path. Use --cli codex, or fix BUSDRIVER_PLUGIN_ROOT.\n' \
                    "$_PLUGIN_ROOT" > "$outfile" 2>&1
                exit_code=1
            elif [[ -n "$MODEL" ]] && ! _agy_model_flag_supported; then
                # A model was requested and this install is not KNOWN to support
                # `--model`. Two ways to land here, and both must refuse:
                #
                #   - a confirmed agy 1.0.x, which has no --model flag at all
                #     (SKILL.md, "agy v1.0.0 does not support --model"); and
                #   - an INCONCLUSIVE version probe (`agy --version` exceeded its
                #     2s budget, or printed something unparseable), which the
                #     transport default optimistically treats as modern.
                #
                # The second is why this branch sits BEFORE the transport
                # selection below rather than after it: assume-modern routes an
                # inconclusive probe down the argv path, which would forward
                # `--model` and skip a refusal placed further down the chain. A
                # 1.0.x stub whose `--version` sleeps 3s reproduces it (Codex P2
                # on PR #687); `_agy_model_flag_supported` is where the two argv
                # outcomes are told apart.
                #
                # Silently dropping --model instead would run the request on
                # agy's own default model without saying so — quietly asking a
                # DIFFERENT model than the operator configured.
                #
                # NOT lane-scoped (#689; Codex round 7 and Greptile both flagged
                # the lane-only form). The predicate is "a model was requested
                # and cannot be honoured", equally true of plain
                # `--cli agy --model X`, a path this PR made reachable when it
                # removed the blanket --model refusal. Plain `--cli agy` with NO
                # --model — the blueprint-review reviewer_1 and
                # council.pragmatist shape — leaves $MODEL empty, never enters
                # here, and still dispatches on any agy version.
                #
                # HARD `exit 1` TO STDERR, not `exit_code=1` into $outfile. This
                # is a CONFIG error, not a transient: it fails the dispatch,
                # which is the correct outcome for a config error.
                # stderr rather than $outfile because `exit` skips the tail that
                # prints the outfile, which would make the message invisible.
                # Same shape as the oversize-prompt guard below.
                local _agy_why
                if _agy_wants_argv_prompt; then
                    _agy_why="this agy install did not answer --version within the probe budget, so --model support is unconfirmed"
                else
                    _agy_why="this agy install does not support it (agy 1.0.x)"
                fi
                printf 'Error: --cli agy was given --model (%s), but %s — see %s/skills/dispatch-cli/SKILL.md. Upgrade agy, drop --model to use agy'"'"'s own configured model, or use --cli codex.\n' \
                    "$MODEL" "$_agy_why" "$_PLUGIN_ROOT" >&2
                exit 1
            elif _agy_wants_argv_prompt; then
                # shellcheck disable=SC2312  # `|| echo 0` IS the fallback; masking is intended
                _agy_size=$(wc -c < "$PROMPT_FILE" 2>/dev/null || echo 0)
                if _agy_prompt_oversize "$_agy_size"; then
                    echo "Error: prompt is ${_agy_size}B, over agy's argv ceiling ($(_agy_argv_limit)B). agy >=1.1 has no file-input flag; use --cli codex for prompts this large." >&2
                    exit 1
                fi
                _agy_prompt=$(cat "$PROMPT_FILE")
                if [[ "$MODE" == "auto" ]]; then
                    _portable_timeout "$_budget" agy --dangerously-skip-permissions \
                        --print-timeout "${TIMEOUT}s" ${MODEL:+--model "$MODEL"} \
                        "${_agy_lane[@]+"${_agy_lane[@]}"}" \
                        --print "$_agy_prompt" > "$outfile" 2>&1 || exit_code=$?
                else
                    "${_agy_run[@]+"${_agy_run[@]}"}" _portable_timeout "$_budget" agy --sandbox \
                        --print-timeout "${TIMEOUT}s" ${MODEL:+--model "$MODEL"} \
                        "${_agy_lane[@]+"${_agy_lane[@]}"}" \
                        --print "$_agy_prompt" > "$outfile" 2>&1 || exit_code=$?
                fi
            elif [[ "$MODE" == "auto" ]]; then
                _portable_timeout "$_budget" agy --dangerously-skip-permissions \
                    --print-timeout "${TIMEOUT}s" ${MODEL:+--model "$MODEL"} \
                    "${_agy_lane[@]+"${_agy_lane[@]}"}" \
                    --print /dev/stdin < "$PROMPT_FILE" > "$outfile" 2>&1 || exit_code=$?
            else
                "${_agy_run[@]+"${_agy_run[@]}"}" _portable_timeout "$_budget" agy --sandbox \
                    --print-timeout "${TIMEOUT}s" ${MODEL:+--model "$MODEL"} \
                    "${_agy_lane[@]+"${_agy_lane[@]}"}" \
                    --print /dev/stdin < "$PROMPT_FILE" > "$outfile" 2>&1 || exit_code=$?
            fi ;;
        grok)
            # Flags actually passed (see invocation at the end of this case):
            #   --prompt-file /dev/stdin: feeds the prompt via fd 0, bypassing
            #     argv length limits and shell escaping. Matches the heredoc
            #     pattern callers use elsewhere in this script.
            #   --max-turns 150: grok counts every internal message (tool calls,
            #     planning steps, web fetches) toward the budget, not user-
            #     assistant exchanges. Real Researcher prompts consume 50-100
            #     messages; 150 is the safety margin. `max_turns_exceeded` is
            #     DESTRUCTIVE (whole output discarded), so err generous.
            #   --sandbox strict, --deny 'Bash(*)', --deny 'Edit',
            #     --deny 'MCPTool(*)', and the two GROK_*_HOOKS_ENABLED=0 env
            #     assignments: see the SAFETY MODEL block below.
            #
            # Flags deliberately NOT passed: --always-approve (the point of this
            # arm is the opposite) and --disallowed-tools (superseded by --deny,
            # which is the documented rule surface and empirically enforcing).
            #
            # NOTE: grok-build (the only available model) rejects --reasoning-effort
            # and --effort with a 400 from the responses API, so neither MODEL nor
            # effort tiers are forwarded here.
            #
            # A REFUSAL (skipped), not a failure, and it
            # became load-bearing the moment
            # grok joined `--cli all` discovery: every batch voice receives the
            # batch's `--model`, so a bare `exit 1` here failed the WHOLE batch
            # for every other voice whenever a model was pinned. That is #594's
            # failure mode exactly. Routing it through `_grok_refused` also stops
            # the prompt being re-sent elsewhere, which would ship the quoted
            # repo content to a different CLI after the operator was told grok
            # would not run.
            #
            # An EXPLICIT `--cli grok --model X` still exits non-zero: a batch of
            # one in which the only voice was skipped reports "every CLI in the
            # batch was skipped", because there the voice that cannot run IS the
            # request. The reason is written to "$outfile" as well as stderr —
            # the banner prints the file, so stderr alone would show "(no
            # output)" and lose it — and the flag is set only if that write
            # succeeded, so an unwritable outfile stays `error`.
            if [[ -n "$MODEL" ]]; then
                echo "Error: --model is not supported by grok-build (single model; rejects --model flag). Remove --model or use --cli codex to pin a specific model." >&2
                # Set BEFORE the write, and outside its success branch: whether
                # the marker landed decides reporting, never whether grok runs.
                _grok_model_rejected=1
                if printf 'Skipped: %s\n' "--model is not supported by grok-build (single model) — grok not dispatched" >> "$outfile" 2>/dev/null; then
                    _grok_refused=1
                else
                    echo "busdriver: could not write the skip marker to \$outfile — classifying as error, not skipped" >&2
                fi
                exit_code=1
            fi
            # SAFETY MODEL (end-to-end, re-measured 2026-08-19 on macOS):
            #
            # Every control is DISPATCHER-SIDE and kernel- or policy-enforced.
            # The user's grok config is NOT part of the boundary. That was the
            # 2026-05-26 model and it is RETIRED: the same probe set ran under
            # `permission_mode = "auto"` and under `default` (the old "always
            # approve DISABLED" requirement) with identical results — shell
            # exec, `ls ~/.ssh`, `curl`, and a /tmp write ALL succeeded in both.
            # What had actually been blocking project-root writes was the
            # sandbox profile, not the permission mode. Do not reintroduce a
            # user-config clause here; it never held.
            #
            #   * --sandbox busdriver-review: a CUSTOM profile, and that word
            #     is the load-bearing part. Built-in profiles FAIL OPEN — grok
            #     warns and runs unconfined if the kernel policy cannot be
            #     applied — while an explicitly requested custom profile
            #     REFUSES TO START ("Refusing to start with its protections
            #     missing", verified 2026-08-19 by naming a profile that did
            #     not exist). The profile lives in the operator's
            #     ~/.grok/sandbox.toml, is checked for by the preflight below,
            #     and ships as docs/examples/grok-sandbox.toml. It extends
            #     `strict`, so reads are kernel-confined to CWD + system paths
            #     (`~/.ssh/known_hosts` -> `Permission denied`, where the old
            #     `readonly` profile returned the full key listing), and it
            #     kernel-denies two path groups: the in-tree HOOK SOURCES
            #     (`.claude/settings*.json`, `.cursor/hooks.json`,
            #     `.grok/hooks`) and secrets. The hook denies are what close
            #     the one path no --deny rule reaches: hooks run outside the
            #     tool permission system and `strict` permits CWD writes, so a
            #     branch-planted hook would be a clean bypass — but grok cannot
            #     load a hook file it cannot READ (verified: both settings
            #     files came back `Permission denied` / `does not exist`).
            #   * --deny 'Bash(*)': shell exec returns `Denied by permission
            #     policy: deny rule on bash`; file reads keep working.
            #   * --deny 'Edit': blocks the write/edit tool class, in the
            #     project root AND outside it (`Denied by permission policy:
            #     deny rule on edit`). Needed because strict re-permits CWD
            #     writes and because a Bash deny alone does not gate the write
            #     tool — measured: under deny-Bash the write tool still created
            #     /tmp/grok-writetool-probe.txt.
            #   * --deny 'MCPTool(*)': MCP is a SEPARATE permission class, so
            #     Bash and Edit denies do not reach it. An MCP server loaded
            #     from user or project config can write and exec, which under a
            #     CWD-writable strict profile is a straight bypass of the two
            #     rules above. Verified firing against the operator's `exa`
            #     server: `Denied by permission policy: deny rule on mcp`. No
            #     reviewer role needs MCP; grok's OWN websearch/webfetch tool
            #     classes are a different class and stay available, so the
            #     council Researcher keeps its web access.
            #   * HINDSIGHT_DISABLED=1: grok never shows SessionStart or
            #     UserPromptSubmit hook context to the model
            #     (vectorize-io/hindsight#5467), so a voice read nothing and
            #     only retained its transcript. Reads come back another way:
            #     grok_hindsight_prefetch (resolve-cli.sh) fetches the
            #     prompt-matched pages out here, outside the sandbox, and
            #     BUSDRIVER_GROK_HINDSIGHT carries them to the operator's
            #     optional PostToolUse hook (grok-hooks/busdriver-memory.py),
            #     the one hook event grok does show. Revisit when #5467 is fixed.
            #   * GROK_CLAUDE_HOOKS_ENABLED=0 / GROK_CURSOR_HOOKS_ENABLED=0:
            #     a second, cheaper layer over the same hook vector the profile
            #     denies — the scanners never look, and the files are
            #     unreadable anyway. Kept because they cost nothing and cover
            #     a vendor path the deny globs might miss after an upgrade.
            #     MEASURED 2026-08-19 with GROK_HOOK_DEBUG=1 + GROK_HOOKS_LOG:
            #     grok reports `project_sources=0` in this repo either way, and
            #     the switches drop global_sources 4 -> 1 without affecting the
            #     review.
            #     WHEN RE-PROBING: a marker file appearing is NOT evidence a
            #     grok hook ran. The first pass here "observed" a repo hook
            #     firing; it was Claude Code's OWN PreToolUse hook, injected
            #     into the same settings.local.json, firing on the prober's
            #     Bash calls. Read grok's hook-discovery log, not the
            #     filesystem.
            #   * --mode auto rejected at dispatcher level (see gate below)
            #     to restrict grok to read-shaped workloads only.
            #
            # `--deny` was previously documented here as a headless no-op. That
            # is FALSE as of 2026-08-19 — both deny rules above were verified
            # firing. `deny` beats `ask` and `allow` from every source, so a
            # committed `.claude/settings.json` or `.grok/config.toml` in a
            # reviewed tree can narrow this arm further but cannot widen it.
            #
            # RESIDUALS (accepted, not closed — each is a degradation to the
            # PREVIOUS posture at worst, never below it):
            #   * CWD WRITES BY SPAWNED PROCESSES. `strict` permits them
            #     where `readonly` did not, so anything grok spawns outside the
            #     tool permission system could write the reviewed tree. In-tree
            #     hook sources are kernel-denied (above), so what remains is
            #     the operator's own GLOBAL ~/.grok/hooks — measured firing on
            #     every headless run and able to write the CWD. Those are
            #     operator-authored, not repo-controlled, so they are outside
            #     this boundary; treat adding one as the same class of decision
            #     as adding a git hook.
            #   * /tmp and /var/tmp stay writable under every profile, so the
            #     Edit deny — not the sandbox — is what keeps grok from writing
            #     there.
            #   * Network egress is NOT blocked on macOS: strict's child-network
            #     block is Linux-only (seccomp), and grok's own webfetch /
            #     websearch tool classes stay open because the council
            #     Researcher needs them. So "read what strict allows, then
            #     exfiltrate" remains reachable — narrowed to CWD contents plus,
            #     when the operator installed the grok memory hook, the injected
            #     Claude Mem timeline and Hindsight pages. Accepted: codex and agy
            #     readonly dispatches already carry the same memory context.
            # ENFORCEMENT GATE: independently of all of the above, we reject
            # --mode auto for grok. A write-capable role could still
            # request reads that look harmless; defense-in-depth means
            # write-capable workloads route to codex/agy where the
            # write-permission model is better understood.
            if [[ "$MODE" == "auto" ]]; then
                echo "Error: grok adapter does not support --mode auto. The readonly lane's containment (custom sandbox profile + Bash/Edit/MCPTool denies) is verified for read-shaped work only; a write-capable role would need its own threat model and its own probes. Use --mode readonly or pick another CLI." >&2
                exit 1
            fi
            # Runtime visibility: print a per-dispatch warning naming the
            # RESIDUAL, not a config dependency the operator has to satisfy.
            # The dispatcher's primary in-codebase caller (council Researcher)
            # does not consume stderr, so the warning surfaces to the user
            # and not into the council report. Suppress with
            # export BUSDRIVER_GROK_QUIET_SANDBOX_WARN=1.
            if [[ "${BUSDRIVER_GROK_QUIET_SANDBOX_WARN:-0}" != "1" ]]; then
                echo "Warning: grok containment = --sandbox busdriver-review (custom kernel profile, refuses to start if unenforceable) + --deny Bash/Edit/MCPTool (policy) — reads confined to CWD, in-tree hook sources and secrets kernel-denied, shell/writes/MCP denied. RESIDUAL: network egress is NOT blocked on macOS and grok's own web tools stay open, so anything readable under CWD can still leave. Gate this lane on WHO WROTE the content. Set BUSDRIVER_GROK_QUIET_SANDBOX_WARN=1 to suppress." >&2
            fi
            # `/usr/bin/env` by absolute path, and it re-sets PATH for the
            # child it execs. PATH is inherited, and this repo already treats a
            # committed settings.json env block as repo-injectable (#325 / ADR
            # 0016), so a PATH-shadowed `env` or `grok` would run before grok's
            # sandbox exists. Absolute `/usr/bin/env` fixes the first; env
            # resolving `grok` against the PATH given ON ITS OWN COMMAND LINE
            # fixes the second. The four loader variables are blanked BEFORE
            # `env` is exec'd, not by its `-i`: the dynamic loader acts on
            # LD_PRELOAD / LD_AUDIT / LD_LIBRARY_PATH (and the DYLD_ pair) while loading
            # `/usr/bin/env` ITSELF, so anything injected there runs inside
            # env's own process before -i has cleared a single variable. An
            # assignment prefix is applied at exec time, which is early enough.
            # It sits on `_portable_timeout`, not inside its argv: the helper
            # execs "$@", so an `LD_PRELOAD=` word there would be read as the
            # command name.
            # The four loader variables are blanked BEFORE `env` is exec'd,
            # not by its `-i`: the dynamic loader acts on LD_PRELOAD / LD_AUDIT
            # (and the DYLD_* pair) while loading `/usr/bin/env` ITSELF, so
            # anything injected there runs inside env's own process, before -i
            # has cleared a single variable. An assignment prefix is applied to
            # the command's environment at exec time, which is early enough.
            #
            # `-i` clears the REST of the environment rather
            # than overriding four names in it: everything not listed here is
            # repo-injectable through a committed settings.json env block, and
            # loader variables (BASH_ENV, NODE_OPTIONS, DYLD_*, LD_PRELOAD)
            # execute code in whatever grok spawns before its sandbox exists.
            # Verified 2026-08-19 that grok runs normally with only the four
            # below: auth lives in ~/.grok, which HOME and GROK_HOME point at.
            #
            # `$_GROK_PINNED_PATH` is built by the preflight
            # from the same trusted home it validated, and the preflight also
            # refuses when no grok resolves on it — otherwise availability
            # (ambient PATH) and execution (pinned PATH) could disagree and a
            # grok under nvm or a custom prefix would fail as command-not-found
            # after passing selection.
            #
            # RESIDUAL, and it is pre-existing: `_portable_timeout` still
            # resolves `timeout`/`gtimeout`/`perl` through the inherited PATH
            # before any of this runs, exactly as it does for every other CLI
            # arm in this dispatcher. Hardening that is a change to the shared
            # helper and belongs in its own commit, not smuggled into the grok
            # lane.
            #
            # `env VAR=...` and not a caller-side export: an explicit
            # assignment on the command line beats anything inherited, so a
            # repo-committed `.claude/settings.json` env block (#325 / ADR
            # 0016) cannot flip the vendor-hook scanners back on — or, via
            # GROK_HOME, point grok at a config directory holding a weaker
            # `sandbox.toml` than the one the preflight just verified. HOME and
            # GROK_HOME are pinned to the password-database home the preflight
            # derived, so the file checked and the file loaded are the same.
            # Refuse if the operator's own ~/.grok/sandbox.toml does not define
            # the profile. Naming a missing custom profile already fails closed
            # inside grok, but with no USER definition a repo-local
            # .grok/sandbox.toml would supply one — the reviewed branch writing
            # its own containment. See grok_sandbox_preflight in resolve-cli.sh.
            # The dispatch lives in the POSITIVE branch. Written the other way
            # round — bail inside the failure branch, invoke after the `fi` — an
            # exported BASH_FUNC_exit%% turns the bail into a fall-through and
            # grok runs with no verified profile. There is nothing to fall
            # through into here.
            if [[ "${_grok_refused:-0}" == "1" || "${_grok_model_rejected:-0}" == "1" ]]; then
                # Already refused above (--model). The reason is in "$outfile"
                # already; running the preflight now would only overwrite it
                # with a profile hint that is not why this voice was skipped.
                :
            elif grok_sandbox_preflight "" && grok_auth_ready "$_budget"; then   # "" = no fixture override
            # 64 KB, not 2 KB: a blueprint prompt's rubric alone can fill 2 KB and
            # hide the "Document to review:" line; the prefetch caps the query itself.
            grok_hindsight_prefetch "$(/usr/bin/head -c 65536 "$PROMPT_FILE")"
            # No CLAUDE_MEM_WORKER_PORT here: a repo can set it, so the memory hook
            # reads the port from the trusted home's ~/.claude-mem/settings.json.
            # #956: a PIPE, not `< "$PROMPT_FILE"`. On Linux grok reopens
            # /dev/stdin via /proc/self/fd/0, which re-resolves a redirected
            # file by its path — under HOME, outside CWD — and the sandbox
            # denies it. A pipe has no path to re-resolve. printf is a builtin.
            # SIGPIPE is ignored in the writer so a grok that exits 0 without
            # draining a large prompt is not reported as 141 under pipefail;
            # grok, rightmost, still owns the pipeline's status.
            (trap '' PIPE; printf '%s' "$PROMPT" 2>/dev/null || :) |
            LD_PRELOAD='' LD_AUDIT='' LD_LIBRARY_PATH='' \
                DYLD_INSERT_LIBRARIES='' DYLD_LIBRARY_PATH='' \
            _portable_timeout "$_budget" /usr/bin/env -i \
                PATH="$_GROK_PINNED_PATH" \
                HOME="$_GROK_TRUSTED_HOME" \
                GROK_HOME="$_GROK_TRUSTED_HOME/.grok" \
                GROK_CLAUDE_HOOKS_ENABLED=0 \
                GROK_CURSOR_HOOKS_ENABLED=0 \
                HINDSIGHT_DISABLED=1 \
                BUSDRIVER_GROK_HINDSIGHT="$_GROK_HINDSIGHT_CTX" \
                grok \
                --prompt-file /dev/stdin \
                --max-turns 150 \
                --sandbox busdriver-review \
                --deny 'Bash(*)' \
                --deny 'Edit' \
                --deny 'MCPTool(*)' \
                > "$outfile" 2>&1 || exit_code=$?
            else
                # The hint goes to BOTH stderr (for the operator) and $outfile,
                # because the retry loop classifies on the output file: an empty
                # one reads as "CLI died, retry".
                #
                # `_grok_refused` is what makes this a REFUSAL rather than a
                # failed attempt. Without it the shared loop reads exit 1 as "the
                # CLI failed" and reports an error instead of a refusal; the
                # dispatch fails and its content goes nowhere else. Reported by
                # Cursor Bugbot on PR #704.
                #
                # The flag is set only if the write to $outfile succeeded,
                # matching the sibling refusal path above (--model). Setting it unconditionally
                # would let an unwritable outfile still classify as "skipped
                # with a reason" while the reason itself was lost — the batch
                # banner would print "(no output)" and the refusal cause would
                # never reach the operator. Reported by CodeRabbit on PR #704.
                grok_preflight_hint >&2
                # shellcheck disable=SC2310  # deliberate: the hint's failure IS
                # the branch condition here, so `set -e` must not preempt it.
                if grok_preflight_hint > "$outfile" 2>/dev/null; then
                    _grok_refused=1
                else
                    echo "busdriver: could not write the grok refusal reason to \$outfile — classifying as error, not skipped" >&2
                fi
                exit_code=1
            fi ;;
    esac

    # Timeout → don't retry; it is reported as a timeout.
    [[ "$exit_code" -eq 124 ]] && break
    # A clean exit with non-empty output is success — UNLESS it is a bare
    # transient notice the CLI wrote while still exiting 0 (a rate-limit/5xx
    # message in place of a review). Those fall through to the retry path;
    # a real review payload — even one discussing rate limits / 5xx — is accepted.
    if [[ "$exit_code" -eq 0 && -s "$outfile" ]] && ! _is_bare_transient_notice_file "$outfile"; then
        break
    fi
    # Retry if the attempt produced NO output (CLI died before writing — empty is
    # never a valid response, whatever the exit code) OR the output looks
    # transient. Otherwise bail (non-transient hard failure that produced output
    # → it is reported as an error).
    # The refusal flag is checked FIRST and wins outright. It is set only for
    # failures that are deterministic by construction, so no amount of retrying
    # helps — and the text classifier below cannot be trusted to agree, because
    # refusal messages quote operator-supplied values.
    if [[ "${_grok_refused:-0}" != "1" ]] \
       && { [[ ! -s "$outfile" ]] || _is_transient_cli_error < "$outfile"; }; then
        _attempt=$((_attempt + 1))
        continue
    fi
    break
    done
    # Exhausted retries while the output file is still empty OR still holds a bare
    # transient notice on a clean exit → mark as failure so the status below is
    # reported as error rather than a silent empty / rate-limited success.
    if [[ "$exit_code" -eq 0 ]] && { [[ ! -s "$outfile" ]] || _is_bare_transient_notice_file "$outfile"; }; then
        exit_code=1
    fi

    local duration=$(( $(date +%s) - start ))

    # NOTE: stderr-noise filtering was removed 2026-05-26 after litmus review.
    # The filter (originally catching grok's "Skipping MCP tool" /
    # "qualified name contains" / claude-mem `CLAUDE_MEM_RUNTIME` runtime
    # mismatch lines) risked hiding real tool-failure diagnostics that the
    # caller might need to see — e.g., a Researcher run that failed to retrieve
    # prior observations should leave the failure visible in the transcript,
    # not be silently cleaned. Council Researcher transcripts may therefore
    # contain interspersed ISO-timestamped ERROR lines from grok's stderr —
    # accept the cosmetic cost in exchange for diagnostic fidelity. If the root
    # cause (claude-mem MCP worker/server-beta runtime mismatch) is fixed
    # upstream, the noise disappears at its source.

    # Clean ANSI
    if [[ -f "$outfile" ]]; then
        strip_ansi < "$outfile" > "${outfile}.clean" && mv "${outfile}.clean" "$outfile"
    fi

    # Determine status
    local status="success"
    [[ $exit_code -eq 124 ]] && status="timeout"
    [[ $exit_code -ne 0 && $exit_code -ne 124 ]] && status="error"
    # `skipped` — the voice never ran. Assigned LAST so it wins over the
    # error/timeout classification above: a deterministic precondition failure
    # is not an attempt that failed, it is an attempt that was refused before it
    # began, and the two deserve different consequences. Keeping them merged as
    # `error` is what let ONE ineligible voice fail a whole `--cli all` batch for
    # every other voice (#594). An EXPLICIT single-CLI request still fails,
    # because there the voice that cannot run IS the request.
    # A grok refusal (preflight, or a --model grok cannot accept) is wired to this status: the voice
    # was refused before it began, so one unconfigured host must not fail a
    # whole `--cli all` batch for every other voice. An explicit `--cli grok`
    # still exits non-zero, because there the refused voice IS the request.
    [[ "${_grok_refused:-0}" == "1" ]] && status="skipped"

    echo "${status}|${duration}|${exit_code}" > "$meta"
}

# ── Read meta helper ───────────────────────────
read_meta() {
    cat "$1" 2>/dev/null || echo "error|0|1"
}

# ── Execute ────────────────────────────────────
STAMP="$(date +%s)-$$"
OUT_DIR="${TMPDIR:-/tmp}"

if [[ "$CLI" == "both" ]]; then
    CODEX_OUT="${OUT_DIR}/dispatch-codex-${STAMP}.txt"
    AGY_OUT="${OUT_DIR}/dispatch-agy-${STAMP}.txt"

    echo "Dispatching to Codex + Agy in parallel (${MODE}, ${TIMEOUT}s timeout)..." >&2

    dispatch_one "codex" "$CODEX_OUT" &
    dispatch_one "agy"   "$AGY_OUT" &
    wait || true  # allow meta parsing even if a background job exits non-zero

    # Read results
    CMETA=$(read_meta "${CODEX_OUT}.meta"); rm -f "${CODEX_OUT}.meta"
    AMETA=$(read_meta "${AGY_OUT}.meta");   rm -f "${AGY_OUT}.meta"

    CS=$(echo "$CMETA" | cut -d'|' -f1); CD=$(echo "$CMETA" | cut -d'|' -f2)
    AS=$(echo "$AMETA" | cut -d'|' -f1); AD=$(echo "$AMETA" | cut -d'|' -f2)

    # Log before emitting — same SIGPIPE reasoning as the other two paths.
    log_event "codex" "$CS" "$CD" "$CODEX_OUT"
    log_event "agy"   "$AS" "$AD" "$AGY_OUT"

    # Print both outputs
    echo "═══════════════════════════════════════════════════════"
    echo "  CODEX  (${CS}, ${CD}s)"
    echo "═══════════════════════════════════════════════════════"
    [[ -f "$CODEX_OUT" ]] && cat "$CODEX_OUT" || echo "(no output)"
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  AGY  (${AS}, ${AD}s)"
    echo "═══════════════════════════════════════════════════════"
    [[ -f "$AGY_OUT" ]] && cat "$AGY_OUT" || echo "(no output)"

    echo "" >&2
    echo "Saved: codex → ${CODEX_OUT}  |  agy → ${AGY_OUT}" >&2

    # Exit with failure if either dispatch failed
    [[ "$CS" == "error" || "$CS" == "timeout" || "$AS" == "error" || "$AS" == "timeout" ]] && exit 1
    # Explicit — see the identical note at the end of the `all` branch. Without
    # it, a fully successful pair exited 1.
    exit 0

elif [[ "$CLI" == "all" ]]; then
    echo "Dispatching to ${#ALL_CLIS[@]} CLIs: ${ALL_CLIS[*]} (${MODE}, ${TIMEOUT}s timeout)..." >&2

    ALL_OUTS=()
    for c in "${ALL_CLIS[@]}"; do
        outfile="${OUT_DIR}/dispatch-${c}-${STAMP}.txt"
        ALL_OUTS+=("$outfile")
        dispatch_one "$c" "$outfile" &
    done
    wait || true  # allow meta parsing even if a background job exits non-zero

    any_failed=false
    any_ran=false
    # PASS 1 — read every voice's meta and LOG IT, writing nothing to stdout.
    # Interleaving this with the output loop below does not work: `cat` (and even
    # the header `echo`s) die on SIGPIPE as soon as a consumer exits early, and
    # under `set -e` that kills the script, so every voice after the one being
    # printed would lose its log entry AND its failure archive. Separating the
    # passes is what actually makes the batch's audit trail independent of
    # whether anyone is still reading stdout — moving `log_event` a few lines
    # earlier inside one combined loop does not, because the headers still
    # precede it.
    local_idx=0
    ALL_STATUS=(); ALL_DURATION=()
    for c in "${ALL_CLIS[@]}"; do
        outfile="${ALL_OUTS[$local_idx]}"
        META=$(read_meta "${outfile}.meta"); rm -f "${outfile}.meta"
        STATUS=$(echo "$META" | cut -d'|' -f1); DURATION=$(echo "$META" | cut -d'|' -f2)
        ALL_STATUS+=("$STATUS"); ALL_DURATION+=("$DURATION")
        log_event "$c" "$STATUS" "$DURATION" "$outfile"
        [[ "$STATUS" == "error" || "$STATUS" == "timeout" ]] && any_failed=true
        # `skipped` is deliberately absent from the failure test above — a voice
        # that never ran is not a voice that failed (#594).
        [[ "$STATUS" != "skipped" ]] && any_ran=true
        local_idx=$((local_idx + 1))
    done

    # PASS 2 — emit. Everything above is already durable, so a consumer that
    # walks away here costs only the display.
    idx=0
    for c in "${ALL_CLIS[@]}"; do
        outfile="${ALL_OUTS[$idx]}"
        echo "═══════════════════════════════════════════════════════"
        echo "  $(echo "$c" | tr '[:lower:]' '[:upper:]')  (${ALL_STATUS[$idx]}, ${ALL_DURATION[$idx]}s)"
        echo "═══════════════════════════════════════════════════════"
        [[ -f "$outfile" ]] && cat "$outfile" || echo "(no output)"
        echo ""
        idx=$((idx + 1))
    done

    echo "" >&2
    echo "Saved outputs to ${OUT_DIR}/dispatch-*-${STAMP}.txt" >&2
    # ...but a batch in which EVERY voice was skipped produced no comparison at
    # all, and "nothing ran" must never read as success. This is the one place
    # `skipped` is still fatal.
    if [[ "$any_ran" != "true" ]]; then
        echo "Error: every CLI in the batch was skipped — no voice met its preconditions, so nothing ran." >&2
        exit 1
    fi
    [[ "$any_failed" == "true" ]] && exit 1
    # Explicit, and load-bearing: without it the `&&` list above is the branch's
    # LAST statement, so a fully successful batch fell off the end of the script
    # carrying that test's own exit status — a clean run reported failure.
    exit 0

else
    # Reporting identity: the requested lane name (e.g. "agy-prose") when the
    # agy-prose desugar set it, else the plain CLI value. Dispatch mechanics
    # below still use $CLI (the shared agy arm) — only the audit trail
    # (filename, console line, log entry) needs the more specific name.
    REPORT_NAME="${REPORT_CLI_NAME:-$CLI}"
    # Second gate, deliberately kept even though REPORT_CLI_NAME is initialized
    # empty above and only ever set to a literal by the desugar. This value lands
    # in a FILENAME and in the audit log, so it is a provenance field: constrain
    # it to the lane vocabulary rather than trusting that no future edit
    # reintroduces an ambient or computed source. Anything unrecognized falls
    # back to $CLI, which the --cli validator has already restricted to the enum.
    case "$REPORT_NAME" in
        codex|agy|agy-prose|grok) ;;
        *) REPORT_NAME="$CLI" ;;
    esac
    OUTFILE="${OUT_DIR}/dispatch-${REPORT_NAME}-${STAMP}.txt"

    echo "Dispatching to ${REPORT_NAME} (${MODE}, ${TIMEOUT}s timeout)..." >&2

    dispatch_one "$CLI" "$OUTFILE"
    META=$(read_meta "${OUTFILE}.meta"); rm -f "${OUTFILE}.meta"

    STATUS=$(echo "$META" | cut -d'|' -f1)
    DURATION=$(echo "$META" | cut -d'|' -f2)
    EXIT_CODE=$(echo "$META" | cut -d'|' -f3)

    # LOG BEFORE EMITTING. `cat` dies on SIGPIPE the moment a consumer exits
    # early (`dispatch.sh ... | head -1`), and it is the last command of an `&&`
    # list, so `set -e` takes the whole script down with it — losing both the log
    # entry and the failure archive for a run that had already finished. Verified:
    # a 2.4MB failing output piped to `head -1` produced 0 log entries and 0
    # archived files; a small output did not, because it fit in the pipe buffer
    # and `cat` never received the signal. Recording the run first makes the
    # audit trail independent of whether anyone is still reading stdout.
    log_event "$REPORT_NAME" "$STATUS" "$DURATION" "$OUTFILE"

    [[ -f "$OUTFILE" ]] && cat "$OUTFILE"

    echo "" >&2
    echo "${REPORT_NAME} → ${STATUS} (${DURATION}s) | saved: ${OUTFILE}" >&2

    exit "${EXIT_CODE}"
fi
