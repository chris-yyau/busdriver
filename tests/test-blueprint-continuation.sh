#!/usr/bin/env bash
# #948: accountable continuation of a stopped blueprint review.
#
# Drives the worktree's init-design-review.sh (the D2 init refusal and --continue) and
# the loop's start guards (D2, D8) against synthetic fixtures. Every fixture is its own
# mktemp repository with a pinned environment (design B3.5), asserted before any script
# runs, so nothing here can reach this repository's docs/reviews or STATE_DIR.
#
# Case numbers follow the design's "Test acceptance" list. Rounds after a continuation
# are SIMULATED (design "Full-round coverage" (b)): sim_round writes a fresh round's
# artifacts and runs the real loop under --claude-only. B3.2 runs the af80025 (2.6.5)
# closure and is skipped, by a mid-test SKIP line, where that commit is absent (a
# shallow clone). Not covered: the B3.3 SIGKILL table. Case 16 is the existing suites,
# run on their own.
# shellcheck disable=SC2312
# Each `expect` condition is a single-quoted string eval'd later, inside the case's
# subshell, so its variables are read there and not where shellcheck looks:
# shellcheck disable=SC2016,SC2034,SC2030,SC2031
set -uo pipefail
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD
INIT="$REPO/skills/blueprint-review/scripts/init-design-review.sh"
LOOP="$REPO/skills/blueprint-review/scripts/run-design-review-loop.sh"
LIB="$REPO/skills/blueprint-review/scripts/lib/state_management.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "SKIP: perl not installed (needed for the FIFO timeouts)"; exit 0; }

ROOT=$(mktemp -d) || exit 1
RES="$ROOT/results"
: > "$RES"
trap 'rm -rf "$ROOT"' EXIT
REAL_MKDIR=$(command -v mkdir)
REAL_CP=$(command -v cp)
REAL_MV=$(command -v mv)
REAL_JQ=$(command -v jq)

ok() { printf '  PASS  %s\n' "$1"; echo P >> "$RES"; }
no() { printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; echo F >> "$RES"; }
# expect <name> <shell condition> [detail]
expect() { if eval "$2"; then ok "$1"; else no "$1" "${3:-$2}"; fi; }

DESIGN=spec/demo.md   # not under docs/plans and not named PLAN/DESIGN: arms nothing
SLUG=demo
D="docs/reviews/$SLUG"
S="$D/state.md"

