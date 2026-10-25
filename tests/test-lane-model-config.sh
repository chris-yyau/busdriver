#!/usr/bin/env bash
# shellcheck disable=SC2310,SC2312  # assertions intentionally use command substitution
# shellcheck disable=SC2015  # `ok` always returns 0, so A && ok || fail is a real if-then-else here
# shellcheck disable=SC2016  # golden-grep patterns intentionally contain literal $
# shellcheck disable=SC2034  # BUSDRIVER_STATE_DIR is read by the sourced library, not this file
# tests/test-lane-model-config.sh — guard for the shared lane-model reader
# (_bd_read_lane_model) behind resolve_writing_prose_model (the agy-prose lane).
#
# Each lane's model comes from the USER busdriver.json. Three properties have to
# hold, and each has a real failure mode:
#   1. USER config only — a reviewed fork controls its own project
#      .claude/busdriver.json; honoring it would let a hostile branch redirect
#      the prompt to a third party of its choosing (#325 class).
#   2. Invalid values degrade to the default — the value lands in argv after
#      `--model`, so a leading `-` is option injection; a voice must not die on
#      a typo either.
#   3. No hardcoded model id survives at the dispatch sites.

set -euo pipefail
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

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

# ── Executable: resolve_writing_prose_model under a fake HOME ────
# The reader's trust-boundary properties are lane-independent; writing_prose is
# the one lane left that consumes it (the `bare` grammar).
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
    if [[ "${2:-}" == "keep-stderr" ]]; then resolve_writing_prose_model 2>&1
    else resolve_writing_prose_model 2>/dev/null; fi
    printf '%s' "$_BD_WRITING_PROSE_MODEL" )
}

# Every unconfigured/rejected case below resolves to the empty string.
DEFAULT=""

