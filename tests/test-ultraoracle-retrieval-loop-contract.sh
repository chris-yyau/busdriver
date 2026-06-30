#!/usr/bin/env bash
# tests/test-ultraoracle-retrieval-loop-contract.sh
# ADR 0007 Phase 5 — the two-round loop hits live GPT-5.5 Pro, so it cannot be unit
# tested. Pin the load-bearing wiring with a static contract (same approach as
# test-ultra-council.sh): flag-gated dispatch, retrieve-before-validate ordering,
# exactly two consults, and fail-closed tokens.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
S="$REPO_ROOT/skills/ultraoracle/scripts/run-retrieval-loop.sh"

passed=0; failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }
[[ -f "$S" ]] || { fail "run-retrieval-loop.sh missing"; echo "Results: 0 passed, 1 failed"; exit 1; }

# A1: dispatch is gated by the default-OFF blueprintReview flag.
grep -q 'ultra_oracle_surface_enabled blueprintReview' "$S" && ok "A1 flag-gated" || fail "A1 missing flag gate"
# A2: skips with a typed token when disabled (no silent run).
grep -q 'skipped:disabled' "$S" && ok "A2 disabled token" || fail "A2 missing disabled token"
# A3: retrieval runs BEFORE validation (ordering anchor).
rl=$(grep -n 'retrieve-evidence.sh' "$S" | head -1 | cut -d: -f1)
vl=$(grep -n 'validate-retrieval-review.sh' "$S" | head -1 | cut -d: -f1)
{ [ -n "$rl" ] && [ -n "$vl" ] && [ "$rl" -lt "$vl" ]; } && ok "A3 retrieve before validate" || fail "A3 ordering wrong"
# A4: exactly two oracle consults (Round 1 + Round 2) — anchor to actual call
# sites (the `st="$(ultra_oracle_consult ...)"` invocations), not every mention
# of the function name (comments referencing it would inflate a plain grep -c).
c=$(grep -cE '="\$\(ultra_oracle_consult' "$S" || true)
[ "$c" -eq 2 ] && ok "A4 exactly two consults ($c)" || fail "A4 expected exactly 2 consults, got $c"
# A5: fail-closed token on a failed validation / consult.
grep -Eq 'printf .?error|echo .?error|"error"' "$S" && ok "A5 fail-closed token" || fail "A5 missing error token"
# A6: question-file validated (present+readable+non-empty) before any billed dispatch.
grep -q '\-s "\$QUESTION_FILE"' "$S" && ok "A6 question-file validated" || fail "A6 missing question-file -s guard"
# A7: errexit-safe consult capture (if st=...; then) so a non-zero typed token is not lost
#     when the wrapper runs under set -e — guards the confirmed token-loss defect.
[ "$(grep -c 'if st[12]="\$(ultra_oracle_consult' "$S")" -eq 2 ] && ok "A7 errexit-safe capture x2" || fail "A7 consult capture not errexit-safe"
# A8: Round-2 prompt re-states the original question (grounding) — the question file is
#     concatenated into round2-prompt.txt, not just round1.
awk '/round2-prompt.txt/{f=1} f&&/ORIGINAL QUESTION/{print; exit}' "$S" | grep -q . && ok "A8 round-2 re-grounds question" || fail "A8 round-2 omits question"
# A9: inventory is secret-filtered (emit_nonsecret_z), not raw git ls-files.
grep -q 'ls-files -z .*| emit_nonsecret_z' "$S" && ok "A9 inventory secret-filtered" || fail "A9 raw inventory"
# A10: question file is secret-scanned before the first consult.
qline=$(grep -n 'is_secret_like "\$q_canon"' "$S" | head -1 | cut -d: -f1)
c1line=$(grep -n 'ultra_oracle_consult' "$S" | head -1 | cut -d: -f1)
{ [ -n "$qline" ] && [ -n "$c1line" ] && [ "$qline" -lt "$c1line" ]; } && ok "A10 question secret-gated pre-consult" || fail "A10 question not gated before consult"

# A11: question-file guarded as a REGULAR file (-f), not just -r/-s — a directory satisfies
#      -r/-s and `cat dir` fails silently, which would bill a Round-1 consult on an empty question.
grep -q '\-f "\$QUESTION_FILE"' "$S" && ok "A11 question-file regular-file guard" || fail "A11 missing -f guard"

echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
