# Busdriver Plugin

Unified workflow orchestrator for Claude Code. Consolidates pipeline process, domain tools, and enforcement gates into one plugin.

## Tech Stack

- **Language:** Shell (gate scripts, hooks), JavaScript (utility scripts), Markdown (skills, agents, rules, commands)
- **Runtime:** Claude Code plugin system — no build step, no compiled output
- **Package manager:** npm (devDependencies only — `ajv` for JSON schema validation)
- **Linting:** ShellCheck for `hooks/gate-scripts/*.sh` and `scripts/hooks/*.sh`
- **Commit format:** Conventional Commits enforced by commitlint (`@commitlint/config-conventional`)

## Project Structure

```
agents/          49 agent definitions (.md) — specialized reviewers, builders, resolvers
commands/        Slash command entry points (.md) — user-invokable shortcuts to skills
hooks/
  hooks.json     Hook registration manifest (PreToolUse, PostToolUse, SessionStart, Stop)
  gate-scripts/  Shell scripts that enforce review gates (fail-CLOSED by default)
rules/           Coding rules installed to ~/.claude/rules/ (common/ + 11 language dirs + zh/)
scripts/         JS/shell utilities — release, install, session management, health checks
skills/          206 skill definitions (.md) — the bulk of the plugin's capability (plus `supplements/` support dir)
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

**Related per-repo operator-consent file (NOT a gate, but lives alongside them):** `.claude/pr-grind-auto-admin-solo.local` (gitignored). When present AND the operator is structurally the sole human admin of the repo, pr-grind's approver-gap detector treats `--admin-on-approver-gap` as implicit — `gh pr merge --admin` runs without surfacing the operator-decision dialog. Same baseline gates as the flag (CI green, bots ack, author admin/maintain, `bypass-audit.yml` present). The opt-in self-revokes if a second human admin appears (assumption broken). **Anti-self-bypass (snapshot-anchored):** Step 0 of pr-grind snapshots the file's mtime to `.claude/.pr-grind-solo-opt-in-snapshot.local` only when the file is already ≥30s old at invocation start; Completion fires auto-merge only if snapshot exists AND its mtime matches the current file's mtime. Defeats the "touch at start of slow run, satisfy 30s by Completion" attack. Mid-run touch or replacement invalidates. Logged to `.claude/bypass-log.jsonl` with `event: pr-grind-admin-on-approver-gap-solo-admin-auto` for forensics. See `skills/pr-grind/SKILL.md` flag table.

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
| `tests.yml` | Push to main, PRs | ShellCheck linting, commitlint, version drift check, SBOM + Trivy (vuln + license) |
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
- **No test framework** — tests are standalone shell scripts in `tests/` run directly. No jest, vitest, or mocha.
- **Private repo** — no external collaborators on PRs. Local tooling preferred over remote CI for development workflow.
