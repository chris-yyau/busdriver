#!/usr/bin/env bash
# test-agy-read-lane.sh — `--cli agy-read` desugaring and reviewer isolation.
#
# No agy binary is invoked. Every case stops before dispatch (bad --mode, bad
# --cli) or inspects the resolver directly, so this runs offline and in CI.
#
# The invariants that matter:
#   (a) `--cli agy` (the blueprint-review reviewer_1 slot) must NEVER pick up
#       the read lane's model — verified live once (2026-08-17: the read lane
#       and the reviewer resolved to two DIFFERENT configured models from the
#       same config); and
#   (b) every agy dispatch — the read lane AND the plain `--cli agy` reviewer
#       slots — must scope to the CWD via `--add-dir "$PWD"` (#686), so an
#       unscoped reviewer cannot cite a remembered foreign tree. Sections 5b/5c
#       assert the real argv both reviewer entry points (dispatch.sh and
#       execute_review) reach agy with.

# Literal grep patterns ($PWD, ${...}) must never expand, and several checks
# deliberately consume a command's output rather than its status.
# Literal grep patterns ($PWD, ${...}) must never expand, and several checks
# deliberately consume a command's output rather than its status.
# shellcheck disable=SC2016,SC2312
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
# A JSON number or boolean must degrade to the default rather than being
# stringified by `jq -r` and forwarded verbatim to `agy --model` — jq and the
# python3 fallback must agree on this (PR #687 Codex finding).
check_model '123' "$agy_default" \
  'numeric config value degrades to the default (jq/python parity)'
check_model 'true' "$agy_default" \
  'boolean config value degrades to the default (jq/python parity)'

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

# ── 5/6. the workspace argv: --add-dir UNCONDITIONAL, --mode plan lane-only ──
# Both flags are load-bearing and both are MEASURED (2026-08-17):
#   --add-dir : without it agy resolves a remembered workspace and cited a stale
#               checkout with confident file:line refs (wrong tree, no error).
#               Since #686 it is UNCONDITIONAL — plain `--cli agy` is the
#               blueprint-review reviewer_1 / council.pragmatist slot, and an
#               unscoped reviewer can return findings about a DIFFERENT checkout
#               than the one under review.
#   --mode plan: `agy --sandbox` ALONE created ./scratch-probe.txt and
#               /tmp/agy-write-probe.txt; under plan mode the same probe, and an
#               adversarial "plan approved, write it now" retry, created neither.
#               It stays LANE-ONLY: a reviewer silently switched into plan mode
#               stops producing findings.
scope_build="$(grep -cE '^[[:space:]]+local _agy_lane=\(--add-dir "\$PWD"\)$' "$DISPATCH")"
scope_plan="$(grep -cE '^[[:space:]]+_agy_lane\+=\(--mode plan\)$' "$DISPATCH")"
scope_gate="$(grep -cE '^[[:space:]]+if \[\[ -n "\$_AGY_READ_LANE" \]\]; then$' "$DISPATCH")"
lane_sites="$(grep -cE '^[[:space:]]+"\$\{_agy_lane\[@\]\+"\$\{_agy_lane\[@\]\}"\}" \\$' "$DISPATCH")"
agy_sites="$(grep -cE '^[[:space:]]+_portable_timeout "\$_budget" agy ' "$DISPATCH")"
if [[ "$scope_build" == "1" && "$lane_sites" == "$agy_sites" && "$lane_sites" == "4" ]]; then
  pass "workspace argv built once, expanded at all $agy_sites agy call sites"
else
  fail "scope_build=$scope_build lane_sites=$lane_sites agy_sites=$agy_sites (want 1/4/4)"
fi

# --add-dir must be UNCONDITIONAL: removing it silently re-exposes the reviewer
# slot to agy's remembered workspace (the #686 defect). --mode plan must stay
# gated on the lane.
if [[ "$scope_build" == "1" && "$scope_plan" == "1" && "$scope_gate" == "1" ]]; then
  pass "--add-dir unconditional; --mode plan gated on _AGY_READ_LANE"
else
  fail "--add-dir must be unconditional and --mode plan lane-only (build=$scope_build plan=$scope_plan gate=$scope_gate)"
fi

if grep -qE '^_AGY_READ_LANE=""$' "$DISPATCH"; then
  pass "_AGY_READ_LANE defaults empty"
else
  fail "_AGY_READ_LANE has no empty default"
fi

