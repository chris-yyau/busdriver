#!/bin/bash
# tests/test-ultra-oracle-guard.sh — spec §4 allow table, the closed deny-reason set, the bash 3.2
# floor, and the run-dir preconditions (§11 "Guard unit tests", first half).
set -u
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
G="$DIR/scripts/hooks/ultra-oracle-child/guard.sh"
FX="$DIR/tests/fixtures/ultra-oracle"
JQ=/usr/bin/jq
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT INT TERM
FAIL=0; pass() { echo "OK:   $1"; }; fail() { echo "FAIL: $1"; FAIL=1; }
TAG=0123456789abcdef; C=mcp__claude-in-chrome__
QUERY='file input element for attaching files to the message composer'
SIX="select:${C}tabs_context_mcp,${C}tabs_close_mcp,${C}navigate,${C}find,${C}file_upload,${C}javascript_tool"

newrun() {
  RD="$(mktemp -d "$T/run-XXXXXX")"; RD="$(cd "$RD" && pwd -P)"; mkdir -m 700 "$RD/oob"; N=0
  $JQ -n --arg t "$TAG" --arg st "$RD/uora-$TAG.txt" --arg q "$QUERY" '{tag:$t, staged:$st, url:"https://chatgpt.com/", query:$q,
    snippets:{"j-home":"/*home*/","j-attached":"/*att*/","j-send":"/*send*/","j-id":"/*id*/","j-poll":"/*poll*/","j-get":"/*get*/","j-archive":"/*arch*/"}}' > "$RD/guard.json"
  chmod 600 "$RD/guard.json"; printf '{}\n' > "$RD/guard-state.json"; printf 'setup\n' > "$RD/phase"
}
hook() { # <pre|post> <tool> <input-json> [result-text]  -> OUT, RC
  N=$((N + 1))
  OUT="$($JQ -cn --arg ev "$1" --arg t "$2" --argjson i "$3" --arg id "toolu_$N" --arg x "${4-}" \
      '{hook_event_name: (if $ev == "pre" then "PreToolUse" else "PostToolUse" end), tool_name: $t, tool_input: $i, tool_use_id: $id}
       + (if $ev == "post" then {tool_response: [{type: "text", text: $x}]} else {} end)' \
    | env -i PATH=/usr/bin:/bin UORA_RUN_DIR="$RD" /bin/bash "$G" "$1" 2>/dev/null)"; RC=$?
}
allow() { hook pre "$@"; if [ "$RC" = 0 ] && grep -q '"permissionDecision":"allow"' <<<"$OUT"; then pass "allow $1"; else fail "want allow: $* (rc=$RC $OUT)"; fi; }
deny() { local r="$1"; shift; hook pre "$@"
  if [ "$RC" = 2 ] && grep -qF "\"uora-guard: deny $r\"" <<<"$OUT"; then pass "deny $r: $1"; else fail "want deny $r: $* (rc=$RC $OUT)"; fi; }
js() { printf '{"action":"javascript_exec","text":"%s","tabId":%s}' "$1" "${2:-101}"; }
UP() { printf '{"paths":["%s"],"ref":"%s","tabId":%s}' "${1:-$RD/uora-$TAG.txt}" "${2:-ref_7}" "${3:-101}"; }
NAV='{"url":"https://chatgpt.com/","tabId":101}'
FIND="{\"query\":\"$QUERY\",\"tabId\":101}"
state() { $JQ -r "$1" "$RD/guard-state.json"; }
# Each stage drives the child's own state one step: an allowed call plus its PostToolUse record.
to_tab()      { newrun; allow ToolSearch "{\"query\":\"$SIX\",\"max_results\":6}"; allow "${C}tabs_context_mcp" '{"createIfEmpty":true}'
                hook post "${C}tabs_context_mcp" '{"createIfEmpty":true}' "$(cat "$FX/tabs-context-result.txt")"; }
