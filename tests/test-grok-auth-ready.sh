#!/usr/bin/env bash
# test-grok-auth-ready.sh — #882: grok's login must outlive the dispatch, or the
# dispatch refuses up front instead of stalling on 401s until its timeout.
#
# The busdriver-review sandbox denies ~/.grok, so grok cannot renew an expired
# token inside it. grok-auth-ready.sh checks expires_at outside the sandbox and,
# when it has already expired, lets an unsandboxed `grok models` renew it. Driven
# here against a fixture home and a fake grok, so no real login is touched.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CHILD="$ROOT/scripts/lib/grok-auth-ready.sh"
LIB="$ROOT/scripts/lib/resolve-cli.sh"
FAILED=0
pass() { printf 'ok   — %s\n' "$1"; }
fail() { printf 'FAIL — %s\n' "$1"; FAILED=1; }

FX="$(mktemp -d)"
trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/home/.grok" "$FX/bin"
# The fake grok records how it was run and, when $FX/renews exists, plays a
# successful renewal by rewriting auth.json with that expiry.
cat > "$FX/bin/grok" <<'EOF'
#!/bin/bash
printf '%s|%s\n' "$*" "$(pwd -P)" >> "$HOME/../calls"
printf '%s\n' "$$" > "$HOME/../pid"
# $FX/hang plays a renewal that hangs and ignores the polite signals.
if [[ -f "$HOME/../hang" ]]; then trap '' TERM ALRM INT HUP; sleep 30; fi
[[ -f "$HOME/../renews" ]] && printf '{"s::1":{"key":"FIXTURE-KEY","expires_at":"%s.5Z"}}' "$(cat "$HOME/../renews")" > "$HOME/.grok/auth.json"
exit 0
EOF
chmod +x "$FX/bin/grok"

iso() { /usr/bin/perl -MPOSIX -e 'print strftime("%Y-%m-%dT%H:%M:%S", gmtime($ARGV[0]))' "$1"; }
now="$(date +%s)"
auth_expiring_at() {
  printf '{"https://auth.x.ai::k":{"key":"FIXTURE-KEY","refresh_token":"FIXTURE-SECRET","expires_at":"%s.123456Z"}}' "$(iso "$1")" > "$FX/home/.grok/auth.json"
}
run() { /usr/bin/env -i /bin/bash -p "$CHILD" "$FX/home" "$FX/bin:/usr/bin:/bin" "$1"; }
calls() { [[ -f "$FX/calls" ]] && wc -l < "$FX/calls" | tr -d ' ' || echo 0; }

auth_expiring_at $((now + 21600))
out="$(run 1200)"
[[ "$out" == OK && "$(calls)" == 0 ]] && pass "a token valid past the budget passes without running grok" || fail "ample token — got '$out', grok calls $(calls)"

auth_expiring_at $((now + 600))
out="$(run 1200)"
[[ "$out" == WHY=auth-expiring && "$(calls)" == 0 ]] && pass "a token expiring inside the budget refuses up front" || fail "expiring token — got '$out', grok calls $(calls)"

auth_expiring_at $((now + 1200 + 30))
out="$(run 1200)"
[[ "$out" == WHY=auth-expiring ]] && pass "the 60s margin applies past the budget" || fail "margin — got '$out'"

auth_expiring_at $((now - 60))
out="$(run 1200)"
[[ "$out" == WHY=auth && "$(calls)" == 1 ]] && pass "an expired token that grok cannot renew refuses after one renewal attempt" || fail "unrenewable — got '$out', grok calls $(calls)"

iso $((now + 21600)) > "$FX/renews"
auth_expiring_at $((now - 60))
out="$(run 1200)"
[[ "$out" == OK ]] && pass "an expired token renewed by 'grok models' passes" || fail "renewable — got '$out'"
last="$(tail -n 1 "$FX/calls")"
[[ "${last%%|*}" == models ]] && pass "renewal runs plain 'grok models': no prompt, no --sandbox" || fail "renewal argv was '${last%%|*}'"
cwd="${last#*|}"
[[ "$cwd" != "$ROOT"* && "$cwd" != "$FX"* && "$cwd" != "$(pwd -P)" ]] && pass "renewal runs from a scratch directory, not the checkout" || fail "renewal cwd was $cwd"
rm -f "$FX/renews"

