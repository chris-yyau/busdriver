#!/usr/bin/env bash
# Regression tests pinning ADR 0038 — "TDD is not a Phase 4 default; ordering is advisory".
#
# Why a test and not a note in the ADR: this repo's own canon says "enforce invariants
# with a test, never prose", and the wording ADR 0038 changed is INHERITED from upstream
# obra/superpowers, which still ships the always-on Iron Law. A sync that re-vendors the
# orchestrator or the tdd-guide agent would silently restore the mandate and nothing
# would notice. These assertions are the thing that notices.
#
# Scope: the Phase 4 DEFAULT only. Explicit TDD (/tdd and friends) is deliberately
# untouched by ADR 0038 and is asserted here to STILL work — a sync that deleted the
# opt-in route would be a different regression, equally worth catching.
# shellcheck disable=SC2016  # single quotes are deliberate: the backticks below are
# literal characters of the markdown being matched, not shell expansions. This directive
# must precede the first command to apply file-wide.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ORCH="$ROOT/skills/orchestrator/SKILL.md"
GUIDE="$ROOT/agents/tdd-guide.md"
TDD_SKILL="$ROOT/skills/test-driven-development/SKILL.md"
TDD_WORKFLOW="$ROOT/skills/tdd-workflow/SKILL.md"
ADR="$ROOT/docs/adr/0038-tdd-not-a-phase-4-default.md"

pass=0; fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

for f in "$ORCH" "$GUIDE" "$TDD_SKILL" "$TDD_WORKFLOW" "$ADR"; do
  [[ -f "$f" ]] || { echo "FAIL missing required file: $f"; exit 1; }
done

# --- The mandate is gone ------------------------------------------------------------

# Shared predicates: scope every assertion below to what it actually claims to check,
# so a future edit that removes the guarantee from the RIGHT place but leaves stray
# matching text elsewhere cannot make these pass on an incorrect policy.
has_unconditional_tdd_dispatch() {
  grep -qE '^\*\*DISPATCH `tdd-guide` agent\*\*' "$1"
}
has_proactive_tdd_description() {
  grep -q 'Use PROACTIVELY' "$1"
}
# A skill BODY loads on demand, but its frontmatter description is ambient — it is the
# routing signal. A description saying "any feature or bugfix" re-acquires the Phase 4
# default through the back door, exactly as `Use PROACTIVELY` did on the agent, so
# ADR 0038 point 7 narrows both TDD skills to explicit invocation. Same guard shape.
has_broad_tdd_routing() {
  grep -qE 'implementing any feature or bugfix|writing new features, fixing bugs, or refactoring code' "$1"
}
# The Phase 4 "Tests" bullet is the sole place ADR 0038's ordering/advisory statements
# are required to live. Scoping to just that bullet (rather than the whole file) means
# a future sync can't relocate or duplicate the phrases elsewhere and still pass.
#
# Uniqueness is part of the guard, not a nicety. Without it these are "does ANY
# '- **Tests**' line carry the phrases", so an edit that weakens the real Phase 4
# bullet while any other such line elsewhere in the file still carried them would keep
# both assertions green on a policy that no longer holds. Requiring exactly one match
# is what makes "the Phase 4 Tests bullet" name a single identifiable line.
phase4_tests_bullet() {
  grep -E '^- \*\*Tests\*\*' "$1" || true
}
count_tests_bullets() {
  grep -cE '^- \*\*Tests\*\*' "$1" || true
}

# The unconditional Phase 4 dispatch. Measured 0 dispatches in 234 over ~5 months
# before removal (ADR 0038); it must not come back as a default.
if has_unconditional_tdd_dispatch "$ORCH"; then
  bad "orchestrator restored the unconditional 'DISPATCH tdd-guide agent' line (ADR 0038)"
else
  ok "orchestrator has no unconditional tdd-guide dispatch"
fi

# The agent must not advertise itself as proactive, or the harness re-acquires the
# default through the agent description rather than through the orchestrator.
if has_proactive_tdd_description "$GUIDE"; then
  bad "agents/tdd-guide.md restored 'Use PROACTIVELY' (ADR 0038)"
else
  ok "tdd-guide is not advertised as proactive"
fi

for f in "$TDD_SKILL" "$TDD_WORKFLOW"; do
  if has_broad_tdd_routing "$f"; then
    bad "${f##*/skills/} restored a broad 'every feature/bugfix/refactor' routing description (ADR 0038 point 7)"
  else
    ok "${f##*/skills/} does not auto-route every feature/bugfix to strict TDD"
  fi
done

TESTS_BULLET_COUNT="$(count_tests_bullets "$ORCH")"
TESTS_BULLET="$(phase4_tests_bullet "$ORCH")"
if [[ "$TESTS_BULLET_COUNT" -eq 1 ]]; then
  ok "orchestrator has exactly one '- **Tests**' bullet to anchor the assertions below"
else
  # Clear TESTS_BULLET so the two phrase assertions below report the loss rather than
  # matching against an ambiguous multi-line blob.
  TESTS_BULLET=""
  bad "expected exactly one '- **Tests**' bullet in orchestrator SKILL.md, found $TESTS_BULLET_COUNT — the ADR 0038 assertions below cannot be anchored"
fi