to_nav()      { to_tab; allow "${C}navigate" "$NAV"; hook post "${C}navigate" "$NAV" ok; }
to_ready()    { to_nav; allow "${C}javascript_tool" "$(js j-home)"; hook post "${C}javascript_tool" "$(js j-home)" READY; }
to_found()    { to_ready; allow "${C}find" "$FIND"; hook post "${C}find" "$FIND" "$(cat "$FX/find-result.txt")"; }
to_uploaded() { to_found; allow "${C}file_upload" "$(UP)"; hook post "${C}file_upload" "$(UP)" 'Uploaded 1 file(s)'; }
to_attached() { to_uploaded; allow "${C}javascript_tool" "$(js j-attached)"; hook post "${C}javascript_tool" "$(js j-attached)" ATTACHED; }
to_sent()     { to_attached; allow "${C}javascript_tool" "$(js j-send)"; hook post "${C}javascript_tool" "$(js j-send)" SENT; }

# --- the fixtures recorded in Task 1 drive the recorder
to_tab; [ "$(state .tab)" = 101 ] && pass "tab id recorded from the live fixture" || fail "tab id not recorded ($(state .tab))"
to_found; [ "$(state .find_count)/$(state .ref)" = "1/ref_7" ] && pass "find ref recorded" || fail "find: $(state .find_count)/$(state .ref)"

# --- ToolSearch and tabs_context_mcp
newrun
deny forbidden ToolSearch '{"query":"select:Bash","max_results":1}'
deny forbidden ToolSearch "{\"query\":\"$SIX,${C}computer\",\"max_results\":7}"
deny forbidden "${C}tabs_context_mcp" '{"createIfEmpty":false}'
deny forbidden "${C}tabs_context_mcp" '{}'
deny forbidden "${C}tabs_create_mcp" '{}'
allow "${C}tabs_context_mcp" '{"createIfEmpty":true}'
deny forbidden "${C}tabs_context_mcp" '{"createIfEmpty":true}'
deny not-yet "${C}navigate" "$NAV"                       # tab-scoped before the own tab id is recorded
[ "$(state .n.nav)" = 0 ] && pass "not-yet spends no counter" || fail "not-yet spent the nav counter"

# --- navigate, and J-home batched with navigate
to_tab
deny forbidden "${C}navigate" '{"url":"https://evil.example/","tabId":101}'
deny forbidden "${C}navigate" '{"url":"https://chatgpt.com/","tabId":999}'
allow "${C}navigate" "$NAV"
deny not-yet "${C}javascript_tool" "$(js j-home)"         # navigate's record has not landed yet
hook post "${C}navigate" "$NAV" ok
allow "${C}javascript_tool" "$(js j-home)"
deny forbidden "${C}navigate" "$NAV"                      # once only

# --- find
to_nav
deny not-yet "${C}find" "$FIND"                           # before READY
hook pre "${C}javascript_tool" "$(js j-home)"; hook post "${C}javascript_tool" "$(js j-home)" 'READY trailing'
deny not-yet "${C}find" "$FIND"                           # a token with surrounding text records nothing
to_ready
deny forbidden "${C}find" "{\"query\":\"other\",\"tabId\":101}"
deny forbidden "${C}read_page" '{"tabId":101}'
deny forbidden "${C}computer" '{"action":"screenshot","tabId":101}'
allow "${C}find" "$FIND"
deny forbidden "${C}find" "$FIND"                         # second find