rm -f "$FX/home/.grok/auth.json"
out="$(run 1200)"
[[ "$out" == WHY=auth ]] && pass "a missing auth.json refuses" || fail "missing — got '$out'"

printf '{"s::1":{"expires_at":1790000000}}' > "$FX/home/.grok/auth.json"
out="$(run 1200)"
[[ "$out" == WHY=auth ]] && pass "an expires_at of an unknown shape refuses" || fail "garbled — got '$out'"

printf '{"a::1":{"key":"K","expires_at":"%s.1Z"},"b::2":{"key":"K","expires_at":"%s.1Z"}}' "$(iso $((now + 21600)))" "$(iso $((now + 300)))" > "$FX/home/.grok/auth.json"
out="$(run 1200)"
[[ "$out" == WHY=auth-expiring ]] && pass "with several scopes the earliest expiry decides" || fail "multi-scope — got '$out'"

printf '{"s::1":{"expires_at":"%s.1Z"}}' "$(iso $((now + 21600)))" > "$FX/home/.grok/auth.json"
out="$(run 1200)"
[[ "$out" == WHY=auth ]] && pass "a future expiry with no key refuses" || fail "keyless — got '$out'"

printf '{"a::1":{"key":"K","expires_at":"%s.1Z"},"b::2":{"key":"K"}}' "$(iso $((now + 21600)))" > "$FX/home/.grok/auth.json"
out="$(run 1200)"
[[ "$out" == WHY=auth ]] && pass "a scope entry with no expires_at refuses instead of being skipped" || fail "expiry-less scope — got '$out'"

auth_expiring_at $((now + 21600))
out="$(run abc)"
[[ "$out" == WHY=auth ]] && pass "a non-numeric budget refuses" || fail "bad budget — got '$out'"

printf '{"s::1":{"expires_at":"2099-01-01T00:00:00Z"' > "$FX/home/.grok/auth.json"
out="$(run 1200)"
[[ "$out" == WHY=auth ]] && pass "a truncated auth.json refuses even with a future-looking expiry" || fail "truncated — got '$out'"

printf '{"s::1":{"expires_at":"2099-99-99T99:99:99Z"}}' > "$FX/home/.grok/auth.json"
out="$(run 1200)"
[[ "$out" == WHY=auth ]] && pass "an impossible date refuses" || fail "impossible date — got '$out'"

printf '{"s::1":{"expires_at":"0040-01-01T00:00:00Z"}}' > "$FX/home/.grok/auth.json"
out="$(run 1200)"
[[ "$out" == WHY=auth ]] && pass "a year-0040 expiry is not read as 2040" || fail "year 0040 — got '$out'"

# A renewal that ignores SIGTERM/SIGALRM is still killed at the cap: budget 2
# makes the cap 2s, against a fake grok that would sleep for 30.
touch "$FX/hang"
auth_expiring_at $((now - 60))
t0="$(date +%s)"
out="$(run 2)"
t1="$(date +%s)"
rm -f "$FX/hang"
[[ "$out" == WHY=auth && $((t1 - t0)) -lt 10 ]] && pass "a hung renewal is killed at its cap" || fail "hung renewal — got '$out' after $((t1 - t0))s"

# Is any member of process group $1 still running? A zombie is gone (its
# reparented exit may not be reaped yet); if ps cannot run, answer "alive" so
# the check fails rather than passing on no evidence.
group_live() {
  local s
  s="$(ps -A -o pgid=,stat= 2>/dev/null)" || return 0
  awk -v g="$1" '$1 == g && $2 !~ /^Z/ { f = 1 } END { exit !f }' <<<"$s"
}

