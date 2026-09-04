---
name: council
description: >-
  Convene a 5-voice AI council (Architect, Skeptic, Pragmatist, Critic,
  Researcher) for ambiguous decisions needing multiple lenses — design,
  tradeoffs, architecture, strategy. Triggers include council, roundtable,
  perspectives, group wisdom, ideas/feedback/advice; "ultra-council" adds the
  UltraOracle (ChatGPT Pro) expert witness; "ultimate-council" adds three expert
  witnesses — the UltraOracle, the Mythos Witness (Claude Fable, subagent), and
  the Mechanism Witness (claim-vs-mechanism) — each rendered
  separately, never a vote. Not for simple tasks with clear answers.
origin: custom
---

# Council

Convene five advisors — the in-context Claude plus four fresh agents — for diverse perspectives. Each gives an independent perspective, then synthesize into a compressed verdict. (An **ultra-council** run adds an optional UltraOracle expert witness — see Step 4.5 — rendered as its own section, never counted among the five voices. An **ultimate-council** run adds THREE expert witnesses — the UltraOracle, a **Mythos Witness** (Claude Fable, dispatched as an in-harness subagent; see Step 4.6), and a **Mechanism Witness** (claim-vs-mechanism; see Step 4.7) — each rendered as its own section, none counted among the five voices.)

## Roles (Fixed)

| Voice | Method | Role | Lens | Configurable |
|---|---|---|---|---|
| Claude (you) | In-context | Architect | Correctness, maintainability, long-term implications | No (in-context) |
| Fresh Claude | Agent tool (clean memory) | Skeptic | Challenge assumptions, question premises, propose simplest alternative | No (Agent tool) |
| Configurable | dispatch-cli | Pragmatist | Shipping speed, simplicity, user impact, practical tradeoffs | Yes: `council.pragmatist` (default: agy) |
| Configurable | dispatch-cli | Critic | Edge cases, risks, failure modes, what could go wrong | Yes: `council.critic` (default: codex) |
| Configurable | dispatch-cli | Researcher | Evidence, prior art, current state, factual grounding | Yes: `council.researcher` (default: grok, fallback: droid) |

(UltraOracle is **not** in this table — it is an optional expert witness, not a sixth fixed role. See Step 4.5. The **Mechanism Witness** below is likewise not a fixed role — it is an ultimate-council expert witness, see Step 4.7.)

