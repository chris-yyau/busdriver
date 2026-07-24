# ADR 0024 — Deterministic warn-only (not fail-CLOSED block) when a Codex-active-or-force-on repo merges with `none` Codex

## Status

**Accepted (2026-07-22).** Decision: **D-lite** — a non-gating missing-Codex
warning surfaced from `pre-merge-gate.sh` on every allow path. Full fail-CLOSED D
was considered and **rejected** (see Alternatives). From the PR #444 investigation
(issue #450); the C / D-lite / D choice went to a 5-voice council (unanimous
D-lite) and two rounds of three-tier blueprint review.

**Altitude note (review iteration 2).** The first drafts over-specified the
mechanism (exact `--json` fields, byte-level watchdog snippet, `timeout`-vs-python,
budget seconds, gate line numbers) and blueprint review kept — correctly —
flagging prose that drifted from the real code. This ADR now records the
**decision, rationale, and invariant constraints**; the **exact mechanism is the
implementation PR's to determine and litmus's to verify against live code**. Two
factual corrections the review surfaced are folded in below (the `timeout`
availability reversal and fork-PR target resolution), and the withdrawn ADR 0012
argument stays withdrawn.

## Context

ADR 0013's `none`-nudge posts `@codex review` when Codex
(`chatgpt-codex-connector`) never auto-engaged on a PR a Codex-active repo expects
it to. Two firing points:

1. **Effective — `skills/pr-grind/SKILL.md` COMPLETION block.** Posts the nudge,
   *waits* on a bounded poll (`PR_GRIND_CODEX_GRACE_SECS`, default 480s), re-polls,
   and only then lets the grind declare clean — **and already surfaces a
   missing-Codex warning on `none` after the grace expires.** This is the only path
   where the nudge gates: Codex reviews *before* merge.
2. **Backstop — `hooks/gate-scripts/codex-nudge-premerge.sh`.** A NON-GATING
   PreToolUse hook on `gh pr merge`: posts the nudge, then `exit 0`; the merge
   proceeds immediately.

**The measured problem.** Firing at merge-intent and proceeding is too late.
PR #419 (GitHub-API-verified): nudge `18:43:26Z` → merged `18:43:31Z` → Codex review
`18:48:24Z` — ~5 min after merge, on a closed PR. A post-merge review gates
nothing.

**Why PR #444 slipped both.** #444 modified 5 gate-script files, so
`pre-merge-gate.sh` took its **bootstrap-merge bypass** (gate-modifying PRs trust
CI instead of the cached gate) — allowing the merge **without** the pr-grind-clean
marker, so path 1's nudge+wait+warn never ran. Path 2 (non-gating) was the only
trigger, and it's too late by construction. Result: Codex active + force-on marker
+ `none` on #444, ~55-min window, **no `@codex review` ever posted** (verified: no
comment, zero engagement).

The **bootstrap-bypass and skip-pr-grind** merge shapes share this: they reach
"allowed to merge" without pr-grind's COMPLETION, and the only backstop fires too
late. **This is a visibility gap, not a safety gap** — Codex is not a required
status check, and the operator sees every merge's output.

## Decision

Surface a **non-gating** missing-Codex warning from `pre-merge-gate.sh` — the one
authority that fires on the `gh pr merge` invocations the gate already parses, on
**every allow path** it reaches. (It inherits the gate's existing command-detection
coverage: obfuscated/aliased/`gh api`/web/merge-queue forms that bypass the gate's
pre-filter are out of scope here exactly as they are for the rest of the gate.) The
**firing point** is deterministic (the gate); the **detection** is best-effort (an
external, flaky signal). The two must not be conflated.

The gate has **three substantive allow sites** — operator skip, pr-grind-clean
marker + CI, and the bootstrap bypass. `--admin` is not a distinct site; it is a
merge *shape* that still exits through one of the three. Today each of these sites
is an independent `exit 0` with no shared code path (`pre-merge-gate.sh` has over a
dozen separate allow exits). The implementation MUST first consolidate the three
substantive allow sites into a **single allow epilogue** — a shared code path all
three fall through to before their `exit 0` — and emit the warning **there** (deny
paths never reach it), so a future allow site inherits it and no branch
double-emits. This consolidation is part of the implementation's scope, not
existing infrastructure the implementation can assume.

On a Codex-active-or-force-on repo, when best-effort detection returns **`none`**
(zero Codex engagement on the PR) and the kill switch is unset, the epilogue
surfaces one operator-visible advisory, e.g.:

> ⚠️ Codex is ACTIVE on this repo but has not engaged on PR #NNN — merging without
> Codex engagement. To wait for one: post `@codex review` and re-run /pr-grind.

Then it runs the pre-existing `exit 0`. It never posts, never waits, never blocks.

**Relationship to the existing COMPLETION warning.** Path 1's COMPLETION warning
fires only for **auto-detected active** repos (`CODEX_REPO_ACTIVE=1`); this gate
warns for **active OR force-on**. So on a pr-grind-clean PR: for an *active* repo
that stayed `none`, the gate may emit a *second* (idempotent, harmless) copy of the
same signal; for a **force-on-only** repo the marker path has no COMPLETION
warning, so the gate is the **sole** surface even there. Its primary unique value
remains the **bootstrap/skip** shapes, where COMPLETION never runs at all. This ADR
does not change path 1.

## Invariant constraints (the implementation MUST satisfy; mechanism is the PR's)

These are the properties blueprint review and litmus will hold the implementation
PR to. The *how* (exact commands, JSON fields, budgets, dedup) is decided there and
verified against live code — not pinned in this ADR.

1. **Never blocks — enforced by construction, not assertion.** `pre-merge-gate.sh`
   runs `set -euo pipefail` with an ERR trap that emits `{"decision":"block"}`. The
   entire detection MUST be isolated so it can never propagate a failure to that
   trap (a bounded child whose nonzero exit is swallowed and whose only stdout is a
   tri-state `engaged|none|unknown`/`warn|silent`). Fail mode is silence, never a
   block. **Test:** a hung/erroring detection leaves the gate's original exit status
   intact and emits no `{"decision":"block"}`.

2. **Bounded within the outer budget.** The gate is capped by an outer harness
   `timeout` on every allow path and already does network work (`gh pr checks`).
   The detection MUST be time-bounded strictly inside that outer cap, with **no
   `gh`/`graphql`/`jq` call running untimed or outside the bounded child**. The
   implementation selects a bounding mechanism it **verifies is present** at gate
   runtime and falls back to silence if none is. *(Nuance the review surfaced: do
   NOT assume `timeout` exists. `lib/sanitized-gate.sh` rebuilds PATH from a fixed
   allowlist that includes `/opt/homebrew/bin` **if that dir exists**, so
   `timeout`/`gtimeout` is reachable only where Homebrew coreutils is installed —
   present on the maintainer's host, not guaranteed on stock macOS. This does
   reconcile iteration 1's "`timeout` absent under `env -i PATH=/usr/bin:/bin`"
   with iteration 2's "available": both are true depending on the PATH layer and
   whether coreutils is installed — hence "verify, don't assume.")*

3. **Fail toward silence.** Timeout, API error, missing tool, unresolvable target,
   or kill-switch → `unknown`/`silent` → no warning, allow. Only a *positive*
   active/force-on **and** a *positive* `none` warns.

4. **Kill switch wired.** `PR_GRIND_CODEX_RETRIGGER=0` must actually reach the gate.
   `hooks/hooks.json:67` does not pass it through `env -i` (only the nudge
   registration does). The pre-merge registration MUST re-import **only** that
   variable — a deliberate, documented ADR 0016 exception. It is **kill-only**: its
   sole effect is to suppress an advisory and short-circuit before any network, so
   a repo-injected value can only turn the repo's own advisory *off* (a
   fail-toward-silence direction that grants no bypass). **Test:** `=0` survives
   `env -i`, does zero network, emits nothing.

