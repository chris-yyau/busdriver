---
name: council
description: >-
  Convene a 5-voice AI council (Architect, Skeptic, Pragmatist, Critic,
  Researcher) for ambiguous decisions needing multiple lenses — design,
  tradeoffs, architecture, strategy. Triggers include council, roundtable,
  perspectives, group wisdom, ideas/feedback/advice; "ultra-council" adds the
  UltraOracle (GPT-5.5 Pro) expert witness; "ultimate-council" adds BOTH the
  UltraOracle AND the Mythos Witness (Claude Fable via the zenmux gateway),
  each rendered separately, never a vote. Not for simple tasks with clear
  answers.
origin: custom
---

# Council

Convene five advisors — the in-context Claude plus four fresh agents — for diverse perspectives. Each gives an independent perspective, then synthesize into a compressed verdict. (An **ultra-council** run adds an optional UltraOracle expert witness — see Step 4.5 — rendered as its own section, never counted among the five voices. An **ultimate-council** run adds BOTH the UltraOracle AND a **Mythos Witness** — Claude Fable via the zenmux gateway; see Step 4.6 — each rendered as its own section, neither counted among the five voices.)

## Roles (Fixed)

| Voice | Method | Role | Lens | Configurable |
|---|---|---|---|---|
| Claude (you) | In-context | Architect | Correctness, maintainability, long-term implications | No (in-context) |
| Fresh Claude | Agent tool (clean memory) | Skeptic | Challenge assumptions, question premises, propose simplest alternative | No (Agent tool) |
| Configurable | dispatch-cli | Pragmatist | Shipping speed, simplicity, user impact, practical tradeoffs | Yes: `council.pragmatist` (default: agy) |
| Configurable | dispatch-cli | Critic | Edge cases, risks, failure modes, what could go wrong | Yes: `council.critic` (default: codex) |
| Configurable | dispatch-cli | Researcher | Evidence, prior art, current state, factual grounding | Yes: `council.researcher` (default: grok, fallback: droid) |

(UltraOracle is **not** in this table — it is an optional expert witness, not a sixth fixed role. See Step 4.5.)

**CLI routing:** Pragmatist, Critic, and Researcher CLIs are resolved from `.claude/busdriver.json` via `resolve_role_cli()`. Each role accepts a route array — the resolver walks it left-to-right and returns the first available CLI (e.g., `"council.pragmatist": ["agy", "droid"]` falls back to Droid if Agy is missing). If every CLI in the chain is missing, that voice is skipped and noted in the report; other voices still fire. Changing the CLI only changes which binary receives the prompt — the role framing (Pragmatist lens, Critic lens, Researcher lens) is always the same. **Trade-off to know:** fallback preserves availability but dilutes role identity — Droid filling in as Pragmatist is no longer "Agy's strategic lens." Accept this when resilience matters more than signal purity. See README for per-role routing docs.

