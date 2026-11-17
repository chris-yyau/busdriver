# Heredoc Gate Part 2a: Unreadable Programs (#1093) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use busdriver:subagent-driven-development (recommended) or busdriver:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close member 1b of #1093, which part 1 (#1115) left open — known-allow rows O7–O11 in `tests/fixtures/heredoc_1093.py`, plus O2 (#1112) — so each blocks while a design is pending, without turning any block into an allow.

**Architecture:** One additive change to the design gate's classifier, invisible to `marker_check`: **member 1b — unreadable programs block at any depth.** A string handed whole to a shell (`bash -c`/`sh -c`/`eval`/`find -exec … sh -c` operand) is marked `_program`. When the text the gate reads is the program as bash runs it, a lexer or tokenizer give-up on it blocks, as one at depth 0 already does.

**Depends on:** `docs/plans/2026-11-16-heredoc-body-detectors-1093-part2b.md` (the byte-delimiter and split-terminator detectors, which close O5, O12 and O13). That plan lands first; this one is written and measured against main with it merged — "main" below means main plus that plan. This plan was split from the combined part-2 plan after nine review rounds; the detectors went to their own plan, unchanged.

**Tech Stack:** Python 3 (stdlib only) in `hooks/gate-scripts/lib/`, bash test suites in `tests/`, fixture rows in `tests/fixtures/heredoc_1093.py`.

**Global Constraints:**
- Fail-CLOSED, additive: every change can only add a block. Task 1 adds blocks at give-up sites and nothing else: each site returns main's value unless the as-written rule blocks. Checked in both directions over rows, the committed grid, two corpora and the #1085 fuzz (Task 2 Step 6). Measured: no command changes from block to allow.
- New over-blocks are stated and pinned as KNOWN_BLOCK (K11–K15, K20–K22, K28–K32); main-allowed writes this part does not close are KNOWN_ALLOW (O14, O16, O17, O21–O23, O25–O27).
- `marker_check.py`'s verdicts must not change: every change is in `cmdword.py`, which marker_check does not import.
- No new dependencies. No change to `pre-implementation-gate.sh`.
- Any edit under `hooks/gate-scripts/**` needs `./scripts/gate-integrity.sh --update` committed with it.
- Hook latency: every new scan is linear, and Task 1 walks no segment main does not; a near-cap (≈30K char) command classifies within the fixture's `fx.LIMIT`. The slowest shape measured (review round 9's `${a-` chain, two `$( )`, a quoted backtick, then a write) takes 3.50 s on the branch, 3.52 s on the base and 3.55 s on main (quiet machine, best of 3): the margin to 4.0 s is main's own, and it goes in the follow-up issue.
- Corpus commands are classified only, never executed.
- Commit subjects lower-case (commitlint `subject-case`).

---

## Context

### Why the rows are allowed today

- **O7–O11, O2 (member 1b).** `_is_file_mod_text` blocks an unreadable command only at `_depth == 0` (`cmdword.py` ~5071), because most deeper strings are DERIVED: a `$( )` body `_command_substitutions` cut short at a `)` it should not have read as a closer, or `_ansi_c`'s respelling (`echo $'it\'s'` → `echo 'it\'s'`). A `bash -c` program is not derived — bash runs it as written, command by command, so `echo x > src/f⏎echo '` writes before the syntax error. Two leaks: the lexer give-up (`extra_ok` False) is ignored at depth ≥ 1 (O7, O8, O10, O11); a tokenizer give-up falls back to the verb-only `_regex_fallback`, which cannot see a redirect (O9, O2/#1112).
### When a program's text is as written

`_executed_operands` extracts program operands from the NORMALIZED text, and the base reading's `_normalize` (`cmdword.py` ~2828) rewrites it. Blocking every unreadable program would refuse readable heredoc programs (fixture C8, C9), whose newlines became ` ; `. The third reading (`_lex_reading`, #1085) hands programs over as written.

