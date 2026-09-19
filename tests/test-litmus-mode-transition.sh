#!/usr/bin/env bash
# tests/test-litmus-mode-transition.sh — settled FAIL → other-mode transition (#847).
#
# Drives the real init-review-loop.sh and run-review-loop.sh in throwaway repos with a
# mock `agy` reviewer (no provider is contacted). PR-mode reviews need a Codex lead, so a
# settled PR FAIL is reproduced by a real PR-mode init plus exactly what a PR FAIL run
# leaves behind (one attempt, FAIL verdict, findings history); commit-mode runs are real.
#
# LITMUS_TRANSITION_SRC=<tree> runs the suite against another copy of the scripts — used
# to show it fails before the fix.
#
# Usage: bash tests/test-litmus-mode-transition.sh
#
# shellcheck disable=SC2034,SC2209  # locals are read inside eval'd check expressions; INIT/RUN are functions
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${LITMUS_TRANSITION_SRC:-$REPO_ROOT}"
PASS=0; FAIL=0
ok()  { printf "  PASS  %s\n" "$1"; PASS=$((PASS + 1)); }
bad() {
    printf "  FAIL  %s\n" "$1"; FAIL=$((FAIL + 1))
    # Show what the runner said last in this sandbox — the checks only see its results.
    [ -s "${S:-}/.mock/run.log" ] && tail -n 12 "$S/.mock/run.log" | sed 's/^/        | /'
    return 0
}
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

ROOT=$(mktemp -d) || exit 1
[ -d "$ROOT" ] || exit 1
trap 'cd /; rm -rf "$ROOT"' EXIT

ISSUE='{"file":"test_target.txt","line":1,"severity":"high","category":"bug","description":"deterministic transition-test issue","suggestion":"none","confidence":95}'

new_sandbox() {
    S=$(mktemp -d "$ROOT/sb.XXXXXX")
    cd "$S" || exit 1
    git init -q .; git config user.email t@t.com; git config user.name t; git config commit.gpgsign false
    mkdir -p .claude .mock skills/litmus/scripts/lib skills/blueprint-review/scripts/lib scripts/lib
    cp -r "$SRC"/skills/litmus/scripts/. skills/litmus/scripts/
    cp -r "$SRC"/scripts/lib/. scripts/lib/
    cp "$SRC/skills/blueprint-review/scripts/lib/extract_review_json.py" skills/blueprint-review/scripts/lib/
    echo base > seed.txt; git add seed.txt; git commit -q -m seed
    echo "test content" > test_target.txt; git add test_target.txt
    echo fail > .mock/mode
    # The runner rebuilds its environment, so the mock reads its behaviour from files.
    # The binary lives OUTSIDE the repository: CLI resolution does not take a reviewer
    # from inside the tree under review.
    mkdir -p "$S.bin"
    cat > "$S.bin/agy" <<MOCK
#!/usr/bin/env bash
{ cat; printf '%s\n' "\$@"; } > "$S/.mock/prompt"   # what the reviewer was shown (stdin or --print argv)
echo "call \${1:-}" >> "$S/.mock/calls"    # first argument only: the prompt spans lines
MODE=\$(cat "$S/.mock/mode")
# Only a REVIEW dispatch kills the runner. CLI resolution probes \`agy --version\` first, and
# a probe that killed the runner would die before the review child even exists — which is
# the child the reap regression below is about.
if [ "\$MODE" = kill ] && [ "\${1:-}" != --version ]; then
    # Signal the runner mid-review: it is the process holding the review lock. SIGKILL by
    # default; .mock/killsig selects a CATCHABLE signal instead, which is a different
    # containment path — SIGKILL runs no EXIT trap, TERM/INT/HUP do.
    kill -"\$(cat "$S/.mock/killsig" 2>/dev/null || echo 9)" "\$(readlink "$S/.claude/litmus-review.lock" | sed -E 's/^pid-([0-9]+)-.*/\1/')"
    # Still running after the runner died. A reaped child never reaches the marker below.
    sleep 2
    : > "$S/.mock/orphan-alive"
fi
if [ "\$MODE" = block ]; then
    # Hold the review open until the test has interleaved its callers.
    : > "$S/.mock/blocked"; i=0
    while [ ! -e "$S/.mock/release" ] && [ "\$i" -lt 1200 ]; do sleep 0.1; i=\$((i + 1)); done
    # A different finding, so the completed review settles as review_findings, not a stall.
    printf '%s\n' '{"status":"FAIL","issues":[$ISSUE]}' | sed 's/deterministic/in-flight/'; exit 0
fi
[ "\$MODE" = pass ] && { printf '%s\n' '{"status":"PASS","issues":[]}'; exit 0; }
printf '%s\n' '{"status":"FAIL","issues":[$ISSUE]}'
MOCK
    chmod +x "$S.bin/agy"
}

INIT() { PATH="$S.bin:$PATH" bash "$S/skills/litmus/scripts/init-review-loop.sh" "$@"; }
RUN() {
    PATH="$S.bin:$PATH" BUSDRIVER_REVIEW_CLI=agy CLAUDE_PLUGIN_ROOT="$S" LITMUS_SKIP_SAST=1 \
    LITMUS_SKIP_CONTEXT=1 LITMUS_SKIP_MARKDOWN=1 LITMUS_DOCS_CONTEXT=0 LITMUS_SHORTCIRCUIT_DISABLED=1 \
    bash "$S/skills/litmus/scripts/run-review-loop.sh" "$@" >> "$S/.mock/run.log" 2>&1
}
fm() { grep -E "^$1:" .claude/litmus-state.md 2>/dev/null | head -1 | sed -E "s/^$1:[[:space:]]*//; s/\"//g"; }
LEDGER=.claude/litmus-lineage.local.jsonl
HIST=.claude/litmus-iteration-history.local.jsonl
count() { local n; n=$(grep -c "\"event\": \"$1\"" "$LEDGER" 2>/dev/null) || true; echo "${n:-0}"; }
# Review dispatches only: CLI resolution may first probe `agy --version`, which reviews nothing.
calls() { local n; n=$(grep -vc -- ' --version$' .mock/calls 2>/dev/null) || true; [ "${n:-0}" = 0 ] || echo "$n"; }

# setfm key=value... — rewrite frontmatter fields in place (insert when absent).
setfm() {
    python3 - "$@" <<'PY'
import sys
p = ".claude/litmus-state.md"
lines = open(p).read().split("\n")
end = lines.index("---", 1)
for kv in sys.argv[1:]:
    k, _, v = kv.partition("=")
    for i in range(1, end):
        if lines[i].startswith(k + ":"):
            lines[i] = k + ": " + v
            break
    else:
        lines.insert(end, k + ": " + v)
        end += 1
open(p, "w").write("\n".join(lines))
PY
}
# ledger_add key=value... — append a record shaped like the scripts' own.
ledger_add() {
    python3 - "$@" <<'PY'
import json, sys
rec = {}
for kv in sys.argv[1:]:
    k, _, v = kv.partition("=")
    rec[k] = int(v) if v.isdigit() and k in ("iteration", "max_iterations") else v
open(".claude/litmus-lineage.local.jsonl", "a").write(json.dumps(rec, sort_keys=True) + "\n")
PY
}
# The lineage_key the scripts compute for this sandbox: <root commit>@<branch>.
LKEY() { printf '%s@%s\n' "$(git rev-list --max-parents=0 HEAD | sort | head -1)" "$(git symbolic-ref --short HEAD)"; }
# A settled PR FAIL: real PR-mode init, then what one FAIL run leaves behind.
make_pr_fail() {  # $1 reviewed hash, $2 max_iterations
    LITMUS_MODE=pr INIT "${2:-10}" >/dev/null 2>&1
    ledger_add event=attempt "lineage_id=$(fm lineage_id)" "cycle_id=$(fm cycle_id)" iteration=1 "reviewed_diff_hash=$1"
    setfm iteration=2 'review_status="FAIL"' 'terminal_status="review_findings"' "reviewed_diff_hash=\"$1\"" attempts_consumed=1
    printf '{"iteration": 1, "status": "FAIL", "issues": [%s]}\n' "$ISSUE" > "$HIST"
}

echo "── 1. Filed reproduction: settled PR FAIL → commit init, no --force"
new_sandbox
make_pr_fail deadbeef
OLD=$(fm cycle_id); LIN=$(fm lineage_id); SUM=$(shasum -a 256 < "$HIST")
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "transition exits 0" '[ "$rc" = 0 ]'
check "mode is now commit" '[ "$(fm review_mode)" = commit ]'
check "iteration is not reset" '[ "$(fm iteration)" = 2 ]'
check "new cycle id, same lineage" '[ -n "$OLD" ] && [ "$(fm cycle_id)" != "$OLD" ] && [ "$(fm lineage_id)" = "$LIN" ]'
check "findings history archived byte-exact" '[ ! -e "$HIST" ] && [ "$(shasum -a 256 < "$HIST.$OLD.retired")" = "$SUM" ]'
check "one retire naming the installed successor" '[ "$(count retire)" = 1 ] && grep -q "\"successor_cycle_id\": \"$(fm cycle_id)\"" "$LEDGER"'
check "retirement mints no gate marker" '! ls .claude | grep -q "passed.local"'

echo "── 2. Runner after the transition: one debit per dispatch, changed candidate starts cold"
rc=0; RUN >/dev/null 2>&1 || rc=$?
check "review of the correction runs and records findings" '[ "$(fm terminal_status)" = review_findings ]'
check "lineage now holds exactly two attempts" '[ "$(count attempt)" = 2 ]'
check "reviewed_diff_hash persisted on FAIL" '[ -n "$(fm reviewed_diff_hash)" ] && [ "$(fm reviewed_diff_hash)" != null ]'
check "cycle attempts_consumed written explicitly" '[ "$(fm attempts_consumed)" = 1 ]'

echo "── 3. Ceiling folds over the lineage and cannot be raised"
new_sandbox
make_pr_fail deadbeef 2
ledger_add event=attempt "lineage_id=$(fm lineage_id)" "cycle_id=$(fm cycle_id)" iteration=1 reviewed_diff_hash=deadbeef
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "successor keeps the minimum ceiling" '[ "$rc" = 0 ] && [ "$(fm max_iterations)" = 2 ]'
rc=0; RUN >/dev/null 2>&1 || rc=$?
check "a killed-run re-dispatch already spent the ceiling: refused" '[ "$rc" != 0 ] && [ "$(fm terminal_status)" = max_iterations ]'
check "refusal dispatched nothing and debited nothing" '[ -z "$(calls)" ] && [ "$(count attempt)" = 2 ]'
check "exhausted lineage stays active" '[ "$(fm active)" = true ]'
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "exhausted: an ordinary init cannot open a fresh lineage over it" '[ "$rc" != 0 ] && [ "$(count open)" = 1 ]'
rc=0; RUN --auto-pr-review >/dev/null 2>&1 || rc=$?
check "exhausted: --auto-pr-review cannot buy a fresh budget either" '[ "$rc" != 0 ] && [ "$(count open)" = 1 ] && [ -z "$(calls)" ]'
new_sandbox
INIT 10 >/dev/null 2>&1; setfm iteration=11
rc=0; RUN >/dev/null 2>&1 || rc=$?
check "identity cycle past its own ceiling: refused and kept active" '[ "$rc" != 0 ] && [ "$(fm terminal_status)" = max_iterations ] && [ "$(fm active)" = true ]'
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "past its own ceiling: an ordinary init cannot open a fresh lineage" '[ "$rc" != 0 ] && [ "$(count open)" = 1 ]'

echo "── 4. Killed run: the re-dispatch is charged once, a refused re-run is not"
new_sandbox
INIT 10 >/dev/null 2>&1
echo kill > .mock/mode
RUN >/dev/null 2>&1
check "killed dispatch was charged" '[ "$(count attempt)" = 1 ]'
rm -f .claude/litmus-review.lock    # the documented human remedy for an orphaned lock
echo fail > .mock/mode
RUN >/dev/null 2>&1
check "resumed run that dispatches is charged exactly once more" '[ "$(count attempt)" = 2 ] && [ "$(grep -c "\"iteration\": 1" "$LEDGER")" = 2 ]'
git reset -q
RUN >/dev/null 2>&1
check "re-run refused before dispatch (nothing staged) is not charged" '[ "$(count attempt)" = 2 ]'

echo "── 5. Refusals leave state and ledger untouched"
refuses() {  # $1 label, $2 stderr fragment (may be empty)
    local sum rc=0 out why="$2"
    sum=$(shasum -a 256 < .claude/litmus-state.md)
    out=$(INIT 10 2>&1) || rc=$?
    check "$1: refused" '[ "$rc" != 0 ]'
    check "$1: state unchanged, no retire" '[ "$(shasum -a 256 < .claude/litmus-state.md)" = "$sum" ] && [ "$(count retire)" = 0 ]'
    [ -z "$why" ] || check "$1: says why" 'printf "%s" "$out" | grep -q "$why"'
}
for t in stall max_iterations setup_error too_large infra_failure; do
    new_sandbox; make_pr_fail deadbeef; setfm "terminal_status=\"$t\""; refuses "$t" ""
done
new_sandbox; LITMUS_MODE=pr INIT 10 >/dev/null 2>&1; refuses "PENDING" ""
new_sandbox
printf -- '---\nactive: true\niteration: 2\nmax_iterations: 10\ncompletion_promise: null\nreview_mode: "pr"\nreview_status: "FAIL"\nstarted_at: "x"\nlast_result: null\nterminal_status: "review_findings"\n---\nbody\n' > .claude/litmus-state.md
refuses "legacy state without identity" "no cycle_id"
new_sandbox; make_pr_fail deadbeef; rm -f "$LEDGER"; refuses "identity with missing ledger" "missing or empty ledger"
new_sandbox; make_pr_fail deadbeef; : > "$LEDGER"; refuses "identity with empty ledger" "missing or empty ledger"
new_sandbox; make_pr_fail deadbeef; mv "$LEDGER" .claude/real.jsonl; ln -s real.jsonl "$LEDGER"; refuses "symlinked ledger" "not a regular file"
# An accounting record the fold cannot attribute must fail closed, not vanish from the count.
new_sandbox; make_pr_fail deadbeef; printf '{"cycle_id": "%s", "event": "attempt", "iteration": 1}\n' "$(fm cycle_id)" >> "$LEDGER"
refuses "attempt record without lineage_id" "corrupt"
# A FIFO at the ledger path must be refused, not block the open while the lock is held.
bounded() {  # run "$@" for at most 10s; 124 when it had to be killed
    "$@" & local p=$! i=0
    while kill -0 "$p" 2>/dev/null; do
        i=$((i + 1)); [ "$i" -gt 100 ] && { kill -9 "$p"; (exec 3<> "$LEDGER"; sleep 1) & wait "$p" 2>/dev/null; return 124; }  # O_RDWR releases a blocked reader or writer
        sleep 0.1
    done
    wait "$p"
}
new_sandbox; make_pr_fail deadbeef; rm -f "$LEDGER"; mkfifo "$LEDGER"
sum=$(shasum -a 256 < .claude/litmus-state.md); rc=0; bounded INIT 10 > .mock/out 2>&1 || rc=$?
check "FIFO ledger, settled FAIL: init refuses without blocking" '[ "$rc" != 0 ] && [ "$rc" != 124 ] && [ "$(shasum -a 256 < .claude/litmus-state.md)" = "$sum" ] && grep -q "not a regular file" .mock/out'
new_sandbox; mkfifo "$LEDGER"
rc=0; bounded INIT 10 > .mock/out 2>&1 || rc=$?
check "FIFO ledger, fresh init: the append refuses without blocking" '[ "$rc" != 0 ] && [ "$rc" != 124 ] && [ ! -e .claude/litmus-state.md ]'
new_sandbox; INIT 10 >/dev/null 2>&1; printf '{"event": "attempt", "lineage_id": "%s", "cycle_id": "%s"}\n' "$(fm lineage_id)" "$(fm cycle_id)" >> "$LEDGER"
rc=0; RUN >/dev/null 2>&1 || rc=$?
check "attempt record without iteration: runner refuses to dispatch" '[ "$rc" != 0 ] && [ "$(fm terminal_status)" = setup_error ] && [ -z "$(calls)" ]'

echo "── 6. Crash between the journal and the install re-installs the same successor"
new_sandbox
make_pr_fail deadbeef
OLD=$(fm cycle_id)
ledger_add event=retire "lineage_id=$(fm lineage_id)" "cycle_id=$OLD" successor_cycle_id=feedfacefeedface \
    target_mode=commit max_iterations=10 iteration=2 reviewed_diff_hash=deadbeef "lineage_key=$(LKEY)"
mv "$HIST" "$HIST.$OLD.retired"    # crash landed after the archive rename, too
sum=$(shasum -a 256 < .claude/litmus-state.md)
rc=0; out=$(LITMUS_MODE=pr INIT 7 2>&1) || rc=$?
check "an init for the other mode does not install the commit successor" '[ "$rc" != 0 ] && [ "$(shasum -a 256 < .claude/litmus-state.md)" = "$sum" ] && [ "$(fm cycle_id)" = "$OLD" ] && [ "$(count retire)" = 1 ]'
check "the refusal names the journalled mode" 'printf "%s" "$out" | grep -q "journalled into mode=commit"'
rc=0; INIT 7 >/dev/null 2>&1 || rc=$?
check "an init for the journalled mode installs it with the journalled ceiling" '[ "$rc" = 0 ] && [ "$(fm cycle_id)" = feedfacefeedface ] && [ "$(fm review_mode)" = commit ] && [ "$(fm max_iterations)" = 10 ]'
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "retry after the install is a no-op success" '[ "$rc" = 0 ] && [ "$(fm cycle_id)" = feedfacefeedface ] && [ "$(count retire)" = 1 ]'

echo "── 7. Stall memory crosses a retirement only for an identical candidate"
stall_case() {  # $1 = same|changed, $2 = first run on the identical candidate: killed|own
    new_sandbox
    INIT 10 >/dev/null 2>&1
    RUN >/dev/null 2>&1                            # real commit FAIL records the hash
    H=$(fm reviewed_diff_hash)
    LITMUS_MODE=pr INIT 10 >/dev/null 2>&1         # commit → pr
    ledger_add event=attempt "lineage_id=$(fm lineage_id)" "cycle_id=$(fm cycle_id)" iteration=2 "reviewed_diff_hash=$H"
    setfm iteration=3 'review_status="FAIL"' 'terminal_status="review_findings"' "reviewed_diff_hash=\"$H\""
    printf '{"iteration": 2, "status": "FAIL", "issues": [%s]}\n' "$ISSUE" > "$HIST"
    INIT 10 >/dev/null 2>&1                        # pr → commit
    case "${2:-}" in
        # seeded, charged, no verdict. SIGKILL takes only the runner: its orphaned review subshell
        # still reaches the mock and rewrites .mock/prompt ~2s later, so wait (bounded) for it.
        killed) echo kill > .mock/mode; RUN >/dev/null 2>&1; rm -f .claude/litmus-review.lock
                for _ in $(seq 50); do pgrep -f "$S/" >/dev/null || break; sleep 0.2; done ;;
        own) echo block > .mock/mode; touch .mock/release; RUN >/dev/null 2>&1 ;;                   # seeded, then an own FAIL verdict
    esac
    echo fail > .mock/mode
    [ "$1" = changed ] && { echo more >> test_target.txt; git add test_target.txt; }
    RUN >/dev/null 2>&1
}
stall_case same
check "unchanged candidate: same findings are a stall" '[ -n "$H" ] && [ "$(fm terminal_status)" = stall ]'
check "unchanged candidate: the reviewer was shown the inherited findings it stalls on" 'grep -q "deterministic transition-test issue" .mock/prompt'
stall_case changed
check "changed candidate starts cold" '[ "$(fm terminal_status)" = review_findings ]'
check "changed candidate: no inherited findings in the prompt" '! grep -q "deterministic transition-test issue" .mock/prompt'
stall_case changed killed
check "a SIGKILLed runner reaps its review child instead of leaving it running" '[ ! -e .mock/orphan-alive ]'
check "changed after a charged no-verdict dispatch: the killed attempt was charged" '[ "$(count attempt)" = 4 ]'
check "changed after a charged no-verdict dispatch: starts cold, not stalled on the retired cycle" '[ "$(fm terminal_status)" = review_findings ]'
check "changed after a charged no-verdict dispatch: no inherited findings in the prompt" '! grep -q "deterministic transition-test issue" .mock/prompt'
stall_case changed own
check "changed after an own FAIL: the own verdict is kept, history not cleared" '[ "$(fm terminal_status)" = review_findings ] && grep -q "in-flight transition-test issue" "$HIST" && [ "$(grep -c . "$HIST")" = 3 ]'

# The seeding is re-checked on EVERY run, not just the successor's first: a charged dispatch
# that recorded no verdict (killed) on a CHANGED candidate must not cost the inherited
# findings when the candidate comes back byte-identical to the retired one.
new_sandbox
INIT 10 >/dev/null 2>&1
RUN >/dev/null 2>&1                                     # real commit FAIL records the hash
H=$(fm reviewed_diff_hash)
LITMUS_MODE=pr INIT 10 >/dev/null 2>&1
ledger_add event=attempt "lineage_id=$(fm lineage_id)" "cycle_id=$(fm cycle_id)" iteration=2 "reviewed_diff_hash=$H"
setfm iteration=3 'review_status="FAIL"' 'terminal_status="review_findings"' "reviewed_diff_hash=\"$H\""
printf '{"iteration": 2, "status": "FAIL", "issues": [%s]}\n' "$ISSUE" > "$HIST"
INIT 10 >/dev/null 2>&1                                 # pr → commit: retires, installs the successor
cp test_target.txt .mock/candidate.orig
echo more >> test_target.txt; git add test_target.txt   # a CHANGED candidate
echo kill > .mock/mode; RUN >/dev/null 2>&1; rm -f .claude/litmus-review.lock   # charged, no verdict
for _ in $(seq 50); do pgrep -f "$S/" >/dev/null || break; sleep 0.2; done
cp .mock/candidate.orig test_target.txt; git add test_target.txt                # back to the retired candidate
echo fail > .mock/mode; RUN >/dev/null 2>&1
check "criterion 9: a charged no-verdict dispatch does not cost the inherited findings when the candidate returns" '[ "$(fm terminal_status)" = stall ]'
check "criterion 9: the reviewer is shown those inherited findings on the return" 'grep -q "deterministic transition-test issue" .mock/prompt'

echo "── 8. --auto-pr-review adopts the transition and never blind-forces"
new_sandbox
INIT 10 >/dev/null 2>&1; RUN >/dev/null 2>&1       # settled commit FAIL
OLD=$(fm cycle_id)
RUN --auto-pr-review >/dev/null 2>&1
check "settled commit FAIL retired into PR mode, counter and findings kept" '[ "$(fm review_mode)" = pr ] && [ "$(fm iteration)" = 2 ] && [ -f "$HIST.$OLD.retired" ]'
for t in stall max_iterations; do
    new_sandbox; INIT 10 >/dev/null 2>&1; RUN >/dev/null 2>&1; setfm "terminal_status=\"$t\""
    sum=$(shasum -a 256 < .claude/litmus-state.md); rc=0
    RUN --auto-pr-review >/dev/null 2>&1 || rc=$?
    check "auto path refuses $t without touching state" '[ "$rc" != 0 ] && [ "$(shasum -a 256 < .claude/litmus-state.md)" = "$sum" ]'
done
new_sandbox; INIT 10 >/dev/null 2>&1
sum=$(shasum -a 256 < .claude/litmus-state.md); rc=0
RUN --auto-pr-review >/dev/null 2>&1 || rc=$?
check "auto path refuses PENDING without touching state" '[ "$rc" != 0 ] && [ "$(shasum -a 256 < .claude/litmus-state.md)" = "$sum" ]'

legacy_state() {  # $1 = review_mode — a settled FAIL written before cycle identity
    printf -- '---\nactive: true\niteration: 2\nmax_iterations: 10\ncompletion_promise: null\nreview_mode: "%s"\nreview_status: "FAIL"\nstarted_at: "x"\nlast_result: null\nterminal_status: "review_findings"\n---\nbody\n' "$1" > .claude/litmus-state.md
}

