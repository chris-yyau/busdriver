#!/bin/bash
# shellcheck disable=SC2016  # grep patterns intentionally contain literal $ ( )
# shellcheck disable=SC2034,SC2329  # run_case's stubs/vars are consumed by the extracted block it sources, not by this file
# tests/test-blueprint-oracle-status-line.sh — guard for the UltraOracle operator
# status line in blueprint-review (#502).
#
# Everything the oracle produces otherwise lands ONLY in the arbiter's prompt file,
# so "did the oracle fire?" was answerable only by opening claude-validation-prompt.txt.
# ADR 0027 closed exactly this gap for the Mechanism Witness; this is the same
# treatment for the oracle.
#
# THE RULE MOST LIKELY TO REGRESS is silence-when-disabled. The oracle is a
# default-OFF USER-config opt-in, so an "absent" line on every review would be
# noise for everyone who never enabled it — unlike k3, which is always-on and whose
# "absent" therefore carries information. A regression here is not a wrong line, it
# is a line printed to every operator on every review forever, so it gets its own
# assertion and a proven-to-fail check.
#
# Structure mirrors tests/test-blueprint-oracle-deadline.sh: golden-grep on the
# wiring, plus an EXECUTABLE pass that extracts the real branch code from source and
# runs it against fabricated fixtures. No live oracle dispatch — CI must never bill
# the oracle.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOOP="$SCRIPT_DIR/skills/blueprint-review/scripts/run-design-review-loop.sh"

passed=0; failed=0
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }

[[ -f "$LOOP" ]] || { fail "missing $LOOP"; echo "Results: $passed passed, $failed failed"; exit 1; }

# Check mktemp explicitly: this file runs without `errexit` (the assertions need to
# keep going past a failure), so an unchecked `tmp=""` would silently rewrite every
# path below into a root-level one — "$tmp/adv-ok.md" becomes "/adv-ok.md".
tmp="$(mktemp -d)" || tmp=""
if [[ -z "$tmp" || ! -d "$tmp" ]]; then
  fail "mktemp -d failed — refusing to run with an empty tmp root"
  echo "Results: $passed passed, $failed failed"; exit 1
fi
trap 'rm -rf "$tmp"' EXIT INT TERM

# ── Layer 1: wiring ──────────────────────────────────────────────────────────
if grep -qE '^  _uora_status_line=""' "$LOOP"; then
  ok "status var pre-initialised at the top of the advisory block (set -u safe)"
else
  fail "_uora_status_line not pre-initialised — set -u abort reachable on the disabled path"
fi

if grep -qE '\[ -n "\$_uora_status_line" \] && log_info' "$LOOP"; then
  ok "status line emitted via log_info, guarded on non-empty"
else
  fail "no guarded log_info emit — the line is either unconditional or missing"
fi

# The tag that keeps an auxiliary from being read as a fourth lens. k3 carries the
# same marker; losing it is how an advisory silently becomes "independent agreement".
if grep -qE 'UltraOracle \(ChatGPT Pro\): ran .*AUXILIARY, not a reviewer' "$LOOP"; then
  ok "success line carries the AUXILIARY-not-a-reviewer tag"
else
  fail "success line lost the AUXILIARY tag — advisory can be miscounted as a 4th lens"
fi

# ── Layer 2: executable — extract the real branch code and run it ────────────
# Pull from the section assignment through the emit, so the assertions below run
# the SAME code the loop runs, not a paraphrase of it.
block="$tmp/block.sh"
awk '/^  ULTRA_ORACLE_ADVISORY_SECTION=""$/{p=1}
     p{print}
     p&&/^  \[ -n "\$_uora_status_line" \] && log_info/{exit}' "$LOOP" > "$block"
if [[ -s "$block" ]] && grep -q '_uora_status_line' "$block"; then
  ok "extracted the advisory/status block from source ($(wc -l < "$block" | tr -d ' ') lines)"
else
  fail "could not extract the advisory block — test cannot verify behaviour"
  echo "Results: $passed passed, $failed failed"; exit 1
fi

# Harness: stub only what the block calls OUT to, never what it decides.
run_case() {
  # $1 = case label, $2 = DISPATCH_STATUS, $3 = advisory file path ("" = unset),
  # $4 = user-config enabled value, $5 = CLAUDE_ONLY
  local _label="$1" _status="$2" _file="$3" _enabled="$4" _conly="$5"
  (
    set -uo pipefail
    log_info()    { printf 'INFO:%s\n'  "$1"; }
    log_warning() { printf 'WARN:%s\n'  "$1"; }
    ultra_oracle_timeout_cap() { printf '10'; }
    _uora_rc_grace()           { printf '2'; }
    _read_config_value()       { printf '%s' "$_enabled"; }
    STATE_DIR=".claude"
    HOME="$tmp/home"
    ULTRA_ORACLE_DISPATCH_STATUS="$_status"
    ULTRA_ORACLE_ADVISORY_FILE="$_file"
    ULTRA_ORACLE_DEADLINE=0
    CLAUDE_ONLY="$_conly"
    # shellcheck source=/dev/null
    . "$block"
  ) 2>&1
}

# A user config must EXIST for the adapter-unloadable branch to consult it.
mkdir -p "$tmp/home/.claude"; printf '{}' > "$tmp/home/.claude/busdriver.json"

