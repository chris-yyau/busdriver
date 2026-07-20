---
name: council
description: >-
  Convene a 5-voice AI council (Architect, Skeptic, Pragmatist, Critic,
  Researcher) for ambiguous decisions needing multiple lenses — design,
  tradeoffs, architecture, strategy. Triggers include council, roundtable,
  perspectives, group wisdom, ideas/feedback/advice; "ultra-council" adds the
  UltraOracle (ChatGPT Pro) expert witness; "ultimate-council" adds BOTH the
  UltraOracle AND the Mythos Witness (Claude Fable, subagent-first),
  each rendered separately, never a vote. Not for simple tasks with clear
  answers.
origin: custom
---

# Council

Convene five advisors — the in-context Claude plus four fresh agents — for diverse perspectives. Each gives an independent perspective, then synthesize into a compressed verdict. (An **ultra-council** run adds an optional UltraOracle expert witness — see Step 4.5 — rendered as its own section, never counted among the five voices. An **ultimate-council** run adds BOTH the UltraOracle AND a **Mythos Witness** — Claude Fable, dispatched as an in-harness subagent; see Step 4.6 — each rendered as its own section, neither counted among the five voices.)

## Roles (Fixed)

| Voice | Method | Role | Lens | Configurable |
|---|---|---|---|---|
| Claude (you) | In-context | Architect | Correctness, maintainability, long-term implications | No (in-context) |
| Fresh Claude | Agent tool (clean memory) | Skeptic | Challenge assumptions, question premises, propose simplest alternative | No (Agent tool) |
| Configurable | dispatch-cli | Pragmatist | Shipping speed, simplicity, user impact, practical tradeoffs | Yes: `council.pragmatist` (default: agy) |
| Configurable | dispatch-cli | Critic | Edge cases, risks, failure modes, what could go wrong | Yes: `council.critic` (default: codex) |
| Configurable | dispatch-cli | Researcher | Evidence, prior art, current state, factual grounding | Yes: `council.researcher` (default: grok, fallback: droid) |

(UltraOracle is **not** in this table — it is an optional expert witness, not a sixth fixed role. See Step 4.5. The **Auditor** below is likewise not a fixed role.)

**Auditor (advisory, on by default, never counted among the five voices).** Route `council.auditor`, default `opencode` → `opencode-go/kimi-k3`. Lens: *claim-vs-mechanism* — does the artifact actually do what it says it does. Rendered as its own section like the UltraOracle, never folded into the five-voice synthesis and never a vote.

Two deliberate properties:

- **Not a fixed role**, because the five-voice composition is load-bearing across ADRs 0006/0011/0012/0013/0019, the ultra/ultimate council skills, and the README. Adding a sixth chair would require rewriting immutable decision records to stay honest. Advisory costs nothing and keeps the count true.
- **No droid fallback.** Every other role falls back to droid for availability; this one does not. Droid already backstops three slots, so a droid Auditor would be a fourth copy of the same model wearing a new label — worse than an absent voice, because it reads as independent corroboration while adding no independent signal. If opencode is missing, the Auditor is absent and the report says so.

**Known limitation — treat Auditor findings as leads, not verdicts.** Measured against three already-passed PRs (2026-07-20): one verified true positive that Codex xhigh and the Opus backstop both missed, one confidently-asserted false positive, one correct `NOTHING FOUND`. Its confidence labels were *inverted* on that sample — it marked the hallucination MEDIUM and the real defect LOW. Verify before acting on anything it reports.

**CLI routing:** Pragmatist, Critic, and Researcher CLIs (plus the advisory Auditor) are resolved from `.claude/busdriver.json` via `resolve_role_cli()`. Each role accepts a route array — the resolver walks it left-to-right and returns the first available CLI (e.g., `"council.pragmatist": ["agy", "droid"]` falls back to Droid if Agy is missing). If every CLI in the chain is missing, that voice is skipped and noted in the report; other voices still fire. Changing the CLI only changes which binary receives the prompt — the role framing (Pragmatist lens, Critic lens, Researcher lens) is always the same. **Trade-off to know:** fallback preserves availability but dilutes role identity — Droid filling in as Pragmatist is no longer "Agy's strategic lens." Accept this when resilience matters more than signal purity. See README for per-role routing docs.

