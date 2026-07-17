#!/usr/bin/env bash
# tests/test-codex-retrigger.sh
#
# Verifies scripts/codex-retrigger.sh — the one-shot-per-(PR,HEAD) `@codex review`
# re-trigger that breaks the Codex-stale-on-unchanged-HEAD wait-round dead-end.
#
# `gh` is stubbed (a fake on PATH) that records every invocation and the --body it
# was given; the script's marker is redirected to a temp BUSDRIVER_STATE_DIR so the
# real repo is never touched. We assert the OBSERVABLE contract: when (and only
# when) a post happens, and that a failed post never writes the one-shot marker
# (so the next wait-round retries) and never returns non-zero (never stales gate).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RT="$SCRIPT_DIR/scripts/codex-retrigger.sh"
BASH_BIN="$(command -v bash)"

passed=0; failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

[ -f "$RT" ] || { fail "missing $RT"; echo "Results: $passed passed, $failed failed"; exit 1; }

TMP_DIRS=()
cleanup() { local d; for d in "${TMP_DIRS[@]:-}"; do [ -n "${d:-}" ] && rm -rf "$d"; done; return 0; }
trap cleanup EXIT
mk() { local d; d=$(mktemp -d); TMP_DIRS+=("$d"); printf '%s' "$d"; }

# A fake `gh`: logs the full argv to $GH_CALLLOG, the --body value to $GH_BODYFILE.
# STUB_GH_FAIL=1  → every `pr comment` fails (exit 1).
# STUB_GH_FAIL_ONCE=1 → only the FIRST `pr comment` fails, later ones succeed
#   (a single transient) — proves the bounded in-process retry recovers (#398).
make_gh_stub() {
  local bindir="$1"
  cat > "$bindir/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_CALLLOG:?}"
if [ "$1" = "pr" ] && [ "$2" = "comment" ]; then
  prev=""
  for a in "$@"; do
    [ "$prev" = "--body" ] && printf '%s\n' "$a" >> "${GH_BODYFILE:?}"
    prev="$a"
  done
  [ "${STUB_GH_FAIL:-0}" = "1" ] && exit 1
  # This invocation was already logged above, so on the first post the count is 1.
  if [ "${STUB_GH_FAIL_ONCE:-0}" = "1" ] \
     && [ "$(grep -c 'pr comment' "${GH_CALLLOG}" 2>/dev/null)" -le 1 ]; then
    exit 1
  fi
  exit 0
fi
exit 0
STUB
  chmod +x "$bindir/gh"
}

PR=217
HEAD=11abbbdfdeadbeef
HEAD8=${HEAD:0:8}
MARKER_NAME=".pr-grind-codex-retriggered-pr${PR}-${HEAD8}.local"

# Fresh sandbox per case: returns "statedir bindir calllog bodyfile" on one line.
setup_case() {
  local state bin
  state=$(mk); bin=$(mk); make_gh_stub "$bin"
  printf '%s %s %s %s' "$state" "$bin" "$state/calls.log" "$state/body.log"
}
posts_in() { [ -f "$1" ] && grep -c 'pr comment' "$1" 2>/dev/null || echo 0; }

