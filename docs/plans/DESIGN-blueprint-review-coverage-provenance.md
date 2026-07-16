<!-- design-reviewed: PASS -->
# DESIGN: blueprint-review coverage provenance / UNFULFILLED tracking

**Status:** spec for review (iter 3) · **Date:** 2026-06-06
**Origin:** 3-round council + evidence pass. See `~/.claude/notes/lesson-council-2026-06-06-blueprint-review-role-lensing.md`.

## Problem (measured, not hypothetical)

blueprint-review runs 3 reviewer backends (agy/codex/grok) then a Claude arbiter. Mining `docs/reviews/` (5 historical runs) showed a **degraded or empty backend was silently counted as "3 reviewers ran" in ~4 of 5 runs** (droid-fallback in 2/5; a reviewer returned 0 findings in 2 more). The gate misreports its own coverage. The arbiter adds only ~5% net-new findings, so it — not the 3 reviewers — is the real safety layer.

## Decision (settled)

Make coverage **honest and visible**. Do NOT role-differentiate the reviewers (no evidence it helps; the one full run shows the models already diverge under the identical prompt — deferred until this harness can measure overlap). Keep the arbiter and PASS/FAIL verdict logic unchanged.

## Non-goals

- FAIL: Role-lensing the reviewer prompts (deferred, evidence-gated).
- FAIL: Any change to the arbiter's verdict or the PASS/FAIL semantics.
- FAIL: Hard-blocking an individual review because one reviewer slot degraded.

## Implementation locations (canonical — all under `skills/blueprint-review/` unless noted)

| Root | Path |
|------|------|
| Resolver | `skills/blueprint-review/scripts/lib/resolve-cli.sh` (or wherever `resolve_role_cli` lives) |
| State lib | `skills/blueprint-review/scripts/lib/state_management.sh` |
| Review loop | `skills/blueprint-review/scripts/run-design-review-loop.sh` |
| Init | `skills/blueprint-review/scripts/init-design-review.sh` |
| Arbiter prompt | `skills/blueprint-review/prompts/claude_validation_prompt.txt` |
| User/agent contract | `skills/blueprint-review/SKILL.md` |
| Tests | `tests/test-blueprint-review-state.sh` (+ new cases) |

## The 5 HOW-decisions (resolved)

### D1 — Manifest shape, fulfillment rule, and source signals

**Fulfillment is keyed on EXECUTION STATUS, never on issue count.** A slot is **FULFILLED** iff its output JSON parses, has `status ∈ {PASS, FAIL}`, has a `metadata.run_id` matching the current run, AND the slot was not duplicate-collapsed, resolve-time-fallen-back, or runtime-droid-rescued. An empty `issues: []` with `status: PASS` is **fulfilled** (clean review — the reviewer contract uses empty issues for a clean pass).

`reason ∈ { ok, explicit-none, missing-cli, unsupported-cli, builtin, duplicate, resolve-droid-fallback, runtime-droid-rescue, runtime-failed, invalid-json, stale, missing-output }` (`ok` = fulfilled; all others = unfulfilled).

**Reason precedence** (first match wins, since signals overlap): `missing-output > invalid-json > stale > runtime-failed > resolve-droid-fallback > duplicate > runtime-droid-rescue > missing-cli > unsupported-cli > explicit-none > builtin > ok`. (A file must exist before it can be stale/unparseable; a duplicate-collapsed slot is classified `duplicate` even if its copy was a droid rescue — so the test asserts `duplicate + rescue → duplicate`.)

**Source signals — capture provenance WITHOUT touching the resolver's contract.** `resolve_role_cli` resolves via several paths (`BUSDRIVER_REVIEW_CLI` env override, route array, `defaults.primary`, `defaults.fallback`, builtin/ultimate) and returns only the final CLI on stdout. **Do NOT change that stdout** — it is a plugin-wide single-token contract that council, litmus, and blueprint-review all parse. Instead add a **separate read-only helper `describe_role_resolution <role>`** in the same lib that returns the record — `requested` (intended primary), `actual` (resolved CLI), `resolution_reason` (`ok` | `resolve-droid-fallback` | `builtin` | `missing-cli` | `unsupported-cli` | `explicit-none`). Only the blueprint-review loop calls it; `resolve_role_cli` stays byte-identical. Provenance is correct **by construction**, not inferred. Runtime signals layer on top: `metadata.runtime_escalated_from` (dispatch.sh droid rescue) → `runtime-droid-rescue`; `DUPLICATE_MODE`/`REVIEWER_3_DUPLICATE` → `duplicate`; bad/missing/stale output → the error reasons.

