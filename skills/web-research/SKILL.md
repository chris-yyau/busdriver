---
name: web-research
description: >
  Route web search, scraping, and research tasks to the right MCP tool. Use when doing any web
  lookup, search, scraping, content extraction, site mapping, or online research. Triggers on:
  "search for", "look up", "find online", "scrape", "research", "what is", "latest news about",
  "read this URL", "extract from", "crawl", competitor analysis, documentation lookup, or any
  task requiring external web data.
---

# Web Research Tool Router

Three MCP servers available: **Brave Search**, **Tavily**, and **Firecrawl**. Each has distinct strengths.

## Tool Selection Matrix

Route by what you need, not habit:

| Need | Tool | Why |
|------|------|-----|
| Quick factual lookup, "what is X", general search | **Brave** `brave_web_search` | Fast, lightweight, returns snippets only |
| Local businesses, restaurants, "near me" | **Brave** `brave_local_search` | Only tool with local business data (ratings, hours, phone) |
| Research requiring depth, relevance, or filtering | **Tavily** `tavily-search` | AI-curated results, `search_depth: "advanced"`, time-range + domain filtering |
| Breaking news, recent events | **Tavily** `tavily-search` | Use `topic: "news"` + `time_range: "day"` or `"week"` |
| Read full content from a known URL | **Firecrawl** `firecrawl_scrape` | Single-page extraction: markdown (full content) or JSON (specific data) |
| Extract structured data from known URLs | **Firecrawl** `firecrawl_extract` | LLM-powered extraction with JSON schema (prices, specs, fields) |
| Read raw content from known URLs (esp. LinkedIn) | **Tavily** `tavily-extract` | Simpler extraction; use `extract_depth: "advanced"` for LinkedIn |
| Discover all pages on a site | **Firecrawl** `firecrawl_map` | URL discovery before targeted scraping |
| Scrape multiple pages from a site | **Firecrawl** `firecrawl_crawl` | Multi-page extraction (keep `limit` and `maxDiscoveryDepth` low) |
| Complex multi-source research, unknown URLs | **Firecrawl** `firecrawl_agent` | Autonomous async researcher (poll status every 15-30s, allow 2-5 min) |
| Competitor analysis, design inspiration | **Firecrawl** `firecrawl_scrape` | Use `formats: ["branding"]` to extract colors, fonts, typography |
| Browser automation, JS-heavy SPAs, login flows | **Firecrawl** `firecrawl_browser_*` | CDP-based sessions for interactive pages |

## Escalation Ladder (cost-aware)

Start cheap, escalate only when needed:

```
1. SEARCH ONLY ──────── Brave (cheapest) or Tavily (when you need relevance/filtering)
       │
       ▼ snippet doesn't answer the question
2. SEARCH + READ ────── Firecrawl Search (has optional inline scrapeOptions)
       │
       ▼ need to read a specific page
3. READ KNOWN URL ───── Firecrawl Scrape (markdown for content, JSON for data points)
       │
       ▼ page is empty/SPA, or need multi-page deep research
4. DEEP RESEARCH ────── Firecrawl Agent (last resort — async, slowest, most expensive)
```

## Decision Rules

### When to use Brave vs Tavily for search
- **Brave**: Default for simple lookups. Fast, cheap, good enough for factual questions.
- **Tavily**: When you need better relevance ranking, domain filtering (`include_domains`/`exclude_domains`), time-based filtering, or `advanced` search depth for thorough research.

### When to use Firecrawl Scrape vs Tavily Extract
- **Firecrawl Scrape**: More powerful — supports markdown, JSON extraction with schema, screenshots, branding analysis, `waitFor` for JS rendering.
- **Tavily Extract**: Simpler, good for quick raw content. Prefer for LinkedIn profiles (`extract_depth: "advanced"`).

### Handling JS-rendered pages (SPAs)
When Firecrawl Scrape returns empty or minimal content:
1. Add `waitFor: 5000` to allow JS rendering
2. Use `firecrawl_map` with `search` param to find the correct URL
3. Fall back to `firecrawl_agent` as last resort

### Key constraints
- Never scrape when a search snippet already answers the question
- For Firecrawl Crawl: keep `limit` ≤ 20 and `maxDiscoveryDepth` ≤ 5 to avoid token overflow
- For Firecrawl Agent: async workflow — call `firecrawl_agent`, then poll `firecrawl_agent_status` every 15-30s. Be patient (2-5 min for complex queries).
- For Firecrawl Scrape JSON extraction: always provide a `schema` object — don't use markdown when extracting specific data points

## Setup

API keys are configured per-server in `~/.claude.json` under `mcpServers`:

```
mcpServers.brave-search.env.BRAVE_API_KEY
mcpServers.tavily-mcp.env.TAVILY_API_KEY
mcpServers.firecrawl-mcp.env.FIRECRAWL_API_KEY
```

To add or rotate a key, edit `~/.claude.json` directly. This file is outside the repo and not git-tracked.

| Service | Get a key |
|---------|-----------|
| Brave Search | brave.com/search/api |
| Tavily | app.tavily.com |
| Firecrawl | firecrawl.dev |
