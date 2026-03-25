#!/bin/bash
# Auto-fix decision engine for design review
# Applies fixes for unanimous high-confidence issues

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/validation.sh"
source "$SCRIPT_DIR/lib/confidence_scoring.sh"
source "$SCRIPT_DIR/lib/state_management.sh"

# Configuration
MAX_AUTO_FIXES=5
CONSENSUS_FILE=$(get_review_file "consensus.json")
AUTOFIX_LOG=$(get_review_file "autofix-log.json")

log_info "Starting auto-fix engine"

# Validate consensus file exists
if ! validate_json_file "$CONSENSUS_FILE"; then
  log_error "Consensus file not found or invalid: $CONSENSUS_FILE"
  exit 1
fi

# Load consensus data
CONSENSUS_JSON=$(cat "$CONSENSUS_FILE")

# Get design file from state
DESIGN_FILE=$(get_design_file)

if ! validate_file_exists "$DESIGN_FILE"; then
  log_error "Design file not found: $DESIGN_FILE"
  exit 1
fi

# Initialize auto-fix log if not exists
if [[ ! -f "$AUTOFIX_LOG" ]]; then
  echo '{"auto_fixes": [], "total_count": 0}' > "$AUTOFIX_LOG"
fi

# Initialize counters
AUTO_FIX_COUNT=0
RECOMMEND_COUNT=0
HUMAN_REVIEW_COUNT=0

# Process unanimous issues
UNANIMOUS_COUNT=$(echo "$CONSENSUS_JSON" | jq '.unanimous | length')
log_info "Processing $UNANIMOUS_COUNT unanimous issues"

for ((i=0; i<UNANIMOUS_COUNT; i++)); do
  ISSUE=$(echo "$CONSENSUS_JSON" | jq -c ".unanimous[$i]")

  # Extract fields
  SECTION=$(echo "$ISSUE" | jq -r '.section')
  SEVERITY=$(echo "$ISSUE" | jq -r '.severity')
  AVG_CONFIDENCE=$(echo "$ISSUE" | jq -r '.avg_confidence')
  MIN_CONFIDENCE=$(echo "$ISSUE" | jq -r '.min_confidence')
  DESCRIPTION=$(echo "$ISSUE" | jq -r '.description')
  SUGGESTION=$(echo "$ISSUE" | jq -r '.suggestion')

  log_info "Evaluating issue #$((i+1)): $SECTION (severity: $SEVERITY, min_conf: $MIN_CONFIDENCE)"

  # Decision tree
  ACTION="HUMAN_REVIEW"  # Default

  # Rule 1: Auto-fix (unanimous + high confidence + high severity)
  if [[ "$SEVERITY" == "high" ]] && awk -v c="$MIN_CONFIDENCE" 'BEGIN { exit !(c >= 0.8) }'; then
    if [[ $AUTO_FIX_COUNT -lt $MAX_AUTO_FIXES ]]; then
      ACTION="AUTO_FIX"
      log_info "  → AUTO-FIX: High confidence ($MIN_CONFIDENCE) + high severity"
    else
      ACTION="RECOMMEND"
      log_warning "  → RECOMMEND: Would auto-fix but reached limit ($MAX_AUTO_FIXES)"
    fi
  # Rule 2: Recommend (unanimous + moderate confidence + high severity)
  elif [[ "$SEVERITY" == "high" ]] && awk -v c="$MIN_CONFIDENCE" 'BEGIN { exit !(c >= 0.7) }'; then
    ACTION="RECOMMEND"
    log_info "  → RECOMMEND: Moderate confidence ($MIN_CONFIDENCE) + high severity"
  # Rule 3: Recommend (unanimous + high confidence + medium severity)
  elif [[ "$SEVERITY" == "medium" ]] && awk -v c="$MIN_CONFIDENCE" 'BEGIN { exit !(c >= 0.75) }'; then
    ACTION="RECOMMEND"
    log_info "  → RECOMMEND: High confidence ($MIN_CONFIDENCE) + medium severity"
  # Default: Human review
  else
    log_info "  → HUMAN_REVIEW: Does not meet auto-fix criteria"
  fi

  # Execute action
  case "$ACTION" in
    AUTO_FIX)
      log_info "  Applying auto-fix to section: $SECTION"

      # Create backup of current design file
      cp "$DESIGN_FILE" "${DESIGN_FILE}.backup.$(date +%s)"

      # Log the auto-fix
      AUTOFIX_ENTRY=$(jq -n \
        --arg section "$SECTION" \
        --arg severity "$SEVERITY" \
        --argjson confidence "$MIN_CONFIDENCE" \
        --arg description "$DESCRIPTION" \
        --arg suggestion "$SUGGESTION" \
        --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --arg design_file "$DESIGN_FILE" \
        '{
          section: $section,
          severity: $severity,
          confidence: $confidence,
          description: $description,
          suggestion: $suggestion,
          timestamp: $timestamp,
          design_file: $design_file,
          status: "applied"
        }')

      # Append to auto-fix log
      CURRENT_LOG=$(cat "$AUTOFIX_LOG")
      echo "$CURRENT_LOG" | jq \
        --argjson entry "$AUTOFIX_ENTRY" \
        '.auto_fixes += [$entry] | .total_count = (.auto_fixes | length)' \
        > "${AUTOFIX_LOG}.tmp"
      mv "${AUTOFIX_LOG}.tmp" "$AUTOFIX_LOG"

      # Apply the fix to the design file
      # Strategy: Add suggestion as a comment/note in the relevant section
      if grep -q "^## $SECTION" "$DESIGN_FILE" || grep -q "^# $SECTION" "$DESIGN_FILE"; then
        # Section found - add fix note after the section header
        log_info "  Applying fix to section: $SECTION"

        # Create temp file with fix inserted
        awk -v section="$SECTION" -v suggestion="$SUGGESTION" '
          /^##? / {
            if ($0 ~ section) {
              print $0
              print ""
              print "**⚠️ AUTO-FIX APPLIED:**"
              print suggestion
              print ""
              in_section = 0
              next
            }
          }
          { print }
        ' "$DESIGN_FILE" > "${DESIGN_FILE}.tmp"

        mv "${DESIGN_FILE}.tmp" "$DESIGN_FILE"
        log_info "  ✓ Auto-fix applied to $SECTION"
      else
        # Section not found - append to end of file
        log_warning "  Section '$SECTION' not found in document"
        log_info "  Appending fix suggestion to end of document"

        cat >> "$DESIGN_FILE" <<EOF

