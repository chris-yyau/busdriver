#!/bin/bash
# dispatch.sh — Dispatch tasks to Codex, Antigravity (agy), Droid, Grok, or opencode CLI as autonomous agents
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
# Ditto for the Auditor model resolver — without the library there is no config
# reader, so the opencode arm falls back to the same built-in default. Gate on
# whether the trusted library was actually sourced (_BD_RESOLVE_CLI_SOURCED),
# not on `type resolve_auditor_model` — an inherited/exported function of that
# name in the caller's environment would satisfy the `type` check and silently
# stand in for the real resolver, defeating the model-selection hardening this
# function exists to provide.
if [[ "$_BD_RESOLVE_CLI_SOURCED" != 1 ]]; then
  _BD_AUDITOR_MODEL=""
  resolve_auditor_model() { _BD_AUDITOR_MODEL="zenmux/moonshotai/kimi-k3"; }
  _BD_PI_MODEL=""
  resolve_pi_model() { _BD_PI_MODEL="opencode-go/deepseek-v4-flash"; }
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
TIMEOUT=300
MODEL=""
PROMPT=""

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
  --cli     codex|agy|droid|grok|opencode|pi|both|all|auto  (default: auto)
  --mode    readonly|auto           (default: readonly)
  --timeout seconds                 (default: 300)
  --model   model override          (optional)
  --prompt  "task description"      (or pipe via stdin)

