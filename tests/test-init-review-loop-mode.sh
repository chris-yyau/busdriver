#!/usr/bin/env bash
# tests/test-init-review-loop-mode.sh — init-review-loop.sh mode-aware re-init (#363).
#
# The active-loop guard exists to protect an in-flight loop's iteration counter from a
# careless re-init. It was scoped too widely: it refused for ANY active state file, even
# when the caller asked for a DIFFERENT review mode. Since run-review-loop.sh reads
# review_mode from the state file and lets it OVERRIDE $LITMUS_MODE, a refused init left
# the stale mode in place and the next run silently reviewed the wrong diff (commit mode
# reviews `git diff --cached`; pr mode reviews `origin/main...HEAD`).
#
# The state file only lingers when a run was killed mid-review — e.g. a blocking call
# hitting the harness Bash timeout, which is the same #363 the timeout-doc fix addresses.
#
# Usage: bash tests/test-init-review-loop-mode.sh
# Exit: 0 if all pass, 1 if any fail.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok()   { printf "  PASS  %s\n" "$1"; PASS=$((PASS + 1)); }
bad()  { printf "  FAIL  %s\n" "$1"; FAIL=$((FAIL + 1)); }

# Fail HARD if the sandbox cannot be made. Without -e an empty SANDBOX would turn every
# path below into an absolute one (/skills/..., /.claude) and the mkdir/cp/rm would act
# on the FILESYSTEM ROOT. Verify it is a real directory, not merely a non-empty string.
SANDBOX=$(mktemp -d) || { echo "FATAL: mktemp -d failed"; exit 1; }
if [ -z "$SANDBOX" ] || [ ! -d "$SANDBOX" ]; then
    echo "FATAL: sandbox path is not a directory: '$SANDBOX'"; exit 1
fi
trap 'if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then rm -rf "$SANDBOX"; fi' EXIT

