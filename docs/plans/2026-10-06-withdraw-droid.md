# Withdraw the droid CLI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use busdriver:subagent-driven-development (recommended) or busdriver:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove `droid` from busdriver completely: it stops being a review CLI, a route fallback, a runtime escalation target, and a dispatch lane.

**Architecture:** droid is uninstalled on both operator hosts (Mac and um; `command -v droid` returns nothing on either, checked 2026-10-06), so none of the code below can run today. This is a removal; no new mechanism is added. A stale `droid` in a config or env var is handled by the existing removed-CLI path that already covers `amp|claude|aider|opencode`: it warns, skips the entry, and keeps the route's next entry working. Every "codex → droid → builtin" chain becomes "codex → builtin". Every "failed reviewer → droid rescue" becomes "failed reviewer stays failed", which the #355 degraded-coverage path already blocks fail-closed.

**Tech Stack:** bash (gate and resolver scripts), python3 (blueprint JSON extractor and its pytest), Markdown docs, JSON config.

**Global Constraints:**
- **Removal only.** Do not add a replacement fallback CLI, a new env var, or a new flag.
- **Stale `droid` input** is treated exactly like `opencode` (ADR 0051): warn and skip it in route arrays, `unsupported:droid` from `BUSDRIVER_REVIEW_CLI`, and skip it in `defaults.primary`/`defaults.fallback`. Same message text, with `droid` removed from the "use … instead" list.
- **Fail-closed behaviour must not loosen.**
  - Litmus commit mode: a failed Codex still ends in `BUILTIN_FALLBACK` (exit 3) or exit 124.
  - Litmus PR mode: still rejects a non-codex lead.
  - Blueprint: a failed reviewer slot stays `runtime-failed`, and the PASS is withheld (#355).
- **Orphans created by the removal are removed too.** If a variable, comment or sidecar file existed only to serve droid, delete it. Do not touch unrelated code.
- **Historical documents stay as they are:** ADRs other than the amendment lines below, `docs/plans/**`, `docs/plan-history/**`, `docs/plan-status/**`, `CHANGELOG.md`.
- **Not droid:** `Android` (in `agents/a11y-architect.md` and `package-lock.json`) is a substring match. Leave it.
- **Commits:** at most 8 staged files per commit (the litmus split threshold). Each commit leaves the test suite green, and that is verified, not assumed: **before every commit, `bash scripts/ci/run-shell-tests.sh` must exit 0** in addition to the task's focused run. Several suites source or grep `resolve-cli.sh` and `dispatch.sh` by exact text (e.g. `tests/test-no-auditor-lane.sh`), so a focused subset cannot prove the rest stays green.
- **No edits** under `hooks/gate-scripts/**` or `scripts/hooks/**`, so the gate-integrity lock is untouched. Verify with `./scripts/gate-integrity.sh --check`.

---

## File Structure

| File | Change |
|---|---|
| `scripts/lib/resolve-cli.sh` | Delete the droid arm, `should_escalate_to_droid`, `_classify_droid_escalation_outcome` and the codex→droid escalation. Add `droid` to the removed-CLI set at its 6 sites. Drop droid from the allowlists, the auto lists and the per-role legacy defaults. Remove the orphans `_ECX_LAST_WAS_TRANSIENT`, `_ECX_DURATION_CFG` and `_ECX_FAIL_REASON`. |
| `skills/dispatch-cli/scripts/dispatch.sh` | Delete the `droid)` arm, the runtime droid escalation block, the `droid-fallback` status, and droid from the usage/validator/auto/`all`/whitelist lists. Lower the `--cli all` cap from 5 to 4. |
| `skills/blueprint-review/scripts/run-design-review-loop.sh` | Delete `_bp_droid_rescue`, the Phase 1 rescue loop, the `LITMUS_CODEX_DROID_FALLBACK_DISABLED` export and the `.salvaged` sidecar. The `runtime-droid-rescue` coverage branch becomes a legacy-artifact guard that maps to `runtime-failed`. |
| `skills/blueprint-review/scripts/lib/extract_review_json.py`, its two `test_*.py`, `prompts/claude_validation_prompt.txt` | Reword the droid mentions. |
| `skills/litmus/scripts/run-review-loop.sh`, `lib/validation.sh`, `write-review-marker.sh`, `scripts/dispatcher-commit-block.sh` | Remove the PR-mode droid-disable export, and remove droid from the messages and comments. |
| `tests/test-droid-escalation.sh`, `tests/test-droid-escalation-outcome.sh` | Delete. |
| `tests/test-review-boundaries.sh` | Swap the droid fixtures for agy in §7/§8 (not codex — see Task 2 Step 14). Add §9 "droid is a removed CLI". |
| 16 other `tests/*.sh` | Delete droid-only sections and drop droid stubs, env flags and regex alternatives. |
| `.claude/busdriver.json`, `docs/examples/busdriver.json` | Drop `"droid"` from every route. |
| README, `docs/degraded-modes.md`, `docs/observability.md`, 7 `skills/*/SKILL.md` / reference docs, `scripts/ci/shell-test-durations.tsv`, `docs/ci/shell-test-inventory.md`, `.github/workflows/tests.yml` | Update the prose. |
| `docs/adr/0053-withdraw-droid.md` (new), `docs/adr/0006-*.md`, `docs/adr/0034-*.md` | New decision record, plus a one-line amendment in each of the other two. |

---

### Task 1: Remove droid-only tests (harmless against the current code)

**Files:**
- Delete: `tests/test-droid-escalation.sh`, `tests/test-droid-escalation-outcome.sh`
- Modify: `tests/test-grok-sandbox-arm.sh`, `tests/test-trusted-review-cli.sh`, `tests/test-litmus-mode-transition.sh`, `tests/test-cli-retry.sh`, `scripts/ci/shell-test-durations.tsv`

**Interfaces:** Consumes nothing. Produces a suite that no longer references `should_escalate_to_droid`, `_classify_droid_escalation_outcome` or `_bp_droid_rescue` from these files.

- [ ] **Step 1: Delete the two droid test files.**

```bash
git rm tests/test-droid-escalation.sh tests/test-droid-escalation-outcome.sh
```

- [ ] **Step 2: Drop their duration rows.** In `scripts/ci/shell-test-durations.tsv`, delete the two lines whose first field is exactly `test-droid-escalation-outcome` and `test-droid-escalation`. The file is not sorted; do not reorder anything else.

```bash
t=$(mktemp) \
  && awk -F'\t' '$1 != "test-droid-escalation" && $1 != "test-droid-escalation-outcome"' scripts/ci/shell-test-durations.tsv > "$t" \
  && mv "$t" scripts/ci/shell-test-durations.tsv
grep -c droid scripts/ci/shell-test-durations.tsv   # expect 0
```

- [ ] **Step 3: `tests/test-grok-sandbox-arm.sh`.** Delete the five structural checks that grep for removed functions (line numbers as of `main` 5e377d26):
  - `:1315-1320` — `dispatch.sh` tests `_grok_refused` before `should_escalate_to_droid`;
  - `:1410-1415` and `:1419-1422` — `should_escalate_to_droid` in `resolve-cli.sh` excludes grok by name, and does so without text detection;
  - `:1437-1440` and `:1443-1446` — the same two checks for `_bp_droid_rescue`.

  Locate each with `grep -n 'should_escalate_to_droid\|_bp_droid_rescue' tests/test-grok-sandbox-arm.sh` and remove every line from its section's leading comment (if it has one) to its closing `fi`. The first check (`:1315-1321`) has no leading comment: delete from `_esc="$(/usr/bin/awk '/&& type should_escalate_to_droid/…` through the `fi` after `fail "the droid-escalation guard does not exclude _grok_refused…"`. Then reword every remaining droid mention, including the fail/pass message strings (`:1097`, `:1108`, `:1310`, `:1371`), not only the comments. Find them with `grep -n -i droid tests/test-grok-sandbox-arm.sh`; a typical rewrite is "must not fall through to the droid rescue" → "fails instead of being re-sent to another provider". Afterwards `grep -n -i droid tests/test-grok-sandbox-arm.sh` must print nothing.

- [ ] **Step 4: `tests/test-trusted-review-cli.sh`.** Delete:
  - tests 20, 21 and 22: the `#803` blocks headed `# 20) #803: execute_review droid arm…`, `# 21) #803: should_escalate_to_droid…` and `# 22) #803: clean should_escalate_to_droid…`;
  - the `DROID_EXT` fixture (the `DROID_EXT=$(mktemp -d …)` line and the `printf … REAL_DROID … > "$DROID_EXT/droid"` line, plus its `chmod` and cleanup if present). Only test 22 uses it.
  - and reword the comment at `:1234`: `bare timed codex/agy/droid pin argv0` → `bare timed codex/agy pin argv0`.

  Confirm with `grep -n -i droid tests/test-trusted-review-cli.sh`, which must print nothing.

- [ ] **Step 4b: `tests/test-litmus-mode-transition.sh`.** The stub/chmod pair occurs four times (`:486/487`, `:605/606`, `:1007/1008`, `:1798/1799`). At all four, delete the stub line `printf '#!/bin/sh\nexit 0\n' > "$S.bin/droid"` and change `chmod +x "$S.bin/codex" "$S.bin/droid"` to `chmod +x "$S.bin/codex"`. droid is never reached here because each site pins `BUSDRIVER_REVIEW_CLI=codex`, which disables the codex→droid escalation inside `_execute_codex`; this is fixture cleanup only. Afterwards `grep -n droid tests/test-litmus-mode-transition.sh` must print nothing.

- [ ] **Step 4c: `tests/test-cli-retry.sh` — the four rescue-asserting sections.** This must happen in THIS commit, not with the rest of the dispatch work in Task 3: Task 2 deletes `should_escalate_to_droid`, which turns `dispatch.sh`'s `type should_escalate_to_droid` guard false, so the rescue stops firing from Task 2's commit onward and any assertion that it fires would fail there.
  - **C2 and C3: rewrite, do not delete.** They are the only checks that `BUSDRIVER_CLI_RETRIES=0` makes exactly one attempt and that a timeout (124) is not retried, and neither property depends on droid. In each, drop only the ` && grep -q DROID_RESCUE "$O"` clause, keeping the `[[ "$(cat "$C")" == 1 ]]` attempt-count check. Messages and comments: C2 `RETRIES=0 → one attempt then droid fallback` → `RETRIES=0 → exactly one attempt`, comment `# C2: RETRIES=0 disables retry → single failing attempt → droid fallback fires` → `# C2: RETRIES=0 disables retry → single failing attempt`; C3 `council timeout(124) → no retry, droid fallback` → `council timeout(124) → no retry`, comment `# C3: timeout (124) → not retried, droid fallback fires` → `# C3: timeout (124) → not retried`. Keep the `(inv=…, out=…)` diagnostic in the failure messages.
  - **C7 and C8: delete.** They assert `droid rescue also failed`, which is the rescue itself.
  - Against the current code all of this is harmless: C2/C3 only lose a clause, C7/C8 only disappear. The remaining droid references in this file (the C1 stub and the `! grep -q DROID_RESCUE` clauses in C1/C4/C5) still pass after Task 2 and are cleaned in Task 3 Step 9.

- [ ] **Step 5: Run the touched tests.**

Run: `bash tests/test-grok-sandbox-arm.sh && bash tests/test-trusted-review-cli.sh && bash tests/test-litmus-mode-transition.sh && bash tests/test-cli-retry.sh`
Expected: all PASS (they only lost assertions or an unused stub).

- [ ] **Step 6: Commit** (7 paths). Before committing, `bash scripts/ci/run-shell-tests.sh` must exit 0.

```bash
git add tests/test-grok-sandbox-arm.sh tests/test-trusted-review-cli.sh tests/test-litmus-mode-transition.sh tests/test-cli-retry.sh scripts/ci/shell-test-durations.tsv
git commit -m "test: drop droid-escalation tests ahead of the droid withdrawal"
```

(The two deletions are already staged by `git rm`.)

---

### Task 2: Resolver and litmus — droid becomes a removed CLI

**Files:**
- Modify: `scripts/lib/resolve-cli.sh`, `skills/litmus/scripts/run-review-loop.sh`, `skills/litmus/scripts/lib/validation.sh`, `skills/litmus/scripts/write-review-marker.sh`, `scripts/dispatcher-commit-block.sh`, `tests/test-review-boundaries.sh`, `tests/test-no-auditor-lane.sh` (commit A); `tests/test-codex-retry-budget.sh`, `tests/test-pr-excluded-only-autopass.sh` (commit B)

**Interfaces:**
- Produces the following behaviour:
  - `resolve_role_cli <role>` never prints `droid`.
  - `BUSDRIVER_REVIEW_CLI=droid` → `unsupported:droid`.
  - A route entry `droid` is skipped with a warning.
  - `describe_role_resolution` no longer emits the reason `resolve-droid-fallback`.
  - `_execute_codex` on failure prints `BUILTIN_FALLBACK` and exits 3, or exits 124 on a genuine timeout.
- Removes these functions: `should_escalate_to_droid`, `_classify_droid_escalation_outcome`.
- Removes these env vars: `LITMUS_CODEX_DROID_FALLBACK_DISABLED`, `LITMUS_CODEX_DROID_FALLBACK`.

- [ ] **Step 1: Add droid to the removed-CLI set** in `scripts/lib/resolve-cli.sh`, at all six sites. Each one currently lists `opencode` as the last removed name.
  - **Route walker** (`_resolve_from_route_array`): `elif [[ "$cli" == "amp" || "$cli" == "claude" || "$cli" == "aider" || "$cli" == "opencode" ]]; then` → append ` || "$cli" == "droid"` inside the brackets.
  - **Env override** (`_resolve_role_cli_impl` Step 1): `amp|claude|aider|opencode)` → `amp|claude|aider|opencode|droid)`.
  - **`defaults.primary`**: append ` || "$default_primary" == "droid"`.
  - **`defaults.fallback`**: append ` || "$default_fallback" == "droid"`.
  - **`describe_role_resolution` route scan**: `gemini|amp|claude|aider|opencode)` → `gemini|amp|claude|aider|opencode|droid)`.
  - **`describe_role_resolution` defaults scan**: `if [[ "$cli" != "opencode" ]]; then` → `if [[ "$cli" != "opencode" && "$cli" != "droid" ]]; then`, and `if [[ -n "$cli" && "$cli" != "opencode" ]]; then` → `if [[ -n "$cli" && "$cli" != "opencode" && "$cli" != "droid" ]]; then`.

- [ ] **Step 2: Fix the migration messages.**
  - Every `use 'codex', 'agy', 'droid', or 'grok' instead` becomes `use 'codex', 'agy', or 'grok' instead`. There are four.
  - `execute_review`'s `unsupported:*` arm: `use codex, agy, droid, or grok` → `use codex, agy, or grok`.
  - Line 16 header: `# Values: auto (default) | codex | agy | droid | grok | builtin | none` → drop `droid | `.
  - The route-walker comments that use droid as an example (`["gemini", "droid"] route gracefully degrades to droid` and `a stale ["codex", "amp", "droid"] route`) become `["gemini", "codex"] route gracefully degrades to codex` and `a stale ["codex", "amp", "agy"] route`.
  - The Step-4 comment `{"defaults":{"fallback":"droid"}}` → `{"defaults":{"fallback":"codex"}}`.

- [ ] **Step 3: Remove droid from the allowlists and auto lists.**
  - `is_trusted_review_cli_available`: `codex|agy|droid|node)` → `codex|agy|node)`.
  - `get_cli_install_hint`: delete the line `    droid)  echo "See https://droid.dev" ;;`.
  - `_portable_timeout`, three case patterns: `codex|agy|droid|node) ;;` → `codex|agy|node) ;;`; `codex|agy|droid)` → `codex|agy)`; `codex|agy|droid|node)` → `codex|agy|node)`. Remove `droid|` from its two error strings too (`requires codex|agy|droid|node` → `requires codex|agy|node`).
  - `_run_review_with_retries`, two case arms: `codex|agy|droid)` → `codex|agy)`.
  - Three auto loops: `for auto_cli in codex agy droid; do` → `for auto_cli in codex agy; do`, and both `for cli in codex agy droid; do` → `for cli in codex agy; do`.
  - Direct-execution `--json` block: `codex|agy|droid|grok)` → `codex|agy|grok)`, and `for cli in codex agy droid grok; do` → `for cli in codex agy grok; do`.

- [ ] **Step 4: Per-role legacy defaults (Step 4b).** Replace the block from the `# reviewer_3 (grok) added 2026-05-26` comment through the `council.researcher` arm with the following. `reviewer_1`, `reviewer_2` and the `arbiter` lines above and inside it stay as they are.

```bash
    # reviewer_3 (grok) added 2026-05-26: adds xAI lineage to blueprint-review.
    # No fallback CLI (droid was withdrawn, ADR 0053): a missing grok resolves to
    # none and the slot is recorded unfulfilled — the coverage gate withholds PASS.
    blueprint-review.reviewer_3) is_trusted_review_cli_available grok  && /usr/bin/printf '%s\n' "grok"  && return
                                 /usr/bin/printf '%s\n' "none" && return ;;
    blueprint-review.arbiter)    echo "builtin" && return ;;  # arbiter is always Claude
    # No fallback CLI (ADR 0053): when the role's CLI is missing the voice drops
    # and council records it (unavailable). Configure a route to pick another CLI.
    council.pragmatist)         is_trusted_review_cli_available agy   && /usr/bin/printf '%s\n' "agy"   && return
                                /usr/bin/printf '%s\n' "none" && return ;;
    council.critic)             is_trusted_review_cli_available codex && /usr/bin/printf '%s\n' "codex" && return
                                /usr/bin/printf '%s\n' "none" && return ;;
    # Grok was promoted to Researcher primary on 2026-05-26 (xAI lineage, cited
    # external evidence). No fallback CLI since ADR 0053.
    council.researcher)         is_trusted_review_cli_available grok  && /usr/bin/printf '%s\n' "grok"  && return
                                /usr/bin/printf '%s\n' "none" && return ;;
```

- [ ] **Step 5: `describe_role_resolution`.**
  - Delete the two-line `droid)` case arm: the arm line and its `if [[ "$requested" == "droid" ]]; then reason="ok"; else reason="resolve-droid-fallback"; fi ;;` line.
  - Change the header comment `# reason ∈ ok | resolve-droid-fallback | builtin | missing-cli | unsupported-cli | explicit-none` to `# reason ∈ ok | builtin | missing-cli | unsupported-cli | explicit-none`.

- [ ] **Step 6: Delete the escalation functions.** Remove everything from the line `should_escalate_to_droid() {` through the closing `}` of `_classify_droid_escalation_outcome()`. That includes the leading comment block of each function: the `# Classify a droid escalation attempt…` comment and any comment block directly above `should_escalate_to_droid`. The call site inside `_execute_codex` (`:3792`) stays until Step 7 replaces that block; the empty-grep confirmation is at the end of Step 7.

- [ ] **Step 7: Replace the codex→droid escalation in `_execute_codex`.** Inside `if [[ "$_ECX_EXIT_CODE" -ne 0 ]]; then`, keep `_ECX_ATTEMPTS_RUN=…` and the stderr-surfacing `printf` exactly as they are. Replace everything from the comment `# Droid escalation: on transient-error exhaustion` down to the end of that `if/else` (the `fi` just before the outer `else` that handles the success case) with:

```bash
    [[ -n "$_ECX_PROMPT_FILE" ]] && /bin/rm -f "$_ECX_PROMPT_FILE"
    # #803: _bd_exit_as only sets its own status; if/else keeps 124 from falling to 3.
    if [[ "$_ECX_TIMED_OUT" -eq 1 ]]; then
      /usr/bin/printf '%s' "$_ECX_OUTPUT"
      _bd_exit_as 124
    else
      /usr/bin/printf "%s\n" "⚠️  Codex failed after ${_ECX_ATTEMPTS_RUN} attempt(s) — falling back to built-in review" >&2
      /usr/bin/printf "%s\n" "BUILTIN_FALLBACK"
      _bd_exit_as 3
    fi
```

This is the body of the old droid-less `else` branch, word for word. Afterwards, the comment above the `if` (`# All retries exhausted, non-transient error, or a timeout — try droid (if eligible), else fall back to builtin (or preserve the timeout signal).`) becomes `# All retries exhausted, non-transient error, or a timeout — fall back to builtin (or preserve the timeout signal).`. In the exit-0 promotion comment just above it, change `so the droid/builtin fallback below engages` to `so the builtin fallback below engages`. Now confirm that `grep -n 'should_escalate_to_droid\|_classify_droid_escalation_outcome' scripts/lib/resolve-cli.sh` prints nothing.

- [ ] **Step 8: Remove the orphans Step 7 created.** After Step 7, nothing reads `_ECX_LAST_WAS_TRANSIENT`, `_ECX_DURATION_CFG` or `_ECX_FAIL_REASON`. Check: `grep -n '_ECX_LAST_WAS_TRANSIENT\|_ECX_DURATION_CFG\|_ECX_FAIL_REASON' scripts/lib/resolve-cli.sh` should list only assignments and comments.
  - Delete every `_ECX_LAST_WAS_TRANSIENT=…` assignment line. In the transient-retry `if`/`else`, the `if` branch keeps `_ECX_ATTEMPT=$((_ECX_ATTEMPT + 1))`, and the `else` branch keeps `_ECX_DONE=1` and its `printf`. In the truncated-timeout `else`, keep the `printf` and `_ECX_EXIT_CODE=1`. No branch may become empty: if one would, stop and re-read.
  - Delete the declaration `_ECX_DURATION_CFG=`, the save line `_ECX_DURATION_CFG="$_ECX_DURATION"` and its two-line `# Kept, and restored after the loop: the droid escalation…` comment. Also delete the 3-line restore block `if [[ -n "$_ECX_DURATION_CFG" ]]; then … fi`. Keep the remaining lines of the `_ECX_BROKER_DT -gt 0` elif (the three adjustments and both clamps); only the `_ECX_DURATION_CFG` lines go.
  - Reword or delete the comments that justified these variables by droid. Use `grep -n -i droid scripts/lib/resolve-cli.sh` to find them. Concretely:
    - `# narrows droid fallback…` → delete the declaration line entirely, since the variable is gone.
    - `_ECX_TIMED_OUT=0  # a single full-duration timeout is droid-eligible (not retried)` → `_ECX_TIMED_OUT=0  # a single full-duration timeout (not retried) exits 124`.
    - Delete the 4-line `# SCOPE: this bounds the retry LOOP. The droid escalation below…` paragraph.
    - The budget-gate comment `…and _ECX_LAST_WAS_TRANSIENT so a budget-exhausted sequence stays droid-eligible.` → `…exit_code.`
    - Delete the per-attempt reset comment and its assignment, `# Reflect only THIS attempt's classification…`.
    - In the 124-classification comment, drop the clauses `but a timeout IS droid-eligible (a different backend may still answer in time)`, `(droid-eligible via _ECX_TIMED_OUT; if droid can't rescue it, the caller sees exit 124…)` → `(the caller sees exit 124…)`, and `— droid-eligible via _ECX_LAST_WAS_TRANSIENT (same as the explicit budget-exhaustion breaks above), but NOT _ECX_TIMED_OUT, so a droid-less path falls through to BUILTIN_FALLBACK` → `— NOT _ECX_TIMED_OUT, so it falls through to BUILTIN_FALLBACK`.
    - `fall through to the retry/droid path` → `fall through to the retry path`.
    - The `#803: skip if _ECX_DONE=1 (classifier must not reset escalation latch).` comment → `#803: skip if _ECX_DONE=1 (the classifier must not override a finished attempt).`
    - In the retry-budget comment block above `_execute_codex` (the one ending `fall through to droid as the external-voice safety net`), change `exhausting and escalating to droid` → `exhausting and falling back to builtin`, and remove the sentences about the droid net.

- [ ] **Step 9: Delete the `execute_review` droid arm.** Remove the 9-line comment `# Review path: bare \`droid exec\` (default read-only mode)…` and the whole `droid)   _bd_droid_bin="" … fi ;;` arm.

- [ ] **Step 10: Reword the remaining droid comments in `resolve-cli.sh`.** `grep -n -i droid scripts/lib/resolve-cli.sh` lists them. The only allowed survivors are the removed-CLI set entries (Step 1) and Step 4's `(droid was withdrawn, ADR 0053)` comments. The rest fall in three areas:
  - grok-availability comments: `then STOPPED at grok…its documented droid fallback`; `the route continues to droid`; `the slot is recorded \`resolve-droid-fallback\``; `falling through to droid IS the…`. Restate them without droid: an unavailable grok now resolves to the route's next entry, or to `none`.
  - `_run_review_with_retries` comments: `the caller's droid fallback catches that` → `the caller records the failure`; `degrade to droid, silently losing the reviewer` → `fail, silently losing the reviewer`; `retry/droid path` → `retry path`; `droid rescue / litmus error path` → `litmus error path`.
  - agy comments: `caller's droid fallback rescues it` / `refused into the droid rescue` / `the caller's droid rescue owns` / `fell back to droid, and silently degraded blueprint` / `degrades to droid`. Say the slot fails instead, e.g. `the caller records the slot as failed`.
  - Four stderr lines contain no `droid` but describe it: `retry budget … spent — escalating instead of retrying` at `:2748`, `:2764`, `:3477`, `:3494`. Change them to `… spent — not retrying` at the two `_run_review_with_retries` sites and `… spent — falling back` at the two `_execute_codex` sites. Find them with `grep -n 'escalating instead of retrying' scripts/lib/resolve-cli.sh`, which must print nothing afterwards.

- [ ] **Step 11: Litmus PR mode** (`skills/litmus/scripts/run-review-loop.sh`). In the `if [ "$REVIEW_MODE" = "pr" ]` block:
  - delete the 3-line comment `# Close the silent-droid escalation inside _execute_codex…` and the line `export LITMUS_CODEX_DROID_FALLBACK_DISABLED=1`;
  - in the comment above it, replace `not just builtin/none but also droid/agy/grok` with `not just builtin/none but also agy/grok`, and `(A resolve-cli.sh route like [codex,droid] would otherwise resolve to droid when codex is missing.)` with `(A resolve-cli.sh route like [codex,agy] would otherwise resolve to agy when codex is missing.)`;
  - change `# PR mode is the cross-model gate of record with NO droid net (disabled just above) — retrying is the only recovery.` to `# PR mode is the cross-model gate of record — retrying is the only recovery.`;
  - in the PATH-prepend comment, change `the review CLI (codex/agy/droid)` to `the review CLI (codex/agy)`.

- [ ] **Step 12: Litmus messages and comments.**
  - `skills/litmus/scripts/lib/validation.sh`: `Supported values: auto, codex, agy, droid, builtin, none` → `Supported values: auto, codex, agy, builtin, none`.
  - `skills/litmus/scripts/write-review-marker.sh` and `scripts/dispatcher-commit-block.sh`: `the review CLI (codex/agy/droid)` → `the review CLI (codex/agy)`.

- [ ] **Step 13: Test env flags.** In `tests/test-codex-retry-budget.sh` and `tests/test-pr-excluded-only-autopass.sh`:
  - `tests/test-codex-retry-budget.sh:133/152/170/200`: the flag is the LAST element of an env array and carries the array's closing `)` on the same line. Remove only ` LITMUS_CODEX_DROID_FALLBACK_DISABLED=1` and keep the trailing `)`;
  - `tests/test-pr-excluded-only-autopass.sh:129/139`: delete the whole continuation line that carries the flag, and check the line above still ends the command correctly;
  - reword the comments: `with droid disabled it must fall through to BUILTIN_FALLBACK (exit 3) instead` → `it must fall through to BUILTIN_FALLBACK (exit 3)`, and `+ droid fallback` → drop the phrase;
  - `tests/test-codex-retry-budget.sh:121` quotes the old stderr text: `"retry budget spent -- escalating"` → `"retry budget spent -- falling back"`, matching Step 10.

- [ ] **Step 14: `tests/test-review-boundaries.sh` §7 and §8.** In both sections, use `agy` as the working fallback in place of `droid`. Not `codex`: these sections test `council.critic`, whose legacy default IS codex, so a codex result could not tell a route/defaults hit from the legacy default answering. agy is not faked for the legacy arm, so a legacy fallthrough resolves to `none` and fails the assertion.
  - `is_cli_available() { [[ "$1" == "droid" || "$1" == "opencode" ]]; }` → `[[ "$1" == "agy" || "$1" == "opencode" ]]`;
  - `_resolve_trusted_cli_bin`'s `opencode|droid)` → `opencode|agy)`;
  - routes `["opencode","droid"]` → `["opencode","agy"]`;
  - defaults `"fallback":"droid"` → `"fallback":"agy"`;
  - expected values `droid` → `agy`, and `droid/droid/ok` → `agy/agy/ok`, in both the assertions and their messages;
  - in the HOME-isolation comment, `(which routes council.critic → ["codex","droid"])` → `(which may route council.critic elsewhere)`;
  - all other comment wording: droid → agy, and add one line to the fixture comment: `agy, not codex: council.critic's legacy default is codex, so codex could not tell a route hit from the legacy default.`

- [ ] **Step 15: Add §9 to `tests/test-review-boundaries.sh`,** between the end of §8 and the `# ── 10.` header, so the sections stay in numeric order. The structural §9b is a separate block added in Task 6 Step 8, once no droid code or doc reference is left for it to find.

```bash
# ── 9. droid is a removed CLI (ADR 0053) ────────────────────────────
# A stale `droid` value degrades exactly like opencode, via EVERY entry point.
# droid is faked INSTALLED so a refusal cannot be a missing-binary artifact, and
# the legacy per-role defaults must no longer fall back to it.
if (
  set -uo pipefail
  _tmp_repo="$(mktemp -d)" || exit 1
  HOME="$(mktemp -d)" || exit 1
  trap 'rm -rf "$_tmp_repo" "$HOME"' EXIT
  git init -q "$_tmp_repo" || exit 1
  mkdir -p "$_tmp_repo/.claude" || exit 1
  # shellcheck source=/dev/null
  source "$RC"
  unset BUSDRIVER_REVIEW_CLI   # an exported pin would override every route case below
  # shellcheck disable=SC2329  # invoked indirectly by the sourced resolver
  is_cli_available() { [[ "$1" == "droid" || "$1" == "codex" ]]; }
  # shellcheck disable=SC2329  # invoked indirectly by the sourced resolver
  _resolve_trusted_cli_bin() { case "$1" in droid|codex) printf '/usr/bin/true\n' ;; *) return 1 ;; esac; }
  cd "$_tmp_repo" || exit 1
  ok=1
  _write_cfg() { printf '%s\n' "$1" > "$_tmp_repo/.claude/busdriver.json" || exit 1; }

  # The role under test is council.pragmatist: its legacy default (agy) is NOT
  # faked installed, so with no usable config it resolves to `none`. A `codex`
  # result below therefore proves the route/defaults entry was used — it cannot
  # be the legacy default answering instead (council.critic's legacy default IS
  # codex, which would make these cases unable to tell the two apart).
  R=council.pragmatist

  # (a) env override → unsupported:droid
  rm -f "$_tmp_repo/.claude/busdriver.json"
  r=$(BUSDRIVER_REVIEW_CLI=droid resolve_role_cli "$R" 2>/dev/null)
  [[ "$r" == "unsupported:droid" ]] || { echo "  ✗ (a) env droid → '$r' (expected unsupported:droid)"; ok=0; }

  # (b) route ["droid","codex"] → codex, with the removed-CLI warning
  _write_cfg '{"version":1,"routes":{"council.pragmatist":["droid","codex"]}}'
  err=$(resolve_role_cli "$R" 2>&1 >/dev/null)
  r=$(resolve_role_cli "$R" 2>/dev/null)
  [[ "$r" == "codex" ]] || { echo "  ✗ (b) route [droid,codex] → '$r' (expected codex)"; ok=0; }
  [[ "$err" == *"unsupported 'droid'"* ]] || { echo "  ✗ (b) no removed-CLI warning for droid: '$err'"; ok=0; }

  # (c) pure ["droid"] route → unsupported:droid
  _write_cfg '{"version":1,"routes":{"council.pragmatist":["droid"]}}'
  r=$(resolve_role_cli "$R" 2>/dev/null)
  [[ "$r" == "unsupported:droid" ]] || { echo "  ✗ (c) route [droid] → '$r' (expected unsupported:droid)"; ok=0; }

  # (d) defaults.primary=droid with a working fallback → fallback, with warning
  _write_cfg '{"version":1,"defaults":{"primary":"droid","fallback":"codex"}}'
  err=$(resolve_role_cli "$R" 2>&1 >/dev/null)
  r=$(resolve_role_cli "$R" 2>/dev/null)
  [[ "$r" == "codex" ]] || { echo "  ✗ (d) defaults droid/codex → '$r' (expected codex)"; ok=0; }
  [[ "$err" == *"defaults.primary=droid is no longer supported"* ]] || { echo "  ✗ (d) no defaults.primary warning: '$err'"; ok=0; }

  # (e) no config: legacy defaults no longer fall back to droid
  rm -f "$_tmp_repo/.claude/busdriver.json"
  for _role in council.pragmatist council.researcher blueprint-review.reviewer_3; do
    r=$(resolve_role_cli "$_role" 2>/dev/null)
    [[ "$r" == "none" ]] || { echo "  ✗ (e) $_role with droid and codex installed → '$r' (expected none)"; ok=0; }
  done

  # (f) provenance names the filtered route entry, never droid
  _write_cfg '{"version":1,"routes":{"council.pragmatist":["droid","codex"]}}'
  line=$(describe_role_resolution "$R" 2>/dev/null)
  [[ "$line" == $'codex\tcodex\tok' ]] || { echo "  ✗ (f) route provenance → '$line' (expected codex/codex/ok)"; ok=0; }

  # (g) defaults.fallback=droid is refused too. droid is faked installed and,
  # after this change, no longer on the trusted allowlist — so it reaches
  # is_cli_available (faked true): if the fallback filter is missed, these
  # resolve to droid instead of unsupported:droid.
  _write_cfg '{"version":1,"defaults":{"fallback":"droid"}}'
  err=$(resolve_role_cli "$R" 2>&1 >/dev/null)
  r=$(resolve_role_cli "$R" 2>/dev/null)
  [[ "$r" == "unsupported:droid" ]] || { echo "  ✗ (g) defaults.fallback=droid → '$r' (expected unsupported:droid)"; ok=0; }
  [[ "$err" == *"defaults.fallback=droid is no longer supported"* ]] || { echo "  ✗ (g) no defaults.fallback warning: '$err'"; ok=0; }
  _write_cfg '{"version":1,"defaults":{"primary":"droid","fallback":"droid"}}'
  r=$(resolve_role_cli "$R" 2>/dev/null)
  [[ "$r" == "unsupported:droid" ]] || { echo "  ✗ (g) defaults droid/droid → '$r' (expected unsupported:droid)"; ok=0; }

  # (h) provenance through the defaults scan skips a droid primary
  _write_cfg '{"version":1,"defaults":{"primary":"droid","fallback":"codex"}}'
  line=$(describe_role_resolution "$R" 2>/dev/null)
  [[ "$line" == $'codex\tcodex\tok' ]] || { echo "  ✗ (h) defaults provenance → '$line' (expected codex/codex/ok)"; ok=0; }

  exit $((1 - ok))
); then
  pass "droid is refused via env/route/defaults and is no legacy fallback"
else
  fail "removed-CLI droid handling failed (see assertions above)"
fi
```

- [ ] **Step 15b: `tests/test-no-auditor-lane.sh` allowlist.** Its `ALLOW_LINES` array (`:30-38`) whitelists the seven removed-CLI lines of `resolve-cli.sh` by EXACT text, so Step 1's edits would turn that suite red. Replace the seven entries with the post-Step-1 text:

```bash
ALLOW_LINES=(
  'elif [[ "$cli" == "amp" || "$cli" == "claude" || "$cli" == "aider" || "$cli" == "opencode" || "$cli" == "droid" ]]; then'
  'amp|claude|aider|opencode|droid)'
  'elif [[ "$default_primary" == "amp" || "$default_primary" == "claude" || "$default_primary" == "aider" || "$default_primary" == "opencode" || "$default_primary" == "droid" ]]; then'
  'elif [[ "$default_fallback" == "amp" || "$default_fallback" == "claude" || "$default_fallback" == "aider" || "$default_fallback" == "opencode" || "$default_fallback" == "droid" ]]; then'
  'gemini|amp|claude|aider|opencode|droid) i=$((i + 1)); continue ;;'
  'if [[ "$cli" != "opencode" && "$cli" != "droid" ]]; then'
  'if [[ -n "$cli" && "$cli" != "opencode" && "$cli" != "droid" ]]; then'
)
```

  Each entry must equal the edited `resolve-cli.sh` line after the same whitespace trimming the test applies, so write Step 1's edits to exactly these strings.

  The same file's self-tests (`:93-95`) feed the OLD text through the allowlist and would now score a hit. Update their inputs to the new text, keeping the expected counts:

```bash
expect "removed-set line is allowed"       0 "$(hits_in '          gemini|amp|claude|aider|opencode|droid) i=$((i + 1)); continue ;;')"
expect "bare removed-set label is allowed" 0 "$(hits_in '      amp|claude|aider|opencode|droid)')"
expect "removed-set line outside resolve-cli.sh is a hit" 1 "$(hits_in '      amp|claude|aider|opencode|droid)' 0)"
```

  Run `bash tests/test-no-auditor-lane.sh` and confirm it passes; if it fails, diff the reported line against the entry rather than loosening the allowlist.

- [ ] **Step 16: Run the touched tests, ShellCheck and the full shell suite.** `test-cli-retry.sh` is included because `dispatch.sh` sources `resolve-cli.sh`: it proves the C1–C5 sections Task 1 kept still pass once the rescue stops firing.

Run: `bash tests/test-review-boundaries.sh && bash tests/test-no-auditor-lane.sh && bash tests/test-codex-retry-budget.sh && bash tests/test-pr-excluded-only-autopass.sh && bash tests/test-litmus-mode-transition.sh && bash tests/test-cli-retry.sh && shellcheck scripts/lib/resolve-cli.sh skills/litmus/scripts/run-review-loop.sh && bash scripts/ci/run-shell-tests.sh`
Expected: exit 0, and ShellCheck prints nothing new compared with `main`. Compare by running the same `shellcheck` on `main` if anything prints.

- [ ] **Step 17: Commit A** (7 paths). The two test files from Step 13 stay unstaged: after this commit `LITMUS_CODEX_DROID_FALLBACK_DISABLED` has no reader, so the flag they still set is inert.

```bash
git add scripts/lib/resolve-cli.sh skills/litmus/scripts/run-review-loop.sh skills/litmus/scripts/lib/validation.sh \
  skills/litmus/scripts/write-review-marker.sh scripts/dispatcher-commit-block.sh \
  tests/test-review-boundaries.sh tests/test-no-auditor-lane.sh
git commit -m "refactor(review): make droid a removed CLI; codex failure falls straight to builtin (ADR 0053)"
```

- [ ] **Step 18: Commit B** (2 paths), immediately after.

```bash
git add tests/test-codex-retry-budget.sh tests/test-pr-excluded-only-autopass.sh
git commit -m "test: drop the retired LITMUS_CODEX_DROID_FALLBACK_DISABLED flag (ADR 0053)"
```

---

### Task 3: dispatch.sh — drop the droid lane and the runtime escalation

**Files:**
- Modify: `skills/dispatch-cli/scripts/dispatch.sh`, `tests/test-cli-retry.sh`, `tests/test-agy-prose-lane.sh`, `tests/test-agy-dispatch-arm.sh`, `tests/test-pi-dispatch-arm.sh`, `tests/test-dispatch-skipped-status.sh`, `tests/test-agy-argv-limit.sh`, `tests/test-agy-stream-transport.sh`

**Interfaces:**
- Consumes: Task 2 (`should_escalate_to_droid` no longer exists; dispatch.sh's `type should_escalate_to_droid` guard was already a no-op).
- Produces:
  - `--cli` accepts `codex|agy|agy-prose|grok|pi-read|both|all|auto`;
  - `--cli droid` fails with `Error: Invalid --cli value 'droid'…`;
  - `status` is never `droid-fallback`.

- [ ] **Step 1: Header, usage and validator.**
  - Line-86 header and the USAGE heredoc's first line: `Codex, Antigravity (agy), Droid, Grok, or pi-read CLI` → `Codex, Antigravity (agy), Grok, or pi-read CLI`.
  - USAGE `--cli` line → `  --cli     codex|agy|agy-prose|grok|pi-read|both|all|auto  (default: auto)`.
  - Validator condition: drop ` && "$CLI" != "droid"`. Message → `Must be codex|agy|agy-prose|grok|pi-read|both|all|auto.`.
  - Auto ladder: delete `    elif _has_cli droid; then CLI="droid"`. The error becomes `Error: No supported CLI found (tried codex, agy). grok is excluded…` (rest unchanged).
  - Availability gate: delete `    [[ "$CLI" == "droid" ]] && ! _has_cli droid && { echo "Error: droid not found." >&2; exit 1; }`.

- [ ] **Step 2: `--cli all`.**
  - `for c in codex agy droid grok pi-read; do` → `for c in codex agy grok pi-read; do`.
  - `[[ ${#ALL_CLIS[@]} -ge 5 ]] && break` → `[[ ${#ALL_CLIS[@]} -ge 4 ]] && break`.
  - Comment `The cap admits all five candidates` → `The cap admits all four candidates`.
  - The cap comment's `a host with codex+agy+droid+grok would otherwise never reach grok` → `the cap equals the four-candidate list, so a full house includes pi-read`.

- [ ] **Step 3: Delete the `droid)` arm** in `dispatch_one`: the whole case arm from `        droid)` through `< "$PROMPT_FILE" > "$outfile" 2>&1 || exit_code=$? ;;`, including the `DROID_AUTO_LEVEL` parsing.

- [ ] **Step 4: Retry preamble.**
  - Delete `    [[ "$name" == "droid" ]] && _max_retries=0`.
  - Rewrite the comment above it to:

```bash
    # ── Primary-CLI retry (council voices flake intermittently) ──────
    # Retry the primary CLI on a transient failure or empty output — a single
    # rate-limit/network hiccup shouldn't drop a council voice.
    # BUSDRIVER_CLI_RETRIES (default 3; council uses the default, blueprint
    # exports 5 via run-design-review-loop). A timeout (124) is never retried —
    # re-running the full window is too costly.
```

  - The next comment `# a flake. Match the droid-fallback skip below: no retries in those modes.` → `# a flake: no retries in those modes.`
  - The grok-refusal comment `must not be retried, must not be rescued by droid, and must not fail a whole batch` → `must not be retried, and must not fail a whole batch`.
  - The budget comment `(retries+1)× the timeout before droid fallback fires.` → `(retries+1)× the timeout.`

- [ ] **Step 5: Post-loop.**
  - `# Timeout → don't retry; the droid fallback below handles it.` → `# Timeout → don't retry; it is reported as a timeout.`
  - `Those fall through to the retry/droid path;` → `Those fall through to the retry path;`
  - `→ the droid fallback owns the rescue).` → `→ it is reported as an error).`
  - The exhaustion comment → `# Exhausted retries while the output file is still empty OR still holds a bare` / `# transient notice on a clean exit → mark as failure so the status below is` / `# reported as error rather than a silent empty / rate-limited success.`

- [ ] **Step 6: Delete the runtime droid fallback.**
  - Remove everything from the comment `# ── Runtime droid fallback (per-voice, single-CLI dispatch only) ──` through the closing `fi` of `if [[ "$CLI" != "all" … should_escalate_to_droid …; then … fi`. That includes `local escalated=0` and the pi and prose exemption comments.
  - Delete `    [[ "$escalated" -eq 1 ]] && status="droid-fallback"`.

- [ ] **Step 7: Prose lane and agy comments.**
  - The `_AGY_PROSE_LANE` declaration comment says the flag "is read in two places: it adds `--mode plan` to agy's argv, and it exempts the lane from the runtime droid escalation. Deliberately ONE flag for both…". Replace it with:

```bash
# Set only by the `agy-prose` desugar below. Carries the LANE IDENTITY that the
# desugar would otherwise erase (it rewrites CLI to plain "agy"); it adds
# `--mode plan` to agy's argv.
```

    The two following lines (`# Empty for every other caller, so plain…` onward) stay.
  - The desugar comment `Why a lane and not a route with a fallback chain: a route escalates a failed dispatch to droid…` → replace that 6-line paragraph with:

```bash
# Why a lane: the operator's `.writing_prose.model` choice decides which third
# party sees the brief. A failed dispatch fails; nothing re-sends it elsewhere.
```

  - The agy `--model` config-error comment block (`is a CONFIG error, and the runtime droid escalation exists for…` through `…the lane's own droid exemption exists to prevent.`): remove the droid sentences. It should now say the error fails the dispatch, which is the correct outcome for a config error.
  - Error hints: `Use --cli codex/droid` → `Use --cli codex`, and `or use --cli codex/droid` → `or use --cli codex`.
  - The timeout-budget comment `agy's four \`--print-timeout\` sites and the droid rescue.` → `and agy's four \`--print-timeout\` sites.`
  - grok comments: `write-capable workloads route to codex/agy/droid` → `codex/agy`. `the droid rescue, so an operator who asked for grok…` and `not fall through to droid escalation` → say the dispatch fails instead.
  - `the prompt falling through to the droid rescue, which would ship` → `the prompt being re-sent elsewhere, which would ship`. Read the surrounding sentence and keep it grammatical.

- [ ] **Step 8: Report whitelist.** `        codex|agy|agy-prose|droid|grok|pi-read) ;;` → `        codex|agy|agy-prose|grok|pi-read) ;;`. Then confirm `grep -n -i droid skills/dispatch-cli/scripts/dispatch.sh` prints nothing.

- [ ] **Step 9: `tests/test-cli-retry.sh`.** C2 and C3 were already rewritten, and C7 and C8 deleted, in Task 1 Step 4c.
  - In C1, C4 and C5, delete the `printf … DROID_RESCUE … > "$STUB/droid"`, `chmod`, `rm -f "$STUB/droid"` lines and every `! grep -q DROID_RESCUE` clause, keeping the rest of each assertion.
  - Rename messages that mention droid: `"council agy transient x2 → retried to success, no droid"` → `"council agy transient x2 → retried to success"`.
  - Reword the header comments.
  - Afterwards `grep -n -i droid tests/test-cli-retry.sh` prints nothing, and the test's pass count is unchanged from the Task 1 commit (this step deletes stubs and clauses, not sections).

- [ ] **Step 10: `tests/test-agy-prose-lane.sh`.**
  - Delete section 2 (`# ── 2. droid-escalation exemption …` through its `fi`) and the header bullet `# 2. NO droid escalation…`. Renumber the header bullets only if they are numbered consecutively.
  - The whitelist regex becomes `'^[[:space:]]+codex\|agy\|agy-prose\|grok\|pi-read\) ;;$'`.

- [ ] **Step 11: `tests/test-agy-dispatch-arm.sh`.**
  - `:267`'s whitelist locator regex `'^[[:space:]]+codex\|agy\|agy-prose\|droid\|grok\|pi-read\) ;;$'` → `'^[[:space:]]+codex\|agy\|agy-prose\|grok\|pi-read\) ;;$'`. Without this `l_whitelist` comes back empty after Step 8 and the order check (`:272-279`) and the whitelist-present check (`:296-299`) fail.
  - Remove the `&& "$out" != *"falling back to droid"*` and `&& "$out" != *"droid-fallback"*` clauses at `:366`, and the single `&& "$out" != *"falling back to droid"*` clause at `:403`. Keep each condition's remaining clauses and its closing `]]; then`.
  - Reword the comments and the message `should refuse before invoking agy or droid` → `should refuse before invoking agy`.

