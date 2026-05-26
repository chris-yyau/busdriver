---
name: exa-search
description: Neural search via Exa MCP for technical content, code, company intel, and people lookups. Use when the user needs code examples, API docs, research papers, company research, or professional profiles — Exa's neural ranking beats general web search for these. For general web/news lookups, prefer tavily-search.
origin: ECC
---

# Exa Search

Neural search optimized for technical content, code, and structured entity research (companies, people). Free tier covers ~1,000 requests/month.

## When to Activate

- Code examples, API references, technical docs
- Research papers, academic content, technical deep-dives
- Company research (`category:company`)
- People lookups, professional profiles (`category:people`)
- Anything where neural relevance ranking beats keyword search

**Not the right tool for:** general news, broad current-events lookups, simple factual queries — use `tavily-search` instead (also free tier, broader coverage).

## MCP Requirement

Two setup paths — pick whichever fits your harness:

**Option A (recommended): claude.ai-managed Exa MCP.** No API key on disk, no `~/.claude.json` edit. Add via `/mcp` UI or claude.ai integrations panel. Tool names appear as `mcp__claude_ai_Exa__web_search_exa` and `mcp__claude_ai_Exa__web_fetch_exa`.

**Option B: self-hosted via `exa-mcp-server`.** Add to `~/.claude.json`:

```json
"exa-web-search": {
  "command": "npx",
  "args": ["-y", "exa-mcp-server"],
  "env": { "EXA_API_KEY": "YOUR_EXA_API_KEY_HERE" }
}
```

Get an API key at [exa.ai](https://exa.ai).

## Core Tools

### web_search_exa

Neural web search. Returns titles, URLs, and content highlights.

```text
web_search_exa(query: "...", numResults: 5)
```

| Param | Type | Default | Notes |
|-------|------|---------|-------|
| `query` | string | required | Natural-language description of the ideal page. Use `category:company` or `category:people` to focus entity searches. |
| `numResults` | number | 10 | Number of results to return |

**Query tip:** describe the ideal page, not keywords. `"blog post comparing React and Vue performance"` beats `"React vs Vue"`.

### web_fetch_exa

Read full page content as clean markdown. Use after `web_search_exa` when highlights are insufficient.

```text
web_fetch_exa(urls: ["https://example.com/page"], maxCharacters: 3000)
```

| Param | Type | Default | Notes |
|-------|------|---------|-------|
| `urls` | array | required | URLs to read. Batch multiple URLs in one call. |
| `maxCharacters` | number | 3000 | Max chars to extract per page |

## Usage Patterns

### Code Research
```text
web_search_exa(query: "Rust error handling patterns Result type with examples", numResults: 5)
```

### Research Papers / Technical Deep-Dive
```text
web_search_exa(query: "research paper on WebAssembly component model adoption 2026", numResults: 5)
web_fetch_exa(urls: ["<top-2-URLs>"], maxCharacters: 5000)
```

### Company Research
```text
web_search_exa(query: "category:company Vercel funding valuation 2026", numResults: 3)
```

### People Lookup
```text
web_search_exa(query: "category:people AI safety researchers at Anthropic", numResults: 5)
```

### Deep Fetch After Search
```text
results = web_search_exa(query: "...", numResults: 5)
# Pick the 2-3 most promising URLs
web_fetch_exa(urls: [results[0].url, results[1].url], maxCharacters: 4000)
```

## Tips

- Use natural-language queries — Exa's neural model rewards semantic richness over keywords
- Prefix `category:company` or `category:people` at the start of your query to activate Exa's entity filter (e.g. `"category:company Vercel funding 2026"`)
- Default `numResults: 10` is often too many — start with 3-5 to save quota
- Batch URLs in a single `web_fetch_exa` call rather than one-at-a-time
- Lower `maxCharacters` (1500-2000) for snippets, higher (5000+) for full-page comprehension
- Out of 1k/month free? Fall back to `tavily-search` for queries where neural ranking isn't critical

## Related Skills

- `tavily-search` — general web/news lookups (also free tier; preferred for non-technical content)
- `deep-research` — full multi-source research workflow that orchestrates Tavily + Exa
- `market-research` — business-oriented research with decision frameworks
