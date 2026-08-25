# DESIGN — Align live Claude model routes with the Opus-only work policy (#747)

**Status:** implemented on this branch (rev 6, design-reviewed PASS after rounds 1–5) · **Issue:** #747 · **Base:** `0899cb21` · **Branch:** `fix/issue-747-opus-only-routes`

> **What changed in rev 4 (scope correction).** Rev 2–3 grew the CI check from a
> metadata contract into a whole-tree route enforcer (anchors → anchor counts →
> discovery pass → watchdog anchors). Each layer needed another layer. AC4 asks for a
> **production-metadata** contract check, and rev 4 returns it to exactly that: **one
> check over agent metadata**. Protection for the *executable* defaults in B–D is not
> a second scanner — it is `.upstream-sources.json` provenance (KD7), which is this
> repo's existing, purpose-built answer to "the next sync reverts it". What that does
> and does not buy is stated as a named residual in Risks rather than overclaimed.

## Problem

One shared routing drift, not per-agent nits: live Claude routes in `commands/`,
`agents/`, and executable skills still pin or recommend Sonnet/Haiku, while the
operator policy is:

- **Every shipped default for Claude work is Opus.** Explicit env/CLI overrides are
  *outside* enforcement (KD2) — the default is the policy surface.
- The only non-Opus Claude-family exception is a **non-implementation Fable
  plan/spec/advisory role**. Three live Fable Agent dispatch sites (KD1) are **named,
  grandfathered exceptions that currently retain broader tool authority than this policy
  allows**; constraining them is follow-up 3. New Fable pins are held to the policy by
  AC4's capability check.
- **Codex routing is outside this change.** Two Codex implementation rows in the
  Ralphinho stage table (`skills/autonomous-loops/SKILL.md:462,466`) are reserved by the
  in-flight Pi replacement (`docs/plans/2026-08-23-pi-replacement.md:170`) and are
  retargeted there, not here; Codex review/gate routes are untouched.

Nothing enforces this mechanically, so the next upstream sync silently reverts it —
the same failure mode `tests/test-agent-effort-tiers.sh` and the `.upstream-sources.json`
`ecc` note jointly prevent for `effort:`. This change reuses **both** of those existing
mechanisms rather than inventing a third.

## AC1 — Inventory of live non-historical Claude model-selection surfaces

All paths are repo-relative. **AC1 is inventory; the KD* sections are the change
contract** — where a line appears in both, the KD wins.

### A. Agent frontmatter pins (`model:`)

`agents/*.md` (46 files): **34 × `sonnet`**, **1 × `haiku`** (`doc-updater`), 11 `opus`.

sonnet: a11y-architect, agent-evaluator, build-error-resolver, code-explorer,
code-reviewer, code-simplifier, comment-analyzer, conversation-analyzer, e2e-runner,
fastapi-reviewer, go-build-resolver, go-reviewer, harness-optimizer, loop-operator,
marketing-agent, mle-reviewer, opensource-forker, opensource-packager,
opensource-sanitizer, plan-code-reviewer, pr-grinder, pr-test-analyzer, python-reviewer,
pytorch-build-resolver, react-build-resolver, react-reviewer, refactor-cleaner,
rust-build-resolver, rust-reviewer, seo-specialist, silent-failure-hunter, tdd-guide,
type-design-analyzer, typescript-reviewer.

Skill-embedded agent (**currently unvalidated** — `validate-agents.js:9` hardcodes
`agents/`), and the only one in the tree:
`skills/continuous-learning-v2/agents/observer.md:4` → `model: haiku`.

**Prose scope:** no file under `agents/` mentions `sonnet`/`haiku` outside its
frontmatter `model:` line, so those 35 pins need no companion edits. That does not
extend to the skill-embedded agent — `observer.md:3` and
`skills/continuous-learning-v2/agents/start-observer.sh:5` both carry "Uses Haiku …
cost-efficiency" prose and are listed in C.

### B. Command routes

| File | Drift |
|---|---|
| `commands/model-route.md:2,11,15-17,19-24` | description, `--budget` flag, three-tier heuristic, "fallback model" output field |
| `commands/evolve.md:168` | generated-agent template emits `model: sonnet` |

### C. Executable skill routes

