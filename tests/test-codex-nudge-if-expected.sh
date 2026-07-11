#!/usr/bin/env bash
# tests/test-codex-nudge-if-expected.sh
#
# Verifies scripts/codex-nudge-if-expected.sh — the POLICY wrapper (ADR 0013 as
# revised, #320) that nudges a `none` (never-engaged) Codex with one `@codex
# review` when EITHER a force-on opt-in file is present OR the repo is Codex-active
# (active-bit positional arg, or self-detected via codex-active-repo.sh),
# delegating the actual one-shot post to codex-retrigger.sh.
#
# `gh` is stubbed on PATH (records `pr comment` argv/body; on `api graphql` returns
# $GH_FIXTURE so the wrapper's self-detect path is deterministic). The main-repo
# root is pinned via BUSDRIVER_MAIN_ROOT and codex-retrigger's marker via
# BUSDRIVER_STATE_DIR. We assert the OBSERVABLE contract across the trigger matrix.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NW="$SCRIPT_DIR/scripts/codex-nudge-if-expected.sh"
BASH_BIN="$(command -v bash)"

passed=0; failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

[ -f "$NW" ] || { fail "missing $NW"; echo "Results: $passed passed, $failed failed"; exit 1; }

TMP_DIRS=()
cleanup() { local d; for d in "${TMP_DIRS[@]:-}"; do [ -n "${d:-}" ] && rm -rf "$d"; done; return 0; }
trap cleanup EXIT
mk() { local d; d=$(mktemp -d); TMP_DIRS+=("$d"); printf '%s' "$d"; }

# gh stub: logs argv; records `pr comment` --body; fails a `pr comment` if
# STUB_GH_FAIL=1; on `api graphql` returns $GH_FIXTURE (for self-detect).
make_gh_stub() {
  cat > "$1/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_CALLLOG:?}"
if [ "$1" = "pr" ] && [ "$2" = "comment" ]; then
  prev=""
  for a in "$@"; do [ "$prev" = "--body" ] && printf '%s\n' "$a" >> "${GH_BODYFILE:?}"; prev="$a"; done
  [ "${STUB_GH_FAIL:-0}" = "1" ] && exit 1
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  [ -n "${GH_FIXTURE:-}" ] && cat "$GH_FIXTURE"
  exit 0
fi
exit 0
STUB
  chmod +x "$1/gh"
}

PR=298
HEAD=11abbbdfdeadbeef
HEAD8=${HEAD:0:8}
MARKER_NAME=".pr-grind-codex-retriggered-pr${PR}-${HEAD8}.local"
ACTIVE_FIXTURE='{"data":{"repository":{"pullRequests":{"nodes":[{"reviews":{"nodes":[{"author":{"login":"chatgpt-codex-connector[bot]"}}]},"reactions":{"nodes":[]}}]}}}}'

# setup_case → "root bindir calllog bodyfile" ; fresh sandbox per case.
setup_case() {
  local root bin
  root=$(mk); bin=$(mk); make_gh_stub "$bin"
  mkdir -p "$root/.claude"
  printf '%s %s %s %s' "$root" "$bin" "$root/calls.log" "$root/body.log"
}
force_on()  { : > "$1/.claude/pr-grind-codex-expected.local"; }
posts_in()  { if [ -f "$1" ]; then grep -c 'pr comment' "$1" 2>/dev/null || true; else echo 0; fi; }

# run_nudge ROOT BIN CALLLOG BODYFILE [-- extra env=val ...] [-- args...]
# Simplerform: run_nudge_full <root> <bin> <calllog> <bodyfile> <fixture|""> <extra-env-str> <args...>
run_nudge() { # <root> <bin> <calllog> <bodyfile> <fixturefile|-> <extra-env|-> <wrapper-args...>
  local root="$1" bin="$2" calllog="$3" bodyfile="$4" fixture="$5" extra="$6"; shift 6
  local envargs=(PATH="$bin:$PATH" GH_CALLLOG="$calllog" GH_BODYFILE="$bodyfile"
                 BUSDRIVER_MAIN_ROOT="$root" BUSDRIVER_STATE_DIR="$root/.claude")
  [ "$fixture" != "-" ] && envargs+=(GH_FIXTURE="$fixture")
  [ "$extra" != "-" ] && envargs+=("$extra")
  env "${envargs[@]}" "$BASH_BIN" "$NW" "$@"
}
write_fixture() { local f; f=$(mktemp); printf '%s' "$1" > "$f"; printf '%s' "$f"; }

