#!/usr/bin/env bash
# tests/test-codex-nudge-if-expected.sh
#
# Verifies scripts/codex-nudge-if-expected.sh — the opt-in POLICY wrapper (ADR 0013
# / issue #298) that nudges a `none` (never-engaged) Codex with one `@codex review`
# ONLY when the per-repo opt-in `<main-root>/.claude/pr-grind-codex-expected.local`
# is present, delegating the actual one-shot post to codex-retrigger.sh.
#
# `gh` is stubbed on PATH (records `pr comment` invocations); the main-repo root is
# pinned via BUSDRIVER_MAIN_ROOT (no real git needed) and codex-retrigger's marker
# is redirected via BUSDRIVER_STATE_DIR so the real repo is never touched. We assert
# the OBSERVABLE contract: a nudge is delegated IFF the opt-in file exists, the
# one-shot marker is respected through the wrapper, and no path ever stales the gate.

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

# A fake `gh`: logs argv to $GH_CALLLOG, the --body to $GH_BODYFILE, and fails on a
# `pr comment` when STUB_GH_FAIL=1. (Same shape as tests/test-codex-retrigger.sh.)
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
  exit 0
fi
exit 0
STUB
  chmod +x "$bindir/gh"
}

PR=298
HEAD=11abbbdfdeadbeef
HEAD8=${HEAD:0:8}
MARKER_NAME=".pr-grind-codex-retriggered-pr${PR}-${HEAD8}.local"

# Fresh sandbox per case: a main-repo root (holds .claude/ for the opt-in AND, via
# BUSDRIVER_STATE_DIR, the codex-retrigger marker) plus a bindir with the gh stub.
# Echoes "root bindir calllog bodyfile" on one line.
setup_case() {
  local root bin
  root=$(mk); bin=$(mk); make_gh_stub "$bin"
  mkdir -p "$root/.claude"
  printf '%s %s %s %s' "$root" "$bin" "$root/calls.log" "$root/body.log"
}
opt_in() { : > "$1/.claude/pr-grind-codex-expected.local"; }
posts_in() { [ -f "$1" ] && grep -c 'pr comment' "$1" 2>/dev/null || echo 0; }
run_nudge() { # ROOT BIN CALLLOG BODYFILE [extra env=val ...]
  local root="$1" bin="$2" calllog="$3" bodyfile="$4"; shift 4
  env PATH="$bin:$PATH" GH_CALLLOG="$calllog" GH_BODYFILE="$bodyfile" \
      BUSDRIVER_MAIN_ROOT="$root" BUSDRIVER_STATE_DIR="$root/.claude" "$@" \
      "$BASH_BIN" "$NW" "$PR" "$HEAD"
}

# ============================================================
# 1. NOT OPTED IN — no opt-in file: no delegation, no post, no marker, exit 0.
#    This is the critical guardrail — a `none` Codex must stay non-gating by default.
# ============================================================
read -r ROOT BIN CALLLOG BODYFILE <<<"$(setup_case)"
rc=0; run_nudge "$ROOT" "$BIN" "$CALLLOG" "$BODYFILE" || rc=$?
if [ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 0 ] && [ ! -e "$ROOT/.claude/$MARKER_NAME" ]; then
  ok "not opted in: no nudge, no post, no marker (exit 0)"
else
  fail "not opted in: rc=$rc posts=$(posts_in "$CALLLOG") marker=$([ -e "$ROOT/.claude/$MARKER_NAME" ] && echo yes || echo no)"
fi

# ============================================================
# 2. OPTED IN — opt-in present: delegates → exactly one `@codex review`, marker
#    written, exit 0.
# ============================================================
read -r ROOT BIN CALLLOG BODYFILE <<<"$(setup_case)"; opt_in "$ROOT"
rc=0; run_nudge "$ROOT" "$BIN" "$CALLLOG" "$BODYFILE" || rc=$?
if [ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 1 ] && [ -e "$ROOT/.claude/$MARKER_NAME" ] \
   && [ "$(cat "$BODYFILE" 2>/dev/null)" = "@codex review" ]; then
  ok "opted in: one '@codex review' delegated + posted, marker written (exit 0)"
else
  fail "opted in: rc=$rc posts=$(posts_in "$CALLLOG") marker=$([ -e "$ROOT/.claude/$MARKER_NAME" ] && echo yes || echo no) body='$(cat "$BODYFILE" 2>/dev/null)'"
fi

