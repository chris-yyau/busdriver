# ADR 0032 — A shell fed by a pipe: scan the producer, do not detect the flag

- **Status:** Accepted
- **Date:** 2026-08-03
- **Issue:** #557 (regression introduced by #519 / PR #548)
- **Relates:** ADR 0031 / #519 (token-level file-mod classification), ADR 0006 (command-text matching is not the security boundary; an unlisted launcher is a stated residual)

## Context

`printf 'rm -f src/impl.py' | bash` executed the write and neither the file-mod classifier
nor the helper guard blocked it. The pre-#519 raw regex did, so this was a **regression**,
not an inherited gap.

A shell given neither `-c` nor a script operand runs whatever stdin produced. Segment-wise
classification sees a verb in command position nowhere: the payload is quoted **data** in
the producer stage, and the consuming stage has no operand at all. The sibling `<<<`
spelling was closed in PR #548 by an operand branch that a pipe never reaches.

An earlier attempt was reverted after three review passes, each finding a new fail-open.
Every one of them was in the same place — a detector for *"is this shell reading stdin?"*,
which means deciding whether `-c` is present, which is an **option-arity table**:

| Attempt | Defeated by |
|---|---|
| any dash-token containing `c` | `bash --norc`, `bash --rcfile /dev/null` |
| short bundles only, stop at `--` | `bash --rcfile -c` — the `-c` is `--rcfile`'s value |

This module already refuses that table elsewhere (`watch`, `sed`, the `-c` candidate walk)
for exactly this reason: it fails **open** when wrong.

## Decision

**Do not ask which flag the shell was given. Ask what the pipeline is feeding it.**

When a pipeline stage *might be a shell*, hand the text of the stages feeding it to the
pre-#519 raw regexes (and, in the helper guard, to `_names_helper`).

Two properties carry the whole design:

- **The trigger is structural, not lexical.** `|` (and `|&`, not `||`) already says the
  stage is being fed; nothing about its options needs deciding. The remaining test — *might
  this be a shell?* — is deliberately wide and arity-free: a shell name anywhere in the
  stage counts, tokens are re-split on whitespace and peeled of an attached option value so
  `env -S'bash -s'` is seen, and an unresolvable command word (`| $SHELL`, `| /bin/[b]ash`)
  counts too. A false positive costs precision on one command; a false negative is a
  fail-open.
- **The scan is scoped to the producer, not to the whole command.** This is where the
  precision lives, and it was measured rather than argued (below).

One producer per pipeline, taken from the last candidate stage: every earlier candidate's
producer is a prefix of it, and building one per stage is O(stages²) bytes — the shape that
once put the `watch` scan near 218 MB inside a hook whose timeout reads as *allow*.

## Alternatives

Measured against **34,758 real Bash commands** extracted from local session transcripts,
counting commands that the current classifier allows and the candidate would block:

| Option | Over-blocks | Note |
|---|---|---|
| Issue option 1 — any shell name anywhere ⇒ raw-scan whole command | **2,693 (7.7%)** | Mostly `bash tests/foo.sh` beside an unrelated `git` |
| Raw-scan whole command, but only for a pipe-fed shell | 625 (1.8%) | Mostly `gh pr checks N \| bash "$RCS" "$(git rev-parse …)"` |
| Producer = the whole command PREFIX before the receiver | 559 (1.61%) *(see note)* | Closes grouping without any grouping rules, but a multi-line command drags every earlier line into the scan |
| **Chosen — producer scoped to the receiver's own pipeline** | **1,561 (4.49%)** | Almost all are gate self-tests piping `rm -rf` text into a gate script |
| Issue option 3 — accept the regression | 0 | Rejected: a regression is a weaker position than a documented pre-existing limit |

*Note on the 559 row:* that figure and the pipeline-scoped result it was measured against
(**43** at the time) are a **mid-development pair**, taken when the SCOPE decision was
made and before nineteen further rounds of widening. It is listed because the ratio
between the pair is what settled the scope, and it must NOT be read against the 1,561
below it — they share no baseline. Rows one, two and four were measured against the
same commit as each other — the **last measurable** one, see "The trajectory" below.

Against that last-measured implementation the whole-corpus diff is **1,561 newly blocked** and
**one** command newly allowed. Every earlier round held the diff at zero newly allowed, and
that is still the rule; the single exception is named rather than rounded away.

Bash ignores quoting inside a comment. Leaving quotes there let a comment change the quote
state of everything after it, which is two fail-opens: two balanced apostrophes wrap a real
`rm -rf src` in apparent quotes, and one unbalanced apostrophe (`# the caller's copy`) made a
whole command unparseable. Blanking them closes both. The cost is that six commands whose
only block came FROM that accidental unparseability now parse; asked of the real gate rather
than the classifier alone, **five still block** and one changes:
`cat > …/scratchpad/issue-parser.md <<'BODY'` — a scratchpad markdown write in an unrelated
repo, which the gate was never meant to stop and blocked only by accident. Two fail-opens
closed against one accidental block released is the trade, taken deliberately.

