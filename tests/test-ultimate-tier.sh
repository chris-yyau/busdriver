#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # grep patterns intentionally hold literal ${...}/backticks; A&&pass||fail is the intended report idiom
# tests/test-ultimate-tier.sh
# Static contract for the "ultimate" tier (Claude Fable via an in-harness Agent
# subagent) — ADR 0011, as amended by ADR 0015 and ADR 0019. Locks in the rename,
# the removal of the zenmux gateway transport, and the two shipping surfaces:
#   (a) NO live code references the dropped ultra-arbiter keys
#       (BLUEPRINT_ARBITER_ULTRA / ultraArbiter) — they live only in immutable history
#       (docs/adr/, CHANGELOG, SKILL.md Version History).
#   (b) the gateway rung is GONE (ADR 0019): its scripts are deleted and no live
#       instruction routes through them; the arbiter chain is fable subagent → opus.
#   (c) skills/council/SKILL.md carries the Mythos Witness contract anchors
#       (rendered-separately, never-a-vote, MYTHOS_FAILED banner) with no gateway fallback.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAIL=1; }

# ── (a) dropped keys absent from LIVE code ────────────────────────────────
# Live code = the shell that actually runs. History prose (docs/adr/, CHANGELOG,
# SKILL.md Version History) legitimately keeps the old names as record and is excluded.
echo "── (a) dropped ultra-arbiter keys gone from live code ──"
LIVE_FILES=(
  "$DIR/scripts/lib/ultimate-config.sh"
  "$DIR/scripts/lib/resolve-cli.sh"
)
for f in "${LIVE_FILES[@]}"; do
  if [[ -f "$f" ]] && grep -qEi 'BLUEPRINT_ARBITER_ULTRA|ultraArbiter|ultra-arbiter-config|ultra-arbiter|ultra arbiter' "$f"; then
    fail "dropped key present in $(basename "$f")"
  else
    pass "no dropped keys in $(basename "$f")"
  fi
done
# blueprint-review SKILL.md BODY (everything before the Version History heading) must be clean.
SKILL_BP="$DIR/skills/blueprint-review/SKILL.md"
BODY="$(awk '/^#+[[:space:]]+Version History/{exit} {print}' "$SKILL_BP")"
if grep -qE 'BLUEPRINT_ARBITER_ULTRA|ultraArbiter|ultra_arbiter_(fable|unavailable)|ultra-arbiter' <<<"$BODY"; then
  fail "dropped ultra-arbiter key present in blueprint-review SKILL.md BODY (must be renamed)"
else
  pass "blueprint-review SKILL.md body uses the ultimate-* names"
fi

# ── (a2) arbiter has NO persistent config opt-in (ADR 0028) ───────────────
# The `.ultimate.surfaces.arbiter` flag was prose-gated only and never fired; ADR 0028
# drops it, leaving the in-band "ultimate arbiter" trigger phrase as the only arbiter path.
# Guard the positive contract AND the absence of the old USER-config granting sentence.
# (The body may still NAME `.ultimate.surfaces.arbiter` as historical record of the drop;
#  what must be gone is any live sentence that GRANTS the arbiter that opt-in.)
echo "── (a2) arbiter config opt-in dropped (ADR 0028) ──"
if grep -qF -- 'no persistent config opt-in' <<<"$BODY"; then
  pass "arbiter body states elevation is trigger-phrase only (no persistent config opt-in)"
else
  fail "arbiter body missing the 'no persistent config opt-in' contract (ADR 0028)"
fi
# shellcheck disable=SC2016  # literal backticks/dots are intentional — matching prose verbatim, no expansion wanted
if grep -qF -- 'top-level `.ultimate.surfaces.arbiter` in USER' <<<"$BODY"; then
  fail "arbiter body still GRANTS the dropped USER-config opt-in (ADR 0028 regression)"
else
  pass "no live USER-config opt-in grant for the arbiter"
fi

