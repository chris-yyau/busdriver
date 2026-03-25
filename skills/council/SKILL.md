---
name: council
description: >
  Convene a 4-voice AI council (Claude Architect + Fresh Claude Skeptic + Gemini Pragmatist + Codex Critic) for diverse perspectives.
  Use when the user asks "what would a good group of people think/design/do",
  wants multiple opinions, asks for "ideas", "thoughts", "suggestions", "advice",
  "input", "feedback", "recommendations", says "council", "perspectives",
  "what would others think", "group wisdom", "diverse viewpoints", "what do you all think",
  or needs group deliberation on decisions, tradeoffs, design choices, architecture,
  or strategy. NOT for simple tasks with clear answers — only for ambiguous problems
  that benefit from multiple lenses.
---

# Council

Convene four advisors — the in-context Claude plus three fresh agents — for diverse perspectives. Each gives an independent perspective, then synthesize into a compressed verdict.

## Roles (Fixed)

| Voice | Method | Role | Lens |
|---|---|---|---|
| Claude (you) | In-context | Architect | Correctness, maintainability, long-term implications |
| Fresh Claude | Agent tool (clean memory) | Skeptic | Challenge assumptions, question premises, propose simplest alternative |
| Gemini | dispatch-cli | Pragmatist | Shipping speed, simplicity, user impact, practical tradeoffs |
| Codex | dispatch-cli | Critic | Edge cases, risks, failure modes, what could go wrong |

The Fresh Claude Skeptic has **zero conversation context** — it receives only the question and optional code snippets. Its unique value is immunity to conversational drift: it sees what the anchored council has stopped noticing. If the question itself is wrong or the answer is simpler than the council thinks, the Skeptic says so.

## Process

### Step 1: Extract the Question

Get the question from skill args or infer from conversation context. If vague, ask ONE clarifying question before proceeding.

### Step 2: Context Check

If the question is **codebase-specific** (references files, architecture, specific code):
- Gather relevant file snippets (max ~2000 tokens total)
- Include them in the dispatch prompt under a `## Context` section

If it's a **general** design/strategy question, skip this — just send the question.

### Step 3: Form Your Perspective FIRST

Think through your Architect position **before** seeing external responses. This prevents anchoring on their answers.

Write down:
- **Position**: 1-2 sentence clear stance
- **Reasoning**: 3 key points
- **Risk**: The biggest risk with your approach

Hold this. You'll include it in the report after dispatch completes.

### Step 4: Dispatch Fresh Claude + Gemini + Codex

Launch all three agents in parallel. Use a **single message with multiple tool calls** to maximize concurrency.

**4a. Fresh Claude (Skeptic)** — via Agent tool (starts with clean memory):

```
Agent(
  description="Council Skeptic",
  prompt="You are the Skeptic on a council of four AI advisors. [QUESTION + CONTEXT]. Your role is Skeptic — you have NO prior context about this conversation. Focus on: challenging assumptions, questioning whether the problem is framed correctly, and proposing the simplest possible alternative. If the question itself is wrong or the answer is simpler than expected, say so. Give your perspective as: 1. Position (1-2 sentences) 2. Reasoning (3 points) 3. Risk 4. Surprise. Under 300 words. Be opinionated, no hedging.",
  model="opus"
)
```

**4b. Pre-check CLI availability, then dispatch:**

Before dispatching, check CLI availability and find the dispatch script:

```bash
HAS_GEMINI=$(which gemini &>/dev/null && echo yes || echo no)
HAS_CODEX=$(which codex &>/dev/null && echo yes || echo no)
DISPATCH="${CLAUDE_PLUGIN_ROOT}/skills/dispatch-cli/scripts/dispatch.sh"
```

Then dispatch available CLIs in a **single Bash call** with both as background processes. This is critical — if Gemini and Codex are separate parallel Bash tool calls, one failing cancels the other. A single call with `&` and `wait` keeps them independent:

```bash
DISPATCH="${CLAUDE_PLUGIN_ROOT}/skills/dispatch-cli/scripts/dispatch.sh"
[ "$(which gemini &>/dev/null && echo yes || echo no)" = "yes" ] && "$DISPATCH" \
  --cli gemini --timeout 120 \
  --prompt "<Pragmatist prompt>" &
[ "$(which codex &>/dev/null && echo yes || echo no)" = "yes" ] && "$DISPATCH" \
  --cli codex --timeout 120 \
  --prompt "<Critic prompt>" &
wait
```

**Prompt template** for Gemini/Codex (same structure as Skeptic but with their role/lens):

**For Gemini:** Role = "Pragmatist", Lens = "shipping speed, simplicity, user impact, practical tradeoffs"
**For Codex:** Role = "Critic", Lens = "edge cases, risks, failure modes, what could go wrong"

**IMPORTANT:** Launch the Agent tool call AND the single Bash dispatch call (containing both Gemini and Codex as background processes) in the **same message** so all three voices run concurrently. Do NOT use separate Bash tool calls for Gemini and Codex — one failing will cancel the other.

**Degradation:** The Fresh Claude (Agent tool) is always available, so the council always has at least 2 voices (Architect + Skeptic). If one CLI is missing → 3-voice council. If both are missing → 2-voice council. Note the composition in the report.

### Step 5: Read Output and Synthesize

Read the Fresh Claude output from the Agent tool result. Read the Gemini/Codex output from `/tmp/dispatch-{cli}-*.txt`.