A program is treated as written (`_as_written`) when ALL hold:
1. it is a program operand (`_program`);
2. no ancestor text was derived (`_derived` — set while classifying `_ansi_c`'s respelling and any `$( )` body `shell_lex` did not also find);
3. it is read under the third reading, OR under the base reading (not the second, `_ansi_c_reading`) when none of `_normalize`'s rewrites can change it:

| `_normalize` rewrite (base reading) | can change a program when | clause 3 excludes it by |
|---|---|---|
| CR → newline | the root holds a CR | `_root_lexed` |
| comment defused, then newline → ` ; ` (the comment swallows the next lines) | the root holds a `#` | `_root_lexed` |
| `$'`/`$"` → `'`/`"`, quote-unaware (`"x\$"` → `"x\"`) | the root holds a `$` | `_root_lexed` |
| `${IFS}`/`$IFS` → space | the root holds a `$` | `_root_lexed` |
| function header `name()` dropped (`_FUNC_DEF_RE`, any name characters) | `_FUNC_DEF_RE` matches the root as `_normalize` sees it (continuations joined, newlines read as ` ; `), or its keyword-led backtick copy | `_root_lexed` (via `_func_header`) |
| newline → ` ; ` inside a heredoc body | the program holds two `<` and the root a newline | `cmd.count("<") < 2 or _root_flat` |
| every `\<newline>` deleted, even an escaped one | an even backslash run ends a line | not excluded: only ever an over-block (K11), pinned |

`_root_flat` (no newline and no `$` in the root) and `_root_lexed` (`$`, `#` or CR in the root, or a header `_FUNC_DEF_RE` would strip) are set once per top-level `is_file_mod` call, beside the memo resets. The newline→` ; ` rewrite creates or closes no quote by itself; the `\<newline>` deletion can, which is why K11 (a read-only program it mangles into a give-up) blocks — pinned rather than excluded, because excluding even runs would hand the same shape with a write back to the verb-only fallback.

This part does not claim that every program is read strictly in some reading: the third reading runs only for a root with a `$` or `#` or a heredoc shape (#1085), and on a heredoc's cut text. Programs that slip between the two and that main also allows are KNOWN_ALLOW rows (O17, O21), not code.

Trace (fixture C8, `bash -c 'echo hi; cat <<E⏎it'"'"'s⏎E⏎echo ok'`):
```
depth=1 prog=True  lex=False -> False :: "echo hi; cat <<E ; it's ; E ; echo ok"   (base reading: two <, so not as-written)
depth=1 prog=True  lex=True  -> False :: "echo hi; cat <<E\nit's\nE\necho ok"     (third reading: as written, readable)
```

---

## File Structure

| File | Change |
|------|--------|
| `hooks/gate-scripts/lib/cmdword.py` | `_program` threaded `is_file_mod` → `_is_file_mod_readings` → `_is_file_mod` → `_is_file_mod_text`; `_derived` + `_derived_mod`; `_root_flat`, `_root_lexed`; `_confirmed_bodies` + `_unjoined`; `_lexed_heredoc`; `_func_header`; the as-written rule at three give-up sites; the two operand call sites pass `_program=True` |
| `.gate-integrity.lock` | regenerated |
| `tests/fixtures/heredoc_1093.py` | row moves, new BLOCK / ALLOW / KNOWN_BLOCK / KNOWN_ALLOW rows, switch checks, timing rows |
| `docs/plans/2026-11-16-unreadable-programs-1093-part2.md` | this plan, committed with the implementation |

---

### Task 1: Member 1b — programs as written block when unreadable

**Files:** Modify `hooks/gate-scripts/lib/cmdword.py`

**Interfaces:**
- Produces: `is_file_mod(cmd, _depth=0, _program=False)`; `_derived = [False]`; `_derived_mod(text, depth) -> bool`; `_root_flat = [False]`, `_root_lexed = [False]`; `_confirmed_bodies(cmd) -> set`; `_unjoined(text) -> str`; `_lexed_heredoc(cmd) -> bool`. Public call shape `is_file_mod(cmd)` unchanged.

- [ ] **Step 1: thread `_program` and key the memo on it**

```python
def is_file_mod(cmd, _depth=0, _program=False):
    ...
    key = (cmd, _depth, _lex_reading[0], _ansi_c_reading[0], _program, _derived[0])
    ...
        r = _is_file_mod_readings(cmd, _depth, _program)

def _is_file_mod_readings(cmd, _depth=0, _program=False):
    if _is_file_mod(cmd, _depth, _program):
        return True
    ...  # rest unchanged: readings start only at depth 0, where _program is False

def _is_file_mod(cmd, _depth=0, _program=False):
    ...
    if _is_file_mod_text(cmd, _depth, _program=_program):
        return True
    ...
    for hf in _heredoc_frees(cmd):
        ...
            # A program's heredoc-free text is as written only under the third reading: in
            # the base reading the program arrived normalized (#1093 1b).
            if _is_file_mod_text(hf, _depth, _fresh=False, _program=_program and _lex_reading[0]):
                return True

def _is_file_mod_text(cmd, _depth=0, _fresh=True, _program=False):
```

The memo key carries `_program` and `_derived[0]`: the same text reached as a derived string (lenient) and as a program (strict) must not share a verdict.

- [ ] **Step 2: mark derived texts**

Next to `_verdict_memo`:

```python
# True while a DERIVED text is classified -- _ansi_c's respelling, or a body only
# _command_substitutions found -- so no program inside it counts as written (#1093 1b).
_derived = [False]
_root_flat = [False]
_root_lexed = [False]


def _derived_mod(text, depth):
    prev, _derived[0] = _derived[0], True
    try:
        return is_file_mod(text, depth)
    finally:
        _derived[0] = prev
```

In `_is_file_mod_text`:

```python
    resolved = _ansi_c(cmd)
    if resolved != cmd and _derived_mod(resolved, _depth + 1):
        return True
    ...
    lexed = _confirmed_bodies(cmd)
    for body in bodies:
        if (is_file_mod if _unjoined(body) in lexed else _derived_mod)(body, _depth + 1):
            return True
```

with, before `_heredoc_free`:

```python
def _confirmed_bodies(cmd):
    # The bodies shell_lex found in cmd, plus each one's backtick spelling with a backslash
    # layer dropped (_command_substitutions' `bare`, #1063): bash parses that one, so it is
    # as written too. A body outside this set may be cut short, so it is derived (#1093 1b).
    # Compared with every `\<nl>` removed (_unjoined): shell_lex reads joined text and
    # _command_substitutions the text as written, so one body differs by its continuations.
    out = set()
    for b in _lex_memo.get(cmd, ((), False))[0]:
        for v in (b, re.sub(r"\\([$`\\])", r"\1", b), re.sub(r"\\([$`\\" + _DQ + "])", r"\1", b)):
            out.add(_unjoined(v))
    return out


def _unjoined(text):
    return text.replace(chr(92) + chr(10), "")


def _lexed_heredoc(cmd):
    # Does shell_lex find a heredoc operator in cmd? `_heredoc_shaped` is only a cheap
    # superset: two input redirects on two lines hold no body (#1093 1b).
    spans = []
    shell_lex._subst_bodies(cmd, spans)
    return len(spans) > 1
```

`_command_substitutions` (~2982–2991) appends, per backtick body, the raw slice AND a `bare` copy with one backslash layer removed — the text bash parses (#1063); `shell_lex._subst_bodies` returns only the raw slice. Without the `bare` forms, the program bash runs would be marked derived and exempt (rows R76–R78). The two `re.sub` forms are `_command_substitutions`' own transform outside and inside double quotes; an extra confirmed spelling only makes a program strict. `_lex_memo[cmd]` is filled by the `_lex_bodies(cmd, bodies)` call just above, so the lookup does not miss on a path that reaches the loop; a miss would read every body as derived — main's behaviour.

- [ ] **Step 3: the root flags**

In `is_file_mod`, beside the depth-0 memo resets (the `_split_term` reset is the detectors plan's):

```python
        # No newline and no `$` (so no `$'\n'`) anywhere: no program at any depth holds a
        # heredoc body or a `\<nl>` for the base reading to break (#1093 1b).
        _root_flat[0] = chr(10) not in cmd and "$" not in cmd
        # Does the base reading's _normalize respell a program in this root? A CR read as a
        # newline; a comment defused and then extended by newline -> ` ; `; `$'`/`$"` losing
        # their `$` and `${IFS}` read as a space (both need a `$`); a function header `name()`
        # dropped (only where _FUNC_DEF_RE itself matches). With any, the base reading is not as
        # written (#1093 1b).
        _root_lexed[0] = "$" in cmd or "#" in cmd or chr(13) in cmd or _func_header(cmd)
```

and, next to `_heredoc_shaped`:

```python
def _func_header(cmd):
    # Could the base reading's header strip (_FUNC_DEF_RE, in _normalize) drop a `name()` from
    # cmd? Searched on cmd with its continuations joined and its newlines read as ` ; `, as
    # _normalize sees it, and on the keyword-led backtick copy it also cuts from (#1093 1b).
    t = cmd.replace(chr(92) + chr(10), "").replace(chr(10), " ; ")
    return _FUNC_DEF_RE.search(t) is not None or _FUNC_DEF_RE.search(_BACKTICK_KW_RE.sub(";", t)) is not None
```

A bare `()` test (review round 8) excluded any root holding a quoted `"()"`, leaving a writing program with no strict reading (R111). `_root_lexed` has exactly four triggers — `$`, `#`, CR, a function header — and the third reading (the strict one left once the base reading is excluded) starts only on `$`, `#` or a heredoc shape. The two triggers it does not share are the whole residual of this clause: a CR (O22) and a function header, whether respelled (O21) or real (O23, `f() { :; }; bash -c …`). Main allows all three; this part pins them as KNOWN_ALLOW and the follow-up issue aligns the third reading's trigger with `_root_lexed`'s.

- [ ] **Step 4: the as-written rule at three give-up sites**

In `_is_file_mod_text`, the lexer give-up:

```python
    extra, extra_ok = _lex_bodies(cmd, bodies)
    # A program handed whole to a shell runs as written, so a give-up on it blocks like one
    # at depth 0 -- when the text IS as written (plan Context, clause 3) (#1093 1b).
    _as_written = _program and not _derived[0] and (
        _lex_reading[0] or (not _ansi_c_reading[0] and not _root_lexed[0]
                            and (cmd.count("<") < 2 or _root_flat[0])))
    if not extra_ok and (_depth == 0 or _as_written):
        return True
```

the tokenizer give-up:

```python
    pairs, ok = _split_with_ops(_norm)
    if not ok:
        # With a heredoc in it, the body text is data the tokenizer reads as commands: left to
        # the heredoc-free pass, whose cut text gets this rule under the third reading.
        if _as_written and not _lexed_heredoc(cmd):
            return True
        return _regex_fallback(cmd)      # same residual as the substitution path above
```

and the per-segment `shlex` give-up (main: `return _regex_fallback(cmd)`):

```python
        except ValueError:
            # ... Same residual as the two paths above: verb patterns only. An as-written
            # program blocks instead, as at the split site above: `_split_with_ops` reads a
            # backtick as opaque and shlex does not, so `echo `echo "hi`` gives up HERE
            # (#1093 1b). With a heredoc the later lines include body lines, which are data,
            # so main's verdict stands. The segments after this one are not read, as on main
            # (O26, O27: reading on cost latency the hook cannot spare -- review round 9).
            if _as_written and not _lexed_heredoc(cmd):
                return True
            return _regex_fallback(cmd)
```

Why the shlex site does not read on: main's `return _regex_fallback(cmd)` stops at the first unparseable segment, so `` echo `echo "hi`⏎bash -c 'echo x > src/f' `` never reaches its `bash -c`; main allows it and it writes (O26, O27). Review rounds 5–9 read on past the give-up, and every fix to that (checks run once, an exit when the command holds a heredoc, a budget charge per unparseable segment) drew a new finding. The last version still added ≈0.4 s on round 9's near-cap `${a-` chain shape: 3.91 s against the base's 3.52 s, with `fx.LIMIT` at 4.0 s, and a hook killed at its timeout ALLOWS. No goal row needs it: O2 and O7–O11 close through the as-written block. So it is left out, and O26 and O27 go to the follow-up issue. A write INSIDE an unparseable segment is not read either (O25).

- [ ] **Step 5: mark the operands as programs**

Both `_executed_operands` loops (the `-exec`/runner helper ~4124, and the one in `_is_file_mod_text` ~5250):

```python
    for prog in _executed_operands(toks):
        if is_file_mod(prog, depth + 1, _program=True):
            return True
```

(the second site uses `_depth + 1`). The loop at ~2064 (the stdin-shell test) does not classify and is unchanged. `_executed_operands` also yields some operands that are not programs — an attached `-c`'s positional (`sh -c'echo "$0"' "it's"`), and, through its `watch` branch (~3804–3874), every later token (`watch -x echo "it's"`) — so an unreadable one of those now blocks (K14, K15). So does a here-string word after `-c` (`bash -c 'wc -l' <<< "it's"`, K28, K29) and a later `-c` among a program's positionals (K31). Telling them apart means restructuring `_executed_operands`, whose conservative scan keeps wrapped runners blocked; the over-block is pinned instead.

---

### Task 2: Fixture rows, lock, verification

**Files:** Modify `tests/fixtures/heredoc_1093.py`, `.gate-integrity.lock`

Helpers already in the fixture: `q` (`shlex.quote`), `SQ`, `BT`, `P19`, `DQ`, `FIND`. Add `TWO = ": </dev/null </dev/null\n"` and `BARE = r"bash -c 'echo x \\\> src/f" + "\n" + r"echo \\\"'"`.

- [ ] **Step 1: move rows.** KNOWN_ALLOW → BLOCK (labels kept): O2, O7, O8, O9, O10, O11. KNOWN_ALLOW keeps O1, O3, O4, O6 and the detectors plan's O18–O20, O24.

- [ ] **Step 2: new BLOCK rows** — every one writes under bash 5 (the fixture checks) and blocks; "(main blocks)" marks a row main blocks too, pinning additivity:

```python
    ("R64 two < then O8", "bash -c " + q(TWO + P19)),
    ("R65 two < then O9", "bash -c " + q(TWO + DQ)),
    ("R66 R65 in find -exec", FIND + q(TWO + DQ) + " \\;"),
    ("R67 R65 in a double-quoted $( )", ': "$(bash -c ' + q(TWO + DQ) + ')"'),
    ("R68 O9 in backticks", ": " + BT + "bash -c " + q(DQ) + BT),
    ("R69 O8 in a nested $( )", ': "$(: "$(bash -c ' + q(P19) + ')")"'),
    ("R70 O9 after a ${v%)} the paren counter cuts at", ': "$(echo ${v%)}; bash -c ' + q(DQ) + ')"'),
    ("R71 O9 beside an unrelated $'x'", "echo $'x'; bash -c " + q(DQ)),
    ("R72 O9 under eval", "eval " + q(DQ)),
    ("R73 O9 under sh -c in bash -c (main blocks)", "bash -c " + q("sh -c " + q(DQ))),
    ("R75 an even run, then the delimiter, then a write (main blocks)", "cat <<EOF\nit's\n\\\\\nEOF\necho x > src/f\necho 'y'"),
    ("R76 O9 in a backtick body's bare spelling", ": " + BT + BARE + BT),
    ("R77 R76 inside double quotes", ': "' + BT + BARE.replace('"', '\\"') + BT + '"'),
    ("R78 a bare-spelling O9 whose raw redirect sits in a double quote",
     ": " + BT + "bash -c 'echo \\\\\"\necho x > src/f\necho \"'" + BT),
    ("R82 an open quote in a backtick, then a write, in bash -c", "bash -c " + q('echo `echo "hi`\necho x > src/f')),
    ("R83 R78 behind a continuation", ": " + BT + "true \\\n; bash -c 'echo \\\\\"\necho x > src/f\necho \"'" + BT),
    ("R84 one-line two-< program ending in a lone backslash", "bash -c ': </dev/null </dev/null; echo x > src/f; echo \\'"),
    ("R91 a backtick in a top-level body holding a two-< program (main blocks)",
     "cat <<E\n" + BT + "bash -c ': </dev/null </dev/null\necho x > src/f\necho \"'" + BT + "\nE"),
    ("R100 an unreadable program in a backtick holding a heredoc", ": " + BT + "cat <<E\nhi\nE\nbash -c 'echo x > src/f\necho \"'\n" + BT),
    ("R104 a bare-spelling program after a heredoc in a backtick",
     ": " + BT + "bash -c 'cat <<E\nhi\nE\necho \\\\\"\necho x > src/f\necho \"'" + BT),
    ("R106 <\\<nl>< after an apostrophe heredoc in bash -c (main blocks)",
     "bash -c 'cat <<A\nit'\\''s\nA\ncat <\\\n<B\nhi\nB\necho x > src/f\necho \"'"),
    ("R111 a quoted () line, then O9", "bash -c 'echo \"()\"\necho x > src/f\necho \"'"),
```

R76 after backtick processing is `bash -c 'echo x \\> src/f⏎echo \\"'`: line 1 writes, line 2 opens a quote; the raw body's program has neither, which is why only the bare spelling shows the write. R111 is review round 8's: a quoted `"()"` that a bare-parens `_root_lexed` test let through.

- [ ] **Step 3: new ALLOW controls** (none writes; all allow on main too):

```python
    ("C28 two < readable program", "bash -c " + q(TWO + "echo ok")),
    ("C35 an anchored grep in bash -c ($\" respelling)", "bash -c 'grep \"x\\$\" src/impl.py'"),
    ("C37 a comment line, then a quoted backtick, in bash -c", "bash -c " + q("# check backticks\ngrep '`' src/impl.py")),
    ("C39 a function header in a one-line program", "bash -c 'echo \"a;\"foo()'"),
    ("C40 a function header after an escaped ;", "bash -c 'echo \\; \"a()\"'"),
    ("C43 a CR in a read-only program", "bash -c 'echo \"a\rb\"\necho ok'"),
```

(C8/C9/C15–C17 already pin the readable-program and quoted-delimiter controls.)

- [ ] **Step 3a: KNOWN_BLOCK rows** — new over-blocks, none writes, main allows each:

```python
    ("K11 base-reading \\<nl> deletion breaks a read-only program", "bash -c 'echo a\\\\\n'\"'\"'b'\"'\"''"),
    ("K12 a one-line program ending in an open quote", "bash -c ': </dev/null </dev/null; echo x > src/f; echo '\"'\"''"),
    ("K13 a read-only program whose segment shlex cannot read", "bash -c 'echo " + BT + "echo \"hi" + BT + "\necho ok'"),
    ("K14 an attached -c's positional read as a program", "sh -c'echo \"$0\"' \"it's\""),
    ("K15 a wrapper's later token read as a program", "watch -x echo \"it's\""),
    ("K20 a split terminator, then a comment-led program (Task 1 x the defuser)",
     "cat <<EOF\nhello\nE\\\nOF\nbash -c '# check backticks\ngrep '\\''`'\\'' src/impl.py'"),
    ("K21 K13 with heredoc lines after the bad segment",
     "bash -c 'echo " + BT + "echo \"hi" + BT + "\ncat <<EOF\necho x > src/f\nEOF\necho ok'"),
    ("K22 a one-line program with a quoted () ending in an open quote", "bash -c 'echo \"()\"; echo x > src/f; echo \"'"),
    ("K28 a here-string word after -c read as a program", "bash -c 'wc -l' <<< \"it's\""),
    ("K29 a bare -c operand with a here-string", "bash -c cat <<< \"it's\""),
    ("K30 a case arm in a process substitution in a one-line program", "bash -c 'cat <(case x in\na) echo hi;;\nesac)'"),
    ("K31 a later -c in a program's positionals", "bash -c 'echo \"$1\"' _ -c \"it's\""),
    ("K32 a respelled header nested two programs down", "sh -c \"bash -c 'echo \\; \\\"a(\"''\")\\\"'\""),
```

K22, like K12, does not write: bash rejects the one-line program before running any of it. K20: the third-reading defuser ends `<<EOF`'s body unjoined (it runs before the join), so the program reads `# check … ; grep '`' …` and gives up; main makes the same misread and is lenient. K21: the program's heredoc-free text `echo `echo "hi`⏎cat ⏎echo ok` is read as written and gives up (K13's mechanism).

- [ ] **Step 3b: KNOWN_ALLOW rows** — they write; main allows each; this part does not close them:

```python
    ("O14 an even backslash run, then a redirect line", "bash -c 'echo a\\\\\n> src/f'"),
    ("O16 an escaped backtick inside a backtick body, then O9",
     ": " + BT + "echo \\" + BT + "true\\" + BT + "; bash -c 'echo \\\\\"\necho x > src/f\necho \"'" + BT),
    ("O17 a program behind a word in a top-level body's backtick",
     "cat <<E\nhi " + BT + "bash -c ': </dev/null </dev/null\necho x > src/f\necho \"'" + BT + "\nE"),
    ("O21 a function-header respelling, then O9", "bash -c 'echo \\; \"a()\"\necho x > src/f\necho \"'"),
    ("O22 a CR in the root, then O9", "bash -c 'echo \"a\rb\"\necho x > src/f\necho \"'"),
    ("O23 a function header, then O9", "f() { :; }; bash -c 'echo x > src/f\necho \"'"),
    ("O25 a write inside an unparseable segment", "bash -c 'echo x > src/f' " + BT + "\"" + BT),
    ("O26 an unparseable segment, then bash -c, in $( )", ": $(echo " + BT + "echo \"hi" + BT + "\nbash -c 'echo x > src/f')"),
    ("O27 an unparseable segment, then bash -c, at top level", "echo " + BT + "echo \"hi" + BT + "\nbash -c 'echo x > src/f'"),
```

- [ ] **Step 3c: `switch_rows()` checks** — marker_check must read as on main. Append to `checks`:

```python
        # #1093 part 2a: only a header _FUNC_DEF_RE would strip excludes the base reading.
        ("a quoted () is not a header", not cmdword._func_header("echo \"()\"\necho x")),
        ("a header is a header", cmdword._func_header("f() { :; }")),
```

- [ ] **Step 4: timing rows** in `rows()`, after the existing ones:

```python
    # Thousands of segments shlex cannot read, at depth 0 and inside a heredoc-carrying
    # program: the first give-up decides the command, so the rest are not walked (#1093 part 2).
    for name, cmd in (("depth-0", (BT + '"' + BT + " ; ") * 5000 + "echo x > src/f"),
                      ("program", "bash -c 'cat <<E\nx\nE\n" + (BT + '"' + BT + "\n") * 5000 + "echo x > src/f'")):
        got, dt = fx.hook(repo, cmd, timeout=10)
        label = "timing: %s, %d chars of unparseable segments blocked in %.2fs" % (name, len(cmd), dt)
        fx.ok(label) if got == "block" and dt <= fx.LIMIT else fx.no(label, "over %.1f s or %s" % (fx.LIMIT, got))
```

The depth-0 timing row blocks through the gate's own raw redirect check (`is_file_mod` is False there, on the base too), so it pins latency only; the program row is the one `is_file_mod` blocks.

- [ ] **Step 5: regenerate the lock, run focused suites**

```bash
./scripts/gate-integrity.sh --update
bash tests/test-heredoc-body-1093.sh            # all rows pass
bash tests/test-cmdword-case-backtick-1063.sh   # 31/0
bash tests/test-gate-classifier-fail-closed.sh
bash tests/test-ansic-quote-1043.sh
bash tests/test-escaped-dollar-1048.sh
bash tests/test-marker-string-executors.sh
bash tests/test-gate-integrity.sh
```

- [ ] **Step 6: whole-suite, grid and corpus verification**
  - Full shell suite on UM, branch and main on the same host, keeping every script's full output and exit code:
    ```bash
    um-run test -- bash -lc 'mkdir -p out; f=0; for t in tests/test-*.sh; do n=$(basename "$t" .sh); bash "$t" >"out/$n.log" 2>&1; rc=$?; echo "$n rc=$rc"; [ $rc -eq 0 ] || f=1; done; grep -h -E "^ *(FAIL|not ok)|FAILED" out/*.log | sed "s/[0-9.]*s\$//"; exit $f'
    ```
    Acceptance per script: fails on the branch only → regression; fails on both → the SAME failing-assertion lines on both (timings stripped); stopped by an environment error before its assertions → INCONCLUSIVE, re-run alone locally on both trees. If UM is unreachable (exit 70), run the same comparison locally over every `tests/test-*.sh` matching `cmdword|pre-implementation-gate|shell_lex`, and say so.
  - The detectors plan's grid through both trees' real hooks, BOTH tails, plus the `bash -c` program container and four cut-body program probes (an unreadable writing program after a heredoc in a backtick or `<( )`, with and without two `<`): no cell changes verdict except a probe main allows that now blocks; the committed `GRID_OPEN` is unchanged.
  - #1085 fuzz with origin/main's lib as baseline (`tests/fixtures/cmdword_1085.py fuzz <armed> --full --baseline <main lib>/cmdword.py`): 0 writing commands allowed, 0 block→allow.
  - Transcript corpus, classification only: every transcript Bash command holding `-c`, `eval`, `-exec`, `$'`, `<<`, `--command` through both trees' `cmdword.is_file_mod`, and every heredoc-shaped or program-carrying command through both trees' real `pre-implementation-gate.sh` in an armed repo. Expected: 0 allow on the branch that main blocks; an allow→block only where the as-written rule blocks a give-up in a program operand, each one named in the PR body.

- [ ] **Step 7: commit**

```bash
git add hooks/gate-scripts/lib/cmdword.py .gate-integrity.lock tests/fixtures/heredoc_1093.py docs/plans/2026-11-16-unreadable-programs-1093-part2.md
git commit -m "fix(gate): block unreadable programs at any depth (#1093, part 2a)"
```

PR body: `Closes #1093` (with the detectors plan merged), `Closes #1112`. File one follow-up issue listing O14, O16–O27 with their mechanisms (O18–O20 and O24 are the detectors plan's residuals), and main's 3.55 s on the `${a-` chain shape in Global Constraints.

---

## Spike evidence (scratch copy, not committed)

Two scratch trees: `/private/tmp/claude-501/-Volumes-Work-Projects-busdriver/5e8a689e-30af-4e75-80d3-86139dd033ee/scratchpad/spike8` is main plus the detectors plan as approved (this plan's base), and `spike11` beside it is that plus this plan's Task 1 (review round 9 probed `spike9`, which read on past a `shlex` give-up; `spike11` is `spike9` with that read-on removed, and `spike10` is `spike9` plus round 9's budget charge, kept for the timing comparison). `spike4` is main plus Task 1 alone, for the independence check. Measured through each tree's real hook, with the bash-5 write check first:
- Every row in Steps 2–3b, as spelled, spike11 against spike8: each BLOCK row writes and blocks; each ALLOW row does not write and allows on both; each KNOWN_BLOCK row does not write, the base allows, the branch blocks; each KNOWN_ALLOW row writes and both allow. No row the base blocks is allowed. All 50 rows hold; against spike8 alone 31 of them fail, so the check can fail.
- Grid (the detectors plan's 110 cells) spike11 against spike8: no committed cell changes verdict; the two cut-body backtick probes the base allows now block. spike4 against main: 0 regressions, 3 writing cells closed, 0 read-only cells blocked.
- Timing (quiet machine, best of 3): the two segment rows block in ≈0.46 s. Round 9's `${a-` chain shapes (one `$( )`, `$''` then `$( )`, two `$( )`): branch 2.39 / 3.20 / 3.50 s, base 2.43 / 3.21 / 3.52 s, main 2.41 / 3.24 / 3.55 s; `spike10` (reading on, with the budget charge) 2.80 / 3.59 / 3.91 s. `sweep_a.py` (round 9's budget shapes): no filler count allowed on the branch. Step 3c's switch checks pass.
- `test-heredoc-body-1093.sh` on spike11 with the base's fixture: exactly the Step 1 flips (O2, O7–O11 now block), nothing else; every other gate suite (`tests/test-*.sh` matching cmdword/pre-implementation-gate/shell_lex, plus string-executors) equal to the base (any that fails there for environment reasons fails the same way).
- Corpora (classification only), spike11 against spike8: real gate in an armed repo, 0 changes / 8,680 commands; `is_file_mod`, 0 changes / 9,085. spike4 against main: 0 / 8,629 and 0 / 9,031.
- #1085 full fuzz with spike8's lib as baseline: 38,049 writing commands, none allowed, no block→allow.

## Residuals (stated, not fixed here)

- O14, O16, O17, O21–O23, O25–O27 (KNOWN_ALLOW; main allows each): an even backslash run before a redirect line (base-reading `\<nl>` deletion, K11's root); an escaped backtick ending a backtick body early (`_command_substitutions`' `s.find`); a program behind a word in a top-level body's backtick when the root has no `$`/`#` (the third reading reads that root's heredoc-free text); a function-header respelling when the root has no `$`/`#` (no third reading); a CR in a root with no `$`/`#`/heredoc (`_normalize` reads it as a newline and no third reading runs, O22); a real function header before such a program (O23, the same trigger gap as O21); a write inside an unparseable segment, which shlex cannot tokenize (O25); a write in a segment after an unparseable one, which main's verdict stops short of (O26, O27). One follow-up issue, with the detectors plan's O18–O20 and O24.
- #1113 item 1 (O3, O4), #1101 item 3 (O1) and O6 stay KNOWN_ALLOW.
- K11–K15, K20–K22, K28–K32: stated over-blocks (Task 1 Steps 3–5).

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
