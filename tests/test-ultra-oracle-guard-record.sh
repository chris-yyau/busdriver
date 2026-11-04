#!/bin/bash
# tests/test-ultra-oracle-guard-record.sh — spec §4 recorder, lock, busy/post-lost, fence and replay
# (§11 "Guard unit tests", second half). The harness block is copied from test-ultra-oracle-guard.sh.
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

# --- recorder: exact tokens only (§4)
to_sent; allow "${C}javascript_tool" "$(js j-get)"
for bad in 'SAVED' 'SAVED 12' "SAVED 12 $(printf '%063d' 0)" "x SAVED 12 $(printf '%064d' 0)"; do
  hook post "${C}javascript_tool" "$(js j-get)" "$bad"
  [ "$(state .saved)" = false ] && pass "no latch on '$bad'" || fail "latched on '$bad'"
done
hook post "${C}javascript_tool" "$(js j-get)" "SAVED 1234 $(printf '%064d' 0)
"
[ "$(state .saved)" = true ] && pass "SAVED latches with one trailing newline removed" || fail "SAVED did not latch"
to_ready; hook post "${C}javascript_tool" "$(js '/*attached*/')" ATTACHED
[ "$(state .attached)" = false ] && pass "a foreign JS text records nothing" || fail "foreign text recorded"
# The recorder accepts the rewritten snippet text in tool_input as well as the opcode.
to_uploaded; hook post "${C}javascript_tool" '{"action":"javascript_exec","text":"/*att*/","tabId":101}' ATTACHED
[ "$(state .attached)" = true ] && pass "recorder matches the rendered snippet text" || fail "rendered text not matched"

# --- the captured E15/E18 PostToolUse payloads (Task 1 payloads-a.jsonl) record what they carry
newrun; allow "${C}tabs_context_mcp" '{"createIfEmpty":true}'
$JQ -c 'select(.label == "post-tabs-context") | .payload' "$FX/payloads-a.jsonl" \
  | env -i PATH=/usr/bin:/bin UORA_RUN_DIR="$RD" /bin/bash "$G" post
[ "$(state .tab)" = 101 ] && pass "captured tabs_context payload records the tab" || fail "captured payload: tab=$(state .tab)"

# --- a missing or crashing PostToolUse half: nothing recorded, later tab-scoped calls denied
newrun; allow "${C}tabs_context_mcp" '{"createIfEmpty":true}'
printf '{"tool_name":"x"}' | env -i PATH=/usr/bin:/bin UORA_RUN_DIR="$RD" /bin/bash "$G" post; prc=$?
[ "$prc" != 0 ] && [ "$(state .tab)" = null ] && pass "a crashing post records nothing" || fail "crashing post rc=$prc tab=$(state .tab)"
deny not-yet "${C}navigate" "$NAV"

# --- a guard crash -> the registered command blocks (crash = jq missing from the run's view)
newrun; cp "$G" "$T/guard-broken.sh"; sed -i.bak 's|^JQ=/usr/bin/jq$|JQ=/nonexistent/jq|' "$T/guard-broken.sh"
OUT="$(printf '%s' "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"ToolSearch\",\"tool_input\":{\"query\":\"$SIX\",\"max_results\":6},\"tool_use_id\":\"c\"}" \
  | env -i PATH=/usr/bin:/bin UORA_RUN_DIR="$RD" /bin/bash "$T/guard-broken.sh" pre 2>/dev/null)"; rc=$?
[ "$rc" = 2 ] && grep -q '"permissionDecision":"deny"' <<<"$OUT" && pass "a crashing guard denies" || fail "crash rc=$rc"

# --- every decision and record appends exactly one line holding the payload's tool_use_id
to_found
lines="$(wc -l < "$RD/decisions.jsonl" | tr -dc 0-9)"
[ "$lines" = "$N" ] && pass "one log line per hook call ($N)" || fail "log lines $lines vs calls $N"
$JQ -e -s 'all(.[]; (.id | test("\\Atoolu_[0-9]+\\z")))' "$RD/decisions.jsonl" >/dev/null && pass "every line has its tool_use_id" || fail "log ids"
$JQ -e -s '[.[] | select(.tool == "mcp__claude-in-chrome__javascript_tool") | .input.text] | all(. == "j-home")' "$RD/decisions.jsonl" >/dev/null \
  && pass "the log keeps the opcode, not the snippet" || fail "log text"