# ── 5b. the reviewer dispatch resolves the CWD (regression for #686) ──
# Behavioural, not structural: stub agy so it prints its argv, dispatch the
# plain `--cli agy` shape (blueprint-review.reviewer_1 / council.pragmatist)
# from a DISTINCTIVE cwd, and assert the stub received `--add-dir` pointing at
# that cwd and NO `--mode plan`. The defect was a missing flag; a grep-only
# guard could be defeated by moving the flag out of the shared array, so the
# stub observes the real argv.
ags_stub="$(mktemp -d)" || { echo "FAIL — mktemp -d failed for ags_stub"; exit 1; }
ags_cwd="$(mktemp -d)" || { echo "FAIL — mktemp -d failed for ags_cwd"; exit 1; }
cat > "$ags_stub/agy" <<'STUB'
#!/bin/sh
if [ "$1" = "--version" ]; then printf '1.5.0\n'; exit 0; fi
printf 'AGY_ARGV:%s\n' "$*"
STUB
chmod +x "$ags_stub/agy"

out="$(cd "$ags_cwd" && PATH="$ags_stub:$PATH" "$DISPATCH" --cli agy --prompt x 2>&1)"
if [[ "$out" == *"AGY_ARGV:"* && "$out" == *"--add-dir $ags_cwd"* && "$out" != *"--mode plan"* ]]; then
  pass "plain --cli agy (reviewer shape) resolves the dispatch CWD via --add-dir, no --mode plan"
else
  fail "reviewer dispatch must pass --add-dir \"\$PWD\" and no --mode plan (out: $out)"
fi

# The read lane keeps BOTH: --add-dir (the workspace) plus --mode plan (its
# write boundary).
out="$(cd "$ags_cwd" && PATH="$ags_stub:$PATH" "$DISPATCH" --cli agy-read --prompt x 2>&1)"
if [[ "$out" == *"AGY_ARGV:"* && "$out" == *"--add-dir $ags_cwd"* && "$out" == *"--mode plan"* ]]; then
  pass "agy-read keeps --add-dir + --mode plan"
else
  fail "agy-read must pass --add-dir and --mode plan (out: $out)"
fi
rm -rf "$ags_stub" "$ags_cwd"

# ── 5c. execute_review (blueprint-review/litmus reviewer path) scopes too ──
# dispatch_one is not the only agy reviewer entry point: blueprint-review's
# reviewer_1 and litmus-via-agy run through execute_review in
# scripts/lib/resolve-cli.sh, which builds its OWN argv. Both of its agy
# transports must carry `--add-dir "$PWD"` — a reviewer of record must resolve
# the tree under review, not agy's remembered workspace (#686).
er_sites="$(grep -cE '^[[:space:]]+agy --sandbox --add-dir "\$PWD"' "$RESOLVE")"
if [[ "$er_sites" == "2" ]]; then
  pass "execute_review agy arm passes --add-dir \"\$PWD\" on both transports"
else
  fail "execute_review agy arm must pass --add-dir \"\$PWD\" on both transports (found $er_sites/2)"
fi

# Behavioral: stub agy prints its argv; source resolve-cli.sh and run
# execute_review from a DISTINCTIVE cwd; assert the reviewer child was scoped
# to it.
er_cwd="$(mktemp -d)" || { echo "FAIL — mktemp -d failed for er_cwd"; exit 1; }
er_stub="$(mktemp -d)" || { echo "FAIL — mktemp -d failed for er_stub"; exit 1; }
cat > "$er_stub/agy" <<'STUB'
#!/bin/sh
if [ "$1" = "--version" ]; then printf '1.5.0\n'; exit 0; fi
printf 'ER_ARGV:%s\n' "$*"
STUB
chmod +x "$er_stub/agy"
out="$(cd "$er_cwd" && PATH="$er_stub:$PATH" bash -c '
  . "'"$REPO_ROOT"'/scripts/lib/resolve-cli.sh" 2>/dev/null
  execute_review agy "review" 10 2>&1')"
if [[ "$out" == *"ER_ARGV:"* && "$out" == *"--add-dir $er_cwd"* ]]; then
  pass "execute_review (reviewer path) scopes agy to the dispatch CWD"
else
  fail "execute_review agy must pass --add-dir \"\$PWD\" (out: $out)"
fi
rm -rf "$er_cwd" "$er_stub"

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

