#!/bin/bash
# shellcheck disable=SC1091  # dynamic $SCRIPT_DIR/$_PLUGIN_ROOT source paths are not resolvable at lint time
# Three-tier design review: Agy + Codex (parallel) → Claude arbiter
#
# Architecture (post-A++ council fix, 2026-03-27):
#   - Agy + Codex run in parallel as independent reviewers
#   - Claude validates their findings against the codebase (arbiter)
#   - Claude's verdict is the sole convergence signal
#   - No Jaccard consensus, no auto-fix engine, no mechanical convergence
#
# Critic requirements implemented:
#   1. Run-scoped artifact isolation (stale output cleanup + run_id metadata)
#   2. Hard freshness contract (spec_hash + run_id + iteration in every output)
#   3. Atomic completion protocol (write to .pending, rename on success)
#   4. Claude verdict as first-class convergence (no consensus.json dependency)
#   5. Explicit progress model (severity breakdown, not binary FAIL/PASS)

# Intentional pipeline patterns throughout (printf | shasum | cut,
# shasum | cut, jq -r '.issues[] | ...', etc.) where the inner command's
# exit code is not load-bearing — SC2312 here would force noisy refactors
# with no real signal gain.
# shellcheck disable=SC2312

set -euo pipefail

STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/validation.sh"

# Source shared CLI resolution library
_PLUGIN_ROOT="${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}}"
# shellcheck source=../../../scripts/lib/resolve-cli.sh
source "$_PLUGIN_ROOT/scripts/lib/resolve-cli.sh"
# Optional ultra-oracle (ChatGPT Pro) auxiliary advisory (opt-in; visible best-effort).
# shellcheck source=../../../scripts/lib/ultra-oracle.sh
source "$_PLUGIN_ROOT/scripts/lib/ultra-oracle.sh" 2>/dev/null || true
ULTRA_ORACLE_ADVISORY_FILE=""        # set only when a fresh dispatch happens (non-claude-only)
ULTRA_ORACLE_DISPATCH_STATUS=""      # dispatched | skipped:* | error
source "$SCRIPT_DIR/lib/state_management.sh"

# Ensure output directory exists (namespaced per design doc)
REVIEW_DIR=$(get_review_dir)
mkdir -p "$REVIEW_DIR"

# Cross-platform millisecond timestamp
millis() {
  if command -v gdate &>/dev/null; then
    gdate +%s%3N
  elif command -v python3 &>/dev/null; then
    python3 -c 'import time; print(int(time.time()*1000))'
  else
    echo "$(date +%s)000"
  fi
}

# Blueprint runtime droid fallback: rescue a failed reviewer slot once via droid.
# Blueprint caps droid at ONE voice (all 3 reviewers share one prompt, so two
# droids would be near-duplicate signal). On a valid PASS/FAIL verdict, writes
# droid's extracted JSON with droid attribution + the round's freshness stamp.
# run_id is injected HERE: the freshness loop only fills a MISSING run_id and
# would otherwise treat a droid-supplied run_id as STALE and discard the rescue.
# Returns 0 on success (caller then stops — one droid voice).
_bp_droid_rescue() {
  local slot="$1" out="$2" raw droid_exit=0
  raw=$(get_review_file "${slot}-droid-raw.txt")
  log_warning "  ${slot} failed at runtime → retrying once via droid"
  execute_review "droid" "$FULL_PROMPT" > "$raw" 2>&1 || droid_exit=$?
  if [[ "$droid_exit" -ne 0 ]]; then
    log_warning "  droid rescue ${slot}: exit $droid_exit — keeping error entry"; return 1
  fi
  if ! python3 "$SCRIPT_DIR/lib/extract_review_json.py" "$raw" > "${out}.pending" 2>/dev/null; then
    rm -f "${out}.pending"; log_warning "  droid rescue ${slot}: invalid JSON — keeping error entry"; return 1
  fi
  if ! jq -e '(.status=="PASS" or .status=="FAIL") and (.issues|type=="array")' "${out}.pending" >/dev/null 2>&1; then
    rm -f "${out}.pending"; log_warning "  droid rescue ${slot}: no usable verdict — keeping error entry"; return 1
  fi
  if jq --arg from "$slot" --arg rid "$RUN_ID" --argjson iter "${CURRENT_ITERATION:-1}" --arg hash "$SPEC_HASH" \
       '.reviewer_id="droid" | .reviewer="droid" | (.issues = ((.issues // []) | map(.reviewer="droid")))
        | .metadata.runtime_escalated_from=$from | .metadata.run_id=$rid
        | .metadata.iteration=$iter | .metadata.spec_hash=$hash' \
       "${out}.pending" > "${out}.tagged" 2>/dev/null; then
    mv "${out}.tagged" "$out"; rm -f "${out}.pending"
    log_info "  ${slot}→droid rescue succeeded"; return 0
  fi
  rm -f "${out}.pending" "${out}.tagged"
  log_warning "  droid rescue ${slot}: retag failed — keeping error entry"; return 1
}

# Generate a short run ID for artifact isolation
generate_run_id() {
  local input
  input="$(date +%s)-$$"
  if command -v shasum &>/dev/null; then
    printf '%s' "$input" | shasum -a 256 | cut -c1-8
  elif command -v sha256sum &>/dev/null; then
    printf '%s' "$input" | sha256sum | cut -c1-8
  else
    printf '%s' "$input" | cut -c1-8
  fi
}

# Compute SHA-256 of design spec for freshness contract
# Fallback chain: shasum (macOS) → sha256sum (Linux) → python3
#
# $file is passed via env var — NOT interpolated into the python source
# string — so a path containing `'` or python fragments cannot escape the
# python -c body and execute arbitrary code.
compute_spec_hash() {
  local file="$1"
  if command -v shasum &>/dev/null; then
    shasum -a 256 "$file" | cut -d' ' -f1
  elif command -v sha256sum &>/dev/null; then
    sha256sum "$file" | cut -d' ' -f1
  elif command -v python3 &>/dev/null; then
    _CSH_FILE="$file" python3 -c 'import hashlib, os; print(hashlib.sha256(open(os.environ["_CSH_FILE"], "rb").read()).hexdigest())'
  else
    echo "no-hash-tool"
  fi
}

# Parse command line arguments
AUTO_MODE=false
CLAUDE_ONLY=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --auto)
      AUTO_MODE=true
      log_info "Auto-iteration mode enabled"
      shift
      ;;
    --skip-claude)
      log_error "--skip-claude flag has been removed (violates three-tier review)."
      log_error "Claude is the arbiter — skipping it removes the convergence signal."
      exit 1
      ;;
    --claude-only)
      CLAUDE_ONLY=true
      shift
      ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --auto          Auto-iteration mode (iterate until Claude verdict is PASS)"
      echo "  --claude-only   Skip Agy+Codex, only run Phase 3-5 (Claude validation + convergence)"
      echo "  --help          Show this help message"
      echo ""
      echo "Architecture:"
      echo "  1. Agy + Codex review in PARALLEL"
      echo "  2. Claude validates findings against codebase (arbiter)"
      echo "  3. Claude's verdict = convergence signal"
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      echo "Run with --help for usage information"
      exit 1
      ;;
  esac
done

log_info "=== Design Review (Three-Tier, Claude Arbiter) ==="
if [[ "$AUTO_MODE" == "true" ]]; then
  log_info "Mode: AUTO (iterate until Claude PASS)"
else
  log_info "Mode: INTERACTIVE (pause for Claude validation + human review)"
fi
log_info ""

# Check for state file
STATE_FILE=$(get_state_file)
if [[ ! -f "$STATE_FILE" ]]; then
  log_error "State file not found. Run: bash scripts/init-design-review.sh <design_file> first"
  exit 1
fi

# Get design file from state
DESIGN_FILE=$(get_design_file)
log_info "Design file: $DESIGN_FILE"

# ── Task 2 (ADR-D): snapshot this doc's marker tokens BEFORE the review runs ──
# On PASS we prune exactly this snapshot. A token re-armed DURING the review (a
# concurrent edit → new nonce) is NOT in the snapshot, so it survives the prune
# and the existence-keyed reader keeps blocking — the lost-rearm race is killed
# by construction (design test (i)). The key is the physical abspath, so this
# never cross-clears a divergent branch's token in another worktree.
_MARKER_RESOLVER="${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/../../..}}/hooks/gate-scripts/lib/resolve-repo-dir.sh"
_MARKER_SNAP=()
_MARKER_RESOLVE_OK=false
if [[ ! -f "$_MARKER_RESOLVER" ]]; then
  # Unset SCRIPT_DIR / plugin root collapses the fallback to "/…" — the resolver
  # won't exist, so prune would be a silent no-op. Warn rather than pretend.
  log_warning "Marker resolver not found at $_MARKER_RESOLVER; token prune will be skipped on PASS (drain manually if needed)."
elif [[ -f "$DESIGN_FILE" ]]; then
  _mk_glob="$(bash "$_MARKER_RESOLVER" marker-glob "$DESIGN_FILE" 2>/dev/null || true)"
  if [[ -n "$_mk_glob" ]]; then
    _MARKER_RESOLVE_OK=true
    shopt -s nullglob 2>/dev/null || true
    for _mk_f in "$_mk_glob"*; do _MARKER_SNAP+=("$_mk_f"); done
    shopt -u nullglob 2>/dev/null || true
  else
    log_warning "Could not resolve the marker dir for $DESIGN_FILE; token prune will be skipped on PASS (drain manually if needed)."
  fi
fi

# Compute spec hash for freshness contract (Critic #2)
SPEC_HASH=$(compute_spec_hash "$DESIGN_FILE")
log_info "Spec hash: ${SPEC_HASH:0:12}..."

if [[ "$CLAUDE_ONLY" == "true" ]]; then
  # --claude-only: recover run_id from existing Codex/Agy/Grok outputs
  CODEX_FILE=$(get_review_file "codex.json")
  AGY_FILE=$(get_review_file "agy.json")
  GROK_FILE=$(get_review_file "grok.json")
  RUN_ID=""
  if [[ -f "$CODEX_FILE" ]]; then
    RUN_ID=$(jq -r '.metadata.run_id // ""' "$CODEX_FILE" 2>/dev/null || echo "")
  fi
  if [[ -z "$RUN_ID" && -f "$AGY_FILE" ]]; then
    RUN_ID=$(jq -r '.metadata.run_id // ""' "$AGY_FILE" 2>/dev/null || echo "")
  fi
  if [[ -z "$RUN_ID" && -f "$GROK_FILE" ]]; then
    RUN_ID=$(jq -r '.metadata.run_id // ""' "$GROK_FILE" 2>/dev/null || echo "")
  fi
  if [[ -z "$RUN_ID" ]]; then
    log_error "--claude-only requires existing Agy/Codex/Grok outputs with run_id."
    log_error "Run without --claude-only first to generate them."
    exit 1
  fi
  log_info "Mode: CLAUDE-ONLY (Phase 3-5 only)"
  log_info "Recovered run ID: $RUN_ID"
  AGY_AVAILABLE=false
  CODEX_AVAILABLE=false
  GROK_AVAILABLE=false
