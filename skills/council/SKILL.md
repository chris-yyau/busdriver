---
name: council
description: >
  Convene a 5-voice AI council (Claude Architect + Fresh Claude Skeptic + Agy Pragmatist + Codex Critic + Grok Researcher) for diverse perspectives.
  Use when the user asks "what would a good group of people think/design/do",
  wants multiple opinions, asks for "ideas", "thoughts", "suggestions", "advice",
  "input", "feedback", "recommendations", says "council", "roundtable", "perspectives",
  "what would others think", "group wisdom", "diverse viewpoints", "what do you all think",
  or needs group deliberation on decisions, tradeoffs, design choices, architecture,
  or strategy. NOT for simple tasks with clear answers — only for ambiguous problems
  that benefit from multiple lenses.
origin: custom
---

# Council

Convene five advisors — the in-context Claude plus four fresh agents — for diverse perspectives. Each gives an independent perspective, then synthesize into a compressed verdict.

## Roles (Fixed)

| Voice | Method | Role | Lens | Configurable |
|---|---|---|---|---|
| Claude (you) | In-context | Architect | Correctness, maintainability, long-term implications | No (in-context) |
| Fresh Claude | Agent tool (clean memory) | Skeptic | Challenge assumptions, question premises, propose simplest alternative | No (Agent tool) |
| Configurable | dispatch-cli | Pragmatist | Shipping speed, simplicity, user impact, practical tradeoffs | Yes: `council.pragmatist` (default: agy) |
| Configurable | dispatch-cli | Critic | Edge cases, risks, failure modes, what could go wrong | Yes: `council.critic` (default: codex) |
| Configurable | dispatch-cli | Researcher | Evidence, prior art, current state, factual grounding | Yes: `council.researcher` (default: grok, fallback: droid) |

**CLI routing:** Pragmatist, Critic, and Researcher CLIs are resolved from `.claude/busdriver.json` via `resolve_role_cli()`. Each role accepts a route array — the resolver walks it left-to-right and returns the first available CLI (e.g., `"council.pragmatist": ["agy", "droid"]` falls back to Droid if Agy is missing). If every CLI in the chain is missing, that voice is skipped and noted in the report; other voices still fire. Changing the CLI only changes which binary receives the prompt — the role framing (Pragmatist lens, Critic lens, Researcher lens) is always the same. **Trade-off to know:** fallback preserves availability but dilutes role identity — Droid filling in as Pragmatist is no longer "Agy's strategic lens." Accept this when resilience matters more than signal purity. See README for per-role routing docs.

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

### Step 4: Dispatch Fresh Claude + Agy + Codex + Grok

Launch all four external agents in parallel. Use a **single message with multiple tool calls** to maximize concurrency.

**4a. Fresh Claude (Skeptic)** — via Agent tool (starts with clean memory):

```text
Agent(
  description="Council Skeptic",
  prompt="You are the Skeptic on a council of five AI advisors. [QUESTION + CONTEXT]. Your role is Skeptic — you have NO prior context about this conversation. Focus on: challenging assumptions, questioning whether the problem is framed correctly, and proposing the simplest possible alternative. If the question itself is wrong or the answer is simpler than expected, say so. Give your perspective as: 1. Position (1-2 sentences) 2. Reasoning (3 points) 3. Risk 4. Surprise. Under 300 words. Be opinionated, no hedging.",
  model="opus"  # Uses the "opus" alias — valid Agent tool enum value for highest-reasoning model
)
```

**4b. Pre-check CLI availability, then dispatch:**

Before dispatching, check CLI availability and find the dispatch script:

```bash
# Source shared CLI library and resolve roles from config
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve-cli.sh"
PRAGMATIST_CLI=$(resolve_role_cli "council.pragmatist")
CRITIC_CLI=$(resolve_role_cli "council.critic")
RESEARCHER_CLI=$(resolve_role_cli "council.researcher")
DISPATCH="${CLAUDE_PLUGIN_ROOT}/skills/dispatch-cli/scripts/dispatch.sh"

# Dispatch available voices — capture PIDs so wait blocks on the actual processes
# IMPORTANT: Use heredocs (<<'DELIM') NOT --prompt "..." to avoid shell escaping bugs
# with quotes, backticks, $, and newlines in prompt text.
PIDS=()
if [[ "$PRAGMATIST_CLI" != "none" && "$PRAGMATIST_CLI" != "builtin" && ! "$PRAGMATIST_CLI" =~ ^(missing|unsupported): ]]; then
  # DROID_AUTO_LEVEL=low: if Pragmatist falls back to droid (per the route
  # array's droid fallback), constrain the agent to file-write tier only.
  # Pragmatist is a synthesis role — no need for installs, network fetches,
  # or git ops. Has no effect when PRAGMATIST_CLI=agy (env var is ignored
  # by non-droid CLIs). If droid fails at low tier, the voice drops cleanly
  # rather than running at the default 'high' privilege.
  DROID_AUTO_LEVEL=low "$DISPATCH" --cli "$PRAGMATIST_CLI" --timeout 300 <<'PRAGMATIST_PROMPT' &
<Pragmatist prompt>
PRAGMATIST_PROMPT
  PIDS+=("$!")
fi
if [[ "$CRITIC_CLI" != "none" && "$CRITIC_CLI" != "builtin" && ! "$CRITIC_CLI" =~ ^(missing|unsupported): ]]; then
  # DROID_AUTO_LEVEL=low: same reasoning as Pragmatist above — Critic is a
  # synthesis role; if it falls back to droid, file-write tier is sufficient.
  DROID_AUTO_LEVEL=low "$DISPATCH" --cli "$CRITIC_CLI" --timeout 300 <<'CRITIC_PROMPT' &
<Critic prompt>
CRITIC_PROMPT
  PIDS+=("$!")
fi
if [[ "$RESEARCHER_CLI" != "none" && "$RESEARCHER_CLI" != "builtin" && ! "$RESEARCHER_CLI" =~ ^(missing|unsupported): ]]; then
  "$DISPATCH" --cli "$RESEARCHER_CLI" --timeout 300 <<'RESEARCHER_PROMPT' &
<Researcher prompt>
RESEARCHER_PROMPT
  PIDS+=("$!")
fi
(( ${#PIDS[@]} )) && wait "${PIDS[@]}"
```

This is a **single Bash call** with all three CLI dispatches as background processes. This is critical — if Agy, Codex, and Grok are separate parallel Bash tool calls, one failing cancels the others. A single call with `&` and `wait` keeps them independent.

**NEVER wrap dispatches in subshells `()`**. The pattern `( cmd & ) && wait` does NOT work — the subshell exits immediately after backgrounding, so `wait` has nothing to wait for. Always background directly and capture PIDs with `$!`.

**Prompt template** for Agy/Codex/Grok (same structure as Skeptic but with their role/lens). When the resolver falls back to Droid in any slot, the same role/lens text is sent — these labels track the *default primary* CLI per role.

**For Agy:** Role = "Pragmatist", Lens = "shipping speed, simplicity, user impact, practical tradeoffs"
**For Codex:** Role = "Critic", Lens = "edge cases, risks, failure modes, what could go wrong"
**For Grok:** Role = "Researcher", Lens = "evidence, prior art, current state — look up similar past decisions, current code state of the repo, and external evidence relevant to the question. Provide links, quotes, and sources — NOT conclusions stated as settled fact. Your factual/empirical claims are treated as UNVERIFIED by default until checked against local evidence, so for each load-bearing claim name the cheap local check (command / file / grep) that would confirm or refute it. Cite what you find; flag claims that lack grounding."

**IMPORTANT:** Launch the Agent tool call AND the single Bash dispatch call (containing Agy + Codex + Grok as background processes) in the **same message** so all four external voices run concurrently. Do NOT use separate Bash tool calls — one failing will cancel the others.