echo "── 9. The lock holder's own child cannot retire a cycle whose review is in flight"
new_sandbox
INIT 10 >/dev/null 2>&1; RUN >/dev/null 2>&1       # settled commit FAIL
echo more >> test_target.txt; git add test_target.txt
echo block > .mock/mode
RUN >/dev/null 2>&1 &
RUNPID=$!
i=0; while [ ! -e .mock/blocked ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
# What clear_terminal_status leaves when it cannot clear (it warns and carries on): the
# previous verdict, sitting in the state of a review that is dispatched right now.
setfm 'review_status="FAIL"' 'terminal_status="review_findings"'
TOKEN=$(readlink .claude/litmus-review.lock)
rc=0; LITMUS_MODE=pr INIT 10 >/dev/null 2>&1 || rc=$?
check "mid-dispatch: an outside caller is refused by the live lock" '[ -e .mock/blocked ] && [ "$rc" != 0 ] && [ "$(count retire)" = 0 ]'
rc=0; out=$(BUSDRIVER_REVIEW_LOCK_OWNER="$TOKEN" LITMUS_MODE=pr INIT 10 2>&1) || rc=$?
check "mid-dispatch: an inheriting caller is refused despite the stale review_findings" '[ "$rc" != 0 ] && [ "$(count retire)" = 0 ] && [ "$(fm review_mode)" = commit ] && [ -L .claude/litmus-review.lock ]'
check "mid-dispatch: the refusal says the dispatch has no verdict" 'printf "%s" "$out" | grep -q "no recorded verdict"'
touch .mock/release; wait "$RUNPID"
check "the live review completes, charged once" '[ "$(count attempt)" = 2 ] && [ "$(fm terminal_status)" = review_findings ]'
rc=0; LITMUS_MODE=pr INIT 10 >/dev/null 2>&1 || rc=$?
check "control: once its verdict is recorded the same cycle retires" '[ "$rc" = 0 ] && [ "$(fm review_mode)" = pr ] && [ "$(count retire)" = 1 ]'

echo "── 10. --auto-pr-review on a settled FAIL without identity refuses with the missing evidence"
new_sandbox
legacy_state commit
sum=$(shasum -a 256 < .claude/litmus-state.md); rc=0
RUN --auto-pr-review >/dev/null 2>&1 || rc=$?
check "legacy commit FAIL: refused, state untouched, nothing dispatched" '[ "$rc" != 0 ] && [ "$(shasum -a 256 < .claude/litmus-state.md)" = "$sum" ] && [ "$(count retire)" = 0 ] && [ -z "$(calls)" ]'
check "legacy commit FAIL: names the missing identity and prescribes no reset" 'grep -q "no cycle_id" .mock/run.log && ! grep -q -- "--force" .mock/run.log'

echo "── 11. pr-grind commit block: real dispatcher → init → runner, mock provider"
dispatch_sandbox() {
    new_sandbox
    git config core.hooksPath .git/hooks
    git init -q --bare "$S.remote"; git remote add origin "$S.remote"; git push -q -u origin HEAD 2>/dev/null
    cp "$SRC/scripts/dispatcher-commit-block.sh" "$SRC/scripts/ack-ledger.sh" scripts/
    cat > scripts/fetch-pr-state.sh <<'EOF'
FETCH_OK=1
HEAD_SHA=$(git rev-parse HEAD | cut -c1-8)
HEAD_FULL_SHA=$(git rev-parse HEAD)
ALL_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
ALL_REVIEWS='[]'
ALL_COMMENTS='{"comments":[]}'
ALL_CHECK_RUNS='{"check_runs":[]}'
ALL_STATUSES='[]'
export FETCH_OK ALL_THREADS ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS ALL_STATUSES HEAD_SHA HEAD_FULL_SHA
return 0
EOF
    printf '#!/usr/bin/env bash\nexit 1\n' > "$S.bin/gh"; printf '#!/usr/bin/env bash\nexit 127\n' > "$S.bin/npx"
    chmod +x "$S.bin/gh" "$S.bin/npx"
    echo pass > .mock/mode
}
DISPATCH() {
    PATH="$S.bin:$PATH" BUSDRIVER_REVIEW_CLI=agy CLAUDE_PLUGIN_ROOT="$S" LITMUS_SKIP_SAST=1 \
    LITMUS_SKIP_CONTEXT=1 LITMUS_SKIP_MARKDOWN=1 LITMUS_DOCS_CONTEXT=0 WORKTREE_DIR="$S" PR_NUMBER=1 \
    RESULT_STATUS=needs_more RESULT_FIXES="address the review findings" BUSDRIVER_ALLOW_NO_COMMITLINT=1 \
    bash "$S/scripts/dispatcher-commit-block.sh" 2>>"$S/.mock/run.log" | tee -a "$S/.mock/run.log" | tail -n 1
}
dispatch_sandbox
make_pr_fail deadbeef
LIN=$(fm lineage_id); HEAD0=$(git rev-parse HEAD)
J=$(DISPATCH)
check "settled PR FAIL: the block succeeds" 'printf "%s" "$J" | grep -q "\"status\":\"success\""'
check "the real init retired it into commit mode" '[ "$(count retire)" = 1 ] && grep -q "\"target_mode\": \"commit\"" "$LEDGER"'
check "the real runner dispatched the provider once (calls=$(calls))" '[ "$(calls)" = 1 ]'
check "the dispatch was charged to the same lineage" '[ "$(grep "\"event\": \"attempt\"" "$LEDGER" | grep -c "\"lineage_id\": \"$LIN\"")" = 2 ]'
check "the reviewed fix was committed" '[ "$(git rev-parse HEAD)" != "$HEAD0" ] && git log -1 --format=%B | grep -q "^Grind-PR: 1$"'
for shape in stall legacy; do
    dispatch_sandbox
    if [ "$shape" = stall ]; then make_pr_fail deadbeef; setfm 'terminal_status="stall"'; else legacy_state pr; fi
    sum=$(shasum -a 256 < .claude/litmus-state.md); HEAD0=$(git rev-parse HEAD)
    J=$(DISPATCH)
    check "$shape PR state init will not retire: bails, no force-reset" '! printf "%s" "$J" | grep -q success && [ "$(shasum -a 256 < .claude/litmus-state.md)" = "$sum" ] && [ "$(count retire)" = 0 ] && [ -z "$(calls)" ] && [ "$(git rev-parse HEAD)" = "$HEAD0" ]'
done
check "legacy PR state: the bail carries init's missing-evidence reason" 'printf "%s" "$J" | grep -q "no cycle_id"'
dispatch_sandbox
legacy_state commit
J=$(DISPATCH)
check "same-mode legacy commit FAIL: pre-existing #569 force-reset kept (no lineage carried)" 'printf "%s" "$J" | grep -q "\"status\":\"success\"" && [ "$(count retire)" = 0 ]'

echo "── 12. Residuals: auto resume needs an open identity; builtin is not charged and keeps the lineage"
new_sandbox; legacy_state pr
sum=$(shasum -a 256 < .claude/litmus-state.md); rc=0
RUN --auto-pr-review >/dev/null 2>&1 || rc=$?
check "legacy PR FAIL without identity: auto path refuses instead of resuming" '[ "$rc" != 0 ] && ! grep -q "Resuming the settled" .mock/run.log && grep -q "no cycle identity" .mock/run.log'
check "legacy PR FAIL without identity: state untouched, nothing dispatched" '[ "$(shasum -a 256 < .claude/litmus-state.md)" = "$sum" ] && [ -z "$(calls)" ]'
new_sandbox; make_pr_fail deadbeef; mv "$LEDGER" .claude/moved.jsonl
rc=0; RUN --auto-pr-review >/dev/null 2>&1 || rc=$?
check "identity absent from the ledger: auto path refuses instead of resuming" '[ "$rc" != 0 ] && ! grep -q "Resuming the settled" .mock/run.log && grep -q "not open in the ledger" .mock/run.log'
new_sandbox; make_pr_fail deadbeef
RUN --auto-pr-review >/dev/null 2>&1
check "control: an open identity PR FAIL is still resumed in place" 'grep -q "Resuming the settled" .mock/run.log'
BUILTIN_RUN() {
    PATH="$S.bin:$PATH" BUSDRIVER_REVIEW_CLI=builtin CLAUDE_PLUGIN_ROOT="$S" LITMUS_SKIP_SAST=1 \
    LITMUS_SKIP_CONTEXT=1 LITMUS_SKIP_MARKDOWN=1 LITMUS_DOCS_CONTEXT=0 LITMUS_SHORTCIRCUIT_DISABLED=1 \
    bash "$S/skills/litmus/scripts/run-review-loop.sh" >> "$S/.mock/run.log" 2>&1
}
WRITER() { BUSDRIVER_REVIEW_LOCK_WAIT=0 bash "$S/skills/litmus/scripts/write-review-marker.sh" "$@" >> "$S/.mock/run.log" 2>&1; }
new_sandbox; INIT 10 >/dev/null 2>&1
rc=0; BUILTIN_RUN || rc=$?
check "builtin: hands off (exit 3)" '[ "$rc" = 3 ] && [ -s .claude/builtin-review-prompt-path.local ]'
check "builtin: the undispatched handoff is not charged" '[ "$(count attempt)" = 0 ] && [ -z "$(calls)" ]'
check "builtin: state kept active with its identity, settled as infra_failure" '[ "$(fm active)" = true ] && [ -n "$(fm cycle_id)" ] && [ "$(fm terminal_status)" = infra_failure ]'
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "builtin: an ordinary init cannot open a fresh lineage over it" '[ "$rc" != 0 ] && [ "$(count open)" = 1 ]'
rc=0; WRITER "$(cat .claude/builtin-review-prompt-path.local)" || rc=$?
check "builtin PASS: the writer publishes the reviewed marker" '[ "$rc" = 0 ] && grep -q "^BUILTIN-" .claude/litmus-passed.local'
check "builtin PASS: the reviewed completion settles the cycle like a native PASS" '[ ! -e .claude/litmus-state.md ] && [ "$(count attempt)" = 0 ]'
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "builtin PASS: the next ordinary init opens its own cycle, ledger kept" '[ "$rc" = 0 ] && [ "$(count open)" = 2 ]'

new_sandbox; INIT 10 >/dev/null 2>&1; BUILTIN_RUN
P=$(cat .claude/builtin-review-prompt-path.local)
rc=0; BUILTIN_RUN || rc=$?    # re-run while the handoff is armed: refused before any dispatch
check "early exit after the handoff: rewrites the status, charges and dispatches nothing" '[ "$rc" = 1 ] && [ "$(fm terminal_status)" = setup_error ] && [ "$(fm builtin_handoff)" = "${P##*/}" ] && [ "$(count attempt)" = 0 ] && [ -z "$(calls)" ]'
rc=0; WRITER "$P" || rc=$?
check "early exit after the handoff: the reviewed PASS still settles its cycle" '[ "$rc" = 0 ] && grep -q "^BUILTIN-" .claude/litmus-passed.local && [ ! -e .claude/litmus-state.md ]'

new_sandbox; INIT 10 >/dev/null 2>&1; BUILTIN_RUN
WRITER --discard "$(cat .claude/builtin-review-prompt-path.local)"
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "builtin FAIL (--discard): the cycle is not settled and still refuses a fresh lineage" '[ "$(fm terminal_status)" = infra_failure ] && [ "$rc" != 0 ] && [ "$(count open)" = 1 ]'

new_sandbox; INIT 10 >/dev/null 2>&1; BUILTIN_RUN
P=$(cat .claude/builtin-review-prompt-path.local)
echo kill > .mock/mode; RUN >/dev/null 2>&1; rm -f .claude/litmus-review.lock   # a later dispatch, no verdict
setfm 'terminal_status="infra_failure"'    # what a timed-out dispatch leaves: the same status the handoff parked
sum=$(shasum -a 256 < .claude/litmus-state.md)
rc=0; WRITER "$P" || rc=$?
# The later dispatch charged an attempt this arming was not made at, so the arming is stale and
# the completion refuses -- it used to publish, because the state-present path never asked the
# ledger. The marker is the authorization, so refusing costs a re-run and publishing did not.
check "later charged dispatch: the older arming publishes nothing" '[ "$rc" != 0 ] && [ ! -e .claude/litmus-passed.local ] && [ "$(count attempt)" = 1 ]'
check "later charged dispatch: its cycle is NOT settled by the older arming" '[ -f .claude/litmus-state.md ] && [ "$(shasum -a 256 < .claude/litmus-state.md)" = "$sum" ]'

# The ordinary charged path: Codex is dispatched (and debited), fails, and the runner falls
# back to the builtin reviewer. Its PASS must close THAT cycle in the ledger before the
# marker is published, or the attempt stays the lineage tail and the finished cycle is
# resumed (same mode) or refused at 14 (other mode). No provider is contacted.
fallback_sandbox() {
    new_sandbox
    git commit -q -m target
    git update-ref refs/remotes/origin/main "$(git rev-parse HEAD~1)"
    git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
    echo "second change" >> test_target.txt; git add test_target.txt
    printf '#!/bin/sh\necho "call $1" >> "%s/.mock/calls"\nexit 1\n' "$S" > "$S.bin/codex"
    printf '#!/bin/sh\nexit 0\n' > "$S.bin/droid"
    chmod +x "$S.bin/codex" "$S.bin/droid"
    INIT 10 >/dev/null 2>&1
    rc=0
    PATH="$S.bin:$PATH" BUSDRIVER_REVIEW_CLI=codex LITMUS_CODEX_RETRIES=1 CLAUDE_PLUGIN_ROOT="$S" LITMUS_SKIP_SAST=1 \
    LITMUS_SKIP_CONTEXT=1 LITMUS_SKIP_MARKDOWN=1 LITMUS_DOCS_CONTEXT=0 LITMUS_SHORTCIRCUIT_DISABLED=1 \
    bash "$S/skills/litmus/scripts/run-review-loop.sh" >> "$S/.mock/run.log" 2>&1 || rc=$?
    # Findings from an earlier iteration of this cycle, so the history checks below discriminate.
    printf '{"iteration": 0, "status": "FAIL", "issues": [%s]}\n' "$ISSUE" > "$HIST"
    C1=$(fm cycle_id)
}
events() { python3 -c 'import json; print(" ".join(json.loads(l)["event"] for l in open(".claude/litmus-lineage.local.jsonl") if l.strip()))'; }
lrec() { python3 -c 'import json,sys; r=[json.loads(l) for l in open(".claude/litmus-lineage.local.jsonl") if l.strip()][-1]; print(r["event"], r["cycle_id"], r.get("review_basis", ""))'; }
fallback_sandbox
check "charged fallback: Codex was debited, settled no_lead_reviewer at its head, then handed off (exit 3)" '[ "$rc" = 3 ] && [ "$(events)" = "open attempt abandon" ] && [ "$(lrec)" = "abandon $C1 " ] && grep "\"event\": \"abandon\"" "$LEDGER" | grep "\"abandon_reason\": \"no_lead_reviewer\"" | grep -q "\"head_sha\": \"$(git rev-parse HEAD)\"" && [ "$(fm builtin_handoff)" = "$(basename "$(cat .claude/builtin-review-prompt-path.local)")" ]'
rc=0; WRITER "$(cat .claude/builtin-review-prompt-path.local)" || rc=$?
check "charged fallback PASS: marker published and that exact cycle closed as builtin" '[ "$rc" = 0 ] && grep -q "^BUILTIN-" .claude/litmus-passed.local && [ "$(events)" = "open attempt abandon pass" ] && [ "$(lrec)" = "pass $C1 builtin" ] && [ ! -e .claude/litmus-state.md ] && [ ! -e "$HIST" ]'
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "charged fallback PASS: the next same-mode init opens a new cycle, not a resume" '[ "$rc" = 0 ] && [ "$(count open)" = 2 ] && [ "$(fm cycle_id)" != "$C1" ]'
fallback_sandbox
WRITER "$(cat .claude/builtin-review-prompt-path.local)"
rc=0; out=$(LITMUS_MODE=pr INIT 10 2>&1) || rc=$?
check "charged fallback PASS: a cross-mode init opens a new cycle, no 14, no retirement" '[ "$rc" = 0 ] && [ "$(count open)" = 2 ] && [ "$(count retire)" = 0 ] && ! printf "%s" "$out" | grep -q "never retired"'
armed() {  # the whole arming of prompt $P is still in place: handoff, baseline, reviewed hash + binding
    [ "$(cat .claude/builtin-review-prompt-path.local 2>/dev/null)" = "$P" ] && [ -f .claude/builtin-review-marker-baseline.local ] && [ "$(cat "$HF" 2>/dev/null)" = "$RB" ]
}
spent() { [ ! -e .claude/builtin-review-prompt-path.local ] && [ ! -e .claude/builtin-review-marker-baseline.local ] && [ ! -e "$HF" ]; }
# $RH is the reviewed hash ALONE (sidecar line 1, what the marker carries); $RB is the whole
# sidecar, line 2 included -- the cycle and attempt sequence the arming was made at.
arming() { P=$(cat .claude/builtin-review-prompt-path.local); HF=".claude/builtin-review-${P##*/}.hash"; RH=$(sed -n 1p "$HF"); RB=$(cat "$HF"); }
fallback_sandbox; arming
sum=$(shasum -a 256 < .claude/litmus-state.md); hsum=$(shasum -a 256 < "$HIST" 2>/dev/null)
chmod 400 "$LEDGER"
rc=0; WRITER "$P" || rc=$?
chmod 600 "$LEDGER"
check "charged fallback, ledger append fails: refused, no marker, state/history/ledger kept" '[ "$rc" != 0 ] && [ ! -e .claude/litmus-passed.local ] && [ "$(shasum -a 256 < .claude/litmus-state.md)" = "$sum" ] && [ "$(shasum -a 256 < "$HIST" 2>/dev/null)" = "$hsum" ] && [ "$(events)" = "open attempt abandon" ]'
check "charged fallback, append failed: the reviewed arming is kept whole for a retry" 'armed'
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "charged fallback, append failed: the cycle is still held (no fresh lineage)" '[ "$rc" != 0 ] && [ "$(count open)" = 1 ]'
echo "moved on" >> test_target.txt; git add test_target.txt    # the retry must still name the REVIEWED diff
rc=0; WRITER "$P" || rc=$?
check "append failed, ledger repaired: the same arming retries once — reviewed-hash marker, cycle closed, arming spent" '[ "$rc" = 0 ] && [ "$(cat .claude/litmus-passed.local)" = "BUILTIN-$RH" ] && [ "$(events)" = "open attempt abandon pass" ] && [ "$(lrec)" = "pass $C1 builtin" ] && [ ! -e .claude/litmus-state.md ] && spent'
rm -f .claude/litmus-passed.local
rc=0; WRITER "$P" || rc=$?
check "after a successful retry the arming is spent: a replay publishes and records nothing" '[ "$rc" != 0 ] && [ ! -e .claude/litmus-passed.local ] && [ "$(events)" = "open attempt abandon pass" ]'

fallback_sandbox; arming
mkdir .claude/litmus-passed.local    # the marker cannot be published
rc=0; WRITER "$P" || rc=$?
rmdir .claude/litmus-passed.local
check "publication fails after the completion: refused, cycle closed once, state and arming kept" '[ "$rc" != 0 ] && [ "$(events)" = "open attempt abandon pass" ] && [ -f .claude/litmus-state.md ] && armed'
rc=0; WRITER "$P" || rc=$?
check "publication repaired: the same arming publishes without a second completion, then is spent" '[ "$rc" = 0 ] && [ "$(cat .claude/litmus-passed.local)" = "BUILTIN-$RH" ] && [ "$(events)" = "open attempt abandon pass" ] && [ ! -e .claude/litmus-state.md ] && spent'

# R9: an earlier review's marker that cannot be written through. Writing into it failed AFTER
# the generation moved, so the repaired retry read its own stamp as a newer publication.
fallback_sandbox; arming
echo "PRIOR" > .claude/litmus-passed.local; chmod 400 .claude/litmus-passed.local
rc=0; WRITER "$P" || rc=$?; rc1=$rc
if [ "$rc" != 0 ]; then chmod 600 .claude/litmus-passed.local; rc=0; WRITER "$P" || rc=$?; fi
check "existing unwritable marker: the first call publishes over it, never writing through it" '[ "$rc1" = 0 ]'
check "existing unwritable marker (repaired and retried if refused): reviewed-hash marker, cycle closed once, arming spent" '[ "$rc" = 0 ] && [ "$(cat .claude/litmus-passed.local)" = "BUILTIN-$RH" ] && [ "$(events)" = "open attempt abandon pass" ] && [ ! -e .claude/litmus-state.md ] && spent'

fallback_sandbox; arming
echo "PRIOR" > .claude/litmus-passed.local; g0=$(cat .claude/litmus-marker-gen.local 2>/dev/null || echo ABSENT)
rm -f .claude/litmus-marker-gen.local; mkdir .claude/litmus-marker-gen.local    # the generation cannot be stamped
rc=0; WRITER "$P" || rc=$?
rmdir .claude/litmus-marker-gen.local; [ "$g0" = ABSENT ] || echo "$g0" > .claude/litmus-marker-gen.local
check "existing marker, publication fails: refused, prior marker and generation untouched, cycle closed once, arming kept" '[ "$rc" != 0 ] && [ "$(cat .claude/litmus-passed.local)" = PRIOR ] && [ "$(cat .claude/litmus-marker-gen.local 2>/dev/null || echo ABSENT)" = "$g0" ] && [ "$(events)" = "open attempt abandon pass" ] && [ -f .claude/litmus-state.md ] && armed'
rc=0; WRITER "$P" || rc=$?
check "existing marker, publication repaired: the same arming replaces it once, then is spent" '[ "$rc" = 0 ] && [ "$(cat .claude/litmus-passed.local)" = "BUILTIN-$RH" ] && [ "$(events)" = "open attempt abandon pass" ] && [ ! -e .claude/litmus-state.md ] && spent'
rc=0; WRITER "$P" || rc=$?
check "existing marker, after publication: a replay is refused and changes nothing" '[ "$rc" != 0 ] && [ "$(cat .claude/litmus-passed.local)" = "BUILTIN-$RH" ] && [ "$(events)" = "open attempt abandon pass" ]'

fallback_sandbox; arming
mkdir .claude/litmus-passed.local; rc=0; WRITER "$P" || rc=$?; rmdir .claude/litmus-passed.local
echo "newer" > .claude/litmus-marker-gen.local; echo "NEWER" > .claude/litmus-passed.local    # a genuinely newer publication
rc2=0; WRITER "$P" || rc2=$?
check "kept arming vs a genuinely newer generation: the retry is refused and the newer marker stands" '[ "$rc" != 0 ] && [ "$rc2" != 0 ] && [ "$(cat .claude/litmus-passed.local)" = NEWER ] && [ "$(events)" = "open attempt abandon pass" ]'

# A crash between the two publication renames leaves THIS arming's own stamp in front of the
# old marker. The retry has to recognise its own stamp and publish, not read it as a newer
# review. The stamp spelled here is pinned by the success check below.
fallback_sandbox; arming
echo "PRIOR" > .claude/litmus-passed.local
printf 'builtin-%s\n' "${P##*/}" > .claude/litmus-marker-gen.local
rc=0; WRITER "$P" || rc=$?
check "crash between the renames: the same arming republishes over the old marker, completing once" '[ "$rc" = 0 ] && [ "$(cat .claude/litmus-passed.local)" = "BUILTIN-$RH" ] && [ "$(events)" = "open attempt abandon pass" ] && [ ! -e .claude/litmus-state.md ] && spent'
check "the generation a builtin publication stamps is this arming's own" '[ "$(cat .claude/litmus-marker-gen.local)" = "builtin-${P##*/}" ]'

# A crash AFTER the marker rename, before the arming was spent: the marker stands and the
# cycle is closed, but state, history and the arming are still there. The retry finishes the
# cleanup and records nothing a second time.
fallback_sandbox; arming
mkdir .claude/litmus-passed.local; rc=0; WRITER "$P" || rc=$?; rmdir .claude/litmus-passed.local
printf 'BUILTIN-%s\n' "$RH" > .claude/litmus-passed.local
printf 'builtin-%s\n' "${P##*/}" > .claude/litmus-marker-gen.local
rc=0; WRITER "$P" || rc=$?
check "crash after the marker: the retry completes the cleanup once, with no second pass" '[ "$rc" = 0 ] && [ "$(cat .claude/litmus-passed.local)" = "BUILTIN-$RH" ] && [ "$(events)" = "open attempt abandon pass" ] && [ ! -e .claude/litmus-state.md ] && spent'

fallback_sandbox; arming
mv "$LEDGER" .mock/ledger.saved    # the cycle's ledger is lost: nothing may be published over it
rc=0; WRITER "$P" || rc=$?
check "ledger lost: refused, no marker, nothing recorded, state and arming kept" '[ "$rc" != 0 ] && [ ! -e .claude/litmus-passed.local ] && [ ! -e "$LEDGER" ] && [ -f .claude/litmus-state.md ] && armed'
mv .mock/ledger.saved "$LEDGER"
rc=0; WRITER "$P" || rc=$?
check "ledger restored: the same arming completes and publishes once" '[ "$rc" = 0 ] && [ "$(cat .claude/litmus-passed.local)" = "BUILTIN-$RH" ] && [ "$(events)" = "open attempt abandon pass" ] && spent'

echo "── 13. A4: a PR attempt refused for want of a lead reviewer is recorded and resumed from the ledger"
# The real PR path: the codex arm runs this codex's version probe AFTER the attempt is
# debited, and it fails — a charged dispatch that finds no lead reviewer. No provider is
# contacted. `readonly-ledger` makes that probe plant the append failure.
pr_refuse_sandbox() {
    new_sandbox
    git commit -q -m target
    git update-ref refs/remotes/origin/main "$(git rev-parse HEAD~1)"
    git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
    local pre=":"; [ "${1:-}" = readonly-ledger ] && pre="chmod 400 '$S/$LEDGER'"
    printf '#!/bin/sh\n%s\necho "call $1" >> "%s/.mock/calls"\nexit 1\n' "$pre" "$S" > "$S.bin/codex"
    printf '#!/bin/sh\nexit 0\n' > "$S.bin/droid"
    chmod +x "$S.bin/codex" "$S.bin/droid"
    LITMUS_MODE=pr INIT 10 >/dev/null 2>&1
    printf '{"iteration": 0, "status": "FAIL", "issues": [%s]}\n' "$ISSUE" > "$HIST"
    C1=$(fm cycle_id); L1=$(fm lineage_id)
}
PR_RUN() {
    PATH="$S.bin:$PATH" BUSDRIVER_REVIEW_CLI=codex LITMUS_CODEX_RETRIES=1 CLAUDE_PLUGIN_ROOT="$S" LITMUS_SKIP_SAST=1 \
    LITMUS_SKIP_CONTEXT=1 LITMUS_SKIP_MARKDOWN=1 LITMUS_DOCS_CONTEXT=0 LITMUS_SHORTCIRCUIT_DISABLED=1 \
    bash "$S/skills/litmus/scripts/run-review-loop.sh" >> "$S/.mock/run.log" 2>&1
}
events() { python3 -c 'import json; print(" ".join(json.loads(l)["event"] for l in open(".claude/litmus-lineage.local.jsonl") if l.strip()))'; }

pr_refuse_sandbox
rc=0; PR_RUN || rc=$?
check "A4: the refused PR attempt is charged, then abandoned in the ledger" '[ "$rc" = 1 ] && [ "$(events)" = "open attempt abandon" ] && grep "\"event\": \"abandon\"" "$LEDGER" | grep -q "\"settles_seq\": 1"'
check "A4: the state is removed, not re-minted without identity; the history is kept" '[ ! -e .claude/litmus-state.md ] && grep -q deterministic "$HIST"'
rc=0; out=$(LITMUS_MODE=commit INIT 10 2>&1) || rc=$?
check "A4: abandon-only — a cross-mode init refuses at 14, no retirement, no new cycle" '[ "$rc" = 14 ] && [ "$(events)" = "open attempt abandon" ] && [ ! -e .claude/litmus-state.md ] && printf "%s" "$out" | grep -q "never retired"'
rc=0; LITMUS_MODE=pr INIT 10 >/dev/null 2>&1 || rc=$?
check "A4: the same-mode init resumes that cycle, its count and history, with no second open" '[ "$rc" = 0 ] && [ "$(fm cycle_id)" = "$C1" ] && [ "$(fm lineage_id)" = "$L1" ] && [ "$(fm review_mode)" = pr ] && [ "$(fm iteration)" = 1 ] && [ "$(fm attempts_consumed)" = 1 ] && [ "$(count open)" = 1 ] && grep -q deterministic "$HIST"'
ledger_add event=pass "lineage_id=$L1" "cycle_id=$C1" review_basis=excluded_only; rm -f .claude/litmus-state.md
rc=0; LITMUS_MODE=pr INIT 10 >/dev/null 2>&1 || rc=$?
check "A4: a later completion supersedes the abandon — a new cycle, never the stale one" '[ "$rc" = 0 ] && [ "$(fm cycle_id)" != "$C1" ] && [ "$(count open)" = 2 ]'

pr_refuse_sandbox; PR_RUN
rc=0; LITMUS_MODE=pr INIT --force 10 >/dev/null 2>&1 || rc=$?
check "A4: --force still opens a new cycle, recorded after the abandon" '[ "$rc" = 0 ] && [ "$(fm cycle_id)" != "$C1" ] && [ "$(events)" = "open attempt abandon open" ]'
rm -f .claude/litmus-state.md
rc=0; LITMUS_MODE=pr INIT 10 >/dev/null 2>&1 || rc=$?
check "A4: after --force the abandoned predecessor is not resumed" '[ "$rc" = 0 ] && [ "$(fm cycle_id)" != "$C1" ] && [ "$(count open)" = 3 ]'

pr_refuse_sandbox; PR_RUN
cp "$LEDGER" .mock/ledger.ok
line=$(grep '"event": "abandon"' "$LEDGER"); printf '%s\n' "$line" >> "$LEDGER"
rc=0; LITMUS_MODE=pr INIT 10 >/dev/null 2>&1 || rc=$?
check "A4: a duplicate settlement is refused, nothing opened or resumed" '[ "$rc" != 0 ] && [ ! -e .claude/litmus-state.md ] && [ "$(count open)" = 1 ]'
sed 's/"settles_seq": 1/"settles_seq": 2/' .mock/ledger.ok > "$LEDGER"
rc=0; LITMUS_MODE=pr INIT 10 >/dev/null 2>&1 || rc=$?
check "A4: an abandon that does not settle the last charged attempt is refused" '[ "$rc" != 0 ] && [ ! -e .claude/litmus-state.md ] && [ "$(count open)" = 1 ]'
cp .mock/ledger.ok "$LEDGER"; git checkout -q --detach
rc=0; LITMUS_MODE=pr INIT 10 >/dev/null 2>&1 || rc=$?
check "A4: a checkout with no provable branch cannot cold-start past an abandoned cycle" '[ "$rc" != 0 ] && [ ! -e .claude/litmus-state.md ] && [ "$(count open)" = 1 ]'

pr_refuse_sandbox readonly-ledger
rc=0; PR_RUN || rc=$?; chmod 600 "$LEDGER"
check "A4: a failed abandon append keeps the state, its identity and the history" '[ "$rc" = 1 ] && [ "$(fm cycle_id)" = "$C1" ] && [ "$(fm terminal_status)" = infra_failure ] && grep -q deterministic "$HIST" && [ "$(events)" = "open attempt" ]'

pr_refuse_sandbox
python3 -c 'import json; p=".claude/litmus-lineage.local.jsonl"; rs=[json.loads(l) for l in open(p)]; [r.pop("lineage_key", None) for r in rs]; open(p, "w").write("".join(json.dumps(r, sort_keys=True) + "\n" for r in rs))'
rc=0; PR_RUN || rc=$?
check "A4: a cycle born without a key is never abandoned blind — state and identity kept" '[ "$rc" = 1 ] && [ "$(fm cycle_id)" = "$C1" ] && [ "$(events)" = "open attempt" ]'

pr_refuse_sandbox; PR_RUN
H=$(git rev-parse HEAD)
check "A4: the attempt and its abandon both carry the head the run pinned" '[ "$(grep "\"event\": \"attempt\"" "$LEDGER" | grep -c "\"head_sha\": \"$H\"")" = 1 ] && [ "$(grep "\"event\": \"abandon\"" "$LEDGER" | grep -c "\"head_sha\": \"$H\"")" = 1 ]'
python3 - <<'PY'
import json
p = ".claude/litmus-lineage.local.jsonl"
rs = [json.loads(l) for l in open(p)]
for r in rs:
    if r["event"] == "abandon":
        r["head_sha"] = "f" * 40
open(p, "w").write("".join(json.dumps(r, sort_keys=True) + "\n" for r in rs))
PY
rc=0; LITMUS_MODE=pr INIT 10 >/dev/null 2>&1 || rc=$?
check "A4: an abandon naming another head than its attempt is refused" '[ "$rc" != 0 ] && [ ! -e .claude/litmus-state.md ] && [ "$(count open)" = 1 ]'

pr_refuse_sandbox
# The debited attempt loses its head before the refusal: nothing may be filled in for it.
printf '#!/bin/sh\nsed -i.bak '"'"'s/"head_sha": "[0-9a-f]*", //'"'"' "%s/%s"\nexit 1\n' "$S" "$LEDGER" > "$S.bin/codex"
rc=0; PR_RUN || rc=$?
check "A4: an attempt with no recorded head is never abandoned — state kept, no record written" '[ "$rc" = 1 ] && [ "$(fm cycle_id)" = "$C1" ] && [ "$(events)" = "open attempt" ] && ! grep -q "\"head_sha\"" "$LEDGER"'

# The real excluded-only PR exit — the writer, not a planted record.
xo_sandbox() {
    new_sandbox
    git reset -q test_target.txt
    printf 'rules/**/*.md\n' > .claude/review-exclude
    git add .claude/review-exclude; git commit -q -m policy
    git update-ref refs/remotes/origin/main HEAD
    git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
    mkdir -p rules/x; echo doc > rules/x/a.md; git add rules/x/a.md; git commit -q -m doc
    printf '#!/bin/sh\necho "call $1" >> "%s/.mock/calls"\nexit 1\n' "$S" > "$S.bin/codex"; chmod +x "$S.bin/codex"
    LITMUS_MODE=pr INIT 10 >/dev/null 2>&1
    printf '{"iteration": 0, "status": "FAIL", "issues": [%s]}\n' "$ISSUE" > "$HIST"
    C1=$(fm cycle_id)
}
# Exclusions are honoured only for scripts that are not untracked copies inside the
# reviewed tree, so this exit runs the source tree's runner (as the autopass suite does).
XO_RUN() {
    PATH="$S.bin:$PATH" BUSDRIVER_STATE_DIR=.claude BUSDRIVER_REVIEW_CLI=codex LITMUS_PR_BASE=main LITMUS_CODEX_RETRIES=1 \
    LITMUS_SKIP_SAST=1 LITMUS_SKIP_CONTEXT=1 LITMUS_SKIP_MARKDOWN=1 LITMUS_DOCS_CONTEXT=0 LITMUS_SHORTCIRCUIT_DISABLED=1 \
    bash "$SRC/skills/litmus/scripts/run-review-loop.sh" >> "$S/.mock/run.log" 2>&1
}
xo_sandbox
rc=0; XO_RUN || rc=$?
check "excluded-only PR: the real exit records pass for its cycle, then removes state and history" '[ "$rc" = 0 ] && [ "$(events)" = "open pass" ] && grep "\"event\": \"pass\"" "$LEDGER" | grep -q "\"cycle_id\": \"$C1\"" && [ ! -e .claude/litmus-state.md ] && [ ! -s "$HIST" ] && grep -q "^PASS-EXCLUDED-" .claude/pr-review-passed.local && [ -z "$(calls)" ]'
xo_sandbox; chmod 400 "$LEDGER"
rc=0; XO_RUN || rc=$?; chmod 600 "$LEDGER"
check "excluded-only PR: a failed pass append keeps the state and history" '[ "$rc" = 1 ] && grep -q "Could not record the completion of cycle $C1" .mock/run.log && [ "$(fm cycle_id)" = "$C1" ] && [ "$(fm terminal_status)" = setup_error ] && grep -q deterministic "$HIST" && [ "$(events)" = "open" ] && [ ! -e .claude/pr-review-passed.local ]'
# Crash cut after the completion was recorded, before state and history went: the stale state
# is refused by the shared admission check — no second pass, no marker, the ledger still reads.
xo_sandbox; cp .claude/litmus-state.md .mock/state.pre; cp "$HIST" .mock/hist.pre
XO_RUN; cp .mock/state.pre .claude/litmus-state.md; cp .mock/hist.pre "$HIST"; rm -f .claude/pr-review-passed.local
rc=0; XO_RUN || rc=$?
check "excluded-only PR, crash cut after its pass: the stale state is refused — no second pass, no marker, ledger readable" '[ "$rc" = 1 ] && [ "$(events)" = "open pass" ] && [ ! -e .claude/pr-review-passed.local ] && bash -c '"'"'source "$0"; ledger_query usable'"'"' "$S/skills/litmus/scripts/lib/iteration-history.sh"'
# The same stale state dressed as a FAIL must not retire the completed cycle either.
setfm iteration=2 'review_status="FAIL"' 'terminal_status="review_findings"'
rc=0; LITMUS_MODE=commit INIT 10 >> .mock/run.log 2>&1 || rc=$?
check "excluded-only PR, crash cut after its pass: a cross-mode init refuses to retire the closed cycle" '[ "$rc" != 0 ] && [ "$(count retire)" = 0 ] && [ "$(events)" = "open pass" ] && grep -q "already completed" .mock/run.log'

echo "── 14. §7 verdict: the real writer, and a no-state cross-mode retirement of an A4 cycle"
rec() { python3 -c 'import json,sys; print([json.loads(l) for l in open(".claude/litmus-lineage.local.jsonl") if l.strip()][int(sys.argv[1])].get(sys.argv[2], ""))' "$1" "$2"; }
LIB() { bash -c 'source "$0"; "$@"' "$S/skills/litmus/scripts/lib/iteration-history.sh" "$@"; }

# The writer at the runner's single outcome site, in real commit-mode runs.
new_sandbox; INIT 10 >/dev/null 2>&1; C=$(fm cycle_id); H=$(git rev-parse HEAD)
rc=0; RUN || rc=$?
check "verdict writer: a real FAIL settles its attempt — status, fingerprint, mode, head" '[ "$rc" = 1 ] && [ "$(events)" = "open attempt verdict" ] && [ "$(rec -1 cycle_id)" = "$C" ] && [ "$(rec -1 status)" = fail ] && [ "$(rec -1 settles_seq)" = 1 ] && [[ "$(rec -1 fingerprint)" =~ ^[0-9a-f]{32}$ ]] && [ "$(rec -1 review_mode)" = commit ] && [ "$(rec -1 head_sha)" = "$H" ] && [ "$(fm terminal_status)" = review_findings ]'
rc=0; RUN || rc=$?
check "verdict writer: a stall settles its attempt with a FAIL verdict before stopping" '[ "$(fm terminal_status)" = stall ] && [ "$(events)" = "open attempt verdict attempt verdict" ] && [ "$(rec -1 settles_seq)" = 2 ]'
new_sandbox; echo pass > .mock/mode; INIT 10 >/dev/null 2>&1
rc=0; RUN || rc=$?
check "verdict writer: a real commit PASS records its verdict, then closes the cycle, then publishes" '[ "$rc" = 0 ] && [ "$(events)" = "open attempt verdict pass" ] && [ "$(rec -2 status)" = pass ] && [ "$(rec -1 review_basis)" = dispatched ] && [ -s .claude/litmus-passed.local ] && [ ! -e .claude/litmus-state.md ]'
new_sandbox; INIT 10 >/dev/null 2>&1; C=$(fm cycle_id)
mv "$S.bin/agy" "$S.bin/agy.real"
printf '#!/bin/sh\n[ "$1" = --version ] || chmod 400 "%s/%s"\nexec "%s.bin/agy.real" "$@"\n' "$S" "$LEDGER" "$S" > "$S.bin/agy"; chmod +x "$S.bin/agy"
rc=0; RUN || rc=$?; chmod 600 "$LEDGER"
check "verdict writer: a failed append publishes nothing and keeps state, iteration and history" '[ "$rc" = 1 ] && grep -q "Could not record the verdict of cycle $C" .mock/run.log && [ "$(events)" = "open attempt" ] && [ "$(fm terminal_status)" = setup_error ] && [ "$(fm iteration)" = 1 ] && [ ! -e "$HIST" ] && [ ! -e .claude/litmus-passed.local ]'

# An attempt names a cycle the ledger created, under that cycle's own lineage: one the lineage
# fold cannot attribute to its cycle is refused, never dropped from the budget.
new_sandbox; INIT 10 >/dev/null 2>&1; C=$(fm cycle_id); L=$(fm lineage_id); cp "$LEDGER" .mock/ledger.open
ledger_add event=attempt "lineage_id=$L" "cycle_id=$C" iteration=1
rc=0; LIB ledger_query usable || rc=$?
check "attempt control: under its cycle's own lineage it reads and counts once for cycle and lineage" '[ "$rc" = 0 ] && [ "$(LIB ledger_query fold "$L")" = "1 10" ] && [ "$(LIB ledger_query cycle_attempts "$C")" = 1 ]'
cp .mock/ledger.open "$LEDGER"; ledger_add event=attempt lineage_id=other "cycle_id=$C" iteration=1
rc=0; LIB ledger_query usable || rc=$?
check "an attempt under another lineage than its cycle's makes the ledger unreadable (exit 4)" '[ "$rc" = 4 ]'
cp .mock/ledger.open "$LEDGER"; ledger_add event=attempt "lineage_id=$L" cycle_id=unborn iteration=1
rc=0; LIB ledger_query usable || rc=$?
check "an attempt for a cycle the ledger never created makes the ledger unreadable (exit 4)" '[ "$rc" = 4 ]'
rc=0; RUN || rc=$?
check "over that ledger the runner refuses to dispatch — nothing charged, no marker" '[ "$rc" != 0 ] && [ -z "$(calls)" ] && [ "$(count attempt)" = 1 ] && [ ! -e .claude/litmus-passed.local ]'
# A retirement is held to the same rule for the cycle it retires: only an open is a first birth.
retire_as() {  # $1 lineage_id, $2 retired cycle_id
    cp .mock/ledger.open "$LEDGER"; ledger_add event=attempt "lineage_id=$L" "cycle_id=$C" iteration=1
    ledger_add event=retire "lineage_id=$1" "cycle_id=$2" successor_cycle_id=feedfacefeedface target_mode=pr max_iterations=10 iteration=2
    rc=0; LIB ledger_query usable || rc=$?
}
retire_as "$L" "$C"
check "retire control: its own cycle under its lineage reads, the successor joins that lineage with its attempt" '[ "$rc" = 0 ] && [ "$(LIB ledger_query known feedfacefeedface)" = "$L" ] && [ "$(LIB ledger_query fold "$L")" = "1 10" ]'
retire_as other "$C"
check "a retire under another lineage than its cycle's makes the ledger unreadable (exit 4)" '[ "$rc" = 4 ]'
retire_as "$L" unborn
check "a retire of a cycle the ledger never created makes the ledger unreadable (exit 4)" '[ "$rc" = 4 ]'
retire_as other unborn
check "a retire of an unborn cycle under another lineage makes the ledger unreadable (exit 4)" '[ "$rc" = 4 ]'

# An earlier PR FAIL, then a real A4 refusal. A real PR-mode review needs the trusted Codex
# companion, which resolves from the operator's password-database home and which no stub can
# drive; so that review's outcome is reproduced as make_pr_fail does, and settled through the
# production writer above, never a hand-written verdict. HEAD then moves before the A4 run, so
# the attempt it abandons reviewed another head and diff. $1: fail | unsettled | owed | unknown
pr_verdict_then_refuse() {
    pr_refuse_sandbox
    H=$(git rev-parse HEAD); local st=FAIL
    ledger_add event=attempt "lineage_id=$L1" "cycle_id=$C1" iteration=1 reviewed_diff_hash=deadbeef "head_sha=$H"
    FP=$(LIB compute_issue_fingerprint "{\"status\":\"FAIL\",\"issues\":[$ISSUE]}")
    case "$1" in owed) st=PASS; FP=empty ;; unknown) FP=unknown ;; esac
    [ "$1" = unsettled ] || LIB ledger_verdict "$L1" "$C1" "$st" "$FP" pr "$H"
    setfm iteration=2 'review_status="FAIL"' 'terminal_status="review_findings"' attempts_consumed=1
    printf '{"iteration": 1, "status": "FAIL", "issues": [%s]}\n' "$ISSUE" > "$HIST"
    echo moved >> seed.txt; git commit -qam moved
    PR_RUN
}
pr_verdict_then_refuse fail; SUM=$(shasum -a 256 < "$HIST")
check "earlier PR FAIL settled attempt 1, the real A4 run charged and abandoned attempt 2 at a later head" '[ "$(events)" = "open attempt verdict attempt abandon" ] && [ "$(rec -1 settles_seq)" = 2 ] && [ ! -e .claude/litmus-state.md ] && [[ "$FP" =~ ^[0-9a-f]{32}$ ]] && [ "$(rec 3 head_sha)" = "$(git rev-parse HEAD)" ] && [ "$(rec 3 head_sha)" != "$H" ] && [ "$(rec 3 reviewed_diff_hash)" != deadbeef ]'
pr_verdict_then_refuse fail
rc=0; LITMUS_MODE=pr INIT 10 >/dev/null 2>&1 || rc=$?
check "control: the same mode resumes it — no retirement, both debits and the history kept" '[ "$rc" = 0 ] && [ "$(fm cycle_id)" = "$C1" ] && [ "$(fm attempts_consumed)" = 2 ] && [ "$(count retire)" = 0 ] && grep -q deterministic "$HIST"'

