#!/usr/bin/env bash
# shellcheck disable=SC2310,SC2312  # assertions intentionally use command substitution
# shellcheck disable=SC2015  # `ok` always returns 0, so A && ok || fail is a real if-then-else here
# shellcheck disable=SC2016  # golden-grep patterns intentionally contain literal $
# shellcheck disable=SC2034  # BUSDRIVER_STATE_DIR is read by the sourced library, not this file
# tests/test-auditor-model-config.sh — guard for resolve_auditor_model().
#
# The opencode Auditor / Mechanism Witness model used to be hardcoded at two
# dispatch sites. It now comes from the USER busdriver.json (.auditor.model).
# Three properties have to hold, and each has a real failure mode:
#   1. USER config only — a reviewed fork controls its own project
#      .claude/busdriver.json; honoring it would let a hostile branch redirect
#      the witness prompt to a third party of its choosing (#325 class).
#   2. Invalid values degrade to the default — the value lands in argv after
#      `-m`, so a leading `-` is option injection; an auxiliary voice must not
#      die on a typo either.
#   3. No hardcoded model id survives at the dispatch sites.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/resolve-cli.sh"
DISPATCH="$ROOT/skills/dispatch-cli/scripts/dispatch.sh"

passed=0; failed=0
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
eq()   { if [[ "$1" == "$2" ]]; then ok "$3 → $1"; else fail "$3 → got '$1', want '$2'"; fi }

for f in "$LIB" "$DISPATCH"; do
  [[ -f "$f" ]] || { fail "missing $f"; echo "Results: $passed passed, $failed failed"; exit 1; }
done

# ── Executable: resolve_auditor_model under a fake HOME ──────────
FAKE_HOME="$(mktemp -d)"
trap 'rm -rf "$FAKE_HOME"' EXIT
mkdir -p "$FAKE_HOME/.claude"

# Run in a subshell with HOME redirected so the real user config is untouched.
resolve() {  # <json-or-empty> → stdout model, stderr dropped unless $2=keep-stderr
  if [[ -n "$1" ]]; then printf '%s' "$1" > "$FAKE_HOME/.claude/busdriver.json"
  else rm -f "$FAKE_HOME/.claude/busdriver.json"; fi
  ( HOME="$FAKE_HOME" BUSDRIVER_STATE_DIR=".claude"
    # shellcheck source=/dev/null
    source "$LIB"
    if [[ "${2:-}" == "keep-stderr" ]]; then resolve_auditor_model 2>&1
    else resolve_auditor_model 2>/dev/null; fi
    printf '%s' "$_BD_AUDITOR_MODEL" )
}

# The auditor has NO shipped default, deliberately. A built-in model id is only
# ever consulted by an operator who configured none — the one person guaranteed
# to hold no credential for whichever provider we picked — so it cannot work by
# default, and it goes stale. Unconfigured now means the advisory voice is
# SKIPPED. Assert the constant stays deleted: reintroducing one silently
# restores both the failure mode and the drift class this test exists to catch.
if grep -qE '^BUSDRIVER_AUDITOR_MODEL_DEFAULT=' "$LIB"; then
  fail "BUSDRIVER_AUDITOR_MODEL_DEFAULT is back in $LIB — the auditor must ship no default model"
else
  ok "no shipped auditor default constant in $LIB"
fi
# Every unconfigured/rejected case below resolves to the empty string.
DEFAULT=""

# dispatch.sh's library-missing shim must resolve to empty for the same reason:
# with no library there is no config reader, and inventing a model there would
# reintroduce exactly the default we just deleted.
SHIM_DEFAULT="$(grep -E 'resolve_auditor_model\(\) \{ _BD_AUDITOR_MODEL=' "$DISPATCH" | cut -d'"' -f2)"
eq "$SHIM_DEFAULT" "" "dispatch.sh shim resolves the auditor to empty (no default)"