# Cancelling the supervisor mid-renewal takes the renewal's process group with
# it: grok runs in its own group, so the dispatch's TERM never reaches it.
touch "$FX/hang"; rm -f "$FX/pid"
auth_expiring_at $((now - 60))
run 20 >/dev/null 2>&1 &
bg=$!
for _ in $(seq 50); do [[ -s "$FX/pid" ]] && break; sleep 0.1; done
gpid="$(cat "$FX/pid" 2>/dev/null)"
sup="$(ps -o ppid= -p "${gpid:-0}" 2>/dev/null | tr -d ' ')"
[[ -n "$sup" ]] && kill -TERM "$sup"
for _ in $(seq 50); do [[ -n "$gpid" ]] && group_live "$gpid" || break; sleep 0.1; done
if [[ -n "$gpid" ]] && ! group_live "$gpid"; then pass "a cancelled renewal does not outlive its supervisor"
else
  fail "cancelled renewal still running (grok pid '${gpid}', supervisor '${sup}')"
  # Never `-0`: with no pid that would signal this test's own process group.
  [[ -n "$gpid" ]] && kill -KILL -- "-$gpid" 2>/dev/null
fi
wait "$bg" 2>/dev/null
rm -f "$FX/hang"

# A leading zero must not turn the budget octal (01200 would be 640s).
auth_expiring_at $((now + 1000))
out="$(run 01200)"
[[ "$out" == WHY=auth-expiring ]] && pass "a zero-padded budget is read as decimal" || fail "zero-padded budget — got '$out'"
out="$(run 09)"
[[ "$out" == OK ]] && pass "a budget of 09 is not an arithmetic error" || fail "budget 09 — got '$out'"
# The parent accepts any number of leading zeros, so the child must too.
out="$(run 0000000001)"
[[ "$out" == OK ]] && pass "a ten-digit zero-padded budget is accepted" || fail "budget 0000000001 — got '$out'"

all="$(cd "$FX" && for b in 1200 abc; do run "$b"; done; rm -f home/.grok/auth.json; run 1200)"
[[ "$all" != *FIXTURE-SECRET* && "$all" != *FIXTURE-KEY* ]] && pass "nothing read from auth.json is printed" || fail "auth.json content leaked into the output"

# The parent: it hands the child the preflight's verified home and PATH, and a
# refusal reaches the hint as its own reason rather than the profile message.
auth_expiring_at $((now + 600))
(
  # shellcheck source=/dev/null
  source "$LIB" 2>/dev/null
  _GROK_TRUSTED_HOME="$FX/home"; _GROK_PINNED_PATH="$FX/bin:/usr/bin:/bin"
  if grok_auth_ready 1200; then echo "unexpected pass"; fi
  echo "WHY=$_GROK_PREFLIGHT_WHY"
  grok_preflight_hint
  auth_expiring_at $((now + 21600))
  grok_auth_ready 1200 && echo "PASSED"
  grok_auth_ready 0000000001 && echo "PASSED-PADDED"
  _GROK_PREFLIGHT_WHY=auth; grok_preflight_hint
  grok_auth_ready 12x || echo "WHY=$_GROK_PREFLIGHT_WHY"
  grok_preflight_hint
) > "$FX/parent" 2>&1
grep -qx 'WHY=auth-expiring' "$FX/parent" && pass "grok_auth_ready publishes the child's reason" || fail "parent reason: $(cat "$FX/parent")"
grep -q 'expires before' "$FX/parent" && pass "the auth-expiring hint explains the mid-run expiry" || fail "auth-expiring hint missing"
grep -q "grok login" "$FX/parent" && pass "the auth hint tells the operator to log in" || fail "auth hint missing"
grep -qx 'WHY=duration' "$FX/parent" && grep -q 'review duration' "$FX/parent" && pass "a malformed duration is reported as a duration error, not a login" || fail "bad duration reason: $(cat "$FX/parent")"
grep -qx PASSED-PADDED "$FX/parent" && pass "a zero-padded duration the parent accepts is not reported as a login problem" || fail "parent refused 0000000001: $(cat "$FX/parent")"
grep -qx PASSED "$FX/parent" && pass "grok_auth_ready passes a token valid past the budget" || fail "parent did not pass an ample token"
grep -q 'docs/examples/grok-sandbox.toml' "$FX/parent" && fail "an auth refusal sends the operator to the profile example" || pass "auth refusals do not reuse the profile message"

exit "$FAILED"
