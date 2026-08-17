#!/usr/bin/env -S bash -p
# ── Function-clean boundary (ADR 0016 / #325 class) ───────────────
# SHEBANG: `#!/usr/bin/env -S bash -p` — env resolves `bash` via PATH (the
# pi lane requires bash 4+ via PATH; a `#!/bin/bash` shebang would pin macOS
# /bin/bash 3.2) AND the first process starts with `-p`, so no BASH_FUNC_*
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
# dispatch.sh — Dispatch tasks to Codex, Antigravity (agy), Droid, Grok, or opencode CLI as autonomous agents
#
# Usage (prefer heredoc or stdin to avoid shell escaping bugs):
#   dispatch.sh --cli codex <<'PROMPT'
#   your task here
#   PROMPT
#   echo "task" | dispatch.sh --cli codex
#   dispatch.sh --cli codex --prompt "simple single-line only"

# ── Interpreter floor (pi lane) — before `set -euo pipefail`, after the
#    privileged re-exec boundary above ──
# Issue #595: the pi arm's preflight runs a QUOTED heredoc inside `$(...)`
# (`/usr/bin/env -i ... /bin/bash <<'CHILD'`). bash 3.2 — macOS's stock
# /bin/bash — mis-parses that construct when the body contains `case`
# patterns: body text is re-parsed as parent code, and the `set -u` abort
# inside the `if ! _pi_pre="$(...)"` condition exits 0 — a silent fail-open
# that the old `#!/bin/bash` shebang reached on every macOS direct exec.
# Verified: 3.2.57 broken, 4.4 and 5.x parse it correctly.
#
# The scan below uses only parser constructs (`for`/`case`/`[[`/`((` and
# assignments — no command word), and aborts via the `${VAR:?msg}` parameter
# expansion, which is unconditional (needs no `set -e`) and untrappable.
#
# HISTORY (#600, amended after #617): that no-command-word style was chosen
# when this guard was the FIRST thing in the file, to survive an imported
# BASH_FUNC_* shadowing even an absolute path like /usr/bin/env. It is no
# longer load-bearing — #617 put the `-p` shebang and the privileged re-exec
# boundary above (lines ~29-70, themselves full of command words), so by the
# time this runs, imported function shadows cannot execute at all. The style
# is kept because it works and rewriting it buys nothing.
# ponytail: keep-simple — collapse the argv scan into the pi arm (dropping
# this duplicate of the real parser at ~line 313 and its source-text grep in
# tests/test-pi-dispatch-arm.sh) the next time either one desyncs or breaks
# on a reformat; the `-p` boundary above is why that is safe to do.
#
# It refuses both ways a pi dispatch can be reached: `--cli pi` directly, and
# `--cli all` in a non-auto mode (the batch discovery below excludes pi from
# `all` only under --mode auto). The no-pi-installed corner is deliberately
# NOT checked here: knowing that requires the trusted-home derivation (the
# env -i preflight), which this scan cannot run — so `--cli all` on a 3.2
# host refuses loudly even when pi is absent, a conservative fail-closed
# false positive with an explanatory message.
#
# The `#!/usr/bin/env -S bash -p` shebang runs the FIRST `bash` on PATH — it
# selects by PATH order, not by vendor, so it picks up a >= 4 bash where one
# is installed ahead of /bin/bash (Homebrew's, typically, on macOS) and plain
# /bin/bash 3.2 where none is. It authenticates nothing about the interpreter
# it lands on. The threat actor is the CALLER, who by controlling PATH can
# select or plant the `bash` that runs — but such a caller could equally
# invoke any interpreter directly, so no shebang defends against it. A planted
# 3.2 bash is still caught by the version floor below, and a planted >= 4 bash
# is the attacker's own code, i.e. total compromise by definition. What `-p`
# does add is refusing to import functions from the environment.
if (( BASH_VERSINFO[0] < 4 )); then
    # The scan mirrors the real arg parser (lines ~202-206): --cli/--mode/
    # --timeout/--model/--prompt each consume their next operand, the LAST
    # --cli / --mode wins, and -h|--help anywhere exits 0 before dispatch —
    # so a help request must not be refused (usage is the same on every
    # bash). Consuming the other flags' operands matters: `--prompt --cli
    # --cli pi` parses as PROMPT=--cli, CLI=pi — without the operand
    # consumption the scan would read the second `--cli` as the first's
    # value and miss the pi dispatch entirely.
    _cli_arg=""
    _mode_arg=""
    _help=0
    _prev=""
    for _a in "$@"; do
        if [[ "$_prev" == "cli" ]]; then
            _cli_arg="$_a"
            _prev=""
        elif [[ "$_prev" == "mode" ]]; then
            _mode_arg="$_a"
            _prev=""
        elif [[ -n "$_prev" ]]; then
            # operand of --timeout/--model/--prompt (or a bare word after a
            # value-taking flag): consumed, not inspected
            _prev=""
        elif [[ "$_a" == "--cli" ]]; then
            _prev="cli"
        elif [[ "$_a" == "--mode" ]]; then
            _prev="mode"
        elif [[ "$_a" == "--timeout" || "$_a" == "--model" || "$_a" == "--prompt" ]]; then
            _prev="skip"
        elif [[ "$_a" == "--help" || "$_a" == "-h" ]]; then
            _help=1
        fi
    done
    if (( ! _help )) && [[ "$_cli_arg" == "pi" || ( "$_cli_arg" == "all" && "$_mode_arg" != "auto" ) ]]; then
        # The self-assignment overwrites any imported value: `${VAR:?}` only
        # fires on an unset/empty variable, so an environment exporting
        # `_pi_bash_floor=1` would otherwise bypass the abort. Assignments are
        # parser constructs, not command words — nothing can shadow this.
        _pi_bash_floor=""
        # shellcheck disable=SC2154  # _pi_bash_floor is assigned (empty) right above; :? is the abort
        : "${_pi_bash_floor:?dispatch.sh requires bash 4.0 or newer for the pi lane (found ${BASH_VERSION:-unknown}). bash 3.2 (macOS stock /bin/bash) mis-parses the pi preflight heredoc-in-command-substitution and fails open with exit 0. Install a newer bash (macOS: brew install bash), run this script with it, or dispatch a non-pi CLI.}"
    fi
fi

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
# Ditto for the Auditor model resolver — without the library there is no config
# reader, so the opencode arm resolves to an empty model (skip; see below —
# there is no shipped default to fall back on). Gate on whether the trusted
# library was actually sourced (_BD_RESOLVE_CLI_SOURCED),
# not on `type resolve_auditor_model` — an inherited/exported function of that
# name in the caller's environment would satisfy the `type` check and silently
# stand in for the real resolver, defeating the model-selection hardening this
# function exists to provide.
if [[ "$_BD_RESOLVE_CLI_SOURCED" != 1 ]]; then
  _BD_AUDITOR_MODEL=""
  # Library missing → no config reader exists, and there is no shipped default to
  # fall back on (see resolve_auditor_model in resolve-cli.sh). Resolve to empty;
  # the guard at the dispatch site turns that into a skipped advisory voice rather
  # than a dispatch to a model nobody chose.
  resolve_auditor_model() { _BD_AUDITOR_MODEL=""; }
  _BD_PI_MODEL=""
  resolve_pi_model() { _BD_PI_MODEL="opencode-go/deepseek-v4-flash"; }
  # Deliberately NOT a duplicated default (unlike the pi stub above, which is
  # the drift class this repo has already paid for). Empty here is a REFUSAL
  # signal: the `agy-read` desugar below aborts on it rather than falling
  # through to agy's own configured model, because that model is the reviewer's
  # — silently reviewing-model-priced every read is worse than a loud stop.
  _BD_AGY_READ_MODEL=""
  resolve_agy_read_model() { _BD_AGY_READ_MODEL=""; }
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
# The pi version whose tool-permission behaviour this repo actually probed (see
# the pi) arm and docs/adr/0034). A mismatch BLOCKS the dispatch: this lane's
# read-only posture is observed behaviour of one version, and the test proving it
# semantically is opt-in, so an unprobed pi running in-tree is exactly the case
# where a stuck lane beats a skipped check. Clearing it: re-run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh, then bump this constant.
BUSDRIVER_PI_PROBED_VERSION="0.84.1"
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
# 600, raised from 300. The pi arm READS THE TREE, so its work scales with the
# source it has to open rather than with a chat turn, and 300 sat BELOW its
# median: two successful in-tree traces took 315s and 307s — both would have been
# killed by the old default. A cap that kills its own successful runs reads as an
# unreliable model when it is really a misconfigured number.
#
# Raised globally rather than per-CLI on purpose. `_portable_timeout` is a CAP,
# not a wait: an arm that finishes in 30s is unaffected, so the only cost is that
# a genuinely HUNG voice now takes 600s to kill instead of 300s. Paying that on
# the rare hang is far cheaper than a per-arm value threaded through the shared
# retry budget, agy's four `--print-timeout` sites and the droid rescue.
#
# A caller running this BLOCKING needs its own timeout above this one, with room
# for startup and cleanup. Do NOT copy litmus's "600s harness cap" reasoning here
# — that number is specific to LITMUS_TIMEOUT's own budget, not a property of the
# Bash tool, whose ceiling is set by BASH_MAX_TIMEOUT_MS (3600000ms here).
TIMEOUT=600
MODEL=""
PROMPT=""
# Set only by the `agy-read` desugar below. Carries the LANE IDENTITY that the
# desugar would otherwise erase (it rewrites CLI to plain "agy"), and is read in
# two places: it adds `--mode plan` to agy's argv, and it exempts the lane from
# the runtime droid escalation. Deliberately ONE flag for both, not two: they are
# the same fact ("this dispatch is the read lane"), and a second variable would
# let a future change to one silently stop protecting the other.
# Empty for every other caller. Note what that does and does NOT mean: the
# lane-only additions are `--model` and `--mode plan`. `--add-dir "$PWD"` is
# UNCONDITIONAL on all four agy sites, so plain `--cli agy` argv is deliberately
# NOT byte-identical to what it was before this lane existed — see the agy branch
# for why that is a fix rather than scope creep.
_AGY_READ_LANE=""

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
dispatch.sh — Dispatch tasks to Codex, Antigravity (agy), Droid, Grok, opencode, or pi CLI

FLAGS:
  --cli     codex|agy|agy-read|droid|grok|opencode|pi|both|all|auto  (default: auto)
  --mode    readonly|auto           (default: readonly)
  --timeout seconds                 (default: 600)
  --model   model override          (optional)
  --prompt  "task description"      (or pipe via stdin)

NOTE: `agy-read` is the repo-READING lane. Like `pi` it runs IN the working tree
(`--add-dir "$PWD"`, which is load-bearing — without it agy answers from a
remembered workspace, citing the wrong checkout). `--mode auto` is refused. Its model comes from ~/.claude/busdriver.json
`{"agy_read": {"model": "<id>"}}`; `agy models` enumerates ids. Plain `--cli agy` is unaffected and keeps agy's own configured model, so
the blueprint-review reviewer slot is never downgraded to the read model.
Writes: blocked in every probe run via agy's `--mode plan` (`--sandbox` alone
does NOT block writes) — a mode, not a kernel sandbox, so not write-PROOF.

NOTE: `pi` is the older repo-READING lane — unlike opencode (confined to an empty
dir), it runs in the working tree so it can trace real code, with an
allowlisted read-only toolset. It is read-only by construction and is skipped
in `--cli all --mode auto`. Model comes from ~/.claude/busdriver.json
`{"pi": {"model": "provider/id"}}`; `pi --list-models` enumerates ids.
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
trap 'rm -f "$PROMPT_FILE"' EXIT
printf '%s' "$PROMPT" > "$PROMPT_FILE"

# ── CLI detection ──────────────────────────────
_has_cli() {
  if type is_cli_available &>/dev/null; then
    is_cli_available "$1"
  else
    command -v "$1" &>/dev/null
  fi
}