else
  # Normal mode: generate fresh run ID
  RUN_ID=$(generate_run_id)
  log_info "Run ID: $RUN_ID"

  # Resolve CLIs from config
  log_info "Resolving reviewer CLIs..."
  REVIEWER_1_CLI=$(resolve_role_cli "blueprint-review.reviewer_1")
  REVIEWER_2_CLI=$(resolve_role_cli "blueprint-review.reviewer_2")
  REVIEWER_3_CLI=$(resolve_role_cli "blueprint-review.reviewer_3")
  log_info "  Reviewer 1: $REVIEWER_1_CLI"
  log_info "  Reviewer 2: $REVIEWER_2_CLI"
  log_info "  Reviewer 3: $REVIEWER_3_CLI"

  # Duplicate detection (council-validated decision 4c). For 3 reviewers the
  # simple rule is: if reviewer_2 collides with reviewer_1, run single-reviewer
  # mode (the existing pattern); if reviewer_3 collides with either, we just
  # skip reviewer_3 (one less voice, arbitration proceeds). This avoids
  # combinatorial 3-way duplicate-output copying for an edge case.
  DUPLICATE_MODE=false
  if [[ "$REVIEWER_1_CLI" == "$REVIEWER_2_CLI" && "$REVIEWER_1_CLI" != "none" && "$REVIEWER_1_CLI" != "builtin" && ! "$REVIEWER_1_CLI" =~ ^(missing|unsupported): ]]; then
    DUPLICATE_MODE=true
    log_warning "  Degraded: reviewer_1 and reviewer_2 resolved to $REVIEWER_1_CLI (single-reviewer mode for that pair)"
  fi
  REVIEWER_3_DUPLICATE=false
  if [[ "$REVIEWER_3_CLI" != "none" && "$REVIEWER_3_CLI" != "builtin" && ! "$REVIEWER_3_CLI" =~ ^(missing|unsupported): ]]; then
    # Note: collision check compares RESOLVED PRIMARIES, not the effective
    # running set. Edge case: if reviewer_1==reviewer_2==reviewer_3==droid,
    # DUPLICATE_MODE skips reviewer_2 and REVIEWER_3_DUPLICATE skips
    # reviewer_3, leaving only reviewer_1's single droid run. This is the
    # conservative behavior (avoid running near-identical CLI+prompt twice
    # under different role labels) — a fresh droid run would likely produce
    # near-identical JSON output. If non-deterministic LLM voice multiplication
    # ever becomes desired here, lift this restriction and let DUPLICATE_MODE-
    # skipped slots be backfilled by reviewer_3.
    if [[ "$REVIEWER_3_CLI" == "$REVIEWER_1_CLI" || "$REVIEWER_3_CLI" == "$REVIEWER_2_CLI" ]]; then
      REVIEWER_3_DUPLICATE=true
      log_warning "  Degraded: reviewer_3 ($REVIEWER_3_CLI) duplicates a higher slot — voice skipped (see code comment for the DUPLICATE_MODE+reviewer_3 edge case)"
    fi
  fi

  # Set availability flags for backward compat with rest of script
  AGY_AVAILABLE=false
  CODEX_AVAILABLE=false
  GROK_AVAILABLE=false
  [[ "$REVIEWER_1_CLI" != "none" && "$REVIEWER_1_CLI" != "builtin" && ! "$REVIEWER_1_CLI" =~ ^(missing|unsupported): ]] && AGY_AVAILABLE=true
  [[ "$REVIEWER_2_CLI" != "none" && "$REVIEWER_2_CLI" != "builtin" && ! "$REVIEWER_2_CLI" =~ ^(missing|unsupported): && "$DUPLICATE_MODE" == "false" ]] && CODEX_AVAILABLE=true
  [[ "$REVIEWER_3_CLI" != "none" && "$REVIEWER_3_CLI" != "builtin" && ! "$REVIEWER_3_CLI" =~ ^(missing|unsupported): && "$REVIEWER_3_DUPLICATE" == "false" ]] && GROK_AVAILABLE=true

  # Duplicate mode: after single reviewer runs, its output will be copied to both paths (see post-wait block below)
fi

# ── Coverage provenance helpers (flag: BLUEPRINT_COVERAGE_PROVENANCE, default on) ──
# See docs/plans/DESIGN-blueprint-review-coverage-provenance.md. Records WHICH
# reviewer slots actually ran (vs fell back to droid / collapsed to a duplicate /
# errored) so a degraded run is never silently counted as "3 reviewers ran".
_coverage_enabled() {
  case "${BLUEPRINT_COVERAGE_PROVENANCE:-1}" in
    0|false|no|off) return 1 ;;
    *) return 0 ;;
  esac
}
_coverage_role_for_slot() { case "$1" in 1) echo "blueprint-review.reviewer_1" ;; 2) echo "blueprint-review.reviewer_2" ;; 3) echo "blueprint-review.reviewer_3" ;; esac; }
_coverage_file_for_slot() { case "$1" in 1) echo "$AGY_OUTPUT_FILE" ;; 2) echo "$CODEX_OUTPUT_FILE" ;; 3) echo "$GROK_OUTPUT_FILE" ;; esac; }

# persist_dispatch_provenance: NON-claude-only. Capture requested/actual/resolve-
# reason per slot (incl. DUPLICATE override) so --claude-only derivation can read
# them from state without the runtime shell vars. fulfilled finalized in derive_coverage.
persist_dispatch_provenance() {
  _coverage_enabled || return 0
  local n role req act rreason
  for n in 1 2 3; do
    role=$(_coverage_role_for_slot "$n")
    IFS=$'\t' read -r req act rreason < <(describe_role_resolution "$role")
    [[ "$n" == "2" && "${DUPLICATE_MODE:-false}" == "true" ]] && rreason="duplicate"
    [[ "$n" == "3" && "${REVIEWER_3_DUPLICATE:-false}" == "true" ]] && rreason="duplicate"
    update_coverage_slot "$n" "$req" "$act" "" "$rreason"
  done
}

# derive_coverage: BOTH modes. Finalize fulfilled+reason per slot from the reviewer
# JSON (status / run_id / runtime_escalated_from) + persisted resolve-reason, using
# the precedence order. Then recompute coverage_status + append per-iteration history.
derive_coverage() {
  _coverage_enabled || return 0
  _ensure_coverage_fields
  local n file req act rreason jstatus rid esc haserr final fulfilled
  for n in 1 2 3; do
    file=$(_coverage_file_for_slot "$n")
    req=$(get_state_field "reviewer_${n}_requested")
    act=$(get_state_field "reviewer_${n}_actual")
    rreason=$(get_state_field "reviewer_${n}_reason")
    # Persisted resolve-time reason wins first: a slot intentionally skipped or
    # degraded at dispatch (duplicate / explicit-none / missing-cli / unsupported-cli
    # / builtin / resolve-droid-fallback) keeps that reason regardless of any
    # synthesized ERROR-stub artifact written for it in --claude-only mode.
    if [[ -n "$rreason" && "$rreason" != "ok" ]]; then
      final="$rreason"
    elif [[ -z "$file" || ! -s "$file" ]]; then
      final="missing-output"
    elif ! jq -e . "$file" >/dev/null 2>&1; then
      final="invalid-json"
    else
      jstatus=$(jq -r '.status // "ERROR"' "$file" 2>/dev/null)
      rid=$(jq -r '.metadata.run_id // ""' "$file" 2>/dev/null)
      esc=$(jq -r '.metadata.runtime_escalated_from // ""' "$file" 2>/dev/null)
      haserr=$(jq -r 'has("error")' "$file" 2>/dev/null)
      if [[ "$jstatus" == "ERROR" || "$haserr" == "true" ]]; then
        final="runtime-failed"
      elif [[ -n "${RUN_ID:-}" && "$rid" != "$RUN_ID" ]]; then
        # A PASS/FAIL artifact whose run_id is missing or doesn't match the
        # current run is not fresh coverage (freshness contract) — never fulfilled.
        final="stale"
      elif [[ -n "$esc" && "$esc" != "null" ]]; then
        final="runtime-droid-rescue"
      elif [[ "$jstatus" == "PASS" || "$jstatus" == "FAIL" ]]; then
        final="ok"
      else
        final="runtime-failed"
      fi
    fi
    fulfilled="false"; [[ "$final" == "ok" ]] && fulfilled="true"
    update_coverage_slot "$n" "$req" "$act" "$fulfilled" "$final"
  done
  recompute_coverage_status
  append_coverage_history "$(get_state_field fulfilled_lens_count)"
}

# record_coverage_finalize: at terminal sites. Once-guarded. Emits the COVERAGE
# summary line + appends ONE cross-review trend entry. The durable doc-marker is
# written separately at the PASS-marker site (co-located with the verdict marker).
record_coverage_finalize() {
  _coverage_enabled || return 0
  [[ "${COVERAGE_FINALIZED:-0}" == "1" ]] && return 0
  COVERAGE_FINALIZED=1
  local cstatus ccount detail n r slug
  cstatus=$(get_state_field "coverage_status")
  ccount=$(get_state_field "fulfilled_lens_count")
  [[ -z "$cstatus" ]] && return 0
  detail=""
  for n in 1 2 3; do
    r=$(get_state_field "reviewer_${n}_reason")
    [[ -n "$r" && "$r" != "ok" ]] && detail="${detail:+$detail }reviewer_${n}=${r}"
  done
  if [[ "$cstatus" == "DEGRADED" ]]; then
    log_warning "  COVERAGE: DEGRADED — ${ccount}/3 lenses (${detail})"
  else
    log_info "  COVERAGE: FULL — ${ccount}/3 lenses"
  fi
  append_to_state "COVERAGE: ${cstatus} ${ccount}/3 ${detail}"
  slug=$(get_review_slug "$DESIGN_FILE")
  append_coverage_trend "$slug" "$ccount"
}