# ── Fixture: own repo, pinned environment, isolation asserted (B3.5) ──
# A fixture subshell that ends non-zero (a setup exit 99, a nounset abort) is a failure.
_fixture_exit() {
  local rc=$?
  [[ $rc -eq 0 ]] || { echo "  FAIL  fixture subshell exited $rc"; echo F >> "$RES"; }
}
new_fixture() {
  trap _fixture_exit EXIT
  # Before git init: an inherited GIT_DIR would point it at another repository.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
  local v
  for v in $(compgen -e | grep -E '^GIT_CONFIG_(KEY|VALUE)_' || true); do unset "$v"; done
  W=$(mktemp -d "$ROOT/fx.XXXXXX") || exit 99
  cd "$W" || exit 99
  git init -q . >/dev/null 2>&1 || exit 99
  mkdir -p home spec .claude docs/reviews
  printf '# Demo\n\nA design under review.\n' > "$DESIGN"
  export HOME="$W/home" BUSDRIVER_STATE_DIR=.claude
  export BUSDRIVER_PLUGIN_ROOT="$REPO" CLAUDE_PLUGIN_ROOT="$REPO" BLUEPRINT_COVERAGE_PROVENANCE=0
  local wp sd gc gd
  wp=$(pwd -P)
  sd=$(cd "$BUSDRIVER_STATE_DIR" && pwd -P)
  gd=$(git rev-parse --git-common-dir) && [[ -n "$gd" ]] || exit 99
  gc=$(cd "$gd" && pwd -P) || exit 99
  case "$sd/" in "$wp"/*) ;; *) echo "ISOLATION FAILURE: STATE_DIR $sd outside $wp"; exit 99 ;; esac
  case "$gc/" in "$wp"/*) ;; *) echo "ISOLATION FAILURE: git dir $gc outside $wp"; exit 99 ;; esac
}

# setf <file> <key> <value> — set or insert a frontmatter key; value __DEL__ removes it.
setf() {
  local file="$1" key="$2" val="$3"
  _V="$val" awk -v k="$key" '
    BEGIN { v = ENVIRON["_V"] }
    /^---$/ { n++; if (n == 2 && !done && v != "__DEL__") { print k ": " v; done = 1 } print; next }
    n == 1 && $0 ~ "^" k ":" { if (!done && v != "__DEL__") print k ": " v; done = 1; next }
    { print }' "$file" > "$file.t" && "$REAL_MV" "$file.t" "$file"
}
getf() {
  awk -v k="$2" '/^---$/ { y = !y; next } y && $0 ~ "^" k ":" { sub("^" k ": *", ""); gsub(/"/, ""); print; exit }' "$1"
}
old() { touch -t 200001010000 "$@"; }

# write_state <slug> <design> [key=value ...] — a #947-shaped trajectory park by default.
write_state() {
  local slug="$1" design="$2"
  shift 2
  local f="docs/reviews/$slug/state.md"
  "$REAL_MKDIR" -p "docs/reviews/$slug"
  cat > "$f" <<EOF
---
active: false
iteration: 2
max_iterations: 5
started_at: "2026-01-01T00:00:00Z"
design_file: "$design"
status: "parked_no_progress"
last_review_timestamp: "2026-01-01T00:00:00Z"
agy_status: "FAIL"
codex_status: "FAIL"
grok_status: "FAIL"
claude_status: "FAIL"
progress_status: "parked_no_progress"
high_issues: 0
medium_issues: 3
low_issues: 0
plan_blocking_high: 0
plan_blocking_medium: 3
deferred_issues: 0
high_issues_history: "[0,0]"
medium_issues_history: "[2,3]"
coverage_status: "FULL"
fulfilled_lens_count: 3
coverage_history: "[2,2,3,3]"
early_stopped: "no_improvement_trajectory"
---

# Design Review State
EOF
  local kv
  for kv in "$@"; do setf "$f" "${kv%%=*}" "${kv#*=}"; done
  old "$f"
}
# write_artifacts <slug> <run_id or empty>
write_artifacts() {
  local d="docs/reviews/$1" r
  for r in agy codex grok claude; do
    jq -n --arg rid "$2" '{status:"FAIL",issues:[],metadata:(if $rid == "" then {} else {run_id:$rid} end)}' > "$d/$r.json"
  done
  printf 'raw output\n' > "$d/codex-raw.txt"
  old "$d"/*
}
point() { printf '%s\n' "$1" > .claude/current-design-review.local; }
# snap [path ...]: every path, size and mode, plus every file's content hash (B3.4's
# form). Python rather than find -printf / sha256sum, so it also runs on macOS.
snap() {
  local args=("$@")
  [[ $# -gt 0 ]] || args=(docs .claude)
  python3 -I - "${args[@]}" <<'PY'
import hashlib, os, sys
seen = set()
def add(p):
    st = os.lstat(p)
    h = ""
    if os.path.isfile(p) and not os.path.islink(p):
        try:
            h = hashlib.sha256(open(p, "rb").read()).hexdigest()
        except OSError:
            h = "unreadable"
    # A directory's st_size is the filesystem's business (fixed on ext4, an entry count on
    # APFS and tmpfs), and its entries are listed on their own lines anyway (#1000).
    size = "-" if os.path.isdir(p) and not os.path.islink(p) else st.st_size
    seen.add(f"{p} {size} {oct(st.st_mode)} {h}")
for top in [a for a in sys.argv[1:] if a]:
    if not os.path.lexists(top):
        continue
    add(top)
    for dp, dns, fns in os.walk(top):
        for n in dns + fns:
            add(os.path.join(dp, n))
print("\n".join(sorted(seen)))
PY
}
hash256() { python3 -I -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
HASHERS=()
for t in sha256sum shasum; do command -v "$t" >/dev/null 2>&1 && HASHERS+=("$t"); done
# mverify <archive dir>: MANIFEST.sha256 verifies with every hash tool this box has.
mverify() {
  [[ ${#HASHERS[@]} -gt 0 ]] || return 1
  local t
  for t in "${HASHERS[@]}"; do
    case $t in
      sha256sum) (cd "$1" && sha256sum -c --quiet MANIFEST.sha256) || return 1 ;;
      shasum) (cd "$1" && shasum -a 256 -c --quiet MANIFEST.sha256 >/dev/null) || return 1 ;;
    esac
  done
}

# sim_files <run_id> <plan-blocking HIGH> <plan-blocking MEDIUM> [mode]: the artifacts of
# a SIMULATED completed full round in $D, for the design in $DESIGN. It clears the D8
# flag the way the round's cleanup does. Modes: degraded (grok's verdict missing),
# uncountable (the HIGHs carry no confidence: a write-site park), intake (.issues not
# an array: an intake park).
sim_files() {
  local rid="$1" nh="$2" nm="$3" mode="${4:-}" h it r iss st=FAIL conf='confidence:0.9,'
  local can=00112233445566778899aabbccddeeff
  setf "$S" fresh_round_required false
  h=$(hash256 "$DESIGN"); it=$(getf "$S" iteration)
  for r in agy codex grok; do
    jq -n --arg r "$r" --arg rid "$rid" --arg h "$h" --argjson it "$it" --arg c "$can" \
      '{status:"FAIL",reviewer_id:$r,issues:[],metadata:{run_id:$rid,spec_hash:$h,iteration:$it,input_canary:$c,input_canary_head:$c}}' > "$D/$r.json"
    jq -n --arg rid "$rid" --arg s "$r" --arg c "$can" \
      '{run_id:$rid,slot:$s,prompt_bytes_expected:100,prompt_bytes_sent:100,truncated:false,reasons:[],cli:$s,
        input_canary:$c,input_canary_head:$c,runner_path:"/runner.sh",runner_blob:"0123456789abcdef0123456789abcdef01234567",
        runner_closure:"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}' > "$D/$r-receipt.json"
  done
  printf '{"status":"PASS","issues":[]}\n' > "$D/agy-raw.txt"
  [[ $mode == degraded ]] && rm -f "$D/grok.json"
  [[ $mode == uncountable ]] && conf=''
  iss=$(jq -nc --argjson h "$nh" --argjson m "$nm" \
    "[range(\$h) | {severity:\"high\",${conf}section:\"S\",category:\"architecture\",description:\"d\",suggestion:\"s\"}]
     + [range(\$m) | {severity:\"medium\",confidence:0.9,section:\"S\",category:\"architecture\",description:\"d\",suggestion:\"s\"}]")
  [[ $mode == intake ]] && iss=false
  [[ "$iss" == "[]" ]] && st=PASS
  jq -n --arg st "$st" --arg rid "$rid" --arg h "$h" --argjson it "$it" --argjson iss "$iss" \
    '{status:$st,reviewer_id:"claude",validation_notes:"fixture",issues:$iss,metadata:{run_id:$rid,spec_hash:$h,iteration:$it}}' > "$D/claude.json"
}
# sim_round: sim_files, then the real loop (or $XLOOP) under --claude-only.
sim_round() { sim_files "$@"; OUT=$(bash "${XLOOP:-$LOOP}" --claude-only 2>&1 </dev/null); RC=$?; }
reviewed() { python3 -I "$REPO/hooks/gate-scripts/lib/marker_ops.py" reviewed "$1"; }

# The af80025 (2.6.5) closure for B3.2: the loop's own _BP_CLOSURE_DIRS, never the cache.
PRE="$ROOT/pre265"
if ( unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
     git -C "$REPO" cat-file -e 'af80025^{commit}' 2>/dev/null && mkdir -p "$PRE" &&
     git -C "$REPO" archive af80025 skills/blueprint-review scripts/lib hooks/gate-scripts/lib skills/dispatch-cli | tar -x -C "$PRE" ); then
  PRE_LOOP="$PRE/skills/blueprint-review/scripts/run-design-review-loop.sh"
  PRE_INIT="$PRE/skills/blueprint-review/scripts/init-design-review.sh"
else
  PRE=""
fi
cont() { OUT=$(bash "$INIT" --continue "$@" 2>&1); RC=$?; }
init_() { OUT=$(bash "$INIT" "$@" 2>&1); RC=$?; }
loop_() { OUT=$(bash "$LOOP" "$@" 2>&1 </dev/null); RC=$?; }
no_trace() {  # nothing of a continuation left behind
  [[ ! -e "$D/attempts" && ! -e "$D/.continue.lock" ]] && ! compgen -G "$D/state.md.continue.*" >/dev/null
}

echo "test-blueprint-continuation (#948)"

# ── Guard on the guard: an aborted fixture subshell is counted (then its probe mark dropped) ──
f0=$(grep -c F "$RES"); ( new_fixture; exit 7 ) >/dev/null; f1=$(grep -c F "$RES")
if [[ $f1 -gt $f0 ]]; then awk 'NR > 1 { print prev } { prev = $0 }' "$RES" > "$RES.t" && mv "$RES.t" "$RES"; fi
expect "an aborted fixture subshell is counted as a failure" '[[ $f1 -eq $((f0 + 1)) ]]'

# ── Guard on the guard: the snapshot comparison can fail ──
( new_fixture; write_state demo "$DESIGN"; a=$(snap); printf x >> "$S"; b=$(snap)
  expect "snapshot comparison detects a change" '[[ "$a" != "$b" ]]' )

# ── 1. Fresh init on a parked slug, all three variants ──
for variant in trajectory intake writesite; do
  ( new_fixture
    case $variant in
      trajectory) write_state demo "$DESIGN" ;;
      intake) write_state demo "$DESIGN" status='"uncountable_claude_output"' early_stopped='"arbiter_verdict_uncountable"' ;;
      writesite) write_state demo "$DESIGN" early_stopped='"arbiter_verdict_uncountable"' high_issues_history='"[3,0]"' ;;
    esac
    a=$(snap); init_ "$DESIGN"; b=$(snap)
    expect "1 init refused on $variant park" '[[ $RC -eq 1 && "$OUT" == *"--continue"* && "$a" == "$b" ]]' "rc=$RC" )
done
( new_fixture; write_state demo "$DESIGN" status='"passed"' progress_status='"passed"' early_stopped='""'
  init_ "$DESIGN"
  expect "1 control: init on a passed slug succeeds" '[[ $RC -eq 0 && "$(getf "$S" iteration)" == 1 ]]' "rc=$RC $OUT" )
( new_fixture; write_state demo "$DESIGN"
  write_state other spec/other.md active=true status='"IN_PROGRESS"' progress_status='"medium_issues_remaining"' early_stopped='""'
  point other
  printf '{"ts":"x","slug":"a","fulfilled_lens_count":2}\n%.0s' 1 2 3 > .claude/blueprint-coverage-trend.local
  a=$(snap); init_ "$DESIGN"; b=$(snap)
  expect "1 placement: refusal runs before stale cleanup and the coverage advisory" \
    '[[ $RC -eq 1 && "$a" == "$b" && ! -e .claude/blueprint-coverage-degraded.local ]]' "rc=$RC" )
# A design whose slug is the global lock's name would claim docs/reviews/.continue.lock itself.
( new_fixture; printf '# X\n\nx\n' > spec/.continue.lock.md; init_ spec/.continue.lock.md
  expect "1 reserved slug: init refuses .continue.lock and leaves no lock behind" \
    '[[ $RC -eq 1 && "$OUT" == *reserved* && ! -e docs/reviews/.continue.lock ]]' "rc=$RC $OUT"
  init_ "$DESIGN"
  expect "1 reserved slug control: a later init still runs" '[[ $RC -eq 0 ]]' "rc=$RC $OUT" )

# ── 2. Fresh init on a ceiling stop ──
( new_fixture; write_state demo "$DESIGN" status='"max_iterations_exceeded"' progress_status='"medium_issues_remaining"' early_stopped='""' iteration=5
  a=$(snap); init_ "$DESIGN"; b=$(snap)
  expect "2 init refused on a ceiling stop" '[[ $RC -eq 1 && "$OUT" == *"--max-iterations"* && "$a" == "$b" ]]' "rc=$RC" )

# ── 3. The loop on a park, a ceiling, or continuation leftovers ──
for mode in normal claude; do
  flag=(); [[ $mode == claude ]] && flag=(--claude-only)
  ( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r1; point demo
    a=$(snap); loop_ "${flag[@]}"; b=$(snap)
    expect "3 loop refuses a park ($mode)" '[[ $RC -eq 1 && "$OUT" == *PARKED* && "$a" == "$b" ]]' "rc=$RC" )
  ( new_fixture; write_state demo "$DESIGN" status='"max_iterations_exceeded"' progress_status='"medium_issues_remaining"' early_stopped='""' iteration=5
    write_artifacts demo r1; point demo; printf '{"x":1}\n' > .claude/blueprint-coverage-trend.local
    a=$(snap); loop_ "${flag[@]}"; b=$(snap)
    expect "3 loop refuses a ceiling re-run ($mode), no COVERAGE/trend write" '[[ $RC -eq 1 && "$a" == "$b" ]]' "rc=$RC" )
  for left in lock temp staging; do
    ( new_fixture; write_state demo "$DESIGN" status='"IN_PROGRESS"' active=true progress_status='"medium_issues_remaining"' early_stopped='""'
      write_artifacts demo r1; point demo
      case $left in
        lock) mkdir "$D/.continue.lock"; name=.continue.lock ;;
        temp) : > "$D/state.md.continue.4242"; name=state.md.continue.4242 ;;
        staging) mkdir -p "$D/attempts/.staging.4242"; name=.staging.4242 ;;
      esac
      a=$(snap); loop_ "${flag[@]}"; b=$(snap)
      expect "3 loop refuses leftover $left ($mode)" '[[ $RC -eq 1 && "$OUT" == *"$name"* && "$a" == "$b" ]]' "rc=$RC" )
  done
done
( new_fixture; write_state demo "$DESIGN" status='"degraded_coverage"' progress_status='"passed"' early_stopped='""'; point demo
  loop_ --claude-only
  expect "3 control: the loop on degraded_coverage gets past the guard" \
    '[[ "$OUT" != *PARKED* && "$OUT" != *"left these behind"* && "$OUT" == *"requires existing"* ]]' "$OUT" )

# ── 4. --continue on the #947-shaped trajectory fixture ──
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo 5d78af58
  printf 'note\n' > "$D/.notes"; mkdir "$D/extra"; printf 'x\n' > "$D/extra/inner"; old "$D/.notes"
  mkdir -p "$ROOT/c4.$$"; cp -p "$D"/* "$D/.notes" "$ROOT/c4.$$/" 2>/dev/null
  cont "$DESIGN"
  A="$D/attempts/001-5d78af58"
  expect "4 --continue succeeds" '[[ $RC -eq 0 ]]' "$OUT"
  expect "4 state values (D5 table)" '[[ "$(getf "$S" iteration)" == 3 && "$(getf "$S" max_iterations)" == 5
    && "$(getf "$S" high_issues_history)" == "[0,0]" && "$(getf "$S" medium_issues_history)" == "[2,3]"
    && "$(getf "$S" coverage_history)" == "[2,2,3,3]" && "$(getf "$S" progress_status)" == medium_issues_remaining
    && "$(getf "$S" fresh_round_required)" == true && "$(getf "$S" continuation_count)" == 1
    && "$(getf "$S" last_stop_reason)" == no_improvement_trajectory && "$(getf "$S" last_stop_run_id)" == 5d78af58
    && "$(getf "$S" status)" == IN_PROGRESS && "$(getf "$S" active)" == true && -z "$(getf "$S" early_stopped)"
    && "$(getf "$S" pre_park_recorded)" == false ]]'
  same=1; for f in "$ROOT/c4.$$"/* "$ROOT/c4.$$/.notes"; do cmp -s "$f" "$A/$(basename "$f")" || same=0; done
  expect "4 archive holds every top-level file byte-identical, dotfile included" '[[ $same -eq 1 ]]'
  expect "4 subdirectory not copied" '[[ ! -e "$A/extra" ]]'
  expect "4 manifest verifies (${HASHERS[*]})" 'mverify "$A"'
  expect "4 one ledger line with the exact values" '[[ $(wc -l < "$D/continuations.jsonl") -eq 1 ]] &&
    jq -e ".seq == 1 and .iteration_before == 2 and .iteration_after == 3 and .max_before == 5 and .max_after == 5
      and .stop_signal == \"park\" and .stop_run_id == \"5d78af58\" and .derivation_source == \"legacy_plan_blocking\"
      and .derived_progress_status == \"medium_issues_remaining\" and .dropped_high_placeholder == null
      and .medium_issues_history == [2,3]" "$D/continuations.jsonl" >/dev/null'
  expect "4 pointer names the target; no lock, staging or temp left" \
    '[[ "$(cat .claude/current-design-review.local)" == demo && ! -e "$D/.continue.lock" ]] && ! compgen -G "$D/state.md.continue.*" >/dev/null && ! compgen -G "$D/attempts/.staging.*" >/dev/null'
  expect "4 design doc untouched" '[[ "$(cat "$DESIGN")" == *"A design under review."* ]]' )
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo ""
  cont "$DESIGN"
  expect "4 no run_id: null in state and ledger, 001-unknown archive" '[[ $RC -eq 0 && "$(getf "$S" last_stop_run_id)" == null && -d "$D/attempts/001-unknown" ]] &&
    jq -e ".stop_run_id == null" "$D/continuations.jsonl" >/dev/null' "$OUT" )

# 4, hash lanes (F12): each lane of init's chain (shasum, sha256sum, python3) forced in
# turn by a PATH holding every command except the earlier lanes.
for lane in shasum sha256sum python3; do
  ( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r4l
    hide=(); case $lane in sha256sum) hide=(shasum) ;; python3) hide=(shasum sha256sum) ;; esac
    command -v "$lane" >/dev/null 2>&1 || { echo "  SKIP  4 hash lane $lane: not installed"; exit 0; }
    mkdir -p "$W/hb"
    IFS=: read -ra dirs <<<"$PATH"
    for d in "${dirs[@]}"; do [[ -d "$d" ]] && ln -s "$d"/* "$W/hb/" 2>/dev/null; done
    lane_ok=1
    for h in ${hide[@]+"${hide[@]}"}; do
      rm -f "$W/hb/$h"; PATH="$W/hb" command -v "$h" >/dev/null 2>&1 && lane_ok=0
    done
    expect "4 hash lane $lane: the earlier lanes are really hidden" '[[ $lane_ok -eq 1 ]]'
    OUT=$(PATH="$W/hb" "$BASH" "$INIT" --continue "$DESIGN" 2>&1); RC=$?
    expect "4 hash lane $lane: --continue succeeds and its manifest verifies (${HASHERS[*]})" \
      '[[ $RC -eq 0 ]] && mverify "$D/attempts/001-r4l"' "$OUT" )
done

# ── 5. --claude-only right after --continue (D8), and the null-sentinel control ──
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r5
  cont "$DESIGN"; a=$(snap); loop_ --claude-only; b=$(snap)
  expect "5 --claude-only refused after --continue, nothing changed" '[[ $RC -eq 1 && "$OUT" == *"must be a full one"* && "$a" == "$b" ]]' "rc=$RC"
  setf "$S" fresh_round_required false
  loop_ --claude-only
  expect "5 stop run_id refused even with the flag cleared" '[[ $RC -eq 1 && "$OUT" == *"stopped on"* ]]' "$OUT"
  write_artifacts demo fresh9
  loop_ --claude-only
  expect "5 control: a fresh run_id gets past both guards" '[[ "$OUT" != *"stopped on"* && "$OUT" != *"must be a full one"* ]]' )
( new_fixture; write_state demo "$DESIGN" status='"IN_PROGRESS"' active=true progress_status='"medium_issues_remaining"' early_stopped='""' \
    last_stop_run_id=null fresh_round_required=false
  write_artifacts demo null; point demo
  loop_ --claude-only
  expect "5 (S8) a literal null run_id is not matched against a null last_stop_run_id" '[[ "$OUT" != *"stopped on"* ]]' "$OUT" )

# ── 8. Write-site uncountable park ──
( new_fixture; write_state demo "$DESIGN" early_stopped='"arbiter_verdict_uncountable"' high_issues_history='"[3,0]"' plan_blocking_medium=0
  write_artifacts demo r8; cont "$DESIGN"
  expect "8 legacy: drops the placeholder, derives blocked_by_high_issues" '[[ $RC -eq 0 && "$(getf "$S" high_issues_history)" == "[3]"
    && "$(getf "$S" progress_status)" == blocked_by_high_issues ]] && jq -e ".dropped_high_placeholder == 0 and .derivation_source == \"legacy_high_history\"" "$D/continuations.jsonl" >/dev/null' "$OUT" )
( new_fixture; write_state demo "$DESIGN" early_stopped='"arbiter_verdict_uncountable"' high_issues_history='"[3,0]"' \
    pre_park_progress_status='"blocked_by_high_issues"' pre_park_recorded=true
  write_artifacts demo r8; cont "$DESIGN"
  expect "8 persisted: source persisted" '[[ $RC -eq 0 ]] && jq -e ".derivation_source == \"persisted\" and .derived_progress_status == \"blocked_by_high_issues\"" "$D/continuations.jsonl" >/dev/null' "$OUT" )
for marker in absent false; do
  ( new_fixture
    if [[ $marker == absent ]]; then
      write_state demo "$DESIGN" early_stopped='"arbiter_verdict_uncountable"' high_issues_history='"[3,0]"' pre_park_progress_status='"medium_issues_remaining"'
    else
      write_state demo "$DESIGN" early_stopped='"arbiter_verdict_uncountable"' high_issues_history='"[3,0]"' pre_park_progress_status='"medium_issues_remaining"' pre_park_recorded=false
    fi
    write_artifacts demo r8; cont "$DESIGN"
    expect "8 marker $marker: field ignored, legacy derivation" '[[ $RC -eq 0 ]] && jq -e ".derivation_source == \"legacy_high_history\"" "$D/continuations.jsonl" >/dev/null' "$OUT" )
done
( new_fixture; write_state demo "$DESIGN" early_stopped='"arbiter_verdict_uncountable"' high_issues_history='"[3,2]"'
  write_artifacts demo r8; a=$(snap); cont "$DESIGN"; b=$(snap)
  expect "8 a non-zero trailing entry is refused as inconsistent" '[[ $RC -eq 1 && "$OUT" == *inconsistent* && "$a" == "$b" ]]' "rc=$RC" )

# ── 9. Intake uncountable ──
( new_fixture; write_state demo "$DESIGN" status='"uncountable_claude_output"' early_stopped='"arbiter_verdict_uncountable"' \
    high_issues_history='"[2,2]"' plan_blocking_high=2
  write_artifacts demo r9; cont "$DESIGN"
  expect "9 intake: blocker from plan_blocking_*, nothing dropped" '[[ $RC -eq 0 && "$(getf "$S" high_issues_history)" == "[2,2]"
    && "$(getf "$S" progress_status)" == blocked_by_high_issues ]]' "$OUT" )

# ── 11. Refusals change nothing (I5) ──
refuse_case() {  # <name> <setup function> <continue args...>
  local name="$1" setup="$2"
  shift 2
  ( new_fixture; write_artifacts_ok=1; "$setup"
    a=$(snap); cont "$@"; b=$(snap)
    expect "11 refused: $name" '[[ $RC -eq 1 && "$a" == "$b" ]] && no_trace' "rc=$RC $OUT" )
}
s_active() { write_state demo "$DESIGN" status='"IN_PROGRESS"' active=true progress_status='"medium_issues_remaining"' early_stopped='""' last_review_timestamp="\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""; old "$S"; write_artifacts demo r; }
s_passed() { write_state demo "$DESIGN" status='"passed"' progress_status='"passed"' early_stopped='""'; write_artifacts demo r; }
s_degraded0() { write_state demo "$DESIGN" status='"degraded_coverage"' progress_status='"passed"' early_stopped='""' continuation_count=0; write_artifacts demo r; }
s_abandoned0() { write_state demo "$DESIGN" status='"ABANDONED"' progress_status='"medium_issues_remaining"' early_stopped='""'; write_artifacts demo r; }
s_park() { write_state demo "$DESIGN"; write_artifacts demo r; }
s_ceiling() { write_state demo "$DESIGN" status='"max_iterations_exceeded"' progress_status='"medium_issues_remaining"' early_stopped='""' iteration=5; write_artifacts demo r; }
s_full() { write_state demo "$DESIGN" iteration=4; write_artifacts demo r; }
s_symlink() { s_park; ln -s /etc/hostname "$D/link"; }
s_unreadable() { s_park; chmod 000 "$D/codex-raw.txt"; }
s_ptr_live() { s_park; write_state other spec/other.md status='"IN_PROGRESS"' active=true progress_status='""' early_stopped='""'; point other; }
s_ptr_stale() { s_ptr_live; }
s_ptr_await() { s_park; write_state other spec/other.md status='"awaiting_claude_validation"' progress_status='"medium_issues_remaining"' early_stopped='""'; point other; }
s_ptr_degraded() { s_park; write_state other spec/other.md status='"degraded_coverage"' progress_status='"passed"' early_stopped='""'; point other; }
s_ptr_passed() { s_park; write_state other spec/other.md status='"passed"' progress_status='"passed"' early_stopped='""'; point other; }
s_ptr_nostate() { s_park; point ghost; }
refuse_case "an active never-continued state" s_active "$DESIGN"
refuse_case "a passed state" s_passed "$DESIGN"
refuse_case "a never-continued degraded_coverage state" s_degraded0 "$DESIGN"
refuse_case "a never-continued ABANDONED state" s_abandoned0 "$DESIGN"
refuse_case "--max-iterations not higher" s_ceiling "$DESIGN" --max-iterations 5
refuse_case "--max-iterations not a number" s_ceiling "$DESIGN" --max-iterations abc
refuse_case "a positional N with --continue" s_park "$DESIGN" 7
refuse_case "a ceiling stop without --max-iterations" s_ceiling "$DESIGN"
refuse_case "a new iteration that would reach the ceiling" s_full "$DESIGN"
refuse_case "a symlink in the review directory" s_symlink "$DESIGN"
[[ $(id -u) -ne 0 ]] && refuse_case "an unreadable artifact" s_unreadable "$DESIGN"
refuse_case "pointer names another live review" s_ptr_live "$DESIGN"
refuse_case "pointer names another awaiting_claude_validation review" s_ptr_await "$DESIGN"
refuse_case "pointer names another degraded_coverage review" s_ptr_degraded "$DESIGN"
refuse_case "pointer names another passed review" s_ptr_passed "$DESIGN"
refuse_case "pointer names a slug with no state.md" s_ptr_nostate "$DESIGN"
( new_fixture; s_park; a=$(snap); OUT=$(bash "$INIT" "$DESIGN" --continue 2>&1); RC=$?; b=$(snap)
  expect "11 refused: --continue not first" '[[ $RC -eq 1 && "$a" == "$b" ]]' )
( new_fixture; s_park; DESIGN_REVIEW_STALE_HOURS=0.0001 refuse_case_inner=1
  write_state other spec/other.md status='"IN_PROGRESS"' active=true progress_status='""' early_stopped='""'; point other
  a=$(snap); DESIGN_REVIEW_STALE_HOURS=0.0001 cont "$DESIGN"; b=$(snap)
  expect "11 refused: pointer names another review that is stale but still runnable" '[[ $RC -eq 1 && "$a" == "$b" ]] && no_trace' )

# ── 12. Wrong-pointer safety ──
for sig in park ceiling; do
  ( new_fixture; write_state demo "$DESIGN"; write_artifacts demo target1
    if [[ $sig == park ]]; then write_state other spec/other.md
    else write_state other spec/other.md status='"max_iterations_exceeded"' progress_status='"medium_issues_remaining"' early_stopped='""'; fi
    write_artifacts other other999; point other
    before=$(hash256 docs/reviews/other/state.md); cont "$DESIGN"
    expect "12 other slug carrying the $sig signal: accepted, other untouched, target run_id" \
      '[[ $RC -eq 0 && "$(hash256 docs/reviews/other/state.md)" == "$before" && "$(cat .claude/current-design-review.local)" == demo
         && -d "$D/attempts/001-target1" && ! -e "$D/attempts/001-other999" ]]' "$OUT" )
done

# ── 13. Rollback on a handled failure ──
# release <pid>: free a FIFO-held process whether or not it reached its read; never hang.
# Not held: it is killed outright (init defers TERM), and the writer is reaped either way.
release() {
  printf 'go\n' > "$W/fifo" &
  local wp=$! rc
  [[ $held -eq 1 ]] || kill -KILL "$1" 2>/dev/null
  wait "$1"; rc=$?
  kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null
  return "$rc"
}
shim() {  # <name> <body> — a PATH shim that runs <body>, then the real command
  mkdir -p "$W/shim"
  printf '#!/bin/bash\n%s\n' "$2" > "$W/shim/$1"
  chmod +x "$W/shim/$1"
}
# live_shape: the B3.1 live-shaped fixture (2.6.5's state at iteration 3, 13 files, run 5d78af58).
live_shape() {
  write_state demo "$DESIGN" iteration=3 high_issues_history='"[1,0,0]"' medium_issues_history='"[3,3]"' coverage_history='"[3,3,2,2,3,3]"'
  write_artifacts demo 5d78af58
  local f
  for f in agy-raw.txt grok-raw.txt agy-receipt.json codex-receipt.json grok-receipt.json claude-validation-prompt.txt follow-up-issues.md; do
    printf '%s\n' "$f" > "$D/$f"
  done
  old "$D"/*
}
# Case 13 runs on the #947 shape and, as B3.4, on the live shape.
for shape in default live; do
for point_ in copy claim commit; do
  ( new_fixture; point demo
    if [[ $shape == live ]]; then live_shape; else write_state demo "$DESIGN"; write_artifacts demo r13; fi
    a=$(snap); base_ptr=$(cat .claude/current-design-review.local)
    case $point_ in
      copy) shim cp "$REAL_MKDIR -p \"$W/$D/attempts/.staging.99999\"; touch \"$W/reached\"; exit 1" ;;
      claim) shim mkdir "case \"\$1\" in */attempts/0??-*) touch \"$W/reached\"; exit 1;; esac; exec $REAL_MKDIR \"\$@\"" ;;
      commit) shim mv "case \"\$2\" in */demo/state.md) touch \"$W/reached\"; exit 1;; esac; exec $REAL_MV \"\$@\"" ;;
    esac
    OUT=$(PATH="$W/shim:$PATH" bash "$INIT" --continue "$DESIGN" 2>&1); RC=$?
    rm -f "$W/shim"/* ; b=$(snap)
    tag="13 rollback at $point_ ($shape)"; [[ $shape == live ]] && tag="B3.4 $tag"
    expect "$tag: injection reached" '[[ -e "$W/reached" ]]'
    if [[ $point_ == copy ]]; then
      expect "$tag: state and pointer unchanged, foreign staging survives, nothing of ours left" \
        '[[ $RC -eq 1 && "$(cat .claude/current-design-review.local)" == "$base_ptr" && -d "$D/attempts/.staging.99999" ]] &&
         [[ "$(grep -v "attempts" <<<"$a")" == "$(grep -v "attempts" <<<"$b")" ]] && [[ ! -e "$D/.continue.lock" ]] && ! compgen -G "$D/state.md.continue.*" >/dev/null' "$OUT"
    else
      expect "$tag: byte-identical, no trace" '[[ $RC -eq 1 && "$a" == "$b" ]] && no_trace' "$OUT"
    fi )
done
done
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r13
  shim jq "case \"\$*\" in *-nc*) exit 1;; esac; exec $REAL_JQ \"\$@\""
  OUT=$(PATH="$W/shim:$PATH" bash "$INIT" --continue "$DESIGN" 2>&1); RC=$?
  expect "13 step-4 failure: committed state, archive without a ledger line, lock kept, exit 1" \
    '[[ $RC -eq 1 && "$(getf "$S" continuation_count)" == 1 && -d "$D/attempts/001-r13" && ! -e "$D/continuations.jsonl" && -d "$D/.continue.lock" ]]' "$OUT"
  rm -f "$W/shim/jq"; loop_
  expect "13 step-4 failure: the loop then refuses (D2)" '[[ $RC -eq 1 && "$OUT" == *".continue.lock"* ]]' )

# ── 14. Ceiling raise ──
( new_fixture; write_state demo "$DESIGN" status='"max_iterations_exceeded"' progress_status='"medium_issues_remaining"' early_stopped='""' iteration=5
  write_artifacts demo r14; cont "$DESIGN" --max-iterations 7
  expect "14 ceiling raise: max 7, iteration kept, reason recorded, ledger 5->7" '[[ $RC -eq 0 && "$(getf "$S" max_iterations)" == 7 && "$(getf "$S" iteration)" == 5
    && "$(getf "$S" last_stop_reason)" == max_iterations_exceeded ]] && jq -e ".max_before == 5 and .max_after == 7" "$D/continuations.jsonl" >/dev/null' "$OUT" )

# ── 15. Two continuations in a row (with the park in between) ──
( new_fixture; write_state demo "$DESIGN" iteration=1 high_issues_history='"[0]"' medium_issues_history='"[3]"'; write_artifacts demo r15a
  cont "$DESIGN"; rc1=$RC
  setf "$S" status '"parked_no_progress"'; setf "$S" progress_status '"parked_no_progress"'
  setf "$S" early_stopped '"no_improvement_trajectory"'; setf "$S" active false; old "$S"
  write_artifacts demo r15b; cont "$DESIGN"
  expect "15 two continuations: 001 and 002, ledger 2 lines, count 2, iteration 1->2->3" \
    '[[ $rc1 -eq 0 && $RC -eq 0 && -d "$D/attempts/001-r15a" && -d "$D/attempts/002-r15b" && ! -e "$D/attempts/002-r15b/continuations.jsonl"
       && $(wc -l < "$D/continuations.jsonl") -eq 2 && "$(getf "$S" continuation_count)" == 2 && "$(getf "$S" iteration)" == 3 ]] &&
     jq -s -e "length == 2 and .[0].seq == 1 and .[1].seq == 2" "$D/continuations.jsonl" >/dev/null' "$OUT" )

# ── 18. Non-blocking predecessor ──
( new_fixture; write_state demo "$DESIGN" early_stopped='"arbiter_verdict_uncountable"' high_issues_history='"[2,0,0]"' medium_issues_history='"[3,3]"' \
    pre_park_progress_status='""' pre_park_recorded=true
  write_artifacts demo r18; cont "$DESIGN"
  expect "18 drops one 0 and derives \"\" from the persisted field" '[[ $RC -eq 0 && "$(getf "$S" high_issues_history)" == "[2,0]" && -z "$(getf "$S" progress_status)" ]]' "$OUT" )
( new_fixture; write_state demo "$DESIGN" early_stopped='"arbiter_verdict_uncountable"' high_issues_history='"[2,0,0]"' pre_park_progress_status='"passed"' pre_park_recorded=true
  write_artifacts demo r18; a=$(snap); cont "$DESIGN"; b=$(snap)
  expect "18 an out-of-range stored value is refused, never filtered" '[[ $RC -eq 1 && "$a" == "$b" ]] && no_trace' )
for legacy in absent false stacked; do
  ( new_fixture
    case $legacy in
      absent) write_state demo "$DESIGN" early_stopped='"arbiter_verdict_uncountable"' high_issues_history='"[2,0,0]"' ;;
      false) write_state demo "$DESIGN" early_stopped='"arbiter_verdict_uncountable"' high_issues_history='"[2,0,0]"' pre_park_progress_status='""' pre_park_recorded=false ;;
      stacked) write_state demo "$DESIGN" early_stopped='"arbiter_verdict_uncountable"' high_issues_history='"[3,0,0]"' ;;
    esac
    write_artifacts demo r18; a=$(snap); cont "$DESIGN"; b=$(snap)
    expect "18 legacy ($legacy): ambiguous_legacy_history, nothing changed" '[[ $RC -eq 1 && "$OUT" == *ambiguous_legacy_history* && "$a" == "$b" ]] && no_trace' "rc=$RC" )
done

# ── 19. Same document ──
( new_fixture; mkdir -p docs/plans other; printf '# x\n' > docs/plans/2026-02-02-demo.md; printf '# x\n' > other/demo.md
  write_state demo "$DESIGN"; write_artifacts demo r19
  a=$(snap); cont docs/plans/2026-02-02-demo.md; b=$(snap)
  expect "19 another date prefix refused, naming both" '[[ $RC -eq 1 && "$OUT" == *"$DESIGN"* && "$OUT" == *2026-02-02-demo.md* && "$a" == "$b" ]]'
  cont other/demo.md
  expect "19 another directory refused" '[[ $RC -eq 1 ]] && no_trace'
  init_ docs/plans/2026-02-02-demo.md
  expect "19 fresh init with the other file: slug held by a stopped review" '[[ $RC -eq 1 && "$OUT" == *"held by a stopped review"* ]]'
  cont "./$DESIGN"
  expect "19 control: ./spec/demo.md matches spec/demo.md" '[[ $RC -eq 0 ]]' "$OUT" )

# ── 20. A continued review cannot be reset (I2) ──
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r20; cont "$DESIGN"
  rm -f .claude/current-design-review.local; a=$(snap); init_ "$DESIGN"; b=$(snap)
  expect "20a rm pointer then fresh init: refused" '[[ $RC -eq 1 && "$a" == "$b" ]]' )
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r20; cont "$DESIGN"
  setf "$S" last_review_timestamp '"2000-01-01T00:00:00Z"'; old "$S"
  printf '# o\n' > spec/other.md
  DESIGN_REVIEW_STALE_HOURS=0.0001 init_ spec/other.md
  expect "20b another init stale-abandons the continued review" '[[ $RC -eq 0 && "$(getf "$S" status)" == ABANDONED ]]' "$OUT"
  init_ "$DESIGN"
  expect "20b fresh init of the continued file is refused" '[[ $RC -eq 1 ]]'
  old "$S"; cont "$DESIGN"
  expect "20b negative: refused while the other review is live (check 8)" '[[ $RC -eq 1 && "$OUT" == *other* ]]'
  setf docs/reviews/other/state.md status '"passed"'; setf docs/reviews/other/state.md active false; old docs/reviews/other/state.md
  cont "$DESIGN"
  expect "20b negative: refused while the pointer names the completed other review" '[[ $RC -eq 1 && "$OUT" == *other* ]]'
  setf docs/reviews/other/state.md progress_status '"parked_no_progress"'; setf docs/reviews/other/state.md status '"parked_no_progress"'
  old docs/reviews/other/state.md
  cont "$DESIGN"
  expect "20b accepted once the other review is parked: iteration and histories kept, reason ABANDONED" \
    '[[ $RC -eq 0 && "$(getf "$S" iteration)" == 3 && "$(getf "$S" medium_issues_history)" == "[2,3]" && "$(getf "$S" last_stop_reason)" == ABANDONED ]]' "$OUT" )
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r20; cont "$DESIGN"
  cont "$DESIGN"
  expect "20c pointer still names it: told to run the loop" '[[ $RC -eq 1 && "$OUT" == *"the loop resumes this review"* ]]'
  rm -f .claude/current-design-review.local; cont "$DESIGN"
  expect "20c pointer removed, still fresh: told to wait until stale" '[[ $RC -eq 1 && "$OUT" == *"active within DESIGN_REVIEW_STALE_HOURS"* ]] && [[ ! -e "$D/attempts/002-r20" ]]' )
( new_fixture; write_state demo "$DESIGN" status='"ABANDONED"' progress_status='"medium_issues_remaining"' early_stopped='""'
  init_ "$DESIGN"
  expect "20 control: a never-continued ABANDONED slug is re-initialised as today" '[[ $RC -eq 0 && "$(getf "$S" iteration)" == 1 ]]' )

# ── 21. Lock, leftovers and publication ──
for left in lock temp staging; do
  ( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r21
    case $left in
      lock) mkdir "$D/.continue.lock"; name=.continue.lock ;;
      temp) : > "$D/state.md.continue.4242"; name=state.md.continue.4242 ;;
      staging) mkdir -p "$D/attempts/.staging.4242"; name=.staging.4242 ;;
    esac
    a=$(snap); cont "$DESIGN"; b=$(snap)
    expect "21 leftover $left refused by name, nothing changed" '[[ $RC -eq 1 && "$OUT" == *"$name"* && "$a" == "$b" ]]' )
done
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r21; mkdir -p "$D/attempts/001-x"
  cont "$DESIGN"
  expect "21 numbering: a pre-seeded 001 advances to 002" '[[ $RC -eq 0 && -d "$D/attempts/002-r21" && -d "$D/attempts/001-x" ]]' "$OUT" )
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r21
  shim mkdir "case \"\$1\" in */attempts/0??-*) $REAL_MKDIR \"\$1\"; touch \"\$1/planted\";; esac; exec $REAL_MKDIR \"\$@\""
  OUT=$(PATH="$W/shim:$PATH" bash "$INIT" --continue "$DESIGN" 2>&1); RC=$?
  expect "21 a destination appearing after numbering is refused, its contents untouched, nothing nested" \
    '[[ $RC -eq 1 && -f "$D/attempts/001-r21/planted" && $(ls -A "$D/attempts/001-r21" | wc -l) -eq 1 && "$(getf "$S" continuation_count)" == "" ]]' "$OUT" )
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r21
  bash "$INIT" --continue "$DESIGN" >"$W/o1" 2>&1 & p1=$!
  bash "$INIT" --continue "$DESIGN" >"$W/o2" 2>&1 & p2=$!
  wait $p1; r1=$?; wait $p2; r2=$?
  expect "21 two concurrent --continue: exactly one commits" '[[ $((r1 + r2)) -eq 1 && "$(getf "$S" continuation_count)" == 1
    && $(wc -l < "$D/continuations.jsonl") -eq 1 && $(ls "$D/attempts" | wc -l) -eq 1 ]]' \
    "r1=$r1 r2=$r2 | o1: $(tail -n 3 "$W/o1" | tr '\n' ' ') | o2: $(tail -n 3 "$W/o2" | tr '\n' ' ')" )