- [ ] **Step 12: `tests/test-pi-dispatch-arm.sh`.** The bash-3.2 floor scan uses droid as an arbitrary non-pi CLI. Use codex instead:
  - the stub `"$FAKE_HOME/9b-bin/droid"` becomes `"$FAKE_HOME/9b-bin/codex"`, with the same body `exit 124`;
  - the three `scan_args` strings and the `NONPI_OUT` invocation use `--cli codex`;
  - the comment `(stub droid exits 124)` becomes `(stub codex exits 124)`.

  The §4 batch-safety checks also pin the old candidate list, and §4b pins the escalation Step 6 deletes:
  - `:1478` `grep -qE '\$\{#ALL_CLIS\[@\]\} -ge 5'` → `-ge 4`, and its pass message `admits all five CLIs` → `admits all four CLIs`;
  - `:1482` `grep -qF 'for c in codex agy droid grok pi-read; do'` → `'for c in codex agy grok pi-read; do'`, with both messages updated to `codex agy grok pi-read` (and `(ADR 0051)` → `(ADR 0053)`);
  - delete §4b entirely (`# ── 4b. A failed pi must NOT escalate to droid` through its `|| fail …` line, `:1486-1492`). There is no escalation left for pi to be exempt from; Task 6 Step 8's §9b is what proves no escalation code returns.

  If the codex arm needs anything beyond `_has_cli codex` (for example, the companion lookup), first read how the `--cli droid` invocation's assertion is phrased. It must still reach "its own error path" and not the pi 3.2 floor, and the 124 stub does that for codex the same way.

