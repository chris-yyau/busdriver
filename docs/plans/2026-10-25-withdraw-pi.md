# Withdraw pi — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use busdriver:subagent-driven-development (recommended) or busdriver:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove pi from busdriver entirely: the `pi-read` dispatch lane, its resolver, pins and tests, the unbuilt pi-replacement program, and every live instruction that routes work to pi.

**Architecture:** Deletion, done in an order where each commit leaves the suite green. Three steps: first move the coverage that is only reachable through pi onto lanes that stay (grok's `--model` refusal for `skipped`, `writing_prose` for the shared config reader); then delete the dispatcher half (every caller); then delete the resolver half, which by then has no caller left. Docs, the advisory hook, the ADR and plan bookkeeping follow, then a structural guard, so no pi code path can come back unnoticed. The model is the droid withdrawal (`docs/plans/2026-10-06-withdraw-droid.md`, ADR 0053).

**Tech Stack:** bash (dispatch.sh, resolve-cli.sh, shell gate-tests), Node/vitest (`scripts/hooks/pre-read-size-advisory.js`), Markdown (skills, ADRs, plans).

**Global Constraints:**
- Work in worktree `.claude/worktrees/bd-withdraw-pi`, branch `chore/withdraw-pi`, base `origin/main` = `d387639d` (the recovery anchor the ADR records).
- Every commit leaves `bash scripts/ci/run-shell-tests.sh` exit 0, and `npm test` too for commits that touch JS. A task's commit step says which.
- Line numbers below are as of `d387639d`. Locate every edit by its quoted anchor text, not by number, and make deletions inside one file **bottom-up** so earlier anchors do not move.
- Any edit under `scripts/hooks/**` or `hooks/gate-scripts/**` needs `./scripts/gate-integrity.sh --update` in the same commit (`.gate-integrity.lock`, #742).
- No new dependencies, and no behaviour change to the codex, agy, agy-prose or grok arms. The `skipped` status, the `--cli all` batch contract and `TIMEOUT=600` stay exactly as they are. Only the comments that justify them by pi change.
- `docs/adr/*` and the historical plans (other than the edits Tasks 7 and 9 name) and `CHANGELOG.md` stay as they are. They are records.
- Commit messages are Conventional Commits and end with the Co-Authored-By line from the session.
- **Do not tick this plan's checkboxes while executing it.** This file is under `docs/plans/`, so any write to it re-arms the design-review gate and blocks every later task. Track progress outside the repo, in the session's work-state list.

---

## Evidence (why, recorded in the ADR)

- `~/.claude/homunculus/dispatch-log.jsonl`, 2026-09-25 to 2026-10-25: 144 `pi-read` entries, 136 `skipped`, 8 `success`. All 8 successes are on 2026-10-05, the ADR 0052 certification day. Since then there have been 0 successful reads.
- Installed pi is `1.2.0` (`~/.local/bin/pi --version`, 2026-10-25), but `BUSDRIVER_PI_PROBED_VERSION="1.0.1"`. The arm refuses any other version, so every pi-read dispatch since the 2026-10-14 upgrade was refused. ADR 0042 records the same silent outage after an earlier upgrade. Nobody noticed, which is the usage signal.
- Same window, direct agent calls: grok 18, agy-prose 12, agy 6, pi-read 5. That is despite `.claude/CLAUDE.md` making pi-read the mandated first stop for reads.
- Cost: the arm is `dispatch.sh:1337-2196` (about 860 of 2739 lines), `tests/test-pi-dispatch-arm.sh` is 1859 lines, there are two version pins with a live re-certification ritual, and ADR 0052 accepted Google ToS/account-ban risk from pi-antigravity's impersonated OAuth client.
- The pi-replacement program (`docs/plans/2026-08-23-pi-replacement.md`) went 13 review rounds without converging. Only slice 0 (a rename) landed. Its 6-lite predicate "is not yet a design" (0827 plan item 10).
- Council, 2026-10-25: all five voices chose full withdrawal. Two conditions came out of it: retire the credentials, not just the code, and move shared coverage before deleting tests.

## File Structure

| Path | Change | Responsibility after |
|---|---|---|
| `tests/test-pi-dispatch-arm.sh` | Delete | — |
| `scripts/ci/shell-test-durations.tsv` | Modify: drop the `test-pi-dispatch-arm` row | shard weights |
| `tests/test-dispatch-skipped-status.sh` | Modify: runtime cases driven by grok | `skipped` status + batch exit contract |
| `tests/test-lane-model-config.sh` | Modify: reader properties driven by `writing_prose` | shared lane-model reader trust boundary |
| `scripts/lib/resolve-cli.sh` | Modify: drop the pi reader arms, the `slash` grammar, `resolve_pi_read_model`, the install hint | resolver library |
| `tests/test-agy-dispatch-arm.sh` | Modify: drop §4, add §1b (pi-read refused), update the whitelist anchor | agy arm + withdrawn-lane refusals |
| `skills/dispatch-cli/scripts/dispatch.sh` | Modify: drop the arm, the floor, pins, shim, `_pi_available`, discovery entry, flags; add a migration refusal | dispatcher |
| `tests/test-agy-prose-lane.sh`, `tests/test-grok-sandbox-arm.sh` | Modify: anchors and comments | unchanged scope |
| `scripts/hooks/pre-read-size-advisory.js`, `__tests__/pre-read-size-advisory.test.ts`, `.gate-integrity.lock` | Modify: advisory step 2 text | read-size advisory |
| `.claude/CLAUDE.md`, `README.md`, `skills/dispatch-cli/SKILL.md`, `skills/writing-prose/SKILL.md` | Modify | docs |
| `tests/test-dispatch-timeout-and-failure-log.sh`, `tests/test-trusted-review-cli.sh`, `tests/test-no-auditor-lane.sh` | Modify: comments only | unchanged |
| `tests/test-review-boundaries.sh` | Modify: add §9c structural guard | no pi code path survives |
| `docs/adr/0060-withdraw-pi.md` | Create | decision record |
| `docs/adr/0034-…`, `0042-…`, `0052-…` | Modify: status line only | records |
| `docs/plans/2026-08-23-pi-replacement.md`, `…-slice-0.md`, `docs/plans/2026-08-27-pipeline-final-plan.md` | Modify: withdrawal notes | records |

---

### Task 1: Re-home the coverage that only pi could reach (green against current code)

Both rewrites pass against `d387639d`, before any pi code is removed. That is the point of doing them first: the coverage stops depending on pi while pi still exists. Then deleting pi cannot silently take the coverage with it.

**Files:**
- Modify: `tests/test-dispatch-skipped-status.sh`
- Modify: `tests/test-lane-model-config.sh`

**Interfaces:**
- Consumes: the grok arm's existing `--model` refusal (`dispatch.sh:2240` sets `_grok_model_rejected=1` and `_grok_refused=1` before any launch, and `:2571`'s neighbour `[[ "${_grok_refused:-0}" == "1" ]] && status="skipped"`). Also `resolve_writing_prose_model`, `_BD_WRITING_PROSE_MODEL`, and `_bd_read_lane_model "$HOME" <default> writing_prose|writing_prose_raw` (`resolve-cli.sh:1189-1290`, `:1449-1451`).
- Produces: no new symbols.

- [ ] **Step 1: `tests/test-dispatch-skipped-status.sh` — header.** Replace lines 10-27 (from `# The premise being tested:` through `# LLM call — a test suite must not spend quota or depend on the network.`) with:

```bash
# The premise being tested: a CLI that refuses to run on a DETERMINISTIC
# precondition is not a CLI that ran and failed. Merging the two as `error` let
# one ineligible voice fail an entire `--cli all` batch for every other voice.
#
# WHY THE RUNTIME CASES ARE DRIVEN THROUGH grok: grok rejects `--model`
# (grok-build accepts none) and records that as a refusal BEFORE any launch,
# preflight or network call — deterministic and offline on every host, with or
# without grok installed (a missing grok is refused by its preflight, to the same
# status). grok also joins every readonly `--cli all` batch without a PATH probe,
# so the batch cases need no host-specific gate. The other voices are PATH stubs,
# the pattern already used by tests/test-cli-retry.sh Part C.
#
# EVERY dispatch below passes `--model noproviderprefix`: it is the forcing
# mechanism for grok, and the stubs ignore it.
```

- [ ] **Step 2: same file — interpreter note.** Replace lines 34-39 (`# Run the script under the bash running THIS test,` … `RUN_BASH="$BASH"`) with:

```bash
# Run the script under the bash running THIS test, captured before BASE_PATH
# narrows anything. BASE_PATH exists to hide other CLIs from `--cli all`
# selection; letting it choose the interpreter too would select macOS's
# /bin/bash 3.2, on which dispatch.sh is not verified.
RUN_BASH="$BASH"
```

- [ ] **Step 3: same file — PATH note and gate helper.** In the `BASE_PATH` comment (lines 63-68), replace the last two comment lines `# the batch cases. pi is unaffected either way: it resolves from password-db` and `# home candidates, not PATH.` with `# the batch cases. grok is unaffected either way: it runs from a pinned path.`. Then delete the whole `pi_selectable()` helper and its comment (lines 71-89, from `# Is pi selectable for \`--cli all\`?` through the closing `}`).

- [ ] **Step 4: same file — the bash gate message.** Replace line 94 with:

```bash
  skip "running under bash ${BASH_VERSINFO[0]} — dispatch.sh is only verified on bash >= 4; runtime cases need bash >= 4"
```

- [ ] **Step 5: same file — cases 1-4.** Replace lines 97-141 (from `# ── 1. Single-CLI:` through the `fi` that closes `if pi_selectable; then`) with:

```bash
# ── 1. Single-CLI: an explicitly requested voice that cannot run is a FAILURE.
#      The whole request was for that voice; there is nothing left to succeed.
O="$TMP/single.out"
PATH="$BASE_PATH" "$RUN_BASH" "$DISPATCH" --cli grok --model noproviderprefix --prompt p >"$O" 2>&1
rc=$?
{ [[ "$rc" -ne 0 ]] && grep -q "grok → skipped" "$O"; } \
  && ok "explicit --cli grok that cannot run → status skipped, exit nonzero" \
  || bad "explicit --cli grok → skipped + nonzero (rc=$rc, out=[$(tr -d '\n' <"$O" | tail -c 200)])"

# ── 2. Batch: one skipped voice must NOT fail the batch for the others.
#      This is the reported bug (#594).
mk_codex_ok
O="$TMP/batch-ok.out"
PATH="$BASE_PATH" BUSDRIVER_CLI_RETRIES=0 BUSDRIVER_CLI_RETRY_DELAY=0 \
  "$RUN_BASH" "$DISPATCH" --cli all --model noproviderprefix --timeout 20 --prompt p >"$O" 2>&1
rc=$?
{ [[ "$rc" -eq 0 ]] && grep -q CODEX_OK "$O" && grep -qi "GROK  *(skipped" "$O"; } \
  && ok "--cli all: skipped grok does not fail a batch another voice completed" \
  || bad "--cli all: skipped grok failed the batch (rc=$rc, out=[$(tr -d '\n' <"$O" | tail -c 300)])"

# ── 3. ...but `skipped` must not MASK a real failure either. Same batch
#      shape, codex now failing hard → the batch still reports failure.
mk_codex_fail
O="$TMP/batch-fail.out"
PATH="$BASE_PATH" BUSDRIVER_CLI_RETRIES=0 BUSDRIVER_CLI_RETRY_DELAY=0 \
  "$RUN_BASH" "$DISPATCH" --cli all --model noproviderprefix --timeout 20 --prompt p >"$O" 2>&1
rc=$?
[[ "$rc" -ne 0 ]] \
  && ok "--cli all: a genuinely failing voice still fails the batch" \
  || bad "--cli all: real failure was masked (rc=$rc)"

# ── 4. A batch in which EVERY voice was skipped ran nothing, and nothing
#      must never report success. No codex stub → grok is the only candidate.
rm -f "$STUB/codex"
O="$TMP/batch-allskip.out"
PATH="$BASE_PATH" BUSDRIVER_CLI_RETRIES=0 BUSDRIVER_CLI_RETRY_DELAY=0 \
  "$RUN_BASH" "$DISPATCH" --cli all --model noproviderprefix --timeout 20 --prompt p >"$O" 2>&1
rc=$?
{ [[ "$rc" -ne 0 ]] && grep -q "every CLI in the batch was skipped" "$O"; } \
  && ok "--cli all: an all-skipped batch fails (nothing ran ≠ success)" \
  || bad "--cli all: all-skipped batch reported success (rc=$rc, out=[$(tr -d '\n' <"$O" | tail -c 300)])"
```

- [ ] **Step 6: same file — case 5 comment.** Replace lines 146-148 (`#      and reported failure. On a pi-ful host this repeats case 2's shape; on a` … `#      clean-batch guard.`) with `#      and reported failure. grok is skipped (it rejects --model), so codex is`, `#      the one voice that runs: the pure clean-batch guard.` (two comment lines).

- [ ] **Step 7: same file — static checks 7 and 8.** In case 7's comment, replace `#      inert while every runtime case above still passed on a pi-less host.` with `#      inert while every runtime case above still passed.`. Leave case 8 (lines 179-193, `_pi_jail_survived`) **as is for now**. It pins code that still exists. Task 2 deletes it together with that code.

- [ ] **Step 8: Run it against the unchanged dispatcher.**

Run: `bash tests/test-dispatch-skipped-status.sh`
Expected: exit 0. Cases 1-4 report ✅ with `grok` in their text, and no case reports SKIP (other than the bash<4 gate on a 3.2 shell). If case 2 fails only on its `GROK  *(skipped` match, print the real batch summary: `s="$(mktemp -d)"; printf '#!/usr/bin/env bash\necho CODEX_OK\n' > "$s/codex"; chmod +x "$s/codex"; PATH="$s:/usr/bin:/bin:/usr/sbin:/sbin" bash skills/dispatch-cli/scripts/dispatch.sh --cli all --model x --timeout 20 --prompt p 2>&1 | grep -i grok; rm -rf "$s"`. Fix the regex to match the real text, never the other way round.

- [ ] **Step 9: `tests/test-lane-model-config.sh` — header and harness.** Replace line 7 `# (_bd_read_lane_model) behind resolve_pi_read_model and the agy lanes.` with `# (_bd_read_lane_model) behind resolve_writing_prose_model (the agy-prose lane).`. Replace the block from `# ── Executable: resolve_pi_read_model under a fake HOME ──────────` through the line `eq "$PI_SHIM_DEFAULT" "" "dispatch.sh pi shim fails closed when the trusted resolver is missing"` (lines 35-63) with:

```bash
# ── Executable: resolve_writing_prose_model under a fake HOME ────
# The reader's trust-boundary properties are lane-independent; writing_prose is
# the one lane left that consumes it (the `bare` grammar).
FAKE_HOME="$(mktemp -d)"
trap 'rm -rf "$FAKE_HOME"' EXIT
mkdir -p "$FAKE_HOME/.claude"

# Run in a subshell with HOME redirected so the real user config is untouched.
resolve() {  # <json-or-empty> → stdout model, stderr dropped unless $2=keep-stderr
  if [[ -n "$1" ]]; then printf '%s' "$1" > "$FAKE_HOME/.claude/busdriver.json"
  else rm -f "$FAKE_HOME/.claude/busdriver.json"; fi
  ( HOME="$FAKE_HOME" BUSDRIVER_STATE_DIR=".claude"
    # shellcheck source=/dev/null
    source "$LIB"
    if [[ "${2:-}" == "keep-stderr" ]]; then resolve_writing_prose_model 2>&1
    else resolve_writing_prose_model 2>/dev/null; fi
    printf '%s' "$_BD_WRITING_PROSE_MODEL" )
}

# Every unconfigured/rejected case below resolves to the empty string.
DEFAULT=""

# The dispatch-side library-missing shim must fail closed to empty (= agy's own
# model), never to a provider-selecting value.
SHIM_LINE="$(grep -E 'resolve_writing_prose_model\(\) \{ _BD_WRITING_PROSE_MODEL=' "$DISPATCH")"
if [[ "$(printf '%s\n' "$SHIM_LINE" | grep -c .)" -eq 1 && "$SHIM_LINE" == *'_BD_WRITING_PROSE_MODEL=""; }'* ]]; then
  ok "dispatch.sh prose shim exists once and resolves empty when the trusted resolver is missing"
else
  fail "dispatch.sh prose shim missing, duplicated, or not empty: [$SHIM_LINE]"
fi
```

- [ ] **Step 10: same file — value cases.** Replace the block from `eq "$(resolve '')"` through `eq "$(resolve '{"pi_read":{"model":true}}')" …` (lines 65-85) with:

```bash
eq "$(resolve '')"                                          "$DEFAULT"   "no config → empty"
eq "$(resolve '{}')"                                        "$DEFAULT"   "empty config → empty"
eq "$(resolve '{"writing_prose":{"model":"fixture-model"}}')" \
   "fixture-model"                                                       "configured model honored"
eq "$(resolve '{"writing_prose":{"model":"fixture-model:free"}}')" \
   "fixture-model:free"                                                  "colon-tagged variant accepted"
eq "$(resolve '{"writing_prose":{"model":"fixture-model@20250514"}}')" \
   "fixture-model@20250514"                                              "at-tagged variant accepted"
eq "$(resolve '{"writing_prose":{"model":"--dangerously-x"}}')" "$DEFAULT" "leading-dash rejected"
eq "$(resolve '{"writing_prose":{"model":"a b"}}')"         "$DEFAULT"   "whitespace rejected"
eq "$(resolve '{"writing_prose":{"model":"provider/id"}}')" "$DEFAULT"   "provider/ prefix rejected (bare grammar)"
eq "$(resolve 'not json at all')"                           "$DEFAULT"   "corrupt config → empty"
# A JSON number/boolean must not be stringified by `jq -r` and forwarded to
# argv — jq and the python3 fallback must agree (PR #687 Codex finding).
eq "$(resolve '{"writing_prose":{"model":123}}')"           "$DEFAULT"   "numeric config value degrades to default"
eq "$(resolve '{"writing_prose":{"model":true}}')"          "$DEFAULT"   "boolean config value degrades to default"
```

- [ ] **Step 11: same file — state-dir and BASH_FUNC cases.** Apply the same substitution to every remaining case from the traversal block (line 87) through the project-config case (line 166):
  - `'{"pi_read":{"model":"zenmux/evil/model"}}'` → `'{"writing_prose":{"model":"evil-model"}}'`
  - `'{"pi_read":{"model":"zenmux/deepseek/deepseek-v4-pro"}}'` → `'{"writing_prose":{"model":"fixture-model"}}'`
  - `resolve_pi_read_model` → `resolve_writing_prose_model`, and `$_BD_PI_READ_MODEL` → `$_BD_WRITING_PROSE_MODEL`
  - in the BASH_FUNC case, every `zenmux/evil/model` → `evil-model`, and the expected `"zenmux/deepseek/deepseek-v4-pro"` → `"fixture-model"`
  - in the python-fallback case, the expected value becomes `"fixture-model"`
  - the invalid-value case: `'{"pi_read":{"model":"-x"}}'` → `'{"writing_prose":{"model":"-x"}}'`

  Replace the two pi-only no-jq cases and their comment (lines 136-147, from `# Same harness over the three pi-read arms` through the second `eq "$got" "opencode-go/glm-5.2|0" …`) with one case for the presence probe's `pykey`:

```bash
# Same no-jq harness over the presence probe: with jq present a wrong `pykey` is
# never consulted, so only this pass can see one.
printf '%s' '{"writing_prose":{"model":"provider/id"}}' > "$FAKE_HOME/.claude/busdriver.json"
got="$( HOME="$FAKE_HOME" bash -c 'source "$0"; printf "%s" "$(_bd_read_lane_model "$HOME" "" writing_prose_raw)"' "$NOJQ" )"
eq "$got" "provider/id" "no-jq: writing_prose_raw reports the raw value (pykey honoured)"
```

- [ ] **Step 12: same file — the P1 shim case.** In the block from `# P1 regression: an inherited/exported function named resolve_pi_read_model` through `eq "$got" "" "exported resolve_pi_read_model cannot bypass the library-missing shim (P1)"`, substitute `resolve_pi_read_model` → `resolve_writing_prose_model`, `_BD_PI_READ_MODEL` → `_BD_WRITING_PROSE_MODEL`, and the poisoned value `'zenmux/evil/model'` → `'evil-model'`. The awk anchor becomes `/resolve_writing_prose_model\(\) \{/ { seen = 1 }`. Today the prose shim sits in the same `if … fi` block as the pi shim, so the extracted preamble is the same span.

- [ ] **Step 13: same file — sweep comment.** (The retired-`pi_read`-key case belongs with the resolver change. It would fail against today's code, so it lands in Task 3 Step 4.) In the long `# ── No model name in live files` comment, change `` Every configurable model key (`.pi_read.model`, `.writing_prose.model`) ships `` to `` The configurable model key (`.writing_prose.model`) ships ``.

- [ ] **Step 14: Run and commit.**

Run: `bash tests/test-lane-model-config.sh && bash tests/test-dispatch-skipped-status.sh && bash scripts/ci/run-shell-tests.sh`
Expected: all exit 0. `grep -c 'pi_read\|resolve_pi_read_model\|_BD_PI_READ' tests/test-lane-model-config.sh` prints `0`. The retired-key case that names `pi_read` is added later, in Task 3 Step 4. The default-constant check this task drops (`BUSDRIVER_PI_READ_MODEL_DEFAULT`) is covered for good by Task 6's §9c pattern (`PI_READ`).

```bash
git add tests/test-dispatch-skipped-status.sh tests/test-lane-model-config.sh
git commit -m "test: drive skipped-status and lane-reader coverage through lanes that stay (ADR 0060)"
```

---

### Task 2: dispatch.sh — remove the pi-read lane

**Files:**
- Modify: `skills/dispatch-cli/scripts/dispatch.sh`
- Delete: `tests/test-pi-dispatch-arm.sh`
- Modify: `scripts/ci/shell-test-durations.tsv`
- Modify: `tests/test-dispatch-skipped-status.sh` (case 8), `tests/test-agy-dispatch-arm.sh` (whitelist anchor + new §1b), `tests/test-agy-prose-lane.sh`, `tests/test-grok-sandbox-arm.sh`, `tests/test-review-boundaries.sh` (the pi-probe guard count and the (h) comment)

**Interfaces:**
- Consumes: the resolver library unchanged. Task 3 removes its pi half only after this task has removed every caller.
- Produces: `--cli` accepts `codex|agy|agy-prose|grok|both|all|auto`. `--cli pi` and `--cli pi-read` exit 1 with the message below, and no CLI is invoked. The `REPORT_NAME` vocabulary is `codex|agy|agy-prose|grok`.

Edit bottom-up, in this order:

- [ ] **Step 1: REPORT_NAME whitelist (`:2709`).** `        codex|agy|agy-prose|grok|pi-read) ;;` → `        codex|agy|agy-prose|grok) ;;`.

- [ ] **Step 2: status ladder (`:2553-2571`).** Replace from `    # \`skipped\` — the voice never ran. Assigned LAST so it wins over the` through `    [[ "${_pi_setup_failed:-0}" == "1" && "${_pi_jail_survived:-0}" != "1" ]] && status="skipped"` with:

```bash
    # `skipped` — the voice never ran. Assigned LAST so it wins over the
    # error/timeout classification above: a deterministic precondition failure
    # is not an attempt that failed, it is an attempt that was refused before it
    # began, and the two deserve different consequences. Keeping them merged as
    # `error` is what let ONE ineligible voice fail a whole `--cli all` batch for
    # every other voice (#594). An EXPLICIT single-CLI request still fails,
    # because there the voice that cannot run IS the request.
```

  Then replace the next comment's first line `    # A grok preflight refusal is the second arm wired to this status: the voice` with `    # A grok refusal (preflight, or a --model grok cannot accept) is wired to this status: the voice`.

- [ ] **Step 3: retry guard (`:2511-2518`).** Replace from `    # The setup-failure flag is checked FIRST and wins outright. It is set only by` through `    if [[ "${_pi_setup_failed:-0}" != "1" ]] \` / `       && [[ "${_grok_refused:-0}" != "1" ]] \` with:

```bash
    # The refusal flag is checked FIRST and wins outright. It is set only for
    # failures that are deterministic by construction, so no amount of retrying
    # helps — and the text classifier below cannot be trusted to agree, because
    # refusal messages quote operator-supplied values.
    if [[ "${_grok_refused:-0}" != "1" ]] \
```

  Keep the following `       && { [[ ! -s "$outfile" ]] || _is_transient_cli_error < "$outfile"; }; then` line unchanged.

- [ ] **Step 4: grok arm comment (`:2219`).** `            # A REFUSAL (skipped), like pi-read with no model configured, and it` → `            # A REFUSAL (skipped), not a failure, and it`.

- [ ] **Step 5: delete the arm.** Delete from the line `        pi-read)` (`:1337`) through the `            fi ;;` that is immediately followed by `        grok)` (`:2196`). Afterwards `sed -n '/^        agy)/,/^        grok)/p'` must end with the agy arm's `fi ;;` directly followed by `        grok)`.

- [ ] **Step 6: dispatch_one locals (`:1086-1111`).** Delete the `_pi_setup_failed` comment and declaration (from `    # Cleared per DISPATCH, not per arm. Only the pi arm sets it, but the retry` through `    local _pi_setup_failed=0`). Delete the `_pi_jail_survived` comment and declaration (from `    # Set ONLY where a teardown ran and could not confirm the jail was removed,` through `    local _pi_jail_survived=0`). In the `_grok_refused` comment, change `    # Same shape again, for grok's sandbox preflight. A refusal there is a` to `    # Cleared per DISPATCH, for grok's refusals. A refusal there is a`.

- [ ] **Step 7: Hindsight comment (`:1078-1079`).** Replace `… and keeps the session-start context read. pi-read and grok launch under \`env -i\` and do not see` / `    # these; grok sets its own, and pi's memory wiring is left to the 0827 plan's item 10.` with `… and keeps the session-start context read. grok launches under \`env -i\` and does not see` / `    # these; it sets its own.`.

- [ ] **Step 8: failure-archive comment (`:917`).** `    # 465s pi failure whose cause is now unrecoverable.` → `    # 465s dispatch failure whose cause is now unrecoverable.`.

- [ ] **Step 9: `--cli all` discovery (`:863-889`).** Replace from `# Handle --cli all: discover all available supported CLIs (candidates codex,` through the loop's closing `done` with:

```bash
# Handle --cli all: discover all available supported CLIs (candidates codex,
# agy, grok; the cap of 3 equals the list). When MODE=auto,
# grok is excluded — the grok adapter rejects auto mode at dispatch_one
# time, and including it here would kill the entire batch mid-stream after
# the other CLIs had already launched in parallel.
if [[ "$CLI" == "all" ]]; then
    ALL_CLIS=()
    for c in codex agy grok; do
        [[ "$c" == "grok" && "$MODE" == "auto" ]] && continue
        # grok is included WITHOUT an ambient-PATH probe, for the same reason the
        # direct `--cli grok` gate no longer has one: it runs from a pinned path,
        # so a pinned-only install (~/.grok/bin not on PATH) would be silently
        # dropped from the batch and never reach its own preflight. Including it
        # costs nothing when it is unusable — the preflight refuses with a named
        # reason and the voice is marked `skipped`, which is exactly how a batch
        # is meant to treat a voice that cannot run. Reported by Codex on PR #704.
        if [[ "$c" == "grok" ]]; then ALL_CLIS+=("$c"); continue; fi
        _has_cli "$c" && ALL_CLIS+=("$c")
        [[ ${#ALL_CLIS[@]} -ge 3 ]] && break
    done
```

  The `if [[ ${#ALL_CLIS[@]} -eq 0 ]]` block after it is unchanged.

- [ ] **Step 9b: prose-model comment (`:791`).** `        # pasted from the pi config, a typo). Empty is this lane's NORMAL "use` → `        # pasted from another lane's config, a typo). Empty is this lane's NORMAL "use`.

- [ ] **Step 10: agy-prose comments (`:576`, `:591`).** `# 2026-10-10.) Reach for \`pi\` if you need an enforced boundary.` → `# 2026-10-10.) Nothing in this dispatcher offers an enforced write boundary for agy.`. `# Both apply equally to \`pi\` and the reviewer slots. The lane's own` → `# Both apply equally to the reviewer slots. The lane's own`.

- [ ] **Step 11: validator (`:551-559`).** Replace the `elif [[ "$CLI" == "pi" ]]; then` branch (its comment and `echo`) and the enum branch with:

```bash
elif [[ "$CLI" == "pi" || "$CLI" == "pi-read" ]]; then
    # Exact match only. Withdrawn (ADR 0060): a stale caller gets a migration
    # message instead of the generic "invalid --cli value", and nothing runs.
    echo "busdriver: --cli $CLI was withdrawn (ADR 0060). Read code with codegraph_explore or an Explore subagent, or dispatch --cli codex / --cli agy." >&2; exit 1
elif [[ "$CLI" != "codex" && "$CLI" != "agy" && "$CLI" != "agy-prose" && "$CLI" != "grok" && "$CLI" != "both" && "$CLI" != "all" ]]; then
    echo "Error: Invalid --cli value '$CLI'. Must be codex|agy|agy-prose|grok|both|all|auto." >&2; exit 1
fi
```

  This check sits **after** `PROMPT_FILE` is written (`:449-455`), which is existing behaviour for every invalid value: the EXIT trap removes the file. Do not move the validator. The Interfaces line above means no CLI is invoked, and §1b tests exactly that.

- [ ] **Step 12: `_pi_available` (`:466-536`).** Delete from `# pi is a special case: dispatch_one's pi arm resolves the binary from` through the closing `}` of `_pi_available()`.

- [ ] **Step 13: help text (`:394-406`).** `dispatch.sh — Dispatch tasks to Codex, Antigravity (agy), Grok, or pi-read CLI` → `dispatch.sh — Dispatch tasks to Codex, Antigravity (agy), or Grok CLI`. `  --cli     codex|agy|agy-prose|grok|pi-read|both|all|auto  (default: auto)` → `  --cli     codex|agy|agy-prose|grok|both|all|auto  (default: auto)`. Delete the four `NOTE: \`pi-read\` is the repo-READING lane …` lines (`:403-406`).

- [ ] **Step 14: TIMEOUT comment (`:355-359`).** Replace `# 600, raised from 300. The pi arm READS THE TREE, so its work scales with the` … `# unreliable model when it is really a misconfigured number.` with:

```bash
# 600, raised from 300 when an in-tree read lane (pi-read, withdrawn in ADR 0060)
# measured successful traces at 315s and 307s — both would have been killed by
# the old default. Kept: a cap that kills its own successful runs reads as an
# unreliable model when it is really a misconfigured number.
```

- [ ] **Step 15: pins and shim.** Delete `:272-287` (from `# The pi version whose tool-permission behaviour this repo actually probed (see` through `BUSDRIVER_PI_ANTIGRAVITY_PROBED_VERSION="0.9.0"`). In the library-missing block (`:218-227`), delete the two lines `  _BD_PI_READ_MODEL=""` and `  resolve_pi_read_model() { _BD_PI_READ_MODEL=""; }`. The `_BD_WRITING_PROSE_MODEL` shim and its comment stay.

- [ ] **Step 16: interpreter floor (`:95-182`).** Delete from `# ── Interpreter floor (pi lane) — before \`set -euo pipefail\`, after the` through the `fi` that closes `if (( BASH_VERSINFO[0] < 4 )); then`. It only guarded `--cli pi-read` and `--cli all`'s pi member (#595). No other arm uses a bash-4 construct. At `d387639d` both of these scans of the non-arm lines were empty: `grep -nE 'declare -A|mapfile|readarray|,,\}|\^\^\}|@Q\}|coproc|wait -n'` and `grep -nE 'local -n|declare -n|\[\[ -v |&>>'`. Steps are bottom-up, so by this step the arm (Step 5) and `_pi_available` (Step 12) are already gone. Re-run both scans over the **whole file** before deleting, with no line range. The base-commit numbers no longer apply. If either finds a hit, keep a floor scoped to whatever needs it rather than deleting this one.

- [ ] **Step 17: header comments.** Line 86 `# dispatch.sh — Dispatch tasks to Codex, Antigravity (agy), Grok, or pi-read CLI as autonomous agents` → `# dispatch.sh — Dispatch tasks to Codex, Antigravity (agy), or Grok CLI as autonomous agents`. Shebang comment lines 3-5: replace `# SHEBANG: \`#!/usr/bin/env -S bash -p\` — env resolves \`bash\` via PATH (the` / `# pi lane requires bash 4+ via PATH; a \`#!/bin/bash\` shebang would pin macOS` / `# /bin/bash 3.2) AND the first process starts with \`-p\`, so no BASH_FUNC_*` with:

```bash
# SHEBANG: `#!/usr/bin/env -S bash -p` — env resolves `bash` via PATH (chosen for
# the withdrawn pi lane's bash 4+ floor, ADR 0060; tightening it to /bin/bash is
# a separate change) AND the first process starts with `-p`, so no BASH_FUNC_*
```

- [ ] **Step 18: delete the pi test file and its weight.**

```bash
git rm tests/test-pi-dispatch-arm.sh
t=scripts/ci/shell-test-durations.tsv; grep -v $'^test-pi-dispatch-arm\t' "$t" > "$t.new" && mv "$t.new" "$t"   # portable: no sed -i
```

  Check: `grep -c 'test-pi-dispatch-arm' scripts/ci/shell-test-durations.tsv` prints `0`.

- [ ] **Step 19: `tests/test-dispatch-skipped-status.sh` case 8.** Delete case 8 (from `# ── 8. Static: \`skipped\` is conditional on the credential jail being CONFIRMED` through the `bad "nothing sets _pi_jail_survived …"` line). Renumber `# ── 9. Static:` to `# ── 8. Static:`. Then add, right after case 7:

```bash
# ── 7b. Static: grok's refusal is what assigns `skipped`. Since ADR 0060 it is
#      the only producer, so losing this line would leave `skipped` unreachable
#      while case 7 (which only checks ordering) still passed.
grep -q '\[\[ "${_grok_refused:-0}" == "1" \]\] && status="skipped"' "$DISPATCH" \
  && ok "the grok refusal assigns skipped" \
  || bad "nothing assigns skipped from the grok refusal — the batch contract has no producer"
```

- [ ] **Step 20: `tests/test-agy-dispatch-arm.sh`.** Change the whitelist anchor (`:331` at base) to `l_whitelist="$(line_of '^[[:space:]]+codex\|agy\|agy-prose\|grok\) ;;$')"`. Add §1b directly after §1's `rm -rf "$wd_stub"`:

```bash
# ── 1b. pi and pi-read are withdrawn (ADR 0060) with a migration message ──
# Both spellings, exact match: the refusal names the replacement, and no CLI —
# not even a stub agy/codex/grok on PATH — is invoked.
pr_stub="$(mktemp -d)" || { echo "FAIL — mktemp -d failed for pr_stub"; exit 1; }
for c in agy codex grok pi; do
  printf '#!/bin/sh\nprintf "CLI_WAS_INVOKED\\n"\n' > "$pr_stub/$c"; chmod +x "$pr_stub/$c"
done
for v in pi-read pi; do
  out="$(PATH="$pr_stub:$PATH" "$DISPATCH" --cli "$v" --prompt x 2>&1)"; rc=$?
  if [[ $rc -ne 0 && "$out" == *"--cli $v was withdrawn (ADR 0060)"* && "$out" == *"codegraph_explore"* \
        && "$out" != *"CLI_WAS_INVOKED"* ]]; then
    pass "--cli $v is refused with the ADR 0060 migration message, nothing invoked"
  else
    fail "--cli $v must be refused with the migration message and invoke nothing (rc=$rc): $out"
  fi
done
rm -rf "$pr_stub"
```

  Also add `"${pr_stub:-}"` to the file's single EXIT trap list (line 40), next to `"${wd_stub:-}"`.

- [ ] **Step 21: `tests/test-agy-prose-lane.sh`.** Line 68: the pattern becomes `'^[[:space:]]+codex\|agy\|agy-prose\|grok\) ;;$'`. Line 81 comment `# pi-read refuses without a model; this lane must NOT — empty means` → `# This lane must not refuse without a model — empty means`. Line 85 pass text `"empty model is passed through, not defaulted (deliberate divergence from pi)"` → `"empty model is passed through, not defaulted"`. Line 139 `  # not the refusal pi treats it as.` → `  # not a refusal.`. Line 148 `  # A non-empty INVALID string (e.g. a provider/model id pasted from the pi` → `  # A non-empty INVALID string (e.g. a provider/model id pasted from another`.

- [ ] **Step 22: `tests/test-grok-sandbox-arm.sh`.** `:1357`: `_retry_guard="$(/usr/bin/awk '/_pi_setup_failed:-0/,/continue/' "$DISPATCH" | /usr/bin/head -8)"` → `_retry_guard="$(/usr/bin/awk '/The refusal flag is checked FIRST/,/continue/' "$DISPATCH" | /usr/bin/head -8)"`. The anchor is Step 3's new comment, so the slice still covers the `if` that must name `_grok_refused`. `:1388-1389`: `# that put grok in the batch. It must be a REFUSAL (skipped), like pi-read's` / `# missing model.` → `# that put grok in the batch. It must be a REFUSAL (skipped).`.

- [ ] **Step 22b: `tests/test-review-boundaries.sh`.**
  - Delete the pi-probe guard count (`:432-437` at base), which runs from `# shellcheck disable=SC2016  # single-quoted pattern is a literal grep for the pi-probe source text` through its closing `fi`. It requires exactly two copies of `[[ "$u" =~ ^[-+]?[0-9]*$ ]] && exit 1` in dispatch.sh. Both lived in pi code (`_pi_available` at `:506` and the arm at `:1420`), so after Steps 5 and 12 the count is 0 and the suite would fail. The same guard on the surviving resolver copy is still pinned by the `resolve-cli.sh: allowlist rejects tilde stack forms` assertion just above it, and by §10's behavioural test.
  - In the (h) comment (`:273-278`), replace `# (h) dispatch.sh keeps the pi-required PATH-resolved bash shebang (the pi` / `# lane needs bash 4+ via PATH — a \`#!/bin/bash\` shebang would pin /bin/bash` / `# 3.2) WITH \`-p\` …` with `# (h) dispatch.sh keeps its PATH-resolved bash shebang (chosen for the` / `# withdrawn pi lane's bash 4+ floor, ADR 0060; tightening it is a separate` / `# change) WITH \`-p\` …`. Keep the rest of the sentence. The assertion itself is unchanged.

- [ ] **Step 23: Run and commit.**

Run:
```bash
bash -n skills/dispatch-cli/scripts/dispatch.sh && shellcheck skills/dispatch-cli/scripts/dispatch.sh
grep -nE 'pi-read|pi_read|_pi_|PI_PROBED|PI_ANTIGRAVITY|pi-antigravity' skills/dispatch-cli/scripts/dispatch.sh
bash tests/test-dispatch-skipped-status.sh && bash tests/test-agy-dispatch-arm.sh && bash tests/test-agy-prose-lane.sh \
  && bash tests/test-grok-sandbox-arm.sh && bash tests/test-lane-model-config.sh && bash tests/test-review-boundaries.sh \
  && bash scripts/ci/run-shell-tests.sh
```
Expected: syntax and shellcheck clean. The grep prints only two intentional lines: Step 11's `elif` (it names `pi-read`) and Step 14's TIMEOUT comment. Every test exits 0. `wc -l skills/dispatch-cli/scripts/dispatch.sh` is about 1,700 (down from 2,739). Investigate if it is far off.

```bash
git add -A skills/dispatch-cli/scripts/dispatch.sh tests/ scripts/ci/shell-test-durations.tsv
git commit -m "feat(dispatch-cli)!: withdraw the pi-read lane (ADR 0060)

BREAKING CHANGE: --cli pi-read and --cli pi are refused with a migration message."
```

---

### Task 3: Resolver — remove the pi model reader

**Files:**
- Modify: `scripts/lib/resolve-cli.sh`
- Modify: `tests/test-agy-dispatch-arm.sh` (§4 only)
- Modify: `tests/test-lane-model-config.sh` (the retired-key case)

**Interfaces:**
- Consumes: nothing new.
- Produces: `resolve_pi_read_model`, `_BD_PI_READ_MODEL`, `_BD_PI_READ_MIGRATION_REQUIRED` no longer exist. `_bd_read_lane_model` accepts `writing_prose` and `writing_prose_raw` only; any other key returns its default (as `auditor` does today). This task runs AFTER Task 2 on purpose. While the pi arm exists, `--cli all` selects pi on any host where `_pi_available` finds a binary (the Mac has `~/.local/bin/pi`, found via the password-db home, not PATH), and the arm calls `resolve_pi_read_model`. Removing the library function first would make every `--cli all` test fail with `command not found` on that host, while staying green on a pi-less CI runner. **Check before starting:** `grep -n 'resolve_pi_read_model\|_BD_PI_READ' skills/dispatch-cli/scripts/dispatch.sh` prints nothing.

- [ ] **Step 1: delete the pi read lane model section.** Delete from `# ── Pi read lane model ──────────────────────────────────────────` (line 1376) through the closing `}` of `resolve_pi_read_model()` (line 1430), and the blank line after it.

- [ ] **Step 2: writing-prose comment.** In the `# ── writing-prose lane model` block that follows, replace `# Same trust rules as \`.pi_read.model\` (USER config only, no env override, no` with `# Same trust rules as every lane model key (USER config only, no env override, no`. Replace the five-line paragraph starting `# DELIBERATE DIVERGENCE from pi-read — do NOT "unify" this away: empty is NOT a` with:

```bash
# Empty is NOT a refusal here: it means "pass no --model", i.e. agy's own
# configured model, which is the behaviour this lane was validated on. A writer
# that stops dead because an optional key is unset is worse than one that uses
# the operator's own default.
```

- [ ] **Step 3: the reader.** In `_bd_read_lane_model`:
  - Retitle `# ── Lane model keys (pi_read / writing_prose) ────────` to `# ── Lane model key (writing_prose) ────────`.
  - In its comment, replace `` # `pi --list-models` and `agy models` list valid ids. `` with `` # `agy models` lists valid ids. ``.
  - In the child, delete the three case arms `pi_read)`, `pi_read_raw)` and `pi_legacy_raw)` (lines 1205-1207). Replace the paragraph `# \`shape\` selects the validation grammar below. pi-style lanes name a` … `# tests/test-lane-model-config.sh), or the prose goes stale next to it.` with:

```bash
# `shape` selects the validation grammar below: `bare` for agy's ids (no
# provider segment), `any` for the presence probe. Deliberately no example id in
# this comment: no live file may name a model id (see
# tests/test-lane-model-config.sh), or the prose goes stale next to it.
```

  - Replace the grammar-explanation comment block from `# The value becomes a single argv word after \`-m\`.` through `# nobody chose.` with:

```bash
# The value becomes a single argv word after `--model`. No shell eval reaches it,
# so the only real hazards are option injection (a leading `-`) and whitespace or
# control characters. A bad value degrades to the CALLER-SUPPLIED default with a
# loud note rather than killing the voice on a typo.
```

  - In the `shape == 'any'` comment, replace `` # dominant real case — a well-formed string in the wrong grammar, e.g. a `` / `` # `provider/id` pasted from the pi config — not every shape. `` with `` # dominant real case — a well-formed string in the wrong grammar, e.g. a `` / `` # `provider/id` reference — not every shape. ``.
  - Replace the `if [[ "$shape" == 'bare' ]]; then … else … fi` regex selection with the bare assignment alone (the `slash` grammar has no consumer left):

```bash
# Leading `-` (option injection) and whitespace/control chars are excluded by the
# character class. A bare id is the whole value: no `/`, no `#variant`.
_bd_re='^[A-Za-z0-9][A-Za-z0-9._:@-]*$'
_bd_want='a bare model id with no provider/ prefix'
```

- [ ] **Step 4: install hint, username comment, grok comment.**
  - In `get_cli_install_hint`, delete the `pi)     echo "See https://github.com/badlogic/pi-mono …" ;;` line.
  - In the `_bd_valid_username` comment, replace `# bash builtin — no shadowable command word. (Same allowlist the pi lane's` / `# probes apply; dispatch.sh carries an identical fallback copy.)` with `# bash builtin — no shadowable command word. (dispatch.sh carries an` / `# identical fallback copy.)`.
  - Near line 4202, replace `# from the password database instead — the same derivation the agy-prose and` / `# pi lanes use.` with `# from the password database instead — the same derivation the agy-prose lane` / `# uses.`.
  - Leave the `~/.pi/agent/settings.json` sentence near line 4487 as is. It describes agy's own behaviour on 1.1.4, not the pi lane, and §9c's pattern does not match it.
  - In `tests/test-lane-model-config.sh`, directly after the existing `# ADR 0051: a leftover .auditor.model is ignored` case, add:

```bash
# ADR 0060: a leftover .pi_read.model is ignored the same way — the pi_read
# block is no longer in the reader's enum.
printf '{"pi_read":{"model":"x/y"}}' > "$FAKE_HOME/.claude/busdriver.json"
got="$(HOME="$FAKE_HOME" bash -c 'source "$0"; printf "%s" "$(_bd_read_lane_model "$HOME" "SENTINEL" pi_read)"' "$LIB")"
if [[ "$got" == "SENTINEL" ]]; then
  ok "retired pi_read key returns the default"
else
  fail "retired pi_read key still read: '$got'"
fi
```

- [ ] **Step 5: `tests/test-agy-dispatch-arm.sh`.** Delete §4 (from `# ── 4. pi's grammar is unchanged (no cross-contamination) ───────` through the `fi` that closes its `if [[ -z "$got" ]]`). Then in §3's comment, replace `# The pi grammar requires provider/model; agy ids have no slash, so a shared` / `# regex would silently reject every valid value. Driven through the prose lane's` with `# agy ids have no slash, so a provider/model regex would silently reject every` / `# valid value. Driven through the prose lane's`.

- [ ] **Step 6: Run and commit.**

Run: `bash -n scripts/lib/resolve-cli.sh && shellcheck scripts/lib/resolve-cli.sh && bash tests/test-lane-model-config.sh && bash tests/test-agy-dispatch-arm.sh && bash tests/test-agy-prose-lane.sh && bash scripts/ci/run-shell-tests.sh`
Expected: all exit 0, and the lane-model test prints `retired pi_read key returns the default`. `grep -nE 'pi_read|resolve_pi_read_model|_BD_PI_READ|pi_legacy' scripts/lib/resolve-cli.sh` prints nothing. Shellcheck may report SC2034 if `shape` is now only read in one branch. If so, keep `shape` (the `any` branch reads it) and confirm the warning is not new against `d387639d` before suppressing anything.

```bash
git add scripts/lib/resolve-cli.sh tests/test-agy-dispatch-arm.sh tests/test-lane-model-config.sh
git commit -m "refactor(resolve-cli): remove the pi-read model reader and its slash grammar (ADR 0060)"
```

---

### Task 4: Read-size advisory — stop routing to pi

**Files:**
- Modify: `scripts/hooks/pre-read-size-advisory.js:256`
- Modify: `__tests__/pre-read-size-advisory.test.ts:192`
- Modify: `.gate-integrity.lock` (regenerated)

- [ ] **Step 1: the advisory line.** Replace

```js
      '[Hook] 2) Otherwise route to pi. Both trust gates are yours to judge, not this hook\'s.',
```

with

```js
      '[Hook] 2) Otherwise use codegraph_explore for indexed code, or an Explore subagent for a broad sweep.',
```

- [ ] **Step 2: the test.** `expect(text.indexOf('offset/limit')).toBeLessThan(text.indexOf('route to pi'))` → `expect(text.indexOf('offset/limit')).toBeLessThan(text.indexOf('codegraph_explore'))`. Also add `expect(text).not.toContain('route to pi')` on the next line, so the old wording cannot return.

- [ ] **Step 3: regenerate the lock, run, commit.**

Run: `./scripts/gate-integrity.sh --update && ./scripts/gate-integrity.sh --check && npm test && bash tests/test-gate-integrity.sh && bash scripts/ci/run-shell-tests.sh`
Expected: all exit 0. `git diff --stat .gate-integrity.lock` shows exactly one changed line (`scripts/hooks/pre-read-size-advisory.js`).

```bash
git add scripts/hooks/pre-read-size-advisory.js __tests__/pre-read-size-advisory.test.ts .gate-integrity.lock
git commit -m "fix(hooks): point the read-size advisory at CodeGraph/Explore instead of pi (ADR 0060)"
```

---

### Task 5: Operator-facing docs

**Files:**
- Modify: `.claude/CLAUDE.md:101`, `README.md:107`, `skills/dispatch-cli/SKILL.md`, `skills/writing-prose/SKILL.md:111,129`, `commands/model-route.md:20`
- Modify (comments only): `tests/test-dispatch-timeout-and-failure-log.sh:11,27,86,113`, `tests/test-trusted-review-cli.sh:795-797`, `tests/test-no-auditor-lane.sh:17`

- [ ] **Step 1: `.claude/CLAUDE.md`.** Replace the whole bullet at line 101 (`- **Reading routes to \`pi-read\` first …` through `… measured ~5% there because that loop is \`gh\`-fetch dominated.`) with:

```markdown
- **Reading: keep file dumps out of context** — the cheapest read is the one that never enters context. Read a file yourself when you can name the region up front *and* it is under ~200 lines (the read-size advisory reminds you past that). For anything larger, or a trace you cannot scope up front, use **CodeGraph first** (`codegraph_explore` — one call returns line-numbered source plus call paths), then an **Explore subagent** for a broad sweep over files CodeGraph does not index; then `Read` only the ranges they point at. No external CLI is a read lane: `pi-read` was withdrawn (ADR 0060) and `agy-read` before it (ADR 0052). Plain `--cli agy` (reviewers) and `--cli agy-prose` (writing-prose) are unaffected.
```

- [ ] **Step 2: `README.md`.** Delete the `| **pi** | \`pi-read\` dispatch lane …` table row (line 107).

- [ ] **Step 3: `skills/dispatch-cli/SKILL.md`.**
  - Frontmatter `:4` and `:14`: `Codex, Antigravity (agy), Grok, or pi-read` → `Codex, Antigravity (agy), or Grok` (both places; `:4` may wrap, so keep the YAML folded-scalar indentation).
  - CLI Selection table: delete the `| **Repo tracing / "how does X work"** | **\`pi-read\`** | …` row. Change the `all` row's text to `All available CLIs in parallel (up to 3; \`grok\` is skipped in \`auto\` mode)`.
  - `:44` blockquote: `> \`agy-read\` was withdrawn (ADR 0052 follow-up); \`pi-read\` is the read lane.` → `> \`agy-read\` (ADR 0052) and \`pi-read\` (ADR 0060) were withdrawn; there is no read lane.`.
  - `:59-61` "Calibrate the write claim": delete `When you` / `need an enforced boundary rather than a well-behaved one, use \`pi-read\`` / `(jail + \`--tools read\`).`, so the paragraph reads `… not write-**proof**. agy also persists …`.
  - Hindsight paragraph `:76` and `:81-82`: `pi-read and grok launch under \`env -i\` and do not receive the pair. grok runs with` → `grok launches under \`env -i\` and does not receive the pair. It runs with`. Delete the trailing sentence `pi-read` / `is unchanged; its memory wiring belongs to the 0827 plan's item 10.`.
  - Delete the whole section `### \`pi-read\` — the default in-tree read lane (ADR 0052)` (`:110` up to, not including, `## Execution Modes`).
  - Sandboxing table: delete the `| pi-read | \`--tools read\` …` row.
  - Flags table `:355`: `\`codex\`, \`agy\`, \`agy-prose\`, \`grok\`, \`pi-read\`, \`both\`, \`all\`, \`auto\`` → drop `` `pi-read`, ``.
  - Delete the whole section `## Routing reads to the read lane (the point of it)` (`:424` up to, not including, `## Error Handling`). Put this in its place:

```markdown
## Reading code is not a dispatch

No CLI here is a read lane (`agy-read` withdrawn in ADR 0052, `pi-read` in ADR 0060).
To keep large reads out of context, use `codegraph_explore` first and an Explore
subagent for a broad sweep — see the reading rule in `.claude/CLAUDE.md`.
Everything any lane here reads is sent to that lane's provider, so the
provenance and confidentiality questions still apply to every dispatch: does
everything the prompt can reach trace back to an author you trust, and are you
willing to send it — untracked files included — to that third party?
```

  - `### \`skipped\` vs \`error\` (#594)`: first sentence becomes `A voice that refuses to run on a **deterministic precondition** — grok with no usable sandbox profile, or a \`--model\` grok cannot accept — reports \`skipped\`, not \`error\`.`. Table row `| \`--cli pi-read\` (explicit) |` → `| \`--cli grok\` (explicit) |`. Last line `Only the pi-read arm can currently produce a \`skipped\`; the status itself is shared by` / `every CLI.` → `Only the grok arm currently produces a \`skipped\`; the status itself is shared by every CLI.`.
  - Afterwards `grep -nE 'pi-read|pi_read|pi-antigravity|\bpi\b' skills/dispatch-cli/SKILL.md` prints only the two withdrawal mentions above (`:44` blockquote and the new section's first line).

- [ ] **Step 4: `skills/writing-prose/SKILL.md`.** `:111`: replace `model runs. This is a deliberate divergence from \`pi-read\`, which` and the rest of that sentence (up to its full stop) with `model runs.`. `:129`: `best-effort defense in depth, not write-**proof**; use \`pi-read\` if you need an` + the rest of that sentence → `best-effort defense in depth, not write-**proof**.`. Read both sentences in full before cutting, and keep the paragraph grammatical.

- [ ] **Step 4b: `commands/model-route.md:20`.** `  claim Codex is review/gate-only today; the Pi replacement owns its implementation rows.` → `  claim Codex is review/gate-only today; its implementation rows are unchanged (the Pi replacement that would have owned them was withdrawn, ADR 0060).`

- [ ] **Step 5: test comments.** These are comment-only edits, and each claim must stay true:
  - `tests/test-dispatch-timeout-and-failure-log.sh:11`: `#      the pi lane's median (measured in-tree traces: 315s and 307s), so pi's` → `#      the withdrawn pi-read lane's median (measured in-tree traces: 315s and 307s), so its`. `:27`: `# see test-dispatch-skipped-status.sh — #595, bash 3.2 breaks the pi arm` → `# see test-dispatch-skipped-status.sh — dispatch.sh is only verified on bash >= 4`. `:86`: `#      at 300 the pi lane killed its own successful 315s/307s runs.` → `#      at 300 the (since withdrawn) pi-read lane killed its own successful 315s/307s runs.`. `:113`: `#      — which is exactly how the cause of a real 465s pi failure was lost.` → `#      — which is exactly how the cause of a real 465s dispatch failure was lost.`.
  - `tests/test-trusted-review-cli.sh:795-797`: `# one documented exception: its pi lane requires bash 4+, which on macOS only PATH` / `# resolution supplies (/bin/bash is 3.2), and its own nonce+sentinel proof plus` / `` # `env -i` children bound the residual. `` → `# one documented exception: its env-resolved bash was chosen for the withdrawn pi` / `# lane's bash 4+ floor (ADR 0060) and is kept until a separate change tightens it;` / `` # its own nonce+sentinel proof plus `env -i` children bound the residual. ``. The exception itself (`skills/dispatch-cli/scripts/dispatch.sh) continue ;;`) stays.
  - `tests/test-no-auditor-lane.sh:17`: `#   ALLOW_SUBSTR - substrings deleted before matching: the pi provider name and` → `#   ALLOW_SUBSTR - substrings deleted before matching: a provider name and`. Leave the `:97` fixture string as is. It is test input to `hits_in`, not a reference to the lane.

- [ ] **Step 6: Run and commit.**

Run: `bash tests/test-lane-model-config.sh && bash scripts/ci/run-shell-tests.sh && npm run validate`
Expected: all exit 0. The lane-model sweep still includes `.claude/CLAUDE.md` and `skills/dispatch-cli/SKILL.md` and finds no model id.

```bash
git add .claude/CLAUDE.md README.md skills/dispatch-cli/SKILL.md skills/writing-prose/SKILL.md commands/model-route.md \
  tests/test-dispatch-timeout-and-failure-log.sh tests/test-trusted-review-cli.sh tests/test-no-auditor-lane.sh
git commit -m "docs: drop pi-read from the read rule, README and dispatch/prose skills (ADR 0060)"
```

---

### Task 6: Structural guard — no pi code path survives

**Files:**
- Modify: `tests/test-review-boundaries.sh` (after the existing §9b droid block, before `# ── 10.`)

- [ ] **Step 1: add §9c.**

```bash
# ── 9c. no pi code path survives (structural, ADR 0060) ─────────────
# Same contract as §9b: plain grep (works in a non-git copy), rc 0 = a match
# (fail), 1 = clean (pass), anything else = the scan broke — fail CLOSED.
# -I skips binary files. Identifiers and dispatch SHAPES only, never the bare
# word `pi`, which matches prose and pipelines. The shapes catch what an
# identifier list cannot: a restored `pi-read)` case label, a `pi-read` member
# of the `--cli all` discovery loop, or a `|pi-read)` vocabulary entry. The
# validator's migration branch tests `"$CLI" == "pi-read" ]]`, which none of
# these match; its behaviour is probed directly below.
_pi_pat='_pi_[a-z]|pi_read|PI_READ|PI_PROBED|PI_ANTIGRAVITY|pi-antigravity|resolve_pi_read_model|--cli pi-read|^[[:space:]]*pi-read\)|\|pi-read\)|grok pi-read'
_pi_hits="$(grep -rnIE "$_pi_pat" "$REPO_ROOT/scripts" "$REPO_ROOT/skills" "$REPO_ROOT/hooks" 2>&1)"
case $? in
  1) pass "no pi-read lane code remains" ;;
  0) fail "a pi code path survives:"; printf '%s\n' "$_pi_hits" ;;
  *) fail "pi structural scan failed to run: $_pi_hits" ;;
esac
# The scan cannot see a dispatch reached by some other spelling; probe the
# behaviour directly, like §9b does for droid. Both spellings must be refused
# with the migration message (which names the replacement), never run.
for _pi_v in pi-read pi; do
  _pi_out="$(bash "$REPO_ROOT/skills/dispatch-cli/scripts/dispatch.sh" --cli "$_pi_v" --prompt p --timeout 5 2>&1)"; _pi_rc=$?
  if [[ "$_pi_rc" -ne 0 ]] && printf '%s' "$_pi_out" | grep -qF -- "--cli $_pi_v was withdrawn (ADR 0060)"; then
    pass "dispatch.sh refuses --cli $_pi_v with the ADR 0060 migration message"
  else
    fail "dispatch.sh did not refuse --cli $_pi_v as withdrawn (rc=$_pi_rc): $_pi_out"
  fi
done
```

  Check the pattern against the tree before committing. `skills/dispatch-cli/SKILL.md` must not contain `--cli pi-read` after Task 5. If an earlier task left one, fix it there, not by widening the pattern's exemptions.