**Twenty-seven review rounds found sixty-seven fail-opens in the trigger, and every one was the same
mistake: an example-shaped test where a compositional one was needed.** All were verified
executing before being fixed.

| Shape | Why it slipped |
|---|---|
| `(printf 'rm -rf src') \| bash`, `{ printf …; } \| bash` | the segmenter splits on `(`, `)` and `;`, so the payload sat behind an apparent pipeline boundary |
| `printf … \| (bash)`, `printf … \| { :; bash; }` | same, on the receiver side — and the second survived a first fix that only special-cased a segment equal to `}` |
| `printf … \| csh`, `\| fish`, `\| /bin/[b]ash` | a literal seven-name list, and a glob the shell expands before a command word exists |
| `printf … \| env -S'bash -s'` | the option value is ATTACHED, so shlex returns one token whose first word is `-Sbash` |
| `printf 'echo x > src/impl.py' \| bash` | the verb regexes cannot see a redirect-only write |
| `(printf … \| bash)`, `{ printf … \| bash; }` | the fix for the row above suppressed *every* operator inside a group, including the pipe — so a pipeline written wholly inside one never fed |
| `echo { ; printf … \| bash` | a literal `{` argument raised the same depth |
| ``printf … \| `printf bash` `` | the unresolved-command-word test knew `$` but not the older backtick spelling |
| `printf … \|` ⏎ `bash`, and the same with a comment after the pipe | `_normalize` turns a newline into `;`, so an ordinary two-line pipeline arrived as a pipe feeding an empty stage, then a separator before the shell |
| `printf … \| if true; then bash; fi`, `\| for x in 1; do bash; done`, `if true; then printf …; fi \| bash` | a compound command is ONE pipeline stage however many separators sit inside it — braces were only the first spelling of that family, not the family |
| `if true; then if true; then printf …; fi; fi \| bash` | the leading-run walk stopped at `then`/`do`, so a NESTED opener went uncounted while its closer still closed |
| `case x in x) printf …;; esac \| bash` | a `case` pattern terminator is a bare `)` with no opener, and one shared counter let it cancel the keyword depth |
| `time if true; then printf …; fi \| bash`, `! if false; … \| bash` | bash allows `time`/`time -p`/`!` in front of a compound, and the walk stopped on them before reaching the opener |
| `printf … \| env -iS'bash -s'` | peeling ONE option letter off a bundle leaves `Sbash`; peeling a fixed number never terminates |
| `A=bash; printf … \| eval "$A"` | the receiver runs a shell without naming one — its command word is `eval` |
| `f(){ bash; }; printf … \| f` and `g(){ printf …; }; g \| bash` | a NAME can stand for either end of the transport, and the definition sits in a different pipeline from the use |
| `printf … \| yash` | the shell list is an enumeration, and this one was missing |
| `function f { bash; }; printf … \| f` | the keyword form defines a function with no `()`, so the definition pattern missed it |
| `ev"al" …` | the shell concatenates adjacent quoted runs, so the raw text holds no contiguous `eval` |
| `function f-x { bash; }; …`, `f-x() { bash; }; …` | both definition patterns spelled the NAME as a C identifier; bash runs `f-x`, `f.x` and `my:fn` |
| `function fz while false; do bash; done; …` | a function BODY is any compound command, so requiring a `{` after the name missed the loop, `if` and `[[ ]]` forms |
| `A=bash; printf … \| env -S"$A"` (gate copy only) | the receiver hands an OPERAND to execvp, so peeling options returned nothing and the command word never named a shell |
| `printf … <&0 \| bash` | `>&` was joined to its redirect and `<&` was not, so the splitter cut mid-redirect and the producer became the bare `0` |
| `if function f { bash; }; then printf … \| f; fi`, and the same behind `while`, `until`, `time -p`, `!` | the command-position anchor listed `then`/`do`/`else` but not the reserved words that open a compound — a hand-listed subset of a set the depth walk already enumerated |
| `if true; then f(){ bash; }; printf … \| f; fi`, `{ f(){ bash; }; … }`, `( f(){ bash; }; … )` | the `name()` form kept its separators-only anchor when the keyword form gained command position — the same gap, one spelling later |
| `printf 'python3 …/lease_slo?.py' \| bash` (gate copy only) | the piped-producer probe used the plain name test while its siblings used the glob-aware one |
| `printf … \| # ; ignored` ⏎ `bash` | a comment runs to end of LINE and may contain `;`; `_normalize` rewrites the newline to `;` afterwards, so the comment split into a comment segment plus a bare word that read as a real command |
| `hash -p /bin/bash f; printf … \| f` | bash's `hash -p` binds a name to a path for the rest of the shell — the same re-pointing `alias` does, and simply absent from the set |
| `true` ⏎ `f(){ bash; }` ⏎ `printf … \| f` | the `name()` anchor took `;` but not a NEWLINE, though `_normalize` treats the two as the same separator everywhere else |
| `command -- hash -p …`, `command -p hash -p …` | `command` and `builtin` take their own options before the builtin they run |
| `alias 1x=bash; printf … \| 1x` (gate copy only) | the alias branch required an identifier, but a bash alias name is not one |
| `case x in x) f(){ bash; };; esac; printf … \| f` | a case PATTERN ends with a bare `)`, which puts the next word in command position — the same family as the reserved words one round earlier |
| `# '` ⏎ `rm -rf src` ⏎ `# '` | bash ignores quoting inside a comment; the defuser kept quotes, so two balanced ones wrapped the write in apparent quotes |
| `hash -rp/bin/bash f; printf … \| f` | `hash` takes BUNDLED options with an ATTACHED operand, so testing for a bare `-p` token missed it |
| a 60KB pipeline of `env` receivers | the per-stage operand walk ran before the token budget was charged, at ~3.8s against a 5s hook timeout — and a timed-out hook writes no decision, which the harness reads as ALLOW |
| `BASH_CMDS[f]=/bin/bash; printf … \| f` | bash exposes its hash table as a WRITABLE array, so a name is re-pointed without naming the builtin |
| 4,000 stacked `!` prefixes | the command-position prefix carried a repeated group that went quadratic — 5.4s against the same 5s timeout |
| `printf … \| echo "$(bash)"` | a command substitution in an argument inherits the pipeline stdin, so the shell it resolves to runs the payload |
| `printf … \| python3` | `python3`, `perl`, `ruby` and `node` run a program read from stdin exactly as a shell does; the list held only shells |
| `echo $(true)#x; rm -rf src` | `)` was treated as word position, so a `#` closing a substitution read as a comment and the real separator after it was blanked |
| `echo foo\ #notcomment; rm -rf src` | an ESCAPED space read as a delimiter, so the `#` after it opened a comment that swallowed the separator |
| `printf … \<\|bash` | an ESCAPED `<` read as a redirect, so the `\|` after it was glued to the segment and the pipeline disappeared |
| `(true)# '` ⏎ `rm -rf src` ⏎ `(true)# '` | the fix for the row above swung the other way: `)` closing a SUBSHELL does delimit, so the `#` after it really is a comment |
| `printf 'exec rm -rf src' \| tclsh` | one more interpreter that runs a program read from stdin |
| `f()# '` ⏎ `{ rm -rf src }` ⏎ `# '` and `case x in x)# …` | the paren-context fix from the round before covered subshells and substitutions but not function headers or case patterns — the THIRD swing on the same question |
| `printf 'BEGIN { system("rm -rf src") }' \| awk -f -` | `awk -f -` runs a program read from stdin; the interpreter list did not carry it |
| `printf '.shell rm -rf src' \| sqlite3` | sqlite3 reads dot-commands from stdin and `.shell` runs one — the enumeration again |
| `printf … \| source /dev/stdin`, `\| . /dev/stdin`, `\| xargs` | three more receivers that run what they read; `.` is matched in COMMAND POSITION only, because a bare `.` is an ordinary argument and matching it as a name cost 100 over-blocks |
| `printf … &>/dev/stdout \| bash` (gate copy only) | `&>` redirects both streams, so the `&` belongs to the redirect — read as a control operator it cut the segment and discarded the real producer |
| `printf … \| /bin/ba+(s)h` | EXTGLOB changes the grammar: `+(s)` is a pathname pattern, so the parens are not a group and the receiver expands to `/bin/bash`. `!( )` is a NEGATION and is unresolvable, so it fails closed rather than resolving to its inner text |
| `printf 'all: rm -rf src' \| make -f -` | `make -f -` runs a Makefile read from stdin |
| `printf … \| /bin/ba@(s\|z)h` | the extglob fix kept the parens but still split on the `\|` INSIDE the pattern, and resolving an alternation to its inner text picks one spelling — `bas\|zh`, the harmless-looking one |
| `FOO=x hash -p /bin/bash f; printf … \| f` | an assignment prefix is still command position |
| a 59KB command padded with `if hash x` | the `hash` branch backtracked catastrophically — 7.2s against the same 5s timeout. The REGEX was the fail-open |
| `A+=x hash -p …`, `</dev/null hash -p …`, 21 assignments | the prefix grammar again, twice more — closed for good by DELETING the grammar, which measured zero further cost |
| `printf … \| /bin/ba@(+(s))h` | NESTED extglob: one substitution pass does not reach it, and iterating is a slower guess |

