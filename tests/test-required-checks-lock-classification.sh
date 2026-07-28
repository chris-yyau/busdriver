#!/usr/bin/env bash
# tests/test-required-checks-lock-classification.sh — surface (e) of
# scripts/check-required-checks.sh (issue #530).
#
# Surface (e) asserts that every status check a workflow posts is classified in
# .github/required-checks.lock as `required` or `advisory`. It is the only
# server-drift guard that can run in CI: (b) compares against live branch
# protection and needs `administration: read`, which GITHUB_TOKEN cannot be
# granted, so (e) is what actually blocks the #530 failure from recurring.
#
# The bug it guards: `coverage`, `shell-tests`, `validate` and `version-drift`
# were required by branch protection but absent from the lock. Because
# relevant-check-status.sh treats lock.required as an ALLOWLIST, the four were
# filtered out of the merge decision entirely — neither pending nor failed —
# so a PR with two FAILING required checks reported `0 0 required 8`, green.
#
# Runs against a synthetic repo per case, never the real lock, so it keeps
# passing as the repo's own workflows change.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/check-required-checks.sh"

PASS=0
FAIL=0
# Guard the mktemp: an unchecked failure leaves TMPROOT empty, so every case
# dir becomes an absolute path like /e1 — negative cases would then "pass"
# for the wrong reason, and a privileged run would write at the filesystem
# root. Validate before anything derives a path from it.
TMPROOT="$(mktemp -d)" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
[[ -n "$TMPROOT" && -d "$TMPROOT" ]] || { echo "FAIL: TMPROOT invalid" >&2; exit 1; }
trap 'rm -rf "$TMPROOT"' EXIT

# mkrepo <dir> <lock-json> <workflow-yaml>
mkrepo() {
  mkdir -p "$1/.github/workflows" "$1/scripts"
  printf '%s' "$2" > "$1/.github/required-checks.lock"
  printf '%s' "$3" > "$1/.github/workflows/tests.yml"
  # (e) is reached via the script's own SCRIPT_DIR/.. resolution, so the
  # script must live inside the synthetic repo.
  cp "$SCRIPT" "$1/scripts/check-required-checks.sh"
}

# assert_exit <name> <expected-exit> <dir>
assert_exit() {
  local name="$1" want="$2" dir="$3" got
  bash "$dir/scripts/check-required-checks.sh" --local-only >"$dir/out.txt" 2>&1
  got=$?
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1)); echo "  ok   $name (exit $got)"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name — expected exit $want, got $got"; sed 's/^/       /' "$dir/out.txt"
  fi
}

# assert_mentions <name> <substring> <dir>
assert_mentions() {
  local name="$1" needle="$2" dir="$3"
  if grep -qF "$needle" "$dir/out.txt"; then
    PASS=$((PASS + 1)); echo "  ok   $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name — output did not mention '$needle'"; sed 's/^/       /' "$dir/out.txt"
  fi
}

WF_TWO_JOBS='jobs:
  alpha:
    runs-on: ubuntu-latest
  beta:
    name: Beta Check
    runs-on: ubuntu-latest
'

echo "== E1: every workflow check classified => exit 0 =="
D="$TMPROOT/e1"
mkrepo "$D" '{"required":[{"name":"alpha","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha"}],"advisory":[{"name":"Beta Check","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"beta"}]}' "$WF_TWO_JOBS"
assert_exit "classified lock passes" 0 "$D"
assert_mentions "reports ok" "every workflow check name is classified" "$D"

echo "== E2: the #530 shape — a required check missing from the lock => exit 1 =="
D="$TMPROOT/e2"
mkrepo "$D" '{"required":[{"name":"alpha","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha"}],"advisory":[]}' "$WF_TWO_JOBS"
assert_exit "unclassified check fails closed" 1 "$D"
assert_mentions "names the unclassified check" "'Beta Check'" "$D"

echo "== E3: a check classified as advisory is accepted (not required) =="
D="$TMPROOT/e3"
mkrepo "$D" '{"required":[],"advisory":[{"name":"alpha","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha"},{"name":"Beta Check","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"beta"}]}' "$WF_TWO_JOBS"
assert_exit "advisory classification accepted" 0 "$D"

echo "== E4: names containing spaces are matched whole, not fragmented =="
# 'Beta Check' must not be split on whitespace into 'Beta' + 'Check'; if it
# were, this lock (which classifies only the fragments) would wrongly pass.
D="$TMPROOT/e4"
mkrepo "$D" '{"required":[{"name":"alpha","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha"},{"name":"Beta","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"beta"},{"name":"Check","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"beta"}],"advisory":[]}' "$WF_TWO_JOBS"
assert_exit "space-bearing name not fragmented" 1 "$D"

