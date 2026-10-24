# Issue #921: arm the design-review gate on a Bash call's effect, not its spelling

<!-- design-reviewed: PASS -->

Status: proposed, revised after six blueprint-review rounds (two parked on trajectory and
were continued without raising the ceiling). Operator AFK during brainstorming; every
question the brainstorming process would have asked was answered by the implementing
agent with the recommended default, recorded under "Decisions taken without the operator"
below. The optional grill (Step 5.5) was not run, because there was nobody to grill. The
opted-in ultra-oracle consult (Step 5.6) was attempted and refused by the session's
permission classifier as an external data transfer; with the operator away it was skipped
rather than retried, and blueprint-review is the independent review of record.

## Context

`hooks/gate-scripts/check-design-document.sh` is the PostToolUse detector that arms a
design-review token when a design-pattern document is written. For Write/Edit/MultiEdit it
reads `tool_input.file_path`. For Bash it regex-parses the command text for `>`/`>>`
redirect targets, `tee` targets and the last word before a separator of a `cp`/`mv`, and
stops at the first design-pattern match.

A write made by a process the command starts has no target in the command text. On
chrisyau.me PR #406 a node script read `DESIGN.md`, applied string replacements and wrote
it back. No token was armed, the pre-implementation gate never blocked, and the change was
committed. The same edit made with the Edit tool armed the gate (PR #403). The miss is
silent: the hook is fail-open by design and the regex simply found nothing.

Shapes the current parser misses: an interpreter script (`node x.js`, `python3 x.py`),
`sed -i`, `perl -pi`, `git checkout <ref> -- DESIGN.md`, `git apply`, `patch`,
`install`/`cp -t`, a destination spelled through a shell variable, and any write that
rewrites more than one document (the parser `break`s after the first). The variable case
reproduced while this spec was being written: `cp /tmp/draft "$W/docs/specs/<name>.md"`
placed this document and left zero tokens in the marker store, because the parser resolved
the literal `$W/...` text against the cwd.

Relevant prior decisions: ADR 0017 and ADR 0031 (do not narrow the repo-wide block scope),
ADR 0021 (Bash write resolution is cooperative mis-fire protection and best-effort, not an
adversarial boundary), #347/#449 (a Write re-opens review and strips PASS to PENDING),
#446 (one classifier, `gate_design_doc_exempt`, for detector and gate).

## Goal and non-goals

Goal: when a Bash tool call that completes (with a zero or non-zero exit) leaves a
design-pattern document in a repository it started in with working-tree content that it
changed and that is not committed at the post-call HEAD or at a revision being brought in
(below), arm the review token for that document, whatever the command looked like. A call
that writes a doc and commits it in the same command is outside this goal (Residuals).

Success criteria:

1. Each of these arms a token for the document: a script rewrite (python3, and node when
   available), `sed -i`, `cp` to a destination spelled through a variable,
   `git checkout <other-ref> -- DESIGN.md`, a new untracked `docs/plans/x.md` created by a
   script, a script that rewrites two documents in one call (both armed), a second rewrite
   of an already-dirty document, and a rewrite followed by a failing command
   (`python3 w.py && false`).
2. None of these arm through the effect path: a Bash write to a non-design file; a rewrite
   of a design doc with identical content; blueprint-review's own run (it only adds, flips
   or deletes marker lines); `git pull`, `git rebase`, `git checkout <branch>`,
   `git commit`, `git reset --soft HEAD~1`, `git pull --rebase --autostash` over a
   marker-only local edit, and a merge or rebase that stops on a conflict elsewhere while
   bringing in a reviewed doc unchanged from one side (they move committed content, they
   do not create unreviewed content); a doc already dirty from an earlier PASS-preserving
   Edit followed by an unrelated Bash call. A write the redirect parser can see still arms
   exactly as it does today, even when its content is identical, because the parser is
   kept unchanged. A doc left in a merge conflict is not armed while unmerged; it arms when
   its resolution is staged with content that is not committed anywhere (below). A doc git
   auto-merges from edits on both sides, in a merge that stops before committing, is new
   content and arms; the same merge completing and committing in one call is the
   write-and-commit residual.
