# Pipeline Degraded Modes — Runbook

External service dependencies in the busdriver pipeline, what fails if each goes down, and the fallback for each. Consult when a CI check is stuck/absent or a review bot is silent.

## At a glance

| Service | Layer | If down | Impact | Fallback |
|---------|-------|---------|--------|----------|
| **Anthropic API** (Claude) | Local | Can't run Claude Code | Everything stops | Retry + Codex review backend |
| **OpenAI Codex CLI** | Local | Litmus commit review fails; Council Critic voice down | Commits blocked; council loses Critic (4-voice: Architect + Skeptic + Pragmatist + Researcher) | `BUSDRIVER_REVIEW_CLI=agy` or `=builtin`; council continues degraded, note in report |
| **Antigravity (agy) CLI** | Local | Council Pragmatist voice down; blueprint reviewer_1 falls back to droid | Council loses Pragmatist (4-voice: Architect + Skeptic + Critic + Researcher) | Continue degraded, note in report |
| **Droid CLI** | Local | Council Researcher voice down | Council loses Researcher (4-voice: Architect + Skeptic + Pragmatist + Critic) | Continue degraded, note in report |
| **GitHub Actions** | CI | Required checks don't run | PR merge blocked | `gh pr merge N --admin`, then audit via helmet's `bypass-audit.yml` workflow (if deployed) or manually record the bypass reason |
| **GitHub Apps (bots)** | CI | See per-app rows below | Varies | Detailed below |
| CodeRabbit | CI bot | No AI line-level review | No blocker — other reviewers cover | Continue; re-review by copilot + greptile + cubic |
| Greptile | CI bot | No codebase-aware review | Lose cross-file context signals | Copilot's cross-file awareness covers partially |
| Cubic | CI bot | No additional AI review | Low impact — 4 other reviewers | Continue |
| Copilot code review | CI bot | No GitHub-native review | Continue with other bots | |
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

1. Check the bot's own status page (CodeRabbit, Greptile, etc.)
2. `gh pr comments <N>` — did the bot post anything error-like?
3. Close + reopen PR to trigger re-registration
4. If still stuck after 30 min → skip that bot in this round, grind others

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
