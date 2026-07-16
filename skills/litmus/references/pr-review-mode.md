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

## Step 2: Read-Only Opus Security/Bugs Backstop

<EXTREMELY-IMPORTANT>
Dispatch the backstop **only when the Codex lead is clean** (Step 1 PASSED). If Codex FAILed, **short-circuit** — do not dispatch the backstop; fix the Codex findings and re-run Step 1 first.

Dispatch **exactly ONE** agent via the Agent tool, `agentType: pr-security-backstop` (NOT the old 6-agent fan-out). The agent is structurally read-only (`tools: Read, Grep, Glob` — no Write/Edit/Bash) and runs on Opus.

The agent has **no Bash and cannot run git.** You MUST inject the review material into its prompt — it must not infer the diff from the working tree.
</EXTREMELY-IMPORTANT>

**Capture the review material first** (you, not the agent, run git):
```bash
PR_BASE=${LITMUS_PR_BASE:-}
[ -z "$PR_BASE" ] && PR_BASE=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/||')
[ -z "$PR_BASE" ] && PR_BASE=origin/main
[[ -n "${LITMUS_PR_BASE:-}" && "$PR_BASE" != origin/* ]] && PR_BASE="origin/${PR_BASE}"
MERGE_BASE=$(git merge-base "${PR_BASE}" HEAD)

git diff "${MERGE_BASE}...HEAD"                 # full diff — inject verbatim
git diff "${MERGE_BASE}...HEAD" --name-only     # changed-file list
git log --oneline --stat "${MERGE_BASE}..HEAD" | head -n 200   # capped history

# reviewed_diff_hash — binds the backstop verdict to THIS diff. Compute it with
# the SAME formula the trusted writer and gate use (bare `git diff base...HEAD`,
# captured via printf '%s'); any other value is rejected fail-closed by
# --write-backstop-verdict, so do NOT hand-craft or placeholder it.
REVIEWED_DIFF_HASH=$(printf '%s' "$(git diff "${MERGE_BASE}...HEAD")" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
```

**Dispatch prompt** (inject the captured `MERGE_BASE`, full diff, changed-file list, and capped history into the placeholders — no literal placeholder may remain, and the diff must be carried in the prompt):
```text
You are a read-only Security/Bugs backstop for a pull request. You have NO Bash
and cannot run git — review ONLY the material provided below. Do NOT infer the
diff from the working tree.

MERGE_BASE: <MERGE_BASE>

## Changed files
<git diff MERGE_BASE...HEAD --name-only output>

## Commit history (capped)
<git log --oneline --stat MERGE_BASE..HEAD | head -n 200 output>

## Full diff (base...HEAD)
<git diff MERGE_BASE...HEAD output — verbatim>

Review the CHANGED code for security vulnerabilities and correctness bugs only:
hardcoded secrets, injection, auth bypass, SSRF, unsafe deserialization, path
traversal, leaked internals; plus logic errors, off-by-one, null/undefined, and
race conditions. This is an independent cross-model check of the Codex lead — be
adversarial about security.

Rules:
- Only report issues in CHANGED code, not pre-existing code.
- Confidence 0-100: 0=guess, 50=plausible, 80=likely real, 100=certain.
- Do NOT report issues already caught by linters/type checkers.
- Cosmetic findings (docs/comments, naming/style, "long but correct") are LOW —
  they never block. Severity reflects impact, not certainty.

Output ONE JSON object (severities are LOWERCASE — they must match the gate's
`high|medium|low` enum; `high` is the only blocking level):
{
  "status": "PASS" | "FAIL",
  "issues": [
    {"file": "path", "line": N, "severity": "high|medium|low",
     "confidence": 0-100, "category": "security|bug", "description": "..."}
  ]
}
status = "FAIL" if any issue is `high`, else "PASS".
If no blocking issues, return {"status": "PASS", "issues": []}.
```