# --- busy: a pre-existing lock dir denies at once and logs out of band
to_ready; mkdir "$RD/guard.lock"
s=$(date +%s); deny busy "${C}find" "$FIND"; e=$(date +%s)
[ $((e - s)) -le 1 ] && pass "busy within a second" || fail "busy took $((e - s)) s"
[ "$(cat "$RD"/oob/l.* | $JQ -r .r)" = busy ] && pass "busy line in oob/" || fail "no oob busy line"
grep -q busy "$RD/decisions.jsonl" && fail "busy line written to decisions.jsonl" || pass "busy never touches decisions.jsonl"
[ "$(state .n.find)" = 0 ] && pass "busy spends no counter" || fail "busy spent a counter"

# --- a stranded lock: PostToolUse gives up after 5 s and writes post-lost
hook post "${C}javascript_tool" "$(js j-home)" READY
[ "$RC" != 0 ] && grep -q post-lost "$RD"/oob/l.* && pass "stranded lock -> post-lost" || fail "no post-lost"
rmdir "$RD/guard.lock"

# --- J-send's PostToolUse overlapping another hook that holds the lock: sent still recorded
to_attached; allow "${C}javascript_tool" "$(js j-send)"
mkdir "$RD/guard.lock"; ( sleep 1; rmdir "$RD/guard.lock" ) &
hook post "${C}javascript_tool" "$(js j-send)" SENT; wait
[ "$(state .sent)" = true ] && pass "post waits for the lock and records SENT" || fail "sent lost under contention"
allow "${C}javascript_tool" "$(js j-id)"

# --- parallel calls racing a once-only counter: exactly one allow
to_ready
for i in 1 2 3 4 5 6; do
  ( $JQ -cn --arg id "race$i" --arg q "$QUERY" '{hook_event_name:"PreToolUse",tool_name:"mcp__claude-in-chrome__find",tool_input:{query:$q,tabId:101},tool_use_id:$id}' \
      | env -i PATH=/usr/bin:/bin UORA_RUN_DIR="$RD" /bin/bash "$G" pre > "$T/race.$i" 2>/dev/null ) &
done; wait
a="$(cat "$T"/race.* | grep -c '"permissionDecision":"allow"')"
# Exactly one: whichever call holds guard.lock allows, so zero allows is a bug too.
[ "$a" -eq 1 ] && [ "$(state .n.find)" = 1 ] && pass "race: exactly 1 allow, counter 1" || fail "race: $a allows, counter $(state .n.find)"
d="$(cat "$T"/race.* | grep -c '"permissionDecision":"deny"')"
o="$(cat "$T"/race.* | grep -o 'uora-guard: deny [a-z-]*' | grep -cvE 'deny (busy|forbidden)$')"
[ "$d" -eq 5 ] && [ "$o" -eq 0 ] && pass "the 5 losers are denied, busy or forbidden only" || fail "race losers: $d denies, $o other reasons"
for f in "$RD"/oob/l.*; do [ -e "$f" ] || continue; [ "$(wc -l < "$f" | tr -dc 0-9)" = 1 ] || fail "oob file $f holds more than one line"; done
cat "$RD/decisions.jsonl" "$RD"/oob/l.* 2>/dev/null | $JQ -s length >/dev/null && pass "the merged audit input parses: no torn line" || fail "merged log does not parse"

# --- a failed log append: PreToolUse denies, PostToolUse records nothing
to_ready; chmod 400 "$RD/decisions.jsonl"
deny forbidden "${C}find" "$FIND"
hook post "${C}find" "$FIND" "$(cat "$FX/find-result.txt")"
[ "$(state .find_count)" = null ] && pass "failed append records nothing" || fail "recorded despite failed append"
chmod 600 "$RD/decisions.jsonl"

# --- the fence: a hook that takes the lock after guard.json was invalidated writes nothing.
# fence_case <guard> <mv|chmod> prints "leaked" or "clean". mv is the parent's real rename; chmod
# leaves the file readable, so only the under-lock re-check can stop the write. The control copy
# lacks that re-check and MUST leak under chmod: this proves the background post really passed
# its entry check and was waiting on the lock, i.e. the case exercises the fence.
fence_case() { # runs in $(...): setup output goes to /dev/null, only the verdict word is printed
  { to_ready; allow "${C}find" "$FIND"; } >/dev/null
  local before; before="$(wc -l < "$RD/decisions.jsonl")"
  mkdir "$RD/guard.lock"
  ( G="$1"; hook post "${C}find" "$FIND" "$(cat "$FX/find-result.txt")" ) >/dev/null &   # entry check, then waits on the lock
  sleep 1
  if [ "$2" = mv ]; then mv "$RD/guard.json" "$RD/guard.json.done"; else chmod 644 "$RD/guard.json"; fi
  rmdir "$RD/guard.lock"; wait
  if [ "$(wc -l < "$RD/decisions.jsonl")" = "$before" ] && [ "$(state .find_count)" = null ]; then echo clean; else echo leaked; fi
}
sed '/^  _g_ok || exit 1$/d' "$G" > "$T/guard-nofence.sh"
cmp -s "$G" "$T/guard-nofence.sh" && fail "control copy still has the under-lock fence"
[ "$(fence_case "$T/guard-nofence.sh" chmod)" = leaked ] && pass "control: without the fence the waiting post leaks" || fail "control did not leak: the case does not reach the lock wait"
[ "$(fence_case "$G" chmod)" = clean ] && pass "fence: an invalidated guard.json stops the waiting post" || fail "fence leaked a write (chmod)"
[ "$(fence_case "$G" mv)" = clean ] && pass "fence: nothing written after the rename" || fail "fence leaked a write (mv)"