3. The Write/Edit/MultiEdit path is unchanged: no snapshot, no comparison, no new output.
4. Per Bash call: one `git status` per recorded root in each half (at most two roots),
   plus `ls-tree` and `cat-file --batch` per root and per revision consulted, and every
   per-document step in one Python process (whose only per-document child is the
   classifier's existing `git rev-parse`), inside the existing 5 s hook budget. Measured
   numbers are recorded under Performance.

Non-goals: `.impeccable/design.json` and other non-`.md` files (not design-pattern paths
today; widening the grammar is a separate decision). Gitignored design docs. Adversarial
suppression (see Residuals). The commit-time backstop.

## Decision

Detect by effect with a per-call snapshot of the repository's dirty design documents,
taken in PreToolUse and compared after the call in PostToolUse or PostToolUseFailure, and
process every changed document in one Python process that imports the same marker library
the shell helpers delegate to.

### Snapshot set

For a repository root R, the snapshot holds the pre-call `HEAD` oid (absent on an unborn
branch) and the map `relpath -> body hash` over every path in

    git -C R --no-optional-locks status --porcelain -z -uall --no-renames -- \
      ':(top,icase,glob)**/plan*.md' ':(top,icase,glob)**/design*.md' \
      ':(top,icase,glob)**/architecture*.md' \
      ':(top,icase,glob)**/docs/**/plans/**/*.md' ':(top,icase,glob)**/docs/**/specs/**/*.md' \
      ':(top,icase,glob)**/<STATE_DIR>/**/plans/**/*.md' ':(top,icase,glob)**/<STATE_DIR>/**/specs/**/*.md'

Pathspec magic applies only to the entry it prefixes, so every entry carries it. `icase`
on every entry keeps the git filter at least as wide as the detector's grammar on a
case-sensitive filesystem; the exact filter is then the detector's own lexical grammar (the
same `design_re` / `plans_re` the Bash branch uses, with the sanitized
`BUSDRIVER_STATE_DIR`, read from the value the script has already sanitized and exported,
never re-read raw), followed by the exclusions listed under Per-document processing. A
path enters the map only if it is a regular file and its status is not unmerged (`U` in
either column, or `AA`/`DD`). Only paths that are untracked, staged or modified relative to
HEAD are in the set; clean committed documents are not hashed at all.

Roots are decided in PreToolUse only and recorded in the snapshot: the git toplevel of the
pre-event payload `cwd` (the session cwd before the command runs), plus the toplevel of
the command's effective cwd from `gitcmd_detect.effective_cwd` when it names a different
repository (the same resolution the redirect branch uses; it honours one leading absolute
`cd` and falls back to the payload cwd otherwise). Each candidate root is resolved on its
own: a payload cwd that is not inside a repository yields no root and a warning, and the
effective-cwd root is still recorded. The comparison never recomputes them, because the
post-event payload cwd follows any `cd` the command ran and can be a different repository
or no repository at all.

The hook runs under `sanitized-gate.sh`, which points `GIT_CONFIG_GLOBAL` and
`GIT_CONFIG_SYSTEM` at `/dev/null`. Inside the hook `git status` therefore ignores a global
`core.excludesFile` (a doc ignored only there is seen as untracked and is covered),
`core.fsmonitor` and `core.untrackedCache`; the timings under Performance are re-measured
inside that environment by the new test.

### Body hash

The body is the document's bytes decoded as UTF-8 with `surrogateescape`, split with
`re.split(r'\r\n|\r|\n', text)` (the boundaries `marker_ops._substitute_pass_lines` uses
for the PASS rewrite, which are also the universal-newline boundaries the PASS reader
sees), with three changes:

- whole lines matching `^[ \t]*<!-- design-reviewed:.*-->[ \t]*$` are removed;
- lines matching `^[ \t]*<!-- design-review-coverage:.*$` are removed. This is the
  review loop's own prefix rule (`_RE_COV='^[[:space:]]*<!-- design-review-coverage:.*$'`
  in `run-design-review-loop.sh`, which uses it to repair truncated or split coverage
  lines); `[ \t]` is equivalent to `[[:space:]]` here because the split has already
  consumed CR and LF, and VT/FF at the start of a marker line is not a shape the loop or
  any writer produces;
- trailing lines at the end of the document for which `line.strip() == ''` are removed.

Every other line is kept byte for byte, including interior blank lines and trailing
spaces; only line terminators are normalised. The hash is
`sha256('\n'.join(lines).encode('utf-8', 'surrogateescape'))`. Every regular file in the
dirty set is hashed, whatever its size; the deadline below bounds the total work. If
reading a path fails, its entry is the sentinel `unreadable:<size>:<mtime_ns>` from
`lstat` instead of a hash, so a persistently unreadable doc is a candidate only when that
sentinel changes, not on every call; such a candidate is armed but not downgraded (its
content was never read), with a warning. These are exactly the edits blueprint-review's loop
makes: an in-place `sed` replacement of a marker line, a `sed /d` of a coverage line, and a
`printf '\n<marker>\n' >>` append, whose separator blank line ends up trailing once the
marker is removed. A paragraph split, a Markdown hard break or a whitespace change inside a
code fence changes the hash.

### Arm rule

