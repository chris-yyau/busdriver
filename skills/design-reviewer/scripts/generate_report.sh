#!/bin/bash
# Generate human-readable colorized report from consensus + decisions JSON
# Productized output: Human sees a decision checklist, not three raw reports

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/validation.sh"
source "$SCRIPT_DIR/lib/state_management.sh"

# ANSI color codes
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
GRAY='\033[0;90m'
WHITE='\033[1;37m'
RESET='\033[0m'

# Box drawing characters
BOX_H="─"
BOX_V="│"
BOX_TL="┌"
BOX_TR="┐"
BOX_BL="└"
BOX_BR="┘"

CONSENSUS_FILE="${1:-$(get_review_file "consensus.json")}"
DECISIONS_FILE=$(get_review_file "decisions.json")

if ! validate_json_file "$CONSENSUS_FILE"; then
  echo -e "${RED}Error: Consensus file not found or invalid: $CONSENSUS_FILE${RESET}"
  exit 1
fi

# Helper functions
print_header() {
  local title="$1"
  local width=80
  local title_len=${#title}
  local padding=$(( (width - title_len - 2) / 2 ))

  echo ""
  echo -e "${BOLD}${CYAN}${BOX_TL}$(printf '%*s' $width | tr ' ' "$BOX_H")${BOX_TR}${RESET}"
  printf "${BOLD}${CYAN}${BOX_V}${RESET}"
  printf "%*s" $padding ""
  printf "${BOLD}${CYAN}%s${RESET}" "$title"
  printf "%*s" $(( width - title_len - padding )) ""
  printf "${BOLD}${CYAN}${BOX_V}${RESET}\n"
  echo -e "${BOLD}${CYAN}${BOX_BL}$(printf '%*s' $width | tr ' ' "$BOX_H")${BOX_BR}${RESET}"
  echo ""
}

print_section() {
  local title="$1"
  echo -e "${BOLD}${BLUE}$title${RESET}"
  echo -e "${GRAY}$(printf '%.0s─' {1..80})${RESET}"
}

print_checklist_item() {
  local icon="$1"
  local section="$2"
  local severity="$3"
  local confidence="$4"
  local description="$5"
  local suggestion="$6"
  local extra="${7:-}"

  # Color code by severity
  local sev_color=""
  case "$severity" in
    high)   sev_color="${RED}" ;;
    medium) sev_color="${YELLOW}" ;;
    low)    sev_color="${GREEN}" ;;
  esac

  echo -e "  ${icon} ${BOLD}${section}${RESET}"
  echo -e "    ${sev_color}[${severity^^}]${RESET} ${DIM}conf: ${confidence}${RESET}${extra:+  ${GRAY}${extra}${RESET}}"
  echo -e "    ${description}"
  echo -e "    ${GREEN}>${RESET} ${suggestion}"
  echo ""
}

print_stats() {
  local label="$1"
  local value="$2"
  local color="${3:-$RESET}"
  printf "  ${BOLD}%-30s${RESET} ${color}%s${RESET}\n" "$label:" "$value"
}

# Read consensus data
CONSENSUS_JSON=$(cat "$CONSENSUS_FILE")

# Extract summary stats
UNANIMOUS_COUNT=$(echo "$CONSENSUS_JSON" | jq '.unanimous | length')
MAJORITY_COUNT=$(echo "$CONSENSUS_JSON" | jq '.majority | length')
UNIQUE_GEMINI=$(echo "$CONSENSUS_JSON" | jq '.unique_gemini | length')
UNIQUE_CODEX=$(echo "$CONSENSUS_JSON" | jq '.unique_codex | length')
UNIQUE_CLAUDE=$(echo "$CONSENSUS_JSON" | jq '.unique_claude | length')
TOTAL_ISSUES=$(echo "$CONSENSUS_JSON" | jq '.summary.total_issues // 0')

