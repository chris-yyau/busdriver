# ADR 0063 — Merge ultimate-council into ultra-council

## Status

**Accepted (2026-11-11).** Operator decision, 2026-11-10. Amends the council half of
[ADR 0011](./0011-ultimate-tier-fable-surfaces.md)'s naming split and
[ADR 0007](./0007-ultraoracle-expert-witness-and-ultra-council.md)'s definition of ultra-council.
Does not touch the blueprint-review "ultimate arbiter" (ADR 0025 / ADR 0028).

## Context

Two commands convened the same council with different witness sets: `/ultra-council` forced the
UltraOracle, `/ultimate-council` forced the UltraOracle and the Mythos Witness. In the ADR 0062
transcript sweep the Skill tool invoked `ultimate-council` twice and `ultra-council` never, so the
UltraOracle-only variant had no users, and keeping two names for one deliberation cost a second
command, a second trigger and a naming rule the operator had to remember.

## Decision

1. **`/ultra-council` runs what `/ultimate-council` ran:** the five voices plus both expert
   witnesses, UltraOracle (Step 4.5) and Mythos Witness (Step 4.6). The "ultra council" trigger
   sets `ULTRA_ORACLE_COUNCIL_FORCE=1` and `_forced=1`.
2. **`/ultimate-council` and its trigger phrase are deleted.** There is no alias.
3. **Config names stay.** `ultimate.surfaces.council` (Mythos Witness opt-in),
   `ultraOracle.council.enabled` (UltraOracle opt-in) and `BUSDRIVER_ULTIMATE=0` (Mythos force-off)
   keep their names and meaning; renaming them would break operator configs for no behavior change.
4. **Naming split, council exception.** ADR 0011's `ultra*` = ChatGPT Pro / `ultimate*` = Fable rule
   still holds for every other surface. `ultra-council` is now the one name that convenes both.

## Alternatives

- **Keep both commands.** Rejected: one deliberation, two names, and the cheaper one unused.
- **Keep `/ultimate-council` as the survivor.** Rejected by the operator; "ultra-council" is the
  name in use.
- **Rename the config keys to match.** Rejected: churn in user config with no behavior gain.

## Consequences

- A user who wants the council with only the UltraOracle sets `ultraOracle.council.enabled` and runs
  a plain council; there is no command for that subset.
- `tests/test-ultimate-tier.sh` now pins the `_forced=1` instruction in `commands/ultra-council.md`.

## Revisit trigger

A need to run the UltraOracle without the Mythos Witness on demand (for example, Fable becomes
unavailable in-account for long stretches).
