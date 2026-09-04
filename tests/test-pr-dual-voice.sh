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
# SC2016: this file is full of DELIBERATE single-quoted literals — stub script
#         bodies whose `$VAR`s belong to the stub at runtime, perl module
#         sources, and grep patterns that search for literal shell text in
#         run-review-loop.sh. Expansion is never wanted in any of them.
# shellcheck disable=SC2312,SC2016
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
# #576: must match compute_pr_diff_hash / pre-pr-gate.sh byte for byte, --full-index
# included — a bare `git diff` abbreviates index lines and no longer agrees.
# STREAMED, not captured: since #576 round 2 both sides pipe git straight into the
# hash, and a command substitution strips trailing newlines. Capturing here would
# compute a different digest than the code under test and fail every marker match.
_MB=$(git merge-base origin/main HEAD)
_TIP=$(git rev-parse --verify HEAD)
CUR=$(git --no-replace-objects -c color.ui=never -c core.quotePath=false diff --no-ext-diff --no-textconv --full-index --ignore-submodules=none "${_MB}...${_TIP}" | (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1)

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
# STUB_SLEEP=N: hang for N seconds so the REAL `timeout` wrapper fires (rc=124).
# Counts the dispatch itself, because the point of the #823 cases is the attempt
# COUNT under a timeout — a stub that merely `exit 124`s would prove the branch
# fires without proving the wrapper was rebuilt with the remaining budget.
# Mutually exclusive with STUB_FAIL_FIRST/STUB_BAD_FIRST (which count separately).
# STUB_IGNORE_TERM=1: additionally ignore SIGTERM while hanging, so only the
# wrapper's KILL escalation can end this dispatch (rc=137). Models a `claude`
# that traps/ignores TERM — without `-k` it would outrun the budget entirely.
if [ -n "${STUB_SLEEP:-}" ]; then
  if [ -n "${STUB_COUNT_FILE:-}" ]; then
    n=$(cat "$STUB_COUNT_FILE" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB_COUNT_FILE"
  fi
  [ -n "${STUB_IGNORE_TERM:-}" ] && trap '' TERM
  sleep "$STUB_SLEEP"
fi
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
# STUB_SILENT=1: exit 0 having written nothing. An empty capture is a TRANSIENT
# condition the retry loop exists for — it must NOT be treated as terminal.
if [ -n "${STUB_SILENT:-}" ]; then
  if [ -n "${STUB_COUNT_FILE:-}" ]; then
    n=$(cat "$STUB_COUNT_FILE" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB_COUNT_FILE"
  fi
  exit 0
fi
[ "${STUB_RC:-0}" != "0" ] && exit "${STUB_RC}"
# STUB_ORPHAN=N: leave a TERM-ignoring descendant holding the CAPTURED STDOUT for
# N seconds and then exit normally. Models a `claude` that spawns a helper which
# outlives it: the wrapper's timer is cancelled when the leader is reaped, so
# nothing bounds the straggler — only the capture mechanism decides whether the
# caller is still blocked on it. (SIG_IGN survives exec, so the sleep keeps it.)
if [ -n "${STUB_ORPHAN:-}" ]; then
  ( trap '' TERM; exec sleep "$STUB_ORPHAN" ) &
  # Record the pid so a caller can assert the straggler was REAPED, not merely
  # outlived. `exec` keeps the subshell's pid, so $! names the sleep itself.
  if [ -n "${STUB_ORPHAN_PID_FILE:-}" ]; then echo $! > "$STUB_ORPHAN_PID_FILE"; fi
fi
# STUB_HANG=N: keep the LEADER itself alive N seconds before emitting the verdict.
# Only useful with STUB_ORPHAN: it holds the dispatch open so a caller can signal
# the review loop while it is genuinely blocked in `wait`, which is the only way
# to exercise the signal path rather than the post-dispatch reap.
if [ -n "${STUB_HANG:-}" ]; then
  sleep "$STUB_HANG"
fi
# STUB_ORPHAN_APPEND=N: a descendant that not only holds the captured stdout but
# keeps WRITING to it for N seconds. Strictly nastier than STUB_ORPHAN: against a
# regular file an unbounded reader can be kept behind a receding EOF forever, so
# this is what proves the read takes a bounded snapshot rather than merely that
# the capture is a file.
if [ -n "${STUB_ORPHAN_APPEND:-}" ]; then
  ( trap '' TERM
    # BOUNDED write, then hold. The capture file is unlinked while this fd is
    # still open, so an unbounded writer would keep allocating blocks that
    # nothing can reclaim until it exits — gigabytes of CI temp disk for no
    # extra coverage. A few MiB is enough to model "the straggler wrote into
    # the capture"; holding the descriptor afterwards is the rest of the model.
    head -c 2097152 /dev/zero | tr '\0' 'Y'
    exec sleep "$STUB_ORPHAN_APPEND" ) &
fi
python3 -c 'import json,os,sys; sys.stdout.write(json.dumps({"type":"result","subtype":"success","is_error":os.environ.get("STUB_ERR")=="1","result":os.environ.get("STUB_VERDICT","")}))'
# STUB_PAD=1: follow a COMPLETE valid envelope with padding past the 4 MiB
# ceiling. A reader that truncates at the cap would parse the valid prefix as a
# clean PASS; the capture must be rejected instead.
if [ -n "${STUB_PAD:-}" ]; then
  # Count this dispatch too, so a caller can assert how many times an oversize
  # capture was produced (it must be terminal, not retried).
  if [ -n "${STUB_COUNT_FILE:-}" ]; then
    n=$(cat "$STUB_COUNT_FILE" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB_COUNT_FILE"
  fi
  head -c 4259840 /dev/zero | tr '\0' ' '
fi
# STUB_NULPAD=1: follow a COMPLETE valid envelope with NUL bytes, staying UNDER
# the size ceiling so the oversize branch cannot be what rejects it. This is the
# shape bash silently normalized away: a command substitution DROPS NULs, so the
# capture came back as the bare valid prefix and parsed as a clean PASS.
if [ -n "${STUB_NULPAD:-}" ]; then
  head -c 4096 /dev/zero
fi
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

echo "== 9g. --run-backstop: a real timeout is NOT retried (#823) =="
# Pre-#823 the loop classified rc=124 as a transient dispatch failure and
# re-dispatched with a FRESH full window, so the sequence could reach
# (retries+1) x TIMEOUT — past the 600s harness Bash cap at ANY setting, which is
# why no LITMUS_PR_BACKSTOP_TIMEOUT value fitted. A real timeout must now fail
# closed after exactly ONE attempt. Driven through the REAL wrapper (a stub that
# just `exit 124`s would prove the branch fires without proving the wrapper was
# rebuilt with this attempt's remaining budget).
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  rm -f "$BS"; seed_codex_lead; rm -f "$CF"
  STUB_SLEEP=20 STUB_COUNT_FILE="$CF" LITMUS_PR_BACKSTOP_TIMEOUT=2 \
    LITMUS_PR_BACKSTOP_RETRIES=2 STUB_VERDICT='{"status":"PASS","issues":[]}' \
    bash "$RL" --run-backstop >/dev/null 2>&1
  ok "$?" "1" "real timeout fails closed"
  ok "$(has_art)" "n" "no artifact on timeout"
  ok "$(cat "$CF" 2>/dev/null)" "1" "timeout NOT retried — exactly 1 dispatch (was 3)"
  # The timeout must report ITS OWN diagnostic. When oversize and empty shared a
  # branch this said "captured envelope exceeded ..." instead, because a killed
  # dispatch leaves an empty capture — the message users need, never printed.
  rm -f "$BS"; seed_codex_lead; rm -f "$CF"
  _TOERR=$(STUB_SLEEP=20 STUB_COUNT_FILE="$CF" LITMUS_PR_BACKSTOP_TIMEOUT=2 \
    LITMUS_PR_BACKSTOP_RETRIES=0 STUB_VERDICT='{"status":"PASS","issues":[]}' \
    bash "$RL" --run-backstop 2>&1 >/dev/null)
  ok "$(printf '%s' "$_TOERR" | grep -c 'timed out')" "1" "timeout reports the timeout diagnostic"
  ok "$(printf '%s' "$_TOERR" | grep -c 'exceeded')" "0" "timeout is not misreported as an oversize capture"
  # BOTH conditions at once: the stub pads past the ceiling and then hangs. The
  # timeout is the actionable diagnosis (split the PR / raise the budget), so it
  # must win; reporting "oversize envelope" would send the operator after the
  # wrong thing entirely.
  rm -f "$BS"; seed_codex_lead; rm -f "$CF"
  _BOTHERR=$(STUB_PAD=1 STUB_SLEEP=20 STUB_COUNT_FILE="$CF" LITMUS_PR_BACKSTOP_TIMEOUT=2 \
    LITMUS_PR_BACKSTOP_RETRIES=0 STUB_VERDICT='{"status":"PASS","issues":[]}' \
    bash "$RL" --run-backstop 2>&1 >/dev/null)
  ok "$(printf '%s' "$_BOTHERR" | grep -c 'timed out')" "1" "oversize AND timed out reports the TIMEOUT"
  ok "$(has_art)" "n" "no artifact when both conditions fire"
else
  echo "  SKIP  no timeout/gtimeout on PATH — cannot exercise the real 124 path"
fi

echo "== 9h. --run-backstop: the budget bounds the whole retry SEQUENCE (#823) =="
rm -f "$BS"; seed_codex_lead; rm -f "$CF"
# Fast transient failures plus a real (non-zero) backoff. Pre-#823 the budget
# bounded a single attempt only, so 5 retries at 2s linear backoff slept
# 2+4+6+8+10 = 30s on their own and ran all 6 attempts. Bounded to a 3s SEQUENCE
# the loop must stop early — both the elapsed time and the attempt count discriminate.
_t0=$(date +%s)
STUB_FAIL_FIRST=999 STUB_COUNT_FILE="$CF" LITMUS_PR_BACKSTOP_TIMEOUT=3 \
  LITMUS_PR_BACKSTOP_RETRY_DELAY=2 LITMUS_PR_BACKSTOP_RETRIES=5 \
  STUB_VERDICT='{"status":"PASS","issues":[]}' bash "$RL" --run-backstop >/dev/null 2>&1
_rc=$?; _el=$(( $(date +%s) - _t0 ))
ok "$_rc" "1" "budget-exhausted sequence fails closed"
ok "$(has_art)" "n" "no artifact when the budget is spent"
ok "$([[ "$_el" -lt 12 ]] && echo y || echo n)" "y" "sequence bounded to the 3s budget (took ${_el}s; pre-fix backoff alone was 30s)"
ok "$([[ "$(cat "$CF" 2>/dev/null || echo 0)" -lt 6 ]] && echo y || echo n)" "y" "stopped before all 6 attempts"

echo "== 9i. --run-backstop: malformed budget falls back, never aborts (#823) =="
# TIMEOUT_S now feeds $(( )) arithmetic and comes from repo-injectable env
# (#325 / ADR 0016), so it is validated with the same digits-only / length-cap /
# base-10 idiom as the retry tunables. Each bad shape must degrade to the default
# and still produce a clean verdict — never abort under set -e, never run octal.
for badval in "abc" "0" "08" "1e9" "9999999999999999999999" "-5"; do
  rm -f "$BS"; seed_codex_lead
  LITMUS_PR_BACKSTOP_TIMEOUT="$badval" STUB_VERDICT='{"status":"PASS","issues":[]}' \
    bash "$RL" --run-backstop >/dev/null 2>&1
  ok "$?" "0" "TIMEOUT='$badval' degrades to a usable budget"
  ok "$(art_status "$BS")" "PASS" "TIMEOUT='$badval' still writes the PASS artifact"
done
# Arithmetic injection: $(( )) evaluates its operands RECURSIVELY, so a
# numeric-prefixed string like `1+a[$(cmd)]` would EXECUTE cmd during expansion.
# The digits-only case must reject it before any arithmetic sees it.
rm -f "$BS" "$WORK/pwned"; seed_codex_lead
LITMUS_PR_BACKSTOP_TIMEOUT="1+a[\$(touch $WORK/pwned)]" \
  STUB_VERDICT='{"status":"PASS","issues":[]}' bash "$RL" --run-backstop >/dev/null 2>&1
ok "$?" "0" "injection-shaped TIMEOUT degrades cleanly"
ok "$([[ -e "$WORK/pwned" ]] && echo y || echo n)" "n" "injection-shaped TIMEOUT never reaches \$(( ))"

echo "== 9j. the default budget sits UNDER the 600s harness Bash cap (#823/#368) =="
# A 600s budget leaves no headroom for the startup/diff/context phases that run
# before the dispatch, so the call is killed at the boundary with no verdict.
ok "$(grep -c 'LITMUS_PR_BACKSTOP_TIMEOUT:-540' "$RL")" "1" "default budget is 540, not 600"
ok "$(grep -c 'LITMUS_PR_BACKSTOP_TIMEOUT:-600' "$RL")" "0" "no 600s default remains"

echo "== 9k. --run-backstop: a TERM-ignoring dispatch is force-killed, not retried =="
# SIGTERM alone bounds nothing a child can ignore: without a `-k` grace the
# wrapper would return only after the hang finished on its own, so the sequence
# outruns its budget and the harness kills the call with no verdict — #823's
# failure relocated. The escalation must end the attempt within the grace AND
# the resulting 137 must be terminal (one dispatch, no re-dispatch).
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  rm -f "$BS"; seed_codex_lead; rm -f "$CF"
  _t0=$(date +%s)
  STUB_SLEEP=60 STUB_IGNORE_TERM=1 STUB_COUNT_FILE="$CF" LITMUS_PR_BACKSTOP_TIMEOUT=2 \
    LITMUS_PR_BACKSTOP_RETRIES=2 STUB_VERDICT='{"status":"PASS","issues":[]}' \
    bash "$RL" --run-backstop >/dev/null 2>&1
  _rc=$?; _el=$(( $(date +%s) - _t0 ))
  ok "$_rc" "1" "TERM-ignoring dispatch fails closed"
  ok "$(has_art)" "n" "no artifact when the dispatch had to be killed"
  ok "$(cat "$CF" 2>/dev/null)" "1" "force-kill NOT retried — exactly 1 dispatch"
  ok "$([[ "$_el" -lt 40 ]] && echo y || echo n)" "y" "killed within the grace, not after the 60s hang (took ${_el}s)"
else
  echo "  SKIP  no timeout/gtimeout on PATH — cannot exercise the -k escalation"
fi

echo "== 9l. --run-backstop: a wrapper is MANDATORY — perl stand-in, else refuse =="
# With no wrapper at all the budget cannot interrupt anything and a hanging
# dispatch runs unbounded until the harness kills the call with no verdict —
# #823's failure relocated. macOS ships neither GNU binary, so failing closed
# there would disable the backstop on this repo's primary platform: perl is the
# stand-in, and only when all three are absent may the dispatch be refused.
# The refusal is a genuine last resort (the script prepends /usr/bin:/bin, which
# carries perl), so it is asserted structurally; the perl ARM is exercised live.
# Assert the STRUCTURE, not the prose: the perl arm exists, the fail-closed
# refusal exists, and perl is reached only AFTER the coreutils candidates (so a
# host with real coreutils never silently drops to the stand-in). Keyed on
# _TO_MODE and the refusal's stable clause so a reworded message does not
# masquerade as a missing guard.
ok "$(grep -c '_TO_MODE=perl' "$RL")" "1" "perl stand-in wired"
ok "$(grep -c 'refusing to dispatch an unbounded review' "$RL")" "1" "fail-closed refusal when none of the candidates exists"
_L_CORE=$(grep -n '_TO_MODE=coreutils' "$RL" | head -1 | cut -d: -f1)
_L_PERL=$(grep -n '_TO_MODE=perl' "$RL" | head -1 | cut -d: -f1)
ok "$([[ -n "$_L_CORE" && -n "$_L_PERL" && "$_L_CORE" -lt "$_L_PERL" ]] && echo y || echo n)" "y" "coreutils is preferred over the perl stand-in"
# The perl arm itself, driven directly — PLATFORM-INDEPENDENT. The live
# integration check below can only run where /usr/bin carries no `timeout`
# (macOS), and the script prepends /usr/bin:/bin unconditionally, so on Linux CI
# it always skips: without this the perl arm would be covered nowhere CI runs.
# Extracted from the script rather than restated, so the two cannot drift.
_PERLTO=$(python3 -c '
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"_BS_PERL_TO=\x27(.*?)\n  \x27", src, re.S)
sys.stdout.write(m.group(1) if m else "")
' "$RL")
ok "$([[ -n "$_PERLTO" ]] && echo y || echo n)" "y" "perl wrapper body extractable from the script"
if [[ -n "$_PERLTO" ]]; then
  _t0=$(date +%s)
  perl -e "$_PERLTO" -- 2 /bin/sh -c 'trap "" TERM; sleep 60' >/dev/null 2>&1
  _rc=$?; _el=$(( $(date +%s) - _t0 ))
  ok "$_rc" "124" "perl arm reports a timeout (124) on a TERM-ignoring child"
  # Cancellation, not timeout: signal PERL ITSELF and assert it reaps the child
  # group on the way out. This is the arm the group-handle reap cannot reach --
  # perl does not setpgrp itself, so the caller can only signal it by pid -- and a
  # machine with coreutils installed never exercises it through the live dispatch.
  _CPIDF=$(mktemp -t perlcancel-XXXXXX)
  perl -e "$_PERLTO" -- 60 /bin/sh -c 'trap "" TERM; sleep 90 & echo $! > '"$_CPIDF"'; wait' >/dev/null 2>&1 &
  _PLPID=$!
  for _i in $(seq 1 100); do [[ -s "$_CPIDF" ]] && break; sleep 0.1; done
  _CPID=$(cat "$_CPIDF" 2>/dev/null)
  ok "$([[ -n "$_CPID" ]] && echo y || echo n)" "y" "perl arm: grandchild pid recorded"
  kill -TERM "$_PLPID" 2>/dev/null
  wait "$_PLPID" 2>/dev/null
  sleep 3
  ok "$(kill -0 "$_CPID" 2>/dev/null && echo alive || echo gone)" "gone" "perl arm reaps its child group when the wrapper is cancelled"
  kill -9 "$_CPID" 2>/dev/null || true
  rm -f "$_CPIDF"
  ok "$([[ "$_el" -lt 30 ]] && echo y || echo n)" "y" "perl arm KILLed it after the grace, not after 60s (took ${_el}s)"
fi
# The wrapper must be resolved by ABSOLUTE path, never from the inherited PATH:
# PATH is repo-injectable, and on macOS (no timeout in /usr/bin:/bin) a planted
# `timeout` would otherwise be picked ahead of the trusted /usr/bin/perl and
# could print a forged envelope. Behavioural, not structural: a hostile PATH
# carrying a `timeout` that writes a marker must not run it.
_BADBIN="$WORK/badpath"; mkdir -p "$_BADBIN"
printf '#!/bin/sh\nprintf pwned > "$PWN2_MARKER"\nshift\nexec "$@"\n' > "$_BADBIN/timeout"
cp "$_BADBIN/timeout" "$_BADBIN/gtimeout"
chmod +x "$_BADBIN/timeout" "$_BADBIN/gtimeout"
rm -f "$BS" "$WORK/pwn2-marker"; seed_codex_lead
PWN2_MARKER="$WORK/pwn2-marker" PATH="$_BADBIN:$PATH" \
  STUB_VERDICT='{"status":"PASS","issues":[]}' bash "$RL" --run-backstop >/dev/null 2>&1
ok "$([[ -e "$WORK/pwn2-marker" ]] && echo y || echo n)" "n" "a PATH-planted 'timeout' is never selected as the wrapper"
ok "$(grep -c 'command -v timeout' "$RL")" "0" "wrapper resolution does not consult PATH via command -v"

# The perl arm must run with PERL5OPT/PERL5LIB/PERLLIB stripped. They are
# repo-injectable (#325 / ADR 0016) and load attacker code BEFORE the wrapper
# body runs; a module that prints a forged envelope and exits 0 is
# indistinguishable from a clean dispatch, so the strict writer would persist a
# false PASS. Drives the script's OWN _TO construction (extracted, not
# restated) so it cannot drift, and is platform-independent — unlike the live
# integration case below, which only runs where /usr/bin carries no `timeout`.
_TO_PERL_LINE=$(grep -F '_TO=("${_BS_PERL_ENVSTRIP[@]}"' "$RL" | head -1)
ok "$([[ -n "$_TO_PERL_LINE" ]] && echo y || echo n)" "y" "perl arm is built through the env-strip prefix"
_ENVSTRIP_LINE=$(grep -F '_BS_PERL_ENVSTRIP=(' "$RL" | head -1)
for _v in PERL5OPT PERL5LIB PERLLIB; do
  ok "$(printf '%s' "$_ENVSTRIP_LINE" | grep -c -- "-u $_v")" "1" "env-strip removes $_v"
done
if [[ -n "$_PERLTO" && -n "$_ENVSTRIP_LINE" && -n "$_TO_PERL_LINE" ]]; then
  _PWNDIR="$WORK/perlpwn"; mkdir -p "$_PWNDIR"
  printf 'package Pwn;\nopen(my $f, ">", $ENV{PWN_MARKER}); print $f "pwned"; close $f;\n1;\n' > "$_PWNDIR/Pwn.pm"
  rm -f "$WORK/pwn-marker"
  # Rebuild the arm exactly as the script does, from the extracted lines.
  eval "$_ENVSTRIP_LINE"
  _TO_BIN=perl; _BS_PERL_TO="$_PERLTO"; _bs_remaining=5
  eval "$_TO_PERL_LINE"
  PWN_MARKER="$WORK/pwn-marker" PERL5LIB="$_PWNDIR" PERL5OPT="-MPwn" \
    "${_TO[@]}" /bin/sh -c 'exit 0' >/dev/null 2>&1
  ok "$([[ -e "$WORK/pwn-marker" ]] && echo y || echo n)" "n" "hostile PERL5OPT/PERL5LIB does not execute in the perl arm"
  # Non-vacuity: the SAME hostile env against a bare perl (no strip) must fire,
  # or the assertion above would pass for the wrong reason.
  rm -f "$WORK/pwn-marker"
  PWN_MARKER="$WORK/pwn-marker" PERL5LIB="$_PWNDIR" PERL5OPT="-MPwn" \
    perl -e "$_PERLTO" -- 5 /bin/sh -c 'exit 0' >/dev/null 2>&1
  ok "$([[ -e "$WORK/pwn-marker" ]] && echo y || echo n)" "y" "control: unstripped perl DOES execute the injected module"
  unset _TO _TO_BIN _BS_PERL_TO _bs_remaining _BS_PERL_ENVSTRIP
fi

# Live: a PATH with NO timeout/gtimeout must still bound the hang via perl.
rm -f "$BS"; seed_codex_lead; rm -f "$CF"
_PERLDIR="$WORK/perlonlybin"; mkdir -p "$_PERLDIR"
cp "$STUBDIR/claude" "$_PERLDIR/claude"
if PATH="$_PERLDIR:/usr/bin:/bin" command -v timeout >/dev/null 2>&1 \
   || PATH="$_PERLDIR:/usr/bin:/bin" command -v gtimeout >/dev/null 2>&1; then
  echo "  SKIP  coreutils timeout lives in /usr/bin here — cannot isolate the perl arm"
else
  _t0=$(date +%s)
  STUB_SLEEP=60 STUB_COUNT_FILE="$CF" LITMUS_PR_BACKSTOP_TIMEOUT=2 \
    LITMUS_PR_BACKSTOP_RETRIES=2 STUB_VERDICT='{"status":"PASS","issues":[]}' \
    PATH="$_PERLDIR" /bin/bash "$RL" --run-backstop >/dev/null 2>&1
  _rc=$?; _el=$(( $(date +%s) - _t0 ))
  ok "$_rc" "1" "perl arm: hang fails closed"
  ok "$(has_art)" "n" "perl arm: no artifact on timeout"
  ok "$(cat "$CF" 2>/dev/null)" "1" "perl arm: timeout NOT retried — exactly 1 dispatch"
  ok "$([[ "$_el" -lt 40 ]] && echo y || echo n)" "y" "perl arm bounded the 60s hang (took ${_el}s)"
fi

echo "== 9m. --run-backstop: a straggler holding stdout cannot outrun the budget (#823) =="
# The wrapper stops supervising the moment the direct child is reaped, so a
# descendant that `claude` leaves behind is on no clock at all. While the capture
# went through a PIPE, the surrounding command substitution stayed blocked until
# that descendant closed its end — the dispatch ran for the straggler's lifetime,
# not the budget, and a long enough one puts the call past the harness cap with no
# verdict. Capturing to a regular file removes the wait: the attempt ends when the
# leader ends. Both the exit status and the ELAPSED time discriminate (pre-fix this
# blocked for the full STUB_ORPHAN window).
rm -f "$BS"; seed_codex_lead
# Baseline the capture temps rather than asserting an absolute 0: an unrelated
# leftover in a shared TMPDIR would otherwise fail a run that leaked nothing.
# Counts BOTH per-attempt temps — the capture AND the prompt file (the latter is
# newer than this check). `find` errors are not discarded into a silent `0`: a
# find that cannot run must fail the assertion, not report "nothing leaked".
# (`-maxdepth` is fine on BSD find as well as GNU — verified here.)
_bs_tmps() {
  local _out _rc
  _out=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'busdriver-backstop-env-*' -o -name 'busdriver-backstop-prompt-*' 2>/dev/null); _rc=$?
  # A find that could not run must NOT report "0 leaked". Emit a non-numeric
  # sentinel: the baseline assertion below rejects it, so a broken scan fails
  # visibly instead of comparing 0 with 0 and passing without inspecting anything.
  if [[ "$_rc" -ne 0 ]]; then printf 'SCAN_FAILED'; return 0; fi
  printf '%s' "$_out" | grep -c . | tr -d ' '
}
_tmp0=$(_bs_tmps)
ok "$([[ "$_tmp0" =~ ^[0-9]+$ ]] && echo y || echo n)" "y" "temp-file scan actually ran (baseline is a count)"
_t0=$(date +%s)
STUB_ORPHAN=60 LITMUS_PR_BACKSTOP_TIMEOUT=10 \
  STUB_VERDICT='{"status":"PASS","issues":[]}' bash "$RL" --run-backstop >/dev/null 2>&1
_rc=$?; _el=$(( $(date +%s) - _t0 ))
ok "$_rc" "0" "verdict captured even though the CLI left a descendant behind"
ok "$(art_status "$BS")" "PASS" "PASS artifact written despite the straggler"
ok "$([[ "$_el" -lt 20 ]] && echo y || echo n)" "y" "attempt ended with the leader (plus the reap grace), not the 60s straggler (took ${_el}s)"
# And the capture file must not be left behind in TMPDIR -- the straggler's fd
# keeps the inode alive for its own writes, but the path is unlinked.
ok "$(_bs_tmps)" "$_tmp0" "no capture temp leaked"
# ...and the straggler must be REAPED, not merely outlived. Holding the capture
# descriptor open is what lets it keep writing to an inode nothing can reclaim,
# and a shell cannot revoke an fd it has handed out — so the only available bound
# is ending the process. Signalled as a GROUP: the writer is usually a grandchild.
rm -f "$BS"; seed_codex_lead
_PIDF="$WORK/orphan.pid"; rm -f "$_PIDF"
STUB_ORPHAN=60 STUB_ORPHAN_PID_FILE="$_PIDF" LITMUS_PR_BACKSTOP_TIMEOUT=10 \
  STUB_VERDICT='{"status":"PASS","issues":[]}' bash "$RL" --run-backstop >/dev/null 2>&1
_OPID=$(cat "$_PIDF" 2>/dev/null)
ok "$([[ -n "$_OPID" ]] && echo y || echo n)" "y" "stub recorded the straggler pid"
ok "$(kill -0 "$_OPID" 2>/dev/null && echo alive || echo gone)" "gone" "TERM-ignoring straggler is reaped, not left running"
# Non-vacuity: this straggler shape genuinely survives a plain TERM, so the
# assertion above is proving the KILL escalation and not a self-exiting sleep.
( trap '' TERM; exec sleep 30 ) & _CTLPID=$!
# Settle before signalling. Without it the TERM can arrive before the subshell has
# installed its handler, the straggler dies on the default disposition, and the
# control reports "gone" — failing for a reason that has nothing to do with the
# property under test. (The stub's straggler has no such race: it prints its
# envelope through python3 afterwards, which is far longer than the trap takes.)
sleep 0.5
kill -TERM "$_CTLPID" 2>/dev/null
sleep 1
ok "$(kill -0 "$_CTLPID" 2>/dev/null && echo alive || echo gone)" "alive" "control: a TERM-ignoring straggler DOES survive a plain TERM"
kill -9 "$_CTLPID" 2>/dev/null; wait "$_CTLPID" 2>/dev/null || true

# ...and the reap must also fire when the SCRIPT ITSELF is cancelled mid-wait,
# not only when the dispatch returns on its own. This is the signal path: TERM the
# review-loop process while it is blocked in `wait`, then assert the wrapper's
# group died with it rather than being orphaned still holding the capture.
rm -f "$BS"; seed_codex_lead
_PIDF2="$WORK/orphan-sig.pid"; rm -f "$_PIDF2"
STUB_ORPHAN=60 STUB_ORPHAN_PID_FILE="$_PIDF2" STUB_HANG=30 LITMUS_PR_BACKSTOP_TIMEOUT=60 \
  STUB_VERDICT='{"status":"PASS","issues":[]}' bash "$RL" --run-backstop >/dev/null 2>&1 &
_RLPID=$!
# Wait for the stub to actually record its straggler — signalling before the
# dispatch exists would prove nothing about the trap.
for _i in $(seq 1 100); do [[ -s "$_PIDF2" ]] && break; sleep 0.1; done
_OPID2=$(cat "$_PIDF2" 2>/dev/null)
ok "$([[ -n "$_OPID2" ]] && echo y || echo n)" "y" "signal case: stub recorded the straggler pid"
kill -TERM "$_RLPID" 2>/dev/null
wait "$_RLPID" 2>/dev/null
# Give the reap its TERM->grace->KILL ladder room to complete.
sleep 3
ok "$(kill -0 "$_OPID2" 2>/dev/null && echo alive || echo gone)" "gone" "a cancelled run reaps the dispatch group instead of orphaning it"
kill -9 "$_OPID2" 2>/dev/null || true

echo "== 9n. --run-backstop: an APPENDING straggler cannot stall the read (#823) =="
# 9m's straggler only HOLDS the descriptor; moving the capture to a file is enough
# for that. This one keeps WRITING, which is the harder case: the read happens
# after the wrapper's timer is gone, so an unbounded `cat` sits behind a receding
# EOF — past the budget, and consuming unbounded disk and memory on the way. The
# read must take a bounded snapshot. Asserted on WALL CLOCK, because that is the
# property that actually failed.
rm -f "$BS"; seed_codex_lead; rm -f "$CF"
_t0=$(date +%s)
STUB_ORPHAN_APPEND=20 LITMUS_PR_BACKSTOP_TIMEOUT=10 LITMUS_PR_BACKSTOP_RETRIES=0 \
  STUB_COUNT_FILE="$CF" STUB_VERDICT='{"status":"PASS","issues":[]}' \
  bash "$RL" --run-backstop >/dev/null 2>&1
_rc=$?; _el=$(( $(date +%s) - _t0 ))
# BOUNDED is the property under test; the VERDICT here is correctly refused. An
# appending descendant interleaves its bytes with the leader's, and nothing can
# separate them after the fact — so the envelope no longer parses and the run
# fails closed. That is the right direction for a gate: a capture that an
# uncontrolled process wrote into must never become a PASS artifact. Contrast
# 9m, where the straggler only HOLDS the descriptor, the capture stays clean,
# and the verdict is accepted.
# Smoke bound only — be honest about what it proves. `cat` on a REGULAR file
# stops at the EOF it reaches (unlike a pipe), so a shell-loop appender does not
# stall it and this assertion would pass pre-fix too. The discriminating guards
# are the structural ones below plus the byte check that follows: measured
# against a FAST appender (dd from /dev/zero), an unbounded read pulled 4 GB
# into a shell variable in 21s where the bounded snapshot took 4 MiB in 1s.
ok "$([[ "$_el" -lt 18 ]] && echo y || echo n)" "y" "read ended with the leader, not the 20s appender (took ${_el}s)"
# NO assertion on the verdict here — it is genuinely race-dependent. Whether the
# straggler's bytes land before or after the snapshot decides whether the
# envelope still parses, and BOTH outcomes are correct: a clean snapshot is a
# real PASS, a corrupted one fails closed. Asserting either would flake. The
# deterministic soundness case is 9o, where the padding is emitted by the leader
# itself and the outcome cannot race. What 9n owns is BOUNDEDNESS, above.
# The cap must not be overridable from the environment — it is the bound itself.
ok "$(grep -c '_BS_MAX_ENVELOPE=4194304' "$RL")" "1" "envelope ceiling is a constant, not a tunable"
# The DISK bound is separate from the memory bound and must exist too: the
# envelope ceiling caps what is read, RLIMIT_FSIZE caps what can be written by a
# descendant we cannot revoke. It must sit ABOVE the envelope ceiling, or it
# could kill a capture that would have been accepted.
# No RLIMIT_FSIZE here, by decision rather than omission: `ulimit -f` is per-FILE,
# so it never bounded total disk — it bounded one file we already reject when
# oversize — while applying to EVERY file the CLI writes, so a legitimate session
# transcript past the ceiling would take SIGXFSZ and fail a healthy review.
# Pinned so it cannot come back as an apparent hardening.
ok "$(grep -c '^[^#]*ulimit -f' "$RL")" "0" "no file-size rlimit on the dispatch"
# O(1) size query, never a scanning read: `wc -c` is not guaranteed byte-bounded,
# and where it is not fstat-optimized a fast appender could keep it scanning.
ok "$(grep -c 'wc -c < "\$_bs_out"' "$RL")" "0" "capture size does not come from a scanning wc"
# The dispatch must be backgrounded and waited on — that is the only way the
# wrapper's pid survives as a process-GROUP handle for the reap.
ok "$(grep -c 'wait "\$_bs_pid"' "$RL")" "1" "dispatch is waited on by pid"
ok "$(grep -c 'kill -KILL -- "-\$_p"' "$RL")" "1" "reap escalates to a group KILL"
# ONE implementation of the reap. Two copies were how the EXIT path drifted from
# the dispatch path in the first place.
ok "$(grep -c '^_bs_reap_group()' "$RL")" "1" "the reap has exactly one implementation"
# ...reached from the EXIT trap, which is what covers a CANCELLED run: bash runs
# the EXIT trap even when killed by an untrapped fatal signal (measured on bash
# 3.2.57 and 5.3.15), so no separate TERM/INT/HUP traps are needed and none should
# be added back. The behavioural assertion below is what proves it actually fires.
ok "$(grep -c '_bs_reap_group "\${_bs_pid:-}"' "$RL")" "1" "reap is wired into the EXIT trap"
# The reap must precede the unlink in the EXIT trap: ending the writer is what
# bounds it, and unlinking first just hides the inode while it keeps growing.
ok "$(grep -c "trap '_bs_reap_group \"\${_bs_pid:-}\"; review_lock_release" "$RL")" "1" "EXIT trap reaps before it unlinks"
# The perl arm creates its group inside the fork()ed child, so its pgid is
# invisible to the shell — it must carry the equivalent reap in its own body.
ok "$(grep -c 'kill "KILL", -\$pid' "$RL")" "2" "perl arm reaps its group on BOTH the timeout and normal paths"
# The stdin side must be a file too. A `printf | claude` pipeline puts the writer
# outside the wrapper, and a descendant holding the read end blocks it forever on
# any prompt past the pipe buffer — the same stall, entered from the other end.
ok "$(grep -c "printf '%s' \"\$REVIEW_PROMPT\" | " "$RL")" "0" "no pipeline feeds the dispatch"
ok "$(grep -c '< "\$_bs_in" > "\$_bs_out"' "$RL")" "1" "dispatch reads stdin from a file and writes stdout to a file"
# Behavioural, standalone: a reader that exits without draining, leaving a
# descendant on the read end, blocks a PIPE writer indefinitely while a file
# redirect is unaffected. Proves the premise rather than asserting the shape.
_BIGIN=$(mktemp -t bigprompt-XXXXXX)
head -c 1048576 /dev/zero | tr '\0' 'P' > "$_BIGIN"
_HOLDER="$WORK/holder.sh"
# The descendant must EXPLICITLY re-attach the pipe: bash sends a background
# job's stdin to /dev/null unless told otherwise, so a plain `( … ) &` holds
# nothing and the control would pass for the wrong reason (it did, first try).
printf '#!/bin/bash\nexec 9<&0\n( exec sleep 10 ) 0<&9 &\nexit 0\n' > "$_HOLDER"; chmod +x "$_HOLDER"
_t0=$(date +%s); ( cat "$_BIGIN" | "$_HOLDER" ) >/dev/null 2>&1; _pipe_el=$(( $(date +%s) - _t0 ))
_t0=$(date +%s); "$_HOLDER" < "$_BIGIN" >/dev/null 2>&1;      _file_el=$(( $(date +%s) - _t0 ))
ok "$([[ "$_pipe_el" -ge 5 ]] && echo y || echo n)" "y" "control: a held pipe DOES block the writer (${_pipe_el}s)"
ok "$([[ "$_file_el" -lt 5 ]] && echo y || echo n)" "y" "a file redirect does not block (${_file_el}s)"
rm -f "$_BIGIN"
ok "$(grep -c 'ENVELOPE=$(cat ' "$RL")" "0" "no unbounded cat of the capture file remains"
# The MEMORY bound, asserted on bytes rather than wall clock — at test-safe sizes
# time does not discriminate, but the byte ceiling always does. The cap is read
# out of the script so the two cannot drift.
_CAP=$(grep -o '_BS_MAX_ENVELOPE=[0-9]*' "$RL" | head -1 | cut -d= -f2)
ok "$([[ -n "$_CAP" && "$_CAP" -gt 0 ]] && echo y || echo n)" "y" "envelope cap is readable from the script"
if [[ -n "$_CAP" && "$_CAP" -gt 0 ]]; then
  _BF="$WORK/oversize-capture"
  head -c "$(( _CAP + 65536 ))" /dev/zero | tr '\0' 'X' > "$_BF"
  _WHOLE=$(wc -c < "$_BF" | tr -d '[:space:]')
  _SZ="$_WHOLE"; [[ "$_SZ" -gt "$_CAP" ]] && _SZ="$_CAP"
  _READ=$(head -c "$_SZ" "$_BF" | wc -c | tr -d '[:space:]')
  ok "$([[ "$_WHOLE" -gt "$_CAP" ]] && echo y || echo n)" "y" "control: the capture really is larger than the cap"
  ok "$([[ "$_READ" -le "$_CAP" ]] && echo y || echo n)" "y" "the read never exceeds the cap"
  rm -f "$_BF"
fi

echo "== 9o. --run-backstop: an oversize capture is REJECTED, not truncated (#823) =="
# Truncating at the ceiling is unsound, not merely lossy: the first N bytes can be
# a COMPLETE valid envelope followed by more content, so a truncating reader would
# parse a clean PASS and silently discard whatever else was written. The stub emits
# a valid envelope and then pads far past the cap; the run must fail closed.
rm -f "$BS"; seed_codex_lead
STUB_PAD=1 LITMUS_PR_BACKSTOP_RETRIES=0 STUB_VERDICT='{"status":"PASS","issues":[]}' \
  bash "$RL" --run-backstop >/dev/null 2>&1
ok "$?" "1" "oversize capture fails closed"
ok "$(has_art)" "n" "no PASS artifact from a valid-prefix oversize capture"
# The NUL variant, UNDER the ceiling — so the size branch cannot be what rejects
# it. Bash drops NULs from a command substitution, so routing the capture through
# a shell variable turned "valid envelope + NUL padding" back into a clean PASS.
# Piping the file straight into the parser is what makes this fail closed.
rm -f "$BS"; seed_codex_lead
STUB_NULPAD=1 LITMUS_PR_BACKSTOP_RETRIES=0 STUB_VERDICT='{"status":"PASS","issues":[]}' \
  bash "$RL" --run-backstop >/dev/null 2>&1
ok "$?" "1" "NUL-padded capture fails closed"
ok "$(has_art)" "n" "no PASS artifact from a NUL-padded capture"
ok "$(grep -c 'printf .%s. "\$ENVELOPE" | python3' "$RL")" "0" "capture is not round-tripped through a shell variable"
# An oversize capture must be TERMINAL: retrying is a fresh paid dispatch that can
# leave another growing capture behind, multiplying the condition the ceiling
# limits. With retries ALLOWED, exactly one dispatch must still happen.
rm -f "$BS"; seed_codex_lead; rm -f "$CF"
STUB_PAD=1 STUB_COUNT_FILE="$CF" LITMUS_PR_BACKSTOP_RETRIES=2 \
  STUB_VERDICT='{"status":"PASS","issues":[]}' bash "$RL" --run-backstop >/dev/null 2>&1
ok "$?" "1" "oversize capture still fails closed with retries available"
ok "$(cat "$CF" 2>/dev/null)" "1" "oversize is terminal — exactly 1 dispatch, not 3"
# ...but an EMPTY capture is TRANSIENT and must still be retried. Sharing a branch
# with oversize aborted it on attempt 1 with retries unused, and stole the
# timeout's diagnostic in the case that produces it.
rm -f "$BS"; seed_codex_lead; rm -f "$CF"
STUB_SILENT=1 STUB_COUNT_FILE="$CF" LITMUS_PR_BACKSTOP_RETRIES=2 \
  STUB_VERDICT='{"status":"PASS","issues":[]}' bash "$RL" --run-backstop >/dev/null 2>&1
ok "$?" "1" "an empty capture still fails closed once retries are exhausted"
ok "$(cat "$CF" 2>/dev/null)" "3" "empty is TRANSIENT — retried to 3 dispatches, not terminal at 1"

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
