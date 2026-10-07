# PR grind → Shipping routing (stop before merge only where Shipping owns landing)

> **For agentic workers:** small change: one script, one test file, completion/skill prose, two one-sentence operator-surface edits, one ADR. Execute inline with busdriver:executing-plans; no subagent fan-out.

**Goal:** When a repo has opted into Cursor Cloud **Shipping** and the PR touches anything that can change what users get, a clean `/pr-grind` stops at **Ready for Shipping** instead of merging, whatever flags were passed. Every other PR, and every repo that has not opted in, keeps today's merge behavior (merge by default, `--no-merge` to stop and write the clean marker).

**Why:** Shipping (pstack `poteto-mode/playbooks/shipping.md`) lands a PR only after an independent per-PR verdict from an agent that did not write the code, exercising the real surface parent vs head. If pr-grind merges first, or leaves a marker that lets a local `gh pr merge` through, Shipping has nothing left to gate. The value is in the website repos (chrisyau.me, jikdak, diveand.dev, future apps). busdriver itself has no stacked PRs and no UI surface, so busdriver does not opt in.

**Supersedes:** the first 2026-10-07 draft of this file, which flipped the global default to "never merge". Rejected because it would stop every PR in every repo, busdriver included, and hand them to a verifier for which no repo yet has a control skill.

---

## Evidence (measured 2026-10-07, last 50 merged PRs per repo)

| Repo | Stacked PRs | Needs Shipping under the D2 skip list | Skipped |
|---|---|---|---|
| diveand.dev | 0 (all base `main`) | 37/50 | 13 (docs, lighthouse baseline seeds, e2e tests) |
| chrisyau.me | 0 | 48/50 | 2 |
| jikdak | 0 | 47/50 | 3 (all `docs(measurement)`) |

- A per-repo hand-tuned skip list skipped 4 more PRs out of 150, and never skipped a PR that the universal list routed to Shipping. Per-repo declarations are not worth their maintenance, so there is one built-in list.
- No repo has a `.cursor/skills/verify-*` skill yet, and `cursor-team-kit` (`control-ui`) is not installed. Shipping is not useful anywhere until a verify skill exists, which is why the verify skill is also the opt-in signal (D1).
- The replay script and per-PR results live in the session scratchpad (`needs_shipping.py`, `prs*.json`), not committed. The table was re-measured with D2's exact string rules under `/usr/bin/python3` (3.9.6). Narrowing `.claude/**` to `.claude/**/*.md` moved exactly one PR to Shipping: chrisyau.me #351, which only edited `.claude/review-exclude`.

---

## Decisions

**D1. Opt-in signal: the base commit's tree contains `.cursor/skills/verify-*/`, meaning a directory under `.cursor/skills/` whose name starts with `verify-`.**
- The tree is read at the PR's **`baseRefOid`** through the git trees API (`repos/<o>/<r>/git/trees/<sha>`), walking `<root> → .cursor → skills`. A missing `.cursor` or `skills` entry is decided from a **successful** listing that omits the entry. There is no 404-means-absent rule: any non-200 response, including a 404, is an error (D3). The lookup reads `body["tree"]`. Pinning the immutable OID removes branch-name URL encoding. It also **narrows** the retarget race between opt-in and the diff, but does not close it: the base can still move between the classifier's last read and Shipping's own landing, and Shipping re-checks the patch itself (pstack Shipping step 3).
- The required layout is a **directory**, `.cursor/skills/verify-<site>/` containing `SKILL.md`, which is what pstack `/create-verification-skill` generates. A blob named `verify-site.md` does not opt the repo in.
- The tree is never read from the PR head or the local checkout. A PR cannot opt its own repo out: deleting the verify skill touches `.cursor/skills/**`, which is not on the skip list, so that PR routes to Shipping. Opt-out procedure: see Task 5, Consequences.
- Shipping without a verify skill produces verdicts no better than green CI, so the prerequisite and the switch are the same artifact.
- Accidental opt-in only makes pr-grind stricter (it stops instead of merging), so it is accepted.
- Rejected alternatives: a separate `.shipping` marker file, which is a second artifact that can drift from the verify skill; and a gitignored `.claude/*.local` opt-in, which Cursor Cloud agents and other machines (um) never see.