# pi's shim mirrors the auditor's: same library-missing fallback pattern, same
# drift risk between dispatch.sh's shim literal and the LIB constant. The
# golden-grep leak sweep below exempts PI_MODEL_DEFAULT/resolve_pi_model() from
# the "one place a model name lives" invariant on the assumption this asserts
# they stay in sync — without this, a silent divergence would still pass green.
PI_DEFAULT="$(grep -E '^BUSDRIVER_PI_MODEL_DEFAULT=' "$LIB" | cut -d'"' -f2)"
[[ -n "$PI_DEFAULT" ]] && ok "pi default constant present → $PI_DEFAULT" || fail "no BUSDRIVER_PI_MODEL_DEFAULT in $LIB"
PI_SHIM_DEFAULT="$(grep -E 'resolve_pi_model\(\) \{ _BD_PI_MODEL=' "$DISPATCH" | cut -d'"' -f2)"
eq "$PI_SHIM_DEFAULT" "$PI_DEFAULT" "dispatch.sh pi shim default matches BUSDRIVER_PI_MODEL_DEFAULT"

eq "$(resolve '')"                                        "$DEFAULT"        "no config → empty (voice skipped)"
eq "$(resolve '{}')"                                      "$DEFAULT"        "empty config → empty (voice skipped)"
eq "$(resolve '{"auditor":{"model":"zenmux/deepseek/deepseek-v4-pro"}}')" \
   "zenmux/deepseek/deepseek-v4-pro"                                        "configured model honored"
eq "$(resolve '{"auditor":{"model":"opencode-go/kimi-k3"}}')" \
   "opencode-go/kimi-k3"                                                    "provider switch honored"
eq "$(resolve '{"auditor":{"model":"zenmux/moonshotai/kimi-k2.7-code:free"}}')" \
   "zenmux/moonshotai/kimi-k2.7-code:free"                                  "colon-tagged variant accepted"
eq "$(resolve '{"auditor":{"model":"google-vertex-anthropic/claude-sonnet-4@20250514"}}')" \
   "google-vertex-anthropic/claude-sonnet-4@20250514"                       "at-tagged variant (Vertex Anthropic) accepted"
eq "$(resolve '{"auditor":{"model":"openai/gpt-5.2#high"}}')" \
   "openai/gpt-5.2#high"                                                    "hash-tagged OpenCode variant accepted"
eq "$(resolve '{"auditor":{"model":"--dangerously-x"}}')"  "$DEFAULT"        "leading-dash rejected"
eq "$(resolve '{"auditor":{"model":"a b"}}')"              "$DEFAULT"        "whitespace rejected"
eq "$(resolve '{"auditor":{"model":"kimi"}}')"             "$DEFAULT"        "providerless (no slash) rejected"
eq "$(resolve '{"auditor":{"model":"zenmux/"}}')"          "$DEFAULT"        "empty segment rejected"
eq "$(resolve 'not json at all')"                          "$DEFAULT"        "corrupt config → empty (voice skipped)"

# Traversal via BUSDRIVER_STATE_DIR (repo-injectable through settings.json) must
# not escape the home dir into a path the reviewed repo can plant.
printf '%s' '{"auditor":{"model":"zenmux/evil/model"}}' > "$FAKE_HOME/busdriver.json"
got="$( HOME="$FAKE_HOME" BUSDRIVER_STATE_DIR="../$(basename "$FAKE_HOME")" bash -c \
        'source "$0"; resolve_auditor_model 2>/dev/null; printf "%s" "$_BD_AUDITOR_MODEL"' "$LIB" )"
eq "$got" "$DEFAULT" "traversal in BUSDRIVER_STATE_DIR rejected"