**Persisted to `state.md` at dispatch time (Phase 1)** so `--claude-only` derivation needs no runtime vars — `reviewer_N_requested`, `reviewer_N_actual`, and the resolve-time `reviewer_N_reason` (including `duplicate`) are written before reviewers run; `fulfilled` / final `reason` / `coverage_status` / `fulfilled_lens_count` are computed in the derivation step (post-Phase-2, also reachable in `--claude-only` from the reviewer JSONs + persisted fields):
```
# Coverage provenance
coverage_status: ""            # FULL | DEGRADED
fulfilled_lens_count: 0        # 0..3
reviewer_1_requested: ""       # intended primary from resolver record (e.g. agy)
reviewer_1_actual: ""          # resolved CLI (e.g. agy | droid | builtin)
reviewer_1_fulfilled: "false"  # "true" | "false" (quoted, matches get_state_field)
reviewer_1_reason: ""          # reason enum (resolve-time value persisted at dispatch; finalized at derivation)
# …reviewer_2_*, reviewer_3_* identically
coverage_history: "[]"         # per-ITERATION fulfilled_lens_count WITHIN this review (mirrors high_issues_history). Cross-review history is the trend file ONLY (D4).
```
"lens" naming is forward-compat; today lens ≡ reviewer slot.

**Migration:** `update_state_field` only rewrites EXISTING keys (silent no-op on legacy/resumed state). Add `_ensure_coverage_fields()` (mirrors `_ensure_medium_history_field` / `_ensure_grok_status_field`), idempotent, inserts the block preserving other frontmatter; call at the top of every coverage write.

### D2 — Arbiter wiring (exact injected text + insertion point)

In `run-design-review-loop.sh`, the `CLAUDE_PROMPT` heredoc (~L649–712) cats base prompt → `DESIGN_CONTENT` → reviewer JSON blocks. Insert **immediately after the base prompt, before `DESIGN_CONTENT`**:
```
## Coverage (reviewer provenance for THIS run)
reviewer_1: requested=<r1_req> actual=<r1_act> fulfilled=<bool> reason=<reason>
reviewer_2: requested=<r2_req> actual=<r2_act> fulfilled=<bool> reason=<reason>
reviewer_3: requested=<r3_req> actual=<r3_act> fulfilled=<bool> reason=<reason>
Coverage: <FULL|DEGRADED> (<n>/3 fulfilled).
Treat UNFULFILLED slots as ABSENT coverage: do NOT weight a duplicate / fallback / errored slot as independent agreement.
```
Plus one sentence in `claude_validation_prompt.txt`: *"If a `## Coverage` section marks a reviewer slot UNFULFILLED, treat that slot as absent — do not count it as independent agreement."*

### D3 — Where DEGRADED surfaces (durable, never silent)

1. `state.md` `coverage_status` (per-iteration).
2. Human-facing summary line at a **named site**: in `record_coverage_finalize()` (D4), via `log_warning` + `append_to_state`: `COVERAGE: DEGRADED — 2/3 (reviewer_3=resolve-droid-fallback)`.
3. **Durable marker (idempotent upsert):** `docs/reviews/` is gitignored, so on convergence write a persistent comment into the reviewed doc adjacent to the verdict marker — `<!-- design-review-coverage: DEGRADED 2/3 reviewer_3=resolve-droid-fallback -->` (FULL → `<!-- design-review-coverage: FULL 3/3 -->`). **Upsert, not append:** replace any existing `<!-- design-review-coverage: ... -->` line so re-runs don't duplicate it. Written by the **same single code path** that writes `design-reviewed: PASS` (hooked in `record_coverage_finalize()`). The verdict marker is unchanged (verdict ≠ coverage).

### D4 — Single finalize point + chronic-threshold

**Enumerate every terminal site** that sets a terminal status (`passed`, `low_issues_only`, early-stop, max-iter) and call one idempotent **`record_coverage_finalize()`** at each — a guard var (e.g. `COVERAGE_FINALIZED`) makes it run **at most once per review**. This is lighter and safer than refactoring the loop's control flow into a single chokepoint. It does, in order: emit the `COVERAGE:` line (D3.2), upsert the durable doc marker (D3.3), and **append once** `{"ts":...,"slug":...,"fulfilled_lens_count":N}` (JSONL) to `.claude/blueprint-coverage-trend.local` (gitignored; cross-review history). This fixes both the multi-iteration double-count and the "only mark_review_complete" miss. A test asserts it fires exactly once on each terminal path.

