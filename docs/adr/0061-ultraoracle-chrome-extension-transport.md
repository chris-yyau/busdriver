# ADR 0061 — UltraOracle over Claude-in-Chrome; withdraw the oracle CLI

## Status

**Accepted (2026-11-03).** Supersedes [ADR 0020](./0020-ultraoracle-attach-running-transport.md)
and [ADR 0029](./0029-ultraoracle-inline-context-and-submit-watchdog.md). Amends
[ADR 0007](./0007-ultraoracle-expert-witness-and-ultra-council.md). Adds amendment notes to
[ADR 0027](./0027-k3-mechanism-witness-ultimate-tier.md) and
[ADR 0030](./0030-blueprint-blocking-window.md). Spec:
`docs/specs/2026-11-01-ultraoracle-chrome-transport-design.md` (revision 13). Plan:
`docs/plans/2026-11-03-ultraoracle-chrome-transport.md`. Released as 4.0.0. Recovery anchor:
`e69c79f2`.

## Context

The UltraOracle surface consulted ChatGPT Pro through the third-party `oracle` CLI's browser
engine. Every transport it offered either launched an automation-fingerprinted Chrome
(Cloudflare walls it), depended on cookie decryption that current Chrome blocks (#340), or needed
an `oracle serve` process holding a secret token. The adapter accumulated heuristics to
survive the engine itself: hung-response salvage (#458), a submit watchdog and an inline-context
budget (#490), and attach-mode preflight healing (ADR 0020). The spikes of 2026-11-01 and
2026-11-02 (spec E1–E21) showed that a headless `claude -p --chrome` child, driving the
operator's own signed-in Chrome through the Claude-in-Chrome extension, can upload a staged
prompt, read the answer from ChatGPT's own conversation API, and hand it back as a download.

## Decision

`ultra_oracle_consult` keeps its contract and runs one guarded child per consult (spec §1–§3):
- The child has six chrome tools and no `computer` tool. None is pre-approved. A PreToolUse guard
  (`scripts/hooks/ultra-oracle-child/guard.sh`, exec form through `contained-launch.sh closed`,
  bash 3.2, `/usr/bin/jq`) is the only allow, and its table pins every argument (§4).
- The child never sends script text. It sends one of seven opcodes, and the guard swaps in the
  repo's fixed snippet through `updatedInput` (§4, §5).
- The parent publishes nothing while the child runs. After the child's process group is dead, it
  fences the guard, replays the decision log through the guard's pure mode, joins it to the stream,
  classifies the exit by phase, and accepts the answer only when the download matches J-get's
  `SAVED` size and hash and the §5 binding rules (§2, §4, §6).
- A finished consult archives its ChatGPT chat and closes its tab. A failed archive or close is
  a NOTE on an `ok` consult, never a failure.
- One deadline is anchored at consult start, with a browser cutoff 60 s before it. There is one
  child, no retry and no recovery child (§2).
- The `ultraOracle` USER config keeps only `timeoutCapSeconds` and the four surface switches (§8).
  A removed key still present is named once, by key name only.

## Alternatives

- **OpenAI Responses API.** Better primitives, but API billing, not the operator's Pro
  subscription.
- **Keep oracle, fix the heuristics.** Each fix was another layer over a browser engine we do not
  control; the failures were in its detection of page state.
- **Automatic recovery children.** Design-review rounds 9 and 10 kept finding races in their
  shared state; revisit as its own design if dropped consults prove common.

The spec's "Alternatives rejected" section has the rest.

## Consequences

- macOS only (15 or later, for Apple's bundled `/usr/bin/jq`). um and every non-Mac host get
  `skipped:unavailable`, which every caller handles.
- The hook-failure residual of spec §4 is closed. The r3 canary passed
  (`tests/fixtures/ultra-oracle/qualification.json`): the PreToolUse handler carries
  `onFailure: "block"`, which blocked both a hook timeout and a hook crash while the control
  without it leaked, and the probe requires `claude` 2.1.295 or later. A hook timeout therefore
  cannot let the pre-approved `Read` of the staged prompt run.
- Operator prerequisites: ChatGPT's UI in English, Pro as the sticky selection, Chrome's download
  prompt off, and Chrome's profile picker "Show on startup" unchecked (r4: with it checked, a
  cold start stops at the picker and the extension never connects).
- The caller timeout contract is `cap + 90 s`; the attach-preflight launch wait is gone.

## Deviations from the plan

Recorded here as each commit's message promised.

- **Launch and fake harness.** The launch subshell runs `set +e`; the child launches through
  `_uora_noloader`; an unreadable clock counts as the cutoff, in the watchdog and before launch;
  `_uora_dl_dirs` skips a malformed Preferences. The fake keeps only the first text block of a
  result (the one the guard reads), denies on a crashed PreToolUse hook when `onFailure` is
  `block`, and counts one launch per call, not per line. `uora_env` and the suites that arm a
  `pkill -f` trap refuse an empty `mktemp`. On Linux a KILLed orphan stays a zombie under a
  subreaper, so the launch suite's liveness check also reads the process state.
- **Audit and acceptance.** A stream result's text is its first text block; an `is_error` result
  is never evidence of `SAVED`, the id, the archive or the upload; the upload fact takes the
  attempt that succeeded. A cancel is written before `child.pid` is read and rechecked after it
  is written. `.err` and `.hint` are written rm-then-noclobber.
- **The flip (Tasks 15–16).** Split into two commits for the litmus size ceiling. The wrapper's
  `FAILED [...]` glob allows the hint suffix; the advisory suite waits 30 s for `.rc`; layer 1c
  of the nonblocking suite probes the consult core's process group; five `NO_LOCK` lines and
  `HOME_SAVE` went; the lock recovery line no longer names oracle.
- **Config (Task 17).** The preflight suite and its durations row went with the script; the
  legacy-keys notice reads with `/usr/bin/jq`; four more getter assertions were deleted.
- **Notices (Task 18).** The note suite resets the config before its tab case.
- **Docs and sweep (Tasks 19–20).** Three more "`oracle` CLI's ChatGPT Pro browser engine"
  phrasings the plan's grep missed were rewritten. The sweep spells word ends as
  `([^A-Za-z0-9_]|$)`: the macOS `regcomp` behind `git grep -E` has no `\b`, so the plan's key
  pattern could never fire there. Two stale comments went with it. The new suites use if/else
  and join the required Chrome-transport lint step.
- **Live smoke (Task 22).** The legacy-keys notice is named once on stderr, not again at finish.
  The lock recovery line checks `pgrep -fl -- '-p --chrome --model sonnet'`, not the spec's
  `'claude -p --chrome'`: the trusted resolver hands back the versioned binary
  (`…/claude/versions/<v>`), so the child's argv never contains `claude -p` and the spec's check
  printed nothing while a consult ran.

## Revisit trigger

ChatGPT's conversation API or the extension's tool surface changes so that a snippet or the
guard's pinned `find` stops matching; real use shows dropped consults are common; or
`onFailure: "block"` is withdrawn or changes meaning in a later `claude`.
