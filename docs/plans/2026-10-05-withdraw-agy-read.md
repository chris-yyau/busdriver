# Withdraw the agy-read lane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use busdriver:subagent-driven-development (recommended) or busdriver:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove `--cli agy-read` from busdriver. ADR 0052 deprecated it, and this is the follow-up PR that ADR names. No coverage of the shared agy dispatch arm may be lost.

**Architecture:** `agy-read` is a desugar block in `dispatch.sh` that rewrites `CLI=agy` and sets `_AGY_READ_LANE=1`, plus a model reader for `.agy_read.model` in `resolve-cli.sh`. Most of what its test file pins belongs to the *shared* agy arm, not to this lane. That shared arm is still used by plain `--cli agy` (the reviewer slots) and by `--cli agy-prose` (kept). So the lane code is deleted, and the shared-arm coverage moves to a renamed test that drives the same assertions through `agy-prose`. The bare-id grammar tables move to `.writing_prose.model`, which uses the same `bare` grammar.

**Tech Stack:** bash (dispatcher, library, shell tests), Markdown (skills, ADRs).

**Global Constraints:**
- This change only removes code. It adds no new lane, flag, config key or dependency.
- Plain `--cli agy` and `--cli agy-prose` must behave byte-for-byte as before. Their argv still differs only by `--mode plan`, plus any `--model` the prose lane receives, either explicitly or through `.writing_prose.model`.
- **Two commits, each green on its own.**
  - Commit 1 holds the code, the tests and `skills/dispatch-cli/SKILL.md`. That doc must ride with the tests: the lane-model sweep scans it, and its `.agy_read` model example is only allowed while the allowance being deleted exists.
  - Commit 2 holds the remaining docs.
  - Each commit stages an explicit file list, never a directory.
- The fail-CLOSED posture stays as it is:
  - the droid exemption for `agy-prose`
  - the `REPORT_NAME` whitelist
  - the trusted-`$HOME` pin
  - the refusal of a model-pinned dispatch on agy 1.0.x or after an inconclusive version probe
- ADRs, `CHANGELOG.md` and `docs/plans/*` other than this file are historical records and are **not** rewritten. ADRs 0040 and 0052 only get an amendment line.
- No model id may appear in a swept live file (`tests/test-lane-model-config.sh`). Test fixtures use neutral ids such as `probe-model-a`.
- Edits to `hooks/gate-scripts/**` or `scripts/hooks/**` would need `./scripts/gate-integrity.sh --update`. This plan touches neither directory.
- ShellCheck must stay clean on every edited `.sh` file.

**Ultra-oracle plan advisory:** attempted, but failed with status `error` (a Cloudflare challenge in the attached browser). Drafted without it, as the writing-plans skill allows.

---

## File Structure

| File | Change | Responsibility after the change |
|---|---|---|
| `skills/dispatch-cli/scripts/dispatch.sh` | modify | The agy arm serves plain `agy` and the `agy-prose` lane only |
| `scripts/lib/resolve-cli.sh` | modify | Lane model reader with the keys `pi_read*`, `pi_legacy_raw`, `writing_prose*` |
| `tests/test-agy-read-lane.sh` → `tests/test-agy-dispatch-arm.sh` | `git mv` + modify | Shared agy-arm contract (workspace argv, plan-mode gating, report identity, version-probe refusal, `$HOME` pin), the bare-grammar tables, and a withdrawal check |
| `tests/test-agy-prose-lane.sh` | modify | The greps follow the new gate and whitelist shapes |
| `tests/test-lane-model-config.sh` | modify | The staleness sweep: no `*_MODEL_DEFAULT` allowance, and the renamed sweep target |
| `tests/test-trusted-review-cli.sh` | modify (one comment) | Names the renamed test |
| `scripts/ci/shell-test-durations.tsv` | modify | Renamed row |
| `skills/dispatch-cli/SKILL.md` | modify | The agy-read section is removed. The shared `--add-dir` / `--mode plan` mechanics move under an agy heading |
| `skills/writing-prose/SKILL.md` | modify | No comparisons to agy-read |
| `README.md`, `.claude/CLAUDE.md` | modify | agy-read is no longer mentioned as a live lane |
| `docs/adr/0040-agy-read-lane-default.md`, `docs/adr/0052-pi-read-on-antigravity.md` | modify (one amendment line each) | Records the withdrawal |

---

### Task 1: Remove the lane from the dispatcher and library

