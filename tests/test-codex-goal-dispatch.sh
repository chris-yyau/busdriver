#!/usr/bin/env bash
# tests/test-codex-goal-dispatch.sh
#
# Verifies scripts/codex/codex-goal-dispatch.sh — the runtime executor for the
# codex-goal-handover skill. The dispatcher is the trust boundary between Codex's
# self-reported files_changed / intended_commit_message and the real git history;
# its fail-closed exit codes are the primary safety rail for the handover loop.
# Before this test the 784-line script had zero coverage (issue #378).
#
# `codex` is stubbed (a fake on PATH). The dispatcher invokes
# `codex exec ... -o RESULT_FILE`, so the stub extracts the `-o` target, performs
# the file mutations "codex made" (CODEX_STUB_MUTATE), and writes canned schema
# output (CODEX_STUB_RESULT) — no real CLI, no network. Each case runs in a fresh
# throwaway git repo so we can assert on real git state (HEAD, commit message) and
# the documented exit codes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DISPATCH="$SCRIPT_DIR/scripts/codex/codex-goal-dispatch.sh"

passed=0; failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

[ -f "$DISPATCH" ] || { fail "missing $DISPATCH"; echo "Results: $passed passed, $failed failed"; exit 1; }
command -v jq >/dev/null 2>&1 || { fail "jq required to run this test"; echo "Results: $passed passed, $failed failed"; exit 1; }

# Single temp root; children live under it so cleanup is one recursive rm. mk is
# called via `$(mk)` command substitution — a per-dir array append would run in
# that subshell and be lost, so the EXIT trap would leak every dir. A shared root
# sidesteps the subshell entirely.
TMP_ROOT=$(mktemp -d)
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
mk() { mktemp -d "$TMP_ROOT/case.XXXXXX"; }

# A fake `codex`: parse `-o <path>`, optionally mutate the working tree
# (CODEX_STUB_MUTATE, eval'd in the repo CWD), then write CODEX_STUB_RESULT's
# JSON to the -o target unless CODEX_STUB_WRITE=0. Exit CODEX_STUB_EXIT (default 0).
BIN="$(mk)"
cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
[ -n "${CODEX_STUB_MUTATE:-}" ] && eval "$CODEX_STUB_MUTATE"
if [ "${CODEX_STUB_WRITE:-1}" = "1" ] && [ -n "$out" ]; then
  cat "${CODEX_STUB_RESULT:?}" > "$out"
fi
exit "${CODEX_STUB_EXIT:-0}"
STUB
chmod +x "$BIN/codex"

# Fresh git repo with one seed commit so HEAD resolves. Echoes the repo path.
new_repo() {
  local d; d=$(mk)
  git -C "$d" init -q
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name Test
  git -C "$d" config commit.gpgsign false
  # Keep the test's scratch files (canned response, result file + its sidecars,
  # stderr log) out of `git status` so they don't trip the dispatcher's own
  # clean-tree precondition. --exclude-standard honors .git/info/exclude, so the
  # pre-dirty / unclaimed / ignored scanners all skip them too.
  printf '%s\n' '.canned.json' '.result.json*' '.err.log' > "$d/.git/info/exclude"
  echo seed > "$d/seed.txt"
  git -C "$d" add seed.txt
  git -C "$d" commit -qm seed
  printf '%s' "$d"
}

# Run the dispatcher in repo $1 with the case env vars (result/mutate/write/cexit;
# plus optional allow_dirty / allow_unclaimed to exercise the documented bypass
# env vars). Sets globals RC and LOG. Named vars are used rather than positional
# KEY=val args because bash does not re-recognize a `"$@"`-expanded `VAR=val` as
# an assignment — it becomes a bogus command word instead.
run_dispatch() {
  local repo="$1"
  LOG="$repo/.err.log"
  RC=0
  ( cd "$repo" && PATH="$BIN:$PATH" \
      CODEX_STUB_RESULT="${result:-}" CODEX_STUB_MUTATE="${mutate:-}" \
      CODEX_STUB_WRITE="${write:-1}" CODEX_STUB_EXIT="${cexit:-0}" \
      BUSDRIVER_CODEX_ALLOW_DIRTY_TREE="${allow_dirty:-}" \
      BUSDRIVER_CODEX_ALLOW_UNCLAIMED="${allow_unclaimed:-}" \
      bash "$DISPATCH" --result-file "$repo/.result.json" -- "do the thing" \
  ) >/dev/null 2>"$LOG" || RC=$?
}

