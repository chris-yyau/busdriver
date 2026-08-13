# ADR 0038 — TDD is not a Phase 4 default; ordering is advisory

**Status:** Accepted
**Date:** 2026-08-13

## Context

`skills/orchestrator/SKILL.md` listed TDD under **"Always-on disciplines (no
exceptions)"** and instructed **"DISPATCH `tdd-guide` agent to produce test
files."** `agents/tdd-guide.md` carried `Use PROACTIVELY when writing new
features, fixing bugs, or refactoring code`. The wording is inherited from
upstream `obra/superpowers`, which still ships the same Iron Law.

Two independent lines of evidence.

### 1. External — the ordering lever is the contested one

- **Böckeler, "TDD inside the agent loop — theater or actual value?"**
  (martinfowler.com, 2026-08-10). 18 runs; Sonnet 4.6 generated, Opus 4.8
  blind-judged. Non-TDD ranked #1/#2 on small and medium tasks; mutation scores
  tied; TDD cost 2.96x–8.50x tokens. **Every TDD run violated the TDD protocol**,
  and the tasks were greenfield business logic — so it measures TDD *prompting
  under violation*, not TDD.
- **TDAD** (arXiv:2603.17973, 2026-03-18). TDD procedural instructions without
  test context *raised* SWE-bench Verified regressions 6.08% → 9.94%; graph-based
  impact analysis cut them to 1.82%. "Surfacing contextual information
  outperforms prescribing procedural workflows."
- **Fucci et al.** (arXiv:1611.05994, TSE; 39 professionals, 82 tasks).
  "Sequencing, the order in which test and production code are written, had no
  important influence." Granularity and uniformity carried the effect.

None of this is decisive alone. It establishes that *ordering* is the weakest
part of TDD's evidence base, for humans and agents alike.

### 2. Local — the rule was never operative

A compliance audit parsed all 144 local session transcripts for this repo
(~5 months, one operator). Every `tool_use` event was extracted; `Write`/`Edit`/
`MultiEdit` targets were classified test vs implementation code; the first test
write was compared to the first impl write per session; `Task`/`Agent`
dispatches were counted by `subagent_type`.

46 sessions contained code writes:

| Signal | Result |
|---|---|
| `tdd-guide` dispatched | **0 / 46 sessions; 0 of 234 dispatches repo-wide** |
| Test file written before impl file | 5 / 46 (11%) |
| Impl written first | 34 / 46 (74%) |
| Test writes only, no impl | 3 / 46 (7%) |
| Code with no test file at all | 4 / 46 (9%) |

Detector negative control passed: the same parser found all 234 dispatches and
bucketed them correctly (198 `busdriver:pr-grinder`, 18 `general-purpose`,
7 Council Skeptic, 7 Council Mythos Witness, 3 `busdriver:code-reviewer`,
1 `codex:codex-rescue`). `busdriver:tdd-guide` is registered and dispatchable —
it appears 273 times across transcripts in the agent-type listing — so the zero
is disobedience of a live instruction, not a wiring defect.

`grep -riE "tdd|test.?first|red.?green" hooks/` returns 0 hits. No registered gate
currently enforces TDD ordering.

### What the audit does NOT establish

Recorded here because the first draft of this change over-read it:

- **0/234 is evidence about the agent, not the discipline.** Test-first work
  could happen inline without dispatching `tdd-guide`.
- **11% is an upper bound.** It measures write *order*, not observed RED. Zorro's
  accuracy for exactly this inference fell 89%→70% under interleaving; Karac et
  al. (TSE 2025) found only 40% of trained professionals adhere to TDD protocol,
  so low adherence does not uniquely indict a rule.
- **Writes by dispatched external CLI agents** (Codex, agy) run in their own
  processes and are absent from these transcripts.
- **One operator.** busdriver is public. This is canonical dogfooding evidence,
  not population telemetry.
- **The counterfactual is unmeasured.** 42 of 46 code-writing sessions contained a
  test-file write *with the mandate loaded* (the audit measured transcript writes,
  not test execution, pass status, or shipment); whether removing the mandate
  changes that rate is untested.

## Decision

1. TDD is **not** a Phase 4 default. The Phase 4 discipline is the outcome —
   behavioral changes ship with tests — and **ordering is not mandated**.
2. Delete the unconditional `DISPATCH tdd-guide agent` line from Phase 4. It
   produced 0 dispatches in 234.
3. `agents/tdd-guide.md` drops `Use PROACTIVELY`; the agent is reached by
   explicit request (`/tdd`, `/go-test`, `/rust-test`, `/react-test`).
4. The routing-table row `| Write tests | Phase 4 | /tdd (tdd-guide agent) |
   Test task only |` **stays**. It is the legitimate opt-in route and is already
   scoped "Test task only."
5. `skills/test-driven-development/SKILL.md` keeps its Iron Law **unchanged**.
   It governs the workflow of a skill you explicitly invoke; an orchestrator that
   does not mandate ordering and a TDD skill that mandates ordering *while doing
   TDD* are not in contradiction.
6. The Phase 4 bullet says **"Advisory, not gate-enforced"** in as many words.

## Alternatives considered

- **Write a "new test must fail on the base revision" rule into the orchestrator.**
  Rejected. All five council voices and all three expert witnesses converged: a
  rule in the same markdown that just measured 0% adherence is prose replacing
  prose. The criterion is checkable *in principle*; the edit would not check it.
  Per `rules/common/designing-enforcement-gates.md`: "A guard that cannot fire is
  worse than no guard — it certifies safety it never checked."
- **A security/gate carve-out ("fail-closed code still goes TDD").** Rejected.
  The implementing agent would classify its own change, which is the
  author-declares-own-scope anti-pattern. Security behaviour crosses path
  boundaries here — a shared parser or timeout wrapper can decide whether a gate
  fails open.
- **Promise "tests survive mutation."** Rejected. No mutation runner exists
  (`stryker`/`mutmut` absent from `package.json` and `node_modules`), so it would
  remove a concrete requirement and replace it with an unmeasurable one. The
  phrasing is also inverted: a *surviving* mutant indicates a weak suite.
- **Keep it and repair Phase 4 routing instead.** The strongest dissent. Rejected
  for now because the wording asserted an assurance that has never held, and
  leaving a false "no exceptions" in place is itself a defect. Revisit if the
  falsifier below fires.
- **Delete the TDD skills.** Rejected. 118 shell tests, 16 vitest files and 7
  pytest files exist, and 42 of 46 code-writing sessions contained a test-file
  write; what was dead is the ritual and the dispatch, not test-writing itself.

## Consequences

- Phase 4 no longer instructs an unconditional `tdd-guide` dispatch.
- Strict TDD remains fully available and unweakened behind explicit invocation.
- **This is an intentional semantic fork from upstream `obra/superpowers`,** which
  still ships the always-on Iron Law. An upstream sync must not silently restore
  the Phase 4 wording.
- No enforcement changed, because none existed. Test quality still rests on
  litmus, `pr-test-analyzer`, and CI — none of which check ordering either.

## Revisit trigger

- **Falsifier for "the discipline was not operative":** re-parse the 46 sessions
  per *change* rather than per session, joining external-agent logs and commits,
  and look for `test write → observed failing test run → impl write`. If that
  rate is materially above 11%, this ADR misread routing failure as discipline
  failure and should be reversed.
- **Falsifier for "the prose was inert":** a prompt ablation on comparable tasks
  measuring omitted behaviours with and without the TDD material loaded. Böckeler
  found "behaviour the agent didn't think to write a test for didn't get
  implemented at all" — if the mandate measurably reduces omitted behaviour
  despite low procedural compliance, restore it.
- **Upgrade path:** if the outcome rule is to become real, the artifact is known
  — FAIL_TO_PASS (SWE-bench) / triggering test (Defects4J), implemented as a
  litmus pre-PR step that restores implementation at the merge-base, applies
  test-only files, requires the named test to fail *for the right reason*
  (rejecting import errors and zero-collected as invalid RED), then requires pass
  at HEAD. Require the plan to declare the test command; do not auto-discover
  frameworks. Until that ships, the Phase 4 bullet must keep saying "advisory."