After the call, recompute the dirty set S_post for each recorded root, with the same
filters as S_pre (so a deleted, conflicted or excluded path is never in it). For every path
P in S_post, P is a candidate when:

- P was in S_pre and `body(P_post) != S_pre[P]`; or
- P was not in S_pre (clean or absent before the call) and
  `body(P_post) != body(<pre-call HEAD>:P)`. When the pre-call HEAD is unborn, or P does
  not exist in it, this condition holds.

A candidate is dropped, not armed, when its body equals the body of P at any of these
revisions that exist after the call (each resolved with
`git rev-parse -q --verify <REV>^{commit}`): `HEAD`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`,
`REBASE_HEAD`. The working tree then holds content that is committed on a branch being
brought in: a pull or rebase that moved HEAD, an autostash re-applying a marker-only edit
over upstream prose, a merge or rebase stopped on a conflict in another file with a
reviewed doc cleanly staged, or a `git restore --source=HEAD --worktree` over a divergent
index. Every other candidate arms. Blob bodies for a revision are read with one
`git --literal-pathspecs -C R ls-tree -z <rev> -- <candidate paths>`, keyed by the path
each entry returns (never by position) and accepting only `blob` entries with mode
`100644` or `100755` (a symlink or gitlink entry counts as absent), then one
`git cat-file --batch` over the returned oids. Each response record is either
`<oid> SP <type> SP <size> LF` followed by exactly `<size>` bytes and an `LF`, or
`<oid> SP missing LF` with no body (that path is absent at that revision). A path absent
from the listing is absent at that revision. If a revision read fails, times out or
returns a malformed record, every candidate not yet decided for that root arms without
`cmd_downgrade_pass` (the same rule as the unreadable sentinel: content that could not be
compared is never rewritten), with a warning. So a failed read can add a token but can
never strip a PASS.

Comparing first against the pre-call HEAD, not the post-call HEAD, is what keeps
`git reset --soft HEAD~1` and `git reset HEAD~1` from arming a reviewed doc whose bytes did
not change.

Paths that leave the dirty set are never armed: the working tree now holds committed
content. This keeps `git pull`, `git rebase`, branch checkout and `git commit` from
arming, and `git checkout -- DESIGN.md` from arming when the restored body equals HEAD's.
That command copies the index version over the working tree. When the index holds staged
content that differs from HEAD, the outcome follows the rule: if the working tree already
equalled the index, no bytes change and nothing arms; if it differed, the doc now holds
the staged content, which differs from its pre-call body, and it arms. The issue's "arm on any change"
wording would get this wrong: this repository changed design paths in 27 of its last 401
commits (measured over 90 days), and pr-grind rebases onto main constantly. Arming on
every rebase that pulled a reviewed spec would block every worktree and would also
`downgrade-pass` the pulled file, dirtying it.

A doc left unmerged by a conflicting pull, rebase or merge is in neither set, so the
conflict bytes are never armed or rewritten. Staging the resolution puts it in S_post; it
arms then unless its `body()` equals the `body()` of P at `HEAD`, `MERGE_HEAD`,
`CHERRY_PICK_HEAD` or `REBASE_HEAD` (taking a side wholesale is not new content).

### Per-document processing

`design_effect.py diff` processes every armed candidate itself, in the same process, by
importing `marker_ops` from the trusted lib dir (the `sys.path.insert(0, libdir)` pattern
the parser already uses for `gitcmd_detect`) and calling its CLI functions directly with
argv lists: `cmd_dd_exempt([abs, state_dir])` (the #446 classifier),
`cmd_arm([marker_dir, norm])`, `cmd_downgrade_pass([abs])` and `cmd_reviewed([abs])`.
Those are the functions `gate_design_doc_exempt`, `gate_marker_arm`, the `downgrade-pass`
call and `gate_design_pass_honored` already run through
`python3 marker_ops.py <subcommand>`, so the classification, token format and PASS
handling cannot diverge from the Write/Edit path. Every candidate path is first made
absolute as `abs = join(recorded_root, porcelain_relpath)`; nothing is resolved against the
hook process cwd. Return codes map as the shell maps them: `cmd_dd_exempt` is called inside
its own `try`, and 0, 2 or an exception means design doc (arm; 2 and an exception also
warn, matching the shell's fail-closed rc 2), 1 means skip. `cmd_arm` non-zero prints the
existing "could not arm" warning. After `cmd_downgrade_pass`, `cmd_reviewed([abs])`
returning 0 (still an honoured PASS) prints the existing "still reads PASS" warning.

`cmd_dd_exempt` keeps its one `git rev-parse --show-toplevel` per document (that is how it
finds the repo-relative path today, and `marker_ops.py` is not edited). That child has no
timeout of its own, so it is outside the deadline below; it is a sub-10 ms call per
changed document, and an overrun falls under the runner-kill residual.

The shell glue those helpers wrap is mirrored, and these are all of it:

| Step | Shell today | `design_effect.py` |
|------|-------------|--------------------|
| review-output exclusion | `grep -qiE '(reviews/\|review-needed\|review-state\|review-agy\|review-codex\|review-claude\|review-consensus\|review-autofix\|review-decisions)'` on the absolute path | same pattern, `re.IGNORECASE`, on the absolute path |
| memory exclusion | `grep -qE '(memory/\|lesson-)'` on the absolute path | same pattern, case-sensitive, on the absolute path |
| structural-dir exclusion | `grep -qE '(^\|/)(agents\|commands\|scripts\|hooks\|tests\|src\|lib\|skills)/'` on `gate_marker_relpath` (repo-relative, physical parent) | same pattern on `relpath(realpath(dirname(abs))/basename(abs), realpath(root))`, falling back to `abs` when outside the root |
| token key | `gate_marker_norm_path`: `pwd -P` of the parent + `/` + basename, leading `//` collapsed | `realpath(dirname) + '/' + basename`, leading `//` collapsed |
| marker dir | `gate_marker_dir`: `pwd -P` of `git rev-parse --git-common-dir`, plus `/busdriver/design-review-needed.local.d` | `realpath` of `git -C <parent> rev-parse --path-format=absolute --git-common-dir`, plus the same suffix, resolved once per root |
| downgrade containment | `realpath(doc)` under `realpath(git toplevel of the anchor)`, `-f` | `realpath(doc)` under `realpath(root)`, `S_ISREG` via `lstat` (as `cmd_downgrade_pass` itself also checks) |

