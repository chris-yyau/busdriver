# Pipeline Degraded Modes — Runbook

External service dependencies in the busdriver pipeline, what fails if each goes down, and the fallback for each. Consult when a CI check is stuck/absent or a review bot is silent.

## At a glance

| Service | Layer | If down | Impact | Fallback |
|---------|-------|---------|--------|----------|
| **Anthropic API** (Claude) | Local | Can't run Claude Code | Everything stops | Retry + Codex review backend |
| **OpenAI Codex CLI** | Local | Litmus commit review fails; Council Critic voice down | Commits blocked; council loses Critic (4-voice: Architect + Skeptic + Pragmatist + Researcher) | Falls back to the built-in review (exit 3); PR mode fails closed. Or set `BUSDRIVER_REVIEW_CLI=agy` / `=builtin`; council continues degraded, note in report |
| **Antigravity (agy) CLI** | Local | Council Pragmatist voice down; blueprint reviewer_1 falls through to auto-detect and typically collapses into DUPLICATE_MODE (coverage DEGRADED, PASS withheld) | Council loses Pragmatist (4-voice: Architect + Skeptic + Critic + Researcher) | Continue degraded, note in report |
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

Exception (ADR 0064): on a PR opened by the Cursor App bot, Kody's `skipped` run titled `Code Review Skipped` with summary `User Not Licensed — Assign seat to user` reads `skipped-unlicensed`. That is a waiver, not an ack, and it applies only while every Tier K veto holds, including no Kody "could not be posted" comment anywhere on the PR and an exact full-HEAD match. The waiver does not carry across an amend: until Kody posts its own run on the new HEAD, `kody-ai` reads `stale`. If no run appears, comment `@kody review --force`.

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

## What NOT to do on degraded state

- **Don't `--no-verify` to bypass local hooks** — they catch secrets, not just code quality. Secrets exposure is permanent.
- **Don't disable branch protection** — even temporarily. The CI issue is external; disabling protection is permanent in git history.
- **Don't mark a check as "not required" to unblock merge** — re-check after the external service recovers is harder than waiting.
- **Don't skip litmus repeatedly without documenting why** — `bypass-log.jsonl` is the audit; untagged bypasses accumulate as tech debt.

## Recovery checks after a degraded period

- Review `bypass-log.jsonl` entries from the degraded window — any bypasses that should be re-run now?
- Check `review-metrics.jsonl` for missing iterations — did any PRs merge without a proper review during the outage?
- Re-trigger any skipped external bots on the now-merged commits if possible (CodeScene accepts retroactive runs)

## Related references (in `~/.claude/notes/`)

- `reference_github_required_checks_pattern.md` — path-filtered checks trap + job-level skip fix
- `reference_github_pullrequest_event_blackhole.md` — PR event routing glitch diagnostic
- `reference-full-pipeline.md` — full pipeline diagram (LOCAL + CI + PR review + merge)
