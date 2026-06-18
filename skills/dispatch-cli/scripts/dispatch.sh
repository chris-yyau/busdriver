#!/bin/bash
# dispatch.sh — Dispatch tasks to Codex, Antigravity (agy), Droid, or Grok CLI as autonomous agents
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
# BUSDRIVER_PLUGIN_ROOT: set by opencode adapter; CLAUDE_PLUGIN_ROOT by Claude Code.
# Falls back to relative path from this script's location.
# BUSDRIVER_STATE_DIR: .opencode for opencode, .claude for Claude Code (default).
# Source shared CLI library for _portable_timeout and resolve functions
_PLUGIN_ROOT="${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}}"
# shellcheck disable=SC2034  # STATE_DIR used in path construction
STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
if [[ -f "$_PLUGIN_ROOT/scripts/lib/resolve-cli.sh" ]]; then
  source "$_PLUGIN_ROOT/scripts/lib/resolve-cli.sh"
fi

# Fallback if resolve-cli.sh not found
if ! type _portable_timeout &>/dev/null; then
  _portable_timeout() { timeout "$@"; }
fi

LOG_DIR="$HOME/.claude/homunculus"
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
dispatch.sh — Dispatch tasks to Codex, Antigravity (agy), Droid, or Grok CLI

FLAGS:
  --cli     codex|agy|droid|grok|both|all|auto  (default: auto)
  --mode    readonly|auto           (default: readonly)
  --timeout seconds                 (default: 300)
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
elif [[ "$CLI" != "codex" && "$CLI" != "agy" && "$CLI" != "droid" && "$CLI" != "grok" && "$CLI" != "both" && "$CLI" != "all" ]]; then
    echo "Error: Invalid --cli value '$CLI'. Must be codex|agy|droid|grok|both|all|auto." >&2; exit 1
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
    for c in codex agy droid grok; do
        [[ "$c" == "grok" && "$MODE" == "auto" ]] && continue
        _has_cli "$c" && ALL_CLIS+=("$c")
        [[ ${#ALL_CLIS[@]} -ge 4 ]] && break
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

    case "$name" in
        codex)
            if [[ "$MODE" == "auto" ]]; then
                _portable_timeout "$TIMEOUT" codex exec --full-auto ${MODEL:+-m "$MODEL"} - \
                    < "$PROMPT_FILE" > "$outfile" 2>&1 || exit_code=$?
            else
                _portable_timeout "$TIMEOUT" codex exec -s read-only ${MODEL:+-m "$MODEL"} - \
                    < "$PROMPT_FILE" > "$outfile" 2>&1 || exit_code=$?
            fi ;;
        agy)
            # `agy --print /dev/stdin` reads the prompt from fd 0, which bypasses the
            # ARG_MAX (~1 MB) limit that would clamp argv-passed prompts. --print-timeout
            # is aligned with our outer timeout so agy's internal 5m default doesn't
            # abort before _portable_timeout does.
            # NOTE: agy v1.0.0 has no `--model` flag (only `--add-dir`, `--sandbox`,
            # `--print`, `--print-timeout`, `--dangerously-skip-permissions`, etc.).
            # Forwarding $MODEL would crash with "flags provided but not defined: -model".
            # Model selection is implicit in the active conversation/config.
            if [[ -n "$MODEL" ]]; then
                echo "Error: --model is not supported by agy v1.0.0 (model selection is implicit in the active agy config). Remove --model or use --cli codex to pin a specific model." >&2
                exit 1
            fi
            if [[ "$MODE" == "auto" ]]; then
                _portable_timeout "$TIMEOUT" agy --dangerously-skip-permissions \
                    --print-timeout "${TIMEOUT}s" \
                    --print /dev/stdin < "$PROMPT_FILE" > "$outfile" 2>&1 || exit_code=$?
            else
                _portable_timeout "$TIMEOUT" agy --sandbox \
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
            _portable_timeout "$TIMEOUT" droid exec --auto "$_droid_level" \
                < "$PROMPT_FILE" > "$outfile" 2>&1 || exit_code=$? ;;
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
            _portable_timeout "$TIMEOUT" grok \
                --prompt-file /dev/stdin \
                --max-turns 150 \
                --sandbox readonly \
                < "$PROMPT_FILE" > "$outfile" 2>&1 || exit_code=$? ;;
    esac

    # ── Runtime droid fallback (per-voice, single-CLI dispatch only) ──
    # If this voice's CLI failed (timeout 124 or error) and droid is installed,
    # retry once via droid. Council voices fall back INDEPENDENTLY — distinct
    # role prompts → distinct perspectives, so no cross-voice cap (unlike
    # blueprint). SKIPPED for --cli all/both, which COMPARE CLIs on one prompt:
    # a failure there is signal, and two droids would duplicate the comparison.
    # `type` guard: a missing resolve-cli.sh (fallback mode) skips escalation.
    local escalated=0
    if [[ "$CLI" != "all" && "$CLI" != "both" ]] \
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
