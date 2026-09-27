#!/usr/bin/env bash
# Pins how the two gates of record choose the codex reasoning tier (#864).
#
# Both loops used to `export LITMUS_CODEX_EFFORT=xhigh`. The pin was added so a
# gate of record would not inherit a drifting `~/.codex/config.toml`; it then
# became the drifting end itself once the operator config moved off xhigh, and a
# 671-weighted-line PR diff burned the whole LITMUS_TIMEOUT budget twice at a
# tier nobody runs. The tier now follows config.toml.
#
# Why a test: the fix is one word, and the WRONG one-word fix (delete the line)
# looks identical in a diff review while silently re-opening #325 / ADR 0016 —
# a reviewed fork's committed `.claude/settings.json` `env` block sets session
# env, so an omitted line lets the artifact under review export `minimal` and
# weaken the reviewer that gates it. `unset` neutralizes that AND yields to
# config.toml, which is operator-owned and outside the repo. Prose cannot hold
# that distinction; these assertions can.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LITMUS="$ROOT/skills/litmus/scripts/run-review-loop.sh"
BLUEPRINT="$ROOT/skills/blueprint-review/scripts/run-design-review-loop.sh"

pass=0; fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

for f in "$LITMUS" "$BLUEPRINT"; do
  [[ -f "$f" ]] || { echo "FAIL missing required file: $f"; exit 1; }
done

for f in "$LITMUS" "$BLUEPRINT"; do
  name="${f##*/}"

  # (1) The tier is not hardcoded. Matches an assignment only — the word xhigh
  # may still appear in comments and in the validator's accepted-value list.
  if grep -qE '^[[:space:]]*(export[[:space:]]+)?LITMUS_CODEX_EFFORT=' "$f"; then
    bad "$name: pins LITMUS_CODEX_EFFORT; the tier must follow ~/.codex/config.toml (#864)"
  else
    ok "$name: does not pin a reasoning tier"
  fi

  # (2) ...and it is unset, not merely absent. This is the #325 half: without it
  # a repo-injected ambient value reaches the reviewer.
  if grep -qE '^[[:space:]]*unset[[:space:]]+LITMUS_CODEX_EFFORT[[:space:]]*$' "$f"; then
    ok "$name: unsets LITMUS_CODEX_EFFORT (repo-injected value cannot reach the reviewer)"
  else
    bad "$name: no 'unset LITMUS_CODEX_EFFORT'; an omitted line lets a committed settings.json env block set the tier (#325 / ADR 0016)"
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