# ── 8. the audit trail names the read lane, not plain "agy" ─────
# The desugar sets CLI=agy so dispatch mechanics stay on the shared arm, but
# the two lanes send repo content to potentially different third parties and
# differ in write posture — an audit entry that reads plain "agy" cannot tell
# which lane ran. REPORT_CLI_NAME must be captured before CLI is overwritten,
# and OUTFILE/the console status line/log_event must all key off it (falling
# back to $CLI for every other --cli value). (PR #687 Codex finding.)
#
# CodeRabbit finding (PR #687, efcd4b9d): independent `grep -q` checks only
# prove each pattern exists SOMEWHERE in the file — they pass even if
# REPORT_CLI_NAME is captured AFTER $CLI is overwritten, or if REPORT_NAME is
# built from something other than the validated REPORT_CLI_NAME/CLI pair. Pin
# the actual control-flow order with line numbers instead: init empty →
# agy-read desugar capture → REPORT_NAME assignment → vocabulary whitelist →
# OUTFILE construction, each strictly after the last.
line_of() { grep -nE "$1" "$DISPATCH" | head -1 | cut -d: -f1; }

l_init="$(line_of '^REPORT_CLI_NAME=""$')"
l_capture="$(line_of '^[[:space:]]+REPORT_CLI_NAME="agy-read"$')"
l_assign="$(line_of '^[[:space:]]+REPORT_NAME="\$\{REPORT_CLI_NAME:-\$CLI\}"$')"
l_whitelist="$(line_of '^[[:space:]]+codex\|agy\|agy-read\|droid\|grok\|opencode\|pi\) ;;$')"
l_outfile="$(line_of 'OUTFILE="\$\{OUT_DIR\}/dispatch-\$\{REPORT_NAME\}-\$\{STAMP\}\.txt"')"
l_log="$(line_of 'log_event "\$REPORT_NAME"')"
l_console="$(line_of 'echo "\$\{REPORT_NAME\} →')"

if [[ -n "$l_init" && -n "$l_capture" && -n "$l_assign" && -n "$l_whitelist" \
      && -n "$l_outfile" && -n "$l_log" && -n "$l_console" ]] \
   && (( l_init < l_capture && l_capture < l_assign \
         && l_assign < l_whitelist && l_whitelist < l_outfile \
         && l_outfile <= l_log && l_outfile <= l_console )); then
  pass "REPORT_CLI_NAME/REPORT_NAME control-flow order: init < agy-read capture < assign < whitelist < OUTFILE/log/console"
else
  fail "REPORT_CLI_NAME/REPORT_NAME sites are out of order or missing (init=$l_init capture=$l_capture assign=$l_assign whitelist=$l_whitelist outfile=$l_outfile log=$l_log console=$l_console) — audit identity or path safety could regress silently"
fi

# REPORT_CLI_NAME feeds a FILENAME and the audit log, so it is a provenance
# field. It MUST be initialized at top level: without that, an INHERITED
# environment variable would set the logged provider identity and inject path
# components into the output filename on EVERY invocation — and a committed
# .claude/settings.json `env` block is repo-controlled (#325 / ADR 0016), so an
# ambient value is attacker-reachable. Litmus caught this as a HIGH.
if [[ -n "$l_init" ]]; then
  pass "REPORT_CLI_NAME is initialized empty (no inherited-env provenance forgery)"
else
  fail "REPORT_CLI_NAME has no unconditional empty initializer — an inherited env var could forge the audit identity and inject path components into OUTFILE"
fi

# Defense in depth: even if a future edit reintroduces a non-literal source, the
# value must be constrained to the lane vocabulary before it reaches a path.
if [[ -n "$l_whitelist" ]]; then
  pass "REPORT_NAME is whitelisted against the lane vocabulary before use in a path"
else
  fail "REPORT_NAME has no vocabulary whitelist — an unexpected value could reach OUTFILE"
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

# ── 9. jq/python parity across JSON value types ──────────────────
# The reader has TWO backends (jq, then a python3 fallback) and they disagreed:
# `jq -r` stringifies a number/boolean, so `{"model":123}` passed the bare-ID
# regex and reached `agy --model`, while python's isinstance(v,str) rejected it.
# The property that matters is backend-independent: NO non-string JSON type may
# ever survive validation, whichever reader ran. Checked as a table, not one
# example, because the original bug was exactly a missed type.
if [[ -n "$agy_default" ]]; then
  for badtype in 123 -1 0 1.5 true false null '[]' '["a"]' '{}' '{"a":1}'; do
    check_model "$badtype" "$agy_default" "non-string JSON ($badtype) degrades to the default"
  done
fi