The fixes are each the general form rather than the reported spelling: a tracked **group
depth** (braces counted as whole words, so `${VAR}` is not a group) instead of a `}` special
case; a **`_STDIN_SHELLS` superset** plus an unresolved-command-word test covering `$`, a backtick, and the glob characters;
positional state -- word position, redirect position -- tracked EXPLICITLY rather than
inferred from the previously emitted character, which cannot say whether that character was
escaped or quoted; a **general option-value peel** rather than an env-specific one; comment separators
**blanked in place** rather than the comment deleted; a splitter keyed on the
**redirect character** rather than on a list of redirect operators; a command-position anchor
**derived from the compound-keyword sets** rather than hand-listed, so adding a keyword
extends both; and **both halves of the verdict** — verbs *and* redirects — applied to the
producer, exactly as the depth cap above already had to learn.

Each widening rule was measured by disabling it, rather than argued. Against the **last
measurable** code and the same 34,758-command corpus: **1,561** total, of which the indirection rule
accounts for **909**, group depth for **112**, and the newline/comment rule for **25**. Those
do not sum to the total and are not meant to — a command caught by two rules is counted by
each in isolation and once in the total. Every figure in this paragraph comes from one
measurement run against the commit this ADR ships with; the per-round totals in the
trajectory table below are historical and must not be cited as the result.