**Runtime retry + droid fallback (distinct from the route-array fallback above):** the route array picks a CLI by *availability* at resolve time. At *runtime*, each dispatched fixed voice (Agy/Codex/Grok) also retries up to `BUSDRIVER_CLI_RETRIES` (default `3`) on a transient failure (rate-limit, network, 5xx) or empty output — a single flake no longer drops the voice. A timeout is never retried (re-running the full window is too costly). Only after retries are exhausted does the per-voice runtime droid fallback fire; voices fall back independently (distinct role prompts → distinct perspectives, so no cross-voice cap). Set `BUSDRIVER_CLI_RETRIES=0` to disable retries. **The advisory Auditor is exempt from the droid fallback** for the reason given in its own section — a droid Auditor is a fourth copy of an existing model masquerading as an independent lens; retries still apply, but on exhaustion the Auditor is simply absent.

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

### Step 4: Dispatch Fresh Claude + Agy + Codex + Grok (+ advisory Auditor)

Launch all four external agents (plus the advisory Auditor) in parallel. Use a **single message with multiple tool calls** to maximize concurrency.

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
# Resolve the plugin root ONCE. CLAUDE_PLUGIN_ROOT is NOT populated in the Bash
# tool env of every harness (empty in SDK/child sessions), and a bare
# "${CLAUDE_PLUGIN_ROOT}/..." would then collapse to "/scripts/..." and every
# voice + witness would silently fail to launch. Fall back to the newest
# installed cache dir; override with BUSDRIVER_PLUGIN_ROOT. This PLUGIN_ROOT is
# in scope for the Step 4.5 witness snippet (UltraOracle), which is inserted into THIS
# same block (it shares this shell, alongside PIDS). Step 4.6 (Mythos Witness) runs as
# standalone Bash calls and re-resolves PLUGIN_ROOT independently (see there).
PLUGIN_ROOT="${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"
if [ -z "$PLUGIN_ROOT" ]; then
  # newest installed STABLE cache version. grep keeps only pure X.Y.Z dirs
  # (drops prereleases like 2.0.0-beta.1, whose numeric key ties with 2.0.0 and
  # would win the line tie-break). Then numeric field sort by major.minor.patch:
  # NOT `sort -V` (GNU-only; stock macOS BSD sort lacks it) and NOT mtime/`ls -t`
  # (a reinstalled older version can carry a newer mtime). `sort -t. -kN,Nn` is
  # portable across BSD and GNU sort.
  _cache="$HOME/.claude/plugins/cache/busdriver/busdriver"
  _v="$(ls "$_cache" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
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
AUDITOR_PID=""
if [[ "$AUDITOR_CLI" != "none" && "$AUDITOR_CLI" != "builtin" && ! "$AUDITOR_CLI" =~ ^(missing|unsupported): ]]; then
  # Auditor runs read-only via the plugin-owned opencode config (deny-all
  # tools except read/glob/grep). See the opencode) arm in resolve-cli.sh for
  # the four-round probe history — enumerated denylists all leaked.
  # A SHORTER timeout than the fixed voices (advisory must not extend the run),
  # and its PID is kept OUT of the blocking PIDS array — see the bounded reap.
  "$DISPATCH" --cli "$AUDITOR_CLI" --timeout "${COUNCIL_AUDITOR_TIMEOUT:-120}" <<'AUDITOR_PROMPT' &
<Auditor prompt>
AUDITOR_PROMPT
  AUDITOR_PID="$!"
