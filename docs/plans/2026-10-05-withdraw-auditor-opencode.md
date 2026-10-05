# Withdraw the Auditor (Mechanism Witness) and the opencode CLI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use busdriver:subagent-driven-development (recommended) or busdriver:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the auditor / Mechanism Witness review voice and every code path that exists only to run the `opencode` CLI, so busdriver no longer depends on opencode.

**Architecture:** This change only removes things. The witness has two surfaces: the auxiliary 4th voice in blueprint-review, and the third expert witness in ultimate-council. Both are deleted, along with the opencode dispatch lane in `dispatch.sh` and `resolve-cli.sh`, the plugin-owned opencode sandbox config, the `.auditor.model` operator key, and the tests that pin them.

`opencode` joins the existing **removed-CLI** set (`amp|claude|aider`), so a stale `opencode` token in an operator's config is warned about and skipped exactly as `amp` is. The shared model-config reader `_bd_read_auditor_model` stays; it is renamed `_bd_read_lane_model` and loses only its `auditor` key.

The order keeps every commit runnable:
1. Docs.
2. blueprint-review.
3. council.
4. dispatch.sh, resolve-cli.sh and every test that pins them, in **one** commit. The suites cross-pin both files, so splitting them leaves a red tree in between.
5. A guard test.
6. Records and full verification.

**Tech Stack:** bash 3.2-compatible shell, Markdown skills, shell gate-tests in `tests/` (CI runner `scripts/ci/run-shell-tests.sh`), ShellCheck, Python fences inside some suites.

**Global Constraints:**
- **Removal only.** A stale `opencode` / `.auditor` config value must degrade exactly as a removed CLI or an unknown key does today: warn and skip, or return the default. It must never newly crash a review. Added files: one regression test (Task 5).
- **Must keep working:**
  - The pi read lane (`--cli pi-read`, `resolve_pi_read_model`, `pi_read.model`), including every `opencode-go` *provider* mention. The provider is pi's; this ADR covers the CLI only.
  - `agy-read`, `agy-prose` / writing-prose, the UltraOracle, and the Mythos Witness.
  - The `BUSDRIVER_STATE_DIR=.claude` pins in `tests/test-pre-pr-gate.sh` and `tests/test-pr-dual-voice.sh`. They guard against an ambient `.opencode` state dir from the #251 port withdrawal and are unrelated to this change.