5. **Authoritative target resolution — including fork PRs.** The engagement lookup
   needs `<owner/repo> <pr> <head>`, none of which the gate's parsed command yields
   authoritatively (`gitcmd_detect.py` exposes only a cwd-anchored numeric PR and
   value-skips `-R`/`--repo`). Resolution MUST derive **owner/repo from the base
   repository the gate is running against**, **not** from a PR's
   `headRepositoryOwner`/`headRepository`, which on a **fork PR return the
   contributor's fork** and would query the wrong repo (false `none`). `git remote
   get-url origin` is the base repo only when the gate's checkout is anchored on it
   (true for this solo-admin repo's merge flow, per project CLAUDE.md); the
   implementation MUST NOT assume this holds unconditionally — if `origin` cannot
   be confirmed to point at the base repo (e.g. a checkout whose `origin` is a
   contributor's fork), resolution MUST fall to `unknown` → silent rather than
   query the wrong repo. HEAD comes from `headRefOid`. Any repo override /
   non-numeric positional / resolution failure → `unknown` → silent (which also
   covers the un-surfaced `-R` case).

6. **PR-level engagement; HEAD is label-only.** Reuse the existing paginated
   presence check (bot login across reviews + PR-level reactions). This is
   **PR-scoped, not HEAD-scoped** — reactions carry no commit SHA and the review
   scan does not filter `commit_id`. The resolved HEAD is used only in the warning
   text, never as a scoping filter (avoids false `none` from old-commit activity;
   matches the nudge and pr-grind's none-vs-stale split). A reaction (Tier-F 👍)
   counts as engagement → the wording is **engagement**, not review.

7. **Read-only.** The lookup only reads; it never posts `@codex review`
   (posting-then-merging is the too-late pattern this ADR rejects) and writes no
   marker/comment.

8. **Operator-visible, non-gating surface.** Bare stderr on an exit-0 approve is
   diagnostic-only and not reliably shown. The warning MUST use a surface that is
   shown **to the operator** and does **not** gate. Note the distinction verified
   in review: top-level **`systemMessage`** is displayed to the operator, whereas
   `hookSpecificOutput.additionalContext` is injected into *Claude's* context on
   the next model request (model-facing, and the merge may complete before the
   agent even sees it) — so `additionalContext` does **not** satisfy this contract.
   The surface must also carry **no** `decision`/`permissionDecision` field (either
   would gate). **Honest semantics:** this surfaces the warning at approve time; it
   does not hold the merge. Acting on it is the operator's/agent's choice. **Test:**
   the allow response carries an operator-visible message and **no**
   `decision`/`permissionDecision`.

9. **Repeatable, not exactly-once — deduplication is optional, not required.**
   PreToolUse fires once per **Bash tool invocation** that contains the
   `gh pr merge` — not once per runtime merge (a shell loop running the command
   N times under one invocation warns once; only merges submitted as separate
   Bash calls re-warn). The gate keeps no dedup state, so those separate-call
   retries deliberately re-warn — this is not idempotent output, since distinct
   invocations re-emit the same warning by design. Acceptable (message-only, no
   side effect); a per-`(PR,HEAD)` dedup marker is an optional future
   refinement, not required.

## Why warn-only, not a fail-CLOSED block

- **Codex is advisory, not a required status check (decisive).** The real merge
  gate is the required checks + pr-grind-clean. Blocking merge on a *non-required*
  bot's silence inverts its pipeline status. *(Nuance, not overclaim: Codex is a
  hybrid — pr-grind treats a `stale` Codex ack as gating per SKILL.md. The warn-only
  case rests specifically on **`none`/never-engaged** being the non-gating end of
  that split, not on "Codex is advisory everywhere.")*
- **`none` is ambiguous.** Webhook-dropped, uninstalled, quota-exhausted, and idle
  Codex all read as `none`. review-before-merge only helps the rare, curable
  webhook-dropped-but-quota-available case; a block would fire on all the others,
  indistinguishably.
- **A block on a flaky external signal must fail-open — which makes it theater.**
  Full D auto-releases at a deadline so an outage can't wedge merges; operators
  learn to wait out the timer regardless of Codex, eroding attention to the *real*
  deterministic blocks (design-review, litmus, pr-grind-clean). Net-negative for
  safety.
- **An operator-visible warning delivers the signal without withholding authority**
  — the whole value of full D, minus the fail-open theater.

### On ADR 0012 (withdrawn as the "decisive" argument)

The earlier drafts' strongest claim — that blocking on `none` is the "opposite
polarity" of ADR 0012's downgrade-to-release — was **false**. ADR 0012 downgrades
only a **previously-clean, now-stale** ack (Decision precondition #4 requires the
last review to have 0 unresolved findings) and keeps a **never-engaged/crashed**
bot conservative (it stays stale and still bails to the operator). So 0012 is not
precedent for releasing `none`, nor its opposite polarity. It is not load-bearing
here.

## Alternatives

- **C — status quo, no warning.** Rejected: the miss stays silent and unauditable
  at decision time (#444). D-lite closes that with no additional merge-blocking
  risk (its bounded external reads can still consume runtime budget or fail
  silently on timeout — see invariant constraints 1-3 — but never gate the
  merge).
- **D — fail-CLOSED block with auto-release.** Rejected (see "Why warn-only"):
  advisory-not-required, ambiguous `none`, fail-open gate-fatigue. Unanimously
  rejected by the council.
- **`permissionDecision:"ask"` instead of a non-blocking surface.** Gives a true
  pre-merge choice but **prompts**, blocking agent-driven merges. Rejected: a soft
  gate, not warn-only.
- **Widen the nudge parser / post-merge backstop.** Rejected: the nudge is
  non-gating (review still lands post-merge, #419); a post-merge review reviews a
  closed PR.

## Consequences

- On bootstrap/skip merges of a Codex-active repo where Codex silently no-op'd, the
  operator gets a deterministic advisory at merge — the signal #444 lacked. Normal
  (pr-grind-clean) PRs: merge **authorization** unaffected; **runtime** gains one
  bounded read-only check. On an *active* repo that stayed `none` this duplicates
  COMPLETION's warning (harmless, idempotent); on a **force-on-only** repo it is the
  sole warning even on the marker path (COMPLETION requires auto-detected active).
  Skipped entirely under the kill switch.
- **No new way to wedge a merge** — the block set is unchanged; purely additive
  read-only output on allow paths.
- The `⚠️` may become wallpaper if ignored — accepted for an advisory signal on a
  solo repo; "surfaced and ignored" beats "silent."

## Revisit trigger

- **A warned-but-merged PR ships a defect Codex would have caught** → do NOT reach
  for full D. Adopt the **PR-open nudge**: post `@codex review` right after the PR
  is *created*, so Codex has its full pre-merge window and the signal lands before
  merge with no merge-time latency. **Mechanism note:** `pre-pr-gate.sh` is a
  **PreToolUse** hook — it fires *before* `gh pr create`, so the PR doesn't exist
  yet; the nudge needs a **PostToolUse hook on successful `gh pr create`**
  (success-only, authoritative resolution from the created PR, dedup, non-gating).
  - **IMPLEMENTED 2026-07-24 (issue #473 — this exact trigger fired on PR #470, a
    warned-but-merged PR whose Codex review carried a P1 that landed ~4 min
    post-merge).** `hooks/gate-scripts/codex-nudge-precreate.sh` is that PostToolUse
    hook: success-only (shared `gitcmd_detect.gh_pr` + URL/exit/failure-signature
    detection, mirroring `post-pr-consume-marker.sh`, reading output from both the
    `tool_output` and `tool_response` payload shapes), target **bounded to the
    operator's own current-branch PR** via `gh pr view` (the PR number is NOT
    scraped from output; resolved PR must be OPEN and in the cwd origin repo — the
    operator's own PR in the common case), gated on gh having printed
    THAT PR's URL, AND fired ONLY on a LONE `gh pr create` (`precreate_parse.py`:
    only a plain `cd <literal>`/assignments before it, nothing after, no
    `-R`/substitution — so a compound that moves cwd/origin around the create,
    `… && cd B`, `git remote set-url … && gh pr create`, `-R other`, is a fail-safe
    MISS, closing the post-command-state mistarget). The residual is only what a
    parser inherently cannot see — a `cd`/`gh`/`git` shell function/alias or
    inherited GH_*/GIT_* env — the identical limit `codex-nudge-premerge.sh` accepts
    (ACCEPTED LIMITS #2–4),
    delegating to the SAME `codex-nudge-if-expected.sh` → `codex-retrigger.sh` chain
    as the premerge nudge, sharing codex-retrigger's per-`(PR,HEAD)` marker so the
    create + merge + SKILL paths dedup to one `@codex review` per HEAD WITHIN a
    checkout (pr-grind creates and merges in one worktree; the marker is
    worktree-local, so create and merge from DIFFERENT linked worktrees could each
    post once — a bounded, benign double-nudge on the same PR). Non-gating,
    kill-switch–respecting (`PR_GRIND_CODEX_RETRIGGER=0`), fail-safe-SKIP. Test:
    `tests/test-codex-nudge-precreate.sh`. The fail-CLOSED **block** (issue #473
    direction #1) was **re-rejected on unchanged facts** — `none` is still ambiguous
    (quota-exhausted vs webhook-dropped vs idle), a block on it still fails open on a
    timer, and its only escape (a skip file the same dispatcher can write) is
    self-bypass with ceremony. The PR-open nudge *deletes* the latency race instead
    of gating on the ambiguous signal. Basis: 2026-07-24 ultimate-council (unanimous
    A — 5 voices + Mythos Witness).
- **Codex gains a reliable pre-merge first-engagement signal** the gate can observe
  → the nudge/warn dance becomes unnecessary.
- **`docs/degraded-modes.md` lets an advisory bot block merge** → the
  advisory-not-required argument weakens; re-evaluate.

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
