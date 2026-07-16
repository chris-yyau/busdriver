# Plan: Upstream Sync & Adoption — 2026-07-06

**Status:** Blueprint-reviewed PASS 2026-07-06 (2 iterations, coverage DEGRADED 2/3 — grok slot ran as droid rescue both rounds; trajectory auto-stop) + ultra-council (Skeptic + Architect voices; Pragmatist/Critic/Researcher lenses fulfilled via the blueprint reviewers; **UltraOracle expert witness consulted 2026-07-07** — verdict "close but not yet zero-mistakes"; its 6 findings applied: executable effort-guard assertion, byte-identity check replacing residue grep, validator escape-hatch removed, object-store vendoring via `git show`, Tranche A pre-commit re-verification, hook-smoke scope honesty). Execution pending operator go.
**Scope:** Adopt superpowers v6 remainder; fix manifest integrity/attribution; sync verified ECC + small-upstream deltas; consent-gated vault additions.
**Evidence base:** 6 audit agents + 4 adversarial verifiers + 2 operator corrections. Every action below is backed by a primary-source check (diff/grep/jq/ADR), not agent assertion. First-pass audit error rate was ~25% (8 of ~31 claims wrong); all actions from refuted claims have been removed or corrected.

## Pinned upstream evidence (audited SHAs — the claims below hold at these commits ONLY)

