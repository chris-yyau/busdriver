# ADR 0003 — Blueprint-review arbiter runs as a fresh Claude subagent, not the calling session

## Status

Accepted (2026-06-10). **Superseded in part by [ADR 0008](./0008-opus-default-arbiter-drop-fable.md) (2026-07-01):** the *arbiter-model* decisions here — the `model: fable` pin, the `fable → gateway fable → opus → inherit` fallback chain, the `gateway_fable_fallback`/`opus_fallback`/`inherited_fallback` status values, the inline-degraded allowance, and the Revisit trigger below — are replaced by an **opus-default** arbiter with the gateway-fable path re-cast as an opt-in "ultra arbiter" escalation. The **fresh-subagent / author≠judge / context-firewall / verdict-freshness** decisions of this ADR remain in force. Body left unedited as historical record.

## Context

Blueprint-review's three-tier model (Agy + Codex + Grok in parallel, Claude as
arbiter) hardcoded "Claude is always the arbiter" — but that arbiter was the
**calling session itself**: the same Claude that wrote (or commissioned) the
plan under review. That is author-as-judge. The arbiter has investment in its
own plan passing, and the bias is documented, not theoretical: in the
class-roll incident (2026-03-10), Claude did its own validation, decided PASS
with "only low-severity items," and stamped `<!-- design-reviewed: PASS -->`
while Agy and Codex were still running. The skill's `<EXTREMELY-IMPORTANT>`
block — a list of forbidden rationalizations — exists solely to suppress this
bias with prose. Prose prohibitions depend on the model honoring them under
exactly the conditions (long sessions, sunk cost in a plan) where it is least
likely to.

A second, smaller problem: arbiter quality floated with whatever model the
calling session happened to run. The user switches session defaults between
Opus and Fable; the review gate's strictest judgment step inherited that
choice silently.

The loop script's contract made a structural fix cheap: the script generates a
**self-contained** validation prompt file (design doc + all three reviewer
outputs + coverage provenance + freshness contract), pauses
(`awaiting_claude_validation`), and resumes via `--claude-only` once *someone*
writes `claude.json`. The script never cared who writes the file.

## Decision

1. **The arbiter is a freshly dispatched Claude subagent** (Agent tool,
   `subagent_type: general-purpose`), never the calling session. It has no
   conversation history, no authorship stake, and judges only the prompt file
   plus the codebase.
