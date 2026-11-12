"""Shell lexer shared by the gate classifiers (#1085).

Moved verbatim from marker_check.py, which imports every name back under the same name, so
its behaviour is unchanged. cmdword.py will import it for the substitution bodies its own
paren-counting extractor misses. One copy, because two classifiers that disagree about where a
substitution ends are a bypass in whichever one is wrong. No I/O, no side effects at import.
"""
import re

_SQ = chr(39)


def _join_continuations(s):
    """Remove `\\<newline>` outside single quotes -- the shell joins the token first.

    Without it a keyword split across the join (`ca\\<newline>se`) reads as an ordinary
    word, so its pattern `)` is mistaken for the `$()` closer.
    """
    if chr(92) + '\n' not in s:
        return s
    out = []
    i, n, q = 0, len(s), ''
    pend = []                    # bodies whose delimiter was QUOTED: literal data
    _ln = None                   # the current line, joined once (see the `<<` branch)
    while i < n:
        c = s[i]
        if c == '\n':
            _ln = None
        if q == "'":
            if c == "'":
                q = ''
            out.append(c)
            i += 1
            continue
        # A QUOTED delimiter makes its body literal, so the `\<newline>` in there is two
        # characters the shell keeps. Joining them forged the terminator out of
        # `E\<newline>OF` and handed the rest of the body to the parser (#802). A double
        # quote is not a barrier to either half of this: `"$(cat <<'E'` is a command.
        if pend and c == '\n':
            _e = _heredoc_body_end(s, i + 1, pend)
            out.append(s[i:_e])
            i = _e
            pend = []
            continue
        if s.startswith('<<<', i):
            # Consume all THREE, as the walker in `_strip_cmd_subst` does. Stepping over
            # the first `<` alone left `<<'X'` starting one character later, read as a
            # QUOTED delimiter whose terminator line never comes -- so the body swallowed
            # the rest of the command and none of its continuations were joined (#802).
            out.append('<<<')
            i += 3
            continue
        if s.startswith('<<', i) and not s.startswith('<<<', i):
            # Read the delimiter from the JOINED line, because the shell joins first:
            # `<<E\<newline>OF` delimits on EOF. Reading it raw took `E` and the body
            # then ran to the end of the command (#802).
            # Scan that line ONCE and reuse it for every `<<` on it. Rebuilding it per
            # operator is quadratic: 16K of them in a 64K command spent 21s in here,
            # four times the whole hook budget -- and a hook killed on the budget emits
            # nothing, which reads as ALLOW. That is #802's own bug, so the fix for it
            # does not get to reintroduce it.
            if _ln is None:
                _buf, _raw, _at = [], [], {}
                _k = i
                while _k < n:
                    if s[_k] == chr(92) and s[_k + 1:_k + 2] == '\n':
                        _k += 2
                        continue
                    if s[_k] == '\n':
                        break
                    _at[_k] = len(_raw)
                    _buf.append(s[_k])
                    _raw.append(_k)
                    _k += 1
                _ln = ("".join(_buf), _raw, _at, _k)
            _line, _raw, _at, _k = _ln
            _p = _at[i]
            _hd = _heredoc_delim(_line, _p)
            if _hd:
                _w0 = _p + 2 + (1 if _line[_p + 2:_p + 3] == '-' else 0)
                while _w0 < len(_line) and _line[_w0] in ' \t':
                    _w0 += 1
                if _line[_w0:_hd[1]] != _hd[0][0]:   # quoting was removed to get it
                    pend.append(_hd[0])
                    out.append(_line[_p:_hd[1]])
                    i = _raw[_hd[1]] if _hd[1] < len(_raw) else _k
                    continue
        if c == chr(92) and i + 1 < n:
            if s[i + 1] == '\n':
                i += 2
                continue
            out.append(c)
            out.append(s[i + 1])
            i += 2
            continue
        if not q and c in ("'", chr(34)):
            q = c
        elif q == chr(34) and c == chr(34):
            q = ''
        out.append(c)
        i += 1
    return "".join(out)


