# Hook registrations

What each matcher group in [`hooks.json`](hooks.json) does. These notes live here, not in
the JSON, because Claude Code accepts only `matcher` and `hooks` on a matcher group and
warns about any other key (`hooks.json: unknown keys "description" ...`).
`scripts/ci/validate-hooks.js` rejects extra group keys, so keep notes in this file.

| Event | Matcher | Script | Purpose |
|-------|---------|--------|---------|
| SessionStart | `*` | `load-orchestrator.sh` | Load orchestrator skill + staleness checks + instincts |
| SessionStart | `*` | `session-start.js` | Load previous context and detect package manager on new session |
| PreToolUse | `Bash` | `careful-guard.sh` | [GUARD] Warn before destructive commands (rm -rf, force-push, DROP TABLE, git reset --hard) |
| PreToolUse | `Bash` | `pre-commit-gate.sh` | [GATE] Block git commit until codex + design review pass |
| PreToolUse | `Bash` | `pre-pr-gate.sh` | [GATE] Block gh pr create until codex review passes |
| PreToolUse | `Bash` | `pre-merge-gate.sh` | [GATE] Block gh pr merge until pr-grind declares PR clean |
| PreToolUse | `Bash` | `ref-ff-gate.sh` | [GATE] Block a fast-forward of the protected branch to unreviewed content (git merge / git pull) until an operator-written, oid-bound PASS-FF marker authorizes the exact commit on a git merge --ff-only; a pull on a protected branch has no route at all, because the commit it would land does not exist locally when the gate runs [#779] |
| PreToolUse | `Bash` | `codex-nudge-premerge.sh` | [NUDGE] Non-gating: fire @codex review on gh pr merge when Codex is none + repo active |
| PreToolUse | `Write\|Edit\|MultiEdit\|Bash` | `pre-implementation-gate.sh` | [GATE] Block impl code while design docs unreviewed |
| PreToolUse | `Write\|Edit\|MultiEdit` | `freeze-guard.sh` | [GATE] Freeze/Guard — restrict edits to investigation scope during debugging |
| PreToolUse | `Bash` | `block-no-verify.js` | Block git hook-bypass flag to protect pre-commit hooks |
| PreToolUse | `Bash` | `auto-tmux-dev.js` | Auto-start dev servers in tmux with directory-based session names |
| PreToolUse | `Bash` | `pre-bash-tmux-reminder.js` | Reminder to use tmux for long-running commands |
| PreToolUse | `Bash` | `pre-bash-git-push-reminder.js` | Reminder before git push to review changes |
| PreToolUse | `Write\|Edit\|MultiEdit` | `gateguard-fact-force.js` | [GATE] GateGuard: force impact facts (importers, affected API) before editing. Contained under env -i like the wrapped gates (#616); consent is an out-of-tree marker under the operator's passwd home, not an env var. --fail-open because GateGuard guards no boundary — see skills/gateguard/SKILL.md. |
| PreToolUse | `Bash` | `gateguard-fact-force.js` | [GATE] GateGuard: force blast-radius + rollback facts before a destructive command. Contained under env -i like the wrapped gates (#616); consent is an out-of-tree marker under the operator's passwd home, not an env var. --fail-open because GateGuard guards no boundary — see skills/gateguard/SKILL.md. |
| PreToolUse | `Bash` | `pre-bash-dev-server-block.js` | Block unattended dev server launches outside tmux |
| PreToolUse | `Write` | `doc-file-warning.js` | Doc file warning: warn about non-standard documentation files |
| PreToolUse | `Read` | `pre-read-size-advisory.js` | Advisory: surface when a wholesale Read targets a file verifiably over ~200 lines within a bounded probe (50 MiB cap, 1 MiB scan window) |
| PreToolUse | `Write\|Edit\|MultiEdit` | `config-protection.js` | Block modifications to linter/formatter config files |
| PreToolUse | `mcp__.*` | `mcp-health-check.js` | Check MCP server health before MCP tool execution |
| PreToolUse | `Bash\|Write\|Edit\|MultiEdit` | `governance-capture.js` | Capture governance events. Enable with ECC_GOVERNANCE_CAPTURE=1 |
| PreToolUse | `*` | `observe.sh` | Capture tool use observations for continuous learning |
| PreCompact | `*` | `pre-compact.js` | Save state before context compaction |
| PostToolUse | `Write\|Edit\|MultiEdit\|Bash` | `check-design-document.sh` | [STATE] Flag design docs for review gate |
| PostToolUse | `Write\|Edit\|MultiEdit` | `go-post-edit.sh` | gofmt/goimports/go vet on .go files |
| PostToolUse | `Bash` | `post-commit-consume-marker.sh` | [CLEANUP] Consume codex marker after successful commit |
| PostToolUse | `Bash` | `post-pr-consume-marker.sh` | [CLEANUP] Consume PR review marker after successful gh pr create |
| PostToolUse | `Bash` | `post-merge-confirm-bypass.sh` | [CLEANUP] Confirm or release pre-merge skip-pr-grind bypass after gh pr merge |
| PostToolUse | `Bash` | `codex-nudge-precreate.sh` | [NUDGE] Non-gating: fire @codex review on successful gh pr create so Codex gets its full pre-merge window (ADR 0024 revisit #1 / #473) |
| PostToolUse | `Bash` | `post-bash-pr-created.js` | Log PR URL and provide review command after PR creation |
| PostToolUse | `Bash` | `post-bash-build-complete.js` | Async hook for build analysis |
| PostToolUse | `Edit\|Write\|MultiEdit` | `quality-gate.js` | Run quality gate checks after file edits |
| PostToolUse | `Edit` | `post-edit-format.js` | Auto-format JS/TS files after edits |
| PostToolUse | `Edit` | `post-edit-console-warn.js` | Warn about console.log statements after edits |
| PostToolUse | `Bash\|Write\|Edit\|MultiEdit` | `governance-capture.js` | Capture governance events from tool outputs. Enable with ECC_GOVERNANCE_CAPTURE=1 |
| PostToolUse | `Edit\|Write\|MultiEdit` | `post-edit-accumulator.js` | Accumulate edited JS/TS file paths for batch format/typecheck at Stop |
| PostToolUse | `Edit\|Write\|MultiEdit` | `design-quality-check.js` | Frontend design quality hints after editing UI files |
| PostToolUse | `*` | `observe.sh` | Capture tool use results for continuous learning |
| PostToolUse | `*` | `session-activity-tracker.js` | Record sanitized tool activity metrics to ~/.claude/metrics/ |
| PostToolUse | `mcp__plugin_claude-mem_mcp-search__.*` | `post-memory-recall-reminder.sh` | [REMINDER] Verify-before-assert nudge after claude-mem recall (stale-by-default LEAD, not ground truth) |
| PostToolUse | `Bash` | `post-bash-command-log.js` | Audit log bash commands to ~/.claude/bash-commands.log |
| PostToolUseFailure | `mcp__.*` | `mcp-health-check.js` | Track failed MCP tool calls, mark unhealthy servers |
| Stop | `*` | `check-console-log.js` | Check for console.log in modified files |
| Stop | `*` | `session-end.js` | Persist session state after each response |
| Stop | `*` | `cost-tracker.js` | Track token and cost metrics per session |
| Stop | `*` | `stop-format-typecheck.js` | Batch format + typecheck all JS/TS files edited this session |
| Stop | `*` | `desktop-notify.js` | Native desktop notification when session ends |
| Stop | `*` | `evaluate-session.js` | Evaluate session for extractable patterns (continuous learning) |
| SessionEnd | `*` | `session-end-marker.js` | Session end lifecycle marker |

## Launch form (#713 / ADR 0049)

Registrations that launch through `hooks/gate-scripts/lib/contained-launch.sh` use exec
form (command + args, no shell): a committed settings.json `env` block can no longer
silence them via the outer `/bin/sh`, and the first hop runs `#!/bin/bash -p`, which
ignores SHELLOPTS/BASHOPTS, skips BASH_ENV and ENV, and refuses to import shell functions.
The launcher exits 2 with no output when a client drops `args` (closes R7), and converts a
launch failure that never produced a decision into the registration's declared disposition
(closes R8 — first arg `closed` or `open`). Remaining residual, tracked in #777: R3
(XDG_CONFIG_HOME and BUSDRIVER_ORIG_HOME are no longer forwarded).

- **`pre-merge-gate.sh`** — also R9: PR_GRIND_CODEX_RETRIGGER is no longer forwarded, so
  this gate's non-gating missing-Codex advisory (codex_none_warning, read-only, posts
  nothing) no longer honours the kill switch: an operator with `=0` now gets its bounded
  `gh` read and its warning at merge time. Outbound `@codex review` comments stay
  suppressed — the two nudge registrations that post are deliberately left in shell form.
- **`codex-nudge-premerge.sh`, `codex-nudge-precreate.sh`** — DELIBERATELY LEFT IN SHELL
  FORM, not migrated. Exec form cannot forward `$PR_GRIND_CODEX_RETRIGGER`: `env -i` strips
  it, and these hooks run their delegate (codex-nudge-if-expected.sh → codex-retrigger.sh)
  as a CHILD of that sterile process, so under exec form `PR_GRIND_CODEX_RETRIGGER=0` would
  stop suppressing outbound `@codex review` comments. They are non-gating, so an
  outer-shell SHELLOPTS=noexec silencing them is not a gate bypass — it only skips a
  nudge. The exact command strings are pinned verbatim by `scripts/ci/validate-hooks.js`.
