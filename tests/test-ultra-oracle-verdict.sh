#!/bin/bash
# tests/test-ultra-oracle-verdict.sh — spec 2026-11-01 §4 audit, §2 phase table, §4 precedence.
set -u
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0; pass() { echo "OK:   $1"; }; fail() { echo "FAIL: $1"; FAIL=1; }
# shellcheck source=/dev/null
. "$DIR/tests/lib/uora-test-env.sh"
uora_env; cd "$T" || exit 1
# The library must load under errexit: run-retrieval-loop.sh sources it after `set -euo pipefail`.
[ "$(/bin/bash -c 'set -euo pipefail; source "$1/scripts/lib/ultra-oracle.sh"; [ -n "$_UORA_FACTS_JQ" ] && [ -n "$_UORA_PHASE_JQ" ] && echo sourced' _ "$DIR" 2>/dev/null)" = sourced ] \
  && pass "sources under set -euo pipefail with both jq programs loaded" || fail "library aborts an errexit caller at load"
# shellcheck source=/dev/null
source "$DIR/scripts/lib/ultra-oracle.sh"
JQ=/usr/bin/jq

mkrun() { uora_scenario "$@"; mkrun_sc; }
mkrun_sc() { # -> RD: the current scenario run to completion, as the parent sees it after the child's exit
  local run tag
  run="$(_uora_new_run)"; tag="${run%%$'\t'*}"; RD="${run#*$'\t'}"
  printf 'prompt\n' > "$RD/uora-$tag.txt"
  _uora_render_guard "$RD" "$tag"; _uora_render_settings "$RD"
  /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin "$T/bin/claude" -p --chrome --settings "$RD/child-settings.json" x \
    > "$RD/stream.jsonl" 2>/dev/null
  mv -f "$RD/guard.json" "$RD/guard.json.done"
}
fx() { _uora_classify "$RD" | $JQ -r "$1"; }

mkrun $UORA_HAPPY
[ "$(fx .audit)" = clean ] && pass "happy run audits clean" || fail "happy audit $(fx .violations)"
[ "$(fx '.saved.bytes > 0')" = true ] && pass "SAVED parsed" || fail "saved"
[ "$(fx .uora_id)" = 0f0e0d0c-0b0a-4908-8706-050403020100 ] && pass "UORA_ID parsed" || fail "uora id"
[ "$(fx '.tab, .closed, .archive' | tr '\n' ' ')" = "101 true ARCHIVED " ] && pass "tab ledger and archive" || fail "ledger"

# a tool-level error (is_error) is never evidence of success, whatever its text says
mkrun $UORA_HAPPY
$JQ -c 'if .type == "user" then .message.content |= map(if .type == "tool_result" then .is_error = true else . end) else . end' \
  "$RD/stream.jsonl" > "$RD/s" && mv "$RD/s" "$RD/stream.jsonl"
[ "$(fx '[.saved, .uora_id, .archive, .uploaded] | tostring')" = '[null,null,null,false]' ] \
  && pass "is_error results supply no SAVED, UORA_ID, ARCHIVED or upload" || fail "is_error counted as success: $(fx '[.saved, .uora_id, .archive, .uploaded]')"

# --- live fixtures (Task 7): the facts program reads what the producer actually emits
LRD="$T/live"; mkdir -m 700 "$LRD"   # _uora_render_guard creates oob/ itself
cp "$DIR/tests/fixtures/ultra-oracle/stream-ok.jsonl" "$LRD/stream.jsonl"
cp "$DIR/tests/fixtures/ultra-oracle/decisions-ok.jsonl" "$LRD/decisions.jsonl"
tag="$($JQ -r 'select(.half == "pre" and .tool == "mcp__claude-in-chrome__file_upload") | .input.paths[0]' "$LRD/decisions.jsonl" | sed -n 's/.*uora-\([0-9a-f]\{16\}\)\.txt$/\1/p' | head -1)"
staged="$($JQ -r 'select(.half == "pre" and .tool == "mcp__claude-in-chrome__file_upload") | .input.paths[0]' "$LRD/decisions.jsonl" | head -1)"
_uora_render_guard "$LRD" "$tag" && $JQ --arg p "$staged" '.staged = $p' "$LRD/guard.json" > "$LRD/g" && mv "$LRD/g" "$LRD/guard.json.done"
RD="$LRD"
[ "$(fx '.audit + " " + (.saved != null | tostring) + " " + (.uora_id != null | tostring)')" = "clean true true" ] \
  && pass "the live r1 consult audits clean with SAVED and UORA_ID" || fail "live: $(fx .violations)"