# ── 22. No dead ends (I6) ──
for st in awaiting_claude_validation stale_claude_output invalid_claude_output ABANDONED degraded_coverage error_no_design_file; do
  for pred in blocked_by_high_issues medium_issues_remaining; do
    for ptrmode in parked_other none; do
      ( new_fixture
        carried=$pred; want=$pred
        case $st in degraded_coverage|error_no_design_file) carried=passed; want="" ;; esac
        write_state demo "$DESIGN" status="\"$st\"" progress_status="\"$carried\"" early_stopped='""' continuation_count=1
        write_artifacts demo r22
        if [[ $ptrmode == parked_other ]]; then write_state other spec/other.md; point other; fi
        init_ "$DESIGN"; irc=$RC; old "$S"
        cont "$DESIGN"
        expect "22 $st ($pred, pointer $ptrmode): init refused, --continue carries '${want}'" \
          '[[ $irc -eq 1 && $RC -eq 0 && "$(getf "$S" iteration)" == 2 && "$(getf "$S" last_stop_reason)" == "$st"
             && "$(getf "$S" fresh_round_required)" == true && "$(getf "$S" progress_status)" == "$want" ]] &&
           jq -e ".derivation_source == \"carried\"" "$D/continuations.jsonl" >/dev/null' "$OUT" )
    done
  done
