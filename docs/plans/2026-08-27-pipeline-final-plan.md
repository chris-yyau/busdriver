# Pipeline final plan — 2026-08-27 (integrity first)

> **Original approval: 2026-08-27**, after the pipeline audit, ultra-council, open-issue triage,
> and ultimate-council (5 voices + UltraOracle + Mythos Witness + Mechanism Witness).
> Hindsight: `initiative-pipeline-final-plan-2026-08-27-integrity-first`.
> Lessons: `~/.claude/notes/lesson-council-2026-08-27-{audit-logs-are-test-polluted,integrity-before-cost}.md`.
>
> **2026-09-06 amendment: DRAFT, pending the normal plan/PR reviews.** Requested by the operator
> to update this plan, not to change runtime policy immediately. The original approval does not
> certify this amendment. Item IDs are retained for existing work; 2a is the new convergence task.
> Source checkpoint: `main@047a4609c26b2c4da5e4e7d4504473e0d518c7f2`. Reconcile merged work and
> installed versions before starting an item; this table is not a claim that all items remain open.

## Execution model — preserve configured routing

Operator clarification (2026-09-06): Claude Code usually completes planning; Hermes uses Herdr to
assign an issue/plan to Claude Code, OMP, or Cursor-agent using dependencies and quota. The selected
worker owns the remaining Busdriver pipeline through delivery. This records the operator's deployed
workflow; it does not claim that every host adapter is shipped or verified in this repository.

**Pipeline stages and the effective `busdriver.json` routing already determine when and which
agents are used.** Preserve that configuration-driven contract, including its configured fallbacks
and gate-specific restrictions. Hermes selects the pipeline worker; the worker follows the existing
pipeline and resolved routes. Neither gets a new power to improvise reviewer substitutions, skip
stages, or rewrite routing to obtain a PASS. Grok, Agy, Codex, OpenCode, and Droid remain helpers or
review backends in this workflow, not additional full-pipeline workers. This amendment adds no
free-form scheduler and proposes no migration to Paseo or another orchestrator.

## Why this order

Integrity-first means closing a **bounded, evidenced tranche**, not waiting for every conceivable
shell edge case to disappear. Item 0 retains its named defects and acceptance tests. New findings
receive a scope/impact decision: a reachable unresolved blocker still blocks its affected change;
an adjacent issue does not automatically freeze unrelated measurement, CI, or extraction work.
Accepted residuals need the existing owner/ADR process, not unilateral dismissal by the implementer.

Items 0, 1, and 5 can proceed in separate worktrees when their edits do not overlap. Capture a
versioned baseline after item 1 before changing prompts, hooks, or review policy. Diagnostic logging
may start earlier, but test-polluted or integrity-invalid runs are labelled and excluded from quality
yield claims. Item 2a and item 6 can then proceed while the remaining ledger sample accumulates;
separate before/after cohorts by code, prompt, policy, harness, and routing revision. Items 8 and 9
wait for their evidence and operator decision. Numbers and line references from 0827 below are
historical measurements, not current performance targets.

## Execution order and acceptance

