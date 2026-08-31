# Observability

Two persistent JSONL logs per project let you answer questions like *"what's litmus's pass rate?"* or *"how often do I bypass and why?"* without digging through session history.

This is **not** a comprehensive audit trail of every gate execution. `review-metrics.jsonl` records litmus review outcomes; `bypass-log.jsonl` records skip-file consumptions plus the selected telemetry events enumerated below. Routine gate activity that neither reviews nor bypasses — a careful-guard prompt, a freeze-guard refusal, an ordinary allow — is not logged.

| File (per project) | Who writes | What it captures |
|--------------------|-----------|------------------|
| `.claude/review-metrics.jsonl` | litmus | Review outcome (PASS/FAIL), issue count, severity breakdown, iteration, CLI used, mode, commit SHA, branch, diff size |
| `.claude/bypass-log.jsonl` | litmus + busdriver gates (+ seatbelt plugin if installed) | Skip-file consumptions + selected telemetry events (see taxonomy below). Env-var bypasses (`SKIP_LITMUS`, `SKIP_PR_GRIND`) were removed in #325 / ADR 0016 — for **busdriver's own gates**, only the audited, file-based skips remain. The seatbelt plugin is a separate tool writing to the same log and still supports its own `SKIP_SEATBELT` / `SKIP_<SCANNER>` env vars (see `seatbelt-skip` below) |

## Event types written to `bypass-log.jsonl`

