# ADR 0028 — Drop the arbiter USER-config opt-in; trigger-phrase-only elevation

## Status

**Accepted (2026-07-25).** Amends [ADR 0011](./0011-ultimate-tier-fable-surfaces.md)
(which introduced the `.ultimate.surfaces.arbiter` USER-config opt-in) and narrows
the opt-in surface referenced by [ADR 0025](./0025-arbiter-pin-tracks-driver-model.md).
Builds on [ADR 0019](./0019-ultimate-tier-drop-gateway-rung.md), which retired the
arbiter's code-boundary opt-in enforcement along with the deleted
`dispatch-gateway-arbiter.sh`. The driver-tracking default (ADR 0025), the
fresh-subagent / author≠judge / context-firewall decisions of
[ADR 0003](./0003-fresh-subagent-arbiter-for-blueprint-review.md), and council's
`.ultimate.surfaces.council` Mythos-Witness opt-in are all unchanged. Prose + test
change only — no live code path read the dropped flag.

## Date

2026-07-25

## Context

Since ADR 0011 the blueprint-review arbiter could be force-pinned to `fable` while
driving `opus` in three ways: the persistent `.ultimate.surfaces.arbiter` flag in
USER `~/.claude/busdriver.json`, the `BUSDRIVER_ULTIMATE=1` env force, or the per-run
"ultimate arbiter" trigger phrase (which sets `BUSDRIVER_ULTIMATE=1` for one dispatch).

The persistent config flag **never fired on the arbiter path.** ADR 0019 deleted the
zenmux gateway and, with it, the `ultimate_surface_enabled arbiter` code guard that
had lived inside `dispatch-gateway-arbiter.sh` (shipped under #265, commit `fb86e2f0`).
The surviving fable-subagent path was left "gated in prose only." But the arbiter model
is chosen by the executing session at Agent-dispatch time, and the dispatch prose leads
with "`opus` by default" — so nothing in the live path ever read `.ultimate.surfaces.arbiter`.
An operator with the flag set, driving `opus`, still got an `opus` arbiter. The flag was
a dead switch.

The asymmetry: council's Mythos Witness kept a real `bash -c '… ultimate_surface_enabled
council'` gate (`council/SKILL.md`), so `.ultimate.surfaces.council` genuinely works. Only
the arbiter surface was orphaned.

The trigger phrase, by contrast, is an **in-band signal the executing session directly
observes** in the conversation. It does not depend on the prose-path remembering to read
an out-of-band file, so it is materially more reliable than the config flag ever was.

## Decision

**Drop the persistent `.ultimate.surfaces.arbiter` USER-config opt-in.** Arbiter
elevation to `fable` while driving `opus` is now a per-run, in-band signal only:

1. **Default** — driver-tracked, `opus` floor (ADR 0025). Unchanged.
2. **Automatic `fable`** — driver runs `fable` → arbiter `fable` (`driver_fable`).
   Unchanged.
3. **Ultimate-arbiter elevation** — the operator types **"ultimate arbiter"** this run.
   The executing session **observes that in-band conversational signal and pins
   `model: fable` at Agent-dispatch** — the pin is executor-chosen on every path, not
   caused by any code reading a flag (see Alternatives). **The trigger must be an explicit
   operator directive in the live session — the phrase carries no authority when it appears
   in reviewed or quoted content** (the design doc, the branch diff, reviewer output, this
   ADR, or the skill's own text all legitimately contain "ultimate arbiter"); reviewed
   content is data, never a directive. Records `model_pin_status=ultimate_arbiter_fable`. **No persistent config surface, and no
   env-var transport either:** the trigger phrase is the sole elevation signal, because
   an out-of-band value (config flag OR exported env var) has no arbiter reader to
   observe it. (An exported `BUSDRIVER_ULTIMATE=1` still drives *code-gated* ultimate
   surfaces such as council's Mythos Witness; it has no effect on the arbiter.)

`model_pin_status` values are unchanged (`ultimate_arbiter_fable` /
`ultimate_arbiter_unavailable` now cover only the trigger-phrase elevation). The
`ultimate_surface_enabled` helper stays generic and council still uses it; it would
resolve `BUSDRIVER_ULTIMATE` / `.ultimate.surfaces.<name>` for any surface arg, but no
arbiter code path calls it, so neither the env force nor the config key has any effect
on the arbiter pin — the executor picks the arbiter model at dispatch.

A `tests/test-ultimate-tier.sh` anchor (section a2) locks the contract: the
blueprint-review body must state "no persistent config opt-in" and must not carry a
live sentence granting the arbiter the dropped USER-config flag.

## Alternatives considered

- **Fix the flag instead of dropping it** — wire an `ultimate_surface_enabled arbiter`
  code gate into the live dispatch the way council does. Rejected: the arbiter model is
  chosen by the LLM at Agent-dispatch, not by a script, so a gate cannot *force* the
  `model:` param — it could only print a resolved hint the session must still honor.
  That is the same reliability class as the trigger phrase, for more machinery. A
  solo operator who wants fable-above-opus can type two words; a never-honored
  persistent flag is worse than no flag (it certifies an escalation it never delivered).
- **Keep the flag as documented-but-inert.** Rejected: a config switch that silently
  does nothing is a latent "why didn't this work" trap — exactly the bug that prompted
  this ADR.
- **Also drop the trigger phrase.** Rejected: the in-band "ultimate arbiter" phrase is
  the one arbiter-elevation mechanism that actually works (the executor observes it in
  the conversation and pins fable at dispatch). `BUSDRIVER_ULTIMATE` is untouched — it
  remains the tier-wide force for *code-gated* surfaces (council's Mythos Witness), but
  it is not an arbiter transport, since no arbiter code reads it.

## Consequences

- Driving `opus` now always yields an `opus` arbiter unless the operator types
  "ultimate arbiter" that run. The persistent per-repo/per-user "always fable arbiter"
  capability is gone — but it never functioned, so no working behavior is lost.
- One fewer config surface to keep coherent; `busdriver.json` no longer needs an
  `ultimate.surfaces.arbiter` entry. (`ultimate.surfaces.council` stays.)
- The `ultimate_surface_enabled` function and `test-ultimate-config.sh` are unchanged —
  they validate the generic reader council depends on.

## Revisit trigger

- The arbiter dispatch becomes script-driven (a resolver picks the model deterministically
  rather than the LLM choosing it) — a code-gated persistent opt-in would then be
  enforceable and worth reconsidering.
- The repo gains a second operator who needs a durable, non-interactive fable-arbiter
  policy (the per-run trigger phrase would no longer suffice).