# --- join violations
mkrun $UORA_HAPPY
$JQ -c 'select(.id != "toolu_fake5")' "$RD/decisions.jsonl" > "$RD/d" && mv "$RD/d" "$RD/decisions.jsonl"
[ "$(fx .audit)" = audit ] && pass "a stream tool_use with no log line -> audit" || fail "unlogged"
mkrun $UORA_HAPPY
$JQ -c 'if .id == "toolu_fake3" and .half == "pre" then .d = "deny" | .r = "not-yet" else . end' "$RD/decisions.jsonl" > "$RD/d" && mv "$RD/d" "$RD/decisions.jsonl"
[ "$(fx .audit)" = audit ] && pass "an executed call logged as denied -> audit" || fail "executed without allow"
mkrun $UORA_HAPPY
sed -i.bak 's/"tabId":101}/"tabId":102}/' "$RD/stream.jsonl"
[ "$(fx .audit)" = audit ] && pass "a stream input that differs from the logged input -> audit" || fail "input mismatch"
mkrun $UORA_HAPPY
grep -q '"name":"mcp__claude-in-chrome__tabs_close_mcp"' "$RD/stream.jsonl" || fail "fixture: no compact tabs_close_mcp tool_use to rewrite"
sed -i.bak 's/"name":"mcp__claude-in-chrome__tabs_close_mcp"/"name":"mcp__claude-in-chrome__read_page"/' "$RD/stream.jsonl"
[ "$(fx '[.violations[].why] | index("tool") != null')" = true ] && pass "same id and input under another tool name -> audit (tool)" || fail "tool substitution: $(fx .violations)"
# §5: a snippet result outside the closed grammar ends the run as an error, wherever it sits
mkrun ctx nav home find upload attached send id 'poll=hello there' poll dl get archive close exit0
[ "$(fx '.audit + " " + ([.violations[].why] | join(","))')" = "audit nongrammar" ] && pass "a non-grammar J-poll result -> audit" || fail "nongrammar poll: $(fx .violations)"
mkrun ctx nav home find upload attached send id poll dl get 'archive=archived' close exit0
[ "$(fx .audit)" = audit ] && pass "a non-grammar J-archive result after SAVED -> audit" || fail "nongrammar archive"
mkrun $UORA_HAPPY
printf '{"id":"x","half":"pre"' >> "$RD/decisions.jsonl"
[ "$(fx .audit)" = audit ] && pass "a torn last log line -> audit" || fail "torn line"
mkrun $UORA_HAPPY
printf '%s\n' '{"id":"toolu_fake9","half":"post","tool":"mcp__claude-in-chrome__javascript_tool","input":{},"d":"post-lost","r":null,"rec":null}' > "$RD/oob/l.post"
[ "$(fx .audit)" = audit ] && pass "a post-lost line -> audit" || fail "post-lost"
mkrun $UORA_HAPPY
printf '%s\n' '{"id":"toolu_fake4","half":"pre","tool":"mcp__claude-in-chrome__find","input":{},"d":"deny","r":"busy","rec":null}' > "$RD/oob/l.busy"
[ "$(fx .audit)" = clean ] && pass "a busy line is not a violation" || fail "busy flagged"

