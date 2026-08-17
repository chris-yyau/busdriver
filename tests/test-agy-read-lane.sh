#!/usr/bin/env bash
# test-agy-read-lane.sh — `--cli agy-read` desugaring and reviewer isolation.
#
# No agy binary is invoked. Every case stops before dispatch (bad --mode, bad
# --cli) or inspects the resolver directly, so this runs offline and in CI.
#
# The invariant that matters: `--cli agy` (the blueprint-review reviewer_1 slot)
# must NEVER pick up the read lane's model. That was verified live once
# (2026-08-17: read lane -> "Gemini 3.1 Pro", reviewer -> "Gemini 3.7 Flash",
# from the same config); this file is what keeps it true.

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

check_model '"gemini-3.7-flash-medium"' 'gemini-3.7-flash-medium' \
  'bare agy id is accepted verbatim'
check_model '"gemini-3.1-pro-high"' 'gemini-3.1-pro-high' \
  'a different bare id is honoured (config actually drives the lane)'
# Option injection and junk must degrade to the default, not reach argv.
check_model '"--dangerously-skip-permissions"' 'gemini-3.7-flash-medium' \
  'leading-dash value is rejected (no option injection into agy argv)'
check_model '"has space"' 'gemini-3.7-flash-medium' \
  'whitespace value is rejected'

# ── 4. pi's grammar is unchanged (no cross-contamination) ───────
printf '{"pi":{"model":"bare-no-slash"}}\n' > "$tmp_home/.claude/busdriver.json"
got="$(
  # shellcheck disable=SC1090
  source "$RESOLVE" >/dev/null 2>&1
  HOME="$tmp_home" resolve_pi_model 2>/dev/null
  printf '%s' "$_BD_PI_MODEL"
)"
if [[ "$got" == "opencode-go/deepseek-v4-flash" ]]; then
  pass "pi still requires provider/model (bare id degrades to its default)"
else
  fail "pi grammar leaked the bare shape (got '$got')"
fi

# ── 5. the agy arm scopes reads to CWD ──────────────────────────
# --add-dir is load-bearing: without it agy answers from a remembered workspace
# and cites a different checkout with confident file:line refs.
# Anchored to the INVOCATION shape (leading whitespace, trailing continuation)
# so the prose above that explains --add-dir is not counted as an arg.
# The two readonly sites additionally carry the plan-mode guard (checked below),
# so the optional group is what keeps this counting ALL FOUR rather than the two
# write-path sites — the failure this pattern had on its first run.
# shellcheck disable=SC2016  # literal grep pattern; $PWD must NOT expand here
adddir_sites="$(grep -cE '^[[:space:]]+--add-dir "\$PWD"( \$\{_AGY_READ_LANE:\+--mode plan\})? \\$' "$DISPATCH")"
# shellcheck disable=SC2016  # literal pattern; must not expand
agy_sites="$(grep -cE '^[[:space:]]+_portable_timeout "\$_budget" agy ' "$DISPATCH")"
if [[ "$adddir_sites" == "$agy_sites" && "$adddir_sites" == "4" ]]; then
  pass "all $agy_sites agy call sites pass --add-dir \"\$PWD\""
else
  fail "agy call sites=$agy_sites but --add-dir sites=$adddir_sites (expected both 4)"
fi

# ── 6. the write boundary is --mode plan, on the readonly sites only ──
# LIVE-VERIFIED 2026-08-17, and the reason this check exists: `agy --sandbox`
# alone DID create ./scratch-probe.txt and /tmp/agy-write-probe.txt. Under
# `--mode plan` the identical probe created neither. If this guard regresses,
# the "read lane" silently becomes a writing agent pointed at the working tree.
# shellcheck disable=SC2016  # literal grep pattern; $PWD must NOT expand here
plan_sites="$(grep -cE '^[[:space:]]+--add-dir "\$PWD" \$\{_AGY_READ_LANE:\+--mode plan\} \\$' "$DISPATCH")"
# shellcheck disable=SC2016  # literal pattern; must not expand
sandbox_sites="$(grep -cE '^[[:space:]]+_portable_timeout "\$_budget" agy --sandbox \\$' "$DISPATCH")"
if [[ "$plan_sites" == "$sandbox_sites" && "$plan_sites" == "2" ]]; then
  pass "both --sandbox (readonly) agy sites carry the _AGY_READ_LANE guard"
else
  fail "--sandbox sites=$sandbox_sites but plan-guarded sites=$plan_sites (expected both 2)"
fi

# The guard must be EMPTY for every non-agy-read caller, or reviewer_1 silently
# starts running in plan mode and stops producing review findings.
# shellcheck disable=SC2016  # literal pattern; must not expand
if grep -qE '^_AGY_READ_LANE=""$' "$DISPATCH"; then
  pass "_AGY_READ_LANE defaults empty (no --model/--mode plan for plain agy)"
else
  fail "_AGY_READ_LANE has no empty default — reviewer dispatches may inherit the read model/plan mode"
fi

# ── 7. the read lane never escalates to droid ───────────────────
# The desugar rewrites CLI to plain "agy", so \$name is "agy" in the fallback
# guard and the opencode/pi exemptions do not cover this lane. Without its own
# clause a failed agy-read ships the prompt — and the repo content quoted in it —
# to droid, i.e. a DIFFERENT third party than the one the operator selected at
# .agy_read.model. Plain --cli agy must still escalate.
# shellcheck disable=SC2016  # literal pattern; must not expand
if grep -qE '^[[:space:]]+&& \[\[ -z "\$_AGY_READ_LANE" \]\] \\$' "$DISPATCH"; then
  pass "read lane is exempt from the runtime droid escalation"
else
  fail "no _AGY_READ_LANE clause in the droid-escalation guard — a failed read-lane dispatch would silently re-send to another provider"
fi

# ── 8. the bare grammar's accept/reject boundaries ───────────────
# This validator guards an argv slot, so the REJECT set matters as much as the
# accept set: anything that could become a second option, a path, or a shell
# metacharacter must degrade to the default instead of reaching agy's argv.
# The expected value is read from the constant rather than restated here — the
# staleness invariant in test-auditor-model-config.sh allows the id at exactly
# one place, and duplicating it into this file is what that invariant forbids.
agy_default_line=""
# shellcheck disable=SC2016  # literal pattern; must not expand
if ! agy_default_line="$(grep -oE '^BUSDRIVER_AGY_READ_MODEL_DEFAULT="[^"]+"' "$RESOLVE")"; then
  agy_default_line=""
fi
agy_default="${agy_default_line#*\"}"
agy_default="${agy_default%\"}"

if [[ -z "$agy_default" ]]; then
  fail "could not read BUSDRIVER_AGY_READ_MODEL_DEFAULT from resolve-cli.sh"
else
  # Rejected: each must fall back to the shipped default.
  for bad in '"opencode-go/deepseek-v4-flash"' '"has\ttab"' '"-lead"' '"/lead"' \
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