# A NESTED relative segment needs no traversal: the reviewed checkout normally
# lives under the trusted home, so this would read the fork's own committed
# config. Must be rejected too — single path segment only.
mkdir -p "$FAKE_HOME/projects/reviewed/.claude"
printf '%s' '{"auditor":{"model":"zenmux/evil/model"}}' > "$FAKE_HOME/projects/reviewed/.claude/busdriver.json"
got="$( HOME="$FAKE_HOME" BUSDRIVER_STATE_DIR="projects/reviewed/.claude" bash -c \
        'source "$0"; resolve_auditor_model 2>/dev/null; printf "%s" "$_BD_AUDITOR_MODEL"' "$LIB" )"
eq "$got" "$DEFAULT" "nested BUSDRIVER_STATE_DIR (checkout under \$HOME) rejected"

# And the shape a sanitizer cannot catch: a bare single segment naming a checkout
# at $HOME/reviewed, whose busdriver.json the fork commits itself. Only pinning
# the location rejects this — which is why the resolver pins `.claude`.
mkdir -p "$FAKE_HOME/reviewed"
printf '%s' '{"auditor":{"model":"zenmux/evil/model"}}' > "$FAKE_HOME/reviewed/busdriver.json"
got="$( HOME="$FAKE_HOME" BUSDRIVER_STATE_DIR="reviewed" bash -c \
        'source "$0"; resolve_auditor_model 2>/dev/null; printf "%s" "$_BD_AUDITOR_MODEL"' "$LIB" )"
eq "$got" "$DEFAULT" "bare BUSDRIVER_STATE_DIR naming a checkout dir rejected"

# The whole BASH_FUNC_* class in one shot. An attacker-controlled function table
# shadows every command word an in-shell reader could use — `jq`, `command`,
# `printf`, and even `local`/`return` — so the read happens in an `env -i` child,
# which drops the exported functions along with the rest of the environment.
# `_JSON_PARSER*` are listed too: they steered the old in-shell reader.
printf '%s' '{"auditor":{"model":"zenmux/deepseek/deepseek-v4-pro"}}' > "$FAKE_HOME/.claude/busdriver.json"
EVIL="$(mktemp -d)"; printf '#!/bin/sh\necho zenmux/evil/model\n' > "$EVIL/evil"; chmod +x "$EVIL/evil"
got="$( cd "$EVIL" && HOME="$FAKE_HOME" _JSON_PARSER=jq _JSON_PARSER_BIN="$EVIL/evil" \
        env "BASH_FUNC_jq%%=() { echo 'zenmux/evil/model'; }" \
            "BASH_FUNC_command%%=() { echo '$EVIL/evil'; }" \
            "BASH_FUNC_printf%%=() { echo 'zenmux/evil/model'; }" \
        bash -c 'source "$0"; resolve_auditor_model 2>/dev/null; builtin echo "$_BD_AUDITOR_MODEL"' "$LIB" 2>/dev/null )"
rm -rf "$EVIL"
eq "$got" "zenmux/deepseek/deepseek-v4-pro" "injected shell functions + _JSON_PARSER* cannot forge the model"

# A host with python3 but no jq must still honour a configured provider — the
# child tries jq first, python3 second. Simulated by pointing the jq loop at a
# path that cannot exist.
NOJQ="$(mktemp -d)/rc.sh"
sed 's|for b in /opt/homebrew/bin/jq /usr/local/bin/jq /usr/bin/jq /bin/jq; do|for b in /nonexistent/jq; do|' "$LIB" > "$NOJQ"
printf '%s' '{"auditor":{"model":"zenmux/deepseek/deepseek-v4-pro"}}' > "$FAKE_HOME/.claude/busdriver.json"
got="$( HOME="$FAKE_HOME" bash -c 'source "$0"; resolve_auditor_model 2>/dev/null; printf "%s" "$_BD_AUDITOR_MODEL"' "$NOJQ" )"
rm -rf "$(dirname "$NOJQ")"
eq "$got" "zenmux/deepseek/deepseek-v4-pro" "python3 fallback honours the config when jq is absent"

