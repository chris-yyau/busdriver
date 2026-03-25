#!/bin/bash
# Consensus detection and analysis for three-tier design review
# Analyzes Gemini + Codex + Claude outputs and categorizes issues

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/validation.sh"
source "$SCRIPT_DIR/lib/semantic_similarity.sh"
source "$SCRIPT_DIR/lib/confidence_scoring.sh"
source "$SCRIPT_DIR/lib/state_management.sh"

# Check for required review files
GEMINI_FILE=$(get_review_file "gemini.json")
CODEX_FILE=$(get_review_file "codex.json")
CLAUDE_FILE=$(get_review_file "claude.json")
OUTPUT_FILE=$(get_review_file "consensus.json")

log_info "Starting consensus analysis"

# Validate review files exist
for file in "$GEMINI_FILE" "$CODEX_FILE" "$CLAUDE_FILE"; do
  if ! validate_json_file "$file"; then
    log_error "Invalid or missing review file: $file"
    exit 1
  fi
done

# Load review JSONs
GEMINI_JSON=$(cat "$GEMINI_FILE")
CODEX_JSON=$(cat "$CODEX_FILE")
CLAUDE_JSON=$(cat "$CLAUDE_FILE")

# Initialize consensus groups
declare -a UNANIMOUS=()
declare -a MAJORITY=()
declare -a UNIQUE_GEMINI=()
declare -a UNIQUE_CODEX=()
declare -a UNIQUE_CLAUDE=()

# Track matched issue keys per reviewer (newline-delimited for bash 3 compat)
MATCHED_CODEX_KEYS=""
MATCHED_CLAUDE_KEYS=""

# Process each Gemini issue
log_info "Processing Gemini issues..."
GEMINI_COUNT=$(echo "$GEMINI_JSON" | jq '.issues | length')

for ((i=0; i<GEMINI_COUNT; i++)); do
  G_ISSUE=$(echo "$GEMINI_JSON" | jq -c ".issues[$i]")

  G_SECTION=$(echo "$G_ISSUE" | jq -r '.section')
  G_CATEGORY=$(echo "$G_ISSUE" | jq -r '.category')
  G_DESC=$(echo "$G_ISSUE" | jq -r '.description')

  G_SIG=$(create_issue_signature "$G_SECTION" "$G_CATEGORY" "$G_DESC")

  # Find matches in Codex
  C_MATCH=$(find_similar_issue "$G_SIG" "$CODEX_JSON" "0.7")

  # Find matches in Claude
  CL_MATCH=$(find_similar_issue "$G_SIG" "$CLAUDE_JSON" "0.7")

  # Categorize based on matches
  if [[ -n "$C_MATCH" && -n "$CL_MATCH" ]]; then
    # All 3 agree - unanimous
    MERGED=$(merge_issues "$G_ISSUE" "$C_MATCH" "$CL_MATCH")
    UNANIMOUS+=("$MERGED")
    # Track matched Codex/Claude issues by section+description hash
    C_MATCH_KEY=$(echo "$C_MATCH" | jq -r '"\(.section)|\(.description)"' | md5 -q)
    CL_MATCH_KEY=$(echo "$CL_MATCH" | jq -r '"\(.section)|\(.description)"' | md5 -q)
    MATCHED_CODEX_KEYS="${MATCHED_CODEX_KEYS}${C_MATCH_KEY}"$'\n'
    MATCHED_CLAUDE_KEYS="${MATCHED_CLAUDE_KEYS}${CL_MATCH_KEY}"$'\n'
    log_info "  Found unanimous issue: $G_SECTION"
  elif [[ -n "$C_MATCH" || -n "$CL_MATCH" ]]; then
    # 2 of 3 agree - majority
    if [[ -n "$C_MATCH" ]]; then
      MERGED=$(merge_issues "$G_ISSUE" "$C_MATCH")
      C_MATCH_KEY=$(echo "$C_MATCH" | jq -r '"\(.section)|\(.description)"' | md5 -q)
      MATCHED_CODEX_KEYS="${MATCHED_CODEX_KEYS}${C_MATCH_KEY}"$'\n'
    else
      MERGED=$(merge_issues "$G_ISSUE" "$CL_MATCH")
      CL_MATCH_KEY=$(echo "$CL_MATCH" | jq -r '"\(.section)|\(.description)"' | md5 -q)
      MATCHED_CLAUDE_KEYS="${MATCHED_CLAUDE_KEYS}${CL_MATCH_KEY}"$'\n'
    fi
    MAJORITY+=("$MERGED")
    log_info "  Found majority issue: $G_SECTION"
  else
    # Only Gemini flagged - unique
    UNIQUE_GEMINI+=("$G_ISSUE")
    log_info "  Found unique Gemini issue: $G_SECTION"
  fi
done

# Process Codex issues not already matched
log_info "Processing remaining Codex issues..."
CODEX_COUNT=$(echo "$CODEX_JSON" | jq '.issues | length')

