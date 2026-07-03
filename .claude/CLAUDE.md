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
agents/          65 agent definitions (.md) — specialized reviewers, builders, resolvers
commands/        Slash command entry points (.md) — user-invokable shortcuts to skills
hooks/
  hooks.json     Hook registration manifest (PreToolUse, PostToolUse, SessionStart, Stop)
  gate-scripts/  Shell scripts that enforce review gates (fail-CLOSED by default)
rules/           Coding rules installed to ~/.claude/rules/ (common/ + 11 language dirs)
scripts/         JS/shell utilities — release, install, session management, health checks
__tests__/       JS unit tests (vitest) — smoke + gold-standard template
skills/          287 skill definitions (.md) — the bulk of the plugin's capability (plus `supplements/` support dir)
                 Python tests live per-skill (e.g. skills/skill-comply/tests/, skills/continuous-learning-v2/scripts/)
tests/           Shell-based gate tests (test-*.sh)
docs/            Reference docs and examples
```

## Enforcement Gates (Hook-Driven)

Six gates enforced by PreToolUse hooks. All fail-CLOSED (block on error). Escape hatches use `.local` files.

| Gate | Hook Script | Blocks | Skip With |
|------|------------|--------|-----------|
| **Design review** | `check-design-document.sh` → `pre-implementation-gate.sh` | Write/Edit of impl files when design docs are unreviewed | `.claude/skip-design-review.local` |
| **Pre-commit (litmus)** | `pre-commit-gate.sh` | `git commit` until codex review passes | `.claude/skip-litmus.local` (or `SKIP_LITMUS=1` exported in parent shell before `claude` starts — inline `SKIP_LITMUS=1 git commit` does NOT work, hooks fire before the command's env is applied) |
| **Pre-PR** | `pre-pr-gate.sh` | `gh pr create` until litmus passes on full branch diff | `.claude/skip-litmus.local` (or `SKIP_LITMUS=1` in parent shell — same caveat as pre-commit) |
| **Pre-merge (pr-grind)** | `pre-merge-gate.sh` | `gh pr merge` until pr-grind declares PR clean | `.claude/skip-pr-grind.local` (or `SKIP_PR_GRIND=1` in parent shell — same caveat as pre-commit) |
| **Careful guard** | `careful-guard.sh` | Destructive Bash commands (rm -rf, git reset --hard, etc.) | Confirmation prompt |
| **Freeze guard** | `freeze-guard.sh` | Write/Edit outside scoped directory during debugging | Remove `.claude/freeze-scope.local` |

**Related per-repo operator-consent file (NOT a gate, but lives alongside them):** `.claude/pr-grind-auto-admin-solo.local` (gitignored). When present AND the operator is structurally the sole human with **PR-approval capability** (write/maintain/admin — `permissions.push==true`) on the repo, pr-grind's approver-gap detector treats `--admin-on-approver-gap` as implicit. Same baseline gates as the flag (CI green, bots ack, author admin/maintain, `bypass-audit.yml` present). The opt-in self-revokes if a second approval-capable human appears (assumption broken) — a contractor with write permission alone is enough to invalidate it. **Anti-self-bypass (snapshot-anchored, per-PR, three conditions):** Step 0 of pr-grind snapshots the file's mtime to `.claude/.pr-grind-solo-opt-in-snapshot-<PR>.local` (0600) only when the file is already ≥30s old at invocation start; Completion fires auto-merge only if (1) the per-PR snapshot exists, (2) the snapshot's recorded mtime equals the opt-in file's current mtime, AND (3) the snapshot file's own filesystem mtime is ≥30s after the opt-in file's mtime (defeats a same-NOW forge where an attacker creates both files in one action). Per-PR scoping prevents concurrent pr-grind runs on different PRs from racing on shared state. Mid-run touch or replacement invalidates. Logged to `.claude/bypass-log.jsonl` with `event: pr-grind-admin-on-approver-gap-solo-admin-auto` for forensics. See `skills/pr-grind/SKILL.md` flag table.

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
- **Solo operator + provider chain (SETTLED — do not reopen as churn)** — this repo is public but **single-operator** (only the maintainer uses it). The arbiter chain is **`opus` (default) → optional "ultimate arbiter" escalation (USER opt-in, `.claude/busdriver.json` → `ultimate.surfaces.arbiter`) → zenmux (gateway) fable**, exactly as documented in `skills/blueprint-review/SKILL.md` and ADR 0008/ADR 0011 (`fable` dropped from the subscription plan; `opus` is the default arbiter, gateway-fable is now an opt-in "ultimate" escalation — the `ultra*`/`ultimate*` naming split is a hard convention per ADR 0011, mixing them is a bug). The operator **never** uses cloud-provider selectors (`CLAUDE_CODE_USE_{BEDROCK,VERTEX,FOUNDRY,ANTHROPIC_AWS,MANTLE}`). The gateway/provider-scrub hardening is **considered done** — treat that surface as frozen and do **not** spend further effort scrubbing providers that are never used or re-litigating the hostile-arbiter threat model for solo use. (The existing credential-containment layers stay as-is — they still protect the operator's own key — but no new provider-scrub work is warranted absent a real second user/threat.)
- **Public repo** — `chris-yyau/busdriver` is public; you are the sole admin (only approval-capable human — forkers who open PRs are not). Merges are gated by required status checks + sole-admin access. **Solo-admin auto-escalation is enabled** (`.claude/pr-grind-auto-admin-solo.local`, gitignored) but **currently inert**: `main` has no required-review rule (deliberate solo-repo choice — `required_pull_request_reviews: null` since the helmet rollout; **always confirm this via the parent `gh api repos/OWNER/REPO/branches/main/protection` endpoint — the `/protection/required_pull_request_reviews` sub-endpoint phantom-reports `count: 1` even when unenforced and will manufacture a false approver gap**), so there is no approver gap for the opt-in to bridge. The real merge gate is the 8 required status checks with `strict` on (the `mergeStateStatus=BEHIND` enforcer) plus `enforce_admins=false`; an admin squash-merges (`--squash --delete-branch`), adding `--admin` only to clear a `BEHIND` head. The opt-in self-revokes if a second approval-capable human is ever added. Local tooling still preferred over remote CI for development workflow.