- **Droid is out of scope** (that is the next PR). Keep every droid route, escalation path and droid test. Where a droid-exemption predicate lists `opencode`, remove only that member.
- **Delete complete branches, never line ranges.** Line numbers below are as of HEAD `bc5667e8` and serve only to locate code. The unit of deletion is a whole `if`/`elif`/`case` arm or a whole function. When an opencode arm has a non-opencode sibling (`else` / `*)`), the sibling body becomes the only path, unchanged. **Exception:** a case label shared with live CLIs (`codex|agy|droid|node|opencode)`) loses only the `|opencode` member. The arm stays.
- **"Done" is defined by a residue grep, not by this plan's site lists.** Each task names the sites known at plan time *and* ends with an exact residue grep and its allow-list. Any hit the lists missed is deleted or re-worded under the same rules.
- Historical records stay unedited: `docs/adr/*` (except Task 1's status notes), `CHANGELOG.md`, `docs/plan-history/`, and the Version History sections inside SKILL.md files.
- Also untouched:
  - `.upstream-sources.json`; its opencode exclusion records explain why upstream opencode files are not synced.
  - `agents/a11y-architect.md` and `agents/opensource-sanitizer.md`, where "auditor" is a generic word.
- No file under `hooks/gate-scripts/**` or `scripts/hooks/**` changes. Verified at plan time: 0 hits for `opencode|auditor|Mechanism Witness`. If one must change, run `./scripts/gate-integrity.sh --update` in the same commit.
- ShellCheck stays clean on every modified `.sh`. Every touched suite must **run to completion**: no hard-exit or Python `IndexError` from a vanished anchor.
- Targeted test loops accumulate failures and exit non-zero. The full run uses `bash scripts/ci/run-shell-tests.sh`.
- Conventional Commits, one commit per task.

---

## File map

| File | Action | Task |
|---|---|---|
| `docs/adr/0051-withdraw-mechanism-witness-and-opencode.md` | create | 1 |
| `docs/adr/0027-k3-mechanism-witness-ultimate-tier.md`, `docs/adr/0030-blueprint-blocking-window.md`, `docs/adr/0005-codex-auto-retrigger.md`, `docs/adr/0006-pr-mode-codex-deep-review.md` | status note at the top only. **Not** the same-numbered twins `0027-review-once-bot-stranded-clean-review.md` / `0030-premerge-marker-head-sha-binding.md` | 1 |
| `.claude/busdriver.json` | drop the two `*.auditor` routes | 1 |
| `skills/blueprint-review/scripts/run-design-review-loop.sh` | remove the witness | 2 |
| `skills/blueprint-review/SKILL.md` | remove the witness prose; recompute the timeout note | 2 |
| `tests/test-blueprint-auditor-deadline.sh`, `tests/test-auditor-grace-budget.sh` | delete | 2 |
| `tests/test-reviewer-timeout.sh` | delete the auditor assertion (L133-137) | 2 |
| `.github/workflows/tests.yml:433-435` | comment | 2 |
| `skills/council/SKILL.md`, `commands/ultimate-council.md` | remove the witness | 3 |
| `tests/test-ultimate-tier.sh`, `tests/test-marker-glob-specificity.sh` | drop witness anchors; re-anchor the fence | 3 |
| `skills/dispatch-cli/scripts/dispatch.sh`, `scripts/lib/resolve-cli.sh` | remove the opencode lane | 4 |
| `scripts/lib/opencode-review-config.json` | delete | 4 |
| `tests/test-opencode-review-arm.sh` → `tests/test-review-boundaries.sh` | rename + delete opencode-only blocks | 4 |
| `tests/test-auditor-model-config.sh` → `tests/test-lane-model-config.sh` | rename + trim | 4 |
| `tests/test-pi-dispatch-arm.sh`, `tests/test-trusted-review-cli.sh`, `tests/test-agy-read-lane.sh`, `tests/test-agy-prose-lane.sh`, `tests/test-grok-sandbox-arm.sh`, `tests/test-dispatch-skipped-status.sh` | named edits | 4 |
| `skills/dispatch-cli/SKILL.md`, `skills/writing-prose/SKILL.md:140`, `README.md:85,100`, `.claude/CLAUDE.md:101` | prose | 4 |
| `scripts/ci/shell-test-durations.tsv` | drop/rename/add rows | 2, 4, 5 |
| `tests/test-no-auditor-lane.sh` | create | 5 |
| `docs/plans/2026-08-23-pi-replacement.md`, `docs/plans/2026-08-27-pipeline-final-plan.md` | status notes | 6 |

---

### Task 1: Decision record + repo routes

**Files:**
- Create: `docs/adr/0051-withdraw-mechanism-witness-and-opencode.md`
- Modify (top only): `docs/adr/0027-k3-mechanism-witness-ultimate-tier.md`, `docs/adr/0030-blueprint-blocking-window.md`, `docs/adr/0005-codex-auto-retrigger.md`, `docs/adr/0006-pr-mode-codex-deep-review.md`
- **Do NOT touch** `docs/adr/0027-review-once-bot-stranded-clean-review.md` or `docs/adr/0030-premerge-marker-head-sha-binding.md`. Those are unrelated ADRs that happen to share the numbers.
- Modify: `.claude/busdriver.json`

**Interfaces:** Produces ADR 0051. Later tasks cite it in comments and prose.

- [ ] **Write ADR 0051** with exactly this content:

```markdown
# ADR 0051 — Withdraw the Mechanism Witness (auditor) and the opencode CLI

## Status

**Accepted (2026-10-05).** Supersedes [ADR 0027](./0027-k3-mechanism-witness-ultimate-tier.md).
Amends [ADR 0030](./0030-blueprint-blocking-window.md) (the witness reap leaves the
blocking-window budget), [ADR 0005](./0005-codex-auto-retrigger.md) and
[ADR 0006](./0006-pr-mode-codex-deep-review.md) (opencode is no longer a review CLI of
any kind). Withdraws the `pi-auditor` role proposed in
`docs/plans/2026-08-23-pi-replacement.md` §0.2.

## Context

The auditor ("Mechanism Witness", claim-vs-mechanism lens) ran in two places:
- as an auxiliary, non-gating 4th voice in blueprint-review;
- as the third expert witness in ultimate-council.

Both ran the `opencode` CLI under a plugin-owned read-only sandbox config, with the
model taken from the operator key `.auditor.model`.

- **Measured value is mixed.** Against three already-passed PRs (2026-07-20) it
  produced one true positive that Codex and the Opus backstop both missed, one
  confident false positive, and one correct nothing-found, with inverted confidence.
- **Reliability is poor.** Since 2026-10-03 every dispatch has failed: the configured
  model routes through an OpenCode Go balancer whose subscriptions return 403. Two
  days of blueprint and council runs proceeded without anyone noticing. #662: it
  returns unparseable output on code-heavy design docs. #547: auxiliary voices, this
  one included, can consume a whole review round.
- **Maintenance cost is high.** Keeping it means keeping the opencode CLI and the
  harness that contains it: sandbox HOME, home-config validation, auth staging,
  banner detection and a clean-child re-exec. Most of `resolve-cli.sh`'s opencode
  surface exists only for this voice.

## Decision

Delete the voice and the opencode CLI dependency.
- **blueprint-review:** three reviewers (agy, codex, grok) plus the Claude arbiter,
  with the UltraOracle where enabled.
- **council:** five voices. ultimate-council adds **two** expert witnesses (the
  UltraOracle and the Mythos Witness), each still rendered separately and never a vote.
- **Config:**
  - `opencode` joins the removed-CLI set (`amp|claude|aider`). A stale `opencode`
    route entry or `BUSDRIVER_REVIEW_CLI=opencode` is warned about and skipped exactly
    as `amp` is.
  - The `.auditor.model` key and the `blueprint-review.auditor` / `council.auditor`
    routes are retired. A leftover `.auditor.model` is ignored.
- **pi program:** the `pi-auditor` role is not built. The pi read lane and the
  `opencode-go` *provider* used by pi are outside this ADR.

## Alternatives

- **Migrate to a `pi-auditor` role** (the 2026-08-23 plan). Rejected: it builds a new
  lane (config key, prompt, parsing, deadlines, version certification) for a voice
  whose net value is uncertain.
- **Fold the lens into an existing reviewer prompt.** Not done now. It is cheap and
  reversible if the lens is wanted later (see Revisit trigger).
- **Keep it and fix the provider.** Rejected: it keeps the opencode dependency and
  the #662 / #547 failure modes.

## Consequences

- Blueprint review and council get shorter: no witness reap. One fewer third party
  receives repo content.
- The dedicated claim-vs-mechanism lens is gone, including the kind of unique catch
  it made once. The remaining reviewers and the arbiter still check claims, without
  a dedicated lens.
- #662 and #817 become obsolete. #547 and #570 shrink to their non-witness halves.

## Revisit trigger

A review that later proves a stated mechanism false, where the miss would plausibly
have been caught by a claim-vs-mechanism pass. Then add one line to an existing
reviewer prompt before considering a new voice.
```

- [ ] **Status notes.** Add these directly under the `# ADR …` title line of each **exact file** listed above. Match by filename, never by `# ADR 0027` / `# ADR 0030` title, because two files share each of those numbers:
  - `0027-k3-mechanism-witness-ultimate-tier.md`: `> **Superseded by [ADR 0051](./0051-withdraw-mechanism-witness-and-opencode.md) (2026-10-05)** — the Mechanism Witness and the opencode CLI were withdrawn.`
  - `0030-blueprint-blocking-window.md`: `> **Amended by [ADR 0051](./0051-withdraw-mechanism-witness-and-opencode.md) (2026-10-05)** — the Mechanism Witness reap no longer exists; its budget rows are historical.`
  - 0005 and 0006: `> **Amended by [ADR 0051](./0051-withdraw-mechanism-witness-and-opencode.md) (2026-10-05)** — opencode is no longer a review CLI of any kind.`
- [ ] **`.claude/busdriver.json`:** delete the `"council.auditor": [...]` and `"blueprint-review.auditor": [...]` entries, and the trailing comma left behind. Keep the existing formatting of every other line.
- [ ] **Verify:**
  - `jq -e '[.routes | keys[] | select(test("auditor"))] | length == 0' .claude/busdriver.json` → `true`.
  - `git diff --stat -- docs/adr/` lists exactly the four files above plus the new 0051.
  - `npm run validate` → exit 0.
- [ ] **Commit:** `docs(adr): 0051 withdraw the Mechanism Witness and the opencode CLI`

### Task 2: blueprint-review — remove the witness

**Files:**
- Modify: `skills/blueprint-review/scripts/run-design-review-loop.sh`
- Modify: `skills/blueprint-review/SKILL.md`
- Delete: `tests/test-blueprint-auditor-deadline.sh`, `tests/test-auditor-grace-budget.sh`
- Modify: `tests/test-reviewer-timeout.sh`, `tests/test-auditor-model-config.sh` (blueprint block only), `tests/test-blueprint-oracle-deadline.sh` and `tests/test-blueprint-oracle-status-line.sh` (comments only), `scripts/ci/shell-test-durations.tsv`, `.github/workflows/tests.yml`

**Interfaces:**
- Consumes: nothing.
- Produces: the loop resolves no `blueprint-review.auditor` route and never reads or writes `auditor.json` / `auditor-raw.txt`.

- [ ] **Loop, known sites** (delete whole blocks):
  - `--claude-only` binding of `AUDITOR_OUTPUT_FILE` (~L903-908).
  - The two `get_review_file "auditor…"` arguments in the stale-artifact cleanup (~L950-951). Keep the other reviewer artifacts in that list.
  - The witness dispatch block from `# ── Mechanism Witness (AUXILIARY, non-converging)` (~L1303) through the `else create_error_json "auditor" "CLI not available …"` branch (~L1450).
  - The bounded reap from `# BOUNDED reap for the Mechanism Witness` (~L1456) through the `"witness killed at reap limit …"` backstop (~L1520).
  - The status line block from `# Mechanism Witness — AUXILIARY, never gates coverage.` (~L1639) through its closing `fi` (~L1661).
  - The arbiter-prompt paragraph from `MECHANISM WITNESS (opencode) -- AUXILIARY, *NOT* A REVIEWER.` (~L1918) through `$(cat "$AUDITOR_OUTPUT_FILE" …)` (~L1931), plus any `AUDITOR_*` reference in the same heredoc (~L1940).
- [ ] **Loop, harness-budget comment (move, then restate).** The `# HARNESS BUDGET:` comment (~L1364-1385) sits **inside** the witness block deleted above. Before deleting that block, move the comment to sit directly after the `_REV_TIMEOUT` clamp (`[[ "$_REV_TIMEOUT" -gt 1800 ]] && _REV_TIMEOUT=1800`, ~L1074), then restate it without the witness:

```bash
  # HARNESS BUDGET: the operator's BASH_MAX_TIMEOUT_MS must exceed the serial
  # worst case, which is a FORMULA, not a fixed number — it moves with the
  # reviewer budget and the oracle's configured cap:
  #     attach_preflight + max( _REV_TIMEOUT + droid rescue(≤1200),
  #                             ultraOracle.timeoutCapSeconds + 90 )
  # attach_preflight is NOT inside either term. In oracle ATTACH mode with a cold
  # Chrome, ultra_oracle_consult runs scripts/ultra-oracle-attach-preflight.sh
  # SYNCHRONOUSLY, and ULTRA_ORACLE_DEADLINE is only anchored AFTER dispatch
  # returns — so the preflight elapses before the oracle's own budget starts
  # counting. Budget ~20-30s; zero when Chrome is warm or attach mode is off.
  # Left term: 2400s at the default reviewer budget (1200+1200), 3000s at the
  # 1800 clamp (1800+1200). At the documented oracle ceiling of 3600 the RIGHT
  # term binds instead (3690s ⇒ ~3.7e6 ms).
```

  Keep any sentence of the original comment that follows this excerpt and does not mention the witness/auditor (e.g. the "size the harness timeout" advice). The reviewers' own deadline is computed exactly as before; the witness only ever widened the window.
- [ ] **Loop, comments that justify something by citing the witness.** Restate each on its own terms; change no code.
  - ~L218: `the same treatment the sibling BLUEPRINT_AUDITOR_GRACE already has below` → `a repo-injectable env var, so it is sanitized and clamped (#325 / ADR 0016)`.
  - ~L1062-1065: `1800 = the same bound BLUEPRINT_AUDITOR_TIMEOUT already accepts, so the override grants no time a branch could not get by simply making the reviewer slow. Same sanitize-then-clamp shape as _AUD_TIMEOUT below:` → `1800 bounds how long a branch can hold this phase. Sanitize-then-clamp:`.
  - Oracle comments that compare the oracle to the witness. Find them by anchor text, not line number: `ADR 0027 closed`, `unlike the witness's auditor.json`, `the distinction ADR 0027 drew`, `the one deliberate divergence from the witness's line`, `Unlike the witness line (Phase 2)`. E.g. `ABSENT vs FAILED, the distinction ADR 0027 drew for the witness` → `ABSENT vs FAILED: "never ran" must not read as "found nothing"`. A sentence that only exists to contrast with the witness is deleted, not reworded.
- [ ] **Loop residue grep (completion criterion):** `grep -nE 'AUDITOR|_aud_|auditor|[Ww]itness|MECHANISM WITNESS|opencode|ADR 0027' skills/blueprint-review/scripts/run-design-review-loop.sh | grep -v 'Mythos Witness'` → no output. The only exemption is the Mythos Witness, a different surface; a bare "witness" anywhere else is residue.
- [ ] **SKILL.md:**
  - Delete the `auditor.json` sentence from item 2 of the EXTREMELY-IMPORTANT block (L29).
  - Delete the `- **Mechanism Witness** (opencode): …` overview bullet (~L42) **and** its lead-in line `Plus one **advisory** voice that is deliberately NOT a coverage slot:` (~L41). The lead-in introduces only that bullet.
  - Delete the witness status paragraph (~L170).
  - Rewrite the UltraOracle status paragraph (~L172-177) on its own terms: it prints `ran (N lines)` / `absent` / `FAILED -- <reason>`; it is silent when the surface is disabled (default-OFF opt-in); it is emitted on `--claude-only` resumes, reporting `absent — advisory not harvested before arbiter re-run`; it never gates and carries the `AUXILIARY, not a reviewer` tag.
  - Bash-tool timeout note (~L185): delete the witness dispatch and the witness reap from the phase list. Restate the serial worst case with the same formula as the loop comment: `attach_preflight + max(reviewer budget + droid rescue 1200, timeoutCapSeconds + 90)`. That is ~2400s at the default reviewer budget of 1200, **~3000s at the `BLUEPRINT_REVIEWER_TIMEOUT` clamp of 1800**, and ~3690s once the oracle cap is at its 3600 ceiling. Never label 2400 alone as the worst case. Keep the advice to pass the tool's maximum timeout. Delete the closing `— **not** The witness budget.`
  - Leave Version History untouched.
- [ ] **SKILL.md residue grep:** `awk '/^## Version History/{exit} {print}' skills/blueprint-review/SKILL.md | grep -nE 'auditor|Mechanism Witness|witness line|opencode|Plus one \*\*advisory\*\* voice'` → no output.
- [ ] **Tests:**
  - `git rm tests/test-blueprint-auditor-deadline.sh tests/test-auditor-grace-budget.sh`.
  - Delete their rows `test-blueprint-auditor-deadline` and `test-auditor-grace-budget` from `scripts/ci/shell-test-durations.tsv`. (Rows within each duration group are alphabetical. Any row this plan renames or adds is re-inserted at its sorted position, never renamed in place.)
  - In `tests/test-reviewer-timeout.sh`, delete the assertion on `execute_review "$AUDITOR_CLI" "$FULL_PROMPT" "$_AUD_TIMEOUT"` (L133-137) and nothing else.
  - In `tests/test-auditor-model-config.sh`, delete the blueprint witness-classification block in one piece. It runs from the comment `# The library skip must return 4 (SKIPPED), not 1 (failed) or 3 (BUILTIN_FALLBACK).` (~L277) through the `fail "rc=4 message will not match the absent render case in $LOOP"` line and its closing `||` pair (~L324), including the `LOOP=` assignment, the `_route()` helper and both `case "$(_route …)"` blocks. That block executes the loop's witness code, so it must leave in this commit. Everything else in this file stays until Task 4.
  - Comment-only edits (they name deleted files or the withdrawn witness):
    - `tests/test-blueprint-oracle-deadline.sh` L17: `Structure mirrors tests/test-auditor-grace-budget.sh:` → `Structure:`.
    - Same file, L61: `it must sanitize like the sibling BLUEPRINT_AUDITOR_GRACE and may only SHORTEN.` → `it must be sanitized (repo-injectable, #325) and may only SHORTEN.`
    - `tests/test-blueprint-oracle-status-line.sh` L9 and L58: drop the ADR 0027 / "the witness carries" comparisons. State the rule on the oracle's own terms.
- [ ] **tests.yml** (~L434): `# tests/test-auditor-grace-budget.sh and tests/test-ultra-oracle.sh are` → `# tests/test-ultra-oracle.sh is`, with the following verbs made singular. Keep the zsh install step.
- [ ] **Run:**

```bash
fail=0; for t in blueprint-oracle-deadline blueprint-oracle-status-line reviewer-timeout auditor-model-config ultra-oracle blueprint-early-stop-parks blueprint-pass-verdict-countable; do
  bash "tests/test-$t.sh" >"/tmp/t-$t.log" 2>&1 && echo "ok $t" || { echo "FAIL $t"; tail -20 "/tmp/t-$t.log"; fail=1; }
done; shellcheck skills/blueprint-review/scripts/run-design-review-loop.sh || fail=1; exit $fail
```

  Expected: every line `ok`, exit 0.
- [ ] **Commit:** `refactor(blueprint-review): remove the Mechanism Witness voice (ADR 0051)`

### Task 3: council / ultimate-council — remove the witness

**Files:**
- Modify: `skills/council/SKILL.md`, `commands/ultimate-council.md`
- Modify: `tests/test-ultimate-tier.sh`, `tests/test-marker-glob-specificity.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: council reads no `council.auditor`, `MECHANISM_WITNESS`, `AUDITOR_CLI`, `_AUD_TO` or `witness.txt`.

- [ ] **`skills/council/SKILL.md`, known sites:**
  - Frontmatter description (L8-10): `"ultimate-council" adds three expert witnesses — the UltraOracle, the Mythos Witness (Claude Fable, subagent), and the Mechanism Witness (claim-vs-mechanism) —` → `"ultimate-council" adds two expert witnesses — the UltraOracle and the Mythos Witness (Claude Fable, subagent) —`.
  - Body intro (L17): change "THREE expert witnesses" to two; drop the Mechanism Witness and its Step 4.7 pointer.
  - L29: delete `The **Mechanism Witness** below is likewise not a fixed role` (and the rest of that sentence).
  - Roles section: delete the `**Mechanism Witness (expert witness, …)**` paragraph (~L31), its `No droid fallback` bullet (~L36) and the `**Known limitation …**` paragraph (~L38).
  - L40: drop `(plus the Mechanism Witness, ultimate-council only)`.
  - L42 runtime-retry paragraph: drop only the witness's fallback exemption clause.
  - Step 4 title (~L71) and first paragraph (~L73): drop the witness.
  - Output table (~L110): delete the `witness.txt` row.
  - L124: drop `witness.txt` from any file list.
- [ ] **Step 4b bash fence:**
  - Delete `AUDITOR_CLI=$(resolve_role_cli "council.auditor")` (~L142), the literal `MECHANISM_WITNESS=0` and its comment (~L145), the guarded witness dispatch (~L167), and its separate reap with `_AUD_TO` / `_ag_cap` (~L177 onward).
  - The agy / codex / grok dispatch commands and the `(( ${#PIDS[@]} )) && wait "${PIDS[@]}"` command must stay byte-identical. The two comment lines directly above that wait (`# Block on the FIXED voices only; the Mechanism Witness is reaped separately on its` / `# OWN budget (_AUD_TO + 10s). Override with COUNCIL_AUDITOR_GRACE. See (h).`) annotate the wait, not the reap. Replace them with the single line `# Block on the fixed voices.`; do not delete them with the reap.
- [ ] **Design notes:**
  - Delete `(c)` (MECHANISM_WITNESS literal), `(f)` (opencode read-only config), `(g)` (budget normalizers; inside this fence they only serve `_AUD_TO` / `_ag_cap`; the fixed voices use a literal `--timeout 300`), `(h)` (witness reap), and the trailing `_kt` Note.
  - **Rewrite, don't re-point, the citations of deleted notes.** In the surviving cleanup note (currently `(j)`), replace `Named explicitly rather than \`"$D"/*\` for the reason in (g) — no globs in this fence.` with `Named explicitly rather than \`"$D"/*\`, so cleanup removes only the files this block wrote.` The no-glob rule existed only because the `_kt` function lived in this fence (the deleted trailing Note says so). Once `_kt` is gone the fence defines no function and the rule stops applying, so its citation must not be pointed at whichever surviving note inherits the letter `(g)`. In-fence `see (g)` comments sit on `_AUD_TO` / `_ag_cap` lines and go with them. The one `See (h)` sits above the `PIDS` wait and is rewritten as described under the Step 4b fence above.
  - Re-letter the remaining notes contiguously: `(a) (b) (d) (e) (i) (j)` → `(a) (b) (c) (d) (e) (f)`. Then update every cross-reference to a **surviving** note to its new letter (e.g. `see (d) and (i)` → `see (c) and (e)`, `see (j)` → `see (f)`, `see (i)` → `see (e)`). This includes the reference **outside** Step 4b, in the Step 4.5 UltraOracle fence (~L250, `#813, see (i)` → `#813, see (e)`). Afterwards `grep -nE '\((g|h|i|j)\)' skills/council/SKILL.md` must print nothing anywhere in the file (it has no Version History section to exempt).
- [ ] **Prompt templates:**
  - In `**Prompt template** for Agy/Codex/Grok/opencode` (~L220), drop `/opencode`.
  - Delete `**For opencode (Mechanism Witness, …):**` and the `> **Mechanism Witness is snippet-only…**` callout (~L224-226).
  - Drop the opencode mentions in ~L216 and ~L230.
- [ ] **Step 4.7:** delete it from `### Step 4.7: Optional Mechanism Witness` (~L403) through its Bash-tool-timeout callout (~L432).
- [ ] **Synthesis:**
  - ~L442: drop `/opencode`.
  - ~L467: `the UltraOracle …, the Mythos Witness AND the Mechanism Witness (both ultimate-council only)` → `the UltraOracle … and the Mythos Witness (ultimate-council only)`.
  - Delete the `## Mechanism Witness — Expert Witness [claim-vs-mechanism]` section (~L503) and its template.
  - `## Multi-Round` (L529, L532) lists council **voices**, not witnesses. Drop only the opencode member: `For Agy + Codex + Grok + opencode` → `For Agy + Codex + Grok`, and `Frame for Agy/Codex/Grok/opencode` → `Frame for Agy/Codex/Grok`. Do not add the UltraOracle or Mythos Witness there.
- [ ] **`commands/ultimate-council.md`:**
  - L2: `THREE expert witnesses — UltraOracle (ChatGPT Pro), the Mythos Witness (Claude Fable, in-harness subagent), AND the Mechanism Witness …` → `TWO expert witnesses — UltraOracle (ChatGPT Pro) and the Mythos Witness (Claude Fable, in-harness subagent) …`.
  - L7: `force all THREE` → `force both`.
  - Delete the L11 bullet (`MECHANISM_WITNESS=0` → `1` flip).
  - L15: `All three are EXCLUDED` → `Both are EXCLUDED`; drop the `## Mechanism Witness` section name and any `MECHANISM_*` banner.
  - L17: delete the clause that says the Mechanism Witness shares the gate, and `MECHANISM_WITNESS=1`.
  - L19: delete the bolded sentence that begins with the Mechanism Witness being gated on the same `MYTHOS_ATTEMPT` output.
- [ ] **Residue grep (completion criterion):** `for f in skills/council/SKILL.md commands/ultimate-council.md; do awk '/^## Version History/{exit} {print}' "$f" | grep -nE 'MECHANISM|Mechanism Witness|council\.auditor|AUDITOR|_AUD_|witness\.txt|(^|[^A-Za-z0-9_-])opencode([^A-Za-z0-9_-]|$)|THREE expert|three expert'; done` → no output.
- [ ] **`tests/test-ultimate-tier.sh`:**
  - Delete the whole `# ── Mechanism Witness authorization boundary (ADR 0027)` block as one unit (~L153-179). It runs from that header through the `fi` that closes check 4 (`ONLY when the Step 4.6 gate returned …`), and includes checks 1-4: the `mw_lit` if/else, both `anchor` calls, and the check-4 if/else. Delete whole `if … fi` statements only, never just the grep-matched lines inside them (that leaves empty `if`/`else` bodies, a syntax error). Afterwards `bash -n tests/test-ultimate-tier.sh` succeeds and `grep -n 'MECHANISM\|Mechanism' tests/test-ultimate-tier.sh` prints only the new (w) block below.
  - Add before the final summary line:

```bash
# ── (w) Mechanism Witness withdrawn (ADR 0051) ───────────────────────────
for f in "$DIR/skills/council/SKILL.md" "$DIR/commands/ultimate-council.md"; do
  body="$(awk '/^## Version History/{exit} {print}' "$f")"
  if printf '%s\n' "$body" | grep -qE 'MECHANISM_WITNESS|council\.auditor|Mechanism Witness|(^|[^A-Za-z0-9_-])opencode([^A-Za-z0-9_-]|$)'; then
    fail "Mechanism Witness / opencode still referenced in $(basename "$f") body"
  else
    pass "no Mechanism Witness / opencode in $(basename "$f") body"
  fi
done
```

- [ ] **`tests/test-marker-glob-specificity.sh`** (~L1370-1374), in the Python fence:
  - Change `step4 = fence("MECHANISM_WITNESS=")` to `step4 = fence('RESEARCHER_CLI=$(resolve_role_cli "council.researcher")')`.
  - Change `cmd = "ULTRA_ORACLE_COUNCIL_FORCE=1\n" + step4.replace("MECHANISM_WITNESS=0", "MECHANISM_WITNESS=1")` to `cmd = "ULTRA_ORACLE_COUNCIL_FORCE=1\n" + step4`.
  - Keep the `WAIT` assertion and the UltraOracle splice unchanged.
  - The prose comment above the fence (~L1356, `… MECHANISM_WITNESS flipped to 1`) → `the Step 4 fence, assembled as an ultimate-council run assembles it`.
  - Afterwards `grep -n 'MECHANISM\|Mechanism' tests/test-marker-glob-specificity.sh` → no output.
- [ ] **Run:**

```bash
fail=0; for t in ultimate-tier marker-glob-specificity ultraoracle-evidence; do
  bash "tests/test-$t.sh" >"/tmp/t-$t.log" 2>&1 && echo "ok $t" || { echo "FAIL $t"; tail -20 "/tmp/t-$t.log"; fail=1; }
done; exit $fail
```

  Expected: all `ok`. If `test-ultraoracle-evidence.sh` *asserts* a witness string, delete that assertion only.
- [ ] **Commit:** `refactor(council): remove the Mechanism Witness; ultimate-council has two expert witnesses (ADR 0051)`

### Task 4: Remove the opencode lane (dispatch.sh + resolve-cli.sh + pinned tests, one commit)

**Files:**
- Modify: `skills/dispatch-cli/scripts/dispatch.sh`, `scripts/lib/resolve-cli.sh`
- Delete: `scripts/lib/opencode-review-config.json`
- Rename + trim: `tests/test-opencode-review-arm.sh` → `tests/test-review-boundaries.sh` (keeps sections 5, 7, 8, the (h)-(j) dispatch boundary blocks and section 10)
- Rename: `tests/test-auditor-model-config.sh` → `tests/test-lane-model-config.sh`
- Modify: `tests/test-pi-dispatch-arm.sh`, `tests/test-trusted-review-cli.sh`, `tests/test-agy-read-lane.sh`, `tests/test-agy-prose-lane.sh`, `tests/test-grok-sandbox-arm.sh`, `tests/test-dispatch-skipped-status.sh`, `scripts/ci/shell-test-durations.tsv`
- Modify (prose): `skills/dispatch-cli/SKILL.md`, `skills/writing-prose/SKILL.md`, `README.md`, `.claude/CLAUDE.md`

**Interfaces:**
- Consumes: Tasks 2-3 removed the loop and council callers.
- Produces:
  - `--cli` accepts `codex|agy|agy-read|agy-prose|droid|grok|pi-read|both|all|auto`.
  - `opencode` is a removed CLI.
  - `_bd_read_lane_model HOME DEFAULT KEY` takes a required KEY in `{pi_read, pi_read_raw, pi_legacy_raw, agy_read, writing_prose, writing_prose_raw}`. An unknown or empty KEY returns DEFAULT.

**dispatch.sh, known sites:**
- [ ] Header and help (L86, L438, L441, L457): drop opencode from the CLI lists and the enum. Drop the `unlike opencode …` clause in L457.
- [ ] Validator (~L614-615): remove the `!= "opencode"` conjunct and `opencode|` from the error string.
- [ ] Delete the `resolve_auditor_model` fallback shim and its comment (~L219-232).
- [ ] Delete the #541 banner-helper fallback: the comment at ~L354 and the `if ! type _oc_output_is_banner_only &>/dev/null; then … fi` block. Its only dispatch.sh caller (~L1689) is inside the arm deleted below.
- [ ] `all` candidates (~L1027-1041):
  - The list becomes `for c in codex agy droid grok pi-read; do`.
  - Delete the `[[ "$c" == "opencode" && "$MODE" == "auto" ]] && continue` line.
  - Comment → `pi-read is excluded from auto/write MODE`.
  - Lower the cap to match: `[[ ${#ALL_CLIS[@]} -ge 6 ]] && break` → `-ge 5`, and the comment `The cap admits all six candidates; pi-read is last.` → `The cap admits all five candidates; pi-read is last.` In the same commit, update the pin in `tests/test-pi-dispatch-arm.sh` (~L1250-1252: the `-ge 6` grep, the `admits all six` message, and the L1250 comment's `council witness` mention).
- [ ] Delete `local _oc_no_model=0` (~L1182) and the auditor-precondition comment above it.
- [ ] Delete the whole `opencode)` case arm (~L1460 to its `;;`).
- [ ] Droid-exemption at ~L2703: remove only the `&& [[ "$name" != "opencode" ]]` conjunct. The droid fallback logic stays.
- [ ] Delete the `opencode` status lines at ~L2685 and ~L2790-2791, and `[[ "${_oc_no_model:-0}" == "1" ]] && status="skipped"` (~L2801).
- [ ] `REPORT_NAME` whitelist (~L2939): drop `|opencode`.
- [ ] Re-word comment-only comparisons without naming opencode. Known sites: ~L631, ~L696, ~L873, ~L962-968, ~L1289, ~L1388, ~L2227; the pi-read arm comments that call it the opencode arm's "mirror image" (~L1727-1728, ~L1753, ~L1756, ~L1762); and the grok refusal's `same reasoning as opencode's missing .auditor.model` (~L2384-2385 → `a refusal (skipped), like pi-read with no model configured`). `_bd_read_auditor_model` → `_bd_read_lane_model`. No code change in these spots. This list is a starting point. The residue grep below is authoritative for dispatch.sh.

**resolve-cli.sh, known sites:**
- [ ] **Removed-CLI set: add `opencode`** at every site that lists `amp`:
  - L2731: `elif [[ "$cli" == "amp" || "$cli" == "claude" || "$cli" == "aider" || "$cli" == "opencode" ]]; then`.
  - L2857: `amp|claude|aider|opencode)`.
  - L2923 and L2963: add `|| "$default_primary" == "opencode"` / `|| "$default_fallback" == "opencode"`.
  - L3094: `gemini|amp|claude|aider|opencode)`.
  - These five lines, plus the two `!= "opencode"` skip tests in `describe_role_resolution` below, are the **only** places opencode may remain in resolve-cli.sh. Task 5's guard allows exactly those seven lines, as exact whole lines. So the comments that list the removed set are reworded without the name:
    - ~L2783: `["amp"] or ["gemini", "opencode"] route.` → `["amp"] or ["gemini", "claude"] route.`
    - ~L2906-2907: `a removed CLI (amp/opencode/` + `claude/aider)` → `a removed CLI (see the removed-CLI set`, `in Step 1)`.
    - ~L3025: `pruned unused backends (opencode/amp/claude/aider)` → `pruned unused backends (amp/claude/aider among them)`.
  - The user message `use 'codex', 'agy', 'droid', 'grok', or 'opencode' instead` appears at **four** sites: ~L2738 (route), ~L2858 (env), ~L2926 (defaults.primary), ~L2965 (defaults.fallback). At each, drop `, or 'opencode'` and make it `…, 'droid', or 'grok' instead`.
- [ ] **Shared arms: remove the member, keep the arm.** `_portable_timeout` has two case arms shared with CLIs that must keep working: `codex|agy|droid|node|opencode) ;;` (~L2070) and `codex|agy|droid|node|opencode)` (~L2219). At both, remove only `|opencode`. In their error strings (~L2071, ~L2238), `codex|agy|droid|node|opencode` → `codex|agy|droid|node`. **This is the explicit exception to the whole-arm rule.** Deleting these arms would send `--review` for codex/agy/droid/node to the error branch.
- [ ] **`resolve_role_cli`: delete the auditor containment guard.** Delete the comment block from `# Auditor containment guard (P1 — PR #435 review).` and the whole `case "$role_key" in council.auditor|blueprint-review.auditor) … esac` that follows it (~L2799-2828), plus the now-unused `local _bd_result`. The function body becomes exactly:

```bash
resolve_role_cli() {
  local role_key="$1"
  _resolve_role_cli_impl "$role_key"
}
```

- [ ] **Step 4b defaults: delete the auditor arm.** Delete the `council.auditor|blueprint-review.auditor)` arm and its 8-line comment (`# Auditor roles (added 2026-07-20, "opencode" voice) …`, ~L3030-3041). A leftover `*.auditor` key then falls through to Step 5 auto-detect, like any other unknown role.
- [ ] **`describe_role_resolution`** must mirror the resolver, or its provenance metadata names a CLI the resolver rejected:
  - Route scan (~L3094): `gemini|amp|claude|aider) i=$((i + 1)); continue ;;` → `gemini|amp|claude|aider|opencode) i=$((i + 1)); continue ;;`. Delete the `# opencode is Auditor-ONLY (#436) …` comment and its `if [[ "$cli" == "opencode" ]] && ! _is_auditor_role …` block (~L3096-3104).
  - Defaults (~L3108-3124): **drop only the `_is_auditor_role` disjunct**, so opencode is skipped for every role exactly as it already is for non-auditor roles. Keep the amp/claude/aider handling byte-identical. Those report `requested=amp` → `resolve-droid-fallback` today, and `derive_coverage` reads that reason, so touching it would change the blueprint coverage gate inside a removal-only change. The result:

```bash
      cli=$(_read_config_value "$cfg" ".defaults.primary")
      if [[ -n "$cli" ]]; then
        if [[ "$cli" != "opencode" ]]; then
          requested="$cli"; break
        fi
        # A removed-and-skipped primary: mirror _resolve_role_cli_impl's Step 4,
        # which tries defaults.fallback next within the SAME cfg, and apply the
        # same skip to the fallback so provenance never names a rejected CLI.
        cli=$(_read_config_value "$cfg" ".defaults.fallback")
        if [[ -n "$cli" && "$cli" != "opencode" ]]; then
          requested="$cli"; break
        fi
      fi
```

    Sections 8(b) and 8(d) of `tests/test-review-boundaries.sh` pin this unchanged.
  - Run `git grep -nw _is_auditor_role` → 0 hits outside its definition **before** deleting the function.
- [ ] **Delete the auditor-only `opencode` branches**, which the removed-set handling above now supersedes:
  - the route walker `elif [[ "$cli" == "opencode" ]] && ! _is_auditor_role "$role_key"; then …` (~L2742-2749);
  - the env-override `opencode` Auditor-only block (~L2862-2870);
  - the defaults-primary / defaults-fallback opencode-auditor branches (~L2928-2932 and the matching fallback block);
  - the `opencode is Auditor-ONLY (#436) — mirror …` branch after ~L3095.
  - Re-word the auto-cascade comment (~L2750-2770) to drop its opencode paragraph.
  - After this, `opencode` behaves exactly like `amp`: warned and skipped, and a pure `["opencode"]` route resolves to `unsupported:opencode`.
- [ ] **Delete these functions whole** (re-run `git grep -nw <fn>` first; after this task no caller remains):
  - `validate_opencode_home_config` (~L1426-1689)
  - `_bd_oc_stage_auth_json` (~L1695-1750)
  - `_bd_oc_auth_rc_classify` (~L1757-1767)
  - `_bd_oc_lane_cleanup` (~L1797-1802)
  - `_is_auditor_role` (~L2705-2710)
  - `_oc_output_is_banner_only` (~L3321-3345), after the `_run_review_with_retries` edit below
  - `_bd803_oc_lane_exit` (~L5675-5678)
  - `resolve_auditor_model` plus its `_BD_AUDITOR_MODEL=""` global (~L1315-1326)
  - `_bd_rm_sandbox_home` only if `git grep -nw _bd_rm_sandbox_home` shows no other caller; keep it if the pi lane uses it.
- [ ] **`_run_review_with_retries`:**
  - Change both `codex|agy|droid|opencode)` labels (~L3497, ~L3508) to `codex|agy|droid)`.
  - Delete only the banner-detection block that calls `_oc_output_is_banner_only` (~L3517-3528).
  - The retry loop is otherwise unchanged.
- [ ] **`_portable_timeout`:**
  - Delete the `--review opencode` staged-sandbox `if` (~L2421-2430).
  - Delete the `opencode` arms of the env-construction `if`s at ~L2437 and ~L2441.
  - Delete the opencode `if` arm of the perl branch that opens at ~L2472. Its `else` body (~L2509) becomes the unconditional path, byte-identical.
  - Delete complete `if/else/fi` units only. Afterwards `bash -n scripts/lib/resolve-cli.sh` succeeds.
- [ ] **`execute_review`:** delete the `opencode)` case arm (~L5342 to its `;;`) and the opencode threat-model comment above it (~L5286-5310).
- [ ] **Clean-child entry:** delete it from `if [[ "${BASH_SOURCE[0]-}" = "${0-}" && "${1:-}" = "--execute-opencode-review" ]]; then` (~L5575) through its `fi`.
- [ ] **Other single-arm sites:**
  - The trusted-CLI resolver's `opencode)` case (~L897-910); drop opencode from the #803 comment.
  - The `get_cli_install_hint` opencode line (~L1018).
  - The `--json` availability loop and any allow-list that enumerates opencode: drop the member.
  - The header threat-model sentences about `opencode-review-config.json` (~L20-40).
- [ ] **Rename the shared reader:**
  - `_bd_read_auditor_model` → `_bd_read_lane_model` at the definition (~L1196) and its 6 call sites (~L1837, 1838, 1846, 1867, 1890, 1899).
  - In its body, `"${3:-auditor}"` → `"${3:-}"`, and delete the `auditor)` case arm.
  - Update the comment naming `tests/test-auditor-model-config.sh` to `tests/test-lane-model-config.sh`.
- [ ] `git rm scripts/lib/opencode-review-config.json`.

**Tests in the same commit:**
- [ ] **`git mv tests/test-opencode-review-arm.sh tests/test-review-boundaries.sh`, then delete only its opencode-only blocks.** The file also carries the only coverage of boundaries that survive this change, so it is trimmed, not deleted. Block map at bc5667e8:

  | Lines (~) | Block | Action |
  |---|---|---|
  | 1-48 | header: `set -uo pipefail`, `REPO_ROOT`, `pass`/`fail`/`finish` | **keep**; delete the `CONFIG=` line (L21) and the `FAULT_GENERATOR` lines (L23-28; their only user is section 9(j)); rewrite the header comment (see below); `finish` prints `test-review-boundaries` |
  | 49-99 | sections 1-2 (shipped opencode config, env injection) | delete, **except** keep `RC=` and `DP=` (L84-85, inside section 2), which later blocks need under `set -u` |
  | 100-155 | sections 3-4 (opencode arm guards, neutral cwd) | delete |
  | 156-166 | section 5: `_bd_lib_dir` has no `$0` fallback | **keep** (the agy review guard still resolves plugin assets through `_bd_lib_dir`) |
  | 167-225 | section 6 (auditor route containment) | delete |
  | 226-295 | section 7: removed-CLI degradation via env / route / defaults | **keep, invert (e)** |
  | 296-372 | section 8: `describe_role_resolution` provenance | **keep, replace (c)** |
  | 373-791 | section 9 (a)-(j): `~/.opencode/opencode.json` validator | delete |
  | 792-799 | (g) "BOTH opencode arms call the shared guard" | delete |
  | 800-913 | (h) dispatch.sh shebang, (i) privileged bash suppresses function shadows, (j) function-clean boundary (nonce+sentinel re-exec, "refusing to continue") | **keep** (the only behavioural test of ADR 0016's dispatch.sh boundary) |
  | 914-945 | section 10: `_bd_valid_username` tilde-form allowlist | **keep** |
  | 946-end-1 | section 11 / 11a / 11b (#541 banner) | delete |
  | last line | `finish` | keep |

  - **Invert 7(e)** (~L283-287). The auditor-role positive control becomes a removed-CLI check:

```bash
  # (e) A leftover auditor route is a removed-CLI route like any other (ADR 0051).
  for _role in blueprint-review.auditor council.auditor; do
    _write_cfg "{\"version\":1,\"routes\":{\"$_role\":[\"opencode\"]}}"
    r=$(resolve_role_cli "$_role")
    [[ "$r" == "unsupported:opencode" ]] || { echo "  ✗ (e) $_role route [opencode] → '$r' (expected unsupported:opencode)"; ok=0; }
  done
```

  - **Replace 8(c)** (~L344-351) with a parity check against amp. It asserts what amp produces today rather than hard-coding a triple:

```bash
  # (c) Provenance for a pure removed route is identical to amp's (ADR 0051).
  _write_cfg '{"version":1,"routes":{"council.critic":["amp"]}}'
  amp_line=$(describe_role_resolution "council.critic" 2>/dev/null)
  _write_cfg '{"version":1,"routes":{"council.critic":["opencode"]}}'
  oc_line=$(describe_role_resolution "council.critic" 2>/dev/null)
  [[ -n "$amp_line" && "$oc_line" == "${amp_line//amp/opencode}" ]] \
    || { echo "  ✗ (c) pure [opencode] provenance '$oc_line' != pure [amp] '$amp_line'"; ok=0; }
```

  - Rewrite the section 7 and 8 titles, comments and pass/fail messages that say "Auditor-ONLY", "non-auditor roles" or "auditor role unaffected" to say opencode is a removed CLI (ADR 0051). Keep the fakes that make opencode look installed (`is_cli_available`, `_resolve_trusted_cli_bin`): they prove the refusal is not a missing-binary artifact.
  - If a kept block references a variable or helper defined only in a deleted block, move that one definition above its first use. Never keep a deleted block to satisfy a dependency. `bash tests/test-review-boundaries.sh` must reach `finish` and print a `✓` line for every kept block (5, 7, 8, (h), (i), (j), 10). A block that never prints is a silent skip, not a pass.
  - New header comment: this suite pins the review-lane boundaries that outlived the opencode lane (`_bd_lib_dir` resolution, the dispatch.sh function-clean boundary, the username allowlist) and how a stale `opencode` value degrades after ADR 0051.
  - Durations: delete the `test-opencode-review-arm` row and insert `test-review-boundaries` at its sorted position, keeping the value.
- [ ] `git mv tests/test-auditor-model-config.sh tests/test-lane-model-config.sh`. Delete its duration row and insert `test-lane-model-config` at its sorted position, keeping the value.
  - **Retarget, don't delete, the shared-reader security tests.** The `BUSDRIVER_STATE_DIR` traversal, nested-segment and bare-checkout-dir cases, the `BASH_FUNC_*` / `_JSON_PARSER*` injection case, and the corrupt / numeric / boolean value cases (~L95-145) are the only coverage of the `env -i` reader that pi_read, agy_read and writing_prose still use. Rewrite each to go through `resolve_pi_read_model` and read `$_BD_PI_READ_MODEL`, with `{"pi_read":{"model":"<value>"}}` fixtures in place of `{"auditor":{"model":…}}`. Rejected cases expect the empty string (pi_read's default). The injection case expects the configured value. Use a `provider/model` value that `resolve_pi_read_model` accepts; check its validator, which may differ from the auditor grammar.
  - Delete only what is specific to the withdrawn lane: the dispatch-shim probe (L68 `SHIM_DEFAULT=…`), the `resolve_auditor_model` default-constant and grammar cases that pi_read already covers, `_BD_AUDITOR_MODEL`, the opencode arm, the banner helper, and the `_oc_no_model` / skipped-status cases.
  - Keep every existing `pi_read` / `agy_read` case, retargeted to `_bd_read_lane_model`.
  - Add one case, using the file's existing fixture names (adapt the identifiers only if they differ):

```bash
# ADR 0051: a leftover .auditor.model is ignored — the 'auditor' key no longer selects anything.
printf '{"auditor":{"model":"x/y"}}' > "$FAKE_HOME/.claude/busdriver.json"
got="$(HOME="$FAKE_HOME" bash -c 'source "$0"; printf "%s" "$(_bd_read_lane_model "$HOME" "SENTINEL" auditor)"' "$LIB")"
if [[ "$got" == "SENTINEL" ]]; then
  ok "retired auditor key returns the default"
else
  fail "retired auditor key still read: '$got'"
fi
```

  (`ok` / `fail` are this file's existing reporters.)

- [ ] **`tests/test-pi-dispatch-arm.sh`:**
  - L37: delete the `OPENCODE_CONFIG` path pin.
  - L1249-1258: replace the `all`-list assertion with one expecting `for c in codex agy droid grok pi-read; do`, and drop the live-`opencode)`-arm assertion.
  - L1301-1303: invert to an absence check (`! grep -qE '^[[:space:]]*opencode\)' "$DISPATCH"`).
  - Delete L1400-1411 (`resolve_auditor_model` probes).
  - Keep L1398-1399 (`.auditor.model` does not leak into pi).
  - L1414: `_bd_read_auditor_model` → `_bd_read_lane_model`.
  - The suite must still find its own pi-arm slice and run to completion.
- [ ] **`tests/test-trusted-review-cli.sh`** (#803). Delete these three complete opencode-only blocks:
  1. The `BD803_OC_LIB_PIN` / `--execute-opencode-review` behavioural block, from the comment `# #803: BD803_OC_LIB_PIN is caller-supplied` (~L861) through the `bad "#803: in-checkout pin was not refused …"` line and its `fi` (~L888).
  2. The config-containment ordering check, from the comment `# #803: \`_trusted_cli_dir_in_checkout\` derives the reviewed root` (~L968) through its closing `fi` (~L984).
  3. The opencode trusted-PATH availability block, from `# #803: opencode availability must use the SAME fixed trusted PATH` (~L1060) through its closing `fi` (~L1097), including the `run_avail_oc` helper and the `OC_*` fixtures.

  Then make these edits:
  - The held-descriptor check around L956-965: change the grep pattern `[})] 3< "\$\(pin\|_ER_OC_CFG\)"` to `[})] 3< "\$pin"`, change both expected counts (descriptor and `/dev/fd/3` read) from **2 to 1**, and reword the ok/bad messages (`both trust-sensitive copies`, `expected 2`) to the single review-lib staging site. Reword the L924 comment `Two sites depend on this: the review-lib staging and the opencode config bind.` to `The review-lib staging depends on this.`
  - **Keep** the shared review-lib latch tests, the descriptor-copy probe, the entry-point enumeration (`entry_seen`, which counts executables, not opencode) and the non-opencode `BD803_REVIEW_LIB --review` refusals (~L1746+).
  - The commit body names all three deleted blocks. (The removed-CLI degradation cases live in `tests/test-review-boundaries.sh`, above.)
- [ ] **`tests/test-agy-read-lane.sh`:**
  - L290: the pinned `REPORT_NAME` alternation becomes `codex\|agy\|agy-read\|agy-prose\|droid\|grok\|pi-read\) ;;$`.
  - Comments: L50 `The pi/auditor grammar` → `The pi grammar`; L68 and L376 `test-auditor-model-config.sh` → `test-lane-model-config.sh`.
- [ ] **`tests/test-agy-prose-lane.sh`:**
  - L76: drop `\|opencode` from the same alternation.
  - L14 comment: `opencode and agy-read carry.` → `pi and agy-read carry.`
- [ ] **`tests/test-grok-sandbox-arm.sh`** L1354-1355 comment: `like opencode's missing .auditor.model` → `like pi-read's missing model`.
- [ ] **`tests/test-dispatch-skipped-status.sh`** L64 comment: drop `opencode` from the list of voices absent from `--cli all`.
- [ ] **`tests/test-lane-model-config.sh`** keeps its model-name leak sweep (`kimi|opencode-go|moonshotai|gemini…`) and drops only the `AUDITOR_MODEL_DEFAULT|resolve_auditor_model\(\)|"auditor": { "model"` alternatives from its exclusion `grep -vE`. Also delete the two `cwd_alloc_after_guard … _BD_AUDITOR_MODEL …` calls and the `cwd_alloc_after_guard()` helper with its comment (~L258-276), since both guarded sites are deleted.
- [ ] **Leave alone:** `tests/test-pre-pr-gate.sh` and `tests/test-pr-dual-voice.sh`. Their only `opencode` hit is the `.opencode` state-dir pin.

**Prose in the same commit:**
- [ ] `skills/dispatch-cli/SKILL.md`:
  - L41: `(up to 5; \`grok\` and \`pi-read\` are skipped in \`auto\` mode)`.
  - L118: `Same trust rules as the other lane model keys (USER config only, no env override)`.
- [ ] `skills/writing-prose/SKILL.md` L140: `is the same exemption \`pi\` and \`agy-read\` carry.`
- [ ] `README.md`:
  - L85: keep the `#251` sentence verbatim and delete the following sentence (`The opencode CLI survives only as the Auditor-role review backend …`).
  - Delete L100.
- [ ] `.claude/CLAUDE.md` L101: `unlike the pi/auditor keys` → `unlike the pi keys`.

**Completion criterion and run:**
- [ ] **Residue grep:**

```bash
git grep -nE 'opencode|auditor|_oc_|_ER_OC|OPENCODE_|Mechanism Witness' -- \
  scripts/lib/resolve-cli.sh skills/dispatch-cli/ README.md skills/writing-prose/SKILL.md .claude/CLAUDE.md \
  | grep -vE 'opencode-go|(^|[^A-Za-z])amp([^A-Za-z]|$)'
```

  Expected: no output except the README `#251` history sentence. The second `grep` is a convenience filter for this one-off check: `opencode-go` is the pi provider, and removed-CLI set lines always name `amp`. Read every line it drops (same command with `grep -E` in place of `grep -vE`). In resolve-cli.sh, each dropped line that names opencode must be one of the seven removed-set lines, verbatim. Any other line naming opencode, a comment included, is residue. The durable guard is Task 5, and it allows exactly those seven lines.
- [ ] **Test-source residue sweep** (the grep above excludes `tests/`):

```bash
git grep -lE 'opencode|auditor|_oc_|_ER_OC|OPENCODE_|Mechanism Witness|MECHANISM_WITNESS' -- tests/ scripts/ci/ | sort
```

  Expected: exactly these files, each for the stated reason only:
  - `tests/test-lane-model-config.sh`: the retired-`auditor`-key case and the `opencode-go` leak pattern.
  - `tests/test-review-boundaries.sh`: sections 7 and 8 (removed-CLI degradation: opencode fixtures, the auditor-route checks in 7(e)) and section 5's comment naming the old config file. Reword that comment to `a reviewed repo's own plugin asset would then pass the -f check`.
  - `tests/test-pi-dispatch-arm.sh`: the `opencode-go` provider fixtures (~L1351-1365), the kept `.auditor.model`-does-not-leak-into-pi case (~L1398-1399), and the inverted `opencode)`-arm absence check.
  - `tests/test-pre-pr-gate.sh`, `tests/test-pr-dual-voice.sh`: the `.opencode` state-dir pins.
  - `tests/test-ultimate-tier.sh`: the Task 3 absence check.

  Then check each listed file line by line (`git grep -nE … -- <file>`). Every hit must be one of the stated reasons. A hit outside the reasons, or any hit in an unlisted file, is residue: delete the line or the assertion it belongs to, or reword it if it is a comment. Never delete a whole block that also holds kept assertions.
- [ ] **Run:**

```bash
fail=0; for t in lane-model-config review-boundaries pi-dispatch-arm trusted-review-cli agy-read-lane agy-prose-lane grok-sandbox-arm dispatch-skipped-status pre-pr-gate pr-dual-voice reviewer-timeout cli-retry codex-retry-budget droid-escalation droid-escalation-outcome; do
  bash "tests/test-$t.sh" >"/tmp/t-$t.log" 2>&1 && echo "ok $t" || { echo "FAIL $t"; tail -20 "/tmp/t-$t.log"; fail=1; }
done
bash -n scripts/lib/resolve-cli.sh || fail=1
shellcheck scripts/lib/resolve-cli.sh skills/dispatch-cli/scripts/dispatch.sh || fail=1
exit $fail
```

  Expected: every line `ok`, exit 0. The droid suites are included to prove droid behaviour is untouched.
- [ ] **Commit:** `refactor(dispatch): remove the opencode CLI lane; opencode joins the removed-CLI set (ADR 0051)`. The body lists each test assertion deleted or changed.

### Task 5: Invariant guard

**Files:**
- Create: `tests/test-no-auditor-lane.sh`
- Modify: `scripts/ci/shell-test-durations.tsv` (add a `test-no-auditor-lane	1` row at its sorted position)

**Interfaces:** Consumes Tasks 1-4. Produces a suite that fails if the lane is re-added, e.g. by an upstream sync.

- [ ] **Create the test:** the authoritative content is the shipped `tests/test-no-auditor-lane.sh`, not a copy here. The draft that used to sit in this step was weaker than what shipped: it honoured `ALLOW_LINES` in every LIVE file and let a failed `grep` read as a clean scan. The shipped file honours `ALLOW_LINES` only in `scripts/lib/resolve-cli.sh`, reports a `grep` error as a hit, refuses an unreadable or empty body, and self-tests each of those. Re-implementing from the old draft would reintroduce both holes.

  The test's seven `ALLOW_LINES` are exactly the removed-set lines Task 4 leaves in resolve-cli.sh, verbatim. If Task 4's edits produce a different spelling, the guard fails, so fix the code to match those lines, not the reverse. Do not reword a comment to dodge the guard; rewording comments not to name opencode is what Task 4 asks for anyway. An implementer who finds a genuinely necessary new mention may add one exact line or substring and must justify it in the commit body. Never add a bare word, a regex, or a "contains" match.
- [ ] **Prove the guard fires on a real file, then lint:**

```bash
chmod +x tests/test-no-auditor-lane.sh
bash tests/test-no-auditor-lane.sh                                   # expect: all self-tests PASS, PASS test-no-auditor-lane
printf '\n  opencode)\n' >> skills/dispatch-cli/SKILL.md
bash tests/test-no-auditor-lane.sh; echo "rc=$?"                    # expect: FAIL … dispatch-cli/SKILL.md, rc=1
git checkout -- skills/dispatch-cli/SKILL.md
bash tests/test-no-auditor-lane.sh                                   # expect: PASS test-no-auditor-lane
shellcheck tests/test-no-auditor-lane.sh                             # expect: exit 0
```

  The malformed-config and whole-line-bypass cases are covered by the in-file self-tests, so they need no mutation of a tracked file.

- [ ] **Commit:** `test: guard against re-adding the withdrawn auditor/opencode lane (ADR 0051)`

### Task 6: Plan records, full verification, issue hygiene

**Files:**
- Modify: `docs/plans/2026-08-23-pi-replacement.md` (status block only)
- Modify: `docs/plans/2026-08-27-pipeline-final-plan.md` (one note under the ROADMAP banner)

- [ ] **08-23 umbrella:** directly under its `> **Status: UMBRELLA…` paragraph, add:

```markdown
> **2026-10-05 — ADR 0051:** the `pi-auditor` role is withdrawn, not migrated. The auditor
> and the opencode CLI were deleted outright, which completes §1a's CLI half. ADR 0051
> covers the opencode **CLI only**. It does not touch the `opencode-go` *provider* half of
> "OpenCode eliminated", or Decision B (pi accepts `cursor/*` only). Both are pi-provider
> policy and are reopened by a separate ADR, not by this note. Slices that assumed
> `pi-auditor` must be re-specified before any work.
```

- [ ] **0827 roadmap:** directly under the `> **ROADMAP (Chris, 2026-09-26)…` banner, add:

```markdown
> **2026-10-05 — ADR 0051:** the auditor / Mechanism Witness and the opencode CLI are gone.
> Every reference below to `opencode`, `blueprint-review.auditor`, `council.auditor` or
> `.auditor.model` is historical. Item 1's "opencode `council.auditor` fail-close" note is moot.
```

- [ ] **Full verification:**

```bash
npm run validate
shellcheck hooks/gate-scripts/*.sh scripts/hooks/*.sh
./scripts/gate-integrity.sh --check
bash tests/test-no-auditor-lane.sh
bash scripts/ci/run-shell-tests.sh
```

  Expected: every command exits 0. `run-shell-tests.sh` is the CI runner, with per-test timeouts and skip classification. If a suite this plan never touched fails, compare against `origin/main` before attributing it to this change.
- [ ] **Commit:** `docs(plans): record ADR 0051 in the pi-replacement and 0827 roadmaps`
- [ ] **After the PR merges (operator-visible, not part of the diff):**
  - Close #662 and #817, commenting `Obsolete — the Mechanism Witness/opencode lane was withdrawn in ADR 0051 (PR #N).`
  - Comment on #547 and #570 that only their non-witness halves remain.
  - Remove the `.auditor` block from `~/.claude/busdriver.json` on the Mac and on um. It is inert (Task 4's test proves it), so this is tidiness.
  - Uninstall the opencode CLI later, with the omp/balancer machine cleanup.

---

## Pre-mortem

1. **A suite hard-exits or raises instead of failing.** Examples: `test-pi-dispatch-arm.sh` awk-slices arms; `test-marker-glob-specificity.sh` indexes `[0]` in a Python fence; `test-lane-model-config.sh` runs under `set -euo pipefail`. Mitigation:
   - every pinning suite is edited in the commit that removes its anchor (Tasks 3 and 4);
   - each task's run loop exits non-zero on any failure;
   - Task 6 runs the CI runner.
2. **A range deletion leaves broken syntax** (the `_portable_timeout` perl `if/else`). Mitigation: whole-branch rule, `bash -n`, and ShellCheck in Task 4's run.
3. **A stale operator `opencode` route newly crashes a review.** Mitigation: `opencode` joins the removed-CLI set, and Task 4 adds a test that `["opencode","droid"]` resolves past opencode.
4. **Accepted intermediate windows (one commit each, no runtime harm):**
   - After Task 1, Step 4b still defaults auditor roles to opencode until Task 4 deletes that arm. Only the loop and council resolve those roles, and Tasks 2-3 delete those callers.
   - After Task 2, the council witness reap loses `tests/test-auditor-grace-budget.sh` until Task 3 deletes the reap itself.

   Neither window is reachable on `main`, because the PR lands as a whole.
5. **A shared helper disappears with the opencode code** (the reader, `_bd_rm_sandbox_home`). Mitigation: grep for callers before each deletion; the reader is renamed, not deleted, and is covered by `test-lane-model-config.sh`.

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
