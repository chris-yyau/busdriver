# Pipeline Degraded Modes — Runbook

External service dependencies in the busdriver pipeline, what fails if each goes down, and the fallback for each. Consult when a CI check is stuck/absent, a review bot is silent, or an UltraOracle consult comes back without a verdict.

## At a glance

| Service | Layer | If down | Impact | Fallback |
|---------|-------|---------|--------|----------|
| **Anthropic API** (Claude) | Local | Can't run Claude Code | Everything stops | Retry + Codex review backend |
| **OpenAI Codex CLI** | Local | Litmus commit review fails; Council Critic voice down | Commits blocked; council loses Critic (4-voice: Architect + Skeptic + Pragmatist + Researcher) | An ordinary failure prints `BUILTIN_FALLBACK` and exits 3 (commit mode can still mint the marker; PR mode fails closed). A trust refusal exits 1 and does not — see the playbook. A full-window timeout is 124. Or set `BUSDRIVER_REVIEW_CLI=agy` / `=builtin`; council continues degraded, note in report |
| **Antigravity (agy) CLI** | Local | Council Pragmatist voice down; blueprint reviewer_1 falls through to auto-detect and typically collapses into DUPLICATE_MODE (coverage DEGRADED, PASS withheld) | Council loses Pragmatist (4-voice: Architect + Skeptic + Critic + Researcher) | Continue degraded, note in report |
| **ChatGPT Pro (UltraOracle)** | Local, opt-in (4.0.0, [ADR 0061](adr/0061-ultraoracle-chrome-extension-transport.md)) | Consult returns no verdict (`skipped:unavailable`, `timeout`, `error`) | Advisory only — no commit, PR, or merge gate. Brainstorming stops for Retry / skip-once / abort. Council omits the Expert Witness on `NOT_ATTEMPTED`, or prints `FAILED` | Playbook below. Opt out with `.claude/skip-ultra-oracle.local` |
| **GitHub Actions** | CI | Required checks don't run | PR merge blocked | `gh pr merge N --admin`, then audit via helmet's `bypass-audit.yml` workflow (if deployed) or manually record the bypass reason |
| **GitHub Apps (bots)** | CI | See per-app rows below | Varies | Detailed below |
| Kodus (Kody) | CI bot | No AI line-level review; `kody-ai` reads `stale` (compulsory, Tier K — ADR 0058) | Every grind waits, then bails at `--max-wait` naming `kody-ai` (no ADR 0012 downgrade). Large PRs are slow (26 min on busdriver#800) and can use several wait-rounds. A `success` check is not an ack — see the playbook below | Check the `Kody Code Review` check-run and the Kodus dashboard (app installed, branch configured, file limit); on a merge-only HEAD comment `@kody review --force`; re-run pr-grind |
| Cursor Bugbot | CI bot | No AI bug review (ungated; ADR 0047) | Kody and Codex still gate | Continue |
| Cubic / CodeRabbit / Greptile | — | Removed from pr-grind (ADR 0058); not gated or enumerated | Open PRs they already reviewed can still carry their untriaged findings | Review those findings by hand before grinding such a PR |
| CodeScene | CI bot | No code-health delta | Advisory only — never blocks merge | Continue; check manually if concerned |
| GitGuardian | CI bot | No secrets scan | gitleaks local hook is the primary | Ensure gitleaks passed locally |
| Codecov | CI bot | No coverage diff | Advisory only | Continue; coverage unmeasured on this PR |
| OpenSSF Scorecard | Scheduled | No weekly health score | No immediate impact — next week retries | Check manually if needed |
| Sigstore / Cosign | Release | Can't sign binaries | Release blocked on signed-artifact repos | Retry; Sigstore's Rekor log occasionally lags |
| npm registry | Release | semantic-release install fails | Release blocked | Retry; clear npm cache; use registry mirror |

## Detection playbooks

### "PR won't merge, checks look green"

1. Run `gh pr checks <N>` — look for any `pending` or absent required check
2. Run `gh api repos/{owner}/{repo}/branches/main/protection/required_status_checks --jq '.contexts'` — what's required
3. Compare — any required context that didn't run? → **path-filter trap**
4. None pending, all required checks present → unrelated issue (GitHub status page)

### "External bot check stuck pending for hours"

1. Check the bot's own status page (Kodus, Cursor, etc.)
2. `gh pr comments <N>` — did the bot post anything error-like?
3. Close + reopen PR to trigger re-registration
4. If still stuck after 30 min → skip that bot in this round, grind others — **except Kody**: it is compulsory (Tier K), so skipping it only leaves `kody-ai` stale. Inspect the `Kody Code Review` check-run and the Kodus dashboard instead, and let pr-grind bail at `--max-wait`. A check that already says `success` can still be stale; use the playbook below before treating it as acked

### "`kody-ai` stays stale after Kody Code Review succeeds"

Tier K (`scripts/ack-ledger.sh`, ADR 0058) acks `kody-ai` only when the deciding `Kody Code Review` run (app slug `kody-ai`) completed `success` on HEAD, or on a predecessor `acks_head` proves content-identical (same tree and same parents, as after a message-only amend; a rebase or a new merge never qualifies), the thread snapshot was taken at least 60 seconds after that run's `completed_at`, and none of the vetoes below fired. Anything else stays `stale`. There is no `none` and no ADR 0012 downgrade.

A green check still leaves the grind stale when:

1. Any Kody review thread is unresolved, including one GitHub has marked outdated. Kody does not re-raise a finding whose lines changed. Only resolving the thread clears it (#989).
2. `THREADS_FETCHED_AT` (GitHub's clock, stamped immediately before the threads query) or the run's `completed_at` is missing or not a whole-second `…Z` timestamp, or the snapshot is less than 60 seconds after `completed_at`. A Kody run still in progress also leaves it stale. Re-checking the instant the check turns green is inside that window.
3. Kody's own issue comment for that run says its findings could not be posted (#1059). The check still completes `success` and no review thread is opened, because the platform rejected the comments. The ledger vetoes when the comment author's login is `kody-ai` or `kody-ai[bot]`, the first line of the body matches `could not be posted` (case-insensitive), and `createdAt` is at or after the run's `started_at` minus 60 seconds. An older comment belongs to an earlier run and does not veto a newer success. The same sentence from another login does not veto. A missing or ill-formed comments payload is `stale` as well.

The comment the ledger reads is `gh pr view <N> --json comments`:

```bash
gh pr view <N> --json comments --jq '.comments[]
  | select(.author.login == "kody-ai" or .author.login == "kody-ai[bot]")
  | {createdAt, first: (.body | split("\n")[0])}'
```

The heading observed for this veto is `## Code Review Completed, but its comments could not be posted`.

Exception (ADR 0064): on a PR opened by the Cursor App bot, Kody's `skipped` run titled `Code Review Skipped` with summary `User Not Licensed — Assign seat to user` reads `skipped-unlicensed`. That is a waiver, not an ack, and it applies only while every Tier K veto holds, including no Kody "could not be posted" comment anywhere on the PR and an exact full-HEAD match. The waiver does not carry across an amend: until Kody posts its own run on the new HEAD, `kody-ai` reads `stale`. If no run appears, comment `@kody review --force`. Completion grants it only when `scripts/kody-waiver.py` prints `waived` (documentation-only PR); otherwise pr-grind stops and Kody must review.

The grind's bail text is the recovery list, and pr-grind does not post it for you. On a merge-only HEAD, comment `@kody review --force` (a plain `@kody start-review` skips again). If an outdated Kody thread is still open, confirm the finding is fixed, then force-review or resolve the thread. Otherwise check the check-run and the Kodus dashboard (app installed, branch configured, file limit) — that is the hint the grind prints when a rejection left no thread. What clears the veto is a later `success` that meets the ack conditions above: settled at least 60 seconds, no open Kody thread, and no unposted-findings comment for that run.

### "GitHub Actions workflows not triggering"

Short version:
- Push events work but `pull_request` events don't → GitHub event-routing glitch
- Quota fine → admin merge; if repo has helmet's `bypass-audit.yml` deployed, it logs the bypass automatically
- Quota gone → switch repo to public (unlimited) or wait for monthly reset

### "Codex review CLI hanging"

1. `ps aux | grep codex` — is it actually running or deadlocked
2. `kill` the process if hung
3. Set `BUSDRIVER_REVIEW_CLI=agy` for this session, or `=builtin` for agent-based fallback
4. If quota exhausted → `LITMUS_PR_FAST=1` to skip multi-agent review (logged to bypass-log)
5. A reviewer that ignores TERM is killed only after a further 5 seconds (`_BD_PT_KILL_AFTER` in `scripts/lib/resolve-cli.sh`, #839). `_run_review_with_retries` (the agy path) subtracts that grace from the configured budget up front, so a budget of 10 seconds or more bounds the whole call. Below 10 seconds the attempt is stamped with the smaller of the budget and the grace, so a longer budget is never given a shorter attempt, and a TERM-deaf child can still finish late by `10 - budget` seconds. `_execute_codex` does not reserve the grace: its timeout test compares the remaining window with the configured duration, so a TERM-deaf Codex can run those 5 seconds past the attempt. A 124 on a full window is still a timeout, not the built-in fallback.

### "Litmus did not fall back to the built-in review"

`BUILTIN_FALLBACK` on stdout and exit 3 means Codex ran, or failed after it was allowed to run, and commit mode may still hand the diff to the built-in reviewer (`skills/litmus/scripts/run-review-loop.sh`). That handoff can mint `litmus-passed.local`. PR mode does not arm it: the loop says a builtin lead is not accepted and exits 1 with no marker. A full-window timeout is exit 124 and is not this path. The stderr line for an ordinary failure is `⚠️  Codex failed after N attempt(s) — falling back to built-in review`.

A trust refusal is exit 1 with no `BUILTIN_FALLBACK` and no handoff. The loop prints `❌ Error: codex review failed (exit code 1)`, writes `terminal_status: infra_failure`, and does not mint a marker. `_execute_codex` prints one of these and stops, without a retry (#815, #1140):

- `busdriver: review lib bytes changed since trusted load — refusing codex dispatch.`
- `busdriver: node is missing or resolves inside the reviewed checkout — refusing companion dispatch.`
- `busdriver: codex companion unresolved after dual re-check — refusing companion dispatch.`
- `busdriver: cannot build disk-fresh companion dispatch PATH — refusing companion dispatch.`

A refusal inside `_portable_timeout --review` is the same verdict one level down (#1141). The launcher exits 86 (`_BD_PT_REFUSED`) only for its own trust check. `_execute_codex` reprints that reason on stderr and exits 1, so the loop's captured stdout can be empty while the reason already went to the terminal. `_run_review_with_retries` does this for its `codex` and `agy` `--review` arms: status 86 is terminal exit 1, and a refusal whose text matches the transient regex is not retried. A reviewer that exits 86 itself is remapped to 1 inside the launcher before any of this. On the Codex path that ordinary failure can still reach `BUILTIN_FALLBACK`.

`=builtin` is the switch for when the Codex CLI is down. It is not the recovery for a `busdriver: … refusing` line. That switch is the handoff the refusal exists to prevent. A staging failure is the other exit 1 that prints no `BUILTIN_FALLBACK` (`busdriver: failed to write codex prompt to temp file`); the prompt was never dispatched.

### "The commit round bails on a settled PR-mode litmus state"

`scripts/dispatcher-commit-block.sh` bails when `init-review-loop.sh` refuses an active state whose `terminal_status` is `review_findings`, `stall`, `max_iterations`, `infra_failure`, `setup_error`, or `too_large`, and `review_mode` is not `commit` (#928). A missing `review_mode` line counts as commit. Two `review_mode` lines, or a mode that is not `pr` or `commit`, count as not commit, so the guard refuses rather than discarding the other cycle.

Read the bail before picking a remedy:

- Init's output contains a `❌` line. The bail quotes that line (first 400 characters) and does not prescribe `--force`. That is init's own retirement refusal. Follow the remedy init printed. `--force` there discards the cycle's findings and counter.
- Otherwise init stopped on its active-state guard (a `⚠️` line). Recovery is two steps, in order, and only while nothing else is reviewing in that worktree. From the worktree, with `LITMUS_MODE` unset, run `/bin/bash -p <litmus scripts>/init-review-loop.sh --force`, then remove `<worktree>/${BUSDRIVER_STATE_DIR:-.claude}/litmus-state.md`, then re-run the round. `--force` alone leaves a commit cycle the next plain init refuses. Removing the state file alone is refused by the lineage ledger. Forcing discards that cycle's findings history and counter. The two steps are operator prose, not a lock: another round can still start between them.

A same-mode finished state is unchanged: the block runs `--force` itself. An active state with no recognized `terminal_status` is not forced. The bail names `init-review-loop.sh --force` only when the review is genuinely dead.

### "The review script says this is not a git repository"

`init-review-loop.sh`, `run-review-loop.sh`, `init-design-review.sh`, and `run-design-review-loop.sh` prepend `/usr/bin:/bin` to `PATH` and unset `DEVELOPER_DIR` before they resolve `git` (#816, #1149). Prepending, not replacing: a tool those two directories do not hold still comes from the caller's `PATH`. That residual is the review CLI, and `jq` or `python3` where the host installs them only elsewhere. The resolver pins the review CLI (#789); this `PATH` does not.

On macOS, `/usr/bin/git` and `/usr/bin/python3` are developer-tools stubs that run the `xcrun` under `DEVELOPER_DIR`. The variable is as injectable as `PATH`, so leaving it set let a planted `xcrun` answer the `git` that binds the marker. Unset, a planted value is ignored. Without the Command Line Tools those stubs fail, and so do `git` and `python3`. `init-review-loop.sh` then prints `Not a git repository` and `(or git itself failed to run: it resolves to /usr/bin/git here, #816; on macOS check xcode-select -p)`. The gates already launch with `PATH=/usr/bin:/bin` exactly (`hooks/hooks.json`), so they use the same stubs.

### "pr-grind reports an approver gap after someone commented"

`scripts/approver-gap-detect.sh` counts human approvals from each reviewer's latest decisive review (#1127). `COMMENTED` and `PENDING` are dropped before that latest state is taken. An `APPROVED` followed by `COMMENTED` or `PENDING` from the same person still counts. A comment-only reviewer does not. `CHANGES_REQUESTED` does not count, and neither does `DISMISSED`: a comment after a dismissal does not bring the approval back.

Only a review whose user type is `User`, and whose login does not end in `[bot]`, is counted. The required count is the greater of the ruleset `required_approving_review_count` and classic branch protection on the parent protection endpoint. The decision's `human_approvals` is that count.

Counting the comment used to under-count, report a gap GitHub does not have, and, with `--admin-on-approver-gap` or `.claude/pr-grind-auto-admin-solo.local`, take an admin merge the PR did not need. A real gap (the latest decisive state is not `APPROVED`, or there are fewer approvals than the rule requires) is unchanged.

### "UltraOracle returned no verdict"

Since 4.0.0 the consult is one guarded `claude -p --chrome --model sonnet` child driving the operator's signed-in Chrome (`scripts/lib/ultra-oracle.sh`, [ADR 0061](adr/0061-ultraoracle-chrome-extension-transport.md)). The `oracle` CLI is not on this path. Read the token, then the siblings of `--out`.

| Token from `ultra_oracle_consult` | Its exit | What it means |
|---|---|---|
| `ok` | 0 | Verdict is in `--out` |
| `skipped:user` | 0 | `<repo>/${BUSDRIVER_STATE_DIR:-.claude}/skip-ultra-oracle.local` exists. The previous `--out` was removed. No `.err` |
| `skipped:unavailable` | 3 | Refused before launch, or a clean `setup`-phase result of `extension-not-connected` / not signed in. Not "ChatGPT is down", and not a child that died after submit |
| `timeout` | 124 | No accepted answer before the cap. A lock wait that gives up is this token; a lock dir that cannot take an atomic `ln` is `error` |
| `error` | 1 | Rejected input, or the child ran and the answer was not accepted (`pro-unavailable`, `binding`, `download-missing`, …) |
| `dispatched` | 0 | Background mode only. Completion is `$out.rc`: `0` ok, `124` timeout, `3` unavailable, anything else error |

The two wrappers always exit 0. The token is the status.

- `scripts/ultra-oracle-consult-run.sh` prints the token on stdout. Adapter stderr (hints, the lock line) stays on the terminal. `--surface <name>` prints `skipped:disabled` when that USER switch is off and does not call the adapter. A `NOTE:` line is added on stderr only when the token is `ok` and `$out.hint` is non-empty.
- `scripts/ultra-oracle-run.sh` (council witness) prints `NOT_ATTEMPTED`, `VERDICT`, or `FAILED […]`. It discards the consult's stderr and appends `$out.hint`. The background child's own stderr is `$out.dispatch.err`. A missing Expert Witness section is `NOT_ATTEMPTED` (surface off, or the config lib did not load and the run was not forced). `FAILED [adapter-unavailable]` means the run was forced or enabled and `scripts/lib/ultra-oracle.sh` would not source.

1. **`skipped:unavailable` before a child exists** — first line of `$out.err`:
   - `not-macos` — `uname -s` is not `Darwin`. Linux and CI take this path.
   - `claude-unavailable` and the hint names `/usr/bin/jq` — that binary is missing or not executable. macOS 15 or later ships it. A `jq` elsewhere on `PATH` is not used.
   - `claude-unavailable` otherwise — trusted `claude` did not resolve, `claude --help` does not mention both `--chrome` and `--setting-sources`, or `claude --version` is missing or below `2.1.295` (`scripts/hooks/ultra-oracle-child/signatures.json`). Hint: "Claude Code is missing, too old, or not signed in."
2. **Same token after a child, only while the phase is still `setup` and the audit is clean.** `extension-not-connected`: `open -a "Google Chrome"` failed, or the extension disconnected before submit. Open a window and reconnect Claude in Chrome. With the profile picker "Show on startup" checked, a cold start stops at the picker and the extension never connects (`tests/fixtures/ultra-oracle/qualification.json`). A setup-phase stream that contains `Not logged in` is reason `claude-unavailable` with the same hint as a missing `claude`. A browser cutoff on this path is `timeout` instead.
3. **After the phase is `submitting`, or a conversation id exists,** a dropped browser is `error`, or `timeout` if the browser cutoff fired. It does not return to `skipped:unavailable`.
4. **The lock.** One machine shares one Chrome. A second consult waits, then gives up as `timeout`. Nothing auto-reclaims the lock. If the lock directory cannot support an atomic `ln`, the token is `error` / `internal` and no consult runs. The recovery line is on stderr for a blocking consult and in `$out.dispatch.err` for a background one; `$out.hint` on the timeout path is still "No answer within the cap…". The line says to run ``pgrep -fl -- '-p --chrome --model sonnet'`` and, only when that prints nothing, `rm -f` the lock path it names (`$HOME/.cache/busdriver/ultra-oracle.<cksum>.lock`, or under `/tmp/.cache/busdriver/` when `HOME` is unset). The child's argv is the versioned `claude` binary, so a search for `claude -p` matches nothing while a consult is running.
5. **The cap.** `ultraOracle.timeoutCapSeconds` in the USER config defaults to 900, ceiling 3600, floor 120. Under 120 is `error` / reason `input`, not a timeout. The deadline is anchored when the consult starts. Callers wait `cap + 90` seconds for `$out.rc`. A timeout does not cancel generation already running on ChatGPT; a chat id named in the hint is left unarchived.
6. **Pro and English.** The child never selects a model. `pro-unavailable` means select Pro once in Chrome. `not-home`, and an upload whose facts set `noref`, need ChatGPT's UI in English (`Attach files`, `Send`, `Remove <name>`). A published answer is kept only when its `model` matches `gpt-<digits>[.<digits>]*-pro`.
7. **The download.** Chrome's download prompt has to be off. The answer file is `uora-<tag>.json` (a ` (1)` copy counts) in each profile's `download.default_directory`, then `~/Downloads`. `download-missing` and `hash-mismatch` are different reasons; the hint lists the directories searched.
8. **`ok` can still carry a note.** A failed archive or an unclosed tab stays `ok` / `VERDICT`. The witness wrapper prints `NOTE:` after the verdict; the consult wrapper prints it on stderr. An `ok` with no archive/tab notice and no leftover keys writes neither `$out.err` nor `$out.hint`. Leftover keys (item 9) still append their notice to `$out.hint` on `ok`. If a notice cannot be written, an otherwise `ok` run is published as `error` / `internal`.
9. **Leftover pre-4.0.0 settings.** The USER file is `$HOME/${BUSDRIVER_STATE_DIR:-.claude}/busdriver.json`. Only `timeoutCapSeconds` and the `enabled` switches `brainstorming`, `blueprintReview`, `council`, and `writingPlans` are read, and only from that file. A project `.claude/busdriver.json` cannot turn a surface on. Keys the old CLI left behind — `model`, `browserModelStrategy`, `chromeProfileDir`, `cookiePath`, `remoteHost`, `remoteToken`, `hideWindow`, `attachRunning`, `attachProfileDir` — are named once, by key name, and not applied. Delete `remoteToken`; the notice does not print its value. Seeing `remoteHost` in that list means the consult is not running remotely.

After the fact, `$HOME/.cache/busdriver/ultra-oracle/run-*/record.json` keeps `.status` and `.reason`. Cleanup leaves only that file.

## What NOT to do on degraded state

- **Don't `--no-verify` to bypass local hooks** — they catch secrets, not just code quality. Secrets exposure is permanent.
- **Don't disable branch protection** — even temporarily. The CI issue is external; disabling protection is permanent in git history.
- **Don't mark a check as "not required" to unblock merge** — re-check after the external service recovers is harder than waiting.
- **Don't skip litmus repeatedly without documenting why** — `bypass-log.jsonl` is the audit; untagged bypasses accumulate as tech debt.
- **Don't `rm` the UltraOracle lock while ``pgrep -fl -- '-p --chrome --model sonnet'`` still prints a process** — that lock is what keeps two consults off the same Chrome, and nothing reclaims it for you.
- **Don't set `BUSDRIVER_REVIEW_CLI=builtin` to get a marker after a `busdriver: … refusing` line** — that is the handoff the trust refusal declined. Exit 3 is the path that can mint one; exit 1 is not.
- **Don't invent a recovery for a settled PR-mode litmus state** — the commit-round bail already chose. A `❌` from init is that remedy, and it is not `--force`. The active-state guard needs `--force` and then the state-file removal, in that order.

## Recovery checks after a degraded period

- Review `bypass-log.jsonl` entries from the degraded window — any bypasses that should be re-run now?
- Check `review-metrics.jsonl` for missing iterations — did any PRs merge without a proper review during the outage?
- Re-trigger any skipped external bots on the now-merged commits if possible (CodeScene accepts retroactive runs)

## Related references (in `~/.claude/notes/`)

- `reference_github_required_checks_pattern.md` — path-filtered checks trap + job-level skip fix
- `reference_github_pullrequest_event_blackhole.md` — PR event routing glitch diagnostic
- `reference-full-pipeline.md` — full pipeline diagram (LOCAL + CI + PR review + merge)
