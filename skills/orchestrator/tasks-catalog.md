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
| **UI/UX Design** | design, UI review, make it look better, styling | Dual-engine: `busdriver:design-taste-frontend` (explore landing/marketing/portfolio/showcase) → `impeccable:impeccable` (harden; owns dashboards/app UI solo). Supplements (gap-fill only, do NOT lead): `busdriver:ui-ux-pro-max`, `busdriver:design-system`, `document-skills:frontend-design`. Load `.impeccable.md` if present |
| **Design Setup** | impeccable, design context, brand setup | `impeccable:shape` (one-time → `.impeccable.md`) |
| **Design Refinement** | polish, critique, audit UI, animate, make bolder/quieter | Impeccable commands: `/polish`, `/critique`, `/audit`, `/normalize`, `/harden`, `/distill`, `/clarify`, `/colorize`, `/bolder`, `/quieter`, `/delight`, `/animate`, `/overdrive`, `/arrange`, `/extract`, `/typeset`, `/layout`, `/adapt`, `/optimize`, `/onboard` |
| **Skill Creation** | create/edit skill | `busdriver:writing-skills` |
| **API Design** | REST endpoints, API versioning | `busdriver:api-design` |
| **E2E Testing** | browser testing, e2e | `/e2e` command + `e2e-testing` skill |
| **Verification** | verify, build+lint+test | `/verify` command |
| **Repo pipeline setup** | test setup, scaffold tests, CI pipeline, Codecov, pinact, generate/refresh CLAUDE.md, code intelligence, codegraph, code graph, structural search | `helmet` (personal skill — Phase A tests / B CI / C CLAUDE.md / D CodeGraph) |
| **Research** | search for libraries | `busdriver:search-first` |
| **Deep Research** | research X thoroughly, cited reports | `busdriver:deep-research` (multi-source synthesis: Tavily CLI for general/news, Exa MCP for neural/technical, Firecrawl CLI for deep page extraction) |
| **Web Search (general)** | news, current events, broad lookups | `busdriver:tavily-search` (fast LLM-optimized search) or `busdriver:tavily-cli` (search/extract/crawl/map/research suite — vendored Tavily CLI, free tier ~1k/mo) |
| **Web Extract / Crawl / Map** | page extract, site crawl, list site URLs, discover pages | `busdriver:tavily-cli` (or focused variants: `busdriver:tavily-extract`, `busdriver:tavily-crawl`, `busdriver:tavily-map`, `busdriver:tavily-research`, `busdriver:tavily-dynamic-search`) |
| **Scrape / Crawl / Monitor a site** | scrape page, crawl docs, download site, watch for changes, JS-rendered/interactive pages | `busdriver:firecrawl` (or focused variants: `busdriver:firecrawl-scrape`, `busdriver:firecrawl-crawl`, `busdriver:firecrawl-map`, `busdriver:firecrawl-download`, `busdriver:firecrawl-interact`, `busdriver:firecrawl-monitor`, `busdriver:firecrawl-search`, `busdriver:firecrawl-agent`, `busdriver:firecrawl-parse`) |
| **Library / API Docs** | up-to-date library docs, framework API reference, package usage | `busdriver:context7-cli` (ctx7 CLI — fetch current docs for any library) |
| **Neural Search** | code/papers, company intel, people lookup, technical content | Exa MCP (`mcp__claude_ai_Exa__web_search_exa`, `mcp__claude_ai_Exa__web_fetch_exa`) |
| **Rules Distillation** | distill rules from skills | `/rules-distill` command |
| **UI State Debugging** | buttons cancel each other, UI state bugs | `busdriver:click-path-audit` |
| **Skill Auditing** | audit skills, check quality | `skill-stocktake` (quality) or `skill-comply` (compliance) |
| **Skill Scouting** | find/evaluate external skills to adopt, vet third-party skills before adoption | `skill-scout` |
| **Multi-Service** | monorepo, microservices | `busdriver:dispatching-parallel-agents` + `/pm2` |
| **Multi-Session Planning** | plan big project | `busdriver:blueprint` |
| **Multi-Agent** | agent pipeline, parallel teams | `/orchestrate` / `claude-devfleet` / `dmux-workflows` / `team-builder` |
| **Codex Adversarial** | adversarial review, challenge design | `/codex:adversarial-review` (official plugin) |
| **Codex Rescue** | delegate task to Codex | `/codex:rescue` (official plugin) |
| **Codex Goal Loop** | iterative Codex handover with declarative pass/fail verifiers (tests/lint/typecheck), result returns to CC. Foreground only — for fire-and-forget use TUI `codex` + `/goal` | `/busdriver:codex-goal` (verifier-led; skill `codex-goal-handover`) |
| **External CLI** | send to codex/agy/droid | `dispatch-cli` |
| **Multi-Model** | multi-model planning | `/multi-plan`, `/multi-backend`, `/multi-frontend`, `/multi-execute`, `/multi-workflow` |
| **Council** | perspectives, group wisdom, tradeoffs, ambiguous decision, structured deliberation | `council` (5-voice: Architect + Skeptic + Pragmatist + Critic + Researcher) |
| **Communication** | email triage, Slack, inbox | `chief-of-staff` agent |
| **Documents** | .docx/.xlsx/.pptx/.pdf, OCR | `nutrient-document-processing` (vault) |
| **Claude API/SDK** | imports anthropic/claude_agent_sdk | `claude-api-patterns` |
| **MCP Dev** | build MCP server | `mcp-server-patterns` |
| **Canary** | post-deploy canary check | `canary` |
| **Scheduled Agents** | cron job, run on schedule | `CronCreate`/`CronList`/`CronDelete` |
| **Recurring Tasks** | run every N minutes | `/loop-start`, `loop-operator` agent |
| **Notes** | check notes health, refine | `/refine-notes` |
| **Prompt Engineering** | optimize prompt, improve prompt | `prompt-optimizer` skill or `/prompt-optimize` (advisory) |
| **Content** | articles, newsletters, blogs | `article-writing` / `content-engine` / `crosspost` / `x-api`. Run `busdriver:humanizer` as a final pass before publishing to strip AI tone (vault) |
| **Humanize Writing** | remove AI tone, sounds AI-written, de-slop text, make it sound human | `busdriver:humanizer` (detect+fix AI-writing tells: em-dash overuse, rule of three, inflated symbolism, vague attributions, filler) |
| **Data Pipelines** | data collector, scheduled scraping | `data-scraper-agent` (vault) |
| **Fundraising** | pitch deck, investor materials | `investor-materials` / `investor-outreach` / `market-research` (vault) |
| **Media Generation** | generate image/video/audio | `fal-ai-media` (vault) |
| **AI App Launcher** | run AI app/model, inference.sh, infsh, run flux/veo/grok/claude via CLI, serverless AI, OpenRouter, Twitter automation | `busdriver:agent-tools` (inference.sh CLI — 150+ AI apps: image/video/LLM/search/3D/Twitter. Broader than `busdriver:fal-ai-media`, which is media-gen only) (vault) |
| **Video Production** | edit video, analyze, transcribe | `videodb` / `video-editing` / `fal-ai-media` (vault) |
| **Presentations** | create slides, convert PPT | `frontend-slides` |
| **Agent Architecture** | agent loops, multi-agent DAGs | `autonomous-loops` / `continuous-agent-loop` / `enterprise-agent-ops` / `agent-harness-construction` / `agentic-engineering` / `santa-method` / `autonomous-agent-harness`. Agents: `harness-optimizer`, `loop-operator` (vault) |
| **GAN Harness** | build app iteratively, gen+eval loop | `gan-style-harness` / `/gan-design` / `/gan-build`. Agents: `gan-planner`, `gan-generator`, `gan-evaluator` |
| **Open-Sourcing** | open source this, make public | `opensource-pipeline`. Agents: `opensource-forker`, `opensource-sanitizer`, `opensource-packager` |
| **Healthcare** | EMR, clinical, PHI, CDSS | `healthcare-emr-patterns` / `healthcare-cdss-patterns` / `healthcare-phi-compliance` / `healthcare-eval-harness`. Agent: `healthcare-reviewer` (vault) |
| **Lead Intelligence** | find leads, outreach, prospects | `lead-intelligence` (vault) |
| **PRP Workflow** | PRD, plan, implement, commit, PR | `/prp-prd` / `/prp-plan` / `/prp-implement` / `/prp-commit` / `/prp-pr` |
| **Remotion Video** | create video with React, Remotion | `remotion-video-creation` (vault) |
| **Agent Payments** | x402, agent wallet, pay for API | `agent-payment-x402` (vault) |
| **Hexagonal Arch** | ports & adapters, domain boundaries | `hexagonal-architecture` |
| **Dual Review** | adversarial review, two reviewers | `/santa-loop` |
| **UI Demo Recording** | record demo, walkthrough video | `ui-demo` |
| **Billing Ops** | subscriptions, refunds, Stripe | `customer-billing-ops` (vault) |
| **Google Workspace** | Drive, Docs, Sheets, Slides | `google-workspace-ops` (vault) |
| **Project Flow** | GitHub+Linear triage, backlog | `project-flow-ops` (vault) |
| **Workspace Audit** | audit setup, discover capabilities | `workspace-surface-audit` |
| **Laravel Plugins** | find Laravel packages | `laravel-plugin-discovery` (vault) |
| **Error Handling Review** | check error handling, silent failures, catch blocks | `silent-failure-hunter` agent |
| **Type Design Review** | review types, check invariants, type safety | `type-design-analyzer` agent |
| **Test Coverage Review** | check test quality, test gaps, edge cases | `pr-test-analyzer` agent |
| **Code Polish** | simplify code, make clearer, refine | `code-simplifier` agent |
| **Code Architecture Improvement** | deepen design, find architectural opportunities | `improve-codebase-architecture` |
| **Docs Setup** | set up docs, audit docs, standardize docs | `busdriver:docs-setup` |
| **SEO** | SEO audit, schema markup, search visibility | `seo` / `seo-audit` / `schema-markup` / `ai-seo`. Agent: `seo-specialist` |
| **Site Audit** | audit website, site health, broken links, technical/perf/security site scan | `busdriver:audit-website` (squirrelscan CLI — 230+ rules across SEO/perf/security/content; health scores + broken-link + meta analysis. Complements `busdriver:seo` for whole-site crawl-based audits) |
| **Jira** | Jira tickets, issue tracking | `/jira` + `jira-integration` (vault) |
| **GitHub Ops** | GitHub issues, PRs, releases, CI status | `github-ops` |
| **Email Ops** | email triage, drafting, send verification | `email-ops` (vault) |
| **Messages Ops** | text messages, DMs, one-time codes | `messages-ops` (vault) |
| **Notifications** | alert routing, dedup, inbox collapse | `unified-notifications-ops` (vault) |
| **Network Ops** | X/LinkedIn cleanup, warm intros | `connections-optimizer` + `social-graph-ranker` (vault) |
| **Knowledge Ops** | knowledge base, ingestion, sync | `knowledge-ops` (vault) |
| **Research Ops** | fresh facts, comparisons, enrichment | `research-ops` (vault) |
| **Finance/Billing Ops** | revenue, pricing, refunds, billing model | `finance-billing-ops` (vault) |
| **Automation Audit** | audit jobs, hooks, connectors for overlap | `automation-audit-ops` (vault) |
| **ECC Cost Audit** | PR creation burns, quota bypass, agent cost | `ecc-tools-cost-audit` |
| **Code Tour** | CodeTour `.tour` files, onboarding walkthroughs | `code-tour` |
| **Agent Debugging** | agent failures, self-debugging workflow | `agent-introspection-debugging` |
| **Terminal Ops** | run commands, execute, deploy, repo ops | `terminal-ops` (vault) |
| **AI-First Engineering** | AI agents generating code, eval-first | `ai-first-engineering` |
| **Git Workflow** | branching, commit conventions, PR process | `git-workflow` |
| **Hookify Rules** | create hookify rule, prevent behavior | `hookify-rules` |
| **Agent Sorting** | trim ECC install to what project needs | `agent-sort` skill |
| **Product Capability** | PRD-to-SRS, capability plan from spec | `product-capability` |
| **Brand Voice** | writing style profile from real posts | `brand-voice` (vault) |
| **Manim Video** | animated explainers via Manim | `manim-video` (vault) |
| **Security Bounty** | bounty-worthy vulnerability hunting | `security-bounty-hunter` |
| **Dashboard** | monitoring dashboards (Grafana, SigNoz) | `dashboard-builder` (vault) |
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
| **Config Cleanup** | garbage-collect `~/.claude`, prune dead skills/agents/config, reduce bloat | `config-gc` (human-confirm soft-delete to trash) |
| **Caveman Mode** | ultra-compressed output, save tokens | `caveman` skill or `/caveman` toggle |
| **ADRs** | architecture decision record, capture decision | `architecture-decision-records` |
| **Agent Eval** | compare agents, agent benchmark, head-to-head | `agent-eval` |
| **Agent Self-Evaluation** | score agent output against a rubric, self-evaluate quality | `agent-self-evaluation`. Agent: `agent-evaluator` |
| **AI Regression** | AI regression testing, sandbox mode | `ai-regression-testing` |
| **Visa Translation** | translate visa docs, immigration documents | `visa-doc-translate` (vault) |
| **RFC Pipeline** | RFC-driven multi-agent DAG execution | `ralphinho-rfc-pipeline` |
| **Code Quality** | plankton, auto-format, lint enforcement | `plankton-code-quality` |
| **Plan Review** | review code against plan, step completion | `plan-code-reviewer` agent |
| **Performance Opt** | optimize performance, profiling, bottlenecks | `performance-optimizer` agent |
| **Accessibility** | WCAG, a11y, screen reader, aria | `accessibility`. Agent: `a11y-architect` |
| **Continuous Learning** | extract patterns, session learning | `continuous-learning` (v1) / `continuous-learning-v2` (instinct-based) |
| **Frontend Design** | design-led UI, visual direction, typography | `frontend-design` |
| **NanoClaw REPL** | session-aware nanoclaw, persistent project memory | `nanoclaw-repl` (vault) |
| **Project Memory** | per-project persistent memory | `ck` |
| **OpenClaw Persona** | AI Agent persona forge | `openclaw-persona-forge` (vault) |
| **Plan Stress-Test** | grill the plan, hostile interview | `grill-me` (general) / `grill-with-docs` (docs-grounded) |
| **Issue Triage** | triage issues, prioritize backlog, label issues | `triage` (state-machine triage) |
| **Bug Diagnosis (HITL)** | diagnose bug, root-cause loop, reproduce failure | `diagnose` (6-phase HITL) — complements `systematic-debugging` |
| **Prototyping** | throwaway prototype, spike, logic vs UI split | `prototype` |
| **PRD / Issue Breakdown** | synthesize PRD, vertical-slice issue breakdown | `to-prd` / `to-issues` |
| **Session Handoff** | hand off work, continuity doc for next agent | `handoff` |
| **Skill Authoring** | scaffold a new skill, SKILL.md template | `write-a-skill` (complements `writing-skills`) |
| **Repo Onboarding Setup** | issue tracker + triage labels + domain glossary scaffold | `setup-matt-pocock-skills` |
| **Pre-commit Setup** | husky, lint-staged, pre-commit hooks | `setup-pre-commit` |
| **Git Guardrails** | block dangerous git ops, git safety layer | `git-guardrails-claude-code` |
| **Scientific Research** | PubMed, USPTO patents, genomics (gget), literature review, scholar eval | `scientific-db-pubmed-database` / `scientific-db-uspto-database` / `scientific-pkg-gget` / `scientific-thinking-literature-review` / `scientific-thinking-scholar-evaluation` (vault) |
| **Prediction Markets / ITO** | prediction market oracle/risk, ITO trade baskets, market intel | `prediction-market-oracle-research` / `prediction-market-risk-review` / `ito-trade-planner` / `ito-basket-compare` / `ito-market-intelligence` / `ito-data-atlas-agent` (vault) |
| **Agent Architecture Audit** | audit agent design, agent architecture review | `agent-architecture-audit` |
| **Agentic OS** | solo-dev agentic operating-system patterns | `agentic-os` |
| **Parallel Execution / Orchestration** | optimize parallel fan-out, plan→orchestrate bridge | `parallel-execution-optimizer` / `plan-orchestrate` |
| **Decision Ledger** | recursive decision logging, search/optimization trace | `recursive-decision-ledger` |
| **Error Handling Patterns** | language-agnostic error-handling design | `error-handling` |
| **Flox Environments** | Nix/Flox reproducible dev environments | `flox-environments` |
| **Performance-Critical Systems** | low-latency, HFT, throughput tuning, micro-bench loop | `latency-critical-systems` / `data-throughput-accelerator` / `benchmark-optimization-loop` |
| **Production Readiness Audit** | app production readiness, pre-launch checks | `production-audit` |
| **Cost Tracking** | local usage/cost tracking, spend log | `cost-tracking` + `/cost-report` |
| **Marketing Campaign** | plan/run marketing campaign | `marketing-campaign` + `/marketing-campaign`. Agent: `marketing-agent` |
| **Frontend A11y / Design Direction** | frontend a11y patterns, design direction, make UI feel better | `frontend-a11y` / `frontend-design-direction` / `make-interfaces-feel-better` |
| **React/Next Performance** | React/Next perf, re-render, bundle size, waterfalls, memoization, Core Web Vitals | `busdriver:vercel-react-best-practices` (Vercel-authored, 57 rules + per-rule files) — pair with `busdriver:react-patterns` for idiomatic component/state/hooks patterns |
| **React Composition** | compound components, boolean-prop proliferation, render props vs children, reusable component APIs, React 19 composition | `busdriver:vercel-composition-patterns` (Vercel-authored) — complements `busdriver:react-patterns` |
| **Next.js Conventions** | Next.js file conventions, RSC boundaries, async APIs, metadata, route handlers, image/font, bundling, self-hosting | `busdriver:next-best-practices` (Vercel-authored) — pair with `busdriver:nextjs-turbopack` for Turbopack/`proxy.ts`-specific dev config |
| **Web Interface Guidelines Review** | review my UI, audit design, check against best practices, web-interface-guidelines | `busdriver:web-design-guidelines` (Vercel-authored, fetches latest guidelines at review time) — complements `busdriver:accessibility` (WCAG 2.2 standards) and `busdriver:frontend-a11y` (React a11y implementation) |
| **iOS Icon Generation** | generate iOS app icons | `ios-icon-gen` (vault) |
| **Windows Desktop E2E** | E2E test Windows desktop apps | `windows-desktop-e2e` (vault) |
| **tinystruct** | tinystruct Java framework patterns | `tinystruct-patterns` (vault) |
| **Blender Motion** | inspect Blender motion/animation state | `blender-motion-state-inspection` (vault) |
| **HarmonyOS** | HarmonyOS app build errors | `harmonyos-app-resolver` agent (vault) |
| **Self-hosting (uncloud)** | uncloud deployment/self-hosting | `uncloud` (vault) |
| **Hermes Imports** | Hermes import management/resolution | `hermes-imports` (vault) |
| **Project Init** | initialize new project scaffold | `/project-init` |