| File(s) | Drift |
|---|---|
| `skills/autonomous-loops/SKILL.md` — the `# Implement with Sonnet` comment at `:83`, the Sonnet stage rows (`:460`, `:463`, `:464`), the Haiku tiering example (`:573-576`), and **every `claude -p` example in the file** | The examples are pinned to `--model opus` rather than carved out: an unpinned `claude -p` inherits the session model, which is the same inherited-selection the validator rejects for agents, so leaving eleven of them unpinned would contradict the invariant this change states. Codex-cell invariant in AC2. |
| `skills/agentic-engineering/SKILL.md:3,16,35-36,64` | the cost-tiering **thesis**, not only the two banned names (KD8) |
| `skills/prompt-optimizer/SKILL.md:182-185,222,384` | model-recommendation table |
| `skills/subagent-driven-development/SKILL.md:99-133,144,148` (`## Model Selection` **plus** the tier-escalation instructions outside it), `implementer-prompt.md:8-9,76`, `task-reviewer-prompt.md:13-14,171` | "least powerful model", "cheapest tier", "re-dispatch with a more capable model", `[MODEL]` placeholders — names no banned model (KD8) |
| `skills/pr-grind/SKILL.md:42-49,1391`, `skills/pr-grind/references/completion.md:1332`, `tests/test-pr-grinder-skill-read-scope.sh:8` | Sonnet worker + "cuts cost ~5×" / "~25k Sonnet tokens" rationale (KD6) |
| `skills/continuous-learning-v2/SKILL.md:42,94`, `agents/observer.md:3,4`, `agents/observer-loop.sh:216,251,255`, `agents/start-observer.sh:5`, `hooks/observe.sh:149`, `scripts/instinct-cli.py:1731` (all under `skills/continuous-learning-v2/`) | Haiku observer route + watchdog default, generated `model: sonnet` frontmatter, Haiku rationale comments |
| `skills/skill-comply/scripts/run.py:35-41` (**both** defaults + both help strings), `runner.py:38,40`, `grader.py:67` (`classifier_model` — the default that actually governs the classify call, since `run.py:98` calls `grade()` without it), `classifier.py:20,50`, `spec_generator.py:19,47`, `scenario_generator.py:29,47` | `claude --model` defaults + their watchdogs. (`SKILL.md:42` is **not** here — it is the `# Custom models` example demonstrating the CLI *override* path, which KD2 puts outside enforcement; see E.) |
| `hooks/gate-scripts/load-orchestrator.sh:17-23` | the comment describes the observer as a `--model haiku` subprocess, and the `exit 0` it guards **never fires**: `CLAUDE_HOMUNCULUS_INTERNAL` is read at `:21` and assigned **nowhere** in the tree (only other hit is `docs/adr/0016:100`, a mention). Flipping the observer to Opus makes that dead guard expensive — every observer subprocess would load the full orchestrator context on the more costly model. Fix both: set `CLAUDE_HOMUNCULUS_INTERNAL=1` on the same `observer-loop.sh:255` spawn line whose model default flips (beside `ECC_SKIP_OBSERVE=1 ECC_HOOK_PROFILE=minimal`), and re-point the comment at that variable |
| `scripts/harness-audit.js:633-641` | check `cost-model-route-command` scores "complexity-aware routing" / "cheap-default execution" — the advertised fix for a command whose `--budget` flag is being deleted (KD8) |
| `tests/test-agent-effort-tiers.sh:26-27,91-93` | invariant (iv) prose naming sonnet as its rationale, and the comment blessing a model-less agent as "legitimately inherits" — contradicted by AC4 check 2 |

### D. Adjacent live routes outside the three named dirs (explicit inclusion)

| File | Drift |
|---|---|
| `scripts/claw.js:17` | `DEFAULT_MODEL = env \|\| 'sonnet'` (spawns `claude -p`) |
| `scripts/lib/llm-summary.js:20,23` | `ECC_LLM_SUMMARY_MODEL \|\| 'haiku'` (`:23`); `LLM_TIMEOUT_MS` at `:20` is **lowered** 90 000 → 25 000 so the inner timeout wins (KD4) |
| `scripts/lib/agent-compress.js:113` | `frontmatter.model \|\| 'sonnet'` fallback |

### E. Deliberate exclusions (not busdriver work routes)

| Surface | Why excluded |
|---|---|
| `skills/claude-api-patterns/`, `skills/cost-aware-llm-pipeline/`, `skills/regex-vs-llm-structured-text/` | Anthropic-API reference material for the **user's own applications** |
| `skills/agent-tools/SKILL.md` | inference.sh third-party model catalog |
| `skills/plankton-code-quality/SKILL.md` | a **third-party tool's** own tiering config |
| `skills/gan-style-harness/SKILL.md:200` | narrative about harness evolution ("Sonnet-class"); its four live dispatches are already `--model opus` |
| `skills/continuous-learning/SKILL.md:115,127` | **deprecated v1**; `:115` states a fact about the third-party Homunculus project in a comparison table, `:127` is a v2 roadmap bullet — rewriting either falsifies the comparison rather than moving rationale with a pin |
| `skills/context-budget/SKILL.md:78`, `skills/writing-skills/anthropic-best-practices.md` | sample output / vendored upstream Anthropic doc |
| `scripts/hooks/cost-tracker.js` | pricing rate table |
| `skills/litmus/references/pr-review-mode.md:33,153` | **Codex gate** describing an already-disabled fallback — non-goal #2 |
| `skills/skill-comply/scripts/runner.py:17` `ALLOWED_MODELS` + `skills/skill-comply/tests/*` | **parser vocabulary, not work policy** (KD2); test-pinned at `tests/test_runner.py:130,143,169`, `tests/test_grader.py:29,40,49` |
| `skills/skill-comply/SKILL.md:41-42` (`# Custom models` example) | a demonstration of the **CLI override path**, which KD2 places outside enforcement; the models it names stay valid parser vocabulary. Keeping it accurate means keeping the two literals — it is an allowed sweep hit, not drift |
| `skills/blueprint-review/`, `skills/council/`, `skills/orchestrator/session-brief.md:41`, `commands/ultimate-council.md:10` | the four live **Fable dispatch** surfaces — Fable-by-ADR (0019/0025/0028), out of scope by non-goal #2 (KD1) |
| `scripts/lib/resolve-cli.sh:354`, `tests/test-auditor-model-config.sh:89-90`, `__tests__/transcript-context.test.ts:65-75` | third-party/provider **id vocabulary** (Vertex `claude-sonnet-4@…`, context-window classification) |
| `docs/adr/0001..0045`, `CHANGELOG.md`, `docs/plans/`, `docs/reviews/`, `*-archive/` | non-goal #1 / this review's own artifacts (a **new** ADR 0046 is added — KD3) |
| Pi/OpenCode paths, `skills/dispatch-cli` | in-flight elsewhere |

