# Pipeline Audit Remediation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use busdriver:subagent-driven-development (recommended) or busdriver:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the two fail-open gaps in the enforcement gates (matcher/pre-filter bypass, worktree marker mismatch), extend the #325 env-containment to the PURE-BLOCK node hooks (`mcp-health-check` is env-driven → deferred, Task 10), make CI actually verify the fail-CLOSED spine, and clear low-severity correctness/doc debt. Every gate-behavior fix must be proven by an added/updated shell test that FAILS before the fix and PASSES after.

> **Review status (blueprint-review, 4 iterations, fable arbiter):** plan-blocking HIGH trajectory `[2,1,1,0]` — all HIGHs resolved; state reached `medium_issues_remaining` and the loop set `early_stopped: no_improvement_trajectory` (asymptote). Remaining plan-blocking MEDIUMs are concentrated in two genuinely-hard areas flagged in **"Round-4 residuals & known-hard design decisions"** at the end — those need a decision at implementation start, not more plan iteration. The factual audit base (matcher regexes, pre-filters, provenance statuses, 68 tests, 46/186/78 counts, CI gaps) verified accurate every round.

**Source:** 2026-07-12 full pipeline audit (4 parallel review agents + deterministic runs) + blueprint-review round 1 (Agy/Codex/Grok + fable arbiter), all findings re-verified against code. The arbiter corrected three plan errors baked into the first draft — noted inline where they changed the design.

**Tech Stack:** bash, python3 (stdlib), JS (node), JSON manifests, GitHub Actions YAML. No new dependencies.