for ((i=0; i<CODEX_COUNT; i++)); do
  C_ISSUE=$(echo "$CODEX_JSON" | jq -c ".issues[$i]")

  C_SECTION=$(echo "$C_ISSUE" | jq -r '.section')
  C_CATEGORY=$(echo "$C_ISSUE" | jq -r '.category')
  C_DESC=$(echo "$C_ISSUE" | jq -r '.description')

  C_SIG=$(create_issue_signature "$C_SECTION" "$C_CATEGORY" "$C_DESC")

  # Check if this specific Codex issue was already matched during Gemini processing
  C_KEY=$(echo "$C_ISSUE" | jq -r '"\(.section)|\(.description)"' | md5 -q)
  if echo "$MATCHED_CODEX_KEYS" | grep -qF "$C_KEY"; then
    continue
  fi

  # Find match in Claude
  CL_MATCH=$(find_similar_issue "$C_SIG" "$CLAUDE_JSON" "0.7")

  if [[ -n "$CL_MATCH" ]]; then
    # Codex + Claude (majority)
    MERGED=$(merge_issues "$C_ISSUE" "$CL_MATCH")
    MAJORITY+=("$MERGED")
    # Track matched Claude issue
    CL_MATCH_KEY=$(echo "$CL_MATCH" | jq -r '"\(.section)|\(.description)"' | md5 -q)
    MATCHED_CLAUDE_KEYS="${MATCHED_CLAUDE_KEYS}${CL_MATCH_KEY}"$'\n'
    log_info "  Found majority issue (Codex+Claude): $C_SECTION"
  else
    # Only Codex
    UNIQUE_CODEX+=("$C_ISSUE")
    log_info "  Found unique Codex issue: $C_SECTION"
  fi
done

# Process remaining Claude issues
log_info "Processing remaining Claude issues..."
CLAUDE_COUNT=$(echo "$CLAUDE_JSON" | jq '.issues | length')

for ((i=0; i<CLAUDE_COUNT; i++)); do
  CL_ISSUE=$(echo "$CLAUDE_JSON" | jq -c ".issues[$i]")

  CL_SECTION=$(echo "$CL_ISSUE" | jq -r '.section')

  # Check if this specific Claude issue was already matched during Gemini/Codex processing
  CL_KEY=$(echo "$CL_ISSUE" | jq -r '"\(.section)|\(.description)"' | md5 -q)
  if echo "$MATCHED_CLAUDE_KEYS" | grep -qF "$CL_KEY"; then
    continue
  fi

  UNIQUE_CLAUDE+=("$CL_ISSUE")
  log_info "  Found unique Claude issue: $CL_SECTION"
done

# Calculate consensus rate
TOTAL_ISSUES=$((${#UNANIMOUS[@]} + ${#MAJORITY[@]} + ${#UNIQUE_GEMINI[@]} + ${#UNIQUE_CODEX[@]} + ${#UNIQUE_CLAUDE[@]}))
CONSENSUS_ISSUES=$((${#UNANIMOUS[@]} + ${#MAJORITY[@]}))

if [[ $TOTAL_ISSUES -eq 0 ]]; then
  CONSENSUS_RATE=1.0
else
  CONSENSUS_RATE=$(awk -v c="$CONSENSUS_ISSUES" -v t="$TOTAL_ISSUES" 'BEGIN { printf "%.2f", c / t }')
fi

# Build output JSON
log_info "Generating consensus report..."

# Safely convert arrays to JSON (handle empty arrays under set -u)
safe_array_to_json() {
  if [[ $# -eq 0 ]]; then
    echo '[]'
  else
    printf '%s\n' "$@" | jq -s '.'
  fi
}

UNANIMOUS_JSON="$(safe_array_to_json ${UNANIMOUS[@]+"${UNANIMOUS[@]}"})"
MAJORITY_JSON="$(safe_array_to_json ${MAJORITY[@]+"${MAJORITY[@]}"})"
UNIQUE_G_JSON="$(safe_array_to_json ${UNIQUE_GEMINI[@]+"${UNIQUE_GEMINI[@]}"})"
UNIQUE_C_JSON="$(safe_array_to_json ${UNIQUE_CODEX[@]+"${UNIQUE_CODEX[@]}"})"
UNIQUE_CL_JSON="$(safe_array_to_json ${UNIQUE_CLAUDE[@]+"${UNIQUE_CLAUDE[@]}"})"

jq -n \
  --argjson unanimous "$UNANIMOUS_JSON" \
  --argjson majority "$MAJORITY_JSON" \
  --argjson unique_g "$UNIQUE_G_JSON" \
  --argjson unique_c "$UNIQUE_C_JSON" \
  --argjson unique_cl "$UNIQUE_CL_JSON" \
  --argjson consensus_rate "$CONSENSUS_RATE" \
  --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  '{
    timestamp: $timestamp,
    consensus_rate: $consensus_rate,
    summary: {
      unanimous_count: ($unanimous | length),
      majority_count: ($majority | length),
      unique_gemini_count: ($unique_g | length),
      unique_codex_count: ($unique_c | length),
      unique_claude_count: ($unique_cl | length),
      total_issues: (($unanimous | length) + ($majority | length) + ($unique_g | length) + ($unique_c | length) + ($unique_cl | length))
    },
    unanimous: $unanimous,
    majority: $majority,
    unique_gemini: $unique_g,
    unique_codex: $unique_c,
    unique_claude: $unique_cl
  }' > "$OUTPUT_FILE"

log_info "Consensus analysis complete"
log_info "  Unanimous: ${#UNANIMOUS[@]}"
log_info "  Majority: ${#MAJORITY[@]}"
log_info "  Unique (Gemini): ${#UNIQUE_GEMINI[@]}"
log_info "  Unique (Codex): ${#UNIQUE_CODEX[@]}"
log_info "  Unique (Claude): ${#UNIQUE_CLAUDE[@]}"
log_info "  Consensus rate: $CONSENSUS_RATE"
log_info "  Output saved to: $OUTPUT_FILE"