# The Phase 4 Tests bullet must say ordering is not mandated. Asserting the POSITIVE
# claim too, not just the absence of the old one: a sync that dropped the bullet
# entirely would pass an absence-only check while losing the decision.
if [[ -n "$TESTS_BULLET" ]] && printf '%s\n' "$TESTS_BULLET" | grep -q 'Ordering is not mandated'; then
  ok "Phase 4 Tests bullet states ordering is not mandated"
else
  bad "Phase 4 Tests bullet lost the 'Ordering is not mandated' statement (ADR 0038)"
fi

# ADR 0038 turned down writing an unenforced "must fail on the base revision" rule into
# the orchestrator; the Tests bullet must keep disclosing that it is advisory until a
# gate actually runs the check. Dropping this word is how prose starts posing as
# assurance.
if [[ -n "$TESTS_BULLET" ]] && printf '%s\n' "$TESTS_BULLET" | grep -q 'Advisory, not gate-enforced'; then
  ok "Phase 4 Tests bullet discloses the rule is advisory, not gate-enforced"
else
  bad "Phase 4 Tests bullet lost its 'Advisory, not gate-enforced' disclosure (ADR 0038)"
fi

# --- What ADR 0038 deliberately did NOT change --------------------------------------

# The opt-in route. ADR 0038 keeps strict TDD fully available; only the default moved.
if grep -qE '^\| Write tests \| Phase 4 \| `/tdd`' "$ORCH"; then
  ok "explicit /tdd route is still present"
else
  bad "the opt-in '/tdd' routing row was removed — ADR 0038 keeps it"
fi

# The Iron Law governs the workflow of a skill you explicitly invoke. ADR 0038 left it
# intact on purpose; an orchestrator that does not mandate ordering and a TDD skill that
# mandates ordering *while doing TDD* are not in contradiction.
if grep -q 'NO PRODUCTION CODE WITHOUT A FAILING TEST FIRST' "$TDD_SKILL"; then
  ok "test-driven-development skill retains its Iron Law"
else
  bad "the Iron Law was removed from the TDD skill — ADR 0038 keeps it"
fi

# --- Negative control ----------------------------------------------------------------
# A guard that has never been observed failing is not a guard. Prove these assertions
# can fail by running the two most important ones against a fixture that violates them.
# Guard the mktemp: without it a failure leaves TMP empty, the redirections below
# resolve to /violating-orch.md and /violating-guide.md, and a privileged run writes
# at the filesystem root. Fail closed instead.
TMP=$(mktemp -d) || { echo "FAIL could not create temp dir"; exit 1; }
[[ -n "$TMP" && -d "$TMP" ]] || { echo "FAIL mktemp -d produced no usable directory"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
printf '%s\n' '**DISPATCH `tdd-guide` agent** to produce test files.' > "$TMP/violating-orch.md"
printf '%s\n' 'description: ... Use PROACTIVELY when writing new features ...' > "$TMP/violating-guide.md"

if has_unconditional_tdd_dispatch "$TMP/violating-orch.md"; then
  ok "negative control: the dispatch assertion fires on a violating file"
else
  bad "negative control FAILED — the dispatch assertion cannot detect a violation"
fi
if has_proactive_tdd_description "$TMP/violating-guide.md"; then
  ok "negative control: the PROACTIVELY assertion fires on a violating file"
else
  bad "negative control FAILED — the PROACTIVELY assertion cannot detect a violation"
fi

# The uniqueness requirement is the guard that stops a weakened Phase 4 bullet from
# being covered by a decoy elsewhere in the file. Prove it detects the decoy: the
# fixture's FIRST bullet has lost both phrases, the second still carries them, and a
# count-blind check would pass. Exactly the failure litmus flagged.
printf '%s\n' \
  '- **Tests** — behavioral changes ship with tests.' \
  '- **Tests** — Ordering is not mandated. Advisory, not gate-enforced.' \
  > "$TMP/decoy-orch.md"
printf '%s\n' 'description: Use when implementing any feature or bugfix, before writing implementation code' \
  > "$TMP/violating-tdd-skill.md"
if has_broad_tdd_routing "$TMP/violating-tdd-skill.md"; then
  ok "negative control: the broad-routing assertion fires on a violating description"
else
  bad "negative control FAILED — the broad-routing assertion cannot detect a violation"
fi

# has_broad_tdd_routing guards TWO regex alternatives (the tdd-workflow skill's phrasing
# differs from test-driven-development's), but only the first had a negative control
# above. A guard that has never been observed firing on its second alternative is not
# proven to catch a regression there — exactly the gap this repo's own canon warns
# about. Prove the second alternative independently.
printf '%s\n' 'description: Use this skill when writing new features, fixing bugs, or refactoring code' \
  > "$TMP/violating-tdd-workflow.md"
if has_broad_tdd_routing "$TMP/violating-tdd-workflow.md"; then
  ok "negative control: the broad-routing assertion fires on the tdd-workflow phrasing too"
else
  bad "negative control FAILED — the broad-routing assertion cannot detect the tdd-workflow phrasing"
fi

if [[ "$(count_tests_bullets "$TMP/decoy-orch.md")" -ne 1 ]]; then
  ok "negative control: the uniqueness check rejects a decoy second 'Tests' bullet"
else
  bad "negative control FAILED — the uniqueness check cannot detect a decoy bullet"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
