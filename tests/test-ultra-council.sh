#!/bin/bash
# tests/test-ultra-council.sh — ADR 0007 Phase 3 contract for ultra-council.
# ponytail: static grep contract over the markdown skill — checks the rendered directives/template,
# not a live council+oracle run (billed + browser, out of scope for CI). Anchors are headings/
# var-names chosen to stay stable across rewording. grep -F for literal metacharacters.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$DIR/skills/council/SKILL.md"
CMD="$DIR/commands/ultra-council.md"
FAIL=0

# (a) Oracle has its own labeled Expert Witness section.
grep -qF '## UltraOracle — Expert Witness [ORACLE_SUMMARY_REVIEW]' "$SKILL" \
  || { echo "FAIL: no labeled Expert Witness heading in council SKILL"; FAIL=1; }

# (b) Excluded from the vote tally (settling-check #1), in the contract and the Step 6 slot.
grep -qiE 'excluded from the .*vote tally' "$SKILL" \
  || { echo "FAIL: 'excluded from the vote tally' contract missing"; FAIL=1; }
grep -qF 'EXCLUDED from Consensus' "$SKILL" \
  || { echo "FAIL: Step 6 template lacks the exclusion note"; FAIL=1; }

# (c) Vote-#6 phrasing GONE from skill AND shim; no residual "...voice" slug; slug renamed.
if grep -nEi '(sixth|6th)[^.]*(vote|voice)|ultra-oracle voice' "$SKILL" "$CMD" 2>/dev/null; then
  echo "FAIL: vote-#6 phrasing present (skill or shim)"; FAIL=1
fi
if grep -qF 'ultra oracle council voice' "$SKILL"; then
  echo "FAIL: residual '--slug \"ultra oracle council voice\"' present"; FAIL=1
fi
grep -qF 'ultra oracle expert witness' "$SKILL" \
  || { echo "FAIL: dispatch --slug not renamed to the expert-witness label"; FAIL=1; }

# (d) Force is named, SCOPED (plain assignment + unset), never exported.
grep -qF 'ULTRA_ORACLE_COUNCIL_FORCE=1' "$SKILL" \
  || { echo "FAIL: no ULTRA_ORACLE_COUNCIL_FORCE=1 directive in council SKILL"; FAIL=1; }
if grep -qF 'export ULTRA_ORACLE_COUNCIL_FORCE' "$SKILL" || grep -qF 'export ULTRA_ORACLE_COUNCIL_FORCE' "$CMD"; then
  echo "FAIL: force var must be a scoped plain assignment, never exported"; FAIL=1
fi
grep -qF 'unset ULTRA_ORACLE_COUNCIL_FORCE' "$SKILL" \
  || { echo "FAIL: force var is not unset (would leak into a later council)"; FAIL=1; }

# (e) ATTEMPTED flag drives the render (so config-enabled + forced-but-failed both render).
grep -qF 'ULTRA_ORACLE_ATTEMPTED' "$SKILL" \
  || { echo "FAIL: no ULTRA_ORACLE_ATTEMPTED flag (render keys on it)"; FAIL=1; }

# (f) Loud failure banner survives (settling-check #6).
grep -qF 'ORACLE_FAILED' "$SKILL" \
  || { echo "FAIL: ORACLE_FAILED banner missing"; FAIL=1; }

# (g) Real render present (cat the verdict); no inert ': #' placeholders.
grep -qF 'cat "$ULTRA_ORACLE_OUT"' "$SKILL" \
  || { echo "FAIL: render branch does not cat the verdict (still inert?)"; FAIL=1; }
if grep -qF ': # include the verdict' "$SKILL"; then
  echo "FAIL: inert ': #' render placeholder still present"; FAIL=1
fi

# (h) Trigger routes to council; shim exists, references council + the force directive.
grep -qi 'ultra-council' "$SKILL"            || { echo "FAIL: no ultra-council trigger in council SKILL"; FAIL=1; }
[ -f "$CMD" ]                                || { echo "FAIL: commands/ultra-council.md missing"; FAIL=1; }
grep -qi 'council' "$CMD" 2>/dev/null        || { echo "FAIL: shim does not reference council"; FAIL=1; }
grep -qF 'ULTRA_ORACLE_COUNCIL_FORCE=1' "$CMD" 2>/dev/null \
  || { echo "FAIL: shim does not name the force directive"; FAIL=1; }

if [ "$FAIL" -eq 0 ]; then echo "PASS test-ultra-council"; else echo "test-ultra-council FAILED"; fi
exit "$FAIL"
