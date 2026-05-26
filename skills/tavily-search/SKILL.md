---
name: tavily-search
description: Fast web search, page extraction, and site crawling via Tavily MCP. Use as the default tier-1 tool for general web lookups, news, broad current-events queries, and page fetches. Free tier covers ~1,000 requests/month. For neural ranking on technical/code/people/company queries, prefer exa-search.
origin: busdriver
---

# Tavily Search

General-purpose web search and content extraction. Free tier covers ~1,000 requests/month. Use as the default first-stop for web research; escalate to Exa for technical/entity queries or to Firecrawl only when both fail on JS-heavy sites.

## When to Activate

- General web lookups, news, current events
- Quick factual queries where freshness matters
- Page extraction from a known URL (markdown or text)
- Site-wide crawling (multi-page traversal from a root URL)
- URL structure mapping (discovering what pages exist on a site)
- One-shot multi-source synthesis (via `tavily_research`)

**Not the right tool for:** code retrieval, research papers, structured entity searches (`category:company`/`category:people`) — those favor `exa-search`'s neural ranking.

## MCP Requirement

Tavily MCP is available via the claude.ai-managed integrations panel. No API key on disk. Tool names appear as `mcp__claude_ai_Tavily__*`.

Get an API key at [tavily.com](https://tavily.com) if self-hosting.

## Core Tools

### tavily_search

General web search with optional time/domain/depth filters.

```
tavily_search(query: "latest LLM benchmarks 2026", max_results: 5)
```

| Param | Type | Default | Notes |
|-------|------|---------|-------|
| `query` | string | required | Search query |
| `max_results` | integer | 5 | Number of results |
| `search_depth` | string | `basic` | `basic` / `advanced` (thorough) / `fast` / `ultra-fast` (latency-optimized) |
| `time_range` | string | none | `day` / `week` / `month` / `year` — freshness filter |
| `start_date` / `end_date` | string | none | `YYYY-MM-DD` date bounds |
| `include_domains` / `exclude_domains` | array | `[]` | Domain allow/block lists |
| `country` | string | none | Boost results from a specific country (full name, e.g. `"Japan"`) |
| `include_raw_content` | boolean | false | Include cleaned HTML of each result |
| `include_images` | boolean | false | Include query-related images |

### tavily_extract

Read full page content as markdown or text.

```
tavily_extract(urls: ["https://example.com/page"], extract_depth: "basic")
```

| Param | Type | Default | Notes |
|-------|------|---------|-------|
| `urls` | array | required | URLs to extract from |
| `extract_depth` | string | `basic` | Use `advanced` for LinkedIn, protected sites, tables/embedded content |
| `format` | string | `markdown` | `markdown` / `text` |
| `query` | string | `""` | Optional — rerank content chunks by relevance to a query |

### tavily_crawl

Crawl a site starting from a root URL.

```
tavily_crawl(url: "https://docs.example.com", max_depth: 2, limit: 30)
```

| Param | Type | Default | Notes |
|-------|------|---------|-------|
| `url` | string | required | Root URL to crawl from |
| `max_depth` | integer | 1 | How far from the root to explore |
| `max_breadth` | integer | 20 | Max links per level |
| `limit` | integer | 50 | Total link cap before stopping |
| `select_domains` / `select_paths` | array | `[]` | Regex patterns to restrict crawl |
| `instructions` | string | `""` | Natural-language filter for which pages to return |
| `extract_depth` | string | `basic` | `basic` / `advanced` |

### tavily_map

Discover URL structure without extracting content (cheaper than crawl).

```
tavily_map(url: "https://docs.example.com", max_depth: 2)
```

Same depth/breadth/domain/path controls as `tavily_crawl`. Returns URL list only.

### tavily_research

Server-side multi-source research with synthesis. Rate-limited to 20 req/min.

```
tavily_research(input: "comprehensive overview of CRDT-based collaborative editing in 2026", model: "auto")
```

| Param | Type | Default | Notes |
|-------|------|---------|-------|
| `input` | string | required | Comprehensive description of the research task |
| `model` | string | `auto` | `mini` (narrow tasks) / `pro` (broad tasks) / `auto` |

**Note:** for orchestrated multi-step research with sub-question planning and a structured cited report, use the `deep-research` skill instead. `tavily_research` is a one-shot escape hatch.

## Usage Patterns

### Quick News Lookup
```
tavily_search(query: "OpenAI o3 release news", time_range: "week", max_results: 5)
```

### Domain-Scoped Search
```
tavily_search(query: "RFC 9114 HTTP/3 priority", include_domains: ["ietf.org", "rfc-editor.org"], max_results: 3)
```

### Quick Page Read
```
tavily_extract(urls: ["https://example.com/article"], extract_depth: "basic")
```

### Site Crawl for Docs Ingestion
```
tavily_crawl(url: "https://docs.example.com", max_depth: 2, limit: 50, select_paths: ["/api/.*"])
```

### URL Discovery Before Targeted Fetch
```
urls = tavily_map(url: "https://blog.example.com", max_depth: 2, limit: 100)
# Filter to URLs of interest, then extract
tavily_extract(urls: filtered_urls)
```

## Tips

- `search_depth: "ultra-fast"` is ideal inside latency-sensitive agent loops
- Use `time_range` for freshness instead of stuffing dates into the query
- `include_domains`/`exclude_domains` is more reliable than `site:` operators
- `tavily_map` before `tavily_crawl` if you want to inspect what'll get crawled
- `tavily_extract` with `extract_depth: "advanced"` is the right move for LinkedIn or JS-heavy pages
- Out of 1k/month free? Fall back to `exa-search` for queries where neural ranking helps

## Related Skills

- `exa-search` — neural search for technical content, code, people, companies
- `deep-research` — multi-source research workflow that orchestrates Tavily + Exa with planning and structured reports
- `market-research` — business-oriented research with decision frameworks