- [ ] **Step 2: prove the guard fires.** In a scratch copy, re-introduce one hit and confirm §9c fails, then discard the copy:

```bash
s="$(mktemp -d)"; cp -R . "$s/r"; echo '_pi_probe=1' >> "$s/r/scripts/lib/resolve-cli.sh"
( cd "$s/r" && bash tests/test-review-boundaries.sh ) | grep -E 'pi code path survives|no pi-read lane code remains'; rm -rf "$s"
s="$(mktemp -d)"; cp -R . "$s/r"; printf '        pi-read)\n            : ;;\n' >> "$s/r/skills/dispatch-cli/scripts/dispatch.sh"
( cd "$s/r" && bash tests/test-review-boundaries.sh ) | grep -E 'pi code path survives|no pi-read lane code remains'; rm -rf "$s"
```
Expected: both runs print `a pi code path survives:` with the planted line. The first plants an identifier and the second a case label. Then `bash tests/test-review-boundaries.sh` in the worktree prints `no pi-read lane code remains` and both `refuses --cli … with the ADR 0060 migration message` lines.

- [ ] **Step 3: Run and commit.**

Run: `bash tests/test-review-boundaries.sh && bash scripts/ci/run-shell-tests.sh`
Expected: exit 0.

```bash
git add tests/test-review-boundaries.sh
git commit -m "test: assert no pi-read lane code remains (ADR 0060)"
```

