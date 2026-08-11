---
name: gateguard
description: Fact-forcing gate that blocks Edit/Write/Bash (including MultiEdit) and demands concrete investigation (importers, data schemas, user instruction) before allowing the action. Measurably improves output quality by +2.25 points vs ungated agents.
metadata:
  origin: community
---

# GateGuard — Fact-Forcing Pre-Action Gate

A PreToolUse hook that forces Claude to investigate before editing. Instead of self-evaluation ("are you sure?"), it demands concrete facts. The act of investigation creates awareness that self-evaluation never did.

## When to Activate

- Working on any codebase where file edits affect multiple modules
- Projects with data files that have specific schemas or date formats
- Teams where AI-generated code must match existing patterns
- Any workflow where Claude tends to guess instead of investigating

## Core Concept

LLM self-evaluation doesn't work. Ask "did you violate any policies?" and the answer is always "no." This is verified experimentally.

But asking "list every file that imports this module" forces the LLM to run Grep and Read. The investigation itself creates context that changes the output.

**Three-stage gate:**

```
1. DENY  — block the first Edit/Write/Bash attempt
2. FORCE — tell the model exactly which facts to gather
3. ALLOW — permit retry after facts are presented
```

No competitor does all three. Most stop at deny.

## Evidence

Two independent A/B tests, identical agents, same task:

| Task | Gated | Ungated | Gap |
| --- | --- | --- | --- |
| Analytics module | 8.0/10 | 6.5/10 | +1.5 |
| Webhook validator | 10.0/10 | 7.0/10 | +3.0 |
| **Average** | **9.0** | **6.75** | **+2.25** |

Both agents produce code that runs and passes tests. The difference is design depth.

## Gate Types

### Edit / MultiEdit Gate (first edit per file)

MultiEdit is handled identically — the batch's target file is gated on first
touch, reading `tool_input.file_path` (where a real MultiEdit payload carries it)
and falling back to any per-edit `file_path`. The code is the authority.

```
Before editing {file_path}, present these facts:

1. List ALL files that import/require this file (use Grep)
2. List the public functions/classes affected by this change
3. If this file reads/writes data files, show field names, structure,
   and date format (use redacted or synthetic values, not raw production data)
4. Quote the user's current instruction verbatim
```

### Write Gate (first new file creation)

```
Before creating {file_path}, present these facts:

1. Name the file(s) and line(s) that will call this new file
2. Confirm no existing file serves the same purpose (use Glob)
3. If this file reads/writes data files, show field names, structure,
   and date format (use redacted or synthetic values, not raw production data)
4. Quote the user's current instruction verbatim
```

### Destructive Bash Gate (every destructive command)

Triggers on: `rm -rf`, `git reset --hard`, `git push --force`, `drop table`, etc.

```
1. List all files/data this command will modify or delete
2. Write a one-line rollback procedure
3. Quote the user's current instruction verbatim
```

### Routine Bash Gate (once per session)

```
1. The current user request in one sentence
2. What this specific command verifies or produces
```

## Quick Start

### Option A: Use the ECC hook (zero install)

The hook at `scripts/hooks/gateguard-fact-force.js` **is registered** in
`hooks/hooks.json` as two PreToolUse entries — `pre:edit-write:gateguard-fact-force`
(matcher `Write|Edit|MultiEdit`) and `pre:bash:gateguard-fact-force` (matcher `Bash`).

Both are scoped to the **`strict` profile**, so they do NOT fire in a default
session (`ECC_HOOK_PROFILE` defaults to `standard`). Turn them on for a session
with:

```bash
ECC_HOOK_PROFILE=strict claude
```

Deliberate staged rollout — promote to `"standard,strict"` in `hooks.json` once
you are satisfied with the behaviour. That promotion is two edits, not one: the
`run-with-flags.js` profile argument AND the shell `case` guard's skip pattern
(see "The shell guard skips; it never enables" below) both currently treat
`standard` as OFF — widen both, or standard sessions will still be skipped
before node ever runs. What it denies, precisely (it is narrower than the
three-stage summary above suggests):

