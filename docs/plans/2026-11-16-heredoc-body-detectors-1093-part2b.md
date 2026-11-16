# Heredoc Gate Part 2b: Byte-Delimiter and Split-Terminator Detectors (#1093) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use busdriver:subagent-driven-development (recommended) or busdriver:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close known-allow rows O5 (#1113 item 2), O12 and O13 in `tests/fixtures/heredoc_1093.py` — a heredoc whose end bash finds somewhere the gate's readers do not — so each blocks while a design is pending, without turning any block into an allow.

**Architecture:** Two detectors, each an OR term on `cmdword.is_file_mod`'s depth-0 result. Neither changes where any reader ends a heredoc body.
1. **Byte delimiter (Task 1).** A `$'…'` escape for a byte ≥ 0x80 and a heredoc shape, each seen in any text the gate classifies during the call — the command, or any text decoded or cut from it at any depth — block the command.
2. **Split terminator (Task 2).** When an expanding heredoc body has a line that, joined at its `\<newline>`s as bash joins it, equals the delimiter while the line as read does not, the command blocks.

Why detectors: an earlier draft taught the lexer bash's exact body end and let every reader use it. Five review rounds each found a command that writes, that main BLOCKS only because a body never closed, which the exact end then handed to a downstream reader with a known quote gap (R81, R93, R94, R96, R101–R103 below pin them). The class is "new body end × every reader gap", which no list of containers closes. A detector leaves every reader on main's ends and only adds an OR term, so block→allow is impossible by construction.

This is the first of two plans split from `2026-11-16-unreadable-programs-1093-part2.md` (which keeps member 1b, programs read as written). This one lands first; the other is measured on top of it.

**Tech Stack:** Python 3 (stdlib only) in `hooks/gate-scripts/lib/`, bash test suites in `tests/`, fixture rows in `tests/fixtures/heredoc_1093.py`.

**Global Constraints:**
- Fail-CLOSED, additive: the change is two OR terms on a depth-0 result. Checked over rows, a grid, two corpora and the #1085 fuzz (Task 3 Step 6): no command changes from block to allow.
- New over-blocks are stated and pinned as KNOWN_BLOCK (K16–K19, K23–K27); main-allowed writes in this area that this plan does not close are KNOWN_ALLOW (O18–O20, O24).
- `marker_check.py`'s verdicts must not change: the one `shell_lex` change sets a flag only under `shell_lex._cmdword_on[0]` (true only while `cmdword.is_file_mod` runs), and no reader's return value changes.
- No new dependencies. No change to `pre-implementation-gate.sh`.
- Any edit under `hooks/gate-scripts/**` needs `./scripts/gate-integrity.sh --update` committed with it.
- Hook latency: every new scan is linear; a near-cap (≈30K char) command classifies within the fixture's `fx.LIMIT`.
- Corpus commands are classified only, never executed.
- Commit subjects lower-case (commitlint `subject-case`).

---

## Context

- **O12.** `_bash_ansi_c` maps each `\xHH` to its own code point, so `$'E\xc3\xa9'` is `EÃ©` where bash has the bytes of `Eé`; the body's `Eé` line never ends it and the body swallows the write.
- **O13, O5.** `shell_lex._join_continuations` is not body-aware: an apostrophe in an unquoted body (`it's`) opens a quote, so the body's `E\⏎OF` is never joined, `_heredoc_terminator` never finds `EOF`, and the heredoc-free pass sees a body running to the end of the command. O5 (#1113 item 2) is the same miss one step later: a double quote opened on the `<<EOF` line runs on to `world"`, so bash starts the body after that line, and the body's `echo it's` keeps its `E\⏎OF` from being joined.

Why main allows them: a body the gate cannot end swallows everything after it, so the write is read as heredoc data. Main blocks the same shapes whenever a later reader trips on the swallowed text (R93, R94, R96, R101–R103 below) — an accident of quoting, not a rule.

The opposite shape — a delimiter line right after a continuation line, which bash joins away so its body runs on — needs no detector: main ends the body early and reads MORE text as commands, which can only add blocks (E1, E2 below; both block on main, read-only twin too).

---

## File Structure