def _ansi_c_span(s, i):
    """Index past the `$'...'` at `s[i]`, or None.

    A backslash escapes the NEXT character inside one, so the `'` in `$'a\\'b'` is DATA.
    Read as an ordinary single quote it closed early and shifted every quote after it,
    turning an ordinary command into a refusal (#802).
    """
    if not s.startswith("$" + _SQ, i):
        return None
    j = i + 2
    while j < len(s):
        if s[j] == chr(92):
            j += 2
            continue
        if s[j] == _SQ:
            return j + 1
        j += 1
    return None


def _backtick_span(s, i):
    """Index past the `` `...` `` at `s[i]`, or None. Its body ends at its OWN
    delimiter, so a `)` or `}` inside closes nothing outer (#802)."""
    j = i + 1
    while j < len(s):
        if s[j] == chr(92):
            j += 2
            continue
        if s[j] == chr(96):
            return j + 1
        j += 1
    return None


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
_cmdword_on = [False]   # True while cmdword.is_file_mod runs: bash-exact reads marker_check skips


def _past_cont(s, j):
    """j moved past any line continuations, while cmdword classifies (_cmdword_on). Bash joins
    them before it reads a heredoc operator and its word: `<<\\<nl> EOF` and `<<E\\<nl>OF` both
    delimit on EOF. Read raw, the delimiter never closed and its body swallowed the rest of a
    `bash -c` program (#1085 rounds 7 and 8)."""
    while _cmdword_on[0] and s.startswith(chr(92) + chr(10), j):
        j += 2
    return j


def _heredoc_delim(s, i):
    """The heredoc delimiter at `s[i]` and the index past its introducer, or None.

    Quotes and escapes in the word are syntax the shell removes before comparing
    terminator lines, so `<<'EOF'`, `<<"EOF"` and `<<\\EOF` all delimit on `EOF`. Not
    "drop every quote", though: a backslash makes the NEXT character literal, so
    `<<E\\"OF` delimits on `E"OF` and a bare `EOF` line does not end it. Bash accepts
    the operator attached to the word before it (`cat<<E`, `3<<E`), so no preceding
    character is required. Two `<<`s are not heredocs and the caller consumes both:
    `<<<` is a herestring, and inside `$(( ))` a `<<` is an arithmetic shift.
    """
    if not s.startswith('<<', i) or s.startswith('<<<', i):
        return None
    j = _past_cont(s, i + 2)
    strip = j < len(s) and s[j] == '-'
    if strip:
        j = _past_cont(s, j + 1)
    while j < len(s) and s[j] in ' \t':
        j = _past_cont(s, j + 1)
    d = []
    dq = ''
    # `<<''` delimits on the EMPTY line: the quotes are removed to get the terminator,
    # and removing them can leave NOTHING -- which is a delimiter, not the absence of
    # one, and reading it as absence scanned the body as live shell text (#802).
    w0 = j
    while j < len(s):
        c = s[j]
        if dq:
            if c == dq:
                dq = ''
            elif dq == chr(34) and _cmdword_on[0] and s.startswith(chr(92) + chr(10), j):
                j += 1                     # `"E\<nl>OF"` is EOF too; inside '…' bash keeps it
            elif dq == chr(34) and c == chr(92) and j + 1 < len(s) \
                    and s[j + 1] in (chr(34), chr(92), '$', chr(96)):
                j += 1
                d.append(s[j])
            else:
                d.append(c)
            j += 1
            continue
        if c == '$' and s[j + 1:j + 2] == chr(34):
            # `$"..."` is a locale TRANSLATION, so the `$` is a quoting prefix and the
            # delimiter is the quoted text -- exactly as `$'...'` is handled just below.
            # Keeping the `$` looked for `$EOF`, never closed the body, and the scan ate
            # the enclosing substitution's `)` (#802).
            j += 1
            continue
        if c == '$' and s[j + 1:j + 2] == chr(39):
            _e = _ansi_c_span(s, j)
            if _e is None:
                return None
            # Bash's whole escape set while cmdword classifies (_cmdword_on). Off for marker_check,
            # whose verdicts this must not change: its give-up on such a body is a block it keeps.
            # shortcut: `\xc3\xa9` decodes to two code points, not the one character bash's bytes
            # spell, as _decode_escapes on main does; that delimiter is a stated gap, open in #1093.
            d.append(_bash_ansi_c(s[j + 2:_e - 1]) if _cmdword_on[0] else _decode_escapes(s[j + 2:_e - 1]))
            j = _e
            continue
        if c in ("'", chr(34)):
            dq = c
            j += 1
            continue
        if _cmdword_on[0] and s.startswith(chr(92) + chr(10), j):
            j += 2                         # `<<E\<nl>OF` delimits on EOF (one pair per step: linear)
            continue
        if c == chr(92) and j + 1 < len(s):
            j += 1
            d.append(s[j])
            j += 1
            continue
        if c in ' \t\n;&|<>()':
            break
        d.append(c)
        j += 1
    return (("".join(d), strip), j) if (d or j > w0) else None