**Missing CLI handling:** Each role's route array is walked left-to-right; the first available CLI wins. If every CLI in the chain resolves to `none`, `builtin`, `missing:<cli>`, or `unsupported:<cli>` (the last fires when a stale config references a removed backend like opencode/amp/claude/aider — migration warning goes to stderr), that voice is skipped and the report notes its absence as `(unavailable)`. The remaining voices still convene. If the Skeptic Agent call fails (rate limit, timeout), same rule applies. Typical minimum is 2 voices (Architect + Skeptic, 40% of full strength); absolute floor is 1 voice (Architect alone) if the Skeptic Agent call also fails. Always note the composition in the report — and when a fallback fires (e.g., Droid serving as Pragmatist because Agy was missing), note that explicitly so the report doesn't misattribute the lens.

### Step 5: Read Output and Synthesize

Read the Fresh Claude output from the Agent tool result. Read the Agy/Codex/Grok output from the path printed by dispatch.sh to stderr (typically `${TMPDIR:-/tmp}/dispatch-{cli}-*.txt`; on macOS, TMPDIR is `/var/folders/...`, not `/tmp`). When the resolver falls back to Droid in the Researcher slot (grok unavailable), the output filename is `dispatch-droid-*.txt` and the report should attribute "Droid (Researcher, fallback)" rather than "Grok (Researcher)".

**CRITICAL: Read the ENTIRE output file, not just the first few lines.** CLI output files contain noise before the actual response:
- **Agy:** Dumps MCP server initialization logs (e.g., `Registering notification handlers...`, `Loading extension...`) before the response. The actual answer may be 50+ lines deep.
- **Codex:** Echoes a header block (workdir, model, session id, the full prompt) before the response. The actual answer starts after the prompt echo ends.
- **Both:** May duplicate output or include trailing metadata. Always scan the full file.

If you read only the first ~30 lines and see noise/prompt headers, **you have NOT read the response yet.** Keep reading.

<CRITICAL>
SYNTHESIZER BIAS GUARDRAILS

You are both a council member AND the synthesizer. This is a conflict of interest. Rules:

1. NEVER dismiss an external perspective without stating why
2. If any voice raised a point you didn't consider, EXPLICITLY credit it
3. The "Strongest dissent" section is MANDATORY — even if you disagree with it
4. If two or more voices agree against you, seriously consider that you might be wrong
5. Raw positions appear ABOVE the synthesis — the user can always check your work
6. The Fresh Claude Skeptic's premise challenges deserve special weight — they see what you can't because of conversational anchoring
7. **Researcher claims are UNVERIFIED by default (taint by source-class, not self-report).** A factual/empirical claim or citation from the Researcher (Grok/Droid) may NOT justify a **hard** recommendation on its own. To promote it, verify it IN THIS REPORT against pasted local evidence — a grep/Read/run output, the cited source text, or user-provided data — OR route it to a fresh clean-memory verifier (a second Skeptic-style Agent call). If you cannot cheaply verify a load-bearing Researcher claim, mark it `[unverified]` and downgrade any recommendation that rests on it to **exploratory**. Rule 1's "state why" does NOT satisfy this — for a Researcher fact, paste the evidence or mark it unverified. (Both documented Researcher failures — a fabricated quantitative claim and real-but-off-task citations — happened while the narrated "flag claims that lack grounding" guidance was already present; narration alone is insufficient.)
8. **Settling check (mandatory).** Every **hard** recommendation in the Verdict must name a settling check — the cheapest concrete local command / file / test / data whose result would confirm or refute it, plus the expected disconfirming outcome. If no cheap local check can be named, the item ships as **exploratory**, not a hard recommendation. Run the check in-turn when it is cheap and local; do NOT force a "command" onto questions that have none (strategy/naming/product) — for those, the honest settling check is the evidence or experiment that would decide, and absent that they stay exploratory.
</CRITICAL>

### Step 6: Present the Report

**Compressed format (always use this):**

