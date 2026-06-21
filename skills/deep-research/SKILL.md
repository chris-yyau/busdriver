---
name: deep-research
description: Multi-source deep research using the vendored Tavily CLI (busdriver:tavily-cli), the Exa MCP (mcp__claude_ai_Exa__web_search_exa), and the vendored Firecrawl CLI (busdriver:firecrawl). Searches the web, verifies claims, synthesizes findings, and delivers cited reports with source attribution. Use when the user wants thorough research on any topic with evidence and citations.
metadata:
  origin: ECC (forked + localized for busdriver tooling)
---

# Deep Research

> **Tooling-explicit skill.** This skill routes to busdriver's vendored web
> tools by an explicit selection policy (below). It does **not** depend on the
> Firecrawl or Exa MCP servers being wired — it calls the Tavily CLI and the
> Firecrawl CLI as vendored skills, plus the official Exa MCP. CLI flags and
> Exa MCP result shapes can drift; verify current behavior before promising
> coverage or quoting live source counts.

Produce thorough, cited research reports from multiple web sources by fanning
out searches, deep-reading key sources, adversarially verifying claims, and
synthesizing with full source attribution.

## When to Activate

- User asks to research any topic in depth
- Competitive analysis, technology evaluation, or market sizing
- Due diligence on companies, investors, or technologies
- Any question requiring synthesis from multiple sources
- User says "research", "deep dive", "investigate", or "what's the current state of"

## Tool Selection Policy

Pick the tool by the *kind* of source you need. Mix freely across sub-questions.

| Need | Tool | How |
|------|------|-----|
| General web / news / current events / broad lookups | `busdriver:tavily-cli` | LLM-optimized search + extract/crawl/map/research suite (free tier ~1k/mo) |
| Neural / technical / code / papers / company / people | **Exa MCP** | `mcp__claude_ai_Exa__web_search_exa` (search), `mcp__claude_ai_Exa__web_fetch_exa` (read a known URL) |
| Deep page extraction / scrape / crawl a specific source | `busdriver:firecrawl` (CLI) | Full-page markdown, JS-rendered pages, crawl/download a site section |

> **Note (Exa server name):** The `mcp__claude_ai_Exa__…` tool prefix used above
> assumes the Exa MCP server is registered as `claude_ai_Exa` (the claude.ai Exa
> connector used in this environment). With a differently-named Exa MCP server,
> substitute the matching prefix — the `web_search_exa` / `web_fetch_exa` tool
> suffixes are unchanged.
>
> **Note:** Context7 / `ctx7` (`busdriver:context7-cli`) is **library/API-docs
> lookup**, NOT a general web-research source — it is excluded from
> deep-research. Use it only when the question is "how do I call library X",
> not "what is the current state of topic X".

Use the Tavily CLI and Firecrawl CLI as vendored skills (invoke them via the
Skill tool / their CLI). Use the Exa MCP tools directly. None of these require
the legacy Firecrawl or Exa MCP servers to be configured.

## Workflow

### Step 1: Understand the Goal

Ask 1-2 quick clarifying questions:
- "What's your goal — learning, making a decision, or writing something?"
- "Any specific angle or depth you want?"

If the user says "just research it" — skip ahead with reasonable defaults.

### Step 2: Plan the Research (fan-out)

Break the topic into 3-5 research sub-questions. Example:
- Topic: "Impact of AI on healthcare"
  - What are the main AI applications in healthcare today?
  - What clinical outcomes have been measured?
  - What are the regulatory challenges?
  - What companies are leading this space?
  - What's the market size and growth trajectory?

### Step 3: Execute Multi-Source Search (fan-out)

For EACH sub-question, search with the tool that fits the source type per the
policy above:

**General web / news / current events → `busdriver:tavily-cli`:**
```
tvly search "<sub-question keywords>" --max-results 8 --json
```

**Neural / technical / code / papers / company / people → Exa MCP:**
```
mcp__claude_ai_Exa__web_search_exa(query: "<sub-question keywords>", numResults: 8)
```

