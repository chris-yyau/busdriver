---
name: thinking-models-debug
description: 4 structured reasoning models for debugging — Fault Tree, Hypothesis-Driven Investigation, Occam's Razor, Counterfactual Thinking
targets:
  - busdriver:systematic-debugging
  - busdriver:agent-introspection-debugging
source: gsd-build/get-shit-done references/thinking-models-debug.md (adapted)
added: 2026-05-01
---

# Thinking Models for Debugging

Structured reasoning models for investigation and root-cause analysis. Apply these at decision points during a debugging session, not continuously. Each model counters a specific failure mode.

> Load alongside `busdriver:systematic-debugging` or `busdriver:agent-introspection-debugging` when investigating bugs, test failures, or unexpected behavior.

## Conflict Resolution

Fault Tree and Hypothesis-Driven are sequential, not competing. Run **Fault Tree FIRST** (generate the map of possible causes), then **Hypothesis-Driven SECOND** (test each branch systematically). Fault Tree provides the map; Hypothesis-Driven provides the discipline to traverse it.

---

## 1. Fault Tree Analysis

**Counters:** Jumping to conclusions without systematically mapping failure paths.

Before testing any hypothesis, build a fault tree: start with the observed symptom as the root node, then branch into all possible causes at each level (code, configuration, data, environment, dependency). Use AND/OR gates — some failures require multiple conditions (AND), others have independent triggers (OR). This tree becomes your investigation roadmap. Prioritize branches by likelihood and testability, but do NOT prune branches just because they seem unlikely — unlikely causes that are easy to test should be tested early.

## 2. Hypothesis-Driven Investigation

**Counters:** Making random changes and hoping something works — the "shotgun debugging" anti-pattern.

For each hypothesis, follow the strict protocol:

- **PREDICT** — "If hypothesis H is correct, then test T should produce result R"
- **TEST** — execute exactly one test
- **OBSERVE** — record the actual result
- **CONCLUDE** — matched = SUPPORTED, failed = ELIMINATED, unexpected = new evidence

Never skip the PREDICT step — without a prediction, you cannot distinguish a meaningful result from noise. Never change more than one variable per test — if you change two things and the bug disappears, you don't know which change fixed it.

## 3. Occam's Razor

**Counters:** Pursuing elaborate explanations when simple ones have not been ruled out.

Before investigating multi-component interaction bugs, race conditions, or framework-level issues, verify simple explanations first: typo in variable name, wrong file path, missing import, incorrect config value, stale cache, wrong environment variable. These "boring" causes account for the majority of bugs. Only escalate to complex hypotheses AFTER the simple ones are eliminated. If your current hypothesis requires 3+ things to go wrong simultaneously, step back and look for a single-point failure.

## 4. Counterfactual Thinking

**Counters:** Failing to isolate causation by not asking "what if we changed just this one thing?"

When you have a hypothesis about the root cause, construct a counterfactual: "If I change ONLY this one variable/config/line, the bug should disappear (or appear)." Execute the counterfactual test. If the bug persists after your targeted change, your hypothesis is wrong — the cause is elsewhere. If the bug disappears, you have strong causal evidence. This is more powerful than correlation ("the bug appeared after deploy X") because it tests the mechanism, not just the timeline.

---

## When NOT to Think

Skip structured reasoning models when the situation does not benefit:

- **Obvious single-cause bugs** — if the error message names the exact file, line, and cause (e.g., `TypeError: Cannot read property 'x' of undefined at foo.js:42`), fix it directly. Do not build a fault tree for a null reference with a stack trace.
- **Reproducing a known fix** — if you already know the root cause from a previous investigation or the user told you exactly what is wrong, skip hypothesis-driven investigation and go straight to the fix.
- **Typos, missing imports, wrong paths** — if Occam's Razor would immediately resolve it, apply the fix without invoking the full model. The model exists for when simple checks fail, not to gate simple checks.
- **Reading error logs** — reading and understanding error output is normal debugging, not a "decision point." Only invoke models when you have multiple plausible hypotheses and need to choose which to test first.
