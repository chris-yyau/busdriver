# Tier-F Codex `+1` Fail-Closed (#189) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use busdriver:subagent-driven-development (recommended) or busdriver:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the #189 fail-open — the Tier-F Codex `+1` (👍) acknowledgment in `scripts/ack-ledger.sh` must never anchor freshness on the backdatable git committer date; it acks HEAD only when a server-stamped `HEAD_PUSH_DATE` is present and the `+1` postdates it, and returns `stale` (fail-CLOSED) when no push anchor exists.

**Architecture:** Adopt **Option A (uniform fail-closed)** per the 2026-06-18 council (4/5 consensus; all 5 rejected the issue's `HEAD_PUSH_DATE_FETCHED` sentinel as a 5-file compat shim for callers that don't exist). The `+1` path is brought in line with the already-shipped resolved-thread sibling at `ack-ledger.sh:300`, which already fail-closes uniformly when push date is absent. The committer date is removed from the `+1` trust chain entirely, which **orphans `HEAD_COMMITTED_DATE`** (its only executable use is the `+1` line). The reintroduced "outdated-thread deadlock" for no-push-date PRs (forks, events-API aged-out) is **intended** behavior — the hoisted eyes-override and Tier A.2 (push-anchored resolved-current) cover the realistic re-review cases, and a genuinely-outdated finding with no trustworthy anchor SHOULD wait for re-review (operator-visible `--max-wait` bail). Codex's "manufactured server-stamped marker" idea (to restore availability on no-push-date fork PRs) is deferred as a follow-up — YAGNI, since Codex is inactive on this repo.

**Tech Stack:** POSIX/bash shell (`scripts/ack-ledger.sh`, `scripts/fetch-pr-state.sh`), bash test harness (`tests/test-codex-tier-f.sh`), ShellCheck. No build step. No version bump (semantic-release handles it on merge).

---

## File Structure

