# ADR 0031 — Pre-implementation gate: relieve the deadlock with a leased skip and a recorded exit, not by narrowing scope

- **Status:** Accepted
- **Date:** 2026-07-29
- **Issue:** #519 (four composed design issues observed over a real multi-hour session on `busdriver@1.100.3`)
- **Relates:** **ADR 0017** (repo-wide blast radius is intrinsic — this ADR upholds it), ADR 0016 / #325 (gate env containment; consent is authenticated by location, not content), #355 (degraded-coverage PASS withholding), #405 / `scripts/design-clear.sh` (the audited release path), ADR 0006 (command-text matching is not the security boundary)

## Context

#519 reported that an **approved** plan can become permanently unimplementable, with
marker deletion as the only exit. It correctly identified that no single choice is a
bug — the deadlock comes from four defensible choices composing:

1. Blocking scope is repo-wide; the unit of work is per-plan.
2. No terminal state for "approved under degraded reviewer coverage" (#355 withholds
   the PASS when fewer than 3 lenses are fulfilled, and both `codex` and `grok` were
   failing at runtime).
3. The skip file is single-use, but implementing one approved sub-plan takes ~10 gated
   writes — so the hatch cost ~10 operator `touch` cycles, each with a 30s wait.
4. `FILE_MOD_PATTERNS` regexes the raw command string, so `re.search` matched inside
   quoted operands and blocked read-only commands.

The issue ranked (1) highest-impact and proposed scoping the block to an
operator-declared active plan via `$STATE_DIR/current-implementation.local`.

## Decision

**Ship items 2, 3 and 4. Decline item 1 — do not narrow the block scope.**

The composed pain is real and is fixed, but through the *cost* of the escape hatch and
the *quality of the audit trail*, never through what the gate blocks.

### Why item 1 is declined

ADR 0017 settled — via council, on this exact question — that the repo-wide blast
radius is correct fail-CLOSED behaviour, with a narrow revisit trigger: a **trusted,
non-author-controlled** source of the design-doc→impl-file relationship, e.g. a
committed, separately-reviewed manifest. No such source exists in-tree.

#519's proposal is a genuine improvement on the shapes ADR 0017 rejected — it is
explicit that the pointer must be operator-set rather than plan-declared, which
correctly avoids letting an author declare their own gating scope. But it does not
clear the bar, for one reason: **the authenticator is a `.local` file, and any
Bash-holding session can create one.** The gate cannot distinguish an operator's
pointer from an agent's. So a session blocked by plan B's pending review can point
`current-implementation.local` at any already-approved plan A and resume writing —
which is a fail-OPEN on plan B. That is option B's failure mode from ADR 0017
(implementation proceeds while review is pending) reached by a different route, and it
is a *general* bypass primitive rather than an occasional leak.

The `.local` convention is load-bearing for *one-shot, logged, expiring* consent
(the skip files). It is not load-bearing for a *persistent scope declaration*, which is
strictly more powerful: a skip file authorizes N writes and then dies, whereas a scope
pointer silently re-authorizes every future write that falls outside the declared plan.
ADR 0016 / #325 is the governing precedent — consent is authenticated by *location*,
and a persistent value-based switch is the shape that keeps proving injectable.

### What replaces it