A parity test pins it (Tests). For each armed doc the process prints the same three lines
the shell prints today (`Design document written: <basename>`, the `REQUIRED:` line and
the code-reviewer line), and the same "still reads PASS" and "could not arm" warnings on
stderr.

Each candidate is processed inside its own `try`/`except`: a failure prints a stderr
WARNING naming the path and the next candidate is still processed. `design_effect.py`
always exits 0 once it has parsed its input.

Ordering in the shell. For a Bash post event the effect step runs first, immediately after
the payload is read and before the redirect parser, because the parser block ends the
whole script with `exit 0` on an empty target and on each of its three exclusions, and
runs under the script's global `trap 'exit 0' ERR`. The effect step is

    _EFF_RC=0
    _EFF_OUT="$(printf '%s' "$INPUT" | python3 -I "$_LIBDIR/design_effect.py" diff "$_LIBDIR")" || _EFF_RC=$?
    [ "$_EFF_RC" -eq 0 ] || echo "WARNING: design-review effect check failed (rc=$_EFF_RC)" >&2
    [ -z "$_EFF_OUT" ] || printf '%s\n' "$_EFF_OUT"

A command substitution in an assignment followed by `||` triggers neither `errexit` nor
the ERR trap, and `_EFF_RC` is initialised first because the script runs under `set -u`.
The redirect parser then runs exactly as today, so every case that arms today still arms,
including writes outside the snapshot's reach (an ignored directory, another repository by
absolute path). There is no deduplication between the two: a redirect onto a design doc
that also changes its content gets one token from each path, which is harmless because
tokens are already per edit and `design-clear.sh --all-for-doc` releases them together.
Write/Edit/MultiEdit payloads never reach the effect step.

Deadline. `design_effect.py` measures from its own start (the macOS `/bin/bash` 3.2 shell
has no sub-second clock to hand over) and gives itself 3 s, in both `snap` and `diff`.
Every git subprocess `design_effect.py` itself starts (`status`, `rev-parse`, `ls-tree`,
`cat-file`) runs with `timeout=min(1.5, remaining)`, and the deadline is checked
before each file read, each blob batch and each candidate. A `git status` that times out
or fails leaves that root uncompared. When the deadline passes mid-way, `snap` records the
root as incomplete (the comparison then treats it as uncompared) and `diff` stops; in both
cases one stderr WARNING lists the roots or paths left uncompared or unprocessed. The
runner killing the hook at 5 s remains the residual every gate in this repo accepts.

### Where the halves run

Dispatch, tool first:

| `tool_name` | `hook_event_name` | Behaviour |
|-------------|-------------------|-----------|
| Write / Edit / MultiEdit | any | today's code, untouched; no snapshot lookup, no new output |
| Bash | `PreToolUse` | `design_effect.py snap`; prints nothing; exits 0 |
| Bash | `PostToolUse`, `PostToolUseFailure`, absent | `design_effect.py diff`, then the redirect parser and its per-document block |