# --- file_upload
to_ready
deny not-yet "${C}file_upload" "$(UP)"                    # no find count recorded yet
to_ready; allow "${C}find" "$FIND"; hook post "${C}find" "$FIND" '- ref_3: button "Attach photos" (file) - Upload photos'
deny no-ref "${C}file_upload" "$(UP)"
to_ready; allow "${C}find" "$FIND"
hook post "${C}find" "$FIND" "$(printf -- '- ref_7: button "Attach files" (file) - a\n- ref_8: button "Attach files" (file) - b')"
deny no-ref "${C}file_upload" "$(UP)"
to_found
deny forbidden "${C}file_upload" "$(UP /etc/hosts)"
deny forbidden "${C}file_upload" "$(UP "" ref_8)"
deny forbidden "${C}file_upload" "$(UP "" ref_7 999)"
[ "$(cat "$RD/phase")" = setup ] && pass "a forbidden upload leaves phase at setup" || fail "phase moved on a forbidden upload"
allow "${C}file_upload" "$(UP)"
[ "$(cat "$RD/phase")" = submitting ] && pass "the guard wrote submitting before allowing the upload" || fail "phase=$(cat "$RD/phase")"
deny forbidden "${C}file_upload" "$(UP)"
deny forbidden "${C}javascript_tool" "$(js j-home)"       # pre-upload column is closed now

# --- the upload column and the sent column
to_uploaded
deny not-yet "${C}javascript_tool" "$(js j-send)"         # before ATTACHED
deny forbidden "${C}javascript_tool" "$(js j-id)"
deny forbidden "${C}javascript_tool" "$(js j-poll)"
allow "${C}javascript_tool" "$(js j-attached)"
to_attached
allow "${C}javascript_tool" "$(js j-send)"
deny forbidden "${C}javascript_tool" "$(js j-send)"       # second J-send
to_sent
deny forbidden "${C}javascript_tool" "$(js j-attached)"
allow "${C}javascript_tool" "$(js j-id)"
allow "${C}javascript_tool" "$(js j-poll)"
allow "${C}javascript_tool" "$(js j-poll)"
deny forbidden "${C}javascript_tool" "$(js j-archive)"    # before saved
allow "${C}javascript_tool" "$(js j-get)"
deny forbidden "${C}javascript_tool" "$(js j-get)"        # second J-get
hook post "${C}javascript_tool" "$(js j-get)" "SAVED 1234 $(printf '%064d' 0 | tr 0 a)"
allow "${C}javascript_tool" "$(js j-archive)"
deny forbidden "${C}javascript_tool" "$(js j-archive)"    # second J-archive
deny forbidden "${C}javascript_tool" "$(js j-poll 999)"   # another tab's JS
allow "${C}tabs_close_mcp" '{"tabId":101}'
deny forbidden "${C}tabs_close_mcp" '{"tabId":999}'

# --- opcodes: the guard delivers the rendered snippet through updatedInput (E20)
to_ready
hook pre "${C}javascript_tool" "$(js j-home)"
[ "$($JQ -r '.hookSpecificOutput.updatedInput.text' <<<"$OUT")" = '/*home*/' ] && pass "updatedInput carries the rendered J-home" || fail "updatedInput: $OUT"
[ "$($JQ -r '.hookSpecificOutput.updatedInput.tabId' <<<"$OUT")" = 101 ] && pass "updatedInput keeps the other fields" || fail "updatedInput tabId"
deny forbidden "${C}javascript_tool" "$(js '/*home*/')"   # the snippet's own source text is not an opcode
deny forbidden "${C}javascript_tool" '{"action":"javascript_exec","text":"fetch(1)","tabId":101}'
deny forbidden "${C}javascript_tool" '{"action":"other","text":"j-home","tabId":101}'

# --- Read, Bash, any other tool: denied in every column
for stage in newrun to_ready to_uploaded to_sent; do
  $stage
  deny forbidden Read "{\"file_path\":\"$RD/uora-$TAG.txt\"}"
  deny forbidden Bash '{"command":"true"}'
  deny forbidden "${C}computer" '{"action":"left_click","tabId":101}'
  deny forbidden "${C}read_page" '{"tabId":101}'
done

# --- every deny carries exactly one reason from the closed set
to_found; hook pre Read '{}'
[ "$(grep -oE 'uora-guard: deny [a-z-]+' <<<"$OUT" | sort -u)" = 'uora-guard: deny forbidden' ] && pass "one closed-set reason" || fail "reason: $OUT"