**Search strategy:**
- Use 2-3 different keyword variations per sub-question
- Route general/news queries to Tavily, technical/entity queries to Exa
- Aim for 15-30 unique sources total
- Prioritize: academic, official, reputable news > blogs > forums

### Step 4: Deep-Read Key Sources

For the most promising URLs, fetch full content:

**Deep page extraction / scrape / crawl a specific source → `busdriver:firecrawl` (CLI):**
```
firecrawl scrape "<url>"
firecrawl crawl "<url>" --limit 10        # to pull a section of a site
```

**Read a known Exa-surfaced URL → Exa MCP:**
```
mcp__claude_ai_Exa__web_fetch_exa(urls: ["<url>"], maxCharacters: 5000)
```

Read 3-5 key sources in full for depth. Do not rely only on search snippets.
Use the Firecrawl CLI when a source is JS-rendered, paginated, or you need a
whole site section; use Exa's fetch for clean reads of neural search hits.

### Step 5: Adversarially Verify Claims

Before writing, stress-test the findings — do not just collect agreeing sources:
- For each load-bearing claim, **actively search for the counter-position** (route
  contrarian/technical counter-searches to Exa, general/news counter-searches to
  Tavily).
- If only ONE source supports a claim, mark it **unverified** and try to
  corroborate or refute it with a second independent source.
- Watch for circular sourcing (multiple outlets republishing one origin) — trace
  back to the primary source with the Firecrawl CLI when it matters.
- Separate fact from inference; flag estimates, projections, and opinions.

### Step 6: Synthesize and Write Report

Structure the report:

```markdown
# [Topic]: Research Report
*Generated: [date] | Sources: [N] | Confidence: [High/Medium/Low]*

## Executive Summary
[3-5 sentence overview of key findings]

## 1. [First Major Theme]
[Findings with inline citations]
- Key point ([Source Name](url))
- Supporting data ([Source Name](url))

## 2. [Second Major Theme]
...

## 3. [Third Major Theme]
...

## Key Takeaways
- [Actionable insight 1]
- [Actionable insight 2]
- [Actionable insight 3]

## Sources
1. [Title](url) — [one-line summary]
2. ...

## Methodology
Searched [N] queries across Tavily (general/news), Exa (neural/technical), and
deep-read [M] sources via the Firecrawl CLI. Sub-questions investigated: [list].
Claims cross-checked: [note any flagged as unverified].
```

### Step 7: Deliver

- **Short topics**: Post the full report in chat
- **Long reports**: Post the executive summary + key takeaways, save full report to a file

## Parallel Research with Subagents

For broad topics, use Claude Code's Task tool to parallelize:

```
Launch 3 research agents in parallel:
1. Agent 1: Research sub-questions 1-2
2. Agent 2: Research sub-questions 3-4
3. Agent 3: Research sub-question 5 + cross-cutting themes
```

Each agent searches (Tavily for general, Exa for neural), reads sources (Firecrawl
CLI / Exa fetch), and returns findings. The main session adversarially verifies
and synthesizes into the final report.

## Quality Rules

1. **Every claim needs a source.** No unsourced assertions.
2. **Cross-reference.** If only one source says it, flag it as unverified and seek a second.
3. **Verify adversarially.** Search for the counter-position, not just confirmation.
4. **Recency matters.** Prefer sources from the last 12 months.
5. **Acknowledge gaps.** If you couldn't find good info on a sub-question, say so.
6. **No hallucination.** If you don't know, say "insufficient data found."
7. **Separate fact from inference.** Label estimates, projections, and opinions clearly.

## Examples

```
"Research the current state of nuclear fusion energy"
"Deep dive into Rust vs Go for backend services in 2026"
"Research the best strategies for bootstrapping a SaaS business"
"What's happening with the US housing market right now?"
"Investigate the competitive landscape for AI code editors"
```
