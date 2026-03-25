#!/bin/bash
# Semantic similarity matching for issue consensus detection
# v2: Python-backed multi-signal scoring (section number + keywords + category)

set -euo pipefail

# ── Python helper for similarity computation ────────────────────────
# Doing text matching in bash is too limited. This inlines a small Python
# module that the bash callers invoke through wrapper functions.

_SIMILARITY_PY='
import sys, json, re

STOP_WORDS = set("""
the a an is are was were be been being have has had do does did will would
should could may might must can of in on at for to from with by about as into
through during before after above below between under over this that these
those it its and or but not no yes also already both more very only just
even than such so if when where how what which who whom whose each every all
any some there here then now still already also just
""".split())

# Extra stop words specific to design review context
REVIEW_STOP = set("""
design document section line lines described specifies specified documents
documented mentions mentioned notes noted stated states currently existing
explicitly review reviewed reviewer issue issues finding suggests suggesting
confirms confirmed validates validated raises raised flags flagged concern
concerns potential potentially implementation implemented
""".split())

ALL_STOP = STOP_WORDS | REVIEW_STOP

def extract_section_number(section_text):
    """Extract leading section number: 5. Session Lifecycle / ... -> 5"""
    m = re.match(r"(\d+)", section_text.strip())
    return m.group(1) if m else ""

def extract_section_subsection(section_text):
    """Extract subsection after the slash: 5. Session Lifecycle / Server startup recovery -> server startup recovery"""
    parts = re.split(r"[/\-,]", section_text)
    if len(parts) > 1:
        return parts[-1].strip().lower()
    return section_text.strip().lower()

def tokenize(text):
    """Normalize and tokenize text, removing stop words."""
    text = text.lower()
    text = re.sub(r"[^a-z0-9 ]", " ", text)
    words = [w for w in text.split() if w and w not in ALL_STOP and len(w) > 2]
    return set(words)

def jaccard(set1, set2):
    if not set1 and not set2:
        return 0.0
    inter = len(set1 & set2)
    union = len(set1 | set2)
    return inter / union if union > 0 else 0.0

def overlap_coefficient(set1, set2):
    """Overlap = |intersection| / min(|set1|, |set2|). More forgiving than Jaccard
    when one description is much longer than the other."""
    if not set1 or not set2:
        return 0.0
    inter = len(set1 & set2)
    return inter / min(len(set1), len(set2))

def compute_similarity(section1, category1, desc1, section2, category2, desc2):
    """Multi-signal similarity scoring. Returns 0.0 to 1.0."""

    # Signal 1: Section number match (strong signal — same design section)
    sec_num1 = extract_section_number(section1)
    sec_num2 = extract_section_number(section2)
    section_score = 0.0
    if sec_num1 and sec_num2 and sec_num1 == sec_num2:
        section_score = 1.0
        # Bonus for subsection match
        sub1 = extract_section_subsection(section1)
        sub2 = extract_section_subsection(section2)
        sub_tokens1 = tokenize(sub1)
        sub_tokens2 = tokenize(sub2)
        if sub_tokens1 and sub_tokens2:
            sub_overlap = overlap_coefficient(sub_tokens1, sub_tokens2)
            if sub_overlap > 0.5:
                section_score = 1.0  # full credit

    # Signal 2: Category match (soft signal — different reviewers use different categories)
    category_score = 0.0
    if category1 == category2:
        category_score = 1.0
    else:
        # Categories that are conceptually related get partial credit
        RELATED = {
            frozenset({"technical-accuracy", "implementation"}): 0.7,
            frozenset({"bugs", "implementation"}): 0.7,
            frozenset({"bugs", "technical-accuracy"}): 0.6,
            frozenset({"architecture", "implementation"}): 0.6,
            frozenset({"architecture", "completeness"}): 0.5,
            frozenset({"completeness", "implementation"}): 0.5,
            frozenset({"completeness", "best-practices"}): 0.5,
            frozenset({"performance", "bugs"}): 0.5,
            frozenset({"performance", "implementation"}): 0.5,
            frozenset({"clarity", "completeness"}): 0.5,
            frozenset({"technical-accuracy", "completeness"}): 0.4,
            frozenset({"feasibility", "implementation"}): 0.5,
            frozenset({"feasibility", "architecture"}): 0.5,
        }
        pair = frozenset({category1, category2})
        category_score = RELATED.get(pair, 0.2)  # minimum 0.2 — never fully block

    # Signal 3: Description keyword similarity (primary signal)
    tokens1 = tokenize(desc1)
    tokens2 = tokenize(desc2)
    # Use max of Jaccard and overlap coefficient (overlap is more forgiving)
    keyword_jaccard = jaccard(tokens1, tokens2)
    keyword_overlap = overlap_coefficient(tokens1, tokens2)
    keyword_score = max(keyword_jaccard, keyword_overlap * 0.85)  # slight discount for overlap

    # Weighted combination
    # Section number is a very strong signal when matched
    if section_score > 0:
        # Same section: weight keywords heavily, category is just a bonus
        final = 0.25 * section_score + 0.55 * keyword_score + 0.20 * category_score
    else:
        # Different sections: need stronger keyword evidence
        final = 0.10 * section_score + 0.70 * keyword_score + 0.20 * category_score

    return round(final, 2)


