#!/usr/bin/env bash
# tests/test-blueprint-review-oracle-arbiter-contract.sh
# ADR 0007 Phase 4 — locks the ultra-oracle arbiter auxiliary contract that
# settling-checks #3 (false oracle claim cannot gate without validation) and
# #4 (oracle uncounted toward reviewer coverage) depend on.
#
# The advisory MUST reach the blueprint-review arbiter prompt as AUXILIARY
# context that does NOT count as a reviewer, and the arbiter MUST be told to
# validate issues against the codebase with repo tools. If a refactor drops
# this framing, a false oracle file claim could leak into PASS/FAIL — exactly
# what settling-check #3 forbids.
#
# This is a STATIC contract test: the arbiter is an LLM, so "rejects a false
# claim" is runtime behavior, not shell-unit-testable. We instead pin the
# source-of-truth strings the safety property is built on (same approach as
# tests/test-ultra-council.sh).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOP="$DIR/skills/blueprint-review/scripts/run-design-review-loop.sh"
FAIL=0

[ -f "$LOOP" ] || { echo "FAIL loop script not found: $LOOP"; exit 1; }

check() { # desc, fixed-string
  if grep -qF "$2" "$LOOP"; then
    echo "  PASS  $1"
  else
    echo "  FAIL  $1"; echo "        missing: $2"; FAIL=1
  fi
}

# settling-check #4 (coverage): oracle rendered as auxiliary, not a 4th reviewer
check "advisory block labelled auxiliary, not a reviewer" \
  'AUXILIARY, *NOT* A REVIEWER'
check "advisory block fixes reviewer count at three" \
  'exactly THREE reviewers (Agy/Codex/Grok)'
check "arbiter prompt re-states oracle is auxiliary and uncounted" \
  'the reviewer count is always three, and the advisory must not be counted toward independent agreement'

# settling-check #3 (false claim cannot gate without validation):
# arbiter must validate each issue against the codebase using repo tools
check "arbiter instructed to validate each issue against codebase" \
  'For each issue: validate against codebase'
check "arbiter instructed to use repo tools for examination" \
  'Use Read, Grep, Glob tools to examine the codebase'

[ "$FAIL" = 0 ] && echo "PASS test-blueprint-review-oracle-arbiter-contract" || exit 1
