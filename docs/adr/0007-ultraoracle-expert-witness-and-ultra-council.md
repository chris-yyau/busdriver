# ADR 0007: UltraOracle as Repo-Grounded Expert Witness and Ultra-Council Escalation

## Status

Accepted — Phases 0–5 implemented. Phase 6 remains (not started).

## Tracking

- GitHub issue: https://github.com/chris-yyau/busdriver/issues/247

## Date

2026-06-25

## Context

Busdriver currently has several review/deliberation surfaces:

- `blueprint-review`: a design gate with external reviewer lenses and a fresh arbiter.
- `council`: a lightweight multi-perspective deliberation surface.
- `ultraOracle`: an optional ChatGPT Pro / GPT-5.5 Pro advisory path through the `oracle` CLI browser engine.
- Fable/Claude arbiter: the intended final convergence signal for blueprint-review.

The existing ultraOracle adapter is valuable and already provides an important safety boundary:

- a single adapter surface in `scripts/lib/ultra-oracle.sh`;
- typed statuses such as `ok`, `dispatched`, `timeout`, `error`, `skipped:user`, and `skipped:unavailable`;
- stale output cleanup before dispatch;
- `.rc` completion markers for background mode;
- bounded timeout handling;
- user-config-only enablement through `~/.claude/busdriver.json` rather than repo-controlled config;
- support for `--prompt-file` and `--context` paths, which are passed to the `oracle` CLI as files.

However, the current architecture can still create an authority problem: a high-status Oracle verdict may only have seen a Claude-written design/summary. That is useful as an advisory summary review, but it is not a repo-grounded expert review. If the system does not label this distinction, humans and arbiters may overweight Oracle output.

A dogfood ultra-council run was performed before this ADR was written:

- Run id: `ultra-council-20260625-160348`
- Voices: Agy Pragmatist, Codex Critic, Grok Researcher, Fresh Claude Skeptic, UltraOracle GPT-5.5 Pro
- Result: all voices completed after retrying the Fresh Claude Skeptic with a higher turn budget; UltraOracle completed with `rc=0`
- UltraOracle in that run received attached repo files, so under the labels defined below it was an `ORACLE_REPO_ATTACHED_REVIEW` (better than a pure summary review), but it was not yet a two-round `ORACLE_RETRIEVAL_REVIEW`.

The dogfood consensus was:

1. Add a direct `ultra-council` escalation surface.
2. Do **not** treat Oracle as vote #6.
3. Treat Oracle as a high-value expert witness with stronger evidence requirements.
4. Keep Fable/Claude arbiter as the final blueprint-review judge.
5. Build standalone `ultraoracle` workflow first, then promote stable pieces into the plugin.

The strongest dissent was that `council` already has an optional `ULTRA_ORACLE_COUNCIL_FORCE=1` path, so a new `ultra-council` surface may be mostly a naming/trigger convenience unless it also enforces evidence labeling and expert-witness rendering.

## Decision

Busdriver will model Oracle as an **expert witness**, not as a peer reviewer vote or final judge.

### Roles

| Surface / voice | Role | Gate authority |
| --- | --- | --- |
| Claude main session | Author / executor / orchestrator | Not final judge of its own plan |
| Agy / Codex / Grok | Lightweight reviewer lenses | Advisory; claims require evidence to become load-bearing |
| Council | Deliberation and perspective gathering | Not a gate |
| UltraOracle | High-cost repo-grounded expert witness | Advisory; high value only with evidence |
| Fable/Claude arbiter | Evidence-validating judge for blueprint-review | Final PASS/FAIL signal |

### Ultra-council semantics

`ultra-council` means:

```text
normal council
+ explicit UltraOracle expert-witness escalation
+ separate rendering of Oracle output
+ synthesis with settling checks
```

It does **not** mean:

```text
normal council now has six equal votes
```

Normal `council` remains lightweight. Oracle is triggered only when:

- the user explicitly asks for `ultra-council`, `ultra council`, or equivalent wording;
- the user explicitly asks to include Oracle in council;
- operator user config enables `ultraOracle.council.enabled`; or
- a future high-impact auto-escalation heuristic is implemented and tested.

