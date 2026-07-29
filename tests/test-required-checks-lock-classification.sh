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
  # script must live inside the synthetic repo — along with the YAML
  # enumerator it shells out to.
  mkdir -p "$1/scripts/lib"
  cp "$SCRIPT" "$1/scripts/check-required-checks.sh"
  cp "$REPO_ROOT/scripts/lib/list-workflow-checks.mjs" "$1/scripts/lib/"
  # js-yaml must resolve from the synthetic repo. Node walks up from the
  # script's directory, so one symlink at the repo root is enough.
  ln -sfn "$REPO_ROOT/node_modules" "$1/node_modules"
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

[[ -d "$REPO_ROOT/node_modules/js-yaml" ]] || {
  echo "FAIL: node_modules/js-yaml missing — run 'npm ci' first" >&2; exit 1; }

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

WF_MATRIX='jobs:
  build:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
    runs-on: x
'
MX_UBUNTU='{"name":"build (ubuntu-latest)","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"build","matrix_value":"ubuntu-latest"}'
MX_MACOS='{"name":"build (macos-latest)","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"build","matrix_value":"macos-latest"}'

echo "== E9: EVERY rendered matrix combination must be classified =="
# The enumerator expands strategy.matrix into one row per combination, so each
# rendered context needs its own lock entry — matching branch protection, which
# lists contexts one per name.
D="$TMPROOT/e9"
mkrepo "$D" "{\"required\":[$MX_UBUNTU,$MX_MACOS],\"advisory\":[]}" "$WF_MATRIX"
assert_exit "complete matrix lock passes" 0 "$D"

echo "== E10: a MISSING matrix variant is caught — the #530 gap, one level in =="
# Classifying a matrix job by its bare base name let ONE entry satisfy (e) while
# a newly required `build (windows-latest)` stayed absent from the lock. Surface
# (b) catches that, but (b) needs admin scope and cannot run in CI — so nothing
# did. Enumerating the combinations closes it in the token-free subset.
D="$TMPROOT/e10"
mkrepo "$D" "{\"required\":[$MX_UBUNTU],\"advisory\":[]}" "$WF_MATRIX"
assert_exit "missing matrix variant is drift" 1 "$D"
assert_mentions "names the unclassified variant" "build (macos-latest)" "$D"

echo "== E10b: a bare BASE-name entry no longer classifies a matrix job =="
D="$TMPROOT/e10b"
mkrepo "$D" '{"required":[{"name":"build","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"build"}],"advisory":[]}' "$WF_MATRIX"
assert_exit "bare base name does not classify" 1 "$D"

echo "== E10c: an unrenderable matrix is REFUSED, not classified under a base =="
# Expressions, fromJSON and include/exclude cannot be resolved from the file, so
# the enumerator refuses rather than guessing — computing them would mean
# reimplementing Actions expression evaluation inside a merge gate.
for shape in 'os: [ubuntu-latest, "${{ env.X }}"]' 'os: [ubuntu-latest]
        include:
          - os: windows-latest'; do
  D="$TMPROOT/e10c-$RANDOM"
  mkrepo "$D" '{"required":[],"advisory":[]}' "jobs:
  build:
    strategy:
      matrix:
        $shape
    runs-on: x
"
  assert_exit "unrenderable matrix refused" 2 "$D"
done

echo "== E11: quoted job IDs are seen identically by (a) and (e) =="
# The two parsers MUST agree on which keys exist. If only one recognized a
# quoted key, (e) would demand a lock entry for a job (a) cannot resolve —
# CI red with no satisfiable lock state. \047 is a single quote; embedding one
# literally inside this file's quoting would be a footgun.
WF_QUOTED=$(printf 'jobs:\n  "alpha":\n    runs-on: ubuntu-latest\n  \047beta\047:\n    name: Beta Check\n    runs-on: ubuntu-latest\n')
D="$TMPROOT/e11"
mkrepo "$D" '{"required":[{"name":"alpha","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha"}],"advisory":[{"name":"Beta Check","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"beta"}]}' "$WF_QUOTED"
assert_exit "quoted job IDs agree across parsers" 0 "$D"