# ============================================================
# 3. ONE-SHOT THROUGH WRAPPER — opt-in present but marker already claimed for this
#    (PR,HEAD): delegate is a no-op (shared marker → at most one nudge per HEAD).
# ============================================================
read -r ROOT BIN CALLLOG BODYFILE <<<"$(setup_case)"; opt_in "$ROOT"
: > "$ROOT/.claude/$MARKER_NAME"     # pre-existing marker (e.g. stale path already nudged)
rc=0; run_nudge "$ROOT" "$BIN" "$CALLLOG" "$BODYFILE" || rc=$?
if [ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 0 ]; then
  ok "one-shot: opt-in + marker present → no second post (exit 0)"
else
  fail "one-shot: expected no post, rc=$rc posts=$(posts_in "$CALLLOG")"
fi

# ============================================================
# 4. OPT-OUT PASSES THROUGH — opt-in present but PR_GRIND_CODEX_RETRIGGER=0: the
#    wrapper delegates, codex-retrigger honors the global opt-out → no post. Proves
#    delegation reached the mechanism and the kill switch still wins.
# ============================================================
read -r ROOT BIN CALLLOG BODYFILE <<<"$(setup_case)"; opt_in "$ROOT"
rc=0
run_nudge "$ROOT" "$BIN" "$CALLLOG" "$BODYFILE" PR_GRIND_CODEX_RETRIGGER=0 || rc=$?
if [ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 0 ] && [ ! -e "$ROOT/.claude/$MARKER_NAME" ]; then
  ok "opt-out: PR_GRIND_CODEX_RETRIGGER=0 through wrapper → no post, no marker (exit 0)"
else
  fail "opt-out: rc=$rc posts=$(posts_in "$CALLLOG") marker=$([ -e "$ROOT/.claude/$MARKER_NAME" ] && echo yes || echo no)"
fi

# ============================================================
# 5. FAIL-SAFE — opt-in present, gh post fails: exit 0 (never stale gate), marker
#    NOT written (retry next round), one post attempted.
# ============================================================
read -r ROOT BIN CALLLOG BODYFILE <<<"$(setup_case)"; opt_in "$ROOT"
rc=0
run_nudge "$ROOT" "$BIN" "$CALLLOG" "$BODYFILE" STUB_GH_FAIL=1 || rc=$?
if [ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 1 ] && [ ! -e "$ROOT/.claude/$MARKER_NAME" ]; then
  ok "fail-safe: post failed → exit 0, marker NOT written (retry next round)"
else
  fail "fail-safe: rc=$rc posts=$(posts_in "$CALLLOG") marker=$([ -e "$ROOT/.claude/$MARKER_NAME" ] && echo yes || echo no)"
fi

# ============================================================
# 5b. UNRESOLVABLE MAIN ROOT (fail-safe) — no BUSDRIVER_MAIN_ROOT override and CWD
#    is outside any git repo, so the main-repo root can't be resolved. We MUST NOT
#    fall back to a CWD-relative opt-in lookup (which could nudge a non-consenting
#    repo): even with an opt-in file sitting in the CWD, no post happens, exit 0.
# ============================================================
read -r ROOT BIN CALLLOG BODYFILE <<<"$(setup_case)"
NONGIT=$(mk); mkdir -p "$NONGIT/.claude"; : > "$NONGIT/.claude/pr-grind-codex-expected.local"
rc=0
( cd "$NONGIT" && env PATH="$BIN:$PATH" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" \
      BUSDRIVER_STATE_DIR="$NONGIT/.claude" "$BASH_BIN" "$NW" "$PR" "$HEAD" ) || rc=$?
if [ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 0 ] && [ ! -e "$NONGIT/.claude/$MARKER_NAME" ]; then
  ok "unresolvable root: no CWD-relative fallback → no post (fail-safe, exit 0)"
else
  fail "unresolvable root: rc=$rc posts=$(posts_in "$CALLLOG") marker=$([ -e "$NONGIT/.claude/$MARKER_NAME" ] && echo yes || echo no)"
fi

# ============================================================
# 6. USAGE ERROR — missing required args: exit 2, no post (a wiring bug, surfaced).
# ============================================================
read -r ROOT BIN CALLLOG BODYFILE <<<"$(setup_case)"; opt_in "$ROOT"
rc=0
env PATH="$BIN:$PATH" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" \
    BUSDRIVER_MAIN_ROOT="$ROOT" BUSDRIVER_STATE_DIR="$ROOT/.claude" \
    "$BASH_BIN" "$NW" || rc=$?
if [ "$rc" = 2 ] && [ "$(posts_in "$CALLLOG")" = 0 ]; then
  ok "usage error: missing args → exit 2, no post"
else
  fail "usage error: expected exit 2, got rc=$rc posts=$(posts_in "$CALLLOG")"
fi

echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
