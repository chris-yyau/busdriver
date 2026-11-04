#!/bin/bash
# tests/test-ultra-oracle-child-render.sh — renderers, and the exact rendered hook argv run through
# contained-launch.sh (spec §4 "Hook registration", §11 guard cases on the registered command).
set -u
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JQ=/usr/bin/jq
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT INT TERM
FAIL=0; pass() { echo "OK:   $1"; }; fail() { echo "FAIL: $1"; FAIL=1; }
# shellcheck source=/dev/null
source "$DIR/scripts/lib/ultra-oracle.sh"
TAG=0123456789abcdef
RD="$T/run-$TAG"; mkdir -m 700 "$RD"; RD="$(cd "$RD" && pwd -P)"
_uora_render_guard "$RD" "$TAG" && _uora_render_settings "$RD" && _uora_render_instructions "$RD" "$TAG" \
  && pass "renderers succeed" || fail "renderers failed"

[ -n "$(find "$RD/guard.json" -prune -perm 600)" ] && pass "guard.json is 0600" || fail "guard.json mode"
[ "$($JQ -r .staged "$RD/guard.json")" = "$RD/uora-$TAG.txt" ] && pass "staged path" || fail "staged path"
$JQ -e --arg t "$TAG" '.snippets["j-get"] | contains("'"'"'" + $t + "'"'"'") and (contains("__UORA_TAG__") | not)' "$RD/guard.json" >/dev/null \
  && pass "J-get rendered with the tag" || fail "J-get not rendered"
[ "$($JQ -r '.snippets | keys | join(",")' "$RD/guard.json")" = "j-archive,j-attached,j-get,j-home,j-id,j-poll,j-send" ] \
  && pass "all seven snippets" || fail "snippet set"
[ "$(cat "$RD/phase")" = setup ] && [ "$(cat "$RD/guard-state.json")" = '{}' ] && [ -d "$RD/oob" ] \
  && pass "phase, empty state and oob/ initialised" || fail "initial run-dir files"

S="$RD/child-settings.json"
for ev in PreToolUse PostToolUse; do
  [ "$($JQ -r --arg e "$ev" '.hooks[$e][0].matcher' "$S")" = '*' ] && pass "$ev uses the match-all matcher (Read, ToolSearch hooked)" || fail "$ev matcher"
  [ "$($JQ -r --arg e "$ev" '.hooks[$e][0].hooks[0].timeout' "$S")" = 30 ] && pass "$ev timeout 30" || fail "$ev timeout"
  [ "$($JQ -r --arg e "$ev" '.hooks[$e][0].hooks[0].command' "$S")" = "$DIR/hooks/gate-scripts/lib/contained-launch.sh" ] \
    && pass "$ev first hop is contained-launch.sh" || fail "$ev command"
  $JQ -e --arg e "$ev" --arg rd "$RD" --arg g "$DIR/scripts/hooks/ultra-oracle-child/guard.sh" \
    '.hooks[$e][0].hooks[0].args[0:5] == ["closed","PATH=/usr/bin:/bin",("UORA_RUN_DIR=" + $rd),"/bin/bash",$g]' "$S" >/dev/null \
    && pass "$ev exec-form argv, closed disposition, no -p operand" || fail "$ev args"
done
$JQ -e '.hooks.PostToolUse[0].hooks[0] | has("onFailure") | not' "$S" >/dev/null \
  && pass "PostToolUse never blocks on hook failure" || fail "PostToolUse carries onFailure"
$JQ -e 'has("onFailure") | not' "$S" >/dev/null && pass "no top-level onFailure" || fail "top-level onFailure"
# Both r3 outcomes. In-process seam only (no env var): point _UORA_CHILD_DIR at a copy whose
# signatures.json is edited, then restore it.
cp -R "$DIR/scripts/hooks/ultra-oracle-child" "$T/child"
_UORA_CHILD_DIR_SAVE="$_UORA_CHILD_DIR"; _UORA_CHILD_DIR="$T/child"
for want in block '' continue; do
  $JQ --arg b "$want" '.pretool_on_failure = (if $b == "" then null else $b end)' \
    "$DIR/scripts/hooks/ultra-oracle-child/signatures.json" > "$T/child/signatures.json"
  rm -f "$S"
  if [ "$want" = continue ]; then
    _uora_render_settings "$RD" && fail "illegal onFailure value rendered" || pass "illegal onFailure value refused"
    continue
  fi
  _uora_render_settings "$RD" || fail "render with pretool_on_failure=${want:-null}"
  got="$($JQ -r '.hooks.PreToolUse[0].hooks[0].onFailure // ""' "$S")"
  [ "$got" = "$want" ] && pass "PreToolUse onFailure = ${want:-absent}" || fail "PreToolUse onFailure: got '$got'"
  $JQ -e '.hooks.PostToolUse[0].hooks[0] | has("onFailure") | not' "$S" >/dev/null || fail "PostToolUse onFailure (${want:-null})"
