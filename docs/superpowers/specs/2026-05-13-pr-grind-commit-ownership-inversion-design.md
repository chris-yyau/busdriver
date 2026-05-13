# pr-grind Commit Ownership Inversion — Design Spec

> **Status:** Resolved design after brainstorming + grill (2026-05-13). Ready for `/writing-plans`.
> **Input doc:** `docs/plans/2026-05-13-pr-grind-commit-ownership-inversion.md` (council verdict and open questions; preserved as historical artifact).

## Goal

Invert ownership of git commits + litmus iteration in the pr-grind / pr-grinder contract. **Worker prepares staged changes + emits a `RESULT_FIXES` intent statement; dispatcher commits + runs litmus + pushes.** This eliminates the recovery-via-inline machinery (~200 LOC of defensive bridge), removes a contract-induced bail category (`RESULT_BAIL_CATEGORY: tooling`), and directly addresses the documented worker context-exhaustion failure mode (PR #98).

## Motivation

### The load-bearing justification: delete the bridge

`skills/pr-grind/SKILL.md` documents the recovery-via-inline (RECOVERY_INLINE) carve-out as a workaround for a "permanent physical constraint" — the worker subagent allegedly cannot run litmus. The premise is **technically false**:

- Litmus is implemented as bash scripts: `skills/litmus/scripts/init-review-loop.sh` and `run-review-loop.sh`. See `skills/litmus/SKILL.md:108-112` for the documented manual invocation path.
- The `/litmus` slash command is only a UX wrapper for interactive Claude.
- The pr-grinder worker has the `Bash` tool (per `agents/pr-grinder.md` agent definition).
- The pre-commit gate (`hooks/gate-scripts/pre-commit-gate.sh`) only blocks `git commit` Bash calls — it does not block litmus script invocations.

The constraint is **contract-induced**: `agents/pr-grinder.md:570-575` tells the worker to bail with `category=tooling` when litmus blocks, without ever telling the worker that `bash run-review-loop.sh` is available. The existing architecture is a ~200-line defensive bridge built around a constraint that doesn't exist at the runtime layer.

A minimal fix is "teach the worker to run litmus via bash" (option a in the council deliberation). The council surfaced a deeper move: **match the actor to the constraint** — worker prepares the diff; dispatcher owns commit, gate, and push. The bridge disappears.

This is the load-bearing argument. The "fresh context for review" framing — also offered by the council — is rhetorically appealing but fragile to future SDK changes; the simplification argument survives them (see Key Decisions, "Premise rationale framing").

### Empirical motivation: worker context exhaustion

The strongest case for inversion comes from observed behavior, not theoretical critique:

- **PR #98 (claude-mem obs 20550):** Worker subagent bailed mid-context in *both* round 1 and round 2 — exceeding resource limits while addressing multi-reviewer feedback. Operator manually took over the dispatcher role and pushed 4 fix-up commits by hand.
- **The failure mode is context, not litmus loops.** PR #98's bails were resource exhaustion, not gate blocks. The inversion takes work AWAY from the worker (no commit composition, no litmus retries) — directly addressing this exhaustion class.

PRs #100 and #101 corroborate the design's litmus-iteration estimates: PR #100 needed 1 dispatcher-side iteration; PR #101 needed 0. The retry machinery the inversion deletes was over-engineered for the observed failure rate.

## Proposed Architecture

### Worker contract change

Worker (Sonnet, dispatched per round):
1. Resolves PR state, fetches comments, triages findings.
2. Applies fixes to the working tree.
3. Stages files (`git add`).
4. Emits a `RESULT_*` block describing the round (no commit, no push, no litmus).
5. Exits.

No `git commit`. No litmus invocation. No `RESULT_INFLIGHT_CHANGES` / `RESULT_STAGED_FILES` / SHA-256 diff hashes. The worker exits before the dispatcher acts; there is no concurrency window to defend against, so the snapshot block becomes unnecessary.

### Dispatcher contract change

Dispatcher (Opus, per round, after worker returns):

1. Reads `RESULT_FIXES` (worker's intent statement).
2. Initializes the litmus loop: `bash skills/litmus/scripts/init-review-loop.sh`.
3. Invokes litmus **before** any `git commit` (BLOCKING, 21 min timeout per litmus skill contract): `bash skills/litmus/scripts/run-review-loop.sh`.
4. Litmus loop semantics (per `skills/litmus/SKILL.md`'s standard contract — the dispatcher uses the same fix-and-rerun protocol the worker would have used in the legacy path):
   - **Exit 0 (PASS)** — `.claude/litmus-passed.local` marker is written by `run-review-loop.sh` itself (via `write-review-marker.sh`). Proceed to step 5.
   - **Exit 1 (FAIL with actionable findings)** — dispatcher applies the suggested fixes silently, re-stages, returns to step 3. Bounded by litmus's internal max-iterations cap (default 10), tracked in `.claude/litmus-state.md` and enforced by the `run-review-loop.sh` script itself.
   - **Exit 2 (TOO LARGE) or 124 (TIMEOUT)** — bail to operator with `RESULT_BAIL_CATEGORY=judgment`. Worker's diff exceeds litmus's review budget or convergence not reached.
5. Composes the commit message using the safe-interpolation pattern (see Provenance mitigations): `{ printf 'fix: address PR #%s feedback\n' "$PR_NUMBER"; printf '\n%s\n' "$RESULT_FIXES"; } | git commit -F -`.
6. Pre-commit gate (`hooks/gate-scripts/pre-commit-gate.sh`) sees `.claude/litmus-passed.local`, allows the commit through; post-commit hook (`post-commit-consume-marker.sh`) consumes the marker.
7. Local commitlint pre-flight on `HEAD~1..HEAD` (relocated from worker Step 6). On violation, bail to operator for local amend.
8. If litmus auto-fixed files during iteration (HEAD diff exceeds worker's staged path set — comparison done by snapshotting `git diff --cached --name-only` BEFORE step 3 and diffing post-commit), `git commit --amend` to append a `Litmus-Auto-Fix: <one-line summary>` git trailer to the commit body (provenance mitigation #2). Local amend only — commit hasn't been pushed yet. Exact one-line summary format is an implementation detail for the writing-plans phase.
9. Push.

### Mode-uniformity scope (narrow claim)

The inversion equalizes **commit ownership** across subagent mode and inline mode (`--opus`, `--interactive`, `--ci-only`, `--comments-only`). The dispatcher's commit logic SHOULD be a single block called from both code paths so that commit-ownership uniformity is enforced *structurally*, not by convention.

**Out of scope:** other historical subagent/inline divergences — `--ci-only` / `--comments-only` filter behavior, Step 2 branching wiring, Step 6.5 inline ack-ledger details — remain mode-specific and are NOT addressed here. PR #65 (obs 18144) and PR #71 (obs 18249) are case studies in those divergences; addressing them is a separate refactor.

### Provenance mitigations (Codex's commit-laundering concern)

**Risk:** Litmus iteration can mutate the diff (auto-fixes during the review loop). If the dispatcher commits and litmus auto-fixes silently amend, the committed diff no longer matches the worker's `RESULT_FIXES` intent.

**Mitigations applied:**

1. **Commit body cites `RESULT_FIXES` verbatim — via safe-interpolation pattern.** Preserves worker intent in commit history. (Mitigation #1.)
   - **Safe-interpolation invariant (mandatory):** the dispatcher MUST compose the commit message via `{ printf 'fix: ...\n'; printf '\n%s\n' "$RESULT_FIXES"; } | git commit -F -`, mirroring the existing worker pattern at `agents/pr-grinder.md:433-436`. NEVER use `git commit -m "$RESULT_FIXES"`, `eval`, or unquoted variable expansion. `RESULT_FIXES` is free-form worker prose that may contain `$(...)` command substitution, backticks, embedded quotes, or flag-like strings — any of which would be a command-injection or message-malforming regression. The writing-plans phase must include a regression test that submits adversarial `RESULT_FIXES` content (e.g., `$(touch /tmp/bad-bd-test)`, backtick-wrapped commands, embedded quotes) and asserts it is committed as literal text with no side effects.
2. **Litmus auto-fixes annotated as a git trailer line: `Litmus-Auto-Fix: <one-line>`.** Parses with `git log --grep` and `git interpret-trailers`. NOT a separate commit (would inflate PR commit count). (Mitigation #2.)
3. ~~Pre-commit path-set check using `RESULT_FIXES_PATHS` tag.~~ **Dropped** — protocol-purity over speculative defense; no new tags introduced. (See Key Decisions.)

### What disappears

| Item | Currently at | Why it disappears |
|---|---|---|
| `RESULT_INFLIGHT_CHANGES` tag | `agents/pr-grinder.md:572`, `skills/pr-grind/SKILL.md:794` | Worker no longer leaves inflight state |
| `RESULT_STAGED_FILES` / `RESULT_UNSTAGED_FILES` tags | same | Same |
| `RESULT_STAGED_DIFF_SHA` / `RESULT_UNSTAGED_DIFF_SHA` tags | same | No concurrent-mutation window to defend |
| `RESULT_BAIL_CATEGORY: tooling` trigger + handling | `agents/pr-grinder.md:573`, `skills/pr-grind/SKILL.md:258-289` | Litmus no longer a worker bail; dispatcher stops switching on category |
| Worker's snapshot block (~50 LOC) | `agents/pr-grinder.md:579-627` | Snapshot purpose vanishes |
| Dispatcher's RECOVERY_INLINE block | `skills/pr-grind/SKILL.md` (~15 line ranges) | Bridge is deleted, not relocated |
| `--no-recovery-inline` flag | `skills/pr-grind/SKILL.md:1497` | No recovery path to disable |
| `recovery_inline_used_this_round` counter | `skills/pr-grind/SKILL.md:142-143, :182, :637, :664, :668` | No cap to track |
| "Permanent physical constraint" rationale (both copies) | `skills/pr-grind/SKILL.md:263, :674` | False premise no longer cited |

## Scope of Changes

| File | Type of change | LOC delta |
|---|---|---|
| `agents/pr-grinder.md` | Edit Step 6: remove `git commit`, push, and commitlint preflight; replace with "stage + emit RESULT". Remove snapshot block (lines 579-627). Remove `RESULT_BAIL_CATEGORY: tooling` trigger and the "litmus blocks twice" prose. | **~-180** |
| `skills/pr-grind/SKILL.md` | Dispatcher loop pseudocode: insert "commit + commitlint + invoke litmus + push" step after worker returns. Remove RECOVERY_INLINE block entirely. Remove `recovery_inline_used_this_round` counter, `--no-recovery-inline` flag, Bail Triggers `tooling` row. Update RESULT tag list (drop INFLIGHT_CHANGES / STAGED_FILES / UNSTAGED_FILES / DIFF_SHA). Remove both copies of the "permanent physical constraint" rationale. Scope inline/subagent uniformity claim to commit ownership only. | **~-220** + ~30 added for dispatcher-commit block. Net **~-190** |
| `hooks/gate-scripts/pre-commit-gate.sh` | No change. Gate still fires; only the caller changes. | 0 |
| `skills/litmus/SKILL.md` | No change. | 0 |
| Tests (`tests/test-*.sh`) | Update RECOVERY_INLINE tests; add dispatcher-path coverage spanning ~7 distinct scenarios: (a) dispatcher invokes litmus before commit when marker absent; (b) litmus FAIL (exit 1) → dispatcher fix/stage/rerun (silent loop) → PASS; (c) PASS → marker written by run-review-loop.sh → commit consumes marker → push; (d) commitlint failure on `HEAD~1..HEAD` → bail before push (local-only commit, no force-push); (e) `Litmus-Auto-Fix` trailer added when post-litmus HEAD path-set exceeds worker's pre-litmus staged paths; (f) **adversarial `RESULT_FIXES` content** (`$(touch /tmp/bad)`, backticks, embedded quotes) commits as literal text with no command-injection side effects; (g) inline mode (`--opus`/`--interactive`) and subagent mode both invoke the same dispatcher commit block (structural parity, not just behavioral). | **TBD during writing-plans** — the +30 LOC initial estimate is likely an underestimate given the 7 scenarios; actual LOC delta will be sized during plan writing. |

**Net code change: ~-300 LOC** (deletion magnitude increased from the input doc's initial -130 estimate after a cascade-deletion inventory uncovered the bail-category-routing fan-out, the `--no-recovery-inline` flag, the `recovery_inline_used_this_round` counter threading, and the second copy of the "physical constraint" rationale). Per-row totals are best-effort estimates; actual deltas will be finalized during implementation.

## Non-goals

- Changing how litmus itself works (internal iteration cap of 10 remains untouched).
- Changing the pre-commit / pre-PR / pre-merge gate scripts (scripts unchanged; only the caller of the pre-commit gate changes).
- Touching the approver-gap auto-merge flow (PR #94 / PR #100 work — out of scope).
- Re-litigating PR #98 / #100 / #101 design decisions (state-verify, amend bypass, etc.).
- Unifying other historical subagent / inline divergences (Step 2 branching, --ci-only filter behavior, Step 6.5 ack-ledger details). **Commit ownership only.**
- Adding forward-compat for new bail categories (YAGNI; add when needed).
- Adding a STALE_STAGE_RESET crash-safety fallback for "worker crashes after `git add`" (no empirical evidence of the failure mode).
- Adding a new `RESULT_FIXES_PATHS` protocol tag (mitigation #3 dropped per grill).

## Implementation Order

1. **`/writing-plans`** (Phase 2) — produce a task-by-task execution plan with checkbox tracking.
2. **`blueprint-review`** (Phase 2 gate) on the plan.
3. **Implementation** (Phase 3+) via subagent-driven-development or single-coordinator inline.
4. **PR + grind + merge** (Phases 4-6).

## References

- **Input design doc:** `docs/plans/2026-05-13-pr-grind-commit-ownership-inversion.md` (council verdict + open questions; historical artifact, uncommitted)
- **Council lesson:** `~/.claude/notes/lesson-council-2026-05-13-invert-worker-commit-ownership.md`
- **Prior independent analysis:** claude-mem obs 20628 (reached the inversion conclusion in the same session before council convened)
- **Empirical motivation:** claude-mem obs 20550 (PR #98 worker bailed twice mid-context)
- **commitlint pre-push incident:** claude-mem obs 20514 (PR #96 round 1 force-push case)
- **Subagent / inline parity history:** claude-mem obs 18144 (PR #65 system-prompt gap), obs 18249 (PR #71 inline ack-ledger gap)
- **Prior PRs touching this area** (do not re-litigate):
  - PR #98 (`3efb937`) — per-round recovery cap + commitlint + amend bypass
  - PR #100 (`ec01d77`) — state-verify idiom + CWD reset + NO_RECOVERY_INLINE annotation
  - PR #101 (`5997824`) — state-verify retry loop with replication-lag rationale

<!-- GRILL-DECISIONS-BEGIN -->
## Key Decisions (resolved during grilling)

- **Premise rationale framing** — chose (b) simplification, not "fresh context". Rationale: the load-bearing argument is "delete the 200 LOC bridge"; the SDK-constraint-driven "fresh context" rhetoric is fragile to future SDK changes, while the simplification argument survives them.
- **Codex provenance mitigation #3 (path-set assertion)** — chose (b) drop entirely. Rationale: YAGNI applied retrospectively; eliminates the only new protocol tag (`RESULT_FIXES_PATHS`), making the design purely subtractive at the protocol level.
- **Codex provenance mitigations #1 + #2 format** — chose (a) keep both, format #2 as git trailer line (`Litmus-Auto-Fix: <one-line>`). Rationale: trailer-line form parses with `git log --grep` / `git interpret-trailers` tooling at zero added cost; #1 and #2 address distinct provenance concerns (worker intent vs litmus mutation), both nearly free.
- **STALE_STAGE_RESET crash-safety fallback** — chose (b) drop entirely. Rationale: no empirical evidence of "worker crash after git add but before RESULT emission" across PRs #98/#100/#101; YAGNI; solo operator can recover via one `git reset HEAD --` if it ever occurs.
- **Litmus iteration cap (dispatcher-side)** — chose (c) N=1 for the **outer worker-dispatch attempts per round**; the **inner litmus fix-and-rerun loop** uses the litmus skill's standard contract (default 10 iterations tracked in `.claude/litmus-state.md`, enforced by `run-review-loop.sh` itself). Rationale: on exit 1 with actionable findings, the dispatcher applies fixes and reinvokes per the standard litmus skill protocol — same fix-and-rerun loop the worker would have used in the legacy path. On exit 2 (TOO LARGE) / 124 (TIMEOUT) / inner-cap-reached, bail to operator with `RESULT_BAIL_CATEGORY=judgment`. PR #100 needed 1 dispatcher-side litmus invocation; PR #101 needed 0. Empirical baseline supports a tight outer-loop cap of 1 paired with the standard inner cap of 10.
- **Inline-mode uniformity claim scoping** — chose (a) scope honestly to commit ownership only. Rationale: PR #65/#71 history shows subagent/inline divergences exist for reasons unrelated to commit ownership; overclaiming "modes become identical" risks repeating the parity-gap bugs that broke growth-engine PR #44.
- **Migration path and version-skew guard** — chose (a) hard cutover; drop the version-skew guard. Rationale: inverted dispatcher no longer switches on `RESULT_BAIL_CATEGORY` (recovery-via-inline disappears), so the guard defends against nothing live; plugin atomically updates dispatcher SKILL.md and agent files together via semantic-release.
- **commitlint pre-push check** — chose (a) keep, relocate from worker Step 6 → dispatcher commit path. Rationale: PR #96 round 1 incident (169-char body line → CI catch → operator-authorized force-push) is documented prevent-history; subtractive ethos applies only to layers without empirical justification, and this layer has it.

<!-- design-hash: sha256:ecd38749d28f8b4b18793e11a558fdddc33f96e6d181fb994b80b8eefdd47aed -->
<!-- grill-status: complete -->
<!-- GRILL-DECISIONS-END -->

<!-- design-reviewed: PASS -->