**D2. One universal skip list, built into busdriver and not configurable per repo.** A path is skippable only if it matches one of these rules:

| Rule | Implementation |
|---|---|
| `docs/**` | `p.startswith("docs/")` |
| `*.md` at the repo root only (not `**/*.md`) | `"/" not in p and p.endswith(".md")` |
| `.claude/**/*.md` | `p.startswith(".claude/") and p.endswith(".md")` |
| `__tests__/**`, `tests/**` | `p.startswith(("__tests__/", "tests/"))` |
| `**/*.test.ts`, `**/*.test.tsx` | `p.endswith((".test.ts", ".test.tsx"))` |
| `.github/lighthouse.baseline.json` | exact match |

- These are plain string checks, compatible with Python 3.9: no `fnmatch`, no `full_match`, no version gate.
- A PR skips Shipping only if **every** changed path, and every `previous_filename` of a rename, is skippable. Anything else routes to Shipping, including paths that do not exist yet and `.claude/settings.json`, which ADR 0016 treats as an injection channel.
- The list lives in busdriver, so no PR in a gated repo can edit it.

**D3. Routing never merges on doubt.**
- The classifier exits `0` = continue as today, `10` = Ready for Shipping, and **any other code** (1, 2, 127, a 137 kill) = BAIL with `RESULT_BAIL_CATEGORY=env`.
- On every non-0 exit, the dispatcher deletes any existing `pr-grind-clean.local` and writes none.
- An empty file list, or a list at or above the GitHub files-API cap of 3000, returns `10`.
- **Accepted consequence:** non-opted-in repos, busdriver included, gain new BAIL modes on GitHub API or interpreter failure during routing. To keep that surface small, the opt-in walk runs first and is the only network work a non-opted-in repo does: one `gh pr view` plus one to three trees calls. There is no version gate, and the files API is never called unless the repo has opted in.

**D4. Routing runs on every clean completion, `--no-merge` included.** Exit 10 wins over every flag. `--no-merge` is reachable only on exit 0. No new flags are added and there is no in-band "skip Shipping", because agents can type flags. An operator who must land a Shipping-routed PR locally uses the existing audited escape, `.claude/skip-pr-grind.local`.

**D5. A local merge stays blocked because no clean marker exists for the PR.** `pre-merge-gate.sh` requires a `pr-grind-clean.local` whose fields match `<PR> <live headRefOid>`; nothing under `hooks/gate-scripts/` reads `pr-pending-grind.local`.
- On exit 10, the dispatcher removes any pre-existing clean marker, for example one left by a same-head grind from before the repo opted in.
- It also removes `pr-pending-grind.local`, exactly as the other completion paths do, because the grind has finished and that marker only records a grind that has not.
- Shipping merges from Cursor Cloud, which never hits this local gate.

**D6. Operator surfaces get one sentence each; everything else is untouched.**
- Edited: `scripts/hooks/post-bash-pr-created.js` (inside the gate-integrity lock, so the change needs `./scripts/gate-integrity.sh --update` committed in the same branch) and `skills/finishing-a-development-branch/SKILL.md:123`. Both gain: *"If pr-grind prints Ready for Shipping, stop: do not merge, and do not re-run with `--no-merge`; Cursor Cloud Shipping lands it."*
- `post-bash-pr-created.js` also gets its "merge when clean (default behavior)" phrase qualified to "merge when clean (or stop at Ready for Shipping in opted-in repos)". This fits inside the same lock regeneration.
- `agents/pr-grinder.md` gets one bullet in its "The dispatcher emits three categories itself" list (around lines 848–852): `env` is also emitted by the dispatcher when Shipping routing fails. The lead sentence changes from "three" to "four". The worker's own behavior is untouched (it never merges).
- `hooks/gate-scripts/**` is untouched.