**Global Constraints (every task must honor):**
- **Fail-CLOSED is non-negotiable.** No fix may introduce an error path that exits `0`/allow — *including a hook whose command fails to launch* (a hook that can't start does NOT exit 2, so it silently allows). Gate scripts keep `set -euo pipefail` + ERR-trap → `{"decision":"block"}`.
- **Provenance (ADR 0014) — check EACH file, do not assume.** Many touched files are `status: sync` in `.upstream-sources.json` (verified: `config-protection.js`, `mcp-health-check.js`, `pre-bash-dev-server-block.js`, `post-edit-console-warn.js`, `run-with-flags.js`, `evaluate-session.js`, and the `continuous-learning/*` files are all `sync`; only `block-no-verify.js` is `custom`). Editing a `sync` file's CONTENT requires flipping its manifest entry to `custom` in the SAME commit. Check per file: `python3 -c "import json;print([m for m in json.load(open('.upstream-sources.json'))['files'] if m['path']=='<PATH>'])"`. Note: adding an `env -i` prefix to a hook's registration in `hooks.json` does NOT edit the JS file's content, so containment-only changes to a JS hook need no flip — but any change to the JS body does.
- **Never delete a skill — vault it** (`git mv` to `skills-archive/` + manifest path rewrite + `(vault)` marker). ADR 0010; do not re-litigate.
- ShellCheck clean for any touched `*.sh`: `shellcheck --severity=warning <file>`.
- **`npm run validate`** (`scripts/ci/validate-all.js` — schema/workflow/hook-registration validation) MUST pass in the verify block of every task touching `hooks/hooks.json`, `.github/workflows/*.yml`, or `.upstream-sources.json`.
- After touching `.upstream-sources.json` or moving files: `bash tests/test-provenance-guard.sh && bash tests/test-vault-references.sh && bash tests/test-upstream-manifest.sh` — all PASS.
- Conventional commits, lowercase subjects, one commit per task (Task 0 is the exception — it produces fixtures/notes, no standalone commit; its artifacts land inside PR-A). Litmus gate fires per commit — expected, do not bypass.
- Do NOT touch (SETTLED per CLAUDE.md): arbiter chain, provider scrub, impeccable integration, and the EXISTING `env -i` shell-gate wrapper's behavior (extend the model to node hooks via a new launcher; do not weaken the shell path).

**Prior decisions this plan builds on (do not re-open):**
- ADR 0016 / #325 — gate env containment via `env -i` + `sanitized-gate.sh`. This plan EXTENDS containment to blocking node hooks (Task 3) via a sibling `sanitized-node.sh`; it does not alter the shell-gate wrapper.
- ADR 0010 — vault mechanism. ADR 0014 — provenance sync/custom/local semantics.

**Branch/PR grouping — EXPLICIT STACK (each branches off the previous, merged in order; all `hooks.json` edits live in PR-A to avoid conflicting resolutions):**
- **PR-A `fix/gate-fail-open`** (off `main`) — Tasks 0 (fixtures, no standalone commit), 1, 2, 3. Commit order: Task 1 → Task 2 → Task 3 (each self-contained; no async `run()` ships here, so no await-ordering constraint remains). The HIGH + MEDIUM security gate fixes.
- **PR-B `fix/ci-gate-coverage`** (off PR-A) — Tasks 5, 4. Task 5 is a **blocking prerequisite** of Task 4 (the full-glob CI run must not fail on the stale test) — commit 5 before 4.
- **PR-C `chore/audit-housekeeping`** (off PR-B) — Tasks 6, 7, 8, 9 (in that order; Task 9 last so doc counts settle after any other change). LOW correctness + docs. (Task 10's mcp-health-check work + skill-archive are BOTH deferred out — see Task 10.)

---

### Task 0: Baseline — reproduce each failure before fixing (fixtures for PR-A, no standalone commit)

Prove every gate finding is real in THIS tree before changing code. Task 0 produces the regression *fixtures/notes*; the reproductions document today's buggy pass-through, and the regression tests derived from them are what flip fail→pass post-fix. **Run every reproduction in an INERT harness** — a `mktemp -d` scratch git repo, gate scripts invoked directly with synthesized stdin JSON, never against the live busdriver repo — so no reproduction can create a real commit/PR/marker or mutate the working tree.

- [ ] **Matcher bypass (#1):** confirm `command git commit` / `env git commit` / `/usr/bin/git commit` evade `pre-commit-gate.sh`, and `gh  pr create` / `gh  pr merge` (double space) skip the `pre-pr-gate.sh:55` / `pre-merge-gate.sh:83` pre-filters → early `exit 0`.
- [ ] **Worktree marker (#2):** in a scratch repo + `git worktree add` linked worktree, write a design doc from CWD=main, then `cd worktree && git commit` → confirm Gate 1 does NOT fire. This is the reproduction Task 2's fix MUST close.
- [ ] **careful-guard (#5):** `rm -rf /etc && rm -rf node_modules` → confirm no warning.
- [ ] **node-hook containment (#3):** confirm `env -i PATH=/usr/bin:/bin sh -c 'command -v node'` finds nothing on this host (node at `~/.local/bin/node`) — this is WHY a naive `env -i` wrapper fail-opens.
- [ ] **Stale test (#4/#6):** `bash tests/test-docs-context.sh` → 0/2; with `LITMUS_DOCS_CONTEXT=1` → 2/2.

---

## PR-A — Enforcement-gate fail-open fixes

### Task 1 (HIGH): Harden `git commit` / `gh pr create` / `gh pr merge` detection — both layers

**Root cause:** duplicated-logic drift. `pre-merge-gate.sh:113` already uses whole-command `re.findall(r'\bgh\s+pr\s+merge\b', cmd)`; the commit/PR-create gates use start-anchored `re.match(r'git\b', seg)`, defeated by any prefix (`command`/`env`/`/usr/bin/`). Separately the shell pre-filters in `pre-pr-gate.sh:55` and `pre-merge-gate.sh:83-84` require literal single spaces and `exit 0` (allow) on no-match.

**Files:** `pre-commit-gate.sh`, `pre-pr-gate.sh`, `pre-merge-gate.sh` (pre-filter only — its parser is already correct), `post-commit-consume-marker.sh`, `post-pr-consume-marker.sh` (mirror the detection so write/read stay consistent).

- [ ] **Step 1 — Python detection:** replace the yes/no `re.match(r'git\b', seg)` (pre-commit) and `re.match(r'gh\s+pr\s+create\b', seg)` (pre-pr) with whole-command detection modeled on pre-merge: find the `git`/`gh` invocation anywhere in the command, then whole-word-check the following token for the `commit` / `pr create` subcommand. Keep the per-segment walk ONLY for extracting `cd`/`-C` target and `--amend`. Mirror into the two consume-marker scripts.
  - False-positive guard: match the subcommand as a whole word after a real `git`/`gh` token — NOT the mere substring "git"/"gh", so an innocuous message containing the word "git" does not fire.
- [ ] **Step 2 — Shell pre-filter:** change `*gh\ pr\ create*` / `*gh\ pr\ merge*` to the wildcard-tolerant `*gh*pr*create*` / `*gh*pr*merge*` (the style `pre-commit-gate.sh` already uses for `*git*commit*`). Pre-filter stays a fast reject; the Python parser remains authority.
- [ ] **Step 3 — Tests:** extend `tests/test-pre-commit-gate.sh`, `tests/test-pre-pr-gate.sh`, `tests/test-pre-merge-gate.sh`.
  - **Bypass-regression cases** (`command git commit`, `env X=1 git commit`, `/usr/bin/git commit`, `gh  pr create`, `gh  pr merge`): MUST fail pre-fix, pass post-fix.
  - **Negative cases** (innocuous command mentioning "git"/"gh" in a message): MUST pass in BOTH revisions (they are not regressions).
  - **Consume-marker parity** (arbiter MED): the same bypass forms + one quoted-text negative MUST be added against `post-commit-consume-marker.sh:118` and `post-pr-consume-marker.sh:98` (they carry the same start-anchored matcher today) — mirror-detection is untested otherwise.

**Verify:** `bash tests/test-pre-commit-gate.sh && bash tests/test-pre-pr-gate.sh && bash tests/test-pre-merge-gate.sh && bash tests/test-gate-adversarial.sh` PASS (incl. the consume-marker parity cases); shellcheck clean.

### Task 2 (HIGH): Repository-wide design-review marker (closes the worktree fail-open)

**Root cause:** write side (`check-design-document.sh:164`, `pre-implementation-gate.sh:427`) writes `$STATE_DIR/...` CWD-relative; read side (`pre-commit-gate.sh:313`) reads `$REPO_DIR/$STATE_DIR/...`. They diverge across worktrees.

**Decision — marker scope is REPOSITORY-WIDE, anchored on the SHARED git-common-dir's main-worktree root (pinned, not deferred).** *Why:* the natural busdriver flow is plan authored in `main`, implemented in a linked worktree — the marker MUST be shared across worktrees or the gate never fires where the commit happens. `--show-toplevel` is per-worktree; `--git-common-dir` resolves to the SHARED `.git`, so one marker location serves all linked worktrees. **Exact location (decided now — store the marker INSIDE the shared common dir, not a worktree `$STATE_DIR`):** `$(git -C <repo> rev-parse --path-format=absolute --git-common-dir)/busdriver/design-review-needed.local.md`. *Why inside the common dir, not `dirname(common-dir)/$STATE_DIR`:* the arbiter empirically showed `dirname "$(git rev-parse --git-common-dir)"` is NOT the main-worktree root under `git init --separate-git-dir` (it's the detached git-dir's parent) — so any main-worktree-root formula is layout-fragile. The common dir itself is always shared across linked worktrees and always resolvable regardless of layout, sidestepping the "where is the main worktree root" question entirely; it's internal gate state (not user-facing), so living under `.git/busdriver/` is correct. Bare-repo behavior falls under the Step 3 failure policy (block on writer). *Low-reversibility gate-correctness decision — validated by the Step 4 two-worktrees/two-docs + `--separate-git-dir` tests.* Per-worktree scope rejected (would contradict the Task 0 goal).

**Marker CONTENT is per-doc ENTRIES, independently removable — not a whole-file flag (arbiter HIGH, verified).** `pre-commit-gate.sh:318-338` resolves each listed doc path against the committing worktree and, finding them absent there, currently clears the WHOLE marker; `run-design-review-loop.sh:1183` and the cleanup consumers `rm -f` the whole file. Once the marker is shared across worktrees, whole-file deletion by one worktree/one reviewed doc wipes pending entries for OTHER docs/worktrees (a race + a fail-open). The marker must therefore store entries keyed by the doc's path **relative to its own worktree root** (`git -C "$(dirname FILE)" rev-parse --show-toplevel`, then strip that prefix → e.g. `docs/plans/X.md`). This is stable across worktrees: a doc written at `docs/plans/X.md` in `main` and the commit gate resolving `docs/plans/X.md` in a linked worktree produce the SAME key, so the entry matches. (Common-dir-*relative* keys were rejected — linked-worktree files aren't under the common dir at all.) Every consumer removes ONLY the reviewed doc's entry, deleting the file only when it becomes empty.

- [ ] **Step 1 — Single shared path+entry helper (both languages).** Add ONE resolver used by every consumer (shell: extend `lib/resolve-repo-dir.sh` with `gate_marker_path`; python: equivalent or shell-out). It (a) returns the pinned common-dir-anchored absolute marker path above (`--path-format=absolute --git-common-dir` + `/busdriver/…`), and (b) computes a doc's entry key as its path relative to that doc's own worktree root. Writer/reader/cleanup all resolve the SAME shared marker file and the SAME per-doc key.
- [ ] **Step 2 — Update ALL consumers to entry-level semantics** (verified list — none may stay CWD-relative OR whole-file):
  - WRITE (add entry): `check-design-document.sh:164`, `pre-implementation-gate.sh:427` (also switch its `gate_skip_file_repo_controlled "."` to resolve the real repo dir).
  - READ (check entry): `pre-commit-gate.sh:313,318-338` — repoint to the shared helper AND change its per-doc-absent logic to remove only that entry, never the whole file.
  - CLEAR/CLEANUP (remove one entry, delete file only when empty): `run-design-review-loop.sh:1183` (`rm -f` → entry removal), `design_cleanup.py:14` (**also fix: it currently REJECTS absolute state paths — arbiter finding — which conflicts with the absolute common-dir helper path; accept the absolute helper path**), `load-orchestrator.sh:50`.
  - ALSO READ (degraded path — arbiter new finding): `pre-implementation-gate.sh:50` reads `$STATE_DIR/design-review-needed.local.md` CWD-relative in the python3-missing degraded branch — repoint it through the helper too, or it silently diverges when python3 is absent.
- [ ] **Step 3 — Atomic entry mutation (arbiter MED).** The marker is now shared, so two worktrees may add/remove entries concurrently. Every mutation goes through the helper as read-modify-write under a lock (`flock` where available, else atomic temp-file + `rename(2)`), so a concurrent add and remove cannot lose an entry or corrupt the file. Define this once in the helper; all consumers use it.
- [ ] **Step 4 — Resolution-failure policy (define ONE).** If the target file's repo cannot be resolved: the **writer (PreToolUse)** BLOCKS (fail-CLOSED — `{"decision":"block"}`); **cleanup consumers** emit a durable high-visibility stderr warning and take NO destructive action (never whole-file delete). A CWD-relative fallback is NOT fail-closed and must not be labeled as such.
- [ ] **Step 5 — Tests:** `tests/test-design-marker-worktree.sh` with (a) Task 0's doc-in-main / commit-in-worktree repro → Gate 1 fires post-fix; (b) **two worktrees, two pending docs**: reviewing/committing doc A removes only A's entry and leaves B's marker intact (the whole-file-deletion race); (c) marker file deleted only when its last entry clears; (d) unresolvable-`FILE_PATH` → writer blocks; (e) non-worktree path unchanged; (f) `git init --separate-git-dir` layout → marker still resolves to the shared common dir.

**Verify:** new test + `bash tests/test-pre-implementation-gate.sh && bash tests/test-pre-commit-gate.sh && bash tests/test-blueprint-review-state.sh` PASS; shellcheck clean.

### Task 3 (MEDIUM): Contain the PURE-BLOCK node hooks via a `sanitized-node.sh` launcher + correct ADR 0016

**Root cause:** ADR 0016 contained the 10 shell gates but left node hooks inheriting session env; `.claude/settings.json` (not gitignored) sets `ECC_HOOK_PROFILE`/`ECC_DISABLED_HOOKS`, read by `hook-flags.js:19,24`, disabling them.

**Scope decision — contain only hooks whose exit-2 is a PURE gate decision, NOT env-driven behavior (arbiter finding, verified).** Inventory by capability, but DO NOT rely on the grep alone — `grep -rn 'process.exit(2)\|exitCode' scripts/hooks/` is a starting heuristic that misses indirection (helper funcs, `process.exitCode` split across lines); confirm each hook's exit-2 semantics by reading it:
- **CONTAIN (pure block, env only for the FLAG that `env -i` is meant to wipe):** `block-no-verify.js:565`, `config-protection.js`, `pre-bash-dev-server-block.js:221`.
- **DO NOT CONTAIN — accepted residual:** `mcp-health-check.js`. Its exit-2 paths (~580/629/700) are gated on `ECC_MCP_HEALTH_FAIL_OPEN` and it reads ≥4 more behavior-affecting env vars, so `env -i` would CHANGE its behavior, not just strip the injection flag. Its exit-2 also defaults fail-CLOSED (`shouldFailOpen()` is false by default — iter-2 arbiter), so the injection risk is bounded. Document it as accepted residual in the ADR; a proper containment (re-importing its legit vars) is a separate scoped task. **This also removes the async-`run()`/matcher/latency work from this plan** (see Task 10).

A naive `/usr/bin/env -i PATH=/usr/bin:/bin … node …` wrapper **fail-OPENS**: node may live at `~/.local/bin/node`, unreachable under that PATH; a hook that can't launch never exits 2 → the tool proceeds. The shell gates survive only because their command is absolute `bash → sanitized-gate.sh`, which REBUILDS a trusted PATH. Node needs the same.

**Files:** new `hooks/gate-scripts/lib/sanitized-node.sh`, `hooks/hooks.json`, `docs/adr/0016-gate-env-containment.md`, `tests/test-gate-env-containment.sh`, and a new manifest test.

- [ ] **Step 1 — `sanitized-node.sh` launcher (ONE execution model — resolve node, then exec `run-with-flags.js`).** Mirror `sanitized-gate.sh`: run under `/usr/bin/env -i`, rebuild the SAME trusted PATH allowlist (`/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:…`, `sanitized-gate.sh:51`; arbiter confirmed `/opt/homebrew/bin/node` resolves under it here), neutralize git config / HOME, then `exec node run-with-flags.js "$@"` (the runner is the dispatch layer — keep it in the path; do NOT `exec node <hook>` directly).
  - **Launcher argv contract (resolve the self-contradiction):** the launcher HARDCODES the runner — `exec node "$ROOT/scripts/hooks/run-with-flags.js" "$@"` — and `"$@"` is ONLY run-with-flags' own args (`<hookId> <scriptRelPath> <profilesCsv>`). hooks.json therefore passes those three args after the launcher, NOT a literal `run-with-flags.js`: `… bash "…/lib/sanitized-node.sh" "pre:block-no-verify" "scripts/hooks/block-no-verify.js" "standard,strict"`. (The earlier draft both hardcoded the runner AND passed `run-with-flags.js` as arg 1 — double-runner; fixed here.)
  - **hooks.json registration shape (expansion order matters):** `/usr/bin/env -i PATH=/usr/bin:/bin HOME="$HOME" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" CLAUDE_HOOK_EVENT_NAME="$CLAUDE_HOOK_EVENT_NAME" bash "…/lib/sanitized-node.sh" <hookId> <scriptRelPath> <profilesCsv>` — the `"$VAR"` values are expanded by the PARENT shell BEFORE `/usr/bin/env -i` wipes the environment (same pattern the shell-gate registrations use). `CLAUDE_HOOK_EVENT_NAME` is re-imported because a contained hook may branch Pre- vs Post-event on it; it is Claude-set per event, not the settings-env injection channel.
  - **Robust node resolution + fail-CLOSED launch contract.** Launcher resolves node via the trusted PATH; if node is NOT found, it MUST emit `{"decision":"block"}` / exit 2 + a loud stderr line — NEVER exit 0. A blocking hook that can't launch its runtime fails CLOSED. (Optional: resolve an absolute node path at install time as fallback.)
  - Constraint: the 3 contained hooks read `process.env` only for the `ECC_HOOK_PROFILE`/`ECC_DISABLED_HOOKS` FLAG (the thing `env -i` wipes on purpose), not for the decision — confirm each by reading it, and confirm each still reads stdin JSON correctly.
- [ ] **Step 2 — Contain the 3 pure-block hooks** in hooks.json (Pre- and PostToolUse registrations where applicable). Leave the rest uncontained; document `mcp-health-check` + the advisory/telemetry hooks as accepted residual in the ADR.
- [ ] **Step 3 — Manifest guard test.** Add `tests/test-node-hook-containment.sh`: inventory exit-2-capable hooks (grep as a starting point, but the test asserts against an explicit CONTAINED-vs-ACCEPTED-RESIDUAL allowlist so a NEW blocking hook that is neither contained nor listed as residual FAILS the test — mechanically enforcing the upgrade trigger without trusting the fragile grep).
- [ ] **Step 4 — ADR 0016 correction.** Fix lines ~100-101/157: the "node hooks make no allow/block decision" claim is FALSE. State the corrected scope: the 3 pure-block hooks ARE contained via `sanitized-node.sh`; `mcp-health-check` (env-driven exit-2, defaults fail-closed) + the advisory hooks are accepted residual.
- [ ] **Step 5 — Single end-to-end containment test.** Extend `tests/test-gate-env-containment.sh` to run the EXACT hooks.json command for `block-no-verify` with node absent from `/usr/bin:/bin` AND `ECC_HOOK_PROFILE=minimal` injected, asserting `git commit --no-verify` is STILL blocked (proves node-resolution + containment together in one real invocation).

**Verify:** `bash tests/test-gate-env-containment.sh && bash tests/test-node-hook-containment.sh` PASS; `npm run validate` PASS; shellcheck/JSON-lint clean. Provenance: containment-only hooks.json edits don't touch JS bodies → no `sync→custom` flip; `hooks.json` and the new launcher follow their own manifest status.

---

## PR-B — CI actually verifies the gates

### Task 5 (LOW, PREREQUISITE of Task 4): Repair the stale `test-docs-context.sh`

`collect_docs_context` is opt-in (`LITMUS_DOCS_CONTEXT=1`, default off, `docs-context.sh:68`); the test asserts the default path emits output → 0/2. Must land BEFORE Task 4 or the full-glob run fails.

**Files:** `tests/test-docs-context.sh`.
- [ ] `export LITMUS_DOCS_CONTEXT=1` at the top; add one assertion that with the flag UNSET the function is silent (covers the default-off contract).

**Verify:** `bash tests/test-docs-context.sh` PASS.

### Task 4 (MEDIUM): Run the full shell-test suite in CI

`tests.yml` hand-lists ~15 of 67 shell tests under `timeout-minutes: 5`; every gate/security suite is excluded.

**Files:** `.github/workflows/tests.yml`.
- [ ] **Step (a) — Inventory:** run ALL `tests/test-*.sh` (glob, do not hardcode the count — it is 68 today, not 67, and will grow as this plan adds suites; the runner prints the discovered count) locally in a clean environment; produce a pass/skip/fail table and **check it into PR-B as an artifact**. Identify suites needing live `codex`/`gh`/gateway creds (must self-skip headless — e.g. existing `BLUEPRINT_ARBITER_LIVE_TEST` / `SKIP:` guards).
- [ ] **Step (b) — Self-skips, bounded:** for every non-runner-safe suite lacking a guard, add one (skip-with-reason, exit 0). **Guard against skip-masking:** declare the gate suites (`test-pre-commit-gate`, `test-pre-pr-gate`, `test-pre-merge-gate`, `test-design-marker-worktree`, `test-gate-env-containment`, `test-node-hook-containment`, `test-gate-adversarial`, `test-skip-file-repo-controlled`) **non-skippable** — the runner fails if any of them skips — so containment coverage can never be silently dropped. The runner prints skip counts and fails on unexpected skips.
- [ ] **Step (c) — CI loop:** replace the hand-picked list with a full-glob loop (repo-owned `scripts/ci/run-shell-tests.sh` so local and CI run identically) that fails the job on any non-zero, prints failing/skipped test names + discovered count, uses a per-test timeout, and raises `timeout-minutes` to fit the full suite. **Use a portable timeout** — bare `timeout` is absent on macOS/BSD; reuse the repo's existing portable-timeout helper (`scripts/lib/resolve-cli.sh:155`, which already handles `timeout`/`gtimeout`/none) so the runner works for local macOS dev too.

**Verify:** `npm run validate` PASS (workflow schema); the checked-in pass/skip table shows every gate suite PASS (not SKIP); a stashed-revert of Task 1 or Task 2's fix turns the CI shell-test step red (spot-check on the stacked branch).

---

## PR-C — Housekeeping (LOW)

### Task 6 (LOW): careful-guard evaluates each `rm` independently

Advisory guard (fails open by design) — real false negative: greedy `sed` (`careful-guard.sh:55`) strips to the LAST `rm`, so `rm -rf /etc && rm -rf node_modules` warns on nothing.

**Files:** `hooks/gate-scripts/careful-guard.sh` (bash).
- [ ] There is NO existing shared segment-split helper (`lib/` has only design_cleanup.py, load_instincts.py, notes_staleness.py, resolve-repo-dir.sh, sanitized-gate.sh). Define a **minimal inline bash splitter** in careful-guard.sh (split on `&&`/`;`/`|`, evaluate each `rm` against the safe-artifact carve-out separately). Do not claim to reuse a helper that doesn't exist. Add a test case: `rm -rf /etc && rm -rf node_modules` → warns.

### Task 7 (LOW/latent, PR-C): `await` async hook `run()` in run-with-flags + close blocking-dispatch exit-0 paths

`scripts/hooks/run-with-flags.js:212-216` calls `hookModule.run(...)` without `await` inside async `main()`; `resolveHookResult` (lines 62-81) maps the returned Promise to exit-0 pass-through — so a future async `run()` on a blocking hook would fail-OPEN. No async `run()` ships in this plan (the mcp-health-check `run()` export was dropped — Task 10), so this is a latent-bug fix, not an ordering prerequisite.

**Files:** `scripts/hooks/run-with-flags.js` (**status: sync — flip to `custom` in the same commit**).
- [ ] `const output = await hookModule.run(...)`. Add a `__tests__` case with an async `run()` returning a blocking decision; assert it's honored (not swallowed to exit 0). **Also add the shell-level fails-before/passes-after assertion the Goal demands** (drive the real hooks.json dispatch, not just the unit).
- [ ] **Residual exit-0 dispatch paths (arbiter MED, verified):** `run-with-flags.js` exits 0 pass-through on missing hookId (:160), disabled hook (:166), path traversal (:182), missing script (:188), require() failure (:206), and the un-awaited run() (:212-216). For a hook dispatched as a BLOCKING gate, several of these silently allow. Enumerate all six; for each, convert to fail-CLOSED for the blocking-hook case OR document as accepted residual with explicit rationale in-code (do NOT blanket-"document away" — decide per path).
- [ ] Flip `run-with-flags.js` to `custom` in `.upstream-sources.json`.

**Verify:** `npm test` + `bash tests/test-provenance-guard.sh` PASS.

### Task 8 (LOW): `block_emit` JSON fallback hardening

jq-absent fallback escapes only `"` (fails closed today; robustness only).

**Files:** `pre-commit-gate.sh`, `pre-pr-gate.sh`, `pre-merge-gate.sh`, `freeze-guard.sh`.
- [ ] Route the fallback through `python3 -c 'import json,sys;…'` (trusted PATH always has python3), or drop it since jq is guaranteed on the trusted PATH. One test asserting a reason with a backslash/newline emits valid JSON.

### Task 9 (LOW, run AFTER Task 6-8 in PR-C): Refresh stale doc counts

`.claude/CLAUDE.md` (65→46 agents, 287→186 skills), `README.md` (49→46 agents, 206→186 skills, 80→78 commands). All predate the vault archive.

**Files:** `.claude/CLAUDE.md`, `README.md`.
- [ ] Prefer REMOVING the hardcoded numbers (point to the registry) so future vault moves don't re-drift; if a count is kept, compute it at edit time (`ls agents/*.md | wc -l`, `ls -d skills/*/SKILL.md | wc -l`, `ls commands/*.md | wc -l`) and note the live/archive split. Do this last so no earlier task changes the counts under it.

### Task 10 (DEFERRED OUT of this plan — recorded for a follow-up issue)

Two sub-tasks from the original draft are BOTH deferred; neither belongs in this remediation:

1. **`mcp-health-check` latency trim (`run()` export + `*`-matcher narrowing) — deferred.** Adding an in-process `run()` collides with the un-awaited-`run()` bug (Task 7) and, because `mcp-health-check` reads behavior-affecting env vars (Task 3), its containment is non-trivial. It's a ~50-100 ms/tool-call optimization, not a fail-open fix — wrong risk/reward to ride along a security PR. Open a separate follow-up: contain `mcp-health-check` properly (re-import its legit env vars) AND do the latency trim together, after Task 7's `await` lands.
2. **continuous-learning v1 archive — CANCELLED (my original audit finding #6 was WRONG).** v1 is NOT dead: `evaluate-session.js:57` loads `skills/continuous-learning/config.json`, registered live as `stop:evaluate-session` (`hooks.json:490`); `strategic-compact`/`config-gc`/`iterative-retrieval` SKILL.md reference it; files are `status: sync`. `git mv` would break the session evaluator. A future cleanup must first migrate `evaluate-session.js` off the v1 config, rewrite the 3 SKILL refs, and handle sync provenance — a separate scoped task.

No code changes in this task. (Kept as a numbered placeholder so the follow-up is not silently lost.)

---

## Round-4 residuals & known-hard design decisions (resolve at implementation start)

Iteration 4 cleared all plan-blocking HIGHs but surfaced MEDIUMs concentrated in two areas that are genuinely design sub-problems, not remediation sub-steps. **Decide these before writing Task 2/3 code** — do not treat them as already-settled:

**A. Task 2 — the design-review marker across worktrees is its own design task (recommend splitting it out).** The recurring root the arbiter kept finding: even with a shared marker location + worktree-relative entry keys, `pre-commit-gate.sh:326,337` still treats *"the listed doc is absent from THIS committing worktree" as "reviewed/remove entry"* — so a doc authored in `main` and committed from a linked worktree is absent there and the gate passes. Fixing marker LOCATION does not fix this RESOLUTION SEMANTIC. Open sub-decisions, all verified:
  - Change the gate's per-doc semantic so "absent from the committing worktree" is NOT "reviewed" (this is the actual fix; it touches gate-internal logic beyond a marker move).
  - **Entry identity across divergent branches:** two worktrees can hold DIFFERENT unreviewed content at the same relative path (`docs/plans/X.md` on two branches) — a worktree-relative path key is not unique doc identity. Decide whether identity is path, path+content-hash, or path+branch.
  - **Migration / dual-read:** existing markers at `$REPO_DIR/$STATE_DIR/design-review-needed.local.md` must be dual-read (old + new location) for one release, or they silently strand.
  - **Marker file format + mutation API:** today it's markdown (frontmatter + `- <path>` lines, `check-design-document.sh:173-182`) parsed by ≥3 independent implementations. Pin ONE format + one read-modify-write API (the Step-3 lock helper) before adding entry semantics; the temp-file+rename fallback loses concurrent updates and `flock(1)` is absent on macOS, so the fallback is the common local path — the lock design must not rely on `flock` alone.
  - **Recommendation:** lift Task 2 into a standalone `blueprint` design doc + its own PR; keep only the marker-*location* consolidation in this remediation if a quick win is wanted, and gate the full worktree-correctness fix behind that dedicated design.

**B. `run-with-flags.js` has no runtime signal of whether a dispatched hook is a BLOCKING gate.** It receives only `<hookId> <scriptRelPath> <profilesCsv>` (`:145`). Task 3 (containment) and Task 7 (close exit-0 dispatch paths) both need to know "is this dispatch a blocking gate" to decide fail-open vs fail-closed per path. Decide the source of truth (a 4th arg / a registry keyed by hookId / a naming convention) before Task 7 converts any exit-0 path — otherwise "fail-closed for blocking hooks" has nothing to test against. Task 7's exit-0 inventory also needs correcting against code: `require()` failure falls through to the legacy spawn (not a bare exit-0), and `main().catch` exits 0 (omitted from the first list).

**C. Cheap precision fixes (fold in, no decision needed — all verified):**
- **Task 1:** add `post-merge-confirm-bypass.sh:111,253` to the mirrored-detection file list (same start-anchored matcher). And `pre-merge-gate.sh:129-140` PR-number extraction is ALSO start-anchored — the plan called that parser "already correct"; it is not. Harden it with the same whole-command approach.
- **Task 2:** `pre-implementation-gate.sh:427` is a READER, not a writer (mislabeled); the real whole-file-`rm` consumer to convert is `pre-implementation-gate.sh:592-605` — add it to the consumer list.
- **Task 8:** the premise "jq is guaranteed on the trusted PATH" is FALSE — `sanitized-gate.sh` builds PATH from existing DIRECTORIES only; it never verifies jq is installed. Route the fallback through `python3` (stdlib `json`, always present) rather than assuming jq, OR have the launcher verify jq and fail-closed.
- **Do NOT stamp `design-reviewed: PASS` under DEGRADED coverage** — this review had round(s) at 2/3 and one at DEGRADED; a security-gate plan should carry the honest coverage marker, not a bare PASS.

## Out of scope (audit-verified healthy — do NOT touch)
- The `env -i` shell-gate wrapper, `resolve-repo-dir.sh` skip-file guard, anti-self-bypass 30s check, deferred marker consumption — verified correct.
- Cross-platform `stat -f/-c` / `sed -i` / `date` handling — already correct.
- The skills-list token cost (~11.2k/session) — a product decision (which skills to keep), not a bug.
- `freeze-guard.sh:97` broad allowlist — soft investigation aid, cosmetic.
- continuous-learning v1 archive — NOT dead (live via evaluate-session.js); deferred to a separate migration task.

## Success criteria
- The regression tests derived from Task 0's reproductions PASS post-fix (the reproductions themselves document the pre-fix buggy pass-through; they are not "flipped").
- Full `tests/test-*.sh` glob run (runner prints the discovered count — 68+ today) + vitest + pytest green; shellcheck clean; `npm run validate` green; gate suites all PASS (never SKIP).
- `bash tests/test-gate-env-containment.sh` proves `git commit --no-verify` stays blocked with node absent from `/usr/bin:/bin` AND `ECC_HOOK_PROFILE=minimal` injected.
- A stashed-revert of Task 1 or Task 2 turns the CI shell-test step red (proves Task 4 closed the coverage gap).
- All `.upstream-sources.json` status flips for edited `sync` files are present (`test-provenance-guard.sh` green).

<!-- design-reviewed: PASS -->
<!-- design-review-coverage: DEGRADED 1/3 reviewer_1=runtime-droid-rescue reviewer_3=runtime-failed -->
