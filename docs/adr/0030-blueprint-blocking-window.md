# ADR 0030 — The blueprint loop's blocking window is the UltraOracle dispatch, not the k3 reap

## Status

**Accepted (2026-07-27).** Resolves [#499](https://github.com/chris-yyau/busdriver/issues/499)
by rejecting its proposed fix, and implements
[#501](https://github.com/chris-yyau/busdriver/issues/501). Supersedes, in part,
[ADR 0027](./0027-k3-mechanism-witness-ultimate-tier.md)'s Bash-cap rationale for
the `BLUEPRINT_AUDITOR_TIMEOUT` clamp (the clamp itself stands).

## Date

2026-07-27

## Context

#499 reported that the blueprint review loop cannot fit the Bash tool's 600s
ceiling, attributed this to the Mechanism Witness reap (`BLUEPRINT_AUDITOR_TIMEOUT
+ 10`, hard-clamped 610s), and proposed dispatching k3 detached so the loop would
stop waiting on it.

Ten rounds of blueprint review (three external reviewers plus a fresh `opus`
arbiter each round) established that **both premises were wrong**, and produced
three measurements that changed the diagnosis.

**1. `--mode background` did not background.** `ultra_oracle_consult`'s disowned
subshell closed with a bare `) &` — no subshell-level redirect — so the child
inherited the caller's stdout, and both call sites capture that stdout in `$( )`.
Command substitution reads until every writer closes the pipe, so the "background"
dispatch blocked for the consult's whole lifetime. Measured gap between
`Stale artifacts cleared` and `Phase 1: Launching` — pure serialization before any
review work: **4 min, 31 min, 31 min** across three rounds, against reviewers
taking 460–498s.

**2. The 600s ceiling is not a kill boundary.** #499's stated harm was a loop
"killed mid-reap, which writes no verdict at all". Observed twice: a 590s-timeout
invocation was *moved to the background* by the harness and ran to completion
(`exit code 0`) with a full arbiter prompt. It is a foreground-wait boundary.

**3. k3 was landing.** Across six rounds the witness ran in four and failed in two
(`unparseable`, `rc=124`). It runs concurrently with ~500s of reviewer time and
consumes its budget inside that window.

A fourth fact reframed the value of any fix: the child's *last* statement is the
atomic `.rc` rename, so `.rc` already exists when the capture returns. The
post-reviewer poll therefore cost ~0s, and the oracle had to finish before the
arbiter either way. Restoring parallelism recovers only the **overlap**.

## Decision

**Fix the term that binds; leave k3 alone.**

1. **Redirect the background subshell's stdout** (`scripts/lib/ultra-oracle.sh`).
   `) </dev/null >/dev/null &`. stdout only — stderr is not captured, does not hold
   the pipe, and is the sole carrier of the stale-browser-lock recovery pointer.
   `</dev/null` because blueprint-review runs with piped stdin under agent
   invocation.

2. **Route the child's stderr to a sidecar and actually surface it.** The child
   writes to a dedicated `"$out.dispatch.err"` (not inherited — that would hold an
   enclosing capture open; not `/dev/null` — that loses the `rm -f '<lockfile>'`
   instruction for a mutex with **no auto-reclaim**; not `"$out.err"` — the
   watched/blocking paths truncate that for oracle's own output). The blueprint
   loop clears the sidecar at dispatch and, when non-empty, prints it via
   `log_warning`. The console is the only channel the operator reads during a run:
   the existing FAILED banner reaches the **arbiter prompt** only (#502), so
   folding the pointer in there would have left it invisible — the first attempt
   at this fix did exactly that and was caught in review.

3. **Anchor the `.rc` poll to an absolute deadline captured at dispatch**, keeping
   the existing iteration counter as a clock-independent backstop. Both bounds are
   required: the deadline credits the concurrent reviewer time (without it a
   now-genuinely-parallel consult would charge a *fresh* `cap + 90` on top of the
   reviewer window — worse than before the fix), and the counter survives a
   backward wall-clock step, which `date +%s` does not and `$SECONDS` does not
   either.

4. **`ULTRA_ORACLE_RC_GRACE` is sanitized and shorten-only**, mirroring the sibling
   `BLUEPRINT_AUDITOR_GRACE`: it is repo-injectable via a committed `settings.json`
   `env` block (#325 / ADR 0016) and it bounds a wait.

5. **Correct the timeout documentation** in `blueprint-review/SKILL.md` (`:42`,
   `:174`) and `council/SKILL.md` (`:251`). The council contract is now stated as a
   **formula** (`cap + 90 + LAUNCH_WAIT_SECONDS`), because pinning a number
   under-sizes it for any raised cap and re-creates #477 Cause 1.
   `blueprint-review/SKILL.md:28` ("BLOCKING bash call") is **deliberately
   unchanged** — it is a mechanism, not advice: while the call blocks, the session
   cannot write `claude.json`, and the loop consumes any `claude.json` it finds and
   stamps PASS on it.

6. **k3 is untouched.** No detach, no lease, no trust guard;
   `BLUEPRINT_AUDITOR_TIMEOUT` stays default-and-clamp 600s.

## Alternatives considered

- **Detach k3 (the #499 proposal).** Rejected. Two review rounds took it from 14
  findings to 25 (1 → 5 high), each round invalidating the previous round's fix:
  `auditor-raw.txt` is re-opened *by pathname* after `execute_review` returns, so
  the per-round `rm -f` added to block symlink planting breaks any dispatch that
  crosses a round; `gate_skip_file_repo_controlled` performs **no** `GIT_*`
  sanitization, so the proposed trust guard lacked the property it was chosen for;
  and the perl fallback in `_portable_timeout` reparents its child to init, so the
  proposed `pgrep -P` tree-kill can never reach a TERM-ignoring process. Surviving
  review would have needed a `mkdir` lease with ownership nonce and stale reclaim,
  a child-owned raw path, a repo-controlled-artifact guard, a no-symlink component
  verifier, a new TERM/grace/KILL walk that still cannot bound the perl path,
  design-identity stamping, an artifact TTL, and a re-dispatch cap — roughly ten
  new failure modes on the **gate of record**, for a non-gating auxiliary. And it
  does not deliver its headline benefit: with the oracle enabled the loop still
  exceeds 600s after k3 is detached.
- **Drop the blueprint witness, keep k3 in ultimate-council only.** Still open.
  Deferred because the lens found a real defect both Codex-xhigh and the Opus
  backstop missed; the 4-ran/2-failed record argues for re-measuring first.
- **Lower `ultraOracle.timeoutCapSeconds` so the loop fits 600s.** An operator
  lever, not a defect fix; documented as such.
- **Kill the consult on deadline expiry.** Rejected — that is precisely what
  strands the browser mutex.

## Consequences

- The consult runs parallel to the reviewers instead of serially ahead of them,
  returning `min(oracle, reviewers)` ≈ **4–8 minutes per round** — the overlap, not
  the 31-minute block.
- The poll stays bounded at `cap + 90` **from dispatch**, so the change cannot make
  the tail worse than before it.
- `ultra-oracle-run.sh` (the council expert witness) gets the same parallelism for
  free; its bounded `cap + 90` poll starts working as designed instead of being
  bypassed by a blocking dispatch. `ultra-oracle-consult-run.sh` is unaffected —
  every in-tree caller passes `--mode blocking`.
- A latent corruption channel closes: the dispatch-status comparison is an exact
  match on `dispatched`, so any stray byte on the child's stdout previously
  disabled the poll silently.
- ADR 0027's clamp stands; one of its two rationales is retired.

### Residuals (accepted)

1. ~~**Deadline expiry with a live child strands the browser mutex.**~~ **FIXED
   during review.** `disown` does not `setsid` — measured, parent and child shared
   a pgid — so a harness group SIGTERM reached the consult, and killing it before
   it released the shared browser mutex stranded that lock with no auto-reclaim.
   Pre-existing, but this change widened the window (the child is now alive across
   the reviewer phase and the arbitration pause), so it is fixed here rather than
   deferred: `set -m` around the launch makes the background job a **process-group
   leader**, so a group signal no longer reaches it (measured: child pgid ≠ parent
   pgid). Job control is restored immediately after the launch so monitor-mode job
   notices cannot corrupt the `dispatched` token on stdout.

   Deliberate trade-off: an interrupted review now leaves the consult running to
   its own cap instead of stranding a lock that wedges **every** oracle surface
   until cleared by hand. Bounded background work is the cheaper failure.
2. **Late advisory splice on `--claude-only`.** A child landing after expiry can
   write `.rc` during the arbitration pause; the resume then rebuilds the arbiter
   prompt with an advisory the already-written verdict never saw. Nothing detects
   it — verdict freshness binds only `run_id` + `spec_hash`. Non-gating.
3. **Expiry is invisible to the operator** — the FAILED banner reaches only the
   arbiter prompt, never the console. Filed as
   [#502](https://github.com/chris-yyau/busdriver/issues/502); kept a follow-up
   rather than a prerequisite because Decision 2 makes recovery reachable.
4. **The perl-fallback orphan** (`_portable_timeout` exits without reaping) —
   pre-existing, recorded in #501.
5. **An enclosing tool capture is still held while the child runs.** Redirecting
   the subshell's three std fds releases the `$( )` capture of
   `ultra_oracle_consult` — the #501 defect — but **not** a caller that captures
   stdout *and stderr* of the whole invoking shell (which is what a Bash tool call
   does). Measured against a 6s stub child: the hold is **identical (6s) for
   stderr→file, stderr→/dev/null, and no redirect at all**, so the holder is some
   other descriptor on the attach/watched path, not the subshell's own std fds. No
   redirect at this site can fix it. Consequence: if a consult outlives the loop,
   the enclosing tool call stays open until the child exits — bounded by the
   consult's own cap. The behavioral test deliberately does **not** assert this,
   because it would be a guard failing for a reason the code under test cannot
   control. Needs its own investigation; not in scope for #501.

   The child's stderr nonetheless goes to a dedicated `"$out.dispatch.err"` rather
   than being inherited or discarded: it preserves the stale-lock recovery pointer,
   and it does not collide with `"$out.err"`, which the watched/blocking paths
   truncate for oracle's own output.

## Revisit trigger

- If the witness absence rate is re-measured on real design documents and is high,
  reopen #499 — measure first, and prefer dropping the witness from blueprint over
  the detach machinery.
- The k3 reap has the **same defect the oracle poll had**: its counter is
  initialised *after* the reviewer `wait`s, so a slow witness charges a fresh ≤610s
  budget on top of the reviewer window. Deliberately out of scope here; the same
  deadline treatment would fix it.
- If deadline expiry is observed stranding the browser mutex in practice, Residual
  1 needs an owner rather than a log line.
- If a `--mode background` caller appears that does not capture stdout, re-check
  whether the stdout-only redirect is still sufficient.
