---
name: tavily-research
description: |
  Conduct comprehensive AI-powered research with citations via the Tavily CLI. Use this skill when the user wants deep research, a detailed report, a comparison, market analysis, literature review, or says "research", "investigate", "analyze in depth", "compare X vs Y", "what does the market look like for", or needs multi-source synthesis with explicit citations. Returns a structured report grounded in web sources. Takes 30-120 seconds. For quick fact-finding, use tavily-search instead.
allowed-tools: Bash(tvly *)
---

# tavily research

AI-powered deep research that gathers sources, analyzes them, and produces a cited report. Takes 30-120 seconds.

## Before running any command

`tvly` must be installed and authenticated. If it is missing, installation is a one-time external prerequisite the operator runs — it falls outside this skill's `Bash(tvly *)` allow-list, so ask the operator to install rather than self-bootstrapping:

```bash
curl -fsSL https://cli.tavily.com/install.sh | bash && tvly login
```

Once `tvly` is available, do not fall back to other tools.

See [tavily-cli](../tavily-cli/SKILL.md) for alternative install methods and auth options.

## When to use

- You need comprehensive, multi-source analysis
- The user wants a comparison, market report, or literature review
- Quick searches aren't enough — you need synthesis with citations
- Step 5 in the [workflow](../tavily-cli/SKILL.md): search → extract → map → crawl → **research**

## Quick start

```bash
# Basic research (waits for completion)
tvly research "competitive landscape of AI code assistants"

# Pro model for comprehensive analysis
tvly research "electric vehicle market analysis" --model pro

# Stream results in real-time
tvly research "AI agent frameworks comparison" --stream

# Save report to file
tvly research "fintech trends 2025" --model pro -o fintech-report.md

# JSON output for agents
tvly research "quantum computing breakthroughs" --json
```

## Options

| Option | Description |
|--------|-------------|
| `--model` | `mini`, `pro`, or `auto` (default) |
| `--stream` | Stream results in real-time |
| `--no-wait` | Return request_id immediately (async) |
| `--output-schema` | Path to JSON schema for structured output |
| `--citation-format` | `numbered`, `mla`, `apa`, `chicago` |
| `--poll-interval` | Seconds between checks (default: 10) |
| `--timeout` | Max wait seconds (default: 600) |
| `-o, --output` | Save output to file |
| `--json` | Structured JSON output |

## Model selection

| Model | Use for | Speed |
|-------|---------|-------|
| `mini` | Single-topic, targeted research | ~30s |
| `pro` | Comprehensive multi-angle analysis | ~60-120s |
| `auto` | API chooses based on complexity | Varies |

**Rule of thumb:** "What does X do?" → mini. "X vs Y vs Z" or "best way to..." → pro.

## Async workflow

For long-running research, you can start and poll separately:

```bash
# Start without waiting
tvly research "topic" --no-wait --json    # returns request_id

# Check status
tvly research status <request_id> --json

# Wait for completion
tvly research poll <request_id> --json -o result.json
```

## Tips

- **Research takes 30-120 seconds** — use `--stream` to see progress in real-time.
- **Use `--model pro`** for complex comparisons or multi-faceted topics.
- **Use `--output-schema`** to get structured JSON output matching a custom schema.
- **For quick facts**, use `tvly search` instead — research is for deep synthesis.
- Read from stdin: `echo "query" | tvly research - --json`

## See also

- [tavily-search](../tavily-search/SKILL.md) — quick web search for simple lookups
- [tavily-crawl](../tavily-crawl/SKILL.md) — bulk extract from a site for your own analysis
