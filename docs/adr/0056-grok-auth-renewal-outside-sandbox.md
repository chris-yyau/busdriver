# ADR 0056 — grok's login is checked and renewed outside the review sandbox

## Status

**Accepted (2026-10-14).** Issue #882. Operator approved the approach in-session.

## Context

The `busdriver-review` sandbox profile denies `**/.grok`, so grok running inside it cannot
take `~/.grok/auth.json.lock`, and so cannot renew its access token
(`auth lock: failed to open …/auth.json.lock: Operation not permitted`, 13 times on
2026-10-13). grok's access token lives 6 hours and grok renews it only once it has
expired (`oidc refresh enter reason=PreRequest is_expired:true`). A review that starts
with an expired token, or outlives it, gets 401s until the dispatch timeout (1200s for
blueprint-review) and leaves no review JSON.

On the maintainer's Mac it mostly worked by coincidence: an unrelated unsandboxed grok
process (`Grok Bot.app`) ticks every 5 minutes and renewed the token at the moment it
expired (00:53:56, 06:53:56, 12:53:56 UTC on 2026-10-14). Without it, nothing renews.

grok has no non-interactive "renew now": `grok login` is `--oauth` / `--device-auth` only,
and a renewal attempt on a still-valid token leaves `expires_at` unchanged (measured).

## Decision

`grok_auth_ready <budget-seconds>` (`scripts/lib/resolve-cli.sh`, child
`scripts/lib/grok-auth-ready.sh`) runs after `grok_sandbox_preflight` at both grok
dispatch sites, outside the sandbox, with the home and PATH the preflight verified:

1. Read the earliest `expires_at` in `~/.grok/auth.json`. Nothing read from the file is
   printed.
2. Already expired: run `grok models` once, unsandboxed, from an empty temp directory,
   with no prompt, the vendor hooks off and a limit of min(15s, budget), so grok's own login code renews
   the token. Then read it again.
3. Pass only when the token outlives now + budget + 60s. Otherwise refuse at once with
   `WHY=auth` (no usable login: run `grok login`) or `WHY=auth-expiring` (valid now,
   expires mid-run: retry after it expires), through the existing refusal branch and
   `grok_preflight_hint`.

The sandbox profile is unchanged.

## Alternatives

- **Let the sandbox write `auth.json` and its lock.** Renews mid-run, but the grok that
  reads untrusted content could then rewrite the operator's credentials. Rejected: #882
  says not to weaken the sandbox into a general write of `~/.grok`.
- **Refuse on expiry with no renewal step.** Simpler, but every dispatch after a 6-hour
  gap would refuse until the operator ran grok by hand.

## Consequences

- One unsandboxed grok run per expiry. It carries no repo content and runs in an empty
  directory. It is the same binary the preflight already verified.
- The renewal is not counted against the caller's budget, so a dispatch with an expired
  token can run up to min(15s, budget) past its requested limit. The deadline check is
  taken after the renewal, so the review itself is still covered.
- In the last `budget + 60s` of each 6-hour token (about 21 minutes for blueprint-review),
  grok refuses fast instead of timing out. Coverage for that run degrades as for any
  refused voice.
- **Unverified:** that `grok models` renews an *expired* token. The logs show grok renews
  on any request once the token has expired, and `grok models` goes through the same
  silent refresh, but the expired case was not reproduced here (the live token was always
  fresh). If it does not renew, the re-read still refuses with `WHY=auth`, which is
  #882's fail-closed outcome.
- `_grok_available` (route-time availability) does not run the check; it has no budget.
- A `dispatch.sh` paired with an older `resolve-cli.sh` keeps today's behaviour.

## Revisit trigger

grok gains a non-interactive force-refresh, or its sandbox can grant access to the auth
lock alone. Either would allow renewing mid-run without the refusal window.
