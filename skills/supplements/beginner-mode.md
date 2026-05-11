---
name: beginner-mode
description: Explanation discipline for when the user is new to a domain — gloss terms on first use, accept interrupt-and-resume questions ("what does X mean?") at any time
targets: busdriver:brainstorming, busdriver:grill-me
type: supplement
opt_in: true
source: in-house (2026-05-05 grill-me integration)
added: 2026-05-05
---

# Beginner-Mode Supplement

> Load alongside `busdriver:brainstorming` or `busdriver:grill-me` when the user is new to the domain under discussion. Activates via auto-memory signal OR explicit user trigger phrase.

## When This Supplement Loads

Two activation routes — either is sufficient:

1. **Memory signal** — auto-memory contains a `user`-type entry indicating the user is new to the current domain (e.g. "user is new to busdriver pipeline; explain pipeline/skill/agent/hook/gate terms"). The targeting skill reads memory at session start and loads this supplement if a relevant entry exists.
2. **Trigger phrase** — user says any of: "I'm new to this", "explain like I'm a beginner", "beginner mode", "I don't understand X", "what does X mean", "what's X", "explain X". The targeting skill loads this supplement and continues.

If neither route fires, this supplement is NOT loaded and skills behave normally.

## Auto-Memory Protocol (canonical reference)

Auto-memory is the Claude global file-based memory system documented in the user's global system prompt. The relevant operations for this supplement:

- **Read protocol:** Memory files live in `~/.claude/projects/<current-project>/memory/`. The `MEMORY.md` index lists every memory file with a one-line hook. Each individual memory is a frontmatter'd `.md` file with fields `name`, `description`, `type` (one of `user`, `feedback`, `project`, `reference`). To detect a knowledge-gap signal, scan `MEMORY.md` for entries whose `description` references "new to", "learning", "unfamiliar with" combined with a domain keyword relevant to the current topic; Read the matching file(s) for full content.
- **Write protocol:** Use the Write tool to create or update memory files in the same directory, then add a one-line pointer to `MEMORY.md`. Frontmatter `type: user` for knowledge-gap entries. Refer to the global system prompt's "auto memory" section for canonical schema and rules — do not reinvent the format.
- **Off-ramp updates:** When the user says "I get it" / "I know this now" / "stop explaining" for a specific domain, update the corresponding `user_*.md` memory file: either remove the domain from the entry's content, or — if the entry is empty afterward — delete the file entirely using the Bash tool (`rm <path>`). Update or remove the `MEMORY.md` pointer to match.
- **Fallback:** If the memory directory does not exist or is unreadable, treat the user as having no captured knowledge gaps; rely entirely on the trigger-phrase activation route. Do not error.

## Behavior While Loaded

### Glossing Discipline

On the **first use** of a domain term in this session, gloss it inline with a one-line plain-language definition in parentheses. Examples:

- "We need a PreToolUse hook (a script registered in `hooks.json` that runs before Claude executes a specific tool — it can block, log, or modify the call) for this gate."
- "The sentinel-bracketed block (an HTML-comment-delimited section like `<!-- X-BEGIN -->...<!-- X-END -->` that lets a parser-free scanner find an exact block) goes here."

Subsequent uses of the same term in the session are clean — no repeated glossing.

**Use plain language.** Do not say "this is also called X" or chain synonyms. One short definition, one common analogue if useful, then continue.

**Detect domain terms.** Treat any of these as candidates for glossing on first use:
- Tool/CLI names (PreToolUse, PostToolUse, Skill tool, Agent tool, MCP, hooks.json)
- Pipeline concepts (gate, intensifier, supplement, marker, sentinel, fail-closed, blueprint-review)
- Architecture patterns (auto-memory, supplement-loading-protocol, dispatch, orchestrator)
- Anything ending in -SDK / -API / -RPC / -CLI / -ORM that the user may not know

When in doubt, gloss. Over-glossing is mildly verbose; under-glossing leaves the user confused without knowing they should ask.

### Interruption Protocol

The user may interrupt at any time with any of:
- "What does X mean?"
- "What's X?"
- "Explain X"
- "I don't understand X"

Respond with:
1. A brief gloss of X (one to three sentences, plain language).
2. A one-line restatement of the question or step we were on before the interrupt.
3. Resume from that exact point.

Do NOT lose state across interrupts. Do NOT reset the grilling decision tree or the brainstorming clarifying-question sequence.

If the user asks "what does X mean?" mid-grill on a recommendation block, gloss X, then say "Resuming Q3 — your pick from A/B/C/D/E/F?"

### Off-Ramp

If the user says any of:
- "I get it"
- "I know this now"
- "stop explaining"
- "no more glossing"

Stop glossing terms in this session. Update auto-memory to remove or downgrade the relevant knowledge-gap entry. Do NOT keep glossing once asked to stop.

### Domain Boundaries

Beginner-mode applies to the **current domain only**. If the user is new to the busdriver pipeline but expert in TypeScript, do not gloss TypeScript terms. Memory entries are domain-scoped — read the entry to know what to gloss.

If a term comes up that's outside the captured knowledge gaps, default to NOT glossing — but be ready to handle an interrupt.

## What This Supplement Does Not Do

- It does NOT slow the conversation with mandatory comprehension checks.
- It does NOT replace clarifying questions — it changes how terms are phrased while questions are asked.
- It does NOT auto-load in every session — only when memory or trigger phrase activates it.
- It does NOT modify the design doc (no glossary appendix). Glossing is conversational, not artifactual.

## Interaction With Other Skills

- **brainstorming**: glossing applies to clarifying questions, approach descriptions, and design-section presentations. Step 5.5 (offer grill) and Step 6 (write design doc) are not affected.
- **grill-me**: glossing applies to recommended-answer blocks, option tables, and option descriptions. The closing sentinel block (Key Decisions) is NOT itself glossed — it's a clean artifact.
- **council**: out of scope; if added later, register `council` as a target.
