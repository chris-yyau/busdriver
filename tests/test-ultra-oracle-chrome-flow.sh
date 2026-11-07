#!/bin/bash
# tests/test-ultra-oracle-chrome-flow.sh — spec 2026-11-01 §11 adapter cases: success, acceptance,
# publication, cleanup, the pre-dispatch checks. In-process, with the seams reassigned (§2).
set -u
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0; pass() { echo "OK:   $1"; }; fail() { echo "FAIL: $1"; FAIL=1; }
# shellcheck source=/dev/null
. "$DIR/tests/lib/uora-test-env.sh"
uora_env; cd "$T" || exit 1
export _ULTRA_ORACLE_PLATFORM=Plan9 _ULTRA_ORACLE_OPEN_CMD=/bin/false   # exported: must change nothing (§11)
# shellcheck source=/dev/null
source "$DIR/scripts/lib/ultra-oracle.sh"
[ "$_ULTRA_ORACLE_PLATFORM" = "$(uname -s)" ] && [ "${_ULTRA_ORACLE_OPEN_CMD[*]}" = "open -a Google Chrome" ] \
  && pass "exported seam variables are ignored at source time" || fail "seams read from the environment"
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

# --- success, both modes; exactly one open, after the mutex; only record.json left
uora_run blocking $UORA_HAPPY
chk "blocking success" ok - ""
[ "$(cat "$OUT")" = "$(/usr/bin/jq -r .text "$DIR/tests/fixtures/ultra-oracle/answer-ok.json")" ] && grep -q QUALIFY-ONE "$OUT" \
  && pass "the answer text is published (equals the live fixture's .text)" || fail "answer body: $(head -c 200 "$OUT")"
[ ! -e "$OUT.err" ] && [ ! -e "$OUT.hint" ] && pass "a clean ok writes no .err/.hint" || fail "stray err/hint"
[ "$(uora_opens)" = 1 ] && pass "the reopen command ran exactly once" || fail "opens $(uora_opens)"
uora_only_record && pass "the run dir holds only record.json" || fail "leftovers: $(ls -A "$HOME/.cache/busdriver/ultra-oracle"/run-*)"
[ -z "$(find "$T" -path "$HOME/.cache" -prune -o -name 'uora-*.txt' -print)" ] && pass "no staged prompt outside the cache" || fail "staged copy leaked"
[ "$($JQ -r '.status + " " + .phase' "$HOME/.cache/busdriver/ultra-oracle"/run-*/record.json | tail -1)" = "ok captured" ] \
  && pass "record.json: ok, captured" || fail "record"
[[ $- != *m* ]] && pass "the caller's shell has monitor mode off" || fail "monitor mode leaked"
uora_run background $UORA_HAPPY
chk "background success" rc=0 - ""
uora_only_record && pass "background cleanup also leaves only record.json" || fail "background leftovers"
grep -q QUALIFY-ONE "$OUT" && pass "background answer published before .rc" || fail "bg answer"
uora_run blocking ctx nav home find upload attached send id poll '{"download":{"fixture":"answer-cjk.json"}}' get archive close exit0
chk "CJK and non-BMP answer" ok - ""
cmp -s <($JQ -j '.text' "$F/answer-cjk.json") "$OUT" && pass "the CJK text is byte-exact" || fail "CJK bytes"