done
( new_fixture; write_state demo "$DESIGN" status='"awaiting_claude_validation"' progress_status='"medium_issues_remaining"' early_stopped='""' continuation_count=1
  write_artifacts demo r22; point demo; a=$(snap); cont "$DESIGN"; b=$(snap)
  expect "22 control: pointer still names it, told to run the loop, nothing changed" '[[ $RC -eq 1 && "$OUT" == *"the loop resumes this review"* && "$a" == "$b" ]]' )
( new_fixture; write_state demo "$DESIGN" status='"passed"' progress_status='"passed"' early_stopped='""' continuation_count=1
  init_ "$DESIGN"
  expect "22 control: a continued passed review is re-initialised as today" '[[ $RC -eq 0 ]]' )

# ── 23. The pre-park write lands ──
( new_fixture; init_ "$DESIGN"
  expect "23 a fresh repaired init emits both keys" "grep -q '^pre_park_progress_status: \"\"' \"$S\" && grep -q '^pre_park_recorded: false' \"$S\""
  setf "$S" pre_park_progress_status __DEL__; setf "$S" pre_park_recorded __DEL__
  # shellcheck source=skills/blueprint-review/scripts/lib/state_management.sh
  ( set +e; source "$LIB"; set +e; record_pre_park medium_issues_remaining )
  expect "23 _ensure_pre_park_fields inserts both keys on a legacy state" \
    "grep -q '^pre_park_progress_status: \"medium_issues_remaining\"' \"$S\" && grep -q '^pre_park_recorded: true' \"$S\""
  setf "$S" pre_park_progress_status __DEL__; setf "$S" pre_park_recorded __DEL__
  # shellcheck source=skills/blueprint-review/scripts/lib/state_management.sh disable=SC2317
  ( set +e; source "$LIB"; set +e; _ensure_pre_park_fields() { :; }; record_pre_park medium_issues_remaining )
  expect "23 negative control: with the insert stubbed out the keys stay absent" "! grep -q '^pre_park_recorded:' \"$S\"" )
( new_fixture; write_state demo "$DESIGN" pre_park_progress_status='"medium_issues_remaining"' pre_park_recorded=true; write_artifacts demo r23
  cont "$DESIGN"
  expect "23 after --continue both keys are present as \"\" and false" '[[ $RC -eq 0 ]] && grep -q "^pre_park_progress_status: \"\"" "$S" && grep -q "^pre_park_recorded: false" "$S"' )

# ── 24. Archive numbering survives a re-init ──
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r24a; cont "$DESIGN"
  setf "$S" status '"passed"'; setf "$S" progress_status '"passed"'; setf "$S" active false
  init_ "$DESIGN"; rc_init=$RC
  write_state demo "$DESIGN"; write_artifacts demo r24b; cont "$DESIGN"
  expect "24 after a re-init the next archive is 002 and the ledger seq 2" '[[ $rc_init -eq 0 && $RC -eq 0 && -d "$D/attempts/002-r24b" ]] &&
    [[ "$(tail -n 1 "$D/continuations.jsonl" | jq .seq)" == 2 ]]' "$OUT" )

# ── 25. A runnable other review is never redirected (refusal half) ──
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r25
  write_state other spec/other.md status='"awaiting_claude_validation"' progress_status='"medium_issues_remaining"' early_stopped='""'; point other
  a=$(snap); cont "$DESIGN"; b=$(snap)
  expect "25 pointer on an inactive but runnable review: refused naming it, nothing changed" '[[ $RC -eq 1 && "$OUT" == *other* && "$a" == "$b" ]]' )
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r25; write_state other spec/other.md; point other
  touch docs/reviews/other/state.md; cont "$DESIGN"
  expect "25 (tail window) a just-parked other review is refused until quiet" '[[ $RC -eq 1 && "$OUT" == *"stopped less than"* ]] && no_trace' )