(Earlier drafts of this ADR quoted 39, 43, 52, 106, 166, 172, 173, 258, 280, 317, 407 and 872 — each was the
true total for the code as it stood at that round, and each is superseded. Only the figures
in this paragraph should be cited; they all come from one run against one commit.)

Two narrowings were tried inside the widening rules and dropped. `source` in the indirection
set cost **162** alone and does not close the family it belongs to, since a function can
equally arrive from `~/.bashrc` or an exported environment function. Matching the `function`
keyword *anywhere* rather than only in command position cost **95** extra (`grep function
file | …`), so the branch is anchored to command position — a structural restriction, not a
guess about the function body. Giving the `name()` form that *same* full anchor cost **1,105
against 872 at the round it was measured** — a definition cannot follow a group CLOSER or a
pipeline prefix (`} f(){`, `! f(){`), so openers, the case-pattern terminator and reserved
words alone close every reachable spelling. Counting compound keywords *anywhere* in a
segment rather than only in its leading run cost **1,161 against 1,105 at its round**,
because `if`, `for` and `done` are ordinary words in ordinary commands; command-position
counting is what keeps `grep -n done log` allowed.

Those two comparisons are **paired historical measurements**: each was taken against the
code as it stood at that round, and only the ratio between the pair is meaningful. The
last measured total is the 1,561 above — **58% of issue option 1's 2,693**, which is the only
comparison that should be quoted. Two rules landed after it with the corpus already gone,
so the SHIPPED total is unmeasured and no figure in this ADR describes it — see "The
trajectory".

**Two characters in the `name()` anchor accounted for 698 of the 1,105 total at round 14.**
The NEWLINE cost **465** and the case-pattern `)` cost **233**, both measured then. It is kept because the shape it closes — a helper function defined on its own
line in a multi-line command — is completely ordinary rather than exotic, and because
`_normalize` already treats a newline and a `;` as the same separator everywhere else, so
excluding it here was an inconsistency rather than a decision. The cost is real: the
over-blocks are largely multi-line probe scripts that define a `run()` helper, and the
indirection rule answers them by raw-scanning the WHOLE command, which reinstates the
pre-#519 false positives for that command. A narrower rule is available and NOT taken here —
trigger the whole-command scan only when a pipeline stage resolves to a name this command
actually binds, rather than on any indirection anywhere plus any pipe. That is a new
mechanism rather than a fix, so it is left as follow-up work with this measurement attached.

`_STDIN_SHELLS` is kept separate from `_SHELLS` on purpose: `_SHELLS` asserts that `-c`
means execute-this-string, a claim this module acts on by *recursing into the operand*, and
csh/fish do not need to inherit that.

## Consequences

- The pre-#519 decision is restored for the payload that a pipe carries into a shell.
  For the ordinary shape — a pipeline whose receiver may be a shell — the scan is confined
  to that pipeline's producer, so #519's quoted-operand false positives are not reacquired
  across the rest of the command.
- **But the indirection rule is an exception, and it is the expensive one.** A command that
  BOTH introduces indirection (a function or alias definition, `hash -p`, `BASH_CMDS`,
  `eval`) AND contains a pipe is raw-scanned WHOLE, which does reinstate the #519 false
  positives for that command. It accounts for **909** of the 1,561 over-blocks. The
  narrowing is described under "The precision trajectory" and is deliberately not built
  here.
- `_split_simple_commands` now delegates to `_split_with_ops`, which records the operator
  run before each segment. Both copies (`cmdword.py`, `pre-implementation-gate.sh`) must
  stay in step, as their splitters already had to.
- **Residual, stated not chased** — the shell list is an ENUMERATION, so a shell nobody has
  listed reads as a non-shell, and a function defined OUTSIDE the command (sourced, `~/.bashrc`,
  an exported environment function) is invisible to any reading of the command text. Same call
  as ADR 0006. Adding a shell name is free, so add rather than argue when one is found.
- **Residuals, inherited rather than introduced** — the raw scan never saw a verb the
  producer assembles from separate operands (`printf '%s%s' r 'm -rf src' | bash`), and
  `bash < payload.sh` carries no producer text at all, which the pre-#519 regex could not
  read either. Recovering those needs an interpreter, not a tokenizer. Same call as
  ADR 0006: containment is that a launcher only helps an actor who already has Bash, and
  every gated write still needs a lease that is logged.