# --- §6 checks after SAVED
dl() { printf '{"download":%s}' "$1"; }
uora_run blocking ctx nav home find upload attached send id poll "$(dl '{"mutate":".model = \"gpt-6\""}')" get close exit0
chk "non-Pro model in the file -> binding" error binding
uora_run blocking ctx nav home find upload attached send id poll "$(dl '{"mutate":".attachment = \"uora-ffffffffffffffff.txt\""}')" get close exit0
chk "wrong attachment tag in the file -> binding" error binding
uora_run blocking ctx nav home find upload attached send id 'poll=ERR binding' close exit0
chk "J-get-side binding failure finishes fast" error binding
uora_run blocking ctx nav home find upload attached send id poll "$(dl '{"mutate":".end_turn = false"}')" get close exit0
chk "a final node without end_turn -> binding" error binding
uora_run blocking ctx nav home find upload attached send id poll "$(dl '{"mutate":".id = \"11111111-2222-4333-8444-555555555555\""}')" get close exit0
chk "a wrong conversation id -> binding" error binding "The consult chat 0f0e0d0c"
uora_run blocking ctx nav home find upload attached send id poll "$(dl '{"mutate":"del(.text)"}')" get close exit0
chk "missing field -> schema" error schema
uora_run blocking ctx nav home find upload attached send id poll "$(dl '{"mutate":".text = 5"}')" get close exit0
chk "malformed field -> schema" error schema
uora_run blocking ctx nav home find upload attached send id poll "$(dl '{"saved":"SAVED 99 0000000000000000000000000000000000000000000000000000000000000000"}')" get close exit0
chk "SAVED with a missing file -> download-missing" error download-missing "searched:"
_UORA_SETTLE_MAX=2
uora_run blocking ctx nav home find upload attached send id poll "$(dl '{"never":true}')" get close exit0
chk "a download that never settles -> download-missing" error download-missing
_UORA_SETTLE_MAX=30
uora_run blocking ctx nav home find upload attached send id poll "$(dl '{"late":3}')" get archive close exit0
chk "a late .crdownload rename settles -> ok" ok - ""
mkdir -p "$HOME/Library/Application Support/Google/Chrome/Profile 2" "$T/custom"
printf '{"download":{"default_directory":"%s"}}' "$T/custom" > "$HOME/Library/Application Support/Google/Chrome/Profile 2/Preferences"
uora_run blocking ctx nav home find upload attached send id poll "$(dl "{\"dir\":\"$T/custom\"}")" get archive close exit0
chk "a non-default profile's download dir -> ok" ok - ""
uora_run blocking ctx nav home find upload attached send id poll "$(dl '{"name":"uora-@TAG@ (1).json"}')" get archive close exit0
chk "a ' (1)' copy matching size and hash -> ok" ok - ""
uora_run blocking ctx nav home find upload attached send id poll "$(dl '{"mutate":".text = \"I\""}')" get close exit0
chk "a degenerate answer -> verdict-floor" error verdict-floor
uora_run blocking ctx nav home find upload attached send id poll "$(dl '{"badhash":true}')" get close exit0
chk "a right-sized file with another hash -> hash-mismatch" error hash-mismatch "searched:"

# --- publication: notices on ok, .err/.hint before .rc, stale output
uora_run blocking ctx nav home find upload attached send id poll dl get 'archive=ERR archive 500' close exit0
chk "archive failure after a clean SAVED -> ok" ok archive "could not be archived"
uora_run background ctx nav home find upload attached send id poll dl get 'archive=ERR archive 500' close exit0
chk "background: ok with the archive notice" rc=0 archive "could not be archived"
# A notice that cannot be written must not hide behind ok: pre-create the next run's
# .hint.partial as a directory, so the hint write fails after the answer is published.
for m in blocking background; do
  mkdir -p "$T/out/c$((UORA_N + 1)).md.hint.partial"
  uora_run "$m" ctx nav home find upload attached send id poll dl get 'archive=ERR archive 500' close exit0 2> "$T/notice.err"
  rmdir "$OUT.hint.partial" 2>/dev/null
  case "$m" in blocking) want=error ;; *) want=rc=1 ;; esac
  lrd="$(ls -td "$HOME/.cache/busdriver/ultra-oracle"/run-* 2>/dev/null | head -1)"
  [ "$ST" = "$want" ] && [ "$(/usr/bin/jq -r .reason "$lrd/record.json" 2>/dev/null)" = internal ] \
    && pass "$m: an unwritable notice -> error internal, never ok" || fail "$m: unwritable notice gave $ST"
  [ "$m" = background ] || grep -q 'could not be archived' "$T/notice.err" \
    && pass "$m: the lost notice still reaches stderr" || fail "$m: notice lost"
done
# a symlink planted at the next run's .partial paths is replaced, never written through
printf 'precious\n' > "$T/victim"
ln -s "$T/victim" "$T/out/c$((UORA_N + 1)).md.err.partial"; ln -s "$T/victim" "$T/out/c$((UORA_N + 1)).md.hint.partial"
uora_run blocking ctx nav home '{"exit":1}'
[ "$(cat "$T/victim")" = precious ] && pass "notice writes never follow a .partial symlink" || fail "victim overwritten: $(cat "$T/victim")"
chk "a crashed child that left its tab -> tab-cleanup names it" error child-died "tab 101"
grep -qx tab-cleanup "$OUT.err" && pass ".err appends tab-cleanup" || fail "tab-cleanup reason"
printf 'STALE VERDICT from an earlier run\n' > "$T/out/stale.md"
OUT="$T/out/stale.md"; uora_scenario ctx nav home '{"exit":1}'
ST="$(_uora_chrome_consult --prompt hi --out "$OUT" --mode blocking)"
[ "$ST" = error ] && [ ! -e "$OUT" ] && pass "a stale <out> is cleared and never read as success" || fail "stale out"