# ── B3.1 Live-shaped fixture ──
( new_fixture; live_shape
  [[ $(find "$D" -maxdepth 1 -type f | wc -l) -eq 13 ]] || no "B3.1 fixture has 13 files" "$(ls "$D")"
  claude_before=$(hash256 "$D/claude.json")
  cont "$DESIGN"
  A="$D/attempts/001-5d78af58"
  expect "B3.1 live shape: iteration 4, histories byte-equal, legacy_plan_blocking medium" \
    '[[ $RC -eq 0 && "$(getf "$S" iteration)" == 4 && "$(getf "$S" high_issues_history)" == "[1,0,0]" && "$(getf "$S" medium_issues_history)" == "[3,3]"
       && "$(getf "$S" coverage_history)" == "[3,3,2,2,3,3]" && "$(getf "$S" progress_status)" == medium_issues_remaining
       && "$(getf "$S" last_stop_run_id)" == 5d78af58 ]] && jq -e ".derivation_source == \"legacy_plan_blocking\"" "$D/continuations.jsonl" >/dev/null' "$OUT"
  expect "B3.1 archive: 13 files plus a manifest that verifies" '[[ $(ls -A "$A" | wc -l) -eq 14 ]] && mverify "$A"'
  point demo; loop_ --claude-only
  expect "B3.1 --claude-only refused right after; claude.json unchanged" '[[ $RC -eq 1 && "$(hash256 "$D/claude.json")" == "$claude_before" ]]' )
for med in 3 2; do
  ( new_fixture; live_shape; cont "$DESIGN"; sim_round r4sim 0 "$med"
    if [[ $med == 3 ]]; then
      expect "B3.1 simulated round 4, MED 3: [3,3,3], parks, iteration stays 4" \
        '[[ $RC -ne 0 && "$(getf "$S" medium_issues_history)" == "[3,3,3]" && "$(getf "$S" progress_status)" == parked_no_progress && "$(getf "$S" iteration)" == 4 ]]' "$OUT"
      old "$S"; cont "$DESIGN"
      expect "B3.1 then --continue without --max-iterations is refused (check 7)" '[[ $RC -eq 1 && "$OUT" == *max-iterations* ]]' "$OUT"
      cont "$DESIGN" --max-iterations 6
      expect "B3.1 with --max-iterations 6 it is accepted at iteration 5" '[[ $RC -eq 0 && "$(getf "$S" iteration)" == 5 && "$(getf "$S" max_iterations)" == 6 ]]' "$OUT"
    else
      expect "B3.1 simulated round 4, MED 2: [3,3,2], no park" \
        '[[ "$(getf "$S" medium_issues_history)" == "[3,3,2]" && "$(getf "$S" progress_status)" == medium_issues_remaining ]]' "$OUT"
    fi )
done

# ── 5 (a). The D8 clear sits after every reviewer has finished, inside the full-round branch (static) ──
# Cleared before Phase 1, an interrupted round would let --claude-only synthesize missing reviewer files.
d8_order() {
  awk '/# .* Phase 1: Launch Agy/ { p = NR }
       /^  persist_dispatch_provenance$/ { d = NR }
       /update_state_field "fresh_round_required" "false"/ { n++; f = NR }
       /^  fi  # end of CLAUDE_ONLY guard/ { g = NR }
       END { exit !(n == 1 && p > 0 && p < d && d < f && f < g) }' "$1"
}
expect "5(a) the D8 clear: once, after the reviewers finish, before the full-round branch ends" 'd8_order "$LOOP"'
grep -v 'update_state_field "fresh_round_required" "false"' "$LOOP" \
  | awk '{ print } /log_info "  Stale artifacts cleared"/ { print "update_state_field \"fresh_round_required\" \"false\"" }' > "$ROOT/d8-moved.sh"
expect "5(a) control: the ordering check fails on a copy with the clear back before Phase 1" '! d8_order "$ROOT/d8-moved.sh"'

# ── 6. The history really carries over (one simulated round after --continue) ──
for med in 3 2; do
  ( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r6; cont "$DESIGN"; sim_round r6sim 0 "$med"
    if [[ $med == 3 ]]; then
      expect "6 MED 3 after --continue: [2,3,3], parks again, iteration stays 3" \
        '[[ $RC -ne 0 && "$(getf "$S" medium_issues_history)" == "[2,3,3]" && "$(getf "$S" progress_status)" == parked_no_progress
           && "$(getf "$S" early_stopped)" == no_improvement_trajectory && "$(getf "$S" iteration)" == 3 ]]' "$OUT"
      expect "17 a MEDIUM trajectory park writes that round's blocker" \
        '[[ "$(getf "$S" pre_park_progress_status)" == medium_issues_remaining && "$(getf "$S" pre_park_recorded)" == true ]]'
    else
      expect "6 control: MED 2 gives [2,3,2], no park, iteration 4" \
        '[[ "$(getf "$S" medium_issues_history)" == "[2,3,2]" && "$(getf "$S" progress_status)" == medium_issues_remaining && "$(getf "$S" iteration)" == 4 ]]' "$OUT"
      expect "17 control: a non-parking round does not write the pre-park field" \
        '[[ -z "$(getf "$S" pre_park_progress_status)" && "$(getf "$S" pre_park_recorded)" == false ]]'
    fi )
done

# ── 6 regression and B3.2: the same sequences through the 2.6.5 scripts (Path A) ──
if [[ -z "$PRE" ]]; then
  echo "  SKIP  6 regression / B3.2: af80025 is not in this clone, so the pre-repair proof did not run"
else
  ( new_fixture; export BUSDRIVER_PLUGIN_ROOT="$PRE" CLAUDE_PLUGIN_ROOT="$PRE"; XLOOP=$PRE_LOOP
    write_state demo "$DESIGN"; write_artifacts demo r6; point demo; sim_round r6sim 0 3
    expect "6 regression: 2.6.5 re-run of the park gives [3] and no park (the defect is reached)" \
      '[[ "$(getf "$S" medium_issues_history)" == "[3]" && "$(getf "$S" progress_status)" == medium_issues_remaining ]]' "$OUT" )
  ( new_fixture; export BUSDRIVER_PLUGIN_ROOT="$PRE" CLAUDE_PLUGIN_ROOT="$PRE"; XLOOP=$PRE_LOOP
    live_shape; point demo; sim_round r4sim 0 3
    expect "B3.2 2.6.5 on the live shape: [3], no park, one round counted for two (iteration 3 -> 4)" \
      '[[ "$(getf "$S" medium_issues_history)" == "[3]" && "$(getf "$S" progress_status)" == medium_issues_remaining && "$(getf "$S" iteration)" == 4 ]]' "$OUT" )
  ( new_fixture; export BUSDRIVER_PLUGIN_ROOT="$PRE" CLAUDE_PLUGIN_ROOT="$PRE"
    live_shape; OUT=$(bash "$PRE_INIT" "$DESIGN" 2>&1); RC=$?
    expect "B3.2 2.6.5 fresh init resets the parked live shape to iteration 1" \
      '[[ $RC -eq 0 && "$(getf "$S" iteration)" == 1 && "$(getf "$S" medium_issues_history)" == "[]" ]]' "$OUT" )
fi

# ── 7. High-blocker park ──
( new_fixture; write_state demo "$DESIGN" plan_blocking_high=2 plan_blocking_medium=0 high_issues_history='"[2,2]"' medium_issues_history='"[]"'
  write_artifacts demo r7; cont "$DESIGN"
  expect "7 continuing a HIGH park derives blocked_by_high_issues" '[[ $RC -eq 0 && "$(getf "$S" progress_status)" == blocked_by_high_issues ]]' "$OUT"
  sim_round r7sim 2 0
  expect "7 a round with HIGH 2 parks again: [2,2,2]" \
    '[[ $RC -ne 0 && "$(getf "$S" high_issues_history)" == "[2,2,2]" && "$(getf "$S" progress_status)" == parked_no_progress ]]' "$OUT"
  expect "17 a HIGH trajectory park writes blocked_by_high_issues" \
    '[[ "$(getf "$S" pre_park_progress_status)" == blocked_by_high_issues && "$(getf "$S" pre_park_recorded)" == true ]]' )

# ── 8. After the placeholder is dropped, HIGH 2 is progress ──
( new_fixture; write_state demo "$DESIGN" early_stopped='"arbiter_verdict_uncountable"' high_issues_history='"[3,0]"' plan_blocking_medium=0
  write_artifacts demo r8; cont "$DESIGN"; sim_round r8sim 2 0
  expect "8 a round with HIGH 2 does not park: [3,2]" \
    '[[ "$(getf "$S" high_issues_history)" == "[3,2]" && "$(getf "$S" progress_status)" == blocked_by_high_issues ]]' "$OUT" )

# ── 10. No PASS from continuing ──
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r10; cont "$DESIGN"
  expect "10 no PASS marker after --continue" '[[ $RC -eq 0 ]] && ! reviewed "$DESIGN"' "$OUT"
  BLUEPRINT_COVERAGE_PROVENANCE=1 sim_round r10sim 0 0 degraded
  expect "10 a clean round with DEGRADED coverage after it withholds PASS" '[[ $RC -ne 0 && "$OUT" == *DEGRADED* ]] && ! reviewed "$DESIGN"' "$OUT" )
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r10; cont "$DESIGN"; sim_round r10full 0 0
  expect "10 control: a clean FULL 3/3 round after it passes through the approval branch" '[[ $RC -eq 0 ]] && reviewed "$DESIGN"' "$OUT" )

# ── 17. The loop persists the pre-park blocker: write-site and intake parks ──
seed17() {  # <persisted progress_status> [status]: a repaired-init state at iteration 2
  init_ "$DESIGN"; setf "$S" iteration 2; setf "$S" progress_status "\"$1\""; setf "$S" high_issues_history '"[2]"'
  [[ -n "${2:-}" ]] && setf "$S" status "\"$2\""
  return 0
}
( new_fixture; seed17 blocked_by_high_issues; sim_round r17 2 0 uncountable
  expect "17 a write-site park after a blocked_by_high_issues round writes blocked_by_high_issues" \
    '[[ "$(getf "$S" early_stopped)" == arbiter_verdict_uncountable && "$(getf "$S" pre_park_progress_status)" == blocked_by_high_issues
       && "$(getf "$S" pre_park_recorded)" == true ]]' "$OUT" )
for prev in passed degraded_coverage; do
  ( new_fixture
    if [[ $prev == passed ]]; then seed17 passed; else seed17 passed degraded_coverage; fi
    sim_round r17 2 0 uncountable
    expect "17 a write-site park after a $prev round writes \"\"" \
      '[[ "$(getf "$S" early_stopped)" == arbiter_verdict_uncountable && -z "$(getf "$S" pre_park_progress_status)"
         && "$(getf "$S" pre_park_recorded)" == true ]]' "$OUT" )
done
( new_fixture; seed17 medium_issues_remaining; sim_round r17 0 0 intake
  expect "17 an intake park writes the previous persisted status" \
    '[[ "$(getf "$S" early_stopped)" == arbiter_verdict_uncountable && "$(getf "$S" pre_park_progress_status)" == medium_issues_remaining
       && "$(getf "$S" pre_park_recorded)" == true ]]' "$OUT" )

# ── 23. A repaired-loop park on a pre-repair state inserts both keys ──
( new_fixture; write_state demo "$DESIGN" status='"IN_PROGRESS"' active=true progress_status='"medium_issues_remaining"' early_stopped='""' medium_issues_history='"[3]"'
  point demo; sim_round r23 0 3
  expect "23 a trajectory park on a state without the keys leaves both in state.md" \
    '[[ $RC -ne 0 ]] && grep -q "^pre_park_progress_status: \"medium_issues_remaining\"" "$S" && grep -q "^pre_park_recorded: true" "$S"' "$OUT" )

# unpin_loop <loop>: edit a copy of the loop back to re-reading the pointer on every call.
unpin_loop() {
  cp -R "$REPO/skills/blueprint-review/prompts" "$(dirname "$1")/../prompts"  # the loop reads ../prompts
  python3 -I - "$1" <<'PY' || no "the unpinned loop could not be built"
import sys
p = sys.argv[1]; s = open(p).read()
a, b = 'trap _release_loop_pid EXIT\n', 'REVIEW_DIR=$_DR_REVIEW_DIR_PIN\n'
if s.count(a) != 1 or s.count(b) != 1:
    sys.exit(1)
open(p, "w").write(s.replace(a, a + 'unset _DR_REVIEW_DIR_PIN\n').replace(b, 'REVIEW_DIR=$(get_review_dir)\n'))
PY
}