# ── (b) gateway rung removed (ADR 0019) ───────────────────────────────────
# Regression guard: reintroducing the gateway must be a deliberate, test-visible
# change, not an accidental resurrection of a credential-bearing transport.
echo "── (b) gateway rung is gone (ADR 0019) ──"
for gone in \
  "scripts/ultimate-dispatch.sh" \
  "skills/blueprint-review/scripts/dispatch-gateway-arbiter.sh" \
  "tests/test-gateway-arbiter-dispatch.sh" \
  "tests/test-gateway-arbiter-claude-json-residual.sh"
do
  [[ ! -e "$DIR/$gone" ]] && pass "deleted: $gone" || fail "gateway artifact still present: $gone"
done

# No LIVE instruction may route through the deleted helpers or the gateway creds.
# (Prose that *explains* the removal is fine; these tokens are the machinery itself.)
COUNCIL_BODY="$(cat "$DIR/skills/council/SKILL.md")"
for tok in 'ultimate-dispatch.sh' 'dispatch-gateway-arbiter.sh' 'BLUEPRINT_ARBITER_GATEWAY'; do
  if grep -qF -- "$tok" <<<"$BODY"; then
    fail "blueprint-review SKILL.md body still routes through '$tok'"
  else
    pass "blueprint-review SKILL.md body free of '$tok'"
  fi
  if grep -qF -- "$tok" <<<"$COUNCIL_BODY"; then
    fail "council SKILL.md still routes through '$tok'"
  else
    pass "council SKILL.md free of '$tok'"
  fi
done

# The deleted escalation section must not come back under its old HEADING. Scope to the
# body: Version History legitimately names the section as historical record of its removal.
if grep -qE '^#+[[:space:]]+Ultimate-Arbiter Escalation' <<<"$BODY"; then
  fail "the headless claude -p escalation section is back in blueprint-review SKILL.md"
else
  pass "no Ultimate-Arbiter Escalation section heading (deleted in ADR 0019)"
fi

# The arbiter chain is exactly: fable subagent → opus (degraded). No third rung.
bp_anchor() { grep -qF -- "$2" "$SKILL_BP" && pass "$1" || fail "$1 (missing: $2)"; }
bp_anchor "arbiter chain is fable subagent → opus degraded" 'fable subagent, opus degraded'
bp_anchor "chain explicitly has no third rung"              'There is no third rung'
bp_anchor "fable pin identity kept for the subagent"        '`fable` ≡ `claude-fable-5`'
# The gateway-namespaced id was the gateway's alone — it must not survive the deletion.
if grep -qF -- 'anthropic/claude-fable-5' <<<"$BODY"; then
  fail "gateway-namespaced model id still in the blueprint-review body"
else
  pass "gateway-namespaced model id dropped from the body"
fi

# ── (c) Mythos Witness contract anchors in council SKILL.md ───────────────
echo "── (c) council Mythos Witness contract ──"
SKILL_C="$DIR/skills/council/SKILL.md"
anchor() { grep -qF -- "$2" "$SKILL_C" && pass "$1" || fail "$1 (missing: $2)"; }
anchor "Mythos Witness has its own Expert Witness section" '## Mythos Witness — Expert Witness'
anchor "Mythos Witness is never a vote"                    'The Mythos Witness is **not** a vote'
anchor "Mythos Witness excluded from the vote tally"       'EXCLUDED from the council vote tally'
anchor "MYTHOS_FAILED banner on failure"                   'MYTHOS_FAILED'
anchor "rendered AFTER UltraOracle, BEFORE the Verdict"    'AFTER the `## UltraOracle — Expert Witness`'
anchor "config gate is ultimate.surfaces.council"          'ultimate.surfaces.council'
anchor "trigger decision variable is declared"             '_forced=0'
# ADR 0019: the never-silent contract survives the gateway deletion. The banner is now
# emitted by the Step 5 RENDER logic (the executor grades the Agent call directly) —
# the Bash rc-branch that used to emit it lived inside the deleted gateway block.
anchor "subagent failure renders a banner, not an omission" 'MYTHOS_FAILED [subagent-failed]'
anchor "empty subagent verdict renders a banner"            'MYTHOS_FAILED [empty verdict]'
anchor "omission is correct ONLY when never attempted"      'MYTHOS_ATTEMPT=0'

