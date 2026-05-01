---
name: thinking-models-research
description: 5 structured reasoning models for research and synthesis — First Principles, Simpson's Paradox, Survivorship Bias, Confirmation Bias Counter, Steel Man
targets:
  - busdriver:deep-research
  - busdriver:research-ops
  - busdriver:search-first
  - busdriver:codebase-onboarding
source: gsd-build/get-shit-done references/thinking-models-research.md (adapted)
added: 2026-05-01
---

# Thinking Models for Research

Structured reasoning models for research and synthesis. Apply these at decision points during evidence gathering and recommendation, not continuously. Each model counters a specific failure mode.

> Load alongside `busdriver:deep-research`, `busdriver:research-ops`, or `busdriver:search-first` when evaluating contested recommendations or synthesizing conflicting findings.

## Conflict Resolution

First Principles and Steel Man both expand scope. Run **First Principles FIRST** (decompose the problem), then **Steel Man SECOND** (strengthen alternatives). Sequential, not simultaneous.

---

## 1. First Principles Thinking

**Counters:** Accepting surface-level explanations without decomposing into fundamental components.

Before accepting any technology recommendation or architectural pattern, decompose it to its fundamental constraints: What problem does this solve? What are the non-negotiable requirements? What are the physical/logical limits? Build your recommendation UP from these constraints rather than DOWN from conventional wisdom. If you cannot explain WHY a recommendation is correct from first principles, flag it as low-confidence regardless of source count.

## 2. Simpson's Paradox Awareness

**Counters:** Aggregating conflicting research without checking for confounding splits.

When combining findings from multiple sources that show contradictory results, check whether the contradiction disappears when you split by a hidden variable: framework version, deployment target, project scale, or use case category. A library that benchmarks faster overall may be slower for YOUR specific workload. Before resolving contradictions by majority vote, ask: "Is there a subgroup split that explains why both findings are correct in their own context?"

## 3. Survivorship Bias

**Counters:** Only finding successful examples while missing failures and abandoned approaches.

After gathering evidence FOR a recommended approach, actively search for projects that ABANDONED it. Check GitHub issues for "migrated away from", "replaced X with", or "problems with X at scale". A technology with 10 success stories and 100 quiet failures looks great until you check the graveyard. Weight negative evidence (migration-away stories, deprecation notices, unresolved issues) MORE heavily than positive evidence — failures are underreported.

## 4. Confirmation Bias Counter

**Counters:** Searching for evidence that confirms initial hypothesis while ignoring disconfirming evidence.

After forming your initial recommendation, spend one full research cycle searching AGAINST it. Use search terms like "{technology} problems", "{technology} alternatives", "why not {technology}", "{technology} vs {competitor}". For each piece of disconfirming evidence found, either (a) refute it with higher-confidence sources, or (b) add it as a caveat to your recommendation. If you cannot find ANY criticism of your recommendation, your search was too narrow — widen it.

## 5. Steel Man

**Counters:** Dismissing alternative approaches without giving them their strongest possible form.

Before recommending against an alternative technology or approach, construct its STRONGEST possible case. What would a passionate advocate say? What use cases does it serve better than your recommendation? What trade-offs favor it? Present the steel-manned alternative alongside your recommendation with an honest comparison. If the steel-manned alternative is competitive, flag the decision as needing user input rather than making a unilateral recommendation.

---

## When NOT to Think

Skip structured reasoning models when the situation does not benefit:

- **Locked decisions** — if the user already decided "use library X", do not run Steel Man analysis on alternatives or First Principles decomposition of the choice. Research how to use X well, not whether X is the right choice.
- **Standard stack lookups** — if you are simply checking the latest version of a well-known library or reading its API docs, do not invoke Survivorship Bias or Confirmation Bias Counter. These models are for evaluating contested recommendations, not for factual lookups.
- **Single-technology scope** — if the work involves one technology with no alternatives to evaluate (e.g., "add ESLint rule X"), skip comparative models (Steel Man, Confirmation Bias Counter). Just research the implementation.
- **Codebase-only research** — if the research is purely internal (understanding existing code patterns, finding where a function is called), structured reasoning models add no value. Use grep and read the code.