All verification (byte-identity, quotes, diffs) was performed against the sync-cache clones at these HEADs. **Pre-apply guard (mandatory FIRST step of every tranche's work order, not prose):** `[ "$(git -C ~/.claude/cache/upstream/<name> rev-parse HEAD)" = "<full pinned SHA>" ] || { echo "UPSTREAM MOVED — STOP, re-verify"; exit 1; }` for each upstream the tranche touches. **HEAD equality alone doesn't guard a dirty cache worktree — all vendoring copies read the object store, never the worktree:** `git -C ~/.claude/cache/upstream/<name> show <pinned-sha>:<upstream_path> > <local_path>` (byte-exact at the pin regardless of worktree state). Full 40-char SHAs (rev-parse emits 40 chars — a short-pin equality check would never pass):

| Upstream | Audited SHA (full) |
|---|---|
| superpowers | `d884ae04edebef577e82ff7c4e143debd0bbec99` |
| ecc | `4130457d674d2180c5af2c5f634f3cae4cbc6c4f` |
| mattpocock | `16a2a5cd00b4416f673f4ff38c7971a04dd708e7` |
| marketingskills | `30dbd7f793b86f0ec2f007757b333afac93c24db` |
| supabase | `1356046015476711a769601079262b5635929427` |
| nextlevelbuilder | `4baa399d00da806f83ed93652172f66943205153` |
| gstack | `11de390be1be6849eb9a15f91ff4922dd16c589a` |
| taste-skill | `b17742737e796305d829b3ad39eda3add0d79060` |
| humanizer | `1b48564898e999219882660237fde01bf4843a0f` |
| gsd (not tracked) | `d78b29d6c2622cee84a0b448ba9a6f8025d70522` |

## Prerequisite (out-of-band local tooling — NOT part of any tranche/PR)

Fix the NEW-file detector in `~/.claude/scripts/sync-upstream.sh:257`: the `find` filter admits only 5 extensions (`.md .sh .js .json .py`), silently hiding extensionless executables (missed superpowers SDD scripts; still hides ECC `codex-git-hooks/{pre-push,pre-commit}`). This file lives outside the repo, so it gets its own verification instead of PR gates: (a) `shellcheck ~/.claude/scripts/sync-upstream.sh` clean; (b) fixture check — a `--dry-run` after the fix must report upstream extensionless executables (e.g. ECC `codex-git-hooks/pre-push`) as NEW/review-required. **Done before ANY tranche executes** (Tranche A's extensionless scripts are hand-vendored and hand-registered, so A does not depend on the detector — but fixing it first removes the class entirely).

---

## Non-negotiable constraints (settled decisions — violating any of these is a defect)

| # | Constraint | Source |
|---|-----------|--------|
| C1 | **Never remove `effort:` frontmatter from `agents/*.md`.** Upstream ECC lacks these lines; we added them deliberately (cost tiering by blast radius). Effort-line diffs vs upstream are permanent, not drift. Any agent-file sync preserves the line; `tests/test-agent-effort-tiers.sh` must pass before every commit touching `agents/`. | ADR 0009 |
| C2 | **Design-skill routing is settled.** Dual-engine: `design-taste-frontend` explores (landing/marketing/portfolio), `impeccable:impeccable` hardens + owns dashboards/app-UI solo; `ui-ux-pro-max`/`design-system`/`frontend-design` are gap-fill. No demotion/removal of any skill referenced by orchestrator routing. | `skills/orchestrator/tasks-catalog.md:15`, `domain-supplements.md:75-77` |
| C3 | **Vault moves require explicit per-name operator consent.** No promotion/demotion on signal alone. | ADR 0010 |
| C4 | **Keep-ours list (verified deliberate):** `grill-me` (upstream = 7-line stub), `caveman` (upstream deleted; ours custom), 9 mattpocock upstream deletions (path moves of live skills), 7 ECC-deleted command shims (deliberate legacy shims), `web-interface.csv` (still registered in `core.py:64` CSV_CONFIG), custom forks of `brainstorming`/`writing-plans`/`finishing-a-development-branch` (deliberately ahead of upstream), `gateguard-fact-force.js` + `agent-self-evaluation/evaluate.py` (diverged; separate manual review only). | verify-small, verify-ecc |
| C5 | **Do not re-adopt** `sync-ecc-to-codex.sh` or any ECC codex-sync tooling (removed in PR #284), ECC epic/orch pipeline, GSD/impeccable vendoring. | PR #284, verify-gsd-design |
| C6 | Solo-operator/provider chain and gateway hardening are frozen; nothing here touches them. | Project CLAUDE.md |
| C7 | Each tranche = own branch + PR through the normal gates (litmus pre-commit, pre-PR). No cross-tranche bundling. **Serial merge order:** A branches from main; B branches only after A merges; C only after B merges; D blocked on consent. (A and B both edit `.upstream-sources.json` — parallel branches would conflict.) | operator instruction |

---

## Tranche A — Superpowers v6 completion
Branch `chore/superpowers-v6-completion` (file edits already in working tree, verified, uncommitted).

| Step | Action | Verification already done |
|---|---|---|
| A1 | Vendor `skills/subagent-driven-development/scripts/{task-brief,review-package,sdd-workspace}` (fixes live SDD skill calling nonexistent scripts at SKILL.md:136,182,204,226,375,385) | byte-identical to upstream, exec bits preserved; scripts content-reviewed (git read-ops + awk only, no network/destructive ops) |
| A2 | Replace `skills/using-superpowers/SKILL.md` with compressed v6.1.0 body (121→~64 lines; ~600–900 tokens saved per session), adapted: `busdriver:` namespace, platform refs = codex + agy only (no pi) | diff vs upstream shows only the 3 intended deltas |
| A3 | Sync `references/codex-tools.md` (upstream trim); delete `references/{copilot,gemini}-tools.md` (Gemini CLI EOL 2026-06-18; copilot ref empty of harness-specific content) | codex-tools byte-identical; deletions staged |
| A4 | Take upstream `skills/writing-skills/SKILL.md` +1/−1 (removes reference-link list that dangles after A3 and already dangled on `claude-code-tools.md`) | upstream line inspected |
| A5 | Manifest: remove entries for 2 dead reviewer prompts + copilot/gemini tools; add `task-reviewer-prompt.md` (sync), 3 SDD scripts (sync), `agy-tools.md` (custom ← `antigravity-tools.md`); flip `using-superpowers/SKILL.md` sync→custom. **EXECUTION FINDING: the disk-existence scan for A6's validator surfaced 6 stale entries (not 1) — `commands/{brainstorm,execute-plan,write-plan}.md` (deleted #49), `rules/zh/{investigate-before-acting,validate-before-building}.md` (deleted #147), `skills/strategic-compact/suggest-compact.sh` (deleted #215). All 6 point at files deleted in merged PRs; removed here so the validator passes at introduction. This SUPERSEDES B5.** | current entries confirmed via jq; 6 stale entries git-log-confirmed as deleted-in-merged-PR |
| A6 | **Create `tests/test-upstream-manifest.sh`** (semantic manifest validator — created HERE in A, not B, because A merges first and A5 mutates the manifest). Spec: every `sync`/`custom` entry requires `upstream_path` AND its `source` key present in `upstreams`; `status` ∈ {sync,custom,local}; `local` entries carry no upstream requirements; paths unique; tracked paths exist on disk — no exceptions (a change deleting a file must remove its manifest entry in the same commit; an "unless deleted" escape would let stale manifest state pass); upstreams with zero `files[]` references are VALID (gstack pattern-derived case); unknown extra upstream keys (`note`/`license`/`adoption`) permitted. Header documents the boundary: repo-side checks only — upstream-clone-side checks (upstream_path existence, byte-identity) are sync-time concerns, optionally enabled via `UPSTREAM_CACHE_DIR` when clones exist | validator shapes settled by review iter-2 |
| A7 | **Re-verify the pre-existing working-tree edits from the pinned cache before commit** (A's edits predate the SHA guard procedurally): re-diff each staged sync file against `git -C cache show <pinned-sha>:<upstream_path>`; re-confirm the 3 adapted deltas in using-superpowers/SKILL.md are the only ones | Tranche A edits were made before the guard existed |
| A8 | Gate: shellcheck the 3 vendored scripts (verified clean 2026-07-06) + the new test script; `npm test`; `tests/test-vault-references.sh`; `tests/test-upstream-manifest.sh`; litmus; PR | — |

Skips (deliberate): `antigravity-tools.md`/`pi-tools.md` upstream copies (agy fork covers it; Pi unused), upstream Codex packaging scripts (`sync-to-codex-plugin.sh`, `package-codex-plugin.sh`, `lint-shell.sh` — upstream's own distribution tooling), custom-fork overwrites (C4), `plan-document-reviewer-prompt.md` +1/−1 cherry-pick (cosmetic "Task tool→Subagent" rename; optional, take only if free).

## Tranche B — Manifest integrity & attribution
Branch `chore/manifest-attribution`.

| Step | Action |
|---|---|
| B1 | Add `upstreams` entries: `gstack` (garrytan/gstack, **pattern-derived note only, zero `files[]` mappings** — supplements are multi-file prose distillations; file mappings would produce permanent false CUSTOM-CHANGED prompts; script provably ignores extra keys), `taste-skill` (Leonxlnx/taste-skill, MIT), `humanizer` (blader/humanizer, MIT) |
| B2 | Add missing `license` fields: supabase (MIT © Supabase), marketingskills (MIT © Corey Haines), nextlevelbuilder (MIT © Next Level Builder) — all verified from upstream LICENSE files |
| B3 | Re-attribute 9 taste-skill entries `source:local` → `source:taste-skill, status:sync` with upstream_path by frontmatter-name mapping (8 byte-identical). **Apply stitch-design-taste's 1-line upstream URL fix (`labs.google.com`→`labs.google`) in this same step** so `status:sync` is truthful at commit time — never rely on a future sync to make the manifest honest |
| B4 | Re-attribute 3 humanizer entries → `source:humanizer, status:sync`; sync SKILL.md 2.7.0→2.8.2 (verified: our copy is pristine old upstream; the `compatibility` line was upstream's own old value). +3 new AI-tell patterns land with it |
| B5 | ~~Remove stale `skills/strategic-compact/suggest-compact.sh` manifest entry~~ **DONE IN TRANCHE A** (folded into A5's 6-stale-entry cleanup) |
| B6 | Add ECC upstream `note`: "agents/*.md carry local `effort:` frontmatter per ADR 0009 — effort-line diffs are permanent policy, never sync their removal" (makes the C1 near-miss structurally un-repeatable) |
| B7 | Project CLAUDE.md: short "External plugins consumed" note — impeccable (pbakaus/impeccable, Apache-2.0) is used as an installed plugin, deliberately NOT vendored (runtime scripts + PostToolUse hook + CLI); routing per C2. Prevents future re-vendor/consolidation proposals |
| B8 | **Fix `scripts/lib/ultra-oracle.sh` (repo copy)** — diagnosed live 2026-07-07: (a) drop/parameterize the hardcoded `--browser-hide-window` (hidden-window runs fail at prompt submission since ~Jul 5; visible run succeeds in seconds) — make visible the default with an `ultraOracle.hideWindow` config opt-in; (b) capture oracle stdout to an `.err` artifact on failure in both modes (oracle prints its errors to STDOUT — currently discarded, making every failure a silent rc=1); (c) document the 3–5-word slug rule at call sites (oracle 0.15.1 rejects others) |
| B9 | Gate: `tests/test-vault-references.sh`; `tests/test-upstream-manifest.sh` (created in A6 — validator spec lives there; extend only if B's shapes need it); shellcheck on the edited lib; litmus; PR |

## Tranche C — Verified content sync
Branch `chore/sync-upstream-2026-07-06`.

| Step | Action | Trap it avoids |
|---|---|---|
| C-1 | ECC changed sync-files: generate EXACT lists first, mechanically — for each changed `agents/*.md`, classify via `diff` filtered to `effort:` lines: if the only delta is the effort-line removal → **skip list**; if mixed → **adapt-merge list** (take upstream content, re-apply our `effort:` line); diverged customs (C4) → untouched list. Commit the three lists in the PR as the work-order. **Pre-merge guard (on the tranche branch, BEFORE merging — a post-merge `git diff main` on main is vacuously empty; grep -c exits 1 on zero matches so it must be a real assertion, not a bare pipeline):**
```sh
count=$(git diff "$(git merge-base origin/main HEAD)"..HEAD -- agents/ | grep -c '^-effort:' || true)
[ "$count" -eq 0 ] || { echo "effort: frontmatter removed — ADR 0009 violation"; exit 1; }
```
plus `tests/test-agent-effort-tiers.sh` green | ADR 0009 clobber; approximate counts (~26–28/~15) replaced by generated inventories |
| C-2 | clv2 island atomically: `lib/homunculus-dir.sh` + 4 callers (`start-observer.sh`, `observe.sh`, `migrate-homunculus.sh`, `detect-project.sh`) with `_ecc_`→`_clv2_` rename + upstream bugfixes (flock counter #2296, SIGALRM logging #2300, configurable injection #2413) + new `test_parse_instinct.py`; `instinct-cli.py` reconciled by hand (diverged, but verified orthogonal to the rename — zero shell-symbol refs). **Post-sync checks (machine-checkable, no prose exceptions):** `bash -n` on all 5 synced shell files; each synced `status:sync` file byte-identical to the pinned upstream — `git -C ~/.claude/cache/upstream/ecc show <pinned-sha>:<upstream_path> \| cmp - <local_path>` — which subsumes any residue grep (whatever `_ecc_` strings upstream itself retains, e.g. heredoc Python or the storage dir name, are correct by definition) | partial-rename runtime break |
| C-3 | `scripts/hooks/pre-compact.js` + NEW `scripts/lib/llm-summary.js` together (hook wired at hooks.json:216; upstream line 18 requires it). Review llm-summary.js content per #279 before commit. **Register llm-summary.js in the manifest** (source: ecc, status: sync) | MODULE_NOT_FOUND at hook time; unregistered vendored file |
| C-4 | Remaining safe ECC syncs: `session-start.js` (+53/−4 env-overridable thresholds), `tdd-workflow` SKILL (+64/−7 runner matrix; its referenced script already exists here) | — |
| C-5 | mattpocock: refresh `skills/diagnose` content from `engineering/diagnosing-bugs` + update manifest upstream_path (verified true rename — near-identical content, old path deleted upstream). NOTHING else (4 of 5 claimed "successors" refuted) | overwriting live skills with non-successors |
| C-6 | marketing-ads vault fork: merge upstream v2.1.0 content delta (audience-identifiers→feed-creative reframe, verified in upstream VERSIONS.md) while preserving the PR #276 namespace/link adaptations | reverting deliberate adaptations |
| C-7 | gstack supplement refreshes (4 one-liners, all quote-verified upstream): skill-supply-chain "SKILL.md is executable prompt code — never exclude as docs"; llm-security-audit user-message-position FP precedent; diff-aware-qa no-route→Quick-mode fallback; directory-freeze remove doubly-stale "future work" line | supplement rot |
| C-8 | Gate: full test suite (`npm test`, `scripts/test-python.sh`, `tests/test-agent-effort-tiers.sh` explicitly, `test-vault-references.sh`, `test-upstream-manifest.sh`); **hook module-resolution smokes** (bare `require()` of a hook CLI executes top-level code — don't): `node --check scripts/hooks/pre-compact.js`, `node --check scripts/lib/llm-summary.js`, `node -e "require.resolve('./scripts/lib/llm-summary.js')"`, plus one wrapped run: `echo '{}' | node scripts/hooks/pre-compact.js` under a temp state dir asserting exit 0 and no MODULE_NOT_FOUND on stderr — **scope honestly documented: this proves only "module graph resolves on minimal stdin", not hook correctness** (use a saved real PreCompact payload fixture if one exists); **clv2 smoke**: run `detect-project.sh` + `load_instincts.py` against a temp state dir (note: cross-runtime path-mismatch risk was REFUTED — storage dir name `ecc-homunculus` unchanged upstream in shell+JS, only shell fn names renamed; smoke is belt-and-suspenders); litmus; PR | import-time failures broad suites never exercise |

Explicit skips: mass-import of ECC's 142 new files (vault additions are Tranche D consent items), the 92 marketingskills namespace-adapted forks (our own adaptations), nextlevelbuilder's 3 CI scripts + CSV deletion (C4), ui-ux-pro-max's 21-file upstream evolution (deferred — deserves its own review pass, flagged as follow-up).

## Tranche D — Consent-gated vault additions (NO action until per-name "yes")

**Consent recording:** each granted consent (candidate name, action, date, operator's wording) is recorded in the adopting PR's body — durable and auditable; ADR 0010 stays the policy anchor. **Denials/deferrals** are recorded in this table (strikethrough + date) so candidates are never re-asked.

| Candidate | Proposed | One-line evidence |
|---|---|---|
| `loop-design-check` (ECC, new) | vault + promote live | judgment-layer loop review (decidable-goal gate, runaway modes); verified no live equivalent |
| `wayfinder` (mattpocock, new) | vault | multi-session fog-of-war investigation planning; no busdriver equivalent; caveat: `in-progress/` status upstream |
| `codebase-design` (mattpocock, new sibling) | vault | deep-modules vocabulary; NOT a refresh of improve-codebase-architecture (both live upstream) |
| `domain-modeling` + CONTEXT/ADR formats (mattpocock, new) | vault | DDD glossary + sparse-ADR discipline; companion to grill-with-docs |
| `supabase` router (supabase, new) | vault only if Supabase-beyond-Postgres is real | broad first-party router; runtime-fetches changelog (verified line 16) |
| `marketing-loops` (marketingskills, new) | vault w/ PR #276 namespace adaptation | completes the vaulted marketing pack |
| `brandkit` (taste-skill, new) | vault only if brand-board demand exists | 798-line brand-guideline image-gen; YAGNI otherwise |
| `delivery-gate` (ECC, new) | default skip | overlaps existing Stop hooks; listed for completeness |

Backlog (recorded, not built): GSD `STATE.md` living-position spine; GSD verify-coverage step (requirement-ID traceability — verified absent from litmus/pr-grind). Revisit only when the continuity gap is felt in practice.

## Out of scope / cleanup
- Stray `outer/.claude/bypass-log.jsonl` (Jul 5 test artifact) — propose `rm` after operator confirm.
- `ui-ux-pro-max` upstream evolution review — follow-up task, not this plan.

## Failure modes this plan explicitly guards against
1. Effort-line clobber (C1, B6, C-8 test) — the near-miss that survived two agent layers.
2. Partial clv2 rename (C-2 atomic set, verified as 5 shell files).
3. Hook MODULE_NOT_FOUND (C-3 pairing).
4. Overwriting live skills via refuted "successor" mappings (C-5 scoped to the 1 verified rename).
5. Deleting live skills by mirroring upstream path-moves (C4).
6. Manifest lies: pattern-derived gstack gets no file mappings (B1); byte-identical vendored files stop claiming `local` (B3/B4).
7. Silent extensionless-file gaps in future syncs (Prerequisite section — the detector fix + dry-run fixture check, done before any tranche).
8. Guards that cannot fire: pinned SHAs are full 40-char (short-pin equality never passes); effort-line guard runs pre-merge on the branch (post-merge `git diff main` is vacuous); hook smokes use `node --check`/`require.resolve` + wrapped run (bare `require()` of a hook CLI executes it).

<!-- design-reviewed: PASS -->
<!-- design-review-coverage: DEGRADED 2/3 reviewer_3=runtime-droid-rescue -->