---

### Task 7: ADR and amendments

**Files:**
- Create: `docs/adr/0060-withdraw-pi.md`
- Modify: `docs/adr/0034-pi-in-tree-read-lane.md`, `docs/adr/0042-pi-version-certification-cache.md`, `docs/adr/0052-pi-read-on-antigravity.md` (status lines)

- [ ] **Step 1: `docs/adr/0060-withdraw-pi.md`.**

```markdown
# ADR 0060 — Withdraw pi

## Status

**Accepted (2026-10-25).** Supersedes [ADR 0034](./0034-pi-in-tree-read-lane.md),
[ADR 0042](./0042-pi-version-certification-cache.md) and
[ADR 0052](./0052-pi-read-on-antigravity.md). Withdraws the pi-replacement program
(`docs/plans/2026-08-23-pi-replacement.md`) and item 10 of
`docs/plans/2026-08-27-pipeline-final-plan.md`, and item 7b of the same plan.
Plan: `docs/plans/2026-10-25-withdraw-pi.md`. Recovery anchor: `d387639d`
(origin/main immediately before removal) — `git show d387639d:<path>` restores any
file.

## Context

pi served one shipped role, the `pi-read` dispatch lane: an in-tree reader in a
jail with `--tools read`, made the mandated first stop for reads by
`.claude/CLAUDE.md`. A second, larger role was planned and never built — pi as
the single vendor-swappable worker layer (the pi-replacement program).

Measured 2026-10-25 over the previous 30 days (`~/.claude/homunculus/dispatch-log.jsonl`):
144 pi-read dispatches, 136 `skipped`, 8 `success`, all 8 on 2026-10-05 (the ADR 0052
certification day). Installed pi was 1.2.0 against the 1.0.1 pin, so every dispatch
after the 2026-10-14 upgrade was refused — the same silent outage ADR 0042 recorded
for an earlier upgrade — and nobody noticed. Direct agent calls in the same window:
grok 18, agy-prose 12, agy 6, pi-read 5.

Against that: the arm was ~860 of `dispatch.sh`'s 2739 lines plus a 1859-line test;
two version pins with a live re-certification ritual; residuals ADR 0052 left open
(refresh bounded only by a 90s kill, non-atomic `auth.json` writes, unconfined reads);
and Google ToS/account-suspension risk from pi-antigravity's use of Antigravity's
OAuth client, which ADR 0052 accepted. The replacement program ran 13 review rounds
without converging; only its rename slice landed. CodeGraph (`codegraph_explore`) and
an Explore subagent now cover "keep large reads out of context" with no external
provider.

## Decision

Remove pi entirely. `--cli pi` and `--cli pi-read` are refused with a migration
message that names the replacement; nothing is invoked. `.pi_read.model` is no
longer read (a leftover key is inert, like `.auditor.model`). The `skipped` status
and the `--cli all` batch contract are unchanged; grok's refusals are now their
only producer, and the tests drive them through grok. The read rule in
`.claude/CLAUDE.md` and the read-size advisory point at CodeGraph and Explore.

## Alternatives

- **Keep the lane, cancel only the program.** Rejected (council, 2026-10-25): it keeps
  the part with the running cost and the ToS exposure and cancels the part that cost
  nothing.
- **Re-certify pi 1.2.0 and keep everything.** Rejected: the lane had zero successful
  reads in the twenty days before measurement; re-certifying buys a capability nobody
  was using.
- **Replace pi-read with another external read lane.** Rejected: two read lanes have
  now been withdrawn for disuse (agy-read, pi-read); an in-session index does the job
  without moving content to a third party.

## Consequences

- One fewer external provider and one fewer credential store in every data-boundary
  argument.
- No external read lane. Large reads go through CodeGraph or an Explore subagent, whose
  cost lands in this session rather than at a third party.
- `dispatch.sh` keeps its `#!/usr/bin/env -S bash -p` shebang (chosen for pi's bash 4+
  floor); tightening it to `/bin/bash` needs its own bash 3.2 verification and is a
  separate change.
