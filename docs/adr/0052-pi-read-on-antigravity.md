# ADR 0052 — pi-read on Antigravity: access-token-only OAuth projection, pi-side refresh; pi-read is the default read lane

**Status:** Accepted (2026-10-05).
**Supersedes:** ADR 0040's "agy-read is the default read lane".
**Amends:**
- ADR 0034 (pi in-tree read lane): OAuth projection and the narrowed real-HOME test.
- ADR 0042 (pi version pin): an extension pin with the same ritual.

## Context

The operator wants one swappable read/worker layer. busdriver talks to pi, and changing vendor is a
change to `.pi_read.model`. agy stays only for the reviewer slots and `agy-prose`. The chosen
provider is `antigravity`, which comes from the `pi-antigravity` extension and uses an OAuth
credential. Until now the pi jail projected static API keys only. An OAuth token refreshed inside
the jail would be discarded, and for a provider that rotates refresh tokens that invalidates the
real credential.

pi-ai refreshes an OAuth credential whenever `now + 300s >= expires`. It saves the result under its
own file lock before making the model call.

## Decision

1. **Access-token-only projection.** An allowlisted OAuth provider (`OAUTH_ACCESS_ONLY`, today only
   `antigravity`) is projected into the jail *without* `refresh`. The run is admitted only when
   at least 390s are left. It is capped at `remaining - 330s`, and that cap is re-based on the time
   spent before launch. Projection re-checks the token it actually writes against `cap + 310s`, so
   a store that changed between the two reads fails closed. If the cap runs out (the host slept),
   the run refuses inside the dispatch subshell, so the normal teardown still runs. As a result,
   pi never reaches its refresh window inside the jail, and there is no refresh token there to
   lose.
2. **pi refreshes, busdriver does not.** If the stored token is inside the 300s window, pi itself
   refreshes it before any repository content is read. This happens in one run with the
   operator's real HOME:
   - `cd /` and a constant prompt
   - `--no-tools`, `--no-context-files`, `--no-approve`, `--no-session`
   - `--offline`, so the run installs no packages
   - only this extension loaded, with its extra tools off

   The run gets a 90s timeout and needs at least 150s of `--timeout` budget. With less, the lane
   refuses and says that budget is the reason. busdriver never writes the credential store and
   never copies a refresh token.
3. **Extension loading and pin.**
   - The extension loads with `-e` from a fixed path under the password-DB home: `--no-extensions`
     disables discovery, but an explicit `-e` still loads.
   - It runs with `ANTIGRAVITY_NO_EXTRA_TOOLS=1`, and `--tools read` already restricts extension
     tools.
   - It is pinned by `BUSDRIVER_PI_ANTIGRAVITY_PROBED_VERSION`, with the same ritual as pi's own pin:
     bump the pin first, then run the live test. A version mismatch, an unreadable version and a
     missing extension each give a distinct refusal.
   - The live test certifies this pin only when `.pi_read.model` names `antigravity`. With an
     extension installed and some other provider configured, it fails.
   - pi 1.0.1 is the probed pi version.
4. **pi-read is the default read lane.** agy-read is deprecated, and a follow-up PR withdraws it.

## The narrowed real-HOME test

`tests/test-pi-dispatch-arm.sh` used to refuse any `env -i HOME="$_pi_home"` pi child anywhere in
the arm. It now refuses one anywhere except `_pi_oauth_refresh_run`, and it pins that function's
guarantees: `cd /`, the constant prompt, `--no-tools`, `--offline`, no context files, no
`PROMPT_FILE`, and no shadowable `return`, `true` or `:`.

That run's only inputs are a constant string and the operator's own config. Nothing from the
checkout reaches it, so there is nothing to inject. This is a deliberate loosening of a gate test,
recorded here so it is not mistaken for drift.

## Security posture, stated precisely

Access-token-only projection removes the refresh token from what pi is handed in the jail, and it
makes a refresh inside the jail impossible. It does **not** confine reads. pi's read tool accepts
absolute paths, so the real `auth.json`, refresh token included, stays reachable by a determined
injection. That is ADR 0034's residual, and it is unchanged.

## Accepted residuals

- **pi's save is not atomic.** pi writes `auth.json` in place with `writeFileSync`. Its file lock
  serialises writers but does not make the write atomic. A kill that lands mid-write would empty
  the store, and recovery is `/login` for each provider. The refresh run's 90s cap covers
  start-up, pi's own 15s refresh timeout and the one-word answer, so a timeout kill lands after
  the save in practice. A kill from outside busdriver can still hit the window.
- **One refusal window per token lifetime.** With 300–390s left, pi-read refuses and says when to
  retry. That is at most about 90s per token lifetime.
- **Ban risk.** pi-antigravity uses Google's Antigravity desktop OAuth client from a third-party
  tool, a pattern Google has suspended accounts for. The operator accepts this risk. Use a Google
  account separate from the agy reviewer account, so a ban cannot take the reviewers down.

## Evidence (2026-10-05, operator Mac, pi 1.0.1, pi-antigravity 0.9.0)

- `BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh` gave "170 passed, 0 failed, 0 skipped",
  covering live write denial and the extension path.
- The stored token had expired (-4484s) before that run. The real-HOME refresh run brought it to
  +3284s, the entry kept every field, and no jail was left behind.
- End to end, `--cli pi-read` answered a `file:line` question correctly in 167s. The latency is
  recorded, not benchmarked: the operator chose not to measure speed.

## Alternatives

- **busdriver-side refresh in a throwaway HOME, plus write-back.** This was design-review round 2.
  It lost a rotated token on failure paths, left a refresh token on disk on a signal, raced pi's
  lock, and added a credential writer to the dispatcher. Rejected.
- **Refresh only after expiry.** pi refreshes inside its 300s window, so a token admitted near
  expiry would be refreshed in the jail. Rejected (design-review round 1).
- **pi-antigravity-bridge**, which drives the official agy binary. It is ToS-clean, but agy's native
  tools bypass pi's `--tools read`, and it needs `~/.gemini` in the jail. Rejected.
- **An API-key provider for pi-read.** That works today, but it is not the operator's choice.

## Consequences

- Read content goes to Google through the Antigravity API. The trust rule is unchanged: gate on who
  wrote the content, and on what is reachable from the prompt.
- Adding another OAuth provider needs four things: its allowlist entry, an extension-path case, a
  version pin, and a live refresh-path check.
- On a fresh host:
  1. `pi install npm:pi-antigravity@0.9.0`
  2. `/login antigravity` (on a remote host, use the paste-the-callback flow)
  3. set `.pi_read.model`

## Revisit trigger

Revisit if any of these happens:
- Google ships an official API-key or pi-native path for these models.
- An account is banned.
- pi stops honouring `-e` under `--no-extensions`.
- pi-ai changes its 300s refresh threshold.
- pi makes its `auth.json` save atomic, which would remove the first residual.