# ============================================================
# 1. HAPPY PATH — marker absent, opt-in default ON: posts exactly one
#    `@codex review` and writes the one-shot marker. Exit 0.
# ============================================================
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
rc=0
( PATH="$BIN:$PATH" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" BUSDRIVER_STATE_DIR="$STATE" \
       "$BASH_BIN" "$RT" "$PR" "$HEAD" ) || rc=$?
if [ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 1 ] && [ -e "$STATE/$MARKER_NAME" ] \
   && [ "$(cat "$BODYFILE" 2>/dev/null)" = "@codex review" ]; then
  ok "happy path: one '@codex review' posted, marker written, exit 0"
else
  fail "happy path: rc=$rc posts=$(posts_in "$CALLLOG") marker=$([ -e "$STATE/$MARKER_NAME" ] && echo yes || echo no) body='$(cat "$BODYFILE" 2>/dev/null)'"
fi

# ============================================================
# 2. ONE-SHOT — marker already present for this (PR,HEAD): no post, exit 0.
# ============================================================
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
: > "$STATE/$MARKER_NAME"          # pre-existing marker
rc=0
( PATH="$BIN:$PATH" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" BUSDRIVER_STATE_DIR="$STATE" \
       "$BASH_BIN" "$RT" "$PR" "$HEAD" ) || rc=$?
if [ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 0 ]; then
  ok "one-shot: marker present → no second post (exit 0)"
else
  fail "one-shot: expected no post, rc=$rc posts=$(posts_in "$CALLLOG")"
fi

# ============================================================
# 3. OPT-OUT — PR_GRIND_CODEX_RETRIGGER=0: no post, no marker, exit 0.
# ============================================================
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
rc=0
( PATH="$BIN:$PATH" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" BUSDRIVER_STATE_DIR="$STATE" \
       PR_GRIND_CODEX_RETRIGGER=0 "$BASH_BIN" "$RT" "$PR" "$HEAD" ) || rc=$?
if [ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 0 ] && [ ! -e "$STATE/$MARKER_NAME" ]; then
  ok "opt-out (PR_GRIND_CODEX_RETRIGGER=0): no-op, no marker (exit 0)"
else
  fail "opt-out: rc=$rc posts=$(posts_in "$CALLLOG") marker=$([ -e "$STATE/$MARKER_NAME" ] && echo yes || echo no)"
fi

# ============================================================
# 4. FAIL-SAFE — gh post fails on BOTH bounded attempts: exit 0 (never stale gate)
#    AND marker NOT written (so the next wait-round retries). The retry (#398) makes
#    this 2 attempts, not 1.
# ============================================================
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
rc=0
( PATH="$BIN:$PATH" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" BUSDRIVER_STATE_DIR="$STATE" \
       STUB_GH_FAIL=1 "$BASH_BIN" "$RT" "$PR" "$HEAD" ) || rc=$?
if [ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 2 ] && [ ! -e "$STATE/$MARKER_NAME" ]; then
  ok "fail-safe: post failed both attempts → exit 0, marker NOT written (retry next round)"
else
  fail "fail-safe: rc=$rc posts=$(posts_in "$CALLLOG") (expected 2) marker=$([ -e "$STATE/$MARKER_NAME" ] && echo yes || echo no)"
fi

# ============================================================
# 4b. TRANSIENT RECOVERY (#398) — first post fails, the bounded retry succeeds: the
#     nudge IS delivered → marker written, exit 0. Without the retry the single
#     transient would release the claim and drop the nudge with no next round behind it.
# ============================================================
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
rc=0
( PATH="$BIN:$PATH" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" BUSDRIVER_STATE_DIR="$STATE" \
       STUB_GH_FAIL_ONCE=1 "$BASH_BIN" "$RT" "$PR" "$HEAD" ) || rc=$?
if [ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 2 ] && [ -e "$STATE/$MARKER_NAME" ]; then
  ok "transient recovery: first post failed, retry posted → marker written (exit 0)"
else
  fail "transient recovery: rc=$rc posts=$(posts_in "$CALLLOG") marker=$([ -e "$STATE/$MARKER_NAME" ] && echo yes || echo no)"
fi

# ============================================================
# 5. CUSTOM PHRASE — PR_GRIND_CODEX_RETRIGGER_PHRASE overrides the body.
# ============================================================
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
rc=0
( PATH="$BIN:$PATH" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" BUSDRIVER_STATE_DIR="$STATE" \
       PR_GRIND_CODEX_RETRIGGER_PHRASE="@codex please re-review" "$BASH_BIN" "$RT" "$PR" "$HEAD" ) || rc=$?
if [ "$rc" = 0 ] && [ "$(cat "$BODYFILE" 2>/dev/null)" = "@codex please re-review" ]; then
  ok "custom phrase: posted body matches PR_GRIND_CODEX_RETRIGGER_PHRASE"
else
  fail "custom phrase: rc=$rc body='$(cat "$BODYFILE" 2>/dev/null)'"
fi

# ============================================================
# 6. BAD INPUT — non-hex HEAD is a benign skip: no post, no marker, exit 0.
# ============================================================
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
rc=0
( PATH="$BIN:$PATH" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" BUSDRIVER_STATE_DIR="$STATE" \
       "$BASH_BIN" "$RT" "$PR" "zzz123nothex" ) || rc=$?
if [ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 0 ]; then
  ok "bad input (non-hex HEAD): benign skip, no post (exit 0)"
else
  fail "bad input: rc=$rc posts=$(posts_in "$CALLLOG")"
fi

# ============================================================
# 7. USAGE ERROR — missing required args: exit 2, no post.
# ============================================================
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
rc=0
( PATH="$BIN:$PATH" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" BUSDRIVER_STATE_DIR="$STATE" \
       "$BASH_BIN" "$RT" ) || rc=$?
if [ "$rc" = 2 ] && [ "$(posts_in "$CALLLOG")" = 0 ]; then
  ok "usage error: missing args → exit 2, no post"
else
  fail "usage error: expected exit 2, got rc=$rc posts=$(posts_in "$CALLLOG")"
fi

# ============================================================
# 8. GH MISSING — `gh` not on PATH: safe skip, no marker, exit 0. (Run with an
#    empty PATH; the script reaches the `command -v gh` guard using only builtins.)
# ============================================================
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
rc=0
( PATH="" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" BUSDRIVER_STATE_DIR="$STATE" \
       "$BASH_BIN" "$RT" "$PR" "$HEAD" ) || rc=$?
if [ "$rc" = 0 ] && [ ! -e "$STATE/$MARKER_NAME" ]; then
  ok "gh missing: safe skip, no marker (exit 0)"
else
  fail "gh missing: rc=$rc marker=$([ -e "$STATE/$MARKER_NAME" ] && echo yes || echo no)"
fi

# ============================================================
# 9. SEQUENTIAL IDEMPOTENCY — two real invocations on the same (PR,HEAD): the
#    first posts + claims the marker, the second is a no-op. Validates the one-shot
#    guarantee end-to-end (real post, then real re-run), not just a pre-seeded marker.
# ============================================================
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
rc=0
( PATH="$BIN:$PATH" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" BUSDRIVER_STATE_DIR="$STATE" \
  "$BASH_BIN" "$RT" "$PR" "$HEAD" ) || rc=$?
( PATH="$BIN:$PATH" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" BUSDRIVER_STATE_DIR="$STATE" \
  "$BASH_BIN" "$RT" "$PR" "$HEAD" ) || rc=$?
if [ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 1 ] && [ -e "$STATE/$MARKER_NAME" ]; then
  ok "sequential idempotency: two real runs → exactly one post, marker held"
else
  fail "sequential idempotency: rc=$rc posts=$(posts_in "$CALLLOG") (expected 1)"
fi

echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
