#!/usr/bin/env bash
# Regression test for #393: single-pass literal prompt rendering.
#
# render_prompt() must (1) splice values verbatim — bash >=5.2 rewrites an
# unescaped `&` in a ${var/pat/repl} replacement to the matched text, which
# corrupted diffs containing `&` — and (2) never re-read an already-injected
# value as a later placeholder (a staged diff of the litmus script literally
# contains the placeholder tokens).
#
# Usage: bash tests/test-review-loop-inject.sh
# Exit: 0 if all pass, 1 if any fail.

set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=../skills/litmus/scripts/lib/inject.sh
source skills/litmus/scripts/lib/inject.sh

PASS=0
FAIL=0

check() {  # check <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    PASS=$((PASS + 1))
    echo "  ✓ $1"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $1"
    echo "      expected: $2"
    echo "      actual:   $3"
  fi
}

echo "── render_prompt literal splicing (#393) ────────────────────"

# 1. The exact bug: `&` in the value must survive verbatim, not become the placeholder.
got=$(render_prompt "PROMPT {{DIFF}} END" '{{DIFF}}' 'a?x=1&y=2&z=3')
check "ampersands preserved (the #393 bug)" "PROMPT a?x=1&y=2&z=3 END" "$got"

# 2. Backslashes must also survive (${var/} mishandles these too).
got=$(render_prompt "{{DIFF}}" '{{DIFF}}' 'a\to&b')
check "backslashes preserved" 'a\to&b' "$got"

# 3. Real-world instance from the issue: a gh api query string.
got=$(render_prompt 'run: gh api "{{DIFF}}"' '{{DIFF}}' 'issues?state=open&labels=cve&per_page=100')
check "gh api query string intact" 'run: gh api "issues?state=open&labels=cve&per_page=100"' "$got"

# 4. THE COLLISION (surfaced reviewing #393 itself): an injected value that
#    contains a LATER placeholder token must not be re-read as that placeholder.
got=$(render_prompt "A {{DIFF}} B {{CTX}} C" \
  '{{DIFF}}' 'diff mentions {{CTX}} literally' \
  '{{CTX}}'  'REAL-CONTEXT')
check "injected value cannot shadow a later placeholder" \
  "A diff mentions {{CTX}} literally B REAL-CONTEXT C" "$got"

# 5. Placeholder order in the arg list is irrelevant — earliest-in-template wins,
#    and each real placeholder still gets its own value.
got=$(render_prompt "first={{A}} second={{B}}" '{{B}}' 'bbb' '{{A}}' 'aaa')
check "earliest-in-template resolves regardless of arg order" \
  "first=aaa second=bbb" "$got"

# 6. Each placeholder replaced at most once (prior single-substitution semantics).
got=$(render_prompt "X {{DIFF}} Y {{DIFF}} Z" '{{DIFF}}' 'val')
check "first occurrence only" "X val Y {{DIFF}} Z" "$got"

# 7. Missing placeholder → template unchanged.
got=$(render_prompt "no marker here" '{{DIFF}}' 'whatever')
check "passthrough when placeholder absent" "no marker here" "$got"

# 8. Empty value → placeholder removed cleanly.
got=$(render_prompt "before {{DIFF}} after" '{{DIFF}}' '')
check "empty value removes placeholder" "before  after" "$got"

echo ""
echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
