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
source "$SCRIPT_DIR/lib/state_management.sh"

# Ensure output directory exists (namespaced per design doc)
REVIEW_DIR=$(get_review_dir)
mkdir -p "$REVIEW_DIR"

# Cross-platform millisecond timestamp
millis() {
  if command -v gdate &>/dev/null; then
    gdate +%s%3N
  elif command -v python3 &>/dev/null; then
    python3 -c "import time; print(int(time.time()*1000))"
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
compute_spec_hash() {
  local file="$1"
  if command -v shasum &>/dev/null; then
    shasum -a 256 "$file" | cut -d' ' -f1
  elif command -v sha256sum &>/dev/null; then
    sha256sum "$file" | cut -d' ' -f1
  elif command -v python3 &>/dev/null; then
    python3 -c "import hashlib; print(hashlib.sha256(open('$file','rb').read()).hexdigest())"
  else
    echo "no-hash-tool"
  fi
}

# Parse command line arguments
AUTO_MODE=false
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
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --auto          Auto-iteration mode (iterate until Claude verdict is PASS)"
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

# Generate run ID for this execution (Critic #1: run-scoped isolation)
RUN_ID=$(generate_run_id)
log_info "Run ID: $RUN_ID"

# Compute spec hash for freshness contract (Critic #2)
SPEC_HASH=$(compute_spec_hash "$DESIGN_FILE")
log_info "Spec hash: ${SPEC_HASH:0:12}..."

# Validate CLIs are available
log_info "Checking for required CLIs..."
GEMINI_AVAILABLE=false
CODEX_AVAILABLE=false

if validate_cli_available "gemini"; then
  GEMINI_AVAILABLE=true
  log_info "  + Gemini CLI found"
else
  log_warning "  - Gemini CLI not found (will use fallback)"
fi

if validate_cli_available "codex"; then
  CODEX_AVAILABLE=true
  log_info "  + Codex CLI found"
else
  log_warning "  - Codex CLI not found (will use fallback)"
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

  # ── Critic #1: Clean stale outputs from previous iteration ────────
  log_info "Cleaning stale artifacts..."
  rm -f "$(get_review_file "gemini.json")" \
        "$(get_review_file "gemini-raw.txt")" \
        "$(get_review_file "gemini.json.pending")" \
        "$(get_review_file "codex.json")" \
        "$(get_review_file "codex-raw.txt")" \
        "$(get_review_file "codex.json.pending")" \
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

      if echo "$FULL_PROMPT" | gemini > "$GEMINI_RAW_FILE" 2>&1; then
        GEMINI_END=$(millis)
        GEMINI_DURATION=$((GEMINI_END - GEMINI_START))

        if python3 "$SCRIPT_DIR/lib/extract_review_json.py" "$GEMINI_RAW_FILE" > "${GEMINI_OUTPUT_FILE}.pending" 2>/dev/null; then
          # Inject freshness metadata (Critic #2)
          python3 -c "
import json
with open('${GEMINI_OUTPUT_FILE}.pending') as f:
    data = json.load(f)
data.setdefault('metadata', {})
data['metadata']['run_id'] = '$RUN_ID'
data['metadata']['iteration'] = $CURRENT_ITERATION
data['metadata']['spec_hash'] = '$SPEC_HASH'
data['metadata']['review_duration_ms'] = $GEMINI_DURATION
with open('${GEMINI_OUTPUT_FILE}.pending', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null
          mv "${GEMINI_OUTPUT_FILE}.pending" "$GEMINI_OUTPUT_FILE"
        else
          create_error_json "gemini" "Output was not valid JSON" > "$GEMINI_OUTPUT_FILE"
        fi
      else
        create_error_json "gemini" "CLI execution failed" > "$GEMINI_OUTPUT_FILE"
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

      if echo "$FULL_PROMPT" | codex exec - > "$CODEX_RAW_FILE" 2>&1; then
        CODEX_END=$(millis)
        CODEX_DURATION=$((CODEX_END - CODEX_START))

        if python3 "$SCRIPT_DIR/lib/extract_review_json.py" "$CODEX_RAW_FILE" > "${CODEX_OUTPUT_FILE}.pending" 2>/dev/null; then
          # Inject freshness metadata (Critic #2)
          python3 -c "
import json
with open('${CODEX_OUTPUT_FILE}.pending') as f:
    data = json.load(f)
data.setdefault('metadata', {})
data['metadata']['run_id'] = '$RUN_ID'
data['metadata']['iteration'] = $CURRENT_ITERATION
data['metadata']['spec_hash'] = '$SPEC_HASH'
data['metadata']['review_duration_ms'] = $CODEX_DURATION
with open('${CODEX_OUTPUT_FILE}.pending', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null
          mv "${CODEX_OUTPUT_FILE}.pending" "$CODEX_OUTPUT_FILE"
        else
          create_error_json "codex" "Output was not valid JSON" > "$CODEX_OUTPUT_FILE"
        fi
      else
        create_error_json "codex" "CLI execution failed" > "$CODEX_OUTPUT_FILE"
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

  # Freshness check (Critic #2): fail-closed — require run_id match
  for review_file in "$GEMINI_OUTPUT_FILE" "$CODEX_OUTPUT_FILE"; do
    FILE_RUN_ID=$(jq -r '.metadata.run_id // ""' "$review_file" 2>/dev/null || echo "")
    REVIEWER=$(jq -r '.reviewer_id // "unknown"' "$review_file" 2>/dev/null || echo "unknown")
    if [[ -z "$FILE_RUN_ID" ]]; then
      log_error "MISSING run_id in $review_file — fail-closed (freshness contract)"
      create_error_json "$REVIEWER" "Missing run_id metadata (freshness contract violation)" > "$review_file"
    elif [[ "$FILE_RUN_ID" != "$RUN_ID" ]]; then
      log_error "STALE OUTPUT: $review_file has run_id=$FILE_RUN_ID, expected $RUN_ID"
      create_error_json "$REVIEWER" "Stale output from previous run" > "$review_file"
    fi
  done

  GEMINI_STATUS=$(jq -r '.status' "$GEMINI_OUTPUT_FILE")
  CODEX_STATUS=$(jq -r '.status' "$CODEX_OUTPUT_FILE")

  log_info "  Gemini: $GEMINI_STATUS ($(jq '.issues | length' "$GEMINI_OUTPUT_FILE") issues)"
  log_info "  Codex:  $CODEX_STATUS ($(jq '.issues | length' "$CODEX_OUTPUT_FILE") issues)"

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
    log_info "  3. Re-run this script"
    mark_review_complete "awaiting_claude_validation"
    exit 1
  fi

  # Freshness check on Claude output (Critic #2)
  CLAUDE_RUN_ID=$(jq -r '.metadata.run_id // ""' "$CLAUDE_OUTPUT_FILE" 2>/dev/null || echo "")
  if [[ -n "$CLAUDE_RUN_ID" && "$CLAUDE_RUN_ID" != "$RUN_ID" ]]; then
    log_error "STALE CLAUDE OUTPUT: run_id=$CLAUDE_RUN_ID, expected $RUN_ID"
    log_error "Re-run Claude validation against current Gemini/Codex outputs."
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

  update_review_statuses "$GEMINI_STATUS" "$CODEX_STATUS" "$CLAUDE_STATUS"

  # ── Phase 4: Progress analysis (Critic #5) ────────────────────────
  log_info "Phase 4: Progress analysis..."

  HIGH_COUNT=$(jq '[.issues[] | select(.severity == "high" and .confidence >= 0.5)] | length' "$CLAUDE_OUTPUT_FILE" 2>/dev/null || echo 0)
  MEDIUM_COUNT=$(jq '[.issues[] | select(.severity == "medium" and .confidence >= 0.5)] | length' "$CLAUDE_OUTPUT_FILE" 2>/dev/null || echo 0)
  LOW_COUNT=$(jq '[.issues[] | select(.severity == "low")] | length' "$CLAUDE_OUTPUT_FILE" 2>/dev/null || echo 0)

  if [[ "$HIGH_COUNT" -gt 0 ]]; then
    PROGRESS_STATUS="blocked_by_high_issues"
  elif [[ "$MEDIUM_COUNT" -gt 0 ]]; then
    PROGRESS_STATUS="medium_issues_remaining"
  elif [[ "$LOW_COUNT" -gt 0 ]]; then
    PROGRESS_STATUS="low_issues_only"
  else
    PROGRESS_STATUS="passed"
  fi

  update_state_field "progress_status" "\"$PROGRESS_STATUS\""
  update_state_field "high_issues" "$HIGH_COUNT"
  update_state_field "medium_issues" "$MEDIUM_COUNT"
  update_state_field "low_issues" "$LOW_COUNT"

  log_info "  Status: $PROGRESS_STATUS"
  log_info "  Issues: $HIGH_COUNT high, $MEDIUM_COUNT medium, $LOW_COUNT low"

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