# --- forbidden denies
mkrun ctx nav home find '{"tool":"file_upload","input":{"paths":["/etc/hosts"],"ref":"ref_7","tabId":101},"result":"x"}' exit0
[ "$(fx '.audit + " " + .phase')" = "guard-denied setup" ] && pass "a foreign upload path: guard-denied, phase stays setup" || fail "foreign path"
uora_scenario $UORA_HAPPY; sed -i.bak '$d' "$F/scenario.jsonl"
printf '%s\n' '{"tool":"read_page","input":{"tabId":101},"result":"x"}' '{"exit":0}' >> "$F/scenario.jsonl"
mkrun_sc
[ "$(fx .audit)" = guard-denied ] && pass "SAVED followed by a forbidden deny -> guard-denied" || fail "post-SAVED forbidden"

# --- retryable denies and absence after SAVED are not violations
mkrun ctx nav "{\"batch\":[$(_uora_std home),$(_uora_std find)]}" find upload attached send id poll dl get archive close exit0
[ "$(fx .audit)" = clean ] && pass "J-home and find batched, find reissued after not-yet -> clean" || fail "batch: $(fx .violations)"
mkrun ctx nav home find upload attached send id poll dl get 'archive!'
[ "$(fx .audit)" = clean ] && pass "an allowed J-archive with no result after SAVED -> clean" || fail "absence after SAVED"

# --- phase table (§2)
pr() { fx '.phase + " " + .presult'; }
mkrun ctx nav home=ERR\ pro exit0;          [ "$(pr)" = "setup error pro-unavailable" ] && pass "J-home ERR pro" || fail "pro: $(pr)"
mkrun ctx nav 'home=ERR not-home' exit0;    [ "$(pr)" = "setup error not-home" ] && pass "J-home ERR not-home" || fail "not-home: $(pr)"
mkrun ctx nav home=ERR\ origin exit0;       [ "$(pr)" = "setup error origin" ] && pass "J-home ERR origin" || fail "origin: $(pr)"
mkrun ctx nav home find exit0;              [ "$(pr)" = "setup error child-died" ] && pass "setup default -> child-died" || fail "setup default: $(pr)"
mkrun @disc
[ "$(pr)" = "setup unavailable extension-not-connected" ] && pass "disconnect fixture at setup" || fail "disconnect: $(pr)"
mkrun @auth
[ "$(pr)" = "setup unavailable claude-unavailable" ] && pass "signed-out fixture at setup" || fail "auth: $(pr)"
mkrun ctx nav home find upload exit0;       [ "$(pr)" = "submitting error upload" ] && pass "upload, no J-send -> upload" || fail "no jsend: $(pr)"
mkrun ctx nav home find upload 'attached=ERR upload' exit0; [ "$(pr)" = "submitting error upload" ] && pass "J-attached ERR upload" || fail "attached err: $(pr)"
mkrun ctx nav home find upload attached 'send=ERR focus' exit0; [ "$(pr)" = "submitting error send" ] && pass "J-send ERR focus -> send" || fail "focus: $(pr)"
mkrun ctx nav home find upload attached 'send=ERR send' exit0;  [ "$(pr)" = "submitting error send" ] && pass "J-send ERR send -> send" || fail "send: $(pr)"
for e in draft schema; do   # both return before send.click(), so nothing was sent
  mkrun ctx nav home find upload attached "send=ERR $e" exit0; [ "$(pr)" = "submitting error send" ] && pass "J-send ERR $e -> send" || fail "$e: $(pr)"
