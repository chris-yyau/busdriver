# ADR 0044 — The design-review gate does not block a commit whose staged set is only design documents

**Status:** Accepted
**Date:** 2026-08-18
**Issue:** #685

## Context

`pre-commit-gate.sh` Gate 1 blocks `git commit` whenever any design-review token
is armed. That is correct for implementation: the gate exists so code cannot race
ahead of an unreviewed plan.

On a **documentation** PR it closes a loop with no exit.

Every finding a reviewer raises on `docs/plans/X.md` is remediated by editing
`docs/plans/X.md` — there is nothing else to change. That edit is exempt from the
pre-implementation gate (design docs may always be written), and it arms a fresh
review token. Gate 1 then refuses the commit that would land the fix. The
reviewer re-reviews the new HEAD only after a push, so the cycle cannot advance
without clearing the block, and the only ways to clear it are:

- an operator `touch $STATE_DIR/skip-litmus.local` — needs a human at a terminal,
  and also skips litmus;
- `design-clear.sh --yes` — a documented, audited **self-bypass**;
- a blueprint-review PASS — unavailable in the motivating case, where the document
  was a landed record that could not be shown complete against a spec full of
  deferred obligations, and the review ended PENDING after six rounds.

Measured on the reporting repo's PR #267 (documentation-only, four files, seven
commits): **9 operator `touch` commands**, ~20 tokens armed at merge time, 3 lease
expiries mid-flow.

Reproduced on this repo at `15a2f919`: with one token armed for
`docs/plans/p.md`, committing that document blocks with *"Design review required
before committing."*

## Decision

Gate 1 does not fire when the commit's **staged set** is entirely design
documents. Three conditions, all fail-CLOSED, all of which must hold:

1. **The command must be a bare, single-segment `git commit -m …`.**
   `hooks/gate-scripts/lib/commit_scope.py` refuses everything else: anything
   chained (`&&`, `;`, `|`, `&`, a subshell, a redirection), `-a`/`--all`, a
   pathspec operand, `--include`/`--only`, `--amend`, `--no-verify`, a BARE
   `git commit` (it opens `core.editor`), `git -C other`, `/usr/bin/git`, an
   aliasable `git commit-x`, `$`/backtick anywhere, an unquoted glob or brace, a
   newline, an unbalanced quote.
2. **The repository must carry no git hook, and every staged entry must be a
   regular blob on BOTH sides.** A hook can stage files between the decision and the commit; a
   symlink in the index is not the working-tree file condition 3 would resolve.
   The hooks directory is resolved **twice**: `sanitized-gate.sh` exports
   `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_SYSTEM=/dev/null` (ADR 0016)
   while the authorized `git commit` runs with the operator's real config, so a
   global `core.hooksPath` is invisible to the gate and live at commit time. The
   second pass drops those two variables and asks again; a hook in either answer
   refuses, as does config naming a program git may run during the commit:
   `core.fsmonitor`, `core.pager`/`pager.commit` (shell-interpreted, and
   `pager.commit` is consulted before the commit builtin is entered) and
   `gpg.program` (executed when the commit is signed). Excluded on purpose:
   `core.editor`, since a bare `git commit` is already refused, and clean/smudge
   filters and `textconv`, which run at `git add` and at diff rendering — both
   outside the window between the decision and the commit. `core.fsmonitor` is
   classified by git itself (`--type=bool`), not by string matching: a boolean
   names no program (`true` selects git's built-in daemon, which this repository
   sets — the first revision refused it and would have shipped a carve-out that
   could never fire in the repository it was written for), while git preserves
   quoted whitespace, so `" true "` is a PATHNAME that a `.strip()` had read as
   the safe daemon. Stepping outside ADR
   0016 there is narrow and deliberate:
   `rev-parse --git-path` under `--no-pager` is inert plumbing that runs no
   helper, alias or pager, and `HOME` is already re-derived from the password
   database — so declining to look is the fail-OPEN direction, not looking.
3. **The staged set must be at most 20 paths**, and every path must be a design
   document, per `gate_design_doc_exempt` —
   the same canonical predicate the pre-implementation gate uses, applied to both
   the lexical and the `realpath`-resolved repo-relative spelling, so a symlinked
   `docs/plans/x.md -> ../src/impl.py` is not a design doc here either.

