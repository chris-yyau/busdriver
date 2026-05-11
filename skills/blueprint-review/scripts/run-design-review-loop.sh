#!/bin/bash
# Three-tier design review: Gemini + Codex (parallel) → Claude arbiter
#
# Architecture (post-A++ council fix, 2026-03-27):
#   - Gemini + Codex run in parallel as independent reviewers
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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/validation.sh"

# Source shared CLI resolution library
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
# shellcheck source=../../../scripts/lib/resolve-cli.sh
source "$_PLUGIN_ROOT/scripts/lib/resolve-cli.sh"
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
      echo "  --claude-only   Skip Gemini+Codex, only run Phase 3-5 (Claude validation + convergence)"
      echo "  --help          Show this help message"
      echo ""
      echo "Architecture:"
      echo "  1. Gemini + Codex review in PARALLEL"
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

# Compute spec hash for freshness contract (Critic #2)
SPEC_HASH=$(compute_spec_hash "$DESIGN_FILE")
log_info "Spec hash: ${SPEC_HASH:0:12}..."

if [[ "$CLAUDE_ONLY" == "true" ]]; then
  # --claude-only: recover run_id from existing Codex/Gemini outputs
  CODEX_FILE=$(get_review_file "codex.json")
  GEMINI_FILE=$(get_review_file "gemini.json")
  RUN_ID=""
  if [[ -f "$CODEX_FILE" ]]; then
    RUN_ID=$(jq -r '.metadata.run_id // ""' "$CODEX_FILE" 2>/dev/null || echo "")
  fi
  if [[ -z "$RUN_ID" && -f "$GEMINI_FILE" ]]; then
    RUN_ID=$(jq -r '.metadata.run_id // ""' "$GEMINI_FILE" 2>/dev/null || echo "")
  fi
  if [[ -z "$RUN_ID" ]]; then
    log_error "--claude-only requires existing Gemini/Codex outputs with run_id."
    log_error "Run without --claude-only first to generate them."
    exit 1
  fi
  log_info "Mode: CLAUDE-ONLY (Phase 3-5 only)"
  log_info "Recovered run ID: $RUN_ID"
  GEMINI_AVAILABLE=false
  CODEX_AVAILABLE=false
else
  # Normal mode: generate fresh run ID
  RUN_ID=$(generate_run_id)
  log_info "Run ID: $RUN_ID"

  # Resolve CLIs from config
  log_info "Resolving reviewer CLIs..."
  REVIEWER_1_CLI=$(resolve_role_cli "blueprint-review.reviewer_1")
  REVIEWER_2_CLI=$(resolve_role_cli "blueprint-review.reviewer_2")
  log_info "  Reviewer 1: $REVIEWER_1_CLI"
  log_info "  Reviewer 2: $REVIEWER_2_CLI"

  # Duplicate detection (council-validated decision 4c)
  DUPLICATE_MODE=false
  if [[ "$REVIEWER_1_CLI" == "$REVIEWER_2_CLI" && "$REVIEWER_1_CLI" != "none" && "$REVIEWER_1_CLI" != "builtin" && ! "$REVIEWER_1_CLI" =~ ^missing: ]]; then
    DUPLICATE_MODE=true
    log_warning "  Degraded: both reviewers resolved to $REVIEWER_1_CLI (single-reviewer mode)"
  fi

  # Set availability flags for backward compat with rest of script
  GEMINI_AVAILABLE=false
  CODEX_AVAILABLE=false
  [[ "$REVIEWER_1_CLI" != "none" && "$REVIEWER_1_CLI" != "builtin" && ! "$REVIEWER_1_CLI" =~ ^missing: ]] && GEMINI_AVAILABLE=true
  [[ "$REVIEWER_2_CLI" != "none" && "$REVIEWER_2_CLI" != "builtin" && ! "$REVIEWER_2_CLI" =~ ^missing: && "$DUPLICATE_MODE" == "false" ]] && CODEX_AVAILABLE=true

  # Duplicate mode: after single reviewer runs, its output will be copied to both paths (see post-wait block below)