# Captured, not piped: `grep -q` exits on first match and would SIGPIPE the
# producer, which `pipefail` then reports as a failed pipeline.
noisy="$(resolve '{"auditor":{"model":"-x"}}' keep-stderr)"
if [[ "$noisy" == *"ignoring invalid"* ]]; then
  ok "invalid value is announced on stderr (not silent)"
else
  fail "invalid value degraded silently — no 'ignoring invalid' note"
fi

# USER config only: a project config in CWD must not be read.
PROJ="$(mktemp -d)"
mkdir -p "$PROJ/.claude"
printf '%s' '{"auditor":{"model":"zenmux/evil/model"}}' > "$PROJ/.claude/busdriver.json"
got="$( cd "$PROJ" && HOME="$FAKE_HOME" BUSDRIVER_STATE_DIR=".claude" bash -c \
        'rm -f "$HOME/.claude/busdriver.json"; source "$0"; resolve_auditor_model 2>/dev/null; printf "%s" "$_BD_AUDITOR_MODEL"' "$LIB" )"
rm -rf "$PROJ"
eq "$got" "$DEFAULT" "project .claude/busdriver.json ignored (USER config only)"

# P1 regression: an inherited/exported function named resolve_auditor_model
# must not be trusted merely because `type` finds it — only a successfully-
# sourced resolve-cli.sh should skip the library-missing shim. Simulate a
# missing library (BUSDRIVER_PLUGIN_ROOT with no scripts/lib/resolve-cli.sh),
# export a poisoned resolve_auditor_model ahead of time, and confirm the
# shim's built-in default still wins rather than the exported function.
EMPTY_ROOT="$(mktemp -d)"
mkdir -p "$EMPTY_ROOT/scripts/lib"
# Anchor on markers rather than line numbers (fragile against future edits):
# from `set -euo pipefail` through the resolve_auditor_model shim's own
# defining line (the line that assigns the built-in default literal), then
# through that block's closing `fi`.
PREAMBLE="$(awk '
  /^set -euo pipefail$/ { p = 1 }
  p { print }
  /resolve_auditor_model\(\) \{/ { seen = 1 }
  seen && /^fi$/ { exit }
' "$DISPATCH")"
got="$( BUSDRIVER_PLUGIN_ROOT="$EMPTY_ROOT" bash -c "
  resolve_auditor_model() { _BD_AUDITOR_MODEL='zenmux/evil/model'; }
  export -f resolve_auditor_model
  $PREAMBLE
  resolve_auditor_model
  printf '%s' \"\$_BD_AUDITOR_MODEL\"
" )"
rm -rf "$EMPTY_ROOT"
eq "$got" "" "exported resolve_auditor_model cannot bypass the library-missing shim (P1)"

# ── Golden-grep: no model id hardcoded at either dispatch site ───
if grep -nE '^[^#]*-m +[A-Za-z0-9][A-Za-z0-9._/-]*/' "$LIB" "$DISPATCH"; then
  fail "a literal model id is still hardcoded after -m (see lines above)"
else
  ok "neither dispatch site hardcodes a model id after -m"
fi

# ── The empty-model guard, proven to fire AND to stay out of the way ──
# Deleting the default made "no model" reachable, so an empty `-m` must never
# get to opencode — it would silently run that CLI's own default, i.e. a
# provider nobody chose. Two things are asserted: the guard EXISTS at both
# dispatch sites and sits BEFORE the -m line, and its real condition text
# evaluates correctly in both directions. A guard never observed failing is not
# a guard, so the behavioural check evals the grepped line rather than a
# hand-copied duplicate that could drift from it.

guard_before_dispatch() {   # <file> <guard-regex> <dispatch-regex> <label>
  local f="$1" g="$2" d="$3" label="$4" gl dl
  gl="$(grep -nE "$g" "$f" | head -1 | cut -d: -f1)"
  dl="$(grep -nE "$d" "$f" | head -1 | cut -d: -f1)"
  if [[ -z "$gl" ]]; then fail "$label: empty-model guard is missing"
  elif [[ -z "$dl" ]]; then fail "$label: could not find the -m dispatch line"
  elif (( gl < dl )); then ok "$label: guard at line $gl precedes -m at line $dl"
  else fail "$label: guard (line $gl) does not precede -m (line $dl)"
  fi
}
guard_before_dispatch "$LIB" \
  'if \[\[ -z "\$_BD_AUDITOR_MODEL" \]\]; then' \
  '\-m "\$_BD_AUDITOR_MODEL"' "resolve-cli.sh"
guard_before_dispatch "$DISPATCH" \
  'if \[\[ -z "\$\{MODEL:-\}" && -z "\$_BD_AUDITOR_MODEL" && "\$\{_BD_RESOLVE_CLI_SOURCED:-0\}" == "1" \]\]; then' \
  '\-m "\$\{MODEL:-\$_BD_AUDITOR_MODEL\}"' "dispatch.sh"

# Ordering alone is NOT protection — dispatch.sh's guard only sets exit_code=1, so
# what actually stops the launch is the `exit_code -eq 0` gate between them. A PR
# reviewer read the guard as non-blocking precisely because the ordering assertion
# above does not prove this. Assert the gate really sits in between.
_g="$(grep -nE 'if \[\[ -z "\$\{MODEL:-\}" && -z "\$_BD_AUDITOR_MODEL" && "\$\{_BD_RESOLVE_CLI_SOURCED:-0\}" == "1" \]\]; then' "$DISPATCH" | head -1 | cut -d: -f1)"
_m="$(grep -nE '\-m "\$\{MODEL:-\$_BD_AUDITOR_MODEL\}"' "$DISPATCH" | head -1 | cut -d: -f1)"
_gate="$(awk -v a="$_g" -v b="$_m" 'NR>a && NR<b && /if \[\[ "\$exit_code" -eq 0 \]\]; then/{print NR; exit}' "$DISPATCH")"
if [[ -n "$_gate" ]]; then
  ok "dispatch.sh: exit_code gate at line $_gate stands between the guard and -m"
else
  fail "dispatch.sh: nothing gates -m on exit_code between lines $_g and $_m — the guard would NOT stop the launch"
fi

# Both guards bail BEFORE the sandbox is staged, which is what makes "no cleanup
# on this path" correct. If someone moves the $_oc_cwd allocation above a guard,
# that bail starts leaking a temp dir and the reasoning in both comments silently
# becomes false — so pin the ordering rather than the prose.
cwd_alloc_after_guard() {   # <file> <guard-regex> <label>
  local f="$1" g="$2" label="$3" gl al
  gl="$(grep -nE "$g" "$f" | head -1 | cut -d: -f1)"
  # [[:space:]] not \s — \s is a GNU extension, not POSIX ERE, so a BSD/macOS
  # grep can silently fail to match the indented assignment and turn this into a
  # false FAIL (or, worse, a false pass elsewhere).
  al="$(grep -nE '^[[:space:]]*_oc_cwd="\$\{_BD_OC_SANDBOX_HOME\}/\.cwd"' "$f" | head -1 | cut -d: -f1)"
  if [[ -z "$gl" || -z "$al" ]]; then fail "$label: could not locate guard ($gl) or _oc_cwd allocation ($al)"
  elif (( al > gl )); then ok "$label: sandbox allocated at $al, after the guard at $gl (nothing to clean up)"
  else fail "$label: _oc_cwd allocated at $al BEFORE the guard at $gl — the no-cleanup bail now leaks a temp dir"
  fi
}
cwd_alloc_after_guard "$LIB" 'if \[\[ -z "\$_BD_AUDITOR_MODEL" \]\]; then' "resolve-cli.sh"
cwd_alloc_after_guard "$DISPATCH" 'if \[\[ -z "\$\{MODEL:-\}" && -z "\$_BD_AUDITOR_MODEL" && "\$\{_BD_RESOLVE_CLI_SOURCED:-0\}" == "1" \]\]; then' "dispatch.sh"

# The library skip must return 4 (SKIPPED), not 1 (failed) or 3 (BUILTIN_FALLBACK).
# blueprint-review treats any nonzero as "witness failed or returned empty", so
# collapsing this into 1 reports the Mechanism Witness as FAILED for a config key
# the operator simply never set — the ABSENT-vs-FAILED distinction from ADR 0027.
LOOP="$ROOT/skills/blueprint-review/scripts/run-design-review-loop.sh"
if awk '/if \[\[ -z "\$_BD_AUDITOR_MODEL" \]\]; then/{f=1} f&&/return 4/{print;exit}' "$LIB" | grep -q 'return 4'; then
  ok "resolve-cli.sh no-model guard returns 4 (SKIPPED), not a generic failure"
else
  fail "resolve-cli.sh no-model guard does not return 4 — blueprint-review will call it FAILED"
fi
grep -qF '"$_aud_exit" -eq 4' "$LOOP" \
  && ok "blueprint-review handles rc=4 as a distinct witness state" \
  || fail "blueprint-review does not branch on rc=4 in $LOOP"

# Structural presence is not routing. A PR reviewer read the rc=4 arm as
# unreachable, reasoning that execute_review's stderr warning lands in $_aud_raw
# (2>&1), so the non-empty first branch wins and the warning gets parsed as JSON.
# That misses the `-eq 0` conjunct on that branch — but nothing in-tree proved it,
# so prove it here: run the SHIPPED classification block with stubs, seeding
# $_aud_raw with exactly that stderr warning, and check where each rc lands.
_route() {   # <rc> → the message the block produces
  ( set +e
    local BLOCK; BLOCK="$(awk '/^      if \[\[ "\$_aud_exit" -eq 0 \]\]/,/^      fi$/' "$LOOP")"
    create_error_json() { printf 'msg=%s' "$2"; }
    python3() { return 1; }        # reachable only from the first branch
    SCRIPT_DIR=/nonexistent; AUDITOR_OUTPUT_FILE=/dev/null
    local _aud_exit="$1" _aud_raw _aud_tmp
    _aud_raw="$(mktemp)"; _aud_tmp="$(mktemp)"
    # The exact shape the reviewer described: non-empty, and NOT valid JSON.
    printf 'busdriver: no usable .auditor.model ... skipping the Mechanism Witness\n' > "$_aud_raw"
    eval "$BLOCK" >/dev/null 2>&1
    cat "$_aud_tmp"; rm -f "$_aud_raw" "$_aud_tmp" )
}
case "$(_route 4)" in
  *"no .auditor.model configured"*) ok "rc=4 routes to ABSENT even when \$_aud_raw holds the stderr warning" ;;
  *"unparseable"*) fail "rc=4 was parsed as review output — the absent branch is unreachable" ;;
  *) fail "rc=4 routed somewhere unexpected: $(_route 4)" ;;
