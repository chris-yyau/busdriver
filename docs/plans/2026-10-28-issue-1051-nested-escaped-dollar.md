# Gate classifiers: an outer quote's `$` is the inner program's text (#1051)

> **For agentic workers:** small change, kept in step in `hooks/gate-scripts/lib/marker_check.py` and `hooks/gate-scripts/lib/cmdword.py`:
> - the keep condition and one respelling in `_requote_ansi_c`;
> - a new `_bash_quoted` pre-pass;
> - a wider `_ansi_c_differs` trigger.
>
> `_ansi_c_span` in `marker_check.py` also changes its spelling from `chr(39)` to `_SQ`. This matches the cmdword copy, so the parity test can compare the two.
>
> Plus docstrings, rows in `tests/test-escaped-dollar-1048.sh`, and a regenerated `.gate-integrity.lock`. Execute inline; no subagent fan-out.
>
> **Revised after implementation (2026-10-29).** Code review of the first implementation of D1 found four misreadings. Fuzzing then found that the trigger never fired for a double-quoted program. Design review then found more, among them an over-block and a split of the trigger. D1 and D1b below are the shipped design; *Review history* records each finding.

**Goal:** #1048's shape and #1043's shape no longer fail open when they sit inside a program handed to another shell (`bash -c '…'`, `bash -c "…"`, `sh -c '…'`, `dash -c '…'`, `bash <<< '…'`, nested `-c`). This holds in both gates: the helper guard (`marker_check.py`) and the design gate (`cmdword.is_file_mod`). For this `$`-before-a-quote class, the invariant is that a quoted program is classified as its own text would be at top level. The Consequences section names the nested shapes that do not hold to it.

**Scope:** `_requote_ansi_c`, `_bash_quoted` and `_ansi_c_differs` in both modules, the docstrings and comments that describe them, and the test rows. Out of scope:
- the first reading (the blind `$'`/`$"` → quote strip);
- `_exec_payloads` and the recursion, including its depth cap;
- any budget or timeout;
- every other quote walker.

Closes #1051.

---

## Evidence (measured on `54d6d0f7`, classifiers called directly as the tests do; every "runs" was executed under bash 5.2.21 in a scratch tree)

`H` is the helper path; `src/` is a scratch directory. "TOP" is the program alone, and the other columns wrap it with `shlex.quote`.

| Program | runs under bash -c | main TOP | main `bash -c` / `sh -c` / `dash -c` / `bash <<<` | candidate, all four |
|---|---|---|---|---|
| `echo "\$"; python3 H; echo "\$"` | yes | BLOCK | OK / OK / OK / BLOCK | BLOCK |
| `echo $'it\'s'; python3 H; echo '\$'` | yes (bash only) | BLOCK | OK / OK / OK / BLOCK | BLOCK |
| `echo "\$"; rm -rf src; echo "\$"` (cmdword) | yes | True | False / False / False / False | True |
| `echo $'it\'s'; rm -rf src; echo '\$'` (cmdword) | yes (bash only) | True | False ×4 | True |

Rows 2 and 4 are new: they are #1043's shape nested, a fail-open on main that the issue did not name. Only the wrappers that run the program under bash count as closed fail-opens: `bash -c`, and `sh -c` where sh is bash, in both gates, and `bash <<<` in cmdword only (marker_check already blocked it on main). Dash rejects #1043's program, so under `dash -c`, and `sh -c` where sh is dash, the BLOCK is an inherited refusal (the first of D2's named shapes).

