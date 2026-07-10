---
description: Convene the 5-voice council plus BOTH expert witnesses — UltraOracle (ChatGPT Pro) AND the Mythos Witness (Claude Fable, subagent-first) — each rendered separately, never a vote.
---

# Ultimate-Council

Invoke the `council` skill in **ultimate-council** mode: run the normal 5-voice council AND force BOTH expert witnesses.

- Force the UltraOracle by setting `ULTRA_ORACLE_COUNCIL_FORCE=1` (a plain, non-exported assignment) at the top of the council's single Step 4 dispatch Bash block, `unset` at the end (see Step 4.5).
- Force the Mythos Witness by setting `_forced=1` in BOTH the Step 4.6 gate pre-check block AND the gateway-fallback block (they are separate Bash calls — shell state does not carry over). The gate then dispatches an `Agent(model="fable")` Mythos Witness — in-harness, in-account, no gateway creds — as the primary; only if that subagent fails does the gateway fallback run (see Step 4.6).

For the UltraOracle's `ULTRA_ORACLE_COUNCIL_FORCE=1`: never subshell, never `export`, never a `VAR=1 cmd` prefix (a trigger phrase alone sets no env var, and a one-command prefix would not persist to the later gate checks in the same block). The UltraOracle does NOT use gateway credentials — it dispatches via the separate `ultra_oracle_consult` adapter (the `oracle` CLI's ChatGPT Pro browser engine, see `skills/council/SKILL.md` Step 4.5). The Mythos Witness **primary is a fable subagent** (no gateway, no creds); ONLY its fallback routes through the gateway (metered API billing, creds from `BLUEPRINT_ARBITER_GATEWAY_*`), dispatching via `scripts/ultimate-dispatch.sh` (role `mythos-witness`, pinned `claude-fable-5`), fail-closed — and there `ULTIMATE_COUNCIL_FORCE="$_forced"` is passed as a narrow single-command prefix to scope the value to that one child process (see `skills/council/SKILL.md` Step 4.6).

Render each witness in its OWN separate section — `## UltraOracle — Expert Witness [ORACLE_SUMMARY_REVIEW]` then `## Mythos Witness — Expert Witness` — AFTER the five voices and BEFORE the Verdict. Both are EXCLUDED from the vote tally; their claims are unverified-until-checked (grep/Read/run). On timeout/empty/creds-missing render a loud `ORACLE_FAILED` / `MYTHOS_FAILED` banner, never a silent omission.

Enablement is user-config only (`~/.claude/busdriver.json` → `ultimate.surfaces.council` for the Mythos Witness, `ultraOracle.council.enabled` for the UltraOracle); the `*_FORCE=1` vars are set only for an interactive ultimate-council request, never from repo/project config. See `skills/council/SKILL.md` Steps 4.5 and 4.6.

`BUSDRIVER_ULTIMATE=0` is a global force-off that outranks the per-run `_forced=1` escape hatch — the Step 4.6 gate pre-check tests `BUSDRIVER_ULTIMATE != 0` first, so if the operator has it set in their environment, forcing the Mythos Witness via an ultimate-council request will still be skipped (it has no effect on `ULTRA_ORACLE_COUNCIL_FORCE`/the UltraOracle, which has no equivalent global force-off).