```markdown
## Council: [short question]

**Claude (Architect):** [position in 1-2 sentences]
[1-line key reasoning]

**Fresh Claude (Skeptic):** [position in 1-2 sentences]
[1-line key reasoning]

**Agy (Pragmatist):** [position in 1-2 sentences]
[1-line key reasoning]

**Codex (Critic):** [position in 1-2 sentences]
[1-line key reasoning]

**Grok (Researcher):** [position in 1-2 sentences]
[1-line key reasoning + key evidence cited]
(If grok was unavailable and Droid handled the slot, use **Droid (Researcher, fallback):** instead.)

### Verdict
- **Consensus:** [where they agree]
- **Strongest dissent:** [the most important disagreement — who said it and why]
- **Premise check:** [did the Skeptic challenge the question itself? If so, what was the challenge?]
- **Recommendation:** [synthesized best path forward — mark each item **hard** or **exploratory**]
- **Settling check:** [for each HARD recommendation, the cheapest concrete local check (command/file/test/data) + its expected disconfirming result. None nameable → the item is exploratory, not hard.]
- **Researcher claims:** [list any factual/empirical Researcher claim you relied on, each tagged `verified` (with the pasted/cited evidence) or `[unverified]`. An `[unverified]` claim may not justify a hard recommendation — per Synthesizer Guardrail 7.]
```

**Self-contained rule:** When the question involves numbered items (e.g., "6 proposed fixes"), ALL references — in individual voice positions AND the verdict — MUST restate each item inline, not just by number. The user should never need to scroll up. Example: "Fix #1 (add frontend-design to routes) and skip #3 (new plugin-dev entry)" instead of "Fix #1 and skip #3". This applies to every voice's position text, not only the final synthesis.

If an agent failed or timed out, note it inline: `**Agy (Pragmatist):** (unavailable — rate limited)`

Keep the entire report **scannable on a phone screen**. No ceremony. No preamble.

## Multi-Round

Default: **one round**. The council convenes, delivers the verdict, and dissolves.

If the user asks for another round ("ask them again", "what would they say to that", "follow up with the council", "another round"):

1. For Agy + Codex + Grok: include prior council positions in the dispatch prompt as context
2. **For Fresh Claude Skeptic: include ONLY the new follow-up question + original question — do NOT include prior council positions.** This is critical — the Skeptic's value comes from clean memory. If you anchor them on prior positions, they become a fifth confirming voice instead of an independent challenger.
3. Add the user's follow-up question
4. Frame for Agy/Codex/Grok: "The council previously said [positions]. The user now asks: [follow-up]. Respond to the other advisors' positions AND the new question."
5. Frame for Skeptic: "[Original question]. Follow-up: [new question]." — NO prior positions, NO council output.
6. Synthesize again with the same guardrails

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
- All four external voices agreed with the Architect's initial position (no delta — confirms existing knowledge)
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
**Who changed it:** {Fresh Claude Skeptic/Agy/Codex/Grok/Droid/multiple}
**Final recommendation:** {what we actually decided}

**Why:** {why the external perspective was better}
**How to apply:** {when this lesson should inform future decisions}
```

Then add a one-line pointer to `~/.claude/notes/NOTES.md`.

**Keep it tight** — the entire memory file should be <150 words. If you can't compress the lesson to that, it's probably not a single lesson.

## When NOT to Convene

Do NOT fire the council for:
- Simple factual questions
- Clear implementation tasks ("add a button", "fix this typo")
- Bug fixes with obvious causes
- Tasks that need execution, not deliberation

If the question doesn't benefit from multiple perspectives, say so and just answer directly. The council is for **decisions and tradeoffs**, not for tasks with clear right answers.

| Instead of council | Use |
| --- | --- |
| Verifying whether output is correct | `santa-method` |
| Breaking a feature into implementation steps | `planner` |
| Designing system architecture | `architect` |
| Reviewing code for bugs or security | `code-reviewer` or `santa-method` |
| Straight factual questions | just answer directly |
| Obvious execution tasks | just do the task |

## Related Skills

- `santa-method` — adversarial verification (two-reviewer convergence)
- `knowledge-ops` — persist durable decision deltas to the right location
- `search-first` — gather external reference material before convening
- `architecture-decision-records` — formalize the outcome when the decision becomes long-lived system policy