# Criterion 3: whatever the ledger holds — a settled FAIL, an unsettled, owed or unknown
# verdict — an abort whose state is gone never retires into the other mode.
for shape in fail unsettled owed unknown; do
    pr_verdict_then_refuse "$shape"; before=$(events)
    rc=0; out=$(LITMUS_MODE=commit INIT 10 2>&1) || rc=$?
    check "$shape then A4, state removed: cross-mode refuses at 14 — ledger, history untouched, no state" '[ "$rc" = 14 ] && [ "$(events)" = "$before" ] && [ ! -e .claude/litmus-state.md ] && grep -q deterministic "$HIST" && printf "%s" "$out" | grep -q "never retired"'
done

pr_verdict_then_refuse fail; cp "$LEDGER" .mock/ledger.ok
for t in 'rs.insert(rs.index(v) + 1, dict(v))' 'v["head_sha"] = "f" * 40' 'v["review_mode"] = "commit"' 'v["cycle_id"] = "feedface"' 'v["status"] = "FAIL"'; do
    cp .mock/ledger.ok "$LEDGER"
    python3 - "$t" <<'PY'
import json, sys
p = ".claude/litmus-lineage.local.jsonl"
rs = [json.loads(l) for l in open(p) if l.strip()]
v = next(r for r in rs if r["event"] == "verdict")
exec(sys.argv[1])
open(p, "w").write("".join(json.dumps(r, sort_keys=True) + "\n" for r in rs))
PY
    rc=0; LITMUS_MODE=commit INIT 10 >/dev/null 2>&1 || rc=$?
    check "a verdict that is not its attempt's one valid settlement is refused: $t" '[ "$rc" = 1 ] && [ "$(count retire)" = 0 ] && [ "$(count open)" = 1 ] && [ ! -e .claude/litmus-state.md ]'
done

