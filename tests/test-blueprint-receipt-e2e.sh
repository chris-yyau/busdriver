#!/usr/bin/env bash
# tests/test-blueprint-receipt-e2e.sh — #893: dispatch-to-receipt, end to end.
#
# The #840 suites check the receipt writer (test-blueprint-receipt-closure.sh) and the
# PASS gate (test-blueprint-pass-verdict-countable.sh, hand-built receipts under
# --claude-only) separately, so either could drift from what the runner actually sends.
# This drives the REAL non --claude-only round through execute_review's agy arm, with a
# stub `agy` on PATH that records the prompt it was handed and echoes the canaries it
# found there. Then it writes the arbiter verdict and runs the real --claude-only PASS
# gate on that receipt.
#
#   (A) honest echo         -> receipt nonces = the prompt's first/last-line canaries, PASS stamped
#   (wrongtail) wrong tail  -> RECEIPT CHECK FAILED no_canary, no PASS
#   (nohead) head omitted   -> RECEIPT CHECK FAILED no_canary, no PASS
#
# Offline: BUSDRIVER_REVIEW_CLI=agy puts all three slots on the stub (duplicate mode: agy
# runs once and codex gets its copy, receipt included; grok is skipped), and the refusal
# below stops the run if a real agy could win the PATH lookup. No network, no model.
#
# Usage: bash tests/test-blueprint-receipt-e2e.sh [plugin-root]
# SC2015: `cmd && ok || bad` is intentional — ok()/bad() always return 0.
# shellcheck disable=SC2015
set -u
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
DIR="$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd)" || exit 1
LOOP="$DIR/skills/blueprint-review/scripts/run-design-review-loop.sh"
INIT="$DIR/skills/blueprint-review/scripts/init-design-review.sh"
PASSN=0; FAILN=0
ok()  { echo "  PASS  $1"; PASSN=$((PASSN + 1)); }
bad() { echo "  FAIL  $1"; FAILN=$((FAILN + 1)); }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }

T="$(mktemp -d)" || exit 1
[[ -n "$T" && -d "$T" ]] || { echo "mktemp -d produced no directory"; exit 1; }
trap 'rm -rf "$T"' EXIT INT TERM
export HOME="$T/home"; mkdir -p "$HOME/.claude" "$T/bin"
for c in jq git python3 perl timeout gtimeout shasum sha256sum; do
  p="$(command -v "$c" 2>/dev/null)" && ln -s "$p" "$T/bin/$c"
done
export PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export BUSDRIVER_REVIEW_CLI=agy BLUEPRINT_COVERAGE_PROVENANCE=0
export BUSDRIVER_PLUGIN_ROOT="$DIR" CLAUDE_PLUGIN_ROOT="$DIR" BUSDRIVER_STATE_DIR=".claude"

# The stub runs under an `env -i` review environment from a guard workspace, so its mode
# and output path are baked into its body. It reports 1.1 so dispatch takes the argv
# rung (`--print "<prompt>"`); >=1.2 would switch to the stream-json rung.
stub_agy() {  # <mode: echo|wrongtail|nohead>
  cat > "$T/bin/agy" <<EOF
#!/bin/bash
[ "\$1" = --version ] && { echo "agy 1.1.0"; exit 0; }
p=""
while [ \$# -gt 0 ]; do case "\$1" in --print) p="\$2"; shift 2;; *) shift;; esac; done
printf '%s' "\$p" > "$T/seen.txt"
h=\$(printf '%s\n' "\$p" | sed -n '1s/^INPUT CANARY (start): \([0-9a-f]\{32\}\) .*/\1/p')
t=\$(printf '%s\n' "\$p" | sed -n '\$s/^INPUT CANARY (end): \([0-9a-f]\{32\}\) .*/\1/p')
case "$1" in
  wrongtail) t=ffffffffffffffffffffffffffffffff ;;
  nohead) h="" ;;
esac
meta="\"input_canary\": \"\$t\""
[ -n "\$h" ] && meta="\"input_canary_head\": \"\$h\", \$meta"
printf '\`\`\`json\n{"status": "FAIL", "reviewer_id": "agy", "issues": [], "metadata": {%s}}\n\`\`\`\n' "\$meta"
EOF
  chmod +x "$T/bin/agy"
}

