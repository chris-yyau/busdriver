#!/bin/bash
# tests/test-ultra-oracle-chrome-phases.sh — spec 2026-11-01 §11 adapter cases: the §2 phase table,
# the §4 containment and audit outcomes, the §7 status mapping, end to end through the real guard.
set -u
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0; pass() { echo "OK:   $1"; }; fail() { echo "FAIL: $1"; FAIL=1; }
# shellcheck source=/dev/null
. "$DIR/tests/lib/uora-test-env.sh"
uora_env; cd "$T" || exit 1
# shellcheck source=/dev/null
source "$DIR/scripts/lib/ultra-oracle.sh"
uora_inproc
JQ=/usr/bin/jq
chk() { # <label> <ST> <ERR or -> [<hint substring>] [<launches>]
  local ok=1
  [ "$ST" = "$2" ] || ok=0
  [ "$3" = - ] || [ "$ERR" = "$3" ] || ok=0
  [ -z "${4:-}" ] || [[ "$HINT" == *"$4"* ]] || ok=0
  [ "$(uora_launches)" = "${5:-1}" ] || ok=0
  if [ "$ok" = 1 ]; then pass "$1"; else fail "$1: ST=$ST ERR=$ERR HINT=$HINT launches=$(uora_launches)"; fi
}
last_record() { $JQ -r "$1" "$(ls -t "$HOME/.cache/busdriver/ultra-oracle"/run-*/record.json | head -1)"; }
_UORA_SETTLE_MAX=2   # the never-settling download case would otherwise wait the full 30 s

# --- setup
uora_run blocking ctx nav 'home=ERR pro' close exit0
chk "J-home ERR pro -> pro-unavailable, no upload" error pro-unavailable "select Pro"
uora_run blocking ctx nav 'home=ERR not-home' close exit0
chk "J-home ERR not-home -> not-home with the English-UI hint" error not-home "UI in English"
[ "$(last_record .phase)" = setup ] && pass "...and the phase stayed setup" || fail "not-home phase"
uora_run blocking ctx nav home find exit0
chk "a setup exit matching neither fixture -> child-died" error child-died "re-run the consult"
uora_run blocking @disc
chk "disconnect at setup, blocking -> skipped:unavailable" skipped:unavailable extension-not-connected "reconnect Claude in Chrome"
uora_run background @disc
chk "disconnect at setup, background -> .rc 1 + reconnect hint" rc=1 extension-not-connected "reconnect Claude in Chrome"
uora_run blocking @auth
chk "signed-out child, blocking -> skipped:unavailable" skipped:unavailable claude-unavailable "not signed in"
uora_run background @auth
chk "signed-out child after dispatch -> .rc 1, claude-unavailable" rc=1 claude-unavailable "not signed in"
printf 'fail\n' > "$F/open-mode"; uora_run blocking $UORA_HAPPY; rm -f "$F/open-mode"
chk "a failing reopen -> extension-not-connected, no child" skipped:unavailable extension-not-connected "" 0
printf 'fail\n' > "$F/open-mode"; uora_run background $UORA_HAPPY; rm -f "$F/open-mode"
chk "a failing reopen, background -> .rc 1, no child" rc=1 extension-not-connected "" 0

