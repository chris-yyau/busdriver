# Item 2p — Review-yield protocol DRAFT (Item cell)

> **INDEPENDENT DESIGN FILE: BINDING, AND UNREVIEWED.** This file is part of the requirements of
> `docs/plans/2026-08-27-pipeline-final-plan.md` (the parent). The parent cites it at item 2p's Item cell in the execution-order table and does
> not restate it. It is reviewed on its own: `init-design-review.sh docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-2p-review-yield-protocol.md`, then
> `run-design-review-loop.sh`. Its review verdict covers only this file's spec hash. A verdict on the parent
> does not cover this file, and a verdict on this file does not cover the parent. It is not history.
>
> **Context for a reviewer who reads only this file.** The body below was moved verbatim from the parent on
> 2026-09-23 (Chris-approved split), and this header was added the same day; the body is unchanged. Item
> numbers, node names such as `2a-env`, `baseline captured` and `protocol-approved`, and bound labels such as
> (i-a), (i-b), (2-ORD) and (2-CAP) are defined in the parent's execution-order table (§ *Execution order
> and acceptance*) and § *Still needs Chris*, and, since the parent's SECOND MOVE (2026-09-24), in the
> children: the dependency graph, *Standing fallback*, *Recommended next actions* and § *Item 2* in the 2p
> file; § *Item 2i* and § *Item 8* in the item 8 file; § *Item 2a* in the (i-a) file; § *Item 7* in the
> item 7 file; § *#840 proposed revisions* in the 2p file. The parent keeps only one-line pointers there (2026-09-26; UNREVIEWED). A lens reviewing this file receives this file and is not assumed to open the parent or the checkout.
> Line anchors `:NNN` into the parent point at the parent as it stood before the 2026-09-23 splits. Anchors
> into other files name their own tree or checkpoint.