# --- replay: clean on a real log, byte-identical files, mismatch detected
to_sent; allow "${C}javascript_tool" "$(js j-get)"; hook post "${C}javascript_tool" "$(js j-get)" "SAVED 1 $(printf '%064d' 0)"
mkdir -m 700 "$T/scratch"; cp "$RD/guard.json" "$T/scratch/guard.json"; chmod 600 "$T/scratch/guard.json"
snap() { for f in "$RD/phase" "$RD/guard-state.json" "$RD/decisions.jsonl" "$T/scratch/guard.json"; do cksum < "$f"; done; ls -A "$RD" "$T/scratch"; }
h1="$(snap)"
res="$(env -i PATH=/usr/bin:/bin UORA_RUN_DIR="$T/scratch" /bin/bash "$G" replay < "$RD/decisions.jsonl")"; rrc=$?
[ "$rrc" = 0 ] && [ "$res" = "[]" ] && pass "replay of a clean log is clean" || fail "replay: rc=$rrc $res"
[ "$h1" = "$(snap)" ] && pass "replay changes no file in the run dir or in the dir it is given" || fail "replay touched files"
$JQ -c 'if .r == "not-yet" then .r = "forbidden" elif .d == "allow" and .tool == "mcp__claude-in-chrome__find" then .d = "deny" | .r = "forbidden" else . end' "$RD/decisions.jsonl" > "$T/tampered.jsonl"
res="$(env -i PATH=/usr/bin:/bin UORA_RUN_DIR="$T/scratch" /bin/bash "$G" replay < "$T/tampered.jsonl")"; rrc=$?
[ "$rrc" = 0 ] && $JQ -e 'type == "array" and length > 0 and all(.[]; .why == "mismatch")' <<<"$res" >/dev/null \
  && pass "replay catches a re-decision mismatch" || fail "tamper not caught (rc=$rrc res=$res)"
printf '{"id":"x","half":"pre"' >> "$T/torn.jsonl"; cat "$RD/decisions.jsonl" "$T/torn.jsonl" > "$T/torn2.jsonl"
env -i PATH=/usr/bin:/bin UORA_RUN_DIR="$T/scratch" /bin/bash "$G" replay < "$T/torn2.jsonl" >/dev/null 2>&1
[ $? != 0 ] && pass "a torn last line fails replay" || fail "torn line accepted"

# --- a real race: READY's PostToolUse and find's PreToolUse contend for the lock at once. Whichever
# wins (find allowed, not-yet or busy), log order must equal state order, so the merged log replays clean.
for k in 1 2 3; do
  to_nav; allow "${C}javascript_tool" "$(js j-home)"
  mkdir "$RD/guard.lock"
  ( hook post "${C}javascript_tool" "$(js j-home)" READY ) &     # polls the held lock every 10 ms
  sleep 0.2; rmdir "$RD/guard.lock"
  ( N=900; hook pre "${C}find" "$FIND"; printf '%s' "$OUT" > "$T/race-find.$k" ) &   # races the polling post
  wait
  grep -q 'uora-guard: \(allow\|deny not-yet\|deny busy\)' "$T/race-find.$k" || fail "race $k: unexpected find answer: $(cat "$T/race-find.$k")"
  cp "$RD/guard.json" "$T/scratch/guard.json"
  res="$(cat "$RD/decisions.jsonl" "$RD"/oob/l.* 2>/dev/null | env -i PATH=/usr/bin:/bin UORA_RUN_DIR="$T/scratch" /bin/bash "$G" replay)"; rrc=$?
  [ "$rrc" = 0 ] && [ "$res" = "[]" ] && pass "contended READY/find run $k replays clean" || fail "contended replay $k: $res"
done

[ "$FAIL" = 0 ] && echo "PASS test-ultra-oracle-guard-record" || exit 1