# ============================================================
# 1. FORCE-ON (opt-in file), no active-bit → delegates one `@codex review`.
# ============================================================
read -r ROOT BIN CALLLOG BODYFILE <<<"$(setup_case)"; force_on "$ROOT"
rc=0; run_nudge "$ROOT" "$BIN" "$CALLLOG" "$BODYFILE" - - "$PR" "$HEAD" "owner/repo" || rc=$?
if [ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 1 ] && [ -e "$ROOT/.claude/$MARKER_NAME" ] \
   && [ "$(cat "$BODYFILE" 2>/dev/null)" = "@codex review" ]; then
  ok "force-on: one '@codex review' posted, marker written (exit 0)"
else
  fail "force-on: rc=$rc posts=$(posts_in "$CALLLOG") marker=$([ -e "$ROOT/.claude/$MARKER_NAME" ] && echo yes || echo no)"
fi

# ============================================================
# 2. FORCE-ON wins even with active-bit=0 (override beats auto-detect).
# ============================================================
read -r ROOT BIN CALLLOG BODYFILE <<<"$(setup_case)"; force_on "$ROOT"
rc=0; run_nudge "$ROOT" "$BIN" "$CALLLOG" "$BODYFILE" - - "$PR" "$HEAD" "owner/repo" 0 || rc=$?
[ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 1 ] \
  && ok "force-on + active-bit=0 → still posts (override wins)" \
  || fail "force-on+bit0: rc=$rc posts=$(posts_in "$CALLLOG")"

# ============================================================
# 3. AUTO-DETECT via active-bit=1 (no opt-in) → posts.
# ============================================================
read -r ROOT BIN CALLLOG BODYFILE <<<"$(setup_case)"
rc=0; run_nudge "$ROOT" "$BIN" "$CALLLOG" "$BODYFILE" - - "$PR" "$HEAD" "owner/repo" 1 || rc=$?
[ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 1 ] && [ -e "$ROOT/.claude/$MARKER_NAME" ] \
  && ok "active-bit=1 (no opt-in) → posts" \
  || fail "bit1: rc=$rc posts=$(posts_in "$CALLLOG")"

# ============================================================
# 4. active-bit=0, no opt-in → no post (the today's-behavior guardrail).
# ============================================================
read -r ROOT BIN CALLLOG BODYFILE <<<"$(setup_case)"
rc=0; run_nudge "$ROOT" "$BIN" "$CALLLOG" "$BODYFILE" - - "$PR" "$HEAD" "owner/repo" 0 || rc=$?
[ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 0 ] && [ ! -e "$ROOT/.claude/$MARKER_NAME" ] \
  && ok "active-bit=0, no opt-in → no post (exit 0)" \
  || fail "bit0: rc=$rc posts=$(posts_in "$CALLLOG")"

# ============================================================
# 5. SELF-DETECT (no bit) with active fixture → posts.
# ============================================================
read -r ROOT BIN CALLLOG BODYFILE <<<"$(setup_case)"
FIX=$(write_fixture "$ACTIVE_FIXTURE")
rc=0; run_nudge "$ROOT" "$BIN" "$CALLLOG" "$BODYFILE" "$FIX" - "$PR" "$HEAD" "owner/repo" || rc=$?
[ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 1 ] \
  && ok "no bit + self-detect active (fixture) → posts" \
  || fail "self-detect active: rc=$rc posts=$(posts_in "$CALLLOG")"
rm -f "$FIX"

# ============================================================
# 6. SELF-DETECT (no bit) inactive (empty fixture) → no post.
# ============================================================
read -r ROOT BIN CALLLOG BODYFILE <<<"$(setup_case)"
rc=0; run_nudge "$ROOT" "$BIN" "$CALLLOG" "$BODYFILE" - - "$PR" "$HEAD" "owner/repo" || rc=$?
[ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 0 ] \
  && ok "no bit + self-detect inactive → no post (today's behavior)" \
  || fail "self-detect inactive: rc=$rc posts=$(posts_in "$CALLLOG")"