<CRITICAL>
SYNTHESIZER BIAS GUARDRAILS

You are both a council member AND the synthesizer. This is a conflict of interest. Rules:

1. NEVER dismiss an external perspective without stating why
2. If any voice raised a point you didn't consider, EXPLICITLY credit it
3. The "Strongest dissent" section is MANDATORY — even if you disagree with it
4. If two or more voices agree against you, seriously consider that you might be wrong
5. Raw positions appear ABOVE the synthesis — the user can always check your work
6. The Fresh Claude Skeptic's premise challenges deserve special weight — they see what you can't because of conversational anchoring
</CRITICAL>

### Step 6: Present the Report

**Compressed format (always use this):**

```
## Council: [short question]

**Claude (Architect):** [position in 1-2 sentences]
[1-line key reasoning]

**Fresh Claude (Skeptic):** [position in 1-2 sentences]
[1-line key reasoning]

**Gemini (Pragmatist):** [position in 1-2 sentences]
[1-line key reasoning]

**Codex (Critic):** [position in 1-2 sentences]
[1-line key reasoning]

### Verdict
- **Consensus:** [where they agree]
- **Strongest dissent:** [the most important disagreement — who said it and why]
- **Premise check:** [did the Skeptic challenge the question itself? If so, what was the challenge?]
- **Recommendation:** [synthesized best path forward]
```

**Self-contained rule:** When the question involves numbered items (e.g., "6 proposed fixes"), ALL references — in individual voice positions AND the verdict — MUST restate each item inline, not just by number. The user should never need to scroll up. Example: "Fix #1 (add frontend-design to routes) and skip #3 (new plugin-dev entry)" instead of "Fix #1 and skip #3". This applies to every voice's position text, not only the final synthesis.

If an agent failed or timed out, note it inline: `**Gemini (Pragmatist):** (unavailable — rate limited)`

Keep the entire report **scannable on a phone screen**. No ceremony. No preamble.

## Multi-Round

Default: **one round**. The council convenes, delivers the verdict, and dissolves.

If the user asks for another round ("ask them again", "what would they say to that", "follow up with the council", "another round"):

1. For Gemini + Codex: include prior council positions in the dispatch prompt as context
2. **For Fresh Claude Skeptic: include ONLY the new follow-up question + original question — do NOT include prior council positions.** This is critical — the Skeptic's value comes from clean memory. If you anchor them on prior positions, they become a fifth confirming voice instead of an independent challenger.
3. Add the user's follow-up question
4. Frame for Gemini/Codex: "The council previously said [positions]. The user now asks: [follow-up]. Respond to the other advisors' positions AND the new question."
5. Frame for Skeptic: "[Original question]. Follow-up: [new question]." — NO prior positions, NO council output.
5. Synthesize again with the same guardrails

No file persistence needed — prior output is in the conversation context.

### Step 7: Auto-Save Lesson (Recommendation Delta Filter)

<CRITICAL>
This step is AUTOMATIC. Do NOT ask the user whether to save. Evaluate the criteria below immediately after presenting the verdict. If the filter triggers, save the lesson and tell the user you saved it. If it doesn't trigger, say nothing — no "want me to save?" prompts. The user should never need to remind you to do this.

Note: Lesson files written to `~/.claude/notes/` are expected to be staged and committed alongside other session changes — they are part of the git-tracked notes system, not unintended side effects.
</CRITICAL>

After presenting the verdict, evaluate whether the council produced a **recommendation delta** — a case where external input changed the final recommendation from what you (Claude) would have done alone.

**Capture when ANY of these are true:**
- The strongest dissent changed the final recommendation (your initial position was overridden)
- Two or more external voices agreed against your position
- An external voice raised a risk/edge-case you explicitly did not consider in Step 3
- The Skeptic challenged the premise and the challenge was valid (question was reframed)
- A severity re-rating occurred (something you rated LOW was upgraded to HIGH, or vice versa)

**Do NOT capture when:**
- All four voices agreed with the Architect's initial position (no delta — confirms existing knowledge)
- Dissent was noted but the final recommendation matches the Architect's Step 3 position unchanged
- The council was informational only (no decision was at stake)

**When the filter triggers**, immediately write a memory file using the Write tool:

**Path:** `~/.claude/notes/lesson-council-{YYYY-MM-DD}-{slug}.md` (if slug collides with existing file, append `-2`, `-3`, etc.)

**Format:**
```markdown
---
name: council-lesson-{slug}
description: {one-line: what changed and why}
type: feedback
last_validated: "{YYYY-MM-DD}"
---

**Decision:** {what was being decided}
**Initial position:** {what Claude would have done alone}
**What changed:** {the dissent/insight that shifted the recommendation}
**Who changed it:** {Fresh Claude Skeptic/Gemini/Codex/multiple}
**Final recommendation:** {what we actually decided}

**Why:** {why the external perspective was better}
**How to apply:** {when this lesson should inform future decisions}
```

Then add a one-line pointer to `NOTES.md`.

**Keep it tight** — the entire memory file should be <150 words. If you can't compress the lesson to that, it's probably not a single lesson.

## When NOT to Convene

Do NOT fire the council for:
- Simple factual questions
- Clear implementation tasks ("add a button", "fix this typo")
- Bug fixes with obvious causes
- Tasks that need execution, not deliberation

If the question doesn't benefit from multiple perspectives, say so and just answer directly. The council is for **decisions and tradeoffs**, not for tasks with clear right answers.
