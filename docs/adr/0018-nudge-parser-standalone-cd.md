# ADR 0018 — Accept a standalone literal `cd` prefix in the merge-time Codex-nudge parser

## Status

Accepted (2026-07-18). Loosens the merge-first parser guard introduced by the
ADR 0013 revision (2026-07-17). Relates to issue #398 (the merge-time nudge as the
sole delivery path for inline/admin merges).

## Context

The deterministic `none`-nudge lives in a PreToolUse hook on `gh pr merge`
(`hooks/gate-scripts/codex-nudge-premerge.sh`), parsed by
`hooks/gate-scripts/lib/nudge_parse.py`. To avoid ever posting `@codex review` to
the wrong repo, the parser enforces a **MERGE-FIRST** rule: nothing may execute
before the merge except pure non-sensitive assignments and a `cd` that is
**`&&`-joined** directly to the merge (the only form `gitcmd_detect.gh_pr` captures
as a trusted `target_dir`). Any other command word before the merge → skip.

**The miss (diagnosed from session `261270ad`, PR #403).** pr-grind's own
CWD-reset rule (`skills/pr-grind/SKILL.md:81`, `agents/pr-grinder.md:30`) mandates
that *every* Bash tool call **start with a standalone `cd "$WORKTREE_DIR"`** — on
its own line, never `&&`-joined. So a rule-compliant pr-grind merge command always
leads with:

```
cd /Volumes/Work/Projects/busdriver     # standalone line
NO_WORKTREE=1
gh pr merge 403 --squash --delete-branch
```

The standalone `cd` is not `&&`-joined, so the parser flagged it a "real command
before the merge" (`UNSAFE=1`) and the hook exited without nudging. Running the
exact command through `nudge_parse.py` confirmed `UNSAFE=1`; the `&&`-joined form
parsed safe. The result: the `none`-nudge silently no-op'd on **every** properly
formed pr-grind merge — the two governing rules (CWD-reset vs. merge-first) were in
direct contradiction. PR #403 merged with zero Codex engagement.

## Decision

Teach `nudge_parse.py` to also accept a **standalone absolute plain-literal
`cd /<path>`** before the merge as a safe merge-first prefix, and surface its target
as the merge's `target_dir` when `gh_pr` did not capture an `&&`-prefix.

"Absolute plain-literal" is strict: exactly one operand, **starting with `/`**, not a
flag, and free of every shell-expansion metachar (`$`, backtick, glob, brace, `~`)
per the same allowlist the merge segment already uses. A `cd "$(git rev-parse
--show-toplevel)"`, `cd $VAR`, or relative `cd leaf` is **not** accepted here (the
`&&`-capture path still handles the substitution form when it is `&&`-joined).

Predicting the merge's runtime cwd statically is a rabbit hole; five constraints
close it, each with a regression test (cases 8f4–8f9). They were found by the review
gate (Codex) across two rounds — recorded here so they are not "simplified" away:

1. **Builtin only.** The command word must be exactly `cd`, not an external
   `/tmp/cd` (basename `cd`): an external executable cannot change its parent
   shell's cwd, so trusting its operand would resolve the wrong repo.
2. **No hidden re-targeter.** The cd segment is rejected if it carries a sensitive
   assignment or a `$(…)` retargeter (e.g. `X="$(git remote set-url …)" cd .`) —
   the literal-cd suffix does not launder the substitution.
3. **At most one cd.** Two or more `cd`s before the merge cannot be composed
   statically, so any multi-cd prefix is rejected.
4. **No subshell.** A `cd` inside subshell grouping (`( cd /x ) ; merge`) is scoped
   to the group and leaves the merge's cwd untouched; any pre-merge segment carrying
   a bare `(` / `)` token is rejected (this also hardens the pre-existing
   `&&`-capture path).
5. **Absolute only ⇒ CDPATH-immune.** Bash's `CDPATH` re-points a **relative** `cd`
   operand outside the payload cwd; an absolute operand ignores `CDPATH` and resolves
   identically to the downstream repo resolver. Requiring `/`-leading is the primary
   guard; `CDPATH` is additionally treated as a sensitive assignment (defense in depth).
6. **No `..` component.** A `..` after a symlink resolves differently under bash's
   default logical `cd` (textual) and `git -C` (physical), so `..`-bearing targets are
   rejected.
7. **Sequential success-composition only.** The cd must reach the merge via `;` /
   newline / `&&` — never `||` (merge runs only if the cd failed), `&`, or `|` (broken
   cwd inheritance). A cd behind a reserved/control-flow word (`then`, `do`, …) is
   conditional and rejected too.

An absolute single cd resolves to exactly one directory the downstream resolver
computes the same way, so the origin-equality check validates the real target.

## Why this does not weaken wrong-repo safety

A pre-exec hook fundamentally **cannot prove a parsed `cd` executed** as written —
a shell function/alias named `cd`, a conditional (`if …; then cd /b; fi`), a failed
cd, or a symlink+`..` divergence can leave the merge in the payload cwd instead of
the parsed target. So static parser tightening alone is whack-a-mole. The safety
rests on **two layers**:

1. **Downstream target==cwd-origin equality** (unchanged): the hook resolves
   `REPO_DIR` from `target_dir`, runs `gh pr view` *in that dir*, and requires the
   resolved host/owner/repo to equal that dir's `origin`.
2. **Cross-cwd origin guard** (new, load-bearing — `codex-nudge-premerge.sh`): when
   `target_dir` is set, the merge's real cwd is EITHER the parsed target OR the
   payload cwd. The hook now requires **both to resolve to the same github origin**;
   otherwise it skips. Then whichever cwd the merge actually used, the nudge targets
   the correct repo — regardless of whether/how the `cd` executed. A git worktree
   shares its main checkout's origin, so the real pr-grind case (payload cwd +
   `WORKTREE_DIR` of the same repo) passes; a `cd` into a different-origin repo is
   refused.