**Files:**
- Modify: `skills/dispatch-cli/scripts/dispatch.sh`
- Modify: `scripts/lib/resolve-cli.sh`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `--cli agy-read` is rejected by the `--cli` validator.
  - `_AGY_READ_LANE`, `_BD_AGY_READ_MODEL`, `resolve_agy_read_model` and `BUSDRIVER_AGY_READ_MODEL_DEFAULT` no longer exist.
  - The plan-mode gate is exactly `if [[ -n "$_AGY_PROSE_LANE" ]]; then`.
  - The whitelist arm is exactly `codex|agy|agy-prose|droid|grok|pi-read) ;;`.

- [ ] **Step 1: In `dispatch.sh`, remove the library-missing stubs for the read lane.** Delete the 4-line comment beginning `# Deliberately NOT a duplicated default. Empty here is a REFUSAL`, and the two lines `_BD_AGY_READ_MODEL=""` and `resolve_agy_read_model() { _BD_AGY_READ_MODEL=""; }`. Then replace the whole 4-line prose-stub comment above `_BD_WRITING_PROSE_MODEL=""`, which currently runs from `# Empty is the NORMAL value` to `# default rather than aborting.`, with:

```bash
  # Empty is the NORMAL value for the prose lane, not a refusal signal: it
  # means "pass no --model", i.e. agy's own configured model. So a missing
  # library degrades this lane to exactly its documented default rather than
  # aborting.
```

- [ ] **Step 2: Remove the `_AGY_READ_LANE` declaration.** Delete the comment block starting `# Set only by the \`agy-read\` desugar below. Carries the LANE IDENTITY`, through `_AGY_READ_LANE=""`. Then rewrite the `_AGY_PROSE_LANE` comment so it stands alone:

```bash
# Set only by the `agy-prose` desugar below. Carries the LANE IDENTITY the
# desugar would otherwise erase (it rewrites CLI to plain "agy"). Two readers:
# it adds `--mode plan` to agy's argv, and it exempts the lane from the
# runtime droid escalation. ONE flag for both on purpose — they are the same
# fact ("this dispatch is the prose lane"), and a second variable would let a
# change to one silently stop protecting the other.
_AGY_PROSE_LANE=""
```

- [ ] **Step 3: Update the usage text and the `--cli` validator.**
  - In the `USAGE` heredoc, the `--cli` line becomes `--cli     codex|agy|agy-prose|droid|grok|pi-read|both|all|auto  (default: auto)`.
  - Delete the whole `NOTE: \`agy-read\` is the repo-READING lane.` paragraph, through its last line `does NOT block writes) — a mode, not a kernel sandbox, so not write-PROOF.`.
  - In the validator, drop the `&& "$CLI" != "agy-read"` term, and make the error message `Must be codex|agy|agy-prose|droid|grok|pi-read|both|all|auto.`.

- [ ] **Step 4: Make the `agy-prose` desugar comments self-contained.** Each of these comments currently points at the read lane:
  - The header: `Desugars to the ordinary agy arm, mirroring \`agy-read\` below, with the same three pins and for the same reasons:` → `Desugars to the ordinary agy arm with three things pinned, so there is ONE agy implementation to maintain rather than two that drift:`.
  - `exactly like \`pi\`\n# and \`agy-read\`.` → `exactly like \`pi\`.`
  - `# Both apply equally to \`agy-read\`, \`pi\` and the reviewer slots.` → `# Both apply equally to \`pi\` and the reviewer slots.`
  - `# same rationale as agy-read: the lanes differ` → `# because the agy lanes differ`.
  - `# requirement to the agy READ lane below, for identical reasons.` → `# requirement to every lane that ships content to a configured provider.` Also carry over the read lane's Codex P1 sentence, so the reason survives the deletion: `With an inherited $HOME the agy child reads its config, auth and tool settings from a repo-selected directory (Codex P1 on PR #687).`
  - `# shellcheck disable=SC2310  # same \`! fn\` condition shape as the agy-read\n    # derivation below; the else-branch IS the failure handler.` → `# shellcheck disable=SC2310  # \`! fn\` condition shape; the else-branch IS\n    # the failure handler.`

- [ ] **Step 5: Delete the `agy-read` desugar.** Remove everything from `# ── \`agy-read\` — the agy READ lane ───` through the `fi` that closes `if [[ "$CLI" == "agy-read" ]]; then`. The next surviving line must be `# Validate mode`.