- `Edit`/`Write` — the **first touch of each file** only. Paths under Claude's
  own settings are exempt (`isClaudeSettingsPath`).
- `MultiEdit` — the **first touch of the batch's target file**, same as
  `Edit`/`Write`. The branch reads `tool_input.file_path` (where a real MultiEdit
  payload carries it) and falls back to any per-edit `file_path` for harness
  variants that nest it there. Before #615 it read the per-edit field *only*, so
  the loop body never executed and every MultiEdit fell through to allow —
  `__tests__/gateguard-multiedit.test.ts` locks the fix in.
- `Bash` — destructive commands (`rm -rf`, `git reset --hard`, force-push, `drop
  table`, …) are gated **once per distinct command string**, not every time: the
  hook keys state on a SHA-256 of the exact command
  (`gateguard-fact-force.js:876-879`), so re-running a byte-identical destructive
  command later in the session is allowed straight through. Any command that
  differs by even one character is a new key and gates again. (This contradicts
  the "every destructive command" heading inherited from upstream above — the
  code is the authority.) The first *routine* command of a session is also gated
  once, with a shorter two-fact prompt.

**Not env-contained, on purpose.** These two entries invoke `run-with-flags.js`
directly rather than through `hooks/gate-scripts/lib/sanitized-node.sh`, so a
committed `.claude/settings.json` `env` block *can* switch them off. That is
accepted here and would be wrong for a security gate. Two reasons:

1. **GateGuard guards no boundary.** It improves output quality, so a repo that
   disables it only degrades its own results — unlike `block-no-verify` or
   `config-protection`, where disabling grants a real bypass. That is the line
   the repo already draws: 26 of the 31 JS hooks invoke bare `node`, and the 5
   routed through `sanitized-node.sh` are exactly the security gates.
2. **Containment would make this gate unable to fire at all.**
   `sanitized-node.sh` runs `/usr/bin/env -i`, wiping `ECC_HOOK_PROFILE` along
   with everything else. `getHookProfile()` then falls back to `standard`
   (`scripts/lib/hook-flags.js:19`), which is not in these entries' declared
   `strict` list, so `isHookEnabled()` returns false (`:56-66`) and the hook is
   skipped on **every** invocation. Containment here would not harden the gate;
   it would silently retire it.

Do not "harden" this into `sanitized-node.sh` without first widening the profile
list — otherwise you ship a guard that can never fire, which is worse than no
guard because it reads as coverage.

**The shell guard skips; it never enables.** Each entry is wrapped in

```sh
case "${ECC_HOOK_PROFILE:-standard}" in
  [Ss][Tt][Aa][Nn][Dd][Aa][Rr][Dd]|[Mm][Ii][Nn][Ii][Mm][Aa][Ll]) ;;
  *) node … --fail-closed || exit 2 ;;
esac
```

Two things make this shape the right one, and both are easy to get wrong.

*Why a shell guard at all.* The trailing `|| exit 2` makes a `node` that cannot
start (missing binary, bad `CLAUDE_PLUGIN_ROOT`) a **blocking** failure, which is
what `--fail-closed` promises. But the in-process profile check lives inside
`run-with-flags.js`, so it never runs when node cannot start — without a guard, a
broken node would hard-block `standard` and `minimal` sessions where this gate is
supposed to be inert.

*Why the guard lists the OFF profiles rather than matching `strict`.* The shell
must never be the thing that decides the hook is **on**, because shell pattern
matching cannot reproduce `hook-flags.js:19` (`String(...).trim().toLowerCase()`).
Successive review rounds found a fresh divergence each time one was patched:
`STRICT` fails a case-sensitive compare, `" strict "` fails an untrimmed compare,
and NBSP-padded `strict` survives JS `.trim()` but not shell `IFS` splitting. All
three normalize to `strict` in JS, so each would have silently skipped GateGuard
while `getHookProfile()` kept every *other* strict hook enabled.

