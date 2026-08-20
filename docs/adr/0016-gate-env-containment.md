# ADR 0016 — Sanitized-environment containment for review gates

- **Status:** Accepted
- **Date:** 2026-07-11
- **Issue:** #325
- **Supersedes / relates:** ADR 0012 (advisory-downgrade opt-in — same "location beats
  content", operator-owned-file-over-env reasoning that this ADR generalizes)

## Context

Claude Code merges a committed `.claude/settings.json` `env` block into the session
process environment. `settings.json` is a **committable** file, so a PR author —
including a forker who opens a PR — controls its contents, and every bash review gate
inherits those variables when its PreToolUse/PostToolUse hook fires. That makes the
process environment a PR-controllable injection channel into the gates that are
supposed to guard the PR. Verified levers on `main` before this change:

| Lever | Effect |
|-------|--------|
| `SKIP_LITMUS` / `SKIP_PR_GRIND` / `SKIP_DESIGN_REVIEW` | direct gate bypass (`… && exit 0`) |
| `BASH_ENV` / `ENV` / exported functions (`BASH_FUNC_*`) | arbitrary code runs **before** a gate's first line (RCE) |
| `PATH` | prepend a repo-local dir to shim `git` / `gh` / `jq` / `python3` |
| `GIT_*` (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_CONFIG_*`, …) | redirect the git resolution gates rely on |
| `BUSDRIVER_PLUGIN_ROOT` | repoint plugin root → gate scripts `source` attacker code (RCE) |
| `BUSDRIVER_STATE_DIR` | point marker/skip-file lookup at a dir where a `skip-*.local` **can** be committed (gitignore only covers `.claude/*.local`) |
| `LITMUS_PR_BASE` / `LITMUS_PR_BACKSTOP_MAX_AGE` | move the review diff base / inflate the backstop-age window to manufacture a bypass |

This is **systemic**, not a bug in any one gate: `BASH_ENV`/`PATH`/exported functions
compromise a script *before* its own logic runs, so a per-script scrub cannot be
trusted. Containment has to happen **above** the scripts.

Mitigating context (why this was filed as a design record, not an emergency): the repo
is **solo-operator**, and the threat requires the maintainer to run a session *on an
attacker's PR branch*. Real, but bounded. The operator opted into full containment
regardless.

## Decision

Run every enforcement/state gate under a **sanitized environment**, established at the
hook entry point (the one place above the scripts), not inside the scripts.

`hooks.json` invokes each gate as:

```
/usr/bin/env -i PATH=/usr/bin:/bin HOME="$HOME" CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}" \
  bash "${CLAUDE_PLUGIN_ROOT}/hooks/gate-scripts/lib/sanitized-gate.sh" <gate>.sh
```

- `/usr/bin/env` is **absolute** → the outer shell does no `PATH` lookup for it, so a
  shimmed `env` can't win.
- `env -i` wipes the **entire** environment — `BASH_ENV`/`ENV`/exported functions, the
  poisoned `PATH`, `GIT_*`, `SKIP_*`, `BUSDRIVER_*`, `LITMUS_PR_*`, and any unknown
  future lever — in one move. Only a minimal allowlist is re-added.
- `lib/sanitized-gate.sh` rebuilds a **trusted `PATH`** from a fixed list of absolute
  dirs that exist (never the caller's `PATH`), **re-derives `HOME` from the password
  database** (`getent`/`dscl` — the real operator's home, not the PR-influenced env),
  **neutralizes global + system git config** (`GIT_CONFIG_GLOBAL=/dev/null`,
  `GIT_CONFIG_SYSTEM=/dev/null`), sets **`PYTHONNOUSERSITE=1`**, then execs the named gate
  with stdin (the PreToolUse JSON) passed through untouched.

Additionally, the named `SKIP_LITMUS` / `SKIP_PR_GRIND` / `SKIP_DESIGN_REVIEW` env
escape hatches are **removed** from the gate scripts. They are stripped by `env -i`
anyway, and were the cleanest injectable lever. The **operator-created `.local` skip
file** remains the one sanctioned escape hatch — consistent with ADR 0012's
operator-owned-file principle.

But `.gitignore` prevents an accidental `git add`, **not** `git add -f` — so a
malicious PR could commit `.claude/skip-litmus.local`, and after checkout (past the
30s age window) the gate would consume it. That is the *same committable-content
injection class* as this issue. So each gate now also **refuses a repo-controlled
skip file**: `gate_skip_file_repo_controlled` (in `lib/resolve-repo-dir.sh`, mirroring
ADR 0012's fail-closed `_repo_controlled`) rejects any skip file tracked in the index
or HEAD, or in a gitlinked state dir. Only a genuinely *untracked* operator-created
file is honored; any git error fails CLOSED (skip ignored, review enforced).

**Collateral damage — assessed:** the only session-inherited *functional* config any
wrapped gate reads is `LITMUS_PR_BASE` / `LITMUS_PR_BACKSTOP_MAX_AGE`, and both are
themselves injection levers → dropping them to their secure defaults (`origin/HEAD`,
`3600`) is the fix, not a regression. Everything else the gates use is either self-set
(`MODE`, `MERGE_PR_NUM`, …), arrives on stdin, or is read from repo files.

The one real trade-off is `gh` config. `gh` in the pre-PR / pre-merge gates authenticates
via its config/keyring under `$HOME` (`~/.config/gh`) — and because `HOME` is re-derived
from the password database (not the env), that resolves to the **real operator's** config,
so the default `gh auth login` path is unaffected and a poisoned `HOME` can't point `gh` at
attacker config. But `env -i` intentionally does **not** re-import
`GH_TOKEN` / `GITHUB_TOKEN` / `GH_HOST` / proxy vars, because those are themselves
injection levers (a committed `settings.json` could set `GH_TOKEN` to an attacker token,
or `GH_HOST` to redirect PR-state queries). Consequence: an operator relying on
**environment-only** `gh` auth, a non-default `GH_HOST` (GitHub Enterprise), or a required
proxy must move that config into `gh`'s config files (or `~/.config`), not the session env.
For this solo repo (keyring auth, github.com, no proxy) there is no impact.

**Scope:** the 10 enforcement/state gates — `careful-guard`, `pre-commit-gate`,
`pre-pr-gate`, `pre-merge-gate`, `pre-implementation-gate`, `freeze-guard`,
`check-design-document`, `post-commit-consume-marker`, `post-pr-consume-marker`,
`post-merge-confirm-bypass`. The `go-post-edit` formatter and `load-orchestrator`
bootstrap are intentionally **not** wrapped (not enforcement gates; wrapping the
formatter would strip its Go toolchain PATH, and the bootstrap legitimately reads
`CLAUDE_HOMUNCULUS_INTERNAL`).

**Node hooks (corrected — Task 3).** An earlier revision of this scope claimed the
`node`-based hooks "make no allow/block decision." That was FALSE: three node hooks
exit 2 on a *pure* gate decision derived from stdin/`file_path`, not from the
environment — `block-no-verify` (blocks `git commit --no-verify`), `config-protection`
(blocks edits to linter/formatter config), and `pre-bash-dev-server-block` (blocks
unattended dev-server launches). Their only env read is the `ECC_HOOK_PROFILE` /
`ECC_DISABLED_HOOKS` FLAG that `hook-flags.js` uses to enable/disable them — precisely
the PR-injectable channel a committed `settings.json` `env` block controls, so an
attacker could switch the gates OFF. `BASH_ENV` indeed does not apply to `node`, but
the *flag* channel does. These three are now CONTAINED via
`hooks/gate-scripts/lib/sanitized-node.sh` — an `env -i` wrapper that mirrors
`sanitized-gate.sh` (trusted-PATH rebuild, git-config/HOME neutralization) and then runs
the runner (`run-with-flags.js`) as a CHILD — deliberately not `exec` — so it can inspect
the exit status. **Node resolution:** the system allowlist is searched first, then the
operator's passwd-HOME *direct-binary* dirs (`~/.local/bin` + nvm per-version bins) as a
fallback so an nvm-only host still resolves; each candidate is validated with
`node --check "$runner"` (a real syntax parse of the runner, so an incompatible node is
skipped rather than dead-ending the gate closed). Version-manager *shims* (Volta/asdf/mise)
and shared prefixes (Linuxbrew) are excluded — a shim reads PR-controlled repo config to
pick a runtime and a shared prefix is an LCE surface. As defense-in-depth the wrapper runs
node from a **neutral CWD (`/`)** so even a system `node` that is a symlink to a shim can't
read repo-local `.tool-versions`/`.nvmrc`/`package.json`; `config-protection` correspondingly
resolves a relative `file_path` against the *payload* cwd (and fails closed if it can't), so
the neutral process cwd never weakens it. With the profile flag wiped, each hook falls back to
its default-enabled state and fires. If `node`/the runner cannot be found, OR the runner
exits non-0/non-2 (a launch/crash — 1/126/127 — the harness would otherwise treat as a
non-blocking error and let the tool through), the wrapper converts it to
`{"decision":"block"}` / exit 2 (fail-CLOSED), never a silent pass. The wrapper's own
fail-closed only runs once it starts, so each hooks.json registration also appends
`|| exit 2`: if bash itself cannot launch the wrapper (a bad `CLAUDE_PLUGIN_ROOT`, the
wrapper file missing, ENOEXEC), the outer command's 1/126/127 is still converted to a
block at the registration level. (This same launch-failure exposure exists for the shell
gates' `bash sanitized-gate.sh` registrations; hardening those symmetrically is a
follow-up, not in this task's diff.) The wrapper also verifies the target hook script
exists before dispatch and fails closed if it is missing or its path is absolute /
traversing — because `run-with-flags.js` itself exits 0 (allow) on a missing/rejected
hook script, which would fail-open a blocking gate. And `run-with-flags.js` otherwise
exits 0 (allow) on its OWN internal failures — most importantly a caught exception from
a hook's `run()`, which it would swallow to exit 0, indistinguishable from a genuine
allow. To close that, `sanitized-node.sh` appends a `--fail-closed` ARG to the runner
invocation and `run-with-flags.js` converts every fail-open exit point (run() exception,
missing/rejected script, legacy-spawn failure, unhandled error) to exit 2 when that arg
is present. It is deliberately a positional ARG, not an env var: the bare non-gate hook
registrations invoke the runner directly WITHOUT `env -i`, so a fail-closed *env var*
could be set by a committed `settings.json` `env` block and would turn advisory hooks
into spurious blocks (a DoS) — exactly the silent channel this ADR closes. An argv is
settable only via `hooks.json` (review-visible code), never that env channel. The bare
non-gate registrations do not pass the arg, so their historical fail-open is unchanged.

### Amendment (#616, 2026-08-20): the wrapper has TWO dispositions

The unconditional fail-closed contract described above is now **conditional on the caller**,
and the paragraphs above should be read as describing the DEFAULT disposition.

`sanitized-node.sh` accepts a leading `--fail-open` flag (`argv[1]` only, consumed by a
`shift`). Under it, a launch/infrastructure failure resolves to **allow**: the
disposition-aware `_block` writes its stderr line and exits 0 with **no stdout decision at
all**. Nothing may reach stdout in that disposition — the harness consumes a stdout decision
regardless of exit status, so printing block JSON and exiting 0 would still block. The
`--fail-closed` arg is appended to the runner invocation **only** in the closed disposition;
`--fail-open` is never forwarded, because the runner's fail-open behaviour is exactly the
absence of `--fail-closed` (`failOpenExitCode()`).

**The rule, and it is narrow: only a NON-BOUNDARY gate may pass `--fail-open`.** GateGuard is
the sole consumer and qualifies because it guards nothing — it is a quality prompt, off by
default, opt-in per repository. Adopting the closed disposition for it would hard-block every
`Edit`/`Write`/`Bash` of operators who never opted in, on a missing node or one oversized
payload. The four other contained scripts keep the closed disposition and are unaffected. Do
not add a second `--fail-open` consumer without making the same argument explicitly.

A **malformed argument list** is never fail-open: arity, emptiness and stray-flag validation
force `_disposition="closed"` before `_block` is reached, so a malformed registration prints
block JSON and exits 2 whatever it asked for. A malformed registration is a bug in code that
ships with the plugin, not an operator-environment condition, and must be loud.

**Registration shape** (both GateGuard entries):

```
/usr/bin/env -i PATH=/usr/bin:/bin CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}" \
  CLAUDE_HOOK_EVENT_NAME="$CLAUDE_HOOK_EVENT_NAME" \
  bash "${CLAUDE_PLUGIN_ROOT}/hooks/gate-scripts/lib/sanitized-node.sh" --fail-open \
  "<hookId>" "scripts/hooks/gateguard-fact-force.js" "minimal,standard,strict" || exit 0
```

Note `|| exit 0`, not `|| exit 2`: GateGuard denies with exit 0 plus a `permissionDecision`
on stdout, so this cannot suppress a deny — it neutralises infra non-zeros only. One
consequence is worth stating plainly: because the outer tail is `|| exit 0`, the
forced-CLOSED path exits 0 at the shell while its `{"decision":"block"}` still reaches
stdout. The harness blocks on the stdout decision, not on the status; the block takes
effect, the exit code does not carry it. `HOME` is deliberately not forwarded — the wrapper
re-derives it from passwd anyway, and forwarding would imply a trust that is not there.

**Residual, accepted:** for a fail-open consumer, EVERY wrapper launch failure resolves to
allow. That is the intended trade — the alternative hard-blocks operators who never
enrolled — but it means GateGuard is silently absent on a host where node cannot be
resolved. The stderr line is a best-effort diagnostic for someone already debugging, not a
guarantee that a disabled gate announces itself.

**Also amended:** the `|| exit 2` requirement stated above is now "the registration's outer
tail must match its disposition" — `|| exit 2` for a fail-closed consumer, `|| exit 0` for a
fail-open one. #629's registration-derived containment detection keys on that anchored tuple
(leading `/usr/bin/env -i`, the exact wrapper reference, the disposition, the matching outer
tail), NOT on a `--fail-closed` token — after #616 that token appears in no registration at
all, since the wrapper appends it internally.

The `CLAUDE_PLUGIN_ROOT` residual recorded elsewhere in this ADR is **not** amended: its
acceptance argument rests on non-injectability, not on failing closed, and #616 does not
disturb it.

**Out of scope, and named so it is not mistaken for closed:** two classes act on the shell that
*invokes* a registration, before `env -i` is reached, and neither is closed by #616. (a) Exported
shell functions (`BASH_FUNC_*`) and `SHELLOPTS` — the lever table at the top of this ADR already
records exported functions as verified, and it remains live: `/bin/sh` is bash 3.2.57 on macOS
and imports them (`/bin/bash -c 'foo(){ echo PWNED; }; export -f foo; /bin/sh -c foo'` prints
`PWNED`). Note this is NOT the `BASH_ENV`/`ENV` case verified not-live elsewhere in this ADR —
function import is not startup-file sourcing, so that argument does not extend to it. (b) A
committed project `settings.json` key that disables hooks wholesale. Both would defeat all five
wrapped gates identically, before any `env -i` logic runs. This ADR does not record such a key and the
evidence for a specific name was not confirmed; it is reported as a *class*, a plugin-wide
residual for this ADR's own threat model, neither introduced nor closable by #616.

**`mcp-health-check` — was accepted residual, now CONTAINED (#351).** Originally
deferred: its exit-2 paths are env-DRIVEN (`exitCode: shouldFailOpen() ? 0 : 2`, gated
on `ECC_MCP_HEALTH_FAIL_OPEN`, plus ≥4 other behavior-affecting vars), so `env -i` was
thought to require re-importing those "legit" vars. #351 resolved this differently — and
more securely — by removing the dependency instead of re-importing it:

- The one env var the hook genuinely needed for correctness under `env -i` + `cd /` was
  the repo cwd (to find project-scoped `.claude.json`). It now reads that from the hook
  **payload** `cwd` (same pattern as `config-protection.js`), so `process.cwd()` being
  `/` no longer blinds config resolution. `tests/test-mcp-health-payload-cwd.sh` pins it.
- The other `ECC_MCP_*` vars turned out to be pure attack surface on the sanitized
  production path: they are intentionally not re-imported there (the repo's own test
  harness sets `ECC_MCP_HEALTH_STATE_PATH`, and direct (non-sanitized) launches still
  support environment-based configuration), but nothing on the `env -i` production path
  sets them, and two are outright dangerous —
  `ECC_MCP_HEALTH_FAIL_OPEN` (a committed settings `env` block flips the `? 0 : 2` branch
  fail-OPEN) and **`ECC_MCP_RECONNECT_COMMAND` / `ECC_MCP_RECONNECT_*`**, which flow into
  `spawnSync(cmd, {shell: true})` — a repo-injectable **shell-exec** vector this ADR's
  original residual note did not credit. `env -i` wipes all of them for free. The
  operator loses env-var tunability of the health check (deliberate; re-import selectively
  if a real need appears). The `mcp__.*` matcher (narrowed from `*`) also stops the hook
  launching node on every non-MCP tool call.

The remaining reminder/logger/telemetry node hooks make no allow/block decision and
stay out of scope. `tests/test-node-hook-containment.sh` guards this split: a NEW node hook whose
exit-2 uses a *recognized* form (`process.exit(2)`, `exitCode: 2` / `= 2`, or the
`? 0 : 2` ternary) and is neither contained nor listed as residual fails the suite.
The discovery grep is a heuristic, not a proof of completeness — a hook that hides
its exit-2 behind a constant or a helper call would evade it; the explicit
CONTAINED/RESIDUAL lists in the test are the authority, and the trip-wire covers the
common shapes. Full static proof would need an AST pass, deferred as not worth it for
a solo repo whose hook set changes rarely.

## Alternatives considered

1. **Per-script env scrub** (each gate re-derives its signal from a non-env source).
   Rejected: cannot stop `BASH_ENV`/`PATH`/exported-function RCE, which fire before the
   script's first line.
2. **Document as accepted residual risk only** (the "solo-operator, don't run sessions
   on untrusted branches" operational control). Reasonable given the bounded threat, but
   the operator chose to actually close the surface.
3. **`env -u <lever>` denylist** instead of `env -i` allowlist. Rejected: can't
   wildcard-strip exported functions (`BASH_FUNC_*`) and silently misses any lever not
   on the list. `env -i` is closed-by-default.

## Consequences

- The env-based `SKIP_*` escape hatch is **gone**. Operators who previously exported
  `SKIP_LITMUS=1` before starting `claude` now use `touch <repo>/.claude/skip-litmus.local`
  (or `skip-pr-grind` / `skip-design-review`). Docs updated repo-wide.
- Gate scripts run with a fixed trusted `PATH` and no inherited env; a committed
  `settings.json` `env` block can no longer bypass a gate or run code through one **via any
  variable the gate itself reads**. Amended #616: this does not extend to `BASH_FUNC_*` or
  `SHELLOPTS`, which act on the shell that *invokes* the registration, before `/usr/bin/env -i`
  runs — see the lever table at the top of this ADR, and the #616 amendment below.
- The `BUSDRIVER_STATE_DIR` / `BUSDRIVER_PLUGIN_ROOT` / `LITMUS_PR_*` overrides still
  work when a gate script is invoked **directly** (tests, manual runs); they are only
  stripped on the production hook path. Test suites are unaffected.

### Residual risks (accepted)

- **`CLAUDE_PLUGIN_ROOT`** locates the wrapper (`hooks.json` expands it *before* `env -i`).
  This is **not** part of the `settings.json`-`env` injection channel: Claude Code sets
  `CLAUDE_PLUGIN_ROOT` authoritatively per-plugin *after* merging `settings.json`, so a
  committed `env` block **cannot** override it (verified — Claude-provided variables take
  precedence over the settings `env` block, [docs](https://code.claude.com/docs/en/settings.md)
  v2.1.195+; it is exported to hook processes per
  [plugins-reference](https://code.claude.com/docs/en/plugins-reference.md)). It is the
  plugin trust root every busdriver hook already relies on, and #325's lever list
  correctly omits it.
- **`HOME`** — **closed**, not accepted. `HOME` is a general tool-config RCE channel (a
  poisoned `HOME` supplies a `~/.gitconfig` helper, a Python user-site
  `~/.local/.../sitecustomize.py` that runs on every `python3`, or a spoofed `~/.config/gh`
  that feeds a gate fake PR state). Rather than whack-a-mole per tool, the wrapper
  **re-derives `HOME` from the password database** (`getent`/`dscl`, keyed on `id -un`), so
  git/python3/gh all read the *real* operator's config regardless of the env `HOME`.
  `GIT_CONFIG_*=/dev/null` and `PYTHONNOUSERSITE=1` are belt-and-suspenders. The only
  residual is the near-impossible case where `id`/getpwnam yield nothing (no override, so
  the passed `HOME` stands) — acceptable under the solo-operator bound.
- **Outer-shell `BASH_ENV`** — **verified not a live vector** for the documented hook
  runner. `env -i` protects the gate script, but not the *outer* shell that Claude uses to
  launch the hook command (that shell sources its startup files before parsing our
  command, so `env -i` cannot reach an outer sourcing). The guarantee therefore rests on
  *which shell* Claude uses: it runs hook commands via **`sh -c`**
  ([docs](https://code.claude.com/docs/en/hooks.md), macOS/Linux default), and a
  non-interactive POSIX `sh` sources **no** startup files — so `BASH_ENV` is never read
  before our command. Confirmed empirically on this host: `/bin/sh -c` ignores a
  `BASH_ENV` that `bash -c` *does* source (a `BASH_ENV` script that `exit 0`s suppresses
  the command only under `bash -c`). The single way this reopens is an upstream change to
  invoke hooks via `bash -c` — recorded as a revisit trigger.
- **FIVE `node` gate hooks are now CONTAINED** via `sanitized-node.sh` (amended #616): the
  three pure-block hooks (Task 3, see Scope), `mcp-health-check` (#351 — it reads its repo
  cwd from the hook payload instead of `process.cwd()`, so `env -i` no longer changes its
  behavior and also wipes its `ECC_MCP_RECONNECT_COMMAND` shell-exec +
  `ECC_MCP_HEALTH_FAIL_OPEN` channels), and **`gateguard-fact-force`** (#616, both
  registrations). The remaining `node` reminder/logger/telemetry hooks make no allow/block
  decision and stay env-exposed (out of scope).

  The earlier wording "the remaining node hooks make no allow/block decision" was falsified
  by GateGuard, which decides and was nonetheless launched with bare `node`. That is what
  #616 fixed.

## Revisit trigger

- A second approval-capable human is added (repo stops being solo-operator) → tighten
  the residuals above (pin `CLAUDE_PLUGIN_ROOT`, re-examine `HOME`). (`mcp-health-check`
  is already contained — #351.)
- Claude Code gains a first-class "don't honor project-`settings.json` `env` for
  security-relevant keys" control → prefer it and simplify this wrapper.
- Claude Code changes hook execution from `sh -c` to `bash -c` (or any bash-named shell)
  → the outer-shell `BASH_ENV` sourcing above becomes live; re-close upstream or move gate
  enforcement out of a shell command.
