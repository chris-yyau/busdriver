# PR Review Mode (Deep — Codex + enforced security backstop)

> Loaded on demand by `litmus/SKILL.md` when the pre-PR gate blocks `gh pr create`. Not needed on the common commit path. The shared env-var configuration stays in `SKILL.md`.

When the pre-PR gate blocks `gh pr create`, run the full deep review. **Codex (xhigh reasoning) owns the deep multi-lens pass over the whole `base...HEAD` diff; a single read-only Opus agent acts as an independent cross-model security/bugs backstop.** The gate passes only when BOTH voices are clear — enforced by machine-checked artifacts, not prose.

The flow is:

1. **Step 0.5** — always run the Codex lead (no agents-only skip).
2. **Step 1** — Codex deep multi-lens pass on `base...HEAD`.
3. **Step 1.5** — scope-drift detection (advisory, never blocks).
4. **Step 2** — dispatch exactly ONE read-only Opus security/bugs backstop, **only when Codex is clean** (short-circuit if Codex FAILs).
5. **Step 3** — gate = Codex PASS AND backstop has no `high` finding (any `high` ⇒ FAIL; confidence does not gate); write the backstop artifact, then the PR marker.

## Fast Path (codex-only, audited bypass)

Only when the user explicitly asks to skip the backstop:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts/run-review-loop.sh" --auto-pr-review
```
`--auto-pr-review` **IS** the audited fast bypass: it force-inits, runs the Codex deep pass with `LITMUS_PR_FAST=1`, and on a Codex PASS writes a **distinct, diff-bound** `PASS-FAST-<diff_hash>-<epoch>` marker (not a bare hash, not a bare timestamp), logged `pr-fast-bypass` to `.claude/bypass-log.jsonl`. It **SKIPS the independent backstop**. The gate accepts that marker ONLY through its explicit fast-bypass branch — requiring `diff_hash == current base...HEAD` **and** `0 ≤ now-epoch ≤ max_age` — never through the normal dual-artifact path. So a preserved fast marker (a failed `gh pr create` keeps markers) cannot later authorize a *changed* diff. This is an audited bypass, not the default — the default path runs both voices and is fully gated.

A sibling marker, **`PASS-EXCLUDED-<diff_hash>-<epoch>`**, is written by the all-excluded auto-pass path when the **entire** `base...HEAD` diff is excluded from review (lockfile/rules/manifest-only PRs) — **no** reviewer ran because nothing was reviewable. Logged `pr-excluded-only-autopass`. The gate accepts it through the **same** fast-bypass branch (same `diff_hash == current` **and** max-age checks), so adding any reviewable file changes the hash and forces a real review. Distinct from `PASS-FAST` (which means the Codex lead ran, backstop skipped). This unblocks excluded-only branches from `gh pr create` (#226).

## Step 0.5: Always Run the Codex Lead

In PR mode the Codex lead runs on **every** PR. There is no agents-only skip — the deep multi-lens pass over the full `base...HEAD` diff is structurally different from the per-commit single-diff reviews, and the gate cannot pass without a fresh `status:PASS` Codex-lead artifact.

PR mode pins the lead to Codex and disables the silent droid fallback before the review runs:
```bash
export LITMUS_CODEX_DROID_FALLBACK_DISABLED=1
```
The lead **must** resolve to `codex` (`RESOLVED_CLI=codex`). If Codex is unavailable and the chain would fall to builtin (Sonnet), the PR-mode lead is **inconclusive/fail-closed** — a builtin or any non-Codex lead is rejected, never silently accepted (see Degraded States).

## Step 1: Codex Deep Multi-Lens Pass

```bash
# Initialize and run in PR mode (deep pass over base...HEAD)
LITMUS_MODE=pr bash "${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts/init-review-loop.sh"
LITMUS_MODE=pr bash "${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts/run-review-loop.sh"
```

The PR heredoc instructs Codex to review the full `base...HEAD` diff through six lenses in a single pass:

| Lens | Focus |
|------|-------|
| **Bugs** | Logic errors, off-by-one, null/undefined, race conditions in changed code |
| **Security** | Hardcoded secrets, injection, auth bypass, error messages leaking internals, unsafe dependencies |
| **Cross-commit** | Inconsistent naming across commits, partial migrations, orphaned imports, incomplete renames |
| **Guidelines** | CLAUDE.md compliance, project conventions, naming consistency |
| **History** | Reverted changes, contradictory commits, partial refactors — driven by the injected `{{HISTORY_CONTEXT}}` (a capped `git log --oneline --stat MERGE_BASE..HEAD`); the prompt references the injected data and never runs git itself |
| **Docs** | README/SKILL.md/docs accuracy vs changed code — stale examples, wrong signatures, missing new features |

**Severity calibration (cosmetic → LOW):** CRITICAL/HIGH are reserved for correctness, security, data-loss, or interface-breaking risks. Documentation gaps, missing/weak docstrings or comments, naming and style nits, and "function is long but correct" observations are **LOW** — advisory, and they **never** trip the FAIL rule. Severity reflects *impact*, not certainty: do not inflate a cosmetic finding because confidence is high.

On a clean Codex pass, `run-review-loop.sh` writes a diff-bound Codex-lead artifact (`pr-codex-lead.local.json`, `{status, diff_hash, ts}`) via a trusted writer and defers the PR marker to Claude ("Claude Security/Bugs backstop pending"). If Codex FAILs → fix and re-run (same auto-continue loop as commit mode), then re-run Step 1. **Do not proceed to Step 2 while Codex is FAILing.**

## Step 1.5: Scope Drift Detection (Advisory)

Before dispatching the backstop, check whether the branch stayed aligned with its stated intent. This is **advisory only** — it flags deviations but never blocks.

**Step 1.5a: Find the plan.** Use Glob to search for intent documents: `docs/plans/*.md`, `docs/specs/*.md`, and top-level `PLAN.md`/`DESIGN.md`/`ARCHITECTURE.md`. Skim each candidate to find the one most relevant to this branch (matching branch name, feature description, or commit subject). If no intent document exists or none is clearly relevant, skip scope drift detection silently.

**Step 1.5b: Gather intent and changes.** Read the matched plan file. Also read `TODOS.md` (if it exists), commit messages, and PR description. Gather the actual diff by computing the merge-base explicitly:
```bash
PR_BASE=${LITMUS_PR_BASE:-}
[ -z "$PR_BASE" ] && PR_BASE=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/||')
[ -z "$PR_BASE" ] && PR_BASE=origin/main
# Auto-prefix origin/ if bare branch name provided
[[ -n "${LITMUS_PR_BASE:-}" && "$PR_BASE" != origin/* ]] && PR_BASE="origin/${PR_BASE}"
MERGE_BASE=$(git merge-base "${PR_BASE}" HEAD)
git log --oneline "${MERGE_BASE}..HEAD"
git diff "${MERGE_BASE}..HEAD" --stat
gh pr view --json body -q .body 2>/dev/null || true
```

**Step 1.5c: Compare and flag two categories:**

**1. Scope creep** — files changed that are unrelated to the plan:
- For each changed file, check if it (or its parent directory) is mentioned anywhere in the plan
- Exempt: `.claude/`, `CLAUDE.md`, `docs/`, config files, and test files accompanying planned changes
- Frame as: "These files were changed but aren't mentioned in the plan: [list]. Intentional?"

**2. Missing requirements** — plan items with no corresponding changes:
- Read the intent document and extract all file paths mentioned (in task sections, file listings, code blocks, or inline references)
- Check which of those file paths appear in the diff
- Frame as: "These planned files have no matching changes in the diff: [list]. Deferred or forgotten?"

**Output format:**
```text
## Scope Drift Check (advisory)

### Unplanned changes
- `path/to/file.ts` — not referenced in plan (explain or trim)

### Missing from plan
- Task 3 (auth middleware) — `src/middleware/auth.ts` not in diff

### Verdict: [CLEAN | DRIFT DETECTED]
```

**Important:** This is "explain or trim" framing, not "you violated scope." Legitimate opportunistic fixes are fine. The value is surfacing the gap so the developer can consciously decide, not punishing agility.

## Step 2: Read-Only Opus Security/Bugs Backstop (captured dispatch)

<EXTREMELY-IMPORTANT>
Run the backstop **only when the Codex lead is clean** (Step 1 PASSED). If Codex FAILed, **short-circuit** — fix the Codex findings and re-run Step 1 first.

Do NOT dispatch the backstop via the Agent tool and retype its verdict into a writer. A hand-typed security verdict is indistinguishable from a fabricated one — it is the orchestrating model marking its own required check (#350). The Codex lead avoids this because `run-review-loop.sh` captures its stdout directly; the backstop must be captured the same way. Run the single command below — it dispatches the read-only backstop as a **captured `claude -p` subprocess** and pipes its stdout straight to the trusted writer. You never see or retype the verdict.
</EXTREMELY-IMPORTANT>

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts/run-review-loop.sh" --run-backstop
```

This one command (all inside the trusted script — the orchestrating model is not in the evidence path):

- verifies a fresh Codex-lead PASS artifact exists for the current `base...HEAD` (else fail-closed — run Step 1 first);
- captures the full diff, changed-file list, and capped commit history via git (the agent has **no Bash** and reviews only the injected material);
- dispatches `claude -p --model opus --tools "Read,Grep,Glob" --allowedTools "Read,Grep,Glob" --permission-mode dontAsk --append-system-prompt <pr-security-backstop.md body> --output-format json` — read-only is enforced **structurally** by `--tools` (which limits the tools that *exist* in the session, so Bash/Write/Edit are unavailable regardless of any inherited/repo-committed permission settings — `--allowedTools` alone only auto-approves and would not stop an injected diff reaching a mutation tool), with a fail-closed capability guard that refuses to dispatch if `claude` lacks `--tools`; `--model opus` preserves the cross-model property (an Anthropic-family backstop checks the OpenAI Codex lead);
- extracts the agent's JSON verdict from the envelope, binds it to the computed `reviewed_diff_hash`, and pipes it to an **internal** trusted writer (same strict validation: any `high` ⇒ FAIL, TOCTOU-bound, atomic write). There is **no public `--write-backstop-verdict` subcommand** — the writer is reachable only from `--run-backstop`, so the verdict cannot be produced by hand-typed JSON (that retype path was the #350 hole);
- **fails closed** on any dispatch/parse failure (missing `claude`, non-zero exit, empty/malformed output, timeout) — no artifact is written, so the gate stays blocked.

On success it writes `pr-backstop-verdict.local.json` (the Step 3a artifact) directly; go straight to Step 3b. Tunables: `LITMUS_PR_BACKSTOP_TIMEOUT` (default 600s), `LITMUS_PR_BACKSTOP_MAX_DIFF` (oversize ⇒ fail-closed).

## Step 3: Gate Decision

**The gate passes only when:** Codex lead PASS **AND** the backstop returns no `high` finding. The backstop blocks on **`high` severity alone** — `medium`/`low` are advisory, and `confidence` is recorded for triage but does **NOT** gate: the strict writer recomputes `status:FAIL` for ANY `high` issue regardless of confidence (an explicit FAIL is never overridden). A single `high` from either voice fails the gate (fix, then re-run the relevant step).

**3a. Backstop verdict artifact — written by `--run-backstop` (Step 2).** The captured dispatch pipes the agent's verdict to the trusted writer, which re-derives `diff_hash`/`ts` itself and **fails closed if `reviewed_diff_hash` ≠ the current `base...HEAD` hash** (a commit landing mid-review invalidates the verdict → re-run Step 2). The writer **recomputes `status` from the issues** (any `high` ⇒ FAIL — the agent's `status` is advisory and an explicit FAIL is never overridden to PASS), validates strictly (every issue needs `{file,line,severity,confidence,category,description}`; `confidence` 0–100; `severity` in the `high|medium|low` enum; a hallucinated/missing severity ⇒ reject), and **exits nonzero without writing** on any violation. It writes atomically to `${BUSDRIVER_STATE_DIR:-.claude}/pr-backstop-verdict.local.json`. The writer is an **internal function** (`_persist_backstop_verdict`) invoked only from `--run-backstop` — there is no public `--write-backstop-verdict` subcommand. This removes the honest-path retype forge of #350 (the permission classifier refused a hand-typed verdict, which forced bypasses); it is **not** a hard boundary — an orchestrator with Bash can still fabricate a verdict (source the function, stub `claude`, inject via `CLAUDE.md`), the accepted **ADR 0006** "Claude is the trusted dispatcher" residual that applies equally to the Codex lead.

**3b. Write the PR marker** (only after the artifact is written):
```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts/run-review-loop.sh" --write-pr-marker
```
`--write-pr-marker` requires **BOTH** a fresh `status:PASS` `pr-codex-lead` artifact **AND** a fresh `status:PASS` `pr-backstop-verdict` artifact, both with `diff_hash` matching the current `base...HEAD`. A backstop PASS alone cannot satisfy the gate if the Codex lead was skipped, misordered, or FAILed — and vice versa. It writes `.claude/pr-review-passed.local`. Direct writes to marker/artifact files are blocked by the PreToolUse hook — only the trusted writers can produce them.

| Result | Action |
|--------|--------|
| Codex PASS + backstop no `high` | Run `--run-backstop` (writes the 3a artifact) → write marker (3b) → gate passes |
| Codex PASS + backstop any `high` | Report findings. Fix, then re-run from Step 1 (a code fix changes the `base...HEAD` hash, staling the Codex-lead artifact — re-running Step 2 alone cannot rebind it, so the backstop write / PR marker would fail closed) |
| Codex FAIL | Short-circuit (no backstop). Fix, re-run from Step 1 |

The marker is a SHA-256 hash (64 hex chars) of the `base...HEAD` diff, or one of the audited diff-bound bypass markers `PASS-FAST-<diff_hash>-<epoch>` (codex lead ran, backstop skipped) / `PASS-EXCLUDED-<diff_hash>-<epoch>` (entire diff excluded from review, no reviewer ran). The gate rejects `DEGRADED`, `SKIPPED-NONE`, and `BUILTIN-` prefixed markers for PR review.

## Degraded States

PR mode is **fail-closed**. A degraded path never silently downgrades to a weaker voice.

| Failure | Handling |
|---------|----------|
| Codex transient error (rate-limit, network, 5xx) | Codex retries with backoff. **In PR mode the droid escalation is DISABLED** (`LITMUS_CODEX_DROID_FALLBACK_DISABLED=1` is set before review), so an exhausted Codex falls to builtin — which PR mode rejects — leaving the lead inconclusive/fail-closed; re-run once Codex is healthy. (Commit-mode litmus still escalates to `droid exec`.) |
| Codex/droid both exhausted → would fall to builtin (Sonnet) | **Inconclusive/fail-closed.** `LITMUS_CODEX_DROID_FALLBACK_DISABLED=1` is set in PR mode so a failed Codex falls to builtin, which PR mode rejects — it never falls silently to droid as the *lead*. A builtin/non-Codex lead is never accepted; log degraded and surface to the user |
| Non-Codex lead resolved (e.g. `BUSDRIVER_REVIEW_CLI=droid`/`agy`) | **Inconclusive/fail-closed** — the PR normal path requires `RESOLVED_CLI=codex` |
| Backstop agent times out or errors | **Inconclusive/fail-closed** — no artifact written, gate stays blocked. Re-dispatch |
| Diff exceeds `LITMUS_PR_BACKSTOP_MAX_DIFF` | **Inconclusive/fail-closed** — never silently truncated into a PASS. Split the PR (mirrors Codex's large-diff handling); a truncation marker + size are recorded |

## Benchmark Mode (opt-in, non-gating)

> **Status: planned follow-up — NOT yet wired.** This section is the *spec* for the
> benchmark, not a description of current behavior: `run-review-loop.sh` does not yet
> dispatch `LITMUS_PR_BENCHMARK`, so setting it currently has no effect. It is
> deliberately deferred (ADR 0006): its only purpose is to gather data on whether a
> third model family earns a gating seat — a question CLAUDE.md marks SETTLED for this
> solo repo — so building it now would be speculative. Implement it only when a real
> measurement need appears; the contract below is what to build to.

`LITMUS_PR_BENCHMARK` would run additional CLIs (Agy, Grok) as **observers** for measurement only — they would **never** affect the gate exit code, artifact, or marker.

```bash
# unset = off (default); 1 = agy,grok; or a comma list
export LITMUS_PR_BENCHMARK=agy,grok
```
After the gating Codex pass, each benchmark CLI runs via `execute_review` (isolated `BUSDRIVER_STATE_DIR`, per-`diff_hash` lock so the same diff is not re-dispatched) through its **own read-only extractor** (decoupled from the gating validator). Results append atomically to `.claude/pr-review-benchmark.jsonl`:
```text
{ts, diff_hash, cli, status, high_count, medium_count, issues[]}
```
Even a benchmark CRITICAL leaves the gate untouched — the marker is still written if Codex + backstop are clean.

**Comparison recipe:** to measure whether a third model family ever earns a gating seat, replay merged PRs with `LITMUS_PR_BENCHMARK` set, then compare net-new true positives across CLIs via:
```bash
bash scripts/litmus-metrics-report.sh
```
Use the benchmark JSONL + metrics report to decide if a family's *net-new* catches justify the cost before promoting it into the gate.

## User-Created Skip File

The emergency escape hatch is a user-created `.claude/skip-litmus.local` file that exits 0 ahead of all backstop logic — the one intentional, audited bypass, consistent across all busdriver gates. (The env-based `SKIP_LITMUS` skip was removed in #325 / ADR 0016; gate env is now sanitized.) See `SKILL.md` → "User-Created Skip File" for the per-gate table (pre-PR deletes the file on a <30s rejection) and `skills/blueprint-review/SKILL.md` for the canonical verbatim protocol.