Listing only the unambiguous off-values inverts the risk. `standard` and `minimal`
(case-insensitively, plus unset — which defaults to `standard`) skip cheaply and
never launch node. Everything else falls through to node and `isHookEnabled()`
makes the real decision — including values JS *rejects*, like `strict extra`,
which `getHookProfile()` maps back to `standard` so the hook is correctly skipped
in-process. A weird profile value costs one wasted node launch; it can never
silently disable the gate.

*Known residual.* A profile value that is genuinely non-strict but spelled oddly
enough to miss the skip list (`" minimal "`, say) will launch node, so if node
itself is broken the `|| exit 2` blocks that session. That needs two unlikely
conditions at once, and it fails **closed** and loudly, which is the direction
this repo prefers. Widening the skip list further would re-import the shell-vs-JS
normalization problem in the dangerous direction.

So: do not "tighten" this into a positive `strict` match, and do not delete the
`"strict"` argument to `run-with-flags.js` as redundant — that argument is the
only thing actually deciding whether the hook runs.

If GateGuard blocks setup or repair work, start the session with
`ECC_GATEGUARD=off` (or `GATEGUARD_DISABLED=1`). For hook-level control, add
either hook ID above to `ECC_DISABLED_HOOKS`.

**What the gate actually enforces — read this before trusting the three-stage
model above.** It denies the FIRST touch of each file (and each destructive
command), then allows the retry. `markChecked()` runs *before* the denial is
returned (`gateguard-fact-force.js:840-845`), so the state file records "this
target was gated once", **not** "the facts were presented". The hook has no way
to verify that you actually answered — a retry that presents nothing is allowed
just the same. Its value is forcing the investigation *pause* on first touch,
not proving the investigation happened.

Two further gaps, both in the hook rather than the registration — know them
before you rely on this as coverage:

- **Subagent edits are never gated.** `run()` returns `rawInput` the moment
  `isSubagentInvocation(data)` is true (`gateguard-fact-force.js:836-838`,
  `:851-853`), with no `isChecked()` consultation. The inline comment says the
  parent session already passed the file gate, but nothing checks that — a file
  first touched *inside* a subagent bypasses the gate entirely.
- **A `Write` payload over 1 MiB is not gated.** `run-with-flags.js` caps stdin
  at `MAX_STDIN = 1024 * 1024`; past that the JSON arrives truncated, GateGuard
  hits its parse-error path and returns the input unchanged, and the runner
  suppresses the truncated output and exits 0 — even under `--fail-closed`.

### Option B: Full package with config

```bash
pip install gateguard-ai
gateguard init
```

This adds `.gateguard.yml` for per-project configuration (custom messages, ignore paths, gate toggles).

## Anti-Patterns

- **Don't use self-evaluation instead.** "Are you sure?" always gets "yes." This is experimentally verified.
- **Don't skip the data schema check.** Both A/B test agents assumed ISO-8601 dates when real data used `%Y/%m/%d %H:%M`. Checking data structure (with redacted values) prevents this entire class of bugs.
- **Don't gate every single Bash command.** Routine bash gates once per session. Destructive bash gates every time. This balance avoids slowdown while catching real risks.

## Best Practices

- Let the gate fire naturally. Don't try to pre-answer the gate questions — the investigation itself is what improves quality.
- Customize gate messages for your domain. If your project has specific conventions, add them to the gate prompts.
- Use `.gateguard.yml` to ignore paths like `.venv/`, `node_modules/`, `.git/`.

## Related Skills

- `safety-guard` — Runtime safety checks (complementary, not overlapping)
- `code-reviewer` — Post-edit review (GateGuard is pre-edit investigation)