Together these make the parser's `target_dir` **advisory**: even a fully mis-parsed
cd cannot produce a cross-repo post, because layer 2 rejects any payload≠target
origin divergence and layer 1 rejects any resolved-PR≠origin divergence.

The parser tightenings (builtin-only, no-subst, single-cd, no-subshell, absolute-only,
no-`..`, no-reserved-word, sequential-operator-only) remain as **defense in depth** and
keep `target_dir` honest, but the cross-cwd guard is what makes the loosening safe by
construction. Every existing adversarial test still passes.

The hook remains **non-gating and fail-safe = skip**: a bug here can only cause a
missed or bounded-deduped nudge, never a blocked merge and never a cross-repo post.

### Residual accepted limit

A `cd` shell function/alias/conditional could still cause the nudge to fire on the
**same** repo the operator is in for a merge that (in a contrived command) targets a
different worktree of that **same** repo on a different branch, resolved via an
implicit `gh pr merge` (no PR number). This is bounded to a non-gating, deduped nudge
on the operator's OWN repo — the identical residual class already accepted for a `gh`
alias/function (`codex-nudge-premerge.sh` ACCEPTED LIMITS #2). It is not a cross-repo
post and cannot block or mis-route a merge.

## Alternatives considered

- **Fix the merge template instead** (emit `cd "$WORKTREE_DIR" && gh pr merge …`).
  Leaves the security parser untouched, but is fragile: it contradicts the
  CWD-reset rule that trains agents to put `cd` on its own line, so any agent
  deviation silently re-breaks the nudge. Rejected as brittle against pr-grind's
  own dominant convention.
- **Loosen the shared `gitcmd_detect._trusted_cd`** to trust `;`-joined cds
  everywhere. Rejected: that helper backs the fail-CLOSED pre-commit / pre-pr
  security gates, where `&&`-only cd trust is a deliberate property (a marker read
  from the wrong repo is a real bypass). The loosening is safe **only** because the
  nudge hook re-validates via the origin equality check; the security gates have no
  such backstop. Kept the change local to `nudge_parse.py`.

## Consequences

- The merge-time `none`-nudge now fires on rule-compliant pr-grind merges (the
  common case), not just `&&`-joined one-liners.
- Regression test `tests/test-codex-nudge-premerge.sh` Case 19b exercises the exact
  #403 command shape; Cases 8f2/8f3 pin the same-repo-nudge and non-literal-reject
  boundaries. Cases 8f/19 comments updated to note the skip moved from the parser to
  the downstream equality guard.

## Revisit trigger

- A real active repo is observed nudged on the **wrong** repo (would indicate the
  downstream origin-equality guard is not the true backstop we rely on here).
- The pr-grind CWD-reset rule changes such that merge commands no longer lead with a
  standalone literal `cd` (the loosening would then be dead weight and could be
  reverted to `&&`-only).
