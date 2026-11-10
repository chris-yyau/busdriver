# Issue #1085: cmdword reads substitution bodies and comments the way bash does

Status: proposed, revised after blueprint-review rounds 1–3. The operator approved the design in
brainstorming and skipped the optional grill (Step 5.5). The opted-in ultra-oracle consult
(Step 5.6) failed twice on an adapter race unrelated to the design (#1086), and the operator
chose to skip it once. A fable subagent reviewed the design adversarially before it was
presented, and its findings are folded in. blueprint-review is the review of record.

## Context

`hooks/gate-scripts/lib/cmdword.py` exposes `is_file_mod(cmd)`: does this Bash command
write files? `pre-implementation-gate.sh` uses it to block writes while a design document
is unreviewed. When `is_file_mod` is False, the gate also runs its own raw redirect check:
it strips single-quoted text, drops `/dev/null` and fd-to-fd redirects, then looks for
`>`. "The gate's verdict" below means the two together. The classifier fails closed on the
decisions it reaches. But a hook the runner kills at its 5 s timeout emits nothing, and the
command proceeds, so worst-case run time is part of the security property.

What `_is_file_mod` does today, in the order that matters here:

1. `_command_substitutions(cmd)` finds `$( )` and backtick bodies. It ends each body with
   `_subst_end`, which counts parentheses and knows only quotes and backslashes. Each body
   is classified recursively, with a depth cap of `_MAX_DEPTH = 4`. When a body holds the
   word `case`, the #1063 over-read also classifies every longer body ending at a later
   `)`, charged to `_case_budget`; a spent budget blocks. When the scanner finds no closer,
   the command gets `_regex_fallback`: verb patterns only, which cannot see a redirect.
2. `_normalize` joins `\<newline>` continuations everywhere. It runs `_defuse_comments`,
   which blanks the separators inside comments so the splitter cannot see them. It then
   turns every newline into ` ; `, including newlines inside quotes. The segments are
   classified. An executed string such as a `bash -c`, `sh -c` or `eval` argument is
   classified recursively as shell source.
3. `is_file_mod` runs a second reading of the whole command, OR-ed with the first, when
   `_ansi_c_differs(cmd)` fires. That reading reads `$'…'` and escaped dollars the way bash
   does. Its flag is `_ansi_c_reading`; it starts at depth 0 only, and the flag stays set
   through that reading's recursion.

Every shared budget runs out toward block. `_scan_budget` and `_case_budget` return True,
and `_psub_budget` falls back to a raw regex scan.

The sibling anti-forge gate, `hooks/gate-scripts/lib/marker_check.py`, already has a
hardened shell lexer:
- `_subst_body_end` handles comments, heredocs (quoted delimiters included), `${ }` through
  `_param_span`, `$'…'`, backticks, nested `$(` in double quotes, `((` and `$((`
  arithmetic, `[[ ]]`, and a `case` state machine. Its recursion is capped at
  `_SPAN_MAX_DEPTH = 200`.
- `_subst_bodies` is the top-level extractor: it skips comments and every heredoc body,
  and treats `$((` with a matching `))` as arithmetic.
- `_join_continuations` is heredoc-aware.

cmdword cannot import marker_check, because marker_check reads stdin at module level.

## Problem

All of these reproduce on `main` with bash 5.3: bash writes, and the gate's verdict is
allow.

1. **`_subst_end` closes a body at a `)` bash never reads as a closer**, inside `${ }`, a
   comment, a heredoc body or `$'…'`. Nothing after it in the real body is read.
   - `: "$(echo ${v%)}; rm -rf src)"`
   - `: "$(# )` + newline + `rm -rf src)"`
   - `: "$(cat <<E` + newline + `)` + newline + `E` + newline + `rm -rf src)"`
2. **The comment defuser treats non-comments as comments, and misses comments that end
   at a newline:**
   - `#` inside `${ }`: `echo ${v%<<E #}; rm -rf src`
   - `#` inside a backtick body: ``echo `echo # `echo ; rm -rf src``
   - `#\<newline>`: `_normalize` joins continuations before it defuses comments, but bash
     ends a comment at the newline. Example: `echo #\` + newline + `rm -rf src`.
   - **A comment inside a quoted program:** `bash -c 'echo # x` + newline +
     `rm -rf src'`, and the same with `sh -c` and `eval`. The newline inside the quotes
     became ` ; ` before the inner program was read, so its comment ran to the end and
     swallowed the write. Multi-line `bash -c` scripts with comments are an ordinary shape,
     so this is the most common hole of the set.
   - **The same, spelled in ANSI-C escapes:** `bash -c $'echo # x\nrm -rf src'`, and with
     the `#` itself escaped, `bash -c $'echo \x23 x\nrm -rf src'` (also `\043`, `#`,
     with `sh -c` and `eval`). cmdword's `_decode_escapes` decodes only `\x`, `\u`, `\U`
     and octal, so `\n` stays two characters and the program reads as one line. The raw
     text has no `#` at all in the second spelling.
3. **A comment's apostrophe hides a redirect inside a substitution.** In
   `: "$(echo # it's` + newline + `echo x > src/f)"`, `_command_substitutions` takes the
   apostrophe as a quote that never closes, and the command goes to the verbs-only
   fallback. The gate's raw check finds `>` here, but not when the same body sits inside a
   single-quoted `bash -c` program.

A structured fuzz measures the size. It builds commands from fragments that each hold
something bash does not treat as syntax: a `)`, a `#` or a continuation (`${v%)}`, `$'\)'`,
`# )` + newline, heredocs with `)` lines, `` `echo )` ``, `$((1<<2))`, `case` arms,
`ca\<newline>se`, `$\<newline>{`, `# it's` + newline, `<( )`, `$'\x23 )'`, …). It puts
them in 9 forms: quoted `"$( )"`, `;` and newline variants, unquoted `$( )`, top level with
`;` and with a newline, a `bash -c` program, and a `bash -c $'…'` program with `#`, `'`,
`\` and newlines written as escapes, also with its opener split by a continuation
(`$\<newline>'`) and by quote concatenation (`"eval \$""'…'"`). It uses two write kinds,
`rm -rf src` and `echo x > src/f`. Real bash runs each command in a scratch tree. Over two
seeds, of 38,412 commands that wrote, the gate's verdict on `main` allowed 11,055.

## Goal and non-goals

**Goal:** the gate's verdict is block for the shapes above. The new lexer blocks anything it
cannot read in the command as written. Every change only adds blocks. The worst-case time
stays well inside the hook timeout.

**Non-goals:**
- **Removing the #1063 `case` over-read**, and with it the over-blocks it accepts. That
  would loosen the gate, so it goes in a separate issue once the fuzz shows 0 misses
  without it. This was the operator's decision.
- **Reading heredoc bodies as data.** cmdword reads them as shell on purpose, which fails
  closed, and this design keeps that.
- **marker_check's own run time**, which already exceeds the hook budget on some inputs on
  `main` (see Residuals; tracked separately).
- **Making marker_check's own `_join_continuations` comment-aware.**

## Decision

### A. One shared lexer: `lib/shell_lex.py`

Move marker_check's lexer verbatim into a new module, `hooks/gate-scripts/lib/shell_lex.py`.
The moved names are the dependency closure of `_subst_bodies`, computed from the AST:
- functions: `_subst_bodies`, `_subst_body_end`, `_join_continuations`, `_param_span`,
  `_backtick_span`, `_heredoc_delim`, `_heredoc_body_end`, `_ansi_c_span`,
  `_arith_closes`, `_decode_escapes`;
- data: `_paren_matches`, `_ESC_RE`, `_RESERVED_AT_CMD_RE`, `_RESERVED_END_RE`,
  `_PARAM_PATTERN_OP_RE`, `_SPAN_MAX_DEPTH`, `_SQ`.

`_SQ` is the only name `_ansi_c_span` needs at call time. marker_check keeps its own `_SQ`
too, because its other functions use it.

- **marker_check** inserts `os.path.dirname(os.path.abspath(__file__))` into `sys.path`.
  It has to be `__file__`: the gate runs it as `python3 -I marker_check.py`, where the
  script directory is not on the path, and six test files load it through
  `spec_from_file_location`, where `sys.argv[0]` is not the script. The insert comes after
  marker_check's standard-library imports, so a file in `lib/` named like a stdlib module
  cannot shadow one; `shell_lex` itself imports only `re`, which is loaded by then. It
  then imports the moved names under their existing names, and the rest of the file is
  untouched. The
  import is at module level, before the stdin `try:`. If it fails, the process exits
  non-zero with no verdict, and the gate's `|| echo "BLOCK_CLASSIFIER_ERROR|exec"` blocks.
- **cmdword** runs `import shell_lex` at module level. If that fails, the gate's
  `from cmdword import is_file_mod` fails, `is_file_mod` stays None, and the gate uses
  `FILE_MOD_PATTERNS`, the pre-#519 classifier, documented there as strictly wider.
- The directory is pinned by `.gate-integrity.lock` (#742), so `shell_lex.py` is locked like
  every other gate file. This change regenerates the lock.
- `_subst_bodies` also returns `<( )` and `>( )` bodies. Outside double quotes and outside
  `(( ))`, `<(` and `>(` take the `$(` path through `_subst_body_end`. That is the same
  closer bug, in a spelling neither extractor covered. For marker_check it means more
  bodies scanned for helper calls, so only more refusals.
- Every "KEEP IN STEP WITH" comment that names a moved function is rewritten to name
  `shell_lex`. `tests/test-escaped-dollar-1048.sh` compares `_ansi_c_span` in cmdword with
  marker_check's copy through the AST. It is changed to compare it with `shell_lex`'s,
  because marker_check no longer defines it.

Moving the code rather than copying it follows the repo rule "unify sibling gates; don't
special-case". A third copy of about 590 lines, kept in step by comments, is exactly the
drift this module ends.

### B. More bodies, in every reading and at every depth

cmdword's `_command_substitutions`, `_subst_end` and the #1063 over-read stay exactly as
they are. Right after them, `_is_file_mod` also classifies the bodies from the shared lexer
that it has not already seen:

```
bodies, subst_ok = _command_substitutions(cmd)
if subst_ok is None:
    return True                                  # unchanged
extra, extra_ok = _lex_bodies(cmd, bodies)
if not extra_ok and _depth == 0:
    return True                                  # the command as written is unreadable
for body in extra:
    if is_file_mod(body, _depth + 1):
        return True
if not subst_ok and extra_ok:
    if _regex_fallback(cmd):                     # what main returned, still a block
        return True
    # ...and continue to the tokenized reading instead of stopping at the verbs-only verdict
elif not subst_ok:
    return _regex_fallback(cmd)                  # unchanged
...                                              # unchanged from here
```

**`_lex_bodies(cmd, seen)`** works like this:
- It runs `shell_lex._subst_bodies` on the command, with CR and CRLF turned into LF as
  `_normalize` does.
- When a line matches `(?:^|(?<=[\s;&|()<>`]))#[^\n]*\\\n`, meaning a `#` at the start of a
  word followed by a continuation on the same line, it also runs on a copy where that
  backslash is replaced by a space. The plain run reads that `#` as text, so the
  continuation joins. The copy reads it as a comment that ends at the newline, which is what
  bash does with a real comment. A regex cannot tell which reading is right, but one of the
  two always is.