# Main iteration loop
while true; do
  CURRENT_ITERATION=$(get_current_iteration)
  MAX_ITERATIONS=$(get_max_iterations)

  log_info ""
  log_info "=== Iteration $CURRENT_ITERATION of $MAX_ITERATIONS ==="
  log_info ""

  # Check if max iterations reached
  if is_max_iterations_reached; then
    log_warning "Maximum iterations ($MAX_ITERATIONS) reached"
    log_info "Design review did not converge. Human intervention required."
    log_info "Options: fix issues and re-run, or create $STATE_DIR/skip-design-review.local in terminal."
    record_coverage_finalize
    mark_review_complete "max_iterations_exceeded"
    exit 1
  fi

  if [[ "$CLAUDE_ONLY" == "true" ]]; then
    # --claude-only: skip cleanup and Agy+Codex+Grok, jump straight to Phase 3
    log_info "Claude-only mode: skipping Phase 1-2 (using existing Agy+Codex+Grok outputs)"

    AGY_OUTPUT_FILE=$(get_review_file "agy.json")
    CODEX_OUTPUT_FILE=$(get_review_file "codex.json")
    GROK_OUTPUT_FILE=$(get_review_file "grok.json")
    # Advisory Auditor: bind the path in --claude-only resume too (it is set in
    # the normal-review branch only, but read unconditionally when the arbiter
    # prompt is assembled — under `set -u` an unbound read aborts the resume).
    # A prior iteration's auditor.json is reused if present; otherwise the read
    # site falls back to an "unavailable" stub.
    AUDITOR_OUTPUT_FILE=$(get_review_file "auditor.json")
    # Synthesize "no signal" error artifacts for any missing reviewer files so
    # downstream prompt-build cats always have a valid JSON target. Without
    # this, a missing agy.json or codex.json causes `cat "$AGY_OUTPUT_FILE"`
    # to feed an empty section to Claude, silently dropping that reviewer's
    # voice from arbitration. All three slots get the same treatment.
    [[ -f "$AGY_OUTPUT_FILE" ]] || \
      create_error_json "agy" "CLI not available (claude-only mode; no prior agy output)" > "$AGY_OUTPUT_FILE"
    [[ -f "$CODEX_OUTPUT_FILE" ]] || \
      create_error_json "codex" "CLI not available (claude-only mode; no prior codex output)" > "$CODEX_OUTPUT_FILE"
    [[ -f "$GROK_OUTPUT_FILE" ]] || \
      create_error_json "grok" "CLI not available (claude-only mode; no prior grok output)" > "$GROK_OUTPUT_FILE"
    AGY_STATUS=$(jq -r '.status' "$AGY_OUTPUT_FILE" 2>/dev/null || echo "ERROR")
    CODEX_STATUS=$(jq -r '.status' "$CODEX_OUTPUT_FILE" 2>/dev/null || echo "ERROR")
    GROK_STATUS=$(jq -r '.status' "$GROK_OUTPUT_FILE" 2>/dev/null || echo "ERROR")
    DESIGN_CONTENT=$(cat "$DESIGN_FILE")
    REVIEW_START=$(millis)
  else

  # ── Critic #1: Clean stale outputs from previous iteration ────────
  # Decision 7 (ADR 0003): claude.json is NOT preserved across full iterations.
  # The reviewer artifacts are deleted and re-rolled below, so any existing
  # verdict was rendered against reviews that are about to disappear —
  # the pre-v3.3 spec_hash-only preservation let a stale verdict converge a
  # re-run on reviews it never saw. The legitimate pre-written-verdict flow is
  # --claude-only, which skips this cleanup and recovers run_id from the
  # reviewer artifacts on disk — meaningful because the arbiter is dispatched
  # against those same artifacts (the script cannot itself enforce that
  # correspondence end-to-end; see ADR 0003 "Orchestration responsibility").
  log_info "Cleaning stale artifacts..."
  rm -f "$(get_review_file "agy.json")" \
        "$(get_review_file "agy-raw.txt")" \
        "$(get_review_file "agy.json.pending")" \
        "$(get_review_file "codex.json")" \
        "$(get_review_file "codex-raw.txt")" \
        "$(get_review_file "codex.json.pending")" \
        "$(get_review_file "grok.json")" \
        "$(get_review_file "grok-raw.txt")" \
        "$(get_review_file "grok.json.pending")" \
        "$(get_review_file "auditor.json")" \
        "$(get_review_file "auditor-raw.txt")" \
        "$(get_review_file "claude.json")" \
        "$(get_review_file "claude.json.pending")" \
        "$(get_review_file "claude-validation-prompt.txt")" \
        "$(get_review_file "consensus.json")" \
        "$(get_review_file "decisions.json")" \
        "$(get_review_file "autofix-log.json")" \
        "$(get_review_file "autofix-summary.json")" \
        "$(get_review_file "report.txt")" \
        2>/dev/null || true
  log_info "  Stale artifacts cleared"

  # ── Optional ultra-oracle auxiliary advisory: dispatch in background (parallel) ──
  # Opt-in; visible best-effort. Capture the TYPED status (a skip writes no .rc).
  # Never in --claude-only mode (no design re-transmitted when the operator chose Claude-only).
  if [ "$CLAUDE_ONLY" != "true" ] && command -v ultra_oracle_surface_enabled >/dev/null 2>&1 && ultra_oracle_surface_enabled blueprintReview; then
    ULTRA_ORACLE_ADVISORY_FILE="$STATE_DIR/ultra-oracle/${RUN_ID}-plan-review.md"
    rm -f "$ULTRA_ORACLE_ADVISORY_FILE" "$ULTRA_ORACLE_ADVISORY_FILE.rc" "$ULTRA_ORACLE_ADVISORY_FILE.hint" 2>/dev/null || true
    ULTRA_ORACLE_DISPATCH_STATUS="$(ultra_oracle_consult --mode background --slug "ultra oracle plan review" \
      --out "$ULTRA_ORACLE_ADVISORY_FILE" --context "$DESIGN_FILE" \
      --prompt "You are an auxiliary design reviewer. Review this implementation plan for architectural risks, missing decomposition, and underspecified steps. Be concise." 2>/dev/null || true)"
  fi

  # Read design file content and build prompt
  DESIGN_CONTENT=$(cat "$DESIGN_FILE")
  PROMPT=$(cat "$SCRIPT_DIR/../prompts/comprehensive_review_prompt.txt")
  FULL_PROMPT="$PROMPT

