#!/usr/bin/env bash
# tests/test-ultimate-tier.sh
# Static + behavioral contract for the "ultimate" tier (Claude Fable via the zenmux
# gateway) — ADR 0011. Locks in the PR-2 rename + the two shipping surfaces:
#   (a) NO live code references the dropped ultra-arbiter keys
#       (BLUEPRINT_ARBITER_ULTRA / ultraArbiter) — they live only in immutable history
#       (docs/adr/, CHANGELOG, SKILL.md Version History).
#   (b) the shared scripts/ultimate-dispatch.sh helper exists, is executable, and
#       FAIL-CLOSES (non-zero, no output) when gateway creds are absent.
#   (c) skills/council/SKILL.md carries the Mythos Witness contract anchors
#       (rendered-separately, never-a-vote, MYTHOS_FAILED banner).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAIL=1; }

# ── (a) dropped keys absent from LIVE code ────────────────────────────────
# Live code = the shell that actually runs. History prose (docs/adr/, CHANGELOG,
# SKILL.md Version History) legitimately keeps the old names as record and is excluded.
echo "── (a) dropped ultra-arbiter keys gone from live code ──"
LIVE_FILES=(
  "$DIR/scripts/lib/ultimate-config.sh"
  "$DIR/scripts/ultimate-dispatch.sh"
  "$DIR/scripts/lib/resolve-cli.sh"
  "$DIR/skills/blueprint-review/scripts/dispatch-gateway-arbiter.sh"
)
for f in "${LIVE_FILES[@]}"; do
  if [[ -f "$f" ]] && grep -qE 'BLUEPRINT_ARBITER_ULTRA|ultraArbiter|ultra-arbiter-config' "$f"; then
    fail "dropped key present in $(basename "$f")"
  else
    pass "no dropped keys in $(basename "$f")"
  fi
done
# blueprint-review SKILL.md BODY (everything before the Version History heading) must be clean.
SKILL_BP="$DIR/skills/blueprint-review/SKILL.md"
BODY="$(awk '/^#+[[:space:]]+Version History/{exit} {print}' "$SKILL_BP")"
if grep -qE 'BLUEPRINT_ARBITER_ULTRA|ultraArbiter|ultra_arbiter_(fable|unavailable)|ultra-arbiter' <<<"$BODY"; then
  fail "dropped ultra-arbiter key present in blueprint-review SKILL.md BODY (must be renamed)"
else
  pass "blueprint-review SKILL.md body uses the ultimate-* names"
fi

# ── (b) shared helper exists, executable, fail-closes without creds ────────
echo "── (b) scripts/ultimate-dispatch.sh helper ──"
HELPER="$DIR/scripts/ultimate-dispatch.sh"
[[ -f "$HELPER" ]] && pass "ultimate-dispatch.sh exists" || fail "ultimate-dispatch.sh missing"
[[ -x "$HELPER" ]] && pass "ultimate-dispatch.sh is executable" || fail "ultimate-dispatch.sh not executable"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PROMPT="$TMP/prompt.txt"; printf 'test prompt\n' > "$PROMPT"
OUT="$TMP/out.md"
# No gateway env at all → must fail-closed (non-zero) and write no output.
rc=0
env -i PATH="$PATH" bash "$HELPER" mythos-witness "$PROMPT" "$OUT" >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && pass "no-creds dispatch fails closed (rc=$rc, non-zero)" || fail "no-creds dispatch did not fail closed (rc=0)"
[[ ! -e "$OUT" ]] && pass "no output written when creds absent" || fail "output written despite missing creds"
# Guard against sourcing under zsh (must fail loudly, not half-load).
if command -v zsh >/dev/null 2>&1; then
  if zsh -c 'source "$0"' "$HELPER" 2>&1 | grep -qi 'requires bash'; then
    pass "sourcing under zsh fails loudly"
  else
    fail "zsh source guard did not fire"
  fi
else
  echo "  SKIP  zsh not installed"
fi

