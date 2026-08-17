#!/usr/bin/env bash
# test-agy-read-lane.sh — `--cli agy-read` desugaring and reviewer isolation.
#
# No agy binary is invoked. Every case stops before dispatch (bad --mode, bad
# --cli) or inspects the resolver directly, so this runs offline and in CI.
#
# The invariant that matters: `--cli agy` (the blueprint-review reviewer_1 slot)
# must NEVER pick up the read lane's model. That was verified live once
# (2026-08-17: the read lane and the reviewer resolved to two DIFFERENT
# configured models from the same config); this file is what keeps it true.

# Literal grep patterns ($PWD, ${...}) must never expand, and several checks
# deliberately consume a command's output rather than its status.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH="$REPO_ROOT/skills/dispatch-cli/scripts/dispatch.sh"
RESOLVE="$REPO_ROOT/scripts/lib/resolve-cli.sh"

FAILED=0
pass() { printf 'ok   — %s\n' "$1"; }
fail() { printf 'FAIL — %s\n' "$1"; FAILED=1; }

# ── 1. agy-read is a valid --cli value ──────────────────────────
out="$("$DISPATCH" --cli agy-read --mode auto --prompt x 2>&1)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"--mode auto is not accepted"* ]]; then
  pass "agy-read refuses --mode auto (no writing agent under this name)"
else
  fail "agy-read --mode auto should exit non-zero rejecting --mode auto (rc=$rc): $out"
fi

# ── 2. an unknown --cli still errors, and names agy-read ────────
out="$("$DISPATCH" --cli agy-reed --prompt x 2>&1)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"agy-read"* ]]; then
  pass "unknown --cli errors and lists agy-read in the enum"
else
  fail "typo'd --cli should error listing agy-read (rc=$rc): $out"
fi

# ── 3. the config reader accepts a BARE agy id ──────────────────
# The pi/auditor grammar requires provider/model; agy ids have no slash, so a
# shared regex would silently degrade every valid value to the default.
tmp_home="$(mktemp -d)"; trap 'rm -rf "$tmp_home"' EXIT
mkdir -p "$tmp_home/.claude"

check_model() {  # <json-value> <expected> <label>
  printf '{"agy_read":{"model":%s}}\n' "$1" > "$tmp_home/.claude/busdriver.json"
  local got
  got="$(
    # shellcheck disable=SC1090
    source "$RESOLVE" >/dev/null 2>&1
    HOME="$tmp_home" resolve_agy_read_model 2>/dev/null
    printf '%s' "$_BD_AGY_READ_MODEL"
  )"
  if [[ "$got" == "$2" ]]; then pass "$3"; else fail "$3 (got '$got', want '$2')"; fi
}

