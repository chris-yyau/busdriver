#!/usr/bin/env bash
# Tests for the litmus PR-mode dual-voice writers + gate enforcement (ADR 0006).
#
# Covers the trusted writers in run-review-loop.sh and the matching acceptance
# logic in pre-pr-gate.sh:
#   (codex-lead artifact written inline on a real Codex PASS — no subcommand)
#   --write-backstop-verdict     → pr-backstop-verdict.local.json (strict validator)
#   --write-pr-marker            → pr-review-passed.local (requires BOTH artifacts)
#
# Matrix:
#   1. codex-lead writer emits a PASS artifact bound to the current diff
#   2. backstop writer accepts a valid empty PASS
#   3. write-pr-marker writes the marker when BOTH voices PASS
#   4. a backstop `high` issue is recomputed to FAIL even if caller said PASS
#   5. write-pr-marker refuses once the backstop is FAIL
#   6. strict validator rejects a missing confidence
#   7. strict validator rejects an out-of-enum severity (CRITICAL)
#   8. strict validator rejects a stale reviewed_diff_hash (TOCTOU)
#   9. strict validator rejects caller-supplied diff_hash/ts (unknown top-level)
#  10. writer fails closed on an empty diff (no base)
#  11. gate accepts a fresh FAST marker matching the diff
#  12. gate rejects a FAST marker whose hash != current diff
#
# Usage: bash tests/test-pr-dual-voice.sh
# Exit: 0 if all pass, 1 if any fail.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO="$(pwd)"
RL="$REPO/skills/litmus/scripts/run-review-loop.sh"
GATE="$REPO/hooks/gate-scripts/pre-pr-gate.sh"

# Pin the state dir so the test is independent of an ambient .opencode export.
export BUSDRIVER_STATE_DIR=.claude

PASS=0; FAIL=0
ok() { if [ "$1" = "$2" ]; then echo "  PASS  $3"; PASS=$((PASS+1)); else echo "  FAIL  $3 (got '$1' want '$2')"; FAIL=$((FAIL+1)); fi; }