# Auto-fix stats
AUTOFIX_SUMMARY=$(get_review_file "autofix-summary.json")
AUTO_FIXES=0
RECOMMEND_TOTAL=0
HUMAN_REVIEW_TOTAL=0
if [[ -f "$AUTOFIX_SUMMARY" ]]; then
  AUTO_FIXES=$(jq -r '.auto_fixes_applied // 0' "$AUTOFIX_SUMMARY")
  RECOMMEND_TOTAL=$(jq -r '.recommendations // 0' "$AUTOFIX_SUMMARY")
  HUMAN_REVIEW_TOTAL=$(jq -r '.human_review_required // 0' "$AUTOFIX_SUMMARY")
fi

clear

# ============================================================
# DECISION CHECKLIST (the productized output)
# ============================================================

if [[ -f "$DECISIONS_FILE" ]] && validate_json_file "$DECISIONS_FILE"; then
  DECISIONS_JSON=$(cat "$DECISIONS_FILE")
  DECISION_COUNT=$(echo "$DECISIONS_JSON" | jq 'length')

  # Count by action type
  AUTO_FIXED_COUNT=$(echo "$DECISIONS_JSON" | jq '[.[] | select(.action == "auto_fixed")] | length')
  DECISION_NEEDED_COUNT=$(echo "$DECISIONS_JSON" | jq '[.[] | select(.action == "decision_needed" or .action == "recommend")] | length')
  REMINDER_COUNT=$(echo "$DECISIONS_JSON" | jq '[.[] | select(.action == "reminder")] | length')

  print_header "HUMAN DECISION CHECKLIST"

  # Quick summary bar
  echo -e "  ${GREEN}${AUTO_FIXED_COUNT} auto-handled${RESET}  ${YELLOW}${DECISION_NEEDED_COUNT} need your call${RESET}  ${GRAY}${REMINDER_COUNT} FYI${RESET}  ${DIM}(${TOTAL_ISSUES} total)${RESET}"
  echo ""

  # ── Section 1: Auto-handled (just FYI) ──
  if [[ $AUTO_FIXED_COUNT -gt 0 ]]; then
    print_section "  AUTO-HANDLED (unanimous + high confidence)"
    echo -e "  ${DIM}These were auto-fixed. No action needed unless you disagree.${RESET}"
    echo ""

    echo "$DECISIONS_JSON" | jq -c '.[] | select(.action == "auto_fixed")' | while IFS= read -r item; do
      section=$(echo "$item" | jq -r '.section')
      severity=$(echo "$item" | jq -r '.severity')
      confidence=$(echo "$item" | jq -r '.confidence')
      description=$(echo "$item" | jq -r '.description')
      suggestion=$(echo "$item" | jq -r '.suggestion')

      print_checklist_item "${GREEN}[done]${RESET}" "$section" "$severity" "$confidence" "$description" "$suggestion"
    done
  fi

  # ── Section 2: Decisions needed (majority or recommended) ──
  if [[ $DECISION_NEEDED_COUNT -gt 0 ]]; then
    print_section "  DECISIONS NEEDED (2/3 agree or recommended)"
    echo -e "  ${BOLD}${YELLOW}You need to decide on these. Usually a trade-off or scope call.${RESET}"
    echo ""

    echo "$DECISIONS_JSON" | jq -c '.[] | select(.action == "decision_needed" or .action == "recommend")' | while IFS= read -r item; do
      section=$(echo "$item" | jq -r '.section')
      severity=$(echo "$item" | jq -r '.severity')
      confidence=$(echo "$item" | jq -r '.confidence')
      description=$(echo "$item" | jq -r '.description')
      suggestion=$(echo "$item" | jq -r '.suggestion')
      consensus=$(echo "$item" | jq -r '.consensus')

      # Show consensus context
      extra=""
      if [[ "$consensus" == "unanimous" ]]; then
        extra="3/3 agree (below auto-fix threshold)"
      else
        extra="2/3 agree"
      fi

      print_checklist_item "${YELLOW}[ ? ]${RESET}" "$section" "$severity" "$confidence" "$description" "$suggestion" "$extra"
    done
  fi

  # ── Section 3: Reminders (unique, non-blocking) ──
  if [[ $REMINDER_COUNT -gt 0 ]]; then
    print_section "  REMINDERS (1/3 flagged, non-blocking)"
    echo -e "  ${DIM}Only one reviewer flagged these. Awareness only, won't block approval.${RESET}"
    echo ""

    echo "$DECISIONS_JSON" | jq -c '.[] | select(.action == "reminder")' | while IFS= read -r item; do
      section=$(echo "$item" | jq -r '.section')
      severity=$(echo "$item" | jq -r '.severity')
      confidence=$(echo "$item" | jq -r '.confidence')
      description=$(echo "$item" | jq -r '.description')
      suggestion=$(echo "$item" | jq -r '.suggestion')
      reviewer=$(echo "$item" | jq -r '.reviewer // "unknown"')

      print_checklist_item "${GRAY}[fyi]${RESET}" "$section" "$severity" "$confidence" "$description" "$suggestion" "flagged by: ${reviewer}"
    done
  fi

  # ── No decisions needed ──
  if [[ $DECISION_NEEDED_COUNT -eq 0 && $TOTAL_ISSUES -gt 0 ]]; then
    echo -e "  ${BOLD}${GREEN}No decisions needed!${RESET} All issues were either auto-fixed or are non-blocking reminders."
    echo ""
  fi
