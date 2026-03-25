---
name: reflect
description: >
  Reflect on conversation mistakes, corrections, or lessons and save as feedback notes.
  Use when the user says "reflect on that", "remember this mistake", "learn from that",
  "what went wrong", or after a correction/failure in the current session. Outputs feedback
  notes to ~/.claude/notes/ (high trust, always loaded). For analyzing tool-use observation
  logs, the ECC v2 observer handles this automatically.
---

# /reflect — Session Reflection

Analyze mistakes, corrections, and lessons from the current conversation and save them as feedback memories. These are high-trust, always-loaded memories that prevent repeating the same mistakes.

## When to Use

- After you made a mistake and the user corrected you
- After a failed approach that required a different solution
- When the user says "reflect", "remember this", "learn from that"
- After a productive session with lessons worth preserving
- When the user explicitly asks you to save something to memory

## When NOT to Use

- For analyzing tool-use observation logs → handled automatically by ECC v2 observer
- For saving user preferences or project context → use auto-memory directly
- For inferred behavioral patterns → handled automatically by ECC v2 observer (instincts)

## Process

### Step 1: Identify Lessons

Review the current conversation for:

1. **Corrections** — user rejected your approach and told you to do something differently
2. **Failed approaches** — something didn't work and you had to change strategy
3. **Surprising outcomes** — results you didn't expect that revealed a gap in understanding
4. **Explicit requests** — user said "remember this" or "don't do that again"

For each lesson, draft a feedback memory with:
- **Rule**: what to do (or not do) in the future
- **Why**: the reason behind it (the incident or correction)
- **How to apply**: when this lesson should kick in

### Step 2: Check for Duplicates

Before presenting to the user, check existing memories for overlap:
- Read `~/.claude/notes/NOTES.md` index
- If a similar lesson exists, UPDATE the existing memory instead of creating a duplicate
- If the new lesson contradicts an existing memory, flag it to the user

### Step 3: Present for Confirmation

Show each proposed memory to the user before saving:

```
Proposed memory: [name]
  Rule: [what to do/not do]
  Why: [what happened]
  How to apply: [when this matters]
  Duplicate check: [none found | updating existing: <name>]

Save this? [yes/skip/edit]
```

This confirmation step prevents bad reflections from becoming permanent behavioral distortions. The user can approve, skip, or request edits.

### Step 4: Save Approved Memories

For each approved lesson, write a memory file:

```markdown
---
name: [slug]
description: [one-line — specific enough to judge relevance in future conversations]
type: feedback
last_validated: "{YYYY-MM-DD}"
---

[Rule statement]

**Why:** [the incident or correction that prompted this]
**How to apply:** [when/where this guidance kicks in]
```

**Path:** `~/.claude/notes/lesson-reflect-{YYYY-MM-DD}-{slug}.md`

Then add a one-line pointer to `NOTES.md`.

### Step 5: Report

Show the user:
1. How many lessons identified
2. Which were saved (with names)
3. Which were skipped and why
4. Any duplicates found and updated

## Quality Guidelines

- **<150 words per memory** — if you can't compress it, it's not a single lesson
- **Lead with the rule** — the first line should be actionable
- **Be specific** — "verify symlinks after creation" not "be more careful"
- **Include why** — without context, future-you can't judge edge cases
- **One lesson per file** — don't combine unrelated corrections

## What Does NOT Belong Here

- Code patterns or conventions (derivable from codebase)
- Git history details (use `git log`)
- Debugging solutions (the fix is in the code)
- Anything in CLAUDE.md already
- Ephemeral task details

## Related Commands

- `/instinct-status` — view active instincts with confidence scores
- `ls ~/.claude/notes/` — see all saved notes