fi
# Block on the FIXED voices only. The advisory Auditor is reaped separately with
# a bounded grace so a stall cannot gate the council: once the fixed voices are
# in, give the Auditor a short window, then kill its process TREE and proceed
# (execute_review + opencode are descendants; killing only $AUDITOR_PID orphans
# them).
(( ${#PIDS[@]} )) && wait "${PIDS[@]}"
if [[ -n "$AUDITOR_PID" ]]; then
  _ag=0
  while kill -0 "$AUDITOR_PID" 2>/dev/null; do
    if [[ "$_ag" -ge "${COUNCIL_AUDITOR_GRACE:-20}" ]]; then
      _kt() { local p="$1" c; for c in $(pgrep -P "$p" 2>/dev/null); do _kt "$c"; done; kill "$p" 2>/dev/null || true; }
      _kt "$AUDITOR_PID"
      break
    fi
    sleep 1; _ag=$((_ag + 1))
  done
  wait "$AUDITOR_PID" 2>/dev/null || true
fi
```

This is a **single Bash call** with all four CLI dispatches as background processes. This is critical — if Agy, Codex, Grok and opencode are separate parallel Bash tool calls, one failing cancels the others. A single call with `&` and `wait` keeps them independent.

**NEVER wrap dispatches in subshells `()`**. The pattern `( cmd & ) && wait` does NOT work — the subshell exits immediately after backgrounding, so `wait` has nothing to wait for. Always background directly and capture PIDs with `$!`.

**Prompt template** for Agy/Codex/Grok/opencode (same structure as Skeptic but with their role/lens). When the resolver falls back to Droid in any slot, the same role/lens text is sent — these labels track the *default primary* CLI per role.

**For Agy:** Role = "Pragmatist", Lens = "shipping speed, simplicity, user impact, practical tradeoffs"
**For Codex:** Role = "Critic", Lens = "edge cases, risks, failure modes, what could go wrong"
**For opencode (Auditor):** Role = "Auditor", Lens = "claim-vs-mechanism. For each load-bearing claim the proposal makes about how something works — a comment, a doc line, a guarantee, a 'this is handled by X' — check whether the mechanism cited actually produces that behavior, and say so concretely. You are not looking for better designs or missing features; you are looking for places where the stated behavior and the actual behavior diverge. Cite file:line. If you find nothing real, say NOTHING FOUND rather than manufacturing a finding — a confident false positive costs more than a missed nit. Label each finding with your confidence and be willing to say you could not verify a claim from the material available."

**For Grok:** Role = "Researcher", Lens = "evidence, prior art, current state — look up similar past decisions, current code state of the repo, and external evidence relevant to the question. Provide links, quotes, and sources — NOT conclusions stated as settled fact. Your factual/empirical claims are treated as UNVERIFIED by default until checked against local evidence, so for each load-bearing claim name the cheap local check (command / file / grep) that would confirm or refute it. Cite what you find; flag claims that lack grounding."

**IMPORTANT:** Launch the Agent tool call AND the single Bash dispatch call (containing Agy + Codex + Grok + opencode as background processes) in the **same message** so all four external voices plus the advisory Auditor run concurrently. Do NOT use separate Bash tool calls — one failing will cancel the others.

**Missing CLI handling:** Each role's route array is walked left-to-right; the first available CLI wins. If every CLI in the chain resolves to `none`, `builtin`, `missing:<cli>`, or `unsupported:<cli>` (the last fires when a stale config references a removed backend like amp/claude/aider — migration warning goes to stderr), that voice is skipped and the report notes its absence as `(unavailable)`. The remaining voices still convene. If the Skeptic Agent call fails (rate limit, timeout), same rule applies. Typical minimum is 2 voices (Architect + Skeptic, 40% of full strength); absolute floor is 1 voice (Architect alone) if the Skeptic Agent call also fails. Always note the composition in the report — and when a fallback fires (e.g., Droid serving as Pragmatist because Agy was missing), note that explicitly so the report doesn't misattribute the lens.

### Step 4.5: Optional UltraOracle Expert Witness ("ultra-council", off by default)

An UltraOracle (ChatGPT Pro) **expert witness** can be escalated ONLY when `ultraOracle.council.enabled` is true in the operator's **USER config** `~/.claude/busdriver.json` (a repo-controlled project config CANNOT enable it — security), OR the user explicitly invokes **"ultra-council" / "ultra council"** (or asks to include the oracle). To force it for that run, add `ULTRA_ORACLE_COUNCIL_FORCE=1` as a **plain, non-exported** assignment at the very top of the single Step 4 dispatch Bash block, and `unset ULTRA_ORACLE_COUNCIL_FORCE` as its last line (the launch wiring below already reads the var). Do NOT `export` it (it would persist into a later council in a persistent shell), do NOT use a one-command `VAR=1 cmd` prefix (it would not reach the gate), and do NOT wrap the dispatch in a subshell (the no-subshell rule in Step 4 — it would strand `PIDS`). A **normal council omits that line entirely**; the gate's `:-0` default then leaves the oracle off unless user-config enabled it. It is dispatched via the shared `ultra_oracle_consult` adapter (the `oracle` CLI's ChatGPT Pro browser engine), inside that SAME single-Bash dispatch block as the other voices (separate Bash calls serialize/cancel — see Step 4).

UltraOracle is **not** a vote: it is rendered as its own Expert Witness section (Step 5/Step 6) and is EXCLUDED from the council vote tally — consensus, strongest dissent, and the recommendation are computed from the five voices only (ADR 0007 settling-check #1). The consult attaches no evidence-pack files (it sends only the prompt text — a Claude-authored question + context), so its result is labeled `ORACLE_SUMMARY_REVIEW` per the ADR review-type table (a Claude-authored summary, not a repo-attached review) even if that prompt text quotes snippets; a repo-specific claim with no file/path evidence is ungrounded — say so.

**Trade-off (why it's off by default):** a single slow Pro consult makes every council it joins run minutes instead of seconds, and as an expert witness it carries weight only when its claims are evidence-backed. Never add it to the default roster.

**Data boundary:** ultra-oracle transmits the council question to ChatGPT Pro via the oracle browser engine. When Chrome blocks programmatic cookie decryption (recent cookie-encryption hardening — App-Bound Encryption on Windows, Keychain-bound on macOS; observed on macOS Chrome 149, #340), `cookiePath` and `chromeProfileDir` both fail — set `ultraOracle.remoteHost` + `ultraOracle.remoteToken` to delegate to a persistent `oracle serve --manual-login --host 127.0.0.1 --token <T>` you sign into once (`remoteToken` is a secret; pin `127.0.0.1`). Otherwise use `ultraOracle.cookiePath` (a signed-in Cookies DB) or `ultraOracle.chromeProfileDir` (a dedicated ChatGPT-only profile clone). All USER-config only. Do not enable where the question would carry secrets. See `blueprint-review/SKILL.md` for the full precedence + issue #340.

Launch wiring (inside the Step 4 dispatch Bash block, alongside the voices). The oracle runs via the **bash-shebang wrapper `scripts/ultra-oracle-run.sh`**, NOT an in-block `source`. This is load-bearing: `scripts/lib/ultra-oracle.sh` is bash-only (resolves its own dir via `${BASH_SOURCE[0]}`, uses `local -a`) and fail-closes when sourced outside bash — and this Step 4 block is pasted verbatim into the executor's Bash tool, which on a zsh-default machine (macOS) runs **zsh**. An in-block `source` therefore aborted with rc=1 and every ultra-council run silently rendered `ORACLE_FAILED [adapter-unavailable]` (the oracle never launched; the voices were immune only because `dispatch.sh` carries its own bash shebang). The wrapper gives the oracle the same shell-agnostic immunity. It self-gates (surface-enabled OR forced), blocks internally until the consult completes, and prints one typed token — track it in `PIDS` like every other voice and read its result after `wait`. A normal council omits `ULTRA_ORACLE_COUNCIL_FORCE` entirely; the wrapper then prints `NOT_ATTEMPTED` unless user config enabled the surface.

```bash
ULTRA_ORACLE_RESULT="$(mktemp)"; ULTRA_ORACLE_PROMPT_FILE="$(mktemp)"
cat > "$ULTRA_ORACLE_PROMPT_FILE" <<'ULTRA_ORACLE_PROMPT'
<the council question + context — same text composed into the other voices' heredocs>
ULTRA_ORACLE_PROMPT
# Background the wrapper so its consult overlaps the voices; it blocks internally
# until done, so `wait "${PIDS[@]}"` covers it. ULTRA_ORACLE_COUNCIL_FORCE is the
# plain (non-exported) per-run escalation; pass it as arg 2 (a normal council
# leaves it unset → 0). arg 4 is where the verdict markdown + .rc marker land.
# The `{ ...; rm -f ...; }` group deletes the prompt file once the wrapper exits
# (VERDICT, FAILED, or NOT_ATTEMPTED alike) so the council question text — which
# may carry sensitive repo/design context — never lingers in $TMPDIR after an
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

The UltraOracle expert witness (ultra-council / ultimate-council) AND the Mythos Witness (ultimate-council only) are advisory and are NOT among the voices above — keep BOTH out of the vote tally and the consensus/dissent counts; treat each witness's claims like a Researcher's (unverified until checked against local evidence).
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
| Verifying whether output is correct | `santa-method` |
| Breaking a feature into implementation steps | `planner` |
| Designing system architecture | `architect` |
| Reviewing code for bugs or security | `code-reviewer` or `santa-method` |
| Straight factual questions | just answer directly |
| Obvious execution tasks | just do the task |

## Related Skills

- `santa-method` — adversarial verification (two-reviewer convergence)
- `knowledge-ops` — persist durable decision deltas to the right location (vault)
- `search-first` — gather external reference material before convening
- `architecture-decision-records` — formalize the outcome when the decision becomes long-lived system policy