def _heredoc_body_end(s, nl, delims):
    """Index just past the bodies for `delims`, the first of which starts at `nl`.

    A body does not start at the introducer -- the rest of THAT line is still command
    text, and several bodies queue on one line -- so the skip happens at the newline,
    in introducer order. Only `<<-` strips leading tabs from the terminator: under a
    plain `<<` a tab-indented delimiter is body DATA, and ending the body there hands
    a later body `)` back as shell text.
    """
    k = nl
    for d, strip in delims:
        while k < len(s):
            e = s.find('\n', k)
            line = s[k:len(s) if e == -1 else e]
            k = len(s) if e == -1 else e + 1
            if (line.lstrip('\t') if strip else line) == d:
                break
    return k


# A reserved word at command position. Only `case`/`esac` change the paren reading; the
# rest keep the position a command one (`then case …`, `! case …`).
_RESERVED_AT_CMD_RE = re.compile(
    r"(case|esac|then|do|else|elif|if|while|until|time|!|\{)(?=[\s;&|()<>]|$)")


_RESERVED_END_RE = re.compile(r"(?=[\s;&|()<>]|$)")


_PARAM_PATTERN_OP_RE = re.compile(
    r"!?(?:[A-Za-z_][A-Za-z0-9_]*|[0-9]+|[@*#?$!-])(?:\[[^]]*\])?[#%/^,]")


# Nesting the span readers below follow before answering "unreadable": past it the caller
# hands the command to the abandoned-scan probe instead of raising RecursionError, which
# refused a 1000-deep nesting bash runs (and main allowed).
_SPAN_MAX_DEPTH = 200


def _param_span(s, i, dq=False, _depth=0):
    """Index past the `${...}` at `s[i]`, or None. Its parens are DATA -- `${X:-(}`
    prints `(` -- so a body scan counting them lost the body's `)`; quotes, escapes and
    substitutions inside are still syntax, so a quoted `}` closes nothing. Inside double
    quotes a `'` is literal."""
    if _depth > _SPAN_MAX_DEPTH:
        return None
    j, in_d = i + 2, False
    # ...except in a PATTERN (`#` `%` `/` `^` `,` operators), where bash quotes with `'`
    # inside double quotes too: `"${X//'"'/}"` strips a `"`.
    pat_op = _PARAM_PATTERN_OP_RE.match(s, i + 2) is not None
    while j < len(s):
        c = s[j]
        if c == chr(92):
            j += 2
            continue
        q = in_d or (dq and not pat_op)   # a local `"` quotes `'` even in a pattern
        if c == "$" and s.startswith("{", j + 1):
            e = _param_span(s, j, dq or in_d, _depth + 1)
        elif s.startswith("$((", j) and _arith_closes(s, j):
            e = _paren_matches[1][j + 1] + 1
        elif c == "$" and s.startswith("(", j + 1):
            e = _subst_body_end(s, j + 1, _depth + 1)
            e = None if e < 0 else e + 1
        elif c in "<>" and _cmdword_on[0] and not (in_d or dq) and s.startswith("(", j + 1):
            # `${v:-<(# })}`: a process substitution runs inside `${…}` and its `}` is its own
            # (#1085). Inside double quotes `<(` is plain text, as in _subst_bodies. cmdword
            # only: for marker_check this arm turned a give-up block into OK (Deviation 7).
            e = _subst_body_end(s, j + 1, _depth + 1)
            e = None if e < 0 else e + 1
        elif c == chr(96):
            e = _backtick_span(s, j)
        elif c == "$" and s.startswith("'", j + 1) and not q:
            e = _ansi_c_span(s, j)
        elif c == "'" and not q:
            e = s.find("'", j + 1)
            e = None if e < 0 else e + 1
        else:
            if c == chr(34):
                in_d = not in_d
            elif c == "}" and not in_d:
                return j + 1
            j += 1
            continue
        if e is None:
            return None
        j = e
    return None