The file set is read from git (`diff --cached --raw --no-renames --no-ext-diff
-z`), never derived from the command. `--raw` carries both modes per entry, so
one call answers "what is staged" and "is every side of it a regular blob" — a
`ls-files --stage` version saw only the NEW mode, so a staged DELETION, which has
no index entry at all, skipped the check and a deleted symlink named
`docs/plans/component.md` passed as a document. `--no-renames` is load-bearing:
with rename detection on, a staged `src/impl.py` → `docs/plans/impl.md` reports
only the destination and presents as a lone design document while deleting
implementation code.

**Staging happens in its own tool call.** `git add` is not a commit — it exits
`pre-commit-gate.sh` at the `IS_GIT_COMMIT` check and classifies as a read in the
pre-implementation gate — so the docs loop is `git add <docs>` then `git commit
-m …`, two calls. Gate 1's block message names this form, because a fix nobody
can find is not a fix.

Deliberately **not** `gate_design_pass_honored` (the predicate the spec-only Gate
2 bypass 30 lines below uses). The document is unreviewed *by construction* —
that is what armed the token. Requiring a PASS would restore the deadlock exactly.

**Anything that can HANG is a bypass, not a stall** — the same fact the 20-path
bound rests on, and the reason for two further guards found during review. Every
subprocess in `commit_scope.py` draws from ONE shared 4-second deadline
(individually-bounded calls can still overrun the hook budget together), because
repo-influenced git config can hang git outright: `[include] path = /dev/zero`
makes `git config` read forever. And `_settings_inert` runs BEFORE `_hooks_absent`
— reversed, a hostile `XDG_CONFIG_HOME` injected by the very settings file
`_settings_inert` exists to refuse would get to hang git before the check that
would have refused the repo ever ran.

The 20-path bound is not cosmetic. The gate runs the design-doc predicate once
per staged path, each forking `python3` and `git`, inside a PreToolUse hook
registered with a **10-second timeout** — and a timed-out PreToolUse hook emits no
decision, which the harness reads as *allow*, i.e. a commit past both review
gates. An unbounded loop there would have been a fail-OPEN introduced by the
carve-out itself. 20 matches the classifier's own record budget and is far above
any documentation remediation commit.

The carve-out fires only on classifier exit **1** (pending), never on exit 2
(enumeration failure) — converting "nothing could be determined" into success is
the one widening a fail-closed gate must never make. And it **falls through to
Gate 2**; it does not exit. Litmus still reviews the commit, and short-circuits
cheaply on prose.

## Alternatives considered

**Certify a chained `git add X && git commit -m y` in one call.** Built, then
deleted — and the deletion is the most important decision in this ADR.

Parsing the add operands meant re-implementing git's pathspec grammar and bash's
word grammar. Seven consecutive litmus rounds each produced a new HIGH against
that component and nothing else:

| round | what the operand parser certified that git did not do |
|---|---|
| 2 | `-- ':!docs/plans/p.md'` — pathspec magic EXCLUDES, staging everything else |
| 2 | `docs/plans/$(…).md` — shlex strips quoting but expands nothing |
| 2 | a DIRECTORY named `docs/plans/bundle.md` stages its children |
| 3 | operands resolve against the command's cwd, not the repo root |
| 3 | a second `--` is an operand, not another separator |
| 4 | a quoted `';'` is a git operand; `shlex(punctuation_chars=True)` cannot tell |
| 6 | a symlinked operand; a `git add-x` alias (`\b` matches before a hyphen) |
| 8 | a regular file replacing a tracked directory stages the deletions too |

Every fix was correct and every next round found another shape. The class was
unbounded because the grammar being modelled belongs to git and to bash, not to
this helper. Reading the staged set from git instead deletes the entire component
— and costs the docs loop one extra tool call.