# Write a canned schema response to the repo and point `result` at it.
write_result() { printf '%s' "$2" > "$1/.canned.json"; result="$1/.canned.json"; }

# ============================================================
# 1. HAPPY PATH — clean tree, one declared+created file, real commit → exit 0,
#    HEAD advances, commit message matches, dispatcher injects committed=true.
# ============================================================
R=$(new_repo)
write_result "$R" '{"summary":"add hello","self_assessed_status":"complete","blocker":null,"files_changed":["hello.txt"],"intended_commit_message":"feat: add hello"}'
mutate='echo hi > hello.txt'
PRE=$(git -C "$R" rev-parse HEAD)
run_dispatch "$R"
POST=$(git -C "$R" rev-parse HEAD)
if [ "$RC" -eq 0 ] && [ "$PRE" != "$POST" ] \
   && [ "$(git -C "$R" log -1 --format=%s)" = "feat: add hello" ] \
   && jq -e '.committed == true and (.commit_sha | type == "string")' "$R/.result.json" >/dev/null 2>&1; then
  ok "happy path: exit 0, commit landed with intended message, committed=true injected"
else
  fail "happy path (rc=$RC pre=$PRE post=$POST msg=$(git -C "$R" log -1 --format=%s 2>/dev/null))"
fi
unset mutate result write cexit

# ============================================================
# 2. EXIT 4 — dirty tree at entry is refused; BUSDRIVER_CODEX_ALLOW_DIRTY_TREE=1
#    bypasses it (codex runs a no-op iter → exit 0).
# ============================================================
R=$(new_repo)
echo dirt >> "$R/seed.txt"   # pre-existing modification
write_result "$R" '{"summary":"noop","self_assessed_status":"complete","blocker":null,"files_changed":[],"intended_commit_message":null}'
run_dispatch "$R"
[ "$RC" -eq 4 ] && ok "exit 4: dirty tree refused" || fail "exit 4: expected 4 on dirty tree, got $RC"

allow_dirty=1 run_dispatch "$R"
[ "$RC" -eq 0 ] && ok "exit 4 bypass: BUSDRIVER_CODEX_ALLOW_DIRTY_TREE=1 proceeds" \
  || fail "exit 4 bypass: expected 0, got $RC ($(tail -1 "$LOG"))"
unset mutate result write cexit allow_dirty allow_unclaimed

# ============================================================
# 3. EXIT 3 — codex modifies a file NOT in files_changed (still dirty after the
#    scoped commit) → out-of-scope detection; BUSDRIVER_CODEX_ALLOW_UNCLAIMED=1
#    downgrades to informative-only (exit 0).
# ============================================================
R=$(new_repo)
write_result "$R" '{"summary":"a plus stray b","self_assessed_status":"complete","blocker":null,"files_changed":["a.txt"],"intended_commit_message":"feat: a"}'
mutate='echo a > a.txt; echo b > b.txt'
run_dispatch "$R"
if [ "$RC" -eq 3 ] && jq -e '.unclaimed_changes | index("b.txt")' "$R/.result.json" >/dev/null 2>&1; then
  ok "exit 3: out-of-scope file detected and recorded in unclaimed_changes"
else
  fail "exit 3: expected 3 with b.txt unclaimed, got $RC"