# ── 25. Held loop: another review's running loop is never redirected ──
# B (awaiting_claude_validation, active: false, named by the pointer) runs --claude-only
# and is held at its first update_state_field by an awk shim on B's PATH only. While it
# is held, --continue A runs. The mutant is the S1 pre-fix rule: check 8 tests only
# active (and has no quiet period); against it the test must see B's writes reach A.
for build in repaired mutant; do
  ( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r25
    printf '# o\n' > spec/other.md
    write_state other spec/other.md status='"awaiting_claude_validation"' progress_status='"medium_issues_remaining"' early_stopped='""' medium_issues_history='"[3]"'
    ( D=docs/reviews/other; S=$D/state.md; DESIGN=spec/other.md; sim_files rB 0 2 )
    old docs/reviews/other/state.md; point other
    xinit=$INIT; xloop=$LOOP
    if [[ $build == mutant ]]; then
      # The pin (round 7) closes the redirect on its own, so the mutant unpins the loop too.
      cp -R "$REPO/skills/blueprint-review/scripts" "$W/mut"; xinit="$W/mut/init-design-review.sh"
      xloop="$W/mut/run-design-review-loop.sh"; unpin_loop "$xloop"
      python3 -I - "$xinit" <<'PY' || no "25 mutant could not be built"
import sys
p = sys.argv[1]; s = open(p).read()
a = 'if [[ "$o_progress" != "parked_no_progress" && "$o_status" != "max_iterations_exceeded" ]]; then'
b = 'state_file_quiet_for "$other" "$QUIET_SECS"'
c = '_loop_finished "$other"'
if s.count(a) != 1 or s.count(b) != 1 or s.count(c) != 1:
    sys.exit(1)
open(p, "w").write(s.replace(a, 'if [[ "$(_sf_get "$other" active || true)" == true ]]; then').replace(b, "true").replace(c, "true"))
PY
    fi
    mkdir -p "$W/hold"; mkfifo "$W/fifo"
    printf '#!/bin/bash\nif [[ -n "${_AWK_VALUE+x}" && ! -e %q ]]; then printf "%%s\\n" "$2" > %q; read -r _ < %q; fi\nexec %q "$@"\n' \
      "$W/held" "$W/held" "$W/fifo" "$(command -v awk)" > "$W/hold/awk"
    chmod +x "$W/hold/awk"
    PATH="$W/hold:$PATH" bash "$xloop" --claude-only >"$W/b.log" 2>&1 </dev/null & bp=$!
    for _ in $(seq 300); do [[ -e "$W/held" ]] && break; sleep 0.1; done
    held=0; [[ -s "$W/held" ]] && held=1
    a=$(snap "$D" .claude/current-design-review.local)
    OUT=$(bash "$xinit" --continue "$DESIGN" 2>&1); RC=$?
    b=$(snap "$D" .claude/current-design-review.local); mid=$(snap "$D")
    release "$bp"
    after=$(snap "$D")
    if [[ $build == repaired ]]; then
      expect "25 B held at its write of '$(cat "$W/held" 2>/dev/null)': --continue A refused naming B, A and pointer unchanged" \
        '[[ $held -eq 1 && $RC -eq 1 && "$OUT" == *other* && "$a" == "$b" ]] && no_trace' "$OUT $(tail -n 5 "$W/b.log")"
      expect "25 B released: A still byte-identical, B's round landed in B" \
        '[[ "$a" == "$(snap "$D" .claude/current-design-review.local)" && "$(getf docs/reviews/other/state.md medium_issues_history)" == "[3,2]" ]]' "$(tail -n 5 "$W/b.log")"
    else
      expect "25 regression proof: the active-only check 8 commits, and B's later writes change A" \
        '[[ $held -eq 1 && $RC -eq 0 && "$mid" != "$after" ]]' "rc=$RC $OUT $(tail -n 5 "$W/b.log")"
    fi )
done

# ── Beyond the design (litmus round 7): the loop pins its review directory ──
# B's loop (pointer=other) is held at its first state write; the pointer then moves to
# demo, as init or --continue moves it. The mutant re-reads the pointer on every write.
for build in repaired mutant; do
  ( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r26
    printf '# o\n' > spec/other.md
    write_state other spec/other.md status='"awaiting_claude_validation"' progress_status='"medium_issues_remaining"' early_stopped='""' medium_issues_history='"[3]"'
    ( D=docs/reviews/other; S=$D/state.md; DESIGN=spec/other.md; sim_files rB 0 2 )
    point other
    xloop=$LOOP
    if [[ $build == mutant ]]; then
      cp -R "$REPO/skills/blueprint-review/scripts" "$W/mut"; xloop="$W/mut/run-design-review-loop.sh"; unpin_loop "$xloop"
    fi
    mkdir -p "$W/hold"; mkfifo "$W/fifo"
    printf '#!/bin/bash\nif [[ -n "${_AWK_VALUE+x}" && ! -e %q ]]; then printf "%%s\\n" "$2" > %q; read -r _ < %q; fi\nexec %q "$@"\n' \
      "$W/held" "$W/held" "$W/fifo" "$(command -v awk)" > "$W/hold/awk"
    chmod +x "$W/hold/awk"
    PATH="$W/hold:$PATH" bash "$xloop" --claude-only >"$W/b.log" 2>&1 </dev/null & bp=$!
    for _ in $(seq 300); do [[ -e "$W/held" ]] && break; sleep 0.1; done
    held=0; [[ -s "$W/held" ]] && held=1
    a=$(snap "$D"); point demo; lpid=$(cat docs/reviews/other/.loop.pid 2>/dev/null || true)
    release "$bp"
    b=$(snap "$D")
    if [[ $build == repaired ]]; then
      expect "26 pointer moved under a held loop: demo byte-identical, B's round landed in B, B's .loop.pid held then removed" \
        '[[ $held -eq 1 && "$a" == "$b" && "$(getf docs/reviews/other/state.md medium_issues_history)" == "[3,2]" && "$lpid" == "$bp" && ! -e docs/reviews/other/.loop.pid ]]' "$(tail -n 5 "$W/b.log")"
    else
      expect "26 regression proof: re-reading the pointer sends B's later writes into demo" \
        '[[ $held -eq 1 && "$a" != "$b" ]]' "$(tail -n 5 "$W/b.log")"
    fi )
done
( new_fixture; write_state demo "$DESIGN" status='"IN_PROGRESS"' active=true; point demo; mkdir docs/reviews/.continue.lock
  a=$(snap); OUT=$(bash "$LOOP" </dev/null 2>&1); RC=$?; b=$(snap)
  expect "26 the loop refuses while init or --continue holds the cross-review lock, nothing changed" \
    '[[ $RC -eq 1 && "$OUT" == *"docs/reviews/.continue.lock"* && "$a" == "$b" ]]' "$OUT" )

# Stale cleanup landing after the loop's last write (check_existing_review saw it active,
# then it parked) keeps the terminal status, so --continue still classifies the stop.
# Control: a never-finished state is still ABANDONED.
for st in uncountable_claude_output parked_no_progress max_iterations_exceeded IN_PROGRESS; do
  ( new_fixture; write_state demo "$DESIGN" status="\"$st\""; point demo
    # shellcheck source=skills/blueprint-review/scripts/lib/state_management.sh
    ( set +e; source "$LIB"; set +e; cleanup_stale_review )
    want=$st; [[ $st == IN_PROGRESS ]] && want=ABANDONED
    expect "26 stale cleanup over status $st leaves $want, pointer removed" \
      '[[ "$(getf "$S" status)" == "$want" && ! -e .claude/current-design-review.local ]]' )
done

# ── Beyond the design (litmus round 9): the loop announces that it is alive ──
( new_fixture; write_state demo "$DESIGN" status='"IN_PROGRESS"' active=true; point demo
  sleep 300 & lp=$!; echo "$lp" > "$D/.loop.pid"
  a=$(snap); loop_; b=$(snap); kill "$lp"
  expect "26 the loop refuses while another live loop holds .loop.pid, nothing changed" \
    '[[ $RC -eq 1 && "$OUT" == *"already running"* && "$a" == "$b" ]]' "$OUT" )
( new_fixture; write_state demo "$DESIGN"; point demo
  true & dp=$!; wait "$dp"; echo "$dp" > "$D/.loop.pid"
  loop_
  expect "26 a dead PID (a killed loop's) is taken over, and the loop's exit removes its own" \
    '[[ $RC -eq 1 && "$OUT" == *PARKED* && "$OUT" != *"already running"* && ! -e "$D/.loop.pid" ]]' "$OUT" )
# Litmus extra round 1: a symlinked review directory, and a name that leaves an empty slug.
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r26s
  mv docs/reviews/demo real-demo; ln -s ../../real-demo docs/reviews/demo
  a=$(snap real-demo); cont "$DESIGN"; b=$(snap real-demo)
  expect "26 a symlinked review directory is refused, its target untouched" \
    '[[ $RC -eq 1 && "$OUT" == *symlink* && "$a" == "$b" ]]' "$OUT" )
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r26d
  mv docs real-docs; ln -s real-docs docs
  a=$(snap real-docs); cont "$DESIGN"; b=$(snap real-docs)
  expect "26 a symlinked docs directory is refused, its target untouched" \
    '[[ $RC -eq 1 && "$OUT" == *symlink* && "$a" == "$b" ]]' "$OUT" )
# PR review round 1: the pointer's own directory, a hard-linked pointer, the loop and fresh init.
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r26k
  mv .claude real-claude; ln -s real-claude .claude
  a=$(snap docs real-claude); cont "$DESIGN"; b=$(snap docs real-claude)
  expect "26 a symlinked STATE_DIR is refused by --continue, nothing written through it" \
    '[[ $RC -eq 1 && "$OUT" == *symlink* && "$a" == "$b" ]]' "$OUT" )
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r26h; point demo
  ln .claude/current-design-review.local alias.ptr
  a=$(snap); cont "$DESIGN"; b=$(snap)
  expect "26 a hard-linked pointer is refused, both names unchanged" \
    '[[ $RC -eq 1 && "$OUT" == *"hard link"* && "$a" == "$b" && "$(cat alias.ptr)" == demo ]]' "$OUT" )
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r26l
  ln "$DESIGN" docs/reviews/demo/continuations.jsonl
  a=$(snap); cont "$DESIGN"; b=$(snap)
  expect "26 a hard-linked ledger is refused, the linked file unchanged" \
    '[[ $RC -eq 1 && "$OUT" == *"hard link"* && "$a" == "$b" ]]' "$OUT" )
( new_fixture; write_state demo "$DESIGN"; point demo
  mv docs/reviews real-reviews; ln -s ../real-reviews docs/reviews
  a=$(snap real-reviews); loop_; b=$(snap real-reviews)
  expect "26 the loop refuses a symlinked docs/reviews, its target untouched" \
    '[[ $RC -eq 1 && "$OUT" == *symlink* && "$a" == "$b" ]]' "$OUT" )
( new_fixture; write_state demo "$DESIGN"; point demo
  mv docs/reviews/demo real-demo; ln -s ../../real-demo docs/reviews/demo
  a=$(snap real-demo); loop_; b=$(snap real-demo)
  expect "26 the loop refuses a symlinked review directory, no .loop.pid written through it" \
    '[[ $RC -eq 1 && "$OUT" == *symlink* && "$a" == "$b" && ! -e docs/reviews/.continue.lock ]]' "$OUT" )
( new_fixture; mkdir -p real-demo; ln -s ../../real-demo docs/reviews/demo
  a=$(snap real-demo); init_ "$DESIGN"; b=$(snap real-demo)
  expect "26 a fresh init refuses a symlinked review directory, its target untouched" \
    '[[ $RC -eq 1 && "$OUT" == *symlink* && "$a" == "$b" && ! -e .claude/current-design-review.local ]]' "$OUT" )
# A killed loop's job its parent never reaped is a zombie: kill -0 and ps -p both see it.
( new_fixture; mkdir -p "$D"
  perl -e '$| = 1; my $p = fork; exit 0 unless $p; print "$p\n"; sleep 30' > "$D/.loop.pid" & zp=$!
  for _ in $(seq 25); do
    [[ "$(ps -o stat= -p "$(cat "$D/.loop.pid" 2>/dev/null)" 2>/dev/null | tr -d ' ')" == Z* ]] && break
    sleep 0.2
  done
  # shellcheck source=skills/blueprint-review/scripts/lib/state_management.sh
  ( set +e; source "$LIB" >/dev/null 2>&1; loop_alive "$D" ); za=$?
  sleep 300 & lp=$!; echo "$lp" > "$D/.loop.pid"
  # shellcheck source=skills/blueprint-review/scripts/lib/state_management.sh
  ( set +e; source "$LIB" >/dev/null 2>&1; loop_alive "$D" ); la=$?
  kill "$zp" "$lp"; wait "$zp" "$lp" 2>/dev/null
  expect "26 a zombie listed in .loop.pid does not hold the review" '[[ $za -ne 0 ]]'
  expect "26 control: a live PID listed in .loop.pid holds it" '[[ $la -eq 0 ]]' )