- A generated matrix (producer spelling × grouping × receiver spelling, 2,187 combinations)
  asserts the verdict survives composition in both directions — the grouped and expanded
  spellings were found by review rather than by the hand-picked examples, which is exactly
  what a product test is for.
- Two **seeded property checks** quantify over a grammar rather than a list, because every
  regression here was a composition nobody had enumerated: the splitter must be lossless
  (operator runs plus segments concatenate back to the normalized input) over 3,000 random
  compositions, and a stated write piped to a shell must block over 3,000 more. The seed is
  fixed, so a failure reproduces exactly. The second property was run against the
  pre-change classifier as a negative control and failed **2,604 of 3,000** there against
  **0 of 3,000** after — a property that cannot fail certifies nothing.

### One fix moved the needle the wrong way

Deleting comments outright — the obvious reading of the comment defect — moved **14 real
commands from block to ALLOW**. A comment holding an apostrophe (`# the caller's copy`) had
been making the whole command unparseable, and unparseable is the fail-CLOSED path; removing
the comment removed the apostrophe, the command parsed, and the gate honestly allowed it.

That is worth recording as a rule rather than an anecdote: **a change to a fail-closed
classifier may only ever ADD blocks**, and the corpus diff is what proves it, since none of
those 14 appeared in any test. Blanking `;&|()` inside the comment in place — keeping every
quote, every byte, every scannable word — closes the defect with the same measured cost and
zero newly allowed.

### A slow guard is an open guard

Two of the fail-opens above were not parse defects at all: the per-stage operand walk ran
before the token budget was charged, once in each copy. A 64KB command of repeated receivers
took **5.4s** in the gate and **3.8s** in the classifier, against a **5s** hook timeout — and
a hook that times out writes no decision, which the harness reads as **allow**. Charging the
existing budget before the walk brings both to **0.03–0.13s** and makes exhaustion fail
CLOSED. Worth stating plainly because it does not look like a security bug in review: the
logic was correct, and correct-but-too-slow is indistinguishable from wrong at the boundary.

### Deleting a rule closed more than writing one

The `hash -p` detector was anchored on command position, which meant modelling every prefix
bash allows in front of a builtin. Three consecutive rounds each closed one and left the
next: `builtin`/`command`, then `command --` and `command -p`, then `FOO=x`, then `A+=x`,
then a leading redirection, then more than twenty assignments.

The anchor was then **removed** rather than extended — a `hash` carrying a `-p` is the
signal wherever it sits — and measured against the same corpus it cost **zero** further
over-blocks. The prefix grammar had been buying bypasses and nothing else.

Worth stating as a rule: when a guard is anchored on a grammar the guarded party controls,
check what the anchor is actually buying before extending it. Here the answer was nothing,
and four rounds of review went into refining it.

### When refinement is the wrong tool

Three consecutive rounds landed on the same question — does a `)` before a `#` delimit a
command? — and each fix closed one spelling while opening another: substitutions, then
subshells, then function headers and case patterns. Bash has four answers and the text does
not always say which applies.

The fourth round did not add a fourth heuristic. `)#` is now reported as **unresolved**, and
the caller answers it the way it already answers an unparseable command: the raw
whole-command scan, best-effort. That scan performs the raw regex/redirect probe over the
command text and blocks when it finds a matching write verb or redirect — it does not
unconditionally block regardless of what the probe finds, so a command that is ambiguous AND
carries no raw write signal still allows. One command in the 34,758-command corpus contains
the shape at all, so refusing to guess costs nothing measurable — and it ends a thread that
three rounds of refinement had not.

A parser that cannot decide should say so. Guessing is what turns an ambiguity into a
bypass, and each of those three rounds was that guess being wrong in a new place.

### The precision trajectory, and what it costs

| After round | Over-blocks | What was bought |
|---|---|---|
| 8 | 280 (0.81%) | the grouping, shell-list and redirect families |
| 9 | 317 (0.91%) | non-identifier function names, brace-less bodies |
| 11 | 407 (1.17%) | `name()` in command position, glob-named piped helpers |
| 13 | 872 (2.51%) | a definition on its own LINE — 465 of the rise, alone |
| 14 | 1,105 (3.18%) | a definition after a case pattern — 233 of the rise, alone |
| 17 | 1,202 (3.46%) | `BASH_CMDS`, substitution receivers, and the stdin-reading interpreters — 95 of the rise is the interpreter list |
| 21 | 1,345 (3.87%) | `awk -f -` and the rest of the interpreter list — 143, almost all of it `\| awk` in ordinary pipelines |
| 22 | 1,349 (3.88%) | `sqlite3` and equivalent stdin-command readers — 4 |
| 23 | 1,413 (4.07%) | `source`, `.` and `xargs` as receivers — 64 |
| 25 | 1,439 (4.14%) | extglob receivers, `make`, and the unresolvable pattern forms — 26 |
| 27 | 1,440 (4.14%) | the `hash` prefix grammar deleted, nested extglob unresolved — 1 |
| pre-PR | 1,561 (4.49%) | wrapper-option receiver (0); `hash` option search deleted (69); substitution bodies given the full receiver test (52) |
| post-PR | **unmeasured** | no-command shell LAUNCHERS (`script`, `su`, `runuser`, `chroot`, `unshare`, `nsenter`, `newgrp`, `sg`) in command position |
| post-PR | **unmeasured** | the command-position walk in front of them: prefixes, assignments, redirections, compound stages, and an unknown-arity option marking the stage unresolved |