| File | Change |
|------|--------|
| `hooks/gate-scripts/lib/cmdword.py` | `_HIGH_ESC_RE`, `_byte_marks`; `_byte_esc`/`_byte_shape` set on entry at every depth; the depth-0 reset clears them and `_split_term`; the depth-0 return ORs `_split_term` and `_byte_esc and _byte_shape` |
| `hooks/gate-scripts/lib/shell_lex.py` | `_split_term`; `_heredoc_terminator(…, detect=False)` sets it; `_joined_line`; `_subst_bodies` passes `detect` per heredoc; the `_bash_ansi_c` shortcut comment (~235) names the detector instead of an open gap |
| `.gate-integrity.lock` | regenerated |
| `tests/fixtures/heredoc_1093.py` | row moves, new BLOCK / ALLOW / KNOWN_BLOCK / KNOWN_ALLOW rows, a committed grid, switch checks, a timing row |
| `docs/plans/2026-11-16-heredoc-body-detectors-1093-part2b.md` | this plan, committed with the implementation |

---

### Task 1: Byte delimiter — detected

**Files:** Modify `hooks/gate-scripts/lib/cmdword.py`

- [ ] **Step 1: the detector**, next to `_heredoc_shaped` (~4908):

```python
# A `$'…'` escape for a byte >= 0x80: bash emits that BYTE, so `$'E\xc3\xa9'` is `Eé`, while
# the decoders here map each escape to its own code point (`EÃ©`). Octal is masked to eight
# bits, so `\2nn`, `\3nn`, `\6nn` and `\7nn` are bytes >= 0x80 too (`\703\651` is `é`). A
# braced `\x{HH}` (bash 5.3) is decoded by nothing here, whatever its value (`$'\x{45}OF'` is
# `EOF`). With a heredoc shape beside one, a delimiter or terminator line may be read
# differently from bash (#1093 part 2).
_HIGH_ESC_RE = re.compile(r"\\(?:x\{|x[89A-Fa-f][0-9A-Fa-f]|[2367][0-7]{2})")


# Seen in any text classified during one top-level call, at any depth: a `$'` with such an
# escape, and a heredoc shape. Either may appear only once an outer level is decoded
# (`$'\x5cxff'` is `\xff` one level down; `$'\x3c\x3c'` is `<<`), so each is looked for in
# every text and the two are combined at depth 0 (#1093 part 2b).
_byte_esc = [False]
_byte_shape = [False]


def _byte_marks(cmd):
    # (a `$'` with a high-byte escape, a heredoc shape) in cmd as bash tokenizes it.
    t = cmd.replace(chr(92) + chr(10), "")   # bash removes each `\<nl>` before it tokenizes
    return "$" + _SQ in t and _HIGH_ESC_RE.search(t) is not None, _heredoc_shaped(t)
```

- [ ] **Step 2: wire it into `is_file_mod`** (~4854–4903). Every nested text — an `_ansi_c` respelling, a substitution body, a program operand — is classified by a recursive `is_file_mod(…, _depth + 1)`, so marking on entry, before the memo lookup, sees every text the gate reads:

```python
    if _depth == 0:
        _lex_memo.clear()
        _verdict_memo.clear()
        del _stdin_used[:]
        shell_lex._body_unread[0] = shell_lex._split_term[0] = False
        _byte_esc[0] = _byte_shape[0] = False
```

and as the first lines inside the existing `try:` (so its `finally` still restores `_cmdword_on` whatever they do):

```python
        esc, shape = _byte_marks(cmd)
        _byte_esc[0], _byte_shape[0] = _byte_esc[0] or esc, _byte_shape[0] or shape
```

and the depth-0 return, with Task 2's term:

```python
        return (r or shell_lex._body_unread[0] or shell_lex._split_term[0]
                or (_byte_esc[0] and _byte_shape[0]))
