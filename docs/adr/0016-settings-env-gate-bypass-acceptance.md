# ADR 0016: Drop gate-skip env vars; accept the bounded `settings.json` env-injection surface

## Status

Accepted (2026-07-11). Resolves issue #325. Discharges the explicit follow-up
left open in [ADR 0012](./0012-advisory-bot-stale-timeout-downgrade.md) (lines
~202–205: "`SKIP_LITMUS` / `SKIP_PR_GRIND` are themselves settable via a
committed `.claude/settings.json` `env` block … worth hardening **or an explicit
ADR acceptance in its own change**"). This is that change. Continues the
"location beats content" / "escape ≠ enable" reasoning ADR 0012 established for
the advisory-downgrade opt-in and PR #314.

## Date

2026-07-11

## Context

Claude Code merges the `env` block from a project `.claude/settings.json` into
the session process environment. `settings.json` is a **committable** file, so a
PR author (including a forker) controls its contents, and every bash gate/hook
the session runs inherits those variables. This makes the review gates —
themselves plain bash reading behavior from env — influenceable by the very PR
they are meant to guard.

**Verified injectable levers on `main` (pre-fix):**

- Named gate-skip vars accepted bare from env:
  - `pre-commit-gate.sh` — `[ "${SKIP_LITMUS:-0}" = "1" ] && exit 0`
  - `pre-pr-gate.sh` — `[ "${SKIP_LITMUS:-0}" = "1" ] && exit 0`
  - `pre-merge-gate.sh` — `[ "${SKIP_PR_GRIND:-}" = "1" ] && exit 0`
  - `pre-implementation-gate.sh` — `[ "${SKIP_DESIGN_REVIEW:-0}" = "1" ] && exit 0`
- Generic, higher-impact levers exposed to any bash the session runs:
  - **`BASH_ENV`** — sourced by every non-interactive `bash` at startup (and
    `ENV` likewise for a script running under POSIX `sh` / bash in POSIX mode).
    The gate scripts are `#!/usr/bin/env bash` run non-interactively, so a
    poisoned `BASH_ENV` executes arbitrary code **before line 1 of any gate** —
    RCE the moment a gate fires.
  - **`PATH`** — prepend a repo-local dir to shim `git`, `gh`, `jq`, etc.
  - **`GIT_*`** (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_CONFIG_*`, …) — redirect git
    resolution used by the gates.

**Why the levers are not independent.** `BASH_ENV`/`ENV` grant arbitrary code
execution, which subsumes every SKIP_* var and more (an attacker with `BASH_ENV`
can create skip files, patch the gate, or delete markers). So closing the SKIP_*
vars while `BASH_ENV` stays open is **surface reduction and consistency, not a
barrier** against a `BASH_ENV`-capable attacker.

**Why the RCE surface cannot be reliably closed in-repo.** `BASH_ENV` fires when
a bash interpreter *starts*, before any in-script preamble. To neutralize it we
would have to strip it in the hook invocation string *before* `bash gate.sh`
runs — but whether that suffices depends on **which shell Claude Code uses to run
hook `command` strings** (a bash outer shell would itself source `BASH_ENV`
first) and **whether Claude Code sanitizes the hook environment or filters
`settings.json` env keys**. A `claude-code-guide` investigation (2026-07-11)
found all three points **undocumented**. Building a security control on
undocumented harness internals is fragile — it could silently regress on a Claude
Code update. `PATH` is likewise not scrubbable without a per-machine allowlist
that would break `git`/`gh`/`node` discovery.

**Mitigating context (why the residual is bounded — not "no real second user"
hand-waving):**

1. **The local gates were never the merge-security boundary.** A malicious PR's
   committed `settings.json` cannot touch the server-side required status checks
   + branch protection + sole-admin rule that actually gate merges. Even a total
   local-gate bypass **cannot merge itself**. The local gates are a
   development-workflow quality layer for the operator's *own* work.
2. **Exploitation requires the operator to run a Claude session on the untrusted
   branch** — a general "don't run agents on untrusted code" property, not a
   busdriver-specific defect.
3. **Solo-operator repo.** This is the same reasoning that already froze
   per-PR provider-scrub work in `.claude/CLAUDE.md`. The operator's own
   `settings.local.json` carries no `env` block, so the SKIP_* env path is not
   relied on today.

## Decision

**1. Remove the four `SKIP_*` gate-skip env-var reads.** The gates honor **only**
the git-resolved, operator-placed skip *files* (`skip-litmus.local`,
`skip-pr-grind.local`, `skip-design-review.local`) — which are already
anti-self-bypass hardened (≥30s age, single-use consumption, audited to
`bypass-log.jsonl`). The skip-file check now honors a skip file **only when it is
operator-owned** — a non-symlink regular file, in a non-symlink / non-gitlink
single-component state dir, that is **not** present in the git index or HEAD's
tree — via `hooks/gate-scripts/lib/skip-file-guard.sh` (mirroring the ADR 0012
repo-controlled-file resolver). This closes the residual vector Codex flagged on
PR #328: a committed / tracked skip file (directly, or via a
`BUSDRIVER_STATE_DIR`-redirected tracked dir) is now rejected, because any
PR-delivered file is necessarily git-tracked. The skip files are therefore **not**
injectable via a committed `settings.json` *now that repo-controlled skip files
are rejected*; the residual `BASH_ENV`/`ENV`/`PATH`/`GIT_*` RCE surface remains
accepted-bounded as documented in item 2. This makes gate-skip consent handling
uniform with the "operator-placed file over env var" pattern ADR 0012 / PR #314
settled, and reduces the *named* attack surface the issue enumerates to zero.

**2. Accept the residual `BASH_ENV`/`ENV`/`PATH`/`GIT_*` RCE surface as bounded
and documented, not hardened.** Per the reasoning above it is not reliably
closable in-repo, and the three mitigating facts cap its severity for a
solo-operator repo. The operator-level mitigation is: **do not run a Claude Code
session inside an untrusted PR branch checkout**; server-side required checks
remain the merge authority regardless.

## Alternatives

- **Full sanitized-env hardening** (route gates through a launcher; strip
  `BASH_ENV`/`ENV`/`GIT_*`; reset `PATH` to an allowlist; refuse settings-origin
  env). Rejected: depends on undocumented Claude Code hook-exec internals (may
  not actually close `BASH_ENV` if the outer hook shell is bash), the `PATH`
  allowlist is per-machine-fragile and breaks tool discovery, high maintenance,
  and it re-opens exactly the hostile-threat-model churn `.claude/CLAUDE.md`
  declared frozen for solo use.
- **Refuse a `settings.json`-origin `env` value for gate keys.** Rejected: Claude
  Code exposes **no documented signal** for whether an env var originated from
  `settings.json` vs. the parent shell, so this cannot be implemented reliably.
- **Pure ADR acceptance, no code.** Rejected: removing the SKIP_* reads is a
  cheap, deterministic consistency win (aligns with the settled file-based
  pattern) with no dependence on undocumented behavior — worth taking even though
  it is not a standalone barrier.
- **Keep the SKIP_* env vars.** Rejected: they are strictly weaker than, and
  redundant with, the file hatch, and they are the exact levers the issue names.

## Consequences

- **Lost convenience:** the sticky-session `export SKIP_LITMUS=1` /
  `SKIP_PR_GRIND=1` / `SKIP_DESIGN_REVIEW=1` override is gone. The git-resolved
  skip *file* remains the one intentional, audited bypass — but it is **one-shot**
  (consumed per use), where the env var was sticky for the whole session. To skip
  repeatedly, re-`touch` the file. Judged an acceptable trade for uniform,
  non-injectable consent handling.
- **Same-class sibling retained and flagged:** `PR_GRIND_ALLOW_NON_MAIN_BASE=1`
  (`skills/pr-grind/SKILL.md`) is the same injectable class but is a
  **skill-level safety refusal** (don't merge into a non-trunk base), executed by
  Claude-driven bash rather than a PreToolUse hook, and gates a *safety* check
  rather than a *review* skip. Its file hatch (`skip-baseref-check.local`) is
  retained. Left in place under this ADR's "accepted-bounded" umbrella; a future
  change may drop its env form for the same consistency reason.
- `bypass-log.jsonl` telemetry is unaffected — it only ever logged file-based
  skips; the env-var path exited without logging, so removing it loses no audit.
- No change to the merge-security boundary (server-side checks + sole-admin).

## Revisit trigger

- **A second approval-capable human joins the repo** (the solo assumption
  breaks) — re-evaluate whether the residual RCE surface warrants the fragile
  full-hardening after all, and whether the merge/skip model needs tightening.
- **Claude Code documents** a sanitized hook-environment guarantee, a
  `settings.json` `env` key-filter, or an env-origin signal — then the residual
  can be closed by construction and this acceptance should be narrowed.
- **Evidence of real exploitation** (a PR that actually leveraged the surface, or
  a second user/threat materializes) — promote to full hardening.

## Addendum (2026-07-11): reject repo-controlled skip files (PR #328 Codex P1)

**Vector.** Removing the `SKIP_*` env reads (above) left the retained skip *file*
as the sole bypass — but Codex's review of PR #328 found that a *file* is just as
PR-injectable as an env var. A PR can commit a **git-tracked** skip file two ways:
(a) force-add it past `.gitignore` — `git add -f .claude/skip-litmus.local` — or
(b) commit a `.claude/settings.json` with `env.BUSDRIVER_STATE_DIR=evil` plus a
tracked `evil/skip-litmus.local`. After the checkout ages past the gate's 30s
self-bypass window, the old `[ -f "$SKIP_FILE" ]` test consumed the file and
exited 0 **before any review**. The original claim that the skip file was "not
injectable via `settings.json`" was therefore false for a tracked file.

**Fix.** The `[ -f … ]` condition in all four gates is replaced with
`skip_file_operator_owned` (`hooks/gate-scripts/lib/skip-file-guard.sh`), which
honors a skip file only when it is a non-symlink **regular** file, in a
non-symlink / non-gitlink **single-component** state dir, that is **not** in the
index and **not** in HEAD's tree — failing CLOSED (reject) on any git error. It
scrubs repo-supplied `GIT_*` env in a subshell and pins every git query to the
gate's own `REPO_DIR`, exactly like the ADR 0012 resolver
(`scripts/advisory-downgrade-optin.sh`). Because **any PR-delivered file is
necessarily git-tracked**, rejecting repo-controlled skip files closes the vector
by construction. Regression coverage: `tests/test-skip-file-guard.sh`. The
residual `BASH_ENV`/`ENV`/`PATH`/`GIT_*` RCE surface is unchanged and remains
accepted-bounded per item 2 above.
