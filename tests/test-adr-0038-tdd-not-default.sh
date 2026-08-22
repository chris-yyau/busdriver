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
WRITING_PLANS="$ROOT/skills/writing-plans/SKILL.md"
SDD="$ROOT/skills/subagent-driven-development/SKILL.md"
SDD_REVIEWER="$ROOT/skills/subagent-driven-development/task-reviewer-prompt.md"
GUIDE="$ROOT/agents/tdd-guide.md"
TDD_SKILL="$ROOT/skills/test-driven-development/SKILL.md"
TDD_WORKFLOW="$ROOT/skills/tdd-workflow/SKILL.md"
SYSDBG="$ROOT/skills/systematic-debugging/SKILL.md"
ADR="$ROOT/docs/adr/0038-tdd-not-a-phase-4-default.md"

pass=0; fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

for f in "$ORCH" "$WRITING_PLANS" "$SDD" "$SDD_REVIEWER" "$GUIDE" "$TDD_SKILL" "$TDD_WORKFLOW" "$SYSDBG" "$ADR"; do
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
# The two predicates above are BLOCKLISTS: they reject the specific phrasings that were
# there before ADR 0038. That is necessary but not sufficient — a description that never
# uses those words (`Use for every code change`) restores the default and passes both.
# A blocklist can only ever enumerate the broad phrasings someone already thought of.
#
# So require the POSITIVE routing signal instead: every TDD-metadata description must say
# activation is explicit AND name the route. All three files already carry both, so this
# is an allowlist over the wording ADR 0038 actually settled on, and any rewrite that
# drops it fails regardless of what it says instead.
#
# Scoped to the frontmatter `description:` line, not the whole file — the description is
# the ambient routing signal; body prose is not, and matching it would let a mention in
# the body cover for a broad description.
description_line() {
  grep -m1 -E '^description:' "$1" || true
}
has_explicit_request_routing() {
  local d
  d="$(description_line "$1")"
  [[ -n "$d" ]] \
    && printf '%s\n' "$d" | grep -q 'explicitly requested' \
    && printf '%s\n' "$d" | grep -q '`/tdd`'
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

# The allowlist, applied to every piece of TDD metadata the harness routes on — the
# agent as well as both skills. This is what catches a broad rewrite the blocklists
# above have no phrase for.
for f in "$GUIDE" "$TDD_SKILL" "$TDD_WORKFLOW"; do
  # Repo-relative, not basename: both skills' files are named SKILL.md, so a basename
  # label would print the same line twice and name neither.
  if has_explicit_request_routing "$f"; then
    ok "${f#"$ROOT"/} description requires explicit TDD activation and names the /tdd route"
  else
    bad "${f#"$ROOT"/} description no longer states TDD is explicitly requested via \`/tdd\` — routing may have widened back to a default (ADR 0038)"
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

# ADR 0038 removed the mandated ORDERING, not the requirement that behavioral changes
# come with tests. The two assertions above only pin the ordering/advisory qualifiers, so
# a bullet rewritten to make tests themselves optional would satisfy both and still lose
# the thing ADR 0038 explicitly kept. Assert the requirement it preserved.
if [[ -n "$TESTS_BULLET" ]] && printf '%s\n' "$TESTS_BULLET" | grep -q 'behavioral changes ship with tests'; then
  ok "Phase 4 Tests bullet still requires behavioral changes to ship with tests"
else
  bad "Phase 4 Tests bullet lost the 'behavioral changes ship with tests' requirement — ADR 0038 relaxed ordering, not the tests themselves"
fi

# --- systematic-debugging must not re-mandate TDD via bug-fix auto-routing (#657) ----
# Pins the exact retired mandate and positive Phase-4 contract from issue #657.
# No prose-equivalence classifier: variant detection has no bounded completeness
# guarantee and produced false positives in PR #732 review.

phase4_implementation_section() {
  awk '/^### Phase 4: Implementation/,/^## Red Flags/' "$1"
}

SYSDBG_PHASE4="$(phase4_implementation_section "$SYSDBG")"
if [[ -z "$SYSDBG_PHASE4" ]]; then
  bad "systematic-debugging Phase 4 section missing — cannot anchor #657 assertions"
elif printf '%s\n' "$SYSDBG_PHASE4" | grep -q 'MUST have before fixing'; then
  bad "systematic-debugging restored unconditional 'MUST have before fixing' (ADR 0038 / #657)"
else
  ok "systematic-debugging has no unconditional failing-test-before-fix mandate"
fi

if printf '%s\n' "$SYSDBG_PHASE4" | grep -q 'Ordering is not mandated'; then
  ok "systematic-debugging Phase 4 states ordering is not mandated"
else
  bad "systematic-debugging Phase 4 lost 'Ordering is not mandated' (ADR 0038 / #657)"
fi

if [[ -n "$SYSDBG_PHASE4" ]] \
  && printf '%s\n' "$SYSDBG_PHASE4" | grep -q 'explicitly requested' \
  && printf '%s\n' "$SYSDBG_PHASE4" | grep -q '/tdd'; then
  ok "systematic-debugging Phase 4 scopes strict TDD to explicit request"
else
  bad "systematic-debugging Phase 4 no longer scopes TDD to explicit request (ADR 0038 / #657)"
fi

if grep -q 'NO FIXES WITHOUT ROOT CAUSE INVESTIGATION FIRST' "$SYSDBG"; then
  ok "systematic-debugging retains root-cause Iron Law"
else
  bad "systematic-debugging lost the root-cause Iron Law"
fi

if [[ -n "$SYSDBG_PHASE4" ]] \
  && printf '%s\n' "$SYSDBG_PHASE4" | grep -q 'nontrivial fixes' \
  && printf '%s\n' "$SYSDBG_PHASE4" | grep -q 'reproducible check'; then
  ok "systematic-debugging Phase 4 still requires a regression check for nontrivial fixes"
else
  bad "systematic-debugging Phase 4 lost the regression-check requirement (ADR 0038 / #657)"
fi

# --- writing-plans / subagent-driven-development must not re-mandate TDD ordering (#653) ----
# Pins the exact retired mandates and positive Phase-4 contract from issue #653.
# No prose-equivalence classifier: variant detection has no bounded completeness
# guarantee and produced false positives in PR #732 review.

wp_task_structure_section() {
  awk '/^## Task Structure$/{found=1;next} found && /^## /{exit} found' "$1"
}

has_mandated_wp_step1_ordering() {
  printf '%s\n' "$1" | grep -qE '\*\*Step 1: (Write the failing test|Write minimal implementation)\*\*'
}

has_separate_impl_test_checkboxes() {
  local section="$1"
  printf '%s\n' "$section" | grep -q '\*\*Implement the behavior\*\*' \
    && printf '%s\n' "$section" | grep -q '\*\*Add or update tests\*\*'
}

wp_bite_sized_section() {
  awk '/^## Bite-Sized Task Granularity$/{found=1;next} found && /^## /{exit} found' "$1"
}

sdd_advantages_section() {
  awk '/^## Advantages$/{found=1;next} found && /^## /{exit} found' "$1"
}

sdd_integration_section() {
  awk '/^## Integration$/{found=1;next} found && /^## /{exit} found' "$1"
}

WP_BITE_SIZED="$(wp_bite_sized_section "$WRITING_PLANS")"
WP_TASK_STRUCTURE="$(wp_task_structure_section "$WRITING_PLANS")"
SDD_ADVANTAGES="$(sdd_advantages_section "$SDD")"
SDD_INTEGRATION="$(sdd_integration_section "$SDD")"

if [[ -z "$WP_BITE_SIZED" ]]; then
  bad "writing-plans Bite-Sized Task Granularity section missing — cannot anchor #653 assertions"
elif printf '%s\n' "$WP_BITE_SIZED" | grep -qF '"Write the failing test" - step'; then
  bad "writing-plans restored unconditional bite-sized 'Write the failing test' step (#653)"
else
  ok "writing-plans has no unconditional bite-sized test-first step"
fi

if [[ -z "$WP_TASK_STRUCTURE" ]]; then
  bad "writing-plans Task Structure section missing — cannot anchor #653 assertions"
elif has_mandated_wp_step1_ordering "$WP_TASK_STRUCTURE"; then
  bad "writing-plans task template restored mandated Step 1 ordering (#653)"
elif has_separate_impl_test_checkboxes "$WP_TASK_STRUCTURE"; then
  bad "writing-plans task template restored separate implementation and test checkbox steps (#653)"
else
  ok "writing-plans task template does not mandate Step 1 or separate impl/test checkboxes"
fi

if [[ -n "$WP_TASK_STRUCTURE" ]] && printf '%s\n' "$WP_TASK_STRUCTURE" | grep -q 'either order'; then
  ok "writing-plans task template states implementation and tests may be done in either order"
else
  bad "writing-plans task template lost order-neutral wording (#653)"
fi

if [[ -n "$WP_TASK_STRUCTURE" ]] \
  && printf '%s\n' "$WP_TASK_STRUCTURE" | grep -q 'Implement the behavior with tests'; then
  ok "writing-plans task template combines implementation and tests in one flexible step"
else
  bad "writing-plans task template lost combined impl+tests step (#653)"
fi

if [[ -n "$WP_BITE_SIZED" ]] && printf '%s\n' "$WP_BITE_SIZED" | grep -q 'Ordering is not mandated'; then
  ok "writing-plans Bite-Sized section states ordering is not mandated"
else
  bad "writing-plans Bite-Sized section lost 'Ordering is not mandated' (#653)"
fi

if [[ -n "$WP_BITE_SIZED" ]] && printf '%s\n' "$WP_BITE_SIZED" | grep -q 'behavioral changes ship with tests'; then
  ok "writing-plans Bite-Sized section still requires behavioral changes to ship with tests"
else
  bad "writing-plans Bite-Sized section lost the behavioral-changes ship-with-tests requirement (#653)"
fi

if [[ -n "$WP_BITE_SIZED" ]] \
  && printf '%s\n' "$WP_BITE_SIZED" | grep -q 'explicitly requested' \
  && printf '%s\n' "$WP_BITE_SIZED" | grep -q '/tdd'; then
  ok "writing-plans Bite-Sized section scopes strict TDD to explicit request"
else
  bad "writing-plans Bite-Sized section no longer scopes TDD to explicit request (#653)"
fi

if grep -qF 'Subagents follow TDD for each task' "$SDD"; then
  bad "subagent-driven-development restored 'Subagents follow TDD for each task' (#653)"
else
  ok "subagent-driven-development has no unconditional per-task TDD mandate"
fi

if grep -qF 'Subagents follow TDD naturally' "$SDD"; then
  bad "subagent-driven-development restored 'Subagents follow TDD naturally' (#653)"
else
  ok "subagent-driven-development does not claim subagents follow TDD naturally"
fi

if [[ -n "$SDD_ADVANTAGES" ]] && printf '%s\n' "$SDD_ADVANTAGES" | grep -q 'Ordering is not mandated'; then
  ok "subagent-driven-development Advantages section states ordering is not mandated"
else
  bad "subagent-driven-development Advantages section lost 'Ordering is not mandated' (#653)"
fi

if [[ -n "$SDD_INTEGRATION" ]] \
  && printf '%s\n' "$SDD_INTEGRATION" | grep -q 'explicitly requested' \
  && printf '%s\n' "$SDD_INTEGRATION" | grep -q '/tdd'; then
  ok "subagent-driven-development Integration section scopes strict TDD to explicit request"
else
  bad "subagent-driven-development Integration section no longer scopes TDD to explicit request (#653)"
fi

if grep -qF 'reported results with TDD evidence for exactly this code' "$SDD_REVIEWER"; then
  bad "task-reviewer-prompt unconditionally assumes TDD evidence (#653)"
else
  ok "task-reviewer-prompt does not unconditionally assume TDD evidence"
fi

if grep -q 'When TDD was required' "$SDD_REVIEWER" \
  && grep -q 'must include RED/GREEN evidence' "$SDD_REVIEWER"; then
  ok "task-reviewer-prompt requires RED/GREEN evidence only when TDD was required"
else
  bad "task-reviewer-prompt lost positive conditional TDD evidence wording (#653)"
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

# The allowlist exists because the blocklists cannot enumerate every broad phrasing.
# Prove exactly that with a description neither blocklist has a phrase for: it must slip
# past has_broad_tdd_routing and still be caught by has_explicit_request_routing. The
# first of these two assertions is the demonstration of the gap; the second is the fix.
printf '%s\n' 'description: Use for every code change to enforce test-first development' \
  > "$TMP/broad-alt-description.md"
if has_broad_tdd_routing "$TMP/broad-alt-description.md"; then
  bad "fixture is not the intended case — the blocklist already matches it, so it proves nothing about the allowlist"
else
  ok "negative control: the blocklist alone misses 'Use for every code change' — this is the gap"
fi
if has_explicit_request_routing "$TMP/broad-alt-description.md"; then
  bad "negative control FAILED — the allowlist accepted a broad description carrying no explicit-request wording"
else
  ok "negative control: the allowlist rejects the broad description the blocklist missed"
fi

# And the allowlist must accept the real wording, or it would fail closed on everything
# and its rejections above would mean nothing.
printf '%s\n' 'description: Use when TDD is explicitly requested — via `/tdd` or a direct ask.' \
  > "$TMP/valid-description.md"
if has_explicit_request_routing "$TMP/valid-description.md"; then
  ok "negative control: the allowlist accepts the approved explicit-request wording"
else
  bad "negative control FAILED — the allowlist rejects the approved wording, so it always fails"
fi

# A Tests bullet that keeps both ADR 0038 qualifiers but drops the tests requirement.
printf '%s\n' '- **Tests** — Ordering is not mandated. Advisory, not gate-enforced.' \
  > "$TMP/optional-tests-bullet.md"
if printf '%s\n' "$(phase4_tests_bullet "$TMP/optional-tests-bullet.md")" | grep -q 'behavioral changes ship with tests'; then
  bad "negative control FAILED — the behavioral-tests assertion cannot detect a bullet that dropped the requirement"
else
  ok "negative control: the behavioral-tests assertion fires on a bullet that made tests optional"
fi

if [[ "$(count_tests_bullets "$TMP/decoy-orch.md")" -ne 1 ]]; then
  ok "negative control: the uniqueness check rejects a decoy second 'Tests' bullet"
else
  bad "negative control FAILED — the uniqueness check cannot detect a decoy bullet"
fi

violating=0
for section in \
  "$(printf '%s\n' '- [ ] **Implement the behavior**' '- [ ] **Add or update tests**')" \
  "$(printf '%s\n' '- [ ] **Add or update tests**' '- [ ] **Implement the behavior**')"; do
  if ! has_separate_impl_test_checkboxes "$section"; then
    violating=$((violating + 1))
  fi
done
if [[ "$violating" -eq 0 ]]; then
  ok "negative control: the separate-checkbox assertion fires on both orientations"
else
  bad "negative control FAILED — the separate-checkbox assertion cannot detect a violation"
fi

printf '%s\n' '- [ ] **Step 1: Write the failing test**' > "$TMP/violating-wp-template.md"
if has_mandated_wp_step1_ordering "$(cat "$TMP/violating-wp-template.md")"; then
  ok "negative control: the Step 1 ordering assertion fires on a violating template"
else
  bad "negative control FAILED — the Step 1 ordering assertion cannot detect a violation"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