## AC2/AC3 — Change

Every surface in A–D moves to `opus`, and **prose rationale moves with the pin** (a
"cuts cost ~5× on Sonnet" sentence left behind is how the next drift starts).

**Invariants for the implementer:**

1. **Mixed tables: replace only Sonnet/Haiku cells.** In
   `skills/autonomous-loops/SKILL.md`'s Ralphinho stage table, leave
   `| Implement | Codex |` (`:462`) and `| Review Fix | Codex |` (`:466`) **verbatim** —
   `docs/plans/2026-08-23-pi-replacement.md:170` reserves exactly those two cells.
2. **Tiering semantics count, not just the two names** (KD8).
3. **Every default flip carries its watchdog** — where a watchdog can actually bind (KD4).
4. Post-rewrite contracts: `commands/model-route.md` (KD5), `skills/pr-grind` (KD6),
   the three thesis surfaces (KD8).

### KD1 — the Fable exception is scoped to *product code*; three live dispatch sites, enumerated

| Live Fable dispatch | Actual authority |
|---|---|
| `skills/blueprint-review/SKILL.md:249,251-256` arbiter | `subagent_type: general-purpose`, explicitly "needs … plus Write for `claude.json`" — a **review-artifact writer** |
| `skills/council/SKILL.md:375-383` Mythos Witness | `Agent(model="fable")` with no `subagent_type` and no tool list → inherits full default tooling |
| `skills/orchestrator/session-brief.md:41` advisor fallback | "dispatch a `fable` Agent subagent", no capability restriction |
| `commands/ultimate-council.md:10` | not a fourth site — an **entrypoint** that forces the council dispatch above |