esac
case "$(_route 1)" in
  *"failed or returned empty"*) ok "rc=1 still routes to FAILED (absent branch did not swallow it)" ;;
  *) fail "rc=1 no longer routes to the failure branch: $(_route 1)" ;;
esac
# The absent-vs-failed render keys off the message text, so the rc=4 artifact must
# carry a phrase the case statement matches — otherwise it prints FAILED anyway.
grep -qF 'no .auditor.model configured' "$LOOP" \
  && ok "rc=4 artifact carries an ABSENT-matching message" \
  || fail "rc=4 message will not match the absent render case in $LOOP"

# The skip must classify as `skipped`, never `error`: as `error` an absent
# optional .auditor.model would fail an entire `--cli all` batch for every other
# voice whenever opencode is installed (the #594 failure mode). And the flag must
# be `local` to dispatch_one — a leak across calls would mark a later voice
# skipped for an earlier one's missing config.
grep -qE '^[[:space:]]*local _oc_no_model=0' "$DISPATCH" \
  && ok "_oc_no_model is local to dispatch_one (no cross-call leak)" \
  || fail "_oc_no_model is not declared local in $DISPATCH"
grep -qE '\[\[ "\$\{_oc_no_model:-0\}" == "1" \]\] && status="skipped"' "$DISPATCH" \
  && ok "no-model bail classifies as skipped, not error" \
  || fail "_oc_no_model is not wired to status=skipped in $DISPATCH"