( new_fixture; mkdir -p docs/plans; printf '# e\n' > docs/plans/2026-10-14-.md
  init_ docs/plans/2026-10-14-.md; r1=$RC; cont docs/plans/2026-10-14-.md
  expect "26 an empty slug is refused by init and --continue, no state or lock left" \
    '[[ $r1 -eq 1 && $RC -eq 1 && "$OUT" == *"review slug"* && ! -e docs/reviews/state.md && ! -e docs/.continue.lock ]]' "$OUT" )

# Litmus round 10: a continued review whose pointer was removed while its loop runs.
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r26c; cont "$DESIGN"
  rm -f .claude/current-design-review.local; setf "$S" last_review_timestamp '"2000-01-01T00:00:00Z"'; old "$S"
  sleep 300 & lp=$!; echo "$lp" > "$D/.loop.pid"
  a=$(snap); cont "$DESIGN"; b=$(snap); kill "$lp"; wait "$lp" 2>/dev/null
  expect "26 a continued review whose loop is alive is refused, nothing changed" \
    '[[ $RC -eq 1 && "$OUT" == *"has not finished"* && "$a" == "$b" ]]' "$OUT"
  cont "$DESIGN"
  expect "26 control: once that loop has exited it is continued" '[[ $RC -eq 0 ]]' "$OUT" )
( new_fixture; write_state demo "$DESIGN" status='"passed"' progress_status='"passed"' early_stopped='""'; sleep 300 & lp=$!; echo "$lp" > "$D/.loop.pid"
  a=$(snap); init_ "$DESIGN"; b=$(snap); kill "$lp"
  expect "26 fresh init refuses to reset a review whose loop is alive, nothing changed" \
    '[[ $RC -eq 1 && "$OUT" == *"loop is running"* && "$a" == "$b" ]]' "$OUT" )
( new_fixture; write_state demo "$DESIGN" status='"IN_PROGRESS"' active=true last_review_timestamp='"2000-01-01T00:00:00Z"'; point demo
  sleep 300 & lp=$!; echo "$lp" > "$D/.loop.pid"; printf '# o\n' > spec/other.md
  a=$(snap); DESIGN_REVIEW_STALE_HOURS=0.0001 init_ spec/other.md; b=$(snap); kill "$lp"
  expect "26 stale cleanup refuses a review whose loop is alive, nothing changed" \
    '[[ $RC -eq 1 && "$OUT" == *"loop is running"* && "$a" == "$b" ]]' "$OUT" )
cleanup_locked() {  # <init>: init's stale cleanup runs while it holds the cross-review lock
  awk '/^if ! _claim_lock "\$ALL_LOCK"/ { m = NR } /^  cleanup_stale_review$/ { c = NR } /^rmdir "\$ALL_LOCK"$/ { r = NR }
       END { exit !(m && c && r && m < c && c < r) }' "$1"
}
expect "26 static: init's stale cleanup runs under the cross-review lock" 'cleanup_locked "$INIT"'
# An unreadable pointer cannot be backed up: refused and rolled back, never overwritten.
[[ $(id -u) -ne 0 ]] && ( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r26p; point demo; chmod 200 .claude/current-design-review.local
  a=$(snap "$D"); cont "$DESIGN"; b=$(snap "$D")
  chmod 600 .claude/current-design-review.local
  expect "26 an unreadable pointer is refused and rolled back, pointer unchanged" \
    '[[ $RC -eq 1 && "$a" == "$b" && "$(cat .claude/current-design-review.local)" == demo ]] && no_trace' "$OUT" )

# ── 21 (beyond the design; litmus round 2): every --continue is serialized ──
# mutant_init <sed-free python replacement pairs...>: a copy of the scripts with init edited.
mutant_init() {
  cp -R "$REPO/skills/blueprint-review/scripts" "$W/mut"; xinit="$W/mut/init-design-review.sh"
  python3 -I - "$xinit" "$@" <<'PY' || no "mutant could not be built: $*"
import sys
p, pairs = sys.argv[1], sys.argv[2:]
s = open(p).read()
for a, b in zip(pairs[::2], pairs[1::2]):
    if s.count(a) != 1:
        sys.exit(1)
    s = s.replace(a, b)
open(p, "w").write(s)
PY
}
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r21g; mkdir docs/reviews/.continue.lock
  a=$(snap); cont "$DESIGN"; b=$(snap)
  expect "21 a held cross-review lock refuses by name, nothing changed" \
    '[[ $RC -eq 1 && "$OUT" == *"docs/reviews/.continue.lock"* && "$a" == "$b" ]]' "$OUT" )
# A is held at its commit mv (pointer already on A, A still parked) while B continues.
# The mutant locks per review only, as before this fix: B commits and takes the pointer
# from A, whose loop would then write into B.
for build in repaired mutant; do
  ( new_fixture; write_state demo "$DESIGN"; write_artifacts demo rA
    printf '# t\n' > spec/two.md; write_state two spec/two.md; write_artifacts two rB
    xinit=$INIT
    [[ $build == mutant ]] && mutant_init 'ALL_LOCK="docs/reviews/.continue.lock"' 'ALL_LOCK="$REVIEW_DIR/.continue.all"'
    mkfifo "$W/fifo"; mkdir -p "$W/hold"
    printf '#!/bin/bash\ncase "$2" in */demo/state.md) : > %q; read -r _ < %q;; esac\nexec %q "$@"\n' \
      "$W/held" "$W/fifo" "$REAL_MV" > "$W/hold/mv"
    chmod +x "$W/hold/mv"
    PATH="$W/hold:$PATH" bash "$xinit" --continue "$DESIGN" >"$W/a.log" 2>&1 & ap=$!
    for _ in $(seq 300); do [[ -e "$W/held" ]] && break; sleep 0.1; done
    held=0; [[ -e "$W/held" ]] && held=1
    OUT=$(bash "$xinit" --continue spec/two.md 2>&1); RC=$?
    release "$ap"; arc=$?
    if [[ $build == repaired ]]; then
      expect "21 B refused while A holds the cross-review lock; A then commits and keeps the pointer" \
        '[[ $held -eq 1 && $RC -eq 1 && "$OUT" == *"docs/reviews/.continue.lock"* && $arc -eq 0
           && "$(cat .claude/current-design-review.local)" == demo && ! -e docs/reviews/two/attempts ]]' "$OUT $(cat "$W/a.log")"
    else
      expect "21 regression proof: per-review locks let B commit and take the pointer from A" \
        '[[ $held -eq 1 && $RC -eq 0 && "$(cat .claude/current-design-review.local)" == two && "$(getf "$S" status)" == IN_PROGRESS ]]' "rc=$RC arc=$arc $OUT"
    fi )
done

# ── 21 (beyond the design; litmus rounds 2-3): signals are deferred to checkpoints ──
# The mutant takes signals immediately, as before the fix.
SIGDEFER="trap '_CONT_SIG=1' INT TERM HUP
  _claim_lock \"\$ALL_LOCK\""
SIGNOW="trap 'exit 1' INT TERM HUP
  _claim_lock \"\$ALL_LOCK\""
# The mv shim commits, then sends TERM to init before init can swap its EXIT trap.
for build in repaired mutant; do
  ( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r21s
    xinit=$INIT
    [[ $build == mutant ]] && mutant_init "$SIGDEFER" "$SIGNOW"
    shim mv "$REAL_MV \"\$@\" || exit; case \"\$2\" in */demo/state.md) kill -TERM \$PPID;; esac"
    OUT=$(PATH="$W/shim:$PATH" bash "$xinit" --continue "$DESIGN" 2>&1); RC=$?
    if [[ $build == repaired ]]; then
      expect "21 TERM right after the commit is deferred: the continuation completes, ledger written, no lock left" \
        '[[ $RC -eq 0 && "$(getf "$S" continuation_count)" == 1 && -d "$D/attempts/001-r21s" && "$(cat .claude/current-design-review.local)" == demo
           && ! -e "$D/.continue.lock" && ! -e docs/reviews/.continue.lock && $(wc -l < "$D/continuations.jsonl") -eq 1 ]]' "$OUT"
    else
      expect "21 regression proof: without the handover the rollback deletes the archive of a committed state" \
        '[[ "$(getf "$S" continuation_count)" == 1 && ! -e "$D/attempts/001-r21s" ]]' "$OUT"
    fi )
done

# Litmus extra round 3: mv killed after its rename is a commit, not a rollback.
for build in repaired mutant; do
  ( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r26m
    xinit=$INIT
    [[ $build == mutant ]] && mutant_init 'if ! mv "$TEMP_STATE" "$TARGET_STATE" && [[ -e "$TEMP_STATE" ]]; then' 'if ! mv "$TEMP_STATE" "$TARGET_STATE"; then'
    shim mv "$REAL_MV \"\$@\" || exit; case \"\$2\" in */demo/state.md) kill -TERM \$\$;; esac"
    OUT=$(PATH="$W/shim:$PATH" bash "$xinit" --continue "$DESIGN" 2>&1); RC=$?
    if [[ $build == repaired ]]; then
      expect "26 mv killed after its rename: the continuation completes, archive and ledger kept" \
        '[[ $RC -eq 0 && "$(getf "$S" continuation_count)" == 1 && -d "$D/attempts/001-r26m" && $(wc -l < "$D/continuations.jsonl") -eq 1 ]]' "$OUT"
    else
      expect "26 regression proof: without the check the rollback deletes the archive of a committed state" \
        '[[ "$(getf "$S" continuation_count)" == 1 && ! -e "$D/attempts/001-r26m" ]]' "$OUT"
    fi )
done
# A symlinked .loop.pid is never written through.
( new_fixture; write_state demo "$DESIGN" status='"IN_PROGRESS"' active=true; point demo
  true & dp=$!; wait "$dp"; echo "$dp" > ext.pid; ln -s "$PWD/ext.pid" "$D/.loop.pid"
  loop_
  expect "26 a symlinked .loop.pid is refused and its target left unchanged" \
    '[[ $RC -eq 1 && "$OUT" == *"already running"* && "$(cat ext.pid)" == "$dp" && -L "$D/.loop.pid" ]]' "$OUT" )

# A .loop.pid that is not a regular file (a FIFO would block the read) is refused unopened.
( new_fixture; write_state demo "$DESIGN" status='"IN_PROGRESS"' active=true; point demo
  mkfifo "$D/.loop.pid"
  perl -e 'alarm shift; exec @ARGV' 20 bash "$LOOP" > "$W/fifo.out" 2>&1 </dev/null; RC=$?; OUT=$(cat "$W/fifo.out")
  expect "26 a FIFO .loop.pid is refused without blocking, left in place" \
    '[[ $RC -eq 1 && "$OUT" == *"already running"* && -p "$D/.loop.pid" ]]' "$OUT" )
( new_fixture; mkdir -p "$D"
  mkfifo "$D/.loop.pid"
  perl -e 'alarm shift; exec @ARGV' 20 bash "$INIT" "$DESIGN" > "$W/fifo.out" 2>&1; RC=$?; OUT=$(cat "$W/fifo.out")
  expect "26 fresh init refuses a FIFO .loop.pid without blocking" \
    '[[ $RC -eq 1 && -p "$D/.loop.pid" ]]' "$OUT" )

# Litmus extra round 4: the release waits for reviewer jobs still writing.
( new_fixture; mkdir -p "$D"
  awk '/^_release_loop_pid\(\) \{/,/^}/' "$LOOP" > "$W/rel.sh"
  sed '/^  wait /d' "$W/rel.sh" > "$W/rel-nowait.sh"
  rel_probe() {  # <handler file>: true when the writer finished before .loop.pid went away
    rm -f "$W/writer.done"
    bash -c 'source "$1"; _LOOP_PID_FILE=$2; echo "$$" > "$_LOOP_PID_FILE"
      ( sleep 1; [[ -e "$_LOOP_PID_FILE" ]] && touch "$3" ) &
      _release_loop_pid; [[ -e "$3" && ! -e "$_LOOP_PID_FILE" ]]' _ "$1" "$D/.loop.pid" "$W/writer.done"
  }
  rel_probe "$W/rel.sh"; rr=$?; rel_probe "$W/rel-nowait.sh"; rn=$?
  expect "26 the loop's release holds .loop.pid until its reviewer jobs exit" '[[ $rr -eq 0 ]]'
  expect "26 control: a release without the wait drops .loop.pid while a job still writes" '[[ $rn -ne 0 ]]' )

