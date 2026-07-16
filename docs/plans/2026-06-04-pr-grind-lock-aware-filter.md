# PR-Grind / Pre-Merge-Gate Check-Filter Unification (Issue #154)

> **Status:** Draft (design review iteration 3 — security decoupled per operator decision)
> **Date:** 2026-06-04
> **Issue:** #154 — pr-grind / pr-grinder still use old advisory-pattern filter
> **Location:** busdriver plugin (`scripts/`, `hooks/gate-scripts/`, `skills/pr-grind/`, `agents/pr-grinder.md`, `.github/workflows/tests.yml`)

## Problem

PR #155 made `hooks/gate-scripts/pre-merge-gate.sh` **lock-aware**: when
`.github/required-checks.lock` declares a non-empty `required[]`, only failures of
those named checks block the merge gate (allowlist mode); otherwise it strips an
`ADVISORY_PATTERN` ("CodeScene") and counts failures on the remainder.

Three other sites still embed **only** the old advisory-pattern grep as their
canonical "did checks pass?" logic:

- `skills/pr-grind/SKILL.md:788` — Step 1 Phase 2.5 (inline path)
- `skills/pr-grind/SKILL.md:1125` — Completion verify-checks-green block
- `agents/pr-grinder.md:79` — worker Phase 2.5

### Impact (verified live on this repo)

`busdriver` ships `.github/required-checks.lock` with `required[] = {shellcheck,
commitlint, Actions security, Code security, Dependency CVEs, IaC misconfig}`.
Non-required checks that run (`Shell script quality`, `version-drift`, `changes`,
advisory bots beyond CodeScene) are gate-allowed to fail but pr-grind-blocked, so
the operator must drop `skip-pr-grind.local` to merge PRs the gate already allows.

**There is also a latent no-lock divergence:** the gate's python parses the
**status column** (`line.split("\t")[1]`), while the current pr-grind snippets
`grep`-the **whole row** — so a passing check with "fail" in its URL/name is
miscounted by pr-grind but not the gate, even with no lock. Unifying fixes this.

## Goal

One implementation of the lock-aware filter, invoked from all four call sites, so
pr-grind/pr-grinder agree with the gate on which check failures (and pendings)
count. **Scope is the filter unification only** (see Security posture).

## Security posture (decoupled — operator decision 2026-06-04)

This PR does **not** change the merge gate's security posture and does **not**
touch `required-checks.lock` or branch protection. Rationale: the gate already
does not block on `Secret scanning` / `GitGuardian Security Checks` (they are not
in `required[]`), so unifying pr-grind to the gate does not weaken merge-time
security — it only removes pr-grind's *redundant* extra strictness, which the gate
overrides anyway. Making those scanners actually merge-blocking is a separate,
deliberate change (lock entry + remote branch-protection context update, with its
own verification) and is tracked as a **follow-up issue**, not bundled here. (The
design review confirmed bundling would add remote-state mutation that cannot ship
in a PR diff and a `check-required-checks.sh` verification gap for external-app
checks.) A code-level "security floor" inside pr-grind is rejected: it would
re-introduce the gate↔pr-grind divergence #154 exists to remove.

## Design

### Extract a shared script (mirrors `scripts/ack-ledger.sh`)

The lock-aware parser inlined as `_relevant_check_counts`
(`pre-merge-gate.sh:44-103`) moves into `scripts/relevant-check-status.sh`. The
parser's **count-computation logic is preserved unchanged** (same lock read,
status-column parse, tab-line filter, name normalization, `kept`/`failed`/
`pending` derivation). It is **NOT a pure verbatim copy** — two additions are
explicit (flagged by review to avoid an implementer copying the body unchanged):
(1) **additive row emission** — after the existing `print(f"{failed} {pending}
{mode} {kept}")` count line, the parser also prints the kept-and-failed rows
(lines 2..N) when `failed>0`; (2) a **bash wrapper** for argv defaulting, the
self-resolver, and fail-CLOSED behavior. Provenance comment:
`# count logic from hooks/gate-scripts/pre-merge-gate.sh:44-103 (PR #155); row emission added`.
The gate keeps `# filter logic: see scripts/relevant-check-status.sh`.

Header documentation density matches `ack-ledger.sh`.

