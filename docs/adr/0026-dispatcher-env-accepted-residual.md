# ADR 0026 — pr-grind dispatcher credentialed calls run in the operator session's env (accepted residual)

## Status

**Accepted (2026-07-24).** Documented residual, no code change. Relates to
[ADR 0016](./0016-gate-env-containment.md) (gate env containment — the mechanism
this ADR explains does **not** transfer to) and builds on the #470 P1 fix in
[PR #474](https://github.com/chris-yyau/busdriver/pull/474) (routing containment on
the Codex nudge). Issue: **#475**. Sibling theme: **#473** (dispatcher invariant in
prose vs. mechanism).

## Date

2026-07-24

## Context

The pr-grind **dispatcher** (the `skills/pr-grind/SKILL.md` control flow Claude
executes) makes ~15 credentialed `gh`/`git` calls across its bash blocks — the
merge, `gh pr checks`, the ack-ledger GraphQL re-query (the `ALL_THREADS` / `ALL_REVIEWS`
block in `skills/pr-grind/SKILL.md`), the
admin-merge, the Codex nudge. Every one runs in the **operator session's ambient
environment**. `grep -c 'env -i' skills/pr-grind/SKILL.md` == 0.

Codex flagged on PR #474 that the two-var `GH_HOST`/`GH_REPO` pin added there for
the nudge is defeated by `BASH_ENV`/`PATH` injection, and that the exposure is not
specific to the nudge — a committed `.claude/settings.json` `env` block (the
#325 / ADR 0016 repo-controlled channel) can inject `BASH_ENV`, a poisoned `PATH`,
`GH_HOST`, `GH_REPO`, or an exported `gh` shell function that intercepts any of
those calls. Issue #475 asks the threat-model question directly: **is a
repo-injected `env`/`BASH_ENV`/`PATH` in scope for the dispatcher the same way it
is for an auto-firing hook?**

## Decision

**Accept as a documented residual. Do not wrap the dispatcher's credentialed calls
in `env -i`.** The reasoning is that per-call containment here is *false assurance*,
not a real boundary:

1. **The dispatcher IS the operator's Claude Code session.** The poison vector — a
   committed `settings.json` `env` block — is merged into the session process
   environment **at session start**, before any dispatcher prose runs. It is
   inherited by *every* Bash-tool subprocess that session, not just these 15 calls.
   Under a poisoned `PATH`, `git`/`gh`/`node`/`python3` are shimmed on **every**
   command the operator runs — reading files, running tests, the merge, all of it.

2. **The plugin cannot sanitize the session it runs inside.** ADR 0016 contains the
   gates by having `hooks.json` invoke them under `/usr/bin/env -i` **from above the
   script** — a place the plugin controls because the gate is a separate,
   auto-firing process. The dispatcher has no such "above": its env is the session's
   env, already established by Claude Code. Wrapping individual bash blocks in
   `env -i` sanitizes those 15 calls while the other ~500 Bash calls in the same
   session stay poisoned. That is exactly the "inconsistent / false assurance"
   failure #475 names for the nudge-only fix, extended to its logical end: a
   dispatcher-wide wrapper is *also* false assurance, because the session it lives in
   is already fully compromised if the vector fires.

3. **Why this differs from the gates (ADR 0016).** Gates **auto-fire** as the
   security boundary that is *supposed to catch the malicious PR*, so they must be
   contained from above or they can be disabled by the very thing they guard. The
   dispatcher is **operator-initiated** and is **not** the boundary — it runs a merge
   the operator chose to run. Containing it does not restore a boundary; it decorates
   a compromised session.

4. **The mitigating controls (detection + a bounded threat), not a proof of safety:**
   - **Contained upstream review gives a detection opportunity — not immunity.** The
     litmus gates (pre-commit / pre-PR) run under `env -i` (ADR 0016) and *review the PR
     diff* before the dispatcher merges, so a malicious `.claude/settings.json` `env`
     block is a diff line litmus puts in front of the operator. (The pre-merge gate does
     **not** review the diff — it only enforces the resulting marker + required-check
     state; the diff-level detection is litmus's.) That raises the odds the injection is
     *seen*. It does **not** make the merge safe: a PreToolUse gate still fires on a later
     credentialed Bash call, but it runs *before* that command executes and neither
     sanitizes the already-poisoned dispatcher session nor controls which `gh`/`git`
     child a shimmed `PATH` / sourced `BASH_ENV` then selects — so the call can still act
     or forge review state. The gates reduce, they do not eliminate.
   - **The dispatcher is not itself a review boundary.** Its safety rests on the human
     reading the contained review above, plus the operational bound below — not on any
     containment of its own calls.
   - **Solo-operator operational bound.** As with ADR 0016, the threat requires the
     maintainer to start a session on an attacker's branch (so its `settings.json`
     `env` is merged at start). Real but bounded; the operator accepts it here rather
     than paying for containment that does not contain.

5. **The #474 nudge containment stays as-is.** The `GH_HOST=github.com; unset
   GH_REPO` pin on the clean-path Codex nudge block in `skills/pr-grind/SKILL.md`
   (grep `GH_HOST=github.com`) is retained: it is
   cheap, and it genuinely constrains the *routing* of that one call's delegated
   helpers (`codex-active-repo.sh` / `codex-retrigger.sh`). It is **not** extended
   dispatcher-wide, precisely because a broad routing pin would close only the
   `GH_HOST`/`GH_REPO` sub-lever while leaving `PATH`/`BASH_ENV`/exported-function
   RCE open — signaling containment the dispatcher does not have.

## Alternatives considered

1. **Route all ~15 credentialed calls through a shared `env -i` wrapper + adversarial
   test** (the issue's "fix direction"). Rejected: false assurance (the rest of the
   poisoned session is untouched — see Decision 2) plus a fragile, maintenance-heavy
   surface. It would let a future reader believe the dispatcher is contained when it
   structurally cannot be.
2. **Extend the #474 `GH_HOST`/`GH_REPO` pin to every credentialed call.** Rejected:
   closes only the routing sub-lever, not the harder `PATH`/`BASH_ENV` ones, while
   implying full containment — the worst of both (partial coverage, false signal).
3. **Contain the whole operator session.** Not implementable by the plugin: the
   session env is set by Claude Code before the plugin runs. The genuine fixes for
   this class are upstream (Claude Code not honoring project-`settings.json` `env`
   for security-relevant keys) or operational (don't start sessions on untrusted
   branches) — neither is dispatcher code.

## Consequences

- Issue #475 is closed as a **documented residual**, not fixed with a wrapper.
- No new code, no new fragile surface, no false containment signal.
- The dispatcher's residual exposure is now a recorded decision with a revisit
  trigger, so it is not re-filed as an oversight. A greppable pointer sits in
  `skills/pr-grind/SKILL.md` next to the #470/#474 containment note.

## Revisit trigger

- **A second approval-capable human is added** (repo stops being solo-operator) —
  same trigger as ADR 0016; the operational bound weakens and the whole
  session-env class warrants re-examination.
- **Claude Code gains a "don't honor project-`settings.json` `env` for
  security-relevant keys" control** — prefer it; it closes the class at the source
  for both the gates and the dispatcher.
- **The dispatcher moves any credentialed work into an auto-firing hook** — then that
  work becomes containable *from above* (like the gates), and this ADR's "no `above`
  exists" reasoning flips for that path; contain it there.
