# ADR 0017 — Design-review marker: repo-wide blast radius is intrinsic; do not narrow the block

- **Status:** Accepted
- **Date:** 2026-07-18
- **Issue:** #394 (blast-radius root cause), follow-up to #356 (report + two live incidents), #391 (visibility half, shipped)
- **Relates:** ADR-D / `docs/plans/2026-07-13-task2-worktree-design-marker.md` (the worktree-safe marker architecture this ADR constrains), #347 (existence-keyed anti-forge token), ADR 0012 / ADR 0016 ("operator-owned, audited bypass over content/metadata trust" — the same reasoning this ADR applies)

## Context

The design-review gate is **fail-CLOSED, existence-keyed, and repo-wide**. When a
design doc is edited — basename `PLAN|DESIGN|ARCHITECTURE*.md`, or any `.md` under
`docs/plans/` or `docs/specs/` (`check-design-document.sh:143,152`, mirrored in
`marker_ops.py`) — a "pending review" token is armed into a marker directory keyed to
the repo's **shared git-common-dir**. The classifier (`marker_ops.py::_classify_tokens`)
is existence-keyed: if **any** token exists anywhere, the pre-implementation gate blocks
**all** Write/Edit/Bash implementation writes across **all** linked worktrees.

The repo-wide scope is **deliberate and load-bearing** (ADR-D): a plan authored in the
main worktree must govern implementation done in a separate linked worktree, so the
pending signal has to be visible where the implementation commit happens — which is not
the worktree that armed it.

**The felt problem (#356, two live incidents):** an unrelated docs edit in worktree A
arms a marker and halts unrelated security work in worktree B. Both incidents cleared
only by a human deleting the marker file. #391 shipped the *visibility* half (the block
message now names the arming worktree/branch); this ADR addresses the remaining ask —
reduce the blast radius itself.

The token body records the pending design doc's normalized abspath, but **nothing about
which implementation files that doc governs**, nor which worktree armed it. So the block
is unconditional and global. That is the serialization root cause.

## Decision

**Do not narrow the block scope. Keep repo-wide fail-CLOSED blocking. Reduce the felt
pain by making marker *clearing* cheap and audited, never by narrowing what blocks.**

This was decided via `busdriver:council` (issue #394 explicitly asked for council/ADR
before any gate-semantics change). Four voices convened (Architect, Skeptic, Critic,
Researcher; Pragmatist unavailable). The council overrode the Architect's initial
proposal (a `design-scope` marker).

The governing principle: **scoping a fail-CLOSED gate by metadata that lives in the very
artifact the gate is currently gating as unreviewed is a bypass primitive, not a scope
fix.** The block fires *pre-review*, so any author-controlled scope declaration is
untrusted by construction — an author could declare a narrow/bogus scope and implement
freely, defeating the gate. Anti-forge (#347) is meaningless if the author controls
*where* the marker applies, even if they cannot delete it.

Prior art corroborates: CODEOWNERS, pre-commit `files:`, Semgrep path scoping, Bazel
visibility, and Nx/Turbo "affected" all derive gate scope from the **diff** or from
**already-committed (already-reviewed) config** — never from the unreviewed artifact that
armed the lock.

## Options considered and rejected

| Option | Why rejected |
|--------|--------------|
| **A — Scope block to files the design doc names/governs** | The doc is unreviewed when the block is active; extracting targets means parsing author-controlled content (a parser that becomes its own attack surface), and any target the parse misses → impl proceeds unreviewed (**fail-OPEN on under-declaration**). |
| **B — Scope block to the same worktree that armed the marker** | Breaks the plan-in-main → implement-in-worktree flow ADR-D exists for; worse, it *permits* implementation from another worktree while review is pending (visible over-block traded for **silent fail-open**). |
| **C — Trigger arming on design *content* rather than filename** | "Design content vs. prose" is a heuristic; every false negative is a fail-open on a security gate. When an edit cannot be confidently classified harmless without interpreting author content, the fail-CLOSED answer is to arm — which is today's behavior. |
| **Proposed default — `<!-- design-scope: <glob> -->` marker, fail-CLOSED to repo-wide when absent** | The Architect's own proposal; the council's strongest dissent (Critic) showed it is not an occasional leak but a **general bypass primitive** — declare `design-scope: harmless/**`, write elsewhere. Fail-CLOSED on *absence* still fails-OPEN on a *narrow lie*. Disqualifying. |
| **Let the arming session drain its own marker** | Directly contradicts the existence-keyed anti-forge design (#347): draining your own unreviewed design doc's marker *is* the forgery the gate prevents. |

## Consequences

- **Blast radius stays.** Editing any `docs/plans|specs/*.md` or `*-design.md` re-arms
  review and blocks all implementation repo-wide until the doc is reviewed (or the token
  is cleared). This is accepted as the correct fail-CLOSED behavior, not a defect.
- **Follow-up (separate, non-gating):** an audited fast-clear helper (`design-clear` —
  remove the specific pending token + confirm + one `bypass-log.jsonl` event) is the
  sanctioned way to relieve the pain. It does not weaken the gate: clearing remains a
  deliberate, logged human action, symmetric with the `skip-*.local` operator escape
  hatches. Tracked as the actionable remainder of #394; this ADR does not itself ship it.
- **Do not reopen scope-narrowing as churn.** Any future "reduce blast radius" proposal
  that reads scope from the design doc, the arming worktree, or a content heuristic is
  re-deriving a rejected fail-open. Derive from the diff or committed config, or improve
  the clear path — nothing else.

## Revisit trigger

Reopen only if a **trusted, non-author-controlled** source of the design-doc→impl-file
relationship appears (e.g. a committed, separately-reviewed manifest mapping plans to
target paths), OR if a second operator/real multi-tenant threat model changes the
solo-operator assumptions. Absent that, the decision stands.

## Settling check (what would refute the decision)

Inject a pending token whose design doc declares a narrow scope (`design-scope: docs/**`)
and attempt an implementation Write outside that scope. If the write is **allowed**, the
scope-narrowing approach is a proven bypass. True by construction here (the block is
pre-review and the author owns the doc), which is precisely why scope-narrowing is
rejected rather than shipped.