Document to review:
---
$DESIGN_CONTENT
---"

  # Pre-execution safety warning whenever grok will be invoked, regardless
  # of which reviewer slot it landed in. Gate checks ALL three reviewer
  # CLIs because a route override or BUSDRIVER_REVIEW_CLI could put grok
  # into reviewer_1 or reviewer_2 (not just reviewer_3). Printed BEFORE
  # the subshell stderr redirect so the operator sees it in real time —
  # the warning inside execute_review's grok case is captured into the
  # per-reviewer raw file and only visible if the file is inspected.
  # Suppressible via BUSDRIVER_GROK_QUIET_SANDBOX_WARN=1.
  if [[ "${BUSDRIVER_GROK_QUIET_SANDBOX_WARN:-0}" != "1" ]] && \
     [[ "$REVIEWER_1_CLI" == "grok" || "$REVIEWER_2_CLI" == "grok" || "$REVIEWER_3_CLI" == "grok" ]]; then
    log_warning "  grok dispatch in blueprint-review: --sandbox readonly blocks project writes only; shell exec / /tmp writes NOT blocked. Safety also requires 'always approve' DISABLED in grok user-config. Design-document content flows through this path — review the dispatch.sh grok-case comment for the full threat model. Set BUSDRIVER_GROK_QUIET_SANDBOX_WARN=1 to suppress."
  fi

  # ── Phase 1: Launch Agy + Codex + Grok in PARALLEL ────────────
  log_info "Phase 1: Launching Agy + Codex + Grok reviews in parallel..."

  AGY_OUTPUT_FILE=$(get_review_file "agy.json")
  CODEX_OUTPUT_FILE=$(get_review_file "codex.json")
  GROK_OUTPUT_FILE=$(get_review_file "grok.json")

  REVIEW_START=$(millis)

  # Blueprint caps droid at one voice, so disable codex's internal _execute_codex
  # droid fallback during Phase 1 — the single post-run rescue below owns the one
  # droid slot (codex could otherwise become a hidden second droid). Codex's own
  # transient retries still run. Covers codex in ANY reviewer slot.
  export LITMUS_CODEX_DROID_FALLBACK_DISABLED=1

  # Blueprint review is a gate of record — raise the per-reviewer retry budget to
  # 5 (the most important paths get more patience before the single droid rescue
  # fires). Covers codex (LITMUS_CODEX_RETRIES) and agy/grok (BUSDRIVER_CLI_RETRIES
  # via execute_review's retry wrapper). `:-5` respects an explicit operator
  # override exported in the parent shell.
  export LITMUS_CODEX_RETRIES="${LITMUS_CODEX_RETRIES:-5}"
  export BUSDRIVER_CLI_RETRIES="${BUSDRIVER_CLI_RETRIES:-5}"

  # agy reviews headless (--print) and cannot prompt for tool permission, so
  # without --dangerously-skip-permissions every read_file/command request auto-
  # denies and the agy slot dies, silently dropping coverage below FULL and
  # withholding the PASS marker (#424). execute_review gates that flag on this
  # opt-in so the SHARED litmus path (arbitrary/untrusted diffs) stays sandbox-
  # only; blueprint-review opts in because the reviewed artifact is an operator-
  # authored design doc and agy stays --sandbox-contained (writes/network blocked).
  export BUSDRIVER_AGY_REVIEW_SKIP_PERMS="${BUSDRIVER_AGY_REVIEW_SKIP_PERMS:-1}"

  # Run Agy (reviewer 1) in background
  (
    if [[ "$AGY_AVAILABLE" == "true" ]]; then
      AGY_RAW_FILE=$(get_review_file "agy-raw.txt")
      AGY_START=$(millis)

      # Capture exit code per execute_review contract (exit 3 = BUILTIN_FALLBACK)
      REVIEWER_EXIT=0
      execute_review "$REVIEWER_1_CLI" "$FULL_PROMPT" > "$AGY_RAW_FILE" 2>&1 || REVIEWER_EXIT=$?

      if [[ "$REVIEWER_EXIT" -eq 0 ]]; then
        AGY_END=$(millis)
        AGY_DURATION=$((AGY_END - AGY_START))

        if python3 "$SCRIPT_DIR/lib/extract_review_json.py" "$AGY_RAW_FILE" > "${AGY_OUTPUT_FILE}.pending" 2>/dev/null; then
          # Inject freshness metadata (Critic #2)
          # Validates JSON has expected structure before injecting.
          # All values are passed via env vars (single-quoted python -c source
          # string) so paths or hash strings containing `'` cannot escape into
          # the python body.
          # || true: don't let injection failure kill subshell under set -e
          _MIM_PENDING="${AGY_OUTPUT_FILE}.pending" \
          _MIM_RUN_ID="$RUN_ID" \
          _MIM_ITERATION="$CURRENT_ITERATION" \
          _MIM_SPEC_HASH="$SPEC_HASH" \
          _MIM_DURATION="$AGY_DURATION" \
          python3 -c '
import json, os, sys
pending = os.environ["_MIM_PENDING"]
with open(pending) as f:
    data = json.load(f)
if not isinstance(data, dict) or "status" not in data:
    print("Skipping metadata injection: unexpected JSON structure", file=sys.stderr)
    sys.exit(0)
data.setdefault("metadata", {})
data["metadata"]["run_id"] = os.environ["_MIM_RUN_ID"]
data["metadata"]["iteration"] = int(os.environ["_MIM_ITERATION"])
data["metadata"]["spec_hash"] = os.environ["_MIM_SPEC_HASH"]
data["metadata"]["review_duration_ms"] = int(os.environ["_MIM_DURATION"])
with open(pending, "w") as f:
    json.dump(data, f, indent=2)
' 2>/dev/null || true
          mv "${AGY_OUTPUT_FILE}.pending" "$AGY_OUTPUT_FILE"
        else
          create_error_json "agy" "Output was not valid JSON" > "$AGY_OUTPUT_FILE"
        fi
      elif [[ "$REVIEWER_EXIT" -eq 3 ]]; then
        # BUILTIN_FALLBACK: CLI retry exhaustion — degraded mode, not hard error.
        # Arbiter proceeds with fewer external voices.
        create_error_json "agy" "CLI unavailable (builtin fallback — retry exhaustion)" > "$AGY_OUTPUT_FILE"
      else
        create_error_json "agy" "CLI execution failed (exit $REVIEWER_EXIT)" > "$AGY_OUTPUT_FILE"
      fi
    else
      create_error_json "agy" "CLI not available" > "$AGY_OUTPUT_FILE"
    fi
  ) &
  AGY_PID=$!

  # Run Codex in background
  (
    if [[ "$CODEX_AVAILABLE" == "true" ]]; then
      CODEX_RAW_FILE=$(get_review_file "codex-raw.txt")
      CODEX_START=$(millis)

      # Capture exit code per execute_review contract (exit 3 = BUILTIN_FALLBACK)
      REVIEWER_EXIT=0
      execute_review "$REVIEWER_2_CLI" "$FULL_PROMPT" > "$CODEX_RAW_FILE" 2>&1 || REVIEWER_EXIT=$?

      if [[ "$REVIEWER_EXIT" -eq 0 ]]; then
        CODEX_END=$(millis)
        CODEX_DURATION=$((CODEX_END - CODEX_START))

        if python3 "$SCRIPT_DIR/lib/extract_review_json.py" "$CODEX_RAW_FILE" > "${CODEX_OUTPUT_FILE}.pending" 2>/dev/null; then
          # Inject freshness metadata (Critic #2)
          # Validates JSON has expected structure before injecting.
          # All values are passed via env vars (single-quoted python -c source
          # string) so paths or hash strings containing `'` cannot escape into
          # the python body.
          # || true: don't let injection failure kill subshell under set -e
          _MIM_PENDING="${CODEX_OUTPUT_FILE}.pending" \
          _MIM_RUN_ID="$RUN_ID" \
          _MIM_ITERATION="$CURRENT_ITERATION" \
          _MIM_SPEC_HASH="$SPEC_HASH" \
          _MIM_DURATION="$CODEX_DURATION" \
          python3 -c '
import json, os, sys
pending = os.environ["_MIM_PENDING"]
with open(pending) as f:
    data = json.load(f)
if not isinstance(data, dict) or "status" not in data:
    print("Skipping metadata injection: unexpected JSON structure", file=sys.stderr)
    sys.exit(0)
data.setdefault("metadata", {})
data["metadata"]["run_id"] = os.environ["_MIM_RUN_ID"]
data["metadata"]["iteration"] = int(os.environ["_MIM_ITERATION"])
data["metadata"]["spec_hash"] = os.environ["_MIM_SPEC_HASH"]
data["metadata"]["review_duration_ms"] = int(os.environ["_MIM_DURATION"])
with open(pending, "w") as f:
    json.dump(data, f, indent=2)
' 2>/dev/null || true
          mv "${CODEX_OUTPUT_FILE}.pending" "$CODEX_OUTPUT_FILE"
        else
          create_error_json "codex" "Output was not valid JSON" > "$CODEX_OUTPUT_FILE"
        fi
      elif [[ "$REVIEWER_EXIT" -eq 3 ]]; then
        # BUILTIN_FALLBACK: CLI retry exhaustion — degraded mode, not hard error.
        # Arbiter proceeds with fewer external voices.
        create_error_json "codex" "CLI unavailable (builtin fallback — retry exhaustion)" > "$CODEX_OUTPUT_FILE"
      else
        create_error_json "codex" "CLI execution failed (exit $REVIEWER_EXIT)" > "$CODEX_OUTPUT_FILE"
      fi
    else
      create_error_json "codex" "CLI not available" > "$CODEX_OUTPUT_FILE"
    fi
  ) &
  CODEX_PID=$!

  # Run Grok (reviewer 3) in background — clone of the Codex block above with
  # s/CODEX/GROK/g and s/codex/grok/g. Mirrors execute_review contract,
  # JSON-extraction, metadata injection, and error handling. Added 2026-05-26
  # to extend voice-lineage diversity into design review (xAI Grok backend).
  (
    if [[ "$GROK_AVAILABLE" == "true" ]]; then
      GROK_RAW_FILE=$(get_review_file "grok-raw.txt")
      GROK_START=$(millis)

      REVIEWER_EXIT=0
      execute_review "$REVIEWER_3_CLI" "$FULL_PROMPT" > "$GROK_RAW_FILE" 2>&1 || REVIEWER_EXIT=$?

      if [[ "$REVIEWER_EXIT" -eq 0 ]]; then
        GROK_END=$(millis)
        GROK_DURATION=$((GROK_END - GROK_START))

        if python3 "$SCRIPT_DIR/lib/extract_review_json.py" "$GROK_RAW_FILE" > "${GROK_OUTPUT_FILE}.pending" 2>/dev/null; then
          _MIM_PENDING="${GROK_OUTPUT_FILE}.pending" \
          _MIM_RUN_ID="$RUN_ID" \
          _MIM_ITERATION="$CURRENT_ITERATION" \
          _MIM_SPEC_HASH="$SPEC_HASH" \
          _MIM_DURATION="$GROK_DURATION" \
          python3 -c '
import json, os, sys
pending = os.environ["_MIM_PENDING"]
with open(pending) as f:
    data = json.load(f)
if not isinstance(data, dict) or "status" not in data:
    print("Skipping metadata injection: unexpected JSON structure", file=sys.stderr)
    sys.exit(0)
data.setdefault("metadata", {})
data["metadata"]["run_id"] = os.environ["_MIM_RUN_ID"]
data["metadata"]["iteration"] = int(os.environ["_MIM_ITERATION"])
data["metadata"]["spec_hash"] = os.environ["_MIM_SPEC_HASH"]
data["metadata"]["review_duration_ms"] = int(os.environ["_MIM_DURATION"])
with open(pending, "w") as f:
    json.dump(data, f, indent=2)
' 2>/dev/null || true
          mv "${GROK_OUTPUT_FILE}.pending" "$GROK_OUTPUT_FILE"
        else
          create_error_json "grok" "Output was not valid JSON" > "$GROK_OUTPUT_FILE"
        fi
      elif [[ "$REVIEWER_EXIT" -eq 3 ]]; then
        # BUILTIN_FALLBACK: CLI retry exhaustion — degraded mode, not hard error.
        # Arbiter proceeds with fewer external voices.
        create_error_json "grok" "CLI unavailable (builtin fallback — retry exhaustion)" > "$GROK_OUTPUT_FILE"
      else
        create_error_json "grok" "CLI execution failed (exit $REVIEWER_EXIT)" > "$GROK_OUTPUT_FILE"
      fi
    else
      create_error_json "grok" "CLI not available" > "$GROK_OUTPUT_FILE"
    fi
  ) &
  GROK_PID=$!

  # ── Auditor (ADVISORY, non-converging) ───────────────────────────
  # A 4th voice that is deliberately NOT a coverage slot. The gate condition is
  # `coverage_status == FULL AND fulfilled_lens_count == 3`; making this a real
  # slot would raise that to 4/4, so any Auditor stall would WITHHOLD PASS. The
  # backing model (opencode-go/kimi-k3) was measured stalling silently on a
  # meaningful fraction of generation-heavy prompts, which would convert model
  # flakiness directly into blocked design reviews. Modeled on the UltraOracle
  # advisory instead: its verdict reaches the arbiter, it never counts as a lens,
  # and its absence is noted rather than gating.
  #
  # Findings are LEADS, not verdicts — measured 1 true positive / 1 confident
  # false positive / 1 correct NOTHING-FOUND across three already-passed PRs,
  # with inverted confidence labels. The arbiter must verify before acting.
  AUDITOR_CLI=$(resolve_role_cli "blueprint-review.auditor")
  AUDITOR_OUTPUT_FILE=$(get_review_file "auditor.json")
  AUDITOR_PID=""
  if [[ "$AUDITOR_CLI" != "none" && "$AUDITOR_CLI" != "builtin" && ! "$AUDITOR_CLI" =~ ^(missing|unsupported): ]]; then
    (
      _aud_raw=$(get_review_file "auditor-raw.txt")
      _aud_exit=0
      # EXPLICIT short duration. execute_review defaults to 1200s; inheriting
      # that would make this "non-gating" advisory stall the whole round for up
      # to 20 minutes before arbitration — and k3 stalls silently on a
      # meaningful fraction of generation-heavy prompts, so that is the likely
      # path, not the rare one. An advisory that can delay the gate is a gate.
      execute_review "$AUDITOR_CLI" "$FULL_PROMPT" "${BLUEPRINT_AUDITOR_TIMEOUT:-300}" > "$_aud_raw" 2>&1 || _aud_exit=$?
      # ATOMIC write: build the JSON in a temp file, then rename into place. A
      # grace-period kill of this background job could otherwise interrupt a
      # direct write and leave a partial auditor.json that `cat` reads happily —
      # arbitration would then see truncated advice instead of the "unavailable"
      # fallback. `mv` on the same filesystem is atomic: the reader sees the old
      # file, the complete new file, or nothing — never a half-written one.
      _aud_tmp="${AUDITOR_OUTPUT_FILE}.tmp.$$"
      if [[ "$_aud_exit" -eq 0 ]] && [[ -s "$_aud_raw" ]]; then
        python3 "$SCRIPT_DIR/lib/extract_review_json.py" "$_aud_raw" > "$_aud_tmp" 2>/dev/null \
          || create_error_json "auditor" "unparseable advisory output" > "$_aud_tmp"
      else
        # Empty output on a clean exit is the observed silent-stall shape — must
        # read as "advisory absent", never as "advisory found nothing".
        create_error_json "auditor" "advisory failed or returned empty (rc=$_aud_exit)" > "$_aud_tmp"
      fi
      mv -f "$_aud_tmp" "$AUDITOR_OUTPUT_FILE" 2>/dev/null || rm -f "$_aud_tmp"
    ) &
    AUDITOR_PID=$!
  else
    create_error_json "auditor" "CLI not available ($AUDITOR_CLI)" > "$AUDITOR_OUTPUT_FILE"
  fi

  # Wait for all three to complete
  log_info "  Waiting for parallel reviews..."
  wait "$AGY_PID" 2>/dev/null || true
  wait "$CODEX_PID" 2>/dev/null || true
  wait "$GROK_PID" 2>/dev/null || true
  # BOUNDED reap for the advisory Auditor — it must never act as a temporal
  # gate. The three required reviewers have already completed here; give the
  # Auditor only a short grace to finish, then KILL it and proceed. Its output
  # file is either a verdict (used) or an error/absent JSON (noted), never a
  # blocker. Without the bound, `wait` could stall arbitration for the full
  # BLUEPRINT_AUDITOR_TIMEOUT after the real reviewers are already done.
  if [[ -n "${AUDITOR_PID:-}" ]]; then
    _aud_grace=0
    while kill -0 "$AUDITOR_PID" 2>/dev/null; do
      if [[ "$_aud_grace" -ge "${BLUEPRINT_AUDITOR_GRACE:-20}" ]]; then
        # Kill the whole descendant TREE, not just the subshell — execute_review
        # and opencode run as descendants and would otherwise orphan and keep
        # using the network until their own 300s timeout. Portable recursive
        # walk via `pgrep -P` (no process-group/setsid dependency).
        _kill_tree() {
          local _p="$1" _c
          for _c in $(pgrep -P "$_p" 2>/dev/null); do _kill_tree "$_c"; done
          kill "$_p" 2>/dev/null || true
        }
        _kill_tree "$AUDITOR_PID"
        log_warning "  Auditor (advisory) exceeded ${BLUEPRINT_AUDITOR_GRACE:-20}s grace after reviewers finished — killed its process tree, proceeding without it"
        break
      fi
      sleep 1; _aud_grace=$((_aud_grace + 1))
    done
    wait "$AUDITOR_PID" 2>/dev/null || true
  fi

  REVIEW_END=$(millis)
  REVIEW_DURATION=$((REVIEW_END - REVIEW_START))
  log_info "  Both reviews completed in ${REVIEW_DURATION}ms (parallel)"

  # ── Runtime droid fallback (capped at one voice) ─────────────────
  # All 3 reviewers share one prompt, so two droids = duplicate signal. Escalate
  # the FIRST failed reviewer (status not PASS/FAIL) to droid and STOP. Single
  # sequential process → no lock needed. Runs BEFORE the dup-copy so a rescued
  # reviewer_1 propagates to reviewer_2's path. Skipped entirely if droid is
  # ALREADY a voice via a resolve-time availability fallback in any slot —
  # otherwise a runtime rescue would produce a second droid-authored file.
  if is_cli_available droid \
     && [[ "$REVIEWER_1_CLI" != "droid" && "$REVIEWER_2_CLI" != "droid" && "$REVIEWER_3_CLI" != "droid" ]]; then
    for _slot in agy codex grok; do
      case "$_slot" in
        agy)   _so="$AGY_OUTPUT_FILE";   _av="$AGY_AVAILABLE" ;;
        codex) _so="$CODEX_OUTPUT_FILE"; _av="$CODEX_AVAILABLE" ;;
        grok)  _so="$GROK_OUTPUT_FILE";  _av="$GROK_AVAILABLE" ;;
      esac
      [[ "$_av" == "true" ]] || continue
      _st=$(jq -r '.status // "MISSING"' "$_so" 2>/dev/null || echo MISSING)
      [[ "$_st" == "PASS" || "$_st" == "FAIL" ]] && continue   # ran fine — not a runtime failure
      # First failed reviewer only: ONE droid attempt, then stop regardless of
      # outcome. A failed/slow droid must not trigger more long rescue waits
      # (execute_review's timeout is 1200s) — and the cap is one droid voice.
      # shellcheck disable=SC2310  # rescue handles its own errors; || true ignores its rc
      _bp_droid_rescue "$_slot" "$_so" || true
      break
    done
  fi

  # Duplicate mode: copy single reviewer's output to both paths
  if [[ "$DUPLICATE_MODE" == "true" ]]; then
    if [[ -f "$AGY_OUTPUT_FILE" ]] && validate_json_file "$AGY_OUTPUT_FILE" 2>/dev/null; then
      cp "$AGY_OUTPUT_FILE" "$CODEX_OUTPUT_FILE"
      log_info "  Duplicate mode: copied reviewer 1 output to reviewer 2 path"
    fi
  fi

  # ── Phase 2: Validate outputs ────────────────────────────────────
  log_info "Phase 2: Validating review outputs..."

  if ! validate_json_file "$AGY_OUTPUT_FILE"; then
    log_error "Agy output invalid or missing — fail-closed"
    create_error_json "agy" "Output missing or invalid after review" > "$AGY_OUTPUT_FILE"
  fi

  if ! validate_json_file "$CODEX_OUTPUT_FILE"; then
    log_error "Codex output invalid or missing — fail-closed"
    create_error_json "codex" "Output missing or invalid after review" > "$CODEX_OUTPUT_FILE"
  fi

  if ! validate_json_file "$GROK_OUTPUT_FILE"; then
    log_error "Grok output invalid or missing — fail-closed"
    create_error_json "grok" "Output missing or invalid after review" > "$GROK_OUTPUT_FILE"
  fi

  # Freshness check (Critic #2): validate or inject run_id
  for review_file in "$AGY_OUTPUT_FILE" "$CODEX_OUTPUT_FILE" "$GROK_OUTPUT_FILE"; do
    FILE_RUN_ID=$(jq -r '.metadata.run_id // ""' "$review_file" 2>/dev/null || echo "")
    REVIEWER=$(jq -r '.reviewer_id // "unknown"' "$review_file" 2>/dev/null || echo "unknown")
    if [[ -z "$FILE_RUN_ID" ]]; then
      # Missing run_id: try to inject it via jq (fallback if python3 injection failed)
      if jq --arg rid "$RUN_ID" --argjson iter "$CURRENT_ITERATION" --arg hash "$SPEC_HASH" \
        '.metadata.run_id = $rid | .metadata.iteration = $iter | .metadata.spec_hash = $hash' \
        "$review_file" > "${review_file}.tmp" 2>/dev/null; then
        mv "${review_file}.tmp" "$review_file"
        log_warning "Injected missing run_id into $review_file via jq fallback"
      else
        rm -f "${review_file}.tmp"
        log_error "MISSING run_id in $review_file and jq injection failed — fail-closed"
        create_error_json "$REVIEWER" "Missing run_id metadata (freshness contract violation)" > "$review_file"
      fi
    elif [[ "$FILE_RUN_ID" != "$RUN_ID" ]]; then
      log_error "STALE OUTPUT: $review_file has run_id=$FILE_RUN_ID, expected $RUN_ID"
      create_error_json "$REVIEWER" "Stale output from previous run" > "$review_file"
    fi
  done

  AGY_STATUS=$(jq -r '.status' "$AGY_OUTPUT_FILE")
  CODEX_STATUS=$(jq -r '.status' "$CODEX_OUTPUT_FILE")
  GROK_STATUS=$(jq -r '.status' "$GROK_OUTPUT_FILE")

  log_info "  Agy:    $AGY_STATUS ($(jq '.issues | length' "$AGY_OUTPUT_FILE") issues)"
  log_info "  Codex:  $CODEX_STATUS ($(jq '.issues | length' "$CODEX_OUTPUT_FILE") issues)"
  log_info "  Grok:   $GROK_STATUS ($(jq '.issues | length' "$GROK_OUTPUT_FILE") issues)"

  # Coverage provenance: capture which slots actually ran (non-claude-only only)
  persist_dispatch_provenance
  fi  # end of CLAUDE_ONLY guard (Phase 1-2 skipped in claude-only mode)

  # Coverage provenance: finalize fulfilled/reason from this iteration's outputs (both modes)
  derive_coverage

  # ── Phase 3: Claude validation (arbiter) ──────────────────────────
  log_info "Phase 3: Claude validation (arbiter)..."

  CLAUDE_OUTPUT_FILE=$(get_review_file "claude.json")
  CLAUDE_PROMPT_FILE=$(get_review_file "claude-validation-prompt.txt")

  CLAUDE_START=$(millis)

  CLAUDE_PROMPT=$(cat "$SCRIPT_DIR/../prompts/claude_validation_prompt.txt")

  # Coverage provenance section for the arbiter (empty when flag off)
  COVERAGE_SECTION=""
  if _coverage_enabled; then
    _cs_status=$(get_state_field "coverage_status")
    _cs_count=$(get_state_field "fulfilled_lens_count")
    COVERAGE_SECTION="## Coverage (reviewer provenance for THIS run)"$'\n'
    for _cs_n in 1 2 3; do
      COVERAGE_SECTION+="reviewer_${_cs_n}: requested=$(get_state_field "reviewer_${_cs_n}_requested") actual=$(get_state_field "reviewer_${_cs_n}_actual") fulfilled=$(get_state_field "reviewer_${_cs_n}_fulfilled") reason=$(get_state_field "reviewer_${_cs_n}_reason")"$'\n'
    done
    COVERAGE_SECTION+="Coverage: ${_cs_status} (${_cs_count}/3 fulfilled). Treat UNFULFILLED slots as ABSENT coverage: do NOT weight a duplicate/fallback/errored slot as independent agreement."
  fi

  AGY_ISSUES=$(jq -r '.issues[] | "- [\(.severity)] \(.section): \(.description)"' "$AGY_OUTPUT_FILE" 2>/dev/null || echo "No issues")
  CODEX_ISSUES=$(jq -r '.issues[] | "- [\(.severity)] \(.section): \(.description)"' "$CODEX_OUTPUT_FILE" 2>/dev/null || echo "No issues")
  GROK_ISSUES=$(jq -r '.issues[] | "- [\(.severity)] \(.section): \(.description)"' "$GROK_OUTPUT_FILE" 2>/dev/null || echo "No issues")

  # ── Build the ultra-oracle advisory section (status-aware; only wait if dispatched) ──
  ULTRA_ORACLE_ADVISORY_SECTION=""
  if [ -n "${ULTRA_ORACLE_ADVISORY_FILE:-}" ]; then
    if [ "$ULTRA_ORACLE_DISPATCH_STATUS" = "dispatched" ]; then
      # Grace margin BEYOND the oracle cap: on a real timeout the background child writes
      # .rc/.hint only AFTER _portable_timeout kills oracle at t=cap, so waiting exactly
      # cap races the child and reads no .rc (banner falls to "timeout (no completion)"
      # and drops the #340 hint). +10s lets the marker + hint land.
      _uora_wait=0; _uora_cap=$(( $(ultra_oracle_timeout_cap) + 10 ))
      while [ ! -f "$ULTRA_ORACLE_ADVISORY_FILE.rc" ] && [ "$_uora_wait" -lt "$_uora_cap" ]; do
        sleep 2; _uora_wait=$((_uora_wait + 2))
      done
    fi
    if [[ -s "$ULTRA_ORACLE_ADVISORY_FILE" ]] && [[ -f "$ULTRA_ORACLE_ADVISORY_FILE.rc" ]] && [[ "$(cat "$ULTRA_ORACLE_ADVISORY_FILE.rc")" = "0" ]]; then
      ULTRA_ORACLE_ADVISORY_SECTION="=============================================================================
