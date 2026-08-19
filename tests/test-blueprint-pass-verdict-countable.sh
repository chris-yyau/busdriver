#!/usr/bin/env bash
# #656: a PASS marker must never be stamped on an arbiter verdict the loop cannot count.
#
# This is the BEHAVIOURAL proof that tests/test-blueprint-early-stop-parks.sh explicitly
# says is still owed ("a CONTRACT test over the script text, NOT an end-to-end
# behavioural test ... The behavioural proof is still owed — see #656"). It drives the
# real loop in --claude-only mode against crafted claude.json verdicts and asserts on the
# design doc that comes out the other end.
#
# Measured against the pre-fix script, every FAIL vector below stamped
# `<!-- design-reviewed: PASS -->` and exited 0 while claude.json said "status": "FAIL".
#
# Usage: bash tests/test-blueprint-pass-verdict-countable.sh [alternate-loop-script]
#   The optional arg points the run at another copy of the loop — use it to prove this
#   test can go RED (point it at a copy with _arbiter_earns_pass removed). A guard whose
#   failure branch has never been observed is not a guard. The copy MUST sit in
#   skills/blueprint-review/scripts/ — the loop sources lib/ relative to its own path, so
#   a copy elsewhere dies at startup and reds out the positive controls instead, which
#   proves nothing about the guard. Observed both directions against HEAD~ this way.
# Intentional command-substitution pipelines throughout (jq | cut, shasum | cut) where
# the inner exit code is not load-bearing; the harness asserts on rc + marker instead.
# shellcheck disable=SC2312
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD
LOOP="${1:-$REPO/skills/blueprint-review/scripts/run-design-review-loop.sh}"
INIT="$REPO/skills/blueprint-review/scripts/init-design-review.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }
[[ -f "$LOOP" ]] || { echo "missing $LOOP"; exit 1; }
[[ -f "$REPO/hooks/gate-scripts/lib/marker_ops.py" ]] \
  || { echo "missing marker_ops.py"; exit 1; }

PASS=0; FAIL=0
ok(){ printf "  PASS  %s\n" "$1"; PASS=$((PASS + 1)); }
no(){ printf "  FAIL  %s :: %s\n" "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

# The design doc deliberately does NOT live under docs/plans/ and is NOT named
# PLAN/DESIGN/ARCHITECTURE: running this suite must not arm the repo's own design-review
# gate for a phantom path (observed while developing this test).
run_case() {  # <case> -> echoes "<rc> <YES|no>"
  local status="$1" issues="$2" seed_pass="${3:-}" raw="${4:-}" work
  work=$(mktemp -d) || return 1
  (
    cd "$work" || exit 1
    git init -q . >/dev/null 2>&1
    mkdir -p spec .claude docs/reviews
    printf '# Repro Design\n\n## Overview\nA design document under review.\n' > spec/repro.md
    # Optional: seed a PASS from a hypothetical earlier converged run, to check that a
    # blocking verdict TAKES IT AWAY rather than quietly leaving it standing.
    case "$seed_pass" in
      seed) printf '\n<!-- design-reviewed: PASS -->\n' >> spec/repro.md ;;
      # Bare-CR document: the gate's reader parses in TEXT mode where \r is a line
      # boundary, so this PASS IS honored — while an LF-only shell grep/sed misses it.
      seed_cr) printf '\r<!-- design-reviewed: PASS -->\r' >> spec/repro.md ;;
    esac
    # Coverage provenance off: the #355 DEGRADED branch would otherwise exit before the
    # stamp site and make every case read "no PASS" — a vacuous green.
    export BLUEPRINT_COVERAGE_PROVENANCE=0
    bash "$INIT" spec/repro.md 5 >/dev/null 2>&1 || exit 90
    local hash rid=deadbeef r
    # Same fallback order as the loop's own compute_spec_hash — a shasum-less box
    # would otherwise hash differently, trip the freshness check, and red out the
    # positive controls for a reason that has nothing to do with the guard.
    hash=$( (shasum -a 256 spec/repro.md 2>/dev/null \
             || sha256sum spec/repro.md 2>/dev/null \
             || python3 -c 'import hashlib;print(hashlib.sha256(open("spec/repro.md","rb").read()).hexdigest())' \
            ) | cut -d' ' -f1)
    for r in agy codex grok; do
      jq -n --arg r "$r" --arg rid "$rid" --arg h "$hash" \
        '{status:"FAIL",reviewer_id:$r,issues:[],metadata:{run_id:$rid,spec_hash:$h,iteration:1}}' \
        > "docs/reviews/repro/$r.json"
    done
    # `raw` writes claude.json VERBATIM — used for shapes jq cannot express
    # (truncated bytes) or that must bypass the metadata jq would supply.
    if [[ -n "$raw" ]]; then
      printf '%s' "$raw" > docs/reviews/repro/claude.json
      bash "$LOOP" --claude-only < /dev/null > run.log 2>&1
      local rrc=$?
      if python3 -I "$REPO/hooks/gate-scripts/lib/marker_ops.py" reviewed spec/repro.md; then
        echo "$rrc YES"
      else
        echo "$rrc no"
      fi
      exit 0
    fi
    # `omit` builds a verdict with NO `issues` key at all — distinct from `issues: null`,
    # which jq's `//` and `?` operators treat differently from a missing field.
    if [[ "$issues" == "omit" ]]; then
      jq -n --arg st "$status" --arg rid "$rid" --arg h "$hash" \
        '{status:$st,reviewer_id:"claude",validation_notes:"fixture",
          metadata:{run_id:$rid,spec_hash:$h,iteration:1}}' > docs/reviews/repro/claude.json
    else
      jq -n --arg st "$status" --arg rid "$rid" --arg h "$hash" --argjson iss "$issues" \
        '{status:$st,reviewer_id:"claude",validation_notes:"fixture",issues:$iss,
          metadata:{run_id:$rid,spec_hash:$h,iteration:1}}' > docs/reviews/repro/claude.json
    fi
    bash "$LOOP" --claude-only < /dev/null > run.log 2>&1
    local rc=$?
    # Asked of the AUTHORITATIVE reader, not grep: grep is LF-only and would report "no"
    # on a bare-CR doc whose marker the gate still honors.
    if python3 -I "$REPO/hooks/gate-scripts/lib/marker_ops.py" reviewed spec/repro.md; then
      echo "$rc YES"
    else
      echo "$rc no"
    fi
  )
  local out=$?
  rm -rf "$work"
  return "$out"
}