# --- run-dir preconditions
newrun
OUT="$(printf '{}' | env -i PATH=/usr/bin:/bin /bin/bash "$G" pre 2>/dev/null)"; [ $? = 2 ] && pass "UORA_RUN_DIR missing -> deny" || fail "missing run dir"
OUT="$(printf '{}' | env -i PATH=/usr/bin:/bin UORA_RUN_DIR=rel /bin/bash "$G" pre 2>/dev/null)"; [ $? = 2 ] && pass "relative UORA_RUN_DIR -> deny" || fail "relative run dir"
chmod 644 "$RD/guard.json"; hook pre ToolSearch "{\"query\":\"$SIX\",\"max_results\":6}"
[ "$RC" = 2 ] && pass "guard.json not 0600 -> deny" || fail "0644 guard.json allowed"
newrun; rm -f "$RD/guard.json"; hook pre ToolSearch "{\"query\":\"$SIX\",\"max_results\":6}"
[ "$RC" = 2 ] && pass "no guard.json -> deny" || fail "missing guard.json allowed"
newrun; OUT="$(printf 'not json' | env -i PATH=/usr/bin:/bin UORA_RUN_DIR="$RD" /bin/bash "$G" pre 2>/dev/null)"
[ $? = 2 ] && pass "unparseable payload -> deny" || fail "unparseable payload"
newrun; printf 'garbage' > "$RD/guard-state.json"; hook pre ToolSearch "{\"query\":\"$SIX\",\"max_results\":6}"
[ "$RC" = 2 ] && pass "unparseable state -> deny" || fail "unparseable state"

# --- jq only as /usr/bin/jq: a jq shim first on PATH never runs
newrun; mkdir -p "$T/shim"; printf '#!/bin/sh\ntouch %s/shim-ran\nexit 0\n' "$T" > "$T/shim/jq"; chmod +x "$T/shim/jq"
printf '%s' "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"ToolSearch\",\"tool_input\":{\"query\":\"$SIX\",\"max_results\":6},\"tool_use_id\":\"x\"}" \
  | env -i PATH="$T/shim:/usr/bin:/bin" UORA_RUN_DIR="$RD" /bin/bash "$G" pre >/dev/null 2>&1
[ ! -e "$T/shim-ran" ] && pass "jq shim never runs" || fail "guard ran the PATH jq"

# --- bash 3.2 floor (CI's /bin/bash is 4+, so this static check is the enforcement)
# Full-line comments are skipped: the guard's header names the forbidden constructs on purpose.
floor() { grep -vE '^[[:space:]]*#' "$1" | grep -nE 'declare -A|local -A|typeset -A|mapfile|readarray|\[\[ -v |declare -n|local -n|\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^|,|\^)\}|BASHPID|coproc'; }
if floor "$G"; then fail "guard.sh uses a construct above the bash 3.2 floor"; else pass "bash 3.2 floor"; fi
printf '#!/bin/bash\n# mapfile in a comment is fine\nmapfile -t x < /dev/null\n' > "$T/floor-pos"
printf '#!/bin/bash\n# mapfile, readarray, ${x,,} and BASHPID named in comments only\necho ok\n' > "$T/floor-neg"
floor "$T/floor-pos" >/dev/null && ! floor "$T/floor-neg" >/dev/null \
  && pass "floor check fires on code and ignores comments" || fail "floor check controls"
[ "$(head -1 "$G")" = '#!/bin/bash' ] && pass "guard.sh runs as /bin/bash" || fail "shebang"

# --- gate-integrity pins the guard's directory
grep -q '  scripts/hooks/ultra-oracle-child/guard.sh$' "$DIR/.gate-integrity.lock" && pass "guard.sh is pinned" || fail "guard.sh not in .gate-integrity.lock"
for f in "$DIR"/scripts/hooks/ultra-oracle-child/*; do
  grep -qF "  ${f#"$DIR"/}" "$DIR/.gate-integrity.lock" || fail "unpinned: ${f#"$DIR"/}"
done

[ "$FAIL" = 0 ] && echo "PASS test-ultra-oracle-guard" || exit 1