OPTIONAL ULTRA-ORACLE (ChatGPT Pro) ADVISORY -- AUXILIARY, *NOT* A REVIEWER. There are still exactly THREE reviewers (Agy/Codex/Grok); do NOT count this block as a 4th lens or as independent agreement:
=============================================================================

$(cat "$ULTRA_ORACLE_ADVISORY_FILE")"
    else
      _uora_rc="$(cat "$ULTRA_ORACLE_ADVISORY_FILE.rc" 2>/dev/null || true)"
      if [ "$ULTRA_ORACLE_DISPATCH_STATUS" != "dispatched" ]; then _uora_term="$ULTRA_ORACLE_DISPATCH_STATUS"
      elif [ "$_uora_rc" = "124" ]; then _uora_term="timeout"
      elif [ -z "$_uora_rc" ]; then _uora_term="timeout (no completion within cap)"
      elif [ "$_uora_rc" != "0" ]; then _uora_term="error (rc=$_uora_rc)"
      else _uora_term="error (empty verdict)"; fi
      # Fold in the adapter's actionable hint (#340) for a known failure (cookie
      # decryption blocked / not-signed-in / Cloudflare) so THIS banner — the one the
      # operator actually sees, since blueprint-review calls the adapter directly rather
      # than via ultra-oracle-run.sh — names the next step, not just a status code.
      _uora_hint="$(cat "$ULTRA_ORACLE_ADVISORY_FILE.hint" 2>/dev/null || true)"
      _uora_suffix=""; [ -n "$_uora_hint" ] && _uora_suffix=" -- $_uora_hint"
      ULTRA_ORACLE_ADVISORY_SECTION="=============================================================================