WORK=$(mktemp -d)
cleanup() { cd /; rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT
cd "$WORK" || exit 1

git init -q -b main
git config user.email t@example.com; git config user.name Test
echo base > f.txt; git add f.txt; git commit -qm base
git update-ref refs/remotes/origin/main HEAD
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git checkout -q -b feature
printf 'line1\nline2\n' > f.txt; git add f.txt; git commit -qm change

export LITMUS_PR_BASE=main   # resolve_pr_base_branch → origin/main

# Current diff hash, computed the way the writer/gate do (capture + printf '%s').
_D=$(git diff "$(git merge-base origin/main HEAD)...HEAD")
CUR=$(printf '%s' "$_D" | (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1)

art_status() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['status'])" "$1" 2>/dev/null; }

# The Codex-lead PASS artifact is written ONLY inline on a real Codex PASS (there
# is deliberately no writer subcommand — that would let it be forged without a
# review). Seed one directly as a fixture so the marker/gate tests below have the
# lead voice present; the inline writer is covered by the live PR-mode flow.
seed_codex_lead() {
  mkdir -p .claude
  printf '{"status":"PASS","model":"codex","diff_hash":"%s","ts":%s}\n' "$CUR" "$(date +%s)" > .claude/pr-codex-lead.local.json
}

echo "== 1. codex-lead artifact fixture =="
seed_codex_lead
ok "$([ -f .claude/pr-codex-lead.local.json ] && echo y || echo n)" "y" "codex-lead artifact present"
ok "$(art_status .claude/pr-codex-lead.local.json)" "PASS" "codex-lead status=PASS"

echo "== 2. backstop writer — valid empty PASS =="
echo "{\"status\":\"PASS\",\"model\":\"opus\",\"reviewed_diff_hash\":\"$CUR\",\"issues\":[]}" | bash "$RL" --write-backstop-verdict >/dev/null 2>&1
ok "$?" "0" "valid empty PASS accepted"
ok "$(art_status .claude/pr-backstop-verdict.local.json)" "PASS" "backstop status=PASS"

echo "== 2b. backstop rejected without a fresh Codex-lead PASS (precondition) =="
mv .claude/pr-codex-lead.local.json .claude/pr-codex-lead.bak
echo "{\"status\":\"PASS\",\"model\":\"opus\",\"reviewed_diff_hash\":\"$CUR\",\"issues\":[]}" | bash "$RL" --write-backstop-verdict >/dev/null 2>&1
ok "$?" "1" "backstop-only forge blocked when codex-lead absent"
mv .claude/pr-codex-lead.bak .claude/pr-codex-lead.local.json  # restore for later tests

echo "== 3. write-pr-marker — both PASS ⇒ marker =="
bash "$RL" --write-pr-marker >/dev/null 2>&1
ok "$?" "0" "marker writer exit 0"
ok "$(cat .claude/pr-review-passed.local 2>/dev/null)" "$CUR" "marker == current diff hash"

echo "== 4. backstop high severity ⇒ recomputed FAIL =="
echo "{\"status\":\"PASS\",\"model\":\"opus\",\"reviewed_diff_hash\":\"$CUR\",\"issues\":[{\"file\":\"f.txt\",\"line\":1,\"severity\":\"high\",\"confidence\":90,\"category\":\"security\",\"description\":\"x\"}]}" | bash "$RL" --write-backstop-verdict >/dev/null 2>&1
ok "$(art_status .claude/pr-backstop-verdict.local.json)" "FAIL" "high issue recomputed to FAIL (caller said PASS)"

echo "== 5. write-pr-marker refuses on backstop FAIL =="
rm -f .claude/pr-review-passed.local
bash "$RL" --write-pr-marker >/dev/null 2>&1
ok "$?" "1" "marker refused when backstop FAIL"
ok "$([ -f .claude/pr-review-passed.local ] && echo y || echo n)" "n" "no marker written"

echo "== 6. reject missing confidence =="
echo "{\"status\":\"PASS\",\"model\":\"opus\",\"reviewed_diff_hash\":\"$CUR\",\"issues\":[{\"file\":\"f.txt\",\"line\":1,\"severity\":\"low\",\"category\":\"bug\",\"description\":\"x\"}]}" | bash "$RL" --write-backstop-verdict >/dev/null 2>&1
ok "$?" "1" "missing confidence rejected"

echo "== 7. reject out-of-enum severity =="
echo "{\"status\":\"PASS\",\"model\":\"opus\",\"reviewed_diff_hash\":\"$CUR\",\"issues\":[{\"file\":\"f.txt\",\"line\":1,\"severity\":\"CRITICAL\",\"confidence\":80,\"category\":\"bug\",\"description\":\"x\"}]}" | bash "$RL" --write-backstop-verdict >/dev/null 2>&1
ok "$?" "1" "out-of-enum severity (CRITICAL) rejected"

echo "== 8. reject stale reviewed_diff_hash (TOCTOU) =="
echo "{\"status\":\"PASS\",\"model\":\"opus\",\"reviewed_diff_hash\":\"deadbeef\",\"issues\":[]}" | bash "$RL" --write-backstop-verdict >/dev/null 2>&1
ok "$?" "1" "stale reviewed_diff_hash rejected"

echo "== 9. reject caller-supplied diff_hash/ts (unknown top-level) =="
echo "{\"status\":\"PASS\",\"model\":\"opus\",\"reviewed_diff_hash\":\"$CUR\",\"diff_hash\":\"$CUR\",\"ts\":1,\"issues\":[]}" | bash "$RL" --write-backstop-verdict >/dev/null 2>&1
ok "$?" "1" "caller-supplied diff_hash/ts rejected"

echo "== 10. writer fails closed on empty diff (no base) =="
( cd "$WORK" && git checkout -q main 2>/dev/null
  echo "{\"status\":\"PASS\",\"model\":\"opus\",\"reviewed_diff_hash\":\"$CUR\",\"issues\":[]}" \
    | LITMUS_PR_BASE=main bash "$RL" --write-backstop-verdict >/dev/null 2>&1 )
ok "$?" "1" "empty diff (HEAD==base) fails closed"
git checkout -q feature

echo "== 11. gate accepts a fresh FAST marker matching the diff =="
rm -f .claude/pr-codex-lead.local.json .claude/pr-backstop-verdict.local.json
printf 'PASS-FAST-%s-%s\n' "$CUR" "$(date +%s)" > .claude/pr-review-passed.local
DEC=$(printf '{"tool_name":"Bash","tool_input":{"command":"cd %s && gh pr create --fill"}}' "$WORK" \
  | env -u SKIP_LITMUS bash "$GATE" 2>/dev/null)
ok "$(printf '%s' "$DEC" | grep -q '"block"' && echo block || echo allow)" "allow" "fresh FAST marker accepted"

echo "== 12. gate rejects a FAST marker with a wrong hash =="
printf 'PASS-FAST-%s-%s\n' "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$(date +%s)" > .claude/pr-review-passed.local
DEC=$(printf '{"tool_name":"Bash","tool_input":{"command":"cd %s && gh pr create --fill"}}' "$WORK" \
  | env -u SKIP_LITMUS bash "$GATE" 2>/dev/null)
ok "$(printf '%s' "$DEC" | grep -q '"block"' && echo block || echo allow)" "block" "FAST marker with wrong hash rejected"

echo ""
echo "  ── $PASS/$((PASS+FAIL)) passed ──"
[ "$FAIL" -eq 0 ]