```

Why a detector and not a byte-exact decoder: the decoders disagree with bash only for `\xHH` with HH ≥ 0x80, octal `\2nn`/`\3nn`/`\6nn`/`\7nn` (bash keeps an octal escape's low eight bits, so `\703` is 0xC3 — R108), and bash 5.3's braced `\x{HH}`, which nothing here decodes at any value (`$'\x{45}OF'` is `EOF` — R115, R117). `\u`/`\U` name code points, which both agree on, and main already blocks their heredoc spellings; `\0200` is `\020` then `0` (C42). Every heredoc that disagreement can move needs, somewhere in the texts the gate reads, a `$'` holding such an escape and a heredoc shape, each looked for once bash's `\<nl>` removal is applied (`<\<nl><` R109, `$\<nl>'` R110). Neither has to be in the command as typed: decoding one level builds the escape (`$'\x5cxc3'` is `\xc3` inside the program, R112, R113) or the `<<` (`$'\x3c\x3c'`, R114), and the escape and the heredoc can sit at different depths (R114: the escape in the root, the `<<` only in the decoded program). So each mark is collected from every text and the two are combined once, at depth 0. An earlier draft decoded byte-exactly instead and fed the result to the third reading's `_requote_ansi_c`; a surrogate round-trip bug there ALLOWED a command main blocks (R79). The detector reads the raw root and feeds nothing.

Over-blocks (stated): any read-only command with such an escape and a heredoc shape anywhere in it — K16–K19. `_heredoc_shaped` is a shape test (`<<` anywhere, or a newline and two `<`), so a herestring, a shift (K23, K24) or two redirections on separate lines (K26) beside a byte escape trip it too; and deleting every `\<nl>`, even one inside single quotes where bash keeps it, can glue a `\` and an `xff` into an escape (K25). C29's `echo $'\xff'` (no heredoc shape) still allows.

---

### Task 2: Split terminator — detected

**Files:** Modify `hooks/gate-scripts/lib/shell_lex.py` `_heredoc_terminator` (~281) and `_subst_bodies` (~635–690)

- [ ] **Step 1: the flag**

```python
# Set while cmdword runs when a body line, joined at its `\<nl>`s as bash joins an expanding
# body, is the delimiter while the line as read here is not: bash ends the body there and
# every reader here does not. cmdword.is_file_mod blocks on it; nothing reads a joined end
# (#1093 part 2).
_split_term = [False]


def _heredoc_terminator(s, k, d, strip, detect=False):
    # (start of the terminator line, index past it) for the body starting at s[k]; both
    # len(s) when the body never ends. detect: s is _subst_bodies' joined text, so a split
    # terminator still standing is one _join_continuations could not join (#1093 part 2).
    cont = False                  # the previous line ended in an odd backslash run
    while k < len(s):
        e = s.find('\n', k)
        nxt = len(s) if e == -1 else e + 1
        line = s[k:len(s) if e == -1 else e]
        if (line.lstrip('\t') if strip else line) == d:
            return k, nxt
        odd = e != -1 and (len(line) - len(line.rstrip(chr(92)))) % 2 == 1
        if detect and odd and not cont and _cmdword_on[0] and not _split_term[0]:
            j, last = _joined_line(s, k)      # once per logical line, so the scan stays linear
            # bash ends the body at the joined line; the readers here end it at its last
            # physical line only if that line is the delimiter itself -- then the ends agree.
            _split_term[0] = ((j.lstrip('\t') if strip else j) == d
                              and (last.lstrip('\t') if strip else last) != d)
        cont = odd
        k = nxt
    return len(s), len(s)


def _joined_line(s, k):
    # (the logical line starting at s[k], its last physical line): physical lines joined at
    # each odd backslash run's last backslash, as bash reads an expanding heredoc body (an
    # even run is escaped backslashes and joins nothing).
    parts = []
    while True:
        e = s.find('\n', k)
        line = s[k:len(s) if e == -1 else e]
        if e == -1 or (len(line) - len(line.rstrip(chr(92)))) % 2 == 0:
            parts.append(line)
            return "".join(parts), line
        parts.append(line[:-1])
        k = e + 1