**Runtime retry + droid fallback (distinct from the route-array fallback above):** the route array picks a CLI by *availability* at resolve time. At *runtime*, each dispatched voice (Agy/Codex/Grok) also retries up to `BUSDRIVER_CLI_RETRIES` (default `3`) on a transient failure (rate-limit, network, 5xx) or empty output — a single flake no longer drops the voice. A timeout is never retried (re-running the full window is too costly). Only after retries are exhausted does the per-voice runtime droid fallback fire; voices fall back independently (distinct role prompts → distinct perspectives, so no cross-voice cap). Set `BUSDRIVER_CLI_RETRIES=0` to disable retries.

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
# Resolve the plugin root ONCE. CLAUDE_PLUGIN_ROOT is NOT populated in the Bash
# tool env of every harness (empty in SDK/child sessions), and a bare
# "${CLAUDE_PLUGIN_ROOT}/..." would then collapse to "/scripts/..." and every
# voice + witness would silently fail to launch. Fall back to the newest
# installed cache dir; override with BUSDRIVER_PLUGIN_ROOT. This PLUGIN_ROOT is
# in scope for the Step 4.5/4.6 witness snippets, which are inserted into THIS
# same block (they share this shell, alongside PIDS).
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
(( ${#PIDS[@]} )) && wait "${PIDS[@]}"
```

This is a **single Bash call** with all three CLI dispatches as background processes. This is critical — if Agy, Codex, and Grok are separate parallel Bash tool calls, one failing cancels the others. A single call with `&` and `wait` keeps them independent.

**NEVER wrap dispatches in subshells `()`**. The pattern `( cmd & ) && wait` does NOT work — the subshell exits immediately after backgrounding, so `wait` has nothing to wait for. Always background directly and capture PIDs with `$!`.

**Prompt template** for Agy/Codex/Grok (same structure as Skeptic but with their role/lens). When the resolver falls back to Droid in any slot, the same role/lens text is sent — these labels track the *default primary* CLI per role.

**For Agy:** Role = "Pragmatist", Lens = "shipping speed, simplicity, user impact, practical tradeoffs"
**For Codex:** Role = "Critic", Lens = "edge cases, risks, failure modes, what could go wrong"
**For Grok:** Role = "Researcher", Lens = "evidence, prior art, current state — look up similar past decisions, current code state of the repo, and external evidence relevant to the question. Provide links, quotes, and sources — NOT conclusions stated as settled fact. Your factual/empirical claims are treated as UNVERIFIED by default until checked against local evidence, so for each load-bearing claim name the cheap local check (command / file / grep) that would confirm or refute it. Cite what you find; flag claims that lack grounding."

**IMPORTANT:** Launch the Agent tool call AND the single Bash dispatch call (containing Agy + Codex + Grok as background processes) in the **same message** so all four external voices run concurrently. Do NOT use separate Bash tool calls — one failing will cancel the others.

**Missing CLI handling:** Each role's route array is walked left-to-right; the first available CLI wins. If every CLI in the chain resolves to `none`, `builtin`, `missing:<cli>`, or `unsupported:<cli>` (the last fires when a stale config references a removed backend like amp/claude/aider — migration warning goes to stderr), that voice is skipped and the report notes its absence as `(unavailable)`. The remaining voices still convene. If the Skeptic Agent call fails (rate limit, timeout), same rule applies. Typical minimum is 2 voices (Architect + Skeptic, 40% of full strength); absolute floor is 1 voice (Architect alone) if the Skeptic Agent call also fails. Always note the composition in the report — and when a fallback fires (e.g., Droid serving as Pragmatist because Agy was missing), note that explicitly so the report doesn't misattribute the lens.

### Step 4.5: Optional UltraOracle Expert Witness ("ultra-council", off by default)

An UltraOracle (GPT-5.5 Pro) **expert witness** can be escalated ONLY when `ultraOracle.council.enabled` is true in the operator's **USER config** `~/.claude/busdriver.json` (a repo-controlled project config CANNOT enable it — security), OR the user explicitly invokes **"ultra-council" / "ultra council"** (or asks to include the oracle). To force it for that run, add `ULTRA_ORACLE_COUNCIL_FORCE=1` as a **plain, non-exported** assignment at the very top of the single Step 4 dispatch Bash block, and `unset ULTRA_ORACLE_COUNCIL_FORCE` as its last line (the launch wiring below already reads the var). Do NOT `export` it (it would persist into a later council in a persistent shell), do NOT use a one-command `VAR=1 cmd` prefix (it would not reach the gate), and do NOT wrap the dispatch in a subshell (the no-subshell rule in Step 4 — it would strand `PIDS`). A **normal council omits that line entirely**; the gate's `:-0` default then leaves the oracle off unless user-config enabled it. It is dispatched via the shared `ultra_oracle_consult` adapter (the `oracle` CLI's ChatGPT Pro browser engine), inside that SAME single-Bash dispatch block as the other voices (separate Bash calls serialize/cancel — see Step 4).

UltraOracle is **not** a vote: it is rendered as its own Expert Witness section (Step 5/Step 6) and is EXCLUDED from the council vote tally — consensus, strongest dissent, and the recommendation are computed from the five voices only (ADR 0007 settling-check #1). The consult attaches no evidence-pack files (it sends only the prompt text — a Claude-authored question + context), so its result is labeled `ORACLE_SUMMARY_REVIEW` per the ADR review-type table (a Claude-authored summary, not a repo-attached review) even if that prompt text quotes snippets; a repo-specific claim with no file/path evidence is ungrounded — say so.

**Trade-off (why it's off by default):** a single slow Pro consult makes every council it joins run minutes instead of seconds, and as an expert witness it carries weight only when its claims are evidence-backed. Never add it to the default roster.

**Data boundary:** ultra-oracle transmits the council question to ChatGPT Pro via the oracle browser engine; if `ultraOracle.chromeProfileDir` is set it clones that Chrome profile's session — use a dedicated ChatGPT-only profile. Prefer `ultraOracle.cookiePath` (a signed-in Chrome Cookies DB path) to reuse the session headlessly without cloning the whole profile — the reliable path where Chrome app-bound cookie encryption defeats `--copy-profile`. Do not enable where the question would carry secrets.

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

The **Mythos Witness** is the council's second expert witness — **Claude Fable dispatched through
the zenmux gateway** (the `ultimate` tier; see ADR 0011). It is escalated ONLY when
`ultimate.surfaces.council` is true in the operator's **USER config** `~/.claude/busdriver.json`
(a repo-controlled project config CANNOT enable it — enabling transmits the question to an external
gateway), OR the user explicitly invokes **"ultimate-council" / "ultimate council"**. An
ultimate-council runs BOTH witnesses — the UltraOracle (Step 4.5) AND the Mythos Witness; "ultra-council"
(Step 4.5) is UNCHANGED and runs the UltraOracle only.

To force it for that run, add `ULTIMATE_COUNCIL_FORCE=1` as a **plain, non-exported** assignment at the
very top of the single Step 4 dispatch Bash block (right beside `ULTRA_ORACLE_COUNCIL_FORCE=1` for an
ultimate-council), and `unset ULTIMATE_COUNCIL_FORCE` as its last line. Do NOT `export` it (it would
persist into a later council in a persistent shell), do NOT use a one-command `VAR=1 cmd` prefix (it
would not reach the gate), and do NOT wrap the dispatch in a subshell (the no-subshell rule in Step 4).
A **normal or ultra council omits that line entirely**; the gate's `:-0` default then leaves the Mythos
Witness off unless user-config enabled it. It is dispatched via the shared `scripts/ultimate-dispatch.sh`
helper (role slug `mythos-witness`), which pins `claude-fable-5` through the gateway and fails CLOSED
(loud warning + non-zero exit) when gateway creds are missing or the dispatch fails twice — inside that
SAME single-Bash dispatch block as the other voices (separate Bash calls serialize/cancel — see Step 4).

The Mythos Witness is **not** a vote: it is rendered as its own `## Mythos Witness — Expert Witness`
section (Step 5/Step 6), placed AFTER the UltraOracle section and BEFORE the Verdict, and is EXCLUDED
from the council vote tally — consensus, strongest dissent, and the recommendation are computed from the
five voices only. Its claims are treated as **unverified-until-checked** like the Researcher's (grep/Read/run
before any hard recommendation rests on them). On failure it renders a loud `MYTHOS_FAILED [status]`
banner — NEVER a silent omission.

**Trade-off (why it's off by default):** it is a second slow, metered gateway call on top of the
UltraOracle, so an ultimate-council runs minutes instead of seconds. As an expert witness it carries
weight only when its claims are evidence-backed. Never add it to the default roster.

**Data boundary:** the Mythos Witness transmits the council question + context to Claude Fable via the
zenmux gateway — metered API billing, not flat subscription. Gateway creds come from the same
`BLUEPRINT_ARBITER_GATEWAY_*` environment as the ultimate arbiter (never a committed file). Do not enable
where the question would carry secrets.

Launch wiring (inside the Step 4 dispatch Bash block, alongside the voices — background it so it runs
concurrently). `MYTHOS_ATTEMPTED` records that the witness ran (config-enabled OR forced) and drives the
render after `wait`:

```bash
MYTHOS_OUT=""; MYTHOS_STATUS=""; MYTHOS_ATTEMPTED=0
# Enabled via user config, OR forced for one run by an ultimate-council request
# (ULTIMATE_COUNCIL_FORCE=1, set+unset by the executor per this step — a normal council omits it).
if source "${PLUGIN_ROOT}/scripts/lib/ultimate-config.sh" 2>/dev/null \
   && [ "${BUSDRIVER_ULTIMATE:-}" != 0 ] \
   && { ultimate_surface_enabled council || [ "${ULTIMATE_COUNCIL_FORCE:-0}" = 1 ]; }; then
   # BUSDRIVER_ULTIMATE=0 is the operator's global force-OFF: it outranks the per-run
   # ULTIMATE_COUNCIL_FORCE escape hatch — a forced run must never bypass an explicit opt-out.
  MYTHOS_ATTEMPTED=1
  # Repo-root anchored (matches the helper's containment check) — running council from a
  # subdirectory must not create subdir/.claude/ultimate and then be rejected.
  _repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  _mythos_dir="$_repo_root/${BUSDRIVER_STATE_DIR:-.claude}/ultimate"
  mkdir -p "$_mythos_dir"
  MYTHOS_OUT="$(cd "$_mythos_dir" && pwd)/mythos-council-$$.md"   # absolute — the helper requires absolute paths
  # umask 077: the prompt carries council context — never world/group-readable, even briefly.
  _old_umask=$(umask); umask 077
  cat > "$MYTHOS_OUT.prompt" <<'MYTHOS_PROMPT'
<the council question + context — same text composed into the other voices' heredocs>
MYTHOS_PROMPT
  umask "$_old_umask"
  # Background so the gateway call overlaps the other voices; write an .rc marker on completion
  # (0 = verdict written, non-zero = fail-closed). Tracked in PIDS like every other council
  # job — do NOT disown: the Step 4 block's `wait "${PIDS[@]}"` must cover the witness, or the
  # render step can run before the .rc marker exists and misreport a successful dispatch as
  # MYTHOS_FAILED [timeout] while orphaning the gateway call.
  ( umask 077   # subshell-local: the verdict/output and rc marker carry council context too
    _mythos_rc=0
    # ULTIMATE_COUNCIL_FORCE is deliberately non-exported in the parent shell (see the
    # "plain, non-exported" instruction above), so `bash ultimate-dispatch.sh` as a NEW
    # child process would not inherit it and the child's own defense-in-depth gate would
    # reject an already-gate-passed forced run. Pass it narrowly via a per-command env
    # prefix — visible to this one child process only, never exported into the parent shell.
    ULTIMATE_COUNCIL_FORCE="${ULTIMATE_COUNCIL_FORCE:-0}" \
      bash "${PLUGIN_ROOT}/scripts/ultimate-dispatch.sh" mythos-witness \
      "$MYTHOS_OUT.prompt" "$MYTHOS_OUT" >/dev/null 2>&1 || _mythos_rc=$?
    rm -f "$MYTHOS_OUT.prompt"   # the witness prompt carries council context — don't leave it in the state dir
    # Atomic marker write; if even the fallback write fails the render step reads a
    # missing marker as timeout — documented as MYTHOS_FAILED [error] territory.
    { printf '%s\n' "$_mythos_rc" > "$MYTHOS_OUT.rc.tmp" && mv "$MYTHOS_OUT.rc.tmp" "$MYTHOS_OUT.rc"; } \
      || printf '%s\n' 1 > "$MYTHOS_OUT.rc" || true
    exit 0 ) &   # subshell always exits 0: `wait "${PIDS[@]}"` under set -e must not abort on a failed witness — the .rc marker carries the real status
  PIDS+=("$!")
  MYTHOS_STATUS=dispatched
elif [ "${ULTIMATE_COUNCIL_FORCE:-0}" = 1 ]; then
  MYTHOS_ATTEMPTED=1   # forced but the adapter failed to load / gate was false → render a loud banner below
fi
# ... existing PIDS dispatch + `wait "${PIDS[@]}"` ...
```

**Render (Step 5):** after `wait "${PIDS[@]}"`, in the same block. Render whenever the witness was
ATTEMPTED (config-enabled OR ultimate-council-forced) — never mid-dispatch, never as a voice:

```bash
if [ "$MYTHOS_ATTEMPTED" = 1 ]; then
  if [ "$MYTHOS_STATUS" = dispatched ]; then
    n=0; while [ ! -f "$MYTHOS_OUT.rc" ] && [ "$n" -lt "${BLUEPRINT_ARBITER_GATEWAY_TIMEOUT:-600}" ]; do sleep 2; n=$((n + 2)); done
    rc="$(cat "$MYTHOS_OUT.rc" 2>/dev/null)"
    if [ -s "$MYTHOS_OUT" ] && [ "$rc" = 0 ]; then
      cat "$MYTHOS_OUT"                                    # verdict text → place in the Mythos Witness section
    elif [ "$rc" = 3 ]; then
      echo "MYTHOS_FAILED [gateway-not-configured]"        # creds missing (helper exit 3)
    elif [ "$rc" = 0 ]; then
      echo "MYTHOS_FAILED [empty verdict]"                 # exited clean but wrote no verdict
    elif [ -n "$rc" ]; then
      echo "MYTHOS_FAILED [error rc=$rc]"                  # dispatched but failed closed (helper exit 1)
    else
      echo "MYTHOS_FAILED [timeout]"                       # launched, no .rc after the full wait
    fi
  else
    echo "MYTHOS_FAILED [${MYTHOS_STATUS:-adapter-unavailable}]"   # never launched: source failed / gate false
  fi
fi
```

**Rendering directive (binding):** In the Step 6 report, whenever the Mythos Witness was attempted, render
a SEPARATE top-level `## Mythos Witness — Expert Witness` section AFTER the `## UltraOracle — Expert Witness`
section and BEFORE `### Verdict`. On a verdict, place the `cat`'d text (reproduced faithfully — annotate
any ungrounded repo-specific claim as ungrounded); it is advisory and EXCLUDED from the vote tally, and
must NOT flip a hard recommendation without independent local evidence (grep/Read/run). On any
`MYTHOS_FAILED […]` token render a loud `## ⚠ MYTHOS_FAILED [<status>] — Mythos Witness verdict NOT included`
banner in that slot — never silently omit it. Never place the Mythos Witness in a voice slot or count it
toward consensus.

### Step 5: Read Output and Synthesize

Read the Fresh Claude output from the Agent tool result. Read the Agy/Codex/Grok output from the path printed by dispatch.sh to stderr (typically `${TMPDIR:-/tmp}/dispatch-{cli}-*.txt`; on macOS, TMPDIR is `/var/folders/...`, not `/tmp`). When the resolver falls back to Droid in the Researcher slot (grok unavailable), the output filename is `dispatch-droid-*.txt` and the report should attribute "Droid (Researcher, fallback)" rather than "Grok (Researcher)".

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
(Render this section whenever the Mythos Witness RAN — user-config `ultimate.surfaces.council` enabled OR ultimate-council forced; OMIT the entire section when it did not run. Place it AFTER the UltraOracle section and BEFORE the Verdict. It is Claude Fable via the zenmux gateway, NOT a voice, and is EXCLUDED from Consensus / Strongest dissent / Recommendation below.)
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
- `knowledge-ops` — persist durable decision deltas to the right location (vault)
- `search-first` — gather external reference material before convening
- `architecture-decision-records` — formalize the outcome when the decision becomes long-lived system policy