- The word-start anchor keeps `${v#x}` and `$#` out of the copy. They are never comments,
  and without the anchor the copy failed on read-only commands such as
  `echo $(case ${v#x} i\<newline>n …)`.
- It returns the bodies from either run that are not in `seen`, deduplicated, with
  `ok = False` if either run gave up.

**Unreadable blocks only at depth 0.** There the string is the command as written. At depth
1 and below, the strings are derived: bodies `_subst_end` cut short, or `_ansi_c`'s
respelling. The lexer gives up on those even when the command is fine. Examples:
- `: "$(echo ${v%)})"` gives the cut body `echo ${v%`;
- `echo $'it\'s'` is respelled `echo 'it\'s'`.

Blocking on those would block read-only commands. A body the lexer extracts at depth 0 is
never truncated, because the lexer found its closer.

**The fallback change** closes problem 3. When `_subst_end` finds no closer but the lexer
reads the command, the cause is a quote or paren the lexer has already placed, typically
inside a comment. The old verbs-only verdict is kept as a block, and the command also goes
through the normal tokenized reading, which sees redirects. The code comment at that branch
states this residual and explains why a raw redirect scan was withdrawn twice. This fix is
neither of those: it runs only when a comment-aware lexer has read the command, and it uses
the comment-defusing reading, not a raw scan.

