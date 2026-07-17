#!/usr/bin/env bash
# Tests for the litmus PR-mode dual-voice flow (ADR 0006) after the #350 seal.
#
# The backstop verdict is produced ONLY by `run-review-loop.sh --run-backstop`,
# which dispatches the read-only backstop as a CAPTURED `claude -p` subprocess and
# pipes its stdout to an INTERNAL strict writer (`_persist_backstop_verdict`).
# There is NO public `--write-backstop-verdict` subcommand — a public writer let
# the orchestrating model forge a PASS by piping hand-typed JSON (#350). These
# tests drive the real captured path with a stubbed `claude` on PATH.
#
# Covered:
#   - --run-backstop: clean capture ⇒ PASS artifact; high ⇒ recomputed FAIL;
#     fence-stripping; dispatch failure / malformed output / missing codex-lead
#     / empty diff ⇒ fail-closed (no artifact); strict validation (missing
#     confidence, out-of-enum severity, unknown top-level field) ⇒ no artifact.
#   - --write-pr-marker: writes only when BOTH voices PASS; refuses on backstop FAIL.
#   - the seal itself: no public --write-backstop-verdict subcommand exists.
#   - pre-pr-gate.sh: accepts a fresh matching FAST marker; rejects a wrong-hash one.
#
# Usage: bash tests/test-pr-dual-voice.sh
# Exit: 0 if all pass, 1 if any fail.

# SC2312: assertions read `ok "$(fn)" ...` throughout — the masked-return caveat
# does not apply (the helpers only compare + count), so disable it file-wide.
# shellcheck disable=SC2312
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO="$(pwd)"
RL="$REPO/skills/litmus/scripts/run-review-loop.sh"
GATE="$REPO/hooks/gate-scripts/pre-pr-gate.sh"

# Pin the state dir so the test is independent of an ambient .opencode export.
export BUSDRIVER_STATE_DIR=.claude

PASS=0; FAIL=0
ok() { if [ "$1" = "$2" ]; then echo "  PASS  $3"; PASS=$((PASS+1)); else echo "  FAIL  $3 (got '$1' want '$2')"; FAIL=$((FAIL+1)); fi; }

# Run the gate over a payload and classify its JSON decision. Distinguishes a
# genuine "allow" (gate ran and chose not to block) from a "crash" (gate failed
# to execute: nonzero exit AND empty output). Without the crash arm, a broken
# gate's empty output would be silently read as "allow".
gate_decision() {
  local payload="$1" out rc
  out=$(printf '%s' "$payload" | env -u SKIP_LITMUS bash "$GATE" 2>/dev/null); rc=$?
  if printf '%s' "$out" | grep -q '"block"'; then
    echo block
  elif [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    echo crash
  else
    echo allow
  fi
}

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

BS=".claude/pr-backstop-verdict.local.json"
art_status() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['status'])" "$1" 2>/dev/null; }
has_art()    { [[ -f "$BS" ]] && echo y || echo n; }

# The Codex-lead PASS artifact is written ONLY inline on a real Codex PASS (no
# subcommand — forging it would need a real review). Seed one as a fixture so the
# backstop precondition (a fresh Codex-lead PASS for THIS diff) is satisfiable.
seed_codex_lead() {
  mkdir -p .claude
  printf '{"status":"PASS","model":"codex","diff_hash":"%s","ts":%s}\n' "$CUR" "$(date +%s)" > .claude/pr-codex-lead.local.json
}

