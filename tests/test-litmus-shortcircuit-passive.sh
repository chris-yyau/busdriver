#!/usr/bin/env bash
# test-litmus-shortcircuit-passive.sh
# Regression for #415: the commit-mode litmus short-circuit weighted deletions
# at 1/4, so a 39-line PURE DELETION scored 9 (< the default 10 threshold) and
# committed without Codex review — deleting an auth guard was cheaper to slip
# through than inverting it. The fast path is now gated on WHAT changed, not
# only how much: every changed path must be passive prose.
#
# SC_PASSIVE_PATTERN is EXTRACTED from run-review-loop.sh rather than restated
# here, so the assertions below can never drift from the shipped predicate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/skills/litmus/scripts/run-review-loop.sh"

pass=0 fail=0
# Takes the PATHS, not a pre-substituted verdict: keeping the command
# substitution inside the function means call sites are plain literals.
check() { # name expected(FAST|FULL) <changed paths, newline separated>
  local got
  got=$(decide "$3")
  if [[ "$got" == "$2" ]]; then echo "PASS: $1"; pass=$((pass+1))
  else echo "FAIL: $1 — expected $2 got $got"; fail=$((fail+1)); fi
}

# Pull the live assignment out of the script (single source of truth).
PATTERN_LINE=$(grep -m1 "^  SC_PASSIVE_PATTERN=" "$SCRIPT") || {
  echo "FAIL: SC_PASSIVE_PATTERN assignment not found in $SCRIPT"; exit 1; }
eval "${PATTERN_LINE#  }"
[[ -n "${SC_PASSIVE_PATTERN:-}" ]] || { echo "FAIL: extracted pattern is empty"; exit 1; }

# Verbatim port of the gate's decision: non-empty grep -Ev output => FULL review.
decide() { # <changed paths, newline separated>
  local active
  active=$(printf '%s\n' "$1" | grep -Ev "$SC_PASSIVE_PATTERN" || true)
  [[ -z "$active" ]] && echo FAST || echo FULL
}

# --- the #415 failure itself -------------------------------------------------
check "39-line source deletion (the #415 hole)" FULL 'src/auth.ts'
check "shell gate script" FULL 'hooks/gate-scripts/pre-commit-gate.sh'

# --- operational markdown is NOT prose ---------------------------------------
check "skill instructions"  FULL 'skills/litmus/SKILL.md'
check "agent definition"    FULL 'agents/code-reviewer.md'
check "command shim"        FULL 'commands/plan.md'
check "rules canon"         FULL 'rules/common/policy.md'
check "project CLAUDE.md"   FULL 'CLAUDE.md'
check "nested CLAUDE.md"    FULL '.claude/CLAUDE.md'

# A standard doc NAME is passive only at the REPO ROOT. Codex caught this on the
# first review pass: an (^|/) anchor matched the name at any depth, so every
# skills/<name>/README.md — documentation OF an operational skill — would have
# taken the fast path. Nesting decides, not the basename.
check "skill README"      FULL 'skills/humanizer/README.md'
check "nested CHANGELOG"  FULL 'skills/orchestrator/CHANGELOG.md'
check "vendored LICENSE"  FULL 'vendor/foo/LICENSE'
check "deep README"       FULL 'a/b/c/README.md'

# --- genuine prose keeps the fast path ---------------------------------------
check "README"        FAST 'README.md'
check "CHANGELOG"     FAST 'CHANGELOG.md'
check "LICENSE"       FAST 'LICENSE'
check "ADR"           FAST 'docs/adr/0012-advisory-bot.md'
check "docs, nested"  FAST 'docs/guides/setup/install.md'
check "several prose" FAST 'README.md
docs/adr/0001-x.md
CHANGELOG.md'

# --- one active file poisons an otherwise-passive set ------------------------
check "prose + one source file" FULL 'README.md
docs/adr/0001-x.md
src/auth.ts'

# --- real git rename, not a hand-fed path pair -------------------------------
# The first version of this test SUPPLIED both paths itself and therefore proved
# nothing; Codex caught it. `git diff --cached --name-only` reports ONLY the
# rename DESTINATION, so moving active source to a passive path is the sharpest
# way to launder it onto the fast path. Drive real git and assert on real output.
rename_probe() { # -> the path list the gate would classify
  local repo
  repo=$(mktemp -d)
  (
    cd "$repo" || exit 1
    git init -q .
    mkdir -p src docs
    # >50% content change would break rename detection; keep the body identical.
    printf 'if (isAuthorized) { allow(); }\n%.0s' {1..20} > src/auth.ts
    git add -A
    git -c user.email=t@t -c user.name=t commit -qm base
    git mv src/auth.ts docs/auth.md
    # EXACTLY the command the gate uses for its classification.
    git diff --cached --name-only --no-renames
  )
  rm -rf "$repo"
}
PROBE_PATHS=$(rename_probe)
check "real git rename, source into docs/" FULL "$PROBE_PATHS"
# Pin WHY it is caught: --no-renames must expose the deleted active source.
if grep -q '^src/auth\.ts$' <<<"$PROBE_PATHS"; then
  echo "PASS: rename exposes the active source side"; pass=$((pass+1))
else
  echo "FAIL: rename exposes the active source side — got: ${PROBE_PATHS//$'\n'/, }"
  fail=$((fail+1))
fi

# --- fail-closed on anything unrecognized ------------------------------------
check "bare docs-adjacent name" FULL 'notes.md'
check "config"                  FULL 'package.json'
check "workflow"                FULL '.github/workflows/tests.yml'
check "docs/ non-prose ext"     FULL 'docs/scripts/build.sh'

echo "---"
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]