2. **Model-pinned to `fable`** so arbiter quality is independent of the
   session model. `fable` is a verified Agent-tool model value (observed
   accepted dispatch 2026-06-10 — this ADR's own dogfood review ran on it).
   Pin observability without breaching the firewall: the fixed dispatch
   template (Decision 3) contains a standing instruction for the arbiter to
   self-report the model it actually ran as in `validation_notes` using the
   canonical field `executed_model: <model-name>` (e.g.,
   `"executed_model": "fable"`) — a fact the subagent knows from its own
   runtime identity, needing nothing from the caller. The caller records the
   pin status on its own side (its report / review state, never by editing
   `claude.json`) and compares post-hoc against the `executed_model` field, so
   a rejected or silently ignored pin is observable. Pin status values:
   `pinned` — initial `fable` dispatch succeeded (record this on success, before
   any fallback); `gateway_fable_fallback` — subscription `fable` was unsupported
   but the operator had gateway credentials configured, so the arbiter ran as a
   headless `claude -p` subprocess pinned to `claude-fable-5` through an
   Anthropic-API-compatible gateway (e.g., ZenMux); `opus_fallback` — `fable` was
   unsupported (and no gateway rung available), retried with `opus`;
   `inherited_fallback` — `fable` and `opus` were both unsupported, session model
   inherited; `pin_ignored` — dispatch appeared to succeed but
   the arbiter's self-reported `executed_model` mismatches the model actually
   dispatched (after any step-1 fallback; the comparison is by model identity —
   alias ≡ full id ≡ gateway-namespaced id, e.g. `fable` ≡ `claude-fable-5` ≡
   `anthropic/claude-fable-5` — never by literal string)
   (overwrite the previously-recorded status and set `run_degraded=true`). The
   first four values are the mutually exclusive dispatch-time statuses;
   `pin_ignored` is set during the post-dispatch check (step 3 in the SKILL.md
   protocol) and supersedes whichever of the first four was recorded.
3. **Context firewall:** the dispatch prompt is the fixed template plus
   exactly two absolute paths — the validation prompt file and the
   `claude.json` output path. Nothing run-specific beyond the two paths may be
   added: no conversation history, no plan rationale, no reviewer summaries,
   no "the user prefers..." framing — any of it reintroduces the author bias
   this change removes. The template's standing model-self-report instruction
   is part of the fixed shape, not a per-run addition.
4. **Fail-closed failure handling, two branches:**
   - *Unsupported model:* a recognized unsupported-model error from the Agent
     tool → walk the fallback chain: (a) if gateway credentials are configured,
     dispatch a headless `claude -p` arbiter pinned to `claude-fable-5` through
     the gateway (`model_pin_status=gateway_fable_fallback`; opt-in, skipped
     silently when unconfigured — see the SKILL.md Gateway-Fallback Rung). If
     the gateway dispatch itself fails (configured but exit 1), retry it ONCE
     and then fall through to (b) — a gateway outage must not stop arbitration
     the next, independent rung can still provide; (b) retry with `model: opus`
     via the Agent tool (strongest available *subscription* pin,
     `model_pin_status=opus_fallback`); (c) if that is also rejected, retry
     with `model` omitted (inherit the session model,
     `model_pin_status=inherited_fallback`). Record each step caller-side and
     surface any fallback run as degraded. The one-retry-then-STOP rule below
     applies to Agent-tool dispatches, where a second failure leaves no rung to
     fall through to.
   - *Everything else:* invalid/missing subagent output → delete and retry
     ONCE with a fresh subagent; second failure → stop and report. Inline
     arbitration by the calling session is allowed only with explicit user
     authorization after the double failure, recorded as
     `arbiter=inline (degraded, user-authorized)` in `validation_notes` (here
     the calling session is the writer, so self-recording is consistent).
5. **No changes to the dispatch contract.** The freshness contract,
   `--claude-only` resume, and the `claude.json` schema are untouched; v3.3
   changes who writes the file. One narrow script follow-up IS accepted
   (Decision 7) because the review of this ADR surfaced it as a gate-integrity
   gap.
6. **The arbiter slot stays non-configurable** (Claude-family only). The
   constraint is about codebase tool access and trust in the convergence
   signal; a Claude subagent satisfies it. Cross-model diversity remains the
   reviewers' job (Agy/Codex/Grok) — the arbiter's job is codebase validation,
   not independent perspective, so sharing a model family with the writer is
   acceptable.
7. **Arbiter-verdict reuse is re-keyed (the one script change).** Today the
   loop preserves and accepts `claude.json` keyed only on the design
   `spec_hash` (`run-design-review-loop.sh` ~405–413 preserve, ~880–891
   cross-run accept) while `agy.json`/`codex.json`/`grok.json` are deleted and
   re-rolled every run — so a re-run on an unchanged design with different
   reviewer findings or degraded coverage can converge on an arbiter verdict
   that never saw the current reviews. v3.3 scopes reuse: a cached verdict is
   valid only when the full validation context matches — key reuse on a hash
   of the validation-prompt content (design + all three reviewer JSONs +
   coverage section), or equivalently require a current-run `run_id` unless
   the reviewer artifact hashes also match. *Landed 2026-06-10 (same day),
   conservative arm:* `validate_claude_verdict_freshness()` in
   `lib/validation.sh` requires current-run `run_id` + matching `spec_hash`
   (missing metadata = stale, closing the old `-n` guard hole); the
   spec_hash-only preserve site is deleted (full iterations always clean
   `claude.json`) and the cross-run acceptance branch is removed. The
   legitimate pre-written-verdict flow is `--claude-only`, which recovers
   `run_id` from the reviewer artifacts the verdict actually saw. Tests:
   `tests/test-claude-verdict-freshness.sh`.

**Orchestration responsibility.** The calling session — in common usage the
plan-authoring session — executes the dispatch protocol (detect pause,
dispatch, post-check, retry, `--claude-only` resume) and is bound by the
firewall while doing so. The separation is therefore structural for the
*verdict*: whoever orchestrates, the agent rendering judgment has no
authorship stake and no conversation context. Compliance with the protocol
itself (actually dispatching rather than writing `claude.json` inline) remains
prose-enforced defense-in-depth; full dispatch isolation requires the
script-level enforcement listed in Alternatives and Revisit triggers.

## Alternatives

- **Also dispatch a subagent to WRITE the plan** (the original proposal paired
  a Fable writer with the Fable arbiter). Deferred: the main session carries
  the brainstorming conversation — user answers, rejected alternatives, scope
  decisions — and a writer subagent only sees what gets serialized into its
  prompt. writing-plans demands "No Placeholders" and exact file paths; one
  missed nuance produces a confidently wrong plan that burns review
  iterations. The review loop's fix-and-iterate step would also need subagent
  ownership (resume/re-dispatch), adding orchestration surface. Context
  isolation is real but plan-writing is not the main context killer — review
  iterations and execution are. If revisited: dispatch the writer only when
  brainstorming produced a fully self-contained spec doc, pass the doc path
  (not a summary), and have the main session fidelity-check the returned plan
  against the conversation.
- **Keep inline arbitration, strengthen the prose prohibitions.** Rejected:
  that is the v3.2 status quo; class-roll showed prose alone fails exactly
  when it matters.
- **External CLI as arbiter (agy/codex/grok slot-style, configurable).**
  Rejected: the arbiter needs first-class codebase tools (Read/Grep/Glob) and
  produces the sole convergence signal the gates trust; keeping it
  Claude-family preserves both. External diversity already exists in the
  reviewer tier.
- **Script-level enforcement (loop spawns the arbiter itself, e.g. via
  `claude -p`).** Rejected for now: spawning a nested Claude from a hook-era
  bash script adds auth/runtime coupling and a second harness to debug; the
  Agent-tool dispatch gets the same isolation using machinery the session
  already has. Revisit if prompt-level compliance proves unreliable.

## Consequences

- The documented self-pass failure mode is removed structurally **for the
  compliant path**: the agent that renders the verdict has no authorship
  stake. Violations of the protocol itself (writing `claude.json` inline)
  remain prose-prohibited — the `<EXTREMELY-IMPORTANT>` rationalization list
  stays as defense-in-depth pending script-level attestation (see Revisit
  triggers). This is an honest narrowing of the claim, not a loophole grant.
- Cost/latency: one extra subagent dispatch per iteration (~3–5 per review).
  Acceptable on subscription. Verdict reuse exists only on the `--claude-only`
  path under the Decision 7 guard (current-run `run_id` + `spec_hash`); full
  iterations always re-arbitrate against the fresh reviews.
- The arbiter loses conversation context by design. The validation prompt
  file is self-contained, so a verdict should never *need* conversation
  context; if one does, that is a defect in the plan document (it should have
  captured the rationale), not in the protocol.
- Enforcement is prompt-level (SKILL.md), not hook-level. A future session
  could still rationalize writing `claude.json` inline; the firewall and the
  forbidden-thoughts list make that an explicit violation rather than a
  default.

## Revisit trigger

- Arbiter verdicts start contradicting codebase reality or flagging issues
  whose answers live only in the conversation → the prompt file is no longer
  self-contained; fix the prompt generator (or the plan template) rather than
  reverting to inline arbitration.
- Inline-arbitration violations are observed despite v3.3 → escalate to
  script-level enforcement (loop validates that `claude.json` was produced by
  a dispatched agent, or spawns the arbiter itself).
- Plans repeatedly arrive at review missing discussed requirements → revisit
  the deferred writer-subagent half with the spec-doc-as-contract gate
  described in Alternatives.
- The `fable` model tier is renamed/retired, or the pin is rejected or
  silently ignored in practice (arbiter's self-reported model ≠ expected pin)
  → update the pin; the protocol already defines an explicit fallback chain
  (subscription `fable` → gateway `fable` → subscription `opus` → inherit, each
  step recorded caller-side) plus the arbiter self-report comparison, so a
  retired tier degrades to the strongest available pin — preferring gateway
  fable when the operator has opted in — rather than straight to the session
  model.
- A stale-verdict convergence is observed despite the Decision 7 guard → the
  conservative arm (current-run `run_id`) has a bypass; escalate to the full
  context-hash arm (hash of design + all three reviewer JSONs + coverage).
<!-- design-reviewed: PASS -->
<!-- design-review-coverage: FULL 3/3  -->
