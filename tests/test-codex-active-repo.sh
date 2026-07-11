#!/usr/bin/env bash
# tests/test-codex-active-repo.sh — verifies scripts/codex-active-repo.sh, the
# Codex-active auto-detect (ADR 0013 revision / issue #320).
#
# `gh` is stubbed on PATH (logs argv to $GH_CALLLOG; on `api graphql` returns the
# fixture at $GH_FIXTURE, or fails if STUB_GH_FAIL=1). `jq` is the real one. We
# assert the OBSERVABLE contract: ACTIVE iff Codex (bare OR [bot]) authored a
# review OR left a reaction across the window; fail-SAFE to inactive with a
# stderr diagnostic; the query pins states:[CLOSED,MERGED]; the window clamps to
# 1..100; and the kill switch skips the network call entirely.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DET="$SCRIPT_DIR/scripts/codex-active-repo.sh"
BASH_BIN="$(command -v bash)"

passed=0; failed=0
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }

[ -f "$DET" ] || { fail "missing $DET"; echo "Results: $passed passed, $failed failed"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"

cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_CALLLOG:?}"
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  [ "${STUB_GH_FAIL:-0}" = "1" ] && exit 1
  cat "${GH_FIXTURE:?}"
fi
exit 0
STUB
chmod +x "$BIN/gh"

fixture() { printf '{"data":{"repository":{"pullRequests":{"nodes":%s}}}}' "$1"; }
REVIEW='[{"reviews":{"nodes":[{"author":{"login":"chatgpt-codex-connector"}}]},"reactions":{"nodes":[]}}]'
REVIEW_BOT='[{"reviews":{"nodes":[{"author":{"login":"chatgpt-codex-connector[bot]"}}]},"reactions":{"nodes":[]}}]'
REACTION_BOT='[{"reviews":{"nodes":[]},"reactions":{"nodes":[{"user":{"login":"chatgpt-codex-connector[bot]"}}]}}]'
OTHERS='[{"reviews":{"nodes":[{"author":{"login":"cursor"}}]},"reactions":{"nodes":[{"user":{"login":"coderabbitai[bot]"}}]}}]'
EMPTY='[]'

# run [VAR=val ...] <repo> — sets RC; logs argv to $TMP/calls.log; stderr to $TMP/err.log
run() {
  : > "$TMP/calls.log"; : > "$TMP/err.log"
  local envs=(); while [ "$#" -gt 1 ]; do envs+=("$1"); shift; done
  RC=0
  env PATH="$BIN:$PATH" GH_CALLLOG="$TMP/calls.log" GH_FIXTURE="$TMP/fixture.json" \
      ${envs[@]+"${envs[@]}"} "$BASH_BIN" "$DET" "$1" 2>"$TMP/err.log" >/dev/null || RC=$?
}
set_fixture() { printf '%s' "$(fixture "$1")" > "$TMP/fixture.json"; }

# 1. review by codex → active
set_fixture "$REVIEW"; run owner/repo
[ "$RC" = 0 ] && ok "review author codex → active (0)" || fail "review author codex: RC=$RC"

# 2. review by codex[bot] → active (login normalization)
set_fixture "$REVIEW_BOT"; run owner/repo
[ "$RC" = 0 ] && ok "review author codex[bot] → active (0)" || fail "review [bot]: RC=$RC"

# 3. reaction-only by codex[bot], NO review → active (the clean-Codex case)
set_fixture "$REACTION_BOT"; run owner/repo
[ "$RC" = 0 ] && ok "reaction-only codex[bot] (clean-Codex) → active (0)" || fail "reaction-only: RC=$RC"

# 4. only other logins → inactive
set_fixture "$OTHERS"; run owner/repo
[ "$RC" = 1 ] && ok "non-codex reviews/reactions → inactive (1)" || fail "others: RC=$RC"

# 5. empty history → inactive (valid empty array → genuine inactive, no diagnostic)
set_fixture "$EMPTY"; run owner/repo
if [ "$RC" = 1 ] && ! grep -q "detection unavailable" "$TMP/err.log"; then
  ok "empty PR history → inactive (1), no diagnostic"
else
  fail "empty: RC=$RC err='$(cat "$TMP/err.log")'"
fi

# 5b. structurally-broken (valid JSON, data.repository null — gh exited 0) → inactive
#     WITH diagnostic, not silently treated as genuine inactivity.
printf '%s' '{"data":{"repository":null}}' > "$TMP/fixture.json"; run owner/repo
if [ "$RC" = 1 ] && grep -q "detection unavailable" "$TMP/err.log"; then
  ok "structural-null GraphQL response → inactive (1) + diagnostic (not silent)"