# pi is a special case: dispatch_one's pi arm resolves the binary from
# password-db home candidates (~/.local/bin/pi, ~/.pi/bin/pi, Homebrew paths),
# not from the inherited PATH — so `--cli pi` can dispatch even when pi is
# absent from PATH. `_has_cli` alone (a bare `command -v`) would then miss a
# pi install that dispatch_one can actually reach, silently dropping pi from
# `--cli all`. Mirror the same candidate list here as a lightweight presence
# check (not a trust boundary — the real, PATH-shadow-proof resolution still
# happens inside dispatch_one's `env -i` child at dispatch time).
# THE WHOLE PROBE RUNS IN A STERILE CHILD, not here. It resolves the operator's
# home by tilde expansion, which needs `eval` — and `eval` is a builtin an
# exported `BASH_FUNC_eval%%` overrides, so running it in the INHERITED shell
# would hand arbitrary execution to the environment during `--cli all`, BEFORE
# the pi arm's own sterile preflight ever runs. Username validation does not
# help: the shadow intercepts the call regardless of its argument. `env -i`
# gives the child an empty environment, so it imports no functions and its
# `eval` is genuinely the builtin. Same trust anchor as every other escape in
# this arm — the absolute `/usr/bin/env`, which cannot be imported as a
# function name.
# NO `_has_cli pi` SHORTCUT. Selection must accept exactly what the arm's
# preflight accepts, and the preflight takes ONLY the trusted-path candidates
# below — never whatever `command -v` finds on the inherited PATH. With the
# shortcut, a pi anywhere on PATH got added to a `--cli all` batch and then
# failed preflight, which fails the WHOLE batch. The candidate list is the
# contract; duplicating it loosely here is what broke it.
# NOT VERSION-GATED, deliberately. dispatch_one's pi arm refuses any binary
# whose `--version` doesn't match the pinned $BUSDRIVER_PI_PROBED_VERSION, and
# that preflight is the SINGLE authority on eligibility. Duplicating the check
# here was tried on PR #591 and removed: the copy had to be bounded (a hang
# during discovery has no deadline above it), which needed a capture file, a
# race-free name, and a size cap — and the size cap reintroduced the divergence
# the copy existed to close, because a truncated version string can match in one
# place and not the other. Selection is therefore optimistic, and since #594 the
# cost of that is bounded: an ineligible pi reports `skipped`, so it drops out of
# a `--cli all` batch instead of failing it. See the block below.
_pi_available() {
  /usr/bin/env -i "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    /bin/bash --noprofile --norc <<'CHILD' 2>/dev/null
u="$(/usr/bin/id -un)" || exit 1
# Tilde directory-stack forms (~- ~+ ~N ~-N ~+N → $OLDPWD/$PWD) must never
# reach the eval below; digit-LEADING names (0abc) are normal usernames.
[[ "$u" =~ ^[-+]?[0-9]*$ ]] && exit 1
case "$u" in *[!A-Za-z0-9._-]*) exit 1 ;; esac
h="$(eval echo "~$u")" || exit 1
case "$h" in /*) ;; *) exit 1 ;; esac
[ -d "$h" ] || exit 1
# PATH CHECK ONLY — NO VERSION PROBE. Selection deliberately does not try to
# predict the preflight's verdict. It used to: a version probe was duplicated
# here so `--cli all` would not pick a pi the preflight would reject. That
# duplicate then had to be bounded (a hang here has no deadline above it), which
# needed a capture file, which needed a safe name, which needed a size limit —
# and the size limit reintroduced the very divergence the duplicate existed to
# remove, since a truncated version string can match here and not there. Every
# bound on a second implementation of a check spawns the next gap between them.
#
# WHAT OPTIMISTIC SELECTION COSTS, and what absorbs it. A stale or
# version-mismatched pi on the trusted path is still SELECTED here and still
# fails its preflight at dispatch time — selection cannot predict that verdict
# without a second probe, and a second probe is what the paragraph above rules
# out. What changed with #594 is the CONSEQUENCE: that preflight failure now
# reports `skipped` rather than `error`, so the ineligible voice drops out of a
# `--cli all` batch instead of failing it for every other voice. An explicit
# `--cli pi` still fails, because there the voice that cannot run is the whole
# request. What this function guarantees is unchanged: there is exactly ONE
# version probe in the codebase, so selection and preflight cannot disagree
# about eligibility.
for c in "$h/.local/bin/pi" "$h/.pi/bin/pi" /opt/homebrew/bin/pi /usr/local/bin/pi /usr/bin/pi /bin/pi; do
  [ -f "$c" ] && [ -x "$c" ] && exit 0
done
exit 1
CHILD
}

if [[ "$CLI" == "auto" ]]; then
    if _has_cli codex; then CLI="codex"
    elif _has_cli agy; then CLI="agy"
    elif _has_cli droid; then CLI="droid"
    # grok is intentionally excluded from --cli auto. Its safety model
    # (--sandbox readonly + user-config "always approve" disabled) is documented
    # but not enforceable from code, so silently selecting grok via auto would
    # extend its exposure to contexts whose threat model wasn't reviewed.
    # Use --cli grok explicitly (or set BUSDRIVER_REVIEW_CLI=grok) to opt in.
    # This mirrors the resolve-cli.sh auto-detect exclusion.
    else echo "Error: No supported CLI found (tried codex, agy, droid). grok is excluded from auto-selection; use --cli grok to opt in explicitly." >&2; exit 1; fi
elif [[ "$CLI" != "codex" && "$CLI" != "agy" && "$CLI" != "agy-read" && "$CLI" != "droid" && "$CLI" != "grok" && "$CLI" != "opencode" && "$CLI" != "pi" && "$CLI" != "both" && "$CLI" != "all" ]]; then
    echo "Error: Invalid --cli value '$CLI'. Must be codex|agy|agy-read|droid|grok|opencode|pi|both|all|auto." >&2; exit 1
fi

# ── `agy-read` — the agy READ lane ──────────────────────────────
# Desugars to the ordinary agy arm with three things pinned, so there is ONE agy
# implementation to maintain rather than two that drift:
#   readonly mode  → `agy --sandbox` (never --dangerously-skip-permissions)
#   $MODEL         → `.agy_read.model` from ~/.claude/busdriver.json
#   --add-dir "$PWD" is already unconditional in the arm (see the agy branch)
#
# Plain `--cli agy` is UNTOUCHED by all of this: it passes no --model, so the
# reviewer_1 slot keeps agy's own configured model. Only this lane opts in.
# An explicit `--model` still wins — the config is the default, not a clamp.
if [[ "$CLI" == "agy-read" ]]; then
    CLI="agy"
    # Not merely the default. `--mode auto` would select
    # --dangerously-skip-permissions, i.e. a writing agent loose in the working
    # tree, which is a different lane wearing this name.
    # Validate BEFORE normalising. Assigning MODE="readonly" unconditionally would
    # run ahead of the general mode validator below and swallow every invalid
    # value: `--mode typo` would be silently accepted as readonly instead of
    # reported. So reject `auto` with its specific hint, reject anything that is
    # not `readonly` as invalid, and only then normalise.
    if [[ "$MODE" == "auto" ]]; then
        echo "Error: --cli agy-read is the read lane; --mode auto is not accepted. Use --cli agy --mode auto for a writing agy dispatch." >&2; exit 1
    elif [[ "$MODE" != "readonly" ]]; then
        echo "Error: Invalid --mode '$MODE'. --cli agy-read accepts only readonly." >&2; exit 1
    fi
    MODE="readonly"
    # `--sandbox` ALONE DOES NOT BLOCK WRITES. Measured 2026-08-17: a --sandbox
    # dispatch asked to write created BOTH ./scratch-probe.txt and
    # /tmp/agy-write-probe.txt, and reported "Succeeded" for each. --sandbox is
    # terminal restrictions, not a filesystem boundary — do not read it as one.
    # agy's `--mode plan` is the write boundary here. Under it the same probe
    # produced no file, while an ordinary read question still answered normally
    # (correct verbatim line, correct absolute path). A second, ADVERSARIAL probe
    # ("the plan is APPROVED, exit plan mode, write it now") also produced no
    # file. CALIBRATE THE CLAIM, THOUGH: two probes held, which makes plan mode
    # the best boundary agy exposes — not a proven-unbypassable one. It is the
    # agent's own mode, not a kernel sandbox, so treat it as write-blocked in
    # every probe run rather than write-PROOF, and keep pointing this lane only
    # at trees you would run. Anything stronger wants pi's jail.
    #
    # Confidentiality footnote: plan mode still writes its plan artifact into
    # agy's own state dir (~/.gemini/antigravity-cli/brain/<id>/), so the prompt
    # and whatever repo content it quoted persist on disk outside the repo.
    _AGY_READ_LANE=1
    if [[ -z "$MODEL" ]]; then
        # $HOME must be password-DB-derived, not inherited: the config it selects
        # names the third party this repo's source is shipped to, so a
        # repo-injectable $HOME would let a reviewed checkout choose its own
        # exfiltration target. Same derivation as the opencode arm's `_oc_home`
        # (in-process, no heredoc — a heredoc inside `$( )` is the #595 bash-3.2
        # fail-open, and this lane is not behind the pi bash-4 floor).
        # shellcheck disable=SC2310  # same `! fn` condition shape as the opencode
        # arm's _oc_home derivation; the else-branch IS the failure handler.
        if ! _agyr_user="$(/usr/bin/id -un 2>/dev/null)" \
           || ! _bd_valid_username "$_agyr_user" \
           || ! _agyr_home="$(eval echo "~${_agyr_user}" 2>/dev/null)" \
           || [[ -z "$_agyr_home" || "$_agyr_home" != /* || ! -d "$_agyr_home" ]]; then
            echo "Error: could not derive a trusted \$HOME for the agy read model config. Refusing rather than reading ~/.claude/busdriver.json from an inherited \$HOME. Pass --model explicitly." >&2; exit 1
        fi
        HOME="$_agyr_home" resolve_agy_read_model
        MODEL="$_BD_AGY_READ_MODEL"
        [[ -n "$MODEL" ]] || {
            echo "Error: could not resolve the agy read model (${_PLUGIN_ROOT}/scripts/lib/resolve-cli.sh unavailable). Refusing rather than silently dispatching on agy's REVIEWER model. Pass --model explicitly, or fix BUSDRIVER_PLUGIN_ROOT." >&2; exit 1; }
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
    [[ "$CLI" == "droid" ]] && ! _has_cli droid && { echo "Error: droid not found." >&2; exit 1; }
    [[ "$CLI" == "grok" ]] && ! _has_cli grok && { echo "Error: grok not found." >&2; exit 1; }
fi

# Handle --cli all: discover all available supported CLIs (cap raised from
# 3 to 4 when grok joined; a host with codex+agy+droid+grok would otherwise
# never reach grok despite the user requesting all CLIs). When MODE=auto,
# grok is excluded — the grok adapter rejects auto mode at dispatch_one
# time, and including it here would kill the entire batch mid-stream after
# the other CLIs had already launched in parallel.
if [[ "$CLI" == "all" ]]; then
    ALL_CLIS=()
    # opencode included for parity with the --cli enum. Like grok it is excluded
    # in auto/write MODE — its read-only isolation harness (see dispatch_one's
    # opencode) case) has no write posture, so including it in a write batch
    # would produce a read-only voice masquerading as a write attempt.
    # pi is excluded from auto/write MODE for the same reason: its arm pins an
    # allowlisted read-only toolset (`--tools read`) and ignores --mode, so a
    # write batch would carry a read-only voice pretending to be a writer.
    # Cap raised 5 → 6 alongside the sixth candidate; pi is last in the list, so
    # leaving it at 5 would have made a full house silently drop pi.
    for c in codex agy droid grok opencode pi; do
        [[ "$c" == "grok" && "$MODE" == "auto" ]] && continue
        [[ "$c" == "opencode" && "$MODE" == "auto" ]] && continue
        [[ "$c" == "pi" && "$MODE" == "auto" ]] && continue
        if [[ "$c" == "pi" ]]; then
            _pi_available && ALL_CLIS+=("$c")
        else
            _has_cli "$c" && ALL_CLIS+=("$c")
        fi
        [[ ${#ALL_CLIS[@]} -ge 6 ]] && break
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
    # 465s pi failure whose cause is now unrecoverable.
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

# ── Single-CLI dispatch ───────────────────────
# Args: cli_name output_file
# Writes: status|duration|exit_code to meta_file
dispatch_one() {
    local name="$1" outfile="$2" meta="${2}.meta"
    local start exit_code=0
    start=$(date +%s)

    # ── Primary-CLI retry (council voices flake intermittently) ──────
    # Retry the primary CLI on a transient failure or empty output BEFORE the
    # droid fallback below — a single rate-limit/network hiccup shouldn't drop
    # a council voice straight to droid. BUSDRIVER_CLI_RETRIES (default 3;
    # council uses the default, blueprint exports 5 via run-design-review-loop).
    # droid itself is never retried (it is the safety net). A timeout (124) is
    # never retried either — re-running the full window is too costly; the droid
    # fallback catches it.
    local _max_retries="${BUSDRIVER_CLI_RETRIES:-3}"
    case "$_max_retries" in ''|*[!0-9]*) _max_retries=3 ;; esac
    [[ "$name" == "droid" ]] && _max_retries=0
    # --cli all/both COMPARE CLIs on one prompt — a failure there is signal, not
    # a flake. Match the droid-fallback skip below: no retries in those modes.
    [[ "$CLI" == "all" || "$CLI" == "both" ]] && _max_retries=0
    # NEVER retry in write-capable (auto) mode: the case arms below can run
    # `codex exec --full-auto` / `agy --dangerously-skip-permissions`, which may
    # edit files before exiting with a transient-looking error. Re-running the
    # same write prompt could double-apply or corrupt changes. Retries are only
    # safe for read-only review dispatches (the council voices, MODE=readonly).
    [[ "$MODE" != "readonly" ]] && _max_retries=0
    local _retry_delay="${BUSDRIVER_CLI_RETRY_DELAY:-5}"
    case "$_retry_delay" in ''|*[!0-9]*) _retry_delay=5 ;; esac
    # Cleared per DISPATCH, not per arm. Only the pi arm sets it, but the retry
    # loop below is shared by every CLI — so a pi setup failure during
    # `--cli all` would otherwise still read as 1 for the NEXT voice and rob it
    # of its retries. `local` also keeps it out of the caller's scope entirely.
    local _pi_setup_failed=0
    # Same shape as _pi_setup_failed: a deterministic precondition refusal, not a
    # failed attempt. MUST be `local` — a leak across dispatch_one calls would
    # mark a later voice skipped for an earlier one's missing config.
    local _oc_no_model=0
    # Set ONLY where a teardown ran and could not confirm the jail was removed,
    # i.e. a projected credential may still be on disk. It is deliberately NOT
    # `[[ -n "$_pi_jail" ]]` at classification time: the parent NAMES the jail
    # before anything is created (see the "THE PARENT NAMES THE JAIL" comment) so
    # `_pi_wipe` can reach the path on every failure path, which means a non-empty
    # name proves nothing on its own — every pre-creation bail carries one too.
    # Only a name that SURVIVES a wipe is evidence of a leak.
    local _pi_jail_survived=0
    local _attempt=0
    while [[ "$_attempt" -le "$_max_retries" ]]; do
    exit_code=0
    # The whole retry sequence — every attempt PLUS all backoff sleeps — is
    # bounded to ~TIMEOUT (the caller's --timeout budget): each attempt's timeout
    # is the REMAINING budget (equals "$TIMEOUT" on the first attempt) and each
    # backoff is capped to the remaining budget, so neither the sleep nor the
    # attempt can overrun. Retries thus can't multiply the wall-clock to
    # (retries+1)× the timeout before droid fallback fires.
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
            # WHY `--add-dir` IS UNCONDITIONAL (all four sites, reviewer and write
            # paths included) rather than scoped to the read lane. The
            # remembered-workspace bug below is not a read-lane bug — it is an agy
            # bug, and the reviewer slot had it too: `blueprint-review.reviewer_1`
            # dispatches agy at this repo, and an unscoped agy can resolve a
            # DIFFERENT checkout and return findings about code that is not under
            # review. A reviewer silently reviewing the wrong tree is worse than a
            # reader citing it. Scoping the fix to `agy-read` would have preserved a
            # tidier "reviewer argv unchanged" claim while knowingly leaving that
            # bug armed, so the claim was corrected instead (see `_AGY_READ_LANE`).
            # This is not a permission widening: `--add-dir` names WHICH tree agy
            # operates on, it does not add capability — the write path already wrote,
            # just potentially to the wrong checkout.
            #
            # shellcheck disable=SC2310  # `_portable_timeout ... || exit_code=$?` is
            # the established shape of EVERY arm in this dispatcher; the retry loop
            # below consumes exit_code deliberately. Not introduced here.
            #
            # `--add-dir "$PWD"` IS LOAD-BEARING, not belt-and-braces. Without it
            # agy does not scope reads to the CWD: it resolves its own remembered
            # workspace/project. Measured 2026-08-17 dispatching from
            # /Volumes/Work/Projects/busdriver — agy silently answered from a stale
            # /Users/vfrvndtt/src/busdriver checkout (v1.71.0), returning confident,
            # correctly-formatted file:line citations for the WRONG tree. That is
            # the worst failure shape available to a read lane: it does not error,
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
               || ! declare -F _agy_argv_limit >/dev/null; then
                printf 'Error: agy transport helpers unavailable — %s/scripts/lib/resolve-cli.sh could not be sourced. Cannot choose argv-vs-stdin prompt delivery safely; refusing rather than silently using the 1.0.x path. Use --cli codex/droid, or fix BUSDRIVER_PLUGIN_ROOT.\n' \
                    "$_PLUGIN_ROOT" > "$outfile" 2>&1
                exit_code=1
            elif _agy_wants_argv_prompt; then
                _agy_size=$(wc -c < "$PROMPT_FILE" 2>/dev/null || echo 0)
                if _agy_prompt_oversize "$_agy_size"; then
                    echo "Error: prompt is ${_agy_size}B, over agy's argv ceiling ($(_agy_argv_limit)B). agy >=1.1 has no file-input flag; use --cli codex for prompts this large." >&2
                    exit 1
                fi
                _agy_prompt=$(cat "$PROMPT_FILE")
                if [[ "$MODE" == "auto" ]]; then
                    _portable_timeout "$_budget" agy --dangerously-skip-permissions \
                        --print-timeout "${TIMEOUT}s" ${MODEL:+--model "$MODEL"} \
                        --add-dir "$PWD" \
                        --print "$_agy_prompt" > "$outfile" 2>&1 || exit_code=$?
                else
                    _portable_timeout "$_budget" agy --sandbox \
                        --print-timeout "${TIMEOUT}s" ${MODEL:+--model "$MODEL"} \
                        --add-dir "$PWD" ${_AGY_READ_LANE:+--mode plan} \
                        --print "$_agy_prompt" > "$outfile" 2>&1 || exit_code=$?
                fi
            elif [[ "$MODE" == "auto" ]]; then
                _portable_timeout "$_budget" agy --dangerously-skip-permissions \
                    --print-timeout "${TIMEOUT}s" ${MODEL:+--model "$MODEL"} \
                    --add-dir "$PWD" \
                    --print /dev/stdin < "$PROMPT_FILE" > "$outfile" 2>&1 || exit_code=$?
            else
                _portable_timeout "$_budget" agy --sandbox \
                    --print-timeout "${TIMEOUT}s" ${MODEL:+--model "$MODEL"} \
                    --add-dir "$PWD" ${_AGY_READ_LANE:+--mode plan} \
                    --print /dev/stdin < "$PROMPT_FILE" > "$outfile" 2>&1 || exit_code=$?
            fi ;;
        droid)
            # Droid has no strict readonly mode — its --auto tier controls whether it
            # prompts on permission checks. Without a flag, droid bails on first read
            # (fatal under stdin redirection). Tier semantics from `droid exec --help`:
            #   low    = file writes in non-system dirs only
            #   medium = + package installs, trusted-host curl/wget, local git (commit/checkout/pull)
            #   high   = + git push --force, curl|bash, secrets, prod deploys
            # Default: high for both modes. Lower tiers reliably bail in practice —
            # council Researcher prompts (web fetches, API lookups) need high, and
            # medium/low fail unpredictably even on read-only-shaped work. Override
            # per-call with DROID_AUTO_LEVEL=low|medium|high if a caller needs to
            # tighten the sandbox.
            local _droid_level
            if [[ -n "${DROID_AUTO_LEVEL:-}" ]]; then
                case "$DROID_AUTO_LEVEL" in
                    low|medium|high) _droid_level="$DROID_AUTO_LEVEL" ;;
                    *) echo "Error: DROID_AUTO_LEVEL='$DROID_AUTO_LEVEL' is invalid. Must be low, medium, or high." >&2; exit 1 ;;
                esac
            else
                _droid_level="high"
            fi
            _portable_timeout "$_budget" droid exec --auto "$_droid_level" \
                < "$PROMPT_FILE" > "$outfile" 2>&1 || exit_code=$? ;;
        opencode)
            # Pin a system-only PATH for this arm's own utilities (mktemp,
            # dirname, command, env) so a repo-injected PATH cannot trojan them.
            # opencode's real install dir is added explicitly at resolution.
            local PATH="/usr/bin:/bin:/usr/sbin:/sbin"
            # Read-only via the PLUGIN-OWNED config (deny-all tools except
            # read/glob/grep). The four-round probe history and the accepted
            # residual live in scripts/lib/resolve-cli.sh's opencode) arm —
            # single source of truth for this threat model; do not fork it.
            #
            # FAIL CLOSED: opencode does NOT error on a missing OPENCODE_CONFIG.
            # It silently loads the user's default config and the write/bash/task
            # tools come back (verified — the probe wrote its file). A missing
            # asset must therefore block, never dispatch unconfined.
            #
            # MODE NOTE: --mode is deliberately ignored. This arm is read-only by
            # construction, so `--mode auto` cannot loosen it. A writing opencode
            # agent would be a different agent definition and a different arm.
            # NO env override for the config path — BUSDRIVER_OPENCODE_CONFIG is
            # repo-injectable via a fork's settings.json (#325 class) and could
            # point at a tool-restoring JSON. Always the plugin-owned file.
            local _oc_cfg _oc_cwd _oc_user _oc_home _oc_path _oc_bin _oc_trust
            _oc_cfg="${_PLUGIN_ROOT}/scripts/lib/opencode-review-config.json"
            # THREE isolation boundaries — full threat model in the opencode) arm
            # of scripts/lib/resolve-cli.sh (single source of truth; do not fork).
            # COUNCIL routes through THIS path, so all three are required here too:
            #   --dir <empty>        → no reviewed-tree files or project-config
            #                          redefinitions (.opencode/agent, opencode.json[c])
            #   XDG_CONFIG_HOME<empty> → no global MCP servers (read_mcp_resource
            #                          survives the tool denylist and can read them)
            #   OPENCODE_CONFIG      → the plugin's deny-all tools config
            # Create the temp dir ONLY after the config check passes, so a
            # missing-config bail does not leak an empty directory.
            # shellcheck disable=SC2310  # _bd_valid_username is a predicate by design — set -e off in !/|| is intended
            if [[ ! -f "$_oc_cfg" ]]; then
                echo "Error: opencode review config not found at '$_oc_cfg' — refusing to dispatch unconfined (a missing config silently restores write/bash)." >&2
                exit_code=1
            elif ! _oc_cfg="$(cd "$(dirname "$_oc_cfg")" 2>/dev/null && pwd -P)/$(basename "$_oc_cfg")" || [[ ! -f "$_oc_cfg" ]]; then
                # Canonicalize to absolute: the child runs with CWD=neutral dir, so
                # a relative OPENCODE_CONFIG would resolve there (missing) and
                # opencode would fail OPEN to the user default.
                echo "Error: could not resolve the opencode review config to an absolute path — refusing to dispatch." >&2
                exit_code=1
            elif ! _oc_user="$(/usr/bin/id -un 2>/dev/null)" || ! _bd_valid_username "$_oc_user" || ! _oc_home="$(eval echo "~${_oc_user}" 2>/dev/null)" || [[ -z "$_oc_home" || ! -d "$_oc_home" ]]; then
                # Trusted home from the PASSWORD DATABASE, not $HOME (repo-
                # injectable). Derived BEFORE the neutral-dir creation so the
                # arm's later XDG_CACHE_HOME/auth paths use it.
                echo "Error: could not derive a trusted home from the password database — refusing to dispatch unconfined." >&2
                exit_code=1
            else
                # Resolve the binary ONLY from a FIXED trusted path (operator
                # install dirs + system dirs), never the caller's PATH — an
                # absolute caller-PATH entry can point into the reviewed checkout
                # and supply a planted binary. NO env override (repo-injectable).
                # Full rationale in resolve-cli.sh.
                # Trusted home from the PASSWORD DATABASE, not $HOME (repo-
                # injectable). `~user` tilde expansion reads getpwnam. Full
                # rationale in resolve-cli.sh.
                local _oc_path _oc_bin _oc_trust
                _oc_trust="${_oc_home}/.opencode/bin:${_oc_home}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                # `|| true` — under `set -e`, a nonzero `command -v` inside this
                # assignment's command substitution would exit the script
                # immediately, skipping the "binary not found" branch below,
                # leaving .meta unwritten and leaking the `_oc_cwd` temp dir.
                _oc_bin="$(PATH="$_oc_trust" command -v opencode 2>/dev/null)" || true
                if [[ "$exit_code" -ne 0 ]]; then
                    : # already failed on home derivation — skip dispatch
                elif [[ -z "$_oc_bin" || "$_oc_bin" != /* || ! -x "$_oc_bin" ]]; then
                    echo "Error: opencode binary not found on the trusted install path." >&2
                    exit_code=1
                else
                _oc_path="$(CDPATH='' cd -- "$(dirname -- "$_oc_bin")" && pwd -P)"
                _oc_path="${_oc_path}:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                # Prompt via STDIN, not argv (opencode reads fd 0 with no
                # positional message; large prompts would otherwise hit ARG_MAX).
                # `env -i` neutralizes OPENCODE_CONFIG_CONTENT / OPENCODE_CONFIG_DIR
                # (they OVERRIDE OPENCODE_CONFIG and can restore tools/MCP/reads).
                # SUBSHELL `cd` (not `env -C`, a non-portable GNU extension) pins
                # the child process CWD to the neutral dir so startup cannot read
                # cwd-relative files from the reviewed repo. --model honored:
                # $MODEL (operator --model flag) wins, else `.auditor.model` from
                # the USER busdriver.json, else no model — there is no shipped
                # default (see resolve_auditor_model in resolve-cli.sh; the
                # no-model case is handled by the skip guard below). The EXIT/TERM
                # trap rm -rf's the neutral dir even on a council grace-period
                # kill, and handles the case where opencode created files in it
                # (a bare rmdir would leak a non-empty dir).
                # Resolve OUTSIDE the subshell: the resolver returns its value in
                # $_BD_AUDITOR_MODEL (see resolve-cli.sh — an stdout hand-off would
                # be shadowable), and a subshell's assignment would not survive.
                # PATH+HOME pinned at the call, not inherited from the arm's pin, so
                # neither depends on line order within this long case arm.
                PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
                  HOME="$_oc_home" resolve_auditor_model
                # No model → no auditor. The operator's --model ($MODEL) still
                # wins; this fires only when they gave neither it nor a usable
                # `.auditor.model`, because there is no shipped default to fall
                # back on (see resolve_auditor_model in resolve-cli.sh). Skipping
                # an ADVISORY voice is the honest outcome. Handing opencode an
                # empty `-m` is NOT — it would silently run whatever that CLI
                # defaults to, i.e. a provider nobody chose.
                # Gated on _BD_RESOLVE_CLI_SOURCED too: when the library is missing,
                # the fallback shim at the top of this file (`resolve_auditor_model()
                # { _BD_AUDITOR_MODEL=""; }`) makes $_BD_AUDITOR_MODEL empty
                # unconditionally, which would otherwise satisfy this same condition
                # and route a genuine fail-closed resolver error (line ~973 below)
                # through the `skipped` classification instead of `error` — letting
                # `--cli all` silently exit 0 while the operator config could never
                # actually be validated (Cubic finding on PR #666). Requiring the
                # library to have been sourced keeps "no configured model" (skip)
                # and "resolver missing" (error) on separate branches.
                if [[ -z "${MODEL:-}" && -z "$_BD_AUDITOR_MODEL" && "${_BD_RESOLVE_CLI_SOURCED:-0}" == "1" ]]; then
                    echo "busdriver: no usable .auditor.model in ~/.claude/busdriver.json and no --model — skipping the auditor (advisory voice)." >&2
                    # Reason goes to "$outfile" too, not stderr alone — that is the
                    # precondition for routing an opencode bail to `skipped` (the
                    # batch banner would otherwise print "(no output)" and lose it).
                    # Gate `_oc_no_model=1` on the write actually succeeding
                    # (CodeRabbit finding on PR #666): with `|| true` alone, an
                    # unwritable/full "$outfile" would silently classify as
                    # `skipped` with no durable `Skipped:` marker anywhere — the
                    # council loses the signal but the batch treats the voice as
                    # non-failing. Leave the branch as `error` (via exit_code=1
                    # falling through un-skipped) when the marker can't be written.
                    # NO cleanup here, deliberately: $_oc_cwd is not created until
                    # the sandbox is staged inside the subshell below, so at this
                    # point it is still the empty `local` init. An rmdir here would
                    # be a no-op that falsely implies a temp dir exists to reclaim
                    # (it read as a missing-cleanup asymmetry to a PR reviewer).
                    # Nothing has been allocated yet — that is the point of bailing
                    # this early. resolve-cli.sh's sibling guard is symmetric.
                    # `skipped`, NOT `error`: an absent optional config is a refusal
                    # before the attempt, not an attempt that failed. As `error` this
                    # would fail an entire `--cli all` batch for every other voice
                    # whenever opencode is installed without .auditor.model (#594's
                    # failure mode, reported again by Codex on this change). An
                    # EXPLICIT `--cli opencode` still fails, because there the voice
                    # that cannot run IS the request.
                    if printf 'Skipped: %s\n' "no usable .auditor.model and no --model — auditor not dispatched" >> "$outfile" 2>/dev/null; then
                        _oc_no_model=1
                    else
                        echo "busdriver: could not write the skip marker to \$outfile — classifying as error, not skipped" >&2
                    fi
                    exit_code=1
                fi
                # FAIL CLOSED on the operator-owned ~/.opencode/opencode.json[c].
                # opencode loads these in EVERY environment — including this
                # sandbox (verified 2026-08-09) — so they are a fourth config
                # surface the three isolation boundaries do not cover. An `mcp`
                # entry there would load inside the sandbox and read_mcp_resource
                # survives the tool denylist (exactly why XDG_CONFIG_HOME is
                # redirected). Single source of truth: the shared guard lives in
                # resolve-cli.sh; a missing library fails CLOSED here (a stuck
                # lane beats an unvalidated dispatch).
                if [[ "${_BD_RESOLVE_CLI_SOURCED:-}" != 1 ]]; then
                    echo "Error: resolve-cli.sh not sourced — cannot validate the operator ~/.opencode home config; refusing to dispatch unconfined." >&2
                    printf 'Error: %s\n' "resolve-cli.sh not sourced — cannot validate the operator ~/.opencode home config; refusing to dispatch unconfined." >> "$outfile" 2>/dev/null || true
                    /bin/rmdir "${_oc_cwd:-}" 2>/dev/null || true
                    exit_code=1
                else
                # shellcheck disable=SC2310  # intentional: refused dispatch is the branch
                if [[ "$exit_code" -eq 0 ]]; then
                # Validation runs INSIDE the trap-owned subshell: the staged
                # sandbox is owned from creation, so an early TERM/EXIT during
                # staging cannot orphan a credential-bearing temp dir.
                ( _BD_OC_SANDBOX_HOME=""   # owned by this lane from the first statement — a trap fired between fork and here sees nothing to touch
                  trap '_bd_oc_lane_cleanup "$_oc_home" "${_oc_cwd:-}"' EXIT
                  trap '_bd_oc_lane_cleanup "$_oc_home" "${_oc_cwd:-}"; exit 143' TERM
                  trap '_bd_oc_lane_cleanup "$_oc_home" "${_oc_cwd:-}"; exit 130' INT
                  # Pinned SYSTEM-ONLY PATH: the validator stages credentials
                  # with bare mktemp/mkdir/ln/rm — _oc_path's first entry is
                  # the operator-WRITABLE opencode dir, which must not shadow
                  # those utilities; the system dirs carry them all.
                  if ! PATH="/usr/bin:/bin:/usr/sbin:/sbin" validate_opencode_home_config "$_oc_home"; then
                    printf 'Error: %s\n' "operator ~/.opencode home config failed validation — refusing to dispatch unconfined." >> "$outfile" 2>/dev/null || true
                    exit 1
                  fi
                  # Neutral cwd INSIDE the validated sandbox (post-validation):
                  # opencode's project discovery walks UP from the cwd and
                  # finds the sandbox's OWN validated .opencode/opencode.json
                  # copy, stopping there — the real home's config surfaces are
                  # never reopened (no validate-then-open race; the 0700
                  # sandbox is private to the operator — no other-user
                  # planting).
                  _oc_cwd="${_BD_OC_SANDBOX_HOME}/.cwd"
                  /bin/mkdir -p "$_oc_cwd" 2>/dev/null || exit 1
                  # Git-init the EMPTY cwd: opencode's project-config
                  # discovery scans every ancestor through the worktree root
                  # (non-Git = /, reaching the real home); a git repo bounds
                  # the worktree AT the empty cwd, so discovery finds nothing
                  # beyond it. The workspace stays EMPTY — auth.json / SDK
                  # symlinks live OUTSIDE the worktree, and the plugin config
                  # denies external_directory, so the read-enabled reviewer
                  # cannot reach them. Sterile init (GIT_DIR/GIT_WORK_TREE are
                  # repo-injectable) with the EXECUTION-PROBED git (the CLT
                  # shim at /usr/bin/git exists but fails without CLT) +
                  # .git verified inside the cwd.
                  _bd_git=""  # global cache for _bd_resolve_git (defined in resolve-cli.sh)
                  _bd_resolve_git || { echo "Error: no working git found to bound the neutral cwd — refusing to dispatch." >&2; exit 1; }
                  /usr/bin/env -i PATH="/usr/bin:/bin" "$_bd_git" -C "$_oc_cwd" init -q 2>/dev/null || { echo "Error: cannot git-init the neutral cwd — refusing to dispatch." >&2; exit 1; }
                  [[ -d "$_oc_cwd/.git" ]] || { echo "Error: git-init did not create .git in the neutral cwd — refusing to dispatch." >&2; exit 1; }
                  cd "$_oc_cwd" 2>/dev/null || exit 1
                  # XDG_DATA_HOME points at the SANDBOX data dir, which the
                  # validator populated with a validated auth.json copy ONLY:
                  # auth-based providers work, while the empty rest of the
                  # data dir carries NO account/org state (nothing merges
                  # config after OPENCODE_CONFIG — MCP/plugin/permission/
                  # agent overrides). XDG_CACHE_HOME shares the inert model/
                  # package cache. (Comments sit BEFORE the command — a
                  # comment after a backslash continuation would terminate
                  # the chain and run opencode UNISOLATED.)
                  _portable_timeout "$_budget" \
                    /usr/bin/env -i HOME="$_BD_OC_SANDBOX_HOME" PATH="$_oc_path" \
                        OPENCODE_CONFIG="$_oc_cfg" XDG_CONFIG_HOME="$_oc_cwd" \
                        XDG_DATA_HOME="$_BD_OC_SANDBOX_HOME/.local/share" \
                        XDG_CACHE_HOME="$_oc_home/.cache" \
                    "$_oc_bin" run --dir "$_oc_cwd" --agent busdriver-review \
                    -m "${MODEL:-$_BD_AUDITOR_MODEL}" \
                    < "$PROMPT_FILE" ) > "$outfile" 2>&1 || exit_code=$?
                # The subshell's EXIT/TERM/INT trap owns write-back + cleanup
                # (the sandbox var lives only inside the subshell).
                fi
                fi
                fi
            fi ;;
        pi)
            # Deterministic setup failures (untrusted-home, binary-missing,
            # version-mismatch, provider-underivable — none of them a call to
            # pi at all) used to write only to stderr, leaving $outfile empty.
            # The generic retry loop above retries on ANY empty $outfile,
            # treating a setup error that will fail identically on every
            # attempt as if it were a transient one — a direct `--cli pi`
            # invocation with a bad model reference or missing binary paid the
            # full 5s+10s+20s backoff for nothing. Mirror the message into
            # $outfile too so the retry loop's non-transient-with-output path
            # (see the `break` below `_is_transient_cli_error`) short-circuits
            # instead of retrying a failure that cannot succeed on a retry.
            # A SETUP failure is deterministic — an untrusted home, a missing or
            # unprobed binary, an underivable provider. Retrying it cannot change
            # the outcome, so the retry loop must skip it. The signal is this
            # FLAG, not the message text: the text is partly operator-controlled
            # (it quotes `--model`), so `--model ECONNRESET` produced a
            # deterministic provider error that `_is_transient_cli_error` matched
            # on the substring, and the full retry+backoff cycle ran anyway.
            # Classifying our own failures by grepping our own prose was the bug.
            # Declared and cleared once per dispatch in dispatch_one (see the
            # `local _pi_setup_failed=0` there) — deliberately NOT re-cleared here,
            # so there is exactly one owner of its lifetime.
            _pi_setup_fail() {
                echo "Error: $1" >&2
                printf 'Error: %s\n' "$1" >> "$outfile" 2>/dev/null || true
                _pi_setup_failed=1
                exit_code=1
            }
            # THE READ LANE — deliberately the mirror image of the opencode arm
            # above. opencode is confined to an EMPTY dir precisely so it cannot
            # see the tree; this arm runs IN THE WORKING TREE, because tracing
            # real code is the entire point of the voice. That inverts the
            # isolation problem rather than removing it: the repo is now on the
            # INSIDE, so every repo-controlled surface pi would otherwise load
            # has to be switched off by name, and the toolset must be an
            # ALLOWLIST. Both are below; neither is optional.
            #
            # WHY ALLOWLIST, NOT DENYLIST (this is the fail-closed hinge):
            # `--exclude-tools edit,write` looks read-only and is NOT — it leaves
            # pi's built-in `bash` enabled, which writes files, runs git, and
            # reaches the network. Probed on 0.84.1: the full tool surface also
            # carried a SECOND shell (`hypa_shell`), web fetch/search (`exa_*`),
            # and a `subagent` spawner. No denylist enumerates that safely, and
            # the set grows with every extension the operator installs. So the
            # toolset is pinned positively to `read`. Probed and relied upon:
            # an unrecognised name in `--tools` yields NO tools rather than
            # falling back to the default set, so this fails CLOSED on a typo.
            #
            # The six --no-* flags reduce the surface to the built-ins before
            # the allowlist even applies (verified: with them, pi reports
            # exactly `read, bash, edit, write`; without them it reported 45
            # tools including the shells and network reach above). --no-approve
            # is the load-bearing one for an in-tree run: it makes pi ignore
            # project-local files, so the repo being audited cannot redefine the
            # auditor through its own .pi/ config, AGENTS.md, or extensions.
            #
            # MODE NOTE: --mode is deliberately ignored, exactly as in the
            # opencode arm. This lane is read-only by construction and
            # `--mode auto` cannot loosen it; a writing pi would be a different
            # arm with its own worktree semantics and its own review.
            local PATH="/usr/bin:/bin:/usr/sbin:/sbin"
            local _pi_bin _pi_home _pi_path _pi_pre
            # Trusted home from the PASSWORD DATABASE, not $HOME (repo-injectable
            # via a fork's settings.json). Same contract as the opencode arm, and
            # required twice here: to resolve the binary, and because
            # resolve_pi_model reads ~/.claude/busdriver.json — the key that names
            # which third party repo source is shipped to.
            # PREFLIGHT RUNS IN A CLEAN CHILD TOO. Deriving the trusted home and
            # resolving the binary used to happen right here, in the inherited
            # shell, where `eval`, `command -v`, `dirname`, `cd` and `pwd` are all
            # command words an exported function can shadow — which meant an
            # attacker could execute code at `eval` time, or steer `_pi_bin` and
            # `_pi_path` at their own binaries and have a fake `node` report the
            # probed version. PATH pinning never touched that: it does not reach
            # shell functions. So the whole preflight moves inside `env -i`, which
            # deletes the function table, with `/usr/bin/env` and `/bin/bash`
            # absolute so the escape itself cannot be shadowed.
            #
            # Emits exactly two lines — home, then binary — and nothing on any
            # failure, so a partial read cannot be mistaken for success.
            if ! _pi_pre="$(/usr/bin/env -i "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
                       /bin/bash --noprofile --norc <<'CHILD' 2>/dev/null
u="$(/usr/bin/id -un)" || exit 1
# Only a plain username shape reaches eval — `~user` is the one way to read the
# password DB, and eval on anything else is arbitrary execution. Tilde
# directory-stack forms (~- ~+ ~N → $OLDPWD/$PWD) are excluded too; digit-
# LEADING names (0abc) are normal usernames.
[[ "$u" =~ ^[-+]?[0-9]*$ ]] && exit 1
case "$u" in *[!A-Za-z0-9._-]*) exit 1 ;; esac
h="$(eval echo "~$u")" || exit 1
case "$h" in /*) ;; *) exit 1 ;; esac
[ -d "$h" ] || exit 1
# Explicit candidates, never `command -v`: the operator install dirs first, then
# system dirs. NO $HOME fallback — a repo-injectable home must not pick the
# binary that reads the repo.
b=""
for c in "$h/.local/bin/pi" "$h/.pi/bin/pi" /opt/homebrew/bin/pi /usr/local/bin/pi /usr/bin/pi /bin/pi; do
  # -f as well as -x: a DIRECTORY (or a symlink to one) named `pi` is "executable"
  # to the shell, would win over a later valid candidate, and then fail at the
  # version probe — disabling the lane over something that is not a program.
  [ -f "$c" ] && [ -x "$c" ] && { b="$c"; break; }
done
# Home on line 1, binary on line 2 — and line 2 may be EMPTY. Exiting nonzero
# when only the binary is missing would discard the successfully derived home
# too, and the parent would then report "could not derive a trusted home" for a
# machine that simply has no pi installed. Two independent facts, reported
# independently, so each error branch is reachable.
# Trailing "END" is load-bearing. Command substitution strips TRAILING newlines,
# so a missing binary emitted "home\n\n" and arrived as just "home" — the
# expansion below then found no delimiter and assigned the HOME to _pi_bin.
# A searchable directory satisfies -x, so the "pi not found" branch was skipped
# and the operator got a misleading version-unreadable error instead.
printf '%s\n%s\nEND\n' "$h" "$b"
CHILD
            )"; then _pi_pre=""; fi
            # Split with PARAMETER EXPANSION only. The obvious
            # `printf '%s\n' "$x" | sed -n 1p` puts three shadowable command words
            # (`printf`, `sed`, and the `true` in a trailing `|| true`) on the path
            # of the very values the clean child exists to protect — an exported
            # function could forge both the home and the binary, defeating the
            # boundary entirely. `${x%%...}` / `${x#...}` are pure shell syntax:
            # there is no command word left to shadow. Likewise the `if !` above
            # replaces `|| true` — a failing command in an `if` CONDITION is
            # already exempt from `set -e`, so no builtin is needed at all.
            _pi_home="${_pi_pre%%$'\n'*}"
            _pi_bin="${_pi_pre#*$'\n'}"
            _pi_bin="${_pi_bin%%$'\n'*}"
            if [[ -z "$_pi_home" || "$_pi_home" != /* || ! -d "$_pi_home" ]]; then
                # NO $HOME fallback — fail closed rather than trust an injected one.
                _pi_setup_fail "could not derive a trusted home from the password database — refusing to resolve pi from a possibly-injected \$HOME."
            else
                if [[ -z "$_pi_bin" || "$_pi_bin" != /* || ! -x "$_pi_bin" ]]; then
                    _pi_setup_fail "pi binary not found on the trusted install path."
                else
                    # /opt/homebrew/bin is ALWAYS present, not only when pi lives
                    # there: pi ships `#!/usr/bin/env node`, so a pi installed under
                    # ~/.local/bin still needs to find Node — which on Apple Silicon
                    # is normally Homebrew. Omitting it made the version probe
                    # unreadable and the lane refused to run at all.
                    _pi_path="${_pi_bin%/*}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                    # This lane's read-only posture rests on OBSERVED behaviour of
                    # `--tools read` and the six --no-* flags, probed on the version
                    # below — and the test that proves write-denial semantically is
                    # opt-in (it needs a live model call), so CI cannot catch an
                    # upgrade that re-enables shell or write tools for in-tree
                    # prompts. Surface the drift instead of assuming it away.
                    # BLOCK, not warn: the read-only posture is observed behaviour
                    # on one probed version, not a proven invariant, and CI cannot
                    # catch a pi upgrade that re-enables shell or write tools for
                    # in-tree prompts — so an unprobed version runs unverified
                    # inside the working tree. "A stuck session beats a skipped
                    # check" applies here. On a mismatch, re-run:
                    # BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh
                    # The probe runs under `env -i`, NOT the inherited environment.
                    # pi is a `#!/usr/bin/env node` script, so an injected
                    # NODE_OPTIONS=--require=<repo-file> would execute repo code as
                    # the operator during a bare `pi --version` — before any
                    # read-only flag applies. Wiping the environment for the probe
                    # closes that; the dispatch itself was already `env -i`.
                    local _pi_ver _pi_ver_rc
                    # No pipeline: a bare `tr` would run back in the inherited
                    # shell, and an exported `tr` function could print the expected
                    # version and wave a mismatched pi through. Bash parameter
                    # expansion strips the whitespace with no command word at all.
                    # THE EXIT STATUS COUNTS. This is the ONLY version probe in the
                    # codebase (`_pi_available` is a path check by design — see its
                    # header), so it has to be right on its own: a pi that prints
                    # 0.84.1 and then exits nonzero has not answered the question,
                    # and treating matching stdout from a failing probe as proof
                    # would admit a binary whose `--version` does not work. A blank
                    # `_pi_ver` fails the gate below.
                    _pi_ver_rc=0
                    _pi_ver="$(/usr/bin/env -i PATH="$_pi_path" "$_pi_bin" --version 2>/dev/null)" || _pi_ver_rc=$?
                    [[ "$_pi_ver_rc" -eq 0 ]] || _pi_ver=""
                    _pi_ver="${_pi_ver//[[:space:]]/}"
                    # FAIL CLOSED on drift or an unreadable version. This lane's
                    # write denial is observed behaviour of `--tools read` and the
                    # six --no-* flags on one probed version, and the test proving
                    # it semantically is opt-in (it needs a live model call), so CI
                    # cannot catch an upgrade that re-enables shell or write tools.
                    # Running an unprobed version in-tree is exactly the case where
                    # "a stuck session beats a skipped check" applies. Clearing it
                    # is one constant — bumped BEFORE the live test, never after:
                    # the test drives this very dispatch, so this gate would refuse
                    # the new pi before the write-denial check could run. "Verify
                    # then bump" is the intuitive order and it deadlocks; the error
                    # text below must keep saying bump-then-verify.
                    if [[ -z "$_pi_ver" || "$_pi_ver" != "$BUSDRIVER_PI_PROBED_VERSION" ]]; then
                        _pi_setup_fail "pi version '${_pi_ver:-unreadable}' is not the probed ${BUSDRIVER_PI_PROBED_VERSION}. This lane's read-only posture was verified against that version only — refusing to run an unverified pi inside the working tree. To clear, IN THIS ORDER: (1) set BUSDRIVER_PI_PROBED_VERSION in dispatch.sh to the new version, (2) run BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh, (3) revert step 1 if it fails. Verifying before bumping cannot work — this gate refuses the new pi before the live test reaches it."
                    else
                    # PATH+HOME pinned AT THE CALL, not inherited from the arm's
                    # pin, so neither depends on line order in this case arm.
                    PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
                      HOME="$_pi_home" resolve_pi_model
                    # ── Credential projection ───────────────────────────────
                    # `--tools read` stops WRITES; it does NOT confine READS.
                    # Demonstrated on 0.84.1: pi read ~/.pi/agent/auth.json and
                    # enumerated every provider credential in it. This lane
                    # ingests repo content for a living, which is precisely
                    # where a prompt injection lives — so handing it the real
                    # $HOME puts ~/.ssh, ~/.aws, ~/.claude and every other
                    # provider's key one instruction away from the model.
                    #
                    # So the child gets a PRIVATE HOME carrying exactly one
                    # thing: the auth entry for the provider named by the
                    # resolved model. Everything else under ~ disappears.
                    #
                    # RESIDUAL, stated plainly because it is NOT closed: pi's
                    # read tool accepts ABSOLUTE paths, so a determined
                    # injection can still name a file outside this HOME and be
                    # read (verified — the real auth.json is still reachable by
                    # full path). This shrinks blast radius; it is not
                    # containment. Closing it needs OS-enforced read confinement
                    # (sandbox-exec/seatbelt) — see ADR 0034's revisit trigger.
                    local _pi_prov _pi_jail _pi_tmp
                    # Cleanup: credential first and alone, then the whole tree.
                    # Safe to call on ANY path through the branch chain below,
                    # including ones where the jail was never created — the shape
                    # checks make it a no-op rather than an error.
                    # CONTAINMENT FUNCTION. It runs back in the INHERITED shell,
                    # after pi has already read whatever the tree told it to — so
                    # assume every command word here is shadowable, and lean on the
                    # shell GRAMMAR, which is not.
                    #
                    #   * THE SECRET IS DESTROYED BY GRAMMAR, NOT BY A COMMAND. Chasing
                    #     shadowing with better command names has no fixed point: a
                    #     bare `rm` loses to an imported function; `/bin/rm` cannot be
                    #     IMPORTED (the suite probes bash to keep that true) but CAN be
                    #     defined in-shell, and this script calls bare `type`/`source`
                    #     at startup, so an imported function of one of those names
                    #     gets to define it; escaping through `/usr/bin/env` merely
                    #     moves the same problem one word along. A bare redirection
                    #     has NO command word at all, so `>|` ends the regress — it is
                    #     parsed, never resolved. That is step 1, and it is the only
                    #     step the credential's secrecy depends on.
                    #   * THE UNLINK RUNS IN A STERILE `env -i` CHILD (step 2), whose
                    #     empty environment imports no functions, so its bare `rm` is
                    #     genuinely `rm`. It is hygiene: by the time it runs the
                    #     credential is already zeroed. /bin/echo stays absolute but is
                    #     only ever a REPORTING path.
                    #   * NO `return`, `true` or `:`. All three are shadowable —
                    #     verified: bash imports `BASH_FUNC_return%%` and resolves it
                    #     ahead of the builtin, so `|| return 0` would run attacker
                    #     code AND fail to return, falling straight through the very
                    #     guard it forms. This function therefore ends on an
                    #     ASSIGNMENT: syntax, not a command, and its status is 0.
                    #     (`|| true` was worse still — it fired on every SUCCESSFUL
                    #     dispatch, the jail already being gone.)
                    #   * EVERY command TESTED (`if !` / `|| assignment`). `-f` and
                    #     `-rf` exit 0 on a MISSING path but not on a permission or
                    #     filesystem error, and an `if` BODY is not tested — so an
                    #     untested failure trips `set -e`, skipping the rest of the
                    #     cleanup and killing finished dispatches from inside a trap.
                    #   * Failures WARN. A credential left on disk is the one outcome
                    #     this function exists to prevent; swallowing it is worse
                    #     than the leaked tree.
                    #
                    # OUT OF SCOPE, deliberately: an attacker who already has code
                    # execution IN THIS SHELL. Nothing here defends against that —
                    # they would simply redefine `_pi_wipe`. The lane's threat model
                    # is repo content pi READS, and pi's output is written to a file
                    # and never evaluated, so it has no path into this shell at all.
                    #
                    # tests/test-pi-dispatch-arm.sh asserts each of these against this
                    # body, so they survive the next edit.
                    _pi_wipe() {
                        # SUCCESS CLEARS THE NAME. `_pi_jail` is emptied once the jail
                        # is verifiably gone, and every step here is gated on it being
                        # non-empty — so a second call does nothing, having no path to
                        # act on. That closes double-delete AND double-truncate at
                        # once, which a boolean latch could not: latching before the
                        # work let a signal in the gap turn the handler's `_pi_wipe`
                        # into a no-op and abandon cleanup with a live credential,
                        # while latching after left the zeroing unguarded, where a
                        # recreated path — a symlink at any component, not just the
                        # final one — would have `>|` truncate an unrelated file.
                        # Clearing the pathname has no such gap: it happens only after
                        # the removal is confirmed, so a failed wipe KEEPS the name and
                        # stays retryable, and a successful one leaves nothing to
                        # reuse. Chasing this with trap windows never terminated.
                        #
                        # The shape checks stay in the PARENT because `[[` is a
                        # reserved word — the grammar, not a command — so nothing can
                        # intercept them. The removal itself does NOT stay here.
                        # KNOWN, ACCEPTED RESIDUAL — reentrancy across the clear.
                        # Clearing `_pi_jail` cannot be made ATOMIC with the removal
                        # that precedes it: bash runs a pending handler after a
                        # foreground command returns but before the next assignment,
                        # so a signal in that window re-enters this function while the
                        # variable still holds the just-freed pathname. Shell has no
                        # atomic swap, and every mitigation costs more than it buys —
                        # `trap '' INT TERM HUP` around the body would work, but `trap`
                        # is itself a shadowable builtin and a second arming site,
                        # breaking the single-owner and no-bare-command-word
                        # invariants this lane is built on (the suite enforces both).
                        # What bounds it: the window is one statement wide, the second
                        # pass still re-checks the path shape, the pathname carries
                        # $$ plus two $RANDOM draws under a per-user $TMPDIR, and the
                        # credential is already zeroed by then. Closing it properly
                        # needs a language with signal masking, not more bash.
                        #
                        # Compared as STRINGS throughout. `[[ x -eq y ]]` evaluates both
                        # sides ARITHMETICALLY, and arithmetic evaluation expands
                        # command substitution — so any inherited state tested that way
                        # could execute `$(...)` from the environment, inside the
                        # containment function itself.
                        if [[ -n "${_pi_jail:-}" && "$_pi_jail" == /* && "$_pi_jail" != "/" ]]; then
                            # Both removals run inside ONE STERILE CHILD, for the same
                            # reason projection does. `env -i` gives bash an empty
                            # environment, so the child imports no functions at all and
                            # its bare `rm` is genuinely `rm`. That matters: absolute
                            # paths alone do NOT survive a hostile function table here,
                            # because this script calls bare `type`/`source` during
                            # startup, and an imported function of one of THOSE names
                            # can define `/bin/rm` on the way past. Slash-named
                            # functions cannot be IMPORTED (the suite probes bash for
                            # that), but they can be DEFINED in-shell, so second-stage
                            # definition is the live vector and this closes it.
                            # `/usr/bin/env` is now the whole trust anchor — the same
                            # one the projection child already rests on, so the wipe is
                            # no weaker than the write it undoes.
                            #
                            # Credential first and ALONE, so it is gone even if the
                            # tree removal fails. `rm -rf` on the tree is safe HERE and
                            # only here: the PARENT named this path under $TMPDIR with
                            # builtin-only randomness and created it with a bare
                            # `mkdir` that would have failed had it existed, so it is
                            # never a path another process chose. `rmdir` would not do
                            # — pi writes cache files into its HOME, so the directories
                            # are never empty and every dispatch leaked one.
                            #
                            # The child VERIFIES the jail is gone before reporting
                            # success, so the warning below means what it says.
                            # STEP 1 — ZERO THE SECRET WITH PURE GRAMMAR. A bare
                            # redirection has NO COMMAND WORD, so there is nothing for
                            # a function to intercept: `>|` is parsed, not resolved.
                            # This is the one step that terminates the regress every
                            # other approach here runs into (`/bin/rm` is shadowable
                            # in-shell, and so is the `/usr/bin/env` that would escape
                            # it, and so on without a fixed point). Verified with
                            # `rm`, `echo` and `printf` all shadowed: 32 bytes -> 0.
                            # `>|` rather than `>` so `set -C` cannot refuse it, and
                            # `[[ -f ]]` — grammar again — so an already-wiped jail is
                            # not spuriously recreated or warned about. Truncation is
                            # not unlinking, but the credential is CONTENT: zeroing it
                            # is the security-critical outcome, and step 2 is then
                            # merely hygiene.
                            # SC2188 (redirection with no command) is the POINT here,
                            # not an oversight — and shellcheck's suggested remedy,
                            # "use 'true' as a no-op", would reintroduce exactly the
                            # shadowable command word this construct exists to avoid.
                            # shellcheck disable=SC2188
                            # `! -L` IS LOAD-BEARING, not belt-and-braces. `-f` FOLLOWS
                            # symlinks, and this step is deliberately outside the
                            # single-shot latch (it must stay idempotent), so it can
                            # run again after the jail is gone. If the pathname were
                            # recreated with `auth.json` symlinked at an unrelated
                            # file, `>|` would follow it and truncate that file — the
                            # zeroing step turned into a destructive primitive aimed
                            # anywhere. Refusing symlinks outright keeps it pointed at
                            # a real file we created, and `-L` is grammar like `-f`,
                            # so neither check is interceptable.
                            if [[ -f "$_pi_jail/.pi/agent/auth.json" && ! -L "$_pi_jail/.pi/agent/auth.json" ]] \
                               && ! >| "$_pi_jail/.pi/agent/auth.json"; then
                                /bin/echo "WARNING: could not zero the projected pi credential at $_pi_jail/.pi/agent/auth.json — remove it by hand." >&2 || _pi_wipe_warn=1
                            fi
                            # STEP 2 — unlink the file and the tree. Best-effort by
                            # comparison: if this is subverted the credential is
                            # already empty. `-e` alone would MISS a dangling symlink
                            # (verified), so the check is `-e || -L` and the child
                            # cannot report success over a surviving path.
                            #
                            if ! /usr/bin/env -i /bin/bash --noprofile --norc -s "$_pi_jail" <<'CHILD' 2>/dev/null
d="$1"
case "$d" in /|'') exit 1 ;; /*) ;; *) exit 1 ;; esac
rm -f "$d/.pi/agent/auth.json"
if [ -e "$d/.pi/agent/auth.json" ] || [ -L "$d/.pi/agent/auth.json" ]; then exit 1; fi
rm -rf "$d"
if [ -e "$d" ] || [ -L "$d" ]; then exit 1; fi
exit 0
CHILD
                            then
                                # A shadowed `echo` here can only MISREPORT, never
                                # retain the credential — the destructive work is
                                # already done and verified in the sterile child.
                                /bin/echo "WARNING: pi jail $_pi_jail was not fully removed (the credential was zeroed first, so this is a leftover directory, not a live key)." >&2 || _pi_wipe_warn=1
                            else
                                # CONFIRMED GONE — drop the name. Everything above is
                                # gated on `-n "${_pi_jail:-}"`, so this is what makes
                                # a second call a no-op: no pathname, nothing to
                                # truncate, nothing to delete. Only on the child's
                                # SUCCESS, which it reports only after checking the
                                # path is absent — a failed wipe keeps the name and
                                # stays retryable, and the caller's own
                                # `-e || -L` check still sees it.
                                _pi_jail=""
                            fi
                        fi
                        _pi_wipe_rc=0
                    }
                    # CREATING THE JAIL IS ITS OWN STEP, separate from writing the
                    # credential, and that separation is what makes teardown
                    # decidable. Every attempt to infer ownership from a combined
                    # child's EXIT STATUS failed on the same case: a signal replaces
                    # whatever code the child would have returned, so 128+n is
                    # ambiguous no matter how the codes are arranged — reading it as
                    # "ours" can delete a path another process created, and reading it
                    # as "not ours" can strand a written credential.
                    #
                    # Split, the ambiguity survives only where it is harmless. This
                    # child's LAST statement is the `mkdir`, so success is the parent
                    # OBSERVING creation rather than deducing it. A signal before the
                    # mkdir yields failure and no wipe (correct — nothing was made); a
                    # signal after it leaks an EMPTY directory, because the credential
                    # is not written until the next step. Ownership is never in doubt
                    # at a moment when a secret is on disk.
                    #
                    # No -p: it must FAIL if the path already exists, which is exactly
                    # what proves this dispatch created it.
                    _pi_mkjail() {
                        /usr/bin/env -i "D=$_pi_jail" \
                            /bin/bash --noprofile --norc <<'CHILD'
umask 077
case "$D" in /*) ;; *) exit 1 ;; esac
mkdir "$D"
CHILD
                    }
                    # Runs only after _pi_mkjail succeeded, so the jail is known to be
                    # ours and ANY failure here authorises teardown — no exit-code
                    # taxonomy, nothing for a signal to make ambiguous.
                    _pi_project() {
                        # THE SIGNAL TRAP IS ARMED HERE, not before the branch chain,
                        # because it authorises `rm -rf` on a path whose only guard is
                        # "absolute and not /". Armed any earlier it covers the window
                        # before `_pi_mkjail` has observed creation, so a signal in
                        # that window deletes a path this dispatch never made. Armed
                        # here it covers exactly the window in which a credential can
                        # exist: from the first write attempt until the explicit
                        # `_pi_wipe` after dispatch disarms it. The dispatch subshell
                        # installs no trap of its own — this handler stays the sole
                        # owner throughout. (Traps are shell-global in bash, not
                        # function-scoped, so this outlives the call.)
                        # EXIT is deliberately NOT taken: the script-level EXIT trap
                        # owns $PROMPT_FILE, and stealing it would leak that instead.
                        trap '_pi_wipe; rm -f "$PROMPT_FILE" 2>/dev/null; exit 130' INT TERM HUP
                        /usr/bin/env -i \
                            "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
                            "SRC=$_pi_home/.pi/agent/auth.json" \
                            "PROV=$_pi_prov" \
                            "D=$_pi_jail" \
                            /bin/bash --noprofile --norc <<'CHILD'
umask 077
mkdir "$D/.pi" "$D/.pi/agent" || exit 1
py=""
for b in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3 /bin/python3; do
  [ -x "$b" ] && { py="$b"; break; }
done
[ -n "$py" ] || exit 1
# NO CLEANUP TRAP IN THE CHILD, deliberately. The PARENT owns this pathname from
# before the child starts until after it exits, and a second owner is worse than
# an imperfect one: a child trap and the parent's INT/TERM/HUP handler both fire
# on a process-group signal, the child removes $D, and the parent then re-derives
# a name it no longer owns and deletes whatever took its place. One owner, one
# deletion. The child's only job is to report failure; the parent decides.
"$py" -I -c 'import json, sys
src, dst, prov = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(src))
if prov not in d:
    raise SystemExit("provider not in auth store")
entry = d[prov]
# REFUSE refreshable credentials. pi rewrites auth.json in place when it
# refreshes an OAuth token — inside the jail, which is discarded. For a provider
# that ROTATES refresh tokens that silently invalidates the credential still
# sitting in the real store, and the operator has to re-authenticate for reasons
# they cannot see. Copying the jail copy back is not the fix: it would put a
# write to the real credential store on the far side of an untrusted-input run.
# Static API keys have no such lifecycle, so project those and fail closed on
# anything else.
# ALLOWLIST of known-static credential types (pi 0.84.1 stores API keys as
# type="api_key"). An allowlist, not a denylist of oauth-ish field names: an
# unrecognised future type fails closed rather than being projected on the
# assumption it has no refresh lifecycle.
if not isinstance(entry, dict) or entry.get("type") not in ("api_key", "api"):
    raise SystemExit("refreshable or unrecognised credential type")
json.dump({prov: entry}, open(dst, "w"))' "$SRC" "$D/.pi/agent/auth.json" "$PROV" 2>/dev/null || exit 1
CHILD
                    }
                    _pi_prov="${MODEL:-$_BD_PI_MODEL}"
                    _pi_prov="${_pi_prov%%/*}"
                    # THE PARENT NAMES THE JAIL, before anything is created. The
                    # child used to `mktemp` and print the path back, which raced by
                    # construction: it had to disarm its own cleanup trap before the
                    # final `printf`, and a signal or closed pipe in that window
                    # stranded a fully-written API key the parent could not even name
                    # to remove. Command substitution does not help — the parent sees
                    # stdout only at child exit. Computed here, ahead of the branch
                    # chain, so `_pi_wipe` can reach the path on EVERY failure path.
                    # `$$` and `$RANDOM` are shell BUILTINS, not command words, so
                    # they cannot be shadowed by an exported function the way
                    # `mktemp` can.
                    _pi_tmp="${TMPDIR:-/tmp}"
                    [[ "$_pi_tmp" == /* ]] || _pi_tmp="/tmp"
                    _pi_jail="${_pi_tmp%/}/busdriver-pi-$$-${RANDOM}${RANDOM}"
                    if [[ -z "$_pi_prov" || "$_pi_prov" == "${MODEL:-$_BD_PI_MODEL}" ]]; then
                        # No `provider/` prefix ⇒ we cannot tell which credential
                        # to project, and projecting ALL of them is the thing this
                        # block exists to prevent. Fail closed.
                        _pi_setup_fail "could not derive a provider from the pi model reference '${MODEL:-$_BD_PI_MODEL}' (expected provider/model) — refusing to dispatch rather than hand pi the full credential store."
                    # JAIL CREATION + PROJECTION, both inside ONE `env -i` child.
                    # Everything here used to run in the caller's shell, where
                    # `mktemp`, `mkdir`, `rm` and `python3` are all command words an
                    # exported function can shadow — and no amount of PATH pinning
                    # reaches a shell function. Exported functions ARE environment
                    # variables, so `env -i` deletes the function table outright;
                    # `/usr/bin/env` and `/bin/bash` are absolute (a function name
                    # cannot contain `/`), so the escape itself is unshadowable.
                    # This mirrors _bd_read_auditor_model in resolve-cli.sh.
                    #
                    # `mkdir` WITHOUT -p is deliberate: it fails if the directory
                    # already exists, which is what actually proves this dispatch
                    # created the tree. "Absolute and currently empty" never proved
                    # that — a shadowed mktemp could return someone else's empty
                    # directory, and files landing in it after the check would then
                    # be inside the recursive delete.
                    #
                    # The child returns ONLY an exit status; the path was fixed by
                    # the parent beforehand. So every failure — no python3, mkdir
                    # refused, provider absent, refreshable credential — lands on a
                    # branch that can still name and remove the jail.
                    # `-e` alone would MISS a dangling symlink pointing outside the
                    # jail, and a dangling symlink is precisely what an attacker
                    # would plant here.
                    elif [[ -e "$_pi_jail" || -L "$_pi_jail" ]]; then
                        echo "Error: refusing to reuse an existing path for pi's private HOME." >&2
                        exit_code=1
                    # NO WIPE ON THIS BRANCH. Creation failed, so either the path was
                    # never made or a signal killed the child around the `mkdir` — and
                    # in the latter case the only thing that can be left is an EMPTY
                    # directory, never a credential. Deleting on an unproven claim of
                    # ownership is the worse trade; leaking an empty temp directory is
                    # the acceptable one.
                    elif ! _pi_mkjail; then
                        echo "Error: could not create a private HOME for pi at $_pi_jail — refusing to dispatch with the full credential store exposed." >&2
                        exit_code=1
                    elif ! _pi_project; then
                        # Covers every failure the child can hit: no python3 on the
                        # trusted paths, mkdir refused, the provider absent
                        # from the auth store, or a refreshable/OAuth credential.
                        # All of them fail closed — dispatching anyway would let pi
                        # fall back to whatever it finds, which is the operator's
                        # full credential store.
                        #
                        # TEARDOWN RUNS BEFORE THE MESSAGE, not after. The child may
                        # have part-written auth.json, and `echo` is a command word:
                        # a failing write to stderr trips `set -e`, and a shadowed
                        # one can do worse — either way the credential would still be
                        # on disk when the script left. Nothing is allowed to come
                        # between a possible credential and its removal.
                        #
                        # THE WIPE IS UNCONDITIONAL, and it is only allowed to be
                        # because `_pi_mkjail` already succeeded above — the parent
                        # OBSERVED the jail being created rather than deducing it from
                        # an exit status. No code is consulted here, so there is
                        # nothing a signal can make ambiguous: 128+n means the same as
                        # any other failure, namely "we own this and a credential may
                        # be on disk". Every earlier attempt to encode ownership in the
                        # projection child's exit codes broke on exactly that case.
                        #
                        # Teardown runs BEFORE the message: `echo` is a command word,
                        # so a failing write to stderr trips `set -e` and a shadowed
                        # one can do worse. Nothing comes between a possibly written
                        # credential and its removal.
                        _pi_wipe
                        # `_pi_wipe` clears `_pi_jail` ONLY after its sterile child
                        # verifies the path is absent. A name that survives the call
                        # therefore means the projected credential may still be on
                        # disk — record that, so the status ladder can refuse to
                        # downgrade this failure to `skipped` (which the batch loop
                        # treats as "not a failure", per #594). Assignment only, no
                        # command word, on the credential path.
                        [[ -z "${_pi_jail:-}" ]] || _pi_jail_survived=1
                        # Routed through _pi_setup_fail (not a bare echo+exit_code=1)
                        # so this deterministic failure also lands in $outfile and
                        # sets _pi_setup_failed — otherwise the shared retry loop
                        # sees an empty outfile and pays the full 5s/10s/20s backoff
                        # retrying a projection that cannot succeed on any attempt.
                        _pi_setup_fail "could not project a static API credential for '${_pi_prov}' into a private HOME for pi — refusing to dispatch with the full credential store exposed. Either python3 is unavailable, or the provider is not authenticated (try: pi auth check --provider ${_pi_prov}), or it uses a refreshable/OAuth credential, which this lane will not project because pi's in-jail token refresh would be discarded and could invalidate your real one. Point .pi.model at an API-key provider."
                    else
                    # `env -i` wipes PI_* and any injected environment (exported
                    # bash functions included) while KEEPING the inherited CWD —
                    # which is the repo, and is the one thing this lane needs.
                    # Prompt via stdin, not argv: prompts here quote source and
                    # would otherwise hit ARG_MAX (verified pi reads fd 0).
                    # stderr is merged into $outfile ON PURPOSE: the configured
                    # model can be region-gated (the shipped default returns
                    # HTTP 403 RegionError without its provider workspace's
                    # opt-in), and that must surface as a readable provider
                    # error instead of an empty, silently-dead voice.
                    # HOME is the JAIL, not the operator's home. The parent's signal
                    # trap removes the projected credential if the timeout kills the
                    # child or the caller interrupts the batch, and the explicit
                    # `_pi_wipe` below covers a normal return.
                    #
                    # SUPERSEDED — the subshell installs no traps of its own; the
                    # parent is the sole owner (see the paragraph below). Kept only so
                    # the reasoning that ruled the alternative out is not relitigated:
                    # a subshell EXIT trap plus the parent's signal trap meant a
                    # process-group signal fired both, and the parent's delete landed
                    # after the subshell had already freed the pathname, hitting
                    # whatever had taken it.
                    #
                    # THE PARENT IS THE SOLE CLEANUP OWNER, and stays armed across
                    # this entire window — the subshell installs no trap of its own.
                    # Both alternatives are worse, and both were tried: with a trap in
                    # each shell, a PROCESS-GROUP signal reaches both and the parent's
                    # delete lands after the subshell has already freed the pathname,
                    # hitting whatever replaced it. Disarming the parent first instead
                    # opens a gap between that `trap` and the subshell's, and a signal
                    # arriving in it exits with NO owner and the credential on disk.
                    # One continuously-armed owner has neither hole.
                    ( _portable_timeout "$_budget" \
                        /usr/bin/env -i HOME="$_pi_jail" PATH="$_pi_path" \
                        "$_pi_bin" --model "${MODEL:-$_BD_PI_MODEL}" \
                          --print --no-session \
                          --no-approve --no-context-files --no-skills \
                          --no-extensions --no-prompt-templates --no-themes \
                          --tools read \
                          < "$PROMPT_FILE" ) > "$outfile" 2>&1 || exit_code=$?
                    _pi_wipe
                    # Disarmed the moment the jail is gone, so the handler cannot fire
                    # over a freed pathname. `_pi_wipe` is single-shot anyway — this
                    # is the belt to that braces, not the guarantee.
                    trap - INT TERM HUP
                    # TEARDOWN IS VERIFIED BY LOOKING, not by a status. Smuggling a
                    # cleanup failure out through a reserved exit code was worse than
                    # the problem: pi or `_portable_timeout` can legitimately return
                    # that same code, turning a clean run into a false credential
                    # warning. The jail's continued existence is direct evidence, and
                    # `[[ ]]` is grammar rather than a shadowable command. `-L` too,
                    # since a dangling symlink is invisible to `-e`.
                    if [[ -e "$_pi_jail" || -L "$_pi_jail" ]]; then
                        echo "Error: pi ran, but its projected credential jail is STILL ON DISK at $_pi_jail — see the warnings above and remove it by hand." >&2
                        [[ "$exit_code" -ne 0 ]] || exit_code=1
                    fi
                    fi
                    fi
                    # Jail window closed on every branch above — hand signals back.
                    trap - INT TERM HUP
                fi
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
            #   --sandbox readonly: see SAFETY MODEL block below.
            #
            # Flags deliberately NOT passed (--always-approve, --disallowed-tools,
            # --deny): documented in the SAFETY MODEL block below — empirically
            # they are no-ops in headless mode, so passing them would either
            # mislead or provide false-sense-of-security.
            #
            # NOTE: grok-build (the only available model) rejects --reasoning-effort
            # and --effort with a 400 from the responses API, so neither MODEL nor
            # effort tiers are forwarded here.
            if [[ -n "$MODEL" ]]; then
                echo "Error: --model is not supported by grok-build (single model; rejects --model flag). Remove --model or use --cli codex to pin a specific model." >&2
                exit 1
            fi
            # SAFETY MODEL (end-to-end, empirically verified 2026-05-26):
            #
            # Safety relies on BOTH the dispatcher code AND the user's grok
            # configuration — neither alone is sufficient.
            #
            # 1. DISPATCHER CONTROLS (committed in this script):
            #   * --sandbox readonly: blocks file writes inside the project
            #     root (emits `IO Error: Operation not permitted` for `write`
            #     tool calls). Does NOT by itself block shell exec, writes
            #     outside the project root, or network access.
            #   * --mode auto rejected at dispatcher level (see gate below)
            #     to restrict grok to read-shaped workloads only.
            #   * --always-approve / --disallowed-tools / --deny deliberately
            #     NOT passed — empirically they're no-ops in headless mode
            #     (grok's flag-level permission system is advisory, not
            #     enforcing). False-sense-of-security flags.
            #
            # 2. USER-CONFIG REQUIREMENT (not committed; per-machine setting):
            #   * grok must have "always approve" DISABLED in its user config
            #     (via `grok` interactive `/permissions` setting or
            #     ~/.grok/config). When disabled, grok defaults to denying
            #     tool use in non-interactive mode (no user to confirm =
            #     fail-safe). Verified 2026-05-26: with this config, writes
            #     to /tmp and shell exec BOTH BLOCKED while web search and
            #     file reads continue working.
            #   * If a user reinstates "always approve" in their grok config,
            #     the dispatcher silently degrades to the permissive headless
            #     behavior. The runtime warning below points at this
            #     assumption so degradation is visible.
            #
            # ENFORCEMENT GATE: even with the user-config requirement met, we
            # reject --mode auto for grok. A write-capable role could still
            # request reads that look harmless; defense-in-depth means
            # write-capable workloads route to codex/agy/droid where the
            # write-permission model is better understood.
            if [[ "$MODE" == "auto" ]]; then
                echo "Error: grok adapter does not support --mode auto (sandbox is partial; shell exec and writes outside project root are not blocked). Use --mode readonly or pick another CLI." >&2
                exit 1
            fi
            # Runtime visibility: print a per-dispatch warning that documents
            # the end-to-end safety dependency (dispatcher + user-config). The
            # dispatcher's primary in-codebase caller (council Researcher)
            # does not consume stderr, so the warning surfaces to the user
            # and not into the council report. Suppressible once the user
            # has confirmed their grok config disables "always approve":
            # export BUSDRIVER_GROK_QUIET_SANDBOX_WARN=1.
            if [[ "${BUSDRIVER_GROK_QUIET_SANDBOX_WARN:-0}" != "1" ]]; then
                echo "Warning: grok safety = --sandbox readonly (dispatcher) + 'always approve' DISABLED in grok user-config (verify via grok /permissions). If always-approve is enabled in your grok config, shell exec and writes outside project root are NOT blocked. Set BUSDRIVER_GROK_QUIET_SANDBOX_WARN=1 to suppress once verified." >&2
            fi
            _portable_timeout "$_budget" grok \
                --prompt-file /dev/stdin \
                --max-turns 150 \
                --sandbox readonly \
                < "$PROMPT_FILE" > "$outfile" 2>&1 || exit_code=$? ;;
    esac

    # Timeout → don't retry; the droid fallback below handles it.
    [[ "$exit_code" -eq 124 ]] && break
    # A clean exit with non-empty output is success — UNLESS it is a bare
    # transient notice the CLI wrote while still exiting 0 (a rate-limit/5xx
    # message in place of a review). Those fall through to the retry/droid path;
    # a real review payload — even one discussing rate limits / 5xx — is accepted.
    if [[ "$exit_code" -eq 0 && -s "$outfile" ]] && ! _is_bare_transient_notice_file "$outfile"; then
        break
    fi
    # Retry if the attempt produced NO output (CLI died before writing — empty is
    # never a valid response, whatever the exit code) OR the output looks
    # transient. Otherwise bail (non-transient hard failure that produced output
    # → the droid fallback owns the rescue).
    # The setup-failure flag is checked FIRST and wins outright. It is set only by
    # `_pi_setup_fail`, for failures that are deterministic by construction, so no
    # amount of retrying helps — and the text classifier below cannot be trusted to
    # agree, because those messages quote operator-supplied values (`--model
    # ECONNRESET` made a deterministic provider error read as transient).
    if [[ "${_pi_setup_failed:-0}" != "1" ]] \
       && { [[ ! -s "$outfile" ]] || _is_transient_cli_error < "$outfile"; }; then
        _attempt=$((_attempt + 1))
        continue
    fi
    break
    done
    # Exhausted retries while the output file is still empty OR still holds a bare
    # transient notice on a clean exit → mark as failure so should_escalate_to_droid()
    # fires AND (when droid is unavailable) the status below is reported as error
    # rather than a silent empty / rate-limited success.
    if [[ "$exit_code" -eq 0 ]] && { [[ ! -s "$outfile" ]] || _is_bare_transient_notice_file "$outfile"; }; then
        exit_code=1
    fi

    # ── Runtime droid fallback (per-voice, single-CLI dispatch only) ──
    # If this voice's CLI failed (timeout 124 or error) and droid is installed,
    # retry once via droid. Council voices fall back INDEPENDENTLY — distinct
    # role prompts → distinct perspectives, so no cross-voice cap (unlike
    # blueprint). SKIPPED for --cli all/both, which COMPARE CLIs on one prompt:
    # a failure there is signal, and two droids would duplicate the comparison.
    # SKIPPED in write-capable (auto) mode: the droid fallback runs `droid exec`
    # read-only, so it cannot complete a write task the primary (codex
    # --full-auto / agy --dangerously-skip-permissions) failed to finish —
    # reporting droid-fallback "success" there would mask an unfinished change.
    # The whole resilience layer (retry above + this fallback) is read-only only.
    # `type` guard: a missing resolve-cli.sh (fallback mode) skips escalation.
    # opencode is EXEMPT from droid fallback. It serves the Mechanism Witness
    # (council ultimate tier) / the auditor role, and a droid stand-in is a fourth
    # copy of a model droid already backstops elsewhere — it would appear under the
    # claim-vs-mechanism lens as independent corroboration while adding no
    # independent signal, the exact false-agreement the council contract forbids.
    # On failure the witness is simply absent (its arm emits an error JSON the
    # arbiter reads as an unavailable auxiliary).
    local escalated=0
    # pi is exempt for a reason opencode's exemption does not cover: the operator
    # PICKS pi's provider at `.pi.model`, and that key exists precisely to control
    # WHICH third party sees repo source. Escalating a failed pi to droid would
    # ship the same prompt to a DIFFERENT provider than the one chosen, silently.
    # It would also overwrite the pi error in $outfile, defeating the stderr
    # surfacing this lane relies on to make a region-gated 403 diagnosable
    # instead of an empty answer.
    # The agy READ lane is exempt for pi's reason, and it needs its own clause
    # because the desugar rewrote CLI to plain "agy" — so `$name` is "agy" here and
    # the two checks above do not cover it. The operator picks this lane's provider
    # at `.agy_read.model`; escalating a failure to droid would ship the same
    # prompt, and the repo content quoted in it, to a DIFFERENT third party than
    # the one chosen, silently. It would also overwrite the agy error in $outfile.
    # Plain `--cli agy` (the reviewer slot) is unaffected and still escalates.
    if [[ "$CLI" != "all" && "$CLI" != "both" ]] \
       && [[ "$name" != "opencode" ]] \
       && [[ "$name" != "pi" ]] \
       && [[ -z "$_AGY_READ_LANE" ]] \
       && [[ "$MODE" == "readonly" ]] \
       && type should_escalate_to_droid &>/dev/null \
       && should_escalate_to_droid "$name" "$exit_code" "$outfile"; then
        echo "⟳ ${name} failed (exit ${exit_code}) — falling back to droid (read-only)" >&2
        # Bare `droid exec` (read-only — Create/Edit blocked) via stdin PIPE, the
        # same posture as the failed read-only primaries: NO permission widening.
        # Pipe (not fd0-redirect) is required for bare droid to read its prompt
        # without bailing — matches execute_review's proven pattern.
        local _esc_exit=0
        printf '%s' "$PROMPT" | _portable_timeout "$TIMEOUT" droid exec > "${outfile}.droid" 2>&1 || _esc_exit=$?
        if [[ "$_esc_exit" -eq 0 && -s "${outfile}.droid" ]]; then
            {
                echo "[busdriver: ${name} failed at runtime (exit ${exit_code}); response below is from droid (read-only runtime fallback)]"
                echo ""
                cat "${outfile}.droid"
            } > "$outfile"
            rm -f "${outfile}.droid"
            exit_code=0
            escalated=1
        else
            # Failure mark FIRST, fold second: the guard normalizes an
            # empty-output "success" (exit 0) into the canonical failure status
            # (exit 1 — the same normalization the pre-loop guard applies before
            # escalation), so appending the rescue's output below can never be
            # misread as primary output that would mask that failure.
            [[ "$exit_code" -eq 0 ]] && exit_code=1
            # PRESERVE THE RESCUE'S FAILURE before the unlink (#597). The
            # primary already failed and this rescue failed too, so the rescue
            # is the LAST thing that went wrong — usually the more informative
            # of the two. log_event archives $outfile only (never
            # ${outfile}.droid, which is deleted right below), so fold the
            # rescue into $outfile — delimited, in order — and the archived run
            # carries BOTH failures. The marker names the rescue's exit code
            # (the primary's own code is already recorded by the status/meta
            # machinery, and is normalized to 1 for an empty-output primary) and
            # is written even when the rescue produced no output, so the archive
            # still records that a rescue was attempted and how it died.
            # Best-effort: a fold failure must not change the (already failing)
            # dispatch outcome.
            {
                echo ""
                echo "[busdriver: ${name} failed; droid rescue also failed (exit ${_esc_exit})]"
                echo ""
                [[ -s "${outfile}.droid" ]] && cat "${outfile}.droid"
            } >> "$outfile" 2>/dev/null || true
            rm -f "${outfile}.droid"
            echo "⟳ droid fallback for ${name} also failed (exit ${_esc_exit}) — voice drops" >&2
        fi
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
    [[ "$escalated" -eq 1 ]] && status="droid-fallback"
    # `skipped` — the voice never ran. Assigned LAST so it wins over the
    # error/timeout classification above: a deterministic precondition failure
    # (unprobed pi version, underivable provider, no projectable credential) is
    # not an attempt that failed, it is an attempt that was refused before it
    # began, and the two deserve different consequences. Keeping them merged as
    # `error` is what let ONE ineligible voice fail a whole `--cli all` batch for
    # every other voice (#594). An EXPLICIT `--cli pi` still fails, because there
    # the voice that cannot run IS the request.
    # Two arms set a flag today: the pi arm (`_pi_setup_fail`) and opencode's
    # no-model bail (`_oc_no_model`, added when the auditor's shipped default was
    # deleted — an absent `.auditor.model` must not fail a whole batch). The
    # status itself is shared; wire a further arm to it when one needs it.
    # opencode's OTHER setup bails are still deliberately NOT routed here: they
    # write their reason to stderr only, never to "$outfile", so a skipped
    # opencode would print "(no output)" in the batch banner with the reason
    # lost. The no-model bail is routed precisely because it does write there.
    # ...but NEVER when a teardown left a credential behind. The projection
    # failure path runs `_pi_wipe` and then records whether the jail name survived
    # it; if it did, a projected API key may still be on disk. That case must stay
    # `error`: before this status existed it failed the batch, and downgrading it
    # to `skipped` would let another voice's success carry the batch to exit 0
    # with a live key in the jail. Reported by Codex on PR #596. The batch loop's
    # whole point is that `skipped` is not a failure — which is exactly why a
    # leaked credential must never be classified as one.
    [[ "${_pi_setup_failed:-0}" == "1" && "${_pi_jail_survived:-0}" != "1" ]] && status="skipped"
    # No credential ever enters the picture on this path — the bail happens before
    # any sandbox staging — so it carries no leaked-key caveat of its own.
    [[ "${_oc_no_model:-0}" == "1" ]] && status="skipped"

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
    OUTFILE="${OUT_DIR}/dispatch-${CLI}-${STAMP}.txt"

    echo "Dispatching to ${CLI} (${MODE}, ${TIMEOUT}s timeout)..." >&2

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
    log_event "$CLI" "$STATUS" "$DURATION" "$OUTFILE"

    [[ -f "$OUTFILE" ]] && cat "$OUTFILE"

    echo "" >&2
    echo "${CLI} → ${STATUS} (${DURATION}s) | saved: ${OUTFILE}" >&2

    exit "${EXIT_CODE}"
fi
