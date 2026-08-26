# Non-Pipeline Tasks Catalog

> **Read this file** when the user's request doesn't match a Pipeline phase or Domain Supplement in `SKILL.md`. This catalog lists busdriver-owned tasks that enter at a specific point or run independently.
>
> **Skill auto-discovery:** Skills not listed here are still discoverable via the system-prompt skill registry — Claude sees every installed skill's name + description automatically. This catalog only adds value where (a) trigger keyword → skill mapping is non-obvious, or (b) curated multi-skill groupings beat picking single skills.
>
> **Scope (ADR 0048):** busdriver carries pipeline mechanics only — gates, cross-session state, external review/dispatch orchestration, and the workflow-discipline skills the phases invoke. Reference material (language patterns, framework guides) is left to the model. Third-party toolbox skills (web search, scraping, browser automation, docs lookup) are **personal skills**: installed per machine (e.g. `npx skills add <repo>`) and surfaced to Claude through `~/.claude/skills`. Rows marked *(personal)* route to such a skill **if installed**; if absent, use the model's built-in tools (WebSearch/WebFetch, MCPs).

## Routes

Use Skill tool unless marked "agent" (Agent tool) or "command" (`/name`).

| Task | Trigger keywords | Route(s) |
|------|-----------------|----------|
| **Refactoring** | cleanup, dead code | `refactor-cleaner` agent |
| **Authentication** | login, signup, OAuth | `security-review` |
| **UI/UX Design** | design, UI review, make it look better, styling, landing page, dashboard | `impeccable:impeccable` (separately installed plugin — owns design end-to-end). Load `.impeccable.md` if present. Generic fallback: `document-skills:frontend-design` |
| **Design Setup** | impeccable, design context, brand setup | `impeccable:shape` (one-time → `.impeccable.md`) |
| **Design Refinement** | polish, critique, audit UI, animate, make bolder/quieter | Impeccable commands: `/polish`, `/critique`, `/audit`, `/normalize`, `/harden`, `/distill`, `/clarify`, `/colorize`, `/bolder`, `/quieter`, `/delight`, `/animate`, `/overdrive`, `/arrange`, `/extract`, `/typeset`, `/layout`, `/adapt`, `/optimize`, `/onboard` |
| **Image assets** | generate an image, make a logo, hero image, icon, texture, sprite, mockup, reference board, edit this image | `busdriver:imagegen` (router → codex / agy / grok image tools). Video is unavailable — see the skill's Video section |
| **Skill Creation** | create/edit skill | `busdriver:writing-skills` |
| **Verification** | verify, build+lint+test | `/verify` command |
| **Repo pipeline setup** | test setup, scaffold tests, CI pipeline, Codecov, pinact, generate/refresh CLAUDE.md, code intelligence, codegraph, code graph, structural search | `helmet` *(personal)* — Phase A tests / B CI / C CLAUDE.md / D CodeGraph |
| **Deep Research** | research X thoroughly, cited reports | `deep-research` *(personal)* — multi-source synthesis over `tavily-cli` + Exa MCP + `firecrawl` |
| **Web Search / Extract / Crawl / Scrape** | news, current events, page extract, site crawl, scrape page, JS-rendered pages, watch for changes | `tavily-cli` *(personal)*, `firecrawl` *(personal)*; otherwise WebSearch/WebFetch |
| **Library / API Docs** | up-to-date library docs, framework API reference, package usage | `context7-cli` *(personal)* (ctx7 CLI); otherwise Context7 MCP / WebFetch |
| **Neural Search** | code/papers, company intel, people lookup, technical content | Exa MCP (`mcp__claude_ai_Exa__web_search_exa`, `mcp__claude_ai_Exa__web_fetch_exa`) |
| **Browser Automation** | open a website, fill a form, click, screenshot, QA a web app | `agent-browser` *(personal)*, Chrome MCP, Playwright MCP |
| **Skill Auditing** | audit skills, check compliance | `skill-comply` |
| **Multi-Service** | monorepo, microservices | `busdriver:dispatching-parallel-agents` + `/pm2` |
| **Codex Adversarial** | adversarial review, challenge design | `/codex:adversarial-review` (official plugin) |
| **Codex Rescue** | delegate task to Codex | `/codex:rescue` (official plugin) |
| **Codex Goal Loop** | iterative Codex handover with declarative pass/fail verifiers (tests/lint/typecheck), result returns to CC. Foreground only — for fire-and-forget use TUI `codex` + `/goal` | `/busdriver:codex-goal` (verifier-led; skill `codex-goal-handover`) |
| **External CLI** | send to codex/agy/droid | `dispatch-cli` |
| **Multi-Model** | multi-model planning | `/multi-plan`, `/multi-backend`, `/multi-frontend`, `/multi-execute`, `/multi-workflow` |
| **Council** | perspectives, group wisdom, tradeoffs, ambiguous decision, structured deliberation | `council` (5-voice: Architect + Skeptic + Pragmatist + Critic + Researcher) |
| **Communication** | email triage, Slack, inbox | `chief-of-staff` agent |
| **Scheduled Agents** | cron job, run on schedule | `CronCreate`/`CronList`/`CronDelete` |
| **Recurring Tasks** | run every N minutes | `/loop-start`, `loop-operator` agent |
| **Notes** | check notes health, refine | `/refine-notes` |
| **Draft Prose** | write a post, draft an essay, write the copy, rewrite this section, help me word this, write a README intro | `busdriver:writing-prose` (drafts via the write-blocked `agy-prose` dispatch lane, then runs `humanizer` *(personal)* over the draft). For de-slopping text you ALREADY have, use `humanizer` directly instead |
| **Humanize Writing** | remove AI tone, sounds AI-written, de-slop text, make it sound human | `humanizer` *(personal)* — detect+fix AI-writing tells |
| **GAN Harness** | build app iteratively, gen+eval loop | `/gan-design` / `/gan-build`. Agents: `gan-planner`, `gan-generator`, `gan-evaluator` |
| **Open-Sourcing** | open source this, make public | Agents in order: `opensource-forker` → `opensource-sanitizer` → `opensource-packager` |
| **PRP Workflow** | PRD, plan, implement, commit, PR | `/prp-prd` / `/prp-plan` / `/prp-implement` / `/prp-commit` / `/prp-pr` |
| **Dual Review** | adversarial review, two reviewers | `/santa-loop` |
| **Error Handling Review** | check error handling, silent failures, catch blocks | `silent-failure-hunter` agent |
| **Type Design Review** | review types, check invariants, type safety | `type-design-analyzer` agent |
| **Test Coverage Review** | check test quality, test gaps, edge cases | `pr-test-analyzer` agent |
| **Code Polish** | simplify code, make clearer, refine | `code-simplifier` agent |
| **SEO** | SEO audit, schema markup, search visibility | `seo-specialist` agent |
| **PR Grind** | grind PR, fix CI, address PR comments, PR feedback loop | `pr-grind` |
| **GateGuard** | force fact-gathering before edits/writes | `gateguard` + `scripts/hooks/gateguard-fact-force.js` (opt-in) |
| **Agent Self-Evaluation** | score agent output against a rubric, self-evaluate quality | `agent-self-evaluation`. Agent: `agent-evaluator` |
| **Plan Review** | review code against plan, step completion | `plan-code-reviewer` agent |
| **Performance Opt** | optimize performance, profiling, bottlenecks | `performance-optimizer` agent |
| **Accessibility** | WCAG, a11y, screen reader, aria | `a11y-architect` agent |
| **Continuous Learning** | extract patterns, session learning | `continuous-learning-v2` (instinct-based) |
| **Plan Stress-Test** | grill the plan, hostile interview | `grill-me` |
| **Agent Loops** | run/babysit an autonomous loop, tune agent harness config | Agents: `loop-operator`, `harness-optimizer` |
| **Cost Tracking** | local usage/cost tracking, spend log | `/cost-report` |
| **Marketing Campaign** | plan/run marketing campaign, positioning, copy | `marketing-agent` agent |
| **Project Init** | initialize new project scaffold | `/project-init` |