- Operator-side residue is NOT removed by this change: the projected credential store
  (`~/.pi/agent/auth.json`, `antigravity-accounts.json`), the Google OAuth grant, and
  the installed binary. Deleting code revokes nothing; see the plan's operator tasks.
- Historical log entries keep `pi-read`; ADRs 0034/0042/0052 and the program plans
  stay as records.

## Revisit trigger

A sustained need for an external reader that CodeGraph and an Explore subagent cannot
meet — measured, not anticipated. Add it as a new, reviewed lane with its own ADR;
do not restore this one from the anchor.
```

- [ ] **Step 2: status lines on the superseded ADRs.** Add one line to each `Status` block, after the existing amendment lines:
  - ADR 0034: `**Superseded by ADR 0060 (2026-10-25):** pi was withdrawn; the \`pi-read)\` arm, \`resolve_pi_read_model\` and \`tests/test-pi-dispatch-arm.sh\` are deleted.`
  - ADR 0042: `**Superseded by ADR 0060 (2026-10-25):** pi was withdrawn; both pins are deleted. (The silent-outage-on-upgrade failure this ADR describes recurred with pi 1.2.0 and is part of why.)`
  - ADR 0052: `**Superseded by ADR 0060 (2026-10-25):** pi was withdrawn; there is no read lane.`