# The gateway force plumbing existed only to authorize the deleted helper.
if grep -qF -- 'ULTIMATE_COUNCIL_FORCE' "$SKILL_C"; then
  fail "ULTIMATE_COUNCIL_FORCE plumbing survived the gateway deletion"
else
  pass "ULTIMATE_COUNCIL_FORCE plumbing removed with the gateway block"
fi

# Step 4.6 is now a SINGLE Bash block (the gate pre-check). The gateway-fallback block
# that used to re-declare `_forced=0` independently is gone, so exactly one remains.
_forced_count="$(grep -cF -- '_forced=0' "$SKILL_C")"
if [[ "$_forced_count" -eq 1 ]]; then
  pass "Step 4.6 declares _forced=0 exactly once (single gate block)"
else
  fail "expected exactly 1 _forced=0 (single Step 4.6 gate block), found $_forced_count"
fi

CMD_ULTIMATE="$DIR/commands/ultimate-council.md"
if [[ -f "$CMD_ULTIMATE" ]] && grep -qF -- 'setting `_forced=1` in the Step 4.6 gate pre-check block' "$CMD_ULTIMATE"; then
  pass "ultimate-council command instructs the executor to force _forced=1 in the single gate block"
else
  fail "ultimate-council command missing the single-block _forced=1 instruction"
fi

# ── Mechanism Witness (kimi-k3) authorization boundary (ADR 0027) ────────────
# The k3 witness transmits the council prompt + pasted snippets externally, so its
# ultimate-only gate must be injection-proof and share the Mythos authorization.

# 1. A LITERAL `MECHANISM_WITNESS=0` must exist in the Step 4b preamble — it shadows
#    any repo-injected ambient value (a committed settings.json `env` block, #325).
mw_lit="$(grep -cE '^MECHANISM_WITNESS=0' "$SKILL_C")"
if [[ "$mw_lit" -ge 1 ]]; then
  pass "council Step 4b pins a literal MECHANISM_WITNESS=0 (shadows repo-injected env)"
else
  fail "council SKILL.md missing the literal MECHANISM_WITNESS=0 injection guard"
fi

# 2. The dispatch guard must read that var (default 0) — never dispatch k3 on an
#    unset/0 value, so a plain/ultra council or BUSDRIVER_ULTIMATE=0 run skips it.
anchor "council k3 dispatch is guarded on MECHANISM_WITNESS=1" '[ "${MECHANISM_WITNESS:-0}" = 1 ]'

# 3. Enabling k3 is conditioned on MYTHOS_ATTEMPT=1 (same gate as the fable witness,
#    so BUSDRIVER_ULTIMATE=0 / a disabled surface suppress k3 too) and is a LITERAL FLIP.
anchor "council k3 enable is gated on MYTHOS_ATTEMPT=1" 'change that literal to `MECHANISM_WITNESS=1`'

# 4. The command must condition the flip on MYTHOS_ATTEMPT=1, not force it unconditionally.
if grep -qF -- 'ONLY when the Step 4.6 gate returned `MYTHOS_ATTEMPT=1`' "$CMD_ULTIMATE"; then
  pass "ultimate-council command conditions the k3 flip on MYTHOS_ATTEMPT=1 (respects BUSDRIVER_ULTIMATE=0)"
else
  fail "ultimate-council command forces MECHANISM_WITNESS unconditionally (bypasses the ultimate gate)"
fi

[[ "$FAIL" = 0 ]] && echo "PASS test-ultimate-tier" || { echo "FAIL test-ultimate-tier"; exit 1; }