fi

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
    log_info "Options: fix issues and re-run, or create .claude/skip-design-review.local in terminal."
    mark_review_complete "max_iterations_exceeded"
    exit 1
  fi

  if [[ "$CLAUDE_ONLY" == "true" ]]; then
    # --claude-only: skip cleanup and Gemini+Codex, jump straight to Phase 3
    log_info "Claude-only mode: skipping Phase 1-2 (using existing Gemini+Codex outputs)"

    GEMINI_OUTPUT_FILE=$(get_review_file "gemini.json")
    CODEX_OUTPUT_FILE=$(get_review_file "codex.json")
    GEMINI_STATUS=$(jq -r '.status' "$GEMINI_OUTPUT_FILE" 2>/dev/null || echo "ERROR")
    CODEX_STATUS=$(jq -r '.status' "$CODEX_OUTPUT_FILE" 2>/dev/null || echo "ERROR")
    DESIGN_CONTENT=$(cat "$DESIGN_FILE")
    REVIEW_START=$(millis)
  else

  # ── Critic #1: Clean stale outputs from previous iteration ────────
  # Preserve claude.json if it matches the current spec hash — the agent
  # may have written it in a prior run but couldn't get the loop to consume
  # it (non-interactive deadlock). Cleaning it forces a redundant review cycle.
  PRESERVE_CLAUDE=false
  CLAUDE_FILE_PATH="$(get_review_file "claude.json")"
  if [[ -f "$CLAUDE_FILE_PATH" ]]; then
    CLAUDE_SPEC_HASH=$(jq -r '.metadata.spec_hash // ""' "$CLAUDE_FILE_PATH" 2>/dev/null || echo "")
    if [[ -n "$CLAUDE_SPEC_HASH" && "$CLAUDE_SPEC_HASH" == "$SPEC_HASH" ]]; then
      PRESERVE_CLAUDE=true
      log_info "Preserving claude.json (spec_hash matches current design)"
    fi
  fi

  log_info "Cleaning stale artifacts..."
  rm -f "$(get_review_file "gemini.json")" \
        "$(get_review_file "gemini-raw.txt")" \
        "$(get_review_file "gemini.json.pending")" \
        "$(get_review_file "codex.json")" \
        "$(get_review_file "codex-raw.txt")" \
        "$(get_review_file "codex.json.pending")" \
        "$(get_review_file "claude.json.pending")" \
        "$(get_review_file "claude-validation-prompt.txt")" \
        "$(get_review_file "consensus.json")" \
        "$(get_review_file "decisions.json")" \
        "$(get_review_file "autofix-log.json")" \
        "$(get_review_file "autofix-summary.json")" \
        "$(get_review_file "report.txt")" \
        2>/dev/null || true
  if [[ "$PRESERVE_CLAUDE" == "false" ]]; then
    rm -f "$CLAUDE_FILE_PATH" 2>/dev/null || true
  fi
  log_info "  Stale artifacts cleared"

  # Read design file content and build prompt
  DESIGN_CONTENT=$(cat "$DESIGN_FILE")
  PROMPT=$(cat "$SCRIPT_DIR/../prompts/comprehensive_review_prompt.txt")
  FULL_PROMPT="$PROMPT