# Stub `claude` on PATH so --run-backstop dispatches offline. The stub answers the
# confinement capability guard (`claude --help` must advertise --tools /
# --setting-sources), drains the prompt, and emits an --output-format json
# envelope whose .result is $STUB_VERDICT. STUB_RC forces a dispatch failure.
STUBDIR="$WORK/stubbin"; mkdir -p "$STUBDIR"
write_stub() {
  cat > "$STUBDIR/claude" <<'STUB'
#!/bin/bash
if [ "$1" = "--help" ]; then echo "  --tools <tools...>"; echo "  --setting-sources <sources>"; exit 0; fi
cat >/dev/null 2>&1 || true
# STUB_FAIL_FIRST=N: fail transiently (is_error envelope) on the first N dispatches
# of this run, then succeed — exercises the backstop retry loop. Counter persists in
# a per-run file so retries within one --run-backstop advance it.
if { [ -n "${STUB_FAIL_FIRST:-}" ] || [ -n "${STUB_BAD_FIRST:-}" ]; } && [ -n "${STUB_COUNT_FILE:-}" ]; then
  n=$(cat "$STUB_COUNT_FILE" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB_COUNT_FILE"
  # STUB_FAIL_FIRST: transient is_error (ECONNRESET) for the first N dispatches.
  if [ -n "${STUB_FAIL_FIRST:-}" ] && [ "$n" -le "$STUB_FAIL_FIRST" ]; then
    python3 -c 'import json,sys; sys.stdout.write(json.dumps({"type":"result","is_error":True,"result":"API Error: ECONNRESET"}))'
    exit 0
  fi
  # STUB_BAD_FIRST: parseable-but-schema-invalid verdict ({}) for the first N — the
  # writer rejects it, so the retry loop must re-dispatch rather than fail-closed.
  if [ -n "${STUB_BAD_FIRST:-}" ] && [ "$n" -le "$STUB_BAD_FIRST" ]; then
    python3 -c 'import json,sys; sys.stdout.write(json.dumps({"type":"result","is_error":False,"result":"{}"}))'
    exit 0
  fi
fi
[ "${STUB_RC:-0}" != "0" ] && exit "${STUB_RC}"
python3 -c 'import json,os,sys; sys.stdout.write(json.dumps({"type":"result","subtype":"success","is_error":os.environ.get("STUB_ERR")=="1","result":os.environ.get("STUB_VERDICT","")}))'
STUB
  chmod +x "$STUBDIR/claude"
}
write_stub
export PATH="$STUBDIR:$PATH"
# Keep the retry loop instant in tests (exercise the COUNT, never sleep).
export LITMUS_PR_BACKSTOP_RETRY_DELAY=0

# run_bs <verdict-json>: seed codex-lead, clear any prior artifact, run --run-backstop
# with the stub emitting <verdict-json> as the backstop's verdict. Returns the exit code.
run_bs() {
  rm -f "$BS"; seed_codex_lead
  STUB_VERDICT="$1" bash "$RL" --run-backstop >/dev/null 2>&1
}

echo "== 1. codex-lead fixture present/PASS =="
seed_codex_lead
ok "$([[ -f .claude/pr-codex-lead.local.json ]] && echo y || echo n)" "y" "codex-lead artifact present"
ok "$(art_status .claude/pr-codex-lead.local.json)" "PASS" "codex-lead status=PASS"

echo "== 2. --run-backstop: captured clean verdict ⇒ PASS artifact =="
run_bs '{"status":"PASS","issues":[]}'
ok "$?" "0" "run-backstop exit 0 on clean capture"
ok "$(art_status "$BS")" "PASS" "captured artifact status=PASS"

echo "== 3. --write-pr-marker writes when BOTH voices PASS =="
rm -f .claude/pr-review-passed.local
bash "$RL" --write-pr-marker >/dev/null 2>&1
ok "$?" "0" "marker writer exit 0"
ok "$(cat .claude/pr-review-passed.local 2>/dev/null)" "$CUR" "marker == current diff hash"

echo "== 4. --run-backstop: captured high finding ⇒ recomputed FAIL =="
run_bs '{"status":"PASS","issues":[{"file":"f.txt","line":1,"severity":"high","confidence":88,"category":"security","description":"x"}]}'
ok "$(art_status "$BS")" "FAIL" "captured high issue recomputed to FAIL (agent said PASS)"

echo "== 5. --write-pr-marker refuses on backstop FAIL =="
rm -f .claude/pr-review-passed.local
bash "$RL" --write-pr-marker >/dev/null 2>&1
ok "$?" "1" "marker refused when backstop FAIL"
ok "$([[ -f .claude/pr-review-passed.local ]] && echo y || echo n)" "n" "no marker written"

echo "== 6. --run-backstop: strips a markdown fence around the verdict =="
FENCE='`''`''`'   # three backticks, quote-safe
run_bs "$(printf '%sjson\n{"status":"PASS","issues":[]}\n%s' "$FENCE" "$FENCE")"
ok "$?" "0" "fenced verdict parsed"
ok "$(art_status "$BS")" "PASS" "fenced verdict ⇒ PASS artifact"

echo "== 7. strict validation via the captured path (fail-closed, no artifact) =="
# missing confidence
run_bs '{"status":"PASS","issues":[{"file":"f.txt","line":1,"severity":"low","category":"bug","description":"x"}]}'
ok "$(has_art)" "n" "missing confidence rejected (no artifact)"
# out-of-enum severity
run_bs '{"status":"PASS","issues":[{"file":"f.txt","line":1,"severity":"CRITICAL","confidence":80,"category":"bug","description":"x"}]}'
ok "$(has_art)" "n" "out-of-enum severity (CRITICAL) rejected"
# unknown top-level field — faithful passthrough hands it to the writer, which rejects it
run_bs '{"status":"PASS","issues":[],"diff_hash":"deadbeef"}'
ok "$(has_art)" "n" "unknown top-level field (diff_hash) rejected — parser does not launder"
# missing issues array — faithful passthrough must NOT default it to []
run_bs '{"status":"PASS"}'
ok "$(has_art)" "n" "missing issues array rejected — parser does not default to []"

echo "== 8. --run-backstop: dispatch failure (nonzero claude) ⇒ fail-closed =="
rm -f "$BS"; seed_codex_lead
STUB_RC=7 STUB_VERDICT='{"status":"PASS","issues":[]}' bash "$RL" --run-backstop >/dev/null 2>&1
ok "$?" "1" "nonzero claude ⇒ run-backstop fails"
ok "$(has_art)" "n" "no artifact on dispatch failure"

echo "== 9. --run-backstop: malformed CLI output ⇒ fail-closed =="
# result-level malformed via STUB_VERDICT: "" (empty), non-object, then a non-JSON envelope
for bad in '' '[1,2,3]'; do
  rm -f "$BS"; seed_codex_lead
  STUB_VERDICT="$bad" bash "$RL" --run-backstop >/dev/null 2>&1
  ok "$(has_art)" "n" "malformed result leaves no artifact: '${bad}'"
done
rm -f "$BS"; seed_codex_lead
cat > "$STUBDIR/claude" <<'STUB'
#!/bin/bash
if [ "$1" = "--help" ]; then echo "  --tools <tools...>"; echo "  --setting-sources <sources>"; exit 0; fi
cat >/dev/null 2>&1 || true
printf '%s' "not json at all"
STUB
chmod +x "$STUBDIR/claude"
bash "$RL" --run-backstop >/dev/null 2>&1
ok "$(has_art)" "n" "non-JSON envelope leaves no artifact"
write_stub  # restore the well-behaved stub

echo "== 9b. --run-backstop: transient is_error, then success ⇒ retry recovers =="
rm -f "$BS"; seed_codex_lead
CF="$WORK/stub-count"; rm -f "$CF"
# Fail the first 2 dispatches (is_error), succeed on the 3rd — within the default
# 2 retries (3 total attempts). Expect a clean PASS artifact.
STUB_FAIL_FIRST=2 STUB_COUNT_FILE="$CF" STUB_VERDICT='{"status":"PASS","issues":[]}' \
  bash "$RL" --run-backstop >/dev/null 2>&1
ok "$?" "0" "run-backstop recovers after 2 transient failures"
ok "$(art_status "$BS")" "PASS" "recovered verdict ⇒ PASS artifact"
ok "$(cat "$CF" 2>/dev/null)" "3" "took exactly 3 dispatch attempts"

echo "== 9c. --run-backstop: transient failures exceed retries ⇒ fail-closed =="
rm -f "$BS"; seed_codex_lead; rm -f "$CF"
# Fail more times than retries allow (5 > 3 total) — must fail-closed, no artifact.
STUB_FAIL_FIRST=9 STUB_COUNT_FILE="$CF" LITMUS_PR_BACKSTOP_RETRIES=2 STUB_VERDICT='{"status":"PASS","issues":[]}' \
  bash "$RL" --run-backstop >/dev/null 2>&1
ok "$?" "1" "run-backstop fails-closed when retries exhausted"
ok "$(has_art)" "n" "no artifact when retries exhausted"
ok "$(cat "$CF" 2>/dev/null)" "3" "stopped after exactly 3 attempts (1 + 2 retries)"

echo "== 9d. --run-backstop: schema-invalid but parseable verdict ⇒ TERMINAL fail-closed (no retry) =="
rm -f "$BS"; seed_codex_lead; rm -f "$CF"
# A parseable-but-schema-invalid `{}` is handed to the writer, which is terminal:
# the writer's nonzero can also mean TOCTOU/oversize/FS — a re-dispatch cannot fix
# those — so it fails-closed on the FIRST dispatch, not after burning retries.
STUB_BAD_FIRST=1 STUB_COUNT_FILE="$CF" STUB_VERDICT='{"status":"PASS","issues":[]}' \
  bash "$RL" --run-backstop >/dev/null 2>&1
ok "$?" "1" "writer rejection is terminal (fail-closed)"
ok "$(has_art)" "n" "no artifact on writer rejection"
ok "$(cat "$CF" 2>/dev/null)" "1" "writer failure NOT retried — exactly 1 dispatch"

echo "== 9e. tunables clamped: huge RETRIES bounded (no unbounded paid dispatch) =="
rm -f "$BS"; seed_codex_lead; rm -f "$CF"
# RETRIES=999999 must clamp to 5 (6 total). Fail every dispatch → exactly 6 attempts.
STUB_FAIL_FIRST=999 STUB_COUNT_FILE="$CF" LITMUS_PR_BACKSTOP_RETRIES=999999 STUB_VERDICT='{"status":"PASS","issues":[]}' \
  bash "$RL" --run-backstop >/dev/null 2>&1
ok "$?" "1" "clamped retries still fail-closed when all transient"
ok "$(cat "$CF" 2>/dev/null)" "6" "RETRIES clamped to 5 ⇒ exactly 6 attempts"

echo "== 9f. tunables: overflow-length value snaps to ceiling (no negative/abort) =="
rm -f "$BS"; seed_codex_lead; rm -f "$CF"
# A >2^63 RETRIES string must NOT wrap negative past the clamp; it snaps to 5 (6
# attempts) and the run must still fail-closed cleanly, not abort under set -e.
# (DELAY inherits the global 0 so this stays instant — the DELAY length-guard is
# covered by the arithmetic-overflow unit check, not a 120s live sleep.)
STUB_FAIL_FIRST=999 STUB_COUNT_FILE="$CF" \
  LITMUS_PR_BACKSTOP_RETRIES=9223372036854775808 \
  STUB_VERDICT='{"status":"PASS","issues":[]}' bash "$RL" --run-backstop >/dev/null 2>&1
ok "$?" "1" "overflow-length RETRIES still fail-closed cleanly"
ok "$(cat "$CF" 2>/dev/null)" "6" "overflow RETRIES snaps to 5 ⇒ exactly 6 attempts"

echo "== 10. --run-backstop: no fresh Codex-lead ⇒ fail-closed (dispatch skipped) =="
rm -f "$BS" .claude/pr-codex-lead.local.json
STUB_VERDICT='{"status":"PASS","issues":[]}' bash "$RL" --run-backstop >/dev/null 2>&1
ok "$?" "1" "run-backstop fails without a codex-lead PASS"
ok "$(has_art)" "n" "no artifact without codex-lead"

echo "== 11. --run-backstop: empty diff (HEAD==base) ⇒ fail-closed =="
rm -f "$BS"
( git checkout -q main 2>/dev/null; seed_codex_lead
  STUB_VERDICT='{"status":"PASS","issues":[]}' LITMUS_PR_BASE=main bash "$RL" --run-backstop >/dev/null 2>&1 )
ok "$?" "1" "empty diff fails closed"
ok "$(has_art)" "n" "no artifact on empty diff"
git checkout -q feature

echo "== 12. seal: no public --write-backstop-verdict subcommand (#350 forge closed) =="
ok "$(grep -cE '"--write-backstop-verdict"' "$RL")" "0" "no public --write-backstop-verdict guard in the script"
ok "$(grep -cE '^_persist_backstop_verdict\(\) \{' "$RL")" "1" "writer is an internal function"
# A direct pipe to the (removed) subcommand must NOT produce an artifact.
rm -f "$BS"; seed_codex_lead
echo "{\"status\":\"PASS\",\"model\":\"opus\",\"reviewed_diff_hash\":\"$CUR\",\"issues\":[]}" \
  | BUSDRIVER_REVIEW_CLI=none bash "$RL" --write-backstop-verdict >/dev/null 2>&1 || true
ok "$(has_art)" "n" "piping hand-typed JSON to the dead subcommand produces no artifact"

echo "== 13. gate accepts a fresh FAST marker matching the diff =="
rm -f .claude/pr-codex-lead.local.json "$BS"
printf 'PASS-FAST-%s-%s\n' "$CUR" "$(date +%s)" > .claude/pr-review-passed.local
DEC=$(printf '{"tool_name":"Bash","tool_input":{"command":"cd %s && gh pr create --fill"}}' "$WORK")
ok "$(gate_decision "$DEC")" "allow" "fresh FAST marker accepted"

echo "== 14. gate rejects a FAST marker with a wrong hash =="
printf 'PASS-FAST-%s-%s\n' "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$(date +%s)" > .claude/pr-review-passed.local
DEC=$(printf '{"tool_name":"Bash","tool_input":{"command":"cd %s && gh pr create --fill"}}' "$WORK")
ok "$(gate_decision "$DEC")" "block" "FAST marker with wrong hash rejected"

echo ""
echo "  ── $PASS/$((PASS+FAIL)) passed ──"
[ "$FAIL" -eq 0 ]