- [ ] **Step 13: Comment and regex edits.**
  - `tests/test-dispatch-skipped-status.sh`: `status="(success|timeout|error|droid-fallback|skipped)"` → `status="(success|timeout|error|skipped)"`, and the comment `so agy, droid and grok` → `so agy and grok`.
  - `tests/test-agy-argv-limit.sh`: `silently degrade to droid` → `silently lose the reviewer`.
  - `tests/test-agy-stream-transport.sh`: `refused into the droid rescue` → `refused`. Keep the sentence grammatical.

- [ ] **Step 14: Run.**

Run: `rc=0; for t in cli-retry agy-prose-lane agy-dispatch-arm pi-dispatch-arm dispatch-skipped-status agy-argv-limit agy-stream-transport; do bash tests/test-$t.sh >/dev/null 2>&1 && echo "ok $t" || { echo "FAIL $t"; rc=1; }; done; shellcheck skills/dispatch-cli/scripts/dispatch.sh || rc=1; echo "rc=$rc"`
Expected: 7 × `ok`, no new ShellCheck findings, and `rc=0`.

- [ ] **Step 15: Commit** (8 paths). Before committing, `bash scripts/ci/run-shell-tests.sh` must exit 0.

```bash
git add skills/dispatch-cli/scripts/dispatch.sh tests/test-cli-retry.sh tests/test-agy-prose-lane.sh tests/test-agy-dispatch-arm.sh \
  tests/test-pi-dispatch-arm.sh tests/test-dispatch-skipped-status.sh tests/test-agy-argv-limit.sh tests/test-agy-stream-transport.sh
git commit -m "refactor(dispatch): drop the droid lane and runtime droid escalation (ADR 0053)"
```