This step only adds blocks:
- an extra body can only add a True;
- the depth-0 not-ok return is a True;
- the fallback branch keeps main's True and adds the tokenized reading;
- the extra recursion spends shared budgets, and each runs out toward block.

### C. A third reading: bash-faithful

`is_file_mod` gets a third reading. It does not change the existing `$'…'` reading, which
would not be additive: blanking quoted heredoc bodies in that reading, tried during
review, dropped three real `python3 - <<'PY'` file-editing scripts the existing reading
blocked.

```
if _is_file_mod(cmd, _depth):
    return True
if _depth or _ansi_c_reading[0] or _lex_reading[0]:
    return False
if _ansi_c_differs(cmd):                         # second reading, unchanged
    with _ansi_c_reading set:
        if _is_file_mod(cmd): return True
if "#" not in cmd and "$" not in cmd:
    return False
with _ansi_c_reading and _lex_reading both set:  # third reading
    return _is_file_mod(cmd)
```

**Trigger.** The third reading runs whenever the top-level command contains a `#` or a
`$`. Every narrower trigger tried was beaten by a spelling that hides the text it looks
for from the top level, because the inner program is reached only at depth ≥ 1, where no
reading starts:
- `#` plus a literal `${`, backtick or continuation: quote concatenation hides `${` in
  `bash -c 'echo $''{v%<<E #}; rm -rf src'`;