**Why.** The second reading (#1043, widened by #1048) respells `$'…'` and `$"` OUTSIDE quotes. Inside a quoted span it drops the `$` before a quote, exactly as the first reading's blind strip does. To the outer shell that `$` is a literal byte of the quoted text. When the text is a program for another shell, it is that program's syntax:
- `"\$"` loses its `$` and becomes `"\"`, which runs the string on past the payload (#1048);
- `$'it\'s'` loses the opener that makes its `\'` data (#1043).

`_exec_payloads` re-enters the program at `_depth + 1`, but by then the bytes are already gone.

## Decisions

**D1. The second reading keeps a `$` where bash and the flat walk read the same kind of quote.** In both `_requote_ansi_c` copies:

```
bq = _bash_quoted(s) if "$" in s else ()
...
if ch == "$" and s[i + 1:i + 2] in (_SQ, _DQ) and not (q and bq[i] == q):
    j = (_ansi_c_span(s, i) if not q and s[i + 1] == _SQ and not _dollar_run_is_even(s, i + 1) else None)
...
elif ch == chr(92):
    if q == _DQ and s[i + 1:i + 2] == "$" and s[i + 2:i + 3] in (_SQ, _DQ) and bq[i] == _DQ:
        out.append("$"); i += 2; continue      # the respelling below
```

Here `q` is the existing flat quote state. This is the view shlex takes of the normalized text, so the text the readings feed it must agree with it.

`_bash_quoted(s)` is a new pure O(n) pre-pass. For each index it returns the quote bash reads that character inside: `'`, `"`, or none. An ANSI-C span counts as a kind of its own, which matches neither of the flat walk's quotes. It differs from the flat walk in three ways:
- a `$( … )` body opens its own quoting, and the enclosing state returns at its close;
- a backtick body is read as unquoted throughout. Bash strips a layer of backslashes from it before parsing, so its raw quotes are not bash's quotes. The closer is found with backslash escapes honoured. If no closer is found, the rest of the text is read as unquoted too. Either way the `$` drops there, as on main. The same holds for an unclosed `$(` body wherever the flat walk reads it as quoted;
- an unquoted `$'…'` is one ANSI-C span, measured by the existing `_ansi_c_span`.

One respelling goes with the keep. Inside a region both readers call double-quoted, a `\$` before a quote is emitted as `$`. Bash drops that backslash inside `"…"`, but shlex keeps it. Without the respelling, a double-quoted program typed as `\$'it\'s'` reached its own scan as an escaped `$`, and its ANSI-C quote was lost.

Text the pre-pass leaves unterminated is not handed back to main's reading. Bash runs every complete line before a syntax error, so that hand-back would let a trailing line bash cannot parse switch the fix off for a payload above it. Such text may be refused instead.

The kind has to match, not just the fact of being quoted. In `"$(bash -c '…')"` the flat walk reads the program as double-quoted, while bash reads it as single-quoted. Kept on "both quoted", a `$` there reached a shlex parse that misread `echo "("; …; echo $'\\'`, and that refused a print (design review, iteration 2).

Where both readers name the same quote, the `$` is now copied through. That is bash's reading:
- inside `'…'` every byte is literal;
- inside `"…"`, `$'` is literal and a `$` before the closing `"` is literal.

So a program extracted from that span reaches the depth-1 scan with its bytes intact. There `_norm_for_scan` applies whichever reading is active to the program's own top level.

Everywhere else the `$` is dropped exactly as before:
- outside quotes;
- in a `"$( … )"` body, which bash reads unquoted while the flat walk reads it quoted;
- where the two readers name different quotes, as for a single-quoted program inside `"$( … )"`;
- after `$$`;
- at a `$'` whose ANSI-C quote never closes (`_ansi_c_span` returns None).

A `)` the pre-pass cannot pair, such as a `case` arm inside `"$( … )"`, closes its body early. It restores the saved quote state, which holds until the next quote character, and both walkers toggle on that quote. In that stretch the pass can only keep a `$`. That is an over-block direction, never a fail-open against main.

**D1b. The trigger cannot be split by the outer quoting.** `_ansi_c_differs` decides whether the second reading runs at all. It matched `$'` with `\'`, `\$'` and `\$"` as plain substrings, so a double-quoted `bash -c "…"` program never triggered it: there the program's `\$"` is typed `\\$\"`. Matching the spellings one layer down was not enough either. An outer layer can split them across adjacent quoted fragments: `bash -c 'echo "''\''$"; …'` hands bash `echo "\$"; …`, while no contiguous `\$"` is left in the raw text (design review, iteration 3, measured as a fail-open on main and on the earlier revision of this branch). The trigger is now one regex plus a substring test, in both modules:
- `\$\\*["']`: a `$`, any backslashes, then a quote;
- together with any backslash anywhere in the text.

Wherever the program puts a `$` before a quote, the raw text still has a `$` followed by only the backslashes or the closing quote that a layer adds. And the first reading's strip can only misread where a backslash escapes something. Both old spellings imply this test, so it is a superset of them.

The test is checked against the raw command and against its continuation-joined form. That form is built in the normalizer's own order: CRLF and a bare CR become LF first, then backslash-LF is removed. Without it, `"\$\<newline>"` runs as `"\$"` while its raw text spells neither pattern. On main that is a fail-open at top level as well as nested, in both gates.

Each of these checks is a superset of the old test. For the trigger alone, firing more often can only add blocks, at the cost of a second pass. The change as a whole is not monotone: the changed keep in D1 also moves some blocks to allow, as the next paragraphs say.

The first reading is untouched, so every block it reaches survives. It stays the over-read of heredoc bodies that the `_ansi_c_reading` comment records. The two readings remain a union.

A block that main reached only through its second reading can move to allow. The fuzz below found three such moves. In each, a mention or a read sat in a nested program that main's second reading had corrupted into a payload, and bash runs nothing in any of them.

**D2. The verdicts that move from allow to block are inherited, and they are pinned.** Measured over the corpus and fuzz below, every command whose verdict moves from main's OK (or False) to block is one of three kinds:
- its program alone already blocks at top level on main;
- its plain twin, with the escaped strings removed, blocks on main. This is #1048's deliberate class, "what main refuses without the strings, it now refuses with them", which the 1048 suite pins;
- its continuation-joined spelling blocks on main. D1b reads `"\$\<newline>"` as the `"\$"` bash runs, so the split spelling now gets the joined spelling's answer. For example, cmdword returns True on main for `x="$(sh -c 'echo "("; echo "\$"')"`, and it now returns True for the split spelling too. The refusal itself is a pre-existing cmdword over-block of `"("` beside `"\$"` in a quoted `$( )`: main returns True for `x="$(echo "("; echo "\$")"` too. Pinned with `assert_refused_mod` beside its joined spelling (fuzz seed 93).

The second kind is how the seeds 81/83 moves in *Review history* are inherited; both are now pinned with their twins.

For the first kind: On main these were OK when nested only because the same `$` loss that hid the payloads also mangled these programs into something that parsed clean.

Three named shapes:
- #1043's own program `echo $'it\'s'; python3 H; echo '\$'` under `dash -c`, which dash rejects ("Unterminated quoted string"). TOP blocks it on main, because under bash it runs. Pinned with `assert_refused`.
- `printf '%s\n' $'\''echo H'` (and its `rm` twin), nested under any `-c`. `bash -n` rejects the program ("unexpected EOF while looking for matching `''"), so bash runs nothing, and TOP blocks it on main for that reason. Under dash it parses, because dash 0.5.12 has no `$'…'`, and only prints.
- cmdword `echo $'it\'s'; echo rm src; echo '\$'`, nested. TOP returns True on main under the FIRST reading alone (measured with `_ansi_c_differs` forced False). This is a cmdword `_command_substitutions` residual of #1043. No change to the second reading can clear it, because either reading blocking blocks.

**This revises #1051's filed acceptance** ("the three litmus over-block shapes stay OK"). The operator approved the revision on 2026-10-28. The inheritance is accepted because "stay OK nested" asks the nested reading to be more permissive than top level, which is the bug class this closes. Each inherited shape is pinned with its TOP row beside it, asserting both block, so the reason is visible in the test.

**D3. Rejected alternatives** (each measured or refuted during PR #1050):
- *Keep the `$` only when escaped (`_escaped_at`).* This drops the unescaped `$` of `$'it\'s'` but keeps the escaped one of `'\$'`. That breaks the cancellation the nested program parsed by and produces a NEW over-block: `bash -c` of `echo $'it\'s'; echo H; echo '\$'`, where TOP is OK (litmus, 1048 round 2). D1 has no such row.
- *D1 plus ANSI-C spans in cmdword `_command_substitutions`.* This would clear the cmdword TOP residual in D2, but it over-blocked `dash -c` programs and failed a pinned #1043 row (a write that sits only in a comment, which then read as a file mod). That is separate work on a separate walker; see Consequences.
- *Interpreter-aware readings (ANSI-C rules only for bash).* `sh -c` is dash on this host and bash on macOS. The gate cannot know the interpreter from the command text, so a loosened reading for `sh` would be scoped by host-controlled input. Literal `dash -c` would buy back one shape that is a bash syntax error at top level, at the cost of interpreter plumbing through `_exec_payloads` in both modules.
- *Re-extract each payload from the original text.* This needs a second outer-layer parser to map shlex tokens back to source spans. D1 achieves the same thing by not corrupting the bytes in the first place.

## Tests

In `tests/test-escaped-dollar-1048.sh`, replacing the "Residual, tracked in #1051" comment. The rows follow two rules:
- Payload rows (`assert_block`, `assert_mod`) are first executed under bash and must really run the stub helper or really delete `src/`.
- Allow rows (`assert_ok`, `assert_no_mod`) and inherited rows (`assert_refused`, `assert_refused_mod`) must not. An inherited row must still block.

- **Nested payloads must block** (marker_check):
  - #1048's shape under `bash -c`, `sh -c`, `dash -c`, `bash <<<`, `sh -c` inside `bash -c`, and a double-quoted `bash -c "…"`;
  - #1043's shape `echo $'it\'s'; python3 H; echo '\$'` under `bash -c` and `bash <<<`;
  - the same shape double-quoted, ending in `# it's`;
  - a program after an unquoted `$'it\'s'`;
  - a program after a backtick body holding `\\'` (`: "`echo \\'`"; bash -c '…'`);
  - #1048's shape split by a line continuation inside each `"\$"`, at top level and under `bash -c`;
  - the same split by a backslash and a bare CR;
  - a double-quoted program typed as `\$'it\\'s'`, under `bash -c "…"` and `bash <<< "…"`;
  - #1048's shape with each `\$"` split across adjacent outer fragments, the design-review reproducer `bash -c 'echo "''\''$"; python3 H; echo "''\''$"'`;
  - #1043's shape split the same way, its `$` and `'` in adjacent fragments.
- **Accepted over-block** (Consequences): the `case`-arm shape above, `assert_refused` in marker_check and `assert_refused_mod` in cmdword.
- **The copies match:** an AST comparison of `_requote_ansi_c`, `_bash_quoted`, `_ansi_c_differs` and its trigger pattern in both modules. Docstrings and comments are ignored. The files are parsed, not imported, because importing `marker_check` runs its hook `main()`. The comparison was confirmed to fail on a drifted copy.
- **Nested writes are file mods** (cmdword): the same shapes with `rm -rf src`, including `sh -c` inside `bash -c` and the split reproducer.
- **Nested reads stay OK:**
  - `bash -c` of `echo $'it\'s'; echo H; echo '\$'` (marker_check);
  - `bash -c` / `sh -c` of `echo "\$"; echo H; echo "\$"` (marker_check);
  - `bash -c` of `echo "\$"; ls src; echo "\$"` (cmdword);
  - the split reproducer with `echo H` (marker_check) and `ls src` (cmdword) in place of the payload;
  - the two code-review reproducers inside `"$( … )"`, `echo "$(echo "\$(x)"; …; echo $'\\')"` and `echo "$(echo "("; …; echo "$'\\'")"`, in both gates.
- **Inherited from top level** (new section): for each D2 shape that bash does not run, the TOP row and the nested row, both asserted to block (`assert_refused`, `assert_refused_mod`), both asserted not to run. The comment says that TOP already blocks on main and why. #1043's own program under `bash -c` does run, so it is an `assert_block` payload row above, not an inherited row; only its `dash -c` spelling is inherited.

Regression suites:
- every suite that drives `marker_check.py` or `is_file_mod` stays green against a baseline recorded on `54d6d0f7` before the change, including `test-ansic-quote-1043.sh` (27/27 on the spike);
- `tests/test-gate-integrity.sh` passes after `./scripts/gate-integrity.sh --update`.

## Verdict changes against main (D1 + D1b as of commit `5d6d9393`; the later rounds are in *Review history*)

- Corpus of 6 programs × 7 wrappers (TOP, `bash`/`sh`/`dash -c` single-quoted, `bash -c` double-quoted, `bash <<'E'`, `bash <<<`), in both gates:
  - every row bash runs now blocks;
  - every changed allow-row is inherited (D2).
- Differential fuzz, 5000 commands per gate (seeds 51 and 53). Wrappers:
  - `shlex.quote`'d `bash`/`sh`/`dash`/`bash -e -c`;
  - a raw double-quoted `bash -c "…"`;
  - `eval`, `bash <<<`, and `sh -c` inside `bash -c`;
  - `$( )`, `"$( )"` and a backtick inside double quotes;
  - a 30% chance of an escaped-`$` or ANSI-C atom before the wrapper.
- Results:

  | | marker_check | cmdword |
  |---|---|---|
  | fail-opens | 0 | 0 |
  | commands bash runs, OK → BLOCK | 24 | 25 |
  | print-only, OK → BLOCK (every one inherited) | 42 | 44 |
  | BLOCK → OK (each a print; see D1) | 1 | 2 |

- Time: the slowest heavy probe (an 11.6 KB command) went from 0.09s to 0.17s, inside the 5s hook budget.

## Consequences

- #1051 closes. The nested #1043 shape (rows 2 and 4) closes with it.
- Inherited over-blocks, all fail-closed:
  - a nested program that is a bash syntax error built on `$'\''` (dash would print it);
  - cmdword's top-level `$'it\'s'` residual, now also reached nested.
- The cmdword residual is its own issue, filed only with operator approval. It must not re-propose the `_command_substitutions` change above without answering the `dash -c` and #1043 comment-row findings.
- Depth cap, unchanged. In the helper guard the recursion spends a level on each ANSI-C resolution and each `$( )` flatten, as well as on each nested shell, and past three it fails closed (`BLOCK_UNSCANNABLE`). The design gate has its own caps (`_depth >= 4`). Past them the verdict comes from its fail-closed branches or from `_regex_fallback`, so a print can read either way there: one that names `rm ` reads True.
  - On main, `bash -c` of `sh -c` of `echo $'x'; echo "\$(x)"` already meets the cap.
  - Fuzzing found two print-only programs that now meet it as well (seed 21, before D1b). On main they escaped the cap only because their `$'` was stripped.
  - The cap is a time bound and stays out of scope.
- Not addressed, and pre-existing: a `#` comment line inside a multi-line nested program hides the command after it. For example, `bash -c 'true⏎# note⏎python3 H'` is OK in the helper guard while TOP blocks (found by the design-review arbiter). It is unchanged by this design and needs its own issue, filed only with operator approval.
- Fail-closed by choice: text bash cannot parse because a quote is left open may be refused, because its last `$` can be kept where main dropped it. The fuzz met one print-only case in cmdword. Inside an unclosed backtick or `$(` body, the `$` drops as on main. A payload line above such a construct still blocks, and bash runs nothing inside it. Handing such text back to main's reading would reopen the fix, as D1 explains.
- Not addressed, and pre-existing: cmdword does not extract a command from a `case` arm inside a quoted `$( … )`. For example, `: "$(case x in x) bash -c 'rm -rf src' ;; esac)"` reads as no file mod on main and here, while the same `case` at top level reads True (design-review arbiter, measured). This is a cmdword extraction gap, not part of the `$`-before-a-quote class, and the helper guard blocks its helper twin. It needs its own issue, filed only with operator approval.
- Accepted, new on this branch: a non-inherited over-block through a `case` arm inside `"$( … )"`. With P = `echo "("; ls .; echo $'\\'`, `: "$(case x in x) bash -c <quoted P> ;; esac)"` reads as a file mod, and its helper twin (`echo H` in place of `ls .`) is refused. Main allowed both, and P alone, its plain twin and the same program without the `case` stay allowed. The pre-pass cannot pair the arm's `)`, so it closes the body early and keeps a `$` there (see D1). It fits none of D2's three kinds. The operator accepted it as a fail-closed over-block on 2026-10-29 instead of teaching the pre-pass `case` arms. To be pinned with `assert_refused` and `assert_refused_mod` beside the no-`case` allow rows (design review, iteration 2 of run `ffb4e99d`).
- Not addressed, and pre-existing: in the design gate, #1043's shape carried inside a backtick body with its backslashes doubled for that transport. With P = `echo $'it\'s'; rm -rf src; echo $'it\'s'`, both `` : "`bash -c Q`" `` and bare `` : `bash -c Q` `` (Q = P quoted, its backslashes doubled) delete `src/` under bash. cmdword reads them as no file mod on main and here, while the undoubled spelling, the `$( )` form and P alone read True. The helper guard blocks the helper twin on both. The cause is that cmdword reads a backtick body raw, without the layer of backslashes bash strips before parsing. That is outside the `$`-before-a-quote class and outside this design's walkers. It is an exception to the nested invariant in the Goal, declared here; it needs its own issue, filed only with operator approval (design review, iteration 2 of run `ffb4e99d`).
- The double-quoted `bash -c "…"` spelling of the dash shape now blocks as TOP does. It read OK through round 2, and the D1 respelling hands it its own top-level reading. It is an inherited refusal of the first kind, pinned with `assert_refused`. Bash cannot run the inner program.
- Not addressed, a declared residual: an ANSI-C escape SEQUENCE that spells the shape, as in `bash -c $'echo "\x5c\x24"; …'`. It is open on main and here, in both gates (design review round 4, executed under bash). Escape sequences are the class `_norm_for_scan` already declares out of scope ("Escape SEQUENCES such as \x6c remain undecodable by shlex"), the same class as a helper name assembled at run time (ADR 0006). Decoding them for the trigger alone would not close the class, because the payload words are encoded the same way. The operator approved keeping it out of scope on 2026-10-29.
- **Revisit trigger:** a real script refused by an inherited shape, or a parity test between the top-level and nested verdicts across both gates.

## Review history

The code review (litmus) of the first D1 found four misreadings, each fixed and pinned:

| Round | Finding | Fix |
|---|---|---|
| 1 | Keeping every quoted `$` misread `"$( … )"` bodies, which bash reads unquoted. Reproducer: `echo "$(echo "\$(x)"; …; echo $'\\')"`. | First a substitution stack inside `_requote_ansi_c`. |
| 2 | That stack disagreed with the flat walk shlex does. Reproducer: `echo "$(echo "("; …; echo "$'\\'")"`. | The keep is narrowed to where both readers say quoted (D1). |
| 3 | Narrowing to single quotes alone kept a double-quoted fail-open on main: `bash -c "echo $'it\'s'; …; # it's"`. | Double quotes are back in D1, through `_bash_quoted`. |
| 4 | `_bash_quoted` read `$'it\'s'` as a plain quote. | It reads the ANSI-C span. |

The fuzz then found D1b's case: a double-quoted program carrying #1048's shape, open on main.

Design review round 2 found two more, both executed under bash and both open on main:

| Finding | Fix |
|---|---|
| A backtick body's raw `\\'` opened a phantom quote in `_bash_quoted`, so the design gate read a nested `rm -rf src` as no file mod. | The backtick body is read unquoted as a whole. |
| A line continuation inside `"\$"` hid it from the trigger. | The trigger also checks the continuation-joined text. |

Design review round 3 found two more. Both were already open on main:
- **A double-quoted `\$'it\\'s'`.** The first fix was the D1 respelling. With the bare `bq` lookup it raised `IndexError` on text with no `$`, which the fuzz caught. It now checks for the `$` before indexing.
- **A backslash with a bare CR.** Fixed by building the trigger's joined form in the normalizer's own order.

A first attempt to hand unterminated text back to main's reading was withdrawn before commit, for the reason D1 gives.

The last fuzz (seeds 81 and 83) found no fail-open. It found one OK → BLOCK move per gate that is not inherited from its TOP program. In each, `"\$\<CR>"` sits before an `||` branch that bash does not take. Main exempted it only through the #1048 misreading, and main blocks the plain twin without the strings in both gates (measured). It is the same deliberate class the 1048 suite already pins as "what main refuses without the strings, it now refuses with them".

All of these are pinned. Fuzz with continuation and backtick atoms added, 5000 commands per gate (seeds 61 and 63):

| | marker_check | cmdword |
|---|---|---|
| fail-opens | 0 | 0 |
| non-inherited OK → BLOCK | 0 | 0 |
| BLOCK → OK (a print) | 0 | 1 |

Design review iteration 2 found the over-block D1 now explains. With P = `echo "("; ls .; echo $'\\'`, `: "$(bash -c <quoted P>)"` read as a file mod, and the helper twin `echo H` in place of `ls .` was refused. Both are prints that main allowed, and P alone stays allowed. Fix: the keep compares the quote kind. Both shapes, under `: "$( )"` and `x="$( )"`, are pinned as allow rows in both gates, and the rows were confirmed to fail without the fix.

The fuzz then added three wrappers: `: "$(bash -c …)"`, `x="$(sh -c …)"` and `echo "$(bash <<< …)"`, with `echo "("` among the atoms. 5000 commands per gate (seeds 91 and 93):

| | marker_check | cmdword |
|---|---|---|
| fail-opens | 0 | 0 |
| non-inherited OK → BLOCK | 0 | 0 |
| OK → BLOCK through the joined spelling (D2's third kind) | 0 | 1 |
| BLOCK → OK (a print) | 1 | 0 |

Both moves are named and pinned. The BLOCK → OK move is a `cat H` read in an `sh -c` program after a `"\$\<CR>"`. Main refused it only through the #1048 misreading, and it now gets its plain twin's OK.

Design review iteration 3 (a fresh review, run `cfd929ad`) found that adjacent outer fragments split the trigger's spellings. The reproducer is `bash -c 'echo "''\''$"; rm -rf src; echo "''\''$"'`, and the arbiter measured it as a fail-open on main and on the iteration-2 revision of this branch, in both gates and under `bash`/`sh`/`dash -c`. Splitting #1043's `$'` from its quote the same way had the same effect. D1b now fires on any `$` before a quote together with any backslash. The #1043 split falls under the same test, because its program puts a `$` before a quote and holds a backslash; *Tests* lists a row for it. The same review noted that the `_bash_quoted` `$(` arm does not skip `$$(`. Every probe of that reading blocked on both main and the branch, so it is recorded here and not changed.

With the wider trigger, the seed 91/93 fuzz above gives the same counts in every cell, on the same corpus. That corpus has no adjacent-fragment atoms, so it shows that the wider trigger adds no over-block there. It does not show that the split is closed. The rows listed in *Tests* carry that.

<!-- design-review-coverage: DEGRADED 2/3 reviewer_2=runtime-failed -->

<!-- design-reviewed: PENDING -->
