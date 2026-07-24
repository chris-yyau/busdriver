#!/usr/bin/env bash
# tests/test-blueprint-review-claude-only-oracle-inject.sh
# Regression for #486: a #458-salvaged (rc=0) ultra-oracle advisory must NOT be
# silently dropped from the arbiter prompt on the --claude-only re-run.
#
# In --claude-only mode the Phase 1-2 dispatch (incl. ultra-oracle) is skipped, so
# ULTRA_ORACLE_ADVISORY_FILE is empty — but the finalizing re-run REBUILDS
# claude-validation-prompt.txt. Before the fix, the inject guard (needs the file var)
# was false and the WARNING fallback was gated off in claude-only, so a salvaged
# advisory on disk vanished with neither block nor banner. The fix re-points the file
# var at the deterministic RUN_ID path so inject-or-warn runs.
#
# Behavioral test: drive the real loop in --claude-only and assert on the generated
# prompt. Auto mode writes the prompt BEFORE the claude.json check, so a missing
# claude.json (script exits 1 after) does not stop the prompt from being produced.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOP="$DIR/skills/blueprint-review/scripts/run-design-review-loop.sh"
FAIL=0
HDR='OPTIONAL ULTRA-ORACLE (ChatGPT Pro) ADVISORY'
WARN='WARNING: ULTRA-ORACLE ADVISORY FAILED'

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT INT TERM
export HOME="$T/home"; mkdir -p "$HOME/.claude"
mkdir -p "$T/repo/.claude"; cd "$T/repo" || exit 1; git init -q 2>/dev/null
export BUSDRIVER_PLUGIN_ROOT="$DIR" CLAUDE_PLUGIN_ROOT="$DIR" BUSDRIVER_STATE_DIR=".claude"
# USER config enables the blueprintReview ultra-oracle surface (surface_enabled reads USER config only).
printf '{"ultraOracle":{"blueprintReview":{"enabled":true},"timeoutCapSeconds":60}}\n' > "$HOME/.claude/busdriver.json"

printf '# Plan\n\nStep 1: do a thing.\nStep 2: do another.\n' > plan.md
bash "$DIR/skills/blueprint-review/scripts/init-design-review.sh" plan.md 3 >/dev/null 2>&1

RID="tstrun486"; RD="docs/reviews/plan"; PF="$RD/claude-validation-prompt.txt"
for r in agy codex grok; do
  printf '{"status":"PASS","reviewer_id":"%s","issues":[],"metadata":{"run_id":"%s","iteration":1}}\n' "$r" "$RID" > "$RD/$r.json"
done
mkdir -p .claude/ultra-oracle
ADV=".claude/ultra-oracle/${RID}-plan-review.md"

want()    { if grep -qF "$2" "$PF"; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAIL=1; fi; }
wantnot() { if grep -qF "$2" "$PF"; then echo "  FAIL  $1"; FAIL=1; else echo "  PASS  $1"; fi; }

# (A) salvaged rc=0 advisory present -> block injected, body carried, no banner
printf '_[#458 best-effort recovery of a hung ultra-oracle consult]_\n\nADVISORY: sample finding.\n' > "$ADV"
printf '0' > "$ADV.rc"
bash "$LOOP" --claude-only --auto </dev/null >/dev/null 2>&1
want    "(A) salvaged advisory -> block header injected" "$HDR"
want    "(A) salvaged advisory -> body carried"          "ADVISORY: sample finding."
wantnot "(A) salvaged advisory -> no spurious banner"    "$WARN"

# (B) advisory file absent -> visible WARNING banner, never silence
rm -f "$ADV" "$ADV.rc"
bash "$LOOP" --claude-only --auto </dev/null >/dev/null 2>&1
want    "(B) missing advisory -> WARNING banner (not silent)" "$WARN"
wantnot "(B) missing advisory -> no block header"             "$HDR"

[[ "$FAIL" = 0 ]] && echo "PASS test-blueprint-review-claude-only-oracle-inject" || exit 1