fi
# Fresh repo — the first run left b.txt dirty, which would trip the clean-tree
# precondition (exit 4) before the unclaimed logic is reached.
R=$(new_repo)
write_result "$R" '{"summary":"a plus stray b","self_assessed_status":"complete","blocker":null,"files_changed":["a.txt"],"intended_commit_message":"feat: a"}'
mutate='echo a > a.txt; echo b > b.txt'
allow_unclaimed=1 run_dispatch "$R"
[ "$RC" -eq 0 ] && ok "exit 3 bypass: BUSDRIVER_CODEX_ALLOW_UNCLAIMED=1 downgrades to exit 0" \
  || fail "exit 3 bypass: expected 0, got $RC ($(tail -1 "$LOG"))"
unset mutate result write cexit allow_dirty allow_unclaimed

# ============================================================
# 4. EXIT 5 — a declared file that does not exist on disk fails staging;
#    the dispatcher fails closed rather than committing a partial set.
# ============================================================
R=$(new_repo)
write_result "$R" '{"summary":"ghost","self_assessed_status":"complete","blocker":null,"files_changed":["ghost.txt"],"intended_commit_message":"feat: ghost"}'
mutate=''   # never create ghost.txt
run_dispatch "$R"
if [ "$RC" -eq 5 ] && [ "$(git -C "$R" rev-list --count HEAD)" -eq 1 ]; then
  ok "exit 5: unstageable declared file fails closed, no commit"
else
  fail "exit 5: expected 5 with no commit, got $RC commits=$(git -C "$R" rev-list --count HEAD) ($(tail -1 "$LOG"))"
fi
unset mutate result write cexit

# ============================================================
# 5. EXIT 2 — schema-invalid response, and separately a missing result file.
# ============================================================
R=$(new_repo)
write_result "$R" '{"not":"the schema"}'
mutate=''
run_dispatch "$R"
[ "$RC" -eq 2 ] && ok "exit 2: schema-invalid codex response rejected" \
  || fail "exit 2 (schema): expected 2, got $RC"
unset mutate result write cexit

R=$(new_repo)
mutate=''
write=0 run_dispatch "$R"   # stub exits 0 but writes no result file
[ "$RC" -eq 2 ] && ok "exit 2: missing result file rejected" \
  || fail "exit 2 (missing file): expected 2, got $RC"
unset mutate result write cexit

# ============================================================
# 6. NUL-byte path smuggling — a files_changed entry containing an embedded NUL
#    (the literal 6-char \u0000 escape, which jq decodes to a NUL byte) is skipped
#    with a warning and NEVER committed; the sibling real file still commits
#    (exit 0). Guards against splitting one declared path into two via NUL.
# ============================================================
R=$(new_repo)
write_result "$R" '{"summary":"good plus nul","self_assessed_status":"complete","blocker":null,"files_changed":["good.txt","ev\u0000il.txt"],"intended_commit_message":"feat: good"}'
mutate='echo g > good.txt'
run_dispatch "$R"
if [ "$RC" -eq 0 ] \
   && grep -q 'NUL byte' "$LOG" \
   && git -C "$R" cat-file -e "HEAD:good.txt" 2>/dev/null \
   && [ "$(git -C "$R" ls-tree --name-only HEAD | grep -c 'il.txt')" -eq 0 ]; then
  ok "NUL smuggling: NUL-bearing path skipped+warned, sibling committed, no phantom path"
else
  fail "NUL smuggling: rc=$RC warn=$(grep -c 'NUL byte' "$LOG" 2>/dev/null) tree=$(git -C "$R" ls-tree --name-only HEAD | tr '\n' ' ')"
fi
unset mutate result write cexit

# ============================================================
# 7. EXIT 1 — codex CLI itself exits non-zero → dispatcher propagates exit 1.
# ============================================================
R=$(new_repo)
mutate=''
cexit=1 write=0 run_dispatch "$R"
[ "$RC" -eq 1 ] && ok "exit 1: non-zero codex exec propagated" \
  || fail "exit 1: expected 1, got $RC"
unset mutate result write cexit

echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
