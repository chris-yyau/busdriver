---
name: orchestrator
description: >
  Use when starting any task, routing to skills, about to commit or deploy, writing new features or fixing bugs, after writing plans or design docs, debugging, doing code review, or uncertain which skill applies. Use when there is even a 1% chance a skill might apply — this is the single routing authority for superpowers, everything-claude-code, litmus, and blueprint-review.
---

# Master Orchestrator

<!-- CONTENT RULE: This file is for ROUTING DECISIONS only (trigger → route).
     The skill registry already provides skill descriptions and trigger keywords.
     DO NOT duplicate skill descriptions, command shortcut tables, or ECC hook catalogs here.
     New routes go as single rows in the Non-Pipeline Tasks table or domain-supplements.md. -->

<EXTREMELY-IMPORTANT>
YOU MUST FOLLOW THE SUPERPOWERS PIPELINE. This is not optional. This is not negotiable.

EVERY task that creates, modifies, or builds anything MUST go through the pipeline phases below.
You cannot rationalize your way out of this. "It's simple" is not an excuse. "The user just wants X" is not an excuse.

DO NOT use EnterPlanMode for feature work. EnterPlanMode bypasses the superpowers pipeline.
INSTEAD, INVOKE `busdriver:brainstorming` (Phase 1) or `busdriver:writing-plans` (Phase 2).

IF you are about to call EnterPlanMode, STOP and ask yourself:
- Have I invoked `busdriver:brainstorming`? If no → INVOKE IT NOW.
- Has brainstorming already produced a design? → INVOKE `busdriver:writing-plans`.
- EnterPlanMode is ONLY acceptable for non-pipeline tasks (see Non-Pipeline Tasks section).
</EXTREMELY-IMPORTANT>

## Architecture

Three layers, one pipeline:

1. **Superpowers Pipeline** (backbone) — Defines the process: what happens and in what order
2. **ECC + Third-Party Skills** (tools) — Domain patterns loaded as context, specialized agents DISPATCHed when triggered
3. **Gates** (enforcement) — Hook-enforced reviews that cannot be skipped

Superpowers defines WHAT happens. ECC defines HOW. Gates ensure quality. **Supplements** (`skills/supplements/`) provide additive context for targeted skills — loaded via the Supplement Loading Protocol below, not by hooks. See `skills/supplements/MANIFEST.md` for inventory and fork-edit tracking.

### Enforcement Levels

| Level | Tag | Mechanism | Can Claude bypass? |
|-------|-----|-----------|-------------------|
| **GATE** | `<!-- gate -->` | PreToolUse hook outputs `{"decision":"block"}` — harness rejects the tool call | No |
| **STRONG-GUIDANCE** | `<STRONG-GUIDANCE>` | Prompt instruction | Yes — if Claude ignores it |

### Supplement Loading Protocol

When invoking a skill or dispatching an agent, check `skills/supplements/MANIFEST.md` for **active supplements** targeting that skill/agent. If a match exists, Read the supplement file and apply its content alongside the skill. Opt-in supplements require the user's trigger phrase (listed in MANIFEST). This is prompt-level guidance, not automated — supplements are NOT injected by hooks.

## Gates (Hook-Enforced) <!-- mechanically enforced -->

All gates emit `{"decision":"block"}` via PreToolUse hooks. The harness rejects the tool call — Claude cannot bypass.

### Litmus (Pre-Commit + Pre-PR)
**Trigger:** `git commit` OR `gh pr create` in Bash
**Pre-commit (fast — 1 voice):** Blocks until `/litmus` passes → writes `.claude/litmus-passed.local` marker. Consumed after successful commit via PostToolUse. DEGRADED markers rejected. **Design-reviewed bypass:** If ALL staged files are design-reviewed specs (`.md` in `plans/`/`specs/` or basename PLAN/DESIGN/ARCHITECTURE, each with `<!-- design-reviewed: PASS -->`), Gate 2 auto-passes — codex review is redundant after 3-tier design review.
**Pre-PR (deep — multi-voice):** Blocks `gh pr create` until codex review passes. Runs codex CLI pass THEN 6 parallel review agents (guidelines, bugs, history, cross-commit, security, docs-consistency) with confidence scoring. Blocks on CRITICAL/HIGH at 80+ confidence. Accepts `.claude/pr-review-passed.local` (rejects DEGRADED/SKIPPED/BUILTIN markers). Also passes if all `base..HEAD` commits were per-commit reviewed (tracked in `reviewed-commits.local`). 4-of-6 agent quorum required; <4 agents = fail-closed. `LITMUS_PR_FAST=1` skips multi-agent (audited).
**CLI:** `BUSDRIVER_REVIEW_CLI` selects the review backend (auto/codex/gemini/droid/amp/opencode/claude/aider/builtin/none). Per-role routing via `.claude/busdriver.json` — see README for config format. Codex backend uses the official codex-plugin-cc app-server protocol when installed (stable JSON-RPC), with direct CLI fallback.
**Skip:** `.claude/skip-litmus.local` (single-use, 30s self-bypass detection) or `SKIP_LITMUS=1`
**Escalation:** 10 consecutive blocks → warn user about escape hatch. `git push` intentionally NOT gated.

