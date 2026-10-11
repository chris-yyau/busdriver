# pr-grind auto-kicks Cursor cloud Shipping (#929)

**Status: implemented** (#929, hardened in #937). Where this spec and the code differ, the code is authoritative: `scripts/needs-shipping.py`, `scripts/shipping-kick.py` and `skills/pr-grind/references/completion.md`. Known differences are listed in "Implementation notes" below, and this spec is not re-synced line by line.

## Context
ADR 0054 makes `/pr-grind` stop at "Ready for Shipping" when a PR's base tree has `.cursor/skills/verify-*/` and the PR touches anything outside a docs/tests skip list. After that stop, nothing starts Shipping. The 2026-10-07 plan scoped it out: "The operator kicks Shipping; automation can come later" (`docs/plans/2026-10-07-pr-grind-shipping-handoff.md:248`). So opted-in PRs sit open until the operator remembers.

The D1/D2/D4 labels below are the plan's decision labels (plan lines 29, 37 and 58), which ADR 0054 accepted.

**Branch protection.** Measured 2026-10-09 with `gh api repos/Dive-And-Dev/<r>/branches/main/protection` and `gh api repos/Dive-And-Dev/<r>/rulesets`:

| Repo | Up to date required (`strict`) | Required checks | `enforce_admins` | Required reviews | Push restrictions | Rulesets |
|---|---|---|---|---|---|---|
| diveand.dev | true | 8 | false | none | none | 0 |
| jikdak | true | 6 | false | none | none | 0 |
| chrisyau.me | true | 7 | false | none | none | 0 |

Consequences:
- BEHIND is the normal state of an open PR once `main` moves.
- GitHub refuses a merge whose head is behind the current base.
- Rulesets add rules on top of classic protection rather than replacing it. With none, the classic protection the kicker reads (step 7) is the whole of what GitHub enforces on `main`.
- `enforce_admins=false` lets an admin merge past strict and required checks, and the cloud agent acts with the operator's admin identity (S0 D1). The operator decided (2026-10-09) to turn on "Do not allow bypassing" in the three repos; the kicker refuses until it is on (step 7). The D4 escape and Dependabot auto-merge do not use admin bypass and keep working. pr-grind's own Branch-Currency `[admin]` option for a BEHIND PR (`completion.md:725`, `:791`) will be refused in these repos; the operator updates the branch instead.
- Every required check in diveand.dev and jikdak is pinned to GitHub Actions (`app_id` 15368). chrisyau.me's `test` has `app_id` null, so a commit status from any source satisfies it. The kicker refuses such a repo (step 7) until the operator pins it.

**`baseRefOid` is not the live base tip.** Measured on busdriver#911: it still reports the 2026-10-01 commit `f67be922` while `main` is `6b4368ad`. ADR 0054 D1 decides opt-in from it today. This design moves opt-in and every new input to the live tip of the base branch (`base_tip`).

**Cursor reads more than `.cursor/`.** Cursor's docs say it loads skills from `.claude/skills/` for compatibility (cursor.com/docs/skills) and reads `AGENTS.md` and `CLAUDE.md` at the project root as rules (cursor.com/docs/cli/using). A forum report says a `.claude` skill did not trigger in a cloud agent, so cloud behaviour is uncertain. This design treats all of them as agent configuration.

## Goal
On a Ready-for-Shipping completion, pr-grind posts ONE `@cursor` comment, then stops as today. Following pstack Shipping, the comment asks the cloud agent to:
- verify with the base branch's verify skill(s);
- on PASS, bring the branch up to date if it is behind, using GitHub's server-side update (no push);
- confirm the update added only base content, wait for required checks, and land pinned to the head it checked.

No human step.

## Spike S0 — done, PASS
One hand-posted trial of the template on Dive-And-Dev/jikdak#531 (2026-10-08 UTC). The PR was operator-authored, same-repo and BEHIND by one commit at kick. The operator ruled S0 PASS on 2026-10-09. Full record: ADR 0055.

All six criteria held:
- the agent posted a `PASS+NOTES` verdict before updating;
- it updated the branch and ran all four structural checks;
- the PR merged, about 12.5 minutes after the kick;
- the final head `H` was the clean merge (2 parents, `H^1` the reviewed head, `H^2` the main tip, tree equal to `merge-tree`);
- all 6 required checks were green on `H`;
- the branch held no agent commit other than the update merge.

Deviations that change this design:
- **D1. The agent acts as the operator.** Its verdict and result comments have `user.login` = the operator, and the update merge is authored as the operator. Only the first ack is `cursor[bot]`. `mergedBy` reports `app/cursor`. So no check may tell agent output from operator output by author. Dedupe relies on the marker alone, and the comment tells the agent never to repeat it.
- **D2. `gh pr update-branch` is refused in the cloud agent** (`Resource not accessible by integration`, the GraphQL `updatePullRequestBranch` path). The agent reached the same update through the REST API. The template now names the REST call, `PUT repos/<o>/<r>/pulls/<N>/update-branch` with `expected_head_sha`, which also makes the head check atomic on GitHub's side.
- **D3. The `cursor[bot]` ack is edited after the merge** into a summary. Nothing in this design reads it.

S0's verdict named the skill, `M`, the head and per-feature evidence, but not the commit it loaded the skill from. The template now asks for that line.

## Components

### 1. `scripts/needs-shipping.py` (classifier, stays read-only)
On exit 10 the stdout line becomes:

```
shipping mergeStateStatus=<S> base_ref=<name> base_tip=<40-hex> skills=<a,b|-> agent_config_edited=<0|1> files_incomplete=<0|1> author=<login|-> cross_repo=<0|1>
```

- **`base_ref`**: the PR's `baseRefName`, validated against `^[A-Za-z0-9_](?:[A-Za-z0-9._/+=-]|(?<=[A-Za-z0-9_])@)*$` and rejected if it contains `..`. `@` is allowed only directly after a letter, digit or `_`; after `/`, `.` or `-` GitHub would autolink it as a mention in the posted comment. A name that fails validation → exit 1.
- **`base_tip`**: the live tip of the base branch. It is read with `gh api repos/<o>/<r>/git/ref/heads/<base_ref> --jq .object.sha`, a branch ref and never a same-named tag, and must be 40-hex. Slashes in `<base_ref>` stay literal in this path (it is a ref path), unlike the percent-encoded protection read in the kicker's step 7. Any failure → exit 1.
- **Opt-in moves to `base_tip`.** `opted_in()` walks `base_tip`'s tree instead of `baseRefOid`'s. `pr_view` also requests `baseRefName`. The closing movement check re-reads the head, `baseRefName` and the base ref; a moved head, a retargeted base or a moved `base_tip` → exit 1 `head or base moved while classifying; re-run /pr-grind`. Because `base_tip` is read before opt-in is known, a bad base name, a failed ref read or a base move during classification now exits 1 in every repo, not only opted-in ones. In busdriver, where a release commit lands right after each merge, that can mean an occasional re-run. Accepted as friction, not a safety issue. This changes ADR 0054 D1 in both directions:
  - a repo newly opted in on main routes its open PRs to Shipping at once, even when their cached `baseRefOid` predates the skill;
  - a repo that opted out on main stops routing at once.
- **`skills`**: walked from the same `base_tip` tree:
  - the `verify-*` directory names, sorted and comma-joined;
  - `-` when ANY `verify-*` name fails `^verify-[A-Za-z0-9][A-Za-z0-9._-]*$`;
  - an invalid name still opts the repo in but blocks the kick.
- **Agent-config paths.** Matched by path component at any depth. Cursor discovers skill directories in nested subdirectories (cursor.com/docs/skills), runs subagents from `.claude/agents` and `.codex/agents` in Cloud Agents, and loads Claude Code hooks from `.claude/settings.json`. Listing subdirectories one by one kept missing some, so whole directories count. A path is agent config when it, or the previous path of a rename:
  - has a component `.cursor`, `.claude`, `.codex` or `.agents`; or
  - has basename `AGENTS.md`, `CLAUDE.md`, `.cursorrules`, `.cursorignore` or `.cursorindexingignore`. The two ignore files narrow what the agent's file tools can see, so a merged edit blinds every later verifier. `.gitignore` is deliberately not included.
- **`agent_config_edited=1`** when any changed path is agent config.
- **`files_incomplete=1`** when the listing may be incomplete: records==0 or records>=3000, the classifier's existing truncation conditions. It is separate from `agent_config_edited`, because the operator cannot review a change set that was never listed.
- **`author` / `cross_repo`**: taken from `author.login` and `isCrossRepository`, both added to the existing `gh pr view`. `author` is `-` when the login is null, empty, or contains anything other than ASCII letters, digits and the six characters slash, underscore, dot, square brackets and hyphen, or starts with something other than a letter or digit. App authors such as `app/dependabot` and bot logins such as `renovate[bot]` pass. `cross_repo` is `0` only when `isCrossRepository` is JSON `false` and `1` only when it is JSON `true`; a missing, null or non-boolean value → exit 1.
- **Skip-list change (D2).** An agent-config path is never skippable. Today the skip list lets these through:
  - root `AGENTS.md`, `CLAUDE.md` (via the root-`*.md` rule) and `docs/AGENTS.md`, `docs/CLAUDE.md` (via `docs/`);
  - every `.claude/**/*.md`, such as `.claude/CLAUDE.md`, `.claude/agents/verifier.md` and `.claude/skills/x/SKILL.md` (the `.claude/**/*.md` rule is removed);
  - `tests/.cursorrules` and anything agent-config under `docs/`, `tests/` or `__tests__/`, such as `docs/.agents/skills/x/SKILL.md` or `tests/.cursor/rules/x.mdc`.

  A PR editing only such a file merges with no Shipping run, and every later kicked agent reads it. It now routes to Shipping, gets `agent_config_edited=1`, and is never auto-kicked. Cost: in an opted-in repo, a `CLAUDE.md`-only PR now needs a hand review and the D4 escape.
- Exit 0 and the error lines are otherwise unchanged.

### 2. `scripts/shipping-kick.py` (new writer)
- **Runtime:** `/usr/bin/python3 -I`, 3.9-compatible.
- **`gh` calls:** every call reuses `needs-shipping.py`'s `gh()` environment handling (`GH_HOST=github.com`; from the `GH_*`/`GITHUB_*` family only `GH_TOKEN`, `GITHUB_TOKEN` and `GH_CONFIG_DIR` pass through; 120s timeout per call) and an explicit `-R` or `repos/<o>/<r>` path.
- **Invocation:** `shipping-kick.py <owner/repo> <PR> <REVIEWED_HEAD>`.
- **Classifier:** the kicker runs the classifier itself as a subprocess (`/usr/bin/python3 -I <same dir>/needs-shipping.py <owner/repo> <PR> <REVIEWED_HEAD>`) and takes every security input from that output. Nothing else is trusted from the dispatcher.
- **Output:** each outcome prints one status line and nothing else. The comment body is never printed: a printed body is a ready-made kick the local session could post itself, which would turn every refusal into an instruction-only bound.
- **Agent-config suffix:** when `agent_config_edited=1`, every non-zero exit line other than one that already lists the `agent-config` token ends with `; also: agent-config`, so no refusal can hide that the PR edits agent configuration.

Steps, in order:
1. `gh api user`, read `login`. On failure → exit 1 `error: <reason>`.
2. Run the classifier. An exit other than 10, or an unparseable line → exit 6 `stale or not shipping-routed (classifier exit <n>[: <its error reason>]): re-run /pr-grind`, so an API or auth failure (classifier exit 1) is visible as such. The reason is the classifier's `error:` line, cut to one line of at most 200 characters with control characters removed. The classifier already fails when the head moved.
3. **Dedupe.**
   - Read `gh api --paginate --jq '.[]' repos/<o>/<r>/issues/<N>/comments`, which gives one compact JSON object per line. Split on `\n` only, as the classifier does, so a U+2028 inside a comment cannot break the listing.
   - Keep comments whose `user.login` is the operator and whose `body` contains `<!-- busdriver-shipping-kick head=<REVIEWED_HEAD> -->`. A match → exit 4 `already kicked: <html_url>`.
   - The agent also posts as the operator (S0 D1), so the author filter only drops third parties. The template tells the agent never to repeat the marker.
   - A failed or unparseable listing → exit 1. Nothing is posted.
4. **Eligibility.** Reason tokens, in this fixed order:
   1. `cross-repo` when `cross_repo=1`;
   2. `author` when `author` is `-` or not the operator (logins compare case-insensitively here and in step 3, as GitHub treats them);
   3. `files-incomplete` when `files_incomplete=1`;
   4. `agent-config` when `agent_config_edited=1`.

   If any of the first three holds → exit 3 `not eligible: <reasons>`, listing every applicable token (including `agent-config` if set), comma-joined. `agent-config` alone does not exit here; it is decided at step 8, after every other gate has passed, so its line tells the operator nothing else blocks the PR.
5. **Status.** Read live `mergeStateStatus` (`gh pr view <N> -R <o>/<r> --json mergeStateStatus`).
   - If it is `UNKNOWN`, re-read up to 3 times, 10s apart.
   - Anything other than `CLEAN`, `UNSTABLE`, `HAS_HOOKS` or `BEHIND` → exit 2 `not kicked: mergeStateStatus=<S>`.
   - BEHIND is kickable because the agent updates the branch itself.
6. **Skills.** `skills=-` → exit 5 `not kicked: no usable verify skill name`.
7. **Protection precondition.** Read `gh api repos/<o>/<r>/branches/<base_ref, percent-encoded>/protection` (a slash in the name is encoded, as `completion.md:844` does with `@uri`) (the full response: `enforce_admins` plus `required_status_checks`).
   - The read is status-aware (`gh api -i` or an equivalent), because the shared `gh()` wrapper cannot tell a 404 from other failures. A failed read other than 404 → exit 1.
   - Exit 2 `not kicked: protection precondition (<first failing condition>)` on any of:
     - the repository is not private (`gh api repos/<o>/<r> --jq .private` is not `true`). The agent reads the PR conversation, so in a public repo any GitHub user could comment injected instructions on an operator PR, reopening the surface the author and fork gates close. All three opted-in repos are private (measured 2026-10-09);
     - 404 (an unprotected base, such as a stacked PR's);
     - `enforce_admins.enabled` not true. The agent acts with the operator's admin identity (S0 D1), and without it GitHub lets an admin merge past strict and required checks (`gh pr merge --admin` or the API);
     - `required_status_checks.strict` not true;
     - `required_status_checks` absent or null, or an empty `checks` list;
     - any required check whose `app_id` is not 15368 (GitHub Actions). A null `app_id` lets a commit status from any source satisfy it, and Cursor's GitHub app holds "Checks and statuses" permission, so only an allowlisted source app counts as independent of the agent;
     - any check name (`context`) that is empty, longer than 100 characters, or contains a comma, backtick, `<`, `>` or a control character.
   - Otherwise the check names are passed into the comment. The agent may lack permission to read protection itself, and the operator's token can (measured).
8. **Agent-config.** If `agent_config_edited=1` (by now the only reason left) → exit 3 `not eligible: agent-config mergeStateStatus=<S>` (the status step 5 accepted). Nothing is posted and no body is printed; the operator lands it with the D4 escape after reviewing it (Operator recovery).
9. **Post.** Re-read `headRefOid`; if it is not `<REVIEWED_HEAD>` → exit 6, since Cursor loads agent config from the head it sees. Then `gh api -X POST repos/<o>/<r>/issues/<N>/comments -F body=@<tmpfile>`, then print `kicked: <html_url> mergeStateStatus=<S>` (the status step 5 accepted) and exit 0.
10. **Post failure.** Re-run step 3:
   - marker found → exit 4;
   - marker not found → exit 7 `post failed: <reason>; re-run /pr-grind`. The re-run re-checks every gate and posts again. A re-read can miss a comment that was in fact delivered, so a re-run can occasionally duplicate a kick. That costs one extra run; the second agent's pinned merge is refused once the first lands;
   - re-read fails → exit 1 `error: delivery unknown; check PR #<N> before posting anything`.

**Comment body.** Built only from:
- the PR number;
- `owner/repo`;
- the validated `base_ref`;
- the 40-hex `base_tip` and head;
- the validated skill names;
- the validated required-check names.

It contains no PR-authored text.

```
@cursor Ship this PR with pstack Shipping (poteto-mode playbooks/shipping.md).
0. Setup. First read `gh pr view <N> -R <owner/repo> --json headRefOid`; if the head is not <SHA>, post "head moved" and stop. Run every git step below on <SHA> explicitly, never on the checked-out branch. Run `git fetch --no-tags origin +refs/heads/<base_ref>:refs/remotes/origin/<base_ref> <base_tip> <SHA>`. If `git rev-parse --is-shallow-repository` prints true, run `git fetch --unshallow origin`. `git merge-tree --write-tree` needs git 2.38 or newer. If any of this fails, post "SETUP FAIL: <what failed, git version>" and stop.
1. Verify with EVERY skill listed: /<skill>[, /<skill>...]. Load each from commit <base_tip> (list its files with `git ls-tree -r --name-only <base_tip> .cursor/skills/<skill>/`, then read each, starting with SKILL.md, with `git show <base_tip>:<path>`), never this PR's copy; if any cannot be loaded there, post FAIL. Let M be `git merge-base <base_tip> <SHA>`. Drive parent M vs head <SHA>. For each skill, post PASS, PASS+NOTES or FAIL with per-feature evidence, plus one line naming the skill, the commit it was loaded from, M and <SHA>. The overall verdict is PASS only if every skill returns PASS or PASS+NOTES.
2. Only on an overall PASS. Before each of a, b and c, require `gh pr view <N> -R <owner/repo> --json baseRefName,state` to show baseRefName <base_ref> and state OPEN; otherwise post the change and stop.
   a. Read `gh pr view <N> -R <owner/repo> --json headRefOid`. If the head is not <SHA>, post "head moved" and stop. Run `git fetch --no-tags origin +refs/heads/<base_ref>:refs/remotes/origin/<base_ref>`. If origin/<base_ref> is an ancestor of <SHA> (`git merge-base --is-ancestor origin/<base_ref> <SHA>`), H is <SHA>; go to b. Otherwise run `gh api -X PUT repos/<owner/repo>/pulls/<N>/update-branch -f expected_head_sha=<SHA>` (never `gh pr update-branch`, never --rebase, never git push). If it exits non-zero, post its output (a conflict means "FAIL: base conflicts, needs a manual merge") and stop. GitHub creates the update commit asynchronously, so poll `gh pr view <N> -R <owner/repo> --json headRefOid` every 10s for up to 5 minutes until it differs from <SHA>; on timeout, post that and stop. Read the new head H (below, H means that 40-hex SHA, not a ref name), run `git fetch --no-tags origin +refs/heads/<base_ref>:refs/remotes/origin/<base_ref> H`, and require all of:
      - `git rev-parse H^1` equals <SHA>;
      - `git merge-base --is-ancestor H^2 origin/<base_ref>` succeeds;
      - `git rev-list --parents -n 1 H` lists exactly two parents;
      - `git rev-parse H^{tree}` equals `git merge-tree --write-tree <SHA> H^2` (the clean merge, nothing else).
      If any check fails, post which one and stop.
   b. The required checks are: <check>[, <check>...]. Every 60s for up to 45 minutes, run `gh pr checks <N> -R <owner/repo> --required --json name,bucket` and decide from the listed buckets, not the exit code; read `gh pr view <N> -R <owner/repo> --json headRefOid` on each poll for the head. First, a `fail` or `cancel` bucket on a required check, or a head other than H, means stop with the blocker. An error saying "no checks reported" or "no required checks reported" (a new head whose checks have not started), a required check missing from the list, or a `pending` bucket means wait and poll again. Continue only when every required check above is listed with bucket `pass` or `skipping` and the head is still H. On timeout, stop with the blocker.
   c. Run exactly: gh pr merge <N> -R <owner/repo> --squash --delete-branch --match-head-commit H
3. Post the verdict, the kicked head <SHA>, H, and the merge commit SHA or what blocked it. Never push commits, rebase, or edit files on this branch. Never repeat the marker line below, and never write `@cursor`, in anything you post.
<!-- busdriver-shipping-kick head=<SHA> -->
```

### 3. `skills/pr-grind/references/completion.md`
Exit-10 handling. Exit 0 and the error paths are unchanged, and the Shipping block itself is unchanged.

**a. `--no-merge`.** A kick authorizes a merge, so with `--no-merge` run the Shipping block, print the Ready line plus `auto-kick skipped: --no-merge; the operator may kick Shipping by hand`, and stop. This is the only eligibility the prose decides; the kicker owns every other one, so its reason tokens are what the operator sees.

**b. Otherwise.** Run the Shipping block, then `/usr/bin/python3 -I "${CLAUDE_PLUGIN_ROOT}/scripts/shipping-kick.py" <o>/<r> <N> <REVIEWED_HEAD>`.
- The Ready line reports the kicker's line in place of today's "Kick Cursor Cloud Shipping on PR #<N>" (`completion.md:1383`).
- After the kicker's line, print exactly one follow-up:
  - exit 3 naming `author` or `cross-repo`: `security refusal: review this PR yourself before landing it by any route`, and no command;
  - exit 2 for a protection precondition, or exit 5: `fix that, then re-run /pr-grind`. These are repository settings or skill names, not a property of the PR;
  - exit 4: `to retry this head, delete that comment, then re-run /pr-grind`;
  - exits 1, 6 and 7: none; their lines already say what to do;
  - exit 2 for `mergeStateStatus`: `fix that (conflict, draft, failing check or uncomputed status), then re-run /pr-grind`, and no merge command. The PR passed every other gate, so the re-run kicks it;
  - exit 3 whose tokens are only `files-incomplete` and/or `agent-config`: the ADR 0054 D4 escape (`.claude/skip-pr-grind.local` + `gh pr merge`). When the PR is BEHIND, the escape starts with `gh pr update-branch <N> -R <o>/<r>` (the operator's own token, where the GraphQL path works). BEHIND is read from the kicker's line for the step-8 exit 3, which carries the status step 5 accepted, and from the classifier's exit-10 line for a step-4 exit 3, which ends before step 5.
- Whenever the line carries the `agent-config` token or the `also: agent-config` suffix, also print `this PR edits agent configuration: review it before landing it by any route`.
- No kicker exit leads to a `RESULT_BAIL_CATEGORY` or to `gh pr merge` run by pr-grind.
- Also update the skip-list descriptions that agent-config paths now contradict: `completion.md:571`, and the `needs-shipping.py` module docstring.
- The kicker never causes a BAIL or a merge.
- The classifier's `mergeStateStatus` warnings are not printed when the kicker exits 0, since the kicker re-read the status.

**c. Stdout grammar.** The exit-10 match at `completion.md:577` widens from the fixed `shipping mergeStateStatus=<S>` form to `shipping mergeStateStatus=<S>` followed by exactly the seven `key=value` fields above, in that order. Any other line is handled as today's "stdout that does not match" catch-all (BAIL `env`).

**d. Wording.**
- `completion.md:1384` ("Shipping rebases the bottom PR itself") becomes "The cloud agent updates a BEHIND branch after PASS.", printed only on a kicker exit 0 whose line reports `mergeStateStatus=BEHIND`. On a non-zero exit only the §3b follow-up is printed.
- `:1385-1386` ("…before kicking Shipping") are removed; the §3b follow-ups replace them.

### 4. `skills/pr-grind/SKILL.md`
Update each place that says exit 10 stops with no further action: lines 19, 83, 863-865 and 1749. The new wording: the grind still stops, after posting one Shipping kick when eligible. Line 83's skip-list description also gains "agent-config paths are never skipped".

### 5. `skills/finishing-a-development-branch/SKILL.md:123`
New wording: "pr-grind posts the Shipping kick itself. Never post an `@cursor` comment yourself, in any mode, AFK included. After a skip, report the skip line to the operator; after exit 7, re-run `/pr-grind`. A skip for author or fork is a security refusal." The rule binds the local session by instruction only, which is acceptable because the session has no body to post: the kicker never prints one.

### 6. `docs/adr/0055-pr-grind-shipping-kick.md`
- Records the decisions, the S0 result, the protection, rulesets and `baseRefOid` measurements, and the accepted risks.
- Supersedes the plan's out-of-scope line quoted in Context, amends ADR 0054 D1 (opt-in from `base_tip`), D2 (agent-config paths never skippable), D4 (exit 10 still routes under `--no-merge`, but `--no-merge` now suppresses the kick, §3a) and its BEHIND reporting.
- Records that plan D3's accepted consequence widens: the `base_tip` ref read now runs in every repo, so a failure there BAILs `env` in repos that never opted in (§1).
- Gives ADR 0054 a one-line "Amended by ADR 0055" pointer.

### 7. `scripts/hooks/post-bash-pr-created.js:75-76`
The post-PR instruction "If pr-grind prints "Ready for Shipping", stop: do not merge, and do not re-run with `--no-merge`; Cursor Cloud Shipping lands it." becomes "If pr-grind prints "Ready for Shipping", stop: do not merge, do not re-run with `--no-merge`, and never post an `@cursor` comment yourself; pr-grind posts the Shipping kick when the PR is eligible." The file is pinned in `.gate-integrity.lock`, so the same change runs `./scripts/gate-integrity.sh --update`.

## Decisions (grilled, Q1 revised after review, S0 folded in)
- **Landing.** The cloud agent merges on an overall PASS, pinned with `--match-head-commit` to the head it checked. Proven by S0.
- **BEHIND.** The cloud agent decides "behind" by ancestry, not by `mergeStateStatus`, since `UNKNOWN` or `BLOCKED` can hide BEHIND. After PASS it calls GitHub's REST update-branch with `expected_head_sha` (S0 D2). It then proves structurally that the new head is exactly the clean merge of the verified head with a base commit: the first parent is the verified head, the second parent is on the base, and the tree equals `git merge-tree`. It waits for the named required checks on the new head and merges pinned to it. Patch-id was rejected because it ignores whitespace, as ADR 0004:86-89 already established. pr-grind does nothing for BEHIND beyond kicking.
- **Author allowlist.** Only the operator's own account (the authenticated `gh` user). Never a cross-repo PR.
- **No spend cap.** One kick per new clean head, deduped by the marker.
- **Opt-in source.** `base_tip`, for both opt-in and skills, so the two cannot disagree.

## Operator recovery
- **Base moves before the agent's merge.** GitHub refuses the merge (strict) and the agent reports it, with H next to the kicked head. Two cases:
  - H differs from the kicked head (the agent made an update commit): re-run `/pr-grind`. The head is new, so a fresh grind kicks it.
  - H equals the kicked head (it was already up to date): the marker still matches, so a re-run would exit 4. Delete your marker comment, then re-run `/pr-grind`.
- **Run never starts, goes silent, or FAILs on a flake (same head).** The marker makes a re-run exit 4 by design, so a stuck run is never kicked twice by accident. To retry, delete your marker comment, then re-run `/pr-grind`. The next clean completion then posts a fresh kick.
- **SETUP FAIL.** The cloud environment could not fetch or lacks git 2.38. Fix the environment, delete the marker comment, re-run `/pr-grind`.
- **FAIL that needs a fix.** Push the fix. The next clean grind kicks the new head.
- **Ineligible PR.** Follow the printed skip line. For a skip whose only reason is `agent-config`, review the change yourself and land it with the D4 escape, whose skip file only the operator can create. Busdriver never produces a kick for an ineligible PR. A `files-incomplete` skip means nobody has seen the full change set; review it in full before using the escape. An `author` or `cross-repo` skip is a security refusal, and pr-grind prints no escape for it.

## Not doing
- Waiting for or polling the cloud agent.
- A kill switch. Opting the repo out of Shipping is the off switch.
- The Cloud Agents API, which would need a per-repo secret.
- A lock against concurrent kickers (see Risks).
- Reading rulesets in the kicker. They are measured empty; re-measuring is the revisit trigger.

## Risks accepted (ADR 0055)
- **Prompt injection.** The cloud agent reads the PR diff, body and conversation (comments and review threads, including other reviewers' text), so an injected instruction could make it PASS and merge.

  Bounds enforced outside the agent (they hold even if the agent is subverted):
  - operator-authored, non-fork PRs only;
  - no auto-kick when the PR touches an agent-config path (any `.cursor`, `.claude`, `.codex` or `.agents` component; `AGENTS.md`, `CLAUDE.md`, `.cursorrules`, `.cursorignore`, `.cursorindexingignore`; all at any depth) or its file list may be incomplete, all computed by the kicker. This binds the kicker, not the local session: the session holds the same `gh` token and could write an `@cursor` comment itself. Against that it has only the §5 instruction, and the kicker never hands it a body to post. It also covers only the classified diff: a push between the post and the cloud agent's checkout changes the tree Cursor boots on, and config Cursor applies from that checkout before the prompt runs is outside both this gate and the comment (step 0's head check stops the run, but only after that config loaded). Pushing needs write access, so this adds little to the push residual below;
  - strict protection with required checks pinned to GitHub Actions, enforced for admins too, re-checked by the kicker before posting. GitHub then refuses a merge whose head has not passed them.

  Bounds that hold only if the agent follows the comment:
  - skills loaded from the base branch;
  - the head pin, and never pushing to the branch;
  - the structural parents and `merge-tree` check across an update;
  - waiting for the required checks (only liveness depends on this).

  **What a subverted agent can do.** Measured 2026-10-09 (`gh api orgs/Dive-And-Dev/installations`): the Cursor app is installed on all repositories with `contents`, `workflows`, `checks`, `actions` and `pull_requests` write, and `statuses` read. So an injected agent can push new commits to the PR branch under the operator's identity (D1), including edits to `.github/workflows/**` that change what a required check runs, and merge a head the reviewers never saw. The server-side bound then guarantees only that the landed head passed checks that GitHub Actions ran, not that it is the reviewed code, and with workflow write even that is weak. The real bounds against injection are the ones that shrink the injection surface: operator-authored, non-fork PRs that touch no agent-config path. The operator accepted this (agent lands on PASS); it is the same trust model as pstack Shipping kicked by hand, with the operator's per-PR decision to kick removed. The operator cannot narrow these permissions: the app owner (Cursor) sets them, and an installer can only change which repositories the app reaches or suspend or uninstall it (docs.github.com, "Reviewing and modifying installed GitHub Apps"). The exposure therefore lasts as long as Cursor is installed on an opted-in repository. A post-merge audit of landed trees would be a detective control; it belongs in each repository as a follow-up, not in this spec. Files the agent opens of its own accord remain a residual.
- **The agent acts with the operator's GitHub identity** (S0 D1). Its comments and update merge are indistinguishable by author from the operator's own. Accepted; nothing here filters on author to tell them apart.
- **The landed head can differ from the reviewed head.** The difference is GitHub's update-branch merge commit. It is proven to be exactly the clean merge of the reviewed head with base content (parents plus `merge-tree`), and required checks run on it. pr-grind's reviewers never saw it, and the verify run did not drive it. A clean textual merge can still interact semantically with new base commits; required checks are the only net for that.
- **Base churn.** A base move during the check wait refuses the merge, and each re-run kicks a new update head (~20 minutes of verification). No frequency data shows this is common.
- **Spend.** Roughly 13–20 minutes of Cursor cloud agent time per kicked head (S0: 12.5 minutes).
- **New outward write.** The kicker posts with the operator's `gh` token.
- **Concurrent kickers.** Two pr-grind runs finishing on the same head can both post. The second agent's pinned merge is refused once the first lands. Accepted rather than locked.
- **Protection beyond what the kicker reads.** The kicker checks `enforce_admins`, `strict`, the required checks and that each is pinned to a source app. That this is all GitHub enforces rests on the 2026-10-09 measurement of zero rulesets. Re-measuring is the ADR 0055 revisit trigger whenever a repo is newly opted in or adds a ruleset.
- **Direct pushes to the base.** Strict, pinned required checks also refuse a direct push of an unchecked commit (GitHub's GH006), for admins too once `enforce_admins` is on, so a subverted agent gains nothing there beyond the push-then-merge path above.
- **The posted template has never run end to end.** S0 ran an earlier text; the setup step, the REST update-branch call, the per-skill load line and the base checks came after it. The first kicked PR in each repo is a watched trial: the operator checks the verdict and merge evidence and records the result in ADR 0055 before treating that repo as unattended.
- **Skills are pinned to `base_tip` at kick time.** A verify skill added to main during the run is not used. It applies from the next kick.

## Testing

**`tests/test-needs-shipping.sh`**
- Update every exact-match exit-10 assertion (lines 124, 127, 130, 136, 142 and 151) and the line-238 loop over the old Ready-line literals.
- Teach the stub `gh` (lines 32-52) the new base-tip ref read. It runs in every repo, and the stub exits 99 on an unexpected call, so every existing case fails until it does.
- Update the classifier selftest: `.claude/CLAUDE.md` moves from skipped to routed.
- Add cases:
  - `base_ref=` emission, plus an invalid base name exiting 1;
  - `base_tip=` emission, plus a failed ref read exiting 1, and a same-named tag never consulted;
  - opt-in from `base_tip`: `baseRefOid`'s tree lacks `verify-*` while `base_tip`'s has it → exit 10; the reverse → exit 0;
  - skills walked from `base_tip`'s tree even when `baseRefOid` points to an older tree with different skills;
  - a PR editing only root `AGENTS.md`, root `CLAUDE.md`, `docs/AGENTS.md`, `.claude/AGENTS.md`, `.claude/CLAUDE.md`, `.claude/skills/x/SKILL.md` or `tests/.cursorrules` exits 10 with `agent_config_edited=1` (all exit 0 today);
  - `agent_config_edited` for a `.cursor/skills` edit, a delete and a rename-out, a `.cursor/rules` edit, `.agents/skills/x/SKILL.md`, `.codex/skills/x/SKILL.md`, `.claude/agents/verifier.md`, `.codex/agents/x.md`, `.claude/settings.json`, `.cursorignore` and `web/.cursorindexingignore` (edit, delete, rename-out), nested `apps/web/.cursor/skills/x/SKILL.md` and `docs/.agents/skills/x/SKILL.md`, and the paths above alongside a `src/` edit; and `agent_config_edited=0` for `src/skills/x.ts`, `docs/claude/skills.md` and `src/my.claude.ts`;
  - `base_tip` moving between the first read and the movement check exits 1;
  - `files_incomplete=1` for an empty listing and a 3000-record listing, with `agent_config_edited=0` when no listed path is agent config;
  - an author login with a character outside the allowed set, or a leading dot, becomes `author=-`; `app/dependabot` and `renovate[bot]` pass through;
  - `skills=` filtering, multiple skills, and `-` when one is invalid;
  - `author` and `cross_repo` passthrough.
- The existing `run_block` and line-190 Shipping-block tests stay as they are, because the block is unchanged.

**`tests/test-shipping-kick.sh`** (new; `gh` stub plus a stub classifier). One case per exit code:

| Exit | Cases |
|---|---|
| 0 | Posts once. A non-operator marker is ignored. BEHIND posts, and its line ends `mergeStateStatus=BEHIND`. |
| 4 | Operator marker present. Marker on a second comments page. Dedupe beats eligibility and status. Marker present with agent-config (no body). Post fails but the marker is present. |
| 3 | Each reason alone prints exactly its token. Cross-repo plus agent-config prints `not eligible: cross-repo,agent-config` and no body. Author plus files-incomplete plus agent-config prints all three in order. Agent-config alone, with every other gate passing, prints only `not eligible: agent-config mergeStateStatus=<S>` and posts nothing; with the classifier line at CLEAN and step 5 reading BEHIND, the line reports BEHIND. No exit-3 case prints any line of the comment body. |
| 2 | BLOCKED, DIRTY, DRAFT, UNKNOWN after 3 re-reads. A public repository. Protection read 404. `enforce_admins.enabled=false`. `strict=false`. `required_status_checks` null. Empty checks. Each prints its condition. A check with `app_id` null, and one pinned to an app other than 15368. A check name with a backtick. Each of these combined with agent-config still exits 2 with no body, and its line ends `; also: agent-config`. |
| 5 | `skills=-`, alone and combined with agent-config (no body; the line ends `; also: agent-config`). |
| 6 | Classifier exits 1 (the line carries its error reason) or 0. The head moves between classification and the post; nothing is posted. |
| 1 | `gh api user` fails. The comment listing fails. The protection read fails. A post fails and the re-read fails (no body printed). |
| 7 | A post fails with the marker not found; only the status line is printed, with no line of the body. |

Also check:
- `UNKNOWN` then `CLEAN` posts.
- Classifier: `isCrossRepository` omitted, `null` or the string `"false"` each exit 1; `skills` is sorted; a `release/1.2` base reads the ref path with the slash unencoded and the protection path with `%2F`.
- An ambient `GH_HOST` or `GH_REPO` does not reach `gh`.
- The body contains only the allowed fields, names `base_ref` and `base_tip`, lists every skill and every required check, and contains: the setup fetch refspec and unshallow step, the per-skill load-commit line, the base-name check, the ancestry test, the REST update-branch call with `expected_head_sha`, the four structural checks, the check predicate (decided from buckets, not the exit code; `fail`/`cancel` stop first; "no checks reported", "no required checks reported", a missing check and `pending` mean wait), the kicked head next to H in the step-3 report, the `--delete-branch` merge line, and the never-repeat-the-marker and never-write-`@cursor` instruction. It does not contain `patch-id` or `gh pr update-branch`.

**Selftest for the structural check.** The check runs inside the cloud agent, but its commands are fixed. `tests/test-shipping-kick.sh` builds a scratch repo, runs the ancestry test and the four commands exactly as the template prints them, and asserts both outcomes:
- they accept a real `git merge --no-ff` of head and base;
- they reject a merge whose tree carries an extra edit, a commit whose first parent is not the head, a three-parent merge, and a merge whose second parent is not on the base;
- the ancestry test reports "not behind" for a head already containing the base tip.

**Prose-order assertions over `completion.md` and `SKILL.md`**
- The `--no-merge` skip comes before the Shipping block, which comes before the kicker; no other eligibility test appears in the prose.
- No exit-10 branch writes the clean marker or merges.
- The 1383/1384/1385-1386 imperatives are gone.
- No follow-up for a `not kicked: mergeStateStatus`, `not kicked: protection precondition`, `author` or `cross-repo` line contains `gh pr merge` or `skip-pr-grind`.

## Implementation notes (#940)

These are the known places where the shipped code differs from the text above; the list is not guaranteed exhaustive. In each one, and in any difference not listed, the code is right.

**§1 classifier**
- The agent-config basenames also include `CLAUDE.local.md` and `.mcp.json` (`AGENT_FILES` in `needs-shipping.py`), and all agent-config path matching, directory components and basenames alike, is case-insensitive. This also applies to the risk list.
- A bare `.cursor/skills/verify-` directory opts the repo in and yields `skills=-`, so the kick is refused (#942).
- The `base_tip` read fetches the full ref JSON instead of using `--jq .object.sha`, and requires `ref == refs/heads/<base_ref>`, `object.type == "commit"` and a 40-hex `object.sha`; any other response exits 1 (plan deviation 1).

**§2 kicker**
- Not every `gh` call is repo-scoped. `operator_login()` makes one global call, `gh api user`, to read the operator's login.
- The classifier subprocess has a 1000s timeout (`CLASSIFIER_TIMEOUT`); a timeout exits 6 `stale or not shipping-routed (classifier timed out after 1000s): re-run /pr-grind`.
- Step 9 posts the body on stdin (`-F body=@-`), not from a temp file.
- The posted template (`TEMPLATE` in `shipping-kick.py`) differs from the copy in this spec in five places:
  - setup requires `git --version` to report 2.38 or newer;
  - the parent check reads "`git rev-list --parents -n 1 H` prints H followed by exactly two parent SHAs";
  - the ancestry check notes that a stale `H^2` is caught by strict protection at merge time;
  - the check poll may span several tool calls;
  - the merge line says to replace the literal H with H's 40-hex SHA.

**§3 completion.md**
- The exit-2 `mergeStateStatus` follow-up ends "…then re-run /pr-grind to evaluate the remaining gates" (`completion.md`, exit table). The claim in §3b that the PR "passed every other gate" is wrong: the kicker stops at the first gate that fails, and later gates are not evaluated.

**Operator recovery**
- `pre-merge-gate.sh` honors the D4 skip file only if `gate_skip_file_repo_controlled` finds it is not repo-controlled (not in the index or HEAD, no tracked symlink or submodule parent, fail-closed on Git errors) and it is 30s to 3600s old. Neither check identifies who created it. Only the operator should create it; the session never does.

**Testing**
- Template step 2a must contain the phrase "never `gh pr update-branch`". The "does not contain `gh pr update-branch`" assertion means that phrase is the only occurrence (plan deviation 5).
- §3a runs the Shipping block in both modes, so the prose order is Shipping block, then `--no-merge` skip, then kicker (plan deviation 6).

**Known residuals (low)**
- Required-check names are not screened for `@` the way `base_ref` is.
- `allow_squash_merge` is never checked. A repo that disables squash merges fails at the agent's merge step.
- The protection read treats a 404 as "no classic protection" and refuses the kick. Rulesets are not read.

<!-- GRILL-DECISIONS-BEGIN -->
## Key Decisions (resolved during grilling)

- **Landing authority after PASS** — chose the same Cursor cloud agent squash-merges on PASS/PASS+NOTES, pinned with `--match-head-commit` to the head it checked. Rationale: matches pstack Shipping, the jikdak#528 pilot and the jikdak#531 S0 run; the operator-kick and busdriver-reads-verdict alternatives keep the manual step the user rejected.
- **BEHIND on the Shipping path** — chose that the cloud agent, after PASS, decides "behind" by ancestry, runs GitHub's server-side REST update-branch with `expected_head_sha` (never a push or rebase), proves the new head is exactly the clean merge of the verified head with base content (parents + `merge-tree`), waits for the named required checks on it, and merges pinned to it; pr-grind only kicks. Rationale: revised by the user after two review runs parked — pr-grind-side updating needed loop re-entry, BASE_SHA recompute, worktree sync and probe state, and keyed on a `baseRefOid` measured not to track main; the agent-side update follows pstack Shipping steps 3-4; S0 showed `gh pr update-branch` is refused in the cloud agent while the REST path works.
- **Kick author allowlist** — chose the operator's own account only (PR author equals the authenticated `gh` user), never a cross-repo PR. Rationale: the public repo accepts fork PRs and ADR 0054 routes on paths, not author; Dependabot is better served by `dependabot-auto-merge.yml` (add it to diveand.dev) than by exposing third-party release-note text to a merge-capable agent.
- **Spend cap** — chose no cap; one kick per new clean head, deduped by the marker. Rationale: a kick only happens on a fully clean grind, and opting a repo out of Shipping is the existing off switch, so a cap is YAGNI until cost is measured.
- **Trigger mechanism** — chose one `@cursor` PR comment posted with the operator's `gh` auth. Rationale: [self-decided] pilot-proven; the Cloud Agents API would need a new secret per repo.
- **Skill name source** — chose that the classifier emits `skills=` from the live base tip's tree (`base_tip`), and `-` if any `verify-*` name fails `^verify-[A-Za-z0-9][A-Za-z0-9._-]*$`. Rationale: [self-decided] reuses the tree walk that decides opt-in, now also read from `base_tip`; an invalid name keeps the opt-in but blocks the kick.
- **Writer separation** — chose a new `scripts/shipping-kick.py` run under `/usr/bin/python3 -I` that invokes the read-only classifier itself. Rationale: [self-decided] the classifier's tests stub read-only `gh` calls, and the security inputs are computed inside the writer instead of being trusted from the dispatcher.
- **Kick status gate** — chose to kick only on `CLEAN`, `UNSTABLE`, `HAS_HOOKS` and `BEHIND`, plus strict protection with a non-empty, validated required-check list, with the gate inside the kicker. Rationale: [self-decided] these are the states the agent can take to a merge (BEHIND via its own update); the gate lives in testable code, not prose.
- **Idempotence** — chose a hidden `<!-- busdriver-shipping-kick head=<SHA> -->` marker, honoured only in operator-authored comments, which the agent is told never to repeat. Rationale: [self-decided] state lives on GitHub and survives worktree removal; a base move is handled by the agent, so the head alone is the right key; S0 showed the agent posts as the operator, so the marker, not the author, is what separates a kick from agent output.
- **Kick failure handling** — chose to never BAIL or merge, to report each outcome with its own exit code, and never to print the comment text; a failed post (exit 7) is retried by re-running `/pr-grind`, and an agent-config skip is landed with the D4 escape. Rationale: [self-decided] the grind is already complete; the failure is visible without blocking; a printed body would be a kick the local session could post past any refusal; a rare duplicate kick costs one extra run whose pinned merge is refused.
- **Watching the cloud agent** — chose not to wait for or poll the agent's result. Rationale: [self-decided] a run takes about 13–20 minutes, and its ack comment is rewritten after the merge, so confirmation belongs to a later check, not the grind.

<!-- design-hash: sha256:22ec88c515329e2e594567ba41c16b290729f13a12c6fc8b06a9b818bdfb9dfe -->
<!-- grill-status: complete -->
<!-- GRILL-DECISIONS-END -->

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