# --- pre-dispatch checks (§7): direct tokens, no child
mkdir -p "$T/.claude"; touch "$T/.claude/skip-ultra-oracle.local"   # $T is not a repo: the skip path is cwd-relative
uora_run blocking $UORA_HAPPY
chk "the skip file -> skipped:user rc 0" skipped:user - "" 0
rm -f "$T/.claude/skip-ultra-oracle.local"
_ULTRA_ORACLE_PLATFORM=Linux; uora_run blocking $UORA_HAPPY; _ULTRA_ORACLE_PLATFORM=Darwin
chk "not macOS -> skipped:unavailable" skipped:unavailable not-macos "operator's Mac" 0
printf 'old\n' > "$F/help"; uora_run blocking $UORA_HAPPY; rm -f "$F/help"
chk "a claude without --chrome -> skipped:unavailable" skipped:unavailable claude-unavailable "not signed in" 0
_UORA_JQ=/nonexistent/jq; uora_run blocking $UORA_HAPPY; _UORA_JQ=/usr/bin/jq
chk "/usr/bin/jq missing -> skipped:unavailable naming jq" skipped:unavailable claude-unavailable "/usr/bin/jq" 0
UORA_CAP=119 uora_run blocking $UORA_HAPPY
chk "a cap under 120 s -> error" error input "floor" 0
mkfifo "$T/fifo"
ST="$(_uora_chrome_consult --prompt hi --context "$T/fifo" --out "$T/out/fifo.md" --mode blocking)"
[ "$ST" = error ] && pass "a FIFO context -> error, without blocking" || fail "fifo $ST"
printf 'a\0b' > "$T/nul.txt"
ST="$(_uora_chrome_consult --prompt hi --context "$T/nul.txt" --out "$T/out/nul.md" --mode blocking)"
[ "$ST" = error ] && grep -q NUL "$T/out/nul.md.hint" && pass "a NUL-containing context -> error" || fail "nul $ST"
ST="$(_uora_chrome_consult --prompt hi --out)"; [ "$ST" = error ] && pass "missing flag value -> error" || fail "missing value"
ST="$(_uora_chrome_consult --out "$T/out/np.md")"; [ "$ST" = error ] && pass "no prompt -> error" || fail "no prompt"

# --- a clock that fails after rendering is the cutoff: no child starts
eval "$(declare -f _uora_render_instructions | sed '1s/_uora_render_instructions/_uora_orig_render/')"
eval "$(declare -f _uora_now | sed '1s/_uora_now/_uora_orig_now/')"
# The clock fails ONCE, on the core's pre-launch read, then works again: a fix that missed that read
# would launch a child that runs to a normal answer (a marker file, since $(...) cannot redefine).
_uora_render_instructions() { _uora_orig_render "$@" && : > "$T/clockfail"; }
_uora_now() { if [ -e "$T/clockfail" ]; then rm -f "$T/clockfail"; return 1; fi; _uora_orig_now; }
uora_run blocking $UORA_HAPPY
eval "$(declare -f _uora_orig_render | sed '1s/_uora_orig_render/_uora_render_instructions/')"
eval "$(declare -f _uora_orig_now | sed '1s/_uora_orig_now/_uora_now/')"
[ "$ST" != ok ] && [ "$(uora_launches)" = 0 ] && pass "a failed clock after rendering launches no child" \
  || fail "failed clock: ST=$ST launches=$(uora_launches)"

# --- the child's environment is the allowlist, whatever the caller exports (§3)
mkdir -p "$T/evil"; printf '#!/bin/sh\necho EVIL > "%s/evil.ran"\n' "$T" > "$T/evil/jq"; chmod +x "$T/evil/jq"
PATH="$T/evil:$PATH" CLAUDE_CODE_SAFE_MODE=1 BASH_ENV="$T/evil/jq" uora_run blocking $UORA_HAPPY
chk "an exported PATH shim and CLAUDE_CODE_SAFE_MODE change nothing" ok - ""
[ ! -e "$T/evil.ran" ] && pass "the shim never ran" || fail "PATH shim ran"
[ "$(cut -d= -f1 "$F/env.1" | grep -vxE 'PWD|SHLVL|OLDPWD|_' | tr '\n' ' ')" = "HOME LANG LOGNAME PATH TMPDIR USER " ] \
  && pass "the child saw only the six allowlisted variables" || fail "env: $(cut -d= -f1 "$F/env.1" | tr '\n' ' ')"

# --- the run dir lives under $HOME/.cache, never in the repository
[ -z "$(find "$T" -name 'run-*' -not -path "$HOME/.cache/*" 2>/dev/null)" ] && pass "no run dir outside \$HOME/.cache/busdriver/ultra-oracle" || fail "run dir location"

[ "$FAIL" = 0 ] && echo "PASS test-ultra-oracle-chrome-flow" || exit 1