---

### Task 4: Blueprint review — no droid rescue

**Files:**
- Modify: `skills/blueprint-review/scripts/run-design-review-loop.sh`, `skills/blueprint-review/scripts/lib/extract_review_json.py`, `skills/blueprint-review/scripts/lib/test_extract_review_json.py`, `skills/blueprint-review/scripts/lib/test_extract_review_json_log_echo.py`, `skills/blueprint-review/prompts/claude_validation_prompt.txt`, `tests/test-blueprint-nonzero-salvage.sh`, `tests/test-blueprint-pass-verdict-countable.sh`, `tests/test-blueprint-review-state.sh`

**Interfaces:**
- Consumes: Task 2 (the `resolve-droid-fallback` reason no longer exists).
- Produces: a reviewer slot that fails at runtime stays `runtime-failed`. `derive_coverage` never emits `runtime-droid-rescue`.

- [ ] **Step 1: Delete `_bp_droid_rescue`.** Remove the comment block starting `# Blueprint runtime droid fallback: rescue a failed reviewer slot once via droid.` and the function through its closing `}` (the line after `log_warning "  droid rescue ${slot}: retag failed — keeping error entry"; return 1`).

- [ ] **Step 2: Delete the Phase 1 rescue loop.** Remove from `  # ── Runtime droid fallback (capped at one voice) ─────────────────` through the `fi` that closes `if is_cli_available droid \ … then … done` (the line just before `  # Duplicate mode: copy single reviewer's output to both paths`).