**After the agent returns,** take its final message verbatim — by contract it is a
single JSON object `{status, issues[]}` with **lowercase** severities and nothing
else (no fences, no prose; if the agent wrapped it, strip to the bare JSON object).
You (the sole writer — the agent has no Write/Edit/Bash) then add `model` and the
`reviewed_diff_hash` you captured at dispatch, and pipe the result to the trusted
writer in Step 3a. No separate extraction or severity-mapping pass is needed: the
agent already emits the `high|medium|low` enum, and the writer validates strictly
and **fails closed** on any malformed or out-of-enum field.

## Step 3: Gate Decision

**The gate passes only when:** Codex lead PASS **AND** the backstop returns no `high` finding. The backstop blocks on **`high` severity alone** — `medium`/`low` are advisory, and `confidence` is recorded for triage but does **NOT** gate: the strict writer recomputes `status:FAIL` for ANY `high` issue regardless of confidence (an explicit FAIL is never overridden). A single `high` from either voice fails the gate (fix, then re-run the relevant step).

**3a. Write the backstop verdict artifact.** The trusted writer re-derives `diff_hash`/`ts` itself and **fails closed if `reviewed_diff_hash` ≠ the current `base...HEAD` hash** — a commit landing mid-review invalidates the verdict, so re-run:
```bash
# Set BACKSTOP_MODEL to the provider/model id used for this backstop session.
# Required — there is no portable CLI to query the live session model, and a
# wrong value poisons the audit trail, so fail fast rather than auto-detect.
: "${BACKSTOP_MODEL:?set BACKSTOP_MODEL to the provider/model id used for this backstop session}"
# Build the JSON with a real encoder, not string interpolation: a quote,
# backslash, or newline in the model value would otherwise produce invalid JSON
# and the strict writer would reject the artifact (blocking the PR path).

# Case A — no findings (agent returned {"status":"PASS","issues":[]}):
python3 -c 'import json,sys; print(json.dumps({"status":"PASS","model":sys.argv[1],"reviewed_diff_hash":sys.argv[2],"issues":[]}))' \
  "${BACKSTOP_MODEL}" "${REVIEWED_DIFF_HASH}" \
  | bash "${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts/run-review-loop.sh" --write-backstop-verdict

# Case B — agent found issues (AGENT_OUTPUT is the agent's verbatim final message
# per "After the agent returns" above — a single JSON object {status, issues[]}).
# DO NOT manually reconstruct issues[] from prose; take the agent output as-is
# and let the writer recompute status from it (any high ⇒ FAIL regardless of
# the supplied status field, which is advisory only and never overrides FAIL).
printf '%s' "${AGENT_OUTPUT}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); d.update({"model":sys.argv[1],"reviewed_diff_hash":sys.argv[2]}); print(json.dumps(d))' \
    "${BACKSTOP_MODEL}" "${REVIEWED_DIFF_HASH}" \
  | bash "${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts/run-review-loop.sh" --write-backstop-verdict
```
You supply only `{status, model, issues[]}` (plus `reviewed_diff_hash` for the TOCTOU bind) on stdin. The writer re-derives `diff_hash` and `ts`, **recomputes `status` from the issues** (any `high` ⇒ FAIL — the supplied `status` is advisory and an explicit FAIL is never overridden to PASS), validates strictly (every issue needs `{file,line,severity,confidence,category,description}`; `confidence` 0–100; `severity` in the `high|medium|low` enum; a hallucinated/missing severity ⇒ reject), and **exits nonzero without writing** on any violation. It writes atomically to `${BUSDRIVER_STATE_DIR:-.claude}/pr-backstop-verdict.local.json`.

**3b. Write the PR marker** (only after the artifact is written):
```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts/run-review-loop.sh" --write-pr-marker
```
`--write-pr-marker` requires **BOTH** a fresh `status:PASS` `pr-codex-lead` artifact **AND** a fresh `status:PASS` `pr-backstop-verdict` artifact, both with `diff_hash` matching the current `base...HEAD`. A backstop PASS alone cannot satisfy the gate if the Codex lead was skipped, misordered, or FAILed — and vice versa. It writes `.claude/pr-review-passed.local`. Direct writes to marker/artifact files are blocked by the PreToolUse hook — only the trusted writers can produce them.

| Result | Action |
|--------|--------|
| Codex PASS + backstop no `high` | Write artifact (3a) → write marker (3b) → gate passes |
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