echo "== E12: a step-level name: is not mistaken for the job name =="
# A `with: name: <artifact>` key sits far deeper than the job body. Reading it
# as the job name would make (e) demand a lock entry for a check never posted.
WF_STEP_NAME=$(printf 'jobs:\n  alpha:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/upload-artifact@v4\n        with:\n          name: build-artifacts\n')
D="$TMPROOT/e12"
mkrepo "$D" '{"required":[{"name":"alpha","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha"}],"advisory":[]}' "$WF_STEP_NAME"
assert_exit "step-level name ignored" 0 "$D"

echo "== E13: null .advisory is rejected, not silently treated as empty =="
# `// []` accepts null/false as empty, contradicting "if present, must be an
# array". A null advisory is a malformed lock, not an empty one.
D="$TMPROOT/e13"
mkrepo "$D" '{"required":[{"name":"alpha","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha"}],"advisory":null}' "$WF_TWO_JOBS"
assert_exit "null advisory rejected" 2 "$D"

echo "== E14: job keys are found at ANY consistent indent, not just two spaces =="
# YAML permits any consistent indent, and Actions accepts a four-space-indented
# job. A collector hardcoded to /^  / silently omits it, so surface (e) never
# demands a classification for that job and an unclassified required check
# sails through — a fail-OPEN in the guard itself. Also pins that a deeper
# body key does not get mistaken for a second job.
D="$TMPROOT/e14"
WF_FOUR_SPACE='jobs:
    alpha:
        runs-on: ubuntu-latest
    beta:
        name: Beta Check
        runs-on: ubuntu-latest
'
mkrepo "$D" '{"required":[{"name":"alpha","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha"}],"advisory":[]}' "$WF_FOUR_SPACE"
assert_exit "four-space job is collected and fails closed" 1 "$D"
assert_mentions "names the four-space job" "'Beta Check'" "$D"

echo "== E15: a fully classified four-space workflow passes =="
D="$TMPROOT/e15"
mkrepo "$D" '{"required":[{"name":"alpha","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha"},{"name":"Beta Check","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"beta"}],"advisory":[]}' "$WF_FOUR_SPACE"
assert_exit "four-space workflow satisfies both parsers" 0 "$D"


echo "== E16: a flow-style jobs block is PARSED, and its jobs demanded =="
# Flow style (`jobs: {alpha: {...}}`) is valid YAML that Actions accepts. The
# regex scanner this replaced could not read it at all and had to refuse the
# whole file; a real parser sees the jobs and holds them to the same rule.
D="$TMPROOT/e16"
mkrepo "$D" '{"required":[],"advisory":[]}' 'jobs: {alpha: {runs-on: ubuntu-latest}}
'
assert_exit "flow-style job is seen and unclassified" 1 "$D"
assert_mentions "names the flow-style job" "'alpha'" "$D"
echo "== E17: a STALE advisory entry is caught by (a), not left to widen (e) =="
# (e) classifies by name, so an advisory entry whose job no longer exists would
# keep classifying whatever new job later posts that name — satisfying the guard
# for a job nobody reviewed. Validating advisory in (a) catches it at source.
D="$TMPROOT/e17"
mkrepo "$D" '{"required":[{"name":"alpha","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha"}],"advisory":[{"name":"Beta Check","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"ghost"}]}' "$WF_TWO_JOBS"
assert_exit "stale advisory entry is drift" 1 "$D"


echo "== E18: a lock name cannot inject a record separator into the classifier =="
# Lock content is repo-controlled. `awk -v` processes backslash escapes, so a
# name holding the literal four characters \036 would be split into TWO names
# inside awk, smuggling an extra entry into the classified set and passing a job
# nobody listed. Passing via ENVIRON hands the bytes over verbatim.
D="$TMPROOT/e18"
mkrepo "$D" '{"required":[{"name":"zzz\\036alpha","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"beta"}],"advisory":[]}' 'jobs:
  alpha:
    runs-on: ubuntu-latest
  beta:
    name: zzz\036alpha
    runs-on: ubuntu-latest
'
assert_exit "separator injection does not classify alpha" 1 "$D"
assert_mentions "alpha still reported unclassified" "'alpha'" "$D"