#519's own text says item 1 "makes 3 far less painful". The converse is the cheaper
half of that relationship and is what this ADR takes: **a proper lease makes item 1
unnecessary**, because the deadlock was never really about scope — it was about an
escape hatch too expensive to use correctly, which pushed operators toward the worse
exit (deleting the gate's audit trail).

- **Item 3 — the skip file is a lease.** One operator `touch` now authorizes 20 gated
  writes inside a 3600s window instead of exactly one, and **every use appends to
  `bypass-log.jsonl`** recording the slot it claimed and the ceiling. That is enforced, not merely stated: a
  use whose audit append fails is refused and its slot returned, the same rule
  `design-clear.sh` applies ("an unlogged release is not a sanctioned bypass"). Uses are
  immutable `<mtime>.<n>` slots claimed with `mkdir`, never a mutable counter, so
  concurrent gates cannot both read *k* and both write *k+1*; a lease that cannot be
  recorded is refused outright, because unbounded-because-unrecordable is exactly the
  fail-open a tolerant write path would introduce. This is strictly *more* audit signal
  than before, where the pressure-release valve was an unlogged `rm` of a token. The
  ≥30s anti-self-bypass floor and the #325 repo-controlled rejection are unchanged; a
  lease does not need them relaxed, because re-touching to extend a lease also resets
  the 30s clock and is therefore refused. The lease is additionally spent **only by
  genuinely-gated operations** — it is now evaluated after tool classification and
  every allowlist, so a read-only `ls` or a write to an exempt path no longer burns it.
  That closes the "any intervening tool call can consume it" sharp edge, which was the
  most surprising part of the original report.

- **Item 2 — a recorded exit, not a destroyed trail.** `design-clear.sh` already was
  the sanctioned audited release (ADR 0017's stated follow-up), but the gate's own
  block message still invited `rm '<token>'`, so operators followed the message. The
  message now names `design-clear.sh`, and the `design-marker-cleared` event records
  the doc's own-line review-coverage marker verbatim alongside the existing
  `confirmed: tty | no-tty-assumed-yes`. The trail now answers #519's question —
  *which lenses were absent, and who accepted the residual* — without a new gate
  outcome and without relaxing #355. A control that forces you to destroy its own
  audit trail to proceed is worse for auditability than one that lets you proceed with
  a recorded caveat.

- **Item 4 — token-level file-mod classification.** `lib/cmdword.py` segments and
  tokenizes before deciding, comparing token basenames for equality. A verb inside a
  quoted operand survives as one token (`rm |mv |truncate`) and matches nothing, while
  `sudo rm -rf src` still matches because the verb is a real token. This mirrors the
  anti-forge detector's existing rm/tee handling in the same file. On an unparseable
  command it falls back to the original regexes, which are strictly wider — so the
  failure mode is the old behaviour, never a new over-block, and never a fail-open.
  Per ADR 0006, command-text matching here is not the security boundary anyway; the
  false positives were training a bypass reflex (reword until the regex stops matching)
  that the gate exists to suppress.

### Amendment to ADR 0006's wrapper residual

ADR 0006 documented wrapper-hidden indirect writes (`sudo touch <marker>`) as an
accepted residual of the marker-forge detector, on the reasoning that a cooperative
agent has no reason to reach for them. **#519 closes that half of the residual** — the
detector now peels wrapper preambles before choosing the command word.

The reasoning did not survive the new gate state this ADR introduces. Once the skip
LEASE ledger and `bypass-log.jsonl` are themselves protected, `command rmdir <slot>`
resets the 20-use ceiling and `env truncate <log>` erases the audit trail, and both were
reachable by exactly that wrapper shape while the classifier downstream still called
them modifications. A residual that is the *easiest* path is not a residual.

Concretely, the detector now peels wrapper preambles (`sudo`/`env`/`command`/`builtin`/
`timeout`/`xargs`/...), shell reserved words and grouping (`if`, `{`, `coproc`), and it
recognises `find -exec`/`-delete` plus verbs embedded in an `env -S` program (separated,
attached, and quoted spellings). Where a wrapper is present it scans every word rather
than pinning the command word, because enumerating which wrapper flags take an operand
is a table that fails OPEN wherever it is wrong.

**Where the line now sits.** The **execute-a-string class remains the documented ADR 0006
residual**: `eval`, `sh -c`, `python -c`/`perl -e`/`node -e`, command substitution, and
runtime name synthesis (globs, brace expansion). Anything that can `eval` can forge a
marker directly, so blocking a subset is theater against that actor — and the file
already records that building a shell parser *inside* the forge detector was tried and
rejected, because every iteration opened a new segment-split bypass.

What changed is only the *cost/benefit at the easy end*: the wrapper forms are one token
away from an ordinary command and became reachable paths to reset the lease ceiling or
erase the audit trail, so they are no longer residual. The eval class is unchanged, and
future reports of the shape "verb X reachable through arbitrary-string interpreter Y"
should be closed as ADR 0006 residual rather than chased.

`tests/test-pre-implementation-gate.sh` pins the new behaviour where it previously pinned
the residual; the quoted-`env -S` case lives in `tests/test-impl-gate-scope-519.sh`,
whose harness builds payloads with `json.dumps`.

## Consequences

- The repo-wide block stands. Editing any `docs/plans|specs/*.md` or `*-design.md`
  still re-arms review and blocks implementation repo-wide. ADR 0017 is unamended.
- A stalled multi-plan repo is no longer a deadlock in practice: one operator `touch`
  covers a whole sub-plan's implementation, and `design-clear.sh` releases a single
  token with a record.
- Bypass volume in `bypass-log.jsonl` will rise, by construction — each lease use is an
  event where previously there was one event per skip file (and zero for the `rm`
  path). That is the intended trade: visible, attributable bypasses over invisible ones.
- 20 uses / 3600s are heuristics, not derived limits. They are meant to cover one
  approved sub-plan comfortably and nothing more.

## Revisit trigger

- Reopen **item 1** only under ADR 0017's existing trigger — a committed,
  separately-reviewed plan→target manifest, or an out-of-process operator-held
  capability that a Bash-holding session cannot forge. A future `.local`-authenticated
  scope pointer is the same rejected shape and should be closed as churn.
- Revisit the lease bounds if `bypass-log.jsonl` shows leases routinely exhausting
  (20 is too low) or leases regularly expiring unused (3600s is the wrong window).

## Settling check (what would refute the decision)

For the declined item: create `current-implementation.local` naming an approved plan A
while plan B is still pending, then attempt an implementation write. If the write is
**allowed**, the pointer is a proven bypass of B's review. True by construction while
the pointer is an agent-writable file — which is the reason it is declined rather than
shipped.

For what shipped: the guard must be observed both passing and failing.
`tests/test-impl-gate-scope-519.sh` drives the real gate against a real armed marker
and pins both directions — read-only commands mentioning a verb are allowed, wrapper-
hidden real writes still block, the unparseable path still blocks, the lease grants
repeated uses but exhausts and expires, the ≥30s floor still refuses a fresh file, and
read-only/exempt operations do not spend a use. The suite fails if the fixture stops
blocking, so the assertions cannot pass vacuously.
