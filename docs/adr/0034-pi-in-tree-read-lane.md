# ADR 0034 — Pi as an in-tree read lane, with an allowlisted toolset

## Status

Accepted. Implemented in `skills/dispatch-cli/scripts/dispatch.sh` (`pi)` arm),
`scripts/lib/resolve-cli.sh` (`resolve_pi_model`), `tests/test-pi-dispatch-arm.sh`.

## Context

Claude Code usage here is subscription-capped: exhausting the cap stops work
entirely, so the scarce resource is Claude context, not dollars. Measured over
the last 30 days of `~/.claude/metrics/costs.jsonl` (494 sessions, per-session
final snapshots — the rows are cumulative, so summing them naively overcounts by
~10x):

| Token class | Volume | Share of notional cost |
|---|---:|---:|
| output (generation) | 118.6M | 13.7% |
| cache-read | 27,708M | 64.0% |
| cache-write | 775M | 22.4% |

**Context handling is 86.3% of consumption; generation is 13.7%.** The dominant
cost is Claude *reading* — files, diffs, PR comments — not writing. So the
highest-value work to move off Claude is reading, and the artifact that comes
back must be small: a cited summary Claude spot-checks, not a transcript.

Every existing read-only dispatch lane is confined to an empty directory
(`opencode` runs with `--dir <neutral tmp>` so a reviewed checkout cannot
redefine the reviewer through its own project config). That confinement makes
those lanes structurally incapable of the job described above: a voice that
cannot see the tree cannot trace it.

Pi is installed, authenticated against a provider carrying cheap models, and
runs in the working tree by default.

## Decision

Add a `pi` arm to `dispatch-cli` that **runs inside the working tree**, with:

1. **A positive tool allowlist — `--tools read`.** Not a denylist.
2. **Six project-config kill switches** — `--no-approve --no-context-files
   --no-skills --no-extensions --no-prompt-templates --no-themes` (plus
   `--no-session`).
3. **Read-only by construction.** The arm ignores `--mode`, and is excluded from
   `--cli all --mode auto` batches so it can never appear as a writer.
4. **Model configurable at `~/.claude/busdriver.json` → `{"pi": {"model":
   "provider/id"}}`**, resolved through the same hardened reader as
   `.auditor.model`: USER config only, no env override, password-DB-derived
   `$HOME`, `env -i` child, validate-and-default inside the child, result
   returned in a variable.
5. **A projected private `$HOME`** carrying exactly one thing: the auth entry
   for the provider named by the resolved model.
6. **No droid escalation on failure.** Every other read-only voice falls back to
   `droid exec` when it errors. pi must not: the operator picked the provider at
   `.pi.model`, and that key exists to control *which* third party sees repo
   source, so a silent re-send elsewhere defeats it — and the fallback would
   overwrite the pi error this lane surfaces deliberately.

Requirement 5 exists because `--tools read` turned out to stop *writes* only.
Reads are not confined: pi read `~/.pi/agent/auth.json` and enumerated every
stored provider credential. A lane whose job is ingesting repo content is a lane
pointed straight at where prompt injections live, so handing it the real `$HOME`
puts `~/.ssh`, `~/.aws`, `~/.claude` and every provider key one instruction from
the model. Projection removes all of that from `~`.

The allowlist is the load-bearing choice. `--exclude-tools edit,write` reads as
read-only and is not: pi's built-in `bash` survives it and can write, run git,
and reach the network. Probed on pi 0.84.1, the unrestricted surface also
carried a second shell (`hypa_shell`), web fetch/search (`exa_*`), and a
`subagent` spawner — 45 tools total. No denylist enumerates that safely, and the
set grows with every extension the operator installs.

One config key carries provider *and* model because that is pi's own reference
form, which lets `.pi.model` reuse `.auditor.model`'s validation regex verbatim
instead of introducing a second config grammar.

## Alternatives considered

- **Confine pi to a neutral dir, like opencode.** Rejected: it removes the only
  capability the lane exists for. The isolation problem is not avoided, it is
  inverted — the repo is inside, so containment moves to the toolset.
- **Denylist the dangerous tools.** Rejected as fail-open; see above.
- **Delegate pr-grind rounds to pi.** Rejected: the wait-round polling that
  motivated the search is fully deterministic and already implemented in
  `hermes-busdriver-pr-grind-loop` (`clean|needs_fix|wait|blocked`). Spending an
  LLM on it is strictly worse than calling the script. Separately, the pr-grind
  dispatcher owns commit/litmus/push/merge, and those gates are Claude Code
  PreToolUse hooks — an agent committing outside a Claude session is not blocked
  by them, it is invisible to them.
- **Route through the relay's Pi adapter.** Rejected for this lane: production
  dispatch there is blocked by `agent_containment_and_credential_broker_unavailable`
  (ADR 0007 reqs 1 & 4 undelivered) and that machinery targets *mutating* drafts.
  A read lane needs neither.
