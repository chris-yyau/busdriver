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
[[ -f "$HOME/../renews" ]] && printf '{"s::1":{"expires_at":"%s.5Z"}}' "$(cat "$HOME/../renews")" > "$HOME/.grok/auth.json"
exit 0
EOF
chmod +x "$FX/bin/grok"

iso() { /usr/bin/perl -MPOSIX -e 'print strftime("%Y-%m-%dT%H:%M:%S", gmtime($ARGV[0]))' "$1"; }
now="$(date +%s)"
auth_expiring_at() {
  printf '{"https://auth.x.ai::k":{"refresh_token":"FIXTURE-SECRET","expires_at":"%s.123456Z"}}' "$(iso "$1")" > "$FX/home/.grok/auth.json"
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

printf '{"a::1":{"expires_at":"%s.1Z"},"b::2":{"expires_at":"%s.1Z"}}' "$(iso $((now + 21600)))" "$(iso $((now + 300)))" > "$FX/home/.grok/auth.json"
out="$(run 1200)"
[[ "$out" == WHY=auth-expiring ]] && pass "with several scopes the earliest expiry decides" || fail "multi-scope — got '$out'"

auth_expiring_at $((now + 21600))
out="$(run abc)"
[[ "$out" == WHY=auth ]] && pass "a non-numeric budget refuses" || fail "bad budget — got '$out'"

# A leading zero must not turn the budget octal (01200 would be 640s).
auth_expiring_at $((now + 1000))
out="$(run 01200)"
[[ "$out" == WHY=auth-expiring ]] && pass "a zero-padded budget is read as decimal" || fail "zero-padded budget — got '$out'"
out="$(run 09)"
[[ "$out" == OK ]] && pass "a budget of 09 is not an arithmetic error" || fail "budget 09 — got '$out'"

all="$(cd "$FX" && for b in 1200 abc; do run "$b"; done; rm -f home/.grok/auth.json; run 1200)"
[[ "$all" != *FIXTURE-SECRET* ]] && pass "nothing read from auth.json is printed" || fail "auth.json content leaked into the output"

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
  _GROK_PREFLIGHT_WHY=auth; grok_preflight_hint
) > "$FX/parent" 2>&1
grep -qx 'WHY=auth-expiring' "$FX/parent" && pass "grok_auth_ready publishes the child's reason" || fail "parent reason: $(cat "$FX/parent")"
grep -q 'expires before' "$FX/parent" && pass "the auth-expiring hint explains the mid-run expiry" || fail "auth-expiring hint missing"
grep -q "grok login" "$FX/parent" && pass "the auth hint tells the operator to log in" || fail "auth hint missing"
grep -qx PASSED "$FX/parent" && pass "grok_auth_ready passes a token valid past the budget" || fail "parent did not pass an ample token"
grep -q 'docs/examples/grok-sandbox.toml' "$FX/parent" && fail "an auth refusal sends the operator to the profile example" || pass "auth refusals do not reuse the profile message"

exit "$FAILED"
