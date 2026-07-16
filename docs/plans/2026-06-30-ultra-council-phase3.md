# ultra-council (ADR 0007 Phase 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use busdriver:subagent-driven-development (recommended) or busdriver:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the council skill render the UltraOracle verdict as a separate, labeled Expert Witness — out of the 5-voice vote tally — and let an ultra-council request force the escalation. Corrects the vote-#6 framing; runtime adherence is as strong as any council directive, not a code guarantee.

**Architecture:** Four edits to `skills/council/SKILL.md` (frontmatter trigger; Step 4.5 escalation contract; the oracle launch + render wiring inside council's single Step 4 dispatch block; the Step 6 report template), plus a thin command shim and one grep test. The five-voice PIDS dispatch (`&`-backgrounded voices + `wait "${PIDS[@]}"`, lines 86–116) and the `scripts/lib/ultra-oracle.sh` adapter are unchanged.

**Tech Stack:** Markdown skill/command files; Bash gate test under `tests/`; ShellCheck.

**Enforcement model (read first):** busdriver skills/shims are **markdown the executing agent follows**, not compiled code. So "force" and "render separately" are **binding directives to the executor**, as enforceable as any other council instruction — no more. The gate test asserts the directive *text* is present; that is the available guarantee. No code-level guarantee exists for a markdown skill, and a compiled wrapper would be over-engineering.

**Adapter contract (verified against `scripts/lib/ultra-oracle.sh`):** `ultra_oracle_consult --mode background` prints `dispatched` and returns 0 once the consult **launches**, then a backgrounded subshell writes `$out.rc` on completion (timeout → `rc=124`; exit-0-but-empty-verdict → `rc=1`; success → `rc=0`). The `skipped:user` / `skipped:unavailable` / `error` tokens are returned **earlier, before launch, with no `.rc`**. So the render must key off the **status token first**, then `.rc`.

**Global Constraints:**
- **No subshell.** `council/SKILL.md:121` forbids wrapping dispatches in `( … )` (it would strand the `PIDS` array so `wait` breaks). All edits stay in the existing single Step 4 dispatch block, at parent scope.
- **Force is a scoped, ultra-council-only directive.** The gate `ultra_oracle_surface_enabled council || [ "${ULTRA_ORACLE_COUNCIL_FORCE:-0}" = 1 ]` is unchanged. For an ultra-council request the executor sets `ULTRA_ORACLE_COUNCIL_FORCE=1` (a **plain, non-exported** assignment) at the top of that block and `unset`s it at the end. NOT `export` (persists into a later council), NOT a `VAR=1 cmd` prefix (never reaches the gate), NOT a subshell. A **normal council OMITS the force line**; the gate's `:-0` default then leaves the oracle off unless user-config enabled it.
- **Render keys on "attempted", not on the trigger.** A new `ULTRA_ORACLE_ATTEMPTED` flag is set whenever the oracle ran (user-config enabled OR ultra-council forced). The Expert Witness section (or its `ORACLE_FAILED` banner) is emitted in the **render phase** based on that flag — so a config-enabled *normal* council still renders, and a *forced-but-failed* run still renders a loud banner (settling-check #6), neither dropped nor printed mid-dispatch.
- **Security boundary preserved:** enablement stays user-config-only; repo/project config can NEVER set the force var. The `unset` means a forced run never leaves the var set for a later council in a persistent shell.
- No `sixth/6th … vote/voice` phrasing, no inert `: #` render placeholders, Step 6 template has its own Expert Witness slot.
- New shell test ShellCheck-clean, `tests/test-*.sh` pattern; literal assertions use `grep -F`. Edits driven by **textual anchors**, not line numbers.

---

## File Structure

- `tests/test-ultra-council.sh` — **create.**
- `skills/council/SKILL.md` — **modify (4 anchors):** frontmatter `description`; Step 4.5 heading+intro+trade-off; the oracle launch block + render block (inside the existing dispatch block); Step 6 report template.
- `commands/ultra-council.md` — **create.**

---

### Task 1: Failing gate test

**Files:** Test: `tests/test-ultra-council.sh` (create)

**Interfaces:** Consumes nothing (greps files); produces `bash tests/test-ultra-council.sh` exit 0 iff the contract holds.

- [ ] **Step 1: Write the failing test**

```bash
#!/bin/bash
# tests/test-ultra-council.sh — ADR 0007 Phase 3 contract for ultra-council.
# ponytail: static grep contract over the markdown skill — checks rendered directives/template,
# not a live council+oracle run (billed + browser, out of scope for CI). Anchors are headings/
# var-names chosen to stay stable across rewording. grep -F for literal metacharacters.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$DIR/skills/council/SKILL.md"
CMD="$DIR/commands/ultra-council.md"
FAIL=0

# (a) Oracle has its own labeled Expert Witness section.
grep -qF '## UltraOracle — Expert Witness [ORACLE_SUMMARY_REVIEW]' "$SKILL" \
  || { echo "FAIL: no labeled Expert Witness heading in council SKILL"; FAIL=1; }

# (b) Excluded from the vote tally (settling-check #1), in the contract and the Step 6 slot.
grep -qiE 'excluded from the .*vote tally' "$SKILL" \
  || { echo "FAIL: 'excluded from the vote tally' contract missing"; FAIL=1; }
grep -qF 'EXCLUDED from Consensus' "$SKILL" \
  || { echo "FAIL: Step 6 template lacks the exclusion note"; FAIL=1; }

# (c) Vote-#6 phrasing GONE from skill AND shim; no residual "...voice" slug; slug renamed.
if grep -nEi '(sixth|6th)[^.]*(vote|voice)|ultra-oracle voice' "$SKILL" "$CMD" 2>/dev/null; then
  echo "FAIL: vote-#6 phrasing present (skill or shim)"; FAIL=1
fi
if grep -qF 'ultra oracle council voice' "$SKILL"; then
  echo "FAIL: residual '--slug \"ultra oracle council voice\"' present"; FAIL=1
fi
grep -qF 'ultra oracle expert witness' "$SKILL" \
  || { echo "FAIL: dispatch --slug not renamed to the expert-witness label"; FAIL=1; }

# (d) Force is named, SCOPED (plain assignment + unset), never exported.
grep -qF 'ULTRA_ORACLE_COUNCIL_FORCE=1' "$SKILL" \
  || { echo "FAIL: no ULTRA_ORACLE_COUNCIL_FORCE=1 directive in council SKILL"; FAIL=1; }
if grep -qF 'export ULTRA_ORACLE_COUNCIL_FORCE' "$SKILL" || grep -qF 'export ULTRA_ORACLE_COUNCIL_FORCE' "$CMD"; then
  echo "FAIL: force var must be a scoped plain assignment, never exported"; FAIL=1
fi
grep -qF 'unset ULTRA_ORACLE_COUNCIL_FORCE' "$SKILL" \
  || { echo "FAIL: force var is not unset (would leak into a later council)"; FAIL=1; }

# (e) ATTEMPTED flag drives the render (so config-enabled + forced-but-failed both render).
grep -qF 'ULTRA_ORACLE_ATTEMPTED' "$SKILL" \
  || { echo "FAIL: no ULTRA_ORACLE_ATTEMPTED flag (render keys on it)"; FAIL=1; }

# (f) Loud failure banner survives (settling-check #6).
grep -qF 'ORACLE_FAILED' "$SKILL" \
  || { echo "FAIL: ORACLE_FAILED banner missing"; FAIL=1; }

# (g) Real render present (cat the verdict); no inert ': #' placeholders.
grep -qF 'cat "$ULTRA_ORACLE_OUT"' "$SKILL" \
  || { echo "FAIL: render branch does not cat the verdict (still inert?)"; FAIL=1; }
if grep -qF ': # include the verdict' "$SKILL"; then
  echo "FAIL: inert ': #' render placeholder still present"; FAIL=1
fi

# (h) Trigger routes to council; shim exists, references council + the force directive.
grep -qi 'ultra-council' "$SKILL"            || { echo "FAIL: no ultra-council trigger in council SKILL"; FAIL=1; }
[ -f "$CMD" ]                                || { echo "FAIL: commands/ultra-council.md missing"; FAIL=1; }
grep -qi 'council' "$CMD" 2>/dev/null        || { echo "FAIL: shim does not reference council"; FAIL=1; }
grep -qF 'ULTRA_ORACLE_COUNCIL_FORCE=1' "$CMD" 2>/dev/null \
  || { echo "FAIL: shim does not name the force directive"; FAIL=1; }

if [ "$FAIL" -eq 0 ]; then echo "PASS test-ultra-council"; else echo "test-ultra-council FAILED"; fi
exit "$FAIL"
```

- [ ] **Step 2: Run to verify it fails** — `chmod +x tests/test-ultra-council.sh && bash tests/test-ultra-council.sh` → FAIL, non-zero exit (heading/slug/shim/ATTEMPTED absent).

---

### Task 2: Council edits

**Files:** Modify `skills/council/SKILL.md` (4 textual anchors).

- [ ] **Step 1: Add the routing trigger to the frontmatter `description`**

Edit — find:

```
  "what would others think", "group wisdom", "diverse viewpoints", "what do you all think",
  or needs group deliberation on decisions, tradeoffs, design choices, architecture,
  or strategy. NOT for simple tasks with clear answers — only for ambiguous problems
  that benefit from multiple lenses.
```

Replace with:

```
  "what would others think", "group wisdom", "diverse viewpoints", "what do you all think",
  or needs group deliberation on decisions, tradeoffs, design choices, architecture,
  or strategy. Also triggers on "ultra-council" / "ultra council" — the same council plus
  a forced UltraOracle expert-witness escalation (rendered separately, never a vote).
  NOT for simple tasks with clear answers — only for ambiguous problems
  that benefit from multiple lenses.
```

- [ ] **Step 2: Rewrite the Step 4.5 heading + intro + trade-off**

Edit — find (verbatim):

```
### Step 4.5: Optional Ultra-Oracle Voice (opt-in, off by default)

A 6th GPT-5.5 Pro "ultra-oracle" voice can be added ONLY when `ultraOracle.council.enabled` is true in the operator's **USER config** `~/.claude/busdriver.json` (a repo-controlled project config CANNOT enable it — security), OR the user explicitly asks (in which case export `ULTRA_ORACLE_COUNCIL_FORCE=1` for that run, as the snippet below honors). It is dispatched via the shared `ultra_oracle_consult` adapter (the `oracle` CLI's ChatGPT Pro browser engine), inside the SAME single-Bash dispatch block as the other voices (separate Bash calls serialize/cancel — see Step 4).

**Trade-off (why it's off by default):** a single slow Pro voice both dilutes council's diversity (one vote, outvoteable) and makes every council it joins run minutes instead of seconds. Never add it to the default roster.
```

Replace with:

```
### Step 4.5: Optional UltraOracle Expert Witness ("ultra-council", off by default)

An UltraOracle (GPT-5.5 Pro) **expert witness** can be escalated ONLY when `ultraOracle.council.enabled` is true in the operator's **USER config** `~/.claude/busdriver.json` (a repo-controlled project config CANNOT enable it — security), OR the user explicitly invokes **"ultra-council" / "ultra council"** (or asks to include the oracle). On an ultra-council request, set `ULTRA_ORACLE_COUNCIL_FORCE=1` as a plain (non-exported) assignment at the top of council's single Step 4 dispatch Bash block, and `unset ULTRA_ORACLE_COUNCIL_FORCE` at the end of it — NOT a subshell (line 121 forbids it; it would strand `PIDS`), NOT `export` (it would persist into a later council), NOT a `VAR=1 cmd` prefix (it would not reach the gate). A normal council OMITS that line; the gate's `:-0` default leaves the oracle off unless user-config enabled it. It is dispatched via the shared `ultra_oracle_consult` adapter (the `oracle` CLI's ChatGPT Pro browser engine), inside that same dispatch block as the other voices (separate Bash calls serialize/cancel — see Step 4).

UltraOracle is **not** a vote: it is rendered as its own Expert Witness section (Step 5/Step 6) and is EXCLUDED from the council vote tally — consensus, strongest dissent, and the recommendation are computed from the five voices only (ADR 0007 settling-check #1). The consult attaches no evidence-pack files (it sends only the prompt text — a Claude-authored question + context), so its result is labeled `ORACLE_SUMMARY_REVIEW` per the ADR review-type table (a Claude-authored summary, not a repo-attached review) even if that prompt text quotes snippets; a repo-specific claim with no file/path evidence is ungrounded — say so.

**Trade-off (why it's off by default):** a single slow Pro consult makes every council it joins run minutes instead of seconds, and as an expert witness it carries weight only when its claims are evidence-backed. Never add it to the default roster.
```

- [ ] **Step 3: Replace the oracle launch block and the render block**

The oracle wiring lives in council's single Step 4 dispatch block in two places: the **launch** (before the five-voice PIDS dispatch) and the **render** (after `wait "${PIDS[@]}"`). Replace both. No subshell; no force line baked in (Step 2's directive adds it only for ultra-council). The `ULTRA_ORACLE_ATTEMPTED` flag drives the render.

3a. Replace the launch block — find (verbatim):

```bash
ULTRA_ORACLE_OUT=""; ULTRA_ORACLE_STATUS=""
# Enabled via config, OR forced for one run on explicit user request (ULTRA_ORACLE_COUNCIL_FORCE=1).
if source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/ultra-oracle.sh" 2>/dev/null \
   && { ultra_oracle_surface_enabled council || [ "${ULTRA_ORACLE_COUNCIL_FORCE:-0}" = 1 ]; }; then
  ULTRA_ORACLE_OUT="${BUSDRIVER_STATE_DIR:-.claude}/ultra-oracle/council-$$.md"
  mkdir -p "${BUSDRIVER_STATE_DIR:-.claude}/ultra-oracle"
  cat > "$ULTRA_ORACLE_OUT.prompt" <<'ULTRA_ORACLE_PROMPT'
<the council question + context — same text composed into the other voices' heredocs>
ULTRA_ORACLE_PROMPT
  ULTRA_ORACLE_STATUS="$(ultra_oracle_consult --mode background --slug "ultra oracle council voice" \
    --out "$ULTRA_ORACLE_OUT" --prompt-file "$ULTRA_ORACLE_OUT.prompt" 2>/dev/null || true)"
fi
```

Replace with:

```bash
ULTRA_ORACLE_OUT=""; ULTRA_ORACLE_STATUS=""; ULTRA_ORACLE_ATTEMPTED=0
# Enabled via user config, OR forced for one run by an ultra-council request
# (ULTRA_ORACLE_COUNCIL_FORCE=1, set+unset by the executor per Step 4.5 — a normal council omits it).
# ATTEMPTED is set whenever the oracle ran, and drives the render after `wait` below.
if source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/ultra-oracle.sh" 2>/dev/null \
   && { ultra_oracle_surface_enabled council || [ "${ULTRA_ORACLE_COUNCIL_FORCE:-0}" = 1 ]; }; then
  ULTRA_ORACLE_ATTEMPTED=1
  ULTRA_ORACLE_OUT="${BUSDRIVER_STATE_DIR:-.claude}/ultra-oracle/council-$$.md"
  mkdir -p "${BUSDRIVER_STATE_DIR:-.claude}/ultra-oracle"
  cat > "$ULTRA_ORACLE_OUT.prompt" <<'ULTRA_ORACLE_PROMPT'
<the council question + context — same text composed into the other voices' heredocs>
ULTRA_ORACLE_PROMPT
  ULTRA_ORACLE_STATUS="$(ultra_oracle_consult --mode background --slug "ultra oracle expert witness" \
    --out "$ULTRA_ORACLE_OUT" --prompt-file "$ULTRA_ORACLE_OUT.prompt" 2>/dev/null || true)"
elif [ "${ULTRA_ORACLE_COUNCIL_FORCE:-0}" = 1 ]; then
  ULTRA_ORACLE_ATTEMPTED=1   # forced but adapter failed to load / gate false → render a loud banner below
fi
```

3b. Replace the render block — find (verbatim):

```
**Synthesis (Step 5):** ONLY when the voice was actually attempted (`$ULTRA_ORACLE_OUT` non-empty). A disabled council leaves it empty and skips this block entirely — no banner. Note `--mode background` returns `dispatched` on a *successful launch*; whether a verdict was produced is decided by the `.rc` + verdict file, NOT the status token:

```bash
if [ -n "$ULTRA_ORACLE_OUT" ]; then   # voice was attempted (enabled)
  if [ "$ULTRA_ORACLE_STATUS" = dispatched ]; then
    n=0; while [ ! -f "$ULTRA_ORACLE_OUT.rc" ] && [ "$n" -lt "$(ultra_oracle_timeout_cap)" ]; do sleep 2; n=$((n + 2)); done
  fi
  if [ -s "$ULTRA_ORACLE_OUT" ] && [ "$(cat "$ULTRA_ORACLE_OUT.rc" 2>/dev/null)" = 0 ]; then
    : # include the verdict as the ultra-oracle voice in synthesis
  else
    : # render "WARNING: ULTRA-ORACLE VOICE FAILED [$ULTRA_ORACLE_STATUS] — verdict NOT included" prominently
  fi
fi
```
```

Replace with:

```
**Synthesis (Step 5):** runs after `wait "${PIDS[@]}"`, in the same block. Grades the oracle outcome and renders it whenever the escalation was ATTEMPTED (user-config enabled OR ultra-council forced) — never mid-dispatch, never folded into a voice. Status-first (the adapter writes `.rc` only once `dispatched`; `skipped:*`/`error` never launched and have no `.rc`). The directive after the block does the rendering:

```bash
if [ "$ULTRA_ORACLE_ATTEMPTED" = 1 ]; then
  if [ "$ULTRA_ORACLE_STATUS" = dispatched ]; then
    n=0; while [ ! -f "$ULTRA_ORACLE_OUT.rc" ] && [ "$n" -lt "$(ultra_oracle_timeout_cap)" ]; do sleep 2; n=$((n + 2)); done
    rc="$(cat "$ULTRA_ORACLE_OUT.rc" 2>/dev/null)"
    if [ -s "$ULTRA_ORACLE_OUT" ] && [ "$rc" = 0 ]; then
      cat "$ULTRA_ORACLE_OUT"                                 # verdict → Expert Witness section
    elif [ "$rc" = 124 ]; then
      echo "ORACLE_FAILED [timeout]"
    elif [ -n "$rc" ]; then
      echo "ORACLE_FAILED [error rc=$rc]"
    else
      echo "ORACLE_FAILED [timeout]"                          # launched, no .rc after full wait → timed out
    fi
  else
    echo "ORACLE_FAILED [${ULTRA_ORACLE_STATUS:-adapter-unavailable}]"   # never launched: skipped:* / error / source failed
  fi
fi
```

**Rendering directive (binding):** In the Step 6 report, whenever the oracle was attempted, render a SEPARATE top-level `## UltraOracle — Expert Witness [ORACLE_SUMMARY_REVIEW]` section AFTER the five voice blocks and BEFORE `### Verdict`. On a verdict, place the `cat`'d text (reproduced faithfully — annotate any ungrounded repo-specific claim as ungrounded); it is advisory and EXCLUDED from the vote tally, and must NOT flip a hard recommendation without independent local evidence (grep/Read/run). On any `ORACLE_FAILED […]` token render a loud `## WARNING: ORACLE_FAILED [<status>] — UltraOracle Expert Witness verdict NOT included` banner in that slot — never silently omit it (ADR 0007 settling-check #6). Never place UltraOracle in a voice slot or count it toward consensus.
```

- [ ] **Step 4: Add the Expert Witness slot to the Step 6 report template**

Edit — find (verbatim):

```
**Grok (Researcher):** [position in 1-2 sentences]
[1-line key reasoning + key evidence cited]
(If grok was unavailable and Droid handled the slot, use **Droid (Researcher, fallback):** instead.)

### Verdict
```

Replace with:

```
**Grok (Researcher):** [position in 1-2 sentences]
[1-line key reasoning + key evidence cited]
(If grok was unavailable and Droid handled the slot, use **Droid (Researcher, fallback):** instead.)

## UltraOracle — Expert Witness [ORACLE_SUMMARY_REVIEW]
(Render this whenever the UltraOracle escalation RAN — user-config enabled OR ultra-council forced; OMIT the entire section when the oracle did not run. It is NOT a voice and is EXCLUDED from Consensus / Strongest dissent / Recommendation below.)
[the verdict text, reproduced faithfully — annotate any ungrounded repo-specific claim as ungrounded]
(On failure render instead: **WARNING: ORACLE_FAILED [status] — UltraOracle Expert Witness verdict NOT included**.)

### Verdict
```

---

### Task 3: Command shim

**Files:** Create `commands/ultra-council.md`.

- [ ] **Step 1: Create the shim**

```markdown
---
description: Convene the council with a forced UltraOracle (GPT-5.5 Pro) expert-witness escalation — the 5 voices plus a separately-rendered Expert Witness, never a vote.
---

# Ultra-Council

Invoke the `council` skill in **ultra-council** mode: run the normal 5-voice council and force the
UltraOracle escalation by setting `ULTRA_ORACLE_COUNCIL_FORCE=1` (a plain, non-exported assignment)
at the top of council's single Step 4 dispatch Bash block and `unset`-ting it at the end — never a
subshell, never `export`, never a `VAR=1 cmd` prefix (a trigger phrase alone sets no env var). The
GPT-5.5 Pro verdict is rendered as a SEPARATE `UltraOracle — Expert Witness [ORACLE_SUMMARY_REVIEW]`
section, after the five voices and before the Verdict, and is EXCLUDED from the vote tally (ADR 0007
Phase 3).

Oracle is an advisory expert witness, not a vote and not a gate; a repo-specific claim with no
file/path evidence is ungrounded. On timeout/empty it renders a loud `ORACLE_FAILED` banner, never a
silent omission.

Enablement is user-config only (`~/.claude/busdriver.json` → `ultraOracle.council.enabled`);
`ULTRA_ORACLE_COUNCIL_FORCE=1` is set only by an interactive ultra-council request, never by
repo/project config. See `skills/council/SKILL.md` Step 4.5.
```

---

### Task 4: Verify + commit

- [ ] **Step 1:** `bash tests/test-ultra-council.sh` → `PASS test-ultra-council`, exit 0.
- [ ] **Step 2:** `shellcheck tests/test-ultra-council.sh` → clean.
- [ ] **Step 3:** `bash tests/test-ultra-oracle.sh` → prior pass behavior (adapter untouched).
- [ ] **Step 4: Commit**

```bash
git add skills/council/SKILL.md commands/ultra-council.md tests/test-ultra-council.sh
git commit -m "feat(ultra-council): render UltraOracle as separate expert witness (ADR 0007 phase 3)"
```

---

## Acceptance (ADR Phase 3 + settling checks)
- [ ] Normal council unchanged: PIDS dispatch + adapter untouched; force line omitted; only the `--slug`, the `ATTEMPTED` flag, the `elif`, and the `.rc`-status render differ in the shared oracle wiring.
- [ ] `ultra-council` sets the scoped `ULTRA_ORACLE_COUNCIL_FORCE=1` (plain, no subshell, no export) + `unset` at block end — a binding directive (test asserts presence).
- [ ] Oracle rendered as a separate labeled Expert Witness, EXCLUDED from the vote tally (settling-check #1), in the Step 5 directive and the Step 6 template.
- [ ] Render fires whenever the oracle ran (config-enabled OR forced), keyed on `ULTRA_ORACLE_ATTEMPTED` — never dropped, never mid-dispatch.
- [ ] Summary-only consult labeled `ORACLE_SUMMARY_REVIEW` (settling-check #2).
- [ ] Failure renders loud `ORACLE_FAILED` with the correct status (`timeout` on rc=124, `error rc=N`, or the `skipped:*` token) — never the launch token `dispatched` (settling-check #6).
- [ ] No inert `: #`; no `sixth/6th … vote/voice`; no residual `--slug "…voice"`; no `export` of the force var.
- [ ] `tests/test-ultra-council.sh` passes; ShellCheck clean; adapter test green.