# ── 10. agy 1.0.x + the read lane refuses rather than dropping --model ───
# (PR #687 Codex finding.) agy 1.0.x does not support --model (SKILL.md:310),
# but the read lane always resolves $MODEL from .agy_read.model — so every
# agy-read dispatch on a 1.0.x install reaches the /dev/stdin transport
# branches with --model still attached, an unsupported flag on every attempt.
# End-to-end: stub `agy --version` as 1.0.0 on PATH and pass --model explicitly
# (skipping the real-$HOME-derived resolve_agy_read_model path entirely — that
# derivation intentionally ignores an overridden $HOME, so this is the only way
# to exercise the guard without touching the operator's real ~/.claude config).
agy_stub_dir="$(mktemp -d)"
cat > "$agy_stub_dir/agy" <<'STUB'
#!/bin/sh
if [ "$1" = "--version" ]; then printf '1.0.0\n'; exit 0; fi
printf 'AGY_WAS_INVOKED\n'
STUB
chmod +x "$agy_stub_dir/agy"
# Model id deliberately avoids the leak-sweep's vendor-name patterns in
# tests/test-auditor-model-config.sh — this is an arbitrary stand-in, not a
# real provider/model, and the refusal path is triggered by the CLI version
# alone, not by the value.
out="$(PATH="$agy_stub_dir:$PATH" "$DISPATCH" --cli agy-read --model stub-model-3.7 --prompt x 2>&1)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"does not support it"* && "$out" == *"stub-model-3.7"* \
      && "$out" != *"AGY_WAS_INVOKED"* ]]; then
  pass "agy-read on a 1.0.x agy install refuses loudly instead of dropping --model or invoking agy"
else
  fail "agy-read + agy 1.0.0 should refuse before invoking agy (rc=$rc): $out"
fi

# The refusal is NOT lane-scoped (#689). Removing the blanket --model refusal in
# this PR made plain `--cli agy --model X` reachable, so on 1.0.x it would
# forward an unsupported flag and surface agy's own internal error instead of the
# dispatcher's actionable one. Codex (round 7) and Greptile both flagged it.
# The refusal is a HARD exit, not exit_code=1: plain `--cli agy` has no droid
# escalation exemption, so treating a config error as a failed dispatch swallowed
# the message, shipped the prompt to droid (a different third party) and exited
# 0. Asserting "no droid" is the point of this check, and it also keeps the suite
# OFFLINE — the exit_code=1 form fired a live ~17s droid dispatch here.
out="$(PATH="$agy_stub_dir:$PATH" "$DISPATCH" --cli agy --model stub-model-3.7 --prompt x 2>&1)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"does not support it"* && "$out" == *"stub-model-3.7"* \
      && "$out" != *"AGY_WAS_INVOKED"* \
      && "$out" != *"falling back to droid"* && "$out" != *"droid-fallback"* ]]; then
  # (matched on the escalation lines, NOT a bare "droid" — the refusal message
  # itself names droid as an alternative CLI, so a bare match self-defeats.)
  pass "plain --cli agy --model on a 1.0.x install refuses loudly too (not lane-scoped, no droid escalation)"
else
  fail "plain --cli agy --model + agy 1.0.0 should refuse before invoking agy or droid (rc=$rc): $out"
fi

# ...but plain `--cli agy` with NO --model is the reviewer_1 / council.pragmatist
# shape and MUST still reach agy on a 1.0.x install. Guards the widening above
# against over-reach: the predicate is "a model was requested", not "agy is old".
out="$(PATH="$agy_stub_dir:$PATH" "$DISPATCH" --cli agy --prompt x 2>&1)"; rc=$?
if [[ "$out" == *"AGY_WAS_INVOKED"* && "$out" != *"does not support it"* ]]; then
  pass "plain --cli agy with no --model still dispatches on a 1.0.x install"
else
  fail "plain --cli agy (no --model) must still reach agy on 1.0.x (rc=$rc): $out"
fi
rm -rf "$agy_stub_dir"

# ── 10b. an INCONCLUSIVE version probe refuses a model-pinned dispatch ──
# (Codex P2 on PR #687.) `_agy_wants_argv_prompt` bounds `agy --version` at 2s
# and classifies timeout/unparseable as MODERN — the right default for prompt
# delivery, but not evidence of `--model` support. A 1.0.x install whose version
# command is slow was therefore routed down the argv path with `--model`
# attached, skipping the confirmed-1.0.x refusal entirely; and because the read
# lane is exempt from droid escalation, the operator got agy's raw option/path
# error instead of an actionable one. Reproduced with Codex's own shape: a stub
# whose `--version` sleeps past the probe budget.
agyv_stub="$(mktemp -d)"
cat > "$agyv_stub/agy" <<'STUB'
#!/bin/sh
if [ "$1" = "--version" ]; then sleep 3; printf '1.0.0\n'; exit 0; fi
printf 'AGY_WAS_INVOKED\n'
STUB
chmod +x "$agyv_stub/agy"
out="$(PATH="$agyv_stub:$PATH" "$DISPATCH" --cli agy-read --model stub-model-3.7 --prompt x 2>&1)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"support is unconfirmed"* && "$out" == *"stub-model-3.7"* \
      && "$out" != *"AGY_WAS_INVOKED"* && "$out" != *"falling back to droid"* ]]; then
  pass "an inconclusive agy --version probe refuses a model-pinned dispatch (does not assume support)"