# --- containment (§4): what the guard denies, and how the run ends
uora_run blocking ctx nav home find=x upload close exit0
chk "zero Attach files lines -> no-ref -> upload (not guard-denied)" error upload "UI must be in English"
two="$($JQ -r '.find' "$F/std-results.json")"$'\n'"$($JQ -r '.find' "$F/std-results.json" | grep 'Attach files' | sed 's/ref_7/ref_9/')"
uora_run blocking ctx nav home "find=$two" upload close exit0
chk "two Attach files lines -> no-ref -> upload" error upload
uora_run blocking ctx nav home find '{"tool":"file_upload","input":{"paths":["/etc/hosts"],"ref":"ref_7","tabId":101},"result":"x"}' close exit0
chk "a foreign upload path -> guard-denied, not submit-uncertain" error guard-denied "outside its fixed steps"
[ "$(last_record .phase)" = setup ] && pass "...and the phase stayed setup" || fail "foreign path phase"
uora_run blocking ctx nav upload home find upload attached send id poll dl get archive close exit0
chk "file_upload before READY is denied not-yet, then allowed once -> ok" ok - ""
uora_run blocking ctx nav home find '{"tool":"read_page","input":{"tabId":101},"result":"x"}' upload attached send id poll dl get archive close exit0
chk "a read_page call -> forbidden -> guard-denied, never ok" error guard-denied
uora_run blocking ctx nav home find '{"tool":"computer","input":{"action":"screenshot","tabId":101},"result":"x"}' exit0
chk "any computer action -> guard-denied" error guard-denied
uora_run blocking ctx nav home find find upload exit0
chk "a second find -> guard-denied" error guard-denied
uora_run blocking ctx nav "{\"batch\":[$(_uora_std home),$(_uora_std find)]}" find upload attached send id poll dl get archive close exit0
chk "J-home and find batched: find not-yet, reissued -> ok" ok - ""
uora_run blocking ctx nav home "{\"batch\":[$(_uora_std find),$(_uora_std upload)]}" upload attached send id poll dl get archive close exit0
chk "find and file_upload batched: upload not-yet, reissued -> ok" ok - ""
uora_run blocking ctx nav home find '{"tool":"file_upload","input":{"paths":["@STAGED@"],"ref":"ref_7","tabId":101},"result":"x","refuse":true}' exit0
chk "E16: a timed-out guard on file_upload -> refusal, no upload, never ok" error audit
[ "$(last_record .phase)" = setup ] && pass "...and the phase stayed setup" || fail "E16 phase"
uora_run blocking ctx nav home find "{\"tool\":\"file_upload\",\"input\":{\"paths\":[\"@STAGED@\"],\"ref\":\"ref_8\",\"tabId\":101},\"result\":\"x\",\"die\":true}"
chk "a foreign-ref upload with no result -> forbidden deny -> guard-denied" error guard-denied
[ "$(last_record .phase)" = setup ] && pass "...and the phase stayed setup" || fail "foreign-ref phase"
# A retryable (not-yet) deny on an upload before find, then the child dies: no violation, so the
# phase table decides -> setup, child-died.
uora_run blocking ctx nav home '{"tool":"file_upload","input":{"paths":["@STAGED@"],"ref":"ref_7","tabId":101},"result":"x","die":true}'
chk "an upload before find (not-yet deny) with no result -> setup, child-died" error child-died
[ "$(last_record .phase)" = setup ] && pass "...and the phase stayed setup" || fail "not-yet upload phase"
uora_run blocking ctx nav home '{"strand":true}' find upload exit0
chk "a stranded guard.lock -> busy denials, never ok" error child-died
# A cancelled consult: TERM to the core mid-run kills the child's group, never uploads afterwards,
# releases the mutex and leaves no .rc 0 (the core's INT/TERM/HUP traps, Task 13).
uora_scenario ctx nav home find '{"sleep":6}' upload attached send id poll dl get archive close exit0
UORA_N=$((UORA_N + 1)); OUT="$T/out/c$UORA_N.md"; rm -f "$F/launches"
ST="$(_uora_chrome_consult --prompt-file "$T/prompt.txt" --out "$OUT" --mode background)"
i=0; while [ "$(uora_launches)" = 0 ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
crd="$(ls -td "$HOME/.cache/busdriver/ultra-oracle"/run-* 2>/dev/null | head -1)"
i=0; while [ ! -s "$crd/core.pid" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
kill -TERM "$(cat "$crd/core.pid")"
i=0; while [ ! -f "$OUT.rc" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
sleep 1
[ "$ST" = dispatched ] && ! pgrep -f "$T/bin/claude -p" >/dev/null && pass "TERM to the core kills the child's group" || fail "child survived a cancelled consult"
[ "$(cat "$OUT.rc" 2>/dev/null)" != 0 ] && pass "a cancelled consult never reports .rc 0" || fail "cancelled consult rc=$(cat "$OUT.rc" 2>/dev/null)"
sleep 7    # past the scenario's sleep: a surviving child would reach file_upload by now
[ ! -e "$crd/phase" ] || [ "$(cat "$crd/phase")" = setup ] && [ "$(/usr/bin/jq -r '.phase // "setup"' "$crd/record.json" 2>/dev/null)" = setup ] \
  && pass "nothing uploaded after the cancel (phase stayed setup)" || fail "the cancelled consult reached $(cat "$crd/phase" 2>/dev/null)"
uora_run blocking $UORA_HAPPY
chk "the mutex is free right after a cancelled consult" ok - ""
# a guard that exits 0 with no output decides nothing: nothing is pre-approved for chrome tools (E16)
cp -R "$DIR/scripts/hooks/ultra-oracle-child" "$T/child"; printf '#!/bin/bash\nexit 0\n' > "$T/child/guard.sh"
_UORA_CHILD_DIR_SAVE="$_UORA_CHILD_DIR"; _UORA_CHILD_DIR="$T/child"
uora_run blocking $UORA_HAPPY
_UORA_CHILD_DIR="$_UORA_CHILD_DIR_SAVE"
chk "a silent guard -> every chrome call refused, never ok" error audit
[ -z "$(find "$HOME/Downloads" -name 'uora-*')" ] && pass "...and nothing was downloaded" || fail "silent guard ran a call"

# --- submitting (§2)
uora_run blocking ctx nav home find upload exit0
chk "a stream ending after file_upload -> upload, the hint names the draft" error upload "draft with the attachment"
uora_run blocking ctx nav home find upload 'attached=ERR upload' close exit0
chk "J-attached ERR upload -> upload" error upload
uora_run blocking ctx nav home find upload attached 'send!'
chk "a stream ending right after the J-send tool_use -> submit-uncertain" error submit-uncertain "unarchived consult chat"
uora_run blocking ctx nav home find upload attached 'send=ERR focus' close exit0
chk "J-send ERR focus -> send" error send "draft with the attachment"
uora_run blocking ctx nav home find upload attached 'send=ERR send' close exit0
chk "J-send ERR send -> send" error send
uora_run blocking ctx nav home find upload attached send id=NOID close exit0
chk "SENT then NOID -> submit-uncertain" error submit-uncertain

# --- submitted (§2): the id is named, nothing archived, one child
uora_run blocking ctx nav home find upload attached send id exit0
chk "exit 0 right after UORA_ID -> child-died with the id" error child-died "0f0e0d0c-0b0a-4908-8706-050403020100"
uora_run blocking ctx nav home find upload attached send id poll exit0
chk "exit 0 after DONE -> child-died with the id" error child-died "0f0e0d0c-0b0a-4908-8706-050403020100"
grep -q j-archive "$F/scenario.jsonl" && fail "scenario archived" || pass "...and nothing was archived"
uora_run blocking ctx nav home find upload attached send id 'poll=ERR timeout' close exit0
chk "ERR timeout during PENDING -> fetch-timeout, with the id" error fetch-timeout "0f0e0d0c"
uora_run blocking ctx nav home find upload attached send id 'poll=ERR network' close exit0
chk "ERR network -> network" error network "could not be reached"
uora_run blocking ctx nav home find upload attached send id 'poll=ERR gone 404' close exit0
chk "HTTP 404 -> gone" error gone "no longer exists"
uora_run blocking ctx nav home find upload attached send id 'poll=ERR rate 429' close exit0
chk "HTTP 429 -> rate, naming the code" error rate "HTTP 429"
uora_run blocking ctx nav home find upload attached send id 'poll=ERR zzz' close exit0
chk "an unlisted ERR -> terminal error" error child-died
uora_run blocking ctx nav home find upload attached send id poll 'get=ERR binding' close exit0
chk "a continued existing conversation -> binding, nothing archived" error binding

# --- after SAVED (§4 precedence 1 and 2)
uora_run blocking ctx nav home find upload attached send id poll dl get '{"tool":"read_page","input":{"tabId":101},"result":"x"}' exit0
chk "SAVED then a forbidden deny -> guard-denied" error guard-denied
uora_run blocking ctx nav home find upload attached send id poll dl get 'archive!'
chk "SAVED, then an allowed J-archive with no result -> ok" ok - ""
uora_run blocking ctx nav home find upload attached send id poll '{"download":{"never":true}}' 'get=@SAVED@' '{"exit":1}'
chk "SAVED with the file never settling, then a crash -> error, never ok" error download-missing
[ -z "$(find "$HOME/Downloads" -name 'uora-*')" ] && pass "...and cleanup deleted the .crdownload" || fail "crdownload left"
uora_run blocking ctx nav home find upload attached send id poll dl '{"exit":1}'
chk "a child that dies between the download and SAVED -> the file is never accepted" error child-died
[ -z "$(find "$HOME/Downloads" -name 'uora-*')" ] && pass "...and cleanup deleted it" || fail "unaccepted download left"

[ "$FAIL" = 0 ] && echo "PASS test-ultra-oracle-chrome-phases" || exit 1
