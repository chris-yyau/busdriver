# Non-Pipeline Tasks Catalog

> **Read this file** when the user's request doesn't match a Pipeline phase or Domain Supplement in `SKILL.md`. This catalog lists busdriver-owned tasks that enter at a specific point or run independently.
>
> **Skill auto-discovery:** Skills not listed here are still discoverable via the system-prompt skill registry — Claude sees all 200+ skill names + descriptions automatically. This catalog only adds value where (a) trigger keyword → skill mapping is non-obvious, or (b) curated multi-skill groupings beat picking single skills.

## Routes

Use Skill tool unless marked "agent" (Agent tool) or "command" (`/name`).

| Task | Trigger keywords | Route(s) |
|------|-----------------|----------|
| **Refactoring** | cleanup, dead code | `refactor-cleaner` agent |
| **Authentication** | login, signup, OAuth | `security-review` |
| **UI/UX Design** | design, UI review, make it look better, styling | `impeccable:impeccable` + `ui-ux-pro-max` + `busdriver:design-system`. Load `.impeccable.md` if present |
| **Design Setup** | impeccable, design context, brand setup | `impeccable:shape` (one-time → `.impeccable.md`) |
| **Design Refinement** | polish, critique, audit UI, animate, make bolder/quieter | Impeccable commands: `/polish`, `/critique`, `/audit`, `/normalize`, `/harden`, `/distill`, `/clarify`, `/colorize`, `/bolder`, `/quieter`, `/delight`, `/animate`, `/overdrive`, `/arrange`, `/extract`, `/typeset`, `/adapt`, `/optimize`, `/onboard` |
| **Skill Creation** | create/edit skill | `busdriver:writing-skills` |
| **API Design** | REST endpoints, API versioning | `busdriver:api-design` |
| **E2E Testing** | browser testing, e2e | `/e2e` command + `e2e-testing` skill |
| **Verification** | verify, build+lint+test | `/verify` command |
| **Repo pipeline setup** | test setup, scaffold tests, CI pipeline, Codecov, pinact | `helmet` (personal skill) |
| **Research** | search for libraries | `busdriver:search-first` |
| **Deep Research** | research X thoroughly, cited reports | `busdriver:deep-research` (Firecrawl + Exa) |
| **Neural Search** | semantic search, company intel | `busdriver:exa-search` |
| **Rules Distillation** | distill rules from skills | `/rules-distill` command |
| **UI State Debugging** | buttons cancel each other, UI state bugs | `busdriver:click-path-audit` |
| **Skill Auditing** | audit skills, check quality | `skill-stocktake` (quality) or `skill-comply` (compliance) |
| **Multi-Service** | monorepo, microservices | `busdriver:dispatching-parallel-agents` + `/pm2` |
| **Multi-Session Planning** | plan big project | `busdriver:blueprint` |
| **Multi-Agent** | agent pipeline, parallel teams | `/orchestrate` / `/devfleet` / `claude-devfleet` / `dmux-workflows` / `team-builder` |
| **Codex Adversarial** | adversarial review, challenge design | `/codex:adversarial-review` (official plugin) |
| **Codex Rescue** | delegate task to Codex | `/codex:rescue` (official plugin) |
| **Codex Goal Loop** | iterative Codex handover with declarative pass/fail verifiers (tests/lint/typecheck), result returns to CC. Foreground only — for fire-and-forget use TUI `codex` + `/goal` | `/busdriver:codex-goal` (verifier-led; skill `codex-goal-handover`) |
| **External CLI** | send to codex/agy/droid | `dispatch-cli` |
| **Multi-Model** | multi-model planning | `/multi-plan`, `/multi-backend`, `/multi-frontend`, `/multi-execute`, `/multi-workflow` |
| **Council** | perspectives, group wisdom, tradeoffs, ambiguous decision, structured deliberation | `council` (5-voice: Architect + Skeptic + Pragmatist + Critic + Researcher) |
| **Communication** | email triage, Slack, inbox | `chief-of-staff` agent |
| **Documents** | .docx/.xlsx/.pptx/.pdf, OCR | `nutrient-document-processing` |
| **Claude API/SDK** | imports anthropic/claude_agent_sdk | `claude-api-patterns` |
| **MCP Dev** | build MCP server | `mcp-server-patterns` |
| **Canary** | post-deploy canary check | `canary` |
| **Scheduled Agents** | cron job, run on schedule | `CronCreate`/`CronList`/`CronDelete` |
| **Recurring Tasks** | run every N minutes | `/loop-start`, `loop-operator` agent |
| **Notes** | check notes health, refine | `/refine-notes` |
| **Prompt Engineering** | optimize prompt, improve prompt | `prompt-optimizer` skill or `/prompt-optimize` (advisory) |
| **Content** | articles, newsletters, blogs | `article-writing` / `content-engine` / `crosspost` / `x-api`. If the personal `humanizer` skill is installed (`~/.claude/skills/humanizer/`), run it as a final pass before publishing to strip AI tone |
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
| **Dual Review** | adversarial review, two reviewers | `/santa-loop` |
| **UI Demo Recording** | record demo, walkthrough video | `ui-demo` |
| **Billing Ops** | subscriptions, refunds, Stripe | `customer-billing-ops` |
| **Google Workspace** | Drive, Docs, Sheets, Slides | `google-workspace-ops` |
| **Project Flow** | GitHub+Linear triage, backlog | `project-flow-ops` |
| **Workspace Audit** | audit setup, discover capabilities | `workspace-surface-audit` |
| **Laravel Plugins** | find Laravel packages | `laravel-plugin-discovery` |
| **Error Handling Review** | check error handling, silent failures, catch blocks | `silent-failure-hunter` agent |
| **Type Design Review** | review types, check invariants, type safety | `type-design-analyzer` agent |
| **Test Coverage Review** | check test quality, test gaps, edge cases | `pr-test-analyzer` agent |
| **Code Polish** | simplify code, make clearer, refine | `code-simplifier` agent |
| **Code Architecture Improvement** | deepen design, find architectural opportunities | `improve-codebase-architecture` |
| **Docs Setup** | set up docs, audit docs, standardize docs | `busdriver:docs-setup` |
| **SEO** | SEO audit, schema markup, search visibility | `seo` / `seo-audit` / `schema-markup` / `ai-seo`. Agent: `seo-specialist` |
| **Jira** | Jira tickets, issue tracking | `/jira` + `jira-integration` |
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
| **Terminal Ops** | run commands, execute, deploy, repo ops | `terminal-ops` |
| **AI-First Engineering** | AI agents generating code, eval-first | `ai-first-engineering` |
| **Git Workflow** | branching, commit conventions, PR process | `git-workflow` |
| **Hookify Rules** | create hookify rule, prevent behavior | `hookify-rules` |
| **Agent Sorting** | trim ECC install to what project needs | `/agent-sort` + `agent-sort` |
| **Product Capability** | PRD-to-SRS, capability plan from spec | `product-capability` |
| **Brand Voice** | writing style profile from real posts | `brand-voice` |
| **Manim Video** | animated explainers via Manim | `manim-video` |
| **Security Bounty** | bounty-worthy vulnerability hunting | `security-bounty-hunter` |
| **Dashboard** | monitoring dashboards (Grafana, SigNoz) | `dashboard-builder` |
| **API Connector** | add API integration matching repo patterns | `api-connector-builder` |
| **PR Grind** | grind PR, fix CI, address PR comments, PR feedback loop | `pr-grind` |
| **Performance Bench** | benchmark, measure performance baseline | `benchmark` |
| **Browser QA** | visual testing, UI interaction verification | `browser-qa` |
| **Post-Deploy Monitor** | watch URL after deploy, canary monitor | `canary-watch` |
| **Product Validation** | validate why before building, product check | `product-lens` |
| **Product Naming** | name product, brand name, feature name | `product-naming` |
| **Repo Scan** | audit files, asset scan, classify codebase | `repo-scan` |
| **Safety Guard** | production safety, prevent destructive ops | `safety-guard` |
| **GateGuard** | force fact-gathering before edits/writes | `gateguard` + `scripts/hooks/gateguard-fact-force.js` (opt-in) |
| **Token Budget** | context budget advice, token usage | `token-budget-advisor` |
| **Caveman Mode** | ultra-compressed output, save tokens | `caveman` skill or `/caveman` toggle |
| **ADRs** | architecture decision record, capture decision | `architecture-decision-records` |
| **Agent Eval** | compare agents, agent benchmark, head-to-head | `agent-eval` |
| **AI Regression** | AI regression testing, sandbox mode | `ai-regression-testing` |
| **Visa Translation** | translate visa docs, immigration documents | `visa-doc-translate` |
| **RFC Pipeline** | RFC-driven multi-agent DAG execution | `ralphinho-rfc-pipeline` |
| **Code Quality** | plankton, auto-format, lint enforcement | `plankton-code-quality` |
| **Plan Review** | review code against plan, step completion | `plan-code-reviewer` agent |
| **Performance Opt** | optimize performance, profiling, bottlenecks | `performance-optimizer` agent |
| **Accessibility** | WCAG, a11y, screen reader, aria | `accessibility`. Agent: `a11y-architect` |
| **Continuous Learning** | extract patterns, session learning | `continuous-learning` (v1) / `continuous-learning-v2` (instinct-based) |
| **Frontend Design** | design-led UI, visual direction, typography | `frontend-design` |
| **NanoClaw REPL** | session-aware nanoclaw, persistent project memory | `nanoclaw-repl` |
| **Project Memory** | per-project persistent memory | `ck` |
| **OpenClaw Persona** | AI Agent persona forge | `openclaw-persona-forge` |
| **Plan Stress-Test** | grill the plan, hostile interview | `grill-me` (general) / `grill-with-docs` (docs-grounded) |