NOTE: `pi` is the repo-READING lane — unlike opencode (confined to an empty
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
PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/dispatch-prompt-XXXXXX")
printf '%s' "$PROMPT" > "$PROMPT_FILE"
trap 'rm -f "$PROMPT_FILE"' EXIT

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
# place and not the other. Selection is therefore optimistic — see the KNOWN
# LIMITATION below for what that currently costs.
_pi_available() {
  /usr/bin/env -i "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    /bin/bash --noprofile --norc <<'CHILD' 2>/dev/null
u="$(/usr/bin/id -un)" || exit 1
case "$u" in ''|*[!A-Za-z0-9._-]*) exit 1 ;; esac
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
# KNOWN LIMITATION, stated rather than papered over: because a deterministic
# setup failure still reports `error`, a stale or version-mismatched pi on the
# trusted path DOES still fail an otherwise successful `--cli all` batch. The
# proper fix is a `skipped` status, which changes the shared batch loop's
# semantics for every CLI (retry interaction, audit log, exit code) and belongs
# in its own change rather than riding along here. What this function guarantees
# today is narrower and still worth having: there is exactly ONE version probe in
# the codebase, so selection and preflight cannot disagree about eligibility.
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
elif [[ "$CLI" != "codex" && "$CLI" != "agy" && "$CLI" != "droid" && "$CLI" != "grok" && "$CLI" != "opencode" && "$CLI" != "pi" && "$CLI" != "both" && "$CLI" != "all" ]]; then
    echo "Error: Invalid --cli value '$CLI'. Must be codex|agy|droid|grok|opencode|pi|both|all|auto." >&2; exit 1
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

log_event() {
    mkdir -p "$LOG_DIR"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    printf '{"ts":"%s","cli":"%s","mode":"%s","status":"%s","duration":%s,"prompt_len":%d,"output_file":"%s"}\n' \
        "$ts" "$1" "$MODE" "$2" "$3" "${#PROMPT}" "$4" >> "$LOG_FILE" 2>/dev/null || true
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
            # NOTE: agy 1.1.4 DOES advertise `--model` (and `--agent`) — the previous
            # claim that it has no such flag was true of v1.0.0 only. The rejection
            # below is therefore now a DELIBERATE non-support decision rather than a
            # version constraint: forwarding is untested here and out of scope for a
            # prompt-delivery fix. Follow-up: wire $MODEL through and drop this branch.
            if [[ -n "$MODEL" ]]; then
                echo "Error: --model is not forwarded to agy by this dispatcher (agy 1.1.4 accepts --model, but forwarding is unverified here). Remove --model to use agy's configured model, or use --cli codex to pin one." >&2
                exit 1
            fi
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
                        --print-timeout "${TIMEOUT}s" \
                        --print "$_agy_prompt" > "$outfile" 2>&1 || exit_code=$?
                else
                    _portable_timeout "$_budget" agy --sandbox \
                        --print-timeout "${TIMEOUT}s" \
                        --print "$_agy_prompt" > "$outfile" 2>&1 || exit_code=$?
                fi
            elif [[ "$MODE" == "auto" ]]; then
                _portable_timeout "$_budget" agy --dangerously-skip-permissions \
                    --print-timeout "${TIMEOUT}s" \
                    --print /dev/stdin < "$PROMPT_FILE" > "$outfile" 2>&1 || exit_code=$?
            else
                _portable_timeout "$_budget" agy --sandbox \
                    --print-timeout "${TIMEOUT}s" \
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
            local _oc_cfg _oc_cwd
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
            if [[ ! -f "$_oc_cfg" ]]; then
                echo "Error: opencode review config not found at '$_oc_cfg' — refusing to dispatch unconfined (a missing config silently restores write/bash)." >&2
                exit_code=1
            elif ! _oc_cfg="$(cd "$(dirname "$_oc_cfg")" 2>/dev/null && pwd -P)/$(basename "$_oc_cfg")" || [[ ! -f "$_oc_cfg" ]]; then
                # Canonicalize to absolute: the child runs with CWD=neutral dir, so
                # a relative OPENCODE_CONFIG would resolve there (missing) and
                # opencode would fail OPEN to the user default.
                echo "Error: could not resolve the opencode review config to an absolute path — refusing to dispatch." >&2
                exit_code=1
            elif ! _oc_cwd="$(mktemp -d 2>/dev/null)" || [[ -z "$_oc_cwd" || ! -d "$_oc_cwd" ]]; then
                echo "Error: could not create a neutral working directory for opencode — refusing to dispatch from the reviewed tree (its project config could redefine the reviewer)." >&2
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
                local _oc_path _oc_bin _oc_trust _oc_home _oc_user
                _oc_user="$(id -un 2>/dev/null)"
                _oc_home="$(eval echo "~${_oc_user}" 2>/dev/null)"
                # NO $HOME fallback — fail closed if the password-DB lookup fails
                # rather than trust the repo-injectable $HOME.
                if [[ -z "$_oc_home" || ! -d "$_oc_home" ]]; then
                    echo "Error: could not derive a trusted home from the password database — refusing to resolve opencode from a possibly-injected \$HOME." >&2
                    rmdir "$_oc_cwd" 2>/dev/null || true
                    exit_code=1
                fi
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
                    rmdir "$_oc_cwd" 2>/dev/null || true
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
                # the USER busdriver.json, else the built-in default (see
                # resolve_auditor_model in resolve-cli.sh). The EXIT/TERM
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
                ( trap 'rm -rf "$_oc_cwd" 2>/dev/null' EXIT TERM INT
                  cd "$_oc_cwd" 2>/dev/null || exit 1
                  _portable_timeout "$_budget" \
                    env -i HOME="$_oc_home" PATH="$_oc_path" \
                        OPENCODE_CONFIG="$_oc_cfg" XDG_CONFIG_HOME="$_oc_cwd" \
                    "$_oc_bin" run --dir "$_oc_cwd" --agent busdriver-review \
                    -m "${MODEL:-$_BD_AUDITOR_MODEL}" \
                    < "$PROMPT_FILE" ) > "$outfile" 2>&1 || exit_code=$?
                rm -rf "$_oc_cwd" 2>/dev/null || true
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
# password DB, and eval on anything else is arbitrary execution.
case "$u" in ''|*[!A-Za-z0-9._-]*) exit 1 ;; esac
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
    if [[ "$CLI" != "all" && "$CLI" != "both" ]] \
       && [[ "$name" != "opencode" ]] \
       && [[ "$name" != "pi" ]] \
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
            rm -f "${outfile}.droid"
            # If the primary only "passed" (exit 0) by producing EMPTY output and
            # the rescue also failed, mark failure now — don't report false success.
            [[ "$exit_code" -eq 0 ]] && exit_code=1
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
    # NOTE: a deterministic setup failure (unprobed pi version, no python3,
    # provider not authenticated) still reports `error` and so fails a `--cli all`
    # batch for every other voice. That is worth fixing, but NOT here — a
    # `skipped` status changes the shared batch loop's semantics for every CLI
    # (retry interaction, audit log, exit code), which is a change that needs its
    # own review rather than a rider on the pi lane. Tracked separately.

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

    log_event "codex" "$CS" "$CD" "$CODEX_OUT"
    log_event "agy"   "$AS" "$AD" "$AGY_OUT"

    echo "" >&2
    echo "Saved: codex → ${CODEX_OUT}  |  agy → ${AGY_OUT}" >&2

    # Exit with failure if either dispatch failed
    [[ "$CS" == "error" || "$CS" == "timeout" || "$AS" == "error" || "$AS" == "timeout" ]] && exit 1

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
    idx=0
    for c in "${ALL_CLIS[@]}"; do
        outfile="${ALL_OUTS[$idx]}"
        META=$(read_meta "${outfile}.meta"); rm -f "${outfile}.meta"
        STATUS=$(echo "$META" | cut -d'|' -f1); DURATION=$(echo "$META" | cut -d'|' -f2)
        echo "═══════════════════════════════════════════════════════"
        echo "  $(echo "$c" | tr '[:lower:]' '[:upper:]')  (${STATUS}, ${DURATION}s)"
        echo "═══════════════════════════════════════════════════════"
        [[ -f "$outfile" ]] && cat "$outfile" || echo "(no output)"
        echo ""
        log_event "$c" "$STATUS" "$DURATION" "$outfile"
        [[ "$STATUS" == "error" || "$STATUS" == "timeout" ]] && any_failed=true
        idx=$((idx + 1))
    done

    echo "" >&2
    echo "Saved outputs to ${OUT_DIR}/dispatch-*-${STAMP}.txt" >&2
    [[ "$any_failed" == "true" ]] && exit 1

else
    OUTFILE="${OUT_DIR}/dispatch-${CLI}-${STAMP}.txt"

    echo "Dispatching to ${CLI} (${MODE}, ${TIMEOUT}s timeout)..." >&2

    dispatch_one "$CLI" "$OUTFILE"
    META=$(read_meta "${OUTFILE}.meta"); rm -f "${OUTFILE}.meta"

    STATUS=$(echo "$META" | cut -d'|' -f1)
    DURATION=$(echo "$META" | cut -d'|' -f2)
    EXIT_CODE=$(echo "$META" | cut -d'|' -f3)

    [[ -f "$OUTFILE" ]] && cat "$OUTFILE"

    log_event "$CLI" "$STATUS" "$DURATION" "$OUTFILE"

    echo "" >&2
    echo "${CLI} → ${STATUS} (${DURATION}s) | saved: ${OUTFILE}" >&2

    exit "${EXIT_CODE}"
fi
