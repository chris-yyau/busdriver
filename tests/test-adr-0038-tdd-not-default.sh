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
ADR="$ROOT/docs/adr/0038-tdd-not-a-phase-4-default.md"

pass=0; fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

for f in "$ORCH" "$GUIDE" "$TDD_SKILL" "$ADR"; do
  [[ -f "$f" ]] || { echo "FAIL missing required file: $f"; exit 1; }
done

# --- The mandate is gone ------------------------------------------------------------

# The unconditional Phase 4 dispatch. Measured 0 dispatches in 234 over ~5 months
# before removal (ADR 0038); it must not come back as a default.
if grep -qE '^\*\*DISPATCH `tdd-guide` agent\*\*' "$ORCH"; then
  bad "orchestrator restored the unconditional 'DISPATCH tdd-guide agent' line (ADR 0038)"
else
  ok "orchestrator has no unconditional tdd-guide dispatch"
fi

# The agent must not advertise itself as proactive, or the harness re-acquires the
# default through the agent description rather than through the orchestrator.
if grep -q 'Use PROACTIVELY' "$GUIDE"; then
  bad "agents/tdd-guide.md restored 'Use PROACTIVELY' (ADR 0038)"
else
  ok "tdd-guide is not advertised as proactive"
fi

# The Phase 4 bullet must say ordering is not mandated. Asserting the POSITIVE claim
# too, not just the absence of the old one: a sync that dropped the bullet entirely
# would pass an absence-only check while losing the decision.
if grep -q 'Ordering is not mandated' "$ORCH"; then
  ok "Phase 4 states ordering is not mandated"
else
  bad "Phase 4 lost the 'Ordering is not mandated' statement (ADR 0038)"
fi

# ADR 0038 turned down writing an unenforced "must fail on the base revision" rule into
# the orchestrator; the bullet must keep disclosing that it is advisory until a gate
# actually runs the check. Dropping this word is how prose starts posing as assurance.
if grep -q 'Advisory, not gate-enforced' "$ORCH"; then
  ok "Phase 4 discloses the rule is advisory, not gate-enforced"
else
  bad "Phase 4 lost its 'Advisory, not gate-enforced' disclosure (ADR 0038)"
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

if grep -qE '^\*\*DISPATCH `tdd-guide` agent\*\*' "$TMP/violating-orch.md"; then
  ok "negative control: the dispatch assertion fires on a violating file"
else
  bad "negative control FAILED — the dispatch assertion cannot detect a violation"
fi
if grep -q 'Use PROACTIVELY' "$TMP/violating-guide.md"; then
  ok "negative control: the PROACTIVELY assertion fires on a violating file"
else
  bad "negative control FAILED — the PROACTIVELY assertion cannot detect a violation"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
