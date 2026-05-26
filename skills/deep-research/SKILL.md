---
name: deep-research
description: Multi-source deep research using Tavily and Exa MCPs (free tier), with Firecrawl reserved as a paid fallback. Searches the web, synthesizes findings, and delivers cited reports with source attribution. Use when the user wants thorough research on any topic with evidence and citations.
origin: ECC
---

# Deep Research

Produce thorough, cited research reports from multiple web sources. Primary tools are Tavily and Exa (both free-tier); Firecrawl is reserved as a paid fallback for JS-heavy SPAs where the free tools return empty.

## When to Activate

- User asks to research any topic in depth
- Competitive analysis, technology evaluation, or market sizing
- Due diligence on companies, investors, or technologies
- Any question requiring synthesis from multiple sources
- User says "research", "deep dive", "investigate", or "what's the current state of"

## MCP Requirements

**Tier 1 — Free, use first:**
- **tavily** — `tavily_search`, `tavily_extract`, `tavily_crawl`, `tavily_map`. See `tavily-search` skill for details. Best for general/news/broad queries and page extraction.
- **exa** — `web_search_exa`, `web_fetch_exa`. See `exa-search` skill for details. Best for code, technical content, research papers, and `category:company`/`category:people` entity queries.

**Tier 2 — Paid fallback, use only when needed:**
- **firecrawl** — `firecrawl_search`, `firecrawl_scrape`, `firecrawl_crawl`. Reserve for: (a) JS-heavy SPAs where `web_fetch_exa` and `tavily_extract` both return empty/garbage, (b) extremely complex crawls where Tavily's crawl can't reach the content. Every call spends credit.

Both Tier-1 tools together give best free coverage. Configure in `~/.claude.json` or via claude.ai-managed MCP integrations.

## Workflow

### Step 1: Understand the Goal

Ask 1-2 quick clarifying questions:
- "What's your goal — learning, making a decision, or writing something?"
- "Any specific angle or depth you want?"

If the user says "just research it" — skip ahead with reasonable defaults.

### Step 2: Plan the Research

Break the topic into 3-5 research sub-questions. Example:
- Topic: "Impact of AI on healthcare"
  - What are the main AI applications in healthcare today?
  - What clinical outcomes have been measured?
  - What are the regulatory challenges?
  - What companies are leading this space?
  - What's the market size and growth trajectory?

### Step 3: Execute Multi-Source Search

For EACH sub-question, route to the right tool:

**General/news/broad queries — use Tavily (free):**
```text
tavily_search(query: "<sub-question>", max_results: 8, time_range: "year")
```

**Technical/code/research papers — use Exa (free):**
```text
web_search_exa(query: "<sub-question described as ideal page>", numResults: 8)
```

**Entity queries (companies, people) — use Exa with category:**
```text
web_search_exa(query: "category:company <company name> funding 2026", numResults: 5)
```

**Firecrawl is NOT used for search.** Reserve Firecrawl for Step 4 (deep-read) on JS-heavy SPAs where free extract tools fail.

**Search strategy:**
- Use 2-3 different keyword variations per sub-question
- Mix Tavily (broad) and Exa (deep/technical) for the same sub-question
- Aim for 15-30 unique sources total
- Prioritize: academic, official, reputable news > blogs > forums

### Step 4: Deep-Read Key Sources

For the most promising URLs, fetch full content. Try free tools first; spend Firecrawl credit only on fallback.

**Primary (free) — batch URLs in one call:**
```text
web_fetch_exa(urls: ["<url1>", "<url2>"], maxCharacters: 5000)
```
or
```text
tavily_extract(urls: ["<url1>", "<url2>"], extract_depth: "basic")
```

**LinkedIn / protected / tables / embedded content:**
```text
tavily_extract(urls: ["<url>"], extract_depth: "advanced")
```

**Fallback (paid) — only if both above return empty/garbage on JS-heavy SPAs:**
```text
firecrawl_scrape(url: "<url>")
```

Read 3-5 key sources in full for depth. Do not rely only on search snippets.

### Step 5: Synthesize and Write Report

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
Searched [N] queries across web and news. Analyzed [M] sources.
Sub-questions investigated: [list]
```

### Step 6: Deliver

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

Each agent searches, reads sources, and returns findings. The main session synthesizes into the final report.

## Quality Rules

1. **Every claim needs a source.** No unsourced assertions.
2. **Cross-reference.** If only one source says it, flag it as unverified.
3. **Recency matters.** Prefer sources from the last 12 months.
4. **Acknowledge gaps.** If you couldn't find good info on a sub-question, say so.
5. **No hallucination.** If you don't know, say "insufficient data found."
6. **Separate fact from inference.** Label estimates, projections, and opinions clearly.

## Examples

```
"Research the current state of nuclear fusion energy"
"Deep dive into Rust vs Go for backend services in 2026"
"Research the best strategies for bootstrapping a SaaS business"
"What's happening with the US housing market right now?"
"Investigate the competitive landscape for AI code editors"
```
