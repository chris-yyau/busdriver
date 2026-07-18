# Busdriver Plugin

Unified workflow orchestrator for Claude Code. Consolidates pipeline process, domain tools, and enforcement gates into one plugin.

## Tech Stack

- **Language:** Shell (gate scripts, hooks), JavaScript (utility scripts), Markdown (skills, agents, rules, commands)
- **Runtime:** Claude Code plugin system — no build step, no compiled output
- **Package manager:** npm (devDependencies only — `ajv` for JSON schema validation; `vitest` + `@vitest/coverage-v8` for JS tests)
- **Linting:** ShellCheck for `hooks/gate-scripts/*.sh` and `scripts/hooks/*.sh`
- **Testing:** vitest for JS (`__tests__/`, v8 coverage), pytest for Python (federated per-skill via `uv`, run with `scripts/test-python.sh`), plus shell gate-tests in `tests/`
- **Commit format:** Conventional Commits enforced by commitlint (`@commitlint/config-conventional`)

## Project Structure

```
agents/          Agent definitions (.md) — specialized reviewers, builders, resolvers
commands/        Slash command entry points (.md) — user-invokable shortcuts to skills
hooks/
  hooks.json     Hook registration manifest (PreToolUse, PostToolUse, SessionStart, Stop)
  gate-scripts/  Shell scripts that enforce review gates (fail-CLOSED by default)
rules/           Hand-written rules canon installed to ~/.claude/rules/ (common/ only)
scripts/         JS/shell utilities — release, install, session management, health checks
__tests__/       JS unit tests (vitest) — smoke + gold-standard template
skills/          Skill definitions (.md) — the bulk of the plugin's capability (plus `supplements/` support dir)
                 Python tests live per-skill (e.g. skills/skill-comply/tests/, skills/continuous-learning-v2/scripts/)
tests/           Shell-based gate tests (test-*.sh)
docs/            Reference docs and examples
```

## Enforcement Gates (Hook-Driven)

Six gates enforced by PreToolUse hooks. All fail-CLOSED (block on error). Escape hatches use `.local` files.

