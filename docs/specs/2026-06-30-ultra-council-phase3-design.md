# ultra-council — ADR 0007 Phase 3 design

**Date:** 2026-06-30
**ADR:** [docs/adr/0007-ultraoracle-expert-witness-and-ultra-council.md](../../adr/0007-ultraoracle-expert-witness-and-ultra-council.md) — Phase 3
**Status:** approved, pending implementation plan

## Problem

ADR 0007 Phase 3 calls for a direct `ultra-council` escalation: normal council
voices **plus** an UltraOracle expert-witness escalation that is **rendered
separately, not as a 6th vote**.

The mechanism already exists. `skills/council/SKILL.md` Step 4.5 dispatches an
optional UltraOracle voice via the shared `ultra_oracle_consult` adapter
(user-config-only enablement, `ULTRA_ORACLE_COUNCIL_FORCE=1` for explicit
requests, loud `ORACLE_FAILED` on failure). **The bug:** its synthesis folds the
verdict in "as the ultra-oracle voice in synthesis" — the vote-#6 antipattern ADR
settling-check #1 explicitly forbids ("If Oracle appears as vote #6, the design
failed").

Phase 3 is therefore a **rendering + trigger correction**, not a new subsystem.

## Decision

`ultra-council` = council (5 voices, unchanged) + UltraOracle rendered as a
**separate, labeled Expert Witness** kept out of the vote tally. Fixed in place in
council; no separate skill body.

## Changes

### 1. `skills/council/SKILL.md` — Step 4.5 rendering rewrite (the substance)
- Keep the existing background oracle dispatch (concurrency with the other voices
  is free — oracle is minutes, voices are seconds).
- **Success:** render a distinct `## UltraOracle — Expert Witness
  [ORACLE_SUMMARY_REVIEW]` section, **excluded from the vote tally / consensus
  count**. Council remains a 5-voice deliberation; Oracle sits beside it.
- **Label:** statically `ORACLE_SUMMARY_REVIEW`. Council sends only the question
  (no evidence pack), so by the label contract it is a summary review (satisfies
  settling-check #2). Repo-grounding stays the standalone `ultraoracle` skill's job.
- **Failure / empty verdict:** keep the existing loud `WARNING: ORACLE_FAILED [status]`
  banner (settling-check #6). Never silently omit.
- **Synthesis contract:** add an explicit line — Oracle is an expert witness,
  advisory only; it must NOT flip a hard recommendation without independent local
  evidence (grep / Read / run).

### 2. `skills/council/SKILL.md` — trigger + frontmatter
- Add `ultra-council` / `ultra council` to the skill `description` so the phrase
  routes to council.
- One-liner in the body: an explicit "ultra-council" request **forces** the
  escalation for that run (`ULTRA_ORACLE_COUNCIL_FORCE=1`, already honored by the
  Step 4.5 wiring).
- **Security boundary preserved, unchanged:** enablement stays user-config-only
  (`~/.claude/busdriver.json` → `ultraOracle.council.enabled`). Repo/project config
  can never enable transmission — the existing `ultra_oracle_surface_enabled` gate
  is not modified.

### 3. `commands/ultra-council.md` — thin shim
Mirrors `commands/ultraoracle.md`. One paragraph: invoke council in ultra-council
mode — forces the UltraOracle Expert Witness escalation; user-config-only
enablement; points at `skills/council/SKILL.md`.

### 4. `tests/test-ultra-council.sh` — one gate test
Grep-based regression guard on `skills/council/SKILL.md`:
- (a) asserts the labeled separate Expert Witness section is present
  (`Expert Witness` + `ORACLE_SUMMARY_REVIEW`);
- (b) asserts the vote-#6 phrasing is **absent** ("as the ultra-oracle voice in
  synthesis");
- (c) asserts the `ORACLE_FAILED` banner survives.
Follows the existing `tests/test-*.sh` pattern; shellcheck-clean.

## Out of scope (YAGNI)
- No evidence-pack / repo-mode in council — use the `ultraoracle` skill for
  repo-grounded consults.
- No two-round retrieval loop (ADR Phase 5).
- No blueprint-review / arbiter wiring (ADR Phase 4).
- No separate `ultra-council` skill directory.

## Acceptance (ADR Phase 3 + settling checks)
- [ ] Normal council remains lightweight by default (no oracle unless forced/enabled).
- [ ] `ultra-council` forces/attempts Oracle.
- [ ] Oracle rendered as a separate Expert Witness, **not** a 6th vote (settling-check #1).
- [ ] A summary-only consult is labeled `ORACLE_SUMMARY_REVIEW` (settling-check #2).
- [ ] Oracle timeout/empty renders `ORACLE_FAILED` loudly (settling-check #6).
- [ ] `tests/test-ultra-council.sh` passes; shellcheck clean.

## Verification
- `bash tests/test-ultra-council.sh` (the new gate test).
- Existing `tests/test-ultra-oracle.sh` still passes (adapter untouched).
- Live end-to-end dogfood (forced `ultra-council` run hitting GPT-5.5 Pro) is an
  outward, billed action — run only on explicit operator authorization. Phase 1
  already proved the live adapter path.