echo "── 15. Completion barriers, and plain-verdict admission with no state file"
HASH_NOW() { git --no-replace-objects -c color.ui=never -c core.quotePath=false diff --no-ext-diff --no-textconv --full-index --ignore-submodules=none "$(git merge-base origin/main HEAD)...$(git rev-parse HEAD)" | shasum -a 256 | cut -d' ' -f1; }
voice() { printf '{"status":"PASS","model":"%s","diff_hash":"%s","ts":%s}\n' "$2" "$(HASH_NOW)" "$(date +%s)" > ".claude/$1"; }
# The lead artifact as the PRODUCTION writer emits it whenever the run has identity: naming the
# cycle it reviewed. `voice` above is the cycle-less pre-A8 shape, which write_codex_lead_verdict
# only ever produces where there is no cycle to name -- so a fixture that used it for a minted
# cycle was describing a checkout that cannot exist.
lead_voice() { printf '{"status":"PASS","model":"codex","diff_hash":"%s","ts":%s,"cycle_id":"%s","lineage_id":"%s"}\n' "$(HASH_NOW)" "$(date +%s)" "$1" "$2" > .claude/pr-codex-lead.local.json; }
MARKER() { PATH="$S.bin:$PATH" bash "$S/skills/litmus/scripts/run-review-loop.sh" --write-pr-marker >> "$S/.mock/run.log" 2>&1; }
# What A7b's lead-only PASS run leaves: its attempt, its verdict through the production writer,
# the lead artifact, no state file. The lead review itself needs the Codex companion (see 14);
# --write-pr-marker below is the real completion writer, run as the gate flow runs it.
pr_lead_pass() {
    pr_refuse_sandbox
    H=$(git rev-parse HEAD)
    ledger_add event=attempt "lineage_id=$L1" "cycle_id=$C1" iteration=1 "reviewed_diff_hash=$(HASH_NOW)" "head_sha=$H"
    LIB ledger_verdict "$L1" "$C1" PASS empty pr "$H"
    lead_voice "$C1" "$L1"
    rm -f .claude/litmus-state.md "$HIST"
}
pr_lead_pass; before=$(events)
rc=0; out=$(LITMUS_MODE=commit INIT 10 2>&1) || rc=$?
check "lead-only PASS, no state: a cross-mode init refuses at 14 — owed, nothing retired or opened" '[ "$rc" = 14 ] && [ "$(events)" = "$before" ] && [ ! -e .claude/litmus-state.md ] && printf "%s" "$out" | grep -q "never retired"'
rc=0; LITMUS_MODE=pr INIT 10 >/dev/null 2>&1 || rc=$?
check "lead-only PASS, no state: the same mode resumes that cycle — debit kept, no second open" '[ "$rc" = 0 ] && [ "$(fm cycle_id)" = "$C1" ] && [ "$(fm lineage_id)" = "$L1" ] && [ "$(fm attempts_consumed)" = 1 ] && [ "$(fm iteration)" = 2 ] && [ "$(count open)" = 1 ] && [ "$(events)" = "$before" ]'
rm -f .claude/litmus-state.md
rc=0; MARKER || rc=$?
check "A8 with the backstop missing: no marker, no completion, still owed" '[ "$rc" = 1 ] && [ "$(events)" = "$before" ] && [ ! -e .claude/pr-review-passed.local ]'
voice pr-backstop-verdict.local.json opus; chmod 400 "$LEDGER"
rc=0; MARKER || rc=$?; chmod 600 "$LEDGER"
check "A8 completion append fails: no marker published, the cycle stays owed" '[ "$rc" = 1 ] && grep -q "Could not record the completion of cycle $C1" .mock/run.log && [ "$(events)" = "$before" ] && [ ! -e .claude/pr-review-passed.local ]'
rc=0; MARKER || rc=$?
check "A8 real writer: both voices close the owed cycle (pr_dual, its head), then publish the marker" '[ "$rc" = 0 ] && [ "$(events)" = "$before pass" ] && [ "$(rec -1 cycle_id)" = "$C1" ] && [ "$(rec -1 review_basis)" = pr_dual ] && [ "$(rec -1 head_sha)" = "$H" ] && [ "$(cat .claude/pr-review-passed.local)" = "$(HASH_NOW)" ]'
rc=0; LITMUS_MODE=commit INIT 10 >/dev/null 2>&1 || rc=$?
check "A8: the completed cycle is no longer unresolved — the next init opens its own cycle" '[ "$rc" = 0 ] && [ "$(fm cycle_id)" != "$C1" ] && [ "$(count open)" = 2 ] && [ "$(count retire)" = 0 ]'

# Entered from a subdirectory, the completion reads and writes the ledger at the root the marker
# is published under: a failed append publishes nothing, a recorded one is the same record and
# marker as from the root, and nothing lands under the subdirectory.
pr_lead_pass; voice pr-backstop-verdict.local.json opus; before=$(events); mkdir -p sub/dir
chmod 400 "$LEDGER"; rc=0; (cd sub/dir && MARKER) || rc=$?; chmod 600 "$LEDGER"
check "A8 from a subdirectory, completion append fails: no marker, still owed, nothing under the subdirectory" '[ "$rc" = 1 ] && grep -q "Could not record the completion of cycle $C1" .mock/run.log && [ "$(events)" = "$before" ] && [ ! -e .claude/pr-review-passed.local ] && [ ! -e sub/dir/.claude ]'
rc=0; (cd sub/dir && MARKER) || rc=$?
check "A8 from a subdirectory: the root ledger closes the owed cycle (pr_dual, its head), then the root marker" '[ "$rc" = 0 ] && [ "$(events)" = "$before pass" ] && [ "$(rec -1 cycle_id)" = "$C1" ] && [ "$(rec -1 review_basis)" = pr_dual ] && [ "$(rec -1 head_sha)" = "$H" ] && [ "$(cat .claude/pr-review-passed.local)" = "$(HASH_NOW)" ] && [ ! -e sub/dir/.claude ]'
rc=0; (cd sub && LITMUS_MODE=commit INIT 10 >/dev/null 2>&1) || rc=$?
check "init from a subdirectory opens its cycle in the root state and ledger, nothing under the subdirectory" '[ "$rc" = 0 ] && [ "$(count open)" = 2 ] && [ -n "$(fm cycle_id)" ] && [ "$(fm cycle_id)" != "$C1" ] && [ ! -e sub/.claude ]'

# A lost ledger is not a pre-ledger repository. What the lead run leaves bound to its minted
# cycle — the state a resume re-installs, the lead verdict the run wrote — is checked against
# the ledger at publication; only a checkout holding neither publishes as before.
new_sandbox; git commit -q -m target; git update-ref refs/remotes/origin/main "$(git rev-parse HEAD~1)"; git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
voice pr-codex-lead.local.json codex; voice pr-backstop-verdict.local.json opus
rc=0; MARKER || rc=$?
check "A1 pre-ledger: no init ever ran, no ledger, no state, a cycle-less lead verdict — published as before" '[ "$rc" = 0 ] && [ "$(cat .claude/pr-review-passed.local)" = "$(HASH_NOW)" ] && [ ! -e "$LEDGER" ]'
pr_lead_pass; LITMUS_MODE=pr INIT 10 >/dev/null 2>&1; voice pr-backstop-verdict.local.json opus; rm -f "$LEDGER"
rc=0; MARKER || rc=$?
check "A2 ledger lost while the resumed state names the owed cycle: refused, no marker" '[ "$rc" = 1 ] && [ ! -e .claude/pr-review-passed.local ] && grep -q "names cycle $C1, which .* does not hold" .mock/run.log'
pr_lead_pass; lead_voice "$C1" "$L1"; voice pr-backstop-verdict.local.json opus; rm -f "$LEDGER"
rc=0; MARKER || rc=$?
check "A3 ledger lost after a lead-only PASS, no state: the lead verdict's cycle refuses, no marker" '[ "$rc" = 1 ] && [ ! -e .claude/pr-review-passed.local ] && grep -q "belongs to cycle $C1, which .* neither owes nor can republish" .mock/run.log'
pr_lead_pass; lead_voice "$C1" "$L1"; voice pr-backstop-verdict.local.json opus; : > "$LEDGER"
rc=0; MARKER || rc=$?
check "A3 ledger emptied after a lead-only PASS: refused, no marker" '[ "$rc" = 1 ] && [ ! -e .claude/pr-review-passed.local ] && grep -q "neither owes nor can republish" .mock/run.log'
pr_lead_pass; lead_voice "$C1" "$L1"; voice pr-backstop-verdict.local.json opus; before=$(events)
rc=0; MARKER || rc=$?
check "control: a cycle-bound lead verdict with its ledger intact closes the owed cycle and publishes" '[ "$rc" = 0 ] && [ "$(events)" = "$before pass" ] && [ "$(rec -1 cycle_id)" = "$C1" ] && [ "$(cat .claude/pr-review-passed.local)" = "$(HASH_NOW)" ]'
rm -f .claude/pr-review-passed.local; rc=0; MARKER || rc=$?
check "control: rerun after that completion republishes over the closed cycle, no second pass" '[ "$rc" = 0 ] && [ "$(events)" = "$before pass" ] && [ "$(cat .claude/pr-review-passed.local)" = "$(HASH_NOW)" ]'

pr_lead_pass; voice pr-backstop-verdict.local.json opus; before=$(events)
GIT_COMMITTER_DATE=2001-01-01T00:00:00 git commit -q --amend --no-edit    # same diff, another head
rc=0; MARKER || rc=$?
check "A8 at a head the lead verdict did not review: no marker, no completion" '[ "$rc" = 1 ] && [ "$(git rev-parse HEAD)" != "$H" ] && [ "$(events)" = "$before" ] && [ ! -e .claude/pr-review-passed.local ]'

new_sandbox; INIT 5 >/dev/null 2>&1; C=$(fm cycle_id); L=$(fm lineage_id)
RUN; A1=$(rec 1 reviewed_diff_hash); FP=$(rec 2 fingerprint)
rm -f .claude/litmus-state.md
rc=0; INIT 5 >/dev/null 2>&1 || rc=$?
check "plain FAIL, state removed: the same mode resumes it — debit, findings kept, iteration moved on" '[ "$rc" = 0 ] && [ "$(fm cycle_id)" = "$C" ] && [ "$(fm iteration)" = 2 ] && [ "$(fm attempts_consumed)" = 1 ] && [ "$(count open)" = 1 ] && grep -q deterministic "$HIST"'
rm -f .claude/litmus-state.md; before=$(events)
rc=0; out=$(LITMUS_MODE=pr INIT 10 2>&1) || rc=$?
check "plain FAIL, state removed: the other mode refuses at 14 — never retired without its state" '[ "$rc" = 14 ] && [ "$(events)" = "$before" ] && [ "$(count retire)" = 0 ] && [ ! -e .claude/litmus-state.md ] && grep -q deterministic "$HIST" && printf "%s" "$out" | grep -q "LITMUS_MODE=commit"'
INIT 5 >/dev/null 2>&1; echo block > .mock/mode; touch .mock/release; RUN; echo fail > .mock/mode
A2=$(rec -2 reviewed_diff_hash); FP2=$(rec -1 fingerprint); SUM=$(shasum -a 256 < "$HIST")
rc=0; LITMUS_MODE=pr INIT 10 >/dev/null 2>&1 || rc=$?
check "plain FAIL, removed, resumed and reviewed again: the other mode retires it — lineage, both debits, findings; ceiling 5 under 10" '[ "$rc" = 0 ] && [ "$(fm review_mode)" = pr ] && [ "$(fm lineage_id)" = "$L" ] && [ "$(fm iteration)" = 3 ] && [ "$(rec -1 event)" = retire ] && [ "$(rec -1 retired_from)" = commit ] && [ "$(rec -1 fingerprint)" = "$FP2" ] && [ "$FP2" != "$FP" ] && [ "$(rec -1 reviewed_diff_hash)" = "$A2" ] && [ "$(rec -1 max_iterations)" = 5 ] && [ "$(shasum -a 256 < "$HIST.$C.retired")" = "$SUM" ]'

new_sandbox; INIT 10 >/dev/null 2>&1; RUN; A1=$(rec 1 reviewed_diff_hash)
setfm 'reviewed_diff_hash="0000000000000000000000000000000000000000000000000000000000000000"'
rc=0; LITMUS_MODE=pr INIT 10 >/dev/null 2>&1 || rc=$?
check "state present: the retirement binds the FAIL verdict's diff, fingerprint and head, not the state's" '[ "$rc" = 0 ] && [ "$(rec -1 event)" = retire ] && [ "$(rec -1 reviewed_diff_hash)" = "$A1" ] && [[ "$(rec -1 fingerprint)" =~ ^[0-9a-f]{32}$ ]] && [ "$(rec -1 reviewed_head_sha)" = "$(git rev-parse HEAD)" ]'

new_sandbox; INIT 10 >/dev/null 2>&1; RUN
ledger_add event=pass "lineage_id=$(fm lineage_id)" "cycle_id=$(fm cycle_id)" review_basis=pr_dual
rc=0; LITMUS_MODE=pr INIT 10 >/dev/null 2>&1 || rc=$?
check "a review completion over a FAIL verdict makes the ledger unreadable — nothing retired or opened" '[ "$rc" = 1 ] && [ "$(count retire)" = 0 ] && [ "$(count open)" = 1 ]'

new_sandbox; INIT 10 >/dev/null 2>&1; RUN
ledger_add event=pass "lineage_id=$(fm lineage_id)" "cycle_id=$(fm cycle_id)" review_basis=dispatched "head_sha=$(git rev-parse HEAD)"
rc=0; LITMUS_MODE=pr INIT 10 >/dev/null 2>&1 || rc=$?
check "a commit completion over a commit FAIL at its own head is unreadable (status alone) — nothing retired or opened" '[ "$rc" = 1 ] && [ "$(count retire)" = 0 ] && [ "$(count open)" = 1 ]'

new_sandbox; echo pass > .mock/mode; INIT 10 >/dev/null 2>&1; RUN; echo fail > .mock/mode
python3 -c 'import json; p=".claude/litmus-lineage.local.jsonl"; rs=[json.loads(l) for l in open(p) if l.strip()]; rs[-1].pop("head_sha"); open(p, "w").write("".join(json.dumps(r, sort_keys=True) + "\n" for r in rs))'
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "a review completion without the head its PASS verdict names is unreadable — nothing opened" '[ "$(rec -1 review_basis)" = dispatched ] && [ -n "$(rec -2 head_sha)" ] && [ "$rc" = 1 ] && [ "$(count open)" = 1 ]'

echo "── 16. Stall, ceiling and killed runs cannot launder through state deletion; stale PR artifacts stay stale"
new_sandbox; INIT 10 >/dev/null 2>&1; C=$(fm cycle_id); RUN; RUN      # a FAIL, then the same findings
check "stall: settled, state kept active" '[ "$(fm terminal_status)" = stall ] && [ "$(events)" = "open attempt verdict attempt verdict" ]'
rc=0; LITMUS_MODE=pr INIT 10 >/dev/null 2>&1 || rc=$?
check "stall with its state: the other mode is refused" '[ "$rc" != 0 ] && [ "$(count retire)" = 0 ] && [ "$(fm cycle_id)" = "$C" ]'
rm -f .claude/litmus-state.md; before=$(events)
rc=0; out=$(LITMUS_MODE=pr INIT 10 2>&1) || rc=$?
check "stall, state removed: the other mode refuses at 14 — nothing retired or opened" '[ "$rc" = 14 ] && [ "$(events)" = "$before" ] && [ ! -e .claude/litmus-state.md ] && printf "%s" "$out" | grep -q "never retired"'
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "stall, state removed: the same mode resumes that cycle, both debits and its history" '[ "$rc" = 0 ] && [ "$(fm cycle_id)" = "$C" ] && [ "$(fm attempts_consumed)" = 2 ] && [ "$(count open)" = 1 ] && grep -q deterministic "$HIST"'
RUN
check "stall, removed and resumed: the same findings stall again — the memory survived the rm" '[ "$(fm terminal_status)" = stall ] && [ "$(count attempt)" = 3 ] && [ "$(count open)" = 1 ]'

new_sandbox; INIT 1 >/dev/null 2>&1; C=$(fm cycle_id); RUN; RUN      # a FAIL, then refused past ceiling 1
check "ceiling: the second run is refused undebited" '[ "$(fm terminal_status)" = max_iterations ] && [ "$(count attempt)" = 1 ]'
rm -f .claude/litmus-state.md; before=$(events)
rc=0; out=$(LITMUS_MODE=pr INIT 10 2>&1) || rc=$?
check "max_iterations, state removed: the other mode refuses at 14 — no retirement, no fresh lineage" '[ "$rc" = 14 ] && [ "$(events)" = "$before" ] && [ ! -e .claude/litmus-state.md ]'
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?; RUN || true
check "max_iterations, state removed: the same mode resumes at ceiling 1 and is refused again, undebited" '[ "$rc" = 0 ] && [ "$(fm cycle_id)" = "$C" ] && [ "$(fm max_iterations)" = 1 ] && [ "$(fm terminal_status)" = max_iterations ] && [ "$(count attempt)" = 1 ] && [ "$(count open)" = 1 ]'

new_sandbox; INIT 10 >/dev/null 2>&1; C=$(fm cycle_id); L=$(fm lineage_id)
echo kill > .mock/mode; RUN >/dev/null 2>&1; echo fail > .mock/mode
rm -f .claude/litmus-review.lock .claude/litmus-state.md; before=$(events)
rc=0; out=$(LITMUS_MODE=pr INIT 10 2>&1) || rc=$?
check "killed mid-review, state removed: the other mode refuses at 14 — no new lineage" '[ "$before" = "open attempt" ] && [ "$rc" = 14 ] && [ "$(events)" = "$before" ] && [ ! -e .claude/litmus-state.md ] && printf "%s" "$out" | grep -q "no recorded verdict"'
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "killed mid-review, state removed: the same mode resumes that cycle at its charged iteration, no second open" '[ "$rc" = 0 ] && [ "$(fm cycle_id)" = "$C" ] && [ "$(fm lineage_id)" = "$L" ] && [ "$(fm iteration)" = 1 ] && [ "$(fm attempts_consumed)" = 1 ] && [ "$(count open)" = 1 ]'
RUN || true
check "killed, removed, resumed: the re-dispatch is charged on that cycle and settles it" '[ "$(count attempt)" = 2 ] && [ "$(rec -1 event)" = verdict ] && [ "$(rec -1 cycle_id)" = "$C" ] && [ "$(rec -1 settles_seq)" = 2 ]'
check "killed, removed, resumed: the killed attempt is settled as interrupted before the re-dispatch — both debits kept" '[ "$(events)" = "open attempt abandon attempt verdict" ] && [ "$(rec 2 abandon_reason)" = interrupted ] && [ "$(rec 2 settles_seq)" = 1 ] && [ "$(rec 2 head_sha)" = "$(rec 1 head_sha)" ] && [ "$(LIB ledger_query fold "$L")" = "2 10" ]'

# Every attempt settled: killed attempt 1, retry 2 PASS, with no disposition for 1.
new_sandbox; INIT 10 >/dev/null 2>&1; C=$(fm cycle_id); L=$(fm lineage_id); H=$(git rev-parse HEAD)
ledger_add event=attempt "lineage_id=$L" "cycle_id=$C" iteration=1 reviewed_diff_hash=deadbeef "head_sha=$H"
cp "$LEDGER" .mock/ledger.one
ledger_add event=attempt "lineage_id=$L" "cycle_id=$C" iteration=1 reviewed_diff_hash=deadbeef "head_sha=$H"
cp "$LEDGER" .mock/ledger.two
rc=0; LIB ledger_verdict "$L" "$C" PASS empty commit "$H" || rc=$?
check "barrier: a verdict for retry 2 is refused while attempt 1 has no disposition — nothing appended" '[ "$rc" != 0 ] && [ "$(events)" = "open attempt attempt" ]'
cp .mock/ledger.two "$LEDGER"
python3 -c 'import json,sys; open(sys.argv[1], "a").write(json.dumps({"event": "verdict", "lineage_id": sys.argv[2], "cycle_id": sys.argv[3], "status": "pass", "settles_seq": 2, "fingerprint": "empty", "review_mode": "commit", "head_sha": sys.argv[4]}, sort_keys=True) + "\n")' "$LEDGER" "$L" "$C" "$H"
rc=0; LIB ledger_query usable || rc=$?
check "barrier: a hand-written retry verdict over an unsettled attempt 1 makes the ledger unreadable" '[ "$rc" = 4 ]'
cp .mock/ledger.two "$LEDGER"; echo pass > .mock/mode
rc=0; RUN || rc=$?
check "barrier: two attempts with no disposition cannot be settled truthfully — dispatch refused, nothing charged" '[ "$rc" = 1 ] && [ "$(events)" = "open attempt attempt" ] && [ ! -e .claude/litmus-passed.local ]'
cp .mock/ledger.one "$LEDGER"; rm -f .claude/litmus-review.lock; setfm 'terminal_status="infra_failure"'
rc=0; RUN || rc=$?
check "barrier, positive: the real retry settles attempt 1 as interrupted, charges 2, passes and completes" '[ "$rc" = 0 ] && [ "$(events)" = "open attempt abandon attempt verdict pass" ] && [ "$(rec 2 abandon_reason)" = interrupted ] && [ "$(rec 2 settles_seq)" = 1 ] && [ "$(rec -2 settles_seq)" = 2 ] && [ "$(LIB ledger_query fold "$L")" = "2 10" ] && LIB ledger_query usable && [ -s .claude/litmus-passed.local ]'

# Crash cut after a commit PASS was recorded, before state removal: the stale state is refused at
# dispatch — nothing charged, nothing completed twice, no marker, the ledger still reads.
new_sandbox; echo pass > .mock/mode; INIT 10 >/dev/null 2>&1; cp .claude/litmus-state.md .mock/state.pre
RUN; cp .mock/state.pre .claude/litmus-state.md; rm -f .claude/litmus-passed.local; before=$(events)
rc=0; RUN || rc=$?
check "commit PASS crash cut: the closed cycle is refused at dispatch — no debit, no second pass, no marker" '[ "$before" = "open attempt verdict pass" ] && [ "$rc" = 1 ] && [ "$(events)" = "$before" ] && [ ! -e .claude/litmus-passed.local ] && LIB ledger_query usable && grep -q "already completed" .mock/run.log'

# Criterion 11: artifacts voiced before a retirement are never revived by it.
pr_refuse_sandbox
ledger_add event=attempt "lineage_id=$L1" "cycle_id=$C1" iteration=1 reviewed_diff_hash=deadbeef
setfm iteration=2 'review_status="FAIL"' 'terminal_status="review_findings"' 'reviewed_diff_hash="deadbeef"' attempts_consumed=1
voice pr-codex-lead.local.json codex; voice pr-backstop-verdict.local.json opus
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
echo later >> seed.txt; git commit -qam later
rc2=0; MARKER || rc2=$?
check "criterion 11: the retirement mints nothing, and once the diff moves the old PR artifacts are rejected" '[ "$rc" = 0 ] && [ "$(count retire)" = 1 ] && [ "$rc2" = 1 ] && [ ! -e .claude/pr-review-passed.local ] && [ ! -e .claude/litmus-passed.local ]'

echo "── 16. The real PR-lead writer and the pr_fast completion, driven through the runner"
# FIXTURE, NOT model judgment. The stub CLI returns a canned PASS so the runner's own PR PASS
# path executes for real: write_codex_lead_verdict and the LITMUS_PR_FAST branch are the
# production entrypoints here, and nothing is hand-written into their artifacts. What this
# proves is the wiring — binding, identity, ledger accounting, marker shape. It proves
# NOTHING about review quality: no model was asked, and a stub PASS is not a PASS.
pr_pass_sandbox() {
    new_sandbox
    git commit -q -m target
    git update-ref refs/remotes/origin/main "$(git rev-parse HEAD~1)"
    git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
    cat > "$S.bin/codex" <<CODEX
#!/bin/sh
case "\$1" in --version) echo "codex-fixture 0.0.0"; exit 0 ;; esac
cat > /dev/null 2>&1 || true
echo "call \$1" >> "$S/.mock/calls"
printf '%s\n' '{"status":"PASS","issues":[]}'
CODEX
    printf '#!/bin/sh\nexit 0\n' > "$S.bin/droid"
    chmod +x "$S.bin/codex" "$S.bin/droid"
    # The codex arm takes the node companion (resolve-cli.sh:3771) only when BOTH a trusted
    # companion AND a trusted node resolve. The companion comes from the operator's
    # password-DB home and has no env seam — a test must never touch that. node is the
    # conjunct a fixture can answer honestly: _resolve_trusted_cli_bin refuses a runtime
    # resolving INSIDE the reviewed checkout (#803, resolve-cli.sh:666), so an in-tree node
    # sends the dispatch down the documented direct-CLI fallback (:3816) and into the stub
    # above. Executable on purpose — the PATH walk SKIPS a non-executable file (:647)
    # instead of refusing on it, so a `touch`ed dud would silently restore the companion.
    # This directory must hold node and nothing else: a codex here would be refused too.
    mkdir -p "$S/.mock/shadow"
    printf '#!/bin/sh\nexit 127\n' > "$S/.mock/shadow/node"
    chmod +x "$S/.mock/shadow/node"
    LITMUS_MODE=pr INIT 10 >/dev/null 2>&1
    C1=$(fm cycle_id); L1=$(fm lineage_id)
}
# The reviewer binary is the fixture's own, reached through PATH alone. _resolve_trusted_cli_bin
# (resolve-cli.sh:553) is a PATH WALK whose only constraint is that the hit physicalizes
# OUTSIDE the reviewed checkout; $S.bin is a mktemp sibling of the sandbox repo, so PR_RUN's
# PATH prefix already satisfies it. (An earlier version of this fixture also exported
# _BD_CODEX_PINNED_BIN, on the belief that PATH could not reach the stub. That export was
# inert: execute_review clears the variable at resolve-cli.sh:4384 before _execute_codex
# reads it, and the pin is re-set only for an absolute CLI equal to the trusted hit. The
# stub was always being reached by PATH; the companion arm was the real blocker.)
# LITMUS_TIMEOUT is scoped HERE, never suite-wide: :68's mock deliberately blocks a dispatch
# for up to 120s, and a global cap would kill it and read as a regression.
PR_PASS_RUN() { PATH="$S/.mock/shadow:$PATH" LITMUS_TIMEOUT=25 PR_RUN; }
LEAD=.claude/pr-codex-lead.local.json
pr_pass_sandbox
rc=0; PR_PASS_RUN || rc=$?
[ -n "${LITMUS_FIXTURE_LOG:-}" ] && cp "$S/.mock/run.log" "$LITMUS_FIXTURE_LOG" 2>/dev/null
check "PR lead writer: a PR PASS writes the lead artifact through the production writer" '[ "$rc" = 0 ] && [ -f "$LEAD" ] && grep -q "\"status\":\"PASS\"" "$LEAD" && grep -q "\"model\":\"codex\"" "$LEAD"'
check "PR lead artifact is bound to a reviewed diff hash and names this cycle and lineage" 'grep -q "\"cycle_id\":\"$C1\"" "$LEAD" && grep -q "\"lineage_id\":\"$L1\"" "$LEAD" && grep -q "\"diff_hash\":\"[0-9a-f]\{64\}\"" "$LEAD"'
check "PR lead PASS alone publishes no PR marker and does not complete the cycle" '[ ! -e .claude/pr-review-passed.local ] && [ "$(count pass)" = 0 ]'

