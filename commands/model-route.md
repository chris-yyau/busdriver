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
- `codex`: outside this policy — review/gate routes unchanged. This command does not
  claim Codex is review/gate-only today; the Pi replacement owns its implementation rows.

A `fable` route must name a concrete read-only dispatch form: a frontmatter-pinned agent
(whose `tools:` is enforced by `scripts/ci/validate-model-routes.js`) or an explicit read-only `--tools` list (which limits which tools *exist* in the session; `--allowedTools` alone only auto-approves and leaves Bash/Write/Edit available). A bare `Agent(model="fable")` inherits full tooling and is never the recommendation.

The three live Fable dispatch sites (blueprint-review arbiter, council Mythos Witness —
which `/ultimate-council` forces rather than adding a fourth site — and the orchestrator
advisor fallback) are grandfathered exceptions that predate this policy and are outside
this command's domain.

## Required Output

- the route (`opus`, `fable`, or `codex`)
- why the task qualifies for it
- for a `fable` route: confirmation of **all three** conjuncts above, plus the read-only
  dispatch form — and it must be a confining one (`--tools`), not merely an
  auto-approving `--allowedTools`

There is no fallback model and no budget flag: under this policy there is nothing to fall
back to, and `effort:` is the cost dial.

## Arguments

$ARGUMENTS:
- `[task-description]` optional free-text