echo "== E5: object-shaped .advisory is rejected at startup, not silently read =="
# jq iterates an object's VALUES, so an object-shaped advisory would still
# supply every name and let (e) report ok on a malformed lock — fail-OPEN.
D="$TMPROOT/e5"
mkrepo "$D" '{"required":[{"name":"alpha","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha"}],"advisory":{"x":{"name":"Beta Check"}}}' "$WF_TWO_JOBS"
assert_exit "malformed advisory rejected" 2 "$D"

echo "== E6: non-string .name is rejected at startup =="
D="$TMPROOT/e6"
mkrepo "$D" '{"required":[{"name":123,"source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha"}],"advisory":[]}' "$WF_TWO_JOBS"
assert_exit "non-string name rejected" 2 "$D"

echo "== E7: absent .advisory is tolerated (treated as empty) =="
D="$TMPROOT/e7"
mkrepo "$D" '{"required":[{"name":"alpha","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha"},{"name":"Beta Check","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"beta"}]}' "$WF_TWO_JOBS"
assert_exit "missing advisory key tolerated" 0 "$D"

echo "== E8: an Actions job may not borrow an EXTERNAL app's check name =="
# Only github-actions entries classify a workflow check. Honouring the
# gitguardian entry here would let an Actions job take the name of an
# externally reported required context and still read as classified — a
# collision (a) skips (no workflow/job to resolve) and (d) cannot see
# (it only compares workflow names against each other).
D="$TMPROOT/e8"
mkrepo "$D" '{"required":[{"name":"alpha","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha"},{"name":"Beta Check","source_app":"gitguardian"}],"advisory":[]}' "$WF_TWO_JOBS"
assert_exit "external-app name does not classify a workflow job" 1 "$D"
assert_mentions "names the colliding check" "'Beta Check'" "$D"

echo "== E9: matrix entries classify by (workflow, job), not by rendered name =="
# GitHub renders a matrix job as `<base> (<label>)`, so the lock holds
# `alpha (ubuntu-latest)` while the workflow contributes the bare base
# `alpha`. Comparing names would report a correctly-classified matrix job as
# unclassified and wedge CI on every matrix repo.
D="$TMPROOT/e9"
mkrepo "$D" '{"required":[{"name":"alpha (ubuntu-latest)","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha","matrix_value":"ubuntu-latest"},{"name":"alpha (macos-latest)","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha","matrix_value":"macos-latest"},{"name":"Beta Check","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"beta"}],"advisory":[]}' "$WF_TWO_JOBS"
assert_exit "matrix job classified via tuple" 0 "$D"

echo "== E10: a matrix entry only classifies ITS OWN job =="
# The tuple must be (workflow, job) — keying on workflow alone would let one
# matrix entry blanket-classify every job in the same file.
D="$TMPROOT/e10"
mkrepo "$D" '{"required":[{"name":"alpha (ubuntu-latest)","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha","matrix_value":"ubuntu-latest"}],"advisory":[]}' "$WF_TWO_JOBS"
assert_exit "sibling job still unclassified" 1 "$D"
assert_mentions "names only the sibling" "'Beta Check'" "$D"

echo "== E11: quoted job IDs are collected, not skipped =="
# `"quoted-job":` is legal YAML that Actions accepts. A collector that skips it
# never demands a classification for that job — a fail-OPEN in the guard itself.
D="$TMPROOT/e11"
WF_QUOTED='jobs:
  alpha:
    runs-on: ubuntu-latest
  "quoted-job":
    runs-on: ubuntu-latest
'
mkrepo "$D" '{"required":[{"name":"alpha","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha"}],"advisory":[]}' "$WF_QUOTED"
assert_exit "unclassified quoted job fails closed" 1 "$D"
assert_mentions "names the quoted job" "quoted-job" "$D"

echo "== E12: a classified quoted job passes BOTH (a) and (e) =="
# Pins the parser-agreement invariant: if only one collector understood quoted
# keys, this lock would be unsatisfiable — (e) demands the entry, (a) then
# cannot find the job in the workflow.
D="$TMPROOT/e12"
mkrepo "$D" '{"required":[{"name":"alpha","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha"},{"name":"quoted-job","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"quoted-job"}],"advisory":[]}' "$WF_QUOTED"
assert_exit "classified quoted job satisfies both parsers" 0 "$D"

echo
echo "passed: $PASS   failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