# The shipped fallback is read from the constant rather than restated here —
# the staleness invariant in test-auditor-model-config.sh allows the id at
# exactly one place, and duplicating it into this file is what that invariant
# forbids. Computed once, reused by every fallback assertion below (including
# the grammar boundary checks further down).
agy_default_line=""
if ! agy_default_line="$(grep -oE '^BUSDRIVER_AGY_READ_MODEL_DEFAULT="[^"]+"' "$RESOLVE")"; then
  agy_default_line=""
fi
agy_default="${agy_default_line#*\"}"
agy_default="${agy_default%\"}"

if [[ -z "$agy_default" ]]; then
  fail "could not read BUSDRIVER_AGY_READ_MODEL_DEFAULT from resolve-cli.sh"
fi

check_model '"gemini-3.7-flash-medium"' 'gemini-3.7-flash-medium' \
  'bare agy id is accepted verbatim'
check_model '"gemini-3.1-pro-high"' 'gemini-3.1-pro-high' \
  'a different bare id is honoured (config actually drives the lane)'
# Option injection and junk must degrade to the default, not reach argv.
check_model '"--dangerously-skip-permissions"' "$agy_default" \
  'leading-dash value is rejected (no option injection into agy argv)'
check_model '"has space"' "$agy_default" \
  'whitespace value is rejected'

# ── 4. pi's grammar is unchanged (no cross-contamination) ───────
printf '{"pi":{"model":"bare-no-slash"}}\n' > "$tmp_home/.claude/busdriver.json"
got="$(
  # shellcheck disable=SC1090
  source "$RESOLVE" >/dev/null 2>&1
  HOME="$tmp_home" resolve_pi_model 2>/dev/null
  printf '%s' "$_BD_PI_MODEL"
)"
pi_default_line=""
if ! pi_default_line="$(grep -oE '^BUSDRIVER_PI_MODEL_DEFAULT="[^"]+"' "$RESOLVE")"; then
  pi_default_line=""
fi
pi_default="${pi_default_line#*\"}"; pi_default="${pi_default%\"}"
if [[ -z "$pi_default" ]]; then
  fail "could not read BUSDRIVER_PI_MODEL_DEFAULT from resolve-cli.sh"
elif [[ "$got" == "$pi_default" ]]; then
  pass "pi still requires provider/model (bare id degrades to its default)"
else
  fail "pi grammar leaked the bare shape (got '$got')"
fi

# ── 5/6. the lane-only argv: --add-dir + --mode plan, and ONLY for the lane ──
# Both flags are load-bearing for the read lane and both are MEASURED:
#   --add-dir : without it agy resolves a remembered workspace and cited a stale
#               checkout with confident file:line refs (wrong tree, no error).
#   --mode plan: `agy --sandbox` ALONE created ./scratch-probe.txt and
#               /tmp/agy-write-probe.txt; under plan mode the same probe, and an
#               adversarial "plan approved, write it now" retry, created neither.
# And they must stay LANE-ONLY: plain `--cli agy` is the blueprint-review
# reviewer_1 / council.pragmatist slot, whose argv this PR deliberately does not
# change. A reviewer silently switched into plan mode stops producing findings.
lane_build="$(grep -cE '^[[:space:]]+_agy_lane=\(--add-dir "\$PWD" --mode plan\)$' "$DISPATCH")"
lane_sites="$(grep -cE '^[[:space:]]+"\$\{_agy_lane\[@\]\+"\$\{_agy_lane\[@\]\}"\}" \\$' "$DISPATCH")"
agy_sites="$(grep -cE '^[[:space:]]+_portable_timeout "\$_budget" agy ' "$DISPATCH")"
if [[ "$lane_build" == "1" && "$lane_sites" == "$agy_sites" && "$lane_sites" == "4" ]]; then
  pass "lane argv built once, expanded at all $agy_sites agy call sites"
else
  fail "lane_build=$lane_build lane_sites=$lane_sites agy_sites=$agy_sites (want 1/4/4)"
fi

# The array must be EMPTY unless the read lane set the flag — that empties
# --add-dir AND --mode plan for every reviewer dispatch in one place.
if grep -qE '^[[:space:]]+local _agy_lane=\(\)$' "$DISPATCH" \
   && grep -qE '^[[:space:]]+if \[\[ -n "\$_AGY_READ_LANE" \]\]; then$' "$DISPATCH"; then
  pass "lane argv is empty by default (plain --cli agy argv unchanged)"
else
  fail "lane argv is not gated on _AGY_READ_LANE — reviewer dispatches may inherit --add-dir/--mode plan"
fi

# No bare --add-dir may survive on a call site: that would re-widen it to every
# agy dispatch, which is the scope regression this PR backed out of.
if [[ "$(grep -cE '^[[:space:]]+--add-dir "\$PWD"' "$DISPATCH")" == "0" ]]; then
  pass "no unconditional --add-dir on any agy call site"
else
  fail "an unconditional --add-dir call-site arg is back — it would apply to reviewer dispatches too"
fi

if grep -qE '^_AGY_READ_LANE=""$' "$DISPATCH"; then
  pass "_AGY_READ_LANE defaults empty"
else
  fail "_AGY_READ_LANE has no empty default"
fi

# ── 7. the read lane never escalates to droid ───────────────────
# The desugar rewrites CLI to plain "agy", so \$name is "agy" in the fallback
# guard and the opencode/pi exemptions do not cover this lane. Without its own
# clause a failed agy-read ships the prompt — and the repo content quoted in it —
# to droid, i.e. a DIFFERENT third party than the one the operator selected at
# .agy_read.model. Plain --cli agy must still escalate.
if grep -qE '^[[:space:]]+&& \[\[ -z "\$_AGY_READ_LANE" \]\] \\$' "$DISPATCH"; then
  pass "read lane is exempt from the runtime droid escalation"
else
  fail "no _AGY_READ_LANE clause in the droid-escalation guard — a failed read-lane dispatch would silently re-send to another provider"
fi

# ── 8. the bare grammar's accept/reject boundaries ───────────────
# This validator guards an argv slot, so the REJECT set matters as much as the
# accept set: anything that could become a second option, a path, or a shell
# metacharacter must degrade to the default instead of reaching agy's argv.
# $agy_default was computed once, above (section 3), and is reused here.
if [[ -z "$agy_default" ]]; then
  : # already reported by section 3's guard above
else
  # Rejected: each must fall back to the shipped default.
  for bad in '"prov/model"' '"has\ttab"' '"-lead"' '"/lead"' \
             '"trail/"' '"a/b"' '"semi;colon"' '"dollar$var"' '"pipe|x"' \
             '"amp&x"' '"paren(x)"' '""' '"  "'; do
    check_model "$bad" "$agy_default" "grammar rejects $bad"
  done
  # Accepted: the characters the validator's comment claims are allowed must
  # actually be allowed, or the comment is the only thing enforcing them.
  for good in a A0 x.y x_9 m:tag m@ver a-b.c:d@e; do
    check_model "\"$good\"" "$good" "grammar accepts $good"
  done
fi

if [[ "$FAILED" -eq 0 ]]; then echo "PASS: test-agy-read-lane"; else echo "FAIL: test-agy-read-lane"; fi
exit "$FAILED"