# ── CLI interface ──────────────────────────────────────────────────
# Called from bash: python3 -c "..." "compare" "sig1_json" "sig2_json"
# Or: python3 -c "..." "find_best" "target_sig_json" "review_json" "threshold"

if __name__ == "__main__":
    pass  # Functions are called via exec from bash
'

# ── Bash wrapper functions ─────────────────────────────────────────
# These maintain the same interface as v1 so consensus_analyzer.sh doesn't change.

# Create issue signature as JSON for Python consumption
create_issue_signature() {
  local section="$1"
  local category="$2"
  local description="$3"

  # Output as JSON for reliable passing to Python
  jq -n --arg s "$section" --arg c "$category" --arg d "$description" \
    '{"section": $s, "category": $c, "description": $d}'
}

# Compare two issue signatures — returns similarity score (0.0 to 1.0)
compare_issue_signatures() {
  local sig1="$1"
  local sig2="$2"

  _SIG1="$sig1" _SIG2="$sig2" python3 -c "
$_SIMILARITY_PY
import json, os
sig1 = json.loads(os.environ['_SIG1'])
sig2 = json.loads(os.environ['_SIG2'])
score = compute_similarity(
    sig1['section'], sig1['category'], sig1['description'],
    sig2['section'], sig2['category'], sig2['description']
)
print(f'{score:.2f}')
"
}

# Find the best-matching issue in a review JSON
# Returns: JSON object of matching issue or empty string
find_similar_issue() {
  local target_signature="$1"
  local review_json="$2"
  local similarity_threshold="${3:-0.45}"

  # Use Python for the whole search to avoid N×M bash loops with jq calls
  _TARGET="$target_signature" _THRESHOLD="$similarity_threshold" python3 -c "
$_SIMILARITY_PY
import json, sys, os

target = json.loads(os.environ['_TARGET'])
review = json.loads(sys.stdin.read())

best_match = None
best_score = 0.0
threshold = float(os.environ['_THRESHOLD'])

for issue in review.get('issues', []):
    score = compute_similarity(
        target['section'], target['category'], target['description'],
        issue.get('section', ''), issue.get('category', ''), issue.get('description', '')
    )
    if score >= threshold and score > best_score:
        best_score = score
        best_match = issue

if best_match:
    print(json.dumps(best_match, separators=(',', ':')))
" <<< "$review_json"
}

# Compute Jaccard similarity (kept for backward compat, now unused internally)
compute_jaccard_similarity() {
  local keywords1="$1"
  local keywords2="$2"

  python3 -c "
$_SIMILARITY_PY
s1 = set('$keywords1'.split())
s2 = set('$keywords2'.split())
print(f'{jaccard(s1, s2):.2f}')
"
}

# Merge issues from multiple reviewers (for consensus groups)
# Combines description + suggestions, averages confidence
merge_issues() {
  local -a issues=("$@")

  if [[ ${#issues[@]} -eq 0 ]]; then
    echo "{}"
    return
  fi

  # Use first issue as base
  local merged="${issues[0]}"

  # Extract fields from all issues
  local -a reviewers=()
  local -a confidences=()
  local -a descriptions=()
  local -a suggestions=()

  for issue in "${issues[@]}"; do
    reviewers+=($(echo "$issue" | jq -r '.reviewer'))
    confidences+=($(echo "$issue" | jq -r '.confidence'))
    descriptions+=($(echo "$issue" | jq -r '.description'))
    suggestions+=($(echo "$issue" | jq -r '.suggestion'))
  done

  # Calculate average confidence
  local sum_confidence=0
  local count=${#confidences[@]}
  for conf in "${confidences[@]}"; do
    sum_confidence=$(awk -v s="$sum_confidence" -v c="$conf" 'BEGIN { print s + c }')
  done
  local avg_confidence=$(awk -v s="$sum_confidence" -v c="$count" 'BEGIN { printf "%.2f", s / c }')

  # Find minimum confidence
  local min_confidence=$(printf '%s\n' "${confidences[@]}" | sort -n | head -1)

  # Combine descriptions and suggestions
  local combined_descriptions=$(printf '%s\\n' "${descriptions[@]}")
  local combined_suggestions=$(printf '%s\\n' "${suggestions[@]}")

  # Build merged JSON
  jq -n \
    --arg section "$(echo "$merged" | jq -r '.section')" \
    --arg severity "$(echo "$merged" | jq -r '.severity')" \
    --argjson avg_confidence "$avg_confidence" \
    --argjson min_confidence "$min_confidence" \
    --arg category "$(echo "$merged" | jq -r '.category')" \
    --arg combined_desc "$combined_descriptions" \
    --arg combined_sugg "$combined_suggestions" \
    --argjson flagged_by "$(printf '%s\n' "${issues[@]}" | jq -s '.')" \
    '{
      section: $section,
      severity: $severity,
      avg_confidence: $avg_confidence,
      min_confidence: $min_confidence,
      category: $category,
      description: $combined_desc,
      suggestion: $combined_sugg,
      flagged_by: $flagged_by
    }'
}
