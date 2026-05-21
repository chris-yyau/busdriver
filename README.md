# Busdriver

[![CI](https://github.com/chris-yyau/busdriver/actions/workflows/tests.yml/badge.svg)](https://github.com/chris-yyau/busdriver/actions/workflows/tests.yml)
[![Security](https://github.com/chris-yyau/busdriver/actions/workflows/security.yml/badge.svg)](https://github.com/chris-yyau/busdriver/actions/workflows/security.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/chris-yyau/busdriver/badge)](https://scorecard.dev/viewer/?uri=github.com/chris-yyau/busdriver)

The adult supervision your AI coding agent didn't ask for but desperately needs.

Busdriver is a [Claude Code plugin](https://docs.anthropic.com/en/docs/claude-code/plugins) that consolidates pipeline process (brainstorming, planning, TDD, verification), domain tools (language patterns, reviewers, build resolvers), and enforcement gates (code review, design review) into one unified workflow orchestrator. Claude literally cannot talk its way out of it.

Think of it as the designated driver for your codebase — it won't let Claude leave the bar until the code review passes.

## What it does

Busdriver enforces a 6-phase development pipeline and gates every commit and PR with automated review:

| Phase | What happens |
|-------|-------------|
| **1. Brainstorming** | Explore intent, requirements, and design before writing code |
| **2. Planning** | Produce TDD task lists with file paths, commands, expected output |
| **3. Worktree** | Create isolated git worktree, verify baseline tests pass |
| **4. Execution** | TDD (red/green/refactor), code review, language-specific patterns |
| **5. Verification** | Build + lint + tests, security scan, specialist review agents |
| **6. Finishing** | Commit (litmus-reviewed), PR or merge, worktree cleanup |

Small, specific tasks (bug fix, typo, config tweak) skip straight to Phase 4. Everything else goes through the full pipeline.

### Gates (hook-enforced, cannot bypass)

| Gate | Trigger | What it blocks |
|------|---------|---------------|
| **Litmus** | `git commit` | Blocks commit until code review passes |
| **Litmus (deep)** | `gh pr create` | Blocks PR until 6 parallel review agents pass weighted quorum (score ≥ 7/12, Bugs+Security required) |
| **Blueprint Review** | Plan/design doc written | Blocks implementation code while plans are unreviewed |
| **Pre-implementation** | `Write`/`Edit` of code files | Blocks file writes while design docs lack `<!-- design-reviewed: PASS -->` |
| **Freeze/Guard** | Debugging session active | Restricts edits to investigation scope only |

Gates emit `{"decision":"block"}` via PreToolUse hooks. The harness rejects the tool call — Claude cannot rationalize its way past these.

### 15 languages and frameworks

| Language | Patterns | Testing | Reviewer | Build Resolver |
|----------|----------|---------|----------|---------------|
| Go | `golang-patterns` | `golang-testing` | `go-reviewer` | `go-build-resolver` |
| Python | `python-patterns` | `python-testing` | `python-reviewer` | -- |
| Rust | `rust-patterns` | `rust-testing` | `rust-reviewer` | `rust-build-resolver` |
| TypeScript/JS | `coding-standards` | `tdd-guide` | `typescript-reviewer` | `build-error-resolver` |
| Swift | `swiftui-patterns` | -- | -- | -- |
| Kotlin | `kotlin-patterns` | `kotlin-testing` | `kotlin-reviewer` | `kotlin-build-resolver` |
| C++ | `cpp-coding-standards` | `cpp-testing` | `cpp-reviewer` | `cpp-build-resolver` |
| Java | `java-coding-standards` | `springboot-tdd` | `java-reviewer` | `java-build-resolver` |
| Perl | `perl-patterns` | `perl-testing` | -- | -- |
| Flutter/Dart | `flutter-dart-code-review` | -- | `flutter-reviewer` | -- |
| Django | `django-patterns` | `django-tdd` | -- | -- |
| Spring Boot | `springboot-patterns` | `springboot-tdd` | -- | -- |
| Laravel | `laravel-patterns` | `laravel-tdd` | -- | -- |
| Nuxt | `nuxt4-patterns` | -- | -- | -- |
| PyTorch | `pytorch-patterns` | -- | -- | `pytorch-build-resolver` |

### 49 specialized agents

Architect, planner, TDD guide, security reviewer, 9 language-specific reviewers, 8 build resolvers, council (5-voice multi-perspective analysis), and more. They argue with each other so you don't have to.

### 206 skills, 80 commands

From brainstorming and planning to domain patterns, deployment workflows, supply chain management, and AI/LLM pipeline optimization. See `skills/` for the full inventory.

## Requirements

- **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)** — the host harness (required)

### Review CLI (configurable)

Set `BUSDRIVER_REVIEW_CLI` to choose your review backend:

| Value | Behavior |
|-------|----------|
| `auto` (default) | Detects: codex > agy > droid > built-in agent fallback |
| `codex` | OpenAI Codex CLI (`npm install -g @openai/codex`) |
| `agy` | Google Antigravity (`agy`) CLI — successor to the Gemini CLI |
| `droid` | Droid CLI |
| `builtin` | Built-in code-reviewer agent (always available, less independent) |
| `none` | Disable review gate (logs warning on every commit) |

**Without any external CLI:** Auto-detection falls back to the built-in code-reviewer agent. All commits are still reviewed, but by the same model that wrote the code (less independent). Run `node scripts/doctor.js` to see your effective reviewer.

### Per-role routing (optional)

By default, all features share the same CLI. For per-role control, create `.claude/busdriver.json`:

```json
{
  "version": 1,
  "defaults": { "primary": "auto", "fallback": "builtin" },
  "routes": {
    "blueprint-review.reviewer_1": ["agy", "droid"],
    "blueprint-review.reviewer_2": ["codex", "droid"],
    "council.pragmatist": ["agy", "droid"],
    "council.critic": ["codex", "droid"],
    "council.researcher": ["droid"]
  }
}
```

Each route is an array — an ordered fallback chain (first element primary, later elements tried if primary is missing). Applies uniformly across `blueprint-review`, `litmus`, and `council` roles. For council, fallback preserves availability but dilutes role identity (e.g., Droid filling in as Pragmatist is no longer "Agy's strategic lens") — accept the trade-off when resilience matters more than signal purity, or append `"none"` as the terminal entry (e.g., `["agy", "none"]`) to keep the lens pure and let the voice drop when the primary is missing. Roles not listed inherit from `defaults` (which themselves chain to droid for council pragmatist/critic), so a bare single-element array like `["agy"]` will still fall back via the role's default chain. User-level defaults go in `~/.claude/busdriver.json`.

> **Migration note:** If your `busdriver.json` contains `roundtable.pragmatist` or `roundtable.critic` keys, rename them to `council.pragmatist` and `council.critic` respectively. Old keys are silently ignored.

**Precedence:** env var > project config > user config > defaults > auto-detect

| Feature | Role | Config key | Default |
|---------|------|-----------|---------|
| Code review | Reviewer | `litmus.reviewer` | auto |
| Blueprint review | Reviewer 1 | `blueprint-review.reviewer_1` | agy |
| Blueprint review | Reviewer 2 | `blueprint-review.reviewer_2` | codex |
| Council | Pragmatist | `council.pragmatist` | agy |
| Council | Critic | `council.critic` | codex |
| Council | Researcher | `council.researcher` | droid |

Council architect, skeptic, and design-review arbiter are not configurable (they use Claude's Agent tool).

Run `node scripts/doctor.js` to see your effective CLI for each role.

### Optional CLIs for multi-model features

| CLI | Used by | Install |
|-----|---------|---------|
| **[Codex CLI](https://github.com/openai/codex)** | Code review gate (default), blueprint review, council | `npm install -g @openai/codex` |
| **[Antigravity (agy) CLI](https://antigravity.google/docs/cli/)** | Blueprint review, council, code review | See https://antigravity.google/docs/cli/ |
| **[Droid](https://droid.dev)** | Council Researcher (default), pragmatist/critic fallback, any configurable role | See https://droid.dev |

**Without external CLIs:** The code review gate falls back to the built-in code-reviewer agent. Blueprint-review's *legacy defaults* (no `busdriver.json` present) try `agy` for reviewer_1 and `codex` for reviewer_2 first; if those are missing, the resolver falls through to Step 5 auto-detect (codex > agy > droid), so droid CAN serve as a final fallback even without a `busdriver.json`. The example config above adds explicit `droid` fallback in the route array — that's the faster path (avoids the auto-detect loop) and the recommended pattern. The council's *legacy defaults* DO chain explicitly to droid for pragmatist/critic (`agy → droid`, `codex → droid`); this trade-off is documented in `skills/council/SKILL.md` and can be opted out of with `["agy", "none"]` route arrays. Researcher always tries droid only. Architect (in-context Claude) always runs, and Skeptic (Agent tool) typically runs, so the council usually convenes with at least 2 voices (40% of full strength) even if all external CLIs are missing; if Skeptic is unavailable (rate limit/timeout), it can run with Architect alone. Core commit pipeline always works.

## Install

```bash
claude plugin marketplace add github:chris-yyau/busdriver
claude plugin install busdriver@busdriver
```

## How it works

Busdriver registers [PreToolUse and PostToolUse hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) that intercept tool calls at the harness level. The orchestrator skill routes every task to the correct pipeline phase and domain tools.

### Architecture

```
Claude Code                        Busdriver Plugin
───────────                        ────────────────

  User task ──► Orchestrator routes to pipeline phase
                    │
                    ├─► Phase 1-2: brainstorming / writing-plans
                    │     └─► Blueprint Review gates plan docs
                    │
                    ├─► Phase 3: git worktree isolation
                    │
                    ├─► Phase 4: TDD + domain skills + code review
                    │     ├─► Language patterns loaded by detection
                    │     ├─► tdd-guide agent enforces red/green/refactor
                    │     └─► {lang}-reviewer agent reviews every task
                    │
                    ├─► Phase 5: verification loop
                    │     ├─► build + lint + tests
                    │     └─► security-reviewer if auth/input/API touched
                    │
                    └─► Phase 6: finishing
                          ├─► git commit ──► Litmus (fast)
                          └─► gh pr create ──► Litmus (deep, 6 agents)

  Gate hooks (PreToolUse):
    ├── pre-commit gate ──► blocks until litmus review passes
    ├── pre-PR gate ──► blocks until deep review passes
    ├── pre-implementation gate ──► blocks code while plans unreviewed
    └── freeze/guard ──► restricts edits during debugging

  PostToolUse hooks:
    ├── design doc detector ──► flags docs for review
    ├── go post-edit ──► gofmt/goimports/go vet
    └── post-commit cleanup ──► consumes review markers
```

### Skip / bypass

Gates have escape hatches for when you need them:

```bash
# Skip litmus review — pre-commit + pre-PR (single-use, 30s self-bypass detection)
touch .claude/skip-litmus.local

# Skip design review — pre-implementation (single-use, 30s self-bypass detection)
touch .claude/skip-design-review.local

# Skip pr-grind — pre-merge (DEFERRED consumption: file is preserved if
# `gh pr merge` fails, --auto queues, or output is ambiguous; consumed only
# on confirmed merge success. The 1h expiry is anchored to the original
# touch (the 3600s clock does NOT reset on a failed-merge release). 30s
# self-bypass detection still applies.)
# Note: use an EXPLICIT PR number (`gh pr merge 42`) — the auto-detect
# path `gh pr merge` with no PR records `merge_pr=unknown`. The merge
# still proceeds (the gate already authorized it), but confirmation
# refuses to consume the bypass token: the audit log will show
# `skip-pr-grind-released-mismatch` instead of `-consumed`, and the skip
# file remains valid until 1h after the original touch.
touch .claude/skip-pr-grind.local

# Environment variable bypass — must be exported in the parent shell BEFORE
# starting `claude`. Inline `SKIP_LITMUS=1 git commit` does NOT work because
# PreToolUse hooks fire before the command's inline env is applied.
export SKIP_LITMUS=1
export SKIP_DESIGN_REVIEW=1
export SKIP_PR_GRIND=1
```

Skip files for litmus and design-review are single-use (consumed after one bypass). `skip-pr-grind.local` uses deferred consumption — it is preserved when `gh pr merge` fails, `--auto` queues without merging, or output is ambiguous, and is consumed only on confirmed merge success. All bypasses log to `.claude/bypass-log.jsonl`. Files created within 30 seconds are rejected — this prevents Claude from creating skip files itself to bypass gates.

## Utility scripts

| Script | Purpose |
|--------|---------|
| `scripts/release.sh VERSION` | Bump version across manifests, generate changelog, tag, and push |
| `scripts/bump-version.sh VERSION` | Config-driven version bump with drift detection and repo audit |
| `scripts/generate-changelog.sh` | Generate CHANGELOG.md from conventional commits (`--full`, `--dry-run`) |
| `scripts/post-ship-doc-check.sh` | Check for stale docs after code changes (6 heuristic rules) |
| `scripts/litmus-metrics-report.sh` | Dashboard for litmus review outcomes (pass rate, severity, trends) |
| `node scripts/doctor.js` | Diagnose CLI availability and effective reviewer configuration |

## Observability

Every gate execution writes to a persistent JSONL log per project, so you can answer questions like *"what's litmus's pass rate?"* or *"how often do I bypass and why?"* without digging through session history.

| File (per project) | Who writes | What it captures |
|--------------------|-----------|------------------|
| `.claude/review-metrics.jsonl` | litmus | Review outcome (PASS/FAIL), issue count, severity breakdown, iteration, CLI used, mode, commit SHA, branch, diff size |
| `.claude/bypass-log.jsonl` | litmus + busdriver gates (+ seatbelt plugin if installed) | Skip-file consumptions + selected telemetry events (see taxonomy below). **Not logged:** env-var bypasses (`SKIP_LITMUS=1`, `SKIP_PR_GRIND=1`) exit without logging — only file-based skips are audited |

**Event types written to `bypass-log.jsonl`:**

| Event | Source | Meaning |
|-------|--------|---------|
| `skip-review-consumed` | pre-commit / pre-pr / pre-implementation gate | User-created `skip-litmus.local` or `skip-design-review.local` was consumed |
| `skip-pr-grind-claimed` | pre-merge gate (PreToolUse) | User-created `skip-pr-grind.local` was approved for one `gh pr merge`; a `.merge-bypass-pending.local` claim was written. (Cutover note: prior to v1.41.x, the consumed event was logged here with `gate:"pre-merge"`; from v1.41.x onward `skip-pr-grind-consumed` is logged at PostToolUse with `gate:"post-merge"`.) |
| `skip-pr-grind-consumed` | post-merge cleanup hook (PostToolUse) | `gh pr merge` confirmed-succeeded (matched explicit `Squashed and merged` / `Merged pull request` patterns AND tamper checks passed) — the claim was honored and the skip file was deleted |
| `skip-pr-grind-released` | post-merge cleanup hook (PostToolUse) | `gh pr merge` failed; the claim was discarded and the skip file was preserved for retry |
| `skip-pr-grind-released-auto-queued` | post-merge cleanup hook (PostToolUse) | `gh pr merge --auto` enabled auto-merge but the PR was not actually merged yet (CI still pending). Skip file is preserved so a future explicit merge can re-grab it |
| `skip-pr-grind-released-ambiguous` | post-merge cleanup hook (PostToolUse) | Tool output matched neither success nor failure pattern; fail-safe: skip file preserved |
| `skip-pr-grind-released-tampered` | post-merge cleanup hook (PostToolUse) | The skip file disappeared, its mtime changed between claim and confirm, or it was younger than 30s at confirmation. Anti-self-bypass re-applied at consumption; skip file preserved (or absent, in the deleted case) |
| `skip-pr-grind-released-mismatch` | post-merge cleanup hook (PostToolUse) | The PR number parsed from the bash command did not match the PR number recorded in the pending claim, OR either side could not be concretely identified (the auto-detect path where `gh pr merge` runs without an explicit PR number records `merge_pr=unknown` and is refused at confirmation time to prevent cross-PR token reuse via branch-switching between claim and confirm). Skip file preserved |
| `skip-pr-grind-released-malformed` | post-merge cleanup hook (PostToolUse) | Pending claim file failed structural validation (non-numeric mtime, malformed PR number). Skip file preserved |
| `merge-bypass-stale-cleanup` | post-merge cleanup hook (PostToolUse) | A pending claim older than 5 minutes was force-cleaned via an unrelated Bash call (session crash recovery). Skip file preserved |
| `review-skipped-none` | pre-commit gate | Gate skipped because no review tool was active (BUSDRIVER_REVIEW_CLI=none) |
| `narrative-fallback-triggered` | litmus CLI | Review CLI output was non-JSON; parsed as narrative fallback |
| `schema-violation` | litmus schema validator | Review output didn't match expected JSON schema |
| `short-circuit-pass` | litmus commit mode | Diff met all short-circuit criteria; Codex skipped |
| `pr-fast-bypass` | litmus PR mode | `LITMUS_PR_FAST=1` skipped multi-agent review |
| `bootstrap-merge` | pre-merge gate | PR merge allowed via bootstrap bypass for gate-config PRs |
| `builtin-review-accepted` | post-commit marker consumer | Builtin-agent review (not Codex) was accepted for a commit |
| `unreviewed-commit` | post-commit marker consumer | Commit landed without a review marker (detected post-hoc) |
| `seatbelt-skip` | seatbelt plugin (cross-tool — not emitted by busdriver itself) | Scanner skipped via `SKIP_SEATBELT` or `SKIP_<SCANNER>` (only present if the seatbelt plugin is installed) |

**Dashboard for review metrics:**

```bash
# Full dashboard — pass rate, severity distribution, avg iterations, time trends
bash scripts/litmus-metrics-report.sh

# Recent runs (last N)
bash scripts/litmus-metrics-report.sh --recent 10

# Raw JSONL for custom analysis
bash scripts/litmus-metrics-report.sh --raw
```

**Reviewing bypasses:**

```bash
# Last 10 bypass events
tail -10 .claude/bypass-log.jsonl | jq .

# Count bypasses by event type
jq -r '.event' .claude/bypass-log.jsonl | sort | uniq -c

# Seatbelt scanner bypasses (which scanner + env var)
jq -r 'select(.event == "seatbelt-skip") | "\(.scanner) via \(.reason) at \(.ts)"' .claude/bypass-log.jsonl
```

Use these monthly to identify drift — scanners you keep bypassing (candidates for tuning or removal), reviews that consistently FAIL on iteration 1 (candidate for preventive feedback), or persistent short-circuit patterns (might warrant raising the threshold).

## Learning system

Busdriver learns from its mistakes:

- **Instincts** — Observed patterns from sessions, promoted after human review
- **Council** — 5-voice multi-perspective analysis (Architect + Skeptic + Pragmatist + Critic + Researcher; defaults to Agy + Codex + Droid)
- **Lesson capture** — When review finds HIGH+ issues the plan missed, lessons are saved automatically
- **Reflection** — Manual `/reflect` skill for capturing corrections and feedback

## Credits

Built on the shoulders of:
- **[Superpowers](https://github.com/obra/superpowers)** by Jesse Vincent — the pipeline backbone
- **[Everything Claude Code](https://github.com/affaan-m/everything-claude-code)** by Affaan Mustafa — domain tools, hooks, and agents
- **[gstack](https://github.com/garrytan/gstack)** by Garry Tan — supplement patterns for security audit, QA, anti-sycophancy, and design quality
- **[Ralphinho RFC Pipeline](https://github.com/humanplane)** — multi-agent DAG execution and multi-model gate review patterns

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and guidelines.

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting.

## License

MIT