WARNING: ULTRA-ORACLE ADVISORY FAILED [$_uora_term]$_uora_suffix -- verdict NOT included (visible best-effort; the gate converges on the THREE reviewers Agy/Codex/Grok).
============================================================================="
    fi
  elif [ "${CLAUDE_ONLY:-false}" != "true" ]; then
    # The advisory file was never set. Either the surface is disabled (stay silent)
    # OR the optional adapter failed to source while enabled (must warn — never
    # silent). Check config via _read_config_value (always loaded from resolve-cli.sh)
    # so the warning does not depend on the optional adapter's own functions.
    # USER config ONLY (mirrors ultra_oracle_config_get_user): a repo-controlled
    # project config must NOT flip this enablement probe — reading it would
    # contradict the user-config-only opt-in boundary the whole feature enforces
    # (a branch could otherwise surface a misleading "enabled" warning).
    _uora_en=""
    _uora_user_cfg="$HOME/$STATE_DIR/busdriver.json"
    if [ -f "$_uora_user_cfg" ]; then
      _uora_en="$(_read_config_value "$_uora_user_cfg" '.ultraOracle.blueprintReview.enabled' 2>/dev/null || true)"
    fi
    case "$(printf '%s' "$_uora_en" | tr '[:upper:]' '[:lower:]')" in
      true|1)
        ULTRA_ORACLE_ADVISORY_SECTION="=============================================================================
WARNING: ULTRA-ORACLE ADVISORY enabled but the adapter could not be loaded -- verdict NOT included (visible best-effort; gate converges on the THREE reviewers).
=============================================================================" ;;
    esac
  fi

  cat > "$CLAUDE_PROMPT_FILE" <<EOF
$CLAUDE_PROMPT

$COVERAGE_SECTION

=============================================================================
FRESHNESS CONTRACT (include in your output metadata):
  run_id: $RUN_ID
  iteration: $CURRENT_ITERATION
  spec_hash: $SPEC_HASH
=============================================================================

DESIGN DOCUMENT TO VALIDATE:
=============================================================================

$DESIGN_CONTENT

=============================================================================
AGY REVIEW RESULTS (Status: $AGY_STATUS):
=============================================================================

$AGY_ISSUES

Full output:
$(cat "$AGY_OUTPUT_FILE")

=============================================================================
CODEX REVIEW RESULTS (Status: $CODEX_STATUS):
=============================================================================

$CODEX_ISSUES

Full output:
$(cat "$CODEX_OUTPUT_FILE")

=============================================================================
GROK REVIEW RESULTS (Status: $GROK_STATUS):
=============================================================================

$GROK_ISSUES

Full output:
$(cat "$GROK_OUTPUT_FILE")

$ULTRA_ORACLE_ADVISORY_SECTION

=============================================================================
AUDITOR ADVISORY (opencode / kimi-k3) -- AUXILIARY, *NOT* A REVIEWER. There are
still exactly THREE reviewers (Agy/Codex/Grok); do NOT count this block as a 4th
lens or as independent agreement. Its lens is claim-vs-mechanism: places where
the document says one thing and the cited mechanism does another.

TREAT AS LEADS, NOT VERDICTS. Measured across three already-passed PRs: 1 real
defect both Codex-xhigh and the Opus backstop missed, 1 confidently-worded false
positive, 1 correct NOTHING FOUND -- with confidence labels INVERTED (the
hallucination was MEDIUM, the real defect LOW). Verify each claim against the
cited file:line before weighting it. An error/empty block below means the
advisory was ABSENT, which is NOT evidence that nothing was found.
=============================================================================

$(cat "$AUDITOR_OUTPUT_FILE" 2>/dev/null || echo '{"status":"ERROR","note":"auditor advisory unavailable"}')

=============================================================================
VALIDATION TASK:
=============================================================================

1. Read the design document and all three reviews (Agy, Codex, Grok). An optional ULTRA-ORACLE advisory block may also appear above; it is AUXILIARY context, NOT a reviewer — the reviewer count is always three, and the advisory must not be counted toward independent agreement.
2. For each issue: validate against codebase, assign validation_type
3. Search for issues they missed (validation_type: new_finding)
4. Output strict JSON with your verdict
5. Include run_id, iteration, spec_hash in metadata

Note: if any reviewer slot was unavailable (CLI not installed or failed),
its output will contain an error field — treat such slots as "no signal"
rather than "PASS". Arbitration proceeds with the reviewers that returned.

