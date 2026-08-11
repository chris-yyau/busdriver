#!/usr/bin/env bash
# tests/test-pr-grinder-skill-read-scope.sh
#
# The pr-grinder worker contract is self-contained for Steps 1-6.5. It used to
# open with a MANDATORY wholesale `Read skills/pr-grind/SKILL.md`, ordered on
# the claim that "the full Step 1-6 protocol" lived there. It does not — that
# protocol is inline in agents/pr-grinder.md, and SKILL.md is dispatcher
# control flow. The order cost ~25k Sonnet tokens on every dispatched round
# (4-5 rounds is a normal grind) and returned nothing the worker lacked.
#
# This test pins BOTH halves of that, because prose alone would survive
# exactly until the next edit that "helpfully" restores the read:
#   (1) the contract does not order a wholesale read, and
#   (2) the premise still holds — SKILL.md really has no worker step protocol.
# Assertion (2) is the load-bearing one: if someone moves worker steps back
# into SKILL.md, the worker would once again need it, and this test fails
# rather than letting the contract silently go stale in the other direction.
#
# CEILING (named honestly): this is a golden-grep over document text. It proves
# what the contract SAYS, not what a dispatched worker DOES. A worker that
# reads SKILL.md unprompted is not caught here.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKER="$SCRIPT_DIR/agents/pr-grinder.md"
SKILL="$SCRIPT_DIR/skills/pr-grind/SKILL.md"

passed=0; failed=0
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }

for _f in "$WORKER" "$SKILL"; do
  [[ -f "$_f" ]] || { fail "missing $_f"; echo "Results: $passed passed, $failed failed"; exit 1; }
done

# (1) No wholesale read order. Matching only `Read` + path would miss a
# paraphrase ("read the whole file at .../SKILL.md"); matching the word
# anywhere on the line false-positives on long lines that say "read budget
# pressure" or "Edit/Read/Write tool calls" and only cite the path at the end.
# So: anchor the verb to the path — look for a read verb in a 60-character
# window on EITHER side of the path mention (a wholesale-read order can be
# phrased before the path, "Read .../SKILL.md", or after it, ".../SKILL.md —
# read it fully"; checking only the PRECEDING window misses the latter), after
# dropping lines whose whole point is to scope or forbid the read. Legitimate
# cross-references ("see .../SKILL.md Safety Rails for the rationale") carry
# no read verb in either window and correctly stay unflagged.
UNSCOPED=$(awk '
  index($0, "skills/pr-grind/SKILL.md") == 0 { next }
  /named section|[Dd]o NOT read|wholesale "for context"/ { next }
  {
    idx = index($0, "skills/pr-grind/SKILL.md")
    pathlen = length("skills/pr-grind/SKILL.md")
    pre = substr($0, 1, idx - 1)
    if (length(pre) > 60) pre = substr(pre, length(pre) - 59)
    post = substr($0, idx + pathlen)
    if (length(post) > 60) post = substr(post, 1, 60)
    if (tolower(pre) ~ /read/ || tolower(post) ~ /read/) printf "%d: %s\n", NR, substr($0, 1, 150)
  }' "$WORKER")
if [[ -n "$UNSCOPED" ]]; then
  fail "worker contract carries an unscoped read of SKILL.md (~25k tokens/round of dispatcher control flow):"
  echo "$UNSCOPED" | sed 's/^/        /' | cut -c1-160
else
  ok "no unscoped read of skills/pr-grind/SKILL.md in the worker contract"
fi

# (1b) Companion guard for (1): the UNSCOPED check above passes vacuously if
# the literal path is ever renamed or reworded in the worker — every line
# would fail the `index(...) == 0` prefilter, UNSCOPED stays empty, and (1)
# reports OK without having checked anything. Assert the literal is still
# referenced at all, so a path rename can't silently disable half the guard.
if grep -q "skills/pr-grind/SKILL.md" "$WORKER"; then
  ok "worker contract still references the skills/pr-grind/SKILL.md literal (assertion 1's prefilter has something to check)"
else
  fail "worker contract no longer references 'skills/pr-grind/SKILL.md' at all — assertion 1 passed vacuously; update the literal in this test if the path was intentionally renamed"
fi

# (2) No bail/anti-pattern row punishing a read that is no longer ordered —
# a guard that cannot fire certifies a check it never runs.
if grep -qi 'Skipped.*mandatory Read of SKILL\.md\|skipped pre-flight Read' "$WORKER"; then
  fail "worker contract still bails on skipping a Read it no longer orders (guard cannot fire)"
else
  ok "no unfirable 'skipped the mandatory Read' bail trigger"
fi

# (3) The premise: SKILL.md carries no worker step protocol. Step 0 is the
# DISPATCHER's ephemeral-worktree creation and is expected to stay.
STRAY_STEPS=$(grep -cE '^#+ +Step [1-6]' "$SKILL" || true)
if [[ "$STRAY_STEPS" -eq 0 ]]; then
  ok "SKILL.md declares no worker Step 1-6 headings (premise holds)"
else
  fail "SKILL.md now declares $STRAY_STEPS worker Step 1-6 heading(s) — the worker may need it again; re-check the contract"
fi

if grep -q 'Phase 2\.5' "$SKILL"; then
  fail "SKILL.md contains a Phase 2.5 check-verification block — worker protocol has drifted back in"
else
  ok "SKILL.md contains no Phase 2.5 block (premise holds)"
fi

# (4) The worker still has a reachable path to the gate-block protocol, which
# is the one thing the dropped read could plausibly have supplied. The worker
# does Write/Edit, so the design-review gate and the freeze guard can fire on
# IT (careful-guard is Bash-only and cannot). Require the
# ${CLAUDE_PLUGIN_ROOT}-qualified form specifically — a bare
# 'blueprint-review/SKILL.md' match would pass vacuously even if the worker
# reverted to an unqualified relative path, which only resolves when the
# targeted repo IS busdriver itself (see agents/pr-grinder.md's own note on
# why both on-demand reads must resolve against the plugin install root).
# shellcheck disable=SC2016  # the literal string ${CLAUDE_PLUGIN_ROOT} is the
# thing being searched for in the worker contract — expanding it here would
# search for this test process's own plugin root and never match.
if grep -q '\${CLAUDE_PLUGIN_ROOT}/skills/blueprint-review/SKILL\.md' "$WORKER"; then
  ok "worker retains an on-demand, plugin-root-qualified pointer to the canonical skip-file protocol"
else
  fail "worker has no \${CLAUDE_PLUGIN_ROOT}-qualified route to the gate-block/skip-file protocol — dropped read left a real gap, or the path regressed to an unqualified relative form"
fi

# (5) Never create a skip file: this must survive any rewrite of Step 0.
if grep -qi 'never create a skip file' "$WORKER"; then
  ok "worker contract retains the never-self-create-a-skip-file rule"
else
  fail "worker contract lost the never-self-create-a-skip-file rule"
fi

echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