- **`scripts/ack-ledger.sh`** — the Codex Tier-F `+1` freshness block (~lines 210-228) plus its contract/tier-exposure comments (header ~lines 18-31; tier-exposure ~lines 55-56; inline ~lines 212-221). Only the `+1` anchor logic + its comments change; the resolved-thread path (#186) and all other tiers are untouched.
- **`scripts/fetch-pr-state.sh`** — fetches/exports the ack-ledger inputs. The committer-date fetch (~lines 121-126) currently gates `FETCH_OK`; since the committer date is orphaned by this change, that coupling is removed (a fetch failure of an unread value must not stale every bot).
- **`tests/test-codex-tier-f.sh`** — the Tier-F regression suite. The `run_codex` helper gains an optional push-date parameter; the `+1`-ack tests are modernized to supply a push anchor; Test 17 is inverted to assert fail-closed; a new Test 17b discriminates push-only from `max()`.
- **Documentation surfaces describing the OLD committer-date anchor** (eliminated by pattern-grep, not a fragile per-line list — see Task 4): across `scripts/`, `skills/pr-grind/SKILL.md`, `agents/pr-grinder.md`, `scripts/dispatcher-commit-block.sh`, `tests/test-codex-tier-f.sh` header, and `docs/adr/0002-codex-reaction-tier-f.md`.

**`HEAD_COMMITTED_DATE` decision (reversible detail):** after this change `HEAD_COMMITTED_DATE` has zero executable consumers in `ack-ledger.sh`. It is **retained** in the export contract (still fetched/exported by callers, still accepted by the script) to keep the security-fix diff bounded — fully ripping it out (fetch + exports + the dozens of test fixtures that pass it) is unrelated cleanup, captured as a deferred follow-up. Two consequences ARE handled here because they are direct orphans of this change, not adjacent cleanup: (1) its `FETCH_OK` coupling is removed (Task 4) so an unread value can't stale the gate; (2) every comment/doc that describes it AS the `+1` freshness anchor is corrected (Task 4).

---

### Task 1: Modernize `+1` tests to supply a push anchor (stays green under current code)

**Files:**
- Modify: `tests/test-codex-tier-f.sh` — the date-fixtures block (~lines 34-49); the `run_codex` helper (~lines 79-89); Tests 1, 1b, 2, 12e, 13, 14.

- [ ] **Step 1: Add an optional push-date parameter to the `run_codex` helper**

Replace the helper (lines ~79-89) with:

```bash
# Generic Codex run with all non-reaction sources empty.
run_codex() {
  # $1 = ALL_REACTIONS, $2 = HEAD_COMMITTED_DATE, $3 = login (default codex),
  # $4 = ACK_EMIT_TIER (default 0), $5 = HEAD_PUSH_DATE (default empty)
  local login="${3:-$CODEX}" emit="${4:-0}" push="${5:-}"
  FETCH_OK=1 ACK_EMIT_TIER="$emit" \
  ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$1" HEAD_COMMITTED_DATE="$2" HEAD_PUSH_DATE="$push" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$login" 2>/dev/null
}
```

Backward-compatible: `push` defaults to empty, so every existing `run_codex` call is unchanged unless a 5th arg is added.

- [ ] **Step 2: Give the `+1`-ack-expecting `run_codex` tests a push anchor**

The push anchor must be older than `FRESH` (so `+1 > push` → ack). Use `$HEAD_DATE` (16:12; `FRESH` is 16:24).

Test 1 (line ~92): `got=$(run_codex "$(mk_reaction '+1' "$FRESH")" "$HEAD_DATE" "$CODEX" 0 "$HEAD_DATE")`
Test 1b (line ~100): `got=$(run_codex "$(mk_reaction '+1' "$FRESH")" "$HEAD_DATE" "$CODEX" 1 "$HEAD_DATE")`
Test 2 (line ~108, stale `+1`, stays `stale` via push comparison): `got=$(run_codex "$(mk_reaction '+1' "$STALE_TS")" "$HEAD_DATE" "$CODEX" 0 "$HEAD_DATE")`
Test 14 (line ~349): `got=$(run_codex "$PAGINATED" "$HEAD_DATE" "$CODEX" 0 "$HEAD_DATE")`

- [ ] **Step 3: Give the inline-env `+1`-ack tests a push anchor**

Test 12e (line ~305): add `HEAD_PUSH_DATE="$HEAD_DATE"` to the inline env list (between `HEAD_COMMITTED_DATE="$HEAD_DATE"` and `HEAD_SHA="$HEAD_SHA"`).
Test 13 (line ~333): add `HEAD_PUSH_DATE="$RESOLVE_PUSH"` to the inline env list (same position). (`RESOLVE_PUSH` = 16:12, predates `FRESH`.)

- [ ] **Step 4: Run the suite — must stay fully green (no behavior change yet)**

Run: `bash tests/test-codex-tier-f.sh`
Expected: `Results: 37 passed, 0 failed` (current code uses `max(committer, push)`; supplying a push ≤ committer leaves every outcome unchanged).

- [ ] **Step 5: Commit**

```bash
git add tests/test-codex-tier-f.sh
git commit -m "test(ack-ledger): supply push anchor to Tier-F +1 ack tests (pre-#189)"
```

---

### Task 2: Invert Test 17 and add the push-only discriminator (RED, observed locally only)

**Files:**
- Modify: `tests/test-codex-tier-f.sh` — date-fixtures block (~lines 34-49); Test 17 (~lines 615-628); new Test 17b after it.

- [ ] **Step 1: Rewrite Test 17 to assert `stale` when push date is absent**

Replace Test 17 (lines ~615-628) with:

```bash
# --- Test 17: fresh-looking +1 but empty HEAD_PUSH_DATE → stale (#189 fail-CLOSED) ---
# The git committer date is client-stamped and backdatable, so it must NOT anchor
# a +1 ack. With no server-stamped push anchor there is no trustworthy freshness
# proof → fail-CLOSED to stale (mirrors the resolved-thread path, #186). This
# inverts the prior backward-compat fallback that #189 identified as a fail-OPEN:
# a leftover +1 newer than a backdated committer date could falsely ack HEAD.
got=$(FETCH_OK=1 \
  ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$(mk_reaction '+1' "$FRESH")" \
  HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_PUSH_DATE="" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "fresh +1 but empty HEAD_PUSH_DATE → stale (#189 fail-CLOSED; committer date not trusted)"
else
  fail "empty push + fresh +1 expected 'stale' (#189), got '$got'"
fi
```

- [ ] **Step 2: Add the push-only discriminator (Test 17b) with a NAMED fixture date**

First add the discriminating timestamp to the fixtures block (~lines 34-49, alongside `HEAD_DATE`/`FRESH`/`STALE_TS`/`RESOLVE_PUSH`) — NOT as an inline literal in the test body (blueprint-review finding: no magic dates in test bodies):

```bash
COMMITTER_AFTER_PUSH="2026-06-06T16:30:00Z" # committer LATER than push (HEAD_DATE 16:12) and the +1 (FRESH 16:24); discriminates push-only anchor from max()
```

Then insert after Test 17, referencing the fixture:

```bash
# --- Test 17b: committer date LATER than push, +1 between them → HEAD_SHA (anchor is push, NOT max) ---
# With committer (COMMITTER_AFTER_PUSH, 16:30) > push (HEAD_DATE, 16:12) and the +1
# (FRESH, 16:24) between them: max() would anchor on the committer date and return
# stale, while push-only anchors on the push event and acks. Proves the committer
# date is no longer consulted even when present and later (#189).
got=$(FETCH_OK=1 \
  ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$(mk_reaction '+1' "$FRESH")" \
  HEAD_COMMITTED_DATE="$COMMITTER_AFTER_PUSH" HEAD_PUSH_DATE="$HEAD_DATE" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "$HEAD_SHA" ]; then
  ok "committer later than push, +1 after push → HEAD_SHA (anchor is push-only, not max; #189)"
else
  fail "push-only discriminator expected '$HEAD_SHA', got '$got'"
fi
```

Also add a positive regression guard (the most security-adjacent test): a fresh `+1` acks on the push anchor ALONE with an EMPTY committer date. This is GREEN under both old and new code (so it does not change the RED count), but it guards against a future implementation that re-introduces a committer-date dependency — such an impl would fail this test because the committer date is empty:

```bash
# --- Test 17c: empty committer date, push present, fresh +1 → HEAD_SHA (push alone suffices) ---
# Proves the +1 ack needs ONLY the push anchor — no committer date at all. A regression
# that re-required HEAD_COMMITTED_DATE would fail here (committer is empty), while the
# push-only contract correctly acks since FRESH (16:24) > push (HEAD_DATE 16:12). (#189)
got=$(FETCH_OK=1 \
  ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$(mk_reaction '+1' "$FRESH")" \
  HEAD_COMMITTED_DATE="" HEAD_PUSH_DATE="$HEAD_DATE" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "$HEAD_SHA" ]; then
  ok "empty committer + push present + fresh +1 → HEAD_SHA (push anchor alone suffices; #189)"
else
  fail "push-alone positive guard expected '$HEAD_SHA', got '$got'"
fi
```

- [ ] **Step 3: Run the suite — Test 17 AND Test 17b must FAIL (RED, 2 failures); Test 17c passes**

Run: `bash tests/test-codex-tier-f.sh`
Expected: `Results: 37 passed, 2 failed` (39 tests total: 37 pre-existing/green + Test 17c green, with Test 17 and Test 17b RED). Test 17 fails because current code falls back to `HEAD_COMMITTED_DATE` (fresh `+1` 16:24 > committer 16:12 → `abc12345` not `stale`). Test 17b fails because current `max(16:30, 16:12)=16:30` → `+1` 16:24 < 16:30 → `stale` not `abc12345`.

- [ ] **Step 4: Do NOT commit the RED state**

Leave the inverted Test 17, the new Test 17b, and the new Test 17c uncommitted. Task 3 commits all three *together with* the GREEN logic in a single commit, so no committed state ever has a failing suite (heeds the blueprint-review caution against committing a deliberately-red test that would show red in per-commit CI). The RED run above is an in-working-tree TDD checkpoint only.

---

### Task 3: Implement Option A in `ack-ledger.sh` (GREEN)

**Files:**
- Modify: `scripts/ack-ledger.sh` — the `+1` freshness block (~lines 212-228) and the header contract comment (~lines 18-31).

- [ ] **Step 1: Replace the `+1` freshness-anchor logic with push-only + fail-closed**

Replace the inline comment + logic at lines ~212-228 (the block from `# Freshness anchor: use HEAD_PUSH_DATE ...` through the `emit_head_ack "$HEAD_SHA" F; exit 0` and its closing `fi`) with:

```bash
  # Freshness anchor: HEAD_PUSH_DATE (push event timestamp) ALONE — NEVER the git
  # committer date. The committer date is client-stamped and backdatable: force-push
  # an old commit whose committer date predates a leftover +1 and that +1 would look
  # "fresh" → a false HEAD-ack on un-re-reviewed code (#189). So a +1 acks ONLY when a
  # server-stamped push anchor exists AND the +1 postdates it. When HEAD_PUSH_DATE is
  # absent (fork head, events API delayed / aged-out >90d / capped >300 events) there
  # is no trustworthy anchor → DO NOT ack; fall through to stale (fail-CLOSED). This
  # matches the resolved-thread sibling below (#186) — uniform fail-closed, no
  # committer fallback, no sentinel. The hoisted eyes-override above and Tier A.2
  # (push-anchored resolved-current) cover the active-re-review and out-of-scope-clear
  # cases; a genuinely outdated finding with no push anchor SHOULD wait for re-review
  # (operator-visible --max-wait), which is correct, not a regression.
  if [[ -n "$codex_plus1" && -n "${HEAD_PUSH_DATE:-}" && "$codex_plus1" > "${HEAD_PUSH_DATE}" ]]; then
    emit_head_ack "$HEAD_SHA" F; exit 0
  fi
```

This deletes the `_freshness_anchor` variable from the `+1` path (used nowhere else — Step 4 below greps to confirm). The condition is a SINGLE `[[ ... ]]` (not a `[ ] && [ ] && [[ ]]` mix): behavior-identical, avoids the `[`/`[[` style mix a reviewer may flag, and — verified well-formed by direct execution — sidesteps a prompt-compression artifact that mangled the multi-bracket form into a false "missing `]`" reading during design review.

- [ ] **Step 2: Update the header contract comment (lines ~18-31)**

The prose at line ~29 says the Tier-F `+1` path uses `max(HEAD_COMMITTED_DATE, HEAD_PUSH_DATE)`, and line ~31 says callers that don't export `HEAD_PUSH_DATE` "fall back to HEAD_COMMITTED_DATE only." Replace that `max(...)` + fall-back description so it states the `+1` path (like the resolved-thread path) anchors on `HEAD_PUSH_DATE` alone and fails CLOSED to `stale` when absent (#189). Keep `HEAD_COMMITTED_DATE` listed in the input contract (lines ~18/22/39/111) but annotate it as retained-but-no-longer-a-freshness-anchor. Match exact lines with Edit; preserve formatting and the `#186`/`#189` references.

- [ ] **Step 3: Run the full Tier-F suite — must be fully GREEN**

Run: `bash tests/test-codex-tier-f.sh`
Expected: `Results: 39 passed, 0 failed`. Test 17 passes (no push → `stale`); Test 17b passes (push-only anchor acks despite later committer); Test 17c passes (empty committer + push → ack); Task 1's modernized tests still pass.

- [ ] **Step 4: ShellCheck the changed script**

Run: `shellcheck scripts/ack-ledger.sh`
Expected: no new findings (clean, or only the pre-existing baseline `SC2292`/`SC2312` notes from prior reviews). Also confirm the variable is gone: `grep -n "_freshness_anchor" scripts/ack-ledger.sh` → no matches.

- [ ] **Step 5: Commit (the inverted Test 17 + Test 17b from Task 2 together with the logic — never a red committed state)**

```bash
git add scripts/ack-ledger.sh tests/test-codex-tier-f.sh
git commit -m "fix(ack-ledger): fail closed on Tier-F +1 when push anchor absent (#189)"
```

---

### Task 4: Reconcile the codebase with the now-orphaned committer date

Two consequences of removing the `+1` committer fallback: (a) `fetch-pr-state.sh` still trips `FETCH_OK=0` if the now-unread committer-date fetch fails (Grok MEDIUM — would stale every bot over a value no tier reads); (b) many comments/docs still describe the committer date AS the Tier-F `+1` anchor (Codex/arbiter MEDIUM, recurring). (a) is a small logic fix; (b) is handled by **pattern-grep-and-eliminate with a zero-match assertion** — NOT a fragile per-line inventory, which kept missing surfaces across review iterations.

**Files:**
- Modify: `scripts/fetch-pr-state.sh` (committer fetch ~lines 121-126)
- Modify (via grep-eliminate): every surface matching the stale-anchor patterns below — known instances span `scripts/ack-ledger.sh`, `scripts/dispatcher-commit-block.sh`, `skills/pr-grind/SKILL.md`, `agents/pr-grinder.md`, `tests/test-codex-tier-f.sh` (header), `docs/adr/0002-codex-reaction-tier-f.md`.

- [ ] **Step 1: Decouple EVERY orphaned committer-date fetch from `FETCH_OK`** (enumerate — there are 4 sites, not 1)

The committer-date fetch gates `FETCH_OK` at multiple call sites, not just `fetch-pr-state.sh`. Enumerate the fetch sites with a line-robust grep — do NOT pipe `| grep FETCH_OK`, because `fetch-pr-state.sh` splits `commit.committer.date` (line 125) from `|| FETCH_OK=0` (line 126) across two lines, so a same-line filter would silently miss the one site with real logic:

```bash
# All committer-date fetch sites (the token is on one line, so this is line-robust):
grep -rn "commit\.committer\.date" scripts/ skills/ agents/
# Which of them gate FETCH_OK — -A1 catches the split fetch-pr-state.sh form (gate on the NEXT line):
grep -rn -A1 "commit\.committer\.date" scripts/ skills/ agents/ | grep -i "FETCH_OK"
```

Today the fetch grep returns four sites: `scripts/fetch-pr-state.sh:~125-126` (split form `_tmp=$(...) && HEAD_COMMITTED_DATE="$_tmp"` then `|| FETCH_OK=0` on the next line), `skills/pr-grind/SKILL.md:~1048` and `~1249`, and `agents/pr-grinder.md:~515` (single-line form `HEAD_COMMITTED_DATE=$(...) || FETCH_OK=0`). For EACH, drop the `|| FETCH_OK=0` so a failed fetch of the now-unread committer date cannot stale every bot. Concretely:

- `scripts/fetch-pr-state.sh` (~121-126) — also update the stale comment that claims the committer date is required by the Tier-A resolved-thread guard (it is not; that guard is push-anchored, #186). Replace the fetch + comment with:

```bash
        # HEAD_COMMITTED_DATE is retained in the export contract but is NO LONGER a
        # Tier-F freshness anchor: the +1 path is push-anchored as of #189 and the
        # resolved-thread path was already push-anchored (#186). Nothing consumes it,
        # so a fetch failure must NOT trip FETCH_OK (that would stale every bot over an
        # unread value). Best-effort; empty on failure.
        HEAD_COMMITTED_DATE=$(gh api "repos/$owner/$name/commits/$HEAD_SHA" --jq '.commit.committer.date' 2>/dev/null || echo "")
```

- `skills/pr-grind/SKILL.md:~1048` and `~1249`, and `agents/pr-grinder.md:~515` — change `HEAD_COMMITTED_DATE=$(gh api "repos/$OWNER/$REPO/commits/$HEAD_SHA" --jq '.commit.committer.date' 2>/dev/null) || FETCH_OK=0` to `HEAD_COMMITTED_DATE=$(gh api "repos/$OWNER/$REPO/commits/$HEAD_SHA" --jq '.commit.committer.date' 2>/dev/null || echo "")` (the `|| echo ""` keeps it best-effort and non-gating). Afterward run `grep -rn -A1 "commit\.committer\.date" scripts/ skills/ agents/ | grep "FETCH_OK=0"` and confirm **no matches** (the `-A1` catches the split fetch-pr-state.sh form).

- [ ] **Step 2: Reconcile every committer-anchor description (audit the VARIABLE, not phrases)**

A phrase-regex is unreliable here — some stale descriptions split the key phrase across two lines (e.g. `ack-ledger.sh:55-56` wraps "reaction newer" / "than HEAD's commit"), so a single-line regex provably misses them. Instead audit the two enumerable, line-robust signal sets and review EACH hit by reading it:

```bash
# (1) Every occurrence of the variable token (cannot split across lines):
grep -rn "HEAD_COMMITTED_DATE" scripts/ skills/ agents/ docs/ tests/ \
  | grep -v "docs/plans/2026-06-18-tier-f-plus1-fail-closed.md" | grep -v "docs/reviews/"
# (2) Variable-free committer phrasings used in a Tier-F/ack context:
grep -rniE "HEAD'?s commit time|HEAD commit time|committer date" \
  scripts/ skills/ agents/ docs/ tests/ \
  | grep -v "docs/plans/2026-06-18-tier-f-plus1-fail-closed.md" | grep -v "docs/reviews/"
```

For EVERY hit, read the surrounding lines and rewrite any wording that presents the committer date AS the Tier-F `+1`/freshness anchor so it instead says: the anchor is `HEAD_PUSH_DATE` (push event time), failing CLOSED to `stale` when no push anchor exists (#189). Known instances (the greps are authoritative — fix whatever they return, including line-split ones): `scripts/ack-ledger.sh` tier-exposure comment (~55-56, line-split "reaction newer / than HEAD's commit"); `tests/test-codex-tier-f.sh` header (~11); `skills/pr-grind/SKILL.md` (~1044 "Source 7: ... + HEAD commit time", ~1053-1054 and ~1254-1255 "falls back to HEAD_COMMITTED_DATE", and the matching `~1245` Source-7 comment); `agents/pr-grinder.md` (~188, ~510 Source-7, fetch-block comment ~521-522); `scripts/dispatcher-commit-block.sh` Codex-ack comment blocks (~194-200, ~452-457); `docs/adr/0002-codex-reaction-tier-f.md` (Context ~29-30, Decision bullet ~42). Occurrences that are NOT anchor-descriptions (the retained-contract annotation, the non-gating fetch/export lines, and test fixtures that merely pass the value) are left as-is — they are accurate.

- [ ] **Step 3: Amend ADR 0002 and close its documented residual**

(a) Decision bullet (~line 42): change the anchor in "a `+1` whose `created_at > HEAD_COMMITTED_DATE` → HEAD-ack (`:F`)" to `HEAD_PUSH_DATE`, and note the fail-closed-when-absent behavior + a pointer to the Amendment below. Adjust the adjacent "`HEAD_COMMITTED_DATE` is the *committer* date…" note (~52-55) to record it is no longer the `+1` anchor as of #189.

(b) Append a dated amendment to the "Deliberately backdated HEAD" section (~lines 122-129) — that section describes the *exact* residual #189 fixes:

```markdown
**Amendment (2026-06-18, #189):** This residual is now CLOSED for the `+1` path. The
Tier-F `+1` freshness anchor is `HEAD_PUSH_DATE` (server-stamped push event time) ALONE —
the backdatable committer date no longer participates — and the path fails CLOSED to
`stale` when no push anchor is available (fork head, events API aged-out/capped), matching
the resolved-thread path (#186). The eyes-override remains as defense-in-depth. The
operability cost (a no-push-date PR with a prior Codex finding can stall to `--max-wait`)
is accepted; a server-stamped fallback marker is a deferred follow-up (see plan Notes).
```

- [ ] **Step 4: Convergence audit (read each remaining hit — not a bare "zero matches")**

Re-run BOTH Step 2 greps and the Step 1 `FETCH_OK` enumeration, and confirm by reading each hit:
- Every remaining `HEAD_COMMITTED_DATE` occurrence is ONLY one of: the retained input-contract annotation, a non-gating fetch/export line, or a test fixture passing the value — NONE describe it as the active Tier-F/`+1` anchor.
- The variable-free committer-phrase grep returns no hit that calls the committer date the Tier-F anchor.
- POSITIVE contract assertion (not just absence of stale wording): the `ack-ledger.sh` header (~lines 18-31) explicitly states `HEAD_COMMITTED_DATE` is retained best-effort and is NOT a Tier-F freshness anchor — confirming the Task 3 Step 2 header edit landed.
- `grep -rn -A1 "commit\.committer\.date" scripts/ skills/ agents/ | grep "FETCH_OK=0"` → no matches (every committer fetch decoupled; `-A1` catches the split fetch-pr-state.sh form).

This audit is line-robust (it keys on the variable token and an `-A1`-windowed FETCH_OK pairing, not on guessable prose phrases that can wrap across lines).

- [ ] **Step 5: Run/extend the fetch-pr-state shape test for the new partial-failure contract**

The `FETCH_OK` decouple changes a partial-failure case: a committer-date fetch failure must now leave `FETCH_OK=1` (previously it forced `0`). `tests/test-fetch-pr-state-shape.sh` exists but only covers full-success / total-failure. Run it (`bash tests/test-fetch-pr-state-shape.sh` → `0 failed`); if it does not already assert the committer-fetch-fails-but-`FETCH_OK`-stays-`1` case, add a case that does (mock the committer-date `gh api` call to fail and assert `FETCH_OK=1` with the other sources intact). This guards the decouple against silent regression.

- [ ] **Step 6: Run the suite + ShellCheck (logic touched `fetch-pr-state.sh`; rest are comments)**

Run: `bash tests/test-codex-tier-f.sh && shellcheck scripts/ack-ledger.sh scripts/fetch-pr-state.sh`
Expected: `Results: 39 passed, 0 failed`; no new ShellCheck findings.

- [ ] **Step 7: Commit**

```bash
git add scripts/ack-ledger.sh scripts/fetch-pr-state.sh skills/pr-grind/SKILL.md agents/pr-grinder.md scripts/dispatcher-commit-block.sh tests/test-codex-tier-f.sh tests/test-fetch-pr-state-shape.sh docs/adr/0002-codex-reaction-tier-f.md
git commit -m "docs(ack-ledger): align Tier-F +1 docs with push-anchored fail-closed; decouple orphaned committer fetch (#189)"
```

---

### Task 5: Close-out — verify call sites, suites, audits, and the issue link

**Files:** none (verification only).

- [ ] **Step 1: Enumerate EVERY `ack-ledger.sh` invocation site and confirm each fetches `HEAD_PUSH_DATE`** (arbiter MEDIUM — must not rely on a hardcoded file list)

Because the `+1` path now fails closed without a push anchor, any caller that invokes `ack-ledger.sh` for `chatgpt-codex-connector` but does NOT export `HEAD_PUSH_DATE` would stall Codex forever. Discover call sites by pattern:

```bash
grep -rn 'bash "\$ACK_SCRIPT"\|/scripts/ack-ledger\.sh' scripts/ skills/ agents/ | grep -v '^scripts/ack-ledger\.sh:'
```

Today this resolves to `scripts/dispatcher-commit-block.sh` (which `source`s `fetch-pr-state.sh` → exports `HEAD_PUSH_DATE`), `skills/pr-grind/SKILL.md` (inline fetch blocks), and `agents/pr-grinder.md` (inline worker fetch). For EACH enumerated site, confirm `HEAD_PUSH_DATE` is in scope before the call (`grep -n "HEAD_PUSH_DATE" <that file>` shows it in an `export` line or the inline `VAR=... bash "$ACK_SCRIPT"` env list). If the enumeration surfaces a NEW site, it MUST be checked too. Any site missing `HEAD_PUSH_DATE` must be fixed before merge.

- [ ] **Step 2: Run the broader shell suites that touch ack-ledger**

Run: `bash tests/test-codex-tier-f.sh && bash tests/test-ack-ledger-resolved.sh`
Expected: both report `0 failed`. (`test-ack-ledger-resolved.sh` does not exercise the `+1` path — verified during review — so it is unaffected; if a future version does, modernize it as in Task 1.)

- [ ] **Step 3: Final audits**

- `grep -rn "_freshness_anchor" scripts/ tests/` → no matches (variable fully removed from the `+1` path).
- `grep -rn -A1 "commit\.committer\.date" scripts/ skills/ agents/ | grep "FETCH_OK=0"` → no matches (every committer fetch decoupled; `-A1` catches the split fetch-pr-state.sh form).
- Re-run the Task 4 Step 4 convergence audit and confirm no remaining `HEAD_COMMITTED_DATE` occurrence (or committer phrasing) describes it as the Tier-F/`+1` anchor.

- [ ] **Step 4: Reference the issue in the PR body**

The PR body must include `Closes #189` so the issue auto-closes on merge.

---

## Notes / Deferred

- **Codex's "manufactured server-stamped marker" (deferred):** if a future repo runs Codex against fork PRs (no `HEAD_PUSH_DATE` available), the fail-closed `+1` path will stall such PRs to `--max-wait`. The fix would be a pr-grind-written, `HEAD_SHA`-tied, server-stamped marker used as a fallback anchor. Open a follow-up issue/ADR only when that workload is real — not built here (YAGNI; Codex is inactive on this repo).
- **Full `HEAD_COMMITTED_DATE` removal (deferred, LOW):** this plan retains `HEAD_COMMITTED_DATE` in the export contract (decoupled from `FETCH_OK` in Task 4, but still fetched/exported and still passed by test fixtures). Fully removing it (fetch + exports across the caller families + the input-contract comments + test fixtures) is a separate cleanup deliberately kept out of this security fix to bound the diff. Open a follow-up issue.

<!-- design-reviewed: PASS -->
<!-- design-review-coverage: DEGRADED 2/3 reviewer_3=runtime-failed -->