IMPORTANT: Use Read, Grep, Glob tools to examine the codebase.
EOF

  log_info "  Validation prompt: $CLAUDE_PROMPT_FILE"

  if [[ "$AUTO_MODE" == "true" ]]; then
    log_info "  Auto mode: Claude validation must be completed by the calling skill."
  elif [[ ! -t 0 ]]; then
    # Non-interactive (piped stdin) — agent invocation.
    # The agent can't write claude.json while this subprocess blocks on read.
    # Exit with code 2 so the calling skill can:
    #   1. Read the prompt file
    #   2. Write claude.json with codebase-grounded validation
    #   3. Re-run with --claude-only (skips artifact cleanup + Phase 1-2)
    log_info ""
    log_info "  Non-interactive stdin detected (agent invocation)."
    if [[ -f "$CLAUDE_OUTPUT_FILE" ]]; then
      log_info "  Found existing Claude output — continuing."
    else
      log_info "  Claude output needed. Write to: $CLAUDE_OUTPUT_FILE"
      log_info "  Then re-run with: --claude-only"
      log_info "  Prompt file: $CLAUDE_PROMPT_FILE"
      mark_review_complete "awaiting_claude_validation"
      exit 2
    fi
  else
    log_info ""
    log_info "  MANUAL STEP: Complete Claude validation with codebase context."
    log_info "  Write output to: $CLAUDE_OUTPUT_FILE"
    log_info "  Press ENTER when done..."
    read -r
  fi

  if [[ ! -f "$CLAUDE_OUTPUT_FILE" ]]; then
    log_error "Claude validation output not found: $CLAUDE_OUTPUT_FILE"
    log_error "Three-tier review requires Claude as arbiter."
    log_info "  1. Read: cat $CLAUDE_PROMPT_FILE"
    log_info "  2. Write output to: $CLAUDE_OUTPUT_FILE"
    log_info "  3. Re-run this script with --claude-only"
    mark_review_complete "awaiting_claude_validation"
    exit 1
  fi

  # Freshness check on Claude output (Critic #2)
  # Decision 7 (ADR 0003): the verdict must come from the CURRENT run, with a
  # matching spec_hash. The pre-v3.3 branch accepted a different-run verdict on
  # spec_hash match alone — but reviewer artifacts re-roll every full run, so
  # that let a verdict pass judgment on reviews it never saw. --claude-only
  # recovers RUN_ID from the reviewer artifacts on disk, so the legitimate
  # pre-written-verdict flow still matches; anything else is stale (fail-closed,
  # including missing metadata — the old -n guard let run_id-less verdicts pass).
  if ! FRESHNESS_REASON=$(validate_claude_verdict_freshness "$CLAUDE_OUTPUT_FILE" "$RUN_ID" "$SPEC_HASH" 2>&1); then
    log_error "STALE CLAUDE OUTPUT: $FRESHNESS_REASON"
    log_error "Re-dispatch the arbiter against the current validation prompt, then re-run with --claude-only."
    mark_review_complete "stale_claude_output"
    exit 1
  fi

  # Validate Claude JSON before parsing (fail-closed)
  if ! validate_json_file "$CLAUDE_OUTPUT_FILE"; then
    log_error "Claude output is invalid JSON — fail-closed"
    mark_review_complete "invalid_claude_output"
    exit 1
  fi

  CLAUDE_END=$(millis)
  CLAUDE_DURATION=$((CLAUDE_END - CLAUDE_START))

  CLAUDE_STATUS=$(jq -r '.status' "$CLAUDE_OUTPUT_FILE")
  CLAUDE_ISSUE_COUNT=$(jq '.issues | length' "$CLAUDE_OUTPUT_FILE")
  log_info "  Claude: $CLAUDE_STATUS ($CLAUDE_ISSUE_COUNT issues, ${CLAUDE_DURATION}ms)"

  update_review_statuses "$AGY_STATUS" "$CODEX_STATUS" "$CLAUDE_STATUS" "$GROK_STATUS"

  # ── Phase 4: Progress analysis (Critic #5) ────────────────────────
  # Category-aware convergence: line-level findings (test-code typos, lint, perf)
  # belong to TDD-discovery time and shouldn't block plan review. Scope-expansion
  # findings ("OUT OF SCOPE for this PR", "follow-up") get deferred to a
  # follow-up-issues.md file instead of blocking convergence.
  log_info "Phase 4: Progress analysis..."

  # Categories that are TDD-discoverable — first test run catches these in seconds.
  TDD_DISCOVERABLE_CATEGORIES='["technical-accuracy","bugs","implementation","best-practices","maintainability","performance"]'
  # Suggestion patterns that signal scope-expansion findings (defer to follow-up PR).
  SCOPE_EXPANSION_PATTERN="OUT OF SCOPE|follow-up PR|deferred to follow-up|post-merge|inherited from parent"

  # Plan-blocking counts exclude TDD-discoverable categories AND scope-expansion suggestions.
  PLAN_BLOCKING_HIGH=$(jq --argjson tdd "$TDD_DISCOVERABLE_CATEGORIES" --arg pat "$SCOPE_EXPANSION_PATTERN" \
    '[.issues[] | select(
      .severity == "high"
      and .confidence >= 0.5
      and (.category as $c | $tdd | index($c) | not)
      and ((.suggestion // "") | test($pat) | not)
    )] | length' "$CLAUDE_OUTPUT_FILE" 2>/dev/null || echo 0)

  PLAN_BLOCKING_MEDIUM=$(jq --argjson tdd "$TDD_DISCOVERABLE_CATEGORIES" --arg pat "$SCOPE_EXPANSION_PATTERN" \
    '[.issues[] | select(
      .severity == "medium"
      and .confidence >= 0.5
      and (.category as $c | $tdd | index($c) | not)
      and ((.suggestion // "") | test($pat) | not)
    )] | length' "$CLAUDE_OUTPUT_FILE" 2>/dev/null || echo 0)

  HIGH_COUNT=$(jq '[.issues[] | select(.severity == "high" and .confidence >= 0.5)] | length' "$CLAUDE_OUTPUT_FILE" 2>/dev/null || echo 0)
  MEDIUM_COUNT=$(jq '[.issues[] | select(.severity == "medium" and .confidence >= 0.5)] | length' "$CLAUDE_OUTPUT_FILE" 2>/dev/null || echo 0)
  LOW_COUNT=$(jq '[.issues[] | select(.severity == "low")] | length' "$CLAUDE_OUTPUT_FILE" 2>/dev/null || echo 0)

  DEFERRED_COUNT=$(( (HIGH_COUNT + MEDIUM_COUNT) - (PLAN_BLOCKING_HIGH + PLAN_BLOCKING_MEDIUM) ))
  # Clamp to >= 0 — if the two jq groups error-default differently (one returns
  # 0, the other returns real values), the subtraction can underflow.
  if [[ "$DEFERRED_COUNT" -lt 0 ]]; then
    DEFERRED_COUNT=0
  fi

  # Write deferred issues to a follow-up file so the user sees what was set aside.
  if [[ "$DEFERRED_COUNT" -gt 0 ]]; then
    FOLLOWUP_FILE=$(get_review_file "follow-up-issues.md")
    {
      printf '# Deferred Findings (TDD-discoverable + scope-expansion)\n\n'
      printf 'These findings were not blocked at design-review time because they fall into one of two buckets:\n\n'
      printf '1. **TDD-discoverable**: line-level concerns (test stubs, lint, perf) that the first test run catches in seconds.\n'
      printf '2. **Scope-expansion**: legitimate findings explicitly marked as "OUT OF SCOPE for this PR" or "follow-up PR" by the arbiter.\n\n'
      printf 'Address them during implementation (TDD) or open a follow-up issue (scope-expansion).\n\n'
      printf -- '---\n\n'
      jq -r --argjson tdd "$TDD_DISCOVERABLE_CATEGORIES" --arg pat "$SCOPE_EXPANSION_PATTERN" \
        '.issues[] | select(
          (.severity == "high" or .severity == "medium")
          and .confidence >= 0.5
          and ((.category as $c | $tdd | index($c)) or ((.suggestion // "") | test($pat)))
        ) | "## [\(.severity | ascii_upcase)] \(.section)\n\n**Category:** \(.category) | **Confidence:** \(.confidence)\n\n**Description:** \(.description)\n\n**Suggestion:** \(.suggestion)\n"' \
        "$CLAUDE_OUTPUT_FILE" 2>/dev/null
    } > "$FOLLOWUP_FILE"
    log_info "  Deferred $DEFERRED_COUNT issue(s) to: $FOLLOWUP_FILE"
  fi

  # Convergence based on plan-blocking counts only (Fix 1).
  # Capture the persisted progress_status BEFORE recomputing so the medium
  # history reset (below) can detect a state re-entry transition.
  PREV_PROGRESS_STATUS=$(get_state_field "progress_status")
  if [[ "$PLAN_BLOCKING_HIGH" -gt 0 ]]; then
    PROGRESS_STATUS="blocked_by_high_issues"
  elif [[ "$PLAN_BLOCKING_MEDIUM" -gt 0 ]]; then
    PROGRESS_STATUS="medium_issues_remaining"
  elif [[ "$LOW_COUNT" -gt 0 || "$DEFERRED_COUNT" -gt 0 ]]; then
    PROGRESS_STATUS="low_issues_only"
  else
    PROGRESS_STATUS="passed"
  fi

  update_state_field "progress_status" "\"$PROGRESS_STATUS\""
  update_state_field "high_issues" "$HIGH_COUNT"
  update_state_field "medium_issues" "$MEDIUM_COUNT"
  update_state_field "low_issues" "$LOW_COUNT"
  update_state_field "plan_blocking_high" "$PLAN_BLOCKING_HIGH"
  update_state_field "plan_blocking_medium" "$PLAN_BLOCKING_MEDIUM"
  update_state_field "deferred_issues" "$DEFERRED_COUNT"

  # Track plan-blocking-high trajectory for early-stop check (Fix 2).
  append_high_history "$PLAN_BLOCKING_HIGH"
  # Track plan-blocking-medium trajectory ONLY when MEDIUM is the current
  # blocker. Pushing during iterations where HIGH was still the blocker would
  # inflate the history with stale counts and falsely satisfy check_no_progress
  # on the first medium_issues_remaining iteration — the user hadn't focused
  # on MEDIUMs yet, so seeing the same MEDIUM count isn't a "no progress"
  # signal. Trajectory comparison only begins once medium_issues_remaining
  # has held for ≥2 iterations.
  if [[ "$PROGRESS_STATUS" == "medium_issues_remaining" ]]; then
    # On re-entry (medium → blocked_by_high → medium), stale pre-HIGH entries
    # would cause check_no_progress to fire immediately on the first re-entered
    # MEDIUM iteration. Reset the history at the transition boundary so only
    # the current MEDIUM stint's trajectory is evaluated.
    if [[ "$PREV_PROGRESS_STATUS" != "medium_issues_remaining" ]]; then
      update_state_field "medium_issues_history" "\"[]\""
    fi
    append_medium_history "$PLAN_BLOCKING_MEDIUM"
  fi

  # Surface Claude's validation_notes so the user sees the arbiter's reasoning (Fix 5).
  VALIDATION_NOTES=$(jq -r '.validation_notes // ""' "$CLAUDE_OUTPUT_FILE" 2>/dev/null || echo "")
  if [[ -n "$VALIDATION_NOTES" && "$VALIDATION_NOTES" != "null" ]]; then
    log_info ""
    log_info "  Claude validation notes:"
    printf '%s\n' "$VALIDATION_NOTES" | sed 's/^/    /'
    log_info ""
  fi

  log_info "  Status: $PROGRESS_STATUS"
  log_info "  Issues: $HIGH_COUNT high ($PLAN_BLOCKING_HIGH plan-blocking), $MEDIUM_COUNT medium ($PLAN_BLOCKING_MEDIUM plan-blocking), $LOW_COUNT low"
  if [[ "$DEFERRED_COUNT" -gt 0 ]]; then
    log_info "  Deferred to TDD/follow-up: $DEFERRED_COUNT (see follow-up-issues.md)"
  fi

  # Trajectory-aware early stop (Fix 2): if plan-blocking-high didn't strictly
  # decrease from the prior iteration, the loop is unproductive — accept current
  # state as low_issues_only rather than grind through max_iterations.
  #
  # window=1 (compare iteration N to N-1) so the check fires after iteration 2
  # under default max_iterations=5. With window=2 the check would need 3 entries
  # before firing, giving the loop one extra grinding iteration with no payoff.
  #
  # IMPORTANT: only gate on blocked_by_high_issues. The trajectory tracks HIGH
  # only, so a medium_issues_remaining state (HIGH=0, MEDIUM>0) would trivially
  # satisfy "HIGH didn't decrease" and produce a false PASS while blocking
  # MEDIUMs remain. (Surfaced by PR #55 review — copilot-pull-request-reviewer.)
  if [[ "$PROGRESS_STATUS" == "blocked_by_high_issues" ]]; then
    HISTORY=$(get_high_history)
    if [[ "$CURRENT_ITERATION" -ge 2 ]] && check_no_progress "$HISTORY" 1; then
      log_warning ""
      log_warning "  Trajectory: plan-blocking HIGH did not decrease from prior iteration ($HISTORY)"
      log_warning "  Auto-stop: convergence loop unproductive — accepting current state"
      PROGRESS_STATUS="low_issues_only"
      update_state_field "progress_status" "\"$PROGRESS_STATUS\""
      update_state_field "early_stopped" "\"no_improvement_trajectory\""
    fi
  fi

  # Parallel trajectory check for medium_issues_remaining state. HIGH is already
  # resolved (PLAN_BLOCKING_HIGH==0) but MEDIUMs persist — without this, the loop
  # has no circuit breaker for stuck MEDIUM convergence and grinds to max_iter
  # (empirically observed in growth-engine task-13-content-audit, iter 3/3 with
  # high_issues_history=[2,0] and 3 MEDIUMs unresolved).
  if [[ "$PROGRESS_STATUS" == "medium_issues_remaining" ]]; then
    MEDIUM_HISTORY=$(get_medium_history)
    if [[ "$CURRENT_ITERATION" -ge 2 ]] && check_no_progress "$MEDIUM_HISTORY" 1; then
      log_warning ""
      log_warning "  Trajectory: plan-blocking MEDIUM did not decrease from prior iteration ($MEDIUM_HISTORY)"
      log_warning "  Auto-stop: convergence loop unproductive — accepting current state"
      PROGRESS_STATUS="low_issues_only"
      update_state_field "progress_status" "\"$PROGRESS_STATUS\""
      update_state_field "early_stopped" "\"no_improvement_trajectory\""
    fi
  fi

  # ── Phase 5: Convergence (Critic #4: Claude verdict) ──────────────
  log_info "Phase 5: Convergence check..."

  if [[ "$PROGRESS_STATUS" == "passed" || "$PROGRESS_STATUS" == "low_issues_only" ]]; then
    log_info ""
    log_info "=== DESIGN APPROVED ==="
    log_info "  Verdict: $PROGRESS_STATUS | Run: $RUN_ID"
    log_info ""

    # #355: implementation may be authorized ONLY on CONFIRMED FULL coverage. Fail
    # CLOSED: when coverage tracking is on, any status that is not exactly "FULL"
    # (DEGRADED, UNKNOWN, empty, malformed) withholds the PASS marker AND leaves the
    # pending tokens armed below — the pre-implementation gate keys on token
    # existence, so a bare non-prune is what actually keeps a security-gate plan
    # blocked. Writing the coverage marker first keeps provenance honest either way.
    # Authorize (stamp PASS + prune tokens) ONLY on the SAME invariant the readers
    # enforce: coverage_status == FULL AND fulfilled_lens_count == 3. Checking status
    # alone would let a torn/contradictory state (status FULL with count 2) prune the
    # tokens while the reader rejects the resulting `FULL 2/3` marker — a fail-open.
    _cov_block=false
    # shellcheck disable=SC2310  # predicate used in a condition by design (matches the coverage-marker block below)
    if _coverage_enabled; then
      _cov_status_now="$(get_state_field "coverage_status")"
      _cov_count_now="$(get_state_field "fulfilled_lens_count")"
      if [[ "$_cov_status_now" != "FULL" || "$_cov_count_now" != "3" ]]; then
        _cov_block=true
      fi
    fi

    # Atomic in-place sed via an UNPREDICTABLE mktemp sibling — never a fixed
    # `${DESIGN_FILE}.tmp`/.covtmp name a pre-existing symlink could hijack into
    # truncating an arbitrary target. (Concurrent reviews of the SAME doc are already
    # prevented upstream by the loop's review-pointer guard, so this only needs to be
    # single-writer-safe.) The mode is copied from the source AFTER sed writes the
    # temp — before-write would make a read-only (0444) source's redirect fail — so the
    # replacement keeps the doc's original perms rather than mktemp's 0600. The temp is
    # always removed, including on an mv failure, so no `.dr-edit.*` copy is leaked.
    _dr_atomic_sed() {  # <sed-expr> <file>
      local _e="$1" _f="$2" _d _t _m
      _d=$(dirname -- "$_f") || return 1
      _t=$(mktemp "$_d/.dr-edit.XXXXXX") || return 1
      # `if` guards throughout (never `cmd && ...`): a failing left-of-&& would trip
      # set -e and skip the temp cleanup below.
      if sed "$_e" "$_f" > "$_t"; then
        # Copy the source mode onto the temp (GNU `stat -c` / BSD `stat -f`) before the
        # swap; best-effort, and 0600 is the safe fallback if the mode is unreadable.
        _m=$(stat -c '%a' "$_f" 2>/dev/null || stat -f '%Lp' "$_f" 2>/dev/null || true)
        if [[ -n "$_m" ]]; then chmod "$_m" "$_t" 2>/dev/null || true; fi
        if mv -f "$_t" "$_f"; then return 0; fi
      fi
      rm -f "$_t"
      return 1
    }

    # WHOLE-LINE marker regexes (the writer always emits each marker on its own line).
    # Every detect (grep) and rewrite (sed) below anchors to these so a marker string
    # embedded in PROSE — `... the <!-- design-reviewed: PASS --> marker ...` — is never
    # matched or corrupted. A marker ALONE on its own line is treated as a real marker
    # by BOTH the writer here AND the reader (_doc_reviewed matches any occurrence): this
    # is inherent to the machine-consumed marker design, so a tracked design doc must not
    # place a bare-line marker example (even inside a ``` fence). No ERE-only metachars,
    # so the same pattern is valid in grep BRE and sed BRE.
    # _RE_COV keys on a line STARTING with the coverage prefix (not a complete `-->`),
    # matching the reader's total count — so the upsert/strip below can also REPAIR a
    # truncated/split/malformed stale marker line, not just a well-formed one. `.*$`
    # consumes the rest of that line so the whole line is replaced/deleted. A prefix
    # mid-line in prose is not at line start ⇒ untouched.
    _RE_COV='^[[:space:]]*<!-- design-review-coverage:.*$'
    _RE_PASS='^[[:space:]]*<!-- design-reviewed: PASS -->[[:space:]]*$'
    _RE_PEND='^[[:space:]]*<!-- design-reviewed: PENDING -->[[:space:]]*$'

    # Write the coverage provenance marker FIRST — BEFORE any PASS — so a durable
    # PASS is never present without its coverage marker beside it. A crash between the
    # two would otherwise leave a bare PASS that _doc_reviewed honors (no coverage
    # marker = honorable). Always upsert: it records the honest DEGRADED/FULL status.
    # shellcheck disable=SC2310  # predicate used in a condition by design
    if _coverage_enabled && [[ -f "$DESIGN_FILE" ]]; then
      _cov_status=$(get_state_field "coverage_status")
      _cov_count=$(get_state_field "fulfilled_lens_count")
      _cov_detail=""
      for _cn in 1 2 3; do
        _cr=$(get_state_field "reviewer_${_cn}_reason")
        [[ -n "$_cr" && "$_cr" != "ok" ]] && _cov_detail="${_cov_detail:+$_cov_detail }reviewer_${_cn}=${_cr}"
      done
      _cov_marker="<!-- design-review-coverage: ${_cov_status:-UNKNOWN} ${_cov_count}/3 ${_cov_detail} -->"
      if grep -q "$_RE_COV" "$DESIGN_FILE" 2>/dev/null; then
        _dr_atomic_sed "s|$_RE_COV|${_cov_marker}|" "$DESIGN_FILE"
      else
        # Leading '\n' guarantees the marker lands on its OWN line even when the file
        # lacks a trailing newline — otherwise it would fuse onto the last line
        # (`text<!-- ... -->`), which the whole-line regex could never find or replace,
        # so a later FULL review would append a duplicate instead of updating it.
        printf '\n%s\n' "$_cov_marker" >> "$DESIGN_FILE"
      fi
    elif [[ -f "$DESIGN_FILE" ]] && grep -q "$_RE_COV" "$DESIGN_FILE" 2>/dev/null; then
      # Coverage tracking OFF but the doc carries a stale WHOLE-LINE marker from a prior
      # tracked run: with no upsert to refresh it, a leftover DEGRADED/UNKNOWN would make
      # the reader reject the PASS we may stamp below (contradictory writer/reader state).
      # Provenance is off ⇒ no coverage gate ⇒ strip the stale marker line so both agree.
      _dr_atomic_sed "/$_RE_COV/d" "$DESIGN_FILE"
    fi
    record_coverage_finalize

    # Not confirmed FULL 3/3 → withhold PASS, keep pending tokens ARMED (do not prune)
    # so the pre-implementation gate keeps blocking, and finish without marking passed.
    # mark_review_complete sets active:false → the caller stops re-invoking.
    if [[ "$_cov_block" == true ]]; then
      # Downgrade any stale PASS (from a prior FULL run) to PENDING so the withheld
      # verdict is HONEST — the reader already rejects PASS-beside-DEGRADED, but don't
      # leave the physical contradiction in the doc.
      if [[ -f "$DESIGN_FILE" ]] && grep -q "$_RE_PASS" "$DESIGN_FILE" 2>/dev/null; then
        _dr_atomic_sed "s|$_RE_PASS|<!-- design-reviewed: PENDING -->|" "$DESIGN_FILE"
      fi
      log_warning "  COVERAGE NOT CONFIRMED FULL (status=${_cov_status_now:-unset} count=${_cov_count_now:-unset}) — PASS withheld (#355); review stays PENDING."
      log_warning "  Pending review tokens left ARMED — implementation stays gated on partial coverage."
      log_warning "  Fix the reviewer CLIs (which agy codex grok) and re-run, or create skip-design-review.local to proceed knowingly."
      update_state_field "early_stopped" "\"degraded_coverage\""
      mark_review_complete "degraded_coverage"
      exit 1
    fi

    # Confirmed FULL 3/3 → authorize. The FULL 3/3 coverage marker is already durable
    # above, so stamp PASS now (then prune the pending tokens below).
    if [[ -f "$DESIGN_FILE" ]]; then
      if ! grep -q "$_RE_PASS" "$DESIGN_FILE" 2>/dev/null; then
        if grep -q "$_RE_PEND" "$DESIGN_FILE" 2>/dev/null; then
          _dr_atomic_sed "s|$_RE_PEND|<!-- design-reviewed: PASS -->|" "$DESIGN_FILE"
        else
          printf '\n<!-- design-reviewed: PASS -->\n' >> "$DESIGN_FILE"
        fi
        log_info "Gate marker written to: $DESIGN_FILE"
      fi
    else
      log_error "Design file not found: $DESIGN_FILE"
      mark_review_complete "error_no_design_file"
      exit 1
    fi

    # ADR-D: prune ONLY the tokens snapshotted at loop start (physical-abspath
    # keyed → never cross-clears a divergent branch; re-armed tokens survive).
    # This inline rm inside the trusted loop is invisible to the marker-forge
    # guard (which sees only the top-level `bash …run-design-review-loop.sh` call);
    # a Claude tool-call rm of a token stays blocked. Replaces the old whole-file
    # `rm` of the single CWD-relative marker (divergence 4).
    if [ "${#_MARKER_SNAP[@]}" -gt 0 ]; then
      rm -f "${_MARKER_SNAP[@]}"
    fi
    if [ "$_MARKER_RESOLVE_OK" = true ]; then
      log_info "Design review state cleaned up (${#_MARKER_SNAP[@]} marker token(s) pruned)."
    else
      log_warning "PASS recorded, but the marker dir was unresolved at loop start — NO tokens were pruned; drain manually if the gate keeps blocking."
    fi
    mark_review_complete "passed"
    exit 0
  fi

  # ── Not converged ─────────────────────────────────────────────────
  log_info "Not converged: $PROGRESS_STATUS"

  if [[ "$AUTO_MODE" == "true" ]]; then
    # In auto mode, exit after one iteration so the calling skill can:
    # 1. Fix issues in the spec
    # 2. Run Claude validation (requires codebase access)
    # 3. Re-invoke this script for the next iteration
    # Blindly continuing would fail: claude.json is cleaned at iteration
    # start and the script can't produce it without codebase tools.
    log_info "Auto mode: Iteration complete. Exiting for skill to handle fixes + Claude validation."
    log_info "  Fix $HIGH_COUNT high + $MEDIUM_COUNT medium issues, then re-invoke."
    increment_iteration
    exit 1
  else
    log_info "Address the issues, then re-run:"
    log_info "  High:   $HIGH_COUNT (must fix)"
    log_info "  Medium: $MEDIUM_COUNT (should fix)"
    log_info "  Low:    $LOW_COUNT (optional)"
    increment_iteration
    break
  fi
done

log_info ""
log_info "Review loop exited. State: cat $STATE_FILE"