# Mirror the plugin layout the script resolves against: init-review-loop.sh sources
# lib/ relative to its own location, and validation.sh in turn sources scripts/lib/.
mkdir -p "$SANDBOX/skills/litmus/scripts/lib" "$SANDBOX/scripts/lib" "$SANDBOX/.claude"
cp "$REPO_ROOT/skills/litmus/scripts/init-review-loop.sh" "$SANDBOX/skills/litmus/scripts/"
cp -r "$REPO_ROOT"/skills/litmus/scripts/lib/* "$SANDBOX/skills/litmus/scripts/lib/" 2>/dev/null || true
cp -r "$REPO_ROOT"/scripts/lib/* "$SANDBOX/scripts/lib/" 2>/dev/null || true
cd "$SANDBOX" || exit 1
git init -q .
git config user.email t@t.com
git config user.name t

INIT="skills/litmus/scripts/init-review-loop.sh"

# $1 = review_mode value to seed, $2 = iteration
seed_state() {
    printf -- '---\nactive: true\niteration: %s\nmax_iterations: 10\ncompletion_promise: null\nreview_mode: "%s"\nreview_status: "PENDING"\nstarted_at: "2026-07-17T01:00:00Z"\nlast_result: null\n---\nbody\n' \
        "$2" "$1" > .claude/litmus-state.md
}
mode_now() { grep -E '^review_mode:' .claude/litmus-state.md | tr -d ' "' | cut -d: -f2; }

# 1. THE BUG: a killed PR-mode run leaves active state; the operator asks for commit
#    mode. Init must REFUSE (it cannot tell a killed loop from a live one, and clearing
#    a live loop's state would race its writer) — but the refusal must NAME the mismatch,
#    because silently re-running run-review-loop.sh here reviews the WRONG DIFF:
#    review_mode in the state file overrides $LITMUS_MODE. The old message never
#    mentioned the mode, which is exactly why the stranding went unnoticed.
seed_state pr 2
rc=0; out=$(bash "$INIT" 10 2>&1) || rc=$?
if [ "$rc" -ne 0 ] && [ "$(mode_now)" = "pr" ]; then
    ok "#363: stale pr-mode state + commit requested → refuses, state untouched"
else
    bad "#363: stale pr-mode state + commit requested (rc=$rc mode=$(mode_now), want rc!=0 mode=pr)"
fi
if printf '%s' "$out" | grep -q "requested mode=commit but the state file says mode=pr"; then
    ok "#363: refusal names the mode mismatch"
else
    bad "#363: refusal must name the mode mismatch (got: $(printf '%s' "$out" | head -2 | tr '\n' ' '))"
fi
if printf '%s' "$out" | grep -q "OVERRIDES"; then
    ok "#363: refusal explains review_mode overrides LITMUS_MODE"
else
    bad "#363: refusal must explain the override"
fi
# The advice must not tell an operator whose review is RUNNING to start a second loop —
# that is the concurrent-writer race the guard exists to prevent, and an earlier draft
# of this message did exactly that while the comment above it forbade it. The three
# cases must stay distinguishable, keyed on what is actually true.
if printf '%s' "$out" | grep -q "WAIT for it. Do NOT start another"; then
    ok "#363: refusal tells a running review to WAIT, not to re-run"
else
    bad "#363: refusal must not advise starting a second loop while one runs"
fi
for c in "(a)" "(b)" "(c)"; do
    if printf '%s' "$out" | grep -qF "$c"; then
        ok "#363: refusal offers case $c"
    else
        bad "#363: refusal missing case $c"
    fi
done

# 2. Mirror image: stale commit-mode state, PR mode requested → same treatment.
seed_state commit 3
rc=0; out=$(env LITMUS_MODE=pr bash "$INIT" 10 2>&1) || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "requested mode=pr but the state file says mode=commit"; then
    ok "#363: stale commit-mode state + pr requested → refuses and names it"
else
    bad "#363: stale commit-mode state + pr requested (rc=$rc), want refuse + mismatch named"
fi
# The --force remedy must CARRY the mode. LITMUS_MODE is an env var, so a bare
# `--force` re-creates commit mode and reproduces the very wrong-diff bug this fix is
# about — an operator pasting the printed command must land in the mode they asked for.
if printf '%s' "$out" | grep -q "LITMUS_MODE=pr .*--force"; then
    ok "#363: --force remedy carries LITMUS_MODE=pr"
else
    bad "#363: --force remedy must carry LITMUS_MODE=pr (got: $(printf '%s' "$out" | grep -- --force | tr -d ' '))"
fi
# ...and must NOT carry it when commit mode was requested (it is the default; a bogus
# prefix would be cargo-cult noise).
seed_state pr 3
rc=0; out2=$(bash "$INIT" 10 2>&1) || rc=$?
if printf '%s' "$out2" | grep -q "LITMUS_MODE="; then
    bad "#363: commit-mode remedy must not carry a LITMUS_MODE prefix"
else
    ok "#363: commit-mode remedy omits the LITMUS_MODE prefix"
fi

# 3. GUARD PRESERVED: same mode + active loop still refuses, and does NOT emit the
#    mismatch text (there is no mismatch). Pins that the message stays diagnostic
#    rather than becoming noise on the ordinary path.
seed_state commit 4
rc=0; out=$(bash "$INIT" 10 2>&1) || rc=$?
ITER_AFTER=$(grep -E '^iteration:' .claude/litmus-state.md | tr -d ' ' | cut -d: -f2)
if [ "$rc" -ne 0 ] && [ "$ITER_AFTER" = "4" ]; then
    ok "#363: same-mode active loop still refuses, counter untouched"
else
    bad "#363: same-mode active loop should refuse (rc=$rc iteration=$ITER_AFTER, want rc!=0 iteration=4)"
fi
if printf '%s' "$out" | grep -q "but the state file says mode="; then
    bad "#363: same-mode refusal must NOT claim a mode mismatch"
else
    ok "#363: same-mode refusal omits the mismatch text"
fi

# 3b. A LIVE loop is the reason the guard cannot auto-re-init: `active: true` does not
#     distinguish killed from running. Pin that a mode change never clears state — a
#     concurrent writer would otherwise lose its iteration history mid-review.
seed_state pr 5
rc=0; bash "$INIT" 10 >/dev/null 2>&1 || rc=$?
ITER_AFTER=$(grep -E '^iteration:' .claude/litmus-state.md | tr -d ' ' | cut -d: -f2)
if [ "$ITER_AFTER" = "5" ]; then
    ok "#363: mode change never clears a possibly-live loop's state"
else
    bad "#363: mode change must not touch state (iteration=$ITER_AFTER, want 5)"
fi

# 3c. LITMUS_MODE is normalized the same way the state writer normalizes it, so a typo
#     cannot read as a third mode and report a bogus mismatch against a commit state.
seed_state commit 6
rc=0; out=$(env LITMUS_MODE=typo bash "$INIT" 10 2>&1) || rc=$?
if [ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q "but the state file says mode="; then
    ok "#363: invalid LITMUS_MODE normalizes to commit (no bogus mismatch)"
else
    bad "#363: invalid LITMUS_MODE should normalize to commit (rc=$rc)"
fi

# 4. --force still wins over the same-mode guard.
seed_state commit 7
rc=0; bash "$INIT" --force 10 >/dev/null 2>&1 || rc=$?
ITER_AFTER=$(grep -E '^iteration:' .claude/litmus-state.md | tr -d ' ' | cut -d: -f2)
if [ "$rc" -eq 0 ] && [ "$ITER_AFTER" = "1" ]; then
    ok "#363: --force re-inits a same-mode active loop"
else
    bad "#363: --force should re-init (rc=$rc iteration=$ITER_AFTER, want rc=0 iteration=1)"
fi

# 5. An inactive (completed) loop is re-initable in the same mode — unchanged behavior.
printf -- '---\nactive: false\niteration: 5\nmax_iterations: 10\ncompletion_promise: null\nreview_mode: "commit"\n---\nbody\n' > .claude/litmus-state.md
rc=0; bash "$INIT" 10 >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
    ok "#363: inactive loop re-inits in the same mode"
else
    bad "#363: inactive loop should re-init (rc=$rc)"
fi

# 6. A state file predating review_mode must still get the counter guard, not a free
#    re-init — absent field defaults to "commit" rather than to "differs from anything".
printf -- '---\nactive: true\niteration: 6\nmax_iterations: 10\ncompletion_promise: null\n---\nbody\n' > .claude/litmus-state.md
rc=0; bash "$INIT" 10 >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
    ok "#363: legacy state without review_mode still guarded (defaults to commit)"
else
    bad "#363: legacy state without review_mode should still refuse in commit mode (rc=$rc)"
fi

# 6b. ...but it must NOT claim a mode mismatch. run-review-loop.sh only lets the state
#     file override $LITMUS_MODE when review_mode is non-empty and != "null"; an ABSENT
#     field means it falls back to $LITMUS_MODE. So with LITMUS_MODE=pr and a legacy
#     file, run-review-loop.sh WOULD review the pr diff — asserting "the state says
#     commit, you will get the commit diff" is the exact inversion of the truth, i.e.
#     the class of lie this whole change removes. Guard still refuses; message must not
#     invent a clash that does not exist.
rc=0; out=$(env LITMUS_MODE=pr bash "$INIT" 10 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then
    ok "#363: legacy state + pr requested → still refuses"
else
    bad "#363: legacy state + pr requested should refuse (rc=$rc)"
fi
if printf '%s' "$out" | grep -q "but the state file says mode="; then
    bad "#363: legacy state must NOT claim a mode mismatch (run-review-loop would use \$LITMUS_MODE)"
else
    ok "#363: legacy state claims no mode mismatch"
fi
if printf '%s' "$out" | grep -q "mode=unset"; then
    ok "#363: legacy state reports mode as unset, not a fabricated 'commit'"
else
    bad "#363: legacy state should report mode=unset (got: $(printf '%s' "$out" | head -1))"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