# PR-mode litmus: reviewer jobs hold the review, claims survive a group signal, pointer links.
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r26r
  true & dp=$!; wait "$dp"; sleep 300 & lp=$!; printf '%s\n%s\n' "$dp" "$lp" > "$D/.loop.pid"
  a=$(snap); cont "$DESIGN"; b=$(snap); kill "$lp"; wait "$lp" 2>/dev/null
  expect "26 a dead loop whose reviewer job is alive still holds the review, nothing changed" \
    '[[ $RC -eq 1 && "$OUT" == *"has not finished"* && "$a" == "$b" ]]' "$OUT" )
reviewer_pids_recorded() {  # <loop>: each reviewer job's PID is appended right after its launch
  awk '/_PID=\$!$/ { n++; want = 1; next } want { if ($0 ~ />> "\$_LOOP_PID_FILE"/) ok++; want = 0 }
       END { exit !(n == 3 && ok == 3) }' "$1"
}
expect "26 static: the loop records all three reviewer jobs in .loop.pid" 'reviewer_pids_recorded "$LOOP"'
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r26q
  printf 'x\n' > ext.ptr; ln -s "$PWD/ext.ptr" .claude/current-design-review.local
  cont "$DESIGN"; r1=$RC; o1=$OUT; printf '# o\n' > spec/other.md; init_ spec/other.md
  expect "26 a symlinked pointer is refused by --continue and fresh init, its target untouched" \
    '[[ $r1 -eq 1 && "$o1" == *symlink* && $RC -eq 1 && "$OUT" == *symlink* && "$(cat ext.ptr)" == x ]]' "$o1 $OUT" )
# A pointer that is not a regular file (a FIFO would block the write) is refused unopened.
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r26f
  mkfifo .claude/current-design-review.local
  perl -e 'alarm shift; exec @ARGV' 20 bash "$INIT" --continue "$DESIGN" > "$W/fifo.out" 2>&1; r1=$?; o1=$(cat "$W/fifo.out")
  printf '# o\n' > spec/other.md
  perl -e 'alarm shift; exec @ARGV' 20 bash "$INIT" spec/other.md > "$W/fifo.out" 2>&1; RC=$?; OUT=$(cat "$W/fifo.out")
  expect "26 a FIFO pointer is refused by --continue and fresh init without blocking, left in place" \
    '[[ $r1 -eq 1 && "$o1" == *"not a regular file"* && $RC -eq 1 && "$OUT" == *"not a regular file"* && -p .claude/current-design-review.local ]]' "$o1 $OUT" )
# A FIFO in the review directory (the ledger here) is refused before any write.
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r26l; point demo
  mkfifo "$D/continuations.jsonl"; a=$(snap)
  perl -e 'alarm shift; exec @ARGV' 20 bash "$INIT" --continue "$DESIGN" > "$W/fifo.out" 2>&1; RC=$?; OUT=$(cat "$W/fifo.out"); b=$(snap)
  expect "26 a FIFO ledger is refused by --continue without blocking, nothing changed" \
    '[[ $RC -eq 1 && "$OUT" == *"special file"* && "$a" == "$b" && -p "$D/continuations.jsonl" ]]' "$OUT" )
# _claim: the mkdir survives a TERM aimed at it; a plain mkdir in the same spot does not.
( new_fixture
  awk '/^_claim\(\) \{/' "$INIT" > "$W/claim.sh"
  mkdir -p "$W/slow"; printf '#!/bin/bash\nsleep 1\nexec %q "$@"\n' "$(command -v mkdir)" > "$W/slow/mkdir"; chmod +x "$W/slow/mkdir"
  claim_probe() {  # <function body to run>: true when the claimed dir exists afterwards
    rm -rf "$W/lk"
    PATH="$W/slow:$PATH" bash -c "source '$W/claim.sh'; $1 '$W/lk'" & local cp=$!
    sleep 0.4; pkill -TERM -f "$W/slow/mkdir" 2>/dev/null; wait "$cp" 2>/dev/null
    [[ -d "$W/lk" ]]
  }
  claim_probe _claim; c1=$?; claim_probe mkdir; c2=$?
  expect "26 _claim's mkdir completes through a TERM aimed at it" '[[ $c1 -eq 0 ]]'
  expect "26 control: a plain mkdir killed the same way leaves no claim" '[[ $c2 -ne 0 ]]' )

# A reviewer job waits to be recorded; one never recorded exits without writing.
await_gated() {  # <loop>: every reviewer subshell opens with _await_recorded
  awk '/^  \($/ { o = 1; next } o { if ($0 ~ /^    _await_recorded \|\| exit 1$/) g++; o = 0 }
       END { exit !(g == 3) }' "$1"
}
expect "26 static: all three reviewer jobs wait to be recorded before writing" 'await_gated "$LOOP"'
( new_fixture
  awk '/^_await_recorded\(\) \{/,/^}/' "$LOOP" > "$W/await.sh"
  bash -c 'source "$1"; _LOOP_PID_FILE=$2; ( unset BASHPID; sh -c "echo \$PPID" > "$2"; _await_recorded )' _ "$W/await.sh" "$W/rec.pid"; r1=$?
  : > "$W/none.pid"
  bash -c 'source "$1"; _LOOP_PID_FILE=$2; ( _await_recorded )' _ "$W/await.sh" "$W/none.pid"; r2=$?
  expect "26 a recorded job proceeds; one the loop never recorded gives up" '[[ $r1 -eq 0 && $r2 -ne 0 ]]' )

claims_all_signal_safe() {  # <init>: every directory init records as its own is made by _claim
  ! grep -nE '^[[:space:]]*mkdir "' "$1"
}
expect "26 static: init makes no claimed directory with a plain mkdir" 'claims_all_signal_safe "$INIT"'

# ── Beyond the design (litmus round 4): a parked review whose loop is still writing ──
# The park signal comes before the loop's last writes; the terminal status is the last.
( new_fixture; write_state demo "$DESIGN" status='"IN_PROGRESS"' last_review_timestamp='"2000-01-01T00:00:00Z"'; write_artifacts demo r4f
  sleep 300 & lp=$!; echo "$lp" > "$D/.loop.pid"
  a=$(snap); cont "$DESIGN"; b=$(snap); kill "$lp"
  expect "3 a target whose loop is alive is refused even behind an old timestamp, nothing changed" \
    '[[ $RC -eq 1 && "$OUT" == *"has not finished"* && "$a" == "$b" ]] && no_trace' "$OUT" )
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r4f; write_state other spec/other.md status='"IN_PROGRESS"' last_review_timestamp='"2000-01-01T00:00:00Z"'; point other
  sleep 300 & lp=$!; echo "$lp" > docs/reviews/other/.loop.pid
  a=$(snap); cont "$DESIGN"; b=$(snap); kill "$lp"
  expect "8 another review whose loop is alive is refused, nothing changed" \
    '[[ $RC -eq 1 && "$OUT" == *other* && "$OUT" == *"has not finished"* && "$a" == "$b" ]] && no_trace' "$OUT" )
# A park left unfinished by a killed loop, or abandoned after it parked, stays continuable.
( new_fixture; write_state demo "$DESIGN" status='"ABANDONED"'; write_artifacts demo r4a
  cont "$DESIGN"
  expect "3 an ABANDONED park with a stale timestamp is continuable" \
    '[[ $RC -eq 0 && "$(getf "$S" iteration)" == 3 && "$(getf "$S" last_stop_reason)" == no_improvement_trajectory ]]' "$OUT" )
( new_fixture; write_state demo "$DESIGN" status='"IN_PROGRESS"' last_review_timestamp="\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""; write_artifacts demo r4k
  true & dp=$!; wait "$dp"; echo "$dp" > "$D/.loop.pid"
  cont "$DESIGN"
  expect "3 a park whose loop was killed (its PID dead) is continuable at once" '[[ $RC -eq 0 && "$(getf "$S" iteration)" == 3 ]]' "$OUT" )

# mark_review_complete lands status and active in ONE state write (one mv onto state.md).
( new_fixture; init_ "$DESIGN"
  shim mv "case \"\$2\" in */demo/state.md) echo x >> \"$W/mvcount\";; esac; exec $REAL_MV \"\$@\""
  # shellcheck source=skills/blueprint-review/scripts/lib/state_management.sh
  ( PATH="$W/shim:$PATH"; set +e; source "$LIB"; set +e; mark_review_complete parked_no_progress )
  expect "8 mark_review_complete writes status and active in one write" \
    '[[ $(wc -l < "$W/mvcount") -eq 1 && "$(getf "$S" status)" == parked_no_progress && "$(getf "$S" active)" == false ]]'
  rm -f "$W/mvcount"
  # shellcheck source=skills/blueprint-review/scripts/lib/state_management.sh disable=SC2317
  ( PATH="$W/shim:$PATH"; set +e; source "$LIB"; set +e
    mark_review_complete() { update_state_field "status" "\"$1\""; update_state_field "active" "false"; }
    mark_review_complete parked_no_progress )
  expect "8 control: the two-write form is counted as two" '[[ $(wc -l < "$W/mvcount") -eq 2 ]]' )
init_refusals() {  # <init>: the refusal runs before check_existing_review and again after it
  awk '/^_init_refusal$/ { r[++n] = NR } /^check_existing_review \|\| EXISTING/ { c = NR }
       END { exit !(n == 2 && r[1] < c && c < r[2]) }' "$1"
}
expect "1 static: the fresh-init refusal runs again after check_existing_review" 'init_refusals "$INIT"'

# A signal right after the archive claim waits for a checkpoint where the claim is recorded.
for build in repaired mutant; do
  ( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r21m; point demo
    xinit=$INIT
    [[ $build == mutant ]] && mutant_init "$SIGDEFER" "$SIGNOW"
    a=$(snap)
    shim mkdir "$REAL_MKDIR \"\$@\" || exit; case \"\$1\" in */attempts/0??-*) kill -TERM \$PPID;; esac"
    OUT=$(PATH="$W/shim:$PATH" bash "$xinit" --continue "$DESIGN" 2>&1); RC=$?
    rm -f "$W/shim"/*; b=$(snap)
    if [[ $build == repaired ]]; then
      expect "21 TERM right after the archive claim: rolled back byte-identical, no trace" '[[ $RC -eq 1 && "$a" == "$b" ]] && no_trace' "$OUT"
    else
      expect "21 regression proof: an immediate signal orphans the claimed archive" '[[ -d "$D/attempts/001-r21m" ]]' "$OUT"
    fi )
done
# Fresh init holds the same lock from its existing-review check through its pointer write.
( new_fixture; mkdir docs/reviews/.continue.lock
  a=$(snap); init_ "$DESIGN"; b=$(snap)
  expect "21 fresh init refused while a --continue holds the lock, nothing changed" \
    '[[ $RC -eq 1 && "$OUT" == *"docs/reviews/.continue.lock"* && "$a" == "$b" ]]' "$OUT"
  rmdir docs/reviews/.continue.lock; init_ "$DESIGN"
  expect "21 control: fresh init succeeds and releases the lock" \
    '[[ $RC -eq 0 && ! -e docs/reviews/.continue.lock && "$(getf "$S" iteration)" == 1 ]]' "$OUT" )

# uutils mkdir (ubuntu-26.04) can report success on a directory a racing process just
# made, so a claim must not rest on mkdir(1). The shim models it: it never fails on an
# existing directory. Each entry point still refuses the held lock (#1000, #1047).
( new_fixture; write_state demo "$DESIGN"; write_artifacts demo r21u; mkdir docs/reviews/.continue.lock
  shim mkdir "exec $REAL_MKDIR -p \"\$@\""
  a=$(snap); OUT=$(PATH="$W/shim:$PATH" bash "$INIT" --continue "$DESIGN" 2>&1); RC=$?; b=$(snap)
  expect "21 lock held, mkdir that never fails: --continue refuses, nothing changed" \
    '[[ $RC -eq 1 && "$OUT" == *"docs/reviews/.continue.lock"* && "$a" == "$b" ]]' "$OUT"
  OUT=$(PATH="$W/shim:$PATH" bash "$LOOP" --claude-only 2>&1 </dev/null); RC=$?; b=$(snap)
  expect "21 lock held, mkdir that never fails: the loop refuses, nothing changed" \
    '[[ $RC -eq 1 && "$OUT" == *"docs/reviews/.continue.lock"* && "$a" == "$b" ]]' "$OUT" )
( new_fixture; mkdir docs/reviews/.continue.lock; shim mkdir "exec $REAL_MKDIR -p \"\$@\""
  a=$(snap); OUT=$(PATH="$W/shim:$PATH" bash "$INIT" "$DESIGN" 2>&1); RC=$?; b=$(snap)
  expect "21 lock held, mkdir that never fails: fresh init refuses, nothing changed" \
    '[[ $RC -eq 1 && "$OUT" == *"docs/reviews/.continue.lock"* && "$a" == "$b" ]]' "$OUT" )

P=$(grep -c P "$RES"); F=$(grep -c F "$RES")
echo ""
echo "  passed: $P  failed: $F"
[[ $F -eq 0 && $P -gt 0 ]]