def _subst_body_end(s, start, _depth=0):
    # Index of the `)` closing the `$(` whose `(` is at s[start], or -1. KEEP IN STEP WITH
    # cmdword._subst_end for the quote rules -- plus three it lacks, because this body is
    # scanned as a COMMAND and a `)` the shell does not read as the closer ended it early,
    # hiding everything after it: `"$(# )<nl>sh -c '…')"` ran its sh while the body read
    # as `# `. A word-start `#` comments to the newline; a heredoc body is data; and inside
    # `case … esac` a `)` at the case's own paren level ends a pattern list -- `case` only
    # at COMMAND position, where it is a reserved word (`echo case` is an argument). -1 when
    # no closer is found, which the caller treats as unreadable, never as empty.
    if _depth > _SPAN_MAX_DEPTH:
        return -1
    i, n, depth = start, len(s), 0
    in_s = in_d = False
    ws = False
    cmd = False                  # at a command word; s[start] is the `(`, which sets it
    cond = False                 # inside `[[ … ]]`, where no word is a command: `|| case ==`
    # One [paren depth, state] per open `case`. Only a pattern list's FIRST word can be
    # `esac`: the subject is a word (`case esac in`), and so is a pattern after `|` or a
    # leading `(` (`x|esac)`) -- reading either as the end truncated the body.
    # state: subj -> in -> start (a pattern list may begin) -> word -> cmd (its commands)
    heredocs, cases, arith = [], [], 0
    while i < n:
        ch = s[i]
        if in_s:
            in_s = ch != "'"
            i += 1
            continue
        if in_d:
            if ch == chr(92):
                i += 1
            elif ch == chr(34):
                in_d = False
            elif ch == "$" and s.startswith("{", i + 1):
                j = _param_span(s, i, True, _depth + 1)   # `"${X:-"}"}"`: its inner `"` is no close
                if j is None:
                    return -1
                i = j - 1
            elif ch == chr(96):
                j = _backtick_span(s, i)      # `"`printf '"'`"`: its quotes are its own
                if j is None:
                    return -1
                i = j - 1
            elif ch == "$" and s.startswith("(", i + 1) and not (
                    s.startswith("$((", i) and _arith_closes(s, i)):
                # A nested `$(` opens fresh quoting: `"$(echo '"')"` has no closing `"` at
                # its `'"'`, and running on to it lost this body's end.
                j = _subst_body_end(s, i + 1, _depth + 1)
                if j < 0:
                    return -1
                i = j
            i += 1
            continue
        if heredocs and ch == chr(10):
            i = _heredoc_body_end(s, i + 1, heredocs)
            heredocs, ws, cmd = [], True, True
            continue
        if ws and ch == "#" and not arith:
            nl = s.find(chr(10), i)
            if nl < 0:
                return -1
            i = nl
            continue
        if ch == chr(92):
            i += 2
            if s[i - 1:i] != chr(10):     # a line continuation keeps the boundary
                ws = cmd = False
            continue
        if s.startswith("((", i):
            arith += 1
            depth += 2
            i += 2
            ws = True
            continue
        if arith and s.startswith("))", i):
            arith -= 1
            depth -= 2
            i += 2
            ws = cmd = False
            continue
        if not arith and s.startswith("<<", i):
            if s.startswith("<<<", i):
                i += 3
                ws, cmd = True, False
                continue
            hd = _heredoc_delim(s, i)
            if hd:
                heredocs.append(hd[0])
                i = hd[1]
                ws, cmd = True, False
                continue
        top = cases[-1] if cases and depth == cases[-1][0] else None
        if top and top[1] != "cmd" and ws and not arith and ch not in " \t\n":
            if top[1] == "subj":
                top[1] = "in"            # scanned on as an ordinary word
            elif top[1] == "in":
                if not s.startswith("in", i) or not _RESERVED_END_RE.match(s, i + 2):
                    return -1
                top[1] = "start"
                i += 2
                ws = False
                continue
            elif top[1] == "start":
                m = _RESERVED_AT_CMD_RE.match(s, i)
                if m and m.group(1) == "esac":
                    cases.pop()
                    i, ws, cmd = m.end(), False, False
                    continue
                top[1] = "word"          # `x|case)`: an alternative, no command
                if ch == "(":
                    i += 1               # a pattern's optional leading paren
                    continue
        elif cond and ws and s.startswith("]]", i) and _RESERVED_END_RE.match(s, i + 2):
            cond = False
            i, ws, cmd = i + 2, False, False
            continue
        elif ws and cmd and not arith:
            if s.startswith("[[", i) and _RESERVED_END_RE.match(s, i + 2):
                cond = True
                i, ws, cmd = i + 2, False, False
                continue
            m = _RESERVED_AT_CMD_RE.match(s, i)
            if m:
                if m.group(1) == "case":
                    cases.append([depth, "subj"])
                    cmd = False
                elif m.group(1) == "esac":
                    if cases:
                        cases.pop()
                    cmd = False
                i = m.end()
                ws = False
                continue
        if top and top[1] == "cmd" and s.startswith((";;", ";&"), i):
            i += 3 if s.startswith(";;&", i) else 2
            top[1] = "start"
            ws, cmd = True, False
            continue
        if ch == "$" and s.startswith("{", i + 1):
            e = _param_span(s, i, False, _depth + 1)   # `${X:-)}`: its parens are data
            if e is None:
                return -1
            i, ws, cmd = e, False, False
            continue
        if ch == "$" and s.startswith("'", i + 1):
            e = _ansi_c_span(s, i)       # `$'it\'s'`: the escaped `'` closes nothing
            if e is None:
                return -1
            i, ws, cmd = e, False, False
            continue
        if ch == chr(96):
            e = _backtick_span(s, i)     # a backtick body is its own: its `)` closes nothing here
            if e is None:
                return -1
            i, ws, cmd = e, False, False
            continue
        if ch == "'":
            in_s = True
        elif ch == chr(34):
            in_d = True
        elif ch == "(":
            depth += 1
        elif ch == ")" and top:
            top[1] = "cmd"               # a pattern list ends; its command follows
            cmd = True
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i
        ws = ch in " \t\n;&|()"
        if ch in ";&|(\n":               # not `)`: `$(true) case` is an argument
            cmd = not cond
        elif not ws:
            cmd = False
        i += 1
    return -1