RD=docs/reviews/plan
# Runs one full round, then the arbiter + --claude-only PASS gate. Leaves the repo at $T/<mode>.
run_case() {  # <mode>
  stub_agy "$1"
  # Never let a real agy take the dispatch: it would send the prompt to a model.
  [[ "$(command -v agy)" == "$T/bin/agy" ]] || { echo "FAIL: agy resolves to $(command -v agy), not the stub"; exit 1; }
  rm -f "$T/seen.txt"
  mkdir -p "$T/$1/.claude"; cd "$T/$1" || exit 1; git init -q
  printf '# Plan\n\nStep 1: do a thing.\n' > plan.md
  bash "$INIT" plan.md 3 >/dev/null 2>&1
  bash "$LOOP" </dev/null >"$T/$1-round.log" 2>&1; ROUND_RC=$?
  local rid hash
  rid=$(jq -r '.metadata.run_id // ""' "$RD/agy.json" 2>/dev/null)
  hash=$( (shasum -a 256 plan.md 2>/dev/null || sha256sum plan.md 2>/dev/null) | cut -d' ' -f1)
  jq -n --arg rid "$rid" --arg h "$hash" \
    '{status:"PASS",reviewer_id:"claude",validation_notes:"fixture",issues:[],
      metadata:{run_id:$rid,spec_hash:$h,iteration:1}}' > "$RD/claude.json"
  bash "$LOOP" --claude-only </dev/null >"$T/$1-gate.log" 2>&1; GATE_RC=$?
  if python3 -I "$DIR/hooks/gate-scripts/lib/marker_ops.py" reviewed plan.md; then STAMP=YES; else STAMP=no; fi
}

r() { jq -r "$1" "$RD/agy-receipt.json" 2>/dev/null; }
seen_head() { sed -n '1s/^INPUT CANARY (start): \([0-9a-f]\{32\}\) .*/\1/p' "$T/seen.txt"; }
seen_tail() { sed -n '$s/^INPUT CANARY (end): \([0-9a-f]\{32\}\) .*/\1/p' "$T/seen.txt"; }

echo "── (A) stub echoes the canaries it received ────────────────"
run_case echo
[[ -s "$T/seen.txt" ]] \
  && ok  "the round dispatched the stub through execute_review's agy arm" \
  || bad "the stub never ran (round rc=$ROUND_RC; see the round log)"
[[ "$ROUND_RC" == 2 ]] \
  && ok  "the round stops for the arbiter (rc=2)" \
  || bad "the round stops for the arbiter — rc=$ROUND_RC"
[[ "$(r .run_id)" == "$(jq -r .metadata.run_id "$RD/agy.json" 2>/dev/null)" && -n "$(r .run_id)" ]] \
  && ok  "receipt run_id is this round's" \
  || bad "receipt run_id is this round's — receipt '$(r .run_id)'"
[[ -n "$(seen_head)" && "$(r .input_canary_head)" == "$(seen_head)" ]] \
  && ok  "receipt head nonce = the canary on the prompt's first line" \
  || bad "receipt head nonce = first-line canary — receipt '$(r .input_canary_head)' prompt '$(seen_head)'"
[[ -n "$(seen_tail)" && "$(r .input_canary)" == "$(seen_tail)" ]] \
  && ok  "receipt tail nonce = the canary on the prompt's last line" \
  || bad "receipt tail nonce = last-line canary — receipt '$(r .input_canary)' prompt '$(seen_tail)'"
_bytes=$(LC_ALL=C wc -c < "$T/seen.txt" | tr -d '[:space:]')
[[ "$(r .prompt_bytes_sent)" == "$_bytes" && "$(r .prompt_bytes_expected)" == "$_bytes" && "$(r .truncated)" == false ]] \
  && ok  "receipt byte count = the bytes the stub received, not truncated" \
  || bad "receipt bytes — sent=$(r .prompt_bytes_sent) expected=$(r .prompt_bytes_expected) received=$_bytes truncated=$(r .truncated)"
[[ "$(jq -r .copied_from "$RD/codex-receipt.json" 2>/dev/null)" == agy \
   && "$(jq -r .input_canary "$RD/codex-receipt.json" 2>/dev/null)" == "$(seen_tail)" ]] \
  && ok  "duplicate mode carries the agy receipt into the codex slot" \
  || bad "duplicate mode carries the agy receipt into the codex slot"
[[ "$GATE_RC" == 0 && "$STAMP" == YES ]] \
  && ok  "the --claude-only gate accepts the receipt and stamps PASS" \
  || bad "the --claude-only gate accepts the receipt — rc=$GATE_RC stamped=$STAMP: $(grep -E 'RECEIPT|COVERAGE' "$T/echo-gate.log")"

for m in wrongtail nohead; do
  echo ""
  echo "── ($m) stub breaks its canary echo ───────────────────────"
  run_case "$m"
  [[ -s "$T/seen.txt" && "$ROUND_RC" == 2 ]] \
    && ok  "$m: the round dispatched the stub and stopped for the arbiter" \
    || bad "$m: the round dispatched the stub — rc=$ROUND_RC"
  [[ "$GATE_RC" != 0 && "$STAMP" == no ]] \
    && ok  "$m: the gate withholds the PASS (rc=$GATE_RC)" \
    || bad "$m: the gate withholds the PASS — rc=$GATE_RC stamped=$STAMP"
  grep -qF 'RECEIPT CHECK FAILED (agy-receipt.json=no_canary' "$T/$m-gate.log" \
    && ok  "$m: the receipt check names the missing echo" \
    || bad "$m: the receipt check names the missing echo — $(grep -E 'RECEIPT|COVERAGE' "$T/$m-gate.log")"
done

echo ""
echo "── Results: $PASSN/$((PASSN + FAILN)) passed ──"
[[ "$FAILN" -eq 0 ]] || exit 1
