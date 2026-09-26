# Pipeline final plan — history and superseded narrative

> **History only. Not read by the review loop. Nothing here is binding.** The reviewed plan is
> `docs/plans/2026-08-27-pipeline-final-plan.md`; its binding contracts are stated there. This file
> holds the text that was moved out of it verbatim in the 2026-09-23 split (Chris-approved, plan-only,
> UNREVIEWED), so the reviewed file fits the review prompt. Line anchors inside this text (`:NNN`)
> refer to the plan as it stood before the split.

## Header history

> Review history: round 1 (2026-09-08) FAIL — 4 high, 12 medium — at DEGRADED 2/3 coverage (grok
> refused on #785; fixed at the host, not worked around). Round 2 FAIL — 5 high, 13 medium — at
> **FULL 3/3**. Round 3 FAIL — 23 findings — at FULL 3/3 (its arbiter verdict was destroyed by an
> out-of-memory kill during round 4's second attempt; the loop deletes prior artifacts at iteration
> start). Round 4 FAIL — **33 findings, 7 high / 22 medium / 4 low** — at FULL 3/3, `run_id 4e312e6a`,
> arbiter `opus`. **All 33 are addressed in this revision.** Finding counts rose at round 4 because
> five sections revised after round 3 had never been seen by any reviewer, and because finding volume
> tracks this document's ~60 `file:line` anchors — the reviewer checks every one.
> Round 5 FAIL — **28 findings, 7 high / 16 medium / 5 low**, `run_id 4e9bb526`, arbiter `opus`, FULL
> 3/3; 4 plan-blocking high and 9 plan-blocking medium, 10 auto-deferred. **All are addressed in this
> revision.** Round 5's own lesson is recorded because it changed the document's structure: five of its
> seven highs were consequences of round 4's fixes, and they shared one root — the plan had an
> integrity-before-measurement principle but **no pre-baseline integrity stage**, so #844 and item 2a's
> integrity half sat inside BLOCKED rows with no legal start, the milestone that gates everything was
> satisfiable by writing a protocol document with zero observations, and a "standing fallback" invented
> to escape that deadlock re-installed the bounded tranche this plan then rejected (a *worker*-
> installed one; Chris #2(i) has since approved an *operator*-chosen form (b) — see that row).
> Item **2i** is that
> missing stage; the milestone is now split into `protocol-approved` and `baseline captured`.
> Round 6 FAIL — **29 findings, 6 high / 16 medium / 7 low**, `run_id 7a259794`, arbiter `opus`, FULL
> 3/3; **plan-blocking high fell 4 → 3** (`high_issues_history: [4,3]`), so the iteration-2 trajectory
> gate cleared on its own terms rather than parking. All 3 high and 10 medium plan-blocking findings are
> addressed in this revision. Round 6's own lesson, recorded because two findings were defects in the
> round-5 *fixes*: the `completeness` invariant had been written over ONE filename (`litmus-passed.local`)
> while PR-mode authorization runs entirely through `write_codex_lead_verdict` and `--write-pr-marker`,
> leaving the whole PR gate outside the contract; and the "compute authorization before dedup"
> prescription would have produced FAIL verdicts whose `issues[]` held no blocking finding. Both are
> corrected here, along with a fixture that would have decided item 8's medium-blocking policy ahead of
> Chris — at iteration 3 the blocking set is `{high}` by design, so requiring FAIL there was a policy
> change disguised as a regression test.
> Round 7 FAIL — **28 findings, 7 high / 14 medium / 7 low**, `run_id afab35f5`, arbiter `opus`, FULL
> 3/3; 5 plan-blocking high and 8 plan-blocking medium, 8 auto-deferred. **plan-blocking high rose
> 3 → 5** (`high_issues_history: [4,3,5]`), so the native trajectory early-stop fired and the loop
> terminated at **`parked_no_progress`** with `early_stopped: no_improvement_trajectory`. **Parking is
> a process signal, not an approval: PASS is withheld, the review stays PENDING, and the pending
> review tokens remain ARMED** (ADR / #656). Round 7's own lesson, recorded because THREE of its five
> plan-blocking highs were defects in the round-6 *fixes* rather than in older text: the `completeness`
> enum was specified but **cannot be emitted by any existing writer** (`ALLOWED_TOP:910-914`, the
> backstop schema's `additionalProperties: false`, and a hardcoded four-field `printf`); the #844
> "rank by blocking power, break ties deterministically" prescription **cannot deliver
> order-independence**, reproduced as three distinct surviving sets across six permutations of one
> three-finding non-transitive case; and item 7's fail-closed default for an indeterminate probe
> **locked out every binary, image and PDF read**, a new prohibition over an incumbent that never
> denies anything. Item 2i's addition also left the authoritative graph carrying a **cycle**
> (detection ──► baseline ──► producer ──► detection) and a `baseline captured` node missing the
> observation floor its own row had just gained. All five plan-blocking highs and the directly related
> contradictory projections are addressed in this revision, under a **separately approved plan-only
> correction phase with no review authorized** — so the parked round-7 FAIL remains this document's
> current review verdict until a later, separately approved round says otherwise.
> **Post-round-7 correction phases — FOUR, each separately approved, none reviewed.** (1) The five
> plan-blocking highs plus seven directly related contradictory projections. (2) The **dedup clause**,
> after its new acceptance criterion was executed against the unmodified merger and **failed**: the
> fixture as written was a single edge, not a non-transitive chain, and contradicted the numbers printed
> beside it; and connected-components election was still order-dependent because
> `SequenceMatcher(...).ratio()` is asymmetric across the threshold. Both were defects in phase 1's own
> corrections, found by running them. (3) The **protocol legal start** — item 2p, because
> `protocol-approved` was a milestone with no row producing its artifact. (4) The six remaining
> text-accuracy mediums. **The document was corrected four times before any reviewer saw those
> corrections.**
> **Round 8 (2026-09-08) then reviewed them — FAIL, 26 issues (5 high / 17 medium / 4 low), FULL 3/3
> coverage, `plan_blocking_high` 5 → 3, 8 deferred.** It did **not** park: the trajectory improved, so
> the loop exited `blocked_by_high_issues` at iteration 4 of 5. **Round 8 superseded round 7 as the
> current verdict at the time; rounds 9 and 10 have since superseded it — see below. Currency is
> stated ONCE, at the end of this history, and no line above it claims to be current (corrected
> 2026-09-09, round 10, finding [20]).** The finding count is no longer unmeasured, and
> the earlier instruction to "treat the next round as the first review of a substantially different
> plan" is **withdrawn** — a changed document does not reset the ceiling, `high_issues_history` reads
> `[4,3,5,3]`, and any further round appends to that trajectory. Round 8 found the four correction
> phases had introduced structural defects of their own, concentrated in items 2i, 2a and 7.
> **Post-round-8 correction phase — ONE, separately approved, purely technical, NOT reviewed.** (5) The
> three clauses named in that approval: the dedup **edge predicate** restated in full; **deterministic
> blockers excluded from dedup** (the previously prescribed election key was executed and returned a
> *deterministic* false PASS at `LITMUS_ITERATION=3` where the undeduped truth is FAIL); the
> authorization invariant given its missing **PASS direction**; the gate-side honouring readers
> **enumerated completely** (six sites, four of which discriminate by string shape and have no field to
> carry the data); and item 7's probe given a **discriminated result contract** over all sixteen `null`
> sites, including the `scanWindow` collapse that makes `:99` and `:108` indistinguishable one frame
> above `countLines`. **That phase resolved none of round 8's policy questions and edited none of them**
> — and each of the three now carries exactly ONE disposition, in *Still needs Chris*, corrected
> 2026-09-09 (round 9, finding [0]) because the body had marked all three DECIDED while this header
> called them open, with no third surface to break the tie: 2i(B)'s migration/grandfather/ordering is
> **#12**, the `probe_unavailable` allow/deny default is **#13**, and short-circuit distinguishability
> is **#11 — first ANSWERED (B) "out of scope", then REOPENED and ANSWERED (A) by Chris
> 2026-09-09 (`批准840重開11並納入計劃`): the short-circuit provenance distinction and the
> complete-verification requirement are IN SCOPE and IN THIS PLAN, plan-only, authorizing no
> implementation. (B) is retained as provenance in that row; it was reversed because it left
> item 2a's bound (i) asserting that the no-review mints were "NOT thereby unconstrained" while
> both rules that were supposed to constrain them sat out of scope** — and it
> left the remaining round-8 findings untouched.
> **Round 9 (2026-09-09) FAIL — 26 findings, 7 high / 14 medium / 5 low, FULL 3/3, arbiter `opus`;
> 4 plan-blocking high and 9 plan-blocking medium, 8 deferred. `plan_blocking_high` 3 → 4, so the
> trajectory early-stop fired and the loop PARKED (`parked_no_progress`,
> `early_stopped: no_improvement_trajectory`).** A separately approved plan-only phase then classified
> every remaining *Still needs Chris* row and corrected all 13 round-9 plan-blocking findings; each
> carries a `round 9, finding [N]` stamp in the row it repairs.
> **Round 10 (2026-09-09) FAIL — 26 findings, 9 high / 12 medium / 5 low, `run_id bf788871`, arbiter
> `opus`, FULL 3/3; 9 plan-blocking high and 12 plan-blocking medium, 0 deferred. The trajectory
> WORSENED and the loop parked.**
> **Round 11 (2026-09-09) FAIL — 27 findings, 7 high / 16 medium / 4 low, `run_id 34472ac3`, arbiter
> `opus`, FULL 3/3; 7 plan-blocking high and 13 plan-blocking medium, 3 deferred.
> `high_issues_history: [4,3,5,3,4,9,7]` — the trajectory IMPROVED (9 to 7), so the loop did NOT park:
> it took its normal non-park exit and incremented to `iteration: 5`.**
> **Round 12 (2026-09-09) FAIL — 15 findings, 6 high / 6 medium / 3 low, `run_id a1ab7bc0`, arbiter
> `opus`, FULL 3/3; 5 plan-blocking high and 4 plan-blocking medium, 3 deferred.
> `high_issues_history: [4,3,5,3,4,9,7,5]` — the trajectory IMPROVED again (7 to 5), the loop did NOT
> park, and it incremented to `iteration: 6` of `max_iterations: 6` under an operator-approved
> ceiling exception (5 to 6).
> ROUND 12 WAS A FAIL, AND IT WAS THIS DOCUMENT'S CURRENT VERDICT UNTIL ROUND 14 SUPERSEDED IT.
> **DEMOTED TO HISTORY 2026-09-09 (`全部批准`, round-14 finding [12]; UNREVIEWED)** — the round-14 block
> below is the current verdict and states the live ceiling; a second present-tense ceiling
> announcement here is what made two surfaces claim currency at once.
> NOTE ON `state.md`, **CORRECTED in the same pass**: the `early_stopped: no_improvement_trajectory`
> field was a stale residue of round 10's park while rounds 11 and 12 took the normal non-park exit —
> **that reading is now RETIRED, because round 14 genuinely parked and wrote the field itself.** The
> runner still only ever writes it on withholding paths and never clears or reads it, so it remains
> silent about rounds 11 and 12; what changed is that it is no longer stale. Round 12's operative stop
> was `progress_status: blocked_by_high_issues` plus the iteration ceiling of its own round.** All four round-9
> plan-blocking highs were verified genuinely fixed, so the rise is not old findings resurfacing:
> **several of round 10's highs are artifacts of the round-9 corrections themselves** — a decision was
> written into one surface and not propagated to the graph, the acceptance criteria or the counts. The
> approved 2-A/2-B split existed only in prose while the authoritative graph still carried an unsplit
> `2`; round 9's own arrow-direction fix stated a convention the milestone chain then violated,
> re-creating the cycle round 7 removed. **Round 11 reproduced the SAME failure mode: five of its seven
> highs are a decision applied to one surface and not to the surfaces this document itself designates
> authoritative** — the graph, the settling-check cells, the "single normative statement" blocks.
> **Post-round-10 correction phase — ONE, separately approved
> (Chris 2026-09-09, `780和840resume和批准`), plan-only, NOT reviewed.** It covers all 21 blocking
> findings and carries two approved protection decisions: **item 7 RETAINS DENY** (its allow conditions
> are split and its denial transport named), and **items 0 and 9 acceptance are STRENGTHENED**
> (installed-implementation identity; change-time allowlist revalidation).
> **Post-round-11 correction phase — ONE, separately approved (Chris 2026-09-09, `這些可以你自己決定吧？`,
> delegating the routine technical items), plan-only, NOT reviewed.** It covers the round-11 blocking
> set by define-once: a decided value is deleted from every restating surface and replaced by a citation
> to the deciding row. It takes **no** new policy decision, does **not** narrow any promised coverage,
> and surfaced **one capability-retirement question** (*Still needs Chris* #14) rather than silently accepting it.
> **Post-round-11 fallback-preservation phase — separately approved (Chris 2026-09-09,
> `批准840保留fallback方案`), plan-only, NOT reviewed.** #14 is answered as **option (A)**: the built-in
> review agent KEEPS its commit-authorizing role and gains a real completeness envelope — producer,
> marker payload, consumer pattern, fail-closed handling and its acceptance fixtures, specified once
> in item 2i(B)'s **(c-1b)**. Nothing is implemented; the prior review FAIL is untouched.
> **Post-round-12 correction phase — separately approved (Chris 2026-09-09, `批准840本輪文件修正`),
> plan-only, and THIS DOCUMENT IS UNREVIEWED IN ITS CURRENT STATE.** It corrects the round-12
> findings: the `severity_rank` polarity (third round on that prescription, now carrying a required
> executable diagnostic rather than more prose), the over-broad typed-accessor mandate that would
> have inverted `determine_status`'s fail-closed semantics, the fallback envelope's parser/transport
> links and hash extraction, its second branch-qualified consumer, `(c-1b)`'s Stage-1/Stage-2
> placement, the `2i NODE` outcome-neutrality claim, `══▶`'s sufficiency semantics, the fixture-2
> versus item-2a invariant conflict, and the `not_found` justification. **Chris also decided that
> 7a-i is PURELY ADVISORY and that all enforcement belongs to 7b.** Two of the round-12 findings were
> defects THIS correction lineage introduced — the polarity, and a `pre-commit-gate.sh` anchor.
> **THE ANCHOR LESSON WAS RECORDED BACKWARDS AND IS CORRECTED 2026-09-09 (round-13 finding [0];
> UNREVIEWED).** It previously read that a round-11 pass "corrected" the anchor "against the installed
> plugin cache instead of this repository". Measured: `:943` is the CHECKPOINT's value *and* the
> 2.1.15/2.1.16 cache's; `:909` is the branch tree's *and* the 2.1.14 cache's. So the round-12 pass
> REVERSED a checkpoint-accurate anchor toward the older tree while believing it was restoring the
> repository's, and the lesson as written would cause that reversal again. The real failure mode is
> **citing a tree without naming it**, not "cache instead of repository" — which is why the provenance
> rule now requires revision-qualified anchors paired with their predicates.
> **Propagation follow-up, same phase (2026-09-09):** the per-member correction above itself left
> THREE surfaces citing the node-wide prohibition it had just removed — the `2a-env` node's
> rationale, item 2a's status cell, and the "why a sibling" clause. All three are re-cited to
> **(B) Stage 1's** outcome-neutrality rule, which is the clause that actually carries the argument.
> Placement, the separate-cutover requirements and the operator-acceptance semantics are unchanged;
> only the authority each sentence cites moved. **That this correction needed its own correction is
> the document's recurring failure mode, found here by sweeping for the exact retired claim rather
> than by re-reading the edited surface.**
> **Round 13 (2026-09-09) FAIL — `run_id 28762b80`, arbiter `opus`, coverage FULL 3/3, 21 findings
> (4 high / 13 medium / 4 low), plan-blocking 2 high / 6 medium, iteration 6 of 7.** Round 13's evidence is
> **live and NOT archived**; round 12's is archived at `pr840-round12-a1ab7bc0`, 13/13 hash-verified. **Requirements update, 2026-09-09 (Chris ACCEPTED three round-13 acceptance
> requirements; plan-only, NO review):** finding [12] adds an **overall deadline** constraint to item
> 2a's transport list, spanning pages/retries/fallback or an explicitly supported detached lifecycle,
> with a mid-continuation deadline hit retaining findings and yielding a non-authorizing incomplete
> outcome; finding [13] adds a **separately adjudicated iteration-3-and-later medium-only LLM PASS
> stratum** to item 8, with deterministic findings and repeated defects counted apart; finding [14]
> makes the protocol's **required capture fields determine observation ELIGIBILITY**, specified once
> in item 2p and cited from item 2 and the `baseline captured` node, **preserving 2-A/2-B independent
> start authority and changing no graph edge**. **Remaining-findings pass, same phase (2026-09-09;
> UNREVIEWED):** finding **[0]** — the provenance rule now admits REVISION-QUALIFIED anchors and
> requires each gate-script anchor to be paired with its PREDICATE; every `pre-commit-gate.sh` BUILTIN
> citation is re-anchored to `727d4652:...:943/:947/:948` with the branch values named as branch
> values, and the **backwards anchor lesson is corrected** — `:943` was checkpoint-accurate and the
> round-12 pass reversed it. Finding **[16]** — the cache list gains 2.1.16 and "an observed firing
> identifies the version" is withdrawn, since `:943` is common to 2.1.15 and 2.1.16. Finding **[1]** —
> `2a-env` joins the `baseline captured` node's ONE authoritative prerequisite list **as a list entry,
> NOT a graph edge**: under the arrow convention `2a-env ──► "baseline captured"` would encode 2a-env
> being GATED ON the milestone, which bound (i-a) forbids. Finding **[2]** — item 7's partition rule
> is now CITED by the status cell, the Progress row, the graph edge and Chris #13 instead of each
> restating a schedule; every allow/deny-observing fixture and the `run-with-flags.js` lock regen move
> to 7b, the double-ownership sentence is deleted, and `limit=50` is marked **ALLOW**. Stage 1
> outcome-neutrality, the BUILTIN fallback envelope and every other product decision are untouched.
> **Triage pass, same phase (2026-09-09; UNREVIEWED).** **[3] RESOLVED** — `:198` now carries TWO
> kinds (open-time ENOENT ⇒ `not_found` ⇒ ALLOW; every other throw ⇒ `probe_unavailable` ⇒ DENY),
> cited from (4b) rather than restated, with the origin-marker deliverable named (the catch is bare
> and the root re-stat can also raise ENOENT) and an ALLOW fixture plus its vanished-root DENY control
> added to **7b**. **[4] RESOLVED** — the claim that a denial "cannot reach the harness no matter how
> the advisory is changed" is FALSE and withdrawn: `run-with-flags.js:86-87` forwards a delegate's
> `stdout` verbatim and `:258` writes it, so the transport needs **no change to the locked launcher**.
> **[7] RESOLVED** — `:75` splits by thrown error into `uncontained` / `probe_unavailable` /
> `trust_root_unavailable`. **SUPERSEDED by round 14 (`批准840`, finding [8]): two of those three
> branches are unreachable from the only caller, so `:75` maps to `uncontained` alone; item 7's
> reachability correction is the live text.** **[8] RESOLVED** — the "exactly nine kinds" figure is
> struck. **SUPERSEDED by round 14 (`批准840`, finding [11]): the replacement declared a count and
> enumerated one member fewer, so BOTH the membership and the count now come from item 7's canonical
> kind/disposition table and no figure is written beside a list anywhere.** **[17] RESOLVED** — `review-output.schema.json` named as a
> migration surface. **[18] RESOLVED** — "route to pi" re-anchored to the advisory body at `:256`.
> **[19] RESOLVED** — row 13's Class cell now uses the table's vocabulary.
> **[10] RESOLVED 2026-09-09** — D-2 was unrunnable under its own preamble (no sort site, no import
> allowed, and its pair deduplicated so no order existed). Split into **(D-2a)** a non-duplicate
> retention control across different `file`s, explicitly labelled as NOT exercising the rank map, and
> **(D-2b)** the assertion proper, through the duplicate election at `:36-38`, both input orders.
> Both were executed against the real merger before being written down: D-2a retains 2 of 2 in either
> order, D-2b elects the `low` in either order.
> **[5] AND [11] ARE NOW CHRIS-APPROVED PLAN DECISIONS — `全部批准`, 2026-09-09, PLAN TEXT ONLY and
> UNREVIEWED.** Both are behaviour-changing, so each lands behind the gate its own row already
> carries; neither is startable early and neither moves into the outcome-neutral Stage 1.
> **[5] Malformed authorization-bearing fields FAIL CLOSED**, specified once in item 8's
> `determine_status` contract. Four fail-opens were measured by execution before the text was
> written: an ABSENT `severity`, a `null` severity, an UNRECOGNIZED severity (the miscasing `"HIGH"`
> suffices), and a `high` finding with a **NaN** `confidence` all return PASS today, because
> `:72-73` SKIPS what it cannot classify and `nan >= 0.7` is False. `confidence: None` and an
> unparseable `confidence` were already fail-closed and are preserved, not reimplemented. **The
> policy for a VALID `medium` is unchanged** and is pinned by its own fixtures at iterations 1 and 3.
> **[11] Unlocated findings match only other unlocated findings**, specified once in **item 2i(A)'s**
> typed-accessor mandate — **REPOINTED 2026-09-09 (`全部批准`, round-14 finding [13]; UNREVIEWED)**, because
> this entry named item 2a, which carries the convergence contract and not the mandate. The gate is
> named here rather than left implicit: the deliverable lands on the **2i NODE**, and 2i(A) has no
> predecessor. The `line` floor is the **sort sentinel only**; the dedup edge is a
> separate predicate in which locatedness is explicit, so a located and an unlocated finding never
> match at any floor value. Both directions are pinned — two unlocated findings in one file DO
> collapse; an unlocated and a located finding DO NOT, in both input orders.
> **Post-round-14 correction phase — ONE, separately approved (Chris 2026-09-09, `批准840`),
> PLAN TEXT ONLY and UNREVIEWED.** Round 14 ran three reviewers plus a fresh Opus arbiter and
> returned **FAIL — 2 HIGH, 13 MEDIUM, 4 LOW**; `plan_blocking_high` held at 2 → 2, so the
> window-1 trajectory check fired and the loop **PARKED as `parked_no_progress`** with PASS
> withheld. Correction proceeded in **TWO separately approved passes**, both PLAN TEXT ONLY and both
> recorded here rather than in a second block. **PASS ONE (`批准840`)** covered exactly two findings
> plus the references and fixtures directly contradicting them; it is documented immediately below.
> **PASS TWO (`全部批准`, 2026-09-09)** covered the remaining shared-root bundle and the legacy-marker
> policy, and is documented at the end of this block.
> **[0] VALIDATION RUNS BEFORE DEDUP.** Item 8's approved fail-closed validation is pinned to the
> merger's stdin/argv INGESTION point, ahead of `:185`, because `main()` runs `:185 deduplicate`
> before `:186 determine_status` and a record the election drops at `:36-38` is unobservable to
> every reader downstream. Measured before writing: a malformed-vs-valid duplicate pair returns
> **PASS at `LITMUS_ITERATION=3` in BOTH input orders**. A seventh acceptance fixture pins exactly
> that pair at iteration 3 in both orders; item 2i(A)'s exclusion clause is amended to cover dedup
> as an **eliminator** rather than only as a reader, and (D-2a)/(D-2b)/(D-3) gain a scope note —
> they call `deduplicate()` directly, so they stay falsifiable and are NOT authority that a
> malformed record may be elected away.
> **[1] AND [11] ONE CANONICAL KIND/DISPOSITION TABLE.** Item 7 now carries a single table that is
> the sole authority for the union's membership, its count and every disposition; the nine-member
> enumeration that declared TEN is replaced, closing the missing-tenth gap. `trust_root_unavailable`
> had carried DENY at `:75` and ALLOW at `:234-239`, with (4b)'s deny list and Chris #13's ladder
> omitting it entirely; **its disposition is DENY**, on the doctrine (4b) already states for
> `probe_unavailable` — a WORKER DEFAULT under *Still needs Chris* #13, recorded, vetoable by row
> ID, and part of the live-behaviour tightening that row already flags rather than a second one.
> **[8] follows from the same trace:** `resolveContained` has exactly one caller and is not
> exported, and `:224-226` / `:234-239` screen the other two branches first, so `:75` maps to
> `uncontained` alone and a missing target is distinguished from an unavailable trust root **by
> SITE**, not by parsing a thrown message. Two 7b fixtures pin that discrimination.
> **PASS TWO — the remaining bundle, approved `全部批准` 2026-09-09; PLAN TEXT ONLY and UNREVIEWED.**
> It was classified into shared roots first and applied as such, so most entries are one remedy
> serving several findings. **Root 1, define-once:** [13] repoints the [11] header entry from item 2a
> to item 2i(A) and names its gate; [10] withdraws the "launcher must render a DENY" sentence and the
> lock enumeration that contradicted (1-b)'s own pass-through finding; [9] replaces item 2a's "every
> deliverable is locked" over-claim with a citation to the ONE global rule's `2a` bullet; [12] demotes
> the round-12 currency and ceiling claims to history and retires the now-false `early_stopped` note,
> since round 14 genuinely parked and wrote that field; [2]-residue qualifies "stay fail-closed",
> which was false about the incumbent, and adds the schedule reconciliation between startable 2i(A)
> and blocked item 8; [18] drops the 7a-ii half that Chris #10 = (A) had already removed; [17] cites
> #7's resolution. **Root 2, fixtures:** [3] restates (D-2a) as RETENTION only, withdrawing an
> ordering assertion whose rationale contradicted algorithm (α); [4] replaces a pages-less PDF ALLOW
> fixture with the DENY control the `pages` conjunction requires, and strikes the blanket
> media-exemption sentence beside it (quoted once, at its own correction site); [15] fixes the `line` sort floor at the concrete value **`-1`**,
> distinct from the edge predicate's `0`; [16] forbids `additionalContext` on a deny result, because
> `resolveHookResult` tests that key first at `run-with-flags.js:83-84` and would discard the deny.
> **Root 3, propagation:** [6] splits item 8's node so its mutating half carries `baseline captured`,
> mirroring item 9; [7] adds `2a-env` to the promotion rule's collection-time conjuncts, stamps it
> per record, and forbids retroactive qualification of an older dataset. **Root 4, [5]:** the cutover
> REFUSAL of legacy bare-64-hex markers — no grace period — placed in bound (i-b) because it changes
> an authorization, with (i-a) extended to cover BOTH producers so that "bare" identifies the legacy
> population exactly; the indistinguishable legacy genuine/short-circuit population is refused
> wholesale and said to be so, revalidation is the named recovery, and no live marker or token is
> deleted. **What remains open — CORRECTED 2026-09-10, provenance only:** an earlier draft of this
> sentence said "the four LOWs" remained open. That was **false against the artifact**:
> `docs/reviews/pipeline-final-plan/claude.json` records severities `low` at issue indices **15, 16,
> 17 and 18** — precisely the four this bundle corrected. **The one round-14 finding with no approved
> correction is `[14]`** (`medium`, `architecture`, confidence `0.85`, `validation_type:
> new_finding`), which no approval and no classification pass has covered. It holds that **(a)** the
> standing diagnostic (D-2b) asserts a `low` survives against an absent-severity record, which under
> item 8's approved rule is a record that must BLOCK — so the acceptance matrix would institutionalize
> the very elimination item 8 closes; and **(b)** the deterministic-blocker exclusion is scoped by the
> incumbent predicate at `lib/merge-findings.py:45-49`, which tests `severity in ("high","medium")`, so a
> `sast:`/`lint:` finding whose severity is absent, null or miscased is NOT excluded and stays an
> ordinary collapse candidate. **This phase's scope note on (D-2a)/(D-2b)/(D-3) does NOT reach it** —
> that note establishes those fixtures remain runnable and falsifiable, not that D-2b's asserted
> OUTCOME is consistent with item 8's contract. **SUPERSEDED 2026-09-10, BY CORRECTION NOTE RATHER THAN BY REWRITING:** the sentence above
> recorded `[14]` as "open, unclassified and unapproved… a decision for Chris, not for this phase".
> Chris's `全部批准` answered BOTH asks at 23:24, and the first ask's scope was **the remaining
> plan-text corrections — citations, tests and baseline — not an exhaustive index of finding IDs**;
> `[14]` was dropped from the relayed list by a translation slip, and an omission from that list is
> not an operator exclusion. `[14]` is therefore corrected under the SAME existing text-correction
> authority, introducing no new policy: (D-2b) and (D-3) now elect over VALID records, (D-5) carries
> malformed retention here and cites item 8 for blocking there, and the collapse exclusion is keyed
> on source prefix. **Still genuinely open:** every finding's status as reviewed evidence, and the
> round-14 verdict itself. **These corrections are plan text that no round has evaluated — they are
> not a re-scoring of round 14 and no reduction in its finding counts is claimed or implied.**
> No implementation, no round 15, no reviewer invocation, no
> counter or ceiling change, no FAIL acceptance, and no commit or merge were performed.
> **ROUND 15 (2026-09-09) — the round-14 corrections WERE reviewed, and this is now the current
> verdict. FAIL, `run_id f159b035`, iteration 8, arbiter `opus`, coverage FULL 3/3** (Agy FAIL 11,
> Codex FAIL 8, Grok FAIL 8; Mechanism Witness failed and is auxiliary). 25 findings — 2 high
> (1 plan-blocking), 15 medium (9 plan-blocking), 8 low, 7 deferred. `progress_status` is
> **`blocked_by_high_issues`**, NOT a park: `plan_blocking_high` fell 2 → 1 and medium 13 → 9, so the
> trajectory improved and the loop stopped on the **iteration ceiling** instead (`iteration: 9` of
> `max_iterations: 9`). **A further native round therefore required an operator ceiling exception.**
> **ROUND 16 — RAN 2026-09-10 under a finite Photon-decided exception (`max_iterations` 9 → 10;
> `iteration` 9 unchanged; no reset, no initializer).** Run `e9506d0f`, spec hash `af43e74f…` — the
> committed candidate at `34887cb7`. COVERAGE **FULL 3/3** (agy FAIL 10, codex FAIL 6, grok FAIL 10;
> the Mechanism Witness failed and is auxiliary, never a lens). Fresh same-round arbiter verdict
> **FAIL — 3 high / 11 medium / 4 low**; 25 of 26 reviewer findings confirmed against source,
> **grok[6] REFUTED by execution**, one new finding. The loop then **PARKED on the trajectory
> guard** (`plan_blocking_high` 1 → 3, history `[4,3,5,3,4,9,7,5,2,2,1,3]`), `progress_status:
> parked_no_progress`, PASS **WITHHELD**, pending tokens left ARMED. **The stop is now a trajectory
> park, not the numeric ceiling.**
> **POST-ROUND-16 CORRECTION PHASE — ONE, plan text only, UNREVIEWED. PHOTON TECHNICAL DECISIONS
> under standing delegation; NOT new Chris approvals.** Applied: the three HIGH contradictions —
> **[0]** the round-10 blocking-severity paraphrase DELETED so the deterministic-source exclusion is
> stated once, by source prefix alone; **[1]** format determination ORDERED BEFORE the bounded-read
> exemption, `limit` non-exempting for PDF, three fixtures pinned; **[2]** an ingestion parse failure
> made independently NON-AUTHORIZING, with scanner-ARRAY semantics explicitly unchanged — plus the
> existing-policy propagation surfaces [3] [4] [5] [6] [7] [8] [10] [14] [15] [16] [17]. The `NaN`
> clause is PRESERVED and the grok[6] refutation recorded beside it.
> **THE REMAINING FOUR ARE BOUNDED TECHNICAL REALIZATIONS OF ALREADY-APPROVED POLICY — DECIDED
> 2026-09-10 (Photon technical decisions under standing delegation; UNREVIEWED, NOT new Chris
> approvals).** The earlier "new product premises" header was wrong and is replaced: none of these
> introduces a product question, none may be dropped to reach a PASS, and none reverses Chris #11,
> Chris #13, item 8's valid-medium / null-medium iteration pins, round-15 [1]'s object identity, or
> 2i(B)(c-4)'s scanner-array exclusion.
> **[9] `confidence` at item 8's EXISTING ingestion validator — NOW WRITTEN INTO ITEM 8's ROW
> (2026-09-10, round-17 finding [2]).** The rejections and their ORDER (`bool` before `float()`,
> then non-finite, then negative), the measurements that pin them, the fixture count and the
> explicit non-goals are stated ONCE in that row and are CITED here, never restated. A header that
> carried a decision the canonical row did not is precisely the propagation defect round 17 found.
> **[11] The captured-root `{dev,ino}` re-stat before mapping an open-time ENOENT — NOW WRITTEN
> INTO ITEM 7's CANONICAL TABLE, entries 8 and 10 (2026-09-10, round-17 finding [0]).** The
> qualified mapping, the withdrawal of entry 10's "ONLY origin site" claim, the 7b fixture pair and
> the non-goals are stated ONCE there and CITED here. The canonical table is the authority for kind
> membership and disposition; while it disagreed with this header, the fail-open was the table's.
> **[12] Tagged kinds on the probes only — this APPLIES round-15 [1] rather than reopening it.**
> Stated once in item 7's cell; the contradictory round-11 "MUST carry its kind for `run()`"
> sentence and its site→kind mapping extension are withdrawn there, not restated here.
> **[13] The short-circuit's own scanner preconditions — NOW WRITTEN INTO ITEM 2a's BOUND (i-c)
> (2026-09-10, round-17 finding [3]).** The measured sentinel, the paired string-equality predicate,
> the LIST-shape check, the fixtures with their valid-empty negative controls, the checkpoint-versus-
> HEAD anchors and the non-goals are stated ONCE in that bound and CITED here. Round 17 also showed
> the earlier version of this decision was **incomplete, not merely unpropagated**: a sentinel keyed
> on parse failure alone never sees `{}` or JSON `""`, which parse cleanly and still count as zero.
> Bound (i-c) now carries the shape check that closes it; 2i(B)(c-4)'s scanner-array exclusion is
> untouched.
> **ROUND 17 — RAN 2026-09-10. HISTORY. This WAS the current-state record at the close of round 17; it is not current. Every round
> block above it is HISTORY (round-12
> precedent at the head of this file).** Run `a242aede`, spec hash `a8c55fa7…`, iteration 9 of 10.
> **COVERAGE DEGRADED — 2 of 3**: grok exited **124** (timeout) after 1,200,348 ms with zero signal
> and was NOT rescued via droid (cross-provider containment, PR #704); the Mechanism Witness also
> failed and is auxiliary. Under #355 a PASS was therefore withheld on coverage regardless of
> counts. agy FAIL (7), codex FAIL (7). Fresh same-round arbiter: **FAIL — 4 high / 6 medium /
> 3 low**, of which **2 plan-blocking high and 5 plan-blocking medium**, 3 deferred; 13 of 14
> reviewer findings confirmed against source. **The loop did NOT park**: `plan_blocking_high` fell
> **3 → 2** (history `[4,3,5,3,4,9,7,5,2,2,1,3,2]`), a strict decrease, so `check_no_progress` did
> not fire and the ordinary not-converged branch incremented the iteration. **`iteration: 10` now
> equals `max_iterations: 10` — the numeric ceiling is reached again.** (**SUPERSEDED 2026-09-10, round-18 finding [12]; UNREVIEWED:** that sentence restated `max_iterations`, a value the LOOP owns, and it was already wrong when written — `state.md` read 11. Round 17 consumed iteration 10; ceiling figures are read from `state.md` and stamped as measurements, or not stated. This document does not mirror them.)
> **POST-ROUND-17 CORRECTION PHASE — ONE, plan text only, UNREVIEWED; PHOTON TECHNICAL DECISIONS
> under standing delegation, NOT new Chris approvals.** Its subject was PROPAGATION: decisions [9],
> [11] and [13] existed only in this header block while the canonical rows they govern still read
> pre-correction, so the authoritative surfaces carried the fail-opens. Each is now written into its
> canonical row — [11] into item 7's canonical table (entries 8 and 10), [9] into item 8's row, [13]
> into item 2a's new bound (i-c) — and these headers cite those rows instead of restating them.
> Round 17 also found decision [13] **incomplete rather than merely unpropagated**, which is now
> closed by the SHAPE rule at both boundaries. Reconciled alongside: item 6's status cell, the
> honouring-set gate-side reader, the `1 ──► 7a-i` edge direction, and the (D-2a) `:26` anchor.
> **POST-ROUND-15 CORRECTION PHASE — ONE, plan text only, UNREVIEWED. These are PHOTON TECHNICAL
> DECISIONS under standing delegation; they are NOT new Chris approvals and must not be cited as
> such.** It reconciles all TEN blocking findings ([1] `run()` output-compatibility; [2] benchmark
> scope; [3] item-2 restatement; [5] item-8 projection; [6] Standing-fallback scope; [7] item-6
> gating and the projected item-13 node; [8] producer-build stamp; [10] item-2p `2i NODE`;
> [13] mapping supremacy; [16] merge-claim cutover), plus the dependent deferred findings [0]
> (D-5(a) withdrawn), [4] (stale conjunct numeral) and [9] (resolved by the same withdrawal).
> **[0] is the one that impeached this document's own prior correction:** (D-5)(a), added last phase,
> demanded a malformed record be RETAINED through `deduplicate()`; measured against the real merger
> and against this row's own (α)+(β) it is DROPPED in **12 of 12** cases, so the fixture was
> unsatisfiable. It is **withdrawn, not repaired** — repairing it would have required a new
> severity-shaped non-collapse class this plan never approved. The resulting silent drop is recorded
> as a **current interval limitation**, never as desired correctness.
> **AS OF THAT PHASE, the review verdict WAS round 15's FAIL at the ceiling, and no round HAD seen those corrections.** (**TENSE CORRECTED 2026-09-10, round-18 finding [0]; UNREVIEWED.** This block sits BELOW the round-17 record, so its present-tense claim broke the `:78-79` invariant that currency is stated once, at the END of the history, with no line above it claiming to be current. It is history and now reads as history; the single current record is the last block in this section.
> Original wording, preserved: "The current review verdict is round 15's FAIL at the ceiling; no round has seen these corrections."**
> **Nothing in phases 5 or 6
> has been seen by any reviewer, and this document carries no `design-reviewed: PASS` marker.**
> Every finding across every round was addressed by re-measuring the claim rather than
> softening it, and several corrections reversed what an earlier draft asserted: the worker-ownership
> table's `ahead=0 ⇒ no work` rule was **false** and would have destroyed uncommitted work in two
> worktrees; item 13's H1 and H4 were both overstated; #713 and #622 do have design records
> (ADR 0049, ADR 0051) where a draft said none existed. **Round 4 also caught three of round 3's own
> corrections as over-corrections** — item 8's "confidence blocks unconditionally" clause, item 7's
> discrimination premise, and dropping `blueprint-review/SKILL.md:599` from H4 — all three are
> reversed here against re-measured source. Treat this document's own history as the argument for its
> settling checks: every claim here that was not re-run went stale.
> This revision changes only this planning document: no
> `busdriver.json`, hook, gate, prompt, runner, review marker, installed adapter or CI setting is
> touched, and no runtime behaviour changes on merge.
>

## Superseded records

> **SUPERSEDED RECORD — NATIVE RUN `7886ed9f`, REVIEWED SPEC `6cde1dd3fcc1f0897f0757f91b84e54ab85f51dc2802500d04d8cb4cb377baa8`, ITERATION 14 OF 15, `parked_no_progress`, FAIL, COVERAGE DEGRADED 2/3. THIS WAS THE ONE CURRENT RECORD FROM 2026-09-17 UNTIL THE 2026-09-23 RE-BIND ABOVE; IT IS HISTORY NOW, AND EVERY FIELD IN IT WAS READ FROM THE NATIVE ARTIFACTS RATHER THAN RESTATED (RE-BOUND 2026-09-17 root-A on run `7886ed9f`'s own HIGH currency finding, superseding the 2026-09-16 binding to run `59693be3`; Photon `840-plan-blocking-correction-20260917.md`; source-read at HEAD `34887cb7`, NO REVIEW RUN, NOTHING EXECUTED; UNREVIEWED). THE PRECEDING RUN `59693be3` IS SUPERSEDED AND PRESERVED — NOT DELETED, NOT DEMOTED FOR WANT OF AN ARTIFACT — AT THE HASH-VERIFIED ARCHIVE NAMED BELOW.**
> **THE FIELDS, EACH WITH THE FILE IT IS READ FROM.** `docs/reviews/pipeline-final-plan/claude.json` gives `metadata.run_id: "7886ed9f"`, `metadata.iteration: 14`, `metadata.spec_hash: "6cde1dd3fcc1…"`, `metadata.review_timestamp: "2026-09-16T17:04:50Z"`, `metadata.coverage: "DEGRADED 2/3 (reviewer_1 UNFULFILLED — agy exited 124 at 241.3s, droid rescue; codex and grok fulfilled; auditor witness ERRORed and is auxiliary, not counted)"`, `status: "FAIL"`, and **27 issues — 7 HIGH / 16 MEDIUM / 4 LOW**, counted from the `issues` array itself. `docs/reviews/pipeline-final-plan/state.md` gives `iteration: 14`, `max_iterations: 15`, `status: "parked_no_progress"`, `coverage_status: "DEGRADED"`, `fulfilled_lens_count: 2`, `reviewer_1_fulfilled: "false"`, `reviewer_1_reason: "runtime-droid-rescue"`, `high_issues: 7`, `medium_issues: 16`, `low_issues: 4`, **`plan_blocking_high: 4`, `plan_blocking_medium: 6`, `deferred_issues: 13`**, `early_stopped: "no_improvement_trajectory"`. The three reviewer files agree on the run: `agy.json`, `codex.json` and `grok.json` all carry `run_id 7886ed9f` and `spec_hash 6cde1dd3…`, FAIL at 12 / 6 / 10 findings; `auditor.json` carries `status: "ERROR"` with no `run_id` and is auxiliary, never a lens. PASS **WITHHELD**, pending tokens **ARMED**. **THE COUNTER DID NOT ADVANCE FOR THIS ROUND — OBSERVED, NOT CORRECTED:** `state.md` still reads `iteration: 14` and `last_review_timestamp: "2026-09-15T14:19:37Z"`, neither moved by run `7886ed9f`, and no counter, history or timestamp field was edited by hand. **NO ALLOWANCE IS DERIVED FROM THAT COUNTER HERE. WHETHER ANY FURTHER ROUND RUNS IS PHOTON'S DECISION (`840-plan-blocking-correction-20260917.md`), AND NUMERIC HEADROOM IS NOT REVIEW AUTHORITY.**
> **THE REVIEWED SNAPSHOT IS NOT THIS FILE AS IT NOW STANDS.** Run `7886ed9f` reviewed spec `6cde1dd3…`, which was this file byte-for-byte at that moment; that exact preimage is preserved as `candidate-plan.pre.md` in the archive cited below. Every correction since — the 2026-09-17 plan-blocking correction pass, of which this sentence is part — was written AFTER that verdict, so the working draft **has been seen by NO reviewer and is UNREVIEWED**. Nothing in this document claims the edited candidate was reviewed, and no finding count above describes it.
> **WHAT THIS REPLACES, AND HOW CURRENCY IS DECIDED — CORRECTED 2026-09-17 root-A (run `7886ed9f` HIGH; UNREVIEWED).** This record previously declared native run `59693be3` — 23 issues, **5 HIGH / 12 MEDIUM / 6 LOW**, `plan_blocking_high: 3`, `deferred_issues: 8`, coverage FULL 3/3, spec `72492e38…`, `2026-09-16T08:32:00Z` — and before that native run `5e995822` on candidate `98c709e1…` with **4 high (2 plan-blocking) / 9 medium (5 plan-blocking) / 14 low**, 6 deferred, from an extra16 round dated 2026-09-15. **BOTH ARE SUPERSEDED. NEITHER IS DEMOTED FOR WANT OF AN ARTIFACT, AND THE TEST THAT SAID OTHERWISE IS WITHDRAWN.** The withdrawn wording is preserved quoted rather than silently dropped: this paragraph read that `5e995822` "is attested by NO artifact in this repository", tested by "a repository-wide search for `5e995822` returns this plan and nothing else". **THAT TEST IS UNSATISFIABLE BY CONSTRUCTION.** `.gitignore:46` ignores all of `docs/reviews/` as "Machine output — regenerable, and worthless once the review has landed", so **NO review artifact for ANY run is ever at ANY HEAD** — the test demotes every run equally, the current one included, and therefore discriminates nothing; it is false as stated besides, since `5e995822` does occur inside archived native artifacts as finding text. **THE RULE THAT REPLACES IT, AND IT IS A RULE ABOUT ARCHIVES, NOT ABOUT HEAD: a run is ATTESTED when a native artifact carries it as `metadata.run_id` and that artifact sits in a hash-verified archive; a run is CURRENT when it is attested and no attested run supersedes it; a mention in prose or in a finding's text is NOT attestation.** Measured 2026-09-17 by reading `metadata.run_id` across `~/.hermes/reports/840-*archive*/`: all three runs are ATTESTED — `5e995822` at `840-post16-correction-postchange-archive-20260916/` and `840-final15-prearchive-20260916/`; `59693be3` at `840-prereview-archive-20260917/`, 16 payloads under manifest `4340a98352ebde345f3dea24832cd32db474efff42e673e6043a05e74e197d21`, `shasum -c` clean; `7886ed9f` at `840-round7886ed9f-archive-20260917/`, 14 payloads under manifest `7c4bcdd7a125daf75077adaed1a30d889805af8ffa0c3e4a6cdbdf0a5251cbc3`, `shasum -c` clean, and, when this was written, also in the live `docs/reviews/pipeline-final-plan/` tree, which now holds run `bc8c8f18` instead. **THE LIVE TREE IS NOT THE DURABLE RECORD:** Phase 1 of the next round clears it before its reviewers run — which is exactly how run `59693be3`'s files left the disk — so the ARCHIVE is what preserves a superseded run, and the archive is what this record cites. The `5e995822` stamps elsewhere in this document are EDIT PROVENANCE, recording which round prompted a correction; they are neither current-state records nor native proof, and they stay as written.
> **ONE INCONSISTENCY IN THE NATIVE STATE, OBSERVED AND NOT CORRECTED (RE-READ 2026-09-17 against run `7886ed9f`; UNREVIEWED):** `state.md` carries `last_review_timestamp: "2026-09-15T14:19:37Z"` while `claude.json` carries `metadata.review_timestamp: "2026-09-16T17:04:50Z"`, although their severity counts agree at 7 / 16 / 4; `state.md`'s `iteration` likewise still reads 14. **No counter, history, state or verdict file was edited to reconcile this** — it is native review state, recorded here exactly as read.
> **LINEAGE — LOGICAL ROUNDS ARE NOT NATIVE ITERATIONS:** logical round 18 below is the 2026-09-10 record and is HISTORY; the native counter reached 14 through every round the loop ran, and the ceiling was raised 14 → 15 by one approved manual field edit before extra16. **ANCHOR AND INVENTORY RULE — ADDED WITH THIS RECORD:** every implementation node RE-DERIVES its source anchors and its inventories ON ITS OWN START TREE (R1's rule above makes this mechanical); an anchor or list carried forward from an earlier revision is stale by construction, as this document's own history shows. **PRIOR RECORD, NOW HISTORY — ROUND 18 (`e1c65c91`). Every block above it is history, whatever tense it was first written
> in. The post-round-18 block below is UNREVIEWED plan text, not a second current-state record.** Round 18 ran 2026-09-10 on candidate `0832527784bf…` at iteration 10. **Coverage DEGRADED —
> 2 of 3**: grok exited 124 at its native 1200 s budget for the second consecutive round and is not
> droid-rescued by design (PR #704 cross-provider containment); the Mechanism Witness also failed and
> is auxiliary. Under #355 a PASS is withheld on that coverage regardless of counts. agy FAIL (5),
> codex FAIL (7). Fresh same-run arbiter: **FAIL — 3 high / 8 medium / 2 low**; 11 of 12 reviewer
> findings confirmed against source, 1 in part, 0 refuted. The loop PARKED on the trajectory guard
> (`plan_blocking_high` 2 → 3), leaving `progress_status: parked_no_progress`, PASS **withheld** and
> pending tokens ARMED.
> **POST-ROUND-18 CORRECTION PHASE — ONE, plan text only, UNREVIEWED; PHOTON TECHNICAL DECISIONS
> under standing delegation, NOT new Chris approvals, and NOT a review recovery.** All thirteen
> findings are addressed in one pass. Four were genuine policy: **[2]+[9]** explicit per-function
> success payloads (`resolved` / `scanned` / `count`) with BOTH unwrap boundaries named and a
> mandatory contained-over-threshold advisory positive control — the ten kinds and their per-kind
> dispositions are unchanged and no blanket "not a failure ⇒ ALLOW" is introduced; **[5]** scanner
> failures preserved at BOTH upstream normalizers before propagating into the existing sentinel,
> with valid-empty and configured-skip kept distinct from failure; **[3]** ingestion rejection emits
> the merger's existing `internal:merge-findings` HIGH synthetic-diagnostic shape, naming the
> rejected input, so invariant (i) holds even for a mixed run of malformed beside valid-empty input
> — the invariant is not weakened. The remaining nine propagate already-adopted policy into the
> authoritative cells, graph and fixtures: **[0]**/**[12]** currency and the mirrored ceiling figure,
> **[1]** the `══▶` production edge, **[4]** the mixed right-hand side, **[6]** the identity-dependent
> supremacy carve-out, **[7]** the `2a-env` SCOPE line, **[8]** item 12's `12-min` / `12-suite` split,
> **[10]**/**[11]** stable fixture IDs with a derived total and one fixture per enumerated shape.
> **No existing Chris policy decision was reversed, and none was found to be in genuine conflict.**
> This candidate is **UNREVIEWED**: round 18's FAIL and its `parked_no_progress` state stand, and
> nothing in this phase is a review, an acceptance, or a PASS. **COVERAGE CURRENCY CORRECTED
> 2026-09-16 root-A (UNREVIEWED): the coverage DEFICIT named here is ROUND 18's OWN and is
> HISTORICAL. This sentence sits BELOW the one current record at `:428`, so under the `:78-79`
> invariant it may not state currency — the same defect tense-corrected at `:411`. The current
> record's coverage is `coverage_status: "DEGRADED"` with `fulfilled_lens_count: 2` in
> `docs/reviews/pipeline-final-plan/state.md`, source-read at HEAD `34887cb7` (RE-READ 2026-09-17
> root-A after run `7886ed9f`; UNREVIEWED — this cited the superseded run `59693be3`'s `FULL` / `3`,
> preserved at the hash-verified archive cited at `:431`). ROUND 18's DEFICIT AND THE CURRENT
> RECORD'S ARE SEPARATE DEGRADATIONS, NOT ONE RECURRING FACT: round 18 lost reviewer_3 (grok), run
> `7886ed9f` lost reviewer_1 (agy). The FAIL and the
> parked state are unchanged by either, and nothing here is a PASS, an acceptance or a review.**


## Historical handover — item 0 (#713), 2026-08-27


The following is the original investigation snapshot, preserved for provenance. Its pending probes,
line numbers, machine configuration and cleanup suggestions are historical, not current execution
instructions or claims about what this amendment ran. Check merged fixes and installed versions first.
**Live item 0 is the execution-order row; NOTHING HERE IS A WORK LIST** — this section may not state
a deliverable, a count, or a live anchor, and where it once did, the instruction has been struck and
replaced by a citation to item 0, ADR 0049 or ADR 0051 (HISTORY DE-RESTATED 2026-09-12, native
finding [20] MEDIUM; the disclaimer above covers stale *anchors*, which is why it did not cover the
open *work* struck below; UNREVIEWED).

Verified on this host (`claude` CLI, macOS, `/bin/sh` = bash 3.2.57):

1. **Claude Code runs shell-form command hooks via `/bin/sh -c`** (hook logged `$0=/bin/sh`,
   parent comm `claude`, `SHELLOPTS=braceexpand:hashall:interactive-comments:posix`).
2. **A committed `.claude/settings.json` `env: {"SHELLOPTS":"noexec"}` silenced the hook entirely
   and the Bash tool call went through** (throwaway project under the session scratchpad,
   `claude -p … --allowedTools "Bash(echo:*)" --model haiku`). #713 is live, not theoretical.
3. Blast radius is wider than hooks: **every `#!/bin/bash` script run from the Bash tool also
   becomes a silent no-op with rc 0** under that env (`tests/test-freeze-guard-anchoring.sh` and
   `skills/litmus/scripts/run-review-loop.sh --help` both produced 0 bytes, rc 0). zsh ignores
   `SHELLOPTS` (a `#!/bin/zsh` probe ran normally), and the Bash tool itself is zsh here.
4. **The platform primitive #713 asked for exists**: per the hooks reference
   (https://code.claude.com/docs/en/hooks.md), a command hook with `args` set is spawned
   **exec-form (no shell)**; only the shell form goes through `sh -c`. Settings precedence
   (https://code.claude.com/docs/en/settings.md): managed > CLI `--settings` > project local >
   **shared project (overrides user)** > user. `disableAllHooks` exists and is NOT among the keys
   ignored in repository files — so a committed project settings file can plausibly disable every
   hook (ADR 0016 class (b)); **not yet tested empirically**. No documented way for user settings
   to out-rank project settings for `env`/hooks; managed settings
   (`/Library/Application Support/ClaudeCode/managed-settings.json`, absent on this host) do.

Design direction to validate next (four untested claims; (a), (b) and (d) take one `claude -p` run
each, while (c) needs one run PER disposition — five runs — because a single blocking hook would
mask the others. Four of those five are `claude -p` runs; the `ask` case must be driven from an
INTERACTIVE session, because `-p` is non-interactive and `ask` is defined as "prompts the user"
while `defer` is its non-interactive counterpart (hooks reference), so a headless run cannot prove
the prompt appears. The prepared but NOT executed probe for (a) is below):

- (a) exec-form registration `{"command":"/usr/bin/env","args":["-i","PATH=/usr/bin:/bin","bash","…"]}`
  runs despite committed `SHELLOPTS=noexec` (expected: yes — `env -i` wipes it before bash starts);
- (b) whether stdin JSON still reaches an exec-form hook, and how `env -i` interacts with it —
  that pair is the actual untested claim. `${CLAUDE_PLUGIN_ROOT}` substitution inside `args` is
  NOT open: the hooks reference (https://code.claude.com/docs/en/hooks.md) documents that "path
  placeholders like `${CLAUDE_PLUGIN_ROOT}` are substituted into `command` and into each `args`
  element as plain strings", which is exactly what lets us locate `sanitized-gate.sh` /
  `sanitized-node.sh` even though `env -i` wipes the exported variable (it must therefore be
  passed as an `args` value, not read from the environment). Keep a local probe for this only as
  an installed-version compatibility check, not as a discovery;
- (c) whether an exec-form hook still blocks in each disposition the gates use, kept as separate
  cases: exit 2 (a blocking error in its own right, which supersedes any JSON on stdout); the
  legacy top-level `{"decision":"block"}` the contained gates actually emit
  (emitted by `hooks/gate-scripts/pre-commit-gate.sh` and siblings — the snapshot's `:50` was a
  comment, not the emit, and this section does not carry the live anchors: see item 0. STRUCK
  2026-09-12, native finding [20] MEDIUM; UNREVIEWED); and the current
  `hookSpecificOutput.permissionDecision: "deny"` + `permissionDecisionReason` at exit 0
  ; and `hookSpecificOutput.permissionDecision: "ask"` at exit 0 — the disposition `hooks/gate-scripts/careful-guard.sh:2272` actually emits — which must still force the user prompt under exec form, not silently allow or deny, and which is therefore the one case that has to be driven interactively rather than under `claude -p`. Also how a
  failed spawn is treated (the `|| exit 2` fail-closed tail cannot exist in exec form — the
  disposition must live entirely inside the wrapper);
- (d) whether a committed `"disableAllHooks": true` silences hooks (if yes, that class cannot be
  closed inside the plugin: document as platform limit, file upstream, and lean on the
  operator-owned rails — `core.hooksPath` is already `~/.codex/git-hooks` on this host, and branch
  protection's required checks).

If (a)–(c) hold: ONE launch-boundary change — moving the contained gate registrations in
`hooks/hooks.json` to a launch form a repository-controlled `env` block cannot silence. **STRUCK
2026-09-12 (native finding [20] MEDIUM; UNREVIEWED): the entry count this sentence carried was
measured wrong and, more importantly, it is not this section's to state — #713 LANDED as ADR 0049
and #713 is CLOSED, so there is no pending launch-boundary work here and no design doc to write.
See item 0 and `docs/adr/0049-hook-exec-form-launch-boundary.md`; the surviving exec-form
registrations and their rationale are item 0's, cited there and not restated here.**
What this handover records are the facts the review of this plan established, as constraints and a
test matrix that design must pass — deliberately not as a mechanism sketch, because every sketch
attempted here grew a new bypass per review round. Facts: exec form substitutes only the documented
path placeholders and passes `$HOME`, `${XDG_CONFIG_HOME:-}`, `${PR_GRIND_CODEX_RETRIGGER:-}` and
`$CLAUDE_HOOK_EVENT_NAME` literally, so today's capture-then-`env -i` shell strings cannot be
transcribed into `args`; a bash first hop imports `BASH_FUNC_*` (which overrides builtins,
including `exec`) before its first line runs; any dynamically linked first hop is subject to
`LD_PRELOAD`/`DYLD_*` (statically linked binaries, and SIP-protected system binaries on macOS, are
the known exceptions); `BUSDRIVER_ORIG_HOME` is created from the outer `HOME` by the registration
and does not pre-exist; `PR_GRIND_CODEX_RETRIGGER_PHRASE` is deliberately never forwarded. Required
tests: (T1) each of `SHELLOPTS=noexec`, `BASH_ENV`, `BASH_FUNC_exec%%` and — where the chosen first
hop makes it closable — `LD_PRELOAD`/`DYLD_INSERT_LIBRARIES`, set in a committed `settings.json`
env and driven through a registration, still yields the gate's decision; (T2) the gate observes the
same values today's shell strings hand it (`HOME` via passwd, `XDG_CONFIG_HOME`,
`BUSDRIVER_ORIG_HOME`, `CLAUDE_HOOK_EVENT_NAME`, the enumerated retrigger kill switches — and not the
phrase), proven by diffing the gate's environment under the old and new launch; (T3) stdin JSON
arrives intact and every current disposition (exit 2, legacy `{"decision":"block"}`,
`permissionDecision` `deny` and `ask`, failed spawn) behaves as today; (T4)
`scripts/ci/validate-hooks.js`, `tests/test-node-hook-containment.sh` and
`tests/test-gate-env-containment.sh` pin the launch form for every contained gate (fail-closed pin,
not prose). Whatever the design cannot close it states as a residual with an upstream issue
(Claude Code should refuse or scrub loader/shell-behavior keys from repository-controlled `env`),
and the closure of ADR 0016's named residual is recorded in a new ADR.
`#622` (a conflict-free `git merge` commits without litmus because the `commit`-token pre-filter
never fires and `git_commit()` returns `IS_GIT_COMMIT != yes` — **the snapshot's `:112-115`,
`gitcmd_detect.py:2654`, `_scan_commit` `:2553` and `pre-commit-gate.sh:184` anchors are STRUCK
2026-09-12 (native finding [20] MEDIUM; UNREVIEWED): they were re-measured and no longer hold, and
the live filter and bail anchors are item 0's to state, cited there and not repeated here; the
merge-commit effect itself is ADR 0051's**) is independent of #713 and gets its own design doc
(`docs/plans/2026-08-27-commit-gate-effect-complete-622.md`, blueprint-reviewed). Twelve litmus
rounds on this plan showed that any mechanism sketched here in prose grows a new bypass per round,
so this handover states one invariant and a test matrix, not a mechanism. Invariant: while a
review marker is outstanding, no invocation may create a commit, move HEAD, or replace the
index/tree the marker was bound to unless the marker provably binds to exactly the repository,
index and tree that invocation will commit; anything the gate cannot prove is refused
(fail-closed), and the effect check in `hooks/gate-scripts/post-commit-consume-marker.sh:201-206`
stays audit-only defense in depth (at PreToolUse HEAD has not moved, at PostToolUse the commit
already exists). Facts the design must account for — each already produced a bypass against a
verb-list sketch: the marker binds to `git diff --cached` before the command runs; git aliases
(`-c alias.x=…`, repo-local and global `alias.*`); last-wins option overrides (`--no-commit` then
`--commit`, `--squash` then `--no-squash`); `pull` (fetch + merge/rebase; `--ff-only` moves HEAD
with no commit to review); fast-forward under `--no-commit`; sequencer `--continue`/`--skip`
auto-processing the remaining `sequencer/todo` entries, and the absence of a universal
behavior-preserving two-step form (`rebase`, `am` likewise); compound commands that mutate state
and commit in one tool call; repository/index redirection via `GIT_DIR`, `GIT_INDEX_FILE`,
`GIT_WORK_TREE`, `GIT_COMMON_DIR`, `GIT_OBJECT_DIRECTORY`, `GIT_NAMESPACE`,
`GIT_DISCOVERY_ACROSS_FILESYSTEM`, `--git-dir`/`--work-tree`/`--bare`, whether on the command or in
a committed settings `env` block that the `env -i`-contained gate never sees (the hook payload
carries no env fields — the design must decide whether that forces command-level refusal of every
override, or enforcement in a native git hook that sees the real environment). Required tests:
every case above, plus the original conflict-free `git merge`, asserted as a pre-use refusal — not
after-the-fact detection.

Prepared probe (not run — operator stopped the session before execution):

```bash
# in the scratch project: .claude/settings.json
{"env":{"SHELLOPTS":"noexec"},
 "hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/usr/bin/env",
   "args":["-i","PATH=/usr/bin:/bin","bash","-c","printf 'EXEC_FORM_RAN stdin=%s\\n' \"$(cat | wc -c)\" >> hook.log"]}]}]}}
# then: claude -p "Run exactly this shell command and reply with its output: echo probe" --allowedTools "Bash(echo:*)" --model haiku
# expected: hook.log contains EXEC_FORM_RAN with a non-zero stdin byte count.
```

Session artifacts: empty branch `feat/read-route-gate` (no commits — delete or reuse for item 7);
operator config changes already applied: `~/.claude/busdriver.json` `pi` → `pi_read`, model
`cursor/auto` (backup `busdriver.json.bak-20260827`); scratch project at the session scratchpad
`hookshell-test/` (throwaway). Nothing in this repo is committed yet — this file is untracked.
