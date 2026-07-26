# ADR 0030 — The pr-grind-clean marker binds to a commit, not just a PR

**Status:** Accepted (2026-07-26)
**Issue:** #505
**Supersedes nothing.** Amends the marker contract described in ADR 0012.

## Context

`hooks/gate-scripts/pre-merge-gate.sh` authorizes `gh pr merge` from a
`.claude/pr-grind-clean.local` marker that pr-grind writes on clean convergence.
Before this ADR the marker contained **only a PR number**, and the gate accepted
it when three conditions held:

1. marker age < 2 hours,
2. marker PR number == explicitly-supplied merge PR number,
3. `gh pr checks <PR>` shows no failing/pending relevant checks.

None of those bind the marker to a **commit**. A push landing after convergence
left the marker valid for the remainder of its 2-hour window, so the gate would
authorize merging a commit that no reviewer ack had ever covered.

This is not hypothetical. On `Dive-And-Dev/chrisyau.me#181`:

| Time (UTC) | Event |
|-----------|-------|
| ~09:0x | pr-grind converges clean on `866eb7d4`; writes marker `181` |
| 09:11:56 | operator pushes `10090de5` — HEAD moves |
| 09:17:21 | Codex posts 3 P2 findings **on `10090de5`** |
| 09:21:10 | Greptile posts 2 P1 findings **on `10090de5`** |
| 09:56:27 | `gh pr merge 181` — gate allows; PR merges with all 5 unresolved |

The reviewer-ack ledger was never the weak link: `scripts/ack-ledger.sh` Tier A
returns `stale` for a bot with unresolved non-outdated threads, which blocks
`clean`. It simply **never saw `10090de5`** — the grind had already finished. The
session's wrap-up ("all Codex threads on the prior HEAD resolved") was literally
true of `866eb7d4`, the commit the grind actually validated, and that gap between
"the reviewed commit" and "the merged commit" is precisely the defect.

## Decision

The marker contract becomes two whitespace-separated fields:

```
<PR_NUMBER> <HEAD_SHA>
```