All three pre-merge **allow** paths (`skip-pr-grind-claimed`, `pr-grind-clean-merge`, `bootstrap-merge`) record through one helper that **fails CLOSED**: if the record cannot be appended, the gate blocks instead of authorizing an unlogged merge (#667). That is what makes the *absence* of a record meaningful. Be precise about the claim: these record **authorized attempts**, so a blocked attempt is also recordless — the gate saw it and refused. What absence shows is that the gate never *authorized* a merge. (One narrow exception in the other direction: the skip path records before writing its `.merge-bypass-pending.local` claim — deliberately, so a refused record has no unlink to roll back through a possibly-symlinked parent — so if that claim write then fails, a `skip-pr-grind-claimed` event survives for a merge the gate went on to block. Over-recording a visibly blocked attempt is the harmless direction, and nothing reads these events as authorization.) Combined with GitHub reporting the PR merged, absence means it merged without gate authorization — typically from a shell outside Claude Code, where no PreToolUse hook fires by design. Detection, not prevention: nothing here can observe an out-of-harness merge.

| Event | Source | Meaning |
|-------|--------|---------|
| `skip-review-consumed` | pre-commit / pre-pr / pre-implementation gate | User-created `skip-litmus.local` or `skip-design-review.local` was consumed |
| `skip-marker-cleared` | `scripts/design-clear.sh --skip <name>` | A drainable spent skip file or consumed review artifact (`skip-litmus.local`, `skip-design-review.local`, `litmus-passed.local`, `pr-review-passed.local`, the two PR `.local.json` verdicts) was released. Removal makes the next gate STRICTER, never looser — that direction is the whole membership test for the allowlist |
| `skip-marker-clear-failed` | `scripts/design-clear.sh --skip <name>` | The `skip-marker-cleared` event was already written (audit first, unlink second) but the removal did not complete or could not be verified — the unlink failed, or the state directory changed under the descriptor afterwards so the result is unprovable. The audit log's correction that the release did not take effect |
| `skip-pr-grind-claimed` | pre-merge gate (PreToolUse) | Records that the gate *reached* the skip-approval path for one `gh pr merge` and was about to write a `.merge-bypass-pending.local` claim. It is **not** proof the merge was authorized: the event is written before the claim, so if that write then fails the gate blocks and this event survives anyway. Pair it with the matching `skip-pr-grind-consumed`/`-released` event to see what actually happened. (Cutover note: before v1.41.x, the consumed event was logged here with `gate:"pre-merge"`; from v1.41.x onward `skip-pr-grind-consumed` is logged at PostToolUse with `gate:"post-merge"`.) |
| `skip-pr-grind-consumed` | post-merge cleanup hook (PostToolUse) | The PR is confirmed merged AND tamper checks passed — the claim was honored and the skip file was deleted. `reason` records how success was confirmed: `github-api-state-merged` (authoritative `gh pr view --json state`, the normal path since #664 — gh prints its `Squashed and merged` line only on a TTY, and its exit code is unreliable with `--delete-branch`), `cli-pattern-merged` when gh's own output confirmed it (a TTY, or stderr), `cross-repo-merge-unverifiable-token-spent` for a merge steered at another repo/host (this checkout's same-numbered PR is a different pull request, so it is not queried at all — the token is spent rather than left armed, and the operator re-touches if that merge failed), or `auto-merge-accepted-token-spent` for an accepted `--auto` queue |
| `skip-pr-grind-released` | post-merge cleanup hook (PostToolUse) | `gh pr merge` failed AND the GitHub API does not report the PR `MERGED`; the claim was discarded and the skip file was preserved for retry. A local failure after GitHub already merged the PR (the `--delete-branch` worktree-conflict shape) does NOT hit this path — it is reclassified `success` (`reason: github-api-state-merged`) and emits `skip-pr-grind-consumed` instead |
| `skip-pr-grind-released-auto-queued` | post-merge cleanup hook (PostToolUse) | **Retired in #664 — no longer emitted.** An accepted `gh pr merge --auto` queue now consumes the token (`reason: auto-merge-accepted-token-spent`): GitHub lands that merge with no second PostToolUse event, so nothing could ever confirm it and preserving left a spent bypass armed. Historical entries keep their original meaning (skip file was preserved) |
| `skip-pr-grind-released-ambiguous` | post-merge cleanup hook (PostToolUse) | Tool output matched neither success nor failure pattern AND the GitHub API did not answer `MERGED` (unreachable, unauthenticated, or the PR really is not merged); fail-safe: skip file preserved |
| `skip-pr-grind-released-tampered` | post-merge cleanup hook (PostToolUse) | The skip file disappeared, its mtime changed between claim and confirm, or it was younger than 30s at confirmation. Anti-self-bypass re-applied at consumption; skip file preserved (or absent, in the deleted case) |
| `skip-pr-grind-released-mismatch` | post-merge cleanup hook (PostToolUse) | The PR number parsed from the bash command did not match the PR number recorded in the pending claim, OR either side could not be concretely identified (the auto-detect path where `gh pr merge` runs without an explicit PR number records `merge_pr=unknown` and is refused at confirmation time to prevent cross-PR token reuse via branch-switching between claim and confirm). Skip file preserved |
| `skip-pr-grind-released-malformed` | post-merge cleanup hook (PostToolUse) | Pending claim file failed structural validation (non-numeric mtime, malformed PR number). Skip file preserved |
| `merge-bypass-stale-cleanup` | post-merge cleanup hook (PostToolUse) | A pending claim older than 5 minutes was force-cleaned via an unrelated Bash call (session crash recovery). Skip file preserved |
| `pr-grind-admin-on-approver-gap` | pr-grind skill (Completion) | Operator passed `--admin-on-approver-gap` to pr-grind and all eligibility gates (CI green, bots ack, author admin/maintain, `bypass-audit.yml` present) held. `gh pr merge --squash --delete-branch --admin` was run; entry captures PR, branch, author, perm, required-approver count, human approvals at decision time, and head SHA |
| `pr-grind-admin-on-approver-gap-solo-admin-auto` | pr-grind skill (Completion) | Same merge as `pr-grind-admin-on-approver-gap`, but triggered by the per-repo `.claude/pr-grind-auto-admin-solo.local` opt-in file plus a live structural check that `HUMAN_ADMIN_COUNT==1` and the author is that sole admin. Entry additionally records `human_admin_count` so a later audit can detect if the repo's admin roster changed post-merge |
| `ref-ff-authorized` | ref fast-forward gate (PreToolUse) | A `git merge --ff-only <oid>` that would fast-forward a protected branch was authorized by a `ref-ff-authorized.local` marker (#779 / ADR 0050). Records the `branch`, the `oid` the marker named — the two things it binds — and `via`, which is `marker` for a fast-forward and `marker-create` for the creation of a protected branch that did not exist (#781). Those are the gate's only two routes: there are no automatic allows to log — a creation whose start point a protected branch already carries is inert and is allowed with no token and no record. Fails CLOSED like the pre-merge events: if the record cannot be appended the gate blocks rather than authorizing an unlogged ref move, and so does a marker it could not then consume. Attempt-time in the strict sense: the record is appended BEFORE the marker is consumed, so an entry means the authorization was granted and logged — not that git ran, and not even that the gate ultimately allowed, since a consumption that then fails blocks and leaves the event behind. Read it as "a marker was spent against this branch and oid" |
| `review-skipped-none` | pre-commit gate | Gate skipped because no review tool was active (`BUSDRIVER_REVIEW_CLI=none`) |
| `narrative-fallback-triggered` | litmus CLI | Review CLI output was non-JSON; parsed as narrative fallback |
| `codex-droid-fallback` | litmus CLI (`resolve-cli.sh _execute_codex`) | Codex exhausted retries on transient errors (rate-limit / network / 5xx); escalated to `droid exec` (default read-only mode) before falling back to builtin. Logged on every escalation regardless of droid outcome. Disable with `LITMUS_CODEX_DROID_FALLBACK_DISABLED=1` |
| `schema-violation` | litmus schema validator | Review output didn't match expected JSON schema |
| `short-circuit-pass` | litmus commit mode | Diff met all short-circuit criteria; Codex skipped |
| `pr-fast-bypass` | litmus PR mode | `LITMUS_PR_FAST=1` skipped multi-agent review |
| `pr-grind-clean-merge` | pre-merge gate | PR merge authorized on the normal path — a fresh `pr-grind-clean.local` for this PR, its head SHA matching the PR's live HEAD, and relevant CI green. Records `pr` and the reviewed `head` SHA. Added in #667: this path previously authorized silently, so the merge nearly every PR takes left no trace and was indistinguishable afterwards from one the gate never saw. Attempt-time, like its two siblings: it records that the gate authorized the merge, not that GitHub completed it |
| `bootstrap-merge` | pre-merge gate | PR merge allowed via bootstrap bypass for gate-config PRs |
| `builtin-review-accepted` | post-commit marker consumer | Builtin-agent review (not Codex) was accepted for a commit |
| `unreviewed-commit` | post-commit marker consumer | Commit landed without a review marker (detected post-hoc) |
| `seatbelt-skip` | seatbelt plugin (cross-tool — not emitted by busdriver itself) | Scanner skipped via `SKIP_SEATBELT` or `SKIP_<SCANNER>` (only present if the seatbelt plugin is installed) |

## Dashboard for review metrics

```bash
# Full dashboard — pass rate, severity distribution, avg iterations, time trends
bash scripts/litmus-metrics-report.sh

# Recent runs (last N)
bash scripts/litmus-metrics-report.sh --recent 10

# Raw JSONL for custom analysis
bash scripts/litmus-metrics-report.sh --raw
```

## Reviewing bypasses

```bash
# Last 10 bypass events
tail -10 .claude/bypass-log.jsonl | jq .

# Count bypasses by event type
jq -r '.event' .claude/bypass-log.jsonl | sort | uniq -c

# What did the gate record for PR 666, pre- and post-merge? (#667 — no output
# means it never authorized a merge. Output is recorded activity, not proof of
# authorization: a `skip-pr-grind-claimed` row can survive an attempt the gate
# went on to block, so read it with its matching -consumed/-released event.
# If GitHub says the PR is merged, it merged without gate authorization; check
# whether it was merged from a shell outside Claude Code, where no PreToolUse
# hook fires. A blocked attempt normally leaves no record either, so absence
# alone does not distinguish "never attempted" from "attempted and refused".)
jq -r --arg pr 666 'select((.gate == "pre-merge" or .gate == "post-merge")
  and (.pr | tostring) == $pr) | "\(.ts) \(.gate) \(.event)"' .claude/bypass-log.jsonl

# Seatbelt scanner bypasses (which scanner + env var)
jq -r 'select(.event == "seatbelt-skip") | "\(.scanner) via \(.reason) at \(.ts)"' .claude/bypass-log.jsonl
```

Use these monthly to identify drift — scanners you keep bypassing (candidates for tuning or removal), reviews that consistently FAIL on iteration 1 (candidate for preventive feedback), or persistent short-circuit patterns (might warrant raising the threshold).

## Skip-file semantics

Deep semantics live with the gate that owns each file. All are gitignored and *intended* to be operator-created — nothing here proves a human wrote one — and a file created within 30 seconds is rejected. That age check is a heuristic, not prevention: it detects a just-created skip file and raises the cost of an agent self-bypass (which would have to create the file and then wait), rather than making one impossible.

| File | Consumption | Source of truth |
|------|-------------|-----------------|
| `skip-litmus.local` | Single-use — consumed after one bypass | `skills/litmus/SKILL.md` |
| `skip-design-review.local` | **Lease** (#519 / ADR 0031) — one `touch` authorizes 20 gated writes within 3600s. Only genuinely gated operations spend a use; each use is logged with the slot it claimed | `skills/blueprint-review/SKILL.md` |
| `skip-pr-grind.local` | **Deferred** (#664) — preserved when the merge was genuinely refused and GitHub does not report the PR merged, and also when the outcome cannot be verified at all: ambiguous tool output with `gh pr view` unreachable, unauthenticated, timed out, or answering with an unrecognized state logs `skip-pr-grind-released-ambiguous` and leaves the file armed — deliberately, since the merge may in fact have succeeded, so treat a `-released-ambiguous` event as a possibly-spent bypass still reusable for the rest of its hour. It is *spent* on a confirmed merge, and also on an accepted `--auto` queue (GitHub lands it with no second hook event) and on a merge steered at another repo/host via `-R`/`--repo`/`GH_REPO` (unqueryable from this checkout, so it is spent rather than left armed). The 3600s clock is anchored to the original `touch` and does not reset on a failed-merge release | `skills/pr-grind/SKILL.md` |
| `ref-ff-authorized.local` | Not a skip file — an **authorization** token for exactly one ref move (#779 / ADR 0050, extended by #781). Content must be exactly `PASS-FF refs/heads/<branch> <oid>` to fast-forward that branch, or exactly `PASS-CREATE refs/heads/<branch> <oid>` to CREATE it where it does not exist, on one line; the two verbs authorize different operations and the compare is whole-file, so neither is spendable on the other, and a `PASS-CREATE` token is honoured only on the single shape `git branch <name> <full oid>` (`checkout -b` and `switch -c` get no route — recognizing shapes is an allowlist, and `git branch` is the one that runs no hook of its own); a well-formed first line followed by anything else is refused, as is a marker naming a different ref or oid. Honoured **only when the merge names that oid and carries `--ff-only`** — a symbolic ref is re-resolved when the command runs, and only the literal flag outranks configuration the gate cannot read. Single-use, consumed by the gate at authorization rather than by a PostToolUse hook, so a fast-forward that then fails locally leaves no live authorization behind; a consumption that FAILS blocks, since a token left live would authorize every later merge too. Read and removed through an O_NOFOLLOW walk, so a symlink anywhere in the state dir refuses rather than redirecting. The gate blocks with the exact line to write. Repo-bound only by location, and the 30s age check applies | `hooks/gate-scripts/ref-ff-gate.sh` |
| `ref-ff-protected.local` | Not a skip file and not a bypass — the operator's list of branches the ref fast-forward gate guards, one per line, for a project whose protected branch the gate cannot discover (every remote's HEAD, then `init.defaultBranch`, then main/master/trunk/develop/development/default). **No comment syntax**: `#release` is a valid branch name, so every non-blank line is a name, and one that names no existing branch BLOCKS rather than being skipped — a typo is not a narrower policy. It is also the durable answer for a non-conventional branch, since a remote HEAD can be deleted by a later command and this file cannot (forge-guarded). Held to the marker's standard — untracked, non-symlink, read through an O_NOFOLLOW walk — because a file naming NO branch is how an operator declares the repo has none, so a repo able to commit one could switch the gate off. With nothing discovered and no file at all, the gate blocks | `hooks/gate-scripts/ref-ff-gate.sh` |
| `pr-grind-auto-admin-solo.local` | Not a skip file — a per-repo operator-consent file for structurally-sole-admin repos. Bypasses no gate; self-revokes if a second approval-capable human appears | `skills/pr-grind/SKILL.md` |

To release a pending design-review token with a durable audit event rather than deleting it, run `scripts/design-clear.sh` (no args lists what is pending). Its `--skip <name>` mode drains the other direction — a spent skip file whose removal makes the next gate *stricter*.