- [ ] **Step 3: Run and commit.**

Run: `npm run validate && bash scripts/ci/run-shell-tests.sh`
Expected: exit 0. If an ADR index or link checker runs in `validate`, confirm it accepts 0060.

```bash
git add docs/adr/0060-withdraw-pi.md docs/adr/0034-pi-in-tree-read-lane.md docs/adr/0042-pi-version-certification-cache.md \
  docs/adr/0052-pi-read-on-antigravity.md
git commit -m "docs(adr): ADR 0060 withdraw pi; mark ADRs 0034/0042/0052 superseded"
```

---

### Task 8: Acceptance verification

- [ ] **Step 1: the reference sweep of record.**

```bash
grep -rIn -E 'pi-read|pi_read|PI_READ|pi-antigravity|_pi_[a-z]|test-pi-dispatch' \
  --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=docs --exclude=CHANGELOG.md .
```
Expected hits, and only these: the validator `elif` and the TIMEOUT comment in `dispatch.sh` (Task 2 Steps 11, 14), `tests/test-agy-dispatch-arm.sh` §1b, `tests/test-lane-model-config.sh`'s retired-key case, `tests/test-review-boundaries.sh` §9c, `tests/test-no-auditor-lane.sh:97`'s fixture, the two withdrawal mentions in `skills/dispatch-cli/SKILL.md`, the CLAUDE.md read rule's withdrawal mention, and the timeout test's history comments. Fix any other hit in the task that owns that file.