else
  fail "structural-null: RC=$RC err='$(cat "$TMP/err.log")'"
fi

# 5c. per-node damage: a node with a null reviews field (not an array) → diagnostic,
#     not a silent discard by the strict guard.
printf '%s' '{"data":{"repository":{"pullRequests":{"nodes":[{"reviews":null,"reactions":{"nodes":[]}}]}}}}' > "$TMP/fixture.json"
run owner/repo
if [ "$RC" = 1 ] && grep -q "detection unavailable" "$TMP/err.log"; then
  ok "per-node null reviews field → inactive (1) + diagnostic (strict guard)"
else
  fail "per-node damage: RC=$RC err='$(cat "$TMP/err.log")'"
fi

# 5d. partial response — valid connection arrays BUT a top-level GraphQL errors array
#     (gh exited 0) → inactive WITH diagnostic, not silent.
printf '%s' '{"data":{"repository":{"pullRequests":{"nodes":[]}}},"errors":[{"message":"rate limited"}]}' > "$TMP/fixture.json"
run owner/repo
if [ "$RC" = 1 ] && grep -q "detection unavailable" "$TMP/err.log"; then
  ok "top-level GraphQL errors present → inactive (1) + diagnostic"
else
  fail "errors-array: RC=$RC err='$(cat "$TMP/err.log")'"
fi

# 6. gh failure → inactive + stderr diagnostic
set_fixture "$REVIEW"; run STUB_GH_FAIL=1 owner/repo
if [ "$RC" = 1 ] && grep -q "detection unavailable" "$TMP/err.log"; then
  ok "gh query failure → inactive (1) + stderr diagnostic"
else
  fail "gh failure: RC=$RC err='$(cat "$TMP/err.log")'"
fi

# 7. bad repo (no slash) → inactive, no gh call
set_fixture "$REVIEW"; run notaslash
if [ "$RC" = 1 ] && [ ! -s "$TMP/calls.log" ]; then
  ok "bad owner/repo (no slash) → inactive, no gh call"
else
  fail "bad repo: RC=$RC calls=$(wc -l < "$TMP/calls.log")"
fi

# 8. metachar in repo → inactive, no gh call
set_fixture "$REVIEW"; run 'own;er/repo'
[ "$RC" = 1 ] && [ ! -s "$TMP/calls.log" ] && ok "metachar repo → inactive, no gh call" || fail "metachar repo: RC=$RC"

# 9. kill switch → inactive, NO gh call (no network round-trip)
set_fixture "$REVIEW"; run PR_GRIND_CODEX_RETRIGGER=0 owner/repo
if [ "$RC" = 1 ] && [ ! -s "$TMP/calls.log" ]; then
  ok "PR_GRIND_CODEX_RETRIGGER=0 → inactive, no gh call"
else
  fail "kill switch: RC=$RC calls=$(wc -l < "$TMP/calls.log")"
fi

# 10. query pins states:[CLOSED,MERGED] (the CLOSED-vs-MERGED fix)
set_fixture "$REVIEW"; run owner/repo
grep -q 'states:\[CLOSED,MERGED\]' "$TMP/calls.log" \
  && ok "query includes states:[CLOSED,MERGED]" \
  || fail "query missing states:[CLOSED,MERGED]: $(cat "$TMP/calls.log")"

# 11. window clamp: default/empty/non-numeric/<1 → 10 ; >100 → 100 ; in-range passes
check_window() { # <input-window> <expected-n>
  set_fixture "$REVIEW"
  if [ -n "$1" ]; then run "PR_GRIND_CODEX_ACTIVE_WINDOW=$1" owner/repo; else run owner/repo; fi
  if grep -q " n=$2\b" "$TMP/calls.log" || grep -q "^n=$2\b" "$TMP/calls.log" || grep -qw "n=$2" "$TMP/calls.log"; then
    ok "window '$1' → first:$2"
  else
    fail "window '$1' expected n=$2, got: $(grep -o 'n=[0-9]*' "$TMP/calls.log" | head -1)"
  fi
}
check_window ""     10
check_window "abc"  10
check_window "0"    10
check_window "001"  1
check_window "50"   50
check_window "100"  100
check_window "101"  100
check_window "1000" 100

echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
