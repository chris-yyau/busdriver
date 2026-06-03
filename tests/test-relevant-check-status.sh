#!/usr/bin/env bash
# tests/test-relevant-check-status.sh — unit tests for the shared lock-aware
# check-status filter (scripts/relevant-check-status.sh, issue #154).
#
# Cases R1-R8 were moved here from tests/test-pre-merge-gate.sh, which used to
# sed+eval the inline _relevant_check_counts function body. They now drive the
# extracted external script via stdin. Cases 9-11 cover the new wrapper behavior
# (fail-closed, advisory override + empty-pattern guard, row emission).

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/relevant-check-status.sh"
# Disable the self-resolver so the test exercises THIS working copy deterministically
# regardless of CWD/remote (the resolver would otherwise re-exec the same file).
export BUSDRIVER_DISABLE_RELEVANT_CHECK_SELF_RESOLVE=1

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# Synthetic `gh pr checks` rows (TAB-separated: name, status, elapsed, link).
SYNTH=$(printf 'shellcheck\tpass\t5s\thttps://x\ncommitlint\tfail\t3s\thttps://x\nCodeScene\tfail\t10s\thttps://x\nbuild\tpending\t1m\thttps://x\n')

# mklock <dir> <json> — create <dir>/.github/required-checks.lock
mklock() { mkdir -p "$1/.github"; printf '%s' "$2" > "$1/.github/required-checks.lock"; }

# assert_line1 <name> <expected-line-1> <repo_dir> <input> [adv_pattern]
assert_line1() {
  local name="$1" want="$2" dir="$3" input="$4" pat="${5:-}"
  local got
  got=$(printf '%s\n' "$input" | bash "$SCRIPT" "$dir" "$pat" 2>/dev/null | head -n1)
  if [ "$got" = "$want" ]; then
    echo "  ok   $name"; PASS=$((PASS+1))
  else
    echo "  FAIL $name — want [$want] got [$got]"; FAIL=$((FAIL+1))
  fi
}

echo "== relevant-check-status.sh =="

# R1: lock required=[shellcheck] only → commitlint fail is non-required → 0 failed
D=$(mktemp -d "$TMPROOT/r1.XXXX"); mklock "$D" '{"required":[{"name":"shellcheck"}]}'
assert_line1 "R1 lock allowlist excludes non-required fail" "0 0 required 1" "$D" "$SYNTH"

# R2: lock required=[commitlint] → commitlint fail counts
D=$(mktemp -d "$TMPROOT/r2.XXXX"); mklock "$D" '{"required":[{"name":"commitlint"}]}'
assert_line1 "R2 lock allowlist counts required fail" "1 0 required 1" "$D" "$SYNTH"

# R3: lock required=[build] (pending) → 0 failed, 1 pending
D=$(mktemp -d "$TMPROOT/r3.XXXX"); mklock "$D" '{"required":[{"name":"build"}]}'
assert_line1 "R3 lock allowlist pending" "0 1 required 1" "$D" "$SYNTH"

# R4: no lock → fallback strips CodeScene; commitlint fail + build pending counted
D=$(mktemp -d "$TMPROOT/r4.XXXX")
assert_line1 "R4 no lock → advisory fallback" "1 1 all 3" "$D" "$SYNTH"

# R5: malformed lock → fallback
D=$(mktemp -d "$TMPROOT/r5.XXXX"); mklock "$D" '{not valid json'
assert_line1 "R5 malformed lock → fallback" "1 1 all 3" "$D" "$SYNTH"

# R6: empty required[] → fallback
D=$(mktemp -d "$TMPROOT/r6.XXXX"); mklock "$D" '{"required":[]}'
assert_line1 "R6 empty required[] → fallback" "1 1 all 3" "$D" "$SYNTH"

# R7a: whitespace-padded required name still matches
D=$(mktemp -d "$TMPROOT/r7a.XXXX"); mklock "$D" '{"required":[{"name":"  shellcheck  "}]}'
assert_line1 "R7a whitespace-padded name matches" "0 0 required 1" "$D" "$SYNTH"

# R7b: status-column parsing — passing check whose URL contains 'fail' not counted
D=$(mktemp -d "$TMPROOT/r7b.XXXX")
assert_line1 "R7b 'fail' in URL not counted (status column)" "0 0 all 1" "$D" \
  "$(printf 'lint\tpass\t1s\thttps://ci/fail-log\n')"

# R7c: multi-word required name exact-match
D=$(mktemp -d "$TMPROOT/r7c.XXXX"); mklock "$D" '{"required":[{"name":"Actions security"}]}'
assert_line1 "R7c multi-word required name" "1 0 required 1" "$D" \
  "$(printf 'Actions security\tfail\t1s\thttps://x\n')"

# R8: empty stdin → kept=0 (bootstrap signal)
D=$(mktemp -d "$TMPROOT/r8.XXXX")
assert_line1 "R8 empty stdin → kept=0" "0 0 all 0" "$D" ""