- [ ] **Step 6: Gate plan mode on the prose lane only.** In the agy arm:

```bash
            # `--add-dir "$PWD"` selects the CWD as agy's workspace on EVERY agy
            # dispatch — the prose lane and the plain `--cli agy` reviewer slots
            # alike (#686). `--mode plan` is the prose lane's write boundary ONLY:
            # it must never reach a reviewer, which stops producing findings
            # under plan mode.
            local _agy_lane=(--add-dir "$PWD")
            if [[ -n "$_AGY_PROSE_LANE" ]]; then
                _agy_lane+=(--mode plan)
            fi
```

In the model-flag refusal comment, replace `defeating .agy_read.model's whole\n                # purpose without saying so — and on the read lane that means\n                # quietly asking a DIFFERENT model than the operator configured.` with `quietly asking a DIFFERENT model than the operator configured.`

- [ ] **Step 7: Clean up the droid-escalation guard.** Delete the comment paragraph `# The agy READ lane is exempt for pi's reason, ...` through `# Plain \`--cli agy\` (the reviewer slot) is unaffected and still escalates.`, and the line `       && [[ -z "$_AGY_READ_LANE" ]] \`. Insert this in place of the paragraph, so the `_AGY_PROSE_LANE` clause keeps its rationale:

```bash
    # The agy PROSE lane is exempt for pi's reason, and needs its own clause
    # because its desugar rewrote CLI to plain "agy" — `$name` is "agy" here, so
    # the pi-read check above does not cover it. Escalating a failed prose
    # dispatch to droid would ship the brief, and anything quoted into it, to a
    # DIFFERENT third party than the operator chose. Plain `--cli agy` (the
    # reviewer slot) is unaffected and still escalates.
```

- [ ] **Step 8: Update the report identity.** In the `else` branch, change the comment `the requested lane name (e.g. "agy-read") when the\n    # agy-read desugar set it` to `the requested lane name (e.g. "agy-prose") when the\n    # agy-prose desugar set it`. The whitelist arm becomes `        codex|agy|agy-prose|droid|grok|pi-read) ;;`.

- [ ] **Step 9: Update `resolve-cli.sh`.**
  - Header comment: `# ── Lane model keys (pi_read / writing_prose) ────────`.
  - Delete the enum line `  agy_read) jqf='.agy_read.model | ...` from `_bd_read_lane_model`.
  - Delete the block from `# ── agy READ-lane model ───` through the closing `}` of `resolve_agy_read_model`.
  - Rewrite the writing-prose comments that compare to agy_read:

```bash
# ── writing-prose lane model ────────────────────────────────────
# Scoped to `--cli agy-prose` ONLY. Plain `--cli agy` (blueprint-review
# reviewer_1 and friends) is unaffected and keeps agy's own configured model.
#
# Same trust rules as `.pi_read.model` (USER config only, no env override, no
# project config, password-DB-derived $HOME): the value names the third party
# your prose — and anything quoted into the brief — is shipped to.
# `agy models` enumerates ids; the value is BARE (no `provider/` segment).
#
# There is no shipped default, and empty is NOT a refusal: it means "pass no
# --model", i.e. agy's own configured model, which is the behaviour this lane
# was validated on.
```

  - At the comment near line 4189 (`the same derivation the agy-read and`), drop `agy-read`. Keep the rest of the sentence grammatical.

- [ ] **Step 10: Verify that no live reference survives.**

Run: `grep -nE 'agy[-_]read|AGY_READ' skills/dispatch-cli/scripts/dispatch.sh scripts/lib/resolve-cli.sh`
Expected: no output.

Run: `shellcheck skills/dispatch-cli/scripts/dispatch.sh scripts/lib/resolve-cli.sh`
Expected: exit 0.

### Task 2: Move the shared agy-arm coverage into `tests/test-agy-dispatch-arm.sh`

**Files:**
- Rename: `tests/test-agy-read-lane.sh` → `tests/test-agy-dispatch-arm.sh`, then edit it
- Modify: `tests/test-agy-prose-lane.sh`, `tests/test-lane-model-config.sh`, `tests/test-trusted-review-cli.sh`, `scripts/ci/shell-test-durations.tsv`

**Interfaces:**
- Consumes: the shapes Task 1 produces (gate line, whitelist arm, rejection of `--cli agy-read`).
- Produces: the test `tests/test-agy-dispatch-arm.sh` (`PASS: test-agy-dispatch-arm`).