# Routing an opencode bail to `skipped` is conditional on the reason reaching
# "$outfile" — stderr alone would print "(no output)" in the batch banner.
grep -qF 'printf '"'"'Skipped: %s\n'"'"'' "$DISPATCH" \
  && ok "skip reason is written to \$outfile (not stderr alone)" \
  || fail "no-model skip does not write its reason to \$outfile"

GUARD_COND="$(grep -F 'if [[ -z "${MODEL:-}" && -z "$_BD_AUDITOR_MODEL" && "${_BD_RESOLVE_CLI_SOURCED:-0}" == "1" ]]; then' "$DISPATCH")"
if [[ -z "$GUARD_COND" ]]; then
  fail "could not extract the dispatch.sh guard condition to exercise it"
else
  run_guard() {   # <auditor-model> [<--model override>] [<sourced:0|1>] → fire | dispatch
    # Fixed, locally-defined equivalent of the SHIPPED condition — GUARD_COND
    # above only structurally proves dispatch.sh still carries this exact line;
    # it is never eval'd. CodeRabbit finding on PR #666: `eval`ing
    # repository-extracted text is an injection vector (CWE-78) even when the
    # source is a trusted in-repo file, because a malformed or maliciously
    # edited line could append parseable shell after "then".
    ( MODEL="${2:-}"; _BD_AUDITOR_MODEL="$1"; _BD_RESOLVE_CLI_SOURCED="${3:-1}"
      if [[ -z "${MODEL:-}" && -z "$_BD_AUDITOR_MODEL" && "${_BD_RESOLVE_CLI_SOURCED:-0}" == "1" ]]; then
        printf fire
      else
        printf dispatch
      fi )
  }
  eq "$(run_guard '')"                    "fire"     "guard FIRES: no .auditor.model and no --model (resolver sourced)"
  eq "$(run_guard 'opencode-go/model-x')" "dispatch" "guard stands down: .auditor.model configured"
  eq "$(run_guard '' 'openai/gpt-5.2')"   "dispatch" "guard stands down: --model given"
  # Cubic finding (PR #666): when resolve-cli.sh was NOT sourced, the fallback
  # shim (resolve_auditor_model() { _BD_AUDITOR_MODEL=""; }) makes
  # $_BD_AUDITOR_MODEL empty unconditionally — without the _BD_RESOLVE_CLI_SOURCED
  # conjunct this guard would still fire and classify a genuine fail-closed
  # resolver error as `skipped` (status=skipped via _oc_no_model), letting
  # `--cli all` exit 0 while the operator's ~/.opencode home config was never
  # actually validated. The guard must stand DOWN here so the dedicated
  # "resolve-cli.sh not sourced" branch below it — which classifies as `error`
  # — is what fires instead.
  eq "$(run_guard '' '' 0)" "dispatch" "guard stands down when resolve-cli.sh was NOT sourced (falls through to the error branch, not skipped)"
