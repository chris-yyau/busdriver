# Validate Before Building

> Provenance: distilled from `~/.claude/notes/` Council Lessons — GStack adoption scope, Premature integration, Verify before building, Measure before building, No test scaffolding in CI, No blanket test stubs.

## Rule

Do not build, port, or integrate a feature until you have **empirical evidence** the problem it solves actually exists. Assumptions about gaps, coverage, or user demand must be verified with data before they justify engineering work.

## Reach for what exists first

Once the Rule clears (the thing *should* exist), don't reach straight for new code. Stop at the first rung that holds:

**stdlib → native platform feature → already-installed dependency → one clear line → only then new code.**

Mark a deliberate simplification with a greppable inline receipt that names its upgrade trigger — never a bare TODO, never cover for known-broken behavior:

    // keep-simple(UPGRADE: per-account locks if contention is real): single global lock

## Checklist (before starting any build/port/integration)

- [ ] **Is the problem verified?** Have you measured the gap on real data, not estimated it?
- [ ] **Is anyone asking for this?** Is there user demand, or are you anticipating demand that may never arrive?
- [ ] **Is the existing solution actually insufficient?** Diff current vs. proposed on real inputs before assuming a gap.
- [ ] **Is this worth maintaining?** The marginal value of feature N+1 approaches zero. Maintenance cost is forever.

## Anti-Patterns

| Trap | Example | Fix |
|------|---------|-----|
| Optimizing unmeasured metrics | "Coverage is ~85%" with no audit | Measure first, then optimize |
| Building integration bridges speculatively | "These two tools should work together" | Wait for a user to ask |
| Porting features by gap analysis | "Competitor has X, we don't" | Ask: is anyone blocked without X? |
| Replacing paid tools without diffing | "We can build our own X" | Run both on same inputs, compare findings |
| Scaffolding tests for non-app repos | "Repo has no test config" | Check if testable code exists first; offer linting for config repos |
| Generating per-module test stubs | "Every module needs a test file" | One gold-standard template + /tdd on demand beats 50 TODO stubs |

## The Skeptic Test

Before committing to a build, ask: *"If a Skeptic with zero context challenged this, what data would I show them?"* If the answer is "my intuition" or "it seems like we need it" — you haven't validated.
