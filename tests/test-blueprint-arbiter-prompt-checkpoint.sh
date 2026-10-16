#!/usr/bin/env bash
# tests/test-blueprint-arbiter-prompt-checkpoint.sh — regression for #547.
#
# The arbiter prompt (claude-validation-prompt.txt) used to be written only AFTER
# the residual UltraOracle wait. A loop killed during that wait lost a round whose
# three reviewers had finished: no prompt, so the session could not dispatch the
# arbiter and --claude-only had nothing to resume. The fix checkpoints the prompt
# before the wait and rewrites it once the advisory is in.
#
# Behavioural: drives the real loop with every reviewer forced unavailable
# (BUSDRIVER_REVIEW_CLI=agy with no agy on PATH, so nothing leaves the machine)
# and a stub `oracle` on PATH.
#   (A) slow oracle, loop killed mid-wait -> prompt exists, says the advisory is pending
#   (B) fast oracle, loop runs to the end -> final prompt carries the advisory, no pending note
#
# Usage: bash tests/test-blueprint-arbiter-prompt-checkpoint.sh [plugin-root]
#   The optional plugin root lets you point it at an unfixed checkout to watch (A) fail.
set -u
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
DIR="$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd)" || exit 1
LOOP="$DIR/skills/blueprint-review/scripts/run-design-review-loop.sh"
FAIL=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAIL=1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT INT TERM
export HOME="$T/home"; mkdir -p "$HOME/.claude" "$T/bin"
for c in jq git python3 perl timeout gtimeout; do
  p="$(command -v "$c" 2>/dev/null)" && ln -s "$p" "$T/bin/$c"
done
export PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# The offline setup rests on agy being unresolvable; refuse to run real reviews.
if command -v agy >/dev/null 2>&1; then echo "FAIL: agy resolves on PATH ($(command -v agy)); test would run real reviews"; exit 1; fi
export ULTRA_ORACLE_TEST_NO_LOCK=1 BUSDRIVER_REVIEW_CLI=agy
export BUSDRIVER_PLUGIN_ROOT="$DIR" CLAUDE_PLUGIN_ROOT="$DIR" BUSDRIVER_STATE_DIR=".claude"
printf '{"ultraOracle":{"blueprintReview":{"enabled":true},"timeoutCapSeconds":120}}\n' > "$HOME/.claude/busdriver.json"

stub_oracle() {  # <seconds before the advisory lands>
  cat > "$T/bin/oracle" <<EOF
#!/bin/bash
out=""
while [ \$# -gt 0 ]; do case "\$1" in --write-output) out="\$2"; shift 2;; *) shift;; esac; done
sleep $1 & trap 'kill \$! 2>/dev/null; exit 143' TERM; wait \$!
[ -n "\$out" ] && printf 'ADVISORY: stub verdict\n' > "\$out"
exit 0
EOF
  chmod +x "$T/bin/oracle"
}

new_repo() {  # <name> -> cd into a fresh repo with an initialised review of plan.md
  mkdir -p "$T/$1/.claude"; cd "$T/$1" || exit 1; git init -q
  printf '# Plan\n\nStep 1: do a thing.\n' > plan.md
  bash "$DIR/skills/blueprint-review/scripts/init-design-review.sh" plan.md 3 >/dev/null 2>&1
}
PF=docs/reviews/plan/claude-validation-prompt.txt

# (A) killed during the oracle wait
stub_oracle 300
new_repo a
bash "$LOOP" --auto </dev/null >"$T/a.log" 2>&1 &
pid=$!
for _ in $(seq 1 120); do   # poll for the checkpoint itself, not the Phase 3 banner before it
  grep -q 'Arbiter prompt checkpointed before the UltraOracle wait' "$T/a.log" && break
  kill -0 "$pid" 2>/dev/null || break
  sleep 1
done
if kill -0 "$pid" 2>/dev/null; then pass "(A) loop is still waiting on the oracle"; else fail "(A) loop exited before the wait"; fi
pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
pkill -f "$T/bin/oracle" 2>/dev/null
if [[ -s "$PF" ]]; then pass "(A) arbiter prompt exists after a kill mid-wait"; else fail "(A) arbiter prompt missing after a kill mid-wait"; fi
if grep -qF 'ULTRA-ORACLE ADVISORY PENDING' "$PF" 2>/dev/null; then pass "(A) prompt marks the advisory pending"; else fail "(A) prompt does not mark the advisory pending"; fi
if grep -qF 'run_id:' "$PF" 2>/dev/null; then pass "(A) prompt carries the freshness contract"; else fail "(A) prompt lacks the freshness contract"; fi

# (B) the oracle returns: the checkpoint is replaced by the full prompt.
# No outer timeout: the loop's own oracle cap (120s + grace) bounds this run.
stub_oracle 1
new_repo b
bash "$LOOP" --auto </dev/null >"$T/b.log" 2>&1
if grep -qF 'ADVISORY: stub verdict' "$PF" 2>/dev/null; then pass "(B) final prompt carries the advisory"; else fail "(B) final prompt lacks the advisory"; fi
if grep -qF 'ULTRA-ORACLE ADVISORY PENDING' "$PF" 2>/dev/null; then fail "(B) pending note left in the final prompt"; else pass "(B) pending note replaced"; fi

if [[ "$FAIL" != 0 ]]; then exit 1; fi
echo "PASS test-blueprint-arbiter-prompt-checkpoint"