```

The return value is main's in every case; only the flag is new, and the joined text is used for nothing else. The flag needs the two ends to differ: when the logical line's last physical line is itself the delimiter (`\⏎EOF`), the readers here stop on it too, so nothing is flagged (C44). A delimiter word holding a quote or backslash is quoted, so its body is never joined and never checked (`joined` below).

- [ ] **Step 2: detect in `_subst_bodies` only, per heredoc**

```python
    heredocs, expands, joined = [], [], []
    ...
            for (d, strip), exp, joins in zip(heredocs, expands, joined):
                body_end, nxt = _heredoc_terminator(s, k, d, strip, detect=joins)
    ...
            heredocs, expands, joined = [], [], []
    ...
                expands.append(not any(c in s[i + 2:hd[1]] for c in "'" + chr(34) + chr(92)))
                # Bash joins this body's lines when its word, with each unescaped `\<nl>` removed
                # (bash removes them before reading the word), holds no quote or backslash. The
                # test above sees `<<E\<nl>OF` as quoted when _join_continuations could not join
                # it (an apostrophe earlier); `<<'E'\<nl>OF` stays quoted (#1093 part 2).
                w = re.sub(r"(?<!\\)((?:\\\\)*)\\\n", r"\1", s[i + 2:hd[1]])
                joined.append(not any(c in w for c in "'" + chr(34) + chr(92)))
```

Why `_subst_bodies` only: it runs `_join_continuations` first, so a split terminator still standing there is exactly one main's reading misses (an apostrophe kept the join from happening). The other callers (`_subst_body_end` via `_heredoc_body_end`, `_join_continuations`, the third-reading defuser) scan unjoined text and would flag bodies main reads correctly. Every text cmdword classifies passes through `_subst_bodies` (`_lex_bodies`), at every depth, so a `$( )` or program body is checked when it is classified. Why only for a body bash joins: a quoted-delimiter body is never joined by bash, so its `E\⏎OF` is data (flagging it over-blocked eight grid cells in a draft; C41 pins the quoted word holding a continuation).

---

### Task 3: Fixture rows, lock, verification

**Files:** Modify `tests/fixtures/heredoc_1093.py`, `.gate-integrity.lock`

- [ ] **Step 1: move rows.** KNOWN_ALLOW → BLOCK (labels kept): O5, O12, O13. KNOWN_BLOCK keeps K8 (main's verdict: the byte delimiter in a `"$( )"` still blocks).

- [ ] **Step 2: new BLOCK rows** — every one writes under bash 5 (the fixture checks) and blocks; "(main blocks)" marks a row main blocks too, pinning additivity:

```python
    ("R74 O13 with an even backslash run before the split", "cat <<EOF\nit's\na\\\\\nE\\\nOF\necho x > src/f\necho 'y'"),
    ("R79 nested raw-byte delimiter (main blocks)",
     "bash -c $'cat <<$\\'E\\xff\\'\\nit\\'s\\nE\\xff\\necho x\\x3esrc/f\\necho $\\'\\\\x27\\''"),
    ("R80 nested UTF-8 byte delimiter (main blocks)",
     "bash -c $'cat <<$\\'E\\xc3\\xa9\\'\\nit\\'s\\nE\\xc3\\xa9\\necho x\\x3esrc/f\\necho $\\'\\\\x27\\''"),
    ("R81 a split terminator in the first of two $( ) (main blocks)",
     ": $(cat <<EOF\nit's\nE\\\nOF\necho x > src/f\necho 'y'\n) $(cat <<'EOF'\nEOF\n)"),
    ("R85 a UTF-8 delimiter split across two $'...'", "cat <<$'E\\xc3'$'\\xa9'\nit's\nE\u00e9\necho x > src/f\necho 'y'"),
    ("R86 O13 as a bash -c program (main blocks)", "bash -c " + q("cat <<EOF\nit's\nE\\\nOF\necho x > src/f\necho 'y'")),
    ("R87 a split delimiter word and a split terminator after an apostrophe body",
     "cat <<A\nit's\nA\ncat <<E\\\nOF\nhello\nE\\\nOF\necho x > src/f\necho 'y'"),
    ("R88 a UTF-8 terminator line split across two $'...' in bash -c",
     "bash -c $'cat <<E\u00e9\\nit\\'s\\nE\\xc3'$'\\xa9\\necho x\\x3esrc/f\\necho \\'y\\''"),
    ("R93 split terminator in $( ), then a write (main blocks)", ": $(cat <<EOF\nit's\nE\\\nOF\n)\necho x > src/f\necho 'y'"),
    ("R94 byte delimiter in \"$( )\", then a write (main blocks)",
     ": \"$(cat <<$'E\\xc3\\xa9'\nit's\nE\u00e9\n)\"\necho x > src/f\necho 'y'"),
    ("R96 split terminator in <( ), then a write (main blocks)", "cat <(cat <<EOF\nit's\nE\\\nOF\n)\necho x > src/f\necho 'y'"),
    ("R97 split terminator in a backtick, then a write", ": " + BT + "cat <<EOF\nit's\nE\\\nOF\n" + BT + "\necho x > src/f\necho 'y'"),
    ("R101 split terminator in ${v:-\"'\"$( )} (main blocks)",
     ": \"${v:-\"'\"$(cat <<EOF\nhello\nE\\\nOF\n)}\"\necho x > src/f\necho \\'"),
    ("R102 byte delimiter in ${HOME#'\"'$( )} (main blocks)",
     ": \"${HOME#'\"'$(cat <<$'E\\xc3\\xa9'\nit's\nE\u00e9\n)}\"\necho x > src/f\necho 'y'"),
    ("R103 a comment apostrophe, then a split terminator in $( ) (main blocks)",
     "echo hi # it's\n: $(cat <<EOF\nhi\nE\\\nOF\n)\necho x > src/f\necho 'y'"),
    ("R107 a split terminator after a comment apostrophe",
     "echo hi # it's\ncat <<E\\\nOF\nhello\nE\\\nOF\necho x > src/f\necho 'y'"),
    ("R108 O12 spelled in octal", "cat <<$'E\\703\\651'\nit's\nE\u00e9\necho x > src/f\necho 'y'"),
    ("R109 O12 behind a continuation-split <<", "cat <\\\n<$'E\\xc3\\xa9'\nit's\nE\u00e9\necho x > src/f\necho 'y'"),
    ("R110 O12 behind a continuation-split $'", "cat <<$\\\n'E\\xc3\\xa9'\nit's\nE\u00e9\necho x > src/f\necho 'y'"),
    ("E1 a delimiter line joined away by a continuation (main blocks)",
     "cat <<EOF\nit's\nx\\\nEOF\nit's\nEOF\necho x > src/f\necho 'y'"),
    ("E2 E1 as a bash -c program (main blocks)",
     "bash -c " + q("cat <<EOF\nit's\nx\\\nEOF\nit's\nEOF\necho x > src/f\necho 'y'")),
    ("R112 a byte escape built one level down by \\x5c",
     "bash -c $'cat <<$\\'E\\x5cxc3\\x5cxa9\\'\\nit\\'s\\nE\u00e9\\necho x\\x3esrc/f\\necho \\'y\\''"),
    ("R113 a byte escape built one level down by \\134",
     "bash -c $'cat <<$\\'E\\134xc3\\134xa9\\'\\nit\\'s\\nE\u00e9\\necho x\\x3esrc/f\\necho \\'y\\''"),
    ("R115 O12 with braced escapes", "cat <<$'E\\x{c3}\\x{a9}'\nit's\nE\u00e9\necho x > src/f\necho 'y'"),
    ("R116 R115 as a bash -c program (main blocks)",
     "bash -c " + q("cat <<$'E\\x{c3}\\x{a9}'\nit's\nE\u00e9\necho x > src/f\necho 'y'")),
    ("R117 a low braced escape spelling the delimiter", "cat <<$'\\x{45}OF'\nit's\nEOF\necho x > src/f\necho 'y'"),
    ("R114 R88 with its << spelled \\x3c\\x3c",
     "bash -c $'cat \\x3c\\x3cE\u00e9\\nit\\'s\\nE\\xc3'$'\\xa9\\necho x\\x3esrc/f\\necho \\'y\\''"),