- [ ] **Step 2: full suites.** `bash scripts/ci/run-shell-tests.sh && npm test && npm run validate && ./scripts/gate-integrity.sh --check && ./scripts/bump-version.sh --check`. All exit 0.

- [ ] **Step 3: live smoke (operator host).** `skills/dispatch-cli/scripts/dispatch.sh --cli pi-read --prompt x; echo rc=$?` prints the ADR 0060 message and `rc=1`. `echo 'say ok' | skills/dispatch-cli/scripts/dispatch.sh --cli codex --timeout 120` still succeeds. Then `--cli all --prompt 'say ok' --timeout 300` runs codex, agy and grok only, and the batch summary has no PI-READ row.

---

### Task 9: Plan bookkeeping (last — it arms the design gate)

Any write to `docs/plans/**/*.md` arms the design-review gate (`check-design-document.sh`, `plans_re`). These three edits are one-line status notes on historical plans. Doing them earlier would block every later task behind a review of a 1,024-line historical plan. So they come last, after acceptance has passed.

**Files:**
- Modify: `docs/plans/2026-08-23-pi-replacement.md`, `docs/plans/2026-08-23-pi-replacement-slice-0.md`, `docs/plans/2026-08-27-pipeline-final-plan.md`, and in `docs/plans/2026-08-27-pipeline-final-plan.d/`: `…--item-7-rule-4b.md`, `…--item-2p-review-yield-protocol.md`