_paren_matches = [None, {}]     # (string, {open index: close index}) for the last string


def _arith_closes(s, i):
    # Whether bash reads the `$((` at s[i] as arithmetic: its parens must close as one `))`.
    # shortcut: quotes are not modelled, so a quoted paren reads as unbalanced and the text
    # is scanned as a command -- the stricter reading.
    # The matches are found once per string: a scan from every opener was quadratic, and
    # 5000 nested `$((` outran the hook timeout, which the runner reads as ALLOW.
    if _paren_matches[0] is not s:
        m, stack, k = {}, [], 0
        while k < len(s):
            if s[k] == chr(92):
                k += 2                   # `\)` is no paren to bash either
                continue
            if s[k] == "(":
                stack.append(k)
            elif s[k] == ")" and stack:
                m[stack.pop()] = k
            k += 1
        _paren_matches[0], _paren_matches[1] = s, m
    close = _paren_matches[1].get(i + 2)
    return close is not None and s.startswith(")", close + 1)


def _subst_bodies(s):
    # (bodies, ok) for the `$(...)` and backtick substitutions in s, which run wherever
    # they appear -- inside double quotes too. Single-quoted regions are skipped (nothing
    # substitutes there), but a `'` inside double quotes is literal and opens nothing.
    # ok is False when a body's end cannot be found. KEEP IN STEP WITH
    # cmdword._command_substitutions -- which has no comment or heredoc model; this copy
    # needs one because a body found here is scanned as a COMMAND, and a `$( )` the shell
    # never runs (after a word-start `#`, or in a heredoc body) would be refused for text
    # that is only data. Every heredoc body is skipped, expanding or not: this scan only
    # ADDS coverage, so leaving a body to the existing readings is never a regression.
    s = _join_continuations(s)   # `ca\<nl>se` is `case`: unjoined, its pattern `)` closed the body
    out, i, n = [], 0, len(s)
    in_d = False
    ws = True                    # at a shell WORD start, where an unquoted `#` comments
    heredocs = []
    arith = 0                    # inside `(( ))`, where `<<` is a shift, not a heredoc
    param_end = 0                # inside `${…}` before this index: its `<<` and `#` are data
    while i < n:
        ch = s[i]
        if ch == "$" and i >= param_end and s.startswith("{", i + 1):
            # Not skipped -- a `$( )` inside it still runs -- only marked: `${X:-<<E}`
            # registered a heredoc that swallowed every later body. Marked inside double
            # quotes too: a local `"` flips in_d, and `"${X:-" #$(…)"}"` commented out its body.
            e = _param_span(s, i, in_d)
            if e is None:
                return out, False
            param_end = e
        if not in_d and heredocs and ch == chr(10):
            i = _heredoc_body_end(s, i + 1, heredocs)
            heredocs = []
            ws = True
            continue
        if not in_d and ws and ch == "#" and not arith and i >= param_end:
            nl = s.find(chr(10), i)
            i = n if nl < 0 else nl
            continue
        if not in_d and s.startswith("((", i):
            arith += 1
            i += 2
            ws = True
            continue
        if arith and s.startswith("))", i):
            arith -= 1
            i += 2
            ws = False                   # `$((1))#$(…)` is one word: its `#` comments nothing
            continue
        if not in_d and not arith and i >= param_end:
            if s.startswith("<<<", i):
                i += 3
                ws = True
                continue
            hd = _heredoc_delim(s, i)
            if hd:
                heredocs.append(hd[0])
                i = hd[1]
                ws = True
                continue
        if ch == chr(92) and s.startswith(chr(10), i + 1):
            i += 2                   # a line continuation is removed, so the word boundary
            continue                 # before it still holds: `ok \<nl># $(…)` is a comment
        ws = not in_d and ch in " \t\n;&|()<>"
        if ch == chr(92):
            i += 2
            continue
        if ch == "$" and not in_d and s.startswith("'", i + 1):
            j = _ansi_c_span(s, i)
            if j is None:
                return out, False
            i = j
            continue
        if ch == "'" and not in_d:
            j = s.find("'", i + 1)
            if j < 0:
                return out, False
            i = j + 1
            continue
        if ch == chr(34):
            in_d = not in_d
            i += 1
            continue
        if s.startswith("$((", i) and _arith_closes(s, i):
            # Arithmetic, not a command: walked on, so a `$( )` nested in it is still found.
            i += 3
            arith += 1
            continue
        # Otherwise bash falls back to `$(` + a subshell, which RUNS: `"$((( 1 < 2 )) &&
        # sh -c '…')"` ran its sh while this read it as arithmetic.
        if ch == "$" and i + 1 < n and s[i + 1] == "(":
            j = _subst_body_end(s, i + 1)
            if j < 0:
                return out, False
            out.append(s[i + 2:j])
            i = j + 1
            continue
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
        if ch == chr(96):
            j = _backtick_span(s, i)     # `\`` inside one is escaped, not its end
            if j is None:
                return out, False
            out.append(s[i + 1:j - 1])
            i = j
            continue
        i += 1
    return out, True


_ESC_RE = re.compile(
    r"\\(?:x([0-9A-Fa-f]{1,2})"      # \xH, \xHH
    r"|u([0-9A-Fa-f]{1,4})"          # \uH .. \uHHHH
    r"|U([0-9A-Fa-f]{1,8})"          # \UH .. \UHHHHHHHH
    r"|0?([0-7]{1,3}))")             # \ooo, \0ooo


def _decode_escapes(text):
    # Decode the ANSI-C escapes bash decodes, at bash digit widths. Python
    # `unicode_escape` codec is NOT a stand-in: it demands exactly four digits after
    # \u and eight after \U, so bash short forms survived it unchanged and a module
    # name spelled lease_$-quoted-\u73-lot read as an unrelated string. Over-decoding
    # can only make more text match, so it adds blocks and never removes one.
    def _sub(m):
        hexit = m.group(1) or m.group(2) or m.group(3)
        try:
            return chr(int(hexit, 16) if hexit else int(m.group(4), 8))
        except ValueError:
            return ""
    return _ESC_RE.sub(_sub, text)