**`init-design-review.sh` chronic check (exact semantics):**
- Read the trend file. **Fewer than `BLUEPRINT_COVERAGE_MIN_STREAK` (default 3) entries → do nothing.**
- Last `MIN_STREAK` completed reviews all DEGRADED → loud advisory (`log_warning`) + write `.claude/blueprint-coverage-degraded.local`.
- **Non-blocking:** init completes normally, **exit 0, state initialized**. Advisory is informational only (no script gates on it). `BLUEPRINT_ACK_DEGRADED=1` suppresses + removes it. **Auto-clears** when a later completed review records FULL.

### D5 — Interaction with droid-dedup (unchanged; provenance reads its outcome)

`DUPLICATE_MODE` / `REVIEWER_3_DUPLICATE` stay as-is; the `duplicate` reason is persisted to `state.md` at dispatch so `--claude-only` derivation reads it (not the shell vars). Any duplicate-collapsed / skipped / droid / errored slot → `fulfilled=false`, excluded from `fulfilled_lens_count`. Empty *findings* with status PASS remain fulfilled (D1).

## Files touched

| File | Change |
|------|--------|
| `scripts/lib/resolve-cli.sh` | **new** read-only `describe_role_resolution()` helper returning `requested`/`actual`/`resolution_reason`; `resolve_role_cli` stdout UNCHANGED (shared single-token contract) |
| `scripts/lib/state_management.sh` | coverage block in `init_state_file`; `_ensure_coverage_fields()`; `update_coverage_provenance()`; `append_coverage_trend()` — mirror `high_issues_history` quoting/serialization discipline |
| `scripts/run-design-review-loop.sh` | persist `requested`/`actual`/resolve-`reason` at dispatch; derivation post-Phase-2 (also `--claude-only` from JSON+state); inject `## Coverage`; **new `record_coverage_finalize()`** routing all terminal transitions → `COVERAGE:` line + durable upsert + trend append; flag-guarded |
| `scripts/init-design-review.sh` | chronic check + advisory (flag-guarded) |
| `prompts/claude_validation_prompt.txt` | one sentence: treat UNFULFILLED as absent |
| `SKILL.md` | State Files (coverage block), Configuration (`BLUEPRINT_*` envs), Workflow/Output (`COVERAGE:` label + durable marker), Troubleshooting (chronic advisory) |
| `tests/test-blueprint-review-state.sh` | new cases (below) |

(All `scripts/`/`prompts/`/`SKILL.md` paths are under `skills/blueprint-review/`. No `.gitignore` change — `.claude/*.local` already covers it.)

## Flag guard

`BLUEPRINT_COVERAGE_PROVENANCE` (default `"1"`). When `"0"`/`"false"`, the coverage **behavior** is skipped — no resolver-record persist, no derivation, no `## Coverage` injection, no `record_coverage_finalize()` coverage work (trend/marker/COVERAGE line), no chronic check. The inert empty coverage block may still be present in `state.md` (harmless, unread); existing verdict/iteration flow is otherwise unaffected. Documented in SKILL.md Configuration.

## Test plan (`tests/test-blueprint-review-state.sh`)

Behavioral:
- resolver record: requested=grok actual=droid → `resolve-droid-fallback`; env-override/`defaults.primary`/builtin paths each yield the correct `requested`/`actual`/reason.
- runtime rescue (`metadata.runtime_escalated_from=agy`) → `runtime-droid-rescue`; **reason precedence** when signals overlap (duplicate + rescue → `duplicate` per order).
- **`issues=[]` + `status=PASS` → FULFILLED** (iter-1 regression guard).
- `status=ERROR` / missing / stale run_id → correct error reason.
- all 3 ok → `FULL` count=3; verdict-unaffected (DEGRADED run can still PASS).
- `record_coverage_finalize()` fires once on each terminal path (passed / low_issues_only / early-stop / max-iter); durable marker **upsert** (re-run doesn't duplicate); `--claude-only` derives duplicate + coverage from persisted state.
- chronic: <MIN_STREAK → no advisory; MIN_STREAK consecutive DEGRADED → advisory+file; `BLUEPRINT_ACK_DEGRADED=1` suppresses; later FULL auto-clears; trend appends once per completed review.
- flag off → no coverage behavior, existing flow intact.

Serialization invariants (mirror the prior `high_issues_history` bug class): `coverage_history` single-line invariant; multi-line corruption → reset `[]`; unparseable prefix → reset; python-injection via heredoc neutralized; `_ensure_coverage_fields()` idempotent on legacy `state.md`.

## Rollout

Default-on; kill-switch `BLUEPRINT_COVERAGE_PROVENANCE=0`. A correctness fix, not a behavior gamble — one release behind a flag is cheap insurance. The persisted trend becomes the dataset that later lets us revisit role-lensing on evidence.
