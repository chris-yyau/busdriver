# ADR 0020 — UltraOracle transport: attach to a running Chrome, not a launched one

- **Status:** Accepted
- **Date:** 2026-07-18
- **Supersedes (partially):** the `oracle serve --manual-login` remoteHost path from #340 / ADR 0007's Phase-3 notes. `remoteHost` remains supported but is no longer the recommended transport.

## Context

The UltraOracle surface consults ChatGPT Pro through oracle's `--engine browser`. Every
transport we had shipped launches a Chrome that oracle itself configures — `--copy-profile`,
`--browser-cookie-path`, and `oracle serve --manual-login` alike.

On 2026-07-18 the surface was fully unusable. Eleven consecutive live consults failed, and
the failure was reproducible and total, not intermittent:

```
ERROR: Cloudflare challenge detected. Complete the "Just a moment…" check in the open
browser, then rerun.
```

Investigation on the live machine established:

- The challenge is **not** a login problem. Signing in, re-signing in, and clearing the
  challenge by hand all left the next run challenged again.
- It is **not** profile contention. A freshly copied, single-owner profile behaved identically.
- The same profile, same cookies, loaded `chatgpt.com` **cleanly** when Chrome was started
  by hand. The distinguishing variable is how Chrome is launched: oracle's Chrome carries
  automation flags (CDP port, `--disable-features=AutomationControlled`, et al.) that
  Cloudflare fingerprints. A vanilla browser is not challenged.

Oracle already ships the escape: `--browser-attach-running` reuses an ordinary browser
instead of launching one. A direct CLI consult over that path returned a verdict in **38.2s**
on the first attempt.

Two mechanical constraints govern attach mode (oracle 0.15.2):

1. `dist/src/browser/detect.js:105` — discovery walks **only** `~/Library/Application Support`
   on macOS, looking for a `DevToolsActivePort` file. A profile anywhere else is invisible
   however healthy its endpoint is. Our profile lived at `~/.oracle/browser-profile`.
2. Chrome writes `DevToolsActivePort` **only when the debug port is dynamic**
   (`--remote-debugging-port=0`). With an explicit port it writes nothing, and a profile
   copied from elsewhere can carry a stale file advertising a dead port (observed: 57015
   while CDP actually answered on 9222).

The operational failure modes were just as costly as the Cloudflare wall: `oracle serve` died
with its invoking shell, and chose a fresh random port and token on each start, so
`remoteHost`/`remoteToken` in user config went stale on every restart and after every reboot.

## Decision

**Attach mode becomes the recommended UltraOracle transport, with a self-healing preflight.**

1. **`scripts/ultra-oracle-attach-preflight.sh`** — idempotent, sub-second, fail-CLOSED.
   Ensures a vanilla Chrome runs on a discoverable profile, launched with
   `--remote-debugging-port=0` so Chrome records a truthful `DevToolsActivePort`; reads the
   port back; verifies CDP answers; relaunches clean when Chrome is dead or the port file is
   stale. Prints `ok <host>:<port>`.
2. **`ultraOracle.attachRunning: true`** (USER config only, opt-in) selects the path.
   `ultraOracle.attachProfileDir` overrides the default
   `~/Library/Application Support/oracle-attach`; the preflight rejects any path outside
   `~/Library/Application Support` rather than let a consult burn its timeout cap.
3. **Adapter precedence** in `ultra-oracle.sh`: attach outranks `remoteHost`, `cookiePath`,
   and `chromeProfileDir`, which stay mutually exclusive. A failed or unparseable preflight
   returns `error` and never invokes oracle — proceeding would let oracle silently launch its
   own Chrome and walk back into the wall.

Ports are resolved per-run and never pinned: dynamic ports both satisfy constraint (2) and
dodge the port-squatting we hit on 9222 (a stale Chrome from an earlier run held it).

**No launchd agent.** The preflight launches Chrome on demand, so the first consult after a
reboot heals itself. A `KeepAlive` agent would add a failure surface for no coverage the
preflight lacks.

**No preflight-level lock either — Chrome's `SingletonLock` is the concurrency primitive.**
An earlier revision serialized concurrent preflights with a `mkdir` lock. Safely breaking a
*stale* lock requires atomic compare-and-delete, which `mkdir` cannot express, and four
successive review rounds each closed one race while leaving a narrower one: two waiters both
judging an owner dead (the delayed one then deleting the *new* owner's lock), PID recycling
making a dead owner look alive, and the publish gap before the pid file lands. Each guard
made the lock harder to reason about than the browser launch it protected.

Chrome already provides the exclusion we were re-implementing: a second Chrome launched
against the same `user-data-dir` hands off to the first and exits, so concurrent preflights
converge rather than corrupt — the loser's probe loop observes the winner's browser and
returns that port. Verified: five simultaneous preflights return one identical port with one
browser running. Consequently `launch_chrome` deletes stale `DevToolsActivePort` files but
deliberately **never** `Singleton*`, which would destroy that very mechanism.

The residual race — an interleaved kill/launch timing out one probe loop — fails CLOSED with
a diagnostic, becomes a typed `error` in the adapter, and heals on the next consult. That is
strictly better than a subtly-wrong lock, which fails *silently* with two owners.

## Alternatives considered

- **Keep `oracle serve`, fix the port drift.** Rejected: serve's Chrome is the automation
  Chrome, so the Cloudflare wall stands. Pinning the port fixes only the least costly symptom.
- **`--browser-inline-cookies` / exported cookie JSON.** Rejected: seeds a session into a
  browser that is *still* automation-launched, so it is still challenged.
- **`--engine api` with an `OPENAI_API_KEY`.** Genuinely robust — no browser, no Cloudflare,
  no reboot story at all. Rejected because it abandons the ChatGPT Pro subscription for
  metered API billing; using the subscription is the browser engine's entire purpose. This is
  the fallback if the attach path proves flaky in practice.
- **Sign-in probe in the preflight.** Deferred: reading page state needs a CDP WebSocket
  session, and oracle already emits a typed `session not detected` diagnostic that
  `_ultra_oracle_diagnose_hint` surfaces. Add it if a stale login costs real time.

## Consequences

- The surface works, and fails fast when it cannot: a dead Chrome or stale port file is
  healed in ~1.4s instead of surfacing as a 10-minute timeout.
- **Sign-in stays manual.** Nothing automates past Cloudflare plus authentication. The goal is
  a two-second, actionable failure, not an automated login. The profile persists the session
  across reboots, so this should be rare.
- Attach mode reuses a browser **the operator can see and drive**. That profile is dedicated
  to ChatGPT and separate from their main Chrome; the data boundary of ADR 0007 is unchanged —
  UltraOracle still transmits externally, and enablement is still USER-config-only.
- We now depend on two oracle 0.15.2 internals: the discovery root and the port-file behavior.
  Both are asserted by `tests/test-ultra-oracle.sh` at the argv level and documented at the
  call sites; an oracle upgrade that moves either will surface as a preflight failure, which
  is fail-closed rather than silent.
- `remoteHost`/`remoteToken` remain wired and tested for anyone delegating to a remote serve
  on another host — attach mode is local-only by nature.

## Revisit trigger

- Oracle changes attach discovery or `DevToolsActivePort` handling (preflight fails closed → fix there).
- Cloudflare begins challenging attached browsers too → reopen `--engine api`.
- Manual sign-in proves frequent enough to justify the CDP-based login probe.
