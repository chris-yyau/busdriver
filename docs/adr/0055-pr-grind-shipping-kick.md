# ADR 0055 — pr-grind kicks Cursor cloud Shipping itself

## Status

**Accepted (2026-10-09).** Spec: `docs/specs/2026-10-09-pr-grind-shipping-kick-design.md`
(issue #929; blueprint-review PASS, FULL 3/3, run 10 round 2). Spike S0 ran and the
operator ruled it PASS on 2026-10-09. Amends ADR 0054 D1 (opt-in source), D2 (skip list), D4 (`--no-merge`
now suppresses the kick on exit 10) and its BEHIND reporting, widens plan D3's accepted
consequence (the `base_tip` read runs in every repo), and supersedes the out-of-scope line at
`docs/plans/2026-10-07-pr-grind-shipping-handoff.md:248`. D-labels are the plan's
decision labels, which ADR 0054 accepted.

## Context

ADR 0054 stops `/pr-grind` at "Ready for Shipping" in opted-in repos, and nothing then
starts Shipping. Opted-in PRs sit open until the operator remembers to kick it.

Measured 2026-10-09 on the three opted-in repos (`gh api .../branches/main/protection`,
`gh api .../rulesets`):

| Repo | `strict` | Required checks | `enforce_admins` | Required reviews | Push restrictions | Rulesets |
|---|---|---|---|---|---|---|
| diveand.dev | true | 8 | false | none | none | 0 |
| jikdak | true | 6 | false | none | none | 0 |
| chrisyau.me | true | 7 | false | none | none | 0 |

Required-check source pinning (`.../protection/required_status_checks` `.checks[].app_id`):
every required check in diveand.dev and jikdak is pinned to GitHub Actions (15368);
chrisyau.me's `test` is unpinned (`app_id` null), so the kicker refuses chrisyau.me until
it is pinned.

`baseRefOid` does not track the base tip: on busdriver#911 it still read `f67be922`
(2026-10-01) while `main` was `6b4368ad`.

Cursor's docs say it loads `.claude/skills/` and reads root `AGENTS.md` and `CLAUDE.md`
(cursor.com/docs/skills, cursor.com/docs/cli/using). ADR 0054's skip list let those
land without Shipping.

### Spike S0 — Dive-And-Dev/jikdak#531, 2026-10-08 UTC

One hand-posted copy of the template on an operator-authored, same-repo PR that was
BEHIND by one commit. Reviewed head `343b43c2`, base tip at kick `38cb73fe`, skill
`verify-jikdak`, cloud agent `bc-4e516b71-3c36-48cf-9770-3b5371cf27d1`.

| Event | From kick |
|---|---|
| `cursor[bot]` ack | +7s |
| Verdict `PASS+NOTES` | +9m34s |
| Update merge `H` = `6c907872` | +10m02s |
| Last required check green on `H` | +11m56s |
| Merged, squash `1b752778` | +12m30s |

All six criteria held: verdict before update; update plus all four structural checks
(independently recomputed: two parents, `H^1` = reviewed head, `H^2` = main tip, tree =
`merge-tree`); merged; final head satisfies the checks; all 6 protection contexts
`success` on `H`; no agent commit other than the update merge.

Deviations:
- **D1.** The agent posts and commits as the operator (`user.login` = operator); only
  the first ack is `cursor[bot]`, and `mergedBy` reports `app/cursor`.
- **D2.** `gh pr update-branch` (GraphQL) is refused in the cloud agent with `Resource
  not accessible by integration`; the agent used the REST API instead.
- **D3.** The `cursor[bot]` ack is rewritten into a summary after the merge.

## Decision

1. On an exit-10 completion, pr-grind runs `scripts/shipping-kick.py`, which posts one
   `@cursor` comment and stops. It never merges or BAILs.
2. The comment asks the cloud agent to verify with every base-branch verify skill loaded
   from `base_tip`, and on PASS: update a behind branch with REST update-branch pinned by
   `expected_head_sha`, prove the update is the clean merge (parents + `merge-tree`),
   wait for the named required checks, and squash-merge with `--match-head-commit`.
3. Kicks only in private repositories (the agent reads the PR conversation, which
   anyone can write in a public repo), for operator-authored, same-repo PRs whose full file list is known and
   touches no agent-config path, on strict protection with a non-empty required-check
   list whose every check is pinned to GitHub Actions (`app_id` 15368, an allowlist),
   and with `enforce_admins` on. The
   agent acts with the operator's admin identity (D1); without `enforce_admins` GitHub
   lets an admin merge past strict and required checks. The operator decided
   (2026-10-09) to turn it on in the three repos. Each refusal prints fixed reason tokens and never the comment body, so the local
   session is never handed a kick it could post past a refusal. An `agent-config`-only
   PR is landed by the operator with the ADR 0054 D4 escape after review.
4. One kick per head, deduped by a hidden marker in operator comments. The agent is told
   never to repeat it, because it posts as the operator (D1).
5. Opt-in and skill names are read from the live base tip, not `baseRefOid`.
6. Agent-config paths (any `.cursor`, `.claude`, `.codex` or `.agents` component;
   basename `AGENTS.md`, `CLAUDE.md`, `CLAUDE.local.md`, `.mcp.json`, `.cursorrules`,
   `.cursorignore`, `.cursorindexingignore`; all at any depth, matched
   case-insensitively) are never skippable. `CLAUDE.local.md` and `.mcp.json` were
   added at implementation, after code review found Claude Code loads them.
7. A bad base name or failed base-ref read now exits 1 in every repo, because the live
   base tip is read before opt-in is known (amends ADR 0054 Consequences).

## Alternatives

- **pr-grind updates BEHIND branches and re-enters the loop.** Rejected after two review
  runs: it needs loop re-entry, a recomputed BASE_SHA, worktree sync and probe state,
  and it keyed on `baseRefOid`.
- **Verify-only comment, separate landing step.** Rejected: keeps the manual step the
  operator wants gone. It was the fallback had S0 failed.
- **Cloud Agents API.** Rejected: a new secret per repo.
- **Patch-id instead of the structural check.** Rejected: patch-id ignores whitespace
  (ADR 0004:86-89).

## Consequences

- Opted-in PRs land with no human step, about 13 minutes after a clean grind.
- The landed head can be GitHub's update merge, which pr-grind's reviewers never saw;
  required checks are the only net for semantic interaction with new base commits.
- The agent acts with the operator's identity; its output cannot be told apart by author.
- A subverted agent can land code nobody reviewed. Measured 2026-10-09
  (`gh api orgs/Dive-And-Dev/installations`): the Cursor app holds `contents`,
  `workflows`, `checks`, `actions` and `pull_requests` write on all repositories, and
  `statuses` read. An injected agent can push commits, including workflow edits that
  change what a required check runs, and merge them under the operator's identity.
  Branch protection then guarantees only that GitHub Actions passed the landed head. The
  bounds that matter are the ones that shrink the injection surface: operator-authored,
  non-fork PRs touching no agent-config path. The operator cannot narrow these
  permissions: Cursor sets them, and an installer can only change repository access or
  suspend or uninstall the app. The exposure lasts while Cursor is installed on the repo.
- In a private repo, anyone with read access (org members, outside collaborators) can
  comment on an operator PR, and the agent reads those comments. Re-measure that set
  alongside rulesets whenever a repo is newly opted in.
- With no required reviews, write access already implies landing power, so a
  collaborator who pushes to an operator PR between the kick and the agent's checkout
  gains nothing new.
- A required check whose name contains a comma (a matrix job such as `test (a, b)`) is
  refused (exit 2). None exists in the three repos today; revisit with a
  newline-delimited list if one is needed.
- `gh pr checks --required` resolves required checks through GraphQL `isRequired`
  (measured with the operator's token, gh 2.102.0). The first watched kick in each repo
  confirms it works with the cloud agent's token; if it does not, the agent waits out its
  45 minutes and never merges.
- The posted template has never run end to end (S0 ran an earlier text). The first
  kicked PR in each repo is a watched trial; record its result here before treating that
  repo as unattended.
- A `CLAUDE.md`- or `AGENTS.md`-only PR in an opted-in repo now needs a hand review and the
  ADR 0054 D4 escape.
- Moving opt-in to `base_tip` changes routing at once when a repo opts in or out on main.
- A base move during the check wait refuses the merge; the re-run kicks a new head.

## Revisit trigger

- A repo is newly opted in, or any opted-in repo adds a ruleset or bypass actor:
  re-measure protection and rulesets.
- Cursor changes the cloud agent's GitHub permissions (D2) or identity (D1).
- Base churn makes re-kicks common enough to cost real time.