| Gate | Hook Script | Blocks | Skip With |
|------|------------|--------|-----------|
| **Design review** | `check-design-document.sh` → `pre-implementation-gate.sh` | Write/Edit of impl files when design docs are unreviewed | `.claude/skip-design-review.local` |
| **Pre-commit (litmus)** | `pre-commit-gate.sh` | `git commit` until codex review passes | `.claude/skip-litmus.local` (gitignored, operator-created; the env-based `SKIP_LITMUS` escape was removed — #325 / ADR 0016 sanitizes gate env, so a committed `settings.json` can't inject it) |
| **Pre-PR** | `pre-pr-gate.sh` | `gh pr create` until litmus passes on full branch diff | `.claude/skip-litmus.local` (gitignored, operator-created — env-based skip removed, #325) |
| **Pre-merge (pr-grind)** | `pre-merge-gate.sh` | `gh pr merge` until pr-grind declares PR clean | `.claude/skip-pr-grind.local` (gitignored, operator-created — env-based skip removed, #325) |
| **Careful guard** | `careful-guard.sh` | Destructive Bash commands (rm -rf, git reset --hard, etc.) | Confirmation prompt |
| **Freeze guard** | `freeze-guard.sh` | Write/Edit outside scoped directory during debugging | Remove `.claude/freeze-scope.local` |

**Per-repo pr-grind opt-in files** (all gitignored `.local`; full semantics in the linked ADR / `skills/pr-grind/SKILL.md` flag table — read those before touching):

| File | One-line effect | Source of truth |
|------|-----------------|-----------------|
| `.claude/pr-grind-auto-admin-solo.local` | Solo-admin repos: `--admin-on-approver-gap` implicit, snapshot-anchored anti-self-bypass, self-revokes if a 2nd approver appears | `skills/pr-grind/SKILL.md` flag table |
| `.claude/pr-grind-codex-expected.local` | **Force-on cold-start override** for the Codex `none`-nudge. As of the 2026-07-11 ADR 0013 revision the DEFAULT trigger is history **auto-detection** (`scripts/codex-active-repo.sh`: recent Codex reviews/reactions) plus a non-gating missing-Codex warning at merge; this file only force-ons a repo with no history yet. Off switch stays `PR_GRIND_CODEX_RETRIGGER=0`. #327 marker GC bundled. | `docs/adr/0013-codex-none-nudge-opt-in.md` |
| `.claude/pr-grind-advisory-downgrade.local` **(per-repo file; to opt in many repos, drop the marker into each repo's `.claude/` as a plain untracked file — or run `scripts/enable-advisory-downgrade.py REPO...`, the hardened bulk enroller from #326: explicit paths only, openat+O_NOFOLLOW writes, resolver-delegated acceptance)** | At `--max-wait` exhaustion, may downgrade a 0-finding advisory bot's stale ack `stale→none`; never touches merge authority. Resolver `scripts/advisory-downgrade-optin.sh` (root derived purely from git/CWD — no env override; fail-CLOSED: accepts the marker only as a non-repo-controlled — not in index/HEAD, not gitlinked — non-symlink regular file; unresolvable/unqueryable repo ⇒ `0`/BAIL). **No global env-var / global-file switch by design** — both are repo-injectable (a committed `.claude/settings.json` `env` block sets env vars); consent stays operator-owned per-repo. See ADR + the 2026-07-10 (ultimate-)council | `docs/adr/0012-advisory-bot-stale-timeout-downgrade.md` |

## Version Sync

Version numbers are managed across three manifests (declared in `.version-bump.json`):

- `package.json` — `version` field
- `.claude-plugin/plugin.json` — `version` field
- `.claude-plugin/marketplace.json` — `version` field (inside `plugins[0]`)

**Automated (preferred):** semantic-release bumps all manifests via `@semantic-release/exec` → `bump-version.sh` on every merge to main. No manual version management needed.

**Manual escape hatch:** `./scripts/release.sh VERSION` for local releases.

**Drift detection:** `./scripts/bump-version.sh --check` runs in CI on PRs to catch version desync.

## CI Workflows (`.github/workflows/`)

| Workflow | Trigger | What it does |
|----------|---------|-------------|
| `tests.yml` | Push to main, PRs | ShellCheck linting, commitlint, version drift check, SBOM + Trivy (vuln + license); `coverage` job runs vitest + pytest and uploads to Codecov (upload step uses `continue-on-error`, so CI stays green when the `CODECOV_TOKEN` secret is absent, e.g. fork PRs) |
| `release.yml` | Push to main | semantic-release with `RELEASE_TOKEN` (environment-scoped secret) |
| `security.yml` | Schedule + PRs | Security scanning |
| `scorecard.yml` | Schedule | OpenSSF Scorecard |
| `pinact.yml` | Push to main (workflow changes) | Pin GitHub Actions to commit SHAs |
| `bypass-audit.yml` | Push to main | Detect direct-push bypasses; opens `admin-bypass` issues |

## Conventions

- **Skills are Markdown files** — each skill lives at `skills/<name>/SKILL.md`. No code compilation.
- **Agents are Markdown files** — each agent lives at `agents/<name>.md`.
- **Commands are shims** — most commands in `commands/` are one-line redirects to their backing skill.
- **Gate scripts read stdin** — hooks receive JSON via stdin, emit JSON decisions to stdout.
- **Fail-CLOSED philosophy** — all review gates block on error. "A stuck session is better than a skipped review."
- **`.local` files are gitignored** — escape hatches (skip-litmus, freeze-scope, design-review-needed) use `.local` suffix to stay out of version control.
- **Three test suites** — (1) vitest for JS (`__tests__/`, `npm test` / `npm run test:coverage`); (2) pytest for Python, organized **federated per-skill** (each island owns its imports — skill-comply is a self-contained `uv` project; a single root `pytest`/`pyproject.toml` would break its `pythonpath`), run via `scripts/test-python.sh`; (3) shell gate-tests in `tests/test-*.sh` run directly. New JS tests go in `__tests__/`; new Python tests go beside the skill they cover.
- **External plugins consumed, not vendored (SETTLED)** — `impeccable` (`pbakaus/impeccable`, Apache-2.0) is used as a **separately-installed Claude Code plugin**, intentionally NOT vendored into this repo: it ships runtime `.mjs` scripts, a PostToolUse hook, and an `npx impeccable` CLI that would break as loose markdown, and it self-updates. It is therefore absent from `.upstream-sources.json` by design. Design-skill routing is the **settled dual-engine** model (see `skills/orchestrator/tasks-catalog.md` + `domain-supplements.md`): `busdriver:design-taste-frontend` *explores* landing/marketing/portfolio/showcase → `impeccable:impeccable` *hardens* and owns dashboards/app-UI solo; `ui-ux-pro-max`/`design-system`/`frontend-design` are gap-fill (do NOT lead). Do not re-vendor impeccable or "consolidate" the design cluster — that decision is made.
- **Solo operator + provider chain (SETTLED — do not reopen as churn)** — this repo is public but **single-operator** (only the maintainer uses it). The arbiter chain is **`opus` (default) → optional "ultimate arbiter" escalation (USER opt-in, `.claude/busdriver.json` → `ultimate.surfaces.arbiter`)**, and the ultimate escalation is **subagent-only: `fable` Agent subagent → `opus` (degraded)**, exactly as documented in `skills/blueprint-review/SKILL.md` and ADR 0008/ADR 0011/ADR 0015/**ADR 0019** (ADR 0019: fable is in-plan and reliably reachable in-account via the Agent tool, so the never-exercised zenmux gateway rung was **deleted** — `scripts/ultimate-dispatch.sh` and `dispatch-gateway-arbiter.sh` are gone, and both ultimate surfaces — the arbiter and the council Mythos Witness — are subagent-only; `opus` remains the default arbiter; the `ultra*`/`ultimate*` naming split is a hard convention per ADR 0011, mixing them is a bug). The operator **never** uses cloud-provider selectors (`CLAUDE_CODE_USE_{BEDROCK,VERTEX,FOUNDRY,ANTHROPIC_AWS,MANTLE}`). **There is no gateway surface left to harden** — the credential-containment/provider-scrub layers went out with the scripts that carried them, so do **not** reintroduce a gateway transport, re-add provider scrubbing for providers that are never used, or re-litigate the hostile-arbiter threat model for solo use. Note the UltraOracle (`ultra*`, ChatGPT Pro) is a **separate** surface and still transmits externally — that boundary is untouched by ADR 0019.
- **Public repo** — `chris-yyau/busdriver` is public; you are the sole admin (only approval-capable human — forkers who open PRs are not). Merges are gated by required status checks + sole-admin access. **Solo-admin auto-escalation is enabled** (`.claude/pr-grind-auto-admin-solo.local`, gitignored) but **currently inert**: `main` has no required-review rule (deliberate solo-repo choice — `required_pull_request_reviews: null` since the helmet rollout; **always confirm this via the parent `gh api repos/OWNER/REPO/branches/main/protection` endpoint — the `/protection/required_pull_request_reviews` sub-endpoint phantom-reports `count: 1` even when unenforced and will manufacture a false approver gap**), so there is no approver gap for the opt-in to bridge. The real merge gate is the 8 required status checks with `strict` on (the `mergeStateStatus=BEHIND` enforcer) plus `enforce_admins=false`; an admin squash-merges (`--squash --delete-branch`), adding `--admin` only to clear a `BEHIND` head. The opt-in self-revokes if a second approval-capable human is ever added. Local tooling still preferred over remote CI for development workflow.
