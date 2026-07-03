---
description: Convene the 5-voice council plus BOTH expert witnesses — UltraOracle (GPT-5.5 Pro) AND the Mythos Witness (Claude Fable via the zenmux gateway) — each rendered separately, never a vote.
---

# Ultimate-Council

Invoke the `council` skill in **ultimate-council** mode: run the normal 5-voice council AND force BOTH expert witnesses.

- Force the UltraOracle by setting `ULTRA_ORACLE_COUNCIL_FORCE=1` (a plain, non-exported assignment) at the top of the council's single Step 4 dispatch Bash block, `unset` at the end (see Step 4.5).
- Force the Mythos Witness by setting `ULTIMATE_COUNCIL_FORCE=1` (a plain, non-exported assignment) in the SAME Step 4 block, `unset ULTIMATE_COUNCIL_FORCE` at the end (see Step 4.6).

For the *initial* assignment above: never subshell, never `export`, never a `VAR=1 cmd` prefix (a trigger phrase alone sets no env var, and a one-command prefix would not persist to the later gate checks in the same block). Only the Mythos Witness routes through the gateway (metered API billing, gateway creds from `BLUEPRINT_ARBITER_GATEWAY_*`), dispatching via `scripts/ultimate-dispatch.sh` (role `mythos-witness`, pinned `claude-fable-5`), fail-closed; the UltraOracle does NOT use gateway credentials — it dispatches via the separate `ultra_oracle_consult` adapter (the `oracle` CLI's ChatGPT Pro browser engine, see `skills/council/SKILL.md` Step 4.5). Handing the already-set value to the Mythos Witness's child script IS a narrow, single-command `VAR=1 bash ultimate-dispatch.sh ...` prefix (see `skills/council/SKILL.md` Step 4.6) — that's a distinct, intentional use (scoping the non-exported var to one child process), not a violation of the rule above.

Render each witness in its OWN separate section — `## UltraOracle — Expert Witness [ORACLE_SUMMARY_REVIEW]` then `## Mythos Witness — Expert Witness` — AFTER the five voices and BEFORE the Verdict. Both are EXCLUDED from the vote tally; their claims are unverified-until-checked (grep/Read/run). On timeout/empty/creds-missing render a loud `ORACLE_FAILED` / `MYTHOS_FAILED` banner, never a silent omission.

Enablement is user-config only (`~/.claude/busdriver.json` → `ultimate.surfaces.council` for the Mythos Witness, `ultraOracle.council.enabled` for the UltraOracle); the `*_FORCE=1` vars are set only for an interactive ultimate-council request, never from repo/project config. See `skills/council/SKILL.md` Steps 4.5 and 4.6.

`BUSDRIVER_ULTIMATE=0` is a global force-off that outranks the per-run `ULTIMATE_COUNCIL_FORCE=1` escape hatch — if the operator has it set in their environment, forcing the Mythos Witness via an ultimate-council request will still be skipped (it has no effect on `ULTRA_ORACLE_COUNCIL_FORCE`/the UltraOracle, which has no equivalent global force-off).