Finding the launcher meant finding COMMAND POSITION, and several review rounds each found a
spelling the walk stopped short of: an assignment or keyword prefix (`FOO=1 unshare`,
`time script`), a leading redirection (`2>/dev/null unshare` — the fd number lexes apart
from its operator, so both halves have to be stepped over), and a compound stage
(`| { unshare; }`, `| if unshare; then :; fi`), which passes its stdin to the command
inside it. Reserved words restore command position in command position ONLY, the same
restriction the `name()` anchor above is built on, so `| grep for script` is untouched.

The fourth round found the arity question wearing a new hat. Stepping over an option to
reach the launcher behind it (`time -p unshare`) is only sound when the option takes no
value — `/usr/bin/time -o timing.out unshare` reads `timing.out` as the command word and
fails OPEN, which is precisely the failure mode this ADR refuses to build a table against.
So an option in command position marks the stage **unresolved** and the whole stage is
asked instead, the same arity-free move already made for wrappers. Its known cost is an
English-word over-block: `| /usr/bin/time -o t.out grep -c su` blocks. `-p` is exempt
because it is already modelled as `time`'s grouping connector, which keeps the common
`| time -p <cmd>` shape precise.

The same question came back a third time as **sudo and doas shell modes** — `sudo -s`,
`sudo -i`, `sudo --shell`, and every abbreviation `getopt_long` accepts. These are
wrappers, not launchers, until a flag turns them into one, and proving there is no command
operand needs the arity table again. Three successive attempts to scope the search to the
wrapper's own option run each lost to a spelling that hid the flag behind an operand
(`sudo -u root -s`, `sudo --user root --shell`, `sudo -B -s`), so the search is now over
the WHOLE stage — the regime a wrapper already selects everywhere else in this module,
carrying the price that regime has always carried: a word in the wrapped command's data
reads as the flag, so `| sudo grep -i needle` blocks exactly as `sudo grep rm notes.txt`
already did. A short-option BUNDLE is read left to right and stops at the first flag that
takes a value, so `-su root` counts and `-ualice` does not.

