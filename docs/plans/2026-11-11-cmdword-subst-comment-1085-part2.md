# cmdword Substitution and Comment Reading (#1085) — Part 2 of 2 Implementation Plan

<!-- design-reviewed: PASS -->

> **For agentic workers:** REQUIRED SUB-SKILL: Use busdriver:subagent-driven-development (recommended) or busdriver:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the design gate's Bash classifier (`cmdword.is_file_mod`) block the writes that bash performs behind a substitution closer, a comment, or an ANSI-C-quoted program in the spellings Task 3's rows and fuzz exercise, as specified in `docs/specs/2026-11-10-cmdword-subst-comment-1085-design.md`. It narrows #1085 and does not close it (Deviation 12). Other spellings of the same class stay open in #1101, Deviation 4's heredoc-body class in #1093, and the items under Out of scope in #1094 and #1095. Refs #1085; the PR names #1093, #1094, #1095 and #1101.

**Architecture:** Part 1 (PR #1091, merged) moved marker_check's shell lexer into `hooks/gate-scripts/lib/shell_lex.py` unchanged, with fail-closed row B9. This part teaches that lexer process substitution (`<( )` / `>( )`), then in cmdword classifies the extra substitution bodies the lexer finds at every depth (spec B), and adds a third, bash-faithful reading of the whole command that runs when the command contains a `#` or a `$` (spec C). It guards the gate's `is_file_mod` call so an exception blocks (spec D, row B10). Every change only adds blocks.

**Tech Stack:** Python 3 (stdlib only), bash, the existing shell test harness (`tests/test-*.sh`, `scripts/ci/run-shell-tests.sh`).

**Global Constraints:**
- No new dependencies. Python stdlib only; `shell_lex.py` keeps importing only `re`.
- **Additive only.** No change may turn a block into an allow on `main`'s corpus or fuzz. The prototype that this plan transcribes measured 0 such flips; any task that reintroduces one stops the plan.
- **Every edit under `hooks/gate-scripts/**` needs `./scripts/gate-integrity.sh --update`** before the branch is reviewed (`.gate-integrity.lock`, #742). Each task regenerates before it commits. If the update refuses because of stale bytecode, delete `hooks/gate-scripts/lib/__pycache__/*.pyc` (the remedy the tool names) and rerun it.
- The gate's inline classifier in `pre-implementation-gate.sh` is a single-quoted bash string: Python added there must contain **no `'` character**, comments included.
- Fixtures that prove a write must **execute it under bash ≥ 5** in a scratch tree first. The bash on macOS `/bin/bash` is 3.2; select bash 5 explicitly and **fail, not skip,** when none exists.
- Full suites (`npm test`, `scripts/test-python.sh`, the full shell-suite sweep) run on UM through `um-run`; a local hook refuses them on the Mac. Single named suites run locally.
- Every verification loop below must exit non-zero when any command in it fails: they collect a `failed` flag and end with `[ "$failed" -eq 0 ]`.
- Conventional Commits; commit-message footer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. The litmus pre-commit gate runs on every commit.
- Reference prototype (already measured, not part of the repo): `/private/tmp/claude-501/-Volumes-Work-Projects-busdriver/2ff33c5d-419a-4cf4-a15c-2c0b4712a5bc/scratchpad/m1085/spike14lib.py` run with `SPIKE_BASE=spike15lib PROCSUB_GUARD=0 PROCSUB_WS=1`, which is `spike15lib.py` (source patches over today's `cmdword.py`) plus Task 1's `<( )` bodies in `_subst_bodies`. The code below is those patches written out in place, minus two dead pieces the prototype carried (`_quoted_comments`, the `_HDON` switch). The prototype predates part 1: it reads the lexer out of `marker_check.py`, so it no longer loads on this branch, and no step depends on it. The stops are this plan's own checks: the fuzz baseline (Task 3 Step 5) and the corpus check (Task 5 Step 4).

**Deviations from the spec, decided here:**
1. Spec "Timing ceiling" says each adversarial input must return "a block decision". The inputs have benign tails, so the hook allows most of them. The test asserts that the hook **emits a decision** (block or allow) within 4.0 s, which is the property the spec's Performance section argues for.
2. Spec names the new fail-closed rows B7 and B8. Those labels are taken in `tests/test-gate-classifier-fail-closed.sh`; the new rows are **B9** (landed in part 1) and **B10** (Task 4 here).
3. Items the final design-review round asked to be written down (they hold in the prototype; this plan pins each with a test): a literal newline inside `$'…'` (the third reading gives it the quoted-newline placeholder in the `$'…'` span itself, Step 4e: the `_ansi_c(cmd)` respelling alone does not cover it, because `_decode_escapes` leaves `\c` and `\n` undecoded, so `$'echo # a\c<newline>\nrm -rf src'` was allowed); `"r\<newline>m"` inside double quotes; the placeholder is U+0000 and is restored to a newline **before** `_requote_ansi_c` decodes `$'…'`, so the NUL that ends a decoded `$'…'` body can only come from an escape; a raw NUL byte reads as a newline once comments are defused, so inside a quoted program it ends that program's comment (bash would end the command there, so this can only reveal text; pinned in-process, since the hook's stdin cannot carry a NUL); the depth-0-only "unreadable blocks" rule is justified in a code comment at the branch (derived strings at depth ≥ 1 — a body `_subst_end` cut short, or `_ansi_c`'s respelling — are not the command as written, and blocking on them blocked read-only commands such as `: "$(echo ${v%)})"` and `echo $'it\'s'`).
4. Out of scope, filed as #1093: **writes that can only be seen by reading inside a heredoc body.** Every known member writes under bash 5:
   - **An apostrophe in a heredoc body.** The gate's quote handling pairs that `'` with a later quote, so everything between reads as quoted. Allowed on `main` and here: a redirect-only write after the body, then a later closed quote (`cat <<E` / `it's` / `E` / `echo x > src/f` / `echo 'y'`), with or without a `#` or `$`, and the same inside `$( )`; an `rm` after the body inside a program passed to `bash -c` or `eval` that ends in an unclosed quote (`cat <<E` / `it's` / `E` / `rm -rf src` / `echo '`, shell-quoted as one argument); and a top-level `rm` followed by a second heredoc body whose apostrophe closes the quote again (`cat <<E` / `it's` / `E` / `rm -rf src` / `cat <<E2` / `don't` / `E2`). The top-level `rm` with one such body is blocked on `main`.
   - **A substitution closer inside an expanding heredoc body** (`cat <<E` / `: "$(echo ${v%)}; rm -rf src)"` / `E`). Allowed on `main` and here: `shell_lex` skips every heredoc body and `_command_substitutions` cuts the body at `${v%)}`. The plain `$(rm -rf src)` in a body is already blocked on `main`, and the `echo x > src/f` spelling is blocked by the gate's raw redirect check.
   - **The lexer giving up inside a `bash -c` / `eval` program.** Task 2 Step 7 blocks an unreadable command at depth 0 only (Deviation 3), but a program handed whole to another shell runs as written. Task 1 Step 2 fixes the trigger reviewers found, an ANSI-C heredoc delimiter with a simple or control escape (`<<$'E\tF'`, `<<$'E\cIF'`). A delimiter spelled as UTF-8 byte escapes (`$'E\xc3\xa9'`) still decodes to code points rather than bytes, so it never closes; `main` already blocks the `rm` and redirect spellings behind it inside `bash -c`. That spelling and the depth rule itself stay open in #1093.

   This plan opens none of them, and the PR states each as open in #1093 rather than widening the readings here: closing them needs a heredoc-body reading of its own, with its own edge cases (`<<-` tab stripping, continuations in bodies, nested heredocs).
5. Spec Residuals says CR read as a newline "can only add blocks". It can also hide text: bash reads CR as a word character, so `echo <CR>#; rm -rf src` runs the rm while a CR-as-newline reading sees a comment. The third reading and `_lex_bodies` therefore keep CR as a word character (Task 2 Steps 5 and 7); the first two readings are unchanged. Rows pin both spellings and CRLF controls.
6. Spec Tests fixes the timing set at 19 padding units (76 inputs, 68 timed). The fixture adds a 20th, `"# "` (the repeated-`#` shape a review measured as quadratic), so it is 80 inputs and 72 timed.
7. The `<( )` change in Task 1 lives in the shared lexer but is behind the cmdword-only switch (Deviation 11), so marker_check reads `<(` as `main` does. Ungated, it removed a marker_check block: with the `_param_span` arm, `: "$(echo ${v:-<(# it's<newline>true)}; echo lease_slot.py)"` became readable, and marker_check lost the give-up block it has on `main` (#1085 round 8). Task 1 Step 3 pins that command's block.
8. Spec Tests names the fuzz driver `tests/fixtures/fuzz-1085.py`. A hyphenated name cannot be imported, and the corpus check (Task 5 Step 4) imports it, so it is `tests/fixtures/cmdword_1085.py` and holds the rows and timing modes too.
9. **Size cap on the third reading (not in the spec).** The third reading roughly doubles cmdword's time on long commands holding `$`: on #553's "64 openers and 60k filler" case, cmdword plus marker_check went from 1.82–1.86 s on `main` to 2.81–2.83 s, against #553's 3.0 s bound for the 5 s hook deadline, past which the harness reads no decision as ALLOW. So a command longer than `_LEX_READING_MAX` = 32768 characters that holds a `#` or `$` blocks without the third reading (Task 2 Steps 3 and 8). That is additive and fail-closed. Over-block cost: none of 38,492 distinct local commands was longer than 18,755 characters, so none is affected. The timing set is built just under the cap, where the third reading's cost is highest, and one row pins the cap itself. #553's budget is left unchanged. Measured with the cap applied to the full patch (one Mac, best of 3, cmdword plus marker_check): "64 openers and 60k filler" 2.10 s (blocks), "64 closers after 65k filler" 1.22 s, the same openers cut to 32,760 characters (under the cap, third reading runs) 1.55 s. The rest of the 0.25 s over `main` is spec B's extra bodies, which run at every length.
10. Spec "Timing ceiling" fixes 4.0 s. On a GitHub runner the limit is 10.0 s, the same 2.5× calibration #553 uses (`tests/test-impl-gate-scope-553.sh`, keyed on `GITHUB_ACTIONS == "true"` only). The local 4.0 s stays the meaningful number.
11. Every change Task 1 makes to the shared lexer sits behind one switch, `shell_lex._cmdword_on`, off by default. Only `cmdword.is_file_mod` turns it on, for the length of its call (Task 2 Step 8), so every lexer scan cmdword makes reads the same way and marker_check reads as on `main`. Under it: `<( )` / `>( )` bodies in `_subst_bodies` and `_param_span` (Step 1), the full `$'…'` delimiter decode, and line continuations in a heredoc operator and word (Step 2). Each could remove a marker_check block, since several of its blocks exist only because a scan gives up: `: "$(cat <<$'E\tF'` / `hello` / `E<TAB>F` / `echo lease_slot.py)"` is one, and Deviation 7's command another. Task 1 Step 3 asserts each piece with the switch off, and the corpus check compares marker_check on every command holding `<(` or `>(` (Task 5 Step 4).
12. **Scope: Refs #1085, not Closes.** Eight review rounds each found three to five new spellings of the same class: bash runs a write, and a misread comment, quote or heredoc hides it. Almost all were allowed on `main` too. This plan blocks the spellings Task 3 pins and claims no more. Spellings found in review that `main` also allows and this plan does not pin are tracked in #1101: a `#` inside a `${…}`, `$( )` or backtick nested in double quotes (`echo "${v:-" #"}"; rm -rf src`); a standalone `(( 1 << 2 ))` read as a heredoc inside a `bash -c` program; and a top-level redirect between two comments whose apostrophes pair up (`echo # '` / `echo x > src/f` / `echo # '`). A finding of that shape is a new member of #1101, not a reason to widen this plan. A block→allow flip against `main` (Global Constraints) is still a stop.

---

## File Structure

| File | Responsibility |
|---|---|
| `hooks/gate-scripts/lib/shell_lex.py` | `_subst_bodies` also returns `<( )` / `>( )` bodies, and `_param_span` skips them inside `${…}` (Task 1). Shared by marker_check and cmdword. |
| `hooks/gate-scripts/lib/cmdword.py` | Spec B (`_lex_bodies`, extra bodies in `_is_file_mod`) and spec C (`_lex_reading`, the third reading's normalization, `$'…'` decoding, header regex). |
| `hooks/gate-scripts/pre-implementation-gate.sh` | Spec D: `try/except` around the `is_file_mod` call. |
| `tests/fixtures/cmdword_1085.py` (new) | All #1085 checks in one Python driver: `rows` (reproducers and controls through the real hook), `fuzz` (generator + in-process oracle), `timing` (real hook just under the third reading's 32k cap, plus one row over it). |
| `tests/test-cmdword-subst-comment-1085.sh` (new) | Thin shell suite: builds an armed throwaway repo, runs the three fixture modes, aggregates. |
| `tests/test-escaped-dollar-1048.sh` | Strips `_lex_reading` branches before comparing `_requote_ansi_c`; one `_bash_ansi_c` behaviour row. |
| `tests/test-gate-classifier-fail-closed.sh` | B10. |
| `scripts/ci/run-shell-tests.sh` | Per-test timeout override for the new suite. |
| `.gate-integrity.lock` | Regenerated. |

---

### Task 1: Process-substitution bodies and ANSI-C heredoc delimiters in `shell_lex`

**Files:**
- Modify: `hooks/gate-scripts/lib/shell_lex.py` (`_subst_bodies`, `_param_span`, `_heredoc_delim`, new `_bash_ansi_c`)

**Interfaces:**
- Consumes: `shell_lex._subst_body_end` (part 1).
- Produces: `shell_lex._subst_bodies(s) -> (list[str], bool)`, signature unchanged; it now also returns `<( )` / `>( )` bodies, and `_param_span` skips a `<( )` / `>( )` inside `${…}` whole. New `shell_lex._bash_ansi_c(body) -> str`, which Task 2 reuses, `shell_lex._past_cont(s, j) -> int`, and the switch `shell_lex._cmdword_on: list[bool]` (default off). Every change in this task acts only while it is on: `<( )` / `>( )` bodies, `$'…'` heredoc delimiters decoded with bash's full escape set, and line continuations joined in a heredoc operator and word. Only `cmdword.is_file_mod` turns it on (Task 2 Step 8), so marker_check is unchanged (Deviations 7 and 11).

- [ ] **Step 1: Add the `<( )` / `>( )` arm**

In `hooks/gate-scripts/lib/shell_lex.py`, inside `_subst_bodies`, directly after the block

```python
        if ch == "$" and i + 1 < n and s[i + 1] == "(":
            j = _subst_body_end(s, i + 1)
            if j < 0:
                return out, False
            out.append(s[i + 2:j])
            i = j + 1
            continue
```

insert:

```python
        if ch in "<>" and _cmdword_on[0] and not in_d and not arith and s.startswith("(", i + 1):
            # cmdword only (_cmdword_on, Step 2): marker_check reads `<(` as text, as on main.
            # Process substitution: bash runs `<( )` and `>( )` bodies like `$( )`, and
            # finds their `)` the same way. Neither extractor returned them, so a body
            # behind `${v%)}` was cut short here too (#1085). Outside double quotes only,
            # where bash expands them; inside `(( ))` `<(` is a comparison. Inside `${…}`
            # it still runs (`echo ${v:-<(rm -rf src)}` writes), so param_end is not checked.
            j = _subst_body_end(s, i + 1)
            if j < 0:
                return out, False
            out.append(s[i + 2:j])
            i = j + 1
            ws = False           # `<(true)#$(…)` is one word: its `#` comments nothing
            continue
```

Extend the function's leading comment: `# (bodies, ok) for the $(...), backtick, <(...) and >(...) substitutions in s, …`.

`_param_span` needs the same arm, or a `}` inside a process substitution inside `${…}` closes the `${` early: `echo ${v:-<(# }<newline>true) #}; rm -rf src` runs the rm, and the span ended at the `}` in the comment, so the rest of the command read as one `#` comment (#1085 round 7). A `$(` there was already skipped through `_subst_body_end`; `<(` was plain text. In `_param_span`, directly after the arm

```python
        elif c == "$" and s.startswith("(", j + 1):
            e = _subst_body_end(s, j + 1, _depth + 1)
            e = None if e < 0 else e + 1
```

insert:

```python
        elif c in "<>" and _cmdword_on[0] and not (in_d or dq) and s.startswith("(", j + 1):
            # `${v:-<(# })}`: a process substitution runs inside `${…}` and its `}` is its own
            # (#1085). Inside double quotes `<(` is plain text, as in _subst_bodies. cmdword
            # only: for marker_check this arm turned a give-up block into OK (Deviation 7).
            e = _subst_body_end(s, j + 1, _depth + 1)
            e = None if e < 0 else e + 1
```

That is every arm `_param_span` lacked: its other arms already cover `${`, `$((`, `$(`, backticks, `$'…'` and quotes, and a heredoc, a comment or a `case` cannot start inside a parameter word.

- [ ] **Step 2: Decode `$'…'` heredoc delimiters as bash does**

`_heredoc_delim` decodes a `$'…'` delimiter with `_decode_escapes`, which knows only `\x`, `\u`, `\U` and octal. A delimiter spelled `$'E\tF'` or `$'E\cIF'` therefore never matched its closing line, the body swallowed the rest of the string and the lexer gave up. Inside a `bash -c` program that is depth 1, where Task 2 Step 7 does not block on a give-up, so both write kinds behind such a heredoc were allowed (#1085 round 5). In `hooks/gate-scripts/lib/shell_lex.py`, directly above `def _heredoc_delim(s, i):`, add:

```python
_BASH_ESC_RE = re.compile(r"\\(?:([abeEfnrtv\\'\"?])|x([0-9A-Fa-f]{1,2})|u([0-9A-Fa-f]{1,4})"
                          r"|U([0-9A-Fa-f]{1,8})|([0-7]{1,3})|c(\\\\|.))", re.S)   # `\c\\` takes both
_BASH_SIMPLE_ESC = {"a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f", "n": "\n",
                    "r": "\r", "t": "\t", "v": "\v", "\\": "\\", "'": "'", '"': '"', "?": "?"}


def _bash_ansi_c(body):
    """The body of a `$'...'` as bash decodes it: one left-to-right pass over bash's full
    escape set, an unknown escape kept as written, the string ended at a decoded NUL.
    _decode_escapes covers only what resolving a command word needs; the third reading
    needs `\\n` too, or `bash -c $'echo # x\\nrm -rf src'` reads as one comment (#1085)."""
    def _sub(m):
        if m.group(1):
            return _BASH_SIMPLE_ESC[m.group(1)]
        hexit = m.group(2) or m.group(3) or m.group(4)
        try:
            if hexit:
                return chr(int(hexit, 16))
            if m.group(5):
                return chr(int(m.group(5), 8) & 0xFF)
            c = m.group(6)[-1]                       # `\c\\` is control-backslash, 0x1C
            if c == "?":
                return chr(0x7F)
            # bash masks the first BYTE and keeps the rest: `\cĀ` is 04 80, not NUL.
            raw = c.encode("utf-8", "surrogatepass")
            return chr(raw[0] & 0x1F) + raw[1:].decode("latin-1")
        except ValueError:
            # `\U00110000` is past Unicode, but bash still emits bytes for it: deleting it
            # made `\U00110000#` a word-start comment and hid the rest of the line.
            return m.group(0)
    return _BASH_ESC_RE.sub(_sub, body).split(chr(0))[0]
```

The full decode is opt-in, so marker_check's reading does not change (Deviation 11). cmdword reaches the delimiter through many lexer entry points (`_subst_bodies`, `_join_continuations`, `_param_span`, `_backtick_span`, `_heredoc_delim`), and `_subst_body_end` and `_param_span` call each other, so a parameter cannot be threaded through all of them. The switch is a module flag instead, which `cmdword.is_file_mod` holds on for its whole call (Task 2 Step 8), the same pattern as cmdword's `_lex_reading`. Directly below the `_bash_ansi_c` block just added, add:

```python
_cmdword_on = [False]   # True while cmdword.is_file_mod runs: bash-exact reads marker_check skips


def _past_cont(s, j):
    """j moved past any line continuations, while cmdword classifies (_cmdword_on). Bash joins
    them before it reads a heredoc operator and its word: `<<\\<nl> EOF` and `<<E\\<nl>OF` both
    delimit on EOF. Read raw, the delimiter never closed and its body swallowed the rest of a
    `bash -c` program (#1085 rounds 7 and 8)."""
    while _cmdword_on[0] and s.startswith(chr(92) + chr(10), j):
        j += 2
    return j
```

and inside `_heredoc_delim` replace

```python
            d.append(_decode_escapes(s[j + 2:_e - 1]))
```

with

```python
            # Bash's whole escape set while cmdword classifies (_cmdword_on). Off for marker_check,
            # whose verdicts this must not change: its give-up on such a body is a block it keeps.
            d.append(_bash_ansi_c(s[j + 2:_e - 1]) if _cmdword_on[0] else _decode_escapes(s[j + 2:_e - 1]))
```

Then join line continuations in the operator and the word, as bash does. Replace

```python
    j = i + 2
    strip = j < len(s) and s[j] == '-'
    if strip:
        j += 1
    while j < len(s) and s[j] in ' \t':
        j += 1
```

with

```python
    j = _past_cont(s, i + 2)
    strip = j < len(s) and s[j] == '-'
    if strip:
        j = _past_cont(s, j + 1)
    while j < len(s) and s[j] in ' \t':
        j = _past_cont(s, j + 1)
```

then replace

```python
            if c == dq:
                dq = ''
            elif dq == chr(34) and c == chr(92) and j + 1 < len(s) \
```

with

```python
            if c == dq:
                dq = ''
            elif dq == chr(34) and _past_cont(s, j) > j:
                j += 1                     # `"E\<nl>OF"` is EOF too; inside '…' bash keeps it
            elif dq == chr(34) and c == chr(92) and j + 1 < len(s) \
```

and replace

```python
        if c == chr(92) and j + 1 < len(s):
            j += 1
            d.append(s[j])
```

with

```python
        if _past_cont(s, j) > j:
            j += 2                         # `<<E\<nl>OF` delimits on EOF
            continue
        if c == chr(92) and j + 1 < len(s):
            j += 1
            d.append(s[j])
```

No signature changes; `_decode_escapes` and every caller are unchanged.

- [ ] **Step 3: Run the marker and parity suites**

```bash
failed=0
for t in tests/test-marker-*.sh tests/test-ansic-quote-1043.sh tests/test-escaped-dollar-1048.sh \
         tests/test-gate-classifier-fail-closed.sh tests/test-herestring-receiver-643.sh \
         tests/test-brainstorming-oracle-wrapper-root.sh tests/test-design-marker-worktree.sh; do
  if bash "$t" >/dev/null 2>&1; then echo "pass $t"; else echo "FAIL $t"; failed=1; fi
done
python3 -I -c 'import json, os, subprocess, sys, tempfile; sys.path.insert(0, sys.argv[1]); import shell_lex
def on(f, *a):                     # as cmdword.is_file_mod runs it
    shell_lex._cmdword_on[0] = True
    try:
        return f(*a)
    finally:
        shell_lex._cmdword_on[0] = False
BS, NL, Q = chr(92), chr(10), chr(34)
assert on(shell_lex._subst_bodies, "cat <(rm -rf src) >(tee x)") == (["rm -rf src", "tee x"], True)
assert shell_lex._subst_bodies("cat <(rm -rf src) >(tee x)") == ([], True)   # switch off: as on main
assert on(shell_lex._subst_bodies, "echo " + Q + "<(rm x)" + Q) == ([], True)
p = "${v:-<(echo })}"
assert on(shell_lex._param_span, p, 0) == len(p)              # the procsub owns that }
assert shell_lex._param_span(p, 0) == 13                     # switch off: ends at that }, as on main
assert on(shell_lex._param_span, Q + p + Q, 1, True) == 14   # inside "…" it is text: ends at its }
for w in ("<<" + BS + NL + " EOF", "<<-" + BS + NL + " EOF", "<<E" + BS + NL + "OF", "<<" + Q + "E" + BS + NL + "OF" + Q):
    assert on(shell_lex._heredoc_delim, w, 0) == (("EOF", "-" in w), len(w)), w
    assert shell_lex._heredoc_delim(w, 0) != (("EOF", "-" in w), len(w)), w   # switch off: as on main
sq = "<<" + chr(39) + "E" + BS + NL + "OF" + chr(39)
assert on(shell_lex._heredoc_delim, sq, 0)[0][0] == "E" + BS + NL + "OF"   # inside single quotes bash keeps it
# marker_check keeps the block main has on this command (Deviation 7): run as the gate runs it.
c = ": " + Q + "$(echo ${v:-<(# it" + chr(39) + "s" + NL + "true)}; echo lease_slot.py)" + Q
with tempfile.TemporaryDirectory() as d:
    r = subprocess.run([sys.executable, "-I", os.path.join(os.path.abspath(sys.argv[1]), "marker_check.py")], cwd=d, text=True,
                       capture_output=True, input=json.dumps({"tool_name": "Bash", "cwd": d, "tool_input": {"command": c}}))
assert r.stdout.startswith("BLOCK_MARKER_SCRIPT"), r.stdout
for esc in ("t", "cI"):
    p = ": \"$(cat <<$" + chr(39) + "E" + chr(92) + esc + "F" + chr(39) + chr(10) + ")" + chr(10) + "E" + chr(9) + "F" + chr(10) + "rm -rf src)\""
    shell_lex._cmdword_on[0] = True
    bodies, ok = shell_lex._subst_bodies(p)
    shell_lex._cmdword_on[0] = False
    assert ok and any("rm -rf src" in b for b in bodies), (esc, bodies, ok)
    assert shell_lex._subst_bodies(p) == ([], False), esc   # switch off: marker_check reading unchanged
assert shell_lex._bash_ansi_c(chr(92) + "x23 a" + chr(92) + "nb") == "# a" + chr(10) + "b"
print("procsub ok")' hooks/gate-scripts/lib || failed=1
[ "$failed" -eq 0 ]
```

Expected: every line `pass …`, then `procsub ok`, exit 0. Each new arm is asserted twice: with the switch on, as cmdword runs it, and off, where it must read as `main` does. The `<(rm x)` assert is the double-quote control: bash does not expand `<(` inside `"…"`, and the third `_param_span` assert pins the same rule. The heredoc asserts pin the continuation joins: before the word, after `<<-`, inside the word and inside double quotes, while inside single quotes bash keeps the backslash and the newline, so the delimiter does too. The marker_check run pins Deviation 7: the command blocks on `main`, and ungated the `_param_span` arm made it `OK`. The loop asserts that with the switch on a `$'E\tF'` and a `$'E\cIF'` delimiter close on their `E<TAB>F` line, so the `rm` after the heredoc is a body the lexer returns, and that with it off (marker_check) the result is the old give-up. A failing marker suite means the new arm changed a verdict the suite pins. Check the inserted code against Step 1 before changing anything.

- [ ] **Step 4: Regenerate the lock and commit**

```bash
./scripts/gate-integrity.sh --update
git add hooks/gate-scripts/lib/shell_lex.py .gate-integrity.lock
git commit -m "fix(gate): the shared lexer reads process-substitution bodies and ANSI-C heredoc delimiters (#1085)" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: cmdword — extra bodies (spec B) and the third reading (spec C)

**Files:**
- Modify: `hooks/gate-scripts/lib/cmdword.py` (anchors as of `main`: imports :42-44, `_FUNC_DEF_RE` :375, `_defuse_comments` :2401-2517, `_ansi_c_reading` :2524, `_requote_ansi_c` :2629-2679, `_normalize` :2682-2722, `is_file_mod` :4664, `_is_file_mod` :4680-4740)
- Modify: `tests/test-escaped-dollar-1048.sh` (the `_requote_ansi_c` comparison)

**Interfaces:**
- Consumes: `shell_lex._subst_bodies`, `shell_lex._join_continuations`, `shell_lex._param_span`, `shell_lex._backtick_span`, `shell_lex._heredoc_delim`, `shell_lex._heredoc_body_end`, `shell_lex._arith_closes`, `shell_lex._paren_matches` (part 1, PR #1091; `_subst_bodies` with Task 1's `<( )` bodies).
- Produces: `is_file_mod(cmd, _depth=0) -> bool` (signature unchanged); new module globals `_lex_reading: list[bool]`, `_lex_bodies(cmd, seen) -> (list[str], bool)`, `_bash_ansi_c(body) -> str`, `_FUNC_DEF_LEX_RE`.

- [ ] **Step 1: Import the lexer**

After `import shlex` (line 44) add:

```python
import os
import sys

# shell_lex sits next to this file (#1085). The gate puts lib/ on sys.path before importing
# cmdword, but the self-check `python3 -I cmdword.py` does not: -I leaves the script's own
# directory off the path. Added after the stdlib imports above, so lib/ cannot shadow them.
_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
import shell_lex  # noqa: E402
```

Then check: `grep -n "^import os\|^import sys" hooks/gate-scripts/lib/cmdword.py` shows each once (remove a duplicate if cmdword already imports either at module level).

- [ ] **Step 2: The third reading's header regex**

Directly after the `_FUNC_DEF_RE = re.compile(...)` statement (line 375-376) add:

```python
# The third reading (#1085) drops fewer headers: a name holding a backtick, backslash, quote or
# `$` is not a name bash would define, and _FUNC_NAME allowed all of them. In a quoted program
# not yet decoded, ``echo `echo )`\nf() { :; }`` (with `\n` still two characters) let it take
# `` `\nf() `` as a header and delete the closing backtick, unbalancing the rest of the
# program and hiding the write after it. Dropping less leaves more to classify.
_FUNC_DEF_LEX_RE = re.compile(_FUNC_DEF_RE.pattern.replace(_FUNC_NAME, r"[^\s;&|()<>{}`\\'\"$]+"))
if _FUNC_DEF_LEX_RE.pattern == _FUNC_DEF_RE.pattern:
    raise RuntimeError("_FUNC_DEF_LEX_RE: _FUNC_NAME not found in _FUNC_DEF_RE")
```

(An import-time error makes the gate fall back to `FILE_MOD_PATTERNS`, the wider classifier.)

- [ ] **Step 3: The `_lex_reading` flag**

Directly after `_ansi_c_reading = [False]` (line 2524) add:

```python
# The bash-faithful THIRD reading (#1085), for is_file_mod only, OR-ed like the second and
# set together with _ansi_c_reading. It runs the comment defuser on UNJOINED text, keeps
# newlines inside quotes, copies `${…}`, backticks, `$((…))` and heredoc bodies whole, drops
# the backslash bash drops from `\$` inside double quotes, decodes `$'…'` with bash's full
# escape set, and drops fewer function headers. See is_file_mod for when it runs.
_lex_reading = [False]
# Longest command the third reading runs on (#1085, Deviation 9). Longer ones that hold a `#`
# or `$` block instead: see is_file_mod. A 38,492-command local corpus peaked at 18,755.
_LEX_READING_MAX = 32768


def _brace_after(s, k):
    """Index of the `{` at s[k] past any line continuations, or -1."""
    while s.startswith(chr(92) + chr(10), k):
        k += 2
    return k if s.startswith("{", k) else -1
```

- [ ] **Step 4: `_defuse_comments` — the third reading's rules**

All edits are inside `_defuse_comments`. Each is guarded by `_lex_reading[0]`, so the first and second readings are byte-for-byte unchanged.

4a. Replace

```python
    group = []                            # one bit per open paren: subshell or substitution
    i, n = 0, len(s)
    while i < n:
        ch = s[i]
        if esc:
```

with

```python
    group = []                            # one bit per open paren: subshell or substitution
    pending = []                          # third reading: heredocs whose bodies start at the next newline
    i, n = 0, len(s)
    while i < n:
        ch = s[i]
        if (_lex_reading[0] and not (esc or in_s or in_d)
                and s.startswith(chr(92) + chr(10), i)):
            # A continuation: joined after this pass, and invisible to word position, so
            # `x \<nl># c` stays a comment and `a\<nl>#b` stays a word.
            out.append(s[i:i + 2])
            i += 2
            continue
        if esc:
```

4b. Replace the `in_s` and `in_d` branches

```python
        elif in_s:
            out.append(ch)
            if ch == _SQ:
                in_s = False
            word = False
        elif in_d:
            out.append(ch)
            if ch == chr(92):
```

with

```python
        elif in_s:
            # Third reading: a newline inside quotes may be a newline in a `bash -c` / `eval`
            # program, where it ends a comment. A U+0000 placeholder survives _normalize's
            # newline-to-`;` rewrite and is restored to a newline right after it.
            out.append(chr(0) if _lex_reading[0] and ch == chr(10) else ch)
            if ch == _SQ:
                in_s = False
            word = False
        elif in_d and _lex_reading[0] and ch == chr(92) and s[i + 1:i + 2] == "$":
            # bash drops this backslash inside double quotes and shlex keeps it, so a
            # program's `\$((1<<2))` read as `<<2`, a heredoc that swallowed the rest (#1085).
            # Not `` \` ``: dropping that made read-only `grep "…\`…"` patterns substitute.
            out.append("$")
            i += 2
            word = False
            continue
        elif in_d:
            out.append(chr(0) if _lex_reading[0] and ch == chr(10) else ch)
            if ch == chr(92):
```

4c. Replace

```python
        elif ch == _DQ:
            out.append(ch)
            in_d = True
            word = False
        elif ch == "#" and out and out[-1] == ")":
```

with

```python
        elif ch == _DQ:
            out.append(ch)
            in_d = True
            word = False
        elif _lex_reading[0] and (ch == "$" and _brace_after(s, i + 1) >= 0 or ch == chr(96)):
            # `${v%<<E #}` and `` `echo # ` `` hold no comment: copied whole, unread. A newline
            # inside gets the U+0000 placeholder: `"echo # x "${v:-'<nl>rm -rf src'}` hands a
            # newline to bash -c, and as ` ; ` it sat inside the program's comment (#1085).
            j = (shell_lex._param_span(s, _brace_after(s, i + 1) - 1) if ch == "$"
                 else shell_lex._backtick_span(s, i))
            if j is None:
                _paren_hash_ambiguous[0] = True   # no end found: the raw whole-command scan
                out.append(ch)
                word = False
            else:
                out.append(s[i:j].replace(chr(10), chr(0)))
                i = j
                word = False
                continue
        elif _lex_reading[0] and ch == chr(10) and pending:
            # The bodies of the heredocs opened on this line, copied whole, so an apostrophe
            # in a body does not flip the defuser's quote state (that is all the copy protects:
            # _normalize still hands the body to shlex). Third reading only. (A redirect-only
            # write after such a body is NOT caught: neither this
            # reading nor the gate's raw redirect check sees it, on main or here. That
            # heredoc-apostrophe class is tracked in #1093.)
            out.append(ch)
            k = i + 1
            for d in pending:
                e = shell_lex._heredoc_body_end(s, k, [d])
                out.append(s[k:e])
                k = e
            i, pending, word = k, [], True
            continue
        elif _lex_reading[0] and s.startswith("<<<", i):
            out.append("<<<")                     # a herestring, not a heredoc
            i += 3
            word = True
            continue
        elif _lex_reading[0] and s.startswith("<<", i) and shell_lex._heredoc_delim(s, i):
            hd = shell_lex._heredoc_delim(s, i)  # continuations joined: see shell_lex._past_cont
            pending.append(hd[0])
            out.append(s[i:hd[1]])
            i = hd[1]
            word = True
            continue
        elif _lex_reading[0] and s.startswith("$((", i) and shell_lex._arith_closes(s, i):
            e = shell_lex._paren_matches[1][i + 1] + 1   # `$((1<<2))` holds no heredoc
            out.append(s[i:e])
            i, word = e, False
            continue
        elif ch == "#" and out and out[-1] == ")":
```

4d. Replace the comment-blanking line

```python
                out.append(" " if s[i] in ";&|()" + _SQ + _DQ else s[i])
```

with

```python
                out.append(" " if s[i] in ";&|()" + _SQ + _DQ
                           + (chr(92) if _lex_reading[0] else "") else s[i])   # `#…\` joins nothing
```

4e. In the `$'…'` branch (the one commented `The second reading only -- see _ansi_c_reading.`), replace

```python
            j = _ansi_c_span(s, i)
            out.append(s[i:j])
```

with

```python
            j = _ansi_c_span(s, i)
            # Third reading: a literal newline inside `$'…'` gets the same U+0000 placeholder
            # as one inside `'…'`. Rewritten to ` ; ` by _normalize, it turned `\c<newline>` into
            # `\c `, which decodes to NUL and cut the program off before its verb (#1085).
            out.append(s[i:j].replace(chr(10), chr(0)) if _lex_reading[0] else s[i:j])
```

- [ ] **Step 5: `_normalize` — order of operations in the third reading**

Replace

```python
    norm = cmd.replace("\r\n", "\n").replace("\r", "\n")
    norm = norm.replace(chr(92) + chr(10), "")
    norm = _defuse_comments(norm)  # BEFORE newlines become separators -- see the docstring
    norm = norm.replace("\n", " ; ")
```

with

```python
    # In the third reading CR stays a word character, as in bash: as a newline it made the
    # `#` of `echo <CR>#; rm -rf src` a comment and hid the rm (#1085).
    norm = cmd if _lex_reading[0] else cmd.replace("\r\n", "\n").replace("\r", "\n")
    if _lex_reading[0]:
        # Third reading (#1085): defuse BEFORE joining, because bash ends a comment at the
        # newline even after `#…\`; then the heredoc-aware join. A `$` followed by a
        # continuation defeats _param_span (it sees a nested `${` only when `{` follows `$`
        # directly), so such a command takes the raw whole-command scan instead.
        if "$" + chr(92) + chr(10) in norm:
            _paren_hash_ambiguous[0] = True
        norm = shell_lex._join_continuations(_defuse_comments(norm))
    else:
        norm = norm.replace(chr(92) + chr(10), "")
        norm = _defuse_comments(norm)  # BEFORE newlines become separators -- see the docstring
    norm = norm.replace("\n", " ; ")
    if _lex_reading[0]:
        # chr(0) is the third reading's in-quote newline, restored BEFORE _requote_ansi_c
        # decodes `$'…'`, so a NUL there can only come from an escape. A raw NUL in a command
        # reads as a newline too, in this reading only; bash would end the command there, so
        # this can only reveal text. The first and second readings are untouched.
        norm = norm.replace(chr(0), chr(10))
```

Then replace

```python
    norm = _FUNC_DEF_RE.sub(r"\1", norm)
```

with

```python
    _fdr = _FUNC_DEF_LEX_RE if _lex_reading[0] else _FUNC_DEF_RE
    norm = _fdr.sub(r"\1", norm)
```

and, a few lines below, `for m in _FUNC_DEF_RE.finditer(` with `for m in _fdr.finditer(`.

`_normalize` now raises `_paren_hash_ambiguous` itself (the `$\<newline>` check above), so in `_is_file_mod` replace the comment line

```python
    # `_paren_hash_ambiguous` is written only by _defuse_comments (inside _normalize) and
```

with

```python
    # `_paren_hash_ambiguous` is written only by _normalize and the _defuse_comments it calls, and
```

- [ ] **Step 6: `$'…'` decoded as bash decodes it**

`_bash_ansi_c` itself is added to `shell_lex` in Task 1 Step 2. Directly above `def _requote_ansi_c(s):` add:

```python
# Lives in shell_lex since Task 1, which decodes heredoc delimiters with it: one copy.
_bash_ansi_c = shell_lex._bash_ansi_c
```

Inside `_requote_ansi_c`, replace

```python
            out.append(_SQ + s[i + 2:j - 1].replace(chr(92) + _SQ, _SQ + chr(92) + _SQ + _SQ)
                       + _SQ)
```

with

```python
            if _lex_reading[0]:
                # Third reading: decoded in full (#1085), every `'` then respelled `'\''`.
                out.append(_SQ + _bash_ansi_c(s[i + 2:j - 1]).replace(
                    _SQ, _SQ + chr(92) + _SQ + _SQ) + _SQ)
            else:
                out.append(_SQ + s[i + 2:j - 1].replace(chr(92) + _SQ, _SQ + chr(92) + _SQ + _SQ)
                           + _SQ)
```

The `if _lex_reading[0]:` statement form (not an inline conditional) matters: Step 9's parity test strips exactly such `if` statements.

- [ ] **Step 7: `_lex_bodies` and spec B in `_is_file_mod`**

Directly above `def is_file_mod(` add:

```python
# A `#` at a WORD START. Never `${v#x}` or `$#`.
_WORD_HASH_RE = re.compile(r"(?:^|[\s;&|()<>`])#")


def _comment_cont_copy(c):
    """c with the line-ending backslash of every line that holds a word-start `#` replaced by
    a space, or None when there is none. Line by line, so linear: an unanchored regex retried
    `#[^\\n]*` at every `#` on a line without a continuation, quadratic on `# ` padding."""
    lines = c.split("\n")
    hit = False
    for k in range(len(lines) - 1):
        if lines[k].endswith("\\") and _WORD_HASH_RE.search(lines[k]):
            lines[k] = lines[k][:-1] + " "
            hit = True
    return "\n".join(lines) if hit else None


def _lex_bodies(cmd, seen):
    """(bodies, ok): substitution bodies shell_lex finds in cmd that `seen` lacks (#1085).

    _command_substitutions ends a body at a `)` bash never reads as a closer -- inside `${ }`,
    a comment, a heredoc body or `$'…'` -- and so never reads what follows. shell_lex models
    those. Where a `#…\\<nl>` line is present, it also reads a copy with that backslash
    replaced: the plain run joins the line (right if the `#` is text), the copy ends the
    comment at the newline (right if it is a comment, as bash ends it). A regex cannot tell
    which; one of the two is always right. ok is False when EITHER run gave up. CR is left
    a word character, as bash reads it."""
    c = cmd
    out, ok = shell_lex._subst_bodies(c)
    copy = _comment_cont_copy(c)
    if copy is not None:
        more, ok_copy = shell_lex._subst_bodies(copy)
        out, ok = out + more, ok and ok_copy
    known, res = set(seen), []
    for body in out:
        if body not in known:
            known.add(body)
            res.append(body)
    return res, ok
```

In `_is_file_mod`, replace

```python
    bodies, subst_ok = _command_substitutions(cmd)
    if subst_ok is None:
        return True                       # fail CLOSED -- see _case_budget
    if not subst_ok:
        # RESIDUAL, stated:
```

with

```python
    bodies, subst_ok = _command_substitutions(cmd)
    if subst_ok is None:
        return True                       # fail CLOSED -- see _case_budget
    extra, extra_ok = _lex_bodies(cmd, bodies)
    if not extra_ok and _depth == 0:
        # The command AS WRITTEN is unreadable: block. Depth 0 only -- deeper strings are
        # derived (a body _subst_end cut short, _ansi_c's respelling), and the lexer gives up
        # on those for read-only commands: `: "$(echo ${v%)})"` yields `echo ${v%`, and
        # `echo $'it\'s'` is respelled `echo 'it\'s'`. A body found at depth 0 is never cut
        # short, because the lexer found its closer. A `bash -c`/`eval` program is not derived,
        # so a give-up inside one is a stated gap, tracked in #1093.
        return True
    for body in extra:
        if is_file_mod(body, _depth + 1):
            return True
    if not subst_ok and extra_ok:
        # _subst_end found no closer but shell_lex read the command: the stray quote or paren
        # sits where shell_lex placed it, usually in a comment. main's verbs-only verdict is
        # kept as a block, and the command ALSO takes the tokenized reading below, which sees
        # redirects. Not the raw redirect scan withdrawn twice below: this runs only when a
        # comment-aware lexer read the command, and reads it through the comment defuser.
        if _regex_fallback(cmd):
            return True
    elif not subst_ok:
        # RESIDUAL, stated:
```

(the rest of that `if not subst_ok:` block, now `elif`, is unchanged.)

- [ ] **Step 8: The trigger in `is_file_mod`**

Replace the body of `is_file_mod` after its docstring

```python
    if _is_file_mod(cmd, _depth):
        return True
    if _depth or _ansi_c_reading[0] or not _ansi_c_differs(cmd):
        return False
    _ansi_c_reading[0] = True
    try:
        return _is_file_mod(cmd)
    finally:
        _ansi_c_reading[0] = False
```

with

```python
    # shell_lex reads as bash does while this runs (`<( )` bodies, `$'…'` heredoc delimiters,
    # continuations in a heredoc word) and as on main otherwise (marker_check). Held for the
    # whole call, so every lexer scan in every reading agrees (#1085, Deviation 11).
    prev, shell_lex._cmdword_on[0] = shell_lex._cmdword_on[0], True
    try:
        return _is_file_mod_readings(cmd, _depth)
    finally:
        shell_lex._cmdword_on[0] = prev


def _is_file_mod_readings(cmd, _depth=0):
    # The readings is_file_mod ORs, with shell_lex._cmdword_on already on.
    if _is_file_mod(cmd, _depth):
        return True
    if _depth or _ansi_c_reading[0] or _lex_reading[0]:
        return False
    if _ansi_c_differs(cmd):
        _ansi_c_reading[0] = True
        try:
            if _is_file_mod(cmd):
                return True
        finally:
            _ansi_c_reading[0] = False
    # The third reading (#1085). Every narrower trigger was beaten by a spelling that hides
    # its text from the top level -- `$''{`, `\x23`, `"eval \$""'…'"`, `$\<nl>'` -- because
    # the program is reached only at depth >= 1, where no reading starts. None hides the `$`:
    # only `$'…'` makes a `#` or newline out of an escape, and it starts from a `$` as written.
    if "#" not in cmd and "$" not in cmd:
        return False
    if len(cmd) > _LEX_READING_MAX:
        # Over the cap the third reading does not run and the command blocks. The reading
        # roughly doubles cmdword's time on long commands, and a hook past its 5 s deadline
        # writes no decision, which the harness reads as ALLOW; blocking is fail-closed.
        return True
    _lex_reading[0] = _ansi_c_reading[0] = True
    try:
        return _is_file_mod(cmd)
    finally:
        _lex_reading[0] = _ansi_c_reading[0] = False
```

Update its docstring's second paragraph to: `A command is read up to three times -- see _ansi_c_reading, _ansi_c_differs and _lex_reading.` Add `_is_file_mod_readings` to the Produces line of this task's Interfaces; nothing outside cmdword calls it.

- [ ] **Step 9: Parity test for `_requote_ansi_c`**

In `tests/test-escaped-dollar-1048.sh`, inside the Python `node()` helper, strip the third-reading branches from cmdword's function before dumping. The whole Python program sits inside a single-quoted `python3 -I -c '…'`, so **nothing added may contain a `'` character**, comments included (an apostrophe ends the bash string and the suite fails with a syntax error). Two insertions; the rest of `node()`, including its `ast.Assign` arm and the final `return "missing " + name`, stays as it is.

First, directly above `def node(tree, name):` insert:

```python
class _NoLexReading(ast.NodeTransformer):
    # #1085: cmdword guards its third-reading additions with `if _lex_reading[0]:`. With the
    # flag off the function must still match the marker_check one, so keep each else-branch.
    def visit_If(self, n):
        self.generic_visit(n)
        if ast.unparse(n.test) == "_lex_reading[0]":
            return n.orelse or None
        return n
```

Second, in the `ast.FunctionDef` branch of `node()`, directly before its `return ast.dump(n)`, insert one line at the same indent:

```python
            n = _NoLexReading().visit(n)
```

Check: `sed -n '/^if out=\$(python3 -I -c /,/^fi$/p' tests/test-escaped-dollar-1048.sh | grep -c "'"` prints the same count as before the edit (2: the opening and closing quote).

Then, directly after that `ok "the second reading, its pre-pass, …"` block, add one behaviour row:

```bash
if [[ "$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import cmdword
print(cmdword._bash_ansi_c(chr(92) + "x23 a" + chr(92) + "nb"))' "$LIB")" == $'# a\nb' ]]; then
    ok "the third reading decodes \\n and \\x23 in \$'…'"
else
    no "the third reading decodes \\n and \\x23 in \$'…'" "_bash_ansi_c missing or wrong"
fi
if [[ "$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import cmdword
q, b = chr(39), chr(92)
cmdword._lex_reading[0] = True
got = cmdword._requote_ansi_c("echo $" + q + "it" + b + q + "s" + b + "x23" + q)
cmdword._lex_reading[0] = False
print("ok" if got == "echo " + q + "it" + q + b + q + q + "s#" + q else repr(got))' "$LIB")" == ok ]]; then
    ok "the third reading requotes a decoded \$'…' with every ' respelled"
else
    no "the third reading requotes a decoded \$'…' with every ' respelled" "_requote_ansi_c third-reading branch missing or wrong"
fi
```

The first row pins the decoder; the second pins `_requote_ansi_c`'s third-reading branch, which the parity check above strips: deleting the branch, or dropping its `'` respelling, fails it.

- [ ] **Step 10: Run the existing suites**

```bash
failed=0
for t in tests/test-cmdword-*.sh tests/test-ansic-quote-1043.sh tests/test-herestring-receiver-643.sh \
         tests/test-brainstorming-oracle-wrapper-root.sh \
         tests/test-escaped-dollar-1048.sh tests/test-marker-*.sh; do
  if bash "$t" >/dev/null 2>&1; then echo "pass $t"; else echo "FAIL $t"; failed=1; fi
done
if python3 -I hooks/gate-scripts/lib/cmdword.py >/dev/null; then echo "cmdword self-check ok"; else failed=1; fi
[ "$failed" -eq 0 ]
```

Then on UM, the scope suites (minutes each): `um-run test -- bash -lc 'failed=0; for t in tests/test-impl-gate-scope-*.sh; do bash "$t" >/dev/null 2>&1 || { echo "FAIL $t"; failed=1; }; done; [ "$failed" -eq 0 ]'`.

Expected: all `pass`, exit 0. These suites assert many allow rows; a newly failing allow row is an over-block. Check the code against this step's text before changing anything: the corpus run of this plan's own code had 39 heredoc over-blocks and no others, so any other over-block is a transcription error.

- [ ] **Step 11: Regenerate the lock and commit**

```bash
./scripts/gate-integrity.sh --update
git add hooks/gate-scripts/lib/cmdword.py tests/test-escaped-dollar-1048.sh .gate-integrity.lock
git commit -m "fix(gate): read substitution bodies and comments the way bash does (#1085)" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The #1085 suite — reproducers, controls, fuzz, timing

**Files:**
- Create: `tests/fixtures/cmdword_1085.py`
- Create: `tests/test-cmdword-subst-comment-1085.sh`
- Modify: `scripts/ci/run-shell-tests.sh:285-290` (per-test override)

**Interfaces:**
- Consumes: `cmdword.is_file_mod` (Task 2); the hook `hooks/gate-scripts/pre-implementation-gate.sh`; `hooks/gate-scripts/lib/resolve-repo-dir.sh arm <doc>` to arm a pending design.
- Produces: `python3 tests/fixtures/cmdword_1085.py rows|fuzz|timing <armed-repo> [--full]`, which prints `ok …` / `FAIL …` lines and a final `SUMMARY <pass> <fail>`, and exits 1 on any failure, 2 on a setup failure.

- [ ] **Step 1: Write the fixture**

```python
#!/usr/bin/env python3
"""#1085 checks for cmdword: rows and timing through the real hook, fuzz in process.

  cmdword_1085.py rows   <armed-repo>          reproducers must block, controls must allow
  cmdword_1085.py fuzz   <armed-repo> [--full] generated commands bash runs; none that writes may be allowed
  cmdword_1085.py timing <armed-repo>          32k adversarial inputs: the hook decides within 4.0 s (10.0 s on GitHub)

Every write is first executed under bash >= 5 in a scratch tree: a fixture that does not
write proves nothing about the guard. No bash >= 5 is a FAILURE, not a skip.
"""
import json, os, random, re, shlex, shutil, subprocess, sys, tempfile, textwrap, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GATE = os.path.join(ROOT, "hooks", "gate-scripts", "pre-implementation-gate.sh")
LIB = os.path.join(ROOT, "hooks", "gate-scripts", "lib")
NL, BS, SQ, CR = chr(10), chr(92), chr(39), chr(13)
PASS = FAIL = 0


def ok(label):
    global PASS
    PASS += 1
    print("  ok    " + label)


def no(label, why):
    global FAIL
    FAIL += 1
    print("  FAIL  " + label + " :: " + why)


def bash5():
    for cand in (shutil.which("bash"), "/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/usr/bin/bash", "/bin/bash"):
        if cand and os.path.exists(cand):
            try:
                v = subprocess.run([cand, "-c", "echo ${BASH_VERSINFO[0]}"], capture_output=True, text=True, timeout=5)
                if v.stdout.strip().isdigit() and int(v.stdout.strip()) >= 5:
                    return cand
            except (OSError, subprocess.TimeoutExpired):
                pass
    print("  FAIL  no bash >= 5 found -- the reproducers cannot be proven")
    sys.exit(2)


BASH = None


def writes(cmd):
    """True when bash, run in a scratch tree, removes src/ or creates src/f."""
    d = tempfile.mkdtemp()
    try:
        os.makedirs(os.path.join(d, "src"))
        open(os.path.join(d, "src", "keep"), "w").close()
        try:
            # bash 5's own directory first: a nested `bash -c` must be bash 5 too, or a macOS
            # host measures /bin/bash 3.2's reading of the inner program.
            subprocess.run([BASH, "-c", cmd], cwd=d, capture_output=True, timeout=5, stdin=subprocess.DEVNULL,
                           env={"PATH": os.path.dirname(BASH) + ":/usr/bin:/bin", "HOME": d})
        except subprocess.TimeoutExpired:
            pass                         # a write made before the hang still counts
        s = os.path.join(d, "src")
        return not os.path.isdir(s) or os.path.exists(os.path.join(s, "f"))
    finally:
        shutil.rmtree(d, ignore_errors=True)


def hook(repo, cmd, timeout=30):
    """(decision, seconds): 'block', 'allow' or 'error:<why>' from the real hook."""
    payload = json.dumps({"tool_name": "Bash", "cwd": repo, "tool_input": {"command": cmd}})
    t = time.perf_counter()
    try:
        p = subprocess.run(["bash", GATE], input=payload, cwd=repo, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return "error:timeout", time.perf_counter() - t
    dt = time.perf_counter() - t
    # The gate's ERR trap also prints a block; that is a gate failure, and a row must not
    # pass on it. Every other block is a classifier decision (cmdword or marker_check).
    if "Pre-implementation gate error" in p.stdout:
        return "error:gate ERR trap", dt
    if '"block"' in p.stdout:
        return "block", dt
    return ("allow" if p.returncode == 0 else "error:exit %d" % p.returncode), dt


def gate_redirect_check():
    """The gate's own raw redirect check, read out of pre-implementation-gate.sh -- not copied."""
    src = open(GATE).read()
    a = src.rindex("\n", 0, src.index("# Check for shell redirects")) + 1   # whole line, for dedent
    b = src.index("is_mod = True", a) + len("is_mod = True")
    block = textwrap.dedent(src[a:b].replace(SQ + BS + SQ + SQ, SQ))
    if "no_single" not in block or ">{1,2}" not in block:
        print("  FAIL  the gate's redirect check changed shape -- update gate_redirect_check")
        sys.exit(2)
    ns = {"re": re}
    exec(compile("def check(cmd):\n    is_mod = False\n" + textwrap.indent(block, "    ") + "\n    return is_mod\n",
                 "gate-redirect", "exec"), ns)
    return ns["check"]


# ── rows ─────────────────────────────────────────────────────────────────────
W_RM, W_RE = "rm -rf src", "echo x > src/f"
DQPROG = 'bash -c "eval ' + BS + '$""' + SQ  # opener hidden by quote concatenation


def enc(p):    # a program written as a $'…' body: #, ', \ and newlines as escapes
    return p.replace(BS, BS + BS).replace(SQ, BS + SQ).replace("#", BS + "x23").replace(NL, BS + "n")


def dq(p):     # the same body inside double quotes
    return "".join(BS + c if c in BS + '"$`' else c for c in p)


def repro():
    rows = []
    for w in (W_RM, W_RE):
        rows += [
            ': "$(echo ${v%)}; ' + w + ')"',
            ': "$(# )' + NL + w + ')"',
            ': "$(cat <<E' + NL + ")" + NL + "E" + NL + w + ')"',
            "echo ${v%<<E #}; " + w,
            "echo `echo # `echo ; " + w,
            "echo #" + BS + NL + w,
            "bash -c " + shlex.quote("echo # x" + NL + w),
            "sh -c " + shlex.quote("echo # x" + NL + w),
            "eval " + shlex.quote("echo # x" + NL + w),
            "bash -c " + shlex.quote(': "$(echo # it' + SQ + 's' + NL + w + ')"'),
            "bash -c $'" + enc("echo # x" + NL + w) + "'",
            "sh -c $'" + enc("echo # x" + NL + w) + "'",
            "eval $'" + enc("echo # x" + NL + w) + "'",
            "bash -c $'echo " + BS + "x23 x" + BS + "n" + w + "'",
            "bash -c $'echo " + BS + "043 x" + BS + "n" + w + "'",
            "bash -c $'echo " + BS + "u0023 x" + BS + "n" + w + "'",
            "bash -c $'echo " + BS + "U00000023 x" + BS + "n" + w + "'",
            "bash -c $'echo " + BS + "x23 x" + BS + "r" + BS + "n" + w + "'",
            ': "$(bash -c $' + SQ + "echo " + BS + "x23 x" + BS + "n" + w + SQ + ')"',
            "bash -c $" + BS + NL + "'echo " + BS + "x23 x" + BS + "n" + w + "'",
            DQPROG + dq("echo " + BS + "x23 x" + BS + "n" + w) + SQ + '"',
            DQPROG + dq("echo $((1<<2))" + BS + "n" + "echo " + BS + "x23" + BS + BS + BS + "n" + w) + SQ + '"',
            "bash -c $'echo # x" + NL + w + "'",                       # a literal newline inside $'…'
            "sh -c $'echo # x" + NL + w + "'",
            "eval $'echo # x" + NL + w + "'",
            "bash -c 'echo $''{v%<<E #}; " + w + "'",
            "echo ${v:-$" + BS + NL + "{x#}<<E #}; " + w,
            "echo $" + BS + NL + "{v%<<E #}; " + w,
            "echo ${v" + BS + NL + ":-$" + BS + NL + "{x}<<E #}; " + w,
            "cat <(echo ${v%)}; " + w + ")",
            "cat >(echo ${v%)}; " + w + "); wait $!",   # bash does not wait for >( ) itself
            "cat ${v:-<(echo ${v%)}; " + w + ")}",   # procsub inside ${…} runs; cat waits for it
            "bash -c $'echo # x" + BS + "c" + BS * 3 + "n" + w + "'",   # `\c\\` is one escape
            # `\c` then a LITERAL newline is control-newline, a newline: no NUL ends the program.
            "bash -c $'echo # a" + BS + "c" + NL + BS + "n" + w.replace("rm ", BS + "x72m ") + "'",
            # A `$'E\tF'` heredoc delimiter, a comment (so the third reading runs), then the verb
            # split by a line continuation: every lexer scan must decode the delimiter as bash
            # does, or the third reading's continuation join misses it.
            "bash -c " + shlex.quote("cat <<$'E" + BS + "tF'" + NL + "x" + NL + "E\tF" + NL + "echo # x" + NL + w[0] + BS + NL + w[1:]),
            # A `<( )` inside `${…}`: its `}` is its own, so the `${` does not end in its comment.
            "echo ${v:-<(# }" + NL + "true) #}; " + w,
            "echo ${v:-<(# }" + NL + "true)<<E #}; " + w,
            # A continuation inside a heredoc delimiter: `<<E\<nl>OF` delimits on EOF.
            "bash -c $'" + enc("cat <<E" + BS + NL + "OF" + NL + "hello" + NL + "EOF" + NL + "echo # " + SQ + NL + w + NL + "echo # " + SQ) + "'",
            "bash -c " + shlex.quote("cat <<E" + BS + NL + "OF" + NL + "hello" + NL + "EOF" + NL + "echo # " + SQ + NL + w + NL + "echo # " + SQ),
            # A newline quoted inside `${…}` is a newline in the program bash -c / eval runs.
            'bash -c "echo # x "${v:-' + SQ + NL + w + SQ + "}",
            'eval "echo # x" ${v:-' + SQ + NL + w + SQ + "}",
            # A continuation right after `<<`, then a blank: bash joins it, so it is `<< EOF`.
            "bash -c $'" + enc("cat <<" + BS + NL + " EOF" + NL + "it" + SQ + "s" + NL + "EOF" + NL + w + NL + "echo # " + SQ) + "'",
            "bash -c " + shlex.quote("cat <<" + BS + NL + " EOF" + NL + "hello" + NL + "EOF" + NL + "echo # " + SQ + NL + w + NL + "echo # " + SQ),
            # ... and inside a double-quoted delimiter word.
            "bash -c " + shlex.quote("cat <<" + chr(34) + "E" + BS + NL + "OF" + chr(34) + NL + "hello" + NL + "EOF" + NL + "echo # " + SQ + NL + w + NL + "echo # " + SQ),
            # Past-Unicode escape: bash emits bytes, so `#` is mid-word. `\x72m` hides the verb
            # from main's reading; a decoder that deleted the escape allowed it.
            "bash -c $'" + BS + "U00110000#; " + w.replace("rm ", BS + "x72m ") + "'",
            # `\c` masks a BYTE: `\cĀ` is 04 80, not a NUL that would end the program.
            "bash -c $'echo # x" + BS + "c" + chr(0x100) + BS + "n" + w.replace("rm ", BS + "x72m ") + "'",
            # CR is a word character to bash, so this `#` is mid-word, not a comment.
            "echo " + CR + "#; " + w,
            "bash -c " + shlex.quote("echo a" + CR + "#; " + w),
            # Ends in an UNCLOSED quote: unreadable at depth 0, so it blocks. The closed-quote
            # variant has no `#` or `$` and stays allowed (Deviations 4).
            "cat <<EOF" + NL + "it" + SQ + "s" + NL + "EOF" + NL + w + NL + "echo " + SQ + "a",
        ]
    rows.append('echo ${v%<<E #}; "r' + BS + NL + 'm" -rf src')
    rows.append("bash -c $'echo " + BS + "x23 x" + BS + "n" + BS + "x72m -rf src'")   # verb spelled with escapes
    return rows


CONTROLS = [
    "echo ${v%)}", ': "$(echo ${v%)})"', "echo $'it" + BS + "'s'",
    "echo $(case ${v#x} i" + BS + NL + "n x) :;; esac)",
    "echo hi # note", "echo #" + BS + NL + "ls", "git log --oneline -1 # x" + BS + NL,
    "echo $((n+1))", "echo $(echo a)#" + BS + NL + "b",
    "echo 'a # b" + NL + "c'", "bash -c 'echo \"a # b" + NL + "c\"'",
    "echo $'" + BS + "x23 not a comment'; ls", "bash -c $'echo " + BS + "x23 x" + BS + "nls'",
    "printf $'a" + BS + "nb" + BS + "x23c" + BS + "n'",
    "echo $" + BS + NL + "{HOME}", "echo '$" + BS + NL + "'", "echo ${v:-$" + BS + NL + "{x#}}; ls",
    'bash -c "echo # x' + BS + NL + 'ls"', 'echo "' + BS + "$HOME costs " + BS + "`x" + BS + '`"',
    "git status --short # see" + NL + "git log -1",
    "cat <<'E'" + NL + "it" + SQ + "s # a note" + NL + "E",
    'git commit --dry-run -m "fix: x' + NL + NL + "# keep this line" + NL + 'body"',
    "git status" + CR + NL + "git log -1" + CR + NL, "echo hi # x" + CR + NL + "ls",   # CRLF
    "printf $'a" + BS + "c?b'",
    "bash -c $'echo # a" + BS + "c" + NL + BS + "nls'",
    "bash -c " + shlex.quote("cat <<$'E" + BS + "tF'" + NL + "x" + NL + "E\tF" + NL + "echo # x" + NL + "l" + BS + NL + "s"),
    "echo ${v:-<(# }" + NL + "true) #}; ls",
    "bash -c " + shlex.quote("cat <<E" + BS + NL + "OF" + NL + "hello" + NL + "EOF" + NL + "echo # " + SQ + NL + "ls" + NL + "echo # " + SQ),
    'bash -c "echo # x "${v:-' + SQ + NL + "ls" + SQ + "}",
    "bash -c " + shlex.quote("cat <<" + BS + NL + " EOF" + NL + "hello" + NL + "EOF" + NL + "echo # " + SQ + NL + "ls" + NL + "echo # " + SQ),
]
STATED_OVER_BLOCK = [": $(" + NL + "# " + BS + NL + "echo hi)"]   # spec Residuals: _lex_bodies over-block


LEX = [  # shell_lex._subst_bodies directly: shapes the hook rows cannot isolate
    ("echo <(true)#$(echo HI)", (["true", "echo HI"], True)),     # `#` after `)` is mid-word
    ("cat <(echo ${v%)}; ls)", (["echo ${v%)}; ls"], True)),     # `)` inside ${…} closes nothing
]


def rows(repo):
    sys.path.insert(0, LIB)
    import shell_lex
    import cmdword
    # Deviation 11: the full delimiter decode is off for marker_check, so off outside is_file_mod.
    before = list(shell_lex._cmdword_on)
    cmdword.is_file_mod("cat <<$'E" + BS + "tF'" + NL + "x" + NL + "E\tF" + NL + "ls")
    label = "shell_lex._cmdword_on is off outside is_file_mod"
    ok(label) if before == shell_lex._cmdword_on == [False] else no(label, repr((before, shell_lex._cmdword_on)))
    # Deviation 3: in the third reading a raw NUL is restored as a newline, so inside a quoted
    # program it ends that program's comment. In-process: the hook's stdin cannot carry a NUL.
    for cmd, want in (("bash -c " + SQ + "echo # x" + chr(0) + W_RM + SQ, True),
                      ("bash -c " + SQ + "echo # x" + chr(0) + "ls" + SQ, False)):
        label = "raw NUL in a program: " + repr(cmd)
        ok(label) if cmdword.is_file_mod(cmd) == want else no(label, "is_file_mod said " + repr(not want))
    for cmd, want in LEX:
        shell_lex._cmdword_on[0] = True     # as is_file_mod runs it: `<(` reads only then
        try:
            got = shell_lex._subst_bodies(cmd)
        finally:
            shell_lex._cmdword_on[0] = False
        label = "lex: " + repr(cmd)
        ok(label) if got == want else no(label, "got " + repr(got))
    for cmd in repro():
        label = "block: " + repr(cmd)[:90]
        if not writes(cmd):
            no(label, "bash does not write -- not a reproducer")
            continue
        got, _ = hook(repo, cmd)
        ok(label) if got == "block" else no(label, "hook said " + got)
    for cmd in CONTROLS:
        label = "allow: " + repr(cmd)[:90]
        if writes(cmd):
            no(label, "bash writes -- not a control")
            continue
        got, _ = hook(repo, cmd)
        ok(label) if got == "allow" else no(label, "hook said " + got)
    for cmd in STATED_OVER_BLOCK:
        got, _ = hook(repo, cmd)
        label = "stated over-block still blocks: " + repr(cmd)
        ok(label) if got == "block" else no(label, "hook said " + got + " -- update spec Residuals")


# ── fuzz ─────────────────────────────────────────────────────────────────────
FR = ["echo ${v%)}", "echo ${v:-)}", "echo ${v#)}", "echo ${v//)/x}", "echo ${#v}", "echo ${v%<<E #}",
      "echo $'\\)'", "echo $'\\''", "echo $')'", "echo ')'", 'echo ")"', "echo \\)", "echo a#)",
      "# )\n", "echo # )\n", "echo #\\\n", "cat <<E\n)\nE\n", "cat <<'E'\n) #\nE\n", "cat <<-E\n\t)\n\tE\n",
      "echo `echo )`", "echo `echo # `", "echo $((1<<2))", "echo $(( (1) ))", "(( x = (1) ))",
      "[[ x == ) ]] 2>/dev/null", "case x in x) :;; esac", "case x in (x) echo );; esac", "f() { :; }",
      "echo $(echo ))", "echo \"$(echo ')')\"", "echo ${v-$(echo ))}", ":", "true", "echo x\\\ny",
      "ca\\\nse x in x) :;; esac", "e\\\ncho )", "echo $\\\n{v%)}", "echo `echo \\`echo )\\``",
      "echo \"${v%\")\"}\"", "echo ${v:-`echo )`}", "echo ${v:-$(echo '#')}", "echo \"#)\"", "echo x#\\\ny",
      "echo # it's\n", "echo hi # x\n", "cat <(echo ))", "echo $\"a)\"", "echo $'\\x23 )'", "echo $'a\\nb'",
      "echo ${v:-$\\\n{x#}<<E #}", "echo $\\\n{HOME}"]
FORMS = {
    "subst": lambda m, w: ': "$(' + m + "\n" + w + ')"',
    "substs": lambda m, w: ': "$(' + m + "; " + w + ')"',
    "substu": lambda m, w: ": $(" + m + "\n" + w + ")",
    "top": lambda m, w: m + "; " + w,
    "topnl": lambda m, w: m + "\n" + w,
    "bashc": lambda m, w: "bash -c " + shlex.quote(m + "\n" + w),
    "bashca": lambda m, w: "bash -c $'" + enc(m + "\n" + w) + "'",
    "bashcj": lambda m, w: "bash -c $\\\n'" + enc(m + "\n" + w) + "'",
    "bashce": lambda m, w: DQPROG + dq(enc(m + "\n" + w)) + SQ + '"',
}


def load_baseline(path):
    """is_file_mod of another cmdword.py (e.g. main's), under its own module name."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("cmdword_baseline", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.is_file_mod


def fuzz(full, baseline=None):
    sys.path.insert(0, LIB)
    from cmdword import is_file_mod
    redirect = gate_redirect_check()
    base = load_baseline(baseline) if baseline else None
    plan = [(19, 1500), (20, 1500)] if full else [(19, 300)]
    floor = 30000 if full else 2500   # commands that write; fewer means the generator broke
    runs = misses = regress = 0
    for seed, per_form in plan:
        for form, build in FORMS.items():
            for w in (W_RM, W_RE):
                rnd = random.Random("%d/%s/%s" % (seed, form, w))
                for _ in range(per_form):
                    parts = [rnd.choice(FR) for _ in range(rnd.randint(1, 4))]
                    mid = "".join(p if p.endswith("\n") else p + rnd.choice(["; ", "\n", " && ", " | "]) for p in parts)
                    cmd = build(mid.rstrip("; &|\n"), w)
                    verdict = is_file_mod(cmd) or redirect(cmd)
                    if base is not None and not verdict and (base(cmd) or redirect(cmd)):
                        regress += 1      # every candidate, writing or not: additive only
                        no("fuzz", "baseline blocks, this allows: " + repr(cmd))
                    if not writes(cmd):
                        continue
                    runs += 1
                    if not verdict:
                        misses += 1
                        no("fuzz", "bash writes, the gate allows: " + repr(cmd))
    if runs < floor:
        no("fuzz", "only %d commands wrote, floor %d -- the generator or bash broke" % (runs, floor))
    elif misses == 0 and regress == 0:
        ok("fuzz: %d commands that write, none allowed%s (%s)" % (
            runs, ", no block->allow vs baseline" if base else "", "full" if full else "ci"))


# ── timing ───────────────────────────────────────────────────────────────────
CAP = 32768                     # cmdword._LEX_READING_MAX: the third reading's worst case
# 4.0 s locally (the meaningful number, under the 5 s hook deadline); 10.0 s on a GitHub
# runner, the 2.5x calibration #553 measured there. Keyed on GITHUB_ACTIONS only, as #553 is.
LIMIT = 10.0 if os.environ.get("GITHUB_ACTIONS", "").strip().lower() == "true" else 4.0
TRIG = "# x\\\n$'\\''\n"
UNITS = ["${v}", "${v%)}", "$(", "${", "`", "#\\\n", "case x in ", "$(case x in x) ", "x) ", "<<E\n",
         "\\\n", "'a\n# b\n'", "bash -c 'x # y\n'", "$(( (1) ))", "<<<x ", "$(echo ${v%)}; ", '"', "'",
         "$'\\x23\\n'", "# "]
TAILS = ["", ")", "\nE\n", "'"]
# marker_check alone exceeds 5 s on these on main, before cmdword runs. Tracked separately.
MC_OVER = {"$(", "`"}


def timing(repo):
    for u in UNITS:
        for tail in TAILS:
            if u in MC_OVER:
                continue
            cmd = (': "$(' + TRIG + "echo " + u * ((CAP - 60) // len(u)) + tail + '; ls)"')[:CAP]
            got, dt = hook(repo, cmd, timeout=10)
            label = "timing %r %r: %s in %.2fs" % (u, tail, got, dt)
            ok(label) if got in ("block", "allow") and dt <= LIMIT else no(label, "over %.1f s or no decision" % LIMIT)
    # Over the cap: a read-only command holding `$` blocks, fast, without the third reading.
    cmd = "echo " + "${v} " * ((65536 - 100) // 5)
    got, dt = hook(repo, cmd, timeout=10)
    label = "over _LEX_READING_MAX: a %d-char read-only command with $ blocks, in %.2fs" % (len(cmd), dt)
    ok(label) if got == "block" and dt <= LIMIT else no(label, "hook said " + got)
    print("  skip  marker_check over budget on main (#1095): " + ", ".join(sorted(MC_OVER)))


def main():
    global BASH
    if len(sys.argv) < 3 or sys.argv[1] not in ("rows", "fuzz", "timing"):
        print(__doc__)
        return 2
    BASH = bash5()
    mode, repo = sys.argv[1], sys.argv[2]
    if mode == "rows":
        rows(repo)
    elif mode == "fuzz":
        base = sys.argv[sys.argv.index("--baseline") + 1] if "--baseline" in sys.argv else None
        fuzz("--full" in sys.argv, base)
    else:
        timing(repo)
    print("SUMMARY %d %d" % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Write the shell suite**

```bash
#!/usr/bin/env bash
# #1085: cmdword read substitution bodies and comments differently from bash, so writes behind
# `${v%)}`, a comment, a heredoc, or an ANSI-C-quoted program were allowed while a design was
# pending. The checks live in tests/fixtures/cmdword_1085.py; this suite builds the repos.
set -u
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/hooks/gate-scripts/pre-implementation-gate.sh"
FIX="$ROOT/tests/fixtures/cmdword_1085.py"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; }

ARMED=""
trap 'rm -rf ${ARMED:+"$ARMED"}' EXIT
ARMED="$(mktemp -d)" || ARMED=""
[[ -n "$ARMED" && -d "$ARMED" ]] || { echo "  FAIL  mktemp -d"; exit 1; }
git -C "$ARMED" init -q
mkdir -p "$ARMED/docs/plans" "$ARMED/.claude" "$ARMED/src"
printf '# plan\n' >"$ARMED/docs/plans/thing.md"
bash "$ROOT/hooks/gate-scripts/lib/resolve-repo-dir.sh" arm "$ARMED/docs/plans/thing.md" >/dev/null 2>&1

# The fixture is only meaningful with a design pending: prove it, or every allow is vacuous.
case "$(printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"rm -rf src"}}' "$ARMED" \
        | (cd "$ARMED" && bash "$GATE") 2>/dev/null)" in
    *'"block"'*) ok "fixture: a design is pending in the armed repo" ;;
    *) no "fixture: a design is pending in the armed repo" "rm -rf src was allowed"
       printf '\n════ cmdword-subst-comment-1085: %d passed, %d failed ════\n' "$PASS" "$FAIL"; exit 1 ;;
esac

for mode in rows fuzz timing; do
    echo "=== $mode ==="
    out="$(python3 -I "$FIX" "$mode" "$ARMED" 2>&1)"
    rc=$?
    printf '%s\n' "$out" | grep -v '^SUMMARY '
    sum="$(printf '%s\n' "$out" | grep '^SUMMARY ' | tail -1)"
    p=0 f=0
    if [[ -n "$sum" ]]; then
        read -r _ p f <<<"$sum"     # counted whatever rc is: N failed rows show as N
    fi
    PASS=$((PASS + p)); FAIL=$((FAIL + f))
    if [[ -z "$sum" ]] || [[ $rc -ne 0 && $f -eq 0 ]]; then
        no "$mode" "fixture exited $rc${sum:+ ($sum)}"   # setup failure, or rc and SUMMARY disagree
    fi
done

printf '\n════ cmdword-subst-comment-1085: %d passed, %d failed ════\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
```

`chmod +x tests/test-cmdword-subst-comment-1085.sh`.

- [ ] **Step 3: Run it and time it**

Run: `set -o pipefail; time bash tests/test-cmdword-subst-comment-1085.sh 2>&1 | tail -15`
Expected: `0 failed`. Every `block:` row first proved its write under bash 5. Note the wall time.

Then confirm the reproducers are not vacuous: `main`'s classifier must allow most of them.

```bash
T="$(mktemp -d)"
git show origin/main:hooks/gate-scripts/lib/cmdword.py >"$T/cmdword.py"
python3 -I - "$T" "$PWD/tests/fixtures" <<'PY'
import sys
sys.path[:0] = [sys.argv[1], sys.argv[2]]
import cmdword, cmdword_1085 as f
check = f.gate_redirect_check()
rows = f.repro()
print(sum(not (cmdword.is_file_mod(r) or check(r)) for r in rows), "of", len(rows), "allowed on main")
PY
rm -rf "$T"
```

Expected: `48 of 100 allowed on main` (measured on this list during planning; the other 52 are the same shapes in spellings `main` already blocks, kept as regression rows). A count near zero means the rows no longer test the fix.

- [ ] **Step 4: Per-test timeout override**

In `scripts/ci/run-shell-tests.sh`, in the `case` inside `test_timeout()` (lines 286-290 on `main`), add a line set to three times the measured wall time from Step 3, rounded up to a multiple of 60 and at least 300 (#553 uses about 3x, and a GitHub runner measured 2.45x slower than this Mac, so 2x could fail CI):

```bash
    test-cmdword-subst-comment-1085) override=600 ;;
```

(600 if Step 3 measured ≤ 200 s; otherwise use the computed value.) Add one comment line above it: `# #1085: rows + fuzz + timing through the real hook; measured <N>s locally.`

- [ ] **Step 5: Run the full fuzz once locally (not in CI)**

```bash
T="$(mktemp -d)"
git show origin/main:hooks/gate-scripts/lib/cmdword.py >"$T/cmdword.py"
python3 -I tests/fixtures/cmdword_1085.py fuzz "$T" --full --baseline "$T/cmdword.py" >"$T/fuzz.log" 2>&1
fuzz_rc=$?
tail -2 "$T/fuzz.log"
rm -rf "$T"
[ "$fuzz_rc" -eq 0 ]
```

Expected: `ok    fuzz: <about 38000> commands that write, none allowed, no block->allow vs baseline (full)` and `SUMMARY 1 0`. The baseline check covers every generated candidate, writing or not, so it is the fuzz half of the additive-only constraint (Task 5 Step 4 is the corpus half). It needs `main`'s file, so it runs locally, not in CI. Record the count in the PR description.

- [ ] **Step 6: Commit**

```bash
git add tests/fixtures/cmdword_1085.py tests/test-cmdword-subst-comment-1085.sh scripts/ci/run-shell-tests.sh
git commit -m "test(gate): #1085 reproducers, controls, fuzz and hook timing" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: The gate blocks on an exception inside `is_file_mod` (spec D)

**Files:**
- Modify: `hooks/gate-scripts/pre-implementation-gate.sh:783-785`
- Modify: `tests/test-gate-classifier-fail-closed.sh` (new B10 before section C; B9 is already there from part 1)

**Interfaces:**
- Consumes: `is_file_mod` as imported at gate line ~697.
- Produces: no new interface; behaviour: an exception raised inside `is_file_mod` sets `has_explicit_mod = True`.

- [ ] **Step 1: Guard the call**

Replace (gate lines 783-785, inside the single-quoted inline Python — **no `'` characters**):

```python
        has_explicit_mod = (is_file_mod(cmd) if is_file_mod is not None
                            else any(re.search(p, v) for p in FILE_MOD_PATTERNS
                                     for v in _variants(cmd)))
```

with

```python
        try:
            has_explicit_mod = (is_file_mod(cmd) if is_file_mod is not None
                                else any(re.search(p, v) for p in FILE_MOD_PATTERNS
                                         for v in _variants(cmd)))
        except Exception:
            # #1085: an exception inside the classifier is a write, not an allow. The outer
            # handler below still prints SAFE for payload-parsing failures, and a process
            # that dies outright still reaches the shell fallback; both are stated residuals.
            has_explicit_mod = True
```

- [ ] **Step 2: B10**

In `tests/test-gate-classifier-fail-closed.sh`, insert directly before `echo "── C. normal operation is unchanged ──"` (after part 1's B9 rows):

```bash
# B10 (#1085): is_file_mod raises while a design is pending. Before the guard, the inline
# classifier caught it and printed SAFE. A separate ARMED repo: section C needs none pending.
ARMD="$(mktemp -d)" || ARMD=""
if [[ -z "$ARMD" || ! -d "$ARMD" ]]; then
    no "B10 setup" "mktemp -d failed"
else
    git -C "$ARMD" init -q
    mkdir -p "$ARMD/docs/plans" "$ARMD/.claude"
    printf '# plan\n' >"$ARMD/docs/plans/p.md"
    bash "$ROOT/hooks/gate-scripts/lib/resolve-repo-dir.sh" arm "$ARMD/docs/plans/p.md" >/dev/null 2>&1
    # vd: same BLOCK / ERROR / allow logic as verdict() above, run in the armed repo. A block
    # is BLOCK only when it is the design-review block the guard produces; the ERR trap
    # (gate line 35) also prints a block, and that one must not pass for the guard firing.
    vd() { # <gate> [command, default ls -la] -> BLOCK | TRAP | ERROR | allow
        local out status
        out=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' \
            "$ARMD" "${2:-ls -la}" | (cd "$ARMD" && bash "$1"))
        status=$?
        if printf '%s' "$out" | grep -q 'Design review must complete before modifying files via Bash'; then
            printf 'BLOCK'
        elif printf '%s' "$out" | grep -q '"block"'; then
            printf 'TRAP'
        elif [[ "$status" -ne 0 ]]; then
            printf 'ERROR'
        else
            printf 'allow'
        fi
    }
    # Control first, on the same copied tree before the injection (as B9 does): the benign
    # call is allowed with a design pending -- else B10 proves nothing about this copy.
    cp -R "$ROOT/hooks/gate-scripts" "$WORK/gs10"
    # The repo really is armed: the gate exits early, allowing, when nothing is pending, so
    # the ls -la allow below means something only if a write is blocked here.
    got="$(vd "$WORK/gs10/pre-implementation-gate.sh" "rm -f x")"
    if [[ "$got" == "BLOCK" ]]; then ok "B10 control: the armed repo blocks a write"
    else no "B10 control: the armed repo blocks a write" "got=$got -- the design is not pending, B10 proves nothing"; fi
    got="$(vd "$WORK/gs10/pre-implementation-gate.sh")"
    if [[ "$got" == "allow" ]]; then ok "B10 control: copied tree allows ls -la with a design pending"
    else no "B10 control: copied tree allows ls -la with a design pending" "got=$got without the injection"; fi
    printf '\n\ndef is_file_mod(cmd, _depth=0):\n    raise RuntimeError("injected")\n' >>"$WORK/gs10/lib/cmdword.py"
    got="$(vd "$WORK/gs10/pre-implementation-gate.sh")"
    if [[ "$got" == "BLOCK" ]]; then ok "is_file_mod raises -> BLOCK"
    else no "is_file_mod raises -> BLOCK" "got=$got — an exception in the classifier must block through the guard"; fi
    rm -rf "$ARMD"
fi
```

- [ ] **Step 3: Prove both guards fire both ways**

Run: `set -o pipefail; bash tests/test-gate-classifier-fail-closed.sh | tail -6` → expected `0 failed` and exit 0.
Then, to see B10 fail without the guard: copy the tree to a temp dir with Step 1 reverted (`git show HEAD:hooks/gate-scripts/pre-implementation-gate.sh > "$T/gs/pre-implementation-gate.sh"`), append the same raising `is_file_mod`, and run the B10 `vd` against it: expected `allow` (not `TRAP` or `ERROR`). That is what shows the BLOCK in Step 2 comes from the guard. Delete the temp dir.

- [ ] **Step 4: Regenerate the lock and commit**

```bash
./scripts/gate-integrity.sh --update
git add hooks/gate-scripts/pre-implementation-gate.sh tests/test-gate-classifier-fail-closed.sh .gate-integrity.lock
git commit -m "fix(gate): an exception inside is_file_mod blocks instead of allowing (#1085)" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 5: Full verification

**Files:** none new; `.gate-integrity.lock` if anything drifted.

- [ ] **Step 1: Lock and lint**

```bash
failed=0
./scripts/gate-integrity.sh --check && echo lock-ok || failed=1
shellcheck --severity=warning tests/test-cmdword-subst-comment-1085.sh tests/test-gate-classifier-fail-closed.sh || failed=1
python3 -m py_compile hooks/gate-scripts/lib/shell_lex.py hooks/gate-scripts/lib/cmdword.py tests/fixtures/cmdword_1085.py && echo compile-ok || failed=1
[ "$failed" -eq 0 ]
```

Expected: `lock-ok`, no shellcheck output, `compile-ok`, exit 0. `--severity=warning` is the level `tests.yml` lints at: `tests/test-gate-classifier-fail-closed.sh` already carries three info-level findings on `main` (SC1091, SC2016), which this plan does not touch.

- [ ] **Step 2: Every shell suite that touches the gate**

```bash
failed=0
um-run test -- bash -lc 'failed=0
for t in tests/test-cmdword-*.sh tests/test-impl-gate-scope-*.sh tests/test-marker-*.sh \
         tests/test-ansic-quote-1043.sh tests/test-escaped-dollar-1048.sh \
         tests/test-herestring-receiver-643.sh tests/test-brainstorming-oracle-wrapper-root.sh \
         tests/test-gate-classifier-fail-closed.sh tests/test-node-hook-containment.sh \
         tests/test-design-clear.sh tests/test-design-effect-921.sh \
         tests/test-design-marker-cd-prearm.sh tests/test-design-marker-degraded.sh \
         tests/test-design-marker-worktree.sh; do
  if bash "$t" >/dev/null 2>&1; then echo "pass $t"; else echo "FAIL $t"; failed=1; fi
done
[ "$failed" -eq 0 ]' || failed=1
for t in tests/test-gate-integrity.sh tests/test-design-gate-docs-commit.sh; do
  if bash "$t" >/dev/null 2>&1; then echo "pass $t"; else echo "FAIL $t"; failed=1; fi
done
[ "$failed" -eq 0 ]
```

Expected: all `pass` and both blocks exit 0, the first with evidence `verified: true` and `cleanup_confirmed: true`. `test-gate-integrity.sh` and `test-design-gate-docs-commit.sh` need a git checkout, which the UM snapshot is not, so they run locally. If either fails, run it on a clean `origin/main` worktree too: a failure that also shows there comes from the local Python, not this branch. Report it that way and do not count it.

- [ ] **Step 3: JS and Python suites**

Run: `um-run test -- bash -lc 'npm ci >/dev/null && npm test && scripts/test-python.sh'`
Expected: exit 0, with evidence `verified: true` and `cleanup_confirmed: true`.

- [ ] **Step 4: Corpus check (local only, not committed)**

Every distinct Bash command in this machine's transcripts (under 65536 characters), judged by `main`'s `is_file_mod` and the branch's, both OR-ed with the gate's redirect check. `main`'s `cmdword.py` imports only `fnmatch`, `re` and `shlex`, so it loads alone from a temp file. The transcripts are private: the script prints counts and flipped commands to this terminal only, never to a file in the repo.

```bash
T="$(mktemp -d)"
git show origin/main:hooks/gate-scripts/lib/cmdword.py >"$T/cmdword.py"
mkdir "$T/mclib"
git archive origin/main hooks/gate-scripts/lib | tar -x -C "$T/mclib" --strip-components 3
python3 -I - "$T/cmdword.py" "$PWD/hooks/gate-scripts/lib" "$PWD/tests/fixtures" "$T/mclib" <<'PY'
import glob, json, os, sys
sys.path[:0] = [sys.argv[2], sys.argv[3]]
import cmdword, cmdword_1085 as f
base = f.load_baseline(sys.argv[1])
check = f.gate_redirect_check()
cmds = set()
for path in glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")):
    with open(path, errors="ignore") as fh:
        for line in fh:
            if '"Bash"' not in line:
                continue
            try:
                content = (json.loads(line).get("message") or {}).get("content")
            except (ValueError, AttributeError):
                continue
            for c in (content if isinstance(content, list) else []):
                if isinstance(c, dict) and c.get("type") == "tool_use" and c.get("name") == "Bash":
                    cmd = (c.get("input") or {}).get("command")
                    if isinstance(cmd, str) and len(cmd) < 65536:
                        cmds.add(cmd)
import re
# A real heredoc: an UNQUOTED `<<` or `<<-` operator (not `<<<`) naming a word that a LATER
# line closes exactly (leading tabs stripped for `<<-`). Quotes and comments are tracked, so `echo '<<E'`
# with a later line `E` does not count, and a herestring or `$((1<<2))` has no closing line.
_HD = re.compile(r"<<(-?)[ \t]*(['\"]?)\\?([^\s'\"<>;&|()]+)\2")   # `<<\EOF`, `<<EOF-1` too
def is_heredoc(cmd):
    # `$(` inside "…" opens fresh quoting (`--body "$(cat <<'EOF'`), and a word-start `#`
    # comments to the newline, so an apostrophe in `# it's` opens nothing.
    i, n, q, stack = 0, len(cmd), None, []
    while i < n:
        c = cmd[i]
        if q:
            if c == "\\" and q == '"':
                i += 2
                continue
            if q == '"' and cmd.startswith("$(", i):
                stack.append(q)
                q = None
                i += 2
                continue
            if c == q:
                q = None
            i += 1
            continue
        if c == "\\":
            i += 2
            continue
        if c == ")" and stack:
            q = stack.pop()
            i += 1
            continue
        if c == "#" and (i == 0 or cmd[i - 1] in " \t\n;&|("):
            nl = cmd.find("\n", i)
            i = n if nl < 0 else nl
            continue
        if c in "'\"":
            q = c
            i += 1
            continue
        if c == "<" and (i == 0 or cmd[i - 1] != "<") and not cmd.startswith("<<<", i):
            m = _HD.match(cmd, i)
            if m:
                nl = cmd.find("\n", m.end())
                body = cmd[nl + 1:].split("\n") if nl >= 0 else []
                if any((x.lstrip("\t") if m.group(1) else x) == m.group(3) for x in body):
                    return True
                i = m.end()
                continue
        i += 1
    return False
def lex_ok(cmd):                   # _lex_bodies as is_file_mod runs it, switch on
    cmdword.shell_lex._cmdword_on[0] = True
    try:
        return cmdword._lex_bodies(cmd, [])[1]
    finally:
        cmdword.shell_lex._cmdword_on[0] = False
loosen = tighten = heredoc = joined = stated = 0
for cmd in cmds:
    r = check(cmd)
    a, b = base(cmd) or r, cmdword.is_file_mod(cmd) or r
    if a and not b:
        loosen += 1
        print("BLOCK->ALLOW", repr(cmd[:200]))
    elif b and not a:
        tighten += 1
        if is_heredoc(cmd):
            heredoc += 1
            print("NEW BLOCK, heredoc", repr(cmd[:200]))
        elif "$\\\n" in cmd:      # the stated `$\<newline>` residual (Out of scope)
            joined += 1
            print("NEW BLOCK, $\\<newline> residual", repr(cmd[:200]))
        elif ((len(cmd) > cmdword._LEX_READING_MAX and ("#" in cmd or "$" in cmd))
              or cmdword._comment_cont_copy(cmd) is not None or not lex_ok(cmd)):
            # Stated over-blocks: the size cap (Deviation 9), the `_lex_bodies` comment copy
            # (spec Residuals) and the depth-0 unreadable rule (Deviation 3).
            stated += 1
            print("NEW BLOCK, stated over-block", repr(cmd[:200]))
        else:
            print("NEW BLOCK, NO HEREDOC", repr(cmd[:200]))
other = tighten - heredoc - joined - stated
# marker_check: Task 1's changes are all off for it (Deviation 11), so none should differ.
# `<(` / `>(` commands are where an ungated change showed up (Deviation 7).
# Each side runs as the gate runs it, on its own lib/, in a scratch cwd.
import subprocess, tempfile
mc_lib = {"main": sys.argv[4], "branch": sys.argv[2]}
mc_cwd = tempfile.mkdtemp(dir=os.path.dirname(sys.argv[1]))   # inside $T, removed with it
def mc(side, cmd):
    payload = json.dumps({"tool_name": "Bash", "cwd": mc_cwd, "tool_input": {"command": cmd}})
    r = subprocess.run([sys.executable, "-I", os.path.join(mc_lib[side], "marker_check.py")],
                       input=payload, capture_output=True, text=True, cwd=mc_cwd, timeout=60)
    return r.stdout.strip().split("|")[0]
mc_n = mc_loosen = 0
for cmd in cmds:
    if "<(" in cmd or ">(" in cmd:
        mc_n += 1
        a, b = mc("main", cmd), mc("branch", cmd)
        if a != b:
            print("marker_check", a, "->", b, repr(cmd[:200]))
            mc_loosen += a.startswith("BLOCK") and not b.startswith("BLOCK")
print(mc_n, "commands with <( or >( in marker_check;", mc_loosen, "block->allow")
print(len(cmds), "commands;", loosen, "block->allow;", tighten, "allow->block,", heredoc, "of them heredoc")
if not cmds:
    print("no transcripts found -- the corpus check proved nothing")
print(joined, "of them the $\\<newline> residual;", stated, "of them a stated over-block")
if other:
    print(other, "allow->block outside both stated residuals -- read each NEW BLOCK, NO HEREDOC line")
sys.exit(1 if loosen or mc_loosen or not cmds or other else 0)
PY
corpus_rc=$?
rm -rf "$T"
[ "$corpus_rc" -eq 0 ]
```

Expected: exit 0, `0 block->allow` and about 40 allow→block, all heredoc (this plan's code, measured during planning: 37,927 commands, 0 and 39; marker_check: 207 `<(` / `>(` commands, none changed). It also prints how many `<(` / `>(` commands marker_check judged on each side, and any whose verdict changed. A non-zero exit stops the plan: a block→allow flip in cmdword or in marker_check (Global Constraints), no transcripts, or an allow→block that is none of a real heredoc (an opening `<<WORD` and a later line that is `WORD`), the stated `$\<newline>` residual (see Out of scope) and a stated over-block (Deviations 3 and 9, spec Residuals). Every new block is printed, to this terminal only, heredoc ones included: read each `NEW BLOCK, heredoc` and `NEW BLOCK, stated over-block` line and confirm it is a heredoc whose body is data, since the bucket check is a scanner, not bash. The heredoc and residual counts depend on each machine's transcripts, so they are recorded, not asserted. Record the two counts, not the commands, in the PR description.

- [ ] **Step 5: Commit anything left**

If Step 1 changed the lock: `git add .gate-integrity.lock && git commit -m "chore(gate): regenerate gate integrity lock (#1085)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`. Otherwise nothing to commit.

---

## Out of scope (spec non-goals and residuals)

- marker_check's own run time over the hook budget on `main` (8 timing inputs skipped) — #1095.
- `bash -c "echo \`rm -rf src\`"` (escaped backtick in a double-quoted program) — missed on `main` and here; #1094.
- Deviation 4's heredoc-body class — #1093.
- Spellings of the same class that Task 3 does not pin — #1101 (Deviation 12).
- The #1063 `case` over-read stays.
- The heredoc over-blocks (39 on the planning machine's corpus) and the `_lex_bodies` over-block are stated residuals.
- A read-only command holding `$\<newline>` can over-block: the third reading joins the continuation (Task 2 Step 5), and a quoted `<<` or verb text elsewhere in the command can then read as live (`echo '<< rm -rf src'; echo $\<newline>{HOME}`). It only adds blocks.
- `_WORD_HASH_RE`'s `\s` also matches CR, so a CR before a `#` on a continued line triggers `_comment_cont_copy` although bash reads that `#` mid-word (Deviation 5). The copy is one more reading OR-ed in, so this can only over-block; it is kept as the prototype measured it.

<!-- design-review-coverage: FULL 3/3  -->