```

R81, R93, R94, R96 and R101–R103 are the regression class the earlier reader-changing draft hit; they pin that this plan keeps main's verdict on them.

- [ ] **Step 3: new ALLOW controls** (none writes; all allow on main too):

```python
    ("C29 echo $'\\xff' (no heredoc)", "echo $'\\xff'"),
    ("C41 a quoted delimiter word holding a continuation, after an apostrophe body",
     "cat <<A\nit's\nA\ncat <<'E'\\\nOF\nhello\nE\\\nOF\nEOF\necho ok"),
    ("C42 an escaped \\0 then digits is not a high byte", "cat <<$'E\\0200'\nhi\nE\necho ok"),
    ("C44 a backslash-only line, then the delimiter itself", "cat <<EOF\nit's\n\\\nEOF\necho ok"),
```

- [ ] **Step 3a: KNOWN_BLOCK rows** — new over-blocks, none writes, main allows each:

```python
    ("K16 a byte escape beside an unclosed heredoc", "cat <<$'E\\xff'\nhi\nE\necho ok"),
    ("K17 read-only twin of O12", "cat <<$'E\\xc3\\xa9'\nit's\nE\u00e9\necho 'y'"),
    ("K18 read-only twin of R79", "bash -c $'cat <<$\\'E\\xff\\'\\nit\\'s\\nE\\xff\\necho ok\\necho $\\'\\\\x27\\''"),
    ("K19 read-only twin of R88", "bash -c $'cat <<E\u00e9\\nit\\'s\\nE\\xc3'$'\\xa9\\necho ok\\necho \\'y\\''"),
    ("K23 a herestring beside a byte escape", "cat <<< hi; echo $'\\xff'"),
    ("K24 an arithmetic shift beside a byte escape", "echo $((1<<8)); echo $'\\xff'"),
    ("K25 a single-quoted \\<nl> glued into a byte escape", "echo $'ok'\necho '\\\\\nxff'\ncat <<EOF\nhi\nEOF\necho ok"),
    ("K26 two < on separate lines beside a byte escape", "cat < /dev/null\necho '<' $'\\xff'"),
    ("K27 read-only twin of O13 (Task 2's split terminator)", "cat <<EOF\nit's\nE\\\nOF\necho 'y'"),