done
_UORA_CHILD_DIR="$_UORA_CHILD_DIR_SAVE"; _uora_render_settings "$RD"

grep -qF "$RD/uora-$TAG.txt" "$RD/instructions.txt" && pass "instructions carry the staged path" || fail "staged path missing from instructions"
grep -qE '=>|fetch\(|document\.|location\.' "$RD/instructions.txt" && fail "instructions contain JavaScript" || pass "instructions carry no JS"
for w in j-home j-attached j-send j-id j-poll j-get j-archive "$_UORA_QUERY" '"createIfEmpty": true'; do
  grep -qF -- "$w" "$RD/instructions.txt" || fail "instructions missing: $w"
done
grep -q '__UORA_' "$RD/instructions.txt" && fail "unrendered placeholder" || pass "no placeholder left"

# Run the REAL rendered argv through the launcher. ENVX holds optional `env` assignments.
ENVX=()
run_hook() { # <ev> <payload-json> [settings-file] -> OUT, RC
  local s="${3:-$S}" cmd; local -a argv=()
  cmd="$($JQ -r --arg e "$1" '.hooks[$e][0].hooks[0].command' "$s")"
  while IFS= read -r a; do argv+=("$a"); done < <($JQ -r --arg e "$1" '.hooks[$e][0].hooks[0].args[]' "$s")
  OUT="$(printf '%s' "$2" | env ${ENVX[@]+"${ENVX[@]}"} "$cmd" "${argv[@]}" 2>/dev/null)"; RC=$?
}
SIX='select:mcp__claude-in-chrome__tabs_context_mcp,mcp__claude-in-chrome__tabs_close_mcp,mcp__claude-in-chrome__navigate,mcp__claude-in-chrome__find,mcp__claude-in-chrome__file_upload,mcp__claude-in-chrome__javascript_tool'
LEGAL="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"ToolSearch\",\"tool_input\":{\"query\":\"$SIX\",\"max_results\":6},\"tool_use_id\":\"t1\"}"
READ="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$RD/uora-$TAG.txt\"},\"tool_use_id\":\"t2\"}"
run_hook PreToolUse "$LEGAL"
[ "$RC" = 0 ] && grep -q '"permissionDecision":"allow"' <<<"$OUT" && pass "legal call through the launcher: explicit allow" || fail "legal call rc=$RC $OUT"
run_hook PreToolUse "$READ"
[ "$RC" = 2 ] && pass "Read through the launcher: blocked" || fail "Read rc=$RC"
ENVX=(SHELLOPTS=noexec BASH_ENV=/dev/null); run_hook PreToolUse "$READ"; ENVX=()
[ "$RC" = 2 ] && pass "SHELLOPTS=noexec cannot turn a deny into exit 0" || fail "noexec rc=$RC"
ENVX=(SHELLOPTS=noexec); run_hook PreToolUse "$LEGAL"; ENVX=()
[ "$RC" = 0 ] && pass "SHELLOPTS=noexec is stripped: a legal call is still explicitly allowed" || fail "noexec legal rc=$RC"
$JQ --arg g "$T/missing/guard.sh" '.hooks.PreToolUse[0].hooks[0].args[4] = $g' "$S" > "$T/missing.json"
run_hook PreToolUse "$LEGAL" "$T/missing.json"
[ "$RC" = 2 ] && pass "guard.sh missing -> blocked (launcher turns 127 into 2)" || fail "missing guard rc=$RC"
printf '{}' | /bin/bash "$DIR/scripts/hooks/ultra-oracle-child/guard.sh" pre >/dev/null 2>&1
[ $? = 2 ] && pass "no UORA_RUN_DIR -> exit 2" || fail "guard without run dir"

[ "$FAIL" = 0 ] && echo "PASS test-ultra-oracle-child-render" || exit 1
