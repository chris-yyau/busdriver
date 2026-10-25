# marker_check: the `$(...)` flatten reads quoted text as shell (#889, classifier side)

> **For agentic workers:** small change, executed inline. The pieces:
> - in `hooks/gate-scripts/lib/marker_check.py`: the `_literal_spans` lexer, its consult in the existing `$(...)` flatten, and the pairing-loop edits D2 lists;
> - two new shell tests: verdict rows, and a separate oracle file;
> - a corrected comment in `tests/test-marker-case-776.sh`;
> - a `scripts/ci/shell-test-durations.tsv` entry for each new test;
> - the regenerated `.gate-integrity.lock`.
>
> No subagent fan-out.

**Goal:** ordinary read-only commands that put a `$(...)` next to single-quoted program text (a jq filter, a `node -e` snippet, a grep regex, a parenthesized free-text value) stop being refused with `Cannot call lease_slot.py directly`. That covers each such command on which `_literal_spans` returns tokens (D3 lists every bail; the common ones are an unquoted `#`, heredoc, backtick, `((`, `$'` or continuation, R1), and whose kept spans contain no `$(` or backtick (D4.1, R4). It does not cover the two shipped pr-grind blocks, which carry `#` comments. **Non-regression:** every command main blocks that runs a protected helper keeps blocking, **except** where main's BLOCK exists only because of the misreading this change removes. The test for that is the command's **plain form**: the same text without the unrelated `$(…)` that sends it down the crude flatten. Where main returns OK for the plain form, main does not guard that shape; its BLOCK beside a `$(…)` comes only from a dropped quote turning a `(` or newline inside a span into a fake subshell or line, which is the #889 mechanism itself. So no coverage main actually provides is lost. Measured on the final spike: every BLOCK-to-OK flip that review still found once the fixes were in (24 shapes) has an OK plain form on main. They fall into three residuals:
- **R7**, the ADR 0006 execute-a-string class: a helper run only because bash later expands data the command stored or transported (a variable, a positional parameter, `read`/`mapfile`/herestring input). This repo already declares that class out of scope (`marker_check.py` RESIDUAL near line 1694, ADR 0032 "Where this stops"). Main returns OK for `read -r P <<< '<H>'; $P`, `set -- '<H>'; $1`, `printf -v` and `mapfile`. D5 still keeps main's verdict at the bound positions, although that coverage is incidental too (the plain `P='<H>'; $P` is OK on main).
- **R8**, a non-shell interpreter running the helper from a payload in its own language (`python3 -c 'import os; os.system("<H>")'`, `node -e` with `execSync`, `awk` `system()`). The producer scan reads payloads as shell text, and `marker_check.py` already declares this class a KNOWN RESIDUAL (near line 3858, and the "`python3 -c` the write directly" note near line 1698).
- **R9**, any other command, builtin or program, that runs an argument as shell text and that main's probes do not recognise as a string executor. Main returns OK for the plain form of each one measured. The measured inventory is tracked privately, together with the pre-existing issues it belongs to.

In scope, so the property holds without exception:
- a helper in command position in the operator's text: top level, inside `$(…)`/`"$(…)"`, a subshell, a `{ }` group, a function body, or after a command-position `$(…)`;
- a literal payload handed, in the same text, to a string executor that main's probes recognise: `sh -c`/`bash -c` (including payloads assembled from quoted chunks), `eval '…'`, `xargs sh -c`, a literal producer piped into a shell, a herestring into a shell (`bash <<<`, `sh <<<`);
- D4 arithmetic re-evaluation;
- quote concatenation that forms a helper name or a `$(` (the D3 word rule);
- spans at D5's bound positions.

**Scope:** inside `marker_check.py`, the new `_literal_spans(cmd)` lexer and the D2 consult inside the crude flatten in `_helper_invoked` (the `if _depth <= 2 and ("$(" in cmd or chr(96) in cmd):` block, around line 5443 on `14bfe896`). It touches no other reader: not `_split_with_ops`, `_norm_for_scan`, `_strip_cmd_subst`, `_blank_comments`, the probes, `cmdword.py`, any allowlist, budget or timeout. Refs #889. The wrapper side of #889 shipped in #1018.

**Out of scope:** comment modelling (see D3; follow-up issue); #1013 (some rows change as a side effect, which is listed below and not claimed); #947's conditional residuals A9/A12; #639; #877.

---

## Evidence (measured on `14bfe896`, classifier called directly as the tests do)

| Input | Verdict on main |
|---|---|
| #889 repro 1 (approver-gap composer, three lines from the issue body) | `BLOCK_MARKER_SCRIPT\|lease_slot.py` |
| #889 repro 2 (`node -e` / grep dependency inspection, two lines) | `BLOCK_MARKER_SCRIPT\|lease_slot.py` |
| 2.10.1 minimal repro (parenthesized `RESULT_FIXES`, `/*)` arm, `$(...)` in an `if`) | `BLOCK_MARKER_SCRIPT\|lease_slot.py` |