# expect <name> <status> <issues-json> <expected-stamp YES|no> <expected-rc> [seed-stale-pass] [raw-claude-json]
expect() {
  local name="$1" status="$2" issues="$3" want_stamp="$4" want_rc="$5" seed="${6:-}" raw="${7:-}" got rc stamp
  got=$(run_case "$status" "$issues" "$seed" "$raw") || { no "$name" "harness error ($got)"; return; }
  rc=${got%% *}; stamp=${got##* }
  if [[ "$stamp" == "$want_stamp" && "$rc" == "$want_rc" ]]; then
    ok "$name (rc=$rc stamped=$stamp)"
  else
    no "$name" "want stamped=$want_stamp rc=$want_rc, got stamped=$stamp rc=$rc"
  fi
}

H='{section:"S",category:"architecture",description:"d",suggestion:"s"}'

echo "== positive controls (must still stamp — otherwise every red below is vacuous) =="
# Without these, ANY environmental early-exit (coverage, freshness, missing CLI) makes
# the whole suite green while proving nothing.
expect "clean verdict stamps PASS" \
  PASS '[]' YES 0
expect "deferred TDD-discoverable HIGH still stamps PASS" \
  FAIL "$(jq -nc "[$H + {severity:\"high\",confidence:0.9,category:\"bugs\"}]")" YES 0
expect "scope-expansion HIGH still stamps PASS" \
  FAIL "$(jq -nc "[$H + {severity:\"high\",confidence:0.9,suggestion:\"OUT OF SCOPE for this PR\"}]")" YES 0
expect "LOW without a confidence field still stamps PASS" \
  PASS "$(jq -nc "[$H + {severity:\"low\",category:\"clarity\"}]")" YES 0

echo "== #656 fail-open vectors (every one stamped PASS before the fix) =="
expect "FAIL with .issues null withholds PASS" \
  FAIL 'null' no 1
expect "FAIL with the issues key absent entirely withholds PASS" \
  FAIL 'omit' no 1
expect "FAIL with 7 HIGH lacking confidence withholds PASS" \
  FAIL "$(jq -nc "[range(7) | $H + {severity:\"high\"}]")" no 1
expect "FAIL with 7 HIGH spelled \"High\" withholds PASS" \
  FAIL "$(jq -nc "[range(7) | $H + {severity:\"High\",confidence:0.9}]")" no 1
expect "FAIL enumerating no issues withholds PASS" \
  FAIL '[]' no 1
# Numeric but BELOW the documented 0.0-1.0 domain: `>= 0.5` drops it exactly like a
# missing field, so a type check alone is not enough. (A confidence ABOVE 1 is the
# harmless direction — it over-counts, so the run is already blocked; that case is in
# the honest-findings group below.)
expect "FAIL with a below-range confidence withholds PASS" \
  FAIL "$(jq -nc "[$H + {severity:\"high\",confidence:-1}]")" no 1
# Parses, but `.issues | length` on it aborts the script under `set -e` — the refusal has
# to happen at intake, before that line, or nothing gets to withhold anything.
expect "FAIL with a non-array .issues withholds PASS" \
  FAIL 'false' no 1
expect "FAIL with an object .issues withholds PASS" \
  FAIL '{"a":{"severity":"high","confidence":0.9}}' no 1

echo "== honest findings (already correct before the fix — pinned so they stay so) =="
# The second of these is the probe #656 left explicitly open: can a run ending
# medium_issues_remaining stamp PASS? Answer, measured: no.
#
# The rc=0 pinned below is NOT part of the #656 guard: it comes from the interactive
# not-converged `break` at the end of the loop, which exits 0 with findings open. That
# is pre-existing and deliberately out of scope here. If it is ever fixed, relax these
# two to stamp-only — a red on the rc alone is not a guard regression.
expect "plan-blocking HIGH writes no PASS" \
  FAIL "$(jq -nc "[$H + {severity:\"high\",confidence:0.9}]")" no 0
expect "plan-blocking MEDIUM writes no PASS" \
  FAIL "$(jq -nc "[$H + {severity:\"medium\",confidence:0.9}]")" no 0
# Above-range confidence: still >= 0.5, so it counts as plan-blocking and blocks the run
# before the guard is consulted. Pinned so the range conjunct cannot be "simplified" into
# something that lets this one through.
expect "above-range confidence still counts as plan-blocking" \
  FAIL "$(jq -nc "[$H + {severity:\"high\",confidence:1.5}]")" no 0

echo "== a stale PASS must not survive a blocking verdict =="
# The readers honor the marker in the doc, never state.md — so a PASS left standing by
# an earlier converged run is a live authorization contradicting the review that just ran.
expect "stale PASS is downgraded when HIGH is found" \
  FAIL "$(jq -nc "[$H + {severity:\"high\",confidence:0.9}]")" no 0 seed
expect "stale PASS is downgraded when the verdict is uncountable" \
  FAIL 'null' no 1 seed
expect "stale PASS is downgraded when .issues is not an array" \
  FAIL 'false' no 1 seed
# The reader treats a bare CR as a line boundary; an LF-only shell strip does not. This
# case fails if the downgrade ever stops going through the reader's own engine.
expect "CR-separated stale PASS is downgraded too" \
  FAIL "$(jq -nc "[$H + {severity:\"high\",confidence:0.9}]")" no 0 seed_cr

echo "== the downgrade must precede every fail-closed exit, not follow them =="
# Codex on bceb00e7: the downgrade originally sat AFTER the freshness and JSON gates, so
# a verdict that died at one of THEM left the prior PASS standing — the fail-open reachable
# through the guards added to close it. The trigger is "a verdict file is present".
expect "stale run_id exits without leaving a PASS" \
  FAIL '[]' no 1 seed '{"status":"FAIL","reviewer_id":"claude","issues":[],"metadata":{"run_id":"wrongrun","spec_hash":"deadbeef","iteration":1}}'
expect "truncated verdict JSON exits without leaving a PASS" \
  FAIL '[]' no 1 seed '{"status":"FAIL","reviewer_id":"claude","issues":[{"severity":"hi'

echo "== downgrade-pass must not write through a symlink =="
# Codex on bceb00e7: os.replace() installs the new inode AT the given path, so on a
# symlink it replaces the LINK while the open() that read it followed to the TARGET —
# the target keeps its PASS and the link is destroyed. Checked directly against the
# engine, because the loop refuses such a document before any verdict is classified.
# Guarded: this harness runs without `set -e`, so an unchecked mktemp failure would
# leave $sym_work empty and every path below would resolve to /target.md and /link.md.
if ! sym_work=$(mktemp -d) || [[ -z "$sym_work" || ! -d "$sym_work" ]]; then
  no "symlink downgrade is refused" "mktemp -d failed — symlink checks not run"
else
printf '# Doc\n\n<!-- design-reviewed: PASS -->\n' > "$sym_work/target.md"
ln -s "$sym_work/target.md" "$sym_work/link.md"
MO="$REPO/hooks/gate-scripts/lib/marker_ops.py"
if python3 -I "$MO" downgrade-pass "$sym_work/link.md"; then
  no "symlink downgrade is refused" "exited 0 — it wrote through the link"
else
  ok "symlink downgrade is refused"
fi
if [[ -L "$sym_work/link.md" ]]; then ok "the symlink still exists"; else no "the symlink still exists" "replaced by a regular file"; fi
if grep -q 'design-reviewed: PASS' "$sym_work/target.md"; then
  ok "the target is untouched (no silent no-op downgrade)"
else
  no "the target is untouched" "target was rewritten via the link"
fi
# Control: the same engine MUST still downgrade a plain regular file, or the guard
# above would be indistinguishable from a broken downgrade.
if python3 -I "$MO" downgrade-pass "$sym_work/target.md" \
   && grep -q 'design-reviewed: PENDING' "$sym_work/target.md"; then
  ok "a regular file still downgrades (control)"
else
  no "a regular file still downgrades (control)" "the guard broke the normal path"
fi
rm -rf "$sym_work"
fi

printf "\n  %d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