# The audited fast bypass: the SAME production branch, with LITMUS_PR_FAST=1.
pr_pass_sandbox
rc=0; LITMUS_PR_FAST=1 PR_PASS_RUN || rc=$?
check "pr_fast: the fast marker is written, diff-bound, and is not a bare hash" '[ "$rc" = 0 ] && grep -q "^PASS-FAST-[0-9a-f]\{64\}-[0-9]\{1,\}$" .claude/pr-review-passed.local'
check "pr_fast: the cycle is completed exactly once, recorded as pr_fast before the marker" '[ "$(count pass)" = 1 ] && [ "$(rec -1 event)" = pass ] && [ "$(rec -1 cycle_id)" = "$C1" ] && [ "$(rec -1 review_basis)" = pr_fast ]'
check "pr_fast: the bypass is audited" 'grep -q "\"event\":\"pr-fast-bypass\"" .claude/bypass-log.jsonl'
check "pr_fast: no Codex lead artifact is minted on the fast path" '[ ! -e "$LEAD" ]'

# === 17. Watchdog lifetime and ownership =============================================
# The dispatch child's ONLY containment is the watchdog forked by _orphan_watch_start.
# It was losable two ways; both are closed, and each case below fails without its fix.
#
# THE RUNNER'S PARENT IS LOAD-BEARING, and is why the SIGKILL check above is not enough on
# its own. There the runner is a foreground child of this test's bash, which reaps in its
# SIGCHLD handler, so the runner's zombie lasts microseconds. The watchdog used to poll
# `kill -0` on the runner — which SUCCEEDS on a zombie, while the dispatch child has
# ALREADY been reparented — so against a slower-reaping parent the ownership test cleared
# itself on the runner's own death and abandoned the review. That race was reproduced
# 10/10 against a 0.3s-reaping parent in a standalone model of this code path.
#
# HONEST LIMIT, do not overclaim from a green here: SLOW_RUN supplies that slow parent, but
# the SIGKILL case below passes against the PRE-FIX runner too (verified by running this
# suite with LITMUS_TRANSITION_SRC pointed at the unfixed tree). So it is a REGRESSION GUARD
# for the zombie-ownership fix, NOT a proof of it — something in this harness (dispatch is
# mocked and near-instant) keeps the window from opening. The TERM cases below DO
# discriminate: they fail against the pre-fix runner. Anyone tightening this file should fix
# the SIGKILL case's discriminating power rather than trust its green.
SLOW_RUN() {
    PATH="$S.bin:$PATH" BUSDRIVER_REVIEW_CLI=agy CLAUDE_PLUGIN_ROOT="$S" LITMUS_SKIP_SAST=1 \
    LITMUS_SKIP_CONTEXT=1 LITMUS_SKIP_MARKDOWN=1 LITMUS_DOCS_CONTEXT=0 LITMUS_SHORTCIRCUIT_DISABLED=1 \
    /usr/bin/perl -e '$p = fork; if (!$p) { exec "/bin/bash", @ARGV } select undef, undef, undef, 0.3; waitpid $p, 0' \
        "$S/skills/litmus/scripts/run-review-loop.sh" >> "$S/.mock/run.log" 2>&1
}
# $1 = signal the mock sends the runner, $2 = RUN (prompt-reaping parent) or SLOW_RUN.
# The trailing sleep is what makes the verdict sound rather than lucky: the abandoned
# review only announces itself 2s after the runner dies, so a check that runs immediately
# would pass whether or not the reap happened.
watch_case() {
    new_sandbox
    INIT 5 >/dev/null 2>&1
    printf '%s\n' "$1" > .mock/killsig
    echo kill > .mock/mode
    "$2" >/dev/null 2>&1 || true
    sleep 3
}

check "watchdog: perl is available to host the delayed-reaping parent" '[ -x /usr/bin/perl ]'

watch_case 9 SLOW_RUN
check "watchdog: a SIGKILLed runner whose own parent reaps LATE still reaps its review child" '[ ! -e .mock/orphan-alive ]'
rm -f .claude/litmus-review.lock

# A CATCHABLE signal runs the EXIT trap, and that trap used to stop the watchdog while the
# review was still outstanding — reaping nothing in its place, because its _bs_reap_group
# covers the backstop, not the dispatch. So the containment was inverted: SIGKILL (no trap)
# was contained and TERM (trap) was not. Measured before the fix: -15 orphaned 3/3.
watch_case 15 RUN
check "watchdog: a TERMed runner does not lose its review child to its own cleanup" '[ ! -e .mock/orphan-alive ]'
check "watchdog: the guarded EXIT trap still runs its remaining cleanup (lock released)" '[ ! -e .claude/litmus-review.lock ]'
rm -f .claude/litmus-review.lock

watch_case 15 SLOW_RUN
check "watchdog: TERM plus a late-reaping parent — both losses closed at once" '[ ! -e .mock/orphan-alive ]'
rm -f .claude/litmus-review.lock

# Negative control: nothing is signalled when there is nothing of ours to signal. The review
# completes, `wait` reaps it, and the watchdog is stopped having never fired. This is the
# observable consequence of the ownership latch being revocable while the runner is alive —
# a latch that could not be revoked would fire here.
new_sandbox; echo pass > .mock/mode; INIT 5 >/dev/null 2>&1
rc=0; RUN >/dev/null 2>&1 || rc=$?
sleep 3
check "watchdog negative: a completed, reaped review is never signalled and leaves no orphan" '[ "$rc" = 0 ] && [ ! -e .mock/orphan-alive ]'
check "watchdog negative: a healthy run still releases its lock and completes normally" '[ ! -e .claude/litmus-review.lock ] && grep -q "PASS - No issues found" "$S/.mock/run.log"'
echo fail > .mock/mode

# === 18. the two blocking MEDIUMs of the native review of candidate 23f4df0a ===

# (a) THE ARMING WINDOW. Containment used to be set up AFTER the review was dispatched: two
# `ps` calls and a fork, all while the review was already running. A runner killed in there
# left a live review with nothing to reap it, and because the window held fork+exec of `ps`,
# a slow `ps` widened it at will. Moving the observation earlier (twice) only moved the
# window; the fix is ORDERING — the watchdog is forked BEFORE the dispatch and the runner
# hands it the pid through a private file.
#
# Both cases below drive the PRODUCTION order and kill the runner with SIGKILL; both must
# still reap. The slow `ps` shim is what makes the timing certain rather than probable.
#   $1 = seconds to settle after the handoff before killing.
#        empty -> kill in the OLD window: the watchdog is still inside _runner_alive and has
#                 NOT yet taken the handoff, so only the last-chance read saves the review.
#        0.3   -> kill once containment is fully established (the original regression guard).
WATCH_PREARM() {
    local d; d=$(mktemp -d "$ROOT/est.XXXXXX")
    (
      cd "$d" || exit 9
      mkdir -p bin
      printf '#!/bin/bash\nsleep 0.5\nexec /bin/ps "$@"\n' > bin/ps; chmod +x bin/ps
      printf '%s' "$1" > settle
      sed -n '/^_bs_reap_group()/,/^}/p'      "$SRC/skills/litmus/scripts/run-review-loop.sh" >  funcs.sh
      sed -n '/^_orphan_watch_start()/,/^}/p' "$SRC/skills/litmus/scripts/run-review-loop.sh" >> funcs.sh
      grep -q '_orphan_watch_start' funcs.sh || exit 9
      cat > parent.sh <<'P'
PATH="$PWD/bin:$PATH"
source ./funcs.sh
hand="$PWD/handoff"
: > "$hand"
_orphan_watch_start "$hand"          # armed BEFORE the review exists
sleep 300 &                          # the review
_child=$!
echo "$_child" > childpid
printf '%s\n' "$_child" > "$hand"    # the handoff: one builtin write, no fork
[ -s settle ] && sleep "$(cat settle)"
kill -9 $$
P
      bash parent.sh >/dev/null 2>&1
      c=$(cat childpid 2>/dev/null)
      sleep 5
      if kill -0 "$c" 2>/dev/null; then kill -9 "$c" 2>/dev/null; exit 1; fi
      exit 0
    )
}
prearm_rc=0; WATCH_PREARM "" || prearm_rc=$?
check "watchdog: a runner killed in the OLD pre-arm window still reaps its review child" '[ "$prearm_rc" = 0 ]'
est_rc=0; WATCH_PREARM 0.3 || est_rc=$?
check "watchdog: a runner killed inside the ESTABLISHMENT window still reaps its review child" '[ "$est_rc" = 0 ]'

# The ordering itself, pinned. Three rounds of this defect were re-found at a new point each
# time; prose in the function header will not survive a future reorder, and this will.
check "watchdog: containment is ARMED BEFORE the review is dispatched" '
  _f="$SRC/skills/litmus/scripts/run-review-loop.sh"
  _arm=$(grep -n "_orphan_watch_start \"" "$_f" | head -1 | cut -d: -f1)
  _dis=$(grep -n "^execute_review " "$_f" | head -1 | cut -d: -f1)
  [ -n "$_arm" ] && [ -n "$_dis" ] && [ "$_arm" -lt "$_dis" ]'
# ...and that a FAILED arming refuses between those two lines rather than falling through.
# Structural, and labelled as such: the runner hardens PATH and TMPDIR before it reaches the
# dispatch block, so no injection available to this harness can make the real arming fail.
# The behavioural half is the contract check below, which does discriminate.
check "watchdog: a failed arming exits before the dispatch line" '
  _f="$SRC/skills/litmus/scripts/run-review-loop.sh"
  _arm=$(grep -n "_orphan_watch_start \"" "$_f" | head -1 | cut -d: -f1)
  _dis=$(grep -n "^execute_review " "$_f" | head -1 | cut -d: -f1)
  sed -n "${_arm},${_dis}p" "$_f" | grep -q "exit 1"'

# (b) The lineage-ledger reader must FAIL CLOSED on records that cannot be true of one
# cycle. Reader exit 4 is its malformed-ledger refusal; 0 is acceptance.
LEDGER_RC() {   # jsonl on stdin -> reader exit code on stdout
    local d; d=$(mktemp -d "$ROOT/led.XXXXXX")
    cat > "$d/litmus-lineage.local.jsonl"
    (
      # BUSDRIVER_STATE_DIR, not STATE_DIR: the library opens with
      # STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}", so it OVERWRITES an exported STATE_DIR
      # and the ledger path stays the relative .claude/... of whatever the cwd happens to
      # be. Exporting the wrong one does not fail loudly — it silently points the fixture,
      # and the reader, at the caller's REAL ledger.
      BUSDRIVER_STATE_DIR="$d"; export BUSDRIVER_STATE_DIR
      # shellcheck disable=SC1090,SC1091
      source "$SRC/skills/litmus/scripts/lib/iteration-history.sh" >/dev/null 2>&1
      [ "$LINEAGE_LEDGER_FILE" = "$d/litmus-lineage.local.jsonl" ] || { echo 99; exit 0; }
      ledger_query usable >/dev/null 2>&1; echo $?
    )
}
_LL=0e45d40592d1432288f2b97b2aaad63e
_CA=11111111111111111111111111111111
_CB=22222222222222222222222222222222
_CC=33333333333333333333333333333333
_L_OPEN="{\"event\":\"open\",\"lineage_id\":\"$_LL\",\"cycle_id\":\"$_CA\",\"max_iterations\":1,\"review_mode\":\"commit\"}"
_L_PASS="{\"event\":\"pass\",\"lineage_id\":\"$_LL\",\"cycle_id\":\"$_CA\",\"review_basis\":\"none\"}"
_L_ATT="{\"event\":\"attempt\",\"lineage_id\":\"$_LL\",\"cycle_id\":\"$_CA\",\"iteration\":1}"
_L_VERD="{\"event\":\"verdict\",\"lineage_id\":\"$_LL\",\"cycle_id\":\"$_CA\",\"status\":\"pass\",\"settles_seq\":1,\"fingerprint\":\"empty\",\"review_mode\":\"commit\"}"
_L_DISP="{\"event\":\"pass\",\"lineage_id\":\"$_LL\",\"cycle_id\":\"$_CA\",\"review_basis\":\"dispatched\"}"
_L_RET_B="{\"event\":\"retire\",\"lineage_id\":\"$_LL\",\"cycle_id\":\"$_CA\",\"successor_cycle_id\":\"$_CB\",\"target_mode\":\"pr\",\"max_iterations\":1,\"iteration\":1}"
_L_RET_C="{\"event\":\"retire\",\"lineage_id\":\"$_LL\",\"cycle_id\":\"$_CA\",\"successor_cycle_id\":\"$_CC\",\"target_mode\":\"pr\",\"max_iterations\":1,\"iteration\":1}"
# The operand of a real retirement is a FAIL verdict with a findings fingerprint (the
# `operand` op in lib/iteration-history.sh, and _t_operand in init-review-loop.sh, which
# refuses `owed` — a PASS whose completion is still outstanding).
_L_FP=abcdef0123456789abcdef0123456789
_L_VERD_FAIL="{\"event\":\"verdict\",\"lineage_id\":\"$_LL\",\"cycle_id\":\"$_CA\",\"status\":\"fail\",\"settles_seq\":1,\"fingerprint\":\"$_L_FP\",\"review_mode\":\"commit\"}"

led_rc=$(printf '%s\n' "$_L_OPEN" "$_L_PASS" "$_L_ATT" | LEDGER_RC)
check "ledger: an attempt charged AFTER the cycle completed is refused" '[ "$led_rc" = 4 ]'
led_rc=$(printf '%s\n' "$_L_OPEN" "$_L_PASS" "$_L_RET_B" | LEDGER_RC)
check "ledger: a retirement of an already-COMPLETED cycle is refused" '[ "$led_rc" = 4 ]'
led_rc=$(printf '%s\n' "$_L_OPEN" "$_L_RET_B" "$_L_RET_C" | LEDGER_RC)
check "ledger: a predecessor retired TWICE (distinct successors) is refused" '[ "$led_rc" = 4 ]'

# A RETIREMENT is terminal for the cycle it retires, exactly as a completion is. These three
# were accepted before the shared terminal guard: each leaves an attempt/verdict as the newest
# record of the lineage, so eligible() resurrects the retired PREDECESSOR as unresolved work
# and the pending retirement of its successor is never seen. Measured against the pre-fix
# reader, all three returned 0.
led_rc=$(printf '%s\n' "$_L_OPEN" "$_L_RET_B" "$_L_ATT" | LEDGER_RC)
check "ledger: an attempt charged on a RETIRED predecessor is refused" '[ "$led_rc" = 4 ]'
led_rc=$(printf '%s\n' "$_L_OPEN" "$_L_RET_B" "$_L_PASS" | LEDGER_RC)
check "ledger: a completion of a RETIRED predecessor is refused" '[ "$led_rc" = 4 ]'
led_rc=$(printf '%s\n' "$_L_OPEN" "$_L_ATT" "$_L_RET_B" "$_L_VERD" | LEDGER_RC)
check "ledger: a verdict settling an attempt on a RETIRED predecessor is refused" '[ "$led_rc" = 4 ]'

# Positive controls — the tightening must not reject ledgers that are legitimate today.
led_rc=$(printf '%s\n' "$_L_OPEN" "$_L_ATT" "$_L_VERD" "$_L_DISP" | LEDGER_RC)
check "ledger control: open + attempt + pass verdict + dispatched completion still parses" '[ "$led_rc" = 0 ]'
led_rc=$(printf '%s\n' "$_L_OPEN" "$_L_RET_B" | LEDGER_RC)
check "ledger control: a single retirement still parses" '[ "$led_rc" = 0 ]'
led_rc=$(printf '%s\n' "$_L_OPEN" | LEDGER_RC)
check "ledger control: a lone open still parses" '[ "$led_rc" = 0 ]'
# The production shape of a retirement: its operand is the newest settling verdict, and that
# verdict is a FAIL. An earlier revision of this control used _L_VERD (a PASS) and asserted
# it parses — that fixture was WRONG, and it pinned exactly the sequence the reader must
# refuse, so it would have failed the correct tightening. Corrected here rather than worked
# around; the PASS case is now a refusal two checks below.
led_rc=$(printf '%s\n' "$_L_OPEN" "$_L_ATT" "$_L_VERD_FAIL" "$_L_RET_B" | LEDGER_RC)
check "ledger control: a retirement on its FAIL operand still parses" '[ "$led_rc" = 0 ]'

# === 19. the two blocking MEDIUMs of the native review of candidate 2950851d ===
# Enumerated rather than sampled: a retirement is legitimate only while the cycle owes
# nothing, which is what _t_operand checks through the `operand` op before it appends one.
# Of its refusals, two are STRUCTURAL and belong in the reader — `unsettled` (the terminal
# guard means that attempt can never be settled afterwards) and `owed` (a PASS whose
# completion was never recorded). `none` is NOT one of them: a cycle with no settling record
# stays retirable, which the control below pins so the tightening cannot overshoot.
led_rc=$(printf '%s\n' "$_L_OPEN" "$_L_ATT" "$_L_VERD" "$_L_RET_B" | LEDGER_RC)
check "ledger: a retirement over a cycle still OWED a completion is refused" '[ "$led_rc" = 4 ]'
# UNSETTLED is SOME settling record with others missing — attempt 1 settled, attempt 2 not.
# It is NOT "a cycle with no verdicts": that is operand `none`, the live path where attempts
# predate verdicts, and both controls below pin it so this guard cannot overshoot again.
_L_ATT2="{\"event\":\"attempt\",\"lineage_id\":\"$_LL\",\"cycle_id\":\"$_CA\",\"iteration\":2}"
led_rc=$(printf '%s\n' "$_L_OPEN" "$_L_ATT" "$_L_VERD_FAIL" "$_L_ATT2" "$_L_RET_B" | LEDGER_RC)
check "ledger: a retirement over a cycle with an UNSETTLED attempt is refused" '[ "$led_rc" = 4 ]'
led_rc=$(printf '%s\n' "$_L_OPEN" "$_L_RET_B" | LEDGER_RC)
check "ledger control: a retirement with NO settling record still parses" '[ "$led_rc" = 0 ]'
led_rc=$(printf '%s\n' "$_L_OPEN" "$_L_ATT" "$_L_RET_B" | LEDGER_RC)
check "ledger control: a retirement whose attempts PREDATE verdicts still parses" '[ "$led_rc" = 0 ]'

# The reader and ledger_append must agree that every record ends with a newline. Without
# that agreement the reader accepts a file whose last line has none, and the next append
# lands on that same line — so a ledger that parsed cleanly becomes unparseable AFTER an
# attempt has been charged against it. printf '%s' (no \n) is the payload.
led_rc=$(printf '%s' "$_L_OPEN" | LEDGER_RC)
check "ledger: a single record with NO trailing newline is refused" '[ "$led_rc" = 4 ]'
led_rc=$(printf '%s\n%s' "$_L_OPEN" "$_L_ATT" | LEDGER_RC)
check "ledger: a multi-record ledger with NO trailing newline is refused" '[ "$led_rc" = 4 ]'

# === 20. the two blocking HIGHs of the native review of candidate b366331d ===
# Shared class: assigned late or only on some paths, read unconditionally, and NOT cleared by
# the gate environment scrub. Both payloads arrive the way a caller would actually supply
# them — exported into the environment — and are driven through the real scripts.

# (a) THE EXIT TRAP, as a unit. It is installed near the top and runs on every exit path,
# including ones reached long before these variables are assigned. A run with no state file
# exits while reading state, which is exactly such a path. One victim file stands in for all
# ten unlink targets at once, and a live process for the two signal targets.
new_sandbox
echo keepme > "$S/victim.txt"
sleep 300 & _vic_pid=$!
export _REVIEW_OUT_FILE="$S/victim.txt" _INDEX_SNAPSHOT="$S/victim.txt" _diff_tmp="$S/victim.txt" \
       _diff_rc_file="$S/victim.txt" _bs_out="$S/victim.txt" _bs_in="$S/victim.txt" \
       _bs_leaked="$S/victim.txt" EXCL_POLICY_PINNED_TMP="$S/victim.txt" \
       EXCL_LOGIC_PINNED_TMP="$S/victim.txt" _ORPHAN_WATCH_HANDOFF="$S/victim.txt" \
       _ORPHAN_WATCH_PID="$_vic_pid"
RUN >/dev/null 2>&1 || true
unset _REVIEW_OUT_FILE _INDEX_SNAPSHOT _diff_tmp _diff_rc_file _bs_out _bs_in _bs_leaked \
      EXCL_POLICY_PINNED_TMP EXCL_LOGIC_PINNED_TMP _ORPHAN_WATCH_HANDOFF _ORPHAN_WATCH_PID
check "trap: no inherited path is unlinked on an early exit" '[ -f "$S/victim.txt" ] && [ "$(cat "$S/victim.txt")" = keepme ]'
check "trap: an inherited watchdog pid is never signalled" 'kill -0 "$_vic_pid" 2>/dev/null'
kill -9 "$_vic_pid" 2>/dev/null || true

# (b) MODE SELECTION. REVIEW_MODE reads _T_TARGET and _A_MODE unconditionally, but each is
# assigned only on its own path (retirement, resume). On a fresh init neither is local, so an
# inherited value used to win over an explicit LITMUS_MODE — minting a PR cycle where a
# staged commit review was asked for, which is the wrong marker for the wrong gate.
export LITMUS_MODE=commit
new_sandbox
export _T_TARGET=pr
INIT 1 >/dev/null 2>&1 || true
unset _T_TARGET
check "init: an inherited _T_TARGET cannot override LITMUS_MODE=commit" '[ "$(fm review_mode)" = commit ]'
new_sandbox
export _A_MODE=pr
INIT 1 >/dev/null 2>&1 || true
unset _A_MODE
check "init: an inherited _A_MODE cannot override LITMUS_MODE=commit" '[ "$(fm review_mode)" = commit ]'
# Positive control: LITMUS_MODE itself must still select the mode, so the clearing above
# cannot be mistaken for "mode is hard-wired to commit".
new_sandbox
export LITMUS_MODE=pr
INIT 1 >/dev/null 2>&1 || true
export LITMUS_MODE=commit
check "init control: LITMUS_MODE=pr still selects a PR cycle" '[ "$(fm review_mode)" = pr ]'
unset LITMUS_MODE

# === 21. the two blocking MEDIUMs of the native review of candidate ea2f9666 ===
# Shared class: a failure accepted quietly that only becomes fatal after an attempt has been
# charged. Both checks assert the refusal happens AT the failure, not one step later.

# (a) ARMING. The watchdog setup runs under `set +e`; when it could not arm, the runner used
# to dispatch anyway and the review had no reaper at all. A `ps` that answers nothing makes
# the arming fail deterministically (the runner cannot learn its own process group). The
# refusal must happen BEFORE the reviewer is invoked, so the assertion is that no review
# dispatch was made — and the message pins that it refused for THIS reason rather than
# failing earlier for an unrelated one.
# Measured, not assumed: an injected `ps` stub and an unwritable TMPDIR were both tried
# against the real runner and neither reached the arming code — it hardens PATH and TMPDIR
# first, and the review dispatched normally in both. So the failure is exercised where it is
# reachable: on the function itself, extracted exactly as the watchdog cases above do it.
# Pre-fix these returned 0 ("watch nothing") and the caller dispatched anyway.
ARM_RC() {   # $1 = handoff path expression, $2 = 1 to put a silent `ps` on PATH
    local d; d=$(mktemp -d "$ROOT/arm.XXXXXX")
    (
      cd "$d" || exit 9
      mkdir -p bin; printf '#!/bin/bash\nexit 0\n' > bin/ps; chmod +x bin/ps
      [ "$2" = 1 ] && PATH="$d/bin:$PATH"
      sed -n '/^_bs_reap_group()/,/^}/p'      "$SRC/skills/litmus/scripts/run-review-loop.sh" >  f.sh
      sed -n '/^_orphan_watch_start()/,/^}/p' "$SRC/skills/litmus/scripts/run-review-loop.sh" >> f.sh
      grep -q '_orphan_watch_start' f.sh || exit 9
      # shellcheck disable=SC1091
      source ./f.sh
      : > h
      _orphan_watch_start "$1"; rc=$?
      [ -n "${_ORPHAN_WATCH_PID:-}" ] && kill "$_ORPHAN_WATCH_PID" 2>/dev/null
      exit "$rc"
    )
}
arm_rc=0; ARM_RC "" 0 || arm_rc=$?
check "arming: an empty handoff path (a failed mktemp) fails closed" '[ "$arm_rc" != 0 ]'
arm_rc=0; ARM_RC "h" 1 || arm_rc=$?
check "arming: a ps that cannot report our process group fails closed" '[ "$arm_rc" != 0 ]'
arm_rc=0; ARM_RC "h" 0 || arm_rc=$?
check "arming control: a healthy arming still succeeds" '[ "$arm_rc" = 0 ]'