**Review-yield protocol DRAFT** (new 2026-09-08; the second missing legal start, found the same way item 2i's was). `protocol-approved` is a milestone on the critical path — **its edges are the dependency graph's, cited here and NOT restated** (corrected 2026-09-09, round 9 finding [24] — an earlier chain omitted 2p, the very node this row adds — re-glyphed 2026-09-09, round 10 finding [2], and SPLIT 2026-09-09, round 11, because restating it here as a single `══▶` chain said one milestone produces another, since `──►` now means dependency only and this chain is a production chain) — but **no row produced its artifact**. The drafting sat implicitly inside item 2's BLOCKED cell, so the document that the whole measurement chain waits on could not legally be started, exactly the defect item 2i exists to fix one level up. This row is that start. **Scope: author `docs/reviews/review-yield/protocol-v1.md`** with every section item 2 names — sampling unit; the required cohorts (commit vs PR mode, local litmus vs GitHub bot, backend/model, prompt/policy/harness/route revision, **and hook-installation state per repository per observation window**, **and — ADDED 2026-09-13 (native 79ad7ef4 finding [9] MEDIUM; UNREVIEWED) — the SCANNER CONFIGURATION in effect for the observation, in four parts: (1) WHICH scanners ran, because `run_sast_scan` runs Semgrep, ShellCheck and TruffleHog each CONDITIONALLY on what is installed (`skills/litmus/scripts/lib/sast-runner.sh:255-277`) and runs none of them when `LITMUS_SKIP_SAST=1` (`:246-249`), so the scanner set varies by machine and by observation and is recorded on no other surface; (2) a RULE-SET DIGEST for Semgrep, because `_sast_run_semgrep` invokes `semgrep scan --config auto` (`:85-89`) and `auto` names a REGISTRY RESOLUTION rather than a rule set — the same string can mean different rules on different days; and (3) each scanner's VERSION plus the effective ShellCheck rule list from `LITMUS_SHELLCHECK_ENABLE` (`:126-135`), since either changes findings with the scanner set held fixed (anchors and part (3) corrected 2026-09-13, native b5bddf50 MEDIUM, verified at `727d4652`; UNREVIEWED), AND ShellCheck's ambient configuration — the effective `SHELLCHECK_OPTS` value and the content digest of every `.shellcheckrc` the run actually resolved (or a recorded statement that the run isolated both) — because either also changes findings with the rule list held fixed (added 2026-09-13, native 2a9a6900 finding [8]; UNREVIEWED). **(4) THE MARKDOWN STAGE, WHICH PARTS (1)–(3) DID NOT REACH — added 2026-09-23 (native run `58a6b41b` MEDIUM, arbiter-confirmed; plan-only, UNREVIEWED).** Parts (1)–(3) cover only `run_sast_scan`'s three scanners. `lib/markdown-checker.sh` also runs, driver-sourced (`run-review-loop.sh:2188`, called at `:2978`), and its findings are merged beside them: `source: 'lint:markdownlint'` (`:60`) and `lint:url-check` (`:148`, `:158`). Every `lint:` finding at `high` or `medium` is a deterministic FAIL under `_is_deterministic_blocker`, so this stage changes verdicts and elapsed time as the other three do. The capture therefore also records: (a) the MARKDOWN CHECKER IDENTITY, meaning which executable `:25-32` selected (`markdownlint-cli2`, `markdownlint`, or neither); (b) that executable's VERSION; (c) the CONFIG DIGEST, the content digest of every markdownlint configuration file the run actually resolved (or a recorded statement that the run isolated them); and (d) the `LITMUS_CHECK_URLS` value (`:198`) together with its timeout environment, the effective `LITMUS_MARKDOWN_TIMEOUT` (default 5 s, `:69`). **ELIGIBILITY:** an observation in which the markdown lint ran and that lacks (a)–(c), or in which the URL check ran and that lacks (d), is INELIGIBLE and does not count toward the floor **N**. This is the same consequence as the other missing capture fields below. A run whose staged diff held no `.md` file (the configured skip at `:22`) did not run the stage, and records that fact instead. **SETTLING CONJUNCT FOR THIS ARTIFACT — ADDED 2026-09-13 (native 2a9a6900 finding [5]; UNREVIEWED):** the drafted artifact carries, per contract version, item 2a bound (2-CAP)'s T2–T4 CENSORED-STRATUM declaration with its sampling rule, and the hard page cap P TRANSCRIBED from that contract version (P = 3, item 2a OVERFLOW row); `protocol-approved` is UNMET without both (graph node; bound (2-CAP) and *Still needs Chris* #15 cited, not restated). Scanner findings enter the merger, drive status, decide short-circuit eligibility and consume elapsed time, so without both a before/after comparison can move while every revision the protocol pins stays constant, and the change would be attributed to the pipeline instead of to the registry**); the floor **N** of reviews classified `completed-with-findings-adjudicated`, as a concrete number; the adjudication procedure; how immature downstream-escape data is handled; **and the REQUIRED CAPTURE FIELDS per observation, which determine ELIGIBILITY — ACCEPTED 2026-09-09 (Chris, round-13 finding [14]); UNREVIEWED.** An observation counts toward the floor **N** only if it carries the per-observation dimensions the approved protocol declares — at minimum per-reviewer findings, superseded attempts, failed dispatches, **and — ADDED 2026-09-12 (native 4efaea28 finding B6 `architecture`, conf 0.6; UNREVIEWED) — truncation-detectability at capture time, carried by **the per-reviewer `completeness` value item 2a declares** (not a field of this row's own invention), CAPTURED BY ITEM 2-A and defined below — field named and made observable 2026-09-13 (native 79ad7ef4 finding [2] HIGH; re-corrected the same day to reuse item 2a's enum after the count-based version was rejected; UNREVIEWED)**, none of which existing records can supply. **Why the fourth field is needed:** item 2i(B) Stage 2 sits DOWNSTREAM of `baseline captured` and is enabled atomically with the FIRST AUTHORIZING READER of `completeness` (item 2i(B)'s Stage 2 clause; this surface re-keyed 2026-09-13, native 2a9a6900 finding [1]; UNREVIEWED — it previously named item 2a's first complete producer, the retired trigger), and the row states the cost plainly — truncation DETECTION is unavailable for exactly that interval. Accepting that interval is a defensible choice and is not the defect. The defect is downstream: **the baseline dataset is captured DURING that interval**, so it can be composed largely of reviews minted as well-formed `{status: PASS, issues: []}` verdicts whose completeness is unknown and unknowable, with no cohort marking anywhere. **The item-0 form (b) stamp does not reach this** — that limitation is scoped to the SCOPE OF THE MEASUREMENT (whether the baseline may be captured over a partially-closed gate, stamped "provisional, gate partially closed at `<sha>`") and says nothing about completeness DETECTABILITY, so a baseline carrying the item-0 stamp is still silent on this cohort. Therefore an observation captured before completeness detection is operational is recorded **INELIGIBLE — one rule, no alternative branch, and it does NOT count toward the floor N.** **THE EARLIER DISJUNCTION IS DELETED, NOT ANNOTATED — CORRECTED 2026-09-12 (native c94fb702 finding [0], codex issues[0] + grok issues[0] `architecture`, conf 0.95; UNREVIEWED).** The prior wording offered "recorded INELIGIBLE, **or** segregated into a declared PRE-DETECTION COHORT" and then assigned the deciding question ("whether floor N may be met from that cohort") to the `baseline captured` node — which states its prerequisite list and CITES 2p for eligibility, and so never answered. **Two authorities, neither deciding: the exact define-once failure this document exists to prevent, committed by a correction meant to tighten eligibility.** With the surrounding text already asserting ineligibility, the open "or" collapsed to the branch that closes a cycle — N needs detection; detection needs Stage 2; Stage 2 is enabled atomically with item 2a's first complete producer; that producer was then the convergence-policy half (history: bound (2-CAP) now places the first emitter in `2a-env`, and Stage 2 keys on the first authorizing reader); the graph gates that half on `baseline captured`; which needs N. The milestone was unreachable under this document's own text. **THE RESOLUTION IS DETECTION-FIRST, NOT A WEAKENED FLOOR (Chris, 2026-09-12).** The minimal capability lands BEFORE the milestone, in the same pre-baseline position and for the same reason bound (i-c)'s (2-ORD) split moved the minimal non-authorizing reader into `2a-env`: relocate the minimal capability earlier rather than redefine what the milestone measured. **WHAT "DETECTION-CAPABLE" MEANS IS A DERIVED PREDICATE WITH AN OWNER, NOT A STAMP — CORRECTED 2026-09-13 (native 79ad7ef4 findings [1] and [2] HIGH; UNREVIEWED).** The 2026-09-12 wording required "a MINIMAL COMPLETENESS-DETECTION PRODUCER — enough to stamp each captured observation `detection: available`, and nothing more", owned by no row. Two defects: an **unconditional stamp has no false branch**, so it CERTIFIES a capability instead of observing one — and `grep -rn completeness skills/litmus/scripts/` returns NOTHING at HEAD (no producer, no field, no reader, measured 2026-09-13), so every row would have carried `available` while nothing could detect anything; and a producer **owned by no half** is the "named deliverable with no owner" defect this document repairs elsewhere. Replaced by **REUSING THE FIELD THIS PLAN ALREADY DECLARES: the per-reviewer `completeness` value of item 2a's enum (`complete`, `truncated`, `errored`, `cap_exhausted`, `unstated`) — CITED HERE, DECLARED THERE, NEVER RESTATED** — corrected again 2026-09-13 (Photon rejection of this row's own first 2026-09-13 wording under Chris's approval; recorded at *Still needs Chris* **#15**; UNREVIEWED). **OWNED BY ITEM 2-A** for capture — the INSTRUMENTATION half, whose deliverables are item 2's own cell — so the chain is 2p declares → 2-A captures → 2-B assembles → the milestone counts, the layering already in use, and it adds **NO row, NO node and NO field**. **CAPTURED PER ATTEMPT, at the dispatch boundary, never only as a merged value:** the per-attempt records (granularity and sites: item 2-A's CAPTURE GRANULARITY paragraph, cited) are what keep a failed dispatch and every superseded attempt observable instead of folded away. **WHICH ATTEMPT'S VALUE IS THE REVIEWER'S — RECONCILED 2026-09-13 (G5; Chris approved reading A, `840-g5-lease-approved.md`; UNREVIEWED).** The per-reviewer `completeness` value that eligibility reads is the value of that reviewer SLOT's **final accepted attempt** — item 2a bound (ii)'s existing aggregation, cited, not restated — so a slot that exhausts its attempts without a usable review is `errored` and INELIGIBLE, never skipped, and no incomplete final output becomes eligible. **Superseded and failed attempts are RETAINED with their terminal classification for cost, retry, failure-rate, backend-attribution and provenance statistics; they are not completeness values of the slot.** The reason is source-bound, not stylistic: at the checkpoint both attempt loops (`_execute_codex`, `_run_review_with_retries`) end on the first successful attempt, so a superseded attempt is always a FAILED one, and reading every recorded attempt would make eligibility a filter on infrastructure history — a byte-identical nine-finding `complete` review would be excluded when one rate-limited attempt, or a full-window timeout rescued by droid, preceded it, and counted when it did not: the sampling-bias class this row rejects. This row's previous wording ("the per-reviewer record is what keeps a failed dispatch (`errored`) and a superseded attempt observable instead of folded away, and any merged value is computed from those") admitted that reading; it is superseded here, with the preimage archived at `~/.hermes/reports/840-g1g7-preimage/`. Any merged value is computed from the final accepted attempts by the aggregate FOLD's total precedence item 2a already states — cited, not restated. **Scope of this reconciliation: 2p's eligibility input ONLY.** It changes no other denominator and no sampling unit — item 2's requirement that failed dispatches and superseded retries enter its failure and cost denominators stands, and the sampling unit and field names stay the protocol's. Rejected-if-absent by the same dataset VALIDATION CHECK this row already requires. **THE ELIGIBILITY RULE — AND NO COUNT APPEARS ANYWHERE IN IT:** an observation counts toward N only if **it has AT LEAST ONE participating reviewer slot and EVERY slot's final-accepted-attempt `completeness` value is `complete`** — for a continuation chain, that value is the chain's terminal value under bound (2-CAP), and only an observation of the contract version the baseline measures is eligible. A zero-participant observation — the short-circuit PASS dispatches no reviewer — is never eligible (item 2a: "a merge with NO participants is `unstated`") and is recorded as item 2's separate short-circuit cohort. Any other value — `truncated`, `errored`, `cap_exhausted` — and any absent, unparseable or `unstated` value make that observation **INELIGIBLE**. It **FAILS CLOSED** and admits no third disposition: this is item 2a's existing "missing or not `complete` fails closed" rule applied to ELIGIBILITY, not to authorization, and no new rule is owed. **A HIGH-YIELD REVIEW COUNTS.** A review reporting nine findings and stating `complete` is ELIGIBLE on exactly the same terms as one reporting one; issue count is not an input to eligibility, here or anywhere else in this row. **THE COUNT-BASED PREDICATE THIS REPLACES IS REJECTED, recorded rather than smoothed over.** This row's first 2026-09-13 wording made an observation eligible only if its issue count was strictly below both per-iteration caps. Three defects, each disqualifying on its own: it **excluded every at-or-above-cap review**, so N was drawn from one- and two-finding reviews only and the baseline measured review YIELD on a sample with the high-yield tail removed; it treated an **under-cap count as proof of completeness**, which is an assumption dressed as an observation; and it was a **DEFINE-TWICE on this very enum** — item 2a declares `completeness` expressly "to describe this defect (a well-formed `{status: PASS, issues: []}` produced by the 3-new drip cap at `init-review-loop.sh:466`/`:556`)", which is the same defect, so the second field was precisely the failure this row's own "name the field, or it will be built twice" bound exists to prevent. **The claim that the two were "a different mechanism on a different path" is WITHDRAWN as false.** No sampling bias is accepted at `protocol-approved`; the earlier attempt to route one there is deleted, not relabelled. **WHAT THIS CONTRACT DETECTS, AND WHAT IT CANNOT — part of the requirement, not a caveat on it.** It detects **KNOWN withholding by a COMPLIANT producer**: a reviewer that stopped at a cap says so, and the value is in the record where 2-A can capture it. It **certifies nothing about discovery** — a producer that withholds and states `complete` is indistinguishable from one that had nothing more to report, the same irreducible class `run-review-loop.sh:1278` records as *mitigated, not eliminated* — and **no stronger claim is made anywhere in this row**, because no signal this plan has can support one. **The weaker fact at HEAD is what makes the producer a PREREQUISITE rather than an improvement:** the reviewer output contract (`skills/litmus/scripts/init-review-loop.sh:440-470`) carries `status` and `issues[]` alone — no completeness, withheld or total-found field — and nothing truncates the issues array harness-side (the only cap that bites, `run-review-loop.sh:1086`, refuses an oversize DIFF rather than trimming findings), so a three-issue response from a reviewer that found three and one from a reviewer that found nine and reported three are **byte-identical**. Measured at HEAD 2026-09-13: `grep -rn completeness skills/litmus/scripts/` returns nothing — no producer, no field, no reader. **SEQUENCING:** the per-response statement AND complete-result collection land ahead of capture, and the baseline measures that reviewer version while earlier observations stay a separate historical cohort; what moves, how a chain terminates, and what stays unresolved are stated once as bound **(2-CAP)** in item 2a and cited here. **N is met ONLY from detection-capable observations. Pre-detection rows are never rounded up, never counted, and no stamped limitation makes them countable** — the limitation stamp remains required on the artifact for the item-0 form (b) reason, but it records a bound on the measurement and is NOT an eligibility waiver. The rejected alternative is named so it is not reproposed: letting the cohort count toward N with a stamp would have bought a green milestone by redefining what it measured. **This adds NO ARROW EDGE — CORRECTED 2026-09-13 (native 79ad7ef4 finding [0] HIGH; UNREVIEWED).** The 2026-09-12 wording said *"This DOES add one graph edge (minimal detection producer ──► `baseline captured`)"* and the graph duly carried that edge — which under the convention defined once there (right side a quoted milestone ⇒ dependent ──► gate) said the PRODUCER WAITS ON the milestone whose N it exists to enable. That **inverted finding [0]'s cycle instead of removing it**, and it contradicted this row's own statement, one paragraph below, that the graph is unchanged. The edge is **DELETED**; the capability is carried as an ENTRY in the `baseline captured` node's ONE authoritative prerequisite list — **item 2-A** — the same treatment 2a-env (round-13 finding [1]) and item 2i (round-18 finding [1]) already receive, for the reason that node states: prerequisite-of is the opposite direction and the list is where it belongs. It still partially reverses the current 2i/2a ordering for that one capability, so the earlier claim that B6 changed no edge stays WITHDRAWN — for that reason, not because an arrow was added. 2-A/2-B independent start authority is untouched, and the full Stage 2 policy work stays exactly where the graph already puts it. The protocol names those fields and the dataset carries a **VALIDATION CHECK that REJECTS an observation lacking them**, so ineligibility is mechanical rather than an adjudicator's judgement; an observation captured before the required capability is operational is recorded **INELIGIBLE**, never rounded up. **This constrains what COUNTS, not who may BEGIN — neither half starts on the other's authority, and this clause adds no start edge:** 2-B stays startable on its own edges, and 2-A starts only after item 1 AND `2a-env`, the parent graph's gate for it, exactly as *"Neither half may be started on the other's authority"* requires (aligned with the parent 2026-09-24; plan-only, UNREVIEWED). **STATED EXACTLY 2026-09-13 (same correction; UNREVIEWED)** because this clause previously read "the graph is unchanged" while the same pass was adding an edge to the graph: what changed is that the 2026-09-12 producer ARROW was DELETED and the `baseline captured` node's prerequisite LIST gained the entry `item 2-A`; what that pass left unchanged is the START authority of both halves and every `──►` edge that governs it; 2-A's start edges are now the parent graph's `1 ──► 2-A` and `2a-env ──► 2-A`. Finishing 2-A still grants 2-B nothing — 2-B may collect before 2-A is operational, and every row it collects is then INELIGIBLE. It closes the gap that the floor bounds observation COUNT and adjudication but not per-observation DIMENSIONS, so dataset production could otherwise legally precede the capability its own protocol depends on. **It depends on neither Chris #2 nor item 1 nor item 2i**, so it is startable today. **The Chris #2 form is a FIELD in the draft, not a precondition for writing it:** the cohort list is knowable now, and only the *decision* of whether the baseline is captured under form (a) close-the-class or form (b) bounded tranche depends on #2. The draft records that field as **form (b), the value Chris #2(i) answered — CORRECTED 2026-09-09 (round 10, finding [4]).** It previously read "UNSET, pending Chris #2", which made this row's acceptance and the *Standing fallback* — the surface this document designates the normative statement of the split, and which states that #2 "is SET to form (b), and item 2p's draft must carry that value" — **mutually unsatisfiable for the same field of the same artifact**: a draft passing one was rejected by the other, so the row created specifically to give protocol drafting a legal start had no completable definition of done. The value is **cited from *Still needs Chris* #2, not restated as an independent decision here**, so a later amendment there moves one copy. "UNSET" survives only as the historical pre-answer note it always was; **filling the field in is not this row's decision and may not be inferred — it is transcription of a recorded answer.** **Drafting is NOT approval, and this row cannot reach the milestone.** Writing the document does not satisfy `protocol-approved`, does not decide Chris #2, does not authorize collecting a single observation, and unlocks no mutating half of any item. The draft carries a visible header saying so. Acceptance owner is unchanged: **the operator (Chris)**, and `protocol-approved` is reached only by that acceptance, only after the **2i NODE** is complete (scope defined once on the dependency graph; not restated here) — **DISAMBIGUATED 2026-09-10 (round-15 finding [10]; UNREVIEWED)**, because the graph's own governing rule is that "item 2i" on the graph means the **2i NODE**, not the whole 2i row, and a bare "item 2i" here read as the row and so silently imported (B) Stage 2 into this milestone's prerequisites. Keep the three stages distinct — **drafting (2p) → approval (`protocol-approved`) → capture (`baseline captured`)** — and never collapse two of them into one act.

---

## Moved from the parent 2026-09-24: § *Item 2*

> **MOVED VERBATIM (2026-09-24; Chris-approved shrink; plan-only, UNREVIEWED).** The text below was the parent's § *Item 2*, at parent spec `8bfd530e…`; the parent keeps a one-line pointer to this file at its place. It binds as part of this file and is reviewed with this file's spec hash; a verdict on the parent does not cover it. Inside it, "this file", "this document", "above", "below" and line anchors `:NNN` into the parent refer to the parent as it stood before this move.

**Review-yield ledger spike** — unique defects per reviewer/gate, duplicates, false positives, downstream escapes, tokens, elapsed. Baseline BEFORE any policy change. **[#840 adopted, with its cost stated]** Extend the existing metrics/history rather than build a second orchestration system — **but the existing record cannot carry the dimensions this item requires, and saying so is not a licence to build one.** Verified at the checkpoint — **corrected 2026-09-08, the earlier "called once" was false**: `log_review_metrics` is called **TWICE** — at **`run-review-loop.sh:3107`** on the short-circuit path, with a synthetic `{"status":"PASS","issues":[],"short_circuit":true}`, and at **`:3495`** with the merged verdict. **The ledger must capture both, or classify short-circuit runs as an explicitly separate cohort** — silently capturing only `:3495` drops every short-circuited run from the denominator while its synthetic PASS still counts as a review elsewhere. (Anchors are the plan's declared checkpoint `main@727d4652`; this branch is based one release earlier, where the same two sites sit at `:3097`/`:3485`.) `log-metrics.sh:60-69` persists **one aggregate line per run** (status, issue count, iteration, mode, cli, severity tallies, commit, branch, diff lines) with **no per-finding or per-reviewer attribution**; the raw reviewer output is deleted on **FOUR** paths, not one — **`:3515`** (completion-promise), **`:3591`** (success), **`:3620`** (stall) and **`:3640`** (FAIL). Unique-defects-per-reviewer, duplicates and false positives are therefore unmeasurable from it. So item 2 requires a **new capture point upstream of `lib/merge-findings.py`** — **the merger is `skills/litmus/scripts/lib/merge-findings.py`; that path is stated ONCE here, at its first operative use, and every other mention in this plan cites it as `lib/merge-findings.py:N` against that directory. It does NOT exist at `skills/litmus/scripts/merge-findings.py`, so an unqualified anchor would resolve by the `L531–L536` convention to a checkpoint path that is not `git show`-able** (PATH STATED ONCE 2026-09-12, native finding [19] MEDIUM; UNREVIEWED) — (per-reviewer findings *before* dedup) plus **retention of the raw output across all four deletion sites**, with the existing metrics line kept as the aggregate roll-up. **Retention on the FAIL (`:3640`) and stall (`:3620`) paths is the load-bearing part**: an earlier version of this cell named `:3591` alone, which would have retained the raw output for exactly the runs the ledger needs least and dropped it for the two it needs most. **RAW-OUTPUT STORAGE, ONE RULE (2026-09-24; plan-only, UNREVIEWED):** retained raw reviewer output lives only in the observed repository's state directory (`.claude/` by default), at a path `git check-ignore` confirms untracked before the first capture there, and is never committed. A public `docs/` path, `docs/reviews/review-yield/` included, is never its retention store. What leaves that directory, into `baseline-v1.jsonl` or anywhere else, is the derived per-finding fields plus the raw file's sha256 as its content identifier, never raw text; a quote needed for adjudication is redacted first, as the instruction-scope map already requires of traces.

**Retention alone is INSUFFICIENT, and capture moves to the DISPATCH BOUNDARY — corrected 2026-09-08 (round 8, M11).** The four deletion sites above are all **correct**; the defect is that the file they delete **does not exist yet** on three terminal paths. Verified at the checkpoint: `_RAW_OUTPUT_FILE=$(mktemp …)` is created at **`:3403`**, while the **builtin-fallback** path exits 3 at **`:3377`**, the **timeout** path writes `infra_failure` and exits 124 at **`:3386`**, and the **nonzero-backend** path writes `infra_failure` and exits 1 at **`:3393`** — all three before `:3403`, and `log_review_metrics` is likewise never reached on any of them. So a retention-only mechanism silently excludes **every failed dispatch and every superseded retry** from the denominators, and this row's own promises — to "separate review findings from cancellation, timeout, auth and other infrastructure failures" and to "track whether a fix introduced the next defect" — cannot be met by it. **Required instead: an ATTEMPT-START record written at the dispatch boundary, BEFORE the backend runs, and a TERMINAL-CLASSIFICATION record on EVERY exit path — `:3377` (builtin fallback), `:3386` (timeout), `:3393` (nonzero backend) included, plus the builtin-fallback handoff itself. Every started attempt must carry either a terminal classification or an explicit `interrupted` state; an attempt with neither is a ledger defect, not a missing row. `interrupted` is a READER/RECONCILIATION obligation, NOT a writer one — corrected 2026-09-09 (round 9, finding [13]).** The enumerated terminal writes (`run-review-loop.sh:3377` builtin fallback, `:3386` timeout, `:3393` nonzero backend, plus the builtin-fallback handoff — anchors verified) are all exit-path writers **inside the dying process**, so SIGKILL, OOM and host failure produce a start record with no terminal record and no `interrupted` state: precisely the state the requirement declares impossible, and precisely the attempts the ledger most needs. This document supplies its own case — round 3's arbiter verdict was destroyed by an out-of-memory kill during round 4's second attempt. **So: a start record with no terminal record and no live process is CLASSIFIED `interrupted` at ledger-read or run-recovery time, and the start record is retained.** Distinguish a genuinely running attempt from an interrupted one by liveness probe or lease expiry, never by elapsed time alone. **Fixture: kill the process after the start record is written; the ledger must read back `interrupted`, not a missing row.** This is a **specification** requirement of this row and changes nothing about its status: 2-A and 2-B keep their separate gates, and **no collection may begin on the strength of this clause.** **Two capture GAPS (a THIRD is named at the end of this sentence group, 2026-09-13), named rather than assumed covered:** the **PR backstop** path and **GitHub-bot reviews** never reach `lib/merge-findings.py` at all, so a single capture point "upstream of `lib/merge-findings.py`" cannot cover the cohorts this row promises. **ONE DISPOSITION EACH, NO DISJUNCTION — 2026-09-24 (native run `00facd76` HIGH, arbiter-confirmed; plan-text fix recording an already-stated gate; plan-only, UNREVIEWED).** Neither path is commit-authorizing in this plan: the PR backstop verdict authorizes a PR, and GitHub-bot reviews authorize nothing locally. So each is a **2p INELIGIBLE COHORT**: the **PR-backstop cohort** and the **GitHub-bot cohort** are stamped on the baseline as cohorts it does not observe, and both are EXCLUDED from every yield denominator. Neither gets a capture point. **THE THIRD GAP — ADDED 2026-09-13 (G1–G7 reconciliation; UNREVIEWED):** the **builtin `code-reviewer` agent review** that `skills/litmus/SKILL.md`'s Builtin Fallback runs AFTER the exit-3 `BUILTIN_FALLBACK` handoff reaches no dispatch-boundary capture site, no `lib/merge-findings.py` and no `log_review_metrics`, and the loop has already removed its state file and cleared iteration history before exiting (`run-review-loop.sh:3375-3377` at the checkpoint). The handoff's terminal record above covers the DISPATCH, and it also opens the REVIEW the agent then performs as that review's attempt-start (below), and item 2i (A-i)–(A-iii) carries that review's `completeness` to the MARKER only. **ITS DISPOSITION IS A 2-A CAPTURE SITE, not an ineligible cohort — 2026-09-24 (native run `00facd76` HIGH, arbiter-confirmed; plan-text fix recording an already-stated gate; plan-only, UNREVIEWED) — because this plan already calls the built-in path a LIVE commit-authorizing fallback (*Still needs Chris* #14 and item 2i(B)).** The site is the builtin review's marker writer, `skills/litmus/scripts/write-review-marker.sh`, at the two invocations `skills/litmus/SKILL.md` already makes and no others; 2-A adds NO invocation. Step 5 invokes the writer only when Step 4 found no blocking issue (PASS), and Step 7 invokes it with `--discard` to retire the arming for a FAIL and an abandonment alike (aligned with the existing litmus behaviour 2026-09-24; plan-only, UNREVIEWED). At each of those two invocations 2-A writes one review record to its provisional, NON-AUTHORIZING sink, on the Step 5 path AFTER the mint decision, so the record carries its outcome (2026-09-26; plan-only, UNREVIEWED). The record carries the staged diff hash, `backend: builtin` and which of the two existing invocations wrote it. It never enters the marker, and the mint at `:373` stays PASS-only and byte-unchanged by 2-A. No run linkage across the handoff is claimed beyond the (staged diff hash, `<prompt-path>`) pair below. **IDENTITY AND OUTCOME, from EXISTING fields only (2026-09-24; plan-only, UNREVIEWED):** the diff hash is NOT the record's only identity. Its identity is the pair (staged diff hash, `<prompt-path>`). `<prompt-path>` is the argument the writer already requires in BOTH modes, and it names WHICH exit-3 arming the review belongs to (#790), so two reviews of the same diff are two armings with two prompt paths. The record states only what its invocation can know. A Step 5 record is a PASS only when the writer minted; a Step 5 invocation whose mint the writer refuses is a non-PASS terminal outcome and ENTERS the FAIL numerator, because that arming yielded no authorization (2026-09-26; plan-only, UNREVIEWED). **Abandonment is recorded by `write-review-marker.sh --discard` at Step 7, and that record is NOT a PASS:** a `--discard` record is a non-PASS terminal outcome and ENTERS the FAIL numerator, because the arming yielded no authorization (2026-09-24; plan-only, UNREVIEWED). `--discard` carries no channel that separates a FAIL from a deliberate abandonment, and nothing persists Step 4's result, so those two still share the `--discard` record; that is the one remaining residual, and it can only overcount FAIL, never PASS. **A killed review is NOT left unrecorded:** the exit-3 handoff's own 2-A record at `:3377` carries the staged diff hash and the `<prompt-path>` the arming writes, so it is keyed on the same pair and is the review's ATTEMPT-START. Step 5 or Step 7 closes it, and a start that neither closes, with no live process, is classified `interrupted` under item 2's existing read-time rule. No new store and no new enum. **SETTLING FIXTURE:** a builtin PASS writes the `BUILTIN-` marker and exactly one record, from Step 5; a builtin FAIL and an abandoned review each write no marker and exactly one record, from Step 7's `--discard`, each counted as non-PASS in the FAIL numerator; a review killed after arming and before either invocation reads back `interrupted`; and two builtin reviews of the SAME diff under two armings write two records with distinct prompt paths. No record authorizes anything. That is more than an extension of `log-metrics.sh` and less than a second orchestrator; distinguish local Litmus from GitHub-bot reviews, commit from PR mode, iteration/run resets, actual backend/model, prompt/policy revision, harness and effective route revision; separate review findings from cancellation, timeout, auth and other infrastructure failures; track whether a fix introduced the next defect.

**Class:** hard

**Status 2026-09-08:** **SPLIT** — **status CORRECTED 2026-09-09 (round 10 propagation pass): this cell led with BLOCKED while the *Progress* table recorded SPLIT, and that table states it copies these values verbatim, so the two had silently drifted apart in exactly the place the verbatim claim promises they cannot.** SPLIT is the correct value under the legend, and both halves and both gating conditions are named here as the legend requires. Prerequisites are the `baseline captured` node's ONE authoritative list on the dependency graph, deferred to rather than restated here. **RESTATEMENT DELETED 2026-09-10 (round-15 finding [3]; UNREVIEWED):** this cell said "deferred to rather than restated here" and then restated the list anyway — as four conjuncts, having already drifted from the node's five by dropping `2a-env`. The node is the one authority; nothing is enumerated here. **SPLIT 2026-09-09 on Chris's approval of finding [19]: 2-A record COLLECTION — whose DELIVERABLES are this row's own body (the dispatch-boundary records), cited and not restated in the status cell, since restating them as "the capture point and four-site retention" reproduced the pre-M11 mechanism this row supersedes — is gated on ITEM 1 AND on `2a-env` (the graph's `2a-env ──► 2-A` capability edge); 2-B the dataset and its ANALYSIS keeps the Chris #2 gate, which is now SATISFIED — #2 answered (i) bounded tranche, (ii) original seven only. Neither half may start on the other's authority. The normative statement of the split is the *Standing fallback* section; this cell cites it. **SCOPE OF THAT CITATION, NARROWED 2026-09-10 (round-15 finding [6]; UNREVIEWED):** the *Standing fallback* is normative for 2-B's **START** conditions and nothing else. Milestone acceptance belongs to the `baseline captured` node and observation eligibility to the promotion rule — each cited separately, neither restated there. The clause that imported the milestone's prerequisite list into 2-B's start gate is deleted: it made a start condition out of a list that governs a milestone, which would have blocked 2-B on conjuncts its own start never required. Item 2 is not BLOCKED as a whole; each half carries its own gate from the graph. 2-A's gate is item 1 and `2a-env`, and nothing else: 2-A is not startable today because item 1 is TODO, and it becomes startable once both land, whatever the state of `protocol-approved`, which gates the `baseline captured` milestone and not 2-A's start. 2-B's start is the *Standing fallback*'s, cited above (2026-09-24; plan-only, UNREVIEWED).** *(Corrected 2026-09-08: this cell previously said "on item 1, and on Still needs Chris #2", omitting item 2i, while the cell body stated a different pair omitting Chris #2 — two partial lists competing with the graph's complete one.)*

**Evidence / settling check:** **Prerequisites: see the `baseline captured` node on the authoritative graph. This row states no list of its own — a partial restatement here is exactly how a prerequisite goes unenforced, and a fourth statement is not added.** #844 and the completeness-detection half now live in **item 2i**, which has its own row, status and settling check — they were previously specified inside this BLOCKED cell, which left the work that must precede all measurement with no legal start. Item 8 keeps only the *policy* question about medium blocking.

**TWO milestones, because one was satisfiable by writing a document.** An earlier revision replaced "the spike is the check" with "name the versioned artifact whose existence IS `baseline captured`" — which has the same defect one step later, since this row's first deliverable is the *protocol*, so a worker who writes the protocol has by that rule unlocked disabling the observer hooks, archiving `~/.claude/homunculus/`, registering the agy-read gate and rewriting delivered prompt text, with **zero observations collected**. Split them:
**(1) `protocol-approved`** — **the operator (Chris) has ACCEPTED** the versioned protocol artifact at the named path **`docs/reviews/review-yield/protocol-v1.md`**. **Writing that artifact is item 2p, a separate row with no predecessor; existence is not acceptance**, and an earlier version of this clause defined the milestone as mere existence, which collapsed drafting into approval and left the drafting itself with no legal start. The artifact must fix its cohort dimensions and sampling rule: sampling unit; required cohorts (commit vs PR mode, local litmus vs GitHub bot, backend/model, prompt/policy/harness/route revision, **and hook-installation state per repository per observation window**, **plus the SCANNER CONFIGURATION dimension added to item 2p's list 2026-09-13 — cited here, NOT restated, so a later amendment there moves one copy**); minimum observations or a fixed window; the adjudication procedure; and how immature downstream-escape data is handled — **plus the required capture fields that determine observation ELIGIBILITY, accepted 2026-09-09 and specified in item 2p, cited here and NOT restated.**

**Why hook-installation state is a cohort dimension, not a footnote.** The founding argument is that the baseline must be captured over a gate that is *not blind*, but item 0's acceptance is expressed entirely as merged code, ADRs and regression tests — never as enforcement being **ACTIVE** where the observations are produced. ADR 0051 says so itself at `:95-98`: "The gate is only reached where the repository has reference-transaction support and the hook installed; `scripts/install-git-hooks.sh` owns that." A merged PR and an installed plugin version therefore establish nothing about native-hook installation. **Item 0's settling check CARRIES that clause — see item 0's own cell, which names the verification command and the retention rule.** It is stated there rather than declared here: this document's own lesson is that a rule stated only in the row that *depends* on it is not enforced in the row that must *satisfy* it, and an earlier revision announced the clause from this cell while item 0's never gained it.
**(2) `baseline captured`** — a **retained dataset** at **`docs/reviews/review-yield/baseline-v1.jsonl`**, referenced by that protocol. **A floor of usable adjudicated observations applies under BOTH options, not just the count option:** the earlier "minimum observations *or* a fixed window, with missing data explicitly classified" let a window elapse yielding zero usable reviews — or only infrastructure failures, which item 2 itself requires be separated from findings — and still satisfy the milestone that unlocks every mutating half. That is the same "satisfiable without observations" defect the split was created to remove, one level down. **Require at least N reviews classified `completed-with-findings-adjudicated`, with N fixed in the protocol, under either option.** If a fixed window elapses below the floor, the milestone is **recorded as unmet** (extend the window or re-scope) — never rounded up. **WINDOW START (2026-09-24; plan-only, UNREVIEWED):** a repository's fixed window OPENS at the later of `protocol-approved` and 2-A's first ELIGIBLE row in that repository. A row collected before it opens, including every row collected while 2-A is still gated on item 1 and `2a-env`, is INELIGIBLE, counts toward no floor, and does not consume the window.
**Every mutating half gates on (2), never on (1).** Acceptance owner for both: the operator (Chris). Retain the pre-change baseline. Self-reported model confidence is not measured precision. Apply the instruction-scope map: measure delivered/read context by recipient and load trigger, not repository Markdown totals.

---

## Moved from the parent 2026-09-24: dependency graph (§ *Dependencies, order and acceptance for the remaining work*, the fenced graph)

> **MOVED VERBATIM (2026-09-24; Chris-approved shrink; plan-only, UNREVIEWED).** The text below was the parent's dependency graph (§ *Dependencies, order and acceptance for the remaining work*, the fenced graph), at parent spec `8bfd530e…`; the parent keeps a one-line pointer to this file at its place. It binds as part of this file and is reviewed with this file's spec hash; a verdict on the parent does not cover it. Inside it, "this file", "this document", "above", "below" and line anchors `:NNN` into the parent refer to the parent as it stood before this move.

```
0 ──► 2-B                WAS blocked on a decision and deliberately left unresolved here;
                         see the ANSWERED line closing this block.
                         Item 2 measures review yield, so its baseline is only meaningful over
                         a gate that is not blind — and #622 is a live path where a conflict-free
                         merge commits with no litmus at all (pre-commit-gate.sh:182-186 / :249).
                         But the approved item-0 scope is all SEVEN issues, so writing the edge
                         as "#622 only" would BE the bounded tranche, quietly deciding Chris #2
                         in a diagram. Two honest forms, pick one in #2:
                           (a) close-the-class — all seven reconciled and dispositioned before
                               baseline capture; or
                           (b) bounded tranche — capture over a partially-closed gate, and record
                               that limitation on the baseline itself so every later comparison
                               carries it.
                         ANSWERED 2026-09-09: form (b). The limitation is stamped on the
                         baseline; see *Still needs Chris* #2 for the normative record. This
                         edge is therefore SATISFIED. It gates item 2-B only; see the split
                         below. CORRECTED 2026-09-09 (round 10, finding [1]): this line read
                         "item 2 still cannot start", which contradicted the approved 2-A/2-B
                         split recorded in the Standing fallback — 2-A is gated on item 1
                         and on `2a-env` (the capability edge below), and does not wait on this
                         edge at all.
1 ──► 2-A                INSTRUMENTATION half. Its DELIVERABLES are item 2's own cell —
                         the dispatch-boundary records — cited here and NOT restated, because
                         restating them reproduced the pre-M11 mechanism that cell supersedes.
                         Gate: item 1, AND `2a-env` by the capability edge below. ADDED 2026-09-09
                         (round 10, finding [1]) — the split was approved and written into
                         the Standing fallback, which this document designates its normative
                         statement, but was never encoded here. This graph is the single
                         ordered source of truth, so an unsplit `2` node left the two
                         surfaces in a dual-source conflict that this graph's own supremacy
                         rule could not resolve. 2-A changes no authorization outcome and
                         writes to a PROVISIONAL SINK ONLY, which is NON-AUTHORIZING. That is
                         2-A's collection posture, stated once here and cited elsewhere.
2a-env ──► 2-A           CAPABILITY EDGE, ADDED 2026-09-23 (native run `e90373b7` HIGH, arbiter-confirmed; plan-text fix; plan-only, UNREVIEWED).
                         2-A's records at the dispatch sites EXTEND item 2a bound (2-CAP) (d)'s
                         SERVING-BACKEND IDENTITY CHANNEL, which `2a-env` owns (item 2's cell and
                         the Standing fallback, cited). So 2-A's channel-extending records wait
                         on `2a-env` delivering that channel. 2-A is NOT split: this edge and
                         `1 ──► 2-A` together are 2-A's whole gate, and 2-A still grants 2-B
                         nothing.
2-B ──► Chris #2 AND "protocol-approved"
                         DATASET AND ANALYSIS half, with its gates. Chris #2 is SATISFIED
                         ((i) bounded tranche, (ii) original seven only); `protocol-approved`
                         is open, so 2-B is not startable. **Neither half may be started on
                         the other's authority** — 2-A is not a prerequisite of 2-B, and
                         finishing 2-A grants 2-B nothing.
8 ── SPLIT: the ledger dispositioning and the stratified sampling may proceed after 2-B;
     the MUTATING work — the decision on keeping `medium` blocking at iteration 3 and later —
     waits on 2-B AND "baseline captured" AND a Chris decision recorded by row ID at
     *Still needs Chris* #18, made against the predeclared thresholds and both strata of
     `### Item 8` BEFORE that mutation (conjunct written 2026-09-24 (native run `00facd76` HIGH, arbiter-confirmed; plan-text fix recording an already-stated gate; plan-only, UNREVIEWED); it records
     the "needs Chris after data" gate the item already carried and makes no decision). The approved fail-closed validation of the
     authorization-bearing fields is NOT here: it moved to `2a-env`, pre-baseline,
     2026-09-23 (native run `d036cd94` HIGH, arbiter-confirmed; plan-text fix; plan-only, UNREVIEWED). SPLIT WRITTEN 2026-09-09 (`全部批准`, round-14 finding [6];
     UNREVIEWED), mirroring item 9's node: item 8 changes authorization
     behaviour by this plan's own definition, and "Why this order" says items 8 and 9 wait
     for their evidence as well as for their decision — a bare "2-B ──► 8" edge would have
     authorized starting the validation the moment the ledger existed, with no baseline in
     existence, which is the exact reading item 9's node was split to prevent.
     item 2's baseline is also invalid until item 1 quiets both logs
2a ──► "baseline captured"
                         the CONVERGENCE-POLICY half of item 2a ONLY — it may not change prompt
                         behaviour before the baseline exists. The bound (2-CAP) reviewer-contract
                         delta is NOT on this edge: it lands in `2a-env` and IS the version the
                         baseline measures (2026-09-13, Chris `go`; UNREVIEWED). Its INTEGRITY half is NOT on this
                         edge: that is the 2i NODE plus the `2a-env` node above. WRITTEN AS AN
                         EDGE 2026-09-09 (round 11): this was a dangling annotation carrying no
                         glyph and attached to no node, so under the numbered-item convention the
                         nearest reading was `2-B ──► 2a`, whose own gate is only Chris #2 AND
                         "protocol-approved" — and this graph's supremacy rule then permitted the
                         prompt rewrite to start before the logs were quiet.
0 remaining approved (#622, #570) ──► 12
                         minimum cases ship inside each item-0 fix.
                         #789 is deliberately NOT on this edge: it is a post-0827 descendant
                         (Marker & claim integrity bucket), and scheduling one descendant —
                         one of fifteen — as item-0 work would be the silent scope expansion
                         the 0 ──► 2-B note above exists to prevent.
descendants ──► 12       CONDITIONAL, only if Chris #2 absorbs them (#789 plus the Ref-gate
                         and Marker buckets). RESOLVED 2026-09-09 — Chris #2(ii) answered
                         "the original seven only", so this edge DOES NOT FIRE: the fifteen
                         descendants are not item-0 work and are carried as item-12
                         SUCCESSORS. #789 accordingly remains SCHEDULED ONLY as a preservation
                         action (the Worker-ownership preserve line), and is
                         otherwise carried as Chris #6. Corrected 2026-09-08 (round 8, M22):
                         the earlier "appears ONLY on" was a false claim about the whole
                         document, which DISCUSSES #789 in two further places — the New issues
                         since 2026-08-27 table buckets it under Marker & claim integrity
                         against item 0, and Recommended next actions devotes a paragraph to
                         saying it is deliberately NOT listed as item-0 work. A bucket
                         assignment in that table is not a schedule; the substance is
                         consistent everywhere — preserved, not scheduled, superseded on main
                         by bdb9b776 — so only the "ONLY" claim was wrong.
1 ──► 3 (inventory and consumer confirmation ONLY)
                         the before/after latency measurement needs item 1's logs quiet first.
                         ARCHIVING ~/.claude/homunculus/ and DISABLING the observe.sh hooks are
                         the MUTATING half and wait on "baseline captured" — an earlier version
                         of this edge put archive in the item-1-gated set while item 3's status
                         cell put it in the mutating half, and under this graph's own precedence
                         rule the graph would have won and authorized it early.
2i ── no predecessor     pre-baseline INTEGRITY preconditions. Scope: see the node definition
                         below; not restated here. An earlier version restated it and put
                         detection on the node, making the graph a CYCLE — detection ──►
                         baseline ──► producer ──► detection — which under this graph's own
                         precedence rule directed a worker to start the very work item 2i(B)
                         says cannot exist yet. Depends on neither Chris #2 nor item 1, so the
                         node is startable today. This node exists because both
                         members previously sat inside BLOCKED rows and had no legal start.
2p ── no predecessor     protocol DRAFTING. Authors docs/reviews/review-yield/protocol-v1.md with
                         cohorts, sampling rule and the floor N fixed, and the Chris #2 form
                         recorded as the value *Still needs Chris* #2 carries (cited, not
                         restated). Depends on neither Chris #2 nor item 1 nor
                         item 2i, so it is startable today. This node exists because
                         "protocol-approved" was a milestone with no row producing its artifact —
                         the drafting sat inside item 2's BLOCKED cell and had no legal start,
                         the same defect the 2i node above was created to fix. DRAFTING IS NOT
                         APPROVAL: reaching this node satisfies nothing further on its own.
2p ══▶ "protocol-approved"   EDGE CORRECTED 2026-09-10 (round-18 finding [1]; Photon technical
     decision, UNREVIEWED). `══▶` says the LEFT SIDE PRODUCES THE ARTIFACT the milestone is granted
     over, and item 2i produces no protocol artifact — this milestone's own node says so ("item 2p
     produces the artifact, the item 2i NODE must be complete first"). The graph asserted a
     production relation its own node text denied, and the graph is the supreme surface. Item 2i is
     carried as a PREREQUISITE inside the milestone's node below, the same treatment 2a-env already
     receives; the existing list-entry form suffices and NO new glyph is introduced.
2-B ══▶ "baseline captured"
                         2-B is the half that PRODUCES the retained dataset, so it carries the
                         production edge into that milestone. ADDED 2026-09-09 (round 11): the
                         milestone had no producing edge at all — the only `══▶` reaching it came
                         from `protocol-approved`, a milestone, which the convention now forbids.
"baseline captured" ──► "protocol-approved"
                         PREREQUISITE, not production — `protocol-approved` is one of the
                         prerequisites the `baseline captured` node lists, and the dataset itself
                         is produced by 2-B on the `2-B ══▶ "baseline captured"` edge. SPLIT
                         2026-09-09 (round 11): this was written as one `══▶` chain, which under
                         the convention said reaching `protocol-approved` PRODUCES
                         `baseline captured` — re-installing the exact defect the
                         protocol/baseline split exists to remove.
"protocol-approved"      the OPERATOR (Chris) has accepted the drafted protocol artifact. Both
                         conjuncts are load-bearing: item 2p produces the artifact, the item 2i
                         NODE must be complete first, and neither one nor both together reach
                         this node without the acceptance.
                         A FURTHER LOAD-BEARING CONJUNCT, ADDED 2026-09-13 (native 2a9a6900
                         finding [5]; UNREVIEWED — item 2a bound (2-CAP) and *Still needs Chris*
                         #15 already made it binding and this node omitted it), AND DEFINED
                         ONCE HERE, GOVERNING EVERY LATER USE (CORRECTED 2026-09-16 post-16,
                         native run `5e995822` HIGH: the same conjunct was also stated as a
                         post-collection COUNTS requirement, which this node cannot satisfy
                         because counts exist only after 2-B collects and 2-B waits on this
                         node; Photon manual-resume brief `manual-802-838-840-847-20260916.md` #840 section, on the `840-post16-readonly-diagnosis-result.md` roots; source-read at HEAD `34887cb7`, NOTHING EXECUTED; UNREVIEWED): the accepted
                         artifact carries, per contract version, the T2–T4 CENSORED-STRATUM
                         declaration and its sampling rule — A SCHEMA PLUS A PROSPECTIVE
                         SAMPLING RULE, NOT A COUNT — and records the hard page cap P
                         for that contract version (P = 3, fixed in item 2a's OVERFLOW row and
                         TRANSCRIBED by 2p, never chosen by it; because the value lives in this
                         plan, this conjunct does not wait on `2a-env`; a different P is a
                         different contract version and a separate cohort).
                         THE COUNTS THEMSELVES — per-stratum T2–T4 chain counts, their terminal
                         values and findings-before-stop — ARE A REPORTING REQUIREMENT AT
                         `baseline captured`, not a precondition of this node.
                         THE TWO CONJUNCTS, NAMED so "either" has no second reading: this node is
                         UNMET while EITHER (1) the T2-T4 CENSORED-STRATUM declaration with its
                         sampling rule, OR (2) the transcribed hard page cap P for that contract
                         version, is absent. THE COUNTS ARE NEITHER OF THEM: they are the
                         `baseline captured` REPORTING requirement stated above, and their absence
                         does not make this node UNMET.
                         "ITEM 2i" ON THIS GRAPH MEANS THE 2i NODE, NOT THE WHOLE 2i ROW —
                         defined here once and governing every later use below, including the
                         "baseline captured" prerequisite list. The NODE is member (A) plus
                         member (B) STAGE 1 (the stamp, the schema/ALLOWED_TOP admission and
                         the carry-through).
                         OUTCOME-NEUTRALITY IS A PER-MEMBER PROPERTY, NOT A NODE-LEVEL ONE —
                         CORRECTED 2026-09-09 (round 12). The parenthetical above previously
                         read "which by their own rule change no authorization outcome" and sat
                         where it could be read as a claim about the whole NODE; member (A)
                         contradicts such a claim, since changing which findings survive a merge
                         can change what a gate concludes. Each member carries its own posture:
                         (B) STAGE 1's three items are outcome-neutral by their own stated rule,
                         and member (A) is NOT claimed to be. Item 2a's placement of work may
                         rely on the Stage-1 clause ONLY, never on a node-wide property that was
                         never true. It excludes (B) STAGE 2 — the refusal rule — and detection,
                         both of which are blocked on `baseline captured` and land atomically
                         with the FIRST AUTHORIZING READER of `completeness`, DOWNSTREAM of this
                         milestone (re-keyed 2026-09-13 at item 2i(B) Stage 2; propagated here
                         the same day, native 2a9a6900 finding [1]; UNREVIEWED). Read as the node
                         there is no cycle; read as the whole row there is one, because the
                         row's stage 2 sits behind the very milestone this node feeds. An
                         earlier version said only "item 2i must be complete first" and left
                         a reader to pick, which is the ambiguity this definition removes. Producing the document is item 2p and is NOT
                         this milestone — an earlier version of this node defined the milestone
                         as the artifact merely existing, which made drafting and approval the
                         same act. This milestone authorizes NOTHING on its own.
2i NODE ──► 2a-env       2a-env is the MARKER ENVELOPE / PROVENANCE node. ADDED 2026-09-09
                         (round 11): item 2a's bounds (i-a) and (i-b) had no stage that could
                         legally contain them — (i-b) changes an authorization outcome, item 2a
                         assigns its integrity half to the 2i NODE, and the NODE's schedulable
                         members cannot carry it: (B) STAGE 1 is outcome-neutral BY ITS OWN
                         STATED RULE, which (i-b) would violate, and (B) STAGE 2 — the member
                         that may change an outcome — sits DOWNSTREAM of `baseline captured`,
                         which bound (i-a) forbids waiting for.
                         RE-CITED 2026-09-09 (round 12): this sentence previously said "the 2i
                         NODE forbids changing an authorization outcome by its own definition
                         above", a NODE-WIDE prohibition that the same round's per-member
                         correction removed — outcome-neutrality is (B) Stage 1's property and
                         was never the NODE's. The conclusion is unchanged and now rests on the
                         clause that actually carries it.
                         SCOPE: (i-c), the short-circuit scanner preconditions, INCLUDING both
                         upstream normalizers (ADDED 2026-09-10, round-18 finding [7];
                         UNREVIEWED — the bound existed at item 2a and this authoritative
                         SCOPE line omitted it, so the node under-declared its own work);
                         (i-a), the distinguishable mint — BOTH producers (`:3115`'s
                         short-circuit form and `:3585`'s proof of executed review, round-14
                         finding [5]) and every gate-side reader of the `litmus-passed.local`
                         commit-marker artifact in the honouring set, the `pre-pr-gate.sh`
                         arms EXCLUDED because they are outside `2a-env`
                         (`dispatcher-commit-block.sh` with the TWO-ARM delta of item 2i(B)
                         (A-iii)), all in ONE commit; and (i-b), the complete-verification requirement TOGETHER
                         WITH the cutover refusal of legacy bare-64-hex markers, which is an
                         authorization change and so sits here rather than in (i-a) — both
                         defined once in item 2a's cell and cited, not restated; and (2-CAP),
                         the reviewer-contract delta the baseline measures — per-response
                         `completeness` statement, 3-new drip deletion, continuation chain with
                         terminations T1–T4, per-page records — it MAY change findings-based
                         PASS/FAIL (drip deleted, pages accumulate). Δ1–Δ4 of bound (2-CAP) (d)'s CAPTURE OWNERSHIP are ACCEPTED PRE-BASELINE BEHAVIOUR CHANGES of this scope and not merely the drip/pages outcome change above — a reaped descendant's post-exit bytes excluded (Δ1), an over-cap leader as a failed attempt (Δ2), prompt transport and SIGPIPE (Δ3) and the teardown-reduced window (Δ4) — with the reaped-descendant fixture cited there as their runtime proof (ADDED 2026-09-16 post-16, native run `5e995822` MEDIUM; Photon manual-resume brief `manual-802-838-840-847-20260916.md` #840 section, on the `840-post16-readonly-diagnosis-result.md` roots; source-read at HEAD `34887cb7`, NOTHING EXECUTED; UNREVIEWED). It adds NO reader that
                         refuses or grants on a recorded `completeness` value (that is Stage 2),
                         defined once in
                         item 2a's cell and cited (ADDED 2026-09-13, native b5bddf50 HIGH;
                         UNREVIEWED: item 2a said this work moves here while this authoritative
                         SCOPE line omitted it).
                         AND the two INPUT-LEVEL merger rules, RELOCATED here from item 8
                         2026-09-23 (native run `6e0afdc0` HIGH, arbiter-confirmed; Photon correction decision; plan-only, UNREVIEWED):
                         an envelope stating FAIL never merges to PASS (fixture E1), and any
                         unparseable input is NON-AUTHORIZING (fixture P1). AND, beside them,
                         the RECORD-LEVEL fail-closed validation of severity and confidence,
                         RELOCATED here from item 8 2026-09-23 (native run `d036cd94` HIGH, arbiter-confirmed; plan-text fix; plan-only, UNREVIEWED):
                         absent, null or unrecognized severity and non-finite confidence each
                         merge to FAIL (fixtures R1–R6 and N1–N2). AND CONTAINER AND MEMBER
                         SHAPE VALIDATION, RELOCATED here from item 8 2026-09-23 (native run `e90373b7` HIGH, arbiter-confirmed; plan-text fix; plan-only, UNREVIEWED):
                         the ONE ENVELOPE PREDICATE and the two accepted container shapes, the
                         member validation, and the ingestion-rejection synthetic diagnostic —
                         the `internal:merge-findings` HIGH finding naming each rejected input
                         and the shape observed — with fixtures S1–S8 in item 8's contract
                         file: every invalid container or member shape merges to FAIL with its
                         own rejection finding, and the valid-empty controls S5 `[]` and S6
                         `{"status":"PASS","issues":[]}` still AUTHORIZE. Behind item 8's gate
                         stays only the iteration-3 medium-blocking decision and its stratified
                         sample.
                         The two land SEPARABLY —
                         (i-a) is a format change, (i-b) an authorization change — and (i-b) may
                         NOT precede (i-a), or an unrecognizing reader falls back to the bare-hash
                         accept path.
                         ACCEPTANCE-OWNERSHIP SPLIT OF THIS SCOPE — TECHNICAL ORGANIZATION ONLY,
                         ADDED 2026-09-16 root-C (Photon manual-four continuation; source-read at
                         HEAD `34887cb7`, NOTHING EXECUTED; UNREVIEWED). The scope above is ONE
                         node carrying TWO acceptance families whose fixtures, evidence and
                         internal order are each already stated at their own anchors, while their
                         RELATION was stated nowhere — so "who accepts what, in what order" was
                         unowned across the node. NOTHING IS ADDED OR REMOVED HERE: no
                         deliverable, obligation, fixture, product requirement or acceptance owner
                         is created, deleted, widened or moved, and every clause cited below keeps
                         its own governing text, which is CITED AND NOT RESTATED.
                         FAMILY 1 — THE MARKER ENVELOPE. Members: (i-c) the short-circuit scanner
                         preconditions including both upstream normalizers; (i-a) the
                         distinguishable mint, both producers and every gate-side reader of the
                         `litmus-passed.local` commit-marker artifact in the honouring set, the
                         `pre-pr-gate.sh` arms EXCLUDED because they are outside `2a-env`
                         (`dispatcher-commit-block.sh` with the TWO-ARM delta of
                         item 2i(B) (A-iii)), in ONE commit; (i-b) the complete-verification requirement
                         together with the cutover refusal of legacy bare-64-hex markers.
                         ACCEPTANCE OWNERS, ONE PER MEMBER — COMPLETED 2026-09-17 root-C (run
                         `7886ed9f` HIGH; UNREVIEWED: this line named owners for (i-a) and (i-b)
                         only, while (i-c) was listed as a member of this family, so a member of
                         the family sat under no family-level acceptance owner at all): for (i-a)
                         and (i-b), the (i-a)/(i-b) pair fixtures in item 2a's cell, where they
                         are defined once; for (i-c), its OWN scanner fixtures at the (i-c)
                         SHORT-CIRCUIT PRECONDITIONS — THE SCANNER COUNTERS bound, which assert
                         only that the short-circuit does NOT fire, TOGETHER WITH (i-c)'s (2-ORD)
                         readers (merger/short-circuit, and the exit-3 built-in handoff check of
                         item 2i(B) (A-iv)) and their mixed-run fixtures in `2a-env` that X1
                         cites and does not re-implement. All are defined once at those anchors and are CITED, NOT
                         RESTATED: no fixture is created, moved, widened or narrowed here, and
                         only the owner of each is named. INTERNAL SEQUENCING: the one already
                         stated below in this node — (i-b) may NOT precede (i-a) — not a new rule.
                         FAMILY 2 — THE LAUNCHER, THE CAPTURE, AND WHAT RIDES ON THEM. Members:
                         bound (2-CAP)'s CAPTURE
                         OWNERSHIP clause with its Δ1-Δ4 accepted pre-baseline behaviour changes,
                         C1 (the launcher owns its group on every exit path) and C2 (every inner
                         site captures to a private regular file, under C2's own SCOPE RULE and
                         the site list DERIVED from that rule at the implementation start tree);
                         and — ADDED 2026-09-17 root-C (run `7886ed9f` HIGH; UNREVIEWED: both of
                         the following are inside the SCOPE this split organizes and were in
                         NEITHER family, so the split did not cover its own scope) — bound
                         (2-CAP)'s REVIEWER-CONTRACT DELTA, the delta the baseline measures:
                         per-response `completeness` statement, 3-new drip deletion, continuation
                         chain with terminations T1–T4, per-page records; and THE ENVELOPE, the
                         transport SPECIFIED 2026-09-13 in item 2a's row and DUE in `2a-env`,
                         whose scanner and markdown stages delegate to this family's launcher and
                         capture to this family's capture.
                         ACCEPTANCE OWNERS, ONE PER MEMBER: for the CAPTURE OWNERSHIP clause, the
                         reaped-descendant fixture and the Δ1-Δ4 statements cited at that clause,
                         where they are defined once; for the reviewer-contract delta, this node's
                         own ACCEPTANCE paragraph below at its `For (2-CAP):` clause — the T1–T4
                         terminal-value records with every page attempt retained, the surviving-drip
                         repository grep, the producer-contract check over bound (2-CAP)(a)'s
                         enumerated set, and the assembled chain whose per-page records are written
                         with item 2-A ABSENT; for THE ENVELOPE, the TWO envelope fixtures and the
                         four fixtures the transport gates, all stated once at that row. CITED, NOT
                         RESTATED: nothing is added, removed or widened by naming them here.
                         INTERNAL SEQUENCING:
                         also already stated there and not re-legislated — C2's prompt writer is
                         spawned INSIDE the process group C1 creates and reaps, so C1's exit-path
                         ownership is what reaches it.
                         CROSS-FAMILY ORDER: THE PLAN IMPOSES ONE, AND THIS CLAUSE REPORTS IT
                         RATHER THAN INVENTING IT — CORRECTED 2026-09-17 root-C (run `7886ed9f`
                         HIGH; UNREVIEWED). This clause read: "CROSS-FAMILY ORDER: THIS PLAN
                         IMPOSES NONE, AND THIS CLAUSE INVENTS NONE. The two families touch
                         disjoint surfaces — marker CONTENT and its readers on one side; process
                         launch, teardown and capture TRANSPORT on the other — and no clause in
                         this document orders either family against the other. RECORDING THAT
                         ABSENCE IS THE ORGANIZATION; IMPOSING AN ORDER WOULD BE NEW PRODUCT SCOPE
                         AND IS REFUSED HERE." THE DISJOINT-SURFACES CLAIM IS WITHDRAWN. Two
                         sentences already in this document, both predating this split, order
                         FAMILY 2 ahead of work that reaches across the families: (1) THE
                         ENVELOPE's own transport says each such call "captures to a regular file
                         as bound (2-CAP) (d)'s CAPTURE OWNERSHIP requires of every inner reviewer
                         capture"; (2) the CALLERS AND ENTRY PATHS clause ends "and THE ENVELOPE's
                         scanner and markdown stages, which delegate to the same launcher", under
                         a D5 default of ONE launcher behaviour for every caller with Δ1–Δ4
                         applying on each. THE ENVELOPE's scanner stage also reports through
                         (i-c)'s existing failure token, so the two families meet at that surface
                         too rather than staying apart.
                         CONSEQUENCE, WHICH IS THE ORDER THOSE TWO SENTENCES ALREADY CARRY AND NOT
                         A NEW ONE: NO CONTINUATION-CHAIN OR ONE-OVERALL-DEADLINE STAGE MAY BE
                         ACCEPTED AS LANDED UNLESS C1 AND C2 — the launcher and the capture those
                         sentences delegate to — LAND FIRST OR IN THE SAME COMMIT. A stage accepted
                         ahead of them would be accepted against a launcher that does not yet own
                         its group on every exit path and a capture that is not yet a private
                         regular file, which is the condition Δ1–Δ4 were measured against, so the
                         acceptance would not mean what it says.
                         NO DELIVERABLE, OBLIGATION, FIXTURE, PRODUCT REQUIREMENT OR ACCEPTANCE
                         OWNER IS CREATED, DELETED OR WIDENED BY THIS PARAGRAPH: the two sentences
                         quoted above are the source of the order and are unchanged; what was wrong
                         was this clause's claim that no such order existed. FAMILY 1's remaining
                         members — (i-a) and (i-b), marker CONTENT and its readers — are ordered
                         against FAMILY 2 by nothing, and no order is imposed on them here.
                         Both families stay inside `2a-env` and
                         both remain under this node's GATE, whose EDGE is unchanged:
                         GATE: the 2i NODE; FAMILY 1's (i-a)/(i-b) marker-reader commit alone
                         ALSO waits on "#622 merged", per the narrowed edge in this graph
                         (2026-09-24; plan-only, UNREVIEWED). EDGE UNCHANGED, REASON CORRECTED 2026-09-17 (native run
                         `7886ed9f` MEDIUM, conf 0.8; UNREVIEWED). This line read "GATE: the 2i NODE,
                         whose stamp and schema admission the envelope extends" — an edge naming the
                         whole NODE carrying a reason that names ONE member. Stamp and schema
                         admission is (B) STAGE 1's alone. The NODE also carries member (A), the #844
                         merger reconstruction (algorithm alpha, the symmetric edge predicate,
                         source-prefix exclusion including `internal:`, D-1 to D-5), and NO clause in
                         this document names (A) as a predecessor of any `2a-env` deliverable: marker
                         provenance, scanner failure tokens, completeness emission and continuation
                         consume the schema admission, not the new election.
                         WHAT THE ENVELOPE EXTENDS, STATED ONCE: (B) STAGE 1's stamp, schema,
                         `ALLOWED_TOP` and constructor admission — the same reason the transport row
                         gives for placing the edge earlier.
                         THE EDGE IS NOT NARROWED HERE, AND THIS CLAUSE NARROWS NOTHING. Replacing
                         `2i NODE ──► 2a-env` with `2i(B) Stage 1 ──► 2a-env` would move `baseline
                         captured`, and with it the mutating halves of items 3, 6, 7b, 8, 9 and 13,
                         earlier on the critical path; that is a sequencing decision and this
                         correction has no authority to take it. The NODE edge is RETAINED, and
                         retained on a CONSERVATIVE reason stated as such rather than on a technical
                         dependency that does not exist: over-gating delays the envelope, while
                         under-gating could land envelope work against a pre-alpha merger. THE
                         NARROWING IS CARRIED as Still needs Chris #17 — ANSWERED (B) 2026-09-17 BY PHOTON, the 2i NODE edge RETAINED —
                         so it can be cited and vetoed by ID and the edge stands as drawn. The
                         answer and its provenance live at the row, not here.
                         NOT gated on "baseline captured", which bound (i-a) requires.
                         WHY A SIBLING AND NOT A MEMBER: keeping this work OUTSIDE the 2i NODE is
                         precisely what lets (B) STAGE 1's outcome-neutrality clause stay
                         UNRELAXED (re-cited 2026-09-09, round 12 — the clause belongs to that
                         member, not to the node).
                         ACCEPTANCE: a fixture in which a short-circuit mint ALONE fails to
                         authorize, plus proof that BOTH producers and every reader change
                         together; and, for the cutover refusal (round-14 finding [5]), a PAIR
                         of fixtures — a legacy bare-64-hex marker REFUSED at (i-b) activation,
                         and a fresh executed-review mint of the SAME diff ACCEPTED. The pair is
                         what proves the refusal is decided by format alone and that the
                         revalidation recovery is real rather than nominal; neither fixture may
                         delete a marker to pass. For (2-CAP): a chain ending by each of T1–T4
                         records that terminal value with every page attempt retained, a repository grep that finds any surviving copy of the drip, or any producer contract in bound (2-CAP)(a)'s enumerated set listing response fields without `completeness`, fails (`SKILL.md:478` is outside that set — it rides (c-1b) at Stage 2), a chain
                         stopped by T2–T4 is never recorded `complete`, a chain is assembled and
                         its per-page records are written — serving backend included — with
                         item 2-A ABSENT; and for bound (2-CAP) (d)'s SERVING-BACKEND IDENTITY
                         CHANNEL — RUNTIME PROOF PENDING (the mechanism is measured on stubs
                         only) and never met by inference: EVERY successful output branch
                         delivers its own name through the exit status of the `( … ) >file`
                         subshell that replaces the `$(execute_review …)` substitution — a
                         Codex success records `codex`, a
                         Codex attempt that escalates to a successful droid records `droid`,
                         and agy, grok and direct droid returning 0 record their own names —
                         with the stdout written before the subshell exits captured
                         byte-identical and `REVIEW_EXIT` identical to
                         a run without the channel except a raw 200–204, which reads 1 — both runs on the SAME corrected library, so CAPTURE OWNERSHIP's Δ1–Δ4 (bound (2-CAP) (d)) are the comparison's common baseline and never a channel delta; a
                         dispatcher leaving a detached descendant on stdout returns when the
                         subshell exits, identity intact, a fixture today's substitution fails
                         by waiting on the descendant; the same descendant left inside a REAL inner launch is CAPTURE OWNERSHIP's runtime acceptance (bound (2-CAP) (d), cited), without which this fixture alone does not bound an attempt; a
                         missing name, a raw 0, a no-output or non-zero dispatch (124,
                         1, droid no-output) records no backend and counts as T2 — **EXCEPT
                         EXIT 3 WITH OUTPUT EXACTLY `BUILTIN_FALLBACK`, WHICH IS RECOGNIZED
                         BEFORE PAGE-ATTEMPT CLASSIFICATION AND IS NEVER A T2 PAGE FAILURE
                         (CORRECTED 2026-09-16 post-16, native run `5e995822` HIGH; Photon manual-resume brief `manual-802-838-840-847-20260916.md` #840 section, on the `840-post16-readonly-diagnosis-result.md` roots; source-read at HEAD `34887cb7`, NOTHING EXECUTED; UNREVIEWED).**
                         That branch (`run-review-loop.sh:3260`) is the handoff to the
                         built-in reviewer, which *Still needs Chris* #14 keeps as a LIVE
                         commit-authorizing fallback (cited above), so classifying it as an
                         infra failure would retire a live path by wording. On page 1 or an
                         un-paged dispatch it is TODAY'S HANDOFF, carrying only a dispatch
                         terminal record, consistent with CAPTURE GRANULARITY's `builtin`
                         (`:4899`) rule. On a CONTINUATION PAGE (index > 1) the chain ends
                         NON-COMPLETE with earlier pages retained — Photon technical
                         default, because the built-in reviewer cannot honour the withheld-key
                         manifest — which leaves #14's live fallback intact wherever it
                         exists today. Fixtures: an unavailable CLI ⇒ handoff ⇒ built-in
                         review ⇒ a bound marker (scanners clean — a scanner failure token,
                         or a scanner finding the deterministic-blocker predicate FAILs, arms
                         no handoff, item 2i(B) (A-iv), fixtures 7 through 10 there); plus the index > 1 case; a reviewer
                         child that exits 200–204, exports the identity variable, writes to any
                         inherited descriptor or prints a token-shaped body line cannot record
                         or change a backend; a name set by an earlier attempt, another page or
                         the inherited environment is never read as this attempt's; a
                         dispatcher nounset fault or `exit` still returns a non-zero status to a
                         driver that continues; accepted pages served by different backends
                         assemble with `model` ABSENT under the mixed-backend rule; and a tree with (2-CAP)
                         but no Stage 2 has NO reader that refuses on a stated `completeness`
                         value. CORRECTED 2026-09-13 (native 2a9a6900 finding [0]; UNREVIEWED):
                         this previously read "authorizes exactly as before", which contradicted
                         the OVERFLOW fixtures bound below. Deleting the drip and accumulating
                         pages change `issues[]`, so a findings-based PASS/FAIL may change; and a
                         chain the continuation driver did not finish (T2–T4) ends that run
                         through the loop's EXISTING non-authorizing `infra_failure` exit — the
                         driver's IN-RUN CHAIN CONTROL (its own retry ladder, page count against
                         P and deadline), which like today's reviewer timeout
                         (`run-review-loop.sh` exit 124 at `727d4652`) withholds authorization
                         from an unfinished run and never grants on a value, so it is not the
                         first authorizing reader defined at item 2i(B) Stage 2 — which is how the cap-plus-one and deadline
                         fixtures do not authorize without Stage 2. These are contract fixtures with INSERTED values; they prove the
                         transport, not live reviewer behaviour. Also binding here since R2
                         (2026-09-13; UNREVIEWED): the item-2a OVERFLOW row's four transport
                         fixtures plus its two envelope fixtures (a foreign `reviewed_diff_hash`
                         page is refused; an unfunded fallback ends the chain non-`complete`
                         with earlier findings retained). Also binding since 2026-09-13 (native
                         2a9a6900 findings [6] and [7]; UNREVIEWED): that row's totality
                         fixtures (a page stating `errored`, `cap_exhausted` or `unstated`, a
                         page with a missing or invalid `completeness`, and an extraction
                         failure each count as a failed page attempt and never yield
                         `complete`) and its three binding fixtures (a foreign `chain_id` is
                         refused; a wrong `index` is refused; an un-paged response inside a
                         paged chain is refused rather than replacing the chain). Also binding
                         since 2026-09-13 (native 2a9a6900 finding [4]; Photon remaining-contract
                         decision; UNREVIEWED): that row's CONTINUITY PAIR — page 1 `truncated`
                         withholding finding key K (THE FINDING KEY's six members, exact;
                         the earlier triple collided, corrected 2026-09-13) followed by
                         a fresh page stating `complete` without emitting a finding keyed
                         exactly K is a failed page attempt and never `complete`, while the
                         same chain whose later page emits a finding keyed exactly K ends T1
                         `complete`. Also binding since 2026-09-13 (Photon continuity-closure
                         decision; UNREVIEWED): that row's MANIFEST VALIDATION fixtures — a
                         one-line-away re-find does not discharge K; a `withheld` entry
                         missing `line` or `description` is a failed page attempt; a page-1
                         `withheld` over 10·(P − 1) keys ends the chain `cap_exhausted`. Also
                         binding since 2026-09-13 (Photon assembly-closure decision;
                         UNREVIEWED): that row's COLLISION AND ASSEMBLY fixtures — emitting A
                         never discharges a distinct same-triple withheld B; equal withheld
                         keys each need their own emitted finding; a severity-regraded re-find
                         does not discharge; page-1 `FAIL` on medium-only findings then page-2
                         `PASS` assembles and persists `FAIL`; a two-backend chain assembles
                         with no `model` and the backstop writer refuses it; a first page at
                         `index` 0 is refused. (That row's backstop no-artifact fixture binds
                         the item 2i(B) Stage-2 change that adopts backstop paging, not this
                         node.)
"baseline captured"      a RETAINED DATASET at docs/reviews/review-yield/baseline-v1.jsonl
                         measuring the reviewer version that carries item 2a bound (2-CAP);
                         earlier observations are a separate HISTORICAL COHORT, never pooled or
                         counted (2026-09-13, Chris `go`; UNREVIEWED), and
                         satisfying the protocol's sampling rule AND at least N reviews
                         classified completed-with-findings-adjudicated under EITHER option
                         (a) or (b), with N fixed in the protocol artifact. A window that
                         elapses below N is recorded as UNMET, never rounded up. The floor is
                         stated HERE, on the authoritative surface, and referenced — not
                         restated — elsewhere: an earlier version of this node said only
                         "minimum observations or window", so the milestone that unlocks every
                         mutating half was, on the surface that overrides the others, still
                         satisfiable by letting a window elapse with zero usable adjudicated
                         reviews. That is the precise defect the protocol/baseline split was
                         created to remove, and it had been re-installed here.
                         2a-env ADDED to this list 2026-09-09 (round-13 finding [1]; UNREVIEWED).
                         It was a sibling of the 2i NODE with ZERO outgoing edges and was absent
                         here, so the milestone it exists to protect was reachable while
                         short-circuit mints still authorized commits — the node gated nothing.
                         EXPRESSED AS A LIST ENTRY, NOT AN EDGE, DELIBERATELY: under the arrow
                         convention a `2a-env ──► "baseline captured"` edge would read as 2a-env
                         being GATED ON the milestone (right side a quoted milestone ⇒ dependent
                         ──► gate), which is exactly what bound (i-a) FORBIDS. Prerequisite-of is
                         the opposite direction and this list is where it belongs. Placement is
                         unchanged: 2a-env stays a SIBLING outside the 2i NODE, so (B) STAGE 1's
                         outcome-neutrality clause stays UNRELAXED and the BUILTIN envelope in
                         Stage 2 is untouched.
                         ACCEPTANCE: an unfinished 2a-env must DEMONSTRABLY prevent this
                         milestone — a fixture in which the milestone is refused while 2a-env is
                         incomplete, so the entry is enforced rather than merely written.
                         ELIGIBILITY of an observation is the PROTOCOL's, not this node's:
                         item 2p declares the required capture fields and the dataset
                         validation check that REJECTS an observation lacking them, so an
                         observation missing them is INELIGIBLE and never counts toward N.
                         Cited here, NOT restated — ADDED 2026-09-09 (round-13 finding [14],
                         Chris ACCEPTED). This node's floor bounds COUNT and adjudication;
                         the per-observation DIMENSIONS are 2p's, and neither changes who
                         may START 2-A or 2-B.
                         NOT self-declared and NOT satisfiable by writing a document — the
                         single-milestone version was, which would have unlocked every mutating
                         half with zero observations collected.
                         Prerequisites, ONE authoritative list — the other surfaces defer to it:
                         item 1 (logs quiet) AND item 2i AND 2a-env AND "protocol-approved" AND
                         item 2-A AND the
                         Chris #2 disposition RECORDED — **SATISFIED 2026-09-09: recorded as
                         form (b), bounded tranche, so the limitation MUST be stamped on the
                         dataset itself. The remaining conjuncts are UNCHANGED and still
                         open, so this milestone is not reached.** (See *Still needs Chris* #2;
                         this line cites that answer, it does not restate it.)
                         PRECEDENCE — ITEM 0 (vi)'s DISQUALIFICATION vs #2(i)'s STAMP, STATED ONCE
                         HERE AND CITED FROM BOTH (ADDED 2026-09-17, native run `7886ed9f` MEDIUM,
                         conf 0.7; UNREVIEWED: both texts were live, neither cited the other, and no
                         clause said which governs when both apply). THE TWO GOVERN DISJOINT OBJECTS
                         AND NEITHER OVERRIDES THE OTHER. Item 0 (vi) governs BYTE-IDENTITY OF THE
                         ENFORCING IMPLEMENTATION — the installed snapshot's gate-script bytes against
                         this repository's `.gate-integrity.lock` expectation — and a mismatch
                         DISQUALIFIES that repository, because the observation would be produced under
                         an implementation the baseline does not describe. #2(i)'s stamp governs KNOWN
                         SCOPE GAPS OF THE GATE ITSELF, such as the #622 class: the expected
                         implementation is installed, and what it does not yet cover is recorded as a
                         limitation on the dataset. A stamped BOUNDED TRANCHE therefore DOES NOT admit
                         a version-mismatched repository — the stamp records what a correctly-installed
                         gate fails to cover, never that the wrong bytes were installed — and (vi) does
                         not reopen the eligibility FORM that #2(i) answered. NEITHER RULE IS CHANGED
                         BY THIS PARAGRAPH; it names which object each one owns.
                         THE COHORT-SIZE CONSEQUENCE IS NOT A NEW OPERATOR QUESTION. (vi) is expected
                         to disqualify repositories routinely while plugin versions differ across the
                         observation set, so the reachable cohort may sit below the floor N. Under #15
                         the value of N and the price of reaching it are ALREADY the operator's at
                         `protocol-approved`, and the answer to an unreachable floor is a different N
                         or a different sampling rule — never a relaxed eligibility rule, and never
                         admitting a disqualified repository under a stamp. The expected cohort size is
                         recorded BESIDE N in the protocol artifact by item 2p, and is not restated
                         here.
                         item 2-A ADDED to this list 2026-09-13 (native 79ad7ef4 findings [0]-[3];
                         Chris-approved correction, UNREVIEWED). It REPLACES the `minimal
                         detection producer ──► "baseline captured"` edge the 2026-09-12 pass
                         wrote onto the graph, which this correction DELETED. That edge carried
                         three defects at once: (a) it pointed the WRONG WAY — right side a
                         quoted milestone ⇒ dependent ──► gate — so it said the producer WAITS ON
                         the milestone whose N it exists to enable, inverting finding [0]'s cycle
                         rather than removing it; (b) NO ROW OWNED IT, making it a named
                         deliverable owned by no half, the defect this document repairs
                         elsewhere; (c) item 2-A was absent here although the per-observation
                         capture fields 2p declares ARE 2-A's deliverables, so N was unreachable
                         on the declared graph. EXPRESSED AS A LIST ENTRY, NOT AN EDGE, for the
                         reason given once above for 2a-env and once more for item 2i on the
                         `2p ══▶ "protocol-approved"` edge: prerequisite-of is the opposite
                         direction and this list is where it belongs. NO new row, NO new node,
                         NO new glyph — the capability is one of 2-A's INSTRUMENTATION
                         deliverables, DECLARED by 2p, CAPTURED by 2-A, assembled by 2-B and
                         COUNTED here, which is the layering this document already uses.
                         RECONCILED with *"Neither half may be started on the other's
                         authority"*, which is UNCHANGED because it governs who may BEGIN: 2-B
                         stays startable on its own edges and finishing 2-A still grants 2-B
                         nothing. This entry governs what COUNTS — until 2-A's instrumentation
                         is operational 2-B may collect, but every row it collects is INELIGIBLE
                         and never counts toward N.
                         An earlier version of
                         this line omitted Chris #2 while item 2's own status cell required it,
                         and since this milestone unlocks every mutating half, the two readings
                         differed by whether the whole mutating programme could start with #2
                         still unanswered.
                         Items 3, 7 and 13 each split around it: their INVENTORY, consumer-
                         confirmation and diagnostic halves may run before it, but every
                         MUTATING half (disabling hooks, registering the read gate, rewriting
                         prompt text) waits for it — otherwise the change being measured
                         contaminates the baseline it is measured against, which is the whole
                         reason Why-this-order puts data collection first.
5 ── parallel with 0/1   no overlapping edits
13 ──X──► 6              EDGE DELETED — the blanket claim "13 rewrites the very text 6
                         extracts" was never verified. The measurement, the inventory ranges and the
                         named <STATE_DIR> sites are stated ONCE in item 6's cell and are NOT
                         restated here (round 8 M16 re-scoped them; round 9 removed this
                         duplicate copy). Result only: zero proposed-hunk overlap, so item 6
                         is gated on `baseline captured` AND the recorded item-13
                         evaluation (ALONE DELETED 2026-09-10, round-16 finding [4]; the
                         round-15 correction narrated a strike without removing the word).
                         Re-add this edge if a later audit re-run proposes ANY hunk inside
                         103–895 OR 897–1302, and name them when you do. OWNER AND EVALUATION
                         POINT (round 9, finding [20]; without them the rule cannot fire):
                         ITEM 13's owner evaluates it ONCE, immediately before item 6 starts
                         extracting, and item 6 MAY NOT START until that evaluation is
                         recorded. GATING MADE EXPLICIT 2026-09-10 (round-15 finding [7];
                         Photon technical decision, UNREVIEWED): item 6 gates on
                         `baseline captured` AND that recorded pre-extraction evaluation.
                         The word "alone" is struck — it contradicted the MAY NOT START
                         rule two lines above it, and the resolution PRESERVES the
                         mandatory evaluation rather than demoting it to a pre-flight note.
                         13-eval ──► 6            the recorded evaluation is a real edge, not an aside
                         while item 13's
                         hunk half also waits on Chris #7 (RESOLVED 2026-09-09, worker
                         default: carry the single file across; the hunk half now waits on
                         that file LANDING, not on the decision), so without this the H4
                         re-measurement could arrive after item 6 moved the text.
13 ── SPLIT: PROJECTED ONTO THE GRAPH 2026-09-10 (round-15 finding [7]; Photon
     technical decision, UNREVIEWED). This node introduces NO new work — it is a
     mechanical projection of item 13's existing row, added because the graph
     claimed to cover every numbered item while carrying no 13 node at all.
     ANALYSIS half: COMPLETE (audit done; no hunks applied, none authorised).
     HUNK half: BLOCKED on the audit file LANDING on this branch AND
     "baseline captured" — Chris #7 is RESOLVED, so the DECISION is no longer a
     gate and only the file's arrival is. Its pre-extraction evaluation for
     item 6 is the 13-eval edge above.
1 ──► 7a-i               (direction corrected 2026-09-10, round-17 finding [9]: the convention is
                         exhaustive by target TYPE — a numbered target reads prerequisite ──►
                         dependent — so "7a-i ──► after 1" inverted it; "after 1" belongs in the
                         annotation, which is here.) AFTER 1: the DISCRIMINATED-RESULT refactor of pre-read-size-advisory.js, UNIT tests
                         over the returned kinds asserting NO change to observed allow/deny, and
                         the measurement harness. RE-PARTITIONED 2026-09-09 (round-13 finding [2];
                         UNREVIEWED): this edge previously scheduled the exemption-semantics and
                         indeterminate-probe FIXTURES here. Those observe allow/deny, so by the
                         partition rule stated once in item 7's cell — *anything that changes what
                         a gate ALLOWS OR DENIES belongs to 7b* — they are 7b's, together with
                         (1-a)'s `:224-226` guard split, (1-b)'s transport, the (4a)/(4b)
                         dispositions and the run-with-flags.js lock regen. This edge CITES that
                         rule and does not restate a schedule. Chris #13's DENY default is
                         RESOLVED and is a 7b input, not a 7a-i one.
7a-ii ──► Chris #10      RESOLVED 2026-09-09 (worker default, Still needs Chris #10 = (A)): this
                         edge DOES NOT FIRE. Under (A) the helper-down failure test is dropped
                         with (B), so 7a-ii ceases to exist as a separately gated half. The
                         original reason — the fixtures cannot be written until the policy is
                         chosen — is retained as the record of why it was ever gated.
7b ──► "baseline captured"   RIGHT-HAND SIDE NARROWED 2026-09-10 (round-18 finding [4]; Photon
     technical decision, UNREVIEWED). It had read `"baseline captured" AND item 3's paired
     measurement` — a conjunction of a quoted milestone with a numbered item's deliverable, which
     TARGET TYPE cannot disambiguate, so the edge was readable in both directions at once. Item 3's
     prerequisite is stated once, below, and is not repeated here. **CONVENTION, stated with the
     rule it protects: a right-hand side MAY NOT mix a milestone with a numbered item**, because
     target type is what carries direction.
                         the MUTATING half — registering the agy-read PreToolUse hook in
                         hooks/hooks.json, AND the read-doctrine rewrite in session-brief.md
                         (delivered context). Without the Chris #10 conjunct this edge read as
                         making 7b executable on the milestone alone. The old
                         "7 ── independent after 1" line is deleted: it could not be reconciled
                         with the mutating-half rule directly above.
                         Chris #10 SPENT 2026-09-09 (worker default = (A); see Still needs
                         Chris #10). 7b's LIVE gates are therefore "baseline captured" AND
                         item 3's paired measurement AND 7a-i landed (the `7a-i ──► 7b` edge;
                         added 2026-09-24; plan-only, UNREVIEWED), on the edges below. 7b is still not
                         startable: "baseline captured" is not reached.
ACYCLICITY CHECK       WIDENED 2026-09-12 (native c94fb702 finding [0]; UNREVIEWED). NODE SET
{2i(B) Stage 2,          CORRECTED 2026-09-13 (native 79ad7ef4 finding [11] MEDIUM; UNREVIEWED):
 2a convergence-policy,  `2-A` IS a member — this correction made it a prerequisite of
 2p, 2a-env, item 8,     `baseline captured` and it carries the capture-field capability.
 2-A, baseline captured, COMPLETED 2026-09-15 (native FINAL13 issues[15] MEDIUM; UNREVIEWED):
 item 1, 2i NODE,        item 1, the 2i NODE and `protocol-approved` are EXISTING graph nodes
 protocol-approved}      the set omitted; they join it, and no implementation task is added.
                         NOT A MEMBER: the `minimal detection producer` node, because the
                         2026-09-13 correction DELETED it. The braces below are the WHOLE set. Over
                         {`2i(B) Stage 2`, item 2a's CONVERGENCE-POLICY half, `2p` eligibility,
                         `2a-env`, item 8's SPLIT node, `2-A`, `baseline captured`, item 1, the 2i NODE,
                         `protocol-approved`} the edges must
                         remain a DAG. OWNER: the change that adds, removes or relocates an ordering
                         constraint TOUCHING ANY ONE OF THESE MEMBERS owns the re-run, IN THAT
                         SAME CHANGE; its author runs it (a node is not an actor).
                         OWNER SCOPE RECONCILED 2026-09-16 root-B (UNREVIEWED): this clause read
                         "between any two of these members" while the RE-RUN TRIGGER below reads
                         "touching a member" — so a constraint between a member and a NON-member
                         FIRED THE TRIGGER AND HAD NO OWNER, an unowned re-run, which is the
                         fail-open direction. The OWNER scope is widened to the trigger's; the
                         trigger is NOT narrowed to the OWNER's, because narrowing would DELETE
                         re-run cases the trigger already requires. THIS ADDS NO RE-RUN CASE AND
                         NO NEW OBLIGATION — it assigns an owner to re-runs already demanded. The
                         superseded wording is preserved in this sentence. RE-RUN TRIGGER: any bound
                         that adds, removes or relocates an ordering constraint touching a
                         member — the check is not satisfied once and retired. ACCEPTANCE
                         ARTIFACT: an executable milestone-reachability proof, DEFINED HERE
                         (2p names none; the dangling "named in 2p" was corrected 2026-09-13,
                         native b5bddf50 MEDIUM; UNREVIEWED) and owned by this check's OWNER,
                         whose edge list includes every capability dependency a node body names (a record or artifact one member consumes from another), not only drawn arrows, carrying a NEGATIVE control (the pre-correction ordering is detected
                         CYCLIC) and a POSITIVE control (the corrected ordering is ACYCLIC and
                         a sequence reaching N exists). **ACYCLICITY CHECK OVER THE DECLARED EDGE LIST (2026-09-24; plan-only, UNREVIEWED).** The check is Kahn's algorithm over ELEVEN VERTICES, the ten members plus the non-member `#622 merged`: repeatedly remove any vertex with no incoming edge, `#622 merged` included; the list is a DAG IFF every vertex is removed (2026-09-24; plan-only, UNREVIEWED). Its input is the declared member edge list, drawn arrows AND capability dependencies, written prerequisite → dependent, plus the non-member node `#622 merged`: `#622 merged → 2a-env` (the edge gates only 2a-env's (i-a)/(i-b) commit; it is checked here at node level, which is stricter, so a DAG at node level is a DAG for the narrower edge too); `item 1 → 2-A`; `2i NODE → 2a-env`; `2a-env → 2-A`; `2a-env → item 8 (mutating half)`; `2p eligibility → protocol-approved`; `2i NODE → protocol-approved`; `protocol-approved → baseline captured`; `2-A → baseline captured`; `2a-env → baseline captured`; `baseline captured → 2a convergence-policy`; `baseline captured → item 8`; `baseline captured → 2i(B) Stage 2`. POSITIVE CONTROL: over that list the check removes all eleven nodes, `baseline captured` included. NEGATIVE CONTROL: adding the pre-correction (2-ORD) constraint `item 8 → 2a-env` leaves six members unremoved (`2a-env`, `2-A`, `baseline captured`, 2a convergence-policy, item 8, `2i(B) Stage 2`), so the check detects that cycle. Both controls were run 2026-09-24 over exactly this list, and re-run the same day when `#622 merged → 2a-env` was added. A change that adds, removes or relocates a member edge updates this list and re-runs both controls in the same change. **RE-RUN 2026-09-23 (native run `6e0afdc0` HIGH, arbiter-confirmed; Photon correction decision; plan-only, UNREVIEWED), for the relocation of the two input-level merger rules into `2a-env`:** the edge list gains the capability dependency `2a-env ─► item 8`, and it gates item 8's MUTATING half only: the iteration-3 medium-blocking decision, the one item 8 work the 8 SPLIT node keeps behind its gate, is decided over the ingestion boundary `2a-env` establishes. It adds no start gate to item 8's analysis half, which may proceed after 2-B as the 8 SPLIT node states (reason matched to the SPLIT node 2026-09-24; plan-only, UNREVIEWED). It adds no cycle: item 8's mutating half was already downstream of `baseline captured`, which is downstream of `2a-env`. The ACYCLICITY CHECK above covers it. **RE-RUN 2026-09-23 (native run `e90373b7` HIGH, arbiter-confirmed; plan-text fix; plan-only, UNREVIEWED), for the capability edge `2a-env ──► 2-A`:** the edge list gains it, because 2-A's records extend the SERVING-BACKEND IDENTITY CHANNEL `2a-env` owns. It adds no cycle: `2a-env`'s node-level prerequisite is the 2i NODE, its (i-a)/(i-b) commit alone also waits on `#622 merged` (a non-member with no member prerequisite), and neither `2a-env`, the 2i NODE nor `#622 merged` waits on 2-A or on anything downstream of it; both 2-A and `2a-env` already sit upstream of `baseline captured`. The same re-run covers the move of container and member shape validation into `2a-env`, which touches the existing `2a-env ─► item 8` dependency and adds no edge. The ACYCLICITY CHECK above covers it. **WHY IT WAS WIDENED, recorded so the
                         same gap is not reintroduced:** the earlier check was scoped to
                         {`2a-env`, item 8, `baseline captured`} — the triangle the (2-ORD)
                         split was about. Finding [0]'s cycle ran through Stage 2, 2a's
                         convergence-policy half and 2p, sharing exactly ONE node with that
                         set, and 2p was not a vertex at all. A check scoped to the nodes of a
                         known cycle is a POSITIVE CONTROL FOR THAT CYCLE, NOT A DAG VERIFIER;
                         it must name its node set and its blind spot, as this one now does.
                         This is a CHECK on the edges declared here, not a new edge and not an
                         exception to one. It exists because (2-ORD) as
                         first written closed exactly this triangle: token production inside
                         2a-env's SCOPE, `2a-env` a prerequisite of `baseline captured`, item
                         8's reader behind `baseline captured`, and the token forbidden before
                         the reader — so every ordering was forbidden and the `baseline
                         captured` fixture was unreachable. The resolution is the (i-c) (2-ORD)
                         SPLIT: the minimal non-authorizing readers (merger/short-circuit, and
                         the exit-3 built-in handoff check of item 2i(B) (A-iv)) land in
                         `2a-env` with the token; item 8 keeps the policy half behind its own gate. Re-run this
                         check whenever a bound moves work between ANY members of the node set
                         declared at the head of this check — CORRECTED 2026-09-13 (native
                         79ad7ef4 finding [11] MEDIUM; UNREVIEWED). This sentence read "these
                         three nodes", which is the historical (2-ORD) triangle described in the
                         paragraph above, not the widened set; left as written it narrowed the
                         RE-RUN TRIGGER stated at the head of this same check, and the narrower
                         of two co-located triggers is the one a worker can satisfy.
7a-i ──► 7b              ADDED 2026-09-12 (native ca145c70 finding C3, codex issues[3]
                         `architecture`, conf 0.99; UNREVIEWED). 7b flips the DENY arms of the
                         `result.kind` switch that 7a-i PRODUCES, so 7b cannot start before
                         7a-i exists. The edge was absent plan-wide while that switch was named
                         as 7b's deliverable, which left 7b schedulable on "baseline captured"
                         AND item 3 alone — both reachable without 7a-i. This records the
                         prerequisite the Item 7 body already states, and it IS one of 7b's
                         LIVE gates: the graph summary above and Item 7's status cell list it
                         (2026-09-24; plan-only, UNREVIEWED).
3 (paired measurement COMPLETE) ──► 7b
                         DIRECTION CORRECTED 2026-09-09 (round 9, finding [15]) — it was
                         written `7b ──► 3`, which under this graph's numbered-item convention
                         (prerequisite ──► dependent, as in `0 ──► 2-B` and `1 ──► 3`) says 7b
                         registers FIRST and schedules the very contamination the prose below
                         forbids. ARROW CONVENTION, DEFINED ONCE HERE, governing every edge.
                         TWO GLYPHS, because one could not carry both directions —
                         CORRECTED 2026-09-09 (round 10, finding [2]).
                           `──►` DEPENDENCY. Both sides numbered items ⇒ prerequisite ──►
                             dependent. Right side a quoted milestone or a Chris # ⇒
                             dependent ──► gate. Target type disambiguates these two.
                           `══▶` PRODUCTION/SATISFACTION. Left side produces or satisfies the
                             milestone on the right, and is the only glyph that may point AT a
                             milestone the left side brings about. A NUMBERED ITEM, or a
                             conjunction of numbered items, MUST stand on its left: a milestone
                             never produces another milestone.
                             `══▶` IS NECESSARY, NOT SUFFICIENT — CORRECTED 2026-09-09
                             (round 12). It says the left side produces the ARTIFACT the
                             milestone is granted over; it does NOT say that reaching the left
                             side reaches the milestone. Where a milestone additionally requires
                             an operator ACCEPTANCE or any conjunct beyond the artifact, that
                             conjunct is stated in the milestone's own node and is equally
                             binding. The earlier wording gave this glyph sufficiency semantics,
                             so `2i AND 2p ══▶ "protocol-approved"` read as making the milestone
                             reachable without Chris's acceptance — which its own node
                             immediately denies ("neither one nor both together reach this node
                             without the acceptance"), leaving the graph's supreme surface
                             contradicting the node it points at, on the milestone that gates
                             every mutating half.
                           MILESTONE-TO-MILESTONE DEPENDENCY uses `──►` under the existing
                             right-side rule — `"X" ──► "Y"` says Y is a PREREQUISITE of X, never
                             something X produces. CORRECTED 2026-09-09 (round 11): `══▶`
                             previously claimed to be the ONLY glyph permitted with a milestone on
                             both sides, which left no way to write a prerequisite between two
                             milestones and forced one to be written as production — whereupon
                             this graph's own supremacy rule beat the node text defining the
                             milestone.
                         The single glyph was genuinely ambiguous, not merely terse: read
                         under the dependency rule, `2i AND 2p ──► "protocol-approved" ──►
                         "baseline captured"` said 2i and 2p were BLOCKED ON
                         protocol-approved and protocol-approved BLOCKED ON baseline
                         captured — the exact inversion that re-created the cycle round 7
                         removed. Every milestone-producing edge now carries `══▶`.
                         ADDED 2026-09-08 (round 8, M25). Item 3's acceptance is stated once
                         in item 3's cell and not restated here; 7b registers a NEW PreToolUse
                         hook with Bash coverage, so without this edge each contaminates the
                         other's before/after cohort. The one alternative — measuring 7b's
                         cost inside item 3's after-cohort — is acceptable only if item 3's
                         acceptance says so BEFORE collection starts, never retroactively.
                         A third conjunct; 7b's other gates are on the 7b edge, not restated.
#622 ──► Chris #9        waive the blueprint-review record, or run blueprint-review on ADR 0051
                         before that branch goes further. Recorded as an execution decision, so
                         it belongs on the graph rather than only in Still needs Chris.
                         RESOLVED 2026-09-09 (worker default): NO WAIVER — verified that
                         ADR 0051 carries zero design-reviewed markers, so the 0827
                         precondition stands. The edge REMAINS, now gated on that review
                         actually running; this plan neither runs it nor re-plans #622.
2a-env (i-a)/(i-b) commit ──► "#622 merged"
                         ADDED and NARROWED 2026-09-24; plan-only, UNREVIEWED. ONLY FAMILY 1's
                         (i-a)/(i-b) marker-reader commit inside `2a-env` waits on #622 being
                         merged, because #622's
                         `hooks/gate-scripts/lib/validate-staged-litmus-marker.sh` reads the
                         same marker forms that commit retires, and item 2i(B)'s reader list
                         requires the two to land together with #622 FIRST. It does NOT gate
                         the rest of `2a-env`: FAMILY 2 and the relocated merger ingestion
                         rules stay gated by the 2i NODE alone. The Stage 2 cutover follows the
                         (i-a)/(i-b) commit, so it is ordered after #622 too. This edge plans
                         no #622 work and runs no review for it.
4 ── precondition first  scope of that precondition WAS NEEDS CHRIS; RESOLVED 2026-09-09
                         (worker default, Still needs Chris #3): the inventory gates
                         RETIREMENT, as originally approved. #840's pruning-only narrowing
                         is rejected. The precondition itself is unchanged.
9 ── SPLIT: classifier + fixtures may be built after Chris #4;
     the POLICY change (litmus medium blocking, pr-grind round budget for a whole
     path class) waits on Chris #4 AND "baseline captured". THE POLICY GATE IS TWO
     GATES, SPLIT 2026-09-24 (native run `00facd76` HIGH, arbiter-confirmed; plan-text fix recording an already-stated gate; plan-only, UNREVIEWED): (1) the CLASSIFIER BOUNDARY — which
     paths are in the class — stays Chris #4 alone; (2) the WAIVER — skipping litmus
     `medium` blocking, or cutting the pr-grind round budget, for that class — ALSO needs
     a SEPARATE recorded operator disposition of the baseline evidence, at *Still needs
     Chris* #19. The waiver is enabled only when BOTH #4 and #19 are recorded (and
     "baseline captured" is reached); #4 alone never enables it, because #4 settled a
     boundary and not the evidence. Nothing here enables the waiver or makes #19. Item 9 mutates policy
     by this plan's own definition, and "Why this order" says items 8 and 9 wait
     for their evidence as well as the decision — a bare "blocked on Chris" line
     would have authorized starting the policy change once the class boundary was
     answered, with no baseline in existence.
     Chris #4 RESOLVED 2026-09-09 (worker default): the class boundary is a fail-closed,
     initially-EMPTY allowlist, stated once in Still needs Chris #4. A worker default authorizes
     no implementation, so this does not make the classifier half startable; the POLICY half still waits on "baseline captured", which is the
     conjunct this edge exists to protect and which is NOT reached.
10 ── SPLIT 2026-09-09 (worker default, Still needs Chris #5): the host-adapter inventory
     gates every MUTATING pi slice; the in-flight pi-cursor-sdk-sandbox-eval continues as
     evidence-gathering only. The 6-lite predicate requirement is untouched and still owes
     a signal, a writer and an evaluation point before any 6-lite code.
11 ── continuous, re-bucket first
6 ── BLOCKED on "baseline captured" AND the recorded item-13 pre-extraction evaluation.
     PRIMARY NODE, ADDED 2026-09-10 (round-17 finding [7]; Photon technical decision,
     UNREVIEWED) — a mechanical projection of item 6's status cell on the same basis as
     item 13's, introducing NO new work and NO new sequencing. Item 6 had no primary
     left-hand side: its gating lived inside the DELETED `13 ──X──► 6` edge. The milestone
     gate is this plan's mutating-half rule; the second gate is the EXISTING `13-eval ──► 6`
     edge above, cited here rather than restated. Neither gate is weakened or reordered.
12 ── TODO. PRIMARY NODE, ADDED 2026-09-10 (round-17 finding [7]; UNREVIEWED) — a
     mechanical projection of item 12's row; no new work. Item 12 appeared only as a
     TARGET. It SPLITS, and the split is what the older edge already
     carried (CARVE-OUT RESTORED 2026-09-10, round-18 finding [8]; UNREVIEWED — this node stated the
     start gate absolutely and dropped the annotation the edge at `0 remaining approved (#622, #570)
     ──► 12` has always carried, "minimum cases ship inside each item-0 fix", producing a surface
     disagreement rather than a real cycle). **`12-min`** — the per-fix MINIMUM CASES — is owned and
     executed INSIDE each item-0 fix, with no dependency on the other fixes; `fix/issue-622-merge-
     commit-gate` must include its own minimum cases before merge, per item 12's cell. **`12-suite`**
     — the broader suite expansion — is what the EXISTING `0 remaining approved (#622, #570) ──► 12`
     edge gates, and that prerequisite is unchanged. The fifteen descendants (#780 #781 #783
     #822 #834 #838 #833 #835 #836 #837 #842 #789 #793 #816 #825) are SUCCESSORS, not
     prerequisites: `descendants ──► 12` DOES NOT FIRE, and this node does not make it
     fire. Items 10 and 11 already carry primary nodes above and are NOT duplicated here.
2a-env-form ──► recorder  ADDED (2026-09-25; UNREVIEWED); SPLIT (Chris, 2026-09-25; UNREVIEWED).
                         `2a-env-form` defines the pattern of the executed-review FORM, which
                         (i-a) leaves unchosen. It is split out of `2a-env` so the recorder does
                         not wait on 2i or #622: it is gated by neither, may land before
                         acceptance (parent, PRE-ACCEPTANCE DELIVERY), and the rest of `2a-env`
                         consumes its pattern and keeps every gate it had. The recorder checks
                         the FORM class, and (iii) is recorded, only after it lands. Each
                         fixture-ID class follows the same order under the node that owns those
                         fixtures. No FORM grammar is chosen here.
recorder ──► "receipt runner committed"
                         RECORDER NODE, ADDED (2026-09-25; UNREVIEWED). OWNS the composition
                         recorder the parent header assigns: the pre-stamp copy check, the
                         join inventory and JOIN SCAN, the JOIN WINDOWS, BYTE BINDING, the
                         VOIDING CHECK, the RECEIPT CHECK at pin and at (3), and sole writing of
                         `composition-manifest.json`, with one fixture per failure branch.
                         Its gate is the milestone "receipt runner committed": the review
                         runner and its closure dirs, RECEIPT CHECK included, in a
                         litmus-reviewed commit merged to main. That commit merged to main on
                         2026-09-25 as `be15d1b0`, so this gate is met (2026-09-25; UNREVIEWED). It may
                         land before acceptance (parent, PRE-ACCEPTANCE DELIVERY). It also OWNS
                         two outputs (2026-09-26; UNREVIEWED). (a) An ACCEPTANCE RECORD bound to the
                         manifest sha256 and the (iii) verdict: implementation start reads it,
                         never a PASS stamp. No gate reads it today, so this node also delivers
                         the design-gate read: before the first implementation write under this
                         plan the gate refuses unless the record verifies (manifest sha256, (iii)
                         verdict), with a regression in which seven standalone PASS stamps and
                         no record still refuse. (b) A DRY-RENDER FIXTURE that builds the
                         integration document from the current pre-stamp copies and records the
                         size of each lens's fully rendered prompt (framing, canaries and route
                         line included). If one would exceed 524,288 bytes, the join inventory is split
                         into several integration documents, each under the cap and each named
                         in the manifest, as the parent's acceptance (iii) requires; never a
                         cut and never a raised cap. It is not a member of the acyclicity check's
                         node set above.
#780 #781 ──► 12-successor
                         ADDED (2026-09-26; UNREVIEWED). The parent's item 12 cell routes the matrix
                         obligations of #780 (zero-old-oid force-update invariant) and #781
                         (protected-ref-creation invariant) here. Acceptance: a numbered issue
                         for each, recorded in the status file, never in a pinned file. Owner:
                         the operator. It is not a pre-merge condition and imposes nothing on
                         those branches, which *Worker ownership* leaves alone. It gates no node
                         and is not a member of the acyclicity check's node set above.
```

---

## Moved from the parent 2026-09-24: *Standing fallback* and the approved 2-A/2-B split (§ *Dependencies, order and acceptance for the remaining work*)

> **MOVED VERBATIM (2026-09-24; Chris-approved shrink; plan-only, UNREVIEWED).** The text below was the parent's *Standing fallback* and the approved 2-A/2-B split (§ *Dependencies, order and acceptance for the remaining work*), at parent spec `8bfd530e…`; the parent keeps a one-line pointer to this file at its place. It binds as part of this file and is reviewed with this file's spec hash; a verdict on the parent does not cover it. Inside it, "this file", "this document", "above", "below" and line anchors `:NNN` into the parent refer to the parent as it stood before this move.

**Standing fallback if Chris #2 goes unanswered — RETAINED AS THE RECORD OF A CONDITION THAT NO
LONGER HOLDS.** #2 was ANSWERED 2026-09-09 (see *Still needs Chris* #2), so the trigger for this
fallback is spent and the 2-A / 2-B split approved below is the live arrangement. The paragraphs
that follow are kept because their two substantive rules — provisional collection is NON-AUTHORIZING,
and the promotion conditions — **still bind 2-A**, and because withdrawing them would erase the
reasoning that produced the split. Read every "while #2 is pending" clause below as historical.
The chain above is long — item 2 waits on #2, the
baseline milestone gates the mutating halves of 3, 7 and 13, and items 4, 9 and 10 wait on operator
decisions — and the plan previously named no path for a worker facing an unanswered #2 for weeks.
(It is not total paralysis: **items 2i and 2p are startable today** — 2p being the protocol DRAFT,
which needs no #2 answer because the form is a field in it — item 11 is continuous, item 5 waits on
nothing, and the inventory / consumer-confirmation / diagnostic halves of 3, 7 and 13 may proceed.)

**An earlier revision's version of this paragraph was itself the bounded tranche, and is withdrawn.**
It said the fallback "IS form (b) of the `0 ──► 2` edge" — capture a provisional baseline and tag the
artifact. But tagging an artifact does not change its *authorization* consequence: `baseline captured`
is precisely what unlocks the mutating halves of 3, 6, 7b and 13, so a provisional baseline that
satisfies the milestone loosens the approved ordering exactly as #840's reframing would — which this
document rejects in two other places and marks **NEEDS CHRIS #2**. It also had no trigger, no elapsed
bound and no operator acknowledgement, leaving "unanswered for weeks" to worker judgement. Being
written into the draft is not approval; the header says so.
**This withdrawal STANDS, and Chris's 2026-09-09 answer does not reinstate it.** What was rejected
was a bounded tranche a *worker* installed by writing it down; what #2(i) approves is a bounded
tranche an *operator* chose, with the limitation stamped on the dataset. The two differ in exactly
the property this paragraph is about — who authorized the loosening — so the answer settles the
form without reviving the self-authorizing route.

**Replacement, which preserves liveness without touching authorization — provisional collection is
explicitly NON-AUTHORIZING.** A worker blocked on Chris #2 may accumulate review-yield observations
into a file marked `provisional, gate partially closed at <sha>`. That data **may not satisfy
`protocol-approved` or `baseline captured`, and unlocks no mutating half of any item.** Its only
purpose is that the measurement window is not lost while the decision is pending. Promoting
provisional data into the real baseline requires a **recorded operator acknowledgement** answering
Chris #2 — never elapsed time, and never worker judgement.

**Promotion also has provenance conditions, because an acknowledgement cannot retroactively create
them.** Predeclared sampling, adjudication, and the test-pollution labelling all have to happen *at
collection time* — this plan's own lesson file is named `audit-logs-are-test-polluted`. And item 2i is
startable today, so it **changes the merger** mid-window: observations collected before it lands were
produced by a merger that silently evicts blocking findings. Therefore: **only observations collected
after item 1, item 2i AND `2a-env` are complete, and under the approved protocol's sampling and
labelling, may be promoted; everything earlier stays provisional permanently.**
**`2a-env` ADDED AS A COLLECTION-TIME CONJUNCT 2026-09-09 (`全部批准`, round-14 finding [7];
UNREVIEWED)**, for exactly the reason item 2i is one: until the envelope lands, the short-circuit
mint at `run-review-loop.sh:3115` is byte-identical to the executed-review mint at `:3585`, so an
observation that records a gate PASS cannot say which path produced it. That is contamination at
collection time by a mid-window mutation, not a gap to be filled in later. It is also the conjunct
the milestone's own prerequisite list already carries, so leaving it out here had two surfaces
disagreeing about one boundary. Stamp each provisional record with the **merger revision**, the
**log-isolation state** and the **`2a-env` envelope state** at collection time, so the boundary is
checkable rather than remembered. **A record carrying no envelope-state field is pre-`2a-env` by that
fact alone and stays provisional; the field is per-record and is never back-filled.**
**ACCEPTANCE:** a fixture in which a dataset collected before `2a-env` completes is re-examined after
it completes and is still refused promotion — completing a prerequisite must never retroactively
qualify observations collected under the regime it replaced.

**`protocol-approved` may be granted while Chris #2 is still UNSET — DECIDED 2026-09-08 (round 8,
M18), and it is what makes the liveness claim above true rather than nominal.** As written, promotion
required observations collected *under the approved protocol*, while `protocol-approved` is Chris's
acceptance of item 2p's DRAFT — so a worker blocked on #2 had no approved protocol to collect under,
and every observation this fallback authorizes would have stayed provisional permanently. That is the
opposite of preserving the window. Accepting the protocol does **not** decide #2: the bounded-tranche
form was THEN an UNSET field *inside* the draft, so approving the document settles sampling, adjudication
and labelling while leaving that field — and #2 — open and unapproved. Therefore **item 2p may be
submitted for acceptance and `protocol-approved` may be recorded before Chris #2 is answered.** This
grants no mutating half of any item: `baseline captured` is untouched and still waits on #2, and
promotion still requires the recorded operator acknowledgement answering #2 *in addition to* the
approved protocol.
**Status 2026-09-09: the decision above stands as a rule and is now SPENT as a condition.** #2 has
been answered, so the draft's bounded-tranche field is no longer UNSET — **it is SET to form (b)**,
and item 2p's draft must carry that value. `protocol-approved` still has to be granted on its own
merits; what changed is only that it is no longer the sole thing standing between a worker and an
approved protocol to collect under.

**The instrumentation this fallback depends on is owned by ITEM 2 — now specifically by sub-item 2-A
(approved 2026-09-09; see the split recorded below, which is the normative statement of its gate).**
**2-A's SCOPE IS ITEM 2's CELL, CITED AND NOT RESTATED — corrected 2026-09-09 (round 10, finding [15]).**
This paragraph previously described that scope itself, as "the capture point upstream of
`lib/merge-findings.py` and the four-site retention", and asserted those were "specified nowhere else in
this plan". **Both halves were wrong, and together they were dangerous:** item 2's own cell supersedes
that mechanism — it states that **retention alone is INSUFFICIENT and capture moves to the DISPATCH
BOUNDARY**, requiring an attempt-start record plus terminal-classification records at the loop's
`:3377`, `:3386` and `:3393` exit paths (all verified present at the checkpoint, all *before* the
raw-output `mktemp` at `:3403`). So the surface this document designates the **normative statement of
2-A's gate** was describing the **pre-correction** mechanism, and a worker starting 2-A on its
authority would have built the very version round 8's M11 correction removed. **2-A's deliverables are
whatever item 2's cell specifies; this paragraph states its GATE — item 1, and `2a-env` by the graph's `2a-env ──► 2-A` capability edge — and nothing else.**
**CAPTURE GRANULARITY IS PER-ATTEMPT, not per review (round 10, finding [16]).** Verified at the
checkpoint: the loop takes a single outer `REVIEW_OUTPUT=$(execute_review …)` at `:3266`, while
`scripts/lib/resolve-cli.sh:3365` `_run_review_with_retries()` runs a budget-bounded loop reassigning
`_RRWR_OUTPUT` per attempt, and `should_escalate_to_droid()` (`:2587`) can switch backend **mid-call** (superseded 2026-09-13 — its only caller is `dispatch.sh`, not this loop; see BOUNDARIES CORRECTED below).
A record taken at the outer assignment therefore cannot see per-attempt outcomes, which backend
actually produced the surviving output, or any superseded attempt — which is precisely the
"actual backend/model" and "infrastructure failure vs finding" separation item 2 exists to measure.
**The records must sit INSIDE `_run_review_with_retries`, inside `_execute_codex`, and inside the
droid escalation**, not around them. **`_execute_codex` ADDED 2026-09-09 (round 11):** verified at
the declared checkpoint, `resolve-cli.sh:4427` dispatches Codex to `_execute_codex` (`:3531`), the
file's own comment at `:3357` states that Codex has its own richer retry loop there, and
`_execute_codex` never calls `_run_review_with_retries`. Codex is the CONFIGURED PRIMARY reviewer, so
the two-site list missed the principal cohort's per-attempt outcomes entirely — the exact separation
this paragraph exists to capture. **BOUNDARIES CORRECTED AND LINKAGE STATED — 2026-09-13 (G1–G7
reconciliation; UNREVIEWED).** Re-verified at the checkpoint; `resolve-cli.sh` is line-identical at this
branch's HEAD. **(1)** `should_escalate_to_droid()` (`:2587`) is **not** on litmus's `execute_review`
path. Its caller is `skills/dispatch-cli/scripts/dispatch.sh`, so the sentence above that names it as
the loop's mid-call switch is superseded. Litmus's mid-call backend switch is `_execute_codex`'s own
post-loop droid escalation (`:3955-3996`), classified by `_classify_droid_escalation_outcome` (`:2642`)
and already logged as `codex-droid-fallback` (`:3996`). **(2)** The litmus capture sites are therefore:
each attempt of `_execute_codex`'s loop (dispatched at `:4427`) and its post-loop droid escalation; each
attempt of `_run_review_with_retries` for agy (`:4507`, `:4513`) and grok (`:4603`); the single-attempt
direct droid arm (`:4536`); and the `builtin` arm (`:4899`), which emits `BUILTIN_FALLBACK` with ZERO
backend attempts and so carries a dispatch terminal record only. 2-A's records at these sites EXTEND
item 2a bound (2-CAP) (d)'s SERVING-BACKEND IDENTITY CHANNEL, which `2a-env` owns; they never add a second
SERVING-backend source (ADDED 2026-09-15, native FINAL13 issues[6]; UNREVIEWED). The `backend` an attempt record carries in (3) is its LAUNCHED BACKEND — the launching site's literal, stamped on failed and superseded attempts too and never read as provenance; only the accepted attempt's LAUNCHED BACKEND is a SERVING BACKEND, and the channel stays its only carrier (ATTEMPT ATTRIBUTION at bound (2-CAP) (d)'s CAPTURE OWNERSHIP, cited; CORRECTED 2026-09-16 post-15, native round-15 issues[4] MEDIUM; UNREVIEWED). **(3) Linkage.** An attempt record
carries (`started_at`, `iteration`, reviewer slot, continuation page ordinal — the page's position in its
bound (2-CAP) chain, 1 for an unchained review — attempt ordinal `_ECX_ATTEMPT`/`_RRWR_ATTEMPT`,
LAUNCHED BACKEND). A superseded attempt is an earlier ordinal on the same page of the same slot and dispatch,
each page's final accepted attempt (item 2a bound (ii)) is its last, and the page ordinal is propagated with
run identity below (2026-09-26; plan-only, UNREVIEWED). **Run identity is NOT visible at these
sites today:** `resolve-cli.sh` is a shared library that never references `started_at` or
`LITMUS_ITERATION`, and the loop passes `LITMUS_ITERATION` inline to the merger only. 2-A must therefore
PROPAGATE run identity from the loop into the sites, and a record without it is unlinkable and stays
provisional. `started_at` has one-second resolution and is deleted with the state file at the builtin
handoff, so no linkage across that handoff is claimed. **(4) Terminal vocabulary: reuse, no new enum.**
The codex attempt outcome (success / full-window 124 / truncated-budget 124 treated as transient /
transient / non-transient), the droid outcome above, the dispatch rc (0 / 124 / 3 / 1) and loop-level
`write_terminal_status`. Mapping failed paths onto `completeness` stays item 2a's. **(5) Sink:** 2-A's
provisional sink with the promotion rule's per-record stamps, cited above; no second sink. Field names
and the sampling unit remain item 2p's protocol. Item 2-A is gated on **item 1, and on `2a-env` by the graph's `2a-env ──► 2-A` capability edge**; item 1 is TODO/not started. Naming the owner closes the
round-8 (M18) gap in which this paragraph authorized collection using instrumentation the same blocker
forbids building. **It does not unblock item 2, does not permit building the instrumentation ahead of
item 2's gates — `2a-env`'s own per-page attempt record (item 2a bound (2-CAP) (d)) is `2a-env`'s
deliverable, not 2-A's, including its narrow SERVING-BACKEND IDENTITY CHANNEL at `execute_review`, and 2-A
extends it without a second backend source — and does not create a second owner.** Two consequences, stated rather than left to
worker judgement: (a) until **item 2-A's** gate clears, provisional collection is limited to what the
pipeline already emits; and (b) any cohort that would require the new capture point is **not**
collected under this fallback — record it as a cohort the baseline does not observe, which is what
item 2's own cell already requires of uncovered cohorts, and accept that part of the window is lost
until then. **(a) and (b) now expire on item 1 rather than on Chris #2** — that is the whole effect
of the approved split, and it is why the reach measured below stops being the accepted permanent
cost the moment 2-A lands. The fallback preserves the window it can preserve, and says plainly which part it
cannot.

**How little that actually is, stated here because the row was not plain enough about it (round 9,
finding [19]).** Against item 2's own verified cell: `log-metrics.sh:60-69` persists one aggregate
line per run with no per-finding or per-reviewer attribution; raw reviewer output is deleted on all
four paths (`:3515`, `:3591`, `:3620`, `:3640`); and the metrics file does not exist at all on the
three terminal paths before `:3403` (`:3377`, `:3386`, `:3393`), so every failed dispatch and
superseded retry is absent. **Unique defects per reviewer, duplicates, false positives and
infra-vs-finding separation — this fallback's entire stated purpose — are ALL unmeasurable from what
the pipeline already emits.** Under (a), therefore, the fallback preserves run-level tallies and
almost none of the review-yield window it is named for, while still carrying a provisional/promotion
regime with its own provenance conditions.

**APPROVED BY CHRIS 2026-09-09 — record collection is SEPARATED from analysis. This is the single
normative statement of the split; the item-2 row and the status table cite it.** Item 2 is divided
into two sub-items, each carrying its own gate, and **neither half may be started on the other's
authority**:

- **2-A — record COLLECTION (non-mutating instrumentation).** Build the records specified in **item 2's own cell**
  — the dispatch-boundary capture, cited here and NOT restated, because the earlier wording
  ("the capture point upstream of `lib/merge-findings.py` and the four-site retention") names the
  pre-M11 mechanism that cell supersedes and which cannot see failed dispatches, retries or
  backend switches. Collection posture is the graph's: a **provisional sink only**, non-authorizing.
  **Gate: item 1 complete, AND `2a-env` delivered (the graph's `2a-env ──► 2-A` capability edge, 2026-09-23 (native run `e90373b7` HIGH, arbiter-confirmed; plan-text fix; plan-only, UNREVIEWED)). That is the whole gate — 2-A is NOT gated on Chris #2.** Item 1 is
  currently TODO/not started, so **nothing is startable today and no collection begins on this
  paragraph.**
- **2-B — the dataset and its ANALYSIS. Gate: Chris #2, unchanged.** #2 is now ANSWERED — #2(i)
  bounded tranche, #2(ii) original seven only — so that conjunct is SATISFIED, and 2-B's remaining
  start gate is `protocol-approved`, per the `2-B ──► Chris #2 AND "protocol-approved"` node on the
  graph. (CORRECTED 2026-09-10, round-16 finding [7]; UNREVIEWED — the milestone's prerequisite
  list governs a MILESTONE; importing it into 2-B's START gate is the very clause item 2's status
  cell records as deleted, and *Standing fallback* is normative for 2-B's start conditions.)

**Why the split is sound:** what Chris #2 decides is what the baseline may be captured *over*, not
whether the pipeline may be made *capable* of recording it — separating the two preserves the
measurement window without weakening any gate. **What it costs, recorded not hidden:** 2-A is real
code, its sink must be labelled provisional from its first commit, and **the promotion rule above is
unchanged and still binds** — its conjuncts are enumerated once there and cited here, not restated.
**REDUCED TO A CITATION 2026-09-09 (`全部批准`, round-14 finding [7]; UNREVIEWED):** this sentence kept
its own copy of the list, which is how it came to omit `2a-env` once the rule gained it — the
define-once failure this document repairs elsewhere, in miniature. So 2-A running before those
prerequisites are all complete still produces permanently-provisional records, and the #2 acknowledgement that
promotion also requires is now on file rather than pending.

---

## Moved from the parent 2026-09-24: *Recommended next actions* (§ *Dependencies, order and acceptance for the remaining work*)

> **MOVED (2026-09-24; Chris-approved shrink; UNREVIEWED).** The text below was the parent's projection of the dependency graph, moved beside the graph it projects, with that day's corrections applied; the parent keeps a one-line pointer to this file at its place. It binds as part of this file and is reviewed with this file's spec hash. Inside it, "this file" and "above" refer to the parent as it stood before this move.

**The three surfaces below are a mechanical projection of the graph, not a parallel narrative.**
Where any of them appears to disagree with the graph, the graph wins and the surface is the defect.

Recommended next actions, in order, excluding anything already owned:

1. **Items 2i and 2p — rows with no predecessor.** **Item 2p (protocol
   DRAFT)** may run in parallel with 2i: it depends on neither Chris #2 nor item 1 nor 2i, it produces
   the artifact `protocol-approved` accepts, and it was added because that milestone had no row
   producing its artifact — the same missing-legal-start defect, one level along the chain. Drafting it
   is not approving it, and collects no observations. **Item 2i — the integrity preconditions.** It
   depends on neither Chris #2 nor
   item 1, and the founding argument says it must precede all measurement. Until this row existed,
   #844 and the completeness **propagation-and-refusal** half were specified only inside BLOCKED cells
   and had no legal start — the one class of work the ordering says comes first was the one class
   nobody could begin. **What has no predecessor is the 2i NODE, whose scope the dependency graph
   defines once; this line does not restate it.** An earlier version of this sentence restated the
   scope and claimed the detection half, which is what put the cycle into the graph above.
2. **Item 1** — nothing depends on it being late. It gates 2-A and 7a-i DIRECTLY; `2a-env` gates on
   the 2i NODE and must NOT be scheduled behind item 1 (bound (i-a)); 2-B gates on Chris #2 AND
   `protocol-approved`; and 2a's convergence half and item 8's mutating half reach item 1 only
   through `baseline captured`. (CORRECTED 2026-09-10, round-16 finding [6]; UNREVIEWED — "items 2,
   2a, 7a-i and 8 all wait on it" was a parallel narrative, not a projection of the graph, which
   this surface declares itself to be.)
3. **Item 5, in parallel** — the graph has always allowed this (`5 ── parallel with 0/1`), its status
   is TODO not BLOCKED, and it appears nowhere in Worker ownership. It waits on nothing: not Chris #2, not
   item 13, not log isolation. Item 4 also has no predecessor (`4 ── precondition first`); no
   predecessor is not start authority, so item 4 is not listed as startable. Run it in a separate worktree,
   with the `.github/required-checks.lock` `matrix_value` / bare-key `shell-tests` aggregate contract
   as its first commit. An earlier draft called item 1 "the only unambiguous start" and left item 5
   unscheduled and unowned; that was a defect against the graph.
4. **Item 0 / #570 — PRESERVE AND DEFER; no next action is scheduled.** #570 is the only unowned
   member of the approved seven, and *Still needs Chris* #6 **resolved that from the record on
   2026-09-09: no worker is assigned, and the historical record is PARKED.** Its worktree holds an
   untracked design doc (see *Worker ownership*); the standing action is to preserve that — **not**
   to assign, resume, retire or discard the worktree, and not a licence to start new gate work.
   **Owner absence is not disposal authority**, so the answered assignment question schedules
   nothing: #570 stays preserved and deferred under drain.
   **#789 is deliberately not listed here**, for two independent reasons. It is a descendant
   discovered since 0827, not one of the approved seven, so scheduling it as item-0 work would have
   silently answered the bounded-tranche question in *Still needs Chris* #2 — **now ANSWERED
   2026-09-09 as "the original seven only", which settles this reason in the same direction: #789 is
   an item-12 successor, not item-0 work.** **And its content is
   superseded on main by `bdb9b776` (#803/#810)** — its 642-line untracked test is an earlier
   precursor of the 1,786-line file already merged. Preserve its uncommitted work regardless of how
   the scope question lands, since preservation is not scheduling; but preserving a stale precursor
   is not the same as scheduling it.
5. **Item 13** is deliberately absent from this list. Its hunks live in a report that is not on this
   branch, and both hunks it once promoted to first position were found overstated on
   re-measurement. Item 13 stays off this list until `docs/audits/2026-09-05-prompt-audit.md` LANDS on this
   branch (REORDERED 2026-09-10, round-16 finding [16]; #7 is cited below as RESOLVED
   provenance, never as an open conjunct) **AND `baseline
   captured` is reached** — the hunk application is a mutating half under the graph's own rule, so
   Chris #7 alone does not authorize it. **#7 was RESOLVED 2026-09-09 (worker default): bring the
   single audit file across. That settles the DECISION, not the CONDITION — the report is still not
   on this branch, so item 13 stays absent from this list until the file lands and `baseline
   captured` is reached.**

## Moved from the parent 2026-09-25: *Feasibility evidence and limits* (§ *Dependencies, order and acceptance for the remaining work*)

**FEASIBILITY EVIDENCE AND LIMITS — ADDED 2026-09-16 post-15 (native round-15 issues[5] and issues[6] MEDIUM; Photon correction decision; UNREVIEWED). THE ACCEPTANCE ABOVE IS UNCHANGED: NOT WAIVED, NOT NARROWED AND NOT DECLARED UNREACHABLE.**
Measured: before this correction the document was 596,291 bytes (candidate `09cd5dff`) and the round-15 arbiter prompt 626,310 bytes; reviewer_3 (grok) exited 124 in the three native rounds up to and including run `235c2564`, the last at 1800 s, while agy fulfilled reviewer_1 on that same prompt; coverage was therefore DEGRADED 2/3 in those rounds, which #355 does not accept as PASS (`run-design-review-loop.sh:2290`, `:2355`). **THAT CURRENCY QUALIFICATION IS WITHDRAWN — CORRECTED 2026-09-17 root-A (run `7886ed9f` HIGH; UNREVIEWED).** It read: "CURRENCY-QUALIFIED 2026-09-16 root-A (source-bound; UNREVIEWED): that grok-124 observation is HISTORICAL, not current — the later run `59693be3` recorded `coverage_status: "FULL"` with all three lenses returning fresh verdicts, so the sentence above must not be read in the present tense". **RUN `7886ed9f` REFUTED IT.** That run recorded `coverage_status: "DEGRADED"`, `fulfilled_lens_count: 2`, `reviewer_1_fulfilled: "false"`, `reviewer_1_reason: "runtime-droid-rescue"` and `metadata.coverage: "DEGRADED 2/3 (reviewer_1 UNFULFILLED — agy exited 124 at 241.3s, droid rescue; codex and grok fulfilled; auditor witness ERRORed and is auxiliary, not counted)"`. **AS OF 2026-09-17, THE TIMEOUT-AT-BUDGET CLASS THAT COSTS A LENS WAS STILL RECURRING, AND `59693be3`'s FULL 3/3 WAS ONE ROUND, NOT A RESOLUTION.** What changed is WHICH lens, not whether it happens: in `7886ed9f` grok was FULFILLED and reviewer_1 (agy) was the lens lost, at 241.3 s rather than at a 1200 s or 1800 s budget — so the reviewer_3 measurement above stays as written, as a reviewer_3 record, and must NOT be generalized into a claim that this document has become reviewable at FULL coverage. Under #355 a PASS is withheld on DEGRADED coverage regardless of counts; the live coverage state is in the status file the CURRENT STATE pointer names, not here (date-qualified 2026-09-24; UNREVIEWED). **On 2026-09-17 the counter read 14 of 15, not 14 of 14** — `state.md` then carried `iteration: 14`, `max_iterations: 15`, `status: "parked_no_progress"`, `early_stopped: "no_improvement_trajectory"`, unmoved by run `7886ed9f` (observed, not corrected). No allowance is read off it here: whether a further round runs is Photon's decision (`840-plan-blocking-correction-20260917.md`). Either way this is a review-ALLOWANCE state, not a feasibility result.
Not established: that prompt size causes grok's timeouts, or any prompt size below which grok completes — no such budget has been measured, so none is recorded beside the acceptance.
The structure finding (normative rules inside large cells carrying dated overlays) is acknowledged: this correction replaced contradicted sentences in place where it could; no split, relocation or deletion was made then (2026-09-16), since that needs Chris's approval under the standing constraint; and any further native round needs its own authorization.

---

## Moved from the parent 2026-09-26: § *#840 proposed revisions — item-by-item disposition*


Per the operator's fourth premise: being written into the draft is not approval. Every change #840
makes to the approved plan is listed; nothing is adopted silently.

| # | What #840 proposed | Evidence | Disposition |
|---|--------------------|----------|-------------|
| Header | Mark the amendment DRAFT, record a source checkpoint, stop implying every item is still open | Correct — 5 of item 0's 7 issues closed | **Adopted** (checkpoint moved to `main@727d4652`) |
| New §| "Execution model — preserve configured routing" | Matches deployed `busdriver.json`; verified against both config files | **Adopted**, with the routing table added as observed evidence |
| New § | "Instruction scope — source files are not the delivered context" | `hooks.json` SessionStart → `load-orchestrator.sh` verified in source; this session's own brief observed | **Adopted**, with explicit evidence grades and the (b) surface marked 待核實 |
| Why-this-order | Reframe integrity-first as a "bounded, evidenced tranche"; an adjacent issue does not freeze unrelated work | No new evidence — a policy judgement | **REJECTED 2026-09-09** (worker default, same no-loosening rule applied at *Still needs Chris* #3 and #9): the approved integrity-first ordering is **RETAINED**. It loosens an ordering every council voice endorsed, on a policy judgement with no new evidence — the same shape as #3's precondition narrowing and #9's review waiver, and answered the same way, because retaining an approved constraint needs no authority while loosening one does. **Not carried by Chris #2(i), and the difference is exact rather than generic:** #2(i) governs the SCOPE OF A MEASUREMENT — whether item 2's baseline may be captured over a partially-closed gate — and is self-limiting, because the limitation is stamped on the baseline and travels with every later comparison. This cell would govern WHICH WORK MAY PROCEED, plan-wide: "an adjacent issue does not freeze unrelated work" removes the ordering itself, stamps nothing, and leaves no artifact carrying the residual risk. Accepting a bounded *dataset* does not imply a bounded *gate ordering*. **No fresh material-risk decision is identified here, so none is escalated** |
| 0 | Reconcile before implementing; name the violated invariant and threat model per change | Necessary and factual | **Adopted.** Original concrete settling check restored — #840 had replaced it with prose |
| 1 | Broader named test list; droid fallback changed only by operator config | Additive, consistent with the original's "whole shell suite" | **Adopted** |
| 2 | More ledger dimensions; separate infra failures from findings | Additive, no policy change | **Adopted** |
| 2a | New convergence item; claims `init-review-loop.sh` and `prompt_template.txt` conflict | Partly verified, partly wrong. The drip cap is real (`:466`/`:556`) and the template has **zero code consumers**, so it is orphaned rather than competing — but #840's "10 vs 3" framing does not hold, since the live prompts carry the same 10-issue budget at `:464`/`:554`. #840 also cited the template under `scripts/` — wrong path. Anchors live in the item-2a row, not here | **Adopted, corrected and re-scoped** — #840's cited anchors and its two-source framing were both wrong; the authoritative statement is the item-2a row above, not this cell |
| 3 | Confirm consumers before pruning; archive only after item 1 | Sound sequencing | **Adopted** |
| 4 | Split copier retirement from content pruning; the full 235-row inventory gates only the *pruning* | The original and Codex's #775 condition made the inventory gate **retirement** | **REJECTED 2026-09-09** (worker default, *Still needs Chris* #3) — a real loosening of an approved precondition, offered without evidence; the inventory keeps gating RETIREMENT |
| 5 | Require zsh; expose sub-case skips; separate dependency latency from failures | Grounded in #821 and #829 — **both CLOSED/COMPLETED (#821 `2026-09-10T13:06:50Z`, #829 `2026-09-11T19:42:08Z`); status defined once in Progress row 5 and cited here** (CORRECTED 2026-09-16 root-A; source-bound; UNREVIEWED). Closure retires the tickets, not the residual work this row adopts. | **Adopted** |
| 6 | Keep stage/role mapping; refine the existing brief; keep references reachable | Consistent with premise 1 | **Adopted** |
| 7 | Downgrade the gate to an **opt-in cohort experiment** because Claude/OMP/Cursor should not share one cost policy | The gate is a Claude Code PreToolUse hook — OMP and Cursor were never subject to it, so the multi-harness objection does not reach it | **REJECTED** (operator premise 2). Original gate direction restored; #840's metric list adopted as the acceptance measurement |
| 8 | Pin the current severity baseline in tests before adjudicating | **Verified on `origin/main`**: `lib/merge-findings.py:67` `{high, medium}` for iterations ≤2, `{high}` after; the SAST/lint deterministic-blocker predicate `_is_deterministic_blocker` is defined at `:45-49` and **invoked at `:70-71`** (re-measured at the checkpoint 2026-09-08, round 8, M21 — the bare `:49` named only the predicate's `return` line and not the site that makes it blocking) | **Adopted** |
| 9 | Narrow the exemption from "docs-only" to "genuinely passive prose" | The reasoning is right — SKILL/agent Markdown is behaviour-affecting | **Adopted**; class boundary **RESOLVED 2026-09-09** (worker default, *Still needs Chris* #4) as a fail-closed, initially-empty allowlist |
| 10 | Inventory all host adapters *before* continuing any pi slice | Collides with the in-flight `pi-cursor-sdk-sandbox-eval` work | **Adopted for MUTATING slices only — RESOLVED 2026-09-09** (worker default, *Still needs Chris* #5); the eval continues as evidence-gathering |
| 11 | Keep the original candidates; skip completed work | True, but the list is stale — see the count in the Disposition cell and the *New issues* table, which are the single source (an earlier draft of this cell said "12", a leftover that contradicted the same row) | **Adopted.** The triage list is stale: **30** issues opened since 0827 are bucketed in *New issues since 2026-08-27* (29 plus #844, added when it was given a schedulable home in item 2i); item 11 re-buckets those alongside the original closure list before any probe |
| 12 | Minimum e2e cases ship with each item-0 fix rather than deferred | Strictly stronger than the original | **Adopted** |
| ADR § | Rewrite as "ADR bookkeeping and review boundary"; state this edit amends nothing at runtime | Accurate | **Adopted** |
| Handover | Demote the 0827 handover to "Historical" | Correct — its probes and line numbers are stale | **Adopted** |
| 13 | *(absent from #840)* | The item and `docs/audits/2026-09-05-prompt-audit.md` exist only on `docs/plan-0827-status-and-prompt-audit`, which has no PR | **Item restored; report file NOT carried** — **UPDATED 2026-09-09 (`全部批准`, round-14 finding [17]; UNREVIEWED):** this cell said moving the file "is a scope decision for Chris (#7)", but **#7 is RESOLVED** (worker default: single-path checkout of the audit file), so the decision is no longer open. What remains is the file LANDING on this branch, which is item 13's live gate alongside `baseline captured` — cited to #7 and to item 13's row, not restated here |

Beyond the table, #840 replaced the original rows' **concrete settling checks** (runnable commands,
`file:line` anchors) with prose acceptance language. That is a loss of the property that made the
0827 plan checkable, and the concrete checks are restored above.