Document to review:
---
$DESIGN_CONTENT
---"

  # ── Phase 1: Launch Gemini + Codex in PARALLEL ────────────────────
  log_info "Phase 1: Launching Gemini + Codex reviews in parallel..."

  GEMINI_OUTPUT_FILE=$(get_review_file "gemini.json")
  CODEX_OUTPUT_FILE=$(get_review_file "codex.json")

  REVIEW_START=$(millis)

  # Run Gemini in background
  (
    if [[ "$GEMINI_AVAILABLE" == "true" ]]; then
      GEMINI_RAW_FILE=$(get_review_file "gemini-raw.txt")
      GEMINI_START=$(millis)

      # Capture exit code per execute_review contract (exit 3 = BUILTIN_FALLBACK)
      REVIEWER_EXIT=0
      execute_review "$REVIEWER_1_CLI" "$FULL_PROMPT" > "$GEMINI_RAW_FILE" 2>&1 || REVIEWER_EXIT=$?

      if [[ "$REVIEWER_EXIT" -eq 0 ]]; then
        GEMINI_END=$(millis)
        GEMINI_DURATION=$((GEMINI_END - GEMINI_START))

        if python3 "$SCRIPT_DIR/lib/extract_review_json.py" "$GEMINI_RAW_FILE" > "${GEMINI_OUTPUT_FILE}.pending" 2>/dev/null; then
          # Inject freshness metadata (Critic #2)
          # Validates JSON has expected structure before injecting.
          # All values are passed via env vars (single-quoted python -c source
          # string) so paths or hash strings containing `'` cannot escape into
          # the python body.
          # || true: don't let injection failure kill subshell under set -e
          _MIM_PENDING="${GEMINI_OUTPUT_FILE}.pending" \
          _MIM_RUN_ID="$RUN_ID" \
          _MIM_ITERATION="$CURRENT_ITERATION" \
          _MIM_SPEC_HASH="$SPEC_HASH" \
          _MIM_DURATION="$GEMINI_DURATION" \
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
          mv "${GEMINI_OUTPUT_FILE}.pending" "$GEMINI_OUTPUT_FILE"
        else
          create_error_json "gemini" "Output was not valid JSON" > "$GEMINI_OUTPUT_FILE"
        fi
      elif [[ "$REVIEWER_EXIT" -eq 3 ]]; then
        # BUILTIN_FALLBACK: CLI retry exhaustion — degraded mode, not hard error.
        # Arbiter proceeds with fewer external voices.
        create_error_json "gemini" "CLI unavailable (builtin fallback — retry exhaustion)" > "$GEMINI_OUTPUT_FILE"
      else
        create_error_json "gemini" "CLI execution failed (exit $REVIEWER_EXIT)" > "$GEMINI_OUTPUT_FILE"
      fi
    else
      create_error_json "gemini" "CLI not available" > "$GEMINI_OUTPUT_FILE"
    fi
  ) &
  GEMINI_PID=$!

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

  # Wait for both to complete
  log_info "  Waiting for parallel reviews..."
  wait $GEMINI_PID 2>/dev/null || true
  wait $CODEX_PID 2>/dev/null || true

  REVIEW_END=$(millis)
  REVIEW_DURATION=$((REVIEW_END - REVIEW_START))
  log_info "  Both reviews completed in ${REVIEW_DURATION}ms (parallel)"

  # Duplicate mode: copy single reviewer's output to both paths
  if [[ "$DUPLICATE_MODE" == "true" ]]; then
    if [[ -f "$GEMINI_OUTPUT_FILE" ]] && validate_json_file "$GEMINI_OUTPUT_FILE" 2>/dev/null; then
      cp "$GEMINI_OUTPUT_FILE" "$CODEX_OUTPUT_FILE"
      log_info "  Duplicate mode: copied reviewer 1 output to reviewer 2 path"
    fi
  fi

  # ── Phase 2: Validate outputs ────────────────────────────────────
  log_info "Phase 2: Validating review outputs..."

  if ! validate_json_file "$GEMINI_OUTPUT_FILE"; then
    log_error "Gemini output invalid or missing — fail-closed"
    create_error_json "gemini" "Output missing or invalid after review" > "$GEMINI_OUTPUT_FILE"
  fi

  if ! validate_json_file "$CODEX_OUTPUT_FILE"; then
    log_error "Codex output invalid or missing — fail-closed"
    create_error_json "codex" "Output missing or invalid after review" > "$CODEX_OUTPUT_FILE"
  fi

  # Freshness check (Critic #2): validate or inject run_id
  for review_file in "$GEMINI_OUTPUT_FILE" "$CODEX_OUTPUT_FILE"; do
    FILE_RUN_ID=$(jq -r '.metadata.run_id // ""' "$review_file" 2>/dev/null || echo "")
    REVIEWER=$(jq -r '.reviewer_id // "unknown"' "$review_file" 2>/dev/null || echo "unknown")
    FILE_STATUS=$(jq -r '.status // ""' "$review_file" 2>/dev/null || echo "")
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

  GEMINI_STATUS=$(jq -r '.status' "$GEMINI_OUTPUT_FILE")
  CODEX_STATUS=$(jq -r '.status' "$CODEX_OUTPUT_FILE")

  log_info "  Gemini: $GEMINI_STATUS ($(jq '.issues | length' "$GEMINI_OUTPUT_FILE") issues)"
  log_info "  Codex:  $CODEX_STATUS ($(jq '.issues | length' "$CODEX_OUTPUT_FILE") issues)"

  fi  # end of CLAUDE_ONLY guard (Phase 1-2 skipped in claude-only mode)

  # ── Phase 3: Claude validation (arbiter) ──────────────────────────
  log_info "Phase 3: Claude validation (arbiter)..."

  CLAUDE_OUTPUT_FILE=$(get_review_file "claude.json")
  CLAUDE_PROMPT_FILE=$(get_review_file "claude-validation-prompt.txt")

  CLAUDE_START=$(millis)

  CLAUDE_PROMPT=$(cat "$SCRIPT_DIR/../prompts/claude_validation_prompt.txt")

  GEMINI_ISSUES=$(jq -r '.issues[] | "- [\(.severity)] \(.section): \(.description)"' "$GEMINI_OUTPUT_FILE" 2>/dev/null || echo "No issues")
  CODEX_ISSUES=$(jq -r '.issues[] | "- [\(.severity)] \(.section): \(.description)"' "$CODEX_OUTPUT_FILE" 2>/dev/null || echo "No issues")

  cat > "$CLAUDE_PROMPT_FILE" <<EOF
