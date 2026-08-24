---
description: State the required model route for a task under the Opus-only Claude work policy.
---

# Model Route Command

State the required model route for a task. This is a policy lookup, not a cost-tier
recommendation — see `docs/adr/0046-opus-only-claude-work-routes.md`.

## Usage

`/model-route [task-description]`

## Routing Policy

- `opus`: **all** Claude work. There is no cheaper Claude tier to route to.
- `fable`: **only** when all three hold — the task is plan/spec/advisory, it produces no
  product-code mutation, and it needs no write tools.
- `codex`: unchanged, review/gate only.

A `fable` route must name a concrete read-only dispatch form: a frontmatter-pinned agent
(whose `tools:` is enforced by `scripts/ci/validate-model-routes.js`) or an explicit
read-only `allowedTools` list. A bare `Agent(model="fable")` inherits full tooling and is
never the recommendation.

The four live Fable dispatches (blueprint-review arbiter, council Mythos Witness,
orchestrator advisor fallback, ultimate-council) are grandfathered exceptions that
predate this policy and are outside this command's domain.

## Required Output

- the route (`opus`, `fable`, or `codex`)
- why the task qualifies for it
- for a `fable` route: confirmation of **all three** conjuncts above, plus the read-only
  dispatch form

There is no fallback model and no budget flag: under this policy there is nothing to fall
back to, and `effort:` is the cost dial.

## Arguments

$ARGUMENTS:
- `[task-description]` optional free-text