- [ ] **Step 3: Phase 1 env.**
  - Delete the 4-line comment `# Blueprint caps droid at one voice, so disable codex's internal…` and `export LITMUS_CODEX_DROID_FALLBACK_DISABLED=1`.
  - In the retry-budget comment, `(the most important paths get more patience before the single droid rescue fires)` → `(the most important paths get more patience before the slot is recorded as failed)`.
  - In the HARNESS BUDGET comment, the formula `max( _REV_TIMEOUT + droid rescue(≤1200),` → `max( _REV_TIMEOUT + codex broker reap(≤30, codex slot only),`. The worked numbers change too: `Left term: 2400s at the default reviewer budget (1200+1200), 3000s at the 1800 clamp (1800+1200).` → `Left term: 1230s at the default reviewer budget, 1830s at the clamp.`, and `At the documented oracle ceiling of 3600 the RIGHT term binds instead` is unchanged.

- [ ] **Step 4: Salvage function.**
  - In `_bp_salvage_nonzero_verdict`, delete the `.salvaged` sidecar write: the comment `# Out-of-band carry-over record for \`_bp_droid_rescue\`…` and the `jq -n … > "${out}.salvaged" … || rm -f "${out}.salvaged"` command. Its only reader was the rescue.
  - KEEP `        | del(.metadata.runtime_escalated_from)` in the jq filter. Step 5 keeps the field's reader (now mapping it to `runtime-failed`), so stripping a payload-authored copy stays meaningful hygiene, and its test (`tests/test-blueprint-nonzero-salvage.sh:149-154`) stays valid.
  - Comment edits above the function:
    - `runtime-failed and the droid rescue still treats it as rescuable — exactly as before this function existed.` → `runtime-failed — exactly as before this function existed.`
    - `the same extractor \`_bp_droid_rescue\` uses,` → `the same extractor the exit-0 path uses,`
    - `so a droid reviewer self-labels \`codex\` — #714` → `so a reviewer can self-label as another CLI — #714`
    - the last two lines, `# \`runtime_escalated_from\` is DELETED…` / `# rescue ran", and nothing was dispatched here.`: keep the first clause and replace the droid wording, so they read `# \`runtime_escalated_from\` is DELETED: derive_coverage never counts a slot carrying it (ADR 0053),` / `# and nothing was dispatched here, so a payload's claim must not reach coverage.`