**PERFORMANCE was a security finding twice in this family**, both times in a scan that
restarted inside a payload it had already collected: operands that merely spell `-exec`
made the `find` walk quadratic (1,400 of them measured 6.04s in the classifier; 1,900
measured 11.0s in the gate's helper guard). The hook's timeout is 5s and a timed-out hook
writes NO decision, which the harness reads as ALLOW — so an over-long scan is a bypass,
not a slowdown. Both walks are index-controlled now and both shapes are pinned by tests,
one of them with an explicit wall-clock assertion.

Two over-blocks are left DELIBERATELY, pinned by tests so that changing either is a
decision rather than a drift:

- A launcher given an explicit program (`| unshare -- grep rm`) runs that program, and the
  pipe is data. Proving there IS one puts the command in a different place per launcher
  (`unshare -- CMD`, `chroot -- NEWROOT CMD`, `script -c CMD`) — the arity table again.
- A brace group behind a wrapper (`| { env true; grep x; }`) is read as unresolved,
  because `{` is a brace-expansion character in the glob set. This one predates the
  launcher work and is a property of the wrapper-glob rule above, not of this family.

**1,561 is the last measured total, NOT the shipped one.** The launcher rule landed during
the post-PR grind, after the extracted 34,758-command corpus this table is built on was no
longer available, so its cost was never quantified. It is scoped to command position
precisely to keep that unmeasured cost small — these are ordinary English words, and the
any-word test the rest of `_STDIN_SHELLS` uses would have flipped `grep script` to a block —
but "small" here is an argument, not a measurement. Every other figure in this document is
a measurement; this one is not, and the difference is deliberate rather than glossed. Re-run
the extraction before quoting a shipped total.

Every step closed a fail-open that was **verified executing**, and only one step ever moved
a command from block to allow (named above). But the cost is now five times what the design
was argued on, and the majority of it lands in ONE rule: the indirection trigger raw-scans
the WHOLE command whenever the text contains any indirection AND any pipe, which reinstates
the pre-#519 false positives for that command. It accounts for **909 of the 1,561**, or
58.2% — a majority, not all of it.

The narrowing is known and NOT built here: trigger the whole-command scan only when a
pipeline stage resolves to a name this command actually **binds** — collect the names from
the `name()`, `function`, `alias` and `hash -p` forms already parsed, and compare them
against the stage command words. `eval` keeps the broad behaviour, since it binds no name.
That is a new mechanism rather than a fix to an existing one, so it is follow-up work with
this measurement attached rather than a twenty-ninth round of the same review.

## Closed during the pre-PR review

The deep pre-PR pass reported the one gap this ADR had recorded as open:

    printf 'rm -rf src' | env -u X /bin/[b]ash

`_effective_command_word` peels the wrapper and lands on `X` — the operand of `-u` — so the
globbed receiver behind it was never tested. The note said the general fix (test every stage
word, not only the command word) needed its own measurement first. It got one: asking it of
**every** stage costs **8.63%**, worse than the 7.7% option the issue rejected. Scoped to
stages whose first word is a **wrapper** — where the real program is by definition among the
operands — it costs **zero**: 1,440 either way at the round it was measured.

So it is closed rather than carried, and the shape is pinned in the suite alongside an
`allow` for a glob in an ordinary argument (`grep -- *.py`), which is what the scoping buys.

### Two deliberate over-blocks, pinned rather than chased

Both are in the SAFE direction, and closing either needs state whose failure mode is a
fail-open — which is the trade this whole change refuses to make.

| Shape | Why it over-blocks | Why it stays |
|---|---|---|
| `cat eval</dev/null <helper>` | the gate's indirection layer sees text, not a parsed command word, so an `eval` that is an ARGUMENT followed by a redirect matches | telling them apart needs the command word, a different layer |
| `case foo in 'rm -rf src'\|bash) :;; esac` | inside a `case`, `\|` separates pattern ALTERNATIVES, not pipeline stages | closing it needs case-pattern state, and getting that wrong turns a real pipe into an inert pattern |

The second is narrow by construction: it needs a pattern that both contains a write verb
and names a shell in an alternative, so `case x in a|b)` and `case $x in *.py|*.sh)` are
untouched — both verified and asserted. (`case $x in *.py|*.sh)` IS blocked, but by the
unconditional helper guard, because `*.py` can expand to a protected helper — nothing to do
with the pipe. Asserted separately so the two reasons are not conflated.)

## Where this stops

Rounds 7 and 8 crossed from *"the segmenter mis-parses shell grammar"* — closable, and
closed — into *"a name or a payload is assembled somewhere the command text does not show"*.
That second family does not close, and the issue says so itself of
`printf '%s%s' r 'm -rf src' | bash`. Two candidate rules were written **and measured**
before being declined:

| Declined rule | Closes | Cost | Why declined |
|---|---|---|---|
| producer expands a variable this command assigns | `P='rm -rf src'; printf '%s' "$P" \| bash` | **386** over-blocks (1.1%) | leaves the split-operand spelling — and every other runtime assembly — open |
| `source` in the indirection set | a function defined in a sourced file | **162** over-blocks | leaves `~/.bashrc` and exported environment functions open |

A third was written and then **reverted during the post-PR grind**, and it is worth recording
why, because it is the clearest example of the rule this ADR keeps re-deriving. The
paren-balance check that catches `$(case x in x) $SHELL;; esac)` is quote-blind, so an inert
`(` re-balances it: `$(case x in x) echo "("; . /dev/stdin;; esac)` is **not** caught. The
obvious repair — trip on the `case`/`esac` reserved word, which a case construct can never
omit — *does not work*, and only running it showed that: segments are split on `;` before the
producer scan sees them, so `esac` lands in a different segment than the `$(` and the tripwire
never fires on the very shape it was written for. Matching `\bcase\b` instead would have fired
on the English word (`echo "$(date) fixed an edge case"`), and by then the 34,758-command
corpus this ADR is measured against was no longer available, so that cost could not be
quantified. An unmeasured rule that does not work is worse than a recorded residual, so the
balance check stays (it costs zero measured over-blocks and does close the unquoted spelling)
and the quoted one joins the list below.

These are stated as residuals instead, and the first two are asserted as *allow* in the test
suite so the choice stays deliberate rather than being rediscovered as a bug. The line drawn is:
**close what the command text reveals; document what only an interpreter could recover.**
That is the same call ADR 0006 made, and the containment is unchanged — an unlisted shell or
an assembled name only helps an actor who already holds Bash, and every gated write still
needs a lease that is logged.

## Addendum — #563: the revisit trigger fired twice

Both were found by the chatgpt-codex-connector on PR #562, deferred as `follow-up-deferred`
because the two functions they touch are the most heavily measured in the module, and both
were **verified executing against real bash** before being fixed. Each is the *structural*
half failing, exactly as the trigger below anticipated — neither is an arity question, and
neither reopens the flag one.

**1. Control operators inside a backtick substitution read as outer pipeline separators.**
`printf 'rm -rf src' | echo `true && bash`` runs the nested `bash` on the pipeline's stdin,
but `_split_with_ops` tracked single quotes, double quotes and escapes and *not* backtick
spans — so that `&&` ended the pipeline one stage before the receiver and the producer was
discarded. Fixed as STATE, the same shape as the two quote states beside it, rather than as
a rule about `&&`. Making the span opaque to the splitter removes no block: the body is
still extracted and classified by `_command_substitutions`, which runs first. An unterminated
backtick now joins the unterminated quote and the dangling escape in setting `ok = False`, so
the caller falls back to the wider raw scan.

**2. A shell fed by a PROCESS SUBSTITUTION was never handed a producer.** The trigger is
`|`/`|&`, so `bash < <(printf 'rm -rf src')`, its script-operand spelling
`bash <(printf 'rm -rf src')`, and the reverse direction `printf 'rm -rf src' > >(bash)` all
executed the removal while `is_file_mod` answered False. `_procsub_producers` routes them to
the *same* producer loop the pipe path feeds — both halves of the verdict, verbs and
redirects — and splits by direction, because the two ends swap: `<(BODY)` makes BODY the
producer, `>(BODY)` makes the outer command the producer. Nothing new models the language;
the receiver question is the one `_may_read_program_from_stdin` already answers. Quoted
regions are skipped, both kinds, unlike the `$(...)` sibling: process substitution does not
happen inside double quotes (`echo "<(rm -rf q)"` removes nothing — verified).

The first cut of both fixes was reviewed and two defects came back, each worth recording
because each is a rule this ADR already states, missed on the NEW transport:

- **The indirection widening was keyed on a literal `|`.** A substitution has no pipe, so
  `f(){ printf 'rm -rf src'; }; bash < <(f)` and `f(){ bash; }; printf 'rm -rf src' > >(f)`
  both ran while `is_file_mod` answered False — although their pipe twin
  `f(){ printf …; }; f | bash` had blocked through that very rule since #557. The trigger
  now fires on a pipe **or** a process substitution. Adding a transport means asking every
  rule keyed on the old one whether it meant the pipe or the feeding.
- **The candidate walk was charged against `_scan_budget`, which the per-segment walk then
  charges again** — silently halving the documented 4,000-token limit for any command
  holding a `<(`, and flipping a benign 2,004-token
  `grep -f <(echo pat) file0.txt … file1999.txt` from allow to block for a walk that emitted
  no producer at all. It has its own allowance now; exhaustion takes the whole-command scan,
  the same best-effort exit an unreadable command already takes.

A third came back from the pre-commit pass, and it is the *same* mistake one layer in: the
new backtick branch was ordered AFTER the double-quote one, so it was unreachable from a
quoted context. Bash opens a substitution on a backtick inside double quotes, and the quotes
inside the body belong to the body's own command — so
`printf 'rm -rf src' | echo "`echo "x && cat"; bash`"` had its body's second `"` read as the
outer string's CLOSE, the `&&` behind it split the stage, and the producer was discarded
exactly as before the fix. Verified executing. The inner span is checked first now, and
`in_d` is deliberately left set while it is open, so closing the span returns to the string
with no saved state to restore. Three rounds, three orderings — this is the module's own
lesson about positional state, arriving once more: **track the state explicitly; do not infer
it from the branch you happen to be in.** *A slow guard is an open
  guard* has a twin: a guard that spends someone else's budget is an over-blocking one.

**Cost: UNMEASURED, like the launcher rule above it.** The 34,758-command corpus was already
gone. Two over-blocks are known and pinned as *block* in the suite so changing either is a
decision rather than a drift:

- A shell named ANYWHERE in a command puts every `<(...)` body under the raw scan
  (`sh -c ':' <(printf 'rm -rf src')`). The splitter breaks on `(`, so a substitution
  arrives already torn off its own stage, and binding the two back together needs positional
  bookkeeping the splitter does not keep. Scoped by rarity instead: the candidate walk runs
  only once a process substitution is present, so an ordinary command pays nothing.
- `>(...)` takes the whole command as its producer, the same trade the indirection rule
  already makes and for the same reason.

`marker_check._split_with_ops` carries the backtick fix too — the same defect was verified in
that copy (`printf '<helper>' | echo `true && bash`` classified `OK`), and the two are
documented as kept in step. Its producer scan needed no process-substitution change: the
shapes already reach `_abandoned_scan_probe` by another path, checked rather than assumed.

## Revisit trigger

A fail-open found in the *structural* half — a transport that feeds a shell its program
without an unquoted `|` in front of it (a heredoc body, a `<` from a file, a coprocess).
Those are payload-transport problems, not arity problems, and each should be closed on its
own terms rather than by reopening the flag question. It has since fired once, on a
transport the enumeration did not name: **process substitution**, closed in the addendum
above. The three transports actually enumerated here are all still open — a heredoc body,
`<` from a plain FILE (unrecoverable from the command text, as the residual list states),
and a coprocess (`coproc printf 'rm -rf src'` then `bash <&${COPROC[0]}` classifies False,
verified). The backtick item in the addendum is not a transport at all: it is a splitter
defect that discarded the producer of a pipe that was already recognised.