Two new registrations, both for `Bash`, run the same `check-design-document.sh` through
the same exec-form `contained-launch.sh` / `sanitized-gate.sh` launch as the existing
PostToolUse registration, `closed` disposition, `timeout: 5`:

- `PreToolUse|Bash`: takes the snapshot.
- `PostToolUseFailure|Bash`: a Bash call that exits non-zero is delivered to
  PostToolUseFailure, not PostToolUse. Without this registration `python3 w.py && npm
  test` with a failing test, or a rewrite script that exits 1 after writing, would arm
  nothing, which is the #406 miss again.

The existing tests pipe Bash payloads with no `hook_event_name` and no `tool_use_id`; they
stay on the post path and get one extra stderr warning (no snapshot found), which none of
them asserts on.

`closed` rather than `open`, with its consequence stated: under `closed`,
`contained-launch.sh` turns any non-zero exit of the child into exit 2, and a PreToolUse
exit 2 denies the call. So a broken `check-design-document.sh` (a syntax error, an abort
before its `trap 'exit 0' ERR` is installed at line 27, a missing script) denies every
Bash call until it is fixed. That is accepted on purpose, for three reasons. It is a
visible stall, not a silent skip, which is this repo's stated preference ("a stuck session
is better than a skipped review"). The `closed` `pre-implementation-gate.sh` row on the
same `Bash` matcher already has exactly this property, so no new failure class is added.
And `open` would need the `--fail-open` wrapper flag that `validate-hooks.js` permits only
on the two GateGuard rows, widening an allowlist that exists to stop gates being flipped to
fail-open. To keep the Pre half from tripping it in normal operation, the PreToolUse
branch runs only after line 27's trap is installed, does all of its work inside
`design_effect.py` (which always exits 0 once it has parsed its input), and ends with an
explicit `exit 0`. The script itself never emits a decision. A launcher-level test runs
the real `PreToolUse|Bash` row (the `contained-launch.sh` command and args from
`hooks.json`) on a normal payload and asserts exit 0 with empty stdout.

### Snapshot storage

One JSON document per tool call holds every recorded root with its pre-call HEAD oid and
its S_pre map, at `$HOME/.claude/busdriver/design-effect.d/<digest>.json` with
`digest = sha256(utf8(session_id or '-') + b'\0' + utf8(key))` (directory created mode
0700; written to a temp file in the same directory and `os.replace`d). `HOME` in a
contained hook is the passwd-derived value `sanitized-gate.sh` sets, so the location
depends on neither the cwd nor the repository, and both halves find the same file whatever
the command did to the cwd. `key` is the payload `tool_use_id`, which the Claude Code hook
payload carries for these events (documented in the hooks reference). When it is absent
the key is `sha256(utf8(command))`; that is degraded mode, `snap` warns, and two
overlapping identical commands in one session can share a snapshot.

The comparison reads the file, diffs exactly the recorded roots, and deletes it. No file
found: one stderr warning ("no pre-call snapshot; Bash effect check skipped"), no effect
arms. A PreToolUse whose call never reaches a post event (denied by another gate or by the
user, or cancelled) leaves a file behind, so `snap` deletes files in that directory older
than 24 hours. Nothing is written inside any repository's marker store, so the
`design-review-needed.local.d` classifier never sees a non-token file.

## Performance

Measured before writing this spec, on this repository's worktree (warm cache, full
environment): `git --no-optional-locks status --porcelain -z -uall --no-renames` over the
whole tree took 0.095 s, and a `python3 -I` start with the imports `design_effect.py`
needs took 0.024 s. Each half therefore adds roughly 0.15 s per root to a Bash call. The
pathspecs only narrow git's output, not its walk of non-ignored untracked directories, so
a monorepo with a large untracked, non-ignored tree pays that walk on every Bash call; the
1.5 s subprocess timeout bounds it, and a timed-out root is skipped with a warning (the
redirect parser still runs). The new test re-measures both halves under
`env -i PATH=/usr/bin:/bin` with two roots and with 50 changed docs, and asserts each half
finishes under 4 s; those numbers go in the PR description.

## Error handling

The detector stays non-blocking, as the PostToolUse half always was. Its warnings go to
stderr, the convention the existing downgrade and arm-failure warnings in this script
already use: visible in the transcript and verbose mode, not injected into the model's
context.

- `snap` failure (git error, unwritable store, unresolvable HOME): stderr WARNING, exit 0.
  The Bash call proceeds.
- No snapshot at comparison time: WARNING and no effect-based arm. The redirect parser
  still runs after it. It never arms every dirty document instead: a harness that does not run the
  PreToolUse half would then re-arm every dirty design doc after every Bash call, including
  right after blueprint-review passes it, which is a deadlock rather than a gate.