# The dispatch-side library-missing shim must fail closed to empty (= agy's own
# model), never to a provider-selecting value. Scoped to the library-missing
# block: the agy-prose arm carries a second, separate `declare -F` fallback.
SHIM_LINE="$(awk '/_BD_RESOLVE_CLI_SOURCED" != 1/,/^fi$/' "$DISPATCH" \
             | grep -E 'resolve_writing_prose_model\(\) \{ _BD_WRITING_PROSE_MODEL=' || true)"
if [[ "$(printf '%s\n' "$SHIM_LINE" | grep -c .)" -eq 1 && "$SHIM_LINE" == *'_BD_WRITING_PROSE_MODEL=""; }'* ]]; then
  ok "dispatch.sh prose shim exists once in the library-missing block and resolves empty"
else
  fail "dispatch.sh prose shim missing, duplicated, or not empty: [$SHIM_LINE]"
fi

eq "$(resolve '')"                                          "$DEFAULT"   "no config → empty"
eq "$(resolve '{}')"                                        "$DEFAULT"   "empty config → empty"
eq "$(resolve '{"writing_prose":{"model":"fixture-model"}}')" \
   "fixture-model"                                                       "configured model honored"
eq "$(resolve '{"writing_prose":{"model":"fixture-model:free"}}')" \
   "fixture-model:free"                                                  "colon-tagged variant accepted"
eq "$(resolve '{"writing_prose":{"model":"fixture-model@20250514"}}')" \
   "fixture-model@20250514"                                              "at-tagged variant accepted"
eq "$(resolve '{"writing_prose":{"model":"--dangerously-x"}}')" "$DEFAULT" "leading-dash rejected"
eq "$(resolve '{"writing_prose":{"model":"a b"}}')"         "$DEFAULT"   "whitespace rejected"
eq "$(resolve '{"writing_prose":{"model":"provider/id"}}')" "$DEFAULT"   "provider/ prefix rejected (bare grammar)"
eq "$(resolve 'not json at all')"                           "$DEFAULT"   "corrupt config → empty"
# A JSON number/boolean must not be stringified by `jq -r` and forwarded to
# argv — jq and the python3 fallback must agree (PR #687 Codex finding).
eq "$(resolve '{"writing_prose":{"model":123}}')"           "$DEFAULT"   "numeric config value degrades to default"
eq "$(resolve '{"writing_prose":{"model":true}}')"          "$DEFAULT"   "boolean config value degrades to default"

# Traversal via BUSDRIVER_STATE_DIR (repo-injectable through settings.json) must
# not escape the home dir into a path the reviewed repo can plant.
printf '%s' '{"writing_prose":{"model":"evil-model"}}' > "$FAKE_HOME/busdriver.json"
got="$( HOME="$FAKE_HOME" BUSDRIVER_STATE_DIR="../$(basename "$FAKE_HOME")" bash -c \
        'source "$0"; resolve_writing_prose_model 2>/dev/null; printf "%s" "$_BD_WRITING_PROSE_MODEL"' "$LIB" )"
eq "$got" "$DEFAULT" "traversal in BUSDRIVER_STATE_DIR rejected"

# A NESTED relative segment needs no traversal: the reviewed checkout normally
# lives under the trusted home, so this would read the fork's own committed
# config. Must be rejected too — single path segment only.
mkdir -p "$FAKE_HOME/projects/reviewed/.claude"
printf '%s' '{"writing_prose":{"model":"evil-model"}}' > "$FAKE_HOME/projects/reviewed/.claude/busdriver.json"
got="$( HOME="$FAKE_HOME" BUSDRIVER_STATE_DIR="projects/reviewed/.claude" bash -c \
        'source "$0"; resolve_writing_prose_model 2>/dev/null; printf "%s" "$_BD_WRITING_PROSE_MODEL"' "$LIB" )"
eq "$got" "$DEFAULT" "nested BUSDRIVER_STATE_DIR (checkout under \$HOME) rejected"

# And the shape a sanitizer cannot catch: a bare single segment naming a checkout
# at $HOME/reviewed, whose busdriver.json the fork commits itself. Only pinning
# the location rejects this — which is why the resolver pins `.claude`.
mkdir -p "$FAKE_HOME/reviewed"
printf '%s' '{"writing_prose":{"model":"evil-model"}}' > "$FAKE_HOME/reviewed/busdriver.json"
got="$( HOME="$FAKE_HOME" BUSDRIVER_STATE_DIR="reviewed" bash -c \
        'source "$0"; resolve_writing_prose_model 2>/dev/null; printf "%s" "$_BD_WRITING_PROSE_MODEL"' "$LIB" )"
eq "$got" "$DEFAULT" "bare BUSDRIVER_STATE_DIR naming a checkout dir rejected"

# The whole BASH_FUNC_* class in one shot. An attacker-controlled function table
# shadows every command word an in-shell reader could use — `jq`, `command`,
# `printf`, and even `local`/`return` — so the read happens in an `env -i` child,
# which drops the exported functions along with the rest of the environment.
# `_JSON_PARSER*` are listed too: they steered the old in-shell reader.
printf '%s' '{"writing_prose":{"model":"fixture-model"}}' > "$FAKE_HOME/.claude/busdriver.json"
EVIL="$(mktemp -d)"; printf '#!/bin/sh\necho evil-model\n' > "$EVIL/evil"; chmod +x "$EVIL/evil"
got="$( cd "$EVIL" && HOME="$FAKE_HOME" _JSON_PARSER=jq _JSON_PARSER_BIN="$EVIL/evil" \
        env "BASH_FUNC_jq%%=() { echo 'evil-model'; }" \
            "BASH_FUNC_command%%=() { echo '$EVIL/evil'; }" \
            "BASH_FUNC_printf%%=() { echo 'evil-model'; }" \
        bash -c 'source "$0"; resolve_writing_prose_model 2>/dev/null; builtin echo "$_BD_WRITING_PROSE_MODEL"' "$LIB" 2>/dev/null )"
rm -rf "$EVIL"
eq "$got" "fixture-model" "injected shell functions + _JSON_PARSER* cannot forge the model"

# A host with python3 but no jq must still honour a configured provider — the
# child tries jq first, python3 second. Simulated by pointing the jq loop at a
# path that cannot exist.
NOJQ="$(mktemp -d)/rc.sh"
sed 's|for b in /opt/homebrew/bin/jq /usr/local/bin/jq /usr/bin/jq /bin/jq; do|for b in /nonexistent/jq; do|' "$LIB" > "$NOJQ"
printf '%s' '{"writing_prose":{"model":"fixture-model"}}' > "$FAKE_HOME/.claude/busdriver.json"
got="$( HOME="$FAKE_HOME" bash -c 'source "$0"; resolve_writing_prose_model 2>/dev/null; printf "%s" "$_BD_WRITING_PROSE_MODEL"' "$NOJQ" )"
eq "$got" "fixture-model" "python3 fallback honours the config when jq is absent"

# Same no-jq harness over the presence probe: with jq present a wrong `pykey` is
# never consulted, so only this pass can see one.
printf '%s' '{"writing_prose":{"model":"provider/id"}}' > "$FAKE_HOME/.claude/busdriver.json"
got="$( HOME="$FAKE_HOME" bash -c 'source "$0"; printf "%s" "$(_bd_read_lane_model "$HOME" "" writing_prose_raw)"' "$NOJQ" )"
eq "$got" "provider/id" "no-jq: writing_prose_raw reports the raw value (pykey honoured)"
rm -rf "$(dirname "$NOJQ")"

# Captured, not piped: `grep -q` exits on first match and would SIGPIPE the
# producer, which `pipefail` then reports as a failed pipeline.
noisy="$(resolve '{"writing_prose":{"model":"-x"}}' keep-stderr)"
if [[ "$noisy" == *"ignoring invalid"* ]]; then
  ok "invalid value is announced on stderr (not silent)"
else
  fail "invalid value degraded silently — no 'ignoring invalid' note"
fi

# USER config only: a project config in CWD must not be read.
PROJ="$(mktemp -d)"
mkdir -p "$PROJ/.claude"
printf '%s' '{"writing_prose":{"model":"evil-model"}}' > "$PROJ/.claude/busdriver.json"
got="$( cd "$PROJ" && HOME="$FAKE_HOME" BUSDRIVER_STATE_DIR=".claude" bash -c \
        'rm -f "$HOME/.claude/busdriver.json"; source "$0"; resolve_writing_prose_model 2>/dev/null; printf "%s" "$_BD_WRITING_PROSE_MODEL"' "$LIB" )"
rm -rf "$PROJ"
eq "$got" "$DEFAULT" "project .claude/busdriver.json ignored (USER config only)"

# P1 regression: an inherited/exported function named resolve_writing_prose_model
# must not be trusted merely because `type` finds it — only a successfully-
# sourced resolve-cli.sh should skip the library-missing shim. Simulate a
# missing library (BUSDRIVER_PLUGIN_ROOT with no scripts/lib/resolve-cli.sh),
# export a poisoned resolve_writing_prose_model ahead of time, and confirm the
# shim's built-in default still wins rather than the exported function.
EMPTY_ROOT="$(mktemp -d)"
mkdir -p "$EMPTY_ROOT/scripts/lib"
# Anchor on markers rather than line numbers (fragile against future edits):
# from `set -euo pipefail` through the resolve_writing_prose_model shim's own
# defining line (the line that assigns the built-in default literal), then
# through that block's closing `fi`.
PREAMBLE="$(awk '
  /^set -euo pipefail$/ { p = 1 }
  p { print }
  /resolve_writing_prose_model\(\) \{/ { seen = 1 }
  seen && /^fi$/ { exit }
' "$DISPATCH")"
got="$( BUSDRIVER_PLUGIN_ROOT="$EMPTY_ROOT" bash -c "
  resolve_writing_prose_model() { _BD_WRITING_PROSE_MODEL='evil-model'; }
  export -f resolve_writing_prose_model
  $PREAMBLE
  resolve_writing_prose_model
  printf '%s' \"\$_BD_WRITING_PROSE_MODEL\"
" )"
rm -rf "$EMPTY_ROOT"
eq "$got" "" "exported resolve_writing_prose_model cannot bypass the library-missing shim (P1)"

# ADR 0051: a leftover .auditor.model is ignored — the 'auditor' key no longer selects anything.
printf '{"auditor":{"model":"x/y"}}' > "$FAKE_HOME/.claude/busdriver.json"
got="$(HOME="$FAKE_HOME" bash -c 'source "$0"; printf "%s" "$(_bd_read_lane_model "$HOME" "SENTINEL" auditor)"' "$LIB")"
if [[ "$got" == "SENTINEL" ]]; then
  ok "retired auditor key returns the default"
else
  fail "retired auditor key still read: '$got'"
fi

# ADR 0060: a leftover .pi_read.model is ignored the same way — the pi_read
# block is no longer in the reader's enum.
printf '{"pi_read":{"model":"x/y"}}' > "$FAKE_HOME/.claude/busdriver.json"
got="$(HOME="$FAKE_HOME" bash -c 'source "$0"; printf "%s" "$(_bd_read_lane_model "$HOME" "SENTINEL" pi_read)"' "$LIB")"
if [[ "$got" == "SENTINEL" ]]; then
  ok "retired pi_read key returns the default"
else
  fail "retired pi_read key still read: '$got'"
fi

# ── Golden-grep: no model id hardcoded at either dispatch site ───
if grep -nE '^[^#]*-m +[A-Za-z0-9][A-Za-z0-9._/-]*/' "$LIB" "$DISPATCH"; then
  fail "a literal model id is still hardcoded after -m (see lines above)"
else
  ok "neither dispatch site hardcodes a model id after -m"
fi

# ── No model name in live files ─────────────────────────────────
# A voice is defined by its role, not by whichever model happens to be behind
# it. Prose that names the model goes stale the moment the configured model
# changes (a "(kimi-k3)" log line once lied about what ran). The configurable
# model key (`.writing_prose.model`) ships with NO default
# constant, so no live file may name a model id at all; a test FIXTURE passed to
# `check_model` is the one allowance. docs/adr + CHANGELOG are historical
# records and are not swept. `gemini` joined the sweep with the (since
# withdrawn) agy read lane; it caught a real leak on that lane's first run (an
# example id in a rationale comment). Scoped to the files that host the review
# voices — a model name elsewhere (e.g. the agent-tools catalog listing LLMs) is
# not this invariant's business. Placeholder examples (`"<id>"`,
# `"provider/id"`) never match the leak pattern below, so they need no allowance.
#
# (PR #687 CodeRabbit finding: a blanket `|"model":` exclusion dropped ANY line
# containing that JSON-key substring, so a genuinely stale `"model": "kimi-..."`
# example would pass. There is no such exclusion now — a config example naming
# a real id is a leak.)

sweep=("$ROOT/skills/council/SKILL.md"
       "$ROOT/skills/blueprint-review/SKILL.md"
       "$ROOT/skills/blueprint-review/scripts/run-design-review-loop.sh"
       "$ROOT/skills/dispatch-cli/scripts/dispatch.sh"
       "$ROOT/skills/dispatch-cli/SKILL.md"
       "$ROOT/.claude/CLAUDE.md"
       "$ROOT/tests/test-agy-dispatch-arm.sh"
       "$ROOT/commands/ultimate-council.md"
       "$LIB")
# A renamed or deleted target must fail, not silently drop out of the sweep.
for f in "${sweep[@]}"; do [[ -f "$f" ]] || fail "sweep target missing: $f"; done
# Strip only the allowed occurrences (the check_model fixture arguments), never
# the whole line, so a stale id sharing a line with a fixture is still caught.
leaks="$(grep -rIn -iE 'kimi|opencode-go|moonshotai|gemini[- ][0-9]' "${sweep[@]}" 2>/dev/null \
         | sed -E -e "s/check_model '[^']*' '[^']*'//g" \
         | grep -iE 'kimi|opencode-go|moonshotai|gemini[- ][0-9]' || true)"
if [[ -z "$leaks" ]]; then
  ok "no model name in live prose/logs (test fixtures only)"
else
  fail "model name leaked back into live files:"; echo "$leaks" >&2
fi

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
