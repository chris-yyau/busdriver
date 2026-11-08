# Pipeline Degraded Modes — Runbook

External service dependencies in the busdriver pipeline, what fails if each goes down, and the fallback for each. Consult when a CI check is stuck/absent, a review bot is silent, or an UltraOracle consult comes back without a verdict.

## At a glance

| Service | Layer | If down | Impact | Fallback |
|---------|-------|---------|--------|----------|
| **Anthropic API** (Claude) | Local | Can't run Claude Code | Everything stops | Retry + Codex review backend |
| **OpenAI Codex CLI** | Local | Litmus commit review fails; Council Critic voice down | Commits blocked; council loses Critic (4-voice: Architect + Skeptic + Pragmatist + Researcher) | Falls back to the built-in review (exit 3); PR mode fails closed. Or set `BUSDRIVER_REVIEW_CLI=agy` / `=builtin`; council continues degraded, note in report |
| **Antigravity (agy) CLI** | Local | Council Pragmatist voice down; blueprint reviewer_1 falls through to auto-detect and typically collapses into DUPLICATE_MODE (coverage DEGRADED, PASS withheld) | Council loses Pragmatist (4-voice: Architect + Skeptic + Critic + Researcher) | Continue degraded, note in report |
| **ChatGPT Pro (UltraOracle)** | Local, opt-in (4.0.0, [ADR 0061](adr/0061-ultraoracle-chrome-extension-transport.md)) | Consult returns no verdict (`skipped:unavailable`, `timeout`, `error`) | Advisory only — no commit, PR, or merge gate. Brainstorming stops for Retry / skip-once / abort. Council omits the Expert Witness on `NOT_ATTEMPTED`, or prints `FAILED` | Playbook below. Opt out with `.claude/skip-ultra-oracle.local` |
| **GitHub Actions** | CI | Required checks don't run | PR merge blocked | `gh pr merge N --admin`, then audit via helmet's `bypass-audit.yml` workflow (if deployed) or manually record the bypass reason |
| **GitHub Apps (bots)** | CI | See per-app rows below | Varies | Detailed below |
| Kodus (Kody) | CI bot | No AI line-level review; `kody-ai` reads `stale` (compulsory, Tier K — ADR 0058) | Every grind waits, then bails at `--max-wait` naming `kody-ai` (no ADR 0012 downgrade). Large PRs are slow (26 min on busdriver#800) and can use several wait-rounds | Check the `Kody Code Review` check-run and the Kodus dashboard (app installed, branch configured, file limit); on a merge-only HEAD comment `@kody review --force`; re-run pr-grind |
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
4. If still stuck after 30 min → skip that bot in this round, grind others — **except Kody**: it is compulsory (Tier K), so skipping it only leaves `kody-ai` stale. Inspect the `Kody Code Review` check-run and the Kodus dashboard instead, and let pr-grind bail at `--max-wait`

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

## Recovery checks after a degraded period

- Review `bypass-log.jsonl` entries from the degraded window — any bypasses that should be re-run now?
- Check `review-metrics.jsonl` for missing iterations — did any PRs merge without a proper review during the outage?
- Re-trigger any skipped external bots on the now-merged commits if possible (CodeScene accepts retroactive runs)

## Related references (in `~/.claude/notes/`)

- `reference_github_required_checks_pattern.md` — path-filtered checks trap + job-level skip fix
- `reference_github_pullrequest_event_blackhole.md` — PR event routing glitch diagnostic
- `reference-full-pipeline.md` — full pipeline diagram (LOCAL + CI + PR review + merge)
