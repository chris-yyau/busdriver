#!/bin/bash
# tests/test-ultra-oracle-chrome-timing.sh — spec 2026-11-01 §2 deadline, mutex, process group and
# sweep; §4 precedence 3; §11's timing cases. In-process with a fake clock.
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
_uora_now() { echo $(( $(date +%s) + $(cat "$HOME/.uora-fake/skew" 2>/dev/null || echo 0) )); }
JQ=/usr/bin/jq
# shellcheck disable=SC2034  # read by uora_run (tests/lib/uora-test-env.sh)
UORA_CAP=120
LOCK="$(_ultra_oracle_lock_file chrome-extension)"
chk() { # <label> <ST> <ERR or -> [<hint substring>] [<launches>]
  local ok=1
  [ "$ST" = "$2" ] || ok=0
  [ "$3" = - ] || [ "$ERR" = "$3" ] || ok=0
  [ -z "${4:-}" ] || [[ "$HINT" == *"$4"* ]] || ok=0
  [ "$(uora_launches)" = "${5:-1}" ] || ok=0
  if [ "$ok" = 1 ]; then pass "$1"; else fail "$1: ST=$ST ERR=$ERR HINT=$HINT launches=$(uora_launches)"; fi
}
rec() { $JQ -r "$1" "$(ls -t "$HOME/.cache/busdriver/ultra-oracle"/run-*/record.json | head -1)"; }

# --- the browser cutoff (§2, §4 precedence 3)
for m in blocking background; do
  uora_run "$m" ctx nav home find upload attached send id poll=PENDING '{"skew":100}' '{"hang":true}'
  want=timeout; [ "$m" = background ] && want=rc=124
  chk "$m: the cutoff during J-poll PENDING after UORA_ID -> timeout 124 with the id" "$want" timeout "0f0e0d0c"
done
[ "$(rec .cutoff)" = true ] && pass "record.json says the parent terminated the child at the cutoff" || fail "cutoff not recorded"
[ "$(rec '.finished <= .deadline')" = true ] && pass "publication finished inside the reserve" || fail "published after the deadline"
uora_run blocking ctx nav home find upload attached=PENDING '{"skew":100}' '{"hang":true}'
chk "J-attached PENDING until the cutoff, no J-send -> timeout" timeout timeout
uora_run blocking ctx nav home find upload attached send id poll dl get '{"skew":1000}' '{"hang":true}'
chk "the cutoff kills the child during J-archive after a clean SAVED -> ok" ok - "tab 101"
uora_run blocking ctx nav home find upload attached send id poll '{"download":{"badhash":true}}' get '{"skew":1000}' '{"hang":true}'
chk "SAVED + hash mismatch + cutoff -> hash-mismatch, not timeout" error hash-mismatch
uora_run blocking ctx nav home find upload attached send id poll '{"download":{"mutate":".text = \"I\""}}' get '{"skew":1000}' '{"hang":true}'
chk "SAVED + verdict floor + cutoff -> verdict-floor" error verdict-floor
uora_run blocking ctx nav home find upload attached send id poll '{"skew":1000}' '{"hang":true}'
chk "DONE, no SAVED, then the cutoff -> timeout (on its own it would be child-died)" timeout timeout

# --- the mutex wait counts once against the deadline (§2)
printf 'beef %s' "$(( $(date +%s) + 9999 ))" > "$LOCK"
( sleep 2; echo 100 > "$F/skew" ) &
uora_run blocking $UORA_HAPPY
chk "a mutex wait past the browser cutoff -> timeout, no child" timeout timeout "" 0
[ "$(uora_opens)" = 0 ] && pass "...and no reopen" || fail "reopened while queued"
printf 'beef %s' "$(( $(date +%s) + 9999 ))" > "$LOCK"
( sleep 2; echo 100 > "$F/skew" ) &
uora_run background $UORA_HAPPY
grep -q "pgrep -fl -- '-p --chrome --model sonnet'" "$OUT.dispatch.err" && pass "a waiter that gives up writes the recovery line to dispatch.err" || fail "recovery line"
grep -q 'pgrep -fl oracle' "$OUT.dispatch.err" && fail "old oracle pgrep line" || pass "...naming claude, not oracle"
rm -f "$LOCK"
if [ "$(id -u)" != 0 ]; then   # root ignores the mode bits; CI runs unprivileged
  chmod 500 "$HOME/.cache/busdriver"
  uora_run blocking $UORA_HAPPY
  chmod 700 "$HOME/.cache/busdriver"
  [ "$ST" = error ] && [ "$(uora_launches)" = 0 ] && pass "an unwritable lock dir -> error, never an unlocked run" || fail "unlocked run: $ST"
