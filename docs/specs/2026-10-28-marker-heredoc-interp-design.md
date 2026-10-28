# Issue #1052: stop reading an interpreter's quoted heredoc program as a shell function definition

Status: proposed, revision 4. Brainstormed with the operator on 2026-10-28 (split out of
#1025, which stays parked). The optional grill (Step 5.5) was skipped: adversarial review of
the mechanism is left to blueprint-review, and concrete adversarial fixtures are written
into the test file during implementation rather than into this document.

Revision 4 replaces the design of revisions 1–3. Those revisions masked qualifying heredoc
bodies inside an arbitrary command and then listed what elsewhere in the command disables
the masking. Blueprint-review iterations 1–3 each found, by execution, a new class of
same-command construct that re-points the interpreter's name, changes which descriptor the
body arrives on, or routes the program's output to a shell, and the loop parked on no
progress. A list of exclusions over shell syntax does not close. The operator chose a
whole-command allowlist instead (2026-10-29).

## Context

`hooks/gate-scripts/lib/marker_check.py` refuses a Bash command that can run the mutating
helper (`lease_slot.py`). Normally a helper *named* in an operand is data. The indirection
trigger (`_INDIRECTION_RE`, searched at the `INDIRECTION WITHDRAWS THE MENTION CONTRACT`
site in `_helper_invoked`) withdraws that contract for any command that can re-point a name
(a function definition, `function NAME`, `hash`, `alias`, `eval`, `BASH_CMDS[`), and hands
the whole command to `_abandoned_scan_probe`, which asks whether any word is a glob that
could expand onto a helper.

The `NAME()` branch is matched on the raw text and its `_shell_variants`. It does not know
about heredoc bodies, so a Python or JS method call inside a heredoc that an interpreter
reads as its program (`open(f).read()` inside `python3 - <<'EOF' … EOF`) reads as a zsh
function definition (zsh, the Bash-tool shell on macOS, accepts a simple-command body after
`name()`). The contract is withdrawn, and an ordinary regex or path glob in the same command
(`[^.]*`, `/*`) is then matched against the helper. The command is refused as "Cannot call
lease_slot.py directly" although it names no helper.

### Measurement (3.0.12, b623af3e, local macOS transcript corpus)

- 659 distinct refused Bash commands from 423 transcripts; 3.0.12 refuses 570.
- With the `NAME()` branch disabled outright (upper bound): 163 flip to OK.
- Of those, a prototype found 78 whose every `NAME()` match sits inside a quoted-delimiter
  heredoc received by a non-shell interpreter. The rest are inline `-c`/`'…'` payloads
  (55), heredocs received by `cat` (26, refused on purpose), and other shapes (4).
- Revision 4 accepts strictly fewer shapes than the prototype counted, so the number
  released will be lower than 78. It must be re-measured (see Acceptance).

### Ruled out (measured)

- A "`name()` must be followed by a compound command" narrowing holds only in bash; zsh
  accepts a simple-command body. The only follow-token narrowing true in all five shells
  (`NAME()` immediately followed by `)`) releases 6 commands.
- Keeping `'…'` spans literal for this branch releases at most 31 and uncovers a
  string-evaluator class (a `trap` string can redefine a command in bash and zsh, verified
  by execution).
- Keying on the receiver's command name alone (revision 1): some invocation forms of the
  same interpreters pass the body through as data, and perl can hand a body to another
  program based on its first line.
- Masking bodies inside an arbitrary command with a list of disqualifiers (revisions 2–3):
  every review round found a new same-command construct the list missed. Recorded in
  `docs/reviews/marker-heredoc-interp-design/`.

## Goal

A command that consists of nothing but `python3 - <<'EOF' … EOF` (or the Node equivalent,
optionally after a literal `cd … &&`), whose heredoc is the interpreter's program and merely
contains method calls, and which names no helper, is no longer refused. The gate's reach is
not otherwise reduced.

## Non-goals

- Any command with more in it than the shape in §2: pipes, other segments, substitutions,
  redirections to files, wrappers, interpreter options, path-qualified interpreters, perl,
  ruby. Each is left exactly as 3.0.12 treats it.
- Inline `-c '…'` payloads; heredocs received by `cat` (refused on purpose).
- The piped-shell-producer probe, and #1025's two shapes (case-pattern and `$(`-flatten).
- Any change to the `function NAME`, `hash`, `alias`, `eval` or `BASH_CMDS[` branches, or to
  `_abandoned_scan_probe`. A Python body that contains `hash(` or `eval(` therefore still
  triggers; that shortfall is counted in the re-measure.
- zsh's writable command tables missing from `_INDIRECTION_RE` (a pre-existing gap filed as
  #1055).

## Design

### 1. The change

Only `marker_check.py`, only the `NAME()` branch at the withdrawal site in
`_helper_invoked`.

- Split `_INDIRECTION_RE` into the `NAME()` header pattern and the remaining branches. The
  remaining branches keep searching the variants of the full command, unchanged.
- A new predicate `_stdin_program_only(cmd)` decides on the **raw** command string whether
  the whole command is the shape in §2. When it is true, the `NAME()` pattern is not
  searched. When it is false, the `NAME()` pattern searches exactly what it searches today.
- Nothing else changes. The literal-helper-name scan and every other site still read the
  full command, body included.

Because the whole command matches §2, its only text outside the heredoc body is the
introducer line, which by construction contains no `(`. So skipping the `NAME()` search is
the same as searching with the body blanked, and no span arithmetic is needed.

**cmdword twin stays unchanged.** `cmdword._FUNC_DEF_RE` / `_has_indirection` feed only
`is_file_mod`, which blocks solely while a design review is pending. Both sites get a
comment recording the asymmetry as deliberate, as the existing `eval` asymmetry is
recorded. Revisit trigger: a reported file-mod over-block of this shape.

### 2. The accepted shape

`_stdin_program_only(cmd)` is true only when **all** of the following hold. It is a
positive grammar over the raw string; anything that does not match is false.

**2a. Lines.** Split `cmd` on `\n` only. Line 1 is the introducer line. Some later line is
the terminator line. Every line between them is the body. Nothing follows the terminator
line except at most one empty final element (a single trailing newline).

**2b. Introducer line.** It matches this token grammar exactly. Tokens are separated by one
or more spaces; there is no leading or trailing whitespace; there are no other characters:

```
[ cd WORD && ] RECEIVER [ - { WORD } ] [ ERR ] HEREDOC [ ERR ]
```

- `RECEIVER` is exactly one of `python`, `python2`, `python3`, a name matching
  `python[23]\.[0-9]+t?`, or `node`, compared as a whole token.
- `-` is the single character `-` as a whole token. With it, the interpreter reads its
  program from stdin and any following `WORD`s are the program's argv. Without it, no
  argument is allowed, and the interpreter reads its program from stdin because stdin is
  not a terminal.
- `WORD` is a non-empty run of `[A-Za-z0-9_./:@%+,=-]` that does not start with `=` (zsh
  expands a leading `=`), or a single-quoted string with no `'` inside it. Either form is a literal in bash and zsh: no expansion, substitution,
  glob, tilde, brace or backslash can occur.
- `ERR` is one of `2>&1`, `2>/dev/null`, `>/dev/null`. No other redirection is accepted.
- `HEREDOC` is `<<` immediately followed by a quoted delimiter: `'D'`, `"D"` or `\D`, where
  `D` matches `[A-Za-z_][A-Za-z0-9_]*`. No descriptor prefix, no `<<-`, no space between
  `<<` and the delimiter. Exactly one `HEREDOC` token.

**2c. Terminator line.** It is the **first** line after the introducer line that equals
`D` exactly (no leading or trailing characters, including `\r`). That is the line both
shells end the body at. If no line equals `D`, or a later non-empty line exists after it,
the predicate is false.

**2d. Consequences.** Because the introducer line is the whole command apart from body and
terminator, these cannot occur in an accepted command: a second segment, a pipe, a
substitution, a backtick, a second heredoc, a function definition, a sourced file, an
`exec`, a coprocess, a process substitution, an assignment, an alias or a table write. No
same-command construct is left that could re-point `RECEIVER`, change where the body
arrives, or receive the program's output. The receiver's stdout goes only to the Bash
tool.

Python and Node both read the stdin program as source and treat a leading `#!` line as a
comment; the tests verify both by execution.

### 3. Residual, stated

- **Outside the command.** What `RECEIVER` or `cd` resolves to is decided by the
  environment the command runs in (PATH, functions or aliases from outside the command).
  That is the existing ADR 0006 residual for definitions made outside the command; this
  change does not add to it.
- **The program itself.** A Python or Node program can build any text, write it to a file
  or hand it to a shell. The gate cannot see what it builds. That already holds on 3.0.12
  for program text without `NAME()`-shaped text: iteration 1 measured a Node stdin program
  that writes a script and runs it with `sh` as OK, and iteration 2 measured that a helper
  glob in a Python stdin body with no `NAME()` is OK. This change extends that existing
  allowance to program text that happens to contain `NAME()`-shaped text. It does not
  change the literal-helper-name scan, which still reads the body.

The code comment at the predicate states both points and cites ADR 0006.

### 4. Performance

The predicate makes one pass over the introducer line and one scan for the terminator
line. It is linear in the command length and runs only when the command contains `<<`.
A test asserts a 64 KiB accepted command and a 64 KiB rejected near-miss each classify in
under 1 second.

## Testing

New file `tests/test-marker-heredoc-interp-1052.sh`, following
`tests/test-marker-1013-holes.sh`:

- Same harness (`verdict()`, a stub helper in a scratch tree, the helper name assembled
  from fragments).
- Every fixture is tagged with the shells it runs under. Where `zsh` or `node` is missing,
  the row prints SKIP; it never passes silently.
- Three row types:
  - **BLOCK (executes):** first executed, and must really run the stub (checked by a
    marker file the stub writes, not by exit status). A fixture that does not is a FAIL.
  - **BLOCK (does not execute, must stay BLOCK):** a deliberate over-block, labelled as
    such.
  - **OK:** must classify OK. It is executed, and must show that the interpreter ran the
    body (the body writes a sentinel) and that the stub did not run.
- OK pins: `python3 - <<'E'`, `python3 <<'E'`, `node - <<'E'`, `node <<'E'`, `python3 -
  a b <<'E'`, `cd dir && python3 - <<'E'`, `2>&1` and `>/dev/null` forms, `"E"` and `\E`
  delimiters, a body whose first line is `#!`, and a body with method calls plus an
  ordinary regex or glob.
- BLOCK pins: one executing fixture for each class found in review iterations 1–3 that is
  BLOCK on 3.0.12, written as the shortest command containing that class plus a `NAME()` in
  a python body. Each must stay BLOCK because it does not match §2. The classes are those
  the arbiter confirmed in iterations 1–3 (iteration 3's verdict is archived under
  `docs/reviews/marker-heredoc-interp-design/attempts/`); the implementation plan lists
  them one per fixture.
  Also: a helper name spelled in the body; a near-miss on every §2b token (an extra space
  form, an option, a path-qualified or suffixed name, an unquoted delimiter, `<<-`, a
  descriptor prefix, a file redirection); a trailing line after the terminator; CRLF line
  endings; and the existing `cat <<'E' > x.sh` + run pin.
- Residual pin: a comment naming the 3.0.12-allowed counterparts (§3), plus an assertion
  that they are OK before and after this change. It is not a fake BLOCK.
- Timing check per §4.

Regression: all `tests/test-marker-*.sh` and `tests/test-gate-integrity.sh` locally; the
full shell suite via `um-run test`. `./scripts/gate-integrity.sh --update` is recorded in
the same commit as the gate edit.

## Acceptance

- Corpus re-measure, rebuilt from local transcripts, comparing 3.0.12 with the branch.
- **Zero OK→BLOCK.**
- **Every BLOCK→OK flip matches §2.** The re-measure checks this with a separate
  implementation of the §2 grammar (a regex over the raw command written independently of
  the gate code). Any flip it rejects fails acceptance. The full list of released commands
  is attached to the PR for human review.
- The number released is reported as measured, with the shortfall against 78 split by
  reason (pipe or other segment, file redirection, wrapper or option, path-qualified,
  perl/ruby, other indirection branch such as `hash(`, other). The count is not tuned to a
  target. Any widening is a later change with its own review.
- New and existing tests pass; lock updated; litmus and pr-grind clean.

## Relationship

Split from #1025 (parked; resume after this lands and re-measure first, because this change
alters which site fires first). #1055 tracks the pre-existing zsh command-table gap found
during this review. Follow-up #1047 is unrelated. Deferred review items are in
`docs/reviews/marker-heredoc-interp-design/follow-up-issues.md`.

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
