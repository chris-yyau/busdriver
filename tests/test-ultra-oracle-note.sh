#!/bin/bash
# tests/test-ultra-oracle-note.sh — spec 2026-11-01 §6/§11: an ok consult with an archive, tab-cleanup
# or legacy-keys notice prints one NOTE: line from every wrapper. Out of process, through the shims.
set -u
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0; pass() { echo "OK:   $1"; }; fail() { echo "FAIL: $1"; FAIL=1; }
# shellcheck source=/dev/null
. "$DIR/tests/lib/uora-test-env.sh"
uora_env
mkdir -p "$T/repo" && git -C "$T/repo" init -q && cd "$T/repo" || exit 1   # the resolver needs a repo without the shims
export PATH="$T/bin:$PATH"
printf '{"ultraOracle":{"council":{"enabled":true},"brainstorming":{"enabled":true}}}\n' > "$HOME/.claude/busdriver.json"
ARCHFAIL="ctx nav home find upload attached send id poll dl get archive=ERR\ archive\ 500 close exit0"

# ultra-oracle-run.sh: NOTE on stdout, after the verdict
eval "uora_scenario $ARCHFAIL"
out="$(bash "$DIR/scripts/ultra-oracle-run.sh" council 0 "$T/prompt.txt" "$T/out/w1.md")"
if [ "$(printf '%s\n' "$out" | head -1)" = VERDICT ] && [ "$(printf '%s\n' "$out" | tail -1)" = "NOTE: The consult chat could not be archived." ]; then
  pass "ultra-oracle-run.sh: NOTE after the verdict"; else fail "run.sh: $out"; fi

# ultra-oracle-consult-run.sh: the token alone on stdout, NOTE on stderr
eval "uora_scenario $ARCHFAIL"
tok="$(bash "$DIR/scripts/ultra-oracle-consult-run.sh" --surface brainstorming --mode blocking --prompt-file "$T/prompt.txt" --out "$T/out/w2.md" 2>"$T/w2.err")"
if [ "$tok" = ok ] && grep -qx "NOTE: The consult chat could not be archived." "$T/w2.err"; then
  pass "consult-run: raw token kept, NOTE on stderr"; else fail "consult-run: tok=$tok err=$(cat "$T/w2.err")"; fi

# the legacy-keys notice reaches the operator on ok too
printf '{"ultraOracle":{"brainstorming":{"enabled":true},"cookiePath":"x"}}\n' > "$HOME/.claude/busdriver.json"
# shellcheck disable=SC2086   # UORA_HAPPY is a word list
uora_scenario $UORA_HAPPY
tok="$(bash "$DIR/scripts/ultra-oracle-consult-run.sh" --surface brainstorming --mode blocking --prompt-file "$T/prompt.txt" --out "$T/out/w3.md" 2>"$T/w3.err")"
if [ "$tok" = ok ] && grep -q '^NOTE: .*cookiePath' "$T/w3.err"; then
  pass "the legacy-keys notice prints as NOTE on ok"; else fail "legacy note: tok=$tok err=$(cat "$T/w3.err")"; fi
if [ "$(grep -c '^ultra-oracle: .*cookiePath' "$T/w3.err")" = 1 ]; then
  pass "the legacy-keys notice reaches stderr once, not again at finish"; else fail "legacy notice count: $(cat "$T/w3.err")"; fi

# a tab left open on ok: tab-cleanup reaches the NOTE line
printf '{"ultraOracle":{"brainstorming":{"enabled":true}}}\n' > "$HOME/.claude/busdriver.json"
uora_scenario ctx nav home find upload attached send id poll dl get archive exit0
tok="$(bash "$DIR/scripts/ultra-oracle-consult-run.sh" --mode blocking --prompt-file "$T/prompt.txt" --out "$T/out/w4.md" 2>"$T/w4.err")"
if [ "$tok" = ok ] && grep -q '^NOTE: .*tab 101' "$T/w4.err"; then
  pass "tab-cleanup prints as NOTE on ok"; else fail "tab note: tok=$tok err=$(cat "$T/w4.err")"; fi

[ "$FAIL" = 0 ] && echo "PASS test-ultra-oracle-note" || exit 1