- [ ] **Step 1: Rename the file.** Run `git mv tests/test-agy-read-lane.sh tests/test-agy-dispatch-arm.sh`. Header comment:

```bash
# test-agy-dispatch-arm.sh — the SHARED agy dispatch arm (plain `--cli agy`
# reviewer slots + the `agy-prose` lane), and the `bare` model-id grammar.
#
# No real agy binary is invoked: every behavioural case stubs agy on PATH, and
# every dispatch either refuses before agy or reaches the stub. Offline + CI-safe.
#
# The invariants that matter:
#   (a) plain `--cli agy` (blueprint-review reviewer_1, council.pragmatist) never
#       picks up a lane's model or `--mode plan`; and
#   (b) every agy dispatch scopes to the CWD via `--add-dir "$PWD"` (#686).
# Coverage moved here from test-agy-read-lane.sh when the agy-read lane was
# withdrawn (ADR 0052 follow-up); lane-specific cases now drive `agy-prose`.
```

Also drop the duplicated two-line `# Literal grep patterns ...` comment. Keep the `# shellcheck disable=SC2016,SC2312` line.

- [ ] **Step 2: Add a private TMPDIR fixture before the first `agy-prose` dispatch.** `agy-prose` refuses a group- or world-writable `$TMPDIR`, and CI's `/tmp` is mode 1777. Without the fixture, every behavioural lane case would stop at that refusal and never reach the agy stub. Use one fixture everywhere:

```bash
# agy-prose refuses a group/world-writable $TMPDIR (CI's /tmp is 1777), so every
# lane dispatch below runs with a private mode-700 temp dir OUTSIDE any checkout.
prose_tmp="$(mktemp -d /tmp/agy-arm-prose.XXXXXX)" || { echo "FAIL — mktemp -d failed for prose_tmp"; exit 1; }
chmod 700 "$prose_tmp"
```

The fixture is anchored at `/tmp` on purpose. A bare `mktemp -d` inherits the ambient `$TMPDIR`, and if that points inside the checkout, `agy-prose` refuses every case.

The file has **two** EXIT traps: line 52 (`rm -rf "$tmp_home"`) and line 171. The second replaces the first, so `"${prose_tmp:-}"` goes into the **line-171** trap's `rm -rf` list, the one that already names `ags_stub`, `er_cwd` and the others.

- [ ] **Step 3: Replace sections 1 and 2 with a withdrawal check.**

```bash
# ── 1. agy-read is withdrawn, not silently remapped ─────────────
# A stale caller must get a loud refusal — never a dispatch on plain agy, which
# would run with the reviewer's model and no plan mode.
wd_stub="$(mktemp -d)" || { echo "FAIL — mktemp -d failed for wd_stub"; exit 1; }
printf '#!/bin/sh\nprintf "AGY_WAS_INVOKED\\n"\n' > "$wd_stub/agy"; chmod +x "$wd_stub/agy"
out="$(PATH="$wd_stub:$PATH" "$DISPATCH" --cli agy-read --prompt x 2>&1)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"Invalid --cli value 'agy-read'"* && "$out" != *"AGY_WAS_INVOKED"* \
      && "$out" != *"|agy-read|"* ]]; then
  pass "--cli agy-read is rejected (withdrawn), agy is never invoked, enum no longer lists it"
else
  fail "--cli agy-read must be rejected without invoking agy (rc=$rc): $out"
fi
rm -rf "$wd_stub"
```

- [ ] **Step 4: Point sections 3, 8 (grammar) and 9 at `resolve_writing_prose_model`.** Rejected values must now resolve to **empty**, because the prose lane has no default. `check_model` becomes:

```bash
check_model() {  # <json-value> <expected> <label>
  printf '{"writing_prose":{"model":%s}}\n' "$1" > "$tmp_home/.claude/busdriver.json"
  local got
  got="$(
    # shellcheck disable=SC1090
    source "$RESOLVE" >/dev/null 2>&1
    HOME="$tmp_home" resolve_writing_prose_model 2>/dev/null
    printf '%s' "$_BD_WRITING_PROSE_MODEL"
  )"
  if [[ "$got" == "$2" ]]; then pass "$3"; else fail "$3 (got '$got', want '$2')"; fi
}
```