echo "== E19: a job whose FIRST body key is a mapping still resolves its name =="
# `permissions:` matches the job-key pattern too. Consuming such deeper keys with
# `next` let a CHILD (`contents: read`) set the body indent, so the job-level
# `name:` was read at the wrong level and silently ignored — the job then
# classified under its key instead of its real check name.
D="$TMPROOT/e19"
mkrepo "$D" '{"required":[{"name":"Cov","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"coverage"}],"advisory":[]}' 'jobs:
  coverage:
    permissions:
      contents: read
    name: Cov
    runs-on: ubuntu-latest
'
assert_exit "mapping-first job resolves its name" 0 "$D"


echo "== E20: a MIXED block+flow workflow has BOTH jobs demanded =="
# The dangerous shape for a line-oriented scanner: the block job made the file
# look non-empty while the flow job was silently dropped, so (e) never demanded
# it. Parsing the document removes the asymmetry entirely.
D="$TMPROOT/e20"
mkrepo "$D" '{"required":[{"name":"alpha","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha"}],"advisory":[]}' 'jobs:
  alpha:
    runs-on: ubuntu-latest
  beta: {runs-on: ubuntu-latest}
'
assert_exit "flow job in a mixed workflow is seen" 1 "$D"
assert_mentions "names the flow job" "'beta'" "$D"
echo "== E21: flow-style FIRST is seen too, not just flow-style later =="
D="$TMPROOT/e21"
mkrepo "$D" '{"required":[{"name":"alpha","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha"}],"advisory":[]}' 'jobs:
  beta: {runs-on: ubuntu-latest}
  alpha:
    runs-on: ubuntu-latest
'
assert_exit "flow-style first job is seen" 1 "$D"
assert_mentions "names the flow-style first job" "'beta'" "$D"
echo "== E22: an anchored job key is block style, not flow style =="
# `alpha: &base` is valid YAML whose mapping continues on the indented lines
# below, so it parses fine here. Treating "any token after the colon" as flow
# style rejected it outright; the job key must also be stripped of the anchor.
D="$TMPROOT/e22"
mkrepo "$D" '{"required":[{"name":"alpha","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha"}],"advisory":[]}' 'jobs:
  alpha: &base
    runs-on: ubuntu-latest
'
assert_exit "anchored job key accepted and stripped" 0 "$D"


echo "== E23: an ALIAS job is resolved, not refused =="
# `beta: *base` has no inline body — its content lives at the anchor. A real
# parser resolves it to a genuine job that posts a real check, so it must be
# classified like any other rather than skipped or refused.
D="$TMPROOT/e23"
mkrepo "$D" '{"required":[{"name":"alpha","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha"}],"advisory":[]}' 'jobs:
  alpha: &base
    runs-on: ubuntu-latest
  beta: *base
'
assert_exit "alias job is resolved and demanded" 1 "$D"
assert_mentions "names the alias job" "'beta'" "$D"