**D7. Interpreter: `/usr/bin/python3 -I`.** Three properties are wanted here:
- The absolute path avoids `PATH` hijack of `python3`.
- `-I` ignores `PYTHONPATH` and the user site directory.
- If the binary is missing, the call exits 127 and the dispatcher BAILs `env` under D3, which fails closed.

ADR 0049 rejected `/usr/bin/python3` as a *gate-launch first hop*, because there its absence would turn into a silent gate loss. Here absence is a visible BAIL, so that hazard does not apply. ADR 0049 is cited only for that distinction, not as an endorsement.

The code stays 3.9-compatible: macOS ships 3.9.6 and the ubuntu runners ship 3.12. That means no PEP 604 `X | Y` annotations without `from __future__ import annotations`, and no `match`. `gh` stays on `PATH`, as in every other completion block. Each classifier subprocess sets `GH_HOST=github.com` and unsets `GH_REPO`, following the Codex-nudge precedent in SKILL.md around lines 608–627. The ADR records the GHE limitation that follows.

**D8. Merge-readiness on the Shipping path is reported, not enforced.**
- Branch-currency and approver-gap detection are merge-path BAILs and are skipped on exit 10.
- The Ready line instead carries the read-only `mergeStateStatus` from the classifier's final `gh pr view`, with a null value reported as `UNKNOWN`.
- It adds an explicit warning when the state is `BEHIND`, `BLOCKED`, `DIRTY` or `DRAFT`, and a note when it is `UNKNOWN`, so the operator knows before kicking Shipping that GitHub will not land the PR as it stands.
- pstack Shipping step 4 rebases and retargets the bottom PR itself, so `BEHIND` is in its scope; `BLOCKED` on a missing review is not, and the warning says so.
- Measured 2026-10-07: `main` in chrisyau.me, diveand.dev and jikdak has no required reviews and no rulesets, so `BLOCKED` comes only from checks there today.

---

## File Structure

| File | Change |
|---|---|
| `scripts/needs-shipping.py` | **New.** Classifier (D1–D3, D7). Stdlib only, 3.9-compatible. |
| `tests/test-needs-shipping.sh` | **New.** `gh`-stubbed classifier cases, `--selftest`, and prose-order assertions over completion.md and SKILL.md. |
| `skills/pr-grind/references/completion.md` | New "Shipping routing" block between "Verify checks are green" (≈538) and "Write the pr-grind-clean marker" (≈579), plus a new output line. |
| `skills/pr-grind/SKILL.md` | Announce line, Safety Rails bullet, COMPLETION diagram, and the `--no-merge` row of the flags table. |
| `scripts/hooks/post-bash-pr-created.js`, `.gate-integrity.lock` | One sentence (D6) plus the lock regeneration. |
| `skills/finishing-a-development-branch/SKILL.md` | One sentence (D6). |
| `agents/pr-grinder.md` | One bullet in the dispatcher-emitted category list, "three" → "four" (D6). |
| `docs/adr/0054-pr-grind-shipping-routing.md` | **New.** |

---

### Task 1: Classifier, `scripts/needs-shipping.py`

**Interface:** `/usr/bin/python3 -I scripts/needs-shipping.py <owner>/<repo> <PR_NUMBER> <REVIEWED_HEAD>`. Every `gh` call passes `-R <OWNER>/<REPO>` or uses an explicit `repos/<o>/<r>/` path, so the result never depends on the current directory. The script prints one line to stdout and exits 0, 10 or 1:

| stdout | exit |
|---|---|
| `merge` | 0 |
| `shipping mergeStateStatus=<S>` | 10 |
| `error: <reason>` | 1 |

Argument errors exit 1, not argparse's 2; D3 covers any code anyway.

