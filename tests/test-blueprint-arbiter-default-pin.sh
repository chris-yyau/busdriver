#!/usr/bin/env bash
# tests/test-blueprint-arbiter-default-pin.sh
# Static contract test (#265) locking the opus-default arbiter migration
# (ADR 0008 / SKILL.md v3.5) into the live spec: a future refactor must not silently
# regress the default pin back to fable, drop the ultra-arbiter opt-in, or resurrect the
# retired `model_pin_status` fallback tokens.
#
# The retired tokens (gateway_fable_fallback / opus_fallback / inherited_fallback) and the
# old `model: fable` pin legitimately survive in the APPEND-ONLY Version History. The
# negative checks therefore scan the BODY ONLY — everything BEFORE the `## Version History`
# heading — cut with a heading-level-ROBUST regex (`/^#+ Version History/`), never a fixed
# line number, so appending a v3.6 entry or renumbering the doc can't break the exclusion
# (issue #265, low finding). Same static-string approach as
# tests/test-blueprint-review-oracle-arbiter-contract.sh (the contract is prose an LLM
# arbiter follows, so it is pinned, not executed).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$DIR/skills/blueprint-review/SKILL.md"
FAIL=0
[[ -f "$SKILL" ]] || { echo "FAIL SKILL.md not found: $SKILL"; exit 1; }

# Heading-robust cut: everything before the first `#+ Version History` heading.
BODY="$(awk '/^#+[[:space:]]+Version History/{exit} {print}' "$SKILL")"

present() { if grep -qF -- "$2" <<<"$BODY"; then echo "  PASS  $1"
  else echo "  FAIL  $1"; echo "        missing from body: $2"; FAIL=1; fi; }
absent()  { if grep -qF -- "$2" <<<"$BODY"; then echo "  FAIL  $1"
  echo "        present in body (should be Version-History-only): $2"; FAIL=1
  else echo "  PASS  $1"; fi; }

# Guard against a VACUOUS test: if the Version History heading is ever removed/renamed the
# cut would keep the whole file and absent() could trivially pass (or the append-only
# history would leak into the body scan). Anchor the exclusion explicitly.
if ! grep -qE '^#+[[:space:]]+Version History' "$SKILL"; then
  echo "  FAIL  Version History heading not found — heading-robust cut anchor is gone"; FAIL=1
fi
[[ "$(wc -l <<<"$BODY")" -lt "$(wc -l <"$SKILL")" ]] \
  || { echo "  FAIL  body cut removed nothing (heading match failed?)"; FAIL=1; }

echo "── opus is the default pin ──"
present "default arbiter pin is model: opus" 'model: opus'
present "opus success status recorded" 'model_pin_status=pinned'
absent  "fable is NOT the default pin in the live body" 'model: fable'

echo "── ultra-arbiter is the opt-in escalation ──"
present "ultra-arbiter opt-in key documented (USER config)" '.ultraArbiter.enabled'
present "env force documented" 'BLUEPRINT_ARBITER_ULTRA=1'
present "ultra escalation ran status" 'model_pin_status=ultra_arbiter_fable'
present "ultra unavailable status (opt-in set, ran opus)" 'model_pin_status=ultra_arbiter_unavailable'

echo "── unavailable → expect opus + caller-side loudness (crit 5/6) ──"
present "pin check expects opus for the unavailable case" 'the expected pin is `opus`'
present "loud caller-side warning banner" 'WARNING: ULTRA-ARBITER UNAVAILABLE'

echo "── retired fallback statuses gone from the live spec (Version-History-excluded) ──"
absent "gateway_fable_fallback retired" 'gateway_fable_fallback'
absent "opus_fallback retired" 'opus_fallback'
absent "inherited_fallback retired" 'inherited_fallback'

[[ "$FAIL" = 0 ]] && echo "PASS test-blueprint-arbiter-default-pin" \
  || { echo "FAIL test-blueprint-arbiter-default-pin"; exit 1; }