All three are **advisory by prompt, not by capability** — `general-purpose` and a bare
`Agent(model="fable")` both inherit the full default tool set, so none of them is a
Write-only grant. Prompt text constrains behavior, not authority. They are therefore
**named, grandfathered exceptions that today exceed the policy**, not evidence that the
policy is satisfied: narrowing any of them alters a required review gate or a settled
ADR-0019/0025/0028 surface (non-goal #2), and all three are Agent-tool dispatches —
**outside AC4's domain**, which is frontmatter metadata. AC4 binds only what it can see;
constraining these three is **follow-up 3**.

### KD2 — overrides are outside enforcement (and only CLI ones are consent)

`CLAW_MODEL`, `ECC_LLM_SUMMARY_MODEL`, `ECC_OBSERVER_MODEL` and skill-comply's
`--gen-model` keep accepting any value; `--model` accepts any value **in the retained
parser vocabulary** (`runner.py:17,43-44` raise on anything else). The default is the
policy surface.

A **CLI** override is operator consent. An **env** override is not necessarily: ADR 0016's
`env -i` sanitization covers the six enforcement gates only
(`hooks/gate-scripts/lib/sanitized-gate.sh`), while `hooks/hooks.json:233` (observer, via
`observe.sh` → `start-observer.sh:203` `nohup env`, no `-i`) and `:247` (PreCompact) pass
the inherited environment through, so a committed `.claude/settings.json` `env` block can
select a cheaper model there without operator action. **Accepted as a cost/quality
residual, not an authority one** — neither route carries gate authority, reviewer
selection, or merge power. Hardening hook env is ADR 0016's domain, out of scope.
`ALLOWED_MODELS` stays the **parser's vocabulary**, deliberately distinct from the **work
policy**, so its tests pass untouched; `run.py`'s two help strings are reworded to name
the new defaults without re-listing the vocabulary.

### KD3 — a new ADR, not an edit to ADR 0009

`docs/adr/0009-agent-effort-tiers.md:50-52` records "Also rebalance model tiers broadly.
Rejected for now." This change *is* that rebalance. Non-goal #1 forbids **editing**
historical ADRs, so: **add `docs/adr/0046-opus-only-claude-work-routes.md`** (0045 is
current) recording the policy in the Problem section's exact wording, stating that it
supersedes that paragraph of ADR 0009, and naming `effort:` as the surviving cost dial.
ADR 0009 is not touched.

### KD4 — watchdogs re-sized where a watchdog can actually bind

`observer-loop.sh:251-254` already documents the coupling in-tree ("Heavier models are
slower — consider raising `ECC_OBSERVER_TIMEOUT_SECONDS`"). Flipping without re-sizing
converts a working route into a silently-killed one.

| Route | Now | After |
|---|---|---|
| `skills/continuous-learning-v2/agents/observer-loop.sh:216` `ECC_OBSERVER_TIMEOUT_SECONDS` (+ the stale "default 120s" in its `:251-254` comment) | 120s | **600s** — derived from the *floor*, not the cap: `max_turns` floors at 20 (`:221-227`), and 20 × the measured ~17s/turn is ~340s, already over a 300s budget before any Read/Write work |
| `skills/skill-comply/scripts/classifier.py:50` | 60s | **180s** |
| `spec_generator.py:47`, `scenario_generator.py:47` | 120s | **300s** |
| `skills/skill-comply/scripts/runner.py:40` | 300s | **900s** — same function whose model default flips (`:38`), driving up to 30 turns; exempting it would contradict this decision |
| `scripts/lib/llm-summary.js:20` `LLM_TIMEOUT_MS` | 90 000 | **25 000 — lowered, not raised** (below) |

**Why `LLM_TIMEOUT_MS` goes DOWN.** The whole route is bounded by a **30 000 ms outer**
timeout this change does not touch: `hooks/hooks.json:247` dispatches
`run-with-flags.js "pre:compact"`; `run-with-flags.js:214-227` takes the direct-require
fast path only when the target matches `/\bmodule\.exports\b/`, and
`scripts/hooks/pre-compact.js` has none, so `runLegacySpawn` runs it under
`spawnSync(..., { timeout: 30000 })` (`:268-283`), and `hooks/hooks.json:241-252`
registers PreCompact with no per-entry timeout. At 90 000 the **inner** timeout can never
fire first: an Opus overrun is terminated by the outer spawn (SIGTERM — `spawnSync`'s
default `killSignal`), so `pre-compact.js:82-86`'s `if (!llmSummary)` fallback **never
runs and the session file gets no compaction marker at all**. A 25 000 inner budget makes
the inner timeout win: `generateSessionSummary` returns `null` (`llm-summary.js:165-166`)
and the documented plain-log fallback actually executes. The margin is not "25 000 <
30 000" for its own sake — it is a **~5s reserve** for the hook's own preamble (stdin
read, transcript slurp) plus the fallback write that must complete after the inner
timeout fires. Raising the outer bound — widening a
shared legacy-hook cap, or giving `pre-compact.js` a `run()` export plus a per-entry
`hooks.json` timeout — is hook plumbing unrelated to model policy → **follow-up 1**.
**Named residual:** until that lands, this route has ~25s for an Opus summary and will
often fall back rather than summarize.

**All values are conservative default budgets, not proven ceilings**, and the watchdog
**semantics are unchanged** — a runaway bound, not a completion guarantee. The one
measurement taken (single-turn `claude -p --model opus`, trivial prompt, warm CLI:
**16.9s wall**, this machine, 2026-08-24) sets the order of magnitude and no more. **Only
the observer has an env override knob** (`ECC_OBSERVER_TIMEOUT_SECONDS`); the four
skill-comply values are literal `subprocess.run` arguments and `runner.py:40` is a
function default `run.py:98` never passes — they are **fixed literals, accepted as
such**, since adding env reads and a `--timeout` flag is scope this policy change does
not need. Named residual: the observer's `max_turns` auto-scales to 100 (`:217-225`), so
a worst-case batch can still be truncated at 600s; deriving the deadline from the
resolved turn count is **follow-up 2**.

### KD5 — `commands/model-route.md` post-rewrite contract

Command **kept**, no longer a cost-tier recommender:

- **description (line 2)** → "State the required model route for a task under the
  Opus-only Claude work policy."
- **`--budget low|med|high`** → **removed**.
- **Routing heuristic** → `opus` for all Claude work; `codex` outside this policy (its
  review/gate routes unchanged, and the command must not claim Codex is review/gate-only
  today — the Pi replacement owns the two reserved implementation rows);
  `fable` **only** when **all three** hold: the task is plan/spec/advisory, produces no
  product-code mutation, and needs no write tools.
- **Required Output** → the route, why it qualifies, and — for a claimed Fable route —
  **confirmation of all three conjuncts** (not a choice among them).
- **Carve-out sentence** so KD1 and KD5 read as one rule: the enumerated live Fable
  dispatch sites are grandfathered and outside this command's domain.
- **No new ad-hoc Fable dispatches until follow-up 3.** A `fable` verdict must name a
  concrete read-only dispatch form — a frontmatter-pinned agent (which AC4's capability
  check binds) or an explicit read-only **`--tools`** list the operator copies.
  `--allowedTools` is NOT such a form: it only auto-approves the tools it names and
  leaves Bash/Write/Edit reachable, whereas `--tools` limits which tools exist in the
  session at all (`skills/litmus/references/pr-review-mode.md:120`). A bare
  `Agent(model="fable")` inherits full tooling (KD1) and must not be what this command
  recommends; otherwise the command would mint new instances of the exact residual KD1
  hands to follow-up 3.
- **"fallback model" field removed** — nothing to fall back to.

### KD6 — `skills/pr-grind` post-rewrite contract

Keep the **dispatcher/worker split**; its surviving rationale is **context flattening**
and **author/reviewer separation**. Delete the cost-multiple bullet (`SKILL.md:46`),
re-point `:44`, `:1391` and `references/completion.md:1332` at `opus`, and rewrite
`tests/test-pr-grinder-skill-read-scope.sh:8` to a **context-budget** rationale rather
than a token-price one.

### KD7 — provenance is the sync-clobber mechanism for B–D

This is the load-bearing half of AC4's promise for everything that is not agent metadata.
`.upstream-sources.json` already carries the precedent verbatim on the `ecc` upstream:
`effort:` frontmatter is "permanent local policy — NEVER sync a removal", enforced by a
test. So:

1. **Extend the `ecc` note with a second, separate sentence** — not by appending `model:`
   to the `effort:` clause. The two are different shapes: `effort:` is an *additive* line
   upstream does not ship, so its rule is "never sync a removal"; `model:` is a field
   upstream **does** ship with a different value, so its rule is a **value override**:
   "`agents/*.md` also carry a local `model:` value per ADR 0046 — upstream ECC ships this
   field with weaker values; never sync a model-value change.
   `scripts/ci/validate-model-routes.js` enforces it."
2. **Add a parallel `superpowers` note** covering the SDD model-selection divergence.
3. **Flip every permanently-diverged non-agent file from `sync` to `custom`**, derived
   from the actual changed-path set (not a hand-picked seven):
   `commands/evolve.md`, `commands/model-route.md`, `scripts/ci/validate-agents.js`,
   `scripts/lib/agent-compress.js`, `scripts/lib/llm-summary.js`,
   `skills/agentic-engineering/SKILL.md`, `skills/prompt-optimizer/SKILL.md`,
   `skills/continuous-learning-v2/SKILL.md`,
   `skills/continuous-learning-v2/agents/observer-loop.sh`,
   `skills/continuous-learning-v2/agents/observer.md`, `skills/skill-comply/SKILL.md`,
   `skills/skill-comply/scripts/{classifier,grader,run,runner,scenario_generator,spec_generator}.py`,
   `skills/subagent-driven-development/{SKILL.md,implementer-prompt.md,task-reviewer-prompt.md}`.
   (`scripts/claw.js`, `scripts/harness-audit.js`,
   `skills/continuous-learning-v2/{agents/start-observer.sh,hooks/observe.sh,scripts/instinct-cli.py}`
   are already `custom`; `skills/pr-grind/SKILL.md` and
   `hooks/gate-scripts/load-orchestrator.sh` are already `local`.)
   **Each agent file retains its existing disposition** — machine-checked, `agents/*.md`
   is 20 `custom`, 24 `sync`, and **2 absent** (`pr-grinder.md`, `pr-security-backstop.md`).
   The 24 `sync` entries rely on the extended `ecc` note plus the new validator (the
   `effort:` precedent, since upstream still owns their bodies); the 20 `custom` stay
   `custom`. `agents/pr-grinder.md` is `model: sonnet`, so it is in this change's modified
   set **and** absent — it goes in step 4.
4. **Register as `local`:** `scripts/ci/validate-model-routes.js`,
   `__tests__/validate-model-routes.test.ts`, `docs/adr/0046-opus-only-claude-work-routes.md`,
   **and the five paths this branch modifies that are currently ABSENT from the manifest
   entirely** — `scripts/ci/validate-all.js`, `skills/pr-grind/references/completion.md`,
   `tests/test-pr-grinder-skill-read-scope.sh`, `tests/test-agent-effort-tiers.sh`,
   `agents/pr-grinder.md`.
   Absent is not a disposition: an unregistered path is untargetable by `sync-upstream`
   today but silently becomes targetable if a future manifest refresh adds it, and
   `validate-all.js` is the single file wiring AC4 into CI. Registering them makes the
   state declared rather than merely unexamined.

### KD8 — post-rewrite contracts for the three thesis surfaces

These carry the cheap-default thesis with **no banned token anywhere**, so only an
explicit contract fixes them:

| Surface | Replacement contract |
|---|---|
| `skills/agentic-engineering/SKILL.md:3,16,35-36,64` | description and principle 3 stop advertising "cost-aware model routing" / "route model tiers by task complexity"; the tier list becomes "Claude work runs on Opus; `effort:` is the cost dial"; `:64`'s escalate-when-cheaper-fails rule is deleted |
| `skills/subagent-driven-development/SKILL.md:99-148` + `implementer-prompt.md:8-9,76` + `task-reviewer-prompt.md:13-14,171` | `## Model Selection` becomes: Claude-family subagents run `opus`; Fable only under KD5's three conjuncts; Codex unchanged. "Always specify the model explicitly" is **kept** (it prevents silent inheritance); "least powerful"/"cheapest tier"/turn-count-vs-price paragraphs go, **and so does the "Task complexity signals" tier map (~:127-131)** — deleted, not re-labelled. The escalation paths at `:144`, `:148` and `implementer-prompt.md:76` become Opus-only recovery: more context, split the task, fix the plan, raise `effort:`, or escalate to the human — never "re-dispatch with a more capable model". `[MODEL]` placeholders become `opus`. |
| `scripts/harness-audit.js:633-642` | **delete** the `cost-model-route-command` check outright. A string rewrite would leave a `category: 'Cost Efficiency'`, `points: 3` check whose `pass` is only `fileExists('commands/model-route.md')` — and `context-model-route` (`:453-462`) already asserts that same file's presence. Scoring the *existence* of a route command as cost efficiency **is** the retired thesis. Named consequence: the Cost Efficiency subtotal drops by 3 points, so any recorded score baseline shifts. |
| `skills/prompt-optimizer/SKILL.md:181-185,222,384` | **delete** the four-row tier table (a name swap yields four Opus rows still advertising "fast, cost-efficient" / "deep reasoning for planning" tiers), the `\| Model \|` output row's tier framing, and the `:384` footer; replace with one line: "Claude work runs on `opus`; `effort:` is the cost dial." |
| `skills/autonomous-loops/SKILL.md:78-88,573-576` | the surrounding rationale goes with the pins: `:83`'s "(fast, capable)" gloss and the `:573-576` tiered-routing paragraph are deleted, not re-labelled — a "route simple tasks to Opus and complex tasks to Opus" sentence is worse than none |

## AC4 — One runnable production-metadata contract check

**One check, one mechanism, wired into the existing runner.** `scripts/ci/validate-all.js`
(run by `npm run validate`, `tests.yml:215`) gains one entry:
`validate-model-routes.js`. The model check **moves out of** `validate-agents.js` (its
`VALID_MODELS` block is deleted, not duplicated), so exactly one file owns model policy.
No per-agent fixtures.

**Scope, stated honestly:** this check binds **agent metadata** — `agents/*.md` and
`skills/*/agents/*.md`. It does not police executable defaults in B–D; KD7 is what
protects those, and Risks names what that does and does not buy. Rev 2–3 tried to make
one check do both and produced a scanner that still could not see an unpinned `claude -p`
or a newly synced file.

**Shared parser, not a third copy.** The Fable capability check is load-bearing on one
parser behavior — `validate-agents.js:25` `if (/^\s/.test(line)) continue;`, which makes an
indented/multiline `tools:` read as *absent*. `validate-agents.js` currently exports
nothing, so it gains a `module.exports` + `require.main === module` split (the shape
`scripts/ci/validate-hooks.js` already uses) and the new validator **imports**
`extractFrontmatter` from it. `scripts/ci/validate-skills.js:43` holds a pre-existing
second copy; it does no model policy and is left alone (noted, not refactored).

**Checks:**

1. **Closed whitelist, fail-closed** — never a two-literal denylist. Accepted: `opus`;
   plus `fable` for a path in `FABLE_ALLOWED`. Everything else errors, which is what makes
   a versioned or provider-prefixed id (`claude-sonnet-5`, `us.anthropic.claude-haiku-…`)
   fail too. A family classifier (`/(^|[-.])(sonnet|haiku)([-.]|$)/i`) selects the
   *message* only, never the verdict.
2. **`model:` required** across the discovery set — missing/empty errors (an unpinned
   agent inherits the session model). `REQUIRED_FIELDS` (which includes `tools`) stays
   scoped to `agents/`, so `observer.md` is not forced to invent a `tools:` list.
3. **Duplicate keys fail**: `model` on every discovered file; `tools` and `effort` on
   every Fable candidate — last-wins parsing must not decide a fail-closed check.
4. **`FABLE_ALLOWED`** — named allowlist keyed by **repo-relative path**, shipped **empty
   and frozen**.
5. **Fable capability check, fail-closed on metadata.** An allowlisted `fable` entry must
   declare a **single-line, non-empty `tools:`** whose every entry is in a **positive
   read-only allowlist** (`Read`, `Grep`, `Glob`, `WebFetch`, `WebSearch`).
   **Grammar** (all 46 live `tools:` lines are bracketed YAML arrays — 38 quoted, 8
   unquoted, zero bare comma lists — and `extractFrontmatter` hands back the literal
   text `["Read", "Grep"]`, brackets included): strip one optional enclosing `[`…`]`,
   split on commas, trim, strip one optional surrounding pair of single/double quotes per
   token, then **reject** an empty token or any residual `[`, `]`, or quote inside a
   token. Anything the grammar cannot parse is a rejection, not a pass.
   Missing, empty, or indented/multiline `tools:` is a **rejection** — an omitted `tools:`
   means *inherited full access*, so treating it as "no mutation tools" would invert the
   default. A positive allowlist also cannot be outrun by a future or plugin-provided
   mutation tool the way a five-name denylist can.
6. **Effort consistency.** An allowlisted `fable` entry must carry an explicit `effort:`
   from the closed set, `high` or below, so it cannot pass here while failing
   `tests/test-agent-effort-tiers.sh` invariant (iv) (`xhigh|max ⇒ model: opus`), which
   scans `agents/*.md` only. That test's `:26-27` rationale is reworded to "weaker
   Claude-family ids silently cap at ~high" so the two checkers agree and the sentence
   stops naming a tier.

### Durable proof — one hermetic test, no fixture pile

`__tests__/validate-model-routes.test.ts`, existing vitest lane. Seam:

```js
module.exports = { validateModelRoutes, FABLE_ALLOWED }  // ({ rootDir, fableAllowed }) -> errors[]
if (require.main === module) { /* real tree, frozen production constants */ }
```

mirroring `scripts/ci/validate-hooks.js`'s existing split. The test builds a temp
mini-tree with `mkdtempSync` — the pattern in `__tests__/gateguard-consent.test.ts`,
`path-safety.test.ts`, `run-with-flags-*.test.ts` — and injects `fableAllowed` as an
**argument**. Production constants stay frozen and empty; no env hook exists to reach the
Fable branch.

| # | Input | Expect |
|---|---|---|
| 1 | `model: opus` in `agents/` | pass |
| 2 | `model: sonnet` in `agents/`, and in `skills/x/agents/` | fail (both) |
| 3 | `model: haiku` | fail |
| 4 | `model: claude-sonnet-5` (versioned id) | fail — proves the closed whitelist |
| 5 | missing / empty `model:` | fail |
| 6 | duplicate `model:` keys | fail |
| 7 | `model: fable`, **not** allowlisted | fail |
| 8 | `model: fable`, allowlisted, `effort: high`, `tools:` in **both canonical forms** — `["Read", "Grep", "Glob"]` and `[Read, Grep, Glob]` | **pass** — proves the allowlist branch is reachable and the grammar handles the live shapes |
| 9 | same, `tools: ["Read", "Bash"]` / `["Write"]` | fail |
| 10 | same, `tools:` missing / empty / indented multiline / malformed (`["Read"`) | fail |
| 11 | same, `effort:` missing / unknown / `xhigh` / `max` | fail |
| 12 | the **shipped** `FABLE_ALLOWED` constant | asserted empty |
| 13 | `validateModelRoutes({ rootDir })` with **no `fableAllowed` argument** + a `model: fable` fixture | fail — proves the default path cannot be opened without a code change, since nothing else in the suite reads the production constant |
| 14 | `scripts/ci/validate-all.js`'s `VALIDATORS` | contains `validate-model-routes.js` — otherwise rows 2–3 of Verification both pass whether or not the wiring landed. **Assert by `readFileSync` on the file, not `require()`**: it has no library seam — `VALIDATORS` is a module-scope const, the runner loop runs at module scope, and the file ends in a bare `process.exit(...)`, so requiring it would run every validator and kill the vitest process before any assertion |
| 15 | `model: gemini` (non-family, non-fable) in `agents/` | fail — **the only case that distinguishes the closed whitelist from a two-name denylist**; cases 2–4 are all sonnet/haiku-family and would pass a denylist implementation |
| 16 | `model: opus` **with** a `tools:` containing `Bash`/`Write` | pass — the capability check binds Fable entries only; Opus agents legitimately mutate |
| 17 | a non-agent `.md` under `skills/x/` (not in an `agents/` dir) with `model: sonnet` | pass — discovery is scoped, not tree-wide |

Case 8 must pass before 9–11 mean anything: with an empty allowlist an unlisted `fable`
agent is rejected by check 4 before the capability check ever runs, so "fails on a fable
agent with Bash" would otherwise be satisfied by a check that was never implemented.

## Verification

| Step | Check |
|---|---|
| guard proven to fail **and** pass | `npx vitest run __tests__/validate-model-routes.test.ts` — the 17-case matrix (incl. case 14's CI-wiring assertion and case 15's whitelist-vs-denylist discriminator) |
| watchdog ordering | one vitest case asserting `LLM_TIMEOUT_MS` (`scripts/lib/llm-summary.js`) is **below** the outer `spawnSync` timeout **read from `scripts/hooks/run-with-flags.js`**, not hardcoded — the 25 000 value's whole purpose is that ordering, and no existing test observes either literal (`grep` over `__tests__/` and `tests/` returns none) |
| contract check on the real tree | `node scripts/ci/validate-model-routes.js` exits 0 |
| full validators | `npm run validate` |
| JS unit | `npx vitest run` |
| shell gates | `bash scripts/ci/run-shell-tests.sh` |
| python islands | `bash scripts/test-python.sh` |
| provenance | executable, not by eye: enumerate `git diff --name-only 0899cb21...HEAD` (the recorded base SHA) and assert every path resolves in `.upstream-sources.json` to `custom`, `local`, or `sync`-with-the-note (KD7). **Enumerated exception set — the only paths allowed to be ABSENT:** `.upstream-sources.json` itself (the manifest has no self-entry; verified, 1335 entries), `docs/reviews/**` (this review's own artifacts), and `docs/plans/**` (design documents are repo-local narrative and are not sync targets — this design doc ships with the PR and is deliberately *not* registered, unlike ADR 0046 which is). Any other absent changed path fails — that is what let five modified files (`validate-all.js`, `agents/pr-grinder.md` among them) go unexamined through rev 4. |
| residual sweep (one-shot, human-read) | see the fenced command below |

**Residual sweep command** (fenced, so the alternation needs no table escaping — a `\|`
inside a Markdown cell reaches `grep -E` as a *literal* pipe and matches neither model
name; `git grep` also skips `.git/`, `node_modules/` and untracked junk):

```sh
git grep -niE '(^|[^[:alnum:]_])(sonnet|haiku)([^[:alnum:]_]|$)'
```

The hyphen is **deliberately absent from the boundary class**, which is what makes a
hyphenated occurrence match: `[^[:alnum:]_]` accepts `-`, so `Sonnet-class` and
`claude-sonnet-5` are both found. An earlier form that excluded `-` from the class
(`[^[:alnum:]_-]`) missed exactly those — verified against
`skills/gan-style-harness/SKILL.md`. The AC1.E allowed-hit list does the noise
suppression instead.

**Pass condition is not zero hits** — it is that every remaining hit is an AC1.E exclusion
or a file this change adds. A zero-hit gate is unsatisfiable: `runner.py:17`,
`tests/test-auditor-model-config.sh:89-90`, `__tests__/transcript-context.test.ts:65-75`
and `scripts/lib/resolve-cli.sh:354` legitimately keep the literals. Help/default strings
naming the old models **are** in scope and must change.

## Risks

- **Enforcement is metadata-only — stated, not overclaimed.** AC4's check cannot see an
  executable default, an unpinned `claude -p`, a `--model fable` on an implementation
  route, or a newly synced file. What protects B–D is KD7 provenance — and precisely
  what that buys, read from the tool rather than assumed: `sync-upstream` is
  **maintainer-only user-level tooling that is not in this repo**, and a `custom`
  disposition makes it surface the file as CUSTOM CHANGED with a diff and a default-no
  prompt, while `--auto-sync` skips it. So it prevents *silent automated* reversion and
  makes a deliberate one visible to the maintainer; it does **not** stop a hand-written
  regression, and it does nothing at all in a clone that never runs the tool. That is the
  honest boundary of this change. Extending enforcement to executable dispatch sites is
  **follow-up 4**, not a claim made here.
- **Spend and latency on three recurring surfaces.** `pr-grind` rounds (per PR round),
  `llm-summary` (**every session compact**, still inside a 30s outer bound, degrading to
  the existing plain-log fallback when Opus overruns), and `observer-loop` (**per
  interval**, `max_turns` auto-scaled to 100 so per-run cost is not fixed) each move
  roughly an order of magnitude.
- **Consumer blast radius — a plugin-wide pin with no per-agent override.** ADR 0009:16-17
  states that "because busdriver is a plugin shipped to other users, we cannot rely on
  each consumer's global default." The same now applies to `model:`: every consumer
  inherits `opus` on all 35 flipped agents, with no agent-level equivalent of
  `CLAW_MODEL`/`ECC_OBSERVER_MODEL`; `effort:` becomes the only remaining cost dial.
  **The operator accepts this for downstream consumers** — stated so a reader can tell
  intent from oversight.
- **Unenforced residue, by decision:** env overrides on the two unsanitized hook paths
  (KD2), the Fable dispatch sites' tool authority (KD1), the observer's worst-case
  turn budget and the pre-compact 30s outer bound (KD4).

## Follow-ups (filed, not bundled)

1. Bound the PreCompact route above 30s (direct-require `run()` export + per-entry
   `hooks.json` timeout), so `LLM_TIMEOUT_MS` becomes meaningful.
2. Derive `ECC_OBSERVER_TIMEOUT_SECONDS` from the resolved `max_turns`.
3. Constrain the three Fable Agent dispatch sites' tool grants (KD1) — gate-touching, needs its
   own review.
4. Extend model-policy enforcement to executable dispatch sites if drift recurs there.

## Non-goals

No edits to existing ADRs or `CHANGELOG.md` (a **new** ADR 0046 is added — KD3), no
changes to Codex/Opus review gates, no Pi/OpenCode diff absorbed, no hook-env
sanitization (ADR 0016's domain), no refactor of `validate-skills.js`'s pre-existing
frontmatter parser, no hook-plumbing changes (follow-up 1).

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