Further changes to these sections:
  - Delete the `agy_default_line` / `agy_default` derivation and its guard.
  - Replace every `"$agy_default"` expected value with `''`.
  - Drop the `if [[ -z "$agy_default" ]]` / `if [[ -n "$agy_default" ]]` wrappers around the tables.
  - Section 3's two accept cases use neutral ids: `check_model '"probe-model-a"' 'probe-model-a' 'bare id is accepted verbatim'` and `check_model '"probe-model-b"' 'probe-model-b' 'a different bare id is honoured (config actually drives the lane)'`.
  - Every reject label says "is rejected by the grammar (validated model resolves empty)". It does **not** say "no --model": for a non-empty invalid string, dispatch then refuses through the `writing_prose_raw` presence probe, which `test-agy-prose-lane.sh` §5 pins.
  - Section 4 keeps its body, and its closing comment becomes `# the grammar did not leak: writing_prose accepts bare ids, pi-read must not.`.

- [ ] **Step 5: Update sections 5/6 to the prose gate.**

```bash
scope_gate="$(grep -cE '^[[:space:]]+if \[\[ -n "\$_AGY_PROSE_LANE" \]\]; then$' "$DISPATCH")"
```

Further changes here:
  - The pass label becomes `"--add-dir unconditional; --mode plan gated on _AGY_PROSE_LANE"`.
  - Replace the `_AGY_READ_LANE defaults empty` check with the same check on `^_AGY_PROSE_LANE=""$`.
  - Delete the comment `# Both agy lanes (agy-read, agy-prose) share the plan-mode pin.` and its three following lines. Replace them with `# Plan mode is LANE-GATED, never unconditional — a reviewer silently switched into plan mode stops producing findings.`

- [ ] **Step 6: Change section 5b's lane case to `agy-prose`.**

```bash
# The prose lane keeps BOTH: --add-dir (the workspace) plus --mode plan (its
# write boundary).
# An explicit neutral --model keeps this case independent of the operator's real
# .writing_prose.model, which agy-prose reads from the password-DB home and
# refuses before agy when it is invalid.
out="$(cd "$ags_cwd" && TMPDIR="$prose_tmp" PATH="$ags_stub:$PATH" "$DISPATCH" --cli agy-prose --model probe-model-a --prompt x 2>&1)"
if [[ "$out" == *"AGY_ARGV:"* && "$out" == *"--add-dir $ags_cwd"* && "$out" == *"--mode plan"* ]]; then
  pass "agy-prose keeps --add-dir + --mode plan"
else
  fail "agy-prose must pass --add-dir and --mode plan (out: $out)"
fi
```

Section 5c stays unchanged.

- [ ] **Step 7: Delete section 7.** It is the structural `_AGY_READ_LANE` droid-exemption grep. `test-agy-prose-lane.sh` §2 already pins the `_AGY_PROSE_LANE` clause.

- [ ] **Step 8: Re-anchor section 8 (audit order) on the prose capture.** Change `l_capture="$(line_of '^[[:space:]]+REPORT_CLI_NAME="agy-prose"$')"` and `l_whitelist="$(line_of '^[[:space:]]+codex\|agy\|agy-prose\|droid\|grok\|pi-read\) ;;$')"`. Change "agy-read capture" to "agy-prose capture" in the pass label and the comments. That includes the comment line `# agy-read desugar capture → REPORT_NAME assignment → ...`, currently line 283.

- [ ] **Step 9: Move sections 10, 10b and 11 to `agy-prose`.** Prefix every lane dispatch with `TMPDIR="$prose_tmp"`, and change `--cli agy-read` to `--cli agy-prose`. The three plain `--cli agy` cases stay as they are, without a TMPDIR prefix. Fix the labels as well:
  - "agy-read on a 1.0.x agy install refuses loudly ..." → "agy-prose on a 1.0.x agy install refuses loudly ..."
  - "agy-read pins the password-DB \$HOME on the agy process" → "agy-prose pins the password-DB \$HOME on the agy process"
  - In the comments, change "the read lane" to "the prose lane", and `.agy_read.model` to `.writing_prose.model`.
  - Rewrite section 10's comment block, currently lines 360-367, which describes agy-read. It names `resolve_agy_read_model`, and that function will no longer exist:

```bash
# ── 10. agy 1.0.x + a model-pinned lane refuses rather than dropping --model ───
# (PR #687 Codex finding.) agy 1.0.x does not support --model, so a lane
# dispatch carrying one would reach the /dev/stdin transport with an unsupported
# flag on every attempt. End-to-end: stub `agy --version` as 1.0.0 on PATH and
# pass --model explicitly (the lane's own model resolution reads the real
# password-DB home and cannot be redirected, so an explicit --model is the only
# way to exercise the guard without touching the operator's real config).
```

  - Section 11 `resolved-model` case. It dispatches with no `--model`, so `agy-prose` resolves `.writing_prose.model` from the operator's real password-DB home, and it refuses before agy if that value is invalid. Handle that explicitly, so the suite stays green and still says what happened. Add this arm **before** the "stub agy was never invoked" `fail`:

```bash
  if [[ "$agyh_case" == resolved-model && "$out" == *".writing_prose.model is set to"* ]]; then
    pass "$agyh_case: host's .writing_prose.model is invalid, lane refused before agy (\$HOME pin still proven by explicit-model)"
  elif [[ "$out" != *"AGY_SAW_HOME="* ]]; then
```

The `$HOME` export runs before model resolution (`dispatch.sh` ~line 653), so the `explicit-model` case alone proves the pin. The `resolved-model` case adds coverage only where the host's config allows it.

- [ ] **Step 10: Update the final lines.** They become `PASS: test-agy-dispatch-arm` / `FAIL: test-agy-dispatch-arm`.

- [ ] **Step 11: Update `tests/test-agy-prose-lane.sh`.**
  - Line 14: `agy-read carry.` → `pi carries.`, and the preceding words `Same exemption pi and` → `Same exemption`.
  - Line 70 regex: `'^[[:space:]]+if \[\[ -n "\$_AGY_PROSE_LANE" \]\]; then$'`.
  - Line 76 regex: `'^[[:space:]]+codex\|agy\|agy-prose\|droid\|grok\|pi-read\) ;;$'`.
  - Line 89 comment: `# pi refuses on empty; this lane must NOT — empty means`.
  - Line 93 label: `(deliberate divergence from pi)`.
  - Line 147 comment: `# not the refusal pi treats it as.`

- [ ] **Step 12: Update `tests/test-lane-model-config.sh`.**
  - Delete `agy_read_default=...`, `esc_regex()`, `model_value_allow=...`, and the three comment lines above `agy_read_default` that explain the missing pi-read alternative.
  - Delete the sed `-e "s/${model_value_allow}//g"` and the `-e 's/^([^:]+:[0-9]+:)BUSDRIVER_AGY_READ_MODEL_DEFAULT=...'` expression. Keep `-e "s/check_model '[^']*' '[^']*'//g"`.
  - In `sweep=(...)`, replace `"$ROOT/tests/test-agy-read-lane.sh"` with `"$ROOT/tests/test-agy-dispatch-arm.sh"`.
  - Rewrite the rationale comment above the sweep to the current state:

```bash
# ── No model name in live files ─────────────────────────────────
# A voice is defined by its role, not by whichever model happens to be behind
# it. Prose that names the model goes stale the moment the configured model
# changes (a "(kimi-k3)" log line once lied about what ran). Every configurable
# model key (`.pi_read.model`, `.writing_prose.model`) ships with NO default
# constant, so no live file may name a model id at all; a test FIXTURE passed to
# `check_model` is the one allowance. docs/adr + CHANGELOG are historical
# records and are not swept. Scoped to the files that host the review voices.
```

- [ ] **Step 13: Update the one-line references.** In `tests/test-trusted-review-cli.sh:951`, change `tests/test-agy-read-lane.sh` to `tests/test-agy-dispatch-arm.sh (formerly test-agy-read-lane.sh)`. In `scripts/ci/shell-test-durations.tsv`, rename the row `test-agy-read-lane\t12` to `test-agy-dispatch-arm\t12`. Keep the file's existing ordering: if the rows are sorted, move the row to its sorted position.

- [ ] **Step 13a: Update `skills/dispatch-cli/SKILL.md` in this commit.** The lane-model sweep scans this file. Its `{ "agy_read": { "model": ... } }` example (currently line 62) only passed through the `model_value_allow` allowance that Step 12 deletes, so the doc has to change in the same commit, or Step 14 fails.
  - Delete the CLI Selection row `| Repo tracing (deprecated) | \`agy-read\` | ... |`.
  - Replace the whole `### \`agy-read\` — deprecated in-tree read lane` section, up to the next `### \`pi-read\`` heading, with the section below. It keeps the measured mechanics and drops the lane:

```markdown
### agy dispatch mechanics (plain `agy` and `agy-prose`)

> `agy-read` was withdrawn (ADR 0052 follow-up); `pi-read` is the read lane.
> These mechanics are the shared agy arm's and still apply to the reviewer
> slots and to `agy-prose`. `tests/test-agy-dispatch-arm.sh` pins them.
```

  Keep the existing `**Two mechanics are load-bearing**` table verbatim, with one change in the `--mode plan` row: "Lane-only on the older argv" → "Prose-lane-only on the older argv". Keep the `**⚠️ Reads are not confined.**` paragraph verbatim. Delete the `--mode auto` refusal and `**Calibrate the write claim.**` paragraphs, since `writing-prose/SKILL.md` already carries the prose lane's equivalents.
  - In the pi-read section: `same as agy-read.` → `same as agy.`
  - In the routing row (currently line 437): `**\`pi-read\` first** (ADR 0052; \`agy-read\` is deprecated)` → `**\`pi-read\` first** (ADR 0052)`.
  - The `--cli` row of the flags table: `` | `--cli` | `codex`, `agy`, `agy-prose`, `droid`, `grok`, `pi-read`, `both`, `all`, `auto` | `auto` | ``
  - Current line 448: `agy-read's\nown token cost is not separately measured (see below)` → `agy-read's\n(withdrawn) token cost was never separately measured`.
  - Lines 453 and 456 are past-tense history (the 2026-08-17 anecdote and the 10-15s comparison). Leave them as they are.

- [ ] **Step 14: Run the affected tests.**

Run: `bash tests/test-agy-dispatch-arm.sh && bash tests/test-agy-prose-lane.sh && bash tests/test-lane-model-config.sh && bash tests/test-trusted-review-cli.sh`
Expected: each prints its PASS line and exits 0.

Run: `shellcheck tests/test-agy-dispatch-arm.sh tests/test-agy-prose-lane.sh tests/test-lane-model-config.sh`
Expected: exit 0.

Run the mutation check, which proves the moved gate assertion can still fail. The mutation is applied to a throwaway copy of the worktree, so the real `dispatch.sh` is never edited and nothing needs restoring:

```bash
mut="$(mktemp -d)" && trap 'rm -rf "$mut"' EXIT
git archive --format=tar HEAD | tar -x -C "$mut"          # tracked files at HEAD…
git diff HEAD | (cd "$mut" && git apply --allow-empty)    # …plus the uncommitted change
sed -i.x 's/if \[\[ -n "\$_AGY_PROSE_LANE" \]\]; then/if true; then/' "$mut/skills/dispatch-cli/scripts/dispatch.sh"
bash "$mut/tests/test-agy-dispatch-arm.sh" | grep -c '^FAIL'   # expect >= 1
```

Expected: at least one FAIL in the copy. The real tree is untouched (`git diff --stat` is unchanged).

- [ ] **Step 15: Commit Tasks 1 and 2 together.** The tests pin the code shape, so neither half is green alone. Stage an explicit list, never `tests/`:

```bash
git add skills/dispatch-cli/scripts/dispatch.sh scripts/lib/resolve-cli.sh \
  tests/test-agy-dispatch-arm.sh tests/test-agy-prose-lane.sh \
  tests/test-lane-model-config.sh tests/test-trusted-review-cli.sh \
  scripts/ci/shell-test-durations.tsv skills/dispatch-cli/SKILL.md
# 8 paths; the old test path is omitted because `git mv` already staged its
# removal (naming it here would fail the pathspec). That is
# within litmus's >8 staged-file split threshold. This plan doc goes in commit 2.
git commit -m "refactor(dispatch): withdraw the agy-read lane (ADR 0052 follow-up)"
```

### Task 3: Documentation

**Files:**
- Modify: `skills/writing-prose/SKILL.md`, `README.md`, `.claude/CLAUDE.md`, `docs/adr/0040-agy-read-lane-default.md`, `docs/adr/0052-pi-read-on-antigravity.md`

**Interfaces:**
- Consumes: Task 2's test filename (`tests/test-agy-dispatch-arm.sh`).
- Produces: none.

- [ ] **Step 1: (done in Task 2 Step 13a.)** `skills/dispatch-cli/SKILL.md` is edited in commit 1, because the lane-model sweep scans it.

