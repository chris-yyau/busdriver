#!/bin/bash
# Run Gemini and Codex CLI reviews on design artifacts (plans, architecture docs, structure)

set -e

# Check if both CLIs are available
if ! command -v gemini &> /dev/null; then
    echo '{"status": "ERROR", "message": "Gemini CLI not found. Please install it first."}' >&2
    exit 1
fi

if ! command -v codex &> /dev/null; then
    echo '{"status": "ERROR", "message": "Codex CLI not found. Please install it first."}' >&2
    exit 1
fi

# Get the artifact file path (required argument)
if [ -z "$1" ]; then
    echo '{"status": "ERROR", "message": "Usage: run_design_review.sh <file_path>"}' >&2
    exit 1
fi

ARTIFACT_FILE="$1"

if [ ! -f "$ARTIFACT_FILE" ]; then
    echo "{\"status\": \"ERROR\", \"message\": \"File not found: $ARTIFACT_FILE\"}" >&2
    exit 1
fi

# Read the artifact content
CONTENT=$(cat "$ARTIFACT_FILE")

if [ -z "$CONTENT" ]; then
    echo '{"status": "PASS", "gemini_issues": [], "codex_issues": [], "message": "Empty file, nothing to review"}' >&2
    exit 0
fi

echo "=== Running Gemini Strategic Review ===" >&2

# Run Gemini for strategic/architectural review
GEMINI_PROMPT="Review this plan/design document for strategic and architectural soundness. Focus on:
- Clarity and completeness of the plan/design
- Architectural decisions and trade-offs
- Feasibility and potential roadblocks
- Missing considerations or edge cases
- Alignment with best practices

Output STRICT JSON format:
{
  \"status\": \"PASS\"|\"FAIL\",
  \"issues\": [
    {
      \"section\": \"section name or line reference\",
      \"severity\": \"high\"|\"medium\"|\"low\",
      \"category\": \"clarity\"|\"completeness\"|\"architecture\"|\"feasibility\"|\"best-practices\",
      \"description\": \"clear description\",
      \"suggestion\": \"how to improve\"
    }
  ]
}

If no issues, issues array should be empty. Status is FAIL if any high or medium severity issues exist.

Document to review:
---
$CONTENT
---"

GEMINI_OUTPUT=$(echo "$GEMINI_PROMPT" | gemini 2>/dev/null || echo '{"status": "ERROR", "issues": [], "message": "Gemini CLI failed"}')

echo "=== Running Codex Technical Review ===" >&2

# Run Codex for technical/implementation review
CODEX_PROMPT="Review this plan/design document for technical and implementation soundness. Focus on:
- Technical accuracy and correctness
- Implementation approach and methodology
- Potential bugs or issues in proposed solution
- Code structure and organization (if applicable)
- Technical best practices and patterns

Output STRICT JSON format:
{
  \"status\": \"PASS\"|\"FAIL\",
  \"issues\": [
    {
      \"section\": \"section name or line reference\",
      \"severity\": \"high\"|\"medium\"|\"low\",
      \"category\": \"technical-accuracy\"|\"implementation\"|\"bugs\"|\"structure\"|\"best-practices\",
      \"description\": \"clear description\",
      \"suggestion\": \"how to fix\"
    }
  ]
}

If no issues, issues array should be empty. Status is FAIL if any high or medium severity issues exist.

Document to review:
---
$CONTENT
---"

CODEX_OUTPUT=$(echo "$CODEX_PROMPT" | codex 2>/dev/null || echo '{"status": "ERROR", "issues": [], "message": "Codex CLI failed"}')

# Combine results
echo "{"
echo "  \"file\": \"$ARTIFACT_FILE\","
echo "  \"gemini\": $GEMINI_OUTPUT,"
echo "  \"codex\": $CODEX_OUTPUT"
echo "}"
