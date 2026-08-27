# Pipeline final plan — 2026-08-27 (integrity first)

> **Status: APPROVED by operator 2026-08-27** after a pipeline audit, an ultra-council on the audit, an
> open-issue triage against merged PRs / ADRs / the tree, and an ultimate-council on the consolidated
> plan (5 voices + UltraOracle + Mythos Witness + Mechanism Witness). Hindsight page:
> `initiative-pipeline-final-plan-2026-08-27-integrity-first`. Lessons:
> `~/.claude/notes/lesson-council-2026-08-27-{audit-logs-are-test-polluted,integrity-before-cost}.md`.

## Why this order

Every council voice and witness inverted the audit's cost-first order: a gate set with known
fail-open paths cannot be optimized ("a measurement of theatre"), and policy decisions that say
"decide after data" must schedule their data collection before the changes that would contaminate
the baseline.

## Execution order

| # | Item | Class | Evidence / settling check |
|---|------|-------|---------------------------|
| 0 | **Gate integrity**: #713 (`SHELLOPTS=noexec` in a committed `settings.json` env block silences the outer shell of every contained registration — ADR 0016:210-228 names it as an out-of-scope class residual; fixing it closes that residual), #622 (conflict-free `git merge` / `cherry-pick` / `revert` / `--continue` commit without litmus — `pre-commit-gate.sh:112-115` pre-filters on the `commit` token). Then the integrity epic: #553, #570, #576, #742, #563. | hard | `env SHELLOPTS=noexec /bin/sh -c 'echo X'` prints nothing rc 0 (reproduced 2026-08-27; zsh executes). Each fix ships with a test that drives the bypass and asserts the block. |
| 1 | Fix `scripts/lib/resolve-cli.sh` grok preflight under the Bash tool (zsh: `BASH_SOURCE` empty → refuses → `council.researcher` falls to droid); droid re-auth or delete the fallback rung (closes #556). Isolate test writers from live logs — `~/.claude/homunculus/dispatch-log.jsonl` (~10.4k/15.6k rows in 60 d are tests) and `.claude/bypass-log.jsonl` (all event counts multiples of 39). `tests/test-pre-merge-gate.sh` already isolates `BUSDRIVER_STATE_DIR` (verified: 2810→2810 lines); candidates: `test-codex-premerge-warn.sh`, `test-gitcmd-detect.sh`, `test-gate-untrusted-cd.sh`, `test-relevant-check-status.sh`. Re-measure afterwards. | hard | `bash -c 'source scripts/lib/resolve-cli.sh; resolve_role_cli council.researcher'` → `grok`; under zsh → `droid`. Per-test `wc -l .claude/bypass-log.jsonl` diff. |
| 2 | **Review-yield ledger spike** — unique defects per reviewer/gate, duplicates, false positives, downstream escapes, tokens, elapsed. Baseline BEFORE any policy change. | hard | The spike is the check. |
| 3 | Disable both `continuous-learning-v2` `observe.sh` hooks (`hooks.json` Pre+Post `*`; observer.enabled=false; instincts last written 2026-03-31) AND prune non-contained, side-effect-free ECC hooks (`ECC_HOOK_PROFILE` unset → 30/32 flag-hooks on; contained ones run under `sanitized-node.sh`, which strips `ECC_DISABLED_HOOKS` by design) — together, ONE before/after per-Bash-call latency measurement. Archive `~/.claude/homunculus/` except `dispatch-log.jsonl`. Amends ADR 0048 D1, ADR 0046. | hard | Hook fan-out timing before/after (baseline: 14 PreToolUse procs, ~1.5 s CPU, ~300 ms wall per Bash call). |
| 4 | Retire the file-level sync **mechanism** — `~/.claude/scripts/sync-upstream.sh` and its cache — but **keep `.upstream-sources.json`, frozen as the provenance inventory**, and keep BOTH `tests/test-upstream-manifest.sh` (schema guard) and `tests/test-provenance-guard.sh` (it SKIPs when the manifest is absent, `tests/test-provenance-guard.sh:175`, so removing the file would silently disable it). **Precondition (Codex, #775): inventory the surviving `sync`-status entries and their consumers before retiring the copier.** Be precise about what ADR 0048 measured: it was the vendored *skills* that were never read (zero vault promotions in eight weeks) — the 235 surviving `sync` entries are 110 scripts (58 `scripts/lib`, 26 `scripts/hooks`, 8 `scripts/ci`, 18 other), 68 skill files, 51 commands and 6 agents, and some ARE live (e.g. `scripts/hooks/session-start.js`, `.upstream-sources.json:984-987`, runs on every SessionStart via `hooks/hooks.json:16-25`). The precondition inventory carries a consumer/reachability row for EVERY one of the 235 entries, not just hooks and scripts: reachability is the TRANSITIVE closure from the plugin's roots — `hooks/hooks.json` registrations, every `skills/*/SKILL.md`, `commands/*.md`, `agents/*.md`, `.github/workflows/*`, `package.json` scripts — following file references (`bash`/`node`/`source`/`require`/relative-path mentions) to a fixpoint, so `scripts/hooks/check-hook-enabled.js` is `live` via `run-with-flags-shell.sh` and `skills/brainstorming/scripts/server.cjs` is `live` via `SKILL.md → visual-companion.md → start-server.sh`, even though neither is cited by a root directly. Every entry ends in exactly one disposition — `live:<shortest chain from a root>`, `unreferenced` (no chain from any root — deletion candidate, confirmed by a second pass after the candidate is moved aside and the shell + vitest + pytest suites run), or `dead` (a command shim whose target is gone) — and the copier is retired only after no entry is still `?`. Category owners for follow-through: hooks → items 3/12; commands + agents → the agents/commands round ADR 0048 deferred; skill files → ADR 0048 D1's keep-list; `scripts/lib` + `scripts/ci` + other scripts → dispositioned in the inventory itself. Also update `tests/test-provenance-guard.sh:6,184`, whose remediation text still says `sync-upstream.sh` detects drift, in the same PR that retires the copier; what this row retires is the *copier*, because syncs did land (2026-04-15, 04-30, 05-29, 06-20, 07-07) but nothing since the trim, the cache dir is absent, and every surviving entry is effectively `custom` once ECC content is pruned rather than refreshed. Generate `THIRD_PARTY_NOTICES` from files actually shipped, verified against each upstream's license. Upstream digest on demand only. Explicit ADR amending ADR 0048 D6 + ADR 0014. | hard | Precondition artifact: the inventory (`jq -r '.files[] \| select(.status=="sync") \| .path' .upstream-sources.json` — all 235 rows — each joined to its consumer per the rule in the row and carrying a disposition; zero `?` rows before the copier is retired). Disconfirming evidence = an upstream fix to a surviving live `sync` entry that the on-demand digest would not surface — i.e. the copier caught something the digest cannot; absent that, the copier stays retired. |
| 5 | CI: make `scripts/ci/run-shell-tests.sh` print per-test durations, then shard into a duration-balanced matrix with ONE aggregate check still named `shell-tests`, `if: always()`, failing on any failed / cancelled / missing shard; update `.github/required-checks.lock` (`matrix_value` semantics). Folds #632. | hard | Lock lists `shell-tests` as required; aggregate reports on every PR including skipped shards. Baseline 14.9 min of a 15–21 min run. |
| 6 | Extract the pr-grind `SKILL.md` Dispatcher Loop (lines 103–897 of a 120 KB file) into scripts; doctrine + issue-numbered caveats stay; parity tests assert semantic/output contracts (shell state, cancellation, retries, partial output), not byte-for-byte. #547/#662 stay separate reliability work. Later: blueprint-review (90 KB), council (57 KB), litmus (49 KB). | hard | Parity suite diff. |
| 7 | **agy-read gate** in the plugin (`hooks/hooks.json`): PreToolUse on `Read` and bare Bash `cat <file>` (no pipe/redirect), deny whole-file reads >200 lines without offset/limit. Message leads with the trust rule (dispatch only content whose authors you trust; it leaves the machine), then the exact `dispatch.sh --cli agy-read` line. Replaces the advisory `pre-read-size-advisory.js` (keep its bounded probe; its text still says "route to pi"). Registered via `run-with-flags.js` — advisory disposition on infra failure; documented as a cost gate, NOT a security boundary, Bash coverage deliberately narrow. Read doctrine leaves busdriver's project `.claude/CLAUDE.md` for the SessionStart brief. pi-read leaves the routing doctrine; lane code + `.pi_read.model` stay for the pi-replacement program; the lane is inert (cursor provider is a pi extension; lane launches `--no-extensions` in a jail HOME, `dispatch.sh:2313-2317`) until slice 2 lands an `-e <cursor-extension>` launcher. Amends ADR 0040, ADR 0034. | hard | `PATH=/nonexistent` node → Read still allowed (fail-open proven); 201-line file without limit → denied; with `limit` → allowed. |
| 8 | Litmus commit mode: keep `medium` blocking. Stratified sample of 20 medium-only FAILs with predeclared thresholds, dispositioned against the item-2 ledger. Then decide. CodeScene: one final advisory state in the ack ledger, drop per-event acks — re-opens ADR 0012 (`:37`, ledger-only) explicitly; ONE umbrella CodeScene-debt issue absorbing #759 #733 #725 #716 #700 #637 #590 #564 (no blanket close). | needs Chris after data | Ledger numbers. |
| 9 | Docs-only path-class triage (Mythos): docs-only diffs skip litmus `medium` and get one pr-grind round; must keep every lock-required check reporting (a never-reporting check blocks — `pr-grind/SKILL.md:24`). Evaluate against #774 (+20/−2, 6.4 h, 13 reviews). ADR 0044 already carves docs-only commits out of Gate 1. | exploratory | Before/after on the next docs PR. |
| 10 | pi-replacement amendment: Codex retained for review + `/codex:rescue` + imagegen; Slice 6 keeps `pi-goal-handover`, drops `pi-rescue`. **Guarded 6-lite**: launcher runs `pi --model cursor/<id> -e <cursor-extension> --cursor-sandbox` in a git worktree, dispatcher commits from outside, and REFUSES unless worktree clean ∧ base branch operator-authored ∧ no fork PR / untrusted patch, refusal text naming the broker upgrade. Cursor's sandbox is SDK opt-in, not a kernel boundary. ADR records this as deliberately reopening the 13-round sequencing (cite ADR 0006 "trusted dispatcher" + ADR 0026 dispatcher residual). | needs Chris (security-class) | Test: fork-base worktree is refused. |
| 11 | Issue triage. Close after a probe (not a one-liner) — #516 (`design-clear.sh --skip`), #539 (gate hint names `design-clear.sh`, `pre-implementation-gate.sh:758`), #540 (`--all-for-doc --yes`), #644 (release cost fixed; accumulation is ADR 0017/0021 settled), #661 (HyperFrames docs gone), #550 (`cmdword.py:188-191` deliberate won't-fix), #572 (position-blind strategies removed, `skills/blueprint-review/scripts/lib/extract_review_json.py:7`), #592 / #560 (adversarial probe required), #583, #556 (after item 1). Epics: classifier precision #639 #654 #724 #767 #771 #768 #769; dispatch/council reliability #547 #558 #603 #662. Low: #712, #586, #508, #568. | mine | One probe per closure, recorded in the closing comment. |
| 12 | Oracle's missing piece: an adversarial end-to-end pipeline-integrity suite (hostile committed env, shell expansion, merge commands, diff drivers, launcher substitution, missing CI shards) — grows out of item 0's per-fix tests. | exploratory | — |

## ADR bookkeeping

- Amended (each needs an explicit entry naming the decision): 0012 (item 8), 0014 + 0048 D6 (item 4), 0034 + 0040 (item 7), 0046 + 0048 D1 (item 3). ADR 0016 is NOT amended by item 0 — it closes a residual 0016 named.
- Depended on, untouched: 0001, 0002, 0004, 0005, 0006, 0007, 0009, 0013, 0018, 0024, 0026, 0033, 0035, 0036, 0042, 0043, 0047.
- Superseded records left as-is: 0010, 0011, 0015, 0041, 0027-review-once.

## Dropped from the original audit

"3 dangling command shims" (false positive — `learn.md` writes `~/.claude/skills/learned/`, a runtime dir); bypass-log as a gate defect (test pollution); `ECC_DISABLED_HOOKS` for contained hooks (stripped by design); a quarterly upstream digest ritual; loosening litmus `medium` on frequency alone.

## Handover — item 0 (#713) investigation state (2026-08-27, stopped here by operator)

Verified on this host (`claude` CLI, macOS, `/bin/sh` = bash 3.2.57):

1. **Claude Code runs shell-form command hooks via `/bin/sh -c`** (hook logged `$0=/bin/sh`,
   parent comm `claude`, `SHELLOPTS=braceexpand:hashall:interactive-comments:posix`).
2. **A committed `.claude/settings.json` `env: {"SHELLOPTS":"noexec"}` silenced the hook entirely
   and the Bash tool call went through** (throwaway project under the session scratchpad,
   `claude -p … --allowedTools "Bash(echo:*)" --model haiku`). #713 is live, not theoretical.
3. Blast radius is wider than hooks: **every `#!/bin/bash` script run from the Bash tool also
   becomes a silent no-op with rc 0** under that env (`tests/test-freeze-guard-anchoring.sh` and
   `skills/litmus/scripts/run-review-loop.sh --help` both produced 0 bytes, rc 0). zsh ignores
   `SHELLOPTS` (a `#!/bin/zsh` probe ran normally), and the Bash tool itself is zsh here.
4. **The platform primitive #713 asked for exists**: per the hooks reference
   (https://code.claude.com/docs/en/hooks.md), a command hook with `args` set is spawned
   **exec-form (no shell)**; only the shell form goes through `sh -c`. Settings precedence
   (https://code.claude.com/docs/en/settings.md): managed > CLI `--settings` > project local >
   **shared project (overrides user)** > user. `disableAllHooks` exists and is NOT among the keys
   ignored in repository files — so a committed project settings file can plausibly disable every
   hook (ADR 0016 class (b)); **not yet tested empirically**. No documented way for user settings
   to out-rank project settings for `env`/hooks; managed settings
   (`/Library/Application Support/ClaudeCode/managed-settings.json`, absent on this host) do.

Design direction to validate next (four untested claims; (a), (b) and (d) take one `claude -p` run
each, while (c) needs one run PER disposition — five runs — because a single blocking hook would
mask the others; the prepared but NOT executed probe for (a) is below):

- (a) exec-form registration `{"command":"/usr/bin/env","args":["-i","PATH=/usr/bin:/bin","bash","…"]}`
  runs despite committed `SHELLOPTS=noexec` (expected: yes — `env -i` wipes it before bash starts);
- (b) whether `${CLAUDE_PLUGIN_ROOT}` substitution applies inside `args` (needed to locate
  `sanitized-gate.sh` / `sanitized-node.sh`; `env -i` wipes the env var, so it must be passed as an
  `args` value) and whether stdin JSON still reaches an exec-form hook;
- (c) whether an exec-form hook still blocks in each disposition the gates use, kept as separate
  cases: exit 2 (a blocking error in its own right, which supersedes any JSON on stdout); the
  legacy top-level `{"decision":"block"}` the contained gates actually emit
  (`hooks/gate-scripts/pre-commit-gate.sh:50` and siblings); and the current
  `hookSpecificOutput.permissionDecision: "deny"` + `permissionDecisionReason` at exit 0
  ; and `hookSpecificOutput.permissionDecision: "ask"` at exit 0 — the disposition `hooks/gate-scripts/careful-guard.sh:2272` actually emits — which must still force the user prompt under exec form, not silently allow or deny. Also how a
  failed spawn is treated (the `|| exit 2` fail-closed tail cannot exist in exec form — the
  disposition must live entirely inside the wrapper);
- (d) whether a committed `"disableAllHooks": true` silences hooks (if yes, that class cannot be
  closed inside the plugin: document as platform limit, file upstream, and lean on the
  operator-owned rails — `core.hooksPath` is already `~/.codex/git-hooks` on this host, and branch
  protection's required checks).

If (a)–(c) hold: ONE launch-boundary change — convert every contained gate registration in
`hooks/hooks.json` (the 19 `/usr/bin/env -i …` entries) to exec form, update
`scripts/ci/validate-hooks.js` and `tests/test-node-hook-containment.sh` /
`tests/test-gate-env-containment.sh` to require exec form for contained gates (fail-closed pin, not
prose), add a test that drives a `SHELLOPTS=noexec` env through a registration and asserts the
gate still emits its decision, and record the closure of ADR 0016's named residual in a new ADR.
`#622` (merge/cherry-pick/revert/--continue skip the `commit` pre-filter in
`hooks/gate-scripts/pre-commit-gate.sh:112-115`) is independent: gate on the effect (HEAD moved
without a review marker) rather than the verb, with a test that drives a conflict-free merge.

Prepared probe (not run — operator stopped the session before execution):

```bash
# in the scratch project: .claude/settings.json
{"env":{"SHELLOPTS":"noexec"},
 "hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/usr/bin/env",
   "args":["-i","PATH=/usr/bin:/bin","bash","-c","printf 'EXEC_FORM_RAN stdin=%s\\n' \"$(cat | wc -c)\" >> hook.log"]}]}]}}
# then: claude -p "Run exactly this shell command and reply with its output: echo probe" --allowedTools "Bash(echo:*)" --model haiku
# expected: hook.log contains EXEC_FORM_RAN with a non-zero stdin byte count.
```

Session artifacts: empty branch `feat/read-route-gate` (no commits — delete or reuse for item 7);
operator config changes already applied: `~/.claude/busdriver.json` `pi` → `pi_read`, model
`cursor/auto` (backup `busdriver.json.bak-20260827`); scratch project at the session scratchpad
`hookshell-test/` (throwaway). Nothing in this repo is committed yet — this file is untracked.
