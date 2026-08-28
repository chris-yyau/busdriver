# Busdriver

[![CI](https://github.com/chris-yyau/busdriver/actions/workflows/tests.yml/badge.svg)](https://github.com/chris-yyau/busdriver/actions/workflows/tests.yml)
[![Security](https://github.com/chris-yyau/busdriver/actions/workflows/security.yml/badge.svg)](https://github.com/chris-yyau/busdriver/actions/workflows/security.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/chris-yyau/busdriver/badge)](https://scorecard.dev/viewer/?uri=github.com/chris-yyau/busdriver)

The adult supervision your AI coding agent didn't ask for but desperately needs.

Busdriver is a [Claude Code plugin](https://docs.anthropic.com/en/docs/claude-code/plugins) that turns process into enforcement. It carries a 6-phase development pipeline, the review and dispatch orchestration around it, and a set of hook-backed gates that block the tool call itself. Claude literally cannot talk its way out of it.

Think of it as the designated driver for your codebase — it won't let Claude leave the bar until the code review passes.

## What it does

| Phase | What happens |
|-------|-------------|
| **1. Brainstorming** | Explore intent, requirements, and design before writing code |
| **2. Planning** | Produce task lists with file paths, commands, expected output |
| **3. Worktree** | Create isolated git worktree, verify baseline tests pass |
| **4. Execution** | Tests (TDD ordering advisory, opt-in via `/tdd`), code review, reviewer dispatch |
| **5. Verification** | Build + lint + tests, security scan, specialist review agents |
| **6. Finishing** | Commit (litmus-reviewed), PR or merge, worktree cleanup |

Small, specific tasks (bug fix, typo, config tweak) skip straight to Phase 4. Everything else goes through the full pipeline.

## Gates

Six blocking gates plus one advisory guard, all hook-enforced. The six emit `{"decision":"block"}` from a PreToolUse hook, so the harness rejects the tool call — Claude cannot rationalize its way past them — and they fail **closed**: a gate that errors blocks rather than waving the operation through.

Careful guard is the deliberate exception. It emits `permissionDecision: ask` to raise a confirmation prompt rather than blocking, and it fails **open** on internal error, so a bug in it cannot wedge every Bash call in the session.

| Gate | Trigger | What it blocks |
|------|---------|---------------|
| **Litmus (commit)** | `git commit` | Blocks the commit until code review passes |
| **Litmus (PR)** | `gh pr create` | Blocks the PR until a Codex deep multi-lens pass **and** an independent read-only Opus Security/Bugs backstop both pass. The PR marker is refused without a fresh PASS backstop artifact matching `base...HEAD` |
| **Blueprint review** | Plan/design doc written | Blocks implementation code while plans are unreviewed |
| **Pre-implementation** | `Write`/`Edit` of code files | Blocks writes while design docs lack `<!-- design-reviewed: PASS -->` |
| **Pre-merge** | `gh pr merge` | Blocks the merge until pr-grind declares the PR clean at its live HEAD |
| **Careful guard** | Destructive Bash (`rm -rf`, `git reset --hard`, …) | Raises a confirmation prompt |
| **Freeze guard** | `.claude/freeze-scope.local` present | Restricts edits to the investigation scope during debugging |

### Escape hatches

The three review gates take a skip file. Each is gitignored and meant to be created by the operator, in their own terminal:

```bash
touch .claude/skip-litmus.local          # commit + PR review — single-use
touch .claude/skip-design-review.local   # pre-implementation — lease: 20 writes / 1h
touch .claude/skip-pr-grind.local        # pre-merge — deferred; see docs/observability.md
```

Consumption is logged to `.claude/bypass-log.jsonl`, with two caveats worth knowing. The litmus paths append `skip-review-consumed` with `|| true`, so a failed write does not stop the bypass — logging there is best-effort. And careful guard confirmations and freeze-guard deactivations emit no event at all. The log records skip-file and merge-authorization activity, not every gate execution.

A file younger than 30 seconds is rejected. That is a **timing heuristic, not an authentication boundary** — it raises the cost of an agent arming its own bypass inside a single turn, but nothing here proves a human created the file, and `skip-pr-grind.local` is not among the paths `marker_check.py` protects from agent writes. Detection, not prevention.

The old environment-variable bypasses (`SKIP_LITMUS`, …) were removed in [#325](https://github.com/chris-yyau/busdriver/pull/325) / ADR 0016: a committed `settings.json` `env` block is merged into the session, which made env-based skips a PR-injectable bypass lever. Gate env is now sanitized.

Full consumption semantics, the audit event taxonomy, and the per-repo opt-in files are in **[docs/observability.md](docs/observability.md)**.

## Reviewers and agents

40 agents and 38 skills ship with the plugin. Language pattern libraries and framework guides do not — the model covers those (ADR 0048). What remains per domain is the reviewer or build-resolver the pipeline dispatches:

| Domain | Reviewer | Build resolver |
|--------|----------|---------------|
| Python / FastAPI | `python-reviewer`, `fastapi-reviewer` | -- |
| TypeScript / JS | `typescript-reviewer` | `build-error-resolver` |
| React / Next.js | `react-reviewer` | `react-build-resolver` |
| Database / SQL | `database-reviewer` | -- |
| Security-sensitive changes | `security-reviewer` | -- |

Plus architect, planner, TDD guide, silent-failure hunter, type-design analyzer, and a 5-voice council for ambiguous decisions. They argue with each other so you don't have to. See `agents/` and `skills/` for the full inventory.

## Install

```bash
claude plugin marketplace add github:chris-yyau/busdriver
claude plugin install busdriver@busdriver
```

**Requires [Claude Code](https://docs.anthropic.com/en/docs/claude-code)** as the host harness. OpenCode is *not* supported — the `opencode/` port was removed in [#251](https://github.com/chris-yyau/busdriver/pull/251) and must not be restored. The `opencode` CLI survives only as an optional review backend.

## Review CLI

Set `BUSDRIVER_REVIEW_CLI` to choose your review backend:

| Value | Behavior |
|-------|----------|
| `auto` (default) | Detects: codex > agy > droid > built-in agent fallback |
| `codex` | OpenAI Codex CLI (`npm install -g @openai/codex`) |
| `agy` | Google Antigravity (`agy`) CLI — successor to the Gemini CLI |
| `droid` | Droid CLI |
| `builtin` | Built-in code-reviewer agent (always available, less independent) |
| `none` | Disable the review gate (logs a warning on every commit) |

**Without any external CLI:** auto-detection falls back to the built-in code-reviewer agent. Commits are still reviewed, but by the same model that wrote the code — less independent. Run `node scripts/doctor.js` to see your effective reviewer.

### Optional CLIs

| CLI | Used by | Install |
|-----|---------|---------|
| **[Codex](https://github.com/openai/codex)** | Review gate (default), blueprint review, council | `npm install -g @openai/codex` |
| **[Antigravity (agy)](https://antigravity.google/docs/cli/)** | Blueprint review, council, code review, `agy-read` dispatch lane | See the linked docs |
| **Grok (xAI Grok Build)** | Council Researcher (default) | See xAI Grok Build docs |
| **[Droid](https://droid.dev)** | Council Researcher fallback, pragmatist/critic fallback, any configurable role | See https://droid.dev |

### Per-role routing (optional)

By default every feature shares one CLI. For per-role control, create `.claude/busdriver.json`:

```json
{
  "version": 1,
  "defaults": { "primary": "auto", "fallback": "builtin" },
  "routes": {
    "blueprint-review.reviewer_1": ["agy", "droid"],
    "blueprint-review.reviewer_2": ["codex", "droid"],
    "council.pragmatist": ["agy", "droid"],
    "council.critic": ["codex", "droid"],
    "council.researcher": ["grok", "droid"]
  }
}
```

Each route is an ordered fallback chain — first element primary, later elements tried if the primary is missing. Roles not listed inherit from `defaults`. User-level defaults go in `~/.claude/busdriver.json`.

**Precedence:** env var > project config > user config > defaults > auto-detect

| Feature | Role | Config key | Default |
|---------|------|-----------|---------|
| Code review | Reviewer | `litmus.reviewer` | auto |
| Blueprint review | Reviewer 1 | `blueprint-review.reviewer_1` | agy |
| Blueprint review | Reviewer 2 | `blueprint-review.reviewer_2` | codex |
| Council | Pragmatist | `council.pragmatist` | agy |
| Council | Critic | `council.critic` | codex |
| Council | Researcher | `council.researcher` | grok (fallback: droid) |

Council architect, skeptic, and the design-review arbiter are not configurable — they use Claude's Agent tool.

For council, fallback preserves availability but dilutes role identity (Droid filling in as Pragmatist is no longer "Agy's strategic lens"). Append `"none"` as the terminal entry — `["agy", "none"]` — to keep the lens pure and let the voice drop instead. Architect always runs in-context and Skeptic usually runs, so the council normally convenes with two or more voices even with no external CLIs installed — the second voice is guaranteed only when the Skeptic dispatch succeeds. The core commit pipeline always works.

> **Migration note:** `roundtable.pragmatist` / `roundtable.critic` were renamed to `council.*`. Old keys are silently ignored.

## Utility scripts

| Script | Purpose |
|--------|---------|
| `node scripts/doctor.js` | Diagnose CLI availability and the effective reviewer for each role |
| `scripts/design-clear.sh` | Release a pending design-review token with a durable audit event |
| `scripts/litmus-metrics-report.sh` | Dashboard for litmus outcomes (pass rate, severity, trends) |
| `scripts/release.sh VERSION` | Bump version across manifests, changelog, tag, push |
| `scripts/bump-version.sh --check` | Version drift detection (also runs in CI) |
| `scripts/generate-changelog.sh` | Generate CHANGELOG.md from conventional commits |
| `scripts/post-ship-doc-check.sh` | Flag stale docs after code changes |

## Learning system

- **Instincts** — patterns observed from sessions, promoted after human review
- **Council** — 5-voice analysis (Architect, Skeptic, Pragmatist, Critic, Researcher)
- **Lesson capture** — when review finds HIGH+ issues the plan missed, the lesson is saved automatically
- **Reflection** — `/reflect` for capturing corrections by hand

## Credits

Busdriver is built on two upstream projects, and still carries their code directly — 320 files at last count, tracked file-by-file in `.upstream-sources.json` and kept current by the `sync-upstream` tooling:

- **[Superpowers](https://github.com/obra/superpowers)** (MIT) by Jesse Vincent — the pipeline backbone: brainstorming, planning, systematic debugging, worktrees, verification, skill authoring
- **[Everything Claude Code](https://github.com/affaan-m/everything-claude-code)** (MIT) by Affaan Mustafa — agents, commands, hooks, session and install tooling

Smaller borrowings are credited in the files that carry them: `careful-guard.sh` names its gstack ([garrytan/gstack](https://github.com/garrytan/gstack), MIT) origin in its header, and each supplement in `skills/supplements/` records its source in frontmatter.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

See [SECURITY.md](SECURITY.md).

## License

MIT — see [LICENSE](LICENSE).
