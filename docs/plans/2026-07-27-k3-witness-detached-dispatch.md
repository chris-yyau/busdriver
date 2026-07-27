# DESIGN — Blueprint review loop: fix the real blocking window (#499 → #501)

**Status:** implemented (this branch) — see [ADR 0030](../adr/0030-blueprint-blocking-window.md) for the accepted decision record
**Date:** 2026-07-27
**Issues:** [#499](https://github.com/chris-yyau/busdriver/issues/499) (re-scoped), [#501](https://github.com/chris-yyau/busdriver/issues/501)
**Supersedes:** the k3-detach proposal previously in this file. Filename retained — the review slug and armed marker tokens are keyed to this path.

## Problem

#499 blames the Mechanism Witness reap (`≤610s`) for the blueprint loop's blocking
window and proposes detaching k3. Six review rounds showed the reap is not the
binding term and detaching k3 is the wrong fix.

**`--mode background` does not background.** The disowned subshell at
`ultra-oracle.sh:1232-1313` closes with a bare `) &` — no subshell-level redirect —
so it inherits the caller's stdout, and both `--mode background` call sites capture
that stdout in `$( )`, which reads until the child closes it. The consult therefore
runs **serially before** the reviewers (#501).

Measured — `Stale artifacts cleared` to `Phase 1: Launching`, pure serialization
before any review work: **4 min**, **31 min**, **31 min** across three rounds,
against reviewers taking 460–498s. The 31-minute figure is the oracle cap consumed
in full, serially.

**What the fix is actually worth.** The child's *last* statement before `) &` is
the atomic `.rc` rename (`ultra-oracle.sh:1308-1312`), so `.rc` already exists the
moment the capture returns. The poll at `:1059-1062` therefore costs ~0s **today**,
and the oracle must finish before the arbiter either way. The saving from §1 is not
the 31-minute block — it is the **overlap that block currently forbids**:

```
today:    oracle(T) ; reviewers(R) ; poll(0)        = T + R
after §1: max(T, R) then residual poll               = max(T, R)
saving    = min(T, R)  ≈ 4–8 min   (R measured 460–498s)
```

So: **~4–8 minutes per round, not 4–31.** Worth doing — it is one line — but the
honest number is the overlap, and every figure in this document is stated that way.

`ultra_oracle_timeout_cap` (`ultra-oracle-config.sh:54`) reads USER config with
`900` only as a fallback.

**k3 is not the binding term.** Across six rounds the witness ran in four and
failed in two (`unparseable`, `rc=124`) — so #499's "routinely absent" is real but
partial, and it is not what makes the loop long. k3 runs concurrently with the
reviewers and consumes its budget inside their window.

**These are budgets, not bounds.** `_portable_timeout` invokes `timeout`/`gtimeout`
without `--kill-after`; the reviewer `wait`s at `:822-824` are unbounded; the perl
fallback (`resolve-cli.sh:197-209`) exits without reaping. No number correctly
sizes a foreground call. Measured in practice: ~8 minutes.

## Decision

Fix the term that binds. Change nothing about k3.

### 1. Make `--mode background` non-blocking (#501)

`scripts/lib/ultra-oracle.sh:1312` — redirect the subshell's **stdout**:

```bash
    ) </dev/null >/dev/null &
    disown 2>/dev/null || true
```

Closing stdout is what releases the `$( )` capture; stderr is not captured and does
not hold the pipe, so redirecting it is unnecessary.

`</dev/null` is included because blueprint-review runs with piped stdin under agent
invocation (`[[ ! -t 0 ]]` at `run-design-review-loop.sh:1192`).

**Also drop the `2>/dev/null` on the dispatch at `run-design-review-loop.sh:497`.**
Leaving the child's stderr *open* is not by itself enough — the caller throws it
away. That redirect discards the only carrier of the stale browser-lock recovery
pointer (`ultra-oracle.sh:772`), an actionable `rm -f` instruction the operator
currently never sees. Residual 1's recovery path depends on it. (`ultra-oracle-run.sh:72`
discards it the same way; out of scope here, noted in #501.)

**Bonus: §1 closes a latent corruption channel.** `:1051` compares
`ULTRA_ORACLE_DISPATCH_STATUS` against the exact string `dispatched`. Today the
capture also swallows anything the child writes to stdout, so a single stray byte
silently makes the status mismatch and disables the poll entirely. Redirecting the
child's stdout removes that path.

### 2. Bound the poll §1 unblocks — a companion guard, not a win

**This fixes a defect §1 introduces, and claims no saving of its own.** Today the
poll is a no-op because `.rc` is always present. After §1 the consult can still be
running when the reviewers finish, and the poll would then charge a *fresh*
`cap + 90` on top of the reviewer time — worst case `R + cap + 90`, which is
**worse than today**. The deadline caps it at `cap + 90` from dispatch.

Capture an absolute deadline at dispatch; keep the existing iteration counter:

```bash
ULTRA_ORACLE_DEADLINE=0                       # declared beside ULTRA_ORACLE_DISPATCH_STATUS at :38-39

# at :495, only on a successful dispatch
ULTRA_ORACLE_DEADLINE=$(( $(date +%s) + $(ultra_oracle_timeout_cap) + 90 ))

# at :1059 — whichever fires first
_uora_wait=0; _uora_cap=$(( $(ultra_oracle_timeout_cap) + 90 ))
while [ ! -f "$ULTRA_ORACLE_ADVISORY_FILE.rc" ] \
   && [ "$(date +%s)" -lt "$ULTRA_ORACLE_DEADLINE" ] \
   && [ "$_uora_wait" -lt "$_uora_cap" ]; do
  sleep 2; _uora_wait=$((_uora_wait + 2))
done
```

The counter is retained deliberately: `date +%s` is wall-clock (the hazard
`ultra-oracle.sh:455` documents), so a backward NTP step could otherwise stall the
poll. The deadline credits concurrent reviewer time; the counter bounds it
regardless of the clock. Neither alone suffices — `$SECONDS` is not monotonic
either.

The poll is doubly gated at `:1050-1051` and both variables are pre-initialised at
`:38-39`, so no `set -u` abort is reachable on the `--claude-only`,
adapter-unavailable, or surface-disabled paths. The `while true` at `:407` always
terminates the process within one iteration (no `continue`; every path exits or
breaks), so `ULTRA_ORACLE_DEADLINE` cannot leak across rounds — stated as an
invariant because §2 would be unsafe if it ever stopped holding.

**`ULTRA_ORACLE_RC_GRACE` must be sanitized, not merely read.** It is
repo-injectable through a committed `settings.json` `env` block (#325 / ADR 0016),
and it bounds a wait. Apply the same treatment the sibling `BLUEPRINT_AUDITOR_GRACE`
already gets at `run-design-review-loop.sh:838-845`: reject non-numeric, strip
leading zeros, length-cap before `$((10#…))`, floor at 1, and **clamp upward at the
default** so an override may only *shorten* the wait, never extend it.

### 3. Correct the timeout documentation

**`skills/blueprint-review/SKILL.md:28` is NOT touched.** It reads *"Run
`run-design-review-loop.sh` as a BLOCKING bash call"* and is item 1 of the
`<EXTREMELY-IMPORTANT>` anti-class-roll block. That is a **mechanism, not advice**:
while the call blocks, the session cannot write `claude.json`. Background it and
`:1201-1202` (*"Found existing Claude output — continuing"*) consumes a mid-flight
verdict built from partial artifacts, and the loop then stamps PASS on it. The
instruction stays exactly as written; this design does not ask anyone to background
the loop.

| Site | Change |
|---|---|
| `blueprint-review/SKILL.md:42` | drop the *"starve it under the Bash-tool cap"* clause from the k3 clamp rationale; **keep** the repo-injection DoS justification, which is independent |
| `blueprint-review/SKILL.md:174` | rewrite the sizing advice (below) |
| `council/SKILL.md:251` | it calls 3600s "the default budget"; 3600 is the **ceiling**, the default is **900** (`ultra-oracle-config.sh:54`). Replace with the **formula plus its synchronous preflight** — `ultra_oracle_timeout_cap + 90 + LAUNCH_WAIT_SECONDS` (`ultra-oracle-attach-preflight.sh:24`, 15s, which runs *before* the poll starts) — and keep headroom rather than pinning an exact number. A fixed 990s would under-size the caller contract for any raised cap **and** drop the slack that currently masks the preflight, re-creating #477 Cause 1. Its "the wrapper blocks internally" claim stays **true** after §1: `ultra-oracle-run.sh:86-87` still polls `$OUT.rc` to completion |

`:174`'s replacement states the phases **once each**, without double-counting the
oracle:

```
[ reviewers (execute_review default 1200s) ‖ k3 dispatch ‖ oracle dispatch ]
      → k3 residual reap        (:846, counter starts AFTER the :822-824 waits, ≤610s)
      → optional droid rescue   (:880-904, sequential, one more execute_review)
      → residual oracle wait    (bounded by ultra_oracle_timeout_cap + 90 from dispatch)
      → arbiter
```

Each phase appears exactly once; the k3 reap and the droid rescue are **sequential
tails**, not part of the parallel group.

These are budgets, not bounds, so **pass the tool's maximum `timeout` rather than
computing one**. The lever for a shorter round is `ultraOracle.timeoutCapSeconds`
or the `.claude/skip-ultra-oracle.local` opt-out — not the witness budget.

SKILL.md is shipped and public, so it states the **formula and the default**, never
this operator's private `timeoutCapSeconds`.

> **Not fixed here:** the k3 reap has the same shape — `_aud_grace=0` at `:846` is
> initialised *after* the three reviewer `wait`s at `:822-824`, so a slow witness
> also charges a fresh ≤610s budget on top of the reviewer window. That is #499's
> original complaint, correctly stated. The same deadline treatment would fix it,
> but §4 keeps k3 untouched in this change; recorded as follow-up.

### 4. k3 unchanged; ADR 0027's Bash-cap rationale retired

No detach, no lease, no trust guard, no clamp change — `BLUEPRINT_AUDITOR_TIMEOUT`
stays default-and-clamp 600s.

ADR 0027 gives that clamp two rationales. The one at
`docs/adr/0027-k3-mechanism-witness-ultimate-tier.md:82` — *"a longer budget could
starve arbitration under the Bash-tool cap the loop runs beneath"* — is the
cap-as-kill-boundary reading this design retires, so **ADR 0027 gets an inline
supersession note** pointing at ADR 0030. The other rationale (the env var is
repo-injectable, #325) is independent and preserves the clamp on its own.

## Why not detach k3

Two review rounds took the detach design from 14 findings to 25 (1 → 5 high), each
round invalidating the previous round's fix: `auditor-raw.txt` is re-opened by
pathname after `execute_review` returns, so the per-round `rm -f` breaks any
cross-round dispatch; `gate_skip_file_repo_controlled` performs no `GIT_*`
sanitization, so the proposed trust guard lacked the property it was chosen for;
and the perl fallback reparents its child to init, so the proposed `pgrep -P`
tree-kill can never reach a TERM-ignoring process.

Surviving review would have required a `mkdir` lease with ownership nonce and stale
reclaim, a child-owned raw path, a repo-controlled-artifact guard with its own
`GIT_*` unset, a no-symlink component verifier, a new TERM/grace/KILL walk that
still cannot bound the perl path, design-identity stamping, an artifact TTL, and a
re-dispatch cap — roughly ten new failure modes on the **gate of record**, for a
non-gating auxiliary. And it does not deliver its headline benefit: with the oracle
enabled the loop still exceeds 600s after k3 is detached.

## Alternatives considered

- **Detach k3 (original #499).** Rejected above.
- **Drop the blueprint witness, keep k3 in ultimate-council only.** Still open;
  deferred because the lens found a real defect both Codex-xhigh and the Opus
  backstop missed. The 4-ran/2-failed record argues for re-measuring first.
- **Lower `ultraOracle.timeoutCapSeconds` so the loop fits 600s.** An operator
  lever, not a defect fix; documented in §3 as such.
- **Detach the oracle poll the way #499 proposed for k3.** Identical machinery,
  identical cost, unnecessary once §1 restores parallelism.
- **Kill the consult on deadline expiry.** Rejected — strands the browser mutex; see
  Residuals.

## Consequences

- The consult runs **parallel** to the reviewers instead of serially ahead of them,
  returning `min(oracle, reviewers)` ≈ **4–8 minutes** per round — the overlap, not
  the whole 31-minute block.
- The poll stays bounded at `cap + 90` from dispatch rather than from the reviewer
  finish, so §1 cannot make the tail case worse than today.
- `ultra-oracle-run.sh` (council expert witness) gets the same parallelism — its
  bounded `cap + 90` poll starts working as designed instead of being bypassed by a
  blocking dispatch.
- k3 behaviour is bit-for-bit unchanged; ADR 0027's clamp stands, one rationale
  retired.

### Residuals (accepted, not solved)

Residuals 1 and 2 are **on the normal path, not edge cases**: the agent invocation
always pauses at `exit 2` (`:1208`) and resumes with `--claude-only`, so every
review run passes through the window they describe.

1. **Deadline expiry with a live child.** Newly reachable: today's accidental
   blocking guarantees the child is dead before the loop proceeds.

   **The child is reachable by a group signal — verified.** `disown` only clears
   the job table; it never calls `setsid`. Measured: parent pgid `86019`, disowned
   child pgid `86019` — the same group, so any `kill -TERM -<pgid>` reaches it, and
   `council/SKILL.md:251` documents the harness doing exactly that. An earlier
   draft of this document claimed the opposite on the strength of a weaker
   experiment (two disowned children observed alive across a tool-call boundary);
   that test only exercised *normal completion*, which nothing signals, and never
   the kill path. The correction matters because killing the subshell before it
   releases the shared-browser mutex strands that lock with **no auto-reclaim**
   (`ultra-oracle.sh:1242`).

   **This exposure is pre-existing; §1 widens the window rather than creating it.**
   The consult is a disowned child today too — the parent merely happens to be
   blocked on it — so an interrupt already strands the lock mid-consult. (Three
   task-stops during this very review would have hit that window.) What §1 changes
   is that the child is now alive across the reviewer phase, the arbitration pause,
   and beyond, instead of only during the dispatch.

   **Mitigation, in scope:** the recovery instruction already exists — the
   `rm -f '<lockfile>'` pointer at `ultra-oracle.sh:772` — but it is discarded by
   the caller's `2>/dev/null` at `run-design-review-loop.sh:497` and so never
   reaches anyone. Drop that redirect (§1) and the operator gets an actionable
   message when a stale lock is next encountered. That closes the recovery path
   without waiting on **#502**, which stays a follow-up: with recovery reachable,
   an unseen expiry costs a non-gating auxiliary and leaves no unrecoverable state.

   Killing the child on expiry remains rejected — it is precisely what strands the
   lock.
2. **Late advisory splice on `--claude-only`.** Made *more* likely by the survival
   property above: a child landing after expiry writes `$out`/`$out.rc` during the
   arbitration pause, then the resume rebuilds the arbiter prompt (the oracle
   section lands at `:1153`) and
   splices in an advisory the already-written verdict never saw. Nothing detects it
   — `validation.sh:37-51` binds a verdict only by `run_id` + `spec_hash`, neither
   of which changes when the advisory appears. Non-gating (the advisory is
   auxiliary; the three reviewers converge without it), but the archived prompt
   then misrepresents what the arbiter actually read.
3. **The perl-fallback orphan** (`resolve-cli.sh:197-209` exits without reaping) —
   pre-existing, recorded in #501.

## Files touched

| File | Change |
|---|---|
| `scripts/lib/ultra-oracle.sh` | subshell stdout redirect at `:1312` (§1) |
| `skills/blueprint-review/scripts/run-design-review-loop.sh` | drop `2>/dev/null` on the dispatch at `:497` (§1); `ULTRA_ORACLE_DEADLINE=0` at `:38-39`; deadline captured at `:495`; poll at `:1059-1062` gated on deadline **and** the retained counter; the `+ 90` grace becomes the sanitized, shorten-only `ULTRA_ORACLE_RC_GRACE` (default 90) so the tests can run inside the CI ceiling (§2) |
| `skills/blueprint-review/SKILL.md` | `:42` and `:174` only — **`:28` unchanged** (§3) |
| `skills/council/SKILL.md` | `:251` default-budget number only (§3) |
| `docs/adr/0027-k3-mechanism-witness-ultimate-tier.md` | inline supersession note on the `:82` Bash-cap clause (§4) |
| `docs/adr/0030-blueprint-blocking-window.md` | new ADR — Context / Decision / Alternatives / Consequences, per 0027 and 0029 |
| `tests/test-ultra-oracle-background-nonblocking.sh` (new) | Verification 1 |
| `tests/test-blueprint-oracle-deadline.sh` (new) | Verification 2 |

## Verification

1. **`--mode background` returns before its child exits.** Stub `oracle` on `PATH`
   with a script that sleeps then writes `$out`/`$out.rc`; call
   `ultra_oracle_consult --mode background` inside `$( )`; assert the capture
   returns in well under the sleep while the child is still alive, then that the
   `.rc` lands afterwards.
   *Note:* it is **not** true that the existing ultra-oracle tests are all
   grep-anchored — `tests/test-ultra-oracle-advisory.sh:37,45,56,66,73` and ~16
   sites in `tests/test-ultra-oracle.sh` invoke `--mode background` for real. They
   poll `.rc` with bounded waits, so §1 does not break them; none asserts
   *non-blocking*, which is why this test is new.
2. **Deadline arithmetic against the real poll.** The poll at `:1059` is
   **unreachable under `--claude-only`**, and the repo has **no precedent** for a
   non-`--claude-only` loop harness — this test establishes one. Required stubs:
   `agy`/`codex`/`grok` on `PATH` returning canned valid JSON immediately, a stub
   `oracle`, a seeded `state.md` via `init-design-review.sh`, and a stubbed clock
   for the backward-step case. Cover: advisory completing inside the reviewer
   window (poll ~0s); deadline expiry; counter backstop firing when the clock steps
   back; and the no-dispatch matrix under `set -u`.
   **CI budget — requires one production change.** The `+ 90` grace is a hardcoded
   literal in both the existing counter and the proposed deadline, so shrinking the
   cap alone still floors each expiry case at ~91s, and two cases exceed the repo's
   ~180s per-test ceiling. Make the grace an overridable constant
   (`ULTRA_ORACLE_RC_GRACE`, default 90) alongside the deadline change in §2, and
   have the test set it to a small value together with a stubbed
   `ultra_oracle_timeout_cap`. Then expiry fires in single-digit seconds; the
   arithmetic under test is the deadline comparison, not wall time.
3. **Status quo preserved.** `.rc` == 0 still yields the advisory block; a timeout
   still yields `WARNING: ULTRA-ORACLE ADVISORY FAILED [...]` with the `#340` hint.
4. `shellcheck` clean on both modified scripts.
5. **Live.** Re-run this review with the oracle enabled and confirm
   `Stale artifacts cleared` → `Phase 1: Launching` collapses from ~31 min to
   seconds.

No test may dispatch a live oracle — CI must never bill it
(`docs/plans/2026-06-30-adr0007-phase5-retrieval-loop.md`).

## Revisit trigger

- If the witness absence rate is re-measured on real design documents and is high,
  reopen #499 — measure first, and prefer "drop it from blueprint" over the detach
  machinery.
- If deadline-expiry-with-a-live-child is observed stranding the shared browser
  mutex and failing a subsequent consult, Residual 1 needs an owner rather than a
  log line.
- If a `--mode background` caller appears that does not capture stdout, re-check
  whether the stdout-only redirect is still sufficient.