---

## 📝 Auto-Fix Applied: $SECTION

**Issue**: $DESCRIPTION

**Severity**: $SEVERITY (Confidence: $MIN_CONFIDENCE)

**Suggested Fix**:
$SUGGESTION

---
EOF
        log_info "  ✓ Auto-fix appended to end of document"
      fi

      ((AUTO_FIX_COUNT++))
      ;;

    RECOMMEND)
      log_info "  Marked for recommendation to human"
      ((RECOMMEND_COUNT++))
      ;;

    HUMAN_REVIEW)
      log_info "  Marked for human review"
      ((HUMAN_REVIEW_COUNT++))
      ;;
  esac
done

# Update state with auto-fix counts
update_state_field "auto_fixes_applied" "$AUTO_FIX_COUNT"

log_info "Auto-fix engine complete"
log_info "  Auto-fixes applied: $AUTO_FIX_COUNT"
log_info "  Recommendations: $RECOMMEND_COUNT"
log_info "  Human review required: $HUMAN_REVIEW_COUNT"
log_info "  Auto-fix log: $AUTOFIX_LOG"

# Build per-issue action decisions for the decision checklist
# This enables the report generator to show exactly what needs human attention
DECISIONS_FILE=$(get_review_file "decisions.json")

# Collect all decisions into a JSON array
DECISIONS_JSON="[]"

# Re-process unanimous issues to record their action
for ((i=0; i<UNANIMOUS_COUNT; i++)); do
  ISSUE=$(echo "$CONSENSUS_JSON" | jq -c ".unanimous[$i]")
  SECTION=$(echo "$ISSUE" | jq -r '.section')
  SEVERITY=$(echo "$ISSUE" | jq -r '.severity')
  MIN_CONFIDENCE=$(echo "$ISSUE" | jq -r '.min_confidence')
  DESCRIPTION=$(echo "$ISSUE" | jq -r '.description')
  SUGGESTION=$(echo "$ISSUE" | jq -r '.suggestion')

  # Determine action (mirrors decision tree above)
  ACTION="human_review"
  if [[ "$SEVERITY" == "high" ]] && awk -v c="$MIN_CONFIDENCE" 'BEGIN { exit !(c >= 0.8) }'; then
    ACTION="auto_fixed"
  elif [[ "$SEVERITY" == "high" ]] && awk -v c="$MIN_CONFIDENCE" 'BEGIN { exit !(c >= 0.7) }'; then
    ACTION="recommend"
  elif [[ "$SEVERITY" == "medium" ]] && awk -v c="$MIN_CONFIDENCE" 'BEGIN { exit !(c >= 0.75) }'; then
    ACTION="recommend"
  fi

  DECISIONS_JSON=$(echo "$DECISIONS_JSON" | jq \
    --arg section "$SECTION" \
    --arg severity "$SEVERITY" \
    --argjson confidence "$MIN_CONFIDENCE" \
    --arg description "$DESCRIPTION" \
    --arg suggestion "$SUGGESTION" \
    --arg action "$ACTION" \
    --arg consensus "unanimous" \
    '. += [{
      section: $section,
      severity: $severity,
      confidence: ($confidence),
      description: $description,
      suggestion: $suggestion,
      action: $action,
      consensus: $consensus
    }]')