- [ ] **Step 5: `derive_coverage`.** Keep the `runtime_escalated_from` check but stop naming droid. It is the only thing that keeps a fresh-run_id PASS/FAIL artifact carrying the field from counting as a covered slot, so deleting it would loosen fail-closed (a hand-written or left-over artifact could then help `--claude-only` stamp PASS). It costs two lines and needs no reachability argument.
  - Keep the `esc=$(jq -r '.metadata.runtime_escalated_from // ""' …)` line and `esc` in the `local` list.
  - Change the branch `elif [[ -n "$esc" && "$esc" != "null" ]]; then` / `final="runtime-droid-rescue"` to:

```bash
      elif [[ -n "$esc" && "$esc" != "null" ]]; then
        # Legacy-artifact guard (ADR 0053): the rescue that wrote this field is
        # gone, so nothing current sets it. A slot still carrying it was not
        # produced by its own reviewer this run — never count it as coverage.
        final="runtime-failed"
```

  - Change the resolve-reason comment `/ builtin / resolve-droid-fallback)` to `/ builtin)`. Leave the header comment `(status / run_id / runtime_escalated_from)` as is: the field is still read.
  - In the coverage-helper header, `(vs fell back to droid / collapsed to a duplicate / errored)` becomes `(vs collapsed to a duplicate / errored)`.

- [ ] **Step 6: Collision comment and Phase 3 cross-reference.**
  - Rewrite the collision comment's droid example as:

```bash
    # Note: collision check compares RESOLVED PRIMARIES, not the effective
    # running set. Edge case: if all three slots resolve to the same CLI (e.g. a
    # BUSDRIVER_REVIEW_CLI=codex pin), DUPLICATE_MODE skips reviewer_2 and
    # REVIEWER_3_DUPLICATE skips reviewer_3, leaving only reviewer_1's run. This
    # is the conservative behavior (avoid running near-identical CLI+prompt twice
    # under different role labels). If non-deterministic LLM voice multiplication
    # ever becomes desired here, lift this restriction and let DUPLICATE_MODE-
    # skipped slots be backfilled by reviewer_3.
```

  - At the #656 intake comment, `Same shape the droid rescue already demands of a reviewer verdict (\`_bp_droid_rescue\`).` → `Same shape \`_bp_salvage_nonzero_verdict\` demands of a reviewer verdict.`
  - Confirm that `grep -n -i 'droid\|}\.salvaged' skills/blueprint-review/scripts/run-design-review-loop.sh` prints nothing (the `}\.salvaged` form matches the deleted `"${out}.salvaged"` sidecar path but not the `.metadata.salvaged_status` / `.metadata.salvaged_exit_code` fields, which stay), and that `grep -n 'runtime_escalated_from' skills/blueprint-review/scripts/run-design-review-loop.sh` lists only the salvage `del()`, its comment, the `derive_coverage` read and its header comment.

- [ ] **Step 7: Extractor, its tests and the arbiter prompt.**
  - `extract_review_json.py` line 2: `(Agy, Codex, Droid, etc.)` → `(Agy, Codex, Grok, etc.)`. In the `_MAX_UNBALANCED_SCANS` comment, `droid folds stderr into the same file, so a few stray brackets are normal` → `reviewer CLIs fold stderr into the same file, so a few stray brackets are normal`. Then reword every other `droid` hit from `grep -n -i droid` in that file the same way: the reviewer CLI, not droid.
  - `test_extract_review_json.py`: the module docstring `every droid rescue in the repo's review history died at this extractor` → `every reviewer salvage in the repo's review history died at this extractor`; `Droid's actual shape:` → `A real reviewer shape:`; `_bp_droid_rescue would retag and accept it as a PASS` → `the salvage path would retag and accept it as a PASS`.
  - `test_extract_review_json_log_echo.py`: `burning a second budget on a droid rescue` → `losing the reviewer's verdict`. The fixture string `'[droid] verdict: {"reviewer_id":"droid",` → `'[reviewer] verdict: {"reviewer_id":"codex",`. It is an arbitrary mid-line prefix; the assertion keys on the broken nested PASS, not on the name. Read the test to confirm before changing it.
  - `claude_validation_prompt.txt`: `that slot falls back to any other available CLI (e.g., droid); arbitration proceeds with whichever reviewers returned.` → `that slot is recorded as failed; arbitration proceeds with whichever reviewers returned.` Also `(fell back to droid, collapsed to a duplicate, returned empty, or errored)` → `(collapsed to a duplicate, returned empty, or errored)`.

- [ ] **Step 8: Blueprint tests.**
  - `tests/test-blueprint-nonzero-salvage.sh`:
    - delete the rescue section: from its lead comment `# A salvaged slot is still ERROR, so the post-run droid rescue may pick it.` (`:188`) through the `fi` just before `echo "── all three reviewer slots share the one mechanism ────────"`, keeping one `echo ""` separator. It extracts `_bp_droid_rescue` with sed and holds the only `run_block … codex` calls;
    - change the helper default `cli="${3:-droid}"` to `cli="${3:-agy}"`, and the assertions at `:134-138` expecting `"droid"` for `.reviewer_id` and `.issues[N].reviewer` to `"agy"`, with the message `(droid, not the model's 'codex')` → `(agy, not the model's 'codex')`. The resolved CLI must stay DIFFERENT from the fixture's self-label `codex`: these assertions are the #714 misattribution guard, and with equal values they would pass even if the retag code were deleted. The fixture's own `reviewer_id` and issue `reviewer` values stay `codex`;
    - change the fixture line `[droid] session started, loading config...` to `[agy] session started, loading config...`, and the fixture comment at `:47` `while the resolved CLI is droid` → `while the resolved CLI is agy`;
    - keep the fixture's `runtime_escalated_from` and the assertion at `:152-154` (Step 4 keeps the `del()` it tests). Reword only its comment at `:149-151` to `# The fixture authors runtime_escalated_from, which derive_coverage treats as` / `# "not this reviewer's own run" (ADR 0053). Nothing was dispatched here, so the retag` / `# must DELETE it rather than carry the payload's claim into coverage.`;
    - reword the comments that mention the rescue (`:128-129` `and the droid rescue (which skips PASS/FAIL slots) still treats it as rescuable` → drop the clause), and the pass message at `:132` `and stays droid-rescue eligible` → drop the clause;
    - if any assertion checks that `.salvaged` exists, delete it: Step 4 removed that file.
    - Afterwards `grep -n -i 'droid' tests/test-blueprint-nonzero-salvage.sh` must print nothing.
  - `tests/test-blueprint-pass-verdict-countable.sh`:
    - delete the case line `RECEIPT_MODE=rescued expect "a droid-rescued slot with its own receipt stamps PASS" PASS '[]' YES 0` and the fixture arm `        rescued:agy) rcli=droid ;;               # the droid rescue writes its own receipt`;
    - in the `elif` condition, change `&& "${RECEIPT_MODE:-ok}" != rescued` to nothing, keeping `elif [[ "${RECEIPT_MODE:-ok}" != agymissing ]]; then`.
  - `tests/test-blueprint-review-state.sh`:
    - both fixtures `update_coverage_slot 3 grok droid false resolve-droid-fallback` and `update_coverage_slot 3 grok droid "" resolve-droid-fallback` become `update_coverage_slot 3 grok none false explicit-none` and `update_coverage_slot 3 grok none "" explicit-none`;
    - the assertions expecting `resolve-droid-fallback` now expect `explicit-none`;
    - the four labels change: `:385` `"two fulfilled + one droid-fallback → DEGRADED"` → `"two fulfilled + one explicit-none → DEGRADED"`; `:387` `"reviewer_3 reason persisted"` stays (its expected value changes to `explicit-none`); `:462` `"droid-fallback slot → not fulfilled"` → `"explicit-none slot → not fulfilled"`; `:463` `"droid-fallback reason preserved"` → `"explicit-none reason preserved"`. Afterwards `grep -n -i droid tests/test-blueprint-review-state.sh` prints nothing.

    `explicit-none` is a real `describe_role_resolution` reason, so it is the right stand-in for an unfulfilled resolve-time slot.
    - Add a test for the Step 5 legacy-artifact guard, which no test reaches today. In the `derive_coverage fulfillment logic` section, directly before `COV_STATUS_BEFORE=$(get_state_field coverage_status)`, insert:

```bash
# ADR 0053 legacy-artifact guard: a fresh-run_id PASS that carries
# runtime_escalated_from was not produced by its own reviewer this run, so it
# must never count as coverage.
update_coverage_slot 1 agy agy "" ok
update_coverage_slot 2 codex codex "" ok
update_coverage_slot 3 grok grok "" ok
printf '%s' '{"status":"PASS","issues":[],"metadata":{"run_id":"RID1"}}' > "$AGY_OUTPUT_FILE"
printf '%s' '{"status":"PASS","issues":[],"metadata":{"run_id":"RID1"}}' > "$CODEX_OUTPUT_FILE"
printf '%s' '{"status":"PASS","issues":[],"metadata":{"run_id":"RID1","runtime_escalated_from":"grok"}}' > "$GROK_OUTPUT_FILE"
derive_coverage
assert_eq "runtime_escalated_from on a fresh PASS → runtime-failed" "runtime-failed" "$(get_state_field reviewer_3_reason)"
assert_eq "runtime_escalated_from slot → not fulfilled" "false" "$(get_state_field reviewer_3_fulfilled)"
assert_eq "clean slots beside it still fulfilled" "true" "$(get_state_field reviewer_1_fulfilled)"
assert_eq "legacy-artifact guard → DEGRADED" "DEGRADED" "$(get_state_field coverage_status)"
```

- [ ] **Step 9: Leave §9b for later.** It scans `skills/**` docs too, and `skills/litmus/SKILL.md` still names `droid exec` and the env var until Task 5. §9b is added in Task 6 Step 8.

- [ ] **Step 10: Run.**

Run: `bash tests/test-blueprint-nonzero-salvage.sh && bash tests/test-blueprint-pass-verdict-countable.sh && bash tests/test-blueprint-review-state.sh && uv run --quiet --with 'pytest==9.0.3' pytest skills/blueprint-review/scripts/lib/test_extract_review_json.py skills/blueprint-review/scripts/lib/test_extract_review_json_log_echo.py -q && shellcheck skills/blueprint-review/scripts/run-design-review-loop.sh`
(The pytest invocation is the one `scripts/test-python.sh` uses for these two files; plain `python3` has no pytest.)
Expected: all PASS, with no new ShellCheck findings.

- [ ] **Step 11: Commit** (8 paths). Before committing, `bash scripts/ci/run-shell-tests.sh` must exit 0.

