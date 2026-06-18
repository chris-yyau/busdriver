#!/bin/bash
# Initialize design review state
# Usage: init-design-review.sh <design_file> [max_iterations]

set -euo pipefail

STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"

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
# check_existing_review return codes: 0=stale (clean up), 1=active (block), 2=no review (skip)
EXISTING=0
check_existing_review || EXISTING=$?
if [[ $EXISTING -eq 2 ]]; then
  # No active review — nothing to clean up, proceed to init
  :
elif [[ $EXISTING -eq 0 ]]; then
  STALE_SLUG=$(cat "$STATE_DIR/current-design-review.local" 2>/dev/null)
  log_info "Cleaning up stale review: $STALE_SLUG (never completed an iteration)"
  cleanup_stale_review
elif [[ $EXISTING -eq 1 ]]; then
  ACTIVE_SLUG=$(cat "$STATE_DIR/current-design-review.local" 2>/dev/null)
  log_error "Active review loop already exists: $ACTIVE_SLUG"
  log_error "  State: docs/reviews/$ACTIVE_SLUG/state.md"
  log_error "  To force: rm $STATE_DIR/current-design-review.local"
  exit 1
fi

# ── Chronic coverage degradation advisory ───────────────────────────
# Reads the cross-review trend (.claude/blueprint-coverage-trend.local, JSONL).
# If the last BLUEPRINT_COVERAGE_MIN_STREAK (default 3) completed reviews were ALL
# degraded (fulfilled_lens_count < 3), surface a loud advisory. NON-blocking
# (state still initializes, exit 0). Informational only — no script gates on it.
# Auto-clears when a later run records FULL coverage, or via BLUEPRINT_ACK_DEGRADED=1.
_chronic_coverage_check() {
  case "${BLUEPRINT_COVERAGE_PROVENANCE:-1}" in 0|false|no|off) return 0 ;; esac
  local trend="$STATE_DIR/blueprint-coverage-trend.local"
  local advisory="$STATE_DIR/blueprint-coverage-degraded.local"
  local streak="${BLUEPRINT_COVERAGE_MIN_STREAK:-3}"
  case "$streak" in ''|*[!0-9]*) streak=3 ;; esac
  [[ -f "$trend" ]] || return 0

  if [[ "${BLUEPRINT_ACK_DEGRADED:-0}" == "1" ]]; then
    rm -f "$advisory"
    return 0
  fi

  # Most recent run FULL → auto-clear any standing advisory.
  local last_count
  last_count=$(tail -n 1 "$trend" | sed -n 's/.*"fulfilled_lens_count":\([0-9]*\).*/\1/p')
  if [[ "$last_count" == "3" ]]; then
    rm -f "$advisory"
    return 0
  fi

  local total
  total=$(grep -c . "$trend" 2>/dev/null || echo 0)
  [[ "$total" -ge "$streak" ]] || return 0

  local degraded=0 c
  while IFS= read -r c; do
    [[ -n "$c" && "$c" -lt 3 ]] && degraded=$((degraded + 1))
  done < <(tail -n "$streak" "$trend" | sed -n 's/.*"fulfilled_lens_count":\([0-9]*\).*/\1/p')

  if [[ "$degraded" -ge "$streak" ]]; then
    log_warning ""
    log_warning "⚠️  CHRONIC COVERAGE DEGRADATION: the last $streak design reviews ran with <3 reviewers."
    log_warning "    A degraded or fallen-back backend has been silently reducing review coverage."
    log_warning "    Fix your reviewer CLIs (check: which agy codex grok), or set BLUEPRINT_ACK_DEGRADED=1 to dismiss."
    log_warning ""
    printf 'chronic coverage degradation: last %s reviews <3 reviewers (init %s)\n' \
      "$streak" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$advisory"
  fi
}
_chronic_coverage_check

# Initialize state file
log_info "Initializing design review state"
STATE_FILE=$(init_state_file "$DESIGN_FILE" "$MAX_ITERATIONS")

log_info "Design review initialized"
log_info "  Design file: $DESIGN_FILE"
log_info "  Max iterations: $MAX_ITERATIONS"
log_info "  State file: $STATE_FILE"
log_info ""
log_info "Ready to start review. Run: bash scripts/run-design-review-loop.sh"
