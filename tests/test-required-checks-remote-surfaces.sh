#!/usr/bin/env bash
# tests/test-required-checks-remote-surfaces.sh — surfaces (c) and (f) of
# scripts/check-required-checks.sh (issue #648).
#
# (c) compares each required check's reporting app against the lock's
# source_app on the default branch; (f) asks whether each required context
# is reported by that app at all, across recently merged PR heads.
# Both need the GitHub API, so neither is covered by the --local-only suite
# in test-required-checks-lock-classification.sh. They are covered here by
# putting a stub `gh` on PATH that answers from fixture files — no network,
# no token, and the failure branches can actually be made to fire.
#
# The bug that motivated the file: (c) selected a sample commit on the rule
# "has any check-run at all". A `[skip ci]` release commit is not bare —
# CodeQL still posts `Analyze (…)` — so (c) picked one, found none of the
# required names on it, warned twelve times, and printed
#
#   ok: every required check is reported by its expected source app
#
# having examined nothing. That `ok` is what confirmed the (wrong) #631
# diagnosis under which a live required security check was removed from
# branch protection. R2/R3 below pin the shape; the rest pin the behaviour
# it was traded for.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/check-required-checks.sh"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
[[ -n "$TMPROOT" && -d "$TMPROOT" ]] || { echo "FAIL: TMPROOT invalid" >&2; exit 1; }
trap 'rm -rf "$TMPROOT"' EXIT

[[ -d "$REPO_ROOT/node_modules/js-yaml" ]] || {
  echo "FAIL: node_modules/js-yaml missing — run 'npm ci' first" >&2; exit 1; }

# ── the stub `gh` ───────────────────────────────────────────────────────────
# Answers the four call shapes the script makes, from files in $BD_FIXTURES.
# It applies the caller's own `--jq` filter with real jq rather than
# hardcoding each filter's output, so a change to what the script asks for
# surfaces as a test failure instead of being silently absorbed here.
STUB_DIR="$TMPROOT/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
set -u
FIX="${BD_FIXTURES:?stub gh: BD_FIXTURES unset}"

filter=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[i]}" == "--jq" ]] && filter="${args[i+1]:-}"
done

emit() {
  if [[ -n "$filter" ]]; then printf '%s' "$1" | jq -r "$filter"; else printf '%s\n' "$1"; fi
}