A trace of `_helper_invoked` shows that all three take the same path. The depth-0 flatten (`_flat = cmd.replace('"', "").replace("'", "")`) re-enters at depth 1. There, `_piped_shell_producers` returns one producer that runs across many real segments, and `_abandoned_scan_probe` finds a glob-shaped word in it (`*[!0-9]*` in repro 1, `[^"]*` in repro 2) that could match the helper's name. The producer is that long because the flatten removed every quote character. The jq program's `( ) |` (repro 1) and the JS call's `( )` (repro 2) then read as subshells and pipes, and the `''` empty pattern in repro 1 becomes a missing alternative (the residual `tests/test-marker-case-776.sh` already pins). Bash never reads a single-quoted character as syntax. These pipes and subshells exist only in the flattened text.

The flatten drops quotes deliberately: "erring toward blocking", and the shell concatenates adjacent quoted runs, so `lease_"slot.py"` is one word. It cannot simply keep them. A `'` inside double quotes is not a quote, so keeping every `'` would let an apostrophe in `"it's $(cmd)"` open a fake span over a live substitution, which is a fail-open.

## Decisions

**D1. A lexer that marks the quoted spans bash reads as wholly literal.** `_literal_spans(cmd)` returns a list of tokens, or `None`. Each token is either one character or one complete span: a single-quoted `'...'`, or a double-quoted `"..."` whose interior contains no `$`, backtick or backslash. In bash neither kind expands anything, runs anything, or ends a word. A span's interior is consumed whole and never inspected by any rule below.

The lexer keeps a frame stack. Quote liveness follows the **innermost** frame only:

| Frame | Opened by | Closed by | Inside it |
|---|---|---|---|
| (none) | | | quotes live; `(` opens `par`, `$(` opens `sub`, `"` opens `dq` or a literal dq span |
| `sub` | `$(` | `)` | quotes live again, even when the `sub` itself sits inside a `dq` frame |
| `par` | `(` outside a `dq` frame | `)` | quotes live |
| `dq` | `"` whose interior is not literal | `"` | quotes are NOT live: `'`, `(` and `)` are ordinary characters (a `)` never pops a `dq` frame); only `$(` opens a frame |

Backslash: outside a kept span, `\X` is one literal pair. `X` never opens, closes or ends anything, and the pair passes through unchanged as **two single-character tokens**. D2's pairing loop therefore reads `\$(` as a `$` token followed by a `(` token, exactly as today's string flatten does. That over-blocks (as today), never fails open. The exceptions are in D3.

