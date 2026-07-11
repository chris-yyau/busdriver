#!/usr/bin/env bash
# tests/test-pr-grind-codex-wiring.sh — static drift/wiring guard for the Codex
# auto-detect + GC restructure in skills/pr-grind/SKILL.md (ADR 0013 rev, #320/#327).
#
# CEILING (named honestly): golden-grep proves WIRING and ordering, not runtime
# behavior (syntax / branch nesting / var scope). The behavioral weight is carried
# by the three mechanism scripts' unit tests (test-codex-active-repo.sh,
# test-codex-retrigger-gc.sh, test-codex-nudge-if-expected.sh) plus the existing
# pr-grind integration. This test exists to catch the specific regressions the
# blueprint review flagged: swallowed stderr, bare script paths, mis-anchored GC,
# the two distant merge blocks drifting, and the default block's <PR_NUMBER> token.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$SCRIPT_DIR/skills/pr-grind/SKILL.md"

passed=0; failed=0
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
has()  { grep -qF "$1" "$SKILL"; }        # fixed-string presence
hasre(){ grep -qE "$1" "$SKILL"; }        # regex presence

[ -f "$SKILL" ] || { fail "missing $SKILL"; echo "Results: $passed passed, $failed failed"; exit 1; }

# (a) CODEX_REGRACE initialized to CODEX_DONE (decouples warning from grace>0)
has 'CODEX_REGRACE="$CODEX_DONE"' && ok "CODEX_REGRACE init present" \
  || fail "missing CODEX_REGRACE=\"\$CODEX_DONE\" init"

# (b) grace guard keeps the `2>/dev/null` fail-soft redirect
has '[ "${CODEX_GRACE}" -gt 0 ] 2>/dev/null' && ok "grace guard retains 2>/dev/null" \
  || fail "grace guard dropped 2>/dev/null"

# (c) detector call discards STDOUT ONLY (stderr diagnostic must survive)
has 'scripts/codex-active-repo.sh" "$OWNER/$REPO" >/dev/null' \
  && ok "detector call redirects stdout only" \
  || fail "detector call missing / not stdout-only"
if grep -qE 'codex-active-repo\.sh" "\$OWNER/\$REPO" >/dev/null 2>&1' "$SKILL"; then
  fail "detector call swallows stderr (>/dev/null 2>&1) — diagnostic lost"
else
  ok "detector call does NOT swallow stderr"
fi

# (d) both scripts invoked via ${CLAUDE_PLUGIN_ROOT}/scripts/ — reject bare names
has '${CLAUDE_PLUGIN_ROOT}/scripts/codex-active-repo.sh' && ok "detector uses plugin-root path" \
  || fail "detector not invoked via \${CLAUDE_PLUGIN_ROOT}/scripts/"
has '${CLAUDE_PLUGIN_ROOT}/scripts/codex-nudge-if-expected.sh' && ok "nudge uses plugin-root path" \
  || fail "nudge not invoked via \${CLAUDE_PLUGIN_ROOT}/scripts/"
if grep -qE 'bash "?codex-(active-repo|nudge-if-expected|retrigger-gc)\.sh' "$SKILL"; then
  fail "a Codex script is invoked by BARE name (PATH not guaranteed)"
else
  ok "no bare-name Codex script invocations"
fi

# (e) nudge passes the active bit POSITIONALLY (arg after $OWNER/$REPO), not env
has 'codex-nudge-if-expected.sh" "$PR" "$HEAD_FULL_SHA" "$OWNER/$REPO" "$CODEX_REPO_ACTIVE"' \
  && ok "nudge receives \$CODEX_REPO_ACTIVE positionally" \
  || fail "nudge missing positional \$CODEX_REPO_ACTIVE arg"
if grep -qE 'CODEX_REPO_ACTIVE=.*bash "\$\{CLAUDE_PLUGIN_ROOT\}/scripts/codex-nudge' "$SKILL"; then
  fail "active bit passed as ENV to the nudge (injectable — see #325)"
else
  ok "active bit not passed as env to the nudge"
fi

# (f) warning gated on CODEX_REPO_ACTIVE==1 AND the kill switch; copy says "engaged"
has '[ "$CODEX_REGRACE" = "none" ] && [ "$CODEX_REPO_ACTIVE" = "1" ]' \
  && ok "warning gated on none + CODEX_REPO_ACTIVE=1" \
  || fail "warning gate condition missing/changed"
has '[ "${PR_GRIND_CODEX_RETRIGGER:-1}" != "0" ]' \
  && ok "kill-switch guard present on detection" \
  || fail "kill-switch guard missing"
has 'has engaged on recent PRs of this repo' && ok 'warning copy says "engaged" (not "reviewed")' \
  || fail "warning copy missing / not engagement-accurate"

# (g) GC wired into BOTH merge blocks after a MERGED guard; correct PR token per block
GC_COUNT=$(grep -c 'codex-retrigger-gc.sh' "$SKILL" || true)
[ "$GC_COUNT" -eq 2 ] && ok "codex-retrigger-gc.sh wired exactly twice" \
  || fail "expected 2 gc call sites, found $GC_COUNT"
has 'codex-retrigger-gc.sh" "$PR"' && ok "auto-admin block GC uses \$PR" \
  || fail "auto-admin GC not using \$PR"
has 'codex-retrigger-gc.sh" "<PR_NUMBER>"' && ok "default block GC uses <PR_NUMBER> template literal" \
  || fail "default GC not using <PR_NUMBER>"
# ordering: every gc call must be preceded by a MERGE_STATE==MERGED guard
ORDER_OK=$(awk '
  /MERGE_STATE" != "MERGED"/ { seen=1 }
  /codex-retrigger-gc\.sh/   { if (!seen) { print "BAD"; exit } }
  END { print "OK" }' "$SKILL")
[ "$ORDER_OK" = "OK" ] && ok "each GC call follows a MERGE_STATE==MERGED guard" \
  || fail "a GC call precedes its MERGED guard"

echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