# (b) THE OPEN RECORD. review_mode is what every verdict is compared against, so a birth
# without one is admitted, charged, and refused only at the verdict — one step too late.
_L_OPEN_NOMODE="{\"event\":\"open\",\"lineage_id\":\"$_LL\",\"cycle_id\":\"$_CA\",\"max_iterations\":1}"
_L_OPEN_BADMODE="{\"event\":\"open\",\"lineage_id\":\"$_LL\",\"cycle_id\":\"$_CA\",\"max_iterations\":1,\"review_mode\":\"sideways\"}"
led_rc=$(printf '%s\n' "$_L_OPEN_NOMODE" | LEDGER_RC)
check "ledger: an open record with NO review_mode is refused at the birth" '[ "$led_rc" = 4 ]'
led_rc=$(printf '%s\n' "$_L_OPEN_NOMODE" "$_L_ATT" | LEDGER_RC)
check "ledger: it is refused BEFORE an attempt against it can be counted" '[ "$led_rc" = 4 ]'
led_rc=$(printf '%s\n' "$_L_OPEN_BADMODE" | LEDGER_RC)
check "ledger: an open record with an unusable review_mode is refused" '[ "$led_rc" = 4 ]'
# Controls: both legitimate modes must still parse, so the birth check cannot overshoot.
led_rc=$(printf '%s\n' "$_L_OPEN" | LEDGER_RC)
check "ledger control: an open record with review_mode=commit still parses" '[ "$led_rc" = 0 ]'
led_rc=$(printf '%s\n' "$(printf '%s' "$_L_OPEN" | sed 's/"commit"/"pr"/')" | LEDGER_RC)
check "ledger control: an open record with review_mode=pr still parses" '[ "$led_rc" = 0 ]'

# === 22. the two blocking findings of the native review of candidate 486cf9c3 ===
# Shared class: accounting that does not match what actually happened -- a charged cycle
# that cannot be seen, and a debit for a review that never ran.

# (a) THE KEYLESS CYCLE. unresolved_any is asked ONLY by a checkout that cannot prove a
# lineage key (detached HEAD, shallow clone, unborn branch), and it used to drop keyless
# cycles from the count -- exactly the ones such a checkout may own. A charged keyless cycle
# whose state file was gone reported zero, so init cold-started a fresh lineage over a live
# debit and the attempt budget reset.
new_sandbox; INIT 1 >/dev/null 2>&1
: > "$LEDGER"
ledger_add event=open lineage_id=1111111111111111 cycle_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa max_iterations=1 review_mode=commit
ledger_add event=attempt lineage_id=1111111111111111 cycle_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa iteration=1
check "keyless: a charged cycle with no lineage_key counts as unresolved" '[ "$(LIB ledger_query unresolved_any)" = 1 ]'
check "keyless: and that ledger still reads" 'LIB ledger_query usable'
# Control: a keyless BIRTH is not unresolved work -- only a charge that never settled is,
# so counting keyless cycles must not refuse every detached-HEAD checkout outright.
: > "$LEDGER"
ledger_add event=open lineage_id=1111111111111111 cycle_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa max_iterations=1 review_mode=commit
check "keyless control: an uncharged keyless birth is not unresolved" '[ "$(LIB ledger_query unresolved_any)" = 0 ]'
# Control: the keyed path is untouched and still counts exactly once, not twice.
: > "$LEDGER"
ledger_add event=open lineage_id=2222222222222222 cycle_id=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb max_iterations=1 review_mode=commit lineage_key=deadbeef@br
ledger_add event=attempt lineage_id=2222222222222222 cycle_id=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb iteration=1
check "keyed control: a charged keyed cycle still counts exactly once" '[ "$(LIB ledger_query unresolved_any)" = 1 ]'

# (b) THE DEBIT. The ledger is append-only and no record releases an attempt, so a charge
# for a review that never dispatched is budget the operator cannot get back. The arming
# refusal added last round sat AFTER the charge: a failed arming kept the debit, and at
# max_iterations=1 that exhausted the cycle with no reviewer ever invoked.
#
# STRUCTURAL, and labelled as such. Measured last round: the runner hardens PATH and TMPDIR
# before it reaches the dispatch block, so no injection available to this harness can make
# the real arming fail. What is pinned is the ORDER that the unreachable failure depends on
# -- the debit must sit below the arming refusal and above the dispatch.
check "charge: the debit is written after the arming refusal, not before it" '
  _f="$SRC/skills/litmus/scripts/run-review-loop.sh"
  _arm=$(grep -n "_orphan_watch_start \"" "$_f" | head -1 | cut -d: -f1)
  _chg=$(grep -n "ledger_append attempt " "$_f" | head -1 | cut -d: -f1)
  _dis=$(grep -n "^execute_review " "$_f" | head -1 | cut -d: -f1)
  [ -n "$_arm" ] && [ -n "$_chg" ] && [ -n "$_dis" ] && [ "$_arm" -lt "$_chg" ] && [ "$_chg" -lt "$_dis" ]'
# The behavioural half, which the structural pin cannot give: moving the debit BELOW the
# dispatch would let a review run uncounted, so the reviewer itself reports what the ledger
# held at the moment it was invoked.
new_sandbox
mv "$S.bin/agy" "$S.bin/agy.real"
cat > "$S.bin/agy" <<WRAP
#!/bin/sh
[ "\$1" = --version ] || grep -c '"event": "attempt"' "$S/$LEDGER" > "$S/.mock/at-dispatch" 2>/dev/null
exec "$S.bin/agy.real" "\$@"
WRAP
chmod +x "$S.bin/agy"
INIT 1 >/dev/null 2>&1
rc=0; RUN || rc=$?
check "charge control: the debit is already in the ledger when the reviewer is dispatched" '[ "$(cat "$S/.mock/at-dispatch" 2>/dev/null)" = 1 ]'
check "charge control: a dispatched review is charged exactly once" '[ "$rc" = 1 ] && [ "$(count attempt)" = 1 ] && [ "$(fm attempts_consumed)" = 1 ]'

# === 23. the two blocking findings of the native review of candidate 2550ca27 ===
# Same shared root as section 22, one level out: accounting that cannot see the work it is
# accounting for. A keyed checkout that cannot see a keyless cycle, and a completion that
# cannot see its own cycle once the state file naming it is gone.

# (a) THE KEYED CHECKOUT. R18 taught the READER to count keyless cycles; only the keyless
# CALLER ever asks it. The keyed branch asks pending_retire and unresolved, and both match on
# lineage_key -- which a keyless cycle does not have. So charge on a detached HEAD, delete the
# state, check out the branch, and init cold-started a fresh lineage over the live charge:
# the same budget reset, reachable from any branch instead of only a keyless one.
new_sandbox; INIT 1 >/dev/null 2>&1
rm -f .claude/litmus-state.md
: > "$LEDGER"
ledger_add event=open lineage_id=3333333333333333 cycle_id=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee max_iterations=1 review_mode=commit
ledger_add event=attempt lineage_id=3333333333333333 cycle_id=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee iteration=1
rc=0; INIT 1 >/dev/null 2>&1 || rc=$?
check "keyed checkout refuses to cold-start over a charged keyless cycle" '[ "$rc" != 0 ] && [ "$(count open)" = 1 ]'
# Control: a keyless BIRTH that was never charged is not unresolved work. Refusing on it would
# block every keyed init for the lifetime of the ledger.
rm -f .claude/litmus-state.md
: > "$LEDGER"
ledger_add event=open lineage_id=3333333333333333 cycle_id=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee max_iterations=1 review_mode=commit
rc=0; INIT 1 >/dev/null 2>&1 || rc=$?
check "keyed control: an uncharged keyless birth does not block a keyed init" '[ "$rc" = 0 ]'
# Control: the refusal must be about KEYLESS cycles, not about unresolved_any. Another branch
# keyed charged cycle is none of this checkout business and must not block it.
rm -f .claude/litmus-state.md
: > "$LEDGER"
ledger_add event=open lineage_id=4444444444444444 cycle_id=ffffffffffffffffffffffffffffffff max_iterations=1 review_mode=commit lineage_key=deadbeef@some-other-branch
ledger_add event=attempt lineage_id=4444444444444444 cycle_id=ffffffffffffffffffffffffffffffff iteration=1
rc=0; INIT 1 >/dev/null 2>&1 || rc=$?
check "keyed control: another branch charged cycle does not block this branch" '[ "$rc" = 0 ]'

# (b) THE DELETED STATE. The builtin completion was gated on the state file existing, but
# publication is not: it rides the retained prompt, baseline and reviewed-hash sidecar. Delete
# the state after an external attempt hands off, and the marker published while the ledger kept
# its open/attempt/abandon tail -- so the next init resumed a review that had already finished,
# or refused a mode change. Identity is recovered from the ledger through the one binding the
# arming still carries: the reviewed diff hash.
fallback_sandbox; arming
rm -f .claude/litmus-state.md
rc=0; WRITER "$P" || rc=$?
check "state deleted after the handoff: the marker publishes AND the cycle is still closed" '[ "$rc" = 0 ] && [ "$(cat .claude/litmus-passed.local)" = "BUILTIN-$RH" ] && [ "$(events)" = "open attempt abandon pass" ] && [ "$(lrec)" = "pass $C1 builtin" ] && spent'
# and the whole point of recording it: the next init must not resume the finished cycle.
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "state deleted, cycle closed: the next init opens a new cycle rather than resuming" '[ "$rc" = 0 ] && [ "$(count open)" = 2 ]'
# Control: two unresolved cycles charged at the SAME reviewed hash. A hash could not tell them
# apart, so the completion used to refuse rather than close a cycle it guessed; the arming now
# NAMES its cycle, so the same ledger is no longer ambiguous and the stronger property holds --
# exactly the named cycle closes and the sibling is left untouched.
fallback_sandbox; arming
rm -f .claude/litmus-state.md
ledger_add event=open lineage_id=5555555555555555 cycle_id=99999999999999999999999999999999 max_iterations=1 review_mode=commit
ledger_add event=attempt lineage_id=5555555555555555 cycle_id=99999999999999999999999999999999 iteration=1 "reviewed_diff_hash=$RH"
rc=0; WRITER "$P" || rc=$?
check "same-hash sibling: the completion closes the cycle the arming names, not the sibling" '[ "$rc" = 0 ] && [ "$(cat .claude/litmus-passed.local)" = "BUILTIN-$RH" ] && [ "$(lrec)" = "pass $C1 builtin" ] && [ "$(count pass)" = 1 ] && spent'
# The STALE arming, same binding one attempt out. The hash names the attempt the runner
# debited, so it has to be the cycle NEWEST attempt: matched against any historical attempt,
# an arming whose cycle had since been reviewed again -- on a different diff -- and FAILed
# closed that cycle as a builtin PASS, erasing its findings and handing back the budget it had
# already spent. Nothing is owed here, so the marker publishes (the pre-identity branch), but
# the FAILed cycle must be left exactly as it stands.
fallback_sandbox; arming
L1=$(fm lineage_id); H=$(git rev-parse HEAD)
rm -f .claude/litmus-state.md
ledger_add event=attempt "lineage_id=$L1" "cycle_id=$C1" iteration=2 "head_sha=$H" \
    reviewed_diff_hash=0000000000000000000000000000000000000000000000000000000000000000
LIB ledger_verdict "$L1" "$C1" FAIL ffffffffffffffffffffffffffffffff commit "$H"
before=$(events)
rc=0; WRITER "$P" || rc=$?
check "stale arming: a newer attempt reviewed another diff and FAILed — the old hash closes nothing" '[ "$(count pass)" = 0 ] && [ "$(events)" = "$before" ]'
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "stale arming: the FAILed cycle is resumed with its spent budget, not reopened on a fresh one" '[ "$rc" = 0 ] && [ "$(fm cycle_id)" = "$C1" ] && [ "$(fm attempts_consumed)" = 2 ] && [ "$(count open)" = 1 ]'
# The SAME-DIFF stale arming, which a hash binding structurally cannot see. The runner writes
# the reviewed hash onto the attempt it debits, so a LATER attempt that reviewed the SAME diff
# carries the same hash: narrowing to the newest attempt closed only the different-diff half
# above, and no property of a hash can close this one. The arming names its cycle AND the
# attempt sequence it was made at, a later attempt exists, and the newest record is a settled
# FAIL verdict -- so the completion REFUSES. Publishing is not the safe side here: the armed
# hash IS the staged diff, so a BUILTIN- marker would certify at the gate the very diff whose
# FAIL is already in. Nothing published, nothing recorded, the arming kept for a repaired retry.
fallback_sandbox; arming
L1=$(fm lineage_id); H=$(git rev-parse HEAD)
rm -f .claude/litmus-state.md
ledger_add event=attempt "lineage_id=$L1" "cycle_id=$C1" iteration=2 "head_sha=$H" "reviewed_diff_hash=$RH"
LIB ledger_verdict "$L1" "$C1" FAIL ffffffffffffffffffffffffffffffff commit "$H"
before=$(events)
rc=0; WRITER "$P" || rc=$?
check "same-diff stale arming: a later attempt reviewed the SAME diff and FAILed — the completion refuses" '[ "$rc" != 0 ] && [ ! -e .claude/litmus-passed.local ] && [ "$(count pass)" = 0 ] && [ "$(events)" = "$before" ] && armed'
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "same-diff stale arming: the FAILed cycle keeps its findings and its spent budget" '[ "$(fm cycle_id)" = "$C1" ] && [ "$(fm attempts_consumed)" = 2 ] && [ "$(count open)" = 1 ]'
# Isolates the later-attempt half from the verdict half: attempt 2 on the same diff, still
# UNSETTLED, so there is no verdict to refuse on. The sequence being one out is enough alone.
fallback_sandbox; arming
L1=$(fm lineage_id); H=$(git rev-parse HEAD)
rm -f .claude/litmus-state.md
ledger_add event=attempt "lineage_id=$L1" "cycle_id=$C1" iteration=2 "head_sha=$H" "reviewed_diff_hash=$RH"
before=$(events)
rc=0; WRITER "$P" || rc=$?
check "same-diff stale arming: an unsettled later attempt refuses on the sequence alone" '[ "$rc" != 0 ] && [ ! -e .claude/litmus-passed.local ] && [ "$(count pass)" = 0 ] && [ "$(events)" = "$before" ] && armed'

# === 24. the two blocking findings of the native review of candidate 098f4b58 ===
# One shared root under both: an identity check a SECOND path walks around. The builtin
# completion consulted the arming binding only where the state file was absent; the PR
# completion could only reach a cycle through a lineage key a detached HEAD does not have.

# (a) THE RETAINED STATE. Every later external dispatch clears builtin_handoff before it runs,
# so with the state file KEPT the writer read no cycle from it, never consulted the ledger at
# all, and published -- the stale-arming refusal of the previous round sat one branch away,
# reachable by leaving the state file in place rather than deleting it. On the SAME diff the
# older armed hash still matches the staged index, so that marker authorizes at the gate the
# very diff the later review just FAILed.
fallback_sandbox; arming
L1=$(fm lineage_id); H=$(git rev-parse HEAD)
setfm 'builtin_handoff=null'   # what every later dispatch does before it runs
ledger_add event=attempt "lineage_id=$L1" "cycle_id=$C1" iteration=2 "head_sha=$H" "reviewed_diff_hash=$RH"
LIB ledger_verdict "$L1" "$C1" FAIL ffffffffffffffffffffffffffffffff commit "$H"
before=$(events)
rc=0; WRITER "$P" || rc=$?
check "retained state, later same-diff FAIL: the completion refuses instead of publishing" '[ "$rc" != 0 ] && [ ! -e .claude/litmus-passed.local ] && [ "$(count pass)" = 0 ] && [ "$(events)" = "$before" ] && armed'
# Control: the ordinary state-present completion is what the collapse must keep working --
# same arming, nothing later, state retained and still naming the handoff.
fallback_sandbox; arming
rc=0; WRITER "$P" || rc=$?
check "retained state control: an arming with nothing later still closes its own cycle" '[ "$rc" = 0 ] && [ "$(cat .claude/litmus-passed.local)" = "BUILTIN-$RH" ] && [ "$(lrec)" = "pass $C1 builtin" ] && spent'

# (b) THE KEYLESS PR CYCLE. init permits a cycle on a detached HEAD, where lineage_key is
# empty -- and owed_completion matched only on that key, so the one query that can discharge a
# lead PASS could not see the only kind of cycle such a checkout owns, and a valid completion
# was rejected for the life of the ledger. An empty key reaches keyless cycles by cycle id,
# the way unresolved_any already counts them.
KH=0123456789abcdef0123456789abcdef01234567
new_sandbox; INIT 1 >/dev/null 2>&1
: > "$LEDGER"
ledger_add event=open lineage_id=6666666666666666 cycle_id=77777777777777777777777777777777 max_iterations=1 review_mode=pr
ledger_add event=attempt lineage_id=6666666666666666 cycle_id=77777777777777777777777777777777 iteration=1 "head_sha=$KH"
LIB ledger_verdict 6666666666666666 77777777777777777777777777777777 PASS ffffffffffffffffffffffffffffffff pr "$KH"
check "keyless PR cycle: an empty lineage key finds the completion its lead PASS owes" '[ "$(LIB ledger_query owed_completion "")" = "6666666666666666 77777777777777777777777777777777 $KH" ]'
check "keyless PR cycle: and that ledger still reads" 'LIB ledger_query usable'
# Control: a keyed lookup is untouched and a keyless cycle must not leak into one.
check "keyed control: a key no cycle carries still owes nothing" '[ -z "$(LIB ledger_query owed_completion deadbeef@br)" ]'
# Control: a second keyless cycle opened over the first does not make the lookup ambiguous --
# births are ordered, so the newer one wins and the older is superseded, exactly as the keyed
# lookup behaves (newest(key) is the last record of the key). This control USED to pin the
# opposite, a refusal on "two owed cycles that cannot be told apart"; that reading also left
# the newest cycle unable to ever discharge its own valid completion, and was the half-rule
# that returned a superseded cycle in 32 below.
ledger_add event=open lineage_id=8888888888888888 cycle_id=99999999999999999999999999999999 max_iterations=1 review_mode=pr
ledger_add event=attempt lineage_id=8888888888888888 cycle_id=99999999999999999999999999999999 iteration=1 "head_sha=$KH"
LIB ledger_verdict 8888888888888888 99999999999999999999999999999999 PASS ffffffffffffffffffffffffffffffff pr "$KH"
check "keyless control: the newer keyless cycle wins, and the older is superseded" '[ "$(LIB ledger_query owed_completion "")" = "8888888888888888 99999999999999999999999999999999 $KH" ] && [ "$(LIB ledger_query superseded 77777777777777777777777777777777)" = 1 ]'

# === 25. the two blocking findings of the native review of candidate 5cf8464b ===
# Shared root, one level out from section 24: a binding that describes the cycle it parked
# perfectly and says nothing about the world around it. It cannot see a NEWER cycle opened over
# it, and it conflated "no later attempt" with "the attempt I inherited" -- refusing the one
# fresh review that legitimately inherits none.

# (a) THE LIVE CYCLE. init --force opens a new cycle over a retained arming. Every record of
# the parked cycle is exactly as the arming left it, so no ledger query can tell -- and
# completing it deleted the state and per-run history of the NEW cycle, and would have minted a
# marker over a newer review that had FAILed without publishing.
fallback_sandbox; arming
INIT --force 10 >/dev/null 2>&1
B=$(fm cycle_id); bsum=$(shasum -a 256 < .claude/litmus-state.md)
before=$(events)
rc=0; WRITER "$P" || rc=$?
check "live cycle: an arming parked under an older cycle refuses once a newer one is open" '[ "$rc" != 0 ] && [ ! -e .claude/litmus-passed.local ] && [ "$(count pass)" = 0 ] && [ "$(events)" = "$before" ] && armed'
check "live cycle: the newer cycle keeps its state and its identity" '[ "$(shasum -a 256 < .claude/litmus-state.md)" = "$bsum" ] && [ "$(fm cycle_id)" = "$B" ] && [ "$B" != "$C1" ]'
# Control: the veto is about a DIFFERENT live cycle, not about the state file existing. The
# ordinary retained-state completion of the arming own cycle must still go through.
fallback_sandbox; arming
rc=0; WRITER "$P" || rc=$?
check "live cycle control: the arming still completes the cycle the live state is on" '[ "$rc" = 0 ] && [ "$(lrec)" = "pass $C1 builtin" ] && spent'

# (b) THE FRESH DIRECT BUILTIN. An external attempt FAILs, then litmus is asked again and only
# the builtin reviewer is available. That dispatch charges nothing, so the attempt count has not
# moved and the ledger tail is still the FAIL verdict -- which the previous round read as a
# stale arming and refused, leaving a valid review with no way to complete. The count is the
# no-later-attempt guard; the inherited sequence is 0, because this review inherits no attempt.
new_sandbox; INIT 10 >/dev/null 2>&1
rc=0; RUN >/dev/null 2>&1 || rc=$?
check "fresh builtin setup: the external attempt is charged and settled FAIL" '[ "$(events)" = "open attempt verdict" ] && [ "$(count attempt)" = 1 ]'
C1=$(fm cycle_id); BUILTIN_RUN
arming
check "fresh builtin: the handoff binds the attempt COUNT, and inherits no attempt of its own" '[ "$(sed -n 2p "$HF")" = "$C1 1 0" ]'
rm -f .claude/litmus-state.md
rc=0; WRITER "$P" || rc=$?
check "fresh builtin after an external FAIL: the review completes instead of refusing as stale" '[ "$rc" = 0 ] && [ "$(cat .claude/litmus-passed.local)" = "BUILTIN-$RH" ] && [ "$(lrec)" = "pass $C1 builtin" ] && spent'
# The stale direction is unchanged and already covered above (sections 23(b) and 24(a)): a later
# review charges a later attempt, the count moves, and the same arming is refused. Dropping the
# tail check costs nothing there, because the count was the guard doing the work.

# === 26. the blocking finding of the native review of candidate 818b9223 ===
# THE DELETED STATE, one turn on from 25(a). That veto read the LIVE state file, so removing the
# state file skipped it entirely: force-init cycle B over cycle A retained arming, let B FAIL on
# the same diff, delete the state, and A writer published a marker over B failed review and
# deleted its history -- a marker authorizing at the gate the diff B had just rejected. The
# supersession is decided in the LEDGER instead: a newer cycle born under the same checkout key
# is append-only, so no deletion can hide it.
fallback_sandbox; arming
H=$(git rev-parse HEAD)
INIT --force 1 >/dev/null 2>&1
B=$(fm cycle_id); BL=$(fm lineage_id)
ledger_add event=attempt "lineage_id=$BL" "cycle_id=$B" iteration=1 "head_sha=$H" "reviewed_diff_hash=$RH"
LIB ledger_verdict "$BL" "$B" FAIL ffffffffffffffffffffffffffffffff commit "$H"
rm -f .claude/litmus-state.md
before=$(events)
rc=0; WRITER "$P" || rc=$?
check "state gone, newer cycle FAILed: the superseded arming refuses without the state file" '[ "$rc" != 0 ] && [ ! -e .claude/litmus-passed.local ] && [ "$(count pass)" = 0 ] && [ "$(events)" = "$before" ] && armed && [ "$B" != "$C1" ]'
# and the point of refusing: the newer FAIL keeps its findings and its spent budget.
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "state gone, superseded arming: the newer FAILed cycle is what the next init resumes" '[ "$(fm cycle_id)" = "$B" ] && [ "$(count open)" = 2 ]'
# The reader-level statement of the same rule, with no writer in the way. The acceptance half
# is 25(a) control: the same arming, on a ledger with no later birth, completes.
check "supersession: the ledger refuses an arming once a newer cycle is born under its key" '[ "$(LIB ledger_query builtin_owner "$RH" "$C1" 1 1 || echo REFUSED)" = REFUSED ]'