- `#` alone: `\x23` in `bash -c $'echo \x23 x\nrm -rf src'` has no `#`;
- `#` or `$'`: `bash -c "eval \$""'…'"` splits `$` from `'` with quote concatenation, and
  `bash -c $\<newline>'…'` with a continuation.

What none of them can hide is the `$` itself: in bash only `$'…'` turns an escape into a
`#` or a newline before the shell parses, and every `$'…'` at any depth starts from a `$`
in the text as written, possibly escaped or quoted but present. (`_ansi_c_differs` fires on
both concatenated shapes too, but it is narrower than "has a `$`" for no measured gain.) A
program built at run time (`bash -c "$(printf '\x23…')"`) is not statically known, as on
`main`. The cost of the wider trigger is in Performance.

**What it includes.** It sets `_ansi_c_reading` as well, because that same shape needs the
`$'…'`/`$` handling and the `${ }` comment fix together. Under `_lex_reading`:

- `_normalize` runs the defuser on the **unjoined** text, then
  `shell_lex._join_continuations`, which is heredoc-aware where the old
  `replace("\\\n", "")` was not.
- **A `$` followed by a continuation** (`$\<newline>`, anywhere in the command, quotes
  included) raises the existing `_paren_hash_ambiguous` flag, which routes the command to
  the existing fail-closed fallback: `_regex_fallback` plus the raw redirect scan over
  `_shell_variants`, which see a write regardless of comments. `_param_span` walks the raw
  text and recognises a nested `${` only when `{` follows `$` directly, so in
  `echo ${v:-$\<newline>{x#}<<E #}; rm -rf src` it ends the outer span at the inner `}`,
  and the `#` after it would read as a comment. Mapping spans through a joined copy would
  fix that, but the joined copy is a second string for `_arith_closes`' one-entry cache,
  and alternating between the two strings rebuilds it each time (quadratic on padding). A
  read-only `echo $\<newline>{HOME}` still allows, because the fallback finds no write.
- `_defuse_comments`, outside quotes:
  - passes a `\<newline>` through without changing its word-position state, so
    `x \<newline># c` stays a comment and `a\<newline>#b` stays a word;
  - copies `${…}` whole through `_param_span` and `` `…` `` whole through
    `_backtick_span`. A `#` inside either opens nothing. When a span has no end, the
    `_paren_hash_ambiguous` flag goes up, as above;
  - copies `$((…))` whole when `_arith_closes` holds, so its `<<` is no heredoc;
  - recognises heredoc introducers through `_heredoc_delim` (and `<<<` as a herestring)
    and copies each body whole through `_heredoc_body_end`, so an apostrophe in a body
    cannot flip the quote state for the rest of the command;
  - blanks a comment's backslash along with its separators, so `#…\` cannot join the next
    line.
- **`\$` inside double quotes loses the backslash**, as in bash. shlex keeps it, so
  `bash -c "eval \$""'… \$((1<<2)) …'"` reached the inner program as `\$((1<<2))`, whose
  `<<2` then read as a heredoc that swallowed the rest of the program, write included
  (fuzz). The defuser emits the bare `$`. `\"`, `\\` and `\<newline>` are already handled
  (shlex, and the join). `` \` `` keeps its backslash: dropping it made the outer reading
  see a substitution in four read-only `grep "…\`…"` corpus commands, and it did not make
  `bash -c "echo \`rm -rf src\`"` visible either (see Residuals).
- **Function-definition headers use a narrower name.** `_normalize` drops `name() {`
  headers with `_FUNC_DEF_RE`, whose name class is any run of non-metacharacters, backticks
  and backslashes included. In a quoted program not yet decoded,
  ``echo `echo )`\nf() { :; }`` (with `\n` still two characters) let it take
  `` `\nf() `` as the header after `)` and delete the closing backtick, which unbalanced the
  rest of the program and hid the write after it (fuzz). The third reading uses the same
  pattern with backticks, backslashes, quotes and `$` excluded from the name. Dropping
  less text can only leave more to classify.
