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

DEFAULT="$(grep -E '^BUSDRIVER_AUDITOR_MODEL_DEFAULT=' "$LIB" | cut -d'"' -f2)"
[[ -n "$DEFAULT" ]] && ok "default constant present → $DEFAULT" || fail "no BUSDRIVER_AUDITOR_MODEL_DEFAULT in $LIB"

# dispatch.sh's library-missing shim repeats the default literal (no config
# reader exists without the library). Nothing else catches drift between the
# two, so assert equality directly.
SHIM_DEFAULT="$(grep -E 'resolve_auditor_model\(\) \{ _BD_AUDITOR_MODEL=' "$DISPATCH" | cut -d'"' -f2)"
eq "$SHIM_DEFAULT" "$DEFAULT" "dispatch.sh shim default matches BUSDRIVER_AUDITOR_MODEL_DEFAULT"

eq "$(resolve '')"                                        "$DEFAULT"        "no config → default"
eq "$(resolve '{}')"                                      "$DEFAULT"        "empty config → default"
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
eq "$(resolve 'not json at all')"                          "$DEFAULT"        "corrupt config → default"

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
eq "$got" "zenmux/moonshotai/kimi-k3" "exported resolve_auditor_model cannot bypass the library-missing shim (P1)"

# ── Golden-grep: no model id hardcoded at either dispatch site ───
if grep -nE '^[^#]*-m +[A-Za-z0-9][A-Za-z0-9._/-]*/' "$LIB" "$DISPATCH"; then
  fail "a literal model id is still hardcoded after -m (see lines above)"
else
  ok "neither dispatch site hardcodes a model id after -m"
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
# (PI_MODEL_DEFAULT + its library-missing shim): two configurable model keys,
# one invariant — an id may appear at its default constant and nowhere else, so
# rationale comments say "the shipped default" instead of naming a model and
# going stale next to it.
# Scoped to the files that HOST the witness — a model name elsewhere (e.g. the
# agent-tools catalog listing LLMs) is not this invariant's business.
leaks="$(grep -rIn -iE 'kimi|opencode-go|moonshotai' \
           "$ROOT/skills/council/SKILL.md" \
           "$ROOT/skills/blueprint-review/SKILL.md" \
           "$ROOT/skills/blueprint-review/scripts/run-design-review-loop.sh" \
           "$ROOT/skills/dispatch-cli/scripts/dispatch.sh" \
           "$ROOT/commands/ultimate-council.md" \
           "$LIB" 2>/dev/null \
         | grep -vE 'AUDITOR_MODEL_DEFAULT|resolve_auditor_model\(\)|"auditor": \{ "model"|PI_MODEL_DEFAULT|resolve_pi_model\(\)' || true)"
if [[ -z "$leaks" ]]; then
  ok "no model name in live prose/logs (only the default constant names one)"
else
  fail "model name leaked back into live files:"; echo "$leaks" >&2
fi

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