- [ ] **Step 1: program plans.** At the top of the umbrella's status blockquote (`docs/plans/2026-08-23-pi-replacement.md`, before `> **Status: UMBRELLA.`), add:

```markdown
> **2026-10-25 — WITHDRAWN (ADR 0060).** pi was removed from busdriver. Slices 1–7
> will not be built; slice 0 had landed. Kept as a record only — do not resume from it.
>
```

  Add the same note, with `This slice landed; the program it belonged to is withdrawn.` as the second sentence, as the first line of `docs/plans/2026-08-23-pi-replacement-slice-0.md` under its title.

- [ ] **Step 2: `docs/plans/2026-08-27-pipeline-final-plan.md`.**
  - Status table row for item 10 (`:357`): replace the status cells `| open | in flight (eval only) | **SPLIT** |` with `| withdrawn | — | **WITHDRAWN (ADR 0060, 2026-10-25)** |` and prefix the notes cell with `pi was withdrawn; neither the eval nor any mutating slice will run. `. Leave the rest of the cell as a record.
  - Row 7 (`:354`): replace `| open | not started | **SPLIT** |` with `| partly withdrawn | not started | **7b WITHDRAWN (ADR 0060); 7a-i unchanged** |`, and prefix the notes cell with `7b's target lane (agy-read, then pi) no longer exists, and the advisory text it would replace now points at CodeGraph/Explore. 7a-i (a behaviour-preserving refactor) is unaffected. `.
  - Item-10 definition row (`:290`): prefix the first cell's text with `**WITHDRAWN 2026-10-25 (ADR 0060).** `. In its status cell, which starts `**SPLIT** — **10-eval** (the non-mutating half`, prefix `**WITHDRAWN (ADR 0060, 2026-10-25) — neither half will run; the text below is the superseded record.** `.
  - Item-7 definition row (`:287`): its status cell `**SPLIT** — **7a-i** TODO after item 1; **7b** BLOCKED on \`baseline captured\` AND item 3's paired measurement AND 7a-i` → `**SPLIT** — **7a-i** TODO after item 1; **7b** WITHDRAWN (ADR 0060, 2026-10-25) — its target read lane no longer exists`.
  - *Still needs Chris* #5 (`:618`): insert `**Moot 2026-10-25 (ADR 0060): item 10 is withdrawn, so no pi slice remains to sequence.** ` directly after `5. **Item 10 sequencing.** `. Leave the body as the record of what was decided.