echo "== E24: genuinely malformed YAML still fails CLOSED =="
# The fail-closed path must survive the parser swap: a document that cannot be
# parsed at all must error, never yield an empty inventory that reads as
# "this repo has no checks" (#530 in miniature).
D="$TMPROOT/e24"
mkrepo "$D" '{"required":[],"advisory":[]}' 'jobs:
  alpha:
   - this: [is
'
assert_exit "malformed YAML rejected" 2 "$D"
assert_mentions "explains the parse failure" "cannot parse" "$D"
echo "== E25: an expression-bearing job name is REFUSED, not swapped for the key =="
# GitHub evaluates ${{ }} in jobs.<id>.name and posts the RENDERED name. Falling
# back to the job key would have every surface inspect a context that is never
# posted — (e) reporting a repo fully classified while the real check went
# unlisted. That is #530 exactly, so it must error instead.
D="$TMPROOT/e25"
# shellcheck disable=SC2016  # the ${{ }} must stay LITERAL — it is the
# GitHub expression syntax under test, not a shell expansion.
mkrepo "$D" '{"required":[],"advisory":[]}' 'jobs:
  alpha:
    name: build-${{ matrix.os }}
    runs-on: ubuntu-latest
'
assert_exit "expression job name rejected" 2 "$D"
assert_mentions "explains why it cannot resolve" "cannot be resolved statically" "$D"


echo "== E26: an UNQUOTED numeric job name is refused; the quoted form works =="
# GitHub formats numeric job names with .NET G15 (`1e20` -> `1E+20`), which
# String() does not reproduce — coercing would record a context never posted.
# Quoting is unambiguous and is what the lock must contain anyway.
D="$TMPROOT/e26a"
mkrepo "$D" '{"required":[{"name":"2024","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha"}],"advisory":[]}' 'jobs:
  alpha:
    name: 2024
    runs-on: ubuntu-latest
'
assert_exit "unquoted numeric name refused" 2 "$D"
assert_mentions "tells the author to quote it" "quote it" "$D"

D="$TMPROOT/e26b"
mkrepo "$D" '{"required":[{"name":"2024","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha"}],"advisory":[]}' 'jobs:
  alpha:
    name: "2024"
    runs-on: ubuntu-latest
'
assert_exit "quoted numeric name resolves" 0 "$D"

echo "== E27: a non-scalar job name is refused, not guessed at =="
# A bare `name:` parses as null. Silently using the job key there would invent a
# context; refuse instead.
D="$TMPROOT/e27"
mkrepo "$D" '{"required":[],"advisory":[]}' 'jobs:
  alpha:
    name:
    runs-on: ubuntu-latest
'
assert_exit "null name rejected" 2 "$D"
assert_mentions "explains the non-string name" "non-string name" "$D"


echo "== E28: a RAW control character in a lock name is rejected =="
# E18 covers the literal four characters \036. This is the real U+001E byte,
# which the classifier uses as its record separator — a name carrying one splits
# into two known names and classifies a job nobody listed. The lock is
# repo-controlled, so this is an injection into the guard.
D="$TMPROOT/e28"
RS_CHAR=$(printf '\036')
mkrepo "$D" "{\"required\":[{\"name\":\"zzz${RS_CHAR}alpha\",\"source_app\":\"github-actions\",\"workflow\":\".github/workflows/tests.yml\",\"job\":\"beta\"}],\"advisory\":[]}" "$WF_TWO_JOBS"
assert_exit "raw control character in lock name rejected" 2 "$D"
assert_mentions "explains the separator hazard" "control character" "$D"


echo "== E28b: a control character in a WORKFLOW job name is rejected =="
# E28 covers a raw U+001E in the *lock*; this covers the same byte in
# jobs.<id>.name — the enumerator must refuse it with the same rule the lock
# validator applies ([[:cntrl:]]), or a job named this way is demanded by
# surface (e) yet can never be satisfied by any lock entry. A raw control
# byte can't be used directly here (YAML itself refuses it in a scalar
# before the enumerator ever sees it) — a \u-escaped double-quoted scalar is
# how YAML represents the character, and js-yaml decodes it to the same
# U+001E the enumerator's regex must catch.
D="$TMPROOT/e28b"
mkrepo "$D" '{"required":[],"advisory":[]}' 'jobs:
  alpha:
    name: "zzz\u001Ealpha"
    runs-on: ubuntu-latest
'
assert_exit "control character in workflow job name rejected" 2 "$D"
assert_mentions "explains the control character" "control character" "$D"


echo "== E29: an EMPTY job name is refused, not silently skipped =="
# An empty name emits a row with an empty first field, and both (d) and (e) skip
# empty names — so the job would bypass the collision check AND the
# classification check at once. The widest fail-open available here.
D="$TMPROOT/e29"
mkrepo "$D" '{"required":[],"advisory":[]}' 'jobs:
  alpha:
    name: ""
    runs-on: ubuntu-latest
'
assert_exit "empty job name rejected" 2 "$D"
assert_mentions "explains the empty name" "empty name" "$D"


echo "== E30: matrix VALUES get the same rules as the job name =="
# The control-char and numeric-rendering rules were applied to the base name but
# not to matrix values — a value can shift TSV fields or name a context that is
# never posted just as easily.
D="$TMPROOT/e30a"
mkrepo "$D" '{"required":[{"name":"build (18)","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"build"},{"name":"build (20)","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"build"}],"advisory":[]}' 'jobs:
  build:
    strategy:
      matrix:
        node: [18, 20]
    runs-on: x
'
assert_exit "plain integer matrix values render exactly" 0 "$D"

# GitHub uses .NET G15: 1e20 posts `1E+20`, 1.10 posts `1.1`. String() matches
# neither, so both are refused rather than naming a phantom context.
for badnum in '1e20' '1.10'; do
  D="$TMPROOT/e30-$RANDOM"
  mkrepo "$D" '{"required":[],"advisory":[]}' "jobs:
  build:
    strategy:
      matrix:
        n: [$badnum]
    runs-on: x
"
  assert_exit "ambiguous numeric matrix value refused" 2 "$D"
done


echo "== E31: an oversized matrix is rejected BEFORE it is expanded =="
# Twenty dimensions of twenty values is 20^20 combinations — enough to exhaust
# memory inside the gate before any per-row check could reject it. GitHub caps a
# matrix at 256 jobs, so anything larger is not a runnable workflow anyway.
D="$TMPROOT/e31"
BIG=""
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  BIG="${BIG}        d${i}: [\"a\", \"b\", \"c\", \"d\", \"e\", \"f\", \"g\", \"h\", \"i\", \"j\", \"k\", \"l\", \"m\", \"n\", \"o\", \"p\", \"q\", \"r\", \"s\", \"t\"]
"
done
mkrepo "$D" '{"required":[],"advisory":[]}' "jobs:
  build:
    strategy:
      matrix:
${BIG}    runs-on: x
"
assert_exit "oversized matrix refused" 2 "$D"
assert_mentions "cites GitHub's 256 limit" "limit of 256" "$D"


echo "== E32: a static name on a matrix job is refused, not collapsed =="
# GitHub uses an explicit name verbatim, so every leg posts the SAME context.
# Appending the combination would invent contexts that are never posted;
# collapsing to one row would hide several check runs competing for one context
# name — the exact ambiguity surface (d) exists to catch. Neither is honest.
D="$TMPROOT/e32"
mkrepo "$D" '{"required":[],"advisory":[]}' 'jobs:
  build:
    name: Test
    strategy:
      matrix:
        node: [18, 20]
    runs-on: x
'
assert_exit "static name + matrix refused" 2 "$D"
assert_mentions "suggests the achievable remedy" "drop the" "$D"

echo "== E33: a reusable-workflow caller is refused, not named after the caller =="
# It posts one check per job of the CALLED workflow, `<caller> / <called job>`,
# and nothing under the caller name. Emitting the caller name would invent a
# context that is never posted while leaving the real ones unlisted.
D="$TMPROOT/e33"
mkrepo "$D" '{"required":[],"advisory":[]}' 'jobs:
  call:
    uses: ./.github/workflows/other.yml
'
assert_exit "reusable-workflow caller refused" 2 "$D"
assert_mentions "explains the caller/callee naming" "called job" "$D"


echo "== E32b: a SINGLE-leg named matrix is representable, not refused =="
# One combination means one check under that name — no competing contexts, so
# the enumerator can represent it exactly. Refusing it would be over-strict.
D="$TMPROOT/e32b"
mkrepo "$D" '{"required":[{"name":"Test","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"build"}],"advisory":[]}' 'jobs:
  build:
    name: Test
    strategy:
      matrix:
        node: [20]
    runs-on: x
'
assert_exit "single-leg named matrix accepted" 0 "$D"


echo "== E34: two lock entries may not share a name, even across apps =="
# A context has exactly ONE reporter. An external required entry and a
# github-actions advisory entry sharing a name let an Actions job classify
# itself against the external app's required context — (a), (d), (e) and even
# (b)'s name-set comparison all pass while the wrong producer owns the context.
D="$TMPROOT/e34"
mkrepo "$D" '{"required":[{"name":"Dup","source_app":"gitguardian"}],"advisory":[{"name":"Dup","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"beta"}]}' 'jobs:
  beta:
    name: Dup
    runs-on: x
'
assert_exit "cross-app duplicate name rejected" 2 "$D"
assert_mentions "explains one-reporter-per-context" "one reporter" "$D"


echo "== E35: the enumerator's control-char rule matches the lock validator's, every codepoint =="
# E28/E28b prove the rule fires on ONE example each. That is exactly the kind of
# coverage that let the bug this case exists for ship: the enumerator used an
# ASCII-only `[\x00-\x1f\x7f]` while the lock validator uses jq's `[[:cntrl:]]`,
# which is the Unicode Cc category and therefore ALSO covers C1 (U+0080-U+009F).
# A job named with U+0085 was accepted into the inventory but rejected from the
# lock — surface (e) demanding an entry surface (a) can never validate, i.e. an
# UNSATISFIABLE lock: CI red with no state that satisfies both.
#
# An example-based test cannot catch a whole-range disagreement, so sweep the
# entire byte domain (U+0000-U+00FF, which spans both control blocks and the
# printable region above them) and require the two predicates to agree EXACTLY,
# in both directions. Both sides are the real implementations — jq for the
# validator, the actual enumerator for the inventory — so neither can drift
# from a copy kept here.
#
# Cost ~2s: the accept side batches into a single run, but the reject side
# cannot, because the enumerator stops at the first offending job.
D="$TMPROOT/e35"
mkdir -p "$D/.github/workflows"
ln -sfn "$REPO_ROOT/node_modules" "$D/node_modules"
cat > "$D/sweep.cjs" <<'SWEEP'
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const [, , repoRoot, D] = process.argv;
const enumerator = path.join(repoRoot, "scripts", "lib", "list-workflow-checks.mjs");
const wf = path.join(D, ".github", "workflows", "w.yml");

const cps = [];
for (let i = 0; i <= 0xff; i++) cps.push(i);

// The lock validator's own predicate, one jq process. JSON.stringify emits the
// control characters as \u escapes, so the payload itself stays plain ASCII.
const jqIn = JSON.stringify(cps.map((i) => "x" + String.fromCodePoint(i) + "y"));
const rejects = JSON.parse(
  execFileSync("jq", ["-c", '[.[] | test("[[:cntrl:]]")]'], { input: jqIn, encoding: "utf8" }),
);

// A \u-escaped double-quoted scalar: YAML refuses a raw control byte before the
// enumerator sees it, and js-yaml decodes this to the real character.
const esc = (i) => "x\\u" + i.toString(16).padStart(4, "0") + "y";
const accept = cps.filter((i) => !rejects[i]);
const reject = cps.filter((i) => rejects[i]);
const fail = [];

// Accept side: everything jq tolerates must survive the enumerator. None of
// these should refuse, so they all fit in one workflow.
fs.writeFileSync(
  wf,
  "jobs:\n" + accept.map((i, n) => `  j${n}:\n    name: "${esc(i)}"\n`).join(""),
);
try {
  const rows = execFileSync("node", [enumerator, D], { encoding: "utf8" })
    .split("\n").filter(Boolean).length;
  if (rows !== accept.length) {
    fail.push(`accept batch: emitted ${rows} rows, expected ${accept.length}`);
  }
} catch (e) {
  fail.push(
    "accept batch: enumerator refused a codepoint jq tolerates — " +
      String(e.stderr || "").split("\n")[0],
  );
}

// Reject side, one per run. A refusal for a DIFFERENT reason (js-yaml declining
// the escape outright) still satisfies the invariant: what must never happen is
// the enumerator admitting a name the lock can never carry.
for (const i of reject) {
  fs.writeFileSync(wf, `jobs:\n  a:\n    name: "${esc(i)}"\n`);
  let refused = false;
  try {
    execFileSync("node", [enumerator, D], { stdio: "ignore" });
  } catch {
    refused = true;
  }
  if (!refused) {
    fail.push(
      `U+${i.toString(16).padStart(4, "0").toUpperCase()}: jq rejects it but the ` +
        "enumerator accepts it — unsatisfiable lock",
    );
  }
}

if (fail.length) {
  console.error(fail.join("\n"));
  process.exit(1);
}
console.log(`agreed on ${cps.length} codepoints (${accept.length} accepted, ${reject.length} refused)`);
SWEEP
if node "$D/sweep.cjs" "$REPO_ROOT" "$D" >"$D/out.txt" 2>&1; then
  PASS=$((PASS + 1)); echo "  ok   enumerator and lock validator agree ($(cat "$D/out.txt"))"
else
  FAIL=$((FAIL + 1)); echo "  FAIL control-char predicates disagree"; sed 's/^/       /' "$D/out.txt"
fi


echo "== E36: a YAML scalar that parses to an object is not read as an absent key =="
# js-yaml resolves `2026-01-01` to a Date and `!!binary` to a Uint8Array. Both
# satisfy `typeof v === "object" && !Array.isArray(v)` while carrying none of the
# keys the caller reads, so a malformed `strategy:` of that shape read as "no
# matrix" and the job emitted its bare name — a fail-OPEN in a file where every
# other unresolvable shape refuses.
#
# The lock below deliberately CLASSIFIES `alpha`, so the malformed job is
# invisible to every other surface: before the fix this repo exited 0, fully
# green, with the enumerator having silently guessed a name for a job whose
# strategy it could not read. An empty lock would have caught it as ordinary
# (e) drift and proved nothing about this hole.
LOCK_ALPHA='{"required":[],"advisory":[{"name":"alpha","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha"}]}'
D="$TMPROOT/e36"
mkrepo "$D" "$LOCK_ALPHA" 'jobs:
  alpha:
    strategy: 2026-01-01
    runs-on: ubuntu-latest
'
assert_exit "date-valued strategy rejected" 2 "$D"
assert_mentions "explains the non-mapping strategy" "non-mapping" "$D"

D="$TMPROOT/e36b"
mkrepo "$D" "$LOCK_ALPHA" 'jobs:
  alpha:
    strategy:
      matrix: 2026-01-01
    runs-on: ubuntu-latest
'
assert_exit "date-valued matrix rejected" 2 "$D"
# NOTE: the matrix refuse() message is "is not a mapping" (line ~205), not
# "non-mapping" like the sibling strategy check's "has a non-mapping
# 'strategy'" (line ~197) — different literal wording for the same defect
# class. Assert on the text the code actually emits.
assert_mentions "explains the non-mapping matrix" "not a mapping" "$D"


echo "== E37: a matrix VALUE that is not a scalar refuses, it does not render =="
# E36 covers an object-valued `strategy:`/`matrix:`; this covers an object-valued
# entry INSIDE a dimension list, which reaches a different guard — the non-string
# check in the labels() value mapper.
#
# That guard is load-bearing and was untested: the 68 assertions before this
# block ALL passed against a build with the `typeof v !== "string"` line deleted.
# Deleting it does not merely crash — for a value carrying its own `.includes`
# (a nested list, or the Uint8Array from `!!binary`) the mapper falls through to
# `return v` and JS stringifies it into the rendered name, emitting
# `alpha (a,b)` / `alpha (72,101,108,108,111)`. Those are contexts no workflow
# ever posts.
#
# Each case therefore gets a lock naming EXACTLY what the regressed build would
# emit (4th arg). That is the same trick as E36 and it is load-bearing here:
# with any other lock, surface (a) catches the phantom name as ordinary drift
# and the regression exits 1 — caught, but by a different guard, which would
# make this block pass for a reason unrelated to what it claims to test. With
# the phantom name classified, (a) and (e) are both satisfied and the regressed
# build exits 0, FULLY GREEN, on a repo whose real check name it never saw.
# That is #530's shape exactly, and it is what the exit-2 assertion pins down.
#
# The mapping/null/date cases have no rendered form to classify — the regressed
# build dies on `v.includes` instead. They keep the default lock and assert the
# same refusal; a crash is not a fail-open, but it is not a refusal either.
e37_case() {
  local label="$1" value="$2" slug="$3" phantom="${4:-alpha}" dir
  dir="$TMPROOT/e37-$slug"
  mkrepo "$dir" "{\"required\":[],\"advisory\":[{\"name\":\"$phantom\",\"source_app\":\"github-actions\",\"workflow\":\".github/workflows/tests.yml\",\"job\":\"alpha\"}]}" "jobs:
  alpha:
    runs-on: x
    strategy:
      matrix:
        os: [$value]
"
  assert_exit "$label" 2 "$dir"
  assert_mentions "explains the non-scalar $slug" "non-scalar value" "$dir"
}

e37_case "nested-list matrix value refused"    '[a, b]'            "list"    'alpha (a,b)'
e37_case "binary-scalar matrix value refused"  '!!binary SGVsbG8=' "binary"  'alpha (72,101,108,108,111)'
e37_case "nested-mapping matrix value refused" '{a: b}'            "mapping"
e37_case "null matrix value refused"           'null'              "null"
e37_case "date-scalar matrix value refused"    '2026-01-01'        "date"


echo
echo "passed: $PASS   failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