- **`$'…'` is decoded as bash decodes it.** `_requote_ansi_c` already finds each span
  and respells it as a plain single-quoted string. Under `_lex_reading` it first decodes the
  body in one left-to-right pass with bash's full escape set: `\a \b \e \E \f \n \r \t \v
  \\ \' \" \?`, `\xH{1,2}`, `\uH{1,4}`, `\UH{1,8}`, `\ooo`, `\cX`, with an unknown escape
  kept as written and the string ending at a decoded NUL, as in bash. Every `'` in the
  result is then written `'\''`. `_normalize` respells after it has turned newlines into
  ` ; `, so a decoded newline stays inside the quotes and reaches the `bash -c` program's
  own reading as a newline. The first and second readings keep `_requote_ansi_c` and
  `_decode_escapes` unchanged; `_decode_escapes`' narrower set is what they need for the
  command word. The decoding is a branch inside `_requote_ansi_c`, guarded by
  `_lex_reading`, not a separate pass: a separate pass would need its own copy of the
  quote-context walk (`_drops_dollar`, `_bash_quoted`) that decides where a `$'` is an
  ANSI-C quote, a third copy to keep in step. With the flag off, `_requote_ansi_c` is
  marker_check's; the parity test checks exactly that (Tests).
- **Newlines inside quotes survive.** Inside single or double quotes the defuser emits a
  placeholder (`\0`) for each newline. `_normalize` turns the remaining newlines into
  ` ; ` as before, then restores the placeholders to newlines. A `bash -c`, `sh -c` or
  `eval` program therefore reaches its own recursive reading with real newlines, and its
  comments end where bash ends them.

At most three full readings run, and the third only when the first two allowed. The worst
case needs the second reading's trigger and a `#` or `$'` in the same command.

### D. An exception inside the classifier blocks

`pre-implementation-gate.sh` ends its inline classifier with `except Exception:
print("SAFE|")`, and its call to `is_file_mod(cmd)` has no guard of its own. So today any
exception thrown inside `is_file_mod` allows the command. This change adds a lot of lexer
code to that path, and possible sources include `RecursionError`: the
`_subst_body_end` ↔ `_param_span` recursion is capped at 200, with Python's default limit
at 1000. The call is wrapped so that an exception classifies the command as a write:

```
try:
    has_explicit_mod = (is_file_mod(cmd) if is_file_mod is not None else ...)
except Exception:
    has_explicit_mod = True
```

This covers exceptions raised inside `is_file_mod`. The outer `except` stays as it is: it
covers payload-parsing failures. So does the shell's `|| echo "SAFE|"`, which a process
that dies outright still reaches. Both are unchanged, and both are listed under Residuals.

## Performance

The 5 s hook timeout covers the whole hook, so the figure that matters is marker_check
(which always runs first, in its own `python3 -I`) plus `is_file_mod` (in the gate's
second python process), on the same command. Every reading grows linearly with command
length. Measured on an idle M-series Mac, at 64k characters (`_MAX_CMD_CHARS`), on an
adversarial set of 76 inputs: 19 padding units (nested `$(` with `${v%)}`, backticks,
heredocs, `}`, quoted newlines with `#`, `$(( ))`, `<<<`, `case`, `$'\x23\n'`, …) × 4
tails, each behind a trigger for every reading and with a benign tail, so all three
readings run to the end.

| Measure | main | design |
|---|---|---|
| Real-command corpus, slowest single `is_file_mod` verdict | — | 0.034 s |
| Adversarial set, slowest `is_file_mod` alone | 0.11–1.0 s | 1.84 s |
| Adversarial set, slowest marker_check + `is_file_mod`, on the 68 inputs where marker_check finishes on `main` | 2.19 s | **2.63 s** |
| Adversarial set, inputs where marker_check alone exceeds 5 s on `main` | 8 | 8 (unchanged; see below) |

The worst `is_file_mod`-alone input and the worst end-to-end input differ: where
`is_file_mod` is slowest, marker_check is fast or gives up early with `BLOCK_UNSCANNABLE`,
which blocks before cmdword runs.