`HEAD_SHA` is **`REVIEWED_HEAD`** — the `HEAD_FULL_SHA` the ack ledger actually
classified against, already carried to both merge blocks as `--match-head-commit`
(#427). It is **not** re-derived at marker-write time. Re-querying
`gh pr view --json headRefOid` there would reintroduce the very bug in miniature:
a push landing between classification and the marker write would be stamped as
reviewed, and the gate would then faithfully authorize an unreviewed commit.
(`git rev-parse HEAD` is wrong for a second reason — the marker-write block runs
at the ambient session cwd, routinely on a different branch than the PR head.)

Because the gate is a PreToolUse hook, the comparison above is only a **preflight**:
it runs before the command does. A push landing between the check and GitHub
processing the merge is therefore still possible — see "Residual risk", where the
rejected alternative is recorded.

Both evidence-based allow paths also refuse a merge that carries a repo/host
selector (`-R` / `--repo` / `GH_REPO=` / `GH_HOST=`), because every check they run
resolves against `REPO_DIR`'s origin while the merge would target somewhere else.

That guard reads `gitcmd_detect.gh_pr_repo_override()`, which scopes the two selector
forms differently because they have different reach:

- **Flag form** (`-R` / `--repo`) — scoped to the `gh pr merge` invocation's own argv,
  gh global flags before `pr` included (since `gh -R x pr merge 5` really does
  retarget). A flag cannot reach a sibling command, so a wider scope would only
  produce false blocks. gh uses pflag, so shorthand **clusters** count too
  (`-sRother/repo`); the scan follows pflag's rule and stops at the first
  value-taking shorthand, and it consumes a value-taking flag's separate operand —
  otherwise `--subject -R` reads the subject's value as a selector and false-blocks.
  A **positional PR URL** counts too (`gh pr merge https://github.com/o/r/pull/31`):
  it carries its own owner/repo, so it retargets exactly as `-R` does.
- **Env form** (`GH_REPO=` / `GH_HOST=`) — checked on **every** segment of the
  command, because an assignment is ambient: it reaches a merge in a nested chunk
  (`GH_REPO=o/r bash -c 'gh pr merge 31'`) that the assignment's own segment never
  contains.

The env check is **deliberately position-blind and deliberately over-blocking**: a
`GH_REPO=`/`GH_HOST=` assignment word anywhere in the command counts, as does any
export-family word mentioning either name. So `declare GH_REPO=o/r`, `export -n
GH_REPO=o/r`, and a bare `GH_REPO=o/r; gh pr merge 31` all block although the first
two do not export and the third looks inert.

Precision here is not merely hard, it is **unavailable**. Eight review rounds each
made the parse sharper and each surfaced a new shape, ending at one that settles it:
bash preserves a variable's export attribute across re-assignment, so whether a bare
`GH_REPO=o/r` reaches a later `gh` depends on whether the *caller's* shell had
already exported it — ambient state no parse of the command text can observe. This is
the same wall the head-pin requirement hit (see Alternatives), reached from the other
side. Unknowable ⇒ fail closed: an over-block is visible and the operator can reword,
whereas a miss authorizes a cross-repo merge.

The scan stays **token**-based, which is what keeps "position-blind" from degrading
into a text search — `--body 'Document GH_REPO=owner/repo'` holds the string inside a
single argument token and does not match.

Both are matched on **tokens**, never on raw or normalized command text. Tokenization
dequotes and joins line continuations, so every literal spelling the shell reassembles
— `env GH_RE"PO"=o/r`, `env GH_RE\PO=o/r`, a continuation-split name, the append form
`GH_REPO+=o/r` — arrives as one `GH_REPO=o/r` token. A text search would catch those
too, but only by also matching inert prose: `gh pr merge 31 --body 'Document
GH_REPO=owner/repo'` exports nothing yet contains the string. Restricting the scan to
each segment's leading assignment-word run keeps both properties.

It deliberately does **not** gate on ADR 0024's `REPO_OVERRIDE`, a coarse substring
test over the whole *unexpanded* command: gating on that form blocked pr-grind's
**own** auto-admin merge, because that block runs `gh -R "$OWNER/$REPO" pr view` and
`gh pr merge --admin` inside a *single* fenced Bash call
(`skills/pr-grind/SKILL.md` ~2111-2280), so the sibling `-R` rejected the entire call
and the merge never ran. ADR 0024's whole-command value is unchanged and still feeds
its non-gating advisory.

Parsing is acceptable **here and only here**. A selector assembled by shell expansion
(`sel=R; gh pr merge 31 -"$sel" other/repo`), or a `GH_REPO` exported by an earlier
Bash call, is invisible to a hook that never runs the command, so this is
defense-in-depth against the literal form, never a boundary — but the direction of
failure is safe: a miss returns to the
pre-existing behaviour (before #505 this path validated `gh pr checks` against
`REPO_DIR` with no repo guard at all), while a hit blocks. Contrast the head-pin
requirement below, which was reverted precisely because a miss there failed **open**.
See "Residual risk" item 3 — the cross-repo exposure is narrowed, not closed.

## Alternatives considered

- **Shorten the 2-hour TTL.** Rejected: does not fix it. The #181 push landed
  ~6 minutes after convergence; no TTL short enough to catch that is usable.
- **Have the gate re-query unresolved threads itself.** Rejected: duplicates
  `ack-ledger.sh`'s tier logic in a second place, needs GraphQL + jq in a
  PreToolUse hook, and drifts from the ledger. SHA binding delegates to the
  ledger by forcing a fresh grind on the actual commit.
- **Block all pushes after convergence.** Rejected: pr-grind pushes its own fix
  commits; the marker is written after, so this fights the normal loop.
- **Require the merge command to carry `--match-head-commit <reviewed sha>`.**
  Implemented, then **removed** — see "Residual risk" item 2. Deciding whether a flag
  is genuinely on the merge's argv means parsing a command the hook never executes.
  Successive review rounds defeated every version of that parse (prose, `#` comments,
  redirect targets, heredoc delimiters, fd-name redirections, and finally a SHA
  supplied by an unrelated assignment while the real operand was a command
  substitution). Each fix added complexity to something that could not become sound.

## Consequences

- Pushing to a PR after `/pr-grind` converges now requires re-running
  `/pr-grind <PR>`. That is the point: the new commit is unreviewed.
- The marker parser can no longer be `tr -d '[:space:]'` over the whole file —
  that concatenated the two fields into a non-digit blob. ADR 0012's
  "must stay a bare PR number" note is amended accordingly; its anti-laundering
  argument is unaffected (the released-bot list still lives in `bypass-log.jsonl`,
  never in the marker).
- One extra `gh pr view` call on the marker allow path. The path already calls
  `gh pr checks`, so this adds no new dependency class.

## Residual risk (deliberately not addressed here)

SHA binding closes "HEAD moved after convergence". Two narrower gaps remain, both
deliberately out of scope:

1. **Slow bot on the same HEAD.** A finding posted *after* the grind converged, on
   the *same* commit, still slips through — the ack ledger's snapshot is a
   point-in-time read. Already mitigated by the Codex first-engagement grace
   (`PR_GRIND_CODEX_GRACE_SECS`, default 480s, ADR 0013 / #420); widening that is a
   separate mechanism.
2. **Preflight-to-merge race on a MANUAL merge.** This gate is a PreToolUse hook: it
   can block a command but cannot rewrite it, and it runs *before* the command. A push
   landing between the head-SHA check and GitHub processing a hand-typed
   `gh pr merge` is therefore not caught. pr-grind's **own** merges are unaffected —
   they pass `--match-head-commit "$REVIEWED_HEAD"` (#427), template-substituted, with
   no command parsing involved, so GitHub itself refuses a moved head.

   Requiring that flag on *arbitrary* operator commands was tried and reverted: see
   Alternatives. The lesson is the pre-existing house rule — a regex over an un-run
   command is not a security boundary. If this window ever needs to be closed for
   manual merges, it belongs **server-side** (branch protection requiring the pin, or
   a required status check), not in a hook parser.

   Scale: the window is the seconds between hook and API call, against the ~45 minutes
   the un-pinned 2-hour marker allowed before this ADR.

3. **Cross-repo authorization.** Every check on the allow paths resolves against
   `REPO_DIR`'s origin, so a merge carrying a repo/host selector may target a different
   repository, where "PR #N" is an unrelated pull request. The merge-scoped guard
   described under Decision catches every **literal** selector on the merge's argv,
   which narrows this — but a selector assembled by shell expansion, or a `GH_REPO`
   exported by an earlier command, still passes. That residual is **pre-existing**:
   before #505 the marker path validated `gh pr checks $PR_NUM` against `REPO_DIR` and
   authorized the merge with no repo guard at all, so the guard can only narrow, never
   widen. Nothing below it relies on it — the authoritative check is the marker's
   reviewed SHA against the live head, which reads GitHub state rather than the command
   string. Closing the expansion case requires the target as the *shell* resolves it,
   which a PreToolUse hook never sees; that is server-side enforcement, not a parse.

## Revisit trigger

Revisit if a merge again lands unreviewed findings on a commit whose SHA
*matched* the marker — that would indicate the same-HEAD race above, not this one,
and would argue for a post-convergence re-read of the thread set immediately
before `allow_merge`.