| # | Item | Class | Evidence / settling check |
|---|------|-------|---------------------------|
| 0 | **Bounded gate-integrity tranche:** reconcile #713, #622, then #553, #570, #576, #742, #563 against merged code and residual ADRs. For each remaining change, name the violated invariant and supported threat model before implementing. Use a focused design rather than adding one command-spelling exception per review. Integrate the minimum end-to-end cases from item 12 with each fix. | hard | The original failure is exercised through the affected entry point and refused before the effect; intended use and recovery still work. Record fixed, still-blocking, and owner-accepted residuals separately. Closure is not a claim of complete protection against arbitrary operator-shell code. |
| 1 | **Routing health and clean measurement:** verify Grok preflight under Bash/zsh (#556) and the existing fallback chain; resolve Droid authentication or change the fallback only by explicit operator configuration. Isolate test writers from BOTH `~/.claude/homunculus/dispatch-log.jsonl` and `.claude/bypass-log.jsonl`. Cover the whole shell suite, including `test-droid-escalation.sh`, `test-cli-retry.sh`, `test-dispatch-skipped-status.sh`, `test-pre-impl-deliberation-exempt.sh`, `test-codex-premerge-warn.sh`, `test-gate-untrusted-cd.sh`, and `test-relevant-check-status.sh`. | hard | Existing routes resolve as configured under the supported shells, or report an honest unavailable state. The full suite causes zero growth in either live log; test events go to isolated fixtures. Re-measure only after both writer sets are isolated. |
| 2 | **Review-yield ledger spike:** extend the existing metrics/history rather than build a second orchestration system. Record unique confirmed defects, duplicates, disputed/false-positive findings, downstream escapes, elapsed time and available token/cost data. Distinguish local Litmus from GitHub-bot reviews, commit from PR mode, iteration/run resets, actual backend/model, prompt/policy revision, harness, and effective route revision. Separate review findings from cancellation, timeout, auth and other infrastructure failures. Track whether a fix introduced the next defect and whether the worker needed operator rescue. | hard | Capture and retain the pre-change baseline; define adjudication and missing-data handling before comparing cohorts. Self-reported model confidence is not measured precision. A long review or many findings alone proves neither quality nor waste. |
| 2a | **Litmus convergence contract:** make one executable prompt source authoritative. At the checkpoint, `init-review-loop.sh` embeds commit/PR prompts limiting each iteration to three new issues, while `prompt_template.txt` asks for all findings upfront; `run-review-loop.sh` reads the state-file prompt. Replace drip-feeding with all known actionable findings within the output budget and an explicit incomplete-report state when necessary. Reuse the concrete-trigger/evidence principles already in `agents/code-reviewer.md`. Reuse existing history/dedup/stall machinery; distinguish finding validity, scope, and the smallest adequate fix. A follow-up review verifies fixes/regressions and may raise newly evidenced material defects; reopening a settled disposition requires new evidence or changed assumptions. | hard; after baseline capture | Tests exercise the prompt actually emitted and consumed, not only an unused template. Fixtures cover a clean diff, multiple upfront findings, incomplete output, a disputed finding, a real regression, and unchanged previously adjudicated findings. Incomplete review and unresolved blockers never become automatic PASS. Preserve current severity/authorization behavior; changes to it belong to item 8. |
| 3 | **Hook fan-out reduction:** disable both `continuous-learning-v2` `observe.sh` hooks and prune non-contained, side-effect-free ECC hooks after confirming their consumers. Preserve contained gates; `ECC_DISABLED_HOOKS` is not their off-switch. Archive `~/.claude/homunculus/` except the live dispatch log only after item 1. | hard | Paired per-tool-call measurements on the same workload, with installed versions recorded; verify gate outcomes and required artifacts are unchanged. The 0827 reference was 14 PreToolUse processes, about 1.5s CPU/300ms wall per Bash call, not a current baseline. Amend ADR 0046 and 0048 D1. |
| 4 | **Separate copier retirement from content pruning.** First inventory the copier's callers and prove disabling `~/.claude/scripts/sync-upstream.sh` does not remove a runtime dependency; keep shipped files, `.upstream-sources.json`, both provenance/schema tests, and an explicit manual upstream-update route. If that proof is missing, leave the copier in place. Content deletion/externalization remains gated on the complete transitive consumer inventory required by #775: every surviving `sync` entry classified as `live:<chain>`, `unreferenced`, or `dead`, following hooks, skills, commands, agents, workflows, package scripts and their references to a fixpoint. | hard; revised precondition | Retirement-only change proves runtime parity and that retained provenance tests actually run; update their obsolete copier-remediation text. Before pruning, zero unknown inventory rows and tests with candidates moved aside. The 0827 inventory had 235 entries; regenerate it rather than assuming that count. Preserve provenance and generate `THIRD_PARTY_NOTICES` for shipped content. Amend ADR 0014/0048 D6 explicitly; an upstream fix missed by the manual/on-demand route is a revisit trigger. |
| 5 | **CI reliability and sharding, early:** record per-test durations; require dependencies for supported portability cases (including zsh) and expose sub-case skips, not only a suite's final line. Then use a duration-balanced matrix with one aggregate check still named `shell-tests`, `if: always()`, rejecting failed/cancelled/missing required shards. Update `.github/required-checks.lock` together. Address dependency-install latency separately from actual lint/test failures. Folds #632. | hard; parallel with non-overlapping integrity work | Same required test inventory before/after; required portability cases run or the job fails clearly. Aggregate reports on every PR; an unexpectedly skipped required shard cannot count as success. Prove lock parity and measure actual durations, rather than reusing the historical 14.9-minute baseline. |
| 6 | **Extract orchestration mechanics, not routing policy:** move pr-grind's Dispatcher Loop into testable scripts first; later blueprint-review, council, and Litmus. Keep the existing stage/role mapping and `busdriver.json` resolution. SKILLs retain entry conditions, essential decisions, outputs and recovery; executable mechanics become scripts/tests, historical issue caveats live in linked ADR/reference material rather than mandatory per-run context. #547/#662 remain separate reliability work. | hard; incremental | Semantic/output parity for shell state, cancellation, retries, partial output, resolved roles and gate decisions. No byte-for-byte requirement for implementations and no new free-form dispatch authority. Measure mandatory context and workflow outcomes before/after. |
| 7 | **Configured read-cost experiment, not a universal new gate:** retain existing read-lane assignments. Evaluate the 200-line Agy-read proposal on an explicit opt-in cohort appropriate to the pipeline worker; do not force Claude, OMP, and Cursor through the same cost policy or let them select a new provider ad hoc. Keep direct bounded reads and existing trust/data-egress restrictions. Any enforcement remains a cost control, with advisory behavior on infrastructure failure, not a security boundary. | experiment; default change needs evidence | Compare total elapsed time, primary-agent tokens, available total cost, citation accuracy, and rereads caused by missing context. Verify ordinary reads remain possible when the helper is unavailable. Move read doctrine into the runtime brief only when the selected policy is settled. Retain legacy Pi lane code/config until item 10 establishes whether it is still used. Explicitly amend ADR 0034/0040 for any behavior change. |
| 8 | **Calibrate policy from effective behavior:** do not silently tighten or relax severity. At the checkpoint, `merge-findings.py` blocks qualifying LLM `medium` in iterations 1–2 and treats it as advisory from iteration 3; SAST/lint blocking findings remain blocking. Pin that baseline in tests, including run reinitialization and commit/PR modes. Adjudicate the proposed stratified 20 medium-only FAIL sample against item 2, supplemented by escalated/disputed high findings; predeclare thresholds and keep incomparable prompt cohorts separate. CodeScene: evaluate one final advisory ack state instead of per-event acks, with one debt umbrella for #759 #733 #725 #716 #700 #637 #590 #564. | needs Chris after data | Explicit decision on impact, reachable trigger, evidence and repair cost, not merely finding frequency or iteration count. A true finding does not automatically justify its suggested architecture. Disputed blockers remain unresolved until the established decision process settles them; no retry-count auto-approval or blanket issue closure. Amend ADR 0012 for the CodeScene decision. |
| 9 | **Passive-doc pilot, not extension-only exemption:** evaluate lighter medium handling and a bounded pr-grind round for genuinely passive prose. `CLAUDE.md`, SKILL/agent instructions, executable examples and documents changing trust, routing, gates or acceptance criteria are behavior-affecting even when Markdown. #774 is a cost example, not proof that every docs review was unnecessary. ADR 0044 remains the starting point. | exploratory; needs policy decision | Classifier fixtures include passive prose and operational Markdown. Keep every lock-required check reporting and required evidence intact. Reaching the round budget with a blocker stops/escalates; it does not authorize merge. Measure before/after only for eligible changes. |
| 10 | **Reconcile host adoption with the deployed workflow:** inventory the existing Claude Code, OMP and Cursor-agent Busdriver adapters and their installed versions before continuing any Pi-replacement slice. Test their implementation of the SAME configured stages/routes and artifact contract; record host-specific enforcement gaps honestly. No new dispatcher or migration is implied. Keep Codex's configured review role and existing separate utilities. Reassess whether the historical `pi-goal-handover`/6-lite work is still needed. | reconciliation first; security changes need Chris | Per-host evidence for the same task/plan identity, resolved role/fallback, stale/missing review artifact, cancellation/resume and final authorization. No claim of host parity from loading SKILL text alone. For any retained 6-lite path, preserve clean-worktree/operator-approved-base/untrusted-patch restrictions until a separately reviewed replacement exists; do not treat sandbox naming as proof of confinement. |
| 11 | **Issue triage against current code:** retain the original candidates #516, #539, #540, #644, #661, #550, #572, #592, #560, #583, #556; skip work already completed with evidence. Classifier epic: #639 #654 #724 #767 #771 #768 #769. Dispatch/council reliability: #547 #558 #603 #662. Low: #712 #586 #508 #568. | ongoing | One settling probe or existing verified regression per closure, recorded with version. Out-of-scope findings receive a bounded disposition rather than silently expanding the active PR or being dismissed merely to obtain PASS. |
| 12 | **End-to-end integrity suite:** the minimum regressions for each item-0 fix are part of that fix's acceptance, not deferred behind the whole roadmap. Expand from those into hostile committed env, shell expansion, merge commands, diff drivers, launcher substitution and missing-CI-shard cases where the declared boundary applies. | minimum required with fixes; broader expansion exploratory | Exercise the entry point, evidence handoff and authorization outcome together, plus a valid recovery path. Preserve already accepted trust limits. Additional families are separately scoped, not an unlimited prerequisite for items 1, 2, 5 and 6. |

## ADR bookkeeping and review boundary

Implementation PRs record amendments to 0012 (item 8), 0014/0048 D6 (item 4), 0034/0040 (item 7),
and 0046/0048 D1 (item 3). This plan edit does not itself amend their runtime contracts. The revised
item-4 retirement precondition and item-7 default need explicit review, not a silent reinterpretation
of #775. Item 0 closes named residuals of 0016 rather than claiming a broader boundary.

Preserve 0006/0026's applicable trust decisions while reconciling hosts in item 10; an adapter change
that alters authority needs its own recorded decision. Keep superseded ADRs as historical records.
This amendment changes only this planning document: no `busdriver.json`, hook, gate, prompt, runner,
review marker, installed adapter, or CI setting is changed, and no independent review PASS is claimed.

## Dropped from the original audit

Retain the original exclusions: the three allegedly dangling command shims were a false positive;
bypass-log counts were test-polluted; `ECC_DISABLED_HOOKS` does not disable contained hooks; no
quarterly upstream-digest ritual; no loosening of Litmus medium solely because it occurs often.

## Historical handover — item 0 (#713), 2026-08-27

The following is the original investigation snapshot, preserved for provenance. Its pending probes,
line numbers, machine configuration and cleanup suggestions are historical, not current execution
instructions or claims about what this amendment ran. Check merged fixes and installed versions first.

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
  (`hooks/gate-scripts/pre-commit-gate.sh:50` and siblings); and the current
  `hookSpecificOutput.permissionDecision: "deny"` + `permissionDecisionReason` at exit 0
  ; and `hookSpecificOutput.permissionDecision: "ask"` at exit 0 — the disposition `hooks/gate-scripts/careful-guard.sh:2272` actually emits — which must still force the user prompt under exec form, not silently allow or deny, and which is therefore the one case that has to be driven interactively rather than under `claude -p`. Also how a
  failed spawn is treated (the `|| exit 2` fail-closed tail cannot exist in exec form — the
  disposition must live entirely inside the wrapper);
- (d) whether a committed `"disableAllHooks": true` silences hooks (if yes, that class cannot be
  closed inside the plugin: document as platform limit, file upstream, and lean on the
  operator-owned rails — `core.hooksPath` is already `~/.codex/git-hooks` on this host, and branch
  protection's required checks).

If (a)–(c) hold: ONE launch-boundary change — every contained gate registration in
`hooks/hooks.json` (the 19 `/usr/bin/env -i …` entries) moves to a launch form that a
repository-controlled `env` block cannot silence. The mechanism is NOT designed here; it is the
subject of `docs/plans/2026-08-27-hook-exec-form-713.md` (to be written and blueprint-reviewed).
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
`#622` (a conflict-free `git merge` commits without litmus because the `commit`-token pre-filter at
`hooks/gate-scripts/pre-commit-gate.sh:112-115` never fires and `git_commit()` —
`hooks/gate-scripts/lib/gitcmd_detect.py:2654`, `_scan_commit` at `:2553` — returns
`IS_GIT_COMMIT != yes` at `pre-commit-gate.sh:184`) is independent of #713 and gets its own design doc
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
