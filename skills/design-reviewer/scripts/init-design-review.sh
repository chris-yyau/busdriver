#!/bin/bash
# Initialize design review state
# Usage: init-design-review.sh <design_file> [max_iterations]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/validation.sh"
source "$SCRIPT_DIR/lib/state_management.sh"

# Parse arguments
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <design_file> [max_iterations]" >&2
  echo "" >&2
  echo "Arguments:" >&2
  echo "  design_file      Path to the design document to review" >&2
  echo "  max_iterations   Maximum review iterations (default: 5)" >&2
  exit 1
fi

DESIGN_FILE="$1"
MAX_ITERATIONS="${2:-5}"

# Validate design file exists
log_info "Validating design file: $DESIGN_FILE"
if ! validate_file_exists "$DESIGN_FILE"; then
  log_error "Design file not found or not readable"
  exit 1
fi

if ! validate_file_not_empty "$DESIGN_FILE"; then
  log_error "Design file is empty"
  exit 1
fi

# Check for existing active review
# check_existing_review uses return codes 0/1/2 as state, not error indicators
check_existing_review || EXISTING=$?
EXISTING=${EXISTING:-0}
if [[ $EXISTING -eq 0 ]]; then
  STALE_SLUG=$(cat ".claude/current-design-review.local" 2>/dev/null)
  log_info "Cleaning up stale review: $STALE_SLUG (never completed an iteration)"
  cleanup_stale_review
elif [[ $EXISTING -eq 1 ]]; then
  ACTIVE_SLUG=$(cat ".claude/current-design-review.local" 2>/dev/null)
  log_error "Active review loop already exists: $ACTIVE_SLUG"
  log_error "  State: docs/reviews/$ACTIVE_SLUG/state.md"
  log_error "  To force: rm .claude/current-design-review.local"
  exit 1
fi

# Initialize state file
log_info "Initializing design review state"
STATE_FILE=$(init_state_file "$DESIGN_FILE" "$MAX_ITERATIONS")

log_info "Design review initialized"
log_info "  Design file: $DESIGN_FILE"
log_info "  Max iterations: $MAX_ITERATIONS"
log_info "  State file: $STATE_FILE"
log_info ""
log_info "Ready to start review. Run: bash scripts/run-design-review-loop.sh"