expect_line() {
  local _label="$1" _out="$2" _want="$3"
  if printf '%s' "$_out" | grep -qF "$_want"; then
    ok "$_label"
  else
    fail "$_label — want a line containing '$_want', got: $(printf '%s' "$_out" | tr '\n' '|')"
  fi
}

# 1. verdict attached
adv="$tmp/adv-ok.md"; printf 'line one\nline two\nline three\n' > "$adv"; printf '0' > "$adv.rc"
out="$(run_case ok dispatched "$adv" true false)"
expect_line "verdict attached → 'ran (N lines)'" "$out" "UltraOracle (ChatGPT Pro): ran (3 lines -- AUXILIARY, not a reviewer)"

# 2. dispatched, hard timeout
adv="$tmp/adv-124.md"; : > "$adv"; printf '124' > "$adv.rc"
out="$(run_case timeout dispatched "$adv" true false)"
expect_line "rc=124 → 'FAILED -- timeout'" "$out" "UltraOracle (ChatGPT Pro): FAILED -- timeout (auxiliary; review unaffected)"

# 3. dispatched, error WITH an actionable hint (#340) — hint must reach the line
adv="$tmp/adv-hint.md"; : > "$adv"; printf '1' > "$adv.rc"
printf 'sign in to ChatGPT and retry' > "$adv.hint"
out="$(run_case hint dispatched "$adv" true false)"
expect_line "rc=1 + hint → hint folded into the status line" "$out" "FAILED -- error (rc=1) -- sign in to ChatGPT and retry (auxiliary; review unaffected)"

# 4. --claude-only resume: dispatched-status carries the not-harvested string.
#    Must read ABSENT, never FAILED — the ADR 0027 distinction.
adv="$tmp/adv-conly.md"; : > "$adv"
out="$(run_case conly "advisory not harvested before arbiter re-run" "$adv" true true)"
expect_line "claude-only resume → 'absent', not 'FAILED'" "$out" "UltraOracle (ChatGPT Pro): absent -- advisory not harvested before arbiter re-run"
if printf '%s' "$out" | grep -qF "FAILED"; then
  fail "claude-only resume also emitted FAILED — absent and failed are being conflated"
else
  ok "claude-only resume does not also report FAILED"
fi

# 4b. A SKIP is not a failure. The advisory FILE variable is assigned before the
#     consult, so `skipped:user` / `skipped:unavailable` land in the same else-branch
#     as a real failure. Reporting an operator opt-out as FAILED is the exact
#     absent-vs-failed conflation ADR 0027 exists to prevent.
adv="$tmp/adv-skip-user.md"; : > "$adv"
out="$(run_case skipuser "skipped:user" "$adv" true false)"
expect_line "skipped:user → 'absent -- operator opt-out'" "$out" "UltraOracle (ChatGPT Pro): absent -- operator opt-out"
if printf '%s' "$out" | grep -qF "FAILED"; then
  fail "operator opt-out reported as FAILED — a deliberate skip is not a failure"
else
  ok "operator opt-out does not report FAILED"
fi

adv="$tmp/adv-skip-unavail.md"; : > "$adv"
out="$(run_case skipunavail "skipped:unavailable" "$adv" true false)"
expect_line "skipped:unavailable → 'absent -- oracle CLI not available'" "$out" "UltraOracle (ChatGPT Pro): absent -- oracle CLI not available"

# 4c. A verdict whose last line has no trailing newline must not count as 0 lines.
#     `wc -l` counts newlines and would report "ran (0 lines)" — indistinguishable
#     from an empty verdict.
adv="$tmp/adv-nonl.md"; printf 'single line, no trailing newline' > "$adv"; printf '0' > "$adv.rc"
out="$(run_case nonl dispatched "$adv" true false)"
expect_line "verdict without trailing newline → 'ran (1 lines)', not 0" "$out" "ran (1 lines"

# 5. enabled but the adapter never loaded (no advisory file at all)
out="$(run_case unloadable "" "" true false)"
expect_line "enabled + adapter unloadable → 'FAILED -- adapter could not be loaded'" "$out" "UltraOracle (ChatGPT Pro): FAILED -- adapter could not be loaded (auxiliary; review unaffected)"

# 6. THE RULE: surface disabled → completely silent
out="$(run_case disabled "" "" false false)"
if printf '%s' "$out" | grep -q 'UltraOracle'; then
  fail "disabled surface printed a status line — noise on every review for every operator who never enabled it: $(printf '%s' "$out" | tr '\n' '|')"
else
  ok "disabled surface stays SILENT (no UltraOracle line)"
fi

# Prove that guard can fail: the same check against a deliberately unconditional
# emit must trip. A silence assertion that has never been seen to fail is not a guard.
noisy="$tmp/noisy.sh"
sed 's|^  \[ -n "\$_uora_status_line" \] && log_info.*|  log_info "  UltraOracle (ChatGPT Pro): disabled"|' "$block" > "$noisy"
out_noisy="$( block="$noisy"; run_case disabled "" "" false false )"
if printf '%s' "$out_noisy" | grep -q 'UltraOracle'; then
  ok "silence guard fires against an unconditional emit"
else
  fail "silence guard did NOT fire against an unconditional emit — it cannot detect the regression"
fi

echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
