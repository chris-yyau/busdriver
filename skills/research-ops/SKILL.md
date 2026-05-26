---
name: research-ops
description: Evidence-first current-state research workflow for ECC. Use when the user wants fresh facts, comparisons, enrichment, or a recommendation built from current public evidence and any supplied local context.
origin: ECC
---

# Research Ops

Use this when the user asks to research something current, compare options, enrich people or companies, or turn repeated lookups into a monitored workflow.

This is the operator wrapper around the repo's research stack. It is not a replacement for `deep-research`, `exa-search`, or `market-research`; it tells you when and how to use them together.

## Skill Stack

Pull these skills into the workflow when relevant. **Default to free tools (Tavily, Exa); reserve Firecrawl for credit-spend fallback inside `deep-research` only.**

- `tavily-search` for general web, news, broad queries, and page extraction (free tier)
- `exa-search` for neural-ranked technical content, code, papers, and `category:company`/`category:people` entity lookups (free tier)
- `deep-research` for multi-source synthesis with citations — orchestrates Tavily + Exa, falls back to Firecrawl only when needed
- `market-research` when the end result should be a recommendation or ranked decision
- `lead-intelligence` when the task is people/company targeting instead of generic research
- `knowledge-ops` when the result should be stored in durable context afterward

## When to Use

- user says "research", "look up", "compare", "who should I talk to", or "what's the latest"
- the answer depends on current public information
- the user already supplied evidence and wants it factored into a fresh recommendation
- the task may be recurring enough that it should become a monitor instead of a one-off lookup

## Guardrails

- do not answer current questions from stale memory when fresh search is cheap
- separate:
  - sourced fact
  - user-provided evidence
  - inference
  - recommendation
- do not spin up a heavyweight research pass if the answer is already in local code or docs

## Workflow

### 1. Start from what the user already gave you

Normalize any supplied material into:

- already-evidenced facts
- needs verification
- open questions

Do not restart the analysis from zero if the user already built part of the model.

### 2. Classify the ask

Choose the right lane before searching:

- quick factual answer
- comparison or decision memo
- lead/enrichment pass
- recurring monitoring candidate

### 3. Take the lightest useful evidence path first

Route by ask shape (free tools first; escalate to credit-spend only when justified):

| Ask shape | Route to | Why |
|-----------|----------|-----|
| Quick fact, news, current event | `tavily-search` (`tavily_search`) | Broad coverage, free, fast |
| Code, API docs, research papers, technical deep-dives | `exa-search` (`web_search_exa`) | Neural ranking shines on technical content |
| Company intel, people lookups | `exa-search` with `category:company` / `category:people` | Purpose-built entity filters |
| Page fetch from a known URL | `web_fetch_exa` or `tavily_extract` | Both free; pick by which surfaced the URL |
| Site-wide crawl, URL discovery | `tavily_crawl` / `tavily_map` | Free, covers most needs |
| Multi-source comparison or decision memo | `deep-research` | Orchestrates Tavily + Exa with planning + citations |
| Recommendation / ranked decision | `market-research` | Decision frameworks layered on research |
| Target ranking, warm-path discovery | `lead-intelligence` | Specialized for people/company targeting |

**Firecrawl (paid) reserved for:** JS-heavy SPAs where both `web_fetch_exa` and `tavily_extract` return empty/garbage. Only `deep-research` should reach for it, and only after the free tier failed on the specific URL.

### 4. Report with explicit evidence boundaries

For important claims, say whether they are:

- sourced facts
- user-supplied context
- inference
- recommendation

Freshness-sensitive answers should include concrete dates.

### 5. Decide whether the task should stay manual

If the user is likely to ask the same research question repeatedly, say so explicitly and recommend a monitoring or workflow layer instead of repeating the same manual search forever.

## Output Format

```text
QUESTION TYPE
- factual / comparison / enrichment / monitoring

EVIDENCE
- sourced facts
- user-provided context

INFERENCE
- what follows from the evidence

RECOMMENDATION
- answer or next move
- whether this should become a monitor
```

## Pitfalls

- do not mix inference into sourced facts without labeling it
- do not ignore user-provided evidence
- do not use a heavy research lane for a question local repo context can answer
- do not give freshness-sensitive answers without dates

## Verification

- important claims are labeled by evidence type
- freshness-sensitive outputs include dates
- the final recommendation matches the actual research mode used