# === 27. the blocking finding of the native review of candidate f89aea4c ===
# THE CHECKOUT THAT MOVED. Supersession is decided WITHIN a lineage key, so stepping out of the
# key evades it: arm on branch A, switch to branch B, force-init and FAIL there on the same
# diff, delete the state. No record of A changes, the ledger still accepts the arming, and the
# state-file veto that used to catch this is one `rm` away -- so the writer published a marker
# over B review and deleted its history. Publication is bound to the key of the checkout it
# publishes INTO, which git answers and no deletion can forge.
fallback_sandbox; arming
H=$(git rev-parse HEAD)
git checkout -q -b other-branch
INIT --force 1 >/dev/null 2>&1
B=$(fm cycle_id); BL=$(fm lineage_id)
ledger_add event=attempt "lineage_id=$BL" "cycle_id=$B" iteration=1 "head_sha=$H" "reviewed_diff_hash=$RH"
LIB ledger_verdict "$BL" "$B" FAIL ffffffffffffffffffffffffffffffff commit "$H"
rm -f .claude/litmus-state.md
before=$(events)
rc=0; WRITER "$P" || rc=$?
check "branch switched, newer cycle FAILed: the arming refuses on a checkout it was not armed in" '[ "$rc" != 0 ] && [ ! -e .claude/litmus-passed.local ] && [ "$(count pass)" = 0 ] && [ "$(events)" = "$before" ] && armed'
check "branch switched: the newer branch cycle keeps its FAIL and its spent budget" '[ "$(LIB ledger_query closed "$B")" = 0 ] && [ "$B" != "$C1" ]'
# Control: back on the branch it was armed in, with no newer cycle, the same arming completes.
fallback_sandbox; arming
rc=0; WRITER "$P" || rc=$?
check "checkout control: the arming completes in the checkout it was armed in" '[ "$rc" = 0 ] && [ "$(cat .claude/litmus-passed.local)" = "BUILTIN-$RH" ] && [ "$(lrec)" = "pass $C1 builtin" ] && spent'
# Control: the cycle here was born under a KEY and the checkout then detached, so it can no
# longer prove that key. Equality alone refuses it -- "" is not the branch key it was armed
# under -- which is the branch-switch case above reached by detaching instead of switching.
# It is NOT a statement that a detached checkout cannot publish: see 29 for the keyless birth.
fallback_sandbox; arming
git checkout -q --detach
before=$(events)
rc=0; WRITER "$P" || rc=$?
check "keyed birth, checkout detached: the key it was armed under no longer matches — refuses" '[ "$rc" != 0 ] && [ ! -e .claude/litmus-passed.local ] && [ "$(events)" = "$before" ] && armed'

# === 28. the blocking finding of the native review of candidate 42d344b5 ===
# THE CLOSED-CYCLE EXCEPTION, the same supersession question one path over -- the PR completion
# rather than the builtin handoff, which is why the predicate is now SHARED. A lead PASS naming
# a cycle the ledger does not owe was accepted whenever that cycle was merely closed. So:
# complete cycle A, then open and FAIL cycle B on the same diff with A artifacts still fresh.
# owed_completion is empty (B tail is a FAIL, not a PASS) and closed(A)=1, so the guard passed
# and the marker published -- an older completed review authorizing a diff a newer one rejected.
pr_lead_pass; lead_voice "$C1" "$L1"; voice pr-backstop-verdict.local.json opus
rc=0; MARKER || rc=$?
check "closed-cycle setup: cycle A completes and publishes its marker" '[ "$rc" = 0 ] && [ "$(rec -1 cycle_id)" = "$C1" ] && [ "$(rec -1 review_basis)" = "pr_dual" ]'
rm -f .claude/pr-review-passed.local
LITMUS_MODE=pr INIT 10 >/dev/null 2>&1
B=$(fm cycle_id); BL=$(fm lineage_id)
ledger_add event=attempt "lineage_id=$BL" "cycle_id=$B" iteration=1 "reviewed_diff_hash=$(HASH_NOW)" "head_sha=$H"
LIB ledger_verdict "$BL" "$B" FAIL ffffffffffffffffffffffffffffffff pr "$H"
lead_voice "$C1" "$L1"; voice pr-backstop-verdict.local.json opus   # A's artifacts, still fresh
before=$(events)
rc=0; MARKER || rc=$?
check "closed cycle superseded: an older completed lead PASS cannot publish over a newer FAIL" '[ "$rc" != 0 ] && [ ! -e .claude/pr-review-passed.local ] && [ "$(events)" = "$before" ] && [ "$B" != "$C1" ]'
check "closed cycle superseded: the newer FAILed cycle is neither closed nor completed" '[ "$(LIB ledger_query closed "$B")" = 0 ] && [ -z "$(LIB ledger_query completion_basis "$B")" ]'
check "supersession is one predicate: the reader reports A superseded, for either caller" '[ "$(LIB ledger_query superseded "$C1")" = 1 ] && [ "$(LIB ledger_query superseded "$B")" = 0 ]'
# Control: the republish itself is still allowed -- same cycle, nothing newer, same head.
pr_lead_pass; lead_voice "$C1" "$L1"; voice pr-backstop-verdict.local.json opus
rc=0; MARKER || rc=$?; rm -f .claude/pr-review-passed.local
before=$(events)
rc=0; MARKER || rc=$?
check "republish control: the completed cycle republishes its marker, recording no second pass" '[ "$rc" = 0 ] && [ "$(cat .claude/pr-review-passed.local)" = "$(HASH_NOW)" ] && [ "$(events)" = "$before" ]'

# === 29. the blocking finding of the native review of candidate 57ccf139 ===
# THE KEYLESS BIRTH. Requiring the current key to be PROVABLE, on top of matching, was too
# broad: init permits a keyless cycle on a detached HEAD or in a shallow clone and the runner
# arms its builtin handoff, so the extra test left a finished review that could never be
# completed, and re-arming only produced another one. The two keyless situations are different
# questions, and equality alone already tells them apart: born keyless and STILL keyless is the
# same checkout, while born under a key and now unprovable is not, because "" is not that key.
new_sandbox
git checkout -q --detach
INIT 10 >/dev/null 2>&1
C1=$(fm cycle_id)
check "keyless init: a detached checkout opens a cycle with no lineage key" '[ -n "$C1" ] && [ -z "$(LIB ledger_query birth_key "$C1")" ]'
BUILTIN_RUN; arming
check "keyless handoff: the detached checkout arms its builtin review" '[ -n "$P" ] && [ "$(sed -n 2p "$HF")" = "$C1 0 0" ]'
rc=0; WRITER "$P" || rc=$?
check "keyless completion: the unchanged detached checkout completes its own review" '[ "$rc" = 0 ] && [ "$(cat .claude/litmus-passed.local)" = "BUILTIN-$RH" ] && [ "$(lrec)" = "pass $C1 builtin" ] && spent'
# Control: accepted, but still UNDER supersession -- a second keyless cycle opened over the
# arming retires it, exactly as a keyed one does. Keyless births are compared with keyless.
new_sandbox
git checkout -q --detach
INIT 10 >/dev/null 2>&1
C1=$(fm cycle_id); BUILTIN_RUN; arming
INIT --force 10 >/dev/null 2>&1
B=$(fm cycle_id); before=$(events)
rc=0; WRITER "$P" || rc=$?
check "keyless supersession: a newer keyless cycle still retires the older arming" '[ "$rc" != 0 ] && [ ! -e .claude/litmus-passed.local ] && [ "$(events)" = "$before" ] && [ "$B" != "$C1" ] && armed'

# === 30. the two blocking findings of the native review of candidate aed3bbcf ===

# (a) THE CYCLE-LESS LEAD. The republish checks are reached only when the lead artifact NAMES a
# cycle, so the pre-A8 shape -- which names none -- was exempt from all of them by being empty.
# An authorization carrying less information was asked for less proof: a legacy lead PASS could
# publish over a newer identity-bearing cycle that had already FAILed. It is honoured only where
# its own story holds, a checkout that has minted no cycle at all.
pr_lead_pass; voice pr-backstop-verdict.local.json opus   # `voice` writes the cycle-less shape
LITMUS_MODE=pr INIT 10 >/dev/null 2>&1
B=$(fm cycle_id); BL=$(fm lineage_id)
ledger_add event=attempt "lineage_id=$BL" "cycle_id=$B" iteration=1 "reviewed_diff_hash=$(HASH_NOW)" "head_sha=$H"
LIB ledger_verdict "$BL" "$B" FAIL ffffffffffffffffffffffffffffffff pr "$H"
voice pr-codex-lead.local.json codex; voice pr-backstop-verdict.local.json opus
before=$(events)
rc=0; MARKER || rc=$?
check "cycle-less lead, newer FAIL: a legacy artifact cannot publish where cycles were minted" '[ "$rc" != 0 ] && [ ! -e .claude/pr-review-passed.local ] && [ "$(events)" = "$before" ]'
# Control: A1 is untouched -- a genuinely pre-ledger checkout still publishes on the same shape.
new_sandbox; git commit -q -m target; git update-ref refs/remotes/origin/main "$(git rev-parse HEAD~1)"; git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
voice pr-codex-lead.local.json codex; voice pr-backstop-verdict.local.json opus
rc=0; MARKER || rc=$?
check "cycle-less control: a checkout that minted no cycle still publishes as before" '[ "$rc" = 0 ] && [ "$(cat .claude/pr-review-passed.local)" = "$(HASH_NOW)" ] && [ ! -e "$LEDGER" ]'

# (b) THE UNBORN HEAD. Before the first commit there is no head to pin, and the fallback guard
# required one -- so a charged external attempt had its prompt discarded instead of arming the
# builtin review, spending the budget with no reviewer ever invoked. What binds the settlement
# is naming the SAME head as the attempt, which for an absent head is an absent head.
new_sandbox
rm -rf .git; git init -q .; git config user.email t@t.com; git config user.name t; git config commit.gpgsign false
echo "test content" > test_target.txt; git add test_target.txt      # staged, never committed
printf '#!/bin/sh\necho "call $1" >> "%s/.mock/calls"\nexit 1\n' "$S" > "$S.bin/codex"
printf '#!/bin/sh\nexit 0\n' > "$S.bin/droid"
chmod +x "$S.bin/codex" "$S.bin/droid"
INIT 10 >/dev/null 2>&1
C1=$(fm cycle_id)
rc=0
PATH="$S.bin:$PATH" BUSDRIVER_REVIEW_CLI=codex LITMUS_CODEX_RETRIES=1 CLAUDE_PLUGIN_ROOT="$S" LITMUS_SKIP_SAST=1 \
LITMUS_SKIP_CONTEXT=1 LITMUS_SKIP_MARKDOWN=1 LITMUS_DOCS_CONTEXT=0 LITMUS_SHORTCIRCUIT_DISABLED=1 \
bash "$S/skills/litmus/scripts/run-review-loop.sh" >> "$S/.mock/run.log" 2>&1 || rc=$?
check "unborn HEAD: the charged fallback settles headless and arms the builtin review" '[ "$rc" = 3 ] && [ "$(events)" = "open attempt abandon" ] && [ -s .claude/builtin-review-prompt-path.local ]'
check "unborn HEAD: the headless settlement leaves the ledger readable" 'LIB ledger_query usable && [ -z "$(LIB ledger_query unsettled "$C1")" ]'

# === 31. the two blocking findings of the native review of candidate 8d37dbe4 ===

# (a) THE "-" BINDING: 30(a) in the sibling writer. A handoff armed before this checkout had
# any identity names no cycle, and naming nothing exempted it from every ledger check. So
# retain such a handoff, init an identity-bearing cycle, let it FAIL on the same diff, and the
# older builtin writer still published BUILTIN-<hash> -- authorizing the diff that review had
# just rejected, with no newer marker generation in the way, because a FAIL publishes none.
new_sandbox
legacy_state commit
BUILTIN_RUN; arming
check "legacy handoff: a checkout with no identity arms a cycle-less builtin review" '[ "$(sed -n 2p "$HF")" = "-" ] && [ ! -e "$LEDGER" ]'
H=$(git rev-parse HEAD)
INIT --force 1 >/dev/null 2>&1
B=$(fm cycle_id); BL=$(fm lineage_id)
ledger_add event=attempt "lineage_id=$BL" "cycle_id=$B" iteration=1 "head_sha=$H" "reviewed_diff_hash=$RH"
LIB ledger_verdict "$BL" "$B" FAIL ffffffffffffffffffffffffffffffff commit "$H"
before=$(events)
rc=0; WRITER "$P" || rc=$?
check "cycle-less arming, newer FAIL: it cannot publish where a cycle has since been minted" '[ "$rc" != 0 ] && [ ! -e .claude/litmus-passed.local ] && [ "$(events)" = "$before" ] && armed'
# The ledger carries the refusal on its own, with the state file gone -- as in 26.
rm -f .claude/litmus-state.md
rc=0; WRITER "$P" || rc=$?
check "cycle-less arming, state deleted: the minted cycle is still in the ledger, so it refuses" '[ "$rc" != 0 ] && [ ! -e .claude/litmus-passed.local ] && [ "$(count pass)" = 0 ] && armed'
# Control: a genuinely pre-ledger checkout still publishes on the same shape, as A1 does.
new_sandbox
legacy_state commit
BUILTIN_RUN; arming
rc=0; WRITER "$P" || rc=$?
check "cycle-less control: a checkout that minted no cycle publishes as before" '[ "$rc" = 0 ] && [ "$(cat .claude/litmus-passed.local)" = "BUILTIN-$RH" ] && [ ! -e "$LEDGER" ] && spent'

# (b) THE CLEANUP THAT OWNED NOTHING. The state file and the findings history live at one fixed
# path per CHECKOUT, not one per cycle, and the completion deleted whatever was there. Arm on
# branch A, force-init and FAIL cycle B on another branch, then come back: B is born under
# another key, so neither supersession nor the key equality can see it, and A's completion
# erased B's state and the findings B had not converged yet.
fallback_sandbox; arming
H=$(git rev-parse HEAD)
git checkout -q -b other-branch
INIT --force 1 >/dev/null 2>&1
B=$(fm cycle_id); BL=$(fm lineage_id)
ledger_add event=attempt "lineage_id=$BL" "cycle_id=$B" iteration=1 "head_sha=$H" "reviewed_diff_hash=$RH"
LIB ledger_verdict "$BL" "$B" FAIL ffffffffffffffffffffffffffffffff commit "$H"
printf '{"iteration": 1, "status": "FAIL", "issues": [%s]}\n' "$ISSUE" > "$HIST"   # B's findings
ssum=$(shasum -a 256 < .claude/litmus-state.md); hsum=$(shasum -a 256 < "$HIST")
git checkout -q -    # back where the arming was made: its own key, and nothing superseding it
before=$(events)
rc=0; WRITER "$P" || rc=$?
check "retained state names another cycle: the completion refuses instead of erasing it" '[ "$rc" != 0 ] && [ ! -e .claude/litmus-passed.local ] && [ "$(events)" = "$before" ] && armed'
check "retained state names another cycle: that cycle keeps its state and its findings" '[ "$(fm cycle_id)" = "$B" ] && [ "$(shasum -a 256 < .claude/litmus-state.md)" = "$ssum" ] && [ "$(shasum -a 256 < "$HIST")" = "$hsum" ]'
# Control: the state and findings a completion DOES own are still cleared by it.
fallback_sandbox; arming
rc=0; WRITER "$P" || rc=$?
check "ownership control: the cycle that owns the state completes and clears it" '[ "$rc" = 0 ] && [ "$(lrec)" = "pass $C1 builtin" ] && [ ! -e .claude/litmus-state.md ] && [ ! -e "$HIST" ]'

# === 32. the blocking finding of the native review of candidate 808c90e2 ===
# THE SUPERSEDED KEYLESS COMPLETION. The keyless owed_completion branch reaches cycles one at a
# time by cycle id and had no newest-wins rule, so it returned a cycle a newer keyless birth had
# already retired, as long as that newer chain had resolved. On a detached checkout: PR cycle A
# records its lead PASS, B is force-opened over it, FAILs on the same diff and is retired into
# commit mode -- B is resolved, A is the only unresolved keyless cycle left, and the lookup named
# A. Its lead artifact then MATCHED the owed cycle, which is the one shape that reaches neither
# the cycle-less branch nor the republish branch where supersession is tested, so an older PASS
# published over the newer FAILed review and was recorded as its completion.
new_sandbox
git commit -q -m target
git update-ref refs/remotes/origin/main "$(git rev-parse HEAD~1)"
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git checkout -q --detach
H=$(git rev-parse HEAD)
LITMUS_MODE=pr INIT 10 >/dev/null 2>&1
A=$(fm cycle_id); AL=$(fm lineage_id)
ledger_add event=attempt "lineage_id=$AL" "cycle_id=$A" iteration=1 "head_sha=$H" "reviewed_diff_hash=$(HASH_NOW)"
LIB ledger_verdict "$AL" "$A" PASS ffffffffffffffffffffffffffffffff pr "$H"
check "detached PR cycle A: keyless, and owed the completion its lead PASS earned" '[ -z "$(LIB ledger_query birth_key "$A")" ] && [ "$(LIB ledger_query owed_completion "")" = "$AL $A $H" ]'
LITMUS_MODE=pr INIT --force 10 >/dev/null 2>&1      # B force-opened over A
B=$(fm cycle_id); BL=$(fm lineage_id)
ledger_add event=attempt "lineage_id=$BL" "cycle_id=$B" iteration=1 "head_sha=$H" "reviewed_diff_hash=$(HASH_NOW)"
LIB ledger_verdict "$BL" "$B" FAIL ffffffffffffffffffffffffffffffff pr "$H"
setfm iteration=2 'review_status="FAIL"' 'terminal_status="review_findings"' attempts_consumed=1
printf '{"iteration": 1, "status": "FAIL", "issues": [%s]}\n' "$ISSUE" > "$HIST"
INIT 10 >/dev/null 2>&1                             # B retired into commit mode
check "B FAILed and was retired: A is superseded, and the ledger no longer owes it" '[ "$(LIB ledger_query superseded "$A")" = 1 ] && [ -z "$(LIB ledger_query owed_completion "")" ] && [ "$B" != "$A" ] && [ "$(count retire)" = 1 ]'
check "the retirement leaves the ledger readable" 'LIB ledger_query usable'
lead_voice "$A" "$AL"; voice pr-backstop-verdict.local.json opus   # A's artifacts, still fresh
before=$(events)
rc=0; MARKER || rc=$?
check "superseded keyless completion: A's lead PASS cannot publish over the FAIL that retired it" '[ "$rc" != 0 ] && [ ! -e .claude/pr-review-passed.local ] && [ "$(events)" = "$before" ] && [ "$(count pass)" = 0 ]'
# Control: the keyless completion 24(b) covers still discharges -- nothing newer was ever born,
# so the cycle is unsuperseded and its own lead PASS completes it exactly as before.
new_sandbox
git commit -q -m target
git update-ref refs/remotes/origin/main "$(git rev-parse HEAD~1)"
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git checkout -q --detach
H=$(git rev-parse HEAD)
LITMUS_MODE=pr INIT 10 >/dev/null 2>&1
A=$(fm cycle_id); AL=$(fm lineage_id)
ledger_add event=attempt "lineage_id=$AL" "cycle_id=$A" iteration=1 "head_sha=$H" "reviewed_diff_hash=$(HASH_NOW)"
LIB ledger_verdict "$AL" "$A" PASS ffffffffffffffffffffffffffffffff pr "$H"
lead_voice "$A" "$AL"; voice pr-backstop-verdict.local.json opus
rc=0; MARKER || rc=$?
check "keyless control: an unsuperseded detached cycle still completes on its own lead PASS" '[ "$rc" = 0 ] && [ "$(cat .claude/pr-review-passed.local)" = "$(HASH_NOW)" ] && [ "$(lrec)" = "pass $A pr_dual" ]'

# === 33. the blocking finding of the native review of candidate 7b80a1fe ===
# THE COUNT THAT NEVER LET GO, one function up from 32 and the same half-rule. keyless_unresolved
# reaches cycles one at a time by cycle id, so a keyless cycle with a charged attempt stayed
# counted after --force had opened its replacement AND that replacement had completed: nothing
# about the older cycle ever changes, and no key groups it, so ordinary init refused for the life
# of the ledger with nothing left to recover. The keyed path never had this -- newest(key) ends
# the older cycle turn -- so supersession is what makes the two agree.
new_sandbox
git checkout -q --detach
INIT 10 >/dev/null 2>&1
A=$(fm cycle_id); AL=$(fm lineage_id); H=$(git rev-parse HEAD)
ledger_add event=attempt "lineage_id=$AL" "cycle_id=$A" iteration=1 "head_sha=$H" reviewed_diff_hash=deadbeef
LIB ledger_append abandon "lineage_id=$AL" "cycle_id=$A" settles_seq=1 abandon_reason=interrupted "head_sha=$H"
check "keyless A charged then abandoned: it is unresolved, and this checkout is busy" '[ -z "$(LIB ledger_query birth_key "$A")" ] && [ "$(LIB ledger_query unresolved_keyless)" = 1 ] && [ "$(LIB ledger_query unresolved_any)" = 1 ]'
INIT --force 10 >/dev/null 2>&1                 # B force-opened over A
B=$(fm cycle_id)
echo pass > .mock/mode; RUN >/dev/null 2>&1     # B reviews, PASSes and completes
check "B completed over it: the replacement closed and recorded its own pass" '[ "$B" != "$A" ] && [ "$(LIB ledger_query closed "$B")" = 1 ] && [ "$(lrec)" = "pass $B dispatched" ]'
check "superseded A is no longer counted, so the checkout is free again" '[ "$(LIB ledger_query superseded "$A")" = 1 ] && [ "$(LIB ledger_query unresolved_keyless)" = 0 ] && [ "$(LIB ledger_query unresolved_any)" = 0 ]'
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "...and an ordinary init opens its own cycle instead of refusing forever" '[ "$rc" = 0 ] && [ "$(count open)" = 3 ] && [ "$(fm cycle_id)" != "$A" ] && [ "$(fm cycle_id)" != "$B" ]'
# Control: an unsuperseded keyless cycle still holds the checkout -- the count is narrowed by
# supersession only, never by being keyless.
new_sandbox
git checkout -q --detach
INIT 10 >/dev/null 2>&1
A=$(fm cycle_id); AL=$(fm lineage_id); H=$(git rev-parse HEAD)
ledger_add event=attempt "lineage_id=$AL" "cycle_id=$A" iteration=1 "head_sha=$H" reviewed_diff_hash=deadbeef
LIB ledger_append abandon "lineage_id=$AL" "cycle_id=$A" settles_seq=1 abandon_reason=interrupted "head_sha=$H"
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "keyless control: with nothing newer born, the unresolved cycle still refuses a fresh lineage" '[ "$rc" != 0 ] && [ "$(count open)" = 1 ] && [ "$(LIB ledger_query unresolved_keyless)" = 1 ]'

# === 34. the blocking finding of the native review of candidate 7f01c38a ===
# THE REPLACEMENT NO KEY COULD NAME, one predicate under 33 and the last of the same asymmetry.
# superseded() read supersession off lineage_key equality alone, so a forced recovery retired its
# predecessor only while both happened to be born under the same key. Charge a cycle on a
# detached HEAD (keyless), check the branch out, then force-init and complete the replacement:
# the two keys differ, so nothing ever supersedes the keyless cycle and ordinary init refuses for
# the life of the ledger although the prescribed recovery was carried out in full. The forced
# birth now records WHICH cycle it replaced, and that relation is honoured whatever the keys say.
new_sandbox
BR=$(git symbolic-ref --short HEAD)
git checkout -q --detach
INIT 10 >/dev/null 2>&1
A=$(fm cycle_id); AL=$(fm lineage_id); H=$(git rev-parse HEAD)
ledger_add event=attempt "lineage_id=$AL" "cycle_id=$A" iteration=1 "head_sha=$H" reviewed_diff_hash=deadbeef
LIB ledger_append abandon "lineage_id=$AL" "cycle_id=$A" settles_seq=1 abandon_reason=interrupted "head_sha=$H"
git checkout -q "$BR"                           # the recovery happens from the branch, not the detached head
INIT --force 10 >/dev/null 2>&1                 # B force-opened over A
B=$(fm cycle_id)
check "keyless A, keyed replacement B: no key relates them, so the birth names the cycle it replaced" '[ -z "$(LIB ledger_query birth_key "$A")" ] && [ -n "$(LIB ledger_query birth_key "$B")" ] && [ "$B" != "$A" ] && grep -q "\"replaces_cycle_id\": \"$A\"" "$LEDGER"'
echo pass > .mock/mode; RUN >/dev/null 2>&1     # B reviews, PASSes and completes
check "the completed cross-key replacement supersedes A, so the checkout is free again" '[ "$(LIB ledger_query closed "$B")" = 1 ] && [ "$(LIB ledger_query superseded "$A")" = 1 ] && [ "$(LIB ledger_query unresolved_keyless)" = 0 ] && [ "$(LIB ledger_query unresolved_any)" = 0 ]'
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "...and an ordinary init opens its own cycle instead of refusing forever" '[ "$rc" = 0 ] && [ "$(count open)" = 3 ] && [ "$(fm cycle_id)" != "$A" ] && [ "$(fm cycle_id)" != "$B" ]'

