#!/bin/bash
# Confidence scoring calculations for consensus analysis

set -euo pipefail

# Calculate mean confidence from array of confidence values
calculate_mean_confidence() {
  local -a confidences=("$@")

  if [[ ${#confidences[@]} -eq 0 ]]; then
    echo "0.0"
    return
  fi

  local sum=0
  for conf in "${confidences[@]}"; do
    sum=$(awk -v s="$sum" -v c="$conf" 'BEGIN { print s + c }')
  done

  awk -v s="$sum" -v c="${#confidences[@]}" 'BEGIN { printf "%.2f", s / c }'
}

# Find minimum confidence from array
calculate_min_confidence() {
  local -a confidences=("$@")

  if [[ ${#confidences[@]} -eq 0 ]]; then
    echo "0.0"
    return
  fi

  printf '%s\n' "${confidences[@]}" | sort -n | head -1
}

# Find maximum confidence from array
calculate_max_confidence() {
  local -a confidences=("$@")

  if [[ ${#confidences[@]} -eq 0 ]]; then
    echo "0.0"
    return
  fi

  printf '%s\n' "${confidences[@]}" | sort -rn | head -1
}

# Calculate weighted confidence based on severity
# High severity = 3x weight, Medium = 2x, Low = 1x
calculate_weighted_confidence() {
  local confidence="$1"
  local severity="$2"

  local weight=1
  case "$severity" in
    high) weight=3 ;;
    medium) weight=2 ;;
    low) weight=1 ;;
  esac

  awk -v c="$confidence" -v w="$weight" 'BEGIN { printf "%.2f", c * w }'
}

# Extract confidence scores from issue array
extract_confidence_scores() {
  local issues_json="$1"

  echo "$issues_json" | jq -r '.[] | .confidence'
}

# Calculate consensus confidence for a group of issues
# Returns: { mean, min, max, count }
calculate_consensus_confidence() {
  local issues_json="$1"

  local count=$(echo "$issues_json" | jq 'length')

  if [[ $count -eq 0 ]]; then
    echo '{"mean": 0.0, "min": 0.0, "max": 0.0, "count": 0}'
    return
  fi

  local -a confidences=()
  while IFS= read -r conf; do
    confidences+=("$conf")
  done < <(echo "$issues_json" | jq -r '.[] | .confidence')

  local mean=$(calculate_mean_confidence "${confidences[@]}")
  local min=$(calculate_min_confidence "${confidences[@]}")
  local max=$(calculate_max_confidence "${confidences[@]}")

  jq -n \
    --argjson mean "$mean" \
    --argjson min "$min" \
    --argjson max "$max" \
    --argjson count "$count" \
    '{
      mean: $mean,
      min: $min,
      max: $max,
      count: $count
    }'
}

# Determine if confidence meets auto-fix threshold
# Rule: min_confidence >= 0.8 for high severity
meets_autofix_confidence() {
  local min_confidence="$1"
  local severity="$2"

  case "$severity" in
    high)
      awk -v c="$min_confidence" 'BEGIN { exit !(c >= 0.8) }'
      ;;
    medium)
      awk -v c="$min_confidence" 'BEGIN { exit !(c >= 0.75) }'
      ;;
    *)
      return 1  # Low severity never auto-fixes
      ;;
  esac
}

# Determine if confidence meets recommendation threshold
# Rule: min_confidence >= 0.7 for high/medium severity
meets_recommendation_confidence() {
  local min_confidence="$1"
  local severity="$2"

  case "$severity" in
    high|medium)
      awk -v c="$min_confidence" 'BEGIN { exit !(c >= 0.7) }'
      ;;
    *)
      return 1
      ;;
  esac
}

# Calculate confidence variance (for uncertainty detection)
calculate_confidence_variance() {
  local -a confidences=("$@")

  if [[ ${#confidences[@]} -lt 2 ]]; then
    echo "0.0"
    return
  fi

  local mean=$(calculate_mean_confidence "${confidences[@]}")

  local sum_sq_diff=0
  for conf in "${confidences[@]}"; do
    sum_sq_diff=$(awk -v s="$sum_sq_diff" -v c="$conf" -v m="$mean" 'BEGIN {
      diff = c - m
      print s + (diff * diff)
    }')
  done

  awk -v s="$sum_sq_diff" -v c="${#confidences[@]}" 'BEGIN { printf "%.2f", s / c }'
}