## Cross-Cutting Utilities

Available in any pipeline phase:

| Category | Route(s) |
|----------|----------|
| **Context/Session** | `/save-session`, `/resume-session`, `/aside`, `/sessions`, `strategic-compact` |
| **Web Research** | `tavily-cli` / `firecrawl` / `deep-research` *(personal)*, Exa MCP (`mcp__claude_ai_Exa__web_search_exa` — neural for code/papers/entities), WebSearch/WebFetch |
| **Browser Automation** | `agent-browser` *(personal)*, Playwright MCP, Chrome DevTools MCP |
| **Project Setup** | `/setup-pm` |
| **Docs Lookup** | `context7-cli` *(personal)* |
| **Eval/Benchmark** | `eval-harness` |

## Learning System

**Trust gradient** (highest → lowest): `busdriver:reflect` (manual, user confirms) → Lesson capture (council/review delta) → `/learn`+`/learn-eval` (manual ECC patterns) → ECC v2 observer (automatic, requires `/promote`).

**ECC v2 observer** writes to `~/.claude/homunculus/projects/<hash>/instincts/personal/` with `source: session-observation`. Quarantine: `session-observation` requires `/promote` before loading; `distill`/`inherited` auto-load. `load-orchestrator.sh` loads instincts with confidence ≥ 0.7, max 20.

**Lesson capture:** Save when council/review produced a recommendation delta. Path: `~/.claude/notes/lesson-{council|review}-{date}-{slug}.md`. <150 words.

**Skills/Commands:** `busdriver:reflect`, `/instinct-status`, `/promote`, `/evolve`, `/projects`, `/learn`, `/learn-eval`.
