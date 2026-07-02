#!/usr/bin/env bash
# tests/test-agent-effort-tiers.sh
#
# Enforces the per-agent reasoning `effort:` tiering policy across agents/*.md.
# See docs/adr/0009-agent-effort-tiers.md for the rationale.
#
# WHY THIS IS A TEST, NOT PROSE: an agent with NO `effort:` line inherits the
# session/global default (which is `xhigh` in this operator's setup). So a sync
# from upstream that clobbers or drops an effort line does NOT fail loudly — it
# silently reverts that agent to xhigh, a HIDDEN COST regression no other check
# catches. This guard is the durable part of the policy; the frontmatter edits
# just make it pass.
#
# Invariants:
#   (i)   every agents/*.md has exactly ONE valid effort value
#         (low|medium|high|xhigh|max) — reject missing / duplicate / malformed
#   (ii)  any agent whose tools include Write or Edit is >= medium (never low):
#         effort tracks BLAST RADIUS — anything that mutates the working tree
#         reasons at least at medium
#   (iii) gate-critical / secret-handling agents are >= high (a MINIMUM floor
#         for the agents where under-tiering causes real harm — NOT an
#         enumeration of every high-tier agent; deep-reasoning analyzers are
#         high by policy but not floor-enforced, since under-tiering them is a
#         mild cost, not a safety risk)
#   (iv)  effort xhigh|max requires model: opus (sonnet silently caps at ~high,
#         so sonnet+xhigh is a misconfig that pays for reasoning it can't use)
#
# All frontmatter checks are scoped to the YAML block between the first two
# `---` fences, so a body line that happens to begin with `effort:`/`model:`/
# `tools:` (prose, an example) cannot spoof or inflate a match.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS_DIR="$SCRIPT_DIR/agents"

passed=0
failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

# Agents that must reason at >= high (gate-critical reviewers + secret handlers).
GATE_CRITICAL="code-reviewer security-reviewer pr-security-backstop opensource-sanitizer opensource-forker"

# effort -> numeric rank
rank() {
  case "$1" in
    low) echo 0 ;; medium) echo 1 ;; high) echo 2 ;; xhigh) echo 3 ;; max) echo 4 ;;
    *) echo -1 ;;
  esac
}

# Print the YAML frontmatter block (lines strictly between the first two `---`
# fences). Empty output => no well-formed frontmatter block.
frontmatter() {
  awk 'NR==1 && $0=="---" {infm=1; next} infm && $0=="---" {exit} infm {print}' "$1"
}

if [[ ! -d "$AGENTS_DIR" ]]; then
  fail "agents/ dir missing at $AGENTS_DIR"
  echo "Results: $passed passed, $failed failed"
  exit 1
fi

for f in "$AGENTS_DIR"/*.md; do
  name="$(basename "$f" .md)"
  fm="$(frontmatter "$f")"
  if [[ -z "$fm" ]]; then
    fail "$name: no YAML frontmatter block (expected '---' fences at top)"
    continue
  fi

  # (i) exactly one valid effort line (within frontmatter)
  n_effort="$(printf '%s\n' "$fm" | grep -c '^effort:' || true)"
  if [[ "$n_effort" -eq 0 ]]; then
    fail "$name: no effort line (would inherit xhigh default)"
    continue
  fi
  if [[ "$n_effort" -gt 1 ]]; then
    fail "$name: $n_effort effort lines (duplicate)"
    continue
  fi
  effort="$(printf '%s\n' "$fm" | grep -m1 '^effort:' | sed -E 's/^effort:[[:space:]]*//; s/[[:space:]]+$//')"
  r="$(rank "$effort")"
  if [[ "$r" -lt 0 ]]; then
    fail "$name: invalid effort value '$effort'"
    continue
  fi

  # `|| true`: a model-less agent legitimately inherits the session model; don't
  # let grep's exit-1 abort the whole run under `set -e` (invariant iv treats an
  # empty model as "not opus", which is the correct fail for an xhigh/max agent).
  model="$(printf '%s\n' "$fm" | grep -m1 '^model:' | sed -E 's/^model:[[:space:]]*//; s/[[:space:]]+$//' || true)"

  # (ii) Write/Edit tool => >= medium.
  # Quoting-agnostic: matches "Write"/"Edit" and unquoted Write/Edit forms, and
  # NotebookEdit/MultiEdit (also mutating). No non-mutating tool contains these.
  if printf '%s\n' "$fm" | grep -m1 '^tools:' | grep -qE 'Write|Edit'; then
    if [[ "$r" -lt 1 ]]; then
      fail "$name: has Write/Edit tool but effort=$effort (< medium)"
      continue
    fi
  fi

  # (iii) gate-critical => >= high
  case " $GATE_CRITICAL " in
    *" $name "*)
      if [[ "$r" -lt 2 ]]; then
        fail "$name: gate-critical but effort=$effort (< high)"
        continue
      fi
      ;;
  esac

  # (iv) xhigh|max => model: opus
  if [[ "$effort" == xhigh || "$effort" == max ]] && [[ "$model" != opus ]]; then
    fail "$name: effort=$effort requires model:opus but model=$model (silent cap)"
    continue
  fi

  ok "$name ($model/$effort)"
done

echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