fi

grep -qE '\-m "\$_BD_AUDITOR_MODEL"' "$LIB" \
  && ok "resolve-cli.sh opencode arm dispatches the resolved model" \
  || fail "resolve-cli.sh opencode arm no longer uses \$_BD_AUDITOR_MODEL"
grep -qE '\-m "\$\{MODEL:-\$_BD_AUDITOR_MODEL\}"' "$DISPATCH" \
  && ok "dispatch.sh honors --model then the config resolver" \
  || fail "dispatch.sh no longer chains MODEL → resolve_auditor_model"

# Both call sites must pass the password-DB home. A bare `resolve_auditor_model`
# reads the repo-injectable $HOME, letting a reviewed fork pick the provider its
# own review is shipped to — the hole this guard exists to keep closed.
for f in "$LIB" "$DISPATCH"; do
  # Every mention that is not a comment and not the definition/shim is a CALL,
  # and every call must carry the trusted home.
  # PATH too: the reader shells out to jq/python3, so an ambient PATH could
  # supply a planted binary. Both are stated at the call site rather than
  # inherited from the arm's pin, so neither depends on line order.
  bad="$(grep -nE 'resolve_auditor_model' "$f" \
         | grep -vE '^[0-9]+:[[:space:]]*#' \
         | grep -v 'resolve_auditor_model()' \
         | grep -v 'type resolve_auditor_model' \
         | grep -vE 'PATH="[^"]*/opt/homebrew/bin[^"]*/usr/local/bin[^"]*" \\?$|HOME="\$_oc_home" resolve_auditor_model' || true)"
  if [[ -n "$bad" ]]; then
    fail "$(basename "$f") calls resolve_auditor_model without pinned PATH+HOME: $bad"
  else
    ok "$(basename "$f") resolves the model under pinned PATH + trusted home"
  fi
done

# ── No model name outside the one place a default belongs ───────
# The voice is defined by its LENS (claim-vs-mechanism), not by whichever model
# happens to be behind it. Prose that names the model goes stale the moment
# .auditor.model changes, and the "Mechanism Witness (kimi-k3)" log line was
# actively lying about what ran. Allowed: the default constant, dispatch.sh's
# library-missing shim, and the config example next to it. docs/adr + CHANGELOG
# are historical records and are not swept.
# The same rule now also covers the pi read lane's `.pi.model`
# (PI_MODEL_DEFAULT + its library-missing shim) and the agy read lane's
# `.agy_read.model` (AGY_READ_MODEL_DEFAULT): three configurable model keys, one
# invariant — an id may appear at its default constant and nowhere else, so
# rationale comments say "the shipped default" instead of naming a model and
# going stale next to it. `gemini` joined the sweep with the agy lane; it caught
# a real leak on that lane's first run (an example id in a rationale comment).
# Scoped to the files that HOST the witness — a model name elsewhere (e.g. the
# agent-tools catalog listing LLMs) is not this invariant's business.
# The agy lane added three more files that name a model id, and a reviewer was
# right that leaving them unswept made the "one place" claim untrue: a default
# change could leave the documented config and the tests stale while this passed.
# They are swept, with ONE allowance — a line that is a config EXAMPLE (`"model":`)
# or a test FIXTURE (`check_model`) may name an id, because an example with a
# placeholder teaches nothing and a fixture is asserting on that exact string.
# Rationale prose in those files may not.
leaks="$(grep -rIn -iE 'kimi|opencode-go|moonshotai|gemini[- ][0-9]' \
           "$ROOT/skills/council/SKILL.md" \
           "$ROOT/skills/blueprint-review/SKILL.md" \
           "$ROOT/skills/blueprint-review/scripts/run-design-review-loop.sh" \
           "$ROOT/skills/dispatch-cli/scripts/dispatch.sh" \
           "$ROOT/skills/dispatch-cli/SKILL.md" \
           "$ROOT/.claude/CLAUDE.md" \
           "$ROOT/tests/test-agy-read-lane.sh" \
           "$ROOT/commands/ultimate-council.md" \
           "$LIB" 2>/dev/null \
         | grep -vE 'AUDITOR_MODEL_DEFAULT|resolve_auditor_model\(\)|"auditor": \{ "model"|PI_MODEL_DEFAULT|resolve_pi_model\(\)|AGY_READ_MODEL_DEFAULT|resolve_agy_read_model\(\)|"model":|check_model' || true)"
if [[ -z "$leaks" ]]; then
  ok "no model name in live prose/logs (only the default constant names one)"
else
  fail "model name leaked back into live files:"; echo "$leaks" >&2
fi

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
