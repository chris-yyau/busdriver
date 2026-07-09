# ADR 0006 — Litmus PR-mode deep review: Codex lead + one enforced Opus security backstop

## Status

Accepted (2026-06-20)

## Context

Litmus PR mode (the pre-PR gate, `LITMUS_MODE=pr`) ran a two-layer deep review: (1) a Codex CLI
pass over the full `base...HEAD` diff, then (2) **six Claude subagents** — Bugs, Security,
Cross-commit on Opus; Guidelines, History, Docs on Sonnet — blended by a 12-point **weighted
quorum** (Bugs=3, Security=3, Guidelines=2, Cross-commit=2, History=1, Docs=1; a hard "Bugs +
Security must both return" requirement). The three Opus agents are the cost driver — every PR paid
for three Opus reviews plus three Sonnet reviews. The goal: cut that cost without losing review
quality.

Two design questions were stress-tested before deciding:

- **Is a single Codex pass enough?** A council (4 of 5 voices) said no: the six Claude lenses were
  *correlated* (one model family, one diff — "quorum theater"), but the real signal is **cross-model
  diversity**, and the existing `codex → droid → builtin` fallback only covers Codex being
  *unavailable*, never *up-but-confidently-wrong*. Keep one independent voice. This mirrors **ADR
  0003**, which rejected single-voice review for the blueprint-review gate (external CLI diversity +
  a Claude validator).
- **Should the gate use Codex + Agy + Grok (three families)?** A second council (5 of 5) said no for
  the *default* gate: 3× external cost, Grok's weaker security posture inside a security gate, and
  near-duplication of blueprint-review's reviewer tier. It endorsed measuring instead of assuming.

A three-tier blueprint review then forced the design to be *implementation-safe*: a "hard-required"
backstop is meaningless unless **machine-enforced**, and the PR gate had bypass paths (it also
accepted the commit-mode marker; the prose-only "read-only" agent actually carried Write/Edit).

## Decision

Replace the six-agent layer with **Codex xhigh as the deep multi-lens LEAD reviewer + exactly ONE
dedicated read-only Opus Security/Bugs backstop agent** (`agents/pr-security-backstop.md`, `tools:
Read, Grep, Glob` only). Delete the weighted quorum.

The gate is **machine-enforced** by two diff-bound artifacts:

1. On a clean Codex pass, a trusted writer emits `pr-codex-lead.local.json` `{status, diff_hash, ts}`.
2. The Opus backstop's verdict is written by `run-review-loop.sh --write-backstop-verdict` to
   `pr-backstop-verdict.local.json`; the writer **re-derives `diff_hash`/`ts` itself** (caller supplies
   only `{status, model, issues[]}` + `reviewed_diff_hash`), recomputes status from issues, and
   validates strictly (fail-closed on missing confidence / bad severity / TOCTOU hash mismatch).
3. `--write-pr-marker` **and** `pre-pr-gate.sh` refuse the PR unless BOTH artifacts are fresh
   `status:PASS` with `diff_hash` matching the current `base...HEAD`.
4. Both artifacts are added to `pre-implementation-gate.sh`'s `MARKER_FILES`, so they can be written
   only by the trusted writers (mirroring `write-review-marker.sh`).

The Codex lead is pinned: PR mode sets `LITMUS_CODEX_DROID_FALLBACK_DISABLED=1` and requires
`RESOLVED_CLI=codex`; a builtin/non-Codex lead is inconclusive/fail-closed. Cosmetic findings
(docs/naming/style) are capped at LOW so they never trip the FAIL rule.

A non-gating **benchmark mode** (`LITMUS_PR_BENCHMARK`) is **specified but deferred (not yet wired)** —
when built it would run Agy/Grok as observers logged to `.claude/pr-review-benchmark.jsonl`, measurement
only, never affecting the gate. It is deliberately not implemented now: its sole purpose is to gather
evidence on whether a third model family earns a gating seat, a question this solo repo marks SETTLED
(CLAUDE.md frozen-scope principle), so building it would be speculative. The contract lives in
`skills/litmus/references/pr-review-mode.md` → "Benchmark Mode" for when a real measurement need appears.

## Alternatives considered

- **Pure single-Codex pass** — *rejected (council #1, 4/5)*: loses cross-model diversity; the fallback
  chain covers availability, not correctness.
- **Keep the 6-agent weighted quorum** — *rejected*: correlated (all Claude), expensive, "quorum
  theater"; the diversity it appeared to provide was illusory.
- **Codex + Agy + Grok + Claude arbiter as the default** — *rejected (council #2, 5/5)*: 3× cost,
  Grok's weaker posture in a security gate, near-duplicate of blueprint-review. Replaced by the opt-in
  non-gating benchmark to gather net-new-true-positive evidence before promoting any third family.
- **Prose-only "hard-required" backstop** — *rejected (blueprint review)*: structurally unenforced;
  the marker was writable off the diff hash alone with no proof the backstop ran.

## Consequences

- **~80% cost win**: Codex replaces five of six agents; one residual Opus voice per PR.
- The cross-model safety net is **gate-enforced**, not advisory.
- More moving parts than a single pass (two artifacts, a strict validator, gate-acceptance changes),
  justified because this is a security gate.

### Trusted computing base / accepted residual (IMPORTANT)

The gate structurally enforces (a) no PR marker without a fresh PASS artifact bound to the current
diff, and (b) a backstop agent that *cannot* write (Read/Grep/Glob only). It does **not**
cryptographically prove the agent ran — **Claude is the trusted dispatcher**, the same TCB posture as
ADR 0003's arbiter protocol (structural isolation + prose-enforced dispatch compliance). The artifact
protection is at **parity with the existing markers** (`litmus-passed.local`, `pr-review-passed.local`):
a determined shell bypass of the trusted writer (`sed -i`, `cp`, `python -c open(w)`) is **not**
exhaustively chased. This is explicitly accepted for this **solo-operator** repo per the project's
frozen-hardening principle (CLAUDE.md: don't over-harden absent a second writer/threat) — the realistic
risk is a lazy dispatch, not a hostile actor with repo shell access.

> **2026-07-09 addendum (#290) — indirect-write verbs now blocked.** The residual
> above called blocking `cp`/`mv`/`install`/`ln` (and `touch`) "theater," and it
> still is against a *hostile* dispatcher — one that can `eval` forges the marker
> directly. But the realistic threat is an *accidental/lazy self-bypass by a
> cooperative agent*: a bare `touch .claude/skip-litmus.local` (plus `touch -t`
> backdating, which also defeats the pre-commit 30s age heuristic in one shot) let
> Claude skip review. `_writes_marker`'s command-word set was therefore extended
> `rm`/`tee` → `+touch`/`cp`/`mv`/`ln`/`install` (matched in command-word position),
> closing every easy *bare-command* indirect-write path. A bypass must now be a
> deliberate wrapper-hidden form (`sudo`/`env` prefix — still allowed residual) or
> an eval-forge — neither of which a cooperative agent builds to skip its own gate.
> The interpreter/eval class (`python -c open(…)`, `sh -c`, `dd`) and wrapper-hidden
> writes stay out of scope — only an OS sandbox closes them. The human's
> own-terminal `touch` is unaffected (this PreToolUse hook only sees Claude's tool
> calls). Regression cases: `tests/test-pre-implementation-gate.sh` (`#290`).

## Revisit trigger

- A second approval-capable human / writer ever appears → add script-captured dispatch (capture the
  agent's stdout under restricted tools) and full write-vector protection.
- Observed PR escapes (bugs/security issues that reach `main`) rise → use the benchmark JSONL evidence
  to re-introduce a gating reviewer voice.
> **2026-06-27 update:** opencode support has been removed; this section is historical/moot.

- The `opencode/` litmus mirror's PR-mode docs are stale-until-port; a full mirror update is deferred
  to the opencode port task.

<!-- design-reviewed: PASS -->
<!-- design-review-coverage: FULL 3/3 -->