- **A write posture in the same arm.** Deferred to its own change: it needs
  worktree semantics and multi-writer batch review, and doubles the surface for
  a capability exercised manually today.

## Consequences

- Repo tracing moves off Claude at roughly 1/50th the token cost, and Claude
  verifies named citations instead of reading files to find them. Dogfooded:
  correct `file:line` traces of the pr-grind dispatcher and `ack-ledger.sh`,
  independently verified against source.
- The lane is slower than a shell-enabled agent (no grep — it reads whole
  files). Observed 88s–3m per trace. Accuracy improved without the shell.
- Containment now depends on flags pi must honour. `tests/test-pi-dispatch-arm.sh`
  asserts the invocation shape statically, and asserts the write denial live
  (opt-in `BUSDRIVER_PI_LIVE=1`) — that one is demonstrable in both directions:
  removing `--tools read` makes pi write the file.
- **UNCLOSED RESIDUAL — read this before pointing the lane at code you do not
  trust.** Credential projection shrinks blast radius; it is not containment.
  pi's `read` tool accepts **absolute paths**, so an injection that names a full
  path outside the projected HOME is still served (verified: the real
  `~/.pi/agent/auth.json` remains reachable by full path even from the jail).
  Projection does not even force the attacker to guess that path — `/etc/passwd`
  is readable and discloses the operator's real home directory, from which
  `~/.ssh/id_rsa`, `~/.aws/credentials` and the real auth store are all
  predictable. Assume an injection can reach any file the invoking user can read.
  What projection buys is narrow but not nothing: `~`-relative discovery finds
  an empty jail, and the three other stored provider credentials are absent from
  it, so the *default* path of least resistance is closed. Closing the residual needs
  OS-enforced read confinement — see the revisit trigger. Until then this lane
  sits in the same disclosed category as `droid` (no strict sandbox), and must
  not be pointed at a checkout you would not run.
- **Credential teardown is done by grammar, not by a command.** `_pi_wipe` runs
  back in the inherited shell, where every command word is shadowable by an
  exported function — inside the one function that must still work after an
  injection. There is no fixed point in commands: a bare `rm` loses to an
  imported function; `/bin/rm` cannot be *imported* (bash refuses it at
  `export -f` and again at import — the suite probes the live bash so this fails
  loudly if that ever changes) but *can* be defined in-shell, and the arm calls
  bare `type`/`source` at startup, which hands an attacker that opportunity;
  escaping through `/usr/bin/env` only moves the problem one word along. A bare
  redirection has no command word, so `>|` terminates the regress — parsed,
  never resolved. Verified with `rm`, `echo` and `printf` all shadowed: 32 bytes
  → 0. The subsequent unlink runs in a sterile `env -i` child and is hygiene
  only; by then the credential is already zeroed. Truncation is not unlinking,
  and that is the right trade: the credential is *content*.
- **Second residual — reentrancy across the teardown's final clear.** `_pi_wipe`
  empties `_pi_jail` once removal is confirmed, which is what makes a second call
  a no-op. That clear cannot be made atomic with the removal preceding it: bash
  runs a pending signal handler after a foreground command returns but before the
  next assignment, so a signal in that one-statement window re-enters the function
  while the variable still holds the just-freed pathname. Shell offers no atomic
  swap. `trap '' INT TERM HUP` around the body would close it, and was tried and
  reverted: `trap` is itself a shadowable builtin and a second arming site, so it
  breaks both the single-cleanup-owner and no-bare-command-word invariants the
  lane rests on — the test suite enforces both, and caught it. What bounds the
  residual: the window is one statement, the second pass re-checks the path shape,
  the name carries `$$` plus two `$RANDOM` draws under a per-user mode-700
  `$TMPDIR`, and the credential is already zeroed. Closing it properly needs
  signal masking, i.e. not bash.
- **Known gap, deliberately not papered over:** a project-local `AGENTS.md`
  injection assertion was written and removed for being vacuous — it passed with
  the flags, without them, and with `--approve`. No failing case could be
  produced, so it tested nothing. Whether pi honours the `--no-*` flags is pi's
  contract; this suite does not claim to prove it.
- The shipped default requires its provider workspace's China-hosting opt-in;
  without it the provider returns HTTP 403 `RegionError`. The arm therefore
  merges child stderr into the transcript so that reads as a provider error, not
  a silent dead voice. Operators without the opt-in set a different `.pi.model`.

## Revisit trigger

- **OS-enforced read confinement becomes available** (`sandbox-exec`/seatbelt
  profile pinning reads to the repo, or pi gaining a first-class sandbox) → adopt
  it and close the absolute-path residual above. This is the highest-priority
  trigger; the residual is the one known hole in the lane.
- The `--tools read` allowlist proves too narrow in practice (traces missing
  reachable code) → consider adding read-only search verbs, re-probing the full
  surface first, and re-running the write-denial control.
- A write posture is genuinely needed → separate ADR; do not widen this arm.
- Claude's cap stops binding (billing change) → the cost case weakens, though the
  cross-model diversity case stands on its own.
