#!/usr/bin/env bash
# tests/test-ultraoracle-evidence.sh
#
# Verifies skills/ultraoracle/scripts/build-evidence-pack.sh — ADR 0007 Phase 1/2.
# The script decides the Oracle review-type LABEL from what was actually attached,
# so the security-critical behaviors are: (1) summary-only packs stay
# ORACLE_SUMMARY_REVIEW and are never upgraded (ADR settling check #2); (2)
# secret-like files are excluded with no override — including via the generated git
# diff (no unfiltered-diff transmission path); (3) the byte budget is honored;
# (4) retrieval-loop (Phase 5) is rejected so nothing can claim ORACLE_RETRIEVAL_REVIEW.
#
# Needs a real git repo (the script reads HEAD/status/diff), so each run builds a
# throwaway repo under a temp dir and runs the script with CWD inside it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/ultraoracle/scripts/build-evidence-pack.sh"

passed=0; failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

[[ -f "$SCRIPT" ]] || { fail "build-evidence-pack.sh missing at $SCRIPT"; echo "Results: 0 passed, 1 failed"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
git init -q
git config user.email t@t.t; git config user.name t
echo "real source" > app.sh
echo "SECRET" > .env
echo "key" > deploy.pem
git add -A 2>/dev/null || true
git commit -qm init 2>/dev/null || true
echo "question text" > q.txt

run() { ( cd "$TMP" && bash "$SCRIPT" "$@" ); }

# Test 1: no raw files attached => ORACLE_SUMMARY_REVIEW (not upgraded).
out="$(run --mode repo --out-dir "$TMP/p1" --question-file "$TMP/q.txt" | tail -n1)"
if [[ "$out" == "ORACLE_SUMMARY_REVIEW" ]]; then ok "summary-only stays SUMMARY"; else fail "t1 expected SUMMARY got '$out'"; fi

# Test 2: a real repo file attached => ORACLE_REPO_ATTACHED_REVIEW.
out="$(run --mode repo --out-dir "$TMP/p2" --question-file "$TMP/q.txt" --file "$TMP/app.sh" | tail -n1)"
if [[ "$out" == "ORACLE_REPO_ATTACHED_REVIEW" ]]; then ok "raw file => REPO_ATTACHED"; else fail "t2 expected REPO_ATTACHED got '$out'"; fi

# Test 3: secret-like files excluded — not copied, manifest records exclusion,
#         and with ONLY secrets requested the label must NOT upgrade.
out="$(run --mode repo --out-dir "$TMP/p3" --question-file "$TMP/q.txt" \
        --file "$TMP/.env" --file "$TMP/deploy.pem" | tail -n1)"
if [[ "$out" == "ORACLE_SUMMARY_REVIEW" ]] \
   && ! ls "$TMP/p3/files/"* >/dev/null 2>&1 \
   && grep -q "secret_excluded" "$TMP/p3/manifest.txt"; then
  ok "secret-like files excluded, label not upgraded"
else
  fail "t3 secrets leaked or label upgraded (got '$out')"
fi

# Test 4: byte budget skips an oversized file (stays SUMMARY since nothing attaches).
head -c 5000 /dev/zero | tr '\0' 'x' > "$TMP/big.txt"
out="$(run --mode repo --out-dir "$TMP/p4" --question-file "$TMP/q.txt" \
        --byte-budget 100 --file "$TMP/big.txt" | tail -n1)"
if [[ "$out" == "ORACLE_SUMMARY_REVIEW" ]] && grep -q "budget_skipped" "$TMP/p4/manifest.txt"; then
  ok "over-budget file skipped"
else
  fail "t4 budget not enforced (got '$out')"
fi

# Test 5: retrieval-loop rejected (Phase 5), non-zero, no label on stdout.
set +e
rl_out="$(run --mode retrieval-loop --out-dir "$TMP/p5" 2>/dev/null)"; rl_rc=$?
set -e
if [[ "$rl_rc" -ne 0 && -z "$rl_out" ]]; then
  ok "retrieval-loop rejected, no label emitted"
else
  fail "t5 retrieval-loop not rejected (rc=$rl_rc out='$rl_out')"
fi

# Test 6: manifest carries the auditable fields.
if grep -q "^run_id: " "$TMP/p2/manifest.txt" \
   && grep -q "^git_sha: " "$TMP/p2/manifest.txt" \
   && grep -q "^label: " "$TMP/p2/manifest.txt"; then
  ok "manifest records run_id/git_sha/label"
else
  fail "t6 manifest missing audit fields"
fi

# Test 7: a secret in a TRACKED file's working-tree diff must not ride out via
#         git-diff.txt — the generated git context is gated too (HIGH #1).
( cd "$TMP" && printf 'token = "sk-ant-api03-%s"\n' "$(printf 'A%.0s' {1..40})" >> app.sh )
run --mode repo --out-dir "$TMP/p7" --question-file "$TMP/q.txt" >/dev/null
if [[ ! -f "$TMP/p7/git-diff.txt" ]] && grep -q "git_diff (generated)" "$TMP/p7/manifest.txt"; then
  ok "secret in git diff excluded (no unfiltered-diff path)"
else
  fail "t7 git-diff.txt with secret was not excluded"
fi
( cd "$TMP" && git checkout -q -- app.sh )

# Test 8: namespaced key formats are caught (regex breadth — HIGH #2).
printf 'k=sk-proj-%s\n' "$(printf 'B%.0s' {1..30})" > "$TMP/cfg.txt"
out="$(run --mode repo --out-dir "$TMP/p8" --question-file "$TMP/q.txt" --file "$TMP/cfg.txt" | tail -n1)"
if [[ "$out" == "ORACLE_SUMMARY_REVIEW" ]] && grep -q "secret_excluded: .*cfg.txt" "$TMP/p8/manifest.txt"; then
  ok "sk-proj- key file excluded"
else
  fail "t8 namespaced key not caught (got '$out')"
fi

# Test 9: a --file outside the repo is rejected (path containment), label stays SUMMARY.
OUTSIDE="$(mktemp)"; echo "external content" > "$OUTSIDE"
out="$(run --mode repo --out-dir "$TMP/p9" --question-file "$TMP/q.txt" --file "$OUTSIDE" | tail -n1)"
if [[ "$out" == "ORACLE_SUMMARY_REVIEW" ]] && grep -q "path_excluded" "$TMP/p9/manifest.txt"; then
  ok "out-of-repo --file rejected"
else
  fail "t9 out-of-repo file attached (got '$out')"
fi
rm -f "$OUTSIDE"

# Test 10: a secret AFTER 64KB of padding is still caught (whole-file scan).
{ head -c 70000 /dev/zero | tr '\0' 'x'; printf '\nAKIA%s\n' "$(printf 'C%.0s' {1..16})"; } > "$TMP/late.txt"
out="$(run --mode repo --out-dir "$TMP/p10" --question-file "$TMP/q.txt" --file "$TMP/late.txt" | tail -n1)"
if [[ "$out" == "ORACLE_SUMMARY_REVIEW" ]] && grep -q "secret_excluded: .*late.txt" "$TMP/p10/manifest.txt"; then
  ok "secret past 64KB caught"
else
  fail "t10 late secret slipped through (got '$out')"
fi

# Test 11: --out-dir outside the repo is rejected (write-boundary).
OUTDIR="$(mktemp -d)"
set +e
( cd "$TMP" && bash "$SCRIPT" --mode repo --out-dir "$OUTDIR/pack" --question-file "$TMP/q.txt" >/dev/null 2>&1 ); rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then ok "out-of-repo --out-dir rejected"; else fail "t11 out-of-repo out-dir accepted"; fi
rm -rf "$OUTDIR"

# Test 12: a trailing value-flag with no argument fails closed (no set -u crash).
set +e
( cd "$TMP" && bash "$SCRIPT" --mode repo --out-dir "$TMP/p12" --file >/dev/null 2>&1 ); rc=$?
set -e
if [[ "$rc" -eq 2 ]]; then ok "trailing --file fails closed (usage)"; else fail "t12 trailing --file rc=$rc (expected 2)"; fi

# Test 13: a repo-local symlink pointing outside the repo is rejected (no cp-through).
EXT="$(mktemp)"; echo "external secretless content" > "$EXT"
( cd "$TMP" && ln -sf "$EXT" leak.txt )
out="$(run --mode repo --out-dir "$TMP/p13" --question-file "$TMP/q.txt" --file "$TMP/leak.txt" | tail -n1)"
if [[ "$out" == "ORACLE_SUMMARY_REVIEW" ]] && grep -q "path_excluded" "$TMP/p13/manifest.txt"; then
  ok "repo-local symlink to outside rejected"
else
  fail "t13 symlink escape attached (got '$out')"
fi
rm -f "$EXT" "$TMP/leak.txt"

# Test 14: a rejected out-of-repo --out-dir leaves nothing behind.
OUTDIR2="$(mktemp -d)"
set +e
( cd "$TMP" && bash "$SCRIPT" --mode repo --out-dir "$OUTDIR2/pack" --question-file "$TMP/q.txt" >/dev/null 2>&1 )
set -e
if [[ ! -e "$OUTDIR2/pack" ]]; then ok "rejected out-dir leaves nothing behind"; else fail "t14 out-dir created outside repo"; fi
rm -rf "$OUTDIR2"

echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