**Dedupe tokens per document** (the issue's own first-ranked fix, also #644).
Rejected, and it would not have fixed this anyway: *one* pending token blocks a
commit exactly as hard as twenty, so the loop is unchanged. It is also unsafe as
stated — `marker_ops.py cmd_arm` never reads existing tokens on purpose. The
review loop snapshots `<sha>.*` at start and unlinks that snapshot on PASS; a
check-then-skip arm can observe a token that the loop then prunes, losing the
review requirement for the edit that skipped. That is a fail-OPEN, and it is the
race the per-arming nonce exists to kill.

**`design-clear.sh --all-for-doc`.** Already shipped (#665). It lowers the
clearing cost to one confirmation per document; it does not remove the operator
from the loop, and via `--yes` it is a self-bypass rather than an exit.

**Exempt documents that are already merged history** (the issue's item 4).
Deferred. It needs a trustworthy "this is a landed record" signal, and the
obvious one — a banner in the document — is author-controlled metadata living in
the artifact the gate gates, which the repo's own gate-design rule names as a
general bypass primitive.

**Widen the carve-out to Bash-mediated edits of a design doc** (`sed -i
docs/plans/x.md` is still blocked by the pre-implementation gate, while the same
edit through the Edit tool is exempt). Real, and a sibling of this defect, but it
needs a file-set proof for arbitrary Bash that `git` hands us for free here.
Out of scope; the remediation loop uses Edit.

## Consequences

- A documentation PR's review→fix→commit loop closes with no operator action and
  no bypass. Nothing is logged to `bypass-log.jsonl`, because nothing is bypassed.
- The cost is one extra tool call: stage, then commit. A chained
  `git add … && git commit` is refused **by design**, and the block message says
  so along with the form that works.
- The instant one implementation file joins the staged set, the block returns in
  full — as it does for `-a`, an empty index, a repository carrying any git hook,
  a staged symlink, or a classifier that could not enumerate.
- The carve-out announces itself on stderr. A gate that widens silently is
  unauditable.
- **Accepted residual — the commit's environment.** The authorized `git commit`
  runs in the Bash tool's environment, which the gate cannot read: it runs under
  `env -i` (ADR 0016). An ambient `GIT_INDEX_FILE`/`GIT_DIR`/`GIT_CONFIG_COUNT`
  therefore aims the real commit at state this helper never inspected, and this is
  architectural — every gate in `hooks/gate-scripts/` is blind the same way,
  including the litmus marker check in the same file. The *in-repo* channel is
  closed rather than argued away: an earlier draft of this ADR reasoned that a
  committed `.claude/settings.json` `env` block "cannot be landed through the
  carve-out," which was wrong — a checked-out PR's settings file is live from
  checkout, not from being committed. So the helper refuses outright when
  `<state_dir>/settings.json` or `settings.local.json` declares ANY `env` block,
  or cannot be parsed — and likewise for `hooks`, `enabledPlugins` and
  `extraKnownMarketplaces`, since a project-registered PreToolUse hook (directly,
  or via an activated plugin's manifest) can rewrite the approved command through
  `updatedInput` or restage after the index sample. What remains is an operator's
  own ambient environment, and a session whose settings file was read and then
  deleted mid-run — neither of which any gate here has ever been able to see.
  One slice of this was narrowed, not merely accepted: `_hooks_absent`'s
  second (unsanitized) pass exists specifically to see a global
  `core.hooksPath` the sanitized pass can't, but XDG_CONFIG_HOME was stripped
  by `env -i` before that pass could read it either — an operator whose
  XDG_CONFIG_HOME diverges from `$HOME/.config` had a live global hook the
  helper could never detect (reported by Codex on this PR, reproduced). Fixed
  by re-importing XDG_CONFIG_HOME through hooks.json for this one gate;
  GIT_CONFIG_GLOBAL=/dev/null still makes every OTHER git call (including this
  gate's own first pass) blind to it, so nothing else widens. This still does
  not close the gap for a Claude session launched outside the shell where
  XDG_CONFIG_HOME was exported (e.g. set only in a profile the launching
  process never sourced) — hooks.json can only re-import what Claude Code's
  own process environment already carries at hook-interpolation time, which is
  the same "operator's own ambient environment" limit the rest of this bullet
  already accepts. A second slice was narrowed the same way: `sanitized-gate.sh`
  substitutes a passwd-derived HOME for its own subprocess calls (defense
  against a poisoned launching-session HOME), but the authorized `git commit`
  that runs right after this gate approves is a *different* process — it
  inherits the launching session's ORIGINAL HOME, never the substitution. A
  `~/.gitconfig` at that real HOME could carry a live `core.hooksPath` the
  second pass, reading under the passwd HOME, never saw (reported by Codex on
  this PR, reproduced). Fixed the same way as XDG_CONFIG_HOME: hooks.json
  re-imports the pre-substitution value as `BUSDRIVER_ORIG_HOME` (a name
  `sanitized-gate.sh`'s own HOME override never touches, so it survives), and
  `_hooks_absent`'s second pass resolves config under it instead. Same limit
  as XDG_CONFIG_HOME above — only what Claude Code's own process environment
  already carries at hook-interpolation time.
- **Accepted residual — TOCTOU.** A PreToolUse hook samples the index before bash
  runs, so between the decision and git constructing the commit a concurrent
  writer could stage an implementation file. This is structural to every gate in
  `hooks/gate-scripts/` — the design token, the litmus marker and the pr-grind
  clean marker are all sampled at dispatch time, which is why the clean-marker
  write and `gh pr merge` are required to be separate tool calls — and the
  carve-out does not introduce it. It is narrowed as far as a PreToolUse hook
  can narrow it: one segment, so nothing in the command stages; no git hooks, so
  nothing during the commit stages. What remains is a concurrent writer in the
  same repository, which this architecture has never been able to see. The one
  mechanism that could close it is a git `pre-commit` hook — precisely what
  condition 2 refuses, since an existing one could stage anything.
- **Residual, stated plainly:** this does not touch the token lifecycle. Tokens
  still accumulate one-per-edit and outlive the docs PR, so after merge the
  repo-wide implementation-write block persists until a blueprint-review PASS or
  a `design-clear.sh` release. That is #644, and it remains open.
- The `--amend` path is untouched: the gate's own pre-existing amend bypass sits
  above Gate 1, so an amend never reaches this code. `commit_scope.py` refuses it
  regardless.

## Verification

`tests/test-design-gate-docs-commit.sh` — 105 assertions, both branches of every
guard.

Step 1 pins the accept and refuse sets, with the conventional-commit message as
the counterweight: a parser that refused every parenthesis or `#` would refuse
nearly every commit this repo makes, so `fix(scope): …`, `#685`, a quoted `&&`
and a quoted `[gate]` are all asserted to pass while their unquoted forms refuse.
Every historical HIGH that still applies to the commit path has a case.

**Step 1b is differential**, and it is the part that matters. It compares the
claimed set against `git diff --cached` — the only authority on what a commit
would carry — across one-doc, two-doc, impl, and everything-staged indexes, plus
the rename and staged-symlink shapes. It then sweeps a generated command grammar
(5 command heads × 7 option shapes × 14 message shapes = 490 commands) holding
the same invariant over every command the helper ACCEPTS: **12 accepted, claim
equal to git's index on all 12; 478 refused.** The partition is asserted, not
just the invariant — "every accepted command claims the current index" is true by
construction, so a regression that started accepting `-a` would leave the
invariant intact and pass. Pinning the counts makes any change in what the parser
accepts a deliberate edit to that line.

That sweep exists because the hand-picked list is only as good as what someone
thought to write down, and twice it was not good enough: the shell-active commit
message and the adjacent control operator both passed a review whose examples
were chosen by the same person who wrote the parser.

The fixtures run with `HOME` pointed at their own empty home and
`GIT_CONFIG_SYSTEM=/dev/null`, because the helper deliberately resolves git config
twice and the second pass reads the operator's real global file: without that
isolation the suite would report the machine's `core.pager`/`gpg.<fmt>.program`/
`core.hooksPath` rather than the code. Two negative controls pin the inverse
mistake — this repository's `core.fsmonitor=true` and a signing operator's
`gpg.format=ssh` + `commit.gpgSign=true` must both be ACCEPTED, since earlier
revisions refused each and would have shipped a carve-out that could never fire.

Step 2 runs the gate end-to-end against scratch repos with a real armed token:
docs-only allowed; mixed, impl-only, `-a`, chained-add, nothing-staged and
symlinked-doc all still blocked; the carve-out proven to fall through to Gate 2
rather than exit; the announcement proven to reach stderr; and the block message
proven to name the two-step form.

## Revisit trigger

If a docs remediation loop is ever observed blocking again — or if `git commit`
grows an option that widens the file set and is not in the refusal list above.