else
  # Fallback: no decisions file, use legacy report format
  print_header "DESIGN REVIEW CONSENSUS REPORT"
  echo -e "  ${YELLOW}Note: Decision checklist unavailable (run auto-fix engine first)${RESET}"
  echo -e "  ${GRAY}Falling back to detailed view below.${RESET}"
  echo ""
fi

# ============================================================
# DETAILED FINDINGS (reference section)
# ============================================================

print_header "DETAILED FINDINGS"

# Overall Status
print_section "  OVERALL STATUS"
CONSENSUS_RATE=$(echo "$CONSENSUS_JSON" | jq -r '.consensus_rate // 0')
consensus_pct=$(echo "$CONSENSUS_RATE * 100" | bc | cut -d. -f1)
if [ $TOTAL_ISSUES -eq 0 ]; then
  echo -e "  ${BOLD}${GREEN}ALL REVIEWERS PASSED${RESET}"
  echo -e "  ${GRAY}No issues found by any reviewer${RESET}"
else
  echo -e "  ${BOLD}Total Issues:${RESET} $TOTAL_ISSUES  ${BOLD}Consensus Rate:${RESET} ${CYAN}${consensus_pct}%${RESET}  ${BOLD}Auto-fixes:${RESET} ${GREEN}${AUTO_FIXES}${RESET}"
fi
echo ""

# Issue Distribution
print_section "  ISSUE DISTRIBUTION"
print_stats "Unanimous (3/3 agree)" "$UNANIMOUS_COUNT" "$RED"
print_stats "Majority (2/3 agree)" "$MAJORITY_COUNT" "$YELLOW"
print_stats "Unique to Gemini" "$UNIQUE_GEMINI" "$GRAY"
print_stats "Unique to Codex" "$UNIQUE_CODEX" "$GRAY"
print_stats "Unique to Claude" "$UNIQUE_CLAUDE" "$GRAY"
echo ""

# Unanimous Issues
if [ $UNANIMOUS_COUNT -gt 0 ]; then
  print_section "  UNANIMOUS ISSUES (3/3)"

  echo "$CONSENSUS_JSON" | jq -c '.unanimous[]' | while IFS= read -r issue; do
    section=$(echo "$issue" | jq -r '.section')
    severity=$(echo "$issue" | jq -r '.severity')
    confidence=$(echo "$issue" | jq -r '.avg_confidence')
    description=$(echo "$issue" | jq -r '.description')
    suggestion=$(echo "$issue" | jq -r '.suggestion')

    # Confidence bar (10 blocks)
    conf_int=$(echo "$confidence * 10" | bc | cut -d. -f1)
    conf_bar=""
    for i in {1..10}; do
      if [ $i -le $conf_int ]; then
        conf_bar="${conf_bar}\xe2\x96\x88"
      else
        conf_bar="${conf_bar}\xe2\x96\x91"
      fi
    done

    sev_color=""
    case "$severity" in
      high)   sev_color="${RED}" ;;
      medium) sev_color="${YELLOW}" ;;
      low)    sev_color="${GREEN}" ;;
    esac

    echo -e "  ${BOLD}${section}${RESET}"
    echo -e "    ${sev_color}[${severity^^}]${RESET} Confidence: ${CYAN}${conf_bar}${RESET} ${confidence}"
    echo -e "    ${GRAY}Issue:${RESET} $description"
    echo -e "    ${GREEN}Fix:${RESET} $suggestion"
    echo ""
  done