**The timing test runs the real hook**, `pre-implementation-gate.sh` with a design pending,
on the 68 inputs, and requires a block decision from each within 4.0 s of wall time,
process start-up included. That leaves 1 s under the kill, and 1.5× the measured worst for a
slower CI runner. It measures marker_check as changed by this design (the move and the
`<( )` bodies), so a slowdown there fails the same test.

**marker_check over budget on `main`.** On 8 inputs (repeated backticks or `$(` behind a
`#\<newline>` and a `$'\''`), marker_check alone takes longer than 5 s on `main`: 11 s at
about 4,000 characters of backticks, more than 20 s at 16,000 characters of `$(`. A timeout
allows the command, so on these inputs the hook already fails open on `main`, before cmdword
runs. That cost is in marker_check's own scan, not in `_subst_bodies`: `is_file_mod` under
this design finishes those inputs within the 1.84 s above. Fixing marker_check's scan is outside
#1085 and is tracked as its own issue; the timing test excludes exactly these 8 inputs and
names them.

## Error handling

| Failure | Outcome |
|---|---|
| `shell_lex.py` missing or unimportable, marker_check | process exits non-zero → `BLOCK_CLASSIFIER_ERROR\|exec` → block |
| `shell_lex.py` missing or unimportable, cmdword | `is_file_mod` None → `FILE_MOD_PATTERNS` (wider) |
| Lexer finds no closer in the command as written | depth-0 not-ok → True |
| Lexer gives up on a derived string (depth ≥ 1) | ignored; main's reading of that string stands |
| Exception raised inside `is_file_mod` | D → write → block while a design is pending |
| `${`/backtick span without an end in the defuser | `_paren_hash_ambiguous` → existing fail-closed fallback |
| Budget exhausted by extra bodies | existing behaviour: True, or raw-regex scan for `_psub_budget` |

## Alternatives considered

Each was prototyped and measured with the same fuzz and corpus.

1. **Replace `_subst_end` with marker_check's `_subst_body_end`.** This fixes the closer
   but is not additive: 56 corpus commands went from block to allow. Most were `$(( … ))`
   arithmetic that `main` misreads as a subshell body, which happens to block. Rejected,
   because a fix to a fail-closed classifier may only add blocks.
2. **Put the comment fixes into the existing `$'…'` reading.** That keeps 2 passes, but it
   is not additive: three real writes that reading blocked went to allow. Rejected for C.
3. **Narrower third-reading triggers.** `#` plus a literal `${`, backtick or continuation
   missed quote-concatenated programs; `#` alone missed a `#` written as `\x23` (see C).
   Rejected.
4. **Trigger only, no full `$'…'` decoding.** Starting the third reading on `$'` while
   keeping `_decode_escapes` left `\n` undecoded: every `bash -c $'…\n…'` shape in
   Problem 2 still allowed. Rejected.
5. **A regex pass blanking comments inside quoted strings**, instead of preserving their
   newlines. It treated each quoted segment on its own, so it broke on `'\''` splicing and
   on `#` inside `${ }`, and the fuzz found a miss. Rejected for the defuser-based
   newline preservation.
6. **Blank quoted heredoc bodies in the third reading**, to reduce over-blocks. The
   over-blocks did not fall (35 → 36), and it was the change that caused alternative 2's
   loosening. Rejected.
7. **Copy the lexer into cmdword instead of moving it.** Three copies kept in step by
   comments. Rejected per "unify sibling gates".
8. **Accept either `_lex_bodies` run** (block only when both give up). It removes the
   over-block in Residuals, but when the plain run fails and the copy succeeds, the copy's
   reading may be the wrong one, and its bodies would stand in for an unreadable command.
   Rejected: ambiguity blocks.
9. **A from-scratch lexer in cmdword.** #1083 round 2 tried one over ten review
   iterations. It traded one over-block for the next, and one version took 11 s at 32k
   characters. Rejected.

## Residuals (stated, not fixed)

- **Heredoc over-blocks.** Corpus of 37,638 distinct commands, gate's verdict: 0
  block→allow flips, 45 allow → block (0.12%), every one a heredoc. Two kinds:
  - `python3 - <<'PY'` file-editing scripts, which do write files;
  - `gh pr create` / `gh issue comment` bodies in `<<'EOF'`, whose prose cmdword reads as
    shell, as it already does on `main` for the same shapes without the prose that hid
    them there.
  They block only while a design is pending.