- [ ] **Step 2: Update `skills/writing-prose/SKILL.md`.**
  - Line 111: `from \`pi\` and \`agy_read\`, which` → `from \`pi\`, which`. Adjust the following line so the sentence stays grammatical.
  - Line 122: `` `agy-prose` is a first-class dispatch lane, mirroring `agy-read`: `` → `` `agy-prose` is a first-class dispatch lane: ``
  - Line 140: `is the same exemption \`pi\` and \`agy-read\` carry.` → `is the same exemption \`pi\` carries.`

- [ ] **Step 3: Update `README.md`, `.claude/CLAUDE.md` and the ADRs.**
  - In the README agy row: `` Blueprint review, council, code review, `agy-prose`, deprecated `agy-read` lane `` → `` Blueprint review, council, code review, `agy-prose` ``.
  - In CLAUDE.md line 101, change the sentence `` `agy-read` is deprecated (withdrawn in a follow-up, ADR 0052); `` to `` `agy-read` was withdrawn (ADR 0052 follow-up); ``. Leave the rest of the line as it is.
  - ADR 0040: under the status line, add `**Withdrawn (2026-10-05):** the agy-read lane was removed in the ADR 0052 follow-up PR; this ADR is historical.`
  - ADR 0052: after the `**Amends:**` list, add `**Amended (2026-10-05):** decision 4's follow-up landed — \`--cli agy-read\` is withdrawn; its shared agy-arm coverage moved to \`tests/test-agy-dispatch-arm.sh\`.`

- [ ] **Step 4: Verify the docs.**

Run: `grep -rnE 'agy[-_]read' --include='*.md' skills README.md .claude/CLAUDE.md`
Expected: only the historical mentions in dispatch-cli SKILL.md (the withdrawal note, the line-448 history, line 453's 2026-08-17 anecdote and line 456's comparison) and CLAUDE.md's "was withdrawn". No routing row still calls the lane "deprecated".

Run: `bash tests/test-lane-model-config.sh && bash tests/test-docs-context.sh`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add skills/writing-prose/SKILL.md README.md .claude/CLAUDE.md docs/adr/0040-agy-read-lane-default.md docs/adr/0052-pi-read-on-antigravity.md docs/plans/2026-10-05-withdraw-agy-read.md
git commit -m "docs: retire agy-read from live docs; amend ADRs 0040/0052"
```

### Task 4 (operator, after merge): drop the dead config key

`.agy_read` in `~/.claude/busdriver.json` becomes inert, because no reader remains. On both hosts (Mac and um), back the file up, then remove the key:

```bash
cp ~/.claude/busdriver.json ~/.claude/busdriver.json.bak-pre-agy-read-withdrawal
jq 'del(.agy_read)' ~/.claude/busdriver.json > ~/.claude/busdriver.json.tmp && mv ~/.claude/busdriver.json.tmp ~/.claude/busdriver.json
jq 'has("agy_read")' ~/.claude/busdriver.json   # expect false
```

## Acceptance

- `grep -rnE 'agy[-_]read|AGY_READ' skills/dispatch-cli/scripts scripts/lib hooks` prints nothing.
- `grep -rnE 'agy[-_]read|AGY_READ' tests` prints matches in exactly two places:
  - `tests/test-agy-dispatch-arm.sh`: its header provenance lines (Task 2 Step 1) and section 1, the withdrawal check (Task 2 Step 3).
  - `tests/test-trusted-review-cli.sh`: the renamed-file note (Task 2 Step 13).

  Any other hit is a leftover. Task 2 Steps 8 and 9 rewrite sections 8 and 10's comments for exactly this reason.
- `grep -rnE 'agy[-_]read' skills --include='*.md'` prints only `skills/dispatch-cli/SKILL.md`'s withdrawal note and its three past-tense history lines (the current line-448, 453 and 456 passages). No routing row still calls the lane "deprecated".
- These tests pass: `tests/test-agy-dispatch-arm.sh`, `test-agy-prose-lane.sh`, `test-lane-model-config.sh`, `test-trusted-review-cli.sh`, `test-agy-argv-limit.sh`, `test-agy-stream-transport.sh`, `test-docs-context.sh`.
- ShellCheck is clean on the edited scripts. `./scripts/gate-integrity.sh --check` is OK.
- The mutation in Task 2 Step 14 makes the moved gate assertion fail.

## Out of scope

- Any change to plain `--cli agy`, to `agy-prose` behaviour, to pi-read, or to the reviewer routes.
- Rewriting historical ADRs, plans or the CHANGELOG.
- The droid-fallback removal (PR2), which is a separate plan.

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