```bash
git add skills/blueprint-review/scripts/run-design-review-loop.sh skills/blueprint-review/scripts/lib/extract_review_json.py \
  skills/blueprint-review/scripts/lib/test_extract_review_json.py skills/blueprint-review/scripts/lib/test_extract_review_json_log_echo.py \
  skills/blueprint-review/prompts/claude_validation_prompt.txt tests/test-blueprint-nonzero-salvage.sh \
  tests/test-blueprint-pass-verdict-countable.sh tests/test-blueprint-review-state.sh
git commit -m "refactor(blueprint-review): remove the one-voice droid rescue (ADR 0053)"
```

---

### Task 5: Config and user-facing docs

**Files:**
- Modify: `.claude/busdriver.json`, `docs/examples/busdriver.json`, `README.md`, `docs/degraded-modes.md`, `docs/observability.md`, `skills/litmus/SKILL.md`, `skills/litmus/references/pr-review-mode.md`, `skills/dispatch-cli/SKILL.md`

- [ ] **Step 1: Config files.** In `.claude/busdriver.json`, every route drops `"droid"`: `["codex", "droid"]` → `["codex"]`, `["agy", "droid"]` → `["agy"]`, `["grok", "droid"]` → `["grok"]`. Do the same for every route in `docs/examples/busdriver.json`, which is multi-line: delete each `"droid"` element and the comma before it. Validate both with `jq -e . .claude/busdriver.json docs/examples/busdriver.json >/dev/null`.

- [ ] **Step 2: `README.md`.**
  - The auto row → `| auto (default) | Detects: codex > agy > built-in agent fallback |`.
  - Delete the `| droid | Droid CLI |` row and the `| [Droid](https://droid.dev) | … |` optional-CLI row.
  - In the routes JSON example, drop `"droid"` from each array.
  - Council researcher row `grok (fallback: droid)` → `grok`.
  - Replace the sentence `For council, fallback preserves availability but dilutes role identity (Droid filling in as Pragmatist is no longer "Agy's strategic lens").` with `A role whose CLI is missing drops its voice; council records it as (unavailable).`

- [ ] **Step 3: `docs/degraded-modes.md`.**
  - Codex row: replace the clause `**Auto-escalates to droid exec** … disable with LITMUS_CODEX_DROID_FALLBACK_DISABLED=1 …` with `Falls back to the built-in review (exit 3); PR mode fails closed.` Keep the rest of the row as is.
  - agy row: drop `blueprint reviewer_1 falls back to droid`, replacing it with `blueprint reviewer_1 is recorded failed (coverage DEGRADED, PASS withheld)`.
  - Delete the whole `| **Droid CLI** | … |` row.

- [ ] **Step 4: `docs/observability.md`.** In the `codex-droid-fallback` row, replace the description cell with `**Retired (ADR 0053).** No longer emitted; historical entries recorded a Codex→droid escalation.`

- [ ] **Step 5: `skills/litmus/SKILL.md`.** Apply each edit by finding its quoted text:
  - `the review escalates to \`droid exec\` (default read-only mode) before falling back to the builtin Claude agent — see \`LITMUS_CODEX_DROID_FALLBACK_DISABLED\` below.` → `the review falls back to the builtin Claude agent.`
  - every `codex→droid→builtin chain` → `codex→builtin chain`;
  - `so a failed Codex falls to builtin — which is rejected — never silently to droid)` → `so a failed Codex falls to builtin — which is rejected)`;
  - `(auto/codex/agy/droid/builtin/none)` → `(auto/codex/agy/builtin/none)`;
  - delete the whole `LITMUS_CODEX_DROID_FALLBACK_DISABLED` bullet;
  - `maximum retry attempts before escalating to droid` → `maximum retry attempts before falling back to builtin`;
  - delete `(it escalates straight to droid)` and `and any applicable droid escalation was disabled, unavailable, or also failed`;
  - the #823/#864 timeout paragraph (`:243`): delete the sentence `The droid escalation is deliberately outside this bound — it gets its own full \`duration\`, because a safety net handed 0s is no net.`;
  - `:396` `the runtime \`codex → droid → builtin\` chain` → `the runtime \`codex → builtin\` chain`;
  - `:467` PR-mode paragraph: `(codex is pinned and \`LITMUS_CODEX_DROID_FALLBACK_DISABLED=1\` is set, so a failed Codex falls to builtin — which is rejected — never silently to droid)` → `(codex is pinned, so a failed Codex falls to builtin — which is rejected)`;
  - `:486` retry bullet: `have no/limited droid net` → `have no second provider`.

  Afterwards `grep -n -i droid skills/litmus/SKILL.md` prints nothing.

- [ ] **Step 6: `skills/litmus/references/pr-review-mode.md`.**
  - Delete the `export LITMUS_CODEX_DROID_FALLBACK_DISABLED=1` line from the snippet, and reword its lead-in to `PR mode pins the lead to Codex before the review runs:`.
  - In the Degraded States table, the "droid escalation is DISABLED" row becomes a row stating that a failed Codex falls to builtin, which PR mode rejects (fail-closed).
  - `Codex/droid both exhausted` → `Codex exhausted`, and drop its `LITMUS_CODEX_DROID_FALLBACK_DISABLED=1 is set…` sentence.
  - `BUSDRIVER_REVIEW_CLI=droid/agy` → `BUSDRIVER_REVIEW_CLI=agy`.

- [ ] **Step 7: `skills/dispatch-cli/SKILL.md`.**
  - The frontmatter description: `Codex, Antigravity (agy), or Droid CLI` → `Codex, Antigravity (agy), Grok, or pi-read`. The body sentence at line 14 has backticks: `Codex, Antigravity (\`agy\`), or Droid CLI` → `Codex, Antigravity (\`agy\`), Grok, or pi-read`.
  - Triggers: `send to codex/agy/droid` → `send to codex/agy`.
  - Delete the `| Fast autonomous agent | \`droid\` | … |` row.
  - `(up to 5;` → `(up to 4;`.
  - The `--cli` row: drop `` `droid`, ``.
  - Delete these droid-only blocks outright (line numbers as of `main` 5e377d26): the `droid` row of the sandboxing table (`:152`); the "Droid caveat" with its tier table (`:210-216`); the "Dispatch tier mapping" table with the `DROID_AUTO_LEVEL` empirical note and security warning (`:218-227`); and the `execute_review` "`droid exec`" parenthetical (`:231`).
  - `:129` → `A failed pi fails; nothing re-sends it to another provider.` Reword `:142` and any other remaining `grep -n -i droid` hit the same way: "a failed dispatch fails; nothing re-sends it to another provider".
  - Afterwards `grep -n -i droid skills/dispatch-cli/SKILL.md` prints nothing.

- [ ] **Step 8: Commit** (8 paths). Before committing, `bash scripts/ci/run-shell-tests.sh` must exit 0.

```bash
git add .claude/busdriver.json docs/examples/busdriver.json README.md docs/degraded-modes.md docs/observability.md \
  skills/litmus/SKILL.md skills/litmus/references/pr-review-mode.md skills/dispatch-cli/SKILL.md
git commit -m "docs: remove droid from config, README, degraded modes and litmus/dispatch docs (ADR 0053)"
```

---

### Task 6: Remaining skill docs and CI prose

**Files:**
- Modify: `skills/blueprint-review/SKILL.md`, `skills/council/SKILL.md`, `skills/writing-prose/SKILL.md`, `skills/orchestrator/tasks-catalog.md`, `skills/codex-goal-handover/SKILL.md`, `docs/ci/shell-test-inventory.md`, `.github/workflows/tests.yml`

- [ ] **Step 1: `skills/blueprint-review/SKILL.md`.**
  - Overview: delete `falls back to Droid if grok is unavailable, matching the existing reviewer_1/_2 droid-fallback pattern across all three slots`.
  - Configuration JSON: drop `"droid"` from the three route arrays. Replace the paragraph about all three slots walking to droid as a universal fallback with: `Each slot names one CLI. A missing grok resolves reviewer_3 to none. A missing reviewer_1/_2 CLI falls through to auto-detect (codex, then agy, then builtin) and typically collapses into DUPLICATE_MODE. A runtime failure is recorded runtime-failed. In each case coverage is DEGRADED and PASS is withheld (#355). reviewer_1/reviewer_2 collisions enter DUPLICATE_MODE, and reviewer_3 collisions skip that voice.`
  - Route table, Reviewer 3: `grok (default: none if grok not installed)`.
  - Per-reviewer retry: delete the sentence starting `Only after a reviewer exhausts its retries does the one-voice droid rescue fire`.
  - Timeout formula: drop `→ an optional sequential droid rescue (one more execute_review, ≤1200s)`, and update any worked number that included it so it matches Task 4 Step 3.
  - Coverage provenance: `did not fall back to droid / collapse to a duplicate / return empty / error` → `did not collapse to a duplicate / return empty / error`.