done
mkrun ctx nav home find upload attached 'send!';                [ "$(pr)" = "submitting error submit-uncertain" ] && pass "J-send with no result -> submit-uncertain" || fail "jsend die: $(pr)"
mkrun ctx nav home find upload attached send id=NOID exit0;     [ "$(pr)" = "submitting error submit-uncertain" ] && pass "SENT then NOID" || fail "noid: $(pr)"
mkrun ctx nav home find 'upload!'; printf 'setup\n' > "$RD/phase"
[ "$(fx .phase)" = submitting ] && pass "an allowed upload with no result -> submitting (fails closed)" || fail "upload die"
# the defensive stream: an Uploaded result while phase still reads setup
mkrun ctx nav home find upload exit0; printf 'setup\n' > "$RD/phase"
[ "$(pr)" = "submitting error upload" ] && pass "Uploaded in the stream overrides phase setup" || fail "defensive: $(pr)"
# an upload denied in a find/upload batch, then reissued and run: the run that succeeded counts
mkrun ctx nav home "{\"batch\":[$(_uora_std find),$(_uora_std upload)]}" upload exit0; printf 'setup\n' > "$RD/phase"
[ "$(fx '.audit + " " + .phase + " " + .presult + " " + (.uploaded | tostring)')" = "clean submitting error upload true" ] \
  && pass "a denied upload then a successful retry -> uploaded, submitting" || fail "upload retry: $(fx '[.audit, .phase, .presult, .uploaded]')"
mkrun ctx nav home find "{\"tool\":\"file_upload\",\"input\":{\"paths\":[\"@STAGED@\"],\"ref\":\"ref_8\",\"tabId\":101},\"result\":\"x\",\"die\":true}"
[ "$(fx .phase)" = setup ] && pass "a denied upload with no result leaves setup" || fail "denied upload"
for c in auth:401 rate:429 server:503 gone:404 binding: schema: origin: network:; do
  code="${c%%:*}" http="${c#*:}"
  mkrun ctx nav home find upload attached send id "poll=ERR $code${http:+ $http}" exit0
  want="error $code"
  [ "$(fx .presult)" = "$want" ] && pass "submitted ERR $code" || fail "submitted $code: $(fx .presult)"
done
mkrun ctx nav home find upload attached send id 'poll=ERR timeout' exit0
[ "$(fx .presult)" = "error fetch-timeout" ] && pass "ERR timeout -> fetch-timeout" || fail "fetch-timeout"
mkrun ctx nav home find upload attached send id 'poll=ERR weird' exit0
[ "$(fx .presult)" = "error child-died" ] && pass "unlisted ERR -> terminal error" || fail "unlisted"
mkrun ctx nav home find upload attached send id exit0
[ "$(fx .presult)" = "error child-died" ] && pass "exit 0 right after UORA_ID -> child-died" || fail "after id"
mkrun ctx nav home find upload attached send id poll exit0
[ "$(fx .presult)" = "error child-died" ] && pass "exit 0 after DONE -> child-died" || fail "after done"
mkrun ctx nav home find=x 'upload' exit0
[ "$(fx .noref)" = true ] && pass "zero Attach files lines -> no-ref recorded" || fail "noref"

# --- precedence (§4)
[ "$(_uora_precedence audit 1 ok 0 0 'error x')" = "error audit" ] && pass "violation first" || fail "p1"
[ "$(_uora_precedence clean 1 hash-mismatch 1 0 'error x')" = "error hash-mismatch" ] && pass "SAVED check beats cutoff" || fail "p2"
[ "$(_uora_precedence clean 1 ok 1 0 'error x')" = "ok -" ] && pass "SAVED + verified -> ok despite cutoff" || fail "p2 ok"
[ "$(_uora_precedence clean 0 - 1 1 'error x')" = "timeout timeout" ] && pass "cutoff beats no-ref" || fail "p3"
[ "$(_uora_precedence clean 0 - 0 1 'error x')" = "error upload" ] && pass "no-ref -> upload" || fail "p4"
[ "$(_uora_precedence clean 0 - 0 0 'error send')" = "error send" ] && pass "phase table last" || fail "p5"

[ "$FAIL" = 0 ] && echo "PASS test-ultra-oracle-verdict" || exit 1