# ============================================================
# 7. active-bit=1 + PR_GRIND_CODEX_RETRIGGER=0 → kill switch wins, no post.
# ============================================================
read -r ROOT BIN CALLLOG BODYFILE <<<"$(setup_case)"
rc=0; run_nudge "$ROOT" "$BIN" "$CALLLOG" "$BODYFILE" - "PR_GRIND_CODEX_RETRIGGER=0" "$PR" "$HEAD" "owner/repo" 1 || rc=$?
[ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 0 ] && [ ! -e "$ROOT/.claude/$MARKER_NAME" ] \
  && ok "active-bit=1 + PR_GRIND_CODEX_RETRIGGER=0 → no post (kill switch)" \
  || fail "kill switch: rc=$rc posts=$(posts_in "$CALLLOG")"

# ============================================================
# 8. ONE-SHOT: active-bit=1 but marker already present → no second post.
# ============================================================
read -r ROOT BIN CALLLOG BODYFILE <<<"$(setup_case)"
: > "$ROOT/.claude/$MARKER_NAME"
rc=0; run_nudge "$ROOT" "$BIN" "$CALLLOG" "$BODYFILE" - - "$PR" "$HEAD" "owner/repo" 1 || rc=$?
[ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 0 ] \
  && ok "one-shot: marker present → no second post (exit 0)" \
  || fail "one-shot: rc=$rc posts=$(posts_in "$CALLLOG")"

# ============================================================
# 9. FAIL-SAFE: active-bit=1, gh post fails → exit 0, marker NOT written.
# ============================================================
read -r ROOT BIN CALLLOG BODYFILE <<<"$(setup_case)"
rc=0; run_nudge "$ROOT" "$BIN" "$CALLLOG" "$BODYFILE" - "STUB_GH_FAIL=1" "$PR" "$HEAD" "owner/repo" 1 || rc=$?
[ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 1 ] && [ ! -e "$ROOT/.claude/$MARKER_NAME" ] \
  && ok "fail-safe: post failed → exit 0, marker NOT written" \
  || fail "fail-safe: rc=$rc posts=$(posts_in "$CALLLOG") marker=$([ -e "$ROOT/.claude/$MARKER_NAME" ] && echo yes || echo no)"

# ============================================================
# 10. MAIN_ROOT UNRESOLVABLE but active-bit=1 → auto-detect still posts (the
#     opt-in-root early-return must NOT no-op the auto-detect path — iter3 fix).
# ============================================================
NONGIT=$(mk); mkdir -p "$NONGIT/.claude"; BIN2=$(mk); make_gh_stub "$BIN2"
rc=0
( cd "$NONGIT" && env PATH="$BIN2:$PATH" GH_CALLLOG="$NONGIT/calls.log" GH_BODYFILE="$NONGIT/body.log" \
    BUSDRIVER_STATE_DIR="$NONGIT/.claude" "$BASH_BIN" "$NW" "$PR" "$HEAD" "owner/repo" 1 ) || rc=$?
if [ "$rc" = 0 ] && [ "$(posts_in "$NONGIT/calls.log")" = 1 ]; then
  ok "MAIN_ROOT unresolvable + active-bit=1 → auto-detect still posts"
else
  fail "unresolvable root + bit1: rc=$rc posts=$(posts_in "$NONGIT/calls.log")"
fi

# ============================================================
# 11. USAGE ERROR — missing required args → exit 2, no post.
# ============================================================
read -r ROOT BIN CALLLOG BODYFILE <<<"$(setup_case)"
rc=0
env PATH="$BIN:$PATH" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" \
    BUSDRIVER_MAIN_ROOT="$ROOT" BUSDRIVER_STATE_DIR="$ROOT/.claude" \
    "$BASH_BIN" "$NW" || rc=$?
[ "$rc" = 2 ] && [ "$(posts_in "$CALLLOG")" = 0 ] \
  && ok "usage error: missing args → exit 2, no post" \
  || fail "usage error: expected exit 2, got rc=$rc"

echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