```

- [ ] **Step 3b: KNOWN_ALLOW rows** — they write; main allows each; this plan does not close them (a quote gap in the reader, not a body end: the apostrophe body ends where bash ends it, and the reader that follows misquotes it):

```python
    ("O18 an apostrophe body in $( ), then a write", ": $(cat <<EOF\nit's\nEOF\n)\necho x > src/f\necho 'y'"),
    ("O19 an apostrophe body in a backtick, then a write", ": " + BT + "cat <<EOF\nit's\nEOF\n" + BT + "\necho x > src/f\necho 'y'"),
    ("O20 an apostrophe body in <( ), then a write", "cat <(cat <<EOF\nit's\nEOF\n)\necho x > src/f\necho 'y'"),
    ("O24 a braced escape spelling a redirect, no heredoc", "bash -c $'echo x \\x{3e} src/f'"),
```

O24 is not a body end at all: `_bash_ansi_c` does not decode `\x{3e}`, so the program's `>` is never seen. It is listed here because it shares Task 1's root cause; the follow-up issue owns it (teach `_bash_ansi_c` the braced form).

- [ ] **Step 3c: the grid, committed** — body end × container, each followed by a write and a later quote; every writing cell must block except the 16 `GRID_OPEN` cells main allows too, which are pinned allow. In the fixture, after `nest()`:

```python
GRID_BODIES = ("cat <<EOF\nit's\nEOF", "cat <<EOF\nit's\nE\\\nOF", "cat <<$'E\\xc3\\xa9'\nit's\nE\u00e9",
               "cat <<E\\\nOF\nit's\nE\\\nOF", "cat <<'EOF'\nit's\nE\\\nOF\nEOF")
GRID_WRAPS = (lambda b: b, lambda b: ": $(" + b + "\n)", lambda b: ': "$(' + b + '\n)"',
              lambda b: ": " + BT + b + "\n" + BT, lambda b: ': "' + BT + b + "\n" + BT + '"',
              lambda b: "cat <(" + b + "\n)", lambda b: ": >(" + b + "\n)",
              lambda b: ": ${v:-$(" + b + "\n)}", lambda b: ": $(: $(" + b + "\n))",
              lambda b: "cat <<OUT\n$(" + b + "\n)\nOUT")
GRID_OPEN = {(0, 1), (0, 2), (0, 3), (0, 4), (0, 5), (0, 7), (0, 8), (1, 2), (3, 2),
             (4, 1), (4, 2), (4, 3), (4, 4), (4, 5), (4, 7), (4, 8)}   # main allows too: O18-O20's class


