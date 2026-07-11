# ADR 0016 — Sanitized-environment containment for review gates

- **Status:** Accepted
- **Date:** 2026-07-11
- **Issue:** #325
- **Supersedes / relates:** ADR 0012 (advisory-downgrade opt-in — same "location beats
  content", operator-owned-file-over-env reasoning that this ADR generalizes)

## Context

Claude Code merges a committed `.claude/settings.json` `env` block into the session
process environment. `settings.json` is a **committable** file, so a PR author —
including a forker who opens a PR — controls its contents, and every bash review gate
inherits those variables when its PreToolUse/PostToolUse hook fires. That makes the
process environment a PR-controllable injection channel into the gates that are
supposed to guard the PR. Verified levers on `main` before this change:

| Lever | Effect |
|-------|--------|
| `SKIP_LITMUS` / `SKIP_PR_GRIND` / `SKIP_DESIGN_REVIEW` | direct gate bypass (`… && exit 0`) |
| `BASH_ENV` / `ENV` / exported functions (`BASH_FUNC_*`) | arbitrary code runs **before** a gate's first line (RCE) |
| `PATH` | prepend a repo-local dir to shim `git` / `gh` / `jq` / `python3` |
| `GIT_*` (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_CONFIG_*`, …) | redirect the git resolution gates rely on |
| `BUSDRIVER_PLUGIN_ROOT` | repoint plugin root → gate scripts `source` attacker code (RCE) |
| `BUSDRIVER_STATE_DIR` | point marker/skip-file lookup at a dir where a `skip-*.local` **can** be committed (gitignore only covers `.claude/*.local`) |
| `LITMUS_PR_BASE` / `LITMUS_PR_BACKSTOP_MAX_AGE` | move the review diff base / inflate the backstop-age window to manufacture a bypass |

This is **systemic**, not a bug in any one gate: `BASH_ENV`/`PATH`/exported functions
compromise a script *before* its own logic runs, so a per-script scrub cannot be
trusted. Containment has to happen **above** the scripts.

Mitigating context (why this was filed as a design record, not an emergency): the repo
is **solo-operator**, and the threat requires the maintainer to run a session *on an
attacker's PR branch*. Real, but bounded. The operator opted into full containment
regardless.

## Decision

Run every enforcement/state gate under a **sanitized environment**, established at the
hook entry point (the one place above the scripts), not inside the scripts.

`hooks.json` invokes each gate as:

```
/usr/bin/env -i PATH=/usr/bin:/bin HOME="$HOME" CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}" \
  bash "${CLAUDE_PLUGIN_ROOT}/hooks/gate-scripts/lib/sanitized-gate.sh" <gate>.sh
```

- `/usr/bin/env` is **absolute** → the outer shell does no `PATH` lookup for it, so a
  shimmed `env` can't win.
- `env -i` wipes the **entire** environment — `BASH_ENV`/`ENV`/exported functions, the
  poisoned `PATH`, `GIT_*`, `SKIP_*`, `BUSDRIVER_*`, `LITMUS_PR_*`, and any unknown
  future lever — in one move. Only a minimal allowlist is re-added.
- `lib/sanitized-gate.sh` rebuilds a **trusted `PATH`** from a fixed list of absolute
  dirs that exist (never the caller's `PATH`), **neutralizes global + system git config**
  (`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_SYSTEM=/dev/null`) so a re-imported `HOME`
  cannot smuggle a `~/.gitconfig` with an executable helper/alias/pager, then execs the
  named gate with stdin (the PreToolUse JSON) passed through untouched.

Additionally, the named `SKIP_LITMUS` / `SKIP_PR_GRIND` / `SKIP_DESIGN_REVIEW` env
escape hatches are **removed** from the gate scripts. They are stripped by `env -i`
anyway, and were the cleanest injectable lever. The **operator-created `.local` skip
file** remains the one sanctioned escape hatch — consistent with ADR 0012's
operator-owned-file principle.

But `.gitignore` prevents an accidental `git add`, **not** `git add -f` — so a
malicious PR could commit `.claude/skip-litmus.local`, and after checkout (past the
30s age window) the gate would consume it. That is the *same committable-content
injection class* as this issue. So each gate now also **refuses a repo-controlled
skip file**: `gate_skip_file_repo_controlled` (in `lib/resolve-repo-dir.sh`, mirroring
ADR 0012's fail-closed `_repo_controlled`) rejects any skip file tracked in the index
or HEAD, or in a gitlinked state dir. Only a genuinely *untracked* operator-created
file is honored; any git error fails CLOSED (skip ignored, review enforced).

**Collateral damage — assessed:** the only session-inherited *functional* config any
wrapped gate reads is `LITMUS_PR_BASE` / `LITMUS_PR_BACKSTOP_MAX_AGE`, and both are
themselves injection levers → dropping them to their secure defaults (`origin/HEAD`,
`3600`) is the fix, not a regression. Everything else the gates use is either self-set
(`MODE`, `MERGE_PR_NUM`, …), arrives on stdin, or is read from repo files.

The one real trade-off is `gh` config. `gh` in the pre-PR / pre-merge gates authenticates
via its config/keyring under `$HOME` (`~/.config/gh` — preserved), so the default
`gh auth login` path is unaffected. But `env -i` intentionally does **not** re-import
`GH_TOKEN` / `GITHUB_TOKEN` / `GH_HOST` / proxy vars, because those are themselves
injection levers (a committed `settings.json` could set `GH_TOKEN` to an attacker token,
or `GH_HOST` to redirect PR-state queries). Consequence: an operator relying on
**environment-only** `gh` auth, a non-default `GH_HOST` (GitHub Enterprise), or a required
proxy must move that config into `gh`'s config files (or `~/.config`), not the session env.
For this solo repo (keyring auth, github.com, no proxy) there is no impact.

**Scope:** the 10 enforcement/state gates — `careful-guard`, `pre-commit-gate`,
`pre-pr-gate`, `pre-merge-gate`, `pre-implementation-gate`, `freeze-guard`,
`check-design-document`, `post-commit-consume-marker`, `post-pr-consume-marker`,
`post-merge-confirm-bypass`. The `go-post-edit` formatter and `load-orchestrator`
bootstrap are intentionally **not** wrapped (not enforcement gates; wrapping the
formatter would strip its Go toolchain PATH, and the bootstrap legitimately reads
`CLAUDE_HOMUNCULUS_INTERNAL`). The `node`-based reminder/logger hooks are out of scope:
`BASH_ENV` does not apply to `node`, and they make no allow/block decision.

## Alternatives considered

1. **Per-script env scrub** (each gate re-derives its signal from a non-env source).
   Rejected: cannot stop `BASH_ENV`/`PATH`/exported-function RCE, which fire before the
   script's first line.
2. **Document as accepted residual risk only** (the "solo-operator, don't run sessions
   on untrusted branches" operational control). Reasonable given the bounded threat, but
   the operator chose to actually close the surface.
3. **`env -u <lever>` denylist** instead of `env -i` allowlist. Rejected: can't
   wildcard-strip exported functions (`BASH_FUNC_*`) and silently misses any lever not
   on the list. `env -i` is closed-by-default.

## Consequences

- The env-based `SKIP_*` escape hatch is **gone**. Operators who previously exported
  `SKIP_LITMUS=1` before starting `claude` now use `touch <repo>/.claude/skip-litmus.local`
  (or `skip-pr-grind` / `skip-design-review`). Docs updated repo-wide.
- Gate scripts run with a fixed trusted `PATH` and no inherited env; a committed
  `settings.json` can no longer bypass a gate or run code through one.
- The `BUSDRIVER_STATE_DIR` / `BUSDRIVER_PLUGIN_ROOT` / `LITMUS_PR_*` overrides still
  work when a gate script is invoked **directly** (tests, manual runs); they are only
  stripped on the production hook path. Test suites are unaffected.

### Residual risks (accepted)

- **`CLAUDE_PLUGIN_ROOT`** locates the wrapper (`hooks.json` expands it *before* `env -i`).
  This is **not** part of the `settings.json`-`env` injection channel: Claude Code sets
  `CLAUDE_PLUGIN_ROOT` authoritatively per-plugin *after* merging `settings.json`, so a
  committed `env` block **cannot** override it (verified — Claude-provided variables take
  precedence over the settings `env` block, [docs](https://code.claude.com/docs/en/settings.md)
  v2.1.195+; it is exported to hook processes per
  [plugins-reference](https://code.claude.com/docs/en/plugins-reference.md)). It is the
  plugin trust root every busdriver hook already relies on, and #325's lever list
  correctly omits it.
- **`HOME`** is re-imported because tools need it (`gh` reads `~/.config/gh` for auth).
  The concrete git-helper RCE it enabled (`~/.gitconfig` alias/helper) is **closed** by the
  `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM=/dev/null` neutralization above; a spoofed
  `~/.config/gh` remains a bounded residual (the gates' `gh` calls are read-only PR-state
  queries).
- **Outer-shell `BASH_ENV`** — **verified not a live vector** for the documented hook
  runner. `env -i` protects the gate script, but not the *outer* shell that Claude uses to
  launch the hook command (that shell sources its startup files before parsing our
  command, so `env -i` cannot reach an outer sourcing). The guarantee therefore rests on
  *which shell* Claude uses: it runs hook commands via **`sh -c`**
  ([docs](https://code.claude.com/docs/en/hooks.md), macOS/Linux default), and a
  non-interactive POSIX `sh` sources **no** startup files — so `BASH_ENV` is never read
  before our command. Confirmed empirically on this host: `/bin/sh -c` ignores a
  `BASH_ENV` that `bash -c` *does* source (a `BASH_ENV` script that `exit 0`s suppresses
  the command only under `bash -c`). The single way this reopens is an upstream change to
  invoke hooks via `bash -c` — recorded as a revisit trigger.
- `node`-based non-gate hooks remain env-exposed (out of scope; no allow/block role).

## Revisit trigger

- A second approval-capable human is added (repo stops being solo-operator) → tighten
  the residuals above (pin `CLAUDE_PLUGIN_ROOT`, wrap the `node` hooks, re-examine
  `HOME`).
- Claude Code gains a first-class "don't honor project-`settings.json` `env` for
  security-relevant keys" control → prefer it and simplify this wrapper.
- Claude Code changes hook execution from `sh -c` to `bash -c` (or any bash-named shell)
  → the outer-shell `BASH_ENV` sourcing above becomes live; re-close upstream or move gate
  enforcement out of a shell command.