fi

# Majority Issues
if [ $MAJORITY_COUNT -gt 0 ]; then
  print_section "  MAJORITY ISSUES (2/3)"

  echo "$CONSENSUS_JSON" | jq -c '.majority[]' | while IFS= read -r issue; do
    section=$(echo "$issue" | jq -r '.section')
    severity=$(echo "$issue" | jq -r '.severity')
    confidence=$(echo "$issue" | jq -r '.avg_confidence')
    description=$(echo "$issue" | jq -r '.description')
    suggestion=$(echo "$issue" | jq -r '.suggestion')

    sev_color=""
    case "$severity" in
      high)   sev_color="${RED}" ;;
      medium) sev_color="${YELLOW}" ;;
      low)    sev_color="${GREEN}" ;;
    esac

    echo -e "  ${BOLD}${section}${RESET}"
    echo -e "    ${sev_color}[${severity^^}]${RESET} ${DIM}conf: ${confidence}${RESET}"
    echo -e "    ${GRAY}Issue:${RESET} $description"
    echo -e "    ${GREEN}Fix:${RESET} $suggestion"
    echo ""
  done
fi

# Unique Issues (compact)
UNIQUE_TOTAL=$((UNIQUE_GEMINI + UNIQUE_CODEX + UNIQUE_CLAUDE))
if [ $UNIQUE_TOTAL -gt 0 ]; then
  print_section "  UNIQUE ISSUES (1/3)"

  for reviewer in gemini codex claude; do
    unique_key="unique_${reviewer}"
    count=$(echo "$CONSENSUS_JSON" | jq ".${unique_key} | length")
    if [ $count -gt 0 ]; then
      echo -e "  ${GRAY}${reviewer^} only (${count}):${RESET}"
      echo "$CONSENSUS_JSON" | jq -c ".${unique_key}[]" | while IFS= read -r issue; do
        section=$(echo "$issue" | jq -r '.section')
        severity=$(echo "$issue" | jq -r '.severity')
        description=$(echo "$issue" | jq -r '.description')
        echo -e "    ${GRAY}[${severity^^}]${RESET} ${section}: ${DIM}${description}${RESET}"
      done
      echo ""
    fi
  done
fi

# Next Steps
print_header "NEXT STEPS"
if [ $TOTAL_ISSUES -eq 0 ]; then
  echo -e "${BOLD}${GREEN}  Design approved!${RESET} Ready for implementation."
else
  if [[ -f "$DECISIONS_FILE" ]]; then
    DECISION_NEEDED_COUNT=$(cat "$DECISIONS_FILE" | jq '[.[] | select(.action == "decision_needed" or .action == "recommend")] | length')
    if [[ $DECISION_NEEDED_COUNT -gt 0 ]]; then
      echo -e "  ${BOLD}${YELLOW}$DECISION_NEEDED_COUNT decision(s) need your call.${RESET} Review the checklist above."
    else
      echo -e "  ${BOLD}${GREEN}No decisions needed.${RESET} All issues auto-handled or non-blocking."
    fi
  else
    echo -e "  ${BOLD}1.${RESET} Address unanimous issues first (highest impact)"
    echo -e "  ${BOLD}2.${RESET} Review majority issues (significant concerns)"
    echo -e "  ${BOLD}3.${RESET} Evaluate unique issues (may be false positives)"
  fi
  echo ""
  echo "  To iterate:"
  echo -e "  ${CYAN}vim <design-file> && bash \"\${CLAUDE_PLUGIN_ROOT}/skills/design-reviewer/scripts/run-design-review-loop.sh\"${RESET}"
fi
echo ""

# Footer
echo -e "${GRAY}$(printf '%.0s─' {1..80})${RESET}"
echo -e "${GRAY}Generated: $(date)${RESET}"
echo -e "${GRAY}$(printf '%.0s─' {1..80})${RESET}"