## Cross-Cutting Utilities

Available in any pipeline phase:

| Category | Route(s) |
|----------|----------|
| **Context/Session** | `/save-session`, `/resume-session`, `/aside`, `/sessions`, `strategic-compact`, `context-budget` |
| **Web Research** | `busdriver:tavily-search` / `busdriver:tavily-cli` (general/news + extract/crawl/map/research, free), Exa MCP (`mcp__claude_ai_Exa__web_search_exa` — neural for code/papers/entities), `deep-research` (multi-source synthesis orchestrating Tavily CLI + Exa MCP; Firecrawl CLI for deep page extraction) |
| **Browser Automation** | `busdriver:agent-browser` CLI, Playwright MCP, Chrome DevTools MCP |
| **Project Setup** | `/setup-pm`, `configure-ecc`, `codebase-onboarding` |
| **Docs Lookup** | `busdriver:context7-cli` (ctx7 CLI) |
| **Eval/Benchmark** | `eval-harness` |
| **Performance** | `content-hash-cache-pattern` |

## Learning System

**Trust gradient** (highest → lowest): `busdriver:reflect` (manual, user confirms) → Lesson capture (council/review delta) → `/learn`+`/learn-eval` (manual ECC patterns) → ECC v2 observer (automatic, requires `/promote`).

**ECC v2 observer** writes to `~/.claude/homunculus/projects/<hash>/instincts/personal/` with `source: session-observation`. Quarantine: `session-observation` requires `/promote` before loading; `distill`/`inherited` auto-load. `load-orchestrator.sh` loads instincts with confidence ≥ 0.7, max 20.

**Lesson capture:** Save when council/review produced a recommendation delta. Path: `~/.claude/notes/lesson-{council|review}-{date}-{slug}.md`. <150 words.

**Skills/Commands:** `busdriver:reflect`, `/instinct-status`, `/promote`, `/evolve`, `/projects`, `/learn`, `/learn-eval`.