- `git status` fails or times out for a root: WARNING, that root is uncompared.
- A path's read fails: the `unreadable` sentinel above. A revision read fails: the
  undecided candidates arm without a downgrade, with a WARNING.
- One path's processing fails: WARNING naming it, the next path is still processed.
- `design_effect.py` itself exits non-zero or crashes: the shell prints a WARNING and the
  redirect parser still runs.

## Alternatives considered

1. **Commit-time backstop in `pre-commit-gate.sh`** (the issue's second idea): arm or
   block when the staged diff touches a design path with no reviewed marker. Rejected. It
   fires only at `git commit`, after implementation writes the pre-implementation gate
   should already have blocked, and the docs-only carve-out (#685) lets a design-only
   commit through by design anyway. It also edits `pre-commit-gate.sh`, which the parked
   #622 branch rewrites.
2. **Arm on any working-tree change between Pre and Post**, including clean documents
   (the issue's literal wording). Rejected for the pull/rebase/checkout over-arm above.
3. **Post only, against a rolling "last seen" baseline** updated by every hook run. No new
   registration, but it attributes changes made outside any tool call (the operator
   editing `DESIGN.md` in an editor, another session) to the next unrelated Bash call, and
   needs a baseline the Write/Edit path must also maintain to avoid double-arming.
4. **Native `tool_response.bashEditDiff`** (Claude Code PostToolUse). The reference
   documents it as best effort, in public beta, absent unless `bashEditDiffEnabled` is set
   or the session is in auto/bypass mode, skipped for working-tree-moving git commands, and
   says to use it "to find what to review, not to enforce a policy". Not a basis for a
   gate.
5. **Fold the snapshot into `pre-implementation-gate.sh`**, which already runs on
   PreToolUse Bash. Rejected: its ERR trap emits a block, so a snapshot bug would deny
   Bash calls, and it returns early on many paths before a snapshot point.
6. **Widen the regex parser** (`sed -i`, `perl -pi`, interpreters). Rejected: an
   interpreter's write target is inside the script, not the command; this is the shape
   race the issue asks to leave.
7. **Let the effect result replace the parser for covered roots**, so an identical-content
   redirect stops arming. Rejected for this change: it would also stop
   `echo '<!-- design-reviewed: PASS -->' >> doc` from arming, which the parser path arms
   today, and the gain (one fewer spurious token on a no-op redirect) does not justify a
   behaviour change on an anti-self-stamp path.
8. **Snapshot copies inside each repository's git dir** (round 2 of this spec). Rejected:
   the post-event cwd follows the command's `cd`, so `cd /tmp && python3 /repoA/w.py`
   could not find any copy.
9. **Route each effect path through the shell per-document block** (rounds 2 to 4).
   Rejected: about nine process starts per document forced a deadline-and-skip budget that
   either left changed docs unarmed or armed excluded files, and isolating one path's
   failure under the script's global `trap 'exit 0' ERR` needs trap juggling the review
   found broken. Calling the same `marker_ops` functions in one process removes both
   problems.

## Residuals (stated, not fixed)

- **Cancelled calls**: interrupting a running Bash call fires neither post event (hooks
  reference), so a doc written before the interrupt is not armed. The snapshot is pruned
  after 24 hours.
- **Write and commit in one Bash call** (`node x.js && git commit -am x`): after the call
  the document equals HEAD, so it is not armed. This is the same time-of-check gap litmus
  has for any change committed in the call that made it, and is out of scope here. A merge
  that auto-combines two branches' edits to a design doc and commits in the same call is
  the same class: the synthesized body equals the new HEAD.
- **Index-only changes**: `git apply --cached` (or `git restore --staged --source=<ref>`)
  stages new content without touching the working tree, so that call does not arm; a later
  `git commit` in a separate call then records it, and the docs-only carve-out lets that
  commit through. Only working-tree bytes are hashed.
- **Roots not recorded**: a relative `cd ../other`, a second `cd` (effective_cwd falls back
  to the payload cwd on more than one), a `cd` that is not leading, or a `chdir` inside an
  interpreter into another repository is not a recorded root, so a doc changed there is
  not armed (the session's own repository is always recorded).
- **Uncompared roots**: a root whose `git status` times out or fails is not compared.
- **Gitignored documents**, and tracked docs marked `--assume-unchanged` or
  `--skip-worktree`, are invisible to `git status`. The Write/Edit path and the redirect
  parser still cover them.
- **Octopus and squash merges**: only the first `MERGE_HEAD` commit is a drop revision,
  and `merge --squash` writes no `MERGE_HEAD`, so a reviewed doc taken unchanged from a
  later octopus head, or from a stopped squash merge, arms. Over-arm, the safe direction.
- **Degraded key**: without a `tool_use_id`, two overlapping identical commands in one
  session can share a snapshot (Snapshot storage).
- **Broken detector**: a crash of `check-design-document.sh` in the PreToolUse half denies
  Bash calls (Where the halves run).
- **Deletion** of a design doc does not arm: it adds no unreviewed design content.
- **`git stash pop`** of a doc whose stashed content had been reviewed re-arms it (the
  bytes differ from HEAD and there is no way to know they were reviewed), and so does a
  doc that a `git revert` stopped on a conflict elsewhere has cleanly reverted (its body
  matches no drop revision). Over-arm, the safe direction.
- **Deadline overrun**: roots or docs left uncompared when the 3 s deadline passes are
  named in a WARNING but not armed.
- **Background Bash** (`run_in_background`): the post event fires at launch, before the
  command writes anything.
- **Suppression is possible for a deliberate actor**: a command can rewrite its own
  snapshot file, or delete tokens directly. ADR 0021 already scopes Bash write resolution
  as cooperative mis-fire protection; the snapshot directory is not added to the
  marker-forge guard.
- **Concurrent writers**: a change another session makes to the same worktree between Pre
  and Post is attributed to this call and armed. This over-arms, which is the safe
  direction.
- **Marker-only flips made by a script** do not arm through the effect path, the same
  trust the Edit path already gives a PASS line added with Edit. Tokens, not the PASS line,
  are what the pre-implementation gate keys on (SKILL.md #656), and a PASS line on a doc
  with an armed token does not unblock anything. A redirect that names the doc
  (`echo PASS >> doc`) still arms through the parser, as it does today.

## Tests

New `tests/test-design-effect-921.sh`, driving the hook the way the harness does (Pre
payload with `hook_event_name: PreToolUse` and a `tool_use_id`, run the command, post
payload with the same id) in temp repositories with `core.ignorecase=false`, the hook run
under `env -i PATH=/usr/bin:/bin HOME=<temp home> GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_SYSTEM=/dev/null` (the git configuration `sanitized-gate.sh` sets, without its
passwd-derived HOME, so the store lands in the temp home) from a hook process cwd outside
the repositories; one fixture repository sits under `<tmp>/src/proj` so an ancestor named
`src` must not exclude its docs. The launcher-level row test above is the one case that
runs through `contained-launch.sh` and `sanitized-gate.sh`. Driver commands use absolute
interpreter paths resolved before the environment is cleared; python3 is the primary
interpreter reproduction, the node case is skipped with a printed SKIP line when node is
not installed, and `sed` is invoked as `sed -i.bak` so the case runs on BSD and GNU sed.

- arms: python3 rewrite of a committed `DESIGN.md`; node rewrite; `sed -i`; `cp` through a
  variable destination; `git checkout other -- DESIGN.md`; script creating untracked
  `docs/plans/x.md`; script creating `sub/ARCHITECTURE.md` and `docs/specs/sub/y.md`
  (case and nesting through the pathspecs); script rewriting two docs (two armed); second
  rewrite of an already-dirty doc; a paragraph split and a two-space hard break; a rewrite
  followed by `false`, delivered as PostToolUseFailure; one call with a leading absolute
  `cd` into a second repository that changes a reviewed doc in each root (both armed and
  both downgraded to PENDING), run with the post cwd in repo A, in repo B, and in a
  non-repository directory; a committed doc carrying a truncated coverage line, then a
  loop-style repair plus PASS stamp in one call (no token, PASS survives) followed by a
  real body edit (arms); a call changing `docs/reviews/DESIGN-x.md`,
  `agents/plan-x.md` and `docs/plans/real.md` (only `real.md` arms); a command whose
  redirect target is excluded (`echo x > docs/reviews/DESIGN-log.md && python3 w.py`)
  while the script rewrites `docs/plans/real.md` (`real.md` arms); a two-root call where
  root A's marker dir path is made a regular file so arming there fails, and root B's doc
  changes (a WARNING names A's doc, B's doc arms); a conflicted doc resolved with new
  content and staged (arms); a doc git auto-merges from both sides while the merge stops on
  a `src/` conflict (arms); `git checkout -- DESIGN.md` when the index holds staged content
  that differs from both HEAD and the working tree (arms); an unborn-HEAD repository with a
  new design doc (arms); a 2 MiB design doc whose prose is edited (arms); a doc whose HEAD
  blob read is made to fail (arms, PASS line untouched).
- does not arm: Bash write to `src/a.txt`; identical-content rewrite by script; a script
  that stamps PASS and coverage the way the review loop does (in-place replace, `/d`,
  `printf '\n<marker>\n' >>`) on a clean doc and on a dirty doc; `git checkout -- DESIGN.md`
  restoring HEAD; `git commit` of an already-dirty doc; a fast-forward `git merge` that
  brings in a new reviewed spec; `git reset --soft HEAD~1` and `git reset HEAD~1` undoing a
  commit that added a reviewed doc; `ls` with a doc left dirty by an earlier Edit; a merge
  that stops on a conflict in a design doc (no token, conflict bytes untouched); a merge
  and a rebase that each stop on a `src/` conflict while bringing in a reviewed
  `docs/specs/x.md` (no token, PASS kept); `git checkout -- DESIGN.md` when the working
  tree already equals a staged blob that differs from HEAD (no bytes change, no token);
  `git pull --rebase --autostash` over a
  marker-only local edit where upstream changed the prose; with a dirty 2 MiB doc carrying
  PASS, an unrelated `ls` and a loop-style marker stamp (no token, PASS kept); a dirty doc
  made unreadable (`chmod 000`) followed by `ls` twice (no token on either call); a
  `python3 w.py && git commit -am x` that writes and commits in one call (no token, pinning
  the stated residual).
- parity: one fixed path set (a design doc, `docs/reviews/DESIGN-r.md`, `memory/DESIGN-m.md`,
  `agents/plan-a.md`, a `docs/plans` symlink escaping into `src/`) is written once through a
  Write payload and once through a Bash effect; the arm/no-arm result and the token group
  sha (the first field of each token name) are identical for every path.
- unchanged paths: a Write payload gives byte-identical stdout and stderr to the pre-change
  script and creates no snapshot file.
- error paths: a post payload with no snapshot warns on stderr and arms nothing via effect,
  while a redirect target in the same command still arms; a payload with no `session_id`
  and no `tool_use_id` still pairs its two halves; Pre exits 0 with empty stdout; the
  snapshot file is deleted after the comparison; a snapshot older than 24 h is pruned; one
  recorded root's `git status` fails (a corrupted index) and the other root still arms; a
  reviewed doc rewritten by script inside a directory then made read-only, so
  `cmd_downgrade_pass` cannot replace it (arms, PASS line untouched, and the "still reads
  PASS" warning prints because `cmd_reviewed` returns 0); `cmd_dd_exempt` made to raise
  for one candidate (that doc arms with a warning, the next candidate is still processed).
- timing: with two roots and 50 changed docs, each half completes under 4 s, all 50 docs
  arm, and no "uncompared" warning is printed.

Existing suites that must stay green: `tests/test-design-marker-cd-prearm.sh`,
`tests/test-design-marker-worktree.sh`, `tests/test-design-marker-degraded.sh`,
`tests/test-design-gate-docs-commit.sh`, `tests/test-gate-integrity.sh`,
`npm run validate`.

## Touch points

- `hooks/gate-scripts/check-design-document.sh`: dispatch table; for a Bash post event,
  run the effect step before the redirect parser.
- `hooks/gate-scripts/lib/marker_ops.py`: unchanged; imported, not edited.
- `hooks/gate-scripts/lib/design_effect.py`: new (`snap`, `diff`).
- `hooks/hooks.json`: new `PreToolUse|Bash` and `PostToolUseFailure|Bash` registrations.
- `scripts/ci/validate-hooks.js`: two roster lines
  (`PreToolUse|Bash|t=5|check-design-document.sh`,
  `PostToolUseFailure|Bash|t=5|check-design-document.sh`), `EXPECTED_CONTAINED` 20 to 22,
  `EXPECTED_EXEC_FORM` 18 to 20.
- `.gate-integrity.lock`: regenerated.

## Decisions taken without the operator

- Effect detection over the commit-time backstop (Alternative 1).
- Dirty-set comparison against the pre-call HEAD, with committed-content drops, over "any
  change", so pull, rebase, checkout, commit and reset never arm, and
  `git checkout -- DESIGN.md` that restores HEAD content does not arm. This narrows one
  example in the dispatcher's brief (which listed `git checkout -- DESIGN.md` as a case
  that must arm); `git checkout <other-ref> -- DESIGN.md` is the case that brings in
  unreviewed content, and it arms.
- A missing snapshot warns and skips rather than arming everything.
- The redirect parser is kept unchanged and runs after the effect step, with no
  deduplication between them (Alternative 7).
- Per-user snapshot store keyed by session and tool call (Alternative 8).
- In-process per-document processing through the shared `marker_ops` functions
  (Alternative 9).
- `closed` launch disposition for both new registrations.

<!-- design-review-coverage: FULL 3/3  -->