**D2. Consult point.** In the crude flatten, when `_depth == 0 and _full is None` (the operator's own text, the #947 precedent) and `_literal_spans` returns tokens:
- drop the remaining `"` and `'` *characters* exactly as today;
- keep the spans whole;
- let the existing `$(`/`(`/`)` pairing loop treat a span as one opaque token;
- unless D5 sends the command back to today's reading first.

The pairing loop changes in exactly three ways:
1. It iterates over the token list instead of the string.
2. A span token is appended verbatim and skipped.
3. Its `_flat.startswith("$(", _k)` test becomes the token-wise equivalent: a `$` token followed by a `(` token.

The output is joined back to a string. Everything else in the flatten (command-position separators, the #802 pairing rules) is unchanged. When the lexer returns `None`, or at any depth other than the top call, the flatten is byte-for-byte today's.

**D3. Soundness invariant: the lexer bails rather than guesses.** *If `_literal_spans` returns tokens, every kept span is literal to bash **and is a whole shell word**, so D2's rewrite can only remove structure that touches no kept span.* The first half is tested by the span oracle, the second by the verdict oracle (Tests). Over-bailing costs nothing (today's verdict). Under-bailing is a fail-open, so the lexer returns `None` on anything it does not model.

Every bail is tested only on characters **outside kept spans**. A span is consumed whole the moment its opening quote is met, so text such as jq's `select((` inside `'...'` (#889 repro 1) never reaches these rules. Inside a `dq` frame the bails still apply, which can only over-bail.

| Bail | Why |
|---|---|
| any backtick | backticks share one delimiter, and the quote rules inside them differ |
| `<<` that is not part of a `<<<` | a heredoc body is not quote-structured text. A herestring `<<<` is consumed as one three-character operator before this rule runs, so its second and third `<` never look like a heredoc |
| `$'` | ANSI-C quoting has its own escape rules (the existing `_ansi_c` re-entry still runs) |
| `((`, including `$((` | arithmetic ignores comments yet still expands `$(...)`, so the frame model would desync. `$((` must be tested **before** the `$(` rule: otherwise `$(` consumes the first `(` and the second never forms a `((` pair. The execution oracle found exactly this in the spike |
| `$[` | the obsolete arithmetic form expands `$(...)` inside apostrophes, so a "span" there is not literal |
| a kept span that is not a whole word. The check is **lexical**: a boundary character that is the second half of a backslash pair is a literal, so it is no boundary. *Before* the opening quote there must be one of: the start of the text; an unescaped blank, newline, `;`, `&`, `\|`, `(`, `<` or `>`; or a prefix `NAME=`, `-opt=` or `--opt=` (NAME an identifier, opt `[A-Za-z0-9][A-Za-z0-9_-]*`) that itself starts at the start of the text or right after one of those unescaped boundary characters. The prefix is searched for only in the 128 characters before the quote: searching from the start of the text for every span was quadratic, and a 60KB `P='x'; ` flood took 5.5s. A longer name fails to match, which only bails. *After* the closing quote there must be the end of the text, a blank, a newline, or one of `;`, `&`, `\|`, `)`, `<`, `>`. A backslash there is never a boundary | the flatten rewrites `$(`/`)` into separators. A span glued to anything else, including plain word characters (which carry the concatenation on to a later substitution: `'a'x$(…)y'b'`), can be split away from text bash joins with it. Round 3 measured both directions. A `sh -c 'echo '$(true)'; <cmd>'` payload is cut in two, which hides `<cmd>` in the second span. A `"a[$"'(<cmd>)]'` subscript forms `$(` only after concatenation, so no kept span contains it and D4.1 never fires. Round 4 measured the escaped form: in `let a[$\(':;<cmd>)]'` (with or without double quotes, with an escaped blank, or as `a[$\(x=':…'`) the `\(` is a literal, so bash joins the words into `a[$(…)]`. A raw-character test read it as a boundary. Glued words such as `lease_'slot.py'` keep today's quote-dropping reading, which is exactly how they are matched today |
| a backslash followed by `'` or `"` | an escaped quote stays on the existing reading. A pre-existing escaped-character issue in the crude path is tracked privately; this change neither alters nor depends on it |
| any `#` outside a kept span and outside a `dq` frame, unless the character before it is `$` (`$#`). A `#` at index 0 has no character before it, so it always bails: a port that wrote `cmd[i-1]` without guarding `i` would wrap to the last character, and a test row pins this. A flat `${…}` (the `${` rule below) is consumed whole at its `${`, like a span, so the `#` in `${#a}` or `${R#* }` never reaches this rule | where bash starts a comment depends on word boundaries, `[[ ]]`, arithmetic, `$(...)` parsing across bash versions, and zsh. A disagreement turns a kept span into a hiding place: if we read code and bash reads a comment, an apostrophe in the comment opens a span that swallows the commands on later lines. The in-file `_blank_comments` is additive-only and documents its own residuals, and `nudge_parse.strip_comments` does not model `$(` inside double quotes, so neither is a sound basis. Comments go to a follow-up. |
| backslash followed by newline, or a trailing backslash | a continuation re-joins lines (the #776 suite pins continuation as abandon too) |
| any `${` that is not a flat expansion: everything from `${` up to its `}` must be drawn from the allowlist `A–Z a–z 0–9 _ # % : / * ? @ ! - + = . , ^ ~` space tab, and the first character outside it must be `}` | quoting, nesting and pattern rules inside `${...}` are operator-specific. A denylist ("no quote before the first `}`") was beaten twice in review: by a nested `${v:-${w:-}…}`, which ends the scan early, and by a `)` inside `${x/)/y}`, which pops the `sub` frame. The allowlist excludes `$ { } ( ) [ ] ' " \` and backtick, so `${a[0]}` and `${#a[@]}` bail too (harmless: today's reading). `${!x}` indirection is allowed, since it only reads a variable |
| an unterminated `'` or `"`, or a frame still open at the end | not valid input to model |
| a `)` that closes a frame in which a `case` word appeared | a case-arm closer would pop the wrong frame. A top-level `)` with an empty stack is a case-arm closer and changes no quoting context, so it is allowed. "A `case` word" means the unquoted characters `case` at a word start (start of text, after a blank, `;`, `&`, `\|`, `(`, `)`, `<`, `>` or newline), outside a `dq` frame, followed by a blank or newline. "Blank" means a space or a tab, as in bash: a lexer that missed tabs would miss `case<TAB>` inside `"$(...)"`, which is a fail-open. A quoted spelling such as `ca''se` is not a reserved word in bash, so it opens no case. The flag is per frame, set when the word is seen, so no text is rescanned |

The lexer is linear: each `find` starts at the current index and the index moves past what it consumed, and the `case` check is a per-frame flag, not a rescan.

**D4. Literal to the parser is not literal to every builtin. Three mechanisms cover the difference, and all are load-bearing.** Some builtins evaluate their quoted argument again as arithmetic: `let 'a[$(cmd)]=1'`, `[[ 1 -eq 'a[$(cmd)]' ]]`, `declare -i 'b=a[$(cmd)]'`, `printf -v 'a[$(cmd)]' …`. Bash expands `$(cmd)` in that array subscript, so text the parser read as a literal span runs. Three mechanisms cover it:
1. **Re-flatten (formerly residual R4).** A kept span whose text contains `$(` or a backtick leaves that `$(` or backtick in the depth-0 flatten output. The depth-1 call's condition is `"$(" in cmd or chr(96) in cmd`, so it re-reads the text on today's quote-stripping path and blocks. The implementation carries a comment at that condition: narrowing it to "no flatten at depth 1" reopens arithmetic re-evaluation.
2. **The backtick bail.** A backtick *outside* any kept span makes the lexer return `None`, so the whole command keeps today's reading. That includes the existing backtick branch of the flatten, which therefore runs only on that `None` path.
3. **The `$[` and `((`/`$((` bails** cover arithmetic contexts in the operator's text.

A `$(` that exists only after bash concatenates quoted pieces is in no span, so none of the three can see it. The D3 word-boundary rule covers that case: such a span is not a whole word, so the lexer bails.

Measured on the spike, all BLOCK as on main:
- six re-evaluating rows: above, inside `$(…)`, in `"$(…)"`, and after an unrelated `$(…)`;
- seven concatenation rows: `let`, `declare -i`, `printf -v` and `[[ -eq ]]`, with plain, double-quoted, escaped-blank and `NAME=` variants.

They are pinned under a header that names this section.

**D5. A span bound to a name keeps today's reading when it reads as a helper invocation.** Round 5's arbiter measured a regression the earlier generators had no family for: `x=$(true); P='python3 <helper>'; $P` blocks on main and was OK on the spike, and bash runs the helper.
- *Why main blocks it.* The crude flatten drops the quotes, so the assignment reads as `P=python3 <helper>`: an environment prefix followed by a helper command. Keeping the span whole correctly makes it an inert assignment value, and nothing resolves the later `$P`.
- *Scope.* A command held in a variable is the ADR 0006 execute-a-string class that no static scan resolves, so main's coverage here is incidental. This change keeps that incidental coverage **at the bound positions below**, adds none, and leaves the rest of the class as R7.
- *Bound positions.* A kept span is bound when either:
  - the character just before its opening quote is `=` (`NAME='…'`, `--opt='…'`); or
  - it sits anywhere inside a compound assignment: the lexer sees a `(` token right after `=` (`NAME=(`, `NAME+=(`), and tracks paren depth until the matching `)`. This covers every element, whatever blanks or newlines precede it.

  A scalar append `NAME+='…'` never reaches D5: the D3 prefix rule has no `+=`, so the lexer bails and the command keeps today's reading (R6). It therefore stays BLOCK through the bail, not through D5.
- *Rule.* Take the span's **interior, without its enclosing quotes**, and read it on today's path as a command, `_helper_invoked(interior, _depth + 1, _full=<whole command>)`. If that names a helper invocation, D2 discards the tokens and the flatten runs byte-for-byte as today. Passing the span *with* its quotes is a fail-open, because the quoted text is one inert word. The D5 rows catch that mistake: their mutation step must flip them.
- *Arrays today.* Today a non-empty `a=( '…' )` is also blocked independently of D5: the function-header pattern reads `a=(` as `<name> (` and hands the command to `_abandoned_scan_probe` (the #813 over-block class). So D5's compound-assignment arm cannot be observed at present; with D5 disabled, every array row still blocks. It is kept so that array coverage does not depend on that over-block, which a fix of the header pattern would remove.
- *Why only those positions.* Only there did the dropped quotes put a span's text in command position, *and* can bash run it later through an expansion. A span in argument position (a grep pattern, a jq filter) cannot be applied this way: read alone on today's path, repro 2's `"version": "[^"]*"` becomes the `[^]*` glob, which is exactly the #889 false positive. A first prototype that checked every span re-broke repro 2. Some argument slots *do* run their span later, namely those of a command that executes its argument as shell text. But whether a slot is one of them depends on which command is being run. Recognising that is the producer probe's string-executor table (`_SHELL_NAMES`, the KNOWN RESIDUAL near line 3858), not the flatten's job, and that gap is R9. A `=`-bound span, by contrast, is recognisable from the text alone (the character before its quote), whatever the command, which is why D5 stops there.
- *Measured on the spike:* 38 rows, 0 regressions against main. They cover:
  - expansions: `$P`, `${P}`, `( $P )`, `{ $P; }`, `$P | cat`, `echo $P | sh`, `eval \$P`, `${!n}`;
  - bindings: a second prefix `P=x Q='…'`, `P+=` (blocked through the D3 bail), `--x=`, a double-quoted value, a function body, a `"$(…)"`-wrapped form;
  - arrays: `a=('…')`, `a=( '…' )`, a tab or newline after `(`, `a+=( … )`, a later element, an element after a `$(…)`.

  With D5 disabled, 12 of them flip to OK, all scalar `=` bindings; those 12 are the D5 mutation rows. The three #889 repros stay OK, and the 2.10.1 `RESULT_FIXES='…(…)…'` assignment stays OK, because its text names no helper.
- *Cost, bounded.* One `_helper_invoked` call per bound span, and each call reads the whole command (`_full`). Uncapped, a 60KB flood of `P='a (b) | c'; ` took 23s, far past the hook's 5s budget, and a killed hook emits nothing and so ALLOWs. Past `_BOUND_SPAN_MAX = 32` bound spans, D2 therefore discards the tokens, which means today's reading. The flood rows include bound-span floods.

**Why not reuse `_strip_cmd_subst`.** It is the #802 quote-aware scanner, but it *removes* substitution bodies, while the flatten exists to *expose* them. Changing its output would change what its existing callers read.

**Rejected alternatives.**
1. Model comments in this lexer. Rejected for the desync risk above.
2. Neutralize metacharacters inside quotes instead of keeping spans. That breaks the concatenation the flatten preserves, and it changes what a `sh -c` payload looks like to the probes.
3. Keep every `'`. Fail-open, through the apostrophe inside double quotes (see Evidence).
4. Do nothing and tell operators to run the block from a script file. That is today's workaround, and #889 records it as the opposite of what the guard wants to encourage.

## Verdict changes against main (spike; ten suites re-run: the eight that call `marker_check.py` by path, plus `test-impl-gate-scope-553.sh` and `-519.sh`, which import it or drive the gate)

**BLOCK to OK, intended:**
- #889 repro 1, repro 2 and the 2.10.1 minimal repro.
- No existing fixture flips. Earlier spikes flipped `tests/test-marker-conditional-889.sh` A3 (`[[ "$(true)" -eq 1 && "$g" == *') || y' ]]`). Under the D3 word-boundary rule its span is glued to `*`, so the lexer bails and A3 keeps its pinned BLOCK. The suite stays 172/172 unchanged.

**OK to BLOCK, side effect, not claimed:** five #1013 rows where a `sh -c`/`bash -c` payload spelled `python3 <helper>` sits inside a quoted `"$( … )"`. The old flatten cut the payload down to its first word (`python3`), so the helper path became an inert argument; with the quotes kept, the probe sees the whole payload. `echo "$(sh -c "$Y python3 <helper>")"` stays OK, because that payload contains `$` and is not literal. #1013 stays open.

**Unchanged, still BLOCK:**
- A9 and A12 in the #947 suite: after flattening, the bare `*` operand reaches `_glob_helper`, which is #947's `$(`-STOP residual and not about quoting.
- The two shipped pr-grind blocks with their placeholders filled (Step 0's solo-admin snapshot block, completion.md's approver-gap block): both carry `#` comments, so the lexer bails (D3). They are pinned as residuals and named in the comment follow-up issue.
- Every row of the other nine suites (643, fail-closed, oracle-wrapper-root, case-776, loop-binding-638, glob-expansion-budget-802, glob-specificity, impl-gate-scope-553, impl-gate-scope-519), with identical output. Round 5 re-ran sixteen gate suites on the final spike, plus the #947 suite (172/172), with D5, the D3 window and the D5 cap in place. The spike passed every row of all of them, and the adversarial, re-evaluation and round-3/4 row checks still report 0 fail-opens. The main checkout failed one `test-gate-classifier-fail-closed.sh` row and twelve `test-pre-implementation-gate.sh` rows (`rm unrelated ; echo marker`-style rows expecting allow). Those rows belong to the design-marker gate and depend on that checkout's pending design-review state, not on the flatten.
- The case-776 row "the idiom beside a `$(...)` substitution" stays BLOCK. Its comment says the flatten's dropped quotes are the cause, but the measured driver is the `*) :;;` arm: the same command without that arm is already OK on main. The comment is corrected to say so.

**Adversarial rows (all still BLOCK):** 26 commands that run the helper through a quoted path, among them `echo "it's $(python3 <helper>)"`, `echo "$(echo 'x)'; python3 <helper>)"`, `x=$(python3 'hooks/…/lease_'slot.py)`, `x=$(sh -c 'x; python3 <helper>')`, `x=$(eval '…')`, `x=$(printf %s '…' | sh)`, `x=$(bash <<< '…')`, `x=$(xargs sh -c '…' <<< y)`, `f() { …; }; x=$(f '(z)'; python3 <helper>)`, `x=$(echo '"'; python3 <helper>; echo '"')`, and `x=$(echo '${'; python3 <helper>)`.

**Timing:** 60KB floods (nested `(`, nested `$(`, `"$x"`, `'a' $(true)`, `${`, `case` inside `$(`, `"a" $(true)`) take the same wall time as on main, 0.12–0.95s, with the same verdicts.

## Tests

New `tests/test-marker-flatten-quotes-889.sh`, in the shape of `test-marker-case-776.sh`. The helper name is assembled from fragments, and the file is written with a file tool, never a heredoc. Verdict rows go through the classifier as a subprocess, as in case-776. The property test calls `_literal_spans` directly by importing `marker_check` with the library directory on `sys.path`, the pattern `test-impl-gate-scope-553.sh` already uses (the module's top-level gate run then sees an empty stdin and is ignored).
- **A (allowed):** the three repros, the jq/node/grep shapes in isolation, and a parenthesized single-quoted assignment beside a `$(...)` in an `if`.
- **B (keeps blocking, the producer probe's own reason):** the adversarial rows above.
- **Bail rows:** one row per D3 bail, built so that only the bail keeps it from being read as literal (for example `x=$(echo '#'; …)` versus a `#` comment holding an apostrophe ahead of a live substitution on the next line). For each bail, the implementer comments out that one bail line, confirms its row FAILS, and restores it, as "prove the guard fires". The row then pins the result. The one exception is the escaped-quote bail. Its public row asserts only that `_literal_spans` returns `None` on a backslash-quote outside a span: no classifier verdict, no helper, no mutation step. Its verdict consequence is pinned with the private fix.
- **D4 rows:** the six re-evaluating-builtin shapes, pinned BLOCK under a header naming D4.
- **D5 rows.** These use a helper invocation **with trailing arguments** (`python3 <helper path> state(x) 20 0 99999`). A bare `python3 <path>` is caught without D5 in some positions, which would make the mutation step pass vacuously.
  - **Mutation rows:** the 12 scalar bindings that flip when D5 is off, pinned BLOCK. Prove the guard fires: replace the D5 `_helper_invoked` call with `False`, and confirm all 12 fail.
  - **Array rows:** pinned BLOCK as well, but outside the mutation step, for the reason given under *Arrays today*.
  - **Allowed rows:** the `RESULT_FIXES='…(…)…'` assignment and repro 2's grep pattern, pinned OK.
  - **R7 rows**, under a header naming R7:
    - `read -r P <<< '…'; $P` and `set -- '…'; $1`, pinned at their current OK verdict (OK on main too);
    - the variants that do flip: `x=$(true); read -r P <<< 'state(<helper path>)'; $P` and `x=$(true); set -- 'state(<helper path>)'; $1`. Main blocks them only because the dropped quotes make `state(` a fake subshell. They are pinned OK, and each row's comment names its plain form, which is OK on main.
- **R8 rows:** `x=$(true); python3 -c 'import os; os.system("<H>")'`, the same with `node -e` and `execSync`, and `x=$(true); awk 'BEGIN{system("<H>")}'`, pinned OK under a header naming R8. Each row's comment states that main blocks it only through the #889 mechanism and returns OK without the `$(true)`.
- **`#` at index 0:** `_literal_spans` returns `None` on a command that starts with `#` and ends with `$`.
- **Empty spans:** `''` and `""` are kept spans of length 2. A row pins that `case "$X" in ''|*[!0-9]*)` keeps its `''`.
- **Flips:** the five #1013 side-effect rows pinned as BLOCK, with a comment saying they are not a #1013 fix.
- **Word-boundary rows (D3), pinned BLOCK.** Each was measured BLOCK on main and OK on a spike without the rule:
  - a quoted span glued to `$(true)` inside a `sh -c`/`for`/`case` payload;
  - `$(` assembled across quotes in `let`/`declare -i`/`printf -v` subscripts;
  - the round-4 escaped-delimiter forms: `\(` or `\ ` before a span, and `NAME=` after an escaped `(`.
  
  Allowed rows pin that `--filter='a (b) | c'` and `jq … <<< 'x'` beside a `$(…)` stay OK.
- **Bash execution oracle (property test).** A parse reprint such as `declare -f` cannot prove a span is literal: double-quoted text reprints verbatim too, so a wrongly kept span inside `"…"` would pass. The oracle therefore runs bash and asks it.
  - **Generator.** A small grammar over harmless commands (`echo`, `true`, `:`, `case … esac`, `( … )`). It deliberately has no `let`/`declare -i`: those re-evaluate a literal span (D4), so a probe there could fire with a correct lexer. Re-evaluation is the verdict oracle's job. It is joined by `;`, `|`, `&&` and newline, with words built from:
    - single-quoted text, which can hold `" ( ) $( ; | # ${ } \` backtick tab `((` `$[` `<<`;
    - double-quoted text, which can hold `'`, `(`, `)`, `$(…)`, nested `${a:-${b}}`, and `\"` / `\$` / `\\`;
    - `$(…)` substitutions, flat and nested `${…}`, backslash pairs, and globs.
    
    It keeps what `bash -n` accepts.
  - **Probe.** For each command the lexer accepts, insert `;echo PR\OBE>&2;$(echo PR\OBE>&2)` into every kept single-quoted span, and `;echo PR\OBE>&2;` into every kept double-quoted span (a `$(` would make that span non-literal by definition). Run the result as `bash -c` with `PATH` only, `stdin` closed, in a fresh temp directory, through Python's `subprocess.run(..., timeout=5)`. That is portable, so there is no GNU `timeout` dependency (macOS/BSD); a timed-out case is skipped, not counted.
  - **Property.** `PROBE` never appears on stderr. The backslash matters: an error message that quotes the literal text (`command not found: …PR\OBE…`) cannot fake a hit, and only an `echo` that actually runs prints `PROBE`. (A first harness without it fired on exactly such messages.) No filesystem write and no environment variable is involved, so the probe cannot pass vacuously.
  - **Positive control.** The same run against a deliberately broken variant (a `'` inside a `dq` frame opens a span) must fire at least once, or the test fails.
  - **The control disables the word-boundary rule.** Otherwise that rule rejects the planted fake spans before the probe sees them, and the control could never fire.
  - **Measured on the final spike:** seeds 889 and 1013, N=5000 each, about 13s per run. Seed 889: the lexer accepted 642 commands with 190 probed spans, 0 hits; the control had 2 hits. Seed 1013: 0 lexer hits, 1 control hit. An earlier run (seed 7, N=20000, before the word-boundary rule) also had 0 lexer hits against 12 control hits. The first run found the `$((` ordering bug (D3), since fixed.
- **Verdict non-regression oracle.** The span oracle proves only that each kept span is literal. It says nothing about D2's rewrite: round 3's holes had fully literal spans. This oracle tests the property that matters.
  - **Generator.** Commands with a *marker slot* placed where the rewrite could hide it:
    - `sh -c`/`bash -c`/`eval` payloads that bash assembles from alternating quoted chunks, glued `$(true)`, and escaped delimiters (`\(`, `\ `, `\;`, `\)`, `\|`) glued to a chunk;
    - `let`/`declare -i`/`((` subscripts assembled across quote boundaries, including through an escaped delimiter;
    - commands after a `$(…)` piece, bare or inside `"$(…)"`;
    - a span bound to a name or array (`P=`, `P+=`, `P=x Q=`, `a=(`, `a+=( `, `a=(` plus newline, `n=P; P=`, single- or double-quoted) and expanded later as `$V`, `${V}`, `( $V )`, `{ $V; }`, `$V | cat`, `echo $V | sh`, `eval \$V` or `${!n}` (D5);
    - with or without an unrelated `$(…)` prefix.
  - **Reference classifier.** "Main" is **not** a checkout. CI checkouts are shallow, and after merge main *is* the change, so comparing against it would pass while checking nothing. By D2's invariant, the change with `_literal_spans` forced to return `None` runs today's flatten byte-for-byte. The script therefore builds that reference itself, the same way it builds the controls: copy the library to a temp directory and make the lexer's first statement `return None`. In the spike run, an extra flag compared this reference against the real pre-change file on every command where the slot ran, and found 0 mismatches (numbers below). The shipped test does not need the flag.
  - **Two renderings per command.**
    - The classifier, as the reference and with the change, sees the slot filled with a real helper invocation (`python3 <helper path>`, assembled from fragments).
    - bash runs the same text with a stand-in in the slot. The slot executes if `PROBE` appears on the stream the stand-in writes:
      - Most families use `echo PR\OBE >&2` and read **stderr**. The `>&2` is load-bearing, because a substitution captures stdout. The backslash means only an echo that actually runs prints `PROBE`.
      - The bound-span family uses `printf %s%s\n PR OBE`, reading stdout and stderr. Text that arrives through a parameter expansion is not reparsed: there `>&2` is a plain argument and `\O` is never unescaped. printf's literal text reads `PR OBE`, so an error message cannot fake a hit either.
  - **Property.** For every command where the slot executes and the lexer accepts the text, the classifier with the change BLOCKs whenever the reference BLOCKs. The generator has no R7 transport (`read`/`mapfile`/herestring into a variable, `set --`, `printf -v`), since those are out of scope by the Goal. It also has no non-shell interpreter (R8) and no other unrecognised executor (R9): its string executors are `sh -c`, `bash -c` and `eval` only. The R7 and R8 rows pin their verdict instead. R9 is recorded, not tested in this change: its shapes are held in private tracking, and any rows for them belong to the change that decides the string-executor table. Within the generated families the property is deliberately stricter than the Goal: it does not excuse a flip whose plain form is OK on main. D5 protects exactly such incidental coverage, so excusing it would leave the D5 control with nothing to find.
  - **Positive controls, in code.** The script copies the library to a temp directory once per control, disables exactly one rule by a unique text replacement (asserted unique), and re-runs the same seed until the first regression:
    - the whole word-boundary rule;
    - only its escaped-delimiter half;
    - the D5 check.
  - **Self-checking.** The script exits nonzero unless all of these hold:
    - the real run has 0 regressions;
    - the slot ran at least once;
    - every control found a regression.
    The test only checks that exit status.
  - **Measured on the final spike:**

    | Run | Lexer accepted | Slot ran | Regressions |
    |---|---|---|---|
    | seed 889, N=1000 | 453 | 365 | 0 |
    | seed 1013, N=3000 | 1,380 | 1,198 | 0 |
    | seed 7, N=3000 | 1,371 | 1,169 | 0 |

    The reference matched the real pre-change file on every slot-ran command in all three runs (0 mismatches).

    **Controls.** Each control runs until its first regression, with a budget of 5×N generated commands. The escaped-delimiter shape is rare (about 9 in 3,000): with only N it missed once on seed 889, after a generator change shifted the random stream. A control that finds nothing within its budget fails the test. At N=1000 every control fired on seeds 889, 1013 and 7, and the number below is slot runs before the first regression:

    | Control | seed 889 | seed 1013 | seed 7 |
    |---|---|---|---|
    | word-boundary rule off | 13 | 73 | 19 |
    | escaped-delimiter check off | 418 | 264 | 16 |
    | D5 off | 4 | 1 | 7 |

    The first regressions are the D4 `declare -i`/`let` concatenation, the round-4 `\(` shape, and a scalar bound span (`${!n}`, `${P}`). One N=1000 run with its controls takes 33–60s.
- **CI budget.** `scripts/ci/run-shell-tests.sh` kills a suite after `SHELL_TEST_TIMEOUT` (default 180s). Both oracles therefore live in their own file, `tests/test-marker-flatten-quotes-889-oracle.sh`, with fixed seeds: span oracle N=5000 with its control (about 13s), and verdict oracle N=1000 with its three controls (33–60s; 86s with the spike-only reference check). That is under 90s together, against the 180s `SHELL_TEST_TIMEOUT`. The verdict rows stay in the fast main suite. Both new files get a `scripts/ci/shell-test-durations.tsv` entry with their duration measured locally (rounded up to whole seconds; the file's header says CI-measured values refresh it later), so `run-shell-tests.sh --shard` balances them. The larger runs above are reproducible offline by raising N through the script's argument.
- **Bound:** the 60KB flood rows assert a verdict within the existing budget. They include the bound-span floods `P='x'; `, `P='a (b) | c'; `, `--o='x' `, `a=('x'); ` and `P='echo x'; ` (each a quadratic trigger before the D3 window and the D5 cap; now 0.2–0.8s against main's 0.14–0.30s).

`./scripts/gate-integrity.sh --update` regenerates `.gate-integrity.lock`, since `marker_check.py` is pinned.

## Coordination

- Open PR #731 (#639, stale since 2026-08-22) adds code at the top of `_helper_invoked`, not in the flatten block. A rebase of it will need to reconcile line numbers only.
- The #889 wrapper side (#1018) is merged. #1016 (#947) left #889's piped-producer repros as its residual R5, which this change addresses.

## Residuals (accepted)

- **R1.** A command that carries a comment, a heredoc, a backtick, `((`, `$'`, or a continuation keeps today's verdict, including the two shipped pr-grind blocks. Follow-up issue: comment modelling for the flatten.
- **R2.** Only depth 0 is affected. A literal span inside a re-entered `sh -c` payload is read the old way.
- **R3.** `$`-bearing double-quoted payloads (`"$(sh -c "$Y …")"`) keep #1013's verdict.
- **R4.** A kept span whose text contains `$(` or a backtick (for example `node -e '… "$(" …'` or a JS template literal) still over-blocks, through D4's re-flatten. That is the price of D4.1, and it is accepted.
- **R5.** A command with an escaped quote outside a kept span keeps today's verdict (D3).
- **R6.** Some harmless commands still bail and keep today's reading. All of them only over-block, and none is claimed by the Goal:
  - spans glued to plain word characters (`p'ython3'`, `--opt"x"`);
  - an argument that happens to be the word `case` inside a `$(…)`;
  - `${a[0]}`-style expansions;
  - a redirect glued to a span (`'x'2>/dev/null`), since `2` is not a boundary character;
  - a scalar append `NAME+='…'`, since the D3 prefix rule has no `+=`.
- **R7.** The rest of the ADR 0006 execute-a-string class (Goal): a helper run only because bash later expands data the command stored or transported outside D5's bound positions. That covers `read`/`mapfile`/`while read`/herestring input into a variable, `set --` positional parameters, `printf -v` values, files, and array elements reached only through indirection outside a compound assignment. Main's coverage of these is incidental: it is OK on the plain forms and blocks a variant only when a `(` or newline in the dropped quotes forms a fake subshell or line, which is the #889 mechanism itself. Chasing them would re-break the repros. Pinned as rows at their current verdict.
- **R8.** A helper run by a non-shell interpreter from a payload in its own language (`python3 -c`, `node -e`, `ruby -e`, `php -r`, `awk` `system()`) goes from BLOCK to OK when it sits beside an unrelated `$(…)`. Main is already OK on the plain form; its BLOCK beside a `$(…)` comes only from the dropped quotes turning the payload's `(` into a fake subshell, the very misreading #889 removes. This is the pre-existing KNOWN RESIDUAL in `marker_check.py` (the producer scan reads payloads as shell text). Closing it means treating such interpreters as opaque, a policy change of its own. Pinned as rows at OK.
- **R9.** Other commands, builtins or programs, that run an argument as shell text, which main's probes do not recognise as string executors. Beside an unrelated `$(…)` they flip from BLOCK to OK, and main returns OK for the plain form of every one measured, so main never guarded them. Closing them is a classifier change about which commands count as string executors (the producer probe's table), not about quoting. R9 is recorded, not tested here: its shapes are held in private tracking with the pre-existing issues they belong to, and any rows belong to the change that decides that table.

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