## Cross-Cutting Utilities

Available in any pipeline phase:

| Category | Route(s) |
|----------|----------|
| **Context/Session** | `/save-session`, `/resume-session`, `/aside`, `/sessions`, `strategic-compact`, `context-budget` |
| **Web Research** | `deep-research` (Firecrawl + Exa), `exa-search` (neural search) |
| **Browser Automation** | `agent-browser` CLI, Playwright MCP, Chrome DevTools MCP |
| **Project Setup** | `/setup-pm`, `configure-ecc`, `codebase-onboarding` |
| **Docs Lookup** | `docs-lookup` agent or `/docs` (Context7 MCP) |
| **Eval/Benchmark** | `eval-harness` |
| **Performance** | `content-hash-cache-pattern` |

## Learning System

**Trust gradient** (highest → lowest): `busdriver:reflect` (manual, user confirms) → Lesson capture (council/review delta) → `/learn`+`/learn-eval` (manual ECC patterns) → ECC v2 observer (automatic, requires `/promote`).

**ECC v2 observer** writes to `~/.claude/homunculus/projects/<hash>/instincts/personal/` with `source: session-observation`. Quarantine: `session-observation` requires `/promote` before loading; `distill`/`inherited` auto-load. `load-orchestrator.sh` loads instincts with confidence ≥ 0.7, max 20.

**Lesson capture:** Save when council/review produced a recommendation delta. Path: `~/.claude/notes/lesson-{council|review}-{date}-{slug}.md`. <150 words.

**Skills/Commands:** `busdriver:reflect`, `/instinct-status`, `/promote`, `/evolve`, `/projects`, `/learn`, `/learn-eval`.