Project/repo config must not silently enable ultraOracle. The user-only config boundary remains mandatory.

### Oracle review-type labels

Every Oracle result used by Busdriver must be labeled with one of:

| Label | Meaning | May influence final gate? |
| --- | --- | --- |
| `ORACLE_SUMMARY_REVIEW` | Oracle saw only a prompt, design, or Claude-authored summary | Only as weak advisory input |
| `ORACLE_REPO_ATTACHED_REVIEW` | Oracle saw raw attached repo artifacts/files selected before the call | Yes, after arbiter validation |
| `ORACLE_RETRIEVAL_REVIEW` | Oracle first requested files/searches, Busdriver retrieved them read-only, then Oracle gave final verdict | Yes, after arbiter validation |
| `ORACLE_FAILED` | Oracle was attempted but failed, timed out, or produced no usable verdict | No; render loud failure banner |

A repo-specific Oracle claim without file/path/search evidence must be marked ungrounded or downgraded, regardless of the model's confidence.

### Fable arbiter contract

Fable/Claude arbiter remains the final blueprint-review gate. It must not merely aggregate reviewer or Oracle outputs.

For every material claim from Agy, Codex, Grok, Oracle, or Claude main, the arbiter should:

1. verify the claim against repository evidence where possible;
2. classify it as `confirmed`, `rejected`, or `uncertain`;
3. record evidence such as `path:line`, command output, test output, or explicit missing evidence;
4. mark ungrounded claims explicitly;
5. inspect the repo directly to fill gaps;
6. decide `PASS` or `FAIL` only after validation. Per the upstream `skills/blueprint-review/SKILL.md` contract, mark `PASS` only when the arbiter's verdict has no HIGH/MEDIUM issues at confidence >= 0.5.

Oracle may raise high-value issues. Fable decides whether those issues are real and gate-blocking.

## Architecture

### Target flow for blueprint-review

```text
Claude main writes design / plan
        ↓
Build deterministic repo evidence pack
        ↓
Agy / Codex / Grok review design + evidence
        ↓
Optional UltraOracle expert-witness review
        ↓
Fresh Fable/Claude arbiter validates all material claims against repo
        ↓
PASS / FAIL
```

UltraOracle remains auxiliary and does not count toward formal reviewer coverage. Its output can be highly influential only when evidence-backed and validated by the arbiter.

### Target flow for ultra-council

```text
User asks for ultra-council
        ↓
Run normal council voices
        ↓
Run UltraOracle through `ultra_oracle_consult` with explicit force/escalation
        ↓
Render Oracle separately as Expert Witness
        ↓
Synthesize consensus, strongest dissent, Oracle evidence status, hard recommendations, and settling checks
```

### Target flow for standalone ultraoracle

Start as a user-local maintainer workflow/skill. It should standardize:

- when to call Oracle;
- how to build or attach evidence;
- how to label result type;
- how to parse/report failures;
- how to avoid sending secrets;
- how to distinguish summary review from repo-grounded review.

Modes should include:

- `quick`: prompt plus small explicit context, labeled summary unless raw files are attached;
- `repo`: deterministic repo evidence pack attached before the call;
- `upstream-audit`: compare Busdriver against selected upstream repos/capabilities;
- `retrieval-loop`: two-round Oracle-directed retrieval.

## Evidence pack requirements

A minimal repo evidence pack should be deterministic and auditable. It should include, when relevant:

- manifest with run id, repo root, git SHA, generation time, file list, byte budget;
- design or question text;
- git status and diff;
- changed files list;
- repo map / relevant tree;
- selected raw source files;
- search results;
- test and manifest summaries;
- upstream inventory when doing upstream audits.

The evidence pack must avoid secrets and should be generated from a read-only perspective wherever possible.

## Two-round Oracle retrieval loop

The preferred high-confidence protocol is:

### Round 1

Oracle receives a repo map/inventory and returns structured requests:

```json
{
  "needed_files": [
    { "path": "scripts/lib/ultra-oracle.sh", "reason": "Verify adapter semantics" }
  ],
  "search_queries": [
    { "query": "ultra_oracle_consult", "reason": "Find all call sites" }
  ],
  "cannot_assess_yet": ["Need the exact arbiter validation prompt"]
}
```

### Retrieval

Busdriver executes only read-only retrieval:

- read requested files under allowed roots;
- run bounded searches;
- record all retrieved evidence in a manifest;
- reject unsafe paths or secret-like files.

### Round 2

Oracle receives the requested evidence and returns:

```json
{
  "review_type": "ORACLE_RETRIEVAL_REVIEW",
  "files_examined": [],
  "searches_examined": [],
  "claims": [
    {
      "claim": "...",
      "evidence": ["path:line"]
    }
  ],
  "limitations": [],
  "verdict": "PASS|FAIL|UNCERTAIN"
}
```

`UNCERTAIN` is advisory-only: it never gate-blocks on its own. Downstream consumers treat it as an Oracle limitation rather than a verdict — the Fable/Claude arbiter still decides the final `PASS`/`FAIL` from arbiter-validated claims, and an `UNCERTAIN` Oracle result does not by itself force ultra-council escalation or require human intervention. It is recorded in the evidence trail so the arbiter can weigh the unresolved area.

## Rollout plan

### Phase 0: Dogfood first (Completed 2026-06-28)

Any major review-architecture change should be dogfooded through ultra-council once before implementation. This phase is complete: the dogfood run described in the Context section above satisfied the acceptance criteria below.

Acceptance:

- normal council voices run;
- UltraOracle is attempted or a loud failure is rendered;
- output records Oracle review type;
- strongest dissent and settling checks are captured.

### Phase 1: Standalone user-local `ultraoracle` (Completed 2026-06-29, PR #258)

Create a direct reusable workflow for maintainers before promoting it into the plugin.

Acceptance:

- can run quick/repo/upstream-audit modes;
- labels Oracle outputs;
- fails closed on missing cookie/session/output;
- documents what evidence was sent.

### Phase 2: Review-type labels and minimal evidence pack (Completed 2026-06-29, PRs #258–#259)

Add result labeling and deterministic evidence pack generation.

Acceptance:

- summary-only calls cannot be labeled repo reviews;
- attached-file calls record file manifest;
- tests cover label selection and stale-output handling.

### Phase 3: `ultra-council` explicit escalation (Completed 2026-06-30, PR #261)

Add a thin trigger/wrapper for normal council plus UltraOracle.

Acceptance:

- normal council remains lightweight by default;
- `ultra-council` forces/attempts Oracle;
- Oracle is rendered separately as Expert Witness;
- Oracle failure is loud and not silently ignored.

### Phase 4: Blueprint-review integration (Completed 2026-06-30)

Pass evidence and Oracle output into the Fable/Claude arbiter contract.

Wired in `skills/blueprint-review/scripts/run-design-review-loop.sh`: when
`ultraOracle.blueprintReview.enabled` is set in USER config, the loop dispatches
the oracle in parallel with Agy/Codex/Grok and injects its verdict into the
arbiter prompt under an `OPTIONAL ULTRA-ORACLE ADVISORY` block explicitly framed
as auxiliary ("*NOT* A REVIEWER… exactly THREE reviewers"). The arbiter
VALIDATION TASK re-states that the advisory is uncounted and instructs the
arbiter to validate every issue against the codebase with Read/Grep/Glob. A
failed/timed-out consult renders a loud banner and never blocks the gate. The
auxiliary contract that settling-checks #3/#4 depend on is locked by
`tests/test-blueprint-review-oracle-arbiter-contract.sh`.

Acceptance:

- Oracle remains auxiliary and uncounted toward reviewer coverage;
- arbiter validates material reviewer and Oracle claims;
- ungrounded claims are explicitly recorded;
- false Oracle file claims do not affect PASS/FAIL without validation.

### Phase 5: Two-round retrieval loop (Completed 2026-07-01)

Implement Oracle-directed retrieval after simpler evidence-pack mode is stable.

Acceptance:

- Round 1 produces requested files/searches;
- Busdriver retrieves read-only evidence with manifest;
- Round 2 produces `ORACLE_RETRIEVAL_REVIEW`;
- tests cover unsafe requested paths and empty/uncited verdicts.

The deterministic core — `retrieve-evidence.sh` (Round-1 read-only executor), `validate-retrieval-review.sh` (Round-2 fail-closed verdict validator), and the thin `run-retrieval-loop.sh` wrapper, all sharing the extracted `lib/evidence-safety.sh` secret/containment gates — is test-locked (`tests/test-ultraoracle-evidence-safety.sh`, `-retrieve.sh`, `-retrieval-review.sh`, `-retrieval-loop-contract.sh`). The live two-round GPT-5.5 Pro dispatch stays behind the USER-config, default-OFF `ultraOracle.blueprintReview.enabled` flag; the wrapper is verified by a static grep-anchored contract test only and CI never sets the flag, so no billed dogfood occurred this session.

### Phase 6: Optional auto-escalation

Consider auto-escalating blueprint-review to Oracle only for high-impact plans.

Examples:

- auth/security;
- data loss or migrations;
- public API compatibility;
- irreversible architecture;
- repeated reviewer disagreement.

Acceptance:

- heuristic is documented;
- false-positive rate is acceptable;
- user/operator can disable it.

## Consequences

### Positive

- Oracle becomes a high-signal expert witness rather than a high-status summary reviewer.
- Fable/Claude arbiter remains the clear judge of record.
- Council stays fast by default.
- Users get an explicit `ultra-council` escalation when they want a deeper external perspective.
- Review output becomes more auditable through labels, manifests, and claim evidence.

### Negative / costs

- More workflow complexity.
- Oracle calls are slow and may fail due to browser/session issues.
- Evidence pack generation adds maintenance burden.
- Retrieval-loop orchestration requires careful path/secret boundaries.
- Bad labels could create false confidence if not tested.

## Security and data-boundary requirements

- `ultraOracle` enablement remains user-only (`~/.claude/busdriver.json`).
- Repo-controlled config must not silently enable ChatGPT/Oracle transmission.
- Cookie/session paths are credential-bearing: only sanitized path basenames may appear in status messages, and full paths must never appear in logs or terminal output.
- Unreadable configured cookie/session paths fail closed.
- Secret-like files must never be included in evidence packs; there is no override path.
- Oracle requests in retrieval-loop mode are treated as untrusted; Busdriver chooses what to read and attach.

## Settling checks

These checks falsify the design if they fail:

1. **Ultra-council trigger check:** a forced ultra-council run must show normal council voices plus a separate UltraOracle Expert Witness section. If Oracle appears as vote #6, the design failed.
2. **Label check:** a summary-only repo-specific Oracle consult must be labeled `ORACLE_SUMMARY_REVIEW`. If it becomes `ORACLE_REPO_ATTACHED_REVIEW` or `ORACLE_RETRIEVAL_REVIEW`, the labeling contract failed.
3. **Arbiter validation check:** inject or simulate an Oracle advisory with one false file claim. Blueprint-review must reject the false claim; the final `PASS`/`FAIL` must depend solely on arbiter-validated claims.
4. **Coverage check:** Oracle output must not count toward formal reviewer coverage in blueprint-review.
5. **Retrieval check:** a claimed `ORACLE_RETRIEVAL_REVIEW` must include a trace where Oracle requested files/searches not present in the initial payload and Busdriver retrieved them read-only.
6. **Failure check:** if Oracle times out or writes no verdict, the report must render `ORACLE_FAILED` or a loud failure banner, not silently omit it.

## Revisit triggers

Revisit this ADR if:

- Oracle consistently changes correct outcomes in dogfood runs;
- Oracle latency/failure rate makes `ultra-council` unusable;
- Fable/Claude arbiter pinning changes or Fable becomes unavailable;
- ChatGPT/Oracle gains a safer direct repo connector;
- evidence-pack or retrieval-loop labels prove confusing in practice;
- normal council becomes too slow or noisy because of escalation behavior.