$CLAUDE_PROMPT

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
GEMINI REVIEW RESULTS (Status: $GEMINI_STATUS):
=============================================================================

$GEMINI_ISSUES

Full output:
$(cat "$GEMINI_OUTPUT_FILE")

=============================================================================
CODEX REVIEW RESULTS (Status: $CODEX_STATUS):
=============================================================================

$CODEX_ISSUES

Full output:
$(cat "$CODEX_OUTPUT_FILE")

=============================================================================
VALIDATION TASK:
=============================================================================

1. Read the design document and both reviews
2. For each issue: validate against codebase, assign validation_type
3. Search for issues they missed (validation_type: new_finding)
4. Output strict JSON with your verdict
5. Include run_id, iteration, spec_hash in metadata

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
  # Accept claude.json from a different run_id if spec_hash matches — the design
  # hasn't changed, so the validation is still relevant. This enables the preserved-
  # claude.json flow where the agent wrote claude.json in a prior run.
  CLAUDE_RUN_ID=$(jq -r '.metadata.run_id // ""' "$CLAUDE_OUTPUT_FILE" 2>/dev/null || echo "")
  CLAUDE_SPEC_HASH_CHECK=$(jq -r '.metadata.spec_hash // ""' "$CLAUDE_OUTPUT_FILE" 2>/dev/null || echo "")
  if [[ -n "$CLAUDE_RUN_ID" && "$CLAUDE_RUN_ID" != "$RUN_ID" ]]; then
    if [[ -n "$CLAUDE_SPEC_HASH_CHECK" && "$CLAUDE_SPEC_HASH_CHECK" == "$SPEC_HASH" ]]; then
      log_info "  Claude output from different run but spec_hash matches — accepting"
    else
      log_error "STALE CLAUDE OUTPUT: run_id=$CLAUDE_RUN_ID, expected $RUN_ID (spec_hash mismatch)"
      log_error "Re-run Claude validation against current Gemini/Codex outputs."
      mark_review_complete "stale_claude_output"
      exit 1
    fi
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

  update_review_statuses "$GEMINI_STATUS" "$CODEX_STATUS" "$CLAUDE_STATUS"

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
  # under default max_iterations=3. With window=2 the check would need 3 entries
  # and never fire under default config (loop exits at iter 3 before phase 4 runs
  # a third time).
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

  # ── Phase 5: Convergence (Critic #4: Claude verdict) ──────────────
  log_info "Phase 5: Convergence check..."

  if [[ "$PROGRESS_STATUS" == "passed" || "$PROGRESS_STATUS" == "low_issues_only" ]]; then
    log_info ""
    log_info "=== DESIGN APPROVED ==="
    log_info "  Verdict: $PROGRESS_STATUS | Run: $RUN_ID"
    log_info ""

    if [[ -f "$DESIGN_FILE" ]]; then
      if ! grep -q "<!-- design-reviewed: PASS -->" "$DESIGN_FILE" 2>/dev/null; then
        if grep -q "<!-- design-reviewed: PENDING -->" "$DESIGN_FILE" 2>/dev/null; then
          # Portable in-place edit (works on macOS and Linux)
          tmp_design="${DESIGN_FILE}.tmp"
          sed 's/<!-- design-reviewed: PENDING -->/<!-- design-reviewed: PASS -->/' "$DESIGN_FILE" > "$tmp_design" && mv "$tmp_design" "$DESIGN_FILE"
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

    rm -f ".claude/design-review-needed.local.md"
    log_info "Design review state cleaned up."
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