# Output-containment check: with dummy gateway creds set (credential gate is FIRST in the
# helper, so this exercises the containment logic at line ~126-137 without a real dispatch —
# the script dies before it ever calls the claude binary). Covers the PWD-fallback branch
# flagged in PR #275 review (Devin): when OUTPUT_FILE is not inside a git repo, the anchor
# falls back to $PWD, and a correctly-composed path under that fallback must be ACCEPTED
# (not incorrectly rejected), while a path outside the expected dir must still be REJECTED.
echo "── (b.1) output containment (dummy creds, no real dispatch) ──"
NOTGIT="$(mktemp -d)"; trap 'rm -rf "$TMP" "$NOTGIT"' EXIT
# Accept case: OUTPUT_FILE composed directly under the PWD-fallback anchor's expected dir.
mkdir -p "$NOTGIT/.claude/ultimate"
CONTAIN_PROMPT="$NOTGIT/prompt.txt"; printf 'test prompt\n' > "$CONTAIN_PROMPT"
CONTAIN_OUT="$NOTGIT/.claude/ultimate/out.md"
# CLAUDE_BIN pointed at a nonexistent binary so the script dies fast right AFTER the
# containment check (next gate down, line ~140) instead of proceeding to a real (and
# potentially hanging) network dispatch — no network I/O reaches this test.
rc=0
( cd "$NOTGIT" && env -i PATH="$PATH" HOME="$NOTGIT" \
    BLUEPRINT_ARBITER_GATEWAY_BASE_URL="https://example.invalid" \
    BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN="dummy" \
    ULTIMATE_COUNCIL_FORCE=1 \
    CLAUDE_BIN="/nonexistent/claude-binary-for-test" \
    bash "$HELPER" mythos-witness "$CONTAIN_PROMPT" "$CONTAIN_OUT" >"$NOTGIT/stderr.log" 2>&1 ) || rc=$?
if grep -qF "output file must live directly under" "$NOTGIT/stderr.log"; then
  fail "PWD-fallback containment incorrectly rejected a correctly-composed path"
elif grep -qF "claude binary not found" "$NOTGIT/stderr.log"; then
  pass "PWD-fallback containment accepts a correctly-composed path (fails later, on claude binary lookup, not containment)"
else
  fail "unexpected failure mode for PWD-fallback accept case: $(cat "$NOTGIT/stderr.log")"
fi
# Reject case: OUTPUT_FILE outside the expected dir must still die at the containment check.
rc=0
( cd "$NOTGIT" && env -i PATH="$PATH" HOME="$NOTGIT" \
    BLUEPRINT_ARBITER_GATEWAY_BASE_URL="https://example.invalid" \
    BLUEPRINT_ARBITER_GATEWAY_AUTH_TOKEN="dummy" \
    ULTIMATE_COUNCIL_FORCE=1 \
    CLAUDE_BIN="/nonexistent/claude-binary-for-test" \
    bash "$HELPER" mythos-witness "$CONTAIN_PROMPT" "$NOTGIT/out.md" >"$NOTGIT/stderr2.log" 2>&1 ) || rc=$?
if [[ "$rc" -ne 0 ]] && grep -qF "output file must live directly under" "$NOTGIT/stderr2.log"; then
  pass "containment rejects an output path outside the expected dir"
else
  fail "containment did not reject an out-of-bounds output path (rc=$rc)"
fi

# ── (c) Mythos Witness contract anchors in council SKILL.md ───────────────
echo "── (c) council Mythos Witness contract ──"
SKILL_C="$DIR/skills/council/SKILL.md"
anchor() { grep -qF -- "$2" "$SKILL_C" && pass "$1" || fail "$1 (missing: $2)"; }
anchor "Mythos Witness has its own Expert Witness section" '## Mythos Witness — Expert Witness'
anchor "Mythos Witness is never a vote"                    'The Mythos Witness is **not** a vote'
anchor "Mythos Witness excluded from the vote tally"       'EXCLUDED from the council vote tally'
anchor "MYTHOS_FAILED banner on failure"                   'MYTHOS_FAILED'
anchor "rendered AFTER UltraOracle, BEFORE the Verdict"    'AFTER the `## UltraOracle — Expert Witness`'
anchor "routes through the shared ultimate-dispatch helper" 'scripts/ultimate-dispatch.sh'
anchor "config gate is ultimate.surfaces.council"          'ultimate.surfaces.council'
anchor "per-run force var named + scoped"                  'ULTIMATE_COUNCIL_FORCE=1'
grep -qF 'export ULTIMATE_COUNCIL_FORCE' "$SKILL_C" && fail "force var must never be exported" \
  || pass "force var is not exported"
grep -qF 'unset ULTIMATE_COUNCIL_FORCE' "$SKILL_C" && pass "force var is unset after the block" \
  || fail "force var not unset (would leak into a later council)"

[[ "$FAIL" = 0 ]] && echo "PASS test-ultimate-tier" || { echo "FAIL test-ultimate-tier"; exit 1; }