def grid():
    # (label, command, expected) -- every heredoc body end in every container, then a write.
    tail = "\necho x > src/f\necho 'y'"
    for n, b in enumerate(GRID_BODIES):
        yield "grid b%d program" % n, "bash -c " + q(b + tail), "block"
        for m, w in enumerate(GRID_WRAPS):
            yield "grid b%d w%d" % (n, m), w(b) + tail, "allow" if (n, m) in GRID_OPEN else "block"
```

and in `rows()`, after the BLOCK loop:

```python
    for label, cmd, want in grid():
        if not fx.writes(cmd):
            fx.no(label, "bash 5 did not write -- the cell proves nothing")
            continue
        got, _dt = fx.hook(repo, cmd)
        fx.ok(label) if got == want else fx.no(label, "hook said %s, pinned %s" % (got, want))
```

`GRID_OPEN` pins the 16 cells main allows and this plan leaves open, so closing one fails loudly and gets moved, as a KNOWN_ALLOW row does. It is filled from the Step 6 grid run: the plain and the quoted-delimiter bodies in every container but none, `>( )` and the outer body (O18–O20's class); the split and split-word bodies in `"$( )"`, where the apostrophe opens no quote, so `_join_continuations` joins the terminator and the cell reduces to the plain body. The read-only tail is checked in Step 6 against main, not committed: some of its cells block on main and here alike, so it has no single expected verdict.

- [ ] **Step 3d: `switch_rows()` checks** — marker_check must read as on main. Append to `checks`:

```python
        # #1093 part 2: the split-terminator flag is cmdword-only and changes no end.
        ("split terminator: same end (on)",
         (shell_lex._split_term.__setitem__(0, False),
          on(shell_lex._heredoc_terminator, "it's\nE\\\nOF\nx", 0, "EOF", False, True))[1] == (len("it's\nE\\\nOF\nx"),) * 2),
        ("split terminator flagged (on)", shell_lex._split_term[0] is True),
        ("split terminator not flagged (off)", (shell_lex._split_term.__setitem__(0, False),
         shell_lex._heredoc_terminator("it's\nE\\\nOF\nx", 0, "EOF", False, True), shell_lex._split_term[0])[2] is False),
        ("byte heredoc marked", cmdword._byte_marks("cat <<$'E\\xc3\\xa9'\nhi\nE\u00e9") == (True, True)),
        ("no heredoc, no shape mark", cmdword._byte_marks("echo $'\\xff'") == (True, False)),
        ("octal escape marked", cmdword._byte_marks("cat <<$'E\\703\\651'\nhi\nE\u00e9") == (True, True)),
        ("continuation-split $' marked", cmdword._byte_marks("cat <<$\\\n'E\\xc3\\xa9'\nhi\nE\u00e9") == (True, True)),
        ("\\0200 is not a high byte", cmdword._byte_marks("cat <<$'E\\0200'\nhi\nE")[0] is False),
        ("braced escape marked", cmdword._byte_marks("cat <<$'\\x{45}OF'\nhi\nEOF") == (True, True)),
        ("a split line ending in the delimiter itself is not flagged",
         (shell_lex._split_term.__setitem__(0, False),
          on(shell_lex._heredoc_terminator, "it's\n\\\nEOF\nx", 0, "EOF", False, True), shell_lex._split_term[0])[2] is False),