case "${1:-}" in
  pr)
    # prfail marker: the LIST call itself fails. Distinct from a per-head
    # check-runs failure (apifail.txt, covered by R13): this fails before
    # any head is even known, so the sample is empty AND incomplete.
    if [[ -f "$FIX/prfail" ]]; then
      echo "stub gh: simulated 'pr list' failure" >&2; exit 1
    fi
    # gh pr list --base <branch> --state merged --json headRefOid,mergedAt
    #
    # The --base assertion is the test for it: without it a PR merged into a
    # release branch could satisfy a required name that no longer runs
    # against the protected branch, and nothing here would notice the flag
    # going missing.
    case " $* " in
      *" --base main "*) ;;
      *) echo "stub gh: 'pr list' must be scoped with --base main; got: $*" >&2; exit 1 ;;
    esac
    # prheads.txt lines are '<sha> <mergedAt>'.
    heads=$(awk '{printf "{\"headRefOid\":\"%s\",\"mergedAt\":\"%s\"}\n", $1, $2}' "$FIX/prheads.txt" \
            | jq -sc '.')
    emit "$heads"
    ;;
  api)
    path="${2:-}"
    case "$path" in
      *"/protection/required_status_checks")
        emit "$(cat "$FIX/protection.json")" ;;
      *"/commits?sha="*)
        page="${path##*page=}"
        sha=$(sed -n "${page}p" "$FIX/commits.txt")
        if [[ -n "$sha" ]]; then emit "[{\"sha\":\"$sha\"}]"; else emit '[]'; fi ;;
      */commits/*/check-runs)
        sha="${path%/check-runs}"; sha="${sha##*/}"
        # apifail.txt lists shas the API should ERROR on — distinct from a
        # sha with no fixture, which returns a legitimately empty list.
        if [[ -f "$FIX/apifail.txt" ]] && grep -qxF -- "$sha" "$FIX/apifail.txt"; then
          echo "stub gh: simulated API failure for $sha" >&2; exit 1
        fi
        if [[ -f "$FIX/checkruns-$sha.json" ]]; then
          emit "{\"check_runs\": $(cat "$FIX/checkruns-$sha.json")}"
        else
          emit '{"check_runs": []}'
        fi ;;
      repos/*/*)
        emit '{"default_branch":"main"}' ;;
      *)
        echo "stub gh: unhandled api path '$path'" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "stub gh: unhandled command '${1:-}'" >&2; exit 1 ;;
esac
STUB
chmod +x "$STUB_DIR/gh"

# Two jobs, matching the lock every case below uses.
WF='jobs:
  alpha:
    runs-on: ubuntu-latest
  beta:
    name: Beta Check
    runs-on: ubuntu-latest
'
LOCK='{"required":[
  {"name":"alpha","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha"},
  {"name":"Beta Check","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"beta"}
],"advisory":[]}'

# Timestamps, computed at run time so the "fresh" fixtures can never age into
# the staleness branch as this file gets older. (f) dates a sighting by the
# CHECK-RUN, not by the PR merge, so these live on the runs.
FRESH=$(jq -rn 'now | todate')
STALE=$(jq -rn 'now - (400 * 86400) | todate')

# run <name> <app> [completed_at] renders one check-run object.
run() {
  printf '{"name":"%s","app":{"slug":"%s"},"started_at":"%s","completed_at":"%s"}' \
    "$1" "$2" "${3:-$FRESH}" "${3:-$FRESH}"
}

CODEQL_ONLY="[$(run 'Analyze (actions)' github-actions)]"
BOTH="[$(run alpha github-actions),$(run 'Beta Check' github-actions)]"
BOTH_STALE="[$(run alpha github-actions "$STALE"),$(run 'Beta Check' github-actions "$STALE")]"
ALPHA_ONLY="[$(run alpha github-actions)]"
ALPHA_ONLY_STALE="[$(run alpha github-actions "$STALE")]"
ALPHA_SPOOFED="[$(run alpha evil-app),$(run 'Beta Check' github-actions)]"

# mkcase <dir> — synthetic repo + empty fixture dir. Branch protection is
# derived FROM the lock so surface (b) is always ok and never contributes an
# exit code these cases would then have to explain away.
mkcase() {
  local d="$1"
  mkdir -p "$d/.github/workflows" "$d/scripts/lib" "$d/fix"
  printf '%s' "$LOCK" > "$d/.github/required-checks.lock"
  printf '%s' "$WF" > "$d/.github/workflows/tests.yml"
  cp "$SCRIPT" "$d/scripts/check-required-checks.sh"
  cp "$REPO_ROOT/scripts/lib/list-workflow-checks.mjs" "$d/scripts/lib/"
  ln -sfn "$REPO_ROOT/node_modules" "$d/node_modules"
  jq -c '{contexts: [.required[].name]}' "$d/.github/required-checks.lock" > "$d/fix/protection.json"
  : > "$d/fix/commits.txt"
  : > "$d/fix/prheads.txt"
}

# runcase <dir> [extra-args…] — invoke the script against the stub.
runcase() {
  local d="$1"; shift
  BD_FIXTURES="$d/fix" PATH="$STUB_DIR:$PATH" \
    bash "$d/scripts/check-required-checks.sh" --owner o --repo r "$@" \
    >"$d/out.txt" 2>&1
}

# prheads <sha> [mergedAt] — writes the one-PR sample for the current case.
# mergedAt drives only which heads are SAMPLED; the sighting dates come from
# the check-runs themselves.
prheads() { printf '%s %s\n' "$1" "${2:-$FRESH}" > "$D/fix/prheads.txt"; }

ok_()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad_()  { FAIL=$((FAIL + 1)); echo "  FAIL $1"; sed 's/^/       /' "$2"; }

assert_exit() {
  local name="$1" want="$2" got="$3" dir="$4"
  if [[ "$got" == "$want" ]]; then ok_ "$name (exit $got)"; else bad_ "$name — expected exit $want, got $got" "$dir/out.txt"; fi
}
assert_says() {
  local name="$1" needle="$2" dir="$3"
  if grep -qF -- "$needle" "$dir/out.txt"; then ok_ "$name"; else bad_ "$name — output did not mention '$needle'" "$dir/out.txt"; fi
}
assert_silent() {
  local name="$1" needle="$2" dir="$3"
  if grep -qF -- "$needle" "$dir/out.txt"; then bad_ "$name — output must NOT mention '$needle'" "$dir/out.txt"; else ok_ "$name"; fi
}

echo "== R1: the sample commit must CARRY a required check, not just any check =="
# c1 is the release-commit shape: `[skip ci]`, yet CodeQL still posted. The
# old predicate stopped there. The fixed one steps past it to c2.
D="$TMPROOT/r1"; mkcase "$D"
printf 'c1\nc2\n' > "$D/fix/commits.txt"
printf '%s' "$CODEQL_ONLY" > "$D/fix/checkruns-c1.json"
printf '%s' "$BOTH"        > "$D/fix/checkruns-c2.json"
prheads "c2"
runcase "$D"; assert_exit "clean repo passes" 0 $? "$D"
assert_says "walks past the CodeQL-only commit" "using commit: c2" "$D"
assert_says "verifies both required checks" "ok: all 2 required checks" "$D"

echo "== R2: #648 — nothing verifiable must NOT read as verified =="
D="$TMPROOT/r2"; mkcase "$D"
printf 'c1\n' > "$D/fix/commits.txt"
printf '%s' "$CODEQL_ONLY" > "$D/fix/checkruns-c1.json"
prheads "c1"
runcase "$D"; assert_exit "no verifiable commit is not drift by default" 0 $? "$D"
assert_says "says it could not verify" "carried a required check-run" "$D"
# The whole point of the issue. Matched on the fragment common to every
# wording of (c)'s ok line, present and past: pinning the current phrasing
# would let this assertion pass against the very build it exists to reject,
# whose message differed by one word.
assert_silent "never claims the source apps were verified" "expected source app" "$D"

echo "== R3: …and under --strict-remote it is drift =="
D="$TMPROOT/r3"; mkcase "$D"
printf 'c1\n' > "$D/fix/commits.txt"
printf '%s' "$CODEQL_ONLY" > "$D/fix/checkruns-c1.json"
prheads "c1"
runcase "$D" --strict-remote; assert_exit "unverifiable (c) fails closed under --strict-remote" 1 $? "$D"

echo "== R4: a PARTIAL sample reports its own coverage =="
# The normal state on the default branch: a PR-scoped app never posts there.
# `ok` must carry the count, or 1-of-2 verified reads exactly like 2-of-2.
D="$TMPROOT/r4"; mkcase "$D"
printf 'c1\n' > "$D/fix/commits.txt"
printf '%s' "$ALPHA_ONLY" > "$D/fix/checkruns-c1.json"
prheads "c1"
runcase "$D"
assert_says "counts what it actually checked" "ok: 1/2 required checks" "$D"
assert_says "names what it could not check" "unverified: Beta Check" "$D"

echo "== R5: a genuine source_app mismatch is still DRIFT =="
D="$TMPROOT/r5"; mkcase "$D"
printf 'c1\n' > "$D/fix/commits.txt"
printf '%s' "$ALPHA_SPOOFED" > "$D/fix/checkruns-c1.json"
prheads "c1"
runcase "$D"; assert_exit "wrong reporting app is drift" 1 $? "$D"
assert_says "names the unexpected reporter" "reported by 'evil-app'" "$D"

echo "== R6: (f) flags a required check nothing reports =="
# alpha reports; 'Beta Check' never does. Warn by default — an entry added
# after the sampled PRs merged is legitimately absent, and only the operator
# can tell that apart from an app that went dark.
D="$TMPROOT/r6"; mkcase "$D"
printf 'c1\n' > "$D/fix/commits.txt"
printf '%s' "$BOTH" > "$D/fix/checkruns-c1.json"
prheads "p1"
printf '%s' "$ALPHA_ONLY" > "$D/fix/checkruns-p1.json"
runcase "$D"; assert_exit "unreported required check warns by default" 0 $? "$D"
assert_says "names the unreported check" '- "Beta Check"' "$D"
runcase "$D" --strict-remote; assert_exit "…and is drift under --strict-remote" 1 $? "$D"

echo "== R7: (f) passes when every required check appears on a merged head =="
D="$TMPROOT/r7"; mkcase "$D"
printf 'c1\n' > "$D/fix/commits.txt"
printf '%s' "$BOTH" > "$D/fix/checkruns-c1.json"
prheads "p1"
printf '%s' "$BOTH" > "$D/fix/checkruns-p1.json"
runcase "$D"; assert_exit "live required checks pass" 0 $? "$D"
assert_says "reports liveness ok" "every required check was reported" "$D"

echo "== R8: (f) still runs when (c) found nothing to sample =="
# Different populations: the default branch telling us nothing is no reason
# to skip the surface that samples PR heads. (c) used to `exit` here.
D="$TMPROOT/r8"; mkcase "$D"
printf 'c1\n' > "$D/fix/commits.txt"
printf '%s' "$CODEQL_ONLY" > "$D/fix/checkruns-c1.json"
prheads "p1"
printf '%s' "$BOTH" > "$D/fix/checkruns-p1.json"
runcase "$D"; assert_exit "run completes" 0 $? "$D"
assert_says "(f) ran despite (c) having no sample" "every required check was reported" "$D"

echo "== R9: an AGED-OUT sample is not evidence about today =="
# The sample cannot refresh itself. If an app goes dark, branch protection
# blocks every PR, nothing new merges, and the frozen pre-outage heads all
# still carry the name — so presence alone would report ok forever.
D="$TMPROOT/r9"; mkcase "$D"
printf 'c1\n' > "$D/fix/commits.txt"
printf '%s' "$BOTH" > "$D/fix/checkruns-c1.json"
prheads "p1" "$STALE"
printf '%s' "$BOTH_STALE" > "$D/fix/checkruns-p1.json"
runcase "$D"
assert_says "says the sample is too old to mean anything" "older than 30 days" "$D"
assert_silent "does not report liveness ok" "every required check was reported" "$D"
runcase "$D" --strict-remote; assert_exit "aged-out sample is drift under --strict-remote" 1 $? "$D"

echo "== R10: (f) matches the REPORTER too, not just the name =="
# (c) never verifies a PR-scoped app's source_app — it samples the default
# branch, where such an app is absent by design. If (f) matched on the name
# alone, no surface anywhere would check that contract for those entries.
D="$TMPROOT/r10"; mkcase "$D"
printf 'c1\n' > "$D/fix/commits.txt"
printf '%s' "$BOTH" > "$D/fix/checkruns-c1.json"
prheads "p1"
printf '%s' "$ALPHA_SPOOFED" > "$D/fix/checkruns-p1.json"
runcase "$D"
assert_says "flags the name reported by the wrong app" 'expected source_app="github-actions"' "$D"
assert_silent "does not report liveness ok" "every required check was reported" "$D"

echo "== R11: an EMPTY required[] is nothing to verify, not a failure =="
# A legal lock — (b) handles the empty/empty case explicitly. The selection
# predicate matches no commit when there are no names, which must not read
# as "could not verify" under --strict-remote.
D="$TMPROOT/r11"; mkcase "$D"
printf '{"required":[],"advisory":[{"name":"alpha","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"alpha"},{"name":"Beta Check","source_app":"github-actions","workflow":".github/workflows/tests.yml","job":"beta"}]}' \
  > "$D/.github/required-checks.lock"
jq -c '{contexts: [.required[].name]}' "$D/.github/required-checks.lock" > "$D/fix/protection.json"
printf 'c1\n' > "$D/fix/commits.txt"
printf '%s' "$CODEQL_ONLY" > "$D/fix/checkruns-c1.json"
prheads "p1"
runcase "$D" --strict-remote; assert_exit "empty required[] is not drift" 0 $? "$D"
assert_says "says there was nothing to verify" "lock declares no required checks" "$D"

echo "== R12: freshness is dated PER CHECK, not once for the whole sample =="
# One fresh PR carrying `alpha` must not vouch for `Beta Check`, whose only
# sighting is 400 days old. A single summary date for the sample says both
# are current; only per-check dating catches the one that went dark.
D="$TMPROOT/r12"; mkcase "$D"
printf 'c1\n' > "$D/fix/commits.txt"
printf '%s' "$BOTH" > "$D/fix/checkruns-c1.json"
printf 'p1 %s\np2 %s\n' "$STALE" "$FRESH" > "$D/fix/prheads.txt"
printf '%s' "$BOTH_STALE" > "$D/fix/checkruns-p1.json"
printf '%s' "$ALPHA_ONLY" > "$D/fix/checkruns-p2.json"
runcase "$D"
assert_says "names the check whose evidence is old" "last reported $STALE" "$D"
assert_silent "does not report liveness ok" "ok: every required check" "$D"

echo "== R12b: the 10 sampled heads are chosen by mergedAt, not by API order =="
# `gh pr list` returns merged PRs in CREATED_AT order. With more merged PRs
# than the sample size, taking the API's first 10 would drop the one PR that
# actually merged recently — and every check would then read as stale.
D="$TMPROOT/r12b"; mkcase "$D"
printf 'c1\n' > "$D/fix/commits.txt"
printf '%s' "$BOTH" > "$D/fix/checkruns-c1.json"
: > "$D/fix/prheads.txt"
for i in 01 02 03 04 05 06 07 08 09 10 11; do
  printf 'p%s %s\n' "$i" "$STALE" >> "$D/fix/prheads.txt"
  printf '%s' "$BOTH_STALE" > "$D/fix/checkruns-p$i.json"
done
# Created last, merged today: API order puts it 12th, merge order puts it 1st.
printf 'p12 %s\n' "$FRESH" >> "$D/fix/prheads.txt"
printf '%s' "$BOTH" > "$D/fix/checkruns-p12.json"
runcase "$D"; assert_exit "recent merge is inside the window" 0 $? "$D"
assert_says "reads the fresh head, not the first ten" "oldest per-check sighting $FRESH" "$D"

echo "== R13: an unreadable head is not an empty head =="
# A failed Checks API call must not fold into "this head reported nothing" —
# the remaining heads can then supply every name and the run would report a
# sample it never finished reading.
D="$TMPROOT/r13"; mkcase "$D"
printf 'c1\n' > "$D/fix/commits.txt"
printf '%s' "$BOTH" > "$D/fix/checkruns-c1.json"
printf 'p1 %s\np2 %s\n' "$FRESH" "$FRESH" > "$D/fix/prheads.txt"
printf '%s' "$BOTH" > "$D/fix/checkruns-p1.json"
# p2 has no fixture AND the stub is told to fail on it, rather than return
# an empty check_runs list.
printf 'p2\n' > "$D/fix/apifail.txt"
runcase "$D"
assert_says "says the sample was incomplete" "could not read part of the merged-PR sample" "$D"
# The readable remainder held every required pair. That must not then be
# written up as `ok` — a partial pass and a clean pass are different claims.
assert_silent "does not issue a clean bill on a partial sample" "ok: every required check" "$D"
assert_says "qualifies what it did verify" "incomplete: every required check" "$D"
runcase "$D" --strict-remote; assert_exit "incomplete sample is drift under --strict-remote" 1 $? "$D"

echo "== R14b: a sighting is dated by the RUN, not by the merge =="
# A long-lived PR merged today can carry check-runs from months ago. Dating
# the sighting by the PR's mergedAt would turn one such run into today's
# proof of life for an app that has not posted since.
D="$TMPROOT/r14b"; mkcase "$D"
printf 'c1\n' > "$D/fix/commits.txt"
printf '%s' "$BOTH" > "$D/fix/checkruns-c1.json"
prheads "p1" "$FRESH"
printf '%s' "$BOTH_STALE" > "$D/fix/checkruns-p1.json"
runcase "$D"
assert_says "old runs on a fresh merge are still old" "older than 30 days" "$D"
assert_silent "no clean bill from a fresh merge date" "ok: every required check" "$D"

echo "== R15: a missing check and a stale one are BOTH reported =="
# They are independent per-check facts. Reporting only the first means the
# operator fixes it, re-runs, and only then learns about the second.
D="$TMPROOT/r15"; mkcase "$D"
printf 'c1\n' > "$D/fix/commits.txt"
printf '%s' "$BOTH" > "$D/fix/checkruns-c1.json"
prheads "p1"
printf '%s' "$ALPHA_ONLY_STALE" > "$D/fix/checkruns-p1.json"
runcase "$D"
assert_says "reports the absent check" '- "Beta Check"' "$D"
assert_says "reports the stale one in the same run" "last reported $STALE" "$D"

echo "== R14: a check-run NAME cannot forge a match =="
# Check-run names are chosen by whoever installed the app. If the seen-set
# were framed as text, a name carrying a newline plus a forged
# '<expected-app><TAB><required-name>' line would inject a matching record
# and certify a source_app that never posted. The comparison is done in JSON
# for exactly this reason.
D="$TMPROOT/r14"; mkcase "$D"
printf 'c1\n' > "$D/fix/commits.txt"
printf '%s' "$BOTH" > "$D/fix/checkruns-c1.json"
prheads "p1"
# One run, from the wrong app, whose NAME embeds the record a text-framed
# matcher would accept for 'Beta Check'.
printf '[{"name":"x\\ngithub-actions\\tBeta Check","app":{"slug":"evil-app"},"started_at":"2026-08-12T00:00:00Z"},%s]' \
  "$(run alpha github-actions)" > "$D/fix/checkruns-p1.json"
runcase "$D"
assert_says "the forged record does not satisfy 'Beta Check'" 'expected source_app="github-actions"' "$D"
assert_silent "no clean bill from a forged name" "ok: every required check" "$D"

echo "== R16: a fetched-but-empty head is 'cannot verify', not a list of dead checks =="
# p1 is fetched successfully (no apifail entry) but carries no fixture, so
# the stub returns an empty check_runs list — a head that WAS read, but
# contributed zero evidence. f_heads counts it (it was fetched), yet f_seen
# stays empty; the report must say "cannot verify" and must NOT also list
# every required check as unreported — that would restate "no evidence" as
# "these checks are dead", the #631 misreading this surface exists to stop.
D="$TMPROOT/r16"; mkcase "$D"
printf 'c1\n' > "$D/fix/commits.txt"
printf '%s' "$BOTH" > "$D/fix/checkruns-c1.json"
prheads "p1"
runcase "$D"
assert_says "says liveness could not be verified" "cannot verify liveness" "$D"
assert_silent "does not report liveness ok" "ok: every required check" "$D"
assert_silent "does not list required checks as unreported with zero evidence" '- "Beta Check"' "$D"
runcase "$D" --strict-remote; assert_exit "unverifiable (f) fails closed" 1 $? "$D"

echo "== R17: a failed 'pr list' is an incomplete sample, not an empty one =="
D="$TMPROOT/r17"; mkcase "$D"
printf 'c1\n' > "$D/fix/commits.txt"
printf '%s' "$BOTH" > "$D/fix/checkruns-c1.json"
: > "$D/fix/prfail"
runcase "$D"
assert_says "says the sample could not be read" "could not read part of the merged-PR sample" "$D"
assert_silent "does not report liveness ok" "ok: every required check" "$D"
runcase "$D" --strict-remote; assert_exit "unreadable sample is drift under --strict-remote" 1 $? "$D"

echo
echo "passed: $PASS   failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