# 9: parser failure (fake python3 that exits 1) → conservative '1 0 all 0', exit 0
D=$(mktemp -d "$TMPROOT/c9.XXXX")
FAKEBIN=$(mktemp -d "$TMPROOT/fakebin.XXXX")
printf '#!/bin/sh\nexit 1\n' > "$FAKEBIN/python3"; chmod +x "$FAKEBIN/python3"
got=$(printf '%s\n' "$SYNTH" | PATH="$FAKEBIN:$PATH" bash "$SCRIPT" "$D" 2>/dev/null | head -n1)
rc=$(printf '%s\n' "$SYNTH" | PATH="$FAKEBIN:$PATH" bash "$SCRIPT" "$D" >/dev/null 2>&1; echo $?)
if [ "$got" = "1 0 all 0" ] && [ "$rc" = "0" ]; then
  echo "  ok   9 fail-closed on parser failure (line='1 0 all 0', exit 0)"; PASS=$((PASS+1))
else
  echo "  FAIL 9 fail-closed — line=[$got] exit=[$rc]"; FAIL=$((FAIL+1))
fi

# 10a: advisory override via $2 — strip 'Greptile' (not CodeScene); CodeScene fail counts
D=$(mktemp -d "$TMPROOT/c10a.XXXX")
assert_line1 "10a advisory override (\$2=Greptile)" "1 0 all 1" "$D" \
  "$(printf 'Greptile\tfail\t1s\tx\nCodeScene\tfail\t1s\tx\n')" "Greptile"

# 10b: empty advisory pattern resets to CodeScene (does NOT match everything)
D=$(mktemp -d "$TMPROOT/c10b.XXXX")
assert_line1 "10b empty pattern resets to CodeScene" "1 0 all 1" "$D" \
  "$(printf 'CodeScene\tpass\t1s\tx\nfoo\tfail\t1s\tx\n')" ""

# 11: row emission — failing case emits verbatim rows on lines 2..N; no-fail case does not
D=$(mktemp -d "$TMPROOT/c11.XXXX"); mklock "$D" '{"required":[{"name":"commitlint"}]}'
rows=$(printf '%s\n' "$SYNTH" | bash "$SCRIPT" "$D" 2>/dev/null | tail -n +2)
want_row=$(printf 'commitlint\tfail\t3s\thttps://x')
if [ "$rows" = "$want_row" ]; then
  echo "  ok   11a failing row emitted verbatim on line 2"; PASS=$((PASS+1))
else
  echo "  FAIL 11a — want [$want_row] got [$rows]"; FAIL=$((FAIL+1))
fi
D=$(mktemp -d "$TMPROOT/c11b.XXXX"); mklock "$D" '{"required":[{"name":"shellcheck"}]}'
rows=$(printf '%s\n' "$SYNTH" | bash "$SCRIPT" "$D" 2>/dev/null | tail -n +2)
if [ -z "$rows" ]; then
  echo "  ok   11b no rows when failed=0"; PASS=$((PASS+1))
else
  echo "  FAIL 11b — expected no rows, got [$rows]"; FAIL=$((FAIL+1))
fi

echo ""
echo "== call-site wiring (issue #154) =="

# Each call site must invoke the helper and must NOT retain the old advisory-only
# DECISION grep (`grep -ivE "$ADVISORY_PATTERN"`). A retained cosmetic CodeScene
# grep is allowed and intentionally NOT matched here.
assert_wired() {
  local label="$1" file="$2"
  if grep -q 'relevant-check-status.sh' "$file" \
     && ! grep -q 'grep -ivE "\$ADVISORY_PATTERN"' "$file"; then
    echo "  ok   $label wired to helper (old decision grep removed)"; PASS=$((PASS+1))
  else
    echo "  FAIL $label not wired / old decision grep remains"; FAIL=$((FAIL+1))
  fi
}
assert_wired "pr-grind SKILL.md" "$REPO_ROOT/skills/pr-grind/SKILL.md"
assert_wired "pr-grinder.md"     "$REPO_ROOT/agents/pr-grinder.md"
assert_wired "pre-merge-gate.sh" "$REPO_ROOT/hooks/gate-scripts/pre-merge-gate.sh"

# pr-grinder.md must no longer reference the removed $REQUIRED variable.
if ! grep -qE 'REQUIRED=\$\(echo "\$CHECKS_RAW"' "$REPO_ROOT/agents/pr-grinder.md"; then
  echo "  ok   pr-grinder.md no longer defines the removed \$REQUIRED var"; PASS=$((PASS+1))
else
  echo "  FAIL pr-grinder.md still defines \$REQUIRED"; FAIL=$((FAIL+1))
fi

# Required shellcheck CI job must lint the new helper.
if grep -q 'shellcheck --severity=warning scripts/relevant-check-status.sh' "$REPO_ROOT/.github/workflows/tests.yml"; then
  echo "  ok   required shellcheck job lints the helper"; PASS=$((PASS+1))
else
  echo "  FAIL helper not in required shellcheck job"; FAIL=$((FAIL+1))
fi

echo ""
echo "== results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