```

- [ ] **Step 4: timing row** in `rows()`, after the existing ones:

```python
    # A body of nothing but continuation lines near the cap: the joined-line check is linear.
    cmd = "cat <" + "<EOF\nit's\n" + "\\\n" * ((fx.CAP - 60) // 2) + "EOF\necho x > src/f"
    got, dt = fx.hook(repo, cmd, timeout=10)
    label = "timing: %d chars of continuation lines in one body blocked in %.2fs" % (len(cmd), dt)
    fx.ok(label) if got == "block" and dt <= fx.LIMIT else fx.no(label, "over %.1f s or %s" % (fx.LIMIT, got))
```

- [ ] **Step 5: regenerate the lock, run focused suites**

```bash
./scripts/gate-integrity.sh --update
bash tests/test-heredoc-body-1093.sh            # all rows pass
bash tests/test-cmdword-case-backtick-1063.sh
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
  - The grid through both trees' real hooks, BOTH tails (`\necho x > src/f\necho 'y'` and `\necho 'y'`), plus the `bash -c` program container: no writing cell allowed on the branch that main blocks; no read-only cell blocked on the branch that main allows except the stated class (a split-terminator or byte-delimiter body read-only: 12 such cells).
  - #1085 fuzz with origin/main's lib as baseline (`tests/fixtures/cmdword_1085.py fuzz <armed> --full --baseline <main lib>/cmdword.py`): 0 writing commands allowed, 0 block→allow.
  - Transcript corpus, classification only: every transcript Bash command holding `-c`, `eval`, `-exec`, `$'`, `<<`, `--command` through both trees' `cmdword.is_file_mod`, and every heredoc-shaped or program-carrying command through both trees' real `pre-implementation-gate.sh` in an armed repo. Expected: 0 allow on the branch that main blocks; an allow→block only inside the two stated over-block classes (a heredoc shape — `<<` anywhere — beside a high-byte `$'` escape; a split terminator in a joined body), each named in the PR body with its class.

- [ ] **Step 7: commit**

```bash
git add hooks/gate-scripts/lib/cmdword.py hooks/gate-scripts/lib/shell_lex.py .gate-integrity.lock tests/fixtures/heredoc_1093.py docs/plans/2026-11-16-heredoc-body-detectors-1093-part2b.md
git commit -m "fix(gate): detect byte delimiters and split heredoc terminators (#1093, part 2b)"
```

PR body: `Refs #1093` (the issue closes with the companion plan), `Refs #1113` (item 2 only).

---

## Spike evidence (scratch copy, not committed)

A scratch tree holding exactly this plan's code changes (main's tree plus Tasks 1–2) — `/private/tmp/claude-501/-Volumes-Work-Projects-busdriver/5e8a689e-30af-4e75-80d3-86139dd033ee/scratchpad/spike8` (review rounds 1–2's fixes on top of `spike5`; round 2 probed `spike6`, which lacks only the braced escape and the move into the `try:`); `base` beside it is main — measured against main, both through their own real hook with the bash-5 write check first:
- Every row in Steps 2–3b, as spelled: each BLOCK row writes and blocks; each ALLOW row does not write and allows on both; each KNOWN_BLOCK row does not write, main allows, the branch blocks; each KNOWN_ALLOW row writes and both allow. No row main blocks is allowed.
- Grid, 110 cells: 0 writing cells main blocks are allowed; 8 writing cells main allows now block; 16 stay open on both (`GRID_OPEN`); 12 read-only cells main allows now block, all split-terminator or byte-delimiter bodies (the stated class); none the other way.
- Step 3d's ten switch checks pass; the continuation-line timing row (32,741 chars) blocks in ≈0.3 s.
- `test-heredoc-body-1093.sh` on the branch with main's fixture: exactly the Step 1 flips (O5, O12, O13 now block), nothing else.
- Gate suites: every `tests/test-*.sh` matching cmdword/pre-implementation-gate/shell_lex, plus string-executors, equal to main except the heredoc fixture's Step 1 flips (any suite that fails on main for environment reasons fails the same way on the branch).
- Corpora (classification only): real gate in an armed repo, 0 changes / 8,646 commands. `is_file_mod`, 2 allow→block of 9,051: both are spike-editing Python heredocs from the session that wrote this plan, which do write a file and quote `$'\xc3…'` text (Task 1's stated class); the real gate already blocks both.
- #1085 full fuzz against main's lib: 38,049 writing commands, none allowed, no block→allow.
- The rows were also run against main's tree alone: 23 of the 44 fail there, so the check can fail.

## Residuals (stated, not fixed here)

- O18–O20 (KNOWN_ALLOW; main allows each): an apostrophe body in a substitution followed by a write — the body ends where bash ends it, and the reader after it misquotes the apostrophe (the top-level quote gap, O1's family). Follow-up issue.
- A body more than `_MAX_DEPTH` (4) levels down is not checked for a split terminator: `_is_file_mod` returns at the cap before `_lex_bodies`, with its depth-cap verdict (verb patterns plus the redirect check main runs there). Not probed past that.
- O24: `_bash_ansi_c` does not decode bash 5.3's braced `\x{HH}`, so a program spelled with one is read wrong outside any heredoc too. Follow-up issue.
- Member 1b (O2, O7–O11: unreadable programs) is the companion plan's.

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