**Mechanism Witness (expert witness, ultimate-council only, never counted among the five voices).** Route `council.auditor`, default `opencode`; the MODEL comes from `.auditor.model` in the USER `~/.claude/busdriver.json` — an explicit `--model` value wins, and **there is no built-in default: with neither set the witness is skipped, not dispatched** (`opencode models` lists valid ids; USER config only and no env override, since the value picks which third party the prompt is shipped to). A shipped default could only ever name a provider an unconfigured operator holds no credential for, so it failed at dispatch instead of being honestly absent; the skip is classified `skipped`, so it never fails a batch for the other voices. Lens: *claim-vs-mechanism* — does the artifact actually do what it says it does. Rendered as its own section like the UltraOracle and the Mythos Witness, never folded into the five-voice synthesis and never a vote. **It runs ONLY in an ultimate-council** (gated on the same `MYTHOS_ATTEMPT` signal as the fable Mythos Witness — see Step 4.6/4.7); a plain or ultra-council does NOT dispatch it. (It was previously an always-on advisory in every council under the name "Auditor"; the witness runs a slow reasoning model that timed out silently at the old 120s budget, so it moved to the already-slow ultimate tier where it gets a full 900s — UltraOracle-parity, matching the oracle's own default cap — see ADR 0027.)

Two deliberate properties:

- **Not a fixed role**, because the five-voice composition is load-bearing across ADRs 0006/0011/0012/0013/0019, the ultra/ultimate council skills, and the README. Adding a sixth chair would require rewriting immutable decision records to stay honest. An expert witness — like the UltraOracle and Mythos Witness — keeps the count true.
- **No droid fallback.** Every other role falls back to droid for availability; this one does not. Droid already backstops three slots, so a droid Mechanism Witness would be a fourth copy of the same model wearing a new label — worse than an absent voice, because it reads as independent corroboration while adding no independent signal. If opencode is missing, the witness is absent and the report says so.

**Known limitation — treat Mechanism Witness findings as leads, not verdicts.** Measured against three already-passed PRs (2026-07-20): one verified true positive that Codex xhigh and the Opus backstop both missed, one confidently-asserted false positive, one correct `NOTHING FOUND`. Its confidence labels were *inverted* on that sample — it marked the hallucination MEDIUM and the real defect LOW. Verify before acting on anything it reports.

**CLI routing:** Pragmatist, Critic, and Researcher CLIs (plus the Mechanism Witness, ultimate-council only) are resolved from `.claude/busdriver.json` via `resolve_role_cli()`. Each role accepts a route array — the resolver walks it left-to-right and returns the first available CLI (e.g., `"council.pragmatist": ["agy", "droid"]` falls back to Droid if Agy is missing). If every CLI in the chain is missing, that voice is skipped and noted in the report; other voices still fire. Changing the CLI only changes which binary receives the prompt — the role framing (Pragmatist lens, Critic lens, Researcher lens) is always the same. **Trade-off to know:** fallback preserves availability but dilutes role identity — Droid filling in as Pragmatist is no longer "Agy's strategic lens." Accept this when resilience matters more than signal purity. See README for per-role routing docs.

**Runtime retry + droid fallback (distinct from the route-array fallback above):** the route array picks a CLI by *availability* at resolve time. At *runtime*, each dispatched fixed voice (Agy/Codex/Grok) also retries up to `BUSDRIVER_CLI_RETRIES` (default `3`) on a transient failure (rate-limit, network, 5xx) or empty output — a single flake no longer drops the voice. A timeout is never retried (re-running the full window is too costly). Only after retries are exhausted does the per-voice runtime droid fallback fire; voices fall back independently (distinct role prompts → distinct perspectives, so no cross-voice cap). Set `BUSDRIVER_CLI_RETRIES=0` to disable retries. **The Mechanism Witness is exempt from the droid fallback** for the reason given in its own section — a droid Mechanism Witness is a fourth copy of an existing model masquerading as an independent lens; retries still apply, but on exhaustion the witness is simply absent.

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

### Step 4: Dispatch Fresh Claude + Agy + Codex + Grok (+ Mechanism Witness in ultimate-council)

Launch all four external agents in parallel. Use a **single message with multiple tool calls** to maximize concurrency. In an **ultimate-council only**, the Mechanism Witness joins this same dispatch block — see Step 4.7; a plain or ultra-council omits it.

**4a. Fresh Claude (Skeptic)** — via Agent tool (starts with clean memory):

```text
Agent(
  description="Council Skeptic",
  prompt="You are the Skeptic on a council of five AI advisors. [QUESTION + CONTEXT]. Your role is Skeptic — you have NO prior context about this conversation. Focus on: challenging assumptions, questioning whether the problem is framed correctly, and proposing the simplest possible alternative. If the question itself is wrong or the answer is simpler than expected, say so. Give your perspective as: 1. Position (1-2 sentences) 2. Reasoning (3 points) 3. Risk 4. Surprise. Under 300 words. Be opinionated, no hedging.",
  model="opus"  # Uses the "opus" alias — valid Agent tool enum value for highest-reasoning model
)
```

**4b. Pre-check CLI availability, then dispatch:**

**First, make a private prompt directory** with a single Bash call. It prints two things, and they go to different places: the FIRST `suffix=` line is six alphanumeric characters and is the ONLY thing that goes into the dispatch block; `dir=` is the absolute path, and goes only to the `Write` tool:

```bash
_d="$(mkdir -p "$HOME/.claude" && mktemp -d "$HOME/.claude/council.XXXXXX")" || exit 1
_s="${_d##*/council.}"
[[ "$_s" =~ ^[A-Za-z0-9]{6}$ ]] || { echo "council: refusing a malformed suffix" >&2; exit 1; }
printf 'suffix=%s\n' "$_s"
printf 'dir=%s\n' "$_d"
```

`mktemp -d` is doing real work here, and a hand-picked directory name is not a substitute. It creates the directory **atomically** and fails rather than reusing one that already exists, and it creates it mode 0700 — so two councils running at once cannot land in the same directory, and a stale directory from an interrupted run cannot be silently reused. A fixed or hand-rolled name gives none of that: whichever run loses the race has its prompts overwritten between the write and the read, and a council prompt routinely carries repo and design context, so the loser would ship its material to the other session's external voice.

**Only the suffix crosses over — never the path.** Whatever you carry from this step is retyped into the dispatch block, where it becomes shell source and is parsed. A full path is therefore an execution point: it contains the parent directory, and every candidate parent is ambient. `$TMPDIR` is settable by a committed `.claude/settings.json` `env` block (#325 / ADR 0016 class) and `$HOME` is settable too, so a value carrying `$(…)`, a backtick, a quote or a backslash is inert inside the quoted `mktemp` call and then executes when the printed path is pasted. Stripping the name down to `mktemp`'s own suffix leaves six characters of `[A-Za-z0-9]` — the `XXXXXX` template's width — and the regex pins exactly that rather than trusting it — a `$HOME` carrying a newline could otherwise emit a second, forged `suffix=` line, so the genuine one is printed FIRST and the check runs before either line. Written as a command substitution and a parameter expansion rather than a pipe into `sed`, because a pipeline reports the LAST stage's status: a failed `mktemp` — collision retries exhausted, `~/.claude` unwritable, disk full — would print nothing and still exit 0, and the contract here is that this step either hands you a suffix or fails visibly. Take the FIRST `suffix=` line; if nothing is printed, stop, and do not invent a suffix. The block rebuilds the path from that suffix and its own quoted `"$HOME"`, exactly as it already does for the plugin cache — so this step introduces no expansion the fence was not already performing. The absolute `dir=` line is printed for the `Write` calls, which take a filesystem path rather than shell source and so carry none of this hazard; do not paste it into the block.

**What this step does NOT claim.** It removes the execution point that carrying a PATH would have introduced. It does not make the fence safe against an environment that is already hostile, and it would be theater to pretend otherwise: `PLUGIN_ROOT` is derived from `$HOME` eleven lines below and the block then `source`s a file from it and executes `dispatch.sh` from it, so an injected `HOME` owns this shell regardless of where the prompts live; and an injected `PATH` that could substitute `mkdir` or `mktemp` substitutes `ls`, `awk`, `sed`, `pgrep`, `kill`, `rmdir` and `bash` in the same fence, plus `dispatch.sh` itself. Hardening two commands out of a dozen would move nothing. Those are whole-plugin preconditions and belong wherever the plugin decides to address them, not in this hunk.

**Then write each voice's prompt to a file with the `Write` tool**, one file per voice, inside that directory. Use the absolute `dir=` path verbatim — `Write` takes a filesystem path and expands neither `~` nor `$HOME`, so the `~/…` spelling below is shorthand for reading, not a path to pass:

| Voice | File |
|---|---|
| Pragmatist | `~/.claude/council.<SUFFIX>/pragmatist.txt` |
| Critic | `~/.claude/council.<SUFFIX>/critic.txt` |
| Researcher | `~/.claude/council.<SUFFIX>/researcher.txt` |
| Mechanism Witness (ultimate-council only) | `~/.claude/council.<SUFFIX>/witness.txt` |
| UltraOracle (ultra-/ultimate-council only) | `~/.claude/council.<SUFFIX>/oracle.txt` |

Write only the files whose voice will actually be dispatched, and write them **before** the dispatch message — the dispatch block reads them, so they must already exist. Prompt CONTENT is unchanged; only its transport is. **Do not inline the prompts back into the block as heredocs** — that is what #813 fixed, and the reason is in (i) below.

Substitute the `suffix=` value — not the path — into the `D=` line of the dispatch block. If the two do not match, the block stops with an error rather than convening a council with no voices. A prompt file that is individually missing is **not** guarded for, deliberately: the redirection then fails loudly for that voice, which is what you want to see. Guarding it would make a forgotten `Write` indistinguishable from an unavailable CLI, and the report would show the voice as `(unavailable)` rather than as the mistake it is.

Then dispatch. This block checks CLI availability and finds the dispatch script:

```bash
# Prompts come from FILES written before this call, never inline heredocs — see (d) and (i).
# The SUFFIX from Step 4b, nothing more — see there. The trap is the cleanup — see (j).
D="$HOME/.claude/council.<SUFFIX>"
[ -d "$D" ] || { echo "council: prompt dir $D missing — write the prompt files first (Step 4b)" >&2; exit 1; }
trap 'rm -f "$D/pragmatist.txt" "$D/critic.txt" "$D/researcher.txt" "$D/witness.txt" "$D/oracle.txt"; rmdir "$D" 2>/dev/null || true' EXIT

# Resolve the plugin root ONCE — see "Why the block is written this way" (a) below.
PLUGIN_ROOT="${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"
if [ -z "$PLUGIN_ROOT" ]; then
  # newest installed STABLE cache version — see (b) below.
  _cache="$HOME/.claude/plugins/cache/busdriver/busdriver"
  _v="$(ls "$_cache" 2>/dev/null | awk -F. '/^[0-9]+[.][0-9]+[.][0-9]+$/ { if (!n || $1>a || ($1==a && ($2>b || ($2==b && $3>c)))) { a=$1; b=$2; c=$3; n=1; v=$0 } } END { if (n) print v }')"
  [ -n "$_v" ] && PLUGIN_ROOT="$_cache/$_v"
fi
PLUGIN_ROOT="${PLUGIN_ROOT%/}"
[ -n "$PLUGIN_ROOT" ] && [ -d "$PLUGIN_ROOT" ] || { echo "council: cannot resolve busdriver plugin root — set BUSDRIVER_PLUGIN_ROOT" >&2; exit 1; }

# Source shared CLI library and resolve roles from config
source "${PLUGIN_ROOT}/scripts/lib/resolve-cli.sh"
PRAGMATIST_CLI=$(resolve_role_cli "council.pragmatist")
CRITIC_CLI=$(resolve_role_cli "council.critic")
RESEARCHER_CLI=$(resolve_role_cli "council.researcher")
AUDITOR_CLI=$(resolve_role_cli "council.auditor")
DISPATCH="${PLUGIN_ROOT}/skills/dispatch-cli/scripts/dispatch.sh"

# Mechanism Witness authorization (ultimate-council ONLY). This LITERAL 0 shadows any
# repo-injected ambient MECHANISM_WITNESS; flip it to 1 ONLY for an ultimate-council
# whose Step 4.6 gate printed MYTHOS_ATTEMPT=1. See (c) below.
MECHANISM_WITNESS=0

# Dispatch available voices — capture PIDs so wait blocks on the actual processes.
PIDS=()
if [[ "$PRAGMATIST_CLI" != "none" && "$PRAGMATIST_CLI" != "builtin" && ! "$PRAGMATIST_CLI" =~ ^(missing|unsupported): ]]; then
  # DROID_AUTO_LEVEL=low: file-write tier only if this voice falls back to droid — see (e).
  DROID_AUTO_LEVEL=low "$DISPATCH" --cli "$PRAGMATIST_CLI" --timeout 300 < "$D/pragmatist.txt" &
  PIDS+=("$!")
fi
if [[ "$CRITIC_CLI" != "none" && "$CRITIC_CLI" != "builtin" && ! "$CRITIC_CLI" =~ ^(missing|unsupported): ]]; then
  # DROID_AUTO_LEVEL=low: same reasoning as Pragmatist — see (e).
  DROID_AUTO_LEVEL=low "$DISPATCH" --cli "$CRITIC_CLI" --timeout 300 < "$D/critic.txt" &
  PIDS+=("$!")
fi
if [[ "$RESEARCHER_CLI" != "none" && "$RESEARCHER_CLI" != "builtin" && ! "$RESEARCHER_CLI" =~ ^(missing|unsupported): ]]; then
  "$DISPATCH" --cli "$RESEARCHER_CLI" --timeout 300 < "$D/researcher.txt" &
  PIDS+=("$!")
fi
AUDITOR_PID=""
# Mechanism Witness — ULTIMATE-COUNCIL ONLY, gated on the LITERAL MECHANISM_WITNESS
# above (never an inherited env value). See (c) and (f) below.
if [ "${MECHANISM_WITNESS:-0}" = 1 ] && [[ "$AUDITOR_CLI" != "none" && "$AUDITOR_CLI" != "builtin" && ! "$AUDITOR_CLI" =~ ^(missing|unsupported): ]]; then
  # Budget: default AND hard clamp 900s (UltraOracle-parity). One regex, no glob — see (g).
  _AUD_TO=900
  [[ "${COUNCIL_AUDITOR_TIMEOUT:-}" =~ ^0*[0-9]{1,7}$ ]] && _AUD_TO=$((10#$COUNCIL_AUDITOR_TIMEOUT))
  [[ "$_AUD_TO" -lt 1 || "$_AUD_TO" -gt 900 ]] && _AUD_TO=900   # clamp — see (g)
  "$DISPATCH" --cli "$AUDITOR_CLI" --timeout "$_AUD_TO" < "$D/witness.txt" &
  AUDITOR_PID="$!"
fi
# Block on the FIXED voices only; the Mechanism Witness is reaped separately on its
# OWN budget (_AUD_TO + 10s). Override with COUNCIL_AUDITOR_GRACE. See (h).
(( ${#PIDS[@]} )) && wait "${PIDS[@]}"
if [[ -n "$AUDITOR_PID" ]]; then
  # Same regex form as _AUD_TO, for the same two reasons — see (g).
  _ag_cap=$(( _AUD_TO + 10 ))
  [[ "${COUNCIL_AUDITOR_GRACE:-}" =~ ^0*[0-9]{1,7}$ ]] && _ag_cap=$((10#$COUNCIL_AUDITOR_GRACE))
  # The override may only SHORTEN the reap, never extend past budget+10.
  [[ "$_ag_cap" -gt $(( _AUD_TO + 10 )) ]] && _ag_cap=$(( _AUD_TO + 10 )); [[ "$_ag_cap" -lt 1 ]] && _ag_cap=1
  _ag=0
  while kill -0 "$AUDITOR_PID" 2>/dev/null; do
    if [[ "$_ag" -ge "$_ag_cap" ]]; then
      _kt() { local p="$1" c; for c in $(pgrep -P "$p" 2>/dev/null); do _kt "$c"; done; kill "$p" 2>/dev/null || true; }
      _kt "$AUDITOR_PID"
      break
    fi
    sleep 1; _ag=$((_ag + 1))
  done
  wait "$AUDITOR_PID" 2>/dev/null || true
fi
```

**Why the block is written this way.** This rationale lives out here, in prose, rather than as comments inside the fence — and it must stay out here. The fence is pasted **verbatim** into a Bash tool call, where `hooks/gate-scripts/lib/marker_check.py` scans the command string against a **4000-token budget** for the gate-state-helper walk, and comment text is charged to that budget exactly like code. When the rationale sat inline the block measured **12 tokens over**, and an over-budget command is refused `BLOCKED: too large or too deeply nested` — fail-CLOSED, correctly, but on the plugin's own documented workflow (#813). Keep in-fence comments to one line each; put the reasoning here.

- **(a) `PLUGIN_ROOT` resolved ONCE.** `CLAUDE_PLUGIN_ROOT` is NOT populated in the Bash tool env of every harness (empty in SDK/child sessions), and a bare `"${CLAUDE_PLUGIN_ROOT}/..."` would collapse to `/scripts/...` — every voice and witness would silently fail to launch. Falls back to the newest installed cache dir; override with `BUSDRIVER_PLUGIN_ROOT`. This `PLUGIN_ROOT` is in scope for the Step 4.5 UltraOracle snippet, which is inserted into THIS same block and shares this shell (alongside `PIDS`). Step 4.6 (Mythos Witness) runs as standalone Bash calls and re-resolves `PLUGIN_ROOT` independently.
- **(b) Version pick.** One `awk` stage does the whole job: it keeps only pure `X.Y.Z` names and tracks the maximum by comparing major, then minor, then patch numerically. The name filter matters because prereleases like `2.0.0-beta.1` compare equal to `2.0.0` on the numeric keys and would win a tie-break. It replaced a `grep | sort | tail` pipeline whose only defect was cost: a 4-stage pipeline spent ~1000 of the classifier's 4000-token budget on its own (see (i)), and this is 2 stages. Output verified identical to that pipeline under bash and zsh, on synthetic input and on the real plugin cache. Deliberately NOT `sort -V` (GNU-only; stock macOS BSD sort lacks it) and NOT mtime / `ls -t` (a reinstalled older version can carry a newer mtime).
- **(c) `MECHANISM_WITNESS` is a LITERAL, not an inherited value.** A committed `.claude/settings.json` `env` block can set env vars (#325 / ADR 0016 class), so the dispatch guard must not trust an ambient `MECHANISM_WITNESS` — otherwise a plain council could be forced to transmit its prompt to the configured `.auditor.model`. Claude flips the literal to `1` **iff** the Step 4.6 gate printed `MYTHOS_ATTEMPT=1` (Step 4.7, same authorization as the fable Mythos Witness); a plain or ultra-council leaves it `0`. Fail-SAFE: the literal default is `0`. Same injection-proofing as the Step 4.6 `_forced` literal default.
- **(d) Prompt FILES, not `--prompt "..."` and not heredocs.** `--prompt` loses to shell escaping bugs with quotes, backticks, `$`, and newlines; a file has neither that problem nor the one in (i). `dispatch.sh` reads the prompt from stdin either way, so `< file` is a drop-in for the old `<<'DELIM'`.
- **(e) `DROID_AUTO_LEVEL=low`.** If Pragmatist or Critic falls back to droid (per the route array's droid fallback), the agent is constrained to file-write tier — these are synthesis roles needing no installs, network fetches, or git ops. No effect when the CLI is agy (the env var is ignored by non-droid CLIs). If droid fails at low tier the voice drops cleanly rather than running at the default `high` privilege.
- **(f) The witness runs read-only** via the plugin-owned opencode config (deny-all tools except read/glob/grep) — see the `opencode)` arm in `resolve-cli.sh` for the four-round probe history; enumerated denylists all leaked. Its PID is kept OUT of the blocking `PIDS` array, and it runs CONCURRENTLY with the oracle (both start at t=0), so the block still finishes inside the oracle's own budget+90s window — no serial addition.
- **(g) Budget normalizers are ONE regex each, deliberately glob-free.** Semantics are the old chain's exactly: non-numeric / empty / >7-significant-digit → the default, leading zeros dropped, `10#` so a `0`-prefixed value is never read as octal. What changed is the shape. The old form used `case "$x" in ''|*[!0-9]*)`, and a negated character class fnmatches a guarded gate-state helper's filename while spelling none of it — so the whole block was refused for "calling" a script it never names. That fired because a **function definition anywhere in the command** (the `_kt` reap helper below, and until #813 also the bare `PIDS=()` array literal, which the detector misread as a definition) makes the classifier drop its structured walk WHOLESALE and re-read every word of the command — comment prose included — as a bare glob pattern. Glob and function definition are each harmless alone; together they block. Two consequences for anyone editing this fence: **do not reintroduce a glob**, and **do not spell a guarded helper's filename even in a comment** — the literal-name probe reads a comment exactly like a command. Pinned in `tests/test-marker-glob-specificity.sh` section F. The 900s clamp is HARD (not the oracle's 3600 ceiling) because `COUNCIL_AUDITOR_TIMEOUT` is repo-injectable (#325) and a higher ceiling would let a fork stall an ultimate-council past the Bash-tool timeout; the witness is advisory and 900s is ample (ADR 0027 — the old 120s silently timed out). **And no capture group, deliberately:** this block is pasted into the executor's Bash tool, which on a zsh-default machine (macOS) runs **zsh** — and zsh populates `$match`, not `$BASH_REMATCH`, so a capture-group form evaluates to `$((10#))` and silently pins the value at the default, killing the operator override on the very shell the rest of this file warns about (see the Step 4.5 `source` note). `10#` already eats the leading zeros the capture group was there to strip and the `{1,7}` bound already rules out an overflow, so validating the variable and then reading it directly is both shorter and shell-agnostic. Verified identical under bash and zsh across ten boundary inputs, and pinned by the zsh rows in `tests/test-auditor-grace-budget.sh`.
- **(h) The reap waits for the witness's OWN budget** (`_AUD_TO + 10s`), not a stingy tail after the fixed voices: it is a slow reasoning model and a 20s tail reaped it mid-flight. `dispatch`'s own `--timeout` hard-stops the process at `_AUD_TO`, so this loop only POLLS to that ceiling and cannot stall the council unboundedly; the `+10` is slack to finish writing (`execute_review` and opencode are descendants, so killing only `$AUDITOR_PID` orphans them — hence the recursive `_kt`).

- **(i) The prompts live in FILES because the block is scanned, and the scan is not free.** Measured on the shipped block (#813): with the prompts inline as heredocs, **~100 words per voice was already over budget** — the walk cost scales with the pasted prompt, so no amount of comment-trimming fixes it and every longer council question re-breaks the block. Worse, the classifier reads a heredoc payload aimed at `"$DISPATCH"` (an unresolved command word) as a possible *program*, so a council **question** containing an ordinary glob-shaped token — `*.py`, `test_*`, `foo?` — was itself enough to get the command refused as "calling" a gate helper. That is the shape that makes a council *about* the gates nearly impossible to convene, since its question quotes the gates' own command strings. With the prompts in files the block's cost is **constant** — it no longer moves with the length of the council question at all — and the measured margin is 30-plus comment lines of the kind that used to sit in the fence, pinned by a headroom row in `tests/test-marker-glob-specificity.sh`. Do not inline them again.

- **(j) Cleanup runs from a `trap`, not from the last line.** The question text can carry sensitive repo and design context, so the prompt files and their directory must not outlive the run — and a tail cleanup only runs on normal fallthrough. The `exit 1` above it, a failed `source`, an interrupt, or a Bash-tool timeout all skip it, and because each run now gets its own `mktemp -d` directory, nothing later overwrites or reuses those files: they would sit there indefinitely. An `EXIT` trap fires on every one of those paths. `oracle.txt` is on the list even though the Step 4.5 snippet removes it too, because that snippet is absent from a plain council — relying on it alone would make whether the directory can be removed depend on which council tier ran. `rm -f` on an absent file is a no-op, so listing it costs nothing. Named explicitly rather than `"$D"/*` for the reason in (g) — no globs in this fence. **Residual, stated rather than claimed away:** the trap covers the dispatch call, which is where the run actually spends its time, but not the gap between the `Write` turn and that call. A session cancelled in that window, or one whose dispatch never launches, leaves one `~/.claude/council.XXXXXX` directory behind. It is mode 0700 under the operator's own home rather than in a shared temp directory, and it is inert — nothing reads it again, since the next run mints its own — so the cost is a stale directory to delete, not an exposure. Closing it properly would need a writer that owns the whole lifecycle, which is a bigger change than this fix.

> **Note.** `_kt` (h) is a genuine function definition, which still makes the classifier re-read *this block's own words* as glob patterns. That is why (g)'s "no globs in the fence" rule applies to the skeleton and its comments — it is not belt-and-braces, it is the live constraint.

This is a **single Bash call** with all CLI dispatches as background processes. This is critical — if Agy, Codex, Grok (and opencode, in an ultimate-council) are separate parallel Bash tool calls, one failing cancels the others. A single call with `&` and `wait` keeps them independent.

**NEVER wrap dispatches in subshells `()`**. The pattern `( cmd & ) && wait` does NOT work — the subshell exits immediately after backgrounding, so `wait` has nothing to wait for. Always background directly and capture PIDs with `$!`.

**Prompt template** for Agy/Codex/Grok/opencode (same structure as Skeptic but with their role/lens) — this is the text that goes into each voice's prompt FILE (Step 4b table). When the resolver falls back to Droid in any slot, the same role/lens text is sent — these labels track the *default primary* CLI per role.

**For Agy:** Role = "Pragmatist", Lens = "shipping speed, simplicity, user impact, practical tradeoffs"
**For Codex:** Role = "Critic", Lens = "edge cases, risks, failure modes, what could go wrong"
**For opencode (Mechanism Witness, ultimate-council only):** Role = "Mechanism Witness", Lens = "claim-vs-mechanism. For each load-bearing claim the proposal makes about how something works — a comment, a doc line, a guarantee, a 'this is handled by X' — check whether the mechanism cited actually produces that behavior, and say so concretely. You are not looking for better designs or missing features; you are looking for places where the stated behavior and the actual behavior diverge. Cite file:line. If you find nothing real, say NOTHING FOUND rather than manufacturing a finding — a confident false positive costs more than a missed nit. Label each finding with your confidence and be willing to say you could not verify a claim from the material available."

> **Mechanism Witness is snippet-only — you MUST paste the code it audits.** opencode runs sandboxed in a neutral temp dir with `external_directory: deny` (so a reviewed repo can't redefine the reviewer), which means it **cannot read the repo** — its `read`/`glob`/`grep` see an empty dir. Handing it bare paths ("audit `hooks/gate-scripts/pre-merge-gate.sh`…") wastes the voice: it correctly returns `UNABLE TO VERIFY — repo material not present`. Paste the exact `file:line` snippets you want audited into the prompt, exactly like the UltraOracle. Do NOT reference bare paths, and do NOT try to grant repo access — that reopens the injection boundary the denylist exists to close.

**For Grok:** Role = "Researcher", Lens = "evidence, prior art, current state — look up similar past decisions, current code state of the repo, and external evidence relevant to the question. Provide links, quotes, and sources — NOT conclusions stated as settled fact. Your factual/empirical claims are treated as UNVERIFIED by default until checked against local evidence, so for each load-bearing claim name the cheap local check (command / file / grep) that would confirm or refute it. Cite what you find; flag claims that lack grounding."

**IMPORTANT:** The prompt-file `Write` calls come first, in their own turn. Then launch the Agent tool call AND the single Bash dispatch call (containing Agy + Codex + Grok as background processes — plus opencode only in an ultimate-council) in the **same message** so all external voices run concurrently. Do NOT use separate Bash tool calls for the dispatches — one failing will cancel the others. (The `Write` calls are cheap and non-blocking; only the dispatches need to share a call.)

**Missing CLI handling:** Each role's route array is walked left-to-right; the first available CLI wins. If every CLI in the chain resolves to `none`, `builtin`, `missing:<cli>`, or `unsupported:<cli>` (the last fires when a stale config references a removed backend like amp/claude/aider — migration warning goes to stderr), that voice is skipped and the report notes its absence as `(unavailable)`. The remaining voices still convene. If the Skeptic Agent call fails (rate limit, timeout), same rule applies. Typical minimum is 2 voices (Architect + Skeptic, 40% of full strength); absolute floor is 1 voice (Architect alone) if the Skeptic Agent call also fails. Always note the composition in the report — and when a fallback fires (e.g., Droid serving as Pragmatist because Agy was missing), note that explicitly so the report doesn't misattribute the lens.

### Step 4.5: Optional UltraOracle Expert Witness ("ultra-council", off by default)

An UltraOracle (ChatGPT Pro) **expert witness** can be escalated ONLY when `ultraOracle.council.enabled` is true in the operator's **USER config** `~/.claude/busdriver.json` (a repo-controlled project config CANNOT enable it — security), OR the user explicitly invokes **"ultra-council" / "ultra council"** (or asks to include the oracle). To force it for that run, add `ULTRA_ORACLE_COUNCIL_FORCE=1` as a **plain, non-exported** assignment at the very top of the single Step 4 dispatch Bash block, and `unset ULTRA_ORACLE_COUNCIL_FORCE` as its last line (the launch wiring below already reads the var). Do NOT `export` it (it would persist into a later council in a persistent shell), do NOT use a one-command `VAR=1 cmd` prefix (it would not reach the gate), and do NOT wrap the dispatch in a subshell (the no-subshell rule in Step 4 — it would strand `PIDS`). A **normal council omits that line entirely**; the gate's `:-0` default then leaves the oracle off unless user-config enabled it. It is dispatched via the shared `ultra_oracle_consult` adapter (the `oracle` CLI's ChatGPT Pro browser engine), inside that SAME single-Bash dispatch block as the other voices (separate Bash calls serialize/cancel — see Step 4).

UltraOracle is **not** a vote: it is rendered as its own Expert Witness section (Step 5/Step 6) and is EXCLUDED from the council vote tally — consensus, strongest dissent, and the recommendation are computed from the five voices only (ADR 0007 settling-check #1). The consult attaches no evidence-pack files (it sends only the prompt text — a Claude-authored question + context), so its result is labeled `ORACLE_SUMMARY_REVIEW` per the ADR review-type table (a Claude-authored summary, not a repo-attached review) even if that prompt text quotes snippets; a repo-specific claim with no file/path evidence is ungrounded — say so.

**Trade-off (why it's off by default):** a single slow Pro consult makes every council it joins run minutes instead of seconds, and as an expert witness it carries weight only when its claims are evidence-backed. Never add it to the default roster.

**Data boundary:** ultra-oracle transmits the council question to ChatGPT Pro via the oracle browser engine. When Chrome blocks programmatic cookie decryption (recent cookie-encryption hardening — App-Bound Encryption on Windows, Keychain-bound on macOS; observed on macOS Chrome 149, #340), `cookiePath` and `chromeProfileDir` both fail — set `ultraOracle.remoteHost` + `ultraOracle.remoteToken` to delegate to a persistent `oracle serve --manual-login --host 127.0.0.1 --token <T>` you sign into once (`remoteToken` is a secret; pin `127.0.0.1`). Otherwise use `ultraOracle.cookiePath` (a signed-in Cookies DB) or `ultraOracle.chromeProfileDir` (a dedicated ChatGPT-only profile clone). All USER-config only. Do not enable where the question would carry secrets. See `blueprint-review/SKILL.md` for the full precedence + issue #340.

Launch wiring (inside the Step 4 dispatch Bash block, alongside the voices). The oracle runs via the **bash-shebang wrapper `scripts/ultra-oracle-run.sh`**, NOT an in-block `source`. This is load-bearing: `scripts/lib/ultra-oracle.sh` is bash-only (resolves its own dir via `${BASH_SOURCE[0]}`, uses `local -a`) and fail-closes when sourced outside bash — and this Step 4 block is pasted verbatim into the executor's Bash tool, which on a zsh-default machine (macOS) runs **zsh**. An in-block `source` therefore aborted with rc=1 and every ultra-council run silently rendered `ORACLE_FAILED [adapter-unavailable]` (the oracle never launched; the voices were immune only because `dispatch.sh` carries its own bash shebang). The wrapper gives the oracle the same shell-agnostic immunity. It self-gates (surface-enabled OR forced), blocks internally until the consult completes, and prints one typed token — track it in `PIDS` like every other voice and read its result after `wait`. A normal council omits `ULTRA_ORACLE_COUNCIL_FORCE` entirely; the wrapper then prints `NOT_ATTEMPTED` unless user config enabled the surface.

> **⚠ Bash-tool timeout (caller contract — #477 Cause 1).** The wrapper **blocks internally for the full ChatGPT-Pro browser consult** and then polls up to the **oracle budget + 90s** for the completion marker (`ultra-oracle-run.sh` waits `timeout_cap + 90`). Because Step 4's closing `wait "${PIDS[@]}"` blocks on it, the **entire Step 4 dispatch Bash tool call must be invoked with an explicit `timeout` ≥ `ultra_oracle_timeout_cap + 90s + LAUNCH_WAIT_SECONDS`**, rounded up for headroom. Size it from that **formula, not a fixed number**: `ultra_oracle_timeout_cap` reads USER config and only *falls back* to **900s** (`scripts/lib/ultra-oracle-config.sh`) — 3600s is the configurable **ceiling**, not the default — and `scripts/lib/ultra-oracle-attach-preflight.sh` runs its `LAUNCH_WAIT_SECONDS` (15s) synchronously *before* the poll starts. So at the default cap that is ≥1005s (`timeout: 1100000` ms), and at the 3600s ceiling ≥3705s (`timeout: 3710000` ms). Pinning the number to the budget alone under-sizes the contract for any raised cap and re-creates #477 Cause 1. A bare `≥ budget` is not enough — the wrapper's 90s grace can outlast it. The default ~120s Bash-tool ceiling would SIGTERM the whole process group mid-consult, before the wrapper writes a verdict → a spurious `ORACLE_FAILED [no wrapper output]`. This is the ONE extra thing an ultra-council needs over a plain council; a plain council's voices finish well inside the default.

```bash
# The prompt file is written with the Write tool BEFORE this call, like every other
# voice's (see the Step 4b table) — same text, never an inline heredoc (#813, see (i)).
ULTRA_ORACLE_RESULT="$(mktemp)"; ULTRA_ORACLE_PROMPT_FILE="$D/oracle.txt"
# Background the wrapper so its consult overlaps the voices; it blocks internally
# until done, so `wait "${PIDS[@]}"` covers it. ULTRA_ORACLE_COUNCIL_FORCE is the
# plain (non-exported) per-run escalation; pass it as arg 2 (a normal council
# leaves it unset → 0). arg 4 is where the verdict markdown + .rc marker land.
# The `{ ...; rm -f ...; }` group deletes the prompt file once the wrapper exits
# (VERDICT, FAILED, or NOT_ATTEMPTED alike) so the council question text — which
# may carry sensitive repo/design context — never lingers on disk after an
# off-by-default (NOT_ATTEMPTED) run; the wrapper has already fully read the file
# by the time it exits, so this is not a race.
{ bash "${PLUGIN_ROOT}/scripts/ultra-oracle-run.sh" council "${ULTRA_ORACLE_COUNCIL_FORCE:-0}" \
    "$ULTRA_ORACLE_PROMPT_FILE" "${BUSDRIVER_STATE_DIR:-.claude}/ultra-oracle/council-$$.md" \
    > "$ULTRA_ORACLE_RESULT" 2>/dev/null; rm -f "$ULTRA_ORACLE_PROMPT_FILE"; } &
PIDS+=("$!")
# CRITICAL — insert this ENTIRE snippet into the Step 4 dispatch block BEFORE its
# closing `(( ${#PIDS[@]} )) && wait "${PIDS[@]}"` line (the last line of the Step 4
# code fence above), not after it and not as a separate Bash call. Step 5's render
# reads $ULTRA_ORACLE_RESULT immediately with no polling loop of its own, so the
# combined `wait` is the ONLY thing guaranteeing the wrapper has finished — appending
# this dispatch after Step 4's `wait` already ran (or issuing it as its own Bash tool
# call) lets the render execute while the wrapper is still running, producing a false
# `ORACLE_FAILED [no wrapper output]`.
```

**Render (Step 5):** after `wait "${PIDS[@]}"`, in the same block. The wrapper already did the surface-gate + status grading + `.rc` wait, so the render just reads its first-line token: `VERDICT` (verdict text follows on subsequent lines), `NOT_ATTEMPTED` (oracle did not run — omit the section entirely), or `FAILED [<status>]` (render the loud banner).

```bash
_uo_tok="$(head -1 "$ULTRA_ORACLE_RESULT" 2>/dev/null)"
case "$_uo_tok" in
  VERDICT)         tail -n +2 "$ULTRA_ORACLE_RESULT" ;;         # verdict text → Expert Witness section
  FAILED*)         echo "ORACLE_${_uo_tok}" ;;                  # → "ORACLE_FAILED [status]" loud banner
  NOT_ATTEMPTED)   : ;;                                         # oracle did not run → omit the section
  *)               echo "ORACLE_FAILED [no wrapper output]" ;; # empty/unknown token: the wrapper prints exactly one
                                                               # of the three tokens and exits 0, so an empty result
                                                               # means it died before emitting — fail CLOSED to the
                                                               # loud banner, NEVER silently omit (ADR 0007 #6).
esac
```

**Rendering directive (binding):** In the Step 6 report, whenever the oracle was attempted, render a SEPARATE top-level `## UltraOracle — Expert Witness [ORACLE_SUMMARY_REVIEW]` section AFTER the five voice blocks and BEFORE `### Verdict`. On a verdict, place the `cat`'d text (reproduced faithfully — annotate any ungrounded repo-specific claim as ungrounded); it is advisory and EXCLUDED from the vote tally, and must NOT flip a hard recommendation without independent local evidence (grep/Read/run). On any `ORACLE_FAILED […]` token render a loud `## ⚠ ORACLE_FAILED [<status>] — UltraOracle Expert Witness verdict NOT included` banner in that slot — never silently omit it (ADR 0007 settling-check #6). Never place UltraOracle in a voice slot or count it toward consensus.

Council is not a blocking gate, so the loud banner (only when the oracle was attempted) is the strongest fail-closed behavior available.

### Step 4.6: Optional Mythos Witness — Claude Fable ("ultimate-council", off by default)

The **Mythos Witness** is the council's second expert witness — **Claude Fable**, dispatched as a
single in-harness subagent (the `ultimate` tier; see ADR 0011 as amended by ADR 0015 and ADR 0019):

- **Fable subagent (the only transport).** A fresh `Agent(model="fable")` in-harness subagent (pinned
  `claude-fable-5`), dispatched in the SAME Step 4 message as the 4a Skeptic and the 4b voices.
  In-account, no external transmission, no gateway creds, no metered billing.
- **No fallback.** The zenmux gateway rung was removed (ADR 0019). If the subagent errors, is
  unavailable (the harness rejects `model="fable"`), or returns empty, the witness renders a loud
  `MYTHOS_FAILED [status]` banner and the council converges on its five voices — the witness is
  auxiliary and never a vote, so it needs no second transport.

It is escalated ONLY when `ultimate.surfaces.council` is true in the operator's **USER config**
`~/.claude/busdriver.json` (a repo-controlled project config CANNOT enable it), OR the user explicitly
invokes **"ultimate-council" / "ultimate council"**. An ultimate-council runs BOTH witnesses — the
UltraOracle (Step 4.5) AND the Mythos Witness; "ultra-council" (Step 4.5) is UNCHANGED and runs the
UltraOracle only.

`BUSDRIVER_ULTIMATE=0` is the operator's global force-OFF and outranks both the config opt-in and the
per-run trigger. With the gateway helper gone (ADR 0019) there is no second, helper-side re-check: the
gate block below is the sole authorization point for the witness, and `MYTHOS_ATTEMPT` is its output.

The Mythos Witness is **not** a vote: it is rendered as its own `## Mythos Witness — Expert Witness`
section (Step 5/Step 6), placed AFTER the UltraOracle section and BEFORE the Verdict, and is EXCLUDED
from the council vote tally — consensus, strongest dissent, and the recommendation are computed from the
five voices only. Its claims are treated as **unverified-until-checked** like the Researcher's (grep/Read/run
before any hard recommendation rests on them). On failure it renders a loud `MYTHOS_FAILED [status]`
banner — NEVER a silent omission.

**Trade-off (why it's off by default):** the fable subagent is a full, slow model call, so an
ultimate-council runs minutes instead of seconds. As an expert witness it carries weight only when its
claims are evidence-backed. Never add it to the default roster.

**Data boundary:** the fable subagent runs **in-account** — no external transmission, no gateway creds,
no metered billing (ADR 0019 removed the gateway transport that was the only external crossing on this
surface). Note the UltraOracle (Step 4.5) is a *separate* `ultra*` surface and DOES transmit externally;
an ultimate-council runs both, so that boundary still applies to the oracle half of the run.

**Gate (run ONCE before composing the Step 4 dispatch message).** Sets `MYTHOS_ATTEMPT=1` when this run
is an ultimate-council. Set `_forced=1` when the user invoked "ultimate council" this run (Claude knows
the trigger directly); the config opt-in is read from USER config; `BUSDRIVER_ULTIMATE=0` outranks both.

```bash
# Standalone Bash call — shell state does NOT carry over from the Step 4 block, so resolve
# PLUGIN_ROOT here too (same chain as Step 4b's preamble; see there for the full rationale).
PLUGIN_ROOT="${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"
if [ -z "$PLUGIN_ROOT" ]; then
  _c="$HOME/.claude/plugins/cache/busdriver/busdriver"
  _v="$(ls "$_c" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
  [ -n "$_v" ] && PLUGIN_ROOT="$_c/$_v"
fi
PLUGIN_ROOT="${PLUGIN_ROOT%/}"
# Validate but do NOT exit 1 — unlike Step 4b, the _forced=1 trigger path below needs
# no adapter at all (the fable subagent needs no plugin root), so a bogus/missing
# PLUGIN_ROOT here must not abort the whole gate. It only
# matters for the USER-config check a few lines down, which already fails closed via
# `source ... 2>/dev/null` — this just makes the failure diagnosable instead of silent.
[ -n "$PLUGIN_ROOT" ] && [ -d "$PLUGIN_ROOT" ] || echo "council: cannot resolve busdriver plugin root for the USER-config check — set BUSDRIVER_PLUGIN_ROOT (the forced-trigger path is unaffected)" >&2
_forced=0   # set to 1 when the user invoked "ultimate council" this run
MYTHOS_ATTEMPT=0
# BUSDRIVER_ULTIMATE=0 (global force-OFF) outranks both config opt-in and the trigger.
if [ "${BUSDRIVER_ULTIMATE:-}" != 0 ]; then
  if [ "$_forced" = 1 ]; then
    MYTHOS_ATTEMPT=1        # trigger authorizes the in-harness subagent — needs no
                            # adapter, so it must NOT be gated on sourcing one
  # ultimate-config.sh is bash-only (its BASH_SOURCE guard rejects the zsh executor macOS uses),
  # so run the surface check under an explicit `bash -c`, passing PLUGIN_ROOT as $1.
  elif bash -c 'source "$1/scripts/lib/ultimate-config.sh" 2>/dev/null && ultimate_surface_enabled council' _ "$PLUGIN_ROOT"; then
    MYTHOS_ATTEMPT=1        # USER-config opt-in (the adapter reads the surface flag)
  fi
fi
echo "MYTHOS_ATTEMPT=$MYTHOS_ATTEMPT"
```

**Primary — fable subagent (only when `MYTHOS_ATTEMPT=1`).** Dispatch in the SAME Step 4 message as the
4a Skeptic and the 4b voices Bash call — one message, maximal concurrency:

```text
Agent(
  description="Council Mythos Witness",
  prompt="You are the Mythos Witness — a second, independent expert witness to a council of five advisors. You are NOT one of the five voices and NOT a vote. [QUESTION + CONTEXT]. Bring a distinct synthesizing lens the five voices miss — second-order effects, the framing they all share, the option nobody named. Give: 1. Position (1-2 sentences) 2. Reasoning (3 points) 3. Risk 4. Surprise. Under 300 words, opinionated, no hedging. Your factual/empirical claims are treated as UNVERIFIED until checked against local evidence.",
  model="fable"   # pins claude-fable-5 in-harness — no gateway, no external transmission
)
```

Read the subagent's returned text as the Mythos verdict. There is **no fallback transport** — the gateway
rung was removed (ADR 0019), so a failed subagent goes straight to the `MYTHOS_FAILED` render below.

**Render (Step 5).** Whenever `MYTHOS_ATTEMPT=1`, render the Mythos Witness — never as a voice, never in
the vote tally. You (the executor) grade the Agent call's own result directly; there is no Bash rc token
to read:

- **Subagent returned text** → place it in the Mythos Witness section.
- **Subagent errored, or the harness rejected `model="fable"`** → render `MYTHOS_FAILED [subagent-failed]`.
- **Subagent returned empty/whitespace-only** → render `MYTHOS_FAILED [empty verdict]`.

NEVER silently omit an *attempted* witness (an omitted section reads as "not an ultimate-council" — a
fail-OPEN). Omission is correct ONLY for `MYTHOS_ATTEMPT=0`, i.e. the witness was never attempted.

**Rendering directive (binding):** In the Step 6 report, whenever the Mythos Witness was attempted, render
a SEPARATE top-level `## Mythos Witness — Expert Witness` section AFTER the `## UltraOracle — Expert Witness`
section and BEFORE `### Verdict`. On a verdict, place the `cat`'d text (reproduced faithfully — annotate
any ungrounded repo-specific claim as ungrounded); it is advisory and EXCLUDED from the vote tally, and
must NOT flip a hard recommendation without independent local evidence (grep/Read/run). On any
`MYTHOS_FAILED […]` token render a loud `## ⚠ MYTHOS_FAILED [<status>] — Mythos Witness verdict NOT included`
banner in that slot — never silently omit it. Never place the Mythos Witness in a voice slot or count it
toward consensus.

### Step 4.7: Optional Mechanism Witness ("ultimate-council", off by default)

The **Mechanism Witness** is the council's third expert witness — opencode running the configured `.auditor.model` with the
*claim-vs-mechanism* lens (does the artifact actually do what it says). It shares the ultimate tier with
the Mythos Witness and is authorized by the **same `MYTHOS_ATTEMPT` gate** (Step 4.6) — so an
ultimate-council runs all three witnesses (UltraOracle + Mythos + Mechanism); a plain or ultra-council
runs none of the Mechanism Witness.

- **Was the always-on "advisory Auditor".** Until ADR 0027 this witness voice dispatched in *every* council at a
  120s budget. the witness runs a slow reasoning model that routinely timed out silently at 120s (no droid
  fallback → it just vanished from the report), so it moved to the already-slow ultimate tier and got a
  **900s** budget (UltraOracle-parity — the oracle's `ultra_oracle_timeout_cap` also defaults to 900s, so
  the witness rides that window rather than extending it; hard-clamped at 900 since the env is repo-injectable). The internal route key stays `council.auditor` and the
  `auditor.json`/`AUDITOR_*` identifiers are unchanged — only the surface framing (Mechanism Witness) and
  the tier changed.
- **Transport = the Step 4b opencode dispatch block**, already written above and self-gated on
  `MECHANISM_WITNESS`. There is no separate adapter — unlike the Mythos fable subagent (an Agent call),
  the Mechanism Witness IS one of the Step 4 background dispatches, just conditionally included.
- **No droid fallback** (see the Roles section) — if opencode is unavailable the witness is absent and the
  report says so. Its findings are **leads, not verdicts** (measured inverted-confidence limitation above).

**Enable it:** the Step 4b preamble already contains a **literal `MECHANISM_WITNESS=0`** (which shadows any
repo-injected ambient value — see that line's comment). When the Step 4.6 gate printed `MYTHOS_ATTEMPT=1`,
**change that literal to `MECHANISM_WITNESS=1`** (do NOT add a separate assignment that an injected env var
could pre-empt — edit the literal in place). The Step 4b dispatch block self-gates on it. Keep it a plain,
non-exported literal (never `export` — it would leak into a later council in a persistent shell). A plain
or ultra-council **leaves the literal at 0**, so the block skips the witness. This is the
same force-var pattern as the UltraOracle — the ultimate tier just sets both.

> **Bash-tool timeout:** the Mechanism Witness is one of the Step 4 background dispatches; its reap can
> block the closing `wait` for up to **`_AUD_TO + 10` ≤ 910s**. Do NOT assume the UltraOracle covers this —
> an ultimate-council can have `MYTHOS_ATTEMPT=1` (via `ultimate.surfaces.council`) while the oracle is
> disabled, or the oracle's `timeoutCapSeconds` can be set below 900 — so the witness is NOT always hidden behind an
> oracle window. Size the Step 4 Bash-tool `timeout` to cover **`max(oracle budget + 90s, 910s)`** whenever
> `MECHANISM_WITNESS=1`. The witness's clamp is hard-pinned to 900s (the oracle's *default* cap) so this bound stays
> ~equal to the oracle's own #477 requirement in the common both-run case; a 3600s witness would blow past it.

### Step 5: Read Output and Synthesize

Read the Fresh Claude output from the Agent tool result. Read the Agy/Codex/Grok/opencode output from the path printed by dispatch.sh to stderr (typically `${TMPDIR:-/tmp}/dispatch-{cli}-*.txt`; on macOS, TMPDIR is `/var/folders/...`, not `/tmp`). When the resolver falls back to Droid in the Researcher slot (grok unavailable), the output filename is `dispatch-droid-*.txt` and the report should attribute "Droid (Researcher, fallback)" rather than "Grok (Researcher)".

If the UltraOracle escalation ran (ultra-council), the wrapper's first-line token in `$ULTRA_ORACLE_RESULT` (`VERDICT` / `NOT_ATTEMPTED` / `FAILED [status]`) is graded by the render block above; the verdict text also persists at the `--out` path (`.claude/ultra-oracle/council-$$.md`). Capture the emitted verdict (or `ORACLE_FAILED` token) and render it as the separate Expert Witness section per Step 4.5's binding directive, never as a voice and never folded into the vote. A `NOT_ATTEMPTED` token means the oracle did not run — omit the section entirely.

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

The expert witnesses — the UltraOracle (ultra-council / ultimate-council), the Mythos Witness AND the Mechanism Witness (both ultimate-council only) — are NOT among the voices above; keep ALL of them out of the vote tally and the consensus/dissent counts, and treat each witness's claims like a Researcher's (unverified until checked against local evidence).
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

## UltraOracle — Expert Witness [ORACLE_SUMMARY_REVIEW]
(Render this section whenever the UltraOracle escalation RAN — user-config enabled OR ultra-council forced; OMIT the entire section when the oracle did not run. It is NOT a voice and is EXCLUDED from Consensus / Strongest dissent / Recommendation below.)
[the verdict text, reproduced faithfully — annotate any ungrounded repo-specific claim as ungrounded]
(On failure render instead: **⚠ ORACLE_FAILED [status] — UltraOracle Expert Witness verdict NOT included**.)

## Mythos Witness — Expert Witness
(Render this section whenever the Mythos Witness RAN — user-config `ultimate.surfaces.council` enabled OR ultimate-council forced; OMIT the entire section when it did not run. Place it AFTER the UltraOracle section and BEFORE the Verdict. It is Claude Fable (dispatched as an in-harness subagent), NOT a voice, and is EXCLUDED from Consensus / Strongest dissent / Recommendation below.)
[the verdict text, reproduced faithfully — annotate any ungrounded repo-specific claim as ungrounded; treat claims as unverified until checked]
(On failure render instead: **⚠ MYTHOS_FAILED [status] — Mythos Witness verdict NOT included**.)

## Mechanism Witness — Expert Witness [claim-vs-mechanism]
(Render this section whenever this is an ultimate-council — `MECHANISM_WITNESS=1`. OMIT the entire section ONLY when `MECHANISM_WITNESS≠1` (a plain or ultra-council — the witness was never attempted). Place it AFTER the Mythos Witness and BEFORE the Verdict. It is the witness model, NOT a voice, and is EXCLUDED from Consensus / Strongest dissent / Recommendation below. Per the Known Limitation above, treat every finding as an unverified lead — cite file:line and independently confirm before acting. Like the Mythos Witness, an *attempted* witness is NEVER silently omitted — an ultimate-council that renders only two witness sections reads as "the witness ran and found nothing," a fail-OPEN.)
[the findings text, reproduced faithfully, or **NOTHING FOUND** if the witness found nothing]
(On failure/timeout render instead: **⚠ MECHANISM_FAILED [status] — Mechanism Witness verdict NOT included**. Two distinct cases render **ABSENT**, not FAILED, so an ultimate-council never silently drops a witness: (1) `council.auditor` resolved to `none` — opencode unavailable, no droid fallback — render **⚠ MECHANISM_ABSENT [opencode unavailable] — Mechanism Witness NOT included**; (2) opencode IS available but `.auditor.model` is unset/invalid and no `--model` was given — render **⚠ MECHANISM_ABSENT [no .auditor.model configured] — Mechanism Witness NOT included**. **The council dispatches through `$DISPATCH` (`skills/dispatch-cli/scripts/dispatch.sh`) at Step 4 — not `execute_review`** — so the signal you actually receive is the output file's leading line `Skipped: no usable .auditor.model and no --model — auditor not dispatched`. **That line is the only durable signal — key on it.** Do not reach for the `.meta` file: `dispatch.sh` reads it and `rm -f`s it in the same statement, so by the time the council inspects anything it is gone — the `.meta` file itself never survives, which is exactly why the output-file line is the one to key on instead. Do not key on the exit code either: Step 4's `wait` discards it, and it is `1` here regardless — indistinguishable from a genuine failure. (`execute_review` in `scripts/lib/resolve-cli.sh` signals the same condition as rc **4** with an empty output file, but that is blueprint-review's path, not this one; do not carry rc 4 into council reasoning.) Check for the `Skipped:` line BEFORE treating a non-empty run as a FAILED verdict — otherwise this documented skip is misread as a failure, or its skip text is reproduced as findings.)

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

1. For Agy + Codex + Grok + opencode: include prior council positions in the dispatch prompt as context
2. **For Fresh Claude Skeptic: include ONLY the new follow-up question + original question — do NOT include prior council positions.** This is critical — the Skeptic's value comes from clean memory. If you anchor them on prior positions, they become a fifth confirming voice instead of an independent challenger.
3. Add the user's follow-up question
4. Frame for Agy/Codex/Grok/opencode: "The council previously said [positions]. The user now asks: [follow-up]. Respond to the other advisors' positions AND the new question."
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
| Verifying whether output is correct | `/santa-loop` |
| Breaking a feature into implementation steps | `planner` |
| Designing system architecture | `architect` |
| Reviewing code for bugs or security | `code-reviewer` |
| Straight factual questions | just answer directly |
| Obvious execution tasks | just do the task |

