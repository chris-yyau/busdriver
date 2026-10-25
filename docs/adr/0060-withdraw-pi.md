# ADR 0060 — Withdraw pi

## Status

**Accepted (2026-10-25).** Supersedes [ADR 0034](./0034-pi-in-tree-read-lane.md),
[ADR 0042](./0042-pi-version-certification-cache.md) and
[ADR 0052](./0052-pi-read-on-antigravity.md). Withdraws the pi-replacement program
(`docs/plans/2026-08-23-pi-replacement.md`) and item 10 of
`docs/plans/2026-08-27-pipeline-final-plan.md`, and item 7b of the same plan.
Plan: `docs/plans/2026-10-25-withdraw-pi.md`. Recovery anchor: `d387639d`
(origin/main immediately before removal) — `git show d387639d:<path>` restores any
file.

## Context

pi served one shipped role, the `pi-read` dispatch lane: an in-tree reader in a
jail with `--tools read`, made the mandated first stop for reads by
`.claude/CLAUDE.md`. A second, larger role was planned and never built — pi as
the single vendor-swappable worker layer (the pi-replacement program).

Measured 2026-10-25 over the previous 30 days (`~/.claude/homunculus/dispatch-log.jsonl`):
144 pi-read dispatches, 136 `skipped`, 8 `success`, all 8 on 2026-10-05 (the ADR 0052
certification day). Installed pi was 1.2.0 against the 1.0.1 pin, so every dispatch
after the 2026-10-14 upgrade was refused — the same silent outage ADR 0042 recorded
for an earlier upgrade — and nobody noticed. Direct agent calls in the same window:
grok 18, agy-prose 12, agy 6, pi-read 5.

Against that: the arm was ~860 of `dispatch.sh`'s 2739 lines plus a 1859-line test;
two version pins with a live re-certification ritual; residuals ADR 0052 left open
(refresh bounded only by a 90s kill, non-atomic `auth.json` writes, unconfined reads);
and Google ToS/account-suspension risk from pi-antigravity's use of Antigravity's
OAuth client, which ADR 0052 accepted. The replacement program ran 13 review rounds
without converging; only its rename slice landed. CodeGraph (`codegraph_explore`) and
an Explore subagent now cover "keep large reads out of context" with no external
provider.

## Decision

Remove pi entirely. `--cli pi` and `--cli pi-read` are refused with a migration
message that names the replacement; nothing is invoked. `.pi_read.model` is no
longer read (a leftover key is inert, like `.auditor.model`). The `skipped` status
and the `--cli all` batch contract are unchanged; grok's refusals are now their
only producer, and the tests drive them through grok. The read rule in
`.claude/CLAUDE.md` and the read-size advisory point at CodeGraph and Explore.
`tests/test-review-boundaries.sh` §9c asserts no pi lane code remains in
`scripts/`, `skills/` or `hooks/`.

## Alternatives

- **Keep the lane, cancel only the program.** Rejected (council, 2026-10-25): it keeps
  the part with the running cost and the ToS exposure and cancels the part that cost
  nothing.
- **Re-certify pi 1.2.0 and keep everything.** Rejected: the lane had zero successful
  reads in the twenty days before measurement; re-certifying buys a capability nobody
  was using.
- **Replace pi-read with another external read lane.** Rejected: two read lanes have
  now been withdrawn for disuse (agy-read, pi-read); an in-session index does the job
  without moving content to a third party.

## Consequences

- One fewer external provider and one fewer credential store in every data-boundary
  argument.
- No external read lane. Large reads go through CodeGraph or an Explore subagent, whose
  cost lands in this session rather than at a third party.
- **Behaviour change — the bash 4 interpreter floor is gone.** It existed for #595:
  the pi preflight ran a quoted heredoc inside `$(...)`, which bash 3.2 mis-parses into
  a silent exit 0. That construct went out with the arm, and a scan of the remaining
  `dispatch.sh` for bash-4-only constructs (`declare -A`, `mapfile`, `readarray`, case
  modification, `@Q`, `coproc`, `wait -n`) is empty. The floor was also broader than
  the pi lane: it refused `--cli all` in any non-auto mode on bash < 4 for the whole
  batch, pi installed or not. That refusal no longer happens — such a batch now runs
  codex, agy and grok. bash 3.2 is still not a verified interpreter for `dispatch.sh`;
  `tests/test-dispatch-skipped-status.sh` still skips its runtime cases below bash 4.
- `dispatch.sh` keeps its `#!/usr/bin/env -S bash -p` shebang (chosen for pi's bash 4+
  floor); tightening it to `/bin/bash` needs its own bash 3.2 verification and is a
  separate change.
- Operator-side residue is NOT removed by this change: the projected credential store
  (`~/.pi/agent/auth.json`, `antigravity-accounts.json`), the Google OAuth grant, and
  the installed binary. Deleting code revokes nothing; see the plan's operator tasks.
- Historical log entries keep `pi-read`; ADRs 0034/0042/0052 and the program plans
  stay as records.

## Revisit trigger

A sustained need for an external reader that CodeGraph and an Explore subagent cannot
meet — measured, not anticipated. Add it as a new, reviewed lane with its own ADR;
do not restore this one from the anchor.