**Wrapper requirements (from review — all TDD-covered):**
- **Always pass python `argv[2]`** (the advisory pattern). Default `"CodeScene"`;
  override via `$2` or `RELEVANT_CHECK_ADVISORY_PATTERN`. Never invoke python with
  a missing argv[2] (the original reads `sys.argv[2]` → `IndexError` otherwise).
- **Empty-pattern guard:** if the resolved advisory pattern is empty, reset to
  `"CodeScene"`. An empty regex matches every row → all checks filtered → `kept=0`
  → spurious bootstrap block.
- **`set -e` safety:** do not let a missing/failing `python3` propagate a non-zero
  exit. Trap/guard so the script **always exits 0** emitting the conservative line.
- **python3 dependency:** the parser stays python (verbatim extraction; a bash/awk
  rewrite is out of scope). This adds python3 to the pr-grind/worker paths (were
  pure bash/grep). Documented in SKILL.md (call-site checklist); missing python3
  yields a conservative *block*, never a bypass.

### Self-resolver — enumerated prose edits (not a blind s///)

Copy `ack-ledger.sh`'s self-resolver, then rewrite:
1. exec/target paths → `scripts/relevant-check-status.sh`.
2. disable env var `BUSDRIVER_DISABLE_ACK_SELF_RESOLVE` →
   `BUSDRIVER_DISABLE_RELEVANT_CHECK_SELF_RESOLVE` (header + the guard).
3. `-ef` test `"$_self_dir" -ef "$_git_root/scripts"` — already correct, keep.
4. rationale prose referencing ack-ledger PR-#79/#139 → rewrite to this script's
   purpose; the `chris-yyau/busdriver` remote regex stays.

### Resolution + the repo-dir argument (fixes the `$REPO` bug)

The helper's **first argument is the repo-root directory** used to locate
`<dir>/.github/required-checks.lock` — NOT the repo *name*. Each caller must pass
the checkout root, not `$REPO`/`$OWNER`:

| Caller | Context | Invocation (repo-dir + script path) |
|--------|---------|-------------------------------------|
| `pre-merge-gate.sh` | hook | `bash "$script_dir/../../scripts/relevant-check-status.sh" "$REPO_DIR"` — `REPO_DIR` is the already-resolved git root; `script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)` |
| pr-grind `SKILL.md` (×2) | bash in consumer repo | `bash "${CLAUDE_PLUGIN_ROOT}/scripts/relevant-check-status.sh" "$(git rev-parse --show-toplevel)"` (worktree mode uses `$WORKTREE_DIR`). **Do NOT pass `$REPO`** — that resolves the lock at `./busdriver/.github/...` and silently falls back to `mode=all`. |
| `pr-grinder.md` | worker bash | same; pass `$WORKTREE_DIR` |

Self-resolver note (review): `ack-ledger.sh`'s self-resolver is **CWD-based**
(`git rev-parse --show-toplevel`). The gate hook fires *before* the user's
`cd … && gh pr merge`, so the hook's CWD may not be the target checkout. This only
affects whether the working-tree copy is preferred during dogfooding; correctness
(finding the lock) depends on the **explicit `$REPO_DIR` argument**, which the gate
already resolves. Acceptable: the explicit arg is authoritative; the self-resolver
is a dogfood convenience, fail-safe to the cached copy.

