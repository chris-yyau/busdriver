# Pipeline final plan — 2026-08-27 (integrity first)

> **ROADMAP (Chris, 2026-09-26):** whole-plan review stopped after the loop parked; the last verdict, FAIL, stays in the status file. This file and its children are now a roadmap, not a spec: the COMPOSITION STEP, acceptance (i)–(iii), the recorder and the STANDING-FAIL SCOPE gate nothing. Each item starts only with its own design document, reviewed by blueprint-review before implementation; that document is the item's spec and wins over this file.

> **Original approval: 2026-08-27**, after the pipeline audit, ultra-council, open-issue triage,
> and ultimate-council (5 voices + UltraOracle + Mythos Witness + Mechanism Witness).
> Hindsight: `initiative-pipeline-final-plan-2026-08-27-integrity-first`.
> Lessons: `~/.claude/notes/lesson-council-2026-08-27-{audit-logs-are-test-polluted,integrity-before-cost}.md`.
>
> **2026-09-08 consolidated revision: DRAFT, pending blueprint-review and the PR review on #840.**
> Consolidates the original approved plan, the 2026-09-06 amendment proposed in PR #840, the
> 2026-09-05 status check and prompt audit, and the current tree. Original item numbers are
> retained. Added after 0827: **2a, 2i, 2p, 13**. Membership is the execution-order table, not this
> sentence (CORRECTED 2026-09-12, native finding [17] MEDIUM: 2i and 2p are first-class rows — 2i
> gates `protocol-approved` and 2p produces it — so "2a and 13 are the only additions" was a count
> this document's own table falsified; UNREVIEWED). **The 2026-08-27 approval does not certify this
> revision**, and a proposal written into this draft is not thereby approved — every change
> inherited from #840 carries an explicit disposition in *#840 proposed revisions* (moved to the 2p file (2026-09-26; UNREVIEWED)).
> Source checkpoint: `main@727d465215dc2e2370b595fb1300746447461456` (v2.1.15, 2026-09-07).
> **History moved out of the reviewed file (2026-09-23, Chris-approved split; plan-only, UNREVIEWED).** The review history for rounds 1–18 and every post-round correction-phase narrative that stood here are now in `docs/plan-history/2026-08-27-pipeline-final-plan.history.md` § *Header history*. The review loop reads only this file, so it does not read that sibling. Nothing there is binding. Each binding decision it records is specified once in the row or bound it names, and this file keeps that row. Two approvals appear only there, as provenance for correction phases whose resulting text is in this file: `這些可以你自己決定吧？` (the post-round-11 correction phase) and `批准840本輪文件修正` (the post-round-12 correction phase).
> **CURRENCY RULE, carried from the moved history (`:78-81` before the split):** currency is stated ONCE, in the sibling status file that the CURRENT STATE pointer below names, and no line in this file claims to be current (re-pointed 2026-09-23, native run `462c1f6b` HIGH; plan-only, UNREVIEWED).
> **SIX BINDING CONTRACTS LIVE OUTSIDE THIS FILE (2026-09-23 split, Chris-approved; plan-only, UNREVIEWED).** Five were moved verbatim and the Item 7 rule (4b) in part, each leaving its lead sentence and a citation at its original place; the (4b) `probe_unavailable` DENY paragraph then left behind is now in the item 7 file, its one binding location (SECOND MOVE, below; 2026-09-24; UNREVIEWED). The six files: `docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-2p-review-yield-protocol.md` (Item 2p — Review-yield protocol DRAFT (Item cell)); `docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-2a-i-c-scanner-counters.md` (Item 2a — (i-c) short-circuit preconditions: the scanner counters); `docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-2a-i-a-producer-readers-gate-and-2-cap.md` (Item 2a — (i-a) producer, readers and gate, plus bound (2-CAP); relabelled 2026-09-23 (native run `6e0afdc0` HIGH, arbiter-confirmed; Photon correction decision; plan-only, UNREVIEWED)); `docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-2a-transport-envelope.md` (Item 2a — transport status (THE ENVELOPE)); `docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-7-rule-4b.md` (Item 7 — rule (4b): genuinely size- or containment-indeterminate ⇒ DENY); `docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-8-validation-before-dedup.md` (Item 8 — validation runs over all ingested records, before deduplicate()). **They are binding, and they are NOT history.** Each is an INDEPENDENT DESIGN FILE that the review loop reviews on its own (`init-design-review.sh <path>`), made so 2026-09-23 (Chris-approved; plan-only, UNREVIEWED). A review verdict on this file, PASS included, covers only this file's spec hash and none of the six; a verdict on one of the six covers only that file. Until they are accepted as set out below, each one is UNREVIEWED. **COMPOSITION STEP: ACCEPTANCE ACROSS THE SEVEN FILES (2026-09-23 (native run `6e0afdc0` HIGH, arbiter-confirmed; Photon correction decision; plan-only, UNREVIEWED)).** It replaces the earlier sentence that required each child's PASS to be "cited here by `run_id` and spec hash". Writing those citations into this file would change its spec hash and void any PASS on it. Acceptance runs in this order, and nothing in it folds the six back into this file. **(1) Children first, and this file on its own.** Each of the six is reviewed on its own, and this file is reviewed on its own. **CONTENT FREEZE (2026-09-26; UNREVIEWED):** before (2), every pending correction lands in one batch and the seven files are frozen; a finding raised after the pin is queued for one scheduled re-pin, never answered by an edit to a pinned file. **(2) Pin.** Each child's path, sha256 spec hash and PASS `run_id`, together with this file's spec hash and its standalone PASS `run_id`, are recorded in a SEPARATE manifest, `docs/plans/2026-08-27-pipeline-final-plan.d/composition-manifest.json`. Each pinned PASS must be CURRENT for its spec hash under the ATTESTATION RULE, and its manifest entry names its #16(b) authorization; the recorder refuses a superseded or unauthorized run, with a fixture, and re-checks CURRENT when (iii) is recorded and at every read of the ACCEPTANCE RECORD (2026-09-26; UNREVIEWED). They are never recorded in this file. **STAMP (2026-09-24; Chris-approved shrink; UNREVIEWED):** the review loop stamps the design file after the review, so the reviewed hash, the one pinned here, is the sha256 of the file before that stamp, and that file must already be under the measured transport cap. Those PRE-STAMP BYTES are produced by the existing per-run archive step: before the `--claude-only` finalize that could stamp the file, the operator copies it into that run's review archive (`.claude/archive-<ticket>-run-<run_id>/`) beside the run's native artifacts and records the archive's sha256 digest. The copy is valid only when its sha256 equals that run's `metadata.spec_hash`; a run whose archive lacks a valid copy supplies no pinned hash, and none is backfilled. Every check below against a pinned hash reads that copy, never the stamped file (2026-09-25; UNREVIEWED). **(3) Integration review.** One review then covers the pinned seven: this file plus the six at their manifest hashes. Its subject is the joins between them. Every cross-file reference must resolve to text that exists at the pinned hash. Every shared token (the `completeness` enum, the `internal:merge-findings` diagnostic, the FORM token and fixture IDs) must mean the same thing in every file that uses it. Every graph edge whose endpoint or capability dependency lives in a child must match the dependency graph, which since 2026-09-24 lives in the 2p child. **TRANSPORT, NAMED (2026-09-24; UNREVIEWED):** the integration review runs on the one transport this plan already uses for every review, the native blueprint-review loop, which embeds the single design file it is given in each lens's prompt; no reviewer is assumed to read anything from the repository checkout. That single file is the integration document (each part is one when the DRY-RENDER partitions it), and it is the ONLY input a lens must receive. It names the seven paths, their pinned hashes and these checks, and for each side of each join it QUOTES a JOIN WINDOW: the bytes from 256 before to 256 after that side's join offset, clipped to its line, keyed by path, line number, offset and the window's sha256, at the pinned hash. Identical windows are quoted once and shared, and no whole line or child file is quoted. For a § citation the cited side is instead the cited section's lead paragraph, quoted whole (2026-09-26; UNREVIEWED). Each join record names its two JOIN WINDOWS (the joining side and the cited anchor) and quotes nothing itself. Beyond the windows, the integration lens receives each shared token's whole defining sentence and each graph projection's whole 2p graph entry, quoted once; no join cap is raised (2026-09-25; UNREVIEWED). A required recorder fixture places a join's text after byte 512 of its line and asserts that the rendered prompt contains that text (2026-09-25; UNREVIEWED). **The seven files themselves are NOT required to reach any lens**, because that transport delivers one file. The recorder's DRY-RENDER FIXTURE measures each lens's fully rendered prompt (framing, canaries and route line included) before any round; an over-cap integration document is partitioned into parts, each whose rendered prompt is under 524,288 bytes and each named in the manifest; each join record stays whole in one part with every window, defining sentence and graph entry it needs, and quotes are shared only within a part (2026-09-26; UNREVIEWED); and the round FAILS only if a part still exceeds that. Nothing is ever truncated (2p graph, `recorder`) (2026-09-26; UNREVIEWED). Every join the checks above name, and every projection this file makes of the dependency graph, is a REQUIRED join. **REQUIRED-JOIN INVENTORY (2026-09-24; UNREVIEWED):** before any lens runs, the recorder enumerates every required join from the pre-stamp copies of the seven pinned files (each path or § citation from one of the seven into another of the seven, each shared-token use, each graph edge with a child endpoint, each graph projection in this file, meaning any status cell or sentence in this file containing a node ID from the pinned 2p graph block, backticked or preceded by `item`, `node` or `row`, or a quoted milestone from that block (2026-09-26; UNREVIEWED)) and writes that list into the integration document. The recorder fails (iii) if the inventory is missing, if a required join is absent from it, or if any listed join is unquoted. A required join is absent when the JOIN SCAN finds it and the inventory lacks it. The JOIN SCAN is a second procedure, not the function that wrote the inventory: it scans the pre-stamp copies of the seven files for the four classes named above (path or § citation, shared-token use, graph edge with a child endpoint, graph projection); its shared-token class is an exact text match, not a semantic judgment, over the tokens that already have a pattern: the backticked enum `` `completeness` `` (the bare English word does not match), the exact diagnostic `internal:merge-findings`, the literal prefixes `PASS-FAST-` and `PASS-EXCLUDED-`, and the backticked bare tokens `` `PASS-FAST` `` and `` `PASS-EXCLUDED` `` (2026-09-26; UNREVIEWED). A form or fixture-ID class whose pattern is not yet chosen is neither excluded nor an immediate failure: the node that owns it defines the pattern first, and only then does the recorder check that class and record (iii) (the `2a-env-form ──► recorder` edge in the 2p graph) (2026-09-25; UNREVIEWED). Before dispatch the recorder confirms that each JOIN WINDOW occurs byte-for-byte at its offset in the named line of that file's pre-stamp copy and that its sha256 matches, and a quote that does not invalidates the run. The manifest and that document are written at steps (2) and (3), not now, and no review is run by this correction. **ACCEPTANCE, DEFINED ONCE, HERE (2026-09-23, native run `462c1f6b` HIGH, arbiter-confirmed; plan-only, UNREVIEWED). This plan is accepted only when all three hold: (i) a standalone blueprint-review PASS of this file at the spec hash pinned in the manifest; (ii) a PASS of each of the six children at its pinned hash; and (iii) an integration PASS of every integration document named in the manifest, which together name exactly the seven files and hashes in that manifest, no more and no fewer.** Each integration document or part is recorded in the manifest by path and sha256 before dispatch, and each (iii) PASS's spec hash must equal that pinned hash (2026-09-26; UNREVIEWED). (iii) certifies the consistency of the QUOTED text of declared joins only: a clause of a cited section outside what is quoted is not covered, and two files that contradict each other with no citation, edge or scanned token between them share no join, and that residual is named here, not covered; so are citations of files outside the seven (the status and history files, the prompt audit, ADRs), which are not joins (2026-09-26; UNREVIEWED). None of the three stands in for another. **An integration PASS does NOT clear this file's standing FAIL under #16(a)(B).** It covers only the joins, and (i) is still required. A child PASS likewise does not stand in for (i). A change to any of the seven files after pinning voids the manifest and the integration result, and a PASS bound to the changed hash no longer counts toward (i) or (ii). **VOIDING CHECK (2026-09-24; UNREVIEWED):** at (3), and again before implementation relies on it, the recorder compares each WORKING file, the one implementers read, with its pinned pre-stamp copy, after deleting from both every whole-line runner stamp (`<!-- design-review-coverage: … -->`, `<!-- design-reviewed: … -->`) and trailing blank lines; any other difference voids the manifest. **BYTE BINDING (2026-09-24; UNREVIEWED):** the integration run verifies the sha256 of the pre-stamp copies of the seven files its integration document quotes against `composition-manifest.json` BEFORE dispatch and AGAIN when its verdict is recorded; any mismatch invalidates the run, and the integration verdict carries the manifest's own sha256. **THIS IS A SENDER-SIDE CHECK, NOT PROOF OF RECEIPT (2026-09-24; UNREVIEWED):** a matching sha256 proves what was sent, not the bytes a reviewer received. A reviewer whose delivered payload was cut has NOT received its input in full, so that lens cannot count, whatever the runner's coverage label reads. **RECEIPT CHECK, ONE MECHANISM (2026-09-25; UNREVIEWED):** the runner writes `<reviewer>-receipt.json` for each lens after its CLI exits; no reviewer writes it, and each dispatch replaces it. It records the run id, the slot and its CLI, the lens's two canaries, the runner identity (below), the prompt bytes the runner handed over, and a truncation flag the runner sets itself when the agy argv ceiling refuses the prompt or the raw output file is missing or unreadable. A lens is RECEIPT-CLEAR only when BOTH hold: the runner records its slot FULFILLED by its configured reviewer under #355, and its sidecar exists, names this run, carries no truncation flag and records every prompt byte handed over; its verdict echoes both canaries, and the agy lens also passes the raw scan (below). The runner applies that check before its PASS stamp and withholds the stamp otherwise. **BOOTSTRAP (2026-09-25; UNREVIEWED):** a run counts toward (i), (ii) or (iii) only if the `runner_closure` its sidecars record equals the same digest over `git ls-tree -r` of a litmus-reviewed commit for the runner's closure dirs (`skills/blueprint-review`, `scripts/lib`, `hooks/gate-scripts/lib`, `skills/dispatch-cli`), RECEIPT CHECK included, no sidecar reports `runner_changed`, and a pinned PASS records that closure in `composition-manifest.json`; a run with no recorded, committed and pinned closure counts toward none. The reviewer CLIs, python3, jq and node_modules are outside the closure. The runner records its closure at dispatch and at receipt; it never compares it to a commit. The recorder is owned by the `recorder` node of the dependency graph (2p file). That commit merged to `main` on 2026-09-25 as `be15d1b0`, so the node's gate is met (2026-09-25; UNREVIEWED). Then the recorder applies the same check when a PASS is pinned at step (2) and when the integration verdict is recorded at step (3). The raw output of the lens whose sidecar names agy as its CLI is also scanned for the ERE `<truncated [0-9]+ bytes>`: a missing or unreadable file, or a match outside a finding's JSON string, withholds the PASS; a match inside one is a quotation, ignored. Cuts are caught by CANARIES on every lens: the runner puts a fresh random nonce as each prompt's first line and another as its last, records both in that lens's sidecar, and withholds the PASS unless the verdict echoes them in `metadata.input_canary_head` and `metadata.input_canary`; every archived cut dropped the input's tail (2026-09-25; UNREVIEWED). **A lens that is not RECEIPT-CLEAR counts toward NEITHER coverage fulfillment NOR a PASS**, for (i), (ii) and (iii) alike; it stays in the record, marked not RECEIPT-CLEAR. A droid rescue stays UNFULFILLED under #355 and is never a coverage lens. A verdict with fewer than three RECEIPT-CLEAR lenses supports no PASS toward (i), (ii) or (iii), and the runner's coverage label alone never establishes coverage. **A PASS certifies no detected truncation, never receipt:** the sidecar proves what the runner handed over, not what a lens's CLI delivered to its model, so a cut strictly inside a prompt that keeps both canary lines is outside the PASS condition, and every PASS record states that limitation. **The runner's `design-reviewed: PASS` stamp is not the acceptance PASS:** that stamp and a FULL label support none of (i), (ii) or (iii) unless the recorder's RECEIPT CHECK also passed. No gate reads `composition-manifest.json` today, so implementation start reads the recorder's ACCEPTANCE RECORD (2p graph, `recorder`), never a stamp; the gate read that enforces it is a recorder deliverable (2026-09-26; UNREVIEWED). Every other statement of this plan's acceptance defers to this one and does not restate it. **No fresh ceiling:** a child or integration review is a successor under #16(a)(B), so it carries this plan's standing FAIL, and each of its rounds needs its own #16(b) authorization. **LEFT AS IS, AND NAMED:** `init-design-review.sh` still creates a fresh `state.md` counter and ceiling for each new file. Making that counter inherit this plan's would need a review-script change or a ceiling decision, and both are outside this correction. Such a counter grants nothing, because under #16(b) numeric headroom is not review authority. #355 is unchanged; the PASS rule changes only by the RECEIPT CHECK above.
> **SECOND MOVE, INTO THE SAME SIX FILES (2026-09-24; Chris-approved shrink; UNREVIEWED):** to fit the measured agy receipt cap, whole sections moved verbatim into the existing children, each leaving a one-line pointer naming the child: § *Item 2*, the fenced dependency graph and the *Standing fallback* with the approved 2-A/2-B split into the 2p file, later joined by *Recommended next actions*; § *Item 2i* and § *Item 8* into the item 8 file; § *Item 2a* into the (i-a) file; § *Item 7*, its `probe_unavailable` DENY paragraph included, into the item 7 file. No requirement was deleted. This file's review does not cover the moved text, and no reviewer of this file is assumed to open a child; each child's text is reviewed with that child.
> **CURRENT STATE — MOVED OUT OF THIS FILE.** Live run status is in `docs/plan-status/2026-08-27-pipeline-final-plan.status.md` and nowhere in this file. Every reference in this file to "the one current record" or "the current record" means that file. This file states no run result and claims no PASS.
>
> **ATTESTATION RULE — lifted verbatim from the superseded `7886ed9f` record when that record moved in the 2026-09-23 split:** **THE RULE THAT REPLACES IT, AND IT IS A RULE ABOUT ARCHIVES, NOT ABOUT HEAD: a run is ATTESTED when a native artifact carries it as `metadata.run_id` and that artifact sits in a hash-verified archive; a run is CURRENT when it is attested and no attested run supersedes it (a run supersedes another when it reviews the same document path at the same spec hash and is later in attested archive order, whatever its verdict (2026-09-26; UNREVIEWED)); a mention in prose or in a finding's text is NOT attestation.**
> **ANCHOR AND INVENTORY RULE — lifted verbatim from the same record:** **ANCHOR AND INVENTORY RULE — ADDED WITH THIS RECORD:** every implementation node RE-DERIVES its source anchors and its inventories ON ITS OWN START TREE (R1's rule above makes this mechanical); an anchor or list carried forward from an earlier revision is stale by construction, as this document's own history shows.
> **Superseded records moved (2026-09-23 split):** the superseded `7886ed9f` record, the round-18 record and the post-round-18 correction-phase narrative are in `docs/plan-history/2026-08-27-pipeline-final-plan.history.md` § *Superseded records*. They are history, not binding.
## Execution model — preserve configured routing

Operator clarification (2026-09-06): Claude Code usually completes planning; Hermes uses Herdr to
assign an issue/plan to Claude Code, OMP, or Cursor-agent using dependencies and quota. The selected
worker owns the remaining Busdriver pipeline through delivery. This records the operator's deployed
workflow; it does not claim that every host adapter is shipped or verified in this repository.

**Pipeline stages and the effective `busdriver.json` routing already determine when and which
agents are used.** Preserve that configuration-driven contract, including its configured fallbacks
and gate-specific restrictions. Hermes selects the pipeline worker; the worker follows the existing
pipeline and resolved routes. Neither gets a new power to improvise reviewer substitutions, skip
stages, or rewrite routing to obtain a PASS. Grok, Agy, Codex, OpenCode and Droid remain helpers or
review backends in this workflow, not additional full-pipeline workers. This revision adds no
free-form scheduler and proposes no migration to Paseo or another orchestrator.

Effective routing at the checkpoint — read from the deployed configs 2026-09-08, **observed**:

| Role | `~/.claude/busdriver.json` (user-global) | `.claude/busdriver.json` (repo) |
|------|------------------------------------------|----------------------------------|
| `litmus.reviewer` | codex → droid | codex → droid |
| `blueprint-review.reviewer_1 / _2 / _3` | agy→droid / codex→droid / grok→droid | same |
| `blueprint-review.auditor` | *(absent — falls back)* | opencode |
| `council.pragmatist / critic / researcher` | agy→droid / codex→droid / grok→droid | same |
| `council.auditor` | *(absent — falls back)* | opencode |
| `auditor.model` | `opencode-go-lb/deepseek-v4-pro` | — |
| `agy_read.model` | `gemini-3.8-flash-high` | — |
| `pi_read.model` | `cursor/auto` | — |
| `ultraOracle.model` | `gpt-5.6-pro` — **BROKEN** | — |

The two files diverge on the auditor routes only. `.claude/CLAUDE.md` still describes the agy-read
lane as "Gemini 3.7 Flash" while the deployed value is `gemini-3.8-flash-high` — a stale factual
claim in contributor docs, **recorded here, not fixed by this revision** (it is a runtime-adjacent
doc edit, out of this document's scope).

**`ultraOracle.model` is not merely drifted — it is broken, and it is the reason this plan's own
review rounds lost their UltraOracle advisory.** `~/.claude/busdriver.json:33-34` sets
`"ultraOracle": { "model": "gpt-5.6-pro" }`, and the run's own error file records verbatim:
*"oracle 0.17.3 … GPT-5.6 Pro is an API reasoning mode, not a model slug. Use `--model gpt-5.6-sol
--reasoning-mode pro`."* A section whose stated purpose is "read from the deployed configs,
observed" should not silently omit the one deployed route that fails. The fix — `gpt-5.6-sol` plus
`--reasoning-mode pro` — is recorded in *Still needs Chris* #8 alongside the Gemini doc drift; both
are the same class of recorded-but-out-of-scope finding, and would otherwise be lost. The advisory
is auxiliary and non-gating, so coverage was never affected.

**`blueprint-review.reviewer_1` (agy) transport — TEMPORARY LIMITATIONS ACCEPTED BY CHRIS 2026-09-14
(`840agy放寬一點吧，它這個cli本來就功能殘缺，暫時先接受`); candidate UNAPPLIED ON THIS BRANCH, UNREVIEWED — CURRENCY-QUALIFIED 2026-09-16 root-A (source-bound; UNREVIEWED): the fix landed upstream as **PR #855** (`3bb16144679f61ab9090ab00751f31739891fbc9`, merged to `main` `2026-09-14T17:22:16Z`) and `git branch --contains` on 2026-09-16 does **not** list this branch, so "UNAPPLIED" remains true HERE and is stated with its scope rather than left undated. The landed PR does not discharge this row's obligation.**

- **Observed.** This plan's native review lost the real AGY lens: the prompt (534,794 B) exceeds the agy argv ceiling (524,288 B), agy 1.2.2 has no file-input flag, and the droid rescue filled reviewer_1 (`runtime-droid-rescue`).
- **Candidate.** One agy ≥1.2 rung in `resolve-cli.sh` that sends the prompt as a single stream-json stdin message.
  - It reuses `_run_review_with_retries … pipe-review` from a fresh workspace outside the checkout.
  - The 1.1.x argv rung (with its oversize refusal) and the 1.0.x stdin rung are unchanged.
- **Result contract.** An attempt counts only with ALL of:
  - rc 0 and empty stderr;
  - exactly one terminal `result` as the last event, `status` SUCCESS, `num_turns` ≥ 1;
  - a non-empty `response` and no `denied_actions`.

  Anything else — error, timeout partial (exit 0 plus stderr warning), empty, denied or truncated — is no review from that attempt and goes to the existing retry/droid fallback. A counted attempt is transport completeness only. It is never a verdict or a PASS: the arbiter, countability, coverage (#355) and review-ceiling rules are unchanged, and the prior native FAIL stands.
- **Accepted as temporary limitations (disclosed, NOT verified capabilities).**
  - The workspace PreToolUse guard is best-effort defense in depth, NOT enforced read-only containment. Under the operator's `toolPermission: always-proceed`, a hook that exits 0 with empty output let a native write run (disposable fixture, 2026-09-14).
  - One approved `request-review` fixture auto-denied that write headless (SUCCESS, empty `response`, `denied_actions`). The global setting was restored and is not adopted.
  - Unproven:
    - native large-payload byte completeness;
    - observed native timeout partial;
    - untested tool classes (MCP, subagents, browser);
    - reviewer fidelity with an isolated cwd (relative paths no longer resolve to the checkout);
    - retry-classification integration, 1.0/1.1 regression pins, and gate-integrity/#803 trust for the added `scripts/lib` assets (outside `.gate-integrity.lock` scope).
  - A reviewed tree used as a workspace runs its own `.agents/hooks.json` as host commands. This was reproduced in stream mode; for today's argv rung it is inferred, not tested.
- **Not relaxed (original review requirements).** Three-voice coverage, the rescue firing only on failure, the arbiter's fail-closed PASS derivation, and the ceilings.

## Instruction scope — source files are not the delivered context

**2026-09-06 correction, retained.** Busdriver's own `.claude/CLAUDE.md` is contributor guidance for
working on Busdriver. Its presence or size is not evidence that another project receives it by
installing the plugin. Keep self-development and consumer-project audits separate; this distinction
does not make contributor instructions passive prose for item 9.

Three surfaces must never be conflated, and each carries its own evidence grade:

| Surface | What it is | Evidence grade at the checkpoint |
|---------|-----------|-----------------------------------|
| (a) **Self-development** — instructions a session gets while working *on* Busdriver | `~/.claude/CLAUDE.md` + `rules/common/*` + repo `.claude/CLAUDE.md` + the SessionStart orchestrator brief | **observed** — `hooks/hooks.json` registers SessionStart → `load-orchestrator.sh`, which prefers `skills/orchestrator/session-brief.md` over `SKILL.md`; this session's own SessionStart injected that brief |
| (b) **Consumer projects** — what a project loading the plugin actually receives | plugin startup context, skill metadata, on-demand skill bodies | **待核實 (unverified)** — no consumer worktree was inspected in this revision. Record as *unknown*, never as *absent* |
| (c) **External reviewer prompt** — what codex/droid/grok/opencode actually receive | composed by `init-review-loop.sh` → state file → `run-review-loop.sh` | **partial** — the composition path is source-verified and one codex run was observed 2026-09-05; the full composed payload was not retained |

Skill metadata, an on-demand skill body, a script executed without being read, and a reviewer's
composed prompt are different surfaces; do not count every repository file as loaded instructions.
For items 2, 2a, 6 and 10, use a small per-recipient loading map: host/plugin revision, project/CWD,
role/model, instruction source, load trigger, evidence grade. Use redacted traces or content
identifiers and size metadata rather than publishing private prompts or secrets. Only claim context
savings or redundant work from **observed** delivery, reads and execution — not Markdown length or
repeated wording. This is targeted cleanup under existing items, not a new scheduler.

Installed-version drift is itself an instruction-scope fact: the operator machine has plugin
**2.1.14, 2.1.15 and 2.1.16** cached — CORRECTED 2026-09-09 (round-13 finding [16]; UNREVIEWED): an
earlier revision named only the first two. **State the measurement tree once, because this document's credibility
rests on it:** every `file:line` anchor here is verified against the declared checkpoint
`main@727d4652` (**v2.1.15**) with `git show`, not against the working tree. This PR branch is based
on an earlier main and its own tree reads **2.1.14**; the checkpoint is not its ancestor. A gate
observed firing on this host does **NOT identify a version** — CORRECTED 2026-09-09 (round-13 finding
[16]; UNREVIEWED), replacing "a gate observed firing on this host is the *installed* 2.1.15 gate": the
BUILTIN arm sits at the same `:943` in **both** 2.1.15 and 2.1.16, so a firing cannot discriminate them,
and 2.1.16 is the version that actually fired during round 13. Read an observed firing as evidence of
BEHAVIOUR, never of a version number. Where the branch tree and the checkpoint
disagree, the checkpoint is authoritative for every claim in this plan — **and a branch-local
observation MAY still be cited, provided it is REVISION-QUALIFIED** as `<rev>:<path>:<line>` so the tree
it belongs to is explicit; an unqualified anchor is read as the checkpoint's. AMENDED 2026-09-09
(round-13 finding [0]; UNREVIEWED), because the document was already citing both trees and a rule
admitting only one is what let two numberings for a single comparison stand unreconciled. **Pair every
gate-script anchor with its PREDICATE** — the matched pattern, the extraction, the comparison — so a
line shift cannot silently retarget a neighbouring arm. #840 was
written against `main@047a4609`; this revision moves the checkpoint to `main@727d4652`.

## Why this order

Every council voice and witness inverted the audit's cost-first order: a gate set with known
fail-open paths cannot be optimized ("a measurement of theatre"), and policy decisions that say
"decide after data" must schedule their data collection before the changes that would contaminate
the baseline. **That ordering is unchanged and remains approved.**

Items 0, 1 and 5 can proceed in separate worktrees when their edits do not overlap. **`resolve-cli.sh` SLICE OWNERSHIP — ADDED 2026-09-16 post-16 (native run `5e995822` MEDIUM; Photon manual-resume brief `manual-802-838-840-847-20260916.md` #840 section, on the `840-post16-readonly-diagnosis-result.md` roots; source-read at HEAD `34887cb7`, NOTHING EXECUTED; UNREVIEWED): C1 and C2 widened `2a-env`'s footprint to `_portable_timeout`, the reaper and the capture sites in `resolve-cli.sh`, which item 1 also edits, and this rule named only items 0, 1 and 5.** The two own DISJOINT SLICES of that file — item 1 its own, `2a-env` the launcher, reaper and capture sites — so neither is ordered behind the other (CITATION CORRECTED 2026-09-16 root-C; UNREVIEWED. This read "the ordering bar below is unchanged and still forbids scheduling `2a-env` behind item 1", which that bar does not say: the bar places the versioned BASELINE after item 1 and excepts the work the dependency graph puts before `baseline captured`. What actually carries "not behind item 1" is bound (2-CAP)'s CAPTURE OWNERSHIP clause — it changes how the capture sites capture and adds no per-attempt record, those staying item 2-A's and gated on item 1, so `2a-env` still does not wait on item 1 — CITED, NOT RESTATED; the bar itself is unchanged and no ordering is added or removed. The `resolve-cli.sh` slice shared with item 1 is FAMILY 2 of the `2a-env` acceptance-ownership split, defined once at the authoritative SCOPE line in the dependency graph and cited here); whichever LANDS LAST re-runs item 1's settling check on the merged file. The `#803 pin` is a load-time latch and is not a conflict between them; it is simply re-taken with the changed bytes. Capture a
versioned baseline after item 1 before changing prompts, hooks or review policy — except for the work the
dependency graph places before `baseline captured` (the graph is the list; this sentence does not count
it — 2026-09-13, native 2a9a6900 finding [9]; UNREVIEWED), which includes the reviewer-contract delta of
item 2a bound (2-CAP): it lands first and is the version the baseline measures, while observations from before it form a separate historical cohort (Chris `go`,
2026-09-13; UNREVIEWED). Diagnostic logging
may start earlier, but test-polluted or integrity-invalid runs are labelled and excluded from
quality-yield claims. Separate before/after cohorts by code, prompt, policy, harness and routing
revision.
Items 8 and 9 wait for their evidence and the operator decision. Numbers and line references carried
over from 0827 are historical measurements, not current performance targets.

*(An earlier draft added here that "item 2a and item 6 can then proceed while the remaining ledger
sample accumulates". That sentence is **deleted**: it contradicted both the graph's
`baseline captured` rule and item 2a's own blocking edge. The dependency graph is the single ordered
source of truth; this section is a projection of it, not a parallel narrative.)*

> **#840 proposal — REJECTED 2026-09-09 (worker default; the disposition table (`docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-2p-review-yield-protocol.md` § *#840 proposed revisions*) carries the single
> normative statement, including why Chris #2(i) does not reach it).** #840 rewrites this section to say
> integrity-first means closing a *bounded, evidenced tranche* rather than the whole class, so that
> "an adjacent issue does not automatically freeze unrelated measurement, CI or extraction work."
> That is a real loosening of the approved gate and it is exactly the pressure the original ordering
> was chosen to resist. It is recorded in the disposition table (`docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-2p-review-yield-protocol.md` § *#840 proposed revisions*), not applied — and now rejected
> there rather than left pending, on the same no-loosening rule as *Still needs Chris* #3 and #9.
> The approved integrity-first ordering stands unchanged.

## Execution order and acceptance

Status legend — **every status actually used in this table, with its operational meaning; the set is
the bullet list below and the count is derived from it, never written beside it.** An earlier version
defined four and then used three more without definition, and a worker could not tell whether BLOCKED
was a hard stop or a soft preference; a later one said "all seven" while the list already carried
eight — **corrected 2026-09-09 (round 10, propagation pass), by removing the number rather than
updating it**, since a count written next to an enumerated set is the same defect this document
records against "four of the six sites" and item 4's manifest.

- **DONE** — closed, with evidence.
- **IN PROGRESS** — branch activity observed; **assignment unverified** (see *Worker ownership* —
  no signal in this repository establishes assignment, so this never means "a worker owns it").
- **TODO** — schedulable now, subject to the dependency graph. Subject also to the STANDING-FAIL SCOPE (§ *Dependencies*) (2026-09-26; UNREVIEWED).
- **PARTIAL** — named sub-issues remain; do not start new ones without checking *Worker ownership*.
- **BLOCKED** — a **hard stop** on a named predecessor or a named Chris item. Do not start.
- **AUDIT DONE** — analysis complete; **hunks NOT authorised**.
- **SPLIT** — the item is divided into a non-mutating half and a mutating half, **each carrying its
  own status; neither half may be started on the other's authority**. Every SPLIT row must name both
  halves and both gating conditions in its status cell.
- **NEEDS CHRIS** — awaiting an operator decision named in *Still needs Chris*.

The *Progress since the original plan* table copies these values verbatim rather than introducing a
second vocabulary ("not started", "blocked on 2", "audit done, report not on this branch"), so the
two cannot drift. Item text is the 2026-08-27 approved wording; where a #840 amendment was verified
and adopted it is marked **[#840 adopted]** inline.

**GATE-SCRIPT CONTENT LOCK — ONE GLOBAL RULE, DEFINED ONCE HERE, binding on every item in this
table.** `.gate-integrity.lock` pins every file under `hooks/gate-scripts/**` and `scripts/hooks/**`
by SHA-256 (68 pinned paths, verified at `main@727d4652`). **Any commit in this plan that changes a
file under either directory MUST carry the output of `./scripts/gate-integrity.sh --update` in the
SAME reviewed diff.** That is not ordinary CI friction: `.github/workflows/tests.yml:92-108` runs a
dedicated fail-fast `scripts/gate-integrity.sh --check` step and `tests/test-gate-integrity.sh`
asserts the same as its first assertion, so a branch that satisfies every acceptance criterion below
and omits the regen still fails CI. It matters more than that — the lock exists so a gate-body change
cannot reach CI without appearing in the reviewed diff, which is the property this integrity-first
plan is built on. **Items whose named deliverables land inside the locked set** (each cites this rule
rather than restating it) — **RECONCILED against the actual `.gate-integrity.lock` 2026-09-09
(round 10 propagation pass); the regen is required only where a LOCKED path changes, and the
previous wording demanded it in one place where nothing locked is touched:**
- **2a-env** — `pre-commit-gate.sh:955-966` (the bare-hex arm: `^[a-f0-9]{64}$`, then `[ "$MARKER_CONTENT" = "$STAGED_HASH" ]`; `:943-954`, the `^BUILTIN-` arm, is not a 2a-env edit and stays behaviour-identical (2026-09-26; UNREVIEWED)), `post-commit-consume-marker.sh:154+` — the
  **`litmus-passed.local` COMMIT-marker readers only**. Verified present in the lock (68
  entries). Regen REQUIRED **in the `2a-env` commit**. **SPLIT BY NODE 2026-09-12 (native
  c94fb702 finding [7], grok issues[2] `clarity`, conf 0.85; UNREVIEWED): the two
  `pre-pr-gate.sh` arms are NO LONGER listed here.** They were, and bound (i-a) then WITHDREW
  them from the commit-marker cutover on the ground that they read the PR-marker population,
  which (i-a)'s own SCOPE sentence places outside `2a-env`. Both statements were live and this
  bullet did not distinguish the nodes, so a `2a-env` worker was simultaneously told to change
  those locked paths in this commit and not to migrate that population yet. Deleted from this
  line rather than annotated; **the authority is bound (i-a)'s SCOPE sentence, cited not
  restated.**
- **2a convergence-policy / 2i(B) Stage 2** — `pre-pr-gate.sh:291-313` and `:434-448`, plus the
  rest of the gate-side set. **The `PASS-FAST` branch of `:449-468` is IN this lock line
  (2026-09-24; UNREVIEWED): Stage 2 refuses a `PASS-FAST` marker there by FORM (#12), so the Stage 2 regen covers it.** **RANGE CORRECTED 2026-09-13 (native 79ad7ef4 finding [14]
  MEDIUM; UNREVIEWED): this read `:291-313` and `:449-468`.** `verify_pr_artifact_gate` is
  defined at `:291-313`; the arm that CALLS it is the `^[a-f0-9]{64}$` dual-voice deep-review
  branch at `:438-448`, inside the marker block opening at `:434` — so `:434-448` is the only
  range from which `:291-313` is reachable. `:449-468` is the `PASS-(FAST|EXCLUDED)` bypass
  arm, which **deliberately never calls** `verify_pr_artifact_gate`, and it is SPLIT BY ARM —
  CORRECTED 2026-09-13 (native b5bddf50 HIGH, verified at `727d4652`; UNREVIEWED). The
  2026-09-13 range correction above excluded the whole arm because bound (i-a) holds it on
  the PR-marker side of the COMMIT-MARKER cutover; that is a statement about marker FORMAT
  migration, not about completeness. Its `PASS-FAST` branch honours a REVIEW-DERIVED marker
  (writer `run-review-loop.sh:3563`, after a Codex lead PASS) that bound (i)'s no-review
  exclusion list (`:1852`, `:2649`/`:2745`, `:3115`) does not name; Stage 2 refuses it there
  by FORM (#12), not for the `completeness` field `PASS-FAST-<hash>-<epoch>` lacks (2026-09-24; UNREVIEWED). Its `PASS-EXCLUDED` branch honours a
  NO-REVIEW mint (writer `:2649`) and stays under bound (i) only. Verified present in the
  lock. Regen REQUIRED **in the Stage 2 commit**.
- **2i(B) Stage 1** — **NOT in the locked set, corrected here.** Its named deliverables are the
  producer stamp, the schema/`ALLOWED_TOP` admission and the `_ingest` carry-through, which live in
  `skills/litmus/scripts/` and the backstop schema — **verified absent from the lock**, which pins
  only `hooks/gate-scripts/**` and `scripts/hooks/**`. The earlier "Stage 1 and Stage 2 — the same
  set" made a lock regen part of Stage 1's acceptance when Stage 1 changes no locked file; that is a
  false prerequisite, and a settling check nobody can satisfy honestly is worse than none.
- **7** — `scripts/hooks/pre-read-size-advisory.js`, verified present in the lock. Regen REQUIRED.
  **CORRECTED 2026-09-09 (`全部批准`, round-14 finding [10]; UNREVIEWED):** this bullet also named
  `scripts/hooks/run-with-flags.js` as "the denial transport added by rule (1-b)" — a transport rule
  (1-b) itself withdrew, having established that the launcher is a verbatim pass-through and needs no
  change for the denial. It sits in the locked set (`scripts/hooks/**`) all the same, so its regen is
  required **only if 7b modifies that file for some other reason**, and it is not otherwise a
  deliverable of this row.
- **recorder** — its design-gate read of the ACCEPTANCE RECORD lands under `hooks/gate-scripts/`, so regen is REQUIRED in the recorder commit (2026-09-26; UNREVIEWED).
- **Item 0 / #622 arrivals** — every file #622 adds under `hooks/gate-scripts/**` or `scripts/hooks/**`
  is **absent from this checkout's lock**, because it does not exist here yet. At
  `fix/issue-622-merge-commit-gate` that is nine files: `lib/validate-staged-litmus-marker.sh`,
  `lib/merge_pending.py`, `lib/skip_age.py`, and the six gate scripts its installed wrappers exec
  (`merge-reference-transaction-gate.sh`, `merge-pre-commit-gate.sh`, `merge-prepare-commit-msg-gate.sh`,
  `merge-post-commit-consume.sh`, `post-merge-consume-marker.sh`, `pre-merge-commit-gate.sh`) (2026-09-26; UNREVIEWED). The lock
  enumerates from DISK over the whole directory, so they become locked the moment they land, and the
  regen obligation attaches then — **not now**. This is recorded so a worker does not read their
  absence as an exemption.

**Acceptance, stated once for all of them:** `scripts/gate-integrity.sh --check` exits 0 at the
reviewed branch HEAD **for every item whose deliverables include a locked path** — which, per the
list above, excludes 2i(B) Stage 1. Added 2026-09-09 (round 9, finding [9]); none of the three
settling checks named it before.

| # | Item | Class | Status 2026-09-08 | Evidence / settling check |
|---|------|-------|-------------------|---------------------------|
| 0 | Gate integrity — #713/#622 and the integrity epic. Body: `### Item 0` | hard | **PARTIAL** — full status in `### Item 0` | Gate: dependency graph (`0 ──► 2-B`). Settling check: `### Item 0` |
| 1 | Fix `scripts/lib/resolve-cli.sh` under the Bash tool. **Scope it by root cause, not by symptom:** `${BASH_SOURCE[0]}` is empty when the file is sourced from zsh — the file documents this at `:27` and branches on it at `:40-45`, where `_bd_lib_dir` fails to resolve. The known symptom is the grok preflight refusing, so `council.researcher` falls to droid; the fix must cover **every** `${BASH_SOURCE[0]}`-derived path on every entry point that sources this file from an inline `SKILL.md` bash block, not the preflight alone. *(A review round claimed the opencode `council.auditor` lane also fail-closes this way. **待核實** — my own probe returned `opencode` under both bash and zsh, so the specific instance is unconfirmed even though the root cause is real. Enumerate the derived paths rather than trusting either claim.)* Then droid re-auth or delete the fallback rung (closes #556). Isolate test writers from live logs — `~/.claude/homunculus/dispatch-log.jsonl` and `.claude/bypass-log.jsonl`. `skills/dispatch-cli/scripts/dispatch.sh:376` builds `LOG_DIR="$HOME/$STATE_DIR/homunculus"`, so overriding either `HOME` or `BUSDRIVER_STATE_DIR` redirects it — **but not on every lane.** The agy-prose lane (`dispatch.sh:679-697`) deliberately defeats both: it derives the account home from `/usr/bin/id -un` + `eval echo ~user`, refuses an untrusted `$HOME`, and **pins `STATE_DIR` to `.claude`** because `BUSDRIVER_STATE_DIR` is repo-injectable, then recomputes `LOG_DIR`/`LOG_FILE` from the trusted home. **Scope that correctly:** `LOG_DIR` is assigned at exactly two places — `:376-377` (the default, from `$HOME/$STATE_DIR`) and `:697-698` (the agy-prose recompute). The other trusted-`HOME` derivations in this file do **not** move the log path, so a `HOME` override redirects every lane *except* agy-prose. Isolation therefore needs one targeted mechanism for that single lane — plus the separate `bypass-log.jsonl` writers, which have their own resolution. **State the ACTIVATION mechanism, not just the destination.** "A test-only log path not derived from `$HOME`/`$STATE_DIR`" says where the sink goes but not what turns it on, and an *injectable* test override would satisfy the zero-growth check on the production JSONL while reopening the exact exposure `:697` exists to close (the agy-prose lane pins `STATE_DIR` precisely because `BUSDRIVER_STATE_DIR` is repo-injectable and an untrusted `$HOME` is refused). Required: an **isolated test account**, or a sink injected **only by the harness process and unreadable from repository-controlled configuration**. Add a hostile-environment regression that drives a committed `settings.json` `env` block at **both** the JSONL destination and the `failures/` directory, and asserts the pinned path wins. (An earlier draft listed `:970`/`:1503`/`:489`/`:558`/`:1781` as further log pins. They are not; the claim was carried over from a review round without being re-run. Re-grep `LOG_DIR=` before trusting any inventory here, including this one.) **[#840 adopted]** Change the droid fallback rung only by explicit operator configuration, and cover the whole shell suite including `test-droid-escalation.sh`, `test-cli-retry.sh`, `test-dispatch-skipped-status.sh`, `test-pre-impl-deliberation-exempt.sh`, `test-codex-premerge-warn.sh`, `test-gate-untrusted-cd.sh`, `test-relevant-check-status.sh`. | hard | **TODO** | **Evidence (today's bug, not the acceptance):** `bash -c 'source scripts/lib/resolve-cli.sh; resolve_role_cli council.researcher'` → `grok`, `zsh -c '…'` → `droid` — the divergence is the defect (`resolve-cli.sh` documents the empty-`BASH_SOURCE` condition at `:27` and branches on it at `:40-45`). **Settling check (what "fixed" means):** `resolve_role_cli council.researcher` returns `grok` under **both** bash and zsh, and a deliberately unavailable grok still degrades to `droid` under both — so the fix is proven to remove the shell as a variable without removing the fallback. **Precondition, learned during this revision's own review:** that check only discriminates while grok's preflight passes. On 2026-09-08 it did not — `/var/run/docker.sock` was a dangling symlink, so grok's `strict` base refused (#785) and **both** shells returned `droid`, making the shell a non-variable and the check unable to fail for the reason item 1 names. Confirm grok resolves before trusting a `droid` result as a `BASH_SOURCE` diagnosis. **Add TMPDIR writeability to the stated preconditions alongside the grok-preflight one, and require the settling check to report WHICH condition produced a `droid`/`none` result** — the check currently cannot distinguish a shell-compatibility failure from a grok-preflight failure from an environment failure, and #785 already supplied one such confounder. **Do NOT add a mktemp fallback to `resolve-cli.sh`.** A review round proposed one on the theory that a failing `mktemp` aborts sourcing; re-measured at the checkpoint, that mechanism is wrong — `:378-388` already handles it (`_bd803_ensure_staged_lib \|\| :`, commented "a benign staging failure here … must degrade to 'not staged yet', not to a silent abort"), so a `none` result comes from a downstream consumer failing closed **by design**. The surrounding comments at `:23-39` explain at length why a permissive fallback there would be a fail-**OPEN**; the staging path is security-relevant. Adopt the diagnostic point, reject the patch. Per-test `wc -l` diff on BOTH logs over the whole shell suite; zero growth in both before re-measurement. |
| 2 | Review-yield ledger spike — the baseline every policy change in this plan is measured against. Body: `### Item 2` | hard | **SPLIT** — **2-A** TODO after item 1 AND `2a-env`; **2-B** BLOCKED on the 2i NODE AND `protocol-approved` (Chris #2 answered) | Gate: dependency graph (`baseline captured`). Settling check: the 2p file, § *Item 2* |
| 2i | Pre-baseline integrity preconditions — the shared root of the round-5 HIGH findings. Body: `### Item 2i` | hard | **SPLIT** — **(A)** #844: TODO, no predecessor; **(B)** Stage 1 TODO, no predecessor; Stage 2 BLOCKED on `baseline captured` | Gate: dependency graph (the `2i` node). Settling check: the item 8 file, § *Item 2i* |
| 2p | **Review-yield protocol DRAFT.** Binding contract moved verbatim to `docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-2p-review-yield-protocol.md` (2026-09-23 split; UNREVIEWED — the review loop does not read it). It remains part of this plan's requirements. | medium | **TODO** — no predecessor, alongside item 2i. **Not** a milestone and **not** approval | The artifact exists at the named path with every section that item 2p's contract file (`docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-2p-review-yield-protocol.md`) requires populated and **N a concrete number**, the cohort list includes hook-installation state per repository per observation window, and the Chris #2 form fields are present and carry **the values recorded in *Still needs Chris* #2(i) and #2(ii)** — cited from that row, never restated here, so a later amendment there moves one copy. The draft header states that it is non-authorizing and that acceptance is the operator's. **Settled by neither self-declaration nor elapsed time:** this row completes when the draft exists and is complete in that sense, which is a strictly weaker claim than `protocol-approved` and must never be reported as it. No observation may be collected on the strength of this row. |
| 2a | Litmus convergence contract — one authoritative executable prompt source. Body: `### Item 2a` | hard; split around the baseline | **SPLIT** — **`2a-env`** TODO after the 2i NODE (2i(A) plus 2i(B) Stage 1; 2i(B) Stage 2 follows `baseline captured` and is not a predecessor of `2a-env`), its (i-a)/(i-b) commit also after #622 merged; **convergence-policy half** BLOCKED on `baseline captured`; **`2a-env-form`** TODO, gated by neither 2i nor #622 (PRE-ACCEPTANCE DELIVERY) (2026-09-26; UNREVIEWED) | Gate: dependency graph (the `2a-env` and `2a-env-form` nodes; `recorder` is a tooling node with no item row, its status given by its graph entry). Settling check: the (i-a) file, § *Item 2a* |
| 3 | Disable both `continuous-learning-v2` `observe.sh` hooks (`hooks.json` Pre+Post `*`; observer.enabled=false; instincts last written 2026-03-31) AND prune non-contained, side-effect-free ECC hooks (`ECC_HOOK_PROFILE` unset → 30/32 flag-hooks on; contained ones run under `sanitized-node.sh`, which strips `ECC_DISABLED_HOOKS` by design) — together, ONE before/after per-Bash-call latency measurement. Archive `~/.claude/homunculus/` except `dispatch-log.jsonl` — **and except `failures/`**: `dispatch.sh:1092` writes failed-run output there and the dispatch log's `output_file` entries point into it, so archiving it breaks the log's own references. (The instincts concern does *not* apply: the active store is `~/.local/share/ecc-homunculus`, so archiving the legacy directory removes no delivered context.) **[#840 adopted]** Confirm each pruned hook's consumers first, and archive only after item 1. Amends ADR 0048 D1, ADR 0046. | hard | **SPLIT** — inventory/consumer-confirmation half **TODO** after item 1; mutating half (disabling the hooks, archiving `~/.claude/homunculus/`) **BLOCKED on `baseline captured`** | Paired per-tool-call measurements on the same workload with installed versions recorded; gate outcomes and required artifacts unchanged. The 0827 reference — 14 PreToolUse procs, ~1.5 s CPU, ~300 ms wall per Bash call — is a historical baseline, not a current one. |
| 4 | Retire the file-level sync **mechanism** — `~/.claude/scripts/sync-upstream.sh` and its cache — but **keep `.upstream-sources.json`** — and **distinguish two things an earlier draft collapsed into the word "frozen", which made this row and item 13/M9 impossible to satisfy together.** (i) A **frozen historical snapshot** — a *copy*, used for `THIRD_PARTY_NOTICES` provenance; that is what "frozen" legitimately means here. (ii) The **live tracked inventory**, which must continue to record deletions and additions. `tests/test-upstream-manifest.sh:104-105` enforces "invariant 6 — tracked path must exist on disk, no exceptions", failing with "stale entry - remove it in the same change that deleted the file". So a literally frozen manifest plus a retained test forbids the very edit that would keep them consistent: **corrected 2026-09-09 (round 9, finding [10]) — the premise was stale and is withdrawn: item 13/M9 does NOT remove the five `commands/multi-*.md` files.** M9 decided the opposite in this same document ("RETAINED, decided 2026-09-08 … pending consumer evidence and a separate retirement decision"), and item 4's manifest rule settles only HOW they would be removed, never WHETHER. If a future retirement decision ever removes them (manifest entries at `:428-455`), the same-commit rule below applies then; it is a hypothetical, not a pending instance, so **only `skills/litmus/prompt_template.txt` (row `:1745`) remains** on this list. **Rule: any content change updates the active manifest and the shipped notices in the same commit** — which is exactly what invariant 6's own failure message already demands. Keep BOTH `tests/test-upstream-manifest.sh` and `tests/test-provenance-guard.sh` (it SKIPs when the manifest is absent, `:175`, so removing the file would silently disable it). **Precondition (Codex, #775): the complete transitive consumer inventory of every surviving `sync` entry — `live:<shortest chain from a root>`, `unreferenced`, or `dead` — with zero `?` rows, before the copier is retired.** Reachability is the transitive closure from `hooks/hooks.json`, every `skills/*/SKILL.md`, `commands/*.md`, `agents/*.md`, `.github/workflows/*` and `package.json` scripts. Also update `tests/test-provenance-guard.sh:6,184`, whose remediation text still names `sync-upstream.sh`. **The same-commit manifest rule above is scoped to ALL tracked paths — `sync`, `custom` and `local` alike — not only `sync` rows**, because invariant 6 at `test-upstream-manifest.sh:104-105` does not discriminate by status. **THE PENDING-INSTANCE MANIFEST, ENUMERATED ONCE HERE — this list IS the deliverable, and the count is derived from it, never written alongside it (corrected 2026-09-09, round 10, finding [5]).** The cell previously carried three statements that disagreed — a sentence implying only `prompt_template.txt` remained, a count of "two", and an enumeration of six paths — so the row that defines the acceptance set was the one place a worker could not derive it from. **Entries — the count is DERIVED from this list and never written beside it:**<br>  1. **`skills/litmus/prompt_template.txt`** — manifest row `:1745`, status `local`; item 2a's orphan. **This is the only PENDING instance.**<br>**The five `commands/multi-*.md` rows (manifest rows `:428-455`) are NOT entries on this list.** Item 13/M9 decided 2026-09-08 that the five commands and their prerequisite notices **stay UNCHANGED**, so they are tracked inventory, not a pending retirement. **CORRECTED 2026-09-09 (round 11):** a round-10 revision restored them as a second entry, which contradicted M9 inside this same document and left a worker unable to close the enumerated list without deleting files M9 forbids deleting. They are kept here only as the **manifest-rule precedent**: if a future reviewed decision ever retires one of them, the same-commit rule above governs it exactly as it governs the template. **An entry leaves this list two ways** — dispositioned in a reviewed diff that also removes its manifest row, OR closed by a reviewed RETENTION disposition, which resolves the entry without deleting anything. The transitive consumer inventory stays scoped to `sync` rows, where it belongs. Generate `THIRD_PARTY_NOTICES` from files actually shipped. Amends ADR 0048 D6 + ADR 0014. | hard | **TODO** — precondition scope **RESOLVED 2026-09-09** (worker default, *Still needs Chris* #3): the inventory gates **retirement**, not pruning alone | Precondition artifact: the inventory (`.upstream-sources.json` `sync` rows, **regenerated** rather than assuming 0827's count of 235), each joined to its consumer and carrying a disposition; zero `?` rows before retirement. Disconfirming evidence = an upstream fix to a surviving live `sync` entry that the on-demand digest would not surface. |
| 5 | CI: make `scripts/ci/run-shell-tests.sh` print per-test durations, then shard into a duration-balanced matrix with ONE aggregate check still named `shell-tests`, `if: always()`, failing on any failed / cancelled / missing shard; update `.github/required-checks.lock` — **and mind its `matrix_value` semantics** (restored from the 0827 wording): a matrix job reports as `<base> (<matrix_value>)`, so each shard needs its own lock entry while the aggregate keeps the bare key `shell-tests` that sits in `required` today. Sharding without that leaves the shard checks classified as neither required nor advisory, which the lock's `_doc` surface (e) exists to catch. Folds #632. **[#840 adopted]** Require dependencies for supported portability cases (**including zsh — #821 is CLOSED and `main`'s `tests.yml` installs zsh; ticket status is Progress row 5's; what survives is the residual: sub-case skip exposure, dependency-latency separation, sharding and partition completeness** (2026-09-26; UNREVIEWED)) and expose sub-case skips, not only a suite's final line. Address dependency-install latency separately from real lint/test failures (**#829**). | hard; parallel with non-overlapping integrity work | **TODO** | Lock lists `shell-tests` as required; aggregate reports on every PR including skipped shards; an unexpectedly skipped required shard cannot count as success. Measure actual durations rather than reusing the historical 14.9-minute baseline.<br><br>**Partition completeness must be reconciled against the live glob on EVERY run, not compared once at cutover.** `run-shell-tests.sh` discovers its suite by glob at every invocation — `shopt -s nullglob` then `tests=(tests/test-*.sh)` at `:329-330`, with only an empty-set guard at `:331-334`. A one-time "same required test inventory before/after" check plus per-shard outcomes cannot catch the durable failure mode: **a duration-balanced static partition silently omits a test added after the partition was computed, every configured shard succeeds, and the aggregate reports green forever.** Require the aggregate job to reconcile the discovered test list against per-shard completion records and **fail on any test that is unassigned, assigned twice, or missing a completion record**. Add one regression for each of those three cases. |
| 6 | Extract pr-grind's executable dispatcher mechanics into scripts. **Re-anchored 2026-09-08 — the 0827 range was wrong:** in the 1432-line, 119,963-byte `skills/pr-grind/SKILL.md`, `## The Dispatcher Loop` spans **103–895** and `## Step Details` begins at **`:897`** (running to the next heading at **`:1303`**, `## Worked Example: Out-of-Scope-Acknowledged Flow` — re-measured 2026-09-08, round 8 (M21); the earlier `:1302` was off by one). **The anchors were right; the "not code" claim was wrong, and is corrected here 2026-09-08.** Verified at the checkpoint: 103–895 carries the loop's **live dispatcher invocations**, and therefore its control flow. The extraction inventory is those invocations PLUS the bash under `## Step Details` — eight sites: `grind-pr-commits.sh` (`:214`), `pr-grind-write-block-preflight.sh` (`:252`), `dispatcher-commit-block.sh` (invocation `:351`; routing `:320-331`), `codex-nudge-if-expected.sh` (`:626`), `codex-retrigger.sh` (`:679-680`), `advisory-downgrade-optin.sh` (`:753`), `github-server-now.sh` (`:811`) and `advisory-stale-downgrade.sh` (`:829`). An implementer who extracts only the Step-Details range leaves round sequencing, commit-block routing, the write-block preflight, the Codex nudge/retrigger logic and the ADR 0012 advisory downgrade behind in Markdown — the opposite of this item's goal. The earlier cell also narrowed Step Details to "903–1181 (plus 1209–1211)", which is smaller than the section. **The correction is that the invocations inside the flowchart are code, not decoration.** The ASCII flowchart and the doctrine prose stay in `SKILL.md` as the contract the parity tests are written against, which is what this row already intended. doctrine + issue-numbered caveats stay; parity tests assert semantic/output contracts (shell state, cancellation, retries, partial output), not byte-for-byte. Later: blueprint-review (91 KB), council (67 KB), litmus (58 KB). #547/#662 stay separate reliability work. **[#840 adopted]** Keep the existing stage/role mapping and `busdriver.json` resolution; refine the EXISTING session brief rather than adding another; keep moved references reachable at the point of use. **Sequencing with item 13 — the calm-rewrite rule is deleted; `13-eval ──► 6` remains a blocking edge (corrected 2026-09-08; relabelled 2026-09-25; UNREVIEWED).** The former rule ("do the calm rewrite BEFORE extracting, so parity tests pin the calm text") assumed item 13 rewrites text item 6 extracts. Re-measured, it does not — and the check is now stated over the WHOLE extraction inventory rather than a sub-range, **corrected 2026-09-08 (round 8, M16)**: the earlier wording scoped it to `SKILL.md` 897-1211, which is neither the section (**897–1302**) nor the inventory, and the re-add condition inherited that wrong range. Re-run at the checkpoint over the full inventory — the live dispatcher invocations at **103–895** PLUS `## Step Details` at **897–1302** — the audit at `dc56aa03` (`docs/audits/2026-09-05-prompt-audit.md`) proposes **no hunk against `skills/pr-grind/SKILL.md` at all**: its H4 rewrites three stale `<STATE_DIR>` copies (`skills/orchestrator/session-brief.md:46`, `skills/blueprint-review/SKILL.md:599`, `skills/orchestrator/references/gate-recovery.md:8`) and none of them is this file, while the audit's only mention of it is keep-list line 130, which explicitly CLEARS the block item 6 cares about. This file's own `<STATE_DIR>` occurrences — `:755-756`, `:807`, `:828`, `:831`, `:885`, **all inside 103–895** — are occurrences of the H4 pattern that H4 does **not** propose to change; they are a measurement list, not a gate condition, and they are recorded here so the next audit re-run is measured against the named sites rather than re-derived. **So the overlap is zero on the correctly scoped check, not merely on the narrow one.** A later audit re-run that proposes any hunk inside **103–895 OR 897–1302** names those hunks here; it is an EXTRA measurement, not a release of the existing gate. Whatever it finds, item 6 does not extract until `baseline captured` is reached AND the item-13 pre-extraction evaluation is recorded, as the graph's `13-eval ──► 6` edge states (sentence corrected 2026-09-24; UNREVIEWED). | hard; incremental | **BLOCKED on `baseline captured` AND the recorded item-13 pre-extraction evaluation** — both, as the graph node states; the graph is the single ordered source of truth and this cell cites it rather than restating a second gate. (**"and on that alone" DELETED 2026-09-10, round-17 finding [5]; UNREVIEWED** — round-16 [4] struck the same word in the graph body and this status cell kept it, which is the contradiction.) | Parity suite diff: semantic/output parity for shell state, cancellation, retries, partial output, resolved roles and gate decisions. No new free-form dispatch authority. Measure per-recipient context in consumer projects before/after; trimming Busdriver contributor docs alone is not evidence of plugin-wide savings. |
| 7 | agy-read gate in the plugin — PreToolUse read threshold, its four numbered rules and the canonical kind table. Body: `### Item 7` | hard | **SPLIT** — **7a-i** TODO after item 1; **7b** BLOCKED on `baseline captured` AND item 3's paired measurement AND 7a-i | Gate: dependency graph (`baseline captured`). Settling check: the item 7 file, § *Item 7* |
| 8 | Litmus commit mode — keep `medium` blocking; stratified sample with predeclared thresholds. Body: `### Item 8` | needs Chris after data (*Still needs Chris* #18) | **SPLIT** — **analysis half** TODO after 2-B; **mutating half** BLOCKED on 2-B AND `baseline captured` AND *Still needs Chris* #18 | Gate: dependency graph (`baseline captured` AND *Still needs Chris* #18). Settling check: the item 8 file, § *Item 8* |
| 9 | Docs-only path-class triage (Mythos): docs-only diffs skip litmus `medium` and get one pr-grind round; must keep every lock-required check reporting (`pr-grind/SKILL.md:24`). Evaluate against #774 (+20/−2, 6.4 h, 13 reviews). ADR 0044 already carves docs-only commits out of Gate 1. **[#840 adopted in principle]** The eligible class is *genuinely passive prose*, not "any Markdown": `CLAUDE.md`, SKILL/agent instructions, executable examples and any document changing trust, routing, gates or acceptance criteria are behaviour-affecting even when Markdown. **The exact class boundary was NEEDS CHRIS #4 — RESOLVED 2026-09-09 (worker default): a fail-closed allowlist that starts EMPTY, additions only in a reviewed diff carrying a passivity fixture, with `CLAUDE.md`, `skills/**`, `agents/*.md`, `commands/*.md`, `hooks/**`, `docs/adr/**` and anything changing trust/routing/gates/acceptance permanently ineligible. Stated once in *Still needs Chris* #4; this cell cites it.** | exploratory; policy decision resolved as a worker default | **SPLIT** — the classifier and its fixtures are **TODO**: **Chris #4** settles the class boundary only; the classifier half is TODO under the dependency graph, and its landing is held by the STANDING-FAIL SCOPE (2026-09-26; UNREVIEWED); the **POLICY change** (litmus `medium` blocking and the pr-grind round budget for a whole path class) is **BLOCKED on `baseline captured`** (Chris #4 resolved), and the WAIVER in it also needs the separate recorded operator disposition at *Still needs Chris* #19, which is OPEN (#19 cited in this cell 2026-09-24; UNREVIEWED). *(Corrected 2026-09-08: this cell read a flat **NEEDS CHRIS**, which the status legend forbids for a split row — "every SPLIT row must name both halves and both gating conditions" — and which, per the graph's own note, would have authorized starting the policy change the moment the class boundary was answered, with no baseline in existence.)* | Before/after on the next eligible docs PR — **but one future PR against #774 is an anecdote, not a measurement**: diff size, reviewer routing (which items 1 and 13 both change), CI queue latency and the prompt revision all move between them. Either accumulate several eligible PRs through the item-2 ledger with the cohort dimensions recorded, or state plainly that the pilot is a judgement call and not evidence. Classifier fixtures include passive prose *and* operational Markdown. Every lock-required check keeps reporting. Reaching the round budget with a blocker stops and escalates; it does not authorize merge. |
| 10 | pi-replacement amendment: Codex retained for review + `/codex:rescue` + imagegen; Slice 6 keeps `pi-goal-handover`, drops `pi-rescue`. **Guarded 6-lite**: launcher runs `pi --model cursor/<id> -e <cursor-extension> --cursor-sandbox` in a git worktree, dispatcher commits from outside, and REFUSES unless worktree clean ∧ base branch operator-authored ∧ no fork PR / untrusted patch. **The predicate is not yet a design.** "operator-authored" and "untrusted patch" have no evidence definition and no stated check point, and the repo's own doctrine says a gate must not read a value the gated party controls — a committer name and a branch ref both fail that test. Before any 6-lite code, name for each conjunct: what signal establishes it, who can write that signal, and at what moment it is evaluated. Absent that, this row is a requirement, not a mechanism. Cursor's sandbox is SDK opt-in, not a kernel boundary. ADR records this as deliberately reopening the 13-round sequencing (ADR 0006 "trusted dispatcher" + ADR 0026 dispatcher residual). **[#840 proposes a precondition — RESOLVED 2026-09-09, worker default, adopted for MUTATING slices only]** #840 would require inventorying the Claude Code / OMP / Cursor-agent adapters and their installed versions *before* continuing any pi slice. That collides with the in-flight `pi-cursor-sdk-sandbox-eval` worktree. **Sequencing RESOLVED 2026-09-09 (worker default, *Still needs Chris* #5): the inventory gates every MUTATING pi slice; the eval continues as evidence-gathering only, since it changes no runtime file, and any mutating output it proposes is a slice that waits. Stated once in that row; this cell cites it.** | security-class | **SPLIT** — **10-eval** (the non-mutating half: `pi-cursor-sdk-sandbox-eval`) is **IN PROGRESS**, gated on nothing, because it changes no runtime file. **10-slice** (every mutating pi slice) is **BLOCKED on the host-adapter inventory** — and, for 6-lite specifically, additionally on the predicate design this row demands (signal, writer, evaluation point per conjunct), which is unsettled and is NOT settled by the sequencing resolution. Neither half may be started on the other's authority | Test: fork-base worktree is refused. Per-host evidence for the same task/plan identity, resolved role/fallback, stale/missing review artifact, cancellation/resume and final authorization. No claim of host parity from loading SKILL text alone. Do not treat sandbox naming as proof of confinement. |
| 11 | Issue triage. Close after a probe (not a one-liner) — #516, #539, #540, #644, #661, #550, #572, #592, #560, #583, #556 (after item 1). Epics: classifier precision #639 #654 #724 #767 #771 #768 #769; dispatch/council reliability #547 #558 #603 #662. Low: #712, #586, #508, #568. **[#840 adopted]** Skip work already completed with evidence. **The triage list in both prior versions is stale** — see *New issues since 2026-08-27* below; re-bucket before starting. | ongoing | **TODO** | One settling probe or existing verified regression per closure, recorded with the version it was run against. Out-of-scope findings get a bounded disposition rather than silently expanding the active PR or being dismissed to obtain PASS. |
| 12 | Adversarial end-to-end pipeline-integrity suite (hostile committed env, shell expansion, merge commands, diff drivers, launcher substitution, missing CI shards). **[#840 adopted — strictly stronger]** The minimum regression for each item-0 fix is part of **that fix's acceptance**, not deferred behind the whole roadmap; the broader families expand from there. **State the disposition per in-flight item-0 branch, or this strengthened rule binds only unowned future work.** *Worker ownership* says do not re-plan #622 (item 0) and #780/#781 (item-12 successors) — all active (29, 36 and 36 commits ahead) — and the plan never said whether they must absorb the item-12 matrix (hostile committed env, git aliases, `GIT_*` redirection via a settings `env` block, `pull --ff-only`, sequencer `--continue`) **before merge**, or are grandfathered under their own tests. One explicit sentence each is required: either "before merge, this branch must include the item-12 minimum cases for the invariant it claims to close", or "grandfathered; item-12 cases land as follow-up issue #NNN", naming the issue. **The three sentences, supplied here rather than demanded — an earlier revision stated the requirement in imperative form and then left every row blank.** Read from `git show fix/issue-622-merge-commit-gate:docs/adr/0051-native-git-merge-commit-gate.md` without checking the branch out.<br>— **`fix/issue-622-merge-commit-gate` (29 ahead): before merge, this branch must include the item-12 minimum cases for the invariant it claims to close.** The enumeration is executable now and turns on ADR 0051's central choice: it enforces on the **effect** — refusing a branch-tip update to a merge commit unless a pending claim binds that exact `HEAD`, staged tree and `MERGE_HEAD` set — at git's own `reference-transaction` `prepared` phase, *not* on command spelling. That covers the command-shape family **whose effect is a merge commit** — conflict-free `git merge`, aliases via `-c alias.x`, last-wins option overrides, and compound commands — because each must ultimately move a ref to a MULTI-PARENT commit. **An earlier revision of this sentence said it "structurally covers the whole command-shape family the historical handover enumerates". That is false and is corrected here**, on the same evidence item 0 now carries: `fix/issue-622-merge-commit-gate:hooks/gate-scripts/merge-reference-transaction-gate.sh:154-156` exits 0 for every single-parent successor, and ADR 0051 (`fix/issue-622-merge-commit-gate:docs/adr/0051-native-git-merge-commit-gate.md:73-90`) (widened from `:73-88`, round 8 M21) allows `git am` outright and takes cherry-pick/revert only in their `-n` two-step form. It does **NOT cover**: (a) **fast-forward / `pull --ff-only`** — stated precisely, because "the merge-commit predicate never fires" overstated it: a single-commit FF with `FP == OLD` exits 0 at `:154-156`, and a multi-commit FF is adjudicated by the witnessed-FF rule at `:474-489`. Either way no merge commit is created, so the governing invariant is ADR 0050's ref-ff gate, a separate control (#779/#780), not this branch; (b) **hook-location redirection** via `GIT_DIR`/`GIT_COMMON_DIR`, which relocates the operation into a repository whose hooks are not this one's — an installation residual — and via `core.hooksPath` set for one command by `git -c core.hooksPath=…` or by `GIT_CONFIG_COUNT` with `GIT_CONFIG_KEY_<n>`/`GIT_CONFIG_VALUE_<n>`, which moves the hooks directory without moving the git dir. **That config spelling is REFUSED, never accepted (2026-09-25; UNREVIEWED):** `scripts/hooks/block-no-verify.js` already refuses `git -c core.hooksPath=` before the command runs, and item 12 extends the same refusal to the `GIT_CONFIG_COUNT` family, with one refusal fixture per spelling. **`GIT_INDEX_FILE` and `GIT_WORK_TREE` are NOT in this bucket, and grouping them here was wrong (corrected 2026-09-08).** Only `GIT_DIR`/`GIT_COMMON_DIR` change the git directory and therefore the hooks directory; `GIT_INDEX_FILE` selects an alternate index **within the same repository**, and `GIT_WORK_TREE` changes the working tree without selecting a different git dir — neither moves the hooks. The distinction is load-bearing for this plan specifically: alternate-index binding is part of the claimed authorization invariant (no invocation may replace the index or tree the marker was bound to), so **`GIT_INDEX_FILE` and `GIT_WORK_TREE` belong INSIDE the gate's own predicate as index/tree-binding cases the gate must either bind to or refuse**, not outside it as an installation residual. Cite git's environment-variables documentation and `githooks`' location rules in the test so a later reader does not re-collapse them; (c) **sequencer/`rebase`/`am` paths that produce non-merge commits**, outside the predicate by construction; and (d) **single-parent commit CREATION by an ordinary one-step command** — plain `git cherry-pick <sha>`, plain `git revert <sha>`, `git am`, and a sequencer `--continue` of either. (d) is listed separately from (c) because the exclusion list previously named only "sequencer/rebase/am paths" and so read as if the ordinary one-step spellings were covered; they are not, and they produce exactly the unreviewed commit item 0 names as the live defect. Bucket (d) to **#783**. Those four are OUTSIDE the invariant this branch closes, so it does not owe them: (a) and (d) are the named follow-ups above, (c) and the `GIT_DIR`/`GIT_COMMON_DIR` part of (b) are recorded exclusions, and (b)'s `core.hooksPath` spellings are refused as stated there. What it owes before merge is the covered family above plus the `GIT_INDEX_FILE`/`GIT_WORK_TREE` binding cases and the `core.hooksPath` refusal fixtures named in (b).<br>— **`fix/issue-780-zero-old-oid` (36 ahead)** and **`fix/issue-781-protected-ref-create` (36 ahead): NO ITEM-12 PRE-MERGE OBLIGATION ON THIS PLAN'S AUTHORITY. INSTRUCTION NOW ACTUALLY DELETED 2026-09-13 (native 79ad7ef4 finding [8] MEDIUM; UNREVIEWED).** What stood here was the live instruction *"before merge, each branch must include the item-12 minimum cases for the invariant IT claims to close — CONDITIONAL on *Still needs Chris* #2, per the graph"*, and the cell went on to declare that instruction "DELETED, NOT ANNOTATED" while leaving it in place, AHEAD of its own retraction in reading order — the precise failure the cell then states as a principle: *"Telling a reader that an instruction is withdrawn does not withdraw the instruction."* The sentence is removed rather than annotated, which is what the retraction below already required; the retraction below is unchanged and is the live disposition. Two corrections follow, 2026-09-08, and neither decides anything. **(i) The enumeration is not supplied and must not be inferred from #622's.** #622's list is the merge-commit predicate's coverage and its exclusions; #780 closes a zero-old-oid force-update invariant and #781 a protected-ref-creation invariant — **different invariants, so the historical handover's command-shape list is #622's matrix, not theirs**. A worker on either branch cannot read "hostile committed env, git aliases, `GIT_*` redirection, `pull --ff-only`, sequencer `--continue`" off the #622 row and know what they owe. Supplying their enumerations would **re-plan sibling branches this plan is explicitly told not to re-plan** (see *Worker ownership*), so it is out of scope for a plan-only revision and is named as owed rather than guessed. **(ii) #780 AND #781 CARRY NO ITEM-12 PRE-MERGE OBLIGATION ON THIS PLAN'S AUTHORITY.** Stated affirmatively and once. Chris #2(ii) answered **the original seven only**, so the graph's `descendants ──► 12` edge **DOES NOT FIRE**, and their matrix obligations follow the **item-12 SUCCESSOR route** instead: the 2p graph's `#780 #781 ──► 12-successor` entry (2026-09-26; UNREVIEWED). **THE PRIOR "before merge" INSTRUCTION AND ITS "CONDITIONAL" FRAMING ARE DELETED, NOT ANNOTATED — CORRECTED 2026-09-12 (native c94fb702 finding [9], grok issues[4] `clarity`, conf 0.8; UNREVIEWED).** The earlier text opened with a live must-include-before-merge instruction conditioned on Chris #2, then several sentences later told the reader the condition was "no longer a live condition". **Telling a reader that an instruction is withdrawn does not withdraw the instruction** — a worker on `fix/issue-780-zero-old-oid` or `fix/issue-781-protected-ref-create` reading in order implements it before reaching the retraction. That is the dual-source pattern the Progress table's verbatim-copy rule exists to prevent, occurring inside one cell, so the fix is deletion of the withdrawn sentence rather than another annotation layered on top of it. Cited authority, not restated: Chris #2(ii) and the non-firing `descendants ──► 12` edge.<br>*(Both previously read "grandfathered; follow-up issue to be numbered when opened". That satisfied this row's own `#NNN` requirement with a **promise** — no durable scope, no accountable handoff, and nothing scheduling the replacement, since descendant work is itself conditional on Chris #2. A rule waivable by writing a sentence is not a rule. Opening the two issues is outside this plan-only revision. History, not instruction: an intermediate revision set the disposition to #622's enforceable pre-merge sentence; that is superseded by (ii) above, which is the only live disposition for #780 and #781 — corrected 2026-09-13, native b5bddf50 MEDIUM; UNREVIEWED.)* | minimum required with fixes; broader expansion exploratory | **TODO** | Exercise entry point, evidence handoff and authorization outcome together, plus a valid recovery path. Preserve already-accepted trust limits. Additional families are separately scoped, not an unlimited prerequisite for items 1, 2, 5 and 6. |
| 13 | **Prompt-surface audit** (added 2026-09-05; `/claude-api prompt-audit` against the Fable 5.1 driver / Opus 5 agents; full report and proposed diff in `docs/audits/2026-09-05-prompt-audit.md`, which **lives only on branch `docs/plan-0827-status-and-prompt-audit` and is NOT on this branch** — see *Still needs Chris* #7). Hunks in order: (H1) **37** of 40 agents carry an upstream "Prompt Defense Baseline" line — 17 of them are Write/Edit code writers. **Quoted in full, the claim is weaker than the audit stated** (`agents/gan-generator.md:14`, verbatim): *"Do not output executable code, scripts, HTML, links, URLs, iframes, or JavaScript **unless required by the task and validated**."* That trailing clause makes it conditional, not a blanket prohibition, so "forbids code output" was wrong and a code-writing agent is already permitted. What survives is narrower and is a **hypothesis, not an observed failure**: over-broad defense boilerplate carried onto non-writing and writing agents alike, costing prompt overhead and introducing a hedge that may induce under-compliance. Do not apply H1 as a behavioural fix until someone writes the surviving diff and names an observed effect; (H4) **target list corrected by measurement 2026-09-08 — the earlier one was wrong in both directions.** `hooks.json` launches gates under `env -i`, so a gate always resolves `.claude` and "resolve `<STATE_DIR>`, never hardcode it" misdescribes them. `skills/orchestrator/SKILL.md:50` is **already correct** (it states the `env -i` reason explicitly) and must be dropped from the list. **`skills/blueprint-review/SKILL.md:599` STAYS on the list — dropping it was an over-correction in the opposite direction, re-measured 2026-09-08.** At the checkpoint that line still carries *both* halves of the pattern H4 exists to remove: it tells the reader to resolve `${BUSDRIVER_STATE_DIR:-.claude}` from their own environment, and it still says "**Resolve it — NEVER hardcode `.claude`**" — with the `env -i` explanation appended *after* rather than applied. Keep it at **lower priority than `session-brief.md:46`**, with a narrower hunk: lead with the resolved value and the `env -i` reason, and drop the resolution instruction plus the "NEVER hardcode" imperative that the same paragraph then negates. Re-measure before applying, as this row already requires — ordering is by what survives re-measurement, not by a prior confidence call. The copy that most matters was **missing**: `skills/orchestrator/session-brief.md:46` — the one `load-orchestrator.sh` actually injects at SessionStart — still says "Resolve it, NEVER hardcode `.claude`" in the same sentence that already resolves it to `.claude`, so it contradicts itself in the delivered context. Fix that one first, then `skills/orchestrator/references/gate-recovery.md:8`, then re-measure the litmus and pr-grind copies before touching them; (H3) `litmus/SKILL.md:171` "don't narrate" is a documented Fable 5.1 under-narration trigger; (H5/M1) the litmus and blueprint-review `<EXTREMELY-IMPORTANT>` blocks and the twice-told #368 timeout story rewrite to current-state rules at normal volume; (M4) `tdd-workflow` and `test-driven-development` disagree on mocking; (M8) CLAUDE.md bullets 88/90 move their ADR archaeology into the ADRs; (M9) the five `commands/multi-*.md` require a `ccg-workflow` runtime absent on this host — **RETAINED, decided 2026-09-08: the five commands and their prerequisite notices stay UNCHANGED, pending consumer evidence and a separate retirement decision.** Host-local absence is not evidence of obsolescence. Verified at the checkpoint: line 9 of every one of `commands/multi-{backend,execute,frontend,plan,workflow}.md` already carries an identical notice naming the runtime and its `npx ccg-workflow` provisioning step, so absence on this host is the condition the shipped files already document, not a defect they failed to anticipate. Retiring five shipped consumer-facing commands is a **product decision requiring its own evidence and a deprecation disposition**; this item's own instruction-scope table grades consumer projects 待核實/unverified, which forbids inferring from a repository fact that no consumer uses them. Item 4's manifest-consistency rule (`.upstream-sources.json:428-455`, all five status `sync`) settles only HOW they would be removed, never WHETHER. **That retirement decision is deferred and remains unowned by this item — no *Still needs Chris* row is added for it here.** Complements item 6. Item 6 stays gated on `baseline captured` AND the recorded item-13 pre-extraction evaluation, as the graph's `13-eval ──► 6` edge states; the measurement that no hunk touches the executable range item 6 extracts is an input to that evaluation, not a release of the gate (2026-09-24; UNREVIEWED). **Absent from #840; the item is restored here, and the report file lands by single-path checkout of `dc56aa03 -- docs/audits/2026-09-05-prompt-audit.md` per *Still needs Chris* #7 (RESOLVED). The hunk half stays BLOCKED on that FILE LANDING AND `baseline captured` — not on a decision. (CORRECTED 2026-09-10, round-16 finding [8]; Photon technical decision, UNREVIEWED — this description had contradicted its own status cell in the same row.)** | hard; split around the baseline | **SPLIT — analysis DONE; hunk application BLOCKED on `baseline captured` AND *Still needs Chris* #7 — #7 RESOLVED 2026-09-09 (worker default: single-path checkout of the audit file), so the hunk half's live gates are the FILE LANDING on this branch AND `baseline captured`; the decision is no longer one of them, and neither gate is met.** The graph splits items 3, 7 and 13 alike around the milestone and names "rewriting prompt text" as a mutating half, so item 13's hunk application carries **both** conditions — an earlier revision named only Chris #7 and so read as authorizing the rewrite the moment the report arrived. The analysis half is complete (no hunks applied, none authorised); the row's own acceptance also cannot be executed while the report is off-branch | Each hunk is one commit; `tests/` grep for the removed strings before each; re-run the audit after item 6. **Those are reference-hygiene checks and must be labelled as such — they are NOT evidence of behavioural parity.** This document argues at length elsewhere that SKILL and agent Markdown is behaviour-affecting (it is the entire basis of item 9's narrowed docs-only class), and H3/H5/M1 rewrite narration rules, `<EXTREMELY-IMPORTANT>` blocks and timeout guidance **inside skills that drive stage execution, reviewer waiting and recovery**. Nothing in a grep can detect a regression in those paths. Add a small **before/after task set on the named driver and harness with observable expectations**: review completion, timeout recovery, routing decisions and narration volume. Align these observables with item 6's parity-suite contract so the two use the same ones. **Re-verify every anchor in the report before applying a hunk** — both H1 and H4 were found overstated when re-measured on 2026-09-08, which is reason to distrust the ordering rationale, not just the two anchors: order the hunks by what survives re-measurement, not by the audit's own confidence. |

**RESTRUCTURED 2026-09-12 (native finding [15] MEDIUM; UNREVIEWED).** The six oversized rows — **0, 2, 2i, 2a, 7, 8** — carry their bodies ONCE, and each table row above is a one-line index. Only `### Item 0` stays below; since 2026-09-24 the other five bodies are in the child files the header's SECOND MOVE names, and each index status cell names both halves and gates. The other eleven rows stay in the table in full. **No character-limit rule is created here**, and the LOW [14] history-appendix work is neither required nor done.

### Item 0

**Gate integrity**: #713 (`SHELLOPTS=noexec` in a committed `settings.json` env block silences the outer shell of every contained registration — ADR 0016:210-228 names it as an out-of-scope class residual), #622 (a conflict-free commit reaching a ref without litmus — `pre-commit-gate.sh:182-186` pre-filters on the `commit` token via a `case` on `$HOOK_DATA`, and the `IS_GIT_COMMIT != yes` bail is at `:249` — re-measured 2026-09-08; the 0827 anchors `:112-115`/`:184` no longer hold). **Remaining #622 scope NARROWED 2026-09-08, because the earlier wording claimed a closure the fix does not deliver.** What `fix/issue-622-merge-commit-gate` closes is the **multi-parent merge-commit effect** only. Verified on that branch: `fix/issue-622-merge-commit-gate:hooks/gate-scripts/merge-reference-transaction-gate.sh:154-156` is `if [[ ! "$OLD" =~ ^0+$ && "$parents" -lt 2 && -n "$FP" && "$FP" == "$OLD" ]]; then exit 0; fi` — every ordinary **single-parent** successor is allowed — and ADR 0051 (`fix/issue-622-merge-commit-gate:docs/adr/0051-native-git-merge-commit-gate.md:73-90`) states it in terms (**widened from `:73-88` 2026-09-08, round 8, M21** — read on `fix/issue-622-merge-commit-gate`, the `git am` quote is at `:81-82` and the cherry-pick/revert `-n` quote at `:89-90`, so the old range cut the second one off): `git am` "is allowed, and is not refused at all", with cherry-pick and revert in scope "via their `-n` two-step form" only. So a plain `git cherry-pick <sha>`, a plain `git revert <sha>`, `git am`, and a sequencer `--continue` of either still land unreviewed. Item 0 does **NOT** close those; they are bucketed to **#783** in *New issues since 2026-08-27* (Ref-gate / #622 spawn). Earlier drafts wrote the scope as "`git merge` / `cherry-pick` / `revert` / `--continue`", which read as if all four were covered. Then the integrity epic: #553, #570, #576, #742, #563. **[#840 adopted]** Reconcile each against merged code and residual ADRs *before* implementing, and name the violated invariant plus the supported threat model for each remaining change; prefer one focused design over a per-review command-spelling exception.

**Class:** hard

**Status 2026-09-08:** **PARTIAL** — #713, #553, #576, #742, #563 closed. #622 IN PROGRESS. #570 open — 0 commits, but its worktree holds an **uncommitted design doc; do not discard** (see *Worker ownership*). **The two design docs the handover names are absent, but the decisions are not** — #713's design landed as **ADR 0049** (`docs/adr/0049-hook-exec-form-launch-boundary.md`, on main), and #622 carries **ADR 0051** (`docs/adr/0051-native-git-merge-commit-gate.md`) on its own branch, unmerged. The precise gap is therefore *no blueprint-review record covering them*, not "no design exists" — an earlier draft said the latter and was wrong.

**Evidence / settling check:** `env SHELLOPTS=noexec /bin/sh -c 'echo X'` prints nothing rc 0 (reproduced 2026-08-27; zsh executes). Each fix ships with a test that drives the bypass and asserts the block, exercised through the affected entry point and refused **before** the effect; intended use and recovery still work. Record fixed / still-blocking / owner-accepted residuals separately.

**Installation verification — added here 2026-09-08, because item 2 declared this clause and item 0 never carried it.** A fix whose enforcement depends on **installed native hooks is NOT complete until installation is verified in the observation repositories**, with the verification command named and its output retained alongside the baseline. ADR 0051 (`fix/issue-622-merge-commit-gate:docs/adr/0051-native-git-merge-commit-gate.md:95-98`) states the dependency directly: "The gate is only reached where the repository has reference-transaction support and the hook installed; `scripts/install-git-hooks.sh` owns that." A merged PR and an installed plugin version establish nothing about native-hook installation, so establish it by a **READ-ONLY INSTALLED-HOOK AUDIT, per observation repository — corrected 2026-09-08 (round 8, M10), because the clause previously named `scripts/install-git-hooks.sh`'s own digest/pin check and THAT COMMAND DOES NOT EXIST as a check.** Read on `fix/issue-622-merge-commit-gate`, the script's argument loop accepts exactly `--force`/`-f` plus one positional path (`:30-36`); there is no `--check`, `--verify` or dry-run mode, and its embedded digest validates gate bytes **as part of INSTALLING**. So the only stated proof that the #622 gate is live was unobtainable as written, and the naive execution **installs or replaces six hooks in every repository the baseline is collected from** — precisely the contamination the *Why this order* section exists to prevent, inflicted on the observation set by the check meant to qualify it. **The audit reads and records the facts enumerated below — (i) through (vii) — and writes nothing** (the lead-in read "three facts" against a five-item list even before (vi) was added; **corrected 2026-09-09, round 10 propagation pass, by deriving the set from the enumeration instead of counting it**): (i) the **effective `core.hooksPath`** as git itself resolves it; (ii) the **presence and executability of all six wrappers**; (iii) **each wrapper's own bytes** — the `exec` target and the two arguments of its embedded digest check, all three chosen by whoever generated it (`scripts/install-git-hooks.sh:338-361` on `fix/issue-622-merge-commit-gate`); (iv) the digest of the **live closure**, recomputed over `$PLUGIN_ROOT/hooks/gate-scripts` with the wrapper's own program (`:129-165`) and compared to the digest argument each wrapper carries; (v) the digest of the **snapshot tree each `exec` target lives in**, recomputed the same way and compared to the digest in that snapshot directory's own name; **(vi) the snapshot's gate-script bytes against THIS repository's `.gate-integrity.lock` expectation — ADDED 2026-09-09, approved acceptance strengthening (round 10, finding [17]).** (i)–(v) establish that the installed wrapper is *internally self-consistent*: every digest they compare is one the wrapper itself carries, and both sides are chosen by whoever generated it. A locally-edited or shadowing hook that re-digests its own tree passes all five. Since the whole purpose of this item is to establish that enforcement is ACTIVE where the observations are produced, self-consistency is the wrong proof — it certifies *installation*, not *enforcement of the expected implementation*. (vi) binds the installed exec target to the implementation this repo expects, reusing the primitive `.gate-integrity.lock` already provides rather than inventing a second one; a mismatch DISQUALIFIES that repository from the observation set rather than being recorded as a caveat. **Its PRECEDENCE against #2(i)'s stamped BOUNDED TRANCHE is stated once at the `baseline captured` node and cited here, not restated** (ADDED 2026-09-17, native run `7886ed9f` MEDIUM; UNREVIEWED): (vi) governs the enforcing implementation's BYTE-IDENTITY, #2(i)'s stamp governs the gate's KNOWN SCOPE GAPS, and neither overrides the other. It stays read-only and writes nothing, like (i)–(v). (iii)–(vi) are load-bearing, not decoration: the wrapper digests the LIVE tree and then `exec`s `$SNAP/<script>`, where `SNAP="$HOOK_DIR/.busdriver-gates/<digest>.<mkdtemp suffix>"` (`:323`, `:478-552`), so the closure digest authenticates neither the bytes that actually run nor the wrapper that chose them. **Negative case this audit MUST fail on** (stated so the audit is falsifiable rather than a formality): repoint one wrapper's `exec` line at a copy of the gate script with its refusal branch removed, touch nothing under `hooks/gate-scripts`, and leave all six wrappers present and executable — (i), (ii) and (iv) all still pass, and only (v) and (vi) catch it, from the output (iii) records (2026-09-26; UNREVIEWED). **(vii) WRAPPER CONTROL FLOW — ADDED 2026-09-09 (round 11), within the approved item-0 acceptance strengthening.** (iii) is scoped to each wrapper's exec target and the two arguments of its embedded digest check — three fields — so the audit authenticates payload bytes and never the wrapper's control flow, which is the thing this item exists to establish. **Each wrapper MUST be compared against the reviewed installer template at `fix/issue-622-merge-commit-gate:scripts/install-git-hooks.sh:338-361` — interpreter, control flow AND arguments, not only the exec target and digest arguments.** `cat` is a RECORDING step and is not a comparison; this requirement names the comparison, which no earlier requirement did. **Second negative case this audit MUST fail on:** a wrapper that keeps the expected exec target and digest arguments but inserts an early `exit 0` above them, with all six wrappers present and executable — it passes (i) through (vi) unchanged while enforcement never runs. The cell's own argument against (i)–(v) — self-consistency certifies installation, not enforcement — applies unchanged to the wrapper itself, and repointing an exec line is a different bypass that does not cover this one. **The RECORDING command, in full — it records and does NOT compare (corrected 2026-09-24; UNREVIEWED):** checks (vi) and (vii) are separate, mandatory comparisons over its retained output — (vi) every `.gate-integrity.lock` entry under `hooks/gate-scripts/**` against the snapshot, where a locked path missing from the snapshot fails (vi), and each present file's sha256 against its entry, the lock being the one at the merged revision that holds the gates under test, its commit id recorded with the output, and a snapshot file or wrapper `exec` target with no entry there also failing (vi), except a `__pycache__/*.pyc` whose sibling `.py` is locked in the snapshot, whose PEP 552 flags are not unchecked-hash, and whose marshaled body equals a compile of that `.py` under the pinned interpreter, the rule `scripts/gate-integrity.sh` already applies ("Header flags alone are not enough"), with fixtures for a timestamp and a checked-hash `.pyc` whose valid header carries replaced code, each failing (vi) (2026-09-26; UNREVIEWED), and (vii) each recorded wrapper against the `fix/issue-622-merge-commit-gate:scripts/install-git-hooks.sh:338-361` template rendered with the `exec` target and digest arguments recorded from that wrapper, `plugin_root` derived from the recorded gate dir and required to equal the expected plugin root, and `GATE_DIGEST_PY` and the signature from the pinned installer (lock key = `hooks/gate-scripts/` + path relative to the snapshot) (2026-09-26; UNREVIEWED), byte-compared with its mode, template and `GATE_DIGEST_PY` taken from the pinned installer revision: a full commit SHA the audit resolves and records at audit time (the reviewed #622 tip before merge, the #622 merge commit on `main` after; the `:338-361`, `:129-165` and `:557-568` predicates are the re-derivation anchors), (vii) failing if the template cannot be resolved there; before rendering, each wrapper's `exec` basename must equal its hook's script under the pinned installer's six `install_one` pairs (`1712e8297194ce790a88a35e94e051015204a98e:scripts/install-git-hooks.sh:557-568`: reference-transaction → `merge-reference-transaction-gate.sh`, prepare-commit-msg → `merge-prepare-commit-msg-gate.sh`, pre-merge-commit → `pre-merge-commit-gate.sh`, post-merge → `post-merge-consume-marker.sh`, pre-commit → `merge-pre-commit-gate.sh`, post-commit → `merge-post-commit-consume.sh`), and a third negative case repoints reference-transaction at another unmodified locked script, which the whole audit must fail (2026-09-26; UNREVIEWED) — and the audit passes only when that output is retained AND both comparisons match. All three negative cases above are acceptance fixtures of the whole audit, never of this command alone, run in a disposable temporary repository with an installed snapshot and never in an observation repository; each asserts that the audit exits non-zero (2026-09-26; UNREVIEWED). The command is read-only throughout; still no `--check` mode and still no install: run `git config --get core.hooksPath` and `git rev-parse --git-path hooks`, record BOTH verbatim (including an absent `core.hooksPath`), then compare RESOLVED paths, never the raw strings: resolve the `core.hooksPath` value (expand a leading `~`, take a relative value against `git rev-parse --show-toplevel`) and the `git rev-parse --path-format=absolute --git-path hooks` output, each through `realpath`. Two spellings of one directory are agreement. Only resolved paths that differ are a disagreement, reconciled by hand with the one used recorded — this audit must not guess that resolution (2026-09-24; UNREVIEWED). Then, over that directory: `ls -l` the six wrapper names, `cat` each wrapper in full (they are ~10 lines), record the commit id of the merged revision holding the gates and `git show <rev>:.gate-integrity.lock` (2026-09-26; UNREVIEWED), and for the closure plus each distinct snapshot path named by an `exec` line run `python3 -I -S -c "$GATE_DIGEST_PY" <dir>`, with `GATE_DIGEST_PY` taken verbatim from `fix/issue-622-merge-commit-gate:scripts/install-git-hooks.sh:129-165`. **Its output is RETAINED alongside the baseline, per repository per window** — an unretained audit is an assertion, and this row's whole argument is that a gate which cannot be shown live cannot be measured over. Adding a `--check` mode to the script is the alternative and is **not** chosen here: it is a new deliverable on item 0's critical path, where the audit needs no code. This is item 0's requirement, stated in item 0. The whole `0 ──► 2-B` edge exists because the baseline is only meaningful over a gate that is not blind; while the clause lived only in item 2, a worker closing #622 against this cell could merge without it and then collect the baseline in repositories where ADR 0051's gate never runs.

### Item 2

> **MOVED 2026-09-24 (Chris-approved shrink):** now in `docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-2p-review-yield-protocol.md`, verbatim; binding there, reviewed with that child, not by this file's review.

### Item 2i

> **MOVED 2026-09-24 (Chris-approved shrink):** now in `docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-8-validation-before-dedup.md`, verbatim; binding there, reviewed with that child, not by this file's review.

### Item 2a

> **MOVED 2026-09-24 (Chris-approved shrink):** now in `docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-2a-i-a-producer-readers-gate-and-2-cap.md`, verbatim; binding there, reviewed with that child, not by this file's review.

### Item 7

> **MOVED 2026-09-24 (Chris-approved shrink):** now in `docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-7-rule-4b.md`, verbatim; binding there, reviewed with that child, not by this file's review.

### Item 8

> **MOVED 2026-09-24 (Chris-approved shrink):** now in `docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-8-validation-before-dedup.md`, verbatim; binding there, reviewed with that child, not by this file's review.

## Progress since the original plan — verified 2026-09-08

Every row was re-checked against `gh` and the tree. **Correction, 2026-09-08:** an earlier draft of this
section carried several `file:line` anchors and size figures forward from a prior session's notes while
asserting they had been freshly measured. The blueprint-review arbiter caught it. Every anchor below and
in the tables above has since been **re-run with `git show` against the checkpoint
`main@727d4652`** — not against the working tree; the corrected values are
`init-review-loop.sh:466/:556`, `script-reference.md:288`, `hooks.json:301`, `dispatch.sh:376`,
council 67 KB, litmus 58 KB, and 37 of 40 agents. **Plugin `2.1.14` is deliberately excluded from
that list: it is a *branch-tree* measurement, not a checkpoint one** (the checkpoint reads 2.1.15),
and listing it among checkpoint-provenance values is what made an earlier version of this paragraph
untrue. Treat any anchor here as valid for the checkpoint only — they move.

| # | 2026-08-27 | 2026-09-05 | 2026-09-08 | What moved |
|---|-----------|-----------|-----------|------------|
| 0 | open | partial | **PARTIAL** | #713 (PR 778, ADR 0049), #553 (PR 805), #576 (PR 795), #742 (PR 786), #563 (PR 798) closed. #622 shows recent branch activity, 29 commits ahead (assignment unverified). #570 still open; 0 commits, untracked design doc present — do not discard. #782 closed by PR 841 (2026-09-07, empty-diff merge PASS launder). Ref-gate spawn now #780 #781 #783 #822 #834 #838; marker/claim integrity now #833 #835 #836 #837 #842 plus #789 #793 #816 #825 |
| 1 | open | not started | **TODO** | #556 still open. Grok preflight unchanged |
| 2 | open | not started | **SPLIT** | New 2026-09-09 on Chris's approval of finding [19]. **2-A** record collection — gated on item 1 AND on `2a-env` by the `2a-env ──► 2-A` capability edge (item 1 is TODO, so not startable). **2-B** dataset and analysis — Chris #2 gate now SATISFIED (#2 answered: (i) bounded tranche, (ii) original seven only); 2i and `protocol-approved` still open. Neither half startable on the other's authority. **2-A's RECORDS CARRY EVERY REQUIRED-CAPTURE FIELD ITEM 2p DECLARES — including the per-reviewer `completeness` value — CITED, NOT RESTATED** (added 2026-09-13; native 79ad7ef4 finding [2] HIGH; UNREVIEWED): item 2p's row is the authoritative declaration of that field list, and this cell deliberately does not duplicate it. Stated here because this cell is 2-A's whole scope (see `docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-2p-review-yield-protocol.md` § *2-A's SCOPE IS ITEM 2's CELL*), so a worker who reads only this cell would otherwise never learn that the field list exists. No ledger artifact exists |
| 2i | — | — | **SPLIT** | New 2026-09-08. (A) #844 — status DEFINED ONCE at item 2i(A) and CITED here, never restated (upstream-closed 2026-09-15 by PR #856, obligation open, absent from this branch at `34887cb7`) — no predecessor; (B) completeness propagation TODO, its Stage 2 and detection blocked on `baseline captured` and atomic with the first authorizing reader of `completeness` (re-keyed 2026-09-13, native 2a9a6900 finding [1]; UNREVIEWED). (B)'s migration disposition RESOLVED 2026-09-09 (worker default, *Still needs Chris* #12): NO GRANDFATHER, ordering-based; startability unchanged |
| 2p | — | — | **TODO** | New 2026-09-08. Protocol DRAFT, no predecessor. Produces the artifact `protocol-approved` accepts; drafting is not approval, and no observation may be collected on it |
| 2a | — | — | **SPLIT** | Claim checked against source; template confirmed consumer-less; integrity half moved to 2i |
| 3 | open | not started | **SPLIT** | `hooks.json` still registers `observe.sh` twice |
| 4 | open | not started | **TODO** (precondition scope **RESOLVED** 2026-09-09) | `sync-upstream.sh` present; no `THIRD_PARTY_NOTICES`; no inventory. Scope resolved as worker default — the inventory gates RETIREMENT (*Still needs Chris* #3) |
| 5 | open | not started | **TODO** | #632 open; #821 (no zsh in CI) and #829 (commitlint timeout) are CLOSED as of 2026-09-16 and are re-scoped to the residual work only, not the tickets; PR #855 has LANDED on `main`, adding the agy stream-json stdin rung this document still calls an UNAPPLIED candidate — re-derive at the start tree (post-16; Photon manual-resume brief `manual-802-838-840-847-20260916.md` #840 section, on the `840-post16-readonly-diagnosis-result.md` roots; source-read at HEAD `34887cb7`, NOTHING EXECUTED; UNREVIEWED) |
| 6 | open | not started | **BLOCKED** | pr-grind 120 KB, blueprint-review 91 KB, council 67 KB, litmus 58 KB — all four grew since 0827 |
| 7 | open | not started | **SPLIT** | The advisory is registered at `hooks/hooks.json:301` via `run-with-flags.js`; the stale **"route to pi"** text is in the advisory BODY at `scripts/hooks/pre-read-size-advisory.js:256` — RE-ANCHORED 2026-09-09 (round-13 finding [18]; UNREVIEWED), because this cell attributed that string to the hooks.json line, where `:301` is the launcher `command` and `:304` the description, neither mentioning pi. `feat/read-route-gate` branch deleted. Chris #10 and #13 both RESOLVED 2026-09-09 (worker defaults): 7a-i is plain TODO after item 1 — **scoped to the discriminated-result refactor, its unit tests over returned kinds, and the measurement harness; every allow/deny-observing fixture and every enforcement deliverable is 7b's, per the partition rule stated once in the item-7 cell and cited here (RE-PARTITIONED 2026-09-09, round-13 finding [2]; UNREVIEWED)** — 7a-ii is dropped, 7b BLOCKED on `baseline captured` AND item 3's paired measurement AND 7a-i |
| 8 | open | analysis half (ledger dispositioning, stratified sampling) TODO after 2-B; mutating half (the iteration-3 medium-blocking decision) BLOCKED on 2-B AND `baseline captured` AND the recorded Chris decision at *Still needs Chris* #18; the fail-closed validation of the authorization-bearing fields moved to `2a-env`, pre-baseline, 2026-09-23 (native run `d036cd94` HIGH, arbiter-confirmed; plan-text fix; plan-only, UNREVIEWED) | **SPLIT** | **PROJECTION CORRECTED 2026-09-10 (round-15 finding [5]; UNREVIEWED)** — this row read "blocked on 2 / BLOCKED", a single-gate string that predates the item-8 SPLIT node and contradicted the graph, which governs. Baseline now pinned in prose from source (`lib/merge-findings.py:45-49`, `:64`, `:67`, `:70-82`) |
| 9 | open | not started | **SPLIT** | Classifier + fixtures **TODO**: Chris #4 **RESOLVED 2026-09-09** (worker default: fail-closed, initially-empty allowlist) settles the class boundary only; the classifier half is TODO under the dependency graph, and its landing is held by the STANDING-FAIL SCOPE (2026-09-26; UNREVIEWED); POLICY change BLOCKED on `baseline captured`, which is not reached; the WAIVER also needs the separate recorded operator disposition at *Still needs Chris* #19 as well as #4 (split 2026-09-24 (native run `00facd76` HIGH, arbiter-confirmed; plan-text fix recording an already-stated gate; plan-only, UNREVIEWED)) |
| 10 | open | in flight (eval only) | **SPLIT** | Sequencing RESOLVED 2026-09-09 (worker default, *Still needs Chris* #5): adapter inventory gates every MUTATING slice; `pi-cursor-sdk-sandbox-eval` continues as evidence-gathering only. Its worktree exists on disk (not a registered git worktree). The 6-lite predicate design is still owed |
| 11 | open | not started | **TODO** | All closure candidates still open; no probe comments. List is stale |
| 12 | open | not started | **TODO** | `tests/test-gate-adversarial.sh` predates the plan (2026-04-09) |
| 13 | — | audit done | **SPLIT** | Report committed on `docs/plan-0827-status-and-prompt-audit` (commit `dc56aa03`), which has no PR. `docs/audits/` does not exist on this branch — verified 2026-09-08. Chris #7 RESOLVED 2026-09-09 (worker default): bring the single file across via `git checkout dc56aa03 -- docs/audits/2026-09-05-prompt-audit.md`; the hunk half stays BLOCKED until that lands |

**Merged since the 09-05 check:** #841 (#782, empty-diff merge PASS launder), #828 (#811, PR-mode
verdicts across loop runs), #827 (#823, PR backstop retry budget). Plugin released to 2.1.15.

**Open PRs:** #840 (this one, draft, BEHIND), #800 (#776, DIRTY), #731 (#639, DIRTY).

### New issues since 2026-08-27, bucketed to items

Neither prior version of this plan carries these. Item 11 must re-bucket before triage starts.

**Which list scopes item 0 — read this before starting the tranche.** Item 0's row names seven
issues (#713 #622 #553 #570 #576 #742 #563) and is the *approved* scope; the fifteen rows in
the table below marked as item-12 successors are **descendants discovered since**, not silently added to it; their fix
lives in item 0's code, but the 0827 approval does not cover them. Whether
the tranche closes at the original seven or absorbs the descendants was the "bounded tranche"
question in *Still needs Chris* #2 — **ANSWERED 2026-09-09: the ORIGINAL SEVEN ONLY, with the fifteen
descendants carried as item-12 successors.** Read that answer there.

| Bucket | Issues | Item |
|--------|--------|------|
| Ref-gate / #622 spawn | #780 #781 #783 #822 #834 #838 | 12 (successor; not item 0 — #2(ii)) |
| Marker & claim integrity | #833 #835 #836 #837 #842 · #789 #793 #816 #825 | 12 (successor; not item 0 — #2(ii)) |
| resolve-cli reliability | #831 #832 #839 | 1 |
| CI | #821 #829 | 5 |
| pr-grind | #824 #830 #788 | 6 / 11 |
| Classifier precision | #776 #802 #819 #826 · plus the existing #639 #654 #724 #767 #771 #768 #769 | 11 |
| Review lane / backstop | #815 #817 | 1 / 11 |
| Merger integrity | **#844** (opened 2026-09-07 — dedup runs before `determine_status` and ranks by severity alone; **CLOSED 2026-09-15 by PR #856, obligation open, absent from this branch — status defined once at item 2i(A)**) | **2i** |

## Worker ownership — do not re-plan these

A worktree existing is **not** evidence of work. **Provenance for the numeric columns, stated
exactly because this document's own argument is that unstamped numbers drift:** measured
`2026-09-08T12:00Z` with `git rev-list --count origin/main..<branch>` against
`origin/main = 727d465215dc2e2370b595fb1300746447461456`. A re-run on a later day will differ; treat
a mismatch as drift, not as an error in this table. (An earlier draft of this table recorded
`fix/issue-780-zero-old-oid` at 34 while the same day's measurement returned **36** — the column had
gone stale on the day it claimed to record.)

**Read the limit of that evidence honestly:** commits-ahead and last-commit-date establish branch
*activity*, not that a worker is assigned, still running, or intends to finish. A stale-but-nonzero
branch (639r, idle 15 d) and an abandoned one look identical here. Confirm live assignment with
Hermes/Herdr before treating a row as owned; nothing in this repository records that.

> **`ahead=0` does NOT mean nothing was done — an earlier draft of this section said it did, and
> that was wrong in a way that could have destroyed work.** Commits-ahead is blind to the index and
> the working tree. Re-measured 2026-09-08 with `git status --porcelain`: `busdriver-issue-789`
> carries **staged** edits to `scripts/lib/resolve-cli.sh`, `skills/litmus/scripts/run-review-loop.sh`
> and `tests/test-opencode-review-arm.sh`, an unstaged edit to `tests/test-agy-read-lane.sh`, plus
> untracked `tests/test-trusted-review-cli.sh` and a session handoff; `busdriver-issue-570` carries
> an untracked `docs/plans/2026-08-29-contained-review-entry-570.md`. Both were listed as empty.
> **Never dispose of a worktree on commits-ahead alone** — read all three signals below.

**Four** independent signals, never collapsed: **branch activity** (ahead / last commit),
**uncommitted work** (`git status --porcelain`), **base staleness and supersession** (what release
the branch sits on, and whether `origin/main` already carries a superset), and **confirmed
assignment** — which no signal in this repository can establish, so it stays *unknown* for every row
until Hermes/Herdr says otherwise.

**State the rule symmetrically, because the corrected version of this section installed the mirror
image of the error it fixed.** `commits-ahead = 0` never authorizes disposal — that was the original
defect. But `uncommitted-work-present` likewise never authorizes *scheduling*: preserving work and
scheduling it are different acts, and the second one requires diffing the content against
`origin/main` first. Preservation is unconditional; scheduling is not.

| Branch / worktree | Ahead | Last commit | Base / supersession vs `origin/main` | Uncommitted work + status (assignment: unknown for all) |
|---|---|---|---|---|
| `fix/issue-622-merge-commit-gate` | 29 | 2026-09-07 | current-ish | **ACTIVE** — item 0's remaining core |
| `fix/issue-780-zero-old-oid` | 36 | 2026-09-07 | current-ish | **ACTIVE** — item-12 successor (not item 0 — #2(ii)); do not re-plan |
| `fix/issue-802-glob-expansion-timeout` | 8 | 2026-09-07 | current-ish | **ACTIVE** — classifier |
| `fix/issue-781-protected-ref-create` | 36 | 2026-08-31 | current-ish | active, idle 7 d — item-12 successor (not item 0 — #2(ii)); do not re-plan |
| `fix/issue-776-marker-case` | 28 | 2026-08-31 | current-ish | active — PR #800 open, DIRTY |
| `fix/issue-576-litmus-marker-hash` | 34 | 2026-08-30 | current-ish | #576 is **CLOSED**; residuals live in #793 #816 #835 — **待核實** whether this branch is superseded |
| `fix/issue-639-heredoc-prose` | 15 | 2026-08-23 | current-ish | PR #731 open, DIRTY, idle 15 d |
| `fix/grok-fail-salvage-coverage` | 1 | 2026-08-29 | current-ish | minimal |
| `fix/issue-570-sanitized-review` | **0** | — | HEAD `28725fc4` = **2.0.1**, ~14 releases behind 2.1.15. No supersession checked | **uncommitted work present** — untracked `docs/plans/2026-08-29-contained-review-entry-570.md`. No commits, but a design doc exists; **preserve it**. Preservation is not scheduling |
| `fix/issue-789-trusted-review-cli` | **0** | — | HEAD `2faaef15` = **2.1.4**, ~11 releases behind. **SUPERSEDED ON MAIN by `bdb9b776` (#803/#810)** — verify residue only | **uncommitted work present** — 3 staged files, 1 unstaged, 1 untracked new test, plus a session handoff. **Measured 2026-09-08:** its untracked `tests/test-trusted-review-cli.sh` is **642 lines**; `git show 727d4652:tests/test-trusted-review-cli.sh` is **1,786 lines**. The worktree content is an earlier **precursor**, not an identical copy and not unique work. `bdb9b776` also rewrote `scripts/lib/resolve-cli.sh` and touched `skills/litmus/scripts/run-review-loop.sh` and `tests/test-opencode-review-arm.sh` — the same four paths this worktree holds. **Preserve; do not schedule without diffing for unique residue** |
| `pi-cursor-sdk-sandbox-eval` | — | — | n/a | directory present, **not a registered git worktree** — 待核實; bears on item 10 |

**Assignment is unknown for every row, including these.** `fix/issue-622-merge-commit-gate`,
`fix/issue-780-zero-old-oid`, `fix/issue-781-protected-ref-create`, `fix/issue-776-marker-case` and
`fix/issue-639-heredoc-prose` show **recent branch activity; assignment unverified** — that is not
the same as having an owner, and this section has already ruled the inference out. `#570` and `#789`
show **zero commits and uncommitted work present**; they are **unowned, not empty**.

**Hermes/Herdr confirmation is a precondition of both scheduling and retirement**, for every row.
Stated once here; *Progress since the original plan* and *Recommended next actions* defer to this
sentence rather than restating it.

## #840 proposed revisions — item-by-item disposition

> **MOVED 2026-09-26 (byte cap, under Chris's 2026-09-26 instruction to continue):** this section is now in `docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-2p-review-yield-protocol.md`, verbatim; binding there, reviewed with that child, not by this file's review.

## Dependencies, order and acceptance for the remaining work

**This graph is the single ordered source of truth.** Where the status column, *Why this order*, or
*Recommended next actions* appear to disagree with it, the graph wins and the other surface is a
defect to fix — three review rounds found exactly that class of drift, so do not reconcile them by
reading intent. **The graph is in the 2p file (pointer below). Whether this file's surfaces conform to it is NOT part of this file's review; each such projection is a required join of clause (iii) (2026-09-24; UNREVIEWED).**

> **MOVED 2026-09-24 (Chris-approved shrink):** the dependency graph is now in `docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-2p-review-yield-protocol.md`, verbatim; binding there, reviewed with that child, not by this file's review.

> **MOVED 2026-09-24 (Chris-approved shrink):** *Standing fallback* and the 2-A/2-B split is now in `docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-2p-review-yield-protocol.md`, verbatim; binding there, reviewed with that child, not by this file's review.

> **MOVED 2026-09-24 (Chris-approved shrink):** *Recommended next actions* is now in `docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-2p-review-yield-protocol.md`, with that day's corrections applied; binding there, reviewed with that child, not by this file's review.

Acceptance for this revision itself is defined once, in the header's COMPOSITION STEP, and is not
restated here; it is reached under the current Busdriver flow. In addition, #840 stays a draft. This revision's scope
constraint is no runtime file change: the header's RECEIPT CHECK landed separately as `be15d1b0`, and this branch's
uncommitted draft of it must not be committed on #840; #7 and #8 cite that constraint (2026-09-26; UNREVIEWED). **PRE-ACCEPTANCE DELIVERY (Chris, 2026-09-25; UNREVIEWED):** while the FAIL stands, three pieces of review tooling may land, each as its own litmus-reviewed commit through the pre-commit, pre-PR and pr-grind pre-merge gates: the review runner with its closure dirs (the RECEIPT CHECK), the `recorder` node, and `2a-env-form`, the definition of the executed-review FORM pattern split out of `2a-env`, gated by neither 2i nor #622. They exist so acceptance does not wait on work that waits on acceptance: acceptance needs the recorder, which needs the runner commit and the FORM pattern, and none of those waits on acceptance. **STANDING-FAIL SCOPE, defined once here (2026-09-26; UNREVIEWED):** while this plan's FAIL stands, no node may LAND on this plan's authority except these three. Starting and drafting (a branch, or an unlanded artifact such as `docs/reviews/review-yield/protocol-v1.md`) stay governed by the dependency graph and the status legend. In-flight sibling branches under *Worker ownership* and the non-mutating 10-eval are not governed by it. Acceptance still needs the COMPOSITION STEP. The route is the one the runner commit took: its own branch cut from `main`, in its own worktree, started by the operator; the bypass log records no design-review skip for it (2026-09-26; UNREVIEWED).

> **MOVED 2026-09-25 (byte cap, under Chris's 2026-09-25 go-ahead to break the acceptance cycle):** *Feasibility evidence and limits* is now in `docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-2p-review-yield-protocol.md`, verbatim; binding there, reviewed with that child, not by this file's review.

## ADR bookkeeping and review boundary

Implementation PRs record amendments to 0012 (item 8), 0014 / 0048 D6 (item 4), 0034 / 0040
(item 7) and 0046 / 0048 D1 (item 3). **This plan edit amends no runtime contract; the RECEIPT CHECK landed separately as `be15d1b0`.**
The decisions named here were the revised **item-4 precondition scope** (*Still needs Chris* #3)
and the **item-7 helper-down policy** (*Still needs Chris* #10); **both are RESOLVED 2026-09-09 as
worker defaults** — the inventory keeps gating retirement, and the helper-down policy is (A). They
are recorded in those rows and are vetoable by row ID; neither is an operator approval, and neither
authorizes an implementation PR. **#16(c), #18 and #19 are OPEN in that section, each cited by row ID; this sentence settles none of them (2026-09-24; UNREVIEWED).** Of the rows this sentence once covered, #14, the built-in fallback question opened 2026-09-09 (round 11), was ANSWERED the same day by Chris as option (A), preserve the fallback: #6 was resolved from
the record as a supervisor fact (no assigned #570 worker; preserve and defer, since owner absence is
not disposal authority), and the why-this-order reframing is REJECTED under the same
no-loosening default as #3 and #9. **Delivery is nonetheless still blocked — by the live review
verdict in the status file, not by a pending decision** — except the three PRE-ACCEPTANCE DELIVERY items, within the STANDING-FAIL SCOPE (§ *Dependencies*). Not "the item-7 default", which an
earlier draft named and which is **settled**: the direction is the retained cost-gate and #840's
opt-in cohort is REJECTED (*Still needs Chris* #1, and the disposition table (`docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-2p-review-yield-protocol.md` § *#840 proposed revisions*)). Naming the settled
question here left a phantom approval dependency in the implementation instructions. Neither open
item may be resolved by silent reinterpretation of #775 or of the 0827 approval. Item 0 closes named
residuals of ADR 0016 rather than claiming a broader boundary.

- Depended on, untouched: 0001, 0002, 0004, 0005, 0006, 0007, 0009, 0013, **0016** (item 0 closes a
  residual it names), 0018, 0024, 0026, 0033, 0035, 0036, 0042, 0043, **0044** (item 9's starting
  point), 0047, **0049** (#713's landed design), **0050** (ref-fast-forward gate).
- In flight, unmerged: **0051** (`fix/issue-622-merge-commit-gate`) is #622's decision record. If
  item 0 still owes a *new* ADR for the #622 closure beyond 0051, say so here rather than only in the
  historical handover. Preserve 0006 / 0026's applicable trust decisions while reconciling
  hosts in item 10; an adapter change that alters authority needs its own recorded decision.
- Superseded records left as historical: 0010, 0011, 0015, 0041, 0027-review-once.

## Dropped from the original audit

Retained unchanged: the three allegedly dangling command shims were a false positive (`learn.md`
writes `~/.claude/skills/learned/`, a runtime dir); bypass-log counts as a gate defect were test
pollution; `ECC_DISABLED_HOOKS` does not disable contained hooks; no quarterly upstream-digest
ritual; no loosening of litmus `medium` on frequency alone.

## Still needs Chris

**Provenance classes in this section, distinguished once here and never conflated (the lead-in read "Two provenance classes" while the text below already named four dispositions; the count is DROPPED rather than corrected 2026-09-17, under this document's own derive-never-restate rule — native run `7886ed9f` MEDIUM; UNREVIEWED).**
**ANSWERED by Chris** — rows **#2**, **#11** and **#15** (#15 opened retrospectively 2026-09-13,
native 79ad7ef4 finding [13]: the 2026-09-12 detection-first decision was being enforced by item 2p
and the graph with no row here) — records an actual operator decision. **#11 carries
TWO Chris answers**: the original (B) *out of scope*, and the 2026-09-09 reversal to (A) *in scope,
in the plan* (`批准840重開11並納入計劃`). Both are kept in that row — the superseded one as
provenance, clearly marked — because a reversal that erases what it reversed cannot be audited. **A
later Chris answer supersedes an earlier one on the same row; it does not make the earlier one a
worker default**, and neither is reclassified by the other.
**RESOLVED 2026-09-09 (worker default)** — rows **#3, #4, #5, #7, #9, #10, #12, #13** — records a
technical default chosen by the worker under Chris's 2026-09-09 delegation
(*"不是要我決定的東西"*), because each is a reversible technical choice already inside this plan's
scope rather than a product, spend or material-risk call. **A worker default is NOT an operator
approval**: it is recorded so it can be vetoed by row ID, it authorizes no implementation, and it
clears no milestone that carries its own prerequisites. Rows **#1** and **#8** are **RECORDED** —
no answer is owed on either. **#6 is RESOLVED as a SUPERVISOR FACT** — a question of record, not of
policy: no #570 worker is assigned, and the disposition is preserve-and-defer, because owner absence
is not disposal authority. **ROWS #16 AND #17 WERE OPENED 2026-09-17 AWAITING AN OPERATOR DECISION (native run `7886ed9f` MEDIUMs; UNREVIEWED), AND ON 2026-09-17 #17 AND #16's (a) AND (b) WERE ANSWERED BY PHOTON under Chris's standing delegation (decision memo `~/.hermes/reports/840-open-16-17-photon-decision-20260917.md`; recorded in plan text only; UNREVIEWED). #16(c) REMAINED OPEN; #18 and #19, opened since, are OPEN as well, and each row's own cell carries its state (2026-09-24; UNREVIEWED).** **ANSWERED BY PHOTON IS ITS OWN PROVENANCE CLASS, DEFINED ONCE HERE AND CITED — NEVER RESTATED — BY THE ROWS THAT CARRY IT:** a supervisor disposition taken under Chris's standing delegation and recorded by row ID so it can be cited and vetoed by ID. It is NOT a Chris answer, NOT a worker default, and NOT an operator approval of implementation; it clears no milestone, it authorizes no review, no round and no unpark, and it does not touch the standing FAIL. They are the first OPEN rows this section has carried since #14 was opened and ANSWERED on 2026-09-09 (round 11; option (A), preserve the built-in fallback). This line previously read "No row in this section is awaiting an operator decision"; it was true when written and is not now, and it is CORRECTED rather than deleted so the change of state is visible. **THERE IS THEREFORE A FURTHER PROVENANCE CLASS, named here and never conflated with the others: OPEN** — a question recorded with a row ID, an (A)/(B) answer form and a "what this row does NOT do" clause, carrying NO answer and NO worker default, and authorizing nothing until an operator answers it BY ID. **An OPEN row is not a worker default and must not be read as one**: neither #16 nor #17 is answered by the worker who opened it, and a recommendation inside one is a recommendation, not a disposition. That is a
statement about decisions only — delivery remains blocked by the live review verdict in the status file,
which no decision in this section touches.

1. ~~**Item 7 direction**~~ — **not an open question; recorded here only so the disposition is
   traceable.** The operator instruction for this revision already settles it: keep the 2026-08-27
   cost-gate, do not downgrade to an opt-in experiment merely because several harnesses exist.
   #840's item-7 rewrite is therefore REJECTED, and measurement sits in acceptance rather than
   gating the build. The item's status is **SPLIT** (7a-i after item 1; 7b on the gates the
   dependency graph carries, cited not restated here). **CORRECTED 2026-09-09 (`全部批准`, round-14
   finding [18]; UNREVIEWED):** this pointer still listed a third half, "7a-ii on Chris #10 — spent
   2026-09-09", but #10 resolved to **(A)**, which drops the helper-down failure test together with
   option (B); 7a-ii therefore **ceased to exist as a separately gated half** rather than becoming
   schedulable, and naming it here re-created a half the row and the graph had both removed — an earlier draft said "a plain TODO sequenced after item 1",
   which predates the mutating-half rule, and the parenthetical that replaced it dropped the Chris #10
   conjunct from both halves that carry it, restating item 7's gating in a fourth surface at variance
   with the graph. The row and the graph are authoritative; this line is a pointer, not a second
   statement. Nothing is owed on the *direction*; the separate helper-down policy is #10 below.
2. ~~**"Bounded tranche" reframing (item 0 / why-this-order).**~~ **ANSWERED 2026-09-09 by Chris.**
   The item had been carrying two decisions while offering answer forms for only one, so it was
   SPLIT (2026-09-09, round 9, finding [14]) into #2(i) and #2(ii); the ID **#2 is preserved, not
   renumbered**, and Chris answered **both**. This is the single normative record of the answer;
   every other surface cites it.
   - **#2(i) — baseline ELIGIBILITY: ANSWERED = (b) BOUNDED TRANCHE.** The item-2 baseline **may**
     be captured over a partially-closed integrity gate, **with that limitation stamped on the
     baseline itself**. **The stamp governs KNOWN SCOPE GAPS of the gate, never its BYTE-IDENTITY:**
     item 0 (vi)'s disqualification is a separate object, and the precedence between the two is
     stated once at the `baseline captured` node and cited here, not restated (ADDED 2026-09-17,
     native run `7886ed9f` MEDIUM; UNREVIEWED). Form (a) close-the-class is NOT taken. **Accepted cost, recorded here rather
     than discovered later:** the baseline then measures a gate live in fewer repositories than
     close-the-class would have guaranteed, so every cross-repository comparison over that window
     must be read together with the recorded limitation.
   - **#2(ii) — tranche MEMBERSHIP: ANSWERED = THE ORIGINAL SEVEN ONLY.** The fifteen descendants
     are **not** item-0 work; they are tracked as **item-12 successors**. So the graph's
     `descendants ──► 12` edge, which was CONDITIONAL on exactly this, **does not fire**; #780's and
     #781's pre-merge item-12 obligations and #789's scheduling follow the successor route rather
     than item 0's.
   **What this answer does NOT do.** It authorizes no collection and no implementation, it does not
   satisfy `protocol-approved` or `baseline captured` (those keep their own prerequisites), and it
   decides no other row in this section — #1, #3, #4, #5, #6, #7, #8, #9, #10, #12 and #13 were
   untouched **by this answer**, and **#11 was, at that moment, ANSWERED (B)** — it has since been
   REOPENED and ANSWERED (A) by Chris on 2026-09-09, which this clause does not and cannot record,
   because it describes what the #2 answer left untouched rather than the current state of #11.
   Read #11's own row for its live disposition. *(Several of those rows have since
   been RESOLVED as worker defaults on 2026-09-09 under a separate delegation — see the provenance
   note at the head of this section. None of them is a Chris answer, and none was derived from this
   one; this clause records what #2 did NOT decide, not the current state of those rows.)* It is not an approval of #780 or of any work bucketed
   under it beyond the successor classification stated above.
3. **Item 4 precondition scope.** Does the 235-row transitive inventory gate *retiring the copier*
   (original + #775), or only *pruning content* (#840)? **RESOLVED 2026-09-09 (worker default) —
   it gates RETIREMENT, exactly as the 0827 approval and Codex #775 both wrote it; #840's
   narrowing to *pruning only* is REJECTED.** Retirement is the irreversible step and the one the
   inventory exists to make safe — a `sync` row whose consumer is unknown is precisely the row
   whose copier must not be removed. Pruning does **not** thereby acquire a second, separate
   gate: each pruned row is dispositioned out of the *same* inventory, so nothing new is built.
   Chosen as a worker default because **keeping** an approved precondition needs no authority
   while loosening one does, and #840 offered no evidence for the loosening.
4. **Item 9 class boundary.** Which document classes count as "genuinely passive prose"?
   **RESOLVED 2026-09-09 (worker default) — by MECHANISM, not by an enumeration.** The eligible
   class is a **fail-closed allowlist that starts EMPTY**: a path is exempt only if it is listed,
   and a path is added only in a reviewed diff that also carries a classifier fixture
   demonstrating passivity. Unlisted or unclassifiable ⇒ **not eligible**, **and a DIFF is eligible
   only if EVERY path it touches is listed** — the conjunction is what makes the mechanism fail
   closed, since a per-path rule alone lets a mixed diff ride one passive file. Permanently ineligible,
   so the allowlist can never grow to swallow the rule: `CLAUDE.md`, `skills/**`, `agents/*.md`,
   `commands/*.md`, `hooks/**`, `docs/adr/**`, and any document that changes trust, routing, gates
   or acceptance criteria. **The allowlist cannot ride its own exemption** — a change to it is not
   passive prose, so it is never docs-only by its own rule; that is what stops the gated party
   declaring its own scope, the failure this repo's gate doctrine names first. An enumeration was
   deliberately NOT written here: naming N paths from the armchair is the half that would have
   been a scope call, and it would drift the moment a file changed character.
   **CHANGE-TIME REVALIDATION — ADDED 2026-09-09, approved acceptance strengthening (round 10,
   finding [18]).** Everything above validates the allowlist *at introduction*. A control checked
   only when it is created is one whose correctness decays with every later edit: a widening
   would land with none of the scrutiny the original empty set received, because no settling
   check fires on an addition. So the allowlist's **contents are pinned by a test asserting them
   against an expected set**, and the acceptance for any addition is that the same reviewed diff
   updates that expectation, carries the passivity fixture, and re-runs the classifier over the
   WHOLE list — not just the new entry.
   **The trigger is the DIFF, not the path set — CORRECTED 2026-09-09 (round 11).** Every trigger
   named above is an allowlist ADDITION, so editing an already-listed passive document into
   routing instructions or executable examples changes neither the path set nor the pinned
   expectation: no test fires, the classifier never re-runs, and the proposed regression stays
   green for exactly the case this strengthening exists to close. Eligibility is a property of the
   diff, and this clause named that and then attached its remedy to the wrong event. **Therefore:
   any reviewed change TOUCHING a file already on the allowlist must re-run the passivity
   classifier over that file, and the required negative case is a listed passive document that
   becomes operational with the allowlist untouched — which the check MUST fail.** This is the same primitive `.gate-integrity.lock`
   uses one layer down: the edit is not prevented, it is made impossible to land invisibly.
   **The POLICY half is untouched and still waits on `baseline captured`.**
5. **Item 10 sequencing.** #840 would block every pi slice behind a host-adapter inventory, but
   `pi-cursor-sdk-sandbox-eval` is already in flight. Which wins? **RESOLVED 2026-09-09 (worker
   default) — SPLIT by this plan's own mutating/non-mutating legend; neither "wins" wholesale.**
   #840's adapter inventory is **ADOPTED as a precondition on every MUTATING pi slice** — anything
   that changes runtime routing, dispatch, or an installed adapter. The in-flight
   `pi-cursor-sdk-sandbox-eval` **continues, as evidence-gathering ONLY**: it changes no runtime
   file, so the inventory has nothing to protect there, and its findings are an **input** to the
   inventory rather than a bypass of it. Any mutating output it proposes is a slice and waits.
   Nothing safe is blocked; nothing gated is loosened. **Item 10's 6-lite predicate requirement is
   UNTOUCHED** — "operator-authored" and "untrusted patch" still owe a signal, a writer and an
   evaluation point before any 6-lite code, and that is implementer work, not a decision this row
   settles.
6. **Item 0 / #570 — uncommitted work, no commits, assignment unknown.** Its worktree holds an
   untracked design doc that was never committed. Does it resume, does the work get landed by another
   worker, or does it get captured and the worktree retired? Nothing here can tell you whether a
   worker is still assigned — that lives in Hermes/Herdr.
   **#789 is deliberately reduced out of this question.** An earlier version bundled it here on a
   premise this plan never tested — whether `origin/main` already carries a superset. It does:
   measured 2026-09-08, the worktree's 642-line untracked `tests/test-trusted-review-cli.sh` is an
   earlier **precursor** of the 1,786-line file landed by `bdb9b776` (#803/#810), which also rewrote
   `scripts/lib/resolve-cli.sh` and touched the same four paths. **So #789 is superseded, not
   orphaned**, and the old "the work is real, do not discard" framing overstated the risk in one
   direction while understating it in another. **Before answering this item, diff #789's staged
   content and its untracked test against `727d4652` and `bdb9b776`; reduce this question to #570
   alone unless that diff shows unique residue.** Preserving a stale precursor is not the same as
   scheduling it.
   **RESOLVED 2026-09-09 — but as a SUPERVISOR FACT, not a Chris policy decision, and the two must
   not be confused.** The question this row asked ("is a worker still assigned?") is a matter of
   record, and the record answers it: **the managed allowlist carries #780/#840 plus retained
   #622/#802, and NO assigned #570 worker; #570's historical record is PARKED.** Corroborated
   read-only against this repository 2026-09-09: `fix/issue-570-sanitized-review` is
   `28725fc47a6ccf7c471cb5e1882c3370db62ade8`, which is `chore(release): 2.0.1 [skip ci]` — a
   release commit already contained in `origin/main`, so the branch is BEHIND, not ahead, and every
   #570 artifact is uncommitted in its worktree.
   **What that fact does NOT grant — the distinction this row exists to hold.** *Owner absence is
   not disposal authority.* No worker being assigned settles **who is working on it**; it settles
   nothing about **what may be done to it**. So the answer is **PRESERVE AND DEFER UNDER DRAIN**,
   and specifically **NOT**: not resume, not retire or discard the worktree, not open a
   duplicate-issue capture, not treat the absence as a licence to reassign. The worktree stays as
   it is, intact, and its uncommitted contents are preserved — which is exactly the *Worker
   ownership* preserve line, now with the assignment question answered rather than pending.
   **No operator decision is owed on this row.** An earlier revision of this paragraph framed it as
   an ask to Chris; that was a misclassification of a record question as a policy one.
   **Prior measurement, retained.** Measured 2026-09-09 on this checkout: both
   `fix/issue-570-sanitized-review` and `fix/issue-789-trusted-review-cli` are **0 commits ahead of
   `origin/main`** (#789's tip is `2faaef15`, a release commit already contained in main), so every
   residue in either worktree is **uncommitted**; and the #789 half reduces exactly as this row
   instructs, its untracked test having already been measured a superseded precursor of
   `bdb9b776`. #789's *staged* content could not be inspected from here — `git worktree list` was
   **REFUSED by the design-review gate** (recorded, not bypassed) — so #789's residue question is
   answered for its untracked half and unverified for its staged half.
   The question this row once posed as an ask — *is a worker still assigned to #570?* — is answered
   above from the record. It is not reopened here, and its answer authorizes nothing.
7. **Item 13 and the 09-05 audit report.** Item 13 is in this plan, but
   `docs/audits/2026-09-05-prompt-audit.md` is **not on this branch** — it exists only on
   `docs/plan-0827-status-and-prompt-audit` (`dc56aa03`), which has no PR. Three options: carry the
   file onto #840 (one extra docs file in this PR), open a separate PR for that branch, or drop the
   report and keep item 13 pointing at nothing. Until you choose, item 13 cites a file this branch
   does not contain — a dangling reference I have labelled rather than hidden.
   **This one is worth resolving in this round rather than carrying**, because a labelled dangling
   reference on a critical path is still a blocked critical path: item 13's acceptance instructs
   implementers to re-verify every anchor *in the report*, which cannot be executed here, so item 13's
   **hunk-application half is BLOCKED** rather than AUDIT DONE — **the row's status is SPLIT**, matching
   the item table and the Progress table. (An earlier version of this sentence said the item itself was
   marked BLOCKED, giving item 13 a third, conflicting status in a fourth surface. The verbatim-copy
   rule stated for the Progress table applies here too: this list projects the row, it does not restate
   it.) The cheapest resolution consistent with this
   revision's "no runtime file changes" constraint (its one exception is the header's RECEIPT CHECK) is to cherry-pick the single docs file onto this
   branch; inlining the surviving hunks and their re-measured anchors into an appendix is the
   alternative. (Item 6's gates are the
   graph's — `13-eval ──► 6` and `baseline captured`; this row settles only how the audit file
   lands. CORRECTED 2026-09-12, native finding [16] HIGH: measurement deleted the retired blanket
   `13 ──X──► 6`, NOT the 13-eval gate that replaced it, and this row does not restate either;
   UNREVIEWED.)
   **RESOLVED 2026-09-09 (worker default) — carry the SINGLE FILE onto this branch, and the
   mechanism matters.** Measured 2026-09-09: `dc56aa03` touches **two** files —
   `docs/audits/2026-09-05-prompt-audit.md` (+476) **and this plan** (+25) — so a `git cherry-pick`
   would collide with the plan this branch has since rewritten. The correct form is the single-path
   checkout in its own commit: `git checkout dc56aa03 -- docs/audits/2026-09-05-prompt-audit.md`.
   The separate-PR option is REJECTED — it leaves item 13 dangling *here*, which is the defect.
   Dropping the report is REJECTED — item 13's acceptance requires re-verifying its anchors, which
   needs the report. **This decision does NOT unblock item 13**: its hunk-application half stays
   BLOCKED until the file actually lands, which needs a commit that this document-only phase does
   not have. What changed is that the *decision* is no longer the blocker; the *landing* is.
8. **Two recorded-but-out-of-scope config drifts.** (a) `.claude/CLAUDE.md` says "Gemini 3.7 Flash";
   deployed is `gemini-3.8-flash-high`. (b) **The ultraOracle route** — `~/.claude/busdriver.json:33-34`
   carries `gpt-5.6-pro`; the fix is `--model gpt-5.6-sol --reasoning-mode pro`. **(b) was added
   2026-09-09 (round 9, finding [21]): the Execution-model section already claimed this clause was
   recorded here, and it was not — so the finding that section said would "otherwise be lost" was in
   fact lost.** Both out of this revision's scope — recorded so they are not lost.
   **RECORDED, not a decision — no answer is owed here and none is being sought.** Like #1, this
   row exists so the two drifts stay traceable; both are out of scope by this revision's own
   "no runtime file changes" constraint (bar the header's RECEIPT CHECK), and neither becomes actionable by being answered.
9. **#622 has a decision record but no blueprint-review record.** The 0827 handover made a
   *blueprint-reviewed* design doc the precondition. The designs exist — ADR 0049 for #713 (merged),
   ADR 0051 for #622 (on `fix/issue-622-merge-commit-gate`, unmerged) — but neither carries a
   blueprint-review PASS, and the handover argued twelve litmus rounds' worth of reasons for that
   review specifically. So: waive the review record for #622, or run blueprint-review on ADR 0051
   before that branch goes further?
   **RESOLVED 2026-09-09 (worker default) — NO WAIVER.** Verified 2026-09-09:
   `git show fix/issue-622-merge-commit-gate:docs/adr/0051-native-git-merge-commit-gate.md` contains
   **zero** `design-reviewed` markers, so the premise holds — the record is absent, not merely
   unfound. The 0827 handover's precondition therefore **STANDS**: blueprint-review on ADR 0051 is
   owed before that branch goes further. Waiving is the option that needs authority; keeping the
   precondition needs none, and this repo's own #656 doctrine is that a withheld PASS is never
   laundered into approval. **This plan neither runs that review nor re-plans #622** — the
   obligation pre-exists and sits with that branch's owner; what is recorded here is only that no
   waiver was granted.
10. **Item 7 helper-down policy — (A) or (B).** Distinct from the item-7 *direction*, which is
    settled at #1 above. When the agy-read helper is unavailable (as opposed to the hook failing to
    launch, which stays fail-open by rule (2)): **(A)** no-limit reads stay denied and the agent
    paginates — then the wholesale-read language and the helper-unavailable test are dropped
    entirely; or **(B)** a bounded, cached helper failure downgrades the gate to advisory — then name
    the cache path, the TTL, and the rule that dispatch is never on the gate's critical path. The row
    previously asserted both, in a body sentence and a closing sentence that contradicted each other.
    No engineer can write the failure test until this is answered.
    **RESOLVED 2026-09-09 (worker default) — (A).** No-limit reads stay denied when the agy-read
    helper is unavailable; the agent's recovery is rule (1)'s `limit`, which it already has.
    **(B) is REJECTED**: downgrading a gate to advisory because a *dependency* failed is fail-open,
    and it puts a dispatch on the gate's own critical path — both against this repo's
    enforcement-gate doctrine — while additionally owing a cache path and a TTL that do not exist.
    (A) also deletes code rather than adding it. **Consequences, stated once here and cited
    elsewhere:** rule (3)'s wholesale-read language and the helper-unavailable failure test are
    **DROPPED**; **7a-ii ceases to exist as a separately gated half**; and 7b's `Chris #10`
    conjunct is **SPENT**, leaving 7b gated on `baseline captured` AND item 3's paired measurement,
    plus 7a-i landed on the graph's `7a-i ──► 7b` edge (added 2026-09-24; UNREVIEWED).
    **Rule (2) is untouched** — a hook-**launch** failure is still fail-open.
11. **Item 2a — is the distinguishable short-circuit marker form IN SCOPE?** Opened 2026-09-09
    (round 9, finding [1]); a scope question, not wording. Bound (i-a)/(i-b) proposed the tightening
    while the same cell says the form "is NOT decided by this row and are NOT decided anywhere else
    in this plan". Both halves verify against real code (`run-review-loop.sh:3115`/`:3585` are
    byte-identical; `dispatcher-commit-block.sh:946-948` prefix-rejects, `:1076-1084` accepts any
    matching bare 64-hex). **(A)** Adopt — name the prefix (e.g. `PASS-SHORTCIRCUIT-<hash>`) and the
    `:946-948` arm it lands in; (i-a)/(i-b) then carry a decision. **(B)** Out of scope — they stay
    proposals and no reader changes.
    **FIRST ANSWER 2026-09-09: (B) — RETAINED AS PROVENANCE, SUPERSEDED BELOW.** Under (B) the
    distinguishable marker format and the reader tightening were out of scope; (i-a)/(i-b) stayed
    PROPOSED and non-authorizing. That answer closed the finding-[1] contradiction by removing the
    claim rather than by solving the provenance gap, and it was recorded as leaving that gap real
    and unaddressed.
    **(B) PROVED SELF-CONTRADICTORY, which is what reopened the row.** Bound (i) asserts the
    no-review mints are "NOT thereby unconstrained" because "two rules replace the bare exemption" —
    and under (B) **both** of those rules were out of scope and non-authorizing, so nothing replaced
    the exemption and the bound asserted a coverage the plan did not have. A row cannot both exempt
    the mints and claim they are constrained by rules it has placed out of scope.
    **REOPENED AND ANSWERED 2026-09-09 — CHRIS, `批准840重開11並納入計劃`: (A), scoped to THIS PLAN.**
    The short-circuit **provenance distinction** and the **complete-verification requirement** are
    **IN SCOPE and IN THE PLAN**. (i-a) and (i-b) cease to be proposals: they are binding
    requirements of item 2a, and bound (i)'s "NOT thereby unconstrained" is true again because the
    two rules that replace the bare exemption are now live. **This is a PLAN-ONLY inclusion: it
    specifies the requirement, its producers, its readers and its gate; it authorizes no runtime
    implementation, and writing it here does not start it.** The successor/residual route floated
    during diagnosis — carrying the gap to an owner outside this plan — was **considered and NOT
    approved**; the gap is closed inside the plan instead. **Prior provenance above is retained
    deliberately**, so the reversal is auditable and no reader mistakes (A) for the original answer.
12. **Item 2i(B) — legacy migration / grandfather / ordering.** Opened 2026-09-09 (round 9,
    finding [0]); the row proposes NO GRANDFATHER with the circularity broken by ORDERING, and that
    proposal is recorded but unapproved.
    **RESOLVED 2026-09-09 (worker default) — the proposal is ADOPTED as written: NO GRANDFATHER,
    with the circularity broken by the two-stage ORDERING the row already specifies.** This is a
    **new disposition under the delegation, NOT a restoration of the struck "DECIDED 2026-09-08"
    label** — that label was struck because no approval carried it; this one carries the delegation
    instead, and is vetoable by row ID. What decides it (restated 2026-09-24; UNREVIEWED): no artifact minted before Stage 2's commit
    is honoured after it. Stage 2 refuses by FORM every such artifact in a review-derived form
    OTHER than item 2a bound (i-a)'s executed-review form — including one that already carries
    `complete` — and it is re-reviewed. An (i-a) executed-review marker cannot be told apart by
    form, so it is retired by INSTANCE at Stage 2 activation and re-reviewed (item 2i(B) Stage 2,
    cited). A `PASS-FAST` marker is review-derived and not the (i-a) form, so Stage 2 refuses it at
    its reader by FORM like every other such artifact; after Stage 2 no `PASS-FAST` marker
    authorizes `gh pr create` (2026-09-24; UNREVIEWED). The authorization markers are diff-bound and consumed,
    so at the stage-2 cutover the surviving population is stale markers that are refused or
    retired, and re-reviewed. **Stage 1 stays outcome-neutral and stage 2 stays atomic
    with the FIRST AUTHORIZING READER of `completeness`, behind `baseline captured`; neither becomes
    startable on this disposition alone.** PROPAGATED 2026-09-13 (native 2a9a6900 findings [1] and
    [2]; UNREVIEWED): this read "atomic with item 2a's first complete producer", the trigger retired
    by the 2026-09-13 re-key. The retired "empty by construction" premise (stamping begins at the cutover build) held only while the first
    emitter and the first refusal were atomic; bound (2-CAP) now emits `completeness` in `2a-env`
    before any reader refuses on it, so a pre-Stage-2 artifact can already carry `complete`.
    Stage 2 tells such an artifact apart by FORM, reusing bound (i-b)'s format-cutover provenance
    (item 2i(B) Stage 2; resolved 2026-09-13 under Photon's remaining-contract decision;
    UNREVIEWED), for every review-derived form EXCEPT item 2a bound (i-a)'s executed-review form:
    a pre-Stage-2 artifact in that form is not told apart by form, and is retired by instance at
    Stage 2 activation instead; item 2i(B) Stage 2 states that step and its acceptance (narrowed
    2026-09-24; UNREVIEWED).
13. **Item 7 rule (4b) — the `probe_unavailable` allow/deny default.** Opened 2026-09-09 (round 9,
    finding [0]); the row proposes DENY (fail-closed) with an accepted-cost paragraph, and that
    proposal is recorded but unapproved. It is a live-behaviour change over a probe that today denies
    nothing, so it needs an explicit answer.
    **RESOLVED 2026-09-09 (worker default) — DENY (fail-closed), and the `not_found` ⇒ ALLOW split
    is adopted with it.** A gate that IS running and has reached no conclusion blocks; a *cost*
    gate is uniquely cheap to satisfy under that rule, because `limit` clears it. **This is the one
    LIVE-BEHAVIOUR TIGHTENING in this batch and is flagged rather than buried:** the incumbent
    probe denies nothing today, so this is a NEW prohibition on non-darwin/non-linux hosts and on
    intermittent `lsof` failure — the accepted cost is stated in item 7 and is not restated here.
    **The failure ladder, in evaluation order — the two rungs that are NOT probe kinds are stated
    here; every probe kind's disposition is the CANONICAL KIND → DISPOSITION TABLE's and is CITED,
    not restated. REPOINTED 2026-09-09 (`批准840`, round-14 finding [1]; UNREVIEWED),** because the
    flat list that stood here omitted `trust_root_unavailable` and `unparsable_payload` and so was
    a fourth surface disagreeing with the remaining dispositions (**"the other three" replaced 2026-09-10, round-15 finding [4]; UNREVIEWED — a written count beside a list that has since grown, the same stale-numeral defect this document forbids elsewhere; the count is derived, never written**): hook fails to LAUNCH ⇒ fail-open (rule (2),
    unchanged, and NOT a probe kind — the gate never ran) · rule (4a)'s declared binary /
    non-regular / paginated `Read` format exemption is evaluated FIRST · then every probe kind
    takes the table's disposition · agy-read helper down ⇒ no-limit reads denied (#10 = (A)).
    **`trust_root_unavailable` ⇒ DENY is part of this resolution and adds no second tightening** —
    it is the same fail-closed rule already approved here for `probe_unavailable`, applied to a
    kind this ladder had simply left out. **Consequence: the indeterminate-probe fixtures per rule (4) are no longer NEEDS
    CHRIS #13 — the DENY default is settled and becomes an INPUT to 7b.** RE-PARTITIONED 2026-09-09
    (round-13 finding [2]; UNREVIEWED): this line previously made them "plain TODO after item 1",
    i.e. 7a-i's. They assert allow/deny, so item 7's partition rule — cited here, not restated —
    places them in 7b behind `baseline captured`.

14. **Item 2i(B) — does Stage 2 permanently retire the built-in review agent as a commit-authorizing
    fallback?** Opened 2026-09-09 (round 11, M16). **ANSWERED 2026-09-09 BY CHRIS — `批准840保留fallback方案`
    — OPTION (A): PRESERVE the fallback by designing a real completeness envelope. Not (B) accept the
    retirement, and not (C) exempt it from the invariant.** The full specification — producer, marker
    payload, consumer contract, fail-closed handling and its acceptance fixtures — is stated ONCE in
    item 2i(B)'s producer **(c-1b)** and is cited, not restated, here. **PLAN ONLY: nothing is
    implemented by this answer.** The facts that decided it, verified — **stated as the PROBLEM this answer closed, not as
    current design (RELABELLED 2026-09-10, round-16 finding [17]; UNREVIEWED)**: AS WRITTEN BEFORE
    THIS ANSWER, item 2i(B)'s producer (c-1b) assigned the built-in
    review agent `completeness: unstated` **permanently**, and declined the upgrade as larger scope.
    That premise is RETIRED — (c-1b) now specifies the envelope, the marker payload, the consumer
    contract and its acceptance fixtures (count read off that list).
    Stage 2's rule is that missing or not-`complete` fails closed. But the built-in path is a **LIVE
    commit-authorizing fallback today** — the arm matching `^BUILTIN-[a-f0-9]{64}$`, the
    `${MARKER_CONTENT#BUILTIN-}` extraction and the `[ "$BUILTIN_HASH" = "$STAGED_HASH" ]` comparison
    match, strip and compare the BUILTIN marker against the staged diff, at
    `727d4652:hooks/gate-scripts/pre-commit-gate.sh:943/:947/:948` (branch `9b4c6e3e:...:909/:913/:914`).
    **ANCHOR PROVENANCE CORRECTED 2026-09-09 (round-13 finding [0]; UNREVIEWED).** The round-12 note
    here claimed the round-11 `:943-948` came from the INSTALLED PLUGIN CACHE and that "the original
    `:909-914` was right". Both halves are wrong: `:943` is the CHECKPOINT's value (and 2.1.15/2.1.16's),
    `:909` the branch's (and 2.1.14's), so the round-12 pass reversed a checkpoint-accurate anchor. The
    reject-arm claim was true only of the branch tree; at the checkpoint `:943-954` IS the BUILTIN
    honouring arm. Both trees are cited here deliberately and both are revision-qualified, which the
    provenance rule now requires. So
    Stage 2 as written does not merely
    leave that path unenumerated: it **retires** it, and **re-running the built-in review cannot
    recover it**, because the same producer emits `unstated` every time. **The options, ranked:**
    (A) give the built-in path a real envelope (a schema change at `SKILL.md:478` plus a
    marker-payload change) so it can state `complete` — preserves the fallback, costs the larger
    scope this row declined; (B) accept the retirement explicitly, recording that the built-in
    fallback ends at Stage 2 and naming what replaces it for anyone relying on it; (C) exempt the
    built-in path from the completeness invariant the way the no-review paths are exempted under
    bound (i-b) — cheapest, but it puts a non-stating producer back inside the authorizing set,
    which is what Stage 2 exists to stop. **(A) IS ADOPTED; (B) and (C) are recorded as CONSIDERED
    AND NOT APPROVED**, so neither can be revived as a worker default. **This row is CLOSED.** The
    envelope, the marker payload, the consumer pattern, the fail-closed handling and the six
    acceptance fixtures live in **(c-1b)** and are not restated here — a later amendment there moves
    one copy.
15. **Baseline eligibility — is truncation-detection a PREREQUISITE of `baseline captured`, or may
    pre-detection observations count toward N?** **ANSWERED 2026-09-12 by Chris: DETECTION-FIRST,
    NOT A WEAKENED FLOOR.** Row OPENED RETROSPECTIVELY 2026-09-13 (native 79ad7ef4 finding [13]
    MEDIUM; UNREVIEWED) because the decision was already being enforced by item 2p and the
    dependency graph while **this section carried no row for it** — no row ID, no (A)/(B) form and
    no "what this answer does NOT do" clause. That is a provenance failure this section's own
    two-class preamble exists to prevent: with no row, a later amendment of #2 would not move it, a
    reader could not veto it by ID, and an operator product call was indistinguishable from a worker
    default. The answer is recorded here ONCE and every other surface cites it.
    - **The answer.** An observation counts toward the floor **N** only if truncation-detectability
      is established for it. Pre-detection observations are **INELIGIBLE**: never rounded up, never
      counted, and no stamped limitation makes them countable. The minimal capability is relocated
      EARLIER rather than the milestone redefined — the same move as bound (i-c)'s (2-ORD) split.
    - **The measurement target — ANSWERED 2026-09-13 by Chris (`go`,
      `840-new-baseline-direction-go-20260913.md`).** The baseline measures the reviewer version with
      complete-result collection (item 2a bound (2-CAP), cited); older observations are a separate
      historical cohort. This accepts the measurement target ONLY: it proves no no-bias milestone and
      no producer capability. The non-`complete` chains are handled by bound (2-CAP)'s DECLARED
      reporting rule, decided by the operator at `protocol-approved` — never evidence of no sampling
      bias and never an automatic waiver; `protocol-approved` is UNMET without that declaration (R2).
    - **The rejected alternative, named so it is not reproposed:** letting a declared
      PRE-DETECTION COHORT count toward N under a stamp. That buys a green milestone by redefining
      what it measured.
    - **What this answer does NOT do.** It does not decide the VALUE of N (that is 2p's draft,
      accepted by the operator at `protocol-approved`); it does not add an arrow edge to the graph
      — the capability is carried as the list entry `item 2-A` in the `baseline captured` node, and
      the 2026-09-12 producer arrow has been DELETED; it does not alter 2-A/2-B independent start
      authority; it does not authorize collecting any observation; and it clears no milestone.
    - **How the answer is implemented, and the ONE attempt at it that was REJECTED.** The first
      2026-09-13 implementation invented `cap_determinacy`, which marked any review returning
      issues at or above a cap ineligible. **Photon rejected it the same day under Chris's
      approval** (`840-baseline-bias-correction-approved.md`), and the rejection is right on three
      independent grounds: it removed the high-yield tail from a YIELD measurement, it used an
      under-cap count as proof of completeness, and it duplicated item 2a's `completeness` enum —
      the field declared for this exact defect. **No sampling bias is accepted here or at
      `protocol-approved`.** The answer is instead implemented by REUSING that enum: an observation
      counts only if it has at least one participating reviewer and every slot's final-accepted-attempt
      value is `complete` (item 2p, reconciled 2026-09-13), with issue count no part of
      it. A nine-finding review can reach `complete` only through bound (2-CAP)'s continuation chain
      under the unchanged per-response limits, and a chain that stops without `complete` stays
      ineligible and retained. The detection-first direction is unchanged — the per-response
      statement and complete-result collection land before capture via bound (2-CAP) — and
      what the contract can and cannot see is stated in item 2p rather than implied here.
      **No new operator question is opened for it:** the value of N and the price of reaching it are part of the
      protocol artifact whose acceptance is already the operator's at `protocol-approved`. If that
      acceptance judges the floor unreachable, the answer is a different N or a different sampling
      rule — **not** a relaxed eligibility rule, a raised cap, or admitting observations whose
      recorded `completeness` is anything other than `complete`.

16. **Convergence and termination — how this plan exits the standing review FAIL.** **(a) AND (b)
    ANSWERED BY PHOTON 2026-09-17; (c) REMAINS OPEN.** The class is defined at this section's
    lead-in and each answer sits on its own sub-row below, neither restated here; this row still
    does not answer itself. Opened 2026-09-17 (native run
    `7886ed9f` MEDIUM, conf 0.7; UNREVIEWED) because the review-exit question was owned by NO row:
    the header records a standing FAIL, acceptance requires a blueprint-review PASS, and every row
    above this one covers item scope, class boundaries, sequencing, migration or eligibility
    without any of them owning who ends this (stated without a count, under the same
    derive-never-restate rule applied to this section's lead-in). The prose acknowledgement exists — the FEASIBILITY
    section said on 2026-09-16 "no split, relocation or deletion was made then, since that needs Chris's
    approval under the standing constraint; and any further native round needs its own
    authorization" — but an acknowledgement with no row ID cannot be vetoed, cited, or moved by a
    later amendment, which is the exact provenance failure #15 was opened retrospectively to
    repair. Three sub-questions, each owed its own answer:
    - **(a) What happens to the current review artifact if this document is restructured or split?**
      The MECHANISM is established read-only at HEAD `34887cb7`, so the answer form is about POLICY
      and not about mechanism: the review directory is derived from the design file's own name —
      `init_state_file` calls `get_review_slug "$design_file"` — `basename … .md` minus a
      `YYYY-MM-DD-` prefix (`skills/blueprint-review/scripts/lib/state_management.sh:17-26`) —
      writes that slug to `.claude/current-design-review.local` and creates `docs/reviews/$slug`
      with its own `state.md` (`:56-72`), and `get_review_dir` reads the pointer back, falling
      back to a flat `docs/reviews` (`:29-42`) — so a renamed or split document resolves to a
      DIFFERENT directory with its own
      `state.md`, its own iteration counter and its own ceiling, while the existing
      `pipeline-final-plan` artifact keeps its FAIL exactly where it is. **(A)** ACCEPT that: the
      standing FAIL attaches to the old artifact only, and each successor document starts a fresh
      review with a fresh ceiling. **(B)** REFUSE it: a split may not be used to obtain a fresh
      ceiling, and every successor carries the standing FAIL until clause (i) holds; a child or integration PASS clears only its own clause.
      **RECOMMENDED: (B)** — under (A) a rename is a review reset, and this document's entire
      history is about not laundering a process signal into a quality verdict (#656).
      **ANSWERED (B) 2026-09-17 BY PHOTON.** A split or rename may NOT be used to obtain a fresh
      ceiling; the existing artifact for this document keeps its FAIL, and every successor carries
      the standing FAIL until clause (i) holds; a child or integration PASS clears only its own clause. This answers the POLICY question ONLY — the
      read-only mechanism above is unchanged, so a successor document still resolves to its own
      directory, its own `state.md` and its own counter; that is now a fact to account for rather
      than a route to rely on.
    - **(b) What act authorizes a further native round after the current stop?** The another-FAIL
      review STOP is a supervisor stop, `iteration` read 14 of 15 when this row opened (the live value is
      at the one current record, not here), and that headroom is explicitly
      NOT review authority (stated at the one current record and again in the FEASIBILITY section).
      **THE ONLY PRECEDENT ON THE RECORD IS A DIRECT CHRIS APPROVAL.** The 2026-09-16 correction
      lease granted ZERO reviews and left the another-FAIL STOP binding; run `7886ed9f` ran because
      **Chris approved exactly one original-plan review**, which Photon then recorded in a decision
      memo and executed. The 2026-09-17 correction memos since say Photon owns any later review,
      which is a statement about who decides NEXT and not a precedent that a round has ever been
      authorized without Chris. **(A)** Photon MAY authorize a round under Chris's standing
      delegation, recorded HERE by row ID so it is citable and vetoable. **(B)** every round needs a
      direct Chris approval, as the one that has happened did. **RECOMMENDED: (A)**, on the
      2026-09-17 memos alone — the operator has already placed the next review decision with Photon,
      and recording it by row ID makes that visible instead of leaving it in memos this plan does
      not reference. **The recommendation rests on those memos, NOT on the precedent**, which is
      (B)'s. **ANSWERED (A) 2026-09-17 BY PHOTON.** A further native round is authorized only by a
      Photon decision memo under Chris's standing delegation. That settles who may authorize the
      NEXT round and nothing else: it is not a worker default, not an unpark, and it authorizes no
      round here — run `7886ed9f` stays FAIL / parked_no_progress until such a memo exists and is
      cited. (That was the state on 2026-09-17. The standing FAIL is now the run named at the one
      current record, and the memo gap for the rounds since is recorded there.)
    - **(c) What disposition applies if a final permitted round still returns FAIL?** Nothing is
      pre-declared, so the plan can sit parked indefinitely with a permanently UNREVIEWED working
      draft. **(A)** accept-with-recorded-residuals under a named operator approval, the residuals
      listed by finding ID. **(B)** supersession — this plan is closed and a successor opens with
      its own review artifact and its own ceiling. **NO RECOMMENDATION IS OFFERED**: whether
      unreviewed residuals may ship is a product call, not a reversible technical detail, so it is
      not a worker default. **STILL OPEN as of 2026-09-17**, and deliberately so: it was left
      unanswered in the same act that answered (a) and (b), it is outside the scope of the Photon
      memo those two cite, and no one has been asked.
    **What this row does NOT do.** It authorizes no review, no round, no ceiling change, no split,
    no relocation and no deletion; it clears no milestone; it decides no other row; and it does not
    itself alter the standing FAIL, which remains that of the run named in
    the status file.
17. **`2i NODE ──► 2a-env` — should the edge be narrowed to `2i(B) Stage 1`?** **ANSWERED (B)
    2026-09-17 BY PHOTON — the NODE edge is RETAINED and the edge is UNCHANGED.** Opened 2026-09-17 (native run
    `7886ed9f` MEDIUM, conf 0.8; UNREVIEWED). The dependency graph's GATE line named the whole 2i
    NODE while every reason this document gives for the edge — stamp, schema, `ALLOWED_TOP` and
    constructor admission — belongs to member **(B) STAGE 1** alone. The PROSE is corrected at the
    GATE line and at the transport row; the EDGE is deliberately left as drawn, because changing it
    is a sequencing decision rather than a wording one. **(A)** NARROW the edge to
    `2i(B) Stage 1 ──► 2a-env`, and, if the baseline must measure the post-alpha merger, carry
    `2i(A)` as a separate prerequisite of `baseline captured`. **(B)** KEEP the NODE edge, accepting
    that `2a-env` — and through it `baseline captured` and the mutating halves of items 3, 6, 7b, 8,
    9 and 13 — waits on member (A)'s #844 merger reconstruction, which no clause in this document
    names as a predecessor of any `2a-env` deliverable. **RECOMMENDED: (A)**, on this document's own
    define-once rule: an edge whose stated reason names one member should name that member. It is
    RECORDED rather than taken because the critical path moves either way.
    **THE ANSWER IS (B), AGAINST THIS ROW'S OWN RECOMMENDATION**, recorded as a divergence rather
    than silently reconciled: the recommendation stands exactly as written and was not taken. The
    `2i NODE` edge is retained, so `2a-env` — and through it `baseline captured` and the mutating
    halves of items 3, 6, 7b, 8, 9 and 13 — continues to wait on the whole node, member (A)'s #844
    merger reconstruction included.
    **What this row does NOT do.** It changes no edge and no node, starts no work, clears no
    milestone, and decides no other row; the graph stands exactly as drawn.
18. **Item 8 — keep `medium` blocking at iteration 3 and later?** **OPEN; NO ANSWER IS
    RECORDED.** Opened 2026-09-24 (native run `00facd76` HIGH, arbiter-confirmed; plan-text fix recording an already-stated gate; plan-only, UNREVIEWED). Item 8 was classed "needs Chris after data" while its
    graph node gated the mutation only on 2-B and `baseline captured`, so the decision had no
    row to be recorded at. This row is where it is recorded: a Chris decision, made AFTER
    `baseline captured` and against the predeclared thresholds and BOTH strata in the item 8 file's § *Item 8*
    (the medium-only FAIL stratum and the iteration-3-and-later medium-only PASS stratum).
    Item 8's mutating half may not start until an answer is recorded here. **What this row does
    NOT do.** It makes no decision, sets no threshold, and starts no work.
19. **Item 9 — operator disposition of the baseline evidence for the waiver.** **OPEN; NO
    DISPOSITION IS RECORDED.** Opened 2026-09-24 (native run `00facd76` HIGH, arbiter-confirmed; plan-text fix recording an already-stated gate; plan-only, UNREVIEWED). Chris #4 settled the classifier BOUNDARY
    as a worker default; it did not dispose of any evidence. The WAIVER — skipping litmus
    `medium` blocking or cutting the pr-grind round budget for the class — needs this separate
    recorded operator disposition of the baseline evidence, in addition to #4, before it is
    enabled. **What this row does NOT do.** It makes no disposition, enables no waiver, and
    leaves #4 exactly as recorded.

## Historical handover — item 0 (#713), 2026-08-27

Moved 2026-09-23 to `docs/plan-history/2026-08-27-pipeline-final-plan.history.md` § *Historical handover — item 0 (#713), 2026-08-27*. It is history, not a work list, and it is not binding.