done

# Record majority issues (always need human decision)
MAJORITY_COUNT=$(echo "$CONSENSUS_JSON" | jq '.majority | length')
for ((i=0; i<MAJORITY_COUNT; i++)); do
  ISSUE=$(echo "$CONSENSUS_JSON" | jq -c ".majority[$i]")
  SECTION=$(echo "$ISSUE" | jq -r '.section')
  SEVERITY=$(echo "$ISSUE" | jq -r '.severity')
  AVG_CONFIDENCE=$(echo "$ISSUE" | jq -r '.avg_confidence // .confidence // 0.5')
  DESCRIPTION=$(echo "$ISSUE" | jq -r '.description')
  SUGGESTION=$(echo "$ISSUE" | jq -r '.suggestion')

  DECISIONS_JSON=$(echo "$DECISIONS_JSON" | jq \
    --arg section "$SECTION" \
    --arg severity "$SEVERITY" \
    --argjson confidence "$AVG_CONFIDENCE" \
    --arg description "$DESCRIPTION" \
    --arg suggestion "$SUGGESTION" \
    --arg action "decision_needed" \
    --arg consensus "majority" \
    '. += [{
      section: $section,
      severity: $severity,
      confidence: ($confidence),
      description: $description,
      suggestion: $suggestion,
      action: $action,
      consensus: $consensus
    }]')
done

# Record unique issues (reminders only, non-blocking)
for reviewer in gemini codex claude; do
  UNIQUE_KEY="unique_${reviewer}"
  UNIQUE_COUNT=$(echo "$CONSENSUS_JSON" | jq ".${UNIQUE_KEY} | length")
  for ((i=0; i<UNIQUE_COUNT; i++)); do
    ISSUE=$(echo "$CONSENSUS_JSON" | jq -c ".${UNIQUE_KEY}[$i]")
    SECTION=$(echo "$ISSUE" | jq -r '.section')
    SEVERITY=$(echo "$ISSUE" | jq -r '.severity')
    CONFIDENCE=$(echo "$ISSUE" | jq -r '.confidence // 0.5')
    DESCRIPTION=$(echo "$ISSUE" | jq -r '.description')
    SUGGESTION=$(echo "$ISSUE" | jq -r '.suggestion')

    DECISIONS_JSON=$(echo "$DECISIONS_JSON" | jq \
      --arg section "$SECTION" \
      --arg severity "$SEVERITY" \
      --argjson confidence "$CONFIDENCE" \
      --arg description "$DESCRIPTION" \
      --arg suggestion "$SUGGESTION" \
      --arg action "reminder" \
      --arg consensus "unique" \
      --arg reviewer "$reviewer" \
      '. += [{
        section: $section,
        severity: $severity,
        confidence: ($confidence),
        description: $description,
        suggestion: $suggestion,
        action: $action,
        consensus: $consensus,
        reviewer: $reviewer
      }]')
  done
done

# Write decisions file
echo "$DECISIONS_JSON" | jq '.' > "$DECISIONS_FILE"
log_info "Decision checklist saved to: $DECISIONS_FILE"

# Create summary file for reporting
jq -n \
  --argjson auto_fix_count "$AUTO_FIX_COUNT" \
  --argjson recommend_count "$RECOMMEND_COUNT" \
  --argjson human_review_count "$HUMAN_REVIEW_COUNT" \
  --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  '{
    timestamp: $timestamp,
    auto_fixes_applied: $auto_fix_count,
    recommendations: $recommend_count,
    human_review_required: $human_review_count
  }' > "$(get_review_file "autofix-summary.json")"

log_info "Auto-fix summary saved to: $(get_review_file "autofix-summary.json")"