- **marker_check over the hook budget on `main`** (see Performance). Separate issue.
- **marker_check's `#\<newline>`.** marker_check's own `_subst_bodies` still joins a
  continuation inside a comment, so `#\` + newline + heredoc can mislead its own scan.
  cmdword gets the comment-break copy (B); marker_check's reading is unchanged.
- **Process death in the classifier.** The shell's `|| echo "SAFE|"` and the outer
  `except` still allow; D covers only exceptions raised inside `is_file_mod`. Unchanged
  from `main`.
- **Derived strings.** At depth ≥ 1 a string the lexer cannot read keeps `main`'s reading,
  for the reasons in B.
- **`_lex_bodies` over-block.** When a `#…\` line sits inside a `$(` whose closer is on a
  later line, the plain run joins the comment and gives up, and B blocks even though the copy
  reads it. Example: `: $(` + newline + `# \` + newline + `echo hi)`, read-only. The copy's
  regex is quote-blind, so the same happens for `"$(echo` + newline + `# \` + newline +
  `x")`. No corpus command has the shape. Alternative 8 explains why this stays.
- **Programs built at run time.** A `#` or newline produced by `printf`, `echo -e` or a
  variable expansion is not seen, as on `main`.
- **An escaped backtick in a double-quoted program**, `bash -c "echo \`rm -rf src\`"`:
  bash passes ``echo `rm -rf src` `` to the inner shell, which runs it; cmdword keeps the
  backslash and reads a literal. This is missed on `main` and under this design; making it
  visible at the top level over-blocked read-only `grep` patterns (C). To be tracked as its
  own issue.
- **Fuzz coverage.** The fuzz generates from a fixed fragment set. The 0-miss result
  (38,412 writes over two seeds at 1,500 commands per form) is a design-time measurement.
  CI runs one fixed seed at 300 per form, about a fifth of one such seed, so a change that
  reopens a rarer combination inside the fragment set can stay green in CI; the full
  generator stays runnable locally (`fuzz-1085.py --full`). The fable review's 40 hand
  cases also passed. Shapes outside both sets are untested.
- **CR.** `_lex_bodies` reads CR as a newline, as `_normalize` already does, and bash does
  not. This can only add blocks.

## Tests

New suite `tests/test-cmdword-subst-comment-1085.sh`, using the bash-5 selection of
`tests/test-cmdword-case-backtick-1063.sh`.

**One oracle: the hook itself.** Rows run through the real `pre-implementation-gate.sh`
with a design pending, in a temporary repository, the way
`tests/test-gate-classifier-fail-closed.sh` already drives it, and assert its decision. The
fuzz is too large to start the hook per command, so its oracle is `is_file_mod` OR the
gate's redirect check, and that check is not copied: the fixture reads the block between
`# Check for shell redirects` and `is_mod = True` out of `pre-implementation-gate.sh`,
undoes the `'\''` shell escaping, and runs it. A missing or changed block fails the fixture.

**Reproducers.** Each row is first run under bash 5 in a scratch tree to prove the write
happens, then asserted to block. The rows:
- every shape in Problem, each with `rm -rf src` and with `echo x > src/f`;
- the fable review's eleven `main` misses;
- `<( )` and `>( )` bodies behind `${v%)}`;
- `bash -c 'echo $''{v%<<E #}; rm -rf src'`;
- `bash -c`, `sh -c` and `eval` programs with a comment followed by a newline;
- `bash -c`, `sh -c` and `eval` with `$'…'` programs using `\n` and a `#` written as `#`,
  `\x23`, `\043`, `#` and `\U00000023`, plus `\r\n`, a `\x72m` verb, and the same
  inside `"$( )"`;
- the same programs with the opener hidden: `bash -c "eval \$""'…'"` and
  `bash -c $\<newline>'…'`, and `bash -c "eval \$""'echo \$((1<<2))\n…'"`;
- `echo ${v:-$\<newline>{x#}<<E #}; rm -rf src`, `echo $\<newline>{v%<<E #}; rm -rf src`
  and `echo ${v\<newline>:-$\<newline>{x}<<E #}; rm -rf src`.