fi

# --- the reopen and the probe are bounded (§2, §3)
_UORA_RESERVE=116   # cutoff = start + 4 s
for m in blocking background; do
  printf 'hang\n' > "$F/open-mode"; uora_run "$m" $UORA_HAPPY; rm -f "$F/open-mode"
  want=timeout; [ "$m" = background ] && want=rc=124
  chk "$m: a hanging open command -> timeout 124, no child" "$want" timeout "" 0
  [ ! -e "$LOCK" ] && pass "$m: ...and the mutex was released" || fail "$m: mutex held"
done
_UORA_RESERVE=60
for m in blocking background; do
  printf 'hang\n' > "$F/help"; s=$SECONDS; uora_run "$m" $UORA_HAPPY; rm -f "$F/help"
  chk "$m: a hanging claude --help -> skipped:unavailable" skipped:unavailable claude-unavailable "" 0
  [ $((SECONDS - s)) -le 25 ] && pass "$m: ...within the 15 s probe bound" || fail "$m: probe took $((SECONDS - s))s"
done

# --- the process group (§4 "Hooks that outlive the child")
for m in blocking background; do
  uora_run "$m" ctx nav home find upload attached send id poll dl get archive close '{"linger":3}'
  want=ok; [ "$m" = background ] && want=rc=0
  chk "$m: exit 0 with a lingering descendant -> ok" "$want" - ""
  sleep 4
  [ ! -e "$F/linger" ] && pass "$m: the group KILL stopped the descendant before it wrote" || fail "$m: descendant survived"
done
[ -f "$OUT.rc" ] && pass "the publisher outlived the group KILL and wrote .rc" || fail "no .rc"
[[ $- != *m* ]] && pass "the caller's shell has monitor mode off" || fail "monitor mode on"

# --- two concurrent consults: the chrome-extension mutex orders them
uora_scenario ctx nav home find upload attached send id poll '{"sleep":3}' dl get archive close exit0
rm -f "$F/launches" "$F/overlap" "$F/skew"; rmdir "$F/active.d" 2>/dev/null
a="$(_uora_chrome_consult --prompt-file "$T/prompt.txt" --out "$T/out/ca.md" --mode background --timeout-cap-seconds 120)"
b="$(_uora_chrome_consult --prompt-file "$T/prompt.txt" --out "$T/out/cb.md" --mode background --timeout-cap-seconds 120)"
sleep 1; [ -e "$LOCK" ] && pass "the mutex key is non-empty and its lock exists during a run" || fail "no lock file"
i=0; while { [ ! -f "$T/out/ca.md.rc" ] || [ ! -f "$T/out/cb.md.rc" ]; } && [ "$i" -lt 300 ]; do sleep 0.2; i=$((i + 1)); done
[ "$a $b $(cat "$T/out/ca.md.rc") $(cat "$T/out/cb.md.rc")" = "dispatched dispatched 0 0" ] && pass "both consults ok" || fail "concurrent: $a $b"
[ ! -e "$F/overlap" ] && [ "$(uora_launches)" = 2 ] && pass "the children never overlapped" || fail "overlap: $(cat "$F/overlap" 2>/dev/null)"

# --- the start-of-consult sweep (§2)
old="$HOME/.cache/busdriver/ultra-oracle/run-0123456789abcdef"; mkdir -p "$old"; touch -t 202001010000 "$old"
cr="$HOME/Downloads/uora-0123456789abcdef.json.crdownload"; : > "$cr"; touch -t 202001010000 "$cr"
fresh="$HOME/Downloads/uora-fedcba9876543210.json.crdownload"; : > "$fresh"
uora_run blocking $UORA_HAPPY
[ ! -e "$old" ] && [ ! -e "$cr" ] && [ -e "$fresh" ] \
  && pass "the sweep removed the old run dir and the interrupted .crdownload, and kept a fresh one" || fail "sweep"

[ "$FAIL" = 0 ] && echo "PASS test-ultra-oracle-chrome-timing" || exit 1
