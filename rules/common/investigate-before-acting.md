# Investigate Before Acting

> Provenance: distilled from `~/.claude/notes/` Behavioral Rules — Investigate before reversing, Never rollback without asking, Wrong root cause attribution, Read source before analyzing, Scope full problem before solutions, Search before asserting nonexistence, Verify symlinks, Verify subagent claims, Don't modify unrelated infrastructure, Web search before asking, Verify before asserting recalled facts, Never assert metrics without measuring.

## Rule

Before fixing, reverting, or asserting anything, **investigate first**. Read the actual code. Reproduce the problem. Map the full scope. The cost of pausing to understand is minutes; the cost of acting on wrong assumptions is hours of cleanup.

## The Investigation Order

1. **Read** — Read the full source files involved, not grep fragments. Understand what exists before proposing changes.
2. **Reproduce** — Confirm the problem actually exists as described. Check if you caused it yourself.
3. **Scope** — Map ALL affected components before proposing solutions. Partial understanding leads to partial fixes that create new problems.
4. **Search** — Before asserting something doesn't exist, search for it. Absence from your training data does not mean nonexistence. Search the web for unfamiliar terms before asking the user — local grep is not sufficient.
5. **Diagnose** — Identify the root cause. Check if Claude itself caused the issue before blaming external systems.
6. **Then act** — Only after steps 1-5.

## Verify Before Asserting (Recalled Facts)

Memory, prior-session summaries, and training recall are **leads, not ground truth** — stale-by-default. The most common way a wrong assumption reaches the user is stating a *recalled* fact as if it were *verified*.

**Run the check when ALL three hold** (otherwise just answer — do not verify everything):

1. **Load-bearing** — a decision, the user's next action, or a fix depends on the claim being true.
2. **Mutable state** — repo/config/API/counts/"we already did X"/library behavior — not stable logic or math.
3. **From recall** — memory, a prior-session summary, or training — NOT something you observed *this session*.

All three true → confirm against a **primary source** before asserting:

| Claim type | Don't trust | Confirm with |
|------------|-------------|--------------|
| Repo/system state, "we already did X" | memory, prior summary | `git log`/`git show`, `Read`, `gh pr view` |
| Quantitative ("~Nk tokens", "N% coverage", "N files") | estimate, recall | measure / run the command |
| Existence ("there's no skill/file/flag for X") | "I don't recall one" | `grep`/`find`/the skill list |
| Config/behavior ("the gate blocks Y") | memory of the design | Read the actual script/config |
| External library/API/version | training data | Context7 / official docs |

**Escape hatch — hedge instead of asserting.** The sin isn't *recalling*; it's presenting recall as *certain*. When a full check is disproportionate, label the uncertainty: *"From memory, unverified — I believe X."* Zero cost, removes the harm.

**Consensus, analogy, and literature are leads, not evidence.** A multi-agent council verdict, a cited paper, or "this is like X" is a hypothesis — never let any of them authorize a **low-reversibility** action (schema / concurrency / security / public-API / irreversible) without first running the cheapest local check (grep / Read / run / measure) that could *refute* it. The decisive evidence is almost always local (the repo, the API response, the command output), not external. This is why `busdriver:council` verdicts now carry a mandatory *settling check* and tag Researcher factual claims `unverified` until checked.

## Anti-Patterns

| Trap | Fix |
|------|-----|
| Reverting code to "fix" a problem | Diagnose first, fix second, rollback only as last resort — and only with user approval |
| Guessing root cause from symptoms | Read the actual error, trace the actual code path |
| Proposing a fix for file A when the bug is in file B | Scope the full problem across all components first |
| "This doesn't exist" based on training data | Search the filesystem, web, or package registry before asserting |
| Blaming hooks/agents/CI for a recurrence | Check if your own prior action caused it |
| Trusting subagent classifications for deletion | Verify each claim independently — subagents can misclassify custom files |
| Guessing at unfamiliar terms from local files | Web search first, local grep second, ask user last |
| Stating a recalled fact as current without checking | Run the primary-source check, or hedge ("from memory, unverified") |
| Quoting a number from memory ("~20k tokens", "85% coverage") | Measure it — recalled estimates are guesses wearing a fact's clothes |