**Controls.** Read-only commands that use the same constructs, each asserted to allow:
- `echo ${v%)}`, `: "$(echo ${v%)})"`, `echo $'it\'s'`;
- `echo $(case ${v#x} i\<newline>n x) :;; esac)`;
- `echo hi # note`, `echo #\` + newline + `ls`, `git log --oneline # x\` + newline;
- `$((n+1))`, `echo $(echo a)#\` + newline + `b`;
- `echo 'a # b` + newline + `c'`, `bash -c 'echo "a # b` + newline + `c"'`;
- `echo $'\x23 not a comment'; ls`, `bash -c $'echo \x23 x\nls'`, `printf $'a\nb\x23c\n'`;
- `echo $\<newline>{HOME}`, `echo '$\<newline>'`, `echo ${v:-$\<newline>{x#}}; ls`,
  `bash -c "echo # x\<newline>ls"`, ``echo "\$HOME costs \`x\`"``;
- `git commit -m` with a `#` line in a multi-line message;
- a quoted heredoc without writes.

The over-block in Residuals gets a row asserting block, labelled as a stated over-block.

**Fuzz acceptance.** `tests/fixtures/fuzz-1085.py`, the generator behind the measurements,
with one fixed seed and 300 commands per form, over the 9 forms of Problem and
both write kinds. It runs bash 5 in a scratch tree and requires 0 commands where bash wrote
and the oracle allows. `--full` runs the design-time scale; CI does not (see Residuals).

**Timing ceiling.** The 68 adversarial inputs from Performance at 64k characters, each sent
to the real hook with a design pending: each must return a block decision within 4.0 s of
wall time. The 8 inputs where marker_check already exceeds 5 s on `main` are listed in the
test and skipped, pointing at the separate issue.

**Fail-closed**, added to `tests/test-gate-classifier-fail-closed.sh`, which copies the
whole gate tree:
- B7: `shell_lex.py` removed → the marker_check path blocks;
- B8: `is_file_mod` patched to raise → a benign Bash call with a design pending blocks.

**Updated:** `tests/test-escaped-dollar-1048.sh` compares ten helpers between cmdword and
marker_check through the AST. For `_ansi_c_span`, which moves, the marker_check side is
`shell_lex.py`. For `_requote_ansi_c`, the cmdword side is compared after the test removes
every branch guarded by `_lex_reading[0]` (keeping the unguarded path), so the second
reading's copy still has to match marker_check's exactly; a new row checks that the
guarded decoding exists and decodes `\n` and `\x23`. The other eight names are unchanged.

**Unchanged and passing:** every `tests/test-marker-*.sh`, `test-cmdword-*`,
`test-impl-gate-scope-*`, `test-ansic-quote-1043.sh`,
`test-gate-classifier-fail-closed.sh`, `test-gate-integrity.sh`, and the cmdword
self-check.

## Touch points

| File | Change |
|---|---|
| `hooks/gate-scripts/lib/shell_lex.py` | new: the moved lexer, plus `<( )`/`>( )` in `_subst_bodies` |
| `hooks/gate-scripts/lib/marker_check.py` | moved functions removed; `sys.path` insert from `__file__`; import; comments |
| `hooks/gate-scripts/lib/cmdword.py` | `import shell_lex`; `_lex_bodies`; B in `_is_file_mod`; the `_lex_reading` flag and the third reading in `is_file_mod`; C in `_normalize`, `_defuse_comments` and `_requote_ansi_c` (full `$'…'` decoding); comments |
| `hooks/gate-scripts/pre-implementation-gate.sh` | D: guard around the `is_file_mod` call |
| `.gate-integrity.lock` | regenerated |
| `tests/test-cmdword-subst-comment-1085.sh`, `tests/fixtures/fuzz-1085.py` | new |
| `tests/test-gate-classifier-fail-closed.sh` | B7, B8 |
| `tests/test-escaped-dollar-1048.sh` | compare with `shell_lex` |

## Decisions

| Decision | By | Why |
|---|---|---|
| Keep the #1063 over-read | operator | removing it loosens the gate; separate issue |
| Skip the grill | operator | design already measured and independently reviewed |
| Skip the ultra-oracle once | operator | adapter race #1086, not the design |
| Block when the lexer cannot read the command as written | agent, from the operator's "unreadable blocks" | depth 0 only; derived strings would block read-only commands |
| A separate third reading, not an extended second one | agent | the merged version was not additive (alternative 2) |
| Module name `shell_lex` | agent | reversible |
| Timing ceiling 4.0 s on the whole hook | agent | measured 2.63 s end to end; 5 s hook timeout; CI hardware slower than the measuring host |
| Either `_lex_bodies` run giving up blocks | agent | fail-closed on ambiguity; the over-block has no corpus occurrence (alternative 8) |

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