### Blueprint Review (Pre-Commit + Pre-Implementation)
**Trigger:** Write/Edit of PLAN.md, DESIGN.md, ARCHITECTURE.md, or `docs/plans/*-design.md`
**Detection:** PostToolUse flags files in `.claude/design-review-needed.local.md`
**Pre-implementation:** Blocks Write/Edit/Bash(file-modifying) while unreviewed design docs exist.
**Pre-commit:** Blocks `git commit` if unreviewed docs exist. Files must contain `<!-- design-reviewed: PASS -->` marker.
**Skip:** `.claude/skip-design-review.local` (single-use, 30s self-bypass detection) or `SKIP_DESIGN_REVIEW=1`
**Staleness:** Persists across sessions. SessionStart validates entries, warns about stale ones, but does NOT auto-expire.

<CRITICAL>
To review design/plan documents, you MUST invoke the `blueprint-review` SKILL (via Skill tool).
Do NOT use `code-reviewer` agent — it cannot write the `<!-- design-reviewed: PASS -->` marker.
</CRITICAL>

### Freeze/Guard (Debugging Scope Lock)
**Trigger:** `.claude/freeze-scope.local` exists (created by systematic-debugging skill on Phase 1 entry)
**Behavior:** Blocks Write/Edit operations targeting files outside the directory specified in the state file. Infrastructure files (.claude/*, CLAUDE.md, docs/) always allowed.
**Activate:** `echo "path/to/scope" > .claude/freeze-scope.local`
**Deactivate:** `rm .claude/freeze-scope.local`
**Purpose:** Prevents agents from accidentally modifying unrelated files during focused debugging sessions.

### Skip File Protocol

Skip files (`.claude/skip-litmus.local`, `.claude/skip-design-review.local`) have a 30-second self-bypass detection. Files created within 30s are rejected and deleted — this prevents Claude from creating skip files itself to bypass gates.

**When a gate blocks and the user needs to bypass:**
1. Tell the user to create the appropriate skip file using the **full absolute path** (their terminal CWD may differ from the project):
   - Codex gate: `touch /absolute/path/to/project/.claude/skip-litmus.local`
   - Design gate: `touch /absolute/path/to/project/.claude/skip-design-review.local`
2. Wait for user confirmation
3. **You** run `sleep 32` before attempting the gated action — never ask the user to wait
4. Then retry the blocked action

Skip files are single-use (consumed after one bypass) and logged to `.claude/bypass-log.jsonl`.

## The Pipeline

### Entry Routing

| User's state | Entry | INVOKE | Then mandatory |
|---|---|---|---|
| Vague idea, exploring | Phase 1 | `busdriver:brainstorming` | → 2 → 3–6 (auto) |
| Clear requirements | Phase 2 | `busdriver:writing-plans` | → 3–6 (auto) |
| Has a plan file | Phase 3 | `busdriver:using-git-worktrees` | → 4 → 5 → 6 |
| Small specific task | Phase 4 | Execute directly | → 5 → 6 |
| Bug, test failure | Phase 4 | `busdriver:systematic-debugging` | Debug → fix → 5 → 6 |
| Write tests | Phase 4 | `/tdd` (tdd-guide agent) | Test task only |
| Not sure? | **Ask the user** | — | — |

**Auto-execution (Phases 3–6):** After plan review passes in Phase 2, the pipeline auto-continues without user pause: design-review → worktree → subagent-driven-development → verification → finishing. Halts on: design review rejection (3 attempts), baseline test failure, or task blocker requiring human input.

<STRONG-GUIDANCE>
DO NOT skip phases after your entry point. The ONLY exception is small specific tasks entering at Phase 4.
</STRONG-GUIDANCE>

### Phase 1: Discovery → `busdriver:brainstorming`
Use Skill tool, not EnterPlanMode. Load `architect` agent for complex design, domain patterns. For UI/UX: `frontend-design` (Impeccable core) + `ui-ux-pro-max` (design intelligence) + `busdriver:design-system` (token audit); load `.impeccable.md` if present. For code patterns: `busdriver:frontend-patterns`. For API boundaries: `busdriver:api-design`. Blueprint Review triggers when design doc is written. Consider `roundtable` if 2+ viable approaches.
**NEXT:** Phase 2 only. INVOKE `busdriver:writing-plans`. Do NOT start coding. After Phase 2 completes, auto-execution carries through Phases 3–6 without user pause.

### Phase 2: Planning → `busdriver:writing-plans`
Produces TDD tasks with file paths, commands, expected output. Saves to `docs/plans/`. Blueprint Review triggers on plan doc. Consider `roundtable` for unfamiliar tech or security-sensitive flows.
**AUTO-EXECUTION:** After plan review passes, writing-plans auto-continues: design-review → worktree → subagent-driven-development → verification → finishing. No user pause between phases 2–6. Stop conditions: design review rejects (3 attempts), baseline test failure, task blocker requiring human input.

### Phase 3: Worktree → `busdriver:using-git-worktrees`
Creates isolated workspace, verifies baseline tests pass.
<STRONG-GUIDANCE>Never implement on main/master without explicit user consent.</STRONG-GUIDANCE>

### Phase 4: Execution

**Choose one mode:**
| Signal | INVOKE |
|---|---|
| Want human review between batches | `busdriver:executing-plans` |
| Independent tasks, want speed | `busdriver:subagent-driven-development` |
| Multiple independent problems | `busdriver:dispatching-parallel-agents` |

#### Always-On Disciplines (No Exceptions)

- **TDD** — `busdriver:test-driven-development` (discipline: RED → GREEN → REFACTOR). For detailed coverage workflow: `busdriver:tdd-workflow` (ECC: 80%+ coverage, unit+integration+E2E). Every time.
- **Verification** — `busdriver:verification-before-completion` (discipline: no claims without fresh evidence). For comprehensive checks: `busdriver:verification-loop` (build + lint + tests).
- **Debugging** — `busdriver:systematic-debugging`: When stuck — root cause first, no blind fixes.
- **Code Review** — `busdriver:requesting-code-review` after EVERY task. DISPATCH `{lang}-reviewer` agent (e.g., `typescript-reviewer`, `go-reviewer`, `python-reviewer`, `rust-reviewer`, `cpp-reviewer`, `java-reviewer`, `kotlin-reviewer`, `flutter-reviewer`, `csharp-reviewer`). Fallback: `code-reviewer` agent. Handle feedback per `busdriver:receiving-code-review`.
- **Lesson Capture** — After review finds HIGH+ issue not anticipated in plan, save to `~/.claude/notes/lesson-review-{YYYY-MM-DD}-{slug}.md` (type: feedback).

#### Domain Skills During Execution

**Load domain patterns from `domain-supplements.md`** — detect language/framework and load the corresponding ECC skills. The full catalog is in `${CLAUDE_PLUGIN_ROOT}/skills/orchestrator/domain-supplements.md`.

**When build fails — DISPATCH immediately, do not debug manually first:**
DISPATCH `{lang}-build-resolver` agent if one exists. TS/JS: `build-error-resolver`. PyTorch: `pytorch-build-resolver`. No resolver: use `busdriver:systematic-debugging`.

**DISPATCH `tdd-guide` agent** to produce test files. The discipline governs process; the agent produces tests.

### Phase 5: Verification
Run `busdriver:verification-loop` (build + lint + tests) as the comprehensive system check. Then apply `busdriver:verification-before-completion` as the final gate — no success claims without fresh evidence. These are complementary: verification-loop runs the checks, verification-before-completion enforces the discipline. Django: `django-verification`. Spring Boot: `springboot-verification`. Also: `busdriver:security-scan` for .claude/ config.

**DISPATCH `security-reviewer` agent** if auth, user input, API endpoints, payments, or secrets were touched.

**DISPATCH selective specialists** (pr-review-toolkit, advisory) based on what changed:
- Error handling code → `silent-failure-hunter` agent
- Type definitions/interfaces → `type-design-analyzer` agent
- Tests added/modified → `pr-test-analyzer` agent

Consider `roundtable` if architecturally significant or results seem "too clean."

### Phase 6: Finishing → `busdriver:finishing-a-development-branch`
Handles: verify tests → present 4 options (merge/PR/keep/discard) → execute → clean up worktree.
**Gate:** Codex Reviewer fires automatically — fast mode at `git commit`, deep mode (multi-voice) at `gh pr create`.

## Domain Supplements

Domain skills are **additive** — load all that match. **Full catalog:** `${CLAUDE_PLUGIN_ROOT}/skills/orchestrator/domain-supplements.md`

**Quick reference:**
| Domain | Detection | Key skills |
|--------|-----------|------------|
| Go | `*.go`, `go.mod` | `golang-patterns`, `golang-testing`, `go-reviewer` agent |
| Python | `*.py` | `python-patterns`, `python-testing`, `python-reviewer` agent |
| Django | `manage.py` | `django-patterns`, `django-security`, `django-tdd` |
| Spring Boot | `pom.xml` | `springboot-patterns`, `springboot-security`, `springboot-tdd` |
| Frontend | `*.tsx`, `*.jsx` | `frontend-patterns`, `coding-standards`, `typescript-reviewer` agent, `frontend-design` + `ui-ux-pro-max` for design |
| Bun | `bun.lock`, `bunfig.toml` | `bun-runtime` |
| Backend | API routes | `backend-patterns`, `coding-standards` |
| C++ | `*.cpp`, `CMakeLists.txt` | `cpp-coding-standards`, `cpp-testing` |
| Kotlin | `*.kt`, `build.gradle.kts` | `kotlin-patterns`, `kotlin-testing`, `kotlin-coroutines-flows`, `kotlin-reviewer` agent |
| Android/KMP | `app/src/main/` | `android-clean-architecture`, `compose-multiplatform-patterns` |
| C#/.NET | `*.cs`, `*.csproj` | `dotnet-patterns`, `csharp-testing`, `csharp-reviewer` agent |
| Flutter/Dart | `*.dart`, `pubspec.yaml` | `dart-flutter-patterns`, `flutter-dart-code-review`, `flutter-reviewer` agent, `dart-build-resolver` agent |
| Rust | `*.rs`, `Cargo.toml` | `rust-patterns`, `rust-testing`, `rust-reviewer` agent |
| Swift | `*.swift` | `swiftui-patterns`, `swift-concurrency-6-2`, `liquid-glass-design`, `foundation-models-on-device` |
| NestJS | `@nestjs/core` | `nestjs-patterns` |
| Database | SQL, migrations | `postgres-patterns`, `database-migrations`, `clickhouse-io`, `database-reviewer` agent |
| DevOps | Dockerfile, CI/CD | `docker-patterns`, `deployment-patterns` |
| AI/LLM | LLM calls, RAG, PyTorch | `cost-aware-llm-pipeline`, `iterative-retrieval`, `pytorch-patterns` |
| Crypto/DeFi | Solidity, EVM, AMM | `defi-amm-security`, `evm-token-decimals`, `llm-trading-agent-security` |
| Healthcare | EMR, HIPAA, PHI | `healthcare-emr-patterns`, `hipaa-compliance`, `healthcare-reviewer` agent |
| Nuxt | `nuxt.config.*` | `nuxt4-patterns` |
| Perl | `*.pl`, `*.pm` | `perl-patterns`, `perl-security`, `perl-testing` |
| PHP/Laravel | `*.php`, `composer.json` | `laravel-patterns`, `laravel-security`, `laravel-tdd` |
| Supply Chain | freight, inventory, customs | `carrier-relationship-management`, `inventory-demand-planning`, `customs-trade-compliance` |

## Non-Pipeline Tasks

These tasks don't follow the full pipeline — they enter at a specific phase or run independently. Routes below use Skill tool unless marked "agent" (use Agent tool) or "command" (use `/name`).

| Task | Trigger keywords | Route(s) |
|------|-----------------|----------|
| **Refactoring** | cleanup, dead code | `refactor-cleaner` agent |
| **Authentication** | login, signup, OAuth | `security-review` |
| **UI/UX Design** | design, UI review, make it look better, styling | `frontend-design` + `ui-ux-pro-max` + `busdriver:design-system`. Load `.impeccable.md` if present |
| **Design Setup** | impeccable, design context, brand setup | `/teach-impeccable` (one-time → `.impeccable.md`) |
| **Design Refinement** | polish, critique, audit UI, animate, make bolder/quieter | Impeccable commands: `/polish`, `/critique`, `/audit`, `/normalize`, `/harden`, `/distill`, `/clarify`, `/colorize`, `/bolder`, `/quieter`, `/delight`, `/animate`, `/overdrive`, `/arrange`, `/extract`, `/typeset`, `/adapt`, `/optimize`, `/onboard` |
| **Skill Creation** | create/edit skill | `busdriver:writing-skills` |
| **API Design** | REST endpoints, API versioning | `busdriver:api-design` |
| **E2E Testing** | browser testing, e2e | `/e2e` command + `e2e-testing` skill |
| **Verification** | verify, build+lint+test | `/verify` command |
| **Test infrastructure** | test setup, scaffold tests, add tests | `test-setup` |
| **Research** | search for libraries | `busdriver:search-first` |
| **Deep Research** | research X thoroughly, cited reports | `busdriver:deep-research` (Firecrawl + Exa) |
| **Neural Search** | semantic search, company intel | `busdriver:exa-search` |
| **Rules Distillation** | distill rules from skills | `/rules-distill` command |
| **UI State Debugging** | buttons cancel each other, UI state bugs | `busdriver:click-path-audit` |
| **Skill Auditing** | audit skills, check quality | `skill-stocktake` (quality) or `skill-comply` (compliance) |
| **Multi-Service** | monorepo, microservices | `busdriver:dispatching-parallel-agents` + `/pm2` |
| **Multi-Session Planning** | plan big project | `busdriver:blueprint` |
| **Multi-Agent** | agent pipeline, parallel teams | `/orchestrate` / `/devfleet` / `claude-devfleet` / `dmux-workflows` / `team-builder` |
| **Codex Review** | adversarial review, challenge design | `/codex:adversarial-review` command (official plugin) |
| **Codex Rescue** | delegate task to Codex | `/codex:rescue` command (official plugin) |
| **External CLI** | send to codex/gemini/droid/amp/opencode | `dispatch-cli` skill |
| **Multi-Model** | multi-model planning | `/multi-plan`, `/multi-backend`, `/multi-frontend`, `/multi-execute`, `/multi-workflow` |
| **Roundtable** | perspectives, group wisdom, tradeoffs | `roundtable` skill (4-voice: Architect + Skeptic + Pragmatist + Critic) |
| **Communication** | email triage, Slack, inbox | `chief-of-staff` agent |
| **Documents** | .docx/.xlsx/.pptx/.pdf, OCR | `nutrient-document-processing` |
| **Claude API/SDK** | imports anthropic/claude_agent_sdk | `claude-api` skill |
| **MCP Dev** | build MCP server | `mcp-server-patterns` |
| **Canary** | watch deploy, post-deploy check | `canary` skill |
| **Scheduled Agents** | cron job, run on schedule | `CronCreate`/`CronList`/`CronDelete` tools |
| **Recurring Tasks** | run every N minutes | `/loop-start` command, `loop-operator` agent |
| **Notes** | check notes health, refine | `/refine-notes` command |
| **Prompt Engineering** | optimize prompt, improve prompt | `/prompt-optimize` command (advisory only) |
| **Content** | articles, newsletters | `article-writing` / `content-engine` / `crosspost` / `x-api` |
| **Data Pipelines** | data collector, scheduled scraping | `data-scraper-agent` |
| **Fundraising** | pitch deck, investor materials | `investor-materials` / `investor-outreach` / `market-research` |
| **Media Generation** | generate image/video/audio | `fal-ai-media` |
| **Video Production** | edit video, analyze, transcribe | `videodb` / `video-editing` / `fal-ai-media` |
| **Presentations** | create slides, convert PPT | `frontend-slides` |
| **Agent Architecture** | agent loops, multi-agent DAGs | `autonomous-loops` / `continuous-agent-loop` / `enterprise-agent-ops` / `agent-harness-construction` / `agentic-engineering` / `santa-method` / `autonomous-agent-harness`. Agents: `harness-optimizer`, `loop-operator` |
| **GAN Harness** | build app iteratively, gen+eval loop | `gan-style-harness` / `/gan-design` / `/gan-build`. Agents: `gan-planner`, `gan-generator`, `gan-evaluator` |
| **Open-Sourcing** | open source this, make public | `opensource-pipeline`. Agents: `opensource-forker`, `opensource-sanitizer`, `opensource-packager` |
| **Healthcare** | EMR, clinical, PHI, CDSS | `healthcare-emr-patterns` / `healthcare-cdss-patterns` / `healthcare-phi-compliance` / `healthcare-eval-harness`. Agent: `healthcare-reviewer` |
| **Lead Intelligence** | find leads, outreach, prospects | `lead-intelligence` |
| **PRP Workflow** | PRD, plan, implement, commit, PR | `/prp-prd` / `/prp-plan` / `/prp-implement` / `/prp-commit` / `/prp-pr` |
| **Remotion Video** | create video with React, Remotion | `remotion-video-creation` |
| **Agent Payments** | x402, agent wallet, pay for API | `agent-payment-x402` |
| **Hexagonal Arch** | ports & adapters, domain boundaries | `hexagonal-architecture` |
| **Dual Review** | adversarial review, two reviewers | `/santa-loop` command |
| **UI Demo Recording** | record demo, walkthrough video | `ui-demo` |
| **Billing Ops** | subscriptions, refunds, Stripe | `customer-billing-ops` |
| **Google Workspace** | Drive, Docs, Sheets, Slides | `google-workspace-ops` |
| **Project Flow** | GitHub+Linear triage, backlog | `project-flow-ops` |
| **Workspace Audit** | audit setup, discover capabilities | `workspace-surface-audit` |
| **Laravel Plugins** | find Laravel packages | `laravel-plugin-discovery` |
| **Error Handling Review** | check error handling, silent failures, catch blocks | `silent-failure-hunter` agent (pr-review-toolkit) |
| **Type Design Review** | review types, check invariants, type safety | `type-design-analyzer` agent (pr-review-toolkit) |
| **Test Coverage Review** | check test quality, test gaps, edge cases | `pr-test-analyzer` agent (pr-review-toolkit) |
| **Code Polish** | simplify code, make clearer, refine | `code-simplifier` agent (on-demand, Opus) |
| **Docs Setup** | set up docs, audit docs, standardize docs | `busdriver:docs-setup` |
| **SEO** | SEO audit, schema markup, search visibility | `seo` / `seo-audit` / `schema-markup` / `ai-seo`. Agent: `seo-specialist` |
| **Jira** | Jira tickets, issue tracking | `/jira` command + `jira-integration` |
| **GitHub Ops** | GitHub issues, PRs, releases, CI status | `github-ops` |
| **Email Ops** | email triage, drafting, send verification | `email-ops` |
| **Messages Ops** | text messages, DMs, one-time codes | `messages-ops` |
| **Notifications** | alert routing, dedup, inbox collapse | `unified-notifications-ops` |
| **Network Ops** | X/LinkedIn cleanup, warm intros | `connections-optimizer` + `social-graph-ranker` |
| **Knowledge Ops** | knowledge base, ingestion, sync | `knowledge-ops` |
| **Research Ops** | fresh facts, comparisons, enrichment | `research-ops` |
| **Finance/Billing Ops** | revenue, pricing, refunds, billing model | `finance-billing-ops` |
| **Automation Audit** | audit jobs, hooks, connectors for overlap | `automation-audit-ops` |
| **ECC Cost Audit** | PR creation burns, quota bypass, agent cost | `ecc-tools-cost-audit` |
| **Code Tour** | CodeTour `.tour` files, onboarding walkthroughs | `code-tour` |
| **Agent Debugging** | agent failures, self-debugging workflow | `agent-introspection-debugging` |
| **Agent Sorting** | trim ECC install to what project needs | `/agent-sort` command + `agent-sort` |
| **Product Capability** | PRD-to-SRS, capability plan from spec | `product-capability` |
| **Brand Voice** | writing style profile from real posts | `brand-voice` |
| **Manim Video** | animated explainers via Manim | `manim-video` |
| **Security Bounty** | bounty-worthy vulnerability hunting | `security-bounty-hunter` |
| **Dashboard** | monitoring dashboards (Grafana, SigNoz) | `dashboard-builder` |
| **API Connector** | add API integration matching repo patterns | `api-connector-builder` |
| **Council** | 4-voice council for ambiguous decisions | `council` |
| **PR Grind** | grind PR, fix CI, address PR comments, PR feedback loop | `pr-grind` |
| **Performance Bench** | benchmark, measure performance baseline | `benchmark` |
| **Browser QA** | visual testing, UI interaction verification | `browser-qa` |
| **Post-Deploy Monitor** | watch URL after deploy, canary monitor | `canary-watch` |
| **Product Validation** | validate why before building, product check | `product-lens` |
| **Product Naming** | name product, brand name, feature name | `product-naming` |
| **Repo Scan** | audit files, asset scan, classify codebase | `repo-scan` |
| **Safety Guard** | production safety, prevent destructive ops | `safety-guard` |
| **Token Budget** | context budget advice, token usage | `token-budget-advisor` |
| **ADRs** | architecture decision record, capture decision | `architecture-decision-records` |
| **Agent Eval** | compare agents, agent benchmark, head-to-head | `agent-eval` |
| **AI Regression** | AI regression testing, sandbox mode | `ai-regression-testing` |
| **Visa Translation** | translate visa docs, immigration documents | `visa-doc-translate` |
| **RFC Pipeline** | RFC-driven multi-agent DAG execution | `ralphinho-rfc-pipeline` |
| **Code Quality** | plankton, auto-format, lint enforcement | `plankton-code-quality` |
| **Plan Review** | review code against plan, step completion | `plan-code-reviewer` agent |
| **Performance Opt** | optimize performance, profiling, bottlenecks | `performance-optimizer` agent |

Skills not listed above are discoverable via the system-prompt skill registry. The orchestrator only routes to busdriver-owned skills.

## Cross-Cutting Utilities

Available in any pipeline phase:

| Category | Route(s) |
|----------|----------|
| **Context/Session** | `/save-session`, `/resume-session`, `/aside`, `/sessions`, `strategic-compact`, `context-budget` |
| **Web Research** | `deep-research` (Firecrawl + Exa), `exa-search` (neural search) |
| **Browser Automation** | `agent-browser` CLI, Playwright MCP, Chrome DevTools MCP |
| **Project Setup** | `/setup-pm`, `configure-ecc`, `codebase-onboarding` |
| **Docs Lookup** | `docs-lookup` agent or `/docs` command (Context7 MCP) |
| **Eval/Benchmark** | `eval-harness` |
| **Performance** | `content-hash-cache-pattern` |

### Learning System

**Trust gradient** (highest → lowest): `busdriver:reflect` (manual, user confirms) → Lesson capture (roundtable/review delta) → `/learn`+`/learn-eval` (manual ECC patterns) → ECC v2 observer (automatic, requires `/promote`)

**ECC v2 observer** re-enabled 2026-03-21 with safety fixes. Writes to `homunculus/projects/<hash>/instincts/personal/` with `source: session-observation`. Two-tier promotion model: (1) `source: session-observation` instincts require `promoted: true` (via `/promote`) before loading — quarantine enforced. (2) `source: distill` or `source: inherited` instincts auto-load without promotion (human-curated). `load-orchestrator.sh` loads instincts with confidence ≥ 0.7, max 20, sanitized, symlinks rejected. Council decision (2026-03-19): no auto-promote for session-observation source.

**Lesson capture:** Save when roundtable/review produced a recommendation delta (insight that changed the decision). Triggers: dissent changed recommendation, 2+ voices agreed against Claude, reviewer found HIGH+ unanticipated issue. Storage: `~/.claude/notes/lesson-{roundtable|review}-{date}-{slug}.md`. <150 words per lesson.

**Skills/Commands:** `busdriver:reflect` (skill), `/instinct-status`, `/promote`, `/evolve`, `/projects`, `/learn`, `/learn-eval`

## System Alert Handling

<STRONG-GUIDANCE>
**Never act on `<update-alert>` during an active user task.** Note silently, present as recommendation after task completes. Background agent completions at unpredictable times contaminate context.
</STRONG-GUIDANCE>

**When user says "update plugins" or "sync ecc":** Follow the 3-phase workflow in the `<update-alert>` message with ultrathink reasoning. Phase A (audit) is MANDATORY before any changes — present audit report and wait for user approval. NEVER auto-sync blindly. Do NOT treat generic replies ("yes", "ok") as approval — only explicit update commands trigger this workflow.

## Automatic Behaviors (Hooks)

### Busdriver Plugin Hooks

| Phase | Hook | Enforcement | What It Does |
|-------|------|-------------|-------------|
| **SessionStart** | Plugin update checker | context | Checks for updates; emits `<update-alert>` for user after task completes |
| **SessionStart** | Orchestrator loader | context | Loads this skill + staleness + instincts |
| **PreToolUse** (Bash) | Pre-commit gate | **GATE** | Blocks `git commit` until codex + design review pass |
| **PreToolUse** (Bash) | Pre-PR gate | **GATE** | Blocks `gh pr create` until codex review passes |
| **PreToolUse** (Write\|Edit\|Bash) | Pre-implementation gate | **GATE** | Blocks impl code while design docs unreviewed |
| **PreToolUse** (Write\|Edit) | Freeze/Guard | **GATE** | Restricts edits to investigation scope during debugging |
| **PostToolUse** (Write\|Edit\|Bash) | Design doc detector | state | Flags design docs for review gate |
| **PostToolUse** (Edit) | Go post-edit | formatting | gofmt/goimports/go vet on .go files |
| **PostToolUse** (Bash) | Post-commit marker | cleanup | Consumes codex marker after successful commit |
| **SessionEnd** | Auto-push config | persistence | Commits auto-generated pipeline state to remote |

Inherited hooks (from ECC upstream): quality-gate, cost-tracker, session persistence, post-edit format (JS/TS), suggest-compact, block-no-verify, auto-tmux-dev, config-protection, mcp-health-check, observe.sh (continuous learning). These run alongside gate hooks but do NOT enforce gates.

## Quick Reference

### Pipeline — INVOKE Each Phase
```
brainstorming → writing-plans → [AUTO] → design-review → worktree → execute → verify → finish
(Phase 1)       (Phase 2)       ──────────(Phase 3)───────(Phase 4)──(Phase 5)──(Phase 6)
```
After Phase 2 plan review passes, Phases 3–6 execute automatically via subagent-driven-development.

### Entry Points — Use Skill Tool, NOT EnterPlanMode
- Vague idea → `busdriver:brainstorming` → Phase 2 → auto-execute 3–6
- Clear requirements → `busdriver:writing-plans` → auto-execute 3–6
- Has plan → `busdriver:using-git-worktrees` → manual 4 → 5 → 6
- Small task → Execute directly (Phase 4)
- Bug → `busdriver:systematic-debugging`

### Always-On (No Exceptions)
- `busdriver:test-driven-development` — no code without failing test
- `busdriver:verification-before-completion` — no claims without evidence
- `busdriver:requesting-code-review` — after EVERY task

### Gates (Hook-Enforced, Cannot Bypass)
- Codex Reviewer → before `git commit` and `gh pr create`
- Blueprint Review → after plan/design docs, blocks impl + commit
- Pre-implementation → blocks file writes while design unreviewed
- Freeze/Guard → restricts edits to investigation scope during debugging

### Strong Guidance (Advisory)
- Pipeline phase ordering (1→2→3→4→5→6)
- Worktree isolation before implementation
- TDD, code review, verification disciplines

### ECC Skill/Command Resolution

| Interface | Syntax | Example |
|-----------|--------|---------|
| **Skill** | `busdriver:name` via Skill tool | `busdriver:golang-patterns` |
| **Command** | `/name` via Skill tool | `/go-review`, `/tdd`, `/verify` |
| **Agent** | DISPATCH via Agent tool with `subagent_type` | `go-reviewer`, `typescript-reviewer` |

### Document Precedence
1. SKILL.md routing sections (authoritative)
2. domain-supplements.md (language/framework detection)
3. System-prompt skill descriptions (fallback)

**Namespace:** `busdriver:` is this plugin's namespace. Unprefixed skills in this file are also busdriver-owned.

### Pipeline Self-Maintenance
Commit and push changes to `~/.claude/hooks/`, `~/.claude/skills/`, or `${CLAUDE_PLUGIN_ROOT}/` before ending session.

### Key Principle
Superpowers = process (INVOKE the skills). ECC = domain tools (DISPATCH agents, load patterns). Gates = enforcement (run automatically).