else
  fail "slow-version 1.0.x + --model should refuse, not forward --model (rc=$rc): $out"
fi

# Same slow probe, but NO --model: the reviewer_1 / council.pragmatist shape must
# still dispatch. Guards the refusal above against over-reach — the predicate is
# "a model was requested we cannot honour", never "the probe was slow".
out="$(PATH="$agyv_stub:$PATH" "$DISPATCH" --cli agy --prompt x 2>&1)"; rc=$?
if [[ "$out" == *"AGY_WAS_INVOKED"* && "$out" != *"support is unconfirmed"* ]]; then
  pass "an inconclusive probe with no --model still dispatches (reviewer path unaffected)"
else
  fail "plain --cli agy (no --model) must still dispatch on a slow-version install (rc=$rc): $out"
fi
# The conclusive-probe flag must not be forgeable from the environment. A
# committed .claude/settings.json `env` block is repo-controlled (#325 / ADR
# 0016), so an inherited "1" would forge "version confirmed" and re-enable
# exactly the --model forwarding the guard above exists to refuse. Same
# discipline (and same reason) as `_AGY_ARGV_PROMPT`, whose own env-override
# check lives in tests/test-agy-argv-limit.sh.
out="$(PATH="$agyv_stub:$PATH" _AGY_PROBE_CONCLUSIVE=1 "$DISPATCH" --cli agy-read --model stub-model-3.7 --prompt x 2>&1)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"support is unconfirmed"* && "$out" != *"AGY_WAS_INVOKED"* ]]; then
  pass "an inherited _AGY_PROBE_CONCLUSIVE=1 cannot forge version confirmation"
else
  fail "env _AGY_PROBE_CONCLUSIVE=1 must not bypass the inconclusive-probe refusal (rc=$rc): $out"
fi
rm -rf "$agyv_stub"

# ── 11. the lane pins a trusted $HOME on the agy PROCESS ─────────
# (PR #687 Codex P1.) The trusted, password-DB-derived home was originally used
# only to read .agy_read.model, so the agy child still inherited $HOME — which
# `.claude/settings.json` can set from a reviewed checkout. agy loads and
# persists its own ~/.gemini config, auth and plan artifacts from $HOME on EVERY
# invocation, so an inherited one hands the read lane's entire agy configuration
# to the repo under review. Behavioural, not structural: stub agy so it prints
# the $HOME it actually received, dispatch with $HOME pointed at a decoy, and
# assert the child saw the password-DB home. Run for BOTH model paths, because
# the original defect was specifically that `--model` skipped the derivation.
agyh_real="$(eval echo "~$(/usr/bin/id -un)")"
agyh_decoy="$(mktemp -d)"
agyh_stub="$(mktemp -d)"
cat > "$agyh_stub/agy" <<'STUB'
#!/bin/sh
if [ "$1" = "--version" ]; then printf '1.5.0\n'; exit 0; fi
printf 'AGY_SAW_HOME=[%s]\n' "$HOME"
STUB
chmod +x "$agyh_stub/agy"
for agyh_case in explicit-model resolved-model; do
  if [[ "$agyh_case" == explicit-model ]]; then
    set -- --model stub-model-3.7
  else
    set --
  fi
  out="$(HOME="$agyh_decoy" PATH="$agyh_stub:$PATH" \
         "$DISPATCH" --cli agy-read "$@" --prompt x 2>&1)" || true
  if [[ "$out" != *"AGY_SAW_HOME="* ]]; then
    fail "$agyh_case: stub agy was never invoked, so the \$HOME pin is unproven: $out"
  elif [[ "$out" == *"AGY_SAW_HOME=[$agyh_decoy]"* ]]; then
    fail "$agyh_case: agy inherited the injectable \$HOME ($agyh_decoy) instead of the password-DB home"
  elif [[ "$out" == *"AGY_SAW_HOME=[$agyh_real]"* ]]; then
    pass "$agyh_case: agy-read pins the password-DB \$HOME on the agy process"
  else
    fail "$agyh_case: agy saw an unexpected \$HOME (wanted $agyh_real): $out"
  fi
done
set --
rm -rf "$agyh_decoy" "$agyh_stub"

if [[ "$FAILED" -eq 0 ]]; then echo "PASS: test-agy-read-lane"; else echo "FAIL: test-agy-read-lane"; fi
exit "$FAILED"
