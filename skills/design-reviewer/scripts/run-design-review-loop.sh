#!/bin/bash
# Main three-tier consensus review workflow orchestration
# Runs Gemini + Codex + Claude → Consensus → Auto-fix → Human review loop

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/validation.sh"
source "$SCRIPT_DIR/lib/state_management.sh"

# Ensure output directory exists (namespaced per design doc)
REVIEW_DIR=$(get_review_dir)
mkdir -p "$REVIEW_DIR"

# Cross-platform millisecond timestamp
# macOS BSD date doesn't support %N — falls back through gdate → python3 → seconds
millis() {
  if command -v gdate &>/dev/null; then
    gdate +%s%3N
  elif command -v python3 &>/dev/null; then
    python3 -c "import time; print(int(time.time()*1000))"
  else
    echo "$(date +%s)000"
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
      # REMOVED: --skip-claude defeats three-tier consensus.
      # If Claude validation is skipped, the gate fabricates a placeholder PASS
      # using Gemini's status, violating the "all three reviewers must PASS" principle.
      # See: Sprint 1 audit finding C4 (2026-03-19)
      log_error "--skip-claude flag has been removed (violates three-tier consensus)."
      log_error "All three reviewers (Gemini + Codex + Claude) must participate."
      exit 1
      ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --auto          Enable auto-iteration mode (iterate until convergence)"
      echo "  --help          Show this help message"
      echo ""
      echo "Examples:"
      echo "  $0                    # Interactive mode (manual validation)"
      echo "  $0 --auto            # Auto-iterate until convergence"
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      echo "Run with --help for usage information"
      exit 1
      ;;
  esac
done

log_info "=== Design Review Three-Tier Consensus System ==="
if [[ "$AUTO_MODE" == "true" ]]; then
  log_info "Mode: AUTO-ITERATION (will iterate until convergence)"
else
  log_info "Mode: INTERACTIVE (manual approval between iterations)"
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

# Validate CLIs are available
log_info "Checking for required CLIs..."
GEMINI_AVAILABLE=false
CODEX_AVAILABLE=false

if validate_cli_available "gemini"; then
  GEMINI_AVAILABLE=true
  log_info "  ✓ Gemini CLI found"
else
  log_warning "  ✗ Gemini CLI not found (will use fallback)"
fi

if validate_cli_available "codex"; then
  CODEX_AVAILABLE=true
  log_info "  ✓ Codex CLI found"
else
  log_warning "  ✗ Codex CLI not found (will use fallback)"
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
    log_info "Design review did not fully converge. Human intervention required."
    log_info "The pre-commit gate will remain blocked until the design is reviewed."
    log_info "Options: fix issues and re-run, or create .claude/skip-review.local in terminal."
    mark_review_complete "FAIL"
    exit 1
  fi

  # Phase 1: Launch Gemini review
  log_info "Phase 1: Launching Gemini review..."

  GEMINI_OUTPUT_FILE=$(get_review_file "gemini.json")

  if [[ "$GEMINI_AVAILABLE" == "true" ]]; then
    # Read comprehensive prompt
    PROMPT=$(cat "$SCRIPT_DIR/../prompts/comprehensive_review_prompt.txt")

    # Read design file content
    DESIGN_CONTENT=$(cat "$DESIGN_FILE")

    # Construct full prompt
    FULL_PROMPT="$PROMPT

Document to review:
---
$DESIGN_CONTENT
---"

    # Call Gemini CLI in non-interactive mode
    log_info "  ⏳ Running Gemini review (est. 30-60s)..."
    GEMINI_START=$(millis)

    GEMINI_RAW_FILE=$(get_review_file "gemini-raw.txt")

    if echo "$FULL_PROMPT" | gemini > "$GEMINI_RAW_FILE" 2>&1; then
      GEMINI_END=$(millis)
      GEMINI_DURATION=$((GEMINI_END - GEMINI_START))

      # Extract review JSON from Gemini output (may contain non-JSON preamble/thinking/code)
      if python3 "$SCRIPT_DIR/lib/extract_review_json.py" "$GEMINI_RAW_FILE" > "$GEMINI_OUTPUT_FILE"; then
        log_info "  ✓ Gemini completed in ${GEMINI_DURATION}ms (JSON extracted)"
      else
        log_error "  ✗ Gemini output was not valid JSON"
        create_error_json "gemini" "Output was not valid JSON" > "$GEMINI_OUTPUT_FILE"
      fi
    else
      log_error "  ✗ Gemini CLI failed"
      create_error_json "gemini" "CLI execution failed" > "$GEMINI_OUTPUT_FILE"
    fi
  else
    log_warning "  Gemini CLI not available - skipping"
    create_error_json "gemini" "CLI not available" > "$GEMINI_OUTPUT_FILE"
  fi

  # Phase 2: Launch Codex review
  log_info "Phase 2: Launching Codex review..."

  CODEX_OUTPUT_FILE=$(get_review_file "codex.json")

  if [[ "$CODEX_AVAILABLE" == "true" ]]; then
    log_info "  ⏳ Running Codex review (est. 2-5min)..."
    CODEX_START=$(millis)

    # Call Codex CLI exec mode — pipe prompt via stdin to avoid ARG_MAX limits
    CODEX_RAW_FILE=$(get_review_file "codex-raw.txt")

    if echo "$FULL_PROMPT" | codex exec - > "$CODEX_RAW_FILE" 2>&1; then
      CODEX_END=$(millis)
      CODEX_DURATION=$((CODEX_END - CODEX_START))

      # Extract review JSON from Codex output (may contain interleaved exec outputs with code)
      if python3 "$SCRIPT_DIR/lib/extract_review_json.py" "$CODEX_RAW_FILE" > "$CODEX_OUTPUT_FILE"; then
        log_info "  ✓ Codex completed in ${CODEX_DURATION}ms (JSON extracted)"
      else
        log_error "  ✗ Codex output was not valid JSON"
        create_error_json "codex" "Output was not valid JSON" > "$CODEX_OUTPUT_FILE"
      fi
    else
      log_error "  ✗ Codex CLI failed"
      create_error_json "codex" "CLI execution failed" > "$CODEX_OUTPUT_FILE"
    fi
  else
    log_warning "  Codex CLI not available - skipping"
    create_error_json "codex" "CLI not available" > "$CODEX_OUTPUT_FILE"
  fi

  # Phase 3: Both reviews complete (sequential execution)
  log_info "Phase 3: Reviews collected. Proceeding to validation..."

  # Validate outputs
  log_info "Phase 4: Validating review outputs..."

  if ! validate_json_file "$GEMINI_OUTPUT_FILE"; then
    log_error "Gemini output invalid"
    exit 1
  fi

  if ! validate_json_file "$CODEX_OUTPUT_FILE"; then
    log_error "Codex output invalid"
    exit 1
  fi

  # Extract statuses
  GEMINI_STATUS=$(jq -r '.status' "$GEMINI_OUTPUT_FILE")
  CODEX_STATUS=$(jq -r '.status' "$CODEX_OUTPUT_FILE")

  log_info "  Gemini status: $GEMINI_STATUS"
  log_info "  Codex status: $CODEX_STATUS"

  # Phase 5: Claude validation review
  log_info "Phase 5: Running Claude validation review..."

  CLAUDE_OUTPUT_FILE=$(get_review_file "claude.json")
  CLAUDE_PROMPT_FILE=$(get_review_file "claude-validation-prompt.txt")

  log_info "  ⏳ Preparing Claude validation with codebase context..."

  CLAUDE_START=$(millis)

  # Read Claude validation prompt
  CLAUDE_PROMPT=$(cat "$SCRIPT_DIR/../prompts/claude_validation_prompt.txt")

  # Extract issue summaries from Gemini and Codex for validation
  GEMINI_ISSUES=$(jq -r '.issues[] | "- [\(.severity)] \(.section): \(.description)"' "$GEMINI_OUTPUT_FILE" 2>/dev/null || echo "No issues")
  CODEX_ISSUES=$(jq -r '.issues[] | "- [\(.severity)] \(.section): \(.description)"' "$CODEX_OUTPUT_FILE" 2>/dev/null || echo "No issues")

  # Create comprehensive validation prompt file
  cat > "$CLAUDE_PROMPT_FILE" <<EOF
$CLAUDE_PROMPT

=============================================================================
DESIGN DOCUMENT TO VALIDATE:
=============================================================================

$DESIGN_CONTENT

=============================================================================
GEMINI REVIEW RESULTS (Status: $GEMINI_STATUS):
=============================================================================

Summary of Gemini Issues:
$GEMINI_ISSUES

Full Gemini Output:
$(cat "$GEMINI_OUTPUT_FILE")

=============================================================================
CODEX REVIEW RESULTS (Status: $CODEX_STATUS):
=============================================================================

Summary of Codex Issues:
$CODEX_ISSUES

Full Codex Output:
$(cat "$CODEX_OUTPUT_FILE")

=============================================================================
VALIDATION TASK:
=============================================================================

1. Read the design document and both reviews
2. For each issue flagged by Gemini or Codex:
   - Validate against the codebase (read relevant files)
   - Determine if the concern is valid
   - Assign validation_type: confirms_gemini, confirms_codex, contradicts_gemini, contradicts_codex
3. Search for issues they missed:
   - Check for missing error handling
   - Verify API contracts match existing code
   - Check for architectural inconsistencies
   - Look for performance concerns
   - Validate security considerations
   - Mark these as validation_type: new_finding
4. Output strict JSON matching the schema above

IMPORTANT: Use Read, Grep, Glob tools to examine the codebase. Cite specific files and line numbers.
EOF

  log_info "  📝 Validation prompt created: $CLAUDE_PROMPT_FILE"
  log_info ""
  log_info "  ⚠️  MANUAL STEP REQUIRED ⚠️"
  log_info "  Claude validation needs codebase context access."
  log_info ""
  log_info "  To complete validation, run this in Claude Code:"
  log_info "  ┌─────────────────────────────────────────────────────────┐"
  log_info "  │ cat $CLAUDE_PROMPT_FILE                                 │"
  log_info "  │                                                          │"
  log_info "  │ Then paste the output into Claude Code and ask:         │"
  log_info "  │ \"Perform the validation and write output to             │"
  log_info "  │  $CLAUDE_OUTPUT_FILE\"                                   │"
  log_info "  └─────────────────────────────────────────────────────────┘"
  log_info ""
  log_info "  Press ENTER when validation is complete..."

  # Check if we're in automated mode
  if [[ "$AUTO_MODE" == "true" ]]; then
    log_warning "  Auto mode: Claude validation must be completed by the calling skill."
    log_info "  Checking for pre-existing Claude validation output..."
    # In auto mode, the design-reviewer SKILL.md should invoke Claude validation
    # via Agent tool BEFORE running this script. If the output doesn't exist,
    # we FAIL the iteration — we do NOT fabricate a placeholder PASS.
    # See: Sprint 1 audit finding C4 (2026-03-19)
  else
    # Wait for user to complete manual validation
    read -r
  fi

  # Check if validation output exists
  if [[ ! -f "$CLAUDE_OUTPUT_FILE" ]]; then
    # FAIL-CLOSED: Do NOT create placeholder output that mirrors Gemini's status.
    # Fabricating a PASS violates three-tier consensus ("all three reviewers must PASS").
    # The calling skill must ensure Claude validation runs before this script.
    log_error "  Claude validation output not found: $CLAUDE_OUTPUT_FILE"
    log_error "  Three-tier consensus requires all three reviewers (Gemini + Codex + Claude)."
    log_error "  Run Claude validation first, or use interactive mode (without --auto)."
    log_info ""
    log_info "  To complete validation manually:"
    log_info "  1. Read the prompt: cat $CLAUDE_PROMPT_FILE"
    log_info "  2. Run validation and save output to: $CLAUDE_OUTPUT_FILE"
    log_info "  3. Re-run this script"
    mark_review_complete "FAIL"
    exit 1
  fi

  CLAUDE_END=$(millis)
  CLAUDE_DURATION=$((CLAUDE_END - CLAUDE_START))

  CLAUDE_STATUS=$(jq -r '.status' "$CLAUDE_OUTPUT_FILE")
  log_info "  ✓ Claude validation completed in ${CLAUDE_DURATION}ms (status: $CLAUDE_STATUS)"

  # Update review statuses in state
  update_review_statuses "$GEMINI_STATUS" "$CODEX_STATUS" "$CLAUDE_STATUS"

  # Phase 6: Consensus detection
  log_info "Phase 6: Analyzing consensus..."
  bash "$SCRIPT_DIR/consensus_analyzer.sh"

  if [[ $? -ne 0 ]]; then
    log_error "Consensus analysis failed"
    exit 1
  fi

  # Phase 7: Auto-fix engine
  log_info "Phase 7: Running auto-fix engine..."
  bash "$SCRIPT_DIR/auto_fix_engine.sh"

  if [[ $? -ne 0 ]]; then
    log_error "Auto-fix engine failed"
    exit 1
  fi

  # Phase 8: Generate consensus report
  log_info "Phase 8: Generating consensus report..."

  # Generate JSON report (already exists from consensus analyzer)
  CONSENSUS_REPORT=$(get_review_file "consensus.json")
  log_info "  JSON report: $CONSENSUS_REPORT"

  # Generate human-readable colorized report
  REPORT_FILE=$(get_review_file "report.txt")
  if bash "$SCRIPT_DIR/generate_report.sh" > "$REPORT_FILE" 2>&1; then
    log_info "  ✓ Colorized report generated: $REPORT_FILE"
    log_info ""
    log_info "  To view the formatted report, run:"
    log_info "  cat $REPORT_FILE"
  else
    log_warning "  Report generation failed, JSON still available"
  fi

  # Phase 9: Check convergence
  log_info "Phase 9: Checking convergence..."

  if check_convergence; then
    log_info ""
    log_info "✓ ✓ ✓ All reviewers PASS! ✓ ✓ ✓"
    log_info ""

    # Insert gate marker into design document so pre-commit gate allows commits.
    # Without this marker, the pre-commit hook permanently blocks all commits.
    if [[ -f "$DESIGN_FILE" ]]; then
      if ! grep -q "<!-- design-reviewed: PASS -->" "$DESIGN_FILE" 2>/dev/null; then
        if printf '\n<!-- design-reviewed: PASS -->\n' >> "$DESIGN_FILE"; then
          log_info "Gate marker written to: $DESIGN_FILE"
        else
          log_error "FAILED to write gate marker to: $DESIGN_FILE"
          log_error "Check file permissions and disk space. Pre-commit gate will remain blocked."
          mark_review_complete "FAIL"
          exit 1
        fi
      fi
    else
      log_error "Design file not found: $DESIGN_FILE — cannot write gate marker."
      mark_review_complete "FAIL"
      exit 1
    fi

    # Clean up the design-review-needed state file since all reviews passed.
    # This unblocks the pre-implementation gate (Write/Edit hook).
    rm -f ".claude/design-review-needed.local.md"
    log_info "Design review state cleaned up."

    log_info "Design approved and ready for implementation."
    mark_review_complete "PASS"
    exit 0
  fi

  # Phase 10: Human decisions required
  log_info "Phase 10: Iteration complete"
  log_info ""

  if [[ "$AUTO_MODE" == "true" ]]; then
    # Auto-iteration mode: continue automatically
    log_info "Auto mode: Preparing next iteration..."
    log_info ""
    log_info "Issues remaining - will iterate again (iteration $((CURRENT_ITERATION + 1)))"
    log_info "View current report: cat $(get_review_file "report.txt")"
    log_info ""

    # Increment iteration counter
    increment_iteration

    # Brief pause before next iteration
    sleep 2

    # Continue to next iteration
    continue
  else
    # Interactive mode: pause for human review
    log_info "Review the consensus report and make decisions on pending issues:"
    log_info "  cat $(get_review_file "report.txt")"
    log_info "  cat $(get_review_file "consensus.json")"
    log_info ""
    log_info "To continue with next iteration, run this script again after addressing issues."

    # Increment iteration counter
    increment_iteration

    log_info ""
    log_info "Pausing for human review. Update design file and re-run to continue."
    break
  fi
done

log_info ""
log_info "Design review loop exited. Check state file for current status:"
log_info "  cat $STATE_FILE"