`${CLAUDE_PLUGIN_ROOT}` is inline-substituted into markdown at load time — not a
bash env var (verified PR #168); `ack-ledger.sh`'s call site relies on this.

### Output contract (gate `read` stays UNCHANGED — 4-field line 1)

The gate consumes the filter via `read -r FAILED PENDING MODE KEPT <<<"$COUNTS"`
(lines 318-319, 376-377) with non-empty guards (323-325, 384) and a `KEPT>0`
bootstrap guard (338, 386). **Line 1 keeps the existing 4-field shape** so the
gate `read` is untouched (no arity break, no cached-vs-working-tree skew):

- **Line 1:** `<failed> <pending> <mode> <kept>` — four space-separated tokens,
  `mode ∈ {required, all}`. Identical to today's output.
- **Lines 2..N (optional):** the kept-and-failed `gh pr checks` rows **verbatim**
  (tab-separated, exactly what `$REQUIRED | grep fail` surfaces today). Emitted
  only when `failed > 0`. `read … <<<` consumes only line 1, so these never affect
  the gate parse. No external check name reaches line 1 → no injection.

`advisory_failed` is **not** added to the helper output; pr-grind's cosmetic
"N advisory checks failing" message stays a local CodeScene grep on its own
`$CHECKS_RAW` (mode-independent FYI, not a gate decision).

**Caller changes:**
- Gate (×2): no read change. Inline python replaced by
  `COUNTS=$(printf '%s\n' "$CHECKS_OUTPUT" | bash "$SCRIPT" "$REPO_DIR" 2>/dev/null || printf '1 0 all 0\n')`.
- pr-grind/pr-grinder (×3): replace the inline advisory grep with the helper call
  (passing the repo-root dir); read `FAILED PENDING MODE KEPT` from line 1;
**replicate the gate's guards** (empty-var, `KEPT>0`, `PENDING==0`) so
  `0 0 required 0` is NOT treated as clean; use `tail -n +2` for the failing-row
  echo and the worker's `RESULT_REMAINING` fold; update the `pr-grinder.md:88`
  prose that references `$REQUIRED`.
- **Pending wait loops** (SKILL.md Phase 2, pr-grinder Phase 2): switch the
  "still pending?" decision from raw `grep -c "pending"` to the helper's
  lock-aware `PENDING` (line 1, field 2). NOTE: Phase 1's
  `gh pr checks --watch` still waits on all GitHub checks (it has no allowlist
  knob); the lock-awareness applies to the *decision* loop, not the `--watch`
  wait. Documented as a known minor latency caveat, not a correctness issue.

**Fail-CLOSED contract:** script always exits 0; on any internal error emits
`1 0 all 0` (failed≥1 ⇒ block; kept=0 ⇒ bootstrap guard). Caller idiom:
`… || printf '1 0 all 0\n'`. kept=0 in `required` mode ⇒ bootstrap-block; empty/
malformed lock ⇒ `mode=all`.

### Authority Hierarchy doc update (exact prose)

`skills/pr-grind/SKILL.md:24` → replace with:
`- Required status checks: green — per .github/required-checks.lock required[]
when present (allowlist: only those names block); otherwise all checks except
ADVISORY_PATTERN/CodeScene (advisory fallback). The lock is the single source of
truth for both the pre-merge gate and pr-grind, computed by
scripts/relevant-check-status.sh.`
(The Invariant paragraph at SKILL.md:38 stays intact.)

## Test Plan

### New: `tests/test-relevant-check-status.sh` (+ fixtures)

Move R1–R8 out of `test-pre-merge-gate.sh:698-861` (which `eval`s the function
body) and invoke the **external script via stdin**:

1. Lock present, required fails → `failed=1 mode=required`.
2. Lock present, only non-required fails → `failed=0 mode=required`.
3. Lock present, required pending → `failed=0 pending=1 mode=required`.
4. No lock → advisory fallback (`mode=all`).
5. Malformed lock → advisory fallback.
6. Empty `required[]` → advisory fallback.
7a. Whitespace-padded names match. 7b. "fail"-in-URL not counted. 7c. Multi-word name exact match.
8. Empty stdin → `kept=0`.
9. Internal-error path (e.g. python absent) → conservative `1 0 all 0`, exit 0.
10. ADVISORY_PATTERN override via `$2`/env; **empty pattern resets to CodeScene** (no all-filtered kept=0).
11. Name lines: `failed>0` → lines 2..N are exactly the verbatim kept-and-failed rows; `failed=0` → absent.

### Refactor: `tests/test-pre-merge-gate.sh`

- Remove the `sed`/`eval` extraction (682, 690-692), its FATAL guard (686-688),
  and direct-function R1–R8 (moved above). Update the top-comment item "8.
  _relevant_check_counts honors…"; drop now-unused `SYNTH_CHECKS`/`ADVISORY_PATTERN`
  globals.
- Add **gate-integration** tests driving `pre-merge-gate.sh` with a mocked
  `gh pr checks`. NOTE: the existing mock at **`tests/fixtures/gh-mock/gh`** has no
  `gh pr checks <num>` case (it falls through to `{}`) — this test must **extend**
  that mock with a TSV-emitting `pr checks` case (plus PATH/cd/REPO_DIR setup),
  including one end-to-end case where a **non-required** check fails and merge is
**allowed**.
- Keep all non-filter gate tests.

### Integration assertions (call-site coverage)

Grep test: each of the three call sites invokes `relevant-check-status.sh` and no
longer contains the old advisory-only **decision** grep. Scope the assertion to the
decision site (not pr-grind's retained cosmetic CodeScene grep, which is allowed) —
e.g. assert the helper call exists and the `REQUIRED=$(echo … grep -ivE
"$ADVISORY_PATTERN")`-as-filter line is gone. Also assert `pr-grinder.md` no longer
references the removed `$REQUIRED` var.

### Plus

Add `scripts/relevant-check-status.sh` to the **required** `shellcheck` job in
`.github/workflows/tests.yml` (today: `hooks/gate-scripts/*.sh` hard +
`scripts/hooks/*.sh` soft — the new canonical helper would otherwise be unlinted by
a required check). Re-run the full `tests/` suite.

> **Known scope boundary (OUT OF SCOPE — follow-up):** CI (`tests.yml`) runs
> vitest + pytest + shellcheck but does **not** execute the `tests/test-*.sh` shell
> gate-tests — they are run directly/locally per the repo's existing convention
> (CLAUDE.md "shell gate-tests in tests/ run directly"). So the new
> `test-relevant-check-status.sh` and refactored gate tests are enforced the same
> way the *existing* shell gate-tests already are (locally, not CI). Wiring the
> whole shell-test suite into CI is a separate, broader improvement — deferred to a
> follow-up issue, not bundled into #154.

## Acceptance Criteria

1. `scripts/relevant-check-status.sh` exists, self-resolves (renamed disable var),
   always passes python argv[2], guards empty pattern, emits 4-field line-1 +
   optional verbatim rows, fails CLOSED with `1 0 all 0`, always exits 0.
2. `pre-merge-gate.sh` invokes it (read sites unchanged, passes `$REPO_DIR`);
   inline python removed; provenance comment added.
3. All three pr-grind/pr-grinder sites call the helper **passing the repo-root
   dir** (not `$REPO`), replicate the gate's guards, switch pending decision to
   lock-aware `PENDING`, remove old grep + `$REQUIRED` prose, update SKILL.md:24,
   document the python3 dependency.
4. `tests/test-relevant-check-status.sh` (cases 1–11) passes; new script added to
   the required shellcheck job; `shellcheck` clean.
5. `tests/test-pre-merge-gate.sh` refactored (no sed/eval); gate-integration tests
   (with an extended `gh pr checks` mock; incl. non-required-fail-allowed) pass.
6. Integration grep-assertions confirm all call sites migrated.
7. Security posture unchanged; a follow-up issue is opened for "make Secret
   scanning / GitGuardian merge-blocking" (lock + branch-protection).

## Consequences

- pr-grind/pr-grinder stop blocking on non-required failures/pendings the gate
  already allows (less friction). The latent no-lock status-parse divergence is
  fixed. Merge-gate security posture is unchanged (see Security posture).
- Filter logic edits touch one file; gate `read` sites untouched.
- New: 1 script + 1 test file + CI shellcheck line; three call sites shrink.
- **Revisit trigger:** if a future repo wants pr-grind stricter than its gate,
  reconsider an opt-in env-gated floor — only with a real reproducer.

## Alternatives Considered

- **Bundle the security lock+BP change into this PR** — rejected by operator
  decision (2026-06-04): out-of-scope, remote-state mutation can't ship in a PR
  diff, and `check-required-checks.sh` can't fully verify external-app checks post.
  Tracked as a follow-up instead.
- **5th field (`advisory_failed`) on line 1** — rejected; breaks the gate's 4-var
  `read`/risks version skew. advisory_failed stays a local pr-grind cosmetic grep.
- **JSON output** — better against injection but adds a `jq` worker dependency;
  line 1 carries no names, so text parsing at parity is lower-risk.
- **Overload `scripts/check-required-checks.sh`** — rejected; that is the drift
  detector, a different concern that doesn't consume `gh pr checks` output.
- **Code-level security floor in pr-grind** — rejected; re-introduces divergence.

<!-- design-reviewed: PASS -->