# === 35. the blocking finding of the native review of candidate 3b84337b ===
# THE RECOVERY WITH NOTHING LEFT TO READ. 34 recorded the replaced cycle from the state file, so
# it was silent on the one shape the keyless refusal itself prescribes: that refusal tells the
# operator to --force past a cycle whose state is GONE. With no file to read the forced birth
# named nothing, the keyless predecessor stayed live, and ordinary init went on refusing for the
# life of the ledger although the prescribed recovery had been carried out. The ledger is the
# only other record of it, and a keyless unresolved cycle is exactly what this checkout cannot
# rule out owning -- which is why the refusal exists -- so that is what the forced birth names.
new_sandbox
BR=$(git symbolic-ref --short HEAD)
git checkout -q --detach
INIT 10 >/dev/null 2>&1
A=$(fm cycle_id); AL=$(fm lineage_id); H=$(git rev-parse HEAD)
ledger_add event=attempt "lineage_id=$AL" "cycle_id=$A" iteration=1 "head_sha=$H" reviewed_diff_hash=deadbeef
LIB ledger_append abandon "lineage_id=$AL" "cycle_id=$A" settles_seq=1 abandon_reason=interrupted "head_sha=$H"
rm -f .claude/litmus-state.md                   # the rm the keyless refusal tells the operator to force past
git checkout -q "$BR"
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "state deleted: ordinary init refuses, and only the ledger still names the keyless predecessor" '[ "$rc" != 0 ] && [ ! -e .claude/litmus-state.md ] && [ "$(LIB ledger_query unresolved_keyless)" = 1 ]'
INIT --force 10 >/dev/null 2>&1                 # B force-opened over A, with no state to read
B=$(fm cycle_id)
check "the forced birth recovers the cycle it replaces from the ledger instead of naming nothing" '[ "$B" != "$A" ] && grep -q "\"replaces_cycle_id\": \"$A\"" "$LEDGER"'
echo pass > .mock/mode; RUN >/dev/null 2>&1     # B reviews, PASSes and completes
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "...so the completed replacement frees the checkout exactly as it does with the state in place" '[ "$rc" = 0 ] && [ "$(LIB ledger_query superseded "$A")" = 1 ] && [ "$(LIB ledger_query unresolved_any)" = 0 ] && [ "$(count open)" = 3 ]'

# === 36. the blocking finding of the native review of candidate 6f43b425 ===
# THE KEYED HALF OF THE SAME PREDICATE, and the one the recorded replacement itself created. A
# keyed lookup never needed a supersession test while supersession WAS newest-of-key: a cycle
# another had opened over was not the newest record of the key, so it was never considered. A
# birth that names the cycle it replaces broke that equivalence -- a replacement born under
# another key, or under none, supersedes without appearing in newest(key). Charge A on a branch,
# detach, force-open the keyless B over it and complete B: superseded(A) said 1 while
# unresolved_any still counted A, so the detached checkout stayed blocked after a recovery that
# had finished, and returning to the branch RESUMED A on its exhausted budget.
new_sandbox
BR=$(git symbolic-ref --short HEAD)
INIT 10 >/dev/null 2>&1
A=$(fm cycle_id); AL=$(fm lineage_id); H=$(git rev-parse HEAD)
ledger_add event=attempt "lineage_id=$AL" "cycle_id=$A" iteration=1 "head_sha=$H" reviewed_diff_hash=deadbeef
LIB ledger_append abandon "lineage_id=$AL" "cycle_id=$A" settles_seq=1 abandon_reason=interrupted "head_sha=$H"
git checkout -q --detach                        # the recovery happens from a checkout with no key
INIT --force 10 >/dev/null 2>&1                 # B force-opened over A, keyless
B=$(fm cycle_id)
echo pass > .mock/mode; RUN >/dev/null 2>&1     # B reviews, PASSes and completes
check "keyed A, keyless replacement B: the birth names it, and B completed" '[ -n "$(LIB ledger_query birth_key "$A")" ] && [ -z "$(LIB ledger_query birth_key "$B")" ] && grep -q "\"replaces_cycle_id\": \"$A\"" "$LEDGER" && [ "$(LIB ledger_query closed "$B")" = 1 ]'
check "the keyed predecessor is superseded, so no checkout still counts it as unresolved" '[ "$(LIB ledger_query superseded "$A")" = 1 ] && [ "$(LIB ledger_query unresolved_any)" = 0 ] && [ -z "$(LIB ledger_query unresolved "$(LIB ledger_query birth_key "$A")")" ]'
git checkout -q "$BR"
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "...so its own branch opens a fresh cycle instead of resuming it on a spent budget" '[ "$rc" = 0 ] && [ "$(fm cycle_id)" != "$A" ] && [ "$(fm attempts_consumed)" = 0 ] && [ "$(count open)" = 3 ]'

# === 37. the blocking finding of the native review of candidate b24d3fdf ===
# THE JOURNAL THAT OUTLIVED ITS SUCCESSOR, the last caller of newest(key) and the only one that
# does not read through eligible() -- so the supersession the other keyed lookups now honour
# never reached it. Retire A into B on a branch, detach, force-open C over B and complete it:
# the newest record of the branch key is still A retirement, so coming back to the branch
# REINSTALLED the replaced successor B with its carried budget. Worse than the refusals of 34-36,
# because nothing refuses -- the checkout quietly resumes a cycle a completed recovery replaced.
new_sandbox
BR=$(git symbolic-ref --short HEAD)
make_pr_fail deadbeef
A=$(fm cycle_id)
INIT 10 >/dev/null 2>&1                         # settled PR FAIL retired into commit cycle B
B=$(fm cycle_id)
git checkout -q --detach                        # the replacement is forced from a checkout with no key
INIT --force 10 >/dev/null 2>&1                 # C force-opened over B, keyless
C=$(fm cycle_id)
echo pass > .mock/mode; RUN >/dev/null 2>&1     # C reviews, PASSes and completes, clearing the state
check "B was installed by a retirement, then replaced by a keyless C that completed" '[ "$(count retire)" = 1 ] && [ "$B" != "$A" ] && [ "$C" != "$B" ] && grep -q "\"replaces_cycle_id\": \"$B\"" "$LEDGER" && [ "$(LIB ledger_query closed "$C")" = 1 ]'
check "the replaced successor is superseded, so its key no longer offers the retirement" '[ "$(LIB ledger_query superseded "$B")" = 1 ] && [ -z "$(LIB ledger_query pending_retire "$(LIB ledger_query birth_key "$B")")" ]'
git checkout -q "$BR"
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "...so the branch cold-starts instead of reinstalling B on its carried budget" '[ "$rc" = 0 ] && [ "$(fm cycle_id)" != "$B" ] && [ "$(fm attempts_consumed)" = 0 ] && [ "$(fm max_iterations)" = 10 ] && [ "$(count open)" = 3 ]'

# === 38. the blocking finding of the native PR review of e8764e0a ===
# THE JOURNAL NO CHECKOUT COULD FIND. 37 stopped a superseded journal being replayed; this is the
# opposite loss on the keyless side. A retirement made where no (root commit, branch) can be
# proved carries no key, and the record names the RETIRED cycle, so nothing is recorded under the
# successor until it is charged: invisible to the key lookup, invisible to newest_cycle, and an
# unstarted successor is no unresolved work either. Delete the state before the successor
# dispatches and init cold-started a FRESH lineage over it -- handing back the ceiling and the
# consumption the retirement exists to carry. It is now installed from its journal like any other.
new_sandbox
BR=$(git symbolic-ref --short HEAD)
git checkout -q --detach
make_pr_fail deadbeef 2                         # settled PR FAIL, ceiling 2, one attempt charged
A=$(fm cycle_id)
INIT 10 >/dev/null 2>&1                         # retired into commit successor B, keyless
B=$(fm cycle_id)
rm -f .claude/litmus-state.md                   # crash (or rm) before B ever dispatched
check "detached retirement, state gone: the journal is keyless and nothing is recorded under B" '[ "$B" != "$A" ] && [ "$(count retire)" = 1 ] && [ -z "$(LIB ledger_query birth_key "$B")" ] && [ "$(LIB ledger_query cycle_attempts "$B")" = 0 ] && [ "$(LIB ledger_query unresolved_any)" = 0 ]'
# A KEYED checkout is blind to it in a third way -- not its pending retirement, not an unresolved
# cycle, not a keyless one with attempts -- so it cold-started a fresh lineage over the journal
# from any branch at all. It may not adopt what names no branch, but it may not walk past it.
git checkout -q "$BR"
rc=0; out=$(INIT 10 2>&1) || rc=$?
check "a named branch may not cold-start over the keyless journal either" '[ "$rc" != 0 ] && [ "$(count open)" = 1 ] && [ ! -e .claude/litmus-state.md ] && printf "%s" "$out" | grep -q "names no branch"'
git checkout -q --detach                        # the checkout that journalled it installs it
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "the journalled successor is installed, not cold-started over" '[ "$rc" = 0 ] && [ "$(fm cycle_id)" = "$B" ] && [ "$(fm review_mode)" = commit ] && [ "$(count open)" = 1 ] && [ "$(count retire)" = 1 ]'
check "...with the ceiling and the iteration the retirement carried" '[ "$(fm max_iterations)" = 2 ] && [ "$(fm iteration)" = 2 ]'

# === 39. the second blocking finding of the same PR review ===
# THE JOURNAL THAT ANSWERED TO TWO KEYS. A retirement carries the key of the checkout that MADE
# it, while the record itself names the RETIRED cycle -- so it answers to the predecessor key as
# well, and nothing about the successor is written under the predecessor key ever again. FAIL a
# cycle on one branch, retire it from another and complete the successor there: coming back, the
# newest record of the first key was still that retirement, unsuperseded, and init REINSTALLED a
# closed cycle. Supersession was never the missing test -- UNSTARTED was, which the keyless form
# has required from the start.
new_sandbox
BR=$(git symbolic-ref --short HEAD)
make_pr_fail deadbeef
PRED=$(fm cycle_id)
git checkout -q -b other-branch                 # the retirement is made under ANOTHER key
INIT 10 >/dev/null 2>&1
SUC=$(fm cycle_id)
echo pass > .mock/mode; RUN >/dev/null 2>&1     # the successor completes there, clearing the state
check "retired under another key, successor completed there" '[ "$SUC" != "$PRED" ] && [ "$(count retire)" = 1 ] && [ "$(LIB ledger_query closed "$SUC")" = 1 ] && [ ! -e .claude/litmus-state.md ]'
git checkout -q "$BR"
check "the predecessor key still answers to that retirement, but it is no longer pending" '[ "$(LIB ledger_query birth_key "$PRED")" != "$(LIB ledger_query birth_key "$SUC")" ] && [ -z "$(LIB ledger_query pending_retire "$(LIB ledger_query birth_key "$PRED")")" ]'
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "...so the branch opens its own cycle instead of reinstalling the completed successor" '[ "$rc" = 0 ] && [ "$(fm cycle_id)" != "$SUC" ] && [ "$(fm cycle_id)" != "$PRED" ] && [ "$(fm attempts_consumed)" = 0 ] && [ "$(count open)" = 2 ]'

# === 40. the two blocking findings of the PR review of 1bc465ad ===
# (a) THE SAME BLINDNESS, POINTING THE OTHER WAY. 38 taught a branch not to walk past a keyless
# journal; a checkout with NO key could still walk past a KEYED one -- it has no key to look the
# journal up with, and an unstarted successor is no unresolved work -- so init cold-started a
# fresh lineage and reset the carried budget. Refused here, never adopted: only the branch that
# journalled it can prove it owns it.
new_sandbox
BR=$(git symbolic-ref --short HEAD)
make_pr_fail deadbeef 2
INIT 10 >/dev/null 2>&1                         # retired into an unstarted commit successor, keyed
SUC=$(fm cycle_id)
rm -f .claude/litmus-state.md
git checkout -q --detach
rc=0; out=$(INIT 10 2>&1) || rc=$?
check "a keyless checkout may not cold-start over a keyed journal either" '[ "$rc" != 0 ] && [ "$(count open)" = 1 ] && [ ! -e .claude/litmus-state.md ] && printf "%s" "$out" | grep -q "cannot prove it is on"'
git checkout -q "$BR"                           # the branch that journalled it installs it
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "control: its own branch still installs it with the carried ceiling" '[ "$rc" = 0 ] && [ "$(fm cycle_id)" = "$SUC" ] && [ "$(fm max_iterations)" = 2 ] && [ "$(count open)" = 1 ]'
# (b) THE RECOVERY THAT COULD NOT RECOVER. --force is what (a) and 38 both prescribe, and the
# replacement it opens records what it replaced -- but replacement discovery counted only keyless
# cycles with a charged attempt, and an unstarted journalled successor has none. So the forced
# open recorded nothing, its key never matched the keyless journal, and ordinary init went on
# refusing even after the replacement had completed: the prescribed way out led nowhere.
new_sandbox
BR=$(git symbolic-ref --short HEAD)
git checkout -q --detach
make_pr_fail deadbeef 2
INIT 10 >/dev/null 2>&1                         # retired into an unstarted successor, keyless
SUC=$(fm cycle_id)
rm -f .claude/litmus-state.md
git checkout -q "$BR"
INIT --force 10 >/dev/null 2>&1                 # the prescribed recovery, from the branch
NEW=$(fm cycle_id)
check "the forced replacement names the unstarted journalled successor it replaces" '[ "$NEW" != "$SUC" ] && grep -q "\"replaces_cycle_id\": \"$SUC\"" "$LEDGER"'
echo pass > .mock/mode; RUN >/dev/null 2>&1     # the replacement completes
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "...so once it completes, ordinary init stops refusing on the replaced journal" '[ "$rc" = 0 ] && [ "$(LIB ledger_query superseded "$SUC")" = 1 ] && [ -z "$(LIB ledger_query keyless_pending_retire)" ] && [ "$(fm cycle_id)" != "$SUC" ]'

# (c) AND THE RECOVERY FROM (a), which prescribes --force from the checkout that cannot prove a
# key: replacement discovery was keyless-only, so the forced open recorded nothing, the KEYED
# journal survived it, and the refusal came straight back after the replacement had completed.
new_sandbox
BR=$(git symbolic-ref --short HEAD)
make_pr_fail deadbeef 2
INIT 10 >/dev/null 2>&1                         # retired into an unstarted commit successor, keyed
SUC=$(fm cycle_id)
rm -f .claude/litmus-state.md
git checkout -q --detach                        # refused by (a); --force is what that refusal prescribes
INIT --force 10 >/dev/null 2>&1
NEW=$(fm cycle_id)
check "the forced replacement names the keyed journalled successor it replaces" '[ "$NEW" != "$SUC" ] && grep -q "\"replaces_cycle_id\": \"$SUC\"" "$LEDGER"'
echo pass > .mock/mode; RUN >/dev/null 2>&1     # the replacement completes
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "...so once it completes, the detached checkout stops refusing on the replaced journal" '[ "$rc" = 0 ] && [ "$(LIB ledger_query superseded "$SUC")" = 1 ] && [ -z "$(LIB ledger_query keyed_pending_retire)" ] && [ "$(fm cycle_id)" != "$SUC" ]'

# (d) AND THE AMBIGUITY THAT WAS NOT ONE. A journal under the forcing checkout OWN key needs no
# naming -- the forced open is born under that key and supersedes it for free -- so listing it
# only ever added a second candidate, and with it the refusal, to a ledger that recovers cleanly.
new_sandbox
BR=$(git symbolic-ref --short HEAD)
make_pr_fail deadbeef 2
INIT 10 >/dev/null 2>&1                         # journal under THIS branch key
SA=$(fm cycle_id)
rm -f .claude/litmus-state.md
git checkout -q -b other-branch
make_pr_fail deadbeef 2
git checkout -q --detach
INIT 10 >/dev/null 2>&1                         # a second journal, this one keyless
SB=$(fm cycle_id)
rm -f .claude/litmus-state.md
git checkout -q "$BR"
check "two pending journals, one under this key and one under none" '[ "$SA" != "$SB" ] && [ "$(count retire)" = 2 ] && [ -n "$(LIB ledger_query keyed_pending_retire)" ] && [ -n "$(LIB ledger_query keyless_pending_retire)" ]'
rc=0; INIT --force 10 >/dev/null 2>&1 || rc=$?
check "--force names only the one its own key cannot supersede, and both end superseded" '[ "$rc" = 0 ] && grep -q "\"replaces_cycle_id\": \"$SB\"" "$LEDGER" && ! grep -q "\"replaces_cycle_id\": \"$SA\"" "$LEDGER" && [ "$(LIB ledger_query superseded "$SA")" = 1 ] && [ "$(LIB ledger_query superseded "$SB")" = 1 ]'

# (e) THE SAME REDUNDANCY POINTING THE OTHER WAY. A keyless birth supersedes every keyless cycle
# for free, so a detached --force never needs to name one either -- and listing them there cost
# the same ambiguity refusal in the same recoverable ledger. The two halves are complements.
new_sandbox
git checkout -q --detach
make_pr_fail deadbeef 2
INIT 10 >/dev/null 2>&1                         # a keyless journal: unstarted successor SB
SB=$(fm cycle_id)
rm -f .claude/litmus-state.md
# ...and a KEYED journal of another lineage, appended the way section 6 appends one
ledger_add event=open lineage_id=1111111111111111 cycle_id=2222222222222222 review_mode=pr max_iterations=2 "lineage_key=deadbeefroot@other-branch"
ledger_add event=retire lineage_id=1111111111111111 cycle_id=2222222222222222 successor_cycle_id=feedfacefeedface \
    target_mode=commit max_iterations=2 iteration=2 reviewed_diff_hash=deadbeef "lineage_key=deadbeefroot@other-branch"
check "a detached checkout facing one journal of each kind" '[ -n "$(LIB ledger_query keyless_pending_retire)" ] && [ -n "$(LIB ledger_query keyed_pending_retire)" ] && [ "$(LIB ledger_query superseded "$SB")" = 0 ]'
rc=0; INIT --force 10 >/dev/null 2>&1 || rc=$?
check "--force there names only the keyed one, and both end superseded" '[ "$rc" = 0 ] && grep -q "\"replaces_cycle_id\": \"feedfacefeedface\"" "$LEDGER" && ! grep -q "\"replaces_cycle_id\": \"$SB\"" "$LEDGER" && [ "$(LIB ledger_query superseded "$SB")" = 1 ] && [ "$(LIB ledger_query superseded feedfacefeedface)" = 1 ]'

# === 41. the three blocking findings of the PR review of 8c9ac860 ===
# (a) A keyless checkout is refused by KEYED charges too -- unresolved_any counts them -- and a
# keyless birth supersedes none of them, so a forced open that named only journals left the
# refusal exactly where it was: the prescribed recovery recovering nothing, again.
new_sandbox
BR=$(git symbolic-ref --short HEAD)
INIT 10 >/dev/null 2>&1
A=$(fm cycle_id); AL=$(fm lineage_id); H=$(git rev-parse HEAD)
ledger_add event=attempt "lineage_id=$AL" "cycle_id=$A" iteration=1 "head_sha=$H" reviewed_diff_hash=deadbeef
LIB ledger_append abandon "lineage_id=$AL" "cycle_id=$A" settles_seq=1 abandon_reason=interrupted "head_sha=$H"
rm -f .claude/litmus-state.md
git checkout -q --detach
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "a detached checkout is refused by the keyed charge it may own" '[ "$rc" != 0 ] && [ "$(LIB ledger_query unresolved_any)" = 1 ] && [ "$(LIB ledger_query replaceable_ids "")" = "$A" ]'
INIT --force 10 >/dev/null 2>&1                 # the recovery that refusal prescribes
echo pass > .mock/mode; RUN >/dev/null 2>&1
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "--force there names the keyed cycle, so the completed replacement frees the checkout" '[ "$rc" = 0 ] && grep -q "\"replaces_cycle_id\": \"$A\"" "$LEDGER" && [ "$(LIB ledger_query superseded "$A")" = 1 ] && [ "$(LIB ledger_query unresolved_any)" = 0 ]'
# (b) A retirement answers to the PREDECESSOR key as well as its own. Made on another branch, it
# was offered here for adoption -- and the successor it installs is born under that other key, so
# every completion the marker writer is asked for afterwards refuses. It belongs to its own key.
new_sandbox
BR=$(git symbolic-ref --short HEAD)
make_pr_fail deadbeef 2
PRED=$(fm cycle_id)
git checkout -q -b other-branch
INIT 10 >/dev/null 2>&1                         # retirement journalled under the OTHER key
SUC=$(fm cycle_id)
rm -f .claude/litmus-state.md
git checkout -q "$BR"
check "the journal names the other branch, so this one is not offered it" '[ "$(LIB ledger_query birth_key "$SUC")" != "$(LIB ledger_query birth_key "$PRED")" ] && [ -z "$(LIB ledger_query pending_retire "$(LIB ledger_query birth_key "$PRED")")" ]'
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "...so it opens its own cycle instead of installing a successor it could never complete" '[ "$rc" = 0 ] && [ "$(fm cycle_id)" != "$SUC" ] && [ "$(count open)" = 2 ]'
# (c) A state file written before the install still names the PREDECESSOR while the ledger has
# already created the successor. A forced recovery reading it replaced the retired cycle and left
# the live successor neither named nor superseded, and its own branch reinstalled it afterwards.
new_sandbox
BR=$(git symbolic-ref --short HEAD)
make_pr_fail deadbeef 2
PRED=$(fm cycle_id)
ledger_add event=retire "lineage_id=$(fm lineage_id)" "cycle_id=$PRED" successor_cycle_id=feedfacefeedface \
    target_mode=commit max_iterations=2 iteration=2 reviewed_diff_hash=deadbeef   # crash: journalled, not installed
git checkout -q -b other-branch
INIT --force 10 >/dev/null 2>&1                 # forced from elsewhere, reading that stale state
check "the forced recovery replaces the live successor, not the cycle already retired" 'grep -q "\"replaces_cycle_id\": \"feedfacefeedface\"" "$LEDGER" && ! grep -q "\"replaces_cycle_id\": \"$PRED\"" "$LEDGER" && [ "$(LIB ledger_query superseded feedfacefeedface)" = 1 ]'
echo pass > .mock/mode; RUN >/dev/null 2>&1
git checkout -q "$BR"
rc=0; INIT 10 >/dev/null 2>&1 || rc=$?
check "...so the original branch does not reinstall it on its old budget" '[ "$rc" = 0 ] && [ "$(fm cycle_id)" != feedfacefeedface ] && [ "$(fm max_iterations)" = 10 ]'

# (d) AND THE JOURNAL THAT NAMES NO KEY AT ALL, read forwards instead of back: a keyed checkout
# installing one creates a successor born KEYLESS, and the marker writer then refuses every
# completion it is asked for, because that birth key is not this checkout. Reached through the
# predecessor, which the retirement answers to whatever key it carries -- so a branch could adopt
# a journal made while detached and inherit a cycle it can never finish.
new_sandbox
BR=$(git symbolic-ref --short HEAD)
make_pr_fail deadbeef 2
PRED=$(fm cycle_id)
git checkout -q --detach                        # the retirement is journalled with no key
INIT 10 >/dev/null 2>&1
SUC=$(fm cycle_id)
rm -f .claude/litmus-state.md
git checkout -q "$BR"
check "the keyless journal is not offered to the branch that owns its predecessor" '[ -z "$(LIB ledger_query birth_key "$SUC")" ] && [ -n "$(LIB ledger_query birth_key "$PRED")" ] && [ -z "$(LIB ledger_query pending_retire "$(LIB ledger_query birth_key "$PRED")")" ]'
rc=0; out=$(INIT 10 2>&1) || rc=$?
check "...so the branch refuses it instead of inheriting a cycle it could never complete" '[ "$rc" != 0 ] && [ "$(count open)" = 1 ] && printf "%s" "$out" | grep -q "names no branch"'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