- [ ] **Step 2: `skills/council/SKILL.md`.**
  - Roles table: `council.researcher (default: grok, fallback: droid)` → `council.researcher (default: grok)`.
  - Routing text: remove the `["agy", "droid"]` example and the role-dilution trade-off. State that a missing role CLI drops the voice, recorded `(unavailable)`, and that a route can name another CLI.
  - Runtime retry: delete `Only after retries are exhausted does the per-voice runtime droid fallback fire…`. Replace it with `When retries are exhausted the voice drops and is recorded (unavailable).`
  - Retitle the bold lead-in at `:32` `**Runtime retry + droid fallback (distinct from the route-array fallback above):**` → `**Runtime retry (distinct from the route-array fallback above):**`.
  - Step 4b: delete both `# DROID_AUTO_LEVEL=low:` comment lines (`:136`, `:141`), delete the `DROID_AUTO_LEVEL=low ` prefix from both dispatch lines, and delete rationale item `(d) DROID_AUTO_LEVEL=low…`. If items are lettered, re-letter any items that follow.
  - Delete the sentences `When the resolver falls back to Droid in any slot…`, `and when a fallback fires (e.g., Droid serving as Pragmatist because Agy was missing)…` (keep that sentence's preceding clause grammatical) and `When the resolver falls back to Droid in the Researcher slot…`, plus the report-template parenthetical `(If grok was unavailable and Droid handled the slot, use **Droid (Researcher, fallback):** instead.)`.
  - Guardrail 7: `(Grok/Droid)` → `(Grok)`.
  - Auto-save template: `{Fresh Claude Skeptic/Agy/Codex/Grok/Droid/multiple}` → `{Fresh Claude Skeptic/Agy/Codex/Grok/multiple}`.
  - Afterwards `grep -n -i droid skills/council/SKILL.md` must print nothing.

- [ ] **Step 3: `skills/writing-prose/SKILL.md`.** Delete the bullet `- **No droid escalation.** A failed dispatch fails, rather than silently re-sending…` (all 3 lines). Nothing remains to be exempt from.

- [ ] **Step 4: `skills/orchestrator/tasks-catalog.md`.** `send to codex/agy/droid` → `send to codex/agy`.

- [ ] **Step 5: `skills/codex-goal-handover/SKILL.md`.** These are historical council provenance notes. Change `(Droid Researcher)` → `(council Researcher, then droid)`, `External validation (Droid Researcher, 2026-05-13):` → `External validation (council Researcher, 2026-05-13):`, `Deferred from Droid's research:` → `Deferred from the Researcher's notes:`, and `:378` `per Droid's research` → `per the council Researcher's notes`. The first keeps the historical fact; the others read fine without the name.

- [ ] **Step 6: CI prose.**
  - `docs/ci/shell-test-inventory.md`: `no droid fallback` → `no fallback`. If the inventory lists `test-droid-escalation` or `test-droid-escalation-outcome` as rows, delete those rows.
  - `.github/workflows/tests.yml`: `codex/agy/droid/grok` → `codex/agy/grok`. The edit is a comment only.

- [ ] **Step 7: Commit** (7 paths). Before committing, `bash scripts/ci/run-shell-tests.sh` must exit 0.

```bash
git add skills/blueprint-review/SKILL.md skills/council/SKILL.md skills/writing-prose/SKILL.md skills/orchestrator/tasks-catalog.md \
  skills/codex-goal-handover/SKILL.md docs/ci/shell-test-inventory.md .github/workflows/tests.yml
git commit -m "docs(skills): remove droid from blueprint, council and dispatch prose (ADR 0053)"
```

- [ ] **Step 8: Add §9b and commit it on its own.** Add this block to `tests/test-review-boundaries.sh`, directly after §9 and before the `# ── 10.` header:

```bash
# ── 9b. no droid code path survives (structural) ────────────────────
# Plain grep, not `git grep`: it must work in a non-git copy (the mutation
# check runs in one). rc 0 = a match (fail), 1 = clean (pass), anything else =
# the scan itself broke — fail CLOSED, never read an error as "clean".
_droid_pat='should_escalate_to_droid|_classify_droid_escalation_outcome|_bp_droid_rescue|LITMUS_CODEX_DROID_FALLBACK|DROID_AUTO_LEVEL|droid exec'
_droid_hits="$(grep -rnE "$_droid_pat" "$REPO_ROOT/scripts" "$REPO_ROOT/skills" "$REPO_ROOT/hooks" 2>&1)"
case $? in
  1) pass "no droid escalation/rescue/dispatch code remains" ;;
  0) fail "a droid code path survives:"; printf '%s\n' "$_droid_hits" ;;
  *) fail "droid structural scan failed to run: $_droid_hits" ;;
esac
```

§9b deliberately scans only the executable and skill trees. Leftovers in `tests/` and `docs/` are caught by Task 8 Step 1's substring grep, which is the acceptance check of record.

Run: `bash tests/test-review-boundaries.sh && bash scripts/ci/run-shell-tests.sh`
Expected: exit 0, and the output includes §9b's `no droid escalation/rescue/dispatch code remains`. If §9b lists a hit, it is a reference an earlier task missed. Fix it in this commit.

```bash
git add tests/test-review-boundaries.sh
git commit -m "test: assert no droid code path remains (ADR 0053)"
```

---

### Task 7: ADR, amendments, plan

**Files:**
- Create: `docs/adr/0053-withdraw-droid.md`
- Modify: `docs/adr/0006-pr-mode-codex-deep-review.md`, `docs/adr/0034-pi-in-tree-read-lane.md`
- Add: `docs/plans/2026-10-06-withdraw-droid.md` (this file)

- [ ] **Step 1: Write the ADR.**

```markdown
# ADR 0053 — Withdraw the droid CLI

## Status

**Accepted (2026-10-06).** Amends [ADR 0006](./0006-pr-mode-codex-deep-review.md)
(PR mode no longer needs to disable a droid escalation — none exists) and
[ADR 0034](./0034-pi-in-tree-read-lane.md) (pi's exemption from the runtime droid
escalation is moot). Plan: `docs/plans/2026-10-06-withdraw-droid.md`.

## Context

droid (Factory) served four roles: a dispatch lane (`--cli droid`), the second entry
of every shipped route, a runtime escalation target when codex/agy failed (litmus
commit mode, council voices), and a one-voice rescue for a failed blueprint reviewer.
It is uninstalled on both operator hosts (verified 2026-10-06), so every one of those
paths was already dead in practice: routes fell through, escalations found no binary,
and a failed blueprint reviewer was already recorded `runtime-failed` with PASS
withheld (#355). The code spanned 49 files, including two whole
test files and a cross-provider containment rule (grok/pi/prose must never escalate
to droid) that existed only because the escalation did.

## Decision

Remove droid entirely. A stale `droid` value is a removed CLI, handled exactly like
`opencode` (ADR 0051): warned and skipped in routes and defaults, `unsupported:droid`
from `BUSDRIVER_REVIEW_CLI`. A failed Codex falls straight to `BUILTIN_FALLBACK`
(exit 3) or exit 124; a failed council voice drops and is recorded `(unavailable)`;
a failed blueprint reviewer stays `runtime-failed`.

## Alternatives

- **Keep droid code dormant.** Rejected: it cannot run on either host, and its
  containment rules (which CLIs may escalate where) are review surface with no
  function.
- **Replace droid with another fallback CLI.** Rejected: no request for one, and
  every fallback re-sends a prompt to a different third party than the operator
  chose — the exact hazard the escalation exemptions were written to contain.

## Consequences

- One fewer external provider in every data-boundary argument.
- No automatic second chance for a transient reviewer failure: blueprint withholds
  PASS until a re-run; council proceeds with fewer voices. This was already the
  behaviour on both hosts.
- The `codex-droid-fallback` telemetry event and the `droid-fallback` dispatch status
  are retired; historical log entries keep them.

## Revisit trigger

A fallback reviewer becomes desirable again (e.g. sustained Codex outages blocking
commits). Add it as a new, explicitly reviewed route entry — not by restoring
escalation.
```

- [ ] **Step 2: Amendment lines.** Follow each ADR's existing amendment convention.
  - `docs/adr/0006-pr-mode-codex-deep-review.md` carries amendments as a blockquote under the title. Add a second blockquote directly after the ADR 0051 one, separated by a blank line:

```markdown
> **Amended by [ADR 0053](./0053-withdraw-droid.md) (2026-10-06)** — droid was withdrawn; PR mode no longer has a droid escalation to disable.
```

  - `docs/adr/0034-pi-in-tree-read-lane.md` carries amendments as sentences at the end of its `## Status` paragraph. Append a new line after the ADR 0052 sentence:

```markdown
Amended by ADR 0053 (2026-10-06): droid was withdrawn, so pi's exemption from the runtime droid escalation is moot.
```

- [ ] **Step 3: Commit** (4 paths). Before committing, `bash scripts/ci/run-shell-tests.sh` must exit 0.

```bash
git add docs/adr/0053-withdraw-droid.md docs/adr/0006-pr-mode-codex-deep-review.md docs/adr/0034-pi-in-tree-read-lane.md docs/plans/2026-10-06-withdraw-droid.md
git commit -m "docs(adr): ADR 0053 withdraw the droid CLI; amend 0006 and 0034"
```

---

### Task 8: Acceptance verification

- [ ] **Step 1: No live droid references.**

Run:
```bash
git grep -n -i droid -- . ':!docs/adr/0006-*' ':!docs/adr/0027-*' ':!docs/adr/0034-*' ':!docs/adr/0040-*' ':!docs/adr/0053-*' \
  ':!docs/plans' ':!docs/plan-history' ':!docs/plan-status' ':!CHANGELOG.md' \
  ':!agents/a11y-architect.md' ':!package-lock.json' | grep -v -i android
```

This is a substring match on purpose, not `-w`: `_` is a word character, so `-w` misses droid inside identifiers such as `LITMUS_CODEX_DROID_FALLBACK_DISABLED`, `DROID_AUTO_LEVEL`, `DROID_RESCUE` and `should_escalate_to_droid`, wherever they sit (tests and docs included).

Expected, with only these allowed survivors:
- `scripts/lib/resolve-cli.sh`: the removed-CLI set entries (6 sites) and the `(droid was withdrawn, ADR 0053)` comments from Task 2 Step 4;
- `tests/test-review-boundaries.sh` §9 and §9b;
- `tests/test-no-auditor-lane.sh`: the `ALLOW_LINES` entries and the removed-set self-tests from Task 2 Step 15b;
- `skills/codex-goal-handover/SKILL.md`: the one historical `(council Researcher, then droid)`;
- `docs/observability.md`: the retired `codex-droid-fallback` event row from Task 5 Step 4.

Anything else is a miss: fix it and amend the relevant commit's follow-up, without rewriting a pushed commit.

- [ ] **Step 2: Full shell suite, pytest, vitest, lint, integrity.**

Run each and check its exit status (non-zero = failure): `bash scripts/ci/run-shell-tests.sh`, then `scripts/test-python.sh`, then `npm test --silent`, then `shellcheck hooks/gate-scripts/*.sh scripts/hooks/*.sh` (the system binary; shellcheck is not an npm dependency), then `./scripts/gate-integrity.sh --check`.
Expected: every command exits 0.

If a test outside the files listed in this plan fails, read why before touching it. It may be a droid reference the scoping missed; fix that inline and note it in the PR body.

- [ ] **Step 3: Mutation check (the new guards can fail).** Do this in a throwaway copy (`copy=$(mktemp -d) && git -C <worktree> archive HEAD | tar -x -C "$copy"`); never edit the real tree.
  - (i) Re-insert `                                is_trusted_review_cli_available droid && /usr/bin/printf '%s\n' "droid" && return` as the second line of the `council.pragmatist)` arm in `"$copy/scripts/lib/resolve-cli.sh"`. `bash "$copy/tests/test-review-boundaries.sh"` must then FAIL with `(e) council.pragmatist with droid and codex installed → 'droid'`.
  - (ii) Starting from a fresh copy, append `should_escalate_to_droid() { :; }` to `"$copy/scripts/lib/resolve-cli.sh"`. §9b must then FAIL.
  - (iii) Starting from a fresh copy, delete ` || "$default_fallback" == "droid"` from the `defaults.fallback` removed-CLI check in `"$copy/scripts/lib/resolve-cli.sh"`. §9 must then FAIL on `(g) defaults.fallback=droid → 'droid'`.
  - (iv) Starting from a fresh copy, delete the `elif [[ -n "$esc" && "$esc" != "null" ]]; then` branch (its comment and `final="runtime-failed"` line) from `derive_coverage` in `"$copy/skills/blueprint-review/scripts/run-design-review-loop.sh"`. `bash "$copy/tests/test-blueprint-review-state.sh"` must then FAIL on `runtime_escalated_from on a fresh PASS → runtime-failed`.
  - (v) Starting from a fresh copy, `chmod 000 "$copy/skills"`. §9b must report `scan failed to run`, not pass. Restore with `chmod 755` before deleting the copy.

  In every case the unmodified copy passes. Run it once first as a control.

---

## Out of scope

- Uninstalling anything: droid is already gone from both hosts.
- **Operator config (after merge):**
  - **um:** `~/.claude/busdriver.json` routes still list `"droid"` second in all 7 routes. After merge, back the file up and strip it: `jq '.routes |= map_values(map(select(. != "droid")))'`. Until then, um's resolver just warns and skips the entry, so nothing breaks.
  - **Mac:** already clean.
- Rewriting historical ADRs, plans or the changelog.

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