- [ ] **Step 2b: the two child files that restate pi scope.** Each starts with a `> **ROADMAP, NOT BINDING (Chris, 2026-09-26).**` banner. Add one more blockquote paragraph directly below that banner, in both `docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-7-rule-4b.md` and `docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-2p-review-yield-protocol.md`:

```markdown
>
> **2026-10-25 — ADR 0060 withdrew pi.** Every statement below that keeps pi lane code or
> `.pi_read.model`, routes reads to pi, or sequences a pi slice is superseded: item 7b and item 10
> are withdrawn, and the read-size advisory now points at CodeGraph/Explore.
```

  The sentences themselves stay unchanged as records (item-7 child `:32`/`:36`, 2p child `:866-869` and `:1221`). The banner is what makes them unambiguous. Step 3's `git add` adds both files.

- [ ] **Step 3: Commit, then hand the armed tokens to the operator.**

```bash
git add docs/plans/2026-08-23-pi-replacement.md docs/plans/2026-08-23-pi-replacement-slice-0.md docs/plans/2026-08-27-pipeline-final-plan.md \
  docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-7-rule-4b.md \
  docs/plans/2026-08-27-pipeline-final-plan.d/2026-08-27-pipeline-final-plan--item-2p-review-yield-protocol.md
git commit -m "docs(plans): mark the pi-replacement program and 0827 items 7b/10 withdrawn (ADR 0060)"
```

  These edits leave design-review tokens pending on the five docs. The agent does **not** release them: `design-clear.sh --yes` is a documented self-bypass. Ask the operator to choose one of two things. Either release them interactively, with a TTY confirm, one doc at a time: `scripts/design-clear.sh --all-for-doc docs/plans/2026-08-23-pi-replacement.md`, and the same for the other four. Or run `busdriver:blueprint-review` over them. If the gate blocks the `git commit` itself, stop there and ask the same question before retrying.

---

## Codex handoff

Outcome 3 (default executor). There are nine tasks and the plan is well over 3KB. The edits are anchor-based inside a 2,700-line script and need judgment between steps.

## Operator tasks (after merge — the operator runs these; they are outside the repo)

Do these on **both** hosts (Mac and um). Deleting the code revokes nothing.

1. **Config key.** Back up, then drop `.pi_read`:
   ```bash
   cp ~/.claude/busdriver.json ~/.claude/busdriver.json.bak-pre-pi-withdrawal
   jq 'del(.pi_read)' ~/.claude/busdriver.json > ~/.claude/busdriver.json.tmp && mv ~/.claude/busdriver.json.tmp ~/.claude/busdriver.json
   jq 'has("pi_read")' ~/.claude/busdriver.json   # expect: false
   ```
2. **Revoke the Google OAuth grant** pi-antigravity used.
   - First find out which Google account pi logged in with and which one `agy` uses. The file's top level is `version` / `activeAccountId` / `accounts`, so list only the emails with `jq -r '.accounts[] | .email' ~/.pi/agent/antigravity-accounts.json` (the schema is in pi-antigravity's `src/auth/accounts.ts`). Never print whole records: each one carries live `access` and `refresh` tokens next to `email`. ADR 0052 recommended a separate account, and that was never checked.
   - pi-antigravity impersonates Antigravity's own OAuth client (ADR 0052), so on a shared account Google shows **one** Antigravity entry for both. Revoking it **will** log `agy` out there.
   - Revoke: Google Account → Security → *Your connections to third-party apps & services* → Antigravity → *Delete all connections*. Then re-login `agy` if it shared the account, and confirm with any `--cli agy` dispatch.
   - On a separate pi-only account, the revoke touches only pi.
3. **Wipe the credential store**, after step 2:
   ```bash
   ls -la ~/.pi/agent/   # look before deleting
   rm -f ~/.pi/agent/auth.json ~/.pi/agent/antigravity-accounts.json
   find ~/.pi/agent -maxdepth 1 -type f -name 'auth.json.bak.*' -print -delete   # no glob: zsh aborts an unmatched one
   ```
4. **Uninstall pi** (optional, recommended): `npm uninstall -g @earendil-works/pi-coding-agent`, then `rm -rf ~/.pi` once nothing else of yours lives there. Check `ls ~/.pi` first. On um the install path may differ, so use `command -v pi` there.
5. **Stale jails** from interrupted runs, if any: `d="${TMPDIR:-/tmp}"; ls -d "$d"/busdriver-pi-* 2>/dev/null`. Remove each by its literal path.

## Out of scope

- The agy ToS question the council raised: a 2026-10-19 Google forum reply reportedly says wrapping the official `agy` CLI can also risk suspension. It is unverified and affects a lane that stays. File it as a separate issue.
- Tightening `dispatch.sh`'s shebang to `/bin/bash -p` and dropping `tests/test-trusted-review-cli.sh`'s exception. That needs bash 3.2 verification of every remaining arm. File it as a follow-up issue.
- Item 7a-i of the 0827 plan (the advisory's discriminated-result refactor). It is unaffected and stays as planned.
- Rewriting history in ADRs, CHANGELOG, `docs/plans/2026-10-05-*`, or the dispatch log.

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
