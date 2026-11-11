#!/bin/bash
# tests/test-ultra-oracle-fake.sh — the fake claude replays through the real guard (Task 11).
set -u
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0; pass() { echo "OK:   $1"; }; fail() { echo "FAIL: $1"; FAIL=1; }
# shellcheck source=/dev/null
. "$DIR/tests/lib/uora-test-env.sh"
uora_env; cd "$T" || exit 1
# shellcheck source=/dev/null
source "$DIR/scripts/lib/ultra-oracle.sh"
[ "$UORA_QUERY" = "$_UORA_QUERY" ] && pass "the test env's find query is the adapter's" || fail "query drift"

run="$(_uora_new_run)"; tag="${run%%$'\t'*}"; rd="${run#*$'\t'}"
printf 'prompt\n' > "$rd/uora-$tag.txt"
_uora_render_guard "$rd" "$tag" && _uora_render_settings "$rd" && _uora_render_instructions "$rd" "$tag" || fail "render"
fake() { /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin "$T/bin/claude" -p --chrome --settings "$rd/child-settings.json" x; }

uora_scenario $UORA_HAPPY
fake > "$T/s.jsonl"; rc=$?
[ "$rc" = 0 ] && pass "happy replay exits 0" || fail "happy rc $rc"
[ "$(/usr/bin/jq -s '[.[] | select(.type == "user") | .message.content[] | select(.is_error)] | length' "$T/s.jsonl")" = 0 ] \
  && pass "every call allowed by the real guard" || fail "denials: $(grep -o 'uora-guard: deny [a-z-]*' "$T/s.jsonl" | sort | uniq -c)"
grep -q "SAVED [0-9]* [0-9a-f]\{64\}" "$T/s.jsonl" && pass "@SAVED@ filled from the download" || fail "SAVED missing"
[ -f "$HOME/Downloads/uora-$tag.json" ] && pass "download dropped" || fail "no download"
/usr/bin/jq -e '.saved == true and .sent == true and .tab == 101' "$rd/guard-state.json" >/dev/null \
  && pass "the real recorder latched saved, sent and the tab" || fail "state $(cat "$rd/guard-state.json")"
[ "$(wc -l < "$rd/decisions.jsonl" | tr -dc 0-9)" = 24 ] && pass "24 log lines (12 calls, both halves)" || fail "log lines"

# a deny comes back as an is_error tool_result carrying the guard's marker
rm -rf "$rd"; run="$(_uora_new_run)"; tag="${run%%$'\t'*}"; rd="${run#*$'\t'}"; printf 'p\n' > "$rd/uora-$tag.txt"
_uora_render_guard "$rd" "$tag"; _uora_render_settings "$rd"
uora_scenario ctx nav find exit0
fake > "$T/d.jsonl"
grep -q 'uora-guard: deny not-yet' "$T/d.jsonl" && pass "find before READY: not-yet in the stream" || fail "no not-yet"

# a batch emits every tool_use before any result
uora_scenario ctx nav "{\"batch\":[$(_uora_std home),$(_uora_std find)]}" exit0
rm -rf "$rd"; run="$(_uora_new_run)"; tag="${run%%$'\t'*}"; rd="${run#*$'\t'}"; printf 'p\n' > "$rd/uora-$tag.txt"
_uora_render_guard "$rd" "$tag"; _uora_render_settings "$rd"
fake > "$T/b.jsonl"
[ "$(/usr/bin/jq -s '[.[] | select(.type == "assistant") | .message.content | length] | max' "$T/b.jsonl")" = 2 ] \
  && pass "one assistant message holds both tool_use blocks" || fail "batch shape"

# a crashed PreToolUse hook (exit 1) blocks even a pre-approved Read when the settings say
# onFailure "block", and only then
rm -rf "$rd"; run="$(_uora_new_run)"; tag="${run%%$'\t'*}"; rd="${run#*$'\t'}"; printf 'p\n' > "$rd/uora-$tag.txt"
_uora_render_guard "$rd" "$tag"; _uora_render_settings "$rd"
/usr/bin/jq '.hooks.PreToolUse[0].hooks[0] |= (.args = ["-c", "exit 1", "x"] + .args | .command = "/bin/sh")' \
  "$rd/child-settings.json" > "$T/crash.json" && mv "$T/crash.json" "$rd/child-settings.json"
uora_scenario '{"tool":"Read","input":{"file_path":"/etc/hosts"},"result":"r"}' exit0
fake > "$T/c.jsonl"
grep -q 'hook failed (exit 1)' "$T/c.jsonl" && pass "onFailure block: a crashed hook denies Read" || fail "crashed hook let Read run"
/usr/bin/jq '.hooks.PreToolUse[0].hooks[0] |= del(.onFailure)' "$rd/child-settings.json" > "$T/crash.json" \
  && mv "$T/crash.json" "$rd/child-settings.json"
fake > "$T/c2.jsonl"
grep -q 'hook failed' "$T/c2.jsonl" && fail "no onFailure still blocked" || pass "without onFailure a crashed hook does not block"

# the env -i allowlist: the fake sees only what it was given
grep -q '^CLAUDE_CODE_SAFE_MODE=' "$F/env.1" && fail "env leaked" || pass "env recorded"

[ "$FAIL" = 0 ] && echo "PASS test-ultra-oracle-fake" || exit 1