- [ ] **Step 1:** Run `gh pr view <PR> -R <o>/<r> --json headRefOid,baseRefOid,mergeStateStatus`. If `headRefOid != REVIEWED_HEAD`, exit 1 (`head moved after classification; re-run /pr-grind`). This binds routing to the same SHA as `--match-head-commit` (#427).
- [ ] **Step 2 (opt-in, D1):**
  1. Fetch `gh api repos/<o>/<r>/git/trees/<baseRefOid>`.
  2. Find the entry `.cursor` with `type == "tree"`; if absent, exit 0.
  3. Fetch that tree's `sha` and find `skills` with `type == "tree"`; if absent, exit 0.
  4. Fetch that tree. Opted in if any entry has `type == "tree"` and a `path` starting with `verify-`; otherwise exit 0.
  5. Any `gh` non-zero exit or unparseable JSON exits 1. A response with `"truncated": true` also exits 1, since a non-recursive tree is never truncated in practice and failing closed is free.
  6. "Absent" here means a recorded result of `merge`, not an immediate exit. Every path falls through to Step 4.
- [ ] **Step 3 (changed paths, opted-in only):** run `gh api --paginate -X GET -F per_page=100 repos/<o>/<r>/pulls/<PR>/files --jq '.[] | {filename, previous_filename}'`.
  - This emits **one compact JSON object per line** across all pages; `--jq` applies per page. `json.loads` each line, require a dict with a string `filename`, and collect `filename` plus `previous_filename` when present.
  - Lines are never split as paths. A filename containing `\n` stays one path inside its JSON string, so it cannot split into two skippable fragments.
  - A `gh` non-zero exit, including a later page failing, exits 1. A line that fails to parse also exits 1.
  - Zero **objects**, or 3000 or more objects, routes to `shipping`.
- [ ] **Step 4 (runs on every path, before any output):** re-run Step 1's `gh pr view`. If `headRefOid` or `baseRefOid` moved, exit 1. `mergeStateStatus` is read from this second view, with null reported as `UNKNOWN`. Only now print the result recorded in Step 2 or Step 5.
- [ ] **Step 5:** Classify with D2's string rules. Any path that is not skippable records `shipping`; if every path is skippable, record `merge`. Then go to Step 4.
- [ ] **Step 6:** `--selftest` asserts on the pure classifier:
  - routed to Shipping: `src/app/page.tsx`, docs + src, a rename `src/a.ts` → `docs/a.ts` given as both paths, an empty list, `foo/README.md` (root-only `*.md`), `.claude/settings.json`, `.cursor/skills/verify-x/SKILL.md`;
  - also routed: a path containing `\n` (e.g. `src/app/a.test.ts\ndocs/x`), `.github/lighthouse.baseline.json.bak`, `docs` (no slash), `x/docs/a.md`;
  - skipped: `docs/a/b.md` + `README.md`, `.claude/CLAUDE.md`, `client/x.test.tsx`, `.github/lighthouse.baseline.json`.

  `--selftest` runs under `/usr/bin/python3` in Task 2, so 3.9 compatibility is exercised, not assumed.

### Task 2: Tests, `tests/test-needs-shipping.sh`

Put a `gh` stub on `PATH`, keyed on the URL or arguments it receives, and run every classifier case through `/usr/bin/python3 -I`. The stub's trees and files responses are trimmed copies of **real captured API bodies**, so field names (`tree`, `type`, `path`, `filename`, `previous_filename`) are not guessed. For each decision the suite must see both outcomes, so every branch below expects a specific exit code.

**Classifier cases:**
- [ ] Not opted in: no `.cursor` in the base tree → `merge`, 0. The stub asserts the files API was **never** called.
- [ ] Not opted in: `.cursor/skills/` holds only non-`verify-` directories → `merge`, 0.
- [ ] Not opted in: `.cursor/skills/` holds a **blob** named `verify-site.md` → `merge`, 0.
- [ ] Not opted in, but the head moved between Step 1 and Step 4 → 1 (the early-absent path still runs Step 4).
- [ ] Not opted in, but the trees API returns 500 or 404 → `error`, 1. The outcome for this case is decided in D3.
- [ ] Opted in, docs-only diff → `merge`, 0.
- [ ] Opted in, `src/app/page.tsx` → `shipping`, 10, with `mergeStateStatus` echoed.
- [ ] Opted in, rename `src/a.ts` → `docs/a.ts` → 10.
- [ ] Opted in, the PR deletes `.cursor/skills/verify-site/` → 10.
- [ ] Opted in, two pages (page 1 docs, page 2 `src/`) → 10.
- [ ] Opted in, page 2 fails → 1.
- [ ] Opted in, 3000 file objects → 10.
- [ ] Opted in, a filename containing `\n` whose fragments would each be skippable → 10.
- [ ] Opted in, a files line that is not valid JSON → 1.
- [ ] `mergeStateStatus` null → printed as `UNKNOWN`.
- [ ] Head moved in Step 1 → 1.
- [ ] Head or base moved in Step 4 → 1.
- [ ] Bad arguments → 1.
- [ ] `--selftest` passes.

**Prose-order assertions** (same pattern as `tests/test-pr-grind-codex-wiring.sh`):
- [ ] In completion.md, the "Shipping routing" heading falls after "Verify checks are green" and before "Write the pr-grind-clean marker".
- [ ] The exit-10 bash block contains `rm -f` of both markers and no `printf`/`cp`/`>` aimed at `pr-grind-clean.local`.
- [ ] The routing text names the catch-all ("any other exit") with BAIL `env`.
- [ ] In SKILL.md's COMPLETION diagram, the routing node sits above the marker-write node.
- [ ] **Each of the three existing marker sites carries the "only when Shipping routing exited 0" qualifier** (Task 3 Step 4): the CRITICAL two-call block, the "Write the pr-grind-clean marker" heading, and the `--no-merge` heading.
- [ ] The Shipping routing section does not contain the substring `codex-retrigger-gc`.
- [ ] The Ready-line warning strings for `BEHIND`, `BLOCKED`/`DIRTY`/`DRAFT` and `UNKNOWN` are present.
- [ ] `tests/test-pr-grind-codex-wiring.sh` stays unchanged and green. `GC_COUNT == 2` holds because exit 10 adds no GC call, and `TEMPLATE_COUNT` holds because routing passes `<REVIEWED_HEAD>` inline and adds no `REVIEWED_HEAD=<full 40-char SHA` assignment line.

**Run:** `bash tests/test-needs-shipping.sh`, then `bash scripts/ci/run-shell-tests.sh`. A test without a durations row gets `DEFAULT_WEIGHT=10`, so no tsv edit is needed.

### Task 3: Wire into Completion, `skills/pr-grind/references/completion.md`

- [ ] **Step 1:** After "Verify checks are green", insert **"Shipping routing (REQUIRED on every clean completion, `--no-merge` included; run BEFORE the marker write, as its own Bash call)"**. It runs `/usr/bin/python3 -I "${CLAUDE_PLUGIN_ROOT}/scripts/needs-shipping.py" "<owner>/<repo>" <PR_NUMBER> <REVIEWED_HEAD>`. The values are template-substituted the same way as the approver-gap block, with `<REVIEWED_HEAD>` **inline in the command**: there is no `REVIEWED_HEAD=` assignment line, and the classifier's equality check rejects a short or garbled SHA (exit 1). The call runs at the ambient session cwd, without `cd`. Exit 10 is an **expected** outcome, not an error. Then it branches on **stdout and exit code together**:
  - **stdout `merge`, exit 0:** continue to "Write the pr-grind-clean marker" and then the existing default-merge or `--no-merge` path, unchanged.
  - **stdout `shipping mergeStateStatus=<S>`, exit 10:** run the exit-10 block below, print the output with the Shipping line, and stop. Do not reach the marker write, branch-currency, approver-gap, admin-merge, or `--no-merge` blocks.
  - **anything else** (any other exit code, or stdout that does not match the exit code): run the exit-10 block's marker removal, then BAIL with `RESULT_BAIL_CATEGORY=env` and surface the script's `error:` line. Do not merge.
- [ ] **Step 2:** The exit-10 block is spelled out verbatim in completion.md. It is not derived from the `--no-merge` block, which writes and copies markers and must never be used as a template here.
  ```bash
  NO_WORKTREE=<0|1 — see "Resolve flag-to-state translations" in START>
  # Try EVERY root even when one fails; report failure only at the end, so a failure
  # on one root never leaves another root's marker standing.
  CLEAN_FAIL=0
  ROOTS=()
  REPO_ROOT=$(git rev-parse --show-toplevel) && [ -n "$REPO_ROOT" ] && ROOTS+=("$REPO_ROOT") || CLEAN_FAIL=1
  if [ "$NO_WORKTREE" != "1" ]; then
    # An earlier --no-merge run may have copied a marker into the original worktree.
    ORIG_ROOT=$(git -C <original-worktree-path> rev-parse --show-toplevel) && [ -n "$ORIG_ROOT" ] && ROOTS+=("$ORIG_ROOT") || CLEAN_FAIL=1
  fi
  for R in "${ROOTS[@]}"; do
    rm -f "$R/.claude/pr-grind-clean.local" "$R/.claude/pr-pending-grind.local" || CLEAN_FAIL=1
    [ ! -e "$R/.claude/pr-grind-clean.local" ] || CLEAN_FAIL=1
  done
  [ "$CLEAN_FAIL" = 0 ] || exit 1
  if [ "$NO_WORKTREE" != "1" ]; then
    cd <original-worktree-path>
    git worktree remove "../pr-grind-<PR_NUMBER>" --force 2>/dev/null || true
  fi
  ```
  A non-zero exit from this block is handled as the catch-all BAIL `env`. Roots are held in a quoted bash array, so a path with spaces or glob characters is never split. Task 2 executes this block, with its placeholders filled in, in repos whose paths contain spaces: once with both roots resolvable, and once with the original root missing, where the session marker must still be removed.

  This path does not prune the per-PR Codex retrigger markers. The PR is not merged, so they are left as after any other unmerged completion. They are harmless, and changing the wiring test's GC count is not worth it.
- [ ] **Step 4 (qualify the existing marker sites).** Three places in completion.md currently read as unconditional. Each gets a one-line qualifier: *"Only when Shipping routing exited 0 (stdout `merge`). On exit 10 or any routing failure, never write or copy this marker."*
  - the CRITICAL "marker write and `gh pr merge` MUST be TWO SEPARATE Bash tool calls" block (≈569–577);
  - the "Write the pr-grind-clean marker (REQUIRED)" heading (≈579);
  - the "If `--no-merge`: write marker…" heading (≈1297).

  Task 2 asserts the qualifier at all three, so an agent that skims past the routing section (the #93/#95 pattern recorded at ≈574) still meets the condition where it acts.
- [ ] **Step 3:** Output. Add **"With Shipping routing:"**, which appends:
  - `- Ready for Shipping (mergeStateStatus=<S>): this repo opted in (base has .cursor/skills/verify-*). Busdriver did not merge and wrote no clean marker. Kick Cursor Cloud Shipping on PR #<N>.`
  - When `<S>` is `BEHIND`: `Shipping rebases the bottom PR itself.`
  - When `<S>` is `BLOCKED`, `DIRTY` or `DRAFT`: `GitHub will not land this PR as it stands (missing review, failing required check, conflict, or draft); fix that before kicking Shipping.`
  - When `<S>` is `UNKNOWN`: `GitHub has not computed mergeability yet; check the PR before kicking Shipping.`

### Task 4: Skill contract, `skills/pr-grind/SKILL.md`

- [ ] Announce: "…then merge, or stop at Ready for Shipping if the repo opted in."
- [ ] Safety Rails, "Merges by default": add one sentence. In a Shipping-enabled repo (D1), a PR that touches anything outside the D2 skip list stops at Ready for Shipping, even with `--no-merge`. Link ADR 0054.
- [ ] COMPLETION diagram: insert `├── Shipping routing (needs-shipping.py): 10 → Ready for Shipping, rm markers, stop; other non-0 → rm markers, BAIL env` **immediately above** the "Write .claude/pr-grind-clean.local" node, around line 876. Annotate the `--no-merge` node, around line 890, as `(exit 0 only)`.
- [ ] Flags table: the `--no-merge` row says it is reached only when routing returns 0, and that Shipping routing overrides it.

### Task 5: ADR 0054

- [ ] Record D1–D8, the evidence table, and the rejected global flip.
- [ ] **Consequences** include the opt-out procedure. A PR that removes the last `verify-*` skill routes to Shipping, but Shipping has no skill left at that head to verify with. The operator lands it once through `.claude/skip-pr-grind.local`, which is audited. After it merges, the repo is no longer opted in.
- [ ] Also record D3's accepted consequence (new BAIL `env` modes in non-opted-in repos) and D7's interpreter policy.
- [ ] **Revisit triggers:**
  - (a) An opted-in repo serves content from a skip-list path, such as a docs site under `docs/**`: add a per-repo override then, not before.
  - (b) The trial (about 10 Shipping-routed PRs) measures Shipping costing more than it catches.
  - (c) Stacked PRs appear in an opted-in repo.
  - (d) A routing BAIL in a non-opted-in repo is observed to cost real time: add a bounded retry then.
  - (e) A required-review rule or ruleset is added to an opted-in repo. Today none of the three has one (measured 2026-10-07); with one in place, `BLOCKED` would need its own handling.
- [ ] Also record the remaining base-move window (D1) and the `GH_HOST` pin and its GHE limitation (D7).

---

## Dependencies outside this repo (operator, not this PR)

1. **AFK / dots contract.** `~/.claude/CLAUDE.md` is operator-owned and today treats merge as part of delivery. Proposed line for Chris to add: *"In a repo where pr-grind reports Ready for Shipping, that is the delivery end state: end `MERGE_BOUNDARY`, quoting the Ready line, wake condition = Shipping verdict on the PR."*
2. **Verify skills.** Run pstack `/create-verification-skill` in each site repo, starting with diveand.dev, which has `preview.yml`. Put the SEO checks in the feature map, comparing parent vs head: rendered `<head>` (title, meta description, canonical, hreflang, robots meta), JSON-LD, `robots.txt` and `sitemap.xml`. Committing that skill to `main` as the directory `.cursor/skills/verify-<site>/` with a `SKILL.md` inside is what opts the repo in.
3. **Dependabot auto-merge.** In chrisyau.me and jikdak, `dependabot-auto-merge.yml` merges without pr-grind and so bypasses Shipping. File a follow-up issue per repo: stop auto-merging framework and runtime dependencies in opted-in repos.

## Out of scope

- Calling Cursor Cloud or Shipping APIs from busdriver. The operator kicks Shipping; automation can come later.
- Opting busdriver itself in.
- GC of per-PR codex-retrigger markers on the Shipping path.
- Cloudflare dashboard drift. The 2026-09-20 Googlebot lockout came from a CF setting, not a PR, and is `crawler_guard.py`'s job, scheduled separately.

## Done when

1. In a repo whose base tree has no `.cursor/skills/verify-*`, `/pr-grind <n>` merges, or stops under `--no-merge`, exactly as today. The only new behavior is a BAIL `env` on a GitHub API or interpreter failure during the opt-in check (D3).
2. In an opted-in repo:
   - A PR touching `src/**` ends at **Ready for Shipping** with or without `--no-merge`. There is no `gh pr merge`, and no `pr-grind-clean.local` exists afterwards, even if one existed before.
   - A docs-only PR merges as today.
3. A classifier exit other than 0 or 10 BAILs `env`, leaves no clean marker, and never merges.
4. `tests/test-needs-shipping.sh`, `tests/test-pr-grind-codex-wiring.sh`, `tests/test-gate-integrity.sh` and `bash scripts/ci/run-shell-tests.sh` are green, and the classifier was seen to return all three exits.
5. ADR 0054 lands in the same PR.

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
